---
name: setup-playbooks
description: Capture durable repository knowledge or initialize a repository playbook through the single safe mutation workflow.
user-invocable: false
modes: [interactive, mission]
allowed-tools: Bash, Read
---

# Setup Playbooks

Own every operator-facing playbook mutation. Other skills may read a playbook or compose this skill; they must not write one independently.

## Dispatch

Require exactly one entry point:

- `capture repo=<org/repo> fact=<one bounded knowledge unit>` in interactive mode.
- `init repo=<org/repo> discovery=<structured discovery data>` in mission mode.

Reject bare repo names, malformed Markdown, invalid frontmatter, empty facts, oversized proposed content, unsupported modes, or inputs containing credential values. Never print or persist session, admin, dispatch, installation, or provider credentials.

## Capture — interactive

Use only the conversation session credential already injected as `$PYLOT_API_TOKEN`. Never use `$PYLOT_DISPATCH_TOKEN`, an admin token, an installation token, or `/admin/playbooks`.

1. Require `$PYLOT_GATEWAY_URL`, `$CONVERSATION_ID`, and a canonical same-org repo.
2. POST to `$PYLOT_GATEWAY_URL/conversations/$CONVERSATION_ID/admin-action` with `Authorization: Bearer $PYLOT_API_TOKEN` and JSON `{"op":"playbook-read","args":{"repo":"<org/repo>"}}`.
3. Require a complete body plus positive integer `version` and 64-character lowercase `digest`. A 404 means initialization is required; do not invent a partial playbook.
4. Classify the fact into the narrowest meaningful existing section. Prefer Tech Stack, Deployment, Key Directories, Operational Runbook, Testing, Architecture, Security, or Known Quirks. If none fits, insert a specifically named section before appendices/reference material. Never dump an unclassified fact at EOF.
5. Edit only the selected section. Preserve every byte outside it, including whitespace and final newline. An empty, duplicate, or unchanged fact is `already_current` and performs no write.
6. Validate frontmatter and heading structure. Compute a bounded unified diff: include the changed hunk with at most three context lines; summarize omitted unchanged sections. Display this preview before staging any mutation.
7. After the user authorizes that exact preview, POST `playbook-replace` to the same admin-action endpoint with `repo`, complete replacement `content`, `base_version`, and `base_digest`. Tell the user the returned confirmation summary/code; do not claim persistence yet.
8. On deterministic `confirm <code>`, require the confirmed result's complete content, incremented version, and digest. Compare its digest to the proposed content. Report `persisted` only on an exact match.

If confirmation is rejected or expires, report unchanged. On `playbook_conflict`, read again and regenerate the diff; never replay a stale replacement. If the submission response is lost, read back first: matching proposed digest means success, differing digest means regenerate, and only a still-matching base may be retried.

Capture output: `status`, `repo`, `content`, `version`, `digest`, `section`, and the bounded `diff` (or `status: already_current`).

## Init — mission

Mission mode uses the privileged operator's normal gateway credential and the direct admin surface. It is create-only.

1. Require canonical `repo` and structured discovery containing tech stack, deployment, key directories, and operational commands/constraints.
2. GET `/admin/playbooks/<org>/<repo>` first. Any 200 refuses initialization with `playbook_exists`. Only 404 permits creation.
3. Render this minimum complete document, filling it solely from discovery:

   ```markdown
   ---
   name: <repo-name>-playbook
   description: Operational knowledge for <org/repo>.
   user-invocable: false
   ---

   # <org/repo>

   ## Tech Stack

   ## Deployment

   ## Key Directories

   ## Operational Runbook
   ```

4. PUT the complete body to `/admin/playbooks/<org>/<repo>` with `Content-Type: text/plain`, `If-None-Match: *`, and the operator's existing authorization. A 409 is `playbook_exists`; never fall back to an unconditional PUT.
5. Require returned `content`, version `1`, and digest. GET once and compare the complete bytes, version, and digest. A mismatch is a failed init, never success.

Init output: `status: persisted`, `repo`, complete `content`, `version`, and `digest`.

## Safety invariants

- The gateway is the only persistence surface; never edit a repo file, seed, or documentation as a substitute.
- Always complete-read before capture, create-only for init, and compare-and-swap for replacement.
- Never silently truncate canonical content.
- Diffs and confirmation summaries are bounded; audit records contain repo, versions, byte count, and digests—not content.
