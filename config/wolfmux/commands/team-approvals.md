---
description: List workers' pending permission requests (worker-permissions=lead)
argument-hint: [--all]
allowed-tools: Bash(teamctl *)
---

Run this with the Bash tool and show the full output verbatim. Do not interpret it
or run anything else. To act on one: `teamctl approve <id>` or `teamctl deny <id> "<reason>"`.

    teamctl approvals $ARGUMENTS
