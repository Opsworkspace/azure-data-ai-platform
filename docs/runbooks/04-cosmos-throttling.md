# Runbook 04 — Cosmos DB returning 429

**Trigger:** `purple-plat-prod-eus2-cosmos-throttling` (Sev 2)
**Meaning:** more than 1% of Cosmos requests returned `429 Request rate too
large` over 15 minutes.

## Read this before touching the throughput slider

There are **two** completely different causes of 429s, with opposite fixes:

| Cause | Fix | Effect of raising RU |
|---|---|---|
| Genuine capacity exhaustion | Raise throughput | Fixes it |
| **A hot partition** | Fix the access pattern | **Does nothing, costs money** |

A single logical partition is capped at **10,000 RU/s** no matter what the
container is provisioned for. If one partition key value is taking all the
traffic, provisioning 100,000 RU/s across the container changes nothing — the
hot partition still hits its own ceiling.

Diagnose which one you have **first**. Reaching for the throughput slider is
the reflex, and half the time it is pure cost with no benefit.

## 1. Which is it?

```kusto
CDBPartitionKeyRUConsumption
| where TimeGenerated > ago(1h)
| summarize TotalRU = sum(RequestCharge) by PartitionKey, CollectionName
| order by TotalRU desc
| take 20
```

| Result | Diagnosis |
|---|---|
| RU spread fairly evenly across many keys | Genuine capacity — §2 |
| One or two keys dominating | **Hot partition** — §3 |

Cross-check against provisioned throughput:

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| summarize Total = count(),
            Throttled = countif(StatusCode == 429),
            AvgRU = avg(RequestCharge),
            MaxRU = max(RequestCharge)
          by CollectionName, bin(TimeGenerated, 5m)
| order by Throttled desc
```

## 2. Genuine capacity exhaustion

Every partition busy, total consumption near the provisioned ceiling.

### Mitigate

```bash
# Autoscale max throughput. Takes effect in seconds.
az cosmosdb sql container throughput update \
  --account-name purple-data-prod-eus2-cosmos-000000 \
  --resource-group purple-data-prod-eus2-rg \
  --database-name purple \
  --name conversations \
  --max-throughput 80000
```

Then update `environments/prod/data-plane.tf` so the next `apply` does not
revert it.

> Autoscale already scales between 10% and 100% of the ceiling automatically.
> Sustained throttling at the ceiling means the ceiling is genuinely too low.

### Then reduce demand

Raising throughput is the mitigation, not the fix. Look for:

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| where RequestCharge > 50           // a point read costs ~1 RU
| summarize count(), avg(RequestCharge) by OperationName, CollectionName
| order by avg_RequestCharge desc
```

Anything above ~10 RU for a read is suspicious. Usual causes:

- **Cross-partition query.** A query without the partition key fans out to
  every physical partition, and the charge scales with their number.
- **Indexing everything.** Indexing is charged on *write*. A large unqueried
  blob — a raw payload, an embedding vector — can double a document's write
  cost. `excluded_index_paths` in the Terraform is for exactly this.
- **Reading whole documents to use one field.** Use a projection.

## 3. Hot partition

One partition key value taking a disproportionate share.

**Raising throughput will not help.** The cap is per logical partition.

### Immediate mitigation

Options, in order of preference:

1. **Cache it.** If the hot key is one tenant's reference data, cache it in the
   application and the reads disappear.
2. **Rate limit that caller.** The Front Door WAF rate limit can be scoped.
3. **Read from the secondary region.** With multi-region writes the read load
   can be split, buying time.

### The real fix

The partition key is wrong for the access pattern, and that is not a runtime
fix — the key cannot be changed on an existing container. Changing it means
creating a new container and migrating.

Read `infra/terraform/modules/cosmosdb/main.tf`, which explains why `/userId`
was chosen over `/tenantId` precisely to avoid this. If a hot partition has
appeared under `/userId`, then either:

- a single user genuinely has extreme traffic (a bot? a runaway client
  retrying?), or
- a code path is querying with a constant or null key.

The second is far more likely and is a bug, not a capacity problem.

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| where StatusCode == 429
| summarize count() by OperationName, CollectionName
```

## 4. Check the client is retrying correctly

The Azure Cosmos SDK retries 429s automatically, honouring the
`x-ms-retry-after-ms` header. Two anti-patterns make throttling much worse:

- **Retrying immediately** rather than after the advised delay — this amplifies
  the load that caused the throttling.
- **Unlimited retries** — turns a brief slowdown into a self-inflicted outage.

## 5. Verify

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(15m)
| summarize ThrottleRate = 100.0 * countif(StatusCode == 429) / count()
          by bin(TimeGenerated, 1m)
| render timechart
```

Below 1% sustained. Note that a **small** number of 429s is normal and healthy
with autoscale — it is how the service signals that it is scaling. Zero 429s
often means you are over-provisioned.

## 6. Afterwards

- If you raised throughput, is it still needed a week later? Autoscale ceilings
  ratchet up and rarely come back down without someone checking.
- If it was a hot partition, that is a design review, not a ticket.
