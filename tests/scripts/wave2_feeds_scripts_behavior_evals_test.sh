#!/usr/bin/env bash
# Hermetic behavior evals for the Wave 2 script rows.  Every mutating command
# operates on a copied fixture; neither the resident data root nor persona is
# ever opened.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-wave2-scripts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# scripts.init_persona — a present but empty identity document is unusable. It
# must be repaired, while a nonempty personal document remains byte-identical.
PERSONA_ROOT="$TMP/persona-fixture"
mkdir -p "$PERSONA_ROOT/script" "$PERSONA_ROOT/persona"
cp "$ROOT/script/init_persona.sh" "$PERSONA_ROOT/script/init_persona.sh"
printf 'template soul\n' > "$PERSONA_ROOT/persona/SOUL.template.md"
printf 'template agents\n' > "$PERSONA_ROOT/persona/AGENTS.template.md"
printf 'template growth\n' > "$PERSONA_ROOT/persona/GROWTH.template.md"
: > "$PERSONA_ROOT/persona/SOUL.md"
printf 'personal instructions\n' > "$PERSONA_ROOT/persona/AGENTS.md"
bash "$PERSONA_ROOT/script/init_persona.sh" > "$TMP/init-persona.out"
[[ "$(cat "$PERSONA_ROOT/persona/SOUL.md")" == "template soul" ]] \
  || fail "scripts.init_persona did not repair a present-but-empty SOUL.md"
[[ "$(cat "$PERSONA_ROOT/persona/AGENTS.md")" == "personal instructions" ]] \
  || fail "scripts.init_persona overwrote a nonempty personal AGENTS.md"
[[ -d "$PERSONA_ROOT/data" && -f "$PERSONA_ROOT/workspace/.gitkeep" ]] \
  || fail "scripts.init_persona did not create the isolated runtime roots"

# scripts.lib.plist_types — missing, false and true are three distinct states;
# a string that happens to spell true must never acquire Boolean authority.
PLIST="$TMP/types.plist"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>actualTrue</key><true/>
<key>actualFalse</key><false/>
<key>stringTrue</key><string>true</string>
</dict></plist>
PLIST
# shellcheck source=../../script/lib/plist_types.sh
source "$ROOT/script/lib/plist_types.sh"
[[ "$(plist_bool_state "$PLIST" missing)" == "absent" ]] \
  || fail "plist type helper conflates an absent Boolean with a value"
[[ "$(plist_bool_state "$PLIST" actualFalse)" == "false" ]] \
  || fail "plist type helper lost false"
[[ "$(plist_bool_state "$PLIST" actualTrue)" == "true" ]] \
  || fail "plist type helper lost true"
[[ "$(plist_bool_state "$PLIST" stringTrue)" == "non-boolean:string" ]] \
  || fail "plist type helper granted a string Boolean authority"

# scripts.lib.nativeagent_bridge — the atomic descriptor wins the old token,
# while explicit caller overrides retain documented priority.  The token values
# are fixture-only, and this runs in a throwaway HOME.
BRIDGE_HOME="$TMP/bridge-home"
mkdir -p "$BRIDGE_HOME/.config/claude-bridge"
printf 'legacy-fixture-token\n' > "$BRIDGE_HOME/.config/claude-bridge/token"
/usr/libexec/PlistBuddy -c 'Add :url string https://descriptor.example.test' \
  -c 'Add :token string descriptor-fixture-token' \
  -x -c 'Save' "$BRIDGE_HOME/.config/claude-bridge/bridge.json" 2>/dev/null \
  || cat > "$BRIDGE_HOME/.config/claude-bridge/bridge.json" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>url</key><string>https://descriptor.example.test</string><key>token</key><string>descriptor-fixture-token</string></dict></plist>
PLIST
BRIDGE_RESULT="$(HOME="$BRIDGE_HOME" bash -c '
  source "$1/script/lib/nativeagent_bridge.sh"
  nativeagent_bridge_resolve
  printf "%s|%s|%s" "$BASE_URL" "$TOKEN" "$BRIDGE_CREDENTIAL_PATH"
' -- "$ROOT")"
[[ "$BRIDGE_RESULT" == "https://descriptor.example.test|descriptor-fixture-token|$BRIDGE_HOME/.config/claude-bridge/bridge.json" ]] \
  || fail "bridge descriptor did not win over the legacy token: $BRIDGE_RESULT"
