# Test Verification

After implementation, independently verify the code works.

## Discovering Tests

Check the project for its test framework:
- `package.json` scripts: `npm test`, `yarn test`
- `Gemfile`: `bundle exec rspec`, `bin/rails test`
- `pytest.ini` / `pyproject.toml`: `pytest`
- `go.mod`: `go test ./...`
- `Makefile`: look for `test` target

## Dev Server Verification

If a dev server is running:
- Strapi: `curl -sf localhost:1337/_health`
- Next.js: `curl -sf localhost:3000`

Verify affected pages/APIs return expected responses after your changes.

## Rules

- Run tests yourself -- never trust documented results from earlier phases
- Fix failures before proceeding -- do not deliver broken code
- If failing tests are genuinely unrelated to your changes, note them but proceed
