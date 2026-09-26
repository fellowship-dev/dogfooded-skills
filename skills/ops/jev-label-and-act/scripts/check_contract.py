"""Load the single explicitly installed, byte-pinned evidence companion."""
import hashlib
import types
import json
import sys
from pathlib import Path


def load_core():
    skill = Path(__file__).resolve().parents[1]
    companion = skill.parent / 'jev-evidence'
    try:
        expected = json.loads((skill / 'references/evidence-dependency.json').read_text())
        manifest = json.loads((companion / 'manifest.json').read_text())
    except (OSError, ValueError) as error:
        raise ValueError('jev-evidence unavailable: install the companion and this pattern from the same pinned revision') from error
    if manifest.get('version') != expected['version']:
        raise ValueError('jev-evidence is not compatible: install companion and pattern from the same pinned revision')
    encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
    if hashlib.sha256(encoded).hexdigest() != expected['manifest_sha256']:
        raise ValueError('jev-evidence integrity mismatch: reinstall compatible companion and pattern')
    verified = {}
    for relative, expected_hash in manifest['files'].items():
        path = companion / relative
        if not path.resolve().is_relative_to(companion.resolve()):
            raise ValueError('jev-evidence integrity: escaping dependency path')
        try:
            payload = path.read_bytes()
            actual = hashlib.sha256(payload).hexdigest()
        except OSError as error:
            raise ValueError('jev-evidence integrity: missing file; reinstall compatible companion') from error
        if actual != expected_hash:
            raise ValueError('jev-evidence integrity mismatch: reinstall compatible companion')
        verified[relative] = payload
    # Execute verified source bytes, never an unverified timestamp-based pyc.
    module = types.ModuleType('jev_evidence_contracts')
    module.__file__ = str(companion / 'scripts/contracts.py')
    # Hand contracts.py the already-verified schema bytes so its SCHEMA load
    # consumes exactly what was hashed above, closing the TOCTOU window a
    # second, independent disk read of schemas/bundle-v1.json would reopen.
    module._VERIFIED_SCHEMA_JSON = verified['schemas/bundle-v1.json']
    exec(compile(verified['scripts/contracts.py'], module.__file__, 'exec'), module.__dict__)
    module._verified_cli = verified['scripts/cli.py']
    return module


def main():
    try:
        core = load_core()
        companion = Path(__file__).resolve().parents[2] / 'jev-evidence'
        cli = types.ModuleType('jev_evidence_cli')
        cli.__file__ = str(companion / 'scripts/cli.py')
        exec(compile(core._verified_cli, cli.__file__, 'exec'), cli.__dict__)
        return cli.main(core=core)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
