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
# shellcheck source=lib/development_bundle_signing.sh
source "$ROOT/script/lib/development_bundle_signing.sh"

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
NATIVEAGENT_MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"

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

# 3. Re-codesign with entitlements (on temp bundle before atomic swap). The
# shared owner keeps this second pass identical to build_and_run.sh.
nativeagent_sign_development_bundle \
  "$TEMP_BUNDLE" \
  "$ROOT" \
  "$NATIVEAGENT_MAC_BUNDLE_ID" \
  "[install_app.sh]"

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
#
# HOTFIX 2026-08-14 stale-LS-unit: `open` can also exit ZERO and launch
# NOTHING. The atomic mv in step 5 invalidates the LaunchServices unit for
# $APP_DEST; `open` then resolves the path to the dead unit, logs
# "Failed to get unit NNNNN from store" + "LAUNCH: Asking CSUI to launch 0
# items", and returns success. Observed 2026-08-14 16:18:06 — runningboardd
# recorded ZERO launch jobs for the bundle in the following 20s, so readiness
# failed on "installed executable is not running" and a perfectly good build
# was rolled back. Exit status of `open` is therefore NOT proof of a launch:
# re-register the swapped-in bundle first, then prove a process appeared and
# fall back to direct exec if it did not.
INSTALL_VERIFY_STARTED="$(date +%s)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
/usr/bin/open "$APP_DEST" 2>&1 || true
echo
echo "Installed $APP_DEST"
launch_deadline=$((SECONDS + 10))
while ! pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 \
    && (( SECONDS < launch_deadline )); do
  sleep 0.25
done
if ! pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1; then
  echo "[install_app.sh] no NativeAgentApp process 10s after /usr/bin/open"
  echo "[install_app.sh] (launchd-163 or stale LaunchServices unit — bundle IS in"
  echo "[install_app.sh] place + valid); falling back to direct exec."
  # Direct binary spawn — bypasses launchd's bundle-ID cache entirely.
  ( "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 & ) || true
fi
echo "Swift runtime install — verifying authenticated readiness and source identity..."
if "$ROOT/script/verify_installed_runtime_ready.sh" \
    "$APP_DEST" "$INSTALL_SOURCE_REVISION" "$INSTALL_SOURCE_DIRTY" 45; then
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
  # Same stale-LaunchServices-unit hazard as the install launch above: this mv
  # invalidates the unit too, and `open` can exit 0 having launched nothing.
  # Prove a process appeared rather than trusting the exit status — a rollback
  # that silently leaves User with no running app is the worst outcome here.
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
  /usr/bin/open "$APP_DEST" 2>/dev/null || true
  restore_deadline=$((SECONDS + 10))
  while ! pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 \
      && (( SECONDS < restore_deadline )); do
    sleep 0.25
  done
  if ! pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1; then
    ( "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 & ) || true
  fi
  echo "[install_app.sh] restored the previous bundle; failed replacement retained at:" >&2
  echo "  $FAILED_APP" >&2
else
  echo "[install_app.sh] no previous bundle existed; failed fresh install retained at $APP_DEST." >&2
fi
trap - EXIT ERR INT TERM HUP
exit 1
