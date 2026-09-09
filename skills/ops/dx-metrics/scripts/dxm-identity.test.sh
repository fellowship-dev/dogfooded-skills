#!/usr/bin/env bash
# Standalone test for dxm-identity.sh against a synthetic DB. No network.
set -uo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DXM_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dxm-test.XXXXXX")"
export DXM_DB="$DXM_HOME/dxm.db"
S="$SKILL/scripts/dxm-identity.sh"

pass=0; fail=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=$3 got=$2"; fi }

echo "=== DXM_HOME=$DXM_HOME"

# --- 0. --help works and exits 0 -------------------------------------------
out="$("$S" --help 2>/dev/null)"; rc=$?
chk "--help exit 0" "$rc" "0"
case "$out" in *"dxm-identity.sh"*) ok "--help prints usage" ;; *) bad "--help prints usage" ;; esac

# --- 0b. unknown flag is exit 1 --------------------------------------------
"$S" --nonsense >/dev/null 2>&1; rc=$?
chk "unknown flag -> exit 1" "$rc" "1"

# --- 1. seed a synthetic DB -------------------------------------------------
sqlite3 "$DXM_DB" < "$SKILL/schema.sql"
sqlite3 "$DXM_DB" <<'SQL'
INSERT INTO repos(owner,name,full_name,default_branch,is_shallow) VALUES
  ('acme','api','acme/api','main',0),
  ('acme','web','acme/web','main',0);

-- alice: two emails (corporate + noreply) — the alias/multi-email case
INSERT INTO commits(repo_id,sha,author_email,author_name,authored_at,is_merge,subject) VALUES
  (1,'a1','Alice@Corp.com','Alice A','2026-01-05T10:00:00Z',0,'feat: one'),
  (1,'a2','alice@corp.com','Alice A','2026-01-06T10:00:00Z',0,'feat: two'),
  (1,'a3','alice@users.noreply.github.com','alice','2026-01-07T10:00:00Z',0,'fix: three'),
  -- bob: single email
  (1,'b1','bob@corp.com','Bob B','2026-01-08T10:00:00Z',0,'feat: four'),
  -- a bot
  (1,'d1','49699333+dependabot[bot]@users.noreply.github.com','dependabot[bot]','2026-01-09T10:00:00Z',0,'chore: bump'),
  -- a merge commit by the web UI
  (1,'w1','noreply@github.com','GitHub','2026-01-10T10:00:00Z',1,'Merge pull request #1'),
  -- an email nobody can resolve
  (2,'x1','ghost@nowhere.invalid','Ghost','2026-01-11T10:00:00Z',0,'feat: five'),
  (2,'x2','ghost@nowhere.invalid','Ghost','2026-01-12T10:00:00Z',0,'feat: six');

INSERT INTO pull_requests(repo_id,number,title,state,author_login,merged_at) VALUES
  (1,1,'feat: one','MERGED','alice','2026-01-06T12:00:00Z'),
  (1,2,'chore: bump','MERGED','dependabot[bot]','2026-01-09T12:00:00Z'),
  (1,3,'feat: reviewer-only','MERGED','carol','2026-01-10T12:00:00Z');
SQL
ok "synthetic DB seeded"

# HERMETICITY: dxm-identity.sh installs references/identity-overrides.seed.tsv
# when no override file exists yet. That seed carries real machine-address
# mappings for the machine this skill was built on, and every count below would
# move whenever somebody edited it. Pre-creating an empty file pins the fixture;
# the seed itself is tested on its own, in section 15.
mkdir -p "$DXM_HOME/identity"
printf '# test fixture: deliberately empty so the shipped seed is not installed\n' \
  > "$DXM_HOME/identity/identity-overrides.tsv"

# --- 2. first run, no --resolve --------------------------------------------
env1="$("$S" 2>/tmp/dxm-t1.err)"; rc=$?
chk "run 1 exit 0" "$rc" "0"
printf '  envelope: %s\n' "$env1"
echo "$env1" | jq -e . >/dev/null 2>&1 && ok "envelope is valid JSON" || bad "envelope is valid JSON" "$env1"
chk "one line of stdout" "$(printf '%s' "$env1" | wc -l | tr -d ' ')" "0"

# emails: alice@corp.com (case-folded to one), alice@users.noreply, bob, dependabot, noreply@github.com, ghost = 6
chk "distinct emails (case-folded)" "$(echo "$env1" | jq -r .emails)" "6"
chk "alice emails folded to one" "$(sqlite3 "$DXM_DB" "SELECT commit_count FROM identity_emails WHERE email='alice@corp.com';")" "2"

