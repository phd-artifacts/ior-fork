# Agent Notes: ior-fork (application/ior-fork)

This scope covers local IOR fork integration used by io-playground.

## Relevant files
- OMPFile backend adapter:
  - `src/aiori-ompfile.c`
- Local runner:
  - `run.sh`
- Fork docs:
  - `README_OMPFILE`

## Commit instructions
- Commit changes in this submodule first:
  - `cd /scratch/rodrigo.freitas/io-playground/application/ior-fork`
  - `git add ...`
  - `git commit -m "ior-fork: ..."`
- Then update the superproject pointer:
  - `cd /scratch/rodrigo.freitas/io-playground`
  - `git add application/ior-fork`
  - `git commit -m "chore(submodule): bump ior-fork"`
