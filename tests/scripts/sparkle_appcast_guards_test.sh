#!/usr/bin/env bash
# A2.1-2026-07-24: guards for the Sparkle update-honesty contract.
#
# Two things must stay true forever:
#   1. The app never claims automatic updates work unless a signed appcast was
#      actually published for that build.
#   2. The appcast generator refuses to emit an unsigned / placeholder-signed /
#      misaddressed feed — a malformed feed is worse than no feed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE="$ROOT/script/release.sh"
GENERATE="$ROOT/script/generate_appcast.sh"
UPDATER="$ROOT/Sources/NativeAgentApp/UpdateController.swift"
APP_ENTRY="$ROOT/Sources/NativeAgentApp/NativeAgentApp.swift"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- syntax -----------------------------------------------------------------
for s in "$RELEASE" "$GENERATE" "$ROOT/script/sparkle_keygen.sh" "$ROOT/script/lib/sparkle_tools.sh"; do
  bash -n "$s" || fail "$s does not parse"
done
[[ -x "$GENERATE" ]] || fail "script/generate_appcast.sh is not executable"

# --- the placeholder feed URL must never come back --------------------------
if grep -Fq 'example.com/nativeagent/appcast.xml' "$RELEASE"; then
  fail "release.sh stamps the example.com placeholder appcast URL again"
fi

# --- release.sh: publishing is opt-in, and the claim follows the mode --------
grep -Fq -- '--publish-appcast' "$RELEASE" \
  || fail "release.sh no longer supports --publish-appcast"
grep -Fq 'NativeAgentUpdateFeedPublished' "$RELEASE" \
  || fail "release.sh no longer stamps the NativeAgentUpdateFeedPublished honesty flag"
grep -Fq 'SUFeedURL was stamped without --publish-appcast' "$RELEASE" \
  || fail "release.sh no longer fails when a feed URL is stamped with no feed"

# --- UpdateController: the gate reads the published flag, not just the URL ---
grep -Fq 'NativeAgentUpdateFeedPublished' "$UPDATER" \
  || fail "UpdateController no longer gates on the published-feed flag"
grep -Fq 'placeholderHosts' "$UPDATER" \
  || fail "UpdateController no longer rejects placeholder feed hosts"
grep -Fq 'About Software Updates' "$UPDATER" \
  || fail "UpdateController no longer relabels the menu item when updates are unavailable"
grep -Fq 'updateController.menuTitle' "$APP_ENTRY" \
  || fail "the app menu no longer uses the honest, state-derived update title"
if grep -Fq '.disabled(!updateController.canCheckForUpdates)' "$APP_ENTRY"; then
  fail "the update menu item is a dead disabled affordance again"
fi

# --- generator: fail-loud paths (these run without Sparkle's tools) ---------
# Every NATIVE_AGENT_*/NATIVEAGENT_* release variable is cleared first so a
# developer's exported release credentials cannot green these guards.
run_generate() { # env assignments as args; echoes combined output, never aborts
  set +e
  ( cd "$ROOT" && env \
      -u NATIVE_AGENT_SPARKLE_ED_PRIV_KEY -u NATIVEAGENT_SPARKLE_ED_PRIV_KEY \
      -u NATIVE_AGENT_APPCAST_URL -u NATIVEAGENT_APPCAST_URL \
      -u NATIVE_AGENT_DMG_DOWNLOAD_URL -u NATIVEAGENT_DMG_DOWNLOAD_URL \
      -u NATIVE_AGENT_RELEASE_PAGE_URL -u NATIVEAGENT_RELEASE_PAGE_URL \
      "$@" bash "$GENERATE" --dmg "$ROOT/VERSION" --version 0.0.0 2>&1 )
  set -e
}

out="$(run_generate NATIVEAGENT_UNUSED=1)"
grep -q 'refusing to emit an' <<<"$out" \
  || fail "missing signing key does not fail loudly: $out"
grep -q 'sparkle_keygen.sh' <<<"$out" \
  || fail "missing-key failure does not name the remediation: $out"

out="$(run_generate NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$ROOT/VERSION")"
grep -q 'NATIVEAGENT_APPCAST_URL is not set' <<<"$out" \
  || fail "missing appcast URL is not rejected: $out"

out="$(run_generate NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$ROOT/VERSION" \
  NATIVEAGENT_APPCAST_URL=https://example.com/appcast.xml \
  NATIVEAGENT_DMG_DOWNLOAD_URL=https://example.com/NativeAgent.dmg)"
grep -q 'placeholder URL refused' <<<"$out" \
  || fail "placeholder hosting URLs are not rejected: $out"

out="$(run_generate NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$ROOT/VERSION" \
  NATIVEAGENT_APPCAST_URL=https://updates.nativeagent.test/appcast.xml \
  NATIVEAGENT_DMG_DOWNLOAD_URL=https://dl.nativeagent.test/WrongName.dmg)"
grep -q 'must end in the DMG filename' <<<"$out" \
  || fail "enclosure URL / DMG filename mismatch is not rejected: $out"

# --- generator: the anti-unsigned-feed guards must remain in the source -----
grep -Fq 'does not match key' "$GENERATE" \
  || fail "generate_appcast.sh no longer treats Sparkle's key-mismatch WARNING as fatal"
grep -Fq 'NO sparkle:edSignature' "$GENERATE" \
  || fail "generate_appcast.sh no longer refuses an unsigned enclosure"
grep -Fq -- '--verify' "$GENERATE" \
  || fail "generate_appcast.sh no longer re-verifies the signature it emitted"
grep -Fq -- '--rehearsal and --publish are mutually exclusive' "$GENERATE" \
  || fail "generate_appcast.sh lets a rehearsal feed be published"

# --- round 2: the publish claim must be verified, never inferred -------------
# Behavioural coverage for these lives in sparkle_publish_ordering_test.sh; these
# assert the guards were not simply deleted.
grep -Fq 'SIGNING KEY MISMATCH' "$GENERATE" \
  || fail "generate_appcast.sh no longer proves the signing key matches the bundle's SUPublicEDKey"
grep -Fq 'sparkle_ed_public_key_from_file' "$GENERATE" \
  || fail "generate_appcast.sh no longer derives the public half of the signing key"
grep -Fq 'PUBLISH NOT VERIFIED' "$GENERATE" \
  || fail "generate_appcast.sh treats the publish command's exit code as proof again"
grep -Fq 'Published and VERIFIED live' "$GENERATE" \
  || fail "generate_appcast.sh prints a success line for unverified publish state"
if grep -Fq 'echo "==> Published: ' "$GENERATE"; then
  fail "generate_appcast.sh claims 'Published' without fetching the feed"
fi
grep -Fq 'refusing to claim a feed is live on the strength of an exit code' "$GENERATE" \
  || grep -Fiq 'cannot be VERIFIED' "$GENERATE" \
  || fail "generate_appcast.sh no longer fails when publication cannot be verified at all"

echo "[test] sparkle appcast + update-honesty guards OK"
