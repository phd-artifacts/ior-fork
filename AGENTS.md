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
- Commit message format must follow Rodrigo Ceccato style:
  - subject line: `docs: short message`
  - body: larger description with concrete implementation steps and justification.
  - preferred command form:
    - `git commit -m "docs: short message" -m "Step 1: ...\nStep 2: ...\n\nJustification: ..."`
- Commit changes in this submodule first:
  - `cd /scratch/rodrigo.freitas/io-playground/application/ior-fork`
  - `git add ...`
  - `git commit -m "docs: short message" -m "Step 1: ...\nStep 2: ...\n\nJustification: ..."`
- Then update the superproject pointer:
  - `cd /scratch/rodrigo.freitas/io-playground`
  - `git add application/ior-fork`
  - `git commit -m "docs: short message" -m "Step 1: ...\nStep 2: ...\n\nJustification: ..."`
