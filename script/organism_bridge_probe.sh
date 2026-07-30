#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"
SIMULATION_ACTIVE=0

clear_simulation_on_exit() {
  if [ "$SIMULATION_ACTIVE" -eq 1 ]; then
    debug_json '{"action":"clear"}' >/dev/null 2>&1 || true
  fi
}

trap clear_simulation_on_exit EXIT
trap 'exit 130' INT TERM

usage() {
  cat >&2 <<'USAGE'
usage:
  script/organism_bridge_probe.sh state
  script/organism_bridge_probe.sh clear
  script/organism_bridge_probe.sh simulate <scenario> [message]

scenarios:
  provider_brittle
  stale_phone
  resource_tight
  memory_brittle
  approval_closed

examples:
  script/organism_bridge_probe.sh state
  script/organism_bridge_probe.sh simulate provider_brittle
  script/organism_bridge_probe.sh simulate provider_brittle "Body check: answer from your current context."
USAGE
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

nativeagent_bridge_resolve

state_json() {
  curl -sS --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$BASE_URL/codex/state"
}

debug_json() {
  local body="$1"
  curl -sS --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -X POST \
    --data "$body" \
    "$BASE_URL/codex/organism/debug"
}

send_json() {
  local message="$1"
  local session_id="$2"
  local body
  body="$(jq -n --arg text "$message" --arg sender "claude" --arg sid "$session_id" \
    '{text:$text,sender:$sender,sessionId:$sid}')"
  curl -sS --max-time "${AGENT_BRIDGE_MAX_TIME:-700}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -X POST \
    --data "$body" \
    "$BASE_URL/claude/message"
}

organism_summary='{
  activeModel,
  activeSessionId,
  chatReady,
  organism: {
    enabled: .organism.enabled,
    signalCount: .organism.signalCount,
    lastSignalAt: .organism.lastSignalAt,
    hasPromptVisibleBodyLine: .organism.hasPromptVisibleBodyLine,
    promptVisibleBodyLine: .organism.promptVisibleBodyLine,
    bodySchema: .organism.bodySchema,
    chemicalState: .organism.chemicalState,
    field: .organism.field,
    prediction: .organism.prediction,
    dreamRepair: .organism.dreamRepair,
    reflex: .organism.reflex,
    behavior: .organism.behavior
  },
  cognition: {
    lastInjectedCapsule: .cognition.lastInjectedCapsule
  }
}'

debug_summary='{
  status,
  debug,
  organism: {
    enabled: .organism.enabled,
    signalCount: .organism.signalCount,
    hasPromptVisibleBodyLine: .organism.hasPromptVisibleBodyLine,
    promptVisibleBodyLine: .organism.promptVisibleBodyLine,
    bodySchema: .organism.bodySchema,
    chemicalState: .organism.chemicalState,
    field: .organism.field,
    prediction: .organism.prediction,
    dreamRepair: .organism.dreamRepair,
    reflex: .organism.reflex,
    behavior: .organism.behavior
  }
}'

cmd="${1:-state}"
case "$cmd" in
  state)
    state_json | jq "$organism_summary"
    ;;
  clear)
    debug_json '{"action":"clear"}' | jq "$debug_summary"
    ;;
  simulate)
    scenario="${2:-}"
    message="${3:-}"
    if [ -z "$scenario" ]; then
      usage
      exit 2
    fi

    echo "== before =="
    state_json | jq "$organism_summary"

    echo "== simulation: $scenario =="
    body="$(jq -n --arg scenario "$scenario" --argjson ttl 120 \
      '{scenario:$scenario, ttlSeconds:$ttl}')"
    SIMULATION_ACTIVE=1
    debug_json "$body" | jq "$debug_summary"

    echo "== after simulation =="
    state_json | jq "$organism_summary"

    if [ -n "$message" ]; then
      echo "== agent bridge turn =="
      session_id="organism-live-check-$(date +%s)"
      send_json "$message" "$session_id" | jq '{status, model, sessionId, reply}'

      echo "== after turn =="
      state_json | jq "$organism_summary"
    fi

    echo "== clear simulation =="
    debug_json '{"action":"clear"}' | jq "$debug_summary"
    SIMULATION_ACTIVE=0

    echo "== after clear =="
    state_json | jq "$organism_summary"
    ;;
  *)
    usage
    exit 2
    ;;
esac
