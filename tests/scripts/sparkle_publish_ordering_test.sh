#!/usr/bin/env bash
# A2.1 round 2 (2026-07-24): guards for the three ways the Sparkle publish path
# could still ship a lying artifact. Each was found by an independent gpt-5.5
# review of the round-1 work; each is exercised here for real, not grepped for.
#
#   1. ORDERING (BLOCKING) — a failed publish must leave NOTHING shippable behind.
#      release.sh stamps "feed published" into the app before the feed can exist,
#      so artifacts are quarantined until publication is verified.
#   2. EXIT CODE IS NOT EXISTENCE (BLOCKING) — NATIVEAGENT_APPCAST_PUBLISH_CMD=true
#      exits 0 and uploads nothing. Publication is only real once the feed and the
#      DMG have been FETCHED from their advertised URLs and matched byte-for-byte.
#   3. PLIST TYPE CONFUSION (MEDIUM) — <string>true</string> printed "true" to the
#      verifier while Swift's `as? Bool` read nil, i.e. verified artifact, dead
#      updater. Types are asserted, not printed text.
#
# Every temp path here deliberately contains a space: User's paths do.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GENERATE="$ROOT/script/generate_appcast.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent sparkle publish.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Quarantine: a failed publish leaves no shippable artifact.
#    Exercises the SAME functions release.sh calls.
# ---------------------------------------------------------------------------
# shellcheck source=../../script/lib/release_quarantine.sh
source "$ROOT/script/lib/release_quarantine.sh"

DIST="$TMP_ROOT/dist dir"
QDIR="$DIST/.pending-publish"
QDIR_STALE_SRC="$DIST/NativeAgent-0.1.9.dmg"
mkdir -p "$DIST/NativeAgent.app/Contents"
printf 'dmg bytes\n' > "$DIST/NativeAgent-9.9.9.dmg"
printf 'zip bytes\n' > "$DIST/NativeAgent.app.zip"
printf 'plist\n' > "$DIST/NativeAgent.app/Contents/Info.plist"

release_quarantine_init "$QDIR" "test: publish pending"
QDMG="$(release_quarantine_take "$QDIR" "$DIST/NativeAgent-9.9.9.dmg")"
QAPP="$(release_quarantine_take "$QDIR" "$DIST/NativeAgent.app")"
release_quarantine_take "$QDIR" "$DIST/NativeAgent.app.zip" >/dev/null
# A missing optional artifact must be skipped, not crash the release.
release_quarantine_take "$QDIR" "$DIST/does-not-exist.dmg" >/dev/null

