#!/bin/bash
# u1_baseline.sh — U1 performance-core measurement harness (MANUAL/DEV ONLY,
# not CI). Replays a fixed 6-turn scripted conversation through the REAL
# Swift chat path (chat-drive → makeChatOrchestrationClient → live provider
# adapters → REAL provider calls against the live app data root), then
# summarizes the per-call `llm.call` telemetry rows the U1 step-1 adapters
# write to <dataRoot>/traces/events.jsonl.
#
# Run BEFORE flipping a caching step to capture a baseline, and again AFTER
# to capture the delta (cache_read_input_tokens > 0, input token drop, TTFT).
#
# Usage:
#   script/u1_baseline.sh [--session <id>] [--surface chat] [--label baseline]
#
# Requirements: provider credentials on the live data root (OAuth tokens or
# api keys) — this makes ~6 real model calls and costs real tokens.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO_ROOT/Modules/NativeAgentCore"
LABEL="baseline"
SURFACE="chat"
SESSION="u1-replay-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --surface) SURFACE="$2"; shift 2 ;;
    --label)   LABEL="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

echo "[u1] building chat-drive..."
swift build --package-path "$PKG" --product chat-drive --scratch-path /tmp/u1-baseline-scratch >/dev/null
CHAT_DRIVE="$(swift build --package-path "$PKG" --product chat-drive --scratch-path /tmp/u1-baseline-scratch --show-bin-path)/chat-drive"

# Resolve the data root the same way the runtime does (env override wins;
# dev checkout falls back to <repo>/data).
DATA_ROOT="${NATIVE_AGENT_DATA_ROOT:-$REPO_ROOT/data}"
EVENTS="$DATA_ROOT/traces/events.jsonl"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[u1] label=$LABEL session=$SESSION surface=$SURFACE"
echo "[u1] data root: $DATA_ROOT"
echo "[u1] trace feed: $EVENTS"

# Fixed 6-turn scripted conversation. Stable wording — byte-identical
# prefixes across runs are what make before/after cache numbers comparable.
TURNS=(
  "Hi — quick check-in. In one sentence, what can you help me with today?"
  "List three things you remember about my projects. Keep it brief."
  "Pick one of those three and explain why it matters, in two sentences."
  "What tools do you have available right now? Just name five."
  "Summarize our conversation so far in one sentence."
  "Thanks — say goodbye in exactly four words."
)

i=0
for turn in "${TURNS[@]}"; do
  i=$((i+1))
  echo ""
  echo "[u1] ---- turn $i/6 ----"
  NA_CHAT_SESSION="$SESSION" "$CHAT_DRIVE" chat --surface "$SURFACE" "$turn" || {
    echo "[u1] turn $i FAILED — continuing so partial telemetry still prints" >&2
  }
done

echo ""
echo "[u1] ==== llm.call rows since $START_TS ($LABEL) ===="
swift - "$EVENTS" "$START_TS" <<'SWIFT'
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: swift - <events> <start-ts>")
    exit(64)
}
let path = args[1]
let startTS = args[2]

func left(_ value: String, _ width: Int) -> String {
    let clipped = String(value.prefix(width))
    return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
}

func right(_ value: String, _ width: Int) -> String {
    let clipped = String(value.prefix(width))
    return String(repeating: " ", count: max(0, width - clipped.count)) + clipped
}

func intValue(_ value: Any?) -> Int {
    switch value {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s) ?? 0
    default: return 0
    }
}

func field(_ payload: [String: Any], _ key: String, fallback: String = "-") -> String {
    guard let value = payload[key] else { return fallback }
    if value is NSNull { return fallback }
    return "\(value)"
}

let raw: String
do {
    raw = try String(contentsOfFile: path, encoding: .utf8)
} catch {
    print("no trace file at \(path)")
    exit(1)
}

let rows: [[String: Any]] = raw
    .split(separator: "\n", omittingEmptySubsequences: true)
    .compactMap { line -> [String: Any]? in
        guard let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["kind"] as? String == "llm.call",
              (obj["createdAt"] as? String ?? "") >= startTS else {
            return nil
        }
        return obj
    }

if rows.isEmpty {
    print("NO llm.call rows captured — check provider creds / telemetry wiring")
    exit(1)
}

var totals = [
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheReadInputTokens": 0,
    "cacheCreationInputTokens": 0,
    "durationMs": 0,
]
var ttfts: [Int] = []

print("\(left("provider", 24)) \(left("model", 20)) \(right("in", 7)) \(right("out", 6)) \(right("cacheRd", 8)) \(right("cacheWr", 8)) \(right("ttft", 6)) \(right("dur", 7))")

for row in rows {
    let payload = row["payload"] as? [String: Any] ?? [:]
    for key in totals.keys {
        totals[key, default: 0] += intValue(payload[key])
    }
    if let value = payload["ttftMs"], !(value is NSNull) {
        ttfts.append(intValue(value))
    }
    print("\(left(field(payload, "provider", fallback: "?"), 24)) \(left(field(payload, "model", fallback: "?"), 20)) \(right(field(payload, "inputTokens"), 7)) \(right(field(payload, "outputTokens"), 6)) \(right(field(payload, "cacheReadInputTokens"), 8)) \(right(field(payload, "cacheCreationInputTokens"), 8)) \(right(field(payload, "ttftMs"), 6)) \(right(field(payload, "durationMs"), 7))")
}

let input = totals["inputTokens", default: 0]
let output = totals["outputTokens", default: 0]
let cacheRead = totals["cacheReadInputTokens", default: 0]
let cacheWrite = totals["cacheCreationInputTokens", default: 0]
let duration = totals["durationMs", default: 0]
let denom = input + cacheRead + cacheWrite
let hit = denom == 0 ? 0.0 : (100.0 * Double(cacheRead) / Double(denom))
let avgTTFT = ttfts.isEmpty ? nil : Double(ttfts.reduce(0, +)) / Double(ttfts.count)

print(String(repeating: "-", count: 92))
print("calls=\(rows.count)  inputTokens=\(input)  outputTokens=\(output)  cacheRead=\(cacheRead)  cacheWrite=\(cacheWrite)")
let ttftText = avgTTFT.map { "\(Int($0.rounded()))ms" } ?? "n/a"
print(String(format: "cache-hit-rate=%.1f%%  avgTTFT=%@  totalDuration=%dms", hit, ttftText, duration))
SWIFT

echo ""
echo "[u1] done. Re-run with the SAME prompts after each caching step and diff the summaries."
