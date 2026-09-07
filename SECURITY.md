# Security Policy

## What this repository is

A **reference blueprint**. It contains infrastructure-as-code, pipelines, and
application scaffolding for a multi-region Azure Data & AI platform. It is
written to be read, reviewed, linted, and scanned — **not** deployed.

There is no running system behind this repository, so there is no production
attack surface. The security posture that matters here is the posture *of the
code itself*.

## Guarantees this repository tries to keep

1. **No real credentials, ever.** No client secrets, connection strings, SAS
   tokens, PATs, certificates, or private keys.
2. **No real tenancy identifiers.** Subscription IDs, tenant IDs, object IDs,
   and principal IDs are placeholder values (all-zero GUIDs or clearly fake
   names). See `docs/00-safety-and-placeholders.md`.
3. **No personal data.** No personal email addresses, phone numbers, home
   addresses, employer names, or client names. Commits are authored with a
   GitHub `noreply` address.
4. **No deployable state.** No Terraform state files, no `.tfvars` with real
   values, no backend configuration pointing at a real storage account.

## Automated enforcement

Every push and pull request runs:

| Check | Tool | Blocks merge |
|---|---|---|
| Secret detection (history + diff) | `gitleaks` | yes |
| Terraform static security analysis | `checkov`, `tfsec` | yes |
| Terraform correctness | `terraform validate`, `tflint` | yes |
| Kubernetes manifest policy | `kube-linter`, `conftest` | yes |
| Python lint / type / test | `ruff`, `mypy`, `pytest` | yes |
| Container image CVEs | `trivy` | yes |
| Placeholder-leak guard | `tools/check_placeholders.sh` | yes |

`terraform apply` is **not** present in any workflow in this repository, and
no workflow is granted cloud credentials. See
`docs/00-safety-and-placeholders.md` for how that is enforced.

## Reporting a problem

If you find a real secret, a real identifier, or personal data that slipped
through, please open a GitHub issue **without quoting the value** — just point
at the file and line. It will be treated as a priority and the history will be
rewritten if necessary.
