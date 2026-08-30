#!/usr/bin/env bash
#
# Black-box behavioral evals for the script rows that were deliberately left
# uncovered in the total-surface ledger.  This file is intentionally an audit:
# a GAP is a failing release-quality assertion, not a passing source grep.
#
# It never reads or writes the resident data root.  Every command that can
# mutate state runs from a fresh temp root behind stubbed bridge/tool commands.
# Run directly while closing the campaign:
#
#   tests/scripts/total_script_behavior_evals_test.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-script-behavior.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS_ROWS=()
GAPS=()

pass() {
  PASS_ROWS+=("$1")
  printf 'PASS  %s — %s\n' "$1" "$2"
}

gap() {
  GAPS+=("$1")
  printf 'GAP   %s — %s\n' "$1" "$2" >&2
}

expect_failure() {
  local label="$1"
  shift
  local rc=0
  "$@" >"$TMP/$label.out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

write_executable() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" >"$path"
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# scripts.smoke_all.toolDispatchSteps
# ---------------------------------------------------------------------------
# The real smoke accepts an exit-0 JSON error/empty payload.  Run an isolated
# copy against a fake Swift toolchain that returns exactly those bad payloads;
# a healthy smoke must reject them and must keep its data root inside the clone.
SMOKE_ROOT="$TMP/smoke-root"
mkdir -p "$SMOKE_ROOT/script" "$SMOKE_ROOT/bin" "$SMOKE_ROOT/data"
cp "$ROOT/script/smoke_all.sh" "$SMOKE_ROOT/script/smoke_all.sh"
for check in check_architecture_blueprint.swift check_timer_inventory.swift check_persona_skill_hygiene.swift; do
  write_executable "$SMOKE_ROOT/script/$check" '#!/usr/bin/env bash' 'exit 0'
done
write_executable "$SMOKE_ROOT/bin/swift" \
  '#!/usr/bin/env bash' \
  'set -eu' \
  'printf "%s\\n" "$*" >> "$SMOKE_SWIFT_CALLS"' \
  'if [[ "$1" == "run" ]]; then' \
  '  case "${*: -2:1}" in' \
  '    get_persona_doc) printf "{}\\n" ;;' \
  '    list_skills) printf "{\\"skills\\":[]}\\n" ;;' \
  '    recall_memory) printf "{\\"records\\":[]}\\n" ;;' \
  '  esac' \
  'fi'
SMOKE_RC="$(expect_failure smoke-empty env PATH="$SMOKE_ROOT/bin:$PATH" SMOKE_SWIFT_CALLS="$TMP/smoke.swift.calls" NATIVE_AGENT_DATA_ROOT="$SMOKE_ROOT/data" "$SMOKE_ROOT/script/smoke_all.sh")"
if [[ "$SMOKE_RC" -ne 0 ]]; then
  pass "scripts.smoke_all.toolDispatchSteps" "empty/error tool payloads are rejected"
else
  gap "scripts.smoke_all.toolDispatchSteps" "exit 0 accepted empty persona, zero skills, and zero recalled records"
fi
if rg -q -- '--package-path .*/Modules/NativeAgentCore' "$TMP/smoke.swift.calls"; then :; fi

# ---------------------------------------------------------------------------
# scripts.check_timer_inventory.flag.printCandidates
# ---------------------------------------------------------------------------
# This runs the real executable against the real source tree but only observes
# stdout.  Its candidate stream must expose every primitive currently found so
# callers can inspect a changed timer API instead of receiving a decorative OK.
TIMER_OUT="$TMP/timer-candidates.out"
TIMER_RC=0
"$ROOT/script/check_timer_inventory.swift" --repo "$ROOT" --print-candidates >"$TIMER_OUT" 2>&1 || TIMER_RC=$?
if [[ "$TIMER_RC" -eq 0 ]] && [[ -s "$TIMER_OUT" ]] \
  && rg -q 'Task\.sleep\(|Timer\.|DispatchSource\.makeTimerSource\(' "$TIMER_OUT"; then
  pass "scripts.check_timer_inventory.flag.printCandidates" "candidate stream is nonempty and names production timer primitives"
else
  gap "scripts.check_timer_inventory.flag.printCandidates" "candidate mode did not expose the timer primitives present in production"
fi

# ---------------------------------------------------------------------------
# scripts.check_architecture_blueprint.staleInstructionScan
# ---------------------------------------------------------------------------
# Keep the fixture tiny and side-effect-free: source/document trees are linked
# read-only, while the sole operational instruction under test is copied and
# given a retired runtime command. The checker must name this exact active
# instruction rather than accepting it because architecture tables still match.
BLUEPRINT_FIXTURE="$TMP/blueprint-stale-instruction"
mkdir -p "$BLUEPRINT_FIXTURE/script"
for item in .codex docs iOS Modules Sources README.md SECURITY.md PROJECT_STATUS.md; do
  ln -s "$ROOT/$item" "$BLUEPRINT_FIXTURE/$item"
done
cp "$ROOT/AGENTS.md" "$BLUEPRINT_FIXTURE/AGENTS.md"
cp "$ROOT/script/smoke_all.sh" "$BLUEPRINT_FIXTURE/script/smoke_all.sh"
printf '\n# stale fixture: start daemon HTTP at 127.0.0.1:8765\n' >> "$BLUEPRINT_FIXTURE/script/smoke_all.sh"
BLUEPRINT_RC="$(expect_failure blueprint-stale-instruction "$ROOT/script/check_architecture_blueprint.swift" --repo "$BLUEPRINT_FIXTURE")"
if [[ "$BLUEPRINT_RC" -ne 0 ]] \
  && rg -q 'stale instruction \[retired-smoke-runtime\] script/smoke_all\.sh:.*retired daemon runtime' "$TMP/blueprint-stale-instruction.out"; then
  pass "scripts.check_architecture_blueprint.staleInstructionScan" "retired runtime guidance in the active smoke workflow is rejected with its location"
else
  gap "scripts.check_architecture_blueprint.staleInstructionScan" "stale daemon guidance in script/smoke_all.sh was not rejected by the architecture guard"
fi

# Helpers shared by bridge-backed scripts.  The resolver only requires an
# unreadable-to-production throwaway token; fake curl determines all responses.
make_bridge_home() {
  local home="$1"
  mkdir -p "$home/.config/claude-bridge"
  printf 'test-token\n' >"$home/.config/claude-bridge/token"
}

STATE_JSON='{"chatReady":true,"activeModel":"test","buildIdentity":{"exactSourceRevision":"0000000000000000000000000000000000000000","sourceDirty":false},"uptimeSeconds":1,"organism":{"enabled":true,"signalCount":1,"hasPromptVisibleBodyLine":true,"promptVisibleBodyLine":"present","bodySchema":{"providersHealthy":true,"toolHandsAvailable":true,"iPhoneReachable":true,"notificationPathHealthy":true,"approvalChannelsOpen":true,"memoryHealthy":true,"resourcePressure":"nominal"},"chemicalState":{"coherence":1,"confidence":1,"vigilance":1,"fatigue":0,"urgency":0,"warmth":1},"behavior":{"posture":"baseline","toolClaims":"normal","toolStrategy":"normal","loopBudget":"normal"},"prediction":{},"dreamRepair":{},"reflex":{},"field":{}},"cognition":{"microcycle":{"processIdentifier":null},"lastInjectedCapsule":null},"contextFlow":{"mode":"steady","storeGeneration":1,"arenaGeneration":1,"degradedSources":[],"pressure":"low"}}'

# ---------------------------------------------------------------------------
# scripts.cognition_eval.organism / cognition / env
# ---------------------------------------------------------------------------
COG_HOME="$TMP/cognition-home"
COG_BIN="$TMP/cognition-bin"
COG_OUT="$TMP/cognition/organism.jsonl"
make_bridge_home "$COG_HOME"
mkdir -p "$COG_BIN"
write_executable "$COG_BIN/curl" \
  '#!/usr/bin/env bash' \
  'set -eu' \
  'case "$*" in' \
  '  *"/codex/state"*) printf "%s\\n" "$FAKE_STATE_JSON" ;;' \
  '  *"/codex/organism/debug"*) printf "{\\"status\\":\\"server_error\\"}\\n" ;;' \
  'esac'

# A response carrying server_error with exit 0 models a proxy/body failure that
# curl's transport status cannot expose.  No scenario must be recorded after
# that response.
COG_ORG_RC="$(expect_failure cognition-organism-error env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX=7 "$ROOT/script/cognition_eval.sh" organism "$COG_OUT")"
if [[ "$COG_ORG_RC" -ne 0 ]] && rg -q "did not confirm status 'active'" "$TMP/cognition-organism-error.out" && [[ ! -f "$COG_OUT" || "$(wc -l < "$COG_OUT")" -eq 1 ]]; then
  pass "scripts.cognition_eval.organism" "non-success debug response aborts before scenario evidence is written"
else
  gap "scripts.cognition_eval.organism" "server_error response still exits success and records fabricated scenario rows"
fi
COG_ENV_RC="$(expect_failure cognition-invalid-day-index env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX=abc "$ROOT/script/cognition_eval.sh" organism "$TMP/cognition/invalid-day-index.jsonl")"
if [[ "$COG_ENV_RC" -ne 0 ]] && rg -q 'NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX must be a non-negative integer' "$TMP/cognition-invalid-day-index.out"; then
  pass "scripts.cognition_eval.env" "invalid DAY_INDEX is rejected"
else
  gap "scripts.cognition_eval.env" "DAY_INDEX=abc is accepted and coerced to dayIndex 0"
fi

# The historical organism entry point is deliberately only a wrapper. It must
# reject option-like/unknown mode input before any bridge call, preserve a hard
# failure without fabricating later evidence, and write its complete bounded
# six-row run when the bridge confirms every scenario.
LONGITUDINAL_OUT="$TMP/cognition/longitudinal-wrapper.jsonl"
LONGITUDINAL_RC="$(expect_failure organism-longitudinal-wrapper env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX=4 "$ROOT/script/organism_longitudinal_eval.sh" "$LONGITUDINAL_OUT")"
if [[ "$LONGITUDINAL_RC" -ne 0 ]] \
  && [[ "$(wc -l < "$LONGITUDINAL_OUT" | tr -d ' ')" -eq 1 ]] \
  && jq -e 'select(.runId != null and .dayIndex == 4 and .label == "baseline")' "$LONGITUDINAL_OUT" >/dev/null; then
  pass "scripts.organism_longitudinal_eval" "wrapper preserves a named failed scenario without fabricating later evidence"
else
  gap "scripts.organism_longitudinal_eval" "wrapper converts a failed organism scenario into success, loses run identity, or writes fabricated later evidence"
fi
LONGITUDINAL_UNKNOWN_LOG="$TMP/cognition/longitudinal-unknown.calls"
write_executable "$COG_BIN/curl" \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$LONGITUDINAL_UNKNOWN_LOG"' \
  'exit 99'
LONGITUDINAL_UNKNOWN_RC="$(expect_failure organism-longitudinal-unknown env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" LONGITUDINAL_UNKNOWN_LOG="$LONGITUDINAL_UNKNOWN_LOG" "$ROOT/script/organism_longitudinal_eval.sh" --not-a-mode)"
if [[ "$LONGITUDINAL_UNKNOWN_RC" -eq 2 ]] && [[ ! -s "$LONGITUDINAL_UNKNOWN_LOG" ]]; then
  pass "scripts.organism_longitudinal_eval" "unknown mode-like input exits 2 before any bridge request"
