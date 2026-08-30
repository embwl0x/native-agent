#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/evals-changed-plan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
MERGER="$TMP/evals-ledger-merge"
swiftc "$ROOT/script/evals_ledger_merge.swift" -o "$MERGER"

mkdir -p "$TMP/repo/Modules/NativeAgentCore/Sources/Fixture" \
  "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests"
printf 'public struct Fixture {}\n' > "$TMP/repo/Modules/NativeAgentCore/Sources/Fixture/Fixture.swift"
printf 'struct FixtureTests {}\n' > "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests/FixtureTests.swift"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm baseline
printf 'public struct Fixture { public init() {} }\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Sources/Fixture/Fixture.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm source-change
sha="$(git -C "$TMP/repo" rev-parse HEAD)"

printf '%s\n' \
  '{"surfaces":[{"fence":"core.fixture","id":"fixture.surface","kind":"public-api","where":"Modules/NativeAgentCore/Sources/Fixture/Fixture.swift:1","coverage":[{"tier":"test","ref":"fixture behavior — Tests/FixtureTests/FixtureTests.swift:1","strength":"asserts"}],"status":"COVERED"}]}' \
  > "$TMP/ledger.json"

"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger.json" --sha "$sha" \
  --selections "$TMP/selections.tsv" --mappings "$TMP/mappings.tsv" \
  --unmapped "$TMP/unmapped.tsv" --changed-files "$TMP/changed-files.txt"

expected=$'NativeAgentCore\tModules/NativeAgentCore\tFixtureTests'
[[ "$(tr -d '\n' < "$TMP/selections.tsv")" == "$expected" ]] \
  || fail "package-relative Tests path did not resolve to NativeAgentCore"
[[ ! -s "$TMP/unmapped.tsv" ]] \
  || fail "existing package-relative Tests path was reported unmapped"

# A mapped sibling cannot conceal a new production file/one-file target. The
# keeper inventories modules with >=3 files, so these need explicit attribution.
mkdir -p "$TMP/repo/Modules/NativeAgentCore/Sources/NewTarget"
printf 'public struct NewTarget {}\n' > "$TMP/repo/Modules/NativeAgentCore/Sources/NewTarget/NewTarget.swift"
printf 'public struct Fixture { public init() {}; public let changed = true }\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Sources/Fixture/Fixture.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm mixed-new-production-owner
mixed_sha="$(git -C "$TMP/repo" rev-parse HEAD)"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger.json" --sha "$mixed_sha" \
  --selections "$TMP/mixed-selections.tsv" --mappings "$TMP/mixed-mappings.tsv" \
  --unmapped "$TMP/mixed-unmapped.tsv" --changed-files "$TMP/mixed-changed-files.txt"
[[ "$(tr -d '\n' < "$TMP/mixed-selections.tsv")" == "$expected" ]] \
  || fail "new unmapped owner discarded valid sibling selections"
rg -q '^unmapped-production:Modules/NativeAgentCore/Sources/NewTarget/NewTarget.swift' "$TMP/mixed-unmapped.tsv" \
  || fail "mapped sibling concealed a new production owner"

# Exercise the actual eval entrypoint too: otherwise a correct planner warning
# could still be ignored when its sibling tests and keepers all return success.
mkdir -p "$TMP/repo/script" "$TMP/repo/docs/evals" "$TMP/bin"
cp "$ROOT/script/evals.sh" "$TMP/repo/script/evals.sh"
cp "$TMP/ledger.json" "$TMP/repo/docs/evals/ledger.json"
cat > "$TMP/bin/swift" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == */evals_ledger_merge.swift ]]; then
  shift
  exec "$CHANGED_PLAN_MERGER" "$@"
