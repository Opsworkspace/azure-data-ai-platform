# Observability

> The difference from monitoring, why CPU alerts are noise, and how the SLO
> becomes an alert.

## Monitoring vs observability

**Monitoring** tells you whether things you anticipated are happening. Fixed
dashboards, known thresholds, predetermined questions.

**Observability** lets you answer a question you did *not* anticipate, after
the fact, without shipping new code.

The distinction matters because incidents are, by definition, the situations
you did not anticipate. A dashboard showing CPU, memory and request count is
monitoring. Being able to ask "show me every request from users in the Central
US region that touched the assistant endpoint and took over 2 seconds, grouped
by which Cosmos partition they hit" is observability.

## Three signals, three jobs

| Signal | What it is | Answers |
|---|---|---|
| **Logs** | Discrete events with context | "What happened, and why did it fail?" |
| **Metrics** | Numeric aggregates over time | "Is it getting worse? How much?" |
| **Traces** | The causal path of one request | "*Where* in the chain did the time go?" |

They are not interchangeable. The common mistake is using logs for all three:
counting log lines to compute a rate is expensive, slow, and loses precision
under sampling.

## The three stores, and why they are separate

| Store | Holds | Why not merged |
|---|---|---|
| **Log Analytics** | Logs, KQL | The system of record. Everything correlates back here. |
| **Application Insights** | Traces, app telemetry | Workspace-based, so its data physically lives in Log Analytics and can be **joined** to infrastructure logs |
| **Azure Monitor Workspace** | Prometheus metrics | The Prometheus data model — labels, high cardinality, short retention — is genuinely different from a log store's |

Grafana sits on top of all three. It is a **view**, not a storage tier: losing
Grafana loses no data.

> **Workspace-based App Insights is not optional.** Classic App Insights stored
> data in its own silo where it could not be joined to infrastructure logs — so
> the query "show me the pod logs for the trace that produced this 500" was
> impossible. Any guide omitting `workspace_id` predates 2024.

## Structured logging

```python
# Unqueryable without a regex, and the regex breaks when the wording changes.
log.info(f"user {user_id} failed to load dataset {ds} in {ms}ms")

# Queryable by any field, forever.
log.info("dataset_load_failed", user_id=user_id, dataset_id=ds, duration_ms=ms)
```

The second produces JSON that KQL can filter, aggregate and join on. This is
why `services/api/purple_api/telemetry.py` configures `structlog` with a JSON
renderer rather than a human-readable one — these lines are read by a machine.

### Correlating logs to traces

The single highest-value logging enhancement:

```python
event_dict["trace_id"] = format(context.trace_id, "032x")
event_dict["span_id"] = format(context.span_id, "016x")
```

Without it, correlating a log line to a distributed trace means guessing by
timestamp. With it, every log line is clickable through to the full request
path.

## OpenTelemetry, and why it is worth the indirection

The instrumentation in the application is **vendor-neutral**. Only the exporter
is Azure-specific:

```python
from azure.monitor.opentelemetry import configure_azure_monitor
configure_azure_monitor(...)
```

Moving to a different backend is a change to that one file, not to every
instrumented call site. Given that observability vendors are switched more
often than databases, this is cheap insurance.

Note also that telemetry configuration is wrapped in `try/except`. If export
cannot be configured, the service **still starts and serves traffic**. A
platform that refuses to run because its monitoring is unavailable has made
monitoring a hard dependency of the product, which is backwards.

## Alerting on SLOs, not on symptoms

### Why CPU alerts are noise

`CPU > 80%` fires constantly, correlates weakly with user pain, and trains the
on-call engineer to ignore the channel. A service at 85% CPU serving every
request in 50 ms is *fine* — it is efficiently using what it was given.

The industry name for the result is **alert fatigue**, and it is why real
outages get missed. Every alert that does not correspond to user impact makes
the next alert less likely to be read.

### Burn-rate alerting

Alert on the **error budget** instead.

An SLO of 99.95% over 30 days permits 21.6 minutes of failure. **Burn rate** is
how fast you are spending it relative to the rate that would exactly exhaust
it over the window.

```
error_rate_threshold = burn_rate × (1 − SLO)
```

For 99.95%:

| Burn rate | Error rate | Budget consumed | Response |
|---|---|---|---|
| 14.4× | 0.72% | 2% in 1 hour | Page immediately |
| 6× | 0.30% | 5% in 6 hours | Page |
| 3× | 0.15% | 10% in 1 day | Ticket |

### Why two windows per alert

A short window alone is fast but flappy: one bad minute pages you. A long
window alone is stable but slow: a total outage takes hours to alert.

Pairing them gives both — and the short window is what makes the alert
**resolve** quickly once the incident ends, so the on-call engineer is not
chasing something already fixed.

### The volume floor

```kusto
| where Total > 100
```

Essential. Without it, a quiet window with 2 requests and 1 failure is a 50%
error rate and pages someone at 4am about nothing. **Every ratio-based alert
needs a volume floor.**

## What is actually collected

| Source | Signal | Note |
|---|---|---|
| AKS | Container Insights + Prometheus | `msi_auth_for_monitoring_enabled` — identity, not a workspace key |
| Firewall | `AZFWApplicationRule`, `AZFWNetworkRule`, `AZFWDnsQuery` | How "cannot reach X" is answered |
| Cosmos | `DataPlaneRequests`, `PartitionKeyRUConsumption` | RU charge and status per request; **the expensive one** |
| Front Door | Access, health probe, WAF logs | Failover and WAF false positives |
| Key Vault | `AuditEvent` | Every secret read, by every principal |
| Databricks | `unityCatalog`, `notebook`, `jobs` | Who read which table |

**Prometheus label allow-lists are empty by design.** Every Kubernetes label
promoted to a Prometheus label multiplies time-series cardinality, and
cardinality is what makes a metrics bill explode.

## Cost control

Ingestion is billed per GB and grows silently. See
[cost and FinOps](08-cost-and-finops.md) for the levers. The two that matter
most:

- **Sample `CDBDataPlaneRequests`** — it is the highest-volume source and it is
  one row per Cosmos request.
- **Use Basic Logs plans** for high-volume, rarely-queried tables — roughly 80%
  cheaper, at the cost of no alerting on those tables.

## The mistakes

**Alerting on causes rather than symptoms.** Alert on "users are experiencing
errors", then use dashboards to find why. An alert per possible cause produces
dozens of alerts and still misses the cause nobody predicted.

**No runbook link in the alert.** Every alert here has one in its `description`.
An alert without a runbook is a puzzle handed to someone at 3am.

**Turning on every log category.** Ingestion is per GB. Each module here
enables specific categories with a reason, which is also why the
`audit-diagnostic-settings.json` policy is Audit rather than
DeployIfNotExists — automatically enabling everything everywhere is a reliable
way to triple a bill overnight.

**Dashboards nobody reads.** A dashboard that is not opened during an incident
is decoration. The test is whether it answers the first question you ask.

## Related

- `infra/terraform/modules/observability/` — the workspaces and alert rules
- `infra/terraform/modules/observability/alerts.tf` — the burn-rate arithmetic
- `services/api/purple_api/telemetry.py` — instrumentation
- [Availability model](02-availability-model.md) — where the SLO comes from
- [Runbook 01](../runbooks/01-api-error-budget-burn.md)