else
  gap "scripts.organism_longitudinal_eval" "unknown mode-like input reached the bridge or did not exit 2"
fi
write_executable "$COG_BIN/curl" \
  '#!/usr/bin/env bash' \
  'if [[ "$*" == *"/codex/state"* ]]; then printf "%s\\n" "$FAKE_STATE_JSON"; exit 0; fi' \
  'if [[ "$*" == *clear* ]]; then printf "%s\\n" "$CLEARED_JSON"; exit 0; fi' \
  'printf "%s\\n" "$ACTIVE_JSON"'
LONGITUDINAL_HAPPY_OUT="$TMP/cognition/longitudinal-happy.jsonl"
LONGITUDINAL_HAPPY_RC="$(expect_failure organism-longitudinal-happy env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" ACTIVE_JSON='{"status":"active"}' CLEARED_JSON='{"status":"cleared"}' NATIVE_AGENT_ORGANISM_EVAL_RUN_ID=happy-run NATIVE_AGENT_ORGANISM_EVAL_DAY_INDEX=9 "$ROOT/script/organism_longitudinal_eval.sh" "$LONGITUDINAL_HAPPY_OUT")"
if [[ "$LONGITUDINAL_HAPPY_RC" -eq 0 ]] \
  && [[ "$(wc -l < "$LONGITUDINAL_HAPPY_OUT" | tr -d ' ')" -eq 6 ]] \
  && jq -se '
    length == 6
      and all(.[]; .runId == "happy-run" and .dayIndex == 9)
      and map(.label) == [
        "baseline", "scenario:provider_brittle", "scenario:stale_phone",
        "scenario:resource_tight", "scenario:approval_closed", "cleared"
      ]
  ' "$LONGITUDINAL_HAPPY_OUT" >/dev/null; then
  pass "scripts.organism_longitudinal_eval" "confirmed bridge scenarios write one complete identified six-row run"
