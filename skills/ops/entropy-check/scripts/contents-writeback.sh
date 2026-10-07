#!/usr/bin/env bash
# Commit entropy-check's QUALITY_SCORE.md write-back straight to the integration branch through
# the GitHub Contents API (no branch, no PR, [skip ci]). Owner decision 2026-10-07; git push is not
# used because worker containers' git-push-guard.sh denies pushes to main/master/develop.
#
#   contents-writeback.sh fetch <owner/repo> <branch> <out-file>
#       Writes <branch>'s current QUALITY_SCORE.md to <out-file> and prints its blob sha
#       (empty sha and empty file when the file does not exist yet).
#   contents-writeback.sh put <owner/repo> <branch> <path> <file> <sha> <message>
#       Commits <file> as <path> on <branch>. <sha> is the blob sha from `fetch` (optimistic
#       concurrency). Prints the commit sha.
#
# Exit codes: 0 committed / fetched; 1 API or tool failure; 2 refused (only QUALITY_SCORE.md,
# message must contain [skip ci], branch required); 3 stale sha (HTTP 409/422) — re-fetch,
# re-apply the write-back to the fresh content, and put again.
set -uo pipefail

ONLY_PATH="QUALITY_SCORE.md"
die() { printf 'contents-writeback: %s\n' "$2" >&2; exit "$1"; }

cmd=${1:-}; shift || true
case "$cmd" in
  fetch)
    [ $# -eq 3 ] || die 2 "usage: fetch <owner/repo> <branch> <out-file>"
    repo=$1 branch=$2 out=$3
    [ -n "$repo" ] && [ -n "$branch" ] || die 2 "repo and branch are required"
    resp=$(gh api "repos/$repo/contents/$ONLY_PATH?ref=$branch" 2>&1)
    if [ $? -ne 0 ]; then
      if grep -q 'HTTP 404' <<< "$resp"; then : > "$out"; exit 0; fi
      die 1 "fetch $repo@$branch:$ONLY_PATH failed: $resp"
    fi
    jq -j '.content | gsub("\\s"; "") | @base64d' <<< "$resp" > "$out" || die 1 "could not decode content"
    jq -r '.sha' <<< "$resp"
    ;;
  put)
    [ $# -eq 6 ] || die 2 "usage: put <owner/repo> <branch> <path> <file> <sha> <message>"
    repo=$1 branch=$2 path=$3 file=$4 sha=$5 msg=$6
    [ "$path" = "$ONLY_PATH" ] || die 2 "refusing to write '$path': only $ONLY_PATH may be committed this way"
    [ -n "$repo" ] && [ -n "$branch" ] || die 2 "repo and branch are required"
    case "$msg" in *"[skip ci]"*) ;; *) die 2 "commit message must contain [skip ci]" ;; esac
    [ -f "$file" ] || die 2 "no such file: $file"
    payload=$(mktemp); trap 'rm -f "$payload"' EXIT
    jq -n --arg message "$msg" --arg branch "$branch" --arg sha "$sha" \
      --rawfile raw "$file" \
      '{message: $message, branch: $branch, content: ($raw | @base64)} + (if $sha == "" then {} else {sha: $sha} end)' \
      > "$payload" || die 1 "could not build payload"
    resp=$(gh api -X PUT "repos/$repo/contents/$path" --input "$payload" 2>&1)
    if [ $? -ne 0 ]; then
      grep -qE 'HTTP (409|422)' <<< "$resp" && die 3 "stale sha for $repo@$branch:$path — re-fetch and re-apply: $resp"
      die 1 "commit to $repo@$branch:$path failed: $resp"
    fi
    jq -r '.commit.sha' <<< "$resp"
    ;;
  *) die 2 "usage: contents-writeback.sh fetch|put ..." ;;
esac
