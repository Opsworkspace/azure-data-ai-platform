# 0002. Hub-and-spoke network topology

**Status:** Accepted
**Date:** 2026-09-06

## Context

The platform needs a network design that supports two regions, several
environments, workloads that must not reach each other, and a single
controlled egress point — while remaining something a small team can operate.

Azure's defaults give none of that: a flat VNet where everything can reach
everything, with a default route to the internet.

The decision has to be made early and is expensive to revisit, because
changing topology means re-addressing a live network.

## Decision

Hub-and-spoke, one hub and one spoke per region per environment.

The **hub** holds only shared network components: Azure Firewall, Azure
Bastion, the gateway subnet, and shared services. No workloads.

The **spoke** holds workloads: AKS node pools, private endpoints, Databricks
subnets. It peers to its regional hub and routes `0.0.0.0/0` there.

Hubs are peered to each other with global VNet peering. Spokes are **not**
peered to each other — peering is not transitive, so inter-spoke traffic must
route through a hub, where it can be inspected.

Address space is allocated so that no two VNets in the estate overlap, across
all environments, whether or not they ever connect.

## Consequences

### What this makes easier

- One firewall per region rather than one per workload — the cost of the most
  expensive component is amortised.
- A spoke can be delegated to a product team without granting control of
  shared egress or the jump path.
- Blast radius is a spoke: a misconfigured NSG cannot expose another workload.
- Adding a workload is adding a spoke, not re-addressing the network.

### What this makes harder

- More objects: two VNets, two peerings and a route table per region per
  environment, rather than one VNet.
- Peering must be created in both directions. A one-sided peering shows as
  `Initiated` and silently passes no traffic.
- Inter-spoke traffic requires routing through the hub, which costs latency
  and firewall throughput.
- Global peering is billed **per GB in both directions**, so cross-region
  chatter is a real cost line.

### What would have to change for this to be wrong

If the platform were single-region, single-environment, and never expected to
host more than one workload, the hub would be pure overhead. It stops being
overhead at the second spoke.

## Alternatives considered

**A single flat VNet.** Simplest, and defensible for one workload. Rejected
because it has no isolation boundary: every NSG mistake is estate-wide, and
there is no unit of delegation.

**Azure Virtual WAN.** A managed hub-and-spoke with built-in transit routing
and branch connectivity. Genuinely better at scale, particularly with many
branch offices or dozens of spokes. Rejected because it adds cost and a
managed abstraction whose behaviour is harder to reason about, for a platform
with two spokes per environment and no branch connectivity. Worth revisiting
above roughly ten spokes.

**Spoke-to-spoke peering.** Would remove the hub hop for inter-spoke traffic.
Rejected because it grows as O(n²) peerings, and because it removes the
inspection point — the traffic most worth inspecting is exactly the traffic
between workloads.
