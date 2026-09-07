# Module: `naming`

A module that creates **no resources**. It exists to make every name and every
tag in the platform a *derived* value rather than a typed one.

## Why this module exists first

The most common failure in a young platform is not a security hole — it is
drift in names. Someone writes `purple-prod-aks`, someone else writes
`aks-purple-prod`, a third writes `purpleprodaks01`. Six months later nobody can
write a cost query, an alert rule, or an Azure Policy assignment that reliably
matches "all production AKS clusters", because the names carry no structure.

Naming is a platform concern, so it is a module.

## The convention

```
<prefix>-<workload>-<env>-<region>-<abbrev>[-<instance>]
     purple-plat-prod-eus2-aks
```

| Segment | Example | Why it is there |
|---|---|---|
| `prefix` | `purple` | Distinguishes this platform from anything else in the tenant |
| `workload` | `plat`, `data`, `app` | Which capability owns the resource |
| `env` | `dev`, `stg`, `prod` | The single most-queried dimension in cost and policy |
| `region` | `eus2`, `cus` | Two same-named resources in two regions must not collide |
| `abbrev` | `aks`, `kv`, `cosmos` | Resource type, using the CAF abbreviation list |

## Globally-unique names

Storage accounts, Key Vaults, ACRs and Cosmos accounts share a **global** DNS
namespace, and several forbid hyphens or cap at 24 characters. For those, the
module emits a compact form with a deterministic 6-character suffix derived
from the subscription id, environment and location:

```
purpleplatprodeus2a1b2c3   # storage account, 24 chars, lowercase alphanumeric
```

The suffix is deterministic, not random: the same inputs always produce the
same name, so `terraform plan` stays clean across machines. It is *not* a
secret and it is *not* derived from anything sensitive — it is a hash used
purely to avoid global-namespace collisions.

## Tags

Six tags are applied to every resource in the platform. They are not
decoration; each one answers a question somebody will eventually ask:

| Tag | Question it answers |
|---|---|
| `environment` | Can I safely delete this? |
| `workload` | Which team's budget does this land on? |
| `owner` | Who do I page? |
| `cost_center` | Which cost centre does the invoice split into? |
| `data_classification` | What controls does this resource legally require? |
| `managed_by` | Will my change be reverted by a pipeline? (`terraform`) |

`docs/adr/0003-naming-and-tagging.md` records why these six and not others.
