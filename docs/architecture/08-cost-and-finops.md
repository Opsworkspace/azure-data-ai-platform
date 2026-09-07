# Cost and FinOps

> Why cost is a platform engineering concern, and what each environment
> actually costs.

## The framing

Cost is a **design constraint**, not an afterthought for finance. An
architecture nobody can afford to run is not a good architecture, however
elegant.

The platform engineering contribution is not "spend less". It is:

1. Make cost **visible** — per team, per environment, per workload
2. Make cost **attributable** — every resource belongs to someone
3. Make the expensive choices **explicit** — with the lever documented
4. Make waste **easy to find** — and easy to remove

Tagging (`cost_center`, `workload`, `environment`) is the mechanism for the
first two, and is enforced by `platform/policies/require-tags.json`. An
untagged resource is a line on an invoice that no team will claim.

## What this platform would cost

**These are order-of-magnitude estimates for shape and comparison, not quotes.**
Actual prices vary by region, commitment, currency and the date you read this.
The point is the *ratio* between environments and the *rank order* of the line
items.

### Production — dual region, active-active

| Component | Approx/month | Note |
|---|---|---|
| Azure Firewall Premium × 2 | **$4,000** | Per-hour per-region, idle or not |
| AKS nodes (D8ds_v5, ~6-30 × 2) | $3,500 | The variable one — autoscales |
| Cosmos DB (autoscale, multi-region write) | $3,000 | Multi-region writes ~2× the RU cost |
| Databricks (jobs, Photon, spot) | $1,500 | Highly usage-dependent |
| Azure OpenAI (GPT-4o + embeddings) | $1,200 | Token-based; scales with users |
| Front Door Premium + WAF | $400 | Plus per-GB egress |
| AI Search (standard, 3 replicas × 2 partitions × 2 regions) | $1,200 | replicas × partitions × regions |
| Log Analytics (~150 GB/day) | $800 | **Grows silently** |
| Storage (ADLS GZRS) | $300 | Plus transactions |
| ACR Premium + geo-replication | $150 | |
| Bastion × 2, public IPs, DNS | $400 | |
| Global VNet peering egress | $200 | Per GB, **both directions** |
| **Total** | **~$16,500/month** | ~$200k/year |

### Stage — single region, production fidelity

| | |
|---|---|
| Firewall Standard × 1 | $950 |
| AKS (3-10 nodes, smaller SKUs) | $700 |
| Cosmos (autoscale, single region, 1/10 throughput) | $400 |
| Front Door + WAF | $350 |
| AI Search (standard, 2 replicas) | $250 |
| Everything else | $400 |
| **Total** | **~$3,050/month** |

### Dev — single region, cost-optimised

| | |
|---|---|
| AKS Free tier, spot nodes, 1-5 | $250 |
| Cosmos **serverless** | $30 |
| ACR Premium (needed for private endpoint) | $50 |
| AI Search basic | $75 |
| Bastion Basic | $90 |
| Log Analytics (5 GB/day cap) | $50 |
| Storage LRS, misc | $55 |
| **Total** | **~$600/month** |

**Prod is ~27× dev.** That ratio is the point of `environments/dev/main.tf`
recording its trade-offs explicitly.

## The three biggest levers

### 1. Azure Firewall — $4,000/month, idle or not

The largest single line, and it is a **fixed** cost: billed per deployment-hour
per region whether or not a packet flows.

| Option | Cost | What you lose |
|---|---|---|
| Premium × 2 (current) | $4,000 | — |
| Standard × 2 | $2,000 | TLS inspection, IDPS, URL filtering |
| One firewall, both regions route to it | $2,000 | Regional independence — **do not do this** |
| NAT Gateway instead | $100 | **All egress filtering.** See [ADR 0005](../adr/0005-egress-through-firewall.md) |
| No firewall (dev) | $0 | The egress allow-list entirely |

The third row is the trap: it looks like a 50% saving and it reintroduces a
cross-region dependency into the design whose entire purpose is removing them.

### 2. Cosmos DB — throughput and write topology

