#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTITLEMENT_FILES=(
  "$ROOT/NativeAgent.adhoc.entitlements"
  "$ROOT/NativeAgent.public.entitlements"
  "$ROOT/NativeAgent.cloudkit-public.entitlements"
  "$ROOT/NativeAgent.entitlements"
)
ADHOC_ENTITLEMENTS="${ENTITLEMENT_FILES[0]}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

plutil -lint "$ADHOC_ENTITLEMENTS" >/dev/null \
  || fail "ad-hoc entitlements plist is invalid"

for entitlements in "${ENTITLEMENT_FILES[@]}"; do
  plutil -lint "$entitlements" >/dev/null \
    || fail "entitlements plist is invalid: $entitlements"
  calendar_access="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.personal-information.calendars' \
      "$entitlements" 2>/dev/null || true
  )"
  [[ "$calendar_access" == "true" ]] \
    || fail "$entitlements must carry the Calendar entitlement required by hardened-runtime TCC"
done

CLOUDKIT_PUBLIC="$ROOT/NativeAgent.cloudkit-public.entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.aps-environment' "$CLOUDKIT_PUBLIC")" == "production" ]] \
  || fail "CloudKit public template must use production APNS"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$CLOUDKIT_PUBLIC")" == "Production" ]] \
  || fail "CloudKit public template must use the Production CloudKit environment"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$CLOUDKIT_PUBLIC")" == "iCloud.io.github.embwl0x.nativeagent" ]] \
  || fail "CloudKit public template must use the permanent public container"
grep -Fq '<string>CloudKit</string>' "$CLOUDKIT_PUBLIC" \
  || fail "CloudKit public template must declare CloudKit"
for forbidden in CloudDocuments ubiquity-kvstore ubiquity-container background-tasks; do
  ! grep -Fq "$forbidden" "$CLOUDKIT_PUBLIC" \
    || fail "CloudKit public template must not declare $forbidden"
done
for production_entitlements in \
  "$ROOT/NativeAgent.public.entitlements" \
  "$ROOT/NativeAgent.cloudkit-public.entitlements"; do
  ! grep -Eq 'disable-library-validation|allow-unsigned-executable-memory|allow-dyld-environment-variables' \
      "$production_entitlements" \
    || fail "production entitlements carry unnecessary hardened-runtime exceptions: $production_entitlements"
done

library_validation="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.cs.disable-library-validation' \
    "$ADHOC_ENTITLEMENTS" 2>/dev/null || true
)"
[[ "$library_validation" == "true" ]] \
  || fail "hardened-runtime ad-hoc builds must disable library validation so bundled Sparkle can load without a Team ID"

for signer in script/release.sh script/build_and_run.sh script/install_app.sh; do
  grep -Fq 'NativeAgent.adhoc.entitlements' "$ROOT/$signer" \
    || fail "$signer no longer uses the guarded ad-hoc entitlement contract"
  grep -Eq -- '--options[[:space:]]+runtime' "$ROOT/$signer" \
    || fail "$signer no longer declares its hardened-runtime signing mode"
done

for builder in script/release.sh script/build_and_run.sh; do
  grep -Fq 'NSCalendarsFullAccessUsageDescription' "$ROOT/$builder" \
    || fail "$builder no longer declares Calendar full-access purpose text"
  grep -Fq 'NSCalendarsWriteOnlyAccessUsageDescription' "$ROOT/$builder" \
    || fail "$builder no longer declares Calendar write-only purpose text"
done

grep -Fq '/Developer ID Application/' "$ROOT/script/release.sh" \
  || fail "release dry-run no longer discovers a transferable stable Apple identity"
grep -Fq '/Apple Development/' "$ROOT/script/release.sh" \
  || fail "release dry-run no longer falls back to a local Apple Development identity"
grep -Fq 'may not appear in macOS Privacy & Security permission lists' "$ROOT/script/release.sh" \
  || fail "release dry-run no longer warns when only an ad-hoc TCC identity is available"
grep -Fq 'com.apple.security.personal-information.calendars' "$ROOT/script/verify_release_artifact.sh" \
  || fail "release artifact verification no longer proves the signed Calendar entitlement"
grep -Fq 'verify_public_cloudkit_profile_contract' "$ROOT/script/release.sh" \
  || fail "release preflight no longer proves the public CloudKit profile identity contract"
grep -Fq 'verify_public_cloudkit_profile_contract' "$ROOT/script/verify_release_artifact.sh" \
  || fail "mounted artifact verification no longer proves the embedded CloudKit profile identity contract"
grep -Fq 'chmod 0644 "$BUNDLE/Contents/embedded.provisionprofile"' "$ROOT/script/release.sh" \
  || fail "release packaging no longer makes the embedded public profile readable to normal users"
grep -Fq 'chmod 0644 "$BUNDLE/Contents/embedded.provisionprofile"' "$ROOT/script/build_and_run.sh" \
  || fail "development build packaging no longer normalizes embedded profile readability"
grep -Fq 'chmod 0644 "$TEMP_BUNDLE/Contents/embedded.provisionprofile"' "$ROOT/script/install_app.sh" \
  || fail "development install packaging no longer normalizes embedded profile readability"

