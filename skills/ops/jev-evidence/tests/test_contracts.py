import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import contracts as c


def fixture():
    return dict(schema_version='1', toolkit_version='1.0.0', identity=dict(
        pattern='synthetic', wrapper_revision='r1', source_boundary='private:account',
        source_revision='r1', state_hash=c.digest('state'), state_builder_revision='r1',
        questions=[c.digest('q')], criteria=[c.digest('c')], candidates=[c.digest('item')],
        model=dict(requested='alias', resolved=None),
        provider=dict(endpoint='endpoint', route='route', protocol='v4', sdk='urllib'),
        adapter_revision='r1', inference_config={}), policy=dict(revision='p1', weights={'x':1}),
        attempts=[dict(attempt_id='a1', invocation_id='i1', timestamp='2026-09-26T00:00:00Z',
            status='success', raw_response_ref=None, usage=dict(input_tokens=None,output_tokens=None,cost=None),
            nondeterministic=True)], evidence=[dict(id='e1', origin='machine', source_ref='private/path',
            source_span='exact private text', source_revision='r1', attribution='machine',
            observation={'label':'yes'}, adjudication=None, supersedes=None, eligible_uses=['development'])],
        scores={'x':.8}, choices=[dict(options=['yes','no'], probabilities={'yes':.8,'no':.2},choice='yes')])

class Contracts(unittest.TestCase):
    def test_unknowns_are_limitations(self):
        report=c.validate_bundle(fixture())
        self.assertFalse(report['eligibility']['strict_reproduction'])
        self.assertTrue(any('cost' in x for x in report['limitations']))
    def test_source_and_measurement_gaps_prevent_strict_reproduction(self):
        for field in ('source_span','source_revision'):
            b=fixture(); b['identity']['model']['resolved']='immutable-v1'
            b['attempts'][0]['raw_response_ref']='retained';b['evidence'][0][field]=None
            self.assertFalse(c.validate_bundle(b)['eligibility']['strict_reproduction'])
        for change in (lambda b:b.update(attempts=[]),lambda b:b['attempts'][0].update(timestamp=None)):
            b=fixture();b['identity']['model']['resolved']='immutable-v1';b['attempts'][0]['raw_response_ref']='retained';change(b)
            self.assertFalse(c.validate_bundle(b)['eligibility']['strict_reproduction'])

    def test_unknown_historical_policy_revision_is_retained(self):
        b=fixture();b['policy']['revision']=None
        report=c.validate_bundle(b)
        self.assertFalse(report['eligibility']['strict_reproduction'])
        self.assertIn('policy.revision: unknown',report['limitations'])

    def test_origins_never_become_reference_by_assertion(self):
        for origin in ['machine','heuristic','synthetic','disputed','unjudged']:
            b=fixture(); b['evidence'][0]['origin']=origin; b['evidence'][0]['eligible_uses']=['reference']
            with self.assertRaises(c.ContractError): c.validate_bundle(b)
    def test_human_confirmed_machine_retains_origin(self):
        b=fixture(); e=b['evidence'][0]; e['adjudication']={'origin':'human','by':'human','source_ref':'turn:2','source_span':'confirmed','source_revision':'r1','independently_verified':True}
        e['eligible_uses']=['reference']
        self.assertEqual(c.validate_bundle(b)['eligibility']['reference_ids'],['e1'])
        self.assertEqual(e['origin'],'machine')
    def test_reference_requires_source(self):
        b=fixture(); e=b['evidence'][0]; e.update(origin='human',eligible_uses=['reference'],adjudication={'origin':'human','by':'human','source_ref':'turn','source_span':'confirmed','source_revision':'r1','independently_verified':True})
        self.assertEqual(c.validate_bundle(b)['eligibility']['reference_ids'],['e1'])
        e['source_span']=None
        with self.assertRaises(c.ContractError): c.validate_bundle(b)
    def test_probability_and_argmax(self):
        for value in [True,float('nan'),float('inf'),-1,1.1,'0.5']:
            b=fixture(); b['scores']['x']=value
            with self.assertRaises(c.ContractError): c.validate_bundle(b)
        b=fixture(); b['choices'][0]['choice']='no'
        with self.assertRaises(c.ContractError): c.validate_bundle(b)
    def test_unknown_fields_and_non_json(self):
        for change in [lambda b:b.update(secret='abc'),lambda b:b['identity'].update(extra='abc'),lambda b:b['identity']['inference_config'].update(x=(1,2))]:
            b=fixture();change(b)
            with self.assertRaises(c.ContractError): c.validate_bundle(b)
    def test_immutable_history(self):
        b=fixture(); c.validate_append(b['evidence'],copy.deepcopy(b['evidence'][0]))
        changed=copy.deepcopy(b['evidence'][0]);changed['observation']='changed'
        with self.assertRaises(c.ContractError): c.validate_append(b['evidence'],changed)
    def test_supersession_must_resolve_without_erasure(self):
        b=fixture(); e=copy.deepcopy(b['evidence'][0]);e.update(id='e2',supersedes='e1');b['evidence'].append(e)
        self.assertTrue(c.validate_bundle(b)['valid']);self.assertEqual(len(b['evidence']),2)
        e['supersedes']='missing'
        with self.assertRaises(c.ContractError):c.validate_bundle(b)
    def test_portable_whitelist(self):
        b=fixture(); secret='PRIVATE_CREDENTIAL_WITHOUT_RECOGNIZABLE_PREFIX'
        b['identity']['provider']['endpoint']=secret;b['evidence'][0]['id']=secret
        b['evidence'][0]['observation']=secret;b['attempts'][0]['attempt_id']=secret
        b['scores']={secret:.8};b['policy']['weights']={secret:1}
        out=json.dumps(c.portable_bundle(b))
        self.assertNotIn(secret,out);self.assertNotIn('exact private text',out);self.assertNotIn('private/path',out)

if __name__=='__main__': unittest.main()
