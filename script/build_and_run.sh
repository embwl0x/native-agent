#!/usr/bin/env bash
set -euo pipefail
# Report the failing command and line.
trap 'echo "[build_and_run.sh] FAILED line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/development_bundle_signing.sh
source "$ROOT/script/lib/development_bundle_signing.sh"
source "$ROOT/script/lib/development_bundle_validation.sh"
source "$ROOT/script/lib/build_source_inventory.sh"
source "$ROOT/script/lib/embedding_model_contract.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
APP_LOG="$ROOT/.runtime/nativeagent-app.log"
# Modes: (default) build+sign+launch ·
# --logs launch+tail · --build-only build+sign ONLY (no kill, no launch —
# install_app.sh uses this so the running app stays untouched until the new
# bundle is fully proven).
FORCE_CHECKOUT_SWITCH=0
MODE=""
for arg in "$@"; do
  case "$arg" in
    --force-checkout-switch)
      FORCE_CHECKOUT_SWITCH=1
      ;;
    --logs|--build-only)
      if [[ -n "$MODE" ]]; then
        echo "[build_and_run.sh] ERROR: too many arguments: $*" >&2
        echo "Usage: ./script/build_and_run.sh [--logs|--build-only] [--force-checkout-switch]" >&2
        exit 2
      fi
      MODE="$arg"
      ;;
    *)
      # Fail loud on typos: an unknown flag must not silently fall through to
      # the default kill+launch path (--build-only is a downtime-safety mode).
      echo "[build_and_run.sh] ERROR: unknown argument: $arg" >&2
      echo "Usage: ./script/build_and_run.sh [--logs|--build-only] [--force-checkout-switch]" >&2
      exit 2
      ;;
  esac
done

# Build-only never moves the live app, so it is exempt from the shared checkout guard.
INSTALLED_APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
if [[ "$MODE" != "--build-only" ]]; then
  nativeagent_require_installed_checkout "$INSTALLED_APP_BUNDLE" "$ROOT" "$FORCE_CHECKOUT_SWITCH" \
    "[build_and_run.sh]" "Kill+launch from here would bounce the live app and repoint its data root."
fi

# A Codex/agent workspace sandbox cannot register an AppKit process. Launching
# dist/NativeAgent.app there aborts in _RegisterApplication and macOS later
# shows User a misleading "quit unexpectedly" dialog even though the installed
# app never stopped. Codex may build the dist bundle, and install_app.sh uses
# --build-only before launching the installed copy outside this path.
if [[ "${CODEX_SHELL:-0}" == "1" && "$MODE" != "--build-only" ]]; then
  echo "[build_and_run.sh] refusing GUI launch mode '${MODE:-default}' from a Codex shell." >&2
  echo "[build_and_run.sh] Use ./script/install_app.sh, then verify ~/Applications/NativeAgent.app through the authenticated bridge." >&2
  exit 2
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[build_and_run.sh] ERROR: xcodegen is required; install it with: brew install xcodegen" >&2
  exit 1
fi
# Turn upgrades consume the committed table; regeneration is a maintainer step.
ruby "$ROOT/script/sync_build_declarations.rb"
xcodegen --spec "$ROOT/project.yml"

LOCAL_ENV="$ROOT/local/nativeagent.local.env"
if [[ -f "$LOCAL_ENV" ]]; then
  # Local Apple/iCloud identifiers are intentionally gitignored.
  # shellcheck source=/dev/null
  source "$LOCAL_ENV"
fi
NATIVEAGENT_MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"
NATIVEAGENT_ICLOUD_CONTAINER_ID="${NATIVEAGENT_ICLOUD_CONTAINER_ID:-iCloud.io.github.embwl0x.nativeagent}"
NATIVEAGENT_MOBILE_SOURCE_KEY="${NATIVEAGENT_MOBILE_SOURCE_KEY:-mobile_app}"
NATIVEAGENT_BACKGROUND_TASK_PREFIX="${NATIVEAGENT_BACKGROUND_TASK_PREFIX:-io.github.embwl0x.nativeagent}"
NATIVEAGENT_DEVICE_SYNC="${NATIVEAGENT_DEVICE_SYNC:-cloudkit}"
NATIVEAGENT_RELEASE_PAGE_URL="${NATIVEAGENT_RELEASE_PAGE_URL:-https://github.com/embwl0x/native-agent/releases}"

# Select the product and signing contract before the one compile. The ordinary
# local product is the host app; embedding a widget is an explicit selection.
trap '[[ -z "${NATIVEAGENT_SIGNING_WORK:-}" ]] || rm -rf "$NATIVEAGENT_SIGNING_WORK"' EXIT
nativeagent_prepare_development_signing "$ROOT" "$NATIVEAGENT_MAC_BUNDLE_ID" "[sign]"

mkdir -p "$ROOT/.runtime" "$ROOT/dist"

