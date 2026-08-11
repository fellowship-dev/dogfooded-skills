# Identity resolution and the override file

How `scripts/dxm-identity.sh` decides whose commit is whose, and how a human
corrects it without touching code.

---

## 1. How identity is decided

Grouping key is the **GitHub login**, never the email address.

The resolution is done **server-side by GitHub**. For each distinct commit
author email the script takes one sample commit and asks:

```bash
gh api repos/{owner}/{repo}/commits/{sha} --jq '.author.login'
```

GitHub already knows which account owns which verified email, including
corporate addresses that never appear in a `@users.noreply.github.com` form.
That is one API call **per email**, not per commit — a 60-commit repo with six
distinct authors costs six calls.

**There is no regex email-mining path, and there will not be one.** No
splitting local parts, no fuzzy-matching display names, no assuming
`f.lastname@corp.com` and `flastname@corp.com` are the same human. An email
GitHub cannot resolve stays unresolved and **visible in the review queue**.
Its commits are still counted in totals and reported as `unattributed`, so the
reader sees the size of the gap instead of a confidently wrong attribution.

### What each resolution source means

| `identity_emails.resolution_source` | Meaning | Coverage method |
| --- | --- | --- |
| `github_api` | GitHub returned a login for this email | `script` |
| `manual` | An `email` or `alias` line in the override file | `script-with-fallback` |
| `mailmap` | Learned from a repo's own `.mailmap` (not implemented yet) | `script-with-fallback` |
| `unresolved` | Nobody could decide. This is the review queue. | `llm` |

`manual` counts as `script-with-fallback` rather than `script` on purpose: it
is covered, but only because a human pre-seeded the answer. Watching that
number grow is the signal that the automatic path is degrading.

---

## 2. Bot exclusion

Two independent signals, in priority order:

1. **`account_type = 'Bot'`** as reported by the GitHub API. Authoritative.
2. **The `bot_patterns` table** — POSIX EREs matched case-insensitively
   against the login. Seeded in `schema.sql` with `\[bot\]$`, `^dependabot`,
   `^renovate`, `^claude(-|$)`, `^github-actions`, `^web-flow$`, `^cursoragent$`
   and friends.

The matching happens in `grep -Ei`, not in SQL, because macOS's system
`sqlite3` ships **without a `REGEXP` function**. The *result* is written to
`identities.is_bot` so every downstream query joins one boolean column instead
of re-implementing the regex — which is how two dashboards start disagreeing
about how many engineers there are.

The rule that fired is stored in `identities.bot_reason`. When somebody asks
"why is this account excluded", the answer is evidence, not a shrug.

Adding a bot rule is an `INSERT`, not a code change:

```sql
INSERT OR IGNORE INTO bot_patterns(pattern, note)
VALUES ('^acme-deploy-', 'internal deploy service accounts');
```

Because the pattern list is deliberately aggressive, the override file has a
`human` directive that beats it — see below.

---

## 3. The override file

Default location: `$DXM_HOME/identity/identity-overrides.tsv`
(`~/.dx-metrics/identity/identity-overrides.tsv`). Created from a commented
template on first run. Override with `--overrides FILE`.

**Format:** tab-separated, four columns, `#` starts a comment.

```text
directive <TAB> key <TAB> value <TAB> note
```

Overrides are applied **last**, after the automatic rules, so a line here
always wins.

### Directives

| Directive | Key | Value | Effect |
| --- | --- | --- | --- |
| `email` | commit email **or glob** | GitHub login | Confirms a mapping GitHub could not make |
| `alias` | other login | canonical login | Two accounts, one human — merges them |
| `bot` | login | why | Force-classify as a bot |
| `human` | login | why | Force-classify as a human; beats the regex |
| `exclude` | login | why | A real account that is not a person |
| `name` | login | Display Name | Canonical name used in the `.mailmap` |

### Worked examples

```text
# GitHub has no account for this address; the team lead confirmed who it is.
email	contractor@agency.example	jdoe	confirmed by team lead 2026-08-10

# Same human, personal laptop and work laptop.
alias	jdoe-personal	jdoe	second account, same person

# A real engineer whose login trips the ^claude(-|$) bot pattern.
human	claudel	real person, not the Claude bot

# A shared release account. Not a bot, but not a person either — it would
# inflate the contributor count and understate per-person throughput.
exclude	acme-release	shared release account, not an individual

# Canonical spelling for the dashboard and the mailmap.
name	jdoe	Jane Doe
```

### Globs, and the two kinds of fix

The `email` key may contain `*` or `?`, in which case it is a **glob** matched
against the stored (lowercased) address:

```text
email	ubuntu@*.ec2.internal	dxm-machine-ec2-devbox	cloud devbox default user
email	*@ci-agent.local	dxm-machine-ci-agent	in-house agent devbox
```

Machine addresses come in families — a replaced devbox mints a new hostname —
so enumerating them by hand means the file is stale the next time infra
changes. A glob **never pre-seeds a row**: there is no single address to
insert, and inserting the pattern itself would put a fake address into
`identity_emails` and into the `.mailmap`. Later lines win, so put globs first
and exceptions after.

Under the attribution-pair model there are **two different fixes** here, and
confusing them is how a report goes wrong:

