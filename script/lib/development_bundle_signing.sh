#!/usr/bin/env bash

# Shared development-bundle signing contract used by both the dist builder and
# the installer. Callers must source provisioning_profile_contract.sh first.
#
# The two paths intentionally share one decision tree: discover a usable local
# identity, reject a stale explicit override when another real identity exists,
# use profile-derived entitlements when the complete development chain exists,
# and fall back to ad-hoc only for missing prerequisites or explicit opt-in.

nativeagent_resolve_development_signing_identity() {
  local log_prefix="$1"
  local discovered_identity env_identity

  discovered_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')"
  if [[ -z "$discovered_identity" ]]; then
    discovered_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
  fi

  env_identity="${NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY:-${NATIVE_AGENT_DEVELOPER_ID:-}}"
  if [[ -z "$env_identity" ]]; then
    printf '%s\n' "$discovered_identity"
    return 0
  fi
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$env_identity"; then
    printf '%s\n' "$env_identity"
    return 0
  fi
  if [[ -z "$discovered_identity" ]]; then
    # Preserve the missing-cert path: the membership gate in the owner below
    # will select ad-hoc because this stale value is not in the keychain.
    printf '%s\n' "$env_identity"
    return 0
  fi

  echo "$log_prefix NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY/NATIVE_AGENT_DEVELOPER_ID='$env_identity'" >&2
  echo "$log_prefix is NOT present in the keychain, but a real signing identity IS:" >&2
  echo "$log_prefix   '$discovered_identity'" >&2
  echo "$log_prefix Refusing to silently ad-hoc-sign an iCloud app (macOS would kill it)." >&2
  echo "$log_prefix Fix or unset the env var (the discovered identity will be used)," >&2
  echo "$log_prefix or set NATIVE_AGENT_ADHOC=1 to explicitly opt into ad-hoc." >&2
  return 1
}