# identities seeded from pull_requests: alice, dependabot[bot], carol
chk "identities from PR authors" "$(echo "$env1" | jq -r .identities)" "3"
chk "dependabot flagged as bot" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='dependabot[bot]';")" "1"
chk "bot_reason recorded" "$(sqlite3 "$DXM_DB" "SELECT bot_reason LIKE 'bot_patterns:%' FROM identities WHERE login='dependabot[bot]';")" "1"
chk "alice is human" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='alice';")" "0"
chk "humans count" "$(echo "$env1" | jq -r .humans)" "2"

# nothing resolved yet -> all 6 emails unresolved, all 8 commits unattributed
chk "emails_unresolved" "$(echo "$env1" | jq -r .emails_unresolved)" "6"
chk "unattributed_commits" "$(echo "$env1" | jq -r .unattributed_commits)" "8"
chk "unattributed pct" "$(echo "$env1" | jq -r .unattributed_commit_pct)" "100.0"

# coverage: 6 units, all llm (nothing resolved), coverage 0
chk "coverage total" "$(echo "$env1" | jq -r .coverage.total)" "6"
chk "coverage llm" "$(echo "$env1" | jq -r .coverage.llm)" "6"
chk "coverage pct" "$(echo "$env1" | jq -r .coverage.coverage_pct)" "0.0"
chk "backlog reason is a spec" \
  "$(sqlite3 "$DXM_DB" "SELECT reason FROM v_llm_backlog LIMIT 1;")" \
  "identity not resolved yet: re-run dxm-identity.sh --resolve"

# --- 3. no PII on stdout ----------------------------------------------------
if echo "$env1" | grep -Eqi 'alice|bob|ghost|@corp|nowhere'; then
  bad "stdout carries no PII" "$env1"
else ok "stdout carries no PII"; fi

# --- 4. artifacts written ---------------------------------------------------
[ -f "$DXM_HOME/identity/identity-overrides.tsv" ] && ok "override template created" || bad "override template created"
[ -f "$DXM_HOME/identity/mailmap" ] && ok "mailmap written" || bad "mailmap written"
[ -f "$DXM_HOME/identity/identity-review.tsv" ] && ok "review queue written" || bad "review queue written"
chk "review queue lists 6 emails" \
  "$(grep -c '^email' "$DXM_HOME/identity/identity-review.tsv")" "6"

# --- 5. simulate --resolve results by hand (no network) ---------------------
sqlite3 "$DXM_DB" <<'SQL'
INSERT INTO identities(login,display_name,account_type) VALUES('bob','Bob B','User')
  ON CONFLICT(login) DO UPDATE SET display_name=excluded.display_name;
UPDATE identities SET display_name='Alice A', account_type='User' WHERE login='alice';
UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login='alice'),
  resolution_source='github_api', resolved_at='2026-01-20T00:00:00Z'
  WHERE email IN ('alice@corp.com','alice@users.noreply.github.com');
UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login='bob'),
  resolution_source='github_api' WHERE email='bob@corp.com';
UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login='dependabot[bot]'),
  resolution_source='github_api' WHERE email LIKE '%dependabot%';
UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login='web-flow'),
  resolution_source='github_api' WHERE email='noreply@github.com';
INSERT OR IGNORE INTO identities(login,account_type) VALUES('web-flow','User');
UPDATE identity_emails SET identity_id=(SELECT identity_id FROM identities WHERE login='web-flow')
  WHERE email='noreply@github.com';
SQL

env2="$("$S" 2>/tmp/dxm-t2.err)"; rc=$?
chk "run 2 exit 0" "$rc" "0"
printf '  envelope: %s\n' "$env2"
chk "emails_resolved" "$(echo "$env2" | jq -r .emails_resolved)" "5"
chk "emails_unresolved" "$(echo "$env2" | jq -r .emails_unresolved)" "1"
chk "web-flow flagged bot by pattern" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='web-flow';")" "1"
chk "coverage pct after resolve" "$(echo "$env2" | jq -r .coverage.coverage_pct)" "83.3"
chk "coverage script rows" "$(echo "$env2" | jq -r .coverage.script)" "5"
chk "first_seen_at set for alice" "$(sqlite3 "$DXM_DB" "SELECT first_seen_at FROM identities WHERE login='alice';")" "2026-01-05T10:00:00Z"
chk "last_seen_at set for alice" "$(sqlite3 "$DXM_DB" "SELECT last_seen_at FROM identities WHERE login='alice';")" "2026-01-07T10:00:00Z"

