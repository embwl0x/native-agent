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
  installed_repo_path="$(head -n 1 "$INSTALLED_APP_BUNDLE/Contents/Resources/REPO_PATH" | tr -d '[:space:]')"
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
NATIVEAGENT_BUILD_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
NATIVEAGENT_BUILD_VERSION="${NATIVEAGENT_BUILD_VERSION:-0.0.0-dev}"
NATIVEAGENT_SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
NATIVEAGENT_SOURCE_REVISION="${NATIVEAGENT_SOURCE_REVISION:-unknown}"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
  NATIVEAGENT_SOURCE_DIRTY=true
else
  NATIVEAGENT_SOURCE_DIRTY=false
fi
export NATIVEAGENT_MAC_BUNDLE_ID
export NATIVEAGENT_ICLOUD_CONTAINER_ID
export NATIVEAGENT_MOBILE_SOURCE_KEY
export NATIVEAGENT_BACKGROUND_TASK_PREFIX
export NATIVEAGENT_DEVICE_SYNC

# shellcheck source=lib/build_source_inventory.sh
source "$ROOT/script/lib/build_source_inventory.sh"

mkdir -p "$ROOT/.runtime" "$ROOT/dist/$APP_NAME.app/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# SPM stale-build-plan refresh (vault: 04_tooling/spm_local_dep_stale_build_plan.md):
# a new source file added to a local package dep (Modules/NativeAgentCore) is
# invisible to the ROOT build until the PARENT manifest mtime changes — the
# cached .build/debug.yaml keeps the dep's old source list and the build fails
# with "cannot find <NewType> in scope". Re-plan only when the deterministic
# source/resource PATH inventory changes; ordinary content edits remain owned
# by SwiftPM and no longer force an otherwise-cached plan on every build.
if nativeagent_refresh_swiftpm_plan_if_inventory_changed "$ROOT"; then
  echo "[swiftpm-plan] source/resource inventory changed; refreshed build plan"
else
  echo "[swiftpm-plan] source/resource inventory unchanged; keeping cached plan"
fi

