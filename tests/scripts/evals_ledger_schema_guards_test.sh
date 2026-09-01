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

printf '%s\n' \
  '[{"fence":"core.fixture","fragment":{"ranRun":"dated fixture observation","uncertain":[],"surfaces":[{"id":"surface.one","kind":"public-api","where":"Sources/One.swift:1","coverage":[{"tier":"test","ref":"Tests/OneTests.swift:1","strength":"asserts"}]}]},"critic":{"missed":[],"disputed":[]}}]' \
  > "$TMP/inventory-not-receipt.json"
"$MERGER" "$TMP/inventory-not-receipt.json" --out "$TMP/inventory-not-receipt-out" >/dev/null
report="$TMP/inventory-not-receipt-out/COVERAGE.md"
grep -Fq 'COVERED 1' "$report" || fail "asserting coverage lost its inventory classification"

# A catalog/dispatch reachability probe is not functional behavior proof. It
# can reach the correct switch case while valid arguments still fail inside it.
printf '%s\n' \
  '[{"fence":"tools.byname","fragment":{"ranRun":"fixture","uncertain":[],"surfaces":[{"id":"tool.fixture","kind":"tool","where":"Sources/Fixture.swift:1","coverage":[{"tier":"test","ref":"Tests/FixtureTests.swift — everyRegisteredAppToolReachesItsAppOwnedDispatchBoundary","strength":"asserts"}]}]},"critic":{"missed":[],"disputed":[]}}]' \
  > "$TMP/route-only-asserts.json"
if "$MERGER" "$TMP/route-only-asserts.json" --out "$TMP/route-only-output" \
    > "$TMP/route-only.stdout" 2> "$TMP/route-only.stderr"; then
  fail "route-only reachability was accepted as asserting functional coverage"
fi
grep -Fq 'route-only coverage must be reports-only' "$TMP/route-only.stderr" \
  || fail "route-only assertion refusal lost its exact diagnostic"

sed 's/"strength":"asserts"/"strength":"reports-only"/' \
  "$TMP/route-only-asserts.json" > "$TMP/route-only-reports.json"
"$MERGER" "$TMP/route-only-reports.json" --out "$TMP/route-only-output"
grep -Fq 'REPORTS-ONLY 1' "$TMP/route-only-output/COVERAGE.md" \
  || fail "route-only evidence did not remain visible as reports-only"

# Post-inventory overrides are current evidence, not historical audit prose.
# Their explicit paths, line anchors, and suite selectors must still resolve.
mkdir -p "$TMP/repo/tests/FixtureTests"
printf '// fixture package\n' > "$TMP/repo/Package.swift"
printf '@Suite struct CurrentSuite {}\n' > "$TMP/repo/tests/FixtureTests/CurrentTests.swift"
printf '%s\n' \
  '[{"fence":"core.fixture","id":"fixture.current","coverage":[{"tier":"test","strength":"asserts","ref":"tests/FixtureTests/CurrentTests.swift:1 [swift-filter: CurrentSuite]"}]}]' \
  > "$TMP/current-overrides.json"
"$MERGER" validate-overrides --repo "$TMP/repo" --overrides "$TMP/current-overrides.json" \
  > "$TMP/current-overrides.log"
grep -Fq 'eval override references resolve' "$TMP/current-overrides.log" \
  || fail "current override reference did not validate"

sed 's/CurrentTests.swift:1/CurrentTests.swift:99/' "$TMP/current-overrides.json" \
  > "$TMP/stale-line-overrides.json"
if "$MERGER" validate-overrides --repo "$TMP/repo" --overrides "$TMP/stale-line-overrides.json" \
    > "$TMP/stale-line.stdout" 2> "$TMP/stale-line.stderr"; then
  fail "out-of-range override line was accepted"
fi
grep -Fq 'stale line tests/FixtureTests/CurrentTests.swift:99' "$TMP/stale-line.stderr" \
  || fail "stale line refusal lost its exact diagnostic"

sed 's/CurrentSuite/MissingSuite/' "$TMP/current-overrides.json" \
  > "$TMP/stale-suite-overrides.json"
if "$MERGER" validate-overrides --repo "$TMP/repo" --overrides "$TMP/stale-suite-overrides.json" \
    > "$TMP/stale-suite.stdout" 2> "$TMP/stale-suite.stderr"; then
  fail "stale override suite selector was accepted"
fi
grep -Fq 'stale or ambiguous swift-filter reference' "$TMP/stale-suite.stderr" \
  || fail "stale suite refusal lost its exact diagnostic"
grep -Fq 'rendering this report does not execute that evaluator or verify its current result' "$report" \
  || fail "inventory rendering implies a fresh passing run"
grep -Fq 'recorded audit run (historical): dated fixture observation' "$report" \
  || fail "historical observations are presented as current execution"

echo "evals_ledger_schema_guards_test.sh: all assertions passed"
