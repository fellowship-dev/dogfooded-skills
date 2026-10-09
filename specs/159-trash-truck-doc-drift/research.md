# Phase 0 Research: Trash Truck Doc Drift Correction

No `[NEEDS CLARIFICATION]` markers in spec.md, no new dependencies, no integrations — research
is limited to four wording/placement decisions, all already settled by the issue PRD and
repo-observable evidence.

## Decision 1 — Evidence-cutoff binding wording

- **Decision**: `candidate-packet.md:135` reads "...binds the owner only to the fingerprint,
  manifest, and exclusions displayed at selection time." Plan KTD5 drops "and evidence cutoff".
- **Rationale**: `rank_candidates.py:128` — `keys = ("fingerprint", "manifest_digest",
  "repo_head", "deployed_revision")` — evidence cutoff is not in the bound key tuple.
- **Alternatives considered**: Re-add `evidence_cutoff` to the validator's key tuple instead
  (rejected — issue's Implementation Constraints forbid code→docs fixes; it would also
  re-create the CTO-1 deadlock since cutoff advances are declared non-material).

## Decision 2 — Plan doc normativity: banner vs. relocate

- **Decision**: Add a one-line banner above the H1 pointing at
  `skills/ops/trash-truck/references/`; keep the file in `docs/plans/`.
- **Rationale**: `README.md:103` assigns `specs/<number>-<slug>/` to active implementation
  specs and `docs/plans/` to non-normative delivery records; a completed record moving into
  `specs/` would contradict that hierarchy.
- **Alternatives considered**: Moving the doc under `specs/<n>-<slug>/` (rejected — contradicts
  README's own hierarchy); citing a `docs/information-architecture.md` (rejected — that file
  does not exist in this repo, it is a `pylot`-repo doc; citing it would add a second source of
  truth across repos).

## Decision 3 — README breaking-grammar discoverability

- **Decision**: Append a breaking-change clause directly in the `ops/trash-truck` row cell at
  `README.md:69`, pointing down to the existing blockquote at `:71` (keep both — belt and
  braces, not a move).
- **Rationale**: A reader who scans only the table currently misses the blockquote below it;
  the grammar break is the single highest-impact fact for an existing consumer.
- **Alternatives considered**: Moving the blockquote's content entirely into the row (rejected
  by issue scope — "Keep the existing blockquote... belt and braces, not a move").

## Decision 4 — Owner-presence fail-safe honesty wording

- **Decision**: Mirror the existing honest-limitation paragraph at the end of "Refresh and
  Invalidation" in `candidate-packet.md:148` ("`rank_candidates.py approval` only sees what the
  curator gives it... Treat a `valid: true` result as no stronger than..."): state what the
  mechanism cannot check, then name the compensating control.
- **Rationale**: `rank_candidates.py:109-122` — `resolve_mode()` returns
  `interactive`/`interactive-target` purely from the passed `mode` string; it has no notion of
  owner presence. The compensating control (execution additionally requires an explicit owner
  selection of an exact fingerprint, §5–§7, which a scheduler cannot synthesize) is real and
  already documented elsewhere, so it only needs naming, not building.
- **Alternatives considered**: Adding owner-presence detection to `resolve_mode()` (rejected —
  issue's Implementation Constraints explicitly forbid this; it would be a mechanism change,
  not a documentation honesty fix).
