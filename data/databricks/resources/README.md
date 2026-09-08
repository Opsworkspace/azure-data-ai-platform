# Bundle resources

Job and pipeline definitions for the Databricks Asset Bundle rooted at
`../databricks.yml`. Deployed by `databricks bundle deploy`, never created in
the workspace UI.

A job created by clicking in the UI is a job that:

- nobody can review before it changes,
- cannot be reproduced in another workspace or region,
- has no history beyond "modified by X on Y",
- and disappears entirely if the workspace is recreated.

## Why a bundle rather than job JSON

This directory used to hold `medallion-pipeline.json`, posted with
`databricks jobs create`. That worked, and had three problems a bundle solves:

**It was not idempotent.** `jobs create` makes a *new* job every time, so
re-running it left two identical schedules racing each other. Making it
idempotent by hand means storing the job id somewhere outside the repository,
at which point the repository is no longer the source of truth.

**Notebook paths were absolute.** `/Repos/platform/azure-data-ai-platform/...`
describes one workspace's folder layout. Point the same JSON at a second
workspace and the tasks silently reference notebooks that are not there. A
bundle uploads the notebooks it references and rewrites the paths on deploy,
which is why no `/Repos/...` path appears in this repository any more.

**There was no environment axis.** Dev, stage and prod need different cluster
sizes, catalogs and schedules. JSON can only express that by copying the file,
and copies drift. The bundle's targets differ only in *arguments* — the same
approach the Terraform environments take, for the same reason: a reviewer can
diff two targets instead of reading two files.

## Reading `medallion-pipeline.yml`

The reasoning behind each non-obvious setting is a comment next to the setting
itself rather than prose here, so that changing the value and leaving the
justification behind is visible in the diff. The ones worth seeking out:

| Setting | Why it is what it is |
|---|---|
| `max_concurrent_runs: 1` | Two concurrent runs race on the silver MERGE |
| `first_on_demand: 1` | Losing a spot *driver* kills the run; losing a worker does not |
| `runtime_engine: PHOTON` | On ETL only — it is a loss for the UDF-heavy embedding stage |
| `data_security_mode: SINGLE_USER` | Required for Unity Catalog attribution |
| `health.rules` | Warns on a slow run without failing it |
| `retry_on_timeout: false` | A timeout means stuck, not slow; retrying spends another hour |

## Deploying

```bash
# From data/databricks/
databricks bundle validate --target dev
databricks bundle deploy   --target dev
databricks bundle run      medallion_pipeline --target dev
```

`dev` is the default target and runs in development mode, which prefixes every
resource with `[dev <your-username>]`, pauses all schedules, and deploys under
your own workspace home. Two engineers can therefore deploy at once without
colliding, and neither can start a scheduled production run by accident.

No pipeline in this repository deploys a bundle: `bundle deploy` needs a
workspace credential, and no pipeline here holds one. See
`docs/00-safety-and-placeholders.md`.

What CI *can* do without credentials is check that the YAML parses and that
every key exists in the Databricks CLI's schema — `make lint-bundle`, which is
`tools/check_bundle_schema.py`. It catches the typo class of error
(`max_concurrent_run`, `runtime_enginee`) that would otherwise survive until a
manual deploy. It cannot check that a value is *correct*; that needs a
workspace.
