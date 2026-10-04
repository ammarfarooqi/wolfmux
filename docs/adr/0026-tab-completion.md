# 26. Tab completion: one backend inside teamctl, thin shims

Date: 2026-10-04

## Status

accepted

## Context

The owner types `teamctl` and Tab offers nothing. teamctl has grown to 24 public
commands with their options and values the tool knows: roles, teams, models, policy
keys and their choices, layouts, pending approval ids, local branch names. That
knowledge already lives in the shell code; a second copy of it in a completion
script would drift from the option parsers the first time an option is added or
renamed, exactly the class of bug `tests/docs.sh` exists for.

The completion has to work in both shells the owner uses, zsh and bash 3.2, and it
must be harmless to load: a shell startup file that errors, prints, or switches on
the whole completion system uninvited is worse than no completion.

## Decision

One backend, `teamctl _complete -- <word>...`, inside teamctl
(`config/wolfmux/lib/completion.sh`), dispatched as the internal command `_complete`.
It reads the words typed after `teamctl`, answers with candidates one per line as
`candidate<TAB>short description`, and hands file completion back to the shell with
the single line `__files__`.

The zsh and bash shims (`config/wolfmux/completion/`) stay thin: they collect the
words (`$words`/`$CURRENT` in zsh, `COMP_WORDS`/`COMP_CWORD` in bash), call the
backend, and present the answer (`_describe`, `COMPREPLY`). No command, option or
value is named in a shim.

Consequences:

- There is exactly one place that knows the commands, options and values, next to
  the parsers they mirror; `tests/docs.sh` guards it from the other side by asking
  `_complete` for every command and parser option.
- The backend runs at every Tab. It does nothing but read: no lock, no state write,
  no tmux session. Commands, options, models, policy keys and layouts need no project
  and are offered anywhere; roles, teams, approvals and branches belong to one, and
  outside a git repository (or for a team that does not exist) they are simply empty,
  exit 0, nothing on stderr. It never dies (`set +euo pipefail`, trap cleared), and it answers
  in well under the 100 ms a keypress tolerates (measured about 45 ms per call,
  against `teamctl version` at 40 ms on the same machine).
- `teamctl completion <zsh|bash>` prints a shim, so `source <(teamctl completion zsh)`
  works wherever the tool is installed. install.sh copies the shims and sources the
  zsh one from the wolfmux block in `~/.zshrc`; an install from before completion is
  upgraded in place, after a backup, exactly once.

## Why compinit is never switched on for the user

`compinit` rebuilds the completion cache and changes how the whole shell completes
everything else: functions, options of other tools, their styles and colors. Turning
that on as a side effect of sourcing a file from `~/.zshrc` would silently change a
shell the owner has configured themselves, and order the file before or after their
framework's own setup in ways no one can see. The zsh shim therefore registers with
`compdef` only when a completion system is already loaded (oh-my-zsh and most
frameworks run compinit; the wolfmux block sits at the very end of `~/.zshrc`). With
no completion system, sourcing the shim defines the completer, registers nothing,
and prints nothing; a shell without compinit gets one documented line to add above
the block.
