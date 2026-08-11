#!/usr/bin/env bash
# dxm-dashboard.test.sh — standalone test suite for dxm-dashboard.sh.
#
# It exists because the two ways this renderer fails are both SILENT:
#
#   1. A JavaScript exception at render time leaves the page blank apart from
#      the <noscript>. The file is written, the envelope says ok:true, the byte
#      count looks healthy, and the reader sees nothing. Nothing in the shell
#      can catch that, so this suite executes the template's own script against
#      the real payload under a minimal DOM shim and asserts it produced HTML.
#   2. A name, login or email reaching the DEFAULT render. That is the one
#      guarantee this skill makes that cannot be walked back once a file has
#      been sent to a client.
#
# Reuses the aggregate suite's fixture, so the expected numbers below are the
# same hand-computed ones and there is only one fixture to maintain.
#
#   ./dxm-dashboard.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGG="$SCRIPT_DIR/dxm-aggregate.sh"
DASH="$SCRIPT_DIR/dxm-dashboard.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dxm-dash-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export DXM_HOME="$TMP/home"
export DXM_OUT="$TMP/out"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# Same fixture as dxm-aggregate.test.sh — extracted from that file so the two
# suites can never drift apart into two different "expected" worlds.
sed -n '/^# ---8<--- FIXTURE ---8<---$/,$p' "$SCRIPT_DIR/dxm-aggregate.test.sh" \
  | tail -n +2 | sed 's/^# \{0,1\}//' > "$TMP/fixture.sql"
mkdir -p "$DXM_HOME" "$DXM_OUT"
# An empty override file so the shipped seed is not installed into the fixture.
mkdir -p "$DXM_HOME/identity"
printf '# test fixture: empty on purpose\n' > "$DXM_HOME/identity/identity-overrides.tsv"
sqlite3 "$DXM_HOME/dxm.db" < "$SKILL_DIR/schema.sql" >/dev/null
sqlite3 "$DXM_HOME/dxm.db" < "$TMP/fixture.sql"
"$AGG" --repo acme/api --repo acme/web --until 2026-06-20 --adoption-window-days 3 >/dev/null 2>&1

DATA_OF() {  # DATA_OF <html> -> the embedded JSON payload, un-escaped
  python3 - "$1" <<'PY'
import re, sys
h = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'id="dxm-data">\s*(\{.*?\})\s*</script>', h, re.S)
sys.stdout.write(m.group(1).replace('<\\/', '</') if m else '')
PY
}
# The expression travels in the ENVIRONMENT, not in argv: it contains quotes,
# commas and braces, and every one of those is a shell hazard on the way in.
JQ() { DXM_EXPR="$1" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print(eval(os.environ["DXM_EXPR"], {"d": d}))' <<<"$2"; }

echo "== 1. interface =="
"$DASH" --help >/dev/null 2>&1; eq "--help exits 0" "$?" "0"
"$DASH" --bogus >/dev/null 2>&1; eq "unknown flag exits 1" "$?" "1"
"$DASH" --period fortnight >/dev/null 2>&1; eq "bad --period exits 1" "$?" "1"

echo
echo "== 2. default render =="
ENV1="$("$DASH" --scope org --scope-key acme --period week --since 2026-06-01 --until 2026-06-20 2>/dev/null)"; RC=$?
eq "default render exits 0" "$RC" "0"
OUT1="$(printf '%s' "$ENV1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["out"])' 2>/dev/null)"
[ -n "$OUT1" ] && [ -f "$OUT1" ] && ok "wrote a file" || bad "wrote a file" "$OUT1"
eq "file is chmod 600" "$(stat -f '%Lp' "$OUT1" 2>/dev/null || stat -c '%a' "$OUT1")" "600"
printf '%s' "$ENV1" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null \
  && ok "envelope is valid JSON" || bad "envelope is valid JSON" "$ENV1"

echo
echo "== 3. THE privacy guarantee: no personal information in the default render =="
LEAK=""
for name in alice bob carol dependabot 'alice@corp' 'bob@corp' 'ghost@'; do
  grep -qi -- "$name" "$OUT1" && LEAK="$LEAK $name"
