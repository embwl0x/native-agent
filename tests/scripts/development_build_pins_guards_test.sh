#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/development-build-pins.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/script/lib" "$FIXTURE/Sources/App" "$TMP/bin"
cp "$ROOT/script/build_and_run.sh" "$FIXTURE/script/build_and_run.sh"
for lib in provisioning_profile_contract development_bundle_signing chrome_payload build_source_inventory test_gate; do
  cp "$ROOT/script/lib/$lib.sh" "$FIXTURE/script/lib/$lib.sh"
done
printf '// fixture manifest\n' > "$FIXTURE/Package.swift"
printf '{"pins":[{"identity":"grdb.swift","state":{"version":"7.11.0"}}]}\n' \
  > "$FIXTURE/Package.resolved"
cp "$FIXTURE/Package.resolved" "$TMP/original.resolved"
printf 'struct App {}\n' > "$FIXTURE/Sources/App/App.swift"
printf '0.0.0\n' > "$FIXTURE/VERSION"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$PIN_TEST_CALLS"' \
  'case " $* " in *" --force-resolved-versions "*) ;; *) printf "mutated\n" > "$PIN_TEST_LOCKFILE"; exit 66;; esac' \
  'case " $* " in *" --skip-update "*) ;; *) printf "mutated\n" > "$PIN_TEST_LOCKFILE"; exit 67;; esac' \
  'case " $* " in *" --show-bin-path "*) exit 27;; esac' \
  'exit 0' > "$TMP/bin/swift"
chmod +x "$TMP/bin/swift"

set +e
PATH="$TMP/bin:$PATH" PIN_TEST_CALLS="$TMP/swift.calls" \
  PIN_TEST_LOCKFILE="$FIXTURE/Package.resolved" \
  "$FIXTURE/script/build_and_run.sh" --build-only > "$TMP/build.log" 2>&1
rc=$?
set -e
[[ "$rc" == 27 ]] || { printf 'FAIL: development build did not reach the pinned path lookup (rc=%s)\n' "$rc" >&2; exit 1; }
[[ "$(wc -l < "$TMP/swift.calls" | tr -d ' ')" == 2 ]] \
  || { echo 'FAIL: expected one package build and one binary-path lookup' >&2; exit 1; }
cmp -s "$FIXTURE/Package.resolved" "$TMP/original.resolved" \
  || { echo 'FAIL: development build altered reviewed dependency pins' >&2; exit 1; }
rg -q -- '--show-bin-path' "$TMP/swift.calls" \
  || { echo 'FAIL: binary-path lookup did not use the guarded build path' >&2; exit 1; }

# Exercise the actual canonical SwiftPM section, including every shard, without
# running unrelated gates or compiling the app. The real inventory helper still
# verifies package bytes while the SwiftPM stand-in records and checks arguments.
mkdir -p "$FIXTURE/Modules/NativeAgentCore/Sources" "$FIXTURE/Modules/NativeAgentShared"
cp "$FIXTURE/Package.swift" "$FIXTURE/Modules/NativeAgentCore/Package.swift"
cp "$FIXTURE/Package.resolved" "$FIXTURE/Modules/NativeAgentCore/Package.resolved"
mkdir -p "$TMP/libexec/swift/pm" "$FIXTURE/Modules/NativeAgentCore/.build/debug/NativeAgentCorePackageTests.xctest/Contents/MacOS"
touch "$FIXTURE/Modules/NativeAgentCore/.build/debug/NativeAgentCorePackageTests.xctest/Contents/MacOS/NativeAgentCorePackageTests"
cp "$TMP/bin/swift" "$TMP/libexec/swift/pm/swiftpm-testing-helper"
sed '$i\
echo "✔ Test run with 1 test in 1 suite passed after 0.001 seconds."
' "$TMP/bin/swift" > "$TMP/libexec/swift/pm/swiftpm-testing-helper"
chmod +x "$TMP/libexec/swift/pm/swiftpm-testing-helper"
printf '#!/usr/bin/env bash\ncommand -v swift\n' > "$TMP/bin/xcrun"
chmod +x "$TMP/bin/xcrun"
awk '
  /^# shellcheck source=lib\/build_source_inventory.sh$/ { copying=1 }
  /^echo "\[test\] iOS NativeAgentMobile tests"$/ { copying=0; foundEnd=1 }
  copying { print }
  END { if (!foundEnd) exit 1 }
