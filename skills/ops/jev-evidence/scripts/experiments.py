"""Offline U3 protocol mechanics. Pure JSON reducer; hosts own durability and authority.

This version permits synthetic-mechanics claims only. It neither promotes U2
synthetic observations to reference gold nor establishes field effectiveness.
State replay detects accidental/tampered derived fields, not a malicious host
rewriting its entire history. Custody and authorization attestations belong to
an authenticated host adapter. No labels, filesystem, or provider operations.
"""
import copy
import hashlib
import json
import math
import re

SCHEMA_VERSION = '1'
CARD_KEYS = 'revision primitive features state dependencies composition alternatives failure_boundaries affordability'.split()
TABLES = 'cohorts experiments proposals active pending runs corrections diagnoses regressions exposure_manifests'.split()


def _fail(message):
    raise ValueError(message)


def _json(value):
    def check(v):
        if v is None or type(v) in (str, bool, int): return
        if type(v) is float and math.isfinite(v): return
        if type(v) is list:
            for x in v: check(x)
            return
        if type(v) is dict and all(type(k) is str for k in v):
            for x in v.values(): check(x)
            return
        _fail('expected finite JSON')
    check(value)
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(_json(value).encode('utf-8')).hexdigest()


def _keys(value, keys):
    if type(value) is not dict or set(value) != set(keys.split() if isinstance(keys, str) else keys):
        _fail('unknown or missing fields; expected ' + str(keys))


def _text(value):
    if type(value) is not str or not value.strip(): _fail('nonempty text required')


def _hash(value):
    if type(value) is not str or re.fullmatch('[0-9a-f]{64}', value) is None: _fail('SHA256 required')


def _number(value, low=0, high=None):
    if type(value) not in (int, float) or not math.isfinite(value) or value < low or (high is not None and value > high):
        _fail('invalid numerical value')


def _integer(value, low=0):
    if type(value) is not int or value < low: _fail('invalid integer')


def _bool(value):
    if type(value) is not bool: _fail('boolean required')


def _strings(value, nonempty=True):
    if type(value) is not list or (nonempty and not value): _fail('text list required')
    for x in value: _text(x)
    if len(set(value)) != len(value): _fail('duplicate list member')


def _pointer(value, generation=False):
    _keys(value, 'revision hash generation' if generation else 'revision hash')
    _text(value['revision']); _hash(value['hash'])
    if generation: _integer(value['generation'])


def _pair(pointer):
    return {k: pointer[k] for k in ('revision', 'hash')}


def new_state(registry_id, adapter_id):
    _text(registry_id); _text(adapter_id)
    return dict(schema_version=SCHEMA_VERSION, registry_id=registry_id, adapter_id=adapter_id,
                events=[], **{k: {} for k in TABLES})


def _validate_state(state):
    """Replay all events to check schemas, outcomes, immutability, and derived state."""
    _json(state)
    _keys(state, ['schema_version', 'registry_id', 'adapter_id', 'events'] + TABLES)
    if state['schema_version'] != SCHEMA_VERSION or type(state['events']) is not list: _fail('invalid registry schema')
    replay = new_state(state['registry_id'], state['adapter_id'])
    for event in state['events']:
        _keys(event, 'sequence operation payload receipt')
        _integer(event['sequence'], 1)
        receipt, changed = _apply(replay, event['operation'], copy.deepcopy(event['payload']))
        if not changed or event['sequence'] != len(replay['events']) + 1 or receipt != event['receipt']:
            _fail('invalid event history')
        replay['events'].append(copy.deepcopy(event))
    if replay != state: _fail('derived state does not match immutable event history')
    return copy.deepcopy(state)


def validate_state(state):
    """Validate an untrusted snapshot, returning a detached copy or ValueError."""
    try:
        return _validate_state(state)
    except (TypeError, KeyError, IndexError, OverflowError, RecursionError) as exc:
        raise ValueError('malformed registry state') from exc


def transition(state, operation, payload):
    try:
        work = validate_state(state)
        _json(payload); _text(operation)
        receipt, changed = _apply(work, operation, copy.deepcopy(payload))
        if changed:
            work['events'].append({'sequence': len(work['events']) + 1, 'operation': operation,
                                   'payload': copy.deepcopy(payload), 'receipt': copy.deepcopy(receipt)})
        return work, copy.deepcopy(receipt)
    except (TypeError, KeyError, IndexError, OverflowError, RecursionError) as exc:
        raise ValueError('malformed transition') from exc