fi
[[ "$1" == test ]] || exit 92
echo 'Executed 3 tests, with 0 failures (0 unexpected) in 0.01 seconds'
STUB
chmod +x "$TMP/bin/swift"
rc=0
PATH="$TMP/bin:$PATH" CHANGED_PLAN_MERGER="$MERGER" TMPDIR="$TMP" \
  bash "$TMP/repo/script/evals.sh" --changed "$mixed_sha" > "$TMP/mixed-evals.log" 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail "actual changed eval accepted an unrepresented production owner"
rg -q 'UNMAPPED SURFACE: unmapped-production:' "$TMP/mixed-evals.log" \
  || fail "actual changed eval hid the missing production owner diagnostic"
! rg -q "WE'RE GOOD|DOCS-ONLY:" "$TMP/mixed-evals.log" \
  || fail "mixed production commit received a misleading passing label"

# Once the new owner has a real executable reference, the same commit is fully
# selectable. Reusing a test suite is allowed; silently inventing one is not.
jq '.surfaces += [.surfaces[0] | .id = "fixture.newTarget" | .where = "Modules/NativeAgentCore/Sources/NewTarget/NewTarget.swift:1"]' \
  "$TMP/ledger.json" > "$TMP/ledger-new-target.json"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger-new-target.json" --sha "$mixed_sha" \
  --selections "$TMP/new-target-selections.tsv" --mappings "$TMP/new-target-mappings.tsv" \
  --unmapped "$TMP/new-target-unmapped.tsv" --changed-files "$TMP/new-target-changed-files.txt"
[[ ! -s "$TMP/new-target-unmapped.tsv" ]] || fail "explicit new owner mapping remained unresolved"
rg -q 'fixture.newTarget' "$TMP/new-target-mappings.tsv" || fail "new owner mapping was not selected"

# A commit that changes the referenced test itself must implicate the same
# surface. The old raw-string comparison missed this fully qualified git path.
printf 'struct FixtureTests { let changed = true }\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests/FixtureTests.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm test-change
sha="$(git -C "$TMP/repo" rev-parse HEAD)"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger.json" --sha "$sha" \
  --selections "$TMP/test-selections.tsv" --mappings "$TMP/test-mappings.tsv" \
  --unmapped "$TMP/test-unmapped.tsv" --changed-files "$TMP/test-changed-files.txt"
rg -q $'^NativeAgentCore\tModules/NativeAgentCore\tFixtureTests$' "$TMP/test-selections.tsv" \
  || fail "changed package-relative test file did not implicate its ledger surface"

# Fully qualified test evidence remains unambiguous after the file is deleted;
# the deletion must still implicate the surface instead of vanishing.
printf '%s\n' \
  '{"surfaces":[{"fence":"core.fixture","id":"fixture.surface","kind":"public-api","where":"Modules/NativeAgentCore/Sources/Fixture/Fixture.swift:1","coverage":[{"tier":"test","ref":"Modules/NativeAgentCore/Tests/FixtureTests/FixtureTests.swift:1","strength":"asserts"}],"status":"COVERED"}]}' \
  > "$TMP/ledger-direct.json"
rm "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests/FixtureTests.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add -u
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm test-deletion
sha="$(git -C "$TMP/repo" rev-parse HEAD)"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger-direct.json" --sha "$sha" \
  --selections "$TMP/deleted-selections.tsv" --mappings "$TMP/deleted-mappings.tsv" \
  --unmapped "$TMP/deleted-unmapped.tsv" --changed-files "$TMP/deleted-changed-files.txt"
rg -q $'^NativeAgentCore\tModules/NativeAgentCore\tFixtureTests$' "$TMP/deleted-selections.tsv" \
  || fail "deleted fully qualified test evidence did not implicate its ledger surface"

# Ambiguous package-relative paths must not guess a package.
printf 'struct FixtureTests { let restored = true }\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests/FixtureTests.swift"
mkdir -p "$TMP/repo/Modules/NativeAgentShared/Tests/FixtureTests"
printf 'struct SharedFixtureTests {}\n' \
  > "$TMP/repo/Modules/NativeAgentShared/Tests/FixtureTests/FixtureTests.swift"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger.json" --sha "$sha" \
  --selections "$TMP/ambiguous-selections.tsv" --mappings "$TMP/ambiguous-mappings.tsv" \
  --unmapped "$TMP/ambiguous-unmapped.tsv" --changed-files "$TMP/ambiguous-changed-files.txt"
