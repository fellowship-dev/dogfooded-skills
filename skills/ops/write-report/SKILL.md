---
name: write-report
description: Write a mission report to reports/ — resolves repo-root path, generates timestamped filename per CONVENTIONS.md, posts to Quest DB, and writes fan-out manifests. Use this in every mission to write reports correctly.
user-invocable: true
allowed-tools: Bash, Write, Read
---

# write-report

Write a correctly named, correctly placed mission report and post it to the Quest dashboard. Encapsulates the full boilerplate from CONVENTIONS.md so agents don't copy-paste (or forget) it.

## When to Use

- At the end of every mission to write the mission report
- When writing rollcall team reports
- When writing speckit, deps, review, or crew-runner reports
- When dispatching a fan-out batch and writing the supervisor manifest

## When NOT to Use

- Inside `crew/*/` subdirectories — all reports go to repo root `reports/`
- For another team's report — each agent writes its own

## Invocation Examples

```bash
# Standard mission report
/write-report --group crew-runner --id "fellowship-dev-navvi-42" --type crew-runner

# Rollcall team report
/write-report --group rollcall --id lexgo --type rollcall

# Fan-out manifest (written at dispatch time by supervisor)
/write-report --manifest --group rollcall --jobs "lexgo:pending,tooling:pending,navvi:pending"
```

## Workflow

### Step 1: Resolve the report directory

Always resolve from git repo root — NEVER hardcode or use `crew/*/`:

```bash
REPORT_DIR="$(git rev-parse --show-toplevel)/reports"
```

If `git rev-parse` fails, you are not in a git repo. `cd` to the correct project root and retry.

### Step 2: Generate the filename

All timestamps are UTC:

```bash
TIMESTAMP=$(date -u +"%Y%m%d-%H%M")
```

Filename patterns:

| Report type | Filename |
|---|---|
| Standard (speckit, deps, review, crew-runner) | `{TIMESTAMP}_{group}_{id}.md` |
| Rollcall team | `{TIMESTAMP}_rollcall_{team}.md` |
| Rollcall assembly | `{TIMESTAMP}_rollcall_assembly.md` |
| Fan-out manifest | `{TIMESTAMP}_{group}_manifest.json` |

Examples:
```
20260413-1100_rollcall_lexgo.md
20260413-1115_crew-runner_fellowship-dev-navvi-42.md
20260413-1100_rollcall_manifest.json
```

### Step 3: Write the file

**For markdown reports** — use the Write tool if available, otherwise fall back to Bash:

```
REPORT_PATH="${REPORT_DIR}/${TIMESTAMP}_${GROUP}_${ID}.md"
```

Write the full report content to that path. If the Write tool is not in your `allowed-tools` (e.g., CEO/CTO roles), use Bash instead:

```bash
cat > "$REPORT_PATH" << 'REPORT_EOF'
[report content here]
REPORT_EOF
```

**For fan-out manifests** (`--manifest` flag):

```bash
MANIFEST_PATH="${REPORT_DIR}/${TIMESTAMP}_${GROUP}_manifest.json"
```

Required JSON structure (all fields mandatory):

```json
{
  "group_id": "{group}-{YYYYMMDD}-{HHMM}",
  "origin_job": "~/.local/share/pylot/missions/done/{job-file}.job",
  "jobs": {
    "job-id-1": "pending",
    "job-id-2": "pending"
  },
  "created_at": "2026-04-13T11:00:00Z"
}
```

Parse the `--jobs` argument (format: `"id1:state1,id2:state2,..."`):

```bash
python3 -c "
import json, sys
jobs_str = sys.argv[1]
jobs = {}
for pair in jobs_str.split(','):
    job_id, state = pair.strip().split(':')
    jobs[job_id.strip()] = state.strip()
manifest = {
    'group_id': sys.argv[2],
    'origin_job': sys.argv[3] if len(sys.argv) > 3 else 'unknown',
    'jobs': jobs,
    'created_at': sys.argv[4]
}
print(json.dumps(manifest, indent=2))
" "$JOBS_ARG" "${GROUP}-${YYYYMMDD}-${HHMM}" "${ORIGIN_JOB:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MANIFEST_PATH"
```

**Job states:** `pending` · `done` · `failed`

### Step 4: Post to Quest DB

Always attempt — skip silently on failure. Manifests are NOT posted, only `.md` reports:

```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' /Users/maxfindel/Projects/claude-buddy/.env | cut -d= -f2)
curl -s -X POST "http://127.0.0.1:4242/api/event" \
  -H "Authorization: Bearer $QUEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
content = open('$REPORT_PATH').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': '$REPORT_TITLE',
  'meta': {'content': content, 'report_type': '$GROUP'}
}))
")" 2>/dev/null || true
```

### Step 5: Commit and push

```bash
cd "$(git rev-parse --show-toplevel)"
git add reports/
git commit -m "report: ${GROUP} ${ID}"
git push
```

## Error Handling

**`git rev-parse` fails** — not in a git repo. `cd` to the correct project root before invoking.

**Quest unreachable** — expected in offline/pod environments. The `|| true` guard handles this. Do not retry.

**`--jobs` parse error** — malformed jobs string. Expected: `"id1:state1,id2:state2"`. Each pair needs exactly one `:` separator.

**File already exists** — Write tool will overwrite. If writing multiple reports in the same minute, append a suffix to `ID`.

## Critical Rules

- **NEVER write to `crew/*/`** — resolve path from `git rev-parse --show-toplevel`
- **All timestamps in UTC** — always use `date -u`
- **Manifests are NOT posted to Quest** — only `.md` files get posted
- **Workers write their own reports** — never write another team's report
- **Quest skip must be silent** — `|| true` is required, not optional
