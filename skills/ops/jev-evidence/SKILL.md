---
name: jev-evidence
description: Non-invokable offline evidence contract dependency for Jev patterns. Validate normalized host exports, preserve provenance and replay retained numerical scores.
user-invocable: false
---

# Jev evidence contracts

This is the shared L1 support dependency for `jev-label-and-act` and
`jev-search-and-rerank`, not a new workflow, provider client or feedback store.
Python 3.10+ and the standard library are sufficient. Offline synthetic tests
prove mechanics only; no field-quality or untouched-acceptance claim follows.

## Install explicitly

Install this companion and each desired pattern from the **same immutable source
revision** using your existing individual-skill installer. The installer does not
resolve this dependency automatically. For example, replace `REVISION` below with
the reviewed full Git commit:

```sh
npx --yes skills@1.5.26 add https://github.com/fellowship-dev/dogfooded-skills/tree/REVISION/skills/ops/jev-evidence --agent codex claude-code --yes
npx --yes skills@1.5.26 add https://github.com/fellowship-dev/dogfooded-skills/tree/REVISION/skills/ops/jev-label-and-act --agent codex claude-code --yes
```

Install `jev-search-and-rerank` the same way if needed. Both patterns resolve one
`jev-evidence` sibling in the installed skills directory. Their dependency files
pin the companion version and manifest hash; each entry point checks every
runtime/schema file before loading it. Upgrade the companion and the patterns as
one reviewed set. A partial upgrade fails closed, with a reinstall diagnostic.
Keep the prior install and lock entries for rollback; restore the set together.
No credential, schedule or runtime source migration is part of installation.

## Run

Use a pattern's entry point, which verifies the dependency before use:

```sh
python3 .agents/skills/jev-label-and-act/scripts/check_contract.py version
python3 .agents/skills/jev-label-and-act/scripts/check_contract.py validate /private/export.json
python3 .agents/skills/jev-label-and-act/scripts/check_contract.py replay /private/export.json
python3 .agents/skills/jev-label-and-act/scripts/check_contract.py portable /private/export.json
```

`validate` checks the normalized bundle and returns limitations and eligibility.
`replay` recombines retained numerical scores without inference, source access or
store writes. `portable` emits a separate hash-only projection, not a reversible
source export. Keep the original normalized bundle in its existing private
custody; a digest is a linkage aid, not anonymization or proof of source truth.
Review metadata and authorized disclosure before sharing even the projection.
The lower-level `scripts/cli.py` is useful in source tests; consumers use the
pinned pattern entry point.

## Host contract

`schemas/bundle-v1.json` documents the interchange; `scripts/contracts.py`
enforces it and cross-record semantics with no dependencies. Host adapters own
source collection, provider invocation, persistence, corrections, authority and
recovery. Export every original observation separately; attach adjudications and
supersession edges without replacing its origin. Unknown historical metadata is
null with limitations; never hash an absent input and call it verified state.
References require independently verified attribution and source evidence. A
human assertion alone is not correctness, and a model judge is not human gold.
The core validates declared provenance; it cannot authenticate a host's claims.

Inference identity includes exact presented state and ordered input hashes,
source/account boundary, revisions, requested/resolved model and provider route,
protocol/SDK and inference configuration. Numerical recombination belongs to the
replay policy. Identical inference inputs may share a cache key; distinct actual
invocations retain different attempt IDs, including A-to-B-to-A measurements.
Unknown resolved model prevents strict reproducibility, regardless of alias or
epoch. Preserve full typed probabilities, cost unknowns and interrupted attempts.

No authoritative state is written by the companion. Existing adapters append
idempotently under their host lock and retain genuine attempts independently of
cache keys. An interrupted append is retried with the same attempt identity;
a new inference is a new attempt. Malformed/truncated stores fail closed for host
reconciliation. This L1 release does not implement exposure reservation,
experiment execution, acceptance access control or policy promotion (U3).

## Source validation

Run each `tests/test_*.py` directly with Python. Tests cover both consumer
installation layouts, provenance, validation, identity and zero-call replay.
Host adapter acceptance is separate from this source distribution's tests.
