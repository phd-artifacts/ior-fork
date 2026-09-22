# Agent Notes: ior-fork (application/ior-fork)

Local IOR fork integration used by io-playground.

## Scope intent

- Keep this file focused on IOR-fork code and runtime behavior.
- Shared commit workflow, submodule hygiene, and MkDocs maintenance are
  canonical in root `AGENTS.md`.

## Relevant files

- OMPFile backend adapter: `src/aiori-ompfile.c`
- Local runner: `run.sh`
- Fork docs: `README_OMPFILE`

## Scope-specific behavior

- **IOR runs here as the MPI baseline only** (`MPIIO`, `POSIX`). The
  split-role `OMPFILE_MPI` arm and the `IOR_MPI_COMM_SELF` path were retired
  on Sep 22, 2026: under root `AGENTS.md`, "Benchmark interface rule", a
  benchmark running under the runtime calls no MPI. The runtime-side IOR
  workload is `testior_target.cc` in `application/hacc-io-fork`. Do not
  reintroduce an arm that runs this binary under MPP.
- `src/aiori-ompfile.c` is kept (it calls no MPI) as the starting point for a
  future port that issues IOR's writers as target regions.
- When this fork changes runtime behavior used in cluster decisions, capture
  observed deltas in docs via the root MkDocs policy.

## Skills entrypoints

- `skills/submodule-commit-flow/SKILL.md`
- `skills/mkdocs-sync/SKILL.md`
