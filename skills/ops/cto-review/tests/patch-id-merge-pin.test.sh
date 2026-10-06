#!/usr/bin/env bash
# cto-review merge pin (pylot#3738): a review carries across a head change with the same patch-id
# (rebase, merge-from-base) and the merge stays pinned to the exact live head; any change to the
# PR's own diff (rework, conflict resolution) holds. Runs the pin function from stage 03 itself.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DC_SHARED=$(cd "$ROOT/../double-check/shared" && pwd)
S01="$ROOT/stages/01-setup/CONTEXT.md"
S02="$ROOT/stages/02-review/CONTEXT.md"
S03="$ROOT/stages/03-synthesize-act/CONTEXT.md"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: expected [%s], got [%s]\n' "$3" "$1" "$2" >&2; fail=1; fi
}

# Real PR history: reviewed head, a rebase of it, a rework commit, and a conflict resolution.
R="$TMP/repo"
git init -q -b main "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
printf '%s\n' 1 2 3 4 5 > "$R/a.txt"; printf '%s\n' 1 2 3 > "$R/b.txt"
g add -A; g commit -qm base
g checkout -qb pr; sed -i.bak '2s/.*/pr/' "$R/a.txt"; rm -f "$R"/*.bak; g commit -qam pr
H1=$(g rev-parse HEAD)
g checkout -q main; sed -i.bak '3s/.*/base/' "$R/b.txt"; rm -f "$R"/*.bak; g commit -qam base2
g checkout -qb rebased "$H1"; g rebase -q main; H_REBASE=$(g rev-parse HEAD)
sed -i.bak '4s/.*/rework/' "$R/a.txt"; rm -f "$R"/*.bak; g commit -qam rework; H_REWORK=$(g rev-parse HEAD)
g checkout -q main; sed -i.bak '2s/.*/base-a/' "$R/a.txt"; rm -f "$R"/*.bak; g commit -qam base3
g checkout -qb conflicted "$H1"; g merge -q --no-edit main >/dev/null 2>&1 || true
printf '%s\n' 1 resolved 3 4 5 > "$R/a.txt"; g add a.txt; g commit -qm resolve --no-edit
H_CONFLICT=$(g rev-parse HEAD)
diff_of() { git -C "$R" diff "main...$1"; }
for h in "$H1" "$H_REBASE" "$H_REWORK" "$H_CONFLICT"; do diff_of "$h" > "$TMP/$h.diff"; done
P1=$(git patch-id --verbatim < "$TMP/$H1.diff" | awk '{print $1}')

# Fake gh: the live head is $LIVE; `gh pr diff` serves that head's three-dot diff.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "pr diff"*) cat "$FAKE_DIR/$LIVE.diff" ;;
  *headRefOid*) echo "$LIVE" ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_DIR="$TMP"

# The stage-03 pin block, verbatim from the procedure.
PIN_BLOCK=$(awk '/^SETUP_HANDOFF=\.procedure-output\/cto-review/{on=1} /^CURRENT_MERGE_HEAD_SHA=\$\(cto_merge_pin\)/{on=0} on' "$S03")
[ -n "$PIN_BLOCK" ] || { echo 'FAIL pin-block-missing-from-stage-03' >&2; exit 1; }

pin_at() {  # live head, helper available (yes|no) → pinned head or empty
  local live=$1 helper=$2 work
  work=$(mktemp -d "$TMP/w.XXXX")
  mkdir -p "$work/.procedure-output/cto-review/01-setup"
  printf -- '- Current HEAD SHA: %s\n- Current patch-id: %s\n' "$H1" "$P1" \
    > "$work/.procedure-output/cto-review/01-setup/handoff.md"
  if [ "$helper" = yes ]; then mkdir -p "$work/skills/ops/double-check"; ln -s "$DC_SHARED" "$work/skills/ops/double-check/shared"; fi
  (cd "$work" && export HOME="$work" LIVE="$live" PR=1 REPO=o/r && eval "$PIN_BLOCK" >/dev/null 2>&1 && cto_merge_pin 2>/dev/null)
}

assert_eq "$H1" "$(pin_at "$H1" yes)" same-head-merges-pinned-to-it
assert_eq "$H_REBASE" "$(pin_at "$H_REBASE" yes)" rebase-same-patch-id-carries-pinned-to-new-head
assert_eq "" "$(pin_at "$H_REWORK" yes)" rework-changed-diff-holds
assert_eq "" "$(pin_at "$H_CONFLICT" yes)" conflict-resolution-changed-diff-holds
# Without the double-check helper the gate degrades to the exact head, never to "merge anyway".
assert_eq "$H1" "$(pin_at "$H1" no)" no-helper-exact-head-merges
assert_eq "" "$(pin_at "$H_REBASE" no)" no-helper-moved-head-holds

need() {
  if grep -qF -- "$2" "$1"; then printf 'PASS %s\n' "$3"; else printf 'FAIL %s: missing %s\n' "$3" "$2" >&2; fail=1; fi
}
need "$S03" 'gh pr merge $PR --repo $REPO --merge --match-head-commit "$CURRENT_MERGE_HEAD_SHA"' merge-pinned-to-exact-head
need "$S03" 'CURRENT_MERGE_HEAD_SHA=$(cto_merge_pin)' conflict-rebase-re-pins
need "$S01" '- Current patch-id: {CURRENT_PATCH_ID' setup-records-patch-id
need "$S02" 'carries the same patch-id as `Current patch-id` is **current**' double-check-receipt-carried-by-patch-id

exit "$fail"