def _get(table, key):
    _text(key)
    if key not in table: _fail('unknown reference: ' + key)
    return table[key]


def _existing(table, key, payload, field=None):
    _text(key)
    if key not in table: return None
    old = table[key] if field is None else table[key][field]
    if old != payload: _fail('immutable id reused with different content: ' + key)
    return table[key]


def _lineage(cohort):
    return {family for unit in cohort['units'] for family in unit['lineage']}


def _record(s, table, id_key, p):
    old = _existing(s[table], p[id_key], p)
    if old is not None: return old, False
    s[table][p[id_key]] = p
    return p, True


def _apply(s, op, p):
    if op == 'register-cohort':
        _keys(p, 'cohort_id pattern split units custody sampling')
        for k in ('cohort_id', 'pattern'): _text(p[k])
        if p['split'] not in ('development', 'validation', 'acceptance'): _fail('invalid split')
        _keys(p['custody'], 'verified evidence_ref'); _bool(p['custody']['verified']); _text(p['custody']['evidence_ref'])
        sample = p['sampling']; _keys(sample, 'method population selected missing evidence_ref')
        if sample['method'] not in ('random', 'stratified', 'biased'): _fail('invalid sampling method')
        for k in ('population', 'selected', 'missing'): _integer(sample[k])
        _text(sample['evidence_ref'])
        if sample['selected'] > sample['population'] or sample['missing'] > sample['selected']: _fail('invalid sampling counts')
        if type(p['units']) is not list or len(p['units']) != sample['selected'] - sample['missing']: _fail('sampling unit count mismatch')
        seen_ids = set(); seen_families = set()
        for u in p['units']:
            _keys(u, 'unit_id lineage input_hash reference_hash'); _text(u['unit_id']); _strings(u['lineage'])
            _hash(u['input_hash']); _hash(u['reference_hash'])
            if u['unit_id'] in seen_ids or seen_families.intersection(u['lineage']): _fail('units are not independent; group repeated families first')
            seen_ids.add(u['unit_id']); seen_families.update(u['lineage'])
        old = _existing(s['cohorts'], p['cohort_id'], p, 'manifest')
        if old: return {'cohort_id': p['cohort_id'], 'manifest_hash': digest(p)}, False
        for c in s['cohorts'].values():
            if seen_ids.intersection(u['unit_id'] for u in c['manifest']['units']) or seen_families.intersection(_lineage(c['manifest'])):
                _fail('unit/lineage already registered; cannot reset split or independence')
        s['cohorts'][p['cohort_id']] = {'manifest': p, 'exposures': [], 'consumed_by': None}
        return {'cohort_id': p['cohort_id'], 'manifest_hash': digest(p)}, True
    if op == 'import-exposure':
        _keys(p, 'manifest_id lineage evidence_ref'); _strings(p['lineage']); _text(p['evidence_ref']); _text(p['manifest_id'])
        if p['manifest_id'].startswith('correction:'): _fail('reserved correction exposure namespace')
        return _record(s, 'exposure_manifests', 'manifest_id', p)
    if op == 'expose':
        _keys(p, 'cohort_id reason evidence_ref'); _text(p['reason']); _text(p['evidence_ref'])
        c = _get(s['cohorts'], p['cohort_id'])
        if p in c['exposures']: return p, False
        c['exposures'].append(p)
        return p, True
    if op == 'record-run':
        _keys(p, 'run_id status evidence_ref identity_hash cost_usd')
        if p['status'] not in ('success', 'empty', 'partial', 'failed', 'interrupted', 'cache_replayed'): _fail('invalid run status')
        _text(p['evidence_ref']); _hash(p['identity_hash'])
        if p['cost_usd'] is not None: _number(p['cost_usd'])
        return _record(s, 'runs', 'run_id', p)
    if op == 'record-correction':
        _keys(p, 'correction_id run_id source_ref source_revision source_span source_lineage attribution interpretation origin verifier_ref verified supersedes')
        _get(s['runs'], p['run_id']); _bool(p['verified']); _strings(p['source_lineage'])
        for k in ('source_ref', 'source_revision', 'source_span', 'attribution', 'interpretation', 'origin'): _text(p[k])
        if p['verifier_ref'] is not None: _text(p['verifier_ref'])
        if p['verified'] and not p['verifier_ref']: _fail('verified correction requires verifier reference')
        if p['supersedes'] is not None:
            prior = _get(s['corrections'], p['supersedes'])
            if prior['correction_id'] == p['correction_id'] or prior['source_ref'] != p['source_ref']: _fail('invalid supersession')
        receipt, changed = _record(s, 'corrections', 'correction_id', p)
        if changed:
            manifest_id = 'correction:' + p['correction_id']
            s['exposure_manifests'][manifest_id] = {'manifest_id': manifest_id,
                'lineage': copy.deepcopy(p['source_lineage']), 'evidence_ref': p['source_ref']}
        return receipt, changed
    if op == 'diagnose':
        _keys(p, 'diagnosis_id correction_id classification evidence_refs alternatives verified')
        _get(s['corrections'], p['correction_id']); _strings(p['evidence_refs']); _strings(p['alternatives'], False); _bool(p['verified'])
        if p['classification'] not in ('collection', 'candidate', 'context', 'judgment', 'composition', 'policy', 'execution', 'reference-label', 'unknown'): _fail('unknown diagnosis classification')
        return _record(s, 'diagnoses', 'diagnosis_id', p)
    if op == 'add-regression':
        _keys(p, 'regression_id diagnosis_id cohort_id'); diagnosis = _get(s['diagnoses'], p['diagnosis_id'])
        correction = s['corrections'][diagnosis['correction_id']]
        c = _get(s['cohorts'], p['cohort_id'])
        if c['manifest']['split'] != 'development': _fail('regression must be development evidence')
        if not set(correction['source_lineage']).issubset(_lineage(c['manifest'])):
            _fail('regression cohort does not contain correction source lineage')
        r, changed = _record(s, 'regressions', 'regression_id', p)
        if changed: c['exposures'].append({'cohort_id': p['cohort_id'], 'reason': 'regression', 'evidence_ref': p['regression_id']})
        return r, changed
    if op == 'compare':
        return _compare(s, p)
    if op == 'final-acceptance':
        _keys(p, 'experiment_id'); x = _get(s['experiments'], p['experiment_id'])
        if 'acceptance' in x: return x['acceptance'], False
        if x['status'] != 'preregistered': _fail('experiment already ended')
        c = _get(s['cohorts'], x['manifest']['cohorts']['acceptance'])
        if not c['manifest']['custody']['verified']: _fail('unknown acceptance custody')
        if c['exposures'] or c['consumed_by'] is not None: _fail('acceptance already exposed or consumed')
        lineage = _lineage(c['manifest'])
        if any(lineage.intersection(m['lineage']) for m in s['exposure_manifests'].values()): _fail('imported lineage exposure')
        c['consumed_by'] = p['experiment_id']; x['status'] = 'evaluating'
        x['acceptance'] = {'experiment_id': p['experiment_id'], 'status': 'evaluating', 'manifest': copy.deepcopy(x['manifest']),
                           'manifest_hash': digest(x['manifest']), 'cohort': copy.deepcopy(c['manifest'])}
        return x['acceptance'], True
    if op == 'complete':
        _keys(p, 'experiment_id status measurements cost_usd evidence_ref guardrails_passed')
        x = _get(s['experiments'], p['experiment_id'])
        if 'completion' in x:
            if x['completion'] != p: _fail('immutable completion')
            return x['completion'], False
        if x['status'] != 'evaluating': _fail('acceptance must be consumed before completion')
        if p['status'] not in ('completed', 'failed', 'interrupted'): _fail('invalid completion status')
        _text(p['evidence_ref']); _bool(p['guardrails_passed'])
        if p['cost_usd'] is not None: _number(p['cost_usd'])
        if type(p['measurements']) is not list: _fail('measurements must be a list')
        ids = {u['unit_id'] for u in x['acceptance']['cohort']['units']}; seen = set()
        for m in p['measurements']:
            _keys(m, 'unit_id baseline candidate'); _text(m['unit_id']); _number(m['baseline'], 0, 1); _number(m['candidate'], 0, 1)
            if m['unit_id'] not in ids or m['unit_id'] in seen: _fail('measurement not unique registered acceptance unit')
            seen.add(m['unit_id'])
        x['completion'] = p; x['status'] = p['status']
        return p, True
    if op == 'decide':
        _keys(p, 'experiment_id'); x = _get(s['experiments'], p['experiment_id'])
        if 'decision' in x:
            if x['decision']['decision'] == 'promote' and _contaminated(s, x): _fail('acceptance contaminated after decision')
            return x['decision'], False
        if 'completion' not in x: _fail('terminal outcome required before decision')
        x['decision'] = _decide(s, x)
        return x['decision'], True
    if op == 'set-incumbent':
        _keys(p, 'mode revision hash'); _text(p['mode']); _pointer(_pair(p))
        target = dict(_pair(p), generation=0)
        if p['mode'] in s['active']:
            if s['active'][p['mode']] == target: return target, False
            _fail('incumbent is bootstrap-only')
        s['active'][p['mode']] = target
        return target, True
    if op in ('prepare-activation', 'prepare-rollback'):
        return _prepare(s, op, p)
    if op == 'prepare-abort':
        _keys(p, 'activation_id authority_ref'); _text(p['authority_ref'])
        pending = _get(s['pending'], p['activation_id'])
        if pending['kind'] != 'activation': _fail('only an activation can be aborted')
        if pending['status'] in ('aborting', 'aborted'):
            if pending['abort_authority_ref'] != p['authority_ref']: _fail('immutable abort authority')
            return pending, False
        if pending['status'] != 'prepared': _fail('only a prepared activation can be aborted')
        if s['active'][pending['mode']] != pending['expected']: _fail('concurrent active pointer change')
        pending['status'] = 'aborting'
        pending['abort_authority_ref'] = p['authority_ref']
        pending['abort_reason'] = 'explicit_authorized_restore_of_incumbent'
        return pending, True
    if op == 'finish-abort':
        _keys(p, 'activation_id observed'); _pointer(p['observed'])
        pending = _get(s['pending'], p['activation_id'])
        if pending['kind'] != 'activation': _fail('only an activation can be aborted')
        if p['observed'] != _pair(pending['expected']): _fail('abort must observe restored incumbent')
        if pending['status'] == 'aborted': return pending, False
        if pending['status'] != 'aborting': _fail('durable abort preparation required')
        if s['active'][pending['mode']] != pending['expected']: _fail('concurrent active pointer change')
        # Reserve both potential switch and restore generations, even when the
        # host proves the switch never occurred. A stale pre-crash CAS cannot win.
        s['active'][pending['mode']] = dict(p['observed'], generation=pending['expected']['generation'] + 2)
        pending['status'] = 'aborted'
        return pending, True
    if op in ('finish-activation', 'finish-rollback'):
        _keys(p, 'activation_id observed'); _pointer(p['observed'])
        pending = _get(s['pending'], p['activation_id'])
        kind = 'activation' if op == 'finish-activation' else 'rollback'
        if pending['kind'] != kind or p['observed'] != pending['target']: _fail('observed pointer differs from pending target')
        if pending['status'] == 'completed': return pending, False
        if pending['status'] != 'prepared': _fail('transition is no longer prepared')
        if kind == 'activation' and _contaminated(s, s['experiments'][pending['request']['experiment_id']]):
            _fail('acceptance contaminated before activation finish')
        if s['active'][pending['mode']] != pending['expected']: _fail('concurrent active pointer change')
        s['active'][pending['mode']] = dict(pending['target'], generation=pending['expected']['generation'] + 1)
        pending['status'] = 'completed'
        return pending, True
    _fail('unknown operation: ' + str(op))


