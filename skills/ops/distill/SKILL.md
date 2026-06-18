---
name: distill
description: Use when capturing post-mission audit data or analyzing audit records into a findings report with GitHub issue recommendations.
allowed-tools: Read, Write, Bash, Glob, Grep, Agent
---

# distill

Post-mission audit and distillation for crew operations. Two modes:

- **capture** — fetches mission metadata and CloudWatch logs via the hooks.fellowship.dev API, classifies incidents using the 8-code taxonomy, and POSTs a structured audit JSON to the API
- **analyze** — fetches audit records from hooks.fellowship.dev, aggregates recurring failure patterns, manages GitHub issues per pattern, promotes exemplars, and reports trend direction

## When to Use

- **capture**: after every mission (pass or fail) — triggered by the poller as a follow-up mission
- **analyze**: weekly via cron, or manually to survey trends across missions
- Idempotent — the API rejects duplicate audits for the same job_id (409 response)

## Prerequisites

```bash
python3 --version                       # needed for log parsing
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
```

All API calls go to `https://hooks.fellowship.dev` with header:
```
```

### Step 1: Fetch mission metadata + anti-recursion guard

Fetch mission record from the Pylot API. Extract metadata and apply the anti-recursion guard before doing any further work.

```bash
MISSION=$(curl -sf \

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
```

### Environment

```bash
# Required

# Optional
ISSUE_REPO            # Target repo for GitHub issues (default: fellowship-dev/commander)
```

All API calls include the header:
```
```

### Step 1: Fetch audit data

Fetch audit records and aggregated stats from `hooks.fellowship.dev` for the past 7 days, plus the prior 7-day period for trend comparison:

```bash

AUDITS=$(curl -sf \
  -H "$AUTH_HEADER" \
  "https://hooks.fellowship.dev/audits?days=7")

if [ $? -ne 0 ] || [ -z "$AUDITS" ]; then
  echo "ERROR: Failed to fetch audits from hooks.fellowship.dev"
  exit 1
fi

STATS=$(curl -sf \
  -H "$AUTH_HEADER" \
  "https://hooks.fellowship.dev/audits/stats?days=7")

if [ $? -ne 0 ] || [ -z "$STATS" ]; then
  echo "ERROR: Failed to fetch stats from hooks.fellowship.dev"
  exit 1
fi

# Prior period (days 8–14) for trend comparison — fallback to {} if endpoint unsupported
PRIOR_STATS=$(curl -sf \
  -H "$AUTH_HEADER" \
  "https://hooks.fellowship.dev/audits/stats?days=14&offset=7" || echo "{}")

echo "Audit data fetched."
```

### Step 2: Aggregate and identify recurring patterns

Group records by skill name, team, and incident code. Flag any combination with 3 or more occurrences in the 7-day window as a recurring pattern.

```bash
cat > /tmp/distill_aggregate.py << 'PYEOF'
import json, sys, collections

audits = json.loads(sys.argv[1])
stats  = json.loads(sys.argv[2])

if isinstance(audits, dict):
    audits = audits.get("records") or audits.get("audits") or []

pattern_counts  = collections.Counter()
pattern_records = collections.defaultdict(list)

for audit in audits:
    skill = audit.get("skill_name") or audit.get("skill") or "unknown"
    team  = audit.get("team", "unknown")
    for inc in audit.get("incidents", []):
        code = inc.get("code", "??")
        key  = (skill, team, code)
        pattern_counts[key] += 1
        pattern_records[key].append({
            "id":          audit.get("job_id") or audit.get("id"),
            "description": inc.get("description", ""),
            "evidence":    inc.get("evidence", "")
        })

recurring = [
    {
        "skill":   k[0],
        "team":    k[1],
        "code":    k[2],
        "count":   pattern_counts[k],
        "records": pattern_records[k]
    }
    for k, cnt in pattern_counts.items()
    if cnt >= 3
]

failure_rates = {
    entry.get("code"): entry.get("rate") or entry.get("failure_rate")
    for entry in (stats.get("by_code") or stats.get("failure_rates") or [])
}

print(json.dumps({
    "total_audits":       len(audits),
    "recurring_patterns": recurring,
    "failure_rates":      failure_rates
}, indent=2))
PYEOF

AGGREGATE=$(python3 /tmp/distill_aggregate.py "$AUDITS" "$STATS")
PATTERN_COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)['recurring_patterns']))" <<< "$AGGREGATE")
echo "Aggregation complete. ${PATTERN_COUNT} recurring patterns identified."
```

### Step 3: GitHub issue management

For each recurring pattern, search for an open issue whose title contains the skill name and incident code. Comment with updated counts and exemplar IDs if found; create a new issue if not.

