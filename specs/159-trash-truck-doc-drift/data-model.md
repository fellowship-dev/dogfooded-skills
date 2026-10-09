# Phase 1 Data Model: Trash Truck Doc Drift Correction

N/A — no runtime entities, no data, no state transitions. This feature edits prose in four
markdown files. In place of entities, this documents every edit site, verified against the
current repo state (not the issue text's line numbers, which have minor drift):

| File | Line(s) | Current text (verified) | Edit |
|---|---|---|---|
| `candidate-packet.md` | 135 | "...fingerprint, manifest, exclusions, and evidence cutoff displayed at selection time." | Drop ", and evidence cutoff" → "...fingerprint, manifest, and exclusions displayed..." |
| `candidate-packet.md` | 113 | "repository HEAD, deployed revision, evidence cutoff, and freshness;" | **No change** — correct, describes a *displayed* field |
| `canonical-issue.md` | 40, 58 | describes evidence cutoff as displayed / explicitly non-material | **No change** — correct, load-bearing |
| plan doc | 181 (KTD5), now 185 post-banner | "...plus the displayed manifest and evidence cutoff." | Drop "and evidence cutoff" → "...plus the displayed manifest." |
| plan doc | above H1 | no banner | Add one-line banner pointing to `skills/ops/trash-truck/references/` as normative |
| `README.md` | 67 (row) | row cell has no breaking-grammar mention | Append breaking-grammar clause to row cell |
| `README.md` | 69 (blockquote) | existing breaking-grammar blockquote | **No change** — keep, belt and braces |
| `SKILL.md` | 28 (mode table) | "Presence of an interactive owner is unclear → Scheduled fail-safe → report only" | Reword to flag as instruction-level/unenforceable, consistent with new Boundaries bullet |
| `SKILL.md` | 32-39 (Boundaries) | no owner-presence-unenforceable bullet | Add bullet naming it instruction-level + compensating control |
| plan doc | 178 (KTD2), now 182 post-banner | "An invocation that cannot prove an interactive owner is present behaves as scheduled/report-only." | Align with same honest framing (no mechanism claim beyond what's true) |

## Consistency invariant

After edits, grepping `owner is unclear|owner presence|interactive owner` across
`SKILL.md` + plan doc must show all three sites (mode table, Boundaries, KTD2) using the same
"unenforceable, falls back safely, compensating control = explicit fingerprint selection"
framing — no site left asserting a mechanical guarantee the validator can't check.
