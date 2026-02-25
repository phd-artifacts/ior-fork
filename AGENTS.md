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
  - subject line: `[scope]: short message`
  - scope describes the implementation change, not the subfolder name.
  - preferred scopes in this area: `ior`, `tests`, `runtime`, `docs`.
  - use `[docs]:` only for docs-only commits.
  - body: concise bullet list with what changed and why.
  - do not use `Step 1:`, `Step 2:` style.
  - preferred command form:
    - `git commit -m "[ior]: short message" -m "- bullet 1\n- bullet 2\n\nWhy:\n- ..."`
- Commit changes in this submodule first:
  - `cd /scratch/rodrigo.freitas/io-playground/application/ior-fork`
  - `git add ...`
  - `git commit -m "[ior]: short message" -m "- bullet 1\n- bullet 2\n\nWhy:\n- ..."`
- Then update the superproject pointer:
  - `cd /scratch/rodrigo.freitas/io-playground`
  - `git add application/ior-fork`
  - `git commit -m "[runtime]: short message" -m "- bullet 1\n- bullet 2\n\nWhy:\n- ..."`

## MkDocs sync requirements
- Any IOR integration behavior change should update MkDocs roadmap/status notes when relevant.
- Document observed sorgan behavior changes (speedups/slowdowns, limits) when IOR results are used for decisions.
