#!/usr/bin/env bash
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
swift build --package-path "$ROOT"

echo "[smoke] Native tool dispatch: get_persona_doc"
swift run --package-path "$ROOT/Modules/NativeAgentCore" chat-drive \
  dispatch get_persona_doc '{"doc":"SOUL"}'

echo "[smoke] Native tool dispatch: list_skills"
swift run --package-path "$ROOT/Modules/NativeAgentCore" chat-drive \
  dispatch list_skills '{}'

echo "[smoke] Native memory recall"
swift run --package-path "$ROOT/Modules/NativeAgentCore" chat-drive \
  dispatch recall_memory '{"query":"the user","limit":3}'

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

echo "[smoke] Swift-native smoke passed"
