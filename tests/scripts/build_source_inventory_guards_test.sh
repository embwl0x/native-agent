#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../script/lib/build_source_inventory.sh
source "$ROOT/script/lib/build_source_inventory.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-build-inventory.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/Sources/App" "$FIXTURE/Modules/Core/Sources/Core" "$FIXTURE/.runtime"
printf '// manifest\n' > "$FIXTURE/Package.swift"
printf 'struct App {}\n' > "$FIXTURE/Sources/App/App.swift"
printf 'struct Core {}\n' > "$FIXTURE/Modules/Core/Sources/Core/Core.swift"
STATE="$FIXTURE/.runtime/inventory.sha256"

nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE" ||
  fail 'first inventory must refresh the plan'
first_manifest_mtime="$(stat -f %m "$FIXTURE/Package.swift")"
sleep 1
if nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE"; then
  fail 'unchanged inventory refreshed the plan'
fi
[[ "$(stat -f %m "$FIXTURE/Package.swift")" == "$first_manifest_mtime" ]] ||
  fail 'unchanged inventory touched Package.swift'

printf 'struct Added {}\n' > "$FIXTURE/Modules/Core/Sources/Core/Added.swift"
nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE" ||
  fail 'new Swift path did not refresh the plan'
mv "$FIXTURE/Modules/Core/Sources/Core/Added.swift" "$FIXTURE/Modules/Core/Sources/Core/Renamed.swift"
nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE" ||
  fail 'renamed Swift path did not refresh the plan'
rm "$FIXTURE/Modules/Core/Sources/Core/Renamed.swift"
nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE" ||
  fail 'removed Swift path did not refresh the plan'
printf '{"resource":true}\n' > "$FIXTURE/Sources/App/Resource.json"
nativeagent_refresh_swiftpm_plan_if_inventory_changed "$FIXTURE" "$STATE" ||
  fail 'new resource path did not refresh the plan'

before="$(nativeagent_source_state_digest "$FIXTURE")"
printf 'struct Core { let changed = true }\n' > "$FIXTURE/Modules/Core/Sources/Core/Core.swift"
after="$(nativeagent_source_state_digest "$FIXTURE")"
[[ "$before" != "$after" ]] || fail 'content digest ignored a source edit'

# 2026-09-01: the core test bundle is built ONCE up front (--build-tests) and
# every shard, solo or pooled, runs --skip-build against those products.
grep -Fq -- '--package-path "$ROOT/Modules/NativeAgentCore" --build-tests' "$ROOT/script/test.sh" ||
  fail 'the core test bundle is no longer built once up front'
grep -Fq -- '--skip-build --package-path "$ROOT/Modules/NativeAgentCore"' "$ROOT/script/test.sh" ||
  fail 'test shards do not reuse the first built products'
grep -Fq 'CORE_TEST_SOURCE_DIGEST_AFTER=' "$ROOT/script/test.sh" ||
  fail 'test shards lack a final source-state guard'
if grep -Eq 'touch .*Package\.swift|apply_patch|sed -i' "$ROOT/script/benchmark_release_compilation.sh"; then
  fail 'release compile benchmark mutates the package manifest/source'
fi
grep -Fq 'DO NOT adopt until launch/runtime performance is separately proven' \
  "$ROOT/script/benchmark_release_compilation.sh" ||
  fail 'release compile experiment can bypass runtime proof'

