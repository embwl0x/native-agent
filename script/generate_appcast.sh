#!/usr/bin/env bash
# Generate, cryptographically verify and optionally publish the Sparkle appcast.
#
# Usage:
#   script/generate_appcast.sh --dmg dist/NativeAgent-0.2.0.dmg --version 0.2.0 \
#       [--out dist/appcast] [--notes NOTES.md] [--rehearsal | --publish]
#
# Options:
#   --notes FILE   release notes shown in Sparkle's update dialog. Embedded in
#                  the feed item as <description> (CDATA). Branch is chosen by
#                  EXTENSION first (.md -> release_notes_html.swift converter,
#                  .html -> embedded as-is); only an extensionless file is
#                  sniffed, and then on prose with code fences/backtick spans
#                  stripped and line-leading tags only. Added AFTER every
#                  signature/version/URL guard has passed; the feed is then
#                  re-validated, payload included.
#   --allow-version-drift
#                  permit a feed version that differs from the repo VERSION file.
#                  For synthetic-version test runs ONLY; refused with --publish.
#   --previous-dmg FILE
#                  Local previous release DMG for Sparkle delta generation.
#                  Also accepts NATIVEAGENT_SPARKLE_PREVIOUS_DMG. No fetching.
#
# Required environment:
#   NATIVEAGENT_SPARKLE_ED_PRIV_KEY  path to the Sparkle EdDSA private key file
#   NATIVEAGENT_APPCAST_URL          public URL the appcast.xml will be served from
#   NATIVEAGENT_DMG_DOWNLOAD_URL     public URL the DMG will be downloaded from
# Optional:
#   NATIVEAGENT_RELEASE_PAGE_URL     <link> for the feed item (release page)
#   NATIVEAGENT_APPCAST_PUBLISH_CMD  required with --publish; receives the artifacts
#                                    via NATIVEAGENT_PUBLISH_APPCAST/_DMG/_URL env
#   NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS / _DELAY
#                                    bounded retry while the host propagates
#                                    (default 12 attempts, 15s apart). Running out
#                                    of attempts FAILS the publish — after the
#                                    publish command exits 0, this script fetches
#                                    the feed and the DMG from their advertised
#                                    URLs and compares them against what it just
#                                    signed. An exit code is not existence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sparkle_tools.sh
source "$ROOT/script/lib/sparkle_tools.sh"
# shellcheck source=lib/appcast_publish_verify.sh
source "$ROOT/script/lib/appcast_publish_verify.sh"

