#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

DATA_ROOT="${NATIVE_AGENT_DATA_ROOT:-$REPO_ROOT/data}"
ORGANISM_STATE_PATH="${NATIVE_AGENT_ORGANISM_STATE_PATH:-$DATA_ROOT/cognition/organism_state.json}"
EVAL_PATH="${NATIVE_AGENT_ORGANISM_EVAL_PATH:-$DATA_ROOT/cognition/organism_longitudinal_eval.jsonl}"
IOS_SNAPSHOT_PATH="${NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT:-}"
RUN_SIMULATION=0
STRICT=0
FAIL_COUNT=0

usage() {
  cat >&2 <<'USAGE'
usage:
  script/organism_doctor.sh [--simulate] [--strict]

Checks live NativeAgent organism health through:
  - NativeAgentApp process
  - local bridge /codex/state
  - persisted data/cognition/organism_state.json
  - optional iOS organism_living_status.json snapshot
  - optional longitudinal eval JSONL

Environment overrides:
  NATIVE_AGENT_BRIDGE_URL
  NATIVE_AGENT_BRIDGE_TOKEN
  NATIVE_AGENT_DATA_ROOT
  NATIVE_AGENT_ORGANISM_STATE_PATH
  NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT
  NATIVE_AGENT_ORGANISM_EVAL_PATH

--simulate also runs the safe body-scenario proof loop and clears it after.
--strict exits nonzero when any check reports FAIL; warnings stay diagnostic.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --simulate) RUN_SIMULATION=1 ;;
    --strict) STRICT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi
TOKEN=""
BRIDGE_CREDENTIAL_PATH="${NATIVE_AGENT_BRIDGE_TOKEN:-$HOME/.config/claude-bridge/token}"
nativeagent_bridge_resolve >/dev/null 2>&1 || true

