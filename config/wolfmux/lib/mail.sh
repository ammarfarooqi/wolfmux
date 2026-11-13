#!/bin/bash
# mail.sh — (v1.13, being written) messages and tasks reach an agent through its hooks.
# The contract is the header of lib/hooks.sh.
cmd_deliver() { return 0; }
cmd_send() { die "teamctl send is not built yet"; }
cmd_inbox() { die "teamctl inbox is not built yet"; }
