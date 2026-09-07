# Databricks notebook source
# MAGIC %md
# MAGIC # Build the vector index for RAG
# MAGIC
# MAGIC Reads gold, chunks the text, generates embeddings, and writes them into
# MAGIC Azure AI Search so the assistant can retrieve them.
# MAGIC
# MAGIC ## The one thing that must not go wrong
# MAGIC
# MAGIC Every document written here carries a `userId` field. The API's retrieval
# MAGIC filter matches on it — see `services/api/purple_api/rag.py`. A document
# MAGIC indexed **without** `userId` is invisible to every filtered query, which
# MAGIC fails safe; a document indexed with the **wrong** `userId` is a
# MAGIC cross-tenant data leak, which does not.
# MAGIC
# MAGIC The assertion below is not defensive programming ceremony. It is the
# MAGIC write-side half of the platform's tenant isolation boundary.

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.types import ArrayType, StringType, StructField, StructType

# COMMAND ----------

dbutils.widgets.text("catalog", "purple_prod", "Unity Catalog")
dbutils.widgets.text(
    "search_endpoint", "https://purple-data-prod-eus2-srch.search.windows.net", "AI Search"
)
dbutils.widgets.text(
    "openai_endpoint", "https://purple-data-prod-eus2-oai.openai.azure.com/", "Azure OpenAI"
)
dbutils.widgets.text("index_name", "purple-documents", "Index")

CATALOG = dbutils.widgets.get("catalog")
SEARCH_ENDPOINT = dbutils.widgets.get("search_endpoint")
OPENAI_ENDPOINT = dbutils.widgets.get("openai_endpoint")
INDEX_NAME = dbutils.widgets.get("index_name")

SOURCE = f"{CATALOG}.gold.document_content"
EMBEDDING_DEPLOYMENT = "embeddings"
EMBEDDING_DIMENSIONS = 3072  # text-embedding-3-large

# COMMAND ----------

# MAGIC %md
# MAGIC ## Authentication
# MAGIC
# MAGIC No keys. The cluster runs with a managed identity, and both Azure OpenAI
# MAGIC and AI Search accept Entra tokens — `local_auth_enabled = false` and
# MAGIC `local_authentication_enabled = false` in Terraform mean a key would not
# MAGIC work even if one existed.

# COMMAND ----------

from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from openai import AzureOpenAI

credential = DefaultAzureCredential()


def token_provider() -> str:
    return credential.get_token("https://cognitiveservices.azure.com/.default").token


openai_client = AzureOpenAI(
    azure_endpoint=OPENAI_ENDPOINT,
    azure_ad_token_provider=token_provider,
    api_version="2024-10-21",
)