else
  gap "scripts.organism_longitudinal_eval" "confirmed bridge scenarios did not produce the complete identified longitudinal run"
fi

COG_NULL_OUT="$TMP/cognition/null.jsonl"
COG_NULL_RC="$(expect_failure cognition-null env HOME="$COG_HOME" PATH="$COG_BIN:$PATH" FAKE_STATE_JSON='{}' "$ROOT/script/cognition_eval.sh" cognition "$COG_NULL_OUT")"
if [[ "$COG_NULL_RC" -ne 0 ]] && rg -q 'bridge state is incomplete or malformed' "$TMP/cognition-null.out" && [[ ! -f "$COG_NULL_OUT" ]]; then
  pass "scripts.cognition_eval.cognition" "all-null bridge state is rejected"
else
  gap "scripts.cognition_eval.cognition" "all-null cognition/contextFlow sample is committed as evidence"
fi

# ---------------------------------------------------------------------------
# scripts.organism_doctor / organism_doctor.env
# ---------------------------------------------------------------------------
DOCTOR_HOME="$TMP/doctor-home"
DOCTOR_DATA="$TMP/doctor-data"
DOCTOR_BIN="$TMP/doctor-bin"
make_bridge_home "$DOCTOR_HOME"
mkdir -p "$DOCTOR_DATA" "$DOCTOR_BIN"
# The doctor test intentionally gives it a failing process check and a
# successful bridge response.  Stub both commands so the assertion cannot be
# influenced by the installed app, Spotlight, or the resident bridge.
write_executable "$DOCTOR_BIN/pgrep" '#!/usr/bin/env bash' 'exit 1'
write_executable "$DOCTOR_BIN/mdfind" '#!/usr/bin/env bash' 'exit 0'
write_executable "$DOCTOR_BIN/curl" '#!/usr/bin/env bash' 'printf "%s\\n" "$FAKE_STATE_JSON"'
DOCTOR_RC="$(expect_failure doctor-default env HOME="$DOCTOR_HOME" PATH="$DOCTOR_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_DATA_ROOT="$DOCTOR_DATA" NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT='' "$ROOT/script/organism_doctor.sh")"
DOCTOR_OUT="$TMP/doctor-default.out"
if [[ "$DOCTOR_RC" -ne 0 ]] && rg -q 'FAIL_COUNT=[1-9]' "$DOCTOR_OUT"; then
  pass "scripts.organism_doctor" "default doctor is machine-readable and fails with failing checks"
