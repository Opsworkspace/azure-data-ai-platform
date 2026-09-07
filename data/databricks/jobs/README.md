# Databricks job definitions

Jobs as JSON, deployed by CI. Never created in the workspace UI.

A job created by clicking in the UI is a job that:

- nobody can review before it changes,
- cannot be reproduced in another workspace or region,
- has no history beyond "modified by X on Y",
- and disappears entirely if the workspace is recreated.

## Reading `medallion-pipeline.json`

A few choices in it are worth understanding.

### `max_concurrent_runs: 1`

The single most important line. Set to a higher value, two runs of the silver
transform can read the same bronze change-feed range concurrently and race on
the MERGE. The `spark.sql` MERGE is atomic, but two runs both computing "rows
since version N" produce duplicate work and, with a slow first run, an
out-of-order overwrite.

Serial execution is almost always what a scheduled pipeline wants. If a run
overruns its schedule, the right behaviour is to skip the next one, not to
start it alongside.

### `SPOT_WITH_FALLBACK_AZURE` with `first_on_demand: 1`

Workers on spot instances, up to 90% cheaper, evictable at any time. The
driver on demand.

The driver placement is the point: a Spark job survives losing a worker — the
tasks are simply re-run elsewhere — but **losing the driver kills the whole
job**, discarding all completed work. `first_on_demand: 1` pins exactly the
driver to guaranteed capacity and lets every worker be spot.

### `data_security_mode: SINGLE_USER`

Required for Unity Catalog. It means the cluster runs as one identity, so
Unity Catalog can attribute every read and write to a principal. A shared
cluster with multiple users cannot enforce per-user grants on the same query
engine, which is why the older shared-cluster mode has restrictions.

### `PHOTON` runtime

A vectorised C++ execution engine. It costs roughly 2x the DBU rate and
typically runs 2-4x faster on scan-and-aggregate work, so it is usually cost-
neutral-to-cheaper for ETL — and it is a straight loss for UDF-heavy work,
which falls back to the JVM. The ETL cluster uses it; the embedding cluster,
which is dominated by Python UDFs and network calls, does not.

### `health.rules`

Alerts if the run exceeds two hours, without failing it. A pipeline that
normally takes 20 minutes and suddenly takes 90 is telling you something —
usually that data volume grew or a join degraded — long before it starts
timing out.

## Deploying

```bash
databricks jobs create --json @data/databricks/jobs/medallion-pipeline.json
# or, idempotently, in CI:
databricks bundle deploy --target prod
```

Not run by any pipeline in this repository: it requires a workspace token,
and no pipeline here holds credentials. See `docs/00-safety-and-placeholders.md`.