[[ -f "$QDMG" ]] || fail "quarantine did not move the DMG (got '$QDMG')"
[[ -d "$QAPP/Contents" ]] || fail "quarantine did not move the app bundle intact"
# THE invariant: while publication is unproven, no ship-ready name exists.
shopt -s nullglob
leftover=( "$DIST"/*.dmg "$DIST"/*.zip )
shopt -u nullglob
[[ ! -e "$DIST/NativeAgent.app" ]] || leftover+=( "$DIST/NativeAgent.app" )
[[ ${#leftover[@]} -eq 0 ]] \
  || fail "a shippable artifact survived a pending publish: ${leftover[*]}"
[[ -f "$QDIR/.QUARANTINE-DO-NOT-SHIP.txt" ]] || fail "quarantine dir has no DO-NOT-SHIP note"
grep -q '404' "$QDIR/.QUARANTINE-DO-NOT-SHIP.txt" \
  || fail "the quarantine note does not explain the 404 consequence"

# Promotion is the only exit, and it must restore every artifact.
release_quarantine_promote "$QDIR" "$DIST"
[[ -f "$DIST/NativeAgent-9.9.9.dmg" ]] || fail "promotion did not restore the DMG"
[[ -f "$DIST/NativeAgent.app/Contents/Info.plist" ]] || fail "promotion did not restore the app bundle"
[[ -f "$DIST/NativeAgent.app.zip" ]] || fail "promotion did not restore the notarization zip"
[[ ! -d "$QDIR" ]] || fail "quarantine dir survived a successful promotion"

# A re-run after a failed publish must promote the NEW bytes, not resurrect the
# stale quarantined ones (same filenames, so an unlucky mv order could).
printf 'stale dmg\n' > "$DIST/NativeAgent-9.9.9.dmg"
release_quarantine_init "$QDIR" "test: stale run pending"
release_quarantine_take "$QDIR" "$DIST/NativeAgent-9.9.9.dmg" >/dev/null
printf 'fresh dmg\n' > "$DIST/NativeAgent-9.9.9.dmg"
release_quarantine_take "$QDIR" "$DIST/NativeAgent-9.9.9.dmg" >/dev/null
release_quarantine_promote "$QDIR" "$DIST"
[[ "$(cat "$DIST/NativeAgent-9.9.9.dmg")" == "fresh dmg" ]] \
  || fail "a re-run promoted the stale quarantined DMG instead of the rebuilt one"

# Only artifacts THIS run registered may be promoted: a previous failed run's
# never-published artifacts must not ride out on someone else's verification.
printf 'v0.1.9 never published\n' > "$QDIR_STALE_SRC"
release_quarantine_init "$QDIR" "test: run A pending"
release_quarantine_take "$QDIR" "$QDIR_STALE_SRC" >/dev/null   # run A dies here
release_quarantine_init "$QDIR" "test: run B pending"          # run B starts clean
printf 'v0.2.0 dmg\n' > "$DIST/NativeAgent-0.2.0.dmg"
release_quarantine_take "$QDIR" "$DIST/NativeAgent-0.2.0.dmg" >/dev/null
release_quarantine_promote "$QDIR" "$DIST"
[[ -f "$DIST/NativeAgent-0.2.0.dmg" ]] || fail "run B's own artifact was not promoted"
[[ ! -e "$DIST/NativeAgent-0.1.9.dmg" ]] \
  || fail "an earlier failed run's UNPUBLISHED artifact was promoted by a later run"
[[ -f "$QDIR/NativeAgent-0.1.9.dmg" ]] \
  || fail "the earlier run's artifact should stay quarantined, not vanish"
rm -rf "$QDIR"

# release.sh must BUILD into quarantine (not move at the end) and only release
# after publishing.
grep -Fq 'STAGE_DIR="$QUARANTINE_DIR"' "$ROOT/script/release.sh" \
  || fail "release.sh no longer stages a --publish-appcast build inside the quarantine dir"
grep -Fq 'NATIVEAGENT_DMG_OUT_DIR="$STAGE_DIR"' "$ROOT/script/release.sh" \
  || fail "release.sh no longer builds the DMG into the staging/quarantine dir"
# The staging decision must come BEFORE the app is staged and signed, or an abort
# during notarize/staple leaves a feed-claiming bundle under its shippable name.
awk '/STAGE_DIR="\$QUARANTINE_DIR"/ { stage=NR }
     /^BUNDLE="\$STAGE_DIR\/\$APP_NAME.app"/ { bundle=NR }
     END { exit !(stage && bundle && stage < bundle) }' "$ROOT/script/release.sh" \
  || fail "release.sh decides where to stage AFTER defining the bundle path"
awk '/generate_appcast.sh" "\$\{APPCAST_ARGS\[@\]\}"/ { gen=NR }
     /release_quarantine_promote/ { promote=NR }
     END { exit !(gen && promote && gen < promote) }' "$ROOT/script/release.sh" \
  || fail "release.sh promotes artifacts BEFORE the appcast is published — the ordering bug is back"

# dmg_builder must not leave its populated temp image behind on a failed convert.
grep -Fq 'rm -f "$TMP_DMG" 2>/dev/null || true' "$ROOT/script/dmg_builder.sh" \
  || fail "dmg_builder no longer removes its mountable temp image on every exit path"
awk '/^trap cleanup EXIT/ { armed=NR }
     /^trap - EXIT/ { disarmed=NR }
     /hdiutil convert/ { convert=NR }
     END { exit !(armed && convert && (!disarmed || disarmed > convert)) }' "$ROOT/script/dmg_builder.sh" \
  || fail "dmg_builder disarms its cleanup trap before the temp image is gone"
grep -Fq 'NATIVEAGENT_DMG_OUT_DIR' "$ROOT/script/dmg_builder.sh" \
  || fail "dmg_builder no longer honours the quarantined output directory"

# generate_appcast must not leave the DMG it staged for Sparkle lying in the
# output dir when the feed was rejected.
grep -Fq 'rm -f "$OUT_DIR/$DMG_BASENAME"' "$ROOT/script/generate_appcast.sh" \
  || fail "generate_appcast no longer removes the DMG it staged into the output dir"

# ---------------------------------------------------------------------------
# 2. Plist TYPE assertions (the same lib the verifier runs).
# ---------------------------------------------------------------------------
# shellcheck source=../../script/lib/plist_types.sh
source "$ROOT/script/lib/plist_types.sh"

write_plist() { # $1 dest, $2 xml body for NativeAgentUpdateFeedPublished
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NativeAgentUpdateFeedPublished</key>$2
  <key>SUFeedURL</key><string>https://updates.example.test/appcast.xml</string>
</dict></plist>
PLIST
}
PL="$TMP_ROOT/Info real.plist"
write_plist "$PL" '<true/>'
[[ "$(plist_bool_state "$PL" NativeAgentUpdateFeedPublished)" == "true" ]] \
  || fail "a real <true/> is not recognised as true"
write_plist "$PL" '<false/>'
[[ "$(plist_bool_state "$PL" NativeAgentUpdateFeedPublished)" == "false" ]] \
  || fail "a real <false/> is not recognised as false"
write_plist "$PL" '<string>true</string>'
state="$(plist_bool_state "$PL" NativeAgentUpdateFeedPublished)"
[[ "$state" == "non-boolean:string" ]] \
  || fail "<string>true</string> is not detected as a non-Boolean (got '$state')"
write_plist "$PL" '<integer>1</integer>'
[[ "$(plist_bool_state "$PL" NativeAgentUpdateFeedPublished)" == "non-boolean:integer" ]] \
  || fail "<integer>1</integer> is not detected as a non-Boolean"
[[ "$(plist_bool_state "$PL" NotAKeyAtAll)" == "absent" ]] \
  || fail "a missing key is not reported absent"
[[ "$(plist_string_state "$PL" SUFeedURL)" == "string" ]] \
  || fail "a real <string> SUFeedURL is not recognised"
[[ "$(plist_string_state "$PL" NativeAgentUpdateFeedPublished)" == "other" ]] \
  || fail "a non-string SUFeedURL type is not rejected"

# The verifier must consume the lib (a type check only the test knows is no gate).
grep -Fq 'require_plist_bool_or_absent "$INFO" "NativeAgentUpdateFeedPublished"' "$ROOT/script/verify_release_artifact.sh" \
  || fail "verify_release_artifact.sh no longer type-checks NativeAgentUpdateFeedPublished"
grep -Fq 'require_plist_bool_or_absent "$INFO" "SUEnableAutomaticChecks"' "$ROOT/script/verify_release_artifact.sh" \
  || fail "verify_release_artifact.sh no longer type-checks SUEnableAutomaticChecks"
# fail() inside $(...) exits only the subshell — the verifier must not read these
# through a command substitution, or a type violation becomes a warning.
grep -Eq '\$\(require_plist_bool_or_absent' "$ROOT/script/verify_release_artifact.sh" \
  && fail "verify_release_artifact.sh calls require_plist_bool_or_absent in a subshell; its fail() cannot abort"

# ---------------------------------------------------------------------------
# 2b. The real verifier, on a real bundle: a stringified Boolean must be REJECTED
#     (the lib check above proves the helper; this proves the verifier uses it).
# ---------------------------------------------------------------------------
VBUNDLE="$TMP_ROOT/verify me/NativeAgent.app"
mkdir -p "$VBUNDLE/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$VBUNDLE/Contents/MacOS/NativeAgentApp"
chmod +x "$VBUNDLE/Contents/MacOS/NativeAgentApp"
REPO_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
write_bundle_plist() { # $1 = XML for NativeAgentUpdateFeedPublished
  cat > "$VBUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.embwl0x.nativeagent.mac</string>
  <key>CFBundleExecutable</key><string>NativeAgentApp</string>
  <key>CFBundleShortVersionString</key><string>$REPO_VERSION</string>
  <key>CFBundleVersion</key><string>$REPO_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>com.nativeagent.chat-session</string></dict></array>
  <key>SUFeedURL</key><string>https://updates.nativeagent.dev/appcast.xml</string>
  <key>NativeAgentUpdateFeedPublished</key>$1
</dict></plist>
PLIST
}
run_verifier() {
  set +e
  # Developer installs may export their private bundle identity in the parent
  # shell. This fixture is deliberately a public release bundle, so pin the
  # verifier contract instead of letting machine-local signing state leak into
  # the test.
  NATIVEAGENT_EXPECTED_MAC_BUNDLE_ID=io.github.embwl0x.nativeagent.mac \
    bash "$ROOT/script/verify_release_artifact.sh" --bundle "$VBUNDLE" 2>&1
  local rc=$?
  set -e
  return $rc
}
write_bundle_plist '<string>true</string>'
if out="$(run_verifier)"; then
  fail "the verifier ACCEPTED a bundle whose NativeAgentUpdateFeedPublished is a string"
fi
grep -q 'must be a real Boolean' <<<"$out" \
  || fail "the verifier rejected the stringified flag for the wrong reason: $out"
# Sanity: a real Boolean must clear the type gate (it fails later on unrelated
# missing Resources — proof the gate is not simply always-failing).
write_bundle_plist '<true/>'
out="$(run_verifier || true)"
grep -q 'must be a real Boolean' <<<"$out" \
  && fail "a genuine <true/> is rejected by the Boolean type gate: $out"

# ---------------------------------------------------------------------------
# 3. Publish verification: exit 0 is not existence.
#    A stub `curl` earlier on PATH plays the role of the release host, so the
#    real comparison logic in generate_appcast.sh runs offline and deterministically.
# ---------------------------------------------------------------------------
SPARKLE_GEN=""
# shellcheck source=../../script/lib/sparkle_tools.sh
source "$ROOT/script/lib/sparkle_tools.sh"
SPARKLE_GEN="$(sparkle_tool_path generate_appcast "$ROOT" || true)"
if [[ -z "$SPARKLE_GEN" ]]; then
  echo "[test] SKIP publish-verification e2e: Sparkle's generate_appcast is absent"
  echo "[test]      (run 'swift build' once to fetch it; the guards above still ran)"
  echo "[test] sparkle publish ordering + verification guards OK (e2e skipped)"
  exit 0
fi

# The generated feed must match the repo VERSION file (sweep R4 C1), and that
# gate has no --publish escape — so the e2e fixture is built at the repo version
# rather than a synthetic one.
FIXTURE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ -n "$FIXTURE_VERSION" ]] || fail "could not read $ROOT/VERSION"

WORK="$TMP_ROOT/e2e work"
mkdir -p "$WORK/stage/NativeAgent.app/Contents/MacOS" "$WORK/out" "$WORK/host" "$WORK/bin"

# A throwaway signing key — the release key is never involved in tests. Generated
# by the same Swift helper the release path derives with (--new prints "seed pub").
KEYPAIR="$(swift "$ROOT/script/sparkle_ed_public_key.swift" --new)" \
  || fail "could not generate a throwaway Sparkle key pair"
printf '%s' "${KEYPAIR%% *}" > "$WORK/priv.key"
PUB="${KEYPAIR##* }"
[[ -n "$PUB" && "$PUB" != "$KEYPAIR" ]] || fail "unexpected --new output: $KEYPAIR"
# Round-trip: deriving from the key file must reproduce the advertised public half.
DERIVED="$(swift "$ROOT/script/sparkle_ed_public_key.swift" "$WORK/priv.key")"
[[ "$DERIVED" == "$PUB" ]] \
  || fail "the Swift derivation does not round-trip its own key pair ($DERIVED != $PUB)"
APPCAST_URL="https://updates.nativeagent.test/appcast.xml"
DMG_URL="https://dl.nativeagent.test/NativeAgent-$FIXTURE_VERSION.dmg"
cat > "$WORK/stage/NativeAgent.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.embwl0x.nativeagent.mac</string>
  <key>CFBundleExecutable</key><string>NativeAgentApp</string>
  <key>CFBundleName</key><string>NativeAgent</string>
  <key>CFBundleVersion</key><string>$FIXTURE_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$FIXTURE_VERSION</string>
  <key>SUPublicEDKey</key><string>$PUB</string>
  <key>SUFeedURL</key><string>$APPCAST_URL</string>
  <key>NativeAgentUpdateFeedPublished</key><true/>
  <key>SUEnableAutomaticChecks</key><true/>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$WORK/stage/NativeAgent.app/Contents/MacOS/NativeAgentApp"
chmod +x "$WORK/stage/NativeAgent.app/Contents/MacOS/NativeAgentApp"
TEST_DMG="$WORK/NativeAgent-$FIXTURE_VERSION.dmg"
hdiutil create -quiet -srcfolder "$WORK/stage" -volname NativeAgent -format UDZO -ov "$TEST_DMG" \
  || fail "could not build the synthetic test DMG"

# The stub host: $HOST_DIR/appcast.xml and $HOST_DIR/dmg are what it "serves".
cat > "$WORK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# Test double for the release host. Understands exactly the three shapes
# generate_appcast.sh uses: body GET, HEAD, and a 1-byte ranged GET.
set -uo pipefail
HOST="${NATIVEAGENT_TEST_HOST_DIR:?}"
out=""; dump=""; head_only=false; ranged=false; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) dump="$2"; shift 2 ;;
    -r) ranged=true; shift 2 ;;
    --max-time) shift 2 ;;
    -fsSLI) head_only=true; shift ;;
    -fsSL|-fsS|-f|-s|-S|-L) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */appcast.xml) src="$HOST/appcast.xml" ;;
  *.dmg)         src="$HOST/dmg" ;;
  *)             echo "curl: (22) unexpected URL $url" >&2; exit 22 ;;
