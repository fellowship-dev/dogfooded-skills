# Trash Truck retirement workflow forward-run receipts

These secret-free dry exercises ran against commit
`94fab8ee724f6ceb35263f03bc047514235f4e6d`. They call the production decision
CLI directly; they do not claim that any external evidence provider was queried.
All commands exited `0` unless an expected fail-closed result says otherwise.

## 1. Interactive discovery: no candidate

```bash
printf '%s\n' '{"mode":"interactive","candidate":null,"persist":null}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py mode
printf '%s\n' '{"candidates":[{"fingerprint":"acme/app:active-hook","checks":["boundary","code","history","real_world","consumers","recurrence"],"positive_use":true,"payoff":3,"effort":1,"risk":1,"corroborated":true}]}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py rank
```

Receipts: mode returned `{"mode": "interactive"}`; ranking returned
`{"candidates": []}`. The empty result exercises the no-change stop without a
selection question.

## 2. Interactive discovery: fewer than three

```bash
printf '%s\n' '{"candidates":[{"fingerprint":"acme/app:old-worker","checks":["boundary","code","history","real_world","consumers","recurrence"],"payoff":3,"effort":1,"risk":1,"corroborated":true}]}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py rank
```

Receipt: exactly one candidate was returned, with confidence `1.0` and score
`2.25`. The result was not padded to three.

## 3. Missing real-world telemetry remains unknown

```bash
printf '%s\n' '{"candidates":[{"fingerprint":"synthetic/app:static-only-worker","checks":["boundary","code","history","consumers","recurrence"],"payoff":4,"effort":0,"risk":0,"corroborated":true,"positive_use":false,"failed_decisive_source":false,"unresolved_contradictions":0}]}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py rank
```

Receipt: `{"candidates": []}`. With no `real_world` check, confidence is capped
at `0.65`, below the `0.70` proposal threshold; unavailable evidence did not
become zero usage.

## 4. Positive use vetoes a plausible static candidate

```bash
printf '%s\n' '{"candidates":[{"fingerprint":"synthetic/app:live-static-candidate","checks":["boundary","code","history","real_world","consumers","recurrence"],"payoff":4,"effort":0,"risk":0,"corroborated":true,"positive_use":true,"failed_decisive_source":false,"unresolved_contradictions":0}]}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py rank
printf '%s\n' '{"candidates":[{"fingerprint":"synthetic/app:live-static-candidate","checks":["boundary","code","history","real_world","consumers","recurrence"],"payoff":4,"effort":0,"risk":0,"corroborated":true,"positive_use":false,"failed_decisive_source":false,"unresolved_contradictions":0}]}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py rank
```

Receipts: the positive-use input returned no candidates. The otherwise identical
negative control returned the candidate with confidence `1.0` and score `4.0`,
showing that the veto, rather than static scoring, caused the exclusion.

## 5. Named target and invalid mode combinations

```bash
printf '%s\n' '{"mode":"interactive","candidate":"retire legacy export endpoint","persist":null}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py mode
printf '%s\n' '{"mode":"scheduled","candidate":"retire legacy export endpoint","persist":null}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py mode
printf '%s\n' '{"mode":"interactive","candidate":null,"persist":"github"}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py mode
```

Receipts: the valid target returned `interactive-target`. Scheduled plus a named
target failed closed with exit `2`; interactive plus `persist:github` also failed
closed with exit `2`.

## 6. Scheduled persistence remains bounded

```bash
printf '%s\n' '{"persist_requested":false,"duplicate_count":0,"issue_exists":false,"candidate_count":1,"material_change":true,"write_authorized":true,"serialized":true}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py persistence
printf '%s\n' '{"persist_requested":true,"duplicate_count":0,"issue_exists":false,"candidate_count":1,"material_change":true,"write_authorized":false,"serialized":true}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py persistence
printf '%s\n' '{"persist_requested":true,"duplicate_count":2,"issue_exists":true,"candidate_count":0,"material_change":false,"write_authorized":true,"serialized":true}' | python3 skills/ops/trash-truck/scripts/rank_candidates.py persistence
```

Receipts: no grant returned `not-requested`; a grant without repository write
authorization returned `blocked`; duplicate canonical issues returned `blocked`
even when there was no material change. No command performed a GitHub write.

## Verification and mutation boundary

```bash
python3 skills/ops/trash-truck/evals/test_retirement_contract.py
git diff --check
git status --porcelain=v1 --untracked-files=all
```

The contract suite printed `Trash Truck retirement contract passed.`. The diff
check passed, and the worktree, index, and HEAD remained unchanged throughout
the dry exercises. The only subsequent mutation is this reviewable receipt file.
