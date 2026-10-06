#!/usr/bin/env bash
# file-finding.sh — the one way automations file a GitHub finding.
#
#   file-finding.sh --repo <org/repo> --title <title> --search "<root-cause terms>" \
#     (--body <text> | --body-file <path|->) [--severity P0|P1|P2|P3] [--incident] \
#     [--blocking] [--label <name>]... [--dry-run]
#
# Rule (owner, 2026-10-06 — cut issue inflow):
#   1. An OPEN issue already matching --search (title/body, digest excluded) gets a
#      comment with this finding. Nothing new is filed.
#   2. A finding that is not P0/P1, not an incident and not blocking a PR/release goes
#      to the repo's one rolling weekly digest issue (label `digest`) as a comment.
#   3. At most FINDING_CAP (3) new issues per filer run (FINDING_CYCLE). P0 and
#      --incident are exempt; over-cap findings go to the digest.
# Prints exactly one line: `commented <N>` | `digest <N> <reason>` | `created <N>`
# (with --dry-run: the same verb prefixed by `would-`, and nothing is written).
set -euo pipefail

die() { echo "file-finding: $*" >&2; exit 2; }

REPO="" TITLE="" SEARCH="" BODY="" BODY_SET=0 SEVERITY="" INCIDENT=0 BLOCKING=0 DRY=0
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --search) SEARCH="${2:-}"; shift 2 ;;
    --body) BODY="${2:-}"; BODY_SET=1; shift 2 ;;
    --body-file)
      if [ "${2:-}" = "-" ]; then BODY=$(cat); else [ -r "${2:-}" ] || die "cannot read ${2:-}"; BODY=$(cat "$2"); fi
      BODY_SET=1; shift 2 ;;
    --severity) SEVERITY="${2:-}"; shift 2 ;;
    --incident) INCIDENT=1; shift ;;
    --blocking) BLOCKING=1; shift ;;
    --label) LABELS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] && [ -n "$TITLE" ] && [ -n "$SEARCH" ] && [ "$BODY_SET" = 1 ] \
  || die "--repo, --title, --search and --body/--body-file are required"
case "$SEVERITY" in ''|P0|P1|P2|P3) ;; *) die "--severity must be P0|P1|P2|P3" ;; esac

CAP="${FINDING_CAP:-3}"
CYCLE="${FINDING_CYCLE:-${PYLOT_JOB_ID:-$(date -u +%Y%m%dT%H)}}"
STATE_DIR="${FINDING_STATE_DIR:-${TMPDIR:-/tmp}/file-finding}"
COUNT_FILE="$STATE_DIR/$(printf '%s' "$CYCLE" | tr -c 'A-Za-z0-9._-' '_').count"
p() { if [ "$DRY" = 1 ]; then echo "would-$*"; else echo "$*"; fi; }

# 1. Same root cause already open → comment there.
EXISTING=$(gh issue list --repo "$REPO" --state open --limit 1 \
  --search "$SEARCH in:title,body -label:digest" --json number --jq '.[0].number // empty')
if [ -n "$EXISTING" ]; then
  [ "$DRY" = 1 ] || gh issue comment "$EXISTING" --repo "$REPO" \
    --body "$(printf '**Recurrence — %s**\n\n%s' "$TITLE" "$BODY")" >/dev/null
  p "commented $EXISTING"; exit 0
fi

digest() { # reason
  local week dtitle num
  week=$(date -u +%G-W%V)
  dtitle="Weekly findings digest — $week"
  num=$(gh issue list --repo "$REPO" --state open --label digest --limit 20 \
    --json number,title --jq ".[] | select(.title == \"$dtitle\") | .number" | head -1)
  if [ "$DRY" = 1 ]; then p "digest ${num:-new} $1"; return; fi
  if [ -z "$num" ]; then
    gh label create digest --repo "$REPO" --color c5def5 \
      --description "Rolling weekly findings digest" >/dev/null 2>&1 || true
    gh label create no-automation --repo "$REPO" --color ededed >/dev/null 2>&1 || true
    num=$(gh issue create --repo "$REPO" --title "$dtitle" --label digest,no-automation \
      --body "Non-blocking automation findings for $week, one comment each. Promote a finding to its own issue only when it becomes P0/P1 or blocks a PR/release." \
      | sed -E 's#.*/issues/([0-9]+).*#\1#')
    # One open digest per repo: retire earlier weeks.
    for old in $(gh issue list --repo "$REPO" --state open --label digest --limit 20 \
        --json number,title --jq ".[] | select(.title != \"$dtitle\") | .number"); do
      gh issue close "$old" --repo "$REPO" --comment "Superseded by #$num." >/dev/null || true
    done
  fi
  # Same finding already in this week's digest → nothing to add.
  if gh issue view "$num" --repo "$REPO" --json comments --jq '.comments[].body' | grep -Fqx "### $TITLE"; then
    p "digest $num duplicate"; return
  fi
  gh issue comment "$num" --repo "$REPO" --body "$(printf '### %s\n\n_severity: %s · routed: %s · cycle: %s_\n\n%s' \
    "$TITLE" "${SEVERITY:-none}" "$1" "$CYCLE" "$BODY")" >/dev/null
  p "digest $num $1"
}

# 2. Non-blocking → digest.
if [ "$SEVERITY" != P0 ] && [ "$SEVERITY" != P1 ] && [ "$INCIDENT" = 0 ] && [ "$BLOCKING" = 0 ]; then
  digest non-blocking; exit 0
fi

# 3. Per-cycle cap; P0 and incidents exempt.
EXEMPT=0; { [ "$SEVERITY" = P0 ] || [ "$INCIDENT" = 1 ]; } && EXEMPT=1
mkdir -p "$STATE_DIR"
FILED=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
if [ "$EXEMPT" = 0 ] && [ "$FILED" -ge "$CAP" ]; then
  digest over-cap; exit 0
fi
if [ "$DRY" = 1 ]; then p "created new"; exit 0; fi
ARGS=(--repo "$REPO" --title "$TITLE" --body "$BODY")
for l in ${LABELS[@]+"${LABELS[@]}"}; do ARGS+=(--label "$l"); done
URL=$(gh issue create "${ARGS[@]}")
[ "$EXEMPT" = 1 ] || echo $((FILED + 1)) > "$COUNT_FILE"
p "created ${URL##*/}"
