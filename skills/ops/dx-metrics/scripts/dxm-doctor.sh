#!/usr/bin/env bash
# dxm-doctor.sh — preconditions and DB health, as CONTRACT.md §2 names it.
#
# The check itself lives in dxm-run.sh --doctor rather than here, because the
# orchestrator has to run exactly the same check before every pipeline anyway.
# Duplicating it would give us two definitions of "healthy" and, eventually,
# two different answers.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dxm-run.sh" --doctor "$@"
