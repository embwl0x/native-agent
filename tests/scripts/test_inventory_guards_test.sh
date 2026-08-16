#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/script/check_test_inventory.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -x "$CHECKER" ]] || fail "test-inventory checker is missing or not executable"
"$CHECKER"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-test-inventory.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

make_fixture() {
  local name="$1"
  local destination="$FIXTURE/$name"
  local source="$ROOT/iOS/NativeAgentMobile"
  mkdir -p "$destination/iOS/NativeAgentMobile"
  cp -R "$source/Config" "$source/Sources" "$source/Resources" "$source/Tests" \
    "$source/project.yml" "$source/NativeAgentMobile.xcodeproj" \
    "$destination/iOS/NativeAgentMobile/"
  printf '%s' "$destination"
}

TEST_FIXTURE="$(make_fixture orphan-test)"
printf 'import Testing\n' > "$TEST_FIXTURE/iOS/NativeAgentMobile/Tests/OrphanTests.swift"
if "$CHECKER" --root "$TEST_FIXTURE" >"$FIXTURE/orphan-test.log" 2>&1; then
  fail "orphaned iOS test was accepted"
fi
grep -q 'orphaned iOS test: OrphanTests.swift' "$FIXTURE/orphan-test.log" \
  || fail "orphaned test refusal was not explicit"

SOURCE_FIXTURE="$(make_fixture orphan-source)"
printf 'import Foundation\n' > "$SOURCE_FIXTURE/iOS/NativeAgentMobile/Sources/OrphanProduction.swift"
if "$CHECKER" --root "$SOURCE_FIXTURE" >"$FIXTURE/orphan-source.log" 2>&1; then
  fail "orphaned iOS production source was accepted"
fi
grep -q 'orphaned iOS production source: OrphanProduction.swift' "$FIXTURE/orphan-source.log" \
  || fail "orphaned production-source refusal was not explicit"

SCHEME_FIXTURE="$(make_fixture missing-test-action)"
SCHEME="$SCHEME_FIXTURE/iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj/xcshareddata/xcschemes/NativeAgentMobile.xcscheme"
perl -0pi -e 's{(<TestAction\b.*?</TestAction>)}{my $b=$1; $b =~ s/NativeAgentMobileTests/MissingMobileTests/g; $b}gse' "$SCHEME"
if "$CHECKER" --root "$SCHEME_FIXTURE" >"$FIXTURE/missing-test-action.log" 2>&1; then
  fail "shared scheme without NativeAgentMobileTests TestAction was accepted"
fi
grep -q 'missing from the shared scheme TestAction' "$FIXTURE/missing-test-action.log" \
  || fail "shared-scheme refusal was not explicit"

if command -v xcodegen >/dev/null 2>&1; then
  "$CHECKER" --require-reproducible >/dev/null
  DRIFT_FIXTURE="$(make_fixture project-drift)"
  mkdir -p "$DRIFT_FIXTURE/Modules/NativeAgentShared"
  cp -R "$ROOT/Modules/NativeAgentShared/Package.swift" \
    "$ROOT/Modules/NativeAgentShared/Sources" "$DRIFT_FIXTURE/Modules/NativeAgentShared/"
  perl -0pi -e 's/iOS: "17\.0"/iOS: "17.1"/' \
    "$DRIFT_FIXTURE/iOS/NativeAgentMobile/project.yml"
  if "$CHECKER" --root "$DRIFT_FIXTURE" --require-reproducible \
      >"$FIXTURE/project-drift.log" 2>&1; then
    fail "stale checked-in Xcode project was accepted after project.yml changed"
  fi
  grep -Eq 'pbxproj differs|shared scheme differs' "$FIXTURE/project-drift.log" \
    || fail "project.yml drift refusal was not explicit"
fi

echo "PASS: iOS tests, production sources, shared scheme, and release regeneration fail closed on drift"
