Implement the four helpers that docs/spec.md specifies (mul, div, mod, pow) in lib/calc.sh.

- docs/spec.md is the only source of truth: read it in full before you start, the special cases are in it.
- One function per commit, in the order of the document, each with its checks in tests/run.sh.
- Before every commit run `bash tests/run.sh` and read its complete output (do not cut it): a reviewer wants the
  full log of each step in your report file.
- Keep a short log of each step in NOTES.md (what you added, the last line of the suite) and commit it with the step.
- When all four are in: teamctl done, naming the test command and its result.
