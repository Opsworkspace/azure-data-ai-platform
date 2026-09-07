# 0005. Force all egress through Azure Firewall

**Status:** Accepted
**Date:** 2026-09-06

## Context

By default, every Azure subnet has a system route sending `0.0.0.0/0` to the
internet. Any workload can reach any host, on any port, and nothing records
that it happened.

That matters for three distinct reasons, and it is worth separating them
because they have different weights:

1. **Exfiltration.** A compromised pod can send data anywhere.
2. **Supply chain.** A malicious dependency can call home during a build or at
   runtime.
3. **Blast radius.** A misconfigured workload can reach a service it was never
   meant to.

Azure Firewall is expensive: roughly $950/month per deployment plus per-GB
processing, per region, billed whether or not traffic flows. For a
dual-region platform that is about $23,000/year before a single byte moves.

## Decision

All workload subnets carry a user-defined route sending `0.0.0.0/0` to the
regional Azure Firewall's private IP. AKS is configured with
`outbound_type = "userDefinedRouting"`, so it does not create its own outbound
load balancer.

The firewall policy is an **allow-list of FQDNs**, held in version control.
Anything not listed is denied, and the denial is logged by an explicitly named
rule so it is attributable.

The firewall is deployed in **stage and prod only**. Dev sets
`deploy_firewall = false`.

## Consequences

### What this makes easier

- A single, known egress IP per region — the address a partner allow-lists.
- Every outbound connection is logged and attributable.
- Changing what the platform may reach is a reviewed pull request, not a
  runtime discovery.
- Threat-intelligence filtering blocks known-malicious destinations for free.

### What this makes harder

- **Cost.** The largest single line item in the platform.
- **A new dependency is now a code change.** Adding a Python package whose
  installer reaches an unlisted CDN fails, and the failure message is a
  timeout that does not mention the firewall. This is the day-to-day friction
  and it is real. `docs/runbooks/03-egress-blocked.md` exists because of it.
- **Dev does not have it,** so a dependency that dev never noticed breaks in
  stage. That is a deliberate trade: stage exists partly to catch it, and
  paying $950/month for a dev firewall is not justifiable.

### What would have to change for this to be wrong

If the platform ran only workloads with no outbound dependencies at all, or if
its egress destinations changed daily, the friction would outweigh the
control. Neither is true here.

## Alternatives considered

**NAT Gateway per spoke.** Gives a stable egress IP at a fraction of the cost
(~$45/month plus data). Rejected because it provides **no filtering
whatsoever** — it is an address translation device, not a control. It answers
"what IP do we come from" and not "where may we go".

**NSG rules with service tags.** Free, and genuinely useful as a second layer
— which is why the platform also has them. Rejected as the primary control
because NSGs match on IP ranges and service tags, not FQDNs. "Allow
`*.azurecr.io`" cannot be expressed; the nearest equivalent is a broad service
tag covering far more than intended.

**Azure Firewall Basic.** About a third of the cost. Rejected for production
because it has a fixed 250 Mbps throughput cap, which is below this platform's
expected egress. Used in stage, where throughput is not the thing being
validated.

**A third-party NVA (Palo Alto, Fortinet).** More capable filtering. Rejected
because it is a pair of VMs to patch, licence, monitor and fail over — a
platform component the team would now operate, in exchange for features this
workload does not need.
