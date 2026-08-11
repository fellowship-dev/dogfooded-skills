#!/usr/bin/env bash
# dxm-common.sh — shared plumbing for every dx-metrics script.
#
# This file is the CONTRACT MADE EXECUTABLE. It contains no collection logic and
# no metric logic. It exists so that DB location, run bookkeeping, watermarks,
# coverage logging and the stdout envelope are implemented ONCE and cannot drift
# between the scripts that use them.
#
# OWNERSHIP: shared. Do not add repo-fetching, PR-parsing or metric maths here.
# If you need a helper that only your script uses, put it in your own script.
#
# Usage, from any scripts/dxm-*.sh:
#     set -euo pipefail
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "$SCRIPT_DIR/../lib/dxm-common.sh"
#
# shellcheck shell=bash

set -uo pipefail

DXM_SKILL_VERSION="0.1.0"
DXM_SCHEMA_VERSION="1"

# ---------------------------------------------------------------------------
# Paths. Every script resolves them the same way, or resumability breaks.
# ---------------------------------------------------------------------------
DXM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DXM_SKILL_DIR="$(cd "$DXM_LIB_DIR/.." && pwd)"
DXM_SCHEMA_FILE="$DXM_SKILL_DIR/schema.sql"

: "${DXM_HOME:=$HOME/.dx-metrics}"
: "${DXM_DB:=$DXM_HOME/dxm.db}"
: "${DXM_CACHE:=$DXM_HOME/cache}"
: "${DXM_OUT:=$DXM_HOME/out}"

export DXM_HOME DXM_DB DXM_CACHE DXM_OUT

# ---------------------------------------------------------------------------
# Logging. Humans read stderr. Machines read stdout. Never mix them.
# ---------------------------------------------------------------------------
dxm_log()  { printf '%s\n' "$*" >&2; }
dxm_warn() { printf 'WARN: %s\n' "$*" >&2; }
# CONTRACT.md requires every exit to put a JSON envelope on stdout, and SKILL.md
# tells the calling agent to read stdout and ignore stderr unless something
# failed. dxm_die used to write only to stderr, so every hard failure handed the
# agent an empty string and no reason — the agent then had to guess, or re-run.
# The message is emitted on BOTH streams: stderr for a human, stdout for the
# caller that was told to read stdout.
dxm_die()  {
  local code="${2:-1}"
  printf 'ERROR: %s\n' "$1" >&2
  printf '{"ok":false,"error":%s,"exit_code":%s}\n' "$(dxm_json_str "$1")" "$code"
  exit "$code"
}

dxm_utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
dxm_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || dxm_die "required command not found: $c" 2
  done
}

# ---------------------------------------------------------------------------
# SQL. Single quotes are the only escaping hazard we hand-build.
# ---------------------------------------------------------------------------
# dxm_q <value>  ->  a safely quoted SQL string literal, or NULL for empty input
# SQ is spelled out rather than backslash-escaped inline: the escaping rules for
# the replacement half of ${var//pat/rep} differ between bash versions.
dxm_q() {
  local v="${1-}" SQ="'"
  if [ -z "$v" ]; then printf 'NULL'; return; fi
  printf "%s%s%s" "$SQ" "${v//$SQ/$SQ$SQ}" "$SQ"
}

# dxm_sql <sql...>       — execute, stream results to stdout (pipe-separated)
# dxm_sql1 <sql...>      — execute, return first column of first row
# dxm_sql_json <sql...>  — execute, return a JSON array of row objects
_dxm_sqlite() { sqlite3 -cmd ".timeout 10000" -cmd "PRAGMA foreign_keys=ON" "$DXM_DB" "$@"; }
dxm_sql()      { _dxm_sqlite "$*"; }
dxm_sql1()     { _dxm_sqlite "$*" | head -n1; }
dxm_sql_json() { _dxm_sqlite -json "$*"; }

# dxm_sql_stdin — feed a whole SQL script on stdin. Use this for bulk INSERTs
#                 wrapped in BEGIN/COMMIT; one sqlite3 process per 10k rows,
#                 not one per row.
dxm_sql_stdin() { _dxm_sqlite; }

