#!/usr/bin/env bash
# RELEASE-2026-05-06: canonical production release script for NativeAgent
# Usage:
#   ./script/release.sh               — full notarized release
#   ./script/release.sh --dry-run     — sign only (ad-hoc fallback), skip notarization
#   ./script/release.sh --appcast          — also generate+sign the Sparkle appcast
#                                            locally (uploads nothing)
#   ./script/release.sh --publish-appcast  — generate+sign AND publish the feed;
#                                            only this mode lets the app claim that
#                                            automatic updates work (A2.1)
#   ./script/release.sh --notes FILE       — release notes for the Sparkle update
#                                            dialog AND the GitHub release body.
#                                            Defaults to docs/release-notes/<VERSION>.md
#                                            when that file exists; with neither,
#                                            the update dialog stays blank (C12).
#   ./script/release.sh --self-test-gates dist/NativeAgent.app
#                                          — run the A1.1 identity leak gate and the
#                                            A1.5 bundle assertion against an existing
#                                            .app and exit. Builds/signs nothing.
#
# PUBLIC LANE (A1.1-2026-08-02): any NATIVEAGENT_ICLOUD_BUILD other than
# personal|1 is a PUBLIC release, and a public release is ALWAYS built from the
# scrubbed export. Run it from the private tree as usual — this script produces
# the export itself (script/make_public_export.sh) and re-runs inside it with
# the private signing inputs, so scrubbed AND notarized is now one path instead
# of two mutually exclusive ones.
#   NATIVEAGENT_PUBLIC_EXPORT_DIR   — where to put the export (default: mktemp)
#   NATIVEAGENT_REUSE_PUBLIC_EXPORT — 1 reuses an existing export; --dry-run only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sparkle_tools.sh
source "$ROOT/script/lib/sparkle_tools.sh"
# shellcheck source=lib/release_quarantine.sh
source "$ROOT/script/lib/release_quarantine.sh"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/release_bundle_gates.sh
source "$ROOT/script/lib/release_bundle_gates.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
DRY_RUN=false
# A2.1-2026-07-24: appcast generation/publishing is opt-in. A normal release must
# never try to upload anywhere, and — critically — must never stamp an app that
# CLAIMS a working update feed when none was published. See UpdateController.swift.
GENERATE_APPCAST=false
PUBLISH_APPCAST=false
# Sweep R4 C12: release notes for the Sparkle update dialog. Explicit --notes
# FILE wins; otherwise docs/release-notes/<VERSION>.md is picked up if it
# exists. No file, no notes — the dialog stays blank, honestly, rather than
# inventing a changelog.
RELEASE_NOTES_FILE=""

# RELEASE-2026-05-06: parse flags
SELF_TEST_GATES_TARGET=""
_expect_self_test_target=false
_expect_notes_file=false
for arg in "$@"; do
  if [[ "$_expect_self_test_target" == "true" ]]; then
    SELF_TEST_GATES_TARGET="$arg"
    _expect_self_test_target=false
    continue
  fi
  if [[ "$_expect_notes_file" == "true" ]]; then
    RELEASE_NOTES_FILE="$arg"
    _expect_notes_file=false
    continue
  fi
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --appcast) GENERATE_APPCAST=true ;;
    --publish-appcast) GENERATE_APPCAST=true; PUBLISH_APPCAST=true ;;
    --notes) _expect_notes_file=true ;;
    --notes=*) RELEASE_NOTES_FILE="${arg#--notes=}" ;;
    --self-test-gates) _expect_self_test_target=true ;;
    --self-test-gates=*) SELF_TEST_GATES_TARGET="${arg#--self-test-gates=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
if [[ "$_expect_notes_file" == "true" ]]; then
  echo "ERROR: --notes requires a path to a release-notes file." >&2
  exit 1
fi
if [[ -n "$RELEASE_NOTES_FILE" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "ERROR: --notes file not found: $RELEASE_NOTES_FILE" >&2
  exit 1
fi
if [[ "$_expect_self_test_target" == "true" ]]; then
  echo "ERROR: --self-test-gates requires a path to a .app bundle." >&2
  exit 1
fi

# A1.1/A1.5: run the shipped bundle gates against an EXISTING .app and exit.
# Builds nothing, signs nothing, notarizes nothing — this exists so the gates
# can be proven to fire (and to keep firing) without a 20-minute release.
if [[ -n "$SELF_TEST_GATES_TARGET" ]]; then
  if [[ ! -d "$SELF_TEST_GATES_TARGET" ]]; then
    echo "ERROR: --self-test-gates target is not a directory: $SELF_TEST_GATES_TARGET" >&2
    exit 1
  fi
  echo "==> Self-testing release gates against $SELF_TEST_GATES_TARGET"
  _self_test_rc=0
  release_assert_no_identity_strings "$SELF_TEST_GATES_TARGET" || _self_test_rc=1
  release_assert_no_user_state_in_bundle "$SELF_TEST_GATES_TARGET" || _self_test_rc=1
  if [[ "$_self_test_rc" -eq 0 ]]; then
    echo "==> Gate self-test: BOTH GATES PASS for this bundle."
  else
    echo "==> Gate self-test: at least one gate FAILED (a real release would abort here)." >&2
  fi
  exit "$_self_test_rc"
fi

# --dry-run exits before the DMG exists, so an appcast flag there would be
# silently ignored — the exact "looks like it worked" shape this wave removes.
if [[ "$DRY_RUN" == "true" && "$GENERATE_APPCAST" == "true" ]]; then
  echo "ERROR: --dry-run stops before the DMG is built, so --appcast/--publish-appcast" >&2
  echo "       cannot run and would be silently ignored." >&2
  echo "       To exercise the feed pipeline against an existing DMG:" >&2
  echo "         ./script/generate_appcast.sh --dmg dist/NativeAgent-<version>.dmg --rehearsal" >&2
  exit 1
fi

# RELEASE-2026-05-06: version from single source of truth
VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found. Create it with a semver string (e.g. 0.2.0)." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
NATIVEAGENT_SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
NATIVEAGENT_SOURCE_REVISION="${NATIVEAGENT_SOURCE_REVISION:-unknown}"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)" ]]; then
  NATIVEAGENT_SOURCE_DIRTY=true
else
  NATIVEAGENT_SOURCE_DIRTY=false
fi

assert_full_release_source_unchanged() {
  [[ "$DRY_RUN" == "false" ]] || return 0
  local current_revision current_dirty
  current_revision="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  current_dirty="$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null || true)"
  [[ "$NATIVEAGENT_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$NATIVEAGENT_SOURCE_REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || { echo "ERROR: full release requires one exact Git source object ID." >&2; exit 1; }
  [[ "$current_revision" == "$NATIVEAGENT_SOURCE_REVISION" ]] \
    || { echo "ERROR: source HEAD changed during the release build; restart from a stable commit." >&2; exit 1; }
  [[ -z "$current_dirty" ]] \
    || { echo "ERROR: full release requires a clean source tree and it changed during the build." >&2; exit 1; }
}

assert_full_release_source_unchanged
echo "==> NativeAgent release v$VERSION (dry-run=$DRY_RUN)"

# Release-tooling credentials below kept as NATIVEAGENT_* for backward compat
# (Apple signing creds are user-set; renaming them here would break CI pipelines).
# Also accept NATIVE_AGENT_ aliases for the signing creds as a forward-compat bridge.
NATIVEAGENT_DEVELOPER_ID="${NATIVE_AGENT_DEVELOPER_ID:-${NATIVEAGENT_DEVELOPER_ID:-}}"
NATIVEAGENT_TEAM_ID="${NATIVE_AGENT_TEAM_ID:-${NATIVEAGENT_TEAM_ID:-}}"
NATIVEAGENT_APPLE_ID="${NATIVE_AGENT_APPLE_ID:-${NATIVEAGENT_APPLE_ID:-}}"
NATIVEAGENT_NOTARIZATION_PASSWORD="${NATIVE_AGENT_NOTARIZATION_PASSWORD:-${NATIVEAGENT_NOTARIZATION_PASSWORD:-}}"
NATIVEAGENT_SPARKLE_ED_PRIV_KEY="${NATIVE_AGENT_SPARKLE_ED_PRIV_KEY:-${NATIVEAGENT_SPARKLE_ED_PRIV_KEY:-}}"
NATIVEAGENT_SPARKLE_PUBLIC_KEY="${NATIVE_AGENT_SPARKLE_PUBLIC_KEY:-${NATIVEAGENT_SPARKLE_PUBLIC_KEY:-}}"
NATIVEAGENT_PROVISIONING_PROFILE="${NATIVE_AGENT_PROVISIONING_PROFILE:-${NATIVEAGENT_PROVISIONING_PROFILE:-}}"
NATIVEAGENT_APPCAST_URL="${NATIVE_AGENT_APPCAST_URL:-${NATIVEAGENT_APPCAST_URL:-}}"
NATIVEAGENT_MAC_BUNDLE_ID="${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}"
NATIVEAGENT_ICLOUD_CONTAINER_ID="${NATIVEAGENT_ICLOUD_CONTAINER_ID:-iCloud.io.github.embwl0x.nativeagent}"
NATIVEAGENT_MOBILE_SOURCE_KEY="${NATIVEAGENT_MOBILE_SOURCE_KEY:-mobile_app}"
NATIVEAGENT_BACKGROUND_TASK_PREFIX="${NATIVEAGENT_BACKGROUND_TASK_PREFIX:-io.github.embwl0x.nativeagent}"
NATIVEAGENT_DMG_DOWNLOAD_URL="${NATIVE_AGENT_DMG_DOWNLOAD_URL:-${NATIVEAGENT_DMG_DOWNLOAD_URL:-}}"
NATIVEAGENT_RELEASE_PAGE_URL="${NATIVE_AGENT_RELEASE_PAGE_URL:-${NATIVEAGENT_RELEASE_PAGE_URL:-}}"

# A2.1-2026-07-24: the old dry-run fallback stamped
# an example.com placeholder appcast URL into SUFeedURL. That placeholder
# shipped in dist/NativeAgent-0.2.0.dmg (confirmed by mounting it), i.e. a real
# distributed artifact carried a fake update feed. Never synthesize a feed URL.
#
# The one place the app's "updates work" claim is decided, and the ONLY place
# SUFeedURL is stamped: a release that publishes a signed appcast in this same
# run. --appcast alone is a rehearsal of the signing pipeline (it proves the key
# and the tooling work) and deliberately produces an app identical to a plain
# release — no feed URL, updater honestly off. The publish step below is fatal,
# so a build that asserts the claim either publishes or never ships.
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  NATIVEAGENT_UPDATE_FEED_PUBLISHED=true
  SPARKLE_FEED_URL_STAMP="$NATIVEAGENT_APPCAST_URL"
else
  NATIVEAGENT_UPDATE_FEED_PUBLISHED=false
  SPARKLE_FEED_URL_STAMP=""
fi
export NATIVEAGENT_DEVELOPER_ID
export NATIVEAGENT_TEAM_ID
export NATIVEAGENT_APPLE_ID
export NATIVEAGENT_NOTARIZATION_PASSWORD
export NATIVEAGENT_SPARKLE_ED_PRIV_KEY
export NATIVEAGENT_SPARKLE_PUBLIC_KEY
export NATIVEAGENT_PROVISIONING_PROFILE
export NATIVEAGENT_APPCAST_URL
export NATIVEAGENT_DMG_DOWNLOAD_URL
export NATIVEAGENT_RELEASE_PAGE_URL
export NATIVEAGENT_MAC_BUNDLE_ID
export NATIVEAGENT_ICLOUD_CONTAINER_ID
export NATIVEAGENT_MOBILE_SOURCE_KEY
export NATIVEAGENT_BACKGROUND_TASK_PREFIX

# Distribution transport modes. The legacy 1/0 values remain accepted:
#   personal | 1  — development/personal KVS + Drive + CloudKit profile
#   cloudkit      — public Developer ID build with production CloudKit only
#   none     | 0  — public standalone build with no Apple device transport
#
# The official Mac+iPhone release uses `cloudkit`; KVS/CloudDocuments are not
# part of the public Developer ID contract. Every public mode starts from the
# scrubbed, marker-bearing export.
NATIVEAGENT_ICLOUD_BUILD="${NATIVEAGENT_ICLOUD_BUILD:-1}"
case "$NATIVEAGENT_ICLOUD_BUILD" in
  1|personal) NATIVEAGENT_RELEASE_SYNC_MODE="personal" ;;
  cloudkit) NATIVEAGENT_RELEASE_SYNC_MODE="cloudkit" ;;
  0|none) NATIVEAGENT_RELEASE_SYNC_MODE="none" ;;
  *)
    echo "ERROR: NATIVEAGENT_ICLOUD_BUILD must be personal|1, cloudkit, or none|0." >&2
    exit 1
    ;;
