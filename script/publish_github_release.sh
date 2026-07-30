#!/usr/bin/env bash
# Publish the exact Sparkle appcast + DMG prepared by generate_appcast.sh as one
# GitHub Release. This command is intentionally release-host specific; signing,
# notarization, appcast generation, and post-publish HTTP verification remain
# owned by release.sh/generate_appcast.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "$2 is missing: $1"
}

REPOSITORY="${NATIVEAGENT_GITHUB_REPOSITORY:-}"
APPCAST="${NATIVEAGENT_PUBLISH_APPCAST:-}"
DMG="${NATIVEAGENT_PUBLISH_DMG:-}"
APPCAST_URL="${NATIVEAGENT_PUBLISH_APPCAST_URL:-}"
DOWNLOAD_URL="${NATIVEAGENT_DMG_DOWNLOAD_URL:-}"
TARGET="${NATIVEAGENT_GITHUB_TARGET_COMMIT:-}"

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "NATIVEAGENT_GITHUB_REPOSITORY must be owner/repository."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"

require_file "$APPCAST" "NATIVEAGENT_PUBLISH_APPCAST"
require_file "$DMG" "NATIVEAGENT_PUBLISH_DMG"

VISIBILITY="$(gh api "repos/$REPOSITORY" --jq '.visibility' 2>/dev/null || true)"
[[ "$VISIBILITY" == "public" ]] \
  || fail "$REPOSITORY is not public. Sparkle clients cannot authenticate to a private release feed."

VERSION="$(xmllint --xpath \
  'string((//*[local-name()="version"])[1])' "$APPCAST" 2>/dev/null || true)"
[[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)+$ ]] \
  || fail "could not read a valid Sparkle version from $APPCAST"

TAG="v$VERSION"
DMG_NAME="$(basename "$DMG")"
EXPECTED_DMG_NAME="NativeAgent-$VERSION.dmg"
[[ "$DMG_NAME" == "$EXPECTED_DMG_NAME" ]] \
  || fail "DMG name '$DMG_NAME' does not match feed version $VERSION."

EXPECTED_APPCAST_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
EXPECTED_DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$DMG_NAME"
[[ "$APPCAST_URL" == "$EXPECTED_APPCAST_URL" ]] \
  || fail "appcast URL must be $EXPECTED_APPCAST_URL (got $APPCAST_URL)"
[[ "$DOWNLOAD_URL" == "$EXPECTED_DOWNLOAD_URL" ]] \
  || fail "DMG URL must be $EXPECTED_DOWNLOAD_URL (got $DOWNLOAD_URL)"

HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "release source is not a Git checkout."
TARGET="${TARGET:-$HEAD}"
[[ "$TARGET" == "$HEAD" ]] \
  || fail "release target $TARGET does not match the source/artifact commit $HEAD."
REMOTE_TARGET="$(gh api "repos/$REPOSITORY/commits/$TARGET" --jq '.sha' 2>/dev/null || true)"
[[ "$REMOTE_TARGET" == "$TARGET" ]] \
  || fail "source commit $TARGET is not present in $REPOSITORY. Publish the reviewed source first."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-github-release.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

verify_release_assets() {
  local destination="$TMP/download"
  rm -rf "$destination"
  mkdir -p "$destination"
  gh release download "$TAG" \
    --repo "$REPOSITORY" \
    --pattern appcast.xml \
    --pattern "$DMG_NAME" \
    --dir "$destination" >/dev/null
  cmp -s "$APPCAST" "$destination/appcast.xml" \
    || fail "GitHub release $TAG has a different appcast.xml."
  cmp -s "$DMG" "$destination/$DMG_NAME" \
    || fail "GitHub release $TAG has different DMG bytes."
}

# Idempotent retry: a prior successful publish may have completed before the
# caller's final HTTP verification returned. Accept only byte-identical assets.
if RELEASE_JSON="$(gh api "repos/$REPOSITORY/releases/tags/$TAG" 2>/dev/null)"; then
  DRAFT="$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')"
  [[ "$DRAFT" == "false" ]] \
    || fail "a draft release already exists for $TAG. Inspect or delete that draft before retrying."
  verify_release_assets
  echo "==> GitHub release $TAG already exists with the exact appcast and DMG."
  exit 0
fi

NOTES_ARGS=( --generate-notes )
if [[ -n "${NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE:-}" ]]; then
  require_file "$NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE" "NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE"
  NOTES_ARGS=( --notes-file "$NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE" )
fi

echo "==> Creating draft GitHub release $TAG"
gh release create "$TAG" \
  "$APPCAST#Sparkle update feed" \
  "$DMG#NativeAgent $VERSION for macOS" \
  --repo "$REPOSITORY" \
  --target "$TARGET" \
  --title "NativeAgent $VERSION" \
  --draft \
  "${NOTES_ARGS[@]}" >/dev/null

# Draft is the fail-safe resting state. Verify the exact uploaded bytes through
# GitHub before making the release visible or eligible as "latest".
verify_release_assets
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest >/dev/null

RELEASE_JSON="$(gh api "repos/$REPOSITORY/releases/tags/$TAG")"
[[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')" == "false" ]] \
  || fail "GitHub release $TAG is still a draft after publication."
[[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.prerelease')" == "false" ]] \
  || fail "GitHub release $TAG unexpectedly became a prerelease."

echo "==> GitHub release published: https://github.com/$REPOSITORY/releases/tag/$TAG"
