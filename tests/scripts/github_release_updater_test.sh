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
