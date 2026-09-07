# Runbooks

What to do when something is wrong, written before it is wrong.

## What makes a runbook useful

A runbook is not documentation. It is written for someone who has been woken
up, is not the person who built the system, and has about ninety seconds of
patience.

That implies a specific shape:

1. **How you know you are in this runbook** — the exact alert or symptom
2. **What to check first** — the single highest-information command
3. **The decision tree** — branch on what that command returned
4. **How to mitigate** — stop the bleeding, before understanding the cause
5. **How to verify** — how you know it worked
6. **What to do afterwards** — the follow-up that stops it recurring

**Mitigate before diagnose.** The instinct to understand the problem first is
the right instinct in every context except an active incident. Restore service,
then investigate — the evidence keeps.

## The runbooks

| # | Trigger | Runbook |
|---|---|---|
| 01 | `slo-burn-{fast,medium,slow}` alert | [Error budget burn](01-api-error-budget-burn.md) |
| 02 | `slo-latency-p99` alert | [API latency](02-api-latency.md) |
| 03 | A workload cannot reach an external host | [Egress blocked](03-egress-blocked.md) |
| 04 | `cosmos-throttling` alert | [Cosmos 429s](04-cosmos-throttling.md) |
| 05 | A Front Door origin is unhealthy | [Front Door origin](05-frontdoor-origin.md) |
| 06 | Planned exercise | [Regional failover game day](06-regional-failover-game-day.md) |

## Severity and what it means

| Sev | Meaning | Response |
|---|---|---|
| 1 | Users cannot use the product | Page immediately, any hour |
| 2 | Significant degradation, or budget burning fast | Page during business hours |
| 3 | Degraded, no user impact yet | Ticket, next working day |
| 4 | Informational | Backlog |

## Access needed

Every runbook assumes you can:

- Query Log Analytics (`Monitoring Reader`)
- Reach the private AKS API server (Bastion, or `az aks command invoke`)
- View the Azure portal for the subscription

If you cannot do these **before** an incident, fix that now. An incident is a
bad time to discover you need a PIM activation and an approver who is asleep.