printf 'explicit-fixture-token\n' > "$TMP/explicit-token"
BRIDGE_OVERRIDE="$(HOME="$BRIDGE_HOME" NATIVE_AGENT_BRIDGE_URL='https://override.example.test' NATIVE_AGENT_BRIDGE_TOKEN="$TMP/explicit-token" bash -c '
  source "$1/script/lib/nativeagent_bridge.sh"
  nativeagent_bridge_resolve
  printf "%s|%s|%s" "$BASE_URL" "$TOKEN" "$BRIDGE_CREDENTIAL_PATH"
' -- "$ROOT")"
[[ "$BRIDGE_OVERRIDE" == "https://override.example.test|explicit-fixture-token|$TMP/explicit-token" ]] \
  || fail "explicit bridge overrides did not win: $BRIDGE_OVERRIDE"

# Manual cognition evidence must survive optional process telemetry disappearing
# between the bridge snapshot and ps. Use the actual wrapper/sampler with no
# bridge access; preserve the 256-row bound and all non-CPU sample fields.
SAMPLER_ROOT="$TMP/sampler"
mkdir -p "$SAMPLER_ROOT/script/lib" "$SAMPLER_ROOT/bin"
cp "$ROOT/script/cognition_eval.sh" "$ROOT/script/cognition_event_driven_eval.sh" "$SAMPLER_ROOT/script/"
cp "$ROOT/script/lib/nativeagent_bridge.sh" "$SAMPLER_ROOT/script/lib/"
cat > "$SAMPLER_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$SAMPLER_STATE"
STUB
cat > "$SAMPLER_ROOT/bin/ps" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$SAMPLER_CPU"
exit "$SAMPLER_PS_EXIT"
STUB
chmod +x "$SAMPLER_ROOT/bin/curl" "$SAMPLER_ROOT/bin/ps"
sampler_state='{"uptimeSeconds":321,"organism":{"signalCount":7},"cognition":{"microcycle":{"processIdentifier":123,"status":"idle"}},"contextFlow":{"mode":"active","storeGeneration":12}}'
for scenario in numeric zero empty malformed failed missing-pid; do
  sampler_out="$SAMPLER_ROOT/$scenario.jsonl"
  jq -nc 'range(0;256) | {retained:.}' > "$sampler_out"
  sampler_cpu=' 12.5 '
  sampler_ps_exit=0
  sampler_expected=12.5
  scenario_state="$sampler_state"
  case "$scenario" in
    zero) sampler_cpu=0; sampler_expected=0;;
    empty) sampler_cpu=''; sampler_expected=null;;
    malformed) sampler_cpu='unavailable'; sampler_expected=null;;
    failed) sampler_ps_exit=1; sampler_expected=null;;
    missing-pid) scenario_state="$(jq 'del(.cognition.microcycle.processIdentifier)' <<<"$sampler_state")"; sampler_expected=null;;
  esac
  PATH="$SAMPLER_ROOT/bin:$PATH" NATIVE_AGENT_BRIDGE_TOKEN="$TMP/explicit-token" \
    NATIVE_AGENT_BRIDGE_URL='http://fixture.invalid' SAMPLER_STATE="$scenario_state" \
    SAMPLER_CPU="$sampler_cpu" SAMPLER_PS_EXIT="$sampler_ps_exit" \
    NATIVE_AGENT_COGNITION_EVAL_RUN_ID="fixture-$scenario" \
    "$SAMPLER_ROOT/script/cognition_event_driven_eval.sh" "$sampler_out" > "$TMP/sampler-$scenario.out" \
    || fail "cognition sampler failed when CPU telemetry was $scenario"
  jq -se --argjson expected "$sampler_expected" --arg run "fixture-$scenario" '
    length == 256 and .[0].retained == 1
    and .[-1].schema == "cognition.event-driven.eval.v1"
    and .[-1].runId == $run and .[-1].processCpuPercent == $expected
    and (. [-1] | has("processCpuPercent"))
    and .[-1].appUptimeSeconds == 321 and .[-1].organismSignalCount == 7
    and .[-1].microcycle.status == "idle" and .[-1].contextFlow.storeGeneration == 12
  ' "$sampler_out" >/dev/null || fail "cognition $scenario discarded a sample or fabricated CPU evidence"
  [[ "$(wc -l < "$sampler_out" | tr -d ' ')" == 256 ]] \
    || fail "cognition $scenario appended empty lines instead of exactly one valid row"
