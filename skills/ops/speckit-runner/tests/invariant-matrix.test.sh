#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/invariant-matrix"
REFERENCE="$ROOT/references/invariant-matrix.md"
SKILL="$ROOT/SKILL.md"
REVIEW_VALIDATOR="$ROOT/validate-review-output.sh"
ADVERSARIAL="$FIXTURES/adversarial-fixture.sh"
FEATURE_MATRIX="$ROOT/../../../specs/134-invariant-matrix/invariant-matrix.tsv"
EXPECTED_HEADER='id	class	provenance	success_behavior	negative_behavior	evidence_method	expected_check	applicability	state	repository	checkpoint	receipt	finding_ids'

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

validate_matrix() {
  awk -F '\t' -v expected="$EXPECTED_HEADER" '
    NR == 1 { if ($0 != expected) exit 10; next }
    NF != 13 { exit 11 }
    $1 !~ /^INV-[0-9][0-9][0-9]$/ || seen[$1]++ { exit 12 }
    $2 !~ /^(authorization-trust|state-data-integrity|failure-degradation|concurrency-idempotency|lifecycle-cleanup)$/ { exit 13 }
    $3 == "" || $3 == "-" || $4 == "" || $4 == "-" || $5 == "" || $5 == "-" || $6 == "" || $6 == "-" || $7 == "" || $7 == "-" { exit 14 }
    $8 != "applicable" && $8 !~ /^not-applicable: / { exit 15 }
    $9 !~ /^(passed|failed|not-run|unavailable|stale|not-applicable)$/ { exit 16 }
    ($8 == "applicable" && $9 == "not-applicable") || ($8 ~ /^not-applicable: / && $9 != "not-applicable") { exit 17 }
    ($9 == "passed" || $9 == "failed") && ($10 == "" || length($11) != 40 || $11 !~ /^[0-9a-f]+$/ || $12 !~ /^supervisor:/) { exit 18 }
    $13 != "-" && $13 !~ /^F-[0-9][0-9][0-9](,F-[0-9][0-9][0-9])*$/ { exit 19 }
  ' "$1"
}

reconcile_matrix() {
  repo=$1 head=$2
  awk -F '\t' -v OFS='\t' -v repo="$repo" -v head="$head" '
    NR == 1 { print; next }
    ($9 == "passed" || $9 == "failed") && ($10 != repo || $11 != head) { $9 = "stale" }
    { print }
  '
}

assert_disclosure() {
  awk -F '\t' '
    NR == 1 { next }
    $2 !~ /^(passed|failed|not-run|unavailable|stale|not-applicable)$/ { exit 21 }
    $6 == "unavailable" { unavailable = 1 }
    ($7 == "open" || $7 == "declined") { residual = 1 }
    $8 != "yes" { exit 22 }
    END { if (!unavailable || !residual) exit 23 }
  ' "$1"
}

validate_matrix "$FIXTURES/schema.tsv" || fail 'canonical schema rejected'
pass 'canonical schema and stable IDs accepted'

HEADER_ONLY=$(mktemp)
head -n 1 "$FIXTURES/schema.tsv" >"$HEADER_ONLY"
validate_matrix "$HEADER_ONLY" || fail 'header-only matrix rejected'
rm -f "$HEADER_ONLY"
pass 'header-only matrix accepted'

validate_matrix "$FEATURE_MATRIX" || fail 'persisted feature matrix rejected'
pass 'persisted planning matrix accepted'

awk -F '\t' 'NR > 1 && $4 == "yes" { classes[$2]++; if ($5 !~ /^INV-[0-9][0-9][0-9]$/) exit 1 } NR > 1 && $4 == "no" { irrelevant++; if ($5 != "OMITTED") exit 1 } END { exit !(classes["authorization-trust"] && classes["state-data-integrity"] && classes["failure-degradation"] && classes["concurrency-idempotency"] && classes["lifecycle-cleanup"] && irrelevant == 1) }' "$FIXTURES/discovery.tsv" || fail 'discovery coverage or irrelevant-class omission'
pass 'five source-backed classes covered and unsupported class omitted'

