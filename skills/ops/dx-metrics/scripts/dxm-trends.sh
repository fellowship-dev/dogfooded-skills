#!/usr/bin/env bash
# dxm-trends.sh — weekly trend charts for one org, as ONE self-contained HTML
# file with NO JavaScript, no chart library, no CDN, no network of any kind.
#
# WHY NO JAVASCRIPT. The sibling dashboard builds its charts in the browser from
# inlined JSON. One render-time exception there produces a blank page while the
# byte count, the file size and the ok:true envelope all still look healthy —
# nothing in the shell can catch it. Here every <svg> is emitted server-side by
# awk and every tooltip is a native SVG <title>. If the file exists, the charts
# are in it. It is also trivially CSP-safe.
#
# WHAT IT DRAWS — six weekly series, every bucket labelled with its ISO week:
#   per repo   : commits/week, merged PRs/week          (default render)
#   per org    : multi-line commit ratio/week           (default render)
#   per person : commits/week, merged PRs/week,
#                multi-line commit ratio/week           (--include-individuals ONLY)
#
# THE MULTI-LINE RATIO IS AN AGENTIC-USAGE PROXY, NOT "AI USAGE".
# It is the share of commits whose message has a real body after the subject
# line and every trailer-shaped line are stripped (commits.has_body, populated
# by scripts/dxm-backfill-body.sh). It detects AGENTIC use, where the agent
# writes the commit message. It is blind to ASSISTIVE use — Copilot
# autocomplete, pasted ChatGPT output — where the human writes the message.
# Its precision collapses when the underlying rate is low, so the page publishes
# the declared-trailer BASE RATE on the same axes, every time, and never shows
# one without the other.
#
# PRIVACY — binding, see CONTRACT.md §8. The default render contains per-repo
# and per-org series ONLY. Per-person series exist solely behind
# --include-individuals and are written to a DIFFERENT filename. Before writing
# a default render this script greps its own output for every login, every
# display name and anything email-shaped in the database, and REFUSES to write
# the file on a hit it cannot attribute to an in-scope repository name.
#
# OWNERSHIP: scripts/dxm-trends.sh + templates/trends.html. Reads only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"

TEMPLATE="$DXM_SKILL_DIR/templates/trends.html"
SELF="$(basename "$0")"

usage() {
  cat <<'EOF'
dxm-trends.sh — weekly trend charts for one org as a single self-contained HTML
file. No JavaScript, no chart library, no CDN, no network.

USAGE
  dxm-trends.sh --org OWNER [options]

WINDOW
  --since YYYY-MM-DD    First week. Default: 104 weeks (2 years) back.
  --until YYYY-MM-DD    Last week.  Default: today, UTC.
  --compare-weeks N     Size of each half of the change table. Default 26.
                        Only COMPLETE weeks are ever compared.

SHAPE
  --top N               Panels to draw per small-multiple chart, by volume.
                        Default 12. The remainder is drawn as one combined
                        panel and its size is stated.
  --min-series N        Drop a repo/person with fewer than N units in the whole
                        window from its own panel (it still counts in the
                        combined panel and in every org total). Default 5.

OUTPUT
  --out PATH            Write here. Default:
                        $DXM_OUT/dx-trends-<org>-week-<until>[-INDIVIDUALS-do-not-circulate].html
  --dry-run             Do everything except write the file.
  --json                Accepted and ignored; JSON on stdout is the only mode.

PRIVACY
  --include-individuals SENSITIVE, opt-in. Adds the three PER-PERSON series and
                        writes to a separate '-INDIVIDUALS-do-not-circulate'
                        file that can never overwrite the shareable one.
                        Without it the render is per-repo and per-org only and
                        is verified to contain no personal data before it is
                        written.
  --min-cohort N        Below this many people, per-person charts are withheld
                        even with the opt-in flag. Default 3.

  --help                This text.

PREREQUISITE
  commits.has_body must be populated:  scripts/dxm-backfill-body.sh
  This script refuses to render the multi-line series otherwise, rather than
  drawing zeroes for "not measured".

OUTPUT CONTRACT
  Exactly one line of JSON on stdout. Everything else on stderr.
  Exit 0 ok · 1 usage · 2 precondition · 3 partial · 4 data error.

THIS OUTPUT IS SENSITIVE AND MUST NOT BE USED TO MEASURE INDIVIDUAL
PERFORMANCE OR TO FEED PERFORMANCE EVALUATIONS.
EOF
}

ORG=""; SINCE=""; UNTIL=""; OUT_PATH=""; DRY_RUN=0
INCLUDE_INDIVIDUALS=0; MIN_COHORT=3; TOP_N=12; MIN_SERIES=5; CMP_WEEKS=26

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)             usage; exit 0 ;;
    --org)                 ORG="${2:-}";        shift 2 ;;
    --since)               SINCE="${2:-}";      shift 2 ;;
    --until)               UNTIL="${2:-}";      shift 2 ;;
    --out)                 OUT_PATH="${2:-}";   shift 2 ;;
    --top)                 TOP_N="${2:-}";      shift 2 ;;
    --min-series)          MIN_SERIES="${2:-}"; shift 2 ;;
    --compare-weeks)       CMP_WEEKS="${2:-}";  shift 2 ;;
    --min-cohort)          MIN_COHORT="${2:-}"; shift 2 ;;
    --include-individuals) INCLUDE_INDIVIDUALS=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --json)                shift ;;
    *) dxm_die "unknown flag: $1 (try --help)" 1 ;;
  esac
done

