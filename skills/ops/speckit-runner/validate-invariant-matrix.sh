#!/bin/sh
set -eu

MATRIX=${1:?usage: validate-invariant-matrix.sh MATRIX}
EXPECTED_HEADER='id	class	provenance	success_behavior	negative_behavior	evidence_method	expected_check	applicability	state	repository	checkpoint	receipt	finding_ids'

awk -F '\t' -v expected="$EXPECTED_HEADER" '
  NR == 1 { if ($0 != expected) exit 10; next }
  NF != 13 { exit 11 }
  $1 !~ /^INV-[0-9][0-9][0-9]$/ || seen[$1]++ { exit 12 }
  $2 !~ /^(authorization-trust|state-data-integrity|failure-degradation|concurrency-idempotency|lifecycle-cleanup)$/ { exit 13 }
  $3 == "" || $3 == "-" || $4 == "" || $4 == "-" || $5 == "" || $5 == "-" || $6 == "" || $6 == "-" || $7 == "" || $7 == "-" { exit 14 }
  $8 != "applicable" && $8 !~ /^not-applicable: .+/ { exit 15 }
  $9 !~ /^(passed|failed|not-run|unavailable|stale|not-applicable)$/ { exit 16 }
  ($8 == "applicable" && $9 == "not-applicable") || ($8 ~ /^not-applicable: / && $9 != "not-applicable") { exit 17 }
  ($9 == "passed" || $9 == "failed") && ($10 == "" || $10 == "-" || length($11) != 40 || $11 !~ /^[0-9a-f]+$/ || $12 !~ /^supervisor:/) { exit 18 }
  $13 != "-" && $13 !~ /^F-[0-9][0-9][0-9](,F-[0-9][0-9][0-9])*$/ { exit 19 }
  END { if (NR == 0) exit 20 }
' "$MATRIX"
