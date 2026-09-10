#!/usr/bin/env bash
# Verify a built NativeAgent DMG as a public distribution artifact.
#
# This intentionally checks the mounted DMG, not only dist/NativeAgent.app:
# Finder drag-install failures, bad permissions, stale REPO_PATH stamps, and
# copied runtime state are distribution bugs even when the staged app looked OK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/plist_types.sh
source "$ROOT/script/lib/plist_types.sh"
# shellcheck source=lib/provisioning_profile_contract.sh
source "$ROOT/script/lib/provisioning_profile_contract.sh"
# shellcheck source=lib/release_bundle_gates.sh
source "$ROOT/script/lib/release_bundle_gates.sh"
# shellcheck source=lib/release_symbols.sh
source "$ROOT/script/lib/release_symbols.sh"
APP_NAME="NativeAgent"
PRODUCT="NativeAgentApp"
REQUIRE_NOTARIZED=false
REQUIRE_DMG_SIGNATURE=false
REQUIRE_SPARKLE_KEY=false
REQUIRE_CLEAN_SOURCE=false
BUNDLE_PATH=""
RESOURCE_SOURCE_ROOT=""
RESOURCE_BUNDLE_ROOT=""
DERIVED_CONTEXT_SCAN_ROOT=""
ARTIFACT_OPTION_SET=false
EXPECTED_MAC_BUNDLE_ID="${NATIVEAGENT_EXPECTED_MAC_BUNDLE_ID:-${NATIVEAGENT_MAC_BUNDLE_ID:-io.github.embwl0x.nativeagent.mac}}"

VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: $VERSION_FILE not found." >&2
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"

usage() {
  cat >&2 <<USAGE
Usage: $0 [--dmg path] [--bundle path] [--require-notarized] [--require-dmg-signature] [--require-sparkle-key] [--require-clean-source]
       $0 --verify-resource-source repo_root
       $0 --verify-resource-bundle contents_resources_dir
       $0 --verify-no-derived-context-state tree_root
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DMG_PATH="$2"
      ARTIFACT_OPTION_SET=true
      shift 2
      ;;
    --bundle)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      BUNDLE_PATH="$2"
      ARTIFACT_OPTION_SET=true
      shift 2
      ;;
    --require-notarized)
      REQUIRE_NOTARIZED=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-dmg-signature)
      REQUIRE_DMG_SIGNATURE=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-sparkle-key)
      REQUIRE_SPARKLE_KEY=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --require-clean-source)
      REQUIRE_CLEAN_SOURCE=true
      ARTIFACT_OPTION_SET=true
      shift
      ;;
    --verify-resource-source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      RESOURCE_SOURCE_ROOT="$2"
      shift 2
      ;;
    --verify-resource-bundle)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      RESOURCE_BUNDLE_ROOT="$2"
      shift 2
      ;;
    --verify-no-derived-context-state)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      DERIVED_CONTEXT_SCAN_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

verify_no_derived_context_state() {
  local scan_root="$1" context="$2"
  local hit

  [[ -d "$scan_root" && ! -L "$scan_root" ]] \
    || fail "$context scan root is not a real directory: $scan_root"

  # The canonical subtree is entirely rebuildable local state. The basename
  # checks also catch SQLite sidecars and state copied outside that subtree by
  # a future export or staging step. Context source and test filenames remain
  # valid because only artifact-shaped names are rejected.
  local scan_paths
  scan_paths="$(release_find_checked "$context derived-context" "$scan_root" -mindepth 1 -print)" \
    || fail "$context derived-context walk of $scan_root did not run correctly"
  hit="$(
    printf '%s\n' "$scan_paths" \
    | awk 'NF' \
    | LC_ALL=C awk -v root="$scan_root/" '
        !found {
          path = $0
          relative = path
          if (index(relative, root) == 1) {
            relative = substr(relative, length(root) + 1)
          }
          lower = tolower(relative)
          count = split(lower, components, "/")
          basename = components[count]
          framed = "/" lower
          if (framed ~ /\/data\/context(\/|$)/ ||
              basename == "context.sqlite" ||
              basename ~ /^context\.sqlite[-.]/ ||
              basename ~ /^context[-_.]?(flow[-_.]?)?(receipts?|registrations?|arena[-_.]?snapshots?|snapshots?|diagnostics?)(\..*)?$/ ||
              framed ~ /\/context\/(.*[-_.])?(receipts?|registrations?|arena[-_.]?snapshots?|snapshots?|diagnostics?)(\/|\.|$)/ ||
              framed ~ /\/(context[-_]?flow[-_]?(state|cache)|derived[-_]?context)(\/|$)/) {
            print path
            found = 1
          }
        }
      '
  )"

  [[ -z "$hit" ]] \
    || fail "derived ContextFlow state found in $context: $hit"
  echo "[resources] verified no derived ContextFlow state in $context: $scan_root"
}

MINILM_SOURCE_RESOURCE_PATH="Modules/NativeAgentCore/Sources/MemoryV2/Resources"
MINILM_SWIFTPM_BUNDLE_NAME="NativeAgentCore_MemoryV2.bundle"

