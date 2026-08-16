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

grep -Fq 'NativeAgent.adhoc.entitlements' "$ROOT/script/release.sh" \
  || fail "release.sh no longer uses the guarded ad-hoc entitlement contract"
grep -Eq -- '--options[[:space:]]+runtime' "$ROOT/script/release.sh" \
  || fail "release.sh no longer declares its hardened-runtime signing mode"

DEVELOPMENT_SIGNING_HELPER="$ROOT/script/lib/development_bundle_signing.sh"
bash -n "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing owner has invalid shell syntax"
grep -Fq 'NativeAgent.adhoc.entitlements' "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing owner lost the ad-hoc entitlement contract"
grep -Eq -- '--options[[:space:]]+runtime' "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing owner lost hardened-runtime signing"
for signer in script/build_and_run.sh script/install_app.sh; do
  grep -Fq 'source "$ROOT/script/lib/development_bundle_signing.sh"' "$ROOT/$signer" \
    || fail "$signer no longer loads the shared development signing owner"
  grep -Fq 'nativeagent_sign_development_bundle' "$ROOT/$signer" \
    || fail "$signer no longer delegates to the shared development signing owner"
  ! grep -Eq '^_(sign_dev_cert|sign_adhoc|verify_signed_bundle|assert_profile_allows_current_mac)\(\)' "$ROOT/$signer" \
    || fail "$signer reintroduced a private copy of the development signing contract"
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
grep -Fq 'chmod 0644 "$bundle/Contents/embedded.provisionprofile"' "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing no longer normalizes embedded profile readability"

# A replacement developer install is not committed until the authenticated
# runtime proves both chat readiness and its exact stamped source identity.
# Keep the previous bundle available through that gate and restore it on a
# failed launch/readiness check.
INSTALLER="$ROOT/script/install_app.sh"
READINESS="$ROOT/script/verify_installed_runtime_ready.sh"
[[ -x "$READINESS" ]] \
  || fail "installed-runtime readiness verifier is missing or not executable"
bash -n "$INSTALLER" "$READINESS" \
  || fail "installer/readiness scripts have invalid shell syntax"
grep -Fq 'LOCAL_ENV="$ROOT/local/nativeagent.local.env"' "$INSTALLER" \
  || fail "installer no longer loads the machine-local signing identity used by build_and_run"
grep -Fq 'source "$LOCAL_ENV"' "$INSTALLER" \
  || fail "installer no longer applies the machine-local signing identity before its final signing pass"
grep -Fq 'verify_installed_runtime_ready.sh' "$INSTALLER" \
  || fail "installer no longer gates commit on authenticated runtime readiness"
grep -Fq 'rm -rf "$APP_OLD"' "$INSTALLER" \
  || fail "installer no longer retains the previous bundle until readiness succeeds"
grep -Fq 'mv "$APP_OLD" "$APP_DEST"' "$INSTALLER" \
  || fail "installer no longer restores the previous bundle after failed readiness"
grep -Fq '/codex/state' "$READINESS" \
  || fail "readiness verifier no longer uses the authenticated state surface"
grep -Fq 'chatReady' "$READINESS" \
  || fail "readiness verifier no longer proves chat readiness"
grep -Fq 'buildIdentity.sourceRevision' "$READINESS" \
  || fail "readiness verifier no longer proves exact source revision"
grep -Fq 'buildIdentity.sourceDirty' "$READINESS" \
  || fail "readiness verifier no longer proves exact source dirty state"

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
grep -Fq 'prepare_profile_signing_entitlements' "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing no longer derives required profile application/team identifiers"
grep -Fq 'verify_signed_bundle_profile_identity' "$DEVELOPMENT_SIGNING_HELPER" \
  || fail "shared development signing no longer verifies signed identity against the embedded profile"

