# Network topology

> Hub-and-spoke, forced tunnelling, and private endpoints — and the DNS
> problem that breaks all of it if you get it wrong.

## The property the whole design exists to produce

**No PaaS service in this platform has a reachable public endpoint, and no
compute resource has a public IP.**

Not "restricted by firewall rule". Not "protected by an IP allow-list".
`public_network_access_enabled = false`, which means the service refuses
connections from the internet at the service level, before any network control
is consulted.

Everything below follows from committing to that.

## Hub and spoke

```
                      ┌─────────────────────────┐
                      │   Azure Front Door      │
                      │   anycast · WAF         │
                      └───────────┬─────────────┘
                                  │
       ┌──────────────────────────┴──────────────────────────┐
       │                                                     │
┌──────▼───────────────────────┐              ┌──────────────▼──────────────┐
│  EAST US 2                   │              │  CENTRAL US                 │
│                              │              │                             │
│  ┌────────────────────────┐  │  global      │  ┌───────────────────────┐  │
│  │ HUB   10.10.0.0/20     │◄─┼──peering────►│  │ HUB   10.20.0.0/20    │  │
│  │  AzureFirewallSubnet   │  │              │  │  AzureFirewallSubnet  │  │
│  │  AzureBastionSubnet    │  │              │  │  AzureBastionSubnet   │  │
│  │  GatewaySubnet         │  │              │  │  GatewaySubnet        │  │
│  └───────────┬────────────┘  │              │  └──────────┬────────────┘  │
│              │ peering       │              │             │ peering       │
│  ┌───────────▼────────────┐  │              │  ┌──────────▼────────────┐  │
│  │ SPOKE 10.11.0.0/16     │  │              │  │ SPOKE 10.21.0.0/16    │  │
│  │  snet-aks-system  /22  │  │              │  │  snet-aks-system  /22 │  │
│  │  snet-aks-user    /22  │  │              │  │  snet-aks-user    /22 │  │
│  │  snet-aks-ai      /22  │  │              │  │  snet-aks-ai      /22 │  │
│  │  snet-private-eps /24  │  │              │  │  snet-private-eps /24 │  │
│  │  snet-databricks  ×2   │  │              │  │  snet-databricks  ×2  │  │
│  └────────────────────────┘  │              │  └───────────────────────┘  │
└──────────────────────────────┘              └─────────────────────────────┘
```

### Why not one flat VNet

| Concern | Flat VNet | Hub and spoke |
|---|---|---|
| Blast radius | One NSG mistake exposes everything | Contained to one spoke |
| Cost | One firewall — but no isolation | One firewall per region, shared by all spokes |
| Delegation | Cannot hand a subnet to a team safely | A spoke can be owned by a product team |
| Growth | Re-addressing to add a workload | Add a spoke |

The hub holds **no workloads**. It holds the things that must be shared and
must not be duplicated: the egress firewall, the jump path, the DNS boundary.

## The address plan

Non-overlapping across every environment, even though dev and prod never peer:

| Environment | Region | Hub | Spoke |
|---|---|---|---|
| prod | East US 2 | `10.10.0.0/20` | `10.11.0.0/16` |
| prod | Central US | `10.20.0.0/20` | `10.21.0.0/16` |
| stage | East US 2 | `10.30.0.0/20` | `10.31.0.0/16` |
| dev | East US 2 | `10.40.0.0/20` | `10.41.0.0/16` |

**Why non-overlapping when they never connect.** Because one day they might —
a shared services VNet, an ExpressRoute circuit to an on-premises network, an
acquisition, a migration. Overlapping ranges are free to avoid now and
extremely expensive to fix later, because fixing them means re-addressing a
live network.

Subnets within a spoke are **computed**, never typed:

```hcl
aks_system        = cidrsubnet(var.address_space, 6, 0)   # 10.11.0.0/22
aks_user          = cidrsubnet(var.address_space, 6, 1)   # 10.11.4.0/22
private_endpoints = cidrsubnet(var.address_space, 8, 12)  # 10.11.12.0/24
```

Hand-allocated CIDRs are how overlaps reach production. `cidrsubnet()` makes
overlap arithmetically impossible.

> **Azure reserves 5 addresses in every subnet** — network, gateway, two DNS,
> broadcast. A `/22` gives 1019 usable, not 1024. That is a real
> capacity-planning input when sizing an AKS node subnet.

## Forced tunnelling

By default every Azure subnet has a system route sending `0.0.0.0/0` to the
internet. The design removes it:

```hcl
resource "azurerm_route" "default_via_firewall" {
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_private_ip
}
```

Combined with AKS's `outbound_type = "userDefinedRouting"`, every packet
leaving a workload subnet goes to the firewall, is matched against an
allow-list held in version control, and is logged.

### The subtlety that costs people hours

