#!/usr/bin/env bash
# Swift-native NativeAgent.app installer.
#
# NativeAgent.app owns its Swift runtime and uses SMAppService for login startup.
#
# Build, sign and verify the replacement before stopping the running app:
#   1. Build the Swift app bundle (build_and_run.sh --build-only: no kill,
#      no launch).
#   2. Copy the signed dist/NativeAgent.app → temp bundle next to ~/Applications.
#   3. Verify the transferred signature (--deep --strict).
#   4. Remove the Python LaunchAgent and quit the running NativeAgent.app.
#   5. Atomically swap the temp bundle into ~/Applications/NativeAgent.app.
#   6. Launch and prove authenticated chat/source readiness; only then delete
#      the previous bundle. Failed readiness restores the prior install.
#
# After this, you double-click ~/Applications/NativeAgent.app to start. The
# app stays in the menu bar.

set -euo pipefail
# Report the failing command and line.
trap 'echo "[install_app.sh] FAILED line $LINENO: $BASH_COMMAND" >&2' ERR

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
source "$ROOT/script/lib/development_bundle_validation.sh"
source "$ROOT/script/lib/release_symbols.sh"
source "$ROOT/script/lib/build_source_inventory.sh"

APP_NAME="NativeAgent"
# The installed app is used for everyday conversations. Keep ordinary installs
# optimized; an explicit debug override remains available for debugger work.
export NATIVEAGENT_BUILD_CONFIG="${NATIVEAGENT_BUILD_CONFIG:-release}"
APP_DEST="$HOME/Applications/$APP_NAME.app"
FORCE_CHECKOUT_SWITCH="${FORCE_CHECKOUT_SWITCH:-0}"

# Installing always checks the live bundle's checkout before building its replacement.
nativeagent_require_installed_checkout "$APP_DEST" "$ROOT" "$FORCE_CHECKOUT_SWITCH" \
  "[install_app.sh]" "Reinstalling would repoint the live app's data root and bounce it."

if [ "${NATIVE_AGENT_INSTALL_WITH_ST:-0}" = "1" ]; then
    echo "[install_app.sh] ERROR: NATIVE_AGENT_INSTALL_WITH_ST is retired. NativeAgent bundles zero Python; embeddings must use the Swift/CoreML path." >&2
    exit 2
fi
# Rotate logs in the checkout's live data directory.
DATA="$ROOT/data"

# 0. Initialize persona/ and data/ for first-time cloners.
"$ROOT/script/init_persona.sh"

# 1. Build without stopping or launching the app; keep it running until the replacement is signed and verified.
"$ROOT/script/build_and_run.sh" --build-only

# 2. Stage fresh bundle — copy to temp then mv for atomic swap
mkdir -p "$HOME/Applications" "$DATA/logs"
DIST_BUNDLE="$ROOT/dist/$APP_NAME.app"
# The helper and its kit are one release; refuse an incomplete builder result
# before staging or touching the running installation.
if [[ ! -x "$DIST_BUNDLE/Contents/MacOS/NativeAgentSenseHost" \
   || ! -f "$DIST_BUNDLE/Contents/Resources/Senses/sense.js" \
   || ! -f "$DIST_BUNDLE/Contents/Resources/Senses/builtin.json" \
   || ! -f "$DIST_BUNDLE/Contents/Resources/abilities/turn.js" ]]; then
    echo "[install_app.sh] ERROR: built bundle is missing the Senses helper, authoring kit or seed turn part." >&2
    exit 1
fi
TEMP_BUNDLE="$(dirname "$APP_DEST")/.NativeAgent.app.tmp.$$"
APP_OLD="${APP_DEST}.old.$$"
trap '
    # The previous bundle comes back before anything else is cleaned: a failed
    # cleanup under set -e must never strand it at .old.
    if [ -d "$APP_OLD" ] && [ ! -d "$APP_DEST" ]; then
        echo "[install_app.sh] mid-swap failure — restoring previous bundle"
        mv "$APP_OLD" "$APP_DEST"
        /usr/bin/open "$APP_DEST" 2>/dev/null || true
    fi
    rm -rf "$TEMP_BUNDLE" || true
' EXIT
trap 'exit 1' INT TERM HUP
rm -rf "$TEMP_BUNDLE"
cp -R "$DIST_BUNDLE" "$TEMP_BUNDLE"
xattr -dr com.apple.quarantine "$TEMP_BUNDLE" 2>/dev/null || true

