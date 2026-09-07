# Disaster recovery

> Failure domains, honest RTO/RPO, and what is genuinely unrecoverable.

## RPO and RTO

| Term | Question | Target here |
|---|---|---|
| **RPO** — Recovery Point Objective | How much data can we lose? | **0** for operational data |
| **RTO** — Recovery Time Objective | How long can we be down? | **< 5 minutes** for a regional failure |

Both are per-failure-mode. A single number for "the platform" is meaningless:
losing a region and losing the Cosmos account are different events with
different answers.

## Failure domains, smallest to largest

| Domain | Mitigation | RTO | RPO |
|---|---|---|---|
| One pod | Multiple replicas, readiness probe | seconds | 0 |
| One node | Cluster autoscaler reschedules | ~1 min | 0 |
| One availability zone | Zone-redundant node pools, topology spread, ZRS/GZRS | ~1 min | 0 |
| **One region** | Front Door failover, Cosmos multi-region writes | **~1 min** | **0** |
| Cosmos account | Continuous backup, point-in-time restore | **hours** | up to 30 days back |
| Lakehouse account | GZRS + soft delete + versioning | hours | 0-15 min |
| Terraform state | Blob versioning, GZRS | ~30 min | 0 |
| Subscription | **Not mitigated** | — | — |

The rows in bold are the ones the architecture is built for. The rest are worth
being honest about.

## Regional failure — the designed-for case

This is the only failure the platform handles automatically.

```
1. Region's dependencies become unreachable
2. /healthz/ready returns 503 on every pod there
3. Front Door health probe fails (30s interval, 3 of 4 samples)
4. Origin removed from rotation           ← ~60 seconds total
5. All traffic served by the surviving region
6. Cosmos continues accepting writes there (multi-region writes)
```

**No DNS change is involved.** That is the whole reason Front Door was chosen
over Traffic Manager: DNS-based failover is bounded below by record TTL plus
client-side caching, which in practice means minutes and, with badly-behaved
resolvers, much longer.

RTO is a function of the **probe settings**, not of DNS:

```
interval (30s) × samples required  ≈  60-90 seconds
```

RPO is 0 because Cosmos accepts writes in both regions and replicates
continuously.

**This is validated by game day, not by stage.** Stage is single-region, and
`environments/stage/outputs.tf` says so explicitly rather than quietly hoping
otherwise. See [runbook 06](../runbooks/06-regional-failover-game-day.md).

## Data recovery

### Cosmos DB — continuous backup

Point-in-time restore to **any second** in the last 30 days.

```bash
az cosmosdb restore \
  --target-database-account-name purple-cosmos-restored \
  --account-name purple-data-prod-eus2-cosmos-000000 \
  --restore-timestamp "2026-09-05T14:30:00Z" \
  --location eastus2
```

Two things worth knowing before you need them:

- **Restore creates a NEW account.** It does not restore in place. The
  application must be repointed, which is a config change and a deployment.
- **It takes hours**, not minutes, for a large account.

So Cosmos restore is the answer to "a bad deploy corrupted data gradually over
three days" — which continuous backup handles well and nothing else does — and
not to "the region is down".

### Lakehouse

Three independent mechanisms:

| Mechanism | Recovers from |
|---|---|
| GZRS replication | Zone or region loss |
| Blob versioning | An overwrite — restore the previous version |
| Soft delete (30 days) | A deletion |
| Delta time travel | A bad transform — `VERSION AS OF` |

Delta time travel is the one used most often in practice, because the common
failure is not "the storage failed" but "the job wrote wrong data".

```sql
-- What did this table look like before the bad run?
SELECT * FROM purple_prod.silver.datasets VERSION AS OF 41;

-- Put it back.
RESTORE TABLE purple_prod.silver.datasets TO VERSION AS OF 41;
```

> The time-travel window is bounded by `VACUUM RETAIN 168 HOURS`. Seven days.
> Vacuuming with a shorter retention destroys older versions, which is why
> Delta refuses under 168 hours without an explicit override.

**And the deeper safety net:** silver and gold are fully derivable from bronze.
The genuinely irreplaceable layer is bronze, which is append-only and never
edited — that is the whole reason for the medallion split.

### Terraform state

Blob versioning on the state container. A corrupted state write is a
one-minute restore to the previous version rather than a rebuild.

```bash
az storage blob list --container-name tfstate --include v \
  --account-name <state-account> --auth-mode login
# then copy the good version over the current one
```

## What is genuinely unrecoverable

Being explicit about this is more useful than an optimistic table.

| Scenario | Why |
|---|---|
| **Subscription deleted** | 30-day recovery window via support, but resource IDs change. Practically: rebuild from Terraform, restore data from backups. Only a multi-subscription design mitigates it, and this platform is single-subscription. |
| **Tenant compromise at Global Admin level** | Every control in this platform assumes Entra is trustworthy. Mitigation is PIM, Conditional Access and break-glass account hygiene — organisational, not architectural. |
| **Bronze deleted beyond soft-delete retention** | Silver and gold are derivable; bronze is not. It is the one layer with no upstream. |
| **A logic bug that corrupts data slowly** | Recoverable via Cosmos PITR or Delta time travel *if noticed inside the window*. Outside it, the correct data no longer exists anywhere. |

That last row is the one that should worry you most, and it is an argument for
data quality checks — the quarantine mechanism in the silver transform — rather
than for more backups.

## Rebuilding from scratch

The realistic sequence if a subscription were lost:

```bash
# 1. Bootstrap state (~10 min)
cd infra/terraform/bootstrap && terraform apply

# 2. Infrastructure (~45-60 min; AKS and Databricks dominate)
cd ../environments/prod
terraform init -backend-config=../../backend.hcl
terraform apply

# 3. Platform layer (~10 min)
kustomize build platform/kubernetes/overlays/prod | kubectl apply -f -

# 4. Data restore (hours)
#    Cosmos: az cosmosdb restore
#    Lakehouse: re-derive silver/gold from bronze if bronze survived

# 5. Vector index rebuild (hours)
#    databricks jobs run-now --job-id <medallion-pipeline>
```

**Realistic total: 4-8 hours**, dominated by data restore, not by
infrastructure.

That gap is the point: the infrastructure is code and rebuilds in an hour. The
data is not, and it does not.

## What is NOT tested

Honest gaps:

- Full subscription rebuild has never been exercised end to end
- Cosmos point-in-time restore has never been exercised
- Recovery *from* the secondary region back to the primary is tested only in
  game days

A DR plan that has never been executed is a hypothesis. The quarterly game day
covers regional failover; the others should be added as tabletop exercises at
minimum.

## Related

- [Availability model](02-availability-model.md)
- [Runbook 06 — regional failover game day](../runbooks/06-regional-failover-game-day.md)
- `infra/terraform/bootstrap/README.md` — state recovery
