#!/usr/bin/env bash
#
# agent_instrument_test.sh — hermetic assertions for script/agent_instrument.swift.
#
# Builds a tiny SYNTHETIC data root (never touches the real one) and pins the
# three properties the instrument exists for:
#
#   1. A lane that is zero for >= 3 days is flagged SUSPECT DORMANT.
#   2. A missing source is labelled "source absent" — never rendered as a zero.
#   3. The tool REFUSES to write inside the data root, and writes nothing there
#      even on a successful run (byte-for-byte mtime/size/inode proof).
#   4. The BOOM summary leads the report and every anchor it cites exists.
#   5. The reach walker names a PLANTED unknown feed as NOT COVERED.
#   6. The coverage matrix carries all 12 documented subsystems.
#   7. A stage whose clock is never written renders "dark", never "0 ms".
#
# Round 3 added the cases where the INSTRUMENT ITSELF could commit the silent
# zero it exists to catch:
#
#   8.  A corrupt sqlite store reads UNREADABLE, never "0 nodes"; exit stays 0.
#   9.  A WAL sidecar that cannot be copied is LOUD — a torn snapshot is never
#       queried quietly.
#   10. Malformed JSONL lines are counted and surfaced; an all-garbage feed is
#       UNREADABLE, while a lightly-damaged one still computes from good rows.
#   11. An --out that resolves into the data root through a SYMLINK is refused.
#   12. Store-derived text cannot inject markdown structure into the report.
#   13. A failed reach walk exits NONZERO — a vacuous coverage answer at exit 0
#       is indistinguishable from a clean bill of health.
#
# Round 4 closes the same three holes one level down, inside the SYS matrix:
#
#   14. PER-FEED absence inside a PARTIAL organ. The organ-level guard only
#       fires when every feed is blocked; a counter whose own feed is missing
#       must say "source absent" rather than render the 0 it was initialized to.
#   15. Manual DIRECTORY readers. A jobs/executions directory that exists and
#       cannot be listed — or whose files will not parse — is UNREADABLE and
#       wins the BOOM worst-organ line, never "present, 0 entries".
#   16. Equal-tick loops sort deterministically, so the "oldest tick" cell and
#       the SYS-02 severity reason cannot flap between runs over frozen bytes.
#
# Each assertion carries a negative control where one exists, so a passing test
# cannot be passing vacuously. Sections 5-7 and 8/10 additionally carry MUTATION
# tests: the tool is copied, deliberately broken, and the assertion must FAIL.
#
set -uo pipefail

TIMING_ONLY=0
if [[ "${1:-}" == --turn-timing-only && $# == 1 ]]; then
  TIMING_ONLY=1
elif [[ $# != 0 ]]; then
  echo "usage: $0 [--turn-timing-only]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/script/agent_instrument.swift"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent_instrument_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Compile ONCE and execute the binary everywhere below. Running the .swift
# file through the interpreter re-type-checked and re-compiled the whole
# instrument on each of the 53 invocations, which under concurrent build
# load turned this smoke into a 90-minute silent "hang" (2026-08-27, the
# B04 gate). One compile, then fast native runs.
TOOL_BIN="$TMP/agent_instrument.bin"
# These are tiny correctness fixtures. Optimizing this large source costs far
# more than it saves across the native runs; keep compilation unoptimized.
swiftc "$TOOL" -o "$TOOL_BIN" || exit 1

FAILURES=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

[ -f "$TOOL" ] || { echo "missing $TOOL"; exit 2; }

# Reproduce the canonical structured-tool-loop clock boundaries: context was
# built before the engine timer began, while all work ended before terminal.
TIMING_ROOT="$TMP/turn-timing"
mkdir -p "$TIMING_ROOT/turn_traces"
TIMING_DAY="$(date -u +%Y-%m-%d)"
cat > "$TIMING_ROOT/turn_traces/$TIMING_DAY.jsonl" <<JSON
{"kind":"turn.accepted","ts":"${TIMING_DAY}T00:00:00.000Z","turnId":"timing-probe","surface":"chat","payload":{}}
{"kind":"context.summary","ts":"${TIMING_DAY}T00:00:00.435Z","turnId":"timing-probe","surface":"chat","payload":{"totalMs":434}}
{"kind":"llm.call","ts":"${TIMING_DAY}T00:00:26.230Z","turnId":"timing-probe","surface":"chat","payload":{"durationMs":25632}}
{"kind":"tool.dispatch","ts":"${TIMING_DAY}T00:00:17.888Z","turnId":"timing-probe","surface":"chat","payload":{"phase":"end","durationMs":27,"status":"ok"}}
{"kind":"turn.terminal","ts":"${TIMING_DAY}T00:00:26.290Z","turnId":"timing-probe","surface":"chat","payload":{"schema":"metacognition.observed.v1","status":"completed","turnElapsedMs":25701}}
JSON
"$TOOL_BIN" --data-root "$TIMING_ROOT" --days 7 --out "$TMP/timing.md" > "$TMP/timing.log" 2>&1 || exit 1
grep -qF '26290 ms total' "$TMP/timing.md"
check "turn clock uses paired 26290ms lifecycle rather than 25701ms engine payload" $?
grep -qF '| terminal payload clock (not additive) | 25.701 |' "$TMP/timing.md"
check "engine payload remains separately observable" $?
! grep -qE 'stamp more work|need timing-scope attribution|terminal row closes while|split is meaningful' "$TMP/timing.md"
check "prebuilt assembly does not create a false timing inconsistency or partition" $?

for variant in fallback excess absent; do
  variant_root="$TMP/timing-$variant"
  mkdir -p "$variant_root/turn_traces"
  case "$variant" in
    fallback) expression='select(.kind != "turn.accepted")';;
    excess) expression='if .kind == "llm.call" then .payload.durationMs = 30000 else . end';;
    absent) expression='select(.kind != "turn.accepted" and .kind != "turn.terminal")';;
  esac
  jq -c "$expression" "$TIMING_ROOT/turn_traces/$TIMING_DAY.jsonl" > "$variant_root/turn_traces/$TIMING_DAY.jsonl"
  "$TOOL_BIN" --data-root "$variant_root" --days 7 --out "$TMP/timing-$variant.md" > "$TMP/timing-$variant.log" 2>&1 || exit 1
done
grep -qF '| paired accepted→terminal | source absent | source absent |' "$TMP/timing-fallback.md"
check "missing lifecycle pairing stays absent, not a zero or payload-derived wall clock" $?
grep -qF 'scope unknown fallback' "$TMP/timing-fallback.md"
check "payload-only latency explicitly declares its unknown scope" $?
! grep -q 'need timing-scope attribution' "$TMP/timing-fallback.md"
check "unknown-scope payload is not used to accuse overlapping work" $?
grep -qF 'paired lifecycle 26290 ms; model+tool+assembly sum 30461 ms; excess 4171 ms.' "$TMP/timing-excess.md"
check "real sum excess retains exact millisecond evidence without inventing its cause" $?
grep -qF 'A duration sum alone cannot prove post-terminal work' "$TMP/timing-excess.md"
check "sum excess reports an attribution question, not an unsupported runtime diagnosis" $?
grep -qF 'current end-to-end turn latency is unmeasured' "$TMP/timing-absent.md"
check "absent terminal and paired clocks remain unmeasured" $?
if [[ "$TIMING_ONLY" == 1 ]]; then
  [[ "$FAILURES" == 0 ]] || exit 1
  echo 'agent_instrument_test.sh: turn timing assertions passed'
  exit 0
fi

# ── Build the synthetic data root ────────────────────────────────────────────
ROOT="$TMP/data"
mkdir -p "$ROOT/turn_traces" "$ROOT/traces" "$ROOT/cognition"
# Deliberately NOT created, to exercise the absent-source path:
#   $ROOT/memory/memory.sqlite, $ROOT/desk/, $ROOT/notifications/,
#   $ROOT/orchestration/, $ROOT/dream_diary/

# Dates: today and the last 6 days, UTC.
day()  { date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }
inst() { date -u -v-"$1"d +%Y-%m-%dT12:00:00Z 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT12:00:00Z; }

# context.summary rows.
#   liveLane      — non-zero every day            → must be LIVE
#   dormantLane   — non-zero only 5 days ago      → must be SUSPECT DORMANT
#   neverLane     — zero on every single row      → must be SUSPECT DORMANT
#
# stageMs carries one LIVE stage and one DARK stage:
#   stageMs.liveStage   — always non-zero  → live, real p50/p95
#   stageMs.darkStage   — always exactly 0 → DARK, must never render as "0 ms"
# Note the deliberate SPACE after the colons: the real tracer writes
# `"phase": "end"`, and a byte-prefilter spelled without the space silently
# reads zero. The fixture keeps that shape so the tool cannot regress into it.
for d in 0 1 2 3 4 5; do
  TS="$(inst "$d")"
  F="$ROOT/turn_traces/$(day "$d").jsonl"
  if [ "$d" -ge 5 ]; then DORMANT=7; else DORMANT=0; fi
  for i in 1 2 3; do
    printf '{"kind": "context.summary", "ts": "%s", "turnId": "turn-%s-%d", "surface": "chat", "payload": {"counts": {"liveLane": %d, "dormantLane": %d, "neverLane": 0}, "flags": {"someFailure": 0}, "stageMs": {"liveStage": %d, "darkStage": 0}, "totalMs": %d}}\n' \
      "$TS" "$d" "$i" "$((i + 4))" "$DORMANT" "$((i * 10))" "$((i * 20))" >> "$F"
    # Lifecycle rows so the turn-speed section has an end-to-end clock.
    printf '{"kind": "turn.accepted", "ts": "%s", "turnId": "turn-%s-%d", "surface": "chat", "payload": {"milestone": "turn.accepted"}}\n' \
      "$TS" "$d" "$i" >> "$F"
    printf '{"kind": "turn.terminal", "ts": "%s", "turnId": "turn-%s-%d", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": %d}}\n' \
      "$TS" "$d" "$i" "$((1000 + i * 500))" >> "$F"
    printf '{"kind": "llm.call", "ts": "%s", "turnId": "turn-%s-%d", "surface": "chat", "payload": {"surface": "chat", "durationMs": %d, "ttftMs": %d, "model": "claude-opus-5"}}\n' \
      "$TS" "$d" "$i" "$((300 + i * 100))" "$((100 + i * 10))" >> "$F"
    printf '{"kind": "tool.dispatch", "ts": "%s", "turnId": "turn-%s-%d", "surface": "chat", "payload": {"name": "probe", "phase": "end", "durationMs": %d, "status": "ok"}}\n' \
      "$TS" "$d" "$i" "$((50 + i * 5))" >> "$F"
  done
  printf '{"kind": "context.snapshot", "ts": "%s", "surface": "chat", "payload": {"model": "claude-opus-5", "_truncated": true, "_originalBytes": 4096, "_preview": "{\\"cognitiveCapsuleBytes\\": 1100, \\"containsCognitiveSubstrate\\": true, \\"dynamicBytes\\": 900"}}\n' \
    "$TS" >> "$F"
  # One fully-shaped capsule makes anatomy rows executable: every gated line
  # must be distinct, and fingerprint dominance is by capsule presence.
  # The production writer splits at arbitrary character offsets. `Settling`
  # deliberately crosses two chunks: a reader that inserts a separator loses
  # the canonical marker and must fail the exact rate assertion below.
  printf '{"kind": "context.snapshot", "ts": "%s", "surface": "chat", "payload": {"cognitivePreview": ["[CognitiveSubstrate]\\nHow you feel:\\ncurious, curious, steady\\n- Set", "tling: still settling\\n- Sound: a few of the same words keep echoing lately\\n- Since: a recent turn"], "cognitiveTruncated": false, "cognitiveRedactedChars": 0}}\n' \
    "$TS" >> "$F"
done

# llm.call telemetry, including one substitutedFrom row.
{
  printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "claude-opus-5", "provider": "anthropic", "streaming": true, "inputTokens": 100, "outputTokens": 50, "durationMs": 1200, "ttftMs": 400}}\n' "$(inst 1)"
  printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "gpt-5.6-sol", "provider": "openai", "streaming": true, "inputTokens": 80, "outputTokens": 20, "durationMs": 900, "substitutedFrom": "gpt-5.5"}}\n' "$(inst 2)"
} > "$ROOT/traces/events.jsonl"

# A real sqlite cognition store with the live schema subset.
sqlite3 "$ROOT/cognition/cognition.sqlite" <<'SQL'
CREATE TABLE cognitive_nodes (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, subject_type TEXT NOT NULL,
  subject_id TEXT NOT NULL, subject_label TEXT, activation REAL NOT NULL,
  salience REAL NOT NULL, confidence REAL NOT NULL, source_class TEXT NOT NULL,
  created_at REAL NOT NULL, last_activated_at REAL NOT NULL, decay_half_life REAL NOT NULL,
  summary TEXT NOT NULL, metadata_json TEXT NOT NULL, updated_at REAL NOT NULL,
  emotional_valence REAL NOT NULL DEFAULT 0, emotional_arousal REAL NOT NULL DEFAULT 0,
  emotional_warmth REAL NOT NULL DEFAULT 0);
