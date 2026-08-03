# Stage 00: Automation Guard

## Inputs
- Issue number + repo (from invocation)

## Why this stage exists

`issue-to-prd` fires on **every new issue** (`challenge-new-issue`, 318 fires as of 2026-08-02)
and again on every answered question (`rechallenge-after-answers`, 477 fires). Stage 07 **rewrites
the issue body**. Neither the automation's `labels_exclude`
(`dependencies`, `automated`, `prd-ready`, `bug`) nor any stage checked for `no-automation` or
`epic` — so on 2026-08-02 this skill restructured
[fellowship-dev/pylot#2834](https://github.com/fellowship-dev/pylot/issues/2834), an owner-authored
epic labelled **both** `no-automation` **and** `epic`, and deleted the 8-child checklist an hourly
loop was executing against. It also stripped #2649's `<!-- distill-key: … -->` dedupe marker.
Filed as [fellowship-dev/pylot#2837](https://github.com/fellowship-dev/pylot/issues/2837).

The `fellowship-dev/pylot` playbook (§ Issue-filing conventions, owner 2026-08-02) states the rule
this stage now enforces:

> **`no-automation` at creation** keeps issue-to-prd/auto-pylot machinery off an issue — use for
> epics, owner-driven checklists, and discussion issues.
> **`epic` label:** epics are never leaf-dispatched; only decomposed children dispatch. *Until
> issue-to-prd enforces this*, pair `epic` with `no-automation` so the body isn't restructured.

This stage is that enforcement. Run it **first**, before stage 01.

## Task
Refuse to touch an issue this skill is not allowed to touch.

## Steps

```bash
GUARD=$(gh issue view {number} --repo {repo} --json state,labels \
  -q '"\(.state) \([.labels[].name]|sort|join(","))"')
STATE=${GUARD%% *}; LABELS=",${GUARD#* },"
```

Abort — do not run stages 01-07, do not read the body, do not write anything — when **any** holds:

| Condition | Check | Reason |
| --- | --- | --- |
| `no-automation` label | `[[ "$LABELS" == *",no-automation,"* ]]` | Owner opted the issue out of all machinery |
| `epic` label | `[[ "$LABELS" == *",epic,"* ]]` | Epic bodies carry live checklists loops execute against; epics are decomposed, never leaf-structured |
| Issue not open | `[[ "$STATE" != "OPEN" ]]` | A closed issue's body is a record, not a work item |

The `epic` guard stands **on its own** — an epic without `no-automation` is still an epic. That is
the exact gap that ate #2834's checklist, since the label pairing the playbook prescribes is a
convention nobody enforces.

## On abort

Emit **success**, not failure. The automation row carries `max_failures: 3` and auto-disables on
three consecutive failures — a correctly-skipped epic must never count toward disabling
`challenge-new-issue` for the whole org:

```text
[pylot] outcome="skipped: <label|state> — issue-to-prd does not structure this issue" status=success
```

Post **no** comment and apply **no** label. Silence is the whole point of the guard.

## Output: handoff.md

```markdown
# Stage 00: Automation Guard

## Verdict
`proceed` | `abort`

## Labels
{comma-separated}

## Reason (if abort)
{which condition fired}
```

## Success criteria
- Verdict is `proceed` or `abort`
- On `abort`: no GH writes of any kind, `status=success` emitted, stages 01-07 skipped
- On `proceed`: handoff records the label list so downstream stages (05b) do not re-fetch it

## Known gap — the automation layer still fires

This guard stops the skill, not the dispatch. `challenge-new-issue` and `rechallenge-after-answers`
still spend a mission on a guarded issue before this stage refuses it. The complementary fix is a
one-line config change on both automation rows:

```text
labels_exclude: ["dependencies", "automated", "prd-ready", "bug", "no-automation", "epic"]
```

That is a **live prod config mutation** and belongs in a supervised daytime window (see the
`#2794`/`#2736` seeding footguns), not in a skill PR. Until it lands, this stage is the only
enforcement.
