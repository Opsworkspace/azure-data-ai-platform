# Compute platform

> AKS as the substrate, and the decisions that are expensive to reverse.

## AKS is not the platform

Installing AKS gives developers a Kubernetes API and a YAML problem. It
schedules containers and keeps them running; it makes no decisions on your
behalf. Base image, logging format, probe strategy, resource sizing, ingress,
secrets — all still open.

The platform is the set of defaults, guard rails and paved roads on top of it.
This document covers the substrate; the platform parts live in
`platform/kubernetes/` and `platform/policies/`.

## The irreversible decisions

### Network plugin

| Model | Pod IPs | Consequence |
|---|---|---|
| kubenet | NATed | Cheap on IPs, weak network policy, being phased out |
| Azure CNI | Real VNet IPs | Routable, but 30 nodes × 30 pods = **900 VNet addresses** |
| **Azure CNI Overlay** | Private overlay CIDR | Scales hugely, full network policy, pod IPs not routable outside |

Overlay is chosen. **Address exhaustion is the number one reason AKS clusters
get rebuilt**, and overlay removes it: the pod CIDR is not part of the VNet, so
it can be *identical in both regions* — which keeps NetworkPolicy manifests the
same across regions.

The trade: anything that needs to dial a pod directly from outside the cluster
needs adapting. Some service meshes and some legacy monitoring do.

### Private cluster

No public API endpoint at all. See [ADR 0006](../adr/0006-aks-private-cluster.md)
for the full reasoning and the operational cost.

### `outbound_type = "userDefinedRouting"`

The cluster does not create its own outbound load balancer with a public IP.
Egress follows the subnet route table to the hub firewall.

**The route table must exist and be correct before the cluster is created.** If
not, node provisioning fails with a timeout, because nodes cannot reach the AKS
control plane to bootstrap. That ordering constraint is why the spoke module
creates the route table and the environment wires it in before the AKS module
runs.

### SKU tier

`Free` has **no control-plane SLA at all**. `Standard` buys 99.95% (99.99% with
availability zones) for about $0.10/hour.

The control plane is a dependency of every pod start, scale event and probe, so
any cluster with a production SLO must be `Standard`. The AKS module carries a
precondition that refuses `Free` for a cluster whose name contains `prod`.

## Node pools

Three, and the separation is deliberate:

| Pool | Runs | Why separate |
|---|---|---|
| `system` | CoreDNS, metrics-server, CSI drivers | `only_critical_addons_enabled` taints it, so application pods cannot starve CoreDNS |
| `user` | Application workloads | Different SKU, different scaling curve |
| `ai` | GPU inference | Expensive, quota-limited, scales to **zero** |

Each in its own subnet, so an NSG can express "the AI pool may not reach the
internet" — a policy a taint cannot express.

**Taints and labels work together.** The taint keeps everything else off; the
label lets the intended workload find it via `nodeSelector`. A pool with a
taint and no matching toleration anywhere is a pool that scales to its minimum
and runs nothing — expensive, and surprisingly common.

### Ephemeral OS disks

`os_disk_type = "Ephemeral"` puts the OS disk on the VM's local NVMe rather
than in remote managed storage. Faster, included in the VM price, and lost on
deallocation — correct for a stateless node.

The constraint: the VM SKU's cache tier must be large enough to hold the image.
The AI pool uses `Managed` because GPU node images are large and NC-series
cache is not always sufficient.

### Spot nodes

Up to 90% off, evictable with 30 seconds' notice. Correct for anything
interruptible and retryable — the ingestion worker. Catastrophic for anything
that is not.

## Autoscaling

Two independent layers, frequently confused:

| Layer | Scales | Trigger |
|---|---|---|
| **HPA** | Pod replicas | CPU/memory utilisation, or custom metrics |
| **Cluster autoscaler** | Nodes | Pods that cannot be scheduled |

The HPA adds pods; if there is nowhere to put them, the cluster autoscaler adds
nodes. Neither works without the other: a maxed-out HPA on a full cluster does
nothing, and a cluster with spare nodes and no HPA never uses them.

The autoscaler profile matters more than the defaults suggest:

```hcl
scale_down_delay_after_add = "10m"
scale_down_unneeded        = "10m"
expander                   = "least-waste"
```

Aggressive scale-down causes thrashing — nodes removed, immediately needed
again — and every removal is a pod eviction. `least-waste` bin-packs onto the
fewest nodes; `random` spreads load and costs more.

## Upgrades

```hcl
automatic_upgrade_channel = "patch"      # automatic
node_os_upgrade_channel   = "NodeImage"  # automatic
```

**Automatic patching, deliberate minor upgrades.** A patch upgrade closes CVEs
and does not change APIs. A minor upgrade can deprecate APIs the workloads use,
so it is a tested, scheduled change.

AKS supports N-2, so a Kubernetes version is roughly a twelve-month commitment
before a forced upgrade.

Maintenance windows keep both inside a chosen four-hour window on a chosen day.
Without one, an upgrade can start at any time — including during a traffic
peak.

## What makes rollouts invisible

Four settings, working together. Removing any one makes deployments
user-visible:

| Setting | Without it |
|---|---|
| `maxUnavailable: 0` | Capacity drops mid-deploy |
| `PodDisruptionBudget` | A node drain evicts every replica at once |
| `preStop` sleep | 502s during every deployment while endpoint removal propagates |
| Readiness probe | Traffic reaches pods that cannot serve yet |

These are explained in detail in `platform/kubernetes/base/api-deployment.yaml`,
which is worth reading in full.

## Related

- `infra/terraform/modules/aks/` — the cluster and node pools
- `platform/kubernetes/base/` — the workload manifests
- ADR: [0006 — private AKS cluster](../adr/0006-aks-private-cluster.md)
