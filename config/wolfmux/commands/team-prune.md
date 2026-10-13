---
description: Delete build output (node_modules, dist, caches) of parked lanes; asks first
argument-hint: [--dry-run] [--keep-node-modules]
allowed-tools: Bash(teamctl prune --dry-run *)
---

Arguments given: $ARGUMENTS

This can delete real files, so follow these steps in order and do not skip any of them.

1. If `$ARGUMENTS` already contains `--dry-run`: run `teamctl prune $ARGUMENTS` once with
   the Bash tool, show the full output verbatim, and stop. Nothing is deleted by
   `--dry-run`, so no confirmation is needed.
2. Otherwise, first run the dry run so the user can see what would go:

       teamctl prune --dry-run $ARGUMENTS

   Show that output in full.
3. Then ask the user in chat: "Delete this for real?" and wait for a clear yes.
4. Only after they say yes, run exactly this and show its output:

       teamctl prune $ARGUMENTS

If they do not say yes, stop after step 2 and do not run step 4.