| The address is… | Map it to | Result |
| --- | --- | --- |
| a **human** committing from their own machine (`octocat@workstation.local`) | that human's login | steerer = that human, executor = whatever the trailer says. This is the normal pair. |
| a **machine** with no identifiable human behind it (`worker@ci-agent.local`) | a `dxm-machine-*` login | steerer = machine, so it is excluded from delivery metrics instead of inflating the human population |
| a human you **cannot evidence** | nothing — leave it | steerer = unknown, reported as its own population. A legitimate outcome. |

`^dxm-machine-` is a seeded `bot_patterns` rule, so any login with that prefix
is flagged automatically. The bot-pattern pass runs **again** after the override
file precisely because an `email` line can create an identity the first pass
never saw; without that second pass a freshly-mapped devbox login spends a whole
reporting cycle counted as a brand-new human contributor.

`references/identity-overrides.seed.tsv` ships a worked starting point — the
shapes that actually occur, with placeholder addresses you replace. It is
**copied** into `$DXM_HOME` on first run and never merged into a file that
already exists — silently appending to something a human edited is worse than
useless.

### Semantics worth knowing

* **`alias` does not delete anything.** `identities.login` is `UNIQUE` and is
  referenced by foreign keys from `commits` and `pull_requests`. The alias's
  emails are repointed at the canonical identity and the alias row is marked
  `is_excluded=1, exclude_reason='override: alias of <canonical>'`. Nothing is
  orphaned and the merge is reversible by deleting the line.
* **`email` works ahead of ingest.** You can pre-seed a mapping for an address
  whose commits have not been ingested yet; the row is created and picks up its
  commits on the next run.
* **Parsing is strict.** An unknown directive, a missing key, or a missing
  required value **fails the run with exit 4** and names the line number. A
  typo'd override that is silently ignored is how a mapping "you definitely
  fixed" quietly stops applying — and you find out three weeks later, in a
  number you already showed a client.
* **Re-running is idempotent.** The file is fully re-applied every run; it is
  the source of truth, not a one-shot migration.

---

## 4. The review queue

Written to `$DXM_HOME/identity/identity-review.tsv` on every run. Every line is
**already a valid override line** — fill in the login and append it to the
override file:

```text
# directive	key	value	note
email	someone@corp.example	<GITHUB_LOGIN>	42 commits, sample acme/api@a1b2c3d
```

Sorted by `commit_count` descending, so the largest attribution gap is first.
The header carries the totals, which is what actually matters: three
unresolved stragglers and 40% of the history unattributed look identical in a
list and completely different in a decision.

Leaving an entry unresolved is a legitimate outcome. Some commits genuinely
have no GitHub account behind them.

---

## 5. The generated `.mailmap`

Written to `$DXM_HOME/identity/mailmap`, in standard git format:

```text
Jane Doe <jane@corp.example> <jane@users.noreply.github.com>
Jane Doe <jane@corp.example>
```

The canonical address is the identity's **highest-volume** email, because that
is the one a reader recognises. Form 4 (`Name <canon> <other>`) folds a second
address onto the canonical one; form 2 (`Name <email>`) normalises just the
display name, for the case where one human commits as both `jdoe` and
`Jane Doe`.

Use it without installing it into any repo:

```bash
git -c mailmap.file="$HOME/.dx-metrics/identity/mailmap" shortlog -sn HEAD
```

Note the explicit `HEAD`: **`git shortlog` with no rev argument reads stdin**
in a non-tty context and silently returns nothing.

---

## 6. Privacy

Read `CONTRACT.md` §8 first. It is binding, and this module handles the most
personally-identifying data in the skill.

* **stdout never contains an email, a login or a name** — with or without
  `--include-individuals`. The envelope carries counts and file paths only.
  This is stricter than §8 requires, because the envelope is read by a model
  and forwarded into conversation.
* `--include-individuals` only lets the operator see the review table printed
  to **stderr**. It unlocks no new output surface.
* The `mailmap` and the review queue live under `$DXM_HOME`, never under
  `$DXM_OUT`. `$DXM_OUT` is the export surface — dashboards and reports people
  send to other people. These two files are operational state: one is an input
  to `git`, the other is a worklist for the operator. Both carry a
  "SENSITIVE — do not commit" header.
* **None of this may be used to measure individual performance or feed a
  performance evaluation.** Individual-level identity data exists here for
  exactly two legitimate purposes: **ownership / bus-factor risk**, and
  **AI-adoption timing**. There is no per-person throughput output, and no flag
  that produces one.

---

## 7. Operational notes

```bash
# First build, resolving against GitHub
scripts/dxm-identity.sh --resolve

# Weekly re-run: cheap, only unresolved emails cost an API call
scripts/dxm-identity.sh --resolve

# After editing bot_patterns or fixing a wrong flag
scripts/dxm-identity.sh --rebuild

# See what would change
scripts/dxm-identity.sh --dry-run
```

* `--rebuild` clears **derived** fields only (bot flags, exclusions) and
  re-applies the rules. It never drops a resolved `email → login` link: that
  came from GitHub and re-fetching it spends API budget to learn what is
  already known.
* A GitHub rate limit exits **3** with `"partial": true`. Everything written so
  far is valid and the next run continues where this one stopped.
* `--backfill-commits` sets `commits.author_identity_id`. It is **off by
  default** because `CONTRACT.md` §10 assigns that column to the GitHub ingest
  workstream. Turn it on only if that backfill is not running.
