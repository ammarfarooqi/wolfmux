#!/usr/bin/env python3
"""latency.py <transcript.jsonl> - what a request costs as the conversation grows, and what the
compactions and cache misses of one conversation cost in seconds and tokens. Measured from row
timestamps and usage blocks; nothing is estimated."""
import json
import statistics
import sys
from datetime import datetime

BUCKETS = ((0, 100_000), (100_000, 150_000), (150_000, 200_000), (200_000, 300_000), (300_000, 10**9))


def when(row):
    raw = row.get("timestamp")
    return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp() if isinstance(raw, str) else None


def load(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    return rows


def requests(rows):
    """(context tokens, cache-written tokens, output tokens, seconds from the previous step to the last block)."""
    seen, out, prev = {}, [], None
    for row in rows:
        at = when(row)
        if row.get("type") == "assistant" and not row.get("isSidechain"):
            msg = row.get("message", {})
            usage = msg.get("usage") or {}
            ctx = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            mid = msg.get("id")
            if mid not in seen:
                seen[mid] = [ctx, usage.get("cache_creation_input_tokens") or 0, usage.get("output_tokens") or 0, prev, at]
                out.append(seen[mid])
            else:
                seen[mid][4] = at
                seen[mid][2] = max(seen[mid][2], usage.get("output_tokens") or 0)
        elif at and row.get("type") in ("user", "attachment"):
            prev = at
    return [(c, w, o, e - s) for c, w, o, s, e in out if c and s and e and e >= s]


def compaction_gaps(rows):
    """Seconds the conversation stood still around each compaction: last step before -> first answer after."""
    out, last_step = [], None
    pending = None
    for row in rows:
        at = when(row)
        if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
            meta = row.get("compactMetadata") or {}
            pending = {"pre": meta.get("preTokens"), "post": meta.get("postTokens"), "summary_s": (meta.get("durationMs") or 0) / 1000,
                       "precomputed": meta.get("precomputed"), "before": last_step, "boundary": at}
        elif row.get("type") == "assistant" and at:
            if pending:
                pending["stall_s"] = round(at - pending["before"], 1) if pending["before"] else None
                out.append(pending)
                pending = None
            last_step = at
        elif at and row.get("type") == "user":
            last_step = at
    return out


def main():
    rows = load(sys.argv[1])
    reqs = requests(rows)
    print(f"{len(reqs)} requests with a measurable wait")
    print("context bucket        n   median s   mean s   median out-tokens   s per 1k out")
    for low, high in BUCKETS:
        sel = [r for r in reqs if low <= r[0] < high]
        if not sel:
            continue
        secs, outs = [r[3] for r in sel], [r[2] for r in sel]
        rate = 1000 * sum(secs) / max(1, sum(outs))
        print(f"{low // 1000:>4}k-{'%dk' % (high // 1000) if high < 10**9 else 'up':<6} {len(sel):>6} {statistics.median(secs):>9.1f} {statistics.mean(secs):>8.1f} {statistics.median(outs):>12.0f} {rate:>18.1f}")
    misses = [r for r in reqs if r[1] > 0.5 * r[0]]
    print(f"cache misses (more than half of the request written, not read): {len(misses)} requests, "
          f"{sum(r[1] for r in misses):,} tokens written, {sum(r[3] for r in misses):.0f}s")
    for gap in compaction_gaps(rows):
        print(f"compaction {gap['pre']:,} -> {gap['post']:,}: summary took {gap['summary_s']:.0f}s (precomputed={gap['precomputed']}), "
              f"conversation stood still {gap.get('stall_s')}s")


if __name__ == "__main__":
    main()
