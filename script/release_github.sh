#!/usr/bin/env bash
# One-command public NativeAgent release to GitHub Releases:
# clean public source -> Developer ID/notarized app -> signed Sparkle feed ->
# draft asset verification -> published release -> unauthenticated live fetch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="release"
if [[ "${1:-}" == "--preflight" ]]; then
  MODE="preflight"
  shift
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--preflight]" >&2; exit 2; }

failures=()
note_failure() {
  failures+=( "$1" )
  echo "BLOCKED: $1" >&2
}

PUBLIC_DEVICE_SYNC="${NATIVEAGENT_PUBLIC_DEVICE_SYNC:-cloudkit}"
case "$PUBLIC_DEVICE_SYNC" in
  cloudkit|none) ;;
  *) note_failure "NATIVEAGENT_PUBLIC_DEVICE_SYNC must be cloudkit or none." ;;
esac

MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"
BACKGROUND_TASK_PREFIX="${NATIVEAGENT_BACKGROUND_TASK_PREFIX:-io.github.embwl0x.nativeagent}"
ICLOUD_CONTAINER_ID="${NATIVEAGENT_ICLOUD_CONTAINER_ID:-iCloud.io.github.embwl0x.nativeagent}"
MOBILE_SOURCE_KEY="${NATIVEAGENT_MOBILE_SOURCE_KEY:-mobile_app}"
RELEASE_ENTITLEMENTS="${NATIVEAGENT_RELEASE_ENTITLEMENTS:-}"
PROVISIONING_PROFILE="${NATIVEAGENT_PROVISIONING_PROFILE:-}"
PRODUCTION_CLOUDKIT_SCHEMA="${NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA:-}"
PRIVACY_DENYLIST_FILE="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-}"

if [[ -z "$MAC_BUNDLE_ID" || "$MAC_BUNDLE_ID" == com.example.* ]]; then
  note_failure "set NATIVEAGENT_MAC_BUNDLE_ID to the stable public Mac bundle identifier."
fi

if [[ -z "${NATIVEAGENT_LOCAL_IDENTITY_RE:-}" && -z "${NATIVEAGENT_PRIVACY_RE:-}" ]]; then
  [[ -r "$PRIVACY_DENYLIST_FILE" ]] \
    || note_failure "set NATIVEAGENT_PRIVACY_DENYLIST_FILE to the ignored maintainer privacy denylist."
fi
if [[ -z "$BACKGROUND_TASK_PREFIX" || "$BACKGROUND_TASK_PREFIX" == com.example.* ]]; then
  note_failure "set NATIVEAGENT_BACKGROUND_TASK_PREFIX to the stable public background-task namespace."
fi
if [[ "$PUBLIC_DEVICE_SYNC" == "cloudkit" ]]; then
  if [[ -z "$ICLOUD_CONTAINER_ID" || "$ICLOUD_CONTAINER_ID" == iCloud.com.example.* ]]; then
    note_failure "set NATIVEAGENT_ICLOUD_CONTAINER_ID to the production CloudKit container."
  fi
  [[ "$MOBILE_SOURCE_KEY" == "mobile_app" ]] \
    || note_failure "public CloudKit releases require NATIVEAGENT_MOBILE_SOURCE_KEY=mobile_app."
  [[ -r "$RELEASE_ENTITLEMENTS" ]] \
    || note_failure "set NATIVEAGENT_RELEASE_ENTITLEMENTS to the maintainer CloudKit-only production entitlements."
  [[ -r "$PROVISIONING_PROFILE" ]] \
    || note_failure "set NATIVEAGENT_PROVISIONING_PROFILE to the matching Developer ID CloudKit profile."
  if [[ ! -r "$PRODUCTION_CLOUDKIT_SCHEMA" ]]; then
    note_failure "set NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA to a fresh production cktool export."
  else
    for required_type in NAChatMessage NANotification NAPairingDevice NAStatus; do
      grep -Eq "^[[:space:]]*RECORD TYPE $required_type[[:space:]]*\\(" \
        "$PRODUCTION_CLOUDKIT_SCHEMA" \
        || note_failure "production CloudKit schema is missing $required_type."
    done
  fi
fi

command -v gh >/dev/null 2>&1 || note_failure "GitHub CLI (gh) is required."
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  note_failure "GitHub CLI is not authenticated; run: gh auth login"
fi

REPOSITORY="${NATIVEAGENT_GITHUB_REPOSITORY:-}"
if [[ -z "$REPOSITORY" ]] && command -v gh >/dev/null 2>&1; then
  REPOSITORY="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#[.]git$##' || true)"
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  note_failure "set NATIVEAGENT_GITHUB_REPOSITORY=owner/repository"
else
  VISIBILITY="$(gh api "repos/$REPOSITORY" --jq '.visibility' 2>/dev/null || true)"
  [[ "$VISIBILITY" == "public" ]] \
    || note_failure "$REPOSITORY must be public before publishing an unauthenticated update feed."
