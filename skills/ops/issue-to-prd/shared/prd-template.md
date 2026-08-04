# [Feature Name]

## Problem Statement
[2-3 sentences: what user problem this solves and why it matters now]

## User Stories
- As a [user type], I want [goal] so that [benefit]

## Success Metrics
- [Metric]: [specific target or measurement approach]

## Measurable Impact

- **Hypothesis:** [One sentence: "Implementing this feature will <improve/reduce> <metric>"]
- **Baseline:** [Value from `GET /outcomes/summary` — or "not yet measured" if API unavailable]
- **Target:** [Agent-suggested target based on baseline, e.g. "pr_merged ≥ 85% within 30d post-ship"]
- **Experiment plan:** Monitor via outcomes API post-merge; link to Phase 2 experiment once #2773 ships
- **Eval criteria:** [Auto-regression threshold, e.g. "Regression triggers auto-issue if metric drops >5pp"]

## Scope

### In Scope
- [Concrete feature or deliverable]

### Out of Scope
- [Explicitly excluded item]

## Technical Requirements
- [Requirement referencing existing codebase patterns]

## Implementation Constraints
- [Guardrail from failure mode analysis — what NOT to do]
- [Scope fence — which files/areas to touch]
- [Pattern to follow — link to existing code]

## Testing Strategy

### Prerequisites
- [Mock server / seed data / test suite to build FIRST]

### Pre-merge Verification
- [ ] [Test that runs on the PR branch]
- [ ] [Visual evidence requirement]

### Post-merge Verification (if any)
- [ ] [Prod-only check, flagged explicitly]

## Dependencies
- [Related system or feature, if any]

## Open Questions
- [Anything unresolved — do not guess]

## Implementation Notes
[Architectural decisions, patterns to follow, files to reference]
