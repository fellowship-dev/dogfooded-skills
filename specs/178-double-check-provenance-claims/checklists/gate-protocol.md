# Gate-Protocol Checklist: Reconcile Diff-Provenance Claims in double-check

**Purpose**: Validate the *requirements writing quality* of spec.md for a claim-classification
gate — not the implementation.
**Created**: 2026-09-12
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] CHK001 Is the new claim category's boundary (what makes a claim "provenance/range" vs.
      ordinary) stated, not left to the reader to infer? [Spec §Requirements FR-001]
- [x] CHK002 Is the evidence source for the new category named explicitly, not just implied?
      [Spec §Requirements FR-002]
- [x] CHK003 Is the disposition for every reachable state (contradicted, no-SHA, undiffable)
      specified, not just the "obviously wrong" case? [Spec §Requirements FR-003]
- [ ] CHK004 Does the spec state what happens if the range diff *succeeds* and confirms the claim
      (the `backed` case for this category)? [Gap — spec states only the `unbacked` path]

## Clarity

- [x] CHK005 Is "range" defined relative to a fixed reference point (setup head SHA), not a vague
      "current" or "latest"? [Spec §Edge Cases]
- [x] CHK006 Is "undiffable" given operational meaning (cannot produce a diff) rather than left as
      an unquantified adjective? [Spec §Requirements FR-003]
- [x] CHK007 Is the distinction between `unbacked` and `unknown` for this category stated plainly,
      not just cross-referenced? [Spec §Acceptance #2]

## Consistency

- [x] CHK008 Does the "must not widen" edge case use the same category boundary language as FR-001,
      rather than a second, looser description? [Spec §Edge Cases vs FR-001]
- [x] CHK009 Is the range terminus (setup head SHA, not local `HEAD`) stated identically in both
      the Edge Cases and the Assumptions sections? [Spec §Edge Cases, §Assumptions]

## Measurability

- [x] CHK010 Can SC-001 be verified by a third party from the spec alone, without access to the
      live pipeline? [Spec §Success Criteria SC-001]
- [x] CHK011 Can SC-002 be verified without re-running the full gate (i.e., is the "ordinary claim"
      example concrete enough to check by hand)? [Spec §Success Criteria SC-002]
- [x] CHK012 Is SC-003 checkable by a mechanical diff command, or does it rely on subjective
      judgment of "additive"? [Spec §Success Criteria SC-003]

## Coverage

- [x] CHK013 Does User Story 1's acceptance cover both the classification step and the disposition
      step, or only one of the two? [Spec §User Story 1 Acceptance #1-2]
- [ ] CHK014 Is there a story/requirement covering a claim that names *multiple* ranges or SHAs in
      one sentence (e.g., "since either `<sha1>` or `<sha2>`")? [Gap — not addressed]

## Edge Cases

- [x] CHK015 Is the "claim cites no SHA" boundary condition explicitly dispositioned rather than
      left to fall through to a default? [Spec §Requirements FR-003]
- [x] CHK016 Is the "range diff cannot be produced" (e.g., SHA not in history) condition
      distinguished from "range diff succeeds and contradicts"? [Spec §Requirements FR-003]
- [x] CHK017 Is the non-widening constraint (ordinary claims unaffected) paired with a concrete
      counter-example, not just an abstract assertion? [Spec §Success Criteria SC-002]

## Notes

- CHK004 and CHK014 are genuine gaps in spec.md, not blocking: the issue's own scope statement
  ("Ordinary, non-range claims are unaffected — no new false `unbacked` verdicts") implies the
  `backed` case for this category falls out of the same range-diff mechanism when it confirms the
  claim, and multi-SHA claims are a rarer shape the base rule already generalizes to (check the
  *cited* range, whichever SHA(s) it names). Neither required a spec.md edit; resolved below.
- Independent review (post-implementation) proposed closing CHK004 by adding an explicit `backed`
  clause to the taxonomy bullet in `02-review/CONTEXT.md`. Declined: the issue's Out-of-Scope
  section freezes the `backed`/`elsewhere`/`unbacked` bullet definitions verbatim — only the
  extraction sentence and the `unbacked` bullet may grow. A `backed` case for this category is
  already covered implicitly (the claim is checked against the same range diff; if it doesn't
  contradict or fail to produce, it falls through to `backed` like any other claim) — CHK004
  remains a documented, non-blocking gap rather than a code change.
