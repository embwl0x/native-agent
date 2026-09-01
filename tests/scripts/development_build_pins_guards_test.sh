#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/development-build-pins.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/script/lib" "$FIXTURE/Sources/App" "$TMP/bin"
cp "$ROOT/script/build_and_run.sh" "$FIXTURE/script/build_and_run.sh"
for lib in provisioning_profile_contract development_bundle_signing build_source_inventory; do
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
[[ "$(wc -l < "$TMP/swift.calls" | tr -d ' ')" == 3 ]] \
  || { echo 'FAIL: expected all three SwiftPM build invocations' >&2; exit 1; }
cmp -s "$FIXTURE/Package.resolved" "$TMP/original.resolved" \
  || { echo 'FAIL: development build altered reviewed dependency pins' >&2; exit 1; }
rg -q -- '--product NativeAgentChromeRelay' "$TMP/swift.calls" \
  || { echo 'FAIL: relay product did not use the guarded build path' >&2; exit 1; }
rg -q -- '--show-bin-path' "$TMP/swift.calls" \
  || { echo 'FAIL: binary-path lookup did not use the guarded build path' >&2; exit 1; }

# Exercise the actual canonical SwiftPM section, including every shard, without
# running unrelated gates or compiling the app. The real inventory helper still
# verifies package bytes while the SwiftPM stand-in records and checks arguments.
mkdir -p "$FIXTURE/Modules/NativeAgentCore/Sources" "$FIXTURE/Modules/NativeAgentShared"
cp "$FIXTURE/Package.swift" "$FIXTURE/Modules/NativeAgentCore/Package.swift"
cp "$FIXTURE/Package.resolved" "$FIXTURE/Modules/NativeAgentCore/Package.resolved"
awk '
  /^# shellcheck source=lib\/build_source_inventory.sh$/ { copying=1 }
  /^echo "\[test\] iOS NativeAgentMobile tests"$/ { copying=0; foundEnd=1 }
  copying { print }
  END { if (!foundEnd) exit 1 }
' "$ROOT/script/test.sh" > "$TMP/canonical-swiftpm.sh"
[[ "$(grep -Ec '^[[:space:]]*swift (build|test) ' "$TMP/canonical-swiftpm.sh")" == 5 ]] \
  || { echo 'FAIL: canonical SwiftPM fixture did not capture all five call sites' >&2; exit 1; }
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
      printf "%s\n" "${#CORE_SWIFT_TEST_SHARDS[@]}" > "$PIN_TEST_SHARD_COUNT"
    ' > "$TMP/canonical-$sandbox.log" 2>&1 \
    || { echo 'FAIL: canonical SwiftPM calls did not preserve pins' >&2; exit 1; }
  shard_count="$(< "$TMP/shard-count")"
  [[ "$(wc -l < "$calls" | tr -d ' ')" == "$((shard_count + 4))" ]] \
    || { echo 'FAIL: canonical fixture missed a build, test package, or shard' >&2; exit 1; }
  [[ "$(grep -c -- '--skip-build' "$calls")" == "$((shard_count - 1))" ]] \
    || { echo 'FAIL: canonical shard reuse changed' >&2; exit 1; }
  grep -q -- '--product activity-probe' "$calls"
  grep -q -- '--disable-swift-testing' "$calls"
  grep -q -- "--package-path $FIXTURE/Modules/NativeAgentShared" "$calls"
  grep -q -- "--package-path $FIXTURE --no-parallel" "$calls"
  cmp -s "$FIXTURE/Package.resolved" "$TMP/original.resolved" \
    || { echo 'FAIL: canonical runner altered reviewed dependency pins' >&2; exit 1; }
  cmp -s "$FIXTURE/Modules/NativeAgentCore/Package.resolved" "$TMP/original.resolved" \
    || { echo 'FAIL: canonical runner altered Core dependency pins' >&2; exit 1; }
done

# Occasional evals also build and run chat-drive through the real smoke entrypoint.
# Only external Swift work is replaced; each real SwiftPM argv must preserve pins.
cp "$ROOT/script/evals.sh" "$ROOT/script/smoke_all.sh" "$FIXTURE/script/"
for checker in check_architecture_blueprint check_timer_inventory check_persona_skill_hygiene; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/script/$checker.swift"
  chmod +x "$FIXTURE/script/$checker.swift"
