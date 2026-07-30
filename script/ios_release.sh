#!/usr/bin/env bash
# NativeAgentMobile App Store readiness, archive, and local export.
#
# This lane is deliberately fail-closed and never uploads or mutates App Store
# Connect. Account-owned upload/submission remains a separate manual action.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj"
SPEC="$ROOT/iOS/NativeAgentMobile/project.yml"
SCHEME="NativeAgentMobile"
PRIVACY_MANIFEST="$ROOT/iOS/NativeAgentMobile/Resources/PrivacyInfo.xcprivacy"
ICON="$ROOT/iOS/NativeAgentMobile/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
ENTITLEMENTS="$ROOT/iOS/NativeAgentMobile/Sources/NativeAgentMobile.entitlements"
EXPORT_TEMPLATE="$ROOT/distribution/ios/ExportOptions-AppStore.plist"
OUTPUT_DIR="${NATIVEAGENT_IOS_RELEASE_OUTPUT_DIR:-$ROOT/dist/ios}"
ARCHIVE_PATH=""
EXPORT_PATH=""
DO_PREFLIGHT=0
DO_ARCHIVE=0
DO_EXPORT=0
LOCAL_FAILURES=0
ACCOUNT_FAILURES=0
TEAM_ID=""
BUNDLE_ID=""
CONTAINER_ID=""
MARKETING_VERSION=""
BUILD_NUMBER=""
APS_ENVIRONMENT=""
ICLOUD_ENVIRONMENT=""
PRIVACY_POLICY_URL=""
SUPPORT_URL=""
PRODUCTION_CLOUDKIT_SCHEMA="${NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA:-}"

usage() {
  cat <<'EOF'
Usage: ./script/ios_release.sh [--preflight] [--archive] [--export]
                               [--output DIR] [--archive-path PATH]

  --preflight       Run local and Apple-account readiness checks (default).
  --archive         Create a signed Release archive after a green preflight.
  --export          Export an existing/new archive to an IPA; never uploads.
  --output DIR      Artifact directory (default: dist/ios).
  --archive-path P  Use P as the archive (required existing archive for
                    --export unless --archive is also selected).
  --help            Show this help.

Exit 2 means a local/source readiness failure.
Exit 3 means local/source checks passed but Apple account material is missing.
EOF
}

local_fail() {
  printf '[LOCAL BLOCKER] %s\n' "$*" >&2
  LOCAL_FAILURES=$((LOCAL_FAILURES + 1))
}

account_fail() {
  printf '[ACCOUNT BLOCKER] %s\n' "$*" >&2
  ACCOUNT_FAILURES=$((ACCOUNT_FAILURES + 1))
}

pass() {
  printf '[PASS] %s\n' "$*"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

plist_array_contains() {
  local file="$1"
  local key="$2"
  local expected="$3"
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null |
    grep -Fqx "    $expected"
}

plist_scalar_or_array_contains() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local value
  value="$(plist_value "$file" "$key" || true)"
  [[ "$value" == "$expected" ]] ||
    plist_array_contains "$file" "$key" "$expected"
}

plist_grant_contains() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local value
  value="$(plist_value "$file" "$key" || true)"
  [[ "$value" == "*" || "$value" == "$expected" ]] ||
    plist_array_contains "$file" "$key" "*" ||
    plist_array_contains "$file" "$key" "$expected"
}

is_placeholder_identifier() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$value" || "$value" == *'$('* || "$value" == *"example"* ||
     "$value" == *"placeholder"* || "$value" == *"changeme"* ]]
}

version_is_clean() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]
}

build_is_clean() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

icon_has_no_alpha() {
  local icon="$1"
  local size alpha
  size="$(sips -g pixelWidth -g pixelHeight "$icon" 2>/dev/null)"
  grep -q 'pixelWidth: 1024' <<<"$size" &&
    grep -q 'pixelHeight: 1024' <<<"$size" || return 1
  alpha="$(sips -g hasAlpha "$icon" 2>/dev/null | awk -F': ' '/hasAlpha:/{print $2}')"
  [[ "$alpha" == "no" ]]
}