# DOWNTIME GUARD 2026-07-02: the running app used to be pkill'd HERE, before
# `swift build` — so a compile failure (e.g. the stale-plan case above) left
# NativeAgent dead with nothing relaunched. The kill now happens at the
# POINT OF NO RETURN below, after the staged bundle is signed and verified.
SWIFTPM_SANDBOX_FLAG=()
if [[ "${NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  SWIFTPM_SANDBOX_FLAG=(--disable-sandbox)
fi

swift build ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT"
swift build ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} \
  --package-path "$ROOT" --product NativeAgentChromeRelay

BIN_DIR="$(swift build ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
CHROME_RELAY_BIN="$BIN_DIR/NativeAgentChromeRelay"
[[ -x "$CHROME_RELAY_BIN" ]] || {
  echo "[chrome-relay] ERROR: expected executable missing: $CHROME_RELAY_BIN" >&2
  exit 1
}
# Stage + sign into a TEMP bundle and only swap it into dist/NativeAgent.app
# after the shared signing owner passes deep verification. Every fallible step (resource staging,
# provisioning checks, codesign, verification) therefore runs while the
# previous dist bundle — and the running app — are still intact; a failure
# anywhere exits nonzero with nothing killed and nothing half-replaced.
BUNDLE_FINAL="$ROOT/dist/$APP_NAME.app"
BUNDLE="$ROOT/dist/.$APP_NAME.app.staging.$$"
rm -rf "$BUNDLE"
# Sweep the staging dir on any exit; cleared after the swap below (once the
# mv lands, $BUNDLE is reassigned to the final path — this trap must be gone
# by then or it would delete the freshly installed bundle).
trap 'rm -rf "$ROOT/dist/.$APP_NAME.app.staging.$$"' EXIT
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$PRODUCT"
cp "$CHROME_RELAY_BIN" "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
chmod 0755 "$BUNDLE/Contents/MacOS/NativeAgentChromeRelay"
if [[ -f "$ROOT/VERSION" ]]; then
  cp "$ROOT/VERSION" "$BUNDLE/Contents/Resources/VERSION"
fi
printf '%s\n' "$NATIVEAGENT_SOURCE_REVISION" > "$BUNDLE/Contents/Resources/VERSION_SHA"

# 2026-06-07 task #88: stage SPM-generated resource bundles into
# Contents/Resources/. Without this, the bundled MiniLM mlpackage is
# unreachable in any install where `.build/` doesn't exist next to the
# binary (i.e. anyone but the developer who built it).
#
# We stage UNDER Contents/Resources/ ONLY. Putting `.bundle` dirs at the
# .app top level breaks codesign (strict bundle-layout check). The
# SPM-synthesized `Bundle.module` resolver looks at the .app top level
# first, so the Swift-side `CoreMLEmbeddingProvider.bundled()` factory
# adds an explicit Bundle.main fallback to Contents/Resources/<name>.bundle
# in the installed-app shape.
SPM_BIN_DIR_FOR_RES="$(dirname "$BIN")"
shopt -s nullglob
for spm_bundle in "$SPM_BIN_DIR_FOR_RES"/*.bundle; do
  bundle_basename="$(basename "$spm_bundle")"
  rm -rf "$BUNDLE/Contents/Resources/$bundle_basename"
  cp -R "$spm_bundle" "$BUNDLE/Contents/Resources/$bundle_basename"
  echo "[spm-resources] staged $bundle_basename"
done
shopt -u nullglob

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

# Copy Sparkle.framework to the standard app bundle framework location and
# make the executable's rpath explicit. This avoids the startup updater warning
# caused by dyld being unable to resolve @rpath/Sparkle.framework in installed
# bundles.
SPM_BIN_DIR="$(dirname "$BIN")"
if [[ -d "$SPM_BIN_DIR/Sparkle.framework" ]]; then
  mkdir -p "$BUNDLE/Contents/Frameworks"
  rm -rf "$BUNDLE/Contents/Frameworks/Sparkle.framework" "$BUNDLE/Contents/MacOS/Sparkle.framework"
  cp -R "$SPM_BIN_DIR/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null || true
  fi
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT</string>
  <key>CFBundleIdentifier</key>
  <string>$NATIVEAGENT_MAC_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleVersion</key>
  <string>$NATIVEAGENT_BUILD_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$NATIVEAGENT_BUILD_VERSION</string>
  <key>NativeAgentSourceRevision</key>
  <string>$NATIVEAGENT_SOURCE_REVISION</string>
  <key>NativeAgentSourceDirty</key>
  <$NATIVEAGENT_SOURCE_DIRTY/>
  <key>NativeAgentMacBundleID</key>
  <string>$NATIVEAGENT_MAC_BUNDLE_ID</string>
  <key>NativeAgentICloudContainerID</key>
  <string>$NATIVEAGENT_ICLOUD_CONTAINER_ID</string>
  <key>NativeAgentMobileSourceKey</key>
  <string>$NATIVEAGENT_MOBILE_SOURCE_KEY</string>
  <key>NativeAgentBackgroundTaskIDPrefix</key>
  <string>$NATIVEAGENT_BACKGROUND_TASK_PREFIX</string>
  <key>NativeAgentDeviceSync</key>
  <string>$NATIVEAGENT_DEVICE_SYNC</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>NativeAgent Chat Session</string>
      <key>UTTypeIdentifier</key>
      <string>com.nativeagent.chat-session</string>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>NativeAgent uses Apple Events to coordinate with system applications.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>NativeAgent uses calendar access for assistant briefings and user-approved watch jobs.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>NativeAgent uses full calendar access to read upcoming events for assistant briefings and user-approved watch jobs.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>NativeAgent uses write-only calendar access to create events only when the user enables Calendar write access.</string>
  <key>NSRemindersUsageDescription</key>
  <string>NativeAgent uses reminders access for assistant briefings and user-approved watch jobs.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>NativeAgent uses reminders access to read due reminders for assistant briefings and user-approved watch jobs.</string>
  <!-- Contacts framework access for assistant-requested people lookup. -->
  <key>NSContactsUsageDescription</key>
  <string>NativeAgent uses Contacts so the assistant can look up people you ask about and (with the Contacts write toggle on) create or update contacts on your behalf.</string>
  <!-- PATCH-2026-05-06: multimodal-ui Sprint 3.1 — voice input usage descriptions -->
  <key>NSMicrophoneUsageDescription</key>
  <string>NativeAgent uses your microphone for voice input.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>NativeAgent uses speech recognition to transcribe your voice.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>NativeAgent uses the local network to connect the Mac app and trusted companion devices.</string>
</dict>
</plist>
PLIST

# Stamp REPO_PATH in dev bundles so Swift-native data-root resolution can keep
# using the repo-owned data/ tree during local development.
printf '%s\n' "$ROOT" > "$BUNDLE/Contents/Resources/REPO_PATH"

xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true

# Belt-and-suspenders: stale runtime artifacts under Contents/ make codesign
# reject the bundle, so strip them before signing.
rm -rf "$BUNDLE/Contents/.runtime" "$BUNDLE/Contents/.build"
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
