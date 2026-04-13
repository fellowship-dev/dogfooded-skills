---
name: distill
description: Post-mission audit and distillation — capture mode classifies a completed mission using an 8-code failure taxonomy and writes an audit JSON; analyze mode aggregates audit JSONs into a findings report and creates GitHub issues with recommendations.
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

# distill

Post-mission audit and distillation for crew operations. Two modes:

- **capture** — reads a session JSONL + mission report, classifies failure incidents using the 8-code taxonomy, outputs a structured audit JSON co-located with the report
- **analyze** — reads all audit JSONs in `reports/`, aggregates trends, produces a findings report and GitHub issues with recommendations

## When to Use

- **capture**: after every mission (pass or fail) — triggered by the poller as a follow-up mission
- **analyze**: weekly via cron, or manually to survey trends across missions
- Skip capture if `{report-name}-audit.json` already exists — idempotent guard

## Prerequisites

```bash
gh auth status                          # needed for analyze mode
python3 --version                       # needed for JSONL parsing
ls ~/.claude/projects/                  # session JSONL files must be accessible
```

## Failure Taxonomy

| Code | Name | Origin | JSONL Signal |
|------|------|--------|--------------|
| SV | Speed Over Verification | Meiklejohn | Bash/Write actions with no curl/`gh pr view`/test calls after |
| MB | Memory Without Behavioral Change | Meiklejohn | RULES.md or skill Read early in session; same domain errors appear later |
| SF | Silent Failure Suppression | Meiklejohn | `is_error: true` tool results not followed by error-recovery Bash calls |
| UA | User Model Absence | Meiklejohn | Deploy/publish task; no curl HTTP 200 verification in session |
| UB | Uncertainty Blindness | Meiklejohn | `--force` flags, skipped checks, or assumed paths without grep/read confirm |
| ID | Intent Drift | Ours | Write/Edit calls to paths outside original task scope |
| SG | Skill Gap | Ours | ENOENT/command-not-found errors, or domain tool failures with no skill loaded |
| CF | Coordination Failure | Ours | Agent tool called 3+ times for same deliverable (worker retries) |

Use code `??` for incidents that don't fit any category — `??` frequency feeds taxonomy evolution in analyze mode.

---

## capture Mode

### Invocation

```bash
/distill capture reports/2026-04-12-speckit-fellowship-dev-myrepo-branch.md
/distill capture reports/2026-04-12-speckit-fellowship-dev-myrepo-branch.md --session abc123-uuid
```

### Step 1: Guard — already captured?

Check if the audit file already exists. Presence = skip.

```bash
REPORT="$1"
AUDIT="${REPORT%.md}-audit.json"

if [ -f "$AUDIT" ]; then
  echo "Already captured: $AUDIT — skipping"
  exit 0
fi

if [ ! -f "$REPORT" ]; then
  echo "ERROR: Report not found: $REPORT"
  exit 1
fi
```

### Step 2: Resolve the JSONL session file

The agent writes session transcripts to `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.

The encoded path is the `cwd` with every `/` replaced by `-` and the leading `/` stripped:
- `/Users/maxfindel/Projects/fellowship-dev/commander` → `-Users-maxfindel-Projects-fellowship-dev-commander`

**If `--session <id>` provided:**

```bash
ENCODED_CWD=$(pwd | sed 's|/|-|g' | sed 's|^-||')
SESSIONS_DIR="$HOME/.claude/projects/$ENCODED_CWD"
JSONL="$SESSIONS_DIR/${SESSION_ARG}.jsonl"

if [ ! -f "$JSONL" ]; then
  echo "WARN: Session file not found: $JSONL — proceeding with report-only audit"
  JSONL=""
fi
```

**If no session provided — infer by report date:**

```bash
REPORT_DATE=$(basename "$REPORT" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
ENCODED_CWD=$(pwd | sed 's|/|-|g' | sed 's|^-||')
SESSIONS_DIR="$HOME/.claude/projects/$ENCODED_CWD"

# Find JSONL modified on the report date; fall back to most recent
JSONL=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | while IFS= read -r f; do
  # macOS: date -r; Linux: stat -c
  MOD_DATE=$(date -r "$f" +%Y-%m-%d 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -d' ' -f1)
  [ "$MOD_DATE" = "$REPORT_DATE" ] && echo "$f" && break
done | head -1)

# Fallback: most recent session regardless of date
[ -z "$JSONL" ] && JSONL=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1)

[ -z "$JSONL" ] && echo "WARN: No JSONL found in $SESSIONS_DIR — proceeding without session data"
```

### Step 3: Count JSONL lines and decide chunking

```bash
if [ -n "$JSONL" ] && [ -f "$JSONL" ]; then
  LINE_COUNT=$(wc -l < "$JSONL")
  CHUNK_THRESHOLD=2000
  echo "Session: $JSONL ($LINE_COUNT lines)"
else
  LINE_COUNT=0
fi
```

### Step 4: Parse JSONL — extract signals

**If LINE_COUNT ≤ 2000 — parse directly:**

Write the signals extraction script to a temp file and run it:

```bash
cat > /tmp/distill_parse.py << 'PYEOF'
import json, re, sys, collections

