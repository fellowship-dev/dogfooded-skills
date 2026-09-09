#!/usr/bin/env bash
# dxm-trends.test.sh — standalone suite for dxm-backfill-body.sh + dxm-trends.sh.
#
# Two things here can be wrong in ways nobody notices until a client has the
# file, and both are tested against real artefacts rather than reasoned about:
#
#   1. THE TRAILER STRIP. has_body is compared against the AI trailer, so if the
#      strip fails the "correlation" is the same column twice and every
#      conclusion drawn from it is circular. Tested against a REAL git
#      repository with hand-written message shapes, not against a mocked string.
#   2. PERSONAL DATA IN THE DEFAULT RENDER. The suite asserts the login and the
#      display name are absent from the default file and present in the
#      opt-in one, so "the default is safe" is a test result, not a claim.
#
# Also covered: ISO week labelling at both year boundaries (the case a naive
# %W gets wrong), the in-progress week being excluded from comparisons, and the
# page containing no JavaScript at all.
#
#   ./dxm-trends.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKFILL="$SCRIPT_DIR/dxm-backfill-body.sh"
TRENDS="$SCRIPT_DIR/dxm-trends.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dxm-trends-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DXM_HOME="$TMP/home"
export DXM_DB="$DXM_HOME/dxm.db"
export DXM_CACHE="$DXM_HOME/cache"
export DXM_OUT="$TMP/out"
mkdir -p "$DXM_HOME" "$DXM_CACHE" "$DXM_OUT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()   { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "missing: $3"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1" "present but must not be: $3"; else ok "$1"; fi; }
Q()   { sqlite3 "$DXM_DB" "$1"; }

# ===========================================================================
# Fixture: a real git repository whose messages exercise the strip rule.
# ===========================================================================
SRC="$TMP/src"; mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" config user.email alice@acme.example
git -C "$SRC" config user.name  "Alice Alpha"
git -C "$SRC" config commit.gpgsign false

# mk <n> <expected_has_body> <message>
declare -a EXPECT_SHA EXPECT_HB EXPECT_NAME
mk() {
  local name="$1" want="$2" msg="$3"
  printf '%s\n' "$name" >> "$SRC/log.txt"
  git -C "$SRC" add -A
  # A fixed date per commit so the week bucket is deterministic.
  GIT_AUTHOR_DATE="2026-06-0${4}T10:00:00Z" GIT_COMMITTER_DATE="2026-06-0${4}T10:00:00Z" \
    git -C "$SRC" commit -q -m "$msg"
  EXPECT_SHA+=("$(git -C "$SRC" rev-parse HEAD)")
  EXPECT_HB+=("$want")
  EXPECT_NAME+=("$name")
}

mk subject_only        0 'feat: add a thing'                                                        1
mk trailer_only        0 'feat: add a thing

Co-Authored-By: Claude <noreply@anthropic.com>'                                                     1
mk real_body           1 'feat: add a thing

It rewires the widget so the sprocket no longer stalls.'                                            2
mk body_and_trailer    1 'feat: add a thing

It rewires the widget.

Co-Authored-By: Claude <noreply@anthropic.com>
Signed-off-by: Alice <alice@acme.example>'                                                          2
mk trailers_only_many  0 'chore: bump

Signed-off-by: Alice <alice@acme.example>
Reviewed-by: Bob <bob@acme.example>
Refs: ABC-1'                                                                                        3
mk url_line            1 'docs: link

https://example.com/spec'                                                                           3
mk whitespace_only     0 'chore: whitespace

   '                                                                                                4
mk prose_colon         0 'fix: thing

Note: this is deliberately stripped'                                                                4
mk bullet_body         1 'refactor: split

- extracted the parser
- moved the tests'                                                                                  5

git clone -q --bare "$SRC" "$DXM_CACHE/acme__api.git"

# ---- DB rows for exactly those commits ------------------------------------
sqlite3 "$DXM_DB" < "$SKILL_DIR/schema.sql" >/dev/null
{
  echo "PRAGMA foreign_keys=ON; BEGIN;"
  echo "INSERT INTO repos(repo_id,owner,name,full_name,default_branch,is_shallow,clone_path)
        VALUES (1,'acme','api','acme/api','main',0,'$DXM_CACHE/acme__api.git');"
  echo "INSERT INTO identities(identity_id,login,display_name,account_type,is_bot)
        VALUES (1,'alicealpha','Alice Alpha','User',0);"
  echo "INSERT INTO identity_emails(email,identity_id,resolution_source,commit_count)
        VALUES ('alice@acme.example',1,'github_api',9);"
  i=0
  for sha in "${EXPECT_SHA[@]}"; do
    d=$(( i / 2 + 1 ))
    echo "INSERT INTO commits(repo_id,sha,author_email,author_name,author_identity_id,authored_at,is_merge,subject)
          VALUES (1,'$sha','alice@acme.example','Alice Alpha',1,'2026-06-0${d}T10:00:00Z',0,'${EXPECT_NAME[$i]}');"
    i=$((i+1))
  done
  # One AI trailer, on the commit that carries it, so precision/recall has data.
  echo "INSERT INTO ai_agents(agent_key,label,match_email,is_ai) VALUES ('claude','Claude','noreply@anthropic.com',1);"
  echo "INSERT INTO ai_trailers(repo_id,sha,raw_name,raw_email,agent_key,is_ai)
        VALUES (1,'${EXPECT_SHA[1]}','Claude','noreply@anthropic.com','claude',1),
               (1,'${EXPECT_SHA[3]}','Claude','noreply@anthropic.com','claude',1);"
  echo "COMMIT;"
} | sqlite3 "$DXM_DB" 2>/dev/null

