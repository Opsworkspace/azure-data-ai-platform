# Security model

> Defence in depth, expressed as layers that each assume the others have
> failed.

## The principle

No single control is trusted. Each layer is designed on the assumption that
the ones outside it have already been bypassed.

```
┌─ Azure Policy ─────────────────────────────────────────┐
│ subscription-wide; survives Terraform being bypassed   │
│ ┌─ Network ────────────────────────────────────────┐   │
│ │ no public endpoints, private DNS, NSG, firewall  │   │
│ │ ┌─ Identity ─────────────────────────────────┐   │   │
│ │ │ no credentials; least-privilege RBAC       │   │   │
│ │ │ ┌─ Admission control ──────────────────┐   │   │   │
│ │ │ │ PSA restricted + Gatekeeper          │   │   │   │
│ │ │ │ ┌─ Workload ─────────────────────┐   │   │   │   │
│ │ │ │ │ non-root, read-only FS, no caps │  │   │   │   │
│ │ │ │ │ ┌─ Application ──────────────┐  │   │   │   │
│ │ │ │ │ │ per-user filter, validation │ │   │   │   │
│ │ │ │ │ └────────────────────────────┘  │   │   │   │
│ │ │ │ └─────────────────────────────────┘   │   │   │
│ │ │ └──────────────────────────────────────┘   │   │
│ │ └────────────────────────────────────────────┘   │
│ └──────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────┘
```

## Layer by layer

### Azure Policy — outside Terraform

Terraform governs what Terraform creates. Policy governs what **exists**.

The gap between them is where real incidents live: a resource created in the
portal during an incident, another team deploying into the same subscription, a
resource created by an Azure service on your behalf.

`platform/policies/` covers no public IPs, no public network access on PaaS,
required tags, and diagnostic settings. Every effect defaults to `Audit` — a
`Deny` assigned to a subscription that already contains non-compliant resources
blocks the *next legitimate change* to them, which is how a policy rollout
becomes an outage during someone else's deployment.

### Network

Covered in [network topology](03-network-topology.md). The property: nothing is
publicly reachable except Front Door and Bastion, and that is enforced at the
resource level (`public_network_access_enabled = false`), not merely
firewalled.

### Identity

Covered in [identity and RBAC](04-identity-and-rbac.md). The property: there
are no application credentials to steal.

### Admission control

Two mechanisms, deliberately both:

| | Pod Security Admission | Gatekeeper / OPA |
|---|---|---|
| Cost | Free, built in | A webhook in the request path |
| Expresses | The classic container escapes | Anything organisation-specific |
| Configured by | A namespace label | Constraint templates |

PSA `restricted` handles privileged containers, host namespaces, hostPath, and
running as root. Gatekeeper handles registries, probes, resource limits and the
workload-identity label.

**Every constraint starts in `dryrun`.** A constraint that blocks on day one
blocks the deployment someone needs during an incident, and the response is to
disable the whole policy engine.

### Workload

| Setting | Prevents |
|---|---|
| `runAsNonRoot`, `runAsUser: 10001` | Escapes that require root |
| `readOnlyRootFilesystem: true` | Persistence by writing to the filesystem |
| `capabilities: drop: [ALL]` | Every Linux capability |
| `allowPrivilegeEscalation: false` | setuid escalation |
| `automountServiceAccountToken: false` | The legacy non-expiring token |
| NetworkPolicy default-deny | Lateral movement |
| IMDS (`169.254.169.254`) blocked | Pod stealing the **node's** identity |

The image is built to match: multi-stage, so the runtime has no compiler, no
pip and no build tooling; application code owned by root and run as a
non-root user, so an attacker with code execution cannot rewrite it.

### Application

The layer no infrastructure control can substitute for.

`services/api/purple_api/rag.py` contains the platform's sharpest security
boundary, and it is one line:

```python
filter=f"userId eq '{user_id.replace(chr(39), chr(39) * 2)}'"
```

Without it, a vector search returns the nearest chunks from **anyone's**
documents, and the model summarises another customer's confidential data
fluently and convincingly. This is the defining data-leak pattern of enterprise
RAG, and it happens because the filter is easy to forget and its absence is
invisible in testing — with one tenant's data in the index, an unfiltered
search returns exactly the right answers.

Four defences, in order of reliability:

1. The filter is applied **server-side**, from the authenticated principal
2. `user_id` comes from a validated token, never from the request body
3. The API's identity holds `Search Index Data Reader` — it cannot write or
   poison the index
4. A regression test asserts on the source itself, so deleting the filter fails
   CI

**The prompt is not a security control.** The system prompt instructs the model
to use only the provided context, which reduces hallucination. It does not
prevent leakage: a model can be talked into using whatever is in its context
window. Retrieval-level restriction is not bypassable, because the data never
arrives.

## Data protection

| Control | Where |
|---|---|
| Encryption at rest | Platform-managed keys everywhere; CMK documented and not enabled |
| Encryption in transit | TLS 1.2 minimum; `https_traffic_only_enabled` |
| Host encryption | `host_encryption_enabled` on every node pool |
| Soft delete | Key Vault 90 days, blobs 30 days, containers 30 days |
| Point-in-time restore | Cosmos continuous backup, 30 days |
| Versioning | Blob versioning + change feed |
| Row/column security | Unity Catalog row filters and column masks |

## Audit

The logs that answer "what happened", and why each matters:

| Log | Answers |
|---|---|
| Key Vault `AuditEvent` | Was this credential accessed during the incident window? |
| Bastion `BastionAuditLogs` | Who connected to which private host, when? |
| Firewall `AZFWApplicationRule` | Where did this workload try to connect? |
| Cosmos `DataPlaneRequests` | Which query caused the throttling? |
| Databricks `unityCatalog` | Who read which table? |
| ACR `RepositoryEvents` | What image changed, and when? |
| Entra sign-in logs | Which identity did this, from where? |

All are worthless if enabled after the incident. That is why every module
enables them at creation.

## What this design does *not* protect against

Stating the gaps honestly is part of the model:

- **A malicious insider with platform-engineer rights.** They hold
  `ALL PRIVILEGES` on the catalog and cluster-admin. Mitigation is PIM,
  approval workflows and audit — not prevention.
- **A compromised dependency in the image.** Trivy scans for known CVEs; a
  novel supply-chain attack passes. Image signing and admission verification
  would narrow this and are documented but not enabled.
- **A logic bug in the application.** No infrastructure control substitutes for
  the per-user filter being correct.
- **Azure itself.** A compromise of the platform is out of scope for any
  customer-side control.

## Related

- [`SECURITY.md`](../../SECURITY.md) — reporting policy
- `platform/policies/`, `platform/kubernetes/policy/`
- ADR: [0007 — secrets handling](../adr/0007-secrets-handling.md)
