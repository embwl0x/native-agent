#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# 2026-07-21 audit: every tests/scripts/*.sh suite MUST be invoked by this
# script — an unwired guard test greens forever (the MiniLM resource-guard
# suite sat orphaned this way until today). Fail the gate on any orphan.
for suite in "$ROOT"/tests/scripts/*.sh; do
  name="$(basename "$suite")"
  if ! grep -q "tests/scripts/$name" "${BASH_SOURCE[0]}"; then
    echo "[test] FATAL: $name exists but is never invoked by script/test.sh" >&2
    exit 1
  fi
done

echo "[test] release derived ContextFlow state guards"
"$ROOT/tests/scripts/release_derived_context_guards_test.sh"

echo "[test] release ad-hoc signing guards"
"$ROOT/tests/scripts/release_signing_guards_test.sh"

echo "[test] sparkle appcast + update-honesty guards"
"$ROOT/tests/scripts/sparkle_appcast_guards_test.sh"

echo "[test] sparkle publish ordering + live-verification guards"
"$ROOT/tests/scripts/sparkle_publish_ordering_test.sh"

echo "[test] GitHub Sparkle release publisher"
"$ROOT/tests/scripts/github_release_updater_test.sh"


echo "[test] public release source guards"
"$ROOT/tests/scripts/public_release_source_guards_test.sh"

echo "[test] release MiniLM resource guards"
"$ROOT/tests/scripts/release_resource_guards_test.sh"

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
echo "[test] bridge wakeup helpers (node)"
for suite in "$ROOT"/script/tests/*.test.js; do
  node --test "$suite"
done

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

echo "[test] NativeAgentCore XCTest tests"
swift test ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT/Modules/NativeAgentCore" --disable-swift-testing

echo "[test] NativeAgentCore Swift Testing shards"
# Xcode 16/SwiftPM's swiftpm-testing-helper is brittle when this package's
# full 3k+ Swift Testing suite runs as one process: it can SIGPIPE without an
# assertion failure after heavy stderr/test-event output. Sharding by test target
# keeps full coverage while avoiding helper-channel overload and isolates the
# timing-sensitive ProviderRouting tests from SelfImprovement's git subprocesses.
# For a single-command full Core sweep, use `swift test --package-path
# Modules/NativeAgentCore --no-parallel`; do not use the bare parallel helper
# path as the broad gate.
CORE_SWIFT_TEST_SHARDS=(
  "ApprovalInboxTests|BackgroundLoopsTests|BrowserTests|CapabilityFoundryTests|ChatOrchestrationTests"
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
  "PersonaEngineTests|ProviderRoutingTests|ResearchTests|ScreenVisionTests"
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
for shard in "${CORE_SWIFT_TEST_SHARDS[@]}"; do
  echo "[test] NativeAgentCore Swift Testing shard: $shard"
  swift test ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT/Modules/NativeAgentCore" --disable-xctest --filter "^(${shard})\\."
done

echo "[test] NativeAgentShared Swift tests"
swift test ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT/Modules/NativeAgentShared"

echo "[test] NativeAgentApp Swift tests"
# Testing the root package builds NativeAgentApp and runs NativeAgentAppTests in
# one pass. Keep it serial to bound resource pressure from the app's broad test
# target without repeating a separate root build first.
swift test ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT" --no-parallel

echo "[test] iOS NativeAgentMobile tests"
# 2026-07-21 audit: the iOS suites (incl. ChatStoreMergeTests) had no runner.
# The script skips gracefully when no simulator exists or when invoked under
# the builder sandbox (it honors the same NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX
# pattern as the swift gates above).
"$ROOT/script/test_ios.sh"

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
    -path "$ROOT/.hermes-*" -prune -o \
    \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
    -print -quit 2>/dev/null || true
)"
if [[ -n "$cache_hit" ]]; then
  echo "[test] ERROR: generated Python cache remains: $cache_hit" >&2
  exit 1
fi

echo "[test] working-tree Python guard"
working_py_hit="$(
  find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/.build" -prune -o \
    -path "$ROOT/.swiftpm" -prune -o \
    -path "$ROOT/.runtime" -prune -o \
    -path "$ROOT/.hermes-*" -prune -o \
    -path "$ROOT/build" -prune -o \
    -path "$ROOT/DerivedData" -prune -o \
    -path "$ROOT/data" -prune -o \
    -type f -name '*.py' \
    -print -quit 2>/dev/null || true
)"
if [[ -n "$working_py_hit" ]]; then
  echo "[test] ERROR: Python source file remains in repo working tree: $working_py_hit" >&2
  exit 1
fi

echo "[test] git diff whitespace"
git -C "$ROOT" diff --check

echo "[test] Swift-native checks passed"