else
  gap "scripts.organism_doctor" "default doctor prints FAIL lines but returns success and has no machine-readable FAIL count"
fi
DOCTOR_LENIENT_RC="$(expect_failure doctor-lenient env HOME="$DOCTOR_HOME" PATH="$DOCTOR_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_DATA_ROOT="$DOCTOR_DATA" NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT='' "$ROOT/script/organism_doctor.sh" --lenient)"
if [[ "$DOCTOR_LENIENT_RC" -eq 0 ]] && rg -q 'FAIL_COUNT=[1-9]' "$TMP/doctor-lenient.out"; then
  pass "scripts.organism_doctor" "--lenient is the explicit diagnostic-only escape hatch"
else
  gap "scripts.organism_doctor" "--lenient does not preserve an explicit non-gating diagnostic mode"
fi
if rg -q -i 'source absent' "$DOCTOR_OUT"; then
  pass "scripts.organism_doctor.env" "unset iOS snapshot is explicitly source absent"
else
  gap "scripts.organism_doctor.env" "unset iOS snapshot is not labelled 'source absent'"
fi
DOCTOR_UNCERTAIN_STATE="$(printf '%s' "$STATE_JSON" | jq '.organism.bodySchema += {providersAvailable:true, providersHealthy:false, providerPathBelief:{state:"uncertain"}, resourcePressure:"elevated", resourcePressureReading:{thermalPressure:"elevated",lowPowerMode:false}}')"
DOCTOR_UNCERTAIN_RC="$(expect_failure doctor-uncertain env HOME="$DOCTOR_HOME" PATH="$DOCTOR_BIN:$PATH" FAKE_STATE_JSON="$DOCTOR_UNCERTAIN_STATE" NATIVE_AGENT_DATA_ROOT="$DOCTOR_DATA" NATIVE_AGENT_ORGANISM_IOS_SNAPSHOT='' "$ROOT/script/organism_doctor.sh" --lenient)"
if [[ "$DOCTOR_UNCERTAIN_RC" -eq 0 ]] && rg -q 'uncertain; health not established, not proof of an outage; availability=true' "$TMP/doctor-uncertain.out" && rg -q 'thermal=elevated lowPowerMode=false; not a RAM-usage reading' "$TMP/doctor-uncertain.out"; then
  pass "scripts.organism_doctor" "provider uncertainty and thermal pressure retain their real evidence class"
