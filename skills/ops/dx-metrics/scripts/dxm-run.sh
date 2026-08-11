#!/usr/bin/env bash
# dxm-run.sh — the orchestrator. Chains the five stages in the only order that
# works, one repo at a time, and stops on the failures that would otherwise
# produce a confident wrong dashboard.
#
#   1. dxm-ingest-git.sh     git history  -> commits, ai_trailers      (per repo)
#   2. dxm-ingest-github.sh  GitHub API   -> PRs, identities, backfill (per repo)
#   3. dxm-identity.sh       mailmap, overrides, bot flags, review queue
#   4. dxm-classify.sh       PRs          -> pr_classifications
#   5. dxm-aggregate.sh      raw          -> agg_* (once per --period)
#   6. dxm-dashboard.sh      agg_*        -> a self-contained HTML page
#
# WHY SERIAL, AND WHY PER REPO:
#   Stages 1 and 2 clone and fetch. Running several of those at once saturates a
#   laptop's disk and network and makes the run slower, not faster, while also
#   making a failure impossible to attribute. There is no --parallel flag and
#   adding one would be a mistake.
#
#   Ingest is also per repo rather than one --org call so that a single bad repo
#   costs one repo, not the whole org: the loop records the failure, keeps the
#   watermarks of every other repo intact, and carries on.
#
# WHY THIS ORDER:
#   git before github  — identity resolution reads the commit emails git wrote.
#   identity before classify — classify skips bot-authored PRs, which needs
#                              identities.is_bot to already be set.
#   classify before aggregate — the defect/innovation ratios read pr_classifications.
#   aggregate before dashboard — the dashboard renders agg_metric and refuses to
#                              invent a number that is not there.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/dxm-common.sh"

SELF="$(basename "$0")"

