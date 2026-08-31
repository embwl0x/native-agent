#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUNNER="${2:-$ROOT/script/test.sh}"

[[ -f "$RUNNER" ]] || {
  echo "[test-wiring] missing canonical runner: $RUNNER" >&2
  exit 1
}
[[ -d "$ROOT/tests/scripts" ]] || {
  echo "[test-wiring] missing script-suite directory: $ROOT/tests/scripts" >&2
  exit 1
}

failures=0
check_direct_suite() {
  local relative="$1"
  if ! awk -v needle="$relative" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      direct = "\"$ROOT/" needle "\""
      if (line == direct || line == "bash " direct) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$RUNNER"; then
    echo "[test-wiring] orphaned script suite: $relative" >&2
    failures=$((failures + 1))
  fi
}
for suite in "$ROOT"/tests/scripts/*.sh "$ROOT"/script/tests/*.test.sh; do
  [[ -f "$suite" ]] || continue
  check_direct_suite "${suite#"$ROOT"/}"
done

# These mock-only Node families are production regression coverage, not live
# browser/provider checks. Require both the directory glob and its execution;
# merely mentioning a directory (or looping without running it) earns no credit.
for directory in script/tests Extensions/NativeAgentChrome/tests; do
  [[ -d "$ROOT/$directory" ]] || continue
  if ! awk -v directory="$directory" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      if (line == "for suite in \"$ROOT\"/" directory "/*.test.js; do") armed = 1
      else if (armed && line == "node --test \"$suite\"") found = 1
      else if (line == "done") armed = 0
    }
    END { exit(found ? 0 : 1) }
  ' "$RUNNER"; then
    echo "[test-wiring] orphaned Node suite family: $directory/*.test.js" >&2
    failures=$((failures + 1))
  fi
done

[[ "$failures" -eq 0 ]] || exit 1
echo "[test-wiring] every shell suite and production Node family has a canonical command invocation"
