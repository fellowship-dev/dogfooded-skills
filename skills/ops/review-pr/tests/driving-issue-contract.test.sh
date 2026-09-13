#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
REVIEW="$ROOT/skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md"
AUTHOR="$ROOT/skills/product/create-compelling-prs/SKILL.md"
TEMPLATE="$ROOT/skills/shared/follow-up-issue-template.md"
EXTRACTOR="$ROOT/skills/ops/review-pr/scripts/extract-issue-links.sh"
REFS_FIXTURE="$ROOT/skills/ops/review-pr/tests/fixtures/refs-driving-pr-body.md"

assert_contains() {
  local file=$1 needle=$2 scenario=$3
  grep -Fq -- "$needle" "$file" || {
    printf 'FAIL %s: %s does not contain %s\n' "$scenario" "$file" "$needle" >&2
    exit 1
  }
  printf 'PASS %s\n' "$scenario"
}

assert_not_contains() {
  local file=$1 needle=$2 scenario=$3
  if grep -Fq -- "$needle" "$file"; then
    printf 'FAIL %s: obsolete guidance remains: %s\n' "$scenario" "$needle" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$scenario"
}

# Canonical follow-up fields and workflow contract.
assert_contains "$TEMPLATE" 'title begins exactly `Follow-up of #N`' template-title
assert_contains "$TEMPLATE" 'first line of the body is exactly `Follow-up of #N`' template-opening
assert_contains "$TEMPLATE" '## Origin' template-origin
assert_contains "$TEMPLATE" '## Remaining acceptance criteria' template-criteria
assert_contains "$TEMPLATE" '## Out of scope' template-out-of-scope
assert_contains "$TEMPLATE" 'verbatim' template-verbatim-copy
assert_contains "$TEMPLATE" 'closing pull request links the follow-up issue' template-linkage
assert_contains "$TEMPLATE" '`ready-to-work`' template-ready-label
assert_contains "$TEMPLATE" 'same priority label as issue `#N`' template-priority

# Reviewer behavior: preserve closing linkage and emit calibrated Bugs for both fixture cases.
assert_contains "$REVIEW" 'retaining the closing reference' reviewer-retains-closes
assert_contains "$REVIEW" 'NAMES each unaddressed' reviewer-names-criteria
assert_contains "$REVIEW" 'Severity: **Bug**' reviewer-unmet-is-bug
assert_contains "$REVIEW" 'driving issue only with `Refs #N`' reviewer-refs-fixture
assert_contains "$REVIEW" 'emit a **Bug** requiring a closing reference' reviewer-refs-is-bug
assert_contains "$REVIEW" 'calibrate confidence normally' reviewer-calibrates-confidence
assert_contains "$REVIEW" 'clearly identified as related' reviewer-related-refs-exception
assert_contains "$REVIEW" '../../../../shared/follow-up-issue-template.md' reviewer-shared-contract
assert_not_contains "$REVIEW" 'finding recommending `Refs #N`' reviewer-obsolete-downgrade-removed

# Author behavior: exactly one closing driving issue, decomposition, and the same shared contract.
assert_contains "$AUTHOR" 'exactly one driving issue' author-one-driving-issue
assert_contains "$AUTHOR" '`Closes #N`, `Fixes #N`, or' author-closing-keyword
assert_contains "$AUTHOR" 'Every later PR in deliberate multi-PR work gets its own driving issue' author-decomposes
assert_contains "$AUTHOR" 'clearly identified as related context' author-related-refs-exception
assert_contains "$AUTHOR" '../../shared/follow-up-issue-template.md' author-shared-contract
assert_not_contains "$AUTHOR" 'final phase carries the `Closes`' author-obsolete-final-phase-removed

# Behavioral producer-to-reviewer fixture: Stage 00 must retain both a Refs-only driving link and
# its complete source line, plus a separately identified related-context link. This is the raw
# classification Stage 01 consumes to apply its driving-issue Bug rule.
actual_links=$(bash "$EXTRACTOR" "$REFS_FIXTURE")
expected_links=$(printf '%s\n' \
  $'Refs\t162\tRefs #162' \
  $'Refs\t99\tRelated context only: Refs #99')
[ "$actual_links" = "$expected_links" ] || {
  printf 'FAIL refs-driving-fixture\nexpected:\n%s\nactual:\n%s\n' \
    "$expected_links" "$actual_links" >&2
  exit 1
}
printf 'PASS refs-driving-fixture\n'
assert_contains "$REVIEW" 'driving issue only with `Refs #N`' refs-fixture-reviewer-consumer

# Both consumer references must resolve to the one canonical file.
for consumer in "$REVIEW" "$AUTHOR"; do
  target=$(grep -oE '\([^)]*follow-up-issue-template\.md\)' "$consumer" | head -1 | tr -d '()')
  resolved=$(cd "$(dirname "$consumer")" && realpath "$target")
  [ "$resolved" = "$TEMPLATE" ] || {
    printf 'FAIL shared-template-resolution: %s resolves to %s\n' "$consumer" "$resolved" >&2
    exit 1
  }
done
printf 'PASS both-consumers-resolve-canonical-template\n'
printf 'PASS driving issue contract\n'
