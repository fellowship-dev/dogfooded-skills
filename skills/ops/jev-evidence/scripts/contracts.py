"""Pure, stdlib evidence contracts. No providers, stores, or action authority.

The sibling JSON Schema declares structure; x-contract checks below enforce
cross-field provenance, chronology and probability invariants.
"""
import hashlib
import json
import math
from pathlib import Path

VERSION = '1.0.0'
SCHEMA_VERSION = '1'

class ContractError(ValueError):
    pass


def _json(value, path='$'):
    if value is None or type(value) in (str, bool, int): return
    if type(value) is float and math.isfinite(value): return
    if type(value) is list:
        for i, item in enumerate(value): _json(item, f'{path}[{i}]')
        return
    if type(value) is dict and all(type(k) is str for k in value):
        for key, item in value.items(): _json(item, f'{path}.{key}')
        return
    raise ContractError(f'{path}: must be finite JSON-compatible data')


def canonical_json(value):
    _json(value)
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical_json(value).encode('utf-8')).hexdigest()


def _schema(value, spec, path='$'):
    if '$ref' in spec:
        return _schema(value, SCHEMA['$defs'][spec['$ref'].split('/')[-1]], path)
    if 'anyOf' in spec:
        for variant in spec['anyOf']:
            try: _schema(value, variant, path); return
            except ContractError: pass
        raise ContractError(f'{path}: does not match allowed types')
    kind = spec.get('type')
    valid = {'null':value is None, 'string':type(value) is str,
        'object':type(value) is dict, 'array':type(value) is list,
        'boolean':type(value) is bool, 'integer':type(value) is int,
        'number':type(value) in (int,float)}
    if kind and not valid[kind]: raise ContractError(f'{path}: expected {kind}')
    if 'const' in spec and value != spec['const']: raise ContractError(f'{path}: unsupported value')
    if 'enum' in spec and value not in spec['enum']: raise ContractError(f'{path}: invalid enum')
    if kind == 'string' and len(value) < spec.get('minLength',0): raise ContractError(f'{path}: empty string')
    if kind in ('number','integer'):
        if value < spec.get('minimum', -math.inf) or value > spec.get('maximum',math.inf): raise ContractError(f'{path}: out of range')
    if kind == 'array':
        if len(value)<spec.get('minItems',0): raise ContractError(f'{path}: empty array')
        if spec.get('uniqueItems') and len({canonical_json(x) for x in value})!=len(value): raise ContractError(f'{path}: duplicates')
        for i,item in enumerate(value): _schema(item,spec.get('items',{}),f'{path}[{i}]')
    if kind == 'object':
        properties=spec.get('properties',{})
        if not set(spec.get('required',[]))<=set(value): raise ContractError(f'{path}: missing required fields')
        for key,item in value.items():
            if key in properties: _schema(item,properties[key],f'{path}.{key}')
            elif spec.get('additionalProperties') is False: raise ContractError(f'{path}: unknown field {key}')
            elif isinstance(spec.get('additionalProperties'),dict): _schema(item,spec['additionalProperties'],f'{path}.{key}')


def _load_schema():
    """Prefer bytes a byte-pinning loader already hash-verified.

    A loader that has just verified `schemas/bundle-v1.json` against a pinned
    manifest hash (e.g. `check_contract.py`) should inject those exact bytes as
    `_VERIFIED_SCHEMA_JSON` on this module before/at exec time. Falling back to
    an independent disk read here would silently reopen the TOCTOU window the
    loader's verification was meant to close, and would defeat the point of
    hashing this file at all. The disk-read fallback exists only for direct/
    standalone use (running or importing this file without going through a
    pinning loader), where there is nothing to have verified in the first place.
    """
    injected = globals().get('_VERIFIED_SCHEMA_JSON')
    if injected is not None:
        return json.loads(injected)
    return json.loads((Path(__file__).resolve().parents[1] / 'schemas' / 'bundle-v1.json').read_text())


SCHEMA = _load_schema()


def _validate_identity(identity):
    _json(identity); _schema(identity, SCHEMA['$defs']['identity'])


def inference_key(identity):
    """Order is retained for questions, criteria and candidates; unknown stays null.

    This content key never attests unresolved model weights. Check eligibility
    before reuse; attempts are independent of this content identity.
    """
    _validate_identity(identity)
    return digest({'kind':'inference-v1','identity':identity})


def replay_key(identity, policy, scores, attempts):
    """Bind policy to these retained measurements, not just inference inputs."""
    _json(policy); _schema(policy, SCHEMA['$defs']['policy'])
    _json(scores); _schema(scores, SCHEMA['$defs']['scores'])
    _json(attempts); _schema(attempts, SCHEMA['properties']['attempts'])
    if len({a['attempt_id'] for a in attempts}) != len(attempts):
        raise ContractError('duplicate attempt_id')
    return digest({'kind':'replay-v1','inference_key':inference_key(identity),
                   'policy':policy,'scores':scores,'attempts_digest':digest(attempts)})


def attempt_key(identity, attempt_id):
    if not isinstance(attempt_id,str) or not attempt_id: raise ContractError('attempt_id required')
    return digest({'inference_key':inference_key(identity),'attempt_id':attempt_id})


def replay(scores, weights):
    """Weighted mean of retained scores, entirely local; keys must match exactly."""
    _json(scores); _json(weights)
    _schema(scores, SCHEMA['$defs']['scores']); _schema(weights,SCHEMA['$defs']['weights'])
    if not scores or set(scores)!=set(weights): raise ContractError('replay requires matching nonempty score and weight keys')
    total=sum(weights.values())
    if total <= 0 or not math.isfinite(total): raise ContractError('positive finite weight sum required')
    result=sum(scores[k]*(weights[k]/total) for k in scores)
    if not math.isfinite(result): raise ContractError('nonfinite replay')
    return result


