# Canonical Retirement Review Issue

Use this protocol only in scheduled mode after the target repository's instructions permit issue writes. It is the normative owner for issue identity, lifecycle, idempotency, and concurrency behavior.

## Identity

- Title: `Retirement review: OWNER/REPO`
- Stable body marker: `<!-- trash-truck:retirement-review:v1 repo=OWNER/REPO -->`
- Run comment marker: `<!-- trash-truck:investigation:v1 -->`

Normalize repository casing consistently. Search open issues, closed issues, and related pull requests for the stable marker and title before creating anything. If more than one exact-marker issue exists, identify the oldest as the intended canonical issue, stop all writes, and report every match for owner repair. Never close, overwrite, or append to duplicates automatically.

## Creation and No-Change Rules

- Create the issue only when at least one eligible candidate exists.
- A first run with no candidates creates nothing.
- Report `issue_persistence: not-needed` when no candidate or material evidence change requires a write.
- Never reopen or auto-close the canonical issue.
- When an issue exists, append a no-change run only if material evidence changed.
- Do not write labels unless repository policy defines and permits them.

The body stays a stable purpose statement plus marker. Put generated investigations in comments so owner-authored body text and discussion are never replaced.

## Candidate Lifecycle

- `proposed` — eligible and presented, but not selected.
- `selected` — the owner selected the fingerprint and manifest; execution is not necessarily complete.
- `retired` — the complete manifest is deployed or otherwise effective and verified with post-change evidence.
- `kept` — positive use, obligation, or owner decision defeats retirement.
- `insufficient` — evidence cannot support a safe decision.
- `superseded` — another surface, successor, or material evidence change replaced this candidate identity or proposal.

A rejected `kept` or `insufficient` candidate stays suppressed until material evidence changes. Do not pad a new ranking with archived candidates.

## Run Comment

Append one comment only when the investigation materially changes. Include:

- run timestamp, mode, repository HEAD, deployed revision, and evidence cutoff;
- source coverage and failed/unavailable sources;
- zero to three ranked candidate packets or a material no-change result;
- conceptual fingerprints and lifecycle states;
- persistence/readback result;
- unresolved policy, access, owner, or evidence blockers.

Do not include credentials, raw sensitive events, customer data, or unrestricted logs. Link to access-controlled source receipts when appropriate.

## Idempotent Write

1. Acquire a repository-scoped schedule lock when the host supports it.
2. Search open and closed issues plus related PRs.
3. Compare the new normalized run packet to the latest marked comment.
4. If unchanged, do not write.
5. If no canonical issue exists and candidates exist, create the stable body.
6. Append one marked run comment.
7. Read back the issue and comment; verify repository, marker, fingerprint set, and content digest.
8. Release the lock.

If two runs race, repeat search and readback. If duplicates exist, identify the oldest intended canonical issue, stop all writes, report every URL, and request owner repair; do not silently create more churn or destructively reconcile them.

## Authority Failure

Determine whether the current result requires a write before testing write capability. If no candidate or material evidence change requires one, report `not-needed` regardless of GitHub availability or authority.

If a write is required and GitHub is unavailable, authentication fails, repository policy is silent, or issue writes are not authorized:

1. Return the complete investigation in the run result.
2. Mark `issue_persistence` as `blocked` or `failed` with the observed reason.
3. Do not claim the work is durable.
4. STOP without falling through to execution.
