#!/usr/bin/env bash
# Focused executable fixtures for the live ToolExecution inventory boundary.
# The report must never collapse absent, unreadable, empty, and split-brain
# tool state into the same harmless-looking zero.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/script/agent_instrument.swift"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tool-execution-inventory.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TOOL_BIN="$TMP/agent-instrument"
swiftc "$TOOL" -o "$TOOL_BIN"

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

run_case() {
  local name="$1"
  local root="$TMP/$name"
  # The instrument rightly rejects a completely empty root as a vacuous reach
  # walk. A single unrelated trace source makes these tool-lane fixtures valid
  # while leaving the registry/artifact state under test untouched.
  mkdir -p "$root/traces"
  printf '%s\n' '{"kind":"llm.call","createdAt":"2026-08-24T12:00:00Z","payload":{"surface":"chat","model":"fixture"}}' \
    > "$root/traces/events.jsonl"
  "$TOOL_BIN" --data-root "$root" --days 1 --no-bridge-config --no-machine-state \
    --now 2026-08-24T12:00:00Z --out "$TMP/$name.md" >/dev/null
}

sys_tool_row() {
  awk '/^\| SYS-10 \|/{ print; exit }' "$1"
}

echo "==> ToolExecution inventory states"

# ABSENT: neither registry nor artifact roots exist. This is not an empty,
# successfully-read registry.
mkdir -p "$TMP/absent"
run_case absent
check "absent registry/directories render as source absent" \
  grep -q '\*\*source absent\*\* — `tools/registry.json`' "$TMP/absent.md"
check "absent active directory is named absent rather than empty" \
  grep -q '`tools/active/`: \*\*absent\*\*' "$TMP/absent.md"

# EMPTY: all canonical roots exist and the canonical array reads, but no tool
# artifacts have ever been materialized.
mkdir -p "$TMP/empty/tools/active" "$TMP/empty/tools/proposals" "$TMP/empty/tools/quarantine"
printf '[]\n' > "$TMP/empty/tools/registry.json"
run_case empty
check "empty canonical registry is named EMPTY" \
  grep -q 'registry: \*\*EMPTY\*\*, \*\*0\*\* row(s)' "$TMP/empty.md"
check "empty active directory is distinct from absent" \
  grep -q '`tools/active/`: \*\*0\*\* opaque artifact entries' "$TMP/empty.md"

# UNREADABLE: a syntactically valid JSON object is still invalid registry
# shape. It must fail closed rather than being counted as one empty-ish row.
mkdir -p "$TMP/invalid/tools"
printf '{}\n' > "$TMP/invalid/tools/registry.json"
run_case invalid
check "invalid registry top-level is never treated as empty" \
  grep -q '\*\*source unreadable\*\* — `tools/registry.json`' "$TMP/invalid.md"
check "invalid registry makes SYS-10 unreadable" \
  rg -q '^\| SYS-10 \|.*\*\*UNREADABLE\*\*' "$TMP/invalid.md"

# DIVERGENCE: both directions are visible. A real active artifact not in the
# registry is just as dangerous as a registry pointer with no active artifact.
mkdir -p "$TMP/divergence/tools/active/active-only" "$TMP/divergence/tools/proposals" "$TMP/divergence/tools/quarantine"
TZ=UTC touch -t 202608241200 "$TMP/divergence/tools/active/active-only"
printf '[{"id":"registry-only"}]\n' > "$TMP/divergence/tools/registry.json"
run_case divergence
check "registry-only ID is named" \
  grep -qF '**registry rows without `active/` artifact:** `registry-only`' "$TMP/divergence.md"
check "active-only ID is named" \
  grep -qF '**`active/` artifacts without registry row:** `active-only`' "$TMP/divergence.md"
check "dated active artifact reports its exact sampled age" \
  grep -qF 'newest 2026-08-24 12:00:00Z (0.0d)' "$TMP/divergence.md"
check "divergence is severe even though trace/audit sources are partial" \
  rg -q '^\| SYS-10 \|.*\*\*FAILING\*\*' "$TMP/divergence.md"

# A regular file under active/ is malformed. The state must be UNREADABLE even
# when the rest of SYS-10 is partial; this pins the required directory-only
# invariant rather than merely counting that file as a tool.
mkdir -p "$TMP/non-directory/tools/active" "$TMP/non-directory/tools/proposals" "$TMP/non-directory/tools/quarantine"
printf '[{"id":"valid"}]\n' > "$TMP/non-directory/tools/registry.json"
printf 'not a directory\n' > "$TMP/non-directory/tools/active/not-a-tool"
run_case non-directory
check "regular active entry is called invalid" \
  grep -qF '**invalid non-directory entries:** `not-a-tool`' "$TMP/non-directory.md"
check "regular active entry makes SYS-10 unreadable even when partial" \
  rg -q '^\| SYS-10 \|.*\*\*UNREADABLE\*\*' "$TMP/non-directory.md"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
echo "tool_execution_inventory_test.sh: all assertions passed"
