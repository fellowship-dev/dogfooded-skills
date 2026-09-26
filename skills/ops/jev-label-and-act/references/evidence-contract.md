# Evidence contract dependency

Install `jev-evidence` and this pattern from the same reviewed immutable commit
in `fellowship-dev/dogfooded-skills`. Use the individual-skill installer on each
`skills/ops/<name>` tree URL; it does not install dependencies automatically.
The expected version and manifest digest are in `evidence-dependency.json`.
The sibling companion's SKILL.md documents the commands and normalized schema.

```sh
python3 scripts/check_contract.py version
python3 scripts/check_contract.py validate /private/normalized-bundle.json
python3 scripts/check_contract.py replay /private/normalized-bundle.json
python3 scripts/check_contract.py portable /private/normalized-bundle.json
```

Host adapters remain the sole authoritative writers. Preserve historical nulls,
source limitations, original labels and adjudications. A public projection hashes
private values; it is not a restorable source bundle or proof of truth. L1
conformance is not field quality. Upgrade and rollback the companion/pattern set
together; keep previous immutable lock entries and installed bytes.
