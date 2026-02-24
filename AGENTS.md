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
  - body: concise bullet list with what changed and why.
  - do not use `Step 1:`, `Step 2:` style.
  - preferred command form:
    - `git commit -m "docs: short message" -m "- updated docs with libompfile+MPP suite job\n- add info on how to read logs from test job\n- documented local test\n\nWhy:\n- keeps the workflow reproducible on sorgan."`
- Commit changes in this submodule first:
  - `cd /scratch/rodrigo.freitas/io-playground/application/ior-fork`
  - `git add ...`
  - `git commit -m "docs: short message" -m "- bullet 1\n- bullet 2\n\nWhy:\n- ..."`
- Then update the superproject pointer:
  - `cd /scratch/rodrigo.freitas/io-playground`
  - `git add application/ior-fork`
  - `git commit -m "docs: short message" -m "- bullet 1\n- bullet 2\n\nWhy:\n- ..."`
