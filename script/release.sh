#!/usr/bin/env bash
# Production release script for NativeAgent.
# Usage:
#   ./script/release.sh               — full notarized release
#   ./script/release.sh --dry-run     — sign the selected mode, skip notarization
#   ./script/release.sh --artifact-only — accepted spelling for the release receipt path
#   ./script/release.sh --appcast          — also generate+sign the Sparkle appcast
#                                            locally (uploads nothing)
#   ./script/release.sh --publish-appcast  — generate+sign AND publish the feed;
#                                            only this mode lets the app claim that
#                                            automatic updates work
#   ./script/release.sh --notes FILE       — release notes for the Sparkle update
#                                            dialog AND the GitHub release body.
#                                            Defaults to docs/release-notes/<VERSION>.md
#                                            when that file exists; with neither,
#                                            the update dialog stays blank.
#   ./script/release.sh --self-test-gates dist/NativeAgent.app
#                                          — run the identity leak gate and the
#                                            bundle assertion against an existing
#                                            .app and exit. Builds/signs nothing.
#   ./script/release.sh --print-env-surface — print the values-free external
#                                            release configuration interface.
#
# Public releases (NATIVEAGENT_ICLOUD_BUILD other than personal) build only
# from reviewed public source. A private invocation prepares a source export
# and stops; --publish-appcast requires already published public source.
#   NATIVEAGENT_PUBLIC_EXPORT_DIR   — where to put the export (default: mktemp)
# For ad-hoc local proof (no Developer ID signing), select it explicitly:
#   NATIVEAGENT_SIGNING_MODE=adhoc ./script/release.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sparkle_tools.sh
source "$ROOT/script/lib/sparkle_tools.sh"
# shellcheck source=lib/release_quarantine.sh
source "$ROOT/script/lib/release_quarantine.sh"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/release_bundle_gates.sh
source "$ROOT/script/lib/release_bundle_gates.sh"
# shellcheck source=lib/release_symbols.sh
source "$ROOT/script/lib/release_symbols.sh"
source "$ROOT/script/lib/build_source_inventory.sh"
source "$ROOT/script/lib/embedding_model_contract.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
DRY_RUN=false
# Appcast generation and publication are opt-in.
GENERATE_APPCAST=false
PUBLISH_APPCAST=false
RELEASE_NOTES_FILE=""
PRINT_ENV_SURFACE=false

# Package bge-large-en-v1.5 inside the app by default. No release packaging
# step downloads a model; separate-download remains an explicit override.
release_prepare_embedding() { # bundle, output directory, version
  local bundle="$1" out="$2" version="$3" work asset digest bytes url
  local source="${NATIVEAGENT_EMBEDDING_MODEL_DIR:-$ROOT/extras/embedding}"
  local mode="${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}"
  case "$mode" in separate-download|bundled) ;; *) echo "ERROR: embedding distribution must be separate-download or bundled" >&2; return 1 ;; esac
  nativeagent_require_embedding_model "$source" || return 1
  mkdir -p "$out" "$bundle/Contents/Resources"
  asset="NativeAgent-$version.embedding.zip"
  work="$(mktemp -d "$out/.embedding.XXXXXX")"
  mkdir "$work/embedding"
  cp -pR "$source/embedding.json" "$source/embedding.mlpackage" "$source/vocab.txt" "$work/embedding/"
  touch -r "$work/embedding/embedding.json" "$work/embedding"
  if [[ "$mode" == bundled ]]; then
    rm -rf "$bundle/Contents/Resources/embedding"
    mv "$work/embedding" "$bundle/Contents/Resources/embedding"
    rm -f "$bundle/Contents/Resources/embedding-download.json" \
      "$out/$asset" "$out/NativeAgent-$version.embedding.json"
    rm -rf "$work"
    echo "[embedding] bundled inside the app; no separate download"
    return 0
  fi
  ditto -c -k --norsrc --keepParent "$work/embedding" "$work/$asset"
  mv -f "$work/$asset" "$out/$asset"
  digest="$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
  bytes="$(wc -c < "$out/$asset" | tr -d '[:space:]')"
  url="${NATIVEAGENT_DMG_DOWNLOAD_URL:-}"
  [[ "$url" == https://*/* ]] || { rm -rf "$work"; echo "ERROR: model asset requires the release DMG HTTPS URL" >&2; return 1; }
  url="${url%/*}/$asset"
  jq -n --arg name "$asset" --arg sha256 "$digest" --argjson byte_length "$bytes" \
    --arg url "$url" --arg distribution "$mode" --slurpfile model "$work/embedding/embedding.json" \
    '{schema_version:1, name:$name, sha256:$sha256, byte_length:$byte_length, url:$url,
      distribution:$distribution, archive_root:"embedding", model:$model[0]}' \
    > "$out/NativeAgent-$version.embedding.json"
  rm -rf "$bundle/Contents/Resources/embedding"
  cp "$out/NativeAgent-$version.embedding.json" "$bundle/Contents/Resources/embedding-download.json"
  rm -rf "$work"
  echo "[embedding] $mode: $asset ($bytes bytes, sha256 $digest)"
}

# Offline packaging rehearsal: only the explicitly supplied bundle/output paths
# are written. This is also the exact packaging boundary used by the release.
if [[ "${1:-}" == --prepare-embedding ]]; then
  [[ $# == 4 ]] || { echo "Usage: release.sh --prepare-embedding BUNDLE OUT VERSION" >&2; exit 2; }
  [[ "$4" =~ ^[0-9]+([.][0-9A-Za-z-]+)+$ ]] || exit 2
  release_prepare_embedding "$2" "$3" "$4"
  exit 0
fi

# Values are intentionally never printed. This is the stable, inspectable
# external configuration surface for automation and release preflights.
RELEASE_ENV_SURFACE=(
  NATIVEAGENT_DEVELOPER_ID
  NATIVEAGENT_TEAM_ID
  NATIVEAGENT_APPLE_ID
  NATIVEAGENT_NOTARIZATION_PASSWORD
  NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE
  NATIVEAGENT_SPARKLE_ED_PRIV_KEY
  NATIVEAGENT_SPARKLE_PUBLIC_KEY
  NATIVEAGENT_PROVISIONING_PROFILE
  NATIVEAGENT_WIDGET_PROVISIONING_PROFILE
  NATIVEAGENT_MAC_APP_GROUP_ID
  NATIVEAGENT_MAC_WIDGET_BUNDLE_ID
  NATIVEAGENT_APPCAST_URL
  NATIVEAGENT_DMG_DOWNLOAD_URL
  NATIVEAGENT_RELEASE_PAGE_URL
  NATIVEAGENT_ICLOUD_BUILD
  NATIVEAGENT_MAC_BUNDLE_ID
  NATIVEAGENT_ICLOUD_CONTAINER_ID
  NATIVEAGENT_MOBILE_SOURCE_KEY
  NATIVEAGENT_BACKGROUND_TASK_PREFIX
  NATIVEAGENT_INTERNAL_BUILD_STAMP
  NATIVEAGENT_RELEASE_ENTITLEMENTS
  NATIVEAGENT_PUBLIC_EXPORT_DIR
  NATIVEAGENT_PRIVACY_DENYLIST_FILE
  NATIVEAGENT_RELEASE_SYMBOL_ARCHIVE_DIR
  NATIVEAGENT_PRODUCT
  NATIVEAGENT_SIGNING_MODE
  NATIVEAGENT_SKIP_DMG_SIGN
  NATIVEAGENT_EMBEDDING_DISTRIBUTION
  NATIVEAGENT_EMBEDDING_MODEL_DIR
  NATIVEAGENT_SPARKLE_PREVIOUS_DMG
)

release_print_env_surface() {
  printf '%s\n' "${RELEASE_ENV_SURFACE[@]}"
}

SELF_TEST_GATES_TARGET=""
_expect_self_test_target=false
_expect_notes_file=false
for arg in "$@"; do
  if [[ "$_expect_self_test_target" == "true" ]]; then
    SELF_TEST_GATES_TARGET="$arg"
    _expect_self_test_target=false
    continue
  fi
  if [[ "$_expect_notes_file" == "true" ]]; then
    RELEASE_NOTES_FILE="$arg"
    _expect_notes_file=false
    continue
  fi
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --artifact-only) ;;
    --appcast) GENERATE_APPCAST=true ;;
    --publish-appcast) GENERATE_APPCAST=true; PUBLISH_APPCAST=true ;;
    --notes) _expect_notes_file=true ;;
    --notes=*) RELEASE_NOTES_FILE="${arg#--notes=}" ;;
    --self-test-gates) _expect_self_test_target=true ;;
    --self-test-gates=*) SELF_TEST_GATES_TARGET="${arg#--self-test-gates=}" ;;
    --print-env-surface) PRINT_ENV_SURFACE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
