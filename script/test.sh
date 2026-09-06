#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_RECEIPT=""
REQUIRE_IOS=0

usage() {
  cat >&2 <<'USAGE'
usage: script/test.sh [--require-ios] [--release-receipt PATH]

--require-ios           Fail instead of skipping when no iOS simulator is available.
--release-receipt PATH  Mark the current attempt incomplete, then publish a
                        positive JSON receipt only after every check passes
                        on one clean, stable Git revision. Implies --require-ios.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-ios) REQUIRE_IOS=1 ;;
    --release-receipt)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage; exit 2; }
      RELEASE_RECEIPT="$2"
      REQUIRE_IOS=1
      shift
      ;;
    --release-receipt=*)
      RELEASE_RECEIPT="${1#--release-receipt=}"
      [[ -n "$RELEASE_RECEIPT" ]] || { usage; exit 2; }
      REQUIRE_IOS=1
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

TEST_SOURCE_REVISION=""
if [[ -n "$RELEASE_RECEIPT" ]]; then
  # This path describes the CURRENT attempt. Preserve older proof for audit,
  # but never leave it looking like this run passed after an early failure.
  [[ ! -L "$RELEASE_RECEIPT" && ( ! -e "$RELEASE_RECEIPT" || -f "$RELEASE_RECEIPT" ) ]] \
    || { echo "[test] FATAL: receipt destination must be a regular file" >&2; exit 1; }
  mkdir -p "$(dirname "$RELEASE_RECEIPT")"
  if [[ -f "$RELEASE_RECEIPT" ]]; then
    receipt_previous="$(mktemp "$RELEASE_RECEIPT.previous.XXXXXX")"
    cp -p "$RELEASE_RECEIPT" "$receipt_previous"
    echo "[test] previous receipt preserved: $receipt_previous"
  fi
  receipt_pending="$(mktemp "$RELEASE_RECEIPT.pending.XXXXXX")"
  printf '{"schema_version":1,"canonical_gate":"script/test.sh","result":"incomplete","ios_required":true,"ios_result":"not_run","started_at":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$receipt_pending"
  chmod 0644 "$receipt_pending"
  mv -f "$receipt_pending" "$RELEASE_RECEIPT"
  TEST_SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$TEST_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$TEST_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || { echo "[test] FATAL: a release receipt requires one exact Git object ID" >&2; exit 1; }
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] \
    || { echo "[test] FATAL: a release receipt requires a clean source tree" >&2; exit 1; }
fi

export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# 2026-08-05 hermetic-tests sweep: many Core types default their `dataRoot:`
# init parameter to `PersistenceCore.defaultDataRoot()`, which walks up from CWD
# and resolves to THIS repo's `data/` under `swift test` — the LIVE app data
# root. Any test that constructs such a type bare then READS and WRITES real
# user state; `SwiftNativePersonaEngine(root:)` alone appended 739 phantom
# "<DOC>.md updated" rows to data/activity/events.jsonl this way.
#
# The primary fix is per-target `Hermetic*Support.swift` helpers pinning
# `dataRoot:` explicitly. This export is the SECOND line of defence: the env var
# is the first branch `defaultDataRoot()` consults, so any residual bare default
# resolves into a throwaway dir instead of the checkout. PersistenceCoreTests'
# `HermeticDataRootCanaryTests` pins that branch ordering.
NATIVE_AGENT_TEST_DATA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-test-dataroot.XXXXXX")"
export NATIVE_AGENT_DATA_ROOT="$NATIVE_AGENT_TEST_DATA_ROOT"
# ProviderReadinessTests are destructive by design, but the canonical gate has
# already moved their owner root into the throwaway directory above. Arm them
# here so they execute rather than returning early and being counted as passes.
export NATIVE_AGENT_PROVIDER_READINESS_TEST=1
cleanup_test_data_root() {
  [[ -n "${NATIVE_AGENT_TEST_DATA_ROOT:-}" ]] && rm -rf "$NATIVE_AGENT_TEST_DATA_ROOT"
  return 0
}
trap cleanup_test_data_root EXIT
echo "[test] hermetic NATIVE_AGENT_DATA_ROOT=$NATIVE_AGENT_DATA_ROOT"