# bge-large-en-v1.5 is the one embedding model. It is too big for git,
# so the build copies it from
# extras/embedding/ in the checkout (gitignored; embedding.json + the model +
# vocab it names) into Contents/Resources/embedding/. The runtime re-embeds
# an older vector space through the existing epoch mechanism.
EMBEDDING_MODEL_DIR="${NATIVEAGENT_EMBEDDING_MODEL_DIR:-$ROOT/extras/embedding}"
case "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" in
  separate-download) EMBEDDING_MODEL_DIR=/dev/null ;;
  bundled) ;;
  *) echo '[build_and_run.sh] ERROR: embedding distribution must be separate-download or bundled' >&2; exit 2 ;;
esac
# Bundled builds require their own complete model, independent of a user's
# mutable data root. The assembly owner validates the manifest and resources.
if [[ "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" == bundled && ! -f "$EMBEDDING_MODEL_DIR/embedding.json" ]]; then
  NATIVEAGENT_EMBEDDING_MODEL_DIR="$EMBEDDING_MODEL_DIR" "$ROOT/script/fetch_embedding_model.sh"
fi
if [[ "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" == bundled ]]; then
  nativeagent_require_embedding_model "$EMBEDDING_MODEL_DIR"
else
  [[ -r "${NATIVEAGENT_EMBEDDING_DOWNLOAD_MANIFEST:-}" ]] || {
    echo '[embedding] separate-download requires NATIVEAGENT_EMBEDDING_DOWNLOAD_MANIFEST' >&2; exit 1;
  }
fi

# NATIVEAGENT_BUILD_CONFIG=release installs an optimized binary (the speed of the
# DMG) for day-to-day use on a development install; default stays debug.
case "${NATIVEAGENT_BUILD_CONFIG:-debug}" in
  debug) XCODE_CONFIG=Debug ;;
  release) XCODE_CONFIG=Release ;;
  *)
    echo "[build_and_run.sh] ERROR: NATIVEAGENT_BUILD_CONFIG must be debug or release" >&2
    exit 2
    ;;
esac

# The bundle is Xcode's (project.yml): Info.plist, resources, the Chrome
# payload, helpers in Contents/MacOS, Sparkle in Contents/Frameworks and the
# generated Metadata.appintents. Its stamp phase writes VERSION, the source
# identity and, for this dev path only, REPO_PATH. The local identity
# overrides reach it as build settings (they outrank the xcconfig defaults).
# Xcode does not sign here: nativeagent_sign_development_bundle below is the
# one signing owner, so local/NativeAgent.xcconfig signing settings and
# the selected signing mode cannot disagree with it.
# Development builds consume the reviewed dependency pins; deliberate updates
# belong in an explicit package-update workflow. The running app is not
# touched until the POINT OF NO RETURN below (DOWNTIME GUARD 2026-07-02).
DERIVED_DATA="$ROOT/DerivedData"
BUILD_SOURCE_CONTENT_ID="$(nativeagent_source_content_id "$ROOT")"
xcodebuild -quiet \
  -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$XCODE_CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  NATIVEAGENT_MAC_BUNDLE_ID="$NATIVEAGENT_MAC_BUNDLE_ID" \
  NATIVEAGENT_MAC_WIDGET_BUNDLE_ID="${NATIVEAGENT_MAC_WIDGET_BUNDLE_ID:-$NATIVEAGENT_MAC_BUNDLE_ID.widget}" \
  NATIVEAGENT_MAC_APP_GROUP_ID="${NATIVEAGENT_MAC_APP_GROUP_ID:-group.$NATIVEAGENT_MAC_BUNDLE_ID}" \
  NATIVEAGENT_ICLOUD_CONTAINER_ID="$NATIVEAGENT_ICLOUD_CONTAINER_ID" \
  NATIVEAGENT_MOBILE_SOURCE_KEY="$NATIVEAGENT_MOBILE_SOURCE_KEY" \
  NATIVEAGENT_BACKGROUND_TASK_PREFIX="$NATIVEAGENT_BACKGROUND_TASK_PREFIX" \
  NATIVEAGENT_DEVICE_SYNC="$NATIVEAGENT_DEVICE_SYNC" \
  NATIVEAGENT_RELEASE_PAGE_URL="$NATIVEAGENT_RELEASE_PAGE_URL" \
  NATIVEAGENT_EMBEDDING_MODEL_DIR="$EMBEDDING_MODEL_DIR" \
  NATIVEAGENT_EMBEDDING_DISTRIBUTION="${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" \
  NATIVEAGENT_EMBEDDING_DOWNLOAD_MANIFEST="${NATIVEAGENT_EMBEDDING_DOWNLOAD_MANIFEST:-}" \
  NATIVEAGENT_STAMP_REPO_PATH=YES \
  NATIVEAGENT_SOURCE_CONTENT_ID="$BUILD_SOURCE_CONTENT_ID" \
  build
BUILT_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/$APP_NAME.app"
[[ "$(nativeagent_source_content_id "$ROOT")" == "$BUILD_SOURCE_CONTENT_ID" ]] \
  || { echo '[build_and_run.sh] ERROR: source content moved during compilation.' >&2; exit 1; }