CREATE TABLE cognitive_artifacts (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
  score REAL NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE cognitive_receipts (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL);
INSERT INTO cognitive_nodes VALUES
 ('n1','conversationFocus','turn','t1','l',0.5,0.5,0.9,'chat',1000,1000,3600,'s',
  '{"eventKind":"userMessageReceived","memoryRecordIds":["m1","m2"]}',1000,0.2,0.3,0.4),
 ('n2','toolObservation','tool','t2','l',0.4,0.4,0.9,'tool',1000,1000,3600,'s',
  '{"eventKind":"toolSucceeded"}',1000,0,0,0);
INSERT INTO cognitive_artifacts VALUES
 ('a1','affect','current',0,'{"arousal":0.2,"uncertainty":0.1,"taskPressure":0.05,"socialWarmth":0.4}',1000,1000),
 ('a2','standing_view','active',0,'{}',1000,1000),
 ('a3','standing_view','proposed',0,'{}',1000,1000);
SQL

# Passive organism sampler: an old but well-formed row without the writer's
# lock marker is historical/inactive, not a failed resident lane.
printf '{"at":"%s","ok":true,"enabled":true,"signalCount":1,"posture":"baseline"}\n' \
  "$(inst 8)" > "$ROOT/cognition/organism_watch.jsonl"

# ── A PLANTED unknown subsystem ──────────────────────────────────────────────
# Stands in for "a new lane starts writing under the data root tomorrow". No
# reader in the instrument claims it, so the reach walker must name it. Written
# NOW, so it must also be marked ACTIVE. Two instance-named siblings prove the
# family aggregation collapses them into ONE feed rather than two blind spots.
mkdir -p "$ROOT/plantedsubsystem"
for i in 1 2 3 4 5; do
  printf '{"planted": true, "n": %d}\n' "$i" >> "$ROOT/plantedsubsystem/2026-08-20.jsonl"
done
printf '{"planted": true, "n": 99}\n' > "$ROOT/plantedsubsystem/2026-08-19.jsonl"

# ── The SYS organs (section (h)) ─────────────────────────────────────────────
# Minimal real-SHAPED feeds for SYS-02..SYS-08, so the system matrix has live
# readings to render. Three states are exercised deliberately:
#
#   SYS-01  ABSENT   — the bridge lanes live in ~/.config and the hermeticity
#                      gate keeps a synthetic root from reading machine-global
#                      state at all. Its row must say "source absent" and must
#                      NOT print jobs/undelivered/held counts of 0.
#   SYS-03/04/05     PARTIAL — some feeds present, some (task_ledger.jsonl,
#                      notifications/inbox.jsonl, memory.sqlite) deliberately
#                      still missing, because other assertions above pin those
#                      as absent.
#   SYS-02/06/07/08  MEASURED: loop failures and an unstamped GitHub watcher
#                      are faults; an old Workshop lease is only history.
mkdir -p "$ROOT/logs" "$ROOT/desk" "$ROOT/orchestration" "$ROOT/mobile_push" \
         "$ROOT/notifications" "$ROOT/icloud" "$ROOT/memory" "$ROOT/heartbeat" \
         "$ROOT/notify" "$ROOT/connectors/github" \
         "$ROOT/workshop/github_command" "$ROOT/workshop/reservation_claims" \
         "$ROOT/workshop/executions/8f14e45f-ceea-467a-9575-0e5e4ec1cbb1"

# SYS-02: one healthy loop, one 5-day-stale loop, one loop failing repeatedly.
printf '{"version": "1", "loops": {"healthyLoop": "%s", "staleLoop": "%s", "workshop_pump": "%s"}}\n' \
  "$(inst 0)" "$(inst 5)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ROOT/logs/background_loop_state.json"
: > "$ROOT/logs/background_loop_failures.jsonl"
for i in 1 2 3 4; do
  printf '{"kind": "failure", "loopId": "failingLoop", "createdAt": "%s", "error": "planted failure %d. detail"}\n' \
    "$(inst 1)" "$i" >> "$ROOT/logs/background_loop_failures.jsonl"
done
printf '{"kind": "failure_push", "pushedAt": "%s"}\n' "$(inst 1)" \
  >> "$ROOT/logs/background_loop_failures.jsonl"

# SYS-03: reduced ledger state + an outcome cursor + a desk archive.
# orchestration/task_ledger.jsonl stays ABSENT on purpose (section (d) pins it).
printf '{"generatedTs": "%s", "tasks": [{"status": "done", "updatedTs": "%s"}, {"status": "open", "updatedTs": "%s"}]}\n' \
  "$(inst 0)" "$(inst 1)" "$(inst 0)" > "$ROOT/orchestration/task_ledger_state.json"
printf '{"stores": {"plantedStore": {"carded_ids": ["c1", "c2"], "last_seen": "%s"}}}\n' \
  "$(inst 1)" > "$ROOT/logs/delegation_outcome_cursor.json"
printf '{"archivedAt": "%s", "id": "arch-1"}\n{"archivedAt": "%s", "id": "arch-2"}\n' \
  "$(inst 1)" "$(inst 2)" > "$ROOT/desk/desk_archive.jsonl"

# SYS-04: APNs receipts (one failed), a device token, iCloud chat receipts.
# notifications/inbox.jsonl stays ABSENT on purpose (section (d) pins it).
{
  printf '{"createdAt": "%s", "status": "ok", "tokenAgeSeconds": 86400}\n' "$(inst 1)"
  printf '{"createdAt": "%s", "status": "ok", "tokenAgeSeconds": 86400}\n' "$(inst 2)"
  printf '{"createdAt": "%s", "status": "failed", "error": "planted APNs rejection"}\n' "$(inst 1)"
} > "$ROOT/mobile_push/receipts.jsonl"
printf '{"tokens": [{"updatedAt": "%s"}]}\n' "$(inst 1)" > "$ROOT/notifications/push_tokens.json"
{
  printf '{"at": "%s", "status": "sent", "direction": "out", "signatureVerified": true}\n' "$(inst 1)"
  printf '{"at": "%s", "status": "sent", "direction": "out", "signatureVerified": true}\n' "$(inst 2)"
} > "$ROOT/icloud/chat_delivery_receipts.jsonl"

# SYS-05: housekeeping feeds WITHOUT memory.sqlite — the organ must read
# PARTIAL, and every store-backed number in its row must say "source absent".
printf '{"deletedAt": "%s", "id": "t1"}\n' "$(inst 2)" > "$ROOT/memory/tombstones.jsonl"
printf '{"event": "memory_hygiene_v2", "createdAt": "%s"}\n' "$(inst 2)" > "$ROOT/memory/provenance.jsonl"
printf '{"createdAt": "%s"}\n' "$(inst 2)" > "$ROOT/memory/consolidations.jsonl"
printf '{"id": "d1"}\n' > "$ROOT/memory/dedup_shadow.jsonl"
printf '{"status": "ok", "createdAt": "%s", "nextScheduled": "%s", "beforeCount": 10, "afterCount": 10}\n' \
  "$(inst 1)" "$(inst 0)" > "$ROOT/memory/hygiene_last_run.json"
printf '{"createdAt": "%s", "status": "ok"}\n' "$(inst 1)" > "$ROOT/memory/hygiene.jsonl"
mkdir -p "$ROOT/memory/backups/generation-1" "$ROOT/memory/backups/generation-2" "$ROOT/memory/repairs"
printf 'SQLite format 3\000' > "$ROOT/memory/backups/generation-1/memory.sqlite"
printf 'SQLite format 3\000' > "$ROOT/memory/backups/generation-2/memory.sqlite"
mkdir -p "$ROOT/skills"
printf '[{"id": "focused-reply", "name": "Focused reply", "status": "active", "updatedAt": "%s"}, {"name": "Legacy helper", "status": "draft", "createdAt": "%s"}]\n' \
  "$(inst 1)" "$(inst 2)" > "$ROOT/skills/registry.json"
printf '{"active_epoch": "planted-epoch-v1:abcdef", "at": "%s", "protected": true, "status": "current"}\n' \
  "$(inst 1)" > "$ROOT/memory/embedding_epoch_receipt.json"

# SYS-06: old consumed-window history with a recent canonical pump tick must
# retain the lease evidence without inventing a stopped-pump diagnosis.
LEASE_STALE="$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"acquiredAt": "%s", "holder": "workshop", "window": "planted-b0", "claims": [{"acquiredAt": "%s", "holder": "workshop", "window": "planted-b0"}]}\n' \
  "$LEASE_STALE" "$LEASE_STALE" > "$ROOT/workshop/background_lease.json"
printf '{"reservationId": "wres_planted_%s_%s-b0", "disposition": "progress", "status": "ok"}\n' \
  "$(day 1)" "$(day 1)" > "$ROOT/workshop/receipts.jsonl"
printf '{"status": "completed", "created_at": "%s", "id": "exec-1"}\n' "$(inst 1)" \
  > "$ROOT/workshop/executions/8f14e45f-ceea-467a-9575-0e5e4ec1cbb1/execution.json"
printf '{"claimedAt": "%s"}\n' "$(inst 1)" \
  > "$ROOT/workshop/reservation_claims/wres_planted_$(day 1)_$(day 1)-b0.claim"

# SYS-07: an ops ledger, tracked items, approvals, and a watcher snapshot with
# NO timestamp field — the "cycle age is unknowable" lead must fire. The
# compaction base is deliberately a minimal valid envelope: its payload is not
# rendered, only the read boundary's shape/size evidence is eligible.
{
  printf '{"at": "%s", "body": {"observed": {"key": "k1"}}}\n' "$(inst 1)"
  printf '{"at": "%s", "body": {"observed": {"key": "k2"}}}\n' "$(inst 2)"
} > "$ROOT/workshop/github_command/ops.jsonl"
printf '{"state": {"items": [], "dispatchedEventKeys": []}, "lastCompactedOpId": "op-1", "compactedAt": "%s", "compactedOpCount": 12, "tailFirstOpId": "op-2"}\n' \
  "$(inst 1)" > "$ROOT/workshop/github_command/ops_base.json"
printf '{"dispatchedEventKeys": ["k1"], "items": [{"observation": {"isOpen": true}, "notificationReceipts": ["r1"], "notificationClaims": ["c1"], "motorUpdatedAt": "%s"}]}\n' \
  "$(inst 1)" > "$ROOT/workshop/github_command/github_command_state.json"
printf '{"reviewStates": {"pr-1": "review_required"}}\n' > "$ROOT/notify/github_approvals.json"
printf '{"repos": {"a": 1}, "prs": {"b": 2}}\n' > "$ROOT/connectors/github/tracking_snapshot.json"

# SYS-08: a clean heartbeat.
printf '{"status": "ok", "condition_id": "ok", "last_tick_at": "%s", "next_tick_no_earlier_than": "%s", "issues": [], "cadence_seconds": 43200}\n' \
  "$(inst 0)" "$(inst 0)" > "$ROOT/heartbeat/status.json"

# ── The WAVE-2 SYS organs (SYS-09..14) ───────────────────────────────────────
# Same three-state discipline as wave 1:
#
#   SYS-09  MEASURED with a planted fault: one surface pinned to a provider that
#           has NO config file (the "pin cannot fire" lead), plus a PLANTED
#           SECRET inside a provider credential file that must never reach the
#           report — the secret-discipline allowlist is a security boundary and
#           gets a real assertion, not a comment.
#   SYS-10  MEASURED with a tool that fails more often than it succeeds.
#   SYS-11  MEASURED with a snapshot digest naming a file that is NOT cached and
#           an unanswered write-back transaction.
#   SYS-12  PARTIAL — `chat/pinned_session_ids.json` deliberately absent, so the
#           per-feed guard must render "source absent" for the pinned cell while
#           the rest of the organ measures. One in-window session has NO message
#           file, which must raise its own lead.
#   SYS-13  PARTIAL — `trust/policy.json` deliberately absent. One in-window
#           canary trip and one unanswered approval.
#   SYS-14  ABSENT — the update lane lives in the installed bundle and the app's
#           preferences domain, both machine-global. On a synthetic root the
#           hermeticity gate must keep them out and the row must print NO
#           version string.
mkdir -p "$ROOT/providers" "$ROOT/llm" "$ROOT/tools" "$ROOT/chat/archive" "$ROOT/chat/messages" \
         "$ROOT/mobile_snapshot_cache/snapshots" "$ROOT/mobile_snapshot_cache/responses" \
         "$ROOT/mobile_snapshot_cache/transactions/mac" "$ROOT/mobile" "$ROOT/public_sync" \
         "$ROOT/security" "$ROOT/workflows/approvals"

# SYS-09. `chat` is pinned to the model the traced calls really used (no drift);
# `dream` is pinned to `ghostprovider`, which has no config file at all.
PLANTED_SECRET='sk-planted-DO-NOT-PRINT-3f9a'
printf '{"chat": {"model": "claude-opus-5", "reasoningEffort": "high", "serviceTier": "default"}, "dream": {"model": "claude-x", "reasoningEffort": "medium", "serviceTier": "default"}}\n' \
  > "$ROOT/providers/surfaces.json"
printf '{"chat": "anthropic", "dream": "ghostprovider", "desk": "anthropic", "studio_wander": "anthropic", "cognition_cue": "anthropic", "old_surface": "anthropic"}\n' > "$ROOT/providers/active.json"
printf '{"auth_mode": "api_key", "default_model": "claude-opus-5", "api_key": "%s"}\n' "$PLANTED_SECRET" \
  > "$ROOT/providers/anthropic.json"
printf '{"auth_mode": "oauth", "default_model": "gpt-5.5", "access_token": "%s"}\n' "$PLANTED_SECRET" \
  > "$ROOT/providers/openai.json"
printf '{"status": "ok", "detail": "OK", "checkedAt": "%s"}\n' "$(inst 1)" \
  > "$ROOT/llm/provider_status.json"

# SYS-10. `tool.dispatch` rows in the EVENTS feed (the turn traces carry their
# own; this organ reads `traces/events.jsonl`). `flakytool` has eleven calls:
# four failures and seven successes.  It crosses both the ≥10-call per-tool
# envelope and the overall 25% failure ceiling without relying on a tiny-sample
# exception.
{
  cat "$ROOT/traces/events.jsonl"
  printf '{"kind": "tool.dispatch", "createdAt": "%s", "status": "ok", "title": "goodtool", "payload": {"surface": "chat", "durationMs": 12, "receipt": {"target": "goodtool", "decision": "attempted", "outcome": "completed", "permanence": "unknown"}}}\n' "$(inst 1)"
  for i in 1 2 3 4; do
    printf '{"kind": "tool.dispatch", "createdAt": "%s", "status": "failed", "title": "flakytool", "payload": {"surface": "chat", "durationMs": %d, "receipt": {"target": "flakytool", "decision": "attempted", "outcome": "failed", "errorClass": "tool_failed", "errorDetail": "status=failed | planted_reason_%d", "permanence": "unknown"}}}\n' "$(inst 1)" "$((10 + i))" "$(( i % 2 ))"
  done
  for i in 1 2 3 4 5 6 7; do
    printf '{"kind": "tool.dispatch", "createdAt": "%s", "status": "ok", "title": "flakytool", "payload": {"surface": "chat", "durationMs": 9, "receipt": {"target": "flakytool", "decision": "attempted", "outcome": "completed", "permanence": "unknown"}}}\n' "$(inst 1)"
  done
  printf '{"kind": "tool.preload", "createdAt": "%s", "status": "ok", "title": "delegation", "payload": {"groups": ["delegation"], "surface": "chat"}}\n' "$(inst 1)"
} > "$TMP/events_with_tools.jsonl"
mv "$TMP/events_with_tools.jsonl" "$ROOT/traces/events.jsonl"
printf '[{"id": "goodtool", "installed": true}, {"id": "flakytool", "installed": false}]\n' \
  > "$ROOT/tools/registry.json"
mkdir -p "$ROOT/tools/active/goodtool" "$ROOT/tools/proposals" "$ROOT/tools/quarantine"

# SYS-11. `missingsnapshot.json` is named by the digest map and is NOT cached.
printf '["id-1", "id-2", "id-3"]\n' > "$ROOT/icloud/processed_ids.json"
printf '{"desk.json": "aaaa", "missingsnapshot.json": "bbbb"}\n' > "$ROOT/icloud/snapshot_digests.json"
printf '[{"id": "d1"}]\n' > "$ROOT/mobile_snapshot_cache/snapshots/desk.json"
printf '{"n": 1}\n' > "$ROOT/mobile_snapshot_cache/snapshots/health.json"
printf '{"eventId": "e1", "channel": "apns", "status": "ok"}\n' \
  > "$ROOT/mobile_snapshot_cache/responses/resp-1.json"
printf '{"id": "tx-1", "direction": "ios_to_mac", "attempts": 1, "createdAt": "%s", "response": {"status": "ok"}}\n' \
  "$(inst 1)" > "$ROOT/mobile_snapshot_cache/transactions/mac/tx-1.json"
printf '{"id": "tx-2", "direction": "ios_to_mac", "attempts": 3, "createdAt": "%s"}\n' \
  "$(inst 1)" > "$ROOT/mobile_snapshot_cache/transactions/mac/tx-2.json"
printf '{"channel": "inbox_action", "eventID": "e9", "observedAt": "%s", "peerCreatedAt": "%s"}\n' \
  "$(inst 1)" "$(inst 1)" > "$ROOT/mobile/signed_peer_evidence.json"
printf '{"version": 1, "result": "failed", "stage": "verify", "exit_code": 3, "recorded_at": "%s"}\n' \
  "$(inst 1)" > "$ROOT/public_sync/last_status.json"
printf '[{"deviceId": "dev-1", "token": "%s", "updatedAt": "%s"}]\n' "$PLANTED_SECRET" "$(inst 1)" \
  > "$ROOT/mobile_push/tokens.json"

# SYS-12. `sess-live` has a transcript; `sess-orphan` is in the window and has
# none — the index-row-without-transcript lead must fire.
# chat/pinned_session_ids.json is DELIBERATELY absent → the organ reads PARTIAL.
printf '[{"id": "sess-live", "source": "app", "createdAt": "%s", "updatedAt": "%s", "messageCount": 3, "archived": false}, {"id": "sess-orphan", "source": "telegram", "createdAt": "%s", "updatedAt": "%s", "messageCount": 9, "archived": false}]\n' \
  "$(inst 5)" "$(inst 1)" "$(inst 4)" "$(inst 1)" > "$ROOT/chat/sessions.json"
{
  printf '{"id": "m1", "role": "user", "source": "app", "createdAt": "%s"}\n' "$(inst 1)"
  printf '{"id": "m2", "role": "assistant", "source": "app", "createdAt": "%s"}\n' "$(inst 1)"
  printf '{"id": "m3", "role": "user", "source": "telegram", "createdAt": "%s"}\n' "$(inst 40)"
} > "$ROOT/chat/messages/sess-live.jsonl"
# Canonical transcripts deliberately absent from sessions.json: SYS-12 must
# discover the directory population directly. The first proves strict durable
# transcript adjacency promotes reaction only; the second proves a structured
# feedback receipt does the same. The other five dimensions remain dark.
{
  printf '{"id":"request-dark","role":"user","sessionId":"unindexed-dark","runId":"run-dark","createdAt":"%s"}\n' "$(inst 1)"
  printf '{"id":"m-dark","role":"assistant","sessionId":"unindexed-dark","runId":"run-dark","content":"dark","createdAt":"%s","metadata":{"outcomeObservation":{"schema":"response.outcome-observation.v2","messageID":"m-dark","sessionID":"unindexed-dark","turnID":"turn-dark","dimensionStates":{"responsePersistence":"unknown","context":"unknown","provider":"unknown","tools":"unknown","motor":"unknown","reaction":"unknown"}}}}\n' "$(inst 1)"
  printf '{"id":"next-dark","role":"user","sessionId":"unindexed-dark","runId":"run-next","createdAt":"%s"}\n' "$(inst 1)"
} > "$ROOT/chat/messages/unindexed-dark.jsonl"
printf '{"id":"m-feedback","role":"assistant","sessionId":"unindexed-feedback","runId":"run-feedback","content":"feedback","createdAt":"%s","metadata":{"outcomeObservation":{"schema":"response.outcome-observation.v2","messageID":"m-feedback","sessionID":"unindexed-feedback","turnID":"turn-feedback","dimensionStates":{"responsePersistence":"unknown","context":"unknown","provider":"unknown","tools":"unknown","motor":"unknown","reaction":"unknown"}}}}\n' \
  "$(inst 1)" > "$ROOT/chat/messages/unindexed-feedback.jsonl"
mkdir -p "$ROOT/context"
printf '{"schema":"response.feedback.v2","sessionId":"unindexed-feedback","messageId":"m-feedback","turnId":"turn-feedback","reaction":"thumbs_up"}\n' \
  > "$ROOT/context/feedback.jsonl"
printf '{"id": "sess-old", "archivedAt": "%s"}\n' "$(inst 40)" > "$ROOT/chat/archive/sessions.jsonl"
printf '{"lastTurnAt": "%s", "state": "idle"}\n' "$(inst 1)" > "$ROOT/chat/mac_turn_lifecycle.json"

# SYS-15: the actual persisted research boundary. The configuration says only
# that a base URL was supplied; the completed lab run and separately retained
# search receipt prove the other two evidence paths were read.
mkdir -p "$ROOT/research/lab"
printf '{"searxng_base_url": "http://research-fixture.invalid"}\n' > "$ROOT/research/config.json"
printf '[{"id": "lab-ok", "objective": "fixture", "status": "completed", "createdAt": "%s", "connector": "searxng"}]\n' \
  "$(inst 1)" > "$ROOT/research/lab/runs.json"
printf '{"id": "11111111-1111-4111-8111-111111111111", "query": "fixture", "results": [], "createdAt": "%s"}\n' \
  "$(inst 1)" > "$ROOT/research/11111111-1111-4111-8111-111111111111.json"

# SYS-16: canonical BrowserOperationStore lifecycle evidence. The 200-row
# production retention ceiling has no eviction headroom; its first row is both
# a stranded `running` lifecycle and an old, still-unprojected transition.
mkdir -p "$ROOT/native_power/browser"
{
  printf '['
  for i in $(seq 1 200); do
    if [ "$i" -eq 1 ]; then
      printf '{"id":"browser-stranded","status":"running","createdAt":"%s","updatedAt":"%s","projectionOutbox":[{"id":"projection-stranded","run":{}}]}' \
        "$(inst 2)" "$(inst 2)"
    else
      printf '{"id":"browser-%03d","status":"succeeded","createdAt":"%s","updatedAt":"%s"}' \
        "$i" "$(inst 0)" "$(inst 0)"
    fi
    [ "$i" -lt 200 ] && printf ','
  done
  printf ']\n'
} > "$ROOT/native_power/browser/runs.json"
printf '{"id":"browser-receipt","status":"succeeded","createdAt":"%s"}\n' "$(inst 1)" \
  > "$ROOT/native_power/browser/receipts.jsonl"

# SYS-13. One allowed call, one refused; one in-window canary trip; one
# unanswered approval and one resolved 2h later.
# trust/policy.json is DELIBERATELY absent → the organ reads PARTIAL.
{
  printf '{"allowed": true, "decision": "allow", "risk": "low", "autonomy_level": "auto", "tool": "read_file", "created_at": "%s", "requires_approval": false, "origin_trusted": true}\n' "$(inst 1)"
  printf '{"allowed": false, "decision": "block", "risk": "critical", "autonomy_level": "auto", "tool": "flakytool", "created_at": "%s", "requires_approval": true, "origin_trusted": false, "reasons": ["planted policy refusal"]}\n' "$(inst 1)"
} > "$ROOT/security/audit.jsonl"
printf '{"at": "%s", "kind": "arg_validator_block", "tool_name": "bash", "reason": "planted canary"}\n' \
  "$(inst 1)" > "$ROOT/security/canary_trips.jsonl"
printf '{"calendar": {"read": true, "write": false}, "mail": {"read": true, "write": true}}\n' \
  > "$ROOT/security/mac_integration_permissions.json"
mkdir -p "$ROOT/security/autonomy_promotion"
printf '%s' "$(inst 1)" > "$ROOT/security/autonomy_promotion/last_scan"
RESOLVED_AT="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
CREATED_AT="$(date -u -v-26H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '26 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '[{"id": "ap-1", "action": "bash", "createdAt": "%s", "resolvedAt": "%s", "decision": "approved", "status": "resolved"}, {"id": "ap-2", "action": "bash", "createdAt": "%s", "decision": null, "status": "pending"}]\n' \
  "$CREATED_AT" "$RESOLVED_AT" "$(inst 1)" > "$ROOT/workflows/approvals/requests.json"
printf '{"schema": "approval-effect-spend.v1", "spends": {"e1": {"action": "bash", "spentAt": "%s"}}}\n' \
  "$(inst 1)" > "$ROOT/workflows/approvals/effect_spends.json"
printf '{"id": "mc-1", "category": "applescript", "executed_at": "%s", "exit_code": 0, "blocked": false}\n' \
  "$(inst 1)" > "$ROOT/mac_control_audit.jsonl"

# Workflow run-ledger family: its registry, append history, and relaunch state
# must be reported together. The stale state is intentional adverse evidence.
mkdir -p "$ROOT/workflows/run_state"
printf '[{"id":"flow-ok","status":"active","steps":[{"kind":"trace"}]},{"id":"flow-retired","status":"active","steps":[{"kind":"retired_kind"}]}]\n' \
  > "$ROOT/workflows/registry.json"
{
  printf '{"id":"wf-succeeded","status":"succeeded","createdAt":"%s"}\n' "$(inst 2)"
  printf '{"id":"wf-waiting","status":"waiting_approval","createdAt":"%s"}\n' "$(inst 1)"
  printf '{"id":"wf-refused","status":"failed","createdAt":"%s"}\n' "$(inst 0)"
} > "$ROOT/workflows/runs.jsonl"
printf '{"id":"wf-stranded","status":"running"}\n' > "$ROOT/workflows/run_state/wf-stranded.json"
touch -t 202001010000 "$ROOT/workflows/run_state/wf-stranded.json"
printf '{"id":"wf-approval-history","status":"waiting_approval","activeStepAttempt":null}\n' > "$ROOT/workflows/run_state/wf-approval-history.json"
printf '{"id":"wf-dispatch-intent","status":"running","activeStepAttempt":{"id":"attempt-1","phase":"dispatch_intent_persisted"}}\n' > "$ROOT/workflows/run_state/wf-dispatch-intent.json"
touch -t 202001010000 "$ROOT/workflows/run_state/wf-approval-history.json" "$ROOT/workflows/run_state/wf-dispatch-intent.json"

# ── 1. Happy path: run and capture ───────────────────────────────────────────
echo "==> running instrument against the synthetic root"
REPORT="$TMP/report.md"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --out "$REPORT" > "$TMP/stdout.md" 2> "$TMP/stderr.txt"
RC=$?
check "exits 0 on a valid synthetic root (rc=$RC)" "$([ $RC -eq 0 ] && echo 0 || echo 1)"
[ $RC -eq 0 ] || { sed -n '1,40p' "$TMP/stderr.txt"; }
check "writes the --out report" "$([ -s "$REPORT" ] && echo 0 || echo 1)"
# A changed model setting must not accuse calls made before the change.
PIN_ROOT="$TMP/pin-epoch-root"
cp -R "$ROOT" "$PIN_ROOT"
printf '{"kind":"context.summary","ts":"%s","turnId":"sub-ms-admission","surface":"chat","payload":{"stageMs":{"contextFlow.attention.actorAdmission":0}}}\n' "$(inst 0)" >> "$PIN_ROOT/turn_traces/$(day 0).jsonl"
printf '{"chat":{"model":"newly-selected-model"}}\n' > "$PIN_ROOT/providers/surfaces.json"
touch -t 209901010000 "$PIN_ROOT/providers/surfaces.json" "$PIN_ROOT/providers/active.json"
"$TOOL_BIN" --data-root "$PIN_ROOT" --days 7 --out "$TMP/new-pin.md" >/dev/null 2>&1
grep -q 'never used their pinned model' "$TMP/new-pin.md"
check "historical calls do not accuse a newly changed model pin" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'stageMs.contextFlow.attention.actorAdmission` is DARK' "$TMP/new-pin.md"
check "sub-ms actor-free attention admission is not a broken-clock lead" "$([ $? -ne 0 ] && echo 0 || echo 1)"
touch -t 202001010000 "$PIN_ROOT/providers/surfaces.json" "$PIN_ROOT/providers/active.json"
"$TOOL_BIN" --data-root "$PIN_ROOT" --days 7 --out "$TMP/old-pin.md" >/dev/null 2>&1
grep -q 'never used their pinned model' "$TMP/old-pin.md"
check "calls after a stable mismatched pin still raise drift" $?
grep -q '^### Workflow run ledger' "$REPORT"
check "workflow run ledger renders a real three-source section" $?
grep -qF 'retired\_kind=1' "$REPORT"
check "workflow registry reports a kind the real executor cannot run" $?
grep -qF 'waiting\_approval=1' "$REPORT"
check "workflow run ledger retains an approval-waiting state" $?
grep -qF 'failed=1' "$REPORT"
check "workflow run ledger retains a refused terminal outcome" $?
grep -qF 'other non-terminal state ids unchanged >1h: `wf-stranded`' "$REPORT"
check "workflow file age with no attempt remains unknown, not proven in flight" $?
grep -qF 'approval wait ids unchanged >1h, no persisted active attempt: `wf-approval-history`' "$REPORT"
check "old approval-only workflow stays distinct from dispatch evidence" $?
grep -qF 'persisted attempt ids unchanged >1h: `wf-dispatch-intent`' "$REPORT"
check "old dispatch intent still requires canonical outcome reconciliation" $?
grep -qF 'exceeded the 1h drain window' "$REPORT"
check "NEGATIVE CONTROL: file age does not invent a workflow drain deadline" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 2. Dormant lane is flagged ───────────────────────────────────────────────
echo "==> (a) dormant-lane detection"
grep -q 'SUSPECT DORMANT' "$REPORT"
check "report contains a SUSPECT DORMANT section" $?
grep -q 'counts.dormantLane' "$REPORT"
check "the 5-day-stale lane appears at all" $?
# It must appear in the dormant table, not the live table: assert it is listed
# ABOVE the '### Live lanes' heading.
awk '/^### SUSPECT DORMANT/{f=1} /^### Live lanes/{f=0} f' "$REPORT" | grep -q 'counts.dormantLane'
check "5-day-stale lane is inside the DORMANT section" $?
awk '/^### SUSPECT DORMANT/{f=1} /^### Live lanes/{f=0} f' "$REPORT" | grep -q 'counts.neverLane'
check "always-zero lane is inside the DORMANT section" $?
# Negative control: the healthy lane must NOT be flagged dormant.
awk '/^### SUSPECT DORMANT/{f=1} /^### Live lanes/{f=0} f' "$REPORT" | grep -q 'counts.liveLane'
check "NEGATIVE CONTROL: healthy lane is NOT in the DORMANT section" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^### Live lanes/{f=1} /^## \(b\)/{f=0} f' "$REPORT" | grep -q 'counts.liveLane'
check "healthy lane IS in the Live lanes section" $?
# Zero-is-healthy flags are excluded by name rather than flagged.
grep -q 'flags.someFailure' "$REPORT"
check "zero-is-healthy flag is still reported (not silently dropped)" $?
awk '/^### SUSPECT DORMANT/{f=1} /^### ABSENT FROM WINDOW|^### Zero-is-healthy|^### Live lanes/{f=0} f' "$REPORT" \
  | grep -q 'flags.someFailure'
check "NEGATIVE CONTROL: zero-is-healthy flag is NOT flagged dormant" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# The dormant finding must reach the LEADS section with evidence.
awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" | grep -q 'counts.dormantLane'
check "dormant lane produces a ranked LEAD" $?
awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" | grep -q '\*\*evidence:\*\*'
check "leads carry an evidence citation" $?

# ── 2b. Organism watch is a dated sampler, never a zero activity counter ───
echo "==> (a.1) organism-watch sampler freshness"
awk '/^### Organism watch sampler/{f=1} /^### Somatic signals/{f=0} f' "$REPORT" > "$TMP/organism-watch.md"
grep -q 'HISTORICAL / INACTIVE sampler' "$TMP/organism-watch.md"
check "old organism-watch rows without a run marker are labelled historical/inactive" $?
grep -q 'run marker: \*\*absent' "$TMP/organism-watch.md"
check "inactive organism watch names the missing explicit run marker" $?
grep -q '1 / 10000' "$TMP/organism-watch.md"
check "organism watch reports its retained-row bound" $?
! awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" | grep -q 'organism_watch.jsonl` is DORMANT'
check "historical organism watch does not produce a current-failure lead" $?

# Negative control: a current sample with the writer's explicit marker must be
# ACTIVE, not merely a present historical file.
printf '{"at":"%s","ok":true,"enabled":true,"signalCount":1,"posture":"baseline"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ROOT/cognition/organism_watch.jsonl"
mkdir "$ROOT/cognition/organism_watch.jsonl.lock"
WATCH_FRESH_REPORT="$TMP/organism-watch-fresh.md"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --out "$WATCH_FRESH_REPORT" > /dev/null 2>&1
awk '/^### Organism watch sampler/{f=1} /^### Somatic signals/{f=0} f' "$WATCH_FRESH_REPORT" > "$TMP/organism-watch-fresh-section.md"
grep -q 'ACTIVE sampler' "$TMP/organism-watch-fresh-section.md"
check "NEGATIVE CONTROL: a current sample with the explicit marker is ACTIVE" $?
grep -q 'DORMANT sampler' "$TMP/organism-watch-fresh-section.md"
check "NEGATIVE CONTROL: current organism-watch sample is not DORMANT" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 3. Absent sources are labelled absent, never zero ────────────────────────
echo "==> (b) absent-source labelling"
grep -q 'source absent' "$REPORT"
check "report uses the 'source absent' label" $?
# memory.sqlite was never created — its section must say absent, not print zeros.
awk '/^## \(c\) Memory performance/{f=1} /^### Memory-record stamps/{f=0} f' "$REPORT" \
  | grep -q 'source absent'
check "missing memory.sqlite renders 'source absent' in section (c)" $?
awk '/^## \(c\) Memory performance/{f=1} /^### Memory-record stamps/{f=0} f' "$REPORT" \
  | grep -qE '\| memories \(total / active\) \| 0 / 0 \|'
check "NEGATIVE CONTROL: missing memory store does NOT print '0 / 0' memories" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# desk/, notifications/, orchestration/, dream_diary/ are absent too.
grep -q 'desk/desk_ops.jsonl` | \*\*NO\*\*' "$REPORT"
check "sources table marks desk_ops.jsonl as NOT present" $?
awk '/^## \(d\) Desk, delegation/{f=1} /^## \(e\)/{f=0} f' "$REPORT" | grep -c 'source absent' > "$TMP/n"
[ "$(cat "$TMP/n")" -ge 3 ]
check "section (d) labels its 3+ absent sources (got $(cat "$TMP/n"))" $?
# And the present sources are actually measured — proves the absent path is not
# swallowing everything.
grep -q 'substitutedFrom' "$REPORT" && grep -q 'gpt-5.5 → gpt-5.6-sol' "$REPORT"
check "present llm.call source IS measured (substitution detected)" $?
grep -q 'nodes stamped with `memoryRecordIds`: \*\*1\*\*' "$REPORT"
check "cognition sqlite copy is queried (1 stamped node)" $?

# ── 3b. Learned Desk cadence is read, freshened, and bounded ────────────────
# The learner's cross-process store used to be a reach-walk blind spot.  This
# fixture supplies both live desk work and three confident stats: one naturally
# inside the bounds, one clamped at each bound.  The assertions pin the reader
# to the production wire shape rather than a made-up aggregate.
echo "==> (b2) learned Desk cadence"
CADENCE_ROOT="$TMP/data_cadence"
mkdir -p "$CADENCE_ROOT/desk"
printf '{"ts":"%s","op":"create_item"}\n' "$(inst 0)" > "$CADENCE_ROOT/desk/desk_ops.jsonl"
printf '{"version":1,"refs":{"floor":{"refKey":"floor","firstObservedAt":"%s","lastObservedAt":"%s","lastChangeAt":"%s","observations":9,"changes":3,"ewmaChangeIntervalSec":1200.0},"nominal":{"refKey":"nominal","firstObservedAt":"%s","lastObservedAt":"%s","lastChangeAt":"%s","observations":9,"changes":3,"ewmaChangeIntervalSec":7200.0},"ceiling":{"refKey":"ceiling","firstObservedAt":"%s","lastObservedAt":"%s","lastChangeAt":"%s","observations":9,"changes":3,"ewmaChangeIntervalSec":200000.0}}}\n' \
  "$(inst 0)" "$(inst 0)" "$(inst 0)" \
  "$(inst 0)" "$(inst 0)" "$(inst 0)" \
  "$(inst 0)" "$(inst 0)" "$(inst 0)" > "$CADENCE_ROOT/desk/cadence_stats.json"
CADENCE_REPORT="$TMP/cadence.md"
"$TOOL_BIN" --data-root "$CADENCE_ROOT" --days 7 --out "$CADENCE_REPORT" > /dev/null 2>&1
CRC=$?
[ "$CRC" -eq 0 ]
check "cadence fixture runs (rc=$CRC)" $?
awk '/^### Learned Desk cadence/{f=1} /^### Desk backlog/{f=0} f' "$CADENCE_REPORT" > "$TMP/cadence_section.md"
grep -qF 'tracked refs: **3** · confident learned intervals: **3**' "$TMP/cadence_section.md"
check "cadence reader reports per-ref samples as three confident learned intervals" $?
grep -qF 'observations across refs: **27** · recorded changes: **9**' "$TMP/cadence_section.md"
check "cadence reader totals persisted per-ref observation and change samples" $?
grep -qF 'intervals pinned at a learner bound: **1** at 15m floor · **1** at 24h ceiling' "$TMP/cadence_section.md"
check "cadence reader detects both learner clamp bounds" $?
grep -qF 'newest observation: **' "$TMP/cadence_section.md"
check "cadence reader renders the newest per-ref observation stamp" $?
awk '/^## \(j\) LEADS/{f=1} f' "$CADENCE_REPORT" | grep -q 'Desk cadence learner is pinned at a timing bound'
check "pinned cadence stats raise a Desk timing lead" $?

# A stale stats file is only a defect when Desk work is still happening.  This
# separate root is the negative counterpart to the fresh fixture above.
STALE_CADENCE_ROOT="$TMP/data_cadence_stale"
mkdir -p "$STALE_CADENCE_ROOT/desk"
printf '{"ts":"%s","op":"create_item"}\n' "$(inst 0)" > "$STALE_CADENCE_ROOT/desk/desk_ops.jsonl"
printf '{"version":1,"refs":{"stale":{"refKey":"stale","firstObservedAt":"%s","lastObservedAt":"%s","lastChangeAt":"%s","observations":2,"changes":0}}}\n' \
  "$(inst 6)" "$(inst 6)" "$(inst 6)" > "$STALE_CADENCE_ROOT/desk/cadence_stats.json"
STALE_CADENCE_REPORT="$TMP/cadence_stale.md"
"$TOOL_BIN" --data-root "$STALE_CADENCE_ROOT" --days 1 --out "$STALE_CADENCE_REPORT" > /dev/null 2>&1
awk '/^## \(j\) LEADS/{f=1} f' "$STALE_CADENCE_REPORT" | grep -q 'Desk cadence stats stopped updating while desk work continued'
check "in-window Desk work plus stale cadence stats raises the freshness lead" $?

# ── 3c. Canonical trigger claim state (never the legacy inbox copy) ─────────
# The `inbox/` state file remains on disk after migration.  Give it an
# intentionally different, future-stamped name: only a reader anchored to the
# canonical `triggers/` path can render the correct two claims below.
echo "==> (b3) canonical trigger claim state"
TRIGGER_ROOT="$TMP/data_trigger_state"
mkdir -p "$TRIGGER_ROOT/triggers" "$TRIGGER_ROOT/inbox"
printf '[{"name":"canonical-now","kind":"time","enabled":true,"config":{"hour":8,"minute":0}},{"name":"disabled","kind":"time","enabled":false,"config":{"hour":8,"minute":0}}]\n' \
  > "$TRIGGER_ROOT/triggers/trigger_config.json"
printf '{"canonical-now":{"last_fired_at":"%s"},"canonical-unstamped":{}}\n' "$(inst 0)" \
  > "$TRIGGER_ROOT/triggers/trigger_state.json"
printf '{"legacy-only":{"last_fired_at":"2099-01-01T00:00:00Z"}}\n' \
  > "$TRIGGER_ROOT/inbox/trigger_state.json"
TRIGGER_REPORT="$TMP/trigger_state.md"
"$TOOL_BIN" --data-root "$TRIGGER_ROOT" --days 7 --out "$TRIGGER_REPORT" > /dev/null 2>&1
TRC=$?
[ "$TRC" -eq 0 ]
check "canonical trigger-state fixture runs (rc=$TRC)" $?
awk '/^### Trigger scheduler claim state/{f=1} /^### Desk backlog/{f=0} f' "$TRIGGER_REPORT" > "$TMP/trigger_state_section.md"
grep -qF 'canonical state entries: **2** · usable `last_fired_at` stamps: **1**' "$TMP/trigger_state_section.md"
check "trigger-state reader reports canonical entry and stamp counts" $?
grep -qF '| `canonical-now` |' "$TMP/trigger_state_section.md" && grep -qF '| `canonical-unstamped` | unknown | unknown |' "$TMP/trigger_state_section.md"
check "trigger-state reader renders canonical per-trigger claim stamps" $?
grep -qF 'legacy-only' "$TMP/trigger_state_section.md"
check "NEGATIVE CONTROL: legacy inbox claim is never rendered as canonical state" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF '2099-01-01' "$TRIGGER_REPORT"
check "NEGATIVE CONTROL: the frozen legacy timestamp cannot satisfy liveness" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# A real enabled time trigger that has previously claimed an occurrence but
# has not advanced for >36h is a scheduler liveness finding, not just a quiet
# state file.  The separate root makes the time-bound branch executable.
STALE_TRIGGER_ROOT="$TMP/data_trigger_state_stale"
mkdir -p "$STALE_TRIGGER_ROOT/triggers"
printf '[{"name":"daily","kind":"time","enabled":true,"config":{"hour":8,"minute":0}}]\n' \
  > "$STALE_TRIGGER_ROOT/triggers/trigger_config.json"
printf '{"daily":{"last_fired_at":"%s"}}\n' "$(inst 3)" \
  > "$STALE_TRIGGER_ROOT/triggers/trigger_state.json"
STALE_TRIGGER_REPORT="$TMP/trigger_state_stale.md"
"$TOOL_BIN" --data-root "$STALE_TRIGGER_ROOT" --days 7 --out "$STALE_TRIGGER_REPORT" > /dev/null 2>&1
awk '/^## \(j\) LEADS/{f=1} f' "$STALE_TRIGGER_REPORT" | grep -q 'Canonical trigger claims have not advanced for enabled time triggers'
check "stale canonical claim for an enabled time trigger raises the scheduler lead" $?

# ── 3d. Backup registry newest-generation completeness ──────────────────────
# The legacy registry points at absolute paths that are not authority.  The
# instrument must instead join its id under this data root and prove that every
# registry-claimed component exists with non-zero bytes before calling it a
# backup. This fixture exercises all eleven legacy components.
echo "==> (b4) backup generation completeness"
BACKUP_ROOT="$TMP/data_backups"
BACKUP_ID="11111111-1111-4111-8111-111111111111"
BACKUP_COMPONENTS="chat_sessions connectors trust tools memory skills config improvements jobs workspaces missions"
mkdir -p "$BACKUP_ROOT/backups/$BACKUP_ID"
printf '[{"id":"%s","createdAt":"%s","path":"/untrusted/legacy/path","reason":"fixture","scope":["chat_sessions","connectors","trust","tools","memory","skills","config","improvements","jobs","workspaces","missions"]}]\n' \
  "$BACKUP_ID" "$(inst 0)" > "$BACKUP_ROOT/backups/registry.json"
for component in $BACKUP_COMPONENTS; do
  printf '{}\n' > "$BACKUP_ROOT/backups/$BACKUP_ID/$component.json"
done
BACKUP_REPORT="$TMP/backups.md"
"$TOOL_BIN" --data-root "$BACKUP_ROOT" --days 7 --out "$BACKUP_REPORT" > /dev/null 2>&1
BRC=$?
[ "$BRC" -eq 0 ]
check "complete backup fixture runs (rc=$BRC)" $?
awk '/^### Backup generations/{f=1} /^### Desk backlog/{f=0} f' "$BACKUP_REPORT" > "$TMP/backups_section.md"
grep -qF 'registry generations: **1/200**' "$TMP/backups_section.md"
check "backup reader reports the named 200-generation registry bound" $?
grep -qF 'claimed components: **11** · present: **11** · missing: **0**' "$TMP/backups_section.md"
check "backup reader verifies every registry-claimed legacy component" $?
grep -qF 'verified file members: **11** · zero-byte: **0**' "$TMP/backups_section.md"
check "complete backup generation has no zero-byte component" $?

# The newest row is the restore candidate.  One missing component plus one
# zero-byte file must not be hidden by the older complete generation.
BROKEN_BACKUP_ROOT="$TMP/data_backups_broken"
BROKEN_BACKUP_ID="22222222-2222-4222-8222-222222222222"
mkdir -p "$BROKEN_BACKUP_ROOT/backups/$BROKEN_BACKUP_ID"
printf '[{"id":"%s","createdAt":"%s","path":"/untrusted/legacy/path","reason":"fixture","scope":["config","trust","tools"]}]\n' \
  "$BROKEN_BACKUP_ID" "$(inst 0)" > "$BROKEN_BACKUP_ROOT/backups/registry.json"
printf '{}\n' > "$BROKEN_BACKUP_ROOT/backups/$BROKEN_BACKUP_ID/config.json"
: > "$BROKEN_BACKUP_ROOT/backups/$BROKEN_BACKUP_ID/trust.json"
BROKEN_BACKUP_REPORT="$TMP/backups_broken.md"
"$TOOL_BIN" --data-root "$BROKEN_BACKUP_ROOT" --days 7 --out "$BROKEN_BACKUP_REPORT" > /dev/null 2>&1
awk '/^### Backup generations/{f=1} /^### Desk backlog/{f=0} f' "$BROKEN_BACKUP_REPORT" > "$TMP/backups_broken_section.md"
grep -qF 'claimed components: **3** · present: **2** · missing: **1**' "$TMP/backups_broken_section.md"
check "newest incomplete backup reports its missing claimed component" $?
grep -qF 'verified file members: **2** · zero-byte: **1**' "$TMP/backups_broken_section.md"
check "newest backup reports its zero-byte claimed component" $?
awk '/^## \(j\) LEADS/{f=1} f' "$BROKEN_BACKUP_REPORT" | grep -q 'Newest backup generation is incomplete or contains zero-byte data'
check "incomplete newest backup raises a restore-time safety lead" $?

# ── 3e. Legacy context generation JSON stays before the SQLite cutover ──────
# `context.sqlite` is the live-store boundary. The old root JSON receipts and
# cache subtree are deliberately created first here, then the SQLite file is
# born one second later. A reader that merely totals the whole context/ folder,
# or compares against SQLite's mutable write time, cannot prove this invariant.
echo "==> (b5) legacy context-generation cutover"
LEGACY_CONTEXT_ROOT="$TMP/data_legacy_context"
mkdir -p "$LEGACY_CONTEXT_ROOT/context/cache"
printf '{"generation":"retired"}\n' > "$LEGACY_CONTEXT_ROOT/context/11111111-1111-4111-8111-111111111111.json"
printf '{"sections":[]}\n' > "$LEGACY_CONTEXT_ROOT/context/cache/sections.json"
sleep 1
: > "$LEGACY_CONTEXT_ROOT/context/context.sqlite"
LEGACY_CONTEXT_REPORT="$TMP/legacy_context.md"
"$TOOL_BIN" --data-root "$LEGACY_CONTEXT_ROOT" --days 7 --out "$LEGACY_CONTEXT_REPORT" > /dev/null 2>&1
LCRC=$?
[ "$LCRC" -eq 0 ]
check "legacy context fossil fixture runs (rc=$LCRC)" $?
awk '/^### Legacy context-generation cutover/{f=1} /^## \(b\)/{f=0} f' "$LEGACY_CONTEXT_REPORT" > "$TMP/legacy_context_section.md"
grep -qF '`context/*.json`: **1** file(s)' "$TMP/legacy_context_section.md"
check "legacy JSON reader counts only direct UUID generation receipts" $?
grep -qF '`context/cache/`: **1** file(s)' "$TMP/legacy_context_section.md"
check "legacy context reader measures the cache subtree separately" $?
grep -cF '**FROZEN before SQLite cutover**' "$TMP/legacy_context_section.md" | grep -q '^2$'
check "both legacy JSON and cache newest mtimes are strictly before SQLite birth" $?

# The inverse must become visible on the day it happens: a JSON receipt and a
# cache file written after the SQLite file was born cannot hide in the broad
# context/ size rollup or be called a harmless fossil.
REVIVED_CONTEXT_ROOT="$TMP/data_legacy_context_revived"
mkdir -p "$REVIVED_CONTEXT_ROOT/context/cache"
: > "$REVIVED_CONTEXT_ROOT/context/context.sqlite"
sleep 1
printf '{"generation":"revived"}\n' > "$REVIVED_CONTEXT_ROOT/context/22222222-2222-4222-8222-222222222222.json"
printf '{"sections":["revived"]}\n' > "$REVIVED_CONTEXT_ROOT/context/cache/sections.json"
REVIVED_CONTEXT_REPORT="$TMP/legacy_context_revived.md"
"$TOOL_BIN" --data-root "$REVIVED_CONTEXT_ROOT" --days 7 --out "$REVIVED_CONTEXT_REPORT" > /dev/null 2>&1
awk '/^### Legacy context-generation cutover/{f=1} /^## \(b\)/{f=0} f' "$REVIVED_CONTEXT_REPORT" > "$TMP/legacy_context_revived_section.md"
grep -cF '**ACTIVE AFTER CUTOVER**' "$TMP/legacy_context_revived_section.md" | grep -q '^2$'
check "post-cutover legacy writes are named for both JSON and cache feeds" $?
awk '/^## \(j\) LEADS/{f=1} f' "$REVIVED_CONTEXT_REPORT" | grep -q 'Legacy context generation feed wrote at or after the SQLite cutover'
check "post-cutover legacy writes raise the resolver-fallback lead" $?

# ── 4. Read-only discipline ──────────────────────────────────────────────────
echo "==> (c) read-only discipline"
# 4a. Refuses --out inside the data root.
OUT_INSIDE="$ROOT/report.md"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --out "$OUT_INSIDE" > "$TMP/refuse.out" 2> "$TMP/refuse.err"
RC=$?
[ $RC -ne 0 ]
check "refuses --out inside the data root (rc=$RC)" $?
grep -qi 'REFUSED' "$TMP/refuse.err"
check "refusal names itself in stderr" $?
[ ! -e "$OUT_INSIDE" ]
check "refused run created no file inside the data root" $?
# 4b. Refuses a nested path inside the data root too.
"$TOOL_BIN" --data-root "$ROOT" --out "$ROOT/traces/report.md" > /dev/null 2> "$TMP/refuse2.err"
[ $? -ne 0 ] && grep -qi 'REFUSED' "$TMP/refuse2.err"
check "refuses a NESTED --out inside the data root" $?
# 4c. Negative control: an --out OUTSIDE the data root is accepted.
"$TOOL_BIN" --data-root "$ROOT" --out "$TMP/outside.md" > /dev/null 2>&1
[ $? -eq 0 ] && [ -s "$TMP/outside.md" ]
check "NEGATIVE CONTROL: --out outside the data root is accepted" $?
# 4d. A successful run mutates nothing in the data root.
snap() { find "$ROOT" -print0 | xargs -0 stat -f '%N|%m|%z|%i' 2>/dev/null \
         || find "$ROOT" -printf '%p|%T@|%s|%i\n'; }
snap | sort > "$TMP/before.txt"
"$TOOL_BIN" --data-root "$ROOT" --days 7 > /dev/null 2>&1
snap | sort > "$TMP/after.txt"
diff -q "$TMP/before.txt" "$TMP/after.txt" > /dev/null
check "successful run leaves the data root byte-identical (mtime+size+inode)" $?
# 4e. The live sqlite file is never opened: a copy must appear in TMPDIR, and the
#     report must say so.
grep -q 'copied before query' "$REPORT"
check "report attests the sqlite copy-before-query rule" $?
# 4f. Negative control for 4d: prove the snapshot comparison can actually fail.
touch "$ROOT/traces/events.jsonl"
snap | sort > "$TMP/after2.txt"
diff -q "$TMP/before.txt" "$TMP/after2.txt" > /dev/null
check "NEGATIVE CONTROL: the mtime snapshot DOES detect a deliberate touch" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 5. BOOM summary leads the report and its links resolve ───────────────────
echo "==> (d) BOOM summary"
grep -q '^## BOOM' "$REPORT"
check "report has a BOOM summary section" $?
# It must come FIRST — before Sources and before every lettered section.
BOOM_LINE=$(grep -n '^## BOOM' "$REPORT" | head -1 | cut -d: -f1)
SRC_LINE=$(grep -n '^## Sources' "$REPORT" | head -1 | cut -d: -f1)
A_LINE=$(grep -n '^## (a)' "$REPORT" | head -1 | cut -d: -f1)
[ -n "$BOOM_LINE" ] && [ -n "$SRC_LINE" ] && [ "$BOOM_LINE" -lt "$SRC_LINE" ] && [ "$BOOM_LINE" -lt "$A_LINE" ]
check "BOOM is at the TOP (line $BOOM_LINE < Sources $SRC_LINE < (a) $A_LINE)" $?
# One screen: the whole boom block must stay small.
BOOM_LEN=$(awk -v s="$BOOM_LINE" 'NR>=s && /^<a id="sec-sources"/{exit} NR>=s{n++} END{print n+0}' "$REPORT")
[ "$BOOM_LEN" -le 60 ]
check "BOOM fits one screen ($BOOM_LEN lines <= 60)" $?
# Its three required parts.
awk -v s="$BOOM_LINE" 'NR>=s && /^<a id="sec-sources"/{exit} NR>=s' "$REPORT" > "$TMP/boom.md"
grep -q '^\*\*Health\*\*' "$TMP/boom.md";       check "BOOM carries an overall health line" $?
grep -q '^\*\*Top 3 leads\*\*' "$TMP/boom.md";  check "BOOM carries top 3 leads" $?
grep -q '^\*\*Top 3 blind spots\*\*' "$TMP/boom.md"
check "BOOM carries top 3 blind spots" $?
# EVERY anchor the BOOM cites must exist in the report — no dead references.
grep -o '(#[a-z0-9-]*)' "$TMP/boom.md" | tr -d '()#' | sort -u > "$TMP/boom_anchors.txt"
[ -s "$TMP/boom_anchors.txt" ]
check "BOOM references at least one section anchor" $?
MISSING=0
while read -r a; do
  grep -q "<a id=\"$a\"></a>" "$REPORT" || { MISSING=$((MISSING + 1)); echo "     dangling: #$a"; }
done < "$TMP/boom_anchors.txt"
[ "$MISSING" -eq 0 ]
check "every BOOM anchor resolves to a real section ($(wc -l < "$TMP/boom_anchors.txt" | tr -d ' ') checked, $MISSING dangling)" $?
# NEGATIVE CONTROL: the anchor checker can actually detect a dangling link.
echo '1. [bogus](#sec-does-not-exist)' > "$TMP/boom_neg.md"
grep -o '(#[a-z0-9-]*)' "$TMP/boom_neg.md" | tr -d '()#' | while read -r a; do
  grep -q "<a id=\"$a\"></a>" "$REPORT"
done
check "NEGATIVE CONTROL: the anchor checker flags a fabricated anchor" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 6. Reach walker names the PLANTED unknown feed ───────────────────────────
echo "==> (e) reach walker / NOT COVERED"
grep -q '^## (i) REACH WALK' "$REPORT"
check "report has a REACH WALK section" $?
awk '/^### NOT COVERED/{f=1} /^### Covered/{f=0} f' "$REPORT" > "$TMP/notcovered.md"
grep -q 'plantedsubsystem' "$TMP/notcovered.md"
check "planted unknown feed is listed as NOT COVERED" $?
# Family aggregation: the two dated siblings collapse into ONE `*` feed.
grep -q 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md"
check "planted feed's dated siblings aggregate into one \`*.jsonl\` feed" $?
grep -E 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md" | grep -q '| 2 |'
check "aggregated feed reports both files (2)" $?
grep -E 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md" | grep -q 'ACTIVE'
check "planted feed written in-window is marked ACTIVE" $?
# It must have a row-count estimate, a size and an mtime — not just a name.
grep -E 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md" | grep -qE '\| [0-9.]+ (B|KB|MB) \|'
check "planted feed carries a size" $?
grep -E 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md" | grep -qE '\| ~?[0-9]+'
check "planted feed carries a row-count estimate" $?
grep -E 'plantedsubsystem/\*\.jsonl' "$TMP/notcovered.md" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:'
check "planted feed carries an mtime" $?
# NEGATIVE CONTROL: a feed WITH a reader must NOT be in the not-covered table.
grep -q 'turn_traces' "$TMP/notcovered.md"
check "NEGATIVE CONTROL: a covered feed (turn_traces) is NOT in NOT COVERED" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# NOTE: the awk output is staged in a FILE rather than piped into `grep -q`.
# `set -o pipefail` is on at the top, and `grep -q` exits at the first match —
# which SIGPIPEs awk while it still has the rest of the report to write, so the
# pipeline returns 141 and the assertion fails for a reason that has nothing to
# do with the report. It only surfaced once sections were added after this
# table; staging the text removes the race for good.
awk '/^### Covered/{f=1} f' "$REPORT" > "$TMP/covered_tail.md"
grep -q 'turn_traces' "$TMP/covered_tail.md"
check "covered feed IS in the Covered table" $?
# The planted feed must also surface as a ranked LEAD, not just a table row.
awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" | grep -q 'no reader in this instrument'
check "an actively-written uncovered feed produces a ranked LEAD" $?

# ── 7. Coverage matrix carries all 12 subsystems ─────────────────────────────
echo "==> (f) coverage matrix"
grep -q '^## (g) Coverage matrix' "$REPORT"
check "report has a coverage matrix section" $?
awk '/^## \(g\) Coverage matrix/{f=1} /^<a id="sec-h"/{f=0} f' "$REPORT" > "$TMP/coverage.md"
N_SUB=$(grep -cE '^\| SUB-[0-9]{2} \|' "$TMP/coverage.md")
[ "$N_SUB" -eq 12 ]
check "coverage matrix has exactly 12 subsystem rows (got $N_SUB)" $?
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  grep -qE "^\| SUB-$i \|" "$TMP/coverage.md" || { fail "coverage matrix is missing SUB-$i"; }
done
pass "every SUB-01..SUB-12 id is present"
# The 12 named subsystems from docs/SUBCONSCIOUS.md, by keyword.
for kw in "Somatic" "Affect" "appraisal" "fingerprint" "Continuity field" "Standing views" \
          "Prediction ledger" "Trait dials" "Attention" "Delivery envelope" "consolidation" "REM"; do
  grep -qi -- "$kw" "$TMP/coverage.md" || fail "coverage matrix does not mention '$kw'"
done
pass "all 12 documented subsystem names appear in the matrix"
# Every status must be one of the three, and every non-measured row must give a reason.
grep -qE '\| (measured|\*\*partial\*\*|\*\*not-yet\*\*) \|' "$TMP/coverage.md"
check "coverage rows carry a measured/partial/not-yet status" $?
N_GAP=$(grep -cE '\| (\*\*partial\*\*|\*\*not-yet\*\*) \|' "$TMP/coverage.md")
N_REASON=$(grep -cE '^- \*\*SUB-[0-9]{2} ' "$TMP/coverage.md")
[ "$N_GAP" -eq "$N_REASON" ]
check "every partial/not-yet row has a one-line reason ($N_GAP gaps, $N_REASON reasons)" $?
# NEGATIVE CONTROL: the 12-row count is not matching stray text elsewhere.
[ "$(grep -cE '^\| SUB-[0-9]{2} \|' "$TMP/boom.md")" -eq 0 ]
check "NEGATIVE CONTROL: SUB- rows are counted from the matrix, not the BOOM block" $?

# ── 8. A dark stage is never rendered as 0 ms ────────────────────────────────
echo "==> (g) dark stage vs zero"
awk '/^### Assembly stages/{f=1} /^### Per-day trend/{f=0} f' "$REPORT" > "$TMP/stages.md"
grep -q 'darkStage' "$TMP/stages.md"
check "the always-zero stage appears in the stage table" $?
grep -E '^\| `darkStage`' "$TMP/stages.md" | grep -q '\*\*DARK\*\*'
check "the always-zero stage is labelled DARK" $?
# THE POINT: its latency cells must read "dark", never a numeric 0.
grep -E '^\| `darkStage`' "$TMP/stages.md" | grep -q 'dark | dark | dark'
check "dark stage renders 'dark' in p50/p95/max" $?
grep -E '^\| `darkStage`' "$TMP/stages.md" | grep -qE '\| 0 \| 0 \| 0 \|'
check "NEGATIVE CONTROL: dark stage does NOT render '| 0 | 0 | 0 |'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# The live stage MUST show real numbers — proves 'dark' is not applied to everything.
grep -E '^\| `liveStage`' "$TMP/stages.md" | grep -q 'live'
check "NEGATIVE CONTROL: the non-zero stage is 'live', not dark" $?
grep -E '^\| `liveStage`' "$TMP/stages.md" | grep -q 'dark'
check "NEGATIVE CONTROL: the non-zero stage never says 'dark'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# And the darkness must reach the leads with its own finding.
awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" | grep -q 'stageMs.darkStage` is DARK'
check "dark stage produces its own ranked LEAD" $?
# Turn speed must have measured the fixture's lifecycle rows.
grep -q '^## (f) Turn speed' "$REPORT"
check "report has a turn-speed section" $?
grep -q 'turns in diagnostic cohort' "$REPORT"
check "turn speed reports end-to-end turn counts" $?
awk '/^### Where the time goes/{f=1} /^### Assembly stages/{f=0} f' "$REPORT" | grep -q 'tool.dispatch'
check "tool time is attributed (the \`\"phase\": \"end\"\` spacing trap)" $?
awk '/^### Where the time goes/{f=1} /^### Assembly stages/{f=0} f' "$REPORT" \
  | grep -E '^\| tools \|' | grep -qE '\| 0\.0 \|'
check "NEGATIVE CONTROL: tool time is not silently zero" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 10. Corrupt sqlite store → UNREADABLE, never zeros ───────────────────────
# The instrument's own silent-zero: sqlite3 exits nonzero on a corrupt store,
# the query layer returned [], and `?? 0` rendered "0 nodes" for a database
# nobody could read.
echo "==> (i) corrupt sqlite store"
CROOT="$TMP/data_corrupt"
mkdir -p "$CROOT/cognition"
sqlite3 "$CROOT/cognition/cognition.sqlite" <<'SQL'
CREATE TABLE cognitive_nodes (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, subject_type TEXT NOT NULL,
  subject_id TEXT NOT NULL, subject_label TEXT, activation REAL NOT NULL,
  salience REAL NOT NULL, confidence REAL NOT NULL, source_class TEXT NOT NULL,
  created_at REAL NOT NULL, last_activated_at REAL NOT NULL, decay_half_life REAL NOT NULL,
  summary TEXT NOT NULL, metadata_json TEXT NOT NULL, updated_at REAL NOT NULL,
  emotional_valence REAL NOT NULL DEFAULT 0, emotional_arousal REAL NOT NULL DEFAULT 0,
  emotional_warmth REAL NOT NULL DEFAULT 0);
CREATE TABLE cognitive_artifacts (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
  score REAL NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE cognitive_receipts (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL);
SQL
# Enough rows that the file is several pages long, so a mid-file truncation
# genuinely loses data rather than trimming slack.
for i in $(seq 1 400); do
  printf "INSERT INTO cognitive_nodes VALUES ('n%d','conversationFocus','turn','t%d','l',0.5,0.5,0.9,'chat',1000,1000,3600,'summary text %d','{\"eventKind\":\"userMessageReceived\"}',1000,0.2,0.3,0.4);\n" "$i" "$i" "$i"
done | sqlite3 "$CROOT/cognition/cognition.sqlite"

# CONTROL: intact store reads clean, with real counts.
"$TOOL_BIN" --data-root "$CROOT" --days 7 --out "$TMP/corrupt_control.md" > /dev/null 2>&1
CRC=$?
[ $CRC -eq 0 ] && grep -q 'nodes: \*\*400\*\*' "$TMP/corrupt_control.md"
check "CONTROL: intact fixture store reports its real 400 nodes (rc=$CRC)" $?
grep -qE '^\| `[^`]*` \| \*\*UNREADABLE\*\* \|' "$TMP/corrupt_control.md"
check "CONTROL: intact fixture store is NOT marked UNREADABLE" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'quick_check: ok' "$TMP/corrupt_control.md"
check "CONTROL: the copy is integrity-gated with PRAGMA quick_check" $?

# Now truncate the database mid-file.
DBF="$CROOT/cognition/cognition.sqlite"
DBSIZE=$(wc -c < "$DBF" | tr -d ' ')
head -c $((DBSIZE / 2)) "$DBF" > "$TMP/trunc.sqlite" && mv "$TMP/trunc.sqlite" "$DBF"
"$TOOL_BIN" --data-root "$CROOT" --days 7 --out "$TMP/corrupt.md" > /dev/null 2>"$TMP/corrupt.err"
RC=$?
[ $RC -eq 0 ]
check "corrupt store: run still exits 0 — a bad source is a finding, not a crash (rc=$RC)" $?
grep -q '| \*\*UNREADABLE\*\* |' "$TMP/corrupt.md"
check "corrupt store is marked **UNREADABLE** in the Sources table" $?
awk '/^## \(b\) Subconscious/{f=1} /^## \(c\)/{f=0} f' "$TMP/corrupt.md" | grep -q 'source unreadable'
check "section (b) says 'source unreadable' and skips" $?
# THE POINT: no zero anywhere that used to come from `?? 0`.
grep -qE 'nodes: \*\*0\*\*|standing views \| 0 \|active: \*\*0\*\*' "$TMP/corrupt.md"
check "NEGATIVE CONTROL: corrupt store does NOT render '0 nodes'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'nodes: \*\*400\*\*' "$TMP/corrupt.md"
check "NEGATIVE CONTROL: corrupt store does not report the pre-corruption count either" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/corrupt.md" | grep -q 'is UNREADABLE'
check "corrupt store raises a ranked LEAD" $?

# ── 11. Sidecar copy failure is LOUD ─────────────────────────────────────────
# A `-wal` that cannot be copied means the snapshot is TORN: the newest
# committed transactions live in that sidecar. Best-effort `try?` hid it.
echo "==> (j) WAL sidecar copy failure"
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: mode-000 denies nothing to uid 0"
else
  WROOT="$TMP/data_wal"
  mkdir -p "$WROOT/cognition"
  cp "$TMP/corrupt_control_db.sqlite" "$WROOT/cognition/cognition.sqlite" 2>/dev/null || \
    sqlite3 "$WROOT/cognition/cognition.sqlite" \
      "CREATE TABLE cognitive_nodes (id TEXT PRIMARY KEY, kind TEXT, metadata_json TEXT,
         emotional_valence REAL DEFAULT 0, emotional_arousal REAL DEFAULT 0,
         emotional_warmth REAL DEFAULT 0, last_activated_at REAL DEFAULT 0);
       INSERT INTO cognitive_nodes VALUES ('n1','conversationFocus','{}',0,0,0,1000);"
  printf 'not-a-real-wal-but-it-exists-and-cannot-be-read' > "$WROOT/cognition/cognition.sqlite-wal"
  chmod 000 "$WROOT/cognition/cognition.sqlite-wal"
  "$TOOL_BIN" --data-root "$WROOT" --days 7 --out "$TMP/wal.md" > /dev/null 2>&1
  WRC=$?
  chmod 644 "$WROOT/cognition/cognition.sqlite-wal"
  [ $WRC -eq 0 ]
  check "sidecar failure: run exits 0 and reports (rc=$WRC)" $?
  grep -q '| \*\*UNREADABLE\*\* |' "$TMP/wal.md"
  check "unreadable WAL sidecar marks the store UNREADABLE — never queried silently" $?
  grep -q 'sidecar -wal copy failed' "$TMP/wal.md"
  check "the report NAMES the sidecar copy failure (loud, not best-effort)" $?
  awk '/^## \(j\) LEADS/{f=1} f' "$TMP/wal.md" | grep -q 'is UNREADABLE'
  check "sidecar failure raises a ranked LEAD" $?
  # NEGATIVE CONTROL: with the sidecar readable, the same store reads clean.
  "$TOOL_BIN" --data-root "$WROOT" --days 7 --out "$TMP/wal_ok.md" > /dev/null 2>&1
  grep -q 'sidecar -wal copy failed' "$TMP/wal_ok.md"
  check "NEGATIVE CONTROL: a readable sidecar produces no sidecar failure" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
fi

# ── 12. Malformed JSONL lines are counted, surfaced, and gated ───────────────
echo "==> (k) malformed JSONL accounting"
MROOT="$TMP/data_malformed"
mkdir -p "$MROOT/traces" "$MROOT/desk"
# 30 good rows + a truncated tail line + one garbage line = 2/32 = 6.25%,
# UNDER the 10% threshold: the count must surface and the good rows must still
# be computed from.
for i in $(seq 1 30); do
  printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "claude-opus-5", "inputTokens": 10, "outputTokens": 5, "durationMs": 100}}\n' "$(inst 1)"
