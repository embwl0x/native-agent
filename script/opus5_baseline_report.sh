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
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-data/logs/opus5_baseline_$(date +%Y%m%d).txt}"
mkdir -p "$(dirname "$OUT")"
exec >"$OUT" 2>&1

echo "=== Opus 5 baseline — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "--- model actually serving turns (per surface, from traces)"
python3 - <<'PY'
import json, glob, collections
files = sorted(glob.glob('data/turn_traces/*.jsonl'))[-2:]
seen = collections.Counter()
for f in files:
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get('kind') == 'context.snapshot':
            seen[(r.get('surface'), r['payload'].get('model'))] += 1
for (surface, model), n in sorted(seen.items(), key=lambda kv: -kv[1]):
    print(f"  {surface or '?':10} {model or '?':22} {n} turns")
PY

echo
echo "--- memory circulation health (the variable that is NOT the model)"
python3 - <<'PY'
import json, glob
files = sorted(glob.glob('data/turn_traces/*.jsonl'))[-2:]
rows = []
for f in files:
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get('kind') == 'context.summary':
            c = r['payload']['counts']
            rows.append((r['ts'], c.get('contextFlow.memoryRecords'),
                         c.get('contextFlow.selectedAtoms'),
                         c.get('persona.docCount')))
print("  ts                    memRecords atoms personaDocs")
for ts, m, a, d in rows[-12:]:
    print(f"  {ts[:19]}  {str(m):>9} {str(a):>6} {str(d):>10}")
print(f"  (memRecords was 0 on EVERY turn 07-15..07-24 while the lane was dead)")
PY

echo
echo "--- memory actually being USED (use_count bumps prove circulation, not just presence)"
sqlite3 "file:data/memory/memory.sqlite?mode=ro" \
  "select 'active: '||count(*) from memories where status='active';
   select 'used in last 24h: '||count(*) from memories where last_used_at >= datetime('now','-1 day');
   select 'newest last_used_at: '||coalesce(max(last_used_at),'(none)') from memories;" 2>&1

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
[ -d data/dream_diary ] && echo "  dream_diary: $(ls -1 data/dream_diary | wc -l | tr -d ' ') entries, newest $(ls -t data/dream_diary | head -1)"
ls -t data/memory_proposals 2>/dev/null | grep -i dream | head -3 | sed 's/^/  dream-authored memory proposal: /'

echo
echo "--- morning brief card"
python3 - <<'PY'
import json
try:
    rows = [json.loads(l) for l in open('data/notifications/inbox.jsonl') if l.strip()]
except Exception as e:
    print("  (inbox unreadable:", e, ")")
    raise SystemExit
# Proven source values (verified 2026-07-24): the inbox writes
# 'trigger:morning_brief', NOT 'morning_brief' — the first cut matched the bare
# name and silently found nothing. Also capture the warmup + overnight cycles.
WANTED = ('trigger:morning_brief', 'agent_morning_warmup', 'dream_cycle', 'rem_cycle')
briefs = [r for r in rows if r.get('source') in WANTED]
if not briefs:
    print("  (no morning_brief card found)")
for b in briefs[-2:]:
    print(f"  {b.get('created_at')}  status={b.get('status')}  {b.get('title')}")
    print(f"    {(b.get('summary') or '')[:300]}")
PY

echo
echo "--- loop failures overnight (should be quiet: slack recycle + 120s duration floor)"
python3 - <<'PY'
import json
try:
    rows = [json.loads(l) for l in open('data/logs/background_loop_failures.jsonl') if l.strip()]
except Exception:
    rows = []
recent = [r for r in rows if (r.get('createdAt') or r.get('pushedAt') or '') >= '2026-07-24T20']
print(f"  {len(recent)} failure/push receipts since 20:00")
for r in recent[-8:]:
    print(f"    {r.get('createdAt') or r.get('pushedAt')}  {r.get('loopId')}  {r.get('kind')}  {str(r.get('error',''))[:70]}")
PY

echo
echo "=== end. Read with: cat $OUT"
