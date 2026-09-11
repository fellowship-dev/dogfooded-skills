# Stage 01b: Triage Challenge

## Inputs
- `stages/00-automation-guard/output/handoff.md` (label list)
- `stages/01-read-issue/output/handoff.md` (title, body, comments)

## Why this stage exists

Owner ruling (Max, 2026-09-07, issue #169) encodes fellowship-dev/pylot `docs/principles.md`
XI (When in Doubt, Go Without), XII (Smallest Version First), and XIII (Ground Every Claim in Code
or Data): before this skill spends a PRD on an issue, it must first ask whether the issue should
exist at all, or exist at its stated size. Every prior pass went straight from "read the issue" to
"structure it" — nothing ever challenged the ask itself, so a request for a second mechanism
serving a need something already met would sail through to a full PRD, and an oversized ask never
got pushed back to its smallest version. This stage is that challenge. Run it **second**,
immediately after stage 01, before stage 02 reads anything.

## Task
Produce a triage verdict, checked in this priority order — the first that fits on cited evidence
wins:

1. `delete-retire` — an existing mechanism in this repo (or a linked sibling repo) already serves
   the need the issue describes. Cite it `file:line` or by skill/stage name. The issue should not
   get a second mechanism for an already-served need; it should be closed in favor of the existing
   one, or the existing one should be pointed to as the fix.
2. `close` — either no existing mechanism covers it but the issue names no concrete failure, cost,
   or user-facing gap that not doing it would leave open (XI: when in doubt, go without); or **every
   item** the issue asks for has already been done by unrelated work landed since it was filed —
   cite the file(s)/line(s) proving each item is done. (If only *some* items are already done, that
   is a `re-scope`, not a `close` — see step 5; a real example of this exact partial-completion
   shape is in the #169 dry run against fellowship-dev/dogfooded-skills#149,
   `docs/evidence/2026-09-11-issue-169-real-runs.md`.)
3. `re-scope` — the issue's ask is larger than the smallest version that would resolve the need it
   states (XII). Name the narrower version.
4. `prd` — none of the above hold on cited evidence. Proceed to stage 02 normally.

**Any doubt on 1-3 falls through to `prd`.** This stage can only stop the pipeline on a citation;
it can never stop it on a hunch. A missed `delete-retire`/`close`/`re-scope` costs one avoidable
PRD. A wrongly stopped `prd` silently kills a real issue with no PRD, no comment explaining why,
and no way for the reporter to see the reasoning — that is the more expensive failure.

## Steps
1. From stage 01's handoff, write the core need in one sentence: what breaks, or what someone
   cannot do, without this issue.
2. Search the repo for an existing mechanism addressing that need — `git grep`, `grep -rn` over
   `skills/`, relevant `docs/`, config/labels named in the issue — and re-read the issue's own
   comments for a "we already handle this via X" note.
3. **`delete-retire` check**: a match found in step 2 that fully covers the stated need → cite it
   `file:line` or by name, verdict `delete-retire`. A partial match (covers part of the need, or a
   different case) is not a match — fall through to step 4.
4. **`close` check**: no match, and either (a) the issue body/comments state no concrete failure
   mode, cost, or blocked task — only a preference or a "would be nice" — verdict `close`, citing
   the exact line that shows the ask has no stated cost of not doing it; or (b) every item the
   issue lists is already done by work landed since filing — verdict `close`, citing the file(s)/
   line(s) proving each item is done. If only some items are already done, that is not this check —
   fall through to step 5 and name the remaining item as the smaller need.
5. **`re-scope` check**: a concrete need exists, but the ask visibly bundles more than that need
   requires (e.g. a general framework/config system for one caller, a second flag pattern where a
   default change would do) → verdict `re-scope`, naming the smallest version in one sentence.
6. Nothing above lands on a citation → verdict `prd`.

## On non-`prd` verdict
Abort the pipeline — do not run stages 02-07. Post **one** comment naming the verdict, the cited
mechanism/need/smallest-version, and (for `delete-retire`) a pointer to the existing mechanism:

```bash
gh issue comment {number} --repo {repo} --body "..."
```

Apply the label matching the verdict: `delete-retire` → `wontfix`; `close` → `wontfix`; `re-scope`
→ `needs-rescope`. Do not close the issue directly — that is the owner's call once they see the
verdict; this stage only posts the recommendation and its evidence.

Emit `[pylot:$PYLOT_OUTCOME_NONCE] outcome="triage: <verdict> — <one-line reason>" status=success`.

## Output: handoff.md
```markdown
# Stage 01b: Triage Challenge

## Verdict
`delete-retire` | `close` | `re-scope` | `prd`

## Core need
{one sentence}

## Evidence
{file:line or mechanism name for delete-retire; cited absence of stated cost, or file(s)/line(s)
proving every item is already done, for close; the oversized element + smallest version (or the
remaining not-yet-done item) for re-scope; "no match found" for prd}
```

## Success criteria
- Verdict is one of the four values, always with cited evidence — never a bare assertion
- On non-`prd`: exactly one comment posted, correct label applied, stages 02-07 skipped,
  `status=success` emitted
- On `prd`: handoff records the core need and "no match found" so stage 06 does not re-derive it
- Ambiguous or uncited redundancy/scope/benefit signals always fall through to `prd` — never guessed
  into a stop
