import copy
import unittest
from test_contracts import c, fixture

class Identity(unittest.TestCase):
    def test_every_inference_field_and_order_changes_key(self):
        identity=fixture()['identity']; baseline=c.inference_key(identity)
        paths=[]
        def leaves(value,path=()):
            if isinstance(value,dict) and value:
                for k,v in value.items(): leaves(v,path+(k,))
            else: paths.append(path)
        leaves(identity)
        for path in paths:
            changed=copy.deepcopy(identity); target=changed
            for k in path[:-1]: target=target[k]
            old=target[path[-1]]
            target[path[-1]]=old+['different'] if isinstance(old,list) else ({'temperature':.2} if isinstance(old,dict) else 'different')
            self.assertNotEqual(baseline,c.inference_key(changed),path)
        for key in ('questions','criteria','candidates'):
            a=copy.deepcopy(identity);a[key]=['a','b'];b=copy.deepcopy(a);b[key].reverse()
            self.assertNotEqual(c.inference_key(a),c.inference_key(b))
    def test_a_b_a_attempts_never_collapse(self):
        a=fixture()['identity'];b=copy.deepcopy(a);b['model']['requested']='B'
        self.assertEqual(c.inference_key(a),c.inference_key(copy.deepcopy(a)))
        self.assertEqual(len({c.attempt_key(a,'1'),c.attempt_key(b,'2'),c.attempt_key(a,'3')}),3)
    def test_policy_replay_is_independent(self):
        identity=fixture()['identity'];p={'revision':'r1','weights':{'x':1,'y':0}};q={'revision':'r2','weights':{'x':0,'y':1}}
        self.assertNotEqual(c.replay_key(identity,p,{'x':.9},fixture()['attempts']),c.replay_key(identity,q,{'x':.9},fixture()['attempts']))
        self.assertEqual(c.replay({'x':.9,'y':.1},p['weights']),.9)
        self.assertEqual(c.replay({'x':.9,'y':.1},q['weights']),.1)
    def test_legacy_unknown_does_not_attest(self):
        b=fixture();b['identity']['state_hash']=None;b['identity']['questions']=None;b['identity']['provider']['sdk']=None
        report=c.validate_bundle(b)
        self.assertFalse(report['eligibility']['strict_reproduction'])
        self.assertTrue(any('state_hash' in x for x in report['limitations']))
    def test_replay_identity_binds_retained_scores_and_attempts(self):
        b=fixture();identity=b['identity'];policy=b['policy'];attempts=b['attempts']
        baseline=c.replay_key(identity,policy,{'x':.2},attempts)
        self.assertNotEqual(baseline,c.replay_key(identity,policy,{'x':.8},attempts))
        newer=copy.deepcopy(attempts);newer[0]['attempt_id']='a2'
        self.assertNotEqual(baseline,c.replay_key(identity,policy,{'x':.2},newer))
        with self.assertRaises(c.ContractError):c.replay_key(identity,policy,{'x':float('nan')},attempts)

    def test_nested_unknown_identity_never_authorizes_reuse(self):
        a=fixture()['identity'];a['model']['resolved']='immutable-v1'
        a['inference_config']={'messages':[{'content':None}]}
        report=c.compare_identities(a,a)
        self.assertFalse(report['reusable'])
        self.assertIn('identity.inference_config.messages[0].content',report['unknown_fields'])

    def test_drift_and_unknown_identity_never_authorize_reuse(self):
        a=fixture()['identity']
        self.assertFalse(c.compare_identities(a,a)['reusable'])
        a['model']['resolved']='immutable-v1'
        self.assertTrue(c.compare_identities(a,a)['reusable'])
        b=copy.deepcopy(a); b['provider']['route']='new-route'
        report=c.compare_identities(a,b)
        self.assertFalse(report['reusable'])
        self.assertIn('identity.provider.route',report['changed_fields'])

    def test_replay_rejects_partial_or_boolean_weights(self):
        for weights in ({'z':1},{'x':True},{'x':0}):
            with self.assertRaises(c.ContractError):c.replay({'x':.5},weights)

if __name__=='__main__':unittest.main()
