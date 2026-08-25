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

dispatch_json() {
  local tool="$1"
  local input="$2"
  local output
  output="$(swift run --package-path "$ROOT/Modules/NativeAgentCore" chat-drive \
    dispatch "$tool" "$input")"
  # chat-drive prints one human-readable header before the JSON result.  Do
  # not let an exit-zero executable with a malformed or empty payload count as
  # a successful native-tool smoke.
  printf '%s\n' "$output" | awk -v marker="=== $tool returned ===" '
    $0 == marker { found = 1; next }
    found { print }
    END { if (!found) exit 1 }
  '
}

dispatch_json_at_root() {
  local data_root="$1"
  local tool="$2"
  local input="$3"
  local output
  output="$(NATIVE_AGENT_DATA_ROOT="$data_root" swift run --package-path "$ROOT/Modules/NativeAgentCore" chat-drive \
    dispatch "$tool" "$input")"
  printf '%s\n' "$output" | awk -v marker="=== $tool returned ===" '
    $0 == marker { found = 1; next }
    found { print }
    END { if (!found) exit 1 }
  '
}

require_persona_document() {
  jq -e 'type == "string" and length > 0' >/dev/null
}

require_skill_manifest() {
  jq -e 'type == "array" and length > 0' >/dev/null
}

require_memory_recall_receipt() {
  jq -e '
    type == "object"
    and .status == "ok"
    and .memory_available == true
    and (.hits | type == "array")
  ' >/dev/null
}

require_desk_tool_load_receipt() {
  jq -e '
    type == "object"
    and .status == "loaded"
    and (.loaded | type == "array"
      and index("desk_add_item") != null
      and index("desk_close") != null
      and index("desk_nag_control") != null)
  ' >/dev/null
}

require_desk_created_handle() {
  jq -er '
    select(type == "object" and .status == "ok")
    | .handle
    | select(type == "string" and length > 0)
  '
}

require_desk_close_receipt() {
  jq -e '
    type == "object"
    and .status == "ok"
    and (.handle | type == "string" and length > 0)
  ' >/dev/null
}

require_desk_closed_projection() {
  jq -e '
    type == "object"
    and .status == "ok"
    and (.projection | type == "string"
      and contains("done")
      and contains("Native Desk smoke close"))
  ' >/dev/null
}

require_desk_nag_enabled_receipt() {
  jq -e '
    type == "object"
    and .status == "ok"
    and (.config | type == "object" and .enabled == true)
  ' >/dev/null
}

echo "[smoke] Native tool dispatch: get_persona_doc"
dispatch_json get_persona_doc '{"doc":"SOUL"}' | require_persona_document

echo "[smoke] Native tool dispatch: list_skills"
dispatch_json list_skills '{}' | require_skill_manifest

echo "[smoke] Native memory recall"
dispatch_json recall_memory '{"query":"the user","limit":3}' | require_memory_recall_receipt

# Desk mutations are lazy tools, so this is deliberately the real chat-drive
# route: load the visible tools into one durable session, write a seed item,
# close it, then read the same isolated store back. The root is per-run rather
# than the operator's Desk, making this a smoke probe rather than a real task.
DESK_SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-desk-smoke.XXXXXX")"
cleanup_desk_smoke_root() {
  rm -rf -- "$DESK_SMOKE_ROOT"
}
trap cleanup_desk_smoke_root EXIT
DESK_SMOKE_SESSION="smoke-desk"

echo "[smoke] Native Desk mutation lane"
dispatch_json_at_root "$DESK_SMOKE_ROOT" tool_load \
  "{\"session_id\":\"$DESK_SMOKE_SESSION\",\"names\":[\"desk_add_item\",\"desk_close\",\"desk_nag_control\"]}" \
  | require_desk_tool_load_receipt
DESK_SMOKE_HANDLE="$(dispatch_json_at_root "$DESK_SMOKE_ROOT" desk_add_item \
  "{\"session_id\":\"$DESK_SMOKE_SESSION\",\"kind\":\"plan\",\"project\":\"smoke\",\"title\":\"Native Desk smoke close\"}" \
  | require_desk_created_handle)"
DESK_CLOSE_INPUT="$(jq -cn --arg session "$DESK_SMOKE_SESSION" --arg handle "$DESK_SMOKE_HANDLE" \
  '{session_id: $session, handle: $handle, outcome_summary: "smoke verified durable close"}')"
dispatch_json_at_root "$DESK_SMOKE_ROOT" desk_close "$DESK_CLOSE_INPUT" | require_desk_close_receipt
dispatch_json_at_root "$DESK_SMOKE_ROOT" desk_read \
  "{\"session_id\":\"$DESK_SMOKE_SESSION\"}" | require_desk_closed_projection
dispatch_json_at_root "$DESK_SMOKE_ROOT" desk_nag_control \
  "{\"session_id\":\"$DESK_SMOKE_SESSION\",\"action\":\"enable\",\"scope_kind\":\"global\"}" \
  | require_desk_nag_enabled_receipt

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
