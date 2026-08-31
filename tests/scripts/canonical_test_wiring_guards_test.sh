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

mkdir -p "$FIXTURE/script/tests" "$FIXTURE/Extensions/NativeAgentChrome/tests"
printf '#!/usr/bin/env bash\n' > "$FIXTURE/script/tests/release.test.sh"
printf 'fixture\n' > "$FIXTURE/script/tests/bridge.test.js"
printf 'fixture\n' > "$FIXTURE/Extensions/NativeAgentChrome/tests/browser.test.js"
if "$CHECKER" "$FIXTURE" "$FIXTURE/script/test.sh" >"$FIXTURE/missing-families.log" 2>&1; then
  fail "auxiliary shell and Chrome/bridge Node suites were silently omitted"
fi
grep -q 'orphaned script suite: script/tests/release.test.sh' "$FIXTURE/missing-families.log"
grep -Fq 'orphaned Node suite family: script/tests/*.test.js' "$FIXTURE/missing-families.log"
grep -Fq 'orphaned Node suite family: Extensions/NativeAgentChrome/tests/*.test.js' "$FIXTURE/missing-families.log"

cat >> "$FIXTURE/script/test.sh" <<'RUNNER'
bash "$ROOT/script/tests/release.test.sh"
for suite in "$ROOT"/script/tests/*.test.js; do
  node --test "$suite"
done
for suite in "$ROOT"/Extensions/NativeAgentChrome/tests/*.test.js; do
  echo "$suite"
done
RUNNER
if "$CHECKER" "$FIXTURE" "$FIXTURE/script/test.sh" >"$FIXTURE/echo-loop.log" 2>&1; then
  fail "a Chrome loop that only prints paths was accepted as executed coverage"
fi
grep -Fq 'orphaned Node suite family: Extensions/NativeAgentChrome/tests/*.test.js' "$FIXTURE/echo-loop.log"
sed 's/  echo "\$suite"/  node --test "$suite"/' "$FIXTURE/script/test.sh" > "$FIXTURE/script/complete.sh"
"$CHECKER" "$FIXTURE" "$FIXTURE/script/complete.sh" >/dev/null \
  || fail "complete shell, bridge, and Chrome wiring was rejected"

"$CHECKER" "$ROOT" "$ROOT/script/test.sh" >/dev/null \
  || fail "the real canonical runner has orphaned suites"
echo "PASS: canonical shell, bridge, and Chrome suite wiring rejects comments, omissions, and nonexecuting loops"
