# `bootstrap/` — the chicken-and-egg problem

Terraform stores state remotely. Remote state lives in an Azure Storage
account. That storage account has to be created by something.

If you create it with Terraform, where does *that* Terraform's state live?

## The three ways out

| Approach | What actually happens |
|---|---|
| **Click it in the portal** | Works. Nobody can tell you six months later why the account is configured that way, and it is the one resource in the platform not under review. |
| **A shell script with `az` CLI** | Reproducible, but now the platform has two provisioning languages and the storage account's settings drift from the Terraform conventions everything else follows. |
| **Terraform with local state, committed once** ← this repo | The bootstrap is Terraform like everything else. Its own state file is local and deliberately *not* committed. |

## Why local state is acceptable here, and only here

The bootstrap creates exactly four things: a resource group, a storage
account, a blob container, and a role assignment. Losing its state file is
inconvenient, not catastrophic — the resources can be re-imported in about ten
minutes with `terraform import`, and there is nothing in them to reconstruct.

Losing the state file of a *production environment* is a different event
entirely: Terraform no longer knows those resources exist, a subsequent apply
tries to create duplicates, and reconciling it by hand takes days.

That asymmetry is the whole argument. State protection scales with the cost of
losing it.

## The order of operations

```bash
# 1. Create the backend, using local state.
cd infra/terraform/bootstrap
terraform init
terraform apply

# 2. Note the outputs.
terraform output backend_config_hcl

# 3. Every OTHER configuration now points at it.
cd ../environments/dev
terraform init -backend-config=../../backend.hcl
```

`backend.hcl` is in `.gitignore`. It contains a storage account name and a
resource group name — not secrets, but tenancy-identifying, and this
repository publishes neither.

## What protects the state itself

| Setting | Protects against |
|---|---|
| `versioning_enabled` | A corrupted or truncated state write. Roll back to the previous blob version. |
| `blob_delete_retention_policy` | Someone deleting the container. |
| Native blob leasing | Two engineers running `apply` at once. Terraform takes a lease for the duration; the second run blocks rather than interleaving writes. |
| `shared_access_key_enabled = false` | The state file being readable by anyone holding a copied connection string. State contains every attribute of every resource, including many marked sensitive. |
| `prevent_destroy` | `terraform destroy` in the bootstrap directory taking the whole platform's state with it. |

> **State is the most sensitive artefact in an IaC platform.** It contains
> resource attributes in plaintext — generated passwords, connection strings,
> certificate bodies. Treat the state container with the same care as a
> secrets store, because functionally it is one.
