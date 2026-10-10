"""Offline evidence operations. No source, provider, or store access."""
import argparse
import json
import sys
from pathlib import Path


def main(argv=None, *, core=None):
    if core is None:
        import contracts as core
        import experiments
        core.experiments = experiments
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('version', 'validate', 'portable', 'replay', 'transition'))
    parser.add_argument('bundle', nargs='?', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.operation == 'version':
            result = {'version': '1.0.0', 'schema_version': '1'}
        else:
            if args.bundle is None:
                parser.error('bundle path is required; no implicit private store')
            bundle = json.loads(args.bundle.read_text())
            if args.operation == 'transition':
                if not isinstance(bundle, dict) or set(bundle) != {'state', 'operation', 'payload'}:
                    raise ValueError('invalid transition request')
                state, receipt = core.experiments.transition(bundle['state'], bundle['operation'], bundle['payload'])
                result = {'state': state, 'receipt': receipt}
            else:
                report = core.validate_bundle(bundle)
            if args.operation == 'validate':
                result = report
            elif args.operation == 'portable':
                result = core.portable_bundle(bundle)
            elif args.operation == 'replay':
                result = {'score': core.replay(bundle['scores'], bundle['policy']['weights']),
                          'replay_key': core.replay_key(bundle['identity'], bundle['policy'], bundle['scores'], bundle['attempts']),
                          'inference_calls': 0, 'limitations': report['limitations']}
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        # Do not echo input records or validation values into a public log.
        print('Evidence contract rejected: ' + type(error).__name__ + '; inspect the input privately', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
