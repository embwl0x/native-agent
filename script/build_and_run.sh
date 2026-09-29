#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/development_bundle_signing.sh
source "$ROOT/script/lib/development_bundle_signing.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
APP_LOG="$ROOT/.runtime/nativeagent-app.log"
# Modes: (default) build+sign+launch · --verify build+sign+test-launch+quit ·
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
    --verify|--logs|--build-only)
      if [[ -n "$MODE" ]]; then
        echo "[build_and_run.sh] ERROR: too many arguments: $*" >&2
        echo "Usage: ./script/build_and_run.sh [--verify|--logs|--build-only] [--force-checkout-switch]" >&2
        exit 2
      fi
      MODE="$arg"
      ;;
    *)
      # Fail loud on typos: an unknown flag must not silently fall through to
      # the default kill+launch path (--build-only is a downtime-safety mode).
      echo "[build_and_run.sh] ERROR: unknown argument: $arg" >&2
      echo "Usage: ./script/build_and_run.sh [--verify|--logs|--build-only] [--force-checkout-switch]" >&2
      exit 2
      ;;
  esac
done

# 2026-07-21 audit: checkout-identity guard. The installed app's
# Resources/REPO_PATH stamp names the checkout its data-root resolution points
# at. A kill+launch mode run from a DIFFERENT live clone/worktree would bounce
# the running app and hand it a bundle stamped with this checkout's data root.
# Refuse unless --force-checkout-switch; a stamp naming a deleted checkout is
# not a conflict. --build-only never kills or launches (worktree builds and
# install_app.sh rely on that), so it is exempt.
INSTALLED_APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
if [[ "$MODE" != "--build-only" && "$FORCE_CHECKOUT_SWITCH" != "1" && -f "$INSTALLED_APP_BUNDLE/Contents/Resources/REPO_PATH" ]]; then
  installed_repo_path="$(head -n 1 "$INSTALLED_APP_BUNDLE/Contents/Resources/REPO_PATH")"
  if [[ -n "$installed_repo_path" && -d "$installed_repo_path" ]]; then
    installed_repo_resolved="$(cd "$installed_repo_path" 2>/dev/null && pwd -P || true)"
    root_resolved="$(cd "$ROOT" && pwd -P)"
    if [[ -n "$installed_repo_resolved" && "$installed_repo_resolved" != "$root_resolved" ]]; then
      echo "[build_and_run.sh] ERROR: the installed app belongs to a different checkout:" >&2
      echo "  installed: $installed_repo_resolved" >&2
      echo "  this run : $root_resolved" >&2
      echo "Kill+launch from here would bounce the live app and repoint its data root." >&2
      echo "Pass --force-checkout-switch to switch the installed app to this checkout." >&2
      exit 2
    fi
  fi
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
NATIVEAGENT_RELEASE_PAGE_URL="${NATIVE_AGENT_RELEASE_PAGE_URL:-${NATIVEAGENT_RELEASE_PAGE_URL:-https://github.com/embwl0x/native-agent/releases}}"

mkdir -p "$ROOT/.runtime" "$ROOT/dist"

# Large embedding model (2026-09-05). The bundled MiniLM is the floor; a
# stronger model is too big for git, so the build copies it from
# extras/embedding/ in the checkout (gitignored; embedding.json + the model +
# vocab it names) into Contents/Resources/embedding/. The runtime prefers it
# over MiniLM and re-embeds the store on first launch.
EMBEDDING_MODEL_DIR="${NATIVEAGENT_EMBEDDING_MODEL_DIR:-$ROOT/extras/embedding}"
# This dev bundle's data root is $ROOT/data (REPO_PATH stamp). A model already
# installed there (data/extras/coreml) outranks any bundle copy at runtime, so
# a second 600+ MB copy in the bundle would never load: leave it out. Same
# manifest as the one the bundle would carry = the runtime validates both
# alike, so the copy could never win. (A launch with NATIVE_AGENT_DATA_ROOT
# elsewhere reads that root's extras.)
DATA_MODEL_DIR="$ROOT/data/extras/coreml"
data_model_file() { plutil -extract "$1" raw -o - "$DATA_MODEL_DIR/embedding.json" 2>/dev/null; }
if [[ -z "${NATIVEAGENT_EMBEDDING_MODEL_DIR:-}" ]] &&
   cmp -s "$DATA_MODEL_DIR/embedding.json" "$EMBEDDING_MODEL_DIR/embedding.json" &&
   model_file="$(data_model_file model)" && vocab_file="$(data_model_file vocab)" &&
   [[ -n "$model_file" && -e "$DATA_MODEL_DIR/$model_file" && ! -L "$DATA_MODEL_DIR/$model_file" &&
      -n "$vocab_file" && -f "$DATA_MODEL_DIR/$vocab_file" && ! -L "$DATA_MODEL_DIR/$vocab_file" ]]; then
  echo "[embedding] data/extras/coreml holds the model this install loads; not copying it into the bundle"
  EMBEDDING_MODEL_DIR=/dev/null
