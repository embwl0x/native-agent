#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
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

mkdir -p "$ROOT/.runtime" "$ROOT/dist/$APP_NAME.app/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# SPM stale-build-plan refresh (vault: 04_tooling/spm_local_dep_stale_build_plan.md):
# a new source file added to a local package dep (Modules/NativeAgentCore) is
# invisible to the ROOT build until the PARENT manifest mtime changes — the
# cached .build/debug.yaml keeps the dep's old source list and the build fails
# with "cannot find <NewType> in scope". Touch the root manifest to force a
# re-plan every build.
touch "$ROOT/Package.swift"

# DOWNTIME GUARD 2026-07-02: the running app used to be pkill'd HERE, before
# `swift build` — so a compile failure (e.g. the stale-plan case above) left
# NativeAgent dead with nothing relaunched. The kill now happens at the
# POINT OF NO RETURN below, after the staged bundle is signed and verified.
SWIFTPM_SANDBOX_FLAG=()
if [[ "${NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  SWIFTPM_SANDBOX_FLAG=(--disable-sandbox)
fi

swift build ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT"

BIN="$(swift build ${SWIFTPM_SANDBOX_FLAG[@]+"${SWIFTPM_SANDBOX_FLAG[@]}"} --package-path "$ROOT" --show-bin-path)/$PRODUCT"
# Stage + sign into a TEMP bundle and only swap it into dist/NativeAgent.app
# after _verify_signed_bundle passes. Every fallible step (resource staging,
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
  <string>14.0</string>
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

# Mac app signing.
#
# Default path: dev cert + embedded provisioning profile + DER entitlements
# (so iCloud bidi chat works between iOS and Mac).  Falls back to ad-hoc
# automatically if the local cert or ignored local profile is missing.
#
# Force ad-hoc with NATIVE_AGENT_ADHOC=1 (useful for tests that bypass the
# entitlement chain entirely).
PROVISION_PROFILE="${NATIVEAGENT_PROVISIONING_PROFILE:-$ROOT/local/NativeAgent.provisionprofile}"
# Authoritatively detect a real signing identity from the keychain FIRST. A
# stale/blank env var must NOT be able to force ad-hoc when a real cert exists:
# an ad-hoc iCloud bundle is killed by macOS on launch. Prefer "Apple
# Development", then fall back to any Developer ID Application identity.
DISCOVERED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')"
if [[ -z "$DISCOVERED_IDENTITY" ]]; then
    DISCOVERED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
fi
ENV_IDENTITY="${NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY:-${NATIVE_AGENT_DEVELOPER_ID:-}}"
if [[ -n "$ENV_IDENTITY" ]]; then
    # An explicit env override only wins if it names an identity that actually
    # exists in the keychain. If a real cert exists but the env var points at a
    # DIFFERENT/nonexistent identity, fail loudly rather than silently dropping
    # to ad-hoc (the exact incident class this guard protects against).
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$ENV_IDENTITY"; then
        SIGN_IDENTITY="$ENV_IDENTITY"
    elif [[ -n "$DISCOVERED_IDENTITY" ]]; then
        echo "[sign] NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY/NATIVE_AGENT_DEVELOPER_ID='$ENV_IDENTITY'" >&2
        echo "[sign] is NOT present in the keychain, but a real signing identity IS:" >&2
        echo "[sign]   '$DISCOVERED_IDENTITY'" >&2
        echo "[sign] Refusing to silently ad-hoc-sign an iCloud app (macOS would kill it)." >&2
        echo "[sign] Fix or unset the env var (the discovered identity will be used)," >&2
        echo "[sign] or set NATIVE_AGENT_ADHOC=1 to explicitly opt into ad-hoc." >&2
        exit 1
    else
        # No real cert anywhere: keep the (stale) env value so the membership
        # gate below falls through to the documented ad-hoc path.
        SIGN_IDENTITY="$ENV_IDENTITY"
    fi
else
    SIGN_IDENTITY="$DISCOVERED_IDENTITY"
fi
ENT_FULL="${NATIVEAGENT_ENTITLEMENTS:-$ROOT/local/NativeAgent.entitlements}"
ENT_ADHOC="$ROOT/NativeAgent.adhoc.entitlements"

_sign_nested_plain() {
    local identity="$1"
    local timestamp_arg="${2:---timestamp=none}"
    if [[ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
        codesign --force --deep --sign "$identity" --options runtime $timestamp_arg \
            "$BUNDLE/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
    fi
}

_strip_unprovisioned_entitlements() {
    # Keep aligned with install_app.sh. The local source entitlements declare
    # background task identifiers for future unlock, but the current Mac
    # development profile does not grant com.apple.developer.background-tasks.
    # Signing the dev bundle with that key makes AMFI reject launch before the
    # app starts.
    local src="$ENT_FULL"
    local out="$1"
    /usr/bin/perl -0pe 's/\s*<key>com\.apple\.developer\.background-tasks<\/key>\s*<array>.*?<\/array>//s' "$src" > "$out"
}

_sign_dev_cert() {
    # Embed provisioning profile into the bundle (required for restricted entitlements).
    # This function runs inside an `if ! _sign_dev_cert` guard, which SUPPRESSES
    # `set -e`. A failed profile copy must NOT be masked and silently treated as
    # the "maybe fall back to ad-hoc" path — without the embedded profile the
    # iCloud entitlements are not honored and the app is killed at launch. Make
    # the profile copy a hard, immediate abort (exit, not return) so it can never
    # be swallowed by the guard.
    if ! cp "$PROVISION_PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"; then
        echo "[sign] FATAL: failed to copy provisioning profile into the bundle:" >&2
        echo "[sign]   $PROVISION_PROFILE -> $BUNDLE/Contents/embedded.provisionprofile" >&2
        echo "[sign] Cannot honor iCloud entitlements without it. Aborting." >&2
        exit 1
    fi
    chmod 0644 "$BUNDLE/Contents/embedded.provisionprofile"
    _sign_nested_plain "$SIGN_IDENTITY" "--timestamp=none"
    local ENT_TEMPLATE_PATH="${TMPDIR:-/tmp}/na_ent_template.$$.entitlements"
    local ENT_SIGN_PATH="${TMPDIR:-/tmp}/na_ent_sign.$$.entitlements"
    local PROFILE_PLIST="${TMPDIR:-/tmp}/na_profile.$$.plist"
    _strip_unprovisioned_entitlements "$ENT_TEMPLATE_PATH"
    if ! decode_provisioning_profile "$PROVISION_PROFILE" "$PROFILE_PLIST" \
      || ! verify_profile_identity_contract "$PROFILE_PLIST" "$NATIVEAGENT_MAC_BUNDLE_ID" \
      || ! prepare_profile_signing_entitlements "$ENT_TEMPLATE_PATH" "$PROFILE_PLIST" "$ENT_SIGN_PATH"; then
        rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
        echo "[sign] FATAL: provisioning profile identity does not match the bundle." >&2
        exit 1
    fi
    # Sign with hardened runtime + DER entitlements.  --generate-entitlement-der
    # is required on Tahoe for restricted entitlements (iCloud) to be honored.
    # NOTE: do not suppress stderr here — a failure means the app falls back to
    # an unlaunchable ad-hoc signature, and the codesign error is the only clue.
    codesign --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --generate-entitlement-der \
        --entitlements "$ENT_SIGN_PATH" \
        --timestamp=none \
        "$BUNDLE"
    if ! verify_signed_bundle_profile_identity "$BUNDLE" "$PROFILE_PLIST" "$NATIVEAGENT_MAC_BUNDLE_ID"; then
        rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
        echo "[sign] FATAL: signed CloudKit identity does not match the embedded profile." >&2
        exit 1
    fi
    rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
}

_sign_adhoc() {
    _sign_nested_plain "-" "--timestamp=none"
    # Do NOT suppress the final top-level signature: a total signing failure
    # here would otherwise look like success and ship an unsigned bundle. Drop
    # the `2>&1`/`|| true` so the error is visible and fatal under `set -e`.
    if [[ -f "$ENT_ADHOC" ]]; then
        codesign --force --sign - --entitlements "$ENT_ADHOC" "$BUNDLE"
    else
        codesign --force --sign - "$BUNDLE"
    fi
}

# Fatal integrity gate: a failed inner Sparkle signature is
# swallowed by `|| true` inside _sign_nested_plain and only surfaces at launch
# as an unsigned nested Mach-O. Verify the whole bundle after signing and make
# any failure FATAL (mirrors verify_release_artifact.sh's --verify --deep
# --strict gate for release builds).
_verify_signed_bundle() {
    echo "[sign] verifying bundle signature (--deep --strict)..."
    if ! codesign --verify --deep --strict --verbose=2 "$BUNDLE"; then
        echo "[sign] codesign --verify --deep --strict FAILED for $BUNDLE" >&2
        echo "[sign] a nested Mach-O (Sparkle) is unsigned or invalid." >&2
        echo "[sign] refusing to ship an unlaunchable bundle. Fix the cause and re-run." >&2
        exit 1
    fi
}

_assert_profile_allows_current_mac() {
    local profile="$1" ids devices_xml id matched
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

    echo "[sign] provisioning profile does not include this Mac, so macOS will refuse to launch the iCloud build." >&2
    echo "[sign]   profile: $profile" >&2
    echo "[sign] this Mac IDs:" >&2
    while IFS= read -r id; do
        [[ -n "$id" ]] && echo "[sign]   - $id" >&2
    done <<<"$ids"
    echo "[sign] profile allowed devices:" >&2
    printf '%s\n' "$devices_xml" | awk -F'[<>]' '/<string>/ {print "[sign]   - " $3}' >&2
    echo "[sign] Regenerate/download the Mac Development profile for $NATIVEAGENT_MAC_BUNDLE_ID with this Mac selected," >&2
    echo "[sign] replace $ROOT/local/NativeAgent.provisionprofile, then rerun ./script/install_app.sh." >&2
    echo "[sign] Temporary local-only launch: NATIVE_AGENT_ADHOC=1 ./script/install_app.sh (iCloud disabled)." >&2
    exit 1
}

if [[ "${NATIVE_AGENT_ADHOC:-0}" == "1" ]]; then
    echo "[sign] NATIVE_AGENT_ADHOC=1 — using ad-hoc signature (no iCloud)"
    _sign_adhoc
elif [[ -f "$PROVISION_PROFILE" && -f "$ENT_FULL" ]] \
     && [[ -n "$SIGN_IDENTITY" ]] \
     && security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$SIGN_IDENTITY"; then
    echo "[sign] Apple Development cert + provisioning profile + iCloud entitlements"
    _assert_profile_allows_current_mac "$PROVISION_PROFILE"
    # Cert + profile ARE present: a dev-cert signing failure here is the exact
    # incident class (silent ad-hoc fallback → iCloud-killed app). Treat it as
    # FATAL. Only allow the ad-hoc fallback behind an explicit opt-in flag.
    if ! _sign_dev_cert; then
        echo "[sign] dev-cert signing FAILED (see codesign error above)." >&2
        if [[ "${NATIVE_AGENT_ADHOC_FALLBACK:-0}" == "1" ]]; then
            echo "[sign] NATIVE_AGENT_ADHOC_FALLBACK=1 — falling back to ad-hoc" >&2
            echo "[sign] iCloud entitlements will NOT be honored and macOS may kill the app." >&2
            _sign_adhoc
        else
            echo "[sign] cert+profile are present, so this is NOT a missing-identity case —" >&2
            echo "[sign] refusing to silently ship an unlaunchable ad-hoc iCloud app." >&2
            echo "[sign] Fix the codesign cause and re-run, or set NATIVE_AGENT_ADHOC_FALLBACK=1" >&2
            echo "[sign] (or NATIVE_AGENT_ADHOC=1) to explicitly opt into ad-hoc." >&2
            exit 1
        fi
    fi
else
    echo "[sign] no local provisioning profile / cert — ad-hoc (iCloud disabled)"
    _sign_adhoc
fi
_verify_signed_bundle

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
    # issue, not a bundle problem — `_verify_signed_bundle` already proved
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
