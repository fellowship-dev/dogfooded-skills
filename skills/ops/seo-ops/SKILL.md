---
name: seo-ops
description: Use when auditing a website before launch or in production for canonical hosts, redirects, crawlability, indexability, multilingual hreflang, metadata, structured data, sitemaps, robots, internal links, and recurring SEO regressions.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# seo-ops

Run an evidence-first SEO audit, separate machine-observable defects from judgment calls, and turn verified incidents into reusable operational knowledge.

## When to Use

- Pre-launch audits and migration checks
- Production SEO health checks and recurring smoke tests
- Duplicate-host, canonical, redirect, sitemap, robots, or hreflang investigations
- Metadata, social preview, structured-data, and internal-link reviews
- Traffic/indexing incidents after a deploy or domain change

## When Not to Use

- Keyword-volume, backlink, or competitor-market research as the primary task
- Content writing without an existing audit finding
- Search Console actions when the property owner has not authorized account access
- Interactive or JavaScript-rendered certification without a real browser

## Prerequisites

Read the target repo's operational playbook first. Resolve these site-specific inputs there; never add them to this public skill:

| Input | Example shape |
|---|---|
| Canonical origin | `https://example.com` |
| Alternate hosts | `https://www.example.com` |
| Locales and `x-default` | `en`, `es`, root fallback |
| Sitemap and robots URLs | `/sitemap.xml`, `/robots.txt` |
| Search Console property | URL-prefix or Domain property |
| Last verified date | `YYYY-MM-DD` |

Verify the local runtime:

```bash
python3 --version
curl --version
```

## Audit Modes

| Mode | Scope | Gate |
|---|---|---|
| `prelaunch` | Canonical host, redirects, robots, sitemap, metadata, locale clusters, structured data, internal links | Block launch on Critical/High defects |
| `production` | Same checks against the deployed origin plus representative browser rendering | Open/dedupe actionable issues |
| `incident` | One failing signal and its adjacent boundaries | Do not broaden until the failure is reproduced |
| `recurring` | Stable critical subset with machine-readable output | Never certify interactive checks from static evidence |

## Workflow

1. **Establish the expected topology**

   Record the canonical origin, alternate hosts, locale routes, sitemap, and expected redirect policy from the repo playbook. If any are unknown, report them as missing operational decisions rather than guessing.

2. **Run the deterministic static audit**

   ```bash
   python3 skills/ops/seo-ops/scripts/audit.py \
     https://example.com \
     --compare-origin https://www.example.com \
     --max-pages 25 \
     --output /tmp/seo-audit.md
   ```

   Use JSON for automation:

   ```bash
   python3 skills/ops/seo-ops/scripts/audit.py \
     https://example.com \
     --compare-origin https://www.example.com \
     --format json > /tmp/seo-audit.json
   ```

   The script checks status/redirect chains, duplicate hosts, canonicals, robots, sitemap discovery, indexability, metadata, headings, hreflang, static JSON-LD, images, and sampled internal links. It does not pretend to measure rankings, field Core Web Vitals, or rendered JavaScript.

3. **Complete the manual control set**

   Read [references/checklist.md](references/checklist.md). Mark every control `pass`, `fail`, `blocked`, `not-applicable`, or `needs-judgment`. Attach a URL, header, DOM selector, API response, or screenshot to every failure.

4. **Add browser evidence where required**

   Use Playwright, Navvi, or another real browser to inspect the rendered DOM:

   ```javascript
   ({
     canonical: document.querySelector('link[rel="canonical"]')?.href,
     alternates: [...document.querySelectorAll('link[rel="alternate"][hreflang]')]
       .map((node) => ({ lang: node.hreflang, href: node.href })),
     jsonLd: [...document.querySelectorAll('script[type="application/ld+json"]')]
       .map((node) => node.textContent),
     lang: document.documentElement.lang,
     title: document.title,
     h1: [...document.querySelectorAll('h1')].map((node) => node.textContent?.trim()),
   })
   ```

   > **Warning:** Static HTML, `curl`, or a JavaScript bundle search may diagnose an interactive/rendered problem but cannot certify it as passed.

