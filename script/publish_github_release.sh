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
TEST_RECEIPT="${NATIVEAGENT_PUBLISH_TEST_RECEIPT:-}"
ATTESTATION="${NATIVEAGENT_PUBLISH_ATTESTATION:-}"
APPCAST_URL="${NATIVEAGENT_PUBLISH_APPCAST_URL:-}"
DOWNLOAD_URL="${NATIVEAGENT_DMG_DOWNLOAD_URL:-}"
TARGET="${NATIVEAGENT_GITHUB_TARGET_COMMIT:-}"

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "NATIVEAGENT_GITHUB_REPOSITORY must be owner/repository."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."
command -v shasum >/dev/null 2>&1 || fail "shasum is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"

require_file "$APPCAST" "NATIVEAGENT_PUBLISH_APPCAST"
require_file "$DMG" "NATIVEAGENT_PUBLISH_DMG"
require_file "$TEST_RECEIPT" "NATIVEAGENT_PUBLISH_TEST_RECEIPT"
require_file "$ATTESTATION" "NATIVEAGENT_PUBLISH_ATTESTATION"

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
ATTESTATION_NAME="$(basename "$ATTESTATION")"
TEST_RECEIPT_NAME="$(basename "$TEST_RECEIPT")"
EXPECTED_ATTESTATION_NAME="NativeAgent-$VERSION.release-attestation.json"
EXPECTED_TEST_RECEIPT_NAME="NativeAgent-$VERSION.test-receipt.json"
[[ "$DMG_NAME" == "$EXPECTED_DMG_NAME" ]] \
  || fail "DMG name '$DMG_NAME' does not match feed version $VERSION."
[[ "$ATTESTATION_NAME" == "$EXPECTED_ATTESTATION_NAME" ]] \
  || fail "attestation name '$ATTESTATION_NAME' does not match feed version $VERSION."
[[ "$TEST_RECEIPT_NAME" == "$EXPECTED_TEST_RECEIPT_NAME" ]] \
  || fail "test receipt name '$TEST_RECEIPT_NAME' does not match feed version $VERSION."

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

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
TEST_RECEIPT_SHA256="$(shasum -a 256 "$TEST_RECEIPT" | awk '{print $1}')"
DMG_BYTES="$(wc -c < "$DMG" | tr -d '[:space:]')"
jq -e --arg target "$TARGET" \
  '.schema_version == 1
   and .source_revision == $target
   and .source_dirty == false
   and .canonical_gate == "script/test.sh"
   and .ios_required == true
   and .ios_result == "passed"' \
  "$TEST_RECEIPT" >/dev/null \
  || fail "release test receipt does not prove the exact clean source and required iOS gate."
jq -e \
  --arg version "$VERSION" \
  --arg target "$TARGET" \
  --arg dmg_name "$DMG_NAME" \
  --arg dmg_sha256 "$DMG_SHA256" \
  --arg receipt_sha256 "$TEST_RECEIPT_SHA256" \
  --argjson dmg_bytes "$DMG_BYTES" \
  '.schema_version == 1
   and .version == $version
   and .source_revision == $target
   and .test_receipt.canonical_gate == "script/test.sh"
   and .test_receipt.source_dirty == false
   and .test_receipt.ios_required == true
   and .test_receipt.ios_result == "passed"
   and .test_receipt.sha256 == $receipt_sha256
   and .dmg.name == $dmg_name
   and .dmg.sha256 == $dmg_sha256
   and .dmg.byte_length == $dmg_bytes
   and .app.notarized == true
   and .app.stapled == true
   and ((.dmg.signature_required == true and .dmg.notarized == true and .dmg.stapled == true)
        or (.dmg.signature_required == false and .dmg.notarized == false and .dmg.stapled == false))
   and .verification_tool == "script/verify_release_artifact.sh"' \
  "$ATTESTATION" >/dev/null \
  || fail "release attestation does not bind the exact source, canonical test gate, and final DMG verification."
REMOTE_TARGET="$(gh api "repos/$REPOSITORY/commits/$TARGET" --jq '.sha' 2>/dev/null || true)"
[[ "$REMOTE_TARGET" == "$TARGET" ]] \
  || fail "source commit $TARGET is not present in $REPOSITORY. Publish the reviewed source first."