done
eq "no login, name or email in the default render" "${LEAK:-none}" "none"
# The unresolved-email queue holds real addresses. Only its COUNT may be read.
eq "no unresolved-email ROWS in the payload" \
   "$(grep -c 'nowhere.invalid' "$OUT1" | head -n1)" "0"

echo
echo "== 4. the attribution pair reaches the page =="
# Scoped to acme/api and to WEEK A alone, because that is the bucket whose
# numbers are hand-computed in dxm-aggregate.test.sh: 7 non-merge commits —
# alice 4, bob 2, and one whose author email resolves to nobody — of which 2
# carry an AI trailer.
"$DASH" --scope repo --scope-key acme/api --period week \
        --since 2026-06-01 --until 2026-06-07 --out "$TMP/weekA.html" >/dev/null 2>&1
eq "week-A render exits 0" "$?" "0"
D1="$(DATA_OF "$TMP/weekA.html")"
eq "payload carries an attribution object" "$(JQ "'attribution' in d" "$D1")" "True"
eq "all executions in the bucket"           "$(JQ "d['attribution']['commits']" "$D1")" "7"
eq "steerer axis: known = 6"                "$(JQ "d['attribution']['steerer_known']" "$D1")" "6"
eq "steerer axis: unknown = 1"              "$(JQ "d['attribution']['steerer_unknown']" "$D1")" "1"
eq "distinct steerers = 2"                  "$(JQ "d['attribution']['steerers']" "$D1")" "2"
eq "executor axis: agent = 2"               "$(JQ "d['attribution']['executor_agent']" "$D1")" "2"
eq "executor axis: unknown = 5"             "$(JQ "d['attribution']['executor_unknown']" "$D1")" "5"
eq "the 2x2 accounts for every execution exactly once" \
   "$(JQ "d['attribution']['pair_known_agent']+d['attribution']['pair_known_unk']+d['attribution']['pair_unk_agent']+d['attribution']['pair_unk_unk']==d['attribution']['commits']" "$D1")" "True"
eq "unknown_steerer_pct is in the envelope" \
   "$(printf '%s' "$ENV1" | python3 -c 'import json,sys;print("unknown_steerer_pct" in json.load(sys.stdin))')" "True"
eq "the AI-share metric is LABELLED a floor" \
   "$(JQ "any(c['metric_key']=='adoption.ai_commit_share' and 'FLOOR' in c['label'] for c in d['catalog'])" "$D1")" "True"
eq "both AI-share series are present" \
   "$(JQ "len(set(m['metric_key'] for m in d['metrics'] if m['metric_key'].startswith('adoption.ai_commit_share')))" "$D1")" "2"
# 2/7 over every execution, 2/6 over known steerers only. The gap between those
# two IS the attribution artifact, published rather than argued about.
eq "AI floor over all executions = 2/7" \
   "$(JQ "round([m['value'] for m in d['metrics'] if m['metric_key']=='adoption.ai_commit_share'][0],2)" "$D1")" "28.57"
eq "AI floor over known steerers = 2/6" \
   "$(JQ "round([m['value'] for m in d['metrics'] if m['metric_key']=='adoption.ai_commit_share_known_steerer'][0],2)" "$D1")" "33.33"

echo
echo "== 5. leverage is gated like the per-person rate it is =="
# Week A has 2 steerers, below the default --min-cohort of 3.
eq "leverage value withheld under the cohort floor" \
   "$(JQ "[m['value'] for m in d['metrics'] if m['metric_key']=='leverage.commits_per_steerer'][0] is None" "$D1")" "True"
eq "the withholding is stated, not silent" \
   "$(JQ "'WITHHELD' in [m['note'] for m in d['metrics'] if m['metric_key']=='leverage.commits_per_steerer'][0]" "$D1")" "True"
eq "the steerer COUNT survives (a headcount is not a person)" \
   "$(JQ "[m['value'] for m in d['metrics'] if m['metric_key']=='leverage.steerers'][0]" "$D1")" "2.0"