# Stage + sign into a TEMP bundle and only swap it into dist/NativeAgent.app
# after the shared signing owner passes deep verification. Every fallible step
# (provisioning checks, codesign, verification) therefore runs while the
# previous dist bundle — and the running app — are still intact; a failure
# anywhere exits nonzero with nothing killed and nothing half-replaced.
BUNDLE_FINAL="$ROOT/dist/$APP_NAME.app"
APP_PROCESS_PATTERN="$(printf '%s' "$BUNDLE_FINAL/Contents/MacOS/$PRODUCT" | sed 's/[][\.^$*+?(){}|]/\\&/g')([[:space:]].*)?"
BUNDLE="$ROOT/dist/.$APP_NAME.app.staging.$$"
rm -rf "$BUNDLE"
# Sweep the staging dir on any exit; cleared after the swap below (once the
# mv lands, $BUNDLE is reassigned to the final path — this trap must be gone
# by then or it would delete the freshly installed bundle).
trap 'rm -rf "$ROOT/dist/.$APP_NAME.app.staging.$$" "$NATIVEAGENT_SIGNING_WORK"' EXIT
ditto "$BUILT_APP" "$BUNDLE"
if [[ -d "$BUNDLE/Contents/Resources/embedding" ]]; then
  echo "[embedding] staged $(basename "$EMBEDDING_MODEL_DIR") ($(du -sh "$BUNDLE/Contents/Resources/embedding" | cut -f1))"
fi
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true

nativeagent_assert_no_python_artifacts "$BUNDLE" "[swift-native]" staged app

# Sign the finished development bundle before either launch or installation.
nativeagent_sign_development_bundle "$BUNDLE" "$ROOT" "$NATIVEAGENT_MAC_BUNDLE_ID" "[sign]"
rm -rf "$NATIVEAGENT_SIGNING_WORK"

# ─── POINT OF NO RETURN ─────────────────────────────────────────────────────
# The staged bundle is built, signed, and codesign-verified. Only now do we
# kill the running app (never in --build-only) and swap dist/NativeAgent.app.
if [[ "$MODE" != "--build-only" ]]; then
  # Match the app's duplicate-instance rule: same bundle ID, current login session.
  staged_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")"
  matching_app_pids="$(/usr/bin/osascript -l JavaScript - "$staged_bundle_id" <<'JAVASCRIPT'
ObjC.import('AppKit');
function run(argv) {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
  const pids = [];
  for (let i = 0; i < apps.count; i++) {
    const app = apps.objectAtIndex(i);
    if (!app.isTerminated) pids.push(app.processIdentifier);
  }
  return pids.join('\n');
}
JAVASCRIPT
)"
  for app_pid in $matching_app_pids; do
    if ! pgrep -fx "$APP_PROCESS_PATTERN" | grep -qx "$app_pid"; then
      echo "[build_and_run.sh] ERROR: $PRODUCT (pid $app_pid) is running outside $BUNDLE_FINAL." >&2
      echo "[build_and_run.sh] Use ./script/install_app.sh to replace the installed app." >&2
      exit 1
    fi
  done
  # A running dist-launched instance must not have its bundle swapped
  # underneath it, and the launch below needs the old instance gone.
  # Skipped in --build-only: install_app.sh verifies its transferred copy
  # before quitting the app.
  pkill -fx "$APP_PROCESS_PATTERN" 2>/dev/null || true
  # Wait (up to ~5s) for the app to exit before touching the bundle, then
  # hard-kill any survivor.
  for _ in $(seq 1 25); do
    if pgrep -fx "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
      sleep 0.2
    else
      break
    fi
  done
  pkill -9 -fx "$APP_PROCESS_PATTERN" 2>/dev/null || true
fi

# Retain the prior artifact until the selected bundle lands. A failed move
# reports both paths for forward repair; it never restores a prior version.
BUNDLE_OLD="$BUNDLE_FINAL.old.$$"
rm -rf "$BUNDLE_OLD"
trap '
  echo "[build_and_run.sh] incomplete promotion: selected staging bundle at $BUNDLE; previous artifact at $BUNDLE_OLD" >&2
' EXIT
if [[ -d "$BUNDLE_FINAL" ]]; then
  mv "$BUNDLE_FINAL" "$BUNDLE_OLD"
fi
mv "$BUNDLE" "$BUNDLE_FINAL"
trap - EXIT
rm -rf "$BUNDLE_OLD"
BUNDLE="$BUNDLE_FINAL"

case "$MODE" in
  --build-only)
    # install_app.sh path: bundle is built, signed, and codesign-verified;
    # no process was killed and nothing is launched. The installer owns the
    # quit → swap → relaunch sequence after proving its own signed copy.
    echo "Built + signed $BUNDLE (--build-only: no kill, no launch)"
    ;;
  --logs)
    /usr/bin/open -n "$BUNDLE"
    tail -f "$APP_LOG"
    ;;
  *)
    /usr/bin/open -n "$BUNDLE"
    echo "Launched $BUNDLE"
    echo "App log: $APP_LOG"
    ;;
esac
