#!/usr/bin/env bash
#
# Validate every Terraform directory in the repository.
#
# Identical to what .github/workflows/validate.yml runs, so a green run here
# means a green run in CI. Uses -backend=false throughout: no state is read,
# no credentials are used, nothing is contacted except the provider registry.

set -uo pipefail

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

# A shared plugin cache turns ~20 provider downloads into one.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

cd "$(dirname "$0")/.." || exit 1

fail=0
while IFS= read -r dir; do
  printf "%s==> %s%s\n" "$CYAN" "$dir" "$NC"
  if ! terraform -chdir="$dir" init -backend=false -input=false -no-color >/dev/null 2>&1; then
    printf "%sINIT FAILED%s %s\n" "$RED" "$NC" "$dir"
    terraform -chdir="$dir" init -backend=false -input=false -no-color 2>&1 | tail -20
    fail=1
    continue
  fi
  if ! terraform -chdir="$dir" validate -no-color; then
    fail=1
  fi
done < <(find infra/terraform -type f -name '*.tf' -exec dirname {} \; | sort -u)

if [[ $fail -eq 0 ]]; then
  printf "\n%sAll Terraform directories are valid.%s\n" "$GREEN" "$NC"
else
  printf "\n%sValidation failed.%s\n" "$RED" "$NC"
fi
exit $fail