# Exercise the shared decision tree with command-level fixtures. Because both
# build_and_run.sh and install_app.sh delegate their bundle/profile/root inputs
# to this exact owner, this matrix protects both callers without performing a
# real install or requiring private signing material.
(
  # shellcheck source=../../script/lib/development_bundle_signing.sh
  source "$DEVELOPMENT_SIGNING_HELPER"

  SIGNING_FIXTURE_ROOT="$PROFILE_FIXTURE_DIR/development-signing"
  SIGNING_FIXTURE_BUNDLE="$SIGNING_FIXTURE_ROOT/NativeAgent.app"
  SIGNING_COMMAND_LOG="$SIGNING_FIXTURE_ROOT/codesign.log"
  mkdir -p \
    "$SIGNING_FIXTURE_BUNDLE/Contents/Frameworks/Sparkle.framework" \
    "$SIGNING_FIXTURE_ROOT/local"
  cp "$ADHOC_ENTITLEMENTS" "$SIGNING_FIXTURE_ROOT/NativeAgent.adhoc.entitlements"
  cp "$ADHOC_ENTITLEMENTS" "$SIGNING_FIXTURE_ROOT/local/NativeAgent.entitlements"
  printf 'fixture-profile\n' > "$SIGNING_FIXTURE_ROOT/local/NativeAgent.provisionprofile"

  security() {
    if [[ "$*" == "find-identity -v -p codesigning" ]]; then
      printf '%s\n' "${SIGNING_FIXTURE_IDENTITIES:-}"
      return 0
    fi
    return 1
  }
  system_profiler() { return 0; }
  codesign() {
    printf '%s\n' "$*" >> "$SIGNING_COMMAND_LOG"
    if [[ "${SIGNING_FIXTURE_FAIL_DEV_SIGN:-0}" == "1" && " $* " == *" --generate-entitlement-der "* ]]; then
      return 1
    fi
    return 0
  }
  _nativeagent_assert_profile_allows_current_mac() { return 0; }
  decode_provisioning_profile() { cp "$1" "$2"; }
  verify_profile_identity_contract() { return 0; }
  prepare_profile_signing_entitlements() { cp "$1" "$3"; }
  verify_signed_bundle_profile_identity() { return 0; }

  # Explicit ad-hoc: nested framework, guarded entitlement payload, then deep
  # verification. This remains the same contract with or without local certs.
  : > "$SIGNING_COMMAND_LOG"
  SIGNING_FIXTURE_IDENTITIES=""
  unset NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY NATIVE_AGENT_DEVELOPER_ID
  unset NATIVE_AGENT_ADHOC_FALLBACK SIGNING_FIXTURE_FAIL_DEV_SIGN
  NATIVE_AGENT_ADHOC=1 nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null
  grep -Fq -- '--deep --sign - --options runtime --timestamp=none' "$SIGNING_COMMAND_LOG" \
    || fail "shared explicit ad-hoc path no longer signs the nested framework with hardened runtime"
  grep -Fq -- '--sign - --entitlements' "$SIGNING_COMMAND_LOG" \
    || fail "shared explicit ad-hoc path no longer signs with guarded entitlements"
  grep -Fq -- '--verify --deep --strict --verbose=2' "$SIGNING_COMMAND_LOG" \
    || fail "shared explicit ad-hoc path no longer performs final deep verification"

  # A stale override may not force ad-hoc when another real identity exists.
  SIGNING_FIXTURE_IDENTITIES='  1) FIXTURE "Apple Development: Fixture"'
  NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY="Apple Development: Missing"
  if NATIVE_AGENT_ADHOC=0 nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null 2>&1; then
    fail "shared signing accepted a stale explicit identity while a real identity existed"
  fi

  # Complete development chain: embed a readable profile, derive identity
  # entitlements, sign with DER entitlements, then deep-verify.
  unset NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY NATIVE_AGENT_ADHOC
  : > "$SIGNING_COMMAND_LOG"
  nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null
  [[ "$(stat -f '%Lp' "$SIGNING_FIXTURE_BUNDLE/Contents/embedded.provisionprofile")" == "644" ]] \
    || fail "shared development path did not normalize the embedded profile to 0644"
  grep -Fq -- '--generate-entitlement-der --entitlements' "$SIGNING_COMMAND_LOG" \
    || fail "shared development path no longer signs with profile-derived DER entitlements"
  grep -Fq -- '--verify --deep --strict --verbose=2' "$SIGNING_COMMAND_LOG" \
    || fail "shared development path no longer performs final deep verification"

  # A real dev-cert signing failure remains fail-closed unless the existing
  # explicit fallback switch is enabled.
  : > "$SIGNING_COMMAND_LOG"
  SIGNING_FIXTURE_FAIL_DEV_SIGN=1
  unset NATIVE_AGENT_ADHOC_FALLBACK
  if nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null 2>&1; then
    fail "shared development path silently fell back after dev-cert signing failed"
  fi
  ! grep -Fq -- '--sign - --entitlements' "$SIGNING_COMMAND_LOG" \
    || fail "shared development path performed an unauthorized ad-hoc fallback"

  : > "$SIGNING_COMMAND_LOG"
  NATIVE_AGENT_ADHOC_FALLBACK=1 nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null 2>&1
  grep -Fq -- '--sign - --entitlements' "$SIGNING_COMMAND_LOG" \
    || fail "shared development path did not honor explicit ad-hoc fallback"

  # Profile/identity-integrity failures are never eligible for that fallback.
  verify_profile_identity_contract() { return 1; }
  : > "$SIGNING_COMMAND_LOG"
  if NATIVE_AGENT_ADHOC_FALLBACK=1 nativeagent_sign_development_bundle \
    "$SIGNING_FIXTURE_BUNDLE" \
    "$SIGNING_FIXTURE_ROOT" \
    "io.github.owner.nativeagent.mac" \
    "[fixture]" >/dev/null 2>&1; then
    fail "shared development path allowed fallback after profile identity failure"
  fi
  ! grep -Fq -- '--sign - --entitlements' "$SIGNING_COMMAND_LOG" \
    || fail "shared development path ad-hoc-signed after profile identity failure"
)

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

# A release must be backed by one exact clean source revision, the complete
# canonical gate, and a real iOS simulator result. Ordinary development tests
# may still skip iOS when CoreSimulator is unavailable.
bash -n \
  "$ROOT/script/test.sh" \
  "$ROOT/script/test_ios.sh" \
  "$ROOT/script/smoke_all.sh" \
  || fail "release test proof scripts have invalid shell syntax"
grep -Fq -- '--release-receipt "$RELEASE_TEST_RECEIPT"' "$ROOT/script/release.sh" \
  || fail "release lane no longer requires an exact-commit canonical test receipt"
grep -Fq -- '--require-ios' "$ROOT/script/release.sh" \
  || fail "release lane no longer requires a real iOS test result"
grep -Fq 'NATIVE_AGENT_PROVIDER_READINESS_TEST=1' "$ROOT/script/test.sh" \
  || fail "canonical gate no longer executes ProviderReadinessTests in its hermetic root"
grep -Fq 'skip_or_fail' "$ROOT/script/test_ios.sh" \
  || fail "iOS test runner no longer distinguishes the optional and release-required lanes"
grep -Fq 'verify_installed_runtime_ready.sh' "$ROOT/script/smoke_all.sh" \
  || fail "smoke_all --live no longer proves the installed runtime"

echo "PASS: release signing, Calendar purpose, and TCC identity contract"