if [[ "$_expect_notes_file" == "true" ]]; then
  echo "ERROR: --notes requires a path to a release-notes file." >&2
  exit 1
fi
if [[ -n "$RELEASE_NOTES_FILE" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "ERROR: --notes file not found: $RELEASE_NOTES_FILE" >&2
  exit 1
fi
if [[ "$_expect_self_test_target" == "true" ]]; then
  echo "ERROR: --self-test-gates requires a path to a .app bundle." >&2
  exit 1
fi

# One current environment namespace, also passed to child owners.
for release_var in "${RELEASE_ENV_SURFACE[@]}"; do
  printf -v "$release_var" '%s' "${!release_var:-}"
  export "${release_var?}"
done

if [[ "$PRINT_ENV_SURFACE" == "true" ]]; then
  release_print_env_surface
  exit 0
fi

# Run the bundle gates against an existing app without building or signing.
if [[ -n "$SELF_TEST_GATES_TARGET" ]]; then
  if [[ ! -d "$SELF_TEST_GATES_TARGET" ]]; then
    echo "ERROR: --self-test-gates target is not a directory: $SELF_TEST_GATES_TARGET" >&2
    exit 1
  fi
  echo "==> Self-testing release gates against $SELF_TEST_GATES_TARGET"
  _self_test_rc=0
  release_assert_no_leaked_data "$SELF_TEST_GATES_TARGET" "$PRODUCT" "$ROOT" || _self_test_rc=1
  release_assert_no_identity_strings "$SELF_TEST_GATES_TARGET" || _self_test_rc=1
  release_assert_no_user_state_in_bundle "$SELF_TEST_GATES_TARGET" || _self_test_rc=1
  if [[ "$_self_test_rc" -eq 0 ]]; then
    echo "==> Gate self-test: BOTH GATES PASS for this bundle."
  else
    echo "==> Gate self-test: at least one gate FAILED (a real release would abort here)." >&2
  fi
  exit "$_self_test_rc"
fi

# --dry-run exits before the DMG exists, so appcast flags cannot apply.
if [[ "$DRY_RUN" == "true" && "$GENERATE_APPCAST" == "true" ]]; then
  echo "ERROR: --dry-run stops before the DMG is built, so --appcast/--publish-appcast" >&2
  echo "       cannot run and would be silently ignored." >&2
  echo "       To exercise the feed pipeline against an existing DMG:" >&2
  echo "         ./script/generate_appcast.sh --dmg dist/NativeAgent-<version>.dmg --rehearsal" >&2
  exit 1
fi

# VERSION is the source of the bare release version.
VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found. Create it with a semver string (e.g. 0.2.0)." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
NATIVEAGENT_SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
NATIVEAGENT_SOURCE_REVISION="${NATIVEAGENT_SOURCE_REVISION:-unknown}"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
  NATIVEAGENT_SOURCE_DIRTY=true
else
  NATIVEAGENT_SOURCE_DIRTY=false
fi

# Internal short versions carry -dev.<sha8>[.dirty]; Sparkle's build version stays bare.
INTERNAL_BUILD_STAMP="${NATIVEAGENT_INTERNAL_BUILD_STAMP:-1}"
INTERNAL_VERSION_SUFFIX=""
if [[ "$PUBLISH_APPCAST" != "true" && "$INTERNAL_BUILD_STAMP" != "0" ]]; then
  short_revision="${NATIVEAGENT_SOURCE_REVISION:0:8}"
  [[ "$short_revision" =~ ^[0-9a-f]{8}$ ]] || short_revision="nogit"
  INTERNAL_VERSION_SUFFIX="-dev.$short_revision"
  [[ "$NATIVEAGENT_SOURCE_DIRTY" != true ]] || INTERNAL_VERSION_SUFFIX+=".dirty"
fi
EFFECTIVE_SHORT_VERSION="$VERSION$INTERNAL_VERSION_SUFFIX"
export NATIVEAGENT_EXPECTED_SHORT_VERSION="$EFFECTIVE_SHORT_VERSION"

assert_full_release_source_unchanged() {
  [[ "$DRY_RUN" == "false" ]] || return 0
  local current_revision current_dirty
  current_revision="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  current_dirty="$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)"
  [[ "$NATIVEAGENT_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$NATIVEAGENT_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || { echo "ERROR: full release requires one exact Git source object ID." >&2; exit 1; }
  [[ "$current_revision" == "$NATIVEAGENT_SOURCE_REVISION" ]] \
    || { echo "ERROR: source HEAD changed during the release build; restart from a stable commit." >&2; exit 1; }
  [[ -z "$current_dirty" ]] \
    || { echo "ERROR: full release requires a clean source tree and it changed during the build." >&2; exit 1; }
}

assert_full_release_source_unchanged
echo "==> NativeAgent release v$VERSION (dry-run=$DRY_RUN)"

NATIVEAGENT_MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"
NATIVEAGENT_ICLOUD_CONTAINER_ID="${NATIVEAGENT_ICLOUD_CONTAINER_ID:-iCloud.io.github.embwl0x.nativeagent}"
NATIVEAGENT_MOBILE_SOURCE_KEY="${NATIVEAGENT_MOBILE_SOURCE_KEY:-mobile_app}"
NATIVEAGENT_BACKGROUND_TASK_PREFIX="${NATIVEAGENT_BACKGROUND_TASK_PREFIX:-io.github.embwl0x.nativeagent}"
NATIVEAGENT_RELEASE_PAGE_URL="${NATIVEAGENT_RELEASE_PAGE_URL:-https://github.com/embwl0x/native-agent/releases}"
export NATIVEAGENT_RELEASE_PAGE_URL

# Stamp SUFeedURL and the updater claim only for publication in this run; never synthesize a URL.
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  NATIVEAGENT_UPDATE_FEED_PUBLISHED=true
  SPARKLE_FEED_URL_STAMP="$NATIVEAGENT_APPCAST_URL"
else
  NATIVEAGENT_UPDATE_FEED_PUBLISHED=false
  SPARKLE_FEED_URL_STAMP=""
fi
export NATIVEAGENT_DEVELOPER_ID
export NATIVEAGENT_TEAM_ID
export NATIVEAGENT_APPLE_ID
export NATIVEAGENT_NOTARIZATION_PASSWORD
export NATIVEAGENT_SPARKLE_ED_PRIV_KEY
export NATIVEAGENT_SPARKLE_PUBLIC_KEY
export NATIVEAGENT_PROVISIONING_PROFILE
export NATIVEAGENT_APPCAST_URL
export NATIVEAGENT_DMG_DOWNLOAD_URL
export NATIVEAGENT_RELEASE_PAGE_URL
export NATIVEAGENT_MAC_BUNDLE_ID
export NATIVEAGENT_ICLOUD_CONTAINER_ID
export NATIVEAGENT_MOBILE_SOURCE_KEY
export NATIVEAGENT_BACKGROUND_TASK_PREFIX

# Distribution transport modes:
#   personal      — development/personal KVS + Drive + CloudKit profile
#   cloudkit      — public Developer ID build with production CloudKit only
#   none          — public standalone build with no Apple device transport
#
# The official Mac+iPhone release uses `cloudkit`; KVS/CloudDocuments are not
# part of the public Developer ID contract. Every public mode starts from the
# scrubbed, marker-bearing export.
NATIVEAGENT_ICLOUD_BUILD="${NATIVEAGENT_ICLOUD_BUILD:-personal}"
case "$NATIVEAGENT_ICLOUD_BUILD" in
  personal) NATIVEAGENT_RELEASE_SYNC_MODE="personal" ;;
  cloudkit) NATIVEAGENT_RELEASE_SYNC_MODE="cloudkit" ;;
  none) NATIVEAGENT_RELEASE_SYNC_MODE="none" ;;
  *)
    echo "ERROR: NATIVEAGENT_ICLOUD_BUILD must be personal, cloudkit, or none." >&2
    exit 1
    ;;