read_build_setting() {
  local settings="$1"
  local key="$2"
  awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' <<<"$settings"
}

check_privacy_manifest() {
  if [[ ! -f "$PRIVACY_MANIFEST" ]] ||
     ! plutil -lint "$PRIVACY_MANIFEST" >/dev/null 2>&1; then
    local_fail "PrivacyInfo.xcprivacy is missing or invalid."
    return
  fi
  local tracking
  tracking="$(plist_value "$PRIVACY_MANIFEST" NSPrivacyTracking || true)"
  if [[ "$tracking" != "false" ]]; then
    local_fail "Privacy manifest must explicitly declare NSPrivacyTracking=false."
    return
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' \
      "$PRIVACY_MANIFEST" >/dev/null 2>&1; then
    local_fail "Privacy manifest must declare the required-reason API categories used by the app."
    return
  fi
  pass "privacy manifest is present, valid, and declares tracking=false"
}

check_source_entitlements() {
  if [[ ! -f "$ENTITLEMENTS" ]] || ! plutil -lint "$ENTITLEMENTS" >/dev/null 2>&1; then
    local_fail "NativeAgentMobile entitlements are missing or invalid."
    return
  fi
  local aps icloud_environment
  aps="$(plist_value "$ENTITLEMENTS" aps-environment || true)"
  icloud_environment="$(
    plist_value "$ENTITLEMENTS" com.apple.developer.icloud-container-environment || true
  )"
  if [[ "$APS_ENVIRONMENT" != "production" ]] ||
     [[ "$aps" != "production" && "$aps" != '$(NATIVEAGENT_APS_ENVIRONMENT)' ]]; then
    local_fail "Release aps-environment must resolve to production (source '${aps:-missing}', resolved '${APS_ENVIRONMENT:-missing}')."
  else
    pass "Release APNS entitlement is production"
  fi
  if [[ "$ICLOUD_ENVIRONMENT" != "Production" ]] ||
     [[ "$icloud_environment" != "Production" &&
        "$icloud_environment" != '$(NATIVEAGENT_ICLOUD_ENVIRONMENT)' ]]; then
    local_fail "Release CloudKit container environment must resolve to Production (source '${icloud_environment:-missing}', resolved '${ICLOUD_ENVIRONMENT:-missing}')."
  else
    pass "Release CloudKit container environment is Production"
  fi
  if ! plist_array_contains "$ENTITLEMENTS" \
      com.apple.developer.icloud-services CloudKit; then
    local_fail "CloudKit is absent from the iOS iCloud services entitlement."
  else
    pass "CloudKit entitlement is present"
  fi
}

check_metadata() {
  local metadata="$ROOT/distribution/ios/metadata/en-US"
  local required=(description.txt keywords.txt promotional_text.txt release_notes.txt subtitle.txt)
  local item
  for item in "${required[@]}"; do
    if [[ ! -s "$metadata/$item" ]]; then
      local_fail "App Store metadata draft missing: $metadata/$item"
    fi
  done
  local keywords_bytes promotional_bytes subtitle_bytes
  keywords_bytes="$(wc -c <"$metadata/keywords.txt" 2>/dev/null | tr -d ' ' || true)"
  promotional_bytes="$(wc -c <"$metadata/promotional_text.txt" 2>/dev/null | tr -d ' ' || true)"
  subtitle_bytes="$(wc -c <"$metadata/subtitle.txt" 2>/dev/null | tr -d ' ' || true)"
  [[ "$keywords_bytes" =~ ^[0-9]+$ && "$keywords_bytes" -le 101 ]] ||
    local_fail "App Store keywords exceed the 100-character field (plus final newline)."
  [[ "$promotional_bytes" =~ ^[0-9]+$ && "$promotional_bytes" -le 171 ]] ||
    local_fail "App Store promotional text exceeds the 170-character field (plus final newline)."
  [[ "$subtitle_bytes" =~ ^[0-9]+$ && "$subtitle_bytes" -le 31 ]] ||
    local_fail "App Store subtitle exceeds the 30-character field (plus final newline)."
  if [[ -f "$ROOT/distribution/ios/metadata/ACCOUNT_OWNER_CHECKLIST.md" ]]; then
    pass "App Store metadata drafts and account-owner checklist are present"
  else
    local_fail "App Store account-owner checklist is missing."
  fi
}

