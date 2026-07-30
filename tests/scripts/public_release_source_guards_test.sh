#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$ROOT/script/check_public_release_source.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-public-source-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_failure() {
  local name="$1" expected="$2" fixture="$3"
  local output
  if output="$("$GUARD" "$fixture" 2>&1)"; then
    fail "$name unexpectedly succeeded"
  fi
  grep -Fq "$expected" <<<"$output" \
    || fail "$name did not report '$expected': $output"
  echo "PASS: $name"
}

fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
printf 'fixture\n' > "$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.com \
  commit -q -m fixture

expect_failure "missing marker" "requires the scrubbed export marker" "$fixture"

printf '%s\n' "nativeagent-public-source-v1" > "$fixture/.nativeagent-public-source"
expect_failure "untracked marker" "must be tracked by the release commit" "$fixture"

git -C "$fixture" add .nativeagent-public-source
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.com \
  commit -q -m marker
"$GUARD" "$fixture" >/dev/null
echo "PASS: exact tracked marker"

printf '%s\n' "wrong-version" > "$fixture/.nativeagent-public-source"
expect_failure "invalid marker" "invalid content" "$fixture"

echo "All public release source guard tests passed."
