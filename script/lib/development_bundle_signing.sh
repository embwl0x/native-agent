#!/usr/bin/env bash

# Development-bundle signing contract used by the dist builder.
# Callers must source provisioning_profile_contract.sh first.
#
# Select one signing mode and product before compilation; missing prerequisites
# and failed signatures stop that mode. No identity or capability substitution.

nativeagent_resolve_development_signing_identity() {
  local log_prefix="$1" signing_identities="$2"
  local discovered_identity env_identity
  discovered_identity="$(awk -F '"' '/Apple Development/ {print $2}' <<<"$signing_identities")"
  env_identity="${NATIVEAGENT_DEVELOPMENT_SIGN_IDENTITY:-}"
  if [[ -z "$env_identity" ]]; then
    if [[ -z "$discovered_identity" || "$discovered_identity" == *$'\n'* ]]; then
      echo "$log_prefix Select one NATIVEAGENT_DEVELOPMENT_SIGN_IDENTITY (Apple Development certificate required)." >&2
      return 1
    fi
    printf '%s\n' "$discovered_identity"
    return 0
  fi
  if awk -F '"' -v identity="$env_identity" '$2 == identity && /Apple Development/ {found=1} END {exit !found}' <<<"$signing_identities"; then
    printf '%s\n' "$env_identity"
    return 0
  fi
  echo "$log_prefix NATIVEAGENT_DEVELOPMENT_SIGN_IDENTITY is not an available Apple Development identity. Fix the selected certificate." >&2
  return 1
}

nativeagent_prepare_development_signing() {
  local root="$1" bundle_id="$2" log_prefix="$3" identities profile widget_profile group
  NATIVEAGENT_SIGNING_MODE="${NATIVEAGENT_SIGNING_MODE:-development}"
  NATIVEAGENT_PRODUCT="${NATIVEAGENT_PRODUCT:-host}"
  case "$NATIVEAGENT_PRODUCT" in host|host-with-widget) ;; *) echo "$log_prefix NATIVEAGENT_PRODUCT must be host or host-with-widget" >&2; return 1 ;; esac
  case "$NATIVEAGENT_SIGNING_MODE" in
    adhoc)
      [[ -r "$root/NativeAgent.adhoc.entitlements" ]] || { echo "$log_prefix Missing ad-hoc entitlements" >&2; return 1; }
      plutil -lint "$root/NativeAgent.adhoc.entitlements" >/dev/null || return 1
      NATIVEAGENT_SELECTED_SIGN_IDENTITY=-
      ;;
    development)
      identities="$(security find-identity -v -p codesigning)" || return 1
      NATIVEAGENT_SELECTED_SIGN_IDENTITY="$(nativeagent_resolve_development_signing_identity "$log_prefix" "$identities")" || return 1
      ;;
    *) echo "$log_prefix NATIVEAGENT_SIGNING_MODE must be development or adhoc" >&2; return 1 ;;
  esac
  mkdir -p "$root/.runtime" || return 1
  NATIVEAGENT_SIGNING_WORK="$(mktemp -d "$root/.runtime/signing.XXXXXX")" || return 1
  [[ "$NATIVEAGENT_SIGNING_MODE" == development ]] || return 0
  profile="${NATIVEAGENT_PROVISIONING_PROFILE:-$root/local/NativeAgent.provisionprofile}"
  local source_entitlements="${NATIVEAGENT_ENTITLEMENTS:-$root/local/NativeAgent.entitlements}"
  [[ -r "$source_entitlements" ]] || {
    echo "$log_prefix Missing development entitlements; configure NATIVEAGENT_ENTITLEMENTS." >&2; return 1;
  }
  cp "$source_entitlements" "$NATIVEAGENT_SIGNING_WORK/host-source.entitlements" || return 1
  plutil -lint "$NATIVEAGENT_SIGNING_WORK/host-source.entitlements" >/dev/null || return 1
  decode_provisioning_profile "$profile" "$NATIVEAGENT_SIGNING_WORK/host.plist" "$NATIVEAGENT_SIGNING_WORK/host.plist.provisionprofile" || return 1
  verify_profile_identity_contract "$NATIVEAGENT_SIGNING_WORK/host.plist" "$bundle_id" || return 1
  _nativeagent_assert_profile_allows_current_mac "$NATIVEAGENT_SIGNING_WORK/host.plist" "$bundle_id" "$root" "$log_prefix" || return 1
  if [[ "$NATIVEAGENT_PRODUCT" == host-with-widget ]]; then
    widget_profile="${NATIVEAGENT_WIDGET_PROVISIONING_PROFILE:-$root/local/NativeAgentWidget.provisionprofile}"
    group="${NATIVEAGENT_MAC_APP_GROUP_ID:-group.$bundle_id}"
    decode_provisioning_profile "$widget_profile" "$NATIVEAGENT_SIGNING_WORK/widget.plist" "$NATIVEAGENT_SIGNING_WORK/widget.plist.provisionprofile" || return 1
    verify_profile_identity_contract "$NATIVEAGENT_SIGNING_WORK/widget.plist" "${NATIVEAGENT_MAC_WIDGET_BUNDLE_ID:-$bundle_id.widget}" || return 1
    [[ "$(provisioning_profile_value "$NATIVEAGENT_SIGNING_WORK/host.plist" TeamIdentifier:0)" == "$(provisioning_profile_value "$NATIVEAGENT_SIGNING_WORK/widget.plist" TeamIdentifier:0)" ]] || return 1
    _nativeagent_assert_profile_allows_current_mac "$NATIVEAGENT_SIGNING_WORK/widget.plist" "$bundle_id.widget" "$root" "$log_prefix" || return 1
    for profile in host widget; do
      provisioning_profile_array_contains "$NATIVEAGENT_SIGNING_WORK/$profile.plist" 'Entitlements:com.apple.security.application-groups' "$group" || {
        echo "$log_prefix Selected widget product requires App Group $group in both profiles." >&2; return 1;
      }
    done
  fi
}