check_production_cloudkit_schema() {
  local failures_before="$LOCAL_FAILURES"
  if [[ ! -r "$PRODUCTION_CLOUDKIT_SCHEMA" ]]; then
    local_fail "Set NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA to a fresh production cktool export."
    return
  fi
  local record_type field
  for record_type in NAChatMessage NANotification NAPairingDevice NAStatus; do
    grep -Eq "^[[:space:]]*RECORD TYPE $record_type[[:space:]]*\\(" \
      "$PRODUCTION_CLOUDKIT_SCHEMA" ||
      local_fail "Production CloudKit schema is missing $record_type."
  done
  for field in payloadJSON direction notificationTitle notificationScreen notificationEventId \
      secretHex publishedAt key value updatedAt; do
    grep -Eq "^[[:space:]]*$field[[:space:]]+STRING" "$PRODUCTION_CLOUDKIT_SCHEMA" ||
      local_fail "Production CloudKit schema is missing required field $field."
  done
  if [[ "$LOCAL_FAILURES" == "$failures_before" ]]; then
    pass "fresh production CloudKit export contains the device-sync schema"
  fi
}

decode_profile() {
  security cms -D -i "$1" 2>/dev/null
}

profile_matches() {
  local profile="$1"
  local decoded="$2"
  local app_identifier aps profile_team get_task_allow
  local beta_reports time_sensitive kvstore expiration expiration_epoch now_epoch
  app_identifier="$(plist_value "$decoded" Entitlements:application-identifier || true)"
  aps="$(plist_value "$decoded" Entitlements:aps-environment || true)"
  profile_team="$(plist_value "$decoded" TeamIdentifier:0 || true)"
  get_task_allow="$(plist_value "$decoded" Entitlements:get-task-allow || true)"
  beta_reports="$(plist_value "$decoded" Entitlements:beta-reports-active || true)"
  time_sensitive="$(
    plist_value "$decoded" Entitlements:com.apple.developer.usernotifications.time-sensitive || true
  )"
  kvstore="$(
    plist_value "$decoded" Entitlements:com.apple.developer.ubiquity-kvstore-identifier || true
  )"
  expiration="$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)"
  expiration_epoch="$(date -juf '%Y-%m-%dT%H:%M:%SZ' "$expiration" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  [[ "$profile_team" == "$TEAM_ID" &&
     "$app_identifier" == "$TEAM_ID.$BUNDLE_ID" &&
     "$aps" == "production" &&
     "$get_task_allow" == "false" &&
     "$beta_reports" == "true" &&
     "$time_sensitive" == "true" &&
     "$kvstore" == "$TEAM_ID."* &&
     "$expiration_epoch" =~ ^[0-9]+$ &&
     "$expiration_epoch" -gt "$now_epoch" ]] || return 1
  plist_scalar_or_array_contains "$decoded" \
    Entitlements:com.apple.developer.icloud-container-environment Production || return 1
  # Development/ad-hoc profiles enumerate test devices. App Store profiles do
  # not, and are not Developer ID profiles covering every device.
  ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$decoded" \
      >/dev/null 2>&1 || return 1
  ! /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$decoded" \
      >/dev/null 2>&1 || return 1
  plist_grant_contains "$decoded" \
    Entitlements:com.apple.developer.icloud-services CloudKit || return 1
  plist_grant_contains "$decoded" \
    Entitlements:com.apple.developer.icloud-services CloudDocuments || return 1
  plist_array_contains "$decoded" \
    Entitlements:com.apple.developer.icloud-container-identifiers "$CONTAINER_ID" || return 1
  plist_array_contains "$decoded" \
    Entitlements:com.apple.developer.ubiquity-container-identifiers "$CONTAINER_ID"
}

