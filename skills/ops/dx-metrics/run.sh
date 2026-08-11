#!/usr/bin/env bash
# run.sh — convenience entry point. The orchestrator itself is scripts/dxm-run.sh,
# where CONTRACT.md §2 puts it and where every other dxm-* script lives.
# This exists so `bash run.sh --org acme` works from the skill root.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/dxm-run.sh" "$@"