DMG_PATH=""
VERSION=""
OUT_DIR=""
PUBLISH=false
# Rehearsal: prove the key + tooling produce a correctly signed feed for an app
# that deliberately carries no feed URL yet (release.sh --appcast). Relaxes ONLY
# the two bundle<->feed cross-checks; every signature/version/URL/length guard
# below still runs, and publishing is refused.
REHEARSAL=false
NOTES_FILE=""
# Version drift is permitted only for synthetic local runs; publishing must match VERSION.
ALLOW_VERSION_DRIFT=false
PREVIOUS_DMG="${NATIVEAGENT_SPARKLE_PREVIOUS_DMG:-}"

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)     [[ $# -ge 2 ]] || { usage; exit 2; }; DMG_PATH="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || { usage; exit 2; }; VERSION="$2"; shift 2 ;;
    --out)     [[ $# -ge 2 ]] || { usage; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --previous-dmg) [[ $# -ge 2 ]] || { usage; exit 2; }; PREVIOUS_DMG="$2"; shift 2 ;;
    --publish) PUBLISH=true; shift ;;
    --rehearsal) REHEARSAL=true; shift ;;
    --notes)   [[ $# -ge 2 ]] || { usage; exit 2; }; NOTES_FILE="$2"; shift 2 ;;
    --allow-version-drift) ALLOW_VERSION_DRIFT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fail() {
  echo "" >&2
  echo "ERROR: $*" >&2
  exit 1
}

if [[ "$ALLOW_VERSION_DRIFT" == "true" && "$PUBLISH" == "true" ]]; then
  echo "ERROR: --allow-version-drift and --publish are mutually exclusive." >&2
  echo "       A published feed must advertise the version in the repo VERSION file." >&2
  exit 1
fi
if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes file not found: $NOTES_FILE" >&2; exit 1; }
  [[ -s "$NOTES_FILE" ]] || { echo "ERROR: --notes file is empty: $NOTES_FILE" >&2; exit 1; }
  NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
fi

[[ -n "$DMG_PATH" ]] || fail "--dmg is required."
[[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
if [[ "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" == bundled ]]; then
  PREVIOUS_DMG=""
fi
if [[ -n "$PREVIOUS_DMG" ]]; then
  [[ -f "$PREVIOUS_DMG" && "$PREVIOUS_DMG" == *.dmg ]] || fail "previous DMG is missing: $PREVIOUS_DMG"
  PREVIOUS_DMG="$(cd "$(dirname "$PREVIOUS_DMG")" && pwd)/$(basename "$PREVIOUS_DMG")"
  [[ "$(basename "$PREVIOUS_DMG")" != "$(basename "$DMG_PATH")" ]] || fail "previous and current DMGs must have distinct names"
fi

# Version comes from the same single source of truth release.sh uses.
if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || fail "no --version given and $ROOT/VERSION is missing."
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
OUT_DIR="${OUT_DIR:-$ROOT/dist/appcast}"

# ---------------------------------------------------------------------------
# 1. Signing key — checked FIRST, before any tool lookup or staging, so that a
#    missing key always produces the same loud, actionable failure.
# ---------------------------------------------------------------------------
PRIV_KEY="${NATIVE_AGENT_SPARKLE_ED_PRIV_KEY:-${NATIVEAGENT_SPARKLE_ED_PRIV_KEY:-}}"
if [[ -z "$PRIV_KEY" ]]; then
  echo "" >&2
  echo "ERROR: NATIVEAGENT_SPARKLE_ED_PRIV_KEY is not set — refusing to emit an" >&2
  echo "       unsigned appcast. Sparkle rejects unsigned enclosures, and a feed" >&2
  echo "       that parses but cannot install is worse than no feed at all." >&2
  echo "" >&2
  echo "REMEDIATION:" >&2
  echo "  1. Generate the release key once:   ./script/sparkle_keygen.sh" >&2
  echo "     (it uses Sparkle's generate_keys, which stores the key in your Keychain)" >&2
  echo "  2. Export it to a file for scripted signing:" >&2
  echo "       .build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/.config/nativeagent/sparkle_ed_priv.key" >&2
  echo "  3. Export both halves before releasing:" >&2
  echo "       export NATIVEAGENT_SPARKLE_ED_PRIV_KEY=~/.config/nativeagent/sparkle_ed_priv.key" >&2
  echo "       export NATIVEAGENT_SPARKLE_PUBLIC_KEY=\"\$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)\"" >&2
  echo "  The public key MUST be the SUPublicEDKey baked into the app being signed." >&2
  exit 1
fi
[[ -r "$PRIV_KEY" ]] || fail "NATIVEAGENT_SPARKLE_ED_PRIV_KEY is not readable: $PRIV_KEY"
if grep -q "BEGIN .*PRIVATE KEY" "$PRIV_KEY"; then
  fail "NATIVEAGENT_SPARKLE_ED_PRIV_KEY is a PEM key, not a Sparkle EdDSA key file.
       Sparkle expects the base64 seed written by 'generate_keys -x'."
fi

# ---------------------------------------------------------------------------
# 2. URLs — a wrong enclosure URL produces a feed that offers an update it can
#    never download, so these are required rather than guessed.
# ---------------------------------------------------------------------------
APPCAST_URL="${NATIVE_AGENT_APPCAST_URL:-${NATIVEAGENT_APPCAST_URL:-}}"
DOWNLOAD_URL="${NATIVE_AGENT_DMG_DOWNLOAD_URL:-${NATIVEAGENT_DMG_DOWNLOAD_URL:-}}"
RELEASE_PAGE_URL="${NATIVE_AGENT_RELEASE_PAGE_URL:-${NATIVEAGENT_RELEASE_PAGE_URL:-}}"

[[ -n "$APPCAST_URL" ]] || fail "NATIVEAGENT_APPCAST_URL is not set (the URL the feed is served from)."
[[ -n "$DOWNLOAD_URL" ]] || fail "NATIVEAGENT_DMG_DOWNLOAD_URL is not set (the URL the DMG is downloaded from).
       It is never inferred: a guessed enclosure URL yields a feed that advertises
       an update nobody can download."

PLACEHOLDER_RE='(^|//|\.)(example\.(com|org|net|invalid)|localhost)(/|:|$)'
for u in "$APPCAST_URL" "$DOWNLOAD_URL" "${RELEASE_PAGE_URL:-https://ok.invalidcheck.skip}"; do
  [[ "$u" == "https://ok.invalidcheck.skip" ]] && continue
  [[ "$u" =~ ^https:// ]] || fail "URL must be https: $u"
  if printf '%s' "$u" | grep -Eqi "$PLACEHOLDER_RE"; then
    fail "placeholder URL refused: $u
       Set the real hosting URLs before generating a feed."
  fi
done

DMG_BASENAME="$(basename "$DMG_PATH")"
[[ "$DOWNLOAD_URL" == */"$DMG_BASENAME" ]] \
  || fail "NATIVEAGENT_DMG_DOWNLOAD_URL must end in the DMG filename '$DMG_BASENAME'.
       Got: $DOWNLOAD_URL"
DOWNLOAD_PREFIX="${DOWNLOAD_URL%"$DMG_BASENAME"}"

# ---------------------------------------------------------------------------
# 3. Cross-check the artifact: the key we sign with must be the key the app
#    trusts, or Sparkle silently emits an UNSIGNED enclosure.
# ---------------------------------------------------------------------------
MOUNT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-appcast.XXXXXX")"
MOUNT_POINT="$MOUNT_BASE/mnt"
# A rejected feed must never survive on disk where a human could upload it by
# hand — Sparkle happily writes an unsigned appcast.xml before we reject it.
APPCAST_ACCEPTED=false
cleanup() {
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  rm -rf "$MOUNT_BASE"
  if [[ "${OUTPUT_STAGED:-false}" == true ]]; then
    [[ -z "$PREVIOUS_DMG" ]] || rm -f "$OUT_DIR/$(basename "$PREVIOUS_DMG")"
    rm -rf "$OUT_DIR/old_updates"
  fi
  if [[ "$APPCAST_ACCEPTED" != "true" ]]; then
    if [[ -n "${APPCAST_XML:-}" && -f "$APPCAST_XML" ]]; then
      rm -f "$APPCAST_XML"
      echo "    (discarded the rejected $APPCAST_XML)" >&2
    fi
    # Rejection must also remove the staged DMG so the feed directory cannot ship it.
    if [[ -n "${OUT_DIR:-}" && -n "${DMG_BASENAME:-}" && -f "$OUT_DIR/$DMG_BASENAME" ]]; then
      rm -f "$OUT_DIR/$DMG_BASENAME"
      echo "    (discarded the staged $OUT_DIR/$DMG_BASENAME)" >&2
    fi
  fi
}
trap cleanup EXIT

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -noverify -mountpoint "$MOUNT_POINT" >/dev/null \
  || fail "could not mount $DMG_PATH"
APP_INFO="$MOUNT_POINT/NativeAgent.app/Contents/Info.plist"
[[ -f "$APP_INFO" ]] || fail "NativeAgent.app/Contents/Info.plist not found inside $DMG_PATH"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}
BUNDLE_PUB_KEY="$(plist_value "$APP_INFO" SUPublicEDKey)"
BUNDLE_VERSION="$(plist_value "$APP_INFO" CFBundleVersion)"
BUNDLE_SHORT_VERSION="$(plist_value "$APP_INFO" CFBundleShortVersionString)"
BUNDLE_FEED_URL="$(plist_value "$APP_INFO" SUFeedURL)"
BUNDLE_FEED_PUBLISHED="$(plist_value "$APP_INFO" NativeAgentUpdateFeedPublished)"

[[ -n "$BUNDLE_PUB_KEY" ]] \
  || fail "the app inside $DMG_BASENAME has an EMPTY SUPublicEDKey.
       Sparkle cannot verify any update this feed offers. Rebuild the release with
       NATIVEAGENT_SPARKLE_PUBLIC_KEY set (see script/release.sh)."

# The signing key's public half must equal the key trusted by the bundled app.
DERIVED_PUB_KEY="$(sparkle_ed_public_key_from_file "$PRIV_KEY" "$ROOT")" \
  || fail "could not derive the public half of NATIVEAGENT_SPARKLE_ED_PRIV_KEY ($PRIV_KEY).
       Without it there is no way to prove the signing key matches the app's
       SUPublicEDKey, so this release refuses to sign a feed."
if [[ "$DERIVED_PUB_KEY" != "$BUNDLE_PUB_KEY" ]]; then
  fail "SIGNING KEY MISMATCH — refusing to generate a feed this app cannot trust.
       app SUPublicEDKey:      $BUNDLE_PUB_KEY
       key being signed with:  $DERIVED_PUB_KEY  (derived from $PRIV_KEY)
       Sparkle would emit an enclosure whose signature every client rejects.
       Sign with the key whose public half is baked into this build, or rebuild
       the release with NATIVEAGENT_SPARKLE_PUBLIC_KEY=$DERIVED_PUB_KEY."
fi
echo "==> Signing key verified: its public half IS the app's SUPublicEDKey ($BUNDLE_PUB_KEY)."

# Sparkle compares the bare CFBundleVersion; internal short-version suffixes forbid publication.
INTERNAL_DEV_SUFFIX_RE='^-dev\.([0-9a-f]{8}|nogit)(\.dirty)?$'
[[ "$BUNDLE_VERSION" == "$VERSION" ]] \
  || fail "version mismatch: VERSION=$VERSION but the bundle carries
       CFBundleVersion=$BUNDLE_VERSION.
       CFBundleVersion is Sparkle's comparison key and is never suffixed."
BUNDLE_IS_INTERNAL=false
if [[ "$BUNDLE_SHORT_VERSION" != "$VERSION" ]]; then
  SHORT_SUFFIX=""
  [[ "$BUNDLE_SHORT_VERSION" == "$VERSION"* ]] && SHORT_SUFFIX="${BUNDLE_SHORT_VERSION#"$VERSION"}"
  if [[ -n "$SHORT_SUFFIX" && "$SHORT_SUFFIX" =~ $INTERNAL_DEV_SUFFIX_RE ]]; then
    BUNDLE_IS_INTERNAL=true
    [[ "$PUBLISH" != "true" ]] \
      || fail "PUBLISH REFUSED — this DMG contains an INTERNAL build.
       CFBundleShortVersionString=$BUNDLE_SHORT_VERSION carries the internal
       '-dev.<sha>' marker, so it is not the artifact users are meant to receive.
       Rebuild the release with: ./script/release.sh --publish-appcast"
    echo "==> Internal build: CFBundleShortVersionString=$BUNDLE_SHORT_VERSION (--publish is refused for it)."
  else
    fail "version mismatch: VERSION=$VERSION but the bundle carries
       CFBundleShortVersionString=$BUNDLE_SHORT_VERSION.
       Only the internal marker '$VERSION-dev.<short8sha>[.dirty]' is accepted as
       a difference, and only on a non-publish run."
  fi
fi
# What the FEED is expected to advertise as its human-readable short version.
EXPECTED_SHORT_VERSION="$BUNDLE_SHORT_VERSION"
if [[ "$REHEARSAL" == "true" ]]; then
  [[ "$PUBLISH" != "true" ]] || fail "--rehearsal and --publish are mutually exclusive."
  echo "==> Rehearsal: skipping the bundle<->feed cross-checks (this app carries no feed URL)."
else
  [[ "$BUNDLE_FEED_URL" == "$APPCAST_URL" ]] \
    || fail "the app's SUFeedURL ($BUNDLE_FEED_URL) is not the feed being generated
       ($APPCAST_URL). Publishing here would leave the app pointed elsewhere."
  [[ "$BUNDLE_FEED_PUBLISHED" == "true" ]] \
    || fail "the app inside $DMG_BASENAME declares NativeAgentUpdateFeedPublished=$BUNDLE_FEED_PUBLISHED.
       That build's updater is honestly disabled, so publishing a feed for it would
       have no effect. Rebuild with: ./script/release.sh --publish-appcast"
fi

hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 4. Generate + sign, via Sparkle's own tooling (no hand-rolled XML, no
#    hand-rolled crypto).
# ---------------------------------------------------------------------------
GENERATE_APPCAST="$(sparkle_tool_path_or_die generate_appcast "$ROOT")"
SIGN_UPDATE="$(sparkle_tool_path_or_die sign_update "$ROOT")"

# This directory is wiped on every run, so refuse anything that is not clearly a
# scratch output dir. `--out dist` would otherwise delete the whole dist tree.
OUT_PARENT="$(dirname "$OUT_DIR")"
[[ -d "$OUT_PARENT" ]] || fail "--out parent directory does not exist: $OUT_PARENT"
OUT_DIR_ABS="$(cd "$OUT_PARENT" && pwd)/$(basename "$OUT_DIR")"
case "$PREVIOUS_DMG" in "$OUT_DIR_ABS/"*) fail "previous DMG must be outside the scratch output directory" ;; esac
case "$OUT_DIR_ABS" in
  "$ROOT"|"$ROOT/"|"$ROOT/dist"|/|"$HOME") fail "refusing to wipe $OUT_DIR_ABS as the appcast output dir." ;;
esac
if [[ -e "$OUT_DIR_ABS" ]]; then
  [[ -d "$OUT_DIR_ABS" ]] || fail "--out exists and is not a directory: $OUT_DIR_ABS"
  # Only reuse a directory this script created (or an empty one).
  if [[ -n "$(ls -A "$OUT_DIR_ABS" 2>/dev/null)" && ! -f "$OUT_DIR_ABS/.nativeagent-appcast-dir" ]]; then
    fail "--out directory is not empty and was not created by this script: $OUT_DIR_ABS"
  fi
fi
OUT_DIR="$OUT_DIR_ABS"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
touch "$OUT_DIR/.nativeagent-appcast-dir"
OUTPUT_STAGED=true
# Hardlink when possible (same volume) so a 66 MB DMG is not copied every release.
ln "$DMG_PATH" "$OUT_DIR/$DMG_BASENAME" 2>/dev/null || cp "$DMG_PATH" "$OUT_DIR/$DMG_BASENAME"
if [[ -n "$PREVIOUS_DMG" ]]; then
  ln "$PREVIOUS_DMG" "$OUT_DIR/$(basename "$PREVIOUS_DMG")" 2>/dev/null \
    || cp "$PREVIOUS_DMG" "$OUT_DIR/$(basename "$PREVIOUS_DMG")"
fi

APPCAST_XML="$OUT_DIR/appcast.xml"
GEN_LOG="$OUT_DIR/.generate_appcast.log"
MAXIMUM_DELTAS=1
[[ "${NATIVEAGENT_EMBEDDING_DISTRIBUTION:-bundled}" != bundled ]] || MAXIMUM_DELTAS=0
GEN_ARGS=(
  --ed-key-file "$PRIV_KEY"
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --versions "$VERSION"
  --maximum-versions 1
  --maximum-deltas "$MAXIMUM_DELTAS"
  -o "$APPCAST_XML"
)
if [[ -n "$RELEASE_PAGE_URL" ]]; then
  GEN_ARGS+=( --link "$RELEASE_PAGE_URL" )
fi

echo "==> Generating appcast for $DMG_BASENAME (v$VERSION)"
set +e
"$GENERATE_APPCAST" "${GEN_ARGS[@]}" "$OUT_DIR" >"$GEN_LOG" 2>&1
GEN_STATUS=$?
set -e
cat "$GEN_LOG"
[[ $GEN_STATUS -eq 0 ]] || fail "generate_appcast failed (exit $GEN_STATUS); see $GEN_LOG"

# ---------------------------------------------------------------------------
# 5. Verify the produced feed. Every assertion here is a way a feed can parse
#    and still be useless or dangerous.
# ---------------------------------------------------------------------------
[[ -f "$APPCAST_XML" ]] || fail "generate_appcast produced no $APPCAST_XML"
xmllint --noout "$APPCAST_XML" 2>/dev/null || fail "produced appcast.xml is not well-formed XML"

# Exactly one actual update item and its direct full-update enclosure.
ITEM='/rss/channel/item'
ENCLOSURE="$ITEM/enclosure"
ITEM_COUNT="$(xmllint --xpath "count($ITEM)" "$APPCAST_XML")"
[[ "$ITEM_COUNT" == "1" ]] \
  || fail "expected exactly 1 <item> in the generated feed, found $ITEM_COUNT."

[[ "$(xmllint --xpath "count($ENCLOSURE)" "$APPCAST_XML")" == 1 ]] || fail 'expected exactly one direct full-update enclosure'
attr() { xmllint --xpath "string($ENCLOSURE/@*[local-name()='$1'])" "$APPCAST_XML"; }
tag() { xmllint --xpath "string($ITEM/*[local-name()='$1' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'])" "$APPCAST_XML"; }

ENCLOSURE_URL="$(attr 'url')"
ENCLOSURE_LEN="$(attr 'length')"
ED_SIGNATURE="$(attr 'edSignature')"
FEED_VERSION="$(tag 'version')"
FEED_SHORT_VERSION="$(tag 'shortVersionString')"

[[ -n "$ED_SIGNATURE" ]] \
  || fail "the generated appcast has NO sparkle:edSignature on its enclosure.
       An unsigned feed is refused — Sparkle clients cannot install from it."
[[ "$ENCLOSURE_URL" == "$DOWNLOAD_URL" ]] \
  || fail "enclosure URL is $ENCLOSURE_URL but the DMG will live at $DOWNLOAD_URL"
ACTUAL_LEN="$(stat -f%z "$DMG_PATH")"
[[ "$ENCLOSURE_LEN" == "$ACTUAL_LEN" ]] \
  || fail "enclosure length $ENCLOSURE_LEN != actual DMG size $ACTUAL_LEN"
[[ "$FEED_VERSION" == "$VERSION" && "$FEED_SHORT_VERSION" == "$EXPECTED_SHORT_VERSION" ]] \
  || fail "feed advertises version=$FEED_VERSION short=$FEED_SHORT_VERSION, expected
       version=$VERSION short=$EXPECTED_SHORT_VERSION"

# VERSION is authoritative; matching the --version argument alone cannot establish currency.
if [[ -f "$ROOT/VERSION" ]]; then
  REPO_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  if [[ "$FEED_VERSION" != "$REPO_VERSION" ]]; then
    if [[ "$ALLOW_VERSION_DRIFT" == "true" ]]; then
      echo "    NOTE: feed version $FEED_VERSION != VERSION file $REPO_VERSION" >&2
      echo "          (allowed only because --allow-version-drift was passed; never on --publish)" >&2
    else
      fail "the generated feed advertises $FEED_VERSION but $ROOT/VERSION says $REPO_VERSION.
       Publishing this would tell every user they are current while the repo has
       moved on. Bump/settle VERSION and rebuild the DMG, or pass
       --allow-version-drift for a synthetic-version test run (never with --publish)."
    fi
  fi
fi
if grep -Eqi "$PLACEHOLDER_RE" "$APPCAST_XML"; then
  fail "the generated appcast still contains a placeholder URL; refusing to publish."
fi

# The feed's signature must verify against the DMG bytes with the trusted key.
"$SIGN_UPDATE" --verify --ed-key-file "$PRIV_KEY" "$DMG_PATH" "$ED_SIGNATURE" >/dev/null \
  || fail "the sparkle:edSignature in the generated feed does NOT verify against $DMG_BASENAME."

# Sparkle's own BinaryDelta implementation chooses whether a patch saves space.
# Keep full-DMG fallback when the baseline is incompatible or a delta is larger.
sparkle_validate_deltas "$APPCAST_XML" "$DOWNLOAD_PREFIX" "$PRIV_KEY" "$SIGN_UPDATE" \
  || fail 'Sparkle delta validation failed'
DELTA_COUNT="$SPARKLE_DELTA_COUNT"
echo "==> Verified $DELTA_COUNT Sparkle delta(s); full DMG remains available."

# Insert notes after artifact guards, then recheck XML, item count and the unchanged enclosure.
# EdDSA covers the DMG bytes, so notes do not alter its signature.
# Notes extensions decide format; unknown extensions use line-leading prose tags with code stripped.
notes_is_raw_html() { # $1 = notes file; 0 = raw HTML branch, 1 = markdown converter
  local f="$1" base ext
  base="$(basename -- "$f")"
  ext=""
  [[ "$base" == *.* ]] && ext="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    md|markdown|mdown|mkd|text|txt) return 1 ;;
    htm|html|xhtml)                 return 0 ;;
  esac
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    { gsub(/`[^`]*`/, ""); print }
  ' "$f" | grep -Eqi '^[[:space:]]*<(html|body|p|ul|ol|div|section|h[1-6])[[:space:]>/]'
}

if [[ -n "$NOTES_FILE" ]]; then
  echo "==> Embedding release notes from $NOTES_FILE"
  if notes_is_raw_html "$NOTES_FILE"; then
    NOTES_MODE="raw-html"
  else
    NOTES_MODE="converted"
  fi
  echo "    notes mode: $NOTES_MODE"
  ENCLOSURE_BEFORE="$(xmllint --xpath "$ENCLOSURE" "$APPCAST_XML")"
  NOTES_TMP="$OUT_DIR/.release-notes.fragment"
  {
    # Declare HTML rendering explicitly.
    printf '        <description sparkle:descriptionFormat="html"><![CDATA[\n'
    # CDATA cannot contain the terminator; split it if the notes ever do.
    if [[ "$NOTES_MODE" == "raw-html" ]]; then
      sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_FILE"
    else
      # The converter escapes input before emitting styled HTML, keeping CDATA terminators unreachable.
      swift "$ROOT/script/release_notes_html.swift" < "$NOTES_FILE" \
        || fail "release_notes_html.swift failed to convert $NOTES_FILE."
    fi
    printf '        ]]></description>\n'
  } > "$NOTES_TMP"

  # Insert immediately before the (single) </item>.
  NOTES_APPCAST="$OUT_DIR/.appcast.with-notes.xml"
  awk -v frag="$NOTES_TMP" '
    /<\/item>/ && !done { while ((getline line < frag) > 0) print line; close(frag); done = 1 }
    { print }
  ' "$APPCAST_XML" > "$NOTES_APPCAST"
  grep -q '<description' "$NOTES_APPCAST" \
    || fail "release notes were not inserted into the feed; refusing a silently-unchanged appcast."
  mv "$NOTES_APPCAST" "$APPCAST_XML"
  rm -f "$NOTES_TMP"

  # Re-assert every invariant the insertion could have broken.
  xmllint --noout "$APPCAST_XML" 2>/dev/null \
    || fail "the appcast is no longer well-formed XML after embedding $NOTES_FILE."
  ITEM_COUNT_AFTER="$(xmllint --xpath "count($ITEM)" "$APPCAST_XML")"
  [[ "$ITEM_COUNT_AFTER" == "1" ]] \
    || fail "embedding release notes changed the <item> count to $ITEM_COUNT_AFTER."
  ENCLOSURE_AFTER="$(xmllint --xpath "$ENCLOSURE" "$APPCAST_XML")"
  [[ "$ENCLOSURE_AFTER" == "$ENCLOSURE_BEFORE" ]] \
    || fail "embedding release notes altered the signed <enclosure> metadata. Refusing."
  [[ "$(tag 'version')" == "$VERSION" && "$(tag 'shortVersionString')" == "$EXPECTED_SHORT_VERSION" ]] \
    || fail "embedding release notes altered the advertised feed version. Refusing."

  # PAYLOAD guard. Every assertion above is structural — the notes text lives
  # inside CDATA, so a feed carrying raw markdown markers is still well-formed
  # XML with one <item> and an untouched enclosure. That is exactly how the
  # backtick-sniff bug shipped an unstyled, unescaped dialog past all of them.
  # When the CONVERTER branch ran, the rendered description must actually be the
  # converter's output: its wrapper class present, and no line-leading markdown
  # markers left over.
  if [[ "$NOTES_MODE" == "converted" ]]; then
    DESC_PAYLOAD="$(awk '
      /<description[[:space:]]/ { inside = 1; next }
      inside && /^[[:space:]]*\]\]><\/description>/ { inside = 0 }
      inside
    ' "$APPCAST_XML")"
    [[ -n "$DESC_PAYLOAD" ]] \
      || fail "the embedded <description> payload is empty after converting $NOTES_FILE."
    grep -q 'class="release-notes"' <<<"$DESC_PAYLOAD" \
      || fail "the markdown converter branch ran for $NOTES_FILE but the rendered
       description carries no class=\"release-notes\" wrapper — the notes would
       reach Sparkle's dialog unstyled. Refusing."
    # Exclude fenced-code bodies (<pre><code>…</code></pre>) from the marker
    # scan: verbatim code legitimately contains line-leading '#'/'-' and must
    # not fail the publish. Everything outside fences is rendered prose, where
    # a surviving marker means the converter missed a construct.
    DESC_PROSE="$(sed '/<pre><code>/,/<\/code><\/pre>/d' <<<"$DESC_PAYLOAD")"
    if grep -Eq '^[[:space:]]*(#{1,6}[[:space:]]|[-*+][[:space:]]|[0-9]+\.[[:space:]])' <<<"$DESC_PROSE"; then
      fail "the rendered description still contains line-leading markdown markers
       ('#' heading, '- ' list, or '1. ' ordered list) after conversion of
       $NOTES_FILE. The update dialog would show raw markers instead of
       formatted notes. Refusing."
    fi
  fi
  echo "    notes:     embedded as <description> ($(wc -c <"$NOTES_FILE" | tr -d ' ') bytes, $NOTES_MODE)"
fi

# Every guard passed — the feed may now survive on disk. (Set AFTER the notes
# step so a failed embed discards the feed like any other rejection.)
APPCAST_ACCEPTED=true

# The staged DMG was only ever input to generate_appcast. Drop it so the output
# directory contains exactly what gets published and a blind `rsync $OUT_DIR`
# cannot push a 60+ MB disk image onto the feed host.
rm -f "$OUT_DIR/$DMG_BASENAME"
rm -rf "$OUT_DIR/old_updates"

# Record the artifact digest alongside the feed so publishing can be audited.
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
cat > "$OUT_DIR/appcast.manifest.txt" <<MANIFEST
version=$VERSION
dmg=$DMG_BASENAME
dmg_sha256=$DMG_SHA256
dmg_length=$ACTUAL_LEN
enclosure_url=$ENCLOSURE_URL
appcast_url=$APPCAST_URL
ed_signature=$ED_SIGNATURE
public_key=$BUNDLE_PUB_KEY
short_version=$BUNDLE_SHORT_VERSION
internal_build=$BUNDLE_IS_INTERNAL
delta_count=$DELTA_COUNT
MANIFEST

echo ""
echo "==> Appcast generated and verified:"
echo "    feed:      $APPCAST_XML"
echo "    manifest:  $OUT_DIR/appcast.manifest.txt"
echo "    signature: verified against $DMG_BASENAME with the release key"
echo "    sha256:    $DMG_SHA256"

# ---------------------------------------------------------------------------
# 6. Publishing is explicit, never a side effect of generating.
# ---------------------------------------------------------------------------
if [[ "$PUBLISH" != "true" ]]; then
  echo ""
  if [[ "$REHEARSAL" == "true" ]]; then
    echo "==> Rehearsal complete: the signing pipeline works end to end. Nothing was"
    echo "    uploaded, and this feed must NOT be hand-published — the app it"
    echo "    describes has no SUFeedURL and would never read it."
  else
    echo "==> --publish NOT passed: nothing was uploaded. The feed above is local only."
  fi
  exit 0
fi

PUBLISH_CMD="${NATIVE_AGENT_APPCAST_PUBLISH_CMD:-${NATIVEAGENT_APPCAST_PUBLISH_CMD:-}}"
[[ -n "$PUBLISH_CMD" ]] || fail "--publish requires NATIVEAGENT_APPCAST_PUBLISH_CMD.
       It receives NATIVEAGENT_PUBLISH_APPCAST, NATIVEAGENT_PUBLISH_DMG,
       NATIVEAGENT_PUBLISH_TEST_RECEIPT, NATIVEAGENT_PUBLISH_ATTESTATION and
       NATIVEAGENT_PUBLISH_MODEL_ASSET, NATIVEAGENT_PUBLISH_APPCAST_URL and must
       upload these artifacts plus every delta referenced by the feed."

echo ""
echo "==> Publishing via NATIVEAGENT_APPCAST_PUBLISH_CMD"
VERIFY_STATUS=0
nativeagent_publish_appcast_and_verify \
  "$PUBLISH_CMD" "$APPCAST_XML" "$DMG_PATH" "$APPCAST_URL" "$DOWNLOAD_URL" \
  "$VERSION" "$REHEARSAL" "$ENCLOSURE_LEN" "$MOUNT_BASE/verify" || VERIFY_STATUS=$?

if [[ $VERIFY_STATUS -eq 3 ]]; then
  fail "$NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON"
elif [[ $VERIFY_STATUS -eq 2 ]]; then
  fail "$NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON"
elif [[ $VERIFY_STATUS -ne 0 ]]; then
  VERIFY_ATTEMPTS="$NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS"
  verify_note="$NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON"
  # Keep the valid local feed with a warning: its advertised DMG was not verified live.
  cat > "$OUT_DIR/.PUBLISH-FAILED-DO-NOT-UPLOAD.txt" <<TXT
Publication of this feed was attempted and could NOT be verified live.

  reason: $verify_note

appcast.xml here is correctly signed for its DMG, but the DMG was not confirmed
present at $DOWNLOAD_URL. Uploading this feed by hand would advertise an update
that users cannot download. Re-run ./script/release.sh --publish-appcast instead.
TXT
  fail "PUBLISH NOT VERIFIED after $VERIFY_ATTEMPTS attempt(s): $verify_note

       NATIVEAGENT_APPCAST_PUBLISH_CMD exited 0, but the feed and DMG are not
       both live at the URLs this build was stamped with. Treating that exit code
       as proof is exactly how a shipped app ends up polling a 404.
       The release is NOT published."
fi

echo "    appcast: $APPCAST_URL  (sha256 $NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_APPCAST_SHA — matches local)"
echo "    dmg:     $DOWNLOAD_URL  ($NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_DMG_LEN bytes — matches the enclosure)"
echo "==> Published and VERIFIED live: $APPCAST_URL"