| Lever | Saving | Cost |
|---|---|---|
| Drop multi-region writes | ~40% of Cosmos spend | No write availability during a regional outage |
| Manual instead of autoscale | Up to 33% | You must size for peak and page when wrong |
| Exclude unqueried paths from indexing | 20-50% of **write** RU | Nothing — this is free money |
| Serverless (dev) | ~90% | No multi-region, no autoscale, 5,000 RU/s ceiling |

The indexing one deserves emphasis: Cosmos indexes every property by default,
and indexing is charged **on write**. A document with a large unqueried payload
— a raw JSON blob, an embedding vector — can double its own write cost through
indexing nothing ever reads. `excluded_index_paths` in
`environments/prod/data-plane.tf` is the fix, and it costs nothing.

### 3. Log Analytics — the one that grows silently

Ingestion is billed per GB. Nobody notices until the bill arrives, because a
chatty new service adds telemetry without anyone deciding to.

| Lever | Saving |
|---|---|
| Commitment tier at 100 GB/day | 15-30% |
| Basic Logs table plan for high-volume, rarely-queried tables | ~80% on those tables |
| Sample `DataPlaneRequests` on Cosmos | Large; it is the highest-volume source |
| Shorter retention in Analytics + archive tier | Significant above 90 days |
| Adaptive sampling in App Insights | Proportional to traffic |

Note that production sets `daily_quota_gb = -1` (uncapped) deliberately. A cap
protects the bill by **dropping telemetry**, and the moment it matters most —
a traffic spike or an incident — is exactly when losing telemetry is most
expensive. Dev caps at 5 GB because there a runaway log is a cost bug, not an
incident.

## Waste, in the order it is usually found

1. **Dev running overnight and at weekends.** ~70% of dev compute. The
   `auto_shutdown = "true"` tag in `environments/dev/locals.tf` is what an
   automated scale-to-zero job would key off.
2. **Orphaned resources.** Disks from deleted VMs, unattached public IPs, old
   snapshots. Find with Resource Graph:
   ```kusto
   Resources
   | where type == "microsoft.compute/disks" and properties.diskState == "Unattached"
   | project name, resourceGroup, sizeGb = properties.diskSizeGB
   ```
3. **Over-provisioned node pools.** `minReplicas` set for a peak that never
   comes. Check actual utilisation before sizing.
4. **Storage never tiered.** Bronze grows forever by design. The lifecycle
   policy in `modules/lakehouse` moves it to cool at 30 days and archive at
   365.
5. **Old blob versions.** Versioning is on for recoverability; without a
   lifecycle rule to expire old versions, storage grows while the data does
   not.
6. **Idle GPU nodes.** `min_count = 0` on the AI pool exists for this. One idle
   NC-series node costs more than the entire dev environment.

## Making it visible

```kusto
// Cost by cost centre — requires the Cost Management export to Log Analytics.
Usage
| where TimeGenerated > ago(30d)
| extend CostCenter = tostring(Tags["cost_center"])
| summarize Cost = sum(PreTaxCost) by CostCenter, ResourceType
| order by Cost desc
```

Set **budgets with alerts** at 50%, 80% and 100% of the expected monthly spend,
per environment. A budget alert is the cheapest reliability control for the
bill, and unlike a hard cap it does not break anything.

## Reserved capacity and savings plans

Once usage is stable — not before — commitments cut compute meaningfully:

| Commitment | Saving | Risk |
|---|---|---|
| 1-year reserved VM instances | ~40% | Locked to VM family and region |
| 3-year reserved | ~60% | Three years is a long time in a young product |
| Azure Savings Plan (1yr) | ~30% | More flexible: applies across VM families |

**Do not commit in the first six months.** The workload shape changes, and a
reservation for the wrong VM family is money spent on nothing. Savings Plans
are the safer first step because they are not family-locked.

## Related

- Per-environment trade-offs: `infra/terraform/environments/*/locals.tf`
- Cost-relevant outputs: `environments/dev/outputs.tf` → `cost_trades_versus_prod`
- Tag enforcement: `platform/policies/require-tags.json`
- ADR: [0005 — egress through firewall](../adr/0005-egress-through-firewall.md)
