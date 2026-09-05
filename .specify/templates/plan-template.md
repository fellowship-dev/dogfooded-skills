# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]
**Input**: `/specs/[###-feature-name]/spec.md`

## Summary

[Primary requirement + technical approach from research.]

## Technical Context

- **Language/Version**: [e.g., Python 3.11] · or `NEEDS CLARIFICATION`
- **Primary Dependencies**: [e.g., FastAPI]
- **Storage**: [e.g., PostgreSQL, N/A]
- **Testing**: [e.g., pytest]
- **Target Platform**: [e.g., Linux server]
- **Project Type**: [library / cli / web-service / mobile-app / desktop-app]
- **Performance Goals**: [e.g., 1000 req/s p95 < 200ms]
- **Constraints**: [e.g., <100MB memory, offline-capable]
- **Scale/Scope**: [e.g., 10k users, 1M LOC]

## Constitution Check

Gates derived from `.specify/memory/constitution.md`. MUST pass before Phase 0 and re-pass after Phase 1 design.

## Project Structure

```text
specs/[###-feature]/
├── plan.md         # this file (__SPECKIT_COMMAND_PLAN__ output)
├── research.md     # Phase 0
├── data-model.md   # Phase 1
├── quickstart.md   # Phase 1
├── contracts/      # Phase 1
└── tasks.md        # Phase 2 (created by __SPECKIT_COMMAND_TASKS__)
```

Source layout — pick one, delete the rest, populate with real paths:

```text
# Single project
src/{models,services,cli,lib}/   tests/{contract,integration,unit}/

# Web app
backend/src/{models,services,api}/   backend/tests/
frontend/src/{components,pages,services}/   frontend/tests/

# Mobile + API
api/{same as backend}
ios/ or android/{feature modules, UI flows, platform tests}
```

**Structure Decision**: [chosen layout + real paths]

## Complexity Tracking

*Fill ONLY if Constitution Check has violations needing justification.*

| Violation | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
