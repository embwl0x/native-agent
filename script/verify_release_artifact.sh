#!/usr/bin/env bash
# Verify a built NativeAgent DMG as a public distribution artifact.
#
# This intentionally checks the mounted DMG, not only dist/NativeAgent.app:
# Finder drag-install failures, bad permissions, stale REPO_PATH stamps, and
# copied runtime state are distribution bugs even when the staged app looked OK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/plist_types.sh
source "$ROOT/script/lib/plist_types.sh"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/release_bundle_gates.sh
source "$ROOT/script/lib/release_bundle_gates.sh"
# shellcheck source=lib/release_symbols.sh
source "$ROOT/script/lib/release_symbols.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
REQUIRE_NOTARIZED=false
REQUIRE_DMG_SIGNATURE=false
REQUIRE_SPARKLE_KEY=false
REQUIRE_CLEAN_SOURCE=false
BUNDLE_PATH=""
RESOURCE_SOURCE_ROOT=""
RESOURCE_BUNDLE_ROOT=""
DERIVED_CONTEXT_SCAN_ROOT=""
ARTIFACT_OPTION_SET=false
EXPECTED_MAC_BUNDLE_ID="${NATIVEAGENT_EXPECTED_MAC_BUNDLE_ID:-${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}}"

VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"

usage() {
  cat >&2 <<USAGE
Usage: $0 [--dmg path] [--bundle path] [--require-notarized] [--require-dmg-signature] [--require-sparkle-key] [--require-clean-source]
       $0 --verify-resource-source repo_root
       $0 --verify-resource-bundle contents_resources_dir
       $0 --verify-no-derived-context-state tree_root
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DMG_PATH="$2"
      ARTIFACT_OPTION_SET=true
      shift 2
      ;;
    --bundle)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      BUNDLE_PATH="$2"
      ARTIFACT_OPTION_SET=true
      shift 2
      ;;
    --require-notarized)
      REQUIRE_NOTARIZED=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-dmg-signature)
      REQUIRE_DMG_SIGNATURE=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-sparkle-key)
      REQUIRE_SPARKLE_KEY=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-clean-source)
      REQUIRE_CLEAN_SOURCE=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --verify-resource-source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      RESOURCE_SOURCE_ROOT="$2"
      shift 2
      ;;
    --verify-resource-bundle)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      RESOURCE_BUNDLE_ROOT="$2"
      shift 2
      ;;
    --verify-no-derived-context-state)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DERIVED_CONTEXT_SCAN_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

verify_no_derived_context_state() {
  local scan_root="$1" context="$2"
  local hit

  [[ -d "$scan_root" && ! -L "$scan_root" ]] \
    || fail "$context scan root is not a real directory: $scan_root"

  # The canonical subtree is entirely rebuildable local state. The basename
  # checks also catch SQLite sidecars and state copied outside that subtree by
  # a future export or staging step. Context source and test filenames remain
  # valid because only artifact-shaped names are rejected.
  local scan_paths
  scan_paths="$(release_find_checked "$context derived-context" "$scan_root" -mindepth 1 -print)" \
    || fail "$context derived-context walk of $scan_root did not run correctly"
  hit="$(
    printf '%s\n' "$scan_paths" \
    | awk 'NF' \
    | LC_ALL=C awk -v root="$scan_root/" '
        !found {
          path = $0
          relative = path
          if (index(relative, root) == 1) {
            relative = substr(relative, length(root) + 1)
          }
          lower = tolower(relative)
          count = split(lower, components, "/")
          basename = components[count]
          framed = "/" lower
          if (framed ~ /\/data\/context(\/|$)/ ||
              basename == "context.sqlite" ||
              basename ~ /^context\.sqlite[-.]/ ||
              basename ~ /^context[-_.]?(flow[-_.]?)?(receipts?|registrations?|arena[-_.]?snapshots?|snapshots?|diagnostics?)(\..*)?$/ ||
              framed ~ /\/context\/(.*[-_.])?(receipts?|registrations?|arena[-_.]?snapshots?|snapshots?|diagnostics?)(\/|\.|$)/ ||
              framed ~ /\/(context[-_]?flow[-_]?(state|cache)|derived[-_]?context)(\/|$)/) {
            print path
            found = 1
          }
        }
      '
  )"

  [[ -z "$hit" ]] \
    || fail "derived ContextFlow state found in $context: $hit"
  echo "[resources] verified no derived ContextFlow state in $context: $scan_root"
}