done > "$MROOT/traces/events.jsonl"
printf 'this line is not json at all\n' >> "$MROOT/traces/events.jsonl"
printf '{"kind": "llm.call", "createdAt": "2026-08-20T12:00:00Z", "payload": {"surf\n' >> "$MROOT/traces/events.jsonl"
# A feed where EVERY line is garbage: unreadable, no matter the ratio rule.
printf 'garbage one\ngarbage two\ngarbage three\ngarbage four\n' > "$MROOT/desk/desk_ops.jsonl"

"$TOOL_BIN" --data-root "$MROOT" --days 7 --out "$TMP/malformed.md" > /dev/null 2>&1
MRC=$?
[ $MRC -eq 0 ]
check "malformed JSONL: run exits 0 (rc=$MRC)" $?
grep -q '| 30, malformed 2 |' "$TMP/malformed.md"
check "Sources table surfaces 'rows 30, malformed 2'" $?
# Under threshold ⇒ still measured, from the GOOD rows only.
awk '/^## \(e\) Cost and latency/{f=1} /^## \(f\)/{f=0} f' "$TMP/malformed.md" \
  | grep -q '`llm.call` rows in window: \*\*30\*\*'
check "under-threshold feed still computes its 30 good rows" $?
awk '/^## \(e\) Cost and latency/{f=1} /^## \(f\)/{f=0} f' "$TMP/malformed.md" | grep -q 'source unreadable'
check "NEGATIVE CONTROL: an under-threshold feed is NOT marked unreadable" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# All-garbage feed ⇒ unreadable, its section skipped, a lead raised.
grep -qE '^\| `[^`]*desk_ops\.jsonl` \| \*\*UNREADABLE\*\* \|' "$TMP/malformed.md"
check "all-malformed feed is marked **UNREADABLE** in the Sources table" $?
awk '/^### Desk throughput/{f=1} /^### Desk backlog/{f=0} f' "$TMP/malformed.md" | grep -q 'source unreadable'
check "all-malformed feed's section says 'source unreadable' and skips" $?
awk '/^### Desk throughput/{f=1} /^### Desk backlog/{f=0} f' "$TMP/malformed.md" | grep -q 'ops in window: \*\*0\*\*'
check "NEGATIVE CONTROL: all-malformed feed does NOT render '0 ops'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/malformed.md" | grep -q '4/4 lines malformed'
check "all-malformed feed raises a ranked LEAD naming the counts" $?
# NEGATIVE CONTROL: the CLEAN fixture root reports no malformed lines at all.
grep -q ', malformed ' "$REPORT"
check "NEGATIVE CONTROL: the clean synthetic root reports zero malformed lines" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 13. --out through a symlink into the data root is refused ────────────────
echo "==> (l) symlinked --out"
ln -s "$ROOT/traces" "$TMP/sneak_dir"
"$TOOL_BIN" --data-root "$ROOT" --out "$TMP/sneak_dir/report.md" > /dev/null 2>"$TMP/sneak.err"
SRC=$?
[ $SRC -ne 0 ] && grep -qi 'REFUSED' "$TMP/sneak.err"
check "refuses --out through a symlinked DIR resolving into the data root (rc=$SRC)" $?
[ ! -e "$ROOT/traces/report.md" ]
check "no file was created inside the data root through the symlink" $?
# A symlinked FILE whose target is inside the data root is refused too.
ln -s "$ROOT/planted_out.md" "$TMP/sneak_file.md"
"$TOOL_BIN" --data-root "$ROOT" --out "$TMP/sneak_file.md" > /dev/null 2>"$TMP/sneak2.err"
SRC2=$?
[ $SRC2 -ne 0 ] && grep -qi 'REFUSED' "$TMP/sneak2.err"
check "refuses an --out that is a SYMLINK pointing into the data root (rc=$SRC2)" $?
[ ! -e "$ROOT/planted_out.md" ]
check "the symlink target inside the data root was never created" $?
# NEGATIVE CONTROL: a symlinked dir OUTSIDE the data root is still accepted —
# only the FINAL component is O_NOFOLLOW-refused, so ordinary symlinked output
# directories keep working.
mkdir -p "$TMP/realout"
ln -s "$TMP/realout" "$TMP/link_outside"
"$TOOL_BIN" --data-root "$ROOT" --out "$TMP/link_outside/ok.md" > /dev/null 2>&1
[ $? -eq 0 ] && [ -s "$TMP/realout/ok.md" ]
check "NEGATIVE CONTROL: a symlinked dir outside the data root is accepted" $?
# O_NOFOLLOW itself: an --out that IS a symlink, even to a harmless target
# outside the data root, is refused — the target cannot be re-verified after
# the open, so the instrument never writes through one.
ln -s "$TMP/realout/harmless.md" "$TMP/outside_link.md"
"$TOOL_BIN" --data-root "$ROOT" --out "$TMP/outside_link.md" > /dev/null 2>"$TMP/nofollow.err"
NRC=$?
[ $NRC -ne 0 ] && grep -qi 'REFUSED' "$TMP/nofollow.err" && grep -qi 'symlink' "$TMP/nofollow.err"
check "O_NOFOLLOW: an --out that is itself a symlink is refused (rc=$NRC)" $?
[ ! -e "$TMP/realout/harmless.md" ]
check "the symlink's target was never written through" $?