```bash
echo "$AGGREGATE" > /tmp/distill_agg.json
ISSUE_REPO="${ISSUE_REPO:-fellowship-dev/commander}"
python3 << 'PYEOF'
import json, os, subprocess

with open("/tmp/distill_agg.json") as _f:
    agg = json.load(_f)
issue_repo = os.environ.get("ISSUE_REPO", "fellowship-dev/commander")

for pattern in agg.get("recurring_patterns", []):
    skill   = pattern["skill"]
    code    = pattern["code"]
    count   = pattern["count"]
    team    = pattern["team"]
    records = pattern["records"]

    title_prefix = f"[distill] {skill}: recurring {code}"
    title_full   = f"{title_prefix} ({count} occurrences in 7 days)"

    search = subprocess.run(
        ["gh", "issue", "list",
         "--repo", issue_repo,
         "--search", f"{title_prefix} in:title is:open",
         "--json", "number,title", "--limit", "5"],
        capture_output=True, text=True
    )
    existing_issues = json.loads(search.stdout or "[]")
    match = next(
        (i for i in existing_issues if skill in i["title"] and code in i["title"]),
        None
    )

    mission_ids = [r["id"] for r in records if r.get("id")]
    ids_str     = ", ".join(str(m) for m in mission_ids[:5])
    rate        = agg["failure_rates"].get(code)
    rate_str    = f"{rate}%" if isinstance(rate, (int, float)) else str(rate or "N/A")

    if match:
        comment = (
            f"**Updated count**: {count} occurrences in the last 7 days\n\n"
            f"**New exemplar mission IDs**: {ids_str}\n\n"
            f"**Failure rate (7-day)**: {rate_str}"
        )
        result = subprocess.run(
            ["gh", "issue", "comment", str(match["number"]), "--repo", issue_repo, "--body", comment],
            capture_output=True, text=True
        )
        status = "Commented on" if result.returncode == 0 else "WARN: failed to comment on"
        print(f"{status} issue #{match['number']}: {title_prefix}")
    else:
        evidence_lines = "\n".join(
            f"- {r['id']}: {r.get('description', '')[:120]}"
            for r in records[:10]
            if r.get("id")
        )
        body = f"""## Recurring Failure Pattern

**Skill**: \`{skill}\`
**Incident code**: \`{code}\`
**Team**: {team}
**Occurrences**: {count} in the last 7 days
**Failure rate (7-day)**: {rate_str}

## Exemplar Mission IDs

{evidence_lines}

---
_Generated by /distill analyze — fellowship-dev/dogfooded-skills_
"""
        result = subprocess.run(
            ["gh", "issue", "create", "--repo", issue_repo, "--title", title_full, "--body", body],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            print(f"Created issue: {result.stdout.strip()}")
        else:
            print(f"WARN: Failed to create issue for {skill}/{code}: {result.stderr[:200]}")
PYEOF
```

### Step 4: Promote exemplar

For each recurring pattern, identify the single most instructive failure — the record with the richest evidence field — and promote it via `PATCH /audits/{id}/exemplar`.

```bash
echo "$AGGREGATE" > /tmp/distill_agg.json
python3 << 'PYEOF'
import json, os, urllib.request, urllib.error

with open("/tmp/distill_agg.json") as _f:
    agg = json.load(_f)

for pattern in agg.get("recurring_patterns", []):
    records = pattern.get("records", [])
    if not records:
        continue

    exemplar = max(
        records,
        key=lambda r: len(r.get("evidence", "") or r.get("description", ""))
    )
    eid = exemplar.get("id")
    if not eid:
        print(f"WARN: No ID for exemplar in {pattern['skill']}/{pattern['code']}, skipping")
        continue

    req = urllib.request.Request(
        f"https://hooks.fellowship.dev/audits/{eid}/exemplar",
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type":  "application/json"
        },
        data=b"{}"
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"Promoted exemplar {eid} for {pattern['skill']}/{pattern['code']} — HTTP {resp.status}")
    except urllib.error.HTTPError as e:
        print(f"WARN: PATCH /audits/{eid}/exemplar → HTTP {e.code}")
    except Exception as e:
        print(f"WARN: PATCH /audits/{eid}/exemplar → {e}")
PYEOF
```

### Step 5: Trend comparison

Compare incident counts from the current 7-day window against the prior 7-day period. Report `improving` (fewer occurrences), `stable`, or `worsening` (more occurrences) per incident code.

```bash
echo "$STATS" > /tmp/distill_stats.json
echo "$PRIOR_STATS" > /tmp/distill_prior_stats.json
python3 << 'PYEOF'
import json

with open("/tmp/distill_stats.json") as _f:
    stats = json.load(_f)
with open("/tmp/distill_prior_stats.json") as _f:
    prior_stats = json.load(_f)

def extract_counts(s):
    return {
        e.get("code"): e.get("count", 0)
        for e in (s.get("by_code") or s.get("failure_rates") or [])
    }

current = extract_counts(stats)
prior   = extract_counts(prior_stats)
codes   = sorted(set(current) | set(prior))

print("## Trend Report (current 7 days vs prior 7 days)\n")
print(f"{'Code':<6} {'Current':>9} {'Prior':>9}  Trend")
print("-" * 38)
for code in codes:
    c = current.get(code, 0)
    p = prior.get(code, 0)
    if   c < p: trend = "improving"
    elif c > p: trend = "worsening"
    else:       trend = "stable"
    print(f"{code:<6} {c:>9} {p:>9}  {trend}")
PYEOF
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

- **One issue per pattern** — deduplicate by `[distill]` title prefix before creating GitHub issues
- **`??` codes are growth signals** — track frequency; 3+ `??` in analyze means the taxonomy needs a new code
- **Labels must exist** before `gh issue create` — the skill creates them if missing
