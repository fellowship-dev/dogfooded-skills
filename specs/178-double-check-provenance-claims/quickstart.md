# Quickstart: Verify the Provenance-Claim Fix

Manual replay — no automated harness (issue scope forbids adding one).

1. **Positive replay.** Walk the amended step 2 over the recorded live-instance sentence: "both
   merges brought in only an unrelated file — no source delta since the code-fix commits."
   - Confirm it matches the new provenance/range category.
   - Confirm its evidence source is the range diff from the cited SHA to the setup head SHA.
   - Use the recorded measurement (do not re-measure): range `e7433cc5..982066e7` contains three
     base-branch merge commits and 10 changed files, including two source files.
   - Confirm the range contradicts the claim ⇒ `unbacked` ⇒ `claims_reconciled: fail`.

2. **Negative replay (no over-broadening).** Walk an ordinary claim (e.g. "adds `--org` to a CLI
   subcommand") through the amended step. Confirm it still resolves `backed` via the existing
   Changed Files manifest — the new category must not capture it.

3. **SHA-less replay.** Walk "no source delta since the last review" (cites no SHA). Confirm it
   lands on `unbacked`, not `unknown`.

4. **Diff review.** `git diff main -- skills/ops/double-check/stages/02-review/CONTEXT.md` shows
   exactly one file, additive hunks only; taxonomy definitions, non-waivable bullets, and the
   `unknown` paragraph are byte-identical to `main`.

5. **Doctrine check.** `grep -niE 'pylot|fellowship|[0-9]{4}' <changed hunks>` returns nothing.

6. **CI.** `.github/workflows/tests.yml` passes unchanged (no new test entry point added).
