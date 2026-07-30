#!/usr/bin/env bash
# RELEASE-2026-05-06: Sparkle EdDSA key generation for NativeAgent
# Outputs private key to ~/.config/nativeagent/sparkle_ed_priv.key
# Prints public key to stdout — paste it into Info.plist as SUPublicEDKey
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="$HOME/.config/nativeagent"
PRIV_KEY="$KEY_DIR/sparkle_ed_priv.key"
PUB_KEY_FILE="$KEY_DIR/sparkle_ed_pub.key"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

echo "==> Sparkle EdDSA key generation for NativeAgent"

# RELEASE-2026-05-06: Try Sparkle's own generate_keys tool first.
# A2.1-2026-07-24: tool discovery now lives in script/lib/sparkle_tools.sh so the
# appcast pipeline and this script cannot drift apart.
# shellcheck source=lib/sparkle_tools.sh
source "$ROOT/script/lib/sparkle_tools.sh"
SPARKLE_GENKEYS="$(sparkle_tool_path generate_keys "$ROOT" || true)"

if [[ -n "$SPARKLE_GENKEYS" ]]; then
  echo "  Using Sparkle generate_keys: $SPARKLE_GENKEYS"
  "$SPARKLE_GENKEYS"
  echo ""
  echo "  Sparkle stored the private key in your Keychain."
  echo "  Export it to a file so script/generate_appcast.sh can sign non-interactively:"
  echo "    \"$SPARKLE_GENKEYS\" -x \"$PRIV_KEY\""
  echo "    chmod 600 \"$PRIV_KEY\""
  echo "  Then set both halves before releasing:"
  echo "    export NATIVEAGENT_SPARKLE_ED_PRIV_KEY=\"$PRIV_KEY\""
  echo "    export NATIVEAGENT_SPARKLE_PUBLIC_KEY=\"\$(\"$SPARKLE_GENKEYS\" -p)\""
  echo "  The public key must be the SUPublicEDKey baked into the app."
  echo ""
  echo "  You do not have to take that on trust: once the key file exists,"
  echo "    ./script/sparkle_ed_public_key.swift \"$PRIV_KEY\""
  echo "  prints the public half derived from the key itself. release.sh and"
  echo "  generate_appcast.sh both refuse to build or sign unless it matches."
  exit 0
fi

echo "  Sparkle generate_keys not found (build Sparkle first via: swift build)."
echo ""
echo "ERROR: Sparkle release keys must be generated with Sparkle's generate_keys tool." >&2
echo "OpenSSL PEM Ed25519 keys are not accepted by Sparkle sign_update --ed-key-file." >&2
echo "Run swift build so Sparkle is checked out, then re-run this script." >&2
exit 1
