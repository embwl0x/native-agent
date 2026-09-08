#!/usr/bin/env bash
# iOS NativeAgentMobile test runner (2026-07-21 audit): the
# NativeAgentMobileTests suites (incl. ChatStoreMergeTests guarding the
# messages-vanish fix) had no runner and could rot green forever.
#
# Destination: prefers an 'iPhone 16' simulator per the project convention;
# falls back to any available iPhone simulator. The ordinary developer gate
# skips gracefully when CoreSimulator is unavailable. `--require` is the
# release lane: every would-be skip becomes a failure so a Mac-only machine can
# never accidentally certify the iOS half of a public build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj"
SCHEME="NativeAgentMobile"
REQUIRE=0
ONLY_TESTING=""

usage() {
  echo "usage: $0 [--require] [--only-testing TEST_CLASS]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require) REQUIRE=1 ;;
    --only-testing)
      [[ $# -ge 2 && "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { usage; exit 2; }
      ONLY_TESTING="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

skip_or_fail() {
  local reason="$1"
  if [[ "$REQUIRE" -eq 1 ]]; then
    echo "[test-ios] FAIL: $reason (required release proof)" >&2
    exit 1
  fi
  echo "[test-ios] SKIP: $reason"
  exit 0
}

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.runtime/clang-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$ROOT/.runtime/swift-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

if [[ "${NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  skip_or_fail "inside the builder sandbox (NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=1); CoreSimulator is unreachable"
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun simctl list devices available >/dev/null 2>&1; then
  skip_or_fail "no Xcode/simctl available on this machine"
fi

SIM_NAME="$(
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
phones = []
for runtime, devices in (data.get("devices") or {}).items():
    if "iOS" not in runtime:
        continue
    for dev in devices:
        name = dev.get("name") or ""
        if dev.get("isAvailable") and "iPhone" in name:
            phones.append(name)
if "R26-iPhone" in phones:
    print("R26-iPhone")
elif "iPhone 16" in phones:
    print("iPhone 16")
elif phones:
    print(phones[0])
else:
    print("")
'
)"

if [[ -z "$SIM_NAME" ]]; then
  skip_or_fail "no available iOS iPhone simulator installed"
fi

echo "[test-ios] running $SCHEME tests on simulator: $SIM_NAME"
mkdir -p "$ROOT/.runtime/test-ios-results"
RESULT_DIR="$(mktemp -d "$ROOT/.runtime/test-ios-results/run.XXXXXX")"
RESULT_BUNDLE="$RESULT_DIR/tests.xcresult"
echo "[test-ios] result bundle: $RESULT_BUNDLE"
set -- xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$ROOT/iOS/NativeAgentMobile/build/DerivedData" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO
[[ -n "$ONLY_TESTING" ]] && set -- "$@" "-only-testing:NativeAgentMobileTests/$ONLY_TESTING"
build_rc=0
"$@" || build_rc=$?
# Exit zero alone does not prove discovery or execution. Read Xcode's typed
# summary from this exact, fresh run; never borrow an older successful bundle.
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --compact > "$RESULT_DIR/summary.json"
summary_rc=0
python3 -c '
import json, sys
try:
    result = json.load(sys.stdin)
    fields = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    if not isinstance(result, dict) or any(type(result.get(k)) is not int or result[k] < 0 for k in fields):
        raise ValueError("missing or malformed test counts")
    total, passed, failed, skipped, expected = (result[k] for k in fields)
    print(f"[test-ios] counts: {passed} passed, {failed} failed, {skipped} skipped, {total} discovered")
    if result.get("result") != "Passed" or failed or passed == 0:
        raise ValueError("run did not pass with at least one executed passing test")
    if total != passed + failed + skipped + expected:
        raise ValueError("inconsistent test counts")
except Exception as error:
    print("[test-ios] FAIL: invalid execution proof: " + str(error), file=sys.stderr)
    raise SystemExit(1)
if sys.argv[1] == "0":
    print(f"[test-ios] passed: {passed} passed, {skipped} skipped, {expected} expected failures, {total} discovered")
' "$build_rc" < "$RESULT_DIR/summary.json" || summary_rc=$?
[[ "$build_rc" -eq 0 ]] || exit "$build_rc"
exit "$summary_rc"
