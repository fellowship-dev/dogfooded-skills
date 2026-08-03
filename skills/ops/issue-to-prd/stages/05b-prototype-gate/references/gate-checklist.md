# Prototype gate — checklist and worked classifications

Read this only when G0 and G1 have both passed. It exists to calibrate G3, which is the only part
of the gate that is a judgement call.

## The bar, restated

A prototype is worth three branches when **the owner cannot tell you what it should look like,
because nobody knows yet**. It is not worth three branches when the shape is already decided and
only the code is missing. Everything below is a way of asking that one question.

## G3 in one table

| # | Passes when | Fails when |
| --- | --- | --- |
| 1 New surface | The screen/page/panel/flow does not exist in the repo today | It exists and is being changed, extended, fixed, or restyled |
| 2 No design prescribed | Stage 03 says `Mockups/Examples: missing`, and no wireframe / Figma / screenshot / ASCII layout / named in-repo pattern appears anywhere | The issue says "follow X's component", links a mock, or specifies the layout |
| 3 ≥2 material shapes | You can write two one-sentence descriptions a person would answer differently | The alternatives are rearrangements: two-column vs one-column, modal vs drawer, tabs vs accordion |
| 4 Worth booting | ≥2 states or ≥3 interactive elements | One button, one field, a copy change, an icon, a colour, a tooltip |

**Tie-break rule:** any hesitation on any row → `skip`. The cost of a missed prototype is one
label the owner can apply later. The cost of a false positive is a mission, three branches, and a
comment on an issue that did not want one.

## Positive controls

### `fellowship-dev/pylot#1985` — provider-management UI + first-run wizard

The historical case. This is what the gate must select.

| Gate | | Why |
| --- | --- | --- |
| G1 | pass | `enhancement`; no disqualifying label or title prefix |
| G3.1 | pass | `o/[org]/providers` explicitly "new route (sibling to `secrets`/`teams`)" |
| G3.2 | pass | No mock, no Figma, no named pattern to follow — the body describes *steps*, not *layout* |
| G3.3 | pass | Shipped shapes were **A** single page · **B** guided wizard · **C** conversational. Three different products, not three layouts |
| G3.4 | pass | Add-credential → test → enable-repo → smoke-test: four states, many controls |

Outcome in reality: `issue-to-prd` asked "throwaway prototype — build it or skip?", the owner said
build it, three variants shipped as PR #2063, the owner replied *"Owner decision: variation B"*,
and B became the design basis for PR #2072. That is `ask` → owner answers → `dispatch` → `picked`,
which is exactly the state machine in `CONTEXT.md`.

### `fellowship-dev/pylot#2617` — pre-built automation gallery

| Gate | | Why |
| --- | --- | --- |
| G1 | pass | `enhancement` |
| G3.1 | pass | A gallery in the org dashboard; no such surface exists |
| G3.2 | pass | The body prescribes *content* (three risk tiers, four packs) and no layout at all |
| G3.3 | pass | Flat grid of cards · progressive tier ladder that unlocks as you earn it · a "recommended next automation" single-suggestion feed. Materially different products |
| G3.4 | pass | Per-pack description, cost estimate, live on/off toggle, last-run time; plus the progression-gating states |

Verdict `ask`. Note this issue is `dispatched`/`in-progress` today — classification here is a
read-only exercise; the gate is never re-run against work already in flight.

## Negative controls

### `fellowship-dev/pylot#2831` — distill-analyze recalibration

`bug`, `P1`. Dies at **G1** on the label. Had it survived: the deliverable is a confidence
function, an attribution parse, and a dedupe fallback. There is no screen. G3.1 fails.

### `fellowship-dev/pylot#2838` — no ingest path into the skills catalog

`bug`, `no-automation`. Dies at **stage 00** before this stage runs at all.

### `fellowship-dev/pylot#2815` — team setup completeness checklist

The most instructive negative, because it is genuinely a UI issue and the gate still says no.

| Gate | | Why |
| --- | --- | --- |
| G1 | pass | `enhancement`, `chat-ux`, `dx` — nothing disqualifying |
| G3.1 | **fail** | "Do NOT create a new route or page — checklist lives in the existing team settings page component" |
| G3.2 | **fail** | "Follow the #2049 org activation ladder component pattern… do not invent a new pattern", plus an eight-row item table with prescribed icon states and CTA copy |
| G3.3 | **fail** | The remaining freedom is where the progress bar sits. That is a layout choice, not a thesis |
| G3.4 | pass | Three deliverables, several states |

Two of four fail, so `skip`. **A UI label is not a UI exploration.** This issue knows exactly what
it wants and needs an implementer, not three opinions.

### `fellowship-dev/pylot#2813` — proactively offer GitHub linking in chat

`enhancement`, `chat`, `chat-ux`. Fails **G3.4** and arguably **G3.3**: the deliverable is one
proactive message carrying one link. Inline card vs ephemeral prompt vs banner is a real choice,
but it is one element and one state — below the booting bar. `skip`.

## Sweep — `fellowship-dev/pylot`, last 20 issues (2026-08-02)

Run read-only as calibration. **19 of 20 `skip`, 0 `dispatch`.**

| Issue | Verdict | First gate that fired |
| --- | --- | --- |
| #2838 | skip | stage 00 — `no-automation` |
| #2837 | skip | G1 — `bug` |
| #2834 | skip | stage 00 — `no-automation` + `epic` |
| #2833 | skip | G1 — deliverable is a CLI/skill/image |
| #2832 | skip | G1 — `bug` |
| #2831 | skip | G1 — `bug` |
| #2829 | skip | G1 — `bug` |
| #2827 | skip | stage 00 — `no-automation` |
| #2824 | skip | G1 — `bug` |
| #2821 | skip | G1 — `documentation` |
| #2815 | skip | G3.1 + G3.2 — design prescribed (see above) |
| #2814 | skip | stage 00 — `epic` |
| #2813 | skip | G3.4 — one element, one state |
| #2812 | skip | stage 00 — `no-automation` |
| #2810 | skip | G1 — backend ops, no screen |
| #2809 | skip | G1 — `bug`, `security` |
| #2808 | skip | G1 — skill content |
| #2805 | skip | stage 00 — `no-automation` |
| #2803 | skip | stage 00 — `no-automation` |
| #2800 | skip | G1 — `bug`, CI |

Nothing in a normal 20-issue window is prototype-shaped. That is the expected shape of the result:
across the whole `fellowship-dev` org there has been **one** prototype-shaped issue in the
project's history. A gate that selects more than a couple per quarter is miscalibrated.