# Every tests/scripts/*.sh suite must have a real command invocation below.
# The checker deliberately ignores comments so documentation cannot make an
# orphaned suite look wired into the canonical gate.
"$ROOT/script/check_canonical_test_wiring.sh" "$ROOT" "${BASH_SOURCE[0]}"

echo "[test] total script behavior evals"
"$ROOT/tests/scripts/total_script_behavior_evals_test.sh"

echo "[test] Wave 2 script behavior evals"
"$ROOT/tests/scripts/wave2_feeds_scripts_behavior_evals_test.sh"

echo "[test] release environment surface"
bash "$ROOT/tests/scripts/release_env_surface_test.sh"

echo "[test] release derived ContextFlow state guards"
"$ROOT/tests/scripts/release_derived_context_guards_test.sh"

echo "[test] agent instrument eval suite"
"$ROOT/tests/scripts/agent_instrument_test.sh"

echo "[test] merge candidate integration helper"
bash "$ROOT/script/tests/merge_candidate.test.sh"

echo "[test] iOS release deterministic fixtures (no signing or upload)"
bash "$ROOT/script/tests/ios_release.test.sh"

echo "[test] tool execution inventory states"
"$ROOT/tests/scripts/tool_execution_inventory_test.sh"

echo "[test] user-mode Accessibility gate"
"$ROOT/tests/scripts/user_mode_eval_gate_test.sh"

echo "[test] release ad-hoc signing guards"
"$ROOT/tests/scripts/release_signing_guards_test.sh"

echo "[test] sparkle appcast + update-honesty guards"
"$ROOT/tests/scripts/sparkle_appcast_guards_test.sh"

echo "[test] sparkle publish ordering + live-verification guards"
"$ROOT/tests/scripts/sparkle_publish_ordering_test.sh"

echo "[test] GitHub Sparkle release publisher"
"$ROOT/tests/scripts/github_release_updater_test.sh"


echo "[test] compiled release bundle identity guards"
"$ROOT/tests/scripts/release_bundle_gates_test.sh"

echo "[test] public release source guards"
"$ROOT/tests/scripts/public_release_source_guards_test.sh"

echo "[test] release MiniLM resource guards"
"$ROOT/tests/scripts/release_resource_guards_test.sh"

echo "[test] release symbol archive + stripping guards"
"$ROOT/tests/scripts/release_symbol_guards_test.sh"

echo "[test] canonical test inventory"
"$ROOT/tests/scripts/test_inventory_guards_test.sh"
"$ROOT/tests/scripts/ios_test_result_guards_test.sh"
"$ROOT/tests/scripts/evals_execution_receipts_guards_test.sh"
"$ROOT/tests/scripts/canonical_receipt_attempt_guards_test.sh"

echo "[test] canonical script-suite wiring guards"
"$ROOT/tests/scripts/canonical_test_wiring_guards_test.sh"

"$ROOT/tests/scripts/evals_changed_plan_guards_test.sh"

"$ROOT/tests/scripts/evals_ledger_schema_guards_test.sh"

echo "[test] build source inventory guard tests"
"$ROOT/tests/scripts/build_source_inventory_guards_test.sh"

"$ROOT/tests/scripts/development_build_pins_guards_test.sh"

echo "[test] generated artifact cleanup guard tests"
"$ROOT/tests/scripts/generated_artifact_cleanup_guards_test.sh"

echo "[test] Chrome native-host registration"
"$ROOT/tests/scripts/chrome_native_host_install_test.sh"

echo "[test] architecture blueprint drift"
"$ROOT/script/check_architecture_blueprint.swift" --repo "$ROOT"

echo "[test] production timer/deadline ownership"
"$ROOT/script/check_timer_inventory.swift" --repo "$ROOT"

echo "[test] persona hygiene"
"$ROOT/script/check_persona_skill_hygiene.swift" --repo "$ROOT"

echo "[test] tracked privacy"
"$ROOT/script/check_tracked_privacy.sh"

