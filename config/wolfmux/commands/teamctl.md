---
description: Run any teamctl command and show its output
argument-hint: <command> [args...]
allowed-tools: Bash(teamctl *)
---

Run this with the Bash tool, then show the full output to the user exactly as it
came back. Do not interpret it, do not retry it, and do not run anything else
afterwards — not even to "double check" the result.

    teamctl $ARGUMENTS