path = sys.argv[1]
signals = {
    "session_id": None,
    "session_complete": True,
    "start_ts": None,
    "end_ts": None,
    "tool_counts": {},
    "error_tool_results": [],
    "workers_spawned": 0,
    "skills_loaded": [],
    "verification_calls": [],
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "original_prompt": None,
    "write_paths": [],
    "bash_calls": [],
    "git_signals": {
        "branch_created": False,
        "pushed": False,
        "push_force": False,
        "pr_created": False,
        "issue_closed": False,
        "committed_to_main": False,
        "push_verified": False
    }
}
tool_counts = collections.Counter()

try:
    with open(path) as f:
        lines = f.readlines()
except Exception as e:
    signals["session_complete"] = False
    print(json.dumps(signals))
    sys.exit(0)

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        signals["session_complete"] = False
        continue

    if not signals["session_id"] and entry.get("sessionId"):
        signals["session_id"] = entry["sessionId"]

    ts = entry.get("timestamp")
    if ts:
        if not signals["start_ts"]:
            signals["start_ts"] = ts
        signals["end_ts"] = ts

    # Original prompt — first user message with string content
    if (not signals["original_prompt"] and
            entry.get("type") == "user" and
            isinstance(entry.get("message"), dict) and
            entry["message"].get("role") == "user"):
        content = entry["message"].get("content", "")
        if isinstance(content, str) and len(content) > 10:
            signals["original_prompt"] = content[:500]

    # Tool use blocks from assistant messages
    if entry.get("type") == "assistant":
        msg = entry.get("message", {})
        usage = msg.get("usage", {})
        signals["total_input_tokens"] += usage.get("input_tokens", 0)
        signals["total_output_tokens"] += usage.get("output_tokens", 0)

        for block in msg.get("content", []):
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            tool = block.get("name", "")
            tool_counts[tool] += 1
            inp = block.get("input", {})

            if tool == "Agent":
                signals["workers_spawned"] += 1

            elif tool == "Read":
                path_val = str(inp.get("file_path", ""))
                if ".claude/skills" in path_val:
                    parts = path_val.split(".claude/skills/")
                    if len(parts) > 1:
                        skill_name = parts[1].split("/")[0]
                        if skill_name and skill_name not in signals["skills_loaded"]:
                            signals["skills_loaded"].append(skill_name)

            elif tool == "Bash":
                cmd = inp.get("command", "")
                signals["bash_calls"].append(cmd[:300])
                if any(v in cmd for v in ["curl ", "gh pr view", "gh pr merge", "gh pr list", "gh run"]):
                    signals["verification_calls"].append(cmd[:200])
                # Git workflow signals
                gs = signals["git_signals"]
                if re.search(r'git\s+(checkout\s+-b|switch\s+-c)', cmd):
                    gs["branch_created"] = True
                if re.search(r'git\s+push', cmd):
                    if "--force" in cmd or " -f " in cmd:
                        gs["push_force"] = True
                    gs["pushed"] = True
                if "gh pr create" in cmd:
                    gs["pr_created"] = True
                if "gh issue close" in cmd.lower():
                    gs["issue_closed"] = True
                if (re.search(r'git\s+log.*--remotes', cmd) or
                        re.search(r'gh\s+api.*commits/', cmd) or
                        re.search(r'git\s+log.*origin/', cmd)):
                    gs["push_verified"] = True

            elif tool == "Write":
                fp = str(inp.get("file_path", ""))
                signals["write_paths"].append(fp)

    # Tool results with errors
    if entry.get("type") == "user":
        content = entry.get("message", {}).get("content", [])
        if isinstance(content, list):
            for block in content:
                if (isinstance(block, dict) and
                        block.get("type") == "tool_result" and
                        block.get("is_error")):
                    err_text = str(block.get("content", ""))[:300]
                    signals["error_tool_results"].append(err_text)

# committed_to_main: git commit found but no feature branch created in session
if any(re.search(r'git\s+commit', b) for b in signals["bash_calls"]):
    signals["git_signals"]["committed_to_main"] = not signals["git_signals"]["branch_created"]

signals["tool_counts"] = dict(tool_counts)
print(json.dumps(signals, default=str))
PYEOF

SIGNALS=$(python3 /tmp/distill_parse.py "$JSONL")
echo "Signals extracted."
```

**If LINE_COUNT > 2000 — chunk via subagents:**

Split into 2000-line chunks and spawn one subagent per chunk. Each subagent runs the same `distill_parse.py` on its chunk. Merge results: sum token counts, concatenate lists, union skills.

```bash
CHUNK_DIR=$(mktemp -d /tmp/distill_chunks_XXXX)
split -l 2000 "$JSONL" "$CHUNK_DIR/chunk_"

# Spawn one subagent per chunk, collect JSON signals
MERGED_SIGNALS='{"session_id":null,"start_ts":null,"end_ts":null,"tool_counts":{},"error_tool_results":[],"workers_spawned":0,"skills_loaded":[],"verification_calls":[],"total_input_tokens":0,"total_output_tokens":0,"original_prompt":null,"write_paths":[],"bash_calls":[],"git_signals":{"branch_created":false,"pushed":false,"push_force":false,"pr_created":false,"issue_closed":false,"committed_to_main":false,"push_verified":false},"session_complete":true}'