# First build on a fresh checkout: fetch the model from the repository's model
# release unless told not to. A failed fetch is not fatal; MiniLM remains.
elif [[ ! -f "$EMBEDDING_MODEL_DIR/embedding.json" && "${NATIVEAGENT_SKIP_EMBEDDING_FETCH:-0}" != "1" ]]; then
  "$ROOT/script/fetch_embedding_model.sh" || echo "[embedding] fetch failed; building with the bundled MiniLM"
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

# S13b: the bundle is Xcode's (project.yml): Info.plist, resources, the Chrome
# payload, helpers in Contents/MacOS, Sparkle in Contents/Frameworks and the
# generated Metadata.appintents. Its stamp phase writes VERSION, the source
# identity and, for this dev path only, REPO_PATH. The local identity
# overrides reach it as build settings (they outrank the xcconfig defaults).
# Xcode does not sign here: nativeagent_sign_development_bundle below is the
# one signing owner, so local/NativeAgent.xcconfig signing settings and
# NATIVE_AGENT_ADHOC cannot disagree with it.
# Development builds consume the reviewed dependency pins; deliberate updates
# belong in an explicit package-update workflow. The running app is not
# touched until the POINT OF NO RETURN below (DOWNTIME GUARD 2026-07-02).
DERIVED_DATA="$ROOT/DerivedData"
xcodebuild -quiet \
  -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$XCODE_CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  NATIVEAGENT_MAC_BUNDLE_ID="$NATIVEAGENT_MAC_BUNDLE_ID" \
  NATIVEAGENT_ICLOUD_CONTAINER_ID="$NATIVEAGENT_ICLOUD_CONTAINER_ID" \
  NATIVEAGENT_MOBILE_SOURCE_KEY="$NATIVEAGENT_MOBILE_SOURCE_KEY" \
  NATIVEAGENT_BACKGROUND_TASK_PREFIX="$NATIVEAGENT_BACKGROUND_TASK_PREFIX" \
  NATIVEAGENT_DEVICE_SYNC="$NATIVEAGENT_DEVICE_SYNC" \
  NATIVEAGENT_RELEASE_PAGE_URL="$NATIVEAGENT_RELEASE_PAGE_URL" \
  NATIVEAGENT_EMBEDDING_MODEL_DIR="$EMBEDDING_MODEL_DIR" \
  NATIVEAGENT_STAMP_REPO_PATH=YES \
  build
BUILT_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/$APP_NAME.app"

# Stage + sign into a TEMP bundle and only swap it into dist/NativeAgent.app
# after the shared signing owner passes deep verification. Every fallible step
# (provisioning checks, codesign, verification) therefore runs while the
# previous dist bundle — and the running app — are still intact; a failure
# anywhere exits nonzero with nothing killed and nothing half-replaced.
BUNDLE_FINAL="$ROOT/dist/$APP_NAME.app"
BUNDLE="$ROOT/dist/.$APP_NAME.app.staging.$$"
rm -rf "$BUNDLE"
# Sweep the staging dir on any exit; cleared after the swap below (once the
# mv lands, $BUNDLE is reassigned to the final path — this trap must be gone
# by then or it would delete the freshly installed bundle).
trap 'rm -rf "$ROOT/dist/.$APP_NAME.app.staging.$$"' EXIT
ditto "$BUILT_APP" "$BUNDLE"
if [[ -d "$BUNDLE/Contents/Resources/embedding" ]]; then
  echo "[embedding] staged $(basename "$EMBEDDING_MODEL_DIR") ($(du -sh "$BUNDLE/Contents/Resources/embedding" | cut -f1))"
fi

