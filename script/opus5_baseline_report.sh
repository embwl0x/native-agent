#!/usr/bin/env bash
# Opus 5 + restored-memory-circulation baseline capture (2026-07-24).
#
# Two big variables changed within an hour of each other on 2026-07-24:
#   1. Agent's chat + telegram surfaces moved to claude-opus-5.
#   2. Memory circulation came back to life (ef83fa76 / 218fb021) after being
#      silently dead since 2026-07-15 — contextFlow.memoryRecords was 0 on every
#      turn for nine days, so NO memory reached the prompt via ContextFlow.
#
# Because both moved together, a felt difference CANNOT be attributed to the
# model. This script captures the objective side so the comparison is evidence,
# not vibes. It only READS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
OUT="${1:-data/logs/opus5_baseline_$(date +%Y%m%d).txt}"
mkdir -p "$(dirname "$OUT")"
exec >"$OUT" 2>&1

echo "=== Opus 5 baseline — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "--- model actually serving turns (per surface, from traces)"
swift "$SCRIPT_DIR/opus5_baseline_report.swift" models "$PWD"

echo
echo "--- memory circulation health (the variable that is NOT the model)"
swift "$SCRIPT_DIR/opus5_baseline_report.swift" circulation "$PWD"

echo
echo "--- memory actually being USED (use_count bumps prove circulation, not just presence)"
if [[ -f data/memory/memory.sqlite ]]; then
  sqlite3 "file:data/memory/memory.sqlite?mode=ro" \
    "select 'active: '||count(*) from memories where status='active';
     select 'used in last 24h: '||count(*) from memories where last_used_at >= datetime('now','-1 day');
     select 'newest last_used_at: '||coalesce(max(last_used_at),'(none)') from memories;"
else
  echo "  MISSING: data/memory/memory.sqlite"
fi

echo
# PROVEN PATHS ONLY (2026-07-24): the first cut of this script watched
# data/dreams/*.jsonl and data/logs/rem_*.jsonl — neither exists, so it
# reported "nothing" for a healthy system. Same class as watching a path that
# can never fire. These four were confirmed present before being wired in.
echo "--- overnight dream / REM consolidation"
for f in data/rem_proposals.jsonl data/rem_pins.json; do
  [ -f "$f" ] || { echo "  MISSING (was present 2026-07-24): $f"; continue; }
  echo "  $f: $(wc -l < "$f" | tr -d ' ') lines, modified $(stat -f%Sm "$f")"
done
if [[ -d data/dream_diary ]]; then
  echo "  dream_diary: $(ls -1 data/dream_diary | wc -l | tr -d ' ') entries, newest $(ls -t data/dream_diary | head -1)"
fi
if [[ -d data/memory_proposals ]]; then
  find data/memory_proposals -maxdepth 1 -type f -iname '*dream*' -print | head -3 | sed 's#^.*/#  dream-authored memory proposal: #'
fi

echo
echo "--- morning brief card"
swift "$SCRIPT_DIR/opus5_baseline_report.swift" morning-brief "$PWD"

echo
echo "--- loop failures overnight (should be quiet: slack recycle + 120s duration floor)"
swift "$SCRIPT_DIR/opus5_baseline_report.swift" loop-failures "$PWD"

echo
echo "=== end. Read with: cat $OUT"
