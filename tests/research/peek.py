#!/usr/bin/env python3
"""peek.py <transcript.jsonl> <row-type>[:<attachment-or-subtype>] [n] - print the first n rows of
one kind with every long string cut, to learn a transcript's shape without reading megabytes."""
import json, sys

def cut(v, n=160):
    if isinstance(v, str):
        return v if len(v) <= n else v[:n] + f"...<{len(v)} chars>"
    if isinstance(v, list):
        return [cut(x, n) for x in v[:6]] + ([f"...<{len(v)} items>"] if len(v) > 6 else [])
    if isinstance(v, dict):
        return {k: cut(x, n) for k, x in v.items()}
    return v

def main():
    path, want = sys.argv[1], sys.argv[2]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    kind, _, sub = want.partition(":")
    shown = 0
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("type") != kind:
            continue
        if sub:
            got = row.get("attachment", {}).get("type") if kind == "attachment" else row.get("subtype")
            if got != sub:
                continue
        print(json.dumps(cut(row), indent=1)[:6000])
        shown += 1
        if shown >= limit:
            break

if __name__ == "__main__":
    main()
