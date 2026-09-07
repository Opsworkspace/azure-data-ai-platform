# 0006. Private AKS cluster with no public API endpoint

**Status:** Accepted
**Date:** 2026-09-06

## Context

The AKS API server is the control point for the entire cluster. Anyone who can
reach it and authenticate can read every secret, schedule any workload, and
exfiltrate anything the cluster can reach.

By default it has a public endpoint reachable from the internet, protected by
authentication alone.

Azure offers three postures:

1. Public endpoint, no restriction
2. Public endpoint with `authorized_ip_ranges`
3. Private cluster — no public endpoint at all

## Decision

Private cluster. `private_cluster_enabled = true`, with
`private_cluster_public_fqdn_enabled = false` and `private_dns_zone_id = "System"`.

Access is from inside the VNet, from a peered VNet, through Azure Bastion, or
via `az aks command invoke`.

Additionally `local_account_disabled = true`, removing the cluster-admin
certificate that bypasses Entra entirely.

## Consequences

### What this makes easier

- The largest single reduction in attack surface available on a Kubernetes
  cluster. There is no internet-facing control plane to attack, credential-stuff,
  or hit with a zero-day.
- No IP allow-list to maintain, and none to rot. Allow-lists accumulate entries
  for people who have left and offices that closed.
- Combined with `local_account_disabled`, every path to the cluster is an Entra
  identity subject to Conditional Access and PIM.

### What this makes harder

This is the honest part, and it is why most teams do not do it.

- **GitHub-hosted runners cannot reach the cluster.** Deployment requires a
  self-hosted runner inside the VNet, a Jenkins agent inside the VNet, or
  `az aks command invoke`. This is a real, permanent operational cost, and it
  is the main reason `cicd/jenkins/` exists in this repository.
- **`kubectl` from a laptop does not work** without Bastion or a VPN. Every
  debugging session has an extra step.
- `az aks command invoke` is a shell-in-a-box: no streaming, awkward file
  transfer, every command through ARM.
- Bringing your own private DNS zone (rather than `System`) introduces a
  permission dependency that must exist before the cluster does.

### What would have to change for this to be wrong

If the team had no way to run compute inside the VNet — no self-hosted runners,
no Jenkins agents — the friction would fall entirely on humans and would
eventually be routed around. A control people bypass is worse than no control,
because it also carries the cost.

## Alternatives considered

**Public endpoint with `authorized_ip_ranges`.** Much easier, and genuinely
better than nothing. Rejected because the allow-list has to include every CI
runner egress IP (GitHub's ranges are broad and change), every VPN endpoint,
and every office. It rots, it tends to widen over time, and the endpoint is
still internet-facing — a zero-day in the API server is still reachable.

**Public endpoint, no restriction.** The default. Rejected without much
discussion.

**Private cluster with a bring-your-own private DNS zone.** Necessary when a
custom DNS server must resolve the API server. Rejected here because `System`
lets AKS manage the zone, and nothing in this design needs custom resolution
of the API server name.
