#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <app-bundle> <expected-source-content-id> [timeout-seconds]" >&2
  exit 2
fi

APP_BUNDLE="$1"
EXPECTED_CONTENT_ID="$2"
TIMEOUT_SECONDS="${3:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

if ! [[ "$EXPECTED_CONTENT_ID" =~ ^[0-9a-f]{40}$ || "$EXPECTED_CONTENT_ID" =~ ^[0-9a-f]{64}$ ]]; then
  echo "expected-source-content-id must be a full Git tree ID" >&2
  exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( TIMEOUT_SECONDS < 1 )); then
  echo "timeout-seconds must be a positive integer" >&2
  exit 2
fi

EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NativeAgentApp"
started=$SECONDS
deadline=$((SECONDS + TIMEOUT_SECONDS))
last_reason="runtime did not become ready"
state_file="$(mktemp)"
trap 'rm -f "$state_file"' EXIT

while (( SECONDS < deadline )); do
  if ! pgrep -fx "$EXECUTABLE" >/dev/null 2>&1; then
    last_reason="installed executable is not running"
    sleep 0.25
    continue
  fi

  TOKEN=""
  BASE_URL=""
  if ! nativeagent_bridge_resolve >/dev/null 2>&1; then
    last_reason="authenticated bridge descriptor is not ready"
    sleep 0.25
    continue
  fi
  if ! curl -fsS --max-time 2 \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/json" \
      "$BASE_URL/codex/state" >"$state_file"; then
    last_reason="authenticated /codex/state is not reachable"
    sleep 0.25
    continue
  fi

  chat_ready="$(/usr/bin/plutil -extract chatReady raw -o - "$state_file" 2>/dev/null || true)"
  running_content_id="$(/usr/bin/plutil -extract buildIdentity.sourceContentID raw -o - "$state_file" 2>/dev/null || true)"

  if [[ "$chat_ready" != "true" ]]; then
    last_reason="bridge answered but chatReady is not true"
  elif [[ "$running_content_id" != "$EXPECTED_CONTENT_ID" ]]; then
    last_reason="running source content '$running_content_id' does not match '$EXPECTED_CONTENT_ID'"
  else
    echo "ready: authenticated bridge, chat, and source identity verified in $((SECONDS - started))s"
    exit 0
  fi
  sleep 0.25
done

echo "not ready after ${TIMEOUT_SECONDS}s: $last_reason" >&2
exit 1