usage() {
  cat <<'EOF'
dxm-run.sh — run the whole dx-metrics pipeline: ingest -> identity -> classify -> metrics -> dashboard.

SYNOPSIS
  dxm-run.sh --org owner [options]
  dxm-run.sh --repo owner/name [--repo owner/name ...] [options]

TARGETS
  --repo owner/name    Repository to measure. Repeatable.
  --org owner          Every non-archived, non-fork, non-empty repo in the org.
                       Repeatable. Expanded via `gh repo list` before ingest so
                       each repo is ingested on its own, serially.
                       REQUIRES an authenticated view of the org — see
                       --org-anchor. An unauthenticated enumeration silently
                       omits every private repo and is refused.
  --org-anchor owner/repo
                       A repo in the org that `gh` can authenticate against.
                       Under a per-repo token shim, `gh repo list ORG` returns
                       only what THAT repo's token can see, so the anchor
                       decides what "the org" means. Defaults to the first
                       --repo, then to a probe of the org's repos.

OPTIONS
  --since YYYY-MM-DD   Backfill floor for the FIRST ingest of a repo. Say so in
                       any report: a truncated window is a truncated conclusion.
  --until YYYY-MM-DD   Analysis ceiling. Default: today, UTC.
  --period day|week|month
                       Bucket granularity for aggregation and the dashboard.
                       Repeatable — `--period week --period month` aggregates
                       both and renders one dashboard per period.
                       Default: week.
  --max-repos N        Cap on repos expanded from an --org (default 200).
  --min-org-repos N    Assert that each --org expands to at least N repos, and
                       FAIL (exit 2) otherwise. A zero-length expansion is
                       always fatal with or without this flag: an org that
                       enumerates to nothing is a broken read, not a small org,
                       and it produces a complete, confident, empty dashboard.
  --gh-path PATH       Which `gh` binary to use (also DXM_GH). Default: `gh` on
                       PATH. Set this when the gh first on PATH is a shim that
                       mints per-repo tokens — under one, `gh repo list ORG`
                       returned 0 repos and exit 0 for an org that really has
                       28. GH_TOKEN / GITHUB_TOKEN are cleared for every gh call
                       (set DXM_GH_CLEAR_TOKENS=0 to keep them) so an ambient
                       token cannot silently override `gh auth login`.
  --page-size N        PRs per GraphQL page, 1..100 (default 50). A repo whose
                       PRs are heavy enough to make GitHub 504 is retried
                       automatically at half the size, down to 1; lower this if
                       you would rather not pay for the failed attempts.
  --skip-ingest        Re-run everything downstream of ingest against the data
                       already in the DB. No clones, no API calls.
  --rebuild            Drop and recompute derived rows (classifications and
                       aggregates). Does NOT re-fetch raw data.
  --refetch            Re-scan git history and re-pull PRs, ignoring watermarks.
                       Idempotent (upserts) — this repairs, it does not duplicate.
  --include-individuals
                       OPT-IN. Adds the individual section (ownership/SPOF risk
                       and AI-adoption timing) to the dashboard. There is no
                       per-person throughput output with or without this flag.
  --out DIR            Where dashboards are written. Default: $DXM_OUT.
  --no-dashboard       Stop after aggregation.
  --keep-going         Do not stop when a repo fails to ingest; report it and
                       carry on. (Default: a repo failure is recorded and the
                       loop continues; --keep-going additionally tolerates a
                       *stage* failure such as a rate limit.)
  --doctor             Check preconditions and the DB, print a report, exit.
  --dry-run            Pass --dry-run to every stage. Writes nothing.
  --json               Default and implicit.
  --help               This text.

OUTPUT
  One line of JSON on stdout, at the end. Every stage's own envelope and all
  progress output go to stderr, so a caller can read stdout blindly.

EXIT CODES
  0 ok · 1 usage · 2 precondition (missing tool, shallow clone, no targets)
  3 partial (a stage was rate limited or a repo failed; watermarks held)
  4 data error

PRIVACY
  The default dashboard contains no personal information. This is a measure of a
  SYSTEM, not of people. See SKILL.md.
EOF
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
REPOS=(); ORGS=(); PERIODS=()
SINCE=""; UNTIL=""; OUT_DIR=""; ORG_ANCHOR=""
MAX_REPOS=200; PAGE_SIZE=""; MIN_ORG_REPOS=""; GH_LOGIN=""
SKIP_INGEST=0; REBUILD=0; REFETCH=0; INDIVIDUALS=0
NO_DASHBOARD=0; KEEP_GOING=0; DOCTOR=0; DRY_RUN=0

need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || dxm_die "flag $1 requires a value" 1; }
chk_date() { case "$2" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) dxm_die "$1 must be YYYY-MM-DD, got: $2" 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)   usage; exit 0 ;;
    --repo)      need "$1" "${2:-}"; case "$2" in */*) ;; *) dxm_die "--repo must be owner/name, got: $2" 1 ;; esac
                 REPOS+=("$2"); shift 2 ;;
    --org)       need "$1" "${2:-}"; ORGS+=("$2"); shift 2 ;;
    --org-anchor) need "$1" "${2:-}"; case "$2" in */*) ;; *) dxm_die "--org-anchor must be owner/name" 1 ;; esac
                 ORG_ANCHOR="$2"; shift 2 ;;
    --since)     need "$1" "${2:-}"; chk_date "$1" "$2"; SINCE="$2"; shift 2 ;;
    --until)     need "$1" "${2:-}"; chk_date "$1" "$2"; UNTIL="$2"; shift 2 ;;
    --period)    need "$1" "${2:-}"
                 case "$2" in day|week|month) ;; *) dxm_die "--period must be day|week|month" 1 ;; esac
                 PERIODS+=("$2"); shift 2 ;;
    --max-repos) need "$1" "${2:-}"; case "$2" in ''|*[!0-9]*) dxm_die "--max-repos must be a number" 1 ;; esac
                 MAX_REPOS="$2"; shift 2 ;;
    --min-org-repos) need "$1" "${2:-}"; case "$2" in ''|*[!0-9]*) dxm_die "--min-org-repos must be a number" 1 ;; esac
                 MIN_ORG_REPOS="$2"; DXMI_MIN_ORG_REPOS="$2"; export DXMI_MIN_ORG_REPOS; shift 2 ;;
    --gh-path)   need "$1" "${2:-}"; DXM_GH="$2"; export DXM_GH; shift 2 ;;
    --page-size) need "$1" "${2:-}"; case "$2" in ''|*[!0-9]*) dxm_die "--page-size must be a number" 1 ;; esac
                 [ "$2" -ge 1 ] && [ "$2" -le 100 ] || dxm_die "--page-size must be 1..100" 1
                 PAGE_SIZE="$2"; shift 2 ;;
    --out)       need "$1" "${2:-}"; OUT_DIR="$2"; shift 2 ;;
    --skip-ingest)        SKIP_INGEST=1; shift ;;
    --rebuild)            REBUILD=1; shift ;;
    --refetch)            REFETCH=1; shift ;;
    --include-individuals) INDIVIDUALS=1; shift ;;
    --no-dashboard)       NO_DASHBOARD=1; shift ;;
    --keep-going)         KEEP_GOING=1; shift ;;
    --doctor)             DOCTOR=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --json)               shift ;;
    --)                   shift ;;
    *) printf 'ERROR: unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