# Required byte sizes and SHA-256 hashes are the release resource manifest.
# Updating the model requires an intentional manifest change in this script.
MINILM_REQUIRED_FILES=(
  $'minilm_vocab.txt\t231508\t07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3'
  $'minilm.mlpackage/Manifest.json\t617\t911f501a4c3f06b795ddced1606dca39f1b6c3f2bd88a06455a65a04cda4c3a3'
  $'minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel\t71688\t8ce9abd3d498444303732974cdc7e9d959d9463e18e240f6d22f81502fe86318'
  $'minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin\t44939136\tf6d040d94a3a476264c26cb3b6d260aa695784121667e6bff6690f56de558d41'
)
MINILM_EXPECTED_PATHS=(
  "minilm.mlpackage"
  "minilm.mlpackage/Data"
  "minilm.mlpackage/Data/com.apple.CoreML"
  "minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "minilm.mlpackage/Data/com.apple.CoreML/weights"
  "minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "minilm.mlpackage/Manifest.json"
  "minilm_vocab.txt"
)

verify_minilm_resource_tree() {
  local resource_root="$1" context="$2"
  local spec relative_path expected_bytes expected_sha resource_path actual_bytes actual_sha
  local actual_paths missing_paths unexpected_paths first_path symlink_path

  [[ -d "$resource_root" && ! -L "$resource_root" ]] \
    || fail "$context missing required MiniLM resource directory: $resource_root"

  symlink_path="$(release_find_checked "$context MiniLM symlink" "$resource_root" -type l -print)" \
    || fail "$context MiniLM symlink scan of $resource_root did not run correctly"
  symlink_path="$(printf '%s\n' "$symlink_path" | sed '/^$/d' | head -1)"
  [[ -z "$symlink_path" ]] \
    || fail "$context contains unexpected MiniLM resource symlink: $symlink_path"

  for spec in "${MINILM_REQUIRED_FILES[@]}"; do
    IFS=$'\t' read -r relative_path expected_bytes expected_sha <<<"$spec"
    resource_path="$resource_root/$relative_path"
    [[ -f "$resource_path" && ! -L "$resource_path" ]] \
      || fail "$context missing required MiniLM resource: $resource_path"
    actual_bytes="$(wc -c < "$resource_path" | tr -d '[:space:]')"
    [[ "$actual_bytes" =~ ^[0-9]+$ ]] \
      || fail "$context could not measure MiniLM resource: $resource_path"
    [[ "$actual_bytes" == "$expected_bytes" ]] \
      || fail "$context has wrong-sized MiniLM resource: $resource_path ($actual_bytes bytes; require $expected_bytes)"
    actual_sha="$(shasum -a 256 "$resource_path" | awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
      || fail "$context has hash-mismatched MiniLM resource: $resource_path"
  done

  actual_paths="$(
    cd "$resource_root"
    find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort
  )"
  missing_paths="$(
    comm -23 \
      <(printf '%s\n' "${MINILM_EXPECTED_PATHS[@]}" | LC_ALL=C sort) \
      <(printf '%s\n' "$actual_paths")
  )"
  if [[ -n "$missing_paths" ]]; then
    first_path="${missing_paths%%$'\n'*}"
    fail "$context missing required MiniLM resource path: $resource_root/$first_path"
  fi
  unexpected_paths="$(
    comm -13 \
      <(printf '%s\n' "${MINILM_EXPECTED_PATHS[@]}" | LC_ALL=C sort) \
      <(printf '%s\n' "$actual_paths")
  )"
  if [[ -n "$unexpected_paths" ]]; then
    first_path="${unexpected_paths%%$'\n'*}"
    fail "$context contains unexpected MiniLM resource path: $resource_root/$first_path"
  fi
}

verify_minilm_source_resources() {
  local repo_root="$1"
  local resource_root="$repo_root/$MINILM_SOURCE_RESOURCE_PATH"
  verify_minilm_resource_tree "$resource_root" "source tree"
  echo "[resources] verified required MiniLM source resources: $resource_root"
}

verify_minilm_swiftpm_resources() {
  local contents_resources="$1"
  local expected_bundle="$contents_resources/$MINILM_SWIFTPM_BUNDLE_NAME"
  local candidate expected_package expected_vocab

  [[ -d "$contents_resources" && ! -L "$contents_resources" ]] \
    || fail "missing app Contents/Resources directory: $contents_resources"
  [[ -d "$expected_bundle" && ! -L "$expected_bundle" ]] \
    || fail "missing expected SwiftPM resource bundle: $expected_bundle"

  verify_minilm_resource_tree "$expected_bundle" "staged SwiftPM bundle"

  expected_package="$expected_bundle/minilm.mlpackage"
  expected_vocab="$expected_bundle/minilm_vocab.txt"
  local minilm_candidates
  minilm_candidates="$(release_find_checked "staged MiniLM" "$contents_resources" \
    \( -name 'minilm.mlpackage' -o -name 'minilm_vocab.txt' \) -print)" \
    || fail "staged MiniLM scan of $contents_resources did not run correctly"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" == "$expected_package" || "$candidate" == "$expected_vocab" ]] \
      || fail "MiniLM resource staged outside expected SwiftPM resource bundle: $candidate"
  done <<< "$minilm_candidates"

  echo "[resources] verified staged MiniLM SwiftPM bundle: $expected_bundle"
}