' "$ROOT/script/test.sh" > "$TMP/canonical-swiftpm.sh"
# Four SwiftPM calls: test-bundle build, XCTest, Shared and App.
# Swift Testing shards use the built bundle through the native helper.
[[ "$(grep -Ec '^[[:space:]]*(gate_run [A-Za-z-]+ )?swift (build|test) ' "$TMP/canonical-swiftpm.sh")" == 4 ]] \
  || { echo 'FAIL: canonical fixture did not capture all four build/package calls' >&2; exit 1; }
for sandbox in 0 1; do
  calls="$TMP/canonical-$sandbox.calls"
  PATH="$TMP/bin:$PATH" PIN_TEST_CALLS="$calls" \
    PIN_TEST_LOCKFILE="$FIXTURE/Package.resolved" \
    ROOT="$FIXTURE" PIN_TEST_SECTION="$TMP/canonical-swiftpm.sh" \
    PIN_TEST_SHARD_COUNT="$TMP/shard-count" PIN_TEST_SANDBOX="$sandbox" \
    bash -euo pipefail -c '
      SWIFTPM_SANDBOX_FLAG=()
      if [[ "$PIN_TEST_SANDBOX" == 1 ]]; then SWIFTPM_SANDBOX_FLAG=(--disable-sandbox); fi
      source "$PIN_TEST_SECTION"
      gate_finish
      printf "%s\n" "${#CORE_SWIFT_TEST_SHARDS[@]}" > "$PIN_TEST_SHARD_COUNT"
    ' > "$TMP/canonical-$sandbox.log" 2>&1 \
    || { echo 'FAIL: canonical SwiftPM calls did not preserve pins' >&2; exit 1; }
  shard_count="$(< "$TMP/shard-count")"
  # Core XCTest + Core test-bundle build + every shard
  # (solo and pooled) + NativeAgentShared + the root package.
  [[ "$(wc -l < "$calls" | tr -d ' ')" == "$((shard_count + 4))" ]] \
    || { echo 'FAIL: canonical fixture missed a build, test package, or shard' >&2; exit 1; }
  # Every shard now reuses the single up-front test-bundle build.
  [[ "$(grep -c -- '--skip-build' "$calls")" == "$((shard_count + 1))" ]] \
    || { echo 'FAIL: canonical shard reuse changed' >&2; exit 1; }
  # The stated hazards stay pinned solo and internally serial; nothing else does.
  [[ "$(grep -c -- '--no-parallel --filter' "$calls")" == 3 ]] \
    || { echo 'FAIL: canonical solo-shard pinning changed' >&2; exit 1; }
  grep -q -- '--disable-swift-testing' "$calls"
  grep -q -- "--package-path $FIXTURE/Modules/NativeAgentShared" "$calls"
  grep -q -- "--package-path $FIXTURE --no-parallel" "$calls"
  cmp -s "$FIXTURE/Package.resolved" "$TMP/original.resolved" \
    || { echo 'FAIL: canonical runner altered reviewed dependency pins' >&2; exit 1; }
  cmp -s "$FIXTURE/Modules/NativeAgentCore/Package.resolved" "$TMP/original.resolved" \
    || { echo 'FAIL: canonical runner altered Core dependency pins' >&2; exit 1; }
done

# The build-check entrypoint must preserve the same dependency pins.
cp "$ROOT/script/smoke_all.sh" "$FIXTURE/script/"
for checker in check_architecture_blueprint check_timer_inventory check_persona_skill_hygiene; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/script/$checker.swift"
  chmod +x "$FIXTURE/script/$checker.swift"
done
PATH="$TMP/bin:$PATH" PIN_TEST_CALLS="$TMP/smoke.calls" \
  PIN_TEST_LOCKFILE="$FIXTURE/Package.resolved" \
  bash "$FIXTURE/script/smoke_all.sh" > "$TMP/smoke.log" 2>&1
[[ "$(grep -c '^build ' "$TMP/smoke.calls")" == 1 ]]
cmp -s "$FIXTURE/Package.resolved" "$TMP/original.resolved"
echo 'development_build_pins_guards_test.sh: all assertions passed'