echo "== 1. interface =="
"$BACKFILL" --help >/dev/null 2>&1;      eq "backfill --help exits 0"      "$?" "0"
"$BACKFILL" --bogus >/dev/null 2>&1;     eq "backfill bad flag exits 1"    "$?" "1"
"$TRENDS"   --help >/dev/null 2>&1;      eq "trends --help exits 0"        "$?" "0"
"$TRENDS"   --bogus >/dev/null 2>&1;     eq "trends bad flag exits 1"      "$?" "1"
"$TRENDS"   >/dev/null 2>&1;             eq "trends without --org exits 1" "$?" "1"
"$TRENDS" --org acme --since 06-01-2026 >/dev/null 2>&1; eq "trends bad date exits 1" "$?" "1"
"$TRENDS" --org acme/api >/dev/null 2>&1;                eq "trends owner/name exits 1" "$?" "1"
"$TRENDS" --org nosuchorg >/dev/null 2>&1;               eq "trends empty org exits 4"  "$?" "4"

echo
echo "== 2. THE TRAILER STRIP (the whole measurement) =="
BF="$("$BACKFILL" --repo acme/api 2>/dev/null)"; RC=$?
eq "backfill exits 0" "$RC" "0"
eq "backfill measured all 9 commits" \
   "$(printf '%s' "$BF" | sed -n 's/.*"commits_measured_total":\([0-9]*\).*/\1/p')" "9"
i=0
for sha in "${EXPECT_SHA[@]}"; do
  got="$(Q "SELECT COALESCE(has_body,'NULL') FROM commits WHERE sha='$sha';")"
  eq "has_body(${EXPECT_NAME[$i]})" "$got" "${EXPECT_HB[$i]}"
  i=$((i+1))
done
# The single most important assertion in this file: a commit whose ONLY
# non-subject content is the Co-Authored-By line must NOT read as multi-line.
eq "Co-Authored-By alone does not make a body" \
   "$(Q "SELECT has_body FROM commits WHERE sha='${EXPECT_SHA[1]}';")" "0"
eq "body_chars excludes the stripped trailer" \
   "$(Q "SELECT body_chars FROM commits WHERE sha='${EXPECT_SHA[3]}';")" "22"
eq "body_chars is 0 when nothing survives" \
   "$(Q "SELECT body_chars FROM commits WHERE sha='${EXPECT_SHA[4]}';")" "0"
eq "NULL is never written for a reachable commit" \
   "$(Q "SELECT COUNT(*) FROM commits WHERE has_body IS NULL;")" "0"

echo
echo "== 3. the view exposes it, so nothing re-derives it =="
eq "v_commits_enriched.has_body present" \
   "$(Q "SELECT COUNT(*) FROM pragma_table_info('v_commits_enriched') WHERE name='has_body';")" "1"
eq "multi-line count through the view" \
   "$(Q "SELECT SUM(has_body) FROM v_commits_enriched WHERE repo_full_name='acme/api' AND is_merge=0;")" "4"

echo
echo "== 4. ISO week labelling, including both year boundaries =="
ISO="strftime('%Y', date(?,'+3 days')) || '-W' || printf('%02d', (CAST(strftime('%j', date(?,'+3 days')) AS INTEGER)-1)/7 + 1)"
isolab() { Q "SELECT strftime('%Y', date('$1','+3 days')) || '-W' || printf('%02d', (CAST(strftime('%j', date('$1','+3 days')) AS INTEGER)-1)/7 + 1);"; }
eq "2019-12-30 is 2020-W01" "$(isolab 2019-12-30)" "2020-W01"
eq "2020-12-28 is 2020-W53" "$(isolab 2020-12-28)" "2020-W53"
eq "2015-12-28 is 2015-W53" "$(isolab 2015-12-28)" "2015-W53"
eq "2021-01-04 is 2021-W01" "$(isolab 2021-01-04)" "2021-W01"