def validate_append(history, observation):
    """Validate immutable retry semantics; persistence remains the host's job."""
    _json(observation); _schema(observation,SCHEMA['$defs']['evidence'])
    for previous in history:
        if previous['id']==observation['id']:
            if canonical_json(previous)!=canonical_json(observation): raise ContractError('immutable observation changed')
            return False
    if observation['supersedes'] and observation['supersedes'] not in {x['id'] for x in history}:
        raise ContractError('supersedes must reference prior observation')
    return True


def validate_bundle(bundle):
    _json(bundle); _schema(bundle,SCHEMA)
    limitations=[]
    def unknowns(value,path):
        if value is None: limitations.append(f'{path}: unknown')
        elif isinstance(value,dict):
            for k,v in value.items(): unknowns(v,f'{path}.{k}')
        elif isinstance(value,list):
            for i,v in enumerate(value): unknowns(v,f'{path}[{i}]')
    unknowns(bundle['identity'],'identity')
    unknowns(bundle['policy'],'policy')
    strict=not limitations
    if not bundle['attempts']:
        limitations.append('attempts: absent measurement')
        strict=False
    seen=set()
    for attempt in bundle['attempts']:
        if attempt['attempt_id'] in seen: raise ContractError('duplicate attempt_id')
        seen.add(attempt['attempt_id'])
        if attempt['timestamp'] is None:
            limitations.append(f"attempt.{attempt['attempt_id']}: unknown timestamp")
            strict=False
        unknowns(attempt['usage'],f"attempt.{attempt['attempt_id']}.usage")
        if attempt['raw_response_ref'] is None:
            limitations.append(f"attempt.{attempt['attempt_id']}: missing raw response")
            strict=False
    history=[]; references=[]
    for event in bundle['evidence']:
        if not validate_append(history,event): raise ContractError('duplicate evidence id')
        history.append(event)
        source=all(event[k] is not None for k in ('source_ref','source_span','source_revision','attribution'))
        if not source:
            limitations.append(f"evidence.{event['id']}: missing source provenance")
            strict=False
        adjudication=event['adjudication']
        qualifies=(source and event['origin'] not in ('synthetic','disputed','unjudged')
                   and adjudication is not None and adjudication['independently_verified'])
        if 'reference' in event['eligible_uses']:
            if not qualifies: raise ContractError(f"evidence.{event['id']}: ineligible reference")
            references.append(event['id'])
    superseded={e['supersedes'] for e in history}
    references=[key for key in references if key not in superseded]
    for choice in bundle['choices']:
        probs=choice['probabilities']
        if set(probs)!=set(choice['options']) or choice['choice'] not in probs: raise ContractError('choice options mismatch')
        if not .98 <= sum(probs.values()) <= 1.02: raise ContractError('invalid probability sum')
        if probs[choice['choice']] != max(probs.values()): raise ContractError('choice must be an argmax')
    return {'valid':True,'limitations':limitations,'eligibility':{'reference_ids':references,'strict_reproduction':strict}}


def portable_bundle(bundle):
    """Hash-only whitelist projection, NOT a reloadable private evidence bundle.

    Untrusted names, refs, timestamps, labels and provider fields never leave
    verbatim. Hashes preserve linkage, not anonymity or source attestation.
    """
    report=validate_bundle(bundle)
    return {'projection_version':'1','schema_version':'1','toolkit_version':VERSION,
        'bundle_hash':digest(bundle),'inference_key':inference_key(bundle['identity']),
        'replay_key':replay_key(bundle['identity'],bundle['policy'],bundle['scores'],bundle['attempts']),
        'attempts':[{'attempt_hash':digest(a),'attempt_id_hash':digest(a['attempt_id']),
            'status':a['status'],'nondeterministic':a['nondeterministic'],'usage':a['usage']} for a in bundle['attempts']],
        'evidence':[{'id_hash':digest(e['id']),'origin':e['origin'],'observation_hash':digest(e['observation']),
            'source_hash':digest([e['source_ref'],e['source_span'],e['source_revision']]),
            'adjudication_hash':digest(e['adjudication']), 'supersedes_hash':digest(e['supersedes']) if e['supersedes'] else None,
            'eligible_uses':e['eligible_uses']} for e in bundle['evidence']],
        'scores':[{'name_hash':digest(k),'value':v} for k,v in bundle['scores'].items()],
        'limitations_count':len(report['limitations']), 'strict_reproduction':report['eligibility']['strict_reproduction']}


def compare_identities(previous, current):
    """Detect input drift. Equal unresolved aliases never authorize reuse.

    Null values anywhere in configuration conservatively mean unknown; adapters
    that deliberately use JSON null cannot claim strict reuse through this API.
    Content reuse eligibility does not establish a new live attempt, nor attest
    that provider declarations are truthful; the host must verify provenance.
    """
    _validate_identity(previous); _validate_identity(current)
    changed=[]; unknown=[]
    def inspect(a,b,path):
        if isinstance(a,dict) and isinstance(b,dict):
            for key in sorted(set(a)|set(b)):
                if key not in a or key not in b: changed.append(path+'.'+key)
                else: inspect(a[key],b[key],path+'.'+key)
        elif isinstance(a,list) and isinstance(b,list):
            if len(a)!=len(b): changed.append(path)
            for i in range(min(len(a),len(b))): inspect(a[i],b[i],f'{path}[{i}]')
        else:
            if canonical_json(a)!=canonical_json(b): changed.append(path)
        if a is None or b is None: unknown.append(path)
    inspect(previous,current,'identity')
    return {'changed_fields':changed,'unknown_fields':unknown,
            'reusable':not changed and not unknown}
