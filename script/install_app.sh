#!/usr/bin/env bash
# Swift-native NativeAgent.app installer.
#
# Replaces the old install_launch_agent.sh setup. There is no launchd plist
# and no bundled external interpreter runtime; the macOS app owns the runtime in Swift and
# uses SMAppService at first launch to register for login auto-start.
#
# Steps (DOWNTIME GUARD 2026-07-02 — the running app is NOT touched until the
# replacement bundle is fully built, signed, and codesign-verified; any failure
# before the swap exits nonzero and leaves the current install running):
#   1. Build the Swift app bundle (build_and_run.sh --build-only: no kill,
#      no launch).
#   2. Copy dist/NativeAgent.app → temp bundle next to ~/Applications, stamp
#      VERSION/SHA/REPO_PATH.
#   3. Re-codesign the temp bundle with the dev certificate + iCloud
#      entitlements when available, falling back to ad-hoc only when
#      explicitly requested or when the signing identity/profile is missing;
#      verify the signature (--deep --strict) — all fail-closed.
#   4. ONLY NOW tear down any prior retired external-runtime agent + quit the
#      running NativeAgent.app instance.
#   5. Atomically swap the temp bundle into ~/Applications/NativeAgent.app.
#   6. Launch and prove authenticated chat/source readiness; only then delete
#      the previous bundle. Failed readiness restores the prior install.
#
# After this, you double-click ~/Applications/NativeAgent.app to start. The
# app stays in the menu bar.

set -euo pipefail

for arg in "$@"; do
    case "$arg" in
        --with-st)
            echo "[install_app.sh] ERROR: --with-st is retired. NativeAgent bundles zero Python; embeddings must use the Swift/CoreML path." >&2
            exit 2
            ;;
        --force-checkout-switch)
            FORCE_CHECKOUT_SWITCH=1
            ;;
        --help|-h)
            cat <<'USAGE'
Usage:
  ./script/install_app.sh [--force-checkout-switch]

NativeAgent app bundles are Swift-native and zero-Python. The retired
--with-st / sentence-transformers install path is intentionally rejected.

--force-checkout-switch allows reinstalling over an installed app whose
REPO_PATH stamp names a DIFFERENT live checkout (see the guard below).
USAGE
            exit 0
            ;;
        *)
            echo "[install_app.sh] ERROR: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"

# Keep the installer's final signing identity aligned with build_and_run.sh.
# That builder already loads this ignored, machine-local file before it stamps
# the bundle. Without loading it here too, a private development build can be
# created correctly and then rejected by the installer because its second
# signing pass falls back to the public bundle identifier.
LOCAL_ENV="$ROOT/local/nativeagent.local.env"
if [[ -f "$LOCAL_ENV" ]]; then
    # Local Apple/iCloud identifiers are intentionally gitignored.
    # shellcheck source=/dev/null
    source "$LOCAL_ENV"
fi
APP_NAME="NativeAgent"
APP_DEST="$HOME/Applications/$APP_NAME.app"
FORCE_CHECKOUT_SWITCH="${FORCE_CHECKOUT_SWITCH:-0}"

# 2026-07-21 audit: checkout-identity guard. The installed bundle's
# Resources/REPO_PATH stamp names the checkout the app's data-root resolution
# points at. Reinstalling from a DIFFERENT live clone/worktree would silently
# restamp the installed bundle with this checkout's path and bounce the live
# app onto a foreign data root. Refuse unless --force-checkout-switch; a stamp
# naming a deleted checkout is not a conflict.
if [[ "$FORCE_CHECKOUT_SWITCH" != "1" && -f "$APP_DEST/Contents/Resources/REPO_PATH" ]]; then
    installed_repo_path="$(head -n 1 "$APP_DEST/Contents/Resources/REPO_PATH" | tr -d '[:space:]')"
    if [[ -n "$installed_repo_path" && -d "$installed_repo_path" ]]; then
        installed_repo_resolved="$(cd "$installed_repo_path" 2>/dev/null && pwd -P || true)"
        root_resolved="$(cd "$ROOT" && pwd -P)"
        if [[ -n "$installed_repo_resolved" && "$installed_repo_resolved" != "$root_resolved" ]]; then
            echo "[install_app.sh] ERROR: the installed app belongs to a different checkout:" >&2
            echo "  installed: $installed_repo_resolved" >&2
            echo "  this run : $root_resolved" >&2
            echo "Reinstalling would repoint the live app's data root and bounce it." >&2
            echo "Pass --force-checkout-switch to switch the installed app to this checkout." >&2
            exit 2
        fi
    fi
