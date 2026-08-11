#!/usr/bin/env bash
# dxm-classify-selftest.sh -- pin the classification rule table.
#
# OWNERSHIP: W3. Needs NO database, NO network and NO gh: it drives
# dxm-classify-rules.awk directly with a synthetic TSV and asserts the exact
# (class, rule) verdict for each case.
#
# Run it after ANY edit to dxm-classify-rules.awk. A rule change that silently
# re-buckets an existing case is how a dashboard starts lying between two runs.
#
#   ./dxm-classify-selftest.sh          # exit 0 = all cases pass
#   ./dxm-classify-selftest.sh --verbose

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_AWK="$SCRIPT_DIR/dxm-classify-rules.awk"
VERBOSE=0
# Explicit if-blocks, not `[ ] && x`: under `set -e` a bare AND-list whose test
# fails is a trap waiting for the next person who reorders these lines.
if [ "${1-}" = "--help" ]; then sed -n '2,14p' "$0"; exit 0; fi
if [ "${1-}" = "--verbose" ]; then VERBOSE=1; fi
if [ ! -f "$RULES_AWK" ]; then echo "rule engine not found: $RULES_AWK" >&2; exit 2; fi

TAB="$(printf '\t')"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dxm-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# CASES:  title|labels|head_ref|base_ref|has_issue_link|is_dep_bot  =>  expected_class|expected_rule
# `|` separates input fields (converted to TAB before awk sees them); ` => `
# separates the input from the expectation. Neither may appear inside a field.
CASES='
Revert "feat: add billing"|enhancement|revert-101-feat-billing|main|0|0 => revert|revert:head-branch
revert: add billing|||main|0|0 => revert|revert:cc-prefix
Revert PR #99||mf/rev|main|0|0 => revert|revert:title
Reapply "feat: add billing"||reapply-1|main|0|0 => chore|revert:reapply-rollforward
Some change||revert/x|main|0|0 => revert|revert:head-prefix
Some change|revert|mf/x|main|0|0 => revert|revert:label
Bump lodash from 4.17.20 to 4.17.21|dependencies|dependabot/npm/lodash|main|0|1 => deps|deps:bot-author
chore(deps): update react||renovate/react|main|0|0 => deps|deps:head-branch
build(deps-dev): bump eslint||x/y|main|0|0 => deps|deps:cc-scope
Bump lodash from 4.17.20 to 4.17.21||mf/x|main|0|0 => deps|deps:bump-title
Whatever|dependencies|mf/x|main|0|0 => deps|deps:label
feat(billing): add invoices||feature/inv|main|1|0 => feature|cc:feat
fix: null pointer on login|bug|fix/login|main|1|0 => bugfix|cc:fix
Fix: null pointer||mf/x|main|0|0 => bugfix|cc:fix
FEAT(api): new endpoint||mf/x|main|0|0 => feature|cc:feat
fix!: breaking bug||mf/x|main|0|0 => bugfix|cc:fix
hotfix: payment gateway down||mf/pay|main|0|0 => bugfix|cc:hotfix
perf: speed up query||mf/perf|main|0|0 => refactor|cc:perf
security: patch XSS||mf/s|main|0|0 => bugfix|cc:security
spec(admin): cover the edge case||mf/s|main|0|0 => test|cc:spec
docs: update readme||x|main|0|0 => docs|cc:docs
chore: tidy imports|chore|chore/tidy|main|0|0 => chore|cc:chore
Release 2.4.0||release/2.4.0|main|0|0 => chore|release:title
v1.2.3||rel|main|0|0 => chore|release:title
Opaque||release/2.4.0|main|0|0 => chore|release:head-branch
Update the thing|type: bug|mf/thing|main|1|0 => bugfix|label:bug
Update the thing|c-bug|mf/thing|main|0|0 => bugfix|label:bug
Opaque|Documentation|mf/x|main|0|0 => docs|label:documentation
Whatever this is||hotfix/urgent|main|0|0 => bugfix|branch:hotfix
Merge pull request #12 from acme/feature-x||feature-x|main|0|0 => feature|branch:feature
Whatever this is||develop|main|0|0 => chore|release:promotion
Merge develop into main||develop|master|0|0 => chore|release:promotion
Automated cherry pick of #139162: fix scheduler||mf/cp|release-1.36|0|0 => chore|backport:cherry-pick
Bump version to 3.0.0||mf/v|main|0|0 => chore|verb:release
Prepare release 4.1||mf/r|main|0|0 => chore|verb:release
Upgrade COS image family to cos-129-lts||mf/cos|main|0|0 => deps|verb:bump
test/images: bump agnhost, nginx||mf/i|main|0|0 => deps|verb:bump
Fix broken login redirect||mf/login-redirect|main|1|0 => bugfix|verb:fix
Add tests for billing||mf/t|main|0|0 => test|verb:test
Update documentation for API||mf/d|main|0|0 => docs|verb:docs
Refactor the payment module||mf/pay|main|0|0 => refactor|verb:refactor
Clean up dead code||mf/c|main|0|0 => refactor|verb:refactor
Remove unused Active Record internals||mf/r|main|0|0 => refactor|verb:refactor
[8-1-stable] Remove the dead branch||mf/r|main|0|0 => refactor|verb:refactor
Add support for SAML||mf/saml|main|0|0 => feature|verb:add
Something totally opaque|needs-review, p2|mf/opaque|main|1|0 => unclassified|no-cc-prefix+no-mapped-label+no-branch-pattern+no-title-verb+has-issue-link
Something totally opaque||2996-lane-review|main|0|0 => unclassified|no-cc-prefix+no-labels+no-branch-pattern+no-title-verb
WIP: exploring||mf/wip|main|0|0 => unclassified|unmapped-cc-prefix(wip)+no-labels+no-branch-pattern+no-title-verb
Update the thing|type: bug, enhancement|mf/thing|main|0|0 => unclassified|no-cc-prefix+label-conflict+no-branch-pattern+no-title-verb
'