# ---------------------------------------------------------------------------
# DB lifecycle
# ---------------------------------------------------------------------------
# dxm_add_column <table> <column> <decl> — idempotent ADD COLUMN.
#
# WHY THIS EXISTS: schema.sql declares every column inside
# `CREATE TABLE IF NOT EXISTS`, which is a NO-OP against a database that already
# has the table. So a new nullable column added to schema.sql reaches a fresh
# database and NEVER reaches an existing one — and the first index or view in
# schema.sql that mentions it then fails the whole apply with
# "no such column", which is how a working DB becomes unopenable by every
# script at once. SQLite has no `ADD COLUMN IF NOT EXISTS`, so the migration is
# feature-detected here and MUST run BEFORE schema.sql is applied.
dxm_add_column() {
  local t="$1" c="$2" decl="$3" has_table has_col
  has_table="$(_dxm_sqlite "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$t';" 2>/dev/null || echo 0)"
  [ "${has_table:-0}" = "1" ] || return 0      # fresh DB: CREATE TABLE will carry it
  has_col="$(_dxm_sqlite "SELECT COUNT(*) FROM pragma_table_info('$t') WHERE name='$c';" 2>/dev/null || echo 0)"
  [ "${has_col:-0}" = "0" ] || return 0
  dxm_log "migrating: ALTER TABLE $t ADD COLUMN $c $decl"
  _dxm_sqlite "ALTER TABLE $t ADD COLUMN $c $decl;" >/dev/null || dxm_die "failed to add column $t.$c" 2
}

# Every additive column migration, applied in order, before schema.sql. Adding
# a nullable column to schema.sql means adding one line here in the same commit.
dxm_migrate_columns() {
  [ -f "$DXM_DB" ] || return 0
  dxm_add_column commits has_body   INTEGER
  dxm_add_column commits body_chars INTEGER
}

dxm_init_db() {
  dxm_require_cmd sqlite3
  mkdir -p "$(dirname "$DXM_DB")" "$DXM_CACHE" "$DXM_OUT"
  [ -f "$DXM_SCHEMA_FILE" ] || dxm_die "schema.sql not found at $DXM_SCHEMA_FILE" 2
  dxm_migrate_columns
  # schema.sql is idempotent (CREATE TABLE IF NOT EXISTS / INSERT OR IGNORE /
  # DROP VIEW + CREATE VIEW), so applying it on every run also repairs views.
  _dxm_sqlite < "$DXM_SCHEMA_FILE" >/dev/null || dxm_die "failed to apply schema" 2
  local have
  have="$(dxm_sql1 "SELECT value FROM schema_meta WHERE key='schema_version';")"
  [ "$have" = "$DXM_SCHEMA_VERSION" ] || \
    dxm_die "schema version mismatch: db=$have expected=$DXM_SCHEMA_VERSION (rebuild the DB)" 2
}

# dxm_repo_id <owner/name> — resolve, creating the row if absent. Echoes repo_id.
dxm_repo_id() {
  local full="$1" owner name
  owner="${full%%/*}"; name="${full#*/}"
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$full" ] || \
    dxm_die "repo must be owner/name, got: $full" 1
  dxm_sql "INSERT OR IGNORE INTO repos(owner,name,full_name) VALUES($(dxm_q "$owner"),$(dxm_q "$name"),$(dxm_q "$full"));"
  dxm_sql1 "SELECT repo_id FROM repos WHERE full_name=$(dxm_q "$full");"
}

# ---------------------------------------------------------------------------
# Run bookkeeping. Every script opens a run and closes it, always.
# ---------------------------------------------------------------------------
# dxm_run_start <script_basename> <args_string> [repo_full_name] -> run_id
# NOTE: the INSERT and last_insert_rowid() MUST share one sqlite3 process --
# rowid state does not survive across connections and you would silently get 0.
dxm_run_start() {
  local script="$1" args="${2-}" repo="${3-}"
  dxm_sql1 "INSERT INTO runs(script,args,repo_full_name,skill_version,host)
            VALUES($(dxm_q "$script"),$(dxm_q "$args"),$(dxm_q "$repo"),$(dxm_q "$DXM_SKILL_VERSION"),$(dxm_q "$(hostname -s 2>/dev/null || echo unknown)"));
            SELECT last_insert_rowid();"
}

# dxm_run_finish <run_id> <status: ok|partial|error> [exit_code] [error_text]
dxm_run_finish() {
  local id="$1" status="$2" code="${3:-0}" err="${4-}"
  dxm_sql "UPDATE runs SET finished_at=strftime('%Y-%m-%dT%H:%M:%SZ','now'),
             status=$(dxm_q "$status"), exit_code=$code, error=$(dxm_q "$err")
           WHERE run_id=$id;"
}

