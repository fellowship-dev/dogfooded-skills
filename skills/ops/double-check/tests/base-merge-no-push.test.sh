#!/usr/bin/env bash
# Stage 01 checks the base merge locally and never pushes it (Max, 2026-10-06, pylot#3738).
# Every head change restarts a PR's double-check, and GitHub does not require a branch to be up
# to date to merge, so a behind-but-clean PR must keep its head. Runs stage 01's own checkout +
# base-merge block (extracted from CONTEXT.md) against throwaway git repos.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
S01="$ROOT/stages/01-setup/CONTEXT.md"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0

pass() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=1; }

# Stage 01's block, from the checkout heading to the live-head read, with REPO_DIR redirected.
BLOCK="$WORK/block.sh"
awk '/^### Checkout PR branch/{on=1; next} /^CURRENT_HEAD_SHA=/{on=0} on && !/^```/' "$S01" \
  | sed 's|^REPO_DIR=.*|REPO_DIR="$TEST_REPO_DIR"|' > "$BLOCK"
[ -s "$BLOCK" ] || { bad extract "no checkout block in stage 01"; exit 1; }

git_() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=develop -c advice.detachedHead=false "$@"; }

# setup <scenario> <base change: none|other-file|same-line>
setup() {
  local d="$WORK/$1"
  mkdir -p "$d"
  git_ init -q --bare "$d/origin.git"
  git_ clone -q "$d/origin.git" "$d/seed" 2>/dev/null
  (cd "$d/seed" && printf 'line\n' > shared.txt && git_ add . && git_ commit -qm base \
    && git_ push -q origin HEAD:develop \
    && git_ checkout -qb feature && printf 'feature\n' > shared.txt && git_ commit -qam feature \
    && git_ push -q origin feature \
    && git_ checkout -q develop \
    && case "$2" in
         other-file) printf 'x\n' > other.txt && git_ add other.txt && git_ commit -qm ahead && git_ push -q origin develop ;;
         same-line) printf 'develop\n' > shared.txt && git_ commit -qam clash && git_ push -q origin develop ;;
       esac)
  git_ clone -q "$d/origin.git" "$d/repo" 2>/dev/null
}

# run <scenario>: prints MERGE_FAILED and the PR head before/after on the remote.
run() {
  local d="$WORK/$1" before after out
  before=$(git --git-dir="$d/origin.git" rev-parse feature)
  out=$(cd "$WORK" && TEST_REPO_DIR="$d/repo" REPO=org/x PR_BRANCH=feature BASE_BRANCH=develop \
    OUT="$d" DIFF_FALLBACK= MERGE_FAILED= \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    bash -c 'set +e; source "$1" >/dev/null 2>&1; printf "%s|%s|%s" "${MERGE_FAILED:-}" \
      "$(git -C "$TEST_REPO_DIR" rev-parse HEAD)" "$(git -C "$TEST_REPO_DIR" status --porcelain | wc -l | tr -d " ")"' _ "$BLOCK")
  after=$(git --git-dir="$d/origin.git" rev-parse feature)
  printf '%s|%s|%s\n' "$out" "$before" "$after"
}

check() { # scenario base-change expected-merge-failed
  setup "$1" "$2"
  IFS='|' read -r failed local_head dirty before after <<< "$(run "$1")"
  [ "$before" = "$after" ] && pass "$1: remote PR head unchanged (no push)" || bad "$1" "PR branch pushed: $before -> $after"
  [ "$local_head" = "$before" ] && pass "$1: local checkout left on the PR head" || bad "$1" "local HEAD moved to $local_head"
  [ "$dirty" = 0 ] && pass "$1: working tree clean" || bad "$1" "$dirty dirty paths left"
  [ "$failed" = "$3" ] && pass "$1: MERGE_FAILED=${3:-<empty>}" || bad "$1" "MERGE_FAILED=$failed, want ${3:-<empty>}"
}

check behind-but-clean other-file ''   # the case that used to push a merge commit
check up-to-date none ''
check dirty same-line true             # a real conflict blocks; auto-pylot stage 03 fixes it

if grep -nE '^[[:space:]]*git push' "$S01" >/dev/null; then
  bad stage01-never-pushes "$(grep -nE '^[[:space:]]*git push' "$S01")"
else
  pass stage01-never-pushes
fi

exit "$fail"