**A private endpoint injects a `/32` system route that is MORE specific than
`0.0.0.0/0`.** Traffic to a private endpoint therefore does *not* go via the
firewall, even with forced tunnelling enabled.

This is correct and desirable — the traffic stays on the Microsoft backbone —
but it means your Cosmos DB calls will never appear in the firewall logs.
People spend a long time looking for them.

### Where the route table is deliberately NOT attached

- **The private endpoint subnet.** Nothing egresses from it; a private
  endpoint NIC is a destination, never a source.
- **The Databricks subnets.** Databricks manages routing for its secure
  cluster connectivity relay. A platform-imposed default route there breaks
  the control plane connection, and it surfaces as clusters hanging in
  `PENDING` for twenty minutes before failing with an error that mentions
  neither routing nor the firewall.

## Private endpoints and the DNS problem

This is the part that breaks everything when it is wrong, and the failure
looks like a networking problem rather than a DNS one.

### What a private endpoint does and does not do

A private endpoint gives a PaaS service a private IP inside your VNet.

It does **not** change what the service's hostname resolves to.

Without a private DNS zone, a client inside the VNet resolving
`purpledata.blob.core.windows.net` still gets the service's **public** IP,
sends the packet out through the firewall, and is denied — because
`public_network_access_enabled = false`.

The symptom is a connection timeout. The cause is DNS.

### The resolution chain

```
1. Client asks for            purpledata.blob.core.windows.net
2. Azure DNS returns a CNAME  purpledata.privatelink.blob.core.windows.net
3. The linked private zone
   answers with               10.11.12.7        ← the private endpoint
4. Traffic stays on the VNet
```

**Step 3 only happens if the zone is linked to the VNet the client sits in.**
That is what `vnet_links` controls in `modules/private-dns`, and why every
spoke *and* every hub must be listed.

### The three mistakes, in order of frequency

**1. Forgetting the zone entirely.** Endpoint created, nothing resolves to it.

**2. Linking the zone to some VNets and not others.** Works in one region,
times out in the other. This is the worst one, because it looks intermittent.

**3. Creating the same zone twice.** Two zones named
`privatelink.blob.core.windows.net` in one tenant is legal and produces
non-deterministic resolution depending on link order. **One zone, many links**
is the only safe topology.

### Services needing more than one zone

| Service | Zones required |
|---|---|
| ADLS Gen2 | `blob` **and** `dfs` |
| Azure OpenAI | `openai` **and** `cognitiveservices` |
| Azure Monitor (AMPLS) | five, including `blob` |

The storage case is the sharpest. Link only `blob` and Spark's `abfss://`
paths fail while the Azure CLI works — a difference invisible in the portal.
Unity Catalog external locations use `abfss://`, so a lakehouse with only the
blob zone linked has a working portal and a broken data platform.

## NSGs — the second layer

The firewall controls what leaves the VNet. NSGs control what moves *inside*
it. Both are needed: an attacker who lands on a node in the AI pool should not
reach the private endpoint subnet directly, and that is lateral movement the
firewall never sees.

Every NSG follows one shape:

1. Allow the specific flows the workload needs
2. Allow Azure's mandatory infrastructure flows
3. **Explicit** terminal deny at priority 4096

Step 3 is redundant — Azure denies by default — and is there anyway, because
an explicit deny appears in flow logs as a *named* rule. An implicit deny is
much harder to attribute at 3am.

### The two mandatory exceptions worth memorising

- **`AzureFirewallSubnet` must have NO NSG.** Azure forbids it. A blanket
  "attach an NSG to every subnet" policy fails here.
- **`AzureBastionSubnet` must have an NSG with an exact rule set.** Those
  rules are a contract, not a design choice, and they are written out in full
  in `modules/network-hub/nsg.tf` so an operator debugging a broken Bastion
  can read them.

Also: **`AzureLoadBalancer` inbound must be allowed.** Blocking it silently
breaks every load-balanced service, and the symptom — endpoints flapping to
NotReady — points nowhere near the NSG.

## What reaches the platform from outside

Exactly two things:

| Path | Terminates on | Protected by |
|---|---|---|
| `https://api.purple.example.com` | Front Door anycast IP | WAF, rate limiting, TLS |
| Azure Bastion portal | Managed PaaS service | Entra, RBAC, session audit |

There is no third. No VM has a public IP; `deny-public-ip.json` makes that a
property of the subscription rather than of the Terraform.

## Related

- Hub: `infra/terraform/modules/network-hub/`
- Spoke: `infra/terraform/modules/network-spoke/`
- DNS: `infra/terraform/modules/private-dns/`
- Runbook: [`docs/runbooks/03-egress-blocked.md`](../runbooks/03-egress-blocked.md)
- ADR: [`0005-egress-through-firewall.md`](../adr/0005-egress-through-firewall.md)
