#!/usr/bin/env bash
# Passive live-run watch for the Organism Kernel.
# Samples the running app's organism state on an interval and appends one compact
# JSON line per sample to a JSONL. No simulation, no mutation — pure observation,
# so it captures NATURAL body lines + loop-budget decisions as User uses Agent.
#
# usage: script/organism_watch.sh [intervalSeconds] [maxSamples] [outPath]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

INTERVAL="${1:-300}"
MAX="${2:-48}"
OUT="${3:-data/cognition/organism_watch.jsonl}"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
nativeagent_bridge_resolve || exit 1
mkdir -p "$(dirname "$OUT")"

sample() {
  local at; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local raw
  raw="$(curl -sS --max-time 25 -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" "$BASE_URL/codex/state" 2>/dev/null)"
  if [ -z "$raw" ]; then
    # Never fail silently: record the gap so a dead bridge is distinguishable from a quiet one.
    jq -cn --arg at "$at" '{at:$at, ok:false, reason:"bridge_unreachable"}' >>"$OUT"
    return
  fi
  echo "$raw" | jq -c --arg at "$at" '{
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
  }' >>"$OUT" 2>/dev/null \
    || jq -cn --arg at "$at" '{at:$at, ok:false, reason:"parse_error"}' >>"$OUT"
}

echo "organism_watch: interval=${INTERVAL}s max=${MAX} out=${OUT}"
i=0
while [ "$i" -lt "$MAX" ]; do
  sample
  i=$((i+1))
  [ "$i" -lt "$MAX" ] && sleep "$INTERVAL"
done
echo "organism_watch: done ($i samples) -> $OUT"
