# `_core/` template — provenance

This is a **vendored copy** of the canonical ICM `_core/` directory. It is bundled
with the `procedure-builder` skill so a fresh ICM workspace can be bootstrapped
offline and deterministically (no runtime download).

## Source

- Repo: https://github.com/RinDig/Interpreted-Context-Methdology
- Path: `_core/`
- Vendored on: 2026-05-07
- Vendored by: `procedure-builder` Stage 00 (Bootstrap) updates this directory
  by re-running the curl commands below if a refresh is requested.

## Refresh procedure

```bash
BASE=https://raw.githubusercontent.com/RinDig/Interpreted-Context-Methdology/main/_core
TARGET=skills/meta/procedure-builder/templates/_core

curl -sf "$BASE/CONVENTIONS.md" -o "$TARGET/CONVENTIONS.md"
curl -sf "$BASE/placeholder-syntax.md" -o "$TARGET/placeholder-syntax.md"
curl -sf "$BASE/templates/questionnaire-template.md" -o "$TARGET/templates/questionnaire-template.md"
curl -sf "$BASE/templates/stage-context-template.md" -o "$TARGET/templates/stage-context-template.md"
curl -sf "$BASE/templates/workspace-claude-template.md" -o "$TARGET/templates/workspace-claude-template.md"
curl -sf "$BASE/templates/workspace-context-template.md" -o "$TARGET/templates/workspace-context-template.md"
```

Run this only when you've reviewed upstream changes and decided to adopt them.
Do not auto-update — the canonical version is whatever is committed here.

## Why vendor instead of fetching at runtime

- **Offline / Fargate dispatch** — the skill must work without network access
- **Determinism** — running `procedure-builder` against the same spec twice must
  produce the same `_core/` regardless of upstream drift
- **Auditability** — diffs to `_core/` are visible in the skill's git history
