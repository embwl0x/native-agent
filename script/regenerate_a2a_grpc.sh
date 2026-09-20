#!/usr/bin/env bash
set -euo pipefail
# Development only. Normal app builds use the checked-in generated Swift.
# Requires protoc 33.4, protoc-gen-swift 1.38.1, and
# protoc-gen-grpc-swift-2 from grpc-swift-protobuf 2.4.1 on PATH.
# To build either generator from its pinned release checkout, use:
# swift build --disable-keychain -c release --product <generator>
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO="$ROOT/script/proto/a2a-v1.0.0"
OUT="$ROOT/Modules/NativeAgentCore/Sources/ChatOrchestration/Generated"
mkdir -p "$OUT"
protoc -I "$PROTO" \
  --swift_out="Visibility=Public:$OUT" \
  --grpc-swift-2_out="Visibility=Public:$OUT" \
  "$PROTO/a2a.proto"