# Preserve the builder's version and provenance, including its internal-build
# suffix. Readiness must compare against those bytes, never a later Git HEAD.
INSTALL_SOURCE_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :NativeAgentSourceRevision' "$TEMP_BUNDLE/Contents/Info.plist")"
# Keep each product/UUID set once; revisions retain references for symbolication.
DSYM_ARCHIVE="$HOME/Library/Logs/NativeAgent-dsyms"
case "$NATIVEAGENT_BUILD_CONFIG" in
    debug) DSYM_PRODUCTS="$ROOT/DerivedData/Build/Products/Debug" ;;
    release) DSYM_PRODUCTS="$ROOT/DerivedData/Build/Products/Release" ;;
esac
DSYM_MANIFEST="$TEMP_BUNDLE/.symbols.tsv"
: > "$DSYM_MANIFEST"
for dsym in "$DSYM_PRODUCTS"/*.dSYM; do
    [[ -d "$dsym" ]] || continue
    for dwarf in "$dsym/Contents/Resources/DWARF/"*; do
        binary="$(find "$TEMP_BUNDLE/Contents" -type f -name "$(basename "$dwarf")" -print -quit)"
        [[ -n "$binary" ]] || continue 2
        symbol_uuids="$(release_executable_uuids "$dwarf")"
        binary_uuids="$(release_executable_uuids "$binary")"
        if [[ -z "$symbol_uuids" || "$symbol_uuids" != "$binary_uuids" ]]; then
            echo "[install_app.sh] ERROR: symbols do not match staged $binary; rebuild $NATIVEAGENT_BUILD_CONFIG." >&2
            exit 1
        fi
    done
    uuid_set="$(release_executable_uuids "$dsym")"
    uuid_key="$(printf '%s\n' "$uuid_set" | shasum -a 256 | awk '{print $1}')"
    retained="$DSYM_ARCHIVE/objects/$(basename "$dsym")/$uuid_key/$(basename "$dsym")"
    if [[ ! -e "$retained" ]]; then
        # Older installs archived one dSYM per revision directory; the keyed
        # objects/ store was checked above and holds no dSYM at this depth.
        for candidate in "$DSYM_ARCHIVE"/*/"$(basename "$dsym")"; do
            [[ -d "$candidate" && "$candidate" != "$DSYM_ARCHIVE/objects/"* ]] || continue
            candidate_uuids="$(release_executable_uuids "$candidate")"
            if [[ "$candidate_uuids" == "$uuid_set" ]]; then
                retained="$candidate"
                break
            fi
        done
    fi
    symbol_ref="${retained#"$DSYM_ARCHIVE/"}"
    if [[ -e "$retained" ]]; then
        if ! diff -qr "$dsym/Contents/Resources/DWARF" "$retained/Contents/Resources/DWARF"; then
            echo "[install_app.sh] ERROR: retained symbols differ for $uuid_set; inspect $retained before installing." >&2
            exit 1
        fi
        echo "[symbols] reused $symbol_ref"
    else
        mkdir -p "$(dirname "$retained")"
        ditto "$dsym" "$TEMP_BUNDLE/.symbols.dSYM"
        mv "$TEMP_BUNDLE/.symbols.dSYM" "$retained"
        echo "[symbols] archived $symbol_ref"
    fi
    printf '%s\t%s\n' "$(basename "$dsym")" "$symbol_ref" >> "$DSYM_MANIFEST"
done
if [[ ! -s "$DSYM_MANIFEST" ]]; then
    echo "[install_app.sh] ERROR: no symbols match the staged app; rebuild $NATIVEAGENT_BUILD_CONFIG with dSYMs." >&2
    exit 1
fi
mkdir -p "$DSYM_ARCHIVE/$INSTALL_SOURCE_REVISION"
if [[ -f "$DSYM_ARCHIVE/$INSTALL_SOURCE_REVISION/manifest.tsv" ]]; then
    cat "$DSYM_ARCHIVE/$INSTALL_SOURCE_REVISION/manifest.tsv" >> "$DSYM_MANIFEST"
