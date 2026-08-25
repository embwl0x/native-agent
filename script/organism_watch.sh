#!/usr/bin/env bash
# Passive live-run watch for the Organism Kernel.
# Samples the running app's organism state on an interval and appends one compact
# JSON line per sample to a JSONL. No simulation, no mutation — pure observation,
# so it captures NATURAL body lines + loop-budget decisions as User uses Agent.
#
# usage: script/organism_watch.sh [intervalSeconds] [maxSamples] [outPath]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

INTERVAL="${1:-300}"
MAX="${2:-48}"
OUT="${3:-data/cognition/organism_watch.jsonl}"
MAX_ROWS="${NATIVE_AGENT_ORGANISM_WATCH_MAX_ROWS:-10000}"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[[ "$MAX_ROWS" =~ ^[1-9][0-9]*$ ]] || {
  echo "NATIVE_AGENT_ORGANISM_WATCH_MAX_ROWS must be a positive integer" >&2
  exit 2
}
nativeagent_bridge_resolve || exit 1
mkdir -p "$(dirname "$OUT")"

# A watch file is a single append-only timeline.  Concurrent writers would
# interleave samples and make it impossible to reason about the order, so own
# the adjacent mkdir lock for this invocation.  The lock is deliberately a
# directory: creation is atomic and stale/operator-visible locks fail closed.
LOCK_DIR="${OUT}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "organism_watch: writer lock already held at $LOCK_DIR" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

append_sample() {
  local line="$1"
  local keep=$((MAX_ROWS - 1))
  local count=0

  if [ -f "$OUT" ]; then
    count="$(wc -l <"$OUT" | tr -d ' ')"
    if [ "$count" -gt "$keep" ]; then
      local compacted
      compacted="$(mktemp "${OUT}.compact.XXXXXX")"
      tail -n "$keep" "$OUT" >"$compacted"
      mv "$compacted" "$OUT"
    fi
  fi
  printf '%s\n' "$line" >>"$OUT"
}

sample() {
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local raw
  # A transport failure is an observation, not a reason to abandon the rest
  # of a long watch silently.  Preserve it as the explicit unreachable row.
  raw="$(curl -sS --max-time 25 -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" "$BASE_URL/codex/state" 2>/dev/null || true)"
  if [ -z "$raw" ]; then
    # Never fail silently: record the gap so a dead bridge is distinguishable from a quiet one.
    append_sample "$(jq -cn --arg at "$at" '{at:$at, ok:false, reason:"bridge_unreachable"}')"
    return
  fi
  local line
  if line="$(printf '%s\n' "$raw" | jq -c --arg at "$at" '{
    at:$at, ok:true,
    enabled:.organism.enabled,
    signalCount:.organism.signalCount,
    lastSignalAt:.organism.lastSignalAt,
    hasBodyLine:.organism.hasPromptVisibleBodyLine,
    bodyLine:.organism.promptVisibleBodyLine,
    posture:.organism.behavior.posture,
    loopBudget:.organism.behavior.loopBudget,
    tools:.organism.behavior.toolStrategy,
    health:.organism.bodySchema,
    felt:{coherence:.organism.chemicalState.coherence, confidence:.organism.chemicalState.confidence, vigilance:.organism.chemicalState.vigilance, fatigue:.organism.chemicalState.fatigue, urgency:.organism.chemicalState.urgency, warmth:.organism.chemicalState.warmth}
  }' 2>/dev/null)"; then
    append_sample "$line"
  else
    append_sample "$(jq -cn --arg at "$at" '{at:$at, ok:false, reason:"parse_error"}')"
  fi
}

echo "organism_watch: interval=${INTERVAL}s max=${MAX} retention=${MAX_ROWS} out=${OUT}"
i=0
while [ "$i" -lt "$MAX" ]; do
  sample
  i=$((i+1))
  [ "$i" -lt "$MAX" ] && sleep "$INTERVAL"
done
echo "organism_watch: done ($i samples) -> $OUT"
