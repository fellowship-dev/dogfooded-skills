# Issue #169 real-run receipts: issue-to-prd triage + cto-review dimension 4b

`issue-to-prd` and `cto-review` are agent-driven markdown procedures with no callable script
harness (unlike trash-truck's `rank_candidates.py`), so "run the new instructions for real" means
executing them by hand against real, live-fetched GitHub data, at commit
`0e432e12c1ac41ca152ca7e24a463f4596dde71c`. These are **read-only dry runs**: no comment was
posted, no label was applied, and no verdict was submitted to either live item. They exist to show
the new instructions produce the required structure against real data, not synthetic fixtures.

`gh` has no real binary on `PATH` in this environment (the `/opt/pylot/bin/gh` shim fails with
`real gh binary not found`); GitHub REST calls below went through `curl` with a short-lived GitHub
App installation token minted via `git-credential-pylot get`.

## 1. `issue-to-prd` stage 01 + 01b — fellowship-dev/dogfooded-skills#149

```bash
printf 'protocol=https\nhost=github.com\npath=fellowship-dev/dogfooded-skills.git\n\n' \
  | git-credential-pylot get | grep '^password=' | cut -d= -f2- > /tmp/gh_token.txt
curl -s -H "Authorization: Bearer $(cat /tmp/gh_token.txt)" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/fellowship-dev/dogfooded-skills/issues/149"
```

**Stage 01 handoff (real fetch)**: issue #149, state `open`, labels `[]`, title "retire: per-PR
skill ceremony — receipt emitters, comment-cursor, hex TSV receipts, release-train-runner (batch,
one PR)". Body lists six retirement items under an owner directive (Max, 2026-09-02).

**Stage 01b — repo search per item, real citations:**

| Item | Evidence | Status |
|---|---|---|
| 1. Stop emitting `review-state v1` receipt blocks | `skills/ops/double-check/tests/exact-head-receipt.test.sh:110-111` asserts `review-state` stays absent | done |
| 2. Delete comment-cursor promotion gate + restart.md/blocked.md | Same test line; `skills/ops/double-check/SKILL.md:41` promotion rule is already "equals the exact 40-hex head" | done |
| 3. Delete speckit-runner hex TSV + `SUPERVISOR_DISCLOSURE` | `grep -rln "verification-receipts\|SUPERVISOR_DISCLOSURE" skills/ops/speckit-runner/` → zero matches | done |
| 4. flowchad-runner: post verdict as PR comment, **stop applying** `chad-approves`/`chad-rejects` labels | `skills/ops/flowchad-runner/SKILL.md:78` already posts the `<!-- flowchad:verdict -->` comment, but the same line still says "apply the still-load-bearing `chad-approves`/`chad-rejects` label"; `skills/ops/flowchad-runner/stages/05-report/CONTEXT.md:83-84,220` also still applies it | **not done** |
| 5. cto-review: keep build-worker verification, drop body-receipt parsing | `skills/ops/cto-review/stages/01-setup/CONTEXT.md:206,238,341` still calls `/admin/build-worker/<id>` | done (verification retained) |
| 6. Delete release-train-runner skill (991 lines) | `find skills -type f -path "*release-train-runner*"` → zero matches | done |

**Verdict: `re-scope`.** Five of six items are already complete elsewhere in the repo. Smallest
version: drop only the label-application clause at `skills/ops/flowchad-runner/SKILL.md:78` and
`skills/ops/flowchad-runner/stages/05-report/CONTEXT.md:83-84,220` — `cto-review`'s read side
(`skills/ops/cto-review/stages/02-review/CONTEXT.md:65,67`) already treats `chad-approves`/
`chad-rejects` as non-blocking legacy labels, so nothing downstream depends on them still being
applied.

Per stage 01b's hard-gate rule this verdict stops the pipeline before stage 02 for issue #149 as
filed. **Dry run only** — no comment or label was applied to the live issue.

## 2. PRD mandatory sections — dry-run draft for the re-scoped need

Demonstrating what stage 06's mandatory sections look like once populated, using the smallest
version stage 01b named above as the hypothetical `prd`-path input:

> ## Smallest version that works
> Remove the label-application clause from `skills/ops/flowchad-runner/SKILL.md:78` ("apply the
> still-load-bearing chad-approves/chad-rejects label") and
> `skills/ops/flowchad-runner/stages/05-report/CONTEXT.md:83-84,220`; keep the existing
> `<!-- flowchad:verdict -->` PR-comment posting unchanged. No other file needs a change — items 1,
> 2, 3, 5, 6 of the original issue are already complete (stage 01b evidence table above).
>
> ## What this lets us delete
> - `skills/ops/flowchad-runner/SKILL.md:78`'s label-application clause
> - `skills/ops/flowchad-runner/stages/05-report/CONTEXT.md:83-84,220`'s verdict-label-application
>   steps
>
> Nothing else — the other five items named in fellowship-dev/dogfooded-skills#149 are already
> deleted or retired (cited above), so this PRD's own deletion surface is exactly these two label
> call sites.

Both sections are non-templated and every claim above carries a `file:line` citation, per the new
stage 06 fill-steps and citation rule.

## 3. `cto-review` dimension 4b — fellowship-dev/dogfooded-skills#170 (merged)

```bash
curl -s -H "Authorization: Bearer $(cat /tmp/gh_token.txt)" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/fellowship-dev/dogfooded-skills/pulls/170"
curl -s -H "Authorization: Bearer $(cat /tmp/gh_token.txt)" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/fellowship-dev/dogfooded-skills/pulls/170/files"
```

Real merged PR: "Port automation context_template procedures into owning skills", 3 files changed,
+103/-1, base `main` ← head `3447-port-automations-context-procedures`. Diff touches
`skills/ops/double-check/SKILL.md`, `skills/ops/pylot-cli/SKILL.md`, `skills/ops/vercel-deploy/SKILL.md`
— all markdown, no code.

**Dimension 4b applied to the real diff:**
- **Second mechanism?** `none`. The added sections document dispatch behavior that already exists
  in the named `fellowship-dev/pylot` automation rules (PR body: four rules "dispatch to
  `pylot.lead` with no `/skill-name`... the procedure itself needed a documented home") — the diff
  records an existing mechanism in its owning skill, it does not add a new one.
- **Smallest version?** `none`. No new config is introduced. The `vercel-deploy/SKILL.md:26`
  change is a one-sentence addition to an existing paragraph (verified in the fetched patch and in
  the file at HEAD), not a new abstraction or unused flag; the `double-check`/`pylot-cli` additions
  document pre-existing dispatch contracts rather than adding new call sites.

This is a post-hoc dry run on an already-merged PR — it does not reopen or re-verdict #170. It
demonstrates dimension 4b runs cleanly on a real diff and returns a cited `none` verdict rather
than a false positive, and that a genuine trigger (had one existed) would look exactly like the
flowchad-runner finding in §1: naming the specific mechanism/label and the exact line to retire.

## Verification and mutation boundary

```bash
python3 skills/ops/issue-to-prd/evals/outcomes_contract_harness.py
git diff --check
git status --porcelain=v1 --untracked-files=all
```

The outcomes-contract harness (stage 05c, unaffected by this change) printed "All checks passed."
The diff check passed. `git status` before and after these dry runs showed only this repo's own
tracked implementation changes for issue #169 plus this receipt file — no GitHub comment, label, or
issue/PR state changed on either #149 or #170.
