#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd -P)
REVIEW="$ROOT/skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md"
AUTHOR="$ROOT/skills/product/create-compelling-prs/SKILL.md"
DOUBLE_CHECK="$ROOT/skills/ops/double-check/stages/02-review/CONTEXT.md"
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

# A previously completed transfer must pass both review stages; requiring another
# follow-up forever would make the author's conforming workflow unshippable.
assert_contains "$REVIEW" 'inspect the linked follow-up issue, if any.' reviewer-reads-existing-followup
assert_contains "$REVIEW" 'carries every deferred criterion verbatim' reviewer-verifies-full-transfer
assert_contains "$REVIEW" 'generate NO finding for that transferred remainder.' reviewer-accepts-conforming-followup
assert_contains "$REVIEW" 'neither implemented nor covered by a conforming linked follow-up' reviewer-uncovered-remainder-is-bug
assert_contains "$REVIEW" 'claim that deferred work has already passed.' reviewer-transfer-is-not-completion
assert_contains "$DOUBLE_CHECK" 'A conforming transfer backs the' double-check-accepts-conforming-transfer
assert_contains "$DOUBLE_CHECK" 'generate no finding merely because that remainder is absent' double-check-does-not-reject-transferred-remainder
assert_contains "$DOUBLE_CHECK" 'follow-up: it must carry the deferred criteria verbatim.' double-check-reads-and-verifies-followup
assert_contains "$DOUBLE_CHECK" 'If a criterion is neither implemented nor transferred' double-check-uncovered-remainder-requires-fix
assert_contains "$DOUBLE_CHECK" 'Operational or post-merge acceptance remains owed by the follow-up, not claimed done.' double-check-transfer-is-not-completion
assert_contains "$DOUBLE_CHECK" 'Never recommend downgrading the' double-check-retains-closing-reference
assert_contains "$DOUBLE_CHECK" '../../references/follow-up-issue-template.md' double-check-shared-contract
assert_not_contains "$DOUBLE_CHECK" 'implement it is unbacked.' double-check-unconditional-rejection-removed

# Author behavior: exactly one closing driving issue, decomposition, and the same shared contract.
assert_contains "$AUTHOR" 'exactly one driving issue' author-one-driving-issue
assert_contains "$AUTHOR" '`Closes #N`, `Fixes #N`, or' author-closing-keyword
assert_contains "$AUTHOR" 'Every later PR in deliberate multi-PR work gets its own driving issue' author-decomposes
assert_contains "$AUTHOR" 'clearly identified as related context' author-related-refs-exception
assert_contains "$AUTHOR" 'references/follow-up-issue-template.md' author-shared-contract
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

# Review-pr retains the canonical reference. Portable installs carry exact, provenance-marked
# copies inside each skill; fail on missing, escaped, stale or unproven copies.
python3 - "$REVIEW" "$AUTHOR" "$DOUBLE_CHECK" "$TEMPLATE" <<'PY_CONTRACT'
from pathlib import Path
import re
import sys

review, author, double_check, canonical = map(Path, sys.argv[1:])
canonical = canonical.resolve(strict=True)

def target(consumer):
    match = re.search(r"\]\(([^)]*follow-up-issue-template\.md)\)", consumer.read_text())
    assert match, f"missing follow-up reference: {consumer}"
    return (consumer.parent / match.group(1)).resolve(strict=True)

assert target(review) == canonical, "review-pr must retain the canonical reference"
header = b"<!-- Vendored from skills/shared/follow-up-issue-template.md at 3f2479aa27f8068a4463b8d64c4f79a549093ac4; keep this installed copy synchronized with that canonical contract. -->\n\n"
for consumer, skill_root in [(author, author.parent), (double_check, double_check.parents[2])]:
    resolved = target(consumer)
    assert resolved.is_relative_to(skill_root.resolve()), f"reference escapes installed skill: {resolved}"
    content = resolved.read_bytes()
    assert content.startswith(header), f"missing exact vendored provenance: {resolved}"
    assert content[len(header):] == canonical.read_bytes(), f"stale vendored contract: {resolved}"
print("PASS canonical-review-and-identical-portable-contracts")
PY_CONTRACT
printf 'PASS driving issue contract\n'
