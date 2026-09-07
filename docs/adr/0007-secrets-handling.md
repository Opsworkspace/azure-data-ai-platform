# 0007. Eliminate secrets rather than manage them

**Status:** Accepted
**Date:** 2026-09-06

## Context

The conventional maturity ladder for credentials looks like this:

1. Hard-coded in source
2. In an environment variable
3. In a Kubernetes Secret
4. In Key Vault, fetched at runtime
5. In Key Vault with automatic rotation

Most platforms aim for 4 or 5 and consider the problem solved.

It is not solved. At every rung, a **long-lived credential exists**. It can be
exfiltrated by anyone who reaches the place it is stored, it is valid from
anywhere in the world, and its blast radius is whatever it grants until
someone notices and revokes it. Rotation shortens the window; it does not
remove it.

Meanwhile Terraform state deserves particular attention: any secret Terraform
creates or reads is written to state **in plaintext**, including values marked
`sensitive`. `sensitive` controls console output, not storage.

## Decision

**The platform contains no application credentials at all.**

- Every workload authenticates with a managed identity via Workload Identity
  Federation. The pod exchanges its short-lived, audience-scoped Kubernetes
  service account token for an Azure access token.
- Every data service has key-based authentication **disabled** at the resource
  level: `shared_access_key_enabled = false` on storage,
  `local_authentication_enabled = false` on Cosmos, Search and Log Analytics,
  `local_auth_enabled = false` on Azure OpenAI, `admin_enabled = false` on ACR.
  A key would not work even if one existed.
- **Terraform creates no secrets.** The Key Vault module creates the vault and
  the role assignments, never a secret value.
- The few genuinely external secrets that would exist in a funded environment
  are mounted as files by the Secrets Store CSI driver, not stored as
  Kubernetes Secrets.

## Consequences

### What this makes easier

- There is nothing at rest to steal. Exfiltrating the entire cluster state
  yields tokens that expire within the hour and cannot be replayed from
  outside the cluster.
- No rotation process to build, schedule, or forget.
- Every access is attributable to a named identity in the Entra sign-in logs.
- Revocation is instant and central: remove the role assignment.
- Secret scanning has almost nothing to find, so a hit is a real signal rather
  than noise.

### What this makes harder

- **Local development needs `az login`.** A developer must have Azure access
  and network line-of-sight to the private endpoints. A connection string
  could be pasted into a laptop; a managed identity cannot.
- **Tooling that only speaks connection strings stops working.** Storage
  Explorer, older SDKs, and a lot of quick scripts. This is the intended
  outcome and it is genuinely inconvenient.
- **Debugging authentication is harder.** `DefaultAzureCredential` failing
  produces a chain of attempted methods rather than one clear error, and
  `AADSTS70021` names none of the four things that must agree.
- **It only works on Azure.** A component that must authenticate to a
  third-party SaaS still needs a real secret; the CSI mount path exists for
  exactly that case.

### What would have to change for this to be wrong

If the platform had substantial dependencies outside Azure — a payment
provider, a third-party API — the majority of its credentials would fall
outside this model, and the effort would buy less.

## Alternatives considered

**Key Vault with rotation.** The industry-standard answer, and a large
improvement over the alternatives below it. Rejected as the *primary* model
because it manages a risk that federation removes: between rotations the
credential is still long-lived, still exfiltratable, and still valid from
anywhere.

**Kubernetes Secrets.** Base64, not encrypted, stored in etcd, readable by
anyone with `get secrets` in the namespace, and they do not rotate. Used in
exactly one place here — the App Insights connection string, because the
Azure Monitor SDK reads it from an environment variable at import time — and
that exception is documented where it occurs.

**Pod Identity (AAD Pod Identity v1).** The predecessor to workload identity.
Deprecated, and it worked by intercepting IMDS traffic with a privileged
DaemonSet — a node-level component with a large attack surface.

**Service principal secrets in a pipeline.** What most Jenkins-based Azure
pipelines still do. A long-lived credential with broad subscription access,
held by a system with a large plugin attack surface. Rejected explicitly; see
`cicd/jenkins/Jenkinsfile.deploy`.
