---
name: create-compelling-issues
description: Use when filing a GitHub issue — search for duplicates first, resolve filing policy from the repo playbook, and ground every claim in evidence.
user-invocable: true
trigger-hint: "When filing a new issue — bug report, feature request, or epic"
allowed-tools: Read, Write, Bash, Glob, Grep
---

# create-compelling-issues

An issue is a claim that work is needed. A weak one costs more than it saves — it lands in triage limbo, duplicates something closed last week, or points an agent at a bug that three commits already fixed. **The tracker always lags the codebase.** Prove the gap still exists before you file.

## 1. Search Before Filing

Search **open and closed issues AND merged PRs**. A recently fixed defect has a closed issue and a merged PR — and no open issue at all. Run at least two keyword sets: the symptom, and the file/function name.

```bash
R="$ORG/$REPO"
gh search issues --repo "$R" --limit 20 "<symptom keywords>"          # open + closed
gh search prs    --repo "$R" --merged --limit 20 "<symptom keywords>" # already shipped?
gh search issues --repo "$R" --match title --limit 20 "<file or function>"
```

| Finding | Action |
| --- | --- |
| Open issue covers it | Comment there with your new evidence. Do not file. |
| Closed issue, still reproduces | Comment with the fresh repro and ask for reopen. No twin issue. |
| Merged PR already fixes it | Nothing to file — report the PR to the requester. |
| Nothing found | File, and **cite the searches you ran** in the body. |

## 2. Consult the Repo Playbook — Before Applying Any Label

Label semantics are per-company POLICY; this skill does not know them. Read the repo playbook (`GET /admin/playbooks/<org>/<repo>`, falling back to `CONTRIBUTING.md` and `.github/ISSUE_TEMPLATE/`) and resolve:

| Question | Why it matters |
| --- | --- |
| Which labels are owned by automations/triage? | Hand-applying one fires a pipeline at an unvetted issue |
| Which label opts an issue **out** of automation? | Epics and discussion issues need it or a bot rewrites the body |
| Epic conventions | Whether epics are dispatchable, and how children are linked |

> **No filing section in the playbook?** Apply **no** workflow labels, file anyway, and say so in the issue: *"No filing policy found in the repo playbook — no workflow labels applied; triage owner should label."* Never invent a label, and never hand-apply one the playbook marks automation-owned.

## 3. Body vs Comment — Durability

Issue **bodies are automation-writable** — refinement bots, PRD generators, and triage loops rewrite them. Anything that must survive verbatim goes in a **comment**: checklists a loop ticks, live values another agent will consume (IDs, slots, versions), machine-read markers. Body = the durable problem statement. Comment = anything with a machine consumer.

## 4. Evidence Bar

Ground every claim in code you read or a probe you ran, with receipts in the body — commit SHA or permalink for "this code does X", command + output for "this fails", log line / request ID / job ID for "it failed in production". "Probably", "seems to", and "should" are not evidence; **assumption-grade filings get closed.** If you could not verify something, file what you did verify and mark the rest an explicit open question.

## 5. Right-Size

- **One issue = one deliverable.** If done-ness needs a sentence with "and" in it, split it. State what's out of scope.
- **Epics get decomposed** into children that each stand alone. The epic tracks; it does not implement.
- **Cross-repo references are org-qualified** — `org/repo#N`, never bare `#N`. A PR closes across repos with `Closes org/repo#N`.

## Body Template

```markdown
## Problem
[One sentence: what is broken or missing, and where]

## Evidence
[SHA/permalink, command + output, log line — receipts, not narration]

## Searched
`gh search issues --repo O/R "<kw>"` → N hits, none matching; `gh search prs --merged ...` → none.

## Acceptance criteria
- [ ] [Binary, checkable statement]

## Out of scope
[What this issue does NOT cover]
```

## Self-Audit Checklist

- [ ] **Searched?** Open + closed issues *and* merged PRs — searches cited in the body.
- [ ] **Policy resolved?** Playbook consulted; labels are allowed, or the "no policy" note is in the body.
- [ ] **Receipted?** Every claim has a SHA, output, or log line — no "probably".
- [ ] **Right-sized?** One deliverable, binary acceptance criteria, cross-repo refs org-qualified.
- [ ] **Durable?** Anything a machine reads verbatim is in a comment, not the body.