def _compare(s, p):
    _keys(p, 'experiment_id claim_scope hypothesis scope baseline candidate model workload environment budget_usd metric cohorts thresholds decision_card reconsideration')
    for k in ('experiment_id', 'hypothesis', 'scope'): _text(p[k])
    if p['claim_scope'] != 'synthetic_mechanics': _fail('only synthetic mechanics claims implemented')
    _pointer(p['baseline']); _pointer(p['candidate'])
    if p['baseline']['hash'] == p['candidate']['hash'] or p['baseline']['revision'] == p['candidate']['revision']: _fail('candidate must differ from baseline')
    # Versioned descriptors are host-defined opaque JSON, committed by fingerprint.
    for k in ('model', 'workload', 'environment', 'metric'):
        if type(p[k]) is not dict or not p[k]: _fail('nonempty versioned descriptor required: ' + k)
        if 'revision' not in p[k]: _fail('descriptor revision required: ' + k)
        _text(p[k]['revision'])
    _number(p['budget_usd'])
    _keys(p['cohorts'], 'development validation acceptance')
    if len(set(p['cohorts'].values())) != 3: _fail('three distinct splits required')
    for split, cid in p['cohorts'].items():
        if _get(s['cohorts'], cid)['manifest']['split'] != split: _fail('wrong cohort split')
    t = p['thresholds']; _keys(t, 'min_units min_gain max_regression max_ci_width min_coverage')
    _integer(t['min_units'], 1); _number(t['min_gain'], 0, 1); _number(t['max_regression'], 0, 1); _number(t['max_ci_width'], 0, 2); _number(t['min_coverage'], 0, 1)
    if t['max_ci_width'] == 0 or t['min_coverage'] == 0: _fail('precision and coverage must be positive')
    _keys(p['decision_card'], CARD_KEYS)
    for value in p['decision_card'].values():
        if value is None or value == '' or value == [] or value == {}: _fail('complete decision card required')
    conditions = {k: v for k, v in p.items() if k not in ('experiment_id', 'reconsideration')}
    conditions['cohort_manifests'] = {split: s['cohorts'][cid]['manifest'] for split, cid in p['cohorts'].items()}
    fingerprint = digest(conditions)
    old = _existing(s['experiments'], p['experiment_id'], p, 'manifest')
    if old: return {'experiment_id': p['experiment_id'], 'fingerprint': old['fingerprint']}, False
    if p['reconsideration'] is not None:
        _keys(p['reconsideration'], 'prior_experiment_id reason'); _text(p['reconsideration']['reason'])
        prior = _get(s['experiments'], p['reconsideration']['prior_experiment_id'])
        if prior['fingerprint'] == fingerprint: _fail('reconsideration needs a material condition change')
    if fingerprint in s['proposals']:
        return {'experiment_id': s['proposals'][fingerprint], 'fingerprint': fingerprint}, False
    if p['reconsideration'] is None and any(
        prior['manifest']['hypothesis'] == p['hypothesis'] and prior['manifest']['scope'] == p['scope']
        and 'completion' in prior for prior in s['experiments'].values()
    ):
        _fail('reconsidering a measured hypothesis requires a named prior and material change')
    s['experiments'][p['experiment_id']] = {'manifest': p, 'fingerprint': fingerprint, 'status': 'preregistered'}
    s['proposals'][fingerprint] = p['experiment_id']
    return {'experiment_id': p['experiment_id'], 'fingerprint': fingerprint}, True


