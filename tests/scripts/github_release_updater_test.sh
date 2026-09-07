#!/usr/bin/env bash
# Behavioral proof for the GitHub Release publisher used by Sparkle updates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUBLISHER="$ROOT/script/publish_github_release.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-github-updater.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/remote"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$GH_CALLS"
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1" == "api" ]]; then
  case "$2" in
    repos/*/commits/*)
      printf '%s\n' "${NATIVEAGENT_GITHUB_TARGET_COMMIT}"
      ;;
    repos/*/releases/tags/*)
      [[ -f "$GH_REMOTE/published" || -f "$GH_REMOTE/draft" ]] || exit 1
      draft=true
      [[ ! -f "$GH_REMOTE/published" ]] || draft=false
      for file in "$GH_REMOTE/appcast.xml" "$GH_REMOTE"/NativeAgent-9.9.9.*; do
        digest="sha256:$(shasum -a 256 "$file" | awk '{print $1}')"
        size="$(wc -c < "$file" | tr -d '[:space:]')"
        if [[ "$file" == *.dmg ]]; then
          digest="${GH_DMG_DIGEST:-$digest}"
          size="${GH_DMG_SIZE:-$size}"
        fi
        jq -n --arg name "$(basename "$file")" --arg digest "$digest" --argjson size "$size" \
          '{name: $name, state: "uploaded", digest: $digest, size: $size}'
      done | jq -s --argjson draft "$draft" \
        '{tag_name: "v9.9.9", draft: $draft, prerelease: false, assets: .}'
      ;;
    repos/*)
      printf '%s\n' "$GH_VISIBILITY"
      ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "$1 $2" == "release create" ]]; then
  cp "$NATIVEAGENT_PUBLISH_APPCAST" "$GH_REMOTE/appcast.xml"
  cp "$NATIVEAGENT_PUBLISH_DMG" "$GH_REMOTE/$(basename "$NATIVEAGENT_PUBLISH_DMG")"
  cp "$NATIVEAGENT_PUBLISH_TEST_RECEIPT" "$GH_REMOTE/$(basename "$NATIVEAGENT_PUBLISH_TEST_RECEIPT")"
  cp "$NATIVEAGENT_PUBLISH_ATTESTATION" "$GH_REMOTE/$(basename "$NATIVEAGENT_PUBLISH_ATTESTATION")"
  touch "$GH_REMOTE/draft"
  exit 0
fi
if [[ "$1 $2" == "release edit" ]]; then
  rm -f "$GH_REMOTE/draft"
  touch "$GH_REMOTE/published"
  exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"

# Sweep R4 C1: the publisher now creates and pushes the release tag v$VERSION
# (gh --target only ever made the tag on the remote, so the repo carried none).
# git is stubbed so this test can PROVE the tag work happens without touching
# the real repository or a real remote.
cat > "$TMP/bin/git" <<'GITSTUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$GIT_CALLS"
args=( "$@" )
# Drop a leading `-C <path>`; every call the publisher makes uses it.
if [[ "${args[0]:-}" == "-C" ]]; then args=( "${args[@]:2}" ); fi
case "${args[0]:-} ${args[1]:-}" in
  "rev-parse HEAD") printf '%s\n' "$GIT_HEAD"; exit 0 ;;
  "remote -v")
    printf 'origin\thttps://github.com/%s.git\t(fetch)\n' "$NATIVEAGENT_GITHUB_REPOSITORY"
    printf 'origin\thttps://github.com/%s.git\t(push)\n' "$NATIVEAGENT_GITHUB_REPOSITORY"
    exit 0 ;;
esac
case "${args[0]:-}" in
  rev-list)
    [[ -f "$GIT_STATE/local-tag" ]] || exit 128
    cat "$GIT_STATE/local-tag"; exit 0 ;;
  tag)
    jq -n --arg name "$GIT_COMMITTER_NAME" --arg email "$GIT_COMMITTER_EMAIL" \
      --arg sha "$GIT_TAG_OBJECT" --arg target "${args[${#args[@]}-1]}" \
      '{sha: $sha, tagger: {name: $name, email: $email}, object: {type: "commit", sha: $target}}' \
      > "$GIT_STATE/tag-object.json"
    printf '%s\n' "${args[${#args[@]}-1]}" > "$GIT_STATE/local-tag"; exit 0 ;;
  for-each-ref)
    jq -r '"tag \(.tagger.name) <\(.tagger.email)>"' "$GIT_STATE/tag-object.json"; exit 0 ;;
  rev-parse)
    [[ "${args[1]}" == refs/tags/* ]] || exit 1
    jq -r '.sha' "$GIT_STATE/tag-object.json"; exit 0 ;;
  ls-remote)
    if [[ -f "$GIT_STATE/remote-tag" ]]; then
      ref="${args[${#args[@]}-1]}"
      if [[ "$ref" == *'^{}' ]]; then
        printf '%s\t%s\n' "$(cat "$GIT_STATE/remote-tag")" "$ref"
      else
        printf '%s\t%s\n' "$(cat "$GIT_STATE/remote-tag-object")" "$ref"
      fi
    fi
    exit 0 ;;
  push)
    [[ -f "$GIT_STATE/local-tag" ]] || { echo "no local tag to push" >&2; exit 1; }
    jq -r '.object.sha' "$GIT_STATE/tag-object.json" > "$GIT_STATE/remote-tag"
    jq -r '.sha' "$GIT_STATE/tag-object.json" > "$GIT_STATE/remote-tag-object"; exit 0 ;;
esac
exit 1
GITSTUB
chmod +x "$TMP/bin/git"
mkdir -p "$TMP/gitstate"

APPCAST="$TMP/appcast.xml"
DMG="$TMP/NativeAgent-9.9.9.dmg"
cat > "$APPCAST" <<'XML'
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item><sparkle:version>9.9.9</sparkle:version></item></channel>
</rss>
XML
printf 'exact dmg bytes\n' > "$DMG"

HEAD="$(git -C "$ROOT" rev-parse HEAD)"
RECEIPT="$TMP/NativeAgent-9.9.9.test-receipt.json"
ATTESTATION="$TMP/NativeAgent-9.9.9.release-attestation.json"
cat > "$RECEIPT" <<JSON
{
  "schema_version": 1,
  "source_revision": "$HEAD",
  "source_dirty": false,
  "canonical_gate": "script/test.sh",
  "ios_required": true,
  "ios_result": "passed",
  "completed_at": "2026-08-16T12:00:00Z"
}
JSON
"$ROOT/script/create_release_attestation.sh" \
  --dmg "$DMG" \
  --test-receipt "$RECEIPT" \
  --source-revision "$HEAD" \
  --version 9.9.9 \
  --dmg-signature-required true \
  --dmg-notarized true \
  --dmg-stapled true \
  --out "$ATTESTATION" >/dev/null
COMMON_ENV=(
  PATH="$TMP/bin:$PATH"
  GH_CALLS="$TMP/gh.calls"
  GIT_CALLS="$TMP/git.calls"
  GIT_STATE="$TMP/gitstate"
  GIT_HEAD="$HEAD"
  GIT_TAG_OBJECT=1111111111111111111111111111111111111111
  GH_REMOTE="$TMP/remote"
  NATIVEAGENT_GITHUB_REPOSITORY="acme/NativeAgent"
  NATIVEAGENT_GITHUB_TARGET_COMMIT="$HEAD"
  NATIVEAGENT_PUBLISH_APPCAST="$APPCAST"
  NATIVEAGENT_PUBLISH_DMG="$DMG"
  NATIVEAGENT_PUBLISH_TEST_RECEIPT="$RECEIPT"
  NATIVEAGENT_PUBLISH_ATTESTATION="$ATTESTATION"
  NATIVEAGENT_PUBLISH_APPCAST_URL="https://github.com/acme/NativeAgent/releases/latest/download/appcast.xml"
  NATIVEAGENT_DMG_DOWNLOAD_URL="https://github.com/acme/NativeAgent/releases/download/v9.9.9/NativeAgent-9.9.9.dmg"
)

# A private repository is unusable by anonymous installed clients and must fail
# before a draft/release mutation is attempted.
if env "${COMMON_ENV[@]}" GH_VISIBILITY=private "$PUBLISHER" >"$TMP/private.log" 2>&1; then
  fail "publisher accepted a private repository"
fi
grep -q 'Sparkle clients cannot authenticate' "$TMP/private.log" \
  || fail "private-repository refusal is not actionable"
if grep -q '^release ' "$TMP/gh.calls"; then
  fail "publisher mutated GitHub before rejecting private visibility"
fi

: > "$TMP/gh.calls"
env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/public.log"
[[ -f "$TMP/remote/published" ]] || fail "verified draft was not published"
cmp -s "$APPCAST" "$TMP/remote/appcast.xml" || fail "published appcast bytes drifted"
cmp -s "$DMG" "$TMP/remote/NativeAgent-9.9.9.dmg" || fail "published DMG bytes drifted"
cmp -s "$RECEIPT" "$TMP/remote/NativeAgent-9.9.9.test-receipt.json" \
  || fail "published test receipt bytes drifted"
cmp -s "$ATTESTATION" "$TMP/remote/NativeAgent-9.9.9.release-attestation.json" \
  || fail "published attestation bytes drifted"
grep -q '^release create ' "$TMP/gh.calls" || fail "publisher did not create a draft release"
grep -q '^api repos/acme/NativeAgent/releases/tags/v9.9.9' "$TMP/gh.calls" \
  || fail "publisher did not request release asset metadata"
if grep -q '^release download ' "$TMP/gh.calls"; then
  fail "publisher downloaded assets instead of using GitHub digest metadata"
fi
grep -q '^release edit ' "$TMP/gh.calls" || fail "publisher did not publish the verified draft"
# The release tag must exist locally AND on the remote, at the release commit.
grep -q '^-C .* tag -a v9.9.9 ' "$TMP/git.calls" \
  || fail "publisher did not create the release tag v9.9.9"
grep -q '^-C .* push origin refs/tags/v9.9.9' "$TMP/git.calls" \
  || fail "publisher did not push the release tag"
[[ "$(cat "$TMP/gitstate/remote-tag")" == "$HEAD" ]] \
  || fail "the pushed tag does not point at the release commit"
grep -q 'Release tag v9.9.9 is live' "$TMP/public.log" \
  || fail "publisher did not report the tag as live"
# The tag step must run BEFORE anything is published, so a tag failure aborts
# while nothing is live.
awk '/tag -a v9.9.9/ { t=NR } END { exit !t }' "$TMP/git.calls" \
  || fail "no tag creation recorded"

# Retry is idempotent only when all already-public assets are byte-identical.
: > "$TMP/gh.calls"
env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/retry.log"
grep -q 'already exists with the exact appcast, DMG, test receipt, and attestation' "$TMP/retry.log" \
  || fail "exact published retry was not recognized"
if grep -Eq '^release (create|edit) ' "$TMP/gh.calls"; then
  fail "exact retry mutated an already-published release"
fi

printf 'wrong remote bytes\n' > "$TMP/remote/NativeAgent-9.9.9.dmg"
if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/mismatch.log" 2>&1; then
  fail "publisher accepted different bytes for an existing release tag"
fi
grep -q 'asset NativeAgent-9.9.9.dmg lacks an exact SHA-256 and size proof' "$TMP/mismatch.log" \
  || fail "existing-release mismatch is not explicit"

# The attestation is not decorative: its source and DMG digest must validate
# before any release/tag mutation, and existing releases require exact bytes.
cp "$DMG" "$TMP/remote/NativeAgent-9.9.9.dmg"
mkdir -p "$TMP/bad"
BAD_ATTESTATION="$TMP/bad/NativeAgent-9.9.9.release-attestation.json"
cp "$ATTESTATION" "$BAD_ATTESTATION"
jq '.dmg.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$BAD_ATTESTATION" > "$BAD_ATTESTATION.tmp"
mv "$BAD_ATTESTATION.tmp" "$BAD_ATTESTATION"
if env "${COMMON_ENV[@]}" \
  NATIVEAGENT_PUBLISH_ATTESTATION="$BAD_ATTESTATION" \
  GH_VISIBILITY=public "$PUBLISHER" >"$TMP/bad-attestation.log" 2>&1; then
  fail "publisher accepted an attestation for different DMG bytes"
fi
grep -q 'does not bind the exact source' "$TMP/bad-attestation.log" \
  || fail "attestation digest refusal is not explicit"

printf 'different attestation bytes\n' > "$TMP/remote/NativeAgent-9.9.9.release-attestation.json"
if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/attestation-mismatch.log" 2>&1; then
  fail "publisher accepted different attestation bytes for an existing release tag"
fi
grep -q 'asset NativeAgent-9.9.9.release-attestation.json lacks an exact SHA-256 and size proof' "$TMP/attestation-mismatch.log" \
  || fail "existing attestation mismatch is not explicit"

cp "$ATTESTATION" "$TMP/remote/NativeAgent-9.9.9.release-attestation.json"
printf 'different receipt bytes\n' > "$TMP/remote/NativeAgent-9.9.9.test-receipt.json"
if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/receipt-mismatch.log" 2>&1; then
  fail "publisher accepted different test-receipt bytes for an existing release tag"
fi
grep -q 'asset NativeAgent-9.9.9.test-receipt.json lacks an exact SHA-256 and size proof' "$TMP/receipt-mismatch.log" \
  || fail "existing test receipt mismatch is not explicit"

# Corrupt each proof field independently while keeping the uploaded bytes exact.
# Failed draft verification must never promote the release to public/latest.
for mismatch in digest size; do
  rm -f "$TMP/remote/published" "$TMP/remote/draft"
  : > "$TMP/gh.calls"
  if [[ "$mismatch" == digest ]]; then
    override=GH_DMG_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  else
    override=GH_DMG_SIZE=999
  fi
  if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$override" "$PUBLISHER" \
    >"$TMP/$mismatch.log" 2>&1; then
    fail "publisher accepted a $mismatch mismatch"
  fi
  grep -q 'asset NativeAgent-9.9.9.dmg lacks an exact SHA-256 and size proof' "$TMP/$mismatch.log" \
    || fail "$mismatch mismatch did not fail at the asset proof"
  [[ -f "$TMP/remote/draft" && ! -f "$TMP/remote/published" ]] \
    || fail "$mismatch mismatch did not leave the release in draft"
  if grep -q '^release edit ' "$TMP/gh.calls"; then
    fail "$mismatch mismatch attempted publication"
  fi
done

# A remote tag with the expected object ID but the wrong peeled commit must
# fail before release creation. Keep the local tag at the correct commit.
rm -f "$TMP/remote/draft"
printf '%s\n' 2222222222222222222222222222222222222222 > "$TMP/gitstate/remote-tag"
: > "$TMP/gh.calls"
if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/tag-mismatch.log" 2>&1; then
  fail "publisher accepted a tag pointing at the wrong commit"
fi
grep -q "has v9.9.9 at '2222222222222222222222222222222222222222', expected $HEAD" \
  "$TMP/tag-mismatch.log" || fail "wrong tag commit refusal is not explicit"
if grep -Eq '^release (create|edit) ' "$TMP/gh.calls"; then
  fail "publisher mutated a release after a tag commit mismatch"
fi

echo "[test] GitHub Sparkle release publisher OK"
