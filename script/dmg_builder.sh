#!/usr/bin/env bash
# RELEASE-2026-05-06: hand-rolled hdiutil DMG builder for NativeAgent
# No external deps (create-dmg not required).
# Usage: ./script/dmg_builder.sh
#   Env (optional): NATIVEAGENT_DEVELOPER_ID — for DMG codesign
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NativeAgent"

# RELEASE-2026-05-06: version from single source of truth
VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

# A2.1 round 2: --publish-appcast builds a DMG whose app CLAIMS a published
# update feed before the feed exists, so release.sh needs it born inside the
# dist/.pending-publish quarantine rather than under its ship-ready name. These
# two overrides are how it asks; unset, everything behaves exactly as before.
BUNDLE="${NATIVEAGENT_DMG_BUNDLE:-$ROOT/dist/$APP_NAME.app}"
DMG_OUT_DIR="${NATIVEAGENT_DMG_OUT_DIR:-$ROOT/dist}"
[[ -d "$DMG_OUT_DIR" ]] || { echo "ERROR: NATIVEAGENT_DMG_OUT_DIR does not exist: $DMG_OUT_DIR" >&2; exit 1; }
DMG_OUT_DIR="$(cd "$DMG_OUT_DIR" && pwd)"
DMG_OUT="$DMG_OUT_DIR/$APP_NAME-$VERSION.dmg"
# The temp RW image is a FULLY POPULATED, mountable copy of the release app. It
# used to be removed only on the success path, so a failed `hdiutil convert` (or
# a Ctrl-C) left dist/NativeAgent-tmp.dmg behind — a shippable disk image that
# matches dist/*.dmg and that release.sh's quarantine never saw. It now lives in
# the same (possibly quarantined) output dir and is removed by the EXIT trap.
TMP_DMG="$DMG_OUT_DIR/$APP_NAME-tmp.dmg"
VOLUME_NAME="NativeAgent $VERSION"
# Mount to a private mktemp dir (mirrors verify_release_artifact.sh) instead of
# /Volumes/<name>: a stale prior mount with a colliding volume name under
# /Volumes would otherwise be force-detached without confirming it's actually
# ours. A unique temp mountpoint can't collide with an unrelated volume.
MOUNT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-dmg-build.XXXXXX")"
MOUNT_POINT="$MOUNT_BASE/mount"
mkdir -p "$MOUNT_POINT"

echo "==> Building DMG: $DMG_OUT"

if [[ ! -d "$BUNDLE" ]]; then
  echo "ERROR: $BUNDLE not found. Run release.sh first." >&2
  exit 1
fi

# Clean up any prior artifacts
rm -f "$TMP_DMG" "$DMG_OUT"

# RELEASE-2026-05-06: step 1 — create writable temp DMG.
# Size from du with a PERCENTAGE margin, not a fixed +20 MB. 15% (floored at
# +20 MB) scales with the bundle and covers HFS+ overhead, the symlink, and
# .DS_Store.
APP_SIZE_KB=$(du -sk "$BUNDLE" | cut -f1)
MARGIN_KB=$(( APP_SIZE_KB * 15 / 100 ))
if [[ "$MARGIN_KB" -lt 20480 ]]; then
  MARGIN_KB=20480
fi
DMG_SIZE_KB=$(( APP_SIZE_KB + MARGIN_KB ))

echo "  Creating temp RW DMG (${DMG_SIZE_KB}k)..."
hdiutil create \
  -size "${DMG_SIZE_KB}k" \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -layout SPUD \
  -ov \
  "$TMP_DMG"

# RELEASE-2026-05-06: step 2 — mount and populate
echo "  Mounting temp DMG..."
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_POINT" -nobrowse -noverify

# Ensure unmount + temp-dir removal on exit/error
cleanup() {
  hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
  rm -rf "$MOUNT_BASE" 2>/dev/null || true
  # Never leave a mountable, fully-populated temp image on disk.
  rm -f "$TMP_DMG" 2>/dev/null || true
}
trap cleanup EXIT

# RELEASE-2026-05-06: step 3 — copy app and create Applications symlink
echo "  Copying $APP_NAME.app..."
cp -R "$BUNDLE" "$MOUNT_POINT/$APP_NAME.app"

echo "  Creating /Applications symlink..."
ln -sf /Applications "$MOUNT_POINT/Applications"

# RELEASE-2026-05-06: step 4 — set window layout via osascript (best-effort)
echo "  Setting DMG window layout..."
osascript <<APPLESCRIPT 2>/dev/null || echo "  (osascript layout skipped — non-critical)"
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 780, 420}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set position of item "$APP_NAME.app" of container window to {160, 160}
    set position of item "Applications" of container window to {420, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# RELEASE-2026-05-06: step 5 — detach (trap fires but we do it explicitly first for clean unmount)
sync
echo "  Detaching temp DMG..."
# The trap deliberately stays ARMED here (it used to be disarmed): the temp
# image is still on disk until `hdiutil convert` succeeds, and a failure in
# between must not leave it behind. cleanup() is idempotent.
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$MOUNT_BASE" 2>/dev/null || true

# RELEASE-2026-05-06: step 6 — convert to compressed read-only DMG
echo "  Converting to read-only compressed DMG..."
hdiutil convert "$TMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT"

rm -f "$TMP_DMG"

# RELEASE-2026-05-06: step 7 — codesign DMG if identity available.
# CROSS-VERSION MOUNT FIX (2026-07-04): a DMG codesigned by a NEWER macOS host
# (26.5) is rejected as "disk image is corrupted" at mount by an OLDER macOS
# (15.0) — the signature format the older DiskImageMounter validates is too new.
# Empirically confirmed: an UNSIGNED UDZO DMG mounts + installs + runs on 15,
# while the codesigned one does not. The app INSIDE stays fully signed +
# notarized + stapled (that's what Gatekeeper checks at launch), so an unsigned
# DMG wrapper is safe. Set NATIVEAGENT_SKIP_DMG_SIGN=1 to ship the unsigned DMG
# (and skip DMG-level notarize/staple in release.sh). See docs/build_plans/
# public-release-polish.md.
if [[ "${NATIVEAGENT_SKIP_DMG_SIGN:-0}" == "1" ]]; then
  echo "  Skipping DMG codesign (NATIVEAGENT_SKIP_DMG_SIGN=1 — unsigned DMG for"
  echo "  cross-macOS-version mount compatibility; app inside stays notarized)."
elif [[ -n "${NATIVEAGENT_DEVELOPER_ID:-}" ]]; then
  echo "  Codesigning DMG with Developer ID..."
  codesign --force \
    --sign "$NATIVEAGENT_DEVELOPER_ID" \
    --timestamp \
    "$DMG_OUT"
  codesign --verify --verbose=2 "$DMG_OUT"
  echo "  DMG signed."
else
  echo "  WARNING: NATIVEAGENT_DEVELOPER_ID not set — DMG is unsigned."
  echo "           Set the env var and re-run for a notarizable DMG."
fi

echo "  Verifying mounted release artifact..."
"$ROOT/script/verify_release_artifact.sh" --dmg "$DMG_OUT"

echo "==> DMG ready: $DMG_OUT"
