# Documentation-Accuracy Checklist: Fix pylot-cli Dispatch Prompt-Size Budget Doc

**Purpose**: Validate the requirement-writing quality of spec.md itself (not the implementation)
**Created**: 2026-10-09
**Feature**: [spec.md](../spec.md)

## Completeness

- [x] CHK001 Does the spec disclose that the no-secrets rule is not currently present in the Dispatch section, so FR-002 requires *adding* it rather than only reformatting existing prose? [Spec §FR-002] — Gap: only research.md disclosed this; fixed by adding an Assumptions bullet to spec.md.
- [x] CHK002 Does the spec name the source text the new no-secrets line should be adapted from? [Spec §FR-002] — Gap: only research.md named the Preflight-and-dispatch source; fixed by adding an Assumptions bullet to spec.md.
- [x] CHK003 Does the spec identify every section of SKILL.md whose content must NOT change, beyond the one section it names? [Spec §FR-003] — Re-reviewed (correction pass): FR-003 is a blanket prohibition ("No other section... may be changed"), not a partial enumeration, so it already covers every section by exclusion; GitHub Auth is cited only as the one example likely to be confused with the new rule. Adequate as written.

## Clarity

- [x] CHK004 Does the spec define what "one line each" means precisely — a single physical source line, vs. a single rendered bullet that may visually wrap? [Spec §FR-002]
- [x] CHK005 Does the spec make clear whether "dispatch-contract rules" is a term already defined elsewhere in the skill, or newly coined by this issue? [Spec §FR-002] — Re-reviewed (correction pass): FR-002 defines the term by immediate parenthetical enumeration (`/skill` prefix, `team.role`, prompt size, no-secrets) at every use; sufficient for a ≤50-line terse spec, no separate glossary needed.

## Consistency

- [x] CHK006 Does the spec's Edge Cases line reference for the GitHub Auth no-secrets sentence match the line actually verified elsewhere in this feature's artifacts? [Spec §Edge Cases] — Gap found (F1 in analysis): spec.md cited stale `SKILL.md:450-451`; corrected to `~629-640` with a drift note.
- [x] CHK007 Do FR-003 and FR-004 state the same scope boundary in compatible, non-redundant terms? [Spec §FR-003, §FR-004] — Reviewed: FR-003 fences *content within SKILL.md*, FR-004 fences *which files/repos* may change; distinct, non-conflicting.

## Measurability

- [x] CHK008 Can "all four dispatch-contract rules... each appear as one line" (SC-002) be verified by an objective count, independent of subjective judgment about what counts as "one rule"? [Spec §SC-002] — Re-reviewed (correction pass): FR-002 names the exact 4 rules, so "one rule" isn't left to interpretation; independent review's own verification (counted 4 bold-rule lines) confirms this was objectively checkable in practice.
- [ ] CHK009 Does SC-003 ("no duplicate or contradictory no-secrets statement") define what would count as "contradictory" versus merely "differently worded"? [Spec §SC-003] — Still genuinely open; low stakes (judgment call for a single-reviewer doc PR), left for a future spec iteration if this pattern recurs.

## Coverage

- [x] CHK010 Does the spec cover the case where the issue's cited line numbers no longer match the live file? [Spec §Edge Cases] — Gap found: spec.md was silent on this; research.md covered it but spec.md itself did not reference the drift until this checklist's fix.

## Edge Cases

- [ ] CHK011 Does the spec state what to do if a rule's content can't fit a single physical line without truncation? [Gap] — Still open; moot in practice (all 4 rules fit one line in the shipped text), kept open as a hypothetical for any future amendment.
- [x] CHK012 Does the spec address whether markdownlint warnings pre-existing elsewhere in the file are in scope to fix incidentally? [Spec §FR-003] — Re-reviewed (correction pass): FR-003's blanket "no other section may be changed" already answers this by implication — fixing unrelated lint warnings elsewhere would itself violate FR-003, so they're out of scope without needing a separate statement.
- [x] CHK013 Does the spec distinguish the dispatch-payload no-secrets rule (new, in Dispatch) from the credential-handling no-secrets rule (existing, in GitHub Auth) clearly enough that an implementer wouldn't conflate them? [Spec §Edge Cases, §FR-003]

## Notes

- Checked items (`[x]`) were reviewed and either confirmed adequate or had their gap fixed directly
  in spec.md (see CHK001, CHK002, CHK006, CHK010), or re-reviewed on the correction pass and found
  already adequate on closer reading (CHK003, CHK005, CHK008, CHK012 — each resolved by an existing
  FR's blanket/enumerated phrasing, not a new edit).
- CHK009 and CHK011 remain genuinely open: both are real, low-stakes wording gaps that don't block
  this doc-only fix — the shipped text already satisfies FR-001/FR-002 unambiguously in practice
  (verified in tasks.md T001-T007 and the independent review's own re-verification). Left open for
  a future spec iteration if this pattern recurs.
