#!/usr/bin/env bash
# Static source checks; compilation belongs to the canonical build/install path.
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

echo "[smoke] architecture blueprint drift"
swift "$ROOT/script/generate_architecture_blueprint.swift" --check --repo "$ROOT"

echo "[smoke] production timer/deadline ownership"
"$ROOT/script/check_timer_inventory.swift" --repo "$ROOT"

echo "[smoke] persona hygiene"
"$ROOT/script/check_persona_skill_hygiene.swift" --repo "$ROOT"

if [[ "$LIVE" -eq 1 ]]; then
  APP_BUNDLE="${NATIVE_AGENT_INSTALLED_APP:-$HOME/Applications/NativeAgent.app}"
  source "$ROOT/script/lib/build_source_inventory.sh"
  CONTENT_ID="$(nativeagent_source_content_id "$ROOT")"
  echo "[smoke] installed runtime: authenticated bridge, chat, and exact build identity"
  "$ROOT/script/verify_installed_runtime_ready.sh" "$APP_BUNDLE" "$CONTENT_ID" 20
fi

echo "[smoke] Checks passed"
