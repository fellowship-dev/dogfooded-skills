# Links stage

1. Reuse the audit's retained pages and authored edges. For technical checks include authored internal destinations and owner-declared legacy redirects, not only URLs that happened to enter the crawl queue. Keep source URL, literal href, resolved destination, anchor/context and observation time. If the installed collector cannot supply an edge, inspect the exact source HTML/DOM and retain that evidence; do not infer the source from a failed destination or build another crawler.
2. Verify each selected destination and retain the full chain, status of every hop, final URL/status and errors. For one resolved URL:

   ```bash
   curl -sS -L --max-redirs 10 --max-time 15 -D "$EVIDENCE_DIR/link-headers.txt" \
     -o "$EVIDENCE_DIR/link-body.html" -w '%{url_effective} %{http_code}\n' "$LINK_URL"
   ```

   Use a new filename per edge. Include these requests within the visit's total five-minute collection budget; stop with unchecked edges unverified. A redirect's 200 final result does not erase a wrong target, loop or excessive chain. Retain authored query/fragment; HTTP cannot verify fragment existence, so inspect the destination DOM for that control. Verify foreign destinations only when the input scope allows them.
3. In authorized growth work, evaluate relevance semantically: does this reader need this target at this point? Repeated keyword strings alone are not a reason to link. Each recommendation must contain:

   | Required field | Content |
   |---|---|
   | Source | Exact page URL and quoted sentence/paragraph or DOM/code location |
   | Target | Exact canonical destination and verification receipt |
   | Anchor | Exact natural anchor text |
   | Edit | Before and complete after sentence/paragraph |
   | Benefit | What the reader can learn/do next and why it fits here |
   | Basis | Observed content/intent evidence, confidence and any hypothesis |

4. Select a small useful set. If a target or context cannot be verified, mark provisional and do not claim an implemented link. Follow the site-owned review and publication authority, then verify the authored link in live HTML/DOM and record its intervention ID. Maintenance ends with technical findings/authorized repairs; it does not generate a growth linking campaign.
