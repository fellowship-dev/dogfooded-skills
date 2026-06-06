---
name: premature-close-checker
description: Check if a closed issue has unchecked acceptance criteria; post a comment and add needs-triage label if so. Zero LLM overhead — pure bash.
argument-hint: "issue-number org/repo"
user-invocable: true
allowed-tools: Bash
---

# premature-close-checker

Checks whether a closed issue has unchecked acceptance criteria (`- [ ]` items). If found, posts a comment and adds the `needs-triage` label for CTO review.

**Design goal:** zero LLM judgment. All logic is in `scripts/check-premature-close.sh`.

## Usage

```
/premature-close-checker 42 fellowship-dev/pylot
```

## Arguments

```bash
ISSUE_NUMBER=$1   # Issue number
REPO=$2           # org/repo
```

---

## Runbook

### Step 1: Dedup Gate

```bash
ISSUE_NUMBER=$1
REPO=$2

ALREADY_FLAGGED=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" \
  --json labels --jq '[.labels[].name] | contains(["needs-triage"])' 2>/dev/null || echo "false")

if [ "$ALREADY_FLAGGED" = "true" ]; then
  echo "[premature-close-checker] outcome=\"already flagged — needs-triage label present\" status=success"
  exit 0
fi
```

### Step 2: Run Bash Script

```bash
PYLOT_DIR="${PYLOT_DIR:-$HOME/projects/fellowship-dev/pylot}"
bash "$PYLOT_DIR/scripts/check-premature-close.sh" "$ISSUE_NUMBER" "$REPO"
```

---

## Notes

- Script exits 0 in all non-error cases (including "nothing to do").
- `needs-triage` label is created if missing.
- Does NOT reopen issues — CTO decides after review.
