#!/usr/bin/env bash

# Shared release boundary for Developer ID CloudKit provisioning profiles.
# A valid signature and a notarization ticket do not prove that the embedded
# profile grants the app/container named by the signed bundle. macOS AMFI checks
# that relationship at launch, so both release preflight and artifact
# verification must enforce it explicitly.

provisioning_profile_value() {
  local plist="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

provisioning_profile_array_contains() {
  local plist="$1" key="$2" expected="$3"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -Fqx "$expected"
}

decode_provisioning_profile() {
  local profile="$1" output="$2"
  [[ -f "$profile" && ! -L "$profile" ]] || {
    echo "provisioning profile is not a regular file: $profile" >&2
    return 1
  }
  security cms -D -i "$profile" > "$output" 2>/dev/null || {
    echo "unable to decode provisioning profile: $profile" >&2
    return 1
  }
  plutil -lint "$output" >/dev/null || {
    echo "decoded provisioning profile is not a valid plist: $profile" >&2
    return 1
  }
}

verify_profile_identity_contract() {
  local plist="$1" expected_bundle="$2"
  local profile_app_id profile_team entitlement_team expected_app_id

  profile_app_id="$(
    provisioning_profile_value "$plist" \
      "Entitlements:com.apple.application-identifier"
  )"
  profile_team="$(provisioning_profile_value "$plist" "TeamIdentifier:0")"
  entitlement_team="$(
    provisioning_profile_value "$plist" \
      "Entitlements:com.apple.developer.team-identifier"
  )"
  expected_app_id="$profile_team.$expected_bundle"

  [[ -n "$profile_team" && "$entitlement_team" == "$profile_team" ]] || {
    echo "profile application team '$entitlement_team' does not match profile team '$profile_team'" >&2
    return 1
  }
  [[ "$profile_app_id" == "$expected_app_id" ]] || {
    echo "profile application identifier '$profile_app_id' does not match '$expected_app_id'" >&2
    return 1
  }
}

verify_public_cloudkit_profile_contract() {
  local plist="$1" expected_team="$2" expected_bundle="$3" expected_container="$4"
  local expected_app_id profile_app_id profile_team aps_environment
  local container_environment provisions_all_devices

  expected_app_id="$expected_team.$expected_bundle"
  profile_app_id="$(
    provisioning_profile_value "$plist" \
      "Entitlements:com.apple.application-identifier"
  )"
  profile_team="$(provisioning_profile_value "$plist" "TeamIdentifier:0")"
  aps_environment="$(
    provisioning_profile_value "$plist" \
      "Entitlements:com.apple.developer.aps-environment"
  )"
  container_environment="$(
    provisioning_profile_value "$plist" \
      "Entitlements:com.apple.developer.icloud-container-environment"
  )"
  provisions_all_devices="$(
    provisioning_profile_value "$plist" "ProvisionsAllDevices"
  )"

  [[ "$profile_team" == "$expected_team" ]] || {
    echo "profile team '$profile_team' does not match '$expected_team'" >&2
    return 1
  }
  verify_profile_identity_contract "$plist" "$expected_bundle" || return 1
  [[ "$profile_app_id" == "$expected_app_id" ]] || {
    echo "profile application identifier '$profile_app_id' does not match '$expected_app_id'" >&2
    return 1
  }
  provisioning_profile_array_contains \
    "$plist" \
    "Entitlements:com.apple.developer.icloud-container-identifiers" \
    "$expected_container" || {
      echo "profile does not grant CloudKit container '$expected_container'" >&2
      return 1
    }
  {
    provisioning_profile_array_contains \
      "$plist" \
      "Entitlements:com.apple.developer.icloud-services" \
      "CloudKit" \
      || provisioning_profile_array_contains \
        "$plist" \
        "Entitlements:com.apple.developer.icloud-services" \
        "*"
  } || {
    echo "profile does not grant the CloudKit service" >&2
    return 1
  }
  [[ "$aps_environment" == "production" ]] || {
    echo "profile APNS environment '$aps_environment' is not production" >&2
    return 1
  }
  [[ "$container_environment" == "Production" ]] || {
    echo "profile CloudKit environment '$container_environment' is not Production" >&2
    return 1
  }
  [[ "$provisions_all_devices" == "true" ]] || {
    echo "profile is not a Developer ID all-devices distribution profile" >&2
    return 1
  }
  if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$plist" >/dev/null 2>&1; then
    echo "profile is device-bound and cannot ship in a public Mac release" >&2
    return 1
  fi
}

