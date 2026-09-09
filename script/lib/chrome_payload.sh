#!/usr/bin/env bash

# Shared release/development payload. Call before signing a fresh app bundle.
stage_chrome_payload() {
  local root="$1" bundle="$2" relay_bin="$3"
  local extension_source="$root/Extensions/NativeAgentChrome"
  local extension_bundle="$bundle/Contents/Resources/NativeAgentChrome"
  cp "$relay_bin" "$bundle/Contents/MacOS/NativeAgentChromeRelay"
  chmod 0755 "$bundle/Contents/MacOS/NativeAgentChromeRelay"
  mkdir -p "$extension_bundle"
  cp "$extension_source/manifest.json" "$extension_bundle/manifest.json"
  cp -R "$extension_source/src" "$extension_bundle/src"
}
