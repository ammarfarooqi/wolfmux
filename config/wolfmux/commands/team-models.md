---
description: What fable, opus, sonnet and haiku mean today, and which running agents are on an older model
argument-hint: [--json] [--refresh]
allowed-tools: Bash(teamctl *)
---

Run this with the Bash tool and show the full output verbatim. Do not interpret it
or run anything else. Without `--refresh` it reads only what is cached and makes no
model call; `--refresh` asks Claude Code once per alias (a tiny call on the subscription).
Nothing is restarted: the output names the `teamctl restart` that would move an agent.

    teamctl models $ARGUMENTS
