---
name: distill
description: Post-mission audit and distillation — capture mode classifies a completed mission using an 8-code failure taxonomy and writes an audit JSON; analyze mode aggregates audit JSONs into a findings report and creates GitHub issues with recommendations.
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

# distill

Post-mission audit and distillation for crew operations. Two modes:

- **capture** — fetches mission metadata and CloudWatch logs via the hooks.fellowship.dev API, classifies incidents using the 8-code taxonomy, and POSTs a structured audit JSON to the API
- **analyze** — reads all audit JSONs in `reports/`, aggregates trends, produces a findings report and GitHub issues with recommendations

## When to Use

- **capture**: after every mission (pass or fail) — triggered by the poller as a follow-up mission
- **analyze**: weekly via cron, or manually to survey trends across missions
- Idempotent — the API rejects duplicate audits for the same job_id (409 response)

## Prerequisites

```bash
python3 --version                       # needed for log parsing
echo "${PYLOT_DISPATCH_TOKEN:?PYLOT_DISPATCH_TOKEN not set}"  # auth token required
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

Task field: `distill capture <job_id>`

The skill receives `job_id` from the task input (e.g. `task: 'distill capture abc123-uuid'`).

### Environment

```bash
# Required
PYLOT_DISPATCH_TOKEN    # Bearer token for hooks.fellowship.dev
```

All API calls go to `https://hooks.fellowship.dev` with header:
```
Authorization: Bearer $PYLOT_DISPATCH_TOKEN
```

### Step 1: Fetch mission metadata + anti-recursion guard

Fetch mission record from the Pylot API. Extract metadata and apply the anti-recursion guard before doing any further work.

```bash
MISSION=$(curl -sf \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  "https://hooks.fellowship.dev/missions/${job_id}")

if [ $? -ne 0 ] || [ -z "$MISSION" ]; then
  echo "ERROR: Failed to fetch mission $job_id"
  exit 1
fi

# Extract metadata fields
TASK=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('task',''))")
STATUS=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('status',''))")
EXIT_CODE=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('exit_code',''))")
TEAM=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('team',''))")
AGENT=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('agent',''))")
STARTED_AT=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('started_at',''))")
FINISHED_AT=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('finished_at',''))")
REPORT=$(echo "$MISSION" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('report',''))")

# Anti-recursion guard — never capture a capture/audit/analyze mission
if echo "$TASK" | grep -qiE 'distill|capture|audit|analyze'; then
  echo "Anti-recursion: skipping capture for task: $TASK"
  exit 0
fi
```

### Step 2: Stream CloudWatch logs via SSE

```bash
curl -sf \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Accept: text/event-stream" \
  "https://hooks.fellowship.dev/missions/${job_id}/logs/stream" \
  > /tmp/distill_logs_${job_id}.txt

echo "Log stream saved."
```

The SSE stream delivers CloudWatch log lines as JSON events. Each `data:` line is a JSON object with `timestamp`/`ts` and `message`/`msg` fields.

### Step 3: Parse SSE events — extract signals

Write and run the SSE parser:

