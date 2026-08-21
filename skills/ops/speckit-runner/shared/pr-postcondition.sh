#!/bin/sh
# Fail-closed PR postcondition for the supervisor-owned verification disclosure.
# Shell variables cannot contain NUL; all other bytes, including tabs and
# newlines, are compared literally under the byte locale.

pr_body_contains_literal() (
  pr_body_haystack=$1
  pr_body_needle=$2
  [ -n "$pr_body_needle" ] || exit 1
  LC_ALL=C
  export LC_ALL
  case "$pr_body_haystack" in
    *"$pr_body_needle"*) exit 0 ;;
    *) exit 1 ;;
  esac
)

verify_pr_postcondition() {
  : "${REPO:?REPO required}"
  : "${BRANCH:?BRANCH required}"
  : "${ISSUE_NUMBER:?ISSUE_NUMBER required}"
  : "${SUPERVISOR_DISCLOSURE:?SUPERVISOR_DISCLOSURE required}"

  pr_list=$(gh pr list --repo "$REPO" --state open --head "$BRANCH" \
    --limit 1 --json number --jq '.[0] // empty') || return 1
  PR_NUM=$(printf '%s' "$pr_list" | jq -r '.number // empty')
  [ -n "$PR_NUM" ] || return 1

  # This is the sole fetch of the PR body. Keep body-bearing data in this one
  # response so the checks below prove one consistent PR state.
  PR_VIEW=$(gh pr view "$PR_NUM" --repo "$REPO" \
    --json url,headRefName,body,closingIssuesReferences) || return 1
  PR_URL=$(printf '%s' "$PR_VIEW" | jq -r '.url // empty')
  PR_HEAD=$(printf '%s' "$PR_VIEW" | jq -r '.headRefName // empty')
  [ -n "$PR_URL" ] && [ "$PR_HEAD" = "$BRANCH" ] || return 1
  printf '%s' "$PR_VIEW" | jq -e --argjson issue "$ISSUE_NUMBER" --arg repo "$REPO" \
    'any(.closingIssuesReferences[]?; .number == $issue and .repository.nameWithOwner == $repo)' \
    >/dev/null || return 1

  PR_BODY=$(printf '%s' "$PR_VIEW" | jq -r '.body // ""')
  pr_body_contains_literal "$PR_BODY" "$SUPERVISOR_DISCLOSURE" || return 1
  if [ -n "${STALE_SUPERVISOR_DISCLOSURE:-}" ]; then
    pr_body_contains_literal "$PR_BODY" "$STALE_SUPERVISOR_DISCLOSURE" || return 1
  fi
}
