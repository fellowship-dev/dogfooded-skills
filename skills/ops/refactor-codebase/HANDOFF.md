# The Handoff

The handoff is what a **fresh session with no memory of the work** reads to resume the loop with zero ambiguity. (Reviews and resumes routinely happen in fresh context — design for it.) Often the masterplan already carries most of this; the handoff is the thin "where exactly we are and what's next" layer on top.

Keep it **short and current**. A stale 500-line handoff is worse than a tight 40-line one. Refresh it at the end of every cycle.

## Minimum contents

```markdown
# Handoff — <loop name>, cycle <N>

## State
- Masterplan: <link/path>. Branch: <branch>. Base: <origin/main sha>.
- Last green checkpoint: <sha / tag>.
- Worklist position: next target = <X> (technique <Y>).

## Immediate next steps (the resuming agent starts at #1)
1. <the very next action>
2. ...

## How to run the gates here
- baseline suite: <exact command>
- byte-identical snapshot: <exact command>
- <any project-specific deploy/review step>

## Gotchas (things that cost the last session time)
- <env trap, flaky suite to filter, tool quirk, ...>

## Open questions / blockers
- <anything needing a human decision>
```

## Principles

- **State in files, not chat.** The resuming agent must not need the prior conversation. If a fact matters, it's in the handoff or the masterplan.
- **The next step is a concrete action, not a status.** "Resume decomposition" is useless; "Run cycle on `db.mjs` billing cluster via barrel-split; baseline command in §gates" is resumable.
- **Carry gotchas forward.** The env trap that cost an hour this session will cost the next session an hour too unless it's written down. This is the highest-value part of the handoff.
- **Mark soft claims as unverified.** Mechanical state (base sha, dir contents, gate commands, flaky band) is reliable to carry forward; *judgment* claims (which cluster is "green-tested" or "self-contained") drift and mislead. Tag them "claimed — verify via reverse-ref scan," and have the resuming agent re-run the scan rather than trust the prose. A confidently-wrong coverage claim can steer a bad cycle.
- **One handoff, refreshed — not a pile.** Overwrite it each cycle (history lives in git + the scoreboard). Don't accrete `handoff-1`, `handoff-2`, … in the working set.
- **Verify on resume.** The resuming agent re-reads the handoff, confirms the branch/sha and that the baseline is green, *then* starts step 1. If the recorded state doesn't match reality (drifted base, dirty tree), reconcile before refactoring.
- **No handoff committed? Reconstruct from the tree.** When the prior loop kept its masterplan/handoff in scratch (the right call on a repo you don't own — see [MASTERPLAN.md](MASTERPLAN.md)), a fresh session won't find either. Don't start from zero: the repo *is* the handoff. A domain subdir + a re-export barrel means a decomposition is mid-flight — the extracted modules are done cycles, the still-inline clusters are the remaining worklist. Infer it, seam-rank the remainder, and write a fresh masterplan before cycle 1. (See SKILL.md → Orient.)
