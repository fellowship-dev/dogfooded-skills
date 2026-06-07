# Risk & Merge Matrices (lifted verbatim from deps-runner)

Used by stage 03 (risk-eval) for classification and stage 05 (merge-decision) for the action.

## Risk classification matrix

| Bump type | Direct import? | Dep type | Risk |
|-----------|---------------|----------|------|
| Patch (x.x.1->x.x.2) | No (transitive) | Any | Low |
| Patch | Yes | Dev/build | Low |
| Patch | Yes | Runtime | Low |
| Minor (x.1->x.2) | No | Any | Low |
| Minor | Yes | Dev/build | Medium |
| Minor | Yes | Runtime | Medium |
| Major (1.x->2.x) | No | Any | Medium |
| Major | Yes | Dev/build | Medium |
| Major | Yes | Runtime | High |
| Any bump on core framework (rails, strapi, react, etc.) | -- | -- | High |

## Merge-decision matrix (standard repos)

| Build | Tests | Risk | Action |
|-------|-------|------|--------|
| pass | pass | Low | **Auto-merge with [skip ci]** (or label if `merge_strategy: label-only`) |
| pass | pass | Medium (no direct usage) | **Auto-merge with [skip ci]** (or label if `merge_strategy: label-only`) |
| pass | pass | Medium (direct usage) | **Write targeted tests first** (then flag for manual review) |
| pass | pass | High | **Flag for Max** with analysis |
| fail | any | any | **Flag for Max** |
| any | fail | any | **Flag for Max** |

## Merge-decision matrix (Python repos, docker build verification)

For Python repos with **no test suite** but a `container/Dockerfile`, docker build replaces tests.

| Docker build | Risk | Action |
|-------------|------|--------|
| pass | Low | Auto-merge with [skip ci] |
| pass | Medium (no direct usage) | Auto-merge with [skip ci] |
| pass | Medium/High | Flag for Max |
| fail | any | Flag for Max |

## Hard rules

- **Never auto-merge high risk.** Always flag for Max.
- **[skip ci] on all merges.** CI already ran on the PR branch.
- **PRs that needed new tests → manual review.** Even if tests pass, Max sees them first.
- **Dependabot doesn't bump companion packages** (react without react-dom, @strapi/strapi
  without @strapi/plugin-*). Version mismatches that fail builds → classify High, flag.
- **Lockfile-only PRs are still worth merging** — verify build and merge.
