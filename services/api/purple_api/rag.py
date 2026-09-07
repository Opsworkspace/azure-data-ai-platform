"""The retrieval-augmented generation path.

This module contains the platform's most important security boundary, and it
is one line long. Look for `filter=` in `retrieve_context`.

**The threat.** A vector index holds chunks from every user's documents. A
similarity search returns whatever is semantically nearest to the question. If
the search is not filtered by user, a question like "summarise the Q3 revenue
figures" returns the nearest chunks *from anyone's documents*, and the model
will summarise another customer's confidential data fluently and
convincingly. The user has no way to tell it is not theirs.

This is not hypothetical. It is the defining data-leak pattern of enterprise
RAG, and it happens because the filter is easy to forget and its absence is
invisible in testing — with one tenant's data in the index, an unfiltered
search returns exactly the right answers.

**The defence, in layers:**

1. The filter is applied here, server-side, from the authenticated principal.
2. `user_id` is never read from the request body — only from the validated
   token. A client-supplied user id is a client-controlled filter.
3. The API's managed identity holds `Search Index Data Reader`, so even a full
   compromise of this service cannot modify or poison the index.
4. Only the worker's identity may write to the index.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from purple_api.clients import get_openai_client, get_search_client
from purple_api.config import get_settings
from purple_api.telemetry import get_logger

log = get_logger(__name__)


@dataclass
class RetrievedChunk:
    """One passage retrieved from the index."""

    chunk_id: str
    content: str
    document_name: str
    score: float


class UnauthorizedRetrievalError(Exception):
    """Raised when a retrieval is attempted without an authenticated user."""


async def embed_query(question: str) -> list[float]:
    """Turn a question into a vector using the same model that indexed the corpus.

    'The same model' is not optional. Embeddings from different models — or
    even different versions of one model — occupy different vector spaces, and
    similarity between them is meaningless. A model upgrade therefore requires
    re-embedding the entire corpus, which is why the deployment name is pinned
    in Terraform rather than following 'latest'.
    """
    settings = get_settings()
    client = get_openai_client()

    response = await client.embeddings.create(
        model=settings.openai_embedding_deployment,
        input=question,
    )
    return response.data[0].embedding


async def retrieve_context(question: str, *, user_id: str) -> list[RetrievedChunk]:
    """Retrieve the passages most relevant to a question, for ONE user.

    Args:
        question: The user's natural-language question.
        user_id: The authenticated principal's id. **Must** come from the
            validated access token, never from the request body.

    Raises:
        UnauthorizedRetrievalError: if no user id is supplied. Failing closed here
            is deliberate — an empty filter string in Azure AI Search means
            "no filter", so a falsy user id would silently search everything.
    """
    if not user_id:
        raise UnauthorizedRetrievalError("Refusing to search the index without a user filter.")

    settings = get_settings()
    client = get_search_client()
    vector = await embed_query(question)

    from azure.search.documents.models import VectorizedQuery

    results = await client.search(
        search_text=question,
        vector_queries=[
            VectorizedQuery(
                vector=vector,
                k_nearest_neighbors=settings.rag_top_k,
                fields="contentVector",
            )
        ],
        # ------------------------------------------------------------------
        # THE SECURITY BOUNDARY.
        #
        # Applied server-side, from the authenticated identity. Every document
        # in the index carries a userId field written at ingestion time by the
        # worker.
        #
        # OData filter syntax, and the quoting matters: user ids are validated
        # as UUIDs upstream, but doubling any single quote is the documented
        # escaping rule and costs nothing to apply.
        # ------------------------------------------------------------------
        filter=f"userId eq '{user_id.replace(chr(39), chr(39) * 2)}'",
        # Hybrid retrieval: vector similarity AND keyword matching, fused by
        # reciprocal rank. Vectors find conceptual matches; keywords find exact
        # identifiers, product codes and names that embeddings blur together.
        query_type="semantic",
        semantic_configuration_name="default",
        top=settings.rag_top_k,
        select=["chunkId", "content", "documentName"],
    )

    chunks: list[RetrievedChunk] = []
    async for result in results:
        chunks.append(
            RetrievedChunk(
                chunk_id=result["chunkId"],
                content=result["content"],
                document_name=result["documentName"],
                score=result.get("@search.score", 0.0),
            )
        )

    log.info(
        "retrieval_complete",
        user_id=user_id,
        chunks_returned=len(chunks),
        top_k=settings.rag_top_k,
    )
    return chunks


SYSTEM_PROMPT = """You are the Purple data assistant.

Answer using ONLY the context passages provided. If the context does not
contain the answer, say so plainly — do not use general knowledge to fill the
gap, and do not speculate.

Cite the document name for each claim you make.
"""


async def answer(question: str, *, user_id: str) -> dict[str, Any]:
    """Answer a question using only the user's own documents.

    The grounding instruction in SYSTEM_PROMPT is a quality control, not a
    security control. It reduces hallucination; it does not prevent data
    leakage. The only thing preventing leakage is the filter in
    `retrieve_context`, because a model cannot leak a passage it was never
    shown.

    Prompt-level restrictions are bypassable by construction — the model sees
    whatever text is in its context window and can be talked into using it.
    Retrieval-level restrictions are not, because the data never arrives.
    """
    settings = get_settings()
    chunks = await retrieve_context(question, user_id=user_id)

    if not chunks:
        return {
            "answer": "I could not find anything in your documents that answers that.",
            "sources": [],
        }

    context = "\n\n".join(f"[{c.document_name}]\n{c.content}" for c in chunks)

    client = get_openai_client()
    completion = await client.chat.completions.create(
        model=settings.openai_chat_deployment,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"},
        ],
        temperature=0.1,  # low: this is a retrieval task, not a creative one
        max_tokens=1000,
    )

    return {
        "answer": completion.choices[0].message.content,
        "sources": [{"document": c.document_name, "score": round(c.score, 4)} for c in chunks],
    }