# Exercise the shared pure plist contract without requiring a maintainer's
# signed provisioning profiles in the repository.
# shellcheck source=../../script/lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
PROFILE_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-profile-contract.XXXXXX")"
trap 'rm -rf "$PROFILE_FIXTURE_DIR"' EXIT
GOOD_PROFILE="$PROFILE_FIXTURE_DIR/good.plist"
STALE_PROFILE="$PROFILE_FIXTURE_DIR/stale.plist"
DERIVED_ENTITLEMENTS="$PROFILE_FIXTURE_DIR/derived.entitlements"
cat > "$GOOD_PROFILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
  <key>ProvisionsAllDevices</key><true/>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key>
    <string>ABCDE12345.io.github.owner.nativeagent.mac</string>
    <key>com.apple.developer.team-identifier</key>
    <string>ABCDE12345</string>
    <key>com.apple.developer.aps-environment</key><string>production</string>
    <key>com.apple.developer.icloud-container-environment</key><string>Production</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array><string>iCloud.io.github.owner.nativeagent</string></array>
    <key>com.apple.developer.icloud-services</key><string>*</string>
  </dict>
</dict>
</plist>
PLIST
cp "$GOOD_PROFILE" "$STALE_PROFILE"
perl -0pi -e 's/io\.github\.owner\.nativeagent/private\.legacy\.nativeagent/g' "$STALE_PROFILE"

verify_public_cloudkit_profile_contract \
  "$GOOD_PROFILE" \
  "ABCDE12345" \
  "io.github.owner.nativeagent.mac" \
  "iCloud.io.github.owner.nativeagent" \
  || fail "matching public CloudKit profile fixture was rejected"
if verify_public_cloudkit_profile_contract \
  "$STALE_PROFILE" \
  "ABCDE12345" \
  "io.github.owner.nativeagent.mac" \
  "iCloud.io.github.owner.nativeagent" >/dev/null 2>&1; then
  fail "stale app/container profile fixture was accepted"
fi
prepare_public_cloudkit_signing_entitlements \
  "$CLOUDKIT_PUBLIC" \
  "$GOOD_PROFILE" \
  "$DERIVED_ENTITLEMENTS" \
  || fail "could not derive public CloudKit signing entitlements"
verify_profile_identity_contract \
  "$GOOD_PROFILE" \
  "io.github.owner.nativeagent.mac" \
  || fail "matching profile identity fixture was rejected"
if verify_profile_identity_contract \
  "$STALE_PROFILE" \
  "io.github.owner.nativeagent.mac" >/dev/null 2>&1; then
  fail "stale profile identity fixture was accepted"
fi
[[ "$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.application-identifier' \
    "$DERIVED_ENTITLEMENTS"
)" == "ABCDE12345.io.github.owner.nativeagent.mac" ]] \
  || fail "derived CloudKit signing entitlements are missing the profile application identifier"
[[ "$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.team-identifier' \
    "$DERIVED_ENTITLEMENTS"
)" == "ABCDE12345" ]] \
  || fail "derived CloudKit signing entitlements are missing the profile team identifier"
grep -Fq 'prepare_public_cloudkit_signing_entitlements' "$ROOT/script/release.sh" \
  || fail "release no longer derives required CloudKit application/team identifiers"
for signer in script/build_and_run.sh script/install_app.sh; do
  grep -Fq 'prepare_profile_signing_entitlements' "$ROOT/$signer" \
    || fail "$signer no longer derives required profile application/team identifiers"
  grep -Fq 'verify_signed_bundle_profile_identity' "$ROOT/$signer" \
    || fail "$signer no longer verifies signed identity against the embedded profile"
done
grep -Fq 'com.apple.application-identifier' "$ROOT/script/verify_release_artifact.sh" \
  || fail "release artifact verification no longer proves the signed CloudKit application identifier"
grep -Fq 'com.apple.developer.team-identifier' "$ROOT/script/verify_release_artifact.sh" \
  || fail "release artifact verification no longer proves the signed CloudKit team identifier"
grep -Fq 'NativeAgentDeviceSync' "$ROOT/script/release.sh" \
  || fail "release packaging no longer stamps the selected device-sync transport"
grep -Fq 'NATIVEAGENT_MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"' \
  "$ROOT/script/release.sh" \
  || fail "release packaging no longer defaults to the permanent public Mac bundle ID"
grep -Fq 'NATIVEAGENT_BACKGROUND_TASK_PREFIX="${NATIVEAGENT_BACKGROUND_TASK_PREFIX:-io.github.embwl0x.nativeagent}"' \
  "$ROOT/script/release.sh" \
  || fail "release packaging no longer defaults to the permanent public background namespace"
! grep -Fq 'NSCameraUsageDescription' "$ROOT/script/release.sh" \
  || fail "release packaging declares unused Camera access"
! grep -Fq 'NSLocalNetworkUsageDescription' "$ROOT/script/release.sh" \
  || fail "release packaging declares unused Local Network access"
grep -Fq -- '--require-notarized' "$ROOT/script/release.sh" \
  || fail "release lane no longer proves the mounted app is notarized"

echo "PASS: release signing, Calendar purpose, and TCC identity contract"
