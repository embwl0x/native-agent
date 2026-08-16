#!/usr/bin/env bash
# Compare the canonical release compiler mode with per-file -O compilation.
# This never edits Package.swift or adopts the experiment automatically: a
# compile/RSS win only makes the candidate eligible for separate runtime proof.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/build_source_inventory.sh
source "$ROOT/script/lib/build_source_inventory.sh"
JOBS=6
KEEP=false
for arg in "$@"; do
  case "$arg" in
    --jobs=*) JOBS="${arg#*=}" ;;
    --keep) KEEP=true ;;
    -h|--help)
      echo "Usage: $0 [--jobs=N] [--keep]"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be positive" >&2; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-compile-benchmark.XXXXXX")"
cleanup_benchmark() {
  if ! $KEEP && [[ "$SCRATCH" == "${TMPDIR:-/tmp}/nativeagent-release-compile-benchmark."* ]]; then
    find "$SCRATCH" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup_benchmark EXIT

START_DIGEST="$(nativeagent_source_state_digest "$ROOT")"
run_build() {
  local name="$1"; shift
  local scratch="$SCRATCH/$name" log="$SCRATCH/$name.log"
  mkdir -p "$scratch"
  echo "[compile-benchmark] $name"
  /usr/bin/time -l swift build \
    --package-path "$ROOT" \
    --scratch-path "$scratch" \
    -c release --jobs "$JOBS" "$@" \
    >"$log" 2>&1
  local elapsed rss bin bytes
  elapsed="$(awk '/^[[:space:]]*[0-9.]+ real/{print $1; exit}' "$log")"
  rss="$(awk '/maximum resident set size/{print $1; exit}' "$log")"
  bin="$(find "$scratch" -type f -path '*/release/NativeAgentApp' -print -quit)"
  [[ -n "$elapsed" && -n "$rss" && -f "$bin" ]] || {
    echo "[compile-benchmark] ERROR: incomplete metrics for $name; log: $log" >&2
    return 1
  }
  bytes="$(stat -f %z "$bin")"
  printf '%s\t%s\t%s\n' "$elapsed" "$rss" "$bytes" > "$SCRATCH/$name.metrics"
  printf '[compile-benchmark] %s wall=%ss peak_rss=%s bytes=%s\n' "$name" "$elapsed" "$rss" "$bytes"
}

run_build default
[[ "$(nativeagent_source_state_digest "$ROOT")" == "$START_DIGEST" ]] || {
  echo "[compile-benchmark] ERROR: source changed during default build; results invalid" >&2
  exit 1
}
run_build no_wmo -Xswiftc -no-whole-module-optimization
[[ "$(nativeagent_source_state_digest "$ROOT")" == "$START_DIGEST" ]] || {
  echo "[compile-benchmark] ERROR: source changed during no-WMO build; results invalid" >&2
  exit 1
}

IFS=$'\t' read -r default_wall default_rss default_bytes < "$SCRATCH/default.metrics"
IFS=$'\t' read -r candidate_wall candidate_rss candidate_bytes < "$SCRATCH/no_wmo.metrics"
if awk -v cw="$candidate_wall" -v dw="$default_wall" \
       -v cr="$candidate_rss" -v dr="$default_rss" \
       -v cb="$candidate_bytes" -v db="$default_bytes" \
       'BEGIN { exit !(cw <= dw * 1.05 && cr <= dr * 0.70 && cb <= db * 1.05) }'; then
  echo "[compile-benchmark] candidate passes build thresholds; DO NOT adopt until launch/runtime performance is separately proven"
else
  echo "[compile-benchmark] candidate rejected; canonical release compiler mode remains unchanged"
fi
$KEEP && echo "[compile-benchmark] retained evidence: $SCRATCH"
