# ADR-0020: Providers beyond the three subscriptions

**Date**: 2026-09-20
**Status**: accepted
**Deciders**: repository owner; Claude (implementer)

## Context

On 2026-09-20 the owner asked for Kimi, DeepSeek and others beside the Z.ai GLM
Coding Plan. Every one of them sells an Anthropic-compatible endpoint that Claude
Code can be pointed at the same way as Z.ai
([ADR-0001](0001-subscription-only-launchers.md)), so the isolation of the GLM
launcher is the pattern to extend. Two things differ. Some of them are coding plans
on a subscription (Kimi for Coding, MiniMax, Alibaba Model Studio); others are
pay-as-you-go APIs with no plan at all (the Moonshot platform, DeepSeek). And their
facts drift: model ids, context windows and plan coverage change on the vendor's
schedule, not ours. Kimi Code also documents `ANTHROPIC_API_KEY` where the others
document `ANTHROPIC_AUTH_TOKEN`, and its terms forbid altering the User-Agent.

## Decision

One provider table, `config/wolfmux/lib/providers.sh`, becomes the only place that
knows a provider: vendor, label, endpoint, Keychain service, billing (`plan` or
`metered`), model ids, context window, auth variable, extra environment, key URL.
One launcher serves them all: `claude-glm` becomes the third-party launcher and
reads provider and tier from the name it is called by (`claude-kimi`,
`claude-moonshot`, `claude-deepseek`, `claude-minimax`, `claude-qwen`; symlinks, the
same pattern as `claude-opus`). One Keychain service per provider (`wolfmux-kimi`,
`wolfmux-moonshot`, `wolfmux-deepseek`, `wolfmux-minimax`, `wolfmux-qwen`; Z.ai
keeps `zai-coding-plan`). The scrub, the per-process endpoint, the login guard
([ADR-0007](0007-zai-key-delivery-and-login-guard.md)) and the dry run apply to
every provider unchanged; the User-Agent is never touched. Metered providers are in
the table but OFF: the launcher refuses (exit 78) and `teamctl spawn` / `start`
refuse (exit 77) until the owner sets `WOLFMUX_METERED=on`. The owner decides that,
at their own terminal; no agent may switch it on.

## Alternatives Considered

### Alternative 1: One launcher file per provider
- **Pros**: each file reads on its own
- **Cons**: five copies of the security-relevant scrubbing and guard code, five
  places to forget the metered gate
- **Why not**: `claude-fable` under four names already showed the pattern: one
  file, the name decides

### Alternative 2: An OpenRouter / LiteLLM / Fireworks / Novita / SiliconFlow proxy
- **Pros**: every provider behind one endpoint and one credential
- **Cons**: metered aggregators by nature, another daemon, another credential
  store, and one process that sees every request
- **Why not**: forbidden by [GOALS.md](../GOALS.md) constraint 1, before this
  decision and after it

### Alternative 3: A third CLI family (Gemini CLI, Grok Build, Mistral Vibe)
- **Pros**: providers without an Anthropic-compatible endpoint would be reachable
- **Cons**: each is a new CLI family in `agents.sh`: a new scrub list, a new
  settings model, a new guard surface, for one vendor each
- **Why not**: not now; the Anthropic-compatible endpoints cover everything asked
  for

### Alternative 4: A base-URL setting per provider, and China-region endpoints
- **Pros**: no wolfmux release needed when a vendor moves its endpoint
- **Cons**: a setting that can redirect a stored key to any URL is exactly the
  thing [ADR-0001](0001-subscription-only-launchers.md) exists to prevent; a
  China-region endpoint is a second way to reach the same account
- **Why not**: endpoints stay pinned in the table; a vendor move is a one-line
  change there

## Consequences

### Positive
- a provider is one `case` arm in one table: the launcher, `teamctl`, `doctor`
  and the documentation read the same facts
- every provider inherits the measured isolation (scrub, per-process endpoint,
  Keychain, login guard) with no new security-relevant code
- Xiaomi MiMo, StepFun, LongCat, Baidu, Tencent or Volcengine later is one more
  row and one more symlink

### Negative
- `claude-glm` stops being a GLM-only script; its name is one of many, and the
  file's header has to say so
- the vendor facts in the table need a glance when a vendor changes model ids,
  windows or plan coverage

