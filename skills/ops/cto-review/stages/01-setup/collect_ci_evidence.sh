#!/usr/bin/env bash
# Collect fail-closed CI evidence for one immutable PR head.  Output is one JSON object.
set -u -o pipefail

REPO=${1:?usage: collect_ci_evidence.sh org/repo head-sha}
HEAD_SHA=${2:?usage: collect_ci_evidence.sh org/repo head-sha}
# The caller supplies the PR base branch because required checks are branch-specific.
BASE_BRANCH=${3:?usage: collect_ci_evidence.sh org/repo head-sha base-branch}

# Required-check and ruleset API failures must be attributed to this invocation.
# Shared /tmp paths let another concurrent review replace stderr between a failed
# request and its 404 check, which could incorrectly turn a failure into an
# unprotected configuration. Keep this directory private and remove it on exit.
CI_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cto-ci-evidence.XXXXXX") || exit 1
trap 'rm -rf "$CI_TMP_DIR"' EXIT

# Fetch every page and prove the response is complete. A green first page cannot
# establish merge safety when GitHub reports more evidence than it returned there.
collect_paginated() {
  local endpoint=$1 item_key=$2 page=1 expected=-1 count=0 previous=0 response parsed total items
  local collected='[]'
  while :; do
    response=$(gh api "${endpoint}?per_page=100&page=$page" 2>/dev/null) || return 1
    parsed=$(printf '%s' "$response" | jq -ce --arg key "$item_key" '
      if type != "object"
         or (.total_count | type) != "number"
         or (.total_count < 0)
         or ((.total_count | floor) != .total_count)
         or (.[$key] | type) != "array"
      then error("malformed paginated CI response")
      else {total_count, items: .[$key]}
      end
    ') || return 1
    total=$(printf '%s' "$parsed" | jq -r .total_count)
    items=$(printf '%s' "$parsed" | jq -c .items)
    if [ "$expected" = -1 ]; then expected=$total; elif [ "$expected" != "$total" ]; then return 1; fi
    previous=$count
    collected=$(jq -cn --argjson prior "$collected" --argjson next "$items" '$prior + $next') || return 1
    count=$(printf '%s' "$collected" | jq 'length') || return 1
    if [ "$count" -gt "$expected" ]; then return 1; fi
    if [ "$count" = "$expected" ]; then printf '%s\n' "$collected"; return 0; fi
    # An empty page before total_count is reached is incomplete evidence.
    if [ "$count" = "$previous" ]; then return 1; fi
    page=$((page + 1))
  done
}

CHECK_RUNS_ITEMS=$(collect_paginated "repos/$REPO/commits/$HEAD_SHA/check-runs" check_runs) || CHECK_RUNS_OK=false
: "${CHECK_RUNS_OK:=true}"
CHECK_RUNS=$(jq -cn --argjson items "${CHECK_RUNS_ITEMS:-null}" '{check_runs: $items}')
COMMIT_STATUS_ITEMS=$(collect_paginated "repos/$REPO/commits/$HEAD_SHA/status" statuses) || COMMIT_STATUSES_OK=false
: "${COMMIT_STATUSES_OK:=true}"
COMMIT_STATUSES=$(jq -cn --argjson items "${COMMIT_STATUS_ITEMS:-null}" '{statuses: $items}')

REQUIRED=$(gh api "repos/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" 2>"$CI_TMP_DIR/required.err") || REQUIRED_STATUS=$?
if grep -q '404' "$CI_TMP_DIR/required.err"; then
  REQUIRED='{"contexts":[]}'
  REQUIRED_OK=true
elif [ "${REQUIRED_STATUS:-0}" = "0" ]; then
  # A successful response is evidence only when it has the documented shape.
  # Do not normalize malformed required-check configurations into an empty set.
  if printf '%s' "$REQUIRED" | jq -e '
    type == "object"
    and (.contexts | type == "array")
    and all(.contexts[]; type == "string")
    and ((has("checks") | not) or (
      (.checks | type == "array")
      and all(.checks[]; type == "string" or (type == "object" and (.context | type == "string")))
    ))
  ' >/dev/null; then
    REQUIRED_OK=true
  else
    REQUIRED_OK=false
  fi
else
  REQUIRED_OK=false
fi

RULESETS=$(gh api "repos/$REPO/rules/branches/$BASE_BRANCH" 2>"$CI_TMP_DIR/rulesets.err") || RULESETS_STATUS=$?
if grep -q '404' "$CI_TMP_DIR/rulesets.err"; then
  RULESETS='[]'
  RULESETS_OK=true
elif [ "${RULESETS_STATUS:-0}" != "0" ]; then
  RULESETS_OK=false
elif printf '%s' "$RULESETS" | jq -e '
  type == "array"
  and all(.[];
    type == "object"
    and (.rules | type == "array")
    and all(.rules[];
      type == "object"
      and (if .type == "required_status_checks" then
        (.parameters | type == "object")
        and (.parameters.required_status_checks | type == "array")
        and all(.parameters.required_status_checks[];
          type == "string" or (type == "object" and (.context | type == "string"))
        )
      else true end)
    )
  )
' >/dev/null; then
  RULESETS_OK=true
else
  RULESETS_OK=false
fi

WORKFLOW_TREE=$(gh api "repos/$REPO/git/trees/$HEAD_SHA?recursive=1" 2>/dev/null) || WORKFLOW_TREE_OK=false
: "${WORKFLOW_TREE_OK:=true}"
PR_WORKFLOWS='[]'
if [ "$WORKFLOW_TREE_OK" = true ]; then
  WORKFLOW_PATHS=$(echo "$WORKFLOW_TREE" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("truncated") is True or not isinstance(payload.get("tree"), list):
    sys.exit(1)
for item in payload["tree"]:
    if not isinstance(item, dict):
        sys.exit(1)
    path = item.get("path", "")
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        print(path)
') || WORKFLOW_TREE_OK=false
fi
if [ "$WORKFLOW_TREE_OK" = true ]; then
  PR_WORKFLOWS=$(printf '%s\n' "$WORKFLOW_PATHS" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    content=$(gh api "repos/$REPO/contents/$path?ref=$HEAD_SHA" --jq .content 2>/dev/null | base64 -d) || exit 1
    if printf '%s\n' "$content" | python3 -c '
import re, sys
text = sys.stdin.read()
event = r"(?:pull_request|pull_request_target)"
mapping = re.compile(rf"^[ \\t]*(?:{event}|[\\\"\\x27]{event}[\\\"\\x27])[ \\t]*:", re.M)
inline = re.compile(rf"^[ \\t]*on[ \\t]*:[^#\\n]*(?:{event})", re.M)
block_list = re.compile(rf"^[ \\t]*on[ \\t]*:[ \\t]*(?:#.*)?$[\\s\\S]*?^[ \\t]+-[ \\t]*(?:[\\\"\\x27]?{event}[\\\"\\x27]?)(?:[ \\t]*(?:#.*)?)$", re.M)
sys.exit(0 if mapping.search(text) or inline.search(text) or block_list.search(text) else 1)
'; then printf '%s\n' "$path"; fi
  done | jq -Rsc 'split("\n") | map(select(length > 0))') || WORKFLOW_TREE_OK=false
fi

jq -n \
  --argjson runs "${CHECK_RUNS:-null}" \
  --argjson statuses "${COMMIT_STATUSES:-null}" \
  --argjson required "${REQUIRED:-null}" \
  --argjson rulesets "${RULESETS:-null}" --argjson workflows "${PR_WORKFLOWS:-null}" \
  --arg check_ok "$CHECK_RUNS_OK" --arg status_ok "$COMMIT_STATUSES_OK" --arg required_ok "$REQUIRED_OK" --arg rulesets_ok "$RULESETS_OK" --arg workflow_ok "$WORKFLOW_TREE_OK" \
  '{check_runs_ok: ($check_ok == "true"), commit_statuses_ok: ($status_ok == "true"), expected_checks_ok: ($required_ok == "true" and $rulesets_ok == "true"), pr_workflows_ok: ($workflow_ok == "true"), check_runs: ($runs.check_runs // null), commit_statuses: ($statuses.statuses // null), expected_checks: (($required.contexts // []) + ($required.checks // [] | map(.context // .)) + [$rulesets[]?.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | if type == "object" then .context else . end]), pr_workflows: $workflows}'
