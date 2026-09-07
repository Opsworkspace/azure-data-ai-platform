# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze — raw ingestion
# MAGIC
# MAGIC Lands uploaded files into the bronze layer, **exactly as received**.
# MAGIC
# MAGIC ## The rules of bronze
# MAGIC
# MAGIC 1. **Never transform.** No parsing, no casting, no cleaning. If the
# MAGIC    source sent `"N/A"` in a numeric column, bronze stores `"N/A"`.
# MAGIC 2. **Never update.** Append only. A correction from the source is a new
# MAGIC    row, not an edit.
# MAGIC 3. **Always add provenance.** Which file, which run, what time.
# MAGIC
# MAGIC Rule 1 is the one people break, usually by "just" casting a column. The
# MAGIC moment bronze contains a transformation, it stops being the thing you can
# MAGIC re-derive everything else from — because now it contains a decision that
# MAGIC might have been wrong.

# COMMAND ----------

from pyspark.sql import functions as F

# COMMAND ----------

dbutils.widgets.text("catalog", "purple_prod", "Unity Catalog")
dbutils.widgets.text(
    "source_path", "abfss://bronze@purpledataprodeus2000000.dfs.core.windows.net/landing/", "Source"
)
dbutils.widgets.text("table_name", "raw_uploads", "Target table")

CATALOG = dbutils.widgets.get("catalog")
SOURCE_PATH = dbutils.widgets.get("source_path")
TABLE_NAME = dbutils.widgets.get("table_name")

TARGET = f"{CATALOG}.bronze.{TABLE_NAME}"
CHECKPOINT = f"abfss://checkpoints@purpledataprodeus2000000.dfs.core.windows.net/{TABLE_NAME}/"

# COMMAND ----------

# MAGIC %md
# MAGIC ## Auto Loader
# MAGIC
# MAGIC `cloudFiles` incrementally discovers new files. The alternative —
# MAGIC listing the directory each run and diffing against what was already
# MAGIC processed — degrades badly: on a container with millions of blobs, the
# MAGIC LIST operation alone takes minutes and costs real money per call.
# MAGIC
# MAGIC Auto Loader uses a notification queue (Event Grid) instead, so
# MAGIC discovery is O(new files) rather than O(all files).
# MAGIC
# MAGIC ### schemaEvolutionMode = rescue
# MAGIC
# MAGIC The most important option here. Four modes exist:
# MAGIC
# MAGIC | Mode | On an unexpected column |
# MAGIC |---|---|
# MAGIC | `addNewColumns` | Add it, fail the stream, restart with new schema |
# MAGIC | `rescue` | Put it in `_rescued_data`, keep going |
# MAGIC | `failOnNewColumns` | Fail and stay failed |
# MAGIC | `none` | Silently drop it |
# MAGIC
# MAGIC `rescue` is right for bronze because **no data is ever lost and the
# MAGIC pipeline never stops**. An unexpected column lands in `_rescued_data` as
# MAGIC JSON, where it can be inspected later. `none` is the dangerous one: data
# MAGIC silently disappears and nobody finds out for months.

# COMMAND ----------

raw = (
    spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "json")
    .option("cloudFiles.schemaLocation", f"{CHECKPOINT}schema/")
    .option("cloudFiles.schemaEvolutionMode", "rescue")
    # File notification mode rather than directory listing.
    .option("cloudFiles.useNotifications", "true")
    # Bound each micro-batch so one enormous backlog does not produce a single
    # batch that exhausts cluster memory.
    .option("cloudFiles.maxFilesPerTrigger", 1000)
    .load(SOURCE_PATH)
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Provenance columns
# MAGIC
# MAGIC Added, never removed. When a downstream number is wrong, the first
# MAGIC question is "which file did this come from and when" — and without these
# MAGIC the answer is unobtainable.
# MAGIC
# MAGIC `_ingested_at` uses `current_timestamp()`, which is the PROCESSING time.
# MAGIC That is deliberately different from any event time inside the payload:
# MAGIC keeping both is what lets you distinguish "the source sent it late" from
# MAGIC "we processed it late".

# COMMAND ----------

bronze = (
    raw.withColumn("_ingested_at", F.current_timestamp())
    .withColumn("_source_file", F.col("_metadata.file_path"))
    .withColumn("_source_file_modified_at", F.col("_metadata.file_modification_time"))
    # Ties every row to the job run that produced it, so a bad run's output can
    # be identified and excluded without guessing at timestamps.
    .withColumn(
        "_ingest_run_id",
        F.lit(
            dbutils.notebook.entry_point.getDbutils()
            .notebook()
            .getContext()
            .runId()
            .getOrElse(lambda: "manual")
        ),
    )
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Write
# MAGIC
# MAGIC `availableNow=True` processes everything currently available and then
# MAGIC stops, rather than running forever. This turns a streaming job into a
# MAGIC batch job that keeps streaming's exactly-once guarantees and checkpoint
# MAGIC recovery — and lets the cluster shut down between runs, which for a job
# MAGIC that runs hourly is the difference between paying for 1 hour a day and 24.
# MAGIC
# MAGIC The checkpoint is what makes reruns safe: it records exactly which files
# MAGIC were processed, so a rerun after a failure resumes rather than
# MAGIC duplicating.

# COMMAND ----------

(
    bronze.writeStream.format("delta")
    .outputMode("append")
    .option("checkpointLocation", f"{CHECKPOINT}commits/")
    # mergeSchema so a genuinely new column widens the table rather than
    # failing the write. Safe in bronze specifically because bronze has no
    # consumers depending on a fixed shape.
    .option("mergeSchema", "true")
    .trigger(availableNow=True)
    .toTable(TARGET)
    .awaitTermination()
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Verify, and surface rescued data
# MAGIC
# MAGIC A non-empty `_rescued_data` means the source changed shape. That is not
# MAGIC an error — bronze handled it correctly — but it is a signal that the
# MAGIC silver transform may be about to drop something, and it should be looked
# MAGIC at rather than discovered three months later.

# COMMAND ----------

rescued = spark.sql(f"""
    SELECT count(*) AS rescued_rows
    FROM {TARGET}
    WHERE _rescued_data IS NOT NULL
      AND _ingested_at > current_timestamp() - INTERVAL 1 HOUR
""").collect()[0]["rescued_rows"]

if rescued > 0:
    print(f"WARNING: {rescued} rows had unexpected columns rescued into _rescued_data.")
    print("The source schema has changed. Review before the silver transform drops them.")

display(spark.sql(f"SELECT count(*) AS total_rows FROM {TARGET}"))
