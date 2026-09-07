# How to use this repository

No Azure account is required. Nothing here can spend money.

## What you need

| Tool | For | Required? |
|---|---|---|
| `git` | Cloning | Yes |
| `terraform` ≥ 1.5 | `validate`, `fmt` | For the Terraform checks |
| `python` 3.12 | The services and tests | For the Python checks |
| `kustomize` | Building the Kubernetes overlays | For the K8s checks |
| `tflint`, `checkov`, `trivy`, `gitleaks`, `kube-linter` | Linting and scanning | Optional |

`make` degrades gracefully: a tool that is not installed is reported as
**SKIP**, never as a failure. Clone with nothing installed and add tools over
time.

## First run

```bash
git clone https://github.com/Opsworkspace/azure-data-ai-platform.git
cd azure-data-ai-platform

make setup      # configure the local git identity (see below)
make help       # list every target
make validate   # terraform fmt + validate across all 18 directories
make all        # everything CI runs, in CI order
```

### Why `make setup` matters

The repository's git identity is set **locally**, so commits carry a GitHub
`noreply` address rather than a personal email. Local git config does **not**
survive a fresh clone — you would inherit your global identity instead.

`make setup` sets it. Run it once after cloning, before your first commit.
This is the difference between a public commit log with a personal email in
every entry and one without.

## Reading order

The repository can be read three ways depending on what you want.

### To understand the system

1. [`00-safety-and-placeholders.md`](00-safety-and-placeholders.md) — the contract
2. [`architecture/01-system-overview.md`](architecture/01-system-overview.md)
3. [`architecture/02-availability-model.md`](architecture/02-availability-model.md) — where the SLO comes from
4. [`architecture/03-network-topology.md`](architecture/03-network-topology.md)
5. `infra/terraform/environments/prod/main.tf` — everything wired together in one file

### To evaluate the engineering

- `infra/terraform/modules/cosmosdb/main.tf` — an irreversible decision, reasoned about in place
- `services/api/purple_api/health.py` — why three probes and not one
- `platform/kubernetes/base/api-deployment.yaml` — where the availability behaviour actually lives
- `services/tests/test_rag_isolation.py` — a regression test for a security boundary
- `docs/adr/` — the decisions, including the rejected options

## Making a change

```bash
git switch -c my-change
# edit
make fmt        # canonicalise Terraform formatting
make all        # exactly what CI runs
git commit -am "..." && git push -u origin my-change
```

If `make all` passes locally, CI passes. That is the point of them being the
same commands.

## What will NOT work, and why

| Command | Result | Reason |
|---|---|---|
| `terraform plan` | Fails | Needs real state and real credentials |
| `terraform apply` | Fails | Would create billable resources |
| `kubectl apply` | Fails | There is no cluster |
| `docker push` | Fails | There is no registry |

These are not gaps to be filled in. They are the property that makes this
repository safe to publish. See
[`00-safety-and-placeholders.md`](00-safety-and-placeholders.md).

## If you ever do want to deploy it

Read [`architecture/08-cost-and-finops.md`](architecture/08-cost-and-finops.md)
first — it carries a per-environment cost model. Then:

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init && terraform apply
terraform output backend_config_hcl > ../backend.hcl

cd ../environments/dev                          # dev. Never prod first.
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../../backend.hcl
terraform plan
```

Four values in `terraform.tfvars` are the only thing standing between this
repository and a running platform. Both `terraform.tfvars` and `backend.hcl`
are gitignored, because they carry tenancy identifiers.
