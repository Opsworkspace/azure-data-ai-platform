# Safety, Placeholders, and Why Nothing Here Costs Money

> Read this before anything else. It is the contract the rest of the
> repository keeps.

## The constraint

This platform is designed for an application that **does not exist yet**. There
is no budget, no live traffic, and no Azure subscription behind it. That is a
deliberate constraint, not a limitation, and it shapes every decision in here.

A platform blueprint that has never been deployed is still enormously valuable
— it is how real platform teams work *before* the first `apply`. Architecture,
module boundaries, network topology, RBAC model, SLOs, runbooks, and pipeline
design are all decided on paper and in code review, long before anyone spends a
cent. What this repository refuses to do is *pretend* it has been deployed.

## The three rules

### Rule 1 — No workflow may ever hold cloud credentials

There is no `AZURE_CLIENT_SECRET`, no OIDC federated credential, and no service
principal wired into GitHub Actions or Jenkins in this repository. Every
pipeline here runs **credential-free**, which mechanically limits it to:

- formatting (`terraform fmt`)
- syntax and schema checking (`terraform validate`)
- linting (`tflint`, `ruff`, `kube-linter`)
- static security analysis (`checkov`, `tfsec`, `trivy`)
- unit tests (`pytest`)
- policy evaluation (`conftest`)

Notice what is missing: `terraform plan` and `terraform apply`. A `plan`
requires reading real state from a real backend, and `apply` creates real
billable resources. Neither can run, because neither has anything to
authenticate with.

> **The lesson.** In a funded environment you *would* run `plan` on every pull
> request — it is the single highest-value check in IaC, because it shows the
> reviewer exactly what will change. `docs/architecture/10-cicd.md` documents
> exactly how that would be wired using Entra Workload Identity Federation
> (OIDC), with no long-lived secret, and marks it clearly as **not enabled**.

### Rule 2 — Every identifier is a placeholder, and placeholders are obvious

| Kind of value | Placeholder used | Never used |
|---|---|---|
| Subscription ID | `00000000-0000-0000-0000-000000000000` | a real GUID |
| Tenant ID | `00000000-0000-0000-0000-000000000000` | a real GUID |
| Object / principal ID | `00000000-0000-0000-0000-000000000000` | a real GUID |
| DNS name | `purple.example.com` | a real domain |
| Email | `platform-team@example.com` | a personal address |
| Resource prefix | `purple` | a real product name |
| Region pair | `eastus2` / `centralus` | — (these are real region names, and that is fine) |

The all-zero GUID is chosen precisely because it is *never* a valid Azure
identifier. If one ever leaks into a real pipeline, that pipeline fails loudly
instead of touching the wrong tenant.

`tools/check_placeholders.sh` runs in CI and fails the build if any GUID that
is **not** all-zeros appears in a tracked file.

### Rule 3 — No state, no secrets, no personal data in git

`.gitignore` blocks `*.tfstate`, `*.tfvars`, `backend.hcl`, `.env`, `kubeconfig`,
and key material. `gitleaks` scans the full history on every push. Commits are
authored with a GitHub `noreply` address so no personal email is embedded in
the public commit log.

## What "placeholder" means in the Terraform

It does **not** mean fake or incomplete code. The modules are written as real,
production-shaped Terraform: correct resource types, correct arguments, correct
dependency graph, correct `for_each` and lifecycle handling. What is
placeholdered is only the *tenancy-specific input*:

```hcl
# infra/terraform/environments/prod/terraform.tfvars.example
subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"
```

Someone with a funded subscription could copy `terraform.tfvars.example` to
`terraform.tfvars`, fill in four real values, and the code would stand up the
platform. That is the bar every module in here is held to.

## If you ever do want to deploy it

Do not start with `prod`. Read `docs/architecture/08-cost-and-finops.md` first —
it carries a per-environment cost model. The short version:

| Environment | Shape | Rough monthly order of magnitude |
|---|---|---|
| `dev` | single region, spot node pools, serverless Cosmos, no Front Door, no Firewall | low hundreds USD |
| `stage` | single region, production topology at 1/10 scale | low thousands USD |
| `prod` | dual region active/active, zone-redundant, Firewall, Front Door Premium | tens of thousands USD |

The single most expensive line items in the `prod` shape are Azure Firewall
(billed per hour, per region, whether or not traffic flows), Cosmos DB
provisioned throughput with multi-region writes, and Databricks compute. All
three are documented with their cost-reduction levers.
