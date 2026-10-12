---
name: pylot-cli
description: Moved. The pylot-cli skill (operating devboxes with `pylot devbox`) now ships from fellowship-dev/pylot-devboxes, next to the CLI it documents. Install it from there.
metadata:
  status: deprecated
  source: fellowship-dev/pylot-devboxes
---

# pylot-cli has moved

This skill now lives with the CLI, in
[fellowship-dev/pylot-devboxes `skills/pylot-cli`](https://github.com/fellowship-dev/pylot-devboxes/tree/main/skills/pylot-cli).
It is versioned with `pylot-cli`, and CI checks it against the CLI's `--help`.

```sh
npx skills add fellowship-dev/pylot-devboxes --skill pylot-cli
npx skills add fellowship-dev/pylot-devboxes --skill devbox-recipe   # writing recipes
```

Lock files that pin `fellowship-dev/dogfooded-skills` / `skills/ops/pylot-cli/SKILL.md`
should switch to `source: fellowship-dev/pylot-devboxes`, `skillPath: skills/pylot-cli/SKILL.md`.

The hosted Pylot platform content (missions, assets, team settings, workers,
automations) was dropped: that platform is being retired. Its last version is
in this repo's history at commit `121de67`. For the old CLI, use `pylot-legacy --help`.
