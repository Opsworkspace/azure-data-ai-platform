# Identity and RBAC

> How a platform ends up with **zero** application credentials, and what
> replaces them.

## The claim

There is no client secret, connection string, API key, SAS token, or
certificate anywhere in this platform. Not stored in Key Vault, not injected
by a pipeline, not held in a Kubernetes Secret.

This is not secret *management*. It is secret *elimination*, and the two are
frequently confused. Putting a password in Key Vault is an improvement over
putting it in a config file; it does not change the fact that a long-lived
credential exists, can be exfiltrated, and grants access to whoever holds it.

## Workload Identity Federation

The mechanism that makes it possible.

### The problem it solves

A pod needs to read from Cosmos DB. The traditional answer is a connection
string in a Kubernetes Secret. That secret must be created, distributed,
rotated, and kept out of git — and it is valid for anyone who obtains it, from
anywhere, indefinitely.

### How federation replaces it

```
┌──────────────────────────────────────────────────────────────┐
│ 1. AKS runs an OIDC issuer. Every pod's service account      │
│    token is a signed JWT naming its namespace and SA:        │
│      sub: system:serviceaccount:purple:purple-api              │
├──────────────────────────────────────────────────────────────┤
│ 2. A managed identity in Entra is configured to TRUST that   │
│    issuer, for that ONE subject:                             │
│      issuer:  https://…oic.prod-aks.azure.com/…              │
│      subject: system:serviceaccount:purple:purple-api          │
│      audience: api://AzureADTokenExchange                    │
├──────────────────────────────────────────────────────────────┤
│ 3. The pod presents its SA token to Entra and receives an    │
│    Azure access token in exchange.                           │
├──────────────────────────────────────────────────────────────┤
│ 4. That token is scoped, expires in ~1 hour, and is only     │
│    obtainable by a pod in the right namespace with the       │
│    right service account.                                    │
└──────────────────────────────────────────────────────────────┘
```

**There is nothing to steal at rest.** An attacker who exfiltrates the entire
cluster state gets tokens that expire within the hour and cannot be replayed
from outside the cluster.

### The four things that must agree

A mismatch in any one produces `AADSTS70021: No matching federated identity
record found`, an error that names none of them:

| Where | Value |
|---|---|
| Terraform `azurerm_federated_identity_credential.subject` | `system:serviceaccount:purple:purple-api` |
| Kubernetes `ServiceAccount` name and namespace | `purple-api` in `purple` |
| `ServiceAccount` annotation `azure.workload.identity/client-id` | the identity's client id |
| Pod label `azure.workload.identity/use` | `"true"` |

The pod label is the one most often missed. Without it, the mutating webhook
never injects the projected token, `DefaultAzureCredential` silently falls
through to the next method in its chain, and the failure happens at the first
Azure call rather than at pod start. `platform/kubernetes/policy/require-workload-identity.yaml`
rejects it at admission instead.

## DefaultAzureCredential

The client-side half. It walks an ordered chain and uses the first method that
works:

| Order | Method | Where it succeeds |
|---|---|---|
| 1 | Environment variables (SP secret) | **Not used** — no secret exists |
| 2 | **Workload identity** | In the cluster |
| 3 | Managed identity (IMDS) | On a VM |
| 4 | Azure CLI / Developer CLI | On a developer's laptop |

The same code runs everywhere with no configuration branch. A developer runs
`az login` and the application works with *their* identity; a pod presents its
token and works with *its* identity.

> **Blocking IMDS.** `169.254.169.254` is excluded in the NetworkPolicy. It was
> historically how a pod could steal the *node's* managed identity — a
> privilege escalation from pod to node. Workload identity removes any need
> for it, so blocking it closes the path.

## The authorisation model

Authentication says who you are. Authorisation says what you may do. The
platform's complete authorisation model lives in
`infra/terraform/environments/*/identity.tf`.

### Principles

**Least privilege, at the narrowest scope that works.** Roles are granted on a
single resource, not on the resource group.

**Built-in roles over custom ones.** A custom role is a maintenance burden and
drifts from Azure's own updates as services add operations.

**No `Owner`, anywhere, for any workload.** `Owner` includes the right to
grant roles, so any principal with it can escalate to anything. `Contributor`
plus `User Access Administrator` is the auditable equivalent when genuinely
needed — which is far rarer than people assume.

**Groups, never individuals.** A person who leaves should lose access by
leaving the group, not by someone remembering to edit Terraform.

### The actual grants

| Identity | Role | Scope | Why exactly this |
|---|---|---|---|
| `api` | Cosmos DB Built-in Data Contributor | the Cosmos account | Reads and writes user state |
| `api` | Cognitive Services OpenAI **User** | the OpenAI account | Can invoke models; cannot create or delete deployments |
| `api` | Search Index Data **Reader** | the Search service | Retrieves only — never writes to the index |
| `api` | Key Vault Secrets **User** | the regional vault | Read only; the API never writes a secret |
| `worker` | Search Index Data **Contributor** | the Search service | The **only** identity that may write to the index |
| `worker` | Storage Blob Data Contributor | the lakehouse | Writes uploads into bronze |
| `diagnostics` | Cosmos DB Account **Reader** | the Cosmos account | Metrics and metadata; grants **no** data-plane read |

The API/worker split on the search index is a deliberate blast-radius control:
a full compromise of the public-facing API cannot poison the vector index that
feeds the assistant.

### Two RBAC systems that look like one

A recurring source of confusion, worth stating plainly:

| Service | Control plane role | Data plane role |
|---|---|---|
| Cosmos DB | `Cosmos DB Account Reader` — read *metadata* | `Cosmos DB Built-in Data Contributor` — read *documents* |
| Storage | `Contributor` — manage the *account* | `Storage Blob Data Contributor` — read *blobs* |
| AI Search | `Search Service Contributor` — manage *indexes* | `Search Index Data Reader` — read *documents* |
| Key Vault | `Contributor` — manage the *vault* | `Key Vault Secrets User` — read *secrets* |

Granting `Contributor` on a storage account and expecting to read blobs
produces a 403 whose message does not explain why. The left column never
implies the right.

## Kubernetes RBAC

`local_account_disabled = true` and `azure_rbac_enabled = true`.

The first removes the cluster-admin certificate that bypasses Entra entirely —
a credential answering to no identity provider, handed out by
`az aks get-credentials --admin` to anyone with Contributor on the cluster.

The second makes Kubernetes permissions ordinary Azure role assignments, so
they are visible to Resource Graph, grantable through PIM with time limits and
approval, and revoked automatically when someone leaves the Entra group.

## Related

- `infra/terraform/modules/identity/` — the federation and role assignments
- `platform/kubernetes/base/serviceaccount.yaml` — the Kubernetes half
- `services/api/purple_api/clients.py` — `DefaultAzureCredential` in practice
- ADR: [`0007-secrets-handling.md`](../adr/0007-secrets-handling.md)