fi

if [ "${NATIVE_AGENT_INSTALL_WITH_ST:-0}" = "1" ]; then
    echo "[install_app.sh] ERROR: NATIVE_AGENT_INSTALL_WITH_ST is retired. NativeAgent bundles zero Python; embeddings must use the Swift/CoreML path." >&2
    exit 2
fi

_assert_no_python_artifacts() {
    local bundle="$1" hit
    hit="$(find "$bundle/Contents/Resources" \
        \( -type d \( -name python -o -name __pycache__ \) \
           -o -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*python*' \) \
           -o -type l -name '*python*' \) \
        -print -quit 2>/dev/null || true)"
    if [[ -n "$hit" ]]; then
        echo "[install_app.sh] ERROR: Python artifact present in app bundle: $hit" >&2
        echo "[install_app.sh] NativeAgent install artifacts must be Swift-native and zero-Python." >&2
        exit 1
    fi
}

# Phase 11b: log rotation targets repo/data/logs/ (the authoritative live path).
# The old DATA variable pointed at ~/Library/Application Support/NativeAgent which
# is now only a legacy duplicate; rotating it was rotating empty/stale files.
DATA="$ROOT/data"

# 0. Phase 11: ensure persona/ and data/ are initialized for first-time cloners
"$ROOT/script/init_persona.sh"

# 1. Build the Swift app bundle. --build-only: build_and_run.sh must NOT kill
# or launch anything — the running app stays alive until the replacement
# bundle below is fully signed and verified (2026-07-02: a stale-SPM-plan
# compile failure after the old pre-build pkill left the app dead with
# nothing relaunched — live downtime until a manual rebuild).
"$ROOT/script/build_and_run.sh" --build-only

# 2. Stage fresh bundle — copy to temp then mv for atomic swap
mkdir -p "$HOME/Applications" "$DATA/logs"
DIST_BUNDLE="$ROOT/dist/$APP_NAME.app"
TEMP_BUNDLE="$(dirname "$APP_DEST")/.NativeAgent.app.tmp.$$"
rm -rf "$TEMP_BUNDLE"
cp -R "$DIST_BUNDLE" "$TEMP_BUNDLE"
xattr -dr com.apple.quarantine "$TEMP_BUNDLE" 2>/dev/null || true

# C.5: Bundle docs/data-bounds.md so AboutView can open it from the bundle
if [ -f "$ROOT/docs/data-bounds.md" ]; then
    DOCS_DEST="$TEMP_BUNDLE/Contents/Resources/docs"
    mkdir -p "$DOCS_DEST"
    cp "$ROOT/docs/data-bounds.md" "$DOCS_DEST/data-bounds.md"
fi

# Stamp the build's full git object ID into Resources/VERSION_SHA so runtime
# status can prove the exact committed source when the dirty bit is false
# bundle (where there's no .git for `git rev-parse` to consult).
if command -v git >/dev/null 2>&1; then
    BUILD_SHA="$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$BUILD_SHA" ]; then
        printf '%s\n' "$BUILD_SHA" > "$TEMP_BUNDLE/Contents/Resources/VERSION_SHA"
    fi
fi
if [ -f "$ROOT/VERSION" ]; then
    cp "$ROOT/VERSION" "$TEMP_BUNDLE/Contents/Resources/VERSION"
fi

