#!/usr/bin/env bash
# Runs the UI evaluator's own Accessibility gate in a subprocess. The fixture
# never launches an app: it proves the command's exit/report contract when AX
# is unavailable, and the explicit --no-ui escape hatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVAL="$ROOT/script/user_mode_eval.swift"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/user-mode-eval-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
EVAL_BIN="$TMP/user-mode-eval"
swiftc "$EVAL" -o "$EVAL_BIN"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

set +e
"$EVAL_BIN" --repo "$ROOT" --artifacts "$TMP/untrusted" \
  --test-ui-gate-only --test-force-ax-untrusted >"$TMP/untrusted.out" 2>&1
untrusted_rc=$?
set -e
[[ "$untrusted_rc" -ne 0 ]] \
  || fail "missing Accessibility permission exited 0"
rg -q '"severity"\s*:\s*"fail"' "$TMP/untrusted/report.json" \
  || fail "missing Accessibility permission did not write a failure report"
rg -q '"id"\s*:\s*"ui.accessibility.trusted"' "$TMP/untrusted/report.json" \
  || fail "failure report did not identify the Accessibility gate"

"$EVAL_BIN" --repo "$ROOT" --artifacts "$TMP/no-ui" \
  --test-ui-gate-only --test-force-ax-untrusted --no-ui >"$TMP/no-ui.out" 2>&1
rg -q '"id"\s*:\s*"ui.skipped"' "$TMP/no-ui/report.json" \
  || fail "explicit --no-ui did not record its requested skip"
! rg -q '"id"\s*:\s*"ui.accessibility.trusted"' "$TMP/no-ui/report.json" \
  || fail "explicit --no-ui was treated as a missing-Accessibility failure"

"$EVAL_BIN" --repo "$ROOT" --artifacts "$TMP/visibility-contract" \
  --test-visibility-contract >"$TMP/visibility-contract.out" 2>&1
rg -q '"id"\s*:\s*"ui.visibility.geometry"' "$TMP/visibility-contract/report.json" \
  || fail "visibility contract did not exercise clipped/offscreen geometry"
rg -q '"id"\s*:\s*"ui.flow.inbox_open_approvals.fixture_order"' "$TMP/visibility-contract/report.json" \
  || fail "visibility contract did not exercise deterministic Inbox probe ordering"
! rg -q '"severity"\s*:\s*"fail"' "$TMP/visibility-contract/report.json" \
  || fail "visibility or concurrency-safe probe contract failed"

"$EVAL_BIN" --repo "$ROOT" --artifacts "$TMP/process-contract" \
  --test-process-contract >"$TMP/process-contract.out" 2>&1 \
  || { cat "$TMP/process-contract.out" >&2; fail "process execution contract failed"; }
for assertion in output.large output.failure timeout.reaped output.inherited_pipe list.failure_truth list.success; do
  rg -q "\"id\"\\s*:\\s*\"process.$assertion\"" "$TMP/process-contract/report.json" \
    || fail "process execution contract omitted $assertion"
done
! rg -q '"severity"\s*:\s*"fail"' "$TMP/process-contract/report.json" \
  || fail "process execution or failure-reporting contract failed"

echo "user_mode_eval_gate_test.sh: all assertions passed"
