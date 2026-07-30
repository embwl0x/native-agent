#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export NATIVEAGENT_IOS_RELEASE_LIB_ONLY=1
# shellcheck source=../ios_release.sh
source "$ROOT/script/ios_release.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

expect_true() {
  "$@" || fail "$*"
}

expect_false() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

expect_true version_is_clean 1.0
expect_true version_is_clean 12.34.567
expect_false version_is_clean 1
expect_false version_is_clean 1.0-beta
expect_true build_is_clean 1
expect_true build_is_clean 902
expect_false build_is_clean 0
expect_false build_is_clean 01

expect_true is_placeholder_identifier ""
expect_true is_placeholder_identifier com.example.nativeagent.mobile
expect_true is_placeholder_identifier '$(UNRESOLVED)'
expect_false is_placeholder_identifier com.nativeagent.mobile
expect_false is_placeholder_identifier 874CVT94G2

canonical_config="$ROOT/iOS/NativeAgentMobile/Config/CanonicalIdentifiers.xcconfig"
release_config="$ROOT/iOS/NativeAgentMobile/Config/Release.xcconfig"
grep -Fqx 'NATIVEAGENT_IOS_BUNDLE_ID = $(NATIVEAGENT_IOS_BUNDLE_PREFIX).ios' \
  "$canonical_config" || fail "canonical iOS bundle identifier"
grep -Fqx 'NATIVEAGENT_IOS_BUNDLE_PREFIX = io.github.embwl0x.nativeagent' \
  "$canonical_config" || fail "canonical public namespace"
grep -Fqx 'NATIVEAGENT_ICLOUD_CONTAINER_ID = iCloud.io.github.embwl0x.nativeagent' \
  "$canonical_config" || fail "canonical CloudKit container"
[[ "$(grep -nF '#include? "Local.xcconfig"' "$release_config" | cut -d: -f1)" -lt \
   "$(grep -nF '#include "CanonicalIdentifiers.xcconfig"' "$release_config" | cut -d: -f1)" ]] ||
  fail "Release must reassert canonical identifiers after local account material"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

PRODUCTION_CLOUDKIT_SCHEMA="$ROOT/distribution/cloudkit/NativeAgent.ckdb"
LOCAL_FAILURES=0
check_production_cloudkit_schema >/dev/null
[[ "$LOCAL_FAILURES" == "0" ]] || fail "complete production schema proof"
LOCAL_FAILURES=2
schema_output="$(check_production_cloudkit_schema)"
[[ "$LOCAL_FAILURES" == "2" ]] || fail "schema proof must not disturb earlier failures"
grep -Fq '[PASS] fresh production CloudKit export contains the device-sync schema' \
  <<<"$schema_output" || fail "schema pass must remain visible after earlier failures"
printf 'DEFINE SCHEMA\n' >"$fixture/incomplete.ckdb"
PRODUCTION_CLOUDKIT_SCHEMA="$fixture/incomplete.ckdb"
LOCAL_FAILURES=0
check_production_cloudkit_schema >/dev/null 2>&1
[[ "$LOCAL_FAILURES" -gt 0 ]] || fail "incomplete production schema must fail"
LOCAL_FAILURES=0
sed '/notificationEventId/d' \
  "$ROOT/distribution/cloudkit/NativeAgent.ckdb" >"$fixture/no-visual-event.ckdb"
PRODUCTION_CLOUDKIT_SCHEMA="$fixture/no-visual-event.ckdb"
check_production_cloudkit_schema >/dev/null 2>&1
[[ "$LOCAL_FAILURES" -gt 0 ]] ||
  fail "production schema without visual event identity must fail"
LOCAL_FAILURES=0

cp "$ROOT/distribution/ios/ExportOptions-AppStore.plist" "$fixture/options.plist"
team="ABCDE12345"
sed "s/__NATIVEAGENT_TEAM_ID__/$team/g" "$fixture/options.plist" >"$fixture/resolved.plist"
expect_true plutil -lint "$fixture/resolved.plist"
[[ "$(plist_value "$fixture/resolved.plist" teamID)" == "$team" ]] ||
  fail "runtime team injection"