done

# The manual organism sampler temporarily changes debug physiology. Cleanup
# must follow even a lost activation response, failed state read, or signal,
# without claiming a cleared/healthy sample that was never observed.
ORGANISM_ROOT="$TMP/organism"
mkdir -p "$ORGANISM_ROOT/script/lib" "$ORGANISM_ROOT/bin"
cp "$ROOT/script/cognition_eval.sh" "$ROOT/script/organism_longitudinal_eval.sh" "$ORGANISM_ROOT/script/"
cp "$ROOT/script/lib/nativeagent_bridge.sh" "$ORGANISM_ROOT/script/lib/"
cat > "$ORGANISM_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
body=''
timeout=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --data) body="$2"; shift;;
    --max-time) timeout="$2"; shift;;
  esac
  shift
done
if [[ -n "$body" ]]; then
  jq -nc --argjson body "$body" --arg timeout "$timeout" '{body:$body,timeout:$timeout}' >> "$ORGANISM_CASE_DIR/requests.jsonl"
  if [[ "$(jq -r '.action // empty' <<<"$body")" == clear ]]; then
    [[ "$ORGANISM_CASE" != cleanup-failure ]] || exit 7
    printf '{"status":"cleared"}\n'
  else
    touch "$ORGANISM_CASE_DIR/activated"
    [[ "$ORGANISM_CASE" != lost-response ]] || exit 28
    printf '{"status":"active"}\n'
  fi
else
  [[ "$ORGANISM_CASE" != baseline-failure ]] || exit 28
  if [[ -e "$ORGANISM_CASE_DIR/activated" && "$ORGANISM_CASE" != success ]]; then
    if [[ "$ORGANISM_CASE" == signal ]]; then
      touch "$ORGANISM_CASE_DIR/ready"
      sleep 0.3
    fi
    exit 28
  fi
  printf '%s\n' "$SAMPLER_STATE"
fi
STUB
chmod +x "$ORGANISM_ROOT/bin/curl"
for scenario in success baseline-failure state-failure lost-response cleanup-failure signal; do
  organism_case_dir="$ORGANISM_ROOT/$scenario"
  mkdir -p "$organism_case_dir"
  : > "$organism_case_dir/requests.jsonl"
  organism_rc=0
  PATH="$ORGANISM_ROOT/bin:$PATH" NATIVE_AGENT_BRIDGE_TOKEN="$TMP/explicit-token" \
    NATIVE_AGENT_BRIDGE_URL='http://fixture.invalid' SAMPLER_STATE="$sampler_state" \
    ORGANISM_CASE="$scenario" ORGANISM_CASE_DIR="$organism_case_dir" \
    "$ORGANISM_ROOT/script/organism_longitudinal_eval.sh" "$organism_case_dir/samples.jsonl" \
    > "$organism_case_dir/output" 2>&1 &
  organism_pid=$!
  if [[ "$scenario" == signal ]]; then
    for ((attempt=0; attempt<200; attempt++)); do
      [[ ! -e "$organism_case_dir/ready" ]] || break
      sleep 0.01
    done
    if [[ ! -e "$organism_case_dir/ready" ]]; then
      kill -TERM "$organism_pid" 2>/dev/null || true
      wait "$organism_pid" || true
      fail "organism signal fixture did not reach its activated state read"
    fi
    kill -TERM "$organism_pid"
  fi
  wait "$organism_pid" || organism_rc=$?
  if [[ "$scenario" == success ]]; then
    [[ "$organism_rc" == 0 ]] || fail "organism success path failed"
    jq -se 'length == 5 and ([.[] | select(.body.action == "clear")] | length) == 1' \
      "$organism_case_dir/requests.jsonl" >/dev/null || fail "organism success did not clear exactly once"
    jq -se 'length == 6 and .[0].label == "baseline" and .[-1].label == "cleared"' \
      "$organism_case_dir/samples.jsonl" >/dev/null || fail "organism success lost its observed samples"
  elif [[ "$scenario" == baseline-failure ]]; then
    [[ "$organism_rc" == 28 && ! -s "$organism_case_dir/requests.jsonl" && ! -s "$organism_case_dir/samples.jsonl" ]] \
      || fail "organism baseline failure changed debug state or fabricated a sample"
  else
    expected_rc=28
    [[ "$scenario" != signal ]] || expected_rc=143
    [[ "$organism_rc" == "$expected_rc" ]] || fail "organism $scenario lost original exit status: $organism_rc"
    jq -se 'length == 2 and .[0].body.scenario == "provider_brittle" and .[1].body.action == "clear" and .[1].timeout == "5"' \
      "$organism_case_dir/requests.jsonl" >/dev/null || fail "organism $scenario did not attempt bounded cleanup once"
    jq -se 'length == 1 and .[0].label == "baseline" and .[0].signalCount == 7' \
      "$organism_case_dir/samples.jsonl" >/dev/null || fail "organism $scenario discarded evidence or fabricated cleared state"
    if [[ "$scenario" == cleanup-failure ]]; then
      grep -q 'cleanup was not confirmed' "$organism_case_dir/output" \
        || fail "organism cleanup failure hid its uncertain override state"
    fi
  fi
