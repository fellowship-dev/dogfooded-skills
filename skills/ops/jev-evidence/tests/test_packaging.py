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