awk -F '\t' 'NR > 1 { seen[$2]++; if ($1 ~ /^seeded-/ && $5 != "challenge") exit 1 } END { exit !(seen["INV-101"] && seen["INV-102"] && seen["OMITTED"] && seen["INV-103"]) }' "$FIXTURES/review.tsv" || fail 'review did not cover seeded challenges and omission'
awk -F '\t' 'NR == FNR { if (NR > 1 && $4 == "yes") required[$5]=1; next } FNR > 1 { covered[$2]=1 } END { for (id in required) if (!covered[id]) exit 1 }' "$FIXTURES/discovery.tsv" "$FIXTURES/review.tsv" || fail 'review omitted an applicable matrix row'
awk -F '\t' '$1 == "surviving-row" && $2 == "INV-103" && $3 == "NONE" { found=1 } END { exit !found }' "$FIXTURES/review.tsv" || fail 'explicit no-findings verdict absent'
pass 'row falsification, contradiction, omission, and no-findings covered'

for boundary in authorization secret-handling process-tree-cancellation session-continuity compatibility; do
  "$ADVERSARIAL" "$boundary" || fail "seeded $boundary defect was not detected"
done
pass 'all five portable seeded behavior defects detected'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
awk -F '\t' -v OFS='\t' 'NR == 2 { $3 = "" } { print }' "$FIXTURES/schema.tsv" >"$TMP/missing-provenance.tsv"
if validate_matrix "$TMP/missing-provenance.tsv"; then fail 'missing provenance accepted'; fi
awk -F '\t' -v OFS='\t' 'NR == 2 { $4 = "-" } { print }' "$FIXTURES/schema.tsv" >"$TMP/sentinel-behavior.tsv"
if validate_matrix "$TMP/sentinel-behavior.tsv"; then fail 'sentinel required behavior accepted'; fi
awk -F '\t' -v OFS='\t' 'NR == 2 { $9="passed"; $10=""; $11=""; $12="producer says pass" } { print }' "$FIXTURES/schema.tsv" >"$TMP/narrative-pass.tsv"
if validate_matrix "$TMP/narrative-pass.tsv"; then fail 'narrative-only pass accepted'; fi
pass 'malformed provenance and narrative-only pass rejected'

cat >"$TMP/complete-review.txt" <<'EOF'
ROW INV-001 verdict=no-findings
ROW INV-002 verdict=no-findings
[pylot] phase=independent-review status=done actionable=no
EOF
"$REVIEW_VALIDATOR" "$FIXTURES/schema.tsv" "$TMP/complete-review.txt" || fail 'complete reviewer output rejected'
sed '/ROW INV-002/d' "$TMP/complete-review.txt" >"$TMP/incomplete-review.txt"
if "$REVIEW_VALIDATOR" "$FIXTURES/schema.tsv" "$TMP/incomplete-review.txt"; then fail 'incomplete reviewer output accepted'; fi
sed 's/ROW INV-001 verdict=no-findings/FINDING F-001 row_id=INV-001 status=open/' "$TMP/complete-review.txt" >"$TMP/malformed-review.txt"
if "$REVIEW_VALIDATOR" "$FIXTURES/schema.tsv" "$TMP/malformed-review.txt"; then fail 'malformed reviewer finding accepted'; fi
pass 'reviewer output completeness enforced at runtime'

reconcile_matrix fellowship-dev/example 2222222222222222222222222222222222222222 <"$FIXTURES/schema.tsv" >"$TMP/reconciled.tsv"
awk -F '\t' '$1 == "INV-001" { exit !($9 == "stale" && $11 == "1111111111111111111111111111111111111111" && $12 == "supervisor:exit=0" && $13 == "F-001") } END { if (NR < 2) exit 1 }' "$TMP/reconciled.tsv" || fail 'old-head receipt was not staled and preserved'
pass 'exact-checkpoint reconciliation stales unmatched receipt'

assert_disclosure "$FIXTURES/lifecycle.tsv" || fail 'lifecycle disclosure lost state, review, finding, or PR reachability'
states=$(awk -F '\t' 'NR > 1 { print $2 }' "$FIXTURES/lifecycle.tsv" | sort -u | tr '\n' ' ')
for state in passed failed not-run unavailable stale not-applicable; do
  case " $states " in *" $state "*) ;; *) fail "missing lifecycle state $state";; esac
done
pass 'all six states, unavailable review, residual findings, and PR reachability preserved'

for phrase in 'MATRIX RECEIPT' 'row_id=OMITTED' 'narrative-only result' 'finding IDs' 'single PR-creation boundary'; do
  grep -F "$phrase" "$SKILL" "$REFERENCE" >/dev/null || fail "instruction contract missing: $phrase"
done
pass 'planning, falsification, supervisor ownership, and disclosure instructions present'

printf 'PASS invariant matrix contract\n'
