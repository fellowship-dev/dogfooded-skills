# Audit stage

1. Load the entrypoint inputs, visibility policy and prior findings. Prefer suitable retained evidence before collecting again. Use installed seo-ops as the primary account-independent maintenance collector; no OpenSEO login is required.
2. Run the following with the resolved environment variables. The five-minute deadline is total collection time; `--timeout 15` alone is only a per-request bound. Rendering and Lighthouse remain off. Use a smaller page budget if the visit requires it; never exceed 30 without explicit scope.

   ```bash
   python3 - <<'PY'
   import os, pathlib, subprocess
   out = pathlib.Path(os.environ["EVIDENCE_DIR"])
   out.mkdir(parents=True, exist_ok=True)
   command = ["python3", str(pathlib.Path(os.environ["SEO_OPS"]) / "scripts/audit.py"),
              os.environ["SITE_URL"], "--max-pages", "30", "--timeout", "15", "--format", "json"]
   with (out / "audit.json").open("xb") as stdout, (out / "audit.stderr").open("xb") as stderr:
       try:
           result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=300)
           print("collector_exit", result.returncode)
       except subprocess.TimeoutExpired:
           print("collector_deadline_exceeded: coverage partial/unverified; output may be incomplete")
   PY
   ```

   Do not overwrite an earlier run directory. Parse JSON only if complete. This collector may write its report only after collection finishes; a deadline can leave no usable page results. Report that limitation rather than invent partial counts. Record actual inspected URLs, exclusions, failed requests and static-only limits. Read seo-ops' checklist for manual controls; the collector's generic severities are observations to interpret against visibility intent.
3. For an explicitly requested OpenSEO audit, first verify binding and permission to start it. Call `run_site_audit` with `{"projectId":"PROJECT_ID","url":"SITE_URL","maxPages":30,"renderJavaScript":false,"runLighthouse":false}`. Capture the returned exact `auditId`. If absent, stop this path: no latest-audit polling, cleanup or deletion advice, including when the upstream refusal suggests it.
4. With an ID only, poll `get_audit_status` using `{"projectId":"PROJECT_ID","auditId":"AUDIT_ID"}` within the same five-minute budget. On terminal completed/failed status or deadline, stop polling; no restart queue. Read retained partial results with `get_audit_issues` and `get_audit_pages`, always supplying both IDs and `limit:1000`. Record totals versus returned rows; truncation is a coverage limit, not completeness. A previously retained explicit ID can be read without starting a new run.
5. Verify failures against response headers/HTML and, when required, rendered DOM. For never-index sites check effective robots meta or X-Robots-Tag on representative public routes and nested overrides. A robots.txt crawl block alone is not proof of noindex; an observed directive is not proof of removal from search. Retain observed indexing separately if an authorized source is available.
6. Compare findings with prior receipts using the evidence contract. Rank by effect on site purpose/policy, confidence, effort and dependencies; identify a small actionable batch, not a score. Include authored links and declared redirects via [links](links.md) within the same bounded visit. Emit the findings, coverage and evidence references to the existing maintenance report owner.
