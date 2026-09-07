#!/usr/bin/env bash
#
# First push — structured commits.
#
# Review this file, edit any message you disagree with, then run it:
#
#     bash tools/first-push.sh
#
# It stages and commits in logical groups rather than making one enormous
# "initial commit". That is worth the extra effort: a reviewer reading the
# history sees the platform being built in the order it was reasoned about,
# and `git log --oneline` becomes a table of contents.
#
# It does NOT push. The final command is printed for you to run yourself.

set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Guard: refuse to commit if the safety checks do not pass.
#
# This is the whole point of having them. A guard that can be skipped by
# forgetting to run it is not a guard.
# ---------------------------------------------------------------------------
echo "==> Running the placeholder-leak guard before committing"
git add -A
bash tools/check_placeholders.sh || {
  echo "REFUSING TO COMMIT: the placeholder guard failed. Fix the findings above."
  exit 1
}
git reset >/dev/null

# ---------------------------------------------------------------------------
# Commit identity.
#
# The repo-local identity uses a GitHub noreply address so no personal email
# is embedded in the public commit log. Verify it before the first commit,
# because rewriting author metadata afterwards means rewriting history.
# ---------------------------------------------------------------------------
echo "==> Commit identity: $(git config user.name) <$(git config user.email)>"
case "$(git config user.email)" in
  *@users.noreply.github.com) ;;
  *)
    echo "WARNING: commit email is not a GitHub noreply address."
    echo "         It will be permanently visible in this public repository."
    echo "         Fix with:"
    echo "           git config --local user.email '38241689+yamunamiriyala@users.noreply.github.com'"
    read -r -p "         Continue anyway? [y/N] " reply
    [[ "$reply" == "y" ]] || exit 1
    ;;
esac

commit () {
  local message="$1"; shift
  git add -- "$@"
  if git diff --cached --quiet; then
    echo "  (nothing staged for: ${message%%$'\n'*})"
    return
  fi
  git commit --quiet -m "$message"
  echo "  ✓ ${message%%$'\n'*}"
}

echo
echo "==> Committing"

commit "chore: repository scaffolding, licence, and safety guards

Establishes the contract the rest of the repository keeps: no cloud
credentials in any pipeline, no real tenancy identifiers, no personal data,
and no path by which this code can deploy anything.

tools/check_placeholders.sh enforces all three mechanically and runs in CI." \
  .editorconfig .gitignore .gitleaks.toml LICENSE CODEOWNERS SECURITY.md \
  Makefile pyproject.toml tools/ docs/00-safety-and-placeholders.md

commit "feat(terraform): naming module and network foundation

- naming: a module that creates nothing and makes every name and tag a
  derived value, so cost queries and policy assignments can match reliably
- network-hub: firewall, Bastion, and the egress allow-list
- network-spoke: workload subnets computed with cidrsubnet(), NSGs with
  explicit terminal denies, and forced tunnelling to the hub firewall
- private-dns: the zones that make private endpoints actually resolvable

Subnet CIDRs are computed rather than typed, which makes overlap
arithmetically impossible." \
  infra/terraform/modules/naming \
  infra/terraform/modules/network-hub \
  infra/terraform/modules/network-spoke \
  infra/terraform/modules/private-dns

commit "feat(terraform): data plane modules

- cosmosdb: partition keys chosen deliberately (/userId, not /tenantId) with
  the reasoning recorded, session consistency, and optional multi-region writes
- lakehouse: ADLS Gen2 with hierarchical namespace, medallion containers,
  lifecycle tiering, and separate blob + dfs private endpoints
- key-vault: RBAC authorisation rather than access policies; creates no secrets
- container-registry: admin account disabled, geo-replication, private endpoint

Every service has public_network_access_enabled = false and identity-based
access only — no shared keys anywhere." \
  infra/terraform/modules/cosmosdb \
  infra/terraform/modules/lakehouse \
  infra/terraform/modules/key-vault \
  infra/terraform/modules/container-registry

commit "feat(terraform): compute, analytics, AI, identity, and edge

- aks: private cluster, Azure CNI Overlay, workload identity, Azure RBAC with
  the local admin account disabled, and userDefinedRouting egress
- databricks: VNet injection with secure cluster connectivity, plus the
  Unity Catalog access connector
- ai-services: Azure OpenAI deployments and AI Search for the RAG path
- identity: workload identity federation — the mechanism that removes every
  application credential from the platform
- observability: Log Analytics, App Insights, managed Prometheus, Grafana,
  and multi-window multi-burn-rate SLO alerts