esac
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "none" ]]; then
  # Keep the explicit standalone lane honest: no signed iCloud entitlement and
  # no bundle metadata that makes Doctor or the runtime expect one.
  NATIVEAGENT_ICLOUD_CONTAINER_ID="iCloud.com.example.nativeagent"
fi
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
  NATIVEAGENT_DEVICE_SYNC="cloudkit"
else
  # Preserve the established KVS/Drive transport for personal builds. The
  # standalone lane also stamps the inert legacy default, but carries no Apple
  # sync entitlements so no device bridge can start.
  NATIVEAGENT_DEVICE_SYNC="kvs"
fi
if [[ "$DRY_RUN" == "false" ]]; then
  if [[ "$NATIVEAGENT_MAC_BUNDLE_ID" == com.example.* \
     || "$NATIVEAGENT_BACKGROUND_TASK_PREFIX" == com.example.* ]]; then
    echo "ERROR: production release identity still uses the com.example placeholder." >&2
    echo "       Set the stable Mac bundle and background-task identifiers explicitly." >&2
    exit 1
  fi
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "none" \
     && "$NATIVEAGENT_ICLOUD_CONTAINER_ID" == iCloud.com.example.* ]]; then
    echo "ERROR: production device-sync release still uses the example iCloud container." >&2
    exit 1
  fi
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" \
     && "$NATIVEAGENT_MOBILE_SOURCE_KEY" != "mobile_app" ]]; then
    echo "ERROR: public CloudKit release requires the neutral mobile source key 'mobile_app'." >&2
    exit 1
  fi
fi
NATIVEAGENT_NEEDS_PUBLIC_SCRUB=false
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "personal" ]]; then
  if [[ -f "$ROOT/.nativeagent-public-source" ]]; then
    "$ROOT/script/check_public_release_source.sh" "$ROOT"
  else
    NATIVEAGENT_NEEDS_PUBLIC_SCRUB=true
  fi
fi
# A private tree prepares a concrete source artifact for review and stops.
# Publication starts only from the reviewed commit already in the public repo.
if [[ "$NATIVEAGENT_NEEDS_PUBLIC_SCRUB" == true ]]; then
  if [[ "$PUBLISH_APPCAST" == true ]]; then
    echo 'ERROR: publication requires a reviewed, published public checkout before building.' >&2
    echo 'Run script/make_public_export.sh DIR; review and publish that source, then run script/release_github.sh there.' >&2
    exit 1
  fi
  PUBLIC_EXPORT_DIR="${NATIVEAGENT_PUBLIC_EXPORT_DIR:-$ROOT/.runtime/public-release-export}"
  "$ROOT/script/make_public_export.sh" "$PUBLIC_EXPORT_DIR"
  echo "==> Source export ready for review: $PUBLIC_EXPORT_DIR (no build or publication performed)"
  exit 0
fi
if [[ "$PUBLISH_APPCAST" == true ]]; then
  "$ROOT/script/publish_github_release.sh" --preflight-source
fi