esac
[[ -f "$src" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
len="$(stat -f%z "$src")"
if [[ "$head_only" == "true" ]]; then
  # Some real hosts answer HEAD without a length; the caller must then fall back
  # to a ranged GET. NATIVEAGENT_TEST_NO_HEAD_LENGTH exercises that branch.
  if [[ "${NATIVEAGENT_TEST_NO_HEAD_LENGTH:-0}" == "1" ]]; then
    printf 'HTTP/2 200\r\n\r\n' > "${out:-/dev/stdout}"
  else
    printf 'HTTP/2 200\r\nContent-Length: %s\r\n\r\n' "$len" > "${out:-/dev/stdout}"
  fi
  exit 0
fi
if [[ "$ranged" == "true" ]]; then
  # A host that IGNORES Range answers 200 with the full body and a plain
  # Content-Length and no Content-Range. That is still a valid answer.
  if [[ "${NATIVEAGENT_TEST_IGNORE_RANGE:-0}" == "1" ]]; then
    [[ -n "$dump" ]] && printf 'HTTP/2 200\r\nContent-Length: %s\r\n\r\n' "$len" > "$dump"
    [[ -n "$out" ]] && cp "$src" "$out"
    exit 0
  fi
  [[ -n "$dump" ]] && printf 'HTTP/2 206\r\nContent-Range: bytes 0-0/%s\r\n\r\n' "$len" > "$dump"
  [[ -n "$out" ]] && head -c 1 "$src" > "$out"
  exit 0
fi
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
exit 0
SHIM
chmod +x "$WORK/bin/curl"

run_publish() { # $1 = out subdir; echoes combined output, never aborts
  local outdir="$WORK/out/$1"
  mkdir -p "$outdir"
  set +e
  ( cd "$ROOT" && PATH="$WORK/bin:$PATH" \
      NATIVEAGENT_TEST_HOST_DIR="$WORK/host" \
      NATIVEAGENT_TEST_NO_HEAD_LENGTH="${NO_HEAD_LENGTH:-0}" \
      NATIVEAGENT_TEST_IGNORE_RANGE="${IGNORE_RANGE:-0}" \
      env -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVE_AGENT_APPCAST_URL \
          -u NATIVE_AGENT_DMG_DOWNLOAD_URL -u NATIVE_AGENT_RELEASE_PAGE_URL \
          -u NATIVEAGENT_RELEASE_PAGE_URL \
      NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$WORK/priv.key" \
      NATIVEAGENT_APPCAST_URL="$APPCAST_URL" \
      NATIVEAGENT_DMG_DOWNLOAD_URL="$DMG_URL" \
      NATIVEAGENT_APPCAST_PUBLISH_CMD="$PUBLISH_CMD" \
      NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS=1 NATIVEAGENT_APPCAST_VERIFY_DELAY=0 \
      bash "$GENERATE" --dmg "$TEST_DMG" --version "$FIXTURE_VERSION" --out "$outdir/appcast" --publish 2>&1 )
  set -e
}

# (a) the canonical fake success: exits 0, uploads nothing.
rm -f "$WORK/host/appcast.xml" "$WORK/host/dmg"
PUBLISH_CMD='true'
out="$(run_publish a)"
grep -q 'PUBLISH NOT VERIFIED' <<<"$out" \
  || fail "PUBLISH_CMD=true was accepted as a successful publish: $out"
grep -q 'Published and VERIFIED live' <<<"$out" \
  && fail "a no-op publish command printed a success line: $out"

# (b) DMG uploaded, feed forgotten — the 404-poll shape itself.
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_DMG" "$NATIVEAGENT_TEST_HOST_DIR/dmg"'
out="$(run_publish b)"
grep -q 'PUBLISH NOT VERIFIED' <<<"$out" \
  || fail "a DMG-only upload was accepted as a published feed: $out"

# (c) feed live, but the DMG at the enclosure URL is a different length.
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_APPCAST" "$NATIVEAGENT_TEST_HOST_DIR/appcast.xml"; printf short > "$NATIVEAGENT_TEST_HOST_DIR/dmg"'
out="$(run_publish c)"
grep -q 'PUBLISH NOT VERIFIED' <<<"$out" \
  || fail "a wrong-length DMG at the enclosure URL was accepted: $out"
grep -q 'advertises' <<<"$out" \
  || fail "the length mismatch was not the reported reason: $out"

# (d) feed served but not the feed we signed (stale/other upload).
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_DMG" "$NATIVEAGENT_TEST_HOST_DIR/dmg"; { cat "$NATIVEAGENT_PUBLISH_APPCAST"; echo "<!-- tampered -->"; } > "$NATIVEAGENT_TEST_HOST_DIR/appcast.xml"'
out="$(run_publish d)"
grep -q 'is NOT the feed just generated' <<<"$out" \
  || fail "a different appcast at the feed URL was accepted: $out"

# (e) a real, complete publish — verification must PASS, or every guard above is
#     just an always-fail check.
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_APPCAST" "$NATIVEAGENT_TEST_HOST_DIR/appcast.xml"; cp "$NATIVEAGENT_PUBLISH_DMG" "$NATIVEAGENT_TEST_HOST_DIR/dmg"'
out="$(run_publish e)"
grep -q 'Published and VERIFIED live' <<<"$out" \
  || fail "a genuine, complete publish was NOT accepted: $out"

# (e2) same complete publish against a host whose HEAD omits Content-Length: the
#      ranged-GET fallback must still confirm the true size (not assume it).
NO_HEAD_LENGTH=1
out="$(run_publish e2)"
NO_HEAD_LENGTH=0
grep -q 'Published and VERIFIED live' <<<"$out" \
  || fail "the ranged-GET length fallback does not confirm a good publish: $out"

# (e3) host that omits HEAD Content-Length AND ignores Range: the 200-with-
#      Content-Length answer must still be accepted (parsing only Content-Range
#      would fail a legitimate publish).
NO_HEAD_LENGTH=1
IGNORE_RANGE=1
out="$(run_publish e3)"
NO_HEAD_LENGTH=0
IGNORE_RANGE=0
grep -q 'Published and VERIFIED live' <<<"$out" \
  || fail "a host that ignores Range breaks verification of a good publish: $out"

# (e4) STALE CDN, SAME LENGTH (gpt-5.5 final review BLOCKING, 2026-07-25):
#      the served DMG matches the advertised byte length but carries DIFFERENT
#      bytes — a stale edge cache or wrong upload. Size-only verification
#      passed this; the sha256 fetch-verify must refuse it.
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_APPCAST" "$NATIVEAGENT_TEST_HOST_DIR/appcast.xml"; cp "$NATIVEAGENT_PUBLISH_DMG" "$NATIVEAGENT_TEST_HOST_DIR/dmg"; printf X | dd of="$NATIVEAGENT_TEST_HOST_DIR/dmg" bs=1 seek=64 count=1 conv=notrunc 2>/dev/null'
out="$(run_publish e4)"
grep -q 'same length, DIFFERENT bytes' <<<"$out" \
  || fail "a same-length stale DMG passed byte verification: $out"
grep -q 'Published and VERIFIED live' <<<"$out" \
  && fail "a same-length stale DMG printed the success line: $out"

# (f) signing with a key the app does not trust must be refused by arithmetic,
#     not by Sparkle's warning prose.
WRONG_PAIR="$(swift "$ROOT/script/sparkle_ed_public_key.swift" --new)" \
  || fail "could not generate a second throwaway key pair"
printf '%s' "${WRONG_PAIR%% *}" > "$WORK/wrong.key"
set +e
out="$( cd "$ROOT" && PATH="$WORK/bin:$PATH" NATIVEAGENT_TEST_HOST_DIR="$WORK/host" \
  env -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVE_AGENT_APPCAST_URL -u NATIVE_AGENT_DMG_DOWNLOAD_URL \
      -u NATIVEAGENT_RELEASE_PAGE_URL -u NATIVE_AGENT_RELEASE_PAGE_URL \
  NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$WORK/wrong.key" \
  NATIVEAGENT_APPCAST_URL="$APPCAST_URL" NATIVEAGENT_DMG_DOWNLOAD_URL="$DMG_URL" \
  bash "$GENERATE" --dmg "$TEST_DMG" --version "$FIXTURE_VERSION" --out "$WORK/out/f/appcast" 2>&1 )"
set -e
grep -q 'SIGNING KEY MISMATCH' <<<"$out" \
  || fail "signing with a key the bundle does not trust was not refused: $out"

# ---------------------------------------------------------------------------
# 4. Sweep R4 C1/C12: the VERSION-file gate and release notes.
# ---------------------------------------------------------------------------
# (g) a feed version that disagrees with the repo VERSION file is refused, and
#     the drift escape hatch can never be combined with --publish.
set +e
out="$( cd "$ROOT" && env -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVEAGENT_SPARKLE_ED_PRIV_KEY \
  bash "$GENERATE" --dmg "$TEST_DMG" --version 0.0.0 --allow-version-drift --publish 2>&1 )"
set -e
grep -q -- '--allow-version-drift and --publish are mutually exclusive' <<<"$out" \
  || fail "a published feed can still be signed with --allow-version-drift: $out"
grep -Fq 'says $REPO_VERSION' "$GENERATE" \
  || fail "generate_appcast.sh no longer gates the feed version against the VERSION file"

# (g2) the gate must actually FIRE, not merely exist: a DMG whose bundle+feed
#      version is internally consistent but DISAGREES with the repo VERSION file
#      is exactly the 0.3.2-vs-0.3.7 shape that stranded users. Refused without
#      the escape hatch; accepted with it.
DRIFT_VERSION="9.9.9"
[[ "$DRIFT_VERSION" != "$FIXTURE_VERSION" ]] || DRIFT_VERSION="9.9.8"
mkdir -p "$WORK/drift stage/NativeAgent.app/Contents/MacOS" "$WORK/out/g2"
sed -e "s/>$FIXTURE_VERSION</>$DRIFT_VERSION</g" \
  "$WORK/stage/NativeAgent.app/Contents/Info.plist" > "$WORK/drift stage/NativeAgent.app/Contents/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$WORK/drift stage/NativeAgent.app/Contents/MacOS/NativeAgentApp"
chmod +x "$WORK/drift stage/NativeAgent.app/Contents/MacOS/NativeAgentApp"
DRIFT_DMG="$WORK/NativeAgent-$DRIFT_VERSION.dmg"
hdiutil create -quiet -srcfolder "$WORK/drift stage" -volname NativeAgent -format UDZO -ov "$DRIFT_DMG" \
  || fail "could not build the drift-version test DMG"
run_drift() { # $@ extra generate args; echoes combined output, never aborts
  set +e
  ( cd "$ROOT" && env -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVE_AGENT_APPCAST_URL \
      -u NATIVE_AGENT_DMG_DOWNLOAD_URL -u NATIVE_AGENT_RELEASE_PAGE_URL \
      -u NATIVEAGENT_RELEASE_PAGE_URL \
    NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$WORK/priv.key" \
    NATIVEAGENT_APPCAST_URL="$APPCAST_URL" \
    NATIVEAGENT_DMG_DOWNLOAD_URL="https://dl.nativeagent.test/NativeAgent-$DRIFT_VERSION.dmg" \
    bash "$GENERATE" --dmg "$DRIFT_DMG" --version "$DRIFT_VERSION" "$@" 2>&1 )
  set -e
}
out="$(run_drift --out "$WORK/out/g2/refused")"
grep -q "but .*VERSION says $FIXTURE_VERSION" <<<"$out" \
  || fail "a feed advertising $DRIFT_VERSION while VERSION says $FIXTURE_VERSION was NOT refused: $out"
[[ ! -f "$WORK/out/g2/refused/appcast.xml" ]] \
  || fail "the version-mismatched feed survived on disk"
out="$(run_drift --allow-version-drift --out "$WORK/out/g2/allowed")"
grep -q 'Appcast generated and verified' <<<"$out" \
  || fail "--allow-version-drift does not permit a synthetic-version run: $out"

# (h) release notes are embedded as a <description> and the publish still
#     verifies — the signed enclosure must be untouched by the insertion.
mkdir -p "$WORK/out/h"
NOTES="$WORK/notes.md"
printf 'Fixed the thing.\nAlso <b>escaped</b> & safe.\n' > "$NOTES"
PUBLISH_CMD='cp "$NATIVEAGENT_PUBLISH_APPCAST" "$NATIVEAGENT_TEST_HOST_DIR/appcast.xml"; cp "$NATIVEAGENT_PUBLISH_DMG" "$NATIVEAGENT_TEST_HOST_DIR/dmg"'
set +e
out="$( cd "$ROOT" && PATH="$WORK/bin:$PATH" NATIVEAGENT_TEST_HOST_DIR="$WORK/host" \
  env -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVE_AGENT_APPCAST_URL \
      -u NATIVE_AGENT_DMG_DOWNLOAD_URL -u NATIVE_AGENT_RELEASE_PAGE_URL \
      -u NATIVEAGENT_RELEASE_PAGE_URL \
  NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$WORK/priv.key" \
  NATIVEAGENT_APPCAST_URL="$APPCAST_URL" NATIVEAGENT_DMG_DOWNLOAD_URL="$DMG_URL" \
  NATIVEAGENT_APPCAST_PUBLISH_CMD="$PUBLISH_CMD" \
  NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS=1 NATIVEAGENT_APPCAST_VERIFY_DELAY=0 \
  bash "$GENERATE" --dmg "$TEST_DMG" --version "$FIXTURE_VERSION" --notes "$NOTES" \
       --out "$WORK/out/h/appcast" --publish 2>&1 )"
set -e
grep -q 'Published and VERIFIED live' <<<"$out" \
  || fail "a publish carrying release notes was rejected: $out"
grep -q '<description>' "$WORK/out/h/appcast/appcast.xml" \
  || fail "release notes were not embedded in the feed"
grep -q 'Fixed the thing' "$WORK/out/h/appcast/appcast.xml" \
  || fail "the embedded description does not carry the notes text"
[[ "$(grep -c '<item>' "$WORK/out/h/appcast/appcast.xml")" == "1" ]] \
  || fail "embedding notes changed the feed item count"
grep -q 'sparkle:edSignature' "$WORK/out/h/appcast/appcast.xml" \
  || fail "the signed enclosure did not survive the notes insertion"
[[ ! -e "$WORK/out/h/appcast/.release-notes.fragment" ]] \
  || fail "the notes fragment was left in the publishable output directory"

echo "[test] sparkle publish ordering + verification guards OK"
