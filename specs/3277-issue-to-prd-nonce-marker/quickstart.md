# Quickstart: verify the nonce-keyed marker migration

Doc-only change, no build/run step. Every check below is a `grep` a reviewer can run verbatim from
the repo root against `skills/ops/issue-to-prd/`. All must pass before the PR is opened.

## 1. Old (bare, non-nonce) marker form is gone

```bash
grep -rn 'pylot\] outcome=' skills/ops/issue-to-prd/
```
Expected: zero hits.

## 2. Both sites now use the nonce variable

```bash
grep -rn 'PYLOT_OUTCOME_NONCE' skills/ops/issue-to-prd/
```
Expected: two hits — one in `stages/00-automation-guard/CONTEXT.md`, one in
`stages/06-ask-or-structure/CONTEXT.md`.

## 3. No literal nonce value was introduced

```bash
grep -rn 'pylot:[0-9a-fA-F]' skills/ops/issue-to-prd/
```
Expected: zero hits (a literal nonce would look like `[pylot:abc123]`; the only accepted form is
the `$PYLOT_OUTCOME_NONCE` variable).

## 4. Status word unchanged at both sites

```bash
grep -n 'status=success' skills/ops/issue-to-prd/stages/00-automation-guard/CONTEXT.md \
  skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md
```
Expected: one match in each file.

## 5. AC-3 dedup guard is present and states all three conditions

```bash
grep -n 'open-questions' skills/ops/issue-to-prd/stages/06-ask-or-structure/CONTEXT.md
```
Expected: the existing label-apply line, plus new guard prose naming the label as one of the three
conditions (label present, prior bot question, no later non-bot comment).

## 6. Diff is exactly the two in-scope files

```bash
git diff --stat origin/main...HEAD -- skills/
```
Expected: exactly two files listed, both under `skills/ops/issue-to-prd/stages/`.

## 7. The other 12 affected skills are untouched

```bash
git diff --stat origin/main...HEAD -- skills/ops/build-train skills/ops/cto-review \
  skills/ops/deps-runner skills/ops/double-check skills/ops/flowchad-runner \
  skills/ops/release-train-runner skills/ops/review-pr skills/ops/security-runner \
  skills/ops/speckit-proc skills/ops/speckit-runner skills/ops/vercel-deploy \
  skills/meta/procedure-builder
```
Expected: no output.

## 8. No Spec-Kit scaffolding shipped

```bash
git diff --stat origin/main...HEAD -- .specify .claude/commands specs
```
Expected: no output — this working scaffolding is deleted before the PR (see plan.md's final
task); its content lives in the PR body, not the tree.
