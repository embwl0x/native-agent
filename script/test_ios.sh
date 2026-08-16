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

usage() {
  echo "usage: $0 [--require]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require) REQUIRE=1 ;;
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
if "iPhone 16" in phones:
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
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$ROOT/iOS/NativeAgentMobile/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO
echo "[test-ios] passed"