status() {
  local level="$1"
  local name="$2"
  local detail="${3:-}"
  if [ "$level" = "FAIL" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  printf '[%-4s] %-30s %s\n' "$level" "$name" "$detail"
}

section() {
  printf '\n## %s\n' "$1"
}

state_json() {
  local out="$1"
  [ -n "$TOKEN" ] || return 2
  curl -fsS --max-time 15 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$BASE_URL/codex/state" >"$out"
}

find_ios_snapshot() {
  if [ -n "$IOS_SNAPSHOT_PATH" ]; then
    printf '%s\n' "$IOS_SNAPSHOT_PATH"
    return 0
  fi
  if command -v mdfind >/dev/null 2>&1; then
    mdfind 'kMDItemFSName == "organism_living_status.json"' | head -n 1
    return 0
  fi
  return 1
}

bool_status() {
  local value="$1"
  local name="$2"
  local fail_detail="$3"
  if [ "$value" = "true" ]; then
    status PASS "$name" "true"
  else
    status WARN "$name" "$fail_detail"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
state_file="$tmpdir/bridge_state.json"

echo "# NativeAgent Organism Doctor"
echo "generatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "repo=$REPO_ROOT"
echo "dataRoot=$DATA_ROOT"

section "Process"
if pgrep -f 'NativeAgent.app/Contents/MacOS/NativeAgentApp' >/dev/null 2>&1; then
  pid="$(pgrep -f 'NativeAgent.app/Contents/MacOS/NativeAgentApp' | head -n 1)"
  status PASS "NativeAgentApp process" "pid=$pid"
else
  status FAIL "NativeAgentApp process" "not running; run ./script/install_app.sh"
fi

section "Bridge"
bridge_rc=0
state_json "$state_file" || bridge_rc=$?
if [ "$bridge_rc" -eq 0 ]; then
  status PASS "bridge state" "$BASE_URL/codex/state"
  chat_ready="$(jq -r '.chatReady // false' "$state_file")"
  organism_enabled="$(jq -r '.organism.enabled // false' "$state_file")"
  active_model="$(jq -r '.activeModel // "unknown"' "$state_file")"
  running_revision="$(jq -r '.buildIdentity.exactSourceRevision // empty' "$state_file")"
  # jq's `//` treats Boolean false as absent, which would invert a genuinely
  # clean bundle into dirty. Preserve exact Boolean false and fail closed only
  # when the field is missing or malformed.
  running_dirty="$(jq -r 'if (.buildIdentity.sourceDirty | type) == "boolean" then .buildIdentity.sourceDirty else true end' "$state_file")"
  repo_revision="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  posture="$(jq -r '.organism.behavior.posture // "unknown"' "$state_file")"
  claims="$(jq -r '.organism.behavior.toolClaims // "unknown"' "$state_file")"
  strategy="$(jq -r '.organism.behavior.toolStrategy // "unknown"' "$state_file")"
  loop_budget="$(jq -r '.organism.behavior.loopBudget // "unknown"' "$state_file")"
  signal_count="$(jq -r '.organism.signalCount // 0' "$state_file")"
  body_line="$(jq -r '.organism.promptVisibleBodyLine // "quiet"' "$state_file")"
  review_count="$(jq -r '.organism.reflex.reviewRequiredCount // 0' "$state_file")"
  approved_biases="$(jq -r '.organism.reflex.approvedLowRiskCount // 0' "$state_file")"
  dream_proposals="$(jq -r '.organism.dreamRepair.proposedStandingViews // 0' "$state_file")"
  evidence_count="$(jq -r '(.organism.dreamRepair.latestEvidence // []) | length' "$state_file")"
  candidate_count="$(jq -r '(.organism.reflex.candidates // []) | length' "$state_file")"

  bool_status "$chat_ready" "chat ready" "false; bridge can answer state but chat is not ready"
  if [ -n "$repo_revision" ] && [ "$running_dirty" = "false" ] && [ "$running_revision" = "$repo_revision" ]; then
    status PASS "exact running build" "$running_revision"
  else
    status FAIL "exact running build" "repo=$repo_revision running=${running_revision:-unknown} dirty=$running_dirty; reinstall the committed source"
  fi
  bool_status "$organism_enabled" "organism enabled" "false; check public-safe/onboarding flag or organismKernelEnabled"
  status INFO "active model" "$active_model"
  status INFO "behavior posture" "posture=$posture claims=$claims strategy=$strategy loops=$loop_budget"
  status INFO "body line" "$body_line"
  status INFO "organism counters" "signals=$signal_count candidates=$candidate_count reviews=$review_count approvedBiases=$approved_biases dreamEvidence=$evidence_count dreamProposals=$dream_proposals"

  providers="$(jq -r '.organism.bodySchema.providersHealthy // false' "$state_file")"
  tools="$(jq -r '.organism.bodySchema.toolHandsAvailable // false' "$state_file")"
  phone="$(jq -r '.organism.bodySchema.iPhoneReachable // false' "$state_file")"
  notifications="$(jq -r '.organism.bodySchema.notificationPathHealthy // false' "$state_file")"
  approvals="$(jq -r '.organism.bodySchema.approvalChannelsOpen // false' "$state_file")"
  memory="$(jq -r '.organism.bodySchema.memoryHealthy // false' "$state_file")"
  resource="$(jq -r '.organism.bodySchema.resourcePressure // "unknown"' "$state_file")"

  bool_status "$providers" "providers healthy" "false; expect careful/verify posture"
  bool_status "$tools" "tools available" "false; expect careful/verify posture"
  bool_status "$approvals" "approval path open" "false; expect approval-bound posture"
  bool_status "$memory" "memory healthy" "false; expect context-first posture"
  if [ "$phone" = "true" ] && [ "$notifications" = "true" ]; then
    status PASS "phone/notification path" "reachable"
  else
    status WARN "phone/notification path" "phone=$phone notifications=$notifications; expect receipt-required posture"
  fi
  if [ "$resource" = "nominal" ]; then
    status PASS "resource pressure" "$resource"
  else
    status WARN "resource pressure" "$resource; expect conserve/sleep loop budget"
  fi

  last_signal_age="$(jq -r 'if .organism.lastSignalAt == null then "unknown" else ((now - (.organism.lastSignalAt | fromdateiso8601)) | floor | tostring) end' "$state_file" 2>/dev/null || echo unknown)"
  status INFO "last signal age" "${last_signal_age}s"
else
  if [ "$bridge_rc" -eq 2 ]; then
    status FAIL "bridge credential" "not readable at $BRIDGE_CREDENTIAL_PATH"
  else
    status FAIL "bridge state" "cannot reach $BASE_URL/codex/state"
  fi
fi

section "Persistence"
if [ -f "$ORGANISM_STATE_PATH" ]; then
  if jq empty "$ORGANISM_STATE_PATH" >/dev/null 2>&1; then
    schema="$(jq -r '.schemaVersion // "unknown"' "$ORGANISM_STATE_PATH")"
    saved_at="$(jq -r '.savedAt // "unknown"' "$ORGANISM_STATE_PATH")"
    persisted_signals="$(jq -r '.signalCount // 0' "$ORGANISM_STATE_PATH")"
    field_nodes="$(jq -r '(.field.nodes // {}) | length' "$ORGANISM_STATE_PATH")"
    reflex_candidates="$(jq -r '(.reflexState.candidates // {}) | length' "$ORGANISM_STATE_PATH")"
    status PASS "organism_state.json" "schema=$schema savedAt=$saved_at signals=$persisted_signals fieldNodes=$field_nodes reflexCandidates=$reflex_candidates"
  else
    status FAIL "organism_state.json" "exists but is not valid JSON: $ORGANISM_STATE_PATH"
  fi
else
  status WARN "organism_state.json" "missing at $ORGANISM_STATE_PATH; app may not have persisted since enable/reset"
fi

section "iOS Snapshot"
snapshot_path="$(find_ios_snapshot || true)"
if [ -n "$snapshot_path" ] && [ -f "$snapshot_path" ]; then
  if jq empty "$snapshot_path" >/dev/null 2>&1; then
    generated="$(jq -r '.generatedAt // "unknown"' "$snapshot_path")"
    ios_posture="$(jq -r '.posture // "unknown"' "$snapshot_path")"
    ios_reviews="$(jq -r '.counters.reflexesNeedReview // 0' "$snapshot_path")"
    ios_biases="$(jq -r '.counters.approvedReflexBiases // 0' "$snapshot_path")"
    ios_candidates="$(jq -r '(.reflexCandidates // []) | length' "$snapshot_path")"
    ios_proposals="$(jq -r '(.standingViewProposals // []) | length' "$snapshot_path")"
    status PASS "organism_living_status" "generatedAt=$generated posture=$ios_posture reviews=$ios_reviews biases=$ios_biases candidates=$ios_candidates proposals=$ios_proposals"
    status INFO "snapshot path" "$snapshot_path"
  else
    status FAIL "organism_living_status" "found but invalid JSON: $snapshot_path"
  fi
else
  status INFO "organism_living_status" "not found; set NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT to inspect iOS snapshot directly"
fi

section "Longitudinal Eval"
if [ -f "$EVAL_PATH" ]; then
  eval_lines="$(wc -l <"$EVAL_PATH" | tr -d ' ')"
  last_eval="$(tail -n 1 "$EVAL_PATH")"
  last_run="$(printf '%s\n' "$last_eval" | jq -r '.runId // "unknown"' 2>/dev/null || echo unknown)"
  last_day="$(printf '%s\n' "$last_eval" | jq -r '.dayIndex // "unknown"' 2>/dev/null || echo unknown)"
  last_label="$(printf '%s\n' "$last_eval" | jq -r '.label // "unknown"' 2>/dev/null || echo unknown)"
  unique_days="$(jq -r '.dayIndex // empty' "$EVAL_PATH" 2>/dev/null | sort -nu | wc -l | tr -d ' ')"
  status PASS "eval JSONL" "lines=$eval_lines lastRun=$last_run lastDay=$last_day lastLabel=$last_label uniqueDays=$unique_days"
  if [ "${unique_days:-0}" -lt 2 ]; then
    status INFO "multi-day proof" "harness exists, but fewer than 2 distinct dayIndex values"
  fi
else
  status INFO "eval JSONL" "missing at $EVAL_PATH; run script/organism_longitudinal_eval.sh"
fi

if [ "$RUN_SIMULATION" -eq 1 ]; then
  section "Simulation Proof"
  sim_out="$tmpdir/organism_doctor_eval.jsonl"
  NATIVE_AGENT_ORGANISM_EVAL_RUN_ID="doctor-$(date -u +%Y%m%dT%H%M%SZ)" \
  NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX=0 \
  NATIVE_AGENT_ORGANISM_EVAL_NOTE="doctor" \
    "$REPO_ROOT/script/organism_longitudinal_eval.sh" "$sim_out" >/dev/null
  jq -r '"label=\(.label) posture=\(.behavior.posture // "unknown") claims=\(.behavior.toolClaims // "unknown") strategy=\(.behavior.toolStrategy // "unknown") loops=\(.behavior.loopBudget // "unknown")"' "$sim_out"
  status PASS "simulation cleared" "longitudinal eval clears debug override at end"
fi

section "Next Troubleshooting Step"
if [ "$bridge_rc" -ne 0 ]; then
  echo "Start/reinstall the app: $REPO_ROOT/script/install_app.sh"
elif [ -f "$ORGANISM_STATE_PATH" ] && [ "$RUN_SIMULATION" -eq 0 ]; then
  echo "Run $REPO_ROOT/script/organism_doctor.sh --simulate to verify posture deltas."
else
  echo "Open $REPO_ROOT/docs/build_plans/nativeagent-organism-troubleshooting.md for symptom-specific checks."
fi

if [ "$STRICT" -eq 1 ] && [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