check_account_material() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if ! grep -E "\"Apple Distribution: .+ \\($TEAM_ID\\)\"" <<<"$identities" >/dev/null; then
    account_fail "No valid Apple Distribution identity for team $TEAM_ID. Create/download it in Xcode Accounts."
  else
    pass "Apple Distribution identity is available for team $TEAM_ID"
  fi

  local profile_dir profile decoded found=0
  local dirs=(
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  for profile_dir in "${dirs[@]}"; do
    [[ -d "$profile_dir" ]] || continue
    while IFS= read -r -d '' profile; do
      decoded="$(mktemp)"
      if decode_profile "$profile" >"$decoded" &&
         profile_matches "$profile" "$decoded"; then
        found=1
        rm -f "$decoded"
        break 2
      fi
      rm -f "$decoded"
    done < <(find "$profile_dir" -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0 2>/dev/null)
  done
  if [[ "$found" == "1" ]]; then
    pass "App Store distribution profile matches the team, bundle, APNS, and iCloud container"
  else
    account_fail "No installed App Store profile matches $BUNDLE_ID with production APNS/CloudKit and $CONTAINER_ID. Refresh profiles in Xcode."
  fi
}

run_preflight() {
  printf 'NativeAgentMobile App Store preflight\n'
  printf '=====================================\n'

  local required_commands=(xcodegen xcodebuild xcrun plutil sips security codesign git ditto)
  local command_name
  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      local_fail "Required command is unavailable: $command_name"
    fi
  done
  [[ "$LOCAL_FAILURES" == "0" ]] || return

  if ! xcodegen --spec "$SPEC" >/dev/null; then
    local_fail "xcodegen could not generate NativeAgentMobile.xcodeproj."
    return
  fi
  pass "xcodegen regenerated the project from its canonical spec"

  local xcode_version sdk_version sdk_path
  xcode_version="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')"
  sdk_version="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  sdk_path="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [[ -z "$xcode_version" || -z "$sdk_version" || ! -d "$sdk_path" ]]; then
    local_fail "A complete Xcode installation with the iPhoneOS SDK is required."
  elif ! awk -v v="$sdk_version" 'BEGIN { exit !((v + 0) >= 26.0) }'; then
    local_fail "iPhoneOS SDK 26.0 or newer is required (found $sdk_version)."
  else
    pass "Xcode $xcode_version with iPhoneOS SDK $sdk_version"
  fi

  local settings
  settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -destination 'generic/platform=iOS' \
    -showBuildSettings NATIVEAGENT_MOBILE_SOURCE_KEY=mobile_app 2>/dev/null)" || {
      local_fail "Could not resolve Release build settings."
      return
    }
  TEAM_ID="$(read_build_setting "$settings" DEVELOPMENT_TEAM)"
  BUNDLE_ID="$(read_build_setting "$settings" PRODUCT_BUNDLE_IDENTIFIER)"
  CONTAINER_ID="$(read_build_setting "$settings" NATIVEAGENT_ICLOUD_CONTAINER_ID)"
  MARKETING_VERSION="$(read_build_setting "$settings" MARKETING_VERSION)"
  BUILD_NUMBER="$(read_build_setting "$settings" CURRENT_PROJECT_VERSION)"
  APS_ENVIRONMENT="$(read_build_setting "$settings" NATIVEAGENT_APS_ENVIRONMENT)"
  ICLOUD_ENVIRONMENT="$(read_build_setting "$settings" NATIVEAGENT_ICLOUD_ENVIRONMENT)"
  PRIVACY_POLICY_URL="$(read_build_setting "$settings" NATIVEAGENT_PRIVACY_POLICY_URL)"
  SUPPORT_URL="$(read_build_setting "$settings" NATIVEAGENT_SUPPORT_URL)"
  local source_key
  source_key="$(read_build_setting "$settings" NATIVEAGENT_MOBILE_SOURCE_KEY)"

  if is_placeholder_identifier "$TEAM_ID"; then
    local_fail "DEVELOPMENT_TEAM must resolve to a real local Apple team."
  fi
  if is_placeholder_identifier "$BUNDLE_ID"; then
    local_fail "PRODUCT_BUNDLE_IDENTIFIER must resolve to a non-placeholder production ID."
  fi
  if is_placeholder_identifier "$CONTAINER_ID" || [[ "$CONTAINER_ID" != iCloud.* ]]; then
    local_fail "NATIVEAGENT_ICLOUD_CONTAINER_ID must resolve to a real iCloud container."
  fi
  if [[ "$source_key" != "mobile_app" ]]; then
    local_fail "NativeAgentMobileSourceKey must resolve to the neutral key 'mobile_app'."
  fi
  if [[ "$PRIVACY_POLICY_URL" != https://* ]] ||
     is_placeholder_identifier "$PRIVACY_POLICY_URL"; then
    local_fail "NATIVEAGENT_PRIVACY_POLICY_URL must be a final public HTTPS URL."
  fi
  if [[ "$SUPPORT_URL" != https://* ]] ||
     is_placeholder_identifier "$SUPPORT_URL"; then
    local_fail "NATIVEAGENT_SUPPORT_URL must be a final public HTTPS URL."
  fi
  if [[ "$LOCAL_FAILURES" == "0" ]]; then
    pass "team, bundle, iCloud container, and neutral mobile source key resolve cleanly"
  fi

  if ! version_is_clean "$MARKETING_VERSION"; then
    local_fail "MARKETING_VERSION must be a clean numeric release version (found '$MARKETING_VERSION')."
  fi
  if ! build_is_clean "$BUILD_NUMBER"; then
    local_fail "CURRENT_PROJECT_VERSION must be a positive integer (found '$BUILD_NUMBER')."
  fi
  if version_is_clean "$MARKETING_VERSION" && build_is_clean "$BUILD_NUMBER"; then
    pass "release version $MARKETING_VERSION ($BUILD_NUMBER) is syntactically clean"
  fi

  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
    local_fail "The repository is dirty. Archive only an exact clean source revision."
  else
    pass "repository source revision is clean"
  fi

  check_privacy_manifest
  check_source_entitlements
  check_metadata
  check_production_cloudkit_schema

  if [[ ! -f "$ICON" ]] || ! icon_has_no_alpha "$ICON"; then
    local_fail "The 1024x1024 App Store icon is missing, incorrectly sized, or contains alpha."
  else
    pass "1024x1024 App Store icon has no alpha channel"
  fi

  if [[ ! -f "$EXPORT_TEMPLATE" ]] ||
     ! plutil -lint "$EXPORT_TEMPLATE" >/dev/null 2>&1 ||
     [[ "$(plist_value "$EXPORT_TEMPLATE" method || true)" != "app-store-connect" ]] ||
     [[ "$(plist_value "$EXPORT_TEMPLATE" signingStyle || true)" != "automatic" ]] ||
     [[ "$(plist_value "$EXPORT_TEMPLATE" destination || true)" != "export" ]] ||
     [[ "$(plist_value "$EXPORT_TEMPLATE" teamID || true)" != "__NATIVEAGENT_TEAM_ID__" ]]; then
    local_fail "ExportOptions template must be valid, automatic app-store-connect export with the identity-neutral team marker."
  else
    pass "export options are local-export-only and inject the team at runtime"
  fi

  if ! is_placeholder_identifier "$TEAM_ID" &&
     ! is_placeholder_identifier "$BUNDLE_ID" &&
     ! is_placeholder_identifier "$CONTAINER_ID"; then
    check_account_material
  fi
}

validate_signed_app() {
  local app="$1"
  local context="$2"
  local require_distribution="${3:-1}"
  local info="$app/Info.plist"
  local signed_entitlements
  signed_entitlements="$(mktemp)"
  if [[ ! -f "$info" ]] || ! codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
     ! codesign -d --entitlements :- "$app" >"$signed_entitlements" 2>/dev/null; then
    rm -f "$signed_entitlements"
    local_fail "$context app is missing or does not have a valid distribution signature."
    return
  fi
  local actual_bundle actual_source actual_version actual_build aps icloud_environment
  local get_task_allow time_sensitive kvstore authority embedded_profile decoded_profile
  local application_identifier team_identifier
  actual_bundle="$(plist_value "$info" CFBundleIdentifier || true)"
  actual_source="$(plist_value "$info" NativeAgentMobileSourceKey || true)"
  actual_version="$(plist_value "$info" CFBundleShortVersionString || true)"
  actual_build="$(plist_value "$info" CFBundleVersion || true)"
  local actual_privacy_url actual_support_url
  actual_privacy_url="$(plist_value "$info" NativeAgentPrivacyPolicyURL || true)"
  actual_support_url="$(plist_value "$info" NativeAgentSupportURL || true)"
  aps="$(plist_value "$signed_entitlements" aps-environment || true)"
  icloud_environment="$(
    plist_value "$signed_entitlements" com.apple.developer.icloud-container-environment || true
  )"
  get_task_allow="$(plist_value "$signed_entitlements" get-task-allow || true)"
  application_identifier="$(plist_value "$signed_entitlements" application-identifier || true)"
  team_identifier="$(
    plist_value "$signed_entitlements" com.apple.developer.team-identifier || true
  )"
  time_sensitive="$(
    plist_value "$signed_entitlements" com.apple.developer.usernotifications.time-sensitive || true
  )"
  kvstore="$(
    plist_value "$signed_entitlements" com.apple.developer.ubiquity-kvstore-identifier || true
  )"
  authority="$(codesign -dvv "$app" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
  [[ "$actual_bundle" == "$BUNDLE_ID" ]] ||
    local_fail "$context bundle ID changed from $BUNDLE_ID to $actual_bundle."
  [[ "$actual_source" == "mobile_app" ]] ||
    local_fail "$context does not contain the neutral mobile source key."
  [[ "$actual_version" == "$MARKETING_VERSION" && "$actual_build" == "$BUILD_NUMBER" ]] ||
    local_fail "$context version/build changed from $MARKETING_VERSION ($BUILD_NUMBER) to $actual_version ($actual_build)."
  [[ "$actual_privacy_url" == "$PRIVACY_POLICY_URL" && "$actual_privacy_url" == https://* ]] ||
    local_fail "$context privacy-policy URL is missing or changed."
  [[ "$actual_support_url" == "$SUPPORT_URL" && "$actual_support_url" == https://* ]] ||
    local_fail "$context support URL is missing or changed."
  [[ "$application_identifier" == "$TEAM_ID.$BUNDLE_ID" ]] ||
    local_fail "$context application identifier does not match the release team and bundle."
  [[ "$team_identifier" == "$TEAM_ID" ]] ||
    local_fail "$context signed team identifier changed from $TEAM_ID."
  [[ "$icloud_environment" == "Production" ]] ||
    local_fail "$context signed CloudKit container environment is not Production."
  [[ "$time_sensitive" == "true" ]] ||
    local_fail "$context is missing the time-sensitive notification entitlement."
  [[ "$kvstore" == "$TEAM_ID."* ]] ||
    local_fail "$context has a missing or mismatched iCloud KVS entitlement."
  plist_array_contains "$signed_entitlements" \
    com.apple.developer.icloud-services CloudKit ||
    local_fail "$context signed entitlements do not contain CloudKit."
  plist_array_contains "$signed_entitlements" \
    com.apple.developer.icloud-services CloudDocuments ||
    local_fail "$context signed entitlements do not contain CloudDocuments."
  plist_array_contains "$signed_entitlements" \
    com.apple.developer.icloud-container-identifiers "$CONTAINER_ID" ||
    local_fail "$context signed entitlements do not contain $CONTAINER_ID."
  plist_array_contains "$signed_entitlements" \
    com.apple.developer.ubiquity-container-identifiers "$CONTAINER_ID" ||
    local_fail "$context signed ubiquity entitlements do not contain $CONTAINER_ID."
  embedded_profile="$app/embedded.mobileprovision"
  decoded_profile="$(mktemp)"
  if [[ ! -f "$embedded_profile" ]] ||
     ! decode_profile "$embedded_profile" >"$decoded_profile"; then
    local_fail "$context embedded provisioning profile is missing or unreadable."
  elif [[ "$require_distribution" == "1" ]]; then
    [[ "$aps" == "production" ]] ||
      local_fail "$context signed APNS entitlement is not production."
    [[ "$get_task_allow" == "false" ]] ||
      local_fail "$context still has get-task-allow; it is not App Store distribution signed."
    [[ "$authority" == Apple\ Distribution:* ]] ||
      local_fail "$context signer is '$authority', not Apple Distribution."
    profile_matches "$embedded_profile" "$decoded_profile" ||
      local_fail "$context embedded profile is not a current matching App Store profile."
  else
    [[ "$aps" == "development" || "$aps" == "production" ]] ||
      local_fail "$context archive is missing an APNS signing environment."
    [[ "$get_task_allow" == "true" || "$get_task_allow" == "false" ]] ||
      local_fail "$context archive has an invalid get-task-allow entitlement."
    [[ "$authority" == Apple\ Development:* || "$authority" == Apple\ Distribution:* ]] ||
      local_fail "$context archive signer '$authority' is not an Apple team identity."
    [[ "$(plist_value "$decoded_profile" TeamIdentifier:0 || true)" == "$TEAM_ID" ]] ||
      local_fail "$context archive profile does not belong to team $TEAM_ID."
    [[ "$(plist_value "$decoded_profile" Entitlements:application-identifier || true)" == "$TEAM_ID.$BUNDLE_ID" ]] ||
      local_fail "$context archive profile does not match $BUNDLE_ID."
  fi
  rm -f "$decoded_profile"
  [[ -f "$app/PrivacyInfo.xcprivacy" ]] ||
    local_fail "$context app is missing its bundled privacy manifest."
  rm -f "$signed_entitlements"
}

create_archive() {
  mkdir -p "$OUTPUT_DIR"
  [[ -n "$ARCHIVE_PATH" ]] ||
    ARCHIVE_PATH="$OUTPUT_DIR/NativeAgentMobile-${MARKETING_VERSION}-${BUILD_NUMBER}.xcarchive"
  rm -rf "$ARCHIVE_PATH"
  printf '[ARCHIVE] %s\n' "$ARCHIVE_PATH"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    NATIVEAGENT_MOBILE_SOURCE_KEY=mobile_app || {
      local_fail "Xcode archive failed. No upload was attempted."
      return
    }
  local app="$ARCHIVE_PATH/Products/Applications/NativeAgentMobile.app"
  validate_signed_app "$app" "Archived" 0
  [[ "$LOCAL_FAILURES" == "0" ]] &&
    pass "signed release archive validated for App Store export"
}

export_archive() {
  if [[ -z "$ARCHIVE_PATH" || ! -d "$ARCHIVE_PATH" ]]; then
    local_fail "--export requires --archive or --archive-path pointing to an existing archive."
    return
  fi
  EXPORT_PATH="$OUTPUT_DIR/export"
  rm -rf "$EXPORT_PATH"
  mkdir -p "$EXPORT_PATH"
  local options
  options="$(mktemp -t NativeAgentExportOptions).plist"
  sed "s/__NATIVEAGENT_TEAM_ID__/$TEAM_ID/g" "$EXPORT_TEMPLATE" >"$options"
  if ! plutil -lint "$options" >/dev/null 2>&1 ||
     [[ "$(plist_value "$options" teamID || true)" != "$TEAM_ID" ]]; then
    rm -f "$options"
    local_fail "Could not create the identity-injected temporary export options."
    return
  fi
  printf '[EXPORT] %s\n' "$EXPORT_PATH"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$options" || {
      rm -f "$options"
      local_fail "Local IPA export failed. No upload was attempted."
      return
    }
  rm -f "$options"
  local ipa
  ipa="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
  if [[ -z "$ipa" ]]; then
    local_fail "Export completed without producing an IPA."
    return
  fi
  local unpacked exported_app
  unpacked="$(mktemp -d)"
  if ! ditto -x -k "$ipa" "$unpacked"; then
    rm -rf "$unpacked"
    local_fail "Exported IPA could not be unpacked for verification."
    return
  fi
  exported_app="$(find "$unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
  if [[ -z "$exported_app" ]]; then
    rm -rf "$unpacked"
    local_fail "Exported IPA does not contain an application bundle."
    return
  fi
  validate_signed_app "$exported_app" "Exported" 1
  rm -rf "$unpacked"
  [[ "$LOCAL_FAILURES" == "0" ]] || return
  pass "IPA exported locally at $ipa; nothing was uploaded"
}

main() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --preflight) DO_PREFLIGHT=1 ;;
      --archive) DO_ARCHIVE=1 ;;
      --export) DO_EXPORT=1 ;;
      --output)
        shift
        [[ "$#" -gt 0 ]] || { usage >&2; exit 64; }
        OUTPUT_DIR="$1"
        ;;
      --archive-path)
        shift
        [[ "$#" -gt 0 ]] || { usage >&2; exit 64; }
        ARCHIVE_PATH="$1"
        ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
  done

  if [[ "$DO_PREFLIGHT" == "0" && "$DO_ARCHIVE" == "0" && "$DO_EXPORT" == "0" ]]; then
    DO_PREFLIGHT=1
  fi
  run_preflight
  if [[ "$LOCAL_FAILURES" -gt 0 ]]; then
    printf '\nREFUSED: %d local/source blocker(s)' "$LOCAL_FAILURES" >&2
    if [[ "$ACCOUNT_FAILURES" -gt 0 ]]; then
      printf ' and %d Apple account blocker(s)' "$ACCOUNT_FAILURES" >&2
    fi
    printf '.\n' >&2
    exit 2
  fi
  if [[ "$ACCOUNT_FAILURES" -gt 0 ]]; then
    printf '\nREFUSED: local/source checks passed; %d Apple account blocker(s) remain.\n' \
      "$ACCOUNT_FAILURES" >&2
    exit 3
  fi
  if [[ "$DO_ARCHIVE" == "1" ]]; then
    create_archive
  fi
  if [[ "$LOCAL_FAILURES" == "0" && "$DO_EXPORT" == "1" &&
        "$DO_ARCHIVE" == "0" ]]; then
    if [[ -z "$ARCHIVE_PATH" || ! -d "$ARCHIVE_PATH" ]]; then
      local_fail "--export requires --archive or --archive-path pointing to an existing archive."
    else
      validate_signed_app \
        "$ARCHIVE_PATH/Products/Applications/NativeAgentMobile.app" "Archived" 0
    fi
  fi
  if [[ "$LOCAL_FAILURES" == "0" && "$DO_EXPORT" == "1" ]]; then
    export_archive
  fi
  if [[ "$LOCAL_FAILURES" -gt 0 ]]; then
    printf '\nREFUSED: artifact creation failed; nothing was uploaded.\n' >&2
    exit 2
  fi
  printf '\nREADY: local checks and Apple signing material are valid'
  [[ "$DO_EXPORT" == "1" ]] && printf '; IPA exported without upload'
  printf '.\n'
}

if [[ "${NATIVEAGENT_IOS_RELEASE_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