def _contaminated(s, x):
    c = s['cohorts'][x['manifest']['cohorts']['acceptance']]
    lineage = _lineage(c['manifest'])
    return bool(c['exposures']) or any(
        lineage.intersection(m['lineage']) for m in s['exposure_manifests'].values()
    )


def _decide(s, x):
    p = x['manifest']; completion = x['completion']; cohort = x['acceptance']['cohort']; t = p['thresholds']; sample = cohort['sampling']
    differences = [m['candidate'] - m['baseline'] for m in completion['measurements']]
    n = len(differences); expected_n = len(cohort['units'])
    mean = sum(differences) / n if n else None
    radius = math.sqrt(2 * math.log(40) / n) if n else None  # range [-1,1], two-sided 95% Hoeffding
    metrics = {'independent_units': n, 'expected_units': expected_n, 'mean_gain': mean,
               'ci_low': max(-1, mean-radius) if n else None, 'ci_high': min(1, mean+radius) if n else None,
               'ci_width': 2*radius if n else None, 'coverage': sample['selected']/sample['population'] if sample['population'] else 0,
               'cost_usd': completion['cost_usd'], 'interval': 'bounded_hoeffding_95'}
    reasons = []; decision = 'inconclusive'
    if _contaminated(s, x): decision = 'invalid'; reasons.append('acceptance_externally_exposed')
    elif completion['status'] != 'completed': decision = 'invalid'; reasons.append('execution_' + completion['status'])
    elif not completion['guardrails_passed']: decision = 'reject'; reasons.append('guardrails_failed')
    else:
        if n != expected_n: reasons.append('incomplete_measurements')
        if n < t['min_units']: reasons.append('insufficient_independent_units')
        if sample['method'] != 'random': reasons.append('population_sampling_not_random')
        if sample['missing']: reasons.append('missing_source_units')
        if metrics['coverage'] < t['min_coverage']: reasons.append('low_coverage')
        if completion['cost_usd'] is None: reasons.append('unknown_cost')
        elif completion['cost_usd'] > p['budget_usd']: reasons.append('over_budget')
        if not n or metrics['ci_width'] > t['max_ci_width']: reasons.append('insufficient_precision')
        if not reasons:
            if metrics['ci_low'] >= t['min_gain'] and all(d >= -t['max_regression'] for d in differences):
                decision = 'promote'; reasons.append('all_preregistered_gates_passed')
            elif metrics['ci_high'] < t['min_gain'] or any(d < -t['max_regression'] for d in differences):
                decision = 'reject'; reasons.append('gain_or_regression_gate_failed')
            else: reasons.append('gain_interval_inconclusive')
    return {'experiment_id': p['experiment_id'], 'decision': decision, 'reasons': reasons, 'metrics': metrics,
            'claim_scope': p['claim_scope'], 'decision_card': copy.deepcopy(p['decision_card']),
            'manifest_hash': digest(p), 'action': 'eligible_for_authorized_activation' if decision == 'promote' else 'retain_current'}


