#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-chrome.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
BUNDLE="$TMP_ROOT/NativeAgent.app"
CHROME_RELAY_BIN="$TMP_ROOT/NativeAgentChromeRelay"
printf '#!/bin/sh\nexit 0\n' > "$CHROME_RELAY_BIN"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# Exercise the actual release staging, signing and artifact checks without
# building a DMG or using the operator's signing credentials.
source "$ROOT/script/lib/chrome_payload.sh"
eval "$(sed -n '/^sign_nested_plain() {/,/^}/p' "$ROOT/script/release.sh")"
eval "$(sed -n '/^verify_chrome_payload() {/,/^}/p' "$ROOT/script/verify_release_artifact.sh")"
fail() { echo "ERROR: $*" >&2; exit 1; }
codesign() { printf '%s\n' "$@" > "$TMP_ROOT/sign-arguments"; }

stage_chrome_payload "$ROOT" "$BUNDLE" "$CHROME_RELAY_BIN"
verify_chrome_payload "$BUNDLE"
cmp "$CHROME_RELAY_BIN" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
cmp "$ROOT/Extensions/NativeAgentChrome/manifest.json" "$BUNDLE/Contents/Resources/NativeAgentChrome/manifest.json"
diff -r "$ROOT/Extensions/NativeAgentChrome/src" "$BUNDLE/Contents/Resources/NativeAgentChrome/src"
[[ ! -e "$BUNDLE/Contents/Resources/NativeAgentChrome/tests" ]]
for timestamp in --timestamp --timestamp=none; do
  sign_nested_plain 'Fixture Identity' "$timestamp"
  printf '%s\n' --force --sign 'Fixture Identity' --identifier NativeAgentChromeRelay \
    --options runtime "$timestamp" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay" > "$TMP_ROOT/expected-sign-arguments"
  cmp "$TMP_ROOT/expected-sign-arguments" "$TMP_ROOT/sign-arguments"
done

expect_rejection() {
  local expected="$1"
  if (verify_chrome_payload "$BUNDLE") > "$TMP_ROOT/error" 2>&1; then
    fail "incomplete Chrome payload accepted"
  fi
  grep -Fq "$expected" "$TMP_ROOT/error" || fail "unexpected rejection"
}
chmod 0644 "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
expect_rejection 'missing Chrome relay executable'
chmod 0755 "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
mv "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay" "$TMP_ROOT/relay"
expect_rejection 'missing Chrome relay executable'
mv "$TMP_ROOT/relay" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
for resource in manifest.json src/background.js src/browser-workspace.js \
  src/lease-manager.js src/protocol.js src/user-touch.js src/page-agent.js; do
  mv "$BUNDLE/Contents/Resources/NativeAgentChrome/$resource" "$TMP_ROOT/resource"
  expect_rejection "missing Chrome extension resource: $resource"
  mv "$TMP_ROOT/resource" "$BUNDLE/Contents/Resources/NativeAgentChrome/$resource"
done
verify_chrome_payload "$BUNDLE"
echo 'PASS: Chrome release payload stages, signs, and rejects missing components'
