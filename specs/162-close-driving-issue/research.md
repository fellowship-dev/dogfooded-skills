# Research: Close Driving Issues and Decompose Remainders

## Decision 1: Close the driving issue on every shippable PR

- **Decision**: Require exactly one driving issue and a closing keyword on every PR; represent
  deliberate remainder work with separately tracked follow-up issues.
- **Rationale**: An open driving issue is redispatchable even after its intended PR merges. Separate
  issues preserve truthful completion state and make each later PR independently dispatchable.
- **Alternatives**: Keep `Refs` until the last PR (rejected: tracker drift); forbid decomposition
  (rejected: makes legitimate incremental delivery impossible).

## Decision 2: Preserve calibrated review findings

- **Decision**: Both a `Refs`-only driving issue and named unmet criteria produce Bug findings whose
  confidence is judged on the existing 80–100 scale.
- **Rationale**: These are shippability defects, while preserving the review skill's established
  evidence threshold and avoiding hard-coded confidence.
- **Alternatives**: Automatic confidence 100 (rejected: contradicts calibration); Warning severity
  (rejected: permits redispatch or silent loss of acceptance criteria).

## Decision 3: Use one canonical follow-up contract

- **Decision**: Store one shared Markdown template under `skills/shared/`; both author and reviewer
  guidance link to it. The title and body begin with `Follow-up of #N`; the body contains Origin,
  Remaining acceptance criteria, and Out of scope sections; remaining criteria are verbatim; labels
  include `ready-to-work` and the origin issue's priority.
- **Rationale**: A single contract prevents the two instruction surfaces from drifting.
- **Alternatives**: Duplicate embedded templates (rejected: drift); prose-only requirements
  (rejected: agents can produce structurally inconsistent issues).

## Decision 4: Make corpus behavior executable

- **Decision**: Add a focused shell regression test and register it in the repository's explicit CI
  test manifest, alongside markdown lint and the existing suite.
- **Rationale**: SC-001 is a repository-search invariant, and CI currently requires every test entry
  point to be listed explicitly.
- **Alternatives**: Manual search only (rejected: regression-prone); modify all tests (unnecessary).

## Integration Findings

- `skills/ops/review-pr/stages/01-cohesive-review/CONTEXT.md` currently recommends `Refs #N` for
  partially satisfied acceptance criteria and must be reversed.
- `skills/product/create-compelling-prs/SKILL.md` currently permits `Refs` for multi-PR driving work
  and its shippability checklist rejects all follow-ups; both statements need coordinated changes.
- GitHub CLI access is unavailable in this planning environment, so live evidence remains an
  implementation/delivery task using a real accessible PR rather than fabricated planning evidence.