[ ${#PERIODS[@]} -gt 0 ] || PERIODS=(week)
[ -n "$OUT_DIR" ] && { DXM_OUT="$OUT_DIR"; export DXM_OUT; }

# ---------------------------------------------------------------------------
# preconditions. Fail here, loudly, rather than half way through a 20-minute run.
# ---------------------------------------------------------------------------
dxm_require_cmd git sqlite3 awk jq
command -v "$DXM_GH" >/dev/null 2>&1 || dxm_die "required command not found: $DXM_GH (set DXM_GH to a gh binary)" 2
dxm_init_db

GH_AUTH_OK=0; GH_AUTH_MSG="NOT AUTHENTICATED — run: gh auth login  (every GitHub read will fail)"
if dxm_gh_run auth status >/dev/null 2>&1; then
  GH_AUTH_OK=1
  GH_LOGIN="$(dxm_gh_login)"
  GH_AUTH_MSG="ok${GH_LOGIN:+  (as $GH_LOGIN)}"
fi

if [ "$DOCTOR" -eq 1 ]; then
  {
    printf 'dx-metrics doctor\n'
    printf '  skill      %s (schema v%s)\n' "$DXM_SKILL_VERSION" "$DXM_SCHEMA_VERSION"
    printf '  db         %s\n' "$DXM_DB"
    printf '  cache      %s\n' "$DXM_CACHE"
    printf '  out        %s\n' "$DXM_OUT"
    printf '  sqlite3    %s\n' "$(sqlite3 --version | awk '{print $1}')"
    printf '  gh         %s  [binary: %s]\n' \
      "$(dxm_gh_run --version 2>/dev/null | awk 'NR==1{print $3}')" "$DXM_GH"
    # --doctor exists to answer "will a run work?". It used to check that gh was
    # INSTALLED and never that it was AUTHENTICATED, so the single most common
    # first-run failure (installed gh, never ran `gh auth login`) passed doctor
    # green and then surfaced as exit 3 "some repos did not complete; re-run to
    # resume" — advice that can never help, on a failure whose cause was never
    # named. An unauthenticated gh is a precondition failure, not a transient.
    printf '  gh auth    %s\n' "$GH_AUTH_MSG"
    printf '  repos      %s ingested\n' "$(dxm_sql1 'SELECT COUNT(*) FROM repos;')"
    printf '  commits    %s\n' "$(dxm_sql1 'SELECT COUNT(*) FROM commits;')"
    printf '  PRs        %s\n' "$(dxm_sql1 'SELECT COUNT(*) FROM pull_requests;')"
    printf '  unsafe     %s repo(s) flagged shallow/unanalysable\n' "$(dxm_sql1 'SELECT COUNT(*) FROM v_unsafe_repos;')"
    printf '  dangling   %s run(s) still marked running (a previous invocation died)\n' \
      "$(dxm_sql1 "SELECT COUNT(*) FROM runs WHERE status='running';")"
    printf '  integrity  %s\n' "$(dxm_sql1 'PRAGMA integrity_check;')"
    printf '\n  top LLM-fallback reasons (the rule backlog):\n'
    # v_llm_backlog exposes the give-up string as `reason`, not `detail` —
    # `detail` is coverage_log's column name and selecting it here silently
    # printed nothing at all, which is the worst possible behaviour for a
    # health check.
    dxm_sql "SELECT '    ' || hits || 'x  [' || unit_kind || '] ' || substr(reason,1,80) FROM v_llm_backlog LIMIT 8;" 2>/dev/null || true
    printf '\n  coverage by unit kind (all runs in this DB):\n'
    dxm_sql "SELECT printf('    %-20s %5d units  %5.1f%% covered  %d llm', unit_kind, COUNT(*),
                     100.0*SUM(method<>'llm')/COUNT(*), SUM(method='llm'))
               FROM coverage_log GROUP BY unit_kind ORDER BY COUNT(*) DESC;" 2>/dev/null || true
  } >&2
  RUN_ID=$(dxm_run_start "$SELF" "--doctor" "")
  dxm_run_finish "$RUN_ID" ok 0
  # The human text above already prints coverage. Emitting null for it on the
  # machine-readable path meant the one consumer SKILL.md tells to read stdout
  # saw the self-measured honesty metric as absent.
  DOCTOR_COV="$(dxm_sql1 "SELECT printf('%.1f', 100.0*SUM(method<>'llm')/NULLIF(COUNT(*),0)) FROM coverage_log;")"
  [ -n "$DOCTOR_COV" ] || DOCTOR_COV=null
  dxm_emit "$([ "$GH_AUTH_OK" -eq 1 ] && echo true || echo false)" "$SELF" "$RUN_ID" "\"doctor\":true,\"gh_authenticated\":$([ "$GH_AUTH_OK" -eq 1 ] && echo true || echo false),\"coverage_pct\":$DOCTOR_COV,\"repos\":$(dxm_sql1 'SELECT COUNT(*) FROM repos;'),\"unsafe_repos\":$(dxm_sql1 'SELECT COUNT(*) FROM v_unsafe_repos;'),\"dangling_runs\":$(dxm_sql1 "SELECT COUNT(*) FROM runs WHERE status='running';")"
  exit 0
fi

[ ${#REPOS[@]} -gt 0 ] || [ ${#ORGS[@]} -gt 0 ] || \
  dxm_die "nothing to measure: pass --repo owner/name and/or --org owner" 1

# Exit 2 (precondition), not exit 3 (partial, re-run to resume). Without gh auth
# EVERY repo fails identically and no number of re-runs fixes it; reporting that
# as a resumable partial sends the operator into a retry loop.
[ "$GH_AUTH_OK" -eq 1 ] || \
  dxm_die "gh is not authenticated — run 'gh auth login'. Every GitHub read would fail and the run would produce confidently empty numbers." 2

RUN_ID=$(dxm_run_start "$SELF" "$*" "${REPOS[0]:-${ORGS[0]:-}}")
trap 'rc=$?; dxm_run_trap '"$RUN_ID"' $rc' EXIT

# ---------------------------------------------------------------------------
# Target expansion. Done HERE, once, so the per-repo loop below is serial and
# every stage sees the same target list.
#
# THE ORG-ENUMERATION TRAP (found the hard way, on the first real run):
#   Where `gh` is a shim that mints a fresh INSTALLATION TOKEN per invocation,
#   scoped to $GH_REPO, `gh repo list ORG` returns only the repos that THAT
#   token can see — anchoring on one repo of an org returned 6 repos, anchoring
#   on a second repo of the SAME org returned 5 DIFFERENT ones, and
#   anchoring on a repo that does not exist made the shim fall back to running
#   UNAUTHENTICATED, which returned 27 public repos and silently omitted every
#   private one — while exiting 0 and looking perfectly successful.
#
#   "The org" is therefore not a well-defined set under this shim. Two runs a
#   week apart could measure two different populations and nothing would say so.
#   We refuse the unauthenticated answer rather than average over it, and we
#   record which anchor produced the list.
# ---------------------------------------------------------------------------
TARGETS=()
for r in ${REPOS[@]+"${REPOS[@]}"}; do [ -n "$r" ] && TARGETS+=("$r"); done

ORG_ANCHOR_USED=""
for org in ${ORGS[@]+"${ORGS[@]}"}; do
  [ -n "$org" ] || continue

  anchor="$ORG_ANCHOR"
  [ -n "$anchor" ] || anchor="${TARGETS[0]:-}"
  if [ -z "$anchor" ]; then
    # No anchor given and no explicit --repo. Probe: ask GitHub for the org's
    # repos with whatever auth we have, then re-enumerate anchored on the first
    # one. The probe result itself is never trusted as the target list.
    probe="$(GH_REPO="" dxm_gh_run api "orgs/$org/repos?per_page=1" --jq '.[0].full_name // empty' 2>/dev/null || true)"
    anchor="$probe"
  fi
  [ -n "$anchor" ] || dxm_die "cannot enumerate org '$org': no anchor repo. Pass --org-anchor $org/<a-repo> (a repo gh can authenticate against) or list repos with --repo." 2

  errf="$(mktemp "${TMPDIR:-/tmp}/dxm-orglist-err.XXXXXX")"
  raw="$(GH_REPO="$anchor" dxm_gh_run repo list "$org" --limit "$MAX_REPOS" --no-archived --source \
          --json nameWithOwner,isArchived,isFork,isEmpty,defaultBranchRef 2>"$errf" || true)"
  shim_err="$(cat "$errf")"; rm -f "$errf"

  if ! printf '%s' "$raw" | jq -e 'type=="array"' >/dev/null 2>&1; then
    dxm_die "could not enumerate org '$org' (anchor $anchor): $(printf '%s' "$shim_err" | tr '\n' ' ' | cut -c1-200)" 2
  fi

  # The refusal. An unauthenticated listing is a TRUNCATED listing that reports
  # success — exactly the class of silent wrongness this skill exists to avoid.
  if printf '%s' "$shim_err" | grep -qi 'running gh unauthenticated'; then
    dxm_die "refusing org '$org': gh fell back to an UNAUTHENTICATED listing using anchor '$anchor', which sees only public repos and silently omits every private one. Pass --org-anchor $org/<a-repo-you-can-read> or enumerate with --repo." 2
  fi

  n_before=${#TARGETS[@]}
  while IFS= read -r nwo; do
    [ -n "$nwo" ] || continue
    dup=0; for t in ${TARGETS[@]+"${TARGETS[@]}"}; do [ "$t" = "$nwo" ] && dup=1; done
    [ "$dup" -eq 0 ] && TARGETS+=("$nwo")
  done < <(printf '%s' "$raw" | jq -r '.[]
             | select((.isArchived // false)|not)
             | select((.isFork // false)|not)
             | select((.isEmpty // false)|not)
             | select(.defaultBranchRef != null)
             | .nameWithOwner')
  ORG_ANCHOR_USED="$anchor"
  n_added=$(( ${#TARGETS[@]} - n_before ))

  # A ZERO-length org enumeration is the failure this guard exists for, and it
  # is the one that looks most like success. Measured: `gh repo list <org>`
  # under a per-repo token shim returned an empty JSON array and exit 0 — no
  # error text, nothing to grep for — while the same command under the
  # operator's own login returned 28 repos. Left unguarded, that run would have
  # produced a complete, well-formatted, entirely empty dashboard.
  if [ "$n_added" -eq 0 ]; then
    dxm_die "org '$org' enumerated to ZERO repositories (anchor $anchor, gh binary $DXM_GH${GH_LOGIN:+, as $GH_LOGIN}). That is a broken read, not a small org: an empty org cannot be distinguished from a token that cannot see it, so this run refuses to continue rather than publish zeros. Set DXM_GH to a gh authenticated as an org member, or pass --repo explicitly." 2
  fi
  if [ -n "$MIN_ORG_REPOS" ] && [ "$n_added" -lt "$MIN_ORG_REPOS" ]; then
    dxm_die "org '$org' enumerated to $n_added repo(s), below the asserted floor of $MIN_ORG_REPOS (--min-org-repos). Refusing to measure an org from an unknown subset of it." 2
  fi

  dxm_log "org $org: expanded to $n_added repo(s) using anchor $anchor (gh: $DXM_GH${GH_LOGIN:+, as $GH_LOGIN})"
  dxm_log "  NOTE: under a per-repo token shim this list is anchor-dependent. Record the anchor AND the gh identity alongside any number you publish."
done

[ ${#TARGETS[@]} -gt 0 ] || dxm_die "no ingestable repos resolved from the given targets" 2

dxm_log "=== dx-metrics run: ${#TARGETS[@]} repo(s), periods: ${PERIODS[*]} ==="
for t in "${TARGETS[@]}"; do dxm_log "    $t"; done

# ---------------------------------------------------------------------------
# stage runner. Every stage prints one JSON line; we keep it on stderr for the
# operator and only carry the exit code forward. Exit 3 is a first-class
# outcome, not a crash: watermarks were held, so the next run resumes.
# ---------------------------------------------------------------------------
N_OK=0; N_PARTIAL=0; N_FAILED=0
FAILED_REPOS=""
WORST=0

# Run a stage, echo its envelope to stderr, return its exit code.
run_stage() {
  local label="$1" script="$2"; shift 2
  local rc=0 env_line envf
  envf="$(mktemp "${TMPDIR:-/tmp}/dxm-run-env.XXXXXX")"
  dxm_log ""
  dxm_log "--> $label"
  "$SCRIPT_DIR/$script" "$@" >"$envf" || rc=$?
  env_line="$(cat "$envf")"; rm -f "$envf"
  [ -n "$env_line" ] && dxm_log "    $env_line"
  [ "$rc" -gt "$WORST" ] && WORST="$rc"
  return "$rc"
}

COMMON=()
[ "$DRY_RUN" -eq 1 ] && COMMON+=(--dry-run)

# ---------------------------------------------------------------------------
# Stages 1 + 2 — ingest, SERIALLY, one repo at a time.
# ---------------------------------------------------------------------------
if [ "$SKIP_INGEST" -eq 1 ]; then
  dxm_log "--skip-ingest: using the raw data already in $DXM_DB"
  N_OK=${#TARGETS[@]}
else
  for repo in "${TARGETS[@]}"; do
    dxm_log ""
    dxm_log "======== $repo ========"
    repo_rc=0

    gargs=(--repo "$repo" "${COMMON[@]+"${COMMON[@]}"}")
    [ -n "$SINCE" ] && gargs+=(--since "$SINCE")
    [ -n "$UNTIL" ] && gargs+=(--until "$UNTIL")
    [ "$REFETCH" -eq 1 ] && gargs+=(--refetch)
    run_stage "git ingest: $repo" dxm-ingest-git.sh "${gargs[@]}" || repo_rc=$?

    if [ "$repo_rc" -eq 0 ]; then
      hargs=(--repo "$repo" "${COMMON[@]+"${COMMON[@]}"}")
      [ -n "$SINCE" ] && hargs+=(--since "$SINCE")
      [ -n "$UNTIL" ] && hargs+=(--until "$UNTIL")
      [ "$REFETCH" -eq 1 ] && hargs+=(--refetch)
      [ "$REBUILD" -eq 1 ] && hargs+=(--rebuild)
      [ -n "$PAGE_SIZE" ] && hargs+=(--page-size "$PAGE_SIZE")
      run_stage "github ingest: $repo" dxm-ingest-github.sh "${hargs[@]}" || repo_rc=$?
    else
      dxm_warn "$repo: git ingest failed (rc=$repo_rc) — skipping its GitHub pull so a half-ingested repo is not treated as complete"
    fi

    case "$repo_rc" in
      0) N_OK=$((N_OK + 1)) ;;
      3) N_PARTIAL=$((N_PARTIAL + 1)); FAILED_REPOS="$FAILED_REPOS $repo(partial)" ;;
      *) N_FAILED=$((N_FAILED + 1)); FAILED_REPOS="$FAILED_REPOS $repo(rc=$repo_rc)"
         if [ "$KEEP_GOING" -eq 0 ] && [ "$repo_rc" -eq 2 ]; then
           # A shallow clone is the one failure that must stop the run: every
           # downstream number would be confidently wrong rather than missing.
           dxm_run_finish "$RUN_ID" error 2 "$repo: precondition failure (shallow clone or missing tool)"
           dxm_emit false "$SELF" "$RUN_ID" \
             "\"stage\":\"ingest\",\"repo\":$(dxm_json_str "$repo"),\"error\":\"precondition failure (rc=2). A shallow clone truncates history and would produce a confident, wrong time series. Delete its cache dir under \$DXM_CACHE and re-run, or pass --keep-going to measure the other repos without it.\""
           exit 2
         fi ;;
    esac
  done
fi

if [ "$N_OK" -eq 0 ] && [ "$N_PARTIAL" -eq 0 ]; then
  dxm_run_finish "$RUN_ID" error 4 "no repo ingested successfully"
  dxm_emit false "$SELF" "$RUN_ID" "\"error\":\"no repo ingested successfully;$FAILED_REPOS\",\"repos_failed\":$N_FAILED"
  exit 4
fi

# ---------------------------------------------------------------------------
# Stage 3 — identity. Once, over everything, not per repo: one human's addresses
# routinely span several repos and the mailmap has to see all of them.
#
# --no-coverage: dxm-ingest-github.sh already logged an identity_resolution unit
# for every email it resolved. Logging them again here would double the
# denominator that meta.script_coverage_pct reads.
# --resolve is NOT passed for the same reason: W2's resolution is batched (~40
# emails per GraphQL call) where this script's is one REST call per email. Run
# `dxm-identity.sh --resolve` by hand if you have edited the override file and
# want stragglers retried.
# ---------------------------------------------------------------------------
#
# --backfill-commits: the orchestrator passes it because it owns the ORDER.
# CONTRACT §10 gives commits.author_identity_id to the GitHub ingest, and that
# ingest runs at stage 2 — BEFORE the override file is read at stage 3 and only
# over rows that are still NULL. Without this, a mapping added to
# identity-overrides.tsv changed nothing in the run that applied it: the
# operator fixed 577 commits, watched the unknown-steerer share not move, and
# had no way to tell that the fix had simply not been carried into the column
# the metrics read. Re-pointing an already-attributed commit is also the whole
# purpose of an `alias` line, so "only fill the NULLs" is the wrong rule here.
iargs=(--no-coverage --backfill-commits "${COMMON[@]+"${COMMON[@]}"}")
[ "$REBUILD" -eq 1 ] && iargs+=(--rebuild)
[ "$INDIVIDUALS" -eq 1 ] && iargs+=(--include-individuals)
run_stage "identity map + mailmap + review queue" dxm-identity.sh "${iargs[@]}" || \
  dxm_warn "identity stage returned non-zero; continuing — unresolved emails are reported as unattributed, not guessed"

# ---------------------------------------------------------------------------
# Stage 4 — classification. Scoped to the targets so a shared DB is not
# reclassified wholesale on every run.
# ---------------------------------------------------------------------------
cargs=("${COMMON[@]+"${COMMON[@]}"}")
for repo in "${TARGETS[@]}"; do cargs+=(--repo "$repo"); done
[ -n "$SINCE" ] && cargs+=(--since "$SINCE")
[ -n "$UNTIL" ] && cargs+=(--until "$UNTIL")
[ "$REBUILD" -eq 1 ] && cargs+=(--rebuild)
run_stage "PR classification" dxm-classify.sh "${cargs[@]}" || \
  dxm_warn "classification stage returned non-zero; quality/impact ratios will carry a larger unclassified remainder"

# ---------------------------------------------------------------------------
# Stage 5 + 6 — aggregate and render, once per requested period.
# --period takes one kind per invocation by contract, so three granularities
# means three calls. That is deliberate: each writes its own agg_metric rows.
# ---------------------------------------------------------------------------
DASHBOARDS=""
N_DASH=0
for period in "${PERIODS[@]}"; do
  aargs=(--period "$period" "${COMMON[@]+"${COMMON[@]}"}")
  for repo in "${TARGETS[@]}"; do aargs+=(--repo "$repo"); done
  [ -n "$SINCE" ] && aargs+=(--since "$SINCE")
  [ -n "$UNTIL" ] && aargs+=(--until "$UNTIL")
  [ "$REBUILD" -eq 1 ] && aargs+=(--rebuild)
  [ "$INDIVIDUALS" -eq 1 ] && aargs+=(--include-individuals)
  run_stage "aggregate ($period)" dxm-aggregate.sh "${aargs[@]}" || \
    dxm_warn "aggregate ($period) returned non-zero"

  [ "$NO_DASHBOARD" -eq 1 ] && continue
  [ "$DRY_RUN" -eq 1 ] && continue

  # One dashboard per scope. An --org run renders the org; a --repo-only run
  # renders each repo. The dashboard refuses to guess when the scope is
  # ambiguous, so it is always told explicitly.
  # An org-scope page whenever two or more targets share an owner — that is the
  # aggregate, no-personal-information view and it is the one meant to be shown.
  # Per-repo pages are rendered too, because "which repo moved" is the first
  # question anyone asks of an org number.
  scopes=()
  owners_seen=""
  for repo in "${TARGETS[@]}"; do
    o="${repo%%/*}"
    case " $owners_seen " in *" $o "*) ;; *) owners_seen="$owners_seen $o" ;; esac
  done
  for o in $owners_seen; do
    n=0; for repo in "${TARGETS[@]}"; do [ "${repo%%/*}" = "$o" ] && n=$((n + 1)); done
    [ "$n" -ge 2 ] && scopes+=("org|$o")
  done
  for org in ${ORGS[@]+"${ORGS[@]}"}; do
    case " ${scopes[*]-} " in *" org|$org "*) ;; *) scopes+=("org|$org") ;; esac
  done
  for repo in "${TARGETS[@]}"; do scopes+=("repo|$repo"); done

  for s in "${scopes[@]}"; do
    kind="${s%%|*}"; key="${s#*|}"
    dargs=(--scope "$kind" --scope-key "$key" --period "$period")
    [ -n "$UNTIL" ] && dargs+=(--until "$UNTIL")
    [ "$INDIVIDUALS" -eq 1 ] && dargs+=(--include-individuals)
    envf="$(mktemp "${TMPDIR:-/tmp}/dxm-run-dash.XXXXXX")"
    drc=0
    dxm_log ""
    dxm_log "--> dashboard ($kind $key, $period)"
    "$SCRIPT_DIR/dxm-dashboard.sh" "${dargs[@]}" >"$envf" || drc=$?
    line="$(cat "$envf")"; rm -f "$envf"
    [ -n "$line" ] && dxm_log "    $line"
    if [ "$drc" -eq 0 ]; then
      p="$(printf '%s' "$line" | jq -r '.out // empty' 2>/dev/null || true)"
      # Newline-separated, not space-separated: a dashboard written to
      # "~/Desktop/Client Reports/..." otherwise split on the space and the
      # envelope reported a path that does not exist, with ok:true.
      [ -n "$p" ] && { DASHBOARDS="${DASHBOARDS}${p}
"; N_DASH=$((N_DASH + 1)); }
    else
      dxm_warn "dashboard ($kind $key, $period) failed rc=$drc"
      [ "$drc" -gt "$WORST" ] && WORST="$drc"
    fi
  done
done

# ---------------------------------------------------------------------------
# outcome
# ---------------------------------------------------------------------------
COMMITS="$(dxm_sql1 'SELECT COUNT(*) FROM commits;')"
AI_COMMITS="$(dxm_sql1 'SELECT COUNT(*) FROM v_commits_enriched WHERE is_ai_assisted=1;')"
PRS="$(dxm_sql1 'SELECT COUNT(*) FROM pull_requests;')"
MERGED="$(dxm_sql1 "SELECT COUNT(*) FROM pull_requests WHERE state='MERGED' AND merged_at IS NOT NULL;")"
HUMANS="$(dxm_sql1 'SELECT COUNT(*) FROM v_human_identities;')"
UNRES="$(dxm_sql1 'SELECT COUNT(*) FROM v_unresolved_emails;')"
COVPCT="$(dxm_sql1 "SELECT printf('%.1f', 100.0*(SUM(n_script)+SUM(n_script_fallback))/NULLIF(SUM(total),0)) FROM v_coverage_by_run;")"
[ -n "$COVPCT" ] || COVPCT=null

LAST="$(printf '%s' "$DASHBOARDS" | grep -v '^$' | tail -n1)"
# All of them, so a multi-period run does not leave N-1 dashboards undiscoverable.
ALL_DASH="$(printf '%s' "$DASHBOARDS" | grep -v '^$' \
  | while IFS= read -r d; do printf '%s,' "$(dxm_json_str "$d")"; done)"
ALL_DASH="[${ALL_DASH%,}]"

PAYLOAD="\"repos_targeted\":${#TARGETS[@]},\"repos_ok\":$N_OK,\"repos_partial\":$N_PARTIAL,\"repos_failed\":$N_FAILED"
PAYLOAD="$PAYLOAD,\"periods\":\"${PERIODS[*]}\",\"dashboards\":$N_DASH"
[ -n "$ORG_ANCHOR_USED" ] && PAYLOAD="$PAYLOAD,\"org_anchor\":$(dxm_json_str "$ORG_ANCHOR_USED")"
# Provenance for every org-level number below: which binary read the org, and
# as whom. Two runs a week apart under different gh identities can measure two
# different populations, and nothing else on this page would say so.
PAYLOAD="$PAYLOAD,\"gh\":{\"binary\":$(dxm_json_str "$DXM_GH"),\"login\":$(dxm_json_str "$GH_LOGIN")}"
[ -n "$SINCE" ] && PAYLOAD="$PAYLOAD,\"window_floor\":$(dxm_json_str "$SINCE"),\"window_note\":\"BOUNDED BACKFILL — this is not full history; say so in any report\""
[ -n "$LAST" ] && PAYLOAD="$PAYLOAD,\"dashboard\":$(dxm_json_str "$LAST"),\"dashboard_paths\":$ALL_DASH"
PAYLOAD="$PAYLOAD,\"db_totals\":{\"commits\":$COMMITS,\"ai_commits\":$AI_COMMITS,\"prs\":$PRS,\"prs_merged\":$MERGED,\"humans\":$HUMANS,\"unresolved_emails\":$UNRES}"
PAYLOAD="$PAYLOAD,\"pipeline_coverage_pct\":$COVPCT"
PAYLOAD="$PAYLOAD,\"dry_run\":$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
PAYLOAD="$PAYLOAD,\"privacy\":\"default output contains no personal information; not for individual performance evaluation\""

if [ "$N_FAILED" -gt 0 ] || [ "$N_PARTIAL" -gt 0 ] || [ "$WORST" -eq 3 ]; then
  dxm_run_finish "$RUN_ID" partial 3 "repos failed/partial:$FAILED_REPOS"
  dxm_emit false "$SELF" "$RUN_ID" "$PAYLOAD,\"partial\":true,\"note\":\"some repos did not complete; watermarks were held so a re-run resumes\""
  exit 3
fi

dxm_run_finish "$RUN_ID" ok 0
dxm_emit true "$SELF" "$RUN_ID" "$PAYLOAD"
