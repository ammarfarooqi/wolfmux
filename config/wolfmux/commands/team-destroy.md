---
description: End a team and delete everything it holds — session, worktrees, branches, records
argument-hint: <team>
allowed-tools: Bash(teamctl teams *)
---

Team to destroy: $1

This deletes real work. Follow these steps in order.

1. If `$1` is empty, say so and stop.
2. Run `teamctl teams` with the Bash tool and show the output, so the user can see
   what this team currently holds (agents, disk, founder).
3. Ask the user in chat to confirm: say plainly that destroying "$1" ends its
   session and deletes every worktree, the branches teamctl created for it, its
   records and its teammates' Claude Code transcripts. Wait for a clear yes.
4. Only after they say yes, run exactly this and show its output:

       teamctl destroy --team $1 --purge --yes

If they do not give a clear yes, stop after step 3 and do not run step 4.