# Notarize via a stored keychain profile (xcrun notarytool store-credentials)
# instead of an app-specific password in the environment — keeps the secret out
# of env/logs. When set, APPLE_ID/NOTARIZATION_PASSWORD are not required.
NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE="${NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE:-}"
# Signing entitlements: explicit override wins; else picked by ICLOUD_BUILD.
NATIVEAGENT_RELEASE_ENTITLEMENTS="${NATIVEAGENT_RELEASE_ENTITLEMENTS:-}"
GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS=""
RELEASE_WIDGET_WORK=""
NATIVEAGENT_WIDGET_PROVISIONING_PROFILE="${NATIVEAGENT_WIDGET_PROVISIONING_PROFILE:-$ROOT/local/NativeAgentWidget.provisionprofile}"
NATIVEAGENT_MAC_APP_GROUP_ID="${NATIVEAGENT_MAC_APP_GROUP_ID:-group.$NATIVEAGENT_MAC_BUNDLE_ID}"
NATIVEAGENT_MAC_WIDGET_BUNDLE_ID="${NATIVEAGENT_MAC_WIDGET_BUNDLE_ID:-$NATIVEAGENT_MAC_BUNDLE_ID.widget}"
cleanup_generated_release_entitlements() {
  if [[ -n "${RELEASE_WIDGET_WORK:-}" ]]; then
    rm -rf "$RELEASE_WIDGET_WORK"
  fi
  if [[ -n "${GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS:-}" ]]; then
    rm -f "$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"
  fi
}
trap cleanup_generated_release_entitlements EXIT
if [[ -z "$NATIVEAGENT_RELEASE_ENTITLEMENTS" ]]; then
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "personal" ]]; then
    # The selected personal product requires its own local identity contract.
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/local/NativeAgent.entitlements"
  elif [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    if [[ -f "$ROOT/local/NativeAgent.cloudkit.public.entitlements" ]]; then
      NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/local/NativeAgent.cloudkit.public.entitlements"
    else
      echo "ERROR: CloudKit public release requires a maintainer-specific entitlement file." >&2
      echo "       Copy NativeAgent.cloudkit-public.entitlements to" >&2
      echo "       local/NativeAgent.cloudkit.public.entitlements and replace the example container." >&2
      exit 1
    fi
  else
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/NativeAgent.public.entitlements"
  fi
fi

# Validate actual entitlement contents before building; profile-less builds cannot carry iCloud grants.
# Keep the supplied host profile for the widget gate even when the standalone
# lane clears the profile used by the rest of the release pipeline.
RELEASE_WIDGET_HOST_PROFILE="$NATIVEAGENT_PROVISIONING_PROFILE"
if [[ "$DRY_RUN" == "false" ]]; then
  [[ -r "$NATIVEAGENT_RELEASE_ENTITLEMENTS" ]] || { echo "ERROR: entitlements not readable: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2; exit 1; }
  plutil -lint "$NATIVEAGENT_RELEASE_ENTITLEMENTS" >/dev/null || { echo "ERROR: entitlements plist invalid: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2; exit 1; }
  calendar_access="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.personal-information.calendars' \
      "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
  )"
  [[ "$calendar_access" == "true" ]] \
    || { echo "ERROR: production entitlements must retain Calendar TCC authority." >&2; exit 1; }

  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "none" ]]; then
    if grep -qE "com\.apple\.developer\.(icloud|ubiquity|background-tasks)" "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: standalone public build but the signed entitlements declare" >&2
      echo "       iCloud/ubiquity/background-tasks: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2
      echo "       A Developer-ID app with these + no provisioning profile is KILLED at launch." >&2
      echo "       Use NativeAgent.public.entitlements (or unset NATIVEAGENT_RELEASE_ENTITLEMENTS)." >&2
      exit 1
    fi
    if [[ -n "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
      echo "[release] public build: ignoring NATIVEAGENT_PROVISIONING_PROFILE — a no-iCloud public" >&2
      echo "[release] artifact embeds no provisioning profile (gpt-5.5 MED)." >&2
      NATIVEAGENT_PROVISIONING_PROFILE=""
    fi
  elif [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    services="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.icloud-services' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    printf '%s' "$services" | grep -Fq CloudKit \
      || { echo "ERROR: CloudKit public entitlements do not grant CloudKit." >&2; exit 1; }
    if printf '%s' "$services" | grep -Fq CloudDocuments \
      || grep -qE "com\.apple\.developer\.(ubiquity|background-tasks)" "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: public CloudKit mode must not declare CloudDocuments, KVS/ubiquity, or background-task entitlements." >&2
      exit 1
    fi
    aps_environment="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.aps-environment' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    container_environment="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.icloud-container-environment' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    [[ "$aps_environment" == "production" && "$container_environment" == "Production" ]] \
      || { echo "ERROR: public CloudKit release requires production APS and CloudKit environments." >&2; exit 1; }
    if grep -Fqi 'example.nativeagent' "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: public CloudKit release entitlements still contain the example container." >&2
      exit 1
    fi
  fi
fi

# List all missing release inputs before aborting.
if [[ "$DRY_RUN" == "false" ]]; then
  REQUIRED_VARS=(
    NATIVEAGENT_DEVELOPER_ID
    NATIVEAGENT_TEAM_ID
    NATIVEAGENT_SPARKLE_ED_PRIV_KEY
    NATIVEAGENT_SPARKLE_PUBLIC_KEY
  )
  # Feed URLs are required only when producing a feed.
  if [[ "$GENERATE_APPCAST" == "true" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_APPCAST_URL NATIVEAGENT_DMG_DOWNLOAD_URL )
  fi
  # Provisioning profile only needed for the iCloud build (it authorizes the
  # container); the no-iCloud public build ships without one.
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "none" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_PROVISIONING_PROFILE )
  fi
  # Notary creds: a stored keychain profile replaces the apple-id/password pair.
  if [[ -z "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_APPLE_ID NATIVEAGENT_NOTARIZATION_PASSWORD )
  fi
  missing=()
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: The following required environment variables are not set:" >&2
    for v in "${missing[@]}"; do
      echo "  $v" >&2
    done
    echo "" >&2
    echo "Set them and re-run. See docs/release_setup.md for details." >&2
    echo "" >&2
    echo "  NATIVEAGENT_DEVELOPER_ID      — Developer ID Application: Developer Name (XXXXXXXXXX)" >&2
    echo "  NATIVEAGENT_TEAM_ID           — 10-char Apple Team ID" >&2
    echo "  NATIVEAGENT_APPLE_ID          — Apple ID email for notarization" >&2
    echo "  NATIVEAGENT_NOTARIZATION_PASSWORD — app-specific password from appleid.apple.com" >&2
    echo "  NATIVEAGENT_SPARKLE_ED_PRIV_KEY   — path to Sparkle EdDSA private key file" >&2
    echo "  NATIVEAGENT_SPARKLE_PUBLIC_KEY    — Sparkle EdDSA public key string for SUPublicEDKey" >&2
    echo "  NATIVEAGENT_PROVISIONING_PROFILE  — Developer ID provisioning profile matching NativeAgent.entitlements" >&2
    echo "  NATIVEAGENT_APPCAST_URL           — public Sparkle appcast URL (--appcast only)" >&2
    echo "  NATIVEAGENT_DMG_DOWNLOAD_URL      — public URL the DMG is served from (--appcast only)" >&2
    exit 1
  fi
  if [[ ! -r "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY" ]]; then
    echo "ERROR: NATIVEAGENT_SPARKLE_ED_PRIV_KEY is not readable: $NATIVEAGENT_SPARKLE_ED_PRIV_KEY" >&2
    exit 1
  fi
  if grep -q "BEGIN .*PRIVATE KEY" "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY"; then
    echo "ERROR: NATIVEAGENT_SPARKLE_ED_PRIV_KEY is a PEM key, not a Sparkle EdDSA key file." >&2
    echo "Generate it with Sparkle's generate_keys tool." >&2
    exit 1
  fi
  if ! printf '%s' "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" | base64 -D >/dev/null 2>&1; then
    echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY is not valid base64." >&2
    exit 1
  fi
  SPARKLE_PUBLIC_KEY_BYTES="$(printf '%s' "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" | base64 -D | wc -c | tr -d '[:space:]')"
  if [[ "$SPARKLE_PUBLIC_KEY_BYTES" != "32" ]]; then
    echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY must decode to 32 bytes; got $SPARKLE_PUBLIC_KEY_BYTES." >&2
    exit 1
  fi
  # Prove the signing key matches the app's public key before building.
  if RELEASE_DERIVED_PUB="$(sparkle_ed_public_key_from_file "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY" "$ROOT")"; then
    if [[ "$RELEASE_DERIVED_PUB" != "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" ]]; then
      echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY is NOT the public half of" >&2
      echo "       NATIVEAGENT_SPARKLE_ED_PRIV_KEY. The app would trust a key the" >&2
      echo "       appcast is not signed with, so every update would be rejected." >&2
      echo "         stamped into the app: $NATIVEAGENT_SPARKLE_PUBLIC_KEY" >&2
      echo "         derived from the key: $RELEASE_DERIVED_PUB" >&2
      exit 1
    fi
    echo "==> Sparkle key pair verified (public half of the signing key matches the stamp)."
  else
    echo "ERROR: could not derive the public half of NATIVEAGENT_SPARKLE_ED_PRIV_KEY." >&2
    echo "       Refusing to build a release whose update key pair is unproven." >&2
    exit 1
  fi

  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    PROFILE_PREFLIGHT="$(mktemp "${TMPDIR:-/tmp}/nativeagent-release-profile.XXXXXX")"
    if ! decode_provisioning_profile "$NATIVEAGENT_PROVISIONING_PROFILE" "$PROFILE_PREFLIGHT"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: public CloudKit provisioning profile could not be decoded." >&2
      exit 1
    fi
    if ! verify_public_cloudkit_profile_contract \
      "$PROFILE_PREFLIGHT" \
      "$NATIVEAGENT_TEAM_ID" \
      "$NATIVEAGENT_MAC_BUNDLE_ID" \
      "$NATIVEAGENT_ICLOUD_CONTAINER_ID"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: public CloudKit provisioning profile does not match the release identity." >&2
      exit 1
    fi
    GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS="$(
      mktemp "${TMPDIR:-/tmp}/nativeagent-release-entitlements.XXXXXX"
    )"
    if ! prepare_profile_signing_entitlements \
      "$NATIVEAGENT_RELEASE_ENTITLEMENTS" \
      "$PROFILE_PREFLIGHT" \
      "$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: could not derive the CloudKit signing identity from the validated profile." >&2
      exit 1
    fi
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"
    rm -f "$PROFILE_PREFLIGHT"
    echo "==> Public CloudKit provisioning profile matches the exact team, app, container, and production environments."
    echo "==> CloudKit application/team identifiers derived into the temporary signing entitlements."
  fi
fi

# Signing/product choices are fixed before the compile. The host product is
# explicit and does not require widget provisioning on a maintainer's Mac.
NATIVEAGENT_PRODUCT="${NATIVEAGENT_PRODUCT:-host}"
case "$NATIVEAGENT_PRODUCT" in host|host-with-widget) ;; *) echo 'ERROR: NATIVEAGENT_PRODUCT must be host or host-with-widget' >&2; exit 2 ;; esac
NATIVEAGENT_SIGNING_MODE="${NATIVEAGENT_SIGNING_MODE:-developer-id}"
case "$NATIVEAGENT_SIGNING_MODE" in
  adhoc)
    [[ "$DRY_RUN" == true && "$NATIVEAGENT_PRODUCT" == host ]] || { echo 'ERROR: adhoc release rehearsal requires --dry-run and the host product' >&2; exit 2; }
    NATIVEAGENT_SELECTED_SIGN_IDENTITY=-
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/NativeAgent.adhoc.entitlements"
    ;;
  developer-id)
    NATIVEAGENT_SELECTED_SIGN_IDENTITY="$NATIVEAGENT_DEVELOPER_ID"
    [[ -n "$NATIVEAGENT_SELECTED_SIGN_IDENTITY" && "$NATIVEAGENT_SELECTED_SIGN_IDENTITY" != - ]] || { echo 'ERROR: configure NATIVEAGENT_DEVELOPER_ID for the selected developer-id mode' >&2; exit 1; }
    identities="$(security find-identity -v -p codesigning)"
    awk -F '"' -v identity="$NATIVEAGENT_SELECTED_SIGN_IDENTITY" '$2 == identity && /Developer ID Application/ {found=1} END {exit !found}' <<<"$identities" || { echo 'ERROR: selected Developer ID Application certificate is unavailable' >&2; exit 1; }
    # Local rehearsal has no distribution profile or iCloud grants.
    if [[ "$DRY_RUN" == true ]]; then NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/NativeAgent.public.entitlements"; fi
    ;;
  *) echo 'ERROR: NATIVEAGENT_SIGNING_MODE must be developer-id or adhoc for release.sh' >&2; exit 2 ;;