assert_no_python_artifacts() {
  local bundle="$1" hit
  hit="$(find "$bundle/Contents/Resources" \
    \( -type d \( -name python -o -name __pycache__ \) \
       -o -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*python*' \) \
       -o -type l -name '*python*' \) \
    -print -quit 2>/dev/null || true)"
  if [[ -n "$hit" ]]; then
    echo "[swift-native] ERROR: Python artifact staged in app bundle: $hit" >&2
    echo "[swift-native] NativeAgent app artifacts must be Swift-native and zero-Python." >&2
    exit 1
  fi
}

xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true

assert_no_python_artifacts "$BUNDLE"

# Mac app signing. One shared owner keeps build and install on the exact same
# identity/profile/entitlement decision tree.
nativeagent_sign_development_bundle "$BUNDLE" "$ROOT" "$NATIVEAGENT_MAC_BUNDLE_ID" "[sign]"

# ─── POINT OF NO RETURN ─────────────────────────────────────────────────────
# The staged bundle is built, signed, and codesign-verified. Only now do we
# kill the running app (never in --build-only) and swap dist/NativeAgent.app.
if [[ "$MODE" != "--build-only" ]]; then
  # A running dist-launched instance must not have its bundle swapped
  # underneath it, and the launch below needs the old instance gone.
  # Skipped in --build-only: install_app.sh re-signs its own copy and quits
  # the app itself only after that copy passes codesign verification.
  pkill -x "$PRODUCT" 2>/dev/null || true
  # Wait (up to ~5s) for the app to exit before touching the bundle, then
  # hard-kill any survivor.
  for _ in $(seq 1 25); do
    if pgrep -x "$PRODUCT" >/dev/null 2>&1; then
      sleep 0.2
    else
      break
    fi
  done
  pkill -9 -x "$PRODUCT" 2>/dev/null || true
fi

# Swap with rollback: move the old dist bundle aside instead of rm -rf'ing
# it, so a failed mv can't leave dist/ empty (with the app already killed in
# the non---build-only modes, that would be exactly the downtime this change
# exists to prevent). None of the vars referenced in the trap are reassigned
# before the trap is cleared.
BUNDLE_OLD="$BUNDLE_FINAL.old.$$"
rm -rf "$BUNDLE_OLD"
# Arm the combined trap BEFORE the old bundle is moved aside (no window where
# only the staging-sweep trap covers a half-done swap), and restore FIRST —
# a failed sweep must not be able to skip the restore under set -e.
trap '
  if [ -d "$BUNDLE_OLD" ] && [ ! -d "$BUNDLE_FINAL" ]; then
    echo "[build_and_run.sh] mid-swap failure — restoring previous dist bundle" >&2
    mv "$BUNDLE_OLD" "$BUNDLE_FINAL"
  fi
  rm -rf "$ROOT/dist/.$APP_NAME.app.staging.$$" || true
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
  --verify)
    # HOTFIX 2026-06-03 Swift runtime cutover + launchd-163: the old /health
    # curl-probe no longer answers and the strict probe after `pgrep` was
    # forcing this --verify path to exit non-zero on every install. Combined
    # with `/usr/bin/open` returning 1 on launchd-163 (an OS launchd-cache
    # issue, not a bundle problem — the shared signing owner already proved
    # the bundle is valid + signed), this killed install_app.sh BEFORE it
    # could swap the bundle into ~/Applications/.
    # New verify: signed-and-valid is the gate that matters. Try a non-fatal
    # `open` for nicety, but don't gate the install on it.
    _verify_cleanup() {
      osascript -e 'tell application "NativeAgent" to quit' >/dev/null 2>&1 || true
      pkill -x NativeAgentApp >/dev/null 2>&1 || true
    }
    trap '_verify_cleanup' ERR INT TERM
    if NATIVE_AGENT_SKIP_LOGIN_ITEM_REGISTER=1 /usr/bin/open -n "$BUNDLE" >/dev/null 2>&1; then
      sleep 2
      if pgrep -x "$PRODUCT" >/dev/null 2>&1; then
        echo "Verified $APP_NAME launched OK"
      else
        echo "Verified $APP_NAME bundle (signed + valid; launchd refused spawn, OS cache — not a bundle problem)"
      fi
    else
      echo "Verified $APP_NAME bundle (signed + valid; /usr/bin/open hit launchd-163 — OS cache, not a bundle problem)"
    fi
    _verify_cleanup
    trap - ERR INT TERM
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
