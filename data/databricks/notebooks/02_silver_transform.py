# Databricks notebook source
# MAGIC %md
# MAGIC # Silver — clean, conform, deduplicate
# MAGIC
# MAGIC Turns raw bronze rows into a trustworthy table with an enforced schema.
# MAGIC
# MAGIC Silver is where every judgement call lives. Bronze made none; gold
# MAGIC assumes they were all made correctly. That makes this the notebook to
# MAGIC read when a number is wrong.
# MAGIC
# MAGIC Three things happen here, in order:
# MAGIC 1. **Quarantine** — rows that fail validation are set aside, not dropped
# MAGIC 2. **Deduplicate** — at-least-once ingestion means duplicates exist
# MAGIC 3. **Merge** — upsert into silver, so the job is idempotent

# COMMAND ----------

from delta.tables import DeltaTable
from pyspark.sql import Window
from pyspark.sql import functions as F

# COMMAND ----------

dbutils.widgets.text("catalog", "purple_prod", "Unity Catalog")
CATALOG = dbutils.widgets.get("catalog")

BRONZE = f"{CATALOG}.bronze.raw_uploads"
SILVER = f"{CATALOG}.silver.datasets"
QUARANTINE = f"{CATALOG}.silver.datasets_quarantine"

# COMMAND ----------

# MAGIC %md
# MAGIC ## Read only what is new
# MAGIC
# MAGIC Delta's Change Data Feed exposes the rows that changed since a given
# MAGIC version, so this reads new rows rather than rescanning the entire bronze
# MAGIC table. On a table that grows for years, the difference between
# MAGIC incremental and full rescan is the difference between a 2-minute job and
# MAGIC a 2-hour one — and the full rescan gets slower every single day.
# MAGIC
# MAGIC CDF must be enabled on the source table:
# MAGIC `ALTER TABLE ... SET TBLPROPERTIES (delta.enableChangeDataFeed = true)`

# COMMAND ----------

last_version = (
    spark.sql(f"SELECT max(_bronze_version) AS v FROM {SILVER}").collect()[0]["v"]
    if spark.catalog.tableExists(SILVER)
    else 0
)

bronze_df = (
    spark.read.format("delta")
    .option("readChangeFeed", "true")
    .option("startingVersion", (last_version or 0) + 1)
    .table(BRONZE)
    .filter(F.col("_change_type").isin("insert", "update_postimage"))
)