verify_bridge_helper_source_resources() {
  local repo_root="$1" codex_helper claude_helper omp_helper
  codex_helper="$repo_root/script/codex_thread_wakeup.js"
  [[ -f "$codex_helper" && ! -L "$codex_helper" ]] \
    || fail "source tree missing required Codex bridge helper: $codex_helper"
  claude_helper=""
  if [[ -f "$repo_root/script/claude_thread_wakeup.js" && ! -L "$repo_root/script/claude_thread_wakeup.js" ]]; then
    claude_helper="$repo_root/script/claude_thread_wakeup.js"
  elif [[ -f "$repo_root/script/claude_thread_wakeup.js" && ! -L "$repo_root/script/claude_thread_wakeup.js" ]]; then
    claude_helper="$repo_root/script/claude_thread_wakeup.js"
  fi
  [[ -n "$claude_helper" ]] \
    || fail "source tree missing required Claude Code bridge helper"
  [[ "$(wc -c < "$codex_helper" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "Codex bridge helper is unexpectedly small: $codex_helper"
  [[ "$(wc -c < "$claude_helper" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "Claude Code bridge helper is unexpectedly small: $claude_helper"
  omp_helper="$repo_root/script/omp_thread_wakeup.js"
  [[ -f "$omp_helper" && ! -L "$omp_helper" ]] \
    || fail "source tree missing required OMP bridge helper: $omp_helper"
  [[ "$(wc -c < "$omp_helper" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "OMP bridge helper is unexpectedly small: $omp_helper"
  echo "[resources] verified bridge helper source resources"
}

verify_bridge_helper_bundle_resources() {
  local contents_resources="$1" codex_hits claude_hits omp_hits codex_count claude_count omp_count
  codex_hits="$(release_find_checked "Codex bridge helper" "$contents_resources" -type f -name 'codex_thread_wakeup.js' -print)" \
    || fail "Codex bridge helper scan of $contents_resources did not run correctly"
  claude_hits="$(release_find_checked "Claude bridge helper" "$contents_resources" -type f \
    \( -name 'claude_thread_wakeup.js' -o -name 'claude_thread_wakeup.js' \) \
    -print)" \
    || fail "Claude bridge helper scan of $contents_resources did not run correctly"
  omp_hits="$(release_find_checked "OMP bridge helper" "$contents_resources" -type f -name 'omp_thread_wakeup.js' -print)" \
    || fail "OMP bridge helper scan of $contents_resources did not run correctly"
  codex_count="$(printf '%s\n' "$codex_hits" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  claude_count="$(printf '%s\n' "$claude_hits" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  omp_count="$(printf '%s\n' "$omp_hits" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  [[ "$codex_count" == "1" ]] \
    || fail "release resources require exactly one Codex bridge helper; found $codex_count"
  [[ "$claude_count" == "1" ]] \
    || fail "release resources require exactly one Claude Code bridge helper; found $claude_count"
  [[ "$omp_count" == "1" ]] \
    || fail "release resources require exactly one OMP bridge helper; found $omp_count"
  [[ "$(wc -c < "$codex_hits" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "bundled Codex bridge helper is unexpectedly small: $codex_hits"
  [[ "$(wc -c < "$claude_hits" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "bundled Claude Code bridge helper is unexpectedly small: $claude_hits"
  [[ "$(wc -c < "$omp_hits" | tr -d '[:space:]')" -gt 10000 ]] \
    || fail "bundled OMP bridge helper is unexpectedly small: $omp_hits"
  echo "[resources] verified staged Codex, Claude Code, and OMP bridge helpers"
}

verify_data_bounds_bundle_resource() {
  local contents_resources="$1" data_bounds
  [[ -d "$contents_resources" && ! -L "$contents_resources" ]] \
    || fail "missing app Contents/Resources directory: $contents_resources"
  data_bounds="$contents_resources/docs/data-bounds.md"
  [[ -f "$data_bounds" && ! -L "$data_bounds" ]] \
    || fail "release resources missing data-limits reference: $data_bounds"
  [[ -s "$data_bounds" ]] \
    || fail "release data-limits reference is empty: $data_bounds"
  echo "[resources] verified bundled data-limits reference: $data_bounds"
}

SPECIAL_MODE_COUNT=0
[[ -n "$RESOURCE_SOURCE_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
[[ -n "$RESOURCE_BUNDLE_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
[[ -n "$DERIVED_CONTEXT_SCAN_ROOT" ]] && ((SPECIAL_MODE_COUNT += 1))
if (( SPECIAL_MODE_COUNT > 1 )); then
  fail "choose exactly one focused verification mode"
fi
if (( SPECIAL_MODE_COUNT == 1 )); then
  [[ "$ARTIFACT_OPTION_SET" == "false" ]] \
    || fail "focused verification modes cannot be combined with artifact options"
  if [[ -n "$RESOURCE_SOURCE_ROOT" ]]; then
    verify_minilm_source_resources "$RESOURCE_SOURCE_ROOT"
    verify_bridge_helper_source_resources "$RESOURCE_SOURCE_ROOT"
  elif [[ -n "$RESOURCE_BUNDLE_ROOT" ]]; then
    verify_minilm_swiftpm_resources "$RESOURCE_BUNDLE_ROOT"
    verify_bridge_helper_bundle_resources "$RESOURCE_BUNDLE_ROOT"
  else
    verify_no_derived_context_state "$DERIVED_CONTEXT_SCAN_ROOT" "selected tree"
  fi
  exit 0
fi

if [[ -n "$BUNDLE_PATH" && "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
  fail "--bundle verifies an app bundle only; DMG signature requirements need --dmg"
fi

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing required directory: $1"
}

verify_chrome_payload() {
  local bundle="$1" relative
  local relay="$bundle/Contents/MacOS/NativeAgentChromeRelay"
  local extension="$bundle/Contents/Resources/NativeAgentChrome"
  [[ -f "$relay" && -x "$relay" && ! -L "$relay" ]] \
    || fail "missing Chrome relay executable: $relay"
  # Include imported modules as well as the manifest's entry points.
  for relative in manifest.json src/background.js src/browser-workspace.js \
    src/lease-manager.js src/protocol.js src/user-touch.js src/page-agent.js; do
    [[ -s "$extension/$relative" && ! -L "$extension/$relative" ]] \
      || fail "missing Chrome extension resource: $relative"
  done
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

require_plist_value() {
  local plist="$1" key="$2" expected="$3" actual
  actual="$(plist_value "$plist" "$key")"
  [[ "$actual" == "$expected" ]] || fail "Info.plist $key expected '$expected', got '$actual'"
}

# A2.1 round 2 (gpt-5.5 MED): PlistBuddy STRINGIFIES everything, so
# <string>true</string> printed "true" and passed the updater-honesty gates below
# while UpdateController.swift reads `info[key] as? Bool` and saw nil — i.e. an
# artifact could pass verification with its updater silently disabled. Assert the
# plist value TYPE, never the printed text. plist_bool_state / plist_string_state
# live in script/lib/plist_types.sh so the guard tests exercise this exact code.

# Fails when the key exists but is not a real plist Boolean. Absent is allowed —
# the callers decide what absence means.
#
# Result lands in the global PLIST_BOOL_STATE ("true"/"false"/"" for absent)
# rather than on stdout ON PURPOSE: `x="$(fn)"` would run fail()'s `exit 1` in a
# SUBSHELL, so the verifier would print the error and keep going with an empty
# value — a fail-open verifier is worse than none.
PLIST_BOOL_STATE=""
require_plist_bool_or_absent() {
  local plist="$1" key="$2" state
  state="$(plist_bool_state "$plist" "$key")"
  case "$state" in
    absent) PLIST_BOOL_STATE="" ;;
    true|false) PLIST_BOOL_STATE="$state" ;;
    *)
      fail "Info.plist $key must be a real Boolean (<true/>/<false/>), got ${state#non-boolean:}.
       A stringified 'true' passes text comparisons but reads as nil in Swift
       (\`info[\"$key\"] as? Bool\`), which silently disables the updater."
      ;;
  esac
}

require_absent() {
  [[ ! -e "$1" ]] || fail "forbidden release artifact present: $1"
}

MOUNT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-artifact-verify.XXXXXX")"
MOUNT_POINT="$MOUNT_BASE/mount"
cleanup() {
  if [[ -z "$BUNDLE_PATH" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_BASE"
}
trap cleanup EXIT

if [[ -n "$BUNDLE_PATH" ]]; then
  echo "==> Verifying NativeAgent app bundle: $BUNDLE_PATH"
  BUNDLE="$BUNDLE_PATH"
else
  echo "==> Verifying NativeAgent release artifact: $DMG_PATH"
  require_file "$DMG_PATH"

  echo "  hdiutil verify..."
  hdiutil verify "$DMG_PATH" >/dev/null

  if codesign -dv "$DMG_PATH" >/dev/null 2>&1; then
    echo "  DMG codesign verify..."
    codesign --verify --verbose=2 "$DMG_PATH" >/dev/null
  elif [[ "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
    fail "DMG is not codesigned"
  else
    echo "  WARNING: DMG is unsigned; pass --require-dmg-signature for production gating."
  fi

  mkdir -p "$MOUNT_POINT"
  echo "  mounting read-only..."
  hdiutil attach "$DMG_PATH" -readonly -nobrowse -noverify -mountpoint "$MOUNT_POINT" >/dev/null
  BUNDLE="$MOUNT_POINT/$APP_NAME.app"
fi
INFO="$BUNDLE/Contents/Info.plist"
EXECUTABLE="$BUNDLE/Contents/MacOS/$PRODUCT"
RESOURCES="$BUNDLE/Contents/Resources"

require_dir "$BUNDLE"
require_file "$INFO"
require_file "$EXECUTABLE"
[[ -x "$EXECUTABLE" ]] || fail "main executable is not executable: $EXECUTABLE"
verify_chrome_payload "$BUNDLE"

if [[ -z "$BUNDLE_PATH" ]]; then
  [[ -L "$MOUNT_POINT/Applications" ]] || fail "DMG missing /Applications symlink"
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || fail "DMG /Applications symlink points to $(readlink "$MOUNT_POINT/Applications")"
fi

require_plist_value "$INFO" "CFBundleIdentifier" "$EXPECTED_MAC_BUNDLE_ID"
require_plist_value "$INFO" "CFBundleExecutable" "$PRODUCT"
# Internal (non-publish) lanes stamp CFBundleShortVersionString with a
# -dev.<sha8>[.dirty] marker so an internal build can never impersonate the
# published release (seat-hygiene, 2026-08-21). release.sh exports the
# expected marked value; a bare invocation still requires the plain VERSION.
require_plist_value "$INFO" "CFBundleShortVersionString" \
  "${NATIVEAGENT_EXPECTED_SHORT_VERSION:-$VERSION}"
require_plist_value "$INFO" "CFBundleVersion" "$VERSION"
require_plist_value "$INFO" "CFBundlePackageType" "APPL"
require_plist_value "$INFO" "LSMinimumSystemVersion" "26.0"
require_plist_value "$INFO" "UTExportedTypeDeclarations:0:UTTypeIdentifier" "com.nativeagent.chat-session"

SPARKLE_KEY="$(plist_value "$INFO" "SUPublicEDKey")"
if [[ "$REQUIRE_SPARKLE_KEY" == "true" ]]; then
  [[ -n "$SPARKLE_KEY" ]] || fail "SUPublicEDKey is empty"
  if ! printf '%s' "$SPARKLE_KEY" | base64 -D >/dev/null 2>&1; then
    fail "SUPublicEDKey is not valid base64"
  fi
  SPARKLE_KEY_BYTES="$(printf '%s' "$SPARKLE_KEY" | base64 -D | wc -c | tr -d '[:space:]')"
  [[ "$SPARKLE_KEY_BYTES" == "32" ]] || fail "SUPublicEDKey must decode to 32 bytes; got $SPARKLE_KEY_BYTES"
fi

# A2.1-2026-07-24: updater honesty. An artifact must never advertise an update
# feed it cannot actually serve. dist/NativeAgent-0.2.0.dmg shipped with
# SUFeedURL pointing at an example.com placeholder; this is the gate that would
# have stopped it. Checked unconditionally — a lying feed URL is never OK.
SPARKLE_FEED_URL="$(plist_value "$INFO" "SUFeedURL")"
# Type-strict: these two are what the app reads as Swift Bool, so a stringified
# "true" here means the shipped updater is OFF while the text says it is on.
require_plist_bool_or_absent "$INFO" "NativeAgentUpdateFeedPublished"
SPARKLE_FEED_PUBLISHED="$PLIST_BOOL_STATE"
require_plist_bool_or_absent "$INFO" "SUEnableAutomaticChecks"
SPARKLE_AUTO_CHECKS="$PLIST_BOOL_STATE"
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  # Sparkle itself reads SUFeedURL as a string; a Boolean/number here would make
  # the feed URL unreadable to the framework at runtime.
  SPARKLE_FEED_URL_TYPE="$(plist_string_state "$INFO" SUFeedURL)"
  [[ "$SPARKLE_FEED_URL_TYPE" == "string" ]] \
    || fail "Info.plist SUFeedURL must be a <string>; Sparkle cannot read any other type."
  if printf '%s' "$SPARKLE_FEED_URL" | grep -Eqi '(^|//|\.)(example\.(com|org|net|invalid)|localhost)(/|:|$)'; then
    fail "SUFeedURL is a placeholder that will 404 for every user: $SPARKLE_FEED_URL"
  fi
  [[ "$SPARKLE_FEED_URL" =~ ^https:// ]] || fail "SUFeedURL must be https: $SPARKLE_FEED_URL"
  [[ "$SPARKLE_FEED_PUBLISHED" == "true" ]] \
    || fail "SUFeedURL is stamped but NativeAgentUpdateFeedPublished is '${SPARKLE_FEED_PUBLISHED:-absent}' — build with ./script/release.sh --publish-appcast"
fi
if [[ "$SPARKLE_FEED_PUBLISHED" == "true" ]]; then
  [[ -n "$SPARKLE_FEED_URL" ]] || fail "NativeAgentUpdateFeedPublished is true but no SUFeedURL is stamped"
  [[ -n "$SPARKLE_KEY" ]] || fail "NativeAgentUpdateFeedPublished is true but SUPublicEDKey is empty"
elif [[ "$SPARKLE_AUTO_CHECKS" == "true" ]]; then
  fail "SUEnableAutomaticChecks is true with no published feed — background checks would 404"
fi

release_assert_executable_stripped "$EXECUTABLE" \
  || fail "release executable contains non-external symbols"

require_dir "$RESOURCES"
require_file "$RESOURCES/VERSION"
require_file "$RESOURCES/VERSION_SHA"
SOURCE_REVISION="$(tr -d '[:space:]' < "$RESOURCES/VERSION_SHA")"
PLIST_SOURCE_REVISION="$(plist_value "$INFO" "NativeAgentSourceRevision")"
SOURCE_DIRTY="$(plist_value "$INFO" "NativeAgentSourceDirty")"
[[ "$SOURCE_REVISION" =~ ^[0-9A-Fa-f]{40}$ || "$SOURCE_REVISION" =~ ^[0-9A-Fa-f]{64}$ ]] \
  || fail "VERSION_SHA must contain one full Git object ID"
[[ "$PLIST_SOURCE_REVISION" == "$SOURCE_REVISION" ]] \
  || fail "Info.plist source revision does not match Resources/VERSION_SHA"
[[ "$SOURCE_DIRTY" == "true" || "$SOURCE_DIRTY" == "false" ]] \
  || fail "Info.plist NativeAgentSourceDirty must be a Boolean"
if [[ "$REQUIRE_CLEAN_SOURCE" == "true" && "$SOURCE_DIRTY" != "false" ]]; then
  fail "release artifact was built from a dirty or unknown source tree"
fi
verify_minilm_swiftpm_resources "$RESOURCES"
verify_bridge_helper_bundle_resources "$RESOURCES"
verify_data_bounds_bundle_resource "$RESOURCES"
verify_no_derived_context_state "$RESOURCES" "release resources"
require_absent "$RESOURCES/daemon"
require_absent "$RESOURCES/native_agentd.py"
require_absent "$RESOURCES/python"

for forbidden in \
  REPO_PATH data .runtime workspace secrets .secrets cognition memory memory_proposals \
  chat_sessions self_worktrees config providers approvals pairings tokens credentials \
  oauth keychain .env daemon native_agentd.py python
do
  require_absent "$RESOURCES/$forbidden"
done

LOCAL_STATE_DIR_RE='/(activity|approvals|browser|catalog|chat_sessions|cognition|connectors|context|credentials|dreams|evolution|inbox|keychain|knowledge_graph|memory|memory_proposals|missions|nextgen|oauth|pairings|providers|scheduler|self_worktrees|tokens|traces|trust|workflow|workflows)(/|$)'
# SCANNER-INTEGRITY CONTRACT (2026-08-21, round 2): every walk below goes
# through release_find_checked, which keeps find's exit status. The old
# `find ... 2>/dev/null || true` form made a partially-failed walk (unreadable
# subdirectory) look exactly like a clean bundle, and `-print -quit` threw the
# status away a second time by exiting 0 after the error.
local_state_dirs="$(release_find_checked "artifact state-directory" "$RESOURCES" -type d -print)" \
  || fail "state-directory scan of $RESOURCES did not run correctly"
local_state_dir_hit="$(
  printf '%s\n' "$local_state_dirs" \
  | awk 'NF' \
  | awk '{ low=tolower($0); print low "\t" $0 }' \
  | awk -F '\t' -v root="$(printf '%s' "$RESOURCES" | tr '[:upper:]' '[:lower:]')" -v re="$LOCAL_STATE_DIR_RE" '
      index($1, root "/") == 1 {
        rel = substr($1, length(root) + 1)
        if (rel ~ re) { print $2; exit }
      }'
)"
[[ -z "$local_state_dir_hit" ]] || fail "live NativeAgent state directory shipped in release resources: $local_state_dir_hit"

first_line() { printf '%s\n' "$1" | sed '/^$/d' | head -1; }

bad_world_writable="$(release_find_checked "world-writable" "$BUNDLE" -perm -002 -print)" \
  || fail "world-writable scan of $BUNDLE did not run correctly"
[[ -z "$bad_world_writable" ]] || fail "world-writable path inside app bundle: $(first_line "$bad_world_writable")"

bad_readable="$(release_find_checked "readability" "$BUNDLE" \( -type f ! -perm -004 -o -type d ! -perm -005 \) -print)" \
  || fail "readability scan of $BUNDLE did not run correctly"
[[ -z "$bad_readable" ]] || fail "path is not readable/traversable by normal users: $(first_line "$bad_readable")"

pycache_hits="$(release_find_checked "__pycache__" "$RESOURCES" -type d -name '__pycache__' -print)" \
  || fail "__pycache__ scan of $RESOURCES did not run correctly"
[[ -z "$pycache_hits" ]] || fail "Python cache directory shipped in release bundle: $(first_line "$pycache_hits")"
bytecode_hits="$(release_find_checked "bytecode" "$RESOURCES" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print)" \
  || fail "bytecode scan of $RESOURCES did not run correctly"
[[ -z "$bytecode_hits" ]] || fail "Python bytecode shipped in release bundle: $(first_line "$bytecode_hits")"
backup_hits="$(release_find_checked "backup-file" "$RESOURCES" -type f -name '*.bak*' -print)" \
  || fail "backup-file scan of $RESOURCES did not run correctly"
[[ -z "$backup_hits" ]] || fail "backup file shipped in release bundle: $(first_line "$backup_hits")"
test_artifact_hits="$(release_find_checked "test-artifact" "$RESOURCES" -type f \( -name '*_tests.py' -o -name 'test_*.py' \) -print)" \
  || fail "test-artifact scan of $RESOURCES did not run correctly"
[[ -z "$test_artifact_hits" ]] || fail "test artifact shipped in release bundle: $(first_line "$test_artifact_hits")"

# ONBOARDING-2026-05-26: a public release bundle MUST NOT contain a persona
# directory. Earlier revisions shipped *.template.md placeholders here, but
# that caused _resolve_persona_root() step 3 to resolve inside the read-only
# signed .app on public installs, which auto-scaffolded SOUL.md and locked
# users out of the first-run onboarding wizard. The contract is now: no
# persona dir in the bundle; Swift onboarding resolves first-run data under
# the writable data root. Any file under Contents/Resources/persona is a
# regression that must fail the artifact verifier.
[[ ! -e "$RESOURCES/persona" ]] || fail "Contents/Resources/persona must not ship — see release.sh ONBOARDING-2026-05-26"

# SCANNER-INTEGRITY CONTRACT (2026-08-21): these scans go through the
# release_scan_* helpers, which validate the pattern, assert the scan had a
# subject, and never swallow the scanner's exit code. See the long note at the
# top of script/lib/release_bundle_gates.sh.
# The secret VALUE pattern is no longer copied here: release_scan_dir_for_
# secret_values owns it, so the verifier and the release leak guard cannot drift
# apart on either the pattern or the binary-pass flag.
SECRET_FILE_RE="$RELEASE_SECRET_FILE_RE"

release_assert_scanner_canary "artifact verifier" \
  || fail "artifact-verifier scanner self-test failed; its clean verdicts cannot be trusted"

secret_file_hits="$(release_scan_dir_for_filename_re "$RESOURCES" "artifact secret filename" "$SECRET_FILE_RE")" \
  || fail "secret-filename scan of $RESOURCES did not run correctly"
[[ -z "$secret_file_hits" ]] || fail "secret-bearing filename shipped in release bundle: $(printf '%s' "$secret_file_hits" | head -1)"

PRIVACY_DENYLIST_FILE="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-$ROOT/local/privacy_denylist.regex}"
PERSONAL_RE="${NATIVEAGENT_PRIVACY_RE:-}"
if [[ -n "$PERSONAL_RE" ]]; then
  release_require_valid_regex "$PERSONAL_RE" "NATIVEAGENT_PRIVACY_RE" \
    || fail "NATIVEAGENT_PRIVACY_RE is not a usable pattern"
fi
if [[ -f "$PRIVACY_DENYLIST_FILE" ]]; then
  FILE_PRIVACY_RE="$(release_denylist_regex_from_file "$PRIVACY_DENYLIST_FILE")" \
    || fail "privacy denylist $PRIVACY_DENYLIST_FILE is unusable; a broken pattern scans nothing"
  if [[ -n "$FILE_PRIVACY_RE" ]]; then
    if [[ -n "$PERSONAL_RE" ]]; then
      PERSONAL_RE="($PERSONAL_RE)|($FILE_PRIVACY_RE)"
    else
      PERSONAL_RE="$FILE_PRIVACY_RE"
    fi
  fi
fi
raw_personal_hits=""
if [[ -n "$PERSONAL_RE" ]]; then
  raw_personal_hits="$(release_personal_identity_hit_files "$BUNDLE" "$PERSONAL_RE")" \
    || fail "personal-identity scan of $BUNDLE did not run correctly"
else
  echo "  WARNING: no NATIVEAGENT_PRIVACY_RE and no usable privacy denylist — personal-identifier scan SKIPPED." >&2
fi
# Read line-wise: word-splitting shredded any hit path containing a space, so
# the verifier reported a fragment of the file it was rejecting.
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  fail "configured personal identifier found in release artifact: $hit"
done <<< "$raw_personal_hits"

# Binary pass included — see release_scan_binary_files_for_regex. `grep -I`
# alone reports rc 1 "no match" for every binary resource, so a token inside a
# binary plist or compiled asset used to pass the verifier untouched.
secret_value_hits="$(release_scan_dir_for_secret_values "$RESOURCES" "artifact secret value")" \
  || fail "secret-value scan of $RESOURCES did not run correctly"
[[ -z "$secret_value_hits" ]] || fail "credential-looking value shipped in release resources: $(printf '%s' "$secret_value_hits" | head -1)"

PUBLIC_IDENTITY_RE="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
identity_text_hits=""
identity_binary_hit=""
if [[ -n "$PUBLIC_IDENTITY_RE" ]]; then
  identity_text_hits="$(
    release_scan_dir_for_regex "$RESOURCES" "artifact resource identity" ci "$PUBLIC_IDENTITY_RE" \
      '*/minilm_vocab.txt' '*/minilm.mlpackage/*' '*/embedding/vocab.txt' '*/embedding/embedding.mlpackage/*'
  )" || fail "identity resource scan of $RESOURCES did not run correctly"
  identity_binary_hit="$(release_scan_binary_for_local_identity "$EXECUTABLE" "artifact executable identity" "$PUBLIC_IDENTITY_RE")" \
    || fail "identity executable scan of $EXECUTABLE did not run correctly"
else
  # release_github.sh REQUIRES this input; a direct verifier run must at least
  # say out loud that the identity check did not happen.
  echo "  WARNING: NATIVEAGENT_LOCAL_IDENTITY_RE is unset — local-identity scans of" >&2
  echo "           release resources AND of the executable were SKIPPED." >&2
fi
[[ -z "$identity_text_hits" ]] || fail "local identity name found in release resources: $(printf '%s' "$identity_text_hits" | head -1)"
[[ -z "$identity_binary_hit" ]] || fail "local identity name found in release executable strings: $(printf '%s' "$identity_binary_hit" | head -1)"

echo "  app codesign verify..."
codesign --verify --deep --strict --verbose=2 "$BUNDLE" >/dev/null

echo "  signed Calendar entitlement..."
SIGNED_ENTITLEMENTS="$MOUNT_BASE/nativeagent-signed-entitlements.plist"
codesign -d --entitlements :- "$BUNDLE" > "$SIGNED_ENTITLEMENTS" 2>/dev/null \
  || fail "unable to read signed app entitlements"
calendar_entitlement="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.personal-information.calendars' \
    "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
)"
[[ "$calendar_entitlement" == "true" ]] \
  || fail "signed app is missing the Calendar entitlement required by hardened-runtime TCC"

DEVICE_SYNC="$(plist_value "$INFO" "NativeAgentDeviceSync")"
if [[ "$DEVICE_SYNC" == "cloudkit" ]]; then
  EMBEDDED_PROFILE="$BUNDLE/Contents/embedded.provisionprofile"
  require_file "$EMBEDDED_PROFILE"
  PROFILE_PLIST="$MOUNT_BASE/nativeagent-embedded-profile.plist"
  decode_provisioning_profile "$EMBEDDED_PROFILE" "$PROFILE_PLIST" \
    || fail "unable to decode the embedded public CloudKit provisioning profile"

  EXPECTED_CONTAINER="$(plist_value "$INFO" "NativeAgentICloudContainerID")"
  [[ -n "$EXPECTED_CONTAINER" ]] \
    || fail "CloudKit release is missing NativeAgentICloudContainerID"
  SIGNATURE_TEAM="$(
    codesign -dvv "$BUNDLE" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2; exit}'
  )"
  [[ -n "$SIGNATURE_TEAM" ]] \
    || fail "CloudKit release signature has no TeamIdentifier"
  verify_public_cloudkit_profile_contract \
    "$PROFILE_PLIST" \
    "$SIGNATURE_TEAM" \
    "$EXPECTED_MAC_BUNDLE_ID" \
    "$EXPECTED_CONTAINER" \
    || fail "embedded public CloudKit profile does not match the signed release identity"

  signed_aps="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.aps-environment' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_environment="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.icloud-container-environment' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_application_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.application-identifier' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  signed_team_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.developer.team-identifier' \
      "$SIGNED_ENTITLEMENTS" 2>/dev/null || true
  )"
  [[ "$signed_application_identifier" == "$SIGNATURE_TEAM.$EXPECTED_MAC_BUNDLE_ID" ]] \
    || fail "signed CloudKit app application identifier '$signed_application_identifier' does not match '$SIGNATURE_TEAM.$EXPECTED_MAC_BUNDLE_ID'"
  [[ "$signed_team_identifier" == "$SIGNATURE_TEAM" ]] \
    || fail "signed CloudKit app team entitlement '$signed_team_identifier' does not match signature team '$SIGNATURE_TEAM'"
  [[ "$signed_aps" == "production" && "$signed_environment" == "Production" ]] \
    || fail "signed CloudKit release does not use production APNS and CloudKit environments"
  provisioning_profile_array_contains \
    "$SIGNED_ENTITLEMENTS" \
    "com.apple.developer.icloud-container-identifiers" \
    "$EXPECTED_CONTAINER" \
    || fail "signed app does not declare the exact CloudKit container '$EXPECTED_CONTAINER'"
  echo "  signed entitlements and embedded profile match team, app, container, and production environments..."
fi

python_artifact_hits="$(release_find_checked "python-artifact" "$RESOURCES" \
  \( -type d \( -name python -o -name __pycache__ -o -name daemon \) \
     -o -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*python*' -o -name 'native_agentd.py' \) \
     -o -type l \( -name '*python*' -o -name 'native_agentd.py' \) \) \
  -print)" \
  || fail "python-artifact scan of $RESOURCES did not run correctly"
[[ -z "$python_artifact_hits" ]] || fail "Python artifact shipped in release bundle: $(first_line "$python_artifact_hits")"

echo "  public first-run guard marker strings..."
MARKER_STRINGS="$MOUNT_BASE/nativeagent-executable.strings"
strings "$EXECUTABLE" > "$MARKER_STRINGS"
grep -q 'public_release_data_root.json' "$MARKER_STRINGS" || fail "app binary missing public release data marker string"
grep -q 'NativeAgent.pre-public-backup.' "$MARKER_STRINGS" || fail "app binary missing pre-public backup marker string"

if [[ "$REQUIRE_NOTARIZED" == "true" ]]; then
  echo "  app notarization/staple validation..."
  xcrun stapler validate "$BUNDLE" >/dev/null
  spctl -a -vvv -t execute "$BUNDLE" >/dev/null
  if [[ -z "$BUNDLE_PATH" && "$REQUIRE_DMG_SIGNATURE" == "true" ]]; then
    echo "  DMG notarization/staple validation..."
    xcrun stapler validate "$DMG_PATH" >/dev/null
    spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH" >/dev/null
  fi
fi

if [[ -n "$BUNDLE_PATH" ]]; then
  echo "==> Release bundle verification passed: $BUNDLE_PATH"
else
  echo "==> Release artifact verification passed: $DMG_PATH"
fi
