# Data Model: Driving Issue Decomposition Contract

## Driving Issue

| Field | Rules |
|---|---|
| number | Exactly one per PR |
| relationship | `Closes` / `Fixes` / `Resolves`; never `Refs` |
| acceptance criteria | Compare named criteria with the diff; ignore checkbox state |
| remainder | Empty, completed in the PR, or represented by linked Follow-up Issues |

## Follow-up Issue

| Field | Rules |
|---|---|
| title | Begins with `Follow-up of #N` |
| body opening | Begins with `Follow-up of #N` |
| Origin | Links origin issue N and the decomposing PR |
| Remaining acceptance criteria | Copies every deferred named criterion verbatim |
| Out of scope | States the bounded remainder |
| labels | `ready-to-work` plus issue N's priority label |
| linkage | Linked from the PR that closes issue N |

## Review Finding

| Field | Rules |
|---|---|
| severity | Bug |
| confidence | Calibrated 80–100; included only at or above 80 |
| trigger | Driving issue uses `Refs`, or named criteria are unmet without valid follow-ups |
| remedy | Add one closing reference; finish each criterion or file/link a conforming follow-up |

## State Transitions

`Driving issue open` → `PR closes driving issue` → `origin closed on merge`.

For partial delivery: `unmet criterion` → `completed in current PR` OR `copied verbatim into linked
follow-up` → `follow-up ready-to-work` → `later PR closes follow-up`.
