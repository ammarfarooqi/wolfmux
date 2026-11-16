#!/usr/bin/env python3
"""timeline.py <transcript.jsonl>... - every step of one or more conversations on one clock:
the time, seconds since the previous step of that file, who acted and what it was. Rows that
carry no step (bookkeeping, listings) are left out. Used to split "task created -> report read
by the lead" into model time, tool time and wolfmux time."""
import json
import sys
from datetime import datetime

SKIP_ATTACHMENTS = {"deferred_tools_record", "prompt_snapshot", "hook_success", "instructions", "skill_listing",
                    "agent_listing_delta", "environment", "model", "auto_mode", "session_context", "date",
                    "credential_org", "remote_session_change", "total_tokens_reminder"}


def when(row):
    raw = row.get("timestamp")
    return datetime.fromisoformat(raw.replace("Z", "+00:00")) if isinstance(raw, str) else None


def short(value, limit=110):
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return " ".join(text.split())[:limit]


def describe_assistant(row):
    usage = row.get("message", {}).get("usage") or {}
    total = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    parts = []
    for block in row.get("message", {}).get("content") or []:
        if block.get("type") == "tool_use":
            parts.append("CALL " + block.get("name", "?") + " " + short(block.get("input"), 90))
        elif block.get("type") == "text":
            parts.append("SAYS " + short(block.get("text"), 90))
    return f"model [{total:,} in] " + " | ".join(parts) if parts else None


def describe_user(row):
    content = row.get("message", {}).get("content")
    if isinstance(content, str):
        return "prompt: " + short(content)
    for block in content or []:
        if isinstance(block, dict) and block.get("type") == "tool_result":
            return f"tool result ({len(json.dumps(block.get('content')))} ch)"
    return "prompt: " + short(content)


def describe(row):
    kind = row.get("type")
    if kind == "assistant":
        return describe_assistant(row)
    if kind == "user":
        return describe_user(row)
    if kind == "attachment":
        att = row.get("attachment", {})
        if att.get("type") in SKIP_ATTACHMENTS:
            return None
        if att.get("type") == "hook_additional_context":
            return f"hook {att.get('hookEvent')} adds: " + short(att.get("content"))
        return "attachment " + str(att.get("type"))
    if kind == "system":
        return "system " + str(row.get("subtype"))
    return None


def steps(path, label):
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        at, text = when(row), describe(row)
        if at and text:
            yield at, label, text


def main():
    rows = []
    for index, path in enumerate(sys.argv[1:]):
        rows.extend(steps(path, chr(ord("A") + index)))
    rows.sort(key=lambda r: r[0])
    last = {}
    for at, label, text in rows:
        gap = (at - last[label]).total_seconds() if label in last else 0.0
        last[label] = at
        print(f"{at.strftime('%H:%M:%S.%f')[:-3]} {label} +{gap:6.1f}s  {text}")


if __name__ == "__main__":
    main()
