#!/usr/bin/env bash
# The two-minute check. Always-on tiers, one screen. Expensive tiers behind flags.
#   script/evals.sh            smoke + instrument (live, read-only) + turn-replay synthetic + Layer 1 range bench + ledger keeper
#   script/evals.sh --live     + personality range bench scenario #2 on a clone (real tokens)
#   script/evals.sh --ui       + strict user-mode eval (black-box AX walk of the installed app)
#   script/evals.sh --ios      + required iOS simulator unit/eval suites
#   script/evals.sh --full     complete Swift suites + required iOS + exact verified install
#   script/evals.sh --changed <sha>  tests only ledger-mapped surfaces touched by one commit
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"  # every tier assumes repo cwd (chat-drive resolves the DEV data root from here; run-anywhere)
LIVE=0; UI=0; IOS=0; FULL=0; CHANGED_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift;;
    --ui) UI=1; shift;;
    --ios) IOS=1; shift;;
    --full) FULL=1; IOS=1; shift;;
    --changed)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "--changed requires a commit SHA" >&2; exit 2; fi
      CHANGED_SHA="$2"; shift 2;;
    -h|--help) sed -n 2,9p "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
if [ -n "$CHANGED_SHA" ] && { [ "$LIVE" = 1 ] || [ "$UI" = 1 ] || [ "$IOS" = 1 ] || [ "$FULL" = 1 ]; }; then
  echo "--changed cannot be combined with --live, --ui, --ios, or --full" >&2
  exit 2
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-evals.XXXXXX")"
fails=0; changed_exit_code=0; t0=$(date +%s)
step() { # name, cmd...
  local name="$1"; shift; local s=$(date +%s)
  if "$@" > "$OUT/$name.log" 2>&1; then printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
  else printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$OUT/$name.log"; fails=$((fails+1)); fi
}
has_nonzero_test_count() {
  # Discovery/build chatter is not execution proof. Accept only framework
  # completion summaries or the iOS runners checked xcresult receipt.
  awk '
    /^[[:space:]]*Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?([[:space:]]|$)/ {
      total=$2; skipped=0; failed=$5
      if ($6 ~ /^tests?$/ && $7 == "skipped") { skipped=$5; failed=$9 }
      if (failed !~ /^[0-9]+$/ || failed > 0) bad=1
      else if (total > skipped) found=1
    }
    /^[^[:alnum:]]*Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed([[:space:]]|$)/ {
      line=$0; sub(/^.*Test run with /,"",line); split(line,fields," ")
      if (fields[1] > 0) found=1
    }
    /^[^[:alnum:]]*Test run with [0-9]+ tests?.*failed/ { bad=1 }
    /^\[test-ios\] passed: [1-9][0-9]* passed, [0-9]+ skipped, [0-9]+ expected failures, [1-9][0-9]* discovered$/ { found=1 }
    END { exit(found && !bad ? 0 : 1) }
  ' "$1"
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
changed_failure() { # package-label, filter, step-name, log
  local package_label="$1" filter="$2" name="$3" log="$4" found=0
  while IFS=$'\t' read -r mapped_package mapped_filter surface_id where_text fence; do
    if [ "$mapped_package" = "$package_label" ] && [ "$mapped_filter" = "$filter" ]; then
      printf '    BROKE: %s (%s)\n' "$surface_id" "$where_text"
      found=1
    fi
  done < "$OUT/changed-mappings.tsv"
  if [ "$found" = 0 ]; then
    printf '    UNMAPPED FAILURE: %s (%s --filter %s)\n' "$name" "$package_label" "$filter"
  fi
  printf '    diagnostic: %s\n' "$log"
  sed -n '1,80p' "$log" | sed 's/^/      /'
}
changed_test_step() { # name, package-label, filter, cmd...
  local name="$1" package_label="$2" filter="$3"; shift 3
  local s=$(date +%s) log="$OUT/$name.log" rc=0
  "$@" > "$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && has_nonzero_test_count "$log"; then
    printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
    return 0
  fi
  if ! has_nonzero_test_count "$log"; then printf '\n[evals] no non-zero executed-test count found\n' >> "$log"; fi
  printf '\n[evals] command exit: %s\n' "$rc" >> "$log"
  printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$log"
  fails=$((fails+1))
  if [ "$changed_exit_code" = 0 ]; then
    if [ "$rc" = 0 ]; then changed_exit_code=1; else changed_exit_code="$rc"; fi
  fi
  changed_failure "$package_label" "$filter" "$name" "$log"
  return 1
}
changed_script_step() { # name, script-path, cmd...
  local name="$1" script_path="$2"; shift 2
  local s=$(date +%s) log="$OUT/$name.log" rc=0
  "$@" > "$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
    return 0
  fi
  printf '\n[evals] command exit: %s\n' "$rc" >> "$log"
  printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$log"
  fails=$((fails+1))
  [ "$changed_exit_code" = 0 ] && changed_exit_code="$rc"
  changed_failure "script" "$script_path" "$name" "$log"
  return 1
}
is_eval_bookkeeping_path() {
  case "$1" in
    docs/evals/phase1-fragments.json|docs/evals/coverage-overrides.json|docs/evals/coverage-campaigns.json|docs/evals/ledger.json|docs/evals/COVERAGE.md|docs/evals/total-coverage-surface-ids.json|docs/evals/behavior-coverage-conveyor-*-surface-ids.json|docs/evals/behavior-remap-residue-*.json) return 0;;
    *) return 1;;
  esac
}
changed_docs_merge_step() {
  local name=canonical-merge s=$(date +%s) log="$OUT/canonical-merge.log"
  local rendered="$OUT/canonical-merge"
  mkdir -p "$rendered"
  local rc=0
  "$CHANGED_SWIFT" "$ROOT/script/evals_ledger_merge.swift" \
    "$ROOT/docs/evals/phase1-fragments.json" --out "$rendered" > "$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && cmp -s "$rendered/ledger.json" "$ROOT/docs/evals/ledger.json" \
      && cmp -s "$rendered/COVERAGE.md" "$ROOT/docs/evals/COVERAGE.md"; then
    printf '  ✔ %-34s %4ss\n' "$name" "$(( $(date +%s) - s ))"
    return 0
  fi
  [ "$rc" = 0 ] && printf '\n[evals] generated ledger/COVERAGE differ from canonical merge\n' >> "$log"
  printf '\n[evals] command exit: %s\n' "$rc" >> "$log"
  printf '  ✘ %-34s %4ss  → %s\n' "$name" "$(( $(date +%s) - s ))" "$log"
  fails=$((fails+1))
  [ "$changed_exit_code" = 0 ] && changed_exit_code=$([ "$rc" = 0 ] && echo 1 || echo "$rc")
  sed -n '1,80p' "$log" | sed 's/^/      /'
  return 1
}
full_source_digest() {
  local file
  while IFS= read -r -d '' file; do
    printf '%s\0' "$file"
    shasum -a 256 "$ROOT/$file" | awk '{printf "%s\0", $1}'
  done < <(git -C "$ROOT" ls-files -co --exclude-standard -z -- \
    Sources Modules tests iOS script Shared Extensions Package.swift Package.resolved docs/evals) \
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
step eval-reference-integrity swift "$ROOT/script/evals_ledger_merge.swift" validate-overrides \
  --repo "$ROOT" --overrides "$ROOT/docs/evals/coverage-overrides.json"
if [ -n "$CHANGED_SHA" ]; then
  [ "$fails" -eq 0 ] || changed_exit_code=1
  CHANGED_SWIFT="${NATIVEAGENT_EVALS_CHANGED_SWIFT:-swift}"
  if ! "$CHANGED_SWIFT" "$ROOT/script/evals_ledger_merge.swift" changed-plan \
      --repo "$ROOT" --ledger "$ROOT/docs/evals/ledger.json" --sha "$CHANGED_SHA" \
      --selections "$OUT/changed-selections.tsv" --mappings "$OUT/changed-mappings.tsv" \
      --unmapped "$OUT/changed-unmapped.tsv" --changed-files "$OUT/changed-files.txt" \
      > "$OUT/changed-plan.log" 2>&1; then
    echo "[evals] changed-mode planning failed for '$CHANGED_SHA':" >&2
    sed 's/^/  /' "$OUT/changed-plan.log" >&2
    exit 2
  fi

  echo "changed files:"
  sed 's/^/  /' "$OUT/changed-files.txt"
  docs_only=1
  while IFS= read -r changed_file; do
    [ -z "$changed_file" ] && continue
    is_eval_bookkeeping_path "$changed_file" || docs_only=0
  done < "$OUT/changed-files.txt"
  [ -s "$OUT/changed-files.txt" ] || docs_only=0
  awk -F '\t' '!seen[$5 FS $3]++ {printf "  IMPLICATED: %s/%s (%s)\n", $5, $3, $4}' \
    "$OUT/changed-mappings.tsv"
  selected_count=$(awk 'END{print NR+0}' "$OUT/changed-selections.tsv")
  if [ "$selected_count" = 0 ] && [ "$docs_only" = 0 ]; then
    echo "  NO MAPPED EXECUTABLE REFS: this commit selects no ledger-backed test or smoke check"
    fails=$((fails+1))
    [ "$changed_exit_code" = 0 ] && changed_exit_code=1
  fi
  while IFS=$'\t' read -r surface_id where_text fence; do
    [ -z "$surface_id" ] && continue
    printf '  UNMAPPED SURFACE: %s (%s) — no executable coverage ref\n' "$surface_id" "$where_text"
    fails=$((fails+1))
    [ "$changed_exit_code" = 0 ] && changed_exit_code=1
  done < "$OUT/changed-unmapped.tsv"

  # Gate velocity (2026-09-01): the wall clock here went on REDUNDANT BUILDS,
  # not on the number of test runs. Every selection got its own `swift test`,
  # and each one re-parsed the manifests and re-ran the incremental build check
  # for a package an earlier selection had already built — 65 times on
  # 4632df4b. The first selection of a package now owns its build and every
  # later selection of that package reuses it with --skip-build.
  #
  # Deliberately NOT batched into one alternation filter per package: SwiftPM's
  # `--filter` selects Swift Testing cases by their source FILE as well as by
  # test id, so the filters cannot be verified against `swift test list` output,
  # and a single combined run can only prove a non-zero executed-test count for
  # the batch as a whole. One process per selection keeps changed_test_step's
  # per-selection proof — a stale ledger filter that now selects zero tests
  # fails its own step and names its own surface — which is the whole point of
  # the gate. A package's build is paid once either way.
  index=0
  built_packages=""
  root_tests_built=0
  while IFS=$'\t' read -r package_label package_path filter; do
    [ -z "$filter" ] && continue
    index=$((index+1)); name=$(printf 'changed-%03d' "$index")
    if [ "$package_label" = "script" ]; then
      printf '  SELECTED: executable %s\n' "$filter"
      changed_script_step "$name" "$filter" "$ROOT/$filter" || true
    elif [ "$package_label" = "ios" ]; then
      printf '  SELECTED: iOS simulator --only-testing %s\n' "$filter"
      changed_test_step "$name" "$package_label" "$filter" \
        "$ROOT/script/test_ios.sh" --require --only-testing "$filter" || true
    else
      printf '  SELECTED: %s --filter %s\n' "$package_label" "$filter"
      # --skip-build only after a run of THIS package has completed
      # successfully, so a failed build never hands a later selection a stale
      # or missing binary to succeed against.
      changed_build_flag=()
      case " $built_packages " in
        *" $package_label "*) changed_build_flag=(--skip-build);;
      esac
      if changed_test_step "$name" "$package_label" "$filter" \
          swift test --force-resolved-versions --skip-update \
          --package-path "$ROOT/$package_path" \
          ${changed_build_flag[@]+"${changed_build_flag[@]}"} --filter "$filter"; then
        case " $built_packages " in
          *" $package_label "*) ;;
          *) built_packages="$built_packages $package_label";;
        esac
        [ "$package_label" = "root" ] && root_tests_built=1
      fi
    fi
  done < "$OUT/changed-selections.tsv"
  if [ "$docs_only" = 1 ]; then
    changed_docs_merge_step || true
  fi
  # The two always-on root keepers reuse the root package's build for the same
  # reason; nothing between them touches source.
  keeper_build_flag=()
  [ "$root_tests_built" = 1 ] && keeper_build_flag=(--skip-build)
  if changed_test_step ledger-keeper root EvalCoverageLedger \
      swift test --force-resolved-versions --skip-update --package-path "$ROOT" \
      ${keeper_build_flag[@]+"${keeper_build_flag[@]}"} --filter "EvalCoverageLedger"; then
    root_tests_built=1
  fi
  contract_build_flag=()
  [ "$root_tests_built" = 1 ] && contract_build_flag=(--skip-build)
  changed_test_step total-surface-contract root TotalSurfaceContract \
    swift test --force-resolved-versions --skip-update --package-path "$ROOT" \
    ${contract_build_flag[@]+"${contract_build_flag[@]}"} --filter "TotalSurfaceContract" || true

  echo
  if [ "$fails" = 0 ] && [ "$docs_only" = 1 ]; then
    echo "DOCS-ONLY: keeper+seal+merge green, nothing executable touched"
  elif [ "$fails" = 0 ]; then echo "WE'RE GOOD"; else echo "NOT GOOD: $fails failure(s)"; fi
  echo "$(( $(date +%s) - t0 ))s total, $fails failure(s)"
  exit "$changed_exit_code"
