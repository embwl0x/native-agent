#!/usr/bin/env python3
"""Her-screen proof tasks: what one task cost her, read from the traces she
already writes. No app code, no test harness — reads data/turn_traces and the
session's messages.

    her_screen_bench.py <session_id> [<session_id> ...]

Per session (one task each): model calls, tool calls by name, total tokens
(input + cache read + cache write + output), wall time, and whether it replied.
Plan: docs/build_plans/her-screen-2026-09-23.md (Phase 0).
"""
import collections
import glob
import json
import os
import sys
from datetime import datetime

ROOT = os.path.expanduser("~/Projects/NativeAgent/data")


def turn_ids(session):
    path = os.path.join(ROOT, "chat/messages", f"{session}.jsonl")
    ids, first, last, replied = [], None, None, False
    for line in open(path):
        row = json.loads(line)
        at = datetime.fromisoformat(row["createdAt"].replace("Z", "+00:00"))
        if row.get("role") == "user" and first is None:
            first = at
        if row.get("role") == "assistant":
            last, replied = at, bool((row.get("content") or "").strip())
            tid = (row.get("metadata") or {}).get("turnTraceId")
            if tid:
                ids.append(tid)
    return ids, first, last, replied


def cost(ids):
    want = set(ids)
    calls = tokens = 0
    tools = collections.Counter()
    for path in sorted(glob.glob(os.path.join(ROOT, "turn_traces/*.jsonl")))[-3:]:
        for line in open(path):
            if not any(t in line for t in want):
                continue
            row = json.loads(line)
            payload = row.get("payload") or {}
            if (row.get("turnId") or payload.get("turnId")) not in want:
                continue
            kind = row.get("kind") or row.get("event") or row.get("type")
            if kind == "llm.call" and payload.get("surface") == "chat":
                calls += 1
                tokens += sum(payload.get(k) or 0 for k in (
                    "inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "outputTokens"))
            elif kind == "tool.dispatch":
                name = payload.get("tool") or payload.get("toolName") or payload.get("name")
                if name:
                    tools[name] += 1
    # tool.dispatch is logged at start and end; count each call once
    return calls, tokens, {k: (v + 1) // 2 for k, v in tools.items()}


def main(sessions):
    print(f"{'session':28} {'calls':>5} {'tokens':>9} {'secs':>6} {'ok':>3}  tools")
    for session in sessions:
        ids, first, last, replied = turn_ids(session)
        calls, tokens, tools = cost(ids)
        secs = (last - first).total_seconds() if first and last else 0
        used = ", ".join(f"{k}×{v}" for k, v in sorted(tools.items(), key=lambda x: -x[1]))
        print(f"{session:28} {calls:>5} {tokens:>9} {secs:>6.0f} {'y' if replied else 'n':>3}  {used}")


if __name__ == "__main__":
    main(sys.argv[1:])
