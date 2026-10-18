---
name: seo-workflows
description: Use when coordinating a bounded SEO audit, contextual links, keyword selection, complete content improvements, or weekly/monthly evidence reports across site-owned workflows.
---

# seo-workflows

Run five evidence-backed SEO stages using the existing seo-ops collector and project-scoped OpenSEO tools, with site context supplied by the owning project.

## When to Use

- A maintenance visit needs bounded public-page checks and prioritized findings.
- An authorized growth cycle needs a small selected batch, complete copy or implementation, and follow-up evidence.
- A weekly delivery or monthly outcome report must reuse retained intervention receipts.

Do not use this bundle to create a crawler, grant account access, start a ranking campaign, or infer publication authority. This is a development bundle until its real-workload acceptance is recorded; installation does not establish consumer acceptance.

## Prerequisites

1. Read the site's operational instructions and resolve the inputs below. For a URL-only request, default to maintenance, read-only public collection, no OpenSEO binding, unknown indexing intent, and no growth or paid operations. Missing business context does not block technical observations.

   | Input | Required value |
   |---|---|
   | Site | Canonical origin, allowed origins, retained-evidence directory owned by this site |
   | Stage | `audit`, `links`, `keywords`, `briefs`, or `reports` |
   | Mode | `maintenance` or explicitly authorized `growth` |
   | Visibility | `indexable`, `never-index`, or `unknown`; owner evidence for the policy |
   | Lifecycle | Active or pending disposition; pending retirement grants no cancellation/migration authority |
   | Context | Audience, outcome, language/geography, priorities and approval owner; required before growth selection |
   | Binding | Verified OpenSEO project ID and website, or `none`; report owner/renderer and receipt location |
   | Operations | Public reads, retained-data reads, drafts, implementation, publication, report saves, provider calls: each allowed or withheld |
   | Allowance | Provider authorization, cumulative ceiling, spent/reserved amount and receipt; absent means zero new spend |

2. Locate installed `seo-ops` at the same source revision recorded by the consumer. Set `SEO_OPS` to its absolute skill directory, `SITE_URL` to the approved origin and `EVIDENCE_DIR` to a new site-owned run directory. Verify:

   ```bash
   python3 --version
   curl --version
   python3 "$SEO_OPS/scripts/audit.py" --help
   ```

3. For an OpenSEO stage, inspect the connected server's tools/list schemas. Resolve `list_projects` with `{}` and verify the selected project's website against this site's binding; then call `get_project_context` with `{"projectId":"PROJECT_ID"}`. These JSON examples are MCP arguments, not shell commands. Replace uppercase placeholders with resolved values before invoking. Never select a project by name alone or create one automatically. Keep context/research archives in the site's own storage.

## Workflow

1. Record the inputs, source revision, selected installed skill path and allowed operations in the existing run receipt. Read [the evidence contract](references/evidence.md).
2. Choose the stage by this table and read its full reference. Use this explicit bundle name and path when another package exposes `seo-audit`; do not let a colliding skill name choose the workflow.

   | Stage | Execute | Result |
   |---|---|---|
   | `audit` | [audit.md](references/audit.md) | Bounded observations, coverage, policy-aware findings |
   | `links` | [links.md](references/links.md) | Authored-edge verification and contextual editorial changes |
   | `keywords` | [keywords.md](references/keywords.md) | Evidence-ranked shortlist or provisional hypotheses |
   | `briefs` | [briefs.md](references/briefs.md) | Complete reviewable page/copy deliverable with evidence |
   | `reports` | [reports.md](references/reports.md) | Owner outcome view plus technical appendix from existing receipts |

3. Finish the selected stage's deliverable. Only continue into another stage when the request and mode authorize it. Maintenance may assess technical links, but cannot initiate keyword discovery, new growth content, ranking tracking or paid calls. Site-specific eligibility and narrower owner policy always govern growth.
4. Retain raw evidence and baseline; use the site's existing implementation/review/release process for authorized changes. Verify live results after publication and retain actual publication time. Draft/merged/deployed/accepted are distinct states.
5. Hand the receipt to the existing report owner. Report generation never starts collection or publication.

## Decision Boundaries

| Condition | Action |
|---|---|
| Missing/expired analytics connection | Continue free technical work; search impact is unavailable, never zero |
| Unknown visibility | Observe directives; ask the owner to resolve policy before changing them |
| Never-index | Verify exclusion across representative public route classes; no recommendation to make indexable |
| Existing research fits source, age, market and scope | Reuse retained response; record age and limits |
| Provider allowance absent or exhausted | Stop paid operations; retain useful hypotheses without invented metrics |
| Reproduced generic product gap | Check supported interfaces, then propose an upstream contribution; no permanent fork by default |

## Error Handling

**Collector timeout or blocked page** — retain available output and stderr, mark missing coverage partial/unverified, and stop at the collection deadline. No new retry queue.

**OpenSEO audit refusal without an audit ID** — no run exists for this request. Preserve the refusal; never poll the latest audit or recommend deleting retained audits to make room.

**Tool schema differs from this reference** — inspect the deployed schema and record the difference before using supported arguments. Do not guess missing tools or parameters.

## Critical Rules

- Keep client facts, account identifiers, credentials and raw private evidence outside this public bundle.
- No paid call, account/scope change, report replacement, deletion or publication follows merely from invoking a stage.
- Static directives do not prove search-engine removal, and movement after publication does not prove causation.
- Validate this bundle through [real workload evaluations](evals/README.md), not tests that search its prose.
