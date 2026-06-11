# Stage 02: Cohesive CTO Review (subagent — isolated critical judgement)

This is the ICM win: the whole-diff judgement runs here, in clean isolated context, seeing ONLY the
setup handoff. Do NOT split this into per-file or per-dimension subagents — a PR is reviewed in
cohesion, with every dimension weighed against the same full diff at once.

## Inputs
- `.procedure-output/cto-review/01-setup/handoff.md`

## Task
Read the setup handoff — the full diff, PR metadata, repo context, merge state, CI status. Form ONE
strategic CTO verdict covering all dimensions together. Produce the verdict, the filled checklist,
and the numbered action items. No GH side effects in this stage.

If the setup handoff has `merge_state: merged`, frame the output as a **post-merge review note**
(findings + follow-ups), not a merge gate. If `short_circuit: closed-no-merge` is present this stage
should not have been invoked — write a no-op handoff and exit.

## The CTO review is strategic, not code-level
Code quality was already covered by the `reviewed` and `double-checked` phases. Focus on: docs gaps,
ops holes, downstream risk, security, and merge strategy — reading the WHOLE diff in one pass.

**Skip tooling-enforced findings**: Do not surface lint errors, formatting violations, or type errors
that the project's CI/CD pipeline already catches. Reserve judgement for logic bugs, design issues,
missing requirements, and scope problems that static analysis cannot detect.

## Dimensions to weigh (all against the same full diff)

### 0. Spec Conformance
Read the `## Spec` section of the setup handoff.

**If `spec_source: none`**: write "No spec available — skipping conformance check" under this
dimension and proceed to dimension 1.

For each requirement discernible in the spec body, evaluate the diff:

| Requirement | Status | Notes |
|-------------|--------|-------|
| {req summary} | ✅ satisfied / ⚠️ partial / ❌ missing | {detail} |

Also check:
- **Scope creep** — behaviour added to the diff that the spec did not ask for
- **Wrong** — requirement appears implemented but is incorrect (inverted condition,
  wrong field, mismatched contract, wrong HTTP method)

Finding types: **Missing** · **Partial** · **Scope creep** · **Wrong**

A Spec finding does NOT automatically override the overall verdict unless a requirement is entirely
missing or clearly wrong; use your CTO judgement to decide if it rises to REWORK.

### 1. Documentation
For each doc file that SHOULD be updated given the changes, mark status:

| File | Expected update | Status |
|------|----------------|--------|
| `.env.example` | New env vars added? | ✅ / ❌ |
| `README.md` | New features documented? | ✅ / ❌ |
| `docs/setup.md` or equivalent | Setup steps updated? | ✅ / ❌ |
| `CHANGELOG.md` | Entry added (if maintained)? | ✅ / ❌ |

Look specifically for: new env vars not in `.env.example`; new CLI commands/flags with no docs
update; new setup steps not in setup guides; new features shipped to templates/blueprints.
Documentation gaps are the #1 CTO concern — a feature shipped without docs is missed at onboarding.

### 2. External Dependencies
For each new package/API/service in the manifest changes, ask: does it require a new API key or
account? Is there a manual registration/setup step? Is that setup documented?

### 3. Downstream / Template Impact
Identify repos that inherit from or depend on this repo (e.g. template/booster repos; check crew
config for repos under the same team). For each: do they inherit deps/config from this PR? Is the
change breaking (requires update) or opt-in? When must downstream repos pull it?
Opt-in changes (env-var gated) are fine to merge. Changes requiring downstream code updates are
"hold" until a migration plan exists.

### 4. Correctness & Security
Read the whole diff for correctness regressions and security concerns: injected/leaked secrets,
auth/permission changes, input handling, unsafe shell/SQL, supply-chain risk from new deps.

