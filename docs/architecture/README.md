# Architecture

How the platform works, and why it works that way.

| # | Document | Covers |
|---|---|---|
| 01 | [System overview](01-system-overview.md) | The product, its requirements, the request and data paths |
| 02 | [Availability model](02-availability-model.md) | Where 99.95% comes from, and why not 99.99% |
| 03 | [Network topology](03-network-topology.md) | Hub-spoke, forced tunnelling, private endpoints, the DNS trap |
| 04 | [Identity and RBAC](04-identity-and-rbac.md) | Workload identity federation; zero credentials |
| 05 | [Compute platform](05-compute-platform.md) | AKS decisions that are expensive to reverse |
| 06 | [Data platform](06-data-platform.md) | Lakehouse, Delta, medallion, Unity Catalog |
| 07 | [Observability](07-observability.md) | Three signals, SLO burn-rate alerting |
| 08 | [Cost and FinOps](08-cost-and-finops.md) | What each environment costs, and the levers |
| 09 | [Security model](09-security-model.md) | Defence in depth, layer by layer, including the gaps |
| 10 | [CI/CD](10-cicd.md) | What runs here, what a funded environment adds |
| 11 | [Disaster recovery](11-disaster-recovery.md) | Failure domains, honest RTO/RPO, what is unrecoverable |

## Suggested order

**To understand the system:** 01 → 02 → 03 → 04, then
`infra/terraform/environments/prod/main.tf`, which wires everything together in
one readable file.

**To evaluate the engineering:** 02 (the arithmetic), 09 (the gaps it admits),
then the [ADRs](../adr/) — particularly the *Alternatives considered* sections.

**To operate it:** the [runbooks](../runbooks/).