esac
[[ -r "$NATIVEAGENT_RELEASE_ENTITLEMENTS" ]] || { echo 'ERROR: selected signing entitlements are unreadable' >&2; exit 1; }
plutil -lint "$NATIVEAGENT_RELEASE_ENTITLEMENTS" >/dev/null
mkdir -p "$ROOT/.runtime"
RELEASE_WIDGET_WORK="$(mktemp -d "$ROOT/.runtime/release-product.XXXXXX")"
cp "$NATIVEAGENT_RELEASE_ENTITLEMENTS" "$RELEASE_WIDGET_WORK/base.entitlements"
NATIVEAGENT_RELEASE_ENTITLEMENTS="$RELEASE_WIDGET_WORK/base.entitlements"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$NATIVEAGENT_RELEASE_ENTITLEMENTS" >/dev/null 2>&1 || true
if [[ "$NATIVEAGENT_PRODUCT" == host-with-widget ]]; then
  [[ "$DRY_RUN" == false ]] || { echo 'ERROR: widget release requires distribution provisioning (no dry-run widget product)' >&2; exit 1; }
  for product in host widget; do
    if [[ "$product" == host ]]; then
      profile="$RELEASE_WIDGET_HOST_PROFILE"; bundle_id="$NATIVEAGENT_MAC_BUNDLE_ID"
    else
      profile="$NATIVEAGENT_WIDGET_PROVISIONING_PROFILE"; bundle_id="$NATIVEAGENT_MAC_WIDGET_BUNDLE_ID"
    fi
    plist="$RELEASE_WIDGET_WORK/$product.plist"
    decode_provisioning_profile "$profile" "$plist" "$RELEASE_WIDGET_WORK/$product.provisionprofile"
    verify_profile_identity_contract "$plist" "$bundle_id"
    [[ "$(provisioning_profile_value "$plist" TeamIdentifier:0)" == "$NATIVEAGENT_TEAM_ID" ]] || { echo 'ERROR: widget product profiles must match the release team' >&2; exit 1; }
    [[ "$(provisioning_profile_value "$plist" ProvisionsAllDevices)" == true ]] || { echo 'ERROR: widget product requires all-devices Developer ID profiles' >&2; exit 1; }
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" >/dev/null 2>&1; then echo 'ERROR: widget profile is device-bound' >&2; exit 1; fi
    provisioning_profile_array_contains "$plist" 'Entitlements:com.apple.security.application-groups' "$NATIVEAGENT_MAC_APP_GROUP_ID" || { echo 'ERROR: widget product requires the shared App Group in both profiles' >&2; exit 1; }
  done
  prepare_profile_signing_entitlements "$NATIVEAGENT_RELEASE_ENTITLEMENTS" "$RELEASE_WIDGET_WORK/host.plist" "$RELEASE_WIDGET_WORK/host.entitlements"
  prepare_profile_signing_entitlements "$ROOT/Config/NativeAgentWidget.entitlements" "$RELEASE_WIDGET_WORK/widget.plist" "$RELEASE_WIDGET_WORK/widget.entitlements"
  for plist in "$RELEASE_WIDGET_WORK/host.entitlements" "$RELEASE_WIDGET_WORK/widget.entitlements"; do
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' -c "Add :com.apple.security.application-groups:0 string $NATIVEAGENT_MAC_APP_GROUP_ID" "$plist"
  done
  NATIVEAGENT_RELEASE_ENTITLEMENTS="$RELEASE_WIDGET_WORK/host.entitlements"
  NATIVEAGENT_PROVISIONING_PROFILE="$RELEASE_WIDGET_WORK/host.provisionprofile"
fi

# Required model resources are checked before the compile and again when staged.
nativeagent_require_embedding_model "${NATIVEAGENT_EMBEDDING_MODEL_DIR:-$ROOT/extras/embedding}"
# Verify assembly-declared resources before the build.
echo "==> Verifying assembly-declared source resources..."
"$ROOT/script/verify_release_artifact.sh" --verify-resource-source "$ROOT"

# Xcode owns the bundle, helpers, resource bundles, Sparkle and App Intents.
# Keep signing and symbol archival with the existing release owners below.
# In particular, do not let Xcode strip before release_archive_symbols_and_strip.
echo "==> Building with Xcode (Release configuration)..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen is required; install it with: brew install xcodegen" >&2
  exit 1
fi
ruby "$ROOT/script/sync_build_declarations.rb"
xcodegen --spec "$ROOT/project.yml"
DERIVED_DATA="$ROOT/DerivedData/ReleaseBundle"
BUILD_SOURCE_CONTENT_ID="$(nativeagent_source_content_id "$ROOT")"
xcodebuild -quiet -jobs 6 \
  -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  DEPLOYMENT_POSTPROCESSING=NO STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO \
  NATIVEAGENT_RELEASE_BUILD=YES NATIVEAGENT_STAMP_REPO_PATH=NO \
  NATIVEAGENT_SOURCE_CONTENT_ID="$BUILD_SOURCE_CONTENT_ID" \
  NATIVEAGENT_MAC_BUNDLE_ID="$NATIVEAGENT_MAC_BUNDLE_ID" \
  NATIVEAGENT_MAC_WIDGET_BUNDLE_ID="$NATIVEAGENT_MAC_WIDGET_BUNDLE_ID" \
  NATIVEAGENT_MAC_APP_GROUP_ID="$NATIVEAGENT_MAC_APP_GROUP_ID" \
  NATIVEAGENT_ICLOUD_CONTAINER_ID="$NATIVEAGENT_ICLOUD_CONTAINER_ID" \
  NATIVEAGENT_MOBILE_SOURCE_KEY="$NATIVEAGENT_MOBILE_SOURCE_KEY" \
  NATIVEAGENT_BACKGROUND_TASK_PREFIX="$NATIVEAGENT_BACKGROUND_TASK_PREFIX" \
  NATIVEAGENT_DEVICE_SYNC="$NATIVEAGENT_DEVICE_SYNC" \
  NATIVEAGENT_RELEASE_PAGE_URL="$NATIVEAGENT_RELEASE_PAGE_URL" \
  NATIVEAGENT_BUILD_SHORT_VERSION="$EFFECTIVE_SHORT_VERSION" \
  NATIVEAGENT_SPARKLE_PUBLIC_KEY="$NATIVEAGENT_SPARKLE_PUBLIC_KEY" \
  NATIVEAGENT_UPDATE_FEED_PUBLISHED="$NATIVEAGENT_UPDATE_FEED_PUBLISHED" \
  NATIVEAGENT_SPARKLE_FEED_URL="$SPARKLE_FEED_URL_STAMP" \
  NATIVEAGENT_EMBEDDING_MODEL_DIR=/dev/null \
  build
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ "$(nativeagent_source_content_id "$ROOT")" == "$BUILD_SOURCE_CONTENT_ID" ]] \
  || { echo 'ERROR: source content moved during compilation.' >&2; exit 1; }

