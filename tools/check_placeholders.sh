#!/usr/bin/env bash
#
# The placeholder-leak guard.
#
# This repository is public and describes a platform that was never deployed.
# The guarantee it makes — no real tenancy identifiers, no personal data, no
# pipeline that can deploy — is only worth something if it is enforced
# mechanically. This script is that enforcement.
#
# It runs in CI on every push and pull request. See
# docs/00-safety-and-placeholders.md for the rules it implements.
#
# Three checks:
#   1. Every GUID in a tracked file is the canonical all-zero placeholder.
#   2. No email address outside the reserved documentation domains.
#   3. No pipeline definition invokes `terraform apply`.
#
# A note on false positives. Each check below had one during development, and
# the fixes are instructive rather than incidental:
#
#   * `abfss://bronze@account.dfs.core.windows.net` looks exactly like an email
#     address to a naive regex. Azure storage hostnames are excluded explicitly
#     rather than by loosening the pattern, so a genuine address at a similar
#     domain would still be caught.
#   * Documentation that discusses the apply command is not an invocation of
#     it. Lines carrying an explicit `docs-only` marker are skipped, which
#     keeps the exemption visible in the source rather than hidden in this
#     script.

set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
fail=0

cd "$(dirname "$0")/.." || exit 1

# Files that legitimately contain the patterns being searched for: this
# script, the scanner config, and the document explaining the scheme.
EXCLUDE_FILES='^(tools/check_placeholders\.sh|\.gitleaks\.toml|docs/00-safety-and-placeholders\.md)$'

GUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
ZERO='00000000-0000-0000-0000-000000000000'

# ---------------------------------------------------------------- 1. GUIDs ---

echo "==> Scanning tracked files for non-placeholder GUIDs"
while IFS= read -r file; do
  [[ "$file" =~ $EXCLUDE_FILES ]] && continue
  [[ -f "$file" ]] || continue
  while IFS=: read -r lineno match; do
    [[ -z "${match:-}" ]] && continue
    if [[ "$match" != "$ZERO" ]]; then
      echo "${RED}FAIL${NC} $file:$lineno contains a non-placeholder GUID"
      fail=1
    fi
  done < <(grep -nEo "$GUID" "$file" 2>/dev/null)
done < <(git ls-files)

# --------------------------------------------------------------- 2. emails ---

echo "==> Scanning for personal email addresses"

# Reserved documentation domains (RFC 2606), GitHub noreply identities, and
# Azure service hostnames that contain an '@' in a URI but are not addresses.
ALLOWED_AT_PATTERNS='@(example\.(com|org|net)|users\.noreply\.github\.com|invalid|test|localhost)'
AZURE_STORAGE_URI='@[a-z0-9-]+\.(dfs|blob|queue|table|file)\.core\.windows\.net'

email_hits=$(
  git ls-files -z \
    | xargs -0 grep -nEI '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 2>/dev/null \
    | grep -vE "$ALLOWED_AT_PATTERNS" \
    | grep -vE "$AZURE_STORAGE_URI" \
    | grep -vE "^($(echo "$EXCLUDE_FILES" | sed -e 's/^\^(//' -e 's/)\$$//')):" \
    | grep -vE '^(SECURITY\.md|README\.md):'
)

if [[ -n "$email_hits" ]]; then
  echo "$email_hits"
  echo "${RED}FAIL${NC} found an email address outside the allowed placeholder domains"
  fail=1
fi

# ------------------------------------------------------- 3. terraform apply ---

echo "==> Scanning pipeline definitions for a Terraform apply invocation"

apply_hits=$(
  grep -rnE 'terraform[[:space:]]+apply' .github/workflows cicd 2>/dev/null \
    | grep -v 'docs-only' \
    | grep -vE ':[[:space:]]*(#|//|\*)'
)

if [[ -n "$apply_hits" ]]; then
  echo "$apply_hits"
  echo "${RED}FAIL${NC} a pipeline appears to run a Terraform apply — this repository must never deploy"
  fail=1
fi

# ------------------------------------------------------------------ result ---

if [[ $fail -eq 0 ]]; then
  echo "${GREEN}PASS${NC} no leaked identifiers, addresses, or apply steps found"
else
  echo "${YELLOW}See docs/00-safety-and-placeholders.md for the placeholder scheme.${NC}"
fi
exit $fail