done

# Capture pairs must follow persisted run identity, not whichever user row
# happens to be closest after concurrent turns interleave in one session.
CAPTURE_ROOT="$TMP/capture-pairing"
mkdir -p "$CAPTURE_ROOT/data/turn_traces" "$CAPTURE_ROOT/data/chat/messages"
swiftc "$ROOT/script/agent_bench_capture.swift" -o "$CAPTURE_ROOT/capture"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{kind:"context.summary",ts:$ts,turnId:"turn-a",sessionId:"shared",surface:"chat",payload:{counts:{contextCore:1}}}' \
  > "$CAPTURE_ROOT/data/turn_traces/fixture.jsonl"
for scenario in interleaved legacy missing-match late-match; do
  case "$scenario" in
    interleaved)
      rows='{"role":"user","content":"prior history","runId":"prior"},{"role":"user","content":"message for run A","runId":"run-a"},{"role":"user","content":"message for run B","runId":"run-b"},{"role":"assistant","content":"answer A","runId":"run-a","metadata":{"turnTraceId":"turn-a"}}'
      expected='message for run A';;
    legacy)
      rows='{"role":"user","content":"prior history","runId":"prior"},{"role":"user","content":"legacy message"},{"role":"assistant","content":"legacy answer","metadata":{"turnTraceId":"turn-a"}}'
      expected='legacy message';;
    missing-match)
      rows='{"role":"user","content":"another run","runId":"run-b"},{"role":"assistant","content":"answer A","runId":"run-a","metadata":{"turnTraceId":"turn-a"}}';;
    late-match)
      rows='{"role":"user","content":"another run","runId":"run-b"},{"role":"assistant","content":"answer A","runId":"run-a","metadata":{"turnTraceId":"turn-a"}},{"role":"user","content":"too late","runId":"run-a"}';;
  esac
  jq -nc "$rows" > "$CAPTURE_ROOT/data/chat/messages/shared.jsonl"
  capture_rc=0
  "$CAPTURE_ROOT/capture" --data-root "$CAPTURE_ROOT/data" --persona-root "$CAPTURE_ROOT/persona" \
    --out "$CAPTURE_ROOT/$scenario" --turns 1 > "$TMP/capture-$scenario.out" 2>&1 || capture_rc=$?
  if [[ "$scenario" == missing-match || "$scenario" == late-match ]]; then
    [[ "$capture_rc" == 3 && ! -e "$CAPTURE_ROOT/$scenario" ]] \
      || fail "capture $scenario borrowed another turn's prompt or fabricated an empty success"
    grep -q 'captured ZERO replayable turns' "$TMP/capture-$scenario.out" \
      || fail "capture $scenario did not explain the missing replayable input"
  else
    [[ "$capture_rc" == 0 ]] || fail "capture $scenario rejected a correctly paired turn"
    jq -e --arg expected "$expected" '.turns | length == 1 and .[0].userMessage == $expected and .[0].transcript.sourceLinesBefore == 1' \
      "$CAPTURE_ROOT/$scenario/expectations.json" >/dev/null \
      || fail "capture $scenario lost its exact prompt/history boundary"
    jq -se 'length == 1 and .[0].content == "prior history"' \
      "$CAPTURE_ROOT/$scenario/root/chat/transcripts/turn-a.jsonl" >/dev/null \
      || fail "capture $scenario included user rows at or after the matched prompt"
  fi
done

echo "PASS Wave 2 script behavior evals"
