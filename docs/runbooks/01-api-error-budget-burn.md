# Runbook 01 — API error budget burn

**Triggers:** `purple-plat-prod-eus2-slo-burn-fast` (Sev 1),
`-slo-burn-medium` (Sev 2), `-slo-burn-slow` (Sev 3)

## What this means

The API is failing requests fast enough to exhaust the monthly error budget
early.

| Alert | Burn rate | Error rate | Budget consumed |
|---|---|---|---|
| fast | 14.4× | > 0.72% | 2% in 1 hour |
| medium | 6× | > 0.30% | 5% in 6 hours |
| slow | 3× | > 0.15% | 10% in 1 day |

The budget is **21.6 minutes per 30 days** (99.95% SLO). A `fast` alert means
roughly 26 seconds of it went in the last hour.

## 1. Is it one region or both?

The single highest-information query. Run it first — it splits the problem in
half.

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| extend Region = tostring(Properties["cloud.region"])
| summarize Total = count(),
            Failed = countif(Success == false),
            ErrorRate = 100.0 * countif(Success == false) / count()
          by Region, bin(TimeGenerated, 5m)
| render timechart
```

| Result | Meaning | Go to |
|---|---|---|
| One region only | Regional problem. **Failover is the mitigation.** | §2 |
| Both regions | Global: a dependency, a deploy, or the data plane | §3 |

## 2. One region failing

### Mitigate first

Front Door should already be removing it automatically — the readiness probe
should be failing. Confirm:

```kusto
AzureDiagnostics
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(30m)
| summarize Successes = countif(httpStatusCode_s startswith "2"),
            Failures  = countif(httpStatusCode_s !startswith "2")
          by originName_s, bin(TimeGenerated, 5m)
```

**If the probe is passing but the region is failing requests, that is the
real bug.** It means the readiness check is too shallow — it is reporting
healthy while the region cannot serve. Force the region out manually:

```bash
# Portal → Front Door → Origin groups → api-origins → the failing origin
#   → set Priority to 5 (higher number = lower preference)
# Effective within ~60 seconds. No DNS change involved.
```

Then raise a follow-up to fix the probe. A shallow probe is a latent outage.

### Then diagnose

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl get pods -n purple -o wide"
```

Look for: `CrashLoopBackOff`, `ImagePullBackOff`, pods `Running` but not
`Ready` (a readiness failure — check which dependency), or all pods on nodes in
one zone.

```bash
# Which dependency is failing readiness?
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl exec -n purple deploy/purple-api -- curl -s localhost:8000/healthz/ready"
```

The response names the failing dependency and its latency — that is why
`health.py` returns a structured body rather than a bare status code.

## 3. Both regions failing

Global. Three candidates, in order of likelihood.

### 3a. A deployment

```kusto
ContainerImageInventory
| where TimeGenerated > ago(6h)
| distinct Image, ImageTag
```

Correlate the first failure with the rollout time. If they match:

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl rollout undo deployment/purple-api -n purple"
```

**Roll back first, investigate after.** Repeat in the second region.

### 3b. A shared dependency

Cosmos and the vector index are shared across regions, so they fail globally.

```kusto
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| summarize count() by StatusCode, bin(TimeGenerated, 5m)
```

- Many `429` → see [runbook 04](04-cosmos-throttling.md)
- Many `503` / timeouts → check Azure Service Health
- `401` / `403` → an identity or role assignment changed

### 3c. Azure itself

```
Portal → Service Health → Health alerts
```

If it is a platform outage, mitigation is limited: confirm the design degrades
correctly, post an update, and track the Microsoft incident. Record it — a
platform incident still spends your error budget, and that is worth raising in
the review.

## 4. Verify

```kusto
AppRequests
| where TimeGenerated > ago(15m)
| summarize ErrorRate = 100.0 * countif(Success == false) / count()
          by bin(TimeGenerated, 1m)
| render timechart
```

Error rate back under 0.05% sustained for 15 minutes. The alert auto-resolves
(`auto_mitigation_enabled = true`).

## 5. Afterwards

Compute what was actually spent:

```kusto
let SLO = 0.9995;
AppRequests
| where TimeGenerated > startofmonth(now())
| summarize Total = count(), Failed = countif(Success == false)
| extend BudgetMinutes  = (1 - SLO) * 30 * 24 * 60,
         ConsumedPct    = 100.0 * (todouble(Failed) / todouble(Total)) / (1 - SLO)
| project BudgetMinutes, ConsumedPct
```

- **> 50% consumed:** feature work pauses; reliability work takes priority
- **> 100%:** change freeze except reliability fixes, until the window rolls

Write the incident review. The most valuable question is not "what broke" but
**"why did it take us N minutes to know?"** — the answer usually improves the
alerting more than the fix improves the system.
