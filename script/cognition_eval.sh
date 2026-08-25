#!/usr/bin/env bash
set -euo pipefail

# Parameterized manual cognition/organism eval sampler.
#
#   script/cognition_eval.sh organism  [OUT]   # baseline + 4 scenarios + clear
#   script/cognition_eval.sh cognition [OUT]   # one locked, 256-capped sample
#
# Both modes are MANUAL dogfood samplers: no timer, launch agent, cognition
# wake, or model call is created. Run at chosen checkpoints across real
# days/restarts. The thin wrappers `organism_longitudinal_eval.sh` and
# `cognition_event_driven_eval.sh` preserve the historical names/entry points
# (organism_doctor.sh and the docs call them directly).
#
# Env (per mode, indirect via the mode's prefix):
#   organism:  NATIVE_AGENT_ORGANISM_EVAL_{RUN_ID,DAY_INDEX,NOTE}
#   cognition: NATIVE_AGENT_COGNITION_EVAL_{RUN_ID,DAY_INDEX,NOTE}

MODE="${1:?usage: cognition_eval.sh <organism|cognition> [OUT]}"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

case "$MODE" in
  organism)
    ENV_PREFIX="NATIVE_AGENT_ORGANISM_EVAL"
    DEFAULT_OUT="data/cognition/organism_longitudinal_eval.jsonl"
    ;;
  cognition)
    ENV_PREFIX="NATIVE_AGENT_COGNITION_EVAL"
    DEFAULT_OUT="dist/evidence/living-fabric/cognition-event-driven-eval.jsonl"
    ;;
  *)
    echo "unknown mode: $MODE (expected organism|cognition)" >&2
    exit 2
    ;;
esac

OUT="${1:-$DEFAULT_OUT}"
_runid_var="${ENV_PREFIX}_RUN_ID"
_dayidx_var="${ENV_PREFIX}_DAY_INDEX"
_note_var="${ENV_PREFIX}_NOTE"
RUN_ID="${!_runid_var:-$(date -u +%Y%m%dT%H%M%SZ)}"
DAY_INDEX="${!_dayidx_var:-0}"
NOTE="${!_note_var:-}"

if [[ ! "$DAY_INDEX" =~ ^[0-9]+$ ]]; then
  echo "${_dayidx_var} must be a non-negative integer (got '$DAY_INDEX')" >&2
  exit 2
fi

require_cmds() {
  for command in "$@"; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "$command is required" >&2
      exit 2
    fi
  done
}

state_json() {
  local response
  response="$(curl -fsS --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$BASE_URL/codex/state")"
  if ! jq -ce '
      [
        (type == "object"),
        (.organism | type == "object"),
        (.cognition | type == "object"),
        (.cognition.microcycle | type == "object"),
        (.contextFlow | type == "object"),
        (.contextFlow.mode | type == "string")
      ] | all
    ' <<<"$response"; then
    echo "bridge state is incomplete or malformed" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

run_organism() {
  require_cmds jq curl
  nativeagent_bridge_resolve
  mkdir -p "$(dirname "$OUT")"

  debug_json() {
    local body="$1"
    local expected_status="$2"
    local response
    response="$(curl -fsS --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -X POST \
      --data "$body" \
      "$BASE_URL/codex/organism/debug")"
    if ! jq -e --arg expectedStatus "$expected_status" '
        [
          (type == "object"),
          (.status == $expectedStatus),
          (.error | not)
        ] | all
      ' <<<"$response" >/dev/null; then
      echo "organism debug response did not confirm status '$expected_status'" >&2
      return 1
    fi
  }

  record() {
    local label="$1"
    local sample_kind="scenario"
    if [ "$label" = "baseline" ] || [ "$label" = "cleared" ]; then
      sample_kind="$label"
    fi
    jq -c \
      --arg label "$label" \
      --arg sampleKind "$sample_kind" \
      --arg runId "$RUN_ID" \
      --arg dayIndex "$DAY_INDEX" \
      --arg note "$NOTE" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {
        at: $at,
        runId: $runId,
        dayIndex: ($dayIndex | tonumber),
        label: $label,
        sampleKind: $sampleKind,
        note: (if $note == "" then null else $note end),
        enabled: .organism.enabled,
        signalCount: .organism.signalCount,
        bodySchema: .organism.bodySchema,
        prediction: .organism.prediction,
        dreamRepair: .organism.dreamRepair,
        reflex: .organism.reflex,
        behavior: .organism.behavior,
        lastInjectedCapsule: .cognition.lastInjectedCapsule
      }' >>"$OUT"
  }

  state_json | record "baseline"

  for scenario in provider_brittle stale_phone resource_tight approval_closed; do
    body="$(jq -n --arg scenario "$scenario" '{scenario:$scenario, ttlSeconds:45}')"
    debug_json "$body" "active"
    state_json | record "scenario:$scenario"
  done

  debug_json '{"action":"clear"}' "cleared"
  state_json | record "cleared"

  echo "wrote $OUT"
  echo "runId=$RUN_ID dayIndex=$DAY_INDEX"
}

run_cognition() {
  # Each row records process/runtime identity so restarts cannot masquerade as
  # one uninterrupted sample.
  require_cmds jq curl ps
  nativeagent_bridge_resolve
  STATE="$(state_json)"

  PID_VALUE="$(jq -r '.cognition.microcycle.processIdentifier // empty' <<<"$STATE")"
  CPU=""
  if [[ "$PID_VALUE" =~ ^[0-9]+$ ]]; then
    CPU="$(ps -p "$PID_VALUE" -o %cpu= 2>/dev/null | tr -d ' ' || true)"
  fi

  mkdir -p "$(dirname "$OUT")"
  LOCK_DIR="${OUT}.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "another cognition sampler owns $LOCK_DIR" >&2
    exit 1
  fi
  TMP="${OUT}.tmp.$$"
  trap 'rm -rf "$LOCK_DIR" "$TMP"' EXIT

  ROW="$(jq -nc \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg runId "$RUN_ID" \
    --arg dayIndex "$DAY_INDEX" \
    --arg note "$NOTE" \
    --arg cpu "$CPU" \
    --argjson state "$STATE" '
    {
      schema: "cognition.event-driven.eval.v1",
      at: $at,
      runId: $runId,
      dayIndex: ($dayIndex | tonumber),
      note: (if $note == "" then null else $note end),
      processCpuPercent: ($cpu | tonumber?),
      appUptimeSeconds: $state.uptimeSeconds,
      microcycle: $state.cognition.microcycle,
      organismSignalCount: $state.organism.signalCount,
      contextFlow: {
        mode: $state.contextFlow.mode,
        storeGeneration: $state.contextFlow.storeGeneration,
        arenaGeneration: $state.contextFlow.arenaGeneration,
        degradedSources: $state.contextFlow.degradedSources,
        pressure: $state.contextFlow.pressure
      }
    }')"

  # Manual evidence only: bounded to 256 rows and serialized by the lock above.
  # This is an eval artifact, never canonical cognition tissue.
  if [ -f "$OUT" ]; then
    tail -n 255 "$OUT" >"$TMP"
  fi
  printf '%s\n' "$ROW" >>"$TMP"
  mv "$TMP" "$OUT"

  echo "wrote one manual sample to $OUT"
  echo "runId=$RUN_ID dayIndex=$DAY_INDEX"
}

case "$MODE" in
  organism)  run_organism ;;
  cognition) run_cognition ;;
esac
