# ADR-0017: Any model can join any team

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

The first design fixed the cast: Fable or Astra leads, GLM works. The model table did
accept `fable` and `astra` for a worker, but nothing said so, there was no key for the
other Claude models, and an Astra lead could not run commands at all (ADR-0010,
amended). The owner wants to staff on demand: a Fable-led team takes on an Astra teammate
for one frontend review; an Astra-led team hands a piece of work to a Sonnet teammate.
The hard constraint is unchanged: subscriptions only, never an API key.

## Decision

A model is either a key or `<family>:<model-id>`, for `start` and for `spawn` alike.
Keys: `glm53`, `flash` (Z.ai Coding Plan); `fable`, `opus`, `sonnet`, `haiku` (Claude
subscription, one launcher installed under four names, the model chosen by the name);
`astra` (ChatGPT subscription). `claude:<id>` and `codex:<id>` reach any other model of
those two subscriptions through the same launchers, so the environment scrubbing and the
login pinning are identical. There is no `glm:<id>`: the Coding Plan covers two model ids,
and a third could only be billed some other way. The agent protocol tells the lead that
"spawn a teammate" means `teamctl spawn`, with the keys.

## Alternatives Considered

### Alternative 1: One launcher per model, as separate files
- **Pros**: nothing clever
- **Cons**: four copies of the security-relevant scrubbing code
- **Why not**: `claude-glm` / `claude-glm-flash` already showed the pattern: one file, the name decides

### Alternative 2: Free-form `--model <id>` only, no keys
- **Pros**: nothing to maintain when a model is released
- **Cons**: the lead is a language model; "spawn sonnet" must not depend on it remembering `claude-sonnet-5`, and a typo is a failed launch inside a pane
- **Why not**: keys for the common cases, the free form as the escape hatch

### Alternative 3: Let a worker's CLI switch models itself (`/model`)
- **Why not**: invisible to `teamctl status`, lost on restart, and for GLM workers it would leave the plan's two model ids

## Consequences

### Positive
- a team is staffed by what the task needs, whoever leads; every teammate still gets its own worktree, branch, Beads identity and pane
- billing isolation is untouched: every new name goes through a launcher that already existed

### Negative
- Claude-subscription workers spend the same quota as a Fable lead; nothing meters that (by design there is no metering), so the protocol keeps GLM as the default for workers
- guard rails differ by CLI: Codex-based teammates have no worktree guard and no lead-approval mode (ROADMAP)

### Risks
- a model id that the subscription does not include fails inside the pane, not at `spawn`; the pane stays (remain-on-exit) and shows the CLI's own message
