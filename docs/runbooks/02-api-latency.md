# Runbook 02 — API p99 latency above objective

**Trigger:** `purple-plat-prod-eus2-slo-latency-p99` (Sev 2)
**Objective:** p99 < 400 ms

## Why this is a separate SLO

A service that answers every request in 30 seconds is 100% available and
completely unusable. Availability alone does not describe a working system.

p99 rather than mean: the mean hides exactly the tail users notice. If 1% of
requests take 8 seconds and the rest take 50 ms, the mean is ~130 ms and looks
fine — while one user in a hundred has a bad time on every page load.

## 1. Where is the time going?

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| extend Region = tostring(Properties["cloud.region"])
| summarize P50 = percentile(DurationMs, 50),
            P95 = percentile(DurationMs, 95),
            P99 = percentile(DurationMs, 99),
            Count = count()
          by Region, Name
| order by P99 desc
```

Read the **shape**, not just the number:

| Pattern | Meaning |
|---|---|
| P50 also elevated | Everything is slow — a systemic cause (§2) |
| P50 fine, P99 high | A tail — contention, GC, throttling, cold starts (§3) |
| One endpoint only | That endpoint's own dependency (§4) |
| One region only | Regional — capacity or a dependency in that region |

## 2. Everything is slow

### Are we out of capacity?

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl top pods -n purple; kubectl get hpa -n purple"
```

If the HPA is pinned at `maxReplicas`, that is the answer. Mitigate by raising
the ceiling:

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl patch hpa purple-api -n purple -p '{\"spec\":{\"maxReplicas\":90}}'"
```

Then put it in the overlay, or it reverts on the next deploy.

### Are pods being CPU throttled?

The invisible one. Worth checking even though this platform sets no CPU limits
— a limit may have been added, or one may exist on a sidecar.

```promql
rate(container_cpu_cfs_throttled_seconds_total{namespace="purple"}[5m]) > 0
```

Any sustained non-zero value means a CPU limit is throttling the container even
when the node is idle. Remove the limit; keep the request. See the reasoning in
`platform/kubernetes/base/api-deployment.yaml`.

## 3. A tail, not a shift

### Cold starts

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| extend Pod = tostring(Properties["k8s.pod.name"])
| summarize P99 = percentile(DurationMs, 99), Count = count() by Pod
| order by P99 desc
```

If the slow pods are the newest, this is startup cost being paid by real
requests. The `lifespan` handler in `main.py` warms clients precisely to avoid
this — check it is actually running, and that the readiness probe is not
passing before warm-up completes.

### Dependency tail

```kusto
AppDependencies
| where TimeGenerated > ago(1h)
| summarize P50 = percentile(DurationMs, 50),
            P99 = percentile(DurationMs, 99),
            Failures = countif(Success == false),
            Count = count()
          by Target, Name
| order by P99 desc
```

This is usually where the answer is. Common culprits:

| Target | Likely cause |
|---|---|
| Cosmos | Cross-partition query, or 429 retries — [runbook 04](04-cosmos-throttling.md) |
| Azure OpenAI | Capacity throttling. Check TPM utilisation |
| AI Search | Too few replicas, or an expensive semantic query |

## 4. One endpoint

Look at the trace for a slow example:

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| where DurationMs > 400
| project OperationId, Name, DurationMs
| take 5
```

Then expand one:

```kusto
AppDependencies
| where OperationId == "<paste OperationId>"
| project Name, Target, DurationMs, Success
| order by DurationMs desc
```

The distributed trace shows exactly which call consumed the time. This is what
tracing is for, and why `telemetry.py` attaches `trace_id` to every log line.

## 5. Mitigations, fastest first

| Mitigation | When | How |
|---|---|---|
| Raise HPA ceiling | Pinned at max | `kubectl patch hpa` |
| Roll back | Started after a deploy | `kubectl rollout undo` |
| Reduce `rag_top_k` | The assistant is slow | ConfigMap; fewer chunks = shorter prompt |
| Add Search replicas | Search p99 high | Portal; takes ~15 min |
| Request more OpenAI TPM | Throttling | Support ticket — **not** fast |

## 6. Verify

```kusto
AppRequests
| where TimeGenerated > ago(30m)
| summarize P99 = percentile(DurationMs, 99) by bin(TimeGenerated, 5m)
| render timechart
```

Sustained below 400 ms for 15 minutes.

## 7. Afterwards

If the cause was a dependency, the fix is usually **architectural, not
operational**: precompute it (a gold table), cache it, or make it asynchronous.
Repeatedly scaling up to hide a slow dependency works until it does not, and
each round costs more.
