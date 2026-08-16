#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_REPRODUCIBLE="${NATIVE_AGENT_REQUIRE_IOS_PROJECT_REPRODUCIBLE:-0}"

usage() { echo "usage: $0 [--root REPO] [--require-reproducible]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || usage
      ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --require-reproducible)
      REQUIRE_REPRODUCIBLE=1
      shift
      ;;
    *) usage ;;
  esac
done

IOS_ROOT="$ROOT/iOS/NativeAgentMobile"
IOS_TESTS="$IOS_ROOT/Tests"
IOS_SOURCES="$IOS_ROOT/Sources"
IOS_RESOURCES="$IOS_ROOT/Resources"
PBXPROJ="$IOS_ROOT/NativeAgentMobile.xcodeproj/project.pbxproj"
SCHEME="$IOS_ROOT/NativeAgentMobile.xcodeproj/xcshareddata/xcschemes/NativeAgentMobile.xcscheme"

[[ -d "$IOS_TESTS" ]] || { echo "[test-inventory] missing iOS test directory: $IOS_TESTS" >&2; exit 1; }
[[ -d "$IOS_SOURCES" ]] || { echo "[test-inventory] missing iOS source directory: $IOS_SOURCES" >&2; exit 1; }
[[ -d "$IOS_RESOURCES" ]] || { echo "[test-inventory] missing iOS resource directory: $IOS_RESOURCES" >&2; exit 1; }
[[ -f "$PBXPROJ" ]] || { echo "[test-inventory] missing iOS project: $PBXPROJ" >&2; exit 1; }
[[ -f "$SCHEME" ]] || { echo "[test-inventory] missing shared iOS scheme: $SCHEME" >&2; exit 1; }

phase_id() {
  local target="$1" label="$2"
  awk -v target="$target" -v label="$label" '
    $0 ~ "^[[:space:]]*[A-F0-9]+ /\\* " target " \\*/ = \\{$" { in_target = 1; next }
    in_target && $0 ~ "/\\* " label " \\*/" { print $1; exit }
    in_target && /^[[:space:]]*};$/ { in_target = 0 }
  ' "$PBXPROJ"
}

phase_body() {
  local phase="$1" label="$2"
  awk -v phase="$phase" -v label="$label" '
    $1 == phase && $0 ~ "/\\* " label " \\*/ = \\{$" { in_phase = 1 }
    in_phase { print }
    in_phase && /^[[:space:]]*};$/ { exit }
  ' "$PBXPROJ"
}

TEST_SOURCES_PHASE_ID="$(phase_id NativeAgentMobileTests Sources)"
APP_SOURCES_PHASE_ID="$(phase_id NativeAgentMobile Sources)"
APP_RESOURCES_PHASE_ID="$(phase_id NativeAgentMobile Resources)"
[[ -n "$TEST_SOURCES_PHASE_ID" ]] || { echo "[test-inventory] NativeAgentMobileTests has no Sources phase" >&2; exit 1; }
[[ -n "$APP_SOURCES_PHASE_ID" ]] || { echo "[test-inventory] NativeAgentMobile has no Sources phase" >&2; exit 1; }
[[ -n "$APP_RESOURCES_PHASE_ID" ]] || { echo "[test-inventory] NativeAgentMobile has no Resources phase" >&2; exit 1; }

TEST_SOURCES_PHASE="$(phase_body "$TEST_SOURCES_PHASE_ID" Sources)"
APP_SOURCES_PHASE="$(phase_body "$APP_SOURCES_PHASE_ID" Sources)"
APP_RESOURCES_PHASE="$(phase_body "$APP_RESOURCES_PHASE_ID" Resources)"
[[ -n "$TEST_SOURCES_PHASE" && -n "$APP_SOURCES_PHASE" && -n "$APP_RESOURCES_PHASE" ]] \
  || { echo "[test-inventory] could not resolve canonical iOS build phases" >&2; exit 1; }

failures=0
while IFS= read -r test_file; do
  name="$(basename "$test_file")"
  if ! grep -Fq "/* $name in Sources */" <<<"$TEST_SOURCES_PHASE"; then
    echo "[test-inventory] orphaned iOS test: $name" >&2
    failures=$((failures + 1))
  fi
