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

grep -Fq 'core_shard_build_flag=(--skip-build)' "$ROOT/script/test.sh" ||
  fail 'test shards do not reuse the first built products'
grep -Fq 'CORE_TEST_SOURCE_DIGEST_AFTER=' "$ROOT/script/test.sh" ||
  fail 'test shards lack a final source-state guard'
if grep -Eq 'touch .*Package\.swift|apply_patch|sed -i' "$ROOT/script/benchmark_release_compilation.sh"; then
  fail 'release compile benchmark mutates the package manifest/source'
fi
grep -Fq 'DO NOT adopt until launch/runtime performance is separately proven' \
  "$ROOT/script/benchmark_release_compilation.sh" ||
  fail 'release compile experiment can bypass runtime proof'

printf 'ok - build source inventory guards\n'