# ── 14. Store-derived text cannot inject markdown structure ──────────────────
echo "==> (m) markdown injection"
build_injection_root() { # build_injection_root <dir> <extra-json-pair-or-empty>
  local d="$1" extra="$2"
  mkdir -p "$d/turn_traces"
  local f="$d/turn_traces/$(day 1).jsonl"
  : > "$f"
  for i in 1 2 3; do
    printf '{"kind": "context.summary", "ts": "%s", "turnId": "t-%d", "surface": "chat", "payload": {"counts": {%s"liveLane": %d}, "totalMs": 20}}\n' \
      "$(inst 1)" "$i" "$extra" "$((i + 4))" >> "$f"
    printf '{"kind": "turn.terminal", "ts": "%s", "turnId": "t-%d", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 1000}}\n' \
      "$(inst 1)" "$i" >> "$f"
  done
}
# A lane key that tries to open a heading, forge a link, close a code span,
# break a table row, inject HTML, and start a new line. It carries a NON-ZERO
# value on every row, so it raises no lead — that keeps the heading count
# directly comparable against the control.
INJ='## fake ](x) `code` <b>&</b> |cell| \nsecond ### heading'
build_injection_root "$TMP/data_inject" "\"$INJ\": 7, "
build_injection_root "$TMP/data_inject_ctrl" ""
"$TOOL_BIN" --data-root "$TMP/data_inject" --days 7 --out "$TMP/inject.md" > /dev/null 2>&1
IRC=$?
"$TOOL_BIN" --data-root "$TMP/data_inject_ctrl" --days 7 --out "$TMP/inject_ctrl.md" > /dev/null 2>&1
[ $IRC -eq 0 ]
check "injection fixture runs (rc=$IRC)" $?
# Structure must be byte-identical in COUNT to the clean control.
H_INJ=$(grep -c '^#' "$TMP/inject.md"); H_CTL=$(grep -c '^#' "$TMP/inject_ctrl.md")
[ "$H_INJ" -eq "$H_CTL" ]
check "no new heading: $H_INJ headings vs $H_CTL in the control" $?
A_INJ=$(grep -c '<a id=' "$TMP/inject.md"); A_CTL=$(grep -c '<a id=' "$TMP/inject_ctrl.md")
[ "$A_INJ" -eq "$A_CTL" ]
check "anchor count unchanged: $A_INJ vs $A_CTL in the control" $?
# It must still be REPORTED — escaping is not dropping.
grep -q 'fake' "$TMP/inject.md"
check "the injected lane is still reported (escaped, not silently dropped)" $?
# And none of its structural characters may survive at a structural position.
grep -q '^## fake' "$TMP/inject.md"
check "NEGATIVE CONTROL: the injected '## fake' never starts a line" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q '^second ### heading' "$TMP/inject.md"
check "NEGATIVE CONTROL: the injected newline never starts a new line" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# Table integrity: every lane row must still carry exactly the table's column
# count once GFM's `\|` escapes are removed — the injected `|cell|` must arrive
# escaped, so a renderer sees one cell, not three.
awk '/^### Live lanes/{f=1} /^## \(b\)/{f=0} f' "$TMP/inject.md" | grep '^| `' \
  | awk '{ line=$0; gsub(/\\\|/, "", line); n=gsub(/\|/, "", line); if (n != 7) bad++ }
         END { exit (bad > 0) ? 1 : 0 }'
check "injected \`|\` arrives escaped and does not add a lane-table column" $?
# NEGATIVE CONTROL: the same check on a row with the escapes NOT stripped would
# see the extra columns — proving the assertion is measuring something real.
awk '/^### Live lanes/{f=1} /^## \(b\)/{f=0} f' "$TMP/inject.md" | grep '^| `' \
  | awk '{ n=gsub(/\|/, "", $0); if (n != 7) bad++ } END { exit (bad > 0) ? 1 : 0 }'
check "NEGATIVE CONTROL: the injected row DOES carry escaped pipes (raw count differs)" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 15. A failed reach walk exits NONZERO ────────────────────────────────────
echo "==> (n) reach-walk failure is fatal"
EROOT="$TMP/data_empty"
mkdir -p "$EROOT"
"$TOOL_BIN" --data-root "$EROOT" --days 7 --out "$TMP/empty.md" > /dev/null 2>"$TMP/empty.err"
ERC=$?
[ $ERC -ne 0 ]
check "a walk that enumerates 0 files exits NONZERO (rc=$ERC)" $?
grep -q 'report invalid — reach walk failed' "$TMP/empty.err"
check "stderr says 'report invalid — reach walk failed'" $?
grep -q 'REPORT INVALID — REACH WALK FAILED' "$TMP/empty.md"
check "the report itself declares REPORT INVALID" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/empty.md" | grep -q 'REPORT INVALID'
check "the walk failure is the rank-1 LEAD" $?
grep -q 'Every feed in the data root has a reader' "$TMP/empty.md"
check "NEGATIVE CONTROL: a failed walk never claims 'every feed has a reader'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# NEGATIVE CONTROL: the populated root walks fine and exits 0.
grep -q 'per-entry errors: 0' "$REPORT"
check "NEGATIVE CONTROL: the healthy root reports 0 per-entry walk errors" $?

# ── 16. (h) SYSTEM MATRIX — 16 organs, absent ≠ zero, leads, BOOM line ───────
echo "==> (o) system matrix (SYS)"
grep -q '^## (h) System matrix (SYS)' "$REPORT"
check "report has a System matrix (SYS) section" $?
awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$REPORT" > "$TMP/sys.md"
N_SYS=$(grep -cE '^\| SYS-(0[1-9]|1[0-6]) \|' "$TMP/sys.md")
[ "$N_SYS" -eq 16 ]
check "SYS matrix has exactly 16 organ rows (got $N_SYS)" $?
SYS_MISSING=0
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16; do
  grep -qE "^\| SYS-$i \|" "$TMP/sys.md" || { SYS_MISSING=$((SYS_MISSING + 1)); echo "     missing SYS-$i"; }
done
[ "$SYS_MISSING" -eq 0 ]
check "every SYS-01..SYS-16 id is present" $?
# Every row carries one of the four statuses.
N_STATUS=$(grep -cE '\| (measured|\*\*partial\*\*|\*\*absent\*\*|\*\*UNREADABLE\*\*) · ' "$TMP/sys.md")
[ "$N_STATUS" -eq 16 ]
check "every SYS row carries a measured/partial/absent/UNREADABLE status (got $N_STATUS)" $?

# THE POINT: the absent organ says absent, and prints no number.
# SYS-01's lanes live in ~/.config; the hermeticity gate keeps a synthetic root
# from reading machine-global state, so it must be absent here.
grep -E '^\| SYS-01 \|' "$TMP/sys.md" | grep -q '\*\*absent\*\*'
check "SYS-01 (bridge lanes, hermetic on a synthetic root) is status **absent**" $?
grep -E '^\| SYS-01 \|' "$TMP/sys.md" | grep -q 'source absent'
check "SYS-01 renders the 'source absent' label" $?
grep -E '^\| SYS-01 \|' "$TMP/sys.md" | grep -qE 'terminal failed|unconsumed >24h|held-unreleased|stale-heartbeat|jobs 7d'
check "NEGATIVE CONTROL: the absent organ prints NO bridge counts (not even 0)" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q '^### SYS-01 detail' "$TMP/sys.md"
check "SYS-01 has a per-lane detail block" $?
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q 'backup retention: \*\*2\*\*/8 generation(s)'
check "SYS-05 names the bounded memory-backup generation count" $?
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q 'staged repairs: \*\*0\*\* staged'
check "SYS-05 names the staged-repair lifecycle count" $?
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q 'hygiene ledger: newest .*\*\*agrees\*\* with last-run receipt'
check "SYS-05 cross-checks hygiene.jsonl against the last-run receipt" $?
grep -q '^### Skill registry inventory' "$REPORT"
check "report has a dedicated skill-registry inventory" $?
awk '/^### Skill registry inventory/{f=1} /^### SYS-11 detail/{f=0} f' "$REPORT" > "$TMP/skill_registry.md"
grep -q 'registry: populated, \*\*2\*\* row(s)' "$TMP/skill_registry.md"
check "skill registry reports its actual row count" $?
grep -q 'status: active=1, draft=1' "$TMP/skill_registry.md"
check "skill registry reports lifecycle statuses without reading bodies" $?
SKILL_REGISTRY_DAMAGE_ROOT="$TMP/data_skill_registry_damage"
cp -R "$ROOT" "$SKILL_REGISTRY_DAMAGE_ROOT"
printf '{"skills": {}}\n' > "$SKILL_REGISTRY_DAMAGE_ROOT/skills/registry.json"
"$TOOL_BIN" --data-root "$SKILL_REGISTRY_DAMAGE_ROOT" --days 7 --out "$TMP/skill_registry_damage.md" > /dev/null 2>&1
awk '/^### Skill registry inventory/{f=1} /^### SYS-11 detail/{f=0} f' "$TMP/skill_registry_damage.md" > "$TMP/skill_registry_damage_section.md"
grep -q '\*\*source unreadable\*\*' "$TMP/skill_registry_damage_section.md"
check "malformed skill registry is unreadable, never an empty registry" $?
grep -q '\*\*0\*\* row(s)' "$TMP/skill_registry_damage_section.md"
check "NEGATIVE CONTROL: malformed skill registry never renders a zero row count" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^### SYS-01 detail/{f=1} /^### SYS-02 detail/{f=0} f' "$TMP/sys.md" | grep -q 'source absent'
check "SYS-01 detail says 'source absent' rather than an empty lane table" $?

# A MEASURED organ carries real, planted numbers — proving 'absent' is not
# being applied to everything.
grep -E '^\| SYS-02 \|' "$TMP/sys.md" | grep -q '| measured ·'
check "SYS-02 (background loops) is status measured" $?
grep -E '^\| SYS-02 \|' "$TMP/sys.md" | grep -q 'failingLoop'
check "SYS-02 names the planted failing loop in its live reading" $?
grep -E '^\| SYS-02 \|' "$TMP/sys.md" | grep -q 'not ticked >1d: \*\*1\*\*'
check "SYS-02 counts the planted 5-day-stale loop" $?
grep -E '^\| SYS-08 \|' "$TMP/sys.md" | grep -q 'status: `ok`'
check "SYS-08 (heartbeat) reads the planted status" $?
# The compaction snapshot is a real source now. The report must name its
# top-level envelope/size rather than claiming the tail is complete history.
grep -E '^\| SYS-07 \|' "$TMP/sys.md" | grep -q 'compaction base: 5 key(s), 0 reduced item(s), after 12 op(s)'
check "SYS-07 reads the GitHub command compaction base envelope and size boundary" $?
SYS07_RATIO=$(grep -E '^\| SYS-07 \|' "$TMP/sys.md" | sed -n 's/.*base\/tail \([0-9.]*\)×.*/\1/p')
awk -v ratio="$SYS07_RATIO" 'BEGIN { exit !(ratio >= 0.1 && ratio <= 10) }'
check "SYS-07 reports a compaction base/tail byte ratio within one order of magnitude" $?
# The per-loop detail table lists both planted loops.
awk '/^### SYS-02 detail/{f=1} f' "$TMP/sys.md" | grep -q '`staleLoop`'
check "SYS-02 detail lists the stale loop" $?
awk '/^### SYS-02 detail/{f=1} f' "$TMP/sys.md" | grep -q '`healthyLoop`'
check "SYS-02 detail lists the healthy loop" $?

# A PARTIAL organ: memory housekeeping feeds exist, memory.sqlite does not.
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q '\*\*partial\*\*'
check "SYS-05 (memory housekeeping, no memory.sqlite) is status **partial**" $?
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q 'proposals: source absent'
check "SYS-05 store-backed counters read 'source absent', not 0" $?
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -qE 'proposals: \*\*0\*\* pending'
check "NEGATIVE CONTROL: the missing store does NOT render '0 pending' proposals" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# But its FILE-backed counters are real.
grep -E '^\| SYS-05 \|' "$TMP/sys.md" | grep -q '1 in file'
check "SYS-05 still reports the planted tombstone file row" $?

# Leads derived from SYS data.
awk '/^## \(j\) LEADS/{f=1} f' "$REPORT" > "$TMP/leads.md"
grep -q 'failingLoop` failed 4× in the 7-day window' "$TMP/leads.md"
check "a loop failure streak produces a ranked LEAD" $?
grep -q 'Workshop background lease last acquired\|pump is not cycling' "$TMP/leads.md"
check "NEGATIVE CONTROL: old lease history does not imply a stopped pump" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -E '^\| SYS-06 \|' "$TMP/sys.md" | grep -q 'consumed-window history; not a heartbeat'
check "Workshop row retains the lease history with its correct meaning" $?
grep -E '^\| SYS-06 \|' "$TMP/sys.md" | grep -q 'pump: last recorded tick'
check "Workshop activity uses the canonical pump tick" $?

# Independent pump evidence cases: stale tick, absent/malformed tick source,
# and a legitimate empty lease after releaseUnused. No real data is touched.
PUMP_ROOT="$TMP/pump-evidence"
mkdir -p "$PUMP_ROOT/logs"
cp -R "$ROOT/workshop" "$PUMP_ROOT/workshop"
printf '{"loops":{"workshop_pump":"%s"}}\n' "$(inst 5)" > "$PUMP_ROOT/logs/background_loop_state.json"
"$TOOL_BIN" --data-root "$PUMP_ROOT" --days 7 --out "$TMP/pump-stale.md" >/dev/null 2>"$TMP/pump-stale.err"
check "stale pump evidence fixture runs" $?
grep -qE 'Workshop pump last recorded tick .*current activity unknown' "$TMP/pump-stale.md"
check "old canonical pump tick remains an actionable evidence gap" $?
rm "$PUMP_ROOT/logs/background_loop_state.json"
"$TOOL_BIN" --data-root "$PUMP_ROOT" --days 7 --out "$TMP/pump-absent.md" >/dev/null 2>"$TMP/pump-absent.err"
check "absent pump evidence fixture runs" $?
grep -qF 'pump: tick unavailable (source absent); activity unknown' "$TMP/pump-absent.md"
check "missing canonical tick is unknown despite old lease history" $?
printf '{broken\n' > "$PUMP_ROOT/logs/background_loop_state.json"
"$TOOL_BIN" --data-root "$PUMP_ROOT" --days 7 --out "$TMP/pump-corrupt.md" >/dev/null 2>"$TMP/pump-corrupt.err"
check "corrupt pump evidence fixture runs" $?
grep -E '^\| SYS-06 \|' "$TMP/pump-corrupt.md" | grep -q 'tick unavailable.*source unreadable.*activity unknown'
check "corrupt canonical tick cannot borrow lease history as activity" $?
printf '{"loops":{"workshop_pump":"%s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PUMP_ROOT/logs/background_loop_state.json"
printf '{"claims":[]}\n' > "$PUMP_ROOT/workshop/background_lease.json"
"$TOOL_BIN" --data-root "$PUMP_ROOT" --days 7 --out "$TMP/pump-empty.md" >/dev/null 2>"$TMP/pump-empty.err"
check "empty returned lease fixture runs" $?
grep -qF 'no consumed windows retained (empty claim history; not a heartbeat)' "$TMP/pump-empty.md"
check "valid returned lease needs no acquiredAt stamp" $?
grep -q 'Workshop background lease has no\|Workshop pump last recorded tick' "$TMP/pump-empty.md"
check "NEGATIVE CONTROL: empty returned lease with current tick raises no pump lead" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'GitHub watcher snapshot carries no timestamp' "$TMP/leads.md"
check "an unstamped GitHub watcher snapshot produces a ranked LEAD" $?
# NEGATIVE CONTROL: no bridge lead can be raised from the ABSENT bridge organ.
grep -qE 'undelivered for over 24h|unreleased COMMIT HOLD|stopped heartbeating' "$TMP/leads.md"
check "NEGATIVE CONTROL: the absent bridge organ raises NO bridge lead" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# The BOOM system-health line, and it must name a REAL organ.
grep -q 'organs measured' "$TMP/boom.md"
check "BOOM carries the system-health line" $?
grep -qE '\*\*[0-9]+/16 organs measured\*\*' "$TMP/boom.md"
check "BOOM system line reads N/16 organs measured" $?
BOOM_ORGAN=$(grep -o 'worst: \*\*SYS-\(0[1-9]\|1[0-6]\)' "$TMP/boom.md" | grep -o 'SYS-[0-9][0-9]' | head -1)
[ -n "$BOOM_ORGAN" ] && grep -qE "^\| $BOOM_ORGAN \|" "$TMP/sys.md"
check "BOOM 'worst' names a real matrix organ (${BOOM_ORGAN:-none})" $?
# NEGATIVE CONTROL: it is not naming an organ that does not exist.
grep -q 'worst: \*\*SYS-17' "$TMP/boom.md"
check "NEGATIVE CONTROL: BOOM never names a SYS id outside 01..16" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# Anchors: the renumbered sections all resolve.
ANCHOR_MISSING=0
for a in sec-g sec-h sec-i sec-j; do
  grep -q "<a id=\"$a\"></a>" "$REPORT" || { ANCHOR_MISSING=$((ANCHOR_MISSING + 1)); echo "     missing anchor #$a"; }
done
[ "$ANCHOR_MISSING" -eq 0 ]
check "the renumbered section anchors (g/h/i/j) all resolve" $?
grep -q '\[(h) system\](#sec-h)' "$REPORT"
check "the BOOM Sections line links the new (h) system section" $?

# ── 17. PER-FEED absence inside a PARTIAL organ ──────────────────────────────
# The organ-level guard only fires when EVERY feed is blocked. A partial organ
# was the hole: `orchestration/task_ledger.jsonl` and `notifications/inbox.jsonl`
# do not exist on this root, but their counters were initialized to 0 and got
# rendered as measured zeros next to feeds that really did read.
echo "==> (p) per-feed absence inside a partial organ"
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q '\*\*partial\*\*'
check "SYS-03 (no task_ledger.jsonl) is status **partial**" $?
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q 'ledger rows in window: source absent'
check "SYS-03's absent ledger feed renders 'source absent'" $?
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q 'ledger rows in window: \*\*0\*\*'
check "NEGATIVE CONTROL: the absent ledger does NOT render '**0**' rows" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# Nothing in the whole SYS-03 row may be a bolded zero: every counter it carries
# is either a real reading or the absent label.
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q '\*\*0\*\*'
check "NEGATIVE CONTROL: no counter in the SYS-03 row renders '**0**'" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# But its PRESENT feeds are still measured — proving 'source absent' is not
# being smeared over the whole row.
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q 'reduced state: \*\*2\*\* task(s)'
check "NEGATIVE CONTROL: SYS-03's present state feed IS measured (2 tasks)" $?
grep -E '^\| SYS-03 \|' "$TMP/sys.md" | grep -q 'outcome cursors: \*\*1\*\* store(s)'
check "NEGATIVE CONTROL: SYS-03's present cursor feed IS measured" $?

grep -E '^\| SYS-04 \|' "$TMP/sys.md" | grep -q '\*\*partial\*\*'
check "SYS-04 (no notifications/inbox.jsonl) is status **partial**" $?
grep -E '^\| SYS-04 \|' "$TMP/sys.md" | grep -q 'inbox cards in window: source absent'
check "SYS-04's absent inbox feed renders 'source absent'" $?
grep -E '^\| SYS-04 \|' "$TMP/sys.md" | grep -qE 'inbox cards in window: \*\*0\*\*|unread overall: \*\*0\*\*'
check "NEGATIVE CONTROL: the absent inbox does NOT render '**0**' cards or unread" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -E '^\| SYS-04 \|' "$TMP/sys.md" | grep -q 'APNs receipts in window: \*\*3\*\*'
check "NEGATIVE CONTROL: SYS-04's present APNs feed IS measured (3 receipts)" $?

# ── 18. Manual directory readers, and the --bridge-config-root override ──────
# `(try? contentsOfDirectory) ?? []` ranked an unlistable directory HEALTHY with
# "0 jobs", and a job file that would not parse never marked its source bad.
echo "==> (q) directory readers / --bridge-config-root"

# 18a. CONTROL + the explicit-override path. On a synthetic root the hermeticity
# gate keeps machine-global ~/.config lanes out entirely, so SYS-01 measuring
# anything at all proves the measurement came from --bridge-config-root.
BCFG="$TMP/bridge_ok"
mkdir -p "$BCFG/claude-bridge/wake-jobs"
printf '{"messageId": "m1", "createdAt": "%s", "status": "completed"}\n' "$(inst 1)" \
  > "$BCFG/claude-bridge/wake-deliveries.jsonl"
printf '{"messageId": "m1", "createdAt": "%s", "read": true}\n' "$(inst 1)" \
  > "$BCFG/claude-bridge/claude-inbox.jsonl"
printf '{"createdAt": "%s", "state": "settled"}\n' "$(inst 1)" \
  > "$BCFG/claude-bridge/wake-jobs/job-a.json"
printf '{"createdAt": "%s", "state": "settled"}\n' "$(inst 1)" \
  > "$BCFG/claude-bridge/wake-jobs/job-b.json"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BCFG" \
  --out "$TMP/bcfg.md" > /dev/null 2>&1