fi
FULL_SOURCE_BEFORE=""
[ "$FULL" = 1 ] && FULL_SOURCE_BEFORE="$(full_source_digest)"
step smoke              "$ROOT/script/smoke_all.sh"
step instrument         swift "$ROOT/script/agent_instrument.swift" --data-root "$ROOT/data" --days 7 --out "$OUT/instrument.md"
if [ "$FULL" = 1 ]; then
  # The feed report is intentionally a read-only observation of the live data
  # root.  Its artifact belongs to this run's temporary directory, never data.
  step feed-coverage swift "$ROOT/script/feed_coverage_eval.swift" --data-root "$ROOT/data" --days 7 --out "$OUT/feed-coverage.md"
  step full-swift-suite "$ROOT/script/test.sh" --require-ios
  if [ "$fails" = 0 ]; then
    step full-install-verified full_install_and_verify
  else
    # Accumulating diagnostics must not install a candidate whose prerequisite
    # checks failed or were interrupted. Keep their original failure count and
    # logs; this dependent action is blocked, never a successful skip.
    printf '[evals] BLOCKED: install requires every preceding full-mode check to pass (%s failure(s))\n' "$fails" \
      > "$OUT/full-install-verified.log"
    printf '  ✘ %-34s %4ss  → BLOCKED by failed prerequisites; %s\n' \
      "full-install-verified" 0 "$OUT/full-install-verified.log"
  fi
else
  test_step turn-replay        swift test --force-resolved-versions --skip-update --package-path "$ROOT" --filter "TurnReplayBench"
  test_step range-bench-L1     swift test --force-resolved-versions --skip-update --package-path "$ROOT" --filter "PersonalityRangeBench"
  test_step ledger-keeper      swift test --force-resolved-versions --skip-update --package-path "$ROOT" --filter "EvalCoverageLedger"
  test_step total-surface-contract swift test --force-resolved-versions --skip-update --package-path "$ROOT" --filter "TotalSurfaceContract"
fi
[ "$LIVE" = 1 ] && NATIVEAGENT_RANGE_BENCH_LIVE=1 NATIVEAGENT_RANGE_BENCH_PERSONA_ROOT="$ROOT/persona" test_step range-bench-live swift test --force-resolved-versions --skip-update --package-path "$ROOT" --filter "scenario2_theRange"
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