### 5. Process Verification
- **Was related code searched?** (the #1585 class of bug — reimplementing what already exists).
  Check PR description/commits for evidence of pattern search.
- **Were docs updated alongside code?** New CLI flags → argument-hint updated? New config →
  `.env.example`/setup docs? Changed behavior → CLAUDE.md/runbooks?
- **Release train or direct merge?** PRs touching shared infra/templates → prefer release train;
  self-contained fixes → direct merge is fine.
- **Are FlowChad flows affected?** If any `.flowchad/`/`flows/` files changed or the PR changes how
  flows run → note that `/flowchad-runner` should run post-merge.
- **Production impact?** For PRs touching executor, dispatcher, or event routing: will it affect
  running jobs? Break webhook processing? Is there a safe rollback path?

### 6. Merge Strategy & Verdict
Decide the verdict using this table:

| Decision | When | Resulting action (stage 03) |
|----------|------|------------------------------|
| LGTM | All checks pass, no blocking issues | `approved` label; merge (or label per merge_strategy) |
| REWORK | Code needs specific changes | `needs-work` label; post required fixes |
| BLOCKED | External dependency or missing info | `needs-work` label; post what is needed, do NOT dispatch |
| NEW_ISSUE | Review reveals separate work needed | Approve PR on its own merits; flag a separate issue |

**Never recommend merge if CI is red** (`ci_status: failing`) — force the verdict to BLOCKED/hold and
note the CI failure, regardless of how clean the diff is.

## Action items
List numbered, specific, actionable must-do items. "Update docs" is not actionable;
"`docs/vercel-setup.md` — add `NEW_ENV_VAR` to the env var table (scope: production, required: yes)"
is. Each item: `**path/to/file**` then dash + exact change.

## Output: handoff.md

Path: `.procedure-output/cto-review/02-review/handoff.md`

```markdown
# Stage 02: CTO Review

## Verdict
- verdict: {LGTM | REWORK | BLOCKED | NEW_ISSUE}
- emoji: {✅ | 🔄 | ⏸️ | 📋}
- verdict_text: {one-line summary}
- merge_decision: {merge | hold | sendback}
- post_merge_note: {true if merge_state was merged, else false}

## Spec
- spec_ref: {copied from setup handoff — #NNN | org/repo#NNN | none}
- spec_source: {copied from setup handoff — issue | none}

{If spec_source is none: "No spec available — skipping conformance check"}

| Requirement | Status | Notes |
|-------------|--------|-------|
| {req summary} | {✅ satisfied / ⚠️ partial / ❌ missing} | {detail} |

Scope creep: {none | list of unrequested additions found in diff}
Wrong-but-plausible: {none | list of findings}

## Documentation
| Check | Status |
|-------|--------|
| {check} | {✅ description / ❌ what's missing} |

## External Dependencies
- {finding, or "_None_"}

## Downstream Impact
- {repo(s)} — {impact}; changes are {opt-in | breaking} — {details}

## Merge Strategy
- {Merge immediately | Hold — pending N items | Send back — reason}

## Process Verification
| Check | Status |
|-------|--------|
| Related code searched | {✅ evidence / ❌ no evidence / N/A} |
| Docs updated | {✅ / ❌ what is missing} |
| Merge strategy | {Direct merge / Release train — reason} |
| FlowChad flows affected | {✅ none / ⚠️ re-run flowchad-runner post-merge / N/A} |
| Production impact assessed | {✅ low risk / ⚠️ requires careful deploy / N/A} |

## Correctness & Security
- {findings, or "none — no correctness/security concerns"}

## Action Items
1. **`path/to/file`** — specific change needed
{... or "_None — ready to merge_"}
```

## Success criteria
- A single verdict reached across ALL dimensions from the one full diff.
- Checklist tables and action items populated with no unresolved TBD/TODO.
- CI-red forces a non-merge verdict.

## Failure
- Setup handoff missing or unreadable → write handoff with `verdict: BLOCKED` and reason "setup
  handoff unavailable".

<!-- Spec dimension and "skip tooling-enforced findings" guidance adapted from mattpocock/skills:review -->
