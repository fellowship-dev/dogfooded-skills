#!/usr/bin/env bash
# Immutable exact-head gate for the double-check post stage, plus the patch-id receipt that lets a
# verdict survive a head change which leaves the PR's own diff untouched (pylot#3738 fastlane).
# Source this file; apart from the read-only `gh` calls below it performs no GitHub mutation.

dc_is_full_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# Prints one of: promote, carry, restart, blocked.  The caller owns all side effects.
#   promote — the live head is the exact reviewed head.
#   carry   — the head moved, but the PR's own diff did not: both patch-ids are present and equal
#             (a rebase or merge-from-base). The verdict carries to the live head; no review runs.
#   restart — the PR's own diff changed (rework, fix push, conflict resolution); one re-review,
#             scoped to the delta by stage 01.
#   blocked — second move, or anything unreadable/malformed. Fails closed.
# Patch-ids are optional (args 4 and 5); without them this is the plain exact-head gate.
dc_exact_head_decision() {
  local reviewed_head_sha=$1 live_head_sha=$2 restart_count=$3
  local reviewed_patch_id=${4:-} live_patch_id=${5:-}

  if ! dc_is_full_sha "$reviewed_head_sha" || ! dc_is_full_sha "$live_head_sha"; then
    printf '%s\n' blocked
  elif [ "$reviewed_head_sha" = "$live_head_sha" ]; then
    printf '%s\n' promote
  elif dc_is_full_sha "$reviewed_patch_id" && [ "$reviewed_patch_id" = "$live_patch_id" ]; then
    printf '%s\n' carry
  elif [ "$restart_count" = 0 ]; then
    printf '%s\n' restart
  else
    printf '%s\n' blocked
  fi
}

# Read the authoritative PR head immediately before a promotion mutation. The
# caller must stop unless this prints `promote`; a cached JSON document must
# never authorize a comment or label that advances the review pipeline.
dc_live_promotion_decision() {
  local pr=$1 repo=$2 reviewed_head_sha=$3 restart_count=$4 output_file=$5

  if ! gh pr view "$pr" --repo "$repo" --json headRefOid >"$output_file"; then
    printf '%s\n' blocked
    return 0
  fi

  local live_head_sha
  live_head_sha=$(jq -r '.headRefOid // empty' "$output_file" 2>/dev/null || true)
  dc_exact_head_decision "$reviewed_head_sha" "$live_head_sha" "$restart_count"
}

# ---- Patch-id receipts -------------------------------------------------------------------------
# A PR's patch-id is `git diff <base>...<head> | git patch-id --verbatim`: the PR's own diff from its
# merge-base, with line numbers ignored. `--verbatim`, not `--stable`: `--stable` ignores
# whitespace, so an indentation-only rework (a Python block move) would carry unreviewed. Needs git
# 2.39+; an older git prints nothing, which never carries. `gh pr diff` is the same three-dot diff,
# so both sources give the same id. A rebase or clean merge-from-base keeps it; any change to the
# PR's own diff, including a conflict resolution that alters a hunk, changes it. `gh pr diff`
# refuses very large PRs (HTTP 406): those never carry and are reviewed as before.

# stdin: a unified diff. Prints its 40-hex patch-id, or nothing (empty or unreadable diff).
dc_patch_id_of_diff() {
  local pid
  pid=$(git patch-id --verbatim 2>/dev/null | awk 'NR==1{print $1}')
  if dc_is_full_sha "$pid"; then printf '%s\n' "$pid"; fi
  return 0
}

# Live "<head> <patch-id>" of a PR, read from GitHub. Prints nothing when either read fails or the
# head moved during the read, so callers fall back to the exact-head gate.
dc_live_patch_receipt() {
  local pr=$1 repo=$2 head_before head_after pid
  head_before=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null) || return 0
  pid=$(gh pr diff "$pr" --repo "$repo" 2>/dev/null | dc_patch_id_of_diff)
  head_after=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null) || return 0
  if dc_is_full_sha "$head_before" && [ "$head_before" = "$head_after" ] && dc_is_full_sha "$pid"; then
    printf '%s %s\n' "$head_before" "$pid"
  fi
  return 0
}

# Latest double-check verdict receipt on the PR, from its `pylot:exact-head-promoted` marker:
# prints "<head> <patch-id|-> <verdict|->". Legacy markers carry only the head. Prints nothing when
# no receipt exists or the comments cannot be read. Only markers posted by the pipeline's own
# account count (DC_RECEIPT_AUTHORS, space-separated logins, default `pylot-app`): anyone can type a
# marker into a comment, and a forged `verdict=ready` would carry an unreviewed diff.
dc_latest_verdict_receipt() {
  local pr=$1 repo=$2
  gh pr view "$pr" --repo "$repo" --json comments 2>/dev/null \
    | jq -r --arg authors "${DC_RECEIPT_AUTHORS:-pylot-app}" \
        '.comments[] | select(.author.login as $a | ($authors | split(" ") | index($a))) | .body' \
        2>/dev/null \
    | grep -F 'pylot:exact-head-promoted' \
    | awk '{
        head = "-"; pid = "-"; verdict = "-"
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^head=[0-9a-f]+$/)     head = substr($i, 6)
          if ($i ~ /^patch_id=[0-9a-f]+$/) pid = substr($i, 10)
          if ($i ~ /^verdict=[a-z-]+$/)    verdict = substr($i, 9)
        }
        if (length(head) == 40) last = head " " pid " " verdict
      } END { if (last != "") print last }'
  return 0
}

# Files whose PR-level hunks differ between two heads (the delta since the last verdict), one per
# line. Each side is compared against its own merge-base with <base>, so a merge-from-base in
# between contributes nothing. Returns 1 when either head is not in the checkout: the caller then
# reviews the full diff.
dc_delta_files() {
  local dir=$1 base=$2 old=$3 new=$4 f a b
  git -C "$dir" cat-file -e "$old^{commit}" 2>/dev/null || return 1
  git -C "$dir" cat-file -e "$new^{commit}" 2>/dev/null || return 1
  { git -C "$dir" diff --name-only "$base...$old"; git -C "$dir" diff --name-only "$base...$new"; } \
    2>/dev/null | sort -u | while IFS= read -r f; do
      a=$(git -C "$dir" diff "$base...$old" -- "$f" | dc_patch_id_of_diff)
      b=$(git -C "$dir" diff "$base...$new" -- "$f" | dc_patch_id_of_diff)
      [ "$a" = "$b" ] || printf '%s\n' "$f"
    done
}

# Review scope for a changed diff: `delta` when the delta touches at most 30% of the PR's files,
# else `full`. Unknown or zero totals review in full.
dc_review_scope() {
  local delta_count=$1 total_count=$2
  if ! [ "$delta_count" -ge 0 ] 2>/dev/null || ! [ "$total_count" -gt 0 ] 2>/dev/null; then
    printf '%s\n' full
  elif [ $((delta_count * 100)) -le $((total_count * 30)) ]; then
    printf '%s\n' delta
  else
    printf '%s\n' full
  fi
}