# Bridge wakeup helpers are production code with node-only test suites; run
# them all so a new suite can never sit orphaned outside the gate.
# One `node --test` per suite paid a fresh Node startup each time; the runner
# takes every path at once and reports them individually. Same suites (the
# glob is unchanged), same failure behavior — a non-zero run still aborts here.
echo "[test] bridge wakeup helpers (node)"
node --test "$ROOT"/script/tests/*.test.js

echo "[test] Chrome extension (mock browser, node)"
node --test "$ROOT"/Extensions/NativeAgentChrome/tests/*.test.js

# U4 Wave B: when this script runs as the `run_tests` builder tool it is wrapped
# in an OUTER macOS sandbox-exec (workspace-scoped writes). SwiftPM self-sandboxes
# its manifest compilation and sandbox-exec cannot nest, so the build fails with
# "Invalid manifest" unless SwiftPM's own sandbox is disabled. The tool sets
# NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=1; the OUTER sandbox still confines every
# write, so containment is preserved. Unset (CI / manual `script/test.sh`) → no
# flag → SwiftPM's inner sandbox stays on, behavior unchanged.
SWIFTPM_SANDBOX_FLAG=()
if [[ "${NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  SWIFTPM_SANDBOX_FLAG=(--disable-sandbox)
fi

# shellcheck source=lib/build_source_inventory.sh
source "$ROOT/script/lib/build_source_inventory.sh"

# A validation run must not silently change the dependency graph it certifies.
# Dependency updates are explicit maintenance, never a build/test side effect.
echo "[test] build ActivityWatch process-boundary probe once"
swift build --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} \
  --package-path "$ROOT/Modules/NativeAgentCore" --product activity-probe

echo "[test] NativeAgentCore XCTest tests"
swift test --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT/Modules/NativeAgentCore" --disable-swift-testing

echo "[test] NativeAgentCore Swift Testing shards"
# Xcode 16/SwiftPM's swiftpm-testing-helper is brittle when this package's
# full 3k+ Swift Testing suite runs as one process: it can SIGPIPE without an
# assertion failure after heavy stderr/test-event output. Sharding by test target
# keeps full coverage while avoiding helper-channel overload and isolates the
# timing-sensitive ProviderRouting tests from SelfImprovement's git subprocesses.
# THREE shards are pinned solo — run one at a time, `--no-parallel` inside:
# ChatOrchestration (real sandboxed SwiftPM fixture builds, whose parallel
# `dsymutil` children block each other until a tool watchdog fires or outlive
# an interrupted helper), SelfImprovement (git subprocesses) and ProviderRouting
# (wall-clock timing). Those are the only stated hazards, so the remaining
# shards — which spawn nothing and measure nothing — run pooled and internally
# parallel. Sharding still bounds event volume for all of them.
# For a single-command full Core sweep, use `swift test --package-path
# Modules/NativeAgentCore --no-parallel`; do not use the bare parallel helper
# path as the broad gate.
CORE_SWIFT_TEST_SHARDS=(
  "ActivityWatchTests|ApprovalInboxTests|BackgroundLoopsTests|BrowserTests|CapabilityFoundryTests|ChatOrchestrationTests"
  # Keep this family split: on Xcode 26 the combined helper can exit after
  # emitting every passing event while `swift test` remains asleep on a zombie
  # child. Smaller exact-target shards avoid that SwiftPM pipe/reap failure.
  "ConnectorsTests|ContextTests"
  "DispatcherTests"
  "DoctorChecksTests"
  "DreamREMCycleTests"
  "KnowledgeGraphTests|MCPDispatcherTests|MacAssistantStatusTests|MacControlTests|MemoryV2Tests"
  "WorkshopExecutionTests"
  "MultimodalTTSTests|NativeAgentCoreTests|NotificationInboxTests|PersistenceCoreTests"
  "PersonaEngineTests|ProviderRoutingTests|ResearchTests|ScreenVisionTests|VisionPerceptionTests"
  "SelfImprovementTests"
  "SkillsTests|SwarmRunsTests|SystemOpsTests|TelegramBotTests"
  "ToolExecutionTests|ToolRegistryTests|TriggerSchedulerTests|TrustCenterTests|WorkflowOrchestrationTests"
  # R2 tightness sweep (2026-07-18): these three targets are Swift-Testing-only
  # and appeared in NO shard, so their suites (478 + 57 + 1 @Test) never ran in
  # this gate. CognitiveSubstrateTests runs alone — it is the largest suite.
  "CognitiveSubstrateTests"
  "GitHubConnectorTests|SlackConnectorTests"
  # Kept exhaustive: these targets are XCTest-only/empty today (covered by the
  # unfiltered XCTest pass above), but listing them here means a future @Test
  # (Swift Testing) added to any of them is NOT silently skipped by the shards.
  "CommandPaletteTests|OnboardingTests|MacIntegrationTests|XConnectorTests"
)
# The three hazard targets named above. A shard containing any of them is
# pinned solo; every other shard is pooled.
CORE_SOLO_SHARD_TARGETS='ChatOrchestrationTests|SelfImprovementTests|ProviderRoutingTests'
CORE_SHARD_POOL="${NATIVEAGENT_CORE_SHARD_POOL:-4}"
CORE_TEST_SOURCE_DIGEST="$(nativeagent_source_state_digest "$ROOT/Modules/NativeAgentCore")"
core_solo_shards=()
core_pooled_shards=()
for shard in "${CORE_SWIFT_TEST_SHARDS[@]}"; do
  if [[ "$shard" =~ $CORE_SOLO_SHARD_TARGETS ]]; then
    core_solo_shards+=("$shard")
  else
    core_pooled_shards+=("$shard")
  fi
done
echo "[test] Core shard plan: ${#CORE_SWIFT_TEST_SHARDS[@]} shards — ${#core_solo_shards[@]} pinned solo (--no-parallel), ${#core_pooled_shards[@]} pooled ${CORE_SHARD_POOL}-way"
# Build the test bundle ONCE up front so every shard can --skip-build. This
# replaces the old "first shard owns the build" ordering, which a pool cannot
# honor. The digest check below still refuses a stale --skip-build success.
swift build --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} \
  --package-path "$ROOT/Modules/NativeAgentCore" --build-tests
for shard in ${core_solo_shards[@]+"${core_solo_shards[@]}"}; do
  echo "[test] NativeAgentCore Swift Testing shard (solo): $shard"
  swift test --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} \
    --skip-build --package-path "$ROOT/Modules/NativeAgentCore" \
    --disable-xctest --no-parallel --filter "^(${shard})\\."
done
if [[ "${#core_pooled_shards[@]}" -gt 0 ]]; then
  echo "[test] NativeAgentCore Swift Testing shards (pooled ${CORE_SHARD_POOL}-way): ${#core_pooled_shards[@]}"
  core_pooled_logs="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-core-shards.XXXXXX")"
  # --skip-build makes the built products shared read-only, so shards only
  # contend for CPU. Output is captured per shard and printed on failure so a
  # diagnosis is not shredded across concurrent writers.
  printf '%s\n' "${core_pooled_shards[@]}" \
    | xargs -P "$CORE_SHARD_POOL" -I{} bash -c '
        shard="$1"; logs="$2"; sandbox_flag="$3"; package="$4"
        log="$logs/$(printf "%s" "$shard" | tr -c "A-Za-z0-9" "_").log"
        if swift test --force-resolved-versions --skip-update $sandbox_flag \
             --skip-build --package-path "$package" \
             --disable-xctest --filter "^($shard)\\." > "$log" 2>&1; then
          printf "[test]   shard ok: %s\n" "$shard"
        else
          printf "[test]   SHARD FAILED: %s\n" "$shard"
          cat "$log"
          exit 1
        fi
      ' _ {} "$core_pooled_logs" "${SWIFTPM_SANDBOX_FLAG[0]:-}" "$ROOT/Modules/NativeAgentCore"
  rm -rf "$core_pooled_logs"
fi
CORE_TEST_SOURCE_DIGEST_AFTER="$(nativeagent_source_state_digest "$ROOT/Modules/NativeAgentCore")"
if [[ "$CORE_TEST_SOURCE_DIGEST" != "$CORE_TEST_SOURCE_DIGEST_AFTER" ]]; then
  echo "[test] ERROR: NativeAgentCore source/resource state changed during sharded execution; refusing stale --skip-build success." >&2
  exit 1
fi

echo "[test] NativeAgentShared Swift tests"
swift test --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT/Modules/NativeAgentShared"

echo "[test] NativeAgentApp Swift tests"
# Testing the root package builds NativeAgentApp and runs NativeAgentAppTests in
# one pass. Keep it serial to bound resource pressure from the app's broad test
# target without repeating a separate root build first.
swift test --force-resolved-versions --skip-update ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT" --no-parallel

echo "[test] iOS NativeAgentMobile tests"
# 2026-07-21 audit: the iOS suites (incl. ChatStoreMergeTests) had no runner.
# The script skips gracefully when no simulator exists or when invoked under
# the builder sandbox (it honors the same NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX
# pattern as the swift gates above).
IOS_ARGS=()
if [[ "$REQUIRE_IOS" -eq 1 ]]; then
  IOS_ARGS+=(--require)
fi
if [[ ${#IOS_ARGS[@]} -gt 0 ]]; then
  "$ROOT/script/test_ios.sh" "${IOS_ARGS[@]}"
else
  "$ROOT/script/test_ios.sh"
fi

echo "[test] tracked Python guard"
tracked_hits="$(
  cd "$ROOT"
  git ls-files \
  | grep -E '(^|/).*\.py$|(^|/)pytest\.ini$|(^|/)script/nativeagent-skill$|NativeAgent\.python\.entitlements$' \
  || true
)"
if [[ -n "$tracked_hits" ]]; then
  echo "[test] ERROR: tracked Python-era files remain:" >&2
  echo "$tracked_hits" >&2
  exit 1
fi

echo "[test] generated Python cache guard"
cache_hit="$(
  find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/.build" -prune -o \
    -path "$ROOT/.swiftpm" -prune -o \
    -path "$ROOT/.claude" -prune -o \
    -path "$ROOT/.hermes-*" -prune -o \
    \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
    -print -quit 2>/dev/null || true
)"
if [[ -n "$cache_hit" ]]; then
  echo "[test] ERROR: generated Python cache remains: $cache_hit" >&2
  exit 1
fi

echo "[test] working-tree Python guard"
# This one explicitly ignored, offline ground-truth oracle is developer test
# authoring material; it is never tracked, built, or bundled. The tracked
# Python guard above remains the release authority.
working_py_hit="$(
  find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/.build" -prune -o \
    -path "$ROOT/.swiftpm" -prune -o \
    -path "$ROOT/.claude" -prune -o \
    -path "$ROOT/.runtime" -prune -o \
    -path "$ROOT/.hermes-*" -prune -o \
    -path "$ROOT/build" -prune -o \
    -path "$ROOT/DerivedData" -prune -o \
    -path "$ROOT/data" -prune -o \
    -path "$ROOT/tests/activity_watch/verify_ground_truth.py" -prune -o \
    -type f -name '*.py' \
    -print -quit 2>/dev/null || true
)"
if [[ -n "$working_py_hit" ]]; then
  echo "[test] ERROR: Python source file remains in repo working tree: $working_py_hit" >&2
  exit 1
fi

echo "[test] git diff whitespace"
git -C "$ROOT" diff --check

if [[ -n "$RELEASE_RECEIPT" ]]; then
  final_revision="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$final_revision" == "$TEST_SOURCE_REVISION" ]] \
    || { echo "[test] FATAL: source HEAD changed during the release test gate" >&2; exit 1; }
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] \
    || { echo "[test] FATAL: tracked or untracked source changed during the release test gate" >&2; exit 1; }
  receipt_dir="$(dirname "$RELEASE_RECEIPT")"
  mkdir -p "$receipt_dir"
  receipt_tmp="$RELEASE_RECEIPT.tmp.$$"
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{\n  "schema_version": 1,\n  "source_revision": "%s",\n  "source_dirty": false,\n  "canonical_gate": "script/test.sh",\n  "ios_required": true,\n  "ios_result": "passed",\n  "completed_at": "%s"\n}\n' \
    "$TEST_SOURCE_REVISION" "$completed_at" > "$receipt_tmp"
  chmod 0644 "$receipt_tmp"
  mv -f "$receipt_tmp" "$RELEASE_RECEIPT"
  echo "[test] release receipt: $RELEASE_RECEIPT"
fi

echo "[test] Swift-native checks passed"