else
  gap "scripts.organism_doctor" "provider uncertainty or thermal pressure is reported as a different failure"
fi
# ---------------------------------------------------------------------------
# scripts.organism_watch
# ---------------------------------------------------------------------------
WATCH_HOME="$TMP/watch-home"
WATCH_BIN="$TMP/watch-bin"
WATCH_OUT="$TMP/watch/organism_watch.jsonl"
make_bridge_home "$WATCH_HOME"
mkdir -p "$WATCH_BIN" "$(dirname "$WATCH_OUT")" "${WATCH_OUT}.lock"
write_executable "$WATCH_BIN/curl" '#!/usr/bin/env bash' 'printf "%s\\n" "$FAKE_STATE_JSON"'
WATCH_RC="$(expect_failure watch-lock env HOME="$WATCH_HOME" PATH="$WATCH_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" "$ROOT/script/organism_watch.sh" 0 1 "$WATCH_OUT")"
if [[ "$WATCH_RC" -ne 0 ]] && [[ ! -s "$WATCH_OUT" ]]; then
  pass "scripts.organism_watch" "existing writer lock prevents a second writer"
else
  gap "scripts.organism_watch" "existing <out>.lock is ignored; a second writer appends anyway"
fi
rmdir "${WATCH_OUT}.lock"
printf '%s\n' '{"old":1}' '{"old":2}' '{"old":3}' >"$WATCH_OUT"
WATCH_CAP_RC="$(expect_failure watch-cap env HOME="$WATCH_HOME" PATH="$WATCH_BIN:$PATH" FAKE_STATE_JSON="$STATE_JSON" NATIVE_AGENT_ORGANISM_WATCH_MAX_ROWS=2 "$ROOT/script/organism_watch.sh" 0 1 "$WATCH_OUT")"
if [[ "$WATCH_CAP_RC" -eq 0 ]] && [[ "$(wc -l < "$WATCH_OUT" | tr -d ' ')" -eq 2 ]] \
  && jq -e 'select(.ok == true and .enabled == true and .signalCount == 1 and .posture == "baseline")' "$WATCH_OUT" >/dev/null; then
  pass "scripts.organism_watch" "watch retains a bounded, well-formed single-writer JSONL timeline"
else
  gap "scripts.organism_watch" "watch did not write one well-formed named organism observation inside its bounded timeline"
fi
write_executable "$WATCH_BIN/curl" '#!/usr/bin/env bash' 'exit 7'
WATCH_DOWN_OUT="$TMP/watch/bridge-down.jsonl"
WATCH_DOWN_RC="$(expect_failure watch-bridge-down env HOME="$WATCH_HOME" PATH="$WATCH_BIN:$PATH" "$ROOT/script/organism_watch.sh" 0 1 "$WATCH_DOWN_OUT")"
if [[ "$WATCH_DOWN_RC" -eq 0 ]] && rg -q '"ok":false,"reason":"bridge_unreachable"' "$WATCH_DOWN_OUT"; then
  pass "scripts.organism_watch" "transport loss is retained as a named observation"
else
  gap "scripts.organism_watch" "transport loss aborts a watch without a bridge_unreachable observation"
fi

# ---------------------------------------------------------------------------
# scripts.organism_bridge_probe
# ---------------------------------------------------------------------------
PROBE_HOME="$TMP/probe-home"
PROBE_BIN="$TMP/probe-bin"
PROBE_STATE="$TMP/probe-state"
PROBE_BASELINE_RESPONSE="$TMP/probe-baseline.json"
PROBE_SIMULATED_RESPONSE="$TMP/probe-simulated.json"
make_bridge_home "$PROBE_HOME"
mkdir -p "$PROBE_BIN"
printf 'baseline\n' >"$PROBE_STATE"
printf '%s\n' "$STATE_JSON" >"$PROBE_BASELINE_RESPONSE"
sed 's/"baseline"/"simulated"/g' "$PROBE_BASELINE_RESPONSE" >"$PROBE_SIMULATED_RESPONSE"
write_executable "$PROBE_BIN/curl" \
  '#!/usr/bin/env bash' \
  'set -eu' \
  'if [[ "$*" == *"/codex/state"* ]]; then' \
  '  if [[ "$(cat "$PROBE_STATE")" == baseline ]]; then cat "$PROBE_BASELINE_RESPONSE"; else cat "$PROBE_SIMULATED_RESPONSE"; fi' \
  'elif [[ "$*" == *"\"action\":\"clear\""* ]]; then' \
  '  printf baseline > "$PROBE_STATE"; cat "$PROBE_BASELINE_RESPONSE"' \
  'else' \
  '  printf simulated > "$PROBE_STATE"; cat "$PROBE_SIMULATED_RESPONSE"' \
  'fi'