def _prepare(s, op, p):
    rollback = op == 'prepare-rollback'
    _keys(p, 'activation_id prior_activation_id mode expected authority_ref' if rollback else 'activation_id experiment_id mode expected authority_ref')
    _text(p['activation_id']); _text(p['mode']); _text(p['authority_ref']); _pointer(p['expected'], True)
    old = _existing(s['pending'], p['activation_id'], p, 'request')
    if old:
        if not rollback and old['status'] == 'prepared' and _contaminated(s, s['experiments'][p['experiment_id']]):
            _fail('acceptance contaminated during pending activation')
        return old, False
    current = _get(s['active'], p['mode'])
    if current != p['expected']: _fail('active pointer compare-and-swap conflict')
    if any(v['mode'] == p['mode'] and v['status'] in ('prepared', 'aborting') for v in s['pending'].values()): _fail('mode has pending transition')
    if rollback:
        prior = _get(s['pending'], p['prior_activation_id'])
        if prior['kind'] != 'activation' or prior['status'] != 'completed' or prior['mode'] != p['mode']:
            _fail('rollback requires completed activation in same mode')
        if _pair(current) != prior['target'] or current['generation'] != prior['expected']['generation'] + 1:
            _fail('rollback target is no longer current activation')
        target = prior['rollback_ref']
    else:
        x = _get(s['experiments'], p['experiment_id'])
        if x.get('decision', {}).get('decision') != 'promote': _fail('durable promote decision required')
        if _contaminated(s, x): _fail('acceptance contaminated after decision')
        if _pair(current) != x['manifest']['baseline']: _fail('baseline is not incumbent')
        target = x['manifest']['candidate']
    r = {'activation_id': p['activation_id'], 'kind': 'rollback' if rollback else 'activation', 'mode': p['mode'],
         'expected': copy.deepcopy(p['expected']), 'target': copy.deepcopy(target), 'rollback_ref': _pair(current),
         'authority_ref': p['authority_ref'], 'status': 'prepared', 'request': p}
    s['pending'][p['activation_id']] = r
    return r, True


def main():
    import sys
    try:
        request = json.load(sys.stdin)
        _keys(request, 'state operation payload')
        state, receipt = transition(request['state'], request['operation'], request['payload'])
        print(_json({'state': state, 'receipt': receipt}))
    except (ValueError, TypeError, KeyError) as exc:
        print(_json({'error': str(exc)}), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
