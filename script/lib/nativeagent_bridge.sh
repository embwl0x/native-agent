#!/usr/bin/env bash

# Resolve the authenticated local bridge from its atomic descriptor. Each
# install listens on its own port, so the descriptor is the only source of the
# address; explicit environment overrides retain priority.
nativeagent_bridge_resolve() {
  local descriptor="${NATIVE_AGENT_BRIDGE_DESCRIPTOR:-$HOME/.config/claude-bridge/bridge.json}"
  local discovered_url=""
  local discovered_token=""

  if [ -r "$descriptor" ] && [ -x /usr/bin/plutil ]; then
    discovered_url="$(/usr/bin/plutil -extract url raw -o - "$descriptor" 2>/dev/null || true)"
    discovered_token="$(/usr/bin/plutil -extract token raw -o - "$descriptor" 2>/dev/null || true)"
  fi

  BASE_URL="${NATIVE_AGENT_BRIDGE_URL:-$discovered_url}"
  if [ -z "$BASE_URL" ]; then
    echo "NativeAgent bridge descriptor $descriptor has no endpoint; is NativeAgent running?" >&2
    return 1
  fi

  if [ -n "${NATIVE_AGENT_BRIDGE_TOKEN:-}" ]; then
    TOKEN_PATH="$NATIVE_AGENT_BRIDGE_TOKEN"
    BRIDGE_CREDENTIAL_PATH="$NATIVE_AGENT_BRIDGE_TOKEN"
    [ -r "$TOKEN_PATH" ] || {
      echo "bridge token not readable at $TOKEN_PATH; is NativeAgent running?" >&2
      return 1
    }
    TOKEN="$(<"$TOKEN_PATH")"
  elif [ -n "$discovered_token" ]; then
    TOKEN_PATH="$descriptor"
    BRIDGE_CREDENTIAL_PATH="$descriptor"
    TOKEN="$discovered_token"
  else
    echo "NativeAgent bridge descriptor $descriptor has no token; is NativeAgent running?" >&2
    return 1
  fi

  if [ -z "$TOKEN" ]; then
    echo "NativeAgent bridge credential is empty" >&2
    return 1
  fi
}
