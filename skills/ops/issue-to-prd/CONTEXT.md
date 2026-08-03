# issue-to-prd — Overview

ICM procedure that converts a GitHub issue into a structured PRD or posts clarifying questions.

## Purpose
Issues arrive underspecified. This procedure catches context gaps, clarity gaps, and failure modes
before an agent starts work — preventing wasted tokens and off-target PRs.

## Replaces
- `external-rule` (greet) event rule: replaced by `challenge-new-issue`
- Manual `build-prd` skill for the autonomous pipeline case (manual stays for interactive use)

## Architecture
9 sequential stages. Each stage is atomic: defined inputs, defined outputs, explicit side effects.
Stage 00 is a guard. Stages 01-05 are pure analysis (no side effects). Stage 05b may dispatch a
mission but writes nothing to GitHub. Stages 06-07 write to GitHub.

## Key invariants
- Stage 00: the ONLY place this skill decides it is not allowed to run. Aborts emit `status=success`.
- Stages 01-05: read-only. No GH comments, no label changes.
- Stage 05b: no GH writes at all. Its only side effect is `pylot dispatch`, and only on an explicit
  owner signal.
- Stage 06: the ONLY decision point, and the ONLY place a comment is posted. Everything batched
  into ONE comment — including anything stage 05b wants said.
- Stage 07: runs ONLY when stage 06 produced a PRD (not a questions list).
- Labels added, never removed. `prd-ready` signals "has a PRD" and enables deep-triage to
  greenlight; `ready-to-work` is withheld while prototype variants are pending.

## Blast radius

This skill fires on **every new issue** in every enabled org (`challenge-new-issue`: 318 fires) and
again whenever a question is answered (`rechallenge-after-answers`: 477 fires). Anything added here
runs org-wide, hundreds of times, unattended. Two consequences are load-bearing:

- **Stage 07 rewrites the issue body.** That destroyed an owner-authored epic checklist and a
  machine-read dedupe marker on 2026-08-02
  ([pylot#2837](https://github.com/fellowship-dev/pylot/issues/2837)). Stage 00 now keeps it off
  `no-automation` and `epic` issues; making the rewrite itself non-destructive is #2837's job.
- **Any new hop must be gated to near-zero by default.** Stage 05b's design rule — auto-detection
  asks, only humans dispatch — exists for this reason, not out of caution about prototypes
  specifically.

## Folder map
```
SKILL.md           — invocation reference
CONTEXT.md         — this file
shared/            — prd-template.md, failure-modes.md, prototype-mission-brief.md
stages/00,01-05,05b,06-07/  — CONTEXT.md + output/ per stage
stages/03/references/   — gap-checklist.md
stages/05b/references/  — gate-checklist.md
```

## Emit on completion
- Guard path: `[pylot] outcome="skipped: <label|state> — issue-to-prd does not structure this issue" status=success`
- Questions path: `[pylot] outcome="questions posted" status=success`
- PRD path: `[pylot] outcome="PRD published" status=success`
