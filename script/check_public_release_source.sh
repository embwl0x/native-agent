#!/usr/bin/env bash
# Prove that a no-iCloud/public release is being cut from the scrubbed public
# source tree, not from the private working repository.
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
ROOT="$(cd "$ROOT" && pwd -P)"
MARKER="$ROOT/.nativeagent-public-source"
EXPECTED="nativeagent-public-source-v1"

fail() {
  echo "[public-source] REFUSED: $*" >&2
  exit 1
}

[[ -f "$MARKER" && ! -L "$MARKER" ]] \
  || fail "public release requires the scrubbed export marker .nativeagent-public-source"
[[ "$(cat "$MARKER")" == "$EXPECTED" ]] \
  || fail "public export marker has invalid content"
git -C "$ROOT" ls-files --error-unmatch -- ".nativeagent-public-source" >/dev/null 2>&1 \
  || fail "public export marker must be tracked by the release commit"

REQUIRED_TRACKED_RESOURCES=(
  "Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm_vocab.txt"
  "Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm.mlpackage/Manifest.json"
  "Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "Modules/NativeAgentCore/Sources/MemoryV2/Resources/minilm.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
)
for resource in "${REQUIRED_TRACKED_RESOURCES[@]}"; do
  git -C "$ROOT" ls-files --error-unmatch -- "$resource" >/dev/null 2>&1 \
    || fail "public release requires tracked MiniLM resource: $resource"
done

echo "[public-source] verified tracked scrubbed-export marker and MiniLM resources"
