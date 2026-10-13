---
description: Snapshot of every team on this machine, across every project, right now
argument-hint: [--full] [--socket <path>]
allowed-tools: Bash(teamctl *)
---

Run this with the Bash tool and show the full output verbatim. Do not interpret it
or run anything else. `--once` prints one snapshot and exits — it does not redraw.

    teamctl dashboard --once $ARGUMENTS
