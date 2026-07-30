#!/usr/bin/env bash
# A2.1 round 2 (2026-07-24, gpt-5.5 BLOCKING): "no shippable artifact may outlive
# a failed publish".
#
# THE BUG THIS EXISTS TO KILL
#   release.sh --publish-appcast stamps SUFeedURL + NativeAgentUpdateFeedPublished
#   =true into the app BEFORE the appcast is generated and published (it must: the
#   enclosure signature has to cover the final notarized DMG bytes). So if the
#   publish step failed — bad NATIVEAGENT_APPCAST_PUBLISH_CMD, wrong credentials,
#   no network — release.sh exited nonzero but left
#   dist/NativeAgent-<v>.dmg signed, notarized, and CLAIMING a published feed,
#   with nothing at that feed URL. Any later automation or human that picks up
#   dist/*.dmg reships exactly the 404-polling app this whole task killed.
#
# THE INVARIANT
#   While a publish is pending, the ship-ready NAMES DO NOT EXIST. Artifacts are
#   born in dist/.pending-publish/ and are moved to dist/ only by an explicit
#   promotion call that runs after publication is VERIFIED live.
#
# WHY THAT HOLDS UNDER EVERY ABORT
#   Quarantine is the RESTING STATE and promotion is the only exit, so nothing
#   depends on cleanup code running:
#     * `set -e` exit / nonzero step  → promotion never runs → artifacts stay quarantined
#     * SIGINT / SIGTERM             → same; no trap required
#     * SIGKILL, panic, power loss mid-notarization → same; the filesystem is
#       already in the quarantined state, because that is where the bytes were
#       written in the first place
#   A trap-based cleanup would have the opposite property: it fails exactly when
#   the process dies hardest. There is deliberately no trap here.
#
# Usage:  source script/lib/release_quarantine.sh
#         release_quarantine_init "$QDIR" "publishing appcast for v1.2.3"
#         DMG="$(release_quarantine_take "$QDIR" "$DMG")"
#         ... publish ...
#         release_quarantine_promote "$QDIR" "$ROOT/dist"

# shellcheck disable=SC2034
RELEASE_QUARANTINE_LIB_LOADED=1

RELEASE_QUARANTINE_README=".QUARANTINE-DO-NOT-SHIP.txt"
# Only artifacts THIS run put in quarantine may be promoted. Without that, a
# v0.1.9 run that failed after quarantining would have its never-published
# artifacts promoted into dist/ by the next successful v0.2.0 publish — a
# different, unpublished build shipped on the strength of another's verification.
#
# The register lives in a FILE, not a shell array, on purpose: callers naturally
# write `DMG="$(release_quarantine_take ...)"`, and an array appended inside that
# command substitution is appended in a subshell and lost — promotion would then
# silently move nothing. A file survives the subshell.
RELEASE_QUARANTINE_MANIFEST_NAME=".QUARANTINE-MANIFEST"

# $1 — quarantine dir, $2 — human reason
release_quarantine_init() {
  local qdir="$1" reason="${2:-a release publish step is pending}"
  mkdir -p "$qdir" || return 1
  : > "$qdir/$RELEASE_QUARANTINE_MANIFEST_NAME" || return 1
  cat > "$qdir/$RELEASE_QUARANTINE_README" <<TXT
DO NOT SHIP ANYTHING IN THIS DIRECTORY.

Reason: $reason

These artifacts were signed and notarized, and the app inside them CLAIMS a
published Sparkle update feed (NativeAgentUpdateFeedPublished=true + SUFeedURL).
They are held here because that claim has not been proven true yet — the appcast
either has not been published or could not be verified live at its URL.

Shipping one of these gives every user a "Check for Updates…" button that
resolves into a 404. That is the exact bug the A2.1 work removed.

If you are looking at this file, the release FAILED after the DMG was built.
Fix the publish problem and re-run:

    ./script/release.sh --publish-appcast

A successful, verified publish moves these artifacts into dist/ automatically.
Nothing else should ever move them.
TXT
}

# Registers a name this run owns inside the quarantine dir, for artifacts that
# are BUILT there directly (the app bundle, its zip, the DMG) rather than moved.
# Building in place is the stronger form: the ship-ready name never exists at all,
# so there is no window — however short — where an abort leaves it behind.
# $1 — quarantine dir, $2 — basename inside it
release_quarantine_register() {
  local qdir="$1" base="$2"
  printf '%s\n' "$base" >> "$qdir/$RELEASE_QUARANTINE_MANIFEST_NAME" || return 1
  printf '%s\n' "$qdir/$base"
}

# Moves one path into quarantine and echoes its new location. Missing paths are
# skipped silently (echoing nothing) so callers can pass optional artifacts.
# $1 — quarantine dir, $2 — path to move
release_quarantine_take() {
  local qdir="$1" path="$2" base
  [[ -e "$path" ]] || return 0
  base="$(basename "$path")"
  rm -rf "$qdir/$base"
  mv "$path" "$qdir/$base" || return 1
  printf '%s\n' "$base" >> "$qdir/$RELEASE_QUARANTINE_MANIFEST_NAME" || return 1
  printf '%s\n' "$qdir/$base"
}

# Moves the artifacts THIS run registered into $2. Call ONLY after publication
# has been verified.
# $1 — quarantine dir, $2 — destination dir (usually dist/)
release_quarantine_promote() {
  local qdir="$1" dest="$2" base manifest
  [[ -d "$qdir" ]] || return 0
  [[ -d "$dest" ]] || { echo "release_quarantine_promote: no destination dir $dest" >&2; return 1; }
  manifest="$qdir/$RELEASE_QUARANTINE_MANIFEST_NAME"
  if [[ ! -s "$manifest" ]]; then
    echo "release_quarantine_promote: nothing was registered for promotion" >&2
    return 1
  fi
  # Quoted throughout: User's paths contain spaces. Only registered names move —
  # leftovers from an earlier failed run stay quarantined, deliberately.
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    [[ -e "$qdir/$base" ]] || continue
    rm -rf "$dest/$base"
    mv "$qdir/$base" "$dest/$base" || return 1
  done < "$manifest"
  rm -f "$manifest"
  rm -f "$qdir/$RELEASE_QUARANTINE_README"
  # rmdir, never `rm -rf $qdir`: an earlier run's unpublished artifacts may still
  # be in there, and they must be left alone rather than deleted or promoted.
  rmdir "$qdir" 2>/dev/null || {
    echo "NOTE: $qdir still holds artifacts from an earlier unpublished run;" >&2
    echo "      left in place — they were never published and must not ship." >&2
  }
}
