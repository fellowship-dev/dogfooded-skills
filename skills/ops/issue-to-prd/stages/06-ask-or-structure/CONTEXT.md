# Stage 06: Ask or Structure

## Inputs
- All prior handoffs: 02, 03, 04, 05, 05b, 05c

## Task
Decision point: synthesize all findings into either a question list (exit) or a PRD draft.

## Decision logic
ANY of the following triggers questions:
- Stage 02 verdict = `needs-context`
- Stage 03 verdict = `needs-questions`
- Stage 04 has failure modes requiring human clarification to guardrail
- Stage 05 has open questions blocking the test plan

## Ask-path dedup guard — run before any write

`issue-to-prd` re-fires on every answered question (`rechallenge-after-answers`), so a fresh pass
can land on an issue that is already correctly parked and still waiting on the owner. Before
batching questions, check whether that is exactly what is happening. This is a manual read of
labels and comment content/timestamps via the `gh` calls this skill already uses — the same
deliberately low-tech, content-marker detection style as `stages/05b-prototype-gate/CONTEXT.md` § P,
and the same "stop before writing" shape as the precondition in `stages/07-publish/CONTEXT.md`.

Anchor on **content**, never on author type alone: other bot comments can land on this issue between
the question comment and now (stage 05b's own prototype-options comment is one example), and "most
recent bot comment" cannot tell those apart from the actual question. Mirror § P exactly — the
questions comment carries its own marker (see the post step below), and the guard matches on that
marker, sorted explicitly by `created_at` rather than trusting API ordering:

```bash
LABELS=$(gh issue view {number} --repo {repo} --json labels -q '[.labels[].name] | join(",")')
QUESTION_COMMENT=$(gh api "repos/{repo}/issues/{number}/comments?per_page=100" --paginate \
  --jq '[.[] | select(.body | test("<!-- pylot:question issue={number} -->"))] | sort_by(.created_at) | .[] | "\(.id)\t\(.created_at)"' \
  | tail -1)
```

All three must hold, or the guard does not apply and normal routing (the ask/PRD steps below)
proceeds:

1. The `open-questions` label is present on the issue.
2. A prior question comment carrying the `<!-- pylot:question issue={number} -->` marker exists
   (`QUESTION_COMMENT` is non-empty).
3. No comment created after that marker comment's timestamp comes from a non-bot author.

**No marker-carrying comment found** (condition 2 fails — e.g. the label predates this marker, or an
older cycle's comment was posted before this guard existed) is not evidence the issue is unanswered
or answered. It is ambiguous, and ambiguity always falls through to normal routing, **never** to a
skip: a duplicate question comment is recoverable, a silently stranded issue is not. Expect this on
every issue already parked on `open-questions` from before this guard shipped: the first post-sync
pass over such an issue will not find the marker, will fall through, and will post one further
questions comment as a one-time cold-start cost — the guard only engages starting from the *next*
ask/answer cycle for that issue, once its own marker-carrying comment exists.

**All three hold** → the issue is exactly where the last pass left it: post nothing, apply no
label (it is already there), and exit early with:
`[pylot:$PYLOT_OUTCOME_NONCE] outcome="already parked on open-questions, no new comment needed" status=success`.
Do not proceed to the ask/PRD steps below.

**Any one fails** → proceed to the normal ask/PRD routing below (a new answer arrived, the label
was removed, or no marker-carrying question exists yet — this pass owns the write).

**If questions → exit early:**
1. Batch ALL gaps into a single numbered list Q1-Qn (one comment only — never two)
2. Post comment: `gh issue comment {number} --repo {repo} --body "..."` — append the dedup guard's
   marker on its own line after the visible question text: `<!-- pylot:question issue={number} -->`.
   It is an HTML comment, invisible on GitHub; the human-visible question wording is otherwise
   untouched.
3. Add label: `gh issue edit {number} --repo {repo} --add-label "open-questions"`
4. Emit: `[pylot:$PYLOT_OUTCOME_NONCE] outcome="questions posted" status=success`
5. STOP — do not proceed to stage 07

**If all clear → PRD draft:**
1. Use `shared/prd-template.md` as the skeleton
2. Fill in all sections from prior handoffs
3. Weave in stage 02 context additions to relevant sections
4. Add stage 04 guardrails as "Implementation Constraints" section
5. Add stage 05 test plan as "Testing Strategy" section
6. Populate `## Measurable Impact` from stage 05c handoff, gated on `Contract`:
   - `Contract: linked-metric` → include the full section:
     - **Hypothesis**: one sentence built from the issue's own `Source Text` (e.g. "Implementing
       this feature will increase pr_merged rate") — never invent a hypothesis unrelated to what
       the issue said
     - **Baseline**: copy `Baseline` field from stage 05c handoff verbatim
     - **Baseline source**: copy `Baseline Source` field verbatim (endpoint / window / cohort /
       sample size)
     - **Target**: copy `Target` field verbatim — this is the issue's own stated target, never an
       agent computation
     - **Evaluation rule**: copy `Eval Criteria` field verbatim
   - `Contract: none` → replace the whole section with one line: "Not applicable — no goal, eval,
     or outcome contract is established for this issue." Do not include Hypothesis/Baseline/
     Target/Evaluation rule fields, and do not mention any metric name.
   - If stage 05c's `Contract` field itself is ambiguous, missing, or unreadable → treat as
     "needs a goal decision": one line, "Needs a goal decision — outcomes baseline stage did not
     produce a clear contract verdict." Never fall back to a generic metric or a computed target.
7. Write draft to `stages/06-ask-or-structure/output/handoff.md`

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
- Dedup guard: when all three conditions hold, zero comments posted, zero labels applied, and the
  stage exits success on that alone — never a second questions comment on an already-parked issue
