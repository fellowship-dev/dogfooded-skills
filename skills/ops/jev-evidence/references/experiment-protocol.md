# Offline experiment protocol v1

The executable contract is `scripts/experiments.py`; `tests/test_experiments.py`
contains complete synthetic manifests and commands. Both primary pattern loaders
expose it as `load_core().experiments`. No provider, label loader or disk writer
exists in this module. `new_state(registry_id, adapter_id)` binds an explicitly
selected host authority; `transition(state, operation, payload)` returns detached
JSON state and a receipt. The host must durably commit it before acknowledging.
`validate_state` replays every event and rejects inconsistent derived state.
This detects damaged histories, not an authorized host rewriting its entire log.

The pure pattern CLI accepts `transition request.json`, where the request contains
exactly `state`, `operation`, and `payload`. Its JSON output is a proposal, not a
durable reservation or permission to switch a live policy. Existing hosts keep
their sole writers. Buddy uses `python3 -m scripts.jev_learning_loop --root ROOT
--registry-id ID OPERATION --input REQUEST`; ROOT must be an explicitly selected
existing SearchStore, never an inferred/default private corpus.

## Operations and custody

- `record-run` preserves successful, empty, partial, failed, interrupted and cache
  replayed observations. Corrections are optional, never invented for good runs.
- `record-correction` retains source revision, span, attribution, interpretation,
  verifier and original origin separately. Its `source_lineage` immediately
  exposes the source families. The host authenticates the source. Supersession
  preserves prior observations; `source_ref` is the stable source scope, not a
  new observation ID. No correction creates reference gold.
- `diagnose` retains evidence, alternatives and uncertainty. `add-regression`
  requires a development cohort containing all correction source families.
- `register-cohort` fixes independent units, input/reference hashes, global source
  family lineage, split, custody evidence and sampling counts. Related units must
  be grouped before registration. Reusing a family under a new pattern or case ID
  cannot move it across splits. Host grouping must preserve domain relationships;
  hashes cannot infer omitted relationships.
- `import-exposure` imports existing/cross-host source-family inspection history.
  `expose` records direct inspection. Unknown custody blocks acceptance. A new
  registry is not evidence that historical source families are untouched.
- `compare` freezes baseline/candidate, hypothesis, workload/model/environment,
  metric, budget, three cohort manifests, numeric thresholds and decision card.
  Exact duplicate conditions return the prior experiment. Reconsidering a measured
  hypothesis requires an explicit prior and changed recorded conditions.
- `final-acceptance` durably consumes the frozen cohort **before** the host opens
  labels. An idempotent repeat returns the original receipt; it does not authorize
  another label load or evaluator call. Hosts must check existing reservation.
  Development/validation loaders reject acceptance cohorts.
- `complete` preserves raw per-unit normalized scores, costs and terminal status.
  `decide` computes bounded Hoeffding intervals and registered guardrails. Missing
  units, unknown costs, insufficient precision/coverage and biased samples cannot
  promote. No favorable metric is selected after observation. Late-discovered
  exposure invalidates eligibility even after a historical promotion receipt.
- `set-incumbent` bootstraps only from a host-verified actual pointer.
  `prepare-activation`/`finish-activation` and rollback pairs enforce revision,
  content hash and generation CAS. Intent precedes pointer publication and the
  terminal event follows it. One mode has at most one unfinished transition.
- `prepare-abort`/`finish-abort` restore an interrupted activation's incumbent
  under explicit authority, including when late contamination blocks completion.
  The restored generation advances by two, preventing ABA reuse. The host checks
  exact artifacts and actual pointer before effect; an unrelated pointer is a
  reconciliation conflict, never something to overwrite.

## Current supported claim and limits

This version accepts `claim_scope: synthetic_mechanics` only. Its successful
promotion demonstrates L1 mechanics, not human-gold validity, field quality or
production permission. Random samples and normalized higher-is-better per-unit
scores are implemented. Stratified/biased sampling is retained as inconclusive
until an explicit weighting/estimation contract is implemented. Only the host
can attest real source custody, grouping, evaluator behavior or action authority.
There is no access-control claim against direct filesystem inspection; any such
inspection must be recorded. A registered callback is trusted local code.

Buddy adoption is explicit and additive. It preserves and backs up old exposure
files, imports saved/public histories into one registry, keeps correction rows in
the existing feedback authority, and makes its old learner yield before labeled
case access. Its `recover-attempt` closes killed evaluation as interrupted without
reopening references. No live registry adoption or policy activation follows from
installing this package. Revert the installed package set together; retain all
registry, attempt, exposure and activation history during any rollback.
