# Quickstart: Verify the Driving-Issue Contract

1. Run the focused regression check:

   ```bash
   bash skills/ops/review-pr/tests/driving-issue-contract.test.sh
   ```

2. Search for prohibited guidance. Inspect every match and confirm none recommends `Refs` for a
   driving issue:

   ```bash
   rg -n 'Refs|driving issue|follow-up' skills/ops/review-pr skills/product/create-compelling-prs skills/shared
   ```

3. Run repository verification defined in `.github/workflows/tests.yml` and markdown lint via
   `.claude/check-md-lint.sh`.

4. Exercise the author path with one driving issue and one deliberate remainder. Confirm the PR
   retains `Closes #N`, links a follow-up, and the follow-up matches the shared template.

5. Exercise the reviewer path on a real PR with one named unmet criterion. Confirm a calibrated Bug
   names the criterion and requires finishing it or linking a conforming follow-up. Save its URL.

6. After merge/catalog synchronization, record the gateway catalog version in the closing PR.
