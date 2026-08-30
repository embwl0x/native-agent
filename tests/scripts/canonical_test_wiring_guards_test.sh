#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/script/check_canonical_test_wiring.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-test-wiring.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$FIXTURE/tests/scripts" "$FIXTURE/script"
printf '#!/usr/bin/env bash\n' > "$FIXTURE/tests/scripts/real_suite.sh"
chmod +x "$FIXTURE/tests/scripts/real_suite.sh"

cat > "$FIXTURE/script/test.sh" <<'RUNNER'
#!/usr/bin/env bash
# "$ROOT/tests/scripts/real_suite.sh" is intentionally only prose.
RUNNER
if "$CHECKER" "$FIXTURE" "$FIXTURE/script/test.sh" >"$FIXTURE/comment.log" 2>&1; then
  fail "a comment-only suite mention was accepted as executable wiring"
fi
grep -q 'orphaned script suite: tests/scripts/real_suite.sh' "$FIXTURE/comment.log" \
  || fail "comment-only refusal did not name the orphaned suite"

cat > "$FIXTURE/script/test.sh" <<'RUNNER'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/tests/scripts/real_suite.sh"
RUNNER
"$CHECKER" "$FIXTURE" "$FIXTURE/script/test.sh" >/dev/null \
  || fail "a direct canonical suite invocation was rejected"

echo "PASS: comments cannot masquerade as canonical script-suite wiring"