for chunk in "$CHUNK_DIR"/chunk_*; do
  # Each subagent: run distill_parse.py on chunk, return JSON
  # Merge into MERGED_SIGNALS using python3 merge script
  :
done
```

Use Agent tool to spawn one subagent per chunk with instructions: "Run `python3 /tmp/distill_parse.py {chunk_path}` and return the JSON output verbatim."

Merge all chunk signals with:

```python
# merge_signals.py
import json, sys, collections

chunks = [json.loads(line) for line in sys.stdin]
merged = {
    "session_id": next((c["session_id"] for c in chunks if c.get("session_id")), None),
    "start_ts": min((c["start_ts"] for c in chunks if c.get("start_ts")), default=None),
    "end_ts": max((c["end_ts"] for c in chunks if c.get("end_ts")), default=None),
    "tool_counts": dict(sum((collections.Counter(c.get("tool_counts", {})) for c in chunks), collections.Counter())),
    "error_tool_results": sum((c.get("error_tool_results", []) for c in chunks), []),
    "workers_spawned": sum(c.get("workers_spawned", 0) for c in chunks),
    "skills_loaded": list(set(sum((c.get("skills_loaded", []) for c in chunks), []))),
    "verification_calls": sum((c.get("verification_calls", []) for c in chunks), []),
    "total_input_tokens": sum(c.get("total_input_tokens", 0) for c in chunks),
    "total_output_tokens": sum(c.get("total_output_tokens", 0) for c in chunks),
    "original_prompt": next((c["original_prompt"] for c in chunks if c.get("original_prompt")), None),
    "write_paths": sum((c.get("write_paths", []) for c in chunks), []),
    "bash_calls": sum((c.get("bash_calls", []) for c in chunks), []),
    "git_signals": {
        k: any(c.get("git_signals", {}).get(k, False) for c in chunks)
        for k in ["branch_created", "pushed", "push_force", "pr_created",
                  "issue_closed", "committed_to_main", "push_verified"]
    },
    "session_complete": all(c.get("session_complete", True) for c in chunks)
}
print(json.dumps(merged))
```

### Step 5: Extract metadata from mission report

```bash
TASK_SUMMARY=$(grep -m1 "^# Mission:" "$REPORT" | sed 's/^# Mission: //' | head -c 200)
[ -z "$TASK_SUMMARY" ] && TASK_SUMMARY=$(head -1 "$REPORT" | sed 's/^# //')

