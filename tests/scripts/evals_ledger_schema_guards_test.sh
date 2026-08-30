#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/evals-ledger-schema.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
MERGER="$TMP/evals-ledger-merge"
swiftc "$ROOT/script/evals_ledger_merge.swift" -o "$MERGER"
expect_rejected() {
  local name="$1" message="$2"
  set +e
  "$MERGER" "$TMP/$name.json" \
    --out "$TMP/$name-out" > "$TMP/$name.log" 2>&1
  local rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "$name was accepted"
  rg -q "$message" "$TMP/$name.log" || fail "$name lacked diagnostic: $message"
}

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":"fixture","uncertain":[],"surfaces":[{"id":"surface.one","kind":"public-api","where":"Sources/One.swift:1","coverage":[]}]},"critic":{"missed":[],"disputed":[{"why":"missing identity"}]}}]' \
  > "$TMP/dispute-missing-id.json"
expect_rejected dispute-missing-id 'critic.disputed\[0\] has no id'

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":"fixture","uncertain":[],"surfaces":[]},"critic":{"missed":[],"disputed":[{"id":"surface.one","why":"first"},{"id":"surface.one","why":"second"}]}}]' \
  > "$TMP/dispute-duplicate.json"
expect_rejected dispute-duplicate 'duplicate dispute for core.fixture.surface.one'

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":"fixture","uncertain":[],"surfaces":[]},"critic":{"missed":[],"disputed":[{"id":"surface.one","why":""}]}}]' \
  > "$TMP/dispute-empty-reason.json"
expect_rejected dispute-empty-reason 'disputed reason must be a non-empty string'

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":"fixture","uncertain":"not-an-array","surfaces":[]},"critic":{"missed":[],"disputed":[]}}]' \
  > "$TMP/uncertain-wrong-type.json"
expect_rejected uncertain-wrong-type 'fragment.uncertain must be an array'

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":null,"uncertain":[],"surfaces":[]},"critic":{"missed":[],"disputed":[]}}]' \
  > "$TMP/ran-run-wrong-type.json"
expect_rejected ran-run-wrong-type 'fragment.ranRun must be a non-empty string'

echo "evals_ledger_schema_guards_test.sh: all assertions passed"
