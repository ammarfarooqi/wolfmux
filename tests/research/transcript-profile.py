#!/usr/bin/env python3
"""transcript-profile.py <transcript.jsonl> [--json]

Where the tokens and the seconds of ONE Claude Code conversation went, read from the transcript
the CLI writes (~/.claude/projects/<dir>/<session>.jsonl, Claude Code 2.1.325 row shapes).
Nothing is sent anywhere and nothing is written.

What is measured and what is estimated:
  measured   tokens of every request (usage of each assistant message: input + cache_creation +
             cache_read), output tokens, compaction rows (preTokens, postTokens, durationMs),
             hook durations (hook_success.durationMs), timestamps of every row.
  estimated  the split of a request BY SOURCE. The transcript holds the text of each source
             (system prompt, tool schemas, instruction files, listings, hook text, tool results)
             but not its token count, so characters are converted with the conversation's own
             ratio: tokens of the first request / characters known to be in it.
"""
import json
import sys
from collections import defaultdict
from datetime import datetime

MAIL_PREFIX = "[wolfmux mail]"
MEMORY_PREFIX = "[wolfmux memory]"


def load(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def ts(row):
    raw = row.get("timestamp")
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def chars(value):
    """Characters of any JSON value as it would be sent: strings as they are, the rest as JSON."""
    if value is None:
        return 0
    if isinstance(value, str):
        return len(value)
    return len(json.dumps(value, ensure_ascii=False))


def rendered_chars(row):
    return sum(chars(part.get("content")) for part in row.get("rendered") or [] if isinstance(part, dict))


def instruction_group(path):
    if "/rules/ecc/zh/" in path:
        return "rules: ecc/zh (Chinese copy)"
    if "/rules/ecc/common/" in path:
        return "rules: ecc/common"
    if "/rules/" in path:
        return "rules: other (" + path.split("/rules/")[1].rsplit("/", 1)[0] + ")"
    if path.endswith("MEMORY.md") or "/memory/" in path:
        return "auto memory (MEMORY.md)"
    return "instructions: " + path.rsplit("/", 1)[-1]


def hook_kind(att):
    text = att.get("content")
    text = "\n".join(map(str, text)) if isinstance(text, list) else str(text or "")
    event = att.get("hookEvent", "?")
    if MAIL_PREFIX in text:
        return f"hook {event}: wolfmux mail"
    if MEMORY_PREFIX in text:
        return f"hook {event}: wolfmux memory/checkpoint"
    if "[wolfmux" in text:
        return f"hook {event}: wolfmux other"
    return f"hook {event}: other ({att.get('hookName', '?')})"


def attachment_kind(att):
    kind = att.get("type")
    if kind == "hook_additional_context":
        return hook_kind(att)
    if kind in ("file", "edited_text_file", "compact_file_reference"):
        return "attachment: file re-read"
    return f"attachment: {kind}"


SYSTEM_PARTS = (("# Wolfmux", "system prompt: wolfmux protocol + session header"),
                ("# Memory", "system prompt: auto-memory instructions"),
                ("# Claude in Chrome", "system prompt: Chrome section"))


def system_part(text):
    for prefix, name in SYSTEM_PARTS:
        if text.lstrip().startswith(prefix):
            return name
    return "system prompt: CLI base"


def wire_tools(rows):
    """Tool schemas as sent: the first api-request-shape row names them (the first snapshot does not)."""
    for row in rows:
        shape = row.get("shape") if row.get("type") == "api-request-shape" else None
        if isinstance(shape, dict) and shape.get("tools"):
            return shape["tools"]
    return []


def first_request_sources(rows):
    """Characters of every source that is in the conversation before the first answer."""
    out = defaultdict(int)
    tools = wire_tools(rows)
    out["tool schemas (%d tools)" % len(tools)] += chars(tools)
    for row in rows:
        if row.get("type") == "assistant":
            break
        if row.get("type") == "user":
            out["first prompt (user turn)"] += chars(row.get("message", {}).get("content"))
            continue
        if row.get("type") != "attachment":
            continue
        att = row.get("attachment", {})
        kind = att.get("type")
        if kind == "prompt_snapshot":
            for part in att.get("systemPrompt") or []:
                out[system_part(part)] += chars(part)
        elif kind == "instructions":
            for item in att.get("files") or []:
                out[instruction_group(item.get("path", ""))] += chars(item.get("content"))
        elif kind == "hook_additional_context":
            out[hook_kind(att)] += chars(att.get("content"))
        elif kind in ("hook_success", "deferred_tools_record"):
            continue
        else:
            size = rendered_chars(row)
            if size:
                out[f"listing/reminder: {kind}"] += size
    return dict(out)


def requests(rows):
    """One entry per API request: tokens in, tokens out, when it ended, what it was waiting on."""
    seen, out, prev_ts = {}, [], None
    for row in rows:
        when = ts(row)
        if row.get("type") == "assistant" and not row.get("isSidechain"):
            msg = row.get("message", {})
            usage = msg.get("usage") or {}
            mid = msg.get("id") or row.get("requestId") or row.get("uuid")
            total = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            if mid not in seen:
                seen[mid] = {"id": mid, "start": prev_ts, "end": when, "context": total,
                             "cache_read": usage.get("cache_read_input_tokens") or 0,
                             "cache_write": usage.get("cache_creation_input_tokens") or 0,
                             "output": usage.get("output_tokens") or 0, "model": msg.get("model")}
                out.append(seen[mid])
            else:
                entry = seen[mid]
                entry["end"] = when or entry["end"]
                entry["output"] = max(entry["output"], usage.get("output_tokens") or 0)
            continue
        if when is not None and row.get("type") in ("user", "attachment", "system"):
            prev_ts = when
    return [r for r in out if r["context"] > 0]


def added_by_kind(rows):
    """Characters put into the conversation after the first answer, by kind."""
    out, tool_names, started = defaultdict(int), {}, False
    for row in rows:
        kind = row.get("type")
        if row.get("isSidechain"):
            continue
        if kind == "assistant":
            started = True
            for block in row.get("message", {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    tool_names[block.get("id")] = block.get("name")
                    out["model output: tool call input"] += chars(block.get("input"))
                elif block.get("type") == "text":
                    out["model output: text"] += chars(block.get("text"))
            continue
        if not started:
            continue
        if kind == "user":
            content = row.get("message", {}).get("content")
            if row.get("isCompactSummary"):
                out["compaction summary"] += chars(content)
            elif isinstance(content, str):
                out["user/typed prompt"] += len(content)
            else:
                for block in content or []:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        out["tool result: " + str(tool_names.get(block.get("tool_use_id"), "?"))] += chars(block.get("content"))
                    else:
                        out["user/typed prompt"] += chars(block)
        elif kind == "attachment":
            att = row.get("attachment", {})
            if att.get("type") in ("hook_success", "deferred_tools_record", "prompt_snapshot"):
                continue
            size = chars(att.get("content")) if att.get("type") == "hook_additional_context" else rendered_chars(row)
            if size:
                out[attachment_kind(att)] += size
    return dict(out)


def hook_time(rows):
    out = defaultdict(lambda: [0, 0])
    for row in rows:
        att = row.get("attachment", {}) if row.get("type") == "attachment" else {}
        if att.get("type") == "hook_success":
            cell = out[att.get("hookEvent", "?")]
            cell[0] += 1
            cell[1] += att.get("durationMs") or 0
    return {k: {"runs": v[0], "ms": v[1]} for k, v in out.items()}


def compactions(rows, reqs):
    out = []
    for row in rows:
        if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
            meta, when = row.get("compactMetadata") or {}, ts(row)
            after = next((r for r in reqs if r["end"] and when and r["end"] > when), None)
            out.append({"at": row.get("timestamp"), "trigger": meta.get("trigger"), "pre": meta.get("preTokens"),
                        "post": meta.get("postTokens"), "seconds": round((meta.get("durationMs") or 0) / 1000, 1),
                        "first_request_after": after["context"] if after else None})
    return out


def last_cost(rows):
    cost = [r for r in rows if r.get("type") == "cost-state"]
    return cost[-1] if cost else {}


def profile(path):
    rows = load(path)
    reqs = requests(rows)
    sources = first_request_sources(rows)
    first = reqs[0]["context"] if reqs else 0
    known = sum(sources.values()) or 1
    waits = [r["end"] - r["start"] for r in reqs if r["start"] and r["end"] and r["end"] >= r["start"]]
    stamps = [t for t in map(ts, rows) if t]
    cost = last_cost(rows)
    return {
        "file": path, "requests": len(reqs), "first_request_tokens": first,
        "tokens_per_char_first_request": round(first / known, 4),
        "first_request_by_source": {k: {"chars": v, "est_tokens": round(v * first / known)} for k, v in sorted(sources.items(), key=lambda kv: -kv[1])},
        "peak_context": max((r["context"] for r in reqs), default=0),
        "sum_input_tokens": sum(r["context"] for r in reqs),
        "sum_cache_read": sum(r["cache_read"] for r in reqs),
        "sum_cache_write": sum(r["cache_write"] for r in reqs),
        "sum_output_tokens": sum(r["output"] for r in reqs),
        "wall_seconds": round(max(stamps) - min(stamps), 1) if stamps else 0,
        "model_seconds_from_rows": round(sum(waits), 1),
        "cli_api_seconds": round((cost.get("totalAPIDuration") or 0) / 1000, 1),
        "cli_tool_seconds": round((cost.get("totalToolDuration") or 0) / 1000, 1),
        "cli_cost_usd": cost.get("totalCostUSD"),
        "hook_time": hook_time(rows), "added_chars_by_kind": dict(sorted(added_by_kind(rows).items(), key=lambda kv: -kv[1])),
        "compactions": compactions(rows, reqs),
    }


def show(p):
    print(f"file: {p['file']}")
    print(f"requests {p['requests']}  first {p['first_request_tokens']:,}  peak {p['peak_context']:,}  "
          f"sum-in {p['sum_input_tokens']:,} (cache read {p['sum_cache_read']:,}, write {p['sum_cache_write']:,})  out {p['sum_output_tokens']:,}")
    print(f"wall {p['wall_seconds']}s  model(rows) {p['model_seconds_from_rows']}s  cli-api {p['cli_api_seconds']}s  "
          f"cli-tools {p['cli_tool_seconds']}s  cost ${p['cli_cost_usd']}")
    print(f"\nfirst request by source (est. at {p['tokens_per_char_first_request']} tokens/char):")
    for name, cell in p["first_request_by_source"].items():
        print(f"  {cell['est_tokens']:>8,}  {cell['chars']:>8,} ch  {name}")
    total = sum(p["added_chars_by_kind"].values()) or 1
    print("\nadded after the first answer, by kind (characters, share):")
    for name, size in p["added_chars_by_kind"].items():
        print(f"  {size:>9,}  {100 * size / total:5.1f}%  {name}")
    print("\nhooks:", json.dumps(p["hook_time"]))
    for c in p["compactions"]:
        print(f"compaction {c['at']} {c['trigger']}: {c['pre']:,} -> {c['post']:,} in {c['seconds']}s; next request {c['first_request_after']}")


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    if not args:
        sys.exit(__doc__)
    for path in args:
        result = profile(path)
        if "--json" in sys.argv:
            print(json.dumps(result, indent=1))
        else:
            show(result)
            print()


if __name__ == "__main__":
    main()