OUTCOME=$(grep -m1 "^\*\*Status\*\*:" "$REPORT" | sed 's/\*\*Status\*\*: *//' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
[ -z "$OUTCOME" ] && OUTCOME="unknown"

CREW=$(basename "$(pwd)")
REPORT_DATE=$(basename "$REPORT" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
```

Compute duration from `start_ts` and `end_ts` in signals:

```python
from datetime import datetime
start = datetime.fromisoformat(start_ts.replace("Z", "+00:00"))
end = datetime.fromisoformat(end_ts.replace("Z", "+00:00"))
duration_minutes = round((end - start).total_seconds() / 60)
```

Compute cost estimate (Sonnet 4.6 rates as of 2026-04: $3/MTok input, $15/MTok output):

```python
cost_usd = round(
    (total_input_tokens / 1_000_000 * 3.0) +
    (total_output_tokens / 1_000_000 * 15.0),
    2
)
```

### Step 6: Classify incidents

Apply taxonomy rules to the extracted signals. Produce an `incidents` array.

Write and run the classifier:

```bash
cat > /tmp/distill_classify.py << 'PYEOF'
import json, sys

signals = json.loads(sys.argv[1])
report_text = open(sys.argv[2]).read().lower()

tool_counts = signals.get("tool_counts", {})
bash_calls = signals.get("bash_calls", [])
bash_all = " ".join(bash_calls).lower()
error_results = signals.get("error_tool_results", [])
write_paths = signals.get("write_paths", [])
verification_calls = signals.get("verification_calls", [])
workers_spawned = signals.get("workers_spawned", 0)
skills_loaded = signals.get("skills_loaded", [])
original_prompt = (signals.get("original_prompt") or "").lower()
git_signals = signals.get("git_signals", {})

incidents = []
what_worked = []
missed_opportunity = ""

# SV: Speed Over Verification
# Signal: significant tool activity but no verification calls
action_count = (tool_counts.get("Bash", 0) + tool_counts.get("Edit", 0) +
                tool_counts.get("Write", 0) + tool_counts.get("Agent", 0))
if action_count > 5 and len(verification_calls) == 0:
    incidents.append({
        "code": "SV",
        "description": "Significant activity with no verification calls (curl/gh pr view)",
        "evidence": f"{action_count} action tool calls, {len(verification_calls)} verification calls"
    })

# MB: Memory Without Behavioral Change
# Signal: skills or rules were loaded but error patterns suggest they were ignored
rules_read = any("rules.md" in b.lower() for b in bash_calls) or \
             any("rules" in p.lower() for p in write_paths)
if rules_read and len(error_results) >= 2:
    incidents.append({
        "code": "MB",
        "description": "RULES.md was read but error patterns suggest rules were deprioritized",
        "evidence": f"RULES.md accessed, {len(error_results)} error tool results in session"
    })

# SF: Silent Failure Suppression
# Signal: multiple errors encountered; no recovery bash calls follow
if len(error_results) >= 2:
    # Check if there are bash calls after the errors
    # This is a heuristic: if errors exist and no verification, flag it
    recovery_indicators = ["retry", "fix", "debug", "error", "fail"]
    recovery_bash = [b for b in bash_calls if any(r in b.lower() for r in recovery_indicators)]
    if len(recovery_bash) == 0:
        incidents.append({
            "code": "SF",
            "description": "Multiple tool errors without visible recovery steps",
            "evidence": f"{len(error_results)} error results: {'; '.join(error_results[:2])[:200]}"
        })

# UA: User Model Absence
# Signal: deploy/publish task with no HTTP 200 check
deploy_keywords = ["deploy", "publish", "vercel", "heroku", "production", "live"]
is_deploy_task = any(kw in original_prompt for kw in deploy_keywords)
if is_deploy_task and "curl" not in bash_all:
    incidents.append({
        "code": "UA",
        "description": "Deploy/publish task with no HTTP response verification",
        "evidence": "Task involves deploy; no curl call found in session"
    })

# UB: Uncertainty Blindness
# Signal: --force flags, --skip flags, or --no-verify in bash calls
force_calls = [b for b in bash_calls if any(f in b for f in ["--force", "--no-verify", "--skip", "-f "])]
if force_calls:
    incidents.append({
        "code": "UB",
        "description": "Force flags or verification skips used without documented rationale",
        "evidence": f"{len(force_calls)} commands with force/skip flags: {force_calls[0][:150]}"
    })

# ID: Intent Drift
# Signal: Write calls to paths outside expected scope (reports, src dirs unrelated to task)
if write_paths:
    task_hint = original_prompt[:100]
    unexpected_writes = [p for p in write_paths
                        if not any(kw in p.lower() for kw in ["reports/", "tmp/", ".claude/"])]
    if len(unexpected_writes) > 3:
        incidents.append({
            "code": "ID",
            "description": "Write calls suggest scope creep beyond original task",
            "evidence": f"{len(unexpected_writes)} write calls outside expected paths: {', '.join(unexpected_writes[:3])}"
        })

# SG: Skill Gap
# Signal: ENOENT, command not found, or domain-specific tool failures
gap_patterns = ["enoent", "command not found", "no such file", "not installed", "permission denied"]
gap_errors = [e for e in error_results if any(p in e.lower() for p in gap_patterns)]
if gap_errors:
    incidents.append({
        "code": "SG",
        "description": "Tool or command failures suggesting missing capability or setup",
        "evidence": f"{len(gap_errors)} errors: {gap_errors[0][:200]}"
    })

# CF: Coordination Failure
# Signal: Agent tool called 3+ times (worker retries)
if workers_spawned >= 3:
    incidents.append({
        "code": "CF",
        "description": f"Agent spawned {workers_spawned} times — suggests worker retry loops or coordination issues",
        "evidence": f"{workers_spawned} Agent tool calls in session"
    })

# Git workflow classification rules
has_git_commit = any("git commit" in b.lower() for b in bash_calls)

# SV: committed to main without PR — skipped review entirely
if git_signals.get("committed_to_main") and not git_signals.get("pr_created"):
    incidents.append({
        "code": "SV",
        "description": "Committed directly to main without creating a feature branch or PR",
        "evidence": "git commit detected, no branch created, no gh pr create in session"
    })

# SF: committed but never pushed — work trapped locally
if has_git_commit and not git_signals.get("pushed"):
    incidents.append({
        "code": "SF",
        "description": "Committed but never pushed — work never reached the remote",
        "evidence": "git commit found in session but no git push detected"
    })

# UA: closed issue without verifying the push landed on remote
if git_signals.get("issue_closed") and not git_signals.get("push_verified"):
    incidents.append({
        "code": "UA",
        "description": "Issue closed without verifying commit exists on remote",
        "evidence": "gh issue close detected but no git log --remotes or gh api commit check found"
    })

# UB: force-pushed without documented rationale (git push --force)
if git_signals.get("push_force"):
    incidents.append({
        "code": "UB",
        "description": "Force-pushed without documented rationale",
        "evidence": "git push --force detected in session"
    })

# Determine what worked (heuristic from tool activity)
if len(verification_calls) > 0:
    what_worked.append(f"Verification steps executed ({len(verification_calls)} calls)")
if skills_loaded:
    what_worked.append(f"Skills loaded: {', '.join(skills_loaded)}")
if tool_counts.get("Agent", 0) > 0 and workers_spawned < 3:
    what_worked.append(f"Workers deployed efficiently ({workers_spawned} spawned)")
if not incidents:
    what_worked.append("No failure patterns detected")

# Missed opportunity hint
incident_codes_found = [i["code"] for i in incidents]
if "SF" in incident_codes_found and not git_signals.get("pushed"):
    missed_opportunity = "Committed but never pushed — add git push after every commit, then verify with git log --remotes"
elif "SV" in incident_codes_found and git_signals.get("committed_to_main"):
    missed_opportunity = "Create a feature branch before committing — git checkout -b feat/... then open a PR"
elif "UA" in incident_codes_found and git_signals.get("issue_closed"):
    missed_opportunity = "Verify the commit is on the remote before closing the issue — gh api repos/{owner}/{repo}/commits/{sha}"
elif "SV" in incident_codes_found:
    missed_opportunity = "Add verification step before exit — curl or gh pr view would confirm success"
elif "SG" in incident_codes_found:
    missed_opportunity = "Load the relevant skill before attempting the domain operation"
elif "UA" in incident_codes_found:
    missed_opportunity = "curl production URL after deploy — HTTP 200 is the only real success signal"

result = {
    "incidents": incidents,
    "what_worked": what_worked,
    "missed_opportunity": missed_opportunity
}
print(json.dumps(result))
PYEOF

CLASSIFIED=$(python3 /tmp/distill_classify.py "$SIGNALS" "$REPORT")
```

### Step 7: Extract rules compliance

```bash
python3 << PYEOF
import json, sys

signals = json.loads('''$SIGNALS''')
tool_counts = signals.get("tool_counts", {})
bash_calls = signals.get("bash_calls", [])
write_paths = signals.get("write_paths", [])
skills_loaded = signals.get("skills_loaded", [])
verification_calls = signals.get("verification_calls", [])
git_signals = signals.get("git_signals", {})

bash_all = " ".join(bash_calls).lower()
original_prompt = (signals.get("original_prompt") or "").lower()
is_feature = any(kw in original_prompt for kw in
                 ["implement", "feature", "add", "build", "create", "fix", "update"])

compliance = {
    "R1_headless": "AskUserQuestion" not in tool_counts,
    "R3_no_code": ("Edit" not in tool_counts and
                   not any("src/" in p or "app/" in p for p in write_paths)),
    "R4_read_skills": len(skills_loaded) > 0,
    "R6_verify": len(verification_calls) > 0,
    "R7_report": any("reports/" in p for p in write_paths),
    "R_branch": git_signals.get("branch_created", False),
    "R_push": git_signals.get("pushed", False),
    "R_pr": git_signals.get("pr_created", False) or not is_feature
}
print(json.dumps(compliance))
PYEOF
```

### Step 8: Build and write audit JSON

Use python3 to assemble the final audit JSON cleanly:

```bash
python3 << PYEOF
import json, sys
from datetime import datetime, timezone

signals = json.loads('''$SIGNALS''')
classified = json.loads('''$CLASSIFIED''')
compliance = json.loads('''$COMPLIANCE''')

# Duration
start_ts = signals.get("start_ts")
end_ts = signals.get("end_ts")
duration_minutes = 0
if start_ts and end_ts:
    try:
        start = datetime.fromisoformat(start_ts.replace("Z", "+00:00"))
        end = datetime.fromisoformat(end_ts.replace("Z", "+00:00"))
        duration_minutes = round((end - start).total_seconds() / 60)
    except:
        pass

# Cost estimate (Sonnet 4.6: $3/MTok input, $15/MTok output)
input_tok = signals.get("total_input_tokens", 0)
output_tok = signals.get("total_output_tokens", 0)
cost_usd = round((input_tok / 1_000_000 * 3.0) + (output_tok / 1_000_000 * 15.0), 2)

audit = {
    "job_id": "$REPORT_JOB_ID",
    "date": "$REPORT_DATE",
    "crew": "$CREW",
    "task_summary": "$TASK_SUMMARY",
    "outcome": "$OUTCOME",
    "session_id": signals.get("session_id"),
    "session_complete": signals.get("session_complete", True),
    "duration_minutes": duration_minutes,
    "cost_usd": cost_usd,
    "token_usage": {"input": input_tok, "output": output_tok},
    "workers_spawned": signals.get("workers_spawned", 0),
    "skills_loaded": signals.get("skills_loaded", []),
    "rules_compliance": compliance,
    "incidents": classified.get("incidents", []),
    "what_worked": classified.get("what_worked", []),
    "missed_opportunity": classified.get("missed_opportunity", "")
}

print(json.dumps(audit, indent=2))
PYEOF > "$AUDIT"

echo "Audit written: $AUDIT"
python3 -m json.tool "$AUDIT" > /dev/null && echo "JSON valid" || echo "WARN: JSON validation failed"
```

Replace `$REPORT_JOB_ID` with `$(basename "$REPORT" .md)` before running.

---

## analyze Mode

### Invocation

```bash
/distill analyze
/distill analyze --since today
/distill analyze --since 2026-03-01
/distill analyze --repo fellowship-dev/commander --since 2026-04-01
```

### Step 1: Find audit JSONs

```bash
SINCE_DATE="${SINCE_ARG:-}"
# Resolve "today" keyword to current date
if [ "$SINCE_DATE" = "today" ]; then
  SINCE_DATE=$(date +%Y-%m-%d)
fi
REPORTS_DIR="reports"

mapfile -t AUDIT_FILES < <(
  find "$REPORTS_DIR" -name "*-audit.json" 2>/dev/null | sort |
  while IFS= read -r f; do
    if [ -n "$SINCE_DATE" ]; then
      FILE_DATE=$(basename "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
      [[ "$FILE_DATE" < "$SINCE_DATE" ]] && continue
    fi
    echo "$f"
  done
)

echo "Found ${#AUDIT_FILES[@]} audit files"
if [ "${#AUDIT_FILES[@]}" -eq 0 ]; then
  TODAY=$(date +%Y-%m-%d)
  STUB_REPORT="reports/${TODAY}-distill-analyze.md"
  printf "# Distill Analysis — %s\n\nNo missions captured today. No audit files found.\n" "$TODAY" > "$STUB_REPORT"
  echo "Stub report written: $STUB_REPORT"
  exit 0
fi
```

### Step 2: Aggregate signals

```bash
cat > /tmp/distill_aggregate.py << 'PYEOF'
import json, sys, collections
from pathlib import Path

audit_paths = sys.argv[1:]
audits = []
for path in audit_paths:
    try:
        with open(path) as f:
            audits.append((path, json.load(f)))
    except Exception as e:
        print(f"WARN: skipping {path}: {e}", file=sys.stderr)

if not audits:
    print(json.dumps({"error": "no audits loaded"}))
    sys.exit(1)

incident_codes = collections.Counter()
incident_evidence = collections.defaultdict(list)
rule_compliance = collections.defaultdict(list)
costs = []
durations = []
outcomes = collections.Counter()
unknown_incidents = []
skills_across = collections.Counter()

for path, audit in audits:
    report_base = Path(path).stem.replace("-audit", "")

    for inc in audit.get("incidents", []):
        code = inc.get("code", "??")
        incident_codes[code] += 1
        incident_evidence[code].append({
            "audit": path,
            "description": inc.get("description", ""),
            "evidence": inc.get("evidence", "")
        })
        if code == "??":
            unknown_incidents.append({"audit": path, "description": inc.get("description", "")})

    for rule, val in audit.get("rules_compliance", {}).items():
        rule_compliance[rule].append(bool(val))

    cost = audit.get("cost_usd")
    if cost is not None:
        costs.append(cost)

    dur = audit.get("duration_minutes")
    if dur is not None:
        durations.append(dur)

    outcomes[audit.get("outcome", "unknown")] += 1

    for skill in audit.get("skills_loaded", []):
        skills_across[skill] += 1

# Compliance rates
compliance_rates = {}
for rule, values in rule_compliance.items():
    if values:
        compliance_rates[rule] = round(sum(values) / len(values) * 100, 1)

# Recommendations: codes appearing >= 2 times
RECOMMENDATION_MAP = {
    "SV": {
        "type": "rule",
        "title": "Enforce verification gate before mission exit",
        "fix": "Strengthen R6 in RULES.md — add explicit checklist: curl URL, gh pr view, or test run before exit. No exceptions."
    },
    "MB": {
        "type": "rule",
        "title": "Rules-read must produce behavioral change",
        "fix": "Add R4 addendum: after reading RULES.md, lead must log a one-line acknowledgment per rule violated in prior missions. Cognitive activation, not passive reading."
    },
    "SF": {
        "type": "rule",
        "title": "Error recovery is mandatory, not optional",
        "fix": "Add R5 error protocol: any is_error=true result triggers a mandatory investigation step before proceeding. Never continue past an error without a documented recovery."
    },
    "UA": {
        "type": "rule",
        "title": "User-facing deploys require HTTP 200 verification",
        "fix": "Extend R6 verification table: deploy tasks must include curl production URL with expected 200 response before marking done."
    },
    "UB": {
        "type": "rule",
        "title": "Uncertainty must be resolved before acting",
        "fix": "Add uncertainty protocol to RULES.md: when unsure about state, grep/read first. Never assume. Force flags require explicit justification comment in Bash command."
    },
    "ID": {
        "type": "skill",
        "title": "Task scope guard — restate original task at each phase",
        "fix": "New skill: task-scope-guard. At each phase, lead restates original task and compares current actions. If drift detected, stop and re-anchor."
    },
    "SG": {
        "type": "skill",
        "title": "Domain skill gap — build missing capability",
        "fix": "Identify the specific domain where tool failures occurred and author a new skill covering the operational commands, gotchas, and verification steps."
    },
    "CF": {
        "type": "rule",
        "title": "Worker selection must be deliberate",
        "fix": "Add R4 worker selection matrix: lead must consult worker capabilities table before spawning. Retries > 2 = wrong worker, not wrong instructions."
    }
}

recommendations = []
for code, count in incident_codes.most_common():
    if code == "??" or count < 2:
        continue
    rec = RECOMMENDATION_MAP.get(code, {
        "type": "skill",
        "title": f"Address {code} failure pattern",
        "fix": "Review incidents and define a concrete fix."
    })
    recommendations.append({
        "code": code,
        "count": count,
        "pct": round(count / len(audits) * 100, 1),
        "type": rec["type"],
        "title": rec["title"],
        "fix": rec["fix"],
        "evidence": incident_evidence[code]
    })

result = {
    "total_audits": len(audits),
    "date_range": {
        "first": min((Path(p).stem[:10] for p, _ in audits), default=""),
        "last": max((Path(p).stem[:10] for p, _ in audits), default="")
    },
    "outcomes": dict(outcomes),
    "incident_codes": dict(incident_codes),
    "compliance_rates": compliance_rates,
    "total_cost_usd": round(sum(costs), 2),
    "avg_cost_usd": round(sum(costs) / len(costs), 2) if costs else 0,
    "avg_duration_minutes": round(sum(durations) / len(durations), 1) if durations else 0,
    "top_skills": dict(skills_across.most_common(10)),
    "recommendations": recommendations,
    "unknown_incidents": unknown_incidents
}
print(json.dumps(result, indent=2))
PYEOF

AGGREGATE=$(python3 /tmp/distill_aggregate.py "${AUDIT_FILES[@]}")
```

### Step 3: Write findings report

```bash
TODAY=$(date +%Y-%m-%d)
FINDINGS_REPORT="reports/${TODAY}-distill-analyze.md"

python3 << PYEOF > "$FINDINGS_REPORT"
import json, sys

agg = json.loads('''$AGGREGATE''')
today = "$TODAY"

lines = [
    f"# Distill Analysis — {today}",
    "",
    f"**Audits analyzed**: {agg['total_audits']}  ",
    f"**Date range**: {agg['date_range']['first']} to {agg['date_range']['last']}  ",
    f"**Total cost tracked**: \${agg['total_cost_usd']}  ",
    f"**Avg cost/mission**: \${agg['avg_cost_usd']}  ",
    f"**Avg duration**: {agg['avg_duration_minutes']} min  ",
    "",
    "## Mission Outcomes",
    "",
    "| Outcome | Count |",
    "|---------|-------|",
]
for outcome, count in agg["outcomes"].items():
    lines.append(f"| {outcome} | {count} |")

lines += [
    "",
    "## Failure Mode Frequency",
    "",
    "| Code | Name | Count | % of Missions |",
    "|------|------|-------|---------------|",
]
CODE_NAMES = {
    "SV": "Speed Over Verification", "MB": "Memory Without Behavioral Change",
    "SF": "Silent Failure Suppression", "UA": "User Model Absence",
    "UB": "Uncertainty Blindness", "ID": "Intent Drift",
    "SG": "Skill Gap", "CF": "Coordination Failure", "??": "Unclassified"
}
for code, count in sorted(agg["incident_codes"].items(), key=lambda x: -x[1]):
    pct = round(count / agg["total_audits"] * 100, 1)
    name = CODE_NAMES.get(code, code)
    lines.append(f"| {code} | {name} | {count} | {pct}% |")

lines += [
    "",
    "## Rule Compliance Rates",
    "",
    "| Rule | Compliance Rate |",
    "|------|----------------|",
]
for rule, rate in sorted(agg["compliance_rates"].items()):
    flag = "✅" if rate >= 80 else ("⚠️" if rate >= 50 else "❌")
    lines.append(f"| {rule} | {rate}% {flag} |")

lines += ["", "## Recommendations", ""]
if not agg["recommendations"]:
    lines.append("_No patterns recurring ≥ 2 times yet. Keep capturing._")
else:
    for i, rec in enumerate(agg["recommendations"], 1):
        lines += [
            f"### {i}. [{rec['type'].upper()}] {rec['title']}",
            "",
            f"**Failure code**: {rec['code']} — {CODE_NAMES.get(rec['code'], '')}  ",
            f"**Frequency**: {rec['count']} missions ({rec['pct']}% of audits)  ",
            f"**Type**: {rec['type']}  ",
            "",
            f"**Proposed fix**: {rec['fix']}",
            "",
            "**Evidence**:",
        ]
        for ev in rec["evidence"][:5]:
            lines.append(f"- `{ev['audit']}` — {ev['description'][:120]}")
        lines.append("")

if agg["unknown_incidents"]:
    lines += [
        "## Taxonomy Gaps (?? incidents)",
        "",
        f"_{len(agg['unknown_incidents'])} unclassified incidents — review to determine if taxonomy needs a new code._",
        "",
    ]
    for inc in agg["unknown_incidents"][:10]:
        lines.append(f"- `{inc['audit']}`: {inc['description'][:150]}")
    lines.append("")

lines += [
    "## Top Skills Loaded",
    "",
    "| Skill | Missions |",
    "|-------|---------|",
]
for skill, count in list(agg["top_skills"].items())[:10]:
    lines.append(f"| {skill} | {count} |")

print("\n".join(lines))
PYEOF

echo "Findings report written: $FINDINGS_REPORT"
```

### Step 4: Create GitHub issues for recommendations

```bash
REPO="${REPO_ARG:-fellowship-dev/commander}"
GH_TOKEN=$(grep 'GH_TOKEN_FELLOWSHIP' /Users/maxfindel/Projects/claude-buddy/.env | cut -d= -f2 2>/dev/null || echo "$GH_TOKEN")
export GH_TOKEN

# Ensure labels exist
for label_name in "skill" "rule"; do
  gh label list --repo "$REPO" 2>/dev/null | grep -q "^$label_name" || \
    gh label create "$label_name" \
      --repo "$REPO" \
      --color "$([ "$label_name" = "skill" ] && echo "#0075ca" || echo "#e4e669")" \
      --description "$([ "$label_name" = "skill" ] && echo "Worker capability gap" || echo "Lead behavior rule")" \
      2>/dev/null || true
done

# Create one issue per recommendation (deduplicated by code)
python3 << PYEOF
import json, subprocess, sys

agg = json.loads('''$AGGREGATE''')
repo = "$REPO"
today = "$TODAY"

for rec in agg.get("recommendations", []):
    title = f"[distill] {rec['title']}"

    # Check if issue already exists (avoid duplicates across analyze runs)
    result = subprocess.run(
        ["gh", "issue", "list", "--repo", repo, "--search", f'"{title}"', "--json", "number,title"],
        capture_output=True, text=True
    )
    if rec["title"][:30] in result.stdout:
        print(f"Issue already exists for: {rec['title'][:50]} — skipping")
        continue

    evidence_lines = "\n".join(
        f"- [{ev['audit']}]({ev['audit']}) — {ev['description'][:120]}"
        for ev in rec["evidence"][:5]
    )

    body = f"""## Context

Identified by /distill analyze on {today} across {agg['total_audits']} audit reports.

## Failure Pattern: {rec['code']}

**{rec['code']}** appears in **{rec['count']} missions** ({rec['pct']}% of audits analyzed).

## Evidence

{evidence_lines}

## Proposed Fix

{rec['fix']}

## Target

- **Type**: {rec['type']}
- **Repo**: {repo}
- **Label**: {rec['type']}

---
_Generated by /distill analyze — fellowship-dev/dogfooded-skills_
"""

    result = subprocess.run(
        ["gh", "issue", "create",
         "--repo", repo,
         "--title", title,
         "--label", rec["type"],
         "--body", body],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        print(f"Created issue: {result.stdout.strip()}")
    else:
        print(f"WARN: Failed to create issue for {rec['code']}: {result.stderr[:200]}")
PYEOF
```

### Step 5: Post findings report to Quest DB

```bash
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' /Users/maxfindel/Projects/claude-buddy/.env | cut -d= -f2 2>/dev/null || true)
if [ -n "$QUEST_TOKEN" ]; then
  curl -s -X POST "http://127.0.0.1:4242/api/event" \
    -H "Authorization: Bearer $QUEST_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
content = open('$FINDINGS_REPORT').read()
print(json.dumps({
  'source': 'commander',
  'type': 'commander.report',
  'title': 'Distill Analysis $TODAY',
  'meta': {'content': content, 'report_type': 'distill'}
}))
")" 2>/dev/null || true
  echo "Quest DB notified"
fi
```

---

## Error Handling

**No JSONL found for report** — proceed with report-only audit. Set `"session_found": false`. The audit is still useful for outcome tracking and rule compliance inferred from report content.

**Truncated JSONL (crashed session)** — partial data is valid. Set `"session_complete": false`. Capture what's available; partial sessions surface SF and SG patterns reliably.

**`gh` auth failure in analyze** — check `GH_TOKEN` export. The skill sources it from `claude-buddy/.env`. Provide token explicitly if env differs.

**python3 not available** — all parsing uses stdlib only (json, sys, collections, pathlib). No pip install needed.

**Duplicate analyze issues** — the issue creation step checks for existing titles before creating. Run analyze weekly; do not re-run on the same day unless audit files changed.

**Large JSONL (>2000 lines) with no Agent tool** — use `split + subagents` pattern from Step 4. Never attempt to read a JSONL file >2000 lines in a single Read call.

---

## Crew YAML Integration

Declare distill in your `crew.yml` to get it via `npx skills` and schedule weekly analysis:

```yaml
skills:
  - repo: fellowship-dev/dogfooded-skills@latest
    pick: [distill]

cron:
  - schedule: "0 12 * * 1"   # weekly Monday noon
    command: "/distill analyze"
```

Capture is dispatched by the poller after every mission — not declared in YAML.

---

## Audit JSON Schema Reference

```json
{
  "job_id": "2026-04-12-speckit-fellowship-dev-myrepo-branch",
  "date": "2026-04-12",
  "crew": "tooling",
  "task_summary": "Implement distill skill for post-mission auditing",
  "outcome": "done",
  "session_id": "abc123-...",
  "session_complete": true,
  "duration_minutes": 47,
  "cost_usd": 3.21,
  "token_usage": { "input": 850000, "output": 45000 },
  "workers_spawned": 2,
  "skills_loaded": ["project-registry", "speckit-runner"],
  "rules_compliance": {
    "R1_headless": true,
    "R3_no_code": true,
    "R4_read_skills": true,
    "R6_verify": true,
    "R7_report": true
  },
  "incidents": [
    {
      "code": "SV",
      "description": "Deploy actions with no HTTP verification",
      "evidence": "17 Bash calls, 0 curl calls"
    }
  ],
  "what_worked": ["Skills loaded on boot", "Worker deployed efficiently"],
  "missed_opportunity": "curl production URL before exit"
}
```

---

## Critical Rules

- **Never overwrite an existing audit** — `{report}-audit.json` present = already captured, skip
- **Partial sessions are valuable** — crash/timeout JSONL is still signal; set `session_complete: false`
- **Chunk at 2000 lines** — never read JSONL files larger than 2000 lines in a single pass
- **One issue per pattern** — deduplicate by `[distill]` title prefix before creating GitHub issues
- **`??` codes are growth signals** — track frequency; 3+ `??` in analyze means the taxonomy needs a new code
- **Labels must exist** before `gh issue create` — the skill creates them if missing
