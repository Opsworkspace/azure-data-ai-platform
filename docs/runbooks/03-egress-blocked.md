# Runbook 03 — A workload cannot reach an external host

**Symptom:** connection timeouts to something outside the VNet. Package
installs hang. A new API integration never connects. A Databricks cluster
sits in `PENDING` and then fails.

**Almost always:** the firewall's egress allow-list does not contain the
destination. This is the most common friction of forced tunnelling and the
direct cost of [ADR 0005](../adr/0005-egress-through-firewall.md).

## 0. Is it even a firewall problem?

Thirty seconds that prevents an hour of misdirected work.

```bash
az aks command invoke -g purple-data-prod-eus2-rg -n purple-plat-prod-eus2-aks \
  --command "kubectl run netdebug --rm -it --image=mcr.microsoft.com/cbl-mariner/base/core:2.0 \
             --restart=Never -n purple-system -- bash -c '
               echo \"--- DNS ---\";  getent hosts example.com;
               echo \"--- TCP ---\";  timeout 5 bash -c \"</dev/tcp/example.com/443\" && echo open || echo blocked
             '"
```

| Result | Meaning |
|---|---|
| DNS fails | **Not** a firewall problem. NetworkPolicy is blocking DNS, or CoreDNS is down. |
| DNS resolves to a **private** IP | Private endpoint path — see §4 |
| DNS resolves public, TCP blocked | Firewall. Continue to §1 |

## 1. Confirm the firewall denied it

```kusto
AZFWApplicationRule
| where TimeGenerated > ago(30m)
| where Action == "Deny"
| summarize Attempts = count()
          by SourceIp, Fqdn, Protocol, DestinationPort
| order by Attempts desc
```

`Fqdn` is the destination you need to allow. If nothing appears here, try the
network-rule table — a non-HTTP destination is matched there instead:

```kusto
AZFWNetworkRule
| where TimeGenerated > ago(30m)
| where Action == "Deny"
| summarize count() by SourceIp, DestinationIp, DestinationPort, Protocol
```

> This query works because the firewall policy has an **explicit named deny**
> rule at priority 65000. Azure's implicit deny would not be attributable like
> this. That is why the rule exists.

## 2. Decide whether to allow it

Do not reflexively add the FQDN. Three questions:

1. **What is it, and who owns it?** An unrecognised destination from a
   production pod is a security event, not a config gap.
2. **Is it needed at runtime, or only at build time?** Build-time dependencies
   belong in the container image, not in the egress list. Adding a package
   registry to the runtime allow-list because a container installs packages at
   startup is fixing the wrong problem.
3. **Can it be a private endpoint instead?** If it is an Azure service, a
   private endpoint is better than an egress rule: no internet path at all.

## 3. Add it

Egress changes are code changes.

```hcl
# infra/terraform/modules/network-hub/variables.tf
variable "allowed_egress_fqdns" {
  default = [
    # ...existing...
    "api.newvendor.com",   # <- with a comment saying WHY and who owns it
  ]
}
```

Prefer an **application rule** (FQDN) over a network rule (IP). An FQDN rule
survives the target changing IP and is legible to a reviewer.

Wildcards: `*.vendor.com` is convenient and broad. `api.vendor.com` is
specific and breaks when they add a second hostname. Prefer specific; use a
wildcard when the vendor documents that they rotate subdomains.

### Emergency mitigation

If this is blocking an active incident and the change cannot wait for review,
add the rule in the portal:

```
Firewall Policy → Rule collections → platform-egress
  → platform-egress-allowlist → add the FQDN
```

**Then immediately open the PR putting it in Terraform.** An out-of-band
firewall rule is drift, and the next `apply` removes it — which will happen at
the least convenient moment.

## 4. If DNS resolved to a private IP

This is a private endpoint problem, not a firewall one. See
[network topology](../architecture/03-network-topology.md).

```bash
# Compare what the client resolved with what the endpoint actually is.
az network private-endpoint show \
  -g purple-data-prod-eus2-rg -n <name>-pe \
  --query 'customDnsConfigs[].ipAddresses' -o tsv
```

Mismatch, or a public IP returned, means the zone is missing or not linked to
this VNet.

> Remember: private endpoint traffic takes a `/32` route and **never reaches
> the firewall**. If you are looking for it in `AZFWNetworkRule`, you will not
> find it, and its absence there is not evidence of anything.

## 5. Verify

```kusto
AZFWApplicationRule
| where TimeGenerated > ago(10m)
| where Fqdn contains "newvendor.com"
| summarize count() by Action
```

`Allow` only.

## 6. Afterwards

- Is the same FQDN needed in the other region? The policies are per-region.
- Should it be in the **dev** allow-list too? Dev has no firewall, so a
  dependency added only in prod is one dev will never validate — which is how
  this problem recurs.
