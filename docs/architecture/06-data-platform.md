# Data platform

> The lakehouse, the medallion architecture, and Unity Catalog.

## Lakehouse: what the word means

Two older patterns, and what each got wrong:

| | Data warehouse | Data lake |
|---|---|---|
| Storage | Proprietary, expensive | Object storage, cheap |
| Schema | Enforced | None — "schema on read" |
| Transactions | ACID | None |
| Workloads | BI and SQL | ML and data science |
| Failure mode | Cannot hold unstructured data affordably | Becomes a **data swamp** |

The lake's failure mode is the instructive one. Without schema enforcement or
transactions, a lake accumulates files nobody can interpret, half-written
outputs from failed jobs, and six versions of the same dataset with no way to
tell which is current.

A **lakehouse** is object storage plus a table format that adds transactions
and schema. Cheap storage, warehouse guarantees.

## Delta Lake: Parquet plus a transaction log

Parquet is a *file* format. Delta is a *table* format — Parquet files plus an
ordered log of what happened to them.

That log buys four things:

1. **ACID transactions.** A job that fails halfway leaves no partial data.
   With plain Parquet, readers see half-written output.
2. **Time travel.** `VERSION AS OF 42` reads the table as it was — how you
   answer "what did this report say last Tuesday" and how you recover from a
   bad write.
3. **Schema enforcement and evolution.** An unexpected column is rejected
   rather than silently creating an inconsistent table.
4. **Efficient upserts.** `MERGE INTO` on a columnar store is otherwise a full
   rewrite.

**The cost:** the log needs maintenance. `OPTIMIZE` compacts small files;
`VACUUM` expires old versions. Skipping them is how a Delta table becomes slow
and how storage grows while the row count does not. Both are in the
maintenance step of `03_gold_aggregate.py`.

> `VACUUM ... RETAIN 168 HOURS` — seven days is not arbitrary. It is the
> time-travel window, and Delta refuses shorter retentions without an explicit
> override precisely because shortening it breaks concurrent long-running
> readers.

## ADLS Gen2 is a flag

ADLS Gen2 is not a separate product. It is a storage account with
`is_hns_enabled = true` — a hierarchical namespace.

That one flag converts a flat key-value blob store into something with real
directories: atomic directory rename, POSIX-style ACLs, and directory
operations that do not cost one API call per object.

**Delta's transaction protocol depends on atomic rename.** Running Delta on a
flat blob account works but loses that guarantee under concurrent writers.

**The flag cannot be changed after creation.** Getting it wrong means migrating
every byte.

## The medallion architecture

```
        ingest              clean & conform           aggregate
source ──────────► BRONZE ──────────────────► SILVER ──────────► GOLD
                    raw                      deduplicated       business
                    immutable                schema-enforced    aggregates
```

### The question it answers

*What do you do when a number in a dashboard is wrong?*

With one layer, you cannot tell whether the source sent bad data or your
transform introduced the error — and you cannot re-run the transform, because
the original was overwritten.

With bronze preserved, you re-derive silver and gold from data you still have.

| Layer | Written by | Mutation | Recoverable? |
|---|---|---|---|
| Bronze | Ingest jobs only | **Append only, never edited** | No — this is the thing you cannot rebuild |
| Silver | Transform jobs | Merged/upserted | Yes, from bronze |
| Gold | Aggregation jobs | Overwritten freely | Yes, from silver |

The permission model enforces it: data engineers can `SELECT` on bronze but
cannot `MODIFY` it. If an engineer can write to bronze, bronze is no longer
"exactly what the source sent", and the guarantee that makes everything
downstream recoverable is gone.

### Quarantine, do not drop

The design decision in `02_silver_transform.py` most worth internalising.

The obvious approach is `.filter(is_valid)` — keep good rows, drop bad ones. It
is also wrong, because **dropped rows are silent**. Nobody notices 3% of
records vanished until a total fails to reconcile months later, by which point
the cause is unfindable.

Quarantining writes failures to a separate table *with the reason*. Data
quality becomes observable — you can alert on quarantine volume and reprocess a
fixed batch — instead of invisible.

The job also fails on a quality cliff (>5% quarantined), because continuing to
publish gold from a tenth of the expected data is worse than stopping.

### Deduplicate deterministically

Duplicates are not a bug to fix upstream. They are the expected consequence of
at-least-once delivery, which every reliable queue provides.

`dropDuplicates()` keeps an *arbitrary* row. The window function in the silver
notebook keeps the latest deterministically, with a tie-break, so the same
input always produces the same output — which is what makes the job re-runnable.

### `clusterBy`, not `partitionBy`

Hive partitioning creates one directory per distinct value. Partition by
`user_id` with a million users and you get a million directories holding a few
KB each — the **small files problem**, where listing the table costs more than
reading it.

Liquid clustering co-locates related rows *inside* files without directories,
handles skew, and — crucially — **the clustering key can be changed later
without rewriting the table**. A partition key cannot.

## Unity Catalog

Before it, table permissions lived in the workspace and storage permissions
lived in Azure, and the two drifted.

```
metastore  (one per region)
   └── catalog    purple_prod       ← ENVIRONMENT boundary
        └── schema  bronze/silver/gold ← LAYER boundary
             └── table                 ← grant boundary
```

Choosing what each level means is a governance decision. Catalog = environment
means "data scientists can read prod gold and nothing else" is **one grant**.
Using catalogs for business domains instead makes environment isolation
inexpressible.

### The three properties that justify the setup cost

1. **One grant, everywhere.** A grant applies in every workspace attached to
   the metastore, in SQL, in notebooks, and over JDBC.
2. **Lineage, automatically.** Unity Catalog records which job read which table
   and wrote which other. When a gold number is wrong, lineage tells you what
   fed it — without anyone maintaining a diagram.
3. **No credentials anywhere.** Storage access is brokered by the access
   connector's managed identity. Users are granted *tables*, not storage keys.

### Row filters and column masks

```sql
CREATE FUNCTION gold.tenant_filter(tenant_id STRING) RETURNS BOOLEAN
  RETURN is_account_group_member('purple-platform-engineers')
      OR tenant_id = current_user();
```

Enforced at query time on **every access path**. That is what makes it
trustworthy: a filter applied in a dashboard tool protects only that dashboard.

This is the SQL-side counterpart of the RAG filter in
`services/api/purple_api/rag.py`. A tenant boundary enforced on only one access
path is not a tenant boundary.

## Databricks networking

VNet injection puts cluster VMs in **your** VNet, behind your NSGs and route
tables — which is what makes it possible for a cluster to reach a private
endpoint at all.

Secure cluster connectivity (`no_public_ip = true`) means nodes have no public
IP and no inbound port. Instead the cluster opens an **outbound** connection to
the Databricks control plane and holds it open.

**The consequence people hit:** the cluster now depends on outbound
reachability to the control plane, so the firewall must allow
`*.azuredatabricks.net`. If it does not, clusters sit in `PENDING` for about
twenty minutes and then fail with a message mentioning neither the firewall nor
the relay. This is the most common Databricks networking incident, and it is
why those FQDNs are in the hub module's default allow-list.

## Notebooks as `.py`, never `.ipynb`

An `.ipynb` embeds output cells. That means every run produces a diff, code
review is unreadable, and — worst — **query results get committed to git**.

In a data platform that is a data leak, not just noise.

## Related

- `infra/terraform/modules/lakehouse/` — the storage account and lifecycle rules
- `infra/terraform/modules/databricks/` — VNet injection and the access connector
- `data/databricks/unity-catalog/` — catalogs, schemas, grants, masks
- `data/databricks/notebooks/` — the medallion pipeline
