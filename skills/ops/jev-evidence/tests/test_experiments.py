"""Synthetic protocol fixtures; no field-quality or U2 gold-reference claim."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('experiments', Path(__file__).resolve().parents[1] / 'scripts/experiments.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


def cohort(cid, split, n=100):
    return {'cohort_id': cid, 'pattern': 'synthetic', 'split': split,
            'units': [{'unit_id': f'{cid}-{i}', 'lineage': [f'family-{cid}-{i}'], 'input_hash': e.digest(['input', cid, i]), 'reference_hash': e.digest(['reference', cid, i])} for i in range(n)],
            'custody': {'verified': True, 'evidence_ref': 'synthetic://custody'},
            'sampling': {'method': 'random', 'population': n, 'selected': n, 'missing': 0, 'evidence_ref': 'synthetic://sample'}}


def proposal(eid='e1'):
    return {'experiment_id': eid, 'claim_scope': 'synthetic_mechanics', 'hypothesis': 'synthetic gain', 'scope': 'fixture',
            'baseline': {'revision': 'b', 'hash': e.digest('b')}, 'candidate': {'revision': 'c', 'hash': e.digest('c')},
            'model': {'revision': 'synthetic-v1'}, 'workload': {'revision': 'w1'}, 'environment': {'revision': 'offline'},
            'budget_usd': 1, 'metric': {'revision': 'normalized-v1'},
            'cohorts': {'development': 'd', 'validation': 'v', 'acceptance': 'a'},
            'thresholds': {'min_units': 100, 'min_gain': .1, 'max_regression': 0, 'max_ci_width': .6, 'min_coverage': 1},
            'decision_card': {key: 'synthetic' for key in ('revision', 'primitive', 'features', 'state', 'dependencies', 'composition', 'alternatives', 'failure_boundaries', 'affordability')},
            'reconsideration': None}


class Experiments(unittest.TestCase):
    def setUp(self):
        self.s = e.new_state('registry', 'adapter')
    def call(self, op, p):
        old = copy.deepcopy(self.s)
        self.s, r = e.transition(self.s, op, p)
        self.assertEqual(old['events'], self.s['events'][:len(old['events'])])
        return r
    def setup_comparison(self, modify=None):
        for cid, split in [('d', 'development'), ('v', 'validation'), ('a', 'acceptance')]:
            c = cohort(cid, split)
            if modify and cid == 'a': modify(c)
            self.call('register-cohort', c)
        self.call('compare', proposal())
    def finish(self, baseline=0, candidate=1, cost=0, status='completed', measurements=None):
        self.call('final-acceptance', {'experiment_id': 'e1'})
        return self.call('complete', {'experiment_id': 'e1', 'status': status,
            'measurements': measurements if measurements is not None else [{'unit_id': f'a-{i}', 'baseline': baseline, 'candidate': candidate} for i in range(100)],
            'cost_usd': cost, 'evidence_ref': 'synthetic://measurements', 'guardrails_passed': True})
    def test_pure_unknown_and_tampered_state_fail_closed(self):
        original = copy.deepcopy(self.s)
        self.call('register-cohort', cohort('d', 'development'))
        self.assertEqual(original, e.new_state('registry', 'adapter'))
        for state in [dict(self.s, surprise=True), dict(self.s, active={'x': {'revision': 'x', 'hash': e.digest('x'), 'generation': 0}})]:
            with self.assertRaises(ValueError): e.transition(state, 'expose', {'cohort_id': 'd', 'reason': 'inspection', 'evidence_ref': 'x'})
        with self.assertRaises(ValueError): self.call('register-cohort', dict(cohort('a', 'acceptance'), surprise=True))
    def test_cross_pattern_and_transitive_lineage_cannot_reset_split(self):
        self.call('register-cohort', cohort('d', 'development', 1))
        c = cohort('a', 'acceptance', 1); c['pattern'] = 'other'; c['units'][0]['lineage'] = ['new', 'family-d-0']
        with self.assertRaises(ValueError): self.call('register-cohort', c)
    def test_exposure_and_unknown_custody_block_before_labels(self):
        self.setup_comparison()
        self.call('expose', {'cohort_id': 'a', 'reason': 'inspection', 'evidence_ref': 'audit'})
        with self.assertRaises(ValueError): self.call('final-acceptance', {'experiment_id': 'e1'})
    def test_consume_is_idempotent_and_frozen(self):
        self.setup_comparison(); r = self.call('final-acceptance', {'experiment_id': 'e1'})
        before = copy.deepcopy(self.s)
        self.assertEqual(r, self.call('final-acceptance', {'experiment_id': 'e1'})); self.assertEqual(before, self.s)
        self.assertEqual(self.s['experiments']['e1']['status'], 'evaluating')
        changed = proposal(); changed['candidate']['hash'] = e.digest('changed')
        with self.assertRaises(ValueError): self.call('compare', changed)
    def test_synthetic_promotion_and_rejection_use_numeric_evidence(self):
        self.setup_comparison(); self.finish()
        r = self.call('decide', {'experiment_id': 'e1'})
        self.assertEqual(r['decision'], 'promote'); self.assertEqual(r['claim_scope'], 'synthetic_mechanics')
        self.assertGreater(r['metrics']['ci_low'], .1)
        self.assertEqual(r, self.call('decide', {'experiment_id': 'e1'}))
    def test_regression_rejects(self):
        self.setup_comparison(); self.finish(1, 0)
        self.assertEqual(self.call('decide', {'experiment_id': 'e1'})['decision'], 'reject')
    def test_no_data_unknown_cost_and_biased_sampling_never_promote(self):
        for variant in ['empty', 'cost', 'biased', 'precision']:
            self.s = e.new_state('registry', 'adapter')
            self.setup_comparison((lambda c: c['sampling'].update(method='biased')) if variant == 'biased' else None)
            self.finish(cost=None if variant == 'cost' else 0, measurements=[] if variant == 'empty' else None, candidate=.2 if variant == 'precision' else 1)
            self.assertNotEqual(self.call('decide', {'experiment_id': 'e1'})['decision'], 'promote', variant)
    def test_failed_attempt_and_duplicate_preserve_consumption(self):
        self.setup_comparison(); self.finish(status='interrupted', measurements=[])
        r = self.call('compare', proposal('new-id'))
        self.assertEqual(r['experiment_id'], 'e1'); self.assertNotIn('new-id', self.s['experiments'])
        p = proposal('changed'); p['model']['revision'] = 'v2'; p['reconsideration'] = {'prior_experiment_id': 'e1', 'reason': 'changed model'}
        self.call('compare', p)
        with self.assertRaises(ValueError): self.call('final-acceptance', {'experiment_id': 'changed'})
    def test_duplicates_and_boolean_measurements_rejected(self):
        self.setup_comparison(); self.call('final-acceptance', {'experiment_id': 'e1'})
        for values in [[{'unit_id': 'a-0', 'baseline': 0, 'candidate': True}], [{'unit_id': 'a-0', 'baseline': 0, 'candidate': 1}]*2]:
            with self.assertRaises(ValueError): self.call('complete', {'experiment_id': 'e1', 'status': 'completed', 'measurements': values, 'cost_usd': 0, 'evidence_ref': 'fixture', 'guardrails_passed': True})
    def test_full_correction_loop_preserves_observation(self):
        self.call('record-run', {'run_id': 'r', 'status': 'failed', 'evidence_ref': 'synthetic://run', 'identity_hash': e.digest('identity'), 'cost_usd': None})
        correction = {'correction_id': 'c', 'run_id': 'r', 'source_ref': 'synthetic://source', 'source_revision': 'v1', 'source_span': '1:2', 'source_lineage': ['family-d-0'], 'attribution': 'fixture', 'interpretation': 'wrong result', 'origin': 'machine', 'verifier_ref': 'synthetic://verified', 'verified': True, 'supersedes': None}
        self.call('record-correction', correction)
        self.assertEqual(self.s['exposure_manifests']['correction:c']['lineage'], ['family-d-0'])
        old = copy.deepcopy(self.s); self.call('record-correction', correction); self.assertEqual(self.s, old)
        self.call('diagnose', {'diagnosis_id': 'dx', 'correction_id': 'c', 'classification': 'judgment', 'evidence_refs': ['synthetic://source'], 'alternatives': ['context'], 'verified': True})
        self.call('register-cohort', cohort('d', 'development', 1))
        self.call('register-cohort', cohort('unrelated', 'development', 1))
        with self.assertRaises(ValueError): self.call('add-regression', {'regression_id': 'wrong', 'diagnosis_id': 'dx', 'cohort_id': 'unrelated'})
        self.call('add-regression', {'regression_id': 'g', 'diagnosis_id': 'dx', 'cohort_id': 'd'})
        self.assertEqual(self.s['corrections']['c']['origin'], 'machine')
        with self.assertRaises(ValueError): self.call('record-correction', dict(correction, origin='human'))
    def test_imported_exposure_and_unknown_custody_are_ineligible(self):
        for variant in ('history', 'custody'):
            self.s = e.new_state('registry', 'adapter')
            self.setup_comparison((lambda c: c['custody'].update(verified=False)) if variant == 'custody' else None)
            if variant == 'history':
                manifest = {'manifest_id': 'legacy', 'lineage': ['family-a-0'], 'evidence_ref': 'synthetic://legacy'}
                self.call('import-exposure', manifest)
                old = copy.deepcopy(self.s); self.call('import-exposure', manifest); self.assertEqual(old, self.s)
                with self.assertRaises(ValueError): self.call('import-exposure', dict(manifest, lineage=['other']))
            with self.assertRaises(ValueError): self.call('final-acceptance', {'experiment_id': 'e1'})
    def test_same_split_repeats_do_not_inflate_independence(self):
        c = cohort('a', 'acceptance', 2); c['units'][1]['lineage'] = c['units'][0]['lineage']
        with self.assertRaises(ValueError): self.call('register-cohort', c)
        self.call('register-cohort', cohort('d', 'development', 1))
        c = cohort('d2', 'development', 1); c['units'][0]['lineage'] = ['family-d-0']
        with self.assertRaises(ValueError): self.call('register-cohort', c)
    def test_malformed_and_nonfinite_inputs_raise_value_error(self):
        for value in [None, [], 4, {'cohort_id': []}]:
            with self.assertRaises(ValueError): self.call('register-cohort', value)
        for value in [float('nan'), float('inf'), object(), {1: 'x'}]:
            with self.assertRaises(ValueError): e.digest(value)
        with self.assertRaises(ValueError): e.validate_state({'events': []})
        self.setup_comparison()
        p = proposal('bad'); p['cohorts']['acceptance'] = []
        with self.assertRaises(ValueError): self.call('compare', p)
    def test_completed_event_cannot_be_rewritten_or_fabricated(self):
        self.setup_comparison(); self.finish()
        bad = copy.deepcopy(self.s); bad['experiments']['e1']['completion']['cost_usd'] = -1
        with self.assertRaises(ValueError): e.validate_state(bad)
        bad = copy.deepcopy(self.s); bad['events'][-1]['receipt']['status'] = 'failed'
        with self.assertRaises(ValueError): e.validate_state(bad)
        with self.assertRaises(ValueError): self.finish(status='failed', measurements=[])
    def test_same_conditions_reconsideration_cannot_reset_attempt(self):
        self.setup_comparison(); self.finish(status='failed', measurements=[])
        p = proposal('retry'); p['reconsideration'] = {'prior_experiment_id': 'e1', 'reason': 'try again'}
        with self.assertRaises(ValueError): self.call('compare', p)
        changed = proposal('unexplained'); changed['model']['revision'] = 'v2'
        with self.assertRaises(ValueError): self.call('compare', changed)
        self.assertEqual(self.call('decide', {'experiment_id': 'e1'})['decision'], 'invalid')
    def test_field_claim_and_activation_without_decision_fail(self):
        for cid, split in [('d', 'development'), ('v', 'validation'), ('a', 'acceptance')]: self.call('register-cohort', cohort(cid, split))
        p = proposal(); p['claim_scope'] = 'field_quality'
        with self.assertRaises(ValueError): self.call('compare', p)
        self.call('compare', proposal())
        b = proposal()['baseline']; self.call('set-incumbent', dict(b, mode='test'))
        with self.assertRaises(ValueError): self.call('prepare-activation', {'activation_id': 'x', 'experiment_id': 'e1', 'mode': 'test', 'expected': dict(b, generation=0), 'authority_ref': 'fixture'})

    def test_late_exposure_invalidates_decision_and_pending_activation(self):
        for stage in ('before_decide', 'after_decide', 'prepared'):
            for exposure in ('cohort', 'import'):
                self.s = e.new_state('registry', 'adapter')
                self.setup_comparison(); self.finish()
                if stage != 'before_decide': self.call('decide', {'experiment_id': 'e1'})
                b = proposal()['baseline']; c = proposal()['candidate']
                self.call('set-incumbent', dict(b, mode='fixture'))
                p = {'activation_id': 'activate', 'experiment_id': 'e1', 'mode': 'fixture', 'expected': dict(b, generation=0), 'authority_ref': 'synthetic://authority'}
                if stage == 'prepared': self.call('prepare-activation', p)
                if exposure == 'cohort': self.call('expose', {'cohort_id': 'a', 'reason': 'inspection', 'evidence_ref': 'synthetic://inspection'})
                else: self.call('import-exposure', {'manifest_id': 'late', 'lineage': ['family-a-0'], 'evidence_ref': 'synthetic://history'})
                if stage == 'before_decide':
                    self.assertEqual(self.call('decide', {'experiment_id': 'e1'})['decision'], 'invalid')
                else:
                    with self.assertRaises(ValueError): self.call('decide', {'experiment_id': 'e1'})
                if stage == 'prepared':
                    with self.assertRaises(ValueError): self.call('prepare-activation', p)
                    with self.assertRaises(ValueError): self.call('finish-activation', {'activation_id': 'activate', 'observed': c})
                    self.assertEqual(self.s['active']['fixture'], dict(b, generation=0))
                else:
                    with self.assertRaises(ValueError): self.call('prepare-activation', p)

    def test_explicit_abort_restores_custody_and_blocks_aba(self):
        self.setup_comparison(); self.finish(); self.call('decide', {'experiment_id': 'e1'})
        b = proposal()['baseline']; c = proposal()['candidate']
        self.call('set-incumbent', dict(b, mode='fixture'))
        prepare = {'activation_id': 'activate', 'experiment_id': 'e1', 'mode': 'fixture', 'expected': dict(b, generation=0), 'authority_ref': 'synthetic://authority'}
        self.call('prepare-activation', prepare)
        self.call('import-exposure', {'manifest_id': 'late', 'lineage': ['family-a-0'], 'evidence_ref': 'synthetic://history'})
        with self.assertRaises(ValueError): self.call('finish-activation', {'activation_id': 'activate', 'observed': c})
        finish = {'activation_id': 'activate', 'observed': b}
        abort = {'activation_id': 'activate', 'authority_ref': 'synthetic://restore'}
        with self.assertRaises(ValueError): self.call('finish-abort', finish)
        with self.assertRaises(ValueError): self.call('prepare-abort', dict(abort, authority_ref=''))
        preparation = self.call('prepare-abort', abort)
        self.assertEqual(preparation['status'], 'aborting')
        old = copy.deepcopy(self.s)
        self.assertEqual(preparation, self.call('prepare-abort', abort)); self.assertEqual(old, self.s)
        with self.assertRaises(ValueError): self.call('prepare-activation', dict(prepare, activation_id='competitor'))
        with self.assertRaises(ValueError): self.call('finish-activation', {'activation_id': 'activate', 'observed': c})
        with self.assertRaises(ValueError): self.call('finish-abort', dict(finish, observed=c))
        receipt = self.call('finish-abort', finish)
        self.assertEqual(receipt['status'], 'aborted')
        self.assertEqual(receipt['rollback_ref'], b)
        self.assertEqual(self.s['active']['fixture'], dict(b, generation=2))
        old = copy.deepcopy(self.s)
        self.assertEqual(receipt, self.call('finish-abort', finish)); self.assertEqual(old, self.s)
        self.assertEqual(receipt, self.call('prepare-abort', abort)); self.assertEqual(old, self.s)
        with self.assertRaises(ValueError): self.call('prepare-abort', dict(abort, authority_ref='changed'))
        with self.assertRaises(ValueError): self.call('finish-activation', {'activation_id': 'activate', 'observed': c})
        with self.assertRaises(ValueError): self.call('prepare-activation', dict(prepare, activation_id='stale'))

    def test_activation_cas_rollback_and_aba(self):
        self.setup_comparison(); self.finish(); self.call('decide', {'experiment_id': 'e1'})
        b = proposal()['baseline']; c = proposal()['candidate']
        self.call('set-incumbent', dict(b, mode='fixture'))
        expected = dict(b, generation=0)
        p = {'activation_id': 'activate', 'experiment_id': 'e1', 'mode': 'fixture', 'expected': expected, 'authority_ref': 'synthetic://authority'}
        self.call('prepare-activation', p)
        with self.assertRaises(ValueError): self.call('prepare-activation', dict(p, activation_id='other'))
        with self.assertRaises(ValueError): self.call('finish-activation', {'activation_id': 'activate', 'observed': b})
        self.call('finish-activation', {'activation_id': 'activate', 'observed': c})
        self.call('prepare-rollback', {'activation_id': 'rollback', 'prior_activation_id': 'activate', 'mode': 'fixture', 'expected': dict(c, generation=1), 'authority_ref': 'synthetic://rollback'})
        self.call('finish-rollback', {'activation_id': 'rollback', 'observed': b})
        self.assertEqual(self.s['active']['fixture'], dict(b, generation=2))
        with self.assertRaises(ValueError): self.call('prepare-activation', dict(p, activation_id='stale'))
        self.assertEqual(self.s['pending']['activate']['rollback_ref'], b)

if __name__ == '__main__': unittest.main()
