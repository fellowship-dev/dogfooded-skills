#!/usr/bin/env bash
set -euo pipefail

repo="${1:?usage: resolve-merge-strategy.sh <org/repo>}"
pylot_bin="${PYLOT_CLI_BIN:-pylot}"

# Team configuration is DB-authoritative. Failure or ambiguity must remove merge
# authority rather than silently restoring it.
if ! teams_json="$("$pylot_bin" teams list 2>/dev/null)"; then
  echo "label-only"
  exit 0
fi

strategy="$({
  printf '%s' "$teams_json" | jq -r --arg repo "$repo" '
    [
      .teams[]?
      | select(any(.repos[]?; ascii_downcase == ($repo | ascii_downcase)))
      | (.deploy.release_mode // "propose")
    ]
    | if length == 1 and .[0] == "ship" then "auto" else "label-only" end
  '
} 2>/dev/null || true)"

# Exactly one explicit `ship` policy grants automated merge authority. Missing,
# malformed, conflicting, or `propose` configuration is fail-closed.
case "$strategy" in
  auto) echo "auto" ;;
  *) echo "label-only" ;;
esac
