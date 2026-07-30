#!/usr/bin/env bash

# Resolve the authenticated local bridge from its atomic descriptor. Explicit
# environment overrides retain priority; the fixed endpoint/token path remain
# compatibility fallbacks for an older installed app.
nativeagent_bridge_resolve() {
  local descriptor="${NATIVE_AGENT_BRIDGE_DESCRIPTOR:-$HOME/.config/claude-bridge/bridge.json}"
  local legacy_token_path="${NATIVE_AGENT_BRIDGE_TOKEN:-$HOME/.config/claude-bridge/token}"
  local discovered_url=""
  local discovered_token=""

  if [ -r "$descriptor" ] && [ -x /usr/bin/plutil ]; then
    discovered_url="$(/usr/bin/plutil -extract url raw -o - "$descriptor" 2>/dev/null || true)"
    discovered_token="$(/usr/bin/plutil -extract token raw -o - "$descriptor" 2>/dev/null || true)"
  fi

  BASE_URL="${NATIVE_AGENT_BRIDGE_URL:-${discovered_url:-http://127.0.0.1:8771}}"
  TOKEN_PATH="$legacy_token_path"
  BRIDGE_CREDENTIAL_PATH="$legacy_token_path"

  if [ -n "${NATIVE_AGENT_BRIDGE_TOKEN:-}" ]; then
    [ -r "$legacy_token_path" ] || {
      echo "bridge token not readable at $legacy_token_path; is NativeAgent running?" >&2
      return 1
    }
    TOKEN="$(<"$legacy_token_path")"
  elif [ -n "$discovered_token" ]; then
    TOKEN="$discovered_token"
    BRIDGE_CREDENTIAL_PATH="$descriptor"
  elif [ -r "$legacy_token_path" ]; then
    TOKEN="$(<"$legacy_token_path")"
  else
    echo "NativeAgent bridge descriptor/token is not readable; is NativeAgent running?" >&2
    return 1
  fi

  if [ -z "$TOKEN" ]; then
    echo "NativeAgent bridge credential is empty" >&2
    return 1
  fi
}