fi

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || note_failure "release source is not a Git checkout."
[[ -z "$DIRTY" ]] || note_failure "release source is dirty; commit the exact release first."
if [[ "$REPOSITORY" =~ / && "$HEAD" =~ ^[0-9a-f]{40}$ ]]; then
  REMOTE_HEAD="$(gh api "repos/$REPOSITORY/commits/$HEAD" --jq '.sha' 2>/dev/null || true)"
  [[ "$REMOTE_HEAD" == "$HEAD" ]] \
    || note_failure "commit $HEAD is not present in $REPOSITORY; publish source before the binary release."
fi

SPARKLE_PRIVATE_KEY="${NATIVEAGENT_SPARKLE_ED_PRIV_KEY:-$HOME/.config/nativeagent/sparkle_ed_priv.key}"
if [[ ! -r "$SPARKLE_PRIVATE_KEY" ]]; then
  note_failure "Sparkle private key is missing; run ./script/sparkle_keygen.sh once."
  SPARKLE_PUBLIC_KEY=""
else
  SPARKLE_PUBLIC_KEY="$("$ROOT/script/sparkle_ed_public_key.swift" "$SPARKLE_PRIVATE_KEY" 2>/dev/null || true)"
  BYTES="$(printf '%s' "$SPARKLE_PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d '[:space:]')"
  [[ "$BYTES" == "32" ]] || note_failure "Sparkle release key is not a valid 32-byte EdDSA key."
fi

DEVELOPER_ID="${NATIVEAGENT_DEVELOPER_ID:-}"
if [[ -z "$DEVELOPER_ID" ]]; then
  mapfile=()
  while IFS= read -r line; do mapfile+=( "$line" ); done < <(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p'
  )
  if [[ ${#mapfile[@]} -eq 1 ]]; then
    DEVELOPER_ID="${mapfile[0]}"
  else
    note_failure "set NATIVEAGENT_DEVELOPER_ID to one Developer ID Application identity."
  fi
fi

TEAM_ID="${NATIVEAGENT_TEAM_ID:-}"
if [[ -z "$TEAM_ID" && "$DEVELOPER_ID" =~ \(([A-Z0-9]{10})\)$ ]]; then
  TEAM_ID="${BASH_REMATCH[1]}"
fi
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || note_failure "set NATIVEAGENT_TEAM_ID to the 10-character Apple team ID."

if [[ -z "${NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  if [[ -z "${NATIVEAGENT_APPLE_ID:-}" || -z "${NATIVEAGENT_NOTARIZATION_PASSWORD:-}" ]]; then
    note_failure "store a notarytool keychain profile and set NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE (recommended), or set Apple ID notarization credentials."
  fi
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo "" >&2
  echo "NativeAgent GitHub release preflight found ${#failures[@]} blocker(s)." >&2
  exit 1
fi

echo "READY: GitHub release prerequisites are present for NativeAgent $VERSION."
[[ "$MODE" == "release" ]] || exit 0

APPCAST_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
DMG_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/NativeAgent-$VERSION.dmg"
RELEASE_PAGE_URL="https://github.com/$REPOSITORY/releases/tag/v$VERSION"
printf -v PUBLISH_COMMAND '%q' "$ROOT/script/publish_github_release.sh"

export NATIVEAGENT_GITHUB_REPOSITORY="$REPOSITORY"
export NATIVEAGENT_GITHUB_TARGET_COMMIT="$HEAD"
export NATIVEAGENT_DEVELOPER_ID="$DEVELOPER_ID"
export NATIVEAGENT_TEAM_ID="$TEAM_ID"
export NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$SPARKLE_PRIVATE_KEY"
export NATIVEAGENT_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"
export NATIVEAGENT_APPCAST_URL="$APPCAST_URL"
export NATIVEAGENT_DMG_DOWNLOAD_URL="$DMG_URL"
export NATIVEAGENT_RELEASE_PAGE_URL="$RELEASE_PAGE_URL"
export NATIVEAGENT_APPCAST_PUBLISH_CMD="$PUBLISH_COMMAND"
export NATIVEAGENT_MAC_BUNDLE_ID="$MAC_BUNDLE_ID"
export NATIVEAGENT_BACKGROUND_TASK_PREFIX="$BACKGROUND_TASK_PREFIX"
export NATIVEAGENT_ICLOUD_CONTAINER_ID="$ICLOUD_CONTAINER_ID"
export NATIVEAGENT_MOBILE_SOURCE_KEY="$MOBILE_SOURCE_KEY"
export NATIVEAGENT_RELEASE_ENTITLEMENTS="$RELEASE_ENTITLEMENTS"
export NATIVEAGENT_PROVISIONING_PROFILE="$PROVISIONING_PROFILE"
export NATIVEAGENT_ICLOUD_BUILD="$PUBLIC_DEVICE_SYNC"
export NATIVEAGENT_SKIP_DMG_SIGN=1

exec "$ROOT/script/release.sh" --publish-appcast