esac
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "none" ]]; then
  # Keep the explicit standalone lane honest: no signed iCloud entitlement and
  # no bundle metadata that makes Doctor or the runtime expect one.
  NATIVEAGENT_ICLOUD_CONTAINER_ID="iCloud.com.example.nativeagent"
fi
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
  NATIVEAGENT_DEVICE_SYNC="cloudkit"
else
  # Preserve the established KVS/Drive transport for personal builds. The
  # standalone lane also stamps the inert legacy default, but carries no Apple
  # sync entitlements so no device bridge can start.
  NATIVEAGENT_DEVICE_SYNC="kvs"
fi
if [[ "$DRY_RUN" == "false" ]]; then
  if [[ "$NATIVEAGENT_MAC_BUNDLE_ID" == com.example.* \
     || "$NATIVEAGENT_BACKGROUND_TASK_PREFIX" == com.example.* ]]; then
    echo "ERROR: production release identity still uses the com.example placeholder." >&2
    echo "       Set the stable Mac bundle and background-task identifiers explicitly." >&2
    exit 1
  fi
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "none" \
     && "$NATIVEAGENT_ICLOUD_CONTAINER_ID" == iCloud.com.example.* ]]; then
    echo "ERROR: production device-sync release still uses the example iCloud container." >&2
    exit 1
  fi
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" \
     && "$NATIVEAGENT_MOBILE_SOURCE_KEY" != "mobile_app" ]]; then
    echo "ERROR: public CloudKit release requires the neutral mobile source key 'mobile_app'." >&2
    exit 1
  fi
fi
# A1.1-2026-08-02: the scrub is the ONLY path to a public DMG.
#
# Before: this line hard-FAILED when a public build was started from the private
# working tree, and the scrubbed export (which has the marker) has no local/
# directory — local/ is gitignored, so the maintainer entitlements and the
# provisioning profile never leave the private repo. The notarizable path and
# the scrubbed path were therefore mutually exclusive in practice, and the way
# anyone actually got a DMG out was to run this script unscrubbed. 44 Claude
# refs compiled straight into the public binary.
#
# After: a public build started from the private tree is no longer a refusal,
# it is a two-stage release. This process produces the scrubbed export, then
# re-runs THIS script inside it with the private signing inputs handed over as
# absolute paths. The child sees the marker, passes the check below, and does
# the ordinary sign/notarize/staple/DMG flow on scrubbed source.
#
# Private/dev lane (NATIVEAGENT_ICLOUD_BUILD=1|personal, and script/build_and_run.sh)
# is untouched: it never enters this branch.
NATIVEAGENT_NEEDS_PUBLIC_SCRUB=false
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "personal" ]]; then
  if [[ -f "$ROOT/.nativeagent-public-source" ]]; then
    "$ROOT/script/check_public_release_source.sh" "$ROOT"
  elif [[ "${NATIVEAGENT_PUBLIC_SCRUB_CHILD:-0}" == "1" ]]; then
    # Recursion guard: a child must never re-enter the orchestrator. If it got
    # here the export it was pointed at is not a valid scrubbed tree.
    echo "ERROR: scrubbed-export child started in a tree with no public-source marker." >&2
    echo "       Refusing to recurse; inspect the export at $ROOT." >&2
    exit 1
  else
    NATIVEAGENT_NEEDS_PUBLIC_SCRUB=true
  fi