done < <(find "$IOS_TESTS" -type f -name '*Tests.swift' | sort)

while IFS= read -r source_file; do
  name="$(basename "$source_file")"
  if ! grep -Fq "/* $name in Sources */" <<<"$APP_SOURCES_PHASE"; then
    echo "[test-inventory] orphaned iOS production source: $name" >&2
    failures=$((failures + 1))
  fi
done < <(find "$IOS_SOURCES" -type f -name '*.swift' | sort)

# Xcodegen treats each top-level resource path as one build-phase member; an
# asset catalog's nested Contents.json files belong to that catalog, not as
# independent PBX resources.
while IFS= read -r resource; do
  name="$(basename "$resource")"
  if ! grep -Fq "/* $name in Resources */" <<<"$APP_RESOURCES_PHASE"; then
    echo "[test-inventory] orphaned iOS resource: $name" >&2
    failures=$((failures + 1))
  fi
done < <(
  find "$IOS_RESOURCES" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type d ! -name '*.lproj' \) -print
  find "$IOS_RESOURCES" -mindepth 2 -maxdepth 2 -path '*.lproj/*' -type f -print
  )

BUILD_ACTION="$(awk '/^[[:space:]]*<BuildAction$/{inside=1} inside{print} /<\/BuildAction>/{exit}' "$SCHEME")"
TEST_ACTION="$(awk '/^[[:space:]]*<TestAction$/{inside=1} inside{print} /<\/TestAction>/{exit}' "$SCHEME")"
if ! grep -Fq 'BlueprintName = "NativeAgentMobileTests"' <<<"$BUILD_ACTION"; then
  echo "[test-inventory] NativeAgentMobileTests is missing from the shared scheme BuildAction" >&2
  failures=$((failures + 1))
fi
if ! grep -Fq 'BlueprintName = "NativeAgentMobileTests"' <<<"$TEST_ACTION"; then
  echo "[test-inventory] NativeAgentMobileTests is missing from the shared scheme TestAction" >&2
  failures=$((failures + 1))
fi

[[ "$failures" -eq 0 ]] \
  || { echo "[test-inventory] FAIL: $failures iOS project inventory error(s)" >&2; exit 1; }

if [[ "$REQUIRE_REPRODUCIBLE" == "1" ]]; then
  command -v xcodegen >/dev/null 2>&1 \
    || { echo "[test-inventory] release proof requires xcodegen" >&2; exit 1; }
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-ios-project.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/iOS/NativeAgentMobile" "$TMP/Modules"
  cp -R "$IOS_ROOT/Config" "$IOS_ROOT/Sources" "$IOS_ROOT/Resources" \
    "$IOS_ROOT/Tests" "$IOS_ROOT/project.yml" "$TMP/iOS/NativeAgentMobile/"
  mkdir -p "$TMP/Modules/NativeAgentShared"
  cp -R "$ROOT/Modules/NativeAgentShared/Package.swift" \
    "$ROOT/Modules/NativeAgentShared/Sources" "$TMP/Modules/NativeAgentShared/"
  xcodegen --quiet \
    --spec "$TMP/iOS/NativeAgentMobile/project.yml" \
    --project "$TMP/iOS/NativeAgentMobile" \
    --project-root "$TMP/iOS/NativeAgentMobile"
  cmp -s "$PBXPROJ" "$TMP/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj/project.pbxproj" \
    || { echo "[test-inventory] checked-in pbxproj differs from project.yml regeneration" >&2; exit 1; }
  cmp -s "$SCHEME" "$TMP/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj/xcshareddata/xcschemes/NativeAgentMobile.xcscheme" \
    || { echo "[test-inventory] checked-in shared scheme differs from project.yml regeneration" >&2; exit 1; }
  trap - EXIT
  rm -rf "$TMP"
  echo "[test-inventory] project.yml reproduces the checked-in project and scheme"
fi

echo "[test-inventory] iOS tests, production sources, resources, and shared scheme are wired"
