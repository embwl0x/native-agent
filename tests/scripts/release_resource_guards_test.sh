#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/script/verify_release_artifact.sh"
SOURCE_RESOURCES="$ROOT/Modules/NativeAgentCore/Sources/MemoryV2/Resources"
RESOURCE_REL="Modules/NativeAgentCore/Sources/MemoryV2/Resources"
EXPECTED_BUNDLE="NativeAgentCore_MemoryV2.bundle"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-resource-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

clone_tree() {
  local source="$1" destination="$2"
  mkdir -p "$(dirname "$destination")"
  if ! cp -cR "$source" "$destination" 2>/dev/null; then
    rm -rf "$destination"
    cp -R "$source" "$destination"
  fi
}

expect_success() {
  local name="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "FAIL: $name" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_failure() {
  local name="$1" expected="$2"
  shift 2
  local output
  if output="$("$@" 2>&1)"; then
    echo "FAIL: $name unexpectedly succeeded" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "FAIL: $name did not report '$expected'" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_success \
  "complete source resources" \
  "$VERIFIER" --verify-resource-source "$ROOT"

staged_root="$TMP_ROOT/staged"
clone_tree "$SOURCE_RESOURCES" "$staged_root/$EXPECTED_BUNDLE"
expect_success \
  "complete resources in expected SwiftPM bundle" \
  "$VERIFIER" --verify-resource-bundle "$staged_root"

missing_root="$TMP_ROOT/missing"
clone_tree "$SOURCE_RESOURCES" "$missing_root/$RESOURCE_REL"
rm "$missing_root/$RESOURCE_REL/minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel"
expect_failure \
  "missing model resource" \
  "missing required MiniLM resource" \
  "$VERIFIER" --verify-resource-source "$missing_root"

zeroed_root="$TMP_ROOT/zeroed"
clone_tree "$SOURCE_RESOURCES" "$zeroed_root/$RESOURCE_REL"
: > "$zeroed_root/$RESOURCE_REL/minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
expect_failure \
  "zeroed model weights" \
  "wrong-sized MiniLM resource" \
  "$VERIFIER" --verify-resource-source "$zeroed_root"

undersized_root="$TMP_ROOT/undersized"
clone_tree "$SOURCE_RESOURCES" "$undersized_root/$RESOURCE_REL"
truncate -s 44939135 "$undersized_root/$RESOURCE_REL/minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
expect_failure \
  "one-byte-truncated model weights" \
  "wrong-sized MiniLM resource" \
  "$VERIFIER" --verify-resource-source "$undersized_root"

corrupt_root="$TMP_ROOT/corrupt"
clone_tree "$SOURCE_RESOURCES" "$corrupt_root/$RESOURCE_REL"
printf '\000' | dd \
  of="$corrupt_root/$RESOURCE_REL/minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin" \
  bs=1 seek=0 count=1 conv=notrunc status=none
expect_failure \
  "same-size corrupted model weights" \
  "hash-mismatched MiniLM resource" \
  "$VERIFIER" --verify-resource-source "$corrupt_root"

extra_root="$TMP_ROOT/extra"
clone_tree "$SOURCE_RESOURCES" "$extra_root/$RESOURCE_REL"
printf 'unexpected\n' > "$extra_root/$RESOURCE_REL/minilm.mlpackage/Data/unexpected.txt"
expect_failure \
  "extra model resource" \
  "unexpected MiniLM resource path" \
  "$VERIFIER" --verify-resource-source "$extra_root"

misplaced_root="$TMP_ROOT/misplaced"
clone_tree "$SOURCE_RESOURCES" "$misplaced_root/Unexpected_MemoryV2.bundle"
expect_failure \
  "resources outside expected SwiftPM bundle" \
  "missing expected SwiftPM resource bundle" \
  "$VERIFIER" --verify-resource-bundle "$misplaced_root"

duplicate_root="$TMP_ROOT/duplicate"
clone_tree "$SOURCE_RESOURCES" "$duplicate_root/$EXPECTED_BUNDLE"
cp "$SOURCE_RESOURCES/minilm_vocab.txt" "$duplicate_root/minilm_vocab.txt"
expect_failure \
  "duplicate resource outside expected SwiftPM bundle" \
  "staged outside expected SwiftPM resource bundle" \
  "$VERIFIER" --verify-resource-bundle "$duplicate_root"

echo "All release resource guard tests passed."
