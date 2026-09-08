#!/usr/bin/env bash
# Shared by the canonical runner and its deterministic command fixtures.
if [[ -z "${GATE_LOGS:-}" ]]; then
  GATE_LOGS="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-gate.XXXXXX")"
  GATE_STARTED=$SECONDS
  GATE_PIDS=()
fi
GATE_POOL="${NATIVEAGENT_GATE_POOL:-4}"
[[ "$GATE_POOL" =~ ^[1-9][0-9]*$ ]] || { echo '[test] invalid gate pool' >&2; exit 2; }

gate_run() {
  local name="$1"; shift
  local started=$SECONDS rc=0
  local log="$GATE_LOGS/$name.log"
  # Each process gets its own fallback state root. Compiler caches remain shared.
  (
    export NATIVE_AGENT_DATA_ROOT="$GATE_LOGS/$name.data"
    mkdir -p "$NATIVE_AGENT_DATA_ROOT"
    "$@"
  ) > "$log" 2>&1 || rc=$?
  if [[ "$name" == Core-* && "$name" != Core-XCTest && "$rc" -eq 0 ]]; then
    if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed after' "$log"; then
      echo '[test] missing nonempty Swift Testing completion receipt' >> "$log"
      rc=1
    fi
  fi
  printf '%s\t%s\t%s\n' "$name" "$rc" "$((SECONDS - started))" > "$GATE_LOGS/$name.result"
  if [[ "$rc" -ne 0 ]]; then
    echo "[test] FAILED: $name (exit $rc)"
    cat "$log"
  else
    echo "[test] passed: $name ($((SECONDS - started))s)"
  fi
  # Keep collecting independent failures; gate_finish owns the final verdict.
}

gate_wait() {
  local pid
  for pid in ${GATE_PIDS[@]+"${GATE_PIDS[@]}"}; do wait "$pid"; done
  GATE_PIDS=()
}

gate_spawn() {
  gate_run "$@" &
  GATE_PIDS+=("$!")
  if [[ ${#GATE_PIDS[@]} -ge "$GATE_POOL" ]]; then gate_wait; fi
}

gate_finish() {
  gate_wait
  python3 - "$GATE_LOGS" "$((SECONDS - GATE_STARTED))" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
failed = 0
print('[test] summary: shard | pass | fail | skipped | wall seconds | result')
for result in sorted(root.glob('*.result')):
    name, rc, seconds = result.read_text().strip().split('\t')
    log = result.with_suffix('.log').read_text(errors='replace')
    passed = failures = skipped = 0
    measured = False
    # XCTest prints cumulative totals repeatedly; only its last total counts.
    totals = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', log)
    if totals:
        total, skipped, failures = (int(value or 0) for value in totals[-1])
        passed = total - failures - skipped
        measured = True
    swift = re.findall(r'Test run with (\d+) tests? .*?(?:passed|failed) after', log)
    if swift:
        swift_failed = len(re.findall(r'^✘ Test (?!run with ).* failed after', log, re.M))
        swift_skipped = len(re.findall(r'^➜ Test .* skipped', log, re.M))
        passed += int(swift[-1]) - swift_failed - swift_skipped
        failures += swift_failed
        skipped += swift_skipped
        measured = True
    node_pass = re.findall(r'^# pass (\d+)$', log, re.M)
    if node_pass:
        passed = int(node_pass[-1])
        failures = int(re.findall(r'^# fail (\d+)$', log, re.M)[-1])
        skipped = int(re.findall(r'^# skipped (\d+)$', log, re.M)[-1])
        measured = True
    ios = re.findall(r'\[test-ios\] counts: (\d+) passed, (\d+) failed, (\d+) skipped', log)
    if ios:
        passed, failures, skipped = map(int, ios[-1])
        measured = True
    failed += int(rc != '0')
    counts = f'{passed} | {failures} | {skipped}' if measured else '— | — | —'
    print(f'[test] {name} | {counts} | {seconds} | {"PASS" if rc == "0" else "FAIL (exit " + rc + ")"}')
print(f'[test] gate summary: {len(list(root.glob("*.result"))) - failed} passed shards/checks, {failed} failed; wall {sys.argv[2]}s')
print(f'[test] logs: {root}')
sys.exit(bool(failed))
PY
}
