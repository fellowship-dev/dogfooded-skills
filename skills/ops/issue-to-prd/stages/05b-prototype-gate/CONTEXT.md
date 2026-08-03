# Stage 05b: Prototype Gate

## Inputs
- `stages/00-automation-guard/output/handoff.md` (label list)
- `stages/01-read-issue/output/handoff.md` (title, body, comments)
- `stages/03-assess-clarity/output/handoff.md` (the `Mockups/Examples` row)

## Reference
`references/gate-checklist.md` — the full checklist and worked classifications. **Read it only
after G0 and G1 both pass.** Most issues die at G1 in two string comparisons; do not spend context
on the reference for a backend bug.

## Why this stage exists

The factory shipped exactly one set of bootable prototype variants, ever:
[PR #2063](https://github.com/fellowship-dev/pylot/pull/2063) on
[issue #1985](https://github.com/fellowship-dev/pylot/issues/1985), 2026-07-06 — three toggleable
takes on an add-LLM flow, mock API, boot instructions, screenshots, owner picked variation B in a
comment. It was worth repeating and there was never any machinery to repeat it (archaeology:
`docs/visual-evidence.md` § *Prototype variants*, `fellowship-dev/pylot`).

The mechanism that produced it ran **through this skill**: `issue-to-prd` posted an open question
("throwaway prototype — build it or skip?"), the owner said build it, the prototype followed. This
stage encodes that hop. It does not invent a new trigger.

## The safety property

`issue-to-prd` fires on every new issue. So:

> **Auto-detection can only ever ASK. Only an explicit owner signal DISPATCHES.**

The heuristic's entire job is deciding whether one extra sentence rides along in a comment this
skill was already posting. It cannot spend a mission, cannot push a branch, and cannot post a
comment of its own. Zero prototype work happens on a backend, infra, or bug issue — and zero
happens on a UI issue either until a human asks for it.

## Task
Produce a verdict: `skip` | `ask` | `dispatch` | `picked` | `already-dispatched`.

## P — pick first (cheapest exit, and it closes the loop)

If the issue already carries the options comment, the only question is whether the owner has
chosen. Look for the marker, then for a pick in any **later** comment:

```bash
OPTS=$(gh api "repos/{repo}/issues/{number}/comments?per_page=100" --paginate \
  --jq '.[] | select(.body | test("<!-- pylot:prototype-options ")) | "\(.id)\t\(.created_at)"' | tail -1)
```

- **No marker** → fall through to G0.
- **Marker present**, and a comment created *after* it matches `^\s*variant:\s*([A-Ca-c])\b`
  (case-insensitive, from the issue author or an org member) → verdict `picked`, record the letter.
- **Marker present, no pick** → verdict `skip`. The variants are out for review; say nothing, do
  not re-dispatch, do not nag. A second options comment is the #2802 failure mode in a new costume.

Detection is deliberately a manual read of comment text. Do not build reaction-webhook machinery
for this.

## G0 — physical preconditions (never bypassable, not even by the opt-in label)

Both must hold or the verdict is `skip`. These are not judgement calls — a prototype that cannot
be booted or dispatched is not a prototype.

1. **The repo has a bootable UI surface.** Authoritative source is the playbook:
   `pylot teams playbook {repo}` — look for a UI directory and a dev-server command. Fall back to
   the tree (`gh api repos/{repo}/contents --jq '.[].name'` → `ui`/`web`/`frontend`/`app`) plus a
   `dev` script in that directory's `package.json`. No UI, no dev server → `skip`.
2. **Some operator on this repo's managing team carries the `prototype` skill.** Resolve from the
   **live catalog**, never by guessing a role name:

```bash
AGENT=$(pylot teams list | TEAM="$TEAM" python3 -c '
import sys, json, os
team = os.environ["TEAM"]
d = json.load(sys.stdin); teams = d.get("teams", d)
ops = next((t for t in teams if t.get("name") == team), {}).get("operators", {})
cand = [(r, s.get("skills", [])) for r, s in ops.items() if "prototype" in s.get("skills", [])]
cand.sort(key=lambda rs: "pylot-workers" not in rs[1])
print(f"{team}.{cand[0][0]}" if cand else "")')
```

`$TEAM` is the repo's managing team. Do **not** use `pylot context <org/repo>` for this — it
returns `team: null` and an empty `operator.skills` for repos whose team binding it cannot
resolve, which reads as "nobody has the skill".

- `$AGENT` empty → `skip`. **Never dispatch cross-team to borrow the skill**: team GH tokens are
  org/team-scoped (`pylot/<team>` in ASM), so a foreign operator cannot check out the repo, and
  the mission fails on boot. Record the exact fix in the handoff instead —
  `pylot teams skills-add <team> <role> prototype --repo mattpocock/skills` — and, **only if the
  opt-in label was explicitly applied**, add that one line to the PRD's `## Open Questions` so an
  explicit request does not vanish silently. Auto-detect never speaks here.

> As of 2026-08-03 `prototype` is installed on **`pylot.architect` only**, so this hop is live on
> the `pylot` team's repos and inert everywhere else. That is correct behaviour, not a bug —
> widening it is a deliberate `skills-add`, not a fallback.

## G1 — hard disqualifiers (any one → `skip`)

Cheap string tests. Run these before reading the reference file.

- Labels intersect: `bug` · `dependencies` · `automated` · `security` · `infra` · `chore` ·
  `cleanup` · `documentation` · `release-blocked` · `no-automation` · `epic`
- Title begins with `fix(` · `chore(` · `docs(` · `refactor(` · `test(` · `bug:` · `ops:` ·
  `security:` · `perf(`
- The issue's deliverable is a skill, a doc, a CLI, an API, a migration, a cron, a build image, or
  a gateway/automation config — anything with no screen at the end of it

## G2 — the explicit signal (this, and only this, produces `dispatch`)

Either:

- The label **`prototype-options`** is present. It is an owner-applied opt-in; treat it as
  authoritative and skip G3 entirely (G0 still applies).
- A prior pass asked the prototype question — its comment carries
  `<!-- pylot:proto-ask issue={number} -->` — and a later comment from the issue author or an org
  member answers affirmatively (`build the prototype`, `Qn → build`, `yes, variants`). This is the
  #1985 path, verbatim.

> `prototype-options` does not exist on `fellowship-dev/pylot` yet. Creating it is a one-time owner
> step (`gh label create prototype-options --repo <repo> --description "Build bootable UI variants
> before implementation" --color 0E8A16`) and is deliberately **not** done by this skill — labels
> are live state. Until it exists the label branch simply never matches, which is harmless.

## G3 — auto-detect (produces `ask`, never `dispatch`)

**All four** must hold. Any doubt on any one of them → `skip`. See
`references/gate-checklist.md` for the worked classifications behind each.

1. **New user-facing surface.** The deliverable is a screen, page, panel, or flow a person looks
   at, and it does not exist yet. Verify: search the repo for the named route/component
   (`git grep -l`, or `gh api .../contents`). Found → it is a change to an existing surface, not an
   exploration → `skip`.
2. **No design prescribed.** Stage 03's `Mockups/Examples` row reads `missing`, **and** the body
   and comments carry no wireframe, Figma link, screenshot, ASCII layout, or component spec,
   **and** the issue does not name an existing in-repo pattern to follow. *"Follow the #2049
   activation ladder component pattern — do not invent a new pattern"* is a prescription; there is
   nothing left to explore.
3. **At least two materially different shapes exist.** Write them down, one sentence each. #2063's
   were *single page* / *guided wizard* / *conversational* — genuinely different user experiences,
   not three arrangements of the same layout. If you cannot write two sentences that a person would
   answer differently, the answer is no.
4. **Big enough to be worth booting.** The surface has ≥2 states or ≥3 interactive elements. One
   button, one field, a copy change, an icon, or a colour is never worth three branches.

## Dispatch (verdict `dispatch` only)

**Idempotence first.** One prototype run per issue, ever:

```bash
JOB_ID="proto-{number}"
```

- The options-comment marker was already checked in P. If it is there, you are not here.
- `pylot dispatch` returning **409** is **not a failure** — a run is already in flight for this
  issue. Verdict `already-dispatched`, post nothing, continue.

The brief travels with the mission. The receiving operator carries `prototype` but **not**
`issue-to-prd`, and today's only holder (`pylot.architect`) carries neither `visual-evidence`,
`playwright`, nor `evidence-upload` — so the brief must be, and is, self-contained down to the raw
`curl` upload:

```bash
REPO={repo}; N={number}
BRIEF=$(sed -e "s|{org/repo}|$REPO|g" -e "s|{number}|$N|g" -e "s|{slug}|$SLUG|g" \
  ~/.claude/skills/issue-to-prd/shared/prototype-mission-brief.md)

pylot dispatch \
  --agent "$AGENT" \
  --repo "$REPO" \
  --job-id "$JOB_ID" \
  --context "$BRIEF" \
  "/prototype build 3 bootable UI variants for $REPO#$N and post them as options on the issue"
```

`$SLUG` is a kebab-case name for the surface (`providers`, `automation-gallery`). It names the
**route** (`/proto/$SLUG`) only; branches are always `proto/{number}-a|b|c`, keyed on the issue
number so they sort together and are trivially greppable.

The task text must **start** with `/prototype`: the devbox router extracts the first `/skill` token
deterministically and fails the mission loudly if there is none.

## Side effects

This stage posts **no** comment and applies **no** label. Its only side effect is `pylot dispatch`.
Everything the reader sees comes from either stage 06's existing comment or the prototype mission's
single options comment — **never both, and never a comment of this stage's own.**

## Output: handoff.md

```markdown
# Stage 05b: Prototype Gate

## Verdict
`skip` | `ask` | `dispatch` | `already-dispatched` | `picked`

## Gate trace
| Gate | Result | Evidence |
| --- | --- | --- |
| P  | no marker / pending / picked=B | comment id or `—` |
| G0 | pass/fail | UI surface: `ui/` + `npm run dev`; agent: `pylot.architect` |
| G1 | pass/fail | labels: … |
| G2 | pass/fail | `prototype-options` absent; no prior proto-ask |
| G3 | pass/fail | 1 ✅ 2 ✅ 3 ✅ (single-page / wizard / conversational) 4 ✅ |

## Surface
{one line — what would be prototyped}

## Two shapes (G3.3 evidence, required when G3 passes)
- **A —** …
- **B —** …

## Dispatched
job_id: `proto-{number}` · agent: `{team}.{role}`   (or `—`)

## Picked
variant: `B` · branch `proto/{number}-b` · losing branches `proto/{number}-a`, `proto/{number}-c`
```

## Success criteria
- A verdict, with every gate that ran recorded and its evidence named
- `dispatch` only ever from G2; `ask` only ever from G3
- No comment posted, no label applied, by this stage
- When `dispatch`: job id is exactly `proto-{number}`, and a 409 was treated as success
