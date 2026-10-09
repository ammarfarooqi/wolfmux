# ADR-0024: `teamctl doctor --probe`, and which console each Kimi key comes from

**Date**: 2026-09-23
**Status**: accepted
**Deciders**: repository owner (issue #1); lead of the adding-providers team; Claude (implementer)

## Context

A kimi worker answered 401 on every request while `teamctl doctor` reported the provider as
healthy. Doctor checks that the Keychain item exists, never that the endpoint accepts what is in
it, and the key in the slot was of the wrong kind: two consoles both say "Kimi", both keys start with
`sk-`, and a key from platform.kimi.ai only works with `moonshot` while the `kimi` endpoint accepts
only a Kimi Code membership key. Two things pointed the wrong way on top of that: Claude Code's
`Both CLAUDE_CODE_OAUTH_TOKEN and apiKeyHelper set` warning (the login guard, harmless) and the
documented fallback `WOLFMUX_<P>_AUTH_MODE=env`, which cannot fix a wrong key and, for Kimi's
`ANTHROPIC_API_KEY`, makes Claude Code stop at an interactive "use this API key?" prompt.
Plain doctor is offline and reads no key value, and that is worth keeping.

## Decision

`teamctl doctor --probe` (opt-in) reads a key value and asks the endpoint about it, for every
provider whose Keychain item exists, and reports only the HTTP status.

- **The request** is one `POST <endpoint>/v1/messages` with the body `{}` (no model, no message),
  the key in both `x-api-key` and `Authorization: Bearer` (what a helper-mode worker sends). It asks
  for no completion, so nothing is generated and nothing is billed, the metered providers included:
  no metered gate applies, and doctor says what a probe sends.
- **Why not `GET /v1/models`.** Measured on 2026-09-23 with an obviously fake key, status codes only:

  | endpoint | `GET /v1/models` | `POST /v1/messages` with `{}` |
  |----------|------------------|-------------------------------|
  | api.z.ai/api/anthropic | 200 (no key needed) | 401 |
  | api.kimi.com/coding | 401 | 401 |
  | api.moonshot.ai/anthropic | 404 | 401 |
  | api.deepseek.com/anthropic | 401 | 401 |
  | api.minimax.io/anthropic | 401 | 401 |
  | coding-intl.dashscope.aliyuncs.com/apps/anthropic | 404 | 401 |

  A model listing would call a fake Z.ai key fine and has no route at Moonshot and Qwen. On all six the
  key is checked first and the body after.
- **Mapping.** 2xx, 400, 422 and 429 mean the key was accepted (the raw status is printed next to
  it); 401 and 403 are a FAIL naming the Keychain slot, the endpoint and where that key comes from;
  no answer or any other status is a warning.
- **The key** is read in one function, handed to `curl --config -` on stdin through a pipe from the
  `printf` builtin, and never reaches an argument, an environment, a file (a bash 3.2 here-document or
  here-string is a temporary file, so neither is used) or the screen. `curl -q` ignores `~/.curlrc`, no
  redirect is followed, and the request goes only to the provider table's endpoint, only over https,
  built of plain characters; a stored key with a space, quote, backslash or line break is not sent.
- **Key shape**, under `--probe` only: the provider table gets `PROVIDER_KEY_PREFIX` (`sk-kim` for
  kimi, `sk-sp-` for qwen, empty = no check) and `PROVIDER_KEY_SOURCE` (which console issues the key and
  which look-alike does not work here). A kimi key that does not start with `sk-kim` is called what it
  probably is, a Moonshot platform key. The same source sentence is shown by plain doctor, the README,
  SETUP and TROUBLESHOOTING.
- **The kickoff** of a provider worker says what a 401 means and who runs `doctor --probe`, and the
  worker's pane prints one line naming its Keychain slot and endpoint above the CLI. The kickoff only
  reaches a model that got through, so the pane line is what a human sees when the first request fails.
- **Env mode** is documented as a last resort. Claude Code's documentation says the approval prompt
  appears for `ANTHROPIC_API_KEY` in interactive mode, that the choice is remembered, and names no
  setting that pre-approves the key. So Wolfmux sets nothing (in particular it never writes
  `~/.claude.json`) and documents the prompt.

## Alternatives Considered

### Alternative 1: probe by default, in plain doctor
- **Pros**: nobody has to know about the flag.
- **Cons**: plain doctor would read every key value and need the network; it is run by agents and in
  scripts, and "offline, never reads a key" is a property people rely on.
- **Why not**: the flag costs one word and keeps that property.

### Alternative 2: `GET /v1/models`
- **Pros**: the request an API reference would call harmless.
- **Cons**: see the table above: wrong for three of six endpoints.
- **Why not**: measured, not guessed.

### Alternative 3: a minimal billed request (`max_tokens: 1`)
- **Pros**: proves the key works end to end, model included.
- **Cons**: it spends money at Moonshot and DeepSeek, so it would need the metered gate and a warning.
- **Why not**: an empty body reaches the same authentication check without spending anything.

### Alternative 4: pre-approve the env-mode key for the launcher process
- **Pros**: an unattended worker would not hang.
- **Cons**: Claude Code documents no such setting; the remembered answer lives in `~/.claude.json`,
  which Wolfmux does not write.
- **Why not**: nothing to set. Helper mode has no prompt and stays the default.

## Consequences

### Positive
- The reported case (a platform key in the kimi slot) is a one-minute fix: FAIL, slot, endpoint, console.
- A new provider row can ask for the same checks with two fields.

### Negative
- `doctor` gains 150 lines and a network path; `--probe` makes one request per provider per run.
- The doctor text in the table (`PROVIDER_KEY_SOURCE`) is a vendor fact that can go stale.

### Risks
- **The good-key side is inferred, not measured.** Only the reject side (401 with a fake key) was
  observed; no real key was used. A valid key should pass authentication and be refused for the empty
  body (400 or 422). A vendor that answers a valid key differently shows up as a warning with its raw
  status, which is why the status is always printed.
- A vendor could one day answer an empty body with a completion. The body has no model and no messages,
  so that is not expected; the raw status would show it.