BRC=$?
sysrow() { awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$2" | grep -E "^\| $1 \|"; }
[ $BRC -eq 0 ]
check "--bridge-config-root run exits 0 (rc=$BRC)" $?

# `feeds.memory.uncovered_38`: the same read-only instrument must name each
# lifecycle residue, not merely discover the directory exists. The 9th backup
# crosses the named 8-generation ceiling; an eight-day staged repair crosses
# its seven-day bound; and a newer JSONL row disagrees with the last-run
# receipt. All three remain visible even though the backup overage wins the
# row's single worst severity reason.
MEMORY_RESIDUE_ROOT="$TMP/data_memory_residue"
cp -R "$ROOT" "$MEMORY_RESIDUE_ROOT"
for n in 3 4 5 6 7 8 9; do
  mkdir -p "$MEMORY_RESIDUE_ROOT/memory/backups/generation-$n"
  printf 'SQLite format 3\000' > "$MEMORY_RESIDUE_ROOT/memory/backups/generation-$n/memory.sqlite"
done
printf '{"repair": "pending"}\n' > "$MEMORY_RESIDUE_ROOT/memory/repairs/old.staged.json"
perl -e 'utime time - 8 * 86400, time - 8 * 86400, $ARGV[0]' \
  "$MEMORY_RESIDUE_ROOT/memory/repairs/old.staged.json"
printf '{"createdAt": "%s", "status": "ok"}\n' "$(inst 0)" \
  >> "$MEMORY_RESIDUE_ROOT/memory/hygiene.jsonl"
"$TOOL_BIN" --data-root "$MEMORY_RESIDUE_ROOT" --days 7 --out "$TMP/memory_residue.md" > /dev/null 2>&1
sysrow SYS-05 "$TMP/memory_residue.md" | grep -q '\*\*9\*\*/8 generation(s)'
check "memory feed flags backup generations beyond the named ceiling" $?
sysrow SYS-05 "$TMP/memory_residue.md" | grep -q 'staged repairs: \*\*1\*\* staged, oldest'
check "memory feed reports an aged staged repair instead of hiding it" $?
sysrow SYS-05 "$TMP/memory_residue.md" | grep -q 'hygiene ledger: newest .*\*\*MISMATCH\*\* with last-run receipt'
check "memory feed reports disagreement between hygiene receipts" $?

sysrow SYS-01 "$TMP/bcfg.md" | grep -q 'jobs 7d: \*\*2\*\* of 2 on disk'
check "--bridge-config-root: SYS-01 measures the fixture's 2 wake jobs" $?
sysrow SYS-01 "$TMP/bcfg.md" | grep -q 'delivered in window: \*\*1\*\*'
check "--bridge-config-root: SYS-01 measures the fixture's delivery receipt" $?
# NEGATIVE CONTROL: the SAME data root without the flag reads absent (§16), so
# the numbers above cannot have come from anywhere but the override.
grep -E '^\| SYS-01 \|' "$TMP/sys.md" | grep -q 'jobs 7d'
check "NEGATIVE CONTROL: without --bridge-config-root SYS-01 measures nothing" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# The codex/omp lanes are missing from the fixture, so the organ is PARTIAL and
# its per-lane detail must say absent for them rather than print 0/0.
sysrow SYS-01 "$TMP/bcfg.md" | grep -q '\*\*partial\*\*'
check "--bridge-config-root: a one-lane fixture reads **partial**, not measured" $?

# 18a′. A dead-lettered brief is terminally failed, not still queued and not
# successfully consumed. The sender-facing inbox retains the unread brief but
# the two failure classes must stay separate in the diagnosis.
BTERM="$TMP/bridge_terminal"
mkdir -p "$BTERM/codex-nativeagent-bridge/reply-jobs"
: > "$BTERM/codex-nativeagent-bridge/reply-deliveries.jsonl"
{
  printf '{"messageId":"dead-1","createdAt":"%s","read":false,"deliveryStatus":"dead_letter","deliveryTerminalAt":"%s","deliveryFailureReason":"terminal_result"}\n' "$(inst 2)" "$(inst 2)"
  printf '{"messageId":"waiting-1","createdAt":"%s","read":false}\n' "$(inst 2)"
} > "$BTERM/codex-nativeagent-bridge/codex-inbox.jsonl"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BTERM" \
  --out "$TMP/bterm.md" > /dev/null 2>&1
sysrow SYS-01 "$TMP/bterm.md" | grep -q 'terminal failed: \*\*1\*\* · unconsumed >24h: \*\*1\*\*'
check "dead-lettered and merely unconsumed bridge messages are counted separately" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bterm.md" | grep -q '1 bridge message(s) terminally failed delivery'
check "an unread dead-lettered brief raises its own terminal-delivery lead" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bterm.md" | grep -q '1 bridge message(s) have sat unconsumed for over 24h'
check "a separate genuinely unconsumed brief retains the consumer-backlog lead" $?

# 18b. An ALL-UNPARSEABLE jobs directory is UNREADABLE, not "3 jobs in state
# (unparseable)". Runs everywhere — no permission bit involved.
BGAR="$TMP/bridge_garbage"
mkdir -p "$BGAR/claude-bridge/wake-jobs"
for n in 1 2 3; do printf 'this is not json at all\n' > "$BGAR/claude-bridge/wake-jobs/job-$n.json"; done
"$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BGAR" \
  --out "$TMP/bgar.md" > /dev/null 2>&1
GRC=$?
[ $GRC -eq 0 ]
check "all-unparseable jobs dir: run still exits 0 (rc=$GRC)" $?
sysrow SYS-01 "$TMP/bgar.md" | grep -q '\*\*UNREADABLE\*\*'
check "all-unparseable jobs dir marks SYS-01 **UNREADABLE**" $?
sysrow SYS-01 "$TMP/bgar.md" | grep -q 'would not parse'
check "SYS-01 names WHY it is unreadable (3 of 3 records)" $?
sysrow SYS-01 "$TMP/bgar.md" | grep -qE 'jobs 7d|\*\*0\*\*'
check "NEGATIVE CONTROL: the unreadable jobs dir prints no job count (not even 0)" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# THE POINT: severity rank 0 means it WINS the BOOM worst-organ line.
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$TMP/bgar.md" > "$TMP/bgar_boom.md"
grep -q 'worst: \*\*SYS-01' "$TMP/bgar_boom.md"
check "the unreadable organ WINS the BOOM worst-organ line" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bgar.md" | grep -q 'is UNREADABLE'
check "the unreadable jobs dir raises a ranked LEAD" $?

# 18c. A jobs directory that EXISTS and cannot be LISTED (mode 000).
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: mode-000 denies nothing to uid 0"
else
  BCHM="$TMP/bridge_chmod"
  mkdir -p "$BCHM/claude-bridge/wake-jobs"
  printf '{"createdAt": "%s", "state": "settled"}\n' "$(inst 1)" \
    > "$BCHM/claude-bridge/wake-jobs/job-a.json"
  chmod 000 "$BCHM/claude-bridge/wake-jobs"
  "$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BCHM" \
    --out "$TMP/bchm.md" > /dev/null 2>&1
  CRC2=$?
  chmod 755 "$BCHM/claude-bridge/wake-jobs"
  [ $CRC2 -eq 0 ]
  check "unlistable jobs dir: run still exits 0 (rc=$CRC2)" $?
  sysrow SYS-01 "$TMP/bchm.md" | grep -q '\*\*UNREADABLE\*\*'
  check "an unlistable jobs directory marks SYS-01 **UNREADABLE**" $?
  sysrow SYS-01 "$TMP/bchm.md" | grep -q 'could not be listed'
  check "SYS-01 names the listing failure as its reason" $?
  sysrow SYS-01 "$TMP/bchm.md" | grep -qE 'jobs 7d|held-unreleased'
  check "NEGATIVE CONTROL: the unlistable dir prints no job count" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
  awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$TMP/bchm.md" | grep -q 'worst: \*\*SYS-01'
  check "the unlistable organ WINS the BOOM worst-organ line" $?
fi

# 18c′. Preserved (undeliverable) replies: `reply-jobs/undelivered/` on the codex
# lane. The jobs scan filters `*.json` and never descends, which is how 13
# completed-but-unacknowledged replies sat invisible for two weeks (triage
# 2026-08-21). The directory is created lazily by the first preserve, so a lane
# WITHOUT one renders a dash — not 0, not "source absent" — and the cell is
# omitted from the SYS-01 row entirely when no lane has one (18a is the
# negative control for that). Age comes from the reply's OWN completion stamp.
# `inst 9` stamps 12:00Z nine days ago, so the rendered age is 8.5–9.5d
# depending on the hour this runs (8.8d at 07Z bit on 2026-08-22) — the regex
# accepts that whole window, not one evening's reading.
BPRES="$TMP/bridge_preserved"
mkdir -p "$BPRES/claude-bridge/wake-jobs" "$BPRES/codex-nativeagent-bridge/reply-jobs/undelivered"
printf '{"messageId": "m1", "createdAt": "%s", "status": "completed"}\n' "$(inst 1)" \
  > "$BPRES/claude-bridge/wake-deliveries.jsonl"
printf '{"messageId": "m1", "createdAt": "%s", "read": true}\n' "$(inst 1)" \
  > "$BPRES/claude-bridge/claude-inbox.jsonl"
printf '{"createdAt": "%s", "state": "settled"}\n' "$(inst 1)" \
  > "$BPRES/claude-bridge/wake-jobs/job-a.json"
# Two preserved replies (the live file-name shape), one 9 days old, one 2.
printf '{"id": "cx-old", "createdAt": "%s", "phase": "watching_turn", "completedExecution": {"turnResult": {"status": "completed", "completedAt": "%s", "message": "older reply text"}}}\n' \
  "$(inst 9)" "$(inst 9)" > "$BPRES/codex-nativeagent-bridge/reply-jobs/undelivered/nativeagent-codex-OLD.1786000000000.outcome_unknown.json"
printf '{"id": "cx-new", "createdAt": "%s", "phase": "watching_turn", "completedExecution": {"turnResult": {"status": "completed", "completedAt": "%s", "message": "newer reply text"}}}\n' \
  "$(inst 2)" "$(inst 2)" > "$BPRES/codex-nativeagent-bridge/reply-jobs/undelivered/nativeagent-codex-NEW.1786600000000.outcome_unknown.json"
"$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BPRES" \
  --out "$TMP/bpres.md" > /dev/null 2>&1
PRC=$?
[ $PRC -eq 0 ]
check "preserved-replies fixture: run exits 0 (rc=$PRC)" $?
sysrow SYS-01 "$TMP/bpres.md" | grep -Eq 'preserved-undelivered: \*\*2\*\* \(oldest (8\.[5-9]|9\.[0-5])d\)'
check "SYS-01 row counts the 2 preserved replies with the OLDEST reply's own age (9d)" $?
sysrow SYS-01 "$TMP/bpres.md" | grep -q '`bridge/codex/reply-jobs/undelivered/`'
check "SYS-01 registers reply-jobs/undelivered/ as a read source (reach walk knows it)" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bpres.md" | grep -q '2 completed bridge replies sit preserved as undeliverable'
check "the preserved backlog raises a ranked LEAD" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bpres.md" | grep -q 'Nothing rescans or replays that directory by design'
check "the LEAD says the directory is deliberately never replayed (no auto-redeliver)" $?
awk '/^### SYS-01 detail/{f=1} /^### SYS-02 detail/{f=0} f' "$TMP/bpres.md" > "$TMP/bpres_lanes.md"
grep -E '^\| `codex` \|' "$TMP/bpres_lanes.md" | grep -Eq '\| 2, oldest .*\((8\.[5-9]|9\.[0-5])d\) \|'
check "per-lane detail: codex shows 2 preserved + oldest stamp" $?
grep -E '^\| `claude` \|' "$TMP/bpres_lanes.md" | grep -q '— (no undelivered/ dir) |'
check "per-lane detail: a lane with no undelivered/ dir prints a dash, not 0" $?
# NEGATIVE CONTROL: 18a's fixture has no undelivered/ anywhere — its SYS-01 row
# must print no preserved cell at all (not "0"), and raise no preserved lead.
sysrow SYS-01 "$TMP/bcfg.md" | grep -q 'preserved-undelivered'
check "NEGATIVE CONTROL: no undelivered/ dir anywhere → SYS-01 prints NO preserved cell (not 0)" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/bcfg.md" | grep -q 'preserved as undeliverable'
check "NEGATIVE CONTROL: no undelivered/ dir → no preserved LEAD" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# A present-but-all-garbage undelivered/ is UNREADABLE, never "2 preserved".
BPGAR="$TMP/bridge_preserved_garbage"
mkdir -p "$BPGAR/codex-nativeagent-bridge/reply-jobs/undelivered"
for n in 1 2; do printf 'not json\n' > "$BPGAR/codex-nativeagent-bridge/reply-jobs/undelivered/bad-$n.json"; done
"$TOOL_BIN" --data-root "$ROOT" --days 7 --bridge-config-root "$BPGAR" \
  --out "$TMP/bpgar.md" > /dev/null 2>&1
sysrow SYS-01 "$TMP/bpgar.md" | grep -q '\*\*UNREADABLE\*\*'
check "an all-garbage undelivered/ dir marks SYS-01 **UNREADABLE**" $?
sysrow SYS-01 "$TMP/bpgar.md" | grep -q 'preserved-undelivered: \*\*'
check "NEGATIVE CONTROL: the unreadable undelivered/ dir prints no preserved count" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 18d. The Workshop family reader has the same shape: an executions directory
# whose every `execution.json` is garbage is UNREADABLE, not 2 executions of
# unknown status.
XROOT="$TMP/data_exec_garbage"
mkdir -p "$XROOT/traces" "$XROOT/workshop/executions/e1" "$XROOT/workshop/executions/e2"
printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "claude-opus-5", "durationMs": 10}}\n' \
  "$(inst 1)" > "$XROOT/traces/events.jsonl"
printf 'not json\n' > "$XROOT/workshop/executions/e1/execution.json"
printf 'not json\n' > "$XROOT/workshop/executions/e2/execution.json"
"$TOOL_BIN" --data-root "$XROOT" --days 7 --no-bridge-config --out "$TMP/xgar.md" > /dev/null 2>&1
XRC=$?
[ $XRC -eq 0 ]
check "all-unparseable executions dir: run still exits 0 (rc=$XRC)" $?
sysrow SYS-06 "$TMP/xgar.md" | grep -q '\*\*UNREADABLE\*\*'
check "all-unparseable executions dir marks SYS-06 **UNREADABLE**" $?
sysrow SYS-06 "$TMP/xgar.md" | grep -qE 'executions: \*\*2\*\*|executions: \*\*0\*\*'
check "NEGATIVE CONTROL: the unreadable executions family prints no count" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$TMP/xgar.md" | grep -q 'worst: \*\*SYS-06'
check "the unreadable Workshop organ WINS the BOOM worst-organ line" $?
# NEGATIVE CONTROL: the main fixture's ONE good execution record is measured.
grep -E '^\| SYS-06 \|' "$TMP/sys.md" | grep -q 'executions: \*\*1\*\* (completed=1)'
check "NEGATIVE CONTROL: a parseable executions family IS measured" $?

# ── 19. Equal-tick loops are ordered deterministically ───────────────────────
# Swift seeds its Dictionary hashing per process, so `min`/`sorted` over loops
# that share a tick to the second hand back a different winner every run. The
# "oldest tick" cell and the SYS-02 severity reason both read off that winner.
echo "==> (r) equal-tick loop determinism"
LROOT="$TMP/data_equal_ticks"
mkdir -p "$LROOT/traces" "$LROOT/logs"
printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "claude-opus-5", "durationMs": 10}}\n' \
  "$(inst 1)" > "$LROOT/traces/events.jsonl"
EQ="$(inst 3)"
printf '{"version": "1", "loops": {"loopF": "%s", "loopC": "%s", "loopA": "%s", "loopE": "%s", "loopB": "%s", "loopD": "%s"}}\n' \
  "$EQ" "$EQ" "$EQ" "$EQ" "$EQ" "$EQ" > "$LROOT/logs/background_loop_state.json"
: > "$LROOT/logs/background_loop_failures.jsonl"
DRIFT=0
for r in 1 2 3 4; do
  "$TOOL_BIN" --data-root "$LROOT" --days 7 --no-bridge-config \
    --out "$TMP/eq_$r.md" > /dev/null 2>&1
  awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$TMP/eq_$r.md" > "$TMP/eq_sys_$r.md"
  [ "$r" -eq 1 ] || cmp -s "$TMP/eq_sys_1.md" "$TMP/eq_sys_$r.md" || DRIFT=$((DRIFT + 1))
done
[ -s "$TMP/eq_sys_1.md" ] && [ "$DRIFT" -eq 0 ]
check "6 equal-tick loops: SYS section byte-identical across 4 runs ($DRIFT drifted)" $?
# And the winner is the LOWEST loop id, not whichever the hash handed out first.
grep -E '^\| SYS-02 \|' "$TMP/eq_sys_1.md" | grep -q 'oldest tick `loopA`'
check "the equal-tick tie resolves on the loop id (loopA)" $?
grep -E '^\| SYS-02 \|' "$TMP/eq_sys_1.md" | grep -q 'not ticked >1d: \*\*6\*\*'
check "NEGATIVE CONTROL: all 6 equal-tick loops are counted stale (not just one)" $?
# NEGATIVE CONTROL: the cmp above can actually detect a difference.
printf 'drifted\n' >> "$TMP/eq_sys_4.md"
cmp -s "$TMP/eq_sys_1.md" "$TMP/eq_sys_4.md"
check "NEGATIVE CONTROL: the byte-comparison DOES detect a deliberate change" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 20. WAVE-2 ORGANS (SYS-09..15) — measured vs absent, per organ family ────
# One block per organ. Every "it measured X" assertion is paired with the
# absent/partial control that proves the number came from a feed and not from a
# counter's initial value.
echo "==> (s) wave-2 organs (SYS-09..15)"

# ── SYS-09 providers/routing ──
sysrow SYS-09 "$REPORT" | grep -q 'measured'
check "SYS-09 (providers) is MEASURED on a root with pin + registry + trace" $?
sysrow SYS-09 "$REPORT" | grep -q 'surface pins: \*\*2\*\* model-pinned / 6 surface(s)'
check "SYS-09 includes canonical desk and studio_wander plus compatibility and orphan routing keys" $?
sysrow SYS-09 "$REPORT" | grep -q 'pins unresolvable: \*\*1\*\*'
check "SYS-09 names the pin whose provider has no config file" $?
sysrow SYS-09 "$REPORT" | grep -q 'pins on unknown surfaces: \*\*1\*\*'
check "SYS-09 names a persisted provider pin that no canonical routing surface can consume" $?
sysrow SYS-09 "$REPORT" | grep -q 'retired compatibility pins: \*\*1\*\* (`cognition_cue`)'
check "SYS-09 recognizes cognition_cue as retired compatibility state, not an unknown surface" $?
grep -q 'Retired compatibility pins (not failures).*`cognition_cue`' "$REPORT"
check "SYS-09 detail labels cognition_cue as historical residue" $?
sysrow SYS-09 "$REPORT" | grep -q 'ghostprovider'
check "SYS-09 names the missing provider by id" $?
sysrow SYS-09 "$REPORT" | grep -q 'substitutions in window: \*\*1\*\*'
check "SYS-09 counts the substitutedFrom row from the trace" $?
grep -q 'surface pin(s) name a provider with no config on disk' "$TMP/leads.md"
check "an unresolvable provider pin produces a ranked LEAD" $?
grep -q 'provider picker pin(s) target an unknown routing surface' "$TMP/leads.md"
check "an unserved provider picker key produces a ranked LEAD" $?
# THE SECURITY ASSERTION: the credential allowlist is a boundary, not a comment.
! grep -q "$PLANTED_SECRET" "$REPORT"
check "SECRET DISCIPLINE: no api_key/access_token/device token reaches the report" $?
# NEGATIVE CONTROL: the report DID read those files, so the assertion above is
# not passing because the reader never opened them.
grep -q 'auth `api_key`' "$REPORT"
check "NEGATIVE CONTROL: the allowlisted \`auth_mode\` DID come out of that same file" $?

# ── Capsule anatomy: every gated row has an explicit source-absent/zero rate ──
grep -E '^\| `fingerprint` \|' "$REPORT" | grep -q '| 6 | 100.0% |'
check "capsule anatomy distinguishes a present fingerprint headline from a missing one" $?
grep -E '^\| `- Settling:` \|' "$REPORT" | grep -q '| 6 | 100.0% |'
check "capsule anatomy losslessly reassembles a Settling marker split across canonical chunks" $?
grep -E '^\| `- Sound: rut awareness` \|' "$REPORT" | grep -q '| 6 | 100.0% |'
check "capsule anatomy separates the rut-awareness Sound producer" $?
grep -E '^\| `- Sound: exemplar echo` \|' "$REPORT" | grep -q '| 0 | 0.0% |'
check "capsule anatomy reports a real zero for the distinct Sound exemplar producer" $?
grep -q 'dominated by one word (`curious`, 100% of capsules)' "$TMP/leads.md"
check "fingerprint dominance uses capsule presence rather than word-emission share" $?
CAPSULE_ABSENT_ROOT="$TMP/data_capsule_absent"
mkdir -p "$CAPSULE_ABSENT_ROOT/turn_traces"
printf '{"kind":"context.snapshot","ts":"%s","surface":"chat","payload":{"_preview":"{\\"dynamicBytes\\":1}"}}\n' "$(inst 1)" \
  > "$CAPSULE_ABSENT_ROOT/turn_traces/$(day 1).jsonl"
"$TOOL_BIN" --data-root "$CAPSULE_ABSENT_ROOT" --days 7 --out "$TMP/capsule_absent.md" > /dev/null 2>&1
awk '/^### Capsule anatomy/{f=1} /^### REM pins/{f=0} f' "$TMP/capsule_absent.md" | grep -q 'source absent'
check "capsule anatomy labels an absent cognitivePreview source instead of rendering zero-rate rows" $?
awk '/^### Capsule anatomy/{f=1} /^### REM pins/{f=0} f' "$TMP/capsule_absent.md" | grep -q '^| `fingerprint`'
check "NEGATIVE CONTROL: source-absent capsule anatomy does not render a fingerprint zero" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── SYS-10 tools ──
grep -q '^### Tool execution artifact inventory' "$REPORT"
check "SYS-10 renders the registry/artifact inventory rather than only a registry row count" $?
grep -q 'registry rows without `active/` artifact.*`flakytool`' "$REPORT"
check "SYS-10 names a registry row whose active artifact is missing" $?
grep -q 'Tool registry and active artifact directory diverge' "$TMP/leads.md"
check "registry/artifact divergence produces a ranked LEAD" $?
sysrow SYS-10 "$REPORT" | grep -q 'ok \*\*8\*\* / failed \*\*4\*\*'
check "SYS-10 counts tool.dispatch ok/failed out of traces/events.jsonl" $?
sysrow SYS-10 "$REPORT" | grep -q 'worst failing: `flakytool`×4'
check "SYS-10 names the worst-failing tool" $?
sysrow SYS-10 "$REPORT" | grep -q 'envelope \*\*FAIL\*\* (≤25% overall; ≤25% per tool with ≥10 calls)'
check "SYS-10 fails the envelope for an eleven-call tool and a >25% overall failure rate" $?
TOOL_PASS_ROOT="$TMP/data_tool_envelope_pass"
cp -R "$ROOT" "$TOOL_PASS_ROOT"
perl -pi -e 's/"status": "failed"/"status": "ok"/g; s/"outcome": "failed"/"outcome": "completed"/g' "$TOOL_PASS_ROOT/traces/events.jsonl"
"$TOOL_BIN" --data-root "$TOOL_PASS_ROOT" --days 7 --out "$TMP/tool_envelope_pass.md" > /dev/null 2>&1
sysrow SYS-10 "$TMP/tool_envelope_pass.md" | grep -q 'envelope \*\*PASS\*\* (≤25% overall; ≤25% per tool with ≥10 calls)'
check "SYS-10 passes the same >=10-call envelope when the real event rows recover" $?
sysrow SYS-10 "$REPORT" | grep -q 'gate refusals in window: \*\*1\*\*'
check "SYS-10 reports gate refusals from the AUDIT feed, not the trace" $?
sysrow SYS-10 "$REPORT" | grep -q 'approval latency: p50 2.0h'
check "SYS-10 derives approval latency from createdAt→resolvedAt" $?
grep -q '^### SYS-10 detail' "$REPORT"
check "SYS-10 has a per-tool detail block" $?
# errorDetail (2026-08-21): the per-tool table shows the tracer's bounded failure
# reasons (top by count), and the failure-streak severity names the top one.
grep -q 'failure reason(s)' "$REPORT"
check "SYS-10 detail table has a failure reason(s) column" $?
grep -q '`status=failed \\| planted_reason_0`×2, `status=failed \\| planted_reason_1`×2' "$REPORT"
check "SYS-10 detail surfaces receipt.errorDetail counts for the failing tool" $?

# ── SYS-11 sync ──
sysrow SYS-11 "$REPORT" | grep -q 'companion snapshots: \*\*2\*\* cached'
check "SYS-11 counts the cached companion snapshots" $?
sysrow SYS-11 "$REPORT" | grep -q '\*\*1 digest(s) with no cached file\*\*'
check "SYS-11 catches a digest naming an uncached snapshot" $?
sysrow SYS-11 "$REPORT" | grep -q 'write-back queue: \*\*1\*\* unanswered of 2'
check "SYS-11 counts unanswered write-back transactions" $?
sysrow SYS-11 "$REPORT" | grep -q 'public sync: `failed`'
check "SYS-11 surfaces a failed public sync" $?
grep -q 'companion snapshot digest(s) name a file that is not cached' "$TMP/leads.md"
check "an orphaned snapshot digest produces a ranked LEAD" $?
grep -q 'The last public sync did not succeed' "$TMP/leads.md"
check "a failed public sync produces a ranked LEAD" $?

# ── SYS-12 chat sessions ──
sysrow SYS-12 "$REPORT" | grep -q '\*\*partial\*\*'
check "SYS-12 reads PARTIAL with chat/pinned_session_ids.json absent" $?
sysrow SYS-12 "$REPORT" | grep -q 'pinned: source absent'
check "SYS-12's pinned cell says 'source absent', not 0 (per-feed guard)" $?
sysrow SYS-12 "$REPORT" | grep -q 'sessions: \*\*2\*\* (app=1, telegram=1)'
check "SYS-12 counts sessions per source" $?
sysrow SYS-12 "$REPORT" | grep -q 'user \*\*3\*\* / assistant \*\*3\*\*'
check "SYS-12 counts in-window turns from every canonical transcript file" $?
sysrow SYS-12 "$REPORT" | grep -q 'archived: \*\*1\*\*'
check "SYS-12 counts the archive tail" $?
grep -q 'chat session(s) have an index row but no message file' "$TMP/leads.md"
check "an index row with no transcript produces a ranked LEAD" $?
# NEGATIVE CONTROL: the 40-day-old message row is NOT counted as a turn; the
# six current rows are exact.
sysrow SYS-12 "$REPORT" | grep -q 'turns in window: \*\*6\*\*'
check "NEGATIVE CONTROL: the 40-day-old message row is excluded from the window" $?
sysrow SYS-12 "$REPORT" | grep -q 'absent \*\*1\*\* (reported separately, not zero)'
check "SYS-12 reports absent outcome observations separately from zero" $?
sysrow SYS-12 "$REPORT" | grep -q 'dark >95%'
check "SYS-12 renders >95% non-terminal outcome lanes" $?
sysrow SYS-12 "$REPORT" | grep -q '`reaction` \[observed=2\]'
check "SYS-12 joins structured and adjacency reaction evidence into outcome health" $?
grep -q 'Outcome dimension .* has no promoter wired' "$TMP/leads.md"
check "SYS-12 ranks permanently-dark outcome lanes as promoter leads" $?
grep -q 'Outcome dimension `reaction` has no promoter wired' "$TMP/leads.md"
check "NEGATIVE CONTROL: reaction evidence prevents a false missing-promoter lead" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# Missing canonical population is an unavailable source, never six measured
# zeroes. Keep this as a separate root so the branch cannot pass because the
# main fixture happened to contain transcripts.
CHAT_ABSENT_ROOT="$TMP/chat_population_absent"
mkdir -p "$CHAT_ABSENT_ROOT/chat/archive"
printf '[]\n' > "$CHAT_ABSENT_ROOT/chat/sessions.json"
: > "$CHAT_ABSENT_ROOT/chat/archive/sessions.jsonl"
printf '[]\n' > "$CHAT_ABSENT_ROOT/chat/pinned_session_ids.json"
printf '{}\n' > "$CHAT_ABSENT_ROOT/chat/mac_turn_lifecycle.json"
"$TOOL_BIN" --data-root "$CHAT_ABSENT_ROOT" --days 7 \
  --out "$TMP/chat_population_absent.md" > /dev/null 2>&1
