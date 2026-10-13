---
description: Show the pane notices filed for a role — not Beads; tasks live in bd
argument-hint: [<role>] [--all] [--json] [--keep]
allowed-tools: Bash(teamctl *)
---

Run this with the Bash tool and show the full output verbatim. Do not interpret it
or run anything else. This is the pane-notice inbox, not a role's Beads work queue —
that is `bd list --assignee <role> --status open,in_progress,blocked --include-infra`.

    teamctl inbox $ARGUMENTS
