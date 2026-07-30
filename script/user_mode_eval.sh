#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.runtime/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT/.runtime/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

swift "$ROOT/script/user_mode_eval.swift" --repo "$ROOT" "$@"