verify_data_bounds_bundle_resource() {
  local contents_resources="$1" data_bounds
  [[ -d "$contents_resources" && ! -L "$contents_resources" ]] \
    || fail "missing app Contents/Resources directory: $contents_resources"
  data_bounds="$contents_resources/docs/data-bounds.md"
  [[ -f "$data_bounds" && ! -L "$data_bounds" ]] \
    || fail "release resources missing data-limits reference: $data_bounds"
  [[ -s "$data_bounds" ]] \
    || fail "release data-limits reference is empty: $data_bounds"
  echo "[resources] verified bundled data-limits reference: $data_bounds"
}

# The shipped release notes are how the agent answers "what changed?" after
# an update. A bundle without this version's note leaves it with nothing to say.
verify_release_notes_bundle_resource() {
  local contents_resources="$1" version="$2" notes_dir note count
  notes_dir="$contents_resources/docs/release-notes"
  [[ -d "$notes_dir" && ! -L "$notes_dir" ]] \
    || fail "release resources missing bundled release notes directory: $notes_dir"
  count="$(release_find_checked "release notes" "$notes_dir" -maxdepth 1 -type f -name '*.md' -print \
    | sed '/^$/d' | wc -l | tr -d '[:space:]')" \
    || fail "release notes scan of $notes_dir did not run correctly"
  [[ "$count" -gt 0 ]] \
    || fail "release resources stage no release notes: $notes_dir"
  note="$notes_dir/$version.md"
  [[ -f "$note" && ! -L "$note" && -s "$note" ]] \
    || fail "release resources missing this version's release note: $note"
  echo "[resources] verified $count bundled release notes, including $note"
}