```bash
cat > /tmp/distill_parse_sse.py << 'PYEOF'
import re, sys, json, collections

log_file = sys.argv[1]
signals = {
    "session_complete": True,
    "tool_counts": {},
    "error_tool_results": [],
    "workers_spawned": 0,
    "workers_spawned_sessions": [],
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
    },
    "timing": {
        "container_start_ts": None,
        "first_claude_call_ts": None,
        "first_token_ts": None,
        "done_signal_ts": None
    }
}
tool_counts = collections.Counter()

try:
    with open(log_file) as f:
        content = f.read()
except Exception as e:
    signals["session_complete"] = False
    print(json.dumps(signals))
    sys.exit(0)

# Parse SSE data lines — each is a CloudWatch log entry JSON
for line in content.splitlines():
    if not line.startswith("data: "):
        continue
    raw = line[6:].strip()
    if not raw or raw == "[DONE]":
        continue
    try:
        entry = json.loads(raw)
    except json.JSONDecodeError:
        signals["session_complete"] = False
        continue

    ts = entry.get("timestamp") or entry.get("ts")
    msg = entry.get("message", "") or entry.get("msg", "")
    msg_lower = msg.lower()

    # Timing markers
    timing = signals["timing"]
    if not timing["container_start_ts"] and any(k in msg_lower for k in [
            "container start", "ecs task started", "bootstrap"]):
        timing["container_start_ts"] = ts
    if not timing["first_claude_call_ts"] and any(k in msg_lower for k in [
            "claude api", "anthropic.messages.create", "invoking claude"]):
        timing["first_claude_call_ts"] = ts
    if not timing["first_token_ts"] and any(k in msg_lower for k in [
            "first token", "stream started", "content_block_start"]):
        timing["first_token_ts"] = ts
    if not timing["done_signal_ts"] and re.search(r'\bdone\b', msg_lower):
        timing["done_signal_ts"] = ts

    # Tool call detection from log message text
    tool_match = re.search(
        r'\b(Read|Bash|Edit|Write|Grep|Glob|Agent|WebFetch|WebSearch|TodoWrite|TodoRead)\b',
        msg
    )
    if tool_match:
        tool = tool_match.group(1)
        tool_counts[tool] += 1

        if tool == "Agent":
            signals["workers_spawned"] += 1
        elif tool == "Write":
            path_match = re.search(r'file_path["\s:]+([^\s",}]+)', msg)
            if path_match:
                signals["write_paths"].append(path_match.group(1))
        elif tool == "Read":
            path_match = re.search(r'file_path["\s:]+([^\s",}]+)', msg)
            if path_match and ".claude/skills" in path_match.group(1):
                parts = path_match.group(1).split(".claude/skills/")
                if len(parts) > 1:
                    skill_name = parts[1].split("/")[0]
                    if skill_name and skill_name not in signals["skills_loaded"]:
                        signals["skills_loaded"].append(skill_name)
        elif tool == "Bash":
            cmd_match = re.search(r'command["\s:]+(.+?)(?:,\s*"|\}|$)', msg)
            if cmd_match:
                cmd = cmd_match.group(1).strip('"')[:300]
                signals["bash_calls"].append(cmd)
                if any(v in cmd for v in ["curl ", "gh pr view", "gh pr merge", "gh pr list", "gh run"]):
                    signals["verification_calls"].append(cmd[:200])
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
                if re.search(r'\bclaude\s+(-p|--print)\b', cmd):
                    signals["workers_spawned"] += 1
                    sid = re.search(r'--session-id\s+(\S+)', cmd)
                    if sid:
                        signals["workers_spawned_sessions"].append(sid.group(1))

    # Error patterns — ENOENT, permission denied, timeout, crash
    error_patterns = ["enoent", "permission denied", "timeout", "crash", "error:", "exception:"]
    if any(p in msg_lower for p in error_patterns):
        signals["error_tool_results"].append(msg[:300])

    # Original prompt — first assistant message with task context
    if not signals["original_prompt"] and "task:" in msg_lower:
        signals["original_prompt"] = msg[:500]

    # Token usage from log lines
    tok_in = re.search(r'input_tokens["\s:]+(\d+)', msg)
    if tok_in:
        signals["total_input_tokens"] += int(tok_in.group(1))
    tok_out = re.search(r'output_tokens["\s:]+(\d+)', msg)
    if tok_out:
        signals["total_output_tokens"] += int(tok_out.group(1))

# committed_to_main heuristic
if any(re.search(r'git\s+commit', b) for b in signals["bash_calls"]):
    signals["git_signals"]["committed_to_main"] = not signals["git_signals"]["branch_created"]

signals["tool_counts"] = dict(tool_counts)
print(json.dumps(signals, default=str))
PYEOF

SIGNALS=$(python3 /tmp/distill_parse_sse.py "/tmp/distill_logs_${job_id}.txt")
echo "Signals extracted."
```

### Step 4: Extract timing metrics from log timestamps

```bash
TIMING_METRICS=$(python3 << PYEOF
import json
from datetime import datetime

signals = json.loads('''$SIGNALS''')
finished_at = "$FINISHED_AT"
timing = signals.get("timing", {})

def parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None

def ms_between(a, b):
    if a and b:
        return round((b - a).total_seconds() * 1000)
    return None

container_start   = parse_ts(timing.get("container_start_ts"))
first_claude_call = parse_ts(timing.get("first_claude_call_ts"))
first_token       = parse_ts(timing.get("first_token_ts"))
done_signal       = parse_ts(timing.get("done_signal_ts"))
finished          = parse_ts(finished_at)

print(json.dumps({
    "cold_start_ms":    ms_between(container_start, first_claude_call),
    "first_token_ms":   ms_between(first_claude_call, first_token),
    "done_to_ended_ms": ms_between(done_signal, finished)
}))
PYEOF
)
```

- **cold_start_ms** — time from container start log to first Claude API call log
- **first_token_ms** — time from first Claude API call to first token received
- **done_to_ended_ms** — time from `done` signal in logs to `finished_at` in missions DB

### Step 5: Classify incidents

Apply taxonomy rules to the extracted signals. Produce an `incidents` array.

Write and run the classifier:

```bash
cat > /tmp/distill_classify.py << 'PYEOF'
import json, re, sys

signals = json.loads(sys.argv[1])
report_text = open(sys.argv[2]).read().lower()  # mission report text (from API)

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
deploy_keywords = ["deploy", "publish", "vercel", "heroku", "production", "live", "release"]
is_deploy_task = any(re.search(r'\b' + kw + r'\b', original_prompt) for kw in deploy_keywords)
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

echo "$REPORT" > /tmp/distill_report_${job_id}.txt
CLASSIFIED=$(python3 /tmp/distill_classify.py "$SIGNALS" "/tmp/distill_report_${job_id}.txt")
```

### Step 6: Extract rules compliance

