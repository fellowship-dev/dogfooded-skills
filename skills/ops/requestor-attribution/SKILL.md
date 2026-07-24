---
name: requestor-attribution
description: Read at session start — injects Co-authored-by trailers and a "Requested by" PR attribution line from $PYLOT_REQUESTORS. No-op when the env var is absent or empty.
user-invocable: false
allowed-tools: Bash
---

# requestor-attribution

At worker session start, parse `$PYLOT_REQUESTORS` and set up commit and PR attribution so that the humans who triggered the mission are credited in git history and on GitHub.

**When `$PYLOT_REQUESTORS` is unset or empty, every section below is a no-op — no error, no output change, no extra trailers.**

---

## Session Start — Parse requestors

Run once at the beginning of the session before any commits or PRs:

```bash
REQUESTORS_JSON="${PYLOT_REQUESTORS:-}"
REQUESTORS='[]'
if [ -n "$REQUESTORS_JSON" ]; then
  REQUESTORS=$(python3 -c "
import sys, json
raw = sys.argv[1]
try:
    r = json.loads(raw)
    if not isinstance(r, list):
        raise ValueError('expected a JSON array, got ' + type(r).__name__)
    print(json.dumps(r))
except Exception as e:
    print('[requestor-attribution] WARNING: PYLOT_REQUESTORS parse failed — ' + str(e), file=sys.stderr)
    print('[]')
" "$REQUESTORS_JSON") || REQUESTORS='[]'
fi
```

If parse fails, `REQUESTORS='[]'` and all downstream steps silently no-op.

---

## Format `Co-authored-by:` trailers

Run once after parsing, before the first commit:

```bash
HUMAN_TRAILERS=$(python3 -c "
import sys, json
requestors = json.loads(sys.argv[1])
lines = []
for r in requestors:
    name  = ((r.get('display_name') or '').strip() or r.get('slack_user_id', 'Unknown')).replace('<', '').replace('>', '')
    gh    = r.get('github_username')
    email = (r.get('email') or '').strip() or None
    slack = r.get('slack_user_id', 'unknown')
    if gh and email:
        addr = email
    elif gh:
        addr = gh + '@users.noreply.github.com'
    else:
        addr = slack + '@users.noreply.fellowship.dev'
    lines.append('Co-authored-by: ' + name + ' <' + addr + '>')
print('\n'.join(lines))
" "$REQUESTORS")
```

`$HUMAN_TRAILERS` is an empty string when `REQUESTORS='[]'`.

---

## Inject trailers into every commit

**For every `git commit -m` call in this session**: when `$HUMAN_TRAILERS` is non-empty, include it as the final lines of the message body (before the Claude trailer that the harness appends automatically).

```bash
# Pattern — use a heredoc so multi-line trailers work correctly:
if [ -n "$HUMAN_TRAILERS" ]; then
  git commit -m "$(cat <<EOF
<subject line>

<body paragraph if needed>

$HUMAN_TRAILERS
EOF
)"
else
  git commit -m "<subject line>"
fi
```

The Claude Code harness appends `Co-Authored-By: Claude …` after the message body automatically. Human trailers in `$HUMAN_TRAILERS` land **above** that line in the final commit because they are part of the `-m` string passed to git before the harness appends its own line.

**Example commit with one linked requestor:**

```
feat: add timeout guard to retry loop

Co-authored-by: Max F. Findel <max@fellowship.dev>
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

## PR body attribution prefix

After `gh pr create` succeeds and you have the PR URL, prepend a `> Requested by …` line to the PR body:

```bash
# Build the attribution line
PR_ATTRIBUTION_LINE=$(python3 -c "
import sys, json
requestors = json.loads(sys.argv[1])
parts = []
for r in requestors:
    gh = r.get('github_username')
    if gh:
        parts.append('@' + gh)
    else:
        name = (r.get('display_name') or '').strip() or r.get('slack_user_id', '?')
        parts.append(name + ' (Slack)')
if parts:
    print('> Requested by ' + ', '.join(parts))
" "$REQUESTORS")

# Prepend to the PR body if non-empty
if [ -n "$PR_ATTRIBUTION_LINE" ]; then
  CURRENT_BODY=$(gh pr view --json body -q '.body' 2>/dev/null || echo "")
  gh pr edit --body "$(printf '%s\n\n%s' "$PR_ATTRIBUTION_LINE" "$CURRENT_BODY")" 2>/dev/null || \
    echo "[requestor-attribution] WARNING: could not prepend attribution to PR body — continuing"
fi
```

**Example PR body prefix:**
```
> Requested by @maxfindel, Bedo (Slack)

## What this adds
...
```

---

## Add linked users as PR assignees

After the PR is open, add each requestor with a non-null `github_username` as an assignee:

```bash
python3 -c "
import sys, json
for r in json.loads(sys.argv[1]):
    if r.get('github_username'):
        print(r['github_username'])
" "$REQUESTORS" | while IFS= read -r username; do
  gh pr edit --add-assignee "$username" 2>/dev/null || \
    echo "[requestor-attribution] NOTE: could not add assignee $username — skipping"
done
```

Users without a `github_username` (unlinked Slack users) are never passed to `--add-assignee`.

---

## Reference: `$PYLOT_REQUESTORS` shape

```
Array of up to 10 objects, each:
{
  "slack_user_id":   string,        // always present
  "github_username": string | null, // null when Slack account is not linked to GitHub
  "display_name":    string,        // Slack display name or GitHub login
  "email":           string | null  // null when not available
}
```

Populated by the Pylot executor (#2539) at worker spawn when the dispatching conversation has human participants. Absent on missions dispatched without a conversation context (e.g. direct API calls, cron triggers).

**Trailer address precedence:**
1. `github_username` + `email` → `<email>`
2. `github_username`, no `email` → `<github_username@users.noreply.github.com>`
3. No `github_username` → `<slack_user_id@users.noreply.fellowship.dev>`
