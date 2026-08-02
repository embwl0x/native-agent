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
  hit="$(
    find "$scan_root" -mindepth 1 -print 2>/dev/null \
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
  $'minilm_vocab.txt\t231509\tc181487132822450ea37c30773b02f68a98c26e761ba487a42c7a36231a82453'
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

  symlink_path="$(find "$resource_root" -type l -print -quit 2>/dev/null || true)"
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
  while IFS= read -r candidate; do
    [[ "$candidate" == "$expected_package" || "$candidate" == "$expected_vocab" ]] \
      || fail "MiniLM resource staged outside expected SwiftPM resource bundle: $candidate"
  done < <(find "$contents_resources" \
    \( -name 'minilm.mlpackage' -o -name 'minilm_vocab.txt' \) -print 2>/dev/null)

  echo "[resources] verified staged MiniLM SwiftPM bundle: $expected_bundle"
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
  elif [[ -n "$RESOURCE_BUNDLE_ROOT" ]]; then
    verify_minilm_swiftpm_resources "$RESOURCE_BUNDLE_ROOT"
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

if [[ -z "$BUNDLE_PATH" ]]; then
  [[ -L "$MOUNT_POINT/Applications" ]] || fail "DMG missing /Applications symlink"
  [[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || fail "DMG /Applications symlink points to $(readlink "$MOUNT_POINT/Applications")"
fi

require_plist_value "$INFO" "CFBundleIdentifier" "$EXPECTED_MAC_BUNDLE_ID"
require_plist_value "$INFO" "CFBundleExecutable" "$PRODUCT"
require_plist_value "$INFO" "CFBundleShortVersionString" "$VERSION"
require_plist_value "$INFO" "CFBundleVersion" "$VERSION"
require_plist_value "$INFO" "CFBundlePackageType" "APPL"
require_plist_value "$INFO" "LSMinimumSystemVersion" "14.0"
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
local_state_dir_hit="$(
  find "$RESOURCES" -type d -print 2>/dev/null \
  | awk '{ low=tolower($0); print low "\t" $0 }' \
  | awk -F '\t' -v root="$(printf '%s' "$RESOURCES" | tr '[:upper:]' '[:lower:]')" -v re="$LOCAL_STATE_DIR_RE" '
      index($1, root "/") == 1 {
        rel = substr($1, length(root) + 1)
        if (rel ~ re) { print $2; exit }
      }' \
  || true
)"
[[ -z "$local_state_dir_hit" ]] || fail "live NativeAgent state directory shipped in release resources: $local_state_dir_hit"

bad_world_writable="$(find "$BUNDLE" -perm -002 -print -quit 2>/dev/null || true)"
[[ -z "$bad_world_writable" ]] || fail "world-writable path inside app bundle: $bad_world_writable"

bad_readable="$(find "$BUNDLE" \( -type f ! -perm -004 -o -type d ! -perm -005 \) -print -quit 2>/dev/null || true)"
[[ -z "$bad_readable" ]] || fail "path is not readable/traversable by normal users: $bad_readable"

pycache_hits="$(find "$RESOURCES" -type d -name '__pycache__' -print -quit 2>/dev/null || true)"
[[ -z "$pycache_hits" ]] || fail "Python cache directory shipped in release bundle: $pycache_hits"
bytecode_hits="$(find "$RESOURCES" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit 2>/dev/null || true)"
[[ -z "$bytecode_hits" ]] || fail "Python bytecode shipped in release bundle: $bytecode_hits"
backup_hits="$(find "$RESOURCES" -type f -name '*.bak*' -print -quit 2>/dev/null || true)"
[[ -z "$backup_hits" ]] || fail "backup file shipped in release bundle: $backup_hits"
test_artifact_hits="$(find "$RESOURCES" -type f \( -name '*_tests.py' -o -name 'test_*.py' \) -print -quit 2>/dev/null || true)"
[[ -z "$test_artifact_hits" ]] || fail "test artifact shipped in release bundle: $test_artifact_hits"

# ONBOARDING-2026-05-26: a public release bundle MUST NOT contain a persona
# directory. Earlier revisions shipped *.template.md placeholders here, but
# that caused _resolve_persona_root() step 3 to resolve inside the read-only
# signed .app on public installs, which auto-scaffolded SOUL.md and locked
# users out of the first-run onboarding wizard. The contract is now: no
# persona dir in the bundle; Swift onboarding resolves first-run data under
# the writable data root. Any file under Contents/Resources/persona is a
# regression that must fail the artifact verifier.
[[ ! -e "$RESOURCES/persona" ]] || fail "Contents/Resources/persona must not ship — see release.sh ONBOARDING-2026-05-26"

SECRET_FILE_RE='(^|/)(\.env($|[._-])|.*\.env$|\.npmrc$|\.pypirc$|\.netrc$|id_rsa$|id_dsa$|id_ecdsa$|id_ed25519$|credentials?\.(json|ya?ml|toml|ini)$|.*credentials?\.(json|ya?ml|toml|ini)$|token(s)?\.(json|ya?ml|toml|ini)$|.*token(s)?\.(json|ya?ml|toml|ini)$|oauth.*token.*\.(json|ya?ml|toml|ini)$|client_secret(s)?\.(json|ya?ml|toml|ini)$|.*client_secret.*\.(json|ya?ml|toml|ini)$|service[-_]?account.*\.(json|ya?ml|toml|ini)$|firebase-adminsdk.*\.json$|.*\.(pem|p12|pfx|jks|keystore|key|gpg|asc)$)'
secret_file_hits="$(
  find "$RESOURCES" \
    -type f -print 2>/dev/null \
  | awk '{ low=tolower($0); print low "\t" $0 }' \
  | awk -F '\t' -v re="$SECRET_FILE_RE" '$1 ~ re { print $2; exit }' \
  || true
)"
[[ -z "$secret_file_hits" ]] || fail "secret-bearing filename shipped in release bundle: $secret_file_hits"

