#!/usr/bin/env bash
# Patch-id verdict carry (pylot#3738 fastlane). Real git repositories, no network:
#   - a rebase or clean merge-from-base keeps the patch-id → verdict carries, no re-run;
#   - a rework commit changes it → one re-review, scoped to the delta files;
#   - a merge-conflict resolution that changes the PR's diff → re-review, never a carry.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../shared/exact-head-receipt.sh
source "$ROOT/shared/exact-head-receipt.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: expected [%s], got [%s]\n' "$3" "$1" "$2" >&2; fail=1; fi
}
assert_ne() {
  if [ "$1" != "$2" ]; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: both [%s]\n' "$3" "$1" >&2; fail=1; fi
}

R="$TMP/repo"
git init -q -b main "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
pid_of() { git -C "$R" diff "main...$1" | dc_patch_id_of_diff; }
for f in a b c d e; do printf '%s\n' 1 2 3 4 5 6 7 8 9 > "$R/$f.txt"; done
g add -A; g commit -qm base

# PR touches four files.
g checkout -qb pr
for f in a b c d; do sed -i.bak "2s/.*/pr-$f/" "$R/$f.txt"; done; rm -f "$R"/*.bak
g commit -qam pr
H1=$(g rev-parse HEAD); P1=$(pid_of "$H1")

# Base moves on an unrelated file.
g checkout -q main
sed -i.bak '8s/.*/base-e/' "$R/e.txt"; rm -f "$R"/*.bak
g commit -qam base2

# 1. Rebase onto the new base: new head, same PR diff.
g checkout -qb rebased "$H1"
g rebase -q main
H_REBASE=$(g rev-parse HEAD); P_REBASE=$(pid_of "$H_REBASE")
assert_ne "$H1" "$H_REBASE" rebase-changes-head
assert_eq "$P1" "$P_REBASE" rebase-keeps-patch-id
assert_eq carry "$(dc_exact_head_decision "$H1" "$H_REBASE" 0 "$P1" "$P_REBASE")" rebase-carries-no-rerun
assert_eq carry "$(dc_exact_head_decision "$H1" "$H_REBASE" 1 "$P1" "$P_REBASE")" carry-needs-no-restart-budget

# 2. Merge-from-base (what stage 01 does): new head, same PR diff.
g checkout -qb merged "$H1"
g merge -q --no-edit main
H_MERGE=$(g rev-parse HEAD); P_MERGE=$(pid_of "$H_MERGE")
assert_eq "$P1" "$P_MERGE" merge-from-base-keeps-patch-id
assert_eq carry "$(dc_exact_head_decision "$H1" "$H_MERGE" 0 "$P1" "$P_MERGE")" merge-from-base-carries
assert_eq "" "$(dc_delta_files "$R" main "$H1" "$H_MERGE")" merge-from-base-has-empty-delta

# 3. Rework commit on one file: the diff changed → one re-review, delta only.
sed -i.bak '3s/.*/rework-a/' "$R/a.txt"; rm -f "$R"/*.bak
g commit -qam rework
H_REWORK=$(g rev-parse HEAD); P_REWORK=$(pid_of "$H_REWORK")
assert_ne "$P1" "$P_REWORK" rework-changes-patch-id
assert_eq restart "$(dc_exact_head_decision "$H1" "$H_REWORK" 0 "$P1" "$P_REWORK")" rework-reruns
DELTA=$(dc_delta_files "$R" main "$H1" "$H_REWORK")
assert_eq a.txt "$DELTA" rework-delta-is-only-the-touched-file
TOTAL=$(git -C "$R" diff --name-only "main...$H_REWORK" | wc -l | tr -d ' ')
assert_eq delta "$(dc_review_scope "$(printf '%s\n' "$DELTA" | grep -c .)" "$TOTAL")" rework-reviews-delta-only
# A delta touching more than 30% of the PR's files reviews in full.
sed -i.bak '3s/.*/rework-b/' "$R/b.txt"; rm -f "$R"/*.bak
g commit -qam rework2
WIDE=$(dc_delta_files "$R" main "$H1" "$(g rev-parse HEAD)" | grep -c .)
assert_eq 2 "$WIDE" wide-rework-delta-counts-two-files
assert_eq full "$(dc_review_scope "$WIDE" 4)" wide-rework-reviews-in-full
assert_eq full "$(dc_review_scope 0 0)" unknown-total-reviews-in-full
# An unavailable prior head (force-pushed away) fails closed to a full review.
if dc_delta_files "$R" main 0123456789012345678901234567890123456789 "$H_REWORK" >/dev/null; then
  printf 'FAIL missing-prior-head-must-fail\n' >&2; fail=1
else printf 'PASS missing-prior-head-fails-to-full\n'; fi