```bash
HAS_REPORT="True"
[ -z "$REPORT" ] && HAS_REPORT="False"

COMPLIANCE=$(python3 << PYEOF
import json, sys

signals = json.loads('''$SIGNALS''')
task = "$TASK".lower()
tool_counts = signals.get("tool_counts", {})
bash_calls = signals.get("bash_calls", [])
write_paths = signals.get("write_paths", [])
skills_loaded = signals.get("skills_loaded", [])
verification_calls = signals.get("verification_calls", [])
git_signals = signals.get("git_signals", {})

is_feature = any(kw in task for kw in
                 ["implement", "feature", "add", "build", "create", "fix", "update"])

compliance = {
    "R1_headless": "AskUserQuestion" not in tool_counts,
    "R3_no_code": ("Edit" not in tool_counts and
                   not any("src/" in p or "app/" in p for p in write_paths)),
    "R4_read_skills": len(skills_loaded) > 0,
    "R6_verify": len(verification_calls) > 0,
    "R7_report": $HAS_REPORT,  # True if mission API returned a non-empty report field
    "R_branch": git_signals.get("branch_created", False),
    "R_push": git_signals.get("pushed", False),
    "R_pr": git_signals.get("pr_created", False) or not is_feature
}
print(json.dumps(compliance))
PYEOF
)
```

### Step 7: Build and POST audit JSON

Assemble the audit JSON and POST it to the Pylot API:

```bash
AUDIT_JSON=$(python3 << PYEOF
import json
from datetime import datetime

signals   = json.loads('''$SIGNALS''')
classified = json.loads('''$CLASSIFIED''')
compliance = json.loads('''$COMPLIANCE''')
timing    = json.loads('''$TIMING_METRICS''')

started_at  = "$STARTED_AT"
finished_at = "$FINISHED_AT"

def parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None

duration_minutes = 0
s, e = parse_ts(started_at), parse_ts(finished_at)
if s and e:
    duration_minutes = round((e - s).total_seconds() / 60)

input_tok  = signals.get("total_input_tokens", 0)
output_tok = signals.get("total_output_tokens", 0)
cost_usd   = round((input_tok / 1_000_000 * 3.0) + (output_tok / 1_000_000 * 15.0), 2)

audit = {
    "job_id":            "$job_id",
    "team":              "$TEAM",
    "agent":             "$AGENT",
    "task_summary":      "$TASK",
    "status":            "$STATUS",
    "exit_code":         "$EXIT_CODE",
    "started_at":        started_at,
    "finished_at":       finished_at,
    "duration_minutes":  duration_minutes,
    "cost_usd":          cost_usd,
    "token_usage":       {"input": input_tok, "output": output_tok},
    "timing_metrics":    timing,
    "workers_spawned":   signals.get("workers_spawned", 0),
    "skills_loaded":     signals.get("skills_loaded", []),
    "session_complete":  signals.get("session_complete", True),
    "rules_compliance":  compliance,
    "incidents":         classified.get("incidents", []),
    "what_worked":       classified.get("what_worked", []),
    "missed_opportunity": classified.get("missed_opportunity", "")
}
print(json.dumps(audit, indent=2))
PYEOF
)

# POST audit to Pylot API
HTTP_STATUS=$(curl -sf -w "%{http_code}" -o /tmp/distill_audit_response.txt \
  -X POST \
  -H "Authorization: Bearer $PYLOT_DISPATCH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$AUDIT_JSON" \
  "https://hooks.fellowship.dev/missions/${job_id}/audit")

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
  echo "Audit posted: $HTTP_STATUS"
elif [ "$HTTP_STATUS" = "409" ]; then
  echo "Audit already exists for $job_id — skipping (idempotent)"
else
  echo "ERROR: Audit POST failed with HTTP $HTTP_STATUS"
  cat /tmp/distill_audit_response.txt
  exit 1
fi
```

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
GH_TOKEN=$(grep 'GH_TOKEN_FELLOWSHIP' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2 2>/dev/null || echo "$GH_TOKEN")
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
QUEST_TOKEN=$(grep '^QUEST_TOKEN=' /home/ubuntu/projects/fellowship-dev/claude-buddy/.env | cut -d= -f2 2>/dev/null || true)
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

**`gh` auth failure in analyze** — check `GH_TOKEN` export. The skill sources it from `claude-buddy/.env`. Provide token explicitly if env differs.

**python3 not available** — all parsing uses stdlib only (json, sys, collections, pathlib). No pip install needed.

**Duplicate analyze issues** — the issue creation step checks for existing titles before creating. Run analyze weekly; do not re-run on the same day unless audit files changed.

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

- **Idempotent** — POST /missions/{job_id}/audit returns 409 if already captured; exit 0 on 409
- **One issue per pattern** — deduplicate by `[distill]` title prefix before creating GitHub issues
- **`??` codes are growth signals** — track frequency; 3+ `??` in analyze means the taxonomy needs a new code
- **Labels must exist** before `gh issue create` — the skill creates them if missing