print(f"Reading bronze from version {(last_version or 0) + 1}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Validate, and QUARANTINE rather than drop
# MAGIC
# MAGIC This is the design decision worth internalising.
# MAGIC
# MAGIC The obvious approach is `.filter(is_valid)` — keep the good rows, drop
# MAGIC the bad ones. It is also the wrong one, because dropped rows are
# MAGIC **silent**. Nobody notices that 3% of records vanished until a total
# MAGIC does not reconcile, months later, and by then the cause is unfindable.
# MAGIC
# MAGIC Quarantining writes the failures to a separate table WITH the reason
# MAGIC they failed. That makes data quality observable — you can alert on
# MAGIC quarantine volume, and you can reprocess a fixed batch — instead of
# MAGIC invisible.

# COMMAND ----------

validation_rules = {
    "missing_dataset_id": F.col("dataset_id").isNull(),
    "missing_user_id": F.col("user_id").isNull(),
    "invalid_row_count": F.col("row_count") < 0,
    "future_timestamp": F.col("created_at") > F.current_timestamp() + F.expr("INTERVAL 1 DAY"),
    # An unexpected source column arrived. Not fatal, but it means the silver
    # schema may be dropping data.
    "unexpected_schema": F.col("_rescued_data").isNotNull(),
}

failure_reason = F.array_compact(
    F.array(*[F.when(cond, F.lit(name)) for name, cond in validation_rules.items()])
)

validated = bronze_df.withColumn("_validation_failures", failure_reason)

valid_rows = validated.filter(F.size("_validation_failures") == 0)
invalid_rows = validated.filter(F.size("_validation_failures") > 0)

# COMMAND ----------

(
    invalid_rows.withColumn("_quarantined_at", F.current_timestamp())
    .write.format("delta")
    .mode("append")
    .option("mergeSchema", "true")
    .saveAsTable(QUARANTINE)
)

quarantined_count = invalid_rows.count()
total_count = validated.count()

if total_count > 0:
    quarantine_rate = quarantined_count / total_count
    print(f"Quarantined {quarantined_count}/{total_count} rows ({quarantine_rate:.2%})")
    # Fail the job on a quality cliff. A sudden jump in quarantine rate almost
    # always means the source changed, and continuing to publish gold from a
    # tenth of the expected data is worse than stopping.
    if quarantine_rate > 0.05:
        raise ValueError(
            f"Quarantine rate {quarantine_rate:.2%} exceeds the 5% threshold. "
            f"The source has likely changed shape. Inspect {QUARANTINE} before rerunning."
        )

# COMMAND ----------

# MAGIC %md
# MAGIC ## Deduplicate
# MAGIC
# MAGIC Duplicates are not a bug to be fixed upstream — they are the expected
# MAGIC consequence of at-least-once delivery. Every reliable queue and every
# MAGIC retry produces them.
# MAGIC
# MAGIC `dropDuplicates()` is the wrong tool: given two versions of the same
# MAGIC record it keeps an arbitrary one. This uses a window ordered by
# MAGIC ingestion time to keep the LATEST version deterministically, so the same
# MAGIC input always produces the same output — which is what makes the job
# MAGIC re-runnable.

# COMMAND ----------

dedup_window = Window.partitionBy("dataset_id").orderBy(
    F.col("_ingested_at").desc(),
    # Tie-break on the source file so two rows with identical timestamps still
    # resolve deterministically. Without this, a rerun can produce a different
    # result than the original run.
    F.col("_source_file").desc(),
)

deduplicated = (
    valid_rows.withColumn("_row_rank", F.row_number().over(dedup_window))
    .filter(F.col("_row_rank") == 1)
    .drop("_row_rank", "_validation_failures", "_rescued_data", "_change_type")
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Conform types
# MAGIC
# MAGIC Bronze stored everything as it arrived, mostly strings. Silver enforces
# MAGIC real types. Note `try_cast` rather than `cast`: `cast` turns an
# MAGIC unparseable value into a silent NULL, which is a data-quality failure
# MAGIC disguised as a missing value. Anything that fails to parse here was
# MAGIC already caught by validation above.

# COMMAND ----------

conformed = deduplicated.select(
    F.col("dataset_id").cast("string").alias("dataset_id"),
    F.col("user_id").cast("string").alias("user_id"),
    F.trim(F.col("dataset_name")).alias("dataset_name"),
    F.try_cast(F.col("row_count"), "long").alias("row_count"),
    F.try_cast(F.col("size_bytes"), "long").alias("size_bytes"),
    F.lower(F.trim(F.col("file_format"))).alias("file_format"),
    F.try_cast(F.col("created_at"), "timestamp").alias("created_at"),
    F.col("_ingested_at"),
    F.col("_source_file"),
    F.col("_commit_version").alias("_bronze_version"),
).withColumn("_silver_processed_at", F.current_timestamp())

# COMMAND ----------

# MAGIC %md
# MAGIC ## MERGE — the idempotency mechanism
# MAGIC
# MAGIC `MERGE INTO` upserts: update the row if the key exists, insert it if not.
# MAGIC
# MAGIC This is what makes the whole job safe to re-run. An append-only write
# MAGIC would duplicate everything on a rerun, so a failed job could never be
# MAGIC simply restarted — someone would have to work out what had already been
# MAGIC written and delete it by hand, during an incident.
# MAGIC
# MAGIC The `WHEN MATCHED AND source._ingested_at > target._ingested_at` clause
# MAGIC prevents an out-of-order replay from overwriting newer data with older.

# COMMAND ----------

if not spark.catalog.tableExists(SILVER):
    (
        conformed.write.format("delta")
        .option("delta.enableChangeDataFeed", "true")
        .clusterBy("user_id")
        .saveAsTable(SILVER)
    )
    print(f"Created {SILVER}")
else:
    target = DeltaTable.forName(spark, SILVER)
    (
        target.alias("t")
        .merge(conformed.alias("s"), "t.dataset_id = s.dataset_id")
        .whenMatchedUpdateAll(condition="s._ingested_at > t._ingested_at")
        .whenNotMatchedInsertAll()
        .execute()
    )
    print(f"Merged {conformed.count()} rows into {SILVER}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A note on `clusterBy` versus `partitionBy`
# MAGIC
# MAGIC The table is created with **liquid clustering** (`clusterBy`), not Hive
# MAGIC partitioning (`partitionBy`).
# MAGIC
# MAGIC Partitioning creates one directory per distinct value. Partition by a
# MAGIC high-cardinality column like `user_id` with a million users and you get a
# MAGIC million directories holding a few KB each — the "small files problem",
# MAGIC where listing the table costs more than reading it.
# MAGIC
# MAGIC Liquid clustering co-locates related rows inside files without creating
# MAGIC directories, handles skew, and — crucially — the clustering key can be
# MAGIC **changed later** without rewriting the table. A partition key cannot.

# COMMAND ----------

display(spark.sql(f"SELECT count(*) AS silver_rows FROM {SILVER}"))
