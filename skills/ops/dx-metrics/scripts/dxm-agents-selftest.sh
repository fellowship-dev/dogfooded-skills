#!/usr/bin/env bash
# dxm-agents-selftest.sh — assert what each ai_agents pattern does and does NOT
# match.
#
# WHY THIS FILE EXISTS: the agent-pattern table has produced two shipped, wrong,
# confident claims already.
#
#   1. A `getline`/RS ordering bug loaded only the FIRST pattern, so every AI
#      commit became "claude" and a client dashboard published *100% Claude* as
#      a finding.
#   2. The `other-ai` catch-all was `\[bot\]`, which classified DEPENDABOT as an
#      AI executor — 94 trailers in the first real database. A dependency-bump
#      bot is not a coding agent, and the AI share is a metric whose entire
#      value is being a floor nobody can accuse of overclaiming.
#
# Both were found by hand, downstream, after the numbers had been shown to
# someone. This suite pins the table instead.
#
# It replicates exactly how dxm-ingest-git.sh applies the patterns: POSIX ERE,
# against the LOWERCASED full trailer line (`subject_l ~ apat[i]`), first match
# wins, with `other-ai` forced last. grep -E is the same ERE class as awk's.
#
#   ./dxm-agents-selftest.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dxm-agents.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/agents.db"
sqlite3 "$DB" < "$SKILL_DIR/schema.sql" >/dev/null

PATS="$TMP/patterns.tsv"
sqlite3 -separator $'\t' "$DB" \
  "SELECT agent_key, pattern FROM ai_agents WHERE enabled=1
    ORDER BY (agent_key='other-ai'), agent_id;" > "$PATS"

NPAT="$(wc -l < "$PATS" | tr -d ' ')"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }

# The loader bug again: a table that reads back as one record is the failure
# mode that produced "100% Claude". Assert the count before asserting anything
# that depends on it.
if [ "$NPAT" -ge 10 ]; then ok "$NPAT agent patterns loaded"
else bad "agent patterns loaded" "only $NPAT — the pattern table did not load"; fi

first_match() {
  local line; line="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  local k p
  while IFS=$'\t' read -r k p; do
    [ -n "${k:-}" ] || continue
    if printf '%s\n' "$line" | grep -Eq -- "$p"; then printf '%s' "$k"; return 0; fi
  done < "$PATS"
  printf '%s' "HUMAN"
}

check() {
  local got; got="$(first_match "$1")"
  if [ "$got" = "$2" ]; then ok "$2  <-  $1"
  else bad "$1" "matched [$got], expected [$2]"; fi
}

echo "== agents that must be recognised =="
check "Co-authored-by: Claude Opus 5 <noreply@anthropic.com>"                claude
check "Co-authored-by: Claude Sonnet 4.6 <noreply@anthropic.com>"            claude
check "Co-authored-by: Cursor Agent <cursoragent@cursor.com>"                cursor
check "Co-authored-by: Copilot <copilot@github.com>"                         copilot
check "Co-authored-by: Ona <noreply@ona.com>"                                ona
check "Co-authored-by: openai codex <codex@openai.com>"                      codex

echo
echo "== an in-house agent signs itself six ways; all of them are one agent =="
check "Co-authored-by: CI Agent <worker@ci-agent.local>"                     ci-agent
check "Co-authored-by: CI Agent <worker@ci-agent.internal>"                  ci-agent
check "Co-authored-by: CI Agent Operator <operator@ci-agent.dev>"            ci-agent
check "Co-authored-by: CI Agent infra.ops <infra.ops@ci-agent>"              ci-agent
check "Co-authored-by: ci-agent <ci@example.invalid>"                        ci-agent
check "Co-authored-by: ci-agent-app[bot] <ci-agent-app[bot]@users.noreply.github.com>" ci-agent

echo
echo "== NOT agents: a bot is not automatically an AI coding agent =="
# This is the assertion that would have caught the shipped overclaim.
check "Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>" HUMAN
check "Co-authored-by: renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>"     HUMAN
check "Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" HUMAN
check "Co-authored-by: imgbot[bot] <31427850+imgbot[bot]@users.noreply.github.com>"         HUMAN
check "Co-authored-by: codecov[bot] <codecov@codecov.io>"                                   HUMAN

echo
echo "== NOT agents: real people =="
check "Co-authored-by: Jane Human <jane@corp.example>"                       HUMAN
check "Co-authored-by: Octo Cat <octocat@workstation.local>"                 HUMAN
check "Co-authored-by: A Developer <dev@example.org>"                        HUMAN

printf '\n{"ok":%s,"script":"dxm-agents-selftest.sh","patterns":%s,"cases":%d,"passed":%d,"failed":%d}\n' \
  "$([ "$FAIL" -eq 0 ] && echo true || echo false)" "$NPAT" "$((PASS+FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
