#!/bin/sh
# Fail-closed PR postconditions: the PR's head is the pushed branch, and the PR
# closes exactly the issue this run implemented. These are the only two
# postconditions (#149 retired the supervisor-disclosure byte containment).

verify_pr_postcondition() {
  : "${REPO:?REPO required}"
  : "${BRANCH:?BRANCH required}"
  : "${ISSUE_NUMBER:?ISSUE_NUMBER required}"

  pr_list=$(gh pr list --repo "$REPO" --state open --head "$BRANCH" \
    --limit 1 --json number --jq '.[0] // empty') || return 1
  PR_NUM=$(printf '%s' "$pr_list" | jq -r '.number // empty')
  [ -n "$PR_NUM" ] || return 1

  # Single fetch of PR state so both checks prove one consistent PR.
  PR_VIEW=$(gh pr view "$PR_NUM" --repo "$REPO" \
    --json url,headRefName,closingIssuesReferences) || return 1
  PR_URL=$(printf '%s' "$PR_VIEW" | jq -r '.url // empty')
  PR_HEAD=$(printf '%s' "$PR_VIEW" | jq -r '.headRefName // empty')
  [ -n "$PR_URL" ] && [ "$PR_HEAD" = "$BRANCH" ] || return 1
  printf '%s' "$PR_VIEW" | jq -e --argjson issue "$ISSUE_NUMBER" --arg repo "$REPO" \
    'any(.closingIssuesReferences[]?; .number == $issue and .repository.nameWithOwner == $repo)' \
    >/dev/null || return 1
}