# mailmap: alice canonical email is alice@corp.com (2 commits) > noreply (1)
echo "--- mailmap ---"; grep -v '^#' "$DXM_HOME/identity/mailmap"
grep -q 'Alice A <alice@corp.com> <alice@users.noreply.github.com>' "$DXM_HOME/identity/mailmap" \
  && ok "mailmap folds alice's second email onto her canonical one" \
  || bad "mailmap folds alice's second email"
chk "mailmap_entries in envelope" "$(echo "$env2" | jq -r .mailmap_entries)" "5"

# --- 5b. the mailmap actually works in git ---------------------------------
GD="$(mktemp -d "${TMPDIR:-/tmp}/dxm-git.XXXXXX")"
( cd "$GD" && git init -q . \
  && git -c user.name='Alice A' -c user.email='alice@corp.com' commit -q --allow-empty -m one \
  && git -c user.name='alice' -c user.email='alice@users.noreply.github.com' commit -q --allow-empty -m two )
sl="$(cd "$GD" && git -c mailmap.file="$DXM_HOME/identity/mailmap" shortlog -sn HEAD | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
chk "git accepts the mailmap and folds both commits" "$sl" "2 Alice A"
rm -rf "$GD"

# --- 6. override file: email confirm + human + alias + name ----------------
OV="$DXM_HOME/identity/identity-overrides.tsv"
printf 'email\tghost@nowhere.invalid\tghostly\tconfirmed by the team lead\n' >> "$OV"
printf 'name\tghostly\tGhost Rider\n' >> "$OV"
printf 'human\tweb-flow\tnot really, but tests the override beating the regex\n' >> "$OV"
printf 'bot\tcarol\tservice account after all\n' >> "$OV"

env3="$("$S" 2>/tmp/dxm-t3.err)"; rc=$?
chk "run 3 exit 0" "$rc" "0"
printf '  envelope: %s\n' "$env3"
chk "overrides_applied" "$(echo "$env3" | jq -r .overrides_applied)" "4"
chk "ghost resolved via override" "$(sqlite3 "$DXM_DB" "SELECT resolution_source FROM identity_emails WHERE email='ghost@nowhere.invalid';")" "manual"
chk "emails_unresolved now 0" "$(echo "$env3" | jq -r .emails_unresolved)" "0"
chk "override beats bot regex (web-flow)" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='web-flow';")" "0"
chk "override forces carol to bot" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='carol';")" "1"
chk "display name from override" "$(sqlite3 "$DXM_DB" "SELECT display_name FROM identities WHERE login='ghostly';")" "Ghost Rider"
chk "coverage: manual = script-with-fallback" "$(echo "$env3" | jq -r .coverage.script_with_fallback)" "1"
chk "coverage pct now 100" "$(echo "$env3" | jq -r .coverage.coverage_pct)" "100.0"

# --- 6b. re-run is idempotent (the whole point) ----------------------------
env4="$("$S" 2>/tmp/dxm-t4.err)"
for k in identities humans bots emails emails_resolved emails_unresolved mailmap_entries; do
  a="$(echo "$env3" | jq -r ".$k")"; b="$(echo "$env4" | jq -r ".$k")"
  chk "idempotent: $k" "$b" "$a"
done

# --- 7. alias merge ---------------------------------------------------------
printf 'alias\tbob\talice\tsame human, second account\n' >> "$OV"
env5="$("$S" 2>/tmp/dxm-t5.err)"
chk "alias: bob excluded" "$(sqlite3 "$DXM_DB" "SELECT is_excluded FROM identities WHERE login='bob';")" "1"
chk "alias: bob's email repointed to alice" \
  "$(sqlite3 "$DXM_DB" "SELECT i.login FROM identity_emails e JOIN identities i ON i.identity_id=e.identity_id WHERE e.email='bob@corp.com';")" "alice"
grep -q '<bob@corp.com>' "$DXM_HOME/identity/mailmap" && ok "alias: bob's email still in mailmap (mapped to alice)" || bad "alias: bob email in mailmap"

# --- 8. bad override file -> exit 4 with a line number ---------------------
cp "$OV" "$OV.bak"
printf 'bogus\tfoo\tbar\n' >> "$OV"
"$S" >/dev/null 2>/tmp/dxm-t6.err; rc=$?
chk "bad directive -> exit 4" "$rc" "4"
grep -q "unknown directive 'bogus'" /tmp/dxm-t6.err && ok "bad directive names itself + line no" || bad "bad directive message" "$(cat /tmp/dxm-t6.err)"
chk "failed run recorded as error" "$(sqlite3 "$DXM_DB" "SELECT status FROM runs ORDER BY run_id DESC LIMIT 1;")" "error"
mv "$OV.bak" "$OV"

