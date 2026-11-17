#!/bin/bash
# rotate-self-run.sh <scratch-dir> - one real-CLI measurement of a worker rotating ITSELF (ADR-0039, A3):
# its task tells it to run `teamctl rotate w1` after its second commit. The rotate and warn thresholds are
# off, so nothing else rotates it. Everything else, and what it prints, as rotate-auto-run.sh.
set -u
ROT_MODE=self exec "$(cd "$(dirname "$0")" && pwd -P)/rotate-auto-run.sh" "$@"