SPECIAL_MODE_COUNT=0
[[ -n "$RESOURCE_SOURCE_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
[[ -n "$RESOURCE_BUNDLE_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
[[ -n "$DERIVED_CONTEXT_SCAN_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
if (( SPECIAL_MODE_COUNT > 1 )); then
  fail "choose exactly one focused verification mode"
fi
if (( SPECIAL_MODE_COUNT == 1 )); then
  [[ "$ARTIFACT_OPTION_SET" == "false" ]] \
    || fail "focused verification modes cannot be combined with artifact options"
  if [[ -n "$RESOURCE_SOURCE_ROOT" ]]; then
    ruby "$ROOT/script/sync_build_declarations.rb" --verify-resources "$RESOURCE_SOURCE_ROOT"
  elif [[ -n "$RESOURCE_BUNDLE_ROOT" ]]; then
    ruby "$ROOT/script/sync_build_declarations.rb" --verify-resources "$ROOT" "$RESOURCE_BUNDLE_ROOT"
  else
    verify_no_derived_context_state "$DERIVED_CONTEXT_SCAN_ROOT" "selected tree"
  fi
  exit 0
fi

if [[ -n "$BUNDLE_PATH" && "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
  fail "--bundle verifies an app bundle only; DMG signature requirements need --dmg"
fi

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing required directory: $1"
}

verify_chrome_relay() {
  local bundle="$1"
  local relay="$bundle/Contents/MacOS/NativeAgentChromeRelay"
  [[ -f "$relay" && -x "$relay" && ! -L "$relay" ]] \
    || fail "missing Chrome relay executable: $relay"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

require_plist_value() {
  local plist="$1" key="$2" expected="$3" actual
  actual="$(plist_value "$plist" "$key")"
  [[ "$actual" == "$expected" ]] || fail "Info.plist $key expected '$expected', got '$actual'"
}

# Assert the value's type, matching the app's Swift Bool reads.
# Fails when the key exists but is not a real plist Boolean. Absent is allowed —
# the callers decide what absence means.
#
# Result lands in PLIST_BOOL_STATE ("true"/"false"/"" for absent) so fail() exits
# the verifier itself rather than a command-substitution subshell.
PLIST_BOOL_STATE=""
require_plist_bool_or_absent() {
  local plist="$1" key="$2" state
  state="$(plist_bool_state "$plist" "$key")"
  case "$state" in
    absent) PLIST_BOOL_STATE="" ;;
    true|false) PLIST_BOOL_STATE="$state" ;;
    *)
      fail "Info.plist $key must be a real Boolean (<true/>/<false/>), got ${state#non-boolean:}.
       A stringified 'true' passes text comparisons but reads as nil in Swift
       (\`info[\"$key\"] as? Bool\`), which silently disables the updater."
      ;;
  esac
}

MOUNT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-artifact-verify.XXXXXX")"
MOUNT_POINT="$MOUNT_BASE/mount"
cleanup() {
  if [[ -z "$BUNDLE_PATH" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_BASE"
}
trap cleanup EXIT

if [[ -n "$BUNDLE_PATH" ]]; then
  echo "==> Verifying NativeAgent app bundle: $BUNDLE_PATH"
  BUNDLE="$BUNDLE_PATH"
else
  echo "==> Verifying NativeAgent release artifact: $DMG_PATH"
  require_file "$DMG_PATH"

  echo "  hdiutil verify..."
  hdiutil verify "$DMG_PATH" >/dev/null

  if codesign -dv "$DMG_PATH" >/dev/null 2>&1; then
    echo "  DMG codesign verify..."
    codesign --verify --verbose=2 "$DMG_PATH" >/dev/null
  elif [[ "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
    fail "DMG is not codesigned"
  else
    echo "  WARNING: DMG is unsigned; pass --require-dmg-signature for production gating."
  fi

  mkdir -p "$MOUNT_POINT"
  echo "  mounting read-only..."
  hdiutil attach "$DMG_PATH" -readonly -nobrowse -noverify -mountpoint "$MOUNT_POINT" >/dev/null
  BUNDLE="$MOUNT_POINT/$APP_NAME.app"
fi
INFO="$BUNDLE/Contents/Info.plist"
EXECUTABLE="$BUNDLE/Contents/MacOS/$PRODUCT"
RESOURCES="$BUNDLE/Contents/Resources"

require_dir "$BUNDLE"
require_file "$INFO"
require_file "$EXECUTABLE"
[[ -x "$EXECUTABLE" ]] || fail "main executable is not executable: $EXECUTABLE"
verify_chrome_relay "$BUNDLE"

if [[ -z "$BUNDLE_PATH" ]]; then
  [[ -L "$MOUNT_POINT/Applications" ]] || fail "DMG missing /Applications symlink"
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || fail "DMG /Applications symlink points to $(readlink "$MOUNT_POINT/Applications")"
fi

require_plist_value "$INFO" "CFBundleIdentifier" "$EXPECTED_MAC_BUNDLE_ID"
require_plist_value "$INFO" "CFBundleExecutable" "$PRODUCT"
# release.sh supplies the expected short version; standalone verification requires VERSION.
require_plist_value "$INFO" "CFBundleShortVersionString" \
  "${NATIVEAGENT_EXPECTED_SHORT_VERSION:-$VERSION}"
require_plist_value "$INFO" "CFBundleVersion" "$VERSION"
require_plist_value "$INFO" "CFBundlePackageType" "APPL"
require_plist_value "$INFO" "LSMinimumSystemVersion" "26.0"
require_plist_value "$INFO" "UTExportedTypeDeclarations:0:UTTypeIdentifier" "com.nativeagent.chat-session"

SPARKLE_KEY="$(plist_value "$INFO" "SUPublicEDKey")"
if [[ "$REQUIRE_SPARKLE_KEY" == "true" ]]; then
  [[ -n "$SPARKLE_KEY" ]] || fail "SUPublicEDKey is empty"
  if ! printf '%s' "$SPARKLE_KEY" | base64 -D >/dev/null 2>&1; then
    fail "SUPublicEDKey is not valid base64"
  fi
  SPARKLE_KEY_BYTES="$(printf '%s' "$SPARKLE_KEY" | base64 -D | wc -c | tr -d '[:space:]')"
  [[ "$SPARKLE_KEY_BYTES" == "32" ]] || fail "SUPublicEDKey must decode to 32 bytes; got $SPARKLE_KEY_BYTES"
fi

# A2.1-2026-07-24: updater honesty. An artifact must never advertise an update
# feed it cannot actually serve. dist/NativeAgent-0.2.0.dmg shipped with
# SUFeedURL pointing at an example.com placeholder; this is the gate that would
# have stopped it. Checked unconditionally — a lying feed URL is never OK.
SPARKLE_FEED_URL="$(plist_value "$INFO" "SUFeedURL")"
# Type-strict: these two are what the app reads as Swift Bool, so a stringified
# "true" here means the shipped updater is OFF while the text says it is on.
require_plist_bool_or_absent "$INFO" "NativeAgentUpdateFeedPublished"
SPARKLE_FEED_PUBLISHED="$PLIST_BOOL_STATE"
require_plist_bool_or_absent "$INFO" "SUEnableAutomaticChecks"
SPARKLE_AUTO_CHECKS="$PLIST_BOOL_STATE"
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  # Sparkle itself reads SUFeedURL as a string; a Boolean/number here would make
  # the feed URL unreadable to the framework at runtime.
  SPARKLE_FEED_URL_TYPE="$(plist_string_state "$INFO" SUFeedURL)"
  [[ "$SPARKLE_FEED_URL_TYPE" == "string" ]] \
    || fail "Info.plist SUFeedURL must be a <string>; Sparkle cannot read any other type."
  if printf '%s' "$SPARKLE_FEED_URL" | grep -Eqi '(^|//|\.)(example\.(com|org|net|invalid)|localhost)(/|:|$)'; then
    fail "SUFeedURL is a placeholder that will 404 for every user: $SPARKLE_FEED_URL"
  fi
  [[ "$SPARKLE_FEED_URL" =~ ^https:// ]] || fail "SUFeedURL must be https: $SPARKLE_FEED_URL"
  [[ "$SPARKLE_FEED_PUBLISHED" == "true" ]] \
    || fail "SUFeedURL is stamped but NativeAgentUpdateFeedPublished is '${SPARKLE_FEED_PUBLISHED:-absent}' — build with ./script/release.sh --publish-appcast"
fi
if [[ "$SPARKLE_FEED_PUBLISHED" == "true" ]]; then
  [[ -n "$SPARKLE_FEED_URL" ]] || fail "NativeAgentUpdateFeedPublished is true but no SUFeedURL is stamped"
  [[ -n "$SPARKLE_KEY" ]] || fail "NativeAgentUpdateFeedPublished is true but SUPublicEDKey is empty"
elif [[ "$SPARKLE_AUTO_CHECKS" == "true" ]]; then
  fail "SUEnableAutomaticChecks is true with no published feed — background checks would 404"
fi

release_assert_executable_stripped "$EXECUTABLE" \
  || fail "release executable contains non-external symbols"

require_dir "$RESOURCES"
require_file "$RESOURCES/VERSION"
require_file "$RESOURCES/VERSION_SHA"
SOURCE_REVISION="$(tr -d '[:space:]' < "$RESOURCES/VERSION_SHA")"
PLIST_SOURCE_REVISION="$(plist_value "$INFO" "NativeAgentSourceRevision")"
SOURCE_DIRTY="$(plist_value "$INFO" "NativeAgentSourceDirty")"
[[ "$SOURCE_REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$SOURCE_REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
  || fail "VERSION_SHA must contain one full Git object ID"
[[ "$PLIST_SOURCE_REVISION" == "$SOURCE_REVISION" ]] \
  || fail "Info.plist source revision does not match Resources/VERSION_SHA"
[[ "$SOURCE_DIRTY" == "true" || "$SOURCE_DIRTY" == "false" ]] \
  || fail "Info.plist NativeAgentSourceDirty must be a Boolean"
if [[ "$REQUIRE_CLEAN_SOURCE" == "true" && "$SOURCE_DIRTY" != "false" ]]; then
  fail "release artifact was built from a dirty or unknown source tree"
fi
ruby "$ROOT/script/sync_build_declarations.rb" --verify-resources "$ROOT" "$RESOURCES"
verify_data_bounds_bundle_resource "$RESOURCES"
verify_release_notes_bundle_resource "$RESOURCES" "$VERSION"
verify_no_derived_context_state "$RESOURCES" "release resources"
release_assert_no_user_state_in_bundle "$BUNDLE" \
  || fail "release artifact contains user/runtime state or its scan failed"

first_line() { printf '%s\n' "$1" | sed '/^$/d' | head -1; }

bad_world_writable="$(release_find_checked "world-writable" "$BUNDLE" -perm -002 -print)" \
  || fail "world-writable scan of $BUNDLE did not run correctly"
[[ -z "$bad_world_writable" ]] || fail "world-writable path inside app bundle: $(first_line "$bad_world_writable")"

bad_readable="$(release_find_checked "readability" "$BUNDLE" \( -type f ! -perm -004 -o -type d ! -perm -005 \) -print)" \
  || fail "readability scan of $BUNDLE did not run correctly"
[[ -z "$bad_readable" ]] || fail "path is not readable/traversable by normal users: $(first_line "$bad_readable")"

backup_hits="$(release_find_checked "backup-file" "$RESOURCES" -type f -name '*.bak*' -print)" \
  || fail "backup-file scan of $RESOURCES did not run correctly"
[[ -z "$backup_hits" ]] || fail "backup file shipped in release bundle: $(first_line "$backup_hits")"

release_assert_no_leaked_data "$BUNDLE" "$PRODUCT" "$ROOT" \
  || fail "release artifact failed content-leak validation"

echo "  app codesign verify..."
codesign --verify --deep --strict --verbose=2 "$BUNDLE" >/dev/null

echo "  signed Calendar entitlement..."
SIGNED_ENTITLEMENTS="$MOUNT_BASE/nativeagent-signed-entitlements.plist"
codesign -d --entitlements :- "$BUNDLE" > "$SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "unable to read signed app entitlements"
calendar_entitlement="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.personal-information.calendars' \
    "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
)"
[[ "$calendar_entitlement" == "true" ]] \
  || fail "signed app is missing the Calendar entitlement required by hardened-runtime TCC"

DEVICE_SYNC="$(plist_value "$INFO" "NativeAgentDeviceSync")"
if [[ "$DEVICE_SYNC" == "cloudkit" ]]; then
  EMBEDDED_PROFILE="$BUNDLE/Contents/embedded.provisionprofile"
  require_file "$EMBEDDED_PROFILE"
  PROFILE_PLIST="$MOUNT_BASE/nativeagent-embedded-profile.plist"
  decode_provisioning_profile "$EMBEDDED_PROFILE" "$PROFILE_PLIST" \
    || fail "unable to decode the embedded public CloudKit provisioning profile"

  EXPECTED_CONTAINER="$(plist_value "$INFO" "NativeAgentICloudContainerID")"
  [[ -n "$EXPECTED_CONTAINER" ]] \
    || fail "CloudKit release is missing NativeAgentICloudContainerID"
  SIGNATURE_TEAM="$(
    codesign -dvv "$BUNDLE" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2; exit}'
  )"
  [[ -n "$SIGNATURE_TEAM" ]] \
    || fail "CloudKit release signature has no TeamIdentifier"
  verify_public_cloudkit_profile_contract \
    "$PROFILE_PLIST" \
    "$SIGNATURE_TEAM" \
    "$EXPECTED_MAC_BUNDLE_ID" \
    "$EXPECTED_CONTAINER" \
    || fail "embedded public CloudKit profile does not match the signed release identity"

  signed_aps="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.aps-environment' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_environment="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.icloud-container-environment' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_application_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.application-identifier' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_team_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.team-identifier' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  [[ "$signed_application_identifier" == "$SIGNATURE_TEAM.$EXPECTED_MAC_BUNDLE_ID" ]] \
    || fail "signed CloudKit app application identifier '$signed_application_identifier' does not match '$SIGNATURE_TEAM.$EXPECTED_MAC_BUNDLE_ID'"
  [[ "$signed_team_identifier" == "$SIGNATURE_TEAM" ]] \
    || fail "signed CloudKit app team entitlement '$signed_team_identifier' does not match signature team '$SIGNATURE_TEAM'"
  [[ "$signed_aps" == "production" && "$signed_environment" == "Production" ]] \
    || fail "signed CloudKit release does not use production APNS and CloudKit environments"
  provisioning_profile_array_contains \
    "$SIGNED_ENTITLEMENTS" \
    "com.apple.developer.icloud-container-identifiers" \
    "$EXPECTED_CONTAINER" \
    || fail "signed app does not declare the exact CloudKit container '$EXPECTED_CONTAINER'"
  echo "  signed entitlements and embedded profile match team, app, container, and production environments..."
fi

nativeagent_assert_no_python_artifacts "$BUNDLE" '[verify_release_artifact]' shipped release \
  || fail 'Python artifact validation failed'

echo "  public first-run guard marker strings..."
MARKER_STRINGS="$MOUNT_BASE/nativeagent-executable.strings"
strings "$EXECUTABLE" > "$MARKER_STRINGS"
grep -q 'public_release_data_root.json' "$MARKER_STRINGS" || fail "app binary missing public release data marker string"

if [[ "$REQUIRE_NOTARIZED" == "true" ]]; then
  echo "  app notarization/staple validation..."
  xcrun stapler validate "$BUNDLE" >/dev/null
  spctl -a -vvv -t execute "$BUNDLE" >/dev/null
  if [[ -z "$BUNDLE_PATH" && "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
    echo "  DMG notarization/staple validation..."
    xcrun stapler validate "$DMG_PATH" >/dev/null
    spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH" >/dev/null
  fi
fi

if [[ -n "$BUNDLE_PATH" ]]; then
  echo "==> Release bundle verification passed: $BUNDLE_PATH"
else
  echo "==> Release artifact verification passed: $DMG_PATH"
fi