"$DASH" --scope repo --scope-key acme/api --period week \
        --since 2026-06-01 --until 2026-06-07 --min-cohort 2 --out "$TMP/lowfloor.html" >/dev/null 2>&1
D2="$(DATA_OF "$TMP/lowfloor.html")"
eq "leverage published once the floor is met: 6 commits / 2 steerers" \
   "$(JQ "[m['value'] for m in d['metrics'] if m['metric_key']=='leverage.commits_per_steerer'][0]" "$D2")" "3.0"
eq "its numerator leaves the unknown steerer out" \
   "$(JQ "[m['numerator'] for m in d['metrics'] if m['metric_key']=='leverage.commits_per_steerer'][0]" "$D2")" "6.0"

echo
echo "== 6. --include-individuals: separate file, names only there =="
ENV3="$("$DASH" --scope org --scope-key acme --period week --since 2026-06-01 --until 2026-06-20 --include-individuals 2>/dev/null)"
OUT3="$(printf '%s' "$ENV3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["out"])' 2>/dev/null)"
case "$OUT3" in *"-INDIVIDUALS-do-not-circulate.html") ok "individuals render has its own filename" ;;
  *) bad "individuals render has its own filename" "$OUT3" ;; esac
[ "$OUT3" != "$OUT1" ] && [ -f "$OUT1" ] && ok "the shareable render was not overwritten" \
  || bad "the shareable render was not overwritten"
grep -qi 'alice' "$OUT3" && ok "individuals render does name people (that is its purpose)" \
  || bad "individuals render names people"
grep -qi 'alice' "$OUT1" && bad "default render STILL has no names" "leaked" \
  || ok "default render STILL has no names"
# The one thing no flag may ever unlock.
eq "no per-person throughput even with the flag" \
   "$(DATA_OF "$OUT3" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sorted(set().union(*[set(r) for r in d["individuals"]["adoption"]])) if d["individuals"]["adoption"] else [])')" \
   "['first_agent_key', 'first_ai_trailer_at', 'login']"

echo
echo "== 7. the page actually renders (JS executes, not just bytes on disk) =="
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/render.js" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const dataText = html.match(/id="dxm-data">\s*([\s\S]*?)\s*<\/script>/)[1];
const js = html.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
let appHTML = null;
const els = {
  'dxm-data': { textContent: dataText },
  'app': { set innerHTML(v) { appHTML = v; }, set textContent(v) { appHTML = 'THREW:' + v; } },
  'themebtn': { addEventListener() {} },
};
global.document = { getElementById: id => els[id] || null,
                    documentElement: { getAttribute: () => null, setAttribute() {} } };
global.window = { matchMedia: () => ({ matches: false }) };
global.localStorage = { getItem: () => null, setItem() {} };
new Function(js)();
if (appHTML === null) { console.log('EMPTY'); process.exit(0); }
if (String(appHTML).startsWith('THREW:')) { console.log('THREW'); process.exit(0); }
const need = ['How every commit is attributed', 'Executor: UNKNOWN', 'Leverage',
              'FLOOR', 'no identifiable steerer', 'never counted as human'];
const missing = need.filter(s => !appHTML.includes(s));
console.log(missing.length ? 'MISSING:' + missing.join('|') : 'OK:' + appHTML.length);
JS
  eq "default render produces HTML and the pair model is on the page" \
     "$(node "$TMP/render.js" "$OUT1" | cut -d: -f1)" "OK"
  eq "individuals render produces HTML too" \
     "$(node "$TMP/render.js" "$OUT3" | cut -d: -f1)" "OK"
else
  echo "SKIP  node not available — cannot execute the template's JavaScript"
fi

echo
echo "== 8. refusals =="
eq "no orphan agg_metric rows (every number has a catalog row)" \
   "$(sqlite3 "$DXM_HOME/dxm.db" "SELECT COUNT(*) FROM agg_metric m LEFT JOIN metric_catalog c USING(metric_key) WHERE c.metric_key IS NULL")" "0"
eq "no dangling runs" \
   "$(sqlite3 "$DXM_HOME/dxm.db" "SELECT COUNT(*) FROM runs WHERE status='running'")" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