- front-door: WAF, rate limiting, and health-probe-driven regional failover" \
  infra/terraform/modules/aks \
  infra/terraform/modules/databricks \
  infra/terraform/modules/ai-services \
  infra/terraform/modules/identity \
  infra/terraform/modules/observability \
  infra/terraform/modules/front-door

commit "feat(terraform): state backend and dev/stage/prod environments

- bootstrap: solves the chicken-and-egg problem of where state lives, using
  local state deliberately and documenting why that is acceptable only here
- prod: dual-region active-active
- stage: single region at production fidelity — validates what dev cannot
- dev: single region, cost-optimised, with an identical security posture

The environments differ only in module ARGUMENTS. Each records its cost and
fidelity trade-offs as a Terraform output, so they can be diffed rather than
read side by side." \
  infra/terraform/bootstrap infra/terraform/environments

commit "feat(services): API and ingestion worker

- FastAPI service with three distinct health probes; liveness deliberately
  checks no dependencies, because a dependency check there turns an outage
  into a cluster-wide restart storm
- RAG retrieval with a server-side per-user filter — the platform's tenant
  isolation boundary — plus regression tests that fail if it is removed
- Ingestion worker built to be idempotent and interruptible, so it can run
  on spot nodes
- Distroless-style multi-stage Dockerfiles, non-root, read-only root filesystem

24 tests, ruff clean." \
  services/

commit "feat(k8s): manifests, overlays, and admission policy

- Deployments carrying the availability behaviour: maxUnavailable 0, zone
  topology spread, PodDisruptionBudgets, and a preStop hook that holds the
  container open while endpoint removal propagates
- NetworkPolicy default-deny, with IMDS blocked to close the pod-to-node
  privilege escalation path
- Secrets mounted from Key Vault via CSI rather than stored in etcd
- Kustomize overlays for dev and prod
- Gatekeeper constraints, all starting in dryrun

Both overlays build and render correctly." \
  platform/kubernetes

commit "feat(policy): Azure Policy as code

Guard rails that apply to the subscription rather than to Terraform, so they
also cover resources created in the portal, by another team, or by an Azure
service. Every effect defaults to Audit: a Deny policy assigned to a
subscription that already contains non-compliant resources blocks the next
legitimate change to them." \
  platform/policies

commit "feat(data): Unity Catalog governance and the medallion pipeline

- Catalog, schema, external location and grant definitions, granted to groups
  rather than individuals, with row filters and column masks
- Bronze/silver/gold notebooks: bronze never transforms, silver quarantines
  bad rows rather than dropping them silently, gold is fully reproducible
- Vector index build with a hard assertion that every indexed chunk carries
  the user id the API filters on

Notebooks are stored as .py source, not .ipynb — an .ipynb embeds output
cells, which in a data platform means committing query results to git." \
  data/

commit "feat(cicd): Jenkins pipelines and shared library

The same delivery problem as the GitHub Actions workflows, solved with a
different tool, so the trade-off between them is concrete rather than
theoretical.

The deployment pipeline aborts in its first stage. It documents approval
gates, progressive rollout and automated rollback, and cannot run." \
  cicd/

commit "ci: validation and security workflows

Credential-free by construction. No workflow is granted an Azure identity,
which is what mechanically prevents any of them from planning or applying." \
  .github/

commit "docs: architecture reference

Eleven documents covering the system, availability, networking, identity,
compute, data, observability, cost, security, CI/CD and disaster recovery.

The availability model works through why the SLO is 99.95% rather than a
marketing 99.99%: composing the hard dependencies' published SLAs gives a
theoretical ceiling of about 99.97%, and committing to a number above the
architecture's own ceiling teaches everyone that the SLO means nothing.

The security model documents what the design does NOT protect against, which
is the section most worth reading." \
  docs/architecture/ docs/README.md docs/00-how-to-use-this-repo.md

commit "docs: architecture decision records

Eight records covering the decisions that are expensive or impossible to
reverse, each with the alternatives that were rejected and why.

The Cosmos partition key record is the one that matters most: /tenantId is the
intuitive choice for a B2B SaaS and creates a hot partition for the largest
customer, capped at 10,000 RU/s no matter what the container is provisioned
for." \
  docs/adr/

commit "docs: operational runbooks

Six runbooks, written for someone who has been woken up, is not the person who
built the system, and has about ninety seconds of patience.

Each starts with the single highest-information command rather than with
background, and mitigates before diagnosing. The Cosmos runbook exists largely
to stop the reflex of raising throughput, which does nothing at all when the
cause is a hot partition." \
  docs/runbooks/

echo
echo "==> Commit history"
git --no-pager log --oneline
echo
echo "==> Nothing has been pushed yet. To publish:"
echo
echo "      git push -u origin main"
echo
