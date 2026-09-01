#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-test-result.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/script" "$TMP/bin"
cp "$ROOT/script/test_ios.sh" "$TMP/repo/script/test_ios.sh"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == simctl ]]; then
  echo '{"devices":{"iOS":[{"name":"iPhone 16","isAvailable":true}]}}'
elif [[ "$1" == xcresulttool ]]; then
  [[ " $* " == *" --path "*"/tests.xcresult "* ]] || exit 91
  cat "$RESULT_SUMMARY"
  exit "${RESULT_TOOL_EXIT:-0}"
else
  exit 92
fi
STUB
cat > "$TMP/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" -resultBundlePath "*"/tests.xcresult "* ]] || exit 93
if [[ -n "${EXPECTED_ONLY_TESTING:-}" ]]; then
  [[ " $* " == *" -only-testing:NativeAgentMobileTests/$EXPECTED_ONLY_TESTING "* ]] || exit 94
fi
exit "${BUILD_EXIT:-0}"
STUB
chmod +x "$TMP/bin/xcrun" "$TMP/bin/xcodebuild"

run_case() {
  local name="$1" expected="$2" summary="$3" build_exit="${4:-0}" tool_exit="${5:-0}" rc=0
  printf '%s\n' "$summary" > "$TMP/summary.json"
  PATH="$TMP/bin:$PATH" RESULT_SUMMARY="$TMP/summary.json" BUILD_EXIT="$build_exit" \
    RESULT_TOOL_EXIT="$tool_exit" NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=0 \
    bash "$TMP/repo/script/test_ios.sh" --require >"$TMP/$name.log" 2>&1 || rc=$?
  if [[ "$expected" == pass ]]; then
    [[ "$rc" == 0 ]] && grep -q '\[test-ios\] passed: 2 passed, 1 skipped' "$TMP/$name.log" \
      || { echo "FAIL: $name did not prove executed tests" >&2; exit 1; }
  else
    [[ "$rc" != 0 ]] && ! grep -q '\[test-ios\] passed' "$TMP/$name.log" \
      || { echo "FAIL: $name was certified without valid test execution" >&2; exit 1; }
  fi
}
valid='{"result":"Passed","totalTestCount":3,"passedTests":2,"failedTests":0,"skippedTests":1,"expectedFailures":0}'
run_case executed pass "$valid"
EXPECTED_ONLY_TESTING=FocusedIOSFixtureTests RESULT_SUMMARY="$TMP/summary.json" \
  BUILD_EXIT=0 RESULT_TOOL_EXIT=0 NATIVE_AGENT_SWIFTPM_DISABLE_SANDBOX=0 PATH="$TMP/bin:$PATH" \
  bash "$TMP/repo/script/test_ios.sh" --require --only-testing FocusedIOSFixtureTests \
  > "$TMP/only-testing.log" 2>&1 \
  || { echo "FAIL: focused iOS selector did not reach xcodebuild" >&2; exit 1; }
grep -q '\[test-ios\] passed: 2 passed, 1 skipped' "$TMP/only-testing.log" \
  || { echo "FAIL: focused iOS selector did not retain execution proof" >&2; exit 1; }
run_case command-failure fail "$valid" 65
run_case timeout fail "$valid" 124
run_case unreadable-result fail "$valid" 0 1
run_case malformed-result fail '{broken'
run_case zero-discovery fail '{"result":"Passed","totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":0}'
run_case all-skipped fail '{"result":"Skipped","totalTestCount":3,"passedTests":0,"failedTests":0,"skippedTests":3,"expectedFailures":0}'
run_case failed-result fail '{"result":"Failed","totalTestCount":3,"passedTests":2,"failedTests":1,"skippedTests":0,"expectedFailures":0}'
run_case contradictory-result fail '{"result":"Passed","totalTestCount":3,"passedTests":2,"failedTests":1,"skippedTests":0,"expectedFailures":0}'
run_case missing-count fail '{"result":"Passed","passedTests":2}'
run_case boolean-count fail '{"result":"Passed","totalTestCount":3,"passedTests":true,"failedTests":0,"skippedTests":2,"expectedFailures":0}'
run_case inconsistent-count fail '{"result":"Passed","totalTestCount":9,"passedTests":2,"failedTests":0,"skippedTests":1,"expectedFailures":0}'
echo 'ios_test_result_guards_test.sh: all assertions passed'
