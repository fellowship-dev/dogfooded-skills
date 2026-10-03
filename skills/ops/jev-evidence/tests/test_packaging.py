"""Isolated install layouts, dependency tamper and upgrade acceptance."""
import json
import os
import py_compile
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

OPS = Path(__file__).resolve().parents[2]
PATTERNS = ('jev-label-and-act', 'jev-search-and-rerank')

class PackagingTests(unittest.TestCase):
    def run_check(self, root, pattern):
        return subprocess.run([sys.executable, str(root / pattern / 'scripts/check_contract.py'), 'version'],
                              capture_output=True, text=True)

    def load_wrapper(self, root, pattern):
        path = root / pattern / 'scripts/check_contract.py'
        spec = importlib.util.spec_from_file_location('checked_experiment_pattern', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_experiment_module_tamper_fails_closed_for_both_patterns(self):
        for pattern in PATTERNS:
            with self.subTest(pattern=pattern), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in (pattern, 'jev-evidence'):
                    shutil.copytree(OPS / name, root / name)
                source = root / 'jev-evidence/scripts/experiments.py'
                source.write_bytes(source.read_bytes() + b'\nCOMPANION_BYPASS=True\n')
                result = self.run_check(root, pattern)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('integrity', result.stderr)

    def test_experiments_execute_verified_bytes_despite_disk_swap_and_pyc(self):
        import unittest.mock as mock
        for pattern in PATTERNS:
            with self.subTest(pattern=pattern), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in (pattern, 'jev-evidence'):
                    shutil.copytree(OPS / name, root / name)
                source = root / 'jev-evidence/scripts/experiments.py'
                original = source.read_bytes()
                stamp = source.stat()
                malicious = b'COMPANION_BYPASS=True\n'
                source.write_bytes(malicious + b' ' * (len(original) - len(malicious)))
                os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                py_compile.compile(str(source), doraise=True)
                source.write_bytes(original)
                os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                wrapper = self.load_wrapper(root, pattern)
                loaded = wrapper.load_core()
                self.assertFalse(hasattr(loaded.experiments, 'COMPANION_BYPASS'))
                self.assertTrue(callable(loaded.experiments.transition))
                real_read_bytes = Path.read_bytes

                def swap_after_read(path):
                    payload = real_read_bytes(path)
                    if path.resolve() == source.resolve():
                        source.write_bytes(malicious)
                    return payload

                with mock.patch.object(Path, 'read_bytes', swap_after_read):
                    loaded = wrapper.load_core()
                self.assertEqual(source.read_bytes(), malicious)
                self.assertFalse(hasattr(loaded.experiments, 'COMPANION_BYPASS'))
                self.assertTrue(callable(loaded.experiments.transition))

    def test_cli_synthetic_transition_is_pure_for_both_patterns(self):
        for pattern in PATTERNS:
            with self.subTest(pattern=pattern), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in (pattern, 'jev-evidence'):
                    shutil.copytree(OPS / name, root / name)
                core = self.load_wrapper(root, pattern).load_core()
                state = core.experiments.new_state('synthetic-registry', 'synthetic-adapter')
                request = {'state': state, 'operation': 'set-incumbent',
                           'payload': {'mode': 'synthetic', 'revision': 'baseline', 'hash': 'a' * 64}}
                path = root / 'transition.json'
                original = json.dumps(request, sort_keys=True)
                path.write_text(original)
                before = set(root.rglob('*'))
                result = subprocess.run([sys.executable, str(root / pattern / 'scripts/check_contract.py'),
                                         'transition', str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                self.assertEqual(set(output), {'state', 'receipt'})
                self.assertEqual(output['state']['active']['synthetic']['revision'], 'baseline')
                self.assertEqual(output['state']['active']['synthetic']['hash'], 'a' * 64)
                self.assertEqual(state['active'], {})
                self.assertEqual(path.read_text(), original)
                self.assertEqual(set(root.rglob('*')), before)
                self.assertTrue(output['receipt'])

    def test_isolated_combined_and_upgrade(self):
        for selected in ((PATTERNS[0],), (PATTERNS[1],), PATTERNS):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in (*selected, 'jev-evidence'):
                    shutil.copytree(OPS / name, root / name)
                for name in selected:
                    p = self.run_check(root, name)
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertEqual(json.loads(p.stdout)['version'], '1.0.0')
                # A replaced companion must not be accepted by older consumers.
                manifest = root / 'jev-evidence/manifest.json'
                old = manifest.read_text()
                data = json.loads(old)
                data['version'] = '2.0.0'
                manifest.write_text(json.dumps(data))
                for name in selected:
                    p = self.run_check(root, name)
                    self.assertNotEqual(p.returncode, 0)
                    self.assertIn('compatible', p.stderr)
                manifest.write_text(old)
                self.assertEqual(self.run_check(root, selected[0]).returncode, 0)

    def test_unverified_cached_bytecode_is_never_loaded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in (PATTERNS[0], 'jev-evidence'):
                shutil.copytree(OPS / name, root / name)
            core = root / 'jev-evidence/scripts/contracts.py'
            payload = core.read_bytes()
            stamp = core.stat()
            malicious = b'COMPANION_BYPASS=True\n'
            core.write_bytes(malicious + b' ' * (len(payload) - len(malicious)))
            os.utime(core, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            py_compile.compile(str(core), doraise=True)
            core.write_bytes(payload)
            os.utime(core, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            wrapper = root / PATTERNS[0] / 'scripts/check_contract.py'
            spec = importlib.util.spec_from_file_location('checked_pattern', wrapper)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            loaded = module.load_core()
            self.assertFalse(hasattr(loaded, 'COMPANION_BYPASS'))
            self.assertTrue(callable(loaded.validate_bundle))

    def test_schema_load_uses_verified_bytes_not_a_later_disk_read(self):
        # D1 regression: load_core() must hand contracts.py the schema bytes it
        # already hashed, not let contracts.py re-read schemas/bundle-v1.json
        # from disk on its own. Prove it by swapping the on-disk schema for an
        # equally-well-formed-but-different one *after* hashing would occur but
        # before contracts.py's own SCHEMA assignment could otherwise run, then
        # asserting the loaded module validates against the ORIGINAL (verified)
        # schema, not the swapped file that is sitting on disk at exec time.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in (PATTERNS[0], 'jev-evidence'):
                shutil.copytree(OPS / name, root / name)
            wrapper = root / PATTERNS[0] / 'scripts/check_contract.py'
            spec = importlib.util.spec_from_file_location('checked_pattern_schema', wrapper)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)

            schema_path = root / 'jev-evidence/schemas/bundle-v1.json'
            original_schema = json.loads(schema_path.read_text())

            real_read_text = Path.read_text

            def swap_after_verification(self, *args, **kwargs):
                text = real_read_text(self, *args, **kwargs)
                if self == schema_path:
                    # Simulate a swap landing on disk strictly after load_core()
                    # would have hashed the original bytes: a permissive schema
                    # that would accept an otherwise-invalid bundle.
                    tampered = json.loads(text)
                    tampered['additionalProperties'] = True
                    return json.dumps(tampered)
                return text

            import unittest.mock as mock
            with mock.patch.object(Path, 'read_text', swap_after_verification):
                loaded = module.load_core()

            # The loaded module must validate against the schema whose bytes
            # were actually hash-verified, not the swapped copy on disk: an
            # unknown top-level field must still be rejected.
            self.assertEqual(loaded.SCHEMA, original_schema)
            # Build a minimal bundle plus one unexpected field; must still be
            # rejected by the verified (strict) schema even though the swapped
            # on-disk copy above would have permitted it.
            fixture_bundle = {
                'schema_version': '1', 'toolkit_version': '1.0.0',
                'identity': {}, 'policy': {}, 'attempts': [], 'evidence': [],
                'scores': {}, 'choices': [], 'unexpected_field': 'should be rejected',
            }
            with self.assertRaises(loaded.ContractError):
                loaded.validate_bundle(fixture_bundle)

    def test_missing_and_modified_core_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(OPS / PATTERNS[0], root / PATTERNS[0])
            p = self.run_check(root, PATTERNS[0])
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('install', p.stderr)
            shutil.copytree(OPS / 'jev-evidence', root / 'jev-evidence')
            core = root / 'jev-evidence/scripts/contracts.py'
            with core.open('a') as f:
                f.write('\n# unexpected drift\n')
            p = self.run_check(root, PATTERNS[0])
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('integrity', p.stderr)

if __name__ == '__main__':
    unittest.main()
