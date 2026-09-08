# Azure Data & AI Platform — local check runner
#
# Mirrors exactly what CI runs, so "it passed locally" means something.
# Every tool is optional: a missing tool is reported as SKIP, never a failure.
# That lets you clone this repo with nothing installed and add tools over time.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF_DIRS := $(shell find infra/terraform -type f -name '*.tf' -exec dirname {} \; 2>/dev/null | sort -u)

CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
NC := \033[0m

define need
@command -v $(1) >/dev/null 2>&1 || { printf "$(YELLOW)SKIP$(NC) %s not installed — %s\n" "$(1)" "$(2)"; exit 0; }
endef

.PHONY: help
help: ## Show this help
	@printf "$(CYAN)Azure Data & AI Platform$(NC)\n\n"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-14s$(NC) %s\n", $$1, $$2}'
	@printf "\n  No Azure credentials are required, or accepted, by any target.\n\n"

# ------------------------------------------------------------------ setup ---

.PHONY: setup
setup: ## Configure the local git identity so no personal email reaches the log
	@# Local git config does NOT survive a fresh clone, so a new clone would
	@# inherit your GLOBAL identity — which is usually a personal address, and
	@# it would be permanently embedded in this public repository's history.
	@# This target is the fix, and it is why the docs tell you to run it first.
	@git config --local user.name "Yamuna Miriyala"
	@git config --local user.email "38241689+yamunamiriyala@users.noreply.github.com"
	@printf "$(GREEN)Commit identity set to:$(NC) %s <%s>\n" \
	  "$$(git config user.name)" "$$(git config user.email)"
	@printf "  A GitHub noreply address keeps your personal email out of the public log.\n"

.PHONY: lock
lock: ## Regenerate Terraform lock files for every platform CI and dev use
	$(call need,terraform,https://developer.hashicorp.com/terraform/install)
	@# A lock file generated on one OS records only that OS's checksums, so CI
	@# on linux fails with a checksum mismatch. Locking all three platforms up
	@# front is the fix.
	@set -e; for d in $(TF_DIRS); do \
	  grep -rqs 'required_providers' $$d/*.tf || continue; \
	  printf "$(CYAN)==> %s$(NC)\n" "$$d"; \
	  terraform -chdir=$$d providers lock \
	    -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64 >/dev/null; \
	done
	@printf "$(GREEN)Lock files regenerated.$(NC)\n"

# ---------------------------------------------------------------- validate ---

.PHONY: fmt
fmt: ## Rewrite Terraform files into canonical format
	$(call need,terraform,https://developer.hashicorp.com/terraform/install)
	@terraform fmt -recursive infra/

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	$(call need,terraform,https://developer.hashicorp.com/terraform/install)
	@terraform fmt -recursive -check -diff infra/

.PHONY: validate
validate: fmt-check ## terraform init -backend=false + validate, every directory
	$(call need,terraform,https://developer.hashicorp.com/terraform/install)
	@set -e; for d in $(TF_DIRS); do \
	  printf "$(CYAN)==> %s$(NC)\n" "$$d"; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	done

.PHONY: validate-bundle
validate-bundle: ## databricks bundle validate (needs a workspace; NOT part of `all`)
	$(call need,databricks,https://docs.databricks.com/dev-tools/cli/install.html)
	@# Deliberately excluded from `all` and from CI.
	@#
	@# `bundle validate` authenticates to a workspace before it will resolve
	@# variables, so it cannot run in a pipeline that holds no credentials —
	@# and no pipeline here does. Running it anyway would mean either giving
	@# CI a workspace token or watching a permanently red job.
	@#
	@# What CI can check without credentials is that the YAML parses and that
	@# every key exists in the CLI's schema. That is `lint-bundle`.
	@cd data/databricks && databricks bundle validate --target $(or $(TARGET),dev)

.PHONY: lint-bundle
lint-bundle: ## Parse the bundle YAML and check it against the Databricks schema
	$(call need,databricks,https://docs.databricks.com/dev-tools/cli/install.html)
	@databricks bundle schema > /tmp/dab-schema.json
	@python3 tools/check_bundle_schema.py

# -------------------------------------------------------------------- lint ---

.PHONY: lint
lint: lint-tf lint-py lint-k8s ## Run every linter

.PHONY: lint-tf
lint-tf: ## tflint across all Terraform directories
	$(call need,tflint,https://github.com/terraform-linters/tflint)
	@tflint --init >/dev/null 2>&1 || true
	@tflint --recursive --minimum-failure-severity=warning

.PHONY: lint-py
lint-py: ## ruff + mypy over the Python services
	$(call need,ruff,pip install ruff)
	@ruff check services/ data/
	@ruff format --check services/ data/
	@command -v mypy >/dev/null 2>&1 && mypy services/ || \
	  printf "$(YELLOW)SKIP$(NC) mypy not installed\n"

.PHONY: lint-k8s
lint-k8s: build-k8s ## kube-linter over the RENDERED Kubernetes manifests
	$(call need,kube-linter,https://github.com/stackrox/kube-linter)
	@# Lint the rendered output, not the base. The base contains placeholders
	@# that an overlay replaces, so linting it reports problems that do not
	@# exist in anything that would ever be applied.
	@kustomize build platform/kubernetes/overlays/prod \
	  | kube-linter lint - --config .kube-linter.yaml

.PHONY: build-k8s
build-k8s: ## Verify every Kustomize overlay builds
	$(call need,kustomize,https://kubectl.docs.kubernetes.io/installation/kustomize/)
	@set -e; for o in platform/kubernetes/overlays/*/; do \
	  printf "$(CYAN)==> %s$(NC)\n" "$$o"; \
	  kustomize build "$$o" >/dev/null; \
	done
	@printf "$(GREEN)All overlays build.$(NC)\n"

# ---------------------------------------------------------------- security ---

.PHONY: security
security: secrets placeholders checkov tfsec ## Run every security scanner

.PHONY: secrets
secrets: ## gitleaks over the full git history
	$(call need,gitleaks,https://github.com/gitleaks/gitleaks)
	@gitleaks detect --config .gitleaks.toml --redact --verbose

.PHONY: placeholders
placeholders: ## Fail if a non-placeholder GUID or personal email is tracked
	@bash tools/check_placeholders.sh

.PHONY: checkov
checkov: ## Checkov policy scan of the Terraform
	$(call need,checkov,pip install checkov)
	@checkov --directory infra/terraform --quiet --compact --framework terraform

.PHONY: tfsec
tfsec: ## trivy config scan of the Terraform
	$(call need,trivy,https://github.com/aquasecurity/trivy)
	@trivy config infra/terraform --exit-code 1 --severity HIGH,CRITICAL

# -------------------------------------------------------------------- test ---

.PHONY: test
test: ## pytest for the Python services
	$(call need,pytest,pip install -r services/requirements-dev.txt)
	@pytest services/ -q

# --------------------------------------------------------------------- all ---

.PHONY: all
all: validate lint security test ## Everything CI runs, in CI order
	@printf "\n$(GREEN)All checks complete.$(NC)\n"

.PHONY: clean
clean: ## Remove Terraform working directories and Python caches
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
	@rm -rf .pytest_cache .ruff_cache .mypy_cache
	@printf "$(GREEN)Cleaned.$(NC)\n"