sysrow SYS-12 "$TMP/chat_population_absent.md" | grep -q 'canonical `chat/messages/` population is unavailable. This is not a zero.'
check "SYS-12 labels a missing canonical population absent rather than zero" $?
grep -q 'Outcome dimension population source is absent' "$TMP/chat_population_absent.md"
check "SYS-12 ranks the missing-population branch" $?

# An existing directory that cannot be listed is UNREADABLE, not absent and
# not an empty measured population. Mode 000 is ineffective for uid 0.
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: mode-000 transcript directory denies nothing to uid 0"
else
  CHAT_UNREADABLE_ROOT="$TMP/chat_population_unreadable"
  mkdir -p "$CHAT_UNREADABLE_ROOT/chat/archive" "$CHAT_UNREADABLE_ROOT/chat/messages"
  printf '[]\n' > "$CHAT_UNREADABLE_ROOT/chat/sessions.json"
  : > "$CHAT_UNREADABLE_ROOT/chat/archive/sessions.jsonl"
  printf '[]\n' > "$CHAT_UNREADABLE_ROOT/chat/pinned_session_ids.json"
  printf '{}\n' > "$CHAT_UNREADABLE_ROOT/chat/mac_turn_lifecycle.json"
  printf '{}\n' > "$CHAT_UNREADABLE_ROOT/chat/messages/hidden.jsonl"
  chmod 000 "$CHAT_UNREADABLE_ROOT/chat/messages"
  "$TOOL_BIN" --data-root "$CHAT_UNREADABLE_ROOT" --days 7 \
    --out "$TMP/chat_population_unreadable.md" > /dev/null 2>&1
  CHAT_UNREADABLE_RC=$?
  chmod 755 "$CHAT_UNREADABLE_ROOT/chat/messages"
  [ $CHAT_UNREADABLE_RC -eq 0 ]
  check "unlistable transcript directory: instrument still exits 0" $?
  sysrow SYS-12 "$TMP/chat_population_unreadable.md" | grep -q '\*\*UNREADABLE\*\*'
  check "SYS-12 marks an unlistable transcript population UNREADABLE" $?
  sysrow SYS-12 "$TMP/chat_population_unreadable.md" | grep -q 'directory listing failed'
  check "SYS-12 names the transcript listing failure" $?
  sysrow SYS-12 "$TMP/chat_population_unreadable.md" | grep -q 'valid observations'
  check "NEGATIVE CONTROL: unreadable transcripts render no outcome counts" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
  grep -q 'Outcome dimension population source is unreadable' "$TMP/chat_population_unreadable.md"
  check "SYS-12 ranks the unreadable-population branch" $?
fi

# ── SYS-13 security/trust ──
sysrow SYS-13 "$REPORT" | grep -q '\*\*partial\*\*'
check "SYS-13 reads PARTIAL with trust/policy.json absent" $?
sysrow SYS-13 "$REPORT" | grep -q 'trust policy: source absent'
check "SYS-13's trust-policy cell says 'source absent', not 0 (per-feed guard)" $?
sysrow SYS-13 "$REPORT" | grep -q 'effective protective controls: source absent'
check "SYS-13's effective-protection cell keeps an absent policy absent, not zero" $?
sysrow SYS-13 "$REPORT" | grep -qE 'effective protective controls: \*\*[0-9]+/6 enabled'
check "NEGATIVE CONTROL: an absent trust policy renders no enabled-control count" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
sysrow SYS-13 "$REPORT" | grep -q 'refused \*\*1\*\*'
check "SYS-13 counts the gate refusal" $?
sysrow SYS-13 "$REPORT" | grep -q '\*\*1 unanswered\*\*'
check "SYS-13 counts the approval nobody decided" $?
sysrow SYS-13 "$REPORT" | grep -q 'canary trips: \*\*1\*\* in window'
check "SYS-13 counts the in-window canary trip" $?
sysrow SYS-13 "$REPORT" | grep -q 'mac permissions: \*\*3\*\*/4 grant(s)'
check "SYS-13 counts NESTED permission grants, not just top-level bools" $?
awk '/^### SYS-13 detail/{f=1} /^## \(i\)/{f=0} f' "$REPORT" > "$TMP/sys13.md"
grep -q '^#### Effective security-policy posture' "$TMP/sys13.md"
check "SYS-13 renders a per-key effective security-policy posture table" $?
grep -qF '| `killSwitchEnabled` | false | default (policy source absent) |' "$TMP/sys13.md"
check "missing trust policy reports the effective default with source-absent provenance" $?
grep -qF '| `toolSigningRequired` | false | default (policy source absent) |' "$TMP/sys13.md"
check "missing trust policy keeps the YOLO signing default explicitly visible" $?

# Complete SYS-13 fixtures exercise the actual persisted boundaries rather than
# letting policy posture inherit a PARTIAL row from unrelated absent feeds.
# Empty JSONL/array sources are deliberately present and readable: healthy means
# all six SecurityCenter protections are on, not that no source was inspected.
seed_sys13_complete_root() {
  local fixture_root="$1"
  local policy_json="$2"
  mkdir -p "$fixture_root/security/autonomy_promotion" "$fixture_root/workflows/approvals" \
           "$fixture_root/trust"
  : > "$fixture_root/security/audit.jsonl"
  : > "$fixture_root/security/canary_trips.jsonl"
  printf '{"calendar":{"read":true}}\n' > "$fixture_root/security/mac_integration_permissions.json"
  printf '%s\n' "$(inst 1)" > "$fixture_root/security/autonomy_promotion/last_scan"
  printf '%s\n' "$policy_json" > "$fixture_root/trust/policy.json"
  printf '[]\n' > "$fixture_root/workflows/approvals/requests.json"
  printf '{"spends":{}}\n' > "$fixture_root/workflows/approvals/effect_spends.json"
  : > "$fixture_root/mac_control_audit.jsonl"
  : > "$fixture_root/mac_control_bridge_audit.jsonl"
}

SHROOT="$TMP/data_security_matrix_healthy"
seed_sys13_complete_root "$SHROOT" '{"securityPolicy":{"originTrustEnabled":true,"signedRemoteCommandsRequired":true,"promptInjectionShieldEnabled":true,"secretFirewallEnabled":true,"rollbackByDefault":true,"auditReceiptsEnabled":true}}'
"$TOOL_BIN" --data-root "$SHROOT" --days 7 --out "$TMP/security_matrix_healthy.md" > /dev/null 2>&1
sysrow SYS-13 "$TMP/security_matrix_healthy.md" | grep -q 'measured · healthy'
check "complete SYS-13 fixture with all live protections enabled is measured healthy" $?
sysrow SYS-13 "$TMP/security_matrix_healthy.md" | grep -q 'effective protective controls: \*\*6/6 enabled\*\*'
check "healthy SYS-13 derives all six enabled controls from trust/policy.json" $?
sysrow SYS-13 "$TMP/security_matrix_healthy.md" | grep -q 'weakened:'
check "NEGATIVE CONTROL: healthy policy is not labelled weakened" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

SAROOT="$TMP/data_security_matrix_adverse"
seed_sys13_complete_root "$SAROOT" '{"securityPolicy":{"originTrustEnabled":false,"signedRemoteCommandsRequired":false,"promptInjectionShieldEnabled":false,"secretFirewallEnabled":false,"rollbackByDefault":false,"auditReceiptsEnabled":false}}'
"$TOOL_BIN" --data-root "$SAROOT" --days 7 --out "$TMP/security_matrix_adverse.md" > /dev/null 2>&1
sysrow SYS-13 "$TMP/security_matrix_adverse.md" | grep -q 'measured · \*\*FAILING\*\*'
check "complete SYS-13 fixture with disabled protections is measured failure" $?
sysrow SYS-13 "$TMP/security_matrix_adverse.md" | grep -q 'effective protective controls: \*\*0/6 enabled\*\*; \*\*weakened:\*\* origin trust, remote command signing, prompt-injection shield, secret firewall, rollback receipts, audit receipts'
check "adverse SYS-13 names every disabled live protection" $?
sysrow SYS-13 "$TMP/security_matrix_adverse.md" | grep -q 'canary trips: \*\*0\*\* in window'
check "adverse policy fixture has no canary trip to explain its failure" $?
sysrow SYS-13 "$TMP/security_matrix_adverse.md" | grep -q 'approval inbox: \*\*0\*\* total, 0 raised in window'
check "adverse policy fixture has no unanswered approval to explain its failure" $?
awk '/^## \(j\) LEADS/{f=1} f' "$TMP/security_matrix_adverse.md" | grep -q 'Security policy disabled protective controls'
check "disabled live protections produce a ranked SYS-13 lead" $?

# Adverse partial policy: two persisted choices must stay explicit while every
# omitted sibling is named as a default, not silently omitted or relabeled as a
# user choice. This root has no audit/approval rows on purpose; posture is its
# own canonical trust read, independent of activity telemetry.
SPROOT="$TMP/data_security_posture_partial"
mkdir -p "$SPROOT/trust"
printf '{"securityPolicy":{"killSwitchEnabled":true,"toolSigningRequired":true}}\n' > "$SPROOT/trust/policy.json"
"$TOOL_BIN" --data-root "$SPROOT" --days 7 --out "$TMP/security_posture_partial.md" > /dev/null 2>&1
awk '/^### SYS-13 detail/{f=1} /^## \(i\)/{f=0} f' "$TMP/security_posture_partial.md" > "$TMP/security_posture_partial_section.md"
grep -qF '| `killSwitchEnabled` | true | explicit |' "$TMP/security_posture_partial_section.md"
check "partial trust policy keeps saved kill-switch intent explicit" $?
grep -qF '| `toolSigningRequired` | true | explicit |' "$TMP/security_posture_partial_section.md"
check "partial trust policy keeps saved signing intent explicit" $?
grep -qF '| `originTrustEnabled` | true | default (key missing) |' "$TMP/security_posture_partial_section.md"
check "partial trust policy backfills an omitted sibling with default provenance" $?
grep -qF '| `remoteHighRiskDefault` | `block` | default (key missing) |' "$TMP/security_posture_partial_section.md"
check "partial trust policy renders string defaults as effective values, not booleans" $?
# Provenance is the contract: a concrete value alone is insufficient because a
# default matching the persisted value would otherwise masquerade as intent.
grep -qF '| `killSwitchEnabled` | true | default' "$TMP/security_posture_partial_section.md"
check "NEGATIVE CONTROL: an explicit kill-switch is never relabeled as default" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF '| `originTrustEnabled` | true | explicit |' "$TMP/security_posture_partial_section.md"
check "NEGATIVE CONTROL: a backfilled sibling is never relabeled as explicit" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# Malformed persisted authority must fail closed. This is deliberately a
# canonical trust/policy.json fixture rather than an invented report envelope:
# the reader must mark its source unreadable and refuse to infer per-key state.
SUROOT="$TMP/data_security_posture_unreadable"
seed_sys13_complete_root "$SUROOT" '{"securityPolicy":{"originTrustEnabled":"false"}}'
"$TOOL_BIN" --data-root "$SUROOT" --days 7 --out "$TMP/security_posture_unreadable.md" > /dev/null 2>&1
sysrow SYS-13 "$TMP/security_posture_unreadable.md" | grep -q '\*\*UNREADABLE\*\*'
check "malformed canonical security policy marks complete-source SYS-13 unreadable" $?
awk '/^### SYS-13 detail/{f=1} /^## \(i\)/{f=0} f' "$TMP/security_posture_unreadable.md" > "$TMP/security_posture_unreadable_section.md"
grep -q '^#### Effective security-policy posture' "$TMP/security_posture_unreadable_section.md"
check "unreadable canonical policy still renders its fail-closed posture explanation" $?
grep -q 'source unreadable' "$TMP/security_posture_unreadable_section.md"
check "unreadable canonical policy names the fail-closed source state" $?
grep -qF '| `killSwitchEnabled` |' "$TMP/security_posture_unreadable_section.md"
check "NEGATIVE CONTROL: unreadable policy yields no inferred per-key posture" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'security canary trip(s) fired' "$TMP/leads.md"
check "a canary trip produces a ranked LEAD" $?
grep -q 'approval request(s) were never answered' "$TMP/leads.md"
check "an unanswered approval produces a ranked LEAD" $?

# ── SYS-14 update lane ──
sysrow SYS-14 "$REPORT" | grep -q '\*\*absent\*\*'
check "SYS-14 (machine-global update state) is ABSENT on a synthetic root" $?
sysrow SYS-14 "$REPORT" | grep -q 'source absent'
check "SYS-14 renders the 'source absent' label" $?
# NOTE: the ORGAN NAME contains the phrase "honesty flag", so the control must
# match only strings a live reading can produce.
sysrow SYS-14 "$REPORT" | grep -qE 'SUFeedURL|installed bundle:|Sparkle state:|CFBundle'
check "NEGATIVE CONTROL: the absent update organ prints NO bundle/feed reading" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
# And --no-machine-state names the FLAG as the reason, not a missing bundle.
"$TOOL_BIN" --data-root "$ROOT" --days 7 --no-machine-state --out "$TMP/nomach.md" > /dev/null 2>&1
sysrow SYS-14 "$TMP/nomach.md" | grep -q '\*\*absent\*\*'
check "--no-machine-state keeps SYS-14 absent" $?
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$TMP/nomach.md" | grep -q 'organs measured'
check "--no-machine-state still renders the BOOM system line" $?

# ── SYS-15 research connector / blind-spot instrumentation ──
# The complete main root is the positive control: three distinct persisted
# authorities were actually opened, so configuration, a lab run, and a direct
# receipt each have provenance in the row. The following roots prove that an
# absent or unreadable authority cannot fall through to false/zero, and that a
# recorded adverse lab outcome stays adverse even with a non-empty config.
sysrow SYS-15 "$REPORT" | grep -q 'measured · healthy'
check "SYS-15 reads the complete research evidence boundary as measured" $?
sysrow SYS-15 "$REPORT" | grep -q 'configured=\*\*true\*\*'
check "SYS-15 reports a non-empty connector configuration without exposing its URL" $?
grep -q 'research-fixture.invalid' "$REPORT"
check "NEGATIVE CONTROL: SYS-15 does not expose the configured connector endpoint" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
sysrow SYS-15 "$REPORT" | grep -q 'lab evidence: \*\*1\*\* saved lab run(s)'
check "SYS-15 reads the persisted ResearchLabRun evidence" $?
sysrow SYS-15 "$REPORT" | grep -q 'direct connector receipts: \*\*1\*\* receipt file(s)'
check "SYS-15 independently reads the direct search/fetch receipt family" $?
sysrow SYS-15 "$REPORT" | grep -q 'research/config.json.*research/lab/runs.json.*research/receipt-files/'
check "SYS-15 renders actionable source provenance for all three research authorities" $?

# Negative control: no research directory at all. Its row must report an
# unavailable evidence boundary, not configured=false, 0 runs, or 0 receipts.
RABSENT="$TMP/data_research_absent"
mkdir -p "$RABSENT/turn_traces"
printf '{"kind":"context.summary","ts":"%s","payload":{"counts":{},"flags":{},"stageMs":{}}}\n' "$(inst 1)" \
  > "$RABSENT/turn_traces/$(day 1).jsonl"
"$TOOL_BIN" --data-root "$RABSENT" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/research_absent.md" > /dev/null 2>&1
sysrow SYS-15 "$TMP/research_absent.md" | grep -q 'source absent'
check "SYS-15 labels a wholly absent research boundary source absent" $?
sysrow SYS-15 "$TMP/research_absent.md" | grep -qE 'configured=|saved lab run|receipt file'
check "NEGATIVE CONTROL: absent research evidence renders no false/zero counters" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'Research connector evidence is absent' "$TMP/research_absent.md"
check "absent research evidence produces a provenance-bearing actionable lead" $?

# A malformed configuration field is an unreadable authority, even though the
# sibling lab array and receipt directory are readable. No `configured=false`
# claim is allowed to escape this all-or-nothing organ row.
RUNREAD="$TMP/data_research_unreadable"
mkdir -p "$RUNREAD/research/lab"
printf '{"searxng_base_url": 9}\n' > "$RUNREAD/research/config.json"
printf '[]\n' > "$RUNREAD/research/lab/runs.json"
"$TOOL_BIN" --data-root "$RUNREAD" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/research_unreadable.md" > /dev/null 2>&1
sysrow SYS-15 "$TMP/research_unreadable.md" | grep -q '\*\*UNREADABLE\*\*'
check "SYS-15 marks malformed persisted connector configuration UNREADABLE" $?
sysrow SYS-15 "$TMP/research_unreadable.md" | grep -q 'source unreadable'
check "SYS-15 names unreadable research evidence rather than inferring a disabled connector" $?
sysrow SYS-15 "$TMP/research_unreadable.md" | grep -qE 'configured=\*\*false\*\*|saved lab run|receipt file'
check "NEGATIVE CONTROL: unreadable research evidence renders no false/zero counters" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# Adverse control: config is present and the source family is readable, but the
# real lab receipt says `needs_connector`. That outcome must be a failure, not
# hidden behind configuration success or an empty direct-receipt count.
RADVERSE="$TMP/data_research_adverse"
mkdir -p "$RADVERSE/research/lab"
printf '{"searxng_base_url": "http://research-fixture.invalid"}\n' > "$RADVERSE/research/config.json"
printf '[{"id":"lab-failed","objective":"fixture","status":"needs_connector","createdAt":"%s","connector":"none"}]\n' "$(inst 1)" \
  > "$RADVERSE/research/lab/runs.json"
"$TOOL_BIN" --data-root "$RADVERSE" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/research_adverse.md" > /dev/null 2>&1
sysrow SYS-15 "$TMP/research_adverse.md" | grep -q 'measured · \*\*FAILING\*\*'
check "SYS-15 ranks a persisted needs_connector run as an adverse outcome" $?
sysrow SYS-15 "$TMP/research_adverse.md" | grep -qF 'needs\_connector=1'
check "SYS-15 renders the persisted adverse lab status with its source provenance" $?
grep -q 'Research lab recorded `needs_connector` outcome' "$TMP/research_adverse.md"
check "research adverse outcome produces an actionable lead without claiming endpoint success" $?

# ── SYS-16 Browser operation-store / projection blind-spot instrumentation ──
# The main fixture exercises every condition that had no instrument reader:
# all 200 retained rows, a `running` row past the one-hour recovery bound, and
# a projection outbox that has not drained. The exact numbers make this fail if
# any metric is merely initialized to zero or reads the wrong Browser store.
sysrow SYS-16 "$REPORT" | grep -q 'measured · \*\*FAILING\*\*'
check "SYS-16 reads the complete Browser evidence boundary as adverse" $?
sysrow SYS-16 "$REPORT" | grep -q 'runs: \*\*200 / 200\*\* retained; headroom \*\*0\*\*'
check "SYS-16 reports Browser run retention capacity and zero headroom" $?
sysrow SYS-16 "$REPORT" | grep -q 'running >1h: \*\*1\*\* (`browser-stranded` oldest'
check "SYS-16 identifies the stranded production running row" $?
sysrow SYS-16 "$REPORT" | grep -q 'pending projection >1h: \*\*1\*\* stale run(s); \*\*1\*\* queued transition(s)'
check "SYS-16 identifies the old canonical projection outbox" $?
sysrow SYS-16 "$REPORT" | grep -q 'receipts: newest'
check "SYS-16 separately reports the newest derived Browser receipt" $?
sysrow SYS-16 "$REPORT" | grep -q 'native_power/browser/runs.json.*native_power/browser/receipts.jsonl'
check "SYS-16 carries both canonical Browser source provenances" $?
grep -q 'Browser run store has no eviction headroom' "$REPORT"
check "Browser capacity exhaustion raises an actionable recovery lead" $?

# Missing is unknown, not an empty Browser history. A minimal trace keeps the
# reach walk valid while both Browser authorities remain absent.
BABSENT="$TMP/data_browser_absent"
mkdir -p "$BABSENT/turn_traces"
printf '{"kind":"context.summary","ts":"%s","payload":{"counts":{},"flags":{},"stageMs":{}}}\n' "$(inst 1)" \
  > "$BABSENT/turn_traces/$(day 1).jsonl"
"$TOOL_BIN" --data-root "$BABSENT" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/browser_absent.md" > /dev/null 2>&1
sysrow SYS-16 "$TMP/browser_absent.md" | grep -q 'source absent'
check "SYS-16 labels missing Browser stores source absent" $?
sysrow SYS-16 "$TMP/browser_absent.md" | grep -qE 'runs: \*\*0|running >1h: \*\*0|queued transition'
check "NEGATIVE CONTROL: absent Browser stores render no false zero lifecycle counters" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -q 'Browser operation evidence is absent' "$TMP/browser_absent.md"
check "absent Browser evidence raises a provenance-bearing lead" $?

# A present wrong-shaped canonical store is unreadable, even with a valid
# receipt sibling. It must never be treated as an empty run array.
BUNREAD="$TMP/data_browser_unreadable"
mkdir -p "$BUNREAD/native_power/browser" "$BUNREAD/turn_traces"
printf '{"not":"a run array"}\n' > "$BUNREAD/native_power/browser/runs.json"
printf '{"id":"receipt-ok","createdAt":"%s"}\n' "$(inst 1)" > "$BUNREAD/native_power/browser/receipts.jsonl"
printf '{"kind":"context.summary","ts":"%s","payload":{"counts":{},"flags":{},"stageMs":{}}}\n' "$(inst 1)" \
  > "$BUNREAD/turn_traces/$(day 1).jsonl"
"$TOOL_BIN" --data-root "$BUNREAD" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/browser_unreadable.md" > /dev/null 2>&1
sysrow SYS-16 "$TMP/browser_unreadable.md" | grep -q '\*\*UNREADABLE\*\*'
check "SYS-16 marks a malformed canonical Browser run store unreadable" $?
sysrow SYS-16 "$TMP/browser_unreadable.md" | grep -q 'source unreadable'
check "SYS-16 names unreadable Browser evidence rather than deriving a zero" $?
sysrow SYS-16 "$TMP/browser_unreadable.md" | grep -qE 'runs: \*\*0|running >1h: \*\*0|queued transition'
check "NEGATIVE CONTROL: unreadable Browser runs render no false zero lifecycle counters" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 21. The uncovered-feed BURNDOWN line ─────────────────────────────────────
echo "==> (t) uncovered-feed burndown"
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$REPORT" | grep -q 'uncovered feed(s)'
check "BOOM carries the reach line" $?
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$REPORT" | grep -qE 'baseline of [0-9]+'
check "the reach line carries the tracked BASELINE" $?
awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$REPORT" \
  | grep -qE '(\*\*[0-9]+ closed\*\*|\*\*[0-9]+ NEW\*\*|unchanged from)'
check "the reach line states the delta against the baseline" $?
grep -q '^- burndown:' "$REPORT"
check "section (i) repeats the burndown with its rules" $?
# The two must agree — a BOOM number that disagrees with its own section is the
# summary-counter drift this report is supposed to be immune to.
BOOM_UNCOV=$(awk '/^## BOOM/{f=1} /^<a id="sec-sources"/{f=0} f' "$REPORT" \
  | grep -oE '\*\*[0-9]+ uncovered feed\(s\)\*\*' | grep -oE '[0-9]+' | head -1)
SEC_UNCOV=$(grep -oE '\*\*NOT COVERED: [0-9]+\*\*' "$REPORT" | grep -oE '[0-9]+' | head -1)
[ -n "$BOOM_UNCOV" ] && [ "$BOOM_UNCOV" = "$SEC_UNCOV" ]
check "BOOM's uncovered count equals section (i)'s (${BOOM_UNCOV:-?} vs ${SEC_UNCOV:-?})" $?

# ── 22. WHOLE-REPORT determinism over a FROZEN root ──────────────────────────
# §19 pinned the SYS section only. The older (a)/(f)/(e)/(i) tables sorted
# dictionary-derived rows with no tie-break, so the ENTIRE report drifted
# between runs over identical bytes. `--now` pins the clock (the one other
# thing that moves) so the comparison can be a byte comparison.
echo "==> (u) whole-report determinism over a frozen root"
DET_DRIFT=0
for r in 1 2 3; do
  "$TOOL_BIN" --data-root "$ROOT" --days 7 --no-bridge-config --no-machine-state \
    --now 2026-08-21T12:00:00Z --out "$TMP/whole_$r.md" > /dev/null 2>&1
  [ "$r" -eq 1 ] || cmp -s "$TMP/whole_1.md" "$TMP/whole_$r.md" || DET_DRIFT=$((DET_DRIFT + 1))
done
[ -s "$TMP/whole_1.md" ] && [ "$DET_DRIFT" -eq 0 ]
check "ENTIRE report byte-identical across 3 runs over a frozen root ($DET_DRIFT drifted)" $?
grep -q 'CLOCK PINNED by' "$TMP/whole_1.md"
check "a --now run DECLARES the pinned clock in the header" $?
# NEGATIVE CONTROL: without --now the reports legitimately differ, so the
# comparison above is testing tie-breaks and not a no-op.
grep -q 'CLOCK PINNED by' "$REPORT"
check "NEGATIVE CONTROL: a normal run carries no pinned-clock banner" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 23. WAVE 3 — turn-trace kind vocabulary + the uncovered ACTIVE feeds ─────
#
# Everything above grades the instrument's older sections. This block pins the
# two sections added for the `feeds` fence of `docs/evals/ledger.json`:
#
#   (i.1) TURN-TRACE VOCABULARY — the kind REACHABILITY table (a declared kind
#         with zero rows is printed as a row, never omitted), the lifecycle
#         milestone pairing, the `stream.tick` budget bounds, and the per-DAY
#         readability column that keeps "unreadable" apart from "empty".
#   (i.2) WAVE-3 FEEDS — one reading per uncovered ACTIVE feed, each against a
#         NAMED bound, each raising a lead when the bound is crossed.
#
# The fixture root plants BOTH halves of every check: healthy turns AND
# violating ones, a live surface AND a failing one. A detector that fired on
# everything would pass a positive-only fixture and prove nothing, so every
# assertion here has its negative control in the same run — plus the main
# `$REPORT`, where none of these feeds exist at all, as the absent-is-not-zero
# control.
echo "==> (v) wave 3: turn-trace vocabulary + uncovered active feeds"
W3="$TMP/w3root"
mkdir -p "$W3/turn_traces" "$W3/traces" "$W3/activity" "$W3/builder_audit" \
         "$W3/slack" "$W3/telegram/update_inbox" "$W3/doctor" "$W3/oauth_tokens" \
         "$W3/mac_control" "$W3/chat/session_state" "$W3/chat/sessions" "$W3/logs" "$W3/from_codex" \
         "$W3/github_command" "$W3/disabled/retired-github-command/github_command"

