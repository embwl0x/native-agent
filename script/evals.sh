#!/usr/bin/env bash
# The two-minute check. Always-on tiers, one screen. Expensive tiers behind flags.
#   script/evals.sh            smoke + instrument (live, read-only) + turn-replay synthetic + Layer 1 range bench + ledger keeper
#   script/evals.sh --live     + personality range bench scenario #2 on a clone (real tokens)
#   script/evals.sh --ui       + strict user-mode eval (black-box AX walk of the installed app)
#   script/evals.sh --ios      + required iOS simulator unit/eval suites
#   script/evals.sh --full     complete Swift suites + required iOS + exact verified install
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"  # every tier assumes repo cwd (chat-drive resolves the DEV data root from here; run-anywhere)
LIVE=0; UI=0; IOS=0; FULL=0
for a in "$@"; do case "$a" in --live) LIVE=1;; --ui) UI=1;; --ios) IOS=1;; --full) FULL=1; IOS=1;; -h|--help) sed -n 2,8p "$0"; exit 0;; *) echo "unknown option: $a" >&2; exit 2;; esac; done
OUT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-evals.XXXXXX")"
fails=0; t0=$(date +%s)
step() { # name, cmd...
  local name="$1"; shift; local s=$(date +%s)
  if "$@" > "$OUT/$name.log" 2>&1; then printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
  else printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$OUT/$name.log"; fails=$((fails+1)); fi
}
has_nonzero_test_count() {
  grep -Eq '(^|[^0-9])[1-9][0-9]* tests?' "$1"
}
test_step() { # A green command that selected zero tests is a failure.
  local name="$1"; shift; local s=$(date +%s); local log="$OUT/$name.log"
  if "$@" > "$log" 2>&1 && has_nonzero_test_count "$log"; then
    printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
  else
    if ! has_nonzero_test_count "$log"; then printf '\n[evals] no non-zero executed-test count found\n' >> "$log"; fi
    printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$log"; fails=$((fails+1))
  fi
}
full_source_digest() {
  local file
  while IFS= read -r -d '' file; do
    printf '%s\0' "$file"
    shasum -a 256 "$ROOT/$file" | awk '{printf "%s\0", $1}'
  done < <(git -C "$ROOT" ls-files -co --exclude-standard -z -- \
    Sources Modules tests iOS script Shared Package.swift Package.resolved docs/evals) \
    | shasum -a 256 | awk '{print $1}'
}
full_install_and_verify() {
  local revision dirty
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  dirty=false
  [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] && dirty=true
  "$ROOT/script/install_app.sh" || return 1
  "$ROOT/script/verify_installed_runtime_ready.sh" \
    "$HOME/Applications/NativeAgent.app" "$revision" "$dirty" 30 || return 1
  touch "$OUT/full-install-ready"
}
echo "evals — $(git -C "$ROOT" rev-parse --short HEAD) — $(date '+%Y-%m-%d %H:%M')   (logs: $OUT)"
FULL_SOURCE_BEFORE=""
[ "$FULL" = 1 ] && FULL_SOURCE_BEFORE="$(full_source_digest)"
step smoke              "$ROOT/script/smoke_all.sh"
step instrument         swift "$ROOT/script/agent_instrument.swift" --data-root "$ROOT/data" --days 7 --out "$OUT/instrument.md"
if [ "$FULL" = 1 ]; then
  # The feed report is intentionally a read-only observation of the live data
  # root.  Its artifact belongs to this run's temporary directory, never data.
  step feed-coverage swift "$ROOT/script/feed_coverage_eval.swift" --data-root "$ROOT/data" --days 7 --out "$OUT/feed-coverage.md"
  step full-swift-suite "$ROOT/script/test.sh" --require-ios
  step full-install-verified full_install_and_verify
else
  test_step turn-replay        swift test --package-path "$ROOT" --filter "TurnReplayBench"
  test_step range-bench-L1     swift test --package-path "$ROOT" --filter "PersonalityRangeBench"
  test_step ledger-keeper      swift test --package-path "$ROOT" --filter "EvalCoverageLedger"
fi
[ "$LIVE" = 1 ] && NATIVEAGENT_RANGE_BENCH_LIVE=1 NATIVEAGENT_RANGE_BENCH_PERSONA_ROOT="$ROOT/persona" test_step range-bench-live swift test --package-path "$ROOT" --filter "scenario2_theRange"
[ "$IOS" = 1 ] && [ "$FULL" = 0 ] && test_step ios-simulator "$ROOT/script/test_ios.sh" --require
if [ "$UI" = 1 ]; then
  if [ "$FULL" = 0 ] || [ -f "$OUT/full-install-ready" ]; then
    step ui-walk "$ROOT/script/user_mode_eval.sh" --strict-ui
  else
    printf '  ✘ %-34s %4ss  → verified install unavailable\n' "ui-walk" 0
    fails=$((fails+1))
  fi
fi
if [ "$FULL" = 1 ]; then
  FULL_SOURCE_AFTER="$(full_source_digest)"
  if [ "$FULL_SOURCE_BEFORE" = "$FULL_SOURCE_AFTER" ]; then
    printf '  ✔ %-34s %4ss\n' "immutable-source-receipt" 0
    printf '%s\n' "$FULL_SOURCE_AFTER" > "$OUT/source-state.sha256"
  else
    printf '  ✘ %-34s %4ss  → source changed during gate\n' "immutable-source-receipt" 0
    fails=$((fails+1))
  fi
fi
if [ -f "$OUT/instrument.md" ]; then echo; echo "instrument BOOM:"; awk '/^\*\*Health\*\*/{p=1} p&&NR<400' "$OUT/instrument.md" | sed -n 1,12p | sed 's/^/  /'; fi
echo; echo "$(( $(date +%s) - t0 ))s total, $fails failure(s)"; exit $fails
