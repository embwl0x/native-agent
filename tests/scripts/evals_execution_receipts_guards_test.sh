#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/eval-execution-receipts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/script" "$TMP/bin" "$TMP/runs"
cp "$ROOT/script/evals.sh" "$TMP/repo/script/evals.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/repo/script/smoke_all.sh"
cat > "$TMP/bin/swift" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == test ]]; then
  cat "$TEST_RECEIPT"
  exit "${TEST_EXIT:-0}"
fi
exit 0
STUB
cat > "$TMP/repo/script/test_ios.sh" <<'STUB'
#!/usr/bin/env bash
echo '[test-ios] passed: 2 passed, 1 skipped, 0 expected failures, 3 discovered'
STUB
chmod +x "$TMP/bin/swift" "$TMP/repo/script/smoke_all.sh" "$TMP/repo/script/test_ios.sh"
run_case() {
  local name="$1" expected="$2" receipt="$3" command_exit="${4:-0}" rc=0
  printf '%s\n' "$receipt" > "$TMP/receipt.txt"
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/runs" TEST_RECEIPT="$TMP/receipt.txt" TEST_EXIT="$command_exit" \
    bash "$TMP/repo/script/evals.sh" --ios > "$TMP/$name.log" 2>&1 || rc=$?
  if [[ "$expected" == pass ]]; then
    [[ "$rc" == 0 ]] && grep -q '✔ turn-replay' "$TMP/$name.log" && grep -q '✔ ios-simulator' "$TMP/$name.log" \
      || { echo "FAIL: $name was not accepted with executed-test proof" >&2; exit 1; }
  else
    [[ "$rc" != 0 ]] && ! grep -q '✔ turn-replay' "$TMP/$name.log" \
      || { echo "FAIL: $name was accepted without executed-test proof" >&2; exit 1; }
  fi
}
run_case xctest pass 'Executed 3 tests, with 0 failures (0 unexpected) in 0.01 seconds'
run_case xctest-partial-skip pass 'Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.01 seconds'
run_case swift-testing pass '✔ Test run with 3 tests passed after 0.01 seconds.'
run_case swift-testing-suites pass '✔ Test run with 3 tests in 2 suites passed after 0.01 seconds.'
run_case zero fail 'Test run with 0 tests passed'
run_case discovery-chatter fail $'Discovered 3 tests\nTest run with 0 tests passed'
run_case build-chatter fail $'Compiling 3 tests\nExecuted 0 tests, with 0 failures'
run_case malformed-summary fail 'Executed 3 tests, with 0 receipts'
run_case all-skipped fail 'Executed 3 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.01 seconds'
run_case failed-summary fail 'Executed 3 tests, with 1 failure (1 unexpected) in 0.01 seconds'
run_case contradictory-summaries fail $'Executed 2 tests, with 0 failures\nExecuted 3 tests, with 1 failure'
run_case command-failure fail 'Test run with 3 tests passed' 65
run_case timeout fail 'Test run with 3 tests passed' 124

# Full-mode failures must retain their completed evidence without installing
# the failed candidate. Exercise the real orchestration, replacing only costly
# child commands; the successful path still installs and verifies exactly once.
cat > "$TMP/repo/script/smoke_all.sh" <<'STUB'
#!/usr/bin/env bash
echo 'fixture smoke evidence'
exit "${FULL_SMOKE_EXIT:-0}"
STUB
cat > "$TMP/repo/script/test.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == --require-ios ]] || exit 93
echo 'fixture canonical evidence'
exit "${FULL_CANONICAL_EXIT:-0}"
STUB
cat > "$TMP/repo/script/install_app.sh" <<'STUB'
#!/usr/bin/env bash
echo install >> "$FULL_INSTALL_CALLS"
STUB
cat > "$TMP/repo/script/verify_installed_runtime_ready.sh" <<'STUB'
#!/usr/bin/env bash
echo verify >> "$FULL_INSTALL_CALLS"
if [[ -n "${FULL_MUTATE_EXTENSION:-}" ]]; then
  printf 'changed extension source\n' >> "$FULL_MUTATE_EXTENSION"
fi
STUB
chmod +x "$TMP/repo/script/"*.sh
git -C "$TMP/repo" init -q
git -C "$TMP/repo" add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm baseline
run_full_case() {
  local name="$1" smoke_exit="$2" canonical_exit="$3" expected_exit="$4" rc=0 out
  : > "$TMP/install.calls"
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/runs" FULL_INSTALL_CALLS="$TMP/install.calls" \
    FULL_SMOKE_EXIT="$smoke_exit" FULL_CANONICAL_EXIT="$canonical_exit" \
    bash "$TMP/repo/script/evals.sh" --full > "$TMP/$name.log" 2>&1 || rc=$?
  [[ "$rc" == "$expected_exit" ]] \
    || { echo "FAIL: $name changed the prerequisite failure exit ($rc != $expected_exit)" >&2; exit 1; }
  out="$(sed -n 's/.*(logs: \(.*\)).*/\1/p' "$TMP/$name.log")"
  grep -q 'fixture smoke evidence' "$out/smoke.log"
  grep -q 'fixture canonical evidence' "$out/full-swift-suite.log"
  if [[ "$expected_exit" == 0 ]]; then
    [[ "$(cat "$TMP/install.calls")" == $'install\nverify' ]] \
      || { echo "FAIL: $name did not install and verify exactly once" >&2; exit 1; }
    [[ -f "$out/full-install-ready" ]]
    grep -q '✔ full-install-verified' "$TMP/$name.log"
  else
    [[ ! -s "$TMP/install.calls" && ! -e "$out/full-install-ready" ]] \
      || { echo "FAIL: $name installed a candidate after failed prerequisites" >&2; exit 1; }
    grep -q 'BLOCKED by failed prerequisites' "$TMP/$name.log"
    grep -q 'BLOCKED: install requires' "$out/full-install-verified.log"
    ! grep -q '✔ full-install-verified' "$TMP/$name.log"
  fi
}
run_full_case full-pass 0 0 0
run_full_case full-smoke-failed 7 0 1
run_full_case full-canonical-failed 0 65 1
run_full_case full-canonical-interrupted 0 143 1
run_full_case full-both-failed 7 65 2

# Chrome participates in the canonical gate, so a full-mode source receipt
# must bind its source too, including edits after its Node tests completed.
mkdir -p "$TMP/repo/Extensions/NativeAgentChrome"
extension="$TMP/repo/Extensions/NativeAgentChrome/background.js"
printf 'fixture extension source\n' > "$extension"
rc=0
PATH="$TMP/bin:$PATH" TMPDIR="$TMP/runs" FULL_INSTALL_CALLS="$TMP/install.calls" \
  FULL_MUTATE_EXTENSION="$extension" \
  bash "$TMP/repo/script/evals.sh" --full > "$TMP/full-extension-drift.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'source changed during gate' "$TMP/full-extension-drift.log" \
  || { echo 'FAIL: full-mode receipt accepted extension source drift' >&2; exit 1; }
echo 'evals_execution_receipts_guards_test.sh: all assertions passed'
