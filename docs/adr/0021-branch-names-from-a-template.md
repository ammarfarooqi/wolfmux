# ADR-0021: Worker branch names come from a template, and only branches teamctl created are deleted

**Date**: 2026-09-23
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

[GitHub issue #3](https://github.com/ammarfarooqi/wolfmux/issues/3). Worker branches were
always `ai/<role>-<timestamp>` (`ai/<team>/<role>-<timestamp>` in a named team). A reporter's
repositories run a pre-commit check that every branch name contains a Jira key. Every worker
commit failed that one rule, so every worker committed with the project's skip switch
(`DEVFLOW_SKIP=1`) or `--no-verify` — eleven workers in one day. A skip switch used on every
commit protects nothing, and it switches off the other checks in the same hook. The
alternative the reporter used, cherry-picking every worker commit onto a properly named
branch, works but changes every sha.

The shape was also assumed in code: `remove` and `destroy --purge` deleted a worker's branch
only when it matched `ai/*`, which is both the creation rule and the deletion rule rolled into
one pattern. Once the name is configurable, that pattern says nothing about who made the branch.

## Decision

A team's worker branch names come from a **template** with the placeholders `{team}` `{role}`
`{ts}` `{ticket}`, stored per team (`teamctl policy branch-template '<template>'`,
`teamctl policy branch-template default` to clear it; `WOLFMUX_BRANCH_TEMPLATE` in the owner's
config is the default for every team). The built-in template reproduces today's names exactly,
so a project that does not touch this sees no change at all.

- `{ts}` is required in every template. It is the only thing that keeps two workers of one
  role on two branches, so a template without it is refused (exit 64), as is an unknown
  placeholder or an unclosed brace.
- A template with `{ticket}` and a spawn with no ticket key is refused (exit 64), naming
  `--ticket`. It is never guessed at: a wrong ticket key is exactly what the setting exists
  to prevent. The key comes from `teamctl spawn --ticket <KEY>`, or from the team's default
  (`teamctl start <model> --ticket <KEY>`), and the spawn's own key wins.
- `teamctl spawn --branch <name>` skips the template. git decides whether the name is legal
  (`git check-ref-format --branch`), and a branch that already exists is refused (exit 1).
- Deletion has its own rule, recorded rather than inferred: a record carries
  `branch_created: "1"` when teamctl created that branch, and **only such a branch is ever
  deleted**, whatever it is called. A branch teamctl did not create is named in the output and
  left alone. A record written before the field existed has none; teamctl then created only
  `ai/…` branches and deleted only those, so that shape still counts as teamctl's and teams
  from earlier versions keep working unchanged.
- `branch-template` is the one policy key whose value is free text. It is therefore never
  typed into the lead's pane: the notice says the key changed and nothing more, and
  `status --json` keeps its existing `policy` object.

## Consequences

- A repository that enforces a branch shape gets conforming worker branches, and no worker
  has a reason to bypass a commit hook. The protocol's LEAD section says to set the template
  before staffing, and to fix the name rather than tell a worker to skip a hook.
- One more thing to get wrong: a template that expands to a name git rejects is only caught
  at the next spawn, not when it is set. The message names the offending name and the git
  rule it broke.
- A stored template that cannot be used any more falls back to the built-in shape instead of
  stopping a spawn, in the same spirit as `policy_get` falling back for the other keys.
- `{ticket}` is a string wolfmux never validates against a tracker. It is kept to letters,
  digits, `-` and `_` so it is safe in a branch name, and nothing more is claimed about it.
