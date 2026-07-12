# Stage 01: Cohesive Review (subagent — the critical-judgement step)

This is the isolated clean-context judgement stage. ONE subagent reviews the **entire diff in
cohesion**. Do NOT split the diff per-file or per-dimension. There is exactly one of these — no
fan-out, no parallelism.

## Inputs
- `.procedure-output/review-pr/00-context/handoff.md` (PR metadata, body, conventions, existing
  comments, CI status, the FULL diff, and Closes-vs-Refs raw data)

Read ONLY this handoff. You do not have, and do not need, the orchestrator's history.

## Task
Review the whole diff together. Build a mental model of what changed and why, then evaluate
correctness, convention compliance, and Closes-vs-Refs — all dimensions considered in cohesion
across the entire change set. Produce a confidence-scored findings list plus a verdict. Read-only:
do NOT check out, fix, or push anything.

## Steps

### Step 1: Read the Diff — at the depth the Risk Tier demands
Read the `## Risk Tier` section of the handoff first, then the full diff. Build a mental model of
what changed and why. Focus on understanding intent before looking for issues. Reason across
files — a finding in one file may only be a bug because of what another file in the same diff
does. Cross-file cohesion is the point.

**Tier-scaled depth (#2210):**
- **LOW** — bounded pass: verify the change does what the PR claims, check the Closes-vs-Refs data
  (Step 4) and any convention the diff obviously touches, and inspect only the riskiest 2-3 hunks
  in depth. Do not exhaustively sweep a template-following diff. If anything you see contradicts
  the LOW rating (a rubric trigger the mechanical pass missed), ESCALATE: record the new tier +
  reason in your handoff and review at that depth instead.
- **MEDIUM** — the full cohesive review as described below.
- **HIGH** — the full cohesive review PLUS the runtime-shape checklist:

**Runtime-shape checklist (HIGH tier only).** These are the defect classes that diff-reading
historically misses because the code *looks* idiomatic — walk each one explicitly against the diff
and record the answer (fine / finding / not applicable) in your handoff:
1. **Post-response async work on serverless** — any promise started but not awaited before the
   handler returns (fire-and-forget writes, `.catch(() => undefined)` tails). On Lambda the
   process freezes when the response is sent; the work silently never happens.
2. **Boundary return shapes** — values crossing a driver/API boundary (DB rows, SDK responses):
   does the code assume `Date`/number where the real driver returns strings (e.g. RDS Data API
   returns timestamps as strings)? Comparisons/sorting on such fields are the classic failure.
3. **Pagination/cursor math** — cursor comparisons, tuple ordering, off-by-one on page
   boundaries; would a full page of equal-timestamp rows or a string-typed cursor break it?
4. **Local-vs-prod substrate drift** — behavior that differs between the test substrate (PGlite,
   local mocks) and prod (Aurora/Data API/real Lambda): case sensitivity, JSON casting, implicit
   transactions, cold-start state.
5. **Read-modify-write on shared state** — lost-update windows on config/secrets/labels that two
   concurrent missions could interleave.

### Step 2: Analyze and Score Findings

For each potential issue, assess:

**Severity:**
- **Bug** — logic errors, security issues, broken behavior, data loss risk
- **Warning** — potential issues worth investigating, edge cases, performance
- **Info** — style observations, suggestions, minor improvements

**Confidence (0–100):**
- **90–100**: Certain — clear bug, obvious security flaw, definite spec violation
- **80–89**: High — strong evidence, likely a real issue
- **70–79**: Moderate — plausible but uncertain (DO NOT INCLUDE — below threshold)
- **0–69**: Low — speculation, nitpick, or pre-existing issue (DO NOT INCLUDE)

**Only surface findings with confidence ≥ 80.**

**Mandatory filters — EXCLUDE these even if scored high:**
- Pre-existing issues not introduced by this PR
- Issues that linters/formatters will catch automatically
- Generic code quality nitpicks not backed by CLAUDE.md conventions
- Pedantic style preferences with no functional impact
- Moved/renamed code flagged as "new" (detect refactors)

**Verification step:** For each finding, actively try to disprove it. Check if the "bug" is
actually handled elsewhere in the diff, if the "missing check" exists in a caller, if the "edge
case" is prevented by the type system. Only findings that survive this check make the final list.

### Step 3: Convention Compliance
Check the diff against the repo's CLAUDE.md (from the handoff, if present). Flag violations of
explicitly stated conventions. Do NOT invent conventions — only flag what the CLAUDE.md actually
says. If no CLAUDE.md exists, skip this section.

### Step 4: Closes vs Refs Check (MANDATORY)
Use the Closes-vs-Refs raw data in the handoff. For each linked issue with a `Closes`/`Fixes`/
`Resolves` keyword whose unchecked acceptance-criteria count > 0 → add a finding as **Bug**
(confidence 100): PR uses `Closes #N` but issue has unchecked acceptance criteria. Must change to
`Refs #N`.

If no Closes keywords were found, record "No Closes keywords found".

### Step 5: Verdict
The verdict is ALWAYS "proceed to double-check" — this stage never blocks or rejects a PR.
- No findings ≥ 80 → "Clean — proceed to double-check"
- N findings → "{N} findings to address — proceed to double-check"

### Step 6: Write handoff

## Output: handoff.md

Path: `.procedure-output/review-pr/01-cohesive-review/handoff.md`

```markdown
# Stage 01: Cohesive Review — $REPO PR #$PR

## Summary
[2-3 sentences: what this PR does, what problem it solves, and whether the approach is sound]

## Risk Tier
- tier: {tier from handoff, or the ESCALATED tier + reason}

## Findings
| ID | Severity | Location | Finding | Confidence |
|----|----------|----------|---------|------------|
| R1 | 🔴 Bug | `path/file.ts#L67-72` | [description] | 95 |
| R2 | 🟡 Warning | `path/other.ts#L23` | [description] | 85 |
| R3 | ℹ️ Info | `path/util.ts#L45` | [description] | 80 |

[IDs are `R{n}` — they persist into the review-state ledger that double-check and cto-review
update, so never renumber. If no findings ≥ 80 confidence: "No issues found above confidence
threshold."]

## Verified
[What you actually checked and how — this feeds the review-state manifest that tells later
stages what is already covered. `how` is always `read` in this stage (this skill never executes).]
| What | How |
|------|-----|
| {e.g. "whole diff, cross-file cohesion"} | read |
| {e.g. "runtime-shape checklist items 1-5"} | read |
| {e.g. "Closes-vs-Refs AC counts"} | read |

## Runtime-Shape Checklist
[HIGH tier only: item-by-item fine / finding {ID} / n-a. Other tiers: "n/a — tier {tier}"]

## Convention Compliance
[Findings from CLAUDE.md — or "No CLAUDE.md found" / "All conventions followed"]

## Closes vs Refs
[Result of mandatory check — or "No Closes keywords found"]

## Verdict
[Clean — proceed to double-check / {N} findings to address — proceed to double-check]
```

## Success criteria
- The ENTIRE diff was reviewed together (cohesion), not fragmented per-file
- Every surfaced finding has confidence ≥ 80 and survived the disprove step
- Location references a file path and line numbers from the diff
- Convention compliance and Closes-vs-Refs sections both present
- Verdict is "proceed to double-check" (never blocks)
- handoff.md written before exiting

## Failure
- Diff missing/empty in the handoff → emit a handoff noting the failure; the orchestrator emits
  `[pylot] outcome="review-pr failed at stage 01: {reason}" status=failed`
