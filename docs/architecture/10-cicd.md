# CI/CD

> What runs here, what would run in a funded environment, and why the gap is
> deliberate.

## What actually runs in this repository

Every pipeline is **credential-free**. There is no `AZURE_CLIENT_SECRET`, no
OIDC federated credential, and no service principal wired into GitHub Actions
or Jenkins.

That is not a gap to be filled. It is the property that makes this repository
safe to publish, and it mechanically limits what any pipeline can do:

| Stage | Tool | Needs credentials? |
|---|---|---|
| Format | `terraform fmt -check` | No |
| Validate | `terraform validate -backend=false` | No |
| Lint | `tflint`, `ruff`, `kube-linter` | No |
| Build | `kustomize build` | No |
| Test | `pytest` | No |
| Scan | `checkov`, `trivy`, `gitleaks` | No |
| Guard | `tools/check_placeholders.sh` | No |

Notice what is absent: **`terraform plan` and `terraform apply`**. A `plan`
requires reading real state from a real backend; an `apply` creates billable
resources. Neither can run, because neither has anything to authenticate with.

`tools/check_placeholders.sh` fails the build if a Terraform apply invocation
ever appears in a pipeline definition, so this property is enforced rather than
merely intended.

## What a funded environment would add

### Workload identity federation — no stored secret

The important part, and the one most teams get wrong by storing a service
principal secret in a pipeline variable.

```hcl
# infra/terraform/modules/identity/main.tf — defined, deliberately unused.
resource "azurerm_federated_identity_credential" "github" {
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "repo:Opsworkspace/azure-data-ai-platform:environment:prod"
  parent_id = azurerm_user_assigned_identity.github["deploy"].id
}
```

The `subject` pins the credential to one repository **and one trigger**.
`environment:prod` cannot be claimed by a pull request from a fork — which is
precisely the attack this format exists to prevent. A wildcard subject would
let any branch deploy to production.

The workflow side:

```yaml
permissions:
  id-token: write      # required to request the OIDC token
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}        # an identifier, not a secret
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

Note these are `vars`, not `secrets`. None of them is confidential — the
security comes from the federation trust, not from hiding the client id.

### Plan on pull request

The single highest-value check in IaC, and it cannot run here.

```yaml
- run: terraform plan -detailed-exitcode -out=tfplan
```

`-detailed-exitcode` returns:

| Code | Meaning | Action |
|---|---|---|
| 0 | No changes | **Skip the approval gate entirely** |
| 1 | Error | Fail |
| 2 | Changes | Proceed to approval |

Exit code 0 is the useful one. It stops approvers being asked to rubber-stamp
no-op deployments — and an approver who approves twenty no-ops stops reading
the twenty-first.

The plan output is posted as a PR comment so the reviewer sees exactly what
will change. That is the review, far more than reading the diff.

### Apply the saved plan

```yaml
- run: terraform apply -auto-approve tfplan     # the SAVED plan
```

Applying the saved plan guarantees that **what was approved is what runs**.
Re-planning at apply time means approving one thing and applying another — and
between the two, someone else may have changed something.

### Progressive delivery

The deployment sequence, with an automated analysis gate between steps:

```
5% ──► 25% ──► 50% ──► 100%
   │       │       │
   └───────┴───────┴──► error rate and p99 compared against baseline;
                        automatic rollback on regression
```

The critical part is not the canary — it is the **automated analysis**. A
canary a human eyeballs gets approved at 5pm on a Friday because the graph
"looked fine". Flagger or Argo Rollouts implement this properly, and both
integrate with the managed Prometheus workspace this platform already runs.

## The private-cluster problem

The AKS API server has **no public endpoint** ([ADR 0006](../adr/0006-aks-private-cluster.md)).
A GitHub-hosted runner physically cannot reach it. Three options:

| Option | Trade-off |
|---|---|
| `az aks command invoke` | Works, but it is a shell-in-a-box: no streaming, awkward file transfer, every command through ARM |
| Self-hosted GitHub runners in the VNet | Clean, and what most greenfield teams choose now. You operate and patch runner VMs |
| Jenkins agents in the VNet | Often what already exists, because the organisation adopted Jenkins before Azure |

This is the concrete reason `cicd/jenkins/` exists here. Jenkins' real
advantage is not features — it is that the agent runs where you put it, and in
a private-network platform that is sometimes decisive.

## GitHub Actions vs Jenkins

| | GitHub Actions | Jenkins |
|---|---|---|
| Definition | YAML | Groovy DSL |
| Setup cost | Zero | A controller, agents, plugins, upgrades |
| Reach into a private VNet | Needs self-hosted runners | Agent runs wherever you put it |
| Secrets | OIDC federation, none stored | Credentials store, usually long-lived |
| Reuse | Composite actions, reusable workflows | Shared libraries (`vars/`) |
| Failure mode | GitHub outage stops all builds | Your controller is a SPOF you own |
| Testing the reusable parts | Poor | Poor (`JenkinsPipelineUnit` exists, rarely used) |

Both are here so the comparison is concrete rather than theoretical. For a
greenfield platform, Actions with self-hosted runners is usually the right
answer; the honest exception is an organisation with an existing Jenkins estate
and agents already inside the network.

## Supply chain

The order matters, and teams commonly get it backwards:

```
build ──► scan ──► sign ──► push ──► SBOM
```

**Scan before push.** Scan after push and the vulnerable image is already in
the registry, already pullable, and removing it is a race against whatever
might have pulled it. Scan first and a failing image never exists anywhere but
the build agent.

Two policy decisions worth stating:

- **Fail on HIGH/CRITICAL only.** Fail on MEDIUM and the pipeline is
  permanently red, because base images always carry some medium findings with
  no available fix. A permanently red pipeline is one nobody reads.
- **`--ignore-unfixed`.** A CVE with no patch cannot be actioned by this build,
  and blocking on it stops deployment of the fix for something else.

An **SBOM** is generated per image. When the next Log4Shell lands, "are we
affected?" is answered by grepping SBOMs in seconds rather than rebuilding and
inspecting every image over a weekend.

## Reproducible builds

```dockerfile
export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
```

Pins timestamps written into the image so building the same commit twice
produces the same digest. Without it every rebuild differs by file mtimes
alone, and "is this the image we tested?" becomes unanswerable.

Production deploys by **digest**, not tag. A tag is a mutable pointer; a digest
is content-addressed and cannot change meaning. It is also what makes a
rollback trustworthy — you restore exactly the artefact that was running, not
whatever the tag says now.

## Related

- `.github/workflows/` — what actually runs
- `cicd/jenkins/` — the same problem, different tool
- [`00-safety-and-placeholders.md`](../00-safety-and-placeholders.md) — Rule 1
- ADR: [0006 — private AKS cluster](../adr/0006-aks-private-cluster.md)
