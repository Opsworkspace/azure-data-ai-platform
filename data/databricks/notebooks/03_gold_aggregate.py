# Databricks notebook source
# MAGIC %md
# MAGIC # Gold — business aggregates
# MAGIC
# MAGIC The layer the API and the dashboards actually read.
# MAGIC
# MAGIC Gold is fully derived: it can be dropped and rebuilt from silver at any
# MAGIC time. That is what makes it safe to change its shape — unlike bronze,
# MAGIC nothing is lost by recomputing it.
# MAGIC
# MAGIC Gold tables are also the platform's **contract with its consumers**.
# MAGIC A dashboard built on gold should not break because a silver transform
# MAGIC was refactored, which is exactly why analysts are granted gold and not
# MAGIC silver.

# COMMAND ----------

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "purple_prod", "Unity Catalog")
CATALOG = dbutils.widgets.get("catalog")

SILVER_DATASETS = f"{CATALOG}.silver.datasets"
GOLD_USER_SUMMARY = f"{CATALOG}.gold.user_dataset_summary"
GOLD_DAILY_ACTIVITY = f"{CATALOG}.gold.daily_platform_activity"

# COMMAND ----------

# MAGIC %md
# MAGIC ## Per-user summary
# MAGIC
# MAGIC Read by the API on every dashboard load, for one user at a time. That
# MAGIC access pattern — a point lookup by `user_id` — is why the table is
# MAGIC clustered on `user_id`: the query engine can skip every file that cannot
# MAGIC contain that user's rows.
# MAGIC
# MAGIC Note that this is precomputed rather than calculated on demand. At
# MAGIC 120,000 daily active users, running this aggregation per request would
# MAGIC scan the whole silver table per page load. Precomputing trades freshness
# MAGIC (the data is as old as the last job run) for a query that returns in
# MAGIC milliseconds. Whether that trade is right is a product decision, and it
# MAGIC is the single most common performance question in an analytics platform.

# COMMAND ----------

silver = spark.table(SILVER_DATASETS)

user_summary = (
    silver.groupBy("user_id")
    .agg(
        F.count("*").alias("dataset_count"),
        F.sum("row_count").alias("total_rows"),
        F.sum("size_bytes").alias("total_bytes"),
        F.max("created_at").alias("most_recent_upload_at"),
        F.min("created_at").alias("first_upload_at"),
        F.collect_set("file_format").alias("file_formats_used"),
        # approx_count_distinct rather than countDistinct. Exact distinct counts
        # require a full shuffle of every value; HyperLogLog gives ~2% error for
        # a fraction of the cost. For a "how many datasets" tile, 2% error is
        # invisible and the cost difference is large. For a billing metric it
        # would not be — the choice depends on what the number is used for.
        F.approx_count_distinct("dataset_name").alias("distinct_dataset_names"),
    )
    .withColumn("_computed_at", F.current_timestamp())
)

(
    user_summary.write.format("delta")
    .mode("overwrite")
    # Gold is fully derived, so a complete overwrite is correct and simpler
    # than a merge. overwriteSchema allows the shape to evolve freely — again
    # safe only because nothing here is irreplaceable.
    .option("overwriteSchema", "true")
    .clusterBy("user_id")
    .saveAsTable(GOLD_USER_SUMMARY)
)

print(f"Wrote {user_summary.count()} user summaries")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Daily platform activity
# MAGIC
# MAGIC Time series for the platform dashboards. Partitioned by month rather
# MAGIC than by day: one directory per day over three years is ~1,100 partitions
# MAGIC holding one small file each, which is the small-files problem again.
# MAGIC Monthly gives 36 partitions of a useful size.

# COMMAND ----------

daily_activity = (
    silver.withColumn("activity_date", F.to_date("created_at"))
    .groupBy("activity_date")
    .agg(
        F.countDistinct("user_id").alias("active_users"),
        F.count("*").alias("datasets_uploaded"),
        F.sum("size_bytes").alias("bytes_uploaded"),
        F.avg("row_count").alias("avg_rows_per_dataset"),
        F.expr("percentile_approx(size_bytes, 0.5)").alias("median_dataset_bytes"),
        F.expr("percentile_approx(size_bytes, 0.99)").alias("p99_dataset_bytes"),
    )
    .withColumn("activity_month", F.date_format("activity_date", "yyyy-MM"))
    .withColumn("_computed_at", F.current_timestamp())
)

(
    daily_activity.write.format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .partitionBy("activity_month")
    .saveAsTable(GOLD_DAILY_ACTIVITY)
)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Table maintenance
# MAGIC
# MAGIC The two commands every Delta table needs, and that a lakehouse quietly
# MAGIC degrades without.
# MAGIC
# MAGIC **OPTIMIZE** compacts many small files into fewer large ones. Every
# MAGIC write produces new files; after a few hundred runs a table is thousands
# MAGIC of tiny files and every query pays per-file open overhead.
# MAGIC
# MAGIC **VACUUM** deletes files no longer referenced by the transaction log.
# MAGIC Without it, storage grows forever even when the table's row count is
# MAGIC flat, because every overwritten version's files are still there.
# MAGIC
# MAGIC The 168-hour (7 day) retention is not arbitrary: it is the time-travel
# MAGIC window. VACUUM with a shorter retention destroys the ability to query
# MAGIC older versions — and Delta refuses retentions under 168 hours without an
# MAGIC explicit override, precisely because people do this by accident and
# MAGIC break a concurrent long-running reader.

# COMMAND ----------

for table in (GOLD_USER_SUMMARY, GOLD_DAILY_ACTIVITY):
    spark.sql(f"OPTIMIZE {table}")
    spark.sql(f"VACUUM {table} RETAIN 168 HOURS")
    # Statistics drive the query optimiser's join and file-skipping decisions.
    # Stale statistics produce plans that look inexplicably bad.
    spark.sql(f"ANALYZE TABLE {table} COMPUTE STATISTICS FOR ALL COLUMNS")
    print(f"Maintained {table}")

# COMMAND ----------

display(spark.sql(f"SELECT * FROM {GOLD_DAILY_ACTIVITY} ORDER BY activity_date DESC LIMIT 30"))
