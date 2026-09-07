#!/bin/sh
set -eu

MATRIX=${1:?usage: validate-review-output.sh MATRIX REVIEW_OUTPUT}
REVIEW=${2:?usage: validate-review-output.sh MATRIX REVIEW_OUTPUT}
REQUIRED=$(mktemp)
COVERED=$(mktemp)
trap 'rm -f "$REQUIRED" "$COVERED"' EXIT HUP INT TERM

awk -F '\t' 'NR > 1 && $8 == "applicable" { print $1 }' "$MATRIX" | sort >"$REQUIRED"
awk '
  /^ROW INV-[0-9][0-9][0-9] verdict=no-findings$/ { print $2; next }
  /^FINDING F-[0-9][0-9][0-9] row_id=(INV-[0-9][0-9][0-9]|OMITTED) priority=P[0-3] status=open evidence=.+ suggested_action=.+$/ {
    split($3, field, "="); if (field[2] != "OMITTED") print field[2]; next
  }
  /^(ROW|FINDING) / { invalid = 1 }
  END { exit invalid }
' "$REVIEW" >"$COVERED"
sort -o "$COVERED" "$COVERED"

grep -Eq '^\[pylot\] phase=independent-review status=done actionable=(yes|no)$' "$REVIEW"
test "$(uniq -d "$COVERED" | wc -l | tr -d ' ')" = 0
diff -u "$REQUIRED" "$COVERED" >/dev/null