[ -n "$ORG" ] || dxm_die "--org OWNER is required (try --help)" 1
case "$ORG" in */*) dxm_die "--org takes an owner, not owner/name: $ORG" 1 ;; esac
for n in "$TOP_N" "$MIN_SERIES" "$CMP_WEEKS" "$MIN_COHORT"; do
  case "$n" in ''|*[!0-9]*) dxm_die "numeric flags must be non-negative integers, got: $n" 1 ;; esac
done
for d in "$SINCE" "$UNTIL"; do
  [ -z "$d" ] && continue
  case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) dxm_die "dates must be YYYY-MM-DD, got: $d" 1 ;; esac
done
[ -f "$TEMPLATE" ] || dxm_die "template not found: $TEMPLATE" 2

dxm_require_cmd sqlite3 awk
dxm_init_db
RUN_ID="$(dxm_run_start "$SELF" "$*" "")"
trap 'dxm_run_trap '"$RUN_ID"' $?' EXIT
fail() { dxm_run_finish "$RUN_ID" error "$1" "$2"; dxm_emit false "$SELF" "$RUN_ID" "\"error\":$(dxm_json_str "$2")"; exit "$1"; }

QORG="$(dxm_q "$ORG")"

N_REPOS="$(dxm_sql1 "SELECT COUNT(*) FROM repos WHERE owner=$QORG;")"
[ "${N_REPOS:-0}" -gt 0 ] || fail 4 "org '$ORG' has no repos in the database — nothing to chart (an empty org renders a complete, confident, entirely empty page; that is refused)"

# ---------------------------------------------------------------------------
# Preconditions on the multi-line signal. "Not measured" and "measured as zero"
# must never look the same, so an unpopulated column is a hard stop.
# ---------------------------------------------------------------------------
HB_COL="$(dxm_sql1 "SELECT COUNT(*) FROM pragma_table_info('commits') WHERE name='has_body';")"
[ "${HB_COL:-0}" = "1" ] || fail 2 "commits.has_body does not exist; run scripts/dxm-backfill-body.sh first"
HB_MISSING="$(dxm_sql1 "SELECT COUNT(*) FROM commits c JOIN repos r ON r.repo_id=c.repo_id
                         WHERE r.owner=$QORG AND c.has_body IS NULL;")"
HB_TOTAL="$(dxm_sql1 "SELECT COUNT(*) FROM commits c JOIN repos r ON r.repo_id=c.repo_id WHERE r.owner=$QORG;")"
HB_HAVE=$(( ${HB_TOTAL:-0} - ${HB_MISSING:-0} ))
[ "$HB_HAVE" -gt 0 ] || fail 2 "no commit in org '$ORG' has has_body populated; run scripts/dxm-backfill-body.sh first"

# ---------------------------------------------------------------------------
# Window. All date maths in SQLite: macOS date(1) has no -d.
# ---------------------------------------------------------------------------
[ -n "$UNTIL" ] || UNTIL="$(dxm_sql1 "SELECT date('now');")"
[ -n "$SINCE" ] || SINCE="$(dxm_sql1 "SELECT date('now','-728 days');")"   # 104 weeks; SQLite has no 'weeks' modifier
QSINCE="$(dxm_q "$SINCE")"; QUNTIL="$(dxm_q "$UNTIL")"
W_FIRST="$(dxm_sql1 "SELECT date($QSINCE,'-6 days','weekday 1');")"
W_LAST="$(dxm_sql1  "SELECT date($QUNTIL,'-6 days','weekday 1');")"
W_CUR="$(dxm_sql1   "SELECT date('now','-6 days','weekday 1');")"
[ "$W_FIRST" \< "$W_LAST" ] || [ "$W_FIRST" = "$W_LAST" ] || fail 1 "--since ($SINCE) is after --until ($UNTIL)"
QWF="$(dxm_q "$W_FIRST")"; QWL="$(dxm_q "$W_LAST")"; QWC="$(dxm_q "$W_CUR")"

# ISO-8601 week label for a Monday, e.g. 2026-W33. Derived from the THURSDAY of
# that week, which is the ISO rule and the only way the year is right at a year
# boundary: 2019-12-30 is 2020-W01 and 2020-12-28 is 2020-W53. Verified against
# both, plus 2015-W53 and 2021-W01.
iso_expr() { printf "strftime('%%Y', date(%s,'+3 days')) || '-W' || printf('%%02d', (CAST(strftime('%%j', date(%s,'+3 days')) AS INTEGER)-1)/7 + 1)" "$1" "$1"; }
ISO_W="$(iso_expr w)"

# Population rules, written once and spliced everywhere. Merge commits are not
# authorship; machine-steered executions are the mandatory bot exclusion of
# CONTRACT.md decision 10. Unknown steerers STAY IN — they really happened.
C_POP="c.is_merge = 0 AND c.steerer_state <> 'machine'"
C_WIN="c.week_start >= $QWF AND c.week_start <= $QWL"
C_SCOPE="c.owner = $QORG"
P_POP="p.state = 'MERGED' AND p.merged_at IS NOT NULL AND p.steerer_state <> 'machine'"
P_WIN="p.merged_week_start >= $QWF AND p.merged_week_start <= $QWL"
P_SCOPE="p.owner = $QORG"

dxm_log "org=$ORG weeks=$W_FIRST..$W_LAST current=$W_CUR repos=$N_REPOS has_body=$HB_HAVE/$HB_TOTAL"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dxm-trends.XXXXXX")"
trap 'dxm_rc=$?; rm -rf "$TMPD"; dxm_run_trap '"$RUN_ID"' "$dxm_rc"' EXIT

# ---------------------------------------------------------------------------
# The x domain. Every panel on the page shares it, so two charts can never
# disagree about which week a point is, and a series with a gap keeps its
# position instead of sliding left.
# ---------------------------------------------------------------------------
DOMAIN="$TMPD/domain.tsv"
dxm_sql "
WITH RECURSIVE wk(w) AS (
  SELECT $QWF UNION ALL SELECT date(w,'+7 days') FROM wk WHERE w < $QWL
)
SELECT w || char(9) || ($ISO_W) || char(9) || (CASE WHEN w >= $QWC THEN 1 ELSE 0 END) FROM wk ORDER BY w;" > "$DOMAIN"
N_WEEKS="$(wc -l < "$DOMAIN" | tr -d ' ')"
[ "${N_WEEKS:-0}" -gt 1 ] || fail 4 "window covers $N_WEEKS week(s); widen --since"

# Complete-week bounds for every comparison and every headline. The in-progress
# week is drawn at the end of a line, hollow, and is never a driver.
CMP_B_END="$(dxm_sql1   "SELECT date($QWC,'-7 days');")"                       # last complete week
CMP_B_START="$(dxm_sql1 "SELECT date($QWC,'-' || (7*$CMP_WEEKS) || ' days');")"
CMP_A_END="$(dxm_sql1   "SELECT date($(dxm_q "$CMP_B_START"),'-7 days');")"
CMP_A_START="$(dxm_sql1 "SELECT date($(dxm_q "$CMP_B_START"),'-' || (7*$CMP_WEEKS) || ' days');")"
QBA="$(dxm_q "$CMP_A_START")"; QBB="$(dxm_q "$CMP_A_END")"
QCA="$(dxm_q "$CMP_B_START")"; QCB="$(dxm_q "$CMP_B_END")"
ISO_A_START="$(dxm_sql1 "SELECT $(iso_expr "$QBA");")"
ISO_A_END="$(dxm_sql1   "SELECT $(iso_expr "$QBB");")"
ISO_B_START="$(dxm_sql1 "SELECT $(iso_expr "$QCA");")"
ISO_B_END="$(dxm_sql1   "SELECT $(iso_expr "$QCB");")"
ISO_FIRST="$(dxm_sql1   "SELECT $(iso_expr "$QWF");")"
ISO_LAST="$(dxm_sql1    "SELECT $(iso_expr "$QWL");")"
ISO_CUR="$(dxm_sql1     "SELECT $(iso_expr "$QWC");")"

# ===========================================================================
# The SVG renderer. One awk program, used by every chart on the page.
# ===========================================================================
# Reads three files, in this order:
#   domain.tsv  week_start \t iso \t is_current
#   meta.tsv    panel \t title \t subtitle          (also fixes panel ORDER)
#   data.tsv    panel \t series_idx \t series_name \t week_start \t value
#
# Emits one <div class="panel"> per meta row. Every panel carries:
#   * a labelled y axis (0, mid, max) with its unit,
#   * a labelled x axis in ISO weeks — never an unlabelled bar again,
#   * a native <title> on every mark: series, ISO week, value,
#   * the in-progress week drawn hollow/dashed and excluded from the totals.
# ===========================================================================
RENDER_AWK="$TMPD/render.awk"
cat > "$RENDER_AWK" <<'AWKEOF'
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
function nice(v) { return (v == int(v)) ? sprintf("%d", int(v)) : sprintf("%.1f", v) }
function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }

BEGIN {
  FS = "\t"
  # T leaves room for the y-axis unit caption ABOVE the plot area. At T=10 the
  # caption sat on top of the topmost tick label and both were unreadable.
  L = (small ? 40 : 48); R = (small ? 10 : 12); T = 20; B = (small ? 34 : 40)
  W = (small ? 336 : 700); H = (small ? 148 : 210)
  PW = W - L - R; PH = H - T - B
  nd = 0; np = 0
}

FNR == 1 && FILENAME != prevfile { stage++; prevfile = FILENAME }

stage == 1 { nd++; dw[nd] = $1; diso[nd] = $2; dcur[nd] = ($3 + 0); idx[$1] = nd; next }
stage == 2 { np++; pan[np] = $1; ptitle[np] = $2; psub[np] = $3; next }
stage == 3 {
  i = idx[$4]
  if (i == "") next
  key = $1 SUBSEP ($2 + 0) SUBSEP i
  val[key] = $5 + 0
  sname[$1 SUBSEP ($2 + 0)] = $3
  if (($2 + 0) > maxs[$1]) maxs[$1] = ($2 + 0)
  next
}

END {
  for (p = 1; p <= np; p++) {
    pn = pan[p]
    # ---- y domain -------------------------------------------------------
    if (ymax > 0) { top = ymax }
    else {
      top = 0
      for (s = 0; s <= maxs[pn]; s++)
        for (i = 1; i <= nd; i++) { k = pn SUBSEP s SUBSEP i; if (k in val && val[k] > top) top = val[k] }
      if (top <= 0) top = 1
      # Round counts up to something a reader can divide in their head.
      if (unit != "%") { mag = 1; while (top / mag > 10) mag *= 10; top = ceil(top / mag) * mag }
    }

    printf "<div class=\"panel\">\n"
    printf "<div class=\"ttl\">%s</div>\n", esc(ptitle[p])
    if (psub[p] != "") printf "<div class=\"meta\">%s</div>\n", esc(psub[p])
    printf "<svg viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"%s, by ISO calendar week\">\n", W, H, esc(ptitle[p])

    # ---- gridlines + y labels (0, mid, top). ALWAYS labelled. ------------
    for (g = 0; g <= 2; g++) {
      yv = top * g / 2
      yy = T + PH - (PH * g / 2)
      printf "<line class=\"grid\" x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\"/>\n", L, yy, L + PW, yy
      printf "<text class=\"ylab\" x=\"%d\" y=\"%.1f\" text-anchor=\"end\">%s%s</text>\n", L - 5, yy + 3, nice(yv), (unit == "%" ? "%" : "")
    }
    printf "<line class=\"axis\" x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\"/>\n", L, T + PH, L + PW, T + PH

    # ---- x labels in ISO weeks. Sparse enough to stay legible, and the
    #      LAST week is always labelled so the reader knows where "now" is.
    step = ceil(nd / (small ? 4 : 7)); if (step < 1) step = 1
    for (i = 1; i <= nd; i++) {
      if (i % step != 1 && i != nd && step > 1) continue
      if (step > 1 && i != nd && (nd - i) < step * 0.6) continue
      xx = L + (i - 0.5) * PW / nd
      printf "<text class=\"xlab\" x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%s</text>\n", xx, T + PH + 14, diso[i]
    }
    printf "<text class=\"axtitle\" x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">ISO calendar week</text>\n", L + PW / 2, H - 4
    printf "<text class=\"axtitle\" x=\"%d\" y=\"%d\" text-anchor=\"start\">%s</text>\n", 2, 9, esc(yunit)

    # ---- marks ----------------------------------------------------------
    if (mode == "bars") {
      bw = PW / nd - 1; if (bw < 1) bw = 1
      for (i = 1; i <= nd; i++) {
        k = pn SUBSEP 0 SUBSEP i
        v = (k in val) ? val[k] : 0
        hgt = (v / top) * PH; if (hgt < 0) hgt = 0
        xx = L + (i - 1) * PW / nd + (PW / nd - bw) / 2
        cls = "bar" (barcls != "" ? " " barcls : "") (dcur[i] ? " partial" : "")
        tip = sprintf("%s — %s — %s %s%s", ptitle[p], diso[i], nice(v), yunit, (dcur[i] ? " (week still in progress — not a complete bucket)" : ""))
        if (v > 0 || dcur[i])
          printf "<rect class=\"%s\" x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\"><title>%s</title></rect>\n",
                 cls, xx, T + PH - hgt, bw, (hgt < 0.8 ? 0.8 : hgt), esc(tip)
        # A transparent full-height hit area so hovering an empty or tiny week
        # still names the week and its zero, instead of saying nothing.
        printf "<rect class=\"hit\" x=\"%.2f\" y=\"%d\" width=\"%.2f\" height=\"%d\"><title>%s</title></rect>\n",
               L + (i - 1) * PW / nd, T, PW / nd, PH, esc(tip)
      }
    } else {
      for (s = 0; s <= maxs[pn]; s++) {
        pts = ""; nseen = 0
        for (i = 1; i <= nd; i++) {
          k = pn SUBSEP s SUBSEP i
          if (!(k in val)) continue
          if (dcur[i]) continue                       # the in-progress week never joins the line
          xx = L + (i - 0.5) * PW / nd
          yy = T + PH - (val[k] / top) * PH
          pts = pts sprintf("%.1f,%.1f ", xx, yy); nseen++
        }
        if (nseen > 1) printf "<polyline class=\"s%d\" points=\"%s\"/>\n", s, pts
        for (i = 1; i <= nd; i++) {
          k = pn SUBSEP s SUBSEP i
          if (!(k in val)) continue
          xx = L + (i - 0.5) * PW / nd
          yy = T + PH - (val[k] / top) * PH
          tip = sprintf("%s — %s — %s%s%s", sname[pn SUBSEP s], diso[i], nice(val[k]), (unit == "%" ? "%" : " " yunit),
                        (dcur[i] ? " (week still in progress — shown hollow, excluded from every comparison)" : ""))
          printf "<circle class=\"s%d%s\" cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\"><title>%s</title></circle>\n",
                 s, (dcur[i] ? " partial" : ""), xx, yy, (small ? 1.9 : 2.3), esc(tip)
        }
      }
    }
    printf "</svg>\n</div>\n"
  }
}
AWKEOF

# render_chart <mode:bars|lines> <small:0|1> <ymax:0=auto|N> <unit> <yunit> <barcls> <meta.tsv> <data.tsv>
render_chart() {
  awk -v mode="$1" -v small="$2" -v ymax="$3" -v unit="$4" -v yunit="$5" -v barcls="$6" \
      -f "$RENDER_AWK" "$DOMAIN" "$7" "$8"
}

# ===========================================================================
# Data. Every query reads the views, so bucketing, bot exclusion and AI
# attribution stay defined exactly once (CONTRACT.md §10).
# ===========================================================================

# ---- 3. commits per repo per week -----------------------------------------
dxm_sql "SELECT c.repo_full_name || char(9) || '0' || char(9) || c.repo_full_name || char(9) || c.week_start || char(9) || COUNT(*)
           FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN GROUP BY c.repo_full_name, c.week_start;" > "$TMPD/repo_commits.raw"

# ---- 4. merged PRs per repo per week --------------------------------------
dxm_sql "SELECT p.repo_full_name || char(9) || '0' || char(9) || p.repo_full_name || char(9) || p.merged_week_start || char(9) || COUNT(*)
           FROM v_prs_enriched p WHERE $P_SCOPE AND $P_POP AND $P_WIN GROUP BY p.repo_full_name, p.merged_week_start;" > "$TMPD/repo_prs.raw"

# ---- 1/2/5. per person — computed ALWAYS so the cohort size is knowable,
#      rendered ONLY behind the opt-in flag.
dxm_sql "SELECT c.author_login || char(9) || '0' || char(9) || c.author_login || char(9) || c.week_start || char(9) || COUNT(*)
           FROM v_commits_enriched c
          WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.steerer_state='known' AND c.author_login IS NOT NULL
          GROUP BY c.author_login, c.week_start;" > "$TMPD/person_commits.raw"
dxm_sql "SELECT p.author_login || char(9) || '0' || char(9) || p.author_login || char(9) || p.merged_week_start || char(9) || COUNT(*)
           FROM v_prs_enriched p
          WHERE $P_SCOPE AND $P_POP AND $P_WIN AND p.steerer_state='known' AND p.author_login IS NOT NULL
          GROUP BY p.author_login, p.merged_week_start;" > "$TMPD/person_prs.raw"

# ---- 6. multi-line ratio per org per week, WITH the declared-trailer base
#      rate on the same axes. Series 0 = multi-line, series 1 = base rate.
#      has_body IS NULL is excluded from the denominator: not measurable is not
#      the same fact as measured-and-false.
dxm_sql "
  SELECT '__org__' || char(9) || '0' || char(9) || 'Multi-line commit ratio (agentic proxy)' || char(9) || c.week_start || char(9) ||
         printf('%.2f', 100.0*SUM(c.has_body)/COUNT(*))
    FROM v_commits_enriched c
   WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL
   GROUP BY c.week_start
  UNION ALL
  SELECT '__org__' || char(9) || '1' || char(9) || 'Declared AI trailer rate (base rate, a FLOOR)' || char(9) || c.week_start || char(9) ||
         printf('%.2f', 100.0*SUM(c.is_ai_assisted)/COUNT(*))
    FROM v_commits_enriched c
   WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL
   GROUP BY c.week_start;" > "$TMPD/org_ratio.data"

dxm_sql "
  SELECT c.author_login || char(9) || '0' || char(9) || 'Multi-line ratio' || char(9) || c.week_start || char(9) ||
         printf('%.2f', 100.0*SUM(c.has_body)/COUNT(*))
    FROM v_commits_enriched c
   WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL AND c.steerer_state='known' AND c.author_login IS NOT NULL
   GROUP BY c.author_login, c.week_start
  UNION ALL
  SELECT c.author_login || char(9) || '1' || char(9) || 'Declared AI trailer rate (base rate)' || char(9) || c.week_start || char(9) ||
         printf('%.2f', 100.0*SUM(c.is_ai_assisted)/COUNT(*))
    FROM v_commits_enriched c
   WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL AND c.steerer_state='known' AND c.author_login IS NOT NULL
   GROUP BY c.author_login, c.week_start;" > "$TMPD/person_ratio.data"

# ---- org totals (context for reading the per-repo panels) -----------------
dxm_sql "SELECT '__org__' || char(9) || '0' || char(9) || 'commits' || char(9) || c.week_start || char(9) || COUNT(*)
           FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN GROUP BY c.week_start;" > "$TMPD/org_commits.data"
dxm_sql "SELECT '__org__' || char(9) || '0' || char(9) || 'merged PRs' || char(9) || p.merged_week_start || char(9) || COUNT(*)
           FROM v_prs_enriched p WHERE $P_SCOPE AND $P_POP AND $P_WIN GROUP BY p.merged_week_start;" > "$TMPD/org_prs.data"

# ---------------------------------------------------------------------------
# Panel selection: top N by volume, everything else folded into ONE combined
# panel whose size is stated. A chart with 28 unreadable panels is not a chart.
# The fold is additive, so no unit is ever dropped from the org totals.
# ---------------------------------------------------------------------------
# fold_panels <raw> <meta_out> <data_out> <combined_label> -> echoes "kept folded folded_units"
fold_panels() {
  local raw="$1" meta="$2" data="$3" combined="$4"
  awk -F'\t' -v top="$TOP_N" -v minser="$MIN_SERIES" -v cur="$W_CUR" -v combined="$combined" \
      -v metaf="$meta" -v dataf="$data" '
    { tot[$1] += $5; if ($4 != cur) comp[$1] += $5; rows[NR] = $0 }
    END {
      n = 0
      for (p in tot) { order[++n] = p }
      # Rank by COMPLETE-week volume only; a half-finished week must not decide
      # which panels a reader gets to see.
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
        if (comp[order[j]] > comp[order[i]] || (comp[order[j]] == comp[order[i]] && order[j] < order[i])) { t = order[i]; order[i] = order[j]; order[j] = t }
      kept = 0
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (kept < top && comp[p] >= minser) { keep[p] = 1; kept++ }
      }
      folded = 0; foldedunits = 0
      for (i = 1; i <= n; i++) { p = order[i]; if (!(p in keep)) { folded++; foldedunits += comp[p] } }
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (!(p in keep)) continue
        printf "%s\t%s\t%s\n", p, p, sprintf("%d over complete weeks", comp[p]) > metaf
      }
      if (folded > 0)
        printf "%s\t%s\t%s\n", "__other__", sprintf("%s (%d)", combined, folded),
               sprintf("%d over complete weeks", foldedunits) > metaf
      for (r = 1; r <= NR; r++) {
        split(rows[r], f, "\t")
        p = (f[1] in keep) ? f[1] : "__other__"
        if (p == "__other__" && folded == 0) continue
        agg[p SUBSEP f[4]] += f[5]
      }
      for (k in agg) { split(k, f, SUBSEP); printf "%s\t0\t%s\t%s\t%s\n", f[1], f[1], f[2], agg[k] > dataf }
      printf "%d %d %d\n", kept, folded, foldedunits
    }' "$raw"
}

: > "$TMPD/repo_commits.meta"; : > "$TMPD/repo_commits.data"
: > "$TMPD/repo_prs.meta";     : > "$TMPD/repo_prs.data"
RC_FOLD="$(fold_panels "$TMPD/repo_commits.raw" "$TMPD/repo_commits.meta" "$TMPD/repo_commits.data" "all other repositories, combined")"
RP_FOLD="$(fold_panels "$TMPD/repo_prs.raw"     "$TMPD/repo_prs.meta"     "$TMPD/repo_prs.data"     "all other repositories, combined")"

COHORT="$(dxm_sql1 "SELECT COUNT(DISTINCT c.author_login) FROM v_commits_enriched c
                     WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.steerer_state='known' AND c.author_login IS NOT NULL;")"
COHORT="${COHORT:-0}"

if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
  : > "$TMPD/person_commits.meta"; : > "$TMPD/person_commits.data"
  : > "$TMPD/person_prs.meta";     : > "$TMPD/person_prs.data"
  PC_FOLD="$(fold_panels "$TMPD/person_commits.raw" "$TMPD/person_commits.meta" "$TMPD/person_commits.data" "all other people, combined")"
  PP_FOLD="$(fold_panels "$TMPD/person_prs.raw"     "$TMPD/person_prs.meta"     "$TMPD/person_prs.data"     "all other people, combined")"
  # The ratio panels are per person and are NOT folded — an aggregate ratio over
  # "everyone else" is a different quantity, not a bigger version of the same one.
  awk -F'\t' -v minser="$MIN_SERIES" '
    NR==FNR { if ($4 != "") keep[$1] = 1; next }
    { print }' /dev/null "$TMPD/person_ratio.data" > "$TMPD/person_ratio.data.all"
  cut -f1 "$TMPD/person_commits.meta" | grep -v '^__other__$' > "$TMPD/person_ratio.keep" || true
  awk -F'\t' 'NR==FNR { k[$1]=1; next } ($1 in k)' "$TMPD/person_ratio.keep" "$TMPD/person_ratio.data.all" > "$TMPD/person_ratio.data"
  : > "$TMPD/person_ratio.meta"
  while IFS= read -r lg; do
    [ -n "$lg" ] || continue
    row="$(dxm_sql1 "SELECT printf('%d commits · %.1f%% multi-line · %.1f%% trailered (complete weeks)',
                        COUNT(*), 100.0*SUM(c.has_body)/COUNT(*), 100.0*SUM(c.is_ai_assisted)/COUNT(*))
                       FROM v_commits_enriched c
                      WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL
                        AND c.week_start < $QWC AND c.author_login=$(dxm_q "$lg");")"
    printf '%s\t%s\t%s\n' "$lg" "$lg" "$row" >> "$TMPD/person_ratio.meta"
  done < "$TMPD/person_ratio.keep"
fi

# ---------------------------------------------------------------------------
# Change tables. COMPLETE WEEKS ONLY, both halves, stated on the table.
# ---------------------------------------------------------------------------
change_table() {  # change_table <raw_tsv> <unit_noun>
  local raw="$1" noun="$2"
  awk -F'\t' -v a0="$CMP_A_START" -v a1="$CMP_A_END" -v b0="$CMP_B_START" -v b1="$CMP_B_END" -v noun="$noun" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); return s }
    { if ($4 >= a0 && $4 <= a1) A[$1] += $5; if ($4 >= b0 && $4 <= b1) B[$1] += $5; seen[$1] = 1 }
    END {
      n = 0; for (p in seen) if (A[p] + B[p] > 0) order[++n] = p
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
        if (B[order[j]] > B[order[i]]) { t = order[i]; order[i] = order[j]; order[j] = t }
      printf "<div class=\"tablewrap\"><table><thead><tr><th>series</th><th>earlier %s</th><th>later %s</th><th>change</th></tr></thead><tbody>\n", noun, noun
      for (i = 1; i <= n; i++) {
        p = order[i]; a = A[p] + 0; b = B[p] + 0
        if (a == 0 && b == 0) continue
        ch = (a == 0) ? "new" : sprintf("%.2f×", b / a)
        printf "<tr><td>%s</td><td>%d</td><td>%d</td><td>%s</td></tr>\n", esc(p), a, b, ch
      }
      printf "</tbody></table></div>\n"
    }' "$raw"
}

# ---------------------------------------------------------------------------
# Scalars for the header.
# ---------------------------------------------------------------------------
S_COMMITS="$(dxm_sql1 "SELECT COUNT(*) FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.week_start < $QWC;")"
S_PRS="$(dxm_sql1     "SELECT COUNT(*) FROM v_prs_enriched p     WHERE $P_SCOPE AND $P_POP AND $P_WIN AND p.merged_week_start < $QWC;")"
S_MACHINE="$(dxm_sql1 "SELECT COUNT(*) FROM v_commits_enriched c WHERE $C_SCOPE AND c.is_merge=0 AND c.steerer_state='machine' AND $C_WIN AND c.week_start < $QWC;")"
S_UNKNOWN="$(dxm_sql1 "SELECT COUNT(*) FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.steerer_state='unknown' AND c.week_start < $QWC;")"
S_UNK_PCT="$(dxm_sql1 "SELECT printf('%.1f', 100.0*SUM(c.steerer_state='unknown')/NULLIF(COUNT(*),0))
                         FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.week_start < $QWC;")"
S_ML_PCT="$(dxm_sql1  "SELECT printf('%.1f', 100.0*SUM(c.has_body)/NULLIF(COUNT(*),0))
                         FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL AND c.week_start < $QWC;")"
S_AI_PCT="$(dxm_sql1  "SELECT printf('%.1f', 100.0*SUM(c.is_ai_assisted)/NULLIF(COUNT(*),0))
                         FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL AND c.week_start < $QWC;")"
S_UNMEAS="$(dxm_sql1  "SELECT COUNT(*) FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NULL;")"
for v in S_COMMITS S_PRS S_MACHINE S_UNKNOWN S_UNMEAS; do eval "$v=\${$v:-0}"; done
for v in S_UNK_PCT S_ML_PCT S_AI_PCT; do eval "[ -n \"\$$v\" ] || $v='—'"; done

# Precision / recall of multi-line against the declared trailer, on THIS org,
# over complete weeks. Published rather than asserted: the whole point of the
# proxy is that the reader can see how well it tracks the thing it stands in for.
read -r PR_TP PR_ML PR_AI PR_N <<EOF
$(dxm_sql "SELECT SUM(c.has_body=1 AND c.is_ai_assisted=1) || ' ' || SUM(c.has_body=1) || ' ' || SUM(c.is_ai_assisted=1) || ' ' || COUNT(*)
             FROM v_commits_enriched c WHERE $C_SCOPE AND $C_POP AND $C_WIN AND c.has_body IS NOT NULL AND c.week_start < $QWC;")
EOF
PREC="—"; RECALL="—"
[ "${PR_ML:-0}" -gt 0 ] && PREC="$(dxm_sql1 "SELECT printf('%.1f', 100.0*$PR_TP/$PR_ML);")"
[ "${PR_AI:-0}" -gt 0 ] && RECALL="$(dxm_sql1 "SELECT printf('%.1f', 100.0*$PR_TP/$PR_AI);")"

# ===========================================================================
# Assemble the page. The boilerplate is said ONCE, at the top, and no card
# repeats it — a notice printed on every card is a notice nobody reads.
# ===========================================================================
BODY="$TMPD/body.html"
{
  if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
    printf '<h1>%s — weekly trends (INDIVIDUALS — DO NOT CIRCULATE)</h1>\n' "$ORG"
  else
    printf '<h1>%s — weekly trends</h1>\n' "$ORG"
  fi
  printf '<div class="sub">%s → %s · %s weeks · generated %s · dx-metrics %s</div>\n' \
    "$ISO_FIRST" "$ISO_LAST" "$N_WEEKS" "$(dxm_utc_now)" "$DXM_SKILL_VERSION"

  printf '<div class="banner"><div class="t">Sensitive — not a performance measurement</div>'
  printf '<p>This page must <b>not</b> be used to measure individual performance or to feed a performance evaluation. A commit count is not a contribution, and cycle time is a property of a system rather than of a person.</p>'
  if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
    printf '<p><b>This is the individuals render.</b> It names people. It exists for exactly two legitimate purposes — ownership / bus-factor risk and AI-adoption timing — and it is not the version to circulate. The shareable render of the same window contains per-repository and per-organisation series only.</p>'
  else
    printf '<p>This render contains <b>per-repository and per-organisation series only</b>. It holds no logins, no names and no email addresses; that was verified against the database before this file was written.</p>'
  fi
  printf '</div>\n'

  # ---- the single, global boilerplate block ----
  printf '<div class="note"><dl>\n'
  printf '<dt>What is counted</dt><dd>Non-merge commits and merged pull requests, over <b>%s repositories</b> in <code>%s</code>. Machine-steered work is excluded throughout — that is the mandatory bot exclusion, and it removed <b>%s</b> commits from this window. Commits whose author could not be resolved to a person are <b>kept</b> (they really happened) and counted as <b>unknown steerer</b>: %s commits, %s%% of the window.</dd>\n' \
    "$N_REPOS" "$ORG" "$S_MACHINE" "$S_UNKNOWN" "$S_UNK_PCT"
  printf '<dt>Every bucket is an ISO calendar week</dt><dd>Weeks start Monday, UTC, and are labelled <code>YYYY-Www</code> (for example <code>%s</code>) on every axis and in every tooltip. Hover any mark for its exact week and value.</dd>\n' "$ISO_LAST"
  printf '<dt>The in-progress week</dt><dd><b>%s</b> is not over. It is drawn hollow and dashed at the right-hand edge of every chart, it is excluded from every total, every change table and every headline on this page, and no comparison uses it. A partial week that looks like a decline is the most common way a chart like this lies.</dd>\n' "$ISO_CUR"
  printf '<dt>Multi-line commit ratio is an AGENTIC-USAGE PROXY, not "AI usage"</dt><dd>It is the share of commits whose message still has content after the subject line and every trailer-shaped line are removed. Removing trailers is what stops the measurement being circular: <code>Co-Authored-By</code> is the line that defines the AI attribution it is being compared against. The proxy detects <b>agentic</b> use, where the agent writes the commit message. It is <b>blind to assistive</b> use — Copilot autocomplete, pasted ChatGPT — where the human writes the message. On this org, over complete weeks, it agrees with the declared trailer at <b>%s%% precision</b> and <b>%s%% recall</b> against a <b>%s%% base rate</b>. <b>Read those three together.</b> Precision of a proxy collapses as the base rate falls: the same rule that is ~91%% precise at a 74%% base rate is worth single-digit percent at a 2%% base rate, so the trailer rate is drawn on the same axes as the ratio, always, and neither is shown alone.</dd>\n' \
    "$PREC" "$RECALL" "$S_AI_PCT"
  printf '<dt>The declared trailer rate is a FLOOR</dt><dd>AI attribution comes from <code>Co-Authored-By</code> trailers and nothing else. A team using AI without them is invisible to it. The complement of the floor is <b>unknown executor</b> — never "human".</dd>\n'
  printf '<dt>Correlation only</dt><dd>There is no control group here and nothing else was held constant. A step in a series is a description of what happened, not a demonstration of what caused it.</dd>\n'
  printf '<dt>Not measurable</dt><dd>%s commits in this window have no reachable message in the cached clone and are excluded from the ratio denominators rather than counted as zero.</dd>\n' "$S_UNMEAS"
  printf '</dl></div>\n'

  # ================= org totals =================
  printf '<h2>Organisation totals</h2>\n'
  printf '<div class="card"><h3>Commits per week</h3>'
  printf '<p class="cap">Non-merge, machine-steered excluded. <b>%s commits</b> over the complete weeks of this window.</p>' "$S_COMMITS"
  printf '__ORGC__</div>\n'
  printf '<div class="card"><h3>Merged pull requests per week</h3>'
  printf '<p class="cap">Merged only; closed-unmerged is never throughput. Bot-authored PRs excluded. <b>%s merged PRs</b> over the complete weeks of this window.</p>' "$S_PRS"
  printf '__ORGP__</div>\n'

  # ================= multi-line ratio, org =================
  printf '<h2>Multi-line commit ratio — organisation</h2>\n'
  printf '<div class="card"><h3>Agentic-usage proxy vs its base rate</h3>'
  printf '<p class="cap">Over complete weeks: <b>%s%%</b> of commits are multi-line and <b>%s%%</b> carry a declared AI trailer. The two lines are on one pair of axes on purpose — the proxy is only readable next to the rate it stands in for.</p>' \
    "$S_ML_PCT" "$S_AI_PCT"
  printf '<div class="legend"><span class="ml"><i></i>multi-line ratio (agentic proxy)</span><span class="ai"><i></i>declared AI trailer rate (floor / base rate)</span><span class="pt"><i></i>week in progress — hollow, excluded</span></div>'
  printf '__ORGR__</div>\n'

  # ================= per repo =================
  printf '<h2>Commits per repository per week</h2>\n'
  printf '<div class="card"><p class="cap">One panel per repository, ranked by volume over complete weeks. <b>Each panel has its own y scale</b> — compare a panel with itself over time, not with the panel beside it. Repositories below the display threshold are summed into the combined panel; nothing is dropped from the organisation totals above.</p>'
  printf '__RCTABLE__</div>\n'
  printf '<div class="grid">__RCCHART__</div>\n'

  printf '<h2>Merged pull requests per repository per week</h2>\n'
  printf '<div class="card"><p class="cap">Same rules: own y scale per panel, complete weeks only in the table, remainder combined.</p>'
  printf '__RPTABLE__</div>\n'
  printf '<div class="grid">__RPCHART__</div>\n'

  if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
    if [ "$COHORT" -ge "$MIN_COHORT" ]; then
      printf '<h2>Commits per person per week</h2>\n'
      printf '<div class="card"><p class="cap">%s people with a resolvable identity contributed in this window. Own y scale per panel. <b>This is not a leaderboard and must not be read as one</b> — volume is not contribution, and the panels are here for ownership risk and adoption timing.</p>' "$COHORT"
      printf '__PCTABLE__</div>\n'
      printf '<div class="grid">__PCCHART__</div>\n'
      printf '<h2>Merged pull requests per person per week</h2>\n'
      printf '<div class="card"><p class="cap">Merged PRs authored by each person. Same caveat: not a leaderboard.</p>'
      printf '__PPTABLE__</div>\n'
      printf '<div class="grid">__PPCHART__</div>\n'
      printf '<h2>Multi-line commit ratio per person per week</h2>\n'
      printf '<div class="card"><p class="cap">The agentic-usage proxy per person, always drawn with that person&#39;s own declared-trailer base rate on the same axes. A person whose base rate is near zero has a proxy with near-zero precision; the two lines diverging is the thing to read, not the proxy on its own.</p>'
      printf '<div class="legend"><span class="ml"><i></i>multi-line ratio</span><span class="ai"><i></i>that person&#39;s declared trailer rate</span><span class="pt"><i></i>week in progress</span></div></div>\n'
      printf '<div class="grid">__PRCHART__</div>\n'
    else
      printf '<h2>Per-person series</h2>\n'
      printf '<div class="banner warn"><div class="t">Withheld</div><p>Only %s person/people with a resolvable identity contributed in this window, below the minimum cohort of %s. A per-person chart over that few people is an individual report wearing a grid, so it is not drawn — even with the opt-in flag.</p></div>\n' "$COHORT" "$MIN_COHORT"
    fi
  fi

  printf '<footer>dx-metrics %s · run %s · org %s · ISO weeks %s→%s · no JavaScript, no network, no external asset</footer>\n' \
    "$DXM_SKILL_VERSION" "$RUN_ID" "$ORG" "$ISO_FIRST" "$ISO_LAST"
} > "$BODY"

# ---- render every chart into its placeholder ------------------------------
printf '%s\t%s\t%s\n' "__org__" "All repositories" "commits per ISO week" > "$TMPD/org_commits.meta"
printf '%s\t%s\t%s\n' "__org__" "All repositories" "merged PRs per ISO week" > "$TMPD/org_prs.meta"
printf '%s\t%s\t%s\n' "__org__" "$ORG" "% of non-merge commits, complete weeks solid" > "$TMPD/org_ratio.meta"

render_chart bars  0 0   count   "commits"    ""   "$TMPD/org_commits.meta" "$TMPD/org_commits.data" > "$TMPD/c_orgc.html"
render_chart bars  0 0   count   "merged PRs" "pr" "$TMPD/org_prs.meta"     "$TMPD/org_prs.data"     > "$TMPD/c_orgp.html"
render_chart lines 0 100 %       "%"          ""   "$TMPD/org_ratio.meta"   "$TMPD/org_ratio.data"   > "$TMPD/c_orgr.html"
render_chart bars  1 0   count   "commits"    ""   "$TMPD/repo_commits.meta" "$TMPD/repo_commits.data" > "$TMPD/c_rc.html"
render_chart bars  1 0   count   "merged PRs" "pr" "$TMPD/repo_prs.meta"     "$TMPD/repo_prs.data"     > "$TMPD/c_rp.html"

CMP_CAP="<p class=\"cap\">Complete weeks only: <b>$ISO_A_START → $ISO_A_END</b> against <b>$ISO_B_START → $ISO_B_END</b> ($CMP_WEEKS weeks each). $ISO_CUR is in progress and is in neither half.</p>"
{ printf '%s' "$CMP_CAP"; change_table "$TMPD/repo_commits.raw" "commits"; } > "$TMPD/t_rc.html"
{ printf '%s' "$CMP_CAP"; change_table "$TMPD/repo_prs.raw"     "merged PRs"; } > "$TMPD/t_rp.html"

if [ "$INCLUDE_INDIVIDUALS" -eq 1 ] && [ "$COHORT" -ge "$MIN_COHORT" ]; then
  render_chart bars  1 0   count "commits"    ""   "$TMPD/person_commits.meta" "$TMPD/person_commits.data" > "$TMPD/c_pc.html"
  render_chart bars  1 0   count "merged PRs" "pr" "$TMPD/person_prs.meta"     "$TMPD/person_prs.data"     > "$TMPD/c_pp.html"
  render_chart lines 1 100 %     "%"          ""   "$TMPD/person_ratio.meta"   "$TMPD/person_ratio.data"   > "$TMPD/c_pr.html"
  { printf '%s' "$CMP_CAP"; change_table "$TMPD/person_commits.raw" "commits"; } > "$TMPD/t_pc.html"
  { printf '%s' "$CMP_CAP"; change_table "$TMPD/person_prs.raw"     "merged PRs"; } > "$TMPD/t_pp.html"
else
  for f in c_pc c_pp c_pr t_pc t_pp; do : > "$TMPD/$f.html"; done
fi

# Splice by marker with awk, never sed: the payload contains & and \ and every
# sed replacement metacharacter there is.
# splice <marker> <file> — replace the marker IN PLACE, keeping whatever else is
# on the line. Replacing the whole line instead silently ate the `<div
# class="grid">` and `</div>` that wrap every small-multiple chart, which turned
# a 3-column grid of readable panels into a stack of full-width SVGs with
# 40px axis text, and left the surrounding cards unclosed.
splice() {
  awk -v m="$1" -v f="$2" '
    {
      i = index($0, m)
      if (i == 0) { print; next }
      pre = substr($0, 1, i - 1); post = substr($0, i + length(m))
      if (pre != "") print pre
      while ((getline l < f) > 0) print l
      close(f)
      if (post != "") print post
    }'
}
cat "$BODY" \
  | splice __ORGC__    "$TMPD/c_orgc.html" \
  | splice __ORGP__    "$TMPD/c_orgp.html" \
  | splice __ORGR__    "$TMPD/c_orgr.html" \
  | splice __RCCHART__ "$TMPD/c_rc.html" \
  | splice __RPCHART__ "$TMPD/c_rp.html" \
  | splice __RCTABLE__ "$TMPD/t_rc.html" \
  | splice __RPTABLE__ "$TMPD/t_rp.html" \
  | splice __PCCHART__ "$TMPD/c_pc.html" \
  | splice __PPCHART__ "$TMPD/c_pp.html" \
  | splice __PRCHART__ "$TMPD/c_pr.html" \
  | splice __PCTABLE__ "$TMPD/t_pc.html" \
  | splice __PPTABLE__ "$TMPD/t_pp.html" > "$TMPD/body.final.html"

awk -v pre="$TMPD/pre.html" -v post="$TMPD/post.html" '
  index($0, "__DXM_TRENDS_BODY__") && !seen { seen = 1; next }
  { print > (seen ? post : pre) }
  END { exit(seen ? 0 : 1) }' "$TEMPLATE" || fail 2 "template $TEMPLATE has no __DXM_TRENDS_BODY__ marker"

HTML_TMP="$TMPD/out.html"
cat "$TMPD/pre.html" "$TMPD/body.final.html" "$TMPD/post.html" > "$HTML_TMP"
grep -q '__[A-Z]*__' "$HTML_TMP" && fail 4 "an unfilled placeholder survived into the output; refusing to write a half-rendered page"
BYTES="$(wc -c < "$HTML_TMP" | tr -d ' ')"

# ===========================================================================
# PRIVACY SELF-CHECK. Not a promise — a test, run against this exact file,
# every time, before it is allowed to exist.
#
# It greps the rendered bytes for every login and every display name in the
# database, plus anything email-shaped. A hit that is a substring of an in-scope
# REPOSITORY NAME is reported and allowed (a repo called `jdoe-website` is a
# repository identifier, not a per-person metric). Anything else is a hard fail.
# ===========================================================================
PII_COLLISIONS=""; PII_HITS=0; PII_COLL=0
if [ "$INCLUDE_INDIVIDUALS" -eq 0 ]; then
  NEEDLES="$TMPD/needles.txt"
  dxm_sql "SELECT login FROM identities WHERE login IS NOT NULL AND length(login) >= 4
           UNION SELECT display_name FROM identities WHERE display_name IS NOT NULL AND length(display_name) >= 4;" \
    | LC_ALL=C sort -u > "$NEEDLES"
  REPONAMES="$TMPD/reponames.txt"
  dxm_sql "SELECT full_name FROM repos WHERE owner=$QORG;" > "$REPONAMES"
  BAD="$TMPD/pii.txt"; : > "$BAD"
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    if LC_ALL=C grep -qiF -- "$needle" "$HTML_TMP"; then
      if LC_ALL=C grep -qiF -- "$needle" "$REPONAMES"; then
        PII_COLL=$((PII_COLL+1))
        PII_COLLISIONS="$PII_COLLISIONS $needle"
      else
        printf '%s\n' "$needle" >> "$BAD"
      fi
    fi
  done < "$NEEDLES"
  # Anything email-shaped at all. The org name itself is not an email.
  if LC_ALL=C grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$HTML_TMP"; then
    printf '(email-shaped string)\n' >> "$BAD"
  fi
  PII_HITS="$(wc -l < "$BAD" | tr -d ' ')"
  if [ "${PII_HITS:-0}" -gt 0 ]; then
    dxm_log "PRIVACY CHECK FAILED — the default render contains these:"
    head -20 "$BAD" >&2
    fail 4 "default render contains $PII_HITS personal identifier(s); refusing to write. Use --include-individuals if this was intended."
  fi
  if [ "$PII_COLL" -gt 0 ]; then
    dxm_warn "privacy check: $PII_COLL identifier(s) appear only inside repository names in scope (allowed):$PII_COLLISIONS"
  fi
  dxm_log "privacy check passed: no login, display name or email in the default render (${PII_COLL} repo-name collision(s) allowed)"
fi

# ---------------------------------------------------------------------------
# Coverage. Unit of output = one rendered chart.
# ---------------------------------------------------------------------------
{
  printf 'trend_chart\tcommits_per_repo_week@%s\tscript\tCOUNT over v_commits_enriched, non-merge, machine-steered excluded, bucketed by the view'\''s own week_start\n' "$ORG"
  printf 'trend_chart\tmerged_prs_per_repo_week@%s\tscript\tCOUNT over v_prs_enriched, MERGED only, bot-authored excluded, bucketed by merged_week_start\n' "$ORG"
  printf 'trend_chart\tmultiline_ratio_per_org_week@%s\tscript\tSUM(has_body)/COUNT over v_commits_enriched with has_body NOT NULL; subject and trailer-shaped lines stripped at backfill time\n' "$ORG"
  if [ "$INCLUDE_INDIVIDUALS" -eq 1 ]; then
    printf 'trend_chart\tcommits_per_person_week@%s\tscript\tsame population, grouped by resolved author login; opt-in render\n' "$ORG"
    printf 'trend_chart\tmerged_prs_per_person_week@%s\tscript\tsame population, grouped by resolved author login; opt-in render\n' "$ORG"
    printf 'trend_chart\tmultiline_ratio_per_person_week@%s\tscript\tsame ratio, grouped by resolved author login; opt-in render\n' "$ORG"
  else
    printf 'trend_chart\tper_person_series@%s\tscript\twithheld by default: per-person output requires --include-individuals and a separate output file\n' "$ORG"
  fi
  printf 'trend_chart\tmultiline_proxy_quality@%s\tscript-with-fallback\tprecision/recall computed in the renderer against declared trailers; agg_metric has no confusion-matrix dimension\n' "$ORG"
} | dxm_coverage_batch "$RUN_ID"

# ---------------------------------------------------------------------------
# Write.
# ---------------------------------------------------------------------------
if [ -z "$OUT_PATH" ]; then
  SAFE_KEY="$(printf '%s' "$ORG" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-')"
  SUFFIX=""; [ "$INCLUDE_INDIVIDUALS" -eq 1 ] && SUFFIX="-INDIVIDUALS-do-not-circulate"
  OUT_PATH="$DXM_OUT/dx-trends-${SAFE_KEY}-week-${UNTIL}${SUFFIX}.html"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  dxm_log "dry run: would write $BYTES bytes to $OUT_PATH"
  OUT_REPORTED=""
else
  mkdir -p "$(dirname "$OUT_PATH")"
  cp "$HTML_TMP" "$OUT_PATH"
  chmod 600 "$OUT_PATH"
  OUT_REPORTED="$OUT_PATH"
  dxm_log "wrote $BYTES bytes to $OUT_PATH"
fi

set -- $RC_FOLD; RC_KEPT="$1"; RC_FOLDED="$2"
set -- $RP_FOLD; RP_KEPT="$1"; RP_FOLDED="$2"

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$(printf '"org":%s,"period":"week","weeks":%s,"first_week":%s,"last_week":%s,"current_week":%s,"repos":%s,"commits_complete_weeks":%s,"merged_prs_complete_weeks":%s,"steerers":%s,"unknown_steerer_pct":%s,"machine_commits_excluded":%s,"multiline_pct":%s,"trailer_pct":%s,"multiline_precision_pct":%s,"multiline_recall_pct":%s,"unmeasurable_commits":%s,"repo_panels_commits":%s,"repo_panels_folded":%s,"include_individuals":%s,"pii_check":%s,"pii_repo_name_collisions":%s,"bytes":%s,"out":%s' \
  "$(dxm_json_str "$ORG")" "$N_WEEKS" "$(dxm_json_str "$ISO_FIRST")" "$(dxm_json_str "$ISO_LAST")" "$(dxm_json_str "$ISO_CUR")" \
  "$N_REPOS" "$S_COMMITS" "$S_PRS" "$COHORT" \
  "$([ "$S_UNK_PCT" = "—" ] && echo null || echo "$S_UNK_PCT")" "$S_MACHINE" \
  "$([ "$S_ML_PCT" = "—" ] && echo null || echo "$S_ML_PCT")" \
  "$([ "$S_AI_PCT" = "—" ] && echo null || echo "$S_AI_PCT")" \
  "$([ "$PREC" = "—" ] && echo null || echo "$PREC")" \
  "$([ "$RECALL" = "—" ] && echo null || echo "$RECALL")" \
  "$S_UNMEAS" "${RC_KEPT:-0}" "${RC_FOLDED:-0}" \
  "$([ "$INCLUDE_INDIVIDUALS" -eq 1 ] && echo true || echo false)" \
  "$([ "$INCLUDE_INDIVIDUALS" -eq 1 ] && echo '"skipped-opt-in"' || echo '"passed"')" \
  "$PII_COLL" "$BYTES" "$(dxm_json_str "$OUT_REPORTED")")"