[[ "$(plist_value "$fixture/resolved.plist" method)" == "app-store-connect" ]] ||
  fail "App Store Connect method"
[[ "$(plist_value "$fixture/resolved.plist" destination)" == "export" ]] ||
  fail "local export destination"
[[ "$(plist_value "$fixture/resolved.plist" signingStyle)" == "automatic" ]] ||
  fail "automatic signing"

cat >"$fixture/profile.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
<key>ExpirationDate</key><date>2035-01-01T00:00:00Z</date>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>ABCDE12345.com.nativeagent.mobile</string>
<key>aps-environment</key><string>production</string>
<key>beta-reports-active</key><true/>
<key>get-task-allow</key><false/>
<key>com.apple.developer.icloud-container-environment</key><string>Production</string>
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.nativeagent</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string><string>CloudKit</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.com.nativeagent</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>ABCDE12345.com.nativeagent.mobile</string>
<key>com.apple.developer.usernotifications.time-sensitive</key><true/>
</dict></dict></plist>
PLIST
TEAM_ID="ABCDE12345"
BUNDLE_ID="com.nativeagent.mobile"
CONTAINER_ID="iCloud.com.nativeagent"
expect_true profile_matches ignored "$fixture/profile.plist"

cat >"$fixture/modern-profile.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
<key>ExpirationDate</key><date>2035-01-01T00:00:00Z</date>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>ABCDE12345.com.nativeagent.mobile</string>
<key>aps-environment</key><string>production</string>
<key>beta-reports-active</key><true/>
<key>get-task-allow</key><false/>
<key>com.apple.developer.icloud-container-environment</key>
<array><string>Production</string><string>Development</string></array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.nativeagent</string></array>
<key>com.apple.developer.icloud-services</key><string>*</string>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.com.nativeagent</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>ABCDE12345.*</string>
<key>com.apple.developer.usernotifications.time-sensitive</key><true/>
</dict></dict></plist>
PLIST
expect_true profile_matches ignored "$fixture/modern-profile.plist"
/usr/libexec/PlistBuddy \
  -c 'Delete :Entitlements:com.apple.developer.icloud-container-environment:0' \
  "$fixture/modern-profile.plist"
expect_false profile_matches ignored "$fixture/modern-profile.plist"

BUNDLE_ID="com.wrong.mobile"
expect_false profile_matches ignored "$fixture/profile.plist"
BUNDLE_ID="com.nativeagent.mobile"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:get-task-allow true' "$fixture/profile.plist"
expect_false profile_matches ignored "$fixture/profile.plist"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:get-task-allow false' "$fixture/profile.plist"
/usr/libexec/PlistBuddy -c 'Add :ProvisionedDevices array' "$fixture/profile.plist"
/usr/libexec/PlistBuddy -c 'Add :ProvisionedDevices:0 string DEVICE' "$fixture/profile.plist"
expect_false profile_matches ignored "$fixture/profile.plist"

if NATIVEAGENT_IOS_RELEASE_LIB_ONLY=0 "$ROOT/script/ios_release.sh" --upload \
    >"$fixture/upload.out" 2>&1; then
  fail "release script must not expose an upload mode"
fi
grep -q 'Unknown option: --upload' "$fixture/upload.out" ||
  fail "release script must explicitly reject upload"
grep -Fq 'validate_signed_app "$app" "Archived" 0' "$ROOT/script/ios_release.sh" ||
  fail "archive validation must allow Xcode development signing before export"
grep -Fq 'validate_signed_app "$exported_app" "Exported" 1' "$ROOT/script/ios_release.sh" ||
  fail "exported IPA validation must require App Store distribution signing"

printf 'ok - ios_release deterministic checks\n'
