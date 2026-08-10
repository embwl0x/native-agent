#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <app-bundle> <expected-source-revision> <expected-dirty:true|false> [timeout-seconds]" >&2
  exit 2
fi

APP_BUNDLE="$1"
EXPECTED_REVISION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
EXPECTED_DIRTY="$3"
TIMEOUT_SECONDS="${4:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nativeagent_bridge.sh
source "$SCRIPT_DIR/lib/nativeagent_bridge.sh"

if [[ "$EXPECTED_DIRTY" != "true" && "$EXPECTED_DIRTY" != "false" ]]; then
  echo "expected-dirty must be true or false" >&2
  exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( TIMEOUT_SECONDS < 1 )); then
  echo "timeout-seconds must be a positive integer" >&2
  exit 2
fi

EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NativeAgentApp"
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
  running_revision="$(/usr/bin/plutil -extract buildIdentity.sourceRevision raw -o - "$state_file" 2>/dev/null || true)"
  running_dirty="$(/usr/bin/plutil -extract buildIdentity.sourceDirty raw -o - "$state_file" 2>/dev/null || true)"
  running_revision="$(printf '%s' "$running_revision" | tr '[:upper:]' '[:lower:]')"
  running_dirty="$(printf '%s' "$running_dirty" | tr '[:upper:]' '[:lower:]')"

  if [[ "$chat_ready" != "true" ]]; then
    last_reason="bridge answered but chatReady is not true"
  elif [[ "$running_revision" != "$EXPECTED_REVISION" ]]; then
    last_reason="running source revision '$running_revision' does not match '$EXPECTED_REVISION'"
  elif [[ "$running_dirty" != "$EXPECTED_DIRTY" ]]; then
    last_reason="running dirty state '$running_dirty' does not match '$EXPECTED_DIRTY'"
  else
    echo "ready: authenticated bridge, chat, and source identity verified"
    exit 0
  fi
  sleep 0.25
done

echo "not ready after ${TIMEOUT_SECONDS}s: $last_reason" >&2
exit 1