PROBE_RC="$(expect_failure probe-clear env HOME="$PROBE_HOME" PATH="$PROBE_BIN:$PATH" PROBE_STATE="$PROBE_STATE" PROBE_BASELINE_RESPONSE="$PROBE_BASELINE_RESPONSE" PROBE_SIMULATED_RESPONSE="$PROBE_SIMULATED_RESPONSE" "$ROOT/script/organism_bridge_probe.sh" simulate provider_brittle)"
if [[ "$PROBE_RC" -eq 0 ]] && [[ "$(cat "$PROBE_STATE")" == baseline ]] && rg -q '== after clear ==' "$TMP/probe-clear.out"; then
  pass "scripts.organism_bridge_probe" "simulate performs an explicit clear and the observed state returns to baseline"
else
  gap "scripts.organism_bridge_probe" "simulate did not prove an explicit post-clear baseline state"
fi

# Unknown scenarios must fail before any mutation. A typo must never create a
# debug override whose cleanup then becomes somebody else's problem.
PROBE_UNKNOWN_LOG="$TMP/probe-unknown.calls"
write_executable "$PROBE_BIN/curl" \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$PROBE_UNKNOWN_LOG"' \
  'exit 99'
PROBE_UNKNOWN_RC="$(expect_failure probe-unknown env HOME="$PROBE_HOME" PATH="$PROBE_BIN:$PATH" PROBE_UNKNOWN_LOG="$PROBE_UNKNOWN_LOG" "$ROOT/script/organism_bridge_probe.sh" simulate not-a-scenario)"
if [[ "$PROBE_UNKNOWN_RC" -eq 2 ]] && [[ ! -s "$PROBE_UNKNOWN_LOG" ]]; then
  pass "scripts.organism_bridge_probe" "unknown scenario exits 2 before any bridge mutation or read"
else
  gap "scripts.organism_bridge_probe" "unknown scenario reached the bridge or did not report usage failure"
fi

# A transport failure after the simulation is armed must still trigger the EXIT
# cleanup path.  The fake bridge records only the clear POST, making this a
# direct proof that the trap cannot silently strand a debug override.
PROBE_FAILURE_LOG="$TMP/probe-failure.calls"
write_executable "$PROBE_BIN/curl" \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$PROBE_FAILURE_LOG"' \
  'if [[ "$*" == *"/codex/state"* ]]; then cat "$PROBE_BASELINE_RESPONSE"; exit 0; fi' \
  'if grep -q '"'"'"action":"clear"'"'"' <<< "$*"; then cat "$PROBE_BASELINE_RESPONSE"; exit 0; fi' \
  'exit 7'
PROBE_FAILURE_RC="$(expect_failure probe-failure-cleanup env HOME="$PROBE_HOME" PATH="$PROBE_BIN:$PATH" PROBE_FAILURE_LOG="$PROBE_FAILURE_LOG" PROBE_BASELINE_RESPONSE="$PROBE_BASELINE_RESPONSE" "$ROOT/script/organism_bridge_probe.sh" simulate provider_brittle)"
if [[ "$PROBE_FAILURE_RC" -ne 0 ]] && [[ "$(rg -c '"action":"clear"' "$PROBE_FAILURE_LOG" || true)" -eq 1 ]]; then
  pass "scripts.organism_bridge_probe" "a failed simulate still sends exactly one clear POST on exit"
else
  gap "scripts.organism_bridge_probe" "a failed simulate can strand a debug override without exactly one cleanup clear"
fi

# ---------------------------------------------------------------------------
# scripts.u1_baseline
# ---------------------------------------------------------------------------
U1_ROOT="$TMP/u1-root"
U1_BIN="$TMP/u1-bin"
mkdir -p "$U1_ROOT/traces" "$U1_BIN" "$TMP/u1-build"
write_executable "$TMP/u1-build/chat-drive" '#!/usr/bin/env bash' 'exit 0'
write_executable "$U1_BIN/swift" \
  '#!/usr/bin/env bash' \
  'set -eu' \
  'if [[ "$*" == *"--show-bin-path"* ]]; then printf "%s\\n" "$U1_BUILD_BIN"; exit 0; fi' \
  'if [[ "$1" == "build" ]]; then exit 0; fi' \
  'if [[ "$1" == "-" ]]; then printf "calls=6 inputTokens=1\\n"; exit 0; fi' \
  'exit 64'