# 4. Merge conflict whose resolution changes the PR's own diff → re-review, never carry.
g checkout -q main
sed -i.bak '2s/.*/base-a/' "$R/a.txt"; rm -f "$R"/*.bak
g commit -qam base3
g checkout -qb conflicted "$H1"
if g merge -q --no-edit main >/dev/null 2>&1; then printf 'FAIL expected-conflict\n' >&2; fail=1; fi
printf '%s\n' 1 resolved-a 3 4 5 6 7 8 9 > "$R/a.txt"
g add a.txt; g commit -qm 'resolve conflict' --no-edit
H_CONFLICT=$(g rev-parse HEAD); P_CONFLICT=$(pid_of "$H_CONFLICT")
assert_ne "$P1" "$P_CONFLICT" conflict-resolution-changes-patch-id
assert_eq restart "$(dc_exact_head_decision "$H1" "$H_CONFLICT" 0 "$P1" "$P_CONFLICT")" conflict-resolution-rereviews
assert_eq blocked "$(dc_exact_head_decision "$H1" "$H_CONFLICT" 1 "$P1" "$P_CONFLICT")" conflict-after-restart-blocks

# 5. Indentation-only rework (a Python block move) changes the patch-id: it is reviewed, not carried.
g checkout -qb indent "$H1"
sed -i.bak '2s/.*/    pr-c/' "$R/c.txt"; rm -f "$R"/*.bak
g commit -qam indent
H_INDENT=$(g rev-parse HEAD); P_INDENT=$(pid_of "$H_INDENT")
assert_ne "$P1" "$P_INDENT" indentation-only-change-changes-patch-id
assert_eq restart "$(dc_exact_head_decision "$H1" "$H_INDENT" 0 "$P1" "$P_INDENT")" indentation-only-change-rereviews
assert_eq c.txt "$(dc_delta_files "$R" main "$H1" "$H_INDENT")" indentation-only-change-is-in-delta

# Missing or malformed patch-ids never carry: the plain exact-head gate applies.
assert_eq restart "$(dc_exact_head_decision "$H1" "$H_REBASE" 0 "" "")" no-patch-id-no-carry
assert_eq restart "$(dc_exact_head_decision "$H1" "$H_REBASE" 0 "-" "-")" dash-patch-id-no-carry
assert_eq "" "$(printf '' | dc_patch_id_of_diff)" empty-diff-has-no-patch-id

# gh pr diff and local three-dot diff agree, so a live receipt matches a locally computed one.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "pr diff"*) cat "$DC_FAKE_DIFF" ;;
  *headRefOid*)
    n=$(cat "$DC_FAKE_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$DC_FAKE_COUNT"
    if [ -n "${DC_FAKE_HEAD2:-}" ] && [ "$n" -ge 1 ]; then echo "$DC_FAKE_HEAD2"; else echo "$DC_FAKE_HEAD"; fi ;;
  *"--json comments"*) cat "$DC_FAKE_COMMENTS" ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" DC_FAKE_DIFF="$TMP/pr.diff" DC_FAKE_COUNT="$TMP/count" DC_FAKE_COMMENTS="$TMP/comments.txt"
git -C "$R" diff "main...$H_REBASE" > "$DC_FAKE_DIFF"
export DC_FAKE_HEAD="$H_REBASE"
assert_eq "$H_REBASE $P1" "$(dc_live_patch_receipt 1 o/r)" live-receipt-from-gh
rm -f "$DC_FAKE_COUNT"
assert_eq "" "$(DC_FAKE_HEAD2="$H_REWORK" dc_live_patch_receipt 1 o/r)" head-moving-during-read-gives-no-receipt

# Verdict receipts: the newest marker wins; legacy markers carry the head only.
comments() {  # login body [login body ...] -> gh pr view --json comments document
  node -e 'const a=process.argv.slice(1),c=[];for(let i=0;i<a.length;i+=2)c.push({author:{login:a[i]},body:a[i+1]});console.log(JSON.stringify({comments:c}))' "$@" > "$DC_FAKE_COMMENTS"
}
comments pylot-app "<!-- pylot:exact-head-promoted pr=1 head=$H1 -->
## Double-Check Review" \
  pylot-app "<!-- pylot:exact-head-promoted pr=1 head=$H1 patch_id=$P1 verdict=ready -->
verdict carried: patch-id unchanged"
assert_eq "$H1 $P1 ready" "$(dc_latest_verdict_receipt 1 o/r)" latest-receipt-parsed
comments pylot-app "<!-- pylot:exact-head-promoted pr=1 head=$H1 -->"
assert_eq "$H1 - -" "$(dc_latest_verdict_receipt 1 o/r)" legacy-receipt-head-only
# A marker typed by anyone else (PR author, rework agent) is ignored: it cannot carry a rework.
comments pylot-app "<!-- pylot:exact-head-promoted pr=1 head=$H1 patch_id=$P1 verdict=needs-work -->" \
  someone "<!-- pylot:exact-head-promoted pr=1 head=$H_REWORK patch_id=$P_REWORK verdict=ready -->"
assert_eq "$H1 $P1 needs-work" "$(dc_latest_verdict_receipt 1 o/r)" forged-receipt-from-other-author-ignored
comments
assert_eq "" "$(dc_latest_verdict_receipt 1 o/r)" no-receipt

# The procedure wires the helpers in: a test of the helper alone would not stop a doc regression.
need() {
  if grep -qF -- "$2" "$ROOT/$1"; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: %s lacks %s\n' "$3" "$1" "$2" >&2; fail=1; fi
}
need stages/01-setup/CONTEXT.md 'dc_latest_verdict_receipt' setup-reads-last-verdict
need stages/01-setup/CONTEXT.md 'dc_delta_files' setup-computes-delta
need stages/01-setup/CONTEXT.md 'review_scope: {full | delta | carry}' setup-records-scope
need stages/02-review/CONTEXT.md 'review_scope: delta' review-has-delta-mode
need stages/04-post/CONTEXT.md 'patch_id=${LIVE_PATCH_ID:--} verdict=$VERDICT' receipt-records-patch-id
need stages/04-post/CONTEXT.md 'if [ "$DECISION" = carry ]; then' post-carries-on-same-patch-id
need stages/04-post/CONTEXT.md 'verdict carried: patch-id unchanged' carry-posts-one-line-note
need SKILL.md 'review_scope: carry' orchestrator-skips-review-on-carry

exit "$fail"
