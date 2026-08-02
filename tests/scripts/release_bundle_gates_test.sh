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

# A general model vocabulary legitimately contains ordinary names. Exempt only
# the exact verified MemoryV2 payload; app content and lookalikes stay scanned.
mkdir -p "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/Data"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm_vocab.txt"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/Data/model.mlmodel"
if [[ -n "$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')" ]]; then
  echo "FAIL: verified MiniLM payload was not exempted" >&2
  exit 1
fi

printf '%s\n' 'private_fixture_identity' > "$BUNDLE/Contents/Resources/app-owned.txt"
personal_hits="$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')"
if [[ "$personal_hits" != *'/app-owned.txt' ]]; then
  echo "FAIL: app-owned resource identity was not detected" >&2
  exit 1
fi
rm -f "$BUNDLE/Contents/Resources/app-owned.txt"

mkdir -p "$BUNDLE/Contents/Resources/Lookalike.bundle"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/Lookalike.bundle/minilm_vocab.txt"
personal_hits="$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')"
if [[ "$personal_hits" != *'/Lookalike.bundle/minilm_vocab.txt' ]]; then
  echo "FAIL: lookalike model resource was incorrectly exempted" >&2
  exit 1
fi
rm -rf "$BUNDLE/Contents/Resources/Lookalike.bundle"

# Signature metadata is generated after the pre-signing scan and is opaque to
# the app. The mounted-artifact verifier uses this same helper and must not
# interpret signature bytes as app-owned text.
mkdir -p "$BUNDLE/Contents/_CodeSignature"
printf '%s\n' 'private_fixture_identity' > "$BUNDLE/Contents/_CodeSignature/CodeResources"
if [[ -n "$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')" ]]; then
  echo "FAIL: signature metadata was not exempted" >&2
  exit 1
fi
rm -rf "$BUNDLE/Contents/_CodeSignature"

printf '%s\n' 'private_fixture_identity' >> "$BIN"
if NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: configured private identity was accepted" >&2
  exit 1
fi

printf '%s\n' 'release bundle identity gates passed'