U1_RC="$(expect_failure u1-baseline env PATH="$U1_BIN:$PATH" U1_BUILD_BIN="$TMP/u1-build" NATIVE_AGENT_DATA_ROOT="$U1_ROOT" "$ROOT/script/u1_baseline.sh" --session fixture --label fixture)"
if [[ "$U1_RC" -eq 0 ]] && rg -q -i -e '(turn.{0,8}(sha|hash)|script.{0,8}(sha|hash))' "$TMP/u1-baseline.out"; then
  pass "scripts.u1_baseline" "output binds telemetry to a stable turn-script digest"
else
  gap "scripts.u1_baseline" "six turns can run and telemetry can print with no recorded hash of the fixed prompt script"
fi

# ---------------------------------------------------------------------------
# scripts.opus5_baseline_report
# ---------------------------------------------------------------------------
OPUS_ROOT="$TMP/opus-root"
OPUS_BIN="$TMP/opus-bin"
mkdir -p "$OPUS_ROOT/script" "$OPUS_ROOT/data/turn_traces" "$OPUS_ROOT/data/notifications" "$OPUS_ROOT/data/logs" "$OPUS_BIN"
cp "$ROOT/script/opus5_baseline_report.sh" "$OPUS_ROOT/script/opus5_baseline_report.sh"
cp "$ROOT/script/opus5_baseline_report.swift" "$OPUS_ROOT/script/opus5_baseline_report.swift"
printf '%s\n' \
  '{"kind":"context.snapshot","surface":"chat","payload":{"model":"fixture-model"}}' \
  '{"kind":"context.summary","ts":"2026-08-24T00:00:00Z","payload":{"counts":{"contextFlow.memoryRecords":"4","contextFlow.selectedAtoms":"2","persona.docCount":"1"}}}' \
  >"$OPUS_ROOT/data/turn_traces/fixture.jsonl"
printf '%s\n' '{"source":"trigger:morning_brief","created_at":"2026-08-24T00:00:00Z","status":"ready","title":"Fixture brief","summary":"fixture summary"}' \
  >"$OPUS_ROOT/data/notifications/inbox.jsonl"
printf '%s\n' '{"createdAt":"2026-08-24T00:00:00Z","loopId":"fixture-loop","kind":"fixture","error":"fixture failure"}' \
  >"$OPUS_ROOT/data/logs/background_loop_failures.jsonl"
write_executable "$OPUS_BIN/python3" '#!/usr/bin/env bash' 'printf "python3 %s\\n" "$*" >> "$PYTHON_CALLS"'
OPUS_RC="$(expect_failure opus-report env PATH="$OPUS_BIN:$PATH" PYTHON_CALLS="$TMP/python.calls" "$OPUS_ROOT/script/opus5_baseline_report.sh" "$TMP/opus-report.txt")"
write_executable "$OPUS_BIN/swift" '#!/usr/bin/env bash' 'exit 17'
OPUS_COMPANION_FAILURE_RC="$(expect_failure opus-report-companion-failure env PATH="$OPUS_BIN:$PATH" "$OPUS_ROOT/script/opus5_baseline_report.sh" "$TMP/opus-report-companion-failure.txt")"
if [[ "$OPUS_RC" -eq 0 ]] && [[ ! -s "$TMP/python.calls" ]] \
  && [[ "$OPUS_COMPANION_FAILURE_RC" -ne 0 ]] \
  && rg -q 'fixture-model|Fixture brief|fixture-loop' "$TMP/opus-report.txt"; then
  pass "scripts.opus5_baseline_report" "Swift companion parses every seeded report family without Python and its failure aborts the report"
else
  gap "scripts.opus5_baseline_report" "report does not execute the Swift companion across every report family without Python and fail closed"
fi

# ---------------------------------------------------------------------------
# scripts.voice_tic_census
# ---------------------------------------------------------------------------
VOICE_ROOT="$TMP/voice-root"
mkdir -p "$VOICE_ROOT/script" "$VOICE_ROOT/data/chat/messages"
cp "$ROOT/script/voice_tic_census.swift" "$VOICE_ROOT/script/voice_tic_census.swift"
VOICE_RC="$(expect_failure voice-zero swift "$VOICE_ROOT/script/voice_tic_census.swift" --days 1)"
if [[ "$VOICE_RC" -ne 0 ]] && rg -q 'no assistant messages' "$TMP/voice-zero.out"; then
  pass "scripts.voice_tic_census" "zero-message input is a named non-success"
