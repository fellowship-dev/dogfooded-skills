#!/bin/sh
set -eu

MATRIX=${1:?usage: validate-review-output.sh MATRIX REVIEW_OUTPUT}
REVIEW=${2:?usage: validate-review-output.sh MATRIX REVIEW_OUTPUT}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/validate-invariant-matrix.sh" "$MATRIX"
REQUIRED=$(mktemp)
COVERED=$(mktemp)
trap 'rm -f "$REQUIRED" "$COVERED"' EXIT HUP INT TERM

awk -F '\t' 'NR > 1 && $8 == "applicable" { print $1 }' "$MATRIX" | sort >"$REQUIRED"
awk '
  completions && NF { invalid = 1 }
  /^ROW INV-[0-9][0-9][0-9] verdict=no-findings$/ { print $2; next }
  /^FINDING F-[0-9][0-9][0-9] row_id=(INV-[0-9][0-9][0-9]|OMITTED) priority=P[0-3] status=open evidence=.+ suggested_action=.+$/ {
    if (finding_ids[$2]++) invalid = 1
    findings++
    evidence = $0
    sub(/^.* evidence=/, "", evidence)
    sub(/ suggested_action=.*$/, "", evidence)
    action = $0
    sub(/^.* suggested_action=/, "", action)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", evidence)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", action)
    if (evidence == "" || tolower(evidence) ~ /^(-|none|n\/a)$/ ||
        action == "" || tolower(action) ~ /^(-|none|n\/a)$/) invalid = 1
    split($3, field, "="); if (field[2] != "OMITTED") print field[2]; next
  }
  /^\[pylot\] phase=independent-review status=done actionable=(yes|no)$/ {
    completions++
    actionable = $0 ~ /actionable=yes$/
    next
  }
  /^(ROW|FINDING) / { invalid = 1 }
  /^\[pylot\] phase=independent-review/ { invalid = 1 }
  END { exit (invalid || completions != 1 || actionable != (findings > 0)) }
' "$REVIEW" >"$COVERED"
sort -o "$COVERED" "$COVERED"

test "$(uniq -d "$COVERED" | wc -l | tr -d ' ')" = 0
diff -u "$REQUIRED" "$COVERED" >/dev/null
