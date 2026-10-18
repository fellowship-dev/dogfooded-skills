# Keywords stage

1. Require an explicitly growth-eligible site, approved audience/goal/language/geography and operation allowance. In maintenance return `not-in-scope` without discovery or provider calls. Read project context and its research log, retained raw purchases and first-party evidence before proposing new research.
2. Read existing saved keywords with `list_saved_keywords` and `{"projectId":"PROJECT_ID","limit":100}`. This cap is not proof of the full inventory. Use narrower `search` or `tags` when appropriate; record omitted rows/coverage.
3. If first-party collection is authorized and connected, use `get_search_console_performance` with the bound project, explicit `startDate`/`endDate`, `dimensions:["query","page"]`, and `dataState:"final"`. Dates use the provider's Pacific Time convention; retain that alongside the reporting timezone. Follow `hasMore` with `startRow` within the declared collection budget. Missing/expired connection means unavailable measurement, not zero demand; no paid substitute follows automatically.
4. Only when retained evidence is insufficient and the existing cumulative allowance authorizes the exact call, use `research_keywords` with:

   ```json
   {"projectId":"PROJECT_ID","seeds":[{"seed":"APPROVED_SEED","locationCode":2840,"languageCode":"en"}],"resultLimit":150,"includeClickstreamData":false,"groupKeywords":false}
   ```

   Replace the example country/language with validated project-market codes from the deployed schema; never silently default to this example market. The supported seed count is 1–5. Record the maximum authorized cost/reservation before calling; fallback lookup can add cost. If a safe bound cannot be established, do not call. A provider cache is not a durable archive: retain the raw response, source, scope, date and cumulative spend receipt in existing private storage. Preserve partial seed failures. Do not repeat a purchase merely to make a report.
5. Produce a small shortlist weighing relevance, observed demand, opportunity, confidence, effort and dependencies. Include existing-page improvements, overlap/cannibalization, missing user questions, comparisons, tools and original evidence as candidates. For each selected intervention state audience/query, exact URL or proposed route, proposed change, evidence, expected outcome and owner. Null metrics remain unavailable; unmeasured demand and inferred intent remain hypotheses. Do not sum shared close-variant volumes or promise ranking gains. Send selected items to briefs only when content delivery is authorized.
