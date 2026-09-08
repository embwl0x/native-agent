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
MODEL_ASSET="${NATIVEAGENT_PUBLISH_MODEL_ASSET:-}"
DRY_RUN=false
case "${1:-}" in
  --dry-run) [[ $# == 1 ]] || fail "usage: publish_github_release.sh [--dry-run]"; DRY_RUN=true ;;
  '') ;;
  *) fail "usage: publish_github_release.sh [--dry-run]" ;;
esac

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "NATIVEAGENT_GITHUB_REPOSITORY must be owner/repository."
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."
command -v shasum >/dev/null 2>&1 || fail "shasum is required."

require_file "$APPCAST" "NATIVEAGENT_PUBLISH_APPCAST"
require_file "$DMG" "NATIVEAGENT_PUBLISH_DMG"
require_file "$TEST_RECEIPT" "NATIVEAGENT_PUBLISH_TEST_RECEIPT"
require_file "$ATTESTATION" "NATIVEAGENT_PUBLISH_ATTESTATION"

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
   and ((.canonical_gate == "script/test.sh" and .ios_required == true and .ios_result == "passed")
        or (.canonical_gate == "script/release.sh --artifact-only" and .ios_required == false and .ios_result == "not_run"))' \
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
   and ((.short_version // $version) == $version)
   and (.internal_build != true)
   and .source_revision == $target
   and .test_receipt.source_dirty == false
   and ((.test_receipt.canonical_gate == "script/test.sh" and .test_receipt.ios_required == true and .test_receipt.ios_result == "passed")
        or (.test_receipt.canonical_gate == "script/release.sh --artifact-only" and .test_receipt.ios_required == false and .test_receipt.ios_result == "not_run"))
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
  || fail "release attestation does not bind the exact source, canonical test gate, and final DMG verification.
       (internal-build-seat-hygiene: an attestation whose short_version carries the
       '-dev.<sha>' marker, or whose internal_build is true, is refused here — an
       internal build must never be published as the release.)"
RELEASE_ASSETS=( "$APPCAST" "$DMG" "$TEST_RECEIPT" "$ATTESTATION" )
if [[ -n "$MODEL_ASSET" || "$(jq -r '.model_asset != null' "$ATTESTATION")" == true || "$(jq -r '.model_asset != null' "$TEST_RECEIPT")" == true ]]; then
  require_file "$MODEL_ASSET" "NATIVEAGENT_PUBLISH_MODEL_ASSET"
  model_name="$(basename "$MODEL_ASSET")"
  [[ "$model_name" == "NativeAgent-$VERSION.embedding.zip" ]] || fail "model asset name does not match release version"
  model_sha="$(shasum -a 256 "$MODEL_ASSET" | awk '{print $1}')"
  model_bytes="$(wc -c < "$MODEL_ASSET" | tr -d '[:space:]')"
  for proof in "$TEST_RECEIPT" "$ATTESTATION"; do
    jq -e --arg name "$model_name" --arg sha "$model_sha" --argjson bytes "$model_bytes" \
      --arg url "${EXPECTED_DOWNLOAD_URL%/*}/$model_name" \
      '.model_asset.name == $name and .model_asset.sha256 == $sha
       and .model_asset.byte_length == $bytes and .model_asset.url == $url' "$proof" >/dev/null \
      || fail "model asset digest/size/URL does not match $proof"
  done
  RELEASE_ASSETS+=( "$MODEL_ASSET" )
fi
DELTA_COUNT="$(xmllint --xpath 'count(//*[local-name()="deltas"]/*[local-name()="enclosure"])' "$APPCAST")"
if [[ "$DELTA_COUNT" != 0 ]]; then
  source "$ROOT/script/lib/sparkle_tools.sh"
  DELTA_SIGN_TOOL="$(sparkle_tool_path_or_die sign_update "$ROOT")"
  DELTA_KEY="${NATIVEAGENT_SPARKLE_ED_PRIV_KEY:-${NATIVE_AGENT_SPARKLE_ED_PRIV_KEY:-}}"
  require_file "$DELTA_KEY" "Sparkle key for delta verification"
fi
for ((delta_index=1; delta_index<=DELTA_COUNT; delta_index++)); do
  delta_node="(//*[local-name()='deltas']/*[local-name()='enclosure'])[$delta_index]"
  delta_url="$(xmllint --xpath "string($delta_node/@url)" "$APPCAST")"
  delta_name="${delta_url##*/}"
  [[ "$delta_name" =~ ^[A-Za-z0-9_.-]+\.delta$ && "$delta_url" == "${EXPECTED_DOWNLOAD_URL%/*}/$delta_name" ]] \
    || fail "delta URL is outside this release: $delta_url"
  delta_file="$(dirname "$APPCAST")/$delta_name"
  require_file "$delta_file" "Sparkle delta"
  [[ "$(xmllint --xpath "string($delta_node/@length)" "$APPCAST")" == "$(wc -c < "$delta_file" | tr -d '[:space:]')" ]] \
    || fail "delta size mismatch: $delta_name"
  delta_signature="$(xmllint --xpath "string($delta_node/@*[local-name()='edSignature'])" "$APPCAST")"
  [[ -n "$delta_signature" ]] \
    || fail "unsigned Sparkle delta: $delta_name"
  "$DELTA_SIGN_TOOL" --verify --ed-key-file "$DELTA_KEY" "$delta_file" "$delta_signature" >/dev/null \
    || fail "delta signature mismatch: $delta_name"
  RELEASE_ASSETS+=( "$delta_file" )
done
if [[ "$DRY_RUN" == true ]]; then
  echo "==> Offline publication rehearsal passed for $TAG; no remote calls or tag writes."
  printf '    asset: %s\n' "${RELEASE_ASSETS[@]}"
  exit 0
fi
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated; run: gh auth login"
VISIBILITY="$(gh api "repos/$REPOSITORY" --jq '.visibility' 2>/dev/null || true)"
[[ "$VISIBILITY" == public ]] || fail "$REPOSITORY is not public. Sparkle clients cannot authenticate to a private release feed."
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
  GIT_COMMITTER_NAME=embw_l0x \
  GIT_COMMITTER_EMAIL=262193448+embwl0x@users.noreply.github.com \
    git -C "$ROOT" tag -a "$TAG" -m "NativeAgent $VERSION" "$TARGET" \
    || fail "could not create the release tag $TAG."
fi

TAG_METADATA="$(git -C "$ROOT" for-each-ref --format='%(objecttype) %(taggername) %(taggeremail)' "refs/tags/$TAG")"
[[ "$TAG_METADATA" == 'tag embw_l0x <262193448+embwl0x@users.noreply.github.com>' ]] \
  || fail "release tag $TAG must be annotated with the approved GitHub noreply identity."
LOCAL_TAG_OBJECT="$(git -C "$ROOT" rev-parse "refs/tags/$TAG")"
REMOTE_TAG_OBJECT="$(git -C "$ROOT" ls-remote --tags "$GIT_REMOTE" "refs/tags/$TAG" | awk '{print $1}')"
[[ -z "$REMOTE_TAG_OBJECT" || "$REMOTE_TAG_OBJECT" == "$LOCAL_TAG_OBJECT" ]] \
  || fail "remote tag $TAG is not the identity-verified local tag object."
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
[[ "$(git -C "$ROOT" ls-remote --tags "$GIT_REMOTE" "refs/tags/$TAG" | awk '{print $1}')" == "$LOCAL_TAG_OBJECT" ]] \
  || fail "remote tag object changed before release publication."
echo "==> Release tag $TAG is live on $GIT_REMOTE at $TARGET"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-github-release.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# 2026-09-07: GitHub's releases-by-tag endpoint does not serve DRAFT releases
# (404), and the draft is exactly the state this script verifies before
# publication. Look the release up in the list, which includes drafts.
release_json_for_tag() {
  gh api "repos/$REPOSITORY/releases?per_page=100" --jq "[.[] | select(.tag_name == \"$TAG\")] | .[0] // empty"
}

verify_release_assets() {
  local release assets file name digest size
  release="$(release_json_for_tag)" || return $?
  [[ -n "$release" ]] || fail "GitHub has no release (draft or published) for $TAG."
  [[ "$(jq -r '.tag_name' <<<"$release")" == "$TAG" ]] \
    || fail "GitHub returned a different release tag."
  # GitHub computes these digests from uploaded bytes. Missing digests are a
  # refusal, never permission for a multi-hour single-stream DMG readback.
  for file in "${RELEASE_ASSETS[@]}"; do
    name="$(basename "$file")"
    [[ "$file" != "$APPCAST" ]] || name=appcast.xml
    digest="sha256:$(shasum -a 256 "$file" | awk '{print $1}')"
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    assets="$(jq --arg name "$name" '[.assets[] | select(.name == $name)]' <<<"$release")" || return $?
    jq -e --arg digest "$digest" --argjson size "$size" \
      'length == 1 and .[0].state == "uploaded" and .[0].digest == $digest and .[0].size == $size' \
      <<<"$assets" >/dev/null \
      || fail "GitHub release $TAG asset $name lacks an exact SHA-256 and size proof."
  done
}

# Idempotent retry: a prior successful publish may have completed before the
# caller's final HTTP verification returned. Accept only byte-identical assets.
RELEASE_JSON="$(release_json_for_tag 2>/dev/null || true)"
if [[ -n "$RELEASE_JSON" ]]; then
  DRAFT="$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')"
  # Either way the assets must be byte-identical to what this run built.
  verify_release_assets
  if [[ "$DRAFT" == "false" ]]; then
    echo "==> GitHub release $TAG already exists with all exact release assets."
    exit 0
  fi
  # 2026-09-07: a draft with the exact assets is the fail-safe resting state of
  # an interrupted earlier publish; finish it rather than refuse.
  echo "==> Draft release $TAG already holds the exact assets; publishing it."
  gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest >/dev/null
  RELEASE_JSON="$(release_json_for_tag)"
  [[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')" == "false" ]] \
    || fail "GitHub release $TAG is still a draft after publication."
  echo "==> GitHub release published: https://github.com/$REPOSITORY/releases/tag/$TAG"
  exit 0
fi

NOTES_ARGS=( --generate-notes )
if [[ -n "${NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE:-}" ]]; then
  require_file "$NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE" "NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE"
  NOTES_ARGS=( --notes-file "$NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE" )
fi

echo "==> Creating draft GitHub release $TAG"
gh release create "$TAG" \
  "${RELEASE_ASSETS[@]}" \
  --repo "$REPOSITORY" \
  --target "$TARGET" \
  --title "NativeAgent $VERSION" \
  --draft \
  "${NOTES_ARGS[@]}" >/dev/null

# Draft is the fail-safe resting state. Verify the exact uploaded bytes through
# GitHub before making the release visible or eligible as "latest".
verify_release_assets
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest >/dev/null

RELEASE_JSON="$(release_json_for_tag)"
[[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.draft')" == "false" ]] \
  || fail "GitHub release $TAG is still a draft after publication."
[[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.prerelease')" == "false" ]] \
  || fail "GitHub release $TAG unexpectedly became a prerelease."

echo "==> GitHub release published: https://github.com/$REPOSITORY/releases/tag/$TAG"