# Install as: trap 'dxm_run_trap $RUN_ID $?' EXIT
# Guarantees no run is left dangling in 'running' when a script dies.
dxm_run_trap() {
  local id="$1" code="${2:-0}"
  local cur; cur="$(dxm_sql1 "SELECT status FROM runs WHERE run_id=$id;")"
  [ "$cur" = "running" ] || return 0
  if [ "$code" -eq 0 ]; then dxm_run_finish "$id" ok 0
  else dxm_run_finish "$id" error "$code" "script exited $code"; fi
}

# ---------------------------------------------------------------------------
# Watermarks — the resumability contract.
# ---------------------------------------------------------------------------
# dxm_watermark_get <repo_id> <source> -> cursor_value, or empty if never ingested
dxm_watermark_get() {
  dxm_sql1 "SELECT COALESCE(cursor_value,'') FROM ingest_watermarks
            WHERE repo_id=$1 AND source=$(dxm_q "$2");"
}

# dxm_watermark_touch <repo_id> <source> <cursor_kind>
# Call BEFORE fetching. Records the attempt without advancing the cursor, so a
# crash is visible as last_attempt_at > last_success_at.
dxm_watermark_touch() {
  dxm_sql "INSERT INTO ingest_watermarks(repo_id,source,cursor_kind,last_attempt_at)
           VALUES($1,$(dxm_q "$2"),$(dxm_q "$3"),strftime('%Y-%m-%dT%H:%M:%SZ','now'))
           ON CONFLICT(repo_id,source) DO UPDATE SET
             last_attempt_at=strftime('%Y-%m-%dT%H:%M:%SZ','now');"
}

# dxm_watermark_set <repo_id> <source> <cursor_kind> <cursor_value> <run_id> <rows_added>
# Call ONLY after a clean, complete pass. A partial pass must leave the cursor
# where it was: re-fetching an overlap is cheap, a hole in the series is not.
dxm_watermark_set() {
  dxm_sql "INSERT INTO ingest_watermarks(repo_id,source,cursor_kind,cursor_value,record_count,last_success_run_id,last_success_at,last_attempt_at)
           VALUES($1,$(dxm_q "$2"),$(dxm_q "$3"),$(dxm_q "$4"),${6:-0},$5,
                  strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'))
           ON CONFLICT(repo_id,source) DO UPDATE SET
             cursor_kind=excluded.cursor_kind,
             cursor_value=excluded.cursor_value,
             record_count=ingest_watermarks.record_count+excluded.record_count,
             last_success_run_id=excluded.last_success_run_id,
             last_success_at=excluded.last_success_at,
             last_attempt_at=excluded.last_attempt_at;"
}

# ---------------------------------------------------------------------------
# Coverage logging — every unit of output declares how it was decided.
# ---------------------------------------------------------------------------
# dxm_coverage <run_id> <unit_kind> <unit_key> <method> [detail]
dxm_coverage() {
  local id="$1" kind="$2" key="$3" method="$4" detail="${5-}"
  case "$method" in script|script-with-fallback|llm) ;; *) dxm_die "bad coverage method: $method" 1 ;; esac
  dxm_sql "INSERT INTO coverage_log(run_id,unit_kind,unit_key,method,detail)
           VALUES($id,$(dxm_q "$kind"),$(dxm_q "$key"),$(dxm_q "$method"),$(dxm_q "$detail"));"
}

# dxm_coverage_batch <run_id> — reads TSV on stdin: unit_kind<TAB>unit_key<TAB>method<TAB>detail
# Use this in loops. One sqlite3 process, not one per unit.
dxm_coverage_batch() {
  local id="$1"
  { echo "BEGIN;"
    while IFS=$'\t' read -r kind key method detail; do
      [ -n "${kind:-}" ] || continue
      printf "INSERT INTO coverage_log(run_id,unit_kind,unit_key,method,detail) VALUES(%s,%s,%s,%s,%s);\n" \
        "$id" "$(dxm_q "$kind")" "$(dxm_q "$key")" "$(dxm_q "$method")" "$(dxm_q "${detail-}")"
    done
    echo "COMMIT;"
  } | dxm_sql_stdin
}

