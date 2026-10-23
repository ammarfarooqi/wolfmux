# Boot checklist (hand-written; at most 2,000 bytes)

1. `bin/mem boot`: read the card it prints (role, oldest asks, crons, machine, newest decisions).
2. Re-create every enabled cron in state/crons.json, with its prompt file.
3. List the Beads inboxes and close what is read.
4. Open the 5 oldest asks on the card; chase whoever is waited on.
5. `bin/mem recall <words>` before you answer from memory.
6. Record the owner's words with `bin/mem decide`, every send with `bin/mem sent`.
7. `bin/mem check` at the end of each sweep; fix what it prints.
