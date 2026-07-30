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
expect_failure \
  "missing tracked MiniLM resources" \
  "public release requires tracked MiniLM resource" \
  "$fixture"

resource_root="$fixture/Modules/NativeAgentCore/Sources/MemoryV2/Resources"
mkdir -p "$resource_root/minilm.mlpackage/Data/com.apple.CoreML/weights"
printf 'vocab\n' > "$resource_root/minilm_vocab.txt"
printf '{}\n' > "$resource_root/minilm.mlpackage/Manifest.json"
printf 'model\n' > "$resource_root/minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel"
printf 'weights\n' > "$resource_root/minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
git -C "$fixture" add -f Modules/NativeAgentCore/Sources/MemoryV2/Resources
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.com \
  commit -q -m resources
"$GUARD" "$fixture" >/dev/null
echo "PASS: exact tracked marker and MiniLM resources"

git -C "$fixture" rm -q --cached \
  Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel
expect_failure \
  "present but untracked MiniLM resource" \
  "public release requires tracked MiniLM resource" \
  "$fixture"
git -C "$fixture" add -f \
  Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel

printf '%s\n' "wrong-version" > "$fixture/.nativeagent-public-source"
expect_failure "invalid marker" "invalid content" "$fixture"

echo "All public release source guard tests passed."
