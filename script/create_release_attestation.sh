#!/usr/bin/env bash
# Bind one final DMG to the exact source/test proof and the release verification
# gates that ran after signing and notarization.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

DMG=""
RECEIPT=""
SOURCE_REVISION=""
VERSION=""
OUTPUT=""
DMG_SIGNATURE_REQUIRED=""
DMG_NOTARIZED=""
DMG_STAPLED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG="${2:-}"; shift 2 ;;
    --test-receipt) RECEIPT="${2:-}"; shift 2 ;;
    --source-revision) SOURCE_REVISION="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --out) OUTPUT="${2:-}"; shift 2 ;;
    --dmg-signature-required) DMG_SIGNATURE_REQUIRED="${2:-}"; shift 2 ;;
    --dmg-notarized) DMG_NOTARIZED="${2:-}"; shift 2 ;;
    --dmg-stapled) DMG_STAPLED="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
[[ -f "$DMG" ]] || fail "DMG is missing: $DMG"
[[ -f "$RECEIPT" ]] || fail "test receipt is missing: $RECEIPT"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "source revision must be a full lowercase Git SHA"
[[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)+$ ]] || fail "invalid release version: $VERSION"
[[ -n "$OUTPUT" ]] || fail "--out is required"
for value in "$DMG_SIGNATURE_REQUIRED" "$DMG_NOTARIZED" "$DMG_STAPLED"; do
  [[ "$value" == "true" || "$value" == "false" ]] || fail "verification flags must be true or false"
done
[[ "$DMG_NOTARIZED" == "$DMG_STAPLED" ]] \
  || fail "DMG notarization and stapling must agree"
if [[ "$DMG_SIGNATURE_REQUIRED" == "true" ]]; then
  [[ "$DMG_NOTARIZED" == "true" ]] \
    || fail "a signed release DMG must be notarized and stapled"
fi

jq -e \
  --arg revision "$SOURCE_REVISION" \
  '.schema_version == 1
   and .source_revision == $revision
   and .source_dirty == false
   and .canonical_gate == "script/test.sh"
   and .ios_required == true
   and .ios_result == "passed"
   and (.completed_at | type == "string" and length > 0)' \
  "$RECEIPT" >/dev/null \
  || fail "test receipt does not prove the exact clean source and required iOS gate"

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
RECEIPT_SHA256="$(shasum -a 256 "$RECEIPT" | awk '{print $1}')"
DMG_BYTES="$(wc -c < "$DMG" | tr -d '[:space:]')"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$OUTPUT")"
TMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

jq -n \
  --arg version "$VERSION" \
  --arg source_revision "$SOURCE_REVISION" \
  --arg created_at "$CREATED_AT" \
  --arg receipt_sha256 "$RECEIPT_SHA256" \
  --arg receipt_completed_at "$(jq -r '.completed_at' "$RECEIPT")" \
  --arg dmg_name "$(basename "$DMG")" \
  --arg dmg_sha256 "$DMG_SHA256" \
  --argjson dmg_bytes "$DMG_BYTES" \
  --argjson signature_required "$DMG_SIGNATURE_REQUIRED" \
  --argjson dmg_notarized "$DMG_NOTARIZED" \
  --argjson dmg_stapled "$DMG_STAPLED" \
  '{
    schema_version: 1,
    version: $version,
    source_revision: $source_revision,
    created_at: $created_at,
    test_receipt: {
      sha256: $receipt_sha256,
      canonical_gate: "script/test.sh",
      source_dirty: false,
      ios_required: true,
      ios_result: "passed",
      completed_at: $receipt_completed_at
    },
    dmg: {
      name: $dmg_name,
      sha256: $dmg_sha256,
      byte_length: $dmg_bytes,
      signature_required: $signature_required,
      notarized: $dmg_notarized,
      stapled: $dmg_stapled
    },
    app: {
      notarized: true,
      stapled: true
    },
    verification_tool: "script/verify_release_artifact.sh"
  }' > "$TMP"

mv -f "$TMP" "$OUTPUT"
chmod 0644 "$OUTPUT"
trap - EXIT
echo "==> Release attestation: $OUTPUT"
