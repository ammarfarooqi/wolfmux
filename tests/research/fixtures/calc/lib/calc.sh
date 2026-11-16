#!/bin/bash
# calc.sh: tiny integer helpers.
add() { printf '%s\n' "$(($1 + $2))"; }
sub() { printf '%s\n' "$(($1 - $2))"; }
