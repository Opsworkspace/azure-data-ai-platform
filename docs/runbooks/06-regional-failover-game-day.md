# Runbook 06 — Regional failover game day

**This is a planned exercise, not an incident response.**

## Why do this

Every claim in [the availability model](../architecture/02-availability-model.md)
depends on failover working. Until it has been exercised, it is a hypothesis.

Stage cannot validate it — stage is single-region. That is stated explicitly in
`environments/stage/outputs.tf` rather than quietly hoped over. So cross-region
failover is validated here, deliberately, in production, at a time you choose.

> The alternative is validating it at 3am on a date chosen by Azure.

## Before you start

**Announce it.** A game day that surprises the on-call engineer is an incident.

Checklist:

- [ ] Scheduled in a low-traffic window
- [ ] On-call, support and leadership informed
- [ ] Error budget has headroom — check consumption first
- [ ] Someone designated to call it off, and everyone knows who
- [ ] Rollback (restore origin priority) understood by everyone present
- [ ] A shared document open for real-time notes

**Do not run a game day with less than 50% of the error budget remaining.**
The exercise itself spends budget, and doing it while already constrained turns
a controlled test into a real incident.

## Hypotheses to test

State them **before** you start, so the exercise can fail:

| # | Hypothesis | Measure |
|---|---|---|
| 1 | Front Door detects the failure within 90 s | Probe log → access log shift |
| 2 | Error rate stays within budget during failover | < 0.72% for < 5 min |
| 3 | The surviving region absorbs full load without scaling failure | HPA reaches steady state |
| 4 | Cosmos serves writes from the surviving region | Zero write failures |
| 5 | Recovery on restore is clean | Traffic rebalances, no errors |

Write the number you *expect* next to each. Being wrong is the most valuable
outcome available.

## The exercise

### Phase 1 — baseline (15 min)

```kusto
AppRequests
| where TimeGenerated > ago(30m)
| extend Region = tostring(Properties["cloud.region"])
| summarize Requests = count(),
            ErrorRate = 100.0 * countif(Success == false) / count(),
            P99 = percentile(DurationMs, 99)
          by Region, bin(TimeGenerated, 1m)
| render timechart
```

Record: requests/sec per region, error rate, p99, replica counts.

### Phase 2 — induce the failure

Start with the **least** destructive method that tests the hypothesis. The
whole point is a controlled test, and you can escalate.

**Level 1 — remove the origin (safest).** Tests Front Door routing only.

```
Portal → Front Door → Origin groups → api-origins
  → origin-centralus → Priority = 5
```

**Level 2 — fail the readiness probe.** Tests the full detection path: the
application reports unready, the probe fails, Front Door reacts. This is the
most realistic test of the mechanism you actually rely on.

```bash
az aks command invoke -g purple-data-prod-cus-rg -n purple-plat-prod-cus-aks \
  --command "kubectl scale deployment/purple-api -n purple --replicas=0"
```

**Level 3 — network partition.** Closest to a real regional failure. Only once
levels 1 and 2 have passed cleanly on previous game days.

```bash
# Add a deny-all NSG rule on the Central US spoke's AKS subnets.
```

### Phase 3 — observe (record everything with timestamps)

| Time | Observation |
|---|---|
| T+0 | Failure induced |
| T+? | First probe failure in `FrontDoorHealthProbeLog` |
| T+? | Traffic shift visible in `FrontDoorAccessLog` |
| T+? | Error rate peak (value: ____ ) |
| T+? | Error rate back to baseline |
| T+? | East US 2 HPA stabilised at ____ replicas |

The key query:

```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(30m)
| summarize Requests = count() by originName_s, bin(TimeGenerated, 30s)
| render timechart
```

### Phase 4 — restore

Reverse the change. Then watch for the thing people forget to check:

- Does traffic rebalance, or does it stay pinned to one region?
- Any errors *during recovery*? Recovery is a second failover and is tested
  less often than the first.
- Do the pods in the restored region become ready before receiving traffic?
  (`restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 5` exists to
  prevent a cold region being flooded.)

## Recording the result

For each hypothesis: **confirmed**, **refuted**, or **not tested**.

A refuted hypothesis is the point of the exercise. Common findings:

| Finding | Fix |
|---|---|
| Detection slower than expected | Lower `interval_in_seconds` / `successful_samples_required` |
| Surviving region could not absorb load | Raise `maxReplicas`; check node pool ceilings |
| Error spike larger than budget allows | Connection draining, or pre-scale before the shift |
| Probe passed while the region was broken | **The readiness check is too shallow.** Highest-priority fix. |
| Nobody knew who could call it off | Fix the process, not the system |

## Cadence

**Quarterly.** More often and it becomes a chore nobody prepares for; less
often and the system has changed enough that the last result no longer applies.

Run it after any change to the health check, the origin configuration, or the
regional topology — those are exactly the changes that can silently break
failover while every other test passes.