fi
LC_ALL=C sort -u "$DSYM_MANIFEST" -o "$DSYM_MANIFEST"
mv "$DSYM_MANIFEST" "$DSYM_ARCHIVE/$INSTALL_SOURCE_REVISION/manifest.tsv"
INSTALL_SOURCE_CONTENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :NativeAgentSourceContentID' "$TEMP_BUNDLE/Contents/Info.plist")"
if [[ "$INSTALL_SOURCE_CONTENT_ID" != "$(nativeagent_source_content_id "$ROOT")" ]] || \
   [[ "$(cat "$TEMP_BUNDLE/Contents/Resources/VERSION_SHA")" != "$INSTALL_SOURCE_REVISION" ]]; then
    echo "[install_app.sh] ERROR: builder provenance does not match the captured source; refusing installation." >&2
    exit 1
fi

nativeagent_assert_no_python_artifacts "$TEMP_BUNDLE" "[install_app.sh]" present install

# 3. Verify the builder's sealed bundle before atomic swap.
codesign --verify --deep --strict --verbose=2 "$TEMP_BUNDLE"

# ─── POINT OF NO RETURN ────────────────────────────────────────────────────
# Everything above operates on the temp bundle only; any failure up there
# exits nonzero with the running app untouched. The replacement bundle is now
# built, signed, and codesign-verified — only now is it safe to take the
# running app down.

# 4a. Remove the installed Python LaunchAgent.
LABEL="local.nativeagent.NativeAgentDaemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  echo "tearing down legacy LaunchAgent at $PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
fi
# Match the installed bundle's Python process; source-path prefixes can select sibling checkouts.
pkill -f "$APP_DEST/Contents/Resources/native_agentd.py" 2>/dev/null || true

