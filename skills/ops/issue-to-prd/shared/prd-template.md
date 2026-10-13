# [Feature Name] (#[issue number])

**Status:** awaiting-owner-decisions

**Source:** [issue URL, or "supplied in prompt"]

## Problem Statement
[2-3 sentences: what user problem this solves and why it matters now]

## User Stories
- As a [user type], I want [goal] so that [benefit]

## Success Metrics
- [Metric]: [specific target or measurement approach]

## Smallest version that works
[The narrowest change that resolves the stated need — one or two sentences. If the scope below is
larger than this, cite the specific failing case that requires the extra size; a preference is not
a citation.]

## Measurable Impact
[Only when the issue states a named metric, an explicit numeric target and causal framing.
Otherwise replace the section body with the single line: "Not applicable — the issue states no
goal, eval, or outcome contract." Never invent a metric or target.]

- **Hypothesis:** [from the issue's own causal framing]
- **Baseline:** [the issue's stated baseline, or "not yet measured"]
- **Target:** [the issue's own target, verbatim]

## Scope

### In Scope
- [Concrete feature or deliverable]

### Out of Scope
- [Explicitly excluded item]

## What this lets us delete
[Config, code path, flag, doc, or second mechanism this change makes redundant — cite `file:line`
or the mechanism's name. "Nothing" is valid only with a one-line reason (e.g. "net-new capability,
nothing prior served this need"). Never leave this section templated or silent.]

## Technical Requirements
- [Requirement referencing existing codebase patterns; mark answers that depend on an owner
  question "(pending Q{n})"]

## Implementation Constraints
- [Guardrail from failure mode analysis — what NOT to do]
- [Scope fence — which files/areas to touch]
- [Pattern to follow — link to existing code]

## Testing Strategy

### Prerequisites
- [Mock server / seed data / test suite to build FIRST]

### Pre-merge Verification
- [ ] [Test that runs on the PR branch]

### Post-merge Verification (if any)
- [ ] [Prod-only check, flagged explicitly]

## Dependencies
- [Related system or feature, if any]

## Assumptions
- [Anything assumed without an owner decision, cheap to reverse, with its basis]

## Implementation Notes
[Architectural decisions, patterns to follow, files to reference]

## Questions for the owner

### Q1. [The decision, as a question]
- **Why it matters:** [one or two lines, citing `file:line` where possible]
- **Options:**
  - A. [option]
  - B. [option]
- **Recommended:** [letter] — [reason]
- **Blocks implementation:** yes | no
