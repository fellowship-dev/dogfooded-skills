# [Feature Name]

## Problem Statement
[2-3 sentences: what user problem this solves and why it matters now]

## User Stories
- As a [user type], I want [goal] so that [benefit]

## Success Metrics
- [Metric]: [specific target or measurement approach]

## Measurable Impact

[Include this section ONLY if the issue states an explicit causal goal/eval/outcome contract —
a named metric, an explicit target, and causal framing tying this work to that metric. Otherwise
replace the whole section with a single line: "Not applicable — no goal, eval, or outcome
contract is established for this issue." or, if partial signals exist, "Needs a goal decision —
[what's missing]." Never invent a metric or target to fill this section.]

- **Hypothesis:** [One sentence: "Implementing this feature will <improve/reduce> <metric>", from the issue's own causal framing]
- **Baseline:** [The named metric's value — "not yet measured" if the outcomes API was unavailable]
- **Baseline source:** [API endpoint, window (days), cohort (scope/org), sample size]
- **Target:** [The target the issue itself stated, copied verbatim — never agent-computed]
- **Evaluation rule:** [Regression rule derived from the issue's own stated target, e.g. "Regression triggers auto-issue if metric regresses past the stated target"]

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
