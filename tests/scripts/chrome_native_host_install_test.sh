#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-chrome-host-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

INSTALLER="$ROOT/script/install_chrome_native_host.sh"
HOST_PATH="$TEST_HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.nativeagent.chrome.json"
DEV_ID="egdbijiogeeggnmjheomgnnkhmlepfcn"
PROD_FIXTURE_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

HOME="$TEST_HOME" "$INSTALLER" \
  --relay /usr/bin/true \
  --extension-id "$DEV_ID" \
  --extension-id "$PROD_FIXTURE_ID" >/dev/null

[[ -f "$HOST_PATH" && ! -L "$HOST_PATH" ]]
[[ "$(stat -f '%Lp' "$HOST_PATH")" == "600" ]]
[[ "$(/usr/bin/plutil -extract name raw -o - "$HOST_PATH")" == "com.nativeagent.chrome" ]]
[[ "$(/usr/bin/plutil -extract path raw -o - "$HOST_PATH")" == "/usr/bin/true" ]]
[[ "$(/usr/bin/plutil -extract type raw -o - "$HOST_PATH")" == "stdio" ]]
[[ "$(/usr/bin/plutil -extract allowed_origins.0 raw -o - "$HOST_PATH")" == "chrome-extension://$DEV_ID/" ]]
[[ "$(/usr/bin/plutil -extract allowed_origins.1 raw -o - "$HOST_PATH")" == "chrome-extension://$PROD_FIXTURE_ID/" ]]
if /usr/bin/plutil -extract allowed_origins.2 raw -o - "$HOST_PATH" >/dev/null 2>&1; then
  echo "duplicate development extension origin was not removed" >&2
  exit 1
fi

if HOME="$TEST_HOME" "$INSTALLER" --relay relative/path >/dev/null 2>&1; then
  echo "relative relay path was accepted" >&2
  exit 1
fi
if HOME="$TEST_HOME" "$INSTALLER" --relay /usr/bin/true --extension-id invalid >/dev/null 2>&1; then
  echo "malformed extension id was accepted" >&2
  exit 1
fi

HOME="$TEST_HOME" "$INSTALLER" --uninstall >/dev/null
[[ ! -e "$HOST_PATH" ]]

echo "chrome native-host install tests passed"
