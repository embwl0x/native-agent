#!/usr/bin/env bash

set -euo pipefail

HOST_NAME="com.nativeagent.chrome"
DEVELOPMENT_EXTENSION_ID="egdbijiogeeggnmjheomgnnkhmlepfcn"
RELAY_PATH="$HOME/Applications/NativeAgent.app/Contents/MacOS/NativeAgentChromeRelay"
UNINSTALL=0
EXTENSION_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay)
      [[ $# -ge 2 ]] || { echo "missing value for --relay" >&2; exit 2; }
      RELAY_PATH="$2"
      shift 2
      ;;
    --extension-id)
      [[ $# -ge 2 ]] || { echo "missing value for --extension-id" >&2; exit 2; }
      EXTENSION_IDS+=("$2")
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./script/install_chrome_native_host.sh [options]

Options:
  --relay ABSOLUTE_PATH       Relay executable inside NativeAgent.app.
  --extension-id ID           Add an exact 32-letter Chrome extension id.
  --uninstall                 Remove the registered native-host manifest.

The pinned development extension id is always included on install.
USAGE
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="$MANIFEST_DIR/$HOST_NAME.json"

if [[ "$UNINSTALL" == "1" ]]; then
  if [[ -e "$MANIFEST_PATH" ]]; then
    rm -f -- "$MANIFEST_PATH"
    echo "Removed $MANIFEST_PATH"
  fi
  exit 0
fi

[[ "$RELAY_PATH" == /* ]] || { echo "relay path must be absolute" >&2; exit 2; }
[[ -f "$RELAY_PATH" && ! -L "$RELAY_PATH" && -x "$RELAY_PATH" ]] \
  || { echo "relay must be an executable regular file: $RELAY_PATH" >&2; exit 2; }

if (( ${#EXTENSION_IDS[@]} == 0 )); then
  EXTENSION_IDS=("$DEVELOPMENT_EXTENSION_ID")
else
  EXTENSION_IDS=("$DEVELOPMENT_EXTENSION_ID" "${EXTENSION_IDS[@]}")
fi
for extension_id in "${EXTENSION_IDS[@]}"; do
  [[ "$extension_id" =~ ^[a-p]{32}$ ]] \
    || { echo "invalid Chrome extension id: $extension_id" >&2; exit 2; }
done

UNIQUE_EXTENSION_IDS=()
for extension_id in "${EXTENSION_IDS[@]}"; do
  duplicate=0
  for existing_id in "${UNIQUE_EXTENSION_IDS[@]:-}"; do
    if [[ "$existing_id" == "$extension_id" ]]; then
      duplicate=1
      break
    fi
  done
  if [[ "$duplicate" == "0" ]]; then
    UNIQUE_EXTENSION_IDS+=("$extension_id")
  fi
done

mkdir -p "$MANIFEST_DIR"
chmod 0700 "$MANIFEST_DIR"
TEMP_MANIFEST="$(mktemp "$MANIFEST_DIR/.$HOST_NAME.XXXXXX")"
trap 'rm -f -- "$TEMP_MANIFEST"' EXIT

/usr/bin/plutil -create xml1 "$TEMP_MANIFEST"
/usr/bin/plutil -insert name -string "$HOST_NAME" "$TEMP_MANIFEST"
/usr/bin/plutil -insert description -string "NativeAgent Chrome transport relay" "$TEMP_MANIFEST"
/usr/bin/plutil -insert path -string "$RELAY_PATH" "$TEMP_MANIFEST"
/usr/bin/plutil -insert type -string "stdio" "$TEMP_MANIFEST"
/usr/bin/plutil -insert allowed_origins -json '[]' "$TEMP_MANIFEST"

origin_index=0
for extension_id in "${UNIQUE_EXTENSION_IDS[@]}"; do
  origin="chrome-extension://$extension_id/"
  /usr/bin/plutil -insert "allowed_origins.$origin_index" -string "$origin" "$TEMP_MANIFEST"
  origin_index=$((origin_index + 1))
done

/usr/bin/plutil -convert json "$TEMP_MANIFEST"
chmod 0600 "$TEMP_MANIFEST"
mv -f -- "$TEMP_MANIFEST" "$MANIFEST_PATH"
trap - EXIT

echo "Installed $MANIFEST_PATH"
