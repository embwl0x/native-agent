#!/usr/bin/env bash
# iOS NativeAgentMobile test runner (2026-07-21 audit): the
# NativeAgentMobileTests suites (incl. ChatStoreMergeTests guarding the
# messages-vanish fix) had no runner and could rot green forever.
#
# Destination: prefers an 'iPhone 16' simulator per the project convention;
# falls back to any available iPhone simulator; skips gracefully (exit 0)
# when no iOS simulator is installed or when running inside the builder
# sandbox (simctl/CoreSimulator mach services are unreachable there — the
# same NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX pattern script/test.sh uses).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj"
SCHEME="NativeAgentMobile"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.runtime/clang-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$ROOT/.runtime/swift-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

if [[ "${NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  echo "[test-ios] SKIP: inside the builder sandbox (NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=1); CoreSimulator is unreachable"
  exit 0
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun simctl list devices available >/dev/null 2>&1; then
  echo "[test-ios] SKIP: no Xcode/simctl available on this machine"
  exit 0
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
  echo "[test-ios] SKIP: no available iOS iPhone simulator installed"
  exit 0
fi

echo "[test-ios] running $SCHEME tests on simulator: $SIM_NAME"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$ROOT/iOS/NativeAgentMobile/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO
echo "[test-ios] passed"