PRIVACY_DENYLIST_FILE="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-$ROOT/local/privacy_denylist.regex}"
PERSONAL_RE="${NATIVEAGENT_PRIVACY_RE:-}"
if [[ -f "$PRIVACY_DENYLIST_FILE" ]]; then
  FILE_PRIVACY_RE="$(grep -Ev '^[[:space:]]*(#|$)' "$PRIVACY_DENYLIST_FILE" | paste -sd'|' - || true)"
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
  raw_personal_hits="$(release_personal_identity_hit_files "$BUNDLE" "$PERSONAL_RE")"
fi
for hit in $raw_personal_hits; do
  fail "configured personal identifier found in release artifact: $hit"
done

SECRET_VALUE_RE='(sk-(proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{20,}|[0-9]{7,12}:[A-Za-z0-9_-]{30,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{20,}|AKIA[0-9A-Z]{16}|(sk|rk)_live_[0-9A-Za-z]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,})'
secret_value_hits="$(
  find "$RESOURCES" \
    -type f -print0 2>/dev/null \
  | xargs -0 grep -IlE "$SECRET_VALUE_RE" 2>/dev/null | head -1 || true
)"
[[ -z "$secret_value_hits" ]] || fail "credential-looking value shipped in release resources: $secret_value_hits"

PUBLIC_IDENTITY_RE="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
identity_text_hits=""
if [[ -n "$PUBLIC_IDENTITY_RE" ]]; then
  identity_text_hits="$(
    find "$RESOURCES" \
      \( -path '*/minilm_vocab.txt' -o -path '*/minilm.mlpackage/*' \) -prune -o \
      -type f -print0 2>/dev/null \
    | xargs -0 grep -IlEi "$PUBLIC_IDENTITY_RE" 2>/dev/null | head -1 || true
  )"
fi
[[ -z "$identity_text_hits" ]] || fail "local identity name found in release resources: $identity_text_hits"

identity_binary_hit=""
if [[ -n "$PUBLIC_IDENTITY_RE" ]]; then
  identity_binary_hit="$(strings "$EXECUTABLE" 2>/dev/null | grep -Ei "$PUBLIC_IDENTITY_RE" | head -1 || true)"
fi
[[ -z "$identity_binary_hit" ]] || fail "local identity name found in release executable strings: $identity_binary_hit"

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

python_artifact_hits="$(find "$RESOURCES" \
  \( -type d \( -name python -o -name __pycache__ -o -name daemon \) \
     -o -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' -o -name '*python*' -o -name 'native_agentd.py' \) \
     -o -type l \( -name '*python*' -o -name 'native_agentd.py' \) \) \
  -print -quit 2>/dev/null || true)"
[[ -z "$python_artifact_hits" ]] || fail "Python artifact shipped in release bundle: $python_artifact_hits"

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
