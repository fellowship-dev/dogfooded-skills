#!/usr/bin/env bash
# Collect fail-closed CI evidence for one immutable PR head.  Output is one JSON object.
set -u

REPO=${1:?usage: collect_ci_evidence.sh org/repo head-sha}
HEAD_SHA=${2:?usage: collect_ci_evidence.sh org/repo head-sha}
# The caller supplies the PR base branch because required checks are branch-specific.
BASE_BRANCH=${3:?usage: collect_ci_evidence.sh org/repo head-sha base-branch}

CHECK_RUNS=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" 2>/dev/null) || CHECK_RUNS_OK=false
: "${CHECK_RUNS_OK:=true}"
COMMIT_STATUSES=$(gh api "repos/$REPO/commits/$HEAD_SHA/status" 2>/dev/null) || COMMIT_STATUSES_OK=false
: "${COMMIT_STATUSES_OK:=true}"

REQUIRED=$(gh api "repos/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" 2>/tmp/cto-required.err) || REQUIRED_STATUS=$?
if grep -q '404' /tmp/cto-required.err; then
  REQUIRED='{"contexts":[]}'
  REQUIRED_OK=true
elif [ "${REQUIRED_STATUS:-0}" = "0" ]; then
  REQUIRED_OK=true
else
  REQUIRED_OK=false
fi

RULESETS=$(gh api "repos/$REPO/rules/branches/$BASE_BRANCH" 2>/tmp/cto-rulesets.err) || RULESETS_STATUS=$?
if grep -q '404' /tmp/cto-rulesets.err; then
  RULESETS='[]'
elif [ "${RULESETS_STATUS:-0}" != "0" ]; then
  REQUIRED_OK=false
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
    content=$(gh api "repos/$REPO/contents/$path?ref=$HEAD_SHA" --jq .content 2>/dev/null | base64 -d) || exit 1
    if printf '%s\n' "$content" | python3 -c '
import re, sys
text = sys.stdin.read()
trigger = re.compile(r"^[ \\t]*(pull_request|pull_request_target|[\\\"\\x27](pull_request|pull_request_target)[\\\"\\x27])[ \\t]*:", re.M)
inline = re.compile(r"^[ \\t]*on[ \\t]*:[^#\\n]*(pull_request|pull_request_target)", re.M)
sys.exit(0 if trigger.search(text) or inline.search(text) else 1)
'; then printf '%s\n' "$path"; fi
  done | jq -Rsc 'split("\n") | map(select(length > 0))') || WORKFLOW_TREE_OK=false
fi

jq -n \
  --argjson runs "${CHECK_RUNS:-null}" \
  --argjson statuses "${COMMIT_STATUSES:-null}" \
  --argjson required "${REQUIRED:-null}" \
  --argjson rulesets "${RULESETS:-null}" --argjson workflows "${PR_WORKFLOWS:-null}" \
  --arg check_ok "$CHECK_RUNS_OK" --arg status_ok "$COMMIT_STATUSES_OK" --arg required_ok "$REQUIRED_OK" --arg workflow_ok "$WORKFLOW_TREE_OK" \
  '{check_runs_ok: ($check_ok == "true"), commit_statuses_ok: ($status_ok == "true"), expected_checks_ok: ($required_ok == "true"), pr_workflows_ok: ($workflow_ok == "true"), check_runs: ($runs.check_runs // null), commit_statuses: ($statuses.statuses // null), expected_checks: (($required.contexts // []) + ($required.checks // [] | map(.context // .)) + [$rulesets[]?.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?]), pr_workflows: $workflows}'
