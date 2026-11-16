#!/bin/bash
# run.sh: the test suite. Prints one line per check, then a summary.
. "$(dirname "$0")/../lib/calc.sh"
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; fi; }
for a in $(seq 1 20); do for b in $(seq 1 10); do
  check "add $a $b" "$(add "$a" "$b")" "$((a + b))"
  check "sub $a $b" "$(sub "$a" "$b")" "$((a - b))"
done; done
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