# ---------------------------------------------------------------------------
# Git tag (sweep R4 C1). `gh release create --target` creates the tag on the
# REMOTE only, so the repo this release was cut from carried no tag at all —
# no local tag exists past pre-swift-migration-2026-05-30 despite every publish
# computing TAG="v$VERSION". Create and push it HERE, before the release is
# created, so a failure aborts while nothing has been published yet. gh then
# reuses the tag that already exists at $TARGET.
#
# Gated: generate_appcast.sh refuses --rehearsal with --publish, so this script
# is never reached on a rehearsal; the check below makes that a guard rather
# than an assumption.
# ---------------------------------------------------------------------------
[[ "${NATIVEAGENT_APPCAST_REHEARSAL:-false}" != "true" ]] \
  || fail "refusing to tag or publish: this is a rehearsal run."

GIT_REMOTE=""
while read -r name url _; do
  case "$url" in
    *"$REPOSITORY"*) GIT_REMOTE="$name"; break ;;
  esac
done < <(git -C "$ROOT" remote -v 2>/dev/null || true)
[[ -n "$GIT_REMOTE" ]] \
  || fail "no git remote points at $REPOSITORY, so the release tag $TAG cannot be pushed.
       Add the remote (git remote add origin https://github.com/$REPOSITORY.git) and retry."

if EXISTING_TAG_COMMIT="$(git -C "$ROOT" rev-list -n 1 "$TAG" 2>/dev/null)"; then
  [[ "$EXISTING_TAG_COMMIT" == "$TARGET" ]] \
    || fail "local tag $TAG already points at $EXISTING_TAG_COMMIT, not the release commit $TARGET.
       Resolve that by hand — a release tag must name the bytes it shipped."
  echo "==> Tag $TAG already exists locally at $TARGET"
else
  echo "==> Creating release tag $TAG at $TARGET"
  git -C "$ROOT" tag -a "$TAG" -m "NativeAgent $VERSION" "$TARGET" \
    || fail "could not create the release tag $TAG."
fi

REMOTE_TAG_COMMIT="$(git -C "$ROOT" ls-remote --tags "$GIT_REMOTE" "refs/tags/$TAG^{}" 2>/dev/null | awk '{print $1}' | head -1)"
if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
  echo "==> Pushing $TAG to $GIT_REMOTE"
  git -C "$ROOT" push "$GIT_REMOTE" "refs/tags/$TAG" \
    || fail "could not push the release tag $TAG to $GIT_REMOTE."
  REMOTE_TAG_COMMIT="$(git -C "$ROOT" ls-remote --tags "$GIT_REMOTE" "refs/tags/$TAG^{}" 2>/dev/null | awk '{print $1}' | head -1)"
fi
# A push exit code is not existence, same rule as the feed itself.
[[ "$REMOTE_TAG_COMMIT" == "$TARGET" ]] \
  || fail "after pushing, $GIT_REMOTE has $TAG at '${REMOTE_TAG_COMMIT:-<absent>}', expected $TARGET."
echo "==> Release tag $TAG is live on $GIT_REMOTE at $TARGET"

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
    --pattern "$TEST_RECEIPT_NAME" \
    --pattern "$ATTESTATION_NAME" \
    --dir "$destination" >/dev/null
  cmp -s "$APPCAST" "$destination/appcast.xml" \
    || fail "GitHub release $TAG has a different appcast.xml."
  cmp -s "$DMG" "$destination/$DMG_NAME" \
    || fail "GitHub release $TAG has different DMG bytes."
  cmp -s "$TEST_RECEIPT" "$destination/$TEST_RECEIPT_NAME" \
    || fail "GitHub release $TAG has different test-receipt bytes."
  cmp -s "$ATTESTATION" "$destination/$ATTESTATION_NAME" \
    || fail "GitHub release $TAG has different release-attestation bytes."
}

# Idempotent retry: a prior successful publish may have completed before the
# caller's final HTTP verification returned. Accept only byte-identical assets.
if RELEASE_JSON="$(gh api "repos/$REPOSITORY/releases/tags/$TAG" 2>/dev/null)"; then
  DRAFT="$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')"
  [[ "$DRAFT" == "false" ]] \
    || fail "a draft release already exists for $TAG. Inspect or delete that draft before retrying."
  verify_release_assets
  echo "==> GitHub release $TAG already exists with the exact appcast, DMG, test receipt, and attestation."
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
  "$TEST_RECEIPT#NativeAgent $VERSION exact-commit test receipt" \
  "$ATTESTATION#NativeAgent $VERSION release attestation" \
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