# Publishing artifacts start in quarantine so interruption needs no cleanup to keep them unshippable.
# Ship-ready names stay absent until generate_appcast.sh verifies the live feed and DMG.
STAGE_DIR="$ROOT/dist"
mkdir -p "$STAGE_DIR"
QUARANTINE_DIR="$ROOT/dist/.pending-publish"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "==> --publish-appcast: building into $QUARANTINE_DIR until the feed is verified live"
  release_quarantine_init "$QUARANTINE_DIR" "release v$VERSION: appcast publish + live verification pending"
  STAGE_DIR="$QUARANTINE_DIR"
fi

echo "==> Staging $APP_NAME.app..."
BUNDLE="$STAGE_DIR/$APP_NAME.app"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME.app" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME.app.zip" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.dmg" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.dmg.zip" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.test-receipt.json" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.release-attestation.json" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.embedding.zip" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.embedding.json" >/dev/null
  # A stale ship-ready copy from an earlier successful release must not be
  # mistaken for this build's output later on.
  rm -f "$ROOT/dist/$APP_NAME-$VERSION.dmg" \
    "$ROOT/dist/$APP_NAME-$VERSION.dmg.zip" \
    "$ROOT/dist/$APP_NAME-$VERSION.test-receipt.json" \
    "$ROOT/dist/$APP_NAME-$VERSION.embedding.zip" \
    "$ROOT/dist/$APP_NAME-$VERSION.embedding.json" \
    "$ROOT/dist/$APP_NAME-$VERSION.release-attestation.json"
  rm -rf "$ROOT/dist/$APP_NAME.app" "$ROOT/dist/$APP_NAME.app.zip"
fi
rm -rf "$BUNDLE"
ditto "$BUILT_APP" "$BUNDLE"
[[ ! -e "$BUNDLE/Contents/Resources/REPO_PATH" ]] \
  || { echo "ERROR: release bundle contains a REPO_PATH stamp." >&2; exit 1; }
[[ -s "$BUNDLE/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] \
  || { echo "ERROR: Xcode did not produce Metadata.appintents." >&2; exit 1; }

# Apply only the product selected and preflighted before compilation.
if [[ "$NATIVEAGENT_PRODUCT" == host ]]; then
  rm -rf "$BUNDLE/Contents/PlugIns/NativeAgentWidget.appex"
  /usr/libexec/PlistBuddy -c 'Delete :NativeAgentMacAppGroupID' "$BUNDLE/Contents/Info.plist"
else
  widget="$BUNDLE/Contents/PlugIns/NativeAgentWidget.appex"
  [[ -d "$widget" ]] || { echo 'ERROR: selected widget is missing from the built app' >&2; exit 1; }
  cp "$RELEASE_WIDGET_WORK/widget.provisionprofile" "$widget/Contents/embedded.provisionprofile"
  chmod 0644 "$widget/Contents/embedded.provisionprofile"
fi

release_prepare_embedding "$BUNDLE" "$STAGE_DIR" "$VERSION"
export NATIVEAGENT_PUBLISH_MODEL_ASSET=""
if [[ "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" == separate-download ]]; then
  export NATIVEAGENT_PUBLISH_MODEL_ASSET="$STAGE_DIR/$APP_NAME-$VERSION.embedding.zip"
fi

# Require declared source bytes at their assembly destinations before signing.
"$ROOT/script/verify_release_artifact.sh" \
  --verify-resource-bundle "$BUNDLE/Contents/Resources"

# A production artifact may never acquire an exact commit label and then keep
# building after the source changes underneath it. Dry-run remains available
# for dirty development verification; notarized output fails closed.
assert_full_release_source_unchanged

plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null \
  || { echo "ERROR: Xcode Info.plist is malformed." >&2; exit 1; }

# Verify the staged updater claim matches this release's publication mode.
STAMPED_FEED_PUBLISHED="$(/usr/libexec/PlistBuddy -c "Print :NativeAgentUpdateFeedPublished" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
[[ "$STAMPED_FEED_PUBLISHED" == "$NATIVEAGENT_UPDATE_FEED_PUBLISHED" ]] \
  || { echo "ERROR: NativeAgentUpdateFeedPublished stamped '$STAMPED_FEED_PUBLISHED', expected '$NATIVEAGENT_UPDATE_FEED_PUBLISHED'." >&2; exit 1; }
if [[ "$PUBLISH_APPCAST" == "false" ]]; then
  if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "ERROR: SUFeedURL was stamped without --publish-appcast; that is the 404-feed bug." >&2
    exit 1
  fi
fi

# Verify staged versions: Sparkle's CFBundleVersion stays bare; only internal short versions carry a suffix.
STAMPED_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
STAMPED_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
[[ "$STAMPED_BUNDLE_VERSION" == "$VERSION" ]] \
  || { echo "ERROR: CFBundleVersion stamped '$STAMPED_BUNDLE_VERSION', expected the bare '$VERSION'." >&2; exit 1; }
[[ "$STAMPED_SHORT_VERSION" == "$EFFECTIVE_SHORT_VERSION" ]] \
  || { echo "ERROR: CFBundleShortVersionString stamped '$STAMPED_SHORT_VERSION', expected '$EFFECTIVE_SHORT_VERSION'." >&2; exit 1; }
if [[ "$PUBLISH_APPCAST" == "true" && "$STAMPED_SHORT_VERSION" != "$VERSION" ]]; then
  echo "ERROR: a --publish-appcast build carries the internal marker '$STAMPED_SHORT_VERSION'." >&2
  echo "       Published releases stamp the bare version. Refusing." >&2
  exit 1
fi
if [[ -n "$INTERNAL_VERSION_SUFFIX" ]]; then
  echo "==> Internal build: CFBundleShortVersionString=$EFFECTIVE_SHORT_VERSION (CFBundleVersion stays $VERSION)."
fi

if [[ "$DRY_RUN" == "false" ]]; then
  /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$BUNDLE/Contents/Info.plist" >/dev/null
  if [[ "$PUBLISH_APPCAST" == "true" ]]; then
    /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$BUNDLE/Contents/Info.plist" >/dev/null
  fi
elif [[ -z "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" ]]; then
  echo "==> Dry-run warning: NATIVEAGENT_SPARKLE_PUBLIC_KEY is empty; full releases require it."
fi

# Finder drag-installs into /Applications preserve bundle modes from the DMG.
# Source files in this repo can be owner-only (0600), which makes a copied app
# hard for LaunchServices/Gatekeeper to assess from another user and can produce
# the generic "can't be opened because of a problem" dialog. Normalize before
# the leak guard and before signing so the sealed public app is readable and
# executable in the normal macOS app-bundle shape.
echo "==> Normalizing public bundle permissions..."
chmod -R u+rwX,go+rX "$BUNDLE"
chmod -R go-w "$BUNDLE"
nativeagent_assert_no_python_artifacts "$BUNDLE" '[release]' staged release
"$ROOT/script/verify_release_artifact.sh" \
  --verify-no-derived-context-state "$BUNDLE/Contents/Resources"

# Content leaks fail after all staging and before signing.
release_assert_no_leaked_data "$BUNDLE" "$PRODUCT" "$ROOT" || exit 1

# The compiled-binary identity gate requires the maintainer denylist in public
# lanes; the personal lane keeps its own identity. The whole-bundle assertion
# owns recursive store and top-level resource-path exclusion in every lane,
# with the documented CoreML Data exemption.
_gate_rc=0
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "personal" ]]; then
  release_assert_no_identity_strings "$BUNDLE" || _gate_rc=1
