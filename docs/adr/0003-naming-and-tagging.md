# 0003. Naming convention and standard tag set

**Status:** Accepted
**Date:** 2026-09-06

## Context

The most common failure in a young platform is not a security hole — it is
drift in names. One engineer writes `purple-prod-aks`, another `aks-purple-prod`,
a third `purpleprodaks01`.

Six months later nobody can write a cost query, an alert rule, or an Azure
Policy assignment that reliably matches "all production AKS clusters", because
the names carry no structure. The same applies to tags: a resource with no
`cost_center` is a line on an invoice that no team will claim.

Azure makes this harder than it should be:

- Naming rules differ per resource type — some forbid hyphens, some cap at 24
  characters, some must be globally unique across all of Azure.
- There is no official region short-code list.
- Tags are free-form strings with no schema and no enforcement by default.

## Decision

**Names are derived, never typed.** A `naming` module takes facts about a
deployment and emits every name. No resource name is written by hand anywhere
in the platform.

```
<prefix>-<workload>-<env>-<region>-<abbrev>
     purple-plat-prod-eus2-aks
```

For globally-unique namespaces that forbid hyphens, a compact form with a
deterministic six-character suffix derived from the subscription id:

```
purpleplatprodeus2a1b2c3
```

The suffix is deterministic, not random, so the same inputs always produce the
same name and `terraform plan` stays clean across machines.

**Six tags on every resource**, each justified by a question someone will ask:

| Tag | Question it answers |
|---|---|
| `environment` | Can I safely delete this? |
| `workload` | Whose budget does this land on? |
| `owner` | Who do I page? |
| `cost_center` | How does the invoice split? |
| `data_classification` | What controls does this legally require? |
| `managed_by` | Will my change be reverted by a pipeline? |

Enforced by `platform/policies/require-tags.json`.

## Consequences

### What this makes easier

- Cost queries, policy assignments and alert scoping all become reliable,
  because the names and tags are structurally guaranteed.
- Adding a region is a one-line change to a map, and the module *fails* on an
  unmapped region rather than emitting a name containing `null`.
- Changing the convention is a one-file change.

### What this makes harder

- Names are longer and less pretty than a human would choose.
- The 24-character Key Vault limit forces truncation, which occasionally
  produces a name that reads awkwardly.
- Reading Terraform requires one indirection: `module.naming_platform["primary"].aks_cluster_name`
  rather than a literal.

### What would have to change for this to be wrong

If the platform only ever had a handful of resources in one subscription, the
module would be overhead. It stops being overhead somewhere around the second
environment.

## Alternatives considered

**Azure CAF's `azurecaf` provider.** A well-maintained community provider that
does exactly this. Rejected because it adds a provider dependency for
something expressible in ~80 lines of HCL, and because writing it makes the
constraints (24 chars, no hyphens, global uniqueness) legible to the reader
instead of hidden in a dependency.

**Random suffixes (`random_string`).** Guarantees uniqueness. Rejected because
the value is stored in state, so losing state means losing the ability to
reproduce the name — and two engineers running `plan` before the first `apply`
see different names.

**No suffix, rely on the prefix.** Fails the first time someone else in the
world has taken `purplestorage`.