[[ ! -s "$TMP/ambiguous-selections.tsv" ]] \
  || fail "ambiguous package-relative Tests path guessed a package"
rg -q $'^fixture.surface\t' "$TMP/ambiguous-unmapped.tsv" \
  || fail "ambiguous package-relative Tests path did not fail closed"

# Filename globs in canonical evidence expand to concrete filters rather than
# being passed through as a regex-like Swift test filter.
mkdir -p "$TMP/repo/Sources" "$TMP/repo/tests/RootTests"
printf 'public struct RootFixture {}\n' > "$TMP/repo/Sources/RootFixture.swift"
printf 'struct RootAlphaTests {}\n' > "$TMP/repo/tests/RootTests/RootAlphaTests.swift"
printf 'struct RootBetaTests {}\n' > "$TMP/repo/tests/RootTests/RootBetaTests.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm wildcard-baseline
printf 'public struct RootFixture { public init() {} }\n' > "$TMP/repo/Sources/RootFixture.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm wildcard-source-change
sha="$(git -C "$TMP/repo" rev-parse HEAD)"
printf '%s\n' \
  '{"surfaces":[{"fence":"root.fixture","id":"root.surface","kind":"public-api","where":"Sources/RootFixture.swift:1","coverage":[{"tier":"test","ref":"tests/RootTests/Root*Tests.swift","strength":"asserts"}],"status":"COVERED"}]}' \
  > "$TMP/ledger-wildcard.json"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger-wildcard.json" --sha "$sha" \
  --selections "$TMP/wildcard-selections.tsv" --mappings "$TMP/wildcard-mappings.tsv" \
  --unmapped "$TMP/wildcard-unmapped.tsv" --changed-files "$TMP/wildcard-changed-files.txt"
rg -q $'^root\t\.\tRootAlphaTests$' "$TMP/wildcard-selections.tsv" \
  || fail "wildcard evidence did not select RootAlphaTests concretely"
rg -q $'^root\t\.\tRootBetaTests$' "$TMP/wildcard-selections.tsv" \
  || fail "wildcard evidence did not select RootBetaTests concretely"
[[ "$(wc -l < "$TMP/wildcard-selections.tsv" | tr -d ' ')" == 2 ]] \
  || fail "wildcard evidence emitted a raw or unexpected test filter"

# A deleted glob match still implicates the surface even though current-file
# expansion can no longer return that path. Remaining matches are selected.
rm "$TMP/repo/tests/RootTests/RootAlphaTests.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add -u
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm wildcard-one-deleted
sha="$(git -C "$TMP/repo" rev-parse HEAD)"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger-wildcard.json" --sha "$sha" \
  --selections "$TMP/wildcard-delete-selections.tsv" --mappings "$TMP/wildcard-delete-mappings.tsv" \
  --unmapped "$TMP/wildcard-delete-unmapped.tsv" --changed-files "$TMP/wildcard-delete-changed-files.txt"
[[ "$(tr -d '\n' < "$TMP/wildcard-delete-selections.tsv")" == $'root\t.\tRootBetaTests' ]] \
  || fail "wildcard deletion did not select the remaining concrete test"
[[ ! -s "$TMP/wildcard-delete-unmapped.tsv" ]] \
  || fail "wildcard deletion was unmapped despite a remaining concrete test"

