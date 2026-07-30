#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$ROOT/script/verify_release_artifact.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-derived-context-guards.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

clean_root="$TMP_ROOT/clean"
mkdir -p "$clean_root/Modules/NativeAgentCore/Sources/Context"
touch "$clean_root/Modules/NativeAgentCore/Sources/Context/ContextArena.swift"
touch "$clean_root/Modules/NativeAgentCore/Sources/Context/ContextFlowCoordinator.swift"
expect_success \
  "Context source filenames are not derived state" \
  "$VERIFIER" --verify-no-derived-context-state "$clean_root"

assert_rejected_path() {
  local name="$1" relative_path="$2"
  local fixture="$TMP_ROOT/$name"
  mkdir -p "$fixture/$(dirname "$relative_path")"
  touch "$fixture/$relative_path"
  expect_failure \
    "$name" \
    "derived ContextFlow state found" \
    "$VERIFIER" --verify-no-derived-context-state "$fixture"
}

assert_rejected_path "canonical database" "data/context/context.sqlite"
assert_rejected_path "misplaced database" "staged/context.sqlite"
assert_rejected_path "SQLite WAL sidecar" "staged/context.sqlite-wal"
assert_rejected_path "SQLite SHM sidecar" "staged/context.sqlite-shm"
assert_rejected_path "SQLite rollback journal" "staged/context.sqlite-journal"
assert_rejected_path "misplaced receipts" "cache/context_receipts.jsonl"
assert_rejected_path "local registrations" "cache/context/registrations.json"
assert_rejected_path "arena snapshot" "cache/context/arena_snapshot.json"
assert_rejected_path "generated diagnostics" "cache/context/diagnostics/health.json"
assert_rejected_path "derived context namespace" "assets/derived-context/generation.json"

echo "All release derived ContextFlow guard tests passed."
