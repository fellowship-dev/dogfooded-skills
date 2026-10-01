# Common Agent Failure Modes

Catalog of pitfall patterns for use in stage 04 analysis.

## Over-engineering
- Agent builds a general framework when a targeted fix suffices
- Agent adds config options for every variation instead of hardcoding the one needed case
- Guardrail: scope fence + "do not add config, just implement for this case"

## Scope creep
- Agent fixes related-but-separate issues it notices while implementing
- Agent refactors code that works fine but isn't clean
- Guardrail: "only touch files X, Y, Z — do not clean up surrounding code"

## Wrong pattern
- Agent implements a new pattern instead of following the existing one in the codebase
- Agent uses a library that's already abstracted in the repo
- Guardrail: pointer to the existing code that should be replicated

## Assumption about what exists
- Agent assumes a mock server exists when it doesn't
- Agent assumes seeds are in place for the DB state it needs
- Agent assumes permissions or tokens are available in the test environment
- Guardrail: explicit test prerequisites in the PRD

## Rabbit holes
- Agent researches background topics extensively before starting
- Agent investigates all callers of a function when only one is relevant
- Guardrail: "start from file X, read only what you need to implement feature Y"

## Misinterpreted scope
- Agent implements the full feature when a spike or prototype was asked for
- Agent implements client-only when server changes are also needed (or vice versa)
- Guardrail: explicit in/out-of-scope list, call out client/server boundary explicitly

## Missing test coverage
- Agent implements the feature but skips tests because the area has no existing coverage
- Agent writes tests that pass in isolation but fail against real infrastructure
- Guardrail: test prerequisites explicit in PRD, visual evidence requirement stated

## Inventing an owner gate

- Agent writes "do NOT run the production step without owner sign-off" for a change whose target
  value, validation and rollback are already specified. That gate has nothing to decide; it only delays.
- Agent treats an existing `waiting-on-owner` label as proof that the issue needs an owner decision
- Guardrail: an owner gate needs a stated decision: a question, options and a recommendation, in an
  owner-authority class. Those classes are irreversible or destructive production data, spend above
  budget, secrets/credentials, external sends, and org policy or product judgement. Otherwise the PRD
  makes the step executable. If the step must be sequenced with a release, it ships as a migration or
  release-train step. If not, it runs under the existing safety nets: a rollback copy, an audit, and
  the post-deploy watch. Owner ruling, Max, 2026-10-01: owner gates are for decisions, not consequences.