### Risks
- vendor model ids and plan coverage change: the owner pins
  `WOLFMUX_<PROVIDER>_MODEL` / `WOLFMUX_<PROVIDER>_FAST_MODEL` in the config
  without waiting for a release (GLM stays non-pinnable: its plan covers exactly
  its two ids, [ADR-0017](0017-any-model-for-any-agent.md))
- a plan key used on a metered endpoint: Kimi for Coding and the Moonshot platform
  are different endpoints of one vendor with different billing; the table pins
  each provider to one endpoint and one Keychain service, so a stored key cannot
  be silently pointed at the other
- a metered provider, once switched on, bills per request with no local cap; the
  switch is the owner's, in the config file, and an agent that tries anyway is
  refused
- the metered gate reads the owner's real config file, found through the passwd
  database, so neither `WOLFMUX_METERED` in the environment nor a redirected `HOME`
  or `WOLFMUX_HOME` opens it. It is a guard against accident and casual override, not
  a sandbox: every agent runs as the macOS user, and a process that edits
  `~/.config/wolfmux/config` or a launcher can open it (the same class of wording as
  the worktree guard, [ADR-0016](0016-worktree-guard.md)). The worktree guard refuses a worker's `Edit`
  and `Write` on that file, but not a shell command the worker runs, and a lead is
  not guarded at all; the metered refusal therefore names no line for an agent to add. `teamctl restart` of a metered agent is
  gated in the launcher, not in teamctl

## The table (researched 2026-09-20)

| key | vendor | endpoint host | billing | auth variable |
|-----|--------|---------------|---------|---------------|
| `glm` | Z.ai | `api.z.ai` | plan (GLM Coding Plan) | `ANTHROPIC_AUTH_TOKEN` |
| `kimi` | Moonshot AI | `api.kimi.com` | plan (Kimi for Coding) | `ANTHROPIC_API_KEY` |
| `moonshot` | Moonshot AI | `api.moonshot.ai` | metered | `ANTHROPIC_AUTH_TOKEN` |
| `deepseek` | DeepSeek | `api.deepseek.com` | metered | `ANTHROPIC_AUTH_TOKEN` |
| `minimax` | MiniMax | `api.minimax.io` | plan (Coding Plan) | `ANTHROPIC_AUTH_TOKEN` |
| `qwen` | Alibaba | `coding-intl.dashscope.aliyuncs.com` | plan (Model Studio coding plan) | `ANTHROPIC_AUTH_TOKEN` |

Labels: Kimi Code, Kimi K3 API, DeepSeek V4, MiniMax M3, Qwen 3.7 Plus (GLM's stay
GLM-5.3 and GLM-5.3 Flash). All are pinnable except GLM. Context windows come from
the vendor pages; where the pages disagree or stay silent (Kimi, Qwen) the table is
conservative at 262144 and `WOLFMUX_KIMI_CONTEXT` / `WOLFMUX_QWEN_CONTEXT` raises
it. Kimi's background tier is its main model (`kimi-for-coding`) on purpose:
`kimi-k2.7-code` rejects requests without thinking and
`kimi-for-coding-highspeed` is tier-gated. Kimi also asks for
`CLAUDE_CODE_EFFORT_LEVEL`; it is exported after the scrub and added to the scrub
list, so a Claude-subscription child never inherits it.

## Sources (fetched 2026-09-20)

- DeepSeek: [Claude Code integration](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/) · [Anthropic API](https://api-docs.deepseek.com/guides/anthropic_api) · [pricing](https://api-docs.deepseek.com/quick_start/pricing) (metered; no coding plan)
- Kimi Code: [Claude Code guide](https://www.kimi.com/code/docs/en/third-party-tools/claude-code) · [membership guide](https://www.kimi.com/en/help/kimi-code/membership-guide). The two name `api.kimi.ai/coding/` and `api.kimi.com/coding/`; both answer, the table uses the second
- Moonshot platform: [Claude Code with Kimi](https://platform.kimi.ai/docs/guide/claude-code-kimi) · [API troubleshooting](https://www.kimi.ai/help/kimi-api/api-troubleshooting)
- MiniMax: [Claude Code](https://platform.minimax.io/docs/coding-plan/claude-code) · [coding plan](https://platform.minimax.io/docs/coding-plan/intro)
- Alibaba Model Studio: [Claude Code](https://www.alibabacloud.com/help/en/model-studio/claude-code) · [coding plan](https://www.alibabacloud.com/help/en/model-studio/coding-plan). Plan keys are for interactive coding tools only: a team in tmux panes is that, a script is not
