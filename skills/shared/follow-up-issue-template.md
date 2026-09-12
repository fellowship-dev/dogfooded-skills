# Follow-up Issue Contract

Use this contract when a pull request closes its driving issue but deliberately defers one or more
named acceptance criteria. Both the pull request author and reviewer must link the created follow-up
from the closing pull request.

## Required format

- The title begins exactly `Follow-up of #N`, where `N` is the driving issue number.
- The first line of the body is exactly `Follow-up of #N`.
- `Origin` links both issue `#N` and the pull request that closes it.
- `Remaining acceptance criteria` copies every deferred named criterion verbatim from issue `#N`.
  Do not summarize, paraphrase, split, or combine the criteria.
- `Out of scope` states the bounded remainder and distinguishes it from work completed by the
  closing pull request.
- The closing pull request links the follow-up issue.
- Apply the `ready-to-work` label and the same priority label as issue `#N`. If issue `#N` has no
  priority label, apply only `ready-to-work`; do not invent a priority.

## Copy-ready example

Replace each placeholder while preserving the headings and opening line.

```markdown
Follow-up of #N

## Origin

- Driving issue: #N
- Closing pull request: #PR

## Remaining acceptance criteria

- [verbatim criterion copied from issue #N]

## Out of scope

[bounded description of the work deferred from #PR]
```

After creating the issue, add `ready-to-work` and copy issue `#N`'s priority label. Then add the
follow-up issue link to pull request `#PR` before that pull request is considered shippable.
