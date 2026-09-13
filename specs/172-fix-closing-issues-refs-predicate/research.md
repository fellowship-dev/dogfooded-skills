# Research: Fix closingIssuesReferences Repo Predicate

## Decision: corrected predicate

- **Decision**: `.number == $issue and ((.repository.owner.login + "/" + .repository.name) == $repo)`.
- **Rationale**: measured (issue #172 Evidence table, re-verified during this pass against the
  current `pr-postcondition.sh:23` and `SKILL.md:53`) to be the real shape `gh pr view --json
  closingIssuesReferences` returns: `{"id","number","repository":{"id","name","owner":{"id","login"}},"url"}`.
  There is no `.repository.nameWithOwner` key anywhere in that payload, so the existing predicate's
  right-hand side is always `null` and the comparison is always false — the whole reason a
  correctly-formed, genuinely-closing PR still fails the Step 8 postcondition and is invisible to
  the Step 0 resume gate. Owner/name concatenation reconstructs the same `org/repo` string from
  fields that do exist.
- **Alternatives considered**:
  - *Keep `.repository.nameWithOwner`, fix elsewhere* — rejected: the field genuinely does not
    exist in this payload (unlike `gh repo view --json nameWithOwner`, a different, real field on a
    different command — the reason the other 8 occurrences of `nameWithOwner` in this repo are out
    of scope).
  - *Match on `.repository.id` instead of owner/name* — rejected: the issue's payload doesn't
    expose the caller's own repo id for comparison without an extra `gh repo view` call; owner/name
    reconstruction needs no new API call.

## Decision: fail-closed behavior

- **Decision**: no explicit null-guard added; rely on jq's existing null-propagation semantics.
- **Rationale**: verified during the issue's own triage (Evidence table) and re-derived here: if
  `repository` is absent, `.repository.owner.login` is `null`, and `null + "/"` is a jq type error
  only for `+`, but jq's `null + <string>` returns `<string>` unchanged, and further `+` against a
  present `.repository.name` still yields a value that cannot equal `$repo` (a real `org/repo`
  string) — so the `and` short-circuits to `false`, not an error. Same for `any()` over an empty
  array: it vacuously returns `false`. Both cases resolve to rejection (exit 1) without a jq
  execution error, per FR-003.
- **Alternatives considered**:
  - *Add `// empty` / explicit `has("repository")` guards* — rejected: unnecessary given jq's
    demonstrated null-propagation behavior; adds surface area the issue's Anti-patterns section
    doesn't ask for and the fail-closed property already holds without it.

## Decision: test harness fix

- **Decision**: delete the Python `jq` stub (`tests/pr-postcondition.test.sh:26-41`); let real `jq`
  run against a reshaped real-payload fixture; add a wrong-repo case (right issue number, different
  owner/name → rejected).
- **Rationale**: the Python stub hardcodes `.repository.nameWithOwner` as its own model of the
  predicate (line 35) and was never parsing or executing the shell's actual jq program — so the
  suite was validating a hand-written Python copy of the bug's own broken assumption, not the
  shipped string. That is why it passed 4/4 green with the defect present (issue's measured
  baseline). Removing the stub is the smaller, more durable fix: no second implementation to keep
  in sync, and the suite now fails immediately if the shell predicate regresses.
- **Alternatives considered**:
  - *Fix the fixture only, keep the Python stub* — rejected: the issue explicitly rules this out
    (Implementation Notes) — it would just re-sync a second model and leave the same blind spot for
    the next divergence.
  - *Mirror the corrected predicate into the Python stub* — rejected for the same reason: recreates
    the exact blind spot that shipped this bug.
