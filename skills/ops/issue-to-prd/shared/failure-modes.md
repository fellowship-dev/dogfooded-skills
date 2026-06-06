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