# ---- build the TSV the rule engine eats -----------------------------------
: > "$TMPD/in.tsv"; : > "$TMPD/expect.txt"
n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  input="${line%% => *}"
  expect="${line#* => }"
  n=$((n + 1))
  # input fields are `|` separated; the rule engine wants TAB, prefixed by
  # pr_id / repo / number.
  printf '%d\tacme/api\t%d\t%s\n' "$n" "$((1000 + n))" \
    "$(printf '%s' "$input" | tr '|' "$TAB")" >> "$TMPD/in.tsv"
  printf '%s\n' "$expect" >> "$TMPD/expect.txt"
done <<EOF
$CASES
EOF

awk -v ver=selftest -v heur=1 \
    -v sqlfile="$TMPD/rows.sql" -v covfile="$TMPD/cov.tsv" \
    -v cntfile="$TMPD/cnt.tsv" -v unresfile="$TMPD/unres.tsv" \
    -f "$RULES_AWK" < "$TMPD/in.tsv"

# actual class comes from the generated SQL, actual rule from the coverage TSV
# (which is where the give-up reason lives, not the per-PR rule text).
awk -F"'" '{print $2}' "$TMPD/rows.sql" > "$TMPD/actual_class.txt"
cut -f4 "$TMPD/cov.tsv" > "$TMPD/actual_rule.txt"

pass=0; fail=0
i=0
while IFS= read -r exp; do
  i=$((i + 1))
  ec="${exp%%|*}"; er="${exp#*|}"
  ac="$(sed -n "${i}p" "$TMPD/actual_class.txt")"
  ar="$(sed -n "${i}p" "$TMPD/actual_rule.txt")"
  title="$(awk -F'\t' -v r="$i" 'NR==r{print $4}' "$TMPD/in.tsv")"
  if [ "$ec" = "$ac" ] && [ "$er" = "$ar" ]; then
    pass=$((pass + 1))
    if [ "$VERBOSE" -eq 1 ]; then
      printf 'ok   %-48s -> %s / %s\n' "$title" "$ac" "$ar"
    fi
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %s / %s\n     actual:   %s / %s\n' \
      "$title" "$ec" "$er" "$ac" "$ar" >&2
  fi
done < "$TMPD/expect.txt"

printf '%s\n' "{\"ok\":$([ "$fail" -eq 0 ] && echo true || echo false),\"script\":\"dxm-classify-selftest.sh\",\"cases\":$n,\"passed\":$pass,\"failed\":$fail}"
[ "$fail" -eq 0 ]