# 4b. Quit any running app
# Allow 30s for the app's 20s turn wait and 3s shutdown drain before force-stop.
APP_EXECUTABLE_PATTERN="$(printf '%s' "$APP_DEST/Contents/MacOS/NativeAgentApp" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
APP_PROCESS_PATTERN="$APP_EXECUTABLE_PATTERN([[:space:]].*)?"
APP_HELPER_PATTERN="^[0-9]+[[:space:]]+$APP_EXECUTABLE_PATTERN[[:space:]]+--nativeagent-(install-helper|relaunch-after-exit)([[:space:]]|$)"
# The same executable also hosts detached helpers. They own installation or
# relaunch across app exit, so every quit/wait/stop selects only app-mode PIDs.
_nativeagent_app_pids() {
  pgrep -flx "$APP_PROCESS_PATTERN" 2>/dev/null \
    | grep -Ev "$APP_HELPER_PATTERN" \
    | awk '{ print $1 }'
}
# Quit by PID so LaunchServices cannot resolve the request to a different bundle.
_quit_nativeagent() {
  local pid
  for pid in $(_nativeagent_app_pids); do
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 || true
  done
}
_stop_nativeagent() {
  local pid
  for pid in $(_nativeagent_app_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
_quit_nativeagent
quit_deadline=$((SECONDS + 30))
while _nativeagent_app_pids >/dev/null 2>&1 && (( SECONDS < quit_deadline )); do
  sleep 0.1
done
if _nativeagent_app_pids >/dev/null 2>&1; then
  echo "[install_app.sh] graceful quit exceeded 30s; forcing NativeAgentApp stop"
  # Stop only this bundle's app-mode processes.
  _stop_nativeagent
fi
# Wait for app-mode processes to exit before swapping bundles or launching a new instance.
gone_deadline=$((SECONDS + 15))
while _nativeagent_app_pids >/dev/null 2>&1 && (( SECONDS < gone_deadline )); do
  sleep 0.2
done
if _nativeagent_app_pids >/dev/null 2>&1; then
  echo "[install_app.sh] ERROR: NativeAgentApp still running after forced stop; refusing to launch a duplicate." >&2
  exit 1
fi

# 5. Atomic swap.
if [ -d "$APP_DEST" ]; then
    mv "$APP_DEST" "$APP_OLD"
fi
mv "$TEMP_BUNDLE" "$APP_DEST"
# Staging is now installed. The previous bundle stays recoverable until
# the replacement proves its authenticated runtime identity and chat readiness.
trap - EXIT ERR INT TERM HUP

# Rotate logs over 5 MB, keeping three copies.
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
# Register the bundle, launch through LaunchServices, and retry once with open -n.
# Bundle launches preserve macOS Accessibility/TCC attribution.
# Authenticated bridge readiness must prove chat is ready and the running
# content identity matches the replacement bundle.
INSTALL_VERIFY_STARTED="$(date +%s)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

_wait_for_nativeagent_launch() { # $1 = bounded seconds
  local deadline=$((SECONDS + $1))
  while ! pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1 \
      && (( SECONDS < deadline )); do
    sleep 0.25
  done
  pgrep -fx "$APP_DEST/Contents/MacOS/NativeAgentApp" >/dev/null 2>&1
}

_launch_nativeagent_bundle() {
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
  /usr/bin/open "$APP_DEST" 2>&1 || true
  if _wait_for_nativeagent_launch 10; then
    return 0
  fi

  echo "[install_app.sh] no NativeAgentApp process 10s after the first bundle launch; retrying through LaunchServices"
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_DEST" 2>&1 || true
  _wait_for_nativeagent_launch 20
}

echo
echo "Installed $APP_DEST"
INSTALL_LAUNCH_OK=0
if _launch_nativeagent_bundle; then
  INSTALL_LAUNCH_OK=1
else
  echo "[install_app.sh] LaunchServices could not start the replacement bundle; refusing a direct executable launch because it can lose macOS TCC attribution." >&2
fi
echo "Swift runtime install — verifying authenticated readiness and source identity..."
_verify_ready() {
  [[ "$INSTALL_LAUNCH_OK" == "1" ]] && "$ROOT/script/verify_installed_runtime_ready.sh" \
    "$APP_DEST" "$INSTALL_SOURCE_CONTENT_ID" 45
}
# Failed readiness restores the previous bundle without another replacement launch attempt.
INSTALL_READY=0
if _verify_ready; then INSTALL_READY=1; fi
if [[ "$INSTALL_READY" == "1" ]]; then
  APP_PID="$(pgrep -fxn "$APP_DEST/Contents/MacOS/NativeAgentApp" || true)"
  echo "OK — NativeAgentApp ready (pid=$APP_PID)."
  # Install receipts are opt-in via NA_INSTALL_RECEIPT and sent only after readiness.
  # Resolve the authenticated bridge address and token from its descriptor.
  if [ -n "${NA_INSTALL_RECEIPT:-}" ] && command -v jq >/dev/null 2>&1 \
      && source "$ROOT/script/lib/nativeagent_bridge.sh" && nativeagent_bridge_resolve; then
    _na_sha=$(git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    # Send the receipt synchronously before the installer exits.
    curl -sS --max-time 30 -X POST "$BASE_URL/claude/message" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "[install_app.sh] Install receipt, posted by the install script itself, not by a person: build $_na_sha is running as pid $APP_PID." --arg s install_app.sh '{text:$t,sender:$s}')" \
      >/dev/null 2>&1 || true
  fi
  trap - EXIT ERR INT TERM HUP
  rm -rf "$APP_OLD" 2>/dev/null || true
  # A good install supersedes every earlier failed replacement kept for triage.
  rm -rf "${APP_DEST:?}".failed.* 2>/dev/null || true
  exit 0
fi

echo "[install_app.sh] replacement failed authenticated readiness verification." >&2
_quit_nativeagent
rollback_deadline=$((SECONDS + 5))
while _nativeagent_app_pids >/dev/null 2>&1 \
    && (( SECONDS < rollback_deadline )); do
  sleep 0.1
done
_stop_nativeagent
if [[ -d "$APP_OLD" ]]; then
  FAILED_APP="${APP_DEST}.failed.$(date +%Y%m%d-%H%M%S)"
  mv "$APP_DEST" "$FAILED_APP"
  mv "$APP_OLD" "$APP_DEST"
  # The restored bundle uses the same LaunchServices rule; report launch failure.
  if ! _launch_nativeagent_bundle; then
    echo "[install_app.sh] WARNING: restored the previous bundle, but LaunchServices could not start it." >&2
  fi
  echo "[install_app.sh] restored the previous bundle; failed replacement retained at:" >&2
  echo "  $FAILED_APP" >&2
else
  echo "[install_app.sh] no previous bundle existed; failed fresh install retained at $APP_DEST." >&2
fi
trap - EXIT ERR INT TERM HUP
exit 1