else
  gap "scripts.voice_tic_census" "zero assistant messages prints a report-like success instead of failing"
fi

# ---------------------------------------------------------------------------
# scripts.release_github
# ---------------------------------------------------------------------------
# An invalid preflight setting is a deterministic blocked condition.  It must
# make the command nonzero and it must never reach the release executor.
REL_BIN="$TMP/release-bin"
mkdir -p "$REL_BIN"
write_executable "$REL_BIN/gh" \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GH_CALLS"' \
  'case "$1 $2" in' \
  '  "auth status") exit 0 ;;' \
  '  "api repos/fixture/repo") printf public ;;' \
  '  "api repos/fixture/repo/commits/"*) printf "%s\\n" "$TEST_HEAD" ;;' \
  'esac'
REL_RC="$(expect_failure release-preflight env PATH="$REL_BIN:$PATH" GH_CALLS="$TMP/gh.calls" TEST_HEAD="$(git -C "$ROOT" rev-parse HEAD)" NATIVEAGENT_PUBLIC_DEVICE_SYNC=invalid NATIVEAGENT_GITHUB_REPOSITORY=fixture/repo "$ROOT/script/release_github.sh" --preflight)"
if [[ "$REL_RC" -ne 0 ]] && rg -q 'BLOCKED: NATIVEAGENT_PUBLIC_DEVICE_SYNC' "$TMP/release-preflight.out" \
  && ! rg -q 'release.sh' "$TMP/release-preflight.out"; then
  pass "scripts.release_github" "a BLOCKED preflight exits nonzero before any publish command"
else
  gap "scripts.release_github" "a BLOCKED preflight did not reliably stop the release lane"
fi

# ---------------------------------------------------------------------------
# scripts.icons.render
# ---------------------------------------------------------------------------
# Render both images twice in a temporary directory.  Determinism is only the
# first half of the contract; the second half is one shared composition owner.
# Current renderers duplicate that owner, so the eval remains red until the
# shared function/module exists even if their pixels happen to agree today.
ICON_DIR="$TMP/icons"
mkdir -p "$ICON_DIR"
ICON_MAC_1="$ICON_DIR/mac-1.png"
ICON_MAC_2="$ICON_DIR/mac-2.png"
ICON_IOS_1="$ICON_DIR/ios-1.png"
ICON_IOS_2="$ICON_DIR/ios-2.png"
ICON_RC=0
"$ROOT/script/icons/render_icon.sh" mac "$ICON_MAC_1" >/dev/null 2>&1 || ICON_RC=$?
"$ROOT/script/icons/render_icon.sh" mac "$ICON_MAC_2" >/dev/null 2>&1 || ICON_RC=$?
"$ROOT/script/icons/render_icon.sh" ios "$ICON_IOS_1" >/dev/null 2>&1 || ICON_RC=$?
"$ROOT/script/icons/render_icon.sh" ios "$ICON_IOS_2" >/dev/null 2>&1 || ICON_RC=$?
MAC_DRAW_COUNT="$(rg -c '^func drawLivingCore' "$ROOT/script/icons/LivingCore.swift" | awk -F: '{sum += $NF} END {print sum + 0}')"
if [[ "$ICON_RC" -eq 0 ]] && cmp -s "$ICON_MAC_1" "$ICON_MAC_2" && cmp -s "$ICON_IOS_1" "$ICON_IOS_2" && cmp -s "$ICON_MAC_1" "$ROOT/Resources/AppIcon.iconset/icon_512@2x.png" && cmp -s "$ICON_IOS_1" "$ROOT/iOS/NativeAgentMobile/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" && [[ "$MAC_DRAW_COUNT" -eq 1 ]]; then
  pass "scripts.icons.render" "renders are deterministic and share one composition owner"
else
  gap "scripts.icons.render" "renderers are not proven against committed assets and drawLivingCore is duplicated ($MAC_DRAW_COUNT definitions)"
fi

printf '\nScript behavior eval summary: %d pass, %d gap(s)\n' "${#PASS_ROWS[@]}" "${#GAPS[@]}"
if [[ ${#GAPS[@]} -gt 0 ]]; then
  printf 'Remaining production gaps:\n' >&2
  printf '  %s\n' "${GAPS[@]}" >&2
  exit 1
fi
