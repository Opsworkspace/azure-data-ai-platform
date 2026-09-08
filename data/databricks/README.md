# Data platform

The lakehouse, its governance model, and the pipelines that move data through
it.

## The medallion architecture

```
        ingest              clean & conform           aggregate
source ────────► BRONZE ──────────────────► SILVER ──────────────► GOLD
                   │                          │                      │
              raw, immutable            deduplicated,          business-shaped
              exactly as received       schema-enforced,        aggregates the
              never edited              quality-checked         API and BI read
```

### Why three layers and not one

The question worth answering is: *what do you do when a number in a dashboard
is wrong?*

With one layer, you do not know whether the source sent bad data or your
transform introduced the error, and you cannot re-run the transform because
the original is gone — it was overwritten.

With bronze preserved, you re-derive silver and gold from data you still have.
Bronze is append-only and never edited, which is the whole point: it is the
one thing you cannot reconstruct, so it is the one thing you never mutate.

| Layer | Written by | Read by | Mutation |
|---|---|---|---|
| Bronze | Ingest jobs only | Silver transforms | Append only, never updated |
| Silver | Transform jobs | Gold aggregations, data scientists | Merged/upserted, reproducible |
| Gold | Aggregation jobs | The API, dashboards, the RAG indexer | Fully reproducible from silver |

## Why Delta Lake and not plain Parquet

Parquet is a file format. Delta is a *table* format: Parquet files plus a
transaction log.

That log buys four things a lakehouse genuinely needs:

1. **ACID transactions.** A job that fails halfway leaves no partial data.
   With plain Parquet, readers see half-written output.
2. **Time travel.** `VERSION AS OF 42` reads the table as it was. This is how
   you answer "what did this report say last Tuesday" and how you recover from
   a bad write.
3. **Schema enforcement and evolution.** A write with an unexpected column is
   rejected rather than silently creating an inconsistent table.
4. **Efficient upserts.** `MERGE INTO` on a columnar store is otherwise a full
   rewrite.

The cost is that the transaction log itself needs maintenance — `OPTIMIZE` to
compact small files, `VACUUM` to expire old versions. Both are in the
maintenance job, and skipping them is how a Delta table becomes slow.

## Unity Catalog

The governance layer. Before it, table permissions lived in the workspace,
storage permissions lived in Azure, and the two drifted.

```
metastore  (one per region, shared by workspaces)
   └── catalog       purple_prod            ← environment boundary
        └── schema   bronze / silver / gold ← layer boundary
             └── table  users, datasets…    ← grant boundary
```

Three properties make it worth the setup cost:

- **One grant, everywhere.** A grant on a table applies in every workspace
  attached to the metastore, in SQL, in notebooks, and through the JDBC
  endpoint.
- **Lineage, automatically.** Unity Catalog records which job read which table
  and wrote which other one. When a gold number is wrong, lineage tells you
  what fed it without anyone maintaining a diagram.
- **No credentials anywhere.** Storage access is brokered by the access
  connector's managed identity. Users are granted tables, not storage keys.

## What is here

| Path | Contents |
|---|---|
| `databricks.yml` | Asset Bundle root — variables and the dev/stage/prod targets |
| `resources/` | Job definitions — schedules, clusters, task dependencies |
| `unity-catalog/` | Catalog, schema, external location and grant definitions |
| `notebooks/` | The medallion pipeline, one notebook per hop |

Notebooks are stored as `.py` in Databricks source format, not `.ipynb`. This
matters: an `.ipynb` file embeds output cells, which means every run produces
a diff, code review is unreadable, and — worst — *query results end up
committed to git*. In a data platform that is a data leak, not just noise.
