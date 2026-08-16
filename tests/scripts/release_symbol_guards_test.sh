#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../script/lib/release_symbols.sh
source "$ROOT/script/lib/release_symbols.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-symbols.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<'SWIFT'
private func localReleaseFixture(_ value: Int) -> Int { value + 1 }
print(localReleaseFixture(41))
SWIFT
xcrun swiftc -g -c "$TMP/main.swift" -o "$TMP/main.o"
xcrun swiftc -g "$TMP/main.o" -o "$TMP/FixtureApp"
chmod +x "$TMP/FixtureApp"
before="$(stat -f %z "$TMP/FixtureApp")"

if release_assert_executable_stripped "$TMP/FixtureApp" >/dev/null 2>&1; then
  echo "FAIL: unstripped fixture was accepted" >&2
  exit 1
fi
release_archive_symbols_and_strip "$TMP/FixtureApp" "$TMP/symbols" "FixtureApp" >/dev/null
release_assert_executable_stripped "$TMP/FixtureApp"
after="$(stat -f %z "$TMP/FixtureApp")"
[[ "$after" -lt "$before" ]] || { echo "FAIL: fixture did not shrink" >&2; exit 1; }
[[ -s "$TMP/symbols/FixtureApp.dSYM/Contents/Resources/DWARF/FixtureApp" ]] || {
  echo "FAIL: matching dSYM was not archived" >&2
  exit 1
}
[[ -s "$TMP/symbols/FixtureApp.dSYM.sha256" && -s "$TMP/symbols/FixtureApp.uuid" ]] || {
  echo "FAIL: symbol archive proof files are missing" >&2
  exit 1
}
[[ "$(release_executable_uuids "$TMP/FixtureApp")" == "$(release_executable_uuids "$TMP/symbols/FixtureApp.dSYM/Contents/Resources/DWARF/FixtureApp")" ]] || {
  echo "FAIL: stripped fixture and dSYM UUIDs differ" >&2
  exit 1
}

grep -Fq 'release_archive_symbols_and_strip' "$ROOT/script/release.sh" || {
  echo "FAIL: canonical release does not archive and strip" >&2
  exit 1
}
# Match the literal verifier source contract; this is intentionally not expanded.
# shellcheck disable=SC2016
grep -Fq 'release_assert_executable_stripped "$EXECUTABLE"' "$ROOT/script/verify_release_artifact.sh" || {
  echo "FAIL: artifact verifier does not enforce stripping" >&2
  exit 1
}

printf 'ok - release symbol guards\n'
