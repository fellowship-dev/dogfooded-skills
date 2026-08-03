# Stage 06: Ask or Structure

## Inputs
- All prior handoffs: 02, 03, 04, 05, 05b

## Task
Decision point: synthesize all findings into either a question list (exit) or a PRD draft.

## Decision logic
ANY of the following triggers questions:
- Stage 02 verdict = `needs-context`
- Stage 03 verdict = `needs-questions`
- Stage 04 has failure modes requiring human clarification to guardrail
- Stage 05 has open questions blocking the test plan

**If questions → exit early:**
1. Batch ALL gaps into a single numbered list Q1-Qn (one comment only — never two)
2. Post comment: `gh issue comment {number} --repo {repo} --body "..."`
3. Add label: `gh issue edit {number} --repo {repo} --add-label "open-questions"`
4. Emit: `[pylot] outcome="questions posted" status=success`
5. STOP — do not proceed to stage 07

**If all clear → PRD draft:**
1. Use `shared/prd-template.md` as the skeleton
2. Fill in all sections from prior handoffs
3. Weave in stage 02 context additions to relevant sections
4. Add stage 04 guardrails as "Implementation Constraints" section
5. Add stage 05 test plan as "Testing Strategy" section
6. Write draft to `stages/06-ask-or-structure/output/handoff.md`

## Routing stage 05b's verdict

Stage 05b never writes to GitHub. Whatever it decided is carried here, into the comment or the PRD
this stage was already going to produce. **It never earns an extra comment.**

| 05b verdict | Questions path | PRD path |
| --- | --- | --- |
| `skip` | nothing | nothing |
| `ask` | append **one** question to the batch (below) | one line in `## Open Questions` (below) |
| `dispatch` / `already-dispatched` | one line under the questions | one line in `## Implementation Notes` + **withhold `ready-to-work`** (stage 07) |
| `picked` | — | variant becomes the design basis (below) |

**`ask`, questions path** — the last numbered question, carrying the marker stage 05b looks for
next pass:

```markdown
Q{n}: This looks like a new UI surface with no settled design. Want three bootable variants first
(throwaway branches + screenshots, you pick one, it becomes the design basis)? Answer "build the
prototype" here, or add the `prototype-options` label any time later.
<!-- pylot:proto-ask issue={number} -->
```

**`ask`, PRD path** — one line in `## Open Questions`, and nothing else. Do **not** add the
`open-questions` label on this path: the PRD is otherwise complete and the issue is not blocked on
this.

```markdown
- Prototype variants: this reads as UI exploration (<the two shapes from 05b's handoff>). Add the
  `prototype-options` label to get three bootable variants before implementation.
```

**`dispatch` / `already-dispatched`** — one line in `## Implementation Notes`:

```markdown
Prototype variants dispatched (`proto-{number}`). The options comment will land on this issue with
three branches and screenshots. **Do not start implementation until a variant is picked** — the
design basis does not exist yet.
```

**`picked`** — the chosen branch is now the design basis. Cite it where the PRD is normally
vaguest:

- `## Technical Requirements` — point at `proto/{number}-<letter>` and the files under
  `/proto/{slug}` as the pattern to follow.
- `## Implementation Notes` — carry over the thesis from the options comment, and list the losing
  branches for deletion **as a checklist item, not an executed command**:
  `git push origin --delete proto/{number}-a proto/{number}-c`. Deletion is a mutation; it belongs
  to the implementing PR or the owner, never to this skill.

## Output (questions path): handoff.md
```text
Verdict: needs-questions
Questions posted: Q1 ... Qn
```

## Output (PRD path): handoff.md
Full PRD draft (see `shared/prd-template.md` for structure).

## Success criteria
- Questions: single comment, `open-questions` label applied, exit emitted, stage stops
- PRD: all sections populated, no unresolved TBD/TODO
- Stage 05b's verdict is routed into the existing comment or PRD — **never into a second comment**
