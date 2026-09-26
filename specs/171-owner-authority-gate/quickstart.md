# Quickstart: Owner-Authority Gate Narrows `security` Parking

Verification is static — no live `cto-review`/`review-pr` mission is runnable from this PR (no
`gh` auth to `fellowship-dev/pylot` at test/CI time). This is the smoke test a reviewer or CI runs.

## Happy path

1. `python3 skills/ops/cto-review/tests/test_owner_gate_contract.py`
2. Expect exit 0. The test asserts, against `owner-gate-fixtures.json`:
   - Replaying the **pylot#3372** fixture (schema migration on the normal review path) classifies
     `owner_authority_class: none` and does not apply `waiting-on-owner`.
   - Replaying the **pylot#3408** fixture (a `credential`-named file, no secret exposure)
     classifies `owner_authority_class: none` and does not apply `waiting-on-owner`.
   - A `security`-labelled fixture with class `none` reaches the merge bar, not the park.
   - A human-applied `waiting-on-owner` fixture with class `none` still parks (AC6 — the OR, not a
     conjunction).
   - One fixture per taxonomy class applies `waiting-on-owner` with a populated decision line and
     answerer.
3. Grep-based text assertions over the edited Markdown confirm: no site in `skills/ops/cto-review/`
   or `skills/ops/review-pr/` describes `security` as a hold/block (AC1); the taxonomy appears
   verbatim and closed at exactly five classes (AC3); the generic "carries label(s) X" sentence is
   gone (AC5).

## Also run

- Every entry in `.github/workflows/tests.yml`'s `tests=` list (not just the new one) — the guard
  step fails the build if a test file on disk is missing from that list.
- `markdownlint` against `.markdownlint.json` for every edited file.