# Deleting the final match is affected but has no executable evidence left, so
# the surface must fail closed as unmapped.
rm "$TMP/repo/tests/RootTests/RootBetaTests.swift"
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid add -u
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm wildcard-all-deleted
sha="$(git -C "$TMP/repo" rev-parse HEAD)"
"$MERGER" changed-plan \
  --repo "$TMP/repo" --ledger "$TMP/ledger-wildcard.json" --sha "$sha" \
  --selections "$TMP/wildcard-empty-selections.tsv" --mappings "$TMP/wildcard-empty-mappings.tsv" \
  --unmapped "$TMP/wildcard-empty-unmapped.tsv" --changed-files "$TMP/wildcard-empty-changed-files.txt"
[[ ! -s "$TMP/wildcard-empty-selections.tsv" ]] \
  || fail "deleted final wildcard match emitted an executable selection"
rg -q $'^root.surface\t' "$TMP/wildcard-empty-unmapped.tsv" \
  || fail "deleted final wildcard match did not fail closed as unmapped"

# Explicit suite metadata handles real files containing differently named
# suites. The selector is tied to one existing file and target, never a shell
# fragment or a basename guessed across unrelated packages.
printf '// fixture package\n' > "$TMP/repo/Modules/NativeAgentCore/Package.swift"
printf '@Suite struct ActualOwnerSuite {}\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Tests/FixtureTests/FileNamedDifferently.swift"
printf 'public struct Fixture { let selectorChange = true }\n' \
  > "$TMP/repo/Modules/NativeAgentCore/Sources/Fixture/Fixture.swift"
git -C "$TMP/repo" add .
git -C "$TMP/repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm explicit-suite
selector_sha="$(git -C "$TMP/repo" rev-parse HEAD)"
selector_path='Modules/NativeAgentCore/Tests/FixtureTests/FileNamedDifferently.swift'
for scenario in valid stale missing relative wildcard unsafe multiple; do
  ref="$selector_path [swift-filter: ActualOwnerSuite]"
  case "$scenario" in
    stale) ref="$selector_path [swift-filter: UnrelatedSuite]";;
    missing) ref='Modules/NativeAgentCore/Tests/FixtureTests/Deleted.swift [swift-filter: ActualOwnerSuite]';;
    relative) ref='Tests/FixtureTests/FileNamedDifferently.swift [swift-filter: ActualOwnerSuite]';;
    wildcard) ref='Modules/NativeAgentCore/Tests/FixtureTests/*.swift [swift-filter: ActualOwnerSuite]';;
    unsafe) ref="$selector_path "'[swift-filter: $(touch selector-injected)]';;
    multiple) ref="$selector_path [swift-filter: ActualOwnerSuite] [swift-filter: Other]";;
  esac
  jq --arg ref "$ref" '.surfaces[0].coverage = [{tier:"test",strength:"asserts",ref:$ref}]' \
    "$TMP/ledger.json" > "$TMP/selector-$scenario.json"
  "$MERGER" changed-plan \
    --repo "$TMP/repo" --ledger "$TMP/selector-$scenario.json" --sha "$selector_sha" \
    --selections "$TMP/selector-$scenario.tsv" --mappings "$TMP/selector-$scenario-mappings.tsv" \
    --unmapped "$TMP/selector-$scenario-unmapped.tsv" --changed-files "$TMP/selector-$scenario-files.txt"
  if [[ "$scenario" == valid ]]; then
    [[ "$(tr -d '\n' < "$TMP/selector-$scenario.tsv")" == $'NativeAgentCore\tModules/NativeAgentCore\t^FixtureTests\\.ActualOwnerSuite[./]' ]] \
      || fail "explicit suite was not bound to the declared file target"
  else
    [[ ! -s "$TMP/selector-$scenario.tsv" ]] || fail "$scenario suite metadata guessed an executable selection"
    rg -q $'^fixture.surface\t' "$TMP/selector-$scenario-unmapped.tsv" \
      || fail "$scenario suite metadata was not reported unresolved"
  fi
done
[[ ! -e selector-injected ]] || fail "suite metadata was evaluated as shell code"

echo "evals_changed_plan_guards_test.sh: all assertions passed"