5. **Check canonical-signal agreement**

   Compare redirect destination, HTML canonical, HTTP `Link` alternates, HTML hreflang, sitemap URLs, structured-data URLs, Open Graph URL, and internal links.

   | Signals | Verdict | Action |
   |---|---|---|
   | All point to one HTTPS origin and equivalent locale paths | Pass | Record evidence |
   | Alternate host serves 200 while canonical host also serves 200 | Critical | Add one-hop permanent host redirect |
   | Canonical conflicts with hreflang or sitemap | High | Fix the generating source, then re-audit every locale |
   | Only cosmetic trailing-slash variation with one-hop redirect | Low | Standardize when convenient |
   | No explicit canonical but every other signal agrees | Medium | Add self-referencing canonical; do not claim duplicate content without evidence |

6. **Validate multilingual clusters**

   Require self-reference, reciprocity, valid language/region codes, canonical URLs, 200 responses, and representative visible translated copy. URL and `<html lang>` alone do not prove localization.

7. **Classify findings**

   | Severity | Meaning | Response |
   |---|---|---|
   | Critical | Search engines/users receive duplicate, blocked, wrong-host, or non-indexable primary content | Fix before launch or immediately in production |
   | High | Strong canonical, hreflang, sitemap, redirect, or rendering conflict | Fix this release/week |
   | Medium | Missing/weak metadata, incomplete structured data, or sampled broken links | Prioritize with content owners |
   | Low | Hygiene or optimization opportunity with no demonstrated indexing impact | Backlog |
   | Info | Observation requiring Search Console, analytics, or human judgment | Do not present as a defect |

8. **Write the report**

   Start with the outcome, not a score. Include:

   - expected topology and audit mode
   - Critical/High findings first
   - exact evidence and reproduction command
   - expected versus actual behavior
   - smallest safe fix and rollback
   - static/browser/Search Console evidence boundaries
   - passed controls worth preserving as regressions
   - blocked checks and what access would unblock them

9. **Feed verified learning back into the system**

   Read [references/casebook.md](references/casebook.md) before diagnosing a repeated pattern. After an investigation:

   | Knowledge | Destination |
   |---|---|
   | Reusable rule, false positive, command, or decision pattern | This skill's checklist/casebook via PR |
   | Client host, locale, property ID, account, or last verification | Target repo playbook |
   | Executable production invariant | Target repo's Flowchad/e2e flow |
   | Framework implementation default | Framework/template repo |

   Add only reproduced, source-backed lessons. Include the question/suggestion, evidence, conclusion, reusable rule, and regression check. Never treat an old conversation as evidence by itself.

## Decision Boundaries

Read [references/questions.md](references/questions.md) when an investigation starts from a question, suggestion, or disputed recommendation. Add a new answer only after verifying the rule and its exceptions.

| Question | Answer |
|---|---|
| Can `curl` prove canonical and HTTP redirects? | Yes, for returned headers/HTML |
| Can `curl` prove rendered JSON-LD or locale copy? | No; use a browser |
| Is `site:` search an index-coverage measurement? | No; use Search Console |
| Does a Lighthouse SEO score certify technical SEO? | No; it samples a small control subset |
| Should every audit recommend schema? | No; recommend only truthful types supported by page content |
| Should every locale canonicalize to the default language? | No; each genuine locale normally self-canonicalizes |
| Can a redirect rule work on a DNS-only Cloudflare hostname? | No; Cloudflare must receive proxied HTTP traffic |

## Error Handling

**Blocked or protected target** — report the status/protection mechanism. Do not interpret a challenge page as the audited page.

**JavaScript-only metadata** — capture raw and rendered DOM separately. Report disagreement as a rendering risk, not as two independent defects.

**No Search Console access** — complete observable checks and mark index coverage, selected canonical, and query performance as blocked.

**Rate limiting or unstable responses** — lower `--max-pages`, preserve partial evidence, and do not convert missing samples into failures.

**Conflicting tools** — prefer primary response/DOM evidence. Record tool versions and explain the conflict.

## Critical Rules

- Never mutate DNS, redirects, Search Console, or production code during an audit without explicit authorization.
- Never expose credentials, private Search Console data, or client identifiers in the public skill or reports.
- Never certify interactive/rendered behavior without browser evidence.
- Never turn rules of thumb such as title/description character counts into hard ranking claims.
- Never use an aggregate score to hide a Critical or High defect.
- Always distinguish observed facts, source-backed rules, and recommendations.
