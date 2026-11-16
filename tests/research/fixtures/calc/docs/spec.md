# calc: specification of the helpers

This document is the only source of truth for the behaviour of lib/calc.sh. Read the section of a function before implementing it.

## General rules

- The helpers are sourced by other scripts, so a function must never call `exit`; it returns a status instead.
- All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because its handling of a leading dash differs between shells.
- Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and nothing should be added to validate it in this step.
- Every function is one line when it has no special case, and at most six lines when it has one. Longer bodies were rejected in review twice.
- The suite prints one line per check on purpose: a reviewer reads the log of a failed run top to bottom and wants to see which pair of numbers broke.
- Each function is added in its own commit, with its own checks, in the order of this document. A commit that adds two functions is sent back.
- The commit message is `feat: add <name> to calc` and nothing else on the first line.

## 1. mul: multiplication

### Background

(mul, note 1) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, note 2) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted.

(mul, note 3) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. An earlier draft of this section proposed floating point results. It was
dropped after the billing scripts that source calc.sh were found to compare results as strings.

(mul, note 4) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, note 5) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Performance
was measured once, on the reporting job that calls these helpers about forty thousand times per run. The
subshell in the test harness dominated; the helper itself was not measurable. No optimisation is wanted.

(mul, note 6) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. An earlier draft of this section
proposed floating point results. It was dropped after the billing scripts that source calc.sh were found to
compare results as strings.

(mul, note 7) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, note 8) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted.

(mul, note 9) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. An earlier draft of this section proposed floating point results. It was
dropped after the billing scripts that source calc.sh were found to compare results as strings.


(mul, earlier note 1) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, earlier note 2) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted.

(mul, earlier note 3) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. An earlier draft of this section proposed floating point results. It was
dropped after the billing scripts that source calc.sh were found to compare results as strings.

(mul, earlier note 4) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, earlier note 5) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Performance
was measured once, on the reporting job that calls these helpers about forty thousand times per run. The
subshell in the test harness dominated; the helper itself was not measurable. No optimisation is wanted.

(mul, earlier note 6) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. An earlier draft of this section
proposed floating point results. It was dropped after the billing scripts that source calc.sh were found to
compare results as strings.

(mul, earlier note 7) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. A contributor asked whether the helper should accept more than two arguments. The
answer recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mul, earlier note 8) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted.

(mul, earlier note 9) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. An earlier draft of this section proposed floating point results. It was
dropped after the billing scripts that source calc.sh were found to compare results as strings.

### Behaviour (normative)

`mul A B` prints the product. No special cases.

### Checks to add to tests/run.sh

Add `mul` to the existing loop over a and b (20 x 10 pairs) and, where the behaviour above names a special case, one extra check per special case after the loop (status and stderr text).

### Review notes

