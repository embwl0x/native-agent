#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canonical-receipt-attempt.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/script" "$TMP/bin" "$TMP/receipts"
cp "$ROOT/script/test.sh" "$TMP/repo/script/test.sh"
printf '#!/usr/bin/env bash\nexit 73\n' > "$TMP/repo/script/check_canonical_test_wiring.sh"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse HEAD "*) printf '%s\n' "${FIXTURE_REVISION:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  *" status "*|*" diff --check "*) ;;
  *) exit 74 ;;
esac
STUB
chmod +x "$TMP/bin/git" "$TMP/repo/script/check_canonical_test_wiring.sh"
receipt="$TMP/receipts/current.json"
printf '{"schema_version":1,"source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_dirty":false,"canonical_gate":"script/test.sh","ios_required":true,"ios_result":"passed","completed_at":"2026-01-01T00:00:00Z"}\n' > "$receipt"
cp "$receipt" "$TMP/prior.json"
rc=0
PATH="$TMP/bin:$PATH" bash "$TMP/repo/script/test.sh" --release-receipt "$receipt" > "$TMP/failed.log" 2>&1 || rc=$?
[[ "$rc" == 73 ]] || { echo 'FAIL: fixture did not stop at the first canonical checker' >&2; exit 1; }
jq -e '.result == "incomplete" and .ios_result == "not_run" and (has("completed_at") | not)' "$receipt" >/dev/null
prior=("$receipt".previous.*)
[[ "${#prior[@]}" == 1 ]] && cmp -s "${prior[0]}" "$TMP/prior.json" \
  || { echo 'FAIL: previous receipt was not preserved byte-for-byte' >&2; exit 1; }
! grep -q 'Swift-native checks passed' "$TMP/failed.log"

# The real finalization block can publish only after its unchanged-source
# checks. Execute that block against the same pending attempt, not a replica.
awk '/^echo "\[test\] git diff whitespace"$/{copying=1} copying{print}' \
  "$ROOT/script/test.sh" > "$TMP/finalize.sh"
grep -q 'final_revision=' "$TMP/finalize.sh"
rc=0
PATH="$TMP/bin:$PATH" ROOT="$TMP/repo" RELEASE_RECEIPT="$receipt" \
  TEST_SOURCE_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash -euo pipefail "$TMP/finalize.sh" > "$TMP/changed.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && jq -e '.result == "incomplete"' "$receipt" >/dev/null \
  || { echo 'FAIL: changed source received a positive receipt' >&2; exit 1; }
PATH="$TMP/bin:$PATH" ROOT="$TMP/repo" RELEASE_RECEIPT="$receipt" \
  TEST_SOURCE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bash -euo pipefail "$TMP/finalize.sh" > "$TMP/passed.log" 2>&1
jq -e '.source_revision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .ios_result == "passed" and (.completed_at | length > 0) and (has("result") | not)' "$receipt" >/dev/null
grep -q 'Swift-native checks passed' "$TMP/passed.log"

# Invalid source identity must invalidate old proof before the first check,
# and an explicitly empty receipt option must not quietly become ordinary mode.
rc=0
PATH="$TMP/bin:$PATH" FIXTURE_REVISION=invalid bash "$TMP/repo/script/test.sh" \
  --release-receipt "$receipt" > "$TMP/invalid-source.log" 2>&1 || rc=$?
[[ "$rc" != 0 ]] && jq -e '.result == "incomplete"' "$receipt" >/dev/null
if bash "$TMP/repo/script/test.sh" --release-receipt= > "$TMP/empty.log" 2>&1; then
  echo 'FAIL: empty release receipt downgraded to ordinary mode' >&2; exit 1
fi
echo 'canonical_receipt_attempt_guards_test.sh: all assertions passed'
