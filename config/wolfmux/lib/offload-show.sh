#!/bin/bash
# offload-show.sh <log> <exit-code> — run by a wrapped command's EXIT trap (lib/offload.sh): prints
# the result whole when short, shortened when long. Loads nothing but lib/offload.sh.
set -uo pipefail
. "$(dirname "$0")/offload.sh" || exit 1
offload_finish "${1:?log}" "${2:-}"