W3D="$(day 1)"
W3DAY="$W3/turn_traces/$W3D.jsonl"
: > "$W3DAY"

# ── HEALTHY turns: every milestone in order, two ticks, one enqueue ──────────
for i in 1 2 3; do
  printf '{"kind": "turn.accepted", "ts": "%sT10:00:00Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"schema": "turn.lifecycle.v1", "milestone": "turn.accepted", "observedBy": "engine"}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "context.ready", "ts": "%sT10:00:01Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"schema": "turn.lifecycle.v1", "milestone": "context.ready", "observedBy": "assembly", "elapsedMs": 1000}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "provider.requestStarted", "ts": "%sT10:00:02Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"milestone": "provider.requestStarted", "observedBy": "provider"}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "provider.firstDelta", "ts": "%sT10:00:03Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"milestone": "provider.firstDelta", "observedBy": "provider"}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "stream.tick", "ts": "%sT10:00:03Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"chars": 40, "chunks": 1, "elapsedMs": 100}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "stream.tick", "ts": "%sT10:00:04Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"chars": 80, "chunks": 2, "elapsedMs": 200}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "llm.call", "ts": "%sT10:00:04Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"surface": "chat", "durationMs": 900, "ttftMs": 300, "model": "claude-opus-5"}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "surface.outputEnqueued", "ts": "%sT10:00:05Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"milestone": "surface.outputEnqueued", "observedBy": "surface"}}\n' "$W3D" "$i" >> "$W3DAY"
  printf '{"kind": "turn.terminal", "ts": "%sT10:00:05Z", "turnId": "w3-ok-%d", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 5000}}\n' "$W3D" "$i" >> "$W3DAY"
done
# A later provider/tool round rebuilds context for the same turn. Multiplicity
# is valid; the earliest context.ready still owns initial ordering.
printf '{"kind": "context.ready", "ts": "%sT10:00:02.500Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"schema": "turn.lifecycle.v1", "milestone": "context.ready", "observedBy": "tool-loop-rebuild"}}\n' "$W3D" >> "$W3DAY"
# ── VIOLATION 1: a terminal turn with NO `context.ready` ────────────────────
printf '{"kind": "turn.accepted", "ts": "%sT11:00:00Z", "turnId": "w3-noready", "surface": "chat", "payload": {"milestone": "turn.accepted"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "surface.outputEnqueued", "ts": "%sT11:00:01Z", "turnId": "w3-noready", "surface": "chat", "payload": {"milestone": "surface.outputEnqueued"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "turn.terminal", "ts": "%sT11:00:02Z", "turnId": "w3-noready", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 2000}}\n' "$W3D" >> "$W3DAY"
# ── VIOLATION 2: `provider.requestStarted` BEFORE `context.ready` ───────────
printf '{"kind": "turn.accepted", "ts": "%sT11:10:00Z", "turnId": "w3-inverted", "surface": "chat", "payload": {"milestone": "turn.accepted"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "provider.requestStarted", "ts": "%sT11:10:01Z", "turnId": "w3-inverted", "surface": "chat", "payload": {"milestone": "provider.requestStarted"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "context.ready", "ts": "%sT11:10:02Z", "turnId": "w3-inverted", "surface": "chat", "payload": {"milestone": "context.ready"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "surface.outputEnqueued", "ts": "%sT11:10:03Z", "turnId": "w3-inverted", "surface": "chat", "payload": {"milestone": "surface.outputEnqueued"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "turn.terminal", "ts": "%sT11:10:04Z", "turnId": "w3-inverted", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 4000}}\n' "$W3D" >> "$W3DAY"
# ── VIOLATION 3: an ok-terminal turn that never enqueued output ─────────────
printf '{"kind": "turn.accepted", "ts": "%sT11:20:00Z", "turnId": "w3-noenqueue", "surface": "chat", "payload": {"milestone": "turn.accepted"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "context.ready", "ts": "%sT11:20:01Z", "turnId": "w3-noenqueue", "surface": "chat", "payload": {"milestone": "context.ready"}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "turn.terminal", "ts": "%sT11:20:02Z", "turnId": "w3-noenqueue", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 2000}}\n' "$W3D" >> "$W3DAY"
# ── VOCABULARY DRIFT: a kind no declaration knows about ─────────────────────
printf '{"kind": "experimental.newlane", "ts": "%sT11:30:00Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"x": 1}}\n' "$W3D" >> "$W3DAY"
# ── MOTOR: one action that reaches a terminal phase, one that never does ────
printf '{"kind": "motor.state", "ts": "%sT11:40:00Z", "turnId": "motor-closed", "payload": {"schema": "motor.action.read-model.v1", "actionIdentity": "closedaction", "phase": "running", "domain": "mac", "domainState": "x", "verification": "pending", "payloadFree": true, "controlAuthority": false}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "motor.state", "ts": "%sT11:41:00Z", "turnId": "motor-closed", "payload": {"schema": "motor.action.read-model.v1", "actionIdentity": "closedaction", "phase": "succeeded", "domain": "mac", "domainState": "x", "verification": "satisfied", "payloadFree": true, "controlAuthority": false}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "motor.state", "ts": "%sT11:42:00Z", "turnId": "motor-open", "payload": {"schema": "motor.action.read-model.v1", "actionIdentity": "halfopenaction", "phase": "waiting_external", "domain": "mac", "domainState": "y", "verification": "pending", "payloadFree": true, "controlAuthority": false}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "motor.state", "ts": "%sT11:43:00Z", "turnId": "github-ready", "payload": {"schema": "motor.action.read-model.v1", "actionIdentity": "githubready", "phase": "ready", "domain": "github_command", "domainState": "found", "verification": "not_started", "payloadFree": true, "controlAuthority": false}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "motor.state", "ts": "%sT11:44:00Z", "turnId": "github-wait", "payload": {"schema": "motor.action.read-model.v1", "actionIdentity": "githubwait", "phase": "waiting_external", "domain": "github_command", "domainState": "waiting_upstream", "verification": "satisfied", "payloadFree": true, "controlAuthority": false}}\n' "$W3D" >> "$W3DAY"
# ── The remaining dark lanes, one row each ──────────────────────────────────
printf '{"kind": "context.stage", "ts": "%sT11:50:00Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"stage": "contextFlow.attention", "elapsedMs": 12}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "turn.failed", "ts": "%sT11:51:00Z", "turnId": "w3-failed", "surface": "chat", "payload": {"reason": "toolLoopExhausted", "iteration": 3, "dispatchCount": 9}}\n' "$W3D" >> "$W3DAY"
printf '{"kind": "context.attention.late-completion", "ts": "%sT11:52:00Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"abandonedMs": 250}}\n' "$W3D" >> "$W3DAY"
# `memory.commit` fires on the BUS only — the events.jsonl half is deliberately
# missing, which is the two-feed disagreement the reader exists to name.
printf '{"kind": "memory.commit", "ts": "%sT11:53:00Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"recordId": "r1"}}\n' "$W3D" >> "$W3DAY"
# `turn.plan` on the bus carries FEWER payload fields than on events.jsonl.
printf '{"kind": "turn.plan", "ts": "%sT11:54:00Z", "turnId": "w3-ok-1", "surface": "chat", "payload": {"schema": "turn.plan.v1", "runId": "r", "goalType": "answer", "contextMode": "full", "surface": "chat"}}\n' "$W3D" >> "$W3DAY"

# A day file that is PRESENT and cannot be opened. The live reader collapses
# this into "no turns" (TurnInspectorModel.swift:429-432) — that IS the defect.
W3UNREADABLE="$W3/turn_traces/$(day 2).jsonl"
printf '{"kind": "turn.terminal", "ts": "%s", "turnId": "hidden", "payload": {"status": "completed"}}\n' "$(inst 2)" > "$W3UNREADABLE"
chmod 000 "$W3UNREADABLE"

# traces/events.jsonl — the SAME two kinds, the OTHER payload shape, and no
# memory.commit row at all.
{
  printf '{"kind": "turn.plan", "createdAt": "%s", "status": "ok", "payload": {"goalType": "answer", "contextMode": "full", "runId": "r", "surface": "chat", "permissionLevel": "standard", "autonomyDefault": "ask", "fullMacActive": false, "developerMode": false, "remoteSurface": false, "fileAccess": "workspace", "approvalAvailable": true, "remoteIOSAllowed": false, "surfaceTrusted": true, "preloadGroups": [], "preloadCandidateToolCount": 0, "receiptHints": [], "policyDecision": {"actionKind": "turn", "actor": "user", "surface": "chat", "requestedAction": "chat", "requestedCapability": "chat", "dataScope": "local", "sideEffectLevel": "none", "outcome": "allow", "reason": "trusted", "policySource": "trust", "fullMacActive": false, "developerMode": false, "remoteSurface": false, "surfaceTrusted": true}}}\n' "$(inst 1)"
  printf '{"kind": "llm.call", "createdAt": "%s", "payload": {"surface": "chat", "model": "claude-opus-5", "provider": "anthropic", "inputTokens": 10, "outputTokens": 5, "durationMs": 900, "ttftMs": 300}}\n' "$(inst 1)"
  printf '{"kind": "tool.dispatch", "createdAt": "%s", "status": "failed", "title": "mac_view", "payload": {"surface": "chat", "durationMs": 10, "receipt": {"target": "mac_view", "decision": "allow", "outcome": "error", "permanence": "none", "errorClass": "ax"}}}\n' "$(inst 1)"
} > "$W3/traces/events.jsonl"

# activity/events.jsonl — the SECOND events feed. Three single-row kinds, so the
# eviction cliff has something to name BEFORE the trim rather than after.
: > "$W3/activity/events.jsonl"
for i in $(seq 1 40); do
  printf '{"kind": "chat", "createdAt": "%s", "payload": {"i": %d}}\n' "$(inst 1)" "$i" >> "$W3/activity/events.jsonl"
done
for k in approvals provider skill; do
  printf '{"kind": "%s", "createdAt": "%s", "payload": {}}\n' "$k" "$(inst 3)" >> "$W3/activity/events.jsonl"
done

# feeds.logs.uncovered — log text is metadata-only and has a named byte bound;
# general errors are rendered beside scheduler failures so either error lane can
# be seen independently. The oversized sparse fixture proves the bound has a
# real crossing rather than merely being printed as prose.
printf 'small report\n' > "$W3/logs/small.txt"
dd if=/dev/zero of="$W3/logs/oversized.txt" bs=1048576 count=9 2>/dev/null
printf '{"ts": "%s", "code": "diskFull"}\n{"ts": "%s", "code": "diskFull"}\n' \
  "$(inst 1)" "$(inst 1)" > "$W3/logs/errors.jsonl"
printf '{"kind": "failure", "loopId": "separateLoop", "createdAt": "%s", "error": "planted loop failure"}\n' \
  "$(inst 1)" > "$W3/logs/background_loop_failures.jsonl"

# feeds.from_codex — the writer retains 100 audit envelopes. The fixture
# crosses that ceiling and leaves one old, unpaired sidecar: a fresh unpaired
# file may belong to a live Codex process, but a 9-day orphan is residue that
# needs deliberate review rather than automatic replay.
for i in $(seq 1 101); do
  printf '{}\n' > "$W3/from_codex/run-$i.json"
  if [ "$i" -le 100 ]; then
    printf 'last message %s\n' "$i" > "$W3/from_codex/run-$i-last-message.txt"
  fi
done
printf 'interrupted output\n' > "$W3/from_codex/orphan-last-message.txt"
touch -t 202601010101 "$W3/from_codex/orphan-last-message.txt"

# feeds.disabled_shadow_tree — the disabled snapshot looks exactly like the
# live github-command artifact. The report must name it as a SHADOW, never let
# it sort with normal uncovered feeds, and prove no live reader resolved there.
printf '{"state":"live"}\n' > "$W3/github_command/ops.jsonl"
printf '{"state":"retired snapshot"}\n' \
  > "$W3/disabled/retired-github-command/github_command/ops.jsonl"

# builder_audit — one permanent file per builder-tool call, one of them old
# enough to cross the stated age bound.
printf '{"tool": "builder_write"}\n' > "$W3/builder_audit/00000000-0000-0000-0000-000000000001.json"
touch -t 202601010101 "$W3/builder_audit/00000000-0000-0000-0000-000000000001.json"
printf '{"tool": "builder_write"}\n' > "$W3/builder_audit/00000000-0000-0000-0000-000000000002.json"

# slack — errors LIVE while receipts are stale: FAILING, not idle.
: > "$W3/slack/errors.jsonl"
for i in 1 2 3 4 5; do
  printf '{"ts": "%s", "code": "socketClosed", "i": %d}\n' "$(inst 1)" "$i" >> "$W3/slack/errors.jsonl"
done
printf '{"ts": "%s", "ok": true}\n' "$(inst 30)" > "$W3/slack/receipts.jsonl"
# telegram — the NEGATIVE CONTROL for the same rule: errors AND receipts live.
printf '{"ts": "%s", "code": 409}\n' "$(inst 1)" > "$W3/telegram/errors.jsonl"
printf '{"ts": "%s", "ok": true}\n' "$(inst 1)" > "$W3/telegram/receipts.jsonl"
# …and an impossible offset plus an inbox that is not draining.
printf '{"offset": -7}\n' > "$W3/telegram/last_offset.json"
printf '{"update_id": 1}\n' > "$W3/telegram/update_inbox/1.json"
printf '{"schemaVersion":1,"entries":{"1":{"updateId":1,"phase":"pending"}}}\n' > "$W3/telegram/update_inbox/claims_index.json"
touch -t 202601010101 "$W3/telegram/update_inbox/1.json"

# doctor — a STALE verdict that still names a failing check. Self-healing reads
# exactly this file and believes it.
printf '{"generatedAt": "%s", "checks": [{"id": "diskHygiene", "status": "ok"}, {"id": "bridgeReachable", "status": "fail"}]}\n' \
  "$(inst 9)" > "$W3/doctor/latest.json"

# oauth_tokens — a PLANTED token. The assertion is that this string never
# reaches the report; the mutation below widens the allowlist to prove it bites.
W3_TOKEN="ya29-PLANTED-OAUTH-SECRET-do-not-print"
printf '{"access_token": "%s", "refresh_token": "%s-refresh", "expires_at": "2026-12-01T00:00:00Z", "scope": "repo"}\n' \
  "$W3_TOKEN" "$W3_TOKEN" > "$W3/oauth_tokens/github.json"

# mac_control — 5 operations against 1 `mac.*` dispatch row: a 5x divergence
# between two records of the same action.
W3_MAC_OPERATION_AT="$(inst 1)"
printf '{"operations": [{"id": "o1", "state": "failed", "terminalAt": "%s"}, {"id": "o2", "state": "failed", "terminalAt": "%s"}, {"id": "o3", "state": "failed", "terminalAt": "%s"}, {"id": "o4", "state": "failed", "terminalAt": "%s"}, {"id": "o5", "state": "completed", "terminalAt": "%s"}], "schema": "v1"}\n' \
  "$W3_MAC_OPERATION_AT" "$W3_MAC_OPERATION_AT" "$W3_MAC_OPERATION_AT" "$W3_MAC_OPERATION_AT" "$W3_MAC_OPERATION_AT" \
  > "$W3/mac_control/operations.json"

# feeds.macctl_bridge_and_browser_ipc — local discovery is shape-only. These
# values deliberately look secret-like so the report assertions below prove it
# never prints them, while still checking loopback, port, timestamp, and the
# private token-file boundary.
W3_MACCTL_BEARER="macctl-PLANTED-BEARER-do-not-print"
W3_BROWSER_BEARER="browser-PLANTED-BEARER-do-not-print"
printf '{"port": 8770, "token": "%s", "writtenAt": "%s"}\n' \
  "$W3_MACCTL_BEARER" "$(inst 1)" > "$W3/macctl_bridge.json"
printf '{"host": "127.0.0.1", "port": 8766, "url": "http://127.0.0.1:8766", "token": "%s", "writtenAt": "%s"}\n' \
  "$W3_BROWSER_BEARER" "$(inst 1)" > "$W3/browser_ipc.json"
printf '%s' "$W3_BROWSER_BEARER" > "$W3/browser_ipc_token"
chmod 600 "$W3/browser_ipc_token"

# chat — one live session, two ORPHAN session_state directories, a compaction
# artifact bigger than its source, and a cancelled.flag that outlived its turn.
printf '[{"id": "s-live", "source": "chat", "createdAt": "%s", "updatedAt": "%s", "messageCount": 4}]\n' \
  "$(inst 1)" "$(inst 1)" > "$W3/chat/sessions.json"
mkdir -p "$W3/chat/session_state/s-live" "$W3/chat/session_state/s-ghost-1" \
         "$W3/chat/session_state/s-ghost-2" "$W3/chat/sessions/s-live"
printf 'digest\n' > "$W3/chat/session_state/s-live/digest.txt"
printf 'digest\n' > "$W3/chat/session_state/s-ghost-1/digest.txt"
printf 'digest\n' > "$W3/chat/session_state/s-ghost-2/digest.txt"
printf '{"tokens": 10}\n' > "$W3/chat/session_state/s-live/provider_usage.json"
printf 'short\n' > "$W3/chat/sessions/s-live/messages.jsonl"
printf 'this compact artifact is deliberately LARGER than the live transcript beside it\n' \
  > "$W3/chat/sessions/s-live/messages.compact.20260819-185056.06d75ae4.jsonl"
printf '1\n' > "$W3/chat/sessions/s-live/cancelled.flag"
touch -t 202601010101 "$W3/chat/sessions/s-live/cancelled.flag"

W3REPORT="$TMP/w3report.md"
"$TOOL_BIN" --data-root "$W3" --days 7 --no-bridge-config --no-machine-state \
  --out "$W3REPORT" > /dev/null 2>"$TMP/w3.err"
W3RC=$?
check "wave-3 fixture root: run exits 0 (rc=$W3RC)" "$([ $W3RC -eq 0 ] && echo 0 || echo 1)"
[ $W3RC -eq 0 ] || sed -n '1,20p' "$TMP/w3.err"

# Slice the three regions so a match can never come from somewhere else.
awk '/^## \(i\) REACH WALK/{f=1} /^<a id="sec-i1"/{f=0} f' "$W3REPORT" > "$TMP/w3_i.md"
awk '/^## \(i\.1\) TURN-TRACE VOCABULARY/{f=1} /^<a id="sec-i2"/{f=0} f' "$W3REPORT" > "$TMP/w3_i1.md"
awk '/^## \(i\.2\) WAVE-3 FEEDS/{f=1} /^<a id="sec-j"/{f=0} f' "$W3REPORT" > "$TMP/w3_i2.md"
awk '/^## \(j\) LEADS/{f=1} /^## BOOM/{f=0} f' "$W3REPORT" > "$TMP/w3_leads.md"
[ -s "$TMP/w3_i.md" ] && [ -s "$TMP/w3_i1.md" ] && [ -s "$TMP/w3_i2.md" ] && [ -s "$TMP/w3_leads.md" ]
check "the reach, wave-3, and leads sections all render with content" $?
grep -q '<a id="sec-i1"></a>' "$W3REPORT" && grep -q '<a id="sec-i2"></a>' "$W3REPORT"
check "both new section anchors resolve" $?

# ── (i.1) KIND REACHABILITY — a zero-row kind is a ROW, not an absence ──────
grep -qF '| `thinking.delta` | 0 | 0 | — | **INERT' "$TMP/w3_i1.md"
check "a declared kind with ZERO rows is printed as an INERT row, not omitted" $?
grep -qF '| `turn.reaction` | 0 | 0 | — | **INERT' "$TMP/w3_i1.md"
check "the second zero-row declared kind (turn.reaction) is named too" $?
# NEGATIVE CONTROL: an INERT row must never be labelled live.
W3_ROW="$(grep -F '| `thinking.delta` |' "$TMP/w3_i1.md")"
grep -q '| live |' <<< "$W3_ROW"
check "NEGATIVE CONTROL: the INERT kind is NOT labelled live" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF '| `experimental.newlane` | 1 | 1 |' "$TMP/w3_i1.md"
check "a kind with no declaration appears in the table with its real count" $?
W3_ROW="$(grep -F '| `experimental.newlane` |' "$TMP/w3_i1.md")"
grep -qF 'UNDECLARED — vocabulary drift' <<< "$W3_ROW"
check "…and is labelled UNDECLARED (vocabulary drift)" $?
grep -qF '| `context.ready` | 6 | 6 |' "$TMP/w3_i1.md"
check "NEGATIVE CONTROL: context.ready reports all initial and rebuild rows without calling multiplicity a violation" $?
grep -qF 'cheap-scan cross-check: **0 disagreement(s)**' "$TMP/w3_i1.md"
check "the byte scanner is cross-checked against the JSON parser (0 disagreements)" $?
grep -qF 'declared turn-trace kind(s) are INERT' "$TMP/w3_leads.md"
check "INERT kinds raise a ranked LEAD" $?
grep -qF 'are emitted and DECLARED NOWHERE' "$TMP/w3_leads.md"
check "UNDECLARED kinds raise a ranked LEAD" $?

# ── (i.1) PER-DAY READABILITY — unreadable is not empty ────────────────────
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: a mode-000 day file proves nothing to uid 0"
  pass "SKIPPED as root: unreadable-day lead"
else
  grep -qF "| \`$(day 2).jsonl\` | **NO** | unknown — not read |" "$TMP/w3_i1.md"
  check "a present-but-unopenable day file reads 'NO / unknown', never 0 rows" $?
  grep -qF 'day file(s) are present and could not be opened' "$TMP/w3_leads.md"
  check "an unreadable day file raises a ranked LEAD" $?
fi
grep -qF "| \`$W3D.jsonl\` | yes | 50 | 0 |" "$TMP/w3_i1.md"
check "NEGATIVE CONTROL: the readable day file reports opened=yes and its 50 rows" $?

# ── (i.1) LIFECYCLE PAIRING ────────────────────────────────────────────────
grep -qF '| every terminal turn carries ≥1 `context.ready` | 6 | 1 | **1 violation(s)** |' "$TMP/w3_i1.md"
check "the terminal turn with no context.ready is 1 violation out of 6 while a valid rebuild is accepted" $?
grep -qF '| `context.ready` precedes `provider.requestStarted` | 4 | 1 | **1 violation(s)** |' "$TMP/w3_i1.md"
check "the inverted ready/requestStarted pair is 1 violation out of 4 checked" $?
grep -qF '| every accepted ok-terminal turn carries ≥1 `surface.outputEnqueued` | 6 | 1 | **1 violation(s)** |' "$TMP/w3_i1.md"
check "the accepted ok-terminal turn with no enqueue milestone is 1 violation out of 6" $?
# NEGATIVE CONTROL: the healthy turns are NOT counted as violations. A checker
# that flagged every turn would satisfy all three assertions above.
grep -qF '| `turn.accepted` → `context.ready` elapsed is non-negative | 5 | 0 | ok |' "$TMP/w3_i1.md"
check "NEGATIVE CONTROL: the ordering check with no violation reads 'ok', 0 of 5" $?
grep -qF 'terminal turn(s) carry no `context.ready`' "$TMP/w3_leads.md"
check "the missing-context.ready violation raises a ranked LEAD" $?
grep -qF 'precedes `context.ready` on 1 turn(s)' "$TMP/w3_leads.md"
check "the inverted assembly/provider boundary raises its own ranked LEAD" $?
grep -qF 'have no `surface.outputEnqueued`' "$TMP/w3_leads.md"
check "the missing enqueue milestone raises its own ranked LEAD" $?

# ── (i.1) stream.tick BUDGET + the other dark lanes ────────────────────────
grep -qF 'named bounds: **2000 ticks/turn**' "$TMP/w3_i1.md"
check "the stream.tick section states NAMED bounds, not just measurements" $?
grep -qF 'rows in window: **6** = ' "$TMP/w3_i1.md"
check "stream.tick reports its share of the whole feed (its retention-budget cost)" $?
grep -qF 'ticks per turn: p50 2 · p95 2 · max 2 over 3 turn(s)' "$TMP/w3_i1.md"
check "per-turn tick counts are measured against that ceiling" $?
grep -qF '| `motor.state` half-open actions | 1 of 4 never reached a terminal phase |' "$TMP/w3_i1.md"
check "the half-open Mac motor action is named while intentional GitHub waits are excluded" $?
grep -qF '| `motor.state` intentional GitHub waits | **2** `github_command` action(s)' "$TMP/w3_i1.md"
check "ready and waiting_external GitHub watcher states are reported as intentional, not abandoned" $?
grep -qF 'motor action(s) never reached a terminal phase' "$TMP/w3_leads.md"
check "the half-open motor action raises a ranked LEAD" $?
grep -qF '| `memory.commit` two feeds | turn_traces **1** vs traces/events.jsonl **0** row(s) in window |' "$TMP/w3_i1.md"
check "the two memory.commit feeds are COMPARED, not each reported alone" $?
grep -qF 'The two `memory.commit` feeds disagree' "$TMP/w3_leads.md"
check "a memory.commit lane firing on one feed only raises a LEAD" $?
grep -qF 'The two `turn.plan` payloads are NOT the same shape' "$TMP/w3_i1.md"
check "the turn.plan payload-shape divergence between the two feeds is NAMED" $?
grep -qF '| `turn.plan` policy outcomes | allow=1 |' "$TMP/w3_i1.md"
check "turn.plan policy outcomes are read out of the events feed" $?
grep -qF '| `turn.failed` reasons | 1 row(s): toolLoopExhausted=1 |' "$TMP/w3_i1.md"
check "turn.failed reasons are histogrammed" $?
grep -qF '**1** row(s) in window (the 250 ms attention-abandon latch' "$TMP/w3_i1.md"
check "the attention late-completion receipt is counted" $?
grep -qF '| `context.stage` names | 1 row(s): contextFlow.attention=1 |' "$TMP/w3_i1.md"
check "context.stage names are histogrammed" $?

