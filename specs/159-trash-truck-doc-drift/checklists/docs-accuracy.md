# Docs-Accuracy Checklist: Trash Truck Doc Drift Correction

**Purpose**: Validate requirements-writing quality for a doc-truthfulness spec — whether the
spec's claims about what must be stated are themselves complete, unambiguous, consistent,
measurable, and cover the relevant scenario classes.
**Created**: 2026-10-09
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] CHK001 Does the spec name every file allowed to change, with no file left implicit? [Spec §Requirements, FR-005]
- [x] CHK002 Does the spec state which of the 5 original "evidence cutoff" mentions must survive untouched, not just the count? [Spec §Requirements, FR-001 — now names packet:113, canonical-issue.md:40,58]
- [x] CHK003 Does the spec define what "consistent" means for the owner-presence claim across 3 sites, beyond "all agree it's unenforceable"? [Spec §Success Criteria, SC-003 — now gives the exact grep pattern]

## Clarity

- [x] CHK004 Is "the binding claim" in FR-001 unambiguous about which sentence(s) it refers to? [Spec §User Story 1 acceptance names the exact words]
- [x] CHK005 Is "itself" in FR-002 ("README row MUST itself state...") precise enough to distinguish row-cell text from the existing blockquote? [Spec §Success Criteria, SC-002]
- [x] CHK006 Is "the compensating control" in User Story 3 named concretely enough to be checked without re-reading the issue PRD? [Spec §User Story 3 — "(exact-fingerprint owner selection)"]

## Consistency

- [x] CHK007 Does SC-001's verification command agree with the scope implied by FR-001 (i.e., excludes the spec's own meta-discussion of "evidence cutoff")? [Resolved — scoped to `--exclude-dir=specs` after analyze found the drift]
- [x] CHK008 Do FR-005's four named files match the four files referenced across User Stories 1–4 with no fifth file implied anywhere? [Spec §Requirements, FR-005]
- [x] CHK009 Does the Assumptions section's claim that validator code stays untouched match FR-001–FR-004's scope (none target `rank_candidates.py`)? [Spec §Assumptions]

## Measurability

- [x] CHK010 Is SC-001 ("totals 3") objectively verifiable without interpretation? [Spec §Success Criteria, SC-001]
- [x] CHK011 Is SC-003 measurable, or does it rely on subjective judgment of "consistent"? [Resolved — SC-003 now carries the exact grep pattern, matching SC-001/SC-002's style]
- [x] CHK012 Is SC-004 measurable without a recorded baseline value to diff against? [Resolved — SC-004 now quotes the baseline string]

## Coverage

- [x] CHK013 Does the spec address all 4 of the issue's in-scope items (2, 3, 4, 5), with none silently dropped? [Spec §User Scenarios, US1–US4]
- [x] CHK014 Does the spec explicitly cover the out-of-scope items (issue items 1 and 6) so a reader doesn't expect this feature to resolve them? [Spec §Assumptions]
- [x] CHK015 Does the spec cover the "optional, non-blocking" items from the issue (e.g. `repo_head`/`deployed_revision` clause, `superseded_by` frontmatter key) by explicitly marking them out of scope? [Resolved — new Assumptions bullet declines both explicitly]

## Edge Cases

- [x] CHK016 Does the spec state what must NOT change in the plan doc (rename, delete, reword body) as a testable boundary, not just a general instruction? [Spec §User Story 4]
- [ ] CHK017 Does the spec address the risk that the plan doc's own line numbers shift when the banner is inserted, affecting any line-numbered cross-references? [By design, not fixed in spec.md: line numbers are an implementation/provenance detail, not a WHAT/WHY spec concern per speckit-specify's own rules. The drift was caught and fixed where it actually lives — data-model.md and invariant-matrix.tsv provenance fields — during the analyze pass.]

## Notes

- All items resolved except CHK017, which is intentionally left open: spec.md correctly stays
  implementation-detail-free, and the line-number drift it describes was fixed in the artifacts
  that actually carry line numbers (data-model.md, invariant-matrix.tsv), not in spec.md itself.
