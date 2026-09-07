# System overview

What Purple is, what it has to do, and how the pieces fit.

## The product

A Data & AI SaaS. Users upload their own datasets, ask questions about them
through a conversational assistant, and consume scheduled analytics.

Fictional, so that the *platform* is the subject. Its requirements are not
fictional — they are the requirements a real product at this scale has.

| Requirement | Target | What it forces |
|---|---|---|
| Registered users | 1,000,000 | Partition strategy, index sizing |
| Daily active users | ~120,000 | Autoscaling ranges, RU provisioning |
| Peak API throughput | 2,000 req/s | Node pool sizing, connection pooling |
| Availability SLO | 99.95% | Dual region, zone redundancy, Standard AKS |
| Latency SLO (p99) | < 400 ms | Precomputed gold tables, caching strategy |
| RPO / RTO | 0 / < 5 min | Multi-region writes, health-probe failover |
| Data residency | US, dual-region | `DataZoneStandard` model deployments |

## The request path

```
  user
    │  https://api.purple.example.com
    ▼
┌───────────────────────────────────────────┐
│ Azure Front Door Premium                  │  anycast, ~200 edges
│  WAF · rate limit · health probe · TLS    │
└──────────────────┬────────────────────────┘
                   │  routes to the nearest HEALTHY origin
       ┌───────────┴───────────┐
       ▼                       ▼
┌──────────────┐        ┌──────────────┐
│ East US 2    │        │ Central US   │       active / active
│ AKS ingress  │        │ AKS ingress  │
│   │          │        │   │          │
│   ▼          │        │   ▼          │
│ purple-api    │        │ purple-api    │       3-60 replicas, 3 zones
└───┬──────────┘        └───┬──────────┘
    │                       │
    │  all via private endpoints
    ▼                       ▼
┌─────────────────────────────────────────────┐
│ Cosmos DB      multi-region writes          │
│ AI Search      vector index, per-user filter│
│ Azure OpenAI   chat + embeddings            │
│ Key Vault      secrets via CSI              │
└─────────────────────────────────────────────┘
```

## The data path

Separate from the request path, and deliberately so. Analytics failing must
not make the API fail.

```
upload ──► bronze ──► silver ──► gold ──► AI Search index
           (raw)     (clean)   (aggregated)      │
                                   │             │
                                   ▼             ▼
                            API reads gold   assistant retrieves
```

Run nightly by a Databricks job, governed by Unity Catalog, stored as Delta
tables on ADLS Gen2.

## Component inventory

| Layer | Service | Why this one |
|---|---|---|
| Edge | Front Door Premium | Anycast failover in ~60s; DNS-based would take minutes |
| Compute | AKS, private, CNI Overlay | Pod density without VNet address exhaustion |
| Operational data | Cosmos DB | Multi-region writes; single-digit-ms point reads |
| Analytical data | ADLS Gen2 + Delta | ACID and time travel over cheap object storage |
| Governance | Unity Catalog | One grant across every access path; automatic lineage |
| Processing | Databricks | Spark without operating Spark |
| AI | Azure OpenAI + AI Search | Managed models plus hybrid vector retrieval |
| Secrets | Key Vault + CSI driver | Secrets as files, never in etcd |
| Observability | Monitor, Prometheus, Grafana | Logs, metrics and traces correlatable |
| Identity | Entra + workload identity | Zero stored application credentials |

## The five properties everything else serves

1. **Nothing is publicly reachable** except Front Door and Bastion.
2. **There are no application credentials.** Not "in Key Vault" — none.
3. **Every environment is the same code**, differing only in arguments.
4. **Failure of one region is invisible** to users within ~60 seconds.
5. **Every decision is written down** where the code that implements it lives.

## Reading order

If you are new to this repository:

1. [`00-safety-and-placeholders.md`](../00-safety-and-placeholders.md) — the contract this repo keeps
2. [`02-availability-model.md`](02-availability-model.md) — where the SLO comes from
3. [`03-network-topology.md`](03-network-topology.md) — the private network
4. [`04-identity-and-rbac.md`](04-identity-and-rbac.md) — how zero credentials works
5. `infra/terraform/environments/prod/main.tf` — every component wired together in one file