# --- 9. --dry-run writes nothing to identity data --------------------------
before="$(sqlite3 "$DXM_DB" "SELECT COUNT(*)||':'||COALESCE(SUM(is_bot),0) FROM identities;")"
sqlite3 "$DXM_DB" "UPDATE identities SET is_bot=0 WHERE login='dependabot[bot]';"
envd="$("$S" --dry-run 2>/tmp/dxm-t7.err)"
chk "--dry-run exit 0" "$?" "0"
chk "--dry-run reports dry_run" "$(echo "$envd" | jq -r .dry_run)" "true"
chk "--dry-run did NOT re-flag the bot" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='dependabot[bot]';")" "0"
"$S" >/dev/null 2>&1
chk "normal run DOES re-flag the bot" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='dependabot[bot]';")" "1"

# --- 10. --rebuild re-derives ----------------------------------------------
sqlite3 "$DXM_DB" "UPDATE identities SET is_bot=1, bot_reason='garbage' WHERE login='alice';"
"$S" --rebuild >/dev/null 2>/tmp/dxm-t8.err
chk "--rebuild clears a wrong bot flag" "$(sqlite3 "$DXM_DB" "SELECT is_bot FROM identities WHERE login='alice';")" "0"
chk "--rebuild keeps resolved links" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM identity_emails WHERE identity_id IS NOT NULL;")" "6"

# --- 11. --backfill-commits -------------------------------------------------
chk "backfill off by default" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM commits WHERE author_identity_id IS NOT NULL;")" "0"
envb="$("$S" --backfill-commits 2>/tmp/dxm-t9.err)"
chk "backfill attributes all 8 commits" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM commits WHERE author_identity_id IS NOT NULL;")" "8"
chk "backfill count in envelope" "$(echo "$envb" | jq -r .backfilled_commits)" "8"
chk "v_commits_enriched sees no unattributed" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM v_commits_enriched WHERE is_unattributed=1;")" "0"
chk "v_commits_enriched excludes bots correctly" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM v_commits_enriched WHERE is_bot=1;")" "1"

# --- 12. --repo scoping + --org --------------------------------------------
envr="$("$S" --repo acme/web 2>/dev/null)"
chk "--repo scopes repo count" "$(echo "$envr" | jq -r .repos_in_scope)" "1"
envo="$("$S" --org acme 2>/dev/null)"
chk "--org scopes repo count" "$(echo "$envo" | jq -r .repos_in_scope)" "2"
"$S" --repo notaslashrepo >/dev/null 2>&1; chk "bad --repo -> exit 1" "$?" "1"

# --- 13. no run left dangling ----------------------------------------------
chk "no dangling 'running' rows" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM runs WHERE status='running';")" "0"

# --- 14. quoting hostility: an email with a single quote -------------------
sqlite3 "$DXM_DB" "INSERT INTO commits(repo_id,sha,author_email,author_name,authored_at,is_merge,subject) VALUES(1,'q1','o''brien@corp.com','O''Brien','2026-02-01T10:00:00Z',0,'feat: quote');"
envq="$("$S" 2>/tmp/dxm-t10.err)"; rc=$?
chk "single-quoted email survives -> exit 0" "$rc" "0"
chk "single-quoted email ingested" "$(sqlite3 "$DXM_DB" "SELECT COUNT(*) FROM identity_emails WHERE email LIKE '%brien%';")" "1"

# --- 15. the shipped seed, glob overrides, and the attribution pair ---------
# A separate DXM_HOME with no override file, so the seed installs itself.
SEED_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dxm-seed.XXXXXX")"
(
  export DXM_HOME="$SEED_HOME" DXM_DB="$SEED_HOME/dxm.db"
  sqlite3 "$DXM_DB" < "$SKILL/schema.sql"
  sqlite3 "$DXM_DB" <<'SQL'
INSERT INTO repos(owner,name,full_name,default_branch,is_shallow) VALUES ('acme','api','acme/api','main',0);
INSERT INTO commits(repo_id,sha,author_email,author_name,authored_at,is_merge,subject) VALUES
  -- a machine family the seed maps by GLOB: two different hostnames, one rule
  (1,'e1','ubuntu@ip-10-0-0-1.ec2.internal','Ubuntu','2026-01-05T10:00:00Z',0,'chore: one'),
  (1,'e2','ubuntu@ip-10-0-0-2.ec2.internal','Ubuntu','2026-01-06T10:00:00Z',0,'chore: two'),
  -- a machine the seed maps by exact address
  (1,'w1','worker@ci-agent.local','CI Agent','2026-01-07T10:00:00Z',0,'feat: three'),
  -- a human on their own laptop: steerer known, executor declared by trailer
  (1,'m1','octocat@workstation.local','Octo Cat','2026-01-08T10:00:00Z',0,'feat: four'),
  -- an address nobody maps: this is the UNKNOWN STEERER population
  (1,'g1','someone@unmapped.invalid','Nobody','2026-01-09T10:00:00Z',0,'feat: five');
INSERT INTO ai_trailers(repo_id,sha,raw_name,raw_email,agent_key,is_ai) VALUES
  (1,'m1','Claude','noreply@anthropic.com','claude',1);
SQL
  "$S" --backfill-commits >/dev/null 2>&1
) >/dev/null 2>&1
SEED_DB="$SEED_HOME/dxm.db"
SQ() { sqlite3 "$SEED_DB" "$1"; }