# The development bundle is an operational artifact too. Stamp the same exact
# version/source identity exposed by the release bundle so bridge/Doctor proof
# can distinguish "running" from "running the requested source". A dirty bit
# makes an uncommitted install honest instead of pretending HEAD describes all
# bytes that were compiled.
INSTALL_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
INSTALL_VERSION="${INSTALL_VERSION:-0.0.0-dev}"
INSTALL_SOURCE_REVISION="${BUILD_SHA:-unknown}"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
    INSTALL_SOURCE_DIRTY=true
else
    INSTALL_SOURCE_DIRTY=false
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $INSTALL_VERSION" "$TEMP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $INSTALL_VERSION" "$TEMP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $INSTALL_VERSION" "$TEMP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $INSTALL_VERSION" "$TEMP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NativeAgentSourceRevision $INSTALL_SOURCE_REVISION" "$TEMP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :NativeAgentSourceRevision string $INSTALL_SOURCE_REVISION" "$TEMP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NativeAgentSourceDirty $INSTALL_SOURCE_DIRTY" "$TEMP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :NativeAgentSourceDirty bool $INSTALL_SOURCE_DIRTY" "$TEMP_BUNDLE/Contents/Info.plist"

# Phase 11: Stamp the source-repo path into the bundle so the Swift app can
# locate the source-tree persona/ directory at runtime.
printf '%s\n' "$ROOT" > "$TEMP_BUNDLE/Contents/Resources/REPO_PATH"

_assert_no_python_artifacts "$TEMP_BUNDLE"

# 3. Re-codesign with entitlements (on temp bundle before atomic swap).
# Keep this aligned with build_and_run.sh: iCloud/KVS entitlements require a
# local Apple Development signature and embedded provisioning profile. Those
# private files are intentionally ignored by git.
ENT_ADHOC="$ROOT/NativeAgent.adhoc.entitlements"
ENT_FULL="${NATIVEAGENT_ENTITLEMENTS:-$ROOT/local/NativeAgent.entitlements}"
PROVISION_PROFILE="${NATIVEAGENT_PROVISIONING_PROFILE:-$ROOT/local/NativeAgent.provisionprofile}"
# Resolve the signing identity DYNAMICALLY (mirrors build_and_run.sh). A
# hardcoded SHA-1 silently falls to ad-hoc the moment the dev cert rotates —
# and an ad-hoc iCloud app is killed by macOS on launch. Honor the same env
# overrides build_and_run.sh respects, then fall back to the first
# "Apple Development" identity in the keychain.
# Authoritatively detect a real signing identity from the keychain FIRST, then
# only honor an explicit env override when it actually exists. A stale/blank env
# var must NOT be able to force ad-hoc when a real cert is present: an ad-hoc
# iCloud bundle is killed by macOS on launch. (Mirrors build_and_run.sh.)
DISCOVERED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')"
if [[ -z "$DISCOVERED_IDENTITY" ]]; then
    DISCOVERED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