fi
# Notarize via a stored keychain profile (xcrun notarytool store-credentials)
# instead of an app-specific password in the environment — keeps the secret out
# of env/logs. When set, APPLE_ID/NOTARIZATION_PASSWORD are not required.
NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE="${NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE:-}"
# Signing entitlements: explicit override wins; else picked by ICLOUD_BUILD.
NATIVEAGENT_RELEASE_ENTITLEMENTS="${NATIVEAGENT_RELEASE_ENTITLEMENTS:-}"
GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS=""
cleanup_generated_release_entitlements() {
  if [[ -n "${GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS:-}" ]]; then
    rm -f "$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"
  fi
}
trap cleanup_generated_release_entitlements EXIT
if [[ -z "$NATIVEAGENT_RELEASE_ENTITLEMENTS" ]]; then
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "personal" ]]; then
    # Full build: prefer the real local entitlements (real container/team IDs)
    # over the checked-in template, which carries only EXAMPLE iCloud values
    # that would mismatch a real profile and get the app killed (gpt-5.5 MED).
    if [[ -f "$ROOT/local/NativeAgent.entitlements" ]]; then
      NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/local/NativeAgent.entitlements"
    else
      NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/NativeAgent.entitlements"
    fi
  elif [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    if [[ -f "$ROOT/local/NativeAgent.cloudkit.public.entitlements" ]]; then
      NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/local/NativeAgent.cloudkit.public.entitlements"
    else
      echo "ERROR: CloudKit public release requires a maintainer-specific entitlement file." >&2
      echo "       Copy NativeAgent.cloudkit-public.entitlements to" >&2
      echo "       local/NativeAgent.cloudkit.public.entitlements and replace the example container." >&2
      exit 1
    fi
  else
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$ROOT/NativeAgent.public.entitlements"
  fi
fi

# A1.1-2026-08-02: stage 1 of the two-stage public release — produce the
# scrubbed export and re-run this script inside it.
#
# Placed AFTER entitlements selection (so the child inherits the resolved,
# private-tree file) and BEFORE entitlements validation / the Sparkle preflight
# / the build (so nothing expensive or temp-file-generating has happened yet;
# the child performs all of it exactly once, on scrubbed source).
if [[ "$NATIVEAGENT_NEEDS_PUBLIC_SCRUB" == "true" ]]; then
  _abs_release_path() {
    # Absolutize a path from the private tree so it still resolves after the
    # child chdir's into the export. Empty stays empty.
    local p="$1"
    [[ -n "$p" ]] || { printf '%s' ""; return 0; }
    case "$p" in
      /*) printf '%s' "$p" ;;
      *) printf '%s' "$ROOT/$p" ;;
    esac
  }

  [[ -x "$ROOT/script/make_public_export.sh" ]] \
    || { echo "ERROR: script/make_public_export.sh missing or not executable; cannot cut a public release." >&2; exit 1; }

  PUBLIC_EXPORT_DIR="${NATIVEAGENT_PUBLIC_EXPORT_DIR:-}"
  if [[ -z "$PUBLIC_EXPORT_DIR" ]]; then
    PUBLIC_EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-public-release.XXXXXX")/export"
  fi

  # Re-using an existing export skips the scrub, so it is allowed ONLY for
  # --dry-run iteration. A notarized artifact always gets a fresh scrub.
  _reuse_export=false
  if [[ "${NATIVEAGENT_REUSE_PUBLIC_EXPORT:-0}" == "1" ]]; then
    if [[ "$DRY_RUN" != "true" ]]; then
      echo "ERROR: NATIVEAGENT_REUSE_PUBLIC_EXPORT=1 is only permitted with --dry-run." >&2
      echo "       A notarized public DMG must be cut from a freshly scrubbed export." >&2
      exit 1
    fi
    if [[ -f "$PUBLIC_EXPORT_DIR/.nativeagent-public-source" ]]; then
      _reuse_export=true
    fi
  fi

  echo "==> A1.1: public release requested (sync mode: $NATIVEAGENT_RELEASE_SYNC_MODE) from the private tree."
  if [[ "$_reuse_export" == "true" ]]; then
    echo "==> Re-using existing scrubbed export (dry-run only): $PUBLIC_EXPORT_DIR"
  else
    echo "==> Producing the scrubbed public export at: $PUBLIC_EXPORT_DIR"
    echo "    (identity scrub + gitleaks + identity guard + build verification;"
    echo "     this is the only source a public DMG is ever built from)"
    "$ROOT/script/make_public_export.sh" "$PUBLIC_EXPORT_DIR"
  fi
  "$ROOT/script/check_public_release_source.sh" "$PUBLIC_EXPORT_DIR"

  # The signing inputs live in the private tree (local/ is gitignored and is
  # deliberately never exported). Handing them over as absolute paths is what
  # makes the scrubbed source notarizable — the exact coupling whose absence
  # made the two paths mutually exclusive.
  CHILD_ENTITLEMENTS="$(_abs_release_path "$NATIVEAGENT_RELEASE_ENTITLEMENTS")"
  CHILD_PROFILE="$(_abs_release_path "$NATIVEAGENT_PROVISIONING_PROFILE")"
  CHILD_SPARKLE_KEY="$(_abs_release_path "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY")"
  # The denylist lives under the private local/ dir, which the export does not
  # carry; point the child back at the private copy so its personal-data leak
  # guard keeps the same rules instead of silently degrading to no rules.
  CHILD_PRIVACY_DENYLIST="$(_abs_release_path "${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-local/privacy_denylist.regex}")"
  if [[ -n "$CHILD_ENTITLEMENTS" && ! -r "$CHILD_ENTITLEMENTS" ]]; then
    echo "ERROR: release entitlements not readable from the private tree: $CHILD_ENTITLEMENTS" >&2
    exit 1
  fi

  echo "==> A1.1: re-running release.sh inside the scrubbed export"
  set +e
  (
    cd "$PUBLIC_EXPORT_DIR" || exit 1
    NATIVEAGENT_PUBLIC_SCRUB_CHILD=1 \
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$CHILD_ENTITLEMENTS" \
    NATIVEAGENT_PROVISIONING_PROFILE="$CHILD_PROFILE" \
    NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$CHILD_SPARKLE_KEY" \
    NATIVEAGENT_PRIVACY_DENYLIST_FILE="$CHILD_PRIVACY_DENYLIST" \
      "$PUBLIC_EXPORT_DIR/script/release.sh" "$@"
  )
  CHILD_RC=$?
  set -e
  if [[ "$CHILD_RC" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: the scrubbed public release failed (exit $CHILD_RC)." >&2
    echo "       Export preserved for inspection: $PUBLIC_EXPORT_DIR" >&2
    exit "$CHILD_RC"
  fi

  # Copy the finished public artifacts back into the private tree's dist/ so the
  # maintainer picks them up where every other release lands. The export is left
  # in place as the provenance record for the artifacts.
  mkdir -p "$ROOT/dist"
  _copied=()
  for _artifact in "$APP_NAME.app" "$APP_NAME.app.zip" "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION.dmg.zip"; do
    if [[ -e "$PUBLIC_EXPORT_DIR/dist/$_artifact" ]]; then
      rm -rf "${ROOT:?}/dist/$_artifact"
      cp -R "$PUBLIC_EXPORT_DIR/dist/$_artifact" "$ROOT/dist/$_artifact"
      _copied+=("dist/$_artifact")
    fi
  done
  if [[ -d "$PUBLIC_EXPORT_DIR/dist/appcast" ]]; then
    rm -rf "$ROOT/dist/appcast"
    cp -R "$PUBLIC_EXPORT_DIR/dist/appcast" "$ROOT/dist/appcast"
    _copied+=("dist/appcast")
  fi
  echo ""
  echo "==> Public release v$VERSION built from SCRUBBED source."
  echo "    scrubbed export : $PUBLIC_EXPORT_DIR"
  if [[ ${#_copied[@]} -gt 0 ]]; then
    echo "    copied back     : ${_copied[*]}"
  else
    echo "    WARNING: no artifacts found under $PUBLIC_EXPORT_DIR/dist to copy back." >&2
  fi
  exit 0
fi

# Validate the chosen entitlements up front so a bad file fails BEFORE the slow
# build+notarize, and enforce the public-build invariant on the ACTUAL file
# contents, not the mode label (gpt-5.5 HIGH: an override could otherwise sign
# iCloud entitlements into a profile-less public build → launch-killed app).
if [[ "$DRY_RUN" == "false" ]]; then
  [[ -r "$NATIVEAGENT_RELEASE_ENTITLEMENTS" ]] || { echo "ERROR: entitlements not readable: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2; exit 1; }
  plutil -lint "$NATIVEAGENT_RELEASE_ENTITLEMENTS" >/dev/null || { echo "ERROR: entitlements plist invalid: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2; exit 1; }
  calendar_access="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.personal-information.calendars' \
      "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
  )"
  [[ "$calendar_access" == "true" ]] \
    || { echo "ERROR: production entitlements must retain Calendar TCC authority." >&2; exit 1; }

  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "none" ]]; then
    if grep -qE "com\.apple\.developer\.(icloud|ubiquity|background-tasks)" "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: standalone public build but the signed entitlements declare" >&2
      echo "       iCloud/ubiquity/background-tasks: $NATIVEAGENT_RELEASE_ENTITLEMENTS" >&2
      echo "       A Developer-ID app with these + no provisioning profile is KILLED at launch." >&2
      echo "       Use NativeAgent.public.entitlements (or unset NATIVEAGENT_RELEASE_ENTITLEMENTS)." >&2
      exit 1
    fi
    if [[ -n "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
      echo "[release] public build: ignoring NATIVEAGENT_PROVISIONING_PROFILE — a no-iCloud public" >&2
      echo "[release] artifact embeds no provisioning profile (gpt-5.5 MED)." >&2
      NATIVEAGENT_PROVISIONING_PROFILE=""
    fi
  elif [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    services="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.icloud-services' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    printf '%s' "$services" | grep -Fq CloudKit \
      || { echo "ERROR: CloudKit public entitlements do not grant CloudKit." >&2; exit 1; }
    if printf '%s' "$services" | grep -Fq CloudDocuments \
      || grep -qE "com\.apple\.developer\.(ubiquity|background-tasks)" "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: public CloudKit mode must not declare CloudDocuments, KVS/ubiquity, or background-task entitlements." >&2
      exit 1
    fi
    aps_environment="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.aps-environment' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    container_environment="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.icloud-container-environment' \
        "$NATIVEAGENT_RELEASE_ENTITLEMENTS" 2>/dev/null || true
    )"
    [[ "$aps_environment" == "production" && "$container_environment" == "Production" ]] \
      || { echo "ERROR: public CloudKit release requires production APS and CloudKit environments." >&2; exit 1; }
    if grep -Fqi 'example.nativeagent' "$NATIVEAGENT_RELEASE_ENTITLEMENTS"; then
      echo "ERROR: public CloudKit release entitlements still contain the example container." >&2
      exit 1
    fi
  fi
fi

# RELEASE-2026-05-06: require env vars; list all missing ones before aborting
if [[ "$DRY_RUN" == "false" ]]; then
  REQUIRED_VARS=(
    NATIVEAGENT_DEVELOPER_ID
    NATIVEAGENT_TEAM_ID
    NATIVEAGENT_SPARKLE_ED_PRIV_KEY
    NATIVEAGENT_SPARKLE_PUBLIC_KEY
  )
  # A2.1: feed URLs are required only when a feed is actually being produced.
  # A release that publishes nothing must not be forced to name a URL it will
  # then bake into the app as a promise it cannot keep.
  if [[ "$GENERATE_APPCAST" == "true" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_APPCAST_URL NATIVEAGENT_DMG_DOWNLOAD_URL )
  fi
  # Provisioning profile only needed for the iCloud build (it authorizes the
  # container); the no-iCloud public build ships without one.
  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "none" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_PROVISIONING_PROFILE )
  fi
  # Notary creds: a stored keychain profile replaces the apple-id/password pair.
  if [[ -z "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" ]]; then
    REQUIRED_VARS+=( NATIVEAGENT_APPLE_ID NATIVEAGENT_NOTARIZATION_PASSWORD )
  fi
  missing=()
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: The following required environment variables are not set:" >&2
    for v in "${missing[@]}"; do
      echo "  $v" >&2
    done
    echo "" >&2
    echo "Set them and re-run. See docs/release_setup.md for details." >&2
    echo "" >&2
    echo "  NATIVEAGENT_DEVELOPER_ID      — Developer ID Application: Developer Name (XXXXXXXXXX)" >&2
    echo "  NATIVEAGENT_TEAM_ID           — 10-char Apple Team ID" >&2
    echo "  NATIVEAGENT_APPLE_ID          — Apple ID email for notarization" >&2
    echo "  NATIVEAGENT_NOTARIZATION_PASSWORD — app-specific password from appleid.apple.com" >&2
    echo "  NATIVEAGENT_SPARKLE_ED_PRIV_KEY   — path to Sparkle EdDSA private key file" >&2
    echo "  NATIVEAGENT_SPARKLE_PUBLIC_KEY    — Sparkle EdDSA public key string for SUPublicEDKey" >&2
    echo "  NATIVEAGENT_PROVISIONING_PROFILE  — Developer ID provisioning profile matching NativeAgent.entitlements" >&2
    echo "  NATIVEAGENT_APPCAST_URL           — public Sparkle appcast URL (--appcast only)" >&2
    echo "  NATIVEAGENT_DMG_DOWNLOAD_URL      — public URL the DMG is served from (--appcast only)" >&2
    exit 1
  fi
  if [[ ! -r "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY" ]]; then
    echo "ERROR: NATIVEAGENT_SPARKLE_ED_PRIV_KEY is not readable: $NATIVEAGENT_SPARKLE_ED_PRIV_KEY" >&2
    exit 1
  fi
  if grep -q "BEGIN .*PRIVATE KEY" "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY"; then
    echo "ERROR: NATIVEAGENT_SPARKLE_ED_PRIV_KEY is a PEM key, not a Sparkle EdDSA key file." >&2
    echo "Generate it with Sparkle's generate_keys tool." >&2
    exit 1
  fi
  if ! printf '%s' "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" | base64 -D >/dev/null 2>&1; then
    echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY is not valid base64." >&2
    exit 1
  fi
  SPARKLE_PUBLIC_KEY_BYTES="$(printf '%s' "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" | base64 -D | wc -c | tr -d '[:space:]')"
  if [[ "$SPARKLE_PUBLIC_KEY_BYTES" != "32" ]]; then
    echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY must decode to 32 bytes; got $SPARKLE_PUBLIC_KEY_BYTES." >&2
    exit 1
  fi
  # A2.1 round 2: the public key stamped into the app and the private key the
  # appcast is signed with are two separate env vars — nothing used to check they
  # are two halves of ONE key. generate_appcast.sh now proves it, but only after a
  # 20-minute build+notarize. Prove it here, in a second, before any of that.
  if RELEASE_DERIVED_PUB="$(sparkle_ed_public_key_from_file "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY" "$ROOT")"; then
    if [[ "$RELEASE_DERIVED_PUB" != "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" ]]; then
      echo "ERROR: NATIVEAGENT_SPARKLE_PUBLIC_KEY is NOT the public half of" >&2
      echo "       NATIVEAGENT_SPARKLE_ED_PRIV_KEY. The app would trust a key the" >&2
      echo "       appcast is not signed with, so every update would be rejected." >&2
      echo "         stamped into the app: $NATIVEAGENT_SPARKLE_PUBLIC_KEY" >&2
      echo "         derived from the key: $RELEASE_DERIVED_PUB" >&2
      exit 1
    fi
    echo "==> Sparkle key pair verified (public half of the signing key matches the stamp)."
  else
    echo "ERROR: could not derive the public half of NATIVEAGENT_SPARKLE_ED_PRIV_KEY." >&2
    echo "       Refusing to build a release whose update key pair is unproven." >&2
    exit 1
  fi

  if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" == "cloudkit" ]]; then
    PROFILE_PREFLIGHT="$(mktemp "${TMPDIR:-/tmp}/nativeagent-release-profile.XXXXXX.plist")"
    if ! decode_provisioning_profile "$NATIVEAGENT_PROVISIONING_PROFILE" "$PROFILE_PREFLIGHT"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: public CloudKit provisioning profile could not be decoded." >&2
      exit 1
    fi
    if ! verify_public_cloudkit_profile_contract \
      "$PROFILE_PREFLIGHT" \
      "$NATIVEAGENT_TEAM_ID" \
      "$NATIVEAGENT_MAC_BUNDLE_ID" \
      "$NATIVEAGENT_ICLOUD_CONTAINER_ID"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: public CloudKit provisioning profile does not match the release identity." >&2
      exit 1
    fi
    GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS="$(
      mktemp "${TMPDIR:-/tmp}/nativeagent-release-entitlements.XXXXXX.plist"
    )"
    if ! prepare_public_cloudkit_signing_entitlements \
      "$NATIVEAGENT_RELEASE_ENTITLEMENTS" \
      "$PROFILE_PREFLIGHT" \
      "$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"; then
      rm -f "$PROFILE_PREFLIGHT"
      echo "ERROR: could not derive the CloudKit signing identity from the validated profile." >&2
      exit 1
    fi
    NATIVEAGENT_RELEASE_ENTITLEMENTS="$GENERATED_PUBLIC_CLOUDKIT_ENTITLEMENTS"
    rm -f "$PROFILE_PREFLIGHT"
    echo "==> Public CloudKit provisioning profile matches the exact team, app, container, and production environments."
    echo "==> CloudKit application/team identifiers derived into the temporary signing entitlements."
  fi
fi

# Fail before the release build if the ignored-on-disk CoreML payload is absent,
# truncated, or has drifted from the required resource manifest.
echo "==> Verifying required MiniLM source resources..."
"$ROOT/script/verify_release_artifact.sh" --verify-resource-source "$ROOT"

# RELEASE-2026-05-06: step 3 — swift build release
echo "==> Building (release configuration)..."
swift build -c release --package-path "$ROOT"

BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$PRODUCT"

# A2.1 round 2 (gpt-5.5 BLOCKING — ordering, second pass): a --publish-appcast
# build carries NativeAgentUpdateFeedPublished=true + SUFeedURL from the moment it
# is staged, and stays signed/notarized/stapled for many minutes before the feed
# can possibly be published (the enclosure signature has to cover the final
# notarized bytes). Quarantining at the END of that window was not enough: an
# abort during notarize/staple/verify left a signed, feed-claiming
# dist/NativeAgent.app (+ .app.zip, + DMG) under its ship-ready name.
#
# So the artifacts are BORN in dist/.pending-publish/ and the ship-ready names
# never exist until publication has been verified live. Quarantine is the resting
# state; promotion is the only exit. That is why a `set -e` abort, a SIGINT, and a
# SIGKILL/power loss mid-notarization all leave the same safe state with no
# cleanup code needing to run. See script/lib/release_quarantine.sh.
STAGE_DIR="$ROOT/dist"
QUARANTINE_DIR="$ROOT/dist/.pending-publish"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "==> --publish-appcast: building into $QUARANTINE_DIR until the feed is verified live"
  release_quarantine_init "$QUARANTINE_DIR" "release v$VERSION: appcast publish + live verification pending"
  STAGE_DIR="$QUARANTINE_DIR"
fi

# RELEASE-2026-05-06: step 4 — stage dist/NativeAgent.app
echo "==> Staging $APP_NAME.app..."
BUNDLE="$STAGE_DIR/$APP_NAME.app"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME.app" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME.app.zip" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.dmg" >/dev/null
  release_quarantine_register "$QUARANTINE_DIR" "$APP_NAME-$VERSION.dmg.zip" >/dev/null
  # A stale ship-ready copy from an earlier successful release must not be
  # mistaken for this build's output later on.
  rm -f "$ROOT/dist/$APP_NAME-$VERSION.dmg" "$ROOT/dist/$APP_NAME-$VERSION.dmg.zip"
  rm -rf "$ROOT/dist/$APP_NAME.app" "$ROOT/dist/$APP_NAME.app.zip"
fi
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

assert_no_python_artifacts() {
  local bundle="$1" hit
  hit="$(find "$bundle/Contents/Resources" \
    \( -type d \( -name python -o -name __pycache__ -o -name daemon \) \
       -o -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*python*' -o -name 'native_agentd.py' \) \
       -o -type l \( -name '*python*' -o -name 'native_agentd.py' \) \) \
    -print -quit 2>/dev/null || true)"
  if [[ -n "$hit" ]]; then
    echo "[release] ERROR: Python artifact staged in app bundle: $hit" >&2
    echo "[release] NativeAgent release artifacts must be Swift-native and zero-Python." >&2
    exit 1
  fi
}

cp "$BIN" "$BUNDLE/Contents/MacOS/$PRODUCT"

# 2026-06-07 task #88: stage SPM-generated resource bundles into the .app's
# Contents/Resources/. Mirrors the same fix in build_and_run.sh — without
# this, release builds would ship MiniLM as a phantom resource and Fast
# mode would silently no-op on every public install. The runtime
# fallback in CoreMLEmbeddingProvider.installedAppFallbackBundle() looks
# for staged bundles under Contents/Resources/ so this MUST match.
SPM_RELEASE_BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for spm_bundle in "$SPM_RELEASE_BIN_DIR"/*.bundle; do
  bundle_basename="$(basename "$spm_bundle")"
  rm -rf "$BUNDLE/Contents/Resources/$bundle_basename"
  cp -R "$spm_bundle" "$BUNDLE/Contents/Resources/$bundle_basename"
  echo "[release] staged $bundle_basename"
done
shopt -u nullglob

# Do not continue to signing when SwiftPM did not generate and stage the exact
# MemoryV2 resource bundle expected by Bundle.module and the installed fallback.
"$ROOT/script/verify_release_artifact.sh" \
  --verify-resource-bundle "$BUNDLE/Contents/Resources"

# A production artifact may never acquire an exact commit label and then keep
# building after the source changes underneath it. Dry-run remains available
# for dirty development verification; notarized output fails closed.
assert_full_release_source_unchanged

printf '%s\n' "$VERSION" > "$BUNDLE/Contents/Resources/VERSION"
echo "[release] runtime: Swift-native bundle; daemon tree, native_agentd.py, and Python runtime are excluded"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ROOT/docs/data-bounds.md" ]]; then
  mkdir -p "$BUNDLE/Contents/Resources/docs"
  cp "$ROOT/docs/data-bounds.md" "$BUNDLE/Contents/Resources/docs/data-bounds.md"
fi
# PUBLIC-RELEASE PRIVACY: the live persona/ dir is the developer's own
# instance state — local SOUL/VOICE/GROWTH, the developer's USER.md
# (location, handles), and ~80 USER.*.bak history snapshots. A public
# build must ship a GENERIC blank slate only.
#
# ONBOARDING-2026-05-26: do NOT ship a persona/ dir inside the bundle at
# Contents/Resources/persona. Earlier revisions shipped *.template.md files
# there as a placeholder, but the Swift onboarding templates are generated into
# writable user data, not read from bundle template files.
# Worse, the presence of Contents/Resources/persona/ caused
# `_resolve_persona_root()` step 3 (Path(__file__).resolve().parent.parent
# / "persona") to resolve INSIDE the read-only signed bundle on a public
# install (REPO_PATH stamp is intentionally absent — see the C7 note below).
# The background warmup then silently auto-scaffolded SOUL.md inside the
# bundle (personality_doc_contents create_missing=True), which:
#   1) flipped the onboarding gate to has_existing=True before the wizard
#      ever rendered, so first-run onboarding never played;
#   2) and if writes succeeded, broke codesign integrity.
# With nothing at Contents/Resources/persona/, the resolver falls through
# to step 4 (data_root/memory/), which is writable user data the
# preparePublicReleaseDataRootIfNeeded quarantine has already cleaned.
#
# Defensive cleanup: explicitly remove any persona/ directory that might
# exist under the staged bundle (e.g. left behind by a stale dist/ tree), and
# guarantees the bug can't sneak back via a stale incremental build.
rm -rf "$BUNDLE/Contents/Resources/persona"
echo "[release] persona: bundle Contents/Resources/persona pruned (Swift onboarding seeds user data; live persona/ excluded by construction)"

# Stamp the full source object identity. Exact runtime proof additionally
# requires the Info.plist dirty bit below to be false.
printf '%s\n' "$NATIVEAGENT_SOURCE_REVISION" > "$BUNDLE/Contents/Resources/VERSION_SHA"
# C7 fix: do NOT stamp REPO_PATH in a release build.
#
# release.sh runs on the developer's machine where $ROOT is the source repo
# (e.g. /Users/developer/Projects/NativeAgent). If we stamped that path, the
# distributed bundle would carry a path that doesn't exist on any other Mac and
# the Swift resolver would skip it. The public app should use the standard
# Application Support data root instead.
#
# For distribution: REPO_PATH is intentionally absent. The Swift resolver falls
# through its priority chain:
#   1. NATIVE_AGENT_DATA_ROOT env var  → honored if set
#   2. REPO_PATH stamp                  → absent here (intentional)
#   3. <repo_root>/data/ dev path       → won't match inside bundle
#   4. ~/Library/Application Support/NativeAgent/  ← public users land here
#
# ~/Library/Application Support/NativeAgent/ is the correct macOS-standard
# data directory for distributed apps.  install_app.sh (developer installs
# from source clone) still stamps REPO_PATH with the source repo path so the
# daily dev workflow continues to use files in the repo.

# Bundle Sparkle.framework in the standard framework location and add the app
# rpath before signing/notarization.
BIN_RELEASE="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$PRODUCT"
SPM_BIN_DIR_RELEASE="$(dirname "$BIN_RELEASE")"
if [[ -d "$SPM_BIN_DIR_RELEASE/Sparkle.framework" ]]; then
  mkdir -p "$BUNDLE/Contents/Frameworks"
  rm -rf "$BUNDLE/Contents/Frameworks/Sparkle.framework" "$BUNDLE/Contents/MacOS/Sparkle.framework"
  cp -R "$SPM_BIN_DIR_RELEASE/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null || true
  fi
fi

# A2.1-2026-07-24: build the Sparkle key block conditionally. SUFeedURL is emitted
# ONLY when this run generates a feed; otherwise the bundle carries no feed URL at
# all, which is what UpdateController reads to decide it must not pretend to check.
# SUEnableAutomaticChecks follows the same truth so no background poll can 404.
SPARKLE_PLIST_KEYS="  <key>SUPublicEDKey</key>
  <string>${NATIVEAGENT_SPARKLE_PUBLIC_KEY}</string>
  <key>NativeAgentUpdateFeedPublished</key>
  <${NATIVEAGENT_UPDATE_FEED_PUBLISHED}/>
  <key>SUEnableAutomaticChecks</key>
  <${NATIVEAGENT_UPDATE_FEED_PUBLISHED}/>"
if [[ -n "$SPARKLE_FEED_URL_STAMP" ]]; then
  SPARKLE_PLIST_KEYS="  <key>SUFeedURL</key>
  <string>${SPARKLE_FEED_URL_STAMP}</string>
$SPARKLE_PLIST_KEYS"
fi
if [[ -n "$NATIVEAGENT_RELEASE_PAGE_URL" ]]; then
  SPARKLE_PLIST_KEYS="$SPARKLE_PLIST_KEYS
  <key>NativeAgentReleasePageURL</key>
  <string>${NATIVEAGENT_RELEASE_PAGE_URL}</string>"
fi

# Generate Info.plist with version info and Sparkle feed URL
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT</string>
  <key>CFBundleIdentifier</key>
  <string>$NATIVEAGENT_MAC_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>NativeAgentMacBundleID</key>
  <string>$NATIVEAGENT_MAC_BUNDLE_ID</string>
  <key>NativeAgentICloudContainerID</key>
  <string>$NATIVEAGENT_ICLOUD_CONTAINER_ID</string>
  <key>NativeAgentMobileSourceKey</key>
  <string>$NATIVEAGENT_MOBILE_SOURCE_KEY</string>
  <key>NativeAgentBackgroundTaskIDPrefix</key>
  <string>$NATIVEAGENT_BACKGROUND_TASK_PREFIX</string>
  <key>NativeAgentDeviceSync</key>
  <string>$NATIVEAGENT_DEVICE_SYNC</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>NativeAgentSourceRevision</key>
  <string>$NATIVEAGENT_SOURCE_REVISION</string>
  <key>NativeAgentSourceDirty</key>
  <$NATIVEAGENT_SOURCE_DIRTY/>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>NativeAgent Chat Session</string>
      <key>UTTypeIdentifier</key>
      <string>com.nativeagent.chat-session</string>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <!-- Usage strings for TCC prompts -->
  <key>NSAppleEventsUsageDescription</key>
  <string>NativeAgent uses Apple Events to coordinate with system applications.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>NativeAgent uses calendar access for assistant briefings and user-approved watch jobs.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>NativeAgent uses full calendar access to read upcoming events for assistant briefings and user-approved watch jobs.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>NativeAgent uses write-only calendar access to create events only when the user enables Calendar write access.</string>
  <key>NSRemindersUsageDescription</key>
  <string>NativeAgent uses reminders access for assistant briefings and user-approved watch jobs.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>NativeAgent uses reminders access to read due reminders for assistant briefings and user-approved watch jobs.</string>
  <!-- Contacts access for assistant-requested people lookup. -->
  <key>NSContactsUsageDescription</key>
  <string>NativeAgent uses Contacts so the assistant can look up people you ask about and (with the Contacts write toggle on) create or update contacts on your behalf.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>NativeAgent uses your microphone for voice input.</string>
  <!-- PATCH-2026-05-06: multimodal-ui Sprint 3.1 — speech recognition usage string -->
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>NativeAgent uses speech recognition to transcribe your voice.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>NativeAgent may read files from your Desktop when you request it.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>NativeAgent may read files from your Documents folder when you request it.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>NativeAgent may read files from your Downloads folder when you request it.</string>
  <!-- Sparkle updater — see the SPARKLE_PLIST_KEYS block above (A2.1) -->
${SPARKLE_PLIST_KEYS}
  <!-- Swift-native cutover/fin-integration: BGTaskScheduler permitted identifiers.
       MUST match the com.apple.developer.background-tasks entitlement and
       the BGTaskScheduler.register(...) calls in AppDelegate. -->
  <key>BGTaskSchedulerPermittedIdentifiers</key>
  <array>
    <string>${NATIVEAGENT_BACKGROUND_TASK_PREFIX}.dream_cycle</string>
    <string>${NATIVEAGENT_BACKGROUND_TASK_PREFIX}.rem_cycle</string>
    <string>${NATIVEAGENT_BACKGROUND_TASK_PREFIX}.memory_consolidation</string>
    <string>${NATIVEAGENT_BACKGROUND_TASK_PREFIX}.self_improvement_sweep</string>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null \
  || { echo "ERROR: generated Info.plist is malformed." >&2; exit 1; }

# A2.1: the updater claim must match the mode this release actually ran in.
STAMPED_FEED_PUBLISHED="$(/usr/libexec/PlistBuddy -c "Print :NativeAgentUpdateFeedPublished" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
[[ "$STAMPED_FEED_PUBLISHED" == "$NATIVEAGENT_UPDATE_FEED_PUBLISHED" ]] \
  || { echo "ERROR: NativeAgentUpdateFeedPublished stamped '$STAMPED_FEED_PUBLISHED', expected '$NATIVEAGENT_UPDATE_FEED_PUBLISHED'." >&2; exit 1; }
if [[ "$PUBLISH_APPCAST" == "false" ]]; then
  if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "ERROR: SUFeedURL was stamped without --publish-appcast; that is the 404-feed bug." >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" == "false" ]]; then
  /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$BUNDLE/Contents/Info.plist" >/dev/null
  if [[ "$PUBLISH_APPCAST" == "true" ]]; then
    /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$BUNDLE/Contents/Info.plist" >/dev/null
  fi
elif [[ -z "$NATIVEAGENT_SPARKLE_PUBLIC_KEY" ]]; then
  echo "==> Dry-run warning: NATIVEAGENT_SPARKLE_PUBLIC_KEY is empty; full releases require it."
fi

# Finder drag-installs into /Applications preserve bundle modes from the DMG.
# Source files in this repo can be owner-only (0600), which makes a copied app
# hard for LaunchServices/Gatekeeper to assess from another user and can produce
# the generic "can't be opened because of a problem" dialog. Normalize before
# the leak guard and before signing so the sealed public app is readable and
# executable in the normal macOS app-bundle shape.
echo "==> Normalizing public bundle permissions..."
chmod -R u+rwX,go+rX "$BUNDLE"
chmod -R go-w "$BUNDLE"
assert_no_python_artifacts "$BUNDLE"
"$ROOT/script/verify_release_artifact.sh" \
  --verify-no-derived-context-state "$BUNDLE/Contents/Resources"

# PUBLIC-RELEASE LEAK GUARD: a release bundle must contain ZERO developer
# personal data, ZERO credential-looking values, ZERO live runtime state, and
# ZERO local-agent identity defaults in app-owned resources.
# Scope is deliberate:
#   - personal identifiers (handle / location / telegram id / email) fail
#     everywhere in app-owned content. The exact verified MiniLM model payload
#     is exempt because a general vocabulary legitimately contains ordinary
#     person names; similarly named files elsewhere remain fully scanned.
#   - app-owned text resources fail on common API/OAuth/JWT/private-key token
#     shapes. This catches pasted OpenAI/Anthropic/GitHub/Slack/Telegram/
#     Google/AWS/Stripe-style secrets without flagging code variable names.
#   - app-owned secret-bearing file names fail even when the value inside is
#     opaque/random and does not match a vendor-specific token regex: .env,
#     token/credential/client-secret JSON, PEM/P12/PFX/key material, npm/pypi
#     credential files, and SSH private keys. OAuth *code* may ship; OAuth
#     token/cache/config files may not.
#   - live state directories and live persona files fail. Release builds ship
#     NO persona directory inside the bundle (see ONBOARDING-2026-05-26 above);
#     the Swift runtime resolves persona to ~/Library/Application Support/NativeAgent/
#     memory/ at first run and the onboarding wizard scaffolds a blank slate
#     there.
#   - old local-agent names fail in app-owned text resources and in the
#     release executable's string table.
# Runs after ALL staging, before codesign — a tampered/regressed persona
# step aborts the release instead of shipping the developer's data.
_RES_DIR="$BUNDLE/Contents/Resources"
_PRIVACY_DENYLIST_FILE="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-$ROOT/local/privacy_denylist.regex}"
_PERSONAL_RE="${NATIVEAGENT_PRIVACY_RE:-}"
if [[ -f "$_PRIVACY_DENYLIST_FILE" ]]; then
  _FILE_PRIVACY_RE="$(grep -Ev '^[[:space:]]*(#|$)' "$_PRIVACY_DENYLIST_FILE" | paste -sd'|' - || true)"
  if [[ -n "$_FILE_PRIVACY_RE" ]]; then
    if [[ -n "$_PERSONAL_RE" ]]; then
      _PERSONAL_RE="($_PERSONAL_RE)|($_FILE_PRIVACY_RE)"
    else
      _PERSONAL_RE="$_FILE_PRIVACY_RE"
    fi
  fi
fi
_PUBLIC_IDENTITY_RE="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
_SECRET_VALUE_RE='(sk-(proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{20,}|[0-9]{7,12}:[A-Za-z0-9_-]{30,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{20,}|AKIA[0-9A-Z]{16}|(sk|rk)_live_[0-9A-Za-z]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,})'
_SECRET_FILE_RE='(^|/)(\.env($|[._-])|.*\.env$|\.npmrc$|\.pypirc$|\.netrc$|id_rsa$|id_dsa$|id_ecdsa$|id_ed25519$|credentials?\.(json|ya?ml|toml|ini)$|.*credentials?\.(json|ya?ml|toml|ini)$|token(s)?\.(json|ya?ml|toml|ini)$|.*token(s)?\.(json|ya?ml|toml|ini)$|oauth.*token.*\.(json|ya?ml|toml|ini)$|client_secret(s)?\.(json|ya?ml|toml|ini)$|.*client_secret.*\.(json|ya?ml|toml|ini)$|service[-_]?account.*\.(json|ya?ml|toml|ini)$|firebase-adminsdk.*\.json$|.*\.(pem|p12|pfx|jks|keystore|key|gpg|asc)$)'
_raw_hits=""
if [[ -n "$_PERSONAL_RE" ]]; then
  _raw_hits="$(release_personal_identity_hit_files "$BUNDLE" "$_PERSONAL_RE")"
fi
_personal_hits=""
for _f in $_raw_hits; do
  _personal_hits="$_personal_hits$_f"$'\n'
done
_personal_hits="${_personal_hits%$'\n'}"
_identity_text_hits=""
if [[ -n "$_PUBLIC_IDENTITY_RE" ]]; then
  _identity_text_hits="$(
    find "$_RES_DIR" \
      \( -path '*/minilm_vocab.txt' -o -path '*/minilm.mlpackage/*' \) -prune -o \
      -type f -print0 2>/dev/null \
    | xargs -0 grep -IlEi "$_PUBLIC_IDENTITY_RE" 2>/dev/null || true
  )"
fi
_secret_text_hits="$(
  find "$_RES_DIR" \
    -type f -print0 2>/dev/null \
  | xargs -0 grep -IlE "$_SECRET_VALUE_RE" 2>/dev/null || true
)"
_secret_file_hits="$(
  find "$_RES_DIR" \
    -type f -print 2>/dev/null \
  | awk '{ low=tolower($0); print low "\t" $0 }' \
  | awk -F '\t' -v re="$_SECRET_FILE_RE" '$1 ~ re { print $2 }' \
  || true
)"
_forbidden_runtime_hits=""
for _rel in data .runtime workspace secrets .secrets memory memory_proposals chat_sessions self_worktrees config providers approvals pairings tokens credentials oauth keychain daemon python native_agentd.py; do
  if [[ -e "$_RES_DIR/$_rel" ]]; then
    _forbidden_runtime_hits="$_forbidden_runtime_hits$_RES_DIR/$_rel"$'\n'
  fi
done
_LOCAL_STATE_DIR_RE='/(activity|approvals|browser|catalog|chat_sessions|connectors|context|credentials|dreams|evolution|inbox|keychain|knowledge_graph|memory|memory_proposals|missions|nextgen|oauth|pairings|providers|scheduler|self_worktrees|tokens|traces|trust|workflow|workflows)(/|$)'
_nested_state_hits="$(
  find "$_RES_DIR" -type d -print 2>/dev/null \
  | awk '{ low=tolower($0); print low "\t" $0 }' \
  | awk -F '\t' -v root="$(printf '%s' "$_RES_DIR" | tr '[:upper:]' '[:lower:]')" -v re="$_LOCAL_STATE_DIR_RE" '
      index($1, root "/") == 1 {
        rel = substr($1, length(root) + 1)
        if (rel ~ re) { print $2; exit }
      }' \
  || true
)"
if [[ -n "$_nested_state_hits" ]]; then
  _forbidden_runtime_hits="$_forbidden_runtime_hits"$'\n'"$_nested_state_hits"
fi
_forbidden_runtime_hits="${_forbidden_runtime_hits%$'\n'}"
# ONBOARDING-2026-05-26: NO persona dir should ever ship inside the bundle.
# Any file (template or otherwise) under Contents/Resources/persona/ is a leak
# regression: it would cause _resolve_persona_root() step 3 to resolve inside
# the read-only signed .app, breaking first-run onboarding. The persona-pruning
# step above removes the directory; this check fails the release if it crept
# back in (e.g. a stale dist/ tree, a misguided cp -R, or a future packaging
# step that re-introduces it).
_live_persona_hits="$(find "$_RES_DIR/persona" -type f -print 2>/dev/null || true)"
_test_artifact_hits="$(find "$_RES_DIR" -type f \( -name '*_tests.py' -o -name 'test_*.py' \) -print 2>/dev/null || true)"
_identity_binary_hits=""
if [[ -n "$_PUBLIC_IDENTITY_RE" && -x "$BUNDLE/Contents/MacOS/$PRODUCT" ]]; then
  _identity_binary_hits="$(strings "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null | grep -Ei "$_PUBLIC_IDENTITY_RE" | head -20 || true)"
fi
_secret_binary_hits=""
if [[ -x "$BUNDLE/Contents/MacOS/$PRODUCT" ]] \
  && strings "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null | grep -Eq "$_SECRET_VALUE_RE"; then
  _secret_binary_hits="$BUNDLE/Contents/MacOS/$PRODUCT"
fi
if [[ -n "$_personal_hits" || -n "$_identity_text_hits" || -n "$_identity_binary_hits" || -n "$_secret_text_hits" || -n "$_secret_file_hits" || -n "$_secret_binary_hits" || -n "$_forbidden_runtime_hits" || -n "$_live_persona_hits" || -n "$_test_artifact_hits" ]]; then
  echo "" >&2
  echo "ERROR: release bundle FAILED the personal-data leak guard — REFUSING TO SHIP." >&2
  if [[ -n "$_personal_hits" ]]; then
    echo "  developer personal identifiers found in:" >&2
    echo "$_personal_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_identity_text_hits" ]]; then
    echo "  local identity names found in app-owned text resources:" >&2
    echo "$_identity_text_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_identity_binary_hits" ]]; then
    echo "  local identity names found in release executable strings:" >&2
    echo "$_identity_binary_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_secret_text_hits" ]]; then
    echo "  credential-looking values found in app-owned text resources:" >&2
    echo "$_secret_text_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_secret_file_hits" ]]; then
    echo "  secret-bearing files found in app-owned resources:" >&2
    echo "$_secret_file_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_secret_binary_hits" ]]; then
    echo "  credential-looking values found in release executable strings:" >&2
    echo "$_secret_binary_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_forbidden_runtime_hits" ]]; then
    echo "  live runtime/state directories found in release resources:" >&2
    echo "$_forbidden_runtime_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_live_persona_hits" ]]; then
    echo "  persona files found in release bundle (Contents/Resources/persona must not ship — see ONBOARDING-2026-05-26):" >&2
    echo "$_live_persona_hits" | sed 's/^/    /' >&2
  fi
  if [[ -n "$_test_artifact_hits" ]]; then
    echo "  test artifacts found in release resources:" >&2
    echo "$_test_artifact_hits" | sed 's/^/    /' >&2
  fi
  echo "  Fix release defaults; do NOT ship until this is clean." >&2
  exit 1
fi
echo "[release] leak guard passed — blank slate bundle: no configured personal data, credentials, OAuth/token files, live or derived ContextFlow state, or local identity defaults"

# A1.1-2026-08-02 — COMPILED-BINARY LEAK GATE. The guard above only inspects the
# executable using an ignored maintainer denylist. Public release preflight
# requires that input, so the scan cannot silently degrade while public source
# never embeds the private identities it rejects.
#
# A1.5-2026-08-02 — BUNDLE ASSERTION. The state check above is scoped to
# Contents/Resources and stops at the first hit; this one walks the WHOLE
# bundle and names every data/ dir, trust/policy.json, providers/surfaces.json
# or user store it finds.
#
# Both run after ALL staging and before codesign, so a failure aborts the
# release with nothing signed. See script/lib/release_bundle_gates.sh.
#
# SCOPE: the identity gate is a PUBLIC-lane gate. A `personal` build is the
# maintainer's own instance, where these names are the product, not a leak —
# failing it there would break the private release lane. Everything reaching
# this point in a public lane was built from the scrubbed export (enforced
# above), so the gate is asserting that the scrub actually worked. The A1.5
# bundle assertion applies to EVERY lane: no build of any kind should carry a
# writable store inside its signed bundle.
_gate_rc=0
if [[ "$NATIVEAGENT_RELEASE_SYNC_MODE" != "personal" ]]; then
  release_assert_no_identity_strings "$BUNDLE" || _gate_rc=1
else
  echo "[leak-gate] skipped — private 'personal' lane (public lanes always run it)."
fi
release_assert_no_user_state_in_bundle "$BUNDLE" || _gate_rc=1
if [[ "$_gate_rc" -ne 0 ]]; then
  echo "ERROR: release bundle failed the A1.1/A1.5 gates — REFUSING TO SHIP." >&2
  exit 1
fi

# RELEASE-2026-05-06: step 5 — codesign
echo "==> Codesigning..."
sign_nested_plain() {
  local identity="$1"
  local timestamp_arg="${2:---timestamp}"
  if [[ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --sign "$identity" --options runtime $timestamp_arg \
      "$BUNDLE/Contents/Frameworks/Sparkle.framework"
  fi
}
if [[ "$DRY_RUN" == "true" ]]; then
  SIGN_ID="${NATIVEAGENT_DEVELOPER_ID:-}"
  DRY_RUN_ENTITLEMENTS="$ROOT/NativeAgent.adhoc.entitlements"
  if [[ -z "$SIGN_ID" ]]; then
    # A stable Apple code identity gives TCC a responsible application to
    # register. Prefer a transferable Developer ID identity for local-test
    # DMGs, then Apple Development. Keep ad-hoc as the final build-only
    # fallback for contributors without either certificate.
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
    if [[ -z "$SIGN_ID" ]]; then
      SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ {print $2; exit}')"
    fi
    if [[ -n "$SIGN_ID" ]]; then
      echo "  (dry-run) Using an available stable Apple signing identity so macOS TCC can register the app."
    else
      echo "  (dry-run) No Apple signing identity available — using ad-hoc sign."
      echo "  WARNING: ad-hoc local-test apps may not appear in macOS Privacy & Security permission lists."
      SIGN_ID="-"
    fi
  fi
  if [[ ! -f "$DRY_RUN_ENTITLEMENTS" ]]; then
    echo "ERROR: $DRY_RUN_ENTITLEMENTS not found; dry-run signing must use ad-hoc entitlements." >&2
    exit 1
  fi
  sign_nested_plain "$SIGN_ID" "--timestamp=none"
  codesign --sign "$SIGN_ID" \
    --options runtime \
    --generate-entitlement-der \
    --entitlements "$DRY_RUN_ENTITLEMENTS" \
    --force \
    "$BUNDLE"
  echo "==> Dry-run complete. Signed app at: $BUNDLE"
  echo "==> Skipping notarization (--dry-run)."
  exit 0
fi

# Full production sign with timestamp
if [[ -n "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
  if [[ ! -f "$NATIVEAGENT_PROVISIONING_PROFILE" ]]; then
    echo "ERROR: NATIVEAGENT_PROVISIONING_PROFILE does not exist: $NATIVEAGENT_PROVISIONING_PROFILE" >&2
    exit 1
  fi
  cp "$NATIVEAGENT_PROVISIONING_PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
  # Maintainer profiles are intentionally owner-readable on disk. The embedded
  # copy is public signing metadata and must remain readable to normal users;
  # copying it after the bundle-wide permission pass would otherwise preserve
  # mode 0600 and make the packaged app fail the release/launch boundary.
  chmod 0644 "$BUNDLE/Contents/embedded.provisionprofile"
fi
sign_nested_plain "$NATIVEAGENT_DEVELOPER_ID" "--timestamp"
echo "[release] signing with entitlements: $NATIVEAGENT_RELEASE_ENTITLEMENTS (iCloud build=$NATIVEAGENT_ICLOUD_BUILD)"
codesign --sign "$NATIVEAGENT_DEVELOPER_ID" \
  --options runtime \
  --generate-entitlement-der \
  --entitlements "$NATIVEAGENT_RELEASE_ENTITLEMENTS" \
  --force --timestamp \
  "$BUNDLE"

# RELEASE-2026-05-06: step 6 — create notarization zip
echo "==> Creating notarization zip..."
rm -f "$STAGE_DIR/$APP_NAME.app.zip"
ditto -c -k --keepParent "$BUNDLE" "$STAGE_DIR/$APP_NAME.app.zip"

# Notary auth: keychain profile (secret stays in keychain) or apple-id/password.
if [[ -n "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" ]]; then
  NOTARY_AUTH=( --keychain-profile "$NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE" )
else
  NOTARY_AUTH=( --apple-id "$NATIVEAGENT_APPLE_ID" --password "$NATIVEAGENT_NOTARIZATION_PASSWORD" --team-id "$NATIVEAGENT_TEAM_ID" )
fi

# RELEASE-2026-05-06: step 7 — notarize
echo "==> Submitting for notarization (this may take several minutes)..."
xcrun notarytool submit "$STAGE_DIR/$APP_NAME.app.zip" \
  "${NOTARY_AUTH[@]}" \
  --wait

# RELEASE-2026-05-06: step 8 — staple
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$BUNDLE"

# RELEASE-2026-05-06: step 9 — verify
echo "==> Verifying..."
spctl -a -vvv -t execute "$BUNDLE"
stapler validate "$BUNDLE"

# RELEASE-2026-05-06: step 10 — build DMG
# A2.1 round 2: built into STAGE_DIR, which is the quarantine dir for a
# --publish-appcast run, so the ship-ready dist/*.dmg name never exists before
# the feed is verified live. (dmg_builder also removes its populated temp image
# on every exit path, so no mountable leftover survives a failed convert.)
echo "==> Building DMG..."
NATIVEAGENT_DMG_BUNDLE="$BUNDLE" NATIVEAGENT_DMG_OUT_DIR="$STAGE_DIR" \
  "$ROOT/script/dmg_builder.sh"

DMG_PATH="$STAGE_DIR/$APP_NAME-$VERSION.dmg"

# CROSS-VERSION MOUNT FIX (2026-07-04): when the DMG is intentionally UNSIGNED
# (NATIVEAGENT_SKIP_DMG_SIGN=1) so it mounts on older macOS, skip DMG-level
# notarize/staple (an unsigned DMG can't be stapled, and doesn't need to be —
# the APP inside is already notarized + stapled, which is what Gatekeeper checks
# at launch). Still prove that the mounted app carries a valid notarization
# ticket; only the unsigned wrapper is exempt from DMG-level validation.
if [[ "${NATIVEAGENT_SKIP_DMG_SIGN:-0}" == "1" ]]; then
  echo "==> Unsigned DMG (NATIVEAGENT_SKIP_DMG_SIGN=1) — skipping DMG notarize/staple."
  "$ROOT/script/verify_release_artifact.sh" \
    --dmg "$DMG_PATH" \
    --require-clean-source \
    --require-notarized \
    --require-sparkle-key
else
  echo "==> Notarizing DMG..."
  rm -f "$DMG_PATH.zip"
  ditto -c -k --keepParent "$DMG_PATH" "$DMG_PATH.zip"
  xcrun notarytool submit "$DMG_PATH.zip" \
    "${NOTARY_AUTH[@]}" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  stapler validate "$DMG_PATH"

  echo "==> Verifying final notarized release artifact..."
  "$ROOT/script/verify_release_artifact.sh" \
    --dmg "$DMG_PATH" \
    --require-clean-source \
    --require-dmg-signature \
    --require-notarized \
    --require-sparkle-key
fi

# A2.1-2026-07-24: step 10b — generate + EdDSA-sign the Sparkle appcast, and
# publish it when asked. This runs AFTER notarize/staple so the enclosure length
# and signature cover the exact bytes users download. It is fatal on failure:
# the app in this DMG already claims NativeAgentUpdateFeedPublished=true when
# --publish-appcast was passed, so a release that cannot publish must not ship.
if [[ "$GENERATE_APPCAST" == "true" ]]; then
  APPCAST_ARGS=( --dmg "$DMG_PATH" --version "$VERSION" )
  # Sweep R4 C12 — release notes seam. --notes wins; the conventional
  # docs/release-notes/<version>.md is the zero-flag path. Nothing is
  # synthesized: with no file the Sparkle dialog stays blank as before.
  if [[ -z "$RELEASE_NOTES_FILE" && -f "$ROOT/docs/release-notes/$VERSION.md" ]]; then
    RELEASE_NOTES_FILE="$ROOT/docs/release-notes/$VERSION.md"
    echo "==> Release notes: $RELEASE_NOTES_FILE (conventional path)"
  fi
  if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    APPCAST_ARGS+=( --notes "$RELEASE_NOTES_FILE" )
    # The GitHub release body gets the same text as the Sparkle dialog.
    export NATIVEAGENT_GITHUB_RELEASE_NOTES_FILE="$RELEASE_NOTES_FILE"
  else
    echo "==> Release notes: none supplied (--notes FILE or docs/release-notes/$VERSION.md);"
    echo "    the Sparkle update dialog for this build will have no description."
  fi
  if [[ "$PUBLISH_APPCAST" == "true" ]]; then
    APPCAST_ARGS+=( --publish )
  else
    # Rehearsal: the app in this DMG deliberately carries no feed URL, so the
    # bundle<->feed cross-checks cannot apply. Every signature, version, URL and
    # length guard still runs — this proves the key and pipeline work.
    APPCAST_ARGS+=( --rehearsal )
  fi
  echo "==> Sparkle appcast (publish=$PUBLISH_APPCAST)"
  "$ROOT/script/generate_appcast.sh" "${APPCAST_ARGS[@]}"
fi

# A2.1 round 2 — step 10c: the ONLY exit from quarantine. Reached only when
# generate_appcast.sh --publish confirmed (by fetching them) that the feed and the
# DMG are live at the URLs stamped into this build. Anything that stops the script
# before this line leaves the artifacts in dist/.pending-publish/, i.e. nothing
# shippable and nothing named dist/*.dmg.
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "==> Feed verified live — promoting artifacts out of quarantine into dist/"
  release_quarantine_promote "$QUARANTINE_DIR" "$ROOT/dist"
  DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"
  BUNDLE="$ROOT/dist/$APP_NAME.app"
  [[ -f "$DMG_PATH" ]] \
    || { echo "ERROR: promotion did not land $DMG_PATH; artifacts remain in $QUARANTINE_DIR." >&2; exit 1; }
fi

# RELEASE-2026-05-28: step 11 — refresh the shared local-test DMG so the
# other macOS user account can install the latest build without a manual
# copy. /Users/Shared is readable by every user account on the machine, so
# this is the cross-user hand-off path. Naming matches the existing
# convention the install flow already expects ($APP_NAME-$VERSION-local-test).
# Guarded (if/else, not bare cp) so a copy failure can't abort an otherwise
# successful, already-notarized release under `set -e`.
SHARED_DMG="/Users/Shared/$APP_NAME-$VERSION-local-test.dmg"
echo "==> Refreshing shared DMG for cross-user install: $SHARED_DMG"
if cp -f "$DMG_PATH" "$SHARED_DMG"; then
  chmod 644 "$SHARED_DMG" 2>/dev/null || true
  echo "    Shared DMG updated."
else
  echo "    WARNING: could not write $SHARED_DMG (release itself still succeeded)." >&2
fi

echo ""
echo "==> Release v$VERSION complete!"
echo "    App:  $BUNDLE"
echo "    DMG:  $DMG_PATH"
echo "    Shared (cross-user install): $SHARED_DMG"
echo ""
echo "Next steps:"
if [[ "$PUBLISH_APPCAST" == "true" ]]; then
  echo "  Feed published AND verified live: $NATIVEAGENT_APPCAST_URL"
  echo "  1. Nothing to upload: the DMG at $NATIVEAGENT_DMG_DOWNLOAD_URL was fetched"
  echo "     and its length matched this artifact before the release was released."
  echo "  2. Verify from a previous version: install the older build, then use"
  echo "     Check for Updates… and confirm it offers $VERSION."
elif [[ "$GENERATE_APPCAST" == "true" ]]; then
  echo "  Rehearsal only: dist/appcast/appcast.xml was generated + signed, NOT uploaded,"
  echo "  and this app carries NO feed URL (its updater is honestly disabled)."
  echo "  Do NOT hand-upload this feed — the app it describes cannot read it."
  echo "  Re-run with --publish-appcast to ship a build whose updater is enabled."
else
  echo "  1. Upload $APP_NAME-$VERSION.dmg to your release hosting"
  echo "  2. This build ships with the updater honestly disabled (no feed URL)."
  echo "     To ship a self-updating build, re-run with --publish-appcast after"
  echo "     setting NATIVEAGENT_APPCAST_URL and NATIVEAGENT_DMG_DOWNLOAD_URL."
fi
