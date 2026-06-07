# Per-project test commands

Look up the test command from the repo CLAUDE.md. These are the known defaults:

| Project | Test Command |
|---------|-------------|
| Lexgo (Rails) | `RAILS_ENV=test bundle exec rspec --format progress` |
| Booster Pack / Farmesa / Inbox Angel (Strapi+Next) | `cd backend && npm run build && cd ../frontend && npm run build` |
| MTG LOTR (Next.js) | `npm run build` |

Run via remote exec:

```bash
$REMOTE_EXEC "cd $REPO_DIR && <TEST_COMMAND>"
```

If the repo CLAUDE.md specifies a different command, prefer that. Never assume — read the repo
CLAUDE.md first.

## Default branch reminder

Lexgo uses `master`, most others use `main`. Never assume:

```bash
DEFAULT_BRANCH=$(gh repo view $REPO --json defaultBranchRef -q .defaultBranchRef.name)
```