else
  echo "[leak-gate] skipped — private 'personal' lane (public lanes always run it)."
fi
release_assert_no_user_state_in_bundle "$BUNDLE" || _gate_rc=1
if [[ "$_gate_rc" -ne 0 ]]; then
  echo "ERROR: release bundle failed the A1.1/A1.5 gates — REFUSING TO SHIP." >&2
  exit 1
fi

# Preserve symbolication privately, then remove local symbols from the shipped
# executable before signing. Public-export children write directly into the
# private controller's ignored .runtime archive via the environment above;
# dSYMs never enter the app, DMG, appcast, or GitHub release payload.
RELEASE_SYMBOL_ARCHIVE_DIR="${NATIVEAGENT_RELEASE_SYMBOL_ARCHIVE_DIR:-$ROOT/.runtime/release-symbols/$VERSION/$NATIVEAGENT_SOURCE_REVISION}"
echo "==> Archiving dSYM and stripping local executable symbols..."
release_archive_symbols_and_strip \
  "$BUNDLE/Contents/MacOS/$PRODUCT" \
  "$RELEASE_SYMBOL_ARCHIVE_DIR" \
  "$PRODUCT"

echo "==> Codesigning..."
sign_nested_plain() {
  local identity="$1"
  local timestamp_arg="${2:---timestamp}"
  if [[ -d "$BUNDLE/Contents/PlugIns/NativeAgentWidget.appex" ]]; then
    codesign --force --sign "$identity" --options runtime "$timestamp_arg" \
      --generate-entitlement-der --entitlements "$RELEASE_WIDGET_WORK/widget.entitlements" \
      "$BUNDLE/Contents/PlugIns/NativeAgentWidget.appex"
  fi
  codesign --force --sign "$identity" --identifier nativeagent-link \
    --options runtime "$timestamp_arg" "$BUNDLE/Contents/MacOS/nativeagent-link"
  codesign --force --sign "$identity" --identifier NativeAgentChromeRelay \
    --options runtime "$timestamp_arg" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
  codesign --force --sign "$identity" --identifier NativeAgentSenseHost \
    --options runtime "$timestamp_arg" --entitlements "$ROOT/Config/NativeAgentSenseHost.entitlements" \
    "$BUNDLE/Contents/MacOS/NativeAgentSenseHost"
  if [[ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --sign "$identity" --options runtime $timestamp_arg \
      "$BUNDLE/Contents/Frameworks/Sparkle.framework"
  fi
}
if [[ "$DRY_RUN" == "true" ]]; then
  SIGN_ID="$NATIVEAGENT_SELECTED_SIGN_IDENTITY"
  DRY_RUN_ENTITLEMENTS="$NATIVEAGENT_RELEASE_ENTITLEMENTS"
  if [[ ! -f "$DRY_RUN_ENTITLEMENTS" ]]; then
    echo "ERROR: $DRY_RUN_ENTITLEMENTS not found; dry-run signing must use ad-hoc entitlements." >&2
    exit 1
  fi
  sign_nested_plain "$SIGN_ID" "--timestamp=none"
  codesign --sign "$SIGN_ID" \
    --options runtime \
    --generate-entitlement-der \
    --entitlements "$DRY_RUN_ENTITLEMENTS" \
    --force \
    "$BUNDLE"
  echo "==> Dry-run complete. Signed app at: $BUNDLE"
  echo "==> Skipping notarization (--dry-run)."
  exit 0
fi

# Full production sign with timestamp
if [[ -n "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
  if [[ ! -f "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
    echo "ERROR: NATIVEAGENT_PROVISIONING_PROFILE does not exist: $NATIVEAGENT_PROVISIONING_PROFILE" >&2
    exit 1
  fi
  cp "$NATIVEAGENT_PROVISIONING_PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
  # Maintainer profiles are intentionally owner-readable on disk. The embedded
  # copy is public signing metadata and must remain readable to normal users;
  # copying it after the bundle-wide permission pass would otherwise preserve
  # mode 0600 and make the packaged app fail the release/launch boundary.
  chmod 0644 "$BUNDLE/Contents/embedded.provisionprofile"
fi
sign_nested_plain "$NATIVEAGENT_DEVELOPER_ID" "--timestamp"
echo "[release] signing with entitlements: $NATIVEAGENT_RELEASE_ENTITLEMENTS (iCloud build=$NATIVEAGENT_ICLOUD_BUILD)"
codesign --sign "$NATIVEAGENT_DEVELOPER_ID" \
  --options runtime \
  --generate-entitlement-der \
  --entitlements "$NATIVEAGENT_RELEASE_ENTITLEMENTS" \
  --force --timestamp \
  "$BUNDLE"

echo "==> Creating notarization zip..."
rm -f "$STAGE_DIR/$APP_NAME.app.zip"
ditto -c -k --keepParent "$BUNDLE" "$STAGE_DIR/$APP_NAME.app.zip"

# Notary auth: keychain profile (secret stays in keychain) or apple-id/password.
if [[ -n "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" ]]; then
  NOTARY_AUTH=( --keychain-profile "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" )
else
  NOTARY_AUTH=( --apple-id "$NATIVEAGENT_APPLE_ID" --password "$NATIVEAGENT_NOTARIZATION_PASSWORD" --team-id "$NATIVEAGENT_TEAM_ID" )
fi

echo "==> Submitting for notarization (this may take several minutes)..."
xcrun notarytool submit "$STAGE_DIR/$APP_NAME.app.zip" \
  "${NOTARY_AUTH[@]}" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$BUNDLE"

echo "==> Verifying..."
spctl -a -vvv -t execute "$BUNDLE"
stapler validate "$BUNDLE"

echo "==> Building DMG..."
NATIVEAGENT_DMG_BUNDLE="$BUNDLE" NATIVEAGENT_DMG_OUT_DIR="$STAGE_DIR" \
  "$ROOT/script/dmg_builder.sh"

DMG_PATH="$STAGE_DIR/$APP_NAME-$VERSION.dmg"

# An unsigned DMG supports older macOS and cannot be stapled; its mounted app still needs a valid ticket.
if [[ "${NATIVEAGENT_SKIP_DMG_SIGN:-0}" == "1" ]]; then
  echo "==> Unsigned DMG (NATIVEAGENT_SKIP_DMG_SIGN=1) — skipping DMG notarize/staple."
  "$ROOT/script/verify_release_artifact.sh" \
    --dmg "$DMG_PATH" \
    --require-clean-source \
    --require-notarized \
    --require-sparkle-key
else
  echo "==> Notarizing DMG..."
  rm -f "$DMG_PATH.zip"
  ditto -c -k --keepParent "$DMG_PATH" "$DMG_PATH.zip"
  xcrun notarytool submit "$DMG_PATH.zip" \
    "${NOTARY_AUTH[@]}" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  stapler validate "$DMG_PATH"

  echo "==> Verifying final notarized release artifact..."
  "$ROOT/script/verify_release_artifact.sh" \
    --dmg "$DMG_PATH" \
    --require-clean-source \
    --require-dmg-signature \
    --require-notarized \
    --require-sparkle-key
fi

# The named artifact gate has passed on the final bytes. Its only completion
# record is published atomically beside that artifact, never before the gate.
assert_full_release_source_unchanged
STAGED_TEST_RECEIPT="$STAGE_DIR/$APP_NAME-$VERSION.test-receipt.json"
receipt_tmp="$STAGED_TEST_RECEIPT.tmp.$$"
jq -n --arg revision "$NATIVEAGENT_SOURCE_REVISION" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg name "$(basename "$DMG_PATH")" \
  --arg sha256 "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')" \
  --argjson bytes "$(stat -f %z "$DMG_PATH")" \
  '{schema_version:1, source_revision:$revision, source_dirty:false,
    canonical_gate:"script/release.sh --artifact-only", ios_required:false,
    ios_result:"not_run", completed_at:$completed_at,
    artifact:{name:$name, sha256:$sha256, byte_length:$bytes}}' > "$receipt_tmp"
if [[ -n "$NATIVEAGENT_PUBLISH_MODEL_ASSET" ]]; then
  jq --slurpfile model "$STAGE_DIR/$APP_NAME-$VERSION.embedding.json" \
    '. + {model_asset:$model[0]}' "$receipt_tmp" > "$receipt_tmp.model"
  mv "$receipt_tmp.model" "$receipt_tmp"
fi
chmod 0644 "$receipt_tmp"
mv -f "$receipt_tmp" "$STAGED_TEST_RECEIPT"
RELEASE_ATTESTATION="$STAGE_DIR/$APP_NAME-$VERSION.release-attestation.json"
if [[ "${NATIVEAGENT_SKIP_DMG_SIGN:-0}" == "1" ]]; then
  DMG_SIGNATURE_REQUIRED=false
  DMG_NOTARIZED=false
  DMG_STAPLED=false
else
  DMG_SIGNATURE_REQUIRED=true
  DMG_NOTARIZED=true
  DMG_STAPLED=true
fi
"$ROOT/script/create_release_attestation.sh" \
  --dmg "$DMG_PATH" \
  --test-receipt "$STAGED_TEST_RECEIPT" \
  --source-revision "$NATIVEAGENT_SOURCE_REVISION" \
  --version "$VERSION" \
  --short-version "$EFFECTIVE_SHORT_VERSION" \
  --dmg-signature-required "$DMG_SIGNATURE_REQUIRED" \
  --dmg-notarized "$DMG_NOTARIZED" \
  --dmg-stapled "$DMG_STAPLED" \
  --out "$RELEASE_ATTESTATION"
if [[ -n "$NATIVEAGENT_PUBLISH_MODEL_ASSET" ]]; then
  jq --slurpfile model "$STAGE_DIR/$APP_NAME-$VERSION.embedding.json" \
    '. + {model_asset:$model[0]}' "$RELEASE_ATTESTATION" > "$RELEASE_ATTESTATION.tmp"
  mv -f "$RELEASE_ATTESTATION.tmp" "$RELEASE_ATTESTATION"
fi
export NATIVEAGENT_PUBLISH_ATTESTATION="$RELEASE_ATTESTATION"
export NATIVEAGENT_PUBLISH_TEST_RECEIPT="$STAGED_TEST_RECEIPT"

# Sign the appcast after notarizing and stapling so it covers the final download bytes.
if [[ "$GENERATE_APPCAST" == "true" ]]; then
  APPCAST_ARGS=( --dmg "$DMG_PATH" --version "$VERSION" )
  if [[ -z "$RELEASE_NOTES_FILE" && -f "$ROOT/docs/release-notes/$VERSION.md" ]]; then
    RELEASE_NOTES_FILE="$ROOT/docs/release-notes/$VERSION.md"
    echo "==> Release notes: $RELEASE_NOTES_FILE (conventional path)"
  fi
  if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    APPCAST_ARGS+=( --notes "$RELEASE_NOTES_FILE" )
    # The GitHub release body gets the same text as the Sparkle dialog.
    export NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE="$RELEASE_NOTES_FILE"
  else
    echo "==> Release notes: none supplied (--notes FILE or docs/release-notes/$VERSION.md);"
    echo "    the Sparkle update dialog for this build will have no description."
  fi
  if [[ "$PUBLISH_APPCAST" == "true" ]]; then
    APPCAST_ARGS+=( --publish )
  else
    # Rehearsal: the app in this DMG deliberately carries no feed URL, so the
    # bundle<->feed cross-checks cannot apply. Every signature, version, URL and
    # length guard still runs — this proves the key and pipeline work.
    APPCAST_ARGS+=( --rehearsal )
  fi
  echo "==> Sparkle appcast (publish=$PUBLISH_APPCAST)"
  "$ROOT/script/generate_appcast.sh" "${APPCAST_ARGS[@]}"
fi

if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "==> Feed verified live — promoting artifacts out of quarantine into dist/"
  release_quarantine_promote "$QUARANTINE_DIR" "$ROOT/dist"
  DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"
  BUNDLE="$ROOT/dist/$APP_NAME.app"
  [[ -f "$DMG_PATH" ]] \
    || { echo "ERROR: promotion did not land $DMG_PATH; artifacts remain in $QUARANTINE_DIR." >&2; exit 1; }
fi

# The cross-user DMG copy is best-effort; failure cannot abort a completed release.
SHARED_DMG="/Users/Shared/$APP_NAME-$VERSION-local-test.dmg"
echo "==> Refreshing shared DMG for cross-user install: $SHARED_DMG"
if cp -f "$DMG_PATH" "$SHARED_DMG"; then
  chmod 644 "$SHARED_DMG" 2>/dev/null || true
  echo "    Shared DMG updated."
else
  echo "    WARNING: could not write $SHARED_DMG (release itself still succeeded)." >&2
fi

echo "==> Exact-commit artifact receipt: $ROOT/dist/$APP_NAME-$VERSION.test-receipt.json"

echo ""
echo "==> Release v$VERSION complete!"
echo "    App:  $BUNDLE"
echo "    DMG:  $DMG_PATH"
echo "    Shared (cross-user install): $SHARED_DMG"
echo ""
echo "Next steps:"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "  Feed published AND verified live: $NATIVEAGENT_APPCAST_URL"
  echo "  1. Nothing to upload: the DMG at $NATIVEAGENT_DMG_DOWNLOAD_URL was fetched"
  echo "     and its length matched this artifact before the release was released."
  echo "  2. Verify from a previous version: install the older build, then use"
  echo "     Check for Updates… and confirm it offers $VERSION."
elif [[ "$GENERATE_APPCAST" == "true" ]]; then
  echo "  Rehearsal only: dist/appcast/appcast.xml was generated + signed, NOT uploaded,"
  echo "  and this app carries NO feed URL (its updater is honestly disabled)."
  echo "  Do NOT hand-upload this feed — the app it describes cannot read it."
  echo "  Re-run with --publish-appcast to ship a build whose updater is enabled."
else
  echo "  1. Upload $APP_NAME-$VERSION.dmg to your release hosting"
  echo "  2. This build ships with the updater honestly disabled (no feed URL)."
  echo "     To ship a self-updating build, re-run with --publish-appcast after"
  echo "     setting NATIVEAGENT_APPCAST_URL and NATIVEAGENT_DMG_DOWNLOAD_URL."
fi
