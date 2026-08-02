#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/script/lib/release_bundle_gates.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-gates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BUNDLE="$TMP/NativeAgent.app"
BIN_DIR="$BUNDLE/Contents/MacOS"
mkdir -p "$BIN_DIR"
BIN="$BIN_DIR/NativeAgentApp"

printf '%s\n' 'NativeAgent supports Claude Code and ordinary agent workflows.' > "$BIN"
chmod +x "$BIN"

if NATIVEAGENT_LOCAL_IDENTITY_RE='' NATIVEAGENT_PRIVACY_RE='' \
  NATIVEAGENT_PRIVACY_DENYLIST_FILE='' \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: missing maintainer denylist was accepted" >&2
  exit 1
fi

DENYLIST="$TMP/privacy_denylist.regex"
printf '%s\n' 'private_fixture_identity' > "$DENYLIST"
NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null

printf '%s\n' 'private_fixture_identity' >> "$BIN"
if NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: configured private identity was accepted" >&2
  exit 1
fi

printf '%s\n' 'release bundle identity gates passed'