_nativeagent_sign_nested_plain() {
  local bundle="$1" identity="$2"
  local signing_root
  signing_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
  if [[ ! -d "$bundle/Contents/Helpers/NativeAgentFace.app" ]]; then
    echo '[sign] Missing NativeAgentFace renderer' >&2
    return 1
  fi
  local face_sparkle="$bundle/Contents/Helpers/NativeAgentFace.app/Contents/Frameworks/Sparkle.framework"
  if [[ ! -d "$face_sparkle" ]]; then
    echo '[sign] Missing NativeAgentFace Sparkle framework' >&2
    return 1
  fi
  codesign --force --deep --sign "$identity" --options runtime --timestamp=none "$face_sparkle" || return 1
  codesign --force --sign "$identity" --options runtime --timestamp=none \
    "$bundle/Contents/Helpers/NativeAgentFace.app" || return 1
  if [[ ! -f "$bundle/Contents/MacOS/NativeAgentSenseHost" ]]; then
    echo '[sign] Missing NativeAgentSenseHost helper' >&2
    return 1
  fi
  codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements "$signing_root/Config/NativeAgentSenseHost.entitlements" \
    "$bundle/Contents/MacOS/NativeAgentSenseHost" || return 1
  if [[ -f "$bundle/Contents/MacOS/nativeagent-link" ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp=none \
      "$bundle/Contents/MacOS/nativeagent-link" || return 1
  fi
  if [[ -f "$bundle/Contents/MacOS/NativeAgentChromeRelay" ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp=none \
      "$bundle/Contents/MacOS/NativeAgentChromeRelay" || return 1
  fi
  if [[ -d "$bundle/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --sign "$identity" --options runtime --timestamp=none \
      "$bundle/Contents/Frameworks/Sparkle.framework" || return 1
  fi
}

# Apply the selected product, never infer it from provisioning failures.
_nativeagent_gate_widget() {
  local bundle="$1"
  if [[ "$NATIVEAGENT_PRODUCT" == host ]]; then
    rm -rf "$bundle/Contents/PlugIns/NativeAgentWidget.appex" || return 1
    /usr/libexec/PlistBuddy -c 'Delete :NativeAgentMacAppGroupID' "$bundle/Contents/Info.plist" || return 1
    echo '[sign] selected host product (no widget)'
  elif [[ ! -d "$bundle/Contents/PlugIns/NativeAgentWidget.appex" ]]; then
    echo '[sign] Missing embedded NativeAgentWidget.appex in provisioned build' >&2
    return 1
  fi
}

# Only an embedded widget (or the extension itself) needs the shared group.
_nativeagent_set_widget_group() {
  local bundle="$1" entitlements="$2" profile_plist="${3:-}" group groups
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$entitlements" >/dev/null 2>&1 || true
  if [[ "$bundle" != *.appex && ! -d "$bundle/Contents/PlugIns/NativeAgentWidget.appex" ]]; then
    return 0
  fi
  group="$(/usr/libexec/PlistBuddy -c 'Print :NativeAgentMacAppGroupID' "$bundle/Contents/Info.plist")" || return 1
  [[ -n "$group" && "$group" != *'$('* ]] || return 1
  if [[ -n "$profile_plist" ]]; then
    groups="$(provisioning_profile_value "$profile_plist" 'Entitlements:com.apple.security.application-groups')"
    if ! printf '%s\n' "$groups" | awk -v group="$group" '$1 == group { found=1 } END { exit !found }'; then
      echo "[sign] Profile does not grant App Group $group. Enable it for the Mac app and widget and refresh both profiles." >&2
      return 1
    fi
  fi
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' \
    -c "Add :com.apple.security.application-groups:0 string $group" "$entitlements"
}

_nativeagent_sign_widget() {
  local bundle="$1" identity="$2" root="$3" profile_plist="${4:-}" widget entitlements widget_id
  widget="$bundle/Contents/PlugIns/NativeAgentWidget.appex"
  [[ -d "$widget" ]] || return 0
  entitlements="$bundle/../widget-sign.$$.entitlements"
  cp "$root/Config/NativeAgentWidget.entitlements" "$entitlements" || return 1
  if ! _nativeagent_set_widget_group "$widget" "$entitlements"; then
    rm -f "$entitlements"
    return 1
  fi
  if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --options runtime --entitlements "$entitlements" "$widget"
  else
    widget_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Contents/Info.plist")"
    _nativeagent_sign_with_development_identity "$widget" "$identity" "$entitlements" "$widget_id" '[sign widget]' "$profile_plist"
  fi
  local result=$?
  rm -f "$entitlements"
  return "$result"
}

_nativeagent_strip_unprovisioned_entitlements() {
  local source_entitlements="$1" output="$2"
  # The current personal development profile does not grant this future-facing
  # capability. Signing it anyway causes AMFI to reject the bundle at launch.
  /usr/bin/perl -0pe 's/\s*<key>com\.apple\.developer\.background-tasks<\/key>\s*<array>.*?<\/array>//s' \
    "$source_entitlements" > "$output"
}

# Push (CloudKit phone→Mac notifications) needs aps-environment in the signed
# payload; codesign does not copy it from the embedded profile. Sign whatever
# environment the profile grants, and nothing when it grants none.
_nativeagent_add_profile_push_environment() {
  local profile_plist="$1" entitlements="$2" aps_environment

  aps_environment="$(
    provisioning_profile_value "$profile_plist" \
      "Entitlements:com.apple.developer.aps-environment"
  )"
  [[ -z "$aps_environment" ]] && return 0
  /usr/libexec/PlistBuddy \
    -c "Delete :com.apple.developer.aps-environment" \
    "$entitlements" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.developer.aps-environment string $aps_environment" \
    "$entitlements"
}

_nativeagent_assert_profile_allows_current_mac() {
  local profile_plist="$1" bundle_id="$2" root="$3" log_prefix="$4"
  local ids devices_xml id matched

  ids="$(system_profiler SPHardwareDataType | awk -F': ' '/Hardware UUID|Provisioning UDID/ {print $2}')" || return 1
  [[ -n "$ids" ]] || { echo "$log_prefix Could not establish this Mac's provisioning identity." >&2; return 1; }
  if ! devices_xml="$(/usr/bin/plutil -extract ProvisionedDevices xml1 -o - "$profile_plist" 2>/dev/null)"; then
    [[ "$(provisioning_profile_value "$profile_plist" ProvisionsAllDevices)" == true ]] && return 0
    echo "$log_prefix Profile has neither readable ProvisionedDevices nor an all-devices grant." >&2
    return 1
  fi
  matched=0
  while IFS= read -r id; do
    if [[ -n "$id" ]] && /usr/bin/grep -Fq "<string>$id</string>" <<<"$devices_xml"; then
      matched=1
      break
    fi
  done <<<"$ids"
  [[ "$matched" == "1" ]] && return 0

  echo "$log_prefix provisioning profile does not include this Mac, so macOS will refuse to launch the iCloud build." >&2
  echo "$log_prefix   profile snapshot: $profile_plist" >&2
  echo "$log_prefix this Mac IDs:" >&2
  while IFS= read -r id; do
    [[ -n "$id" ]] && echo "$log_prefix   - $id" >&2
  done <<<"$ids"
  echo "$log_prefix profile allowed devices:" >&2
  printf '%s\n' "$devices_xml" | awk -F'[<>]' -v prefix="$log_prefix" '/<string>/ {print prefix "   - " $3}' >&2
  echo "$log_prefix Regenerate/download the Mac Development profile for $bundle_id with this Mac selected," >&2
  echo "$log_prefix replace $root/local/NativeAgent.provisionprofile, then rerun ./script/install_app.sh." >&2
  return 1
}

# All signing and identity failures stop the selected mode.
_nativeagent_sign_with_development_identity() {
  local bundle="$1" identity="$2" source_entitlements="$3"
  local bundle_id="$4" log_prefix="$5"
  local entitlement_template entitlement_sign profile_plist="$6"
  [[ -r "$profile_plist" && -r "$profile_plist.provisionprofile" ]] || {
    echo "$log_prefix Preflight profile snapshot is unavailable; refusing to select new signing input." >&2; return 10;
  }
  cp "$profile_plist.provisionprofile" "$bundle/Contents/embedded.provisionprofile" || return 10

  entitlement_template="${TMPDIR:-/tmp}/na_ent_template.$$.entitlements"
  entitlement_sign="${TMPDIR:-/tmp}/na_ent_sign.$$.entitlements"
  if ! _nativeagent_strip_unprovisioned_entitlements "$source_entitlements" "$entitlement_template" \
    || ! verify_profile_identity_contract "$profile_plist" "$bundle_id" \
    || ! _nativeagent_set_widget_group "$bundle" "$entitlement_template" "$profile_plist" \
    || ! prepare_profile_signing_entitlements "$entitlement_template" "$profile_plist" "$entitlement_sign" \
    || ! _nativeagent_add_profile_push_environment "$profile_plist" "$entitlement_sign"; then
    rm -f "$entitlement_template" "$entitlement_sign" "$profile_plist"
    echo "$log_prefix FATAL: provisioning profile identity does not match the bundle." >&2
    return 10
  fi

  if ! codesign --force \
    --sign "$identity" \
    --options runtime \
    --generate-entitlement-der \
    --entitlements "$entitlement_sign" \
    --timestamp=none \
    "$bundle"; then
    rm -f "$entitlement_template" "$entitlement_sign" "$profile_plist"
    return 11
  fi
  if ! verify_signed_bundle_profile_identity "$bundle" "$profile_plist" "$bundle_id"; then
    rm -f "$entitlement_template" "$entitlement_sign" "$profile_plist"
    echo "$log_prefix FATAL: signed CloudKit identity does not match the embedded profile." >&2
    return 10
  fi
  rm -f "$entitlement_template" "$entitlement_sign" "$profile_plist"
}

_nativeagent_sign_adhoc_bundle() {
  local bundle="$1" adhoc_entitlements="$2"
  _nativeagent_sign_nested_plain "$bundle" "-" || return 1
  local expanded="$bundle/../app-sign.$$.entitlements"
  cp "$adhoc_entitlements" "$expanded" || return 1
  if ! _nativeagent_set_widget_group "$bundle" "$expanded"; then
    rm -f "$expanded"
    return 1
  fi
  codesign --force --sign - --entitlements "$expanded" "$bundle"
  local result=$?
  rm -f "$expanded"
  return "$result"
}

_nativeagent_verify_signed_bundle() {
  local bundle="$1" log_prefix="$2"
  echo "$log_prefix verifying bundle signature (--deep --strict)..."
  if ! codesign --verify --deep --strict --verbose=2 "$bundle"; then
    echo "$log_prefix codesign --verify --deep --strict FAILED for $bundle" >&2
    echo "$log_prefix a nested Mach-O (Sparkle) is unsigned or invalid." >&2
    echo "$log_prefix refusing to use an unlaunchable bundle. Fix the cause and re-run." >&2
    return 1
  fi
}

nativeagent_sign_development_bundle() (
  local bundle="$1" root="$2" bundle_id="$3" log_prefix="$4"
  local source_entitlements adhoc_entitlements sign_identity snapshot_dir profile_plist
  snapshot_dir="$NATIVEAGENT_SIGNING_WORK"
  profile_plist="$snapshot_dir/host.plist"

  source_entitlements="$snapshot_dir/host-source.entitlements"
  adhoc_entitlements="$root/NativeAgent.adhoc.entitlements"
  sign_identity="$NATIVEAGENT_SELECTED_SIGN_IDENTITY"
  _nativeagent_gate_widget "$bundle" || return 1

  if [[ "$NATIVEAGENT_SIGNING_MODE" == adhoc ]]; then
    echo "$log_prefix selected ad-hoc signature (iCloud disabled)"
    _nativeagent_sign_widget "$bundle" "-" "$root" || return 1
    _nativeagent_sign_adhoc_bundle "$bundle" "$adhoc_entitlements" || return 1
  else
    echo "$log_prefix Apple Development cert + provisioning profile + iCloud entitlements"
    _nativeagent_sign_widget "$bundle" "$sign_identity" "$root" "$snapshot_dir/widget.plist" || return 1
    _nativeagent_sign_nested_plain "$bundle" "$sign_identity" || return 1
    _nativeagent_sign_with_development_identity \
      "$bundle" "$sign_identity" "$source_entitlements" "$bundle_id" "$log_prefix" "$profile_plist" || return 1
  fi

  _nativeagent_verify_signed_bundle "$bundle" "$log_prefix"
)