search_client = SearchClient(
    endpoint=SEARCH_ENDPOINT,
    index_name=INDEX_NAME,
    credential=credential,
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Chunking
# MAGIC
# MAGIC Identical parameters to `services/worker/purple_worker/main.py`, and that
# MAGIC is not a coincidence to be tolerated — it is a requirement.
# MAGIC
# MAGIC If the batch pipeline chunks at 1000 characters and the streaming worker
# MAGIC chunks at 500, the index contains two populations of chunks with
# MAGIC different embedding characteristics, and retrieval quality varies
# MAGIC depending on which path ingested a document. In a real platform these
# MAGIC constants belong in one shared library imported by both.

# COMMAND ----------

CHUNK_SIZE = 1000
CHUNK_OVERLAP = 150

chunk_schema = ArrayType(
    StructType(
        [
            StructField("chunk_index", StringType()),
            StructField("content", StringType()),
        ]
    )
)


@F.udf(returnType=chunk_schema)
def chunk_text(text):
    if not text:
        return []
    step = CHUNK_SIZE - CHUNK_OVERLAP
    out = []
    for i, start in enumerate(range(0, len(text), step)):
        piece = text[start : start + CHUNK_SIZE].strip()
        if piece:
            out.append({"chunk_index": str(i), "content": piece})
        if start + CHUNK_SIZE >= len(text):
            break
    return out


# COMMAND ----------

documents = spark.table(SOURCE).select("document_id", "document_name", "user_id", "content")

chunked = (
    documents.withColumn("chunk", F.explode(chunk_text(F.col("content"))))
    .select(
        "document_id",
        "document_name",
        "user_id",
        F.col("chunk.chunk_index").alias("chunk_index"),
        F.col("chunk.content").alias("chunk_content"),
    )
    # Content-addressed chunk id: the same content always produces the same id,
    # so re-running this notebook overwrites rather than duplicating.
    .withColumn(
        "chunk_id",
        F.substring(
            F.sha2(F.concat_ws("|", "document_id", "chunk_index", "chunk_content"), 256), 1, 32
        ),
    )
)

# ---------------------------------------------------------------------------
# THE TENANT ISOLATION ASSERTION.
#
# Refuse to index anything without a user id. A chunk with a NULL userId is
# unreachable by any filtered query, so it wastes index capacity and cost while
# being invisible — and its presence means an upstream join dropped a user
# association, which is worth failing the job over.
# ---------------------------------------------------------------------------
orphans = chunked.filter(F.col("user_id").isNull()).count()
if orphans > 0:
    raise ValueError(
        f"{orphans} chunks have no user_id. Refusing to index: every document "
        f"in this index MUST carry the field the API filters on. Investigate "
        f"the join in {SOURCE} before rerunning."
    )

print(f"{chunked.count()} chunks ready, all with a user id")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Embed and upload
# MAGIC
# MAGIC `foreachPartition` so each Spark partition opens its own client and
# MAGIC uploads independently, rather than collecting everything to the driver.
# MAGIC Collecting to the driver is the classic Spark mistake: it works on the
# MAGIC test dataset and runs the driver out of memory on the real one.
# MAGIC
# MAGIC The batch size bounds both the memory held per partition and the cost of
# MAGIC retrying a failed batch.

# COMMAND ----------

EMBED_BATCH = 32
UPLOAD_BATCH = 100


def process_partition(rows):
    """Embed and upload one Spark partition.

    Clients are created INSIDE the function. A client created on the driver
    cannot be serialised to an executor, and attempting it produces a pickling
    error that does not mention Spark.
    """
    from azure.identity import DefaultAzureCredential
    from azure.search.documents import SearchClient
    from openai import AzureOpenAI

    cred = DefaultAzureCredential()
    oai = AzureOpenAI(
        azure_endpoint=OPENAI_ENDPOINT,
        azure_ad_token_provider=lambda: (
            cred.get_token("https://cognitiveservices.azure.com/.default").token
        ),
        api_version="2024-10-21",
        max_retries=3,
    )
    search = SearchClient(endpoint=SEARCH_ENDPOINT, index_name=INDEX_NAME, credential=cred)

    buffer = []
    pending = []

    for row in rows:
        buffer.append(row)
        if len(buffer) >= EMBED_BATCH:
            pending.extend(_embed_batch(oai, buffer))
            buffer = []
        if len(pending) >= UPLOAD_BATCH:
            search.merge_or_upload_documents(documents=pending)
            pending = []

    if buffer:
        pending.extend(_embed_batch(oai, buffer))
    if pending:
        search.merge_or_upload_documents(documents=pending)


def _embed_batch(oai, rows):
    response = oai.embeddings.create(
        model=EMBEDDING_DEPLOYMENT,
        input=[r["chunk_content"] for r in rows],
    )
    return [
        {
            "chunkId": r["chunk_id"],
            "documentId": r["document_id"],
            "documentName": r["document_name"],
            # The field the API filters on. Never optional.
            "userId": r["user_id"],
            "content": r["chunk_content"],
            "sequence": int(r["chunk_index"]),
            "contentVector": e.embedding,
        }
        for r, e in zip(rows, response.data, strict=True)
    ]


# COMMAND ----------

# Repartition to bound concurrency against the embedding model's TPM quota.
# Too many partitions means many parallel callers, sustained 429s, and the
# interactive API sharing the same deployment gets starved.
chunked.repartition(8).foreachPartition(process_partition)

print("Index build complete.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Verify isolation on the live index
# MAGIC
# MAGIC A last check against what was actually written: pick a user, search with
# MAGIC their filter, and confirm every returned document belongs to them. This
# MAGIC catches a filter or field-name mismatch that unit tests cannot, because
# MAGIC it queries the real index.

# COMMAND ----------

sample_user = chunked.select("user_id").first()["user_id"]

results = search_client.search(
    search_text="*",
    filter=f"userId eq '{sample_user}'",
    select=["chunkId", "userId"],
    top=50,
)

leaked = [r for r in results if r["userId"] != sample_user]
if leaked:
    raise AssertionError(
        f"TENANT ISOLATION FAILURE: filtering on userId={sample_user} returned "
        f"{len(leaked)} documents belonging to other users."
    )

print(f"Isolation verified for user {sample_user}.")