(mul, review 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because its
handling of a leading dash differs between shells.

(mul, review 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Arguments are assumed to be integers that fit in 64 bits. Nothing validates
that, and nothing should be added to validate it in this step.

(mul, review 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Every function is one line when it has no special case, and at most six lines when it
has one. Longer bodies were rejected in review twice.

(mul, review 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The suite
prints one line per check on purpose: a reviewer reads the log of a failed run top to bottom and wants to see
which pair of numbers broke.

(mul, review 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Each function is added in its
own commit, with its own checks, in the order of this document. A commit that adds two functions is sent back.

(mul, review 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(mul, review 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The helpers are sourced by other scripts, so a function must never call `exit`; it
returns a status instead.

(mul, review 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/
because its handling of a leading dash differs between shells.

(mul, review 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

(mul, second review 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because its
handling of a leading dash differs between shells.

(mul, second review 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Arguments are assumed to be integers that fit in 64 bits. Nothing validates
that, and nothing should be added to validate it in this step.

(mul, second review 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Every function is one line when it has no special case, and at most six lines when it
has one. Longer bodies were rejected in second review twice.

(mul, second review 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The suite
prints one line per check on purpose: a reviewer reads the log of a failed run top to bottom and wants to see
which pair of numbers broke.

(mul, second review 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Each function is added in its
own commit, with its own checks, in the order of this document. A commit that adds two functions is sent back.

(mul, second review 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(mul, second review 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The helpers are sourced by other scripts, so a function must never call `exit`; it
returns a status instead.

(mul, second review 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/
because its handling of a leading dash differs between shells.

(mul, second review 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

## 2. div: integer division

### Background

(div, note 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so
nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why
the header comment still mentions it.

(div, note 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. There was a proposal to print errors on stdout with a prefix. It was
rejected because three callers capture stdout with command substitution and would have treated the message as
a number.

(div, note 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.

(div, note 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The team
discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but
two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still
mentions it.

(div, note 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. There was a proposal to print
errors on stdout with a prefix. It was rejected because three callers capture stdout with command substitution
and would have treated the message as a number.

(div, note 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.

(div, note 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so
nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why
the header comment still mentions it.

(div, note 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. There was a proposal to print errors on stdout with a prefix. It was
rejected because three callers capture stdout with command substitution and would have treated the message as
a number.

(div, note 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.


(div, earlier note 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so
nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why
the header comment still mentions it.

(div, earlier note 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. There was a proposal to print errors on stdout with a prefix. It was
rejected because three callers capture stdout with command substitution and would have treated the message as
a number.

(div, earlier note 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.

(div, earlier note 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The team
discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but
two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still
mentions it.

(div, earlier note 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. There was a proposal to print
errors on stdout with a prefix. It was rejected because three callers capture stdout with command substitution
and would have treated the message as a number.

(div, earlier note 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.

(div, earlier note 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so
nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why
the header comment still mentions it.

(div, earlier note 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. There was a proposal to print errors on stdout with a prefix. It was
rejected because three callers capture stdout with command substitution and would have treated the message as
a number.

(div, earlier note 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The first implementation of this helper shelled out to `bc`. On the build machines
`bc` is not installed, and the fallback path was never exercised by a test, which is how the regression of
March went unnoticed for nine days.

### Behaviour (normative)

`div A B` prints the quotient truncated toward zero. If B is 0 it prints nothing to stdout, prints exactly `error: division by zero` to stderr and returns status 2.

### Checks to add to tests/run.sh

Add `div` to the existing loop over a and b (20 x 10 pairs) and, where the behaviour above names a special case, one extra check per special case after the loop (status and stderr text).

### Review notes

(div, review 1) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

(div, review 2) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Every
function is one line when it has no special case, and at most six lines when it has one. Longer bodies were
rejected in review twice.

(div, review 3) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The suite prints one line per
check on purpose: a reviewer reads the log of a failed run top to bottom and wants to see which pair of
numbers broke.

(div, review 4) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.

(div, review 5) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(div, review 6) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The helpers are sourced by other scripts, so a function must never call
`exit`; it returns a status instead.

(div, review 7) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because
its handling of a leading dash differs between shells.

(div, review 8) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Arguments are
assumed to be integers that fit in 64 bits. Nothing validates that, and nothing should be added to validate it
in this step.

(div, review 9) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Every function is one line when
it has no special case, and at most six lines when it has one. Longer bodies were rejected in review twice.

(div, second review 1) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

(div, second review 2) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Every
function is one line when it has no special case, and at most six lines when it has one. Longer bodies were
rejected in second review twice.

(div, second review 3) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The suite prints one line per
check on purpose: a reviewer reads the log of a failed run top to bottom and wants to see which pair of
numbers broke.

(div, second review 4) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.

(div, second review 5) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(div, second review 6) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The helpers are sourced by other scripts, so a function must never call
`exit`; it returns a status instead.

(div, second review 7) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. All output goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because
its handling of a leading dash differs between shells.

(div, second review 8) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. Arguments are
assumed to be integers that fit in 64 bits. Nothing validates that, and nothing should be added to validate it
in this step.

(div, second review 9) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Every function is one line when
it has no special case, and at most six lines when it has one. Longer bodies were rejected in second review twice.

## 3. mod: remainder

### Background

(mod, note 1) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Performance was measured once, on the reporting job that calls these helpers
about forty thousand times per run. The subshell in the test harness dominated; the helper itself was not
measurable. No optimisation is wanted.

(mod, note 2) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. An earlier draft of this section proposed floating point results. It was dropped after
the billing scripts that source calc.sh were found to compare results as strings.

(mod, note 3) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. A contributor
asked whether the helper should accept more than two arguments. The answer recorded in the review was no:
callers that need a fold write the loop themselves, and the helper stays trivially auditable.

(mod, note 4) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Performance was measured once,
on the reporting job that calls these helpers about forty thousand times per run. The subshell in the test
harness dominated; the helper itself was not measurable. No optimisation is wanted.

(mod, note 5) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. An earlier draft of this section proposed floating point results. It was dropped
after the billing scripts that source calc.sh were found to compare results as strings.

(mod, note 6) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mod, note 7) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Performance was measured once, on the reporting job that calls these helpers
about forty thousand times per run. The subshell in the test harness dominated; the helper itself was not
measurable. No optimisation is wanted.

(mod, note 8) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. An earlier draft of this section proposed floating point results. It was dropped after
the billing scripts that source calc.sh were found to compare results as strings.

(mod, note 9) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. A contributor
asked whether the helper should accept more than two arguments. The answer recorded in the review was no:
callers that need a fold write the loop themselves, and the helper stays trivially auditable.


(mod, earlier note 1) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Performance was measured once, on the reporting job that calls these helpers
about forty thousand times per run. The subshell in the test harness dominated; the helper itself was not
measurable. No optimisation is wanted.

(mod, earlier note 2) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. An earlier draft of this section proposed floating point results. It was dropped after
the billing scripts that source calc.sh were found to compare results as strings.

(mod, earlier note 3) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. A contributor
asked whether the helper should accept more than two arguments. The answer recorded in the review was no:
callers that need a fold write the loop themselves, and the helper stays trivially auditable.

(mod, earlier note 4) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Performance was measured once,
on the reporting job that calls these helpers about forty thousand times per run. The subshell in the test
harness dominated; the helper itself was not measurable. No optimisation is wanted.

(mod, earlier note 5) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. An earlier draft of this section proposed floating point results. It was dropped
after the billing scripts that source calc.sh were found to compare results as strings.

(mod, earlier note 6) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable.

(mod, earlier note 7) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Performance was measured once, on the reporting job that calls these helpers
about forty thousand times per run. The subshell in the test harness dominated; the helper itself was not
measurable. No optimisation is wanted.

(mod, earlier note 8) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. An earlier draft of this section proposed floating point results. It was dropped after
the billing scripts that source calc.sh were found to compare results as strings.

(mod, earlier note 9) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. A contributor
asked whether the helper should accept more than two arguments. The answer recorded in the review was no:
callers that need a fold write the loop themselves, and the helper stays trivially auditable.

### Behaviour (normative)

`mod A B` prints the remainder, and the result ALWAYS has the sign of the divisor B (so `mod -7 3` prints 2 and `mod 7 -3` prints -2). If B is 0: stderr `error: modulo by zero`, status 2.

### Checks to add to tests/run.sh

Add `mod` to the existing loop over a and b (20 x 10 pairs) and, where the behaviour above names a special case, one extra check per special case after the loop (status and stderr text).

### Review notes

(mod, review 1) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Every function is one line when
it has no special case, and at most six lines when it has one. Longer bodies were rejected in review twice.

(mod, review 2) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The suite prints one line per check on purpose: a reviewer reads the log of a failed
run top to bottom and wants to see which pair of numbers broke.

(mod, review 3) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.

(mod, review 4) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The commit message is `feat: add <name> to calc` and nothing else on the
first line.

(mod, review 5) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The helpers are sourced by other scripts, so a function must never call `exit`; it
returns a status instead.

(mod, review 6) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. All output
goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because its handling of a leading dash
differs between shells.

(mod, review 7) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Arguments are assumed to be
integers that fit in 64 bits. Nothing validates that, and nothing should be added to validate it in this step.

(mod, review 8) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Every function is one line when it has no special case, and at most six lines when it
has one. Longer bodies were rejected in review twice.

(mod, review 9) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The suite prints one line per check on purpose: a reviewer reads the log of a failed run
top to bottom and wants to see which pair of numbers broke.

(mod, second review 1) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Every function is one line when
it has no special case, and at most six lines when it has one. Longer bodies were rejected in second review twice.

(mod, second review 2) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. The suite prints one line per check on purpose: a reviewer reads the log of a failed
run top to bottom and wants to see which pair of numbers broke.

(mod, second review 3) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.

(mod, second review 4) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The commit message is `feat: add <name> to calc` and nothing else on the
first line.

(mod, second review 5) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The helpers are sourced by other scripts, so a function must never call `exit`; it
returns a status instead.

(mod, second review 6) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. All output
goes through `printf '%s\n'`; `echo` is not used anywhere in lib/ because its handling of a leading dash
differs between shells.

(mod, second review 7) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. Arguments are assumed to be
integers that fit in 64 bits. Nothing validates that, and nothing should be added to validate it in this step.

(mod, second review 8) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Every function is one line when it has no special case, and at most six lines when it
has one. Longer bodies were rejected in second review twice.

(mod, second review 9) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The suite prints one line per check on purpose: a reviewer reads the log of a failed run
top to bottom and wants to see which pair of numbers broke.

## 4. pow: exponentiation

### Background

(pow, note 1) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, note 2) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The first
implementation of this helper shelled out to `bc`. On the build machines `bc` is not installed, and the
fallback path was never exercised by a test, which is how the regression of March went unnoticed for nine
days.

(pow, note 3) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The team discussed locale
handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but two downstream
scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still mentions it.

(pow, note 4) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, note 5) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The first implementation of this helper shelled out to `bc`. On the build machines `bc`
is not installed, and the fallback path was never exercised by a test, which is how the regression of March
went unnoticed for nine days.

(pow, note 6) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The team discussed locale handling at length. Bash arithmetic ignores
LC_NUMERIC, so nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh
and that is why the header comment still mentions it.

(pow, note 7) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, note 8) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The first
implementation of this helper shelled out to `bc`. On the build machines `bc` is not installed, and the
fallback path was never exercised by a test, which is how the regression of March went unnoticed for nine
days.

(pow, note 9) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The team discussed locale
handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but two downstream
scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still mentions it.


(pow, earlier note 1) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, earlier note 2) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The first
implementation of this helper shelled out to `bc`. On the build machines `bc` is not installed, and the
fallback path was never exercised by a test, which is how the regression of March went unnoticed for nine
days.

(pow, earlier note 3) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The team discussed locale
handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but two downstream
scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still mentions it.

(pow, earlier note 4) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, earlier note 5) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The first implementation of this helper shelled out to `bc`. On the build machines `bc`
is not installed, and the fallback path was never exercised by a test, which is how the regression of March
went unnoticed for nine days.

(pow, earlier note 6) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The team discussed locale handling at length. Bash arithmetic ignores
LC_NUMERIC, so nothing here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh
and that is why the header comment still mentions it.

(pow, earlier note 7) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. There was a proposal to print errors on stdout with a prefix. It was rejected because
three callers capture stdout with command substitution and would have treated the message as a number.

(pow, earlier note 8) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The first
implementation of this helper shelled out to `bc`. On the build machines `bc` is not installed, and the
fallback path was never exercised by a test, which is how the regression of March went unnoticed for nine
days.

(pow, earlier note 9) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. The team discussed locale
handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing here depends on it, but two downstream
scripts export LC_ALL=C before sourcing calc.sh and that is why the header comment still mentions it.

### Behaviour (normative)

`pow A B` prints A to the power B using a loop, not `**`. A negative exponent prints nothing to stdout, prints exactly `error: negative exponent` to stderr and returns status 3. `pow 0 0` prints 1.

### Checks to add to tests/run.sh

Add `pow` to the existing loop over a and b (20 x 10 pairs) and, where the behaviour above names a special case, one extra check per special case after the loop (status and stderr text).

### Review notes

(pow, review 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The suite prints one line per check on purpose: a reviewer reads the log of a failed run
top to bottom and wants to see which pair of numbers broke.

(pow, review 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Each function is added in its own commit, with its own checks, in the order
of this document. A commit that adds two functions is sent back.

(pow, review 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(pow, review 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The helpers
are sourced by other scripts, so a function must never call `exit`; it returns a status instead.

(pow, review 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. All output goes through `printf
'%s\n'`; `echo` is not used anywhere in lib/ because its handling of a leading dash differs between shells.

(pow, review 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

(pow, review 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Every function is one line when it has no special case, and at most six lines when it has
one. Longer bodies were rejected in review twice.

(pow, review 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The suite prints one line per check on purpose: a reviewer reads the log of
a failed run top to bottom and wants to see which pair of numbers broke.

(pow, review 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.

(pow, second review 1) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. The suite prints one line per check on purpose: a reviewer reads the log of a failed run
top to bottom and wants to see which pair of numbers broke.

(pow, second review 2) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. Each function is added in its own commit, with its own checks, in the order
of this document. A commit that adds two functions is sent back.

(pow, second review 3) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. The commit message is `feat: add <name> to calc` and nothing else on the first line.

(pow, second review 4) There was a proposal to print errors on stdout with a prefix. It was rejected because three
callers capture stdout with command substitution and would have treated the message as a number. The helpers
are sourced by other scripts, so a function must never call `exit`; it returns a status instead.

(pow, second review 5) An earlier draft of this section proposed floating point results. It was dropped after the
billing scripts that source calc.sh were found to compare results as strings. All output goes through `printf
'%s\n'`; `echo` is not used anywhere in lib/ because its handling of a leading dash differs between shells.

(pow, second review 6) The first implementation of this helper shelled out to `bc`. On the build machines `bc` is not
installed, and the fallback path was never exercised by a test, which is how the regression of March went
unnoticed for nine days. Arguments are assumed to be integers that fit in 64 bits. Nothing validates that, and
nothing should be added to validate it in this step.

(pow, second review 7) A contributor asked whether the helper should accept more than two arguments. The answer
recorded in the second review was no: callers that need a fold write the loop themselves, and the helper stays
trivially auditable. Every function is one line when it has no special case, and at most six lines when it has
one. Longer bodies were rejected in second review twice.

(pow, second review 8) The team discussed locale handling at length. Bash arithmetic ignores LC_NUMERIC, so nothing
here depends on it, but two downstream scripts export LC_ALL=C before sourcing calc.sh and that is why the
header comment still mentions it. The suite prints one line per check on purpose: a reviewer reads the log of
a failed run top to bottom and wants to see which pair of numbers broke.

(pow, second review 9) Performance was measured once, on the reporting job that calls these helpers about forty
thousand times per run. The subshell in the test harness dominated; the helper itself was not measurable. No
optimisation is wanted. Each function is added in its own commit, with its own checks, in the order of this
document. A commit that adds two functions is sent back.
