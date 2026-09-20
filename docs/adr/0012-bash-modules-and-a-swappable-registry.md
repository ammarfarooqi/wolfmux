# ADR-0012: Bash 3.2 modules and a registry behind one interface

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The orchestrator must not require Node, Docker or a service, and macOS ships bash 3.2.
The owner's conventions ask for small files and no mutation-heavy sprawl. The brief
asked that state be replaceable later without changing commands.

## Decision

`teamctl` is a dispatcher plus nine small modules (largest about 460 lines), written for
`/bin/bash` 3.2 under `set -euo pipefail`, depending on `tmux`, `git` and `jq`. All
state access goes through `reg_*` / `meta_*` functions in `registry.sh`; all tmux calls
through `tmuxctl.sh`; the model table is one function.

## Alternatives Considered

### Alternative 1: Python
- **Pros**: easier data handling and tests
- **Cons**: interpreter and version questions; heavier than the job
- **Why not**: bash plus jq is enough

### Alternative 2: One large script
- **Pros**: single file to copy
- **Cons**: over a thousand lines; hard to review
- **Why not**: against the owner's file-size rules

## Consequences

### Positive
- runs on a stock Mac
- each concern reviewable on its own
- swapping the registry backend touches one file

### Negative
- bash 3.2 pitfalls are real: subshell variable scope, `pipefail` with `grep`, whitespace `IFS` collapsing empty fields, empty arrays under `set -u` — each one bit during the build

### Risks
- regressions in shell edge cases — `tests/smoke.sh` runs the whole lifecycle in about a minute