grep -q '^email' "$SEED_HOME/identity/identity-overrides.tsv" 2>/dev/null \
  && ok "seed installed when no override file exists" || bad "seed installed"
chk "seed file is chmod 600" "$(stat -c '%a' "$SEED_HOME/identity/identity-overrides.tsv" 2>/dev/null || stat -f '%Lp' "$SEED_HOME/identity/identity-overrides.tsv")" "600"
chk "glob override matched both EC2 hostnames" \
  "$(SQ "SELECT COUNT(*) FROM identity_emails e JOIN identities i USING(identity_id) WHERE i.login='dxm-machine-ec2-devbox';")" "2"
chk "glob override did NOT insert the pattern as an address" \
  "$(SQ "SELECT COUNT(*) FROM identity_emails WHERE email LIKE '%*%';")" "0"
chk "exact override mapped the in-house agent worker" \
  "$(SQ "SELECT i.login FROM identity_emails e JOIN identities i USING(identity_id) WHERE e.email='worker@ci-agent.local';")" "dxm-machine-ci-agent"
chk "dxm-machine-* is auto-flagged as a machine" \
  "$(SQ "SELECT COUNT(*) FROM identities WHERE login LIKE 'dxm-machine-%' AND is_bot=0;")" "0"
chk "a human on their own laptop maps to the human" \
  "$(SQ "SELECT i.login FROM identity_emails e JOIN identities i USING(identity_id) WHERE e.email='octocat@workstation.local';")" "octocat"
chk "the unmapped address stays unresolved, never guessed" \
  "$(SQ "SELECT COUNT(*) FROM identity_emails WHERE email='someone@unmapped.invalid' AND identity_id IS NULL;")" "1"

# The attribution pair itself.
chk "machine addresses are steerer_state=machine" \
  "$(SQ "SELECT COUNT(*) FROM v_commits_enriched WHERE steerer_state='machine';")" "3"
chk "the human laptop commit is steerer_state=known" \
  "$(SQ "SELECT COUNT(*) FROM v_commits_enriched WHERE steerer_state='known';")" "1"
chk "the unmapped commit is steerer_state=unknown" \
  "$(SQ "SELECT COUNT(*) FROM v_commits_enriched WHERE steerer_state='unknown';")" "1"
chk "a trailered commit has executor_state=agent" \
  "$(SQ "SELECT executor_state FROM v_commits_enriched WHERE sha='m1';")" "agent"
chk "its executor confidence is a declared trailer" \
  "$(SQ "SELECT executor_confidence FROM v_commits_enriched WHERE sha='m1';")" "declared-trailer"
chk "its executor agent is recorded" \
  "$(SQ "SELECT executor_agent_key FROM v_commits_enriched WHERE sha='m1';")" "claude"
# THE RULE: no trailer is UNKNOWN, never human.
chk "an untrailered commit is executor_state=unknown" \
  "$(SQ "SELECT executor_state FROM v_commits_enriched WHERE sha='g1';")" "unknown"
chk "its confidence says there is no evidence either way" \
  "$(SQ "SELECT executor_confidence FROM v_commits_enriched WHERE sha='g1';")" "no-evidence"
chk "executor_state can never be 'human'" \
  "$(SQ "SELECT COUNT(*) FROM v_commits_enriched WHERE executor_state NOT IN ('agent','unknown');")" "0"
chk "unknown steerer is NOT counted as human" \
  "$(SQ "SELECT COUNT(*) FROM v_commits_enriched c JOIN v_human_identities i ON i.identity_id=c.author_identity_id WHERE c.steerer_state='unknown';")" "0"
rm -rf "$SEED_HOME"

echo
echo "=== $pass passed, $fail failed"
echo "=== artifacts: $DXM_HOME/identity/"
[ "$fail" -eq 0 ] || exit 1
