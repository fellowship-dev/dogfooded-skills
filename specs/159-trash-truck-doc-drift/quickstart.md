# Quickstart: Verify Trash Truck Doc Drift Correction

Happy-path smoke test — run after implementing tasks.md, before opening the PR.

1. **Baseline still green**:
   `python3 skills/ops/trash-truck/evals/test_retirement_contract.py`
   → expect `Trash Truck retirement contract passed.`

2. **Scope fence** — run **unscoped**, no path filter (a path-filtered check can't see files
   outside its own prefixes and previously masked an out-of-scope scaffolding leak — see
   finding F-001):
   `git diff --name-only origin/main` →
   expect exactly `README.md`, `skills/ops/trash-truck/SKILL.md`,
   `skills/ops/trash-truck/references/candidate-packet.md`,
   `docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md`, plus this feature's own
   `specs/159-trash-truck-doc-drift/**` design record (the established `specs/<feature>/`
   convention — see README.md's Contributing section and e.g. `specs/134-invariant-matrix/`).
   It must **never** include `.specify/**` or
   `.claude/commands/speckit.*.md` — that transient Spec-Kit bootstrap scaffolding must not ship
   (precedent: commits `56d2683`, `ec4c63d`, `fa3067d`, `fa930a2` all removed this exact pattern
   before merge).

3. **Evidence-cutoff count** (excludes this feature's own planning docs under `specs/`,
   which discuss "evidence cutoff" as meta-commentary):
   `grep -rc "evidence cutoff" --include=*.md . --exclude-dir=specs` → total 3, surviving at
   `candidate-packet.md:113`, `canonical-issue.md:40`, `canonical-issue.md:58` only.

4. **Packet sentence reads grammatically**: open `candidate-packet.md:135`, confirm
   "...fingerprint, manifest, and exclusions displayed at selection time." with no dangling
   comma.

5. **Plan doc untouched structurally**: `git log --diff-filter=R -- 'docs/plans/*'` shows no
   rename; `git diff docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md` shows
   only the banner + KTD5 + KTD2 lines changed.

6. **README row carries the fact**: render `README.md` (e.g. GitHub preview) and confirm the
   `ops/trash-truck` row cell itself states the breaking grammar change; blockquote at `:69`
   still present.

7. **Owner-presence honesty**:
   `grep -n "owner is unclear\|owner presence\|interactive owner" skills/ops/trash-truck/SKILL.md docs/plans/2026-09-05-001-refactor-trash-truck-retirement-plan.md`
   → all matches read as unenforceable + name the compensating control; none assert a
   mechanical guarantee.

8. **No policy leak**: `grep -rniE "pylot|fellowship-dev|ready-to-work|needs-work|staging" skills/ops/trash-truck/`
   → no new matches vs. baseline.

9. **Lint**: `npx markdownlint-cli2` on the four changed files → no new warnings.
