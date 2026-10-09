# Research: Fix pylot-cli Dispatch Prompt-Size Budget Doc

## Decision: prompt-size figure

**Decision**: State the Dispatch section's prompt-size rule as ~2560 bytes.
**Rationale**: Issue #198 cites `ECS_OVERRIDES_LIMIT_BYTES (8192) - DISPATCH_OVERRIDES_RESERVED_BYTES
(5632)` = 2560, from `fellowship-dev/pylot:gateway/modules/missions/dispatch-overrides-guard.mts`.
That repo is out of scope for this PR (Implementation Constraints: "Do NOT touch any file in
fellowship-dev/pylot") and not checked out locally, so the constants are taken as given from the
issue body, not independently re-derived — consistent with spec.md's Assumptions section.
**Alternatives considered**: Re-deriving the figure from a live `pylot` checkout — rejected, out of
scope and unnecessary for a doc correction that only needs to quote the issue's own cited figure.

## Decision: where the 4 rules currently live (doc-drift finding)

**Decision**: Treat the issue's cited line numbers as stale pointers to sections, not literal byte
offsets to edit blindly; locate each rule by content/heading match at implementation time.
**Rationale**: Live `skills/ops/pylot-cli/SKILL.md` (791 lines) does not match the issue's line
map:
- Dispatch section is still `## Dispatch a Mission` at lines 26-40 (matches issue), containing:
  prompt-size (line 33), `/skill` prefix (lines 35-37), `team.role` (lines 38-40).
- **No-secrets is NOT currently in the Dispatch section at all.** The issue's framing ("the other
  three dispatch-contract rules (`/skill` prefix, `team.role`, no-secrets) scattered across prose
  SKILL.md:26-40") overstates what's there — only 2 of those 3 rules are in range 26-40.
  The closest existing no-secrets statement for the *dispatch task contract* is under
  `## Preflight and dispatch` (line 217): "the task contract is self-contained, contains no
  secrets, and names the intended skill explicitly."
- The issue's separate "GitHub Auth Through the CLI" reference (cited as SKILL.md:450-451) is now
  at lines 629-640 (`## GitHub Auth Through the CLI`, no-secrets sentence at line 639-640:
  "Secrets: never in prompts or payloads — `pylot secrets`, then reference env var names."). Same
  content, shifted ~189 lines down — the file grew from unrelated merges since #198 was filed.
**Alternatives considered**: Editing by the issue's literal cited line numbers — rejected, those
offsets no longer point at the right text; would corrupt unrelated content. Deriving the no-secrets
line's wording from the GitHub Auth section — rejected, Implementation Constraints explicitly
forbid duplicating that section's wording; the Preflight-and-dispatch sentence is the correct
source to adapt into one Dispatch-section line.

## Decision: scope of the edit

**Decision**: Add a 4th (no-secrets) line to the Dispatch section, adapted from the Preflight-and-
dispatch wording, alongside reformatting the existing 3 rules — not a pure reformat of already-
present text.
**Rationale**: FR-002 requires all 4 rules to appear as one line each in the Dispatch section; since
no-secrets isn't there yet, satisfying FR-002 requires introducing it, not just reformatting.
**Alternatives considered**: Leaving no-secrets out of Dispatch and only fixing the byte figure —
rejected, contradicts the issue's explicit success metric (all 4 rules, one line each, in Dispatch).