fi
ENV_IDENTITY="${NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY:-${NATIVE_AGENT_DEVELOPER_ID:-}}"
if [[ -n "$ENV_IDENTITY" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$ENV_IDENTITY"; then
        SIGN_IDENTITY="$ENV_IDENTITY"
    elif [[ -n "$DISCOVERED_IDENTITY" ]]; then
        echo "[install_app.sh] NATIVE_AGENT_DEVELOPMENT_SIGN_IDENTITY/NATIVE_AGENT_DEVELOPER_ID='$ENV_IDENTITY'" >&2
        echo "[install_app.sh] is NOT present in the keychain, but a real signing identity IS:" >&2
        echo "[install_app.sh]   '$DISCOVERED_IDENTITY'" >&2
        echo "[install_app.sh] Refusing to silently ad-hoc-sign an iCloud app (macOS would kill it)." >&2
        echo "[install_app.sh] Fix or unset the env var, or set NATIVE_AGENT_ADHOC=1 to opt into ad-hoc." >&2
        exit 1
    else
        SIGN_IDENTITY="$ENV_IDENTITY"
    fi
else
    SIGN_IDENTITY="$DISCOVERED_IDENTITY"
fi

_sign_nested_plain() {
    local identity="$1"
    if [[ -d "$TEMP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
        codesign --force --deep --sign "$identity" --options runtime --timestamp=none \
            "$TEMP_BUNDLE/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
    fi
}

_strip_unprovisioned_entitlements() {
    # HOTFIX 2026-06-03: source NativeAgent.entitlements declares capabilities
    # the May-9 provisioning profile does not grant (BGTasks + full CloudKit).
    # AMFI silently SIGKILLs at launch (exit 137) on an entitlement-vs-profile
    # mismatch. Until the profile is regenerated via Apple Dev portal with all
    # current capabilities, strip declared-but-ungranted keys for the install
    # codesign step. The source entitlements file stays full so a regenerated
    # profile auto-unlocks them next install.
    #
    # Stripped keys (today): com.apple.developer.background-tasks
    # Preserved: iCloud-container, ubiquity-container, ubiquity-kvstore,
    #            icloud-services (CloudDocuments), application-identifier,
    #            team-identifier, com.apple.security.*
    local src="$ENT_FULL"
    local out="$1"
    /usr/bin/perl -0pe 's/\s*<key>com\.apple\.developer\.background-tasks<\/key>\s*<array>.*?<\/array>//s' "$src" > "$out"
}

_sign_dev_cert() {
    # Runs inside `if ! _sign_dev_cert`, which suppresses `set -e`. A failed
    # provisioning-profile copy must be an immediate fatal abort (exit, not
    # return) so it can't be masked and mis-handled as the "maybe fall back to
    # ad-hoc" path — an iCloud bundle without the embedded profile is killed at
    # launch. (Mirrors build_and_run.sh.)
    if ! cp "$PROVISION_PROFILE" "$TEMP_BUNDLE/Contents/embedded.provisionprofile"; then
        echo "[install_app.sh] FATAL: failed to copy provisioning profile into the bundle:" >&2
        echo "[install_app.sh]   $PROVISION_PROFILE -> $TEMP_BUNDLE/Contents/embedded.provisionprofile" >&2
        echo "[install_app.sh] Cannot honor iCloud entitlements without it. Aborting." >&2
        exit 1
    fi
    chmod 0644 "$TEMP_BUNDLE/Contents/embedded.provisionprofile"
    _sign_nested_plain "$SIGN_IDENTITY"
    # HOTFIX 2026-06-03: strip declared-but-ungranted entitlements before the
    # outer sign so AMFI accepts the launch. See _strip_unprovisioned_*.
    local ENT_TEMPLATE_PATH="${TMPDIR:-/tmp}/na_ent_template.$$.entitlements"
    local ENT_SIGN_PATH="${TMPDIR:-/tmp}/na_ent_sign.$$.entitlements"
    local PROFILE_PLIST="${TMPDIR:-/tmp}/na_profile.$$.plist"
    _strip_unprovisioned_entitlements "$ENT_TEMPLATE_PATH"
    if ! decode_provisioning_profile "$PROVISION_PROFILE" "$PROFILE_PLIST" \
      || ! verify_profile_identity_contract "$PROFILE_PLIST" "${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}" \
      || ! prepare_profile_signing_entitlements "$ENT_TEMPLATE_PATH" "$PROFILE_PLIST" "$ENT_SIGN_PATH"; then
        rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
        echo "[install_app.sh] FATAL: provisioning profile identity does not match the bundle." >&2
        exit 1
    fi
    # Do NOT suppress stderr here — a dev-cert failure is the only clue before
    # an ad-hoc iCloud bundle gets killed at launch.
    codesign --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --generate-entitlement-der \
        --entitlements "$ENT_SIGN_PATH" \
        --timestamp=none \
        "$TEMP_BUNDLE"
    if ! verify_signed_bundle_profile_identity \
      "$TEMP_BUNDLE" \
      "$PROFILE_PLIST" \
      "${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"; then
        rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
        echo "[install_app.sh] FATAL: signed CloudKit identity does not match the embedded profile." >&2
        exit 1
    fi
    rm -f "$ENT_TEMPLATE_PATH" "$ENT_SIGN_PATH" "$PROFILE_PLIST"
}

_sign_adhoc() {
    _sign_nested_plain "-"
    # Drop the `2>&1`/`|| true` on the final top-level sign so a total signing
    # failure surfaces and is fatal under `set -e` instead of looking like
    # success.
    if [[ -f "$ENT_ADHOC" ]]; then
        codesign --force --sign - --entitlements "$ENT_ADHOC" "$TEMP_BUNDLE"
    else
        codesign --force --sign - "$TEMP_BUNDLE"
    fi
}

# Fatal integrity gate: a failed inner Sparkle signature is
# swallowed by `|| true` inside _sign_nested_plain and only surfaces at launch.
# Verify the whole bundle after signing and make any failure FATAL.
_verify_signed_bundle() {
    echo "[install_app.sh] verifying bundle signature (--deep --strict)..."
    if ! codesign --verify --deep --strict --verbose=2 "$TEMP_BUNDLE"; then
        echo "[install_app.sh] codesign --verify --deep --strict FAILED for $TEMP_BUNDLE" >&2
        echo "[install_app.sh] a nested Mach-O (Sparkle) is unsigned or invalid." >&2
        echo "[install_app.sh] refusing to install an unlaunchable bundle. Fix the cause and re-run." >&2
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

    echo "[install_app.sh] provisioning profile does not include this Mac, so macOS will refuse to launch the iCloud build." >&2
    echo "[install_app.sh]   profile: $profile" >&2
    echo "[install_app.sh] this Mac IDs:" >&2
    while IFS= read -r id; do
        [[ -n "$id" ]] && echo "[install_app.sh]   - $id" >&2
    done <<<"$ids"
    echo "[install_app.sh] profile allowed devices:" >&2
    printf '%s\n' "$devices_xml" | awk -F'[<>]' '/<string>/ {print "[install_app.sh]   - " $3}' >&2
    echo "[install_app.sh] Regenerate/download the Mac Development profile for ${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac} with this Mac selected," >&2
    echo "[install_app.sh] replace $ROOT/local/NativeAgent.provisionprofile, then rerun ./script/install_app.sh." >&2
    echo "[install_app.sh] Temporary local-only launch: NATIVE_AGENT_ADHOC=1 ./script/install_app.sh (iCloud disabled)." >&2
    exit 1
}

if [[ "${NATIVE_AGENT_ADHOC:-0}" == "1" ]]; then
    echo "[install_app.sh] NATIVE_AGENT_ADHOC=1 — using ad-hoc signature (iCloud disabled)"
    _sign_adhoc
elif [[ -f "$PROVISION_PROFILE" && -f "$ENT_FULL" ]] \
     && [[ -n "$SIGN_IDENTITY" ]] \
     && security find-identity -v -p codesigning 2>/dev/null | grep -Fq -- "$SIGN_IDENTITY"; then
    echo "[install_app.sh] signing installed app with Apple Development cert + iCloud entitlements"
    _assert_profile_allows_current_mac "$PROVISION_PROFILE"
    # Cert + profile ARE present: a dev-cert signing failure here is the exact
    # incident class (silent ad-hoc fallback → iCloud-killed app). Treat it as
    # FATAL. Only allow the ad-hoc fallback behind an explicit opt-in flag.
    if ! _sign_dev_cert; then
        echo "[install_app.sh] dev-cert signing FAILED (see codesign error above)." >&2
        if [[ "${NATIVE_AGENT_ADHOC_FALLBACK:-0}" == "1" ]]; then
            echo "[install_app.sh] NATIVE_AGENT_ADHOC_FALLBACK=1 — falling back to ad-hoc" >&2
            echo "[install_app.sh] iCloud entitlements will NOT be honored and macOS may kill the app." >&2
            _sign_adhoc
        else
            echo "[install_app.sh] cert+profile are present, so this is NOT a missing-identity case —" >&2
            echo "[install_app.sh] refusing to silently ship an unlaunchable ad-hoc iCloud app." >&2
            echo "[install_app.sh] Fix the codesign cause and re-run, or set NATIVE_AGENT_ADHOC_FALLBACK=1" >&2
            echo "[install_app.sh] (or NATIVE_AGENT_ADHOC=1) to explicitly opt into ad-hoc." >&2
            exit 1
        fi
    fi
else
    echo "[install_app.sh] no local provisioning profile / cert — ad-hoc (iCloud disabled)"
    _sign_adhoc
fi
_verify_signed_bundle

# ─── POINT OF NO RETURN ────────────────────────────────────────────────────
# Everything above operates on the temp bundle only; any failure up there
# exits nonzero with the running app untouched. The replacement bundle is now
# built, signed, and codesign-verified — only now is it safe to take the
# running app down.

# 4a. Tear down any prior retired external-runtime agent from old installs.
LABEL="local.nativeagent.NativeAgentDaemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  echo "tearing down legacy LaunchAgent at $PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
fi
# Kill any lingering retired external-runtime process from the prior setup. Old installs launched
# it from the bundle (Contents/Resources/native_agentd.py); match that path.
# A pkill -f on "$ROOT/daemon/native_agentd.py" can match a sibling checkout
# that shares the repo-path prefix, so it's dropped here — the daemon this
# installer is replacing always launches from $APP_DEST, not the source tree.
pkill -f "$APP_DEST/Contents/Resources/native_agentd.py" 2>/dev/null || true

# 4b. Quit any running app
# `applicationWillTerminate` owns a bounded three-second drain for cognition,
# background loops, MCP children, Context Flow, and the installed-physiology
# clean-stop receipt. Sending pkill immediately after AppleScript used to race
# that drain and made an ordinary developer reinstall look like an unclean
# restart. Give the app one bounded grace window; retain the force-stop only as
# recovery for a wedged/ignored quit request.
osascript -e 'tell application "NativeAgent" to quit' 2>/dev/null || true
quit_deadline=$((SECONDS + 5))
while pgrep -x NativeAgentApp >/dev/null 2>&1 && (( SECONDS < quit_deadline )); do
  sleep 0.1
done
if pgrep -x NativeAgentApp >/dev/null 2>&1; then
  echo "[install_app.sh] graceful quit exceeded 5s; forcing NativeAgentApp stop"
  pkill -x NativeAgentApp 2>/dev/null || true
  sleep 1
fi

# 5. Atomic swap.
# HOTFIX 2026-06-03: the atomic-mv rollback trap previously ran from this
# point through EOF, which meant any failure AFTER the fresh bundle landed
# (notably the post-install `/usr/bin/open` step on launchd-163) would restore
# the OLD bundle — ~/Applications/ was forever stuck at the pre-cutover binary.
# Fix: scope the trap to ONLY the 2-line gap between the two mvs. The
# moment the new bundle is in place, clear the trap so later post-install
# failures (launchd-163, open errors) don't undo a successful install.
APP_OLD="${APP_DEST}.old.$$"
if [ -d "$APP_DEST" ]; then
    mv "$APP_DEST" "$APP_OLD"
    # Restore only if the SECOND mv (below) fails or we crash between them.
    trap '
        if [ -d "$APP_OLD" ] && [ ! -d "$APP_DEST" ]; then
            echo "[install_app.sh] mid-swap failure — restoring previous bundle"
            mv "$APP_OLD" "$APP_DEST"
            # The running app was already quit above — relaunch the restored
            # bundle so a mid-swap failure never leaves the app down.
            /usr/bin/open "$APP_DEST" 2>/dev/null || true
        fi
    ' EXIT ERR INT TERM HUP
fi
mv "$TEMP_BUNDLE" "$APP_DEST"
# Clear only the mid-swap trap. The previous bundle stays recoverable until
# the replacement proves its authenticated runtime identity and chat readiness.
trap - EXIT ERR INT TERM HUP

# N37: rotate legacy runtime log files if they exceed 5 MB. Keep up to 3 rotated copies
# (.1, .2, .3) so a single install can never destroy the previous two logs.
_rotate_log() {
  local log="$1"
  if [[ -f "$log" ]] && [[ $(stat -f%z "$log" 2>/dev/null || echo 0) -gt $((5 * 1024 * 1024)) ]]; then
    [ -f "${log}.2" ] && rm -f "${log}.3" && mv -f "${log}.2" "${log}.3"
    [ -f "${log}.1" ] && mv -f "${log}.1" "${log}.2"
    mv "$log" "${log}.1"
    echo "  rotated $(basename "$log") (>5 MB) → $(basename "$log").1"
  fi
}
_rotate_log "$DATA/logs/daemon.err.log"
_rotate_log "$DATA/logs/daemon.out.log"

# 6. Launch
# Readiness is proven through the authenticated local bridge and the exact
# build identity stamped above. A process existing is necessary but not a
# usable runtime: chat must be ready and the running revision/dirty bit must
# match the replacement bundle.
#
# HOTFIX 2026-06-03 launchd-163: `/usr/bin/open` exits 1 on launchd-163
# ("Launchd job spawn failed", RBSRequestErrorDomain=5) which is an OS-level
# launchd-cache issue independent of the bundle (bundle IS in place + valid).
# `set -e` was killing the script there, never reaching the pgrep fallback,
# so installs reported exit 1 even when the bundle landed cleanly. Make `open`
# non-fatal; if launchd refuses to spawn, exec the binary directly as fallback.
INSTALL_VERIFY_STARTED="$(date +%s)"
OPEN_OK=0
/usr/bin/open "$APP_DEST" 2>&1 && OPEN_OK=1 || true
echo
echo "Installed $APP_DEST"
if [[ "$OPEN_OK" != "1" ]]; then
  echo "[install_app.sh] /usr/bin/open returned non-zero (launchd-163 / OS cache);"
  echo "[install_app.sh] bundle IS in place + valid — falling back to direct exec."
  # Direct binary spawn — bypasses launchd's bundle-ID cache.
  ( "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 & ) || true
fi
echo "Swift runtime install — verifying authenticated readiness and source identity..."
if "$ROOT/script/verify_installed_runtime_ready.sh" \
    "$APP_DEST" "$INSTALL_SOURCE_REVISION" "$INSTALL_SOURCE_DIRTY" 20; then
  APP_PID="$(pgrep -fxn "$APP_DEST/Contents/MacOS/NativeAgentApp" || true)"
  echo "OK — NativeAgentApp ready (pid=$APP_PID)."
  trap - EXIT ERR INT TERM HUP
  rm -rf "$APP_OLD" 2>/dev/null || true
  exit 0
fi

echo "[install_app.sh] replacement failed authenticated readiness verification." >&2
osascript -e 'tell application "NativeAgent" to quit' 2>/dev/null || true
rollback_deadline=$((SECONDS + 5))
while pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 \
    && (( SECONDS < rollback_deadline )); do
  sleep 0.1
done
pkill -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" 2>/dev/null || true
if [[ -d "$APP_OLD" ]]; then
  FAILED_APP="${APP_DEST}.failed.$(date +%Y%m%d-%H%M%S)"
  mv "$APP_DEST" "$FAILED_APP"
  mv "$APP_OLD" "$APP_DEST"
  if ! /usr/bin/open "$APP_DEST" 2>/dev/null; then
    ( "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 & ) || true
  fi
  echo "[install_app.sh] restored the previous bundle; failed replacement retained at:" >&2
  echo "  $FAILED_APP" >&2
else
  echo "[install_app.sh] no previous bundle existed; failed fresh install retained at $APP_DEST." >&2
fi
trap - EXIT ERR INT TERM HUP
exit 1
