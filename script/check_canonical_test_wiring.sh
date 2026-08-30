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
for suite in "$ROOT"/tests/scripts/*.sh; do
  name="$(basename "$suite")"
  if ! awk -v needle="tests/scripts/$name" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, needle) == 0) next
      if (line ~ /^bash[[:space:]]+"\$ROOT\/tests\/scripts\// ||
          line ~ /^"\$ROOT\/tests\/scripts\//) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$RUNNER"; then
    echo "[test-wiring] orphaned script suite: tests/scripts/$name" >&2
    failures=$((failures + 1))
  fi
done

[[ "$failures" -eq 0 ]] || exit 1
echo "[test-wiring] every tests/scripts suite has a canonical command invocation"