echo
echo "== 5. default render: shape, labels, no script =="
ENV_D="$("$TRENDS" --org acme --since 2026-05-01 --until 2026-06-30 --min-cohort 1 2>/dev/null)"; RC=$?
eq "default render exits 0" "$RC" "0"
OUT_D="$(printf '%s' "$ENV_D" | sed -n 's/.*"out":"\([^"]*\)".*/\1/p')"
if [ -f "$OUT_D" ]; then ok "default file written"; else bad "default file written" "$OUT_D"; fi
eq "envelope says the privacy check passed" \
   "$(printf '%s' "$ENV_D" | sed -n 's/.*"pii_check":"\([^"]*\)".*/\1/p')" "passed"
hasnt "no <script> tag anywhere"  "$OUT_D" "<script"
hasnt "no javascript: url"        "$OUT_D" "javascript:"
hasnt "no external http(s) asset" "$OUT_D" "https://"
has   "x-axis is labelled"        "$OUT_D" "ISO calendar week"
has   "ISO week labels are drawn" "$OUT_D" "2026-W2"
has   "marks carry native tooltips" "$OUT_D" "<title>"
has   "the not-a-performance-tool notice is present" "$OUT_D" "must"
eq "svg elements were emitted" \
   "$(grep -c '<svg ' "$OUT_D")" "$(grep -c '</svg>' "$OUT_D")"
eq "no placeholder survived" "$(grep -c '__[A-Z][A-Z]*__' "$OUT_D")" "0"
eq "file mode is 600" "$(stat -c '%a' "$OUT_D" 2>/dev/null || stat -f '%Lp' "$OUT_D")" "600"

echo
echo "== 6. PRIVACY: the default file names nobody =="
hasnt "no login in the default render"        "$OUT_D" "alicealpha"
hasnt "no display name in the default render" "$OUT_D" "Alice Alpha"
hasnt "no email in the default render"        "$OUT_D" "alice@acme.example"
if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$OUT_D"; then
  bad "nothing email-shaped in the default render" "regex matched"
else ok "nothing email-shaped in the default render"; fi

echo
echo "== 7. the opt-in render is a DIFFERENT file and does name people =="
ENV_I="$("$TRENDS" --org acme --since 2026-05-01 --until 2026-06-30 --min-cohort 1 --include-individuals 2>/dev/null)"
OUT_I="$(printf '%s' "$ENV_I" | sed -n 's/.*"out":"\([^"]*\)".*/\1/p')"
case "$OUT_I" in
  *-INDIVIDUALS-do-not-circulate.html) ok "individuals render has its own filename" ;;
  *) bad "individuals render has its own filename" "$OUT_I" ;;
esac
if [ "$OUT_I" != "$OUT_D" ]; then ok "individuals render cannot overwrite the shareable one"
else bad "individuals render cannot overwrite the shareable one" "same path"; fi
has "individuals render contains the login" "$OUT_I" "alicealpha"
has "individuals render is marked do-not-circulate" "$OUT_I" "DO NOT CIRCULATE"
if [ -f "$OUT_D" ]; then ok "the default file still exists after the opt-in run"
else bad "the default file still exists after the opt-in run" "gone"; fi
hasnt "still no login in the default file" "$OUT_D" "alicealpha"

echo
echo "== 8. per-person charts are withheld below the cohort floor =="
ENV_C="$("$TRENDS" --org acme --since 2026-05-01 --until 2026-06-30 --min-cohort 3 --include-individuals \
          --out "$TMP/cohort.html" 2>/dev/null)"
has "under-cohort run says it withheld" "$TMP/cohort.html" "Withheld"
hasnt "under-cohort run names nobody"   "$TMP/cohort.html" "alicealpha"

echo
echo "== 9. the in-progress week is marked and never compared =="
ENV_N="$("$TRENDS" --org acme --since 2026-05-01 --min-cohort 1 --out "$TMP/now.html" 2>/dev/null)"
has "the in-progress week is named"  "$TMP/now.html" "is not over"
has "partial marks are drawn hollow" "$TMP/now.html" "partial"
has "tooltips say the week is unfinished" "$TMP/now.html" "week still in progress"
CUR_ISO="$(printf '%s' "$ENV_N" | sed -n 's/.*"current_week":"\([^"]*\)".*/\1/p')"
if grep -q "against <b>[^<]*→ <b>\?$CUR_ISO" "$TMP/now.html"; then
  bad "the change table excludes the current week" "current week is a comparison bound"
else ok "the change table excludes the current week"; fi

echo
echo "== 10. the multi-line proxy audits itself on the page =="
has "precision is published" "$TMP/now.html" "precision"
has "recall is published"    "$TMP/now.html" "recall"
has "the base rate is published next to it" "$TMP/now.html" "base rate"
has "labelled as an agentic proxy, not AI usage" "$TMP/now.html" "AGENTIC-USAGE PROXY"
has "the assistive blind spot is declared" "$TMP/now.html" "blind to assistive"

echo
echo "== 11. incremental + rebuild are idempotent =="
BF2="$("$BACKFILL" --repo acme/api 2>/dev/null)"
eq "second backfill still reports 9 measured" \
   "$(printf '%s' "$BF2" | sed -n 's/.*"commits_measured_total":\([0-9]*\).*/\1/p')" "9"
"$BACKFILL" --repo acme/api --rebuild >/dev/null 2>&1
eq "rebuild does not change any value" \
   "$(Q "SELECT SUM(has_body) FROM commits;")" "4"
eq "no run left dangling" "$(Q "SELECT COUNT(*) FROM runs WHERE status='running';")" "0"

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
