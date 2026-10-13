# Stage 06: Ask or Structure

## Inputs
- All prior handoffs in `$WORK/`: 01, 01b, and (on the `prd` path) 02, 03, 04, 05
- `shared/prd-template.md`

## Task
Write the spec to `specs/{number}-{slug}/spec.md` in the target repository. There is always a
spec, and it always ends with `## Questions for the owner`. "Ask" and "structure" are no longer
two exits: the spec structures everything the evidence settles and asks about everything it
does not.

## Why every spec carries owner questions
The 2026-10-13 bake-off scored this procedure first on vague asks, but every agent arm still
contradicted at least one real owner decision. The agents asked the right questions and then
recommended the conservative engineering answer (restrict deletes after submission, add a second
association for safety), which the owner overrode. So the agent proposes; the owner decides.
Implementation starts only after the owner decision round.

## Path and slug
- `slug`: 2-5 lowercase words from the issue title, kebab-case, ASCII only.
- If `specs/{number}-*/` already exists, reuse that folder and update its `spec.md` in place.
  Keep owner answers already recorded there; they are decisions, not suggestions.
- Create the folder if needed. Write nothing else into it; `plan.md` belongs to the planner.

## Triage path (stage 01b verdict is not `prd`)
Write a short spec: `# {title}`, the status line, `## Triage verdict` (verdict, core need,
cited evidence, the smaller version for `re-scope`), and `## Questions for the owner` with one
question: close as the verdict, re-scope to the named smaller version, or proceed with the full
ask. Recommend the verdict. Skip the template's other sections.

## PRD path
1. Use `shared/prd-template.md` as the skeleton and fill every section from the handoffs.
2. Weave stage 02's context additions into the relevant sections.
3. Stage 04's guardrails go in `## Implementation Constraints`; stage 05's test plan goes in
   `## Testing Strategy`.
4. `## Smallest version that works` comes from stage 01b's `Core need`. If `## Scope` is larger,
   cite the specific failing case that needs the extra size; otherwise trim the scope.
5. `## What this lets us delete`: stage 01b's search result plus anything found while drafting.
   If nothing is superseded, write "Nothing — net-new capability; no existing mechanism serves
   this need". Never a bare "Nothing".
6. `## Measurable Impact` only when the issue itself states all three: a named metric, an
   explicit numeric target, and causal framing tying this work to the metric. Copy them
   verbatim; the baseline is "not yet measured" unless the issue gives one. Otherwise write the
   single line "Not applicable — the issue states no goal, eval, or outcome contract." Never
   invent a metric or compute a target.
7. Citation rule: every factual claim cites `file:line` or a measured number from the handoffs.
   An uncited claim is not asserted; it becomes an owner question or a stated assumption.

## Questions for the owner
Collect every open decision from stages 02 (context gaps), 03 (missing or ambiguous required
sections), 04 (failure modes that need a human call to guardrail) and 05 (testing
prerequisites). Then add the decisions you were about to make silently: any product or design
choice the issue does not settle (constraints on user actions, data-model shape, what happens
to existing records, defaults, visibility, who can do what) is an owner question **even when
you are confident**. Engineering details the codebase already settles are not questions.

Each question uses exactly this shape:

```markdown
### Q1. {The decision, as a question}
- **Why it matters:** {one or two lines, with a `file:line` citation where one exists}
- **Options:**
  - A. {option}
  - B. {option}
- **Recommended:** {letter} — {reason}
- **Blocks implementation:** yes | no
```

- At least two options per question, each a real choice (not "A. do it / B. don't" unless that
  is the decision).
- One recommended answer per question, with a reason. Recommend what the evidence supports, not
  the most restrictive option: say so when the conservative choice costs the user something.
- `Blocks implementation: no` only when the recommended answer is cheap to reverse later.
- Where the spec body depends on an answer, write the recommended answer into the body and mark
  it `(pending Q{n})`. Do not present it as decided.
- If the owner already answered (stage 01 handoff), record the answer under the question as
  `- **Owner answer:** …`, apply it to the body, and drop the `(pending …)` mark.
- If there are genuinely no open decisions, write "None — every decision is settled by the
  issue or the codebase" and say why in one line. Expect this to be rare on vague asks.

## Status line
Right under the title: `**Status:** awaiting-owner-decisions` while any question has no owner
answer, or `**Status:** decided` once every question has one. An implementer must not start on
`awaiting-owner-decisions`.

## Attended and unattended runs
- **Unattended** (a devbox, a scheduled run, or a prompt that says nobody will answer): never
  prompt. Write the spec with the questions and stop. When running inside a devbox as part of
  the work, commit `specs/{number}-{slug}/spec.md` with the change, or on its own if the run
  only writes the spec; follow the caller's branch and delivery instructions.
- **Attended** (a person is in the session): write the spec first, then present the questions
  once, all together, each with its recommendation. Record the answers in the spec as above,
  update the body and the status line, and stop. Do not re-ask answered questions.

In both modes this skill makes no GitHub writes: no comments, labels or issue-body edits.
Publishing the questions anywhere else is the caller's job.

## Output
- `specs/{number}-{slug}/spec.md` (the deliverable)
- `$WORK/06-ask-or-structure.md`: the spec path, the status and the question count

## Success criteria
- `python3 {skill_dir}/scripts/check_spec.py specs/{number}-{slug}/spec.md` exits 0
- Every question has at least two options and one recommended answer
- PRD path: every template section is present and filled; no TBD/TODO
- Every claim cites `file:line` or a measured number, or is an owner question or assumption
- No GitHub writes and, when unattended, no interactive prompts
