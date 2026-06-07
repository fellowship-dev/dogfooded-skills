# Stage 01: Plan Build Order (subagent) — CRITICAL JUDGEMENT

## Inputs
- `.procedure-output/build-train/00-setup/handoff.md` — config + issue manifest

## Task
Derive a dependency DAG over the batched issues and topologically sort it into **waves** so stage
02 knows which builds can run concurrently and which must wait. This is the isolated
critical-judgement stage: a wrong edge either over-serializes the train (slow) or lets a dependent
build race ahead of its prerequisite (broken output). It runs in clean context for exactly this
reason.

## Steps

1. Read the issue manifest (number, title, context summary, dependency hints) from stage 00.

2. For every ordered pair of issues, decide whether a **dependency edge** `A → B` exists (B must
   build after A). An edge exists when B's build must consume A's output. Signals, in priority
   order:
   - Explicit `depends on #A` / `blocked by #A` / "needs #A first" in B's body or comments.
   - B consumes an artifact A produces: shared DB migration/schema, a package/lib A builds, a
     generated client/type, a config or fixture A introduces.
   - A and B edit the **same file(s)** in a way where order matters (foundational change first).
   - Foundational-before-feature: scaffolding / shared infra issue before issues that build on it.

   When unsure, prefer NO edge (more parallelism) UNLESS the two clearly touch the same artifact —
   then add the edge to avoid a race. Document the rationale per edge.

3. Detect cycles. If a cycle exists, break it by dropping the weakest edge (lowest-confidence
   signal) and note it; never emit a cyclic graph.

4. Topologically sort into waves:
   - Wave 1 = all issues with in-degree 0 (no unmet dependency).
   - Remove wave 1, recompute in-degrees, wave 2 = new in-degree-0 set. Repeat until all placed.
   - Independent issues land in the same wave (run concurrently). Dependent issues land strictly
     after every prerequisite.

5. Write handoff.

## Output: handoff.md

Path: `.procedure-output/build-train/01-plan-order/handoff.md`

```markdown
# Stage 01: Build Order

## Dependency edges
| From (prereq) | To (dependent) | Reason | Confidence |
|---------------|----------------|--------|------------|
| #10 | #14 | #14 uses brand tokens from #10 | high |
{or "none — all issues independent"}

## Waves (execution order for stage 02)
| Wave | Issues (run concurrently) |
|------|---------------------------|
| 1 | #10, #15, #16 |
| 2 | #14 |

## Dropped edges (cycle-breaking)
{edge + reason, or "none"}

## Notes
{anything ambiguous and how it was resolved}
```

## Success criteria
- Every batched issue appears in exactly one wave
- Graph is acyclic; each dependent issue is in a strictly later wave than all its prerequisites
- Independent issues are NOT needlessly serialized (max concurrency per wave)

## Failure
- Manifest missing/empty → write handoff with all issues in Wave 1, edges "none (manifest
  unavailable — defaulting to full parallel)", and continue (skip-rather-than-break)
