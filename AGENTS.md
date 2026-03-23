# Agent Notes: ior-fork (application/ior-fork)

This scope covers local IOR fork integration used by io-playground.

## Scope intent
- Keep this file focused on IOR-fork code and runtime behavior.
- Shared commit workflow, submodule hygiene, and MkDocs maintenance are canonical in root `AGENTS.md`.

## Relevant files
- OMPFile backend adapter:
  - `src/aiori-ompfile.c`
- Local runner:
  - `run.sh`
- Fork docs:
  - `README_OMPFILE`

## Scope-specific behavior
- Keep IOR adapter semantics aligned with libompfile MPP mode expectations.
- When this fork changes runtime behavior used in cluster decisions, capture observed deltas in docs via the root MkDocs policy.

## Skills entrypoints
- `skills/submodule-commit-flow/SKILL.md`
- `skills/mkdocs-sync/SKILL.md`
