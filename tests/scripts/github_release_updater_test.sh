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
      [[ -f "$GH_REMOTE/published" ]] || exit 1
      printf '{"draft":false,"prerelease":false}\n'
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
  touch "$GH_REMOTE/draft"
  exit 0
fi
if [[ "$1 $2" == "release download" ]]; then
  destination=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--dir" ]]; then destination="$2"; break; fi
    shift
  done
  [[ -n "$destination" ]]
  cp "$GH_REMOTE/appcast.xml" "$destination/appcast.xml"
  cp "$GH_REMOTE/NativeAgent-9.9.9.dmg" "$destination/NativeAgent-9.9.9.dmg"
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
    printf '%s\n' "${args[${#args[@]}-1]}" > "$GIT_STATE/local-tag"; exit 0 ;;
  ls-remote)
    if [[ -f "$GIT_STATE/remote-tag" ]]; then
      printf '%s\trefs/tags/%s^{}\n' "$(cat "$GIT_STATE/remote-tag")" "${args[${#args[@]}-1]}"
    fi
    exit 0 ;;
  push)
    [[ -f "$GIT_STATE/local-tag" ]] || { echo "no local tag to push" >&2; exit 1; }
    cp "$GIT_STATE/local-tag" "$GIT_STATE/remote-tag"; exit 0 ;;
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
COMMON_ENV=(
  PATH="$TMP/bin:$PATH"
  GH_CALLS="$TMP/gh.calls"
  GIT_CALLS="$TMP/git.calls"
  GIT_STATE="$TMP/gitstate"
  GIT_HEAD="$HEAD"
  GH_REMOTE="$TMP/remote"
  NATIVEAGENT_GITHUB_REPOSITORY="acme/NativeAgent"
  NATIVEAGENT_GITHUB_TARGET_COMMIT="$HEAD"
  NATIVEAGENT_PUBLISH_APPCAST="$APPCAST"
  NATIVEAGENT_PUBLISH_DMG="$DMG"
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
grep -q '^release create ' "$TMP/gh.calls" || fail "publisher did not create a draft release"
grep -q '^release download ' "$TMP/gh.calls" || fail "publisher did not read back draft assets"
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

# Retry is idempotent only when both already-public assets are byte-identical.
: > "$TMP/gh.calls"
env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/retry.log"
grep -q 'already exists with the exact appcast and DMG' "$TMP/retry.log" \
  || fail "exact published retry was not recognized"
if grep -Eq '^release (create|edit) ' "$TMP/gh.calls"; then
  fail "exact retry mutated an already-published release"
fi

printf 'wrong remote bytes\n' > "$TMP/remote/NativeAgent-9.9.9.dmg"
if env "${COMMON_ENV[@]}" GH_VISIBILITY=public "$PUBLISHER" >"$TMP/mismatch.log" 2>&1; then
  fail "publisher accepted different bytes for an existing release tag"
fi
grep -q 'different DMG bytes' "$TMP/mismatch.log" \
  || fail "existing-release mismatch is not explicit"

echo "[test] GitHub Sparkle release publisher OK"