# Derive the two signing-identity entitlements from a provisioning profile.
# A checked-in template should remain team-neutral, and codesign does not copy
# these grants from the embedded profile into an explicit entitlement payload.
prepare_profile_signing_entitlements() {
  local template="$1" profile_plist="$2" output="$3"
  local application_identifier team_identifier

  [[ -f "$template" && ! -L "$template" ]] || {
    echo "entitlement template is not a regular file: $template" >&2
    return 1
  }
  application_identifier="$(
    provisioning_profile_value \
      "$profile_plist" \
      "Entitlements:com.apple.application-identifier"
  )"
  team_identifier="$(
    provisioning_profile_value \
      "$profile_plist" \
      "Entitlements:com.apple.developer.team-identifier"
  )"
  [[ -n "$application_identifier" && -n "$team_identifier" ]] || {
    echo "profile is missing its application/team identifier grants" >&2
    return 1
  }

  cp "$template" "$output" || return 1
  chmod 0600 "$output"
  /usr/libexec/PlistBuddy \
    -c "Delete :com.apple.application-identifier" \
    "$output" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Delete :com.apple.developer.team-identifier" \
    "$output" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $application_identifier" \
    "$output" || return 1
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.developer.team-identifier string $team_identifier" \
    "$output" || return 1
  plutil -lint "$output" >/dev/null
}

verify_signed_bundle_profile_identity() {
  local bundle="$1" profile_plist="$2" expected_bundle="$3"
  local signed_entitlements expected_app_id expected_team signed_app_id signed_team

  verify_profile_identity_contract "$profile_plist" "$expected_bundle" || return 1
  expected_app_id="$(
    provisioning_profile_value \
      "$profile_plist" \
      "Entitlements:com.apple.application-identifier"
  )"
  expected_team="$(
    provisioning_profile_value \
      "$profile_plist" \
      "Entitlements:com.apple.developer.team-identifier"
  )"
  signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/nativeagent-signed-entitlements.XXXXXX.plist")"
  if ! codesign -d --entitlements :- "$bundle" >"$signed_entitlements" 2>/dev/null; then
    rm -f "$signed_entitlements"
    echo "could not read signed entitlements from $bundle" >&2
    return 1
  fi
  signed_app_id="$(
    provisioning_profile_value \
      "$signed_entitlements" \
      "com.apple.application-identifier"
  )"
  signed_team="$(
    provisioning_profile_value \
      "$signed_entitlements" \
      "com.apple.developer.team-identifier"
  )"
  rm -f "$signed_entitlements"

  [[ "$signed_app_id" == "$expected_app_id" ]] || {
    echo "signed application identifier '$signed_app_id' does not match profile '$expected_app_id'" >&2
    return 1
  }
  [[ "$signed_team" == "$expected_team" ]] || {
    echo "signed team identifier '$signed_team' does not match profile '$expected_team'" >&2
    return 1
  }
}

# A Developer ID provisioning profile grants the application/team identifiers,
# but codesign does not copy those grants into an explicit entitlement plist.
# CloudKit requires both identifiers in the app's signed entitlement payload;
# omitting them produces CKError 8 ("Trying to initialize a container without
# an application ID") even though the embedded profile, container grant,
# signature, and notarization are otherwise valid.
#
# Keep the checked-in template team-neutral. Derive only these two identity
# values from the already-validated profile into a temporary signing plist.
prepare_public_cloudkit_signing_entitlements() {
  prepare_profile_signing_entitlements "$1" "$2" "$3"
}
