# Admission policy

Guard rails enforced at the moment a resource is submitted to the API server,
not discovered later by a scanner.

## Why admission control and not just scanning

A CI scan tells you a manifest is non-compliant *before* it is applied. That
is valuable, and this repository does it too. But it only covers resources
that go through CI. It does not cover:

- `kubectl apply` run by hand during an incident
- a Helm chart pulled from upstream
- an operator that creates pods on your behalf
- anything applied before the scan was added

Admission control covers all of them, because it sits in the API server's own
request path. Nothing reaches etcd without passing it.

## The two layers here

| Layer | What it is | What it catches |
|---|---|---|
| **Pod Security Admission** | Built into Kubernetes, set by namespace label | The classic container escapes: privileged, hostPID, hostPath, running as root |
| **Gatekeeper / OPA** | The `azure_policy_enabled` add-on on AKS | Everything organisation-specific: registries, probes, resource limits, labels |

PSA is free, always on, and cannot express anything custom. Gatekeeper can
express anything, and costs a webhook in the request path. Using both means
the common cases are handled by the cheap mechanism.

## The rollout rule

Every constraint starts at `enforcementAction: dryrun`.

A constraint that blocks on day one blocks the deployment someone needs to
make during an incident, and the response is to disable the whole policy
engine. Dry-run mode records violations without blocking, so you can see
exactly what would have been rejected, fix it, and only then switch to `deny`.

The constraints in this directory are marked with their intended final state
in a comment. `warn` is the middle step where it is supported.