# ── (i.2) THE UNCOVERED ACTIVE FEEDS ───────────────────────────────────────
grep -qF 'session_state directories: **3**' "$TMP/w3_i2.md"
check "session_state directories are counted at all (nothing read this feed before)" $?
grep -qF 'digest.txt 3 · provider_usage.json 1' "$TMP/w3_i2.md"
check "the two per-session artifact families (digest / provider_usage) are counted apart" $?
grep -qF 'orphans (id in neither `chat/sessions.json` nor the archive tail): **2**' "$TMP/w3_i2.md"
check "orphan session_state directories are counted (2 ghosts; the live one is not)" $?
grep -qF 'sessions whose compact artifacts are NOT smaller than the live transcript: **1**' "$TMP/w3_i2.md"
check "a compaction artifact bigger than its source is named" $?
grep -qF 'compaction artifacts no smaller than the live transcript' "$TMP/w3_leads.md"
check "the non-shrinking compaction raises a ranked LEAD" $?
grep -qF '**1** cleanup residue older than 1d; turn acceptance clears the session flag before execution' "$TMP/w3_i2.md"
check "an old cancelled.flag is reported as cleanup residue, not a live cancellation hazard" $?
grep -qF 'have outlived their turn' "$TMP/w3_leads.md"
check "old cancellation residue does not raise a false live-turn LEAD" "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'rows: **43 / 5000** line cap' "$TMP/w3_i2.md"
check "activity/events.jsonl is measured against its line cap" $?
grep -qF 'trim trigger' "$TMP/w3_i2.md"
check "…and against the BYTE trigger that actually gates the cap" $?
grep -qF 'kinds that the FIRST eviction would remove entirely (≤2 rows): **3**' "$TMP/w3_i2.md"
check "the rare kinds an eviction would erase are named BEFORE the trim" $?
grep -qF '`approvals`' "$TMP/w3_i2.md"
check "…by name, not as a count" $?
grep -qF 'receipts: **2 / 500** writer-retention bound' "$TMP/w3_i2.md"
check "builder_audit reports its real 500-receipt writer bound" $?
grep -qF '`builder_audit/` has no retention' "$TMP/w3_leads.md"
check "old retained builder receipts do not raise a false no-retention LEAD" "$([ $? -ne 0 ] && echo 0 || echo 1)"
# feeds.logs.uncovered — the general error feed must be counted beside the
# scheduler's failure feed, while opaque .txt logs are bounded by metadata only.
grep -qF 'text files: **2**' "$TMP/w3_i2.md"
check "logs/*.txt files are counted without reading their contents" $?
grep -qF '`logs/errors.jsonl`: **2** row(s), **2** in the 7d window' "$TMP/w3_i2.md"
check "general errors are measured in the report window" $?
grep -qF '`logs/background_loop_failures.jsonl`: **1** failure row(s) in the same window (1 retained total)' "$TMP/w3_i2.md"
check "general errors and scheduler failures render together rather than hiding in separate reports" $?
grep -qF '`logs/oversized.txt`' "$TMP/w3_leads.md" && grep -qF 'text-log bound' "$TMP/w3_leads.md"
check "an oversized text log crosses the named retention bound and raises a LEAD" $?
# feeds.from_codex — count both halves without leaking their content, surface a
# broken writer bound, and distinguish an old orphan from an active sidecar.
grep -qF 'audit envelopes: **101 / 100** writer-retention bound' "$TMP/w3_i2.md"
check "from_codex audit envelopes are measured against the writer's 100-file bound" $?
grep -qF 'last-message sidecars: **101**' "$TMP/w3_i2.md" && grep -qF 'unpaired **1** (1 older than 1d)' "$TMP/w3_i2.md"
check "from_codex sidecars expose the old unpaired residue without reading message text" $?
grep -qF '`from_codex/` holds 101 audit envelopes' "$TMP/w3_leads.md"
check "audit retention overflow raises a ranked LEAD" $?
grep -qF 'last-message sidecar(s) are unpaired for over 1 day' "$TMP/w3_leads.md"
check "only a stale unpaired sidecar raises a review LEAD" $?
# feeds.disabled_shadow_tree — the disabled copy is named outside normal reach
# accounting, with its shadowed live path and a zero-reader subject-pinning guard.
grep -qF '`disabled/` contributes' "$TMP/w3_i.md" && grep -qF 'intentionally excluded here' "$TMP/w3_i.md"
check "disabled feeds are explicitly excluded from the normal NOT COVERED sort" $?
grep -qF '`disabled/` — SHADOW TREE, never a live feed' "$TMP/w3_i2.md"
check "disabled data renders in its own shadow-tree section" $?
grep -qF 'live-path shadows: **1**' "$TMP/w3_i2.md" && grep -qF 'shadows LIVE' "$TMP/w3_i2.md"
check "the disabled github-command snapshot is matched to its live counterpart" $?
grep -qF 'live-reader guard: **0** non-shadow readers resolve under `disabled/`' "$TMP/w3_i2.md"
check "no live instrument reader resolves a disabled path" $?
! grep -qF '`disabled/` contains 1 file(s) that shadow a live operational path' "$TMP/w3_leads.md"
check "an inert disabled tree does not raise a lead while its reader guard is clean" $?
grep -qF '| slack | 5 | 5 | ' "$TMP/w3_i2.md"
check "the slack error feed reports its total rows and its in-window rows" $?
W3_ROW="$(grep -F '| slack |' "$TMP/w3_i2.md")"
grep -qF '**FAILING, NOT IDLE**' <<< "$W3_ROW"
check "errors live + receipts stale reads FAILING, NOT IDLE" $?
grep -qF 'is FAILING, not idle' "$TMP/w3_leads.md"
check "the failing-not-idle surface raises a ranked LEAD" $?
# A fresh connected canonical Slack heartbeat outranks historical errors and a
# stale receipt. Re-run the same frozen fixture with only current state added.
printf '{"connected":true,"updatedAt":"%s","lastError":null}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$W3/slack/state.json"
W3_SLACK_CURRENT="$TMP/w3-slack-current.md"
"$TOOL_BIN" --data-root "$W3" --days 7 --out "$W3_SLACK_CURRENT" > /dev/null 2>&1
W3_ROW="$(grep -F '| slack |' "$W3_SLACK_CURRENT")"
grep -qF '**CURRENTLY CONNECTED** (historical errors retained)' <<< "$W3_ROW"
check "fresh connected Slack state prevents historical errors from being called a current failure" $?
! grep -qF '`slack` is FAILING, not idle' "$W3_SLACK_CURRENT"
check "fresh Slack heartbeat suppresses the stale-receipt failure lead" $?
# NEGATIVE CONTROL: telegram has live errors AND live receipts. A rule that
# fired on any error at all would light this row up too.
W3_ROW="$(grep -F '| telegram |' "$TMP/w3_i2.md")"
grep -q 'FAILING' <<< "$W3_ROW"
check "NEGATIVE CONTROL: a surface with LIVE receipts is not called failing" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF '/ 5.0 MB byte cap' <<< "$W3_ROW"
check "Telegram errors report the writer's real 5 MiB byte-rotation policy" $?
grep -qF 'line cap' <<< "$W3_ROW"
check "Telegram errors are not assigned a fictitious line cap" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF 'offset: **-7** — **NEGATIVE, which the API cannot produce**' "$TMP/w3_i2.md"
check "a negative telegram offset is named impossible, not printed as a number" $?
grep -qF 'holds a negative offset' "$TMP/w3_leads.md"
check "the impossible offset raises a ranked LEAD" $?
grep -qF 'is not draining' "$TMP/w3_leads.md"
check "an update_inbox that is not draining raises a ranked LEAD" $?
# The writer intentionally keeps up to 256 terminal claims and their lock
# sidecars. They are history, not pending work.
printf '{"schemaVersion":1,"entries":{"1":{"updateId":1,"phase":"completed"}}}\n' > "$W3/telegram/update_inbox/claims_index.json"
W3_TELEGRAM_RETAINED="$TMP/w3-telegram-retained.md"
"$TOOL_BIN" --data-root "$W3" --days 7 --out "$W3_TELEGRAM_RETAINED" > /dev/null 2>&1
grep -qF 'completed retained **1 / 256**' "$W3_TELEGRAM_RETAINED" && grep -qF '**idle** — terminal claim retention is intentional' "$W3_TELEGRAM_RETAINED"
check "retained completed Telegram claims are distinguished from pending/processing work" $?
! grep -qF '`telegram/update_inbox/` is not draining' "$W3_TELEGRAM_RETAINED"
check "terminal Telegram retention does not raise a false drain failure" $?
grep -qF 'checks: **2** · failing: **1**' "$TMP/w3_i2.md"
check "doctor/latest.json reports its check count and its failing checks" $?
grep -qF 'self-healing is acting on a frozen verdict' "$TMP/w3_leads.md"
check "a stale doctor verdict raises a ranked LEAD naming self-healing" $?
grep -qF "The doctor's own verdict lists 1 failing check(s)" "$TMP/w3_leads.md"
check "a doctor 'fail' status surfaces as its own lead" $?
grep -qF '| `github` | yes | 4 |' "$TMP/w3_i2.md"
check "an oauth token file is reported as SHAPE (parsed, key count)" $?
grep -qF 'operations in the store: **5**' "$TMP/w3_i2.md"
check "the mac-control operation store is counted" $?
grep -qF 'The mac-control operation store and the dispatch trace disagree (5 vs 1)' "$TMP/w3_leads.md"
check "the store-vs-trace divergence raises a ranked LEAD" $?
grep -qF '### Local Mac-control and browser IPC discovery' "$TMP/w3_i2.md"
check "local Mac-control and browser IPC discovery is rendered" $?
grep -qF 'Mac-control bridge descriptor: loopback port **8770**' "$TMP/w3_i2.md"
check "Mac-control bridge discovery reports the bounded local port" $?
grep -qF 'Browser IPC descriptor: loopback `127.0.0.1` port **8766**' "$TMP/w3_i2.md"
check "browser IPC discovery requires and reports its loopback endpoint" $?
grep -qF 'Browser IPC bearer file:' "$TMP/w3_i2.md" && grep -qF 'private mode **yes**' "$TMP/w3_i2.md" && grep -qF 'contents **not read**' "$TMP/w3_i2.md"
check "browser IPC token is metadata-only and private" $?
W3_IPC_DAMAGE="$TMP/w3_ipc_damage"
chmod u+r "$W3UNREADABLE" || exit 1
cp -R "$W3" "$W3_IPC_DAMAGE"
W3_COPY_RC=$?
chmod 000 "$W3UNREADABLE" || exit 1
if [ "$W3_COPY_RC" -ne 0 ]; then
  fail "wave-3 IPC fixture copy failed (rc=$W3_COPY_RC)"
  exit 1
fi
chmod 000 "$W3_IPC_DAMAGE/turn_traces/$(basename "$W3UNREADABLE")" || exit 1
printf '{"host": "0.0.0.0", "port": 8766, "token": "still-not-rendered", "writtenAt": "%s"}\n' "$(inst 1)" \
  > "$W3_IPC_DAMAGE/browser_ipc.json"
"$TOOL_BIN" --data-root "$W3_IPC_DAMAGE" --days 7 --no-bridge-config --no-machine-state \
  --out "$TMP/w3_ipc_damage.md" > /dev/null 2>&1
awk '/^### Local Mac-control and browser IPC discovery/{f=1} /^## \(j\) LEADS/{f=0} f' "$TMP/w3_ipc_damage.md" > "$TMP/w3_ipc_damage_section.md"
grep -qF 'Browser IPC descriptor: **source unreadable**' "$TMP/w3_ipc_damage_section.md"
check "non-loopback browser IPC discovery is unreadable, not a usable endpoint" $?

# ── THE SECRET BOUNDARY ────────────────────────────────────────────────────
# The WHOLE report, not just the section: token material must not reach any line.
grep -q "$W3_TOKEN" "$W3REPORT"
check "SECRET BOUNDARY: no OAuth token material appears anywhere in the report" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qE "$W3_MACCTL_BEARER|$W3_BROWSER_BEARER" "$W3REPORT"
check "SECRET BOUNDARY: no Mac-control or browser IPC bearer appears anywhere in the report" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"
grep -qF '2026-12-01T00:00:00Z' "$TMP/w3_i2.md"
check "NEGATIVE CONTROL: the allowlisted expires_at IS read (so the file was opened)" $?

# ── ABSENT IS NOT ZERO, proved on the MAIN root where none of this exists ──
awk '/^## \(i\.2\) WAVE-3 FEEDS/{f=1} /^<a id="sec-j"/{f=0} f' "$REPORT" > "$TMP/main_i2.md"
N_ABSENT=$(grep -c 'source absent' "$TMP/main_i2.md")
[ "$N_ABSENT" -ge 6 ]
check "on a root without these feeds every wave-3 reader says 'source absent' ($N_ABSENT labels)" $?
grep -qE '(\*\*0\*\* file\(s\)|orphans[^|]*\*\*0\*\*|operations in the store: \*\*0\*\*)' "$TMP/main_i2.md"
check "NEGATIVE CONTROL: an absent wave-3 feed never renders a zero instead" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── 9. MUTATION TESTS — prove the new assertions can fail ────────────────────
# Each copies the tool, breaks exactly one thing, and asserts the matching
# assertion above goes RED. An assertion that cannot fail is not a test.
echo "==> (h) mutation tests"
MUT_EXTRA=""   # extra argv for the mutant run; reset by every caller that sets it
mutate() { # mutate <name> <root> <sed-expr> <grep-check-cmd...>
  local name="$1"; shift
  local mroot="$1"; shift
  local expr="$1"; shift
  local mtool="$TMP/mutant.swift" mreport="$TMP/mutant.md" mbin="$TMP/mutant.bin"
  sed "$expr" "$TOOL" > "$mtool"
  if cmp -s "$mtool" "$TOOL"; then
    fail "MUTATION '$name': sed changed nothing — the mutation itself is stale"
    return
  fi
  rm -f "$mreport"
  if ! swiftc "$mtool" -o "$mbin" > /dev/null 2>"$TMP/mut.err"; then
    fail "MUTATION '$name': mutant failed to compile ($(head -1 "$TMP/mut.err"))"
    return
  fi
  # shellcheck disable=SC2086 — MUT_EXTRA is deliberately word-split argv.
  if ! "$mbin" --data-root "$mroot" --days 7 $MUT_EXTRA --out "$mreport" > /dev/null 2>"$TMP/mut.err"; then
    fail "MUTATION '$name': mutant failed to run ($(head -1 "$TMP/mut.err"))"
    return
  fi
  if "$@" "$mreport" > /dev/null 2>&1; then
    fail "MUTATION '$name': assertion still PASSES on the broken tool — it proves nothing"
  else
    pass "MUTATION '$name': assertion correctly FAILS on the broken tool"
  fi
}

# M1 — render dark stages as a plain 0 instead of "dark".
check_dark() { grep -E '^\| `darkStage`.*dark \| dark \| dark' "$1"; }
mutate "dark stage rendered as 0 ms" "$ROOT" \
  's@dark | dark | dark@0 | 0 | 0@' \
  check_dark

# M2 — drop the twelfth subsystem from the coverage matrix.
check_twelve() { [ "$(grep -cE '^\| SUB-[0-9]{2} \|' "$1")" -eq 12 ]; }
mutate "coverage matrix missing a subsystem" "$ROOT" \
  's@cover("SUB-12"@cover("GONE-12"@g' \
  check_twelve

# M3 — treat every walked feed as covered, so the planted feed disappears.
check_planted() { awk '/^### NOT COVERED/{f=1} /^### Covered/{f=0} f' "$1" | grep -q 'plantedsubsystem'; }
mutate "walker marks everything covered" "$ROOT" \
  's|^        if !f.covered {$|        f.covered = true; f.coveredBy = ["forced"]; if !f.covered {|' \
  check_planted

# M4 — disable snapshot failure, integrity and query-failure guards, so a
# corrupt store falls through to `?? 0` exactly as it used to. The corrupt-store
# assertion must then go RED.
check_no_zero_nodes() { ! grep -q 'nodes: \*\*0\*\*' "$1"; }
mutate "sqlite failures fall through to zero" "$CROOT" \
  's@do { try copySQLiteOnce(src: src, dest: dest) }@do { try? copySQLiteOnce(src: src, dest: dest) }@; s@if let detail = integrityFailure {@if false, let detail = integrityFailure {@; s@let condemnOnQueryFailure = true@let condemnOnQueryFailure = false@' \
  check_no_zero_nodes

# M5 — ISSUE #4: disable the malformed-line threshold guard. An all-garbage
# feed then reads as a thin-but-fine feed instead of UNREADABLE.
check_all_garbage_unreadable() { grep -qE '^\| `[^`]*desk_ops\.jsonl` \| \*\*UNREADABLE\*\* \|' "$1"; }
mutate "malformed-ratio guard disabled" "$MROOT" \
  's@func malformedRatioTooHigh(lines: Int, malformed: Int) -> Bool {@func malformedRatioTooHigh(lines: Int, malformed: Int) -> Bool { return false@' \
  check_all_garbage_unreadable

# M6 — ISSUE #4, the other half: stop COUNTING malformed lines. The Sources
# table then reports a clean feed that is quietly missing rows.
check_malformed_surfaced() { grep -q '| 30, malformed 2 |' "$1"; }
mutate "malformed lines not counted" "$MROOT" \
  's@alformed += 1@alformed += 0@g; s@alformedLines += 1@alformedLines += 0@g' \
  check_malformed_surfaced

# M7 — comment out the SYS matrix row render. The section header survives, so
# this is exactly the failure the 8-row assertion exists to catch: a matrix
# that LOOKS present and measures nothing.
check_sys_eight() {
  [ "$(awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$1" \
       | grep -cE '^\| SYS-0[1-8] \|')" -eq 8 ]
}
mutate "SYS matrix rows not rendered" "$ROOT" \
  's@, sysRows) { r in@, [SysRow]()) { r in@' \
  check_sys_eight

# M8 — ISSUE #1: disable the PER-FEED cell guard, so a partial organ falls back
# to rendering whatever its counters were initialized to. SYS-03's absent ledger
# then reads "**0**" again and the §17 assertion must go RED.
check_partial_absent() {
  awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$1" \
    | grep -E '^\| SYS-03 \|' | grep -q 'ledger rows in window: source absent'
}
mutate "per-feed cell guard disabled" "$ROOT" \
  's@^let sysPerFeedGuard = true$@let sysPerFeedGuard = false@' \
  check_partial_absent

# M9 — ISSUE #2, first half: restore `try? contentsOfDirectory ?? []`, so a
# directory that cannot be listed reads "present, 0 entries" and the organ ranks
# healthy on a feed nobody could read.
check_unlistable_unreadable() {
  awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$1" \
    | grep -E '^\| SYS-01 \|' | grep -q '\*\*UNREADABLE\*\*'
}
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: mode-000 mutation proves nothing to uid 0"
else
  chmod 000 "$TMP/bridge_chmod/claude-bridge/wake-jobs"
  MUT_EXTRA="--bridge-config-root $TMP/bridge_chmod"
  mutate "unlistable directory falls through to empty" "$ROOT" \
    's@^let organDirGuard = true$@let organDirGuard = false@' \
    check_unlistable_unreadable
  MUT_EXTRA=""
  chmod 755 "$TMP/bridge_chmod/claude-bridge/wake-jobs"
fi

# M10 — ISSUE #2, second half: disable the unparseable-family threshold. An
# all-garbage executions directory then reads as 2 executions of unknown status
# instead of UNREADABLE.
check_exec_family_unreadable() {
  awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$1" \
    | grep -E '^\| SYS-06 \|' | grep -q '\*\*UNREADABLE\*\*'
}
MUT_EXTRA="--no-bridge-config"
mutate "unparseable-family threshold disabled" "$XROOT" \
  's@^let organUnparseableGuard = true$@let organUnparseableGuard = false@' \
  check_exec_family_unreadable
MUT_EXTRA=""

# M11 — WAVE 2, ISSUE #1: widen the provider credential allowlist to every key.
# The report then prints User's api_key / access_token verbatim, and the
# secret-discipline assertion must go RED. This is the mutation that makes
# `providerSafeKeys` a boundary instead of a comment.
check_no_secret() { ! grep -q "$PLANTED_SECRET" "$1"; }
mutate "provider credential allowlist widened to every key" "$ROOT" \
  's@let providerSafeKeys: Set<String> = \["auth_mode", "default_model"\]@let providerSafeKeys: Set<String> = ["auth_mode", "default_model", "api_key", "access_token"]\nlet providerLeakEverything = true@; s@                defaultModel: providerSafeKeys.contains("default_model") ? obj\["default_model"\] as? String : nil,@                defaultModel: (obj["api_key"] as? String) ?? (obj["access_token"] as? String) ?? (obj["default_model"] as? String),@' \
  check_no_secret

# M12 — WAVE 2, ISSUE #2: disable the per-feed cell guard and watch SYS-12's
# absent `pinned_session_ids.json` render as the 0 its counter was initialized
# to. Wave 1 pinned this for SYS-03; wave 2's partial organs need their own
# proof, because a guard that is only exercised by one organ is one refactor
# away from silently not covering the others.
check_chat_partial_absent() {
  awk '/^## \(h\) System matrix/{f=1} /^<a id="sec-i"/{f=0} f' "$1" \
    | grep -E '^\| SYS-12 \|' | grep -q 'pinned: source absent'
}
mutate "per-feed cell guard disabled (SYS-12 partial organ)" "$ROOT" \
  's@^let sysPerFeedGuard = true$@let sysPerFeedGuard = false@' \
  check_chat_partial_absent

# M13 — WAVE 2, ISSUE #3: put back ONE of the Dictionary walks the whole-report
# determinism check depends on. Every table and lead-example list in section (a)
# is derived from this loop, and Swift seeds Dictionary hashing per process, so
# the byte comparison in §22 must go RED. Without this mutation §22 could be
# passing because the fixture happens to have no ties, which proves nothing.
check_whole_report_stable() {
  # $1 is the mutant's report; re-run the mutant a second time and compare.
  local second="$TMP/mut_whole_2.md"
  rm -f "$second"
  "$TMP/mutant.bin" --data-root "$ROOT" --days 7 --no-bridge-config \
    --no-machine-state --now 2026-08-21T12:00:00Z --out "$second" > /dev/null 2>&1 || return 1
  cmp -s "$1" "$second"
}
# The ordering mutation needs a DETERMINISTIC check: two-runs-must-differ is
# probabilistic (hash order can coincide, and the tiny main fixture has too
# few lanes per table for order to matter at all — that combination made the
# original check toothless). Instead: a root with 10 live lanes, and the
# assertion that the lane table's names render in sorted order — passes
# deterministically on the healthy tool, fails on the unsorted mutant unless
# its per-process hash order is coincidentally sorted (p = 1/10!).
LANE_ORDER_ROOT="$TMP/lane_order_root"
mkdir -p "$LANE_ORDER_ROOT/turn_traces"
LO_F="$LANE_ORDER_ROOT/turn_traces/$(day 1).jsonl"
: > "$LO_F"
for i in 1 2 3; do
  printf '{"kind": "context.summary", "ts": "%s", "turnId": "lo-%d", "surface": "chat", "payload": {"counts": {"zulu": 1, "alpha": 2, "mike": 3, "quebec": 4, "bravo": 5, "yankee": 6, "delta": 7, "sierra": 8, "golf": 9, "kilo": 10}, "totalMs": 20}}\n' \
    "$(inst 1)" "$i" >> "$LO_F"
  printf '{"kind": "turn.terminal", "ts": "%s", "turnId": "lo-%d", "surface": "chat", "payload": {"status": "completed", "turnElapsedMs": 1000}}\n' \
    "$(inst 1)" "$i" >> "$LO_F"
done
check_lane_table_sorted() { # $1 = report: section-(a) lane names must be sorted
  local names="$TMP/lane_order_names.txt"
  awk -F'`' '/<a id="sec-b">/{exit} insec && /^\| `counts\./ {print $2} /<a id="sec-a">/{insec=1}' \
    "$1" > "$names"
  [ "$(wc -l < "$names" | tr -d ' ')" -ge 8 ] || return 1
  LC_ALL=C sort -c "$names" 2>/dev/null
}
# NO MUTATION for lane ordering, deliberately: every render site re-sorts its
# rows independently (liveRows/dormantRows/absentRows/healthyZeroRows all
# carry their own .sorted), so removing any single sort changes nothing
# observable — a mutation there can only be theater. The regression pin is
# the rendered PROPERTY itself: >=8 lane names, in sorted order, on a root
# big enough that hash order could not pass by luck.
rm -f "$TMP/lane_order_healthy.md"
"$TOOL_BIN" --data-root "$LANE_ORDER_ROOT" --days 7 --no-bridge-config \
  --no-machine-state --now 2026-08-21T12:00:00Z --out "$TMP/lane_order_healthy.md" > /dev/null 2>&1
check_lane_table_sorted "$TMP/lane_order_healthy.md"
check "lane table renders >=8 names in deterministic sorted order" $?

# ── WAVE-3 MUTATIONS — prove the new assertions can fail ────────────────────
# Each breaks exactly one wave-3 rule and asserts the matching assertion above
# goes RED. Without these the whole block could be passing on fixture shape
# rather than on the property it claims to pin.
MUT_EXTRA="--no-bridge-config --no-machine-state"

# M14 — the kind table drops zero-row kinds. The section still renders, the
# INERT lanes simply vanish, and "absent from the table" reads as "fine".
check_inert_row() { grep -qF '| `thinking.delta` | 0 | 0 | — | **INERT' "$1"; }
mutate "vocabulary table omits zero-row kinds" "$W3" \
  's@    for k in allRows {@    for k in allRows where (traceKindLookback[k] ?? 0) > 0 { // MUTATED@' \
  check_inert_row

# M15 — restore the OLD per-day behaviour: a day file that cannot be opened is
# skipped silently. This is the live reader's own defect, reintroduced.
if [ "$(id -u)" -eq 0 ]; then
  pass "SKIPPED as root: the mode-000 day-file mutation proves nothing to uid 0"
else
  check_unreadable_day() { grep -qF "| \`$(day 2).jsonl\` | **NO** | unknown — not read |" "$1"; }
  mutate "unreadable day file skipped silently (the old reader behaviour)" "$W3" \
    's@^let traceDayOpenGuard = true$@let traceDayOpenGuard = false@' \
    check_unreadable_day
fi

# M16 — the missing-`context.ready` detector stops detecting. The pairing table
# still renders, with a confident "ok" on a turn that has no boundary stamp.
check_ready_violation() {
  grep -qF '| every terminal turn carries ≥1 `context.ready` | 6 | 1 | **1 violation(s)** |' "$1"
}
mutate "missing-context.ready detector disabled" "$W3" \
  's@    let missingReady = terminalTurns.filter { $0.value.readyRows == 0 }@    let missingReady = terminalTurns.filter { _ in false } // MUTATED@' \
  check_ready_violation

# M17 — SECRET BOUNDARY. Widen the oauth allowlist and read the token out. This
# is what makes `oauthSafeKeys` a boundary instead of a comment.
check_no_oauth_secret() { ! grep -q "$W3_TOKEN" "$1"; }
mutate "oauth allowlist widened to token material" "$W3" \
  's@let oauthSafeKeys: Set<String> = \["expires_at", "scope"\]@let oauthSafeKeys: Set<String> = ["expires_at", "scope", "access_token"]@; s@            let scope: String? = oauthSafeKeys.contains("scope") ? (obj\["scope"\] as? String) : nil@            let scope: String? = (obj["access_token"] as? String) ?? (obj["scope"] as? String)@' \
  check_no_oauth_secret

# M18 — the "failing, not idle" rule stops looking at the receipt feed and
# fires on any error at all. The NEGATIVE CONTROL (telegram, whose receipts are
# live) must then go red — which is what proves that control is not decorative.
check_telegram_not_failing() { ! grep -q 'FAILING' <<< "$(grep -F '| telegram |' "$1")"; }
mutate "failing-not-idle rule ignores the receipt feed" "$W3" \
  's@f.errors.inWindow > 0 && receiptsStale == "receipts stale"@f.errors.rows > 0@' \
  check_telegram_not_failing

MUT_EXTRA=""

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "agent_instrument_test.sh: all assertions passed"
  exit 0
fi
echo "agent_instrument_test.sh: $FAILURES assertion(s) FAILED"
exit 1
