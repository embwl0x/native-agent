#!/usr/bin/env bash
# Build check: static source checks and a Swift build only by default.
# --live also verifies installed bridge/chat readiness and exact build identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0

usage() {
  echo "usage: $0 [--live]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

echo "[smoke] architecture blueprint drift"
"$ROOT/script/check_architecture_blueprint.swift" --repo "$ROOT"

echo "[smoke] production timer/deadline ownership"
"$ROOT/script/check_timer_inventory.swift" --repo "$ROOT"

echo "[smoke] persona hygiene"
"$ROOT/script/check_persona_skill_hygiene.swift" --repo "$ROOT"

echo "[smoke] Swift build"
swift build --disable-keychain --force-resolved-versions --skip-update --package-path "$ROOT"

if [[ "$LIVE" -eq 1 ]]; then
  APP_BUNDLE="${NATIVE_AGENT_INSTALLED_APP:-$HOME/Applications/NativeAgent.app}"
  REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || { echo "[smoke] FAIL: --live requires an exact Git source revision" >&2; exit 1; }
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    DIRTY=true
  else
    DIRTY=false
  fi
  echo "[smoke] installed runtime: authenticated bridge, chat, and exact build identity"
  "$ROOT/script/verify_installed_runtime_ready.sh" "$APP_BUNDLE" "$REVISION" "$DIRTY" 20
fi

echo "[smoke] Static checks and Swift build passed"