_nativeagent_sign_nested_plain() {
  local bundle="$1" identity="$2"
  if [[ -d "$bundle/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --sign "$identity" --options runtime --timestamp=none \
      "$bundle/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
  fi
}

_nativeagent_strip_unprovisioned_entitlements() {
  local source_entitlements="$1" output="$2"
  # The current personal development profile does not grant this future-facing
  # capability. Signing it anyway causes AMFI to reject the bundle at launch.
  /usr/bin/perl -0pe 's/\s*<key>com\.apple\.developer\.background-tasks<\/key>\s*<array>.*?<\/array>//s' \
    "$source_entitlements" > "$output"
}

_nativeagent_assert_profile_allows_current_mac() {
  local profile="$1" bundle_id="$2" root="$3" log_prefix="$4"
  local ids devices_xml id matched

  ids="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Hardware UUID|Provisioning UDID/ {print $2}')"
  [[ -z "$ids" ]] && return 0
  if ! devices_xml="$(/usr/bin/security cms -D -i "$profile" | /usr/bin/plutil -extract ProvisionedDevices xml1 -o - - 2>/dev/null)"; then
    return 0
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
  echo "$log_prefix   profile: $profile" >&2
  echo "$log_prefix this Mac IDs:" >&2
  while IFS= read -r id; do
    [[ -n "$id" ]] && echo "$log_prefix   - $id" >&2
  done <<<"$ids"
  echo "$log_prefix profile allowed devices:" >&2
  printf '%s\n' "$devices_xml" | awk -F'[<>]' -v prefix="$log_prefix" '/<string>/ {print prefix "   - " $3}' >&2
  echo "$log_prefix Regenerate/download the Mac Development profile for $bundle_id with this Mac selected," >&2
  echo "$log_prefix replace $root/local/NativeAgent.provisionprofile, then rerun ./script/install_app.sh." >&2
  echo "$log_prefix Temporary local-only launch: NATIVE_AGENT_ADHOC=1 ./script/install_app.sh (iCloud disabled)." >&2
  return 1
}

# Returns 11 only for the final dev-cert codesign failure, the one failure that
# may honor NATIVE_AGENT_ADHOC_FALLBACK=1. Every profile/identity integrity
# failure returns 10 and remains fatal even when fallback was requested.
_nativeagent_sign_with_development_identity() {
  local bundle="$1" identity="$2" profile="$3" source_entitlements="$4"
  local bundle_id="$5" log_prefix="$6"
  local entitlement_template entitlement_sign profile_plist

  if ! cp "$profile" "$bundle/Contents/embedded.provisionprofile"; then
    echo "$log_prefix FATAL: failed to copy provisioning profile into the bundle:" >&2
    echo "$log_prefix   $profile -> $bundle/Contents/embedded.provisionprofile" >&2
    echo "$log_prefix Cannot honor iCloud entitlements without it. Aborting." >&2
    return 10
  fi
  chmod 0644 "$bundle/Contents/embedded.provisionprofile" || return 10
  _nativeagent_sign_nested_plain "$bundle" "$identity"

  entitlement_template="${TMPDIR:-/tmp}/na_ent_template.$$.entitlements"
  entitlement_sign="${TMPDIR:-/tmp}/na_ent_sign.$$.entitlements"
  profile_plist="${TMPDIR:-/tmp}/na_profile.$$.plist"
  if ! _nativeagent_strip_unprovisioned_entitlements "$source_entitlements" "$entitlement_template" \
    || ! decode_provisioning_profile "$profile" "$profile_plist" \
    || ! verify_profile_identity_contract "$profile_plist" "$bundle_id" \
    || ! prepare_profile_signing_entitlements "$entitlement_template" "$profile_plist" "$entitlement_sign"; then
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
  _nativeagent_sign_nested_plain "$bundle" "-"
  if [[ -f "$adhoc_entitlements" ]]; then
    codesign --force --sign - --entitlements "$adhoc_entitlements" "$bundle"
  else
    codesign --force --sign - "$bundle"
  fi
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

nativeagent_sign_development_bundle() {
  local bundle="$1" root="$2" bundle_id="$3" log_prefix="$4"
  local profile source_entitlements adhoc_entitlements sign_identity sign_status

  profile="${NATIVEAGENT_PROVISIONING_PROFILE:-$root/local/NativeAgent.provisionprofile}"
  source_entitlements="${NATIVEAGENT_ENTITLEMENTS:-$root/local/NativeAgent.entitlements}"
  adhoc_entitlements="$root/NativeAgent.adhoc.entitlements"
  sign_identity="$(nativeagent_resolve_development_signing_identity "$log_prefix")" || return 1

  if [[ "${NATIVE_AGENT_ADHOC:-0}" == "1" ]]; then
    echo "$log_prefix NATIVE_AGENT_ADHOC=1 — using ad-hoc signature (iCloud disabled)"
    _nativeagent_sign_adhoc_bundle "$bundle" "$adhoc_entitlements" || return 1
  elif [[ -f "$profile" && -f "$source_entitlements" ]] \
    && [[ -n "$sign_identity" ]] \
    && security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$sign_identity"; then
    echo "$log_prefix Apple Development cert + provisioning profile + iCloud entitlements"
    _nativeagent_assert_profile_allows_current_mac "$profile" "$bundle_id" "$root" "$log_prefix" || return 1
    if _nativeagent_sign_with_development_identity \
      "$bundle" "$sign_identity" "$profile" "$source_entitlements" "$bundle_id" "$log_prefix"; then
      :
    else
      sign_status=$?
      if [[ "$sign_status" != "11" ]]; then
        return 1
      fi
      echo "$log_prefix dev-cert signing FAILED (see codesign error above)." >&2
      if [[ "${NATIVE_AGENT_ADHOC_FALLBACK:-0}" == "1" ]]; then
        echo "$log_prefix NATIVE_AGENT_ADHOC_FALLBACK=1 — falling back to ad-hoc" >&2
        echo "$log_prefix iCloud entitlements will NOT be honored and macOS may kill the app." >&2
        _nativeagent_sign_adhoc_bundle "$bundle" "$adhoc_entitlements" || return 1
      else
        echo "$log_prefix cert+profile are present, so this is NOT a missing-identity case —" >&2
        echo "$log_prefix refusing to silently ship an unlaunchable ad-hoc iCloud app." >&2
        echo "$log_prefix Fix the codesign cause and re-run, or set NATIVE_AGENT_ADHOC_FALLBACK=1" >&2
        echo "$log_prefix (or NATIVE_AGENT_ADHOC=1) to explicitly opt into ad-hoc." >&2
        return 1
      fi
    fi
  else
    echo "$log_prefix no local provisioning profile / cert — ad-hoc (iCloud disabled)"
    _nativeagent_sign_adhoc_bundle "$bundle" "$adhoc_entitlements" || return 1
  fi

  _nativeagent_verify_signed_bundle "$bundle" "$log_prefix"
}
