# Availability model

> Why the SLO is **99.95%** and not 99.99%, and what that number actually
> commits the platform to.

## What an SLO is, precisely

Three terms that get used interchangeably and are not the same thing:

| Term | Meaning | Example |
|---|---|---|
| **SLI** | *Service Level Indicator* — a measurement | The proportion of HTTP requests returning < 500 |
| **SLO** | *Objective* — a target for the SLI, internal | 99.95% of requests succeed over 30 days |
| **SLA** | *Agreement* — a contractual promise with penalties | 99.9% or the customer gets credits |

The SLA is always **looser** than the SLO. If they were equal, missing the
objective by any margin would cost money. The gap between them is the margin
in which a team can miss its own target and fix it before a customer is owed
anything.

This platform's SLO is 99.95%. A corresponding SLA would be 99.9%.

## The error budget

```
Availability target       99.95%
Window                    30 days = 43,200 minutes
Permitted failure         0.05% × 43,200 = 21.6 minutes
```

**21.6 minutes per month.** That is the error budget: the amount of failure
the platform is *allowed* to have.

The framing matters more than it sounds. An error budget is not a threshold
you try never to touch — it is a resource you are expected to spend. A team
that ends every month with 100% of its budget unspent is a team that is
shipping too slowly. A team that exhausts it by the 10th has to stop shipping
features and fix reliability. That is the entire policy, and it replaces
arguing about whether to prioritise reliability with measuring it.

| Target | Downtime/month | Downtime/year |
|---|---|---|
| 99% | 7.2 hours | 3.65 days |
| 99.9% | 43.2 minutes | 8.76 hours |
| **99.95%** | **21.6 minutes** | **4.38 hours** |
| 99.99% | 4.32 minutes | 52.6 minutes |
| 99.999% | 26 seconds | 5.26 minutes |

Read the last row carefully. 99.999% permits 26 seconds of failure *per
month*. A single Kubernetes rolling deployment that goes slightly wrong costs
more than that. Five nines is not a configuration choice; it is an
architectural commitment that forbids most forms of change.

## Why not 99.99%

Because the architecture cannot deliver it, and committing to a number the
architecture cannot deliver is worse than committing to an honest one.

### Composing dependency availability

When a request requires *every* component in a chain to work, availabilities
multiply:

```
A_total = A₁ × A₂ × A₃ × … × Aₙ
```

The platform's hard dependencies on the request path, with Microsoft's
published SLAs:

| Component | SLA | Notes |
|---|---|---|
| Azure Front Door (Premium) | 99.99% | Global anycast |
| AKS control plane (Standard, AZs) | 99.95% | Free tier has **no SLA at all** |
| Cosmos DB (multi-region, session) | 99.999% | Reads and writes, multi-region |
| Azure OpenAI | 99.9% | *Not* on the critical path — see below |
| Entra ID | 99.99% | Token validation |
| Private DNS / networking | ~99.99% | No published SLA; assumed |

Naive multiplication of the hard dependencies:

```
0.9999 × 0.9995 × 0.99999 × 0.9999 × 0.9999
  = 0.99919  →  99.919%
```

**99.92%.** That is below 99.95%, before the application has failed once, and
before any deployment, configuration error, or human mistake.

### How the design claws it back above 99.95%

The multiplication above is pessimistic in one important way: it assumes every
dependency failure is a *total* failure of the request path. Two design
choices break that assumption.

**1. Regional independence.** The AKS control plane's 99.95% applies per
cluster. Two clusters in two regions, with Front Door failing over between
them, fail together only if both fail simultaneously:

```
A = 1 − (1 − 0.9995)²  =  1 − 0.00000025  =  99.999975%
```

The AKS control plane effectively leaves the calculation. This is the single
largest reason the platform is dual-region — not disaster recovery, but
removing a single-region dependency from the availability product.

*The caveat:* this arithmetic assumes the two regions fail **independently**.
They do not, entirely. A global Entra outage, a bad Front Door configuration,
or a Cosmos account-level problem hits both. Correlated failure is why the
answer is not "add regions until you reach five nines" — beyond two regions
the correlated component dominates, and each additional region adds cost and
operational surface for a shrinking benefit.

**2. Graceful degradation.** Azure OpenAI's 99.9% is deliberately *not* on the
critical path. Its readiness check is marked non-critical
(`services/api/purple_api/health.py`), so when it fails the assistant returns an
error and everything else — dataset browsing, uploads, the entire rest of the
API — keeps working. The SLO measures whether the API served requests, not
whether every feature was perfect.

Composing the revised figures:

```
Front Door   0.9999
AKS (dual)   0.99999975
Cosmos       0.99999
Entra        0.9999
Network      0.9999
             ─────────
             0.99969  →  99.969%
```

**99.97% theoretical ceiling.** An SLO of 99.95% leaves roughly 0.02% of
headroom for the thing the arithmetic cannot model: our own bugs, our own
deployments, and our own mistakes.

That headroom is the honest part of the number. Committing to 99.99% would
mean committing to a target *above* the platform's theoretical ceiling, which
guarantees the SLO is missed and teaches everyone that the SLO does not mean
anything.

## What the SLO commits the platform to

| Requirement | Follows from |
|---|---|
| Two regions, active-active | Removing per-region control-plane dependency |
| Zone redundancy in each region | Zone failure must not be a regional failure |
| AKS Standard tier | Free tier has no control-plane SLA |
| Cosmos multi-region writes | Write availability during a regional failure |
| `maxUnavailable: 0` on rollouts | A deployment must not spend error budget |
| PodDisruptionBudgets | A node drain must not spend error budget |
| Deep readiness probes | Failover must trigger on real unhealth |
| Burn-rate alerting | Budget exhaustion must be noticed before it happens |

Every one of these is expensive. That is the point of writing the number down
first: the SLO is what justifies the cost, and a platform that cannot state
its SLO cannot justify anything.

## Measuring it

The SLI is defined in `infra/terraform/modules/observability/alerts.tf`:

```kusto
AppRequests
| summarize Total = count(), Failed = countif(Success == false)
| extend ErrorRate = todouble(Failed) / todouble(Total)
```

Two decisions inside that query are worth noting.

**Request-based, not time-based.** "Minutes of downtime" requires deciding
what makes a minute "down" — one failed request? fifty percent? Counting
requests avoids the question and weights by actual user impact: a failure
during peak traffic costs more budget than one at 3am, which is correct.

**Measured at the application, not at the edge.** Front Door's own metrics
would include client-side network failures the platform cannot control.
Measuring at the origin measures what the platform is actually responsible
for.

## Related

- Alert thresholds and burn-rate arithmetic: `infra/terraform/modules/observability/alerts.tf`
- Readiness and failover mechanics: `services/api/purple_api/health.py`
- Failover behaviour: `infra/terraform/modules/front-door/main.tf`
- Runbook: [`docs/runbooks/01-api-error-budget-burn.md`](../runbooks/01-api-error-budget-burn.md)