done
cat > "$TMP/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build|test|run)
    printf '%s\n' "$*" >> "$PIN_TEST_CALLS"
    package=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" != --package-path ]] || package="$arg"
      previous="$arg"
    done
    [[ -n "$package" ]] || exit 68
    case " $* " in *" --force-resolved-versions "*) ;; *) printf 'mutated\n' > "$package/Package.resolved"; exit 66;; esac
    case " $* " in *" --skip-update "*) ;; *) printf 'mutated\n' > "$package/Package.resolved"; exit 67;; esac
    if [[ "$1" == test ]]; then
      echo 'Executed 3 tests, with 0 failures (0 unexpected) in 0.01 seconds'
    elif [[ "$1" == run ]]; then
      tool="${@: -2:1}"
      printf '=== %s returned ===\n' "$tool"
      case "$tool" in
        get_persona_doc) echo '"fixture persona"';;
        list_skills) echo '["fixture skill"]';;
        recall_memory) echo '{"status":"ok","memory_available":true,"hits":[]}';;
        tool_load) echo '{"status":"loaded","loaded":["desk_add_item","desk_close","desk_nag_control"]}';;
        desk_add_item|desk_close) echo '{"status":"ok","handle":"fixture-handle"}';;
        desk_read) echo '{"status":"ok","projection":"done: Native Desk smoke close"}';;
        desk_nag_control) echo '{"status":"ok","config":{"enabled":true}}';;
        *) exit 69;;
      esac
      # A valid-looking receipt cannot override a failed executable.
      [[ "${PIN_TEST_FAIL_TOOL:-}" != "$tool" ]] || exit 42
    fi
    ;;
  */agent_instrument.swift) ;; # Interpreter calls must not receive SwiftPM options.
  */evals_ledger_merge.swift)
    if [[ "$2" == validate-overrides ]]; then
      exit 0
    fi
    [[ "$2" == changed-plan ]] || exit 70
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --selections) printf 'core\tModules/NativeAgentCore\tFixtureTests\nshared\tModules/NativeAgentShared\tFixtureTests\n' > "$2";;
        --mappings|--unmapped) : > "$2";;
        --changed-files) printf 'Modules/NativeAgentCore/Sources/Fixture.swift\n' > "$2";;
      esac
      shift 2
    done
    ;;
  *) exit 71;;
esac
STUB
printf '#!/usr/bin/env bash\nprintf "fixture-revision\\n"\n' > "$TMP/bin/git"
chmod +x "$TMP/bin/git" "$TMP/bin/swift"
cp "$TMP/original.resolved" "$FIXTURE/Modules/NativeAgentShared/Package.resolved"
for mode in default live changed; do
  calls="$TMP/evals-$mode.calls"
  args=()
  case "$mode" in
    default) expected_tests=4; expected_runs=8; expected_builds=1;;
    live) args=(--live); expected_tests=5; expected_runs=8; expected_builds=1;;
    changed) args=(--changed fixture); expected_tests=4; expected_runs=0; expected_builds=0;;
  esac
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP" PIN_TEST_CALLS="$calls" \
    bash "$FIXTURE/script/evals.sh" ${args[@]+"${args[@]}"} > "$TMP/evals-$mode.log" 2>&1 \
    || { echo "FAIL: $mode evals did not preserve pins" >&2; cat "$TMP/evals-$mode.log" >&2; exit 1; }
  [[ "$(grep -c '^test ' "$calls" || true)" == "$expected_tests" ]]
  [[ "$(grep -c '^run ' "$calls" || true)" == "$expected_runs" ]]
  [[ "$(grep -c '^build ' "$calls" || true)" == "$expected_builds" ]]
  for package in "$FIXTURE" "$FIXTURE/Modules/NativeAgentCore" "$FIXTURE/Modules/NativeAgentShared"; do
    cmp -s "$package/Package.resolved" "$TMP/original.resolved" \
      || { echo "FAIL: $mode evals altered $package dependency pins" >&2; exit 1; }
  done
done
# Each dispatch class must preserve command failure before parsing even when
# chat-drive prints the complete success-shaped payload. No later Desk mutation
# may execute after the failed step, especially the captured create handle.
for failed_tool in get_persona_doc desk_add_item desk_close; do
  calls="$TMP/smoke-failed-$failed_tool.calls"
  smoke_rc=0
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP" PIN_TEST_CALLS="$calls" PIN_TEST_FAIL_TOOL="$failed_tool" \
    bash "$FIXTURE/script/smoke_all.sh" > "$TMP/smoke-failed-$failed_tool.log" 2>&1 || smoke_rc=$?
  [[ "$smoke_rc" == 42 ]] || { echo "FAIL: smoke lost $failed_tool exit42 (got $smoke_rc)" >&2; exit 1; }
  [[ "$(tail -n 1 "$calls")" == *" dispatch $failed_tool "* ]] \
    || { echo "FAIL: smoke dispatched more tools after $failed_tool failed" >&2; exit 1; }
  grep -Fq "$failed_tool dispatch failed (exit 42)" "$TMP/smoke-failed-$failed_tool.log" \
    || { echo "FAIL: smoke hid $failed_tool transport failure" >&2; exit 1; }
  if grep -Fq 'Swift-native smoke passed' "$TMP/smoke-failed-$failed_tool.log"; then
    echo "FAIL: smoke claimed success after $failed_tool failed" >&2
    exit 1
  fi
done
echo 'development_build_pins_guards_test.sh: all assertions passed'