# dxm_coverage_summary <run_id> — this run's coverage as a JSON key/value
# fragment WITHOUT surrounding braces. The coverage formula itself lives in
# v_coverage_by_run (schema.sql) so it is defined exactly once.
dxm_coverage_summary() {
  dxm_sql1 "SELECT printf('\"total\":%d,\"script\":%d,\"script_with_fallback\":%d,\"llm\":%d,\"coverage_pct\":%s',
                    t, s, f, l,
                    CASE WHEN t=0 THEN 'null' ELSE printf('%.1f', 100.0*(s+f)/t) END)
            FROM (SELECT COALESCE(SUM(total),0) AS t,
                         COALESCE(SUM(n_script),0) AS s,
                         COALESCE(SUM(n_script_fallback),0) AS f,
                         COALESCE(SUM(n_llm),0) AS l
                  FROM v_coverage_by_run WHERE run_id=$1);"
}

# ---------------------------------------------------------------------------
# stdout envelope — the ONLY thing a script writes to stdout, once, at the end.
# ---------------------------------------------------------------------------
# dxm_emit <ok:true|false> <script> <run_id> <payload_json_fragment>
# payload_json_fragment is inserted verbatim; it must be valid JSON key/value
# pairs WITHOUT surrounding braces, e.g.  '"repo":"acme/api","commits_new":12'
dxm_emit() {
  local ok="$1" script="$2" run_id="$3" payload="${4-}"
  local cov; cov="$(dxm_coverage_summary "$run_id")"
  [ -n "$cov" ] || cov='"total":0,"script":0,"script_with_fallback":0,"llm":0,"coverage_pct":null'
  printf '{"ok":%s,"script":"%s","run_id":%s,"skill_version":"%s","db":"%s"%s,"coverage":{%s}}\n' \
    "$ok" "$script" "$run_id" "$DXM_SKILL_VERSION" "$DXM_DB" \
    "${payload:+,$payload}" "$cov"
}

# dxm_json_str <value> — JSON-escape a bash string for use inside a payload.
dxm_json_str() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# GitHub CLI. gh carries auth; NEVER write token plumbing.
# Some environments install a gh shim that cannot resolve the target repo from
# cwd — always pass -R owner/repo (or export GH_REPO) on every call.
# ---------------------------------------------------------------------------
#
# DXM_GH — which gh binary to use. Default `gh`, resolved on PATH.
#
# WHY THIS KNOB EXISTS, and it is not a convenience:
#   Some environments put a shim first on PATH that mints a per-repo
#   installation token. Under one, `gh repo list <org>` returned ZERO
#   repositories and exited 0 — a silently empty org that looks exactly like a
#   successful run of a small org. The same command under the operator's own
#   login returned 28. There is no way for the pipeline to tell those two apart
#   after the fact, so the binary has to be selectable and has to be RECORDED.
#
# DXM_GH_CLEAR_TOKENS (default 1) — unset GH_TOKEN / GITHUB_TOKEN for every gh
#   invocation. An ambient token in the environment silently overrides
#   `gh auth login` and re-introduces exactly the scoping problem above. This is
#   not token plumbing (CONTRACT decision 2 forbids that); it is refusing
#   ambient credentials the operator did not choose. Set it to 0 if you really
#   are driving this from a CI token.
: "${DXM_GH:=gh}"
: "${DXM_GH_CLEAR_TOKENS:=1}"
export DXM_GH DXM_GH_CLEAR_TOKENS

# dxm_gh_env — prefix for every gh invocation in this skill.
# Usage:  $(dxm_gh_env) is NOT how to call it; use `dxm_gh_run <args...>`.
dxm_gh_run() {
  if [ "${DXM_GH_CLEAR_TOKENS:-1}" = "1" ]; then
    GH_TOKEN="" GITHUB_TOKEN="" GH_ENTERPRISE_TOKEN="" "$DXM_GH" "$@"
  else
    "$DXM_GH" "$@"
  fi
}

dxm_gh() { GH_REPO="${GH_REPO:-}" dxm_gh_run "$@"; }

# dxm_gh_check — fail fast and loud rather than half-ingesting.
dxm_gh_check() {
  command -v "$DXM_GH" >/dev/null 2>&1 || dxm_die "gh not found at: $DXM_GH (set DXM_GH)" 2
  dxm_gh_run auth status >/dev/null 2>&1 || dxm_warn "gh auth status is not clean; API calls may fail"
}

# dxm_gh_login — the account gh will act as, or empty. Recorded in the doctor
# report and in the run envelope: "which account enumerated the org" is part of
# the provenance of every org-level number this skill produces.
dxm_gh_login() { dxm_gh_run api user --jq '.login' 2>/dev/null || true; }
