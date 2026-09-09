# `.specify/` — vendored Spec-Kit scaffolding

This directory is copied source, not a package dependency.

## Upstream

- **Fork:** [`fellowship-dev/spec-kit`](https://github.com/fellowship-dev/spec-kit) (default source used by `setup-speckit`)
- **Original upstream:** [`github/spec-kit`](https://github.com/github/spec-kit)
- **License:** MIT (see upstream repository for full license text; no local NOTICE file is currently bundled — add one if compliance requires shipping the license text alongside the vendored copy)

`setup-speckit`'s `SKILL.md` clones the fork above at `HEAD` (shallow clone, no commit pin) and copies `scripts/bash/*.sh` and `templates/*` into a target repo's `.specify/`. This repo's own `.specify/` tree was populated the same way and is consumed by `speckit-runner`'s producer prompt, which instructs a worker to bootstrap from it at runtime in the target repo.

## Local divergence from upstream

`scripts/bash/common.sh` in this tree carries a **local fix that is not present upstream**: `get_feature_paths` resolves the active feature by git branch prefix first (see `feature_json_matches_feature_dir` and the numeric-prefix matching in `find_feature_dir_by_number`), and only falls back to the committed `.specify/feature.json` pointer for non-git repos where that pointer actually matches the resolved feature directory. Upstream gives `.specify/feature.json` priority unconditionally, which lets a stale pointer from one feature branch silently redirect `/speckit.plan` on a different branch to the wrong feature directory (tracked as review finding R1 on PR #167 / issue #134).

**If this tree is ever re-vendored from upstream or the fork, re-apply this branch-prefix-priority behavior** — a straight copy will silently revert the fix and reintroduce the cross-branch redirect defect. `skills/ops/speckit-runner/tests/invariant-matrix.test.sh` ("git branch routing ignores a stale repository-global feature pointer") regression-tests this behavior against the vendored copy under `tests/fixtures/invariant-matrix/specify-scripts/common.sh`.