# Exercise the actual benchmark entrypoint without compiling the app. Timing
# remains /usr/bin/time's real receipt; only SwiftPM's expensive work is stubbed.
BENCH_FIXTURE="$TMP/benchmark-repo"
mkdir -p "$BENCH_FIXTURE/script/lib" "$BENCH_FIXTURE/bin"
cp "$ROOT/script/benchmark_release_compilation.sh" "$BENCH_FIXTURE/script/"
cp "$ROOT/script/lib/build_source_inventory.sh" "$BENCH_FIXTURE/script/lib/"
printf '// fixture manifest\n' > "$BENCH_FIXTURE/Package.swift"
printf '{"pins":[]}\n' > "$BENCH_FIXTURE/Package.resolved"
cp "$BENCH_FIXTURE/Package.resolved" "$TMP/original-pins"
cat > "$BENCH_FIXTURE/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == build ]] || exit 90
shift
scratch=''
pinned=0
skip_update=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scratch-path) scratch="$2"; shift;;
    --force-resolved-versions) pinned=1;;
    --skip-update) skip_update=1;;
  esac
  shift
done
[[ "$pinned" == 1 && "$skip_update" == 1 && -n "$scratch" ]] || exit 91
name="${scratch##*/}"
printf '%s\n' "$name" >> "$BENCH_CASE_ROOT/invocations"
if [[ "$BENCH_FAIL" == "$name" ]]; then
  echo "fixture compiler failure for $name" >&2
  exit 42
fi
mkdir -p "$scratch/release"
printf 'fixture executable\n' > "$scratch/release/NativeAgentApp"
STUB
chmod +x "$BENCH_FIXTURE/bin/swift"
for scenario in success keep default-failure candidate-failure; do
  bench_case_root="$TMP/benchmark-$scenario"
  mkdir -p "$bench_case_root"
  bench_args=(--jobs=1)
  bench_fail='none'
  case "$scenario" in
    keep) bench_args+=(--keep);;
    default-failure) bench_fail=default;;
    candidate-failure) bench_fail=no_wmo;;
  esac
  bench_rc=0
  PATH="$BENCH_FIXTURE/bin:$PATH" TMPDIR="$bench_case_root" \
    BENCH_CASE_ROOT="$bench_case_root" BENCH_FAIL="$bench_fail" \
    bash "$BENCH_FIXTURE/script/benchmark_release_compilation.sh" "${bench_args[@]}" \
    > "$bench_case_root/output" 2>&1 || bench_rc=$?
  cmp -s "$BENCH_FIXTURE/Package.resolved" "$TMP/original-pins" \
    || fail 'compile benchmark changed pinned dependencies'
  bench_retained="$(find "$bench_case_root" -maxdepth 1 -type d -name 'nativeagent-release-compile-benchmark.*' -print)"
  if [[ "$scenario" == *-failure ]]; then
    [[ "$bench_rc" == 42 && -n "$bench_retained" ]] \
      || fail "benchmark $scenario lost compiler failure status or logs (exit $bench_rc)"
    grep -Fq "fixture compiler failure for $bench_fail" "$bench_retained/$bench_fail.log" \
      || fail "benchmark $scenario lost the compiler diagnostic"
    grep -Fq "failed (exit 42); retained evidence: $bench_retained" "$bench_case_root/output" \
      || fail "benchmark $scenario hid failure evidence location"
    if [[ "$scenario" == candidate-failure ]]; then
      [[ -s "$bench_retained/default.metrics" && -s "$bench_retained/default.log" ]] \
        || fail 'candidate failure destroyed completed baseline evidence'
    fi
  else
    [[ "$bench_rc" == 0 ]] || fail "successful $scenario benchmark returned $bench_rc"
    [[ "$(wc -l < "$bench_case_root/invocations" | tr -d ' ')" == 2 ]] \
      || fail "benchmark $scenario did not execute both pinned comparisons"
    if [[ "$scenario" == keep ]]; then
      [[ -n "$bench_retained" && -s "$bench_retained/default.metrics" && -s "$bench_retained/no_wmo.metrics" ]] \
        || fail '--keep did not retain both comparisons'
      grep -Fq "retained evidence: $bench_retained" "$bench_case_root/output" \
        || fail '--keep did not identify retained evidence'
    else
      [[ -z "$bench_retained" ]] || fail 'successful default benchmark left unwanted scratch data'
    fi
  fi
done

printf 'ok - build source inventory guards\n'
