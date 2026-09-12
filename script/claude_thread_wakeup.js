#!/usr/bin/env node
"use strict";
// The agent and the user are addressed by their configured names; nothing in
// this file names a specific person.
const AGENT_NAME = process.env.NATIVE_AGENT_AGENT_NAME || "the agent";
const USER_NAME = process.env.NATIVE_AGENT_USER_NAME || "the user";

// claude_thread_wakeup.js — the her→me wake path.
//
// `codex_message` wakes Codex through its app-server (threads, rollout files,
// turn events). Claude has none of that: her runtime IS a spawned `claude`
// process, so this helper is deliberately MUCH simpler than
// script/codex_thread_wakeup.js — no app-server RPC, no rollout watching, no
// file inference. The return path is direct: the child's stdout is the reply,
// and it goes straight back to the agent over the local bridge POST.
//
// Flow (see docs/build_plans/claude-wakeup-parity.md — that file is the
// contract):
//   stdin payload -> O_EXCL job file (dedup on messageId) -> per-topic session
//   pointer -> `claude -p` (--resume or --session-id) -> honest classification
//   -> bridge POST to the agent -> delivery receipt.
//
// Production invocations detach: the foreground process claims the job and
// hands the (minutes-long) run to a detached child so the Swift caller's
// bounded helper deadline is never the thing that kills Claude's turn. Tests
// (and anyone wanting the full envelope on stdout) set
// NATIVE_AGENT_CLAUDE_WAKE_INLINE=1 to run the whole flow in-process.

const {
  jsonOut, nowISO, redactDiagnosticText, processStartIdentity,
  createProcessStartIdentityReader, safeFilePart: sharedSafeFilePart,
  postWakeCompletion, dirLockOwnerAlive: sharedDirLockOwnerAlive, ensureDir, fsyncDirectorySync: syncDirectory, writeSyncedAndClose,
  copyWakeProducerIdentity, copyWakeCompletionOrigin, claimWakeJob: claimJob, readWakeJSON, missingWakeCompletionOrigin,
  appendSyncedWakeLine, readWakeJSONLines, sleep, readWakeBridgeToken, processTreeOrder,
} = require("./wake_worker_common.js");

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const BRIDGE_DIR = process.env.NATIVE_AGENT_CLAUDE_BRIDGE_DIR ||
  path.join(os.homedir(), ".config", "claude-bridge");
const WAKE_JOBS_DIR = path.join(BRIDGE_DIR, "wake-jobs");
const WAKE_SESSIONS_DIR = path.join(BRIDGE_DIR, "wake-sessions");
const DELIVERIES_PATH = path.join(BRIDGE_DIR, "wake-deliveries.jsonl");
const TOKEN_PATH = process.env.NATIVE_AGENT_CLAUDE_WAKE_TOKEN_PATH ||
  path.join(BRIDGE_DIR, "token");
// The bridge publishes its REAL endpoint (it advances from 8771 on collision)
// in bridge.json; the fixed port is only the last-resort fallback.
const BRIDGE_DESCRIPTOR_PATH = path.join(BRIDGE_DIR, "bridge.json");
const BRIDGE_MESSAGE_PATH = "/claude/message";
const DEFAULT_BRIDGE_ORIGIN = "http://127.0.0.1:8771";
const DEFAULT_BRIDGE_URL = `${DEFAULT_BRIDGE_ORIGIN}${BRIDGE_MESSAGE_PATH}`;
// The ceiling is deliberately generous: it is the "this cannot possibly still
// be real work" backstop, NOT the normal way a job ends. A wedged job is meant
// to be caught in minutes by the stall watchdog below, so the ceiling no longer
// has to be tight enough to bound a hang — and the old tight 900s ceiling was
// SIGTERMing real sessions mid-test-run with the fix already on disk.
const DEFAULT_TIMEOUT_SECONDS = 3600;
const MIN_TIMEOUT_SECONDS = 60;
const MAX_TIMEOUT_SECONDS = 3600;
const KILL_GRACE_MS = 2000;
// Stall watchdog: kill when the child stops being demonstrably alive.
//
// WHY NOT heartbeatAt: startHeartbeat() below beats on the RUNNER's own
// setInterval, unconditionally, with no reference to the child. It proves the
// runner is alive and says nothing about the job — a wedged child heartbeats
// perfectly. A watchdog keyed on it can never fire.
//
// WHY NOT stdout: the child is spawned as `claude -p <prompt>` with no
// --output-format stream-json, so stdout stays at zero bytes for the entire
// run and lands only at completion. A watchdog keyed on it fires on every
// healthy job.
//
// So progress is measured from Claude's canonical session transcript. Every
// model/tool movement is appended there even when the runner is blocked on a
// network or MCP call and burns no measurable CPU. CPU is deliberately NOT a
// liveness signal: two healthy production wakes (EB8CAE49 and 9F7A24F3) were
// killed while their transcripts advanced because their short-lived workers
// fell between `ps` samples.
//
// WHY 600s and not 180s: a legitimately quiet stretch is longer than it looks.
// One long model response, or a nested worker dispatch (gpt-5.5 reviews run
// ~5 min), sits near 0% CPU blocked on a socket read the whole time. 180s has
// NEGATIVE margin against known-good behavior and would reproduce the exact
// failure this watchdog exists to prevent. 600s keeps ~2x margin over the
// worst observed legitimate quiet period while still killing a transcript-
// silent job 6x faster than the ceiling.
const DEFAULT_STALL_SECONDS = 600;
const STALL_SAMPLE_MS = 15_000;
const STDOUT_CAP = 512 * 1024;
const STDERR_CAP = 128 * 1024;
const DEFAULT_TOPIC = "general";
const DEFAULT_HEARTBEAT_MS = 30_000;
// A runner that has neither a live pid nor a heartbeat inside 2x its own wake
// timeout is dead: nothing legitimate takes that long without ticking.
// NOTE: staleness alone NEVER authorizes a takeover any more (see
// resolveExistingJob) — it is only a diagnostic note on a duplicate.
const STALE_TIMEOUT_MULTIPLIER = 2;
// The parent claims the job with its OWN pid, spawns the detached child, and
// only then records runnerPid. A duplicate landing inside that window sees a
// dead parent and no runner — which is indistinguishable from a genuinely
// orphaned claim. Treat a job that young as live.
const DEFAULT_SPAWN_GRACE_MS = 30_000;
// Baseline wait for the per-topic lock. A waiter QUEUES BEHIND a live
// in-flight wake (the agent work order 2026-07-25, Defect 3): the effective wait
// extends to the owner's advertised deadline + margin, and on final failure
// the wake is REJECTED loudly, naming the in-flight job — never silently
// downgraded to a fresh, context-free session.
const DEFAULT_LOCK_WAIT_MS = 120_000;
const LOCK_POLL_MS = 100;
const LOCK_ACQUIRE_GRACE_MS = 2000;
// Extra headroom past the lock owner's advertised deadline: covers its
// SIGTERM->SIGKILL escalation, the bridge POST, and settlement writes.
const QUEUE_BEHIND_MARGIN_MS = 120_000;
// Absolute ceiling on queue-behind, whatever the owner advertises: the max
// claude timeout plus margin. A lock held by a LIVE owner past this is a bug
// in the owner; the waiter rejects-by-id rather than waiting forever.
const QUEUE_BEHIND_ABS_CAP_MS = MAX_TIMEOUT_SECONDS * 1000 + 300_000;
// Advertised lock-hold horizon: claude timeout + kill grace + post/settle.
const LOCK_DEADLINE_MARGIN_MS = 90_000;
// A store read taken immediately after an ambiguous bridge exchange cannot
// distinguish "never landed" from "not landed YET": the ack-on-enqueue append
// can complete milliseconds after the client saw a timeout/5xx (a cancelled
// Swift task still finishes a sync write in flight). Absence may only arm a
// replay once this much time has passed since the LAST bridge attempt — by
// then any append that exchange started has long since landed or never will.
const DEFAULT_ABSENT_SETTLE_GRACE_MS = 120_000;

// Structural ping-pong guard: N wakes on the SAME topic inside the window and
// we stop spawning.
const DEFAULT_RATE_WINDOW_MS = 10 * 60 * 1000;
const DEFAULT_RATE_MAX_JOBS = 3;

// A stalled or timed-out run gets exactly ONE automatic re-arm.
//
// Before this, a wedged Claude turn ended as a failure card and NOTHING
// retried it: the live store carried 13 `stalled_after_600s` and 12 timeouts
// with zero retries, each one waiting on a human to notice and re-send the
// same message by hand.
//
// One is the whole budget on purpose. A second automatic retry of a run that
// already burned its ceiling is a loop, not a recovery; past the budget the
// honest end state is a failure card naming the reason.
const DEFAULT_MAX_AUTO_REARMS = 1;
// How far past its OWN advertised deadline a still-alive runner must be before
// a duplicate may terminate it. The runner's two watchdogs own the normal
// case; this margin exists only for a runner whose watchdogs are themselves
// wedged (an event loop blocked inside a sync syscall), which is the only way
// `deadlineAt + kill grace` can pass with the process still breathing.
const WEDGED_RUNNER_MARGIN_MS = 120_000;
// States in which the runner provably has NOT posted anything: it stamps
// `delivering` on the job file BEFORE the bridge POST (performWake, fence 2).
// This list is the entire safety argument for terminating a wedged runner.
const PRE_DELIVERY_STATES = ["claimed", "dispatching", "queued", "running"];
// Bound on one terminal-undelivered recovery pass. The sweep runs on the tail
// of a real wake, so it must never become the thing that delays the next one.
const DEFAULT_RECOVERY_MAX_PER_PASS = 5;

// The ONLY stderr shapes that prove the pinned session is genuinely gone.
// Anything else (auth blip, transient crash, our own timeout) must leave the
// pointer alone — a conservative miss costs one fresh thread, a false positive
// throws away Claude's whole conversation with the agent.
const SESSION_GONE_MARKERS = [
  "no conversation found",
  "session not found",
  "no session found",
];

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function ensureDirs() {
  ensureDir(BRIDGE_DIR);
  ensureDir(WAKE_JOBS_DIR);
  ensureDir(WAKE_SESSIONS_DIR);
}

/// Lowercase alnum + dash, collapsed. Empty/garbage topics fall back to
/// `general` so a pointer file always has a real name.
function topicSlug(topic) {
  const slug = String(topic == null ? "" : topic)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  return slug || DEFAULT_TOPIC;
}

function safeFilePart(value) {
  return sharedSafeFilePart(value, 120);
}

function tail(text, limit) {
  const clean = redactDiagnosticText(String(text || "")).trim();
  if (clean.length <= limit) return clean;
  return `…${clean.slice(clean.length - limit)}`;
}

function fsyncDirectorySync(dir) {
  try { syncDirectory(dir); } catch {}
}

function writeJSONAtomic(file, obj) {
  const dir = path.dirname(file);
  ensureDir(dir);
  const tmp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    const fd = fs.openSync(tmp, "wx", 0o600);
    writeSyncedAndClose(fd, () => JSON.stringify(obj, null, 2));
    fs.renameSync(tmp, file);
    try { fs.chmodSync(file, 0o600); } catch {}
  } finally {
    try { fs.rmSync(tmp, { force: true }); } catch {}
  }
}

function appendJSONL(file, obj) {
  ensureDir(path.dirname(file));
  appendSyncedWakeLine(file, () => `${JSON.stringify(obj)}\n`, fsyncDirectorySync);
}

function envNumber(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

/// EPERM means the pid exists but belongs to another user — still alive.
/// ESRCH (and a garbage pid) means gone.
function pidAlive(pid) {
  const value = Number(pid);
  if (!Number.isInteger(value) || value <= 0) return false;
  try {
    process.kill(value, 0);
    return true;
  } catch (error) {
    return !error || error.code !== "ESRCH";
  }
}


/// Is a `claude` process ALREADY open on this Mac with this session id on its
/// command line? (2026-09-02 defect: a `conversation_mode=resume` wake whose
/// pointer names a session the user has open INTERACTIVELY spawned a second,
/// unattended `claude --resume <id>` into the same git tree. It clicked around
/// his desktop, committed the live session's working tree out from under it,
/// and then told the agent the live session was gone.) A resumed session that is
/// currently open must never be spawned again, so this runs immediately before
/// every resume attempt. Cheap and synchronous by design: one `ps`, no signals,
/// no /proc walk. Returns the pid, or null when nothing proves a live holder —
/// an unreadable `ps` is NOT evidence of liveness and falls through to the
/// normal spawn, exactly as before.
function realPathOrNull(value) {
  const text = String(value || "").trim();
  if (!text) return null;
  try {
    return fs.realpathSync(text);
  } catch {
    return null;
  }
}

let cachedClaudeCliRealPath;

/// The `claude` CLI this helper would itself spawn, fully resolved — the same
/// override, then PATH, that `runClaude` uses. Null when it cannot be resolved,
/// in which case the remaining signals below still stand on their own.
function claudeCliRealPath() {
  if (cachedClaudeCliRealPath !== undefined) return cachedClaudeCliRealPath;
  let candidate = process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN || null;
  if (!candidate) {
    const which = spawnSync("/usr/bin/env", ["which", "claude"], {
      encoding: "utf8",
      timeout: 2000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (which.status === 0) {
      candidate = String(which.stdout || "").trim().split("\n")[0] || null;
    }
  }
  cachedClaudeCliRealPath = candidate ? realPathOrNull(candidate) : null;
  return cachedClaudeCliRealPath;
}

/// pid -> executable path. On macOS `ps -o comm=` prints the full path of the
/// binary actually running, which is what argv[0] cannot be trusted to say.
/// An unreadable scan yields an empty map; the caller's own `command=` scan is
/// what decides "unavailable".
function processExecutablePaths() {
  const map = new Map();
  const probe = spawnSync("/bin/ps", ["-axo", "pid=,comm="], {
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (probe.status !== 0) return map;
  for (const line of String(probe.stdout || "").split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(.*)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    if (!Number.isInteger(pid)) continue;
    map.set(pid, match[2].trim());
  }
  return map;
}

/// Is this process a `claude` CLI?
///
/// 2026-09-06: presence is established from the EXECUTABLE first. Matching
/// only `path.basename(argv[0]) === "claude"` misses a renamed symlink and any
/// wrapper that keeps its own argv[0], and a miss is not harmless: both scans
/// then return null and the caller spawns an unattended session beside a live
/// interactive one — the no-spawn rule this guard exists to enforce. Three
/// signals, any one of which is enough:
///   1. the executable path — its realpath is the CLI this helper itself
///      resolves, or its basename is `claude`;
///   2. argv[0]'s basename, or argv[0] resolving to that same CLI;
///   3. the resolved CLI named as an argv token (a `node .../cli.js` launch).
/// A match against the whole command line stays OUT: that is what used to let
/// `tail -f /tmp/claude` or a `zsh -c "... && claude ..."` pass as a live
/// Claude and leave a real wake message undelivered.
function isClaudeProcess(command, executablePath) {
  const cliPath = claudeCliRealPath();
  const rawExec = String(executablePath || "").trim();
  const exec = realPathOrNull(rawExec) || rawExec;
  if (exec) {
    if (cliPath && exec === cliPath) return true;
    if (path.basename(exec) === "claude") return true;
  }
  const argv = String(command || "").trim().split(/\s+/);
  const argv0 = argv[0] || "";
  if (argv0) {
    if (path.basename(argv0) === "claude") return true;
    if (cliPath && realPathOrNull(argv0) === cliPath) return true;
  }
  if (cliPath) {
    for (const token of argv.slice(1)) {
      if (!token.startsWith("/")) continue;
      if (token === cliPath || realPathOrNull(token) === cliPath) return true;
    }
  }
  return false;
}

function findLiveProcessPid(matches) {
  const probe = spawnSync("/bin/ps", ["-axo", "pid=,command="], {
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
  });
  // A failed or empty process scan is NOT proof of absence. Report it as
  // such so the caller leaves the message in the inbox instead of spawning
  // the unattended session this guard exists to prevent (Codex review
  // 2026-09-05).
  if (probe.status !== 0 || !String(probe.stdout || "").trim()) return "unavailable";
  const executables = processExecutablePaths();
  for (const line of String(probe.stdout).split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(.*)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    const command = match[2];
    if (!Number.isInteger(pid) || pid === process.pid || pid === process.ppid) continue;
    // This runner family (node .../claude_thread_wakeup.js --run ...) never
    // carries a session id on its argv, but exclude it explicitly so a future
    // argv change cannot make the guard see itself.
    if (command.includes(path.basename(__filename))) continue;
    if (matches(command, executables.get(pid))) return pid;
  }
  return null;
}

function liveClaudeSessionPid(sessionId) {
  const id = String(sessionId || "").trim();
  if (!id) return null;
  // The process itself must be the CLI, not merely mention the session id.
  return findLiveProcessPid((command, executable) =>
    command.includes(id) && isClaudeProcess(command, executable));
}

/// Is an INTERACTIVE Claude open on this Mac at all? (the user, 2026-09-04: a
/// `claude_message` is for the Claude he is talking to. While one is live,
/// the durable inbox plus her session hook deliver it; spawning a headless
/// `claude -p` next to her puts two Claudes in one git tree, which is how the
/// probe call sites got swept into a commit and HEAD stopped compiling.) An
/// interactive session is any `claude` process without `-p`/`--print` on its
/// command line, which covers the terminal CLI and the desktop app's
/// stream-json driver alike. The test harness sets
/// NATIVE_AGENT_CLAUDE_WAKE_IGNORE_INTERACTIVE=1 so a Mac with a live Claude
/// still exercises the spawn path; production never sets it (the app passes
/// the real binary in NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN, so that variable
/// cannot stand in for "this is a test").
function liveInteractiveClaudePid() {
  if (process.env.NATIVE_AGENT_CLAUDE_WAKE_IGNORE_INTERACTIVE === "1") return null;
  return findLiveProcessPid((command, executable) => {
    if (!isClaudeProcess(command, executable)) return false;
    const argv = command.split(/\s+/);
    return !argv.includes("-p") && !argv.includes("--print");
  });
}

const currentProcessStartIdentity = createProcessStartIdentityReader();

function dirLockOwnerAlive(lockDir) {
  return sharedDirLockOwnerAlive(lockDir);
}

function jobPathFor(messageId) {
  return path.join(WAKE_JOBS_DIR, `${safeFilePart(messageId)}.json`);
}

function readJob(jobPath) {
  const parsed = readWakeJSON(jobPath);
  return parsed && typeof parsed === "object" ? parsed : null;
}

/// Read-verify that the job on disk still carries OUR claimId. A takeover
/// writes a FRESH claimId, so a writer whose claimId no longer matches (or
/// whose job file is gone) has lost ownership and must stop touching anything
/// the world can see: the pointer, the bridge, the job file.
function ownsClaim(jobPath, claimId) {
  if (!jobPath || claimId == null || claimId === "") return true;
  const job = readJob(jobPath);
  if (!job) return false;
  return job.claimId === claimId;
}

/// Claim-checked write. Pass `claimId` from every writer that runs while a
/// takeover is conceivable; omit it only for writes by the claimant before it
/// hands off, or for settled-job bookkeeping (replay).
///
/// Recovery may replace only a durably unstarted claim whose recorded owners
/// are dead, under the existing topic lock. Running/unreadable claims are not
/// takeover targets. A failed durable write returns null; callers must not
/// start effects merely because an in-memory merged record was constructed.
function updateJob(jobPath, patch, claimId) {
  const record = readWakeJSON(jobPath);
  if (claimId != null && claimId !== "") {
    if (!record || record.claimId !== claimId) return null;
  }
  const merged = { ...(record || {}), ...patch, updatedAt: nowISO() };
  try { writeJSONAtomic(jobPath, merged); } catch { return null; }
  return merged;
}

/// A writer that discovered it no longer owns the claim. It must not post to
/// the bridge and must not write the topic pointer; the ONLY thing it does is
/// leave an auditable row so the loss is visible rather than silent.
function recordOrphanedClaim({ jobPath, claimId, payload, stage }) {
  const receipt = {
    id: crypto.randomUUID(),
    createdAt: nowISO(),
    kind: "orphaned_claim",
    messageId: (payload && payload.messageId) || null,
    topic: (payload && payload.topic) || DEFAULT_TOPIC,
    topicSlug: topicSlug(payload && payload.topic),
    jobPath,
    claimId: claimId || null,
    stage,
    status: "aborted",
    reason: "claim_lost",
  };
  try { appendJSONL(DELIVERIES_PATH, receipt); } catch {}
  return {
    status: "aborted",
    reason: "claim_lost",
    kind: "orphaned_claim",
    delivery: "claude_thread_wakeup",
    messageId: receipt.messageId,
    jobPath,
    stage,
    receiptId: receipt.id,
    receiptPath: DELIVERIES_PATH,
  };
}

/// Liveness beacon. The job file is the dedup marker AND the recovery handle.
/// A dead runner is observable, but that observation alone never proves that
/// its effects are safe to repeat.
function startHeartbeat(jobPath, claimId) {
  if (!jobPath) return { stop() {}, lost() { return false; } };
  const intervalMs = Math.max(250, envNumber("NATIVE_AGENT_CLAUDE_WAKE_HEARTBEAT_MS", DEFAULT_HEARTBEAT_MS));
  let lost = false;
  // Declared before the first beat: beat() may need to cancel the timer, and
  // the very first beat runs before setInterval returns.
  let timer = null;
  const beat = () => {
    // Claim-gated: a dispossessed runner stops beating rather than resurrecting
    // a job file that now belongs to somebody else.
    const written = updateJob(jobPath, { pid: process.pid, heartbeatAt: nowISO() }, claimId);
    if (written === null) {
      lost = true;
      if (timer) clearInterval(timer);
    }
  };
  beat();
  timer = setInterval(beat, intervalMs);
  if (lost) clearInterval(timer);
  if (timer.unref) timer.unref();
  return { stop() { clearInterval(timer); }, lost() { return lost; } };
}

function staleThresholdMs(job) {
  const override = process.env.NATIVE_AGENT_CLAUDE_WAKE_STALE_MS;
  if (override != null && override !== "") {
    const value = Number(override);
    if (Number.isFinite(value) && value >= 0) return value;
  }
  const timeoutSeconds = Number(job && job.timeoutSeconds);
  const seconds = Number.isFinite(timeoutSeconds) && timeoutSeconds > 0 ? timeoutSeconds : DEFAULT_TIMEOUT_SECONDS;
  return seconds * 1000 * STALE_TIMEOUT_MULTIPLIER;
}

function jobHeartbeatAgeMs(job) {
  const stamp = Date.parse((job && (job.heartbeatAt || job.updatedAt || job.createdAt)) || "");
  if (!Number.isFinite(stamp)) return Infinity;
  return Date.now() - stamp;
}

function renameJobAside(jobPath) {
  const stale = `${jobPath}.stale-${crypto.randomUUID()}`;
  try {
    fs.renameSync(jobPath, stale);
    return stale;
  } catch {
    return null;
  }
}

function sessionPointerPath(slug) {
  return path.join(WAKE_SESSIONS_DIR, `${slug}.txt`);
}

/// Pointer contract (same as the invoke_claude session pointer file):
/// line 1 = session id, line 2 = the cwd it was created in. Resume-by-id is
/// project-scoped, so resuming from a different directory finds nothing.
function readSessionPointer(slug) {
  const file = sessionPointerPath(slug);
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
  const lines = raw.split("\n").map((line) => line.trim());
  if (!lines[0]) return null;
  return { sessionId: lines[0], cwd: lines[1] || null, path: file };
}

function writeSessionPointer(slug, sessionId, cwd) {
  const file = sessionPointerPath(slug);
  ensureDir(WAKE_SESSIONS_DIR);
  const tmp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(tmp, `${sessionId}\n${cwd}\n`, { mode: 0o600 });
    fs.renameSync(tmp, file);
    try { fs.chmodSync(file, 0o600); } catch {}
  } finally {
    try { fs.rmSync(tmp, { force: true }); } catch {}
  }
  return file;
}

/// Rename aside, NEVER delete: a pointer that turns out to be recoverable is
/// still on disk, and a human can read the .stale-<ts> file to see what thread
/// was abandoned.
function renameSessionPointerAside(slug) {
  const file = sessionPointerPath(slug);
  const stale = `${file}.stale-${Math.floor(Date.now() / 1000)}`;
  try {
    fs.renameSync(file, stale);
    return stale;
  } catch {
    return null;
  }
}

function sessionGone(stderrText) {
  const lower = String(stderrText || "").toLowerCase();
  if (SESSION_GONE_MARKERS.some((marker) => lower.includes(marker))) return true;
  return lower.includes("session") && lower.includes("does not exist");
}

/// Stall threshold, per-message overridable like the ceiling. Same test seam:
/// an env override bypasses the production default so the stall-kill path is
/// provable in seconds instead of ten minutes.
function resolveStallSeconds(payload) {
  const envRaw = process.env.NATIVE_AGENT_CLAUDE_WAKE_STALL_SECONDS;
  if (envRaw != null && envRaw !== "") {
    const envValue = Number(envRaw);
    // 0 (or negative) explicitly DISABLES the stall watchdog, leaving only the
    // hard ceiling — the escape hatch for a job that legitimately goes dark.
    if (Number.isFinite(envValue)) return envValue > 0 ? envValue : 0;
  }
  const raw = Number(payload && payload.stallSeconds);
  if (!Number.isFinite(raw)) return DEFAULT_STALL_SECONDS;
  return raw > 0 ? raw : 0;
}

function resolveTimeoutSeconds(payload) {
  // Test seam: an explicit env override bypasses the 60s production floor so
  // the timeout-kill path is provable in under a second.
  const envRaw = process.env.NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS;
  if (envRaw != null && envRaw !== "") {
    const envValue = Number(envRaw);
    if (Number.isFinite(envValue) && envValue > 0) {
      return Math.min(MAX_TIMEOUT_SECONDS, envValue);
    }
  }
  const raw = Number(payload && payload.timeoutSeconds);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_TIMEOUT_SECONDS;
  return Math.min(MAX_TIMEOUT_SECONDS, Math.max(MIN_TIMEOUT_SECONDS, Math.round(raw)));
}

function resolveCwd(payload, pointer) {
  const candidates = [
    payload && payload.cwd,
    pointer && pointer.cwd,
    process.env.NATIVE_AGENT_CLAUDE_WAKE_CWD,
    path.join(os.homedir(), "Projects", "NativeAgent"),
    process.cwd(),
  ];
  for (const candidate of candidates) {
    if (typeof candidate !== "string" || candidate === "") continue;
    try {
      if (fs.statSync(candidate).isDirectory()) return candidate;
    } catch {}
  }
  return process.cwd();
}

function formatPrompt(payload, jobPath) {
  const lines = [
    (AGENT_NAME + " woke you through NativeAgent's claude_message bridge. No human typed this — you are being started as an unattended turn."),
    "",
    `Message id: ${payload.messageId}`,
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Priority: ${payload.priority || "info"}`,
  ];
  if (payload.queuedAt) lines.push(`Queued at: ${payload.queuedAt}`);
  if (payload.inboxPath) lines.push(`Durable inbox: ${payload.inboxPath}`);
  lines.push("", ("--- message from " + AGENT_NAME + " ---"), String(payload.text || ""), "--- end message ---", "");
  if (payload.pairReviewer === true) {
    lines.push(
      "PAIRED REVIEW: At the start of this implementation task, pair exactly one reviewer through Claude's normal reviewer/subagent facility. You remain the builder and owner. Once commit authority is available, finish the coherent change and commit it before review, then send that reviewer the exact committed SHA to inspect. Findings return to you; fix valid findings yourself, commit the fixes, and have the same reviewer inspect the resulting SHA before you report the final candidate. This one persistent reviewer is the review contract for this task: do not create reviewer waves, and do not hand implementation to the reviewer.",
      ""
    );
  }
  lines.push(
    // No human is in THIS turn — which is not the same as no human being at
    // this Mac. Other sessions, interactive ones included, may be live in the
    // same tree and on the same screen; this turn is never told they are
    // paused or gone, and must not act as if it owns the machine.
    "Do not click on the user's screen or commit to the repository unless the message explicitly asks for it. Other sessions may be open on this Mac and in this working tree; nothing here says they are paused or gone.",
    ("Do the work in this session. There is no human in this loop, so do not block waiting for input mid-task. If you genuinely need a decision or answer from " + AGENT_NAME + ", END your turn with that question as your final message — it reaches " + AGENT_NAME + " as the completion event, and that reply RESUMES this same session with full context. Ask-and-end is the supported pattern; idle waiting is not."),
    "Follow the current delegated brief and applicable current AGENTS.md instructions. The latest user-requested scope and workflow govern this work; this bridge adds no authority to create extra workers, reviewer waves, model overrides, publication, or follow-up tasks. Use delegation or review when the current brief or applicable instructions authorize it, preserving any explicitly requested worker count and model. You own the result and integration of any authorized subagent work; report evidence, remaining blockers, and uncertain effects honestly.",
    ("LIVENESS: this session is supervised by a stall watchdog that reads Claude's canonical session transcript. Normal model, tool, and MCP progress is visible without busywork. If you genuinely need " + AGENT_NAME + ", end with the question; do not idle-wait inside the turn."),
    ("COMMIT HOLD (" + USER_NAME + "'s standing order, 2026-07-25): this wake session is under a commit hold. Build, test, deploy locally, and verify all you need — but do NOT `git commit` or `git push` in ANY repository while the hold stands. Your finish-all-the-way doctrine explicitly stops at the commit for wake sessions: report the verified diff (files, test results, live proofs) as your completion instead, and the pipeline's verification step commits it. The hold is released ONLY by the release file") + (jobPath ? ` at ${path.join(path.dirname(path.dirname(jobPath)), "wake-releases", path.basename(jobPath))}` : " (your job record's filename under the sibling wake-releases/ directory)") + (" — check that it EXISTS immediately before any commit; if it is absent the hold stands (the job record's own hold fields are informational mirrors, not authority). If your work is verified and you believe it should ship, END your turn saying exactly that — release is " + USER_NAME + "'s, " + AGENT_NAME + "'s, or the interactive Claude's call, never this session's."),
    ("Your FINAL message is what crosses back to " + AGENT_NAME + " as the completion receipt — always end with a real answer, including when the task failed or needed no changes. A completed session with an empty reply is a failure, not evidence.")
  );
  return lines.join("\n");
}

/// Every pid in `rootPid`'s tree, root first. Used to kill the whole tree, not
/// just the direct child: `claude` spawns descendants that INHERIT its stdout
/// pipe, and a surviving descendant holds that pipe open so node's `close`
/// never fires — the runner then hangs forever on a child it already killed.
/// That is the "hung to SIGTERM" shape this watchdog exists to end.
function processTreePids(rootPid) {
  const tree = walkProcessTree(rootPid);
  return tree ? tree.order : [];
}

function walkProcessTree(rootPid) {
  if (!Number.isFinite(Number(rootPid))) return null;
  const probe = spawnSync("/bin/ps", ["-A", "-o", "pid=,ppid=,time="], {
    encoding: "utf8",
    timeout: 5000,
  });
  if (probe.error || probe.status !== 0 || !probe.stdout) return null;
  const out = probe.stdout;
  const children = new Map();
  const cpu = new Map();
  for (const line of out.split("\n")) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)$/);
    if (!m) continue;
    const pid = Number(m[1]);
    const ppid = Number(m[2]);
    cpu.set(pid, parseCpuTimeMs(m[3]));
    if (!children.has(ppid)) children.set(ppid, []);
    children.get(ppid).push(pid);
  }
  if (!cpu.has(Number(rootPid))) return null;
  const order = processTreeOrder(rootPid, children);
  let total = 0;
  const perPid = new Map();
  for (const pid of order) {
    const ms = cpu.get(pid) || 0;
    total += ms;
    perPid.set(pid, ms);
  }
  return { cpuMs: total, order, perPid };
}

/// The actual wake. Runs in the detached child in production, or in-process
/// when NATIVE_AGENT_CLAUDE_WAKE_INLINE=1.
///
/// The topic lock admits one wake at a time. Wait through the owner's advertised
/// deadline, then reject with its identity if busy; never start a fresh session
/// as a fallback for the locked conversation.
async function runWakeJob(payload, jobPath, claimId) {
  const envelope = await runWakeJobInner(payload, jobPath, claimId);
  // Drain stranded completions on the TAIL of the wake, not the head: the
  // recovery POST shares postBridgeMessage's generous reply ceiling, and
  // nothing may sit in front of Claude's actual answer. This is the "next
  // bridge contact" the recovery contract names — the detached runner (or an
  // inline test) is the only place with the time to make it.
  try {
    const recovery = await sweepTerminalUndelivered();
    if (recovery.eligible > 0 && envelope && typeof envelope === "object") {
      envelope.recovery = recovery;
    }
  } catch (error) {
    if (envelope && typeof envelope === "object") {
      envelope.recovery = { status: "failed", reason: "recovery_sweep_error",
        error: redactDiagnosticText(String((error && error.message) || error)) };
    }
  }
  return envelope;
}

async function runWakeJobInner(payload, jobPath, claimId) {
  ensureDirs();
  const slug = topicSlug(payload.topic);
  const original = readJob(jobPath);
  if (!original || original.claimId !== claimId) return recordOrphanedClaim({ jobPath, claimId, payload, stage: "runner_start" });
  if (!["claimed", "dispatching", "queued"].includes(original.state)) {
    return { status: "skipped", reason: "execution_already_admitted", messageId: payload.messageId, jobPath };
  }
  if (!updateJob(jobPath, { state: "queued", pid: process.pid, runnerPid: process.pid }, claimId)) {
    return recordOrphanedClaim({ jobPath, claimId, payload, stage: "queue_admission" });
  }
  const heartbeat = startHeartbeat(jobPath, claimId);
  const timeoutSeconds = resolveTimeoutSeconds(payload);
  const stallSeconds = resolveStallSeconds(payload);
  // Visible-while-waiting: a reader of the job file can see WHO we are
  // queued behind rather than inferring it from a stuck heartbeat.
  const lockDir = topicLockDir(slug);
  const preOwner = readLockOwnerInfo(lockDir);
  if (preOwner && preOwner.pid) {
    updateJob(jobPath, {
      state: "queued",
      queuedBehindMessageId: preOwner.messageId || null,
      queuedBehindPid: preOwner.pid,
      queuedBehindDeadlineAt: preOwner.deadlineAt || null,
    }, claimId);
  }
  const lock = await acquireTopicLock(slug, resolveLockWaitMs(), {
    messageId: payload.messageId,
    // Advertised hold horizon: the claude run itself + kill escalation +
    // bridge POST + settlement writes.
    holdMs: timeoutSeconds * 1000 + LOCK_DEADLINE_MARGIN_MS,
  });
  try {
    if (!lock.acquired) {
      // await, not bare return: the finally below must not stop the
      // heartbeat/release the lock until the rejection is fully delivered.
      return await rejectWakeTopicBusy(payload, jobPath, slug, claimId, lock);
    }
    return await performWake(payload, jobPath, slug, claimId, timeoutSeconds, stallSeconds);
  } finally {
    lock.release();
    heartbeat.stop();
  }
}

/// Loud rejection — Defect 3's contract. Never a silent fresh session: the
/// job settles as failed naming the in-flight owner, the receipt is durable,
/// and the agent is told over the bridge that the message was NOT worked and
/// remains in the durable inbox for a re-send after the in-flight job
/// settles. deliveryLost can never arm here (there is no completed reply).
async function rejectWakeTopicBusy(payload, jobPath, slug, claimId, lock) {
  const inFlight = (lock && lock.inFlight) || null;
  const reason = lock && lock.reason === "lock_unavailable"
    ? "topic_lock_unavailable"
    : "rejected_topic_busy";
  const outcome = {
    status: "failed",
    reason,
    exitCode: null,
    signal: null,
    durationMs: null,
    reply: "",
    stderrTail: null,
    inFlightMessageId: inFlight ? inFlight.messageId || null : null,
    inFlightPid: inFlight ? inFlight.pid || null : null,
    inFlightDeadlineAt: inFlight ? inFlight.deadlineAt || null : null,
    waitedMs: lock ? lock.waitedMs || 0 : 0,
  };
  const completionText = formatCompletionForAgent(outcome, payload);
  if (!ownsClaim(jobPath, claimId)) {
    return recordOrphanedClaim({ jobPath, claimId, payload, stage: "before_bridge_post" });
  }
  const bridge = await postBridgeMessage(completionText, payload.sessionId || "");
  const receipt = {
    id: crypto.randomUUID(),
    createdAt: nowISO(),
    kind: "delivery",
    claimId: claimId || null,
    messageId: payload.messageId,
    topic: payload.topic || DEFAULT_TOPIC,
    topicSlug: slug,
    priority: payload.priority || "info",
    agentSessionId: payload.sessionId || null,
    jobPath,
    status: outcome.status,
    reason: outcome.reason,
    inFlightMessageId: outcome.inFlightMessageId,
    inFlightPid: outcome.inFlightPid,
    inFlightDeadlineAt: outcome.inFlightDeadlineAt,
    waitedMs: outcome.waitedMs,
    bridge: {
      status: bridge.status,
      reason: bridge.reason || null,
      ...(bridge.reason === "missing_origin_session" ? { deliveryAttempted: false, note: bridge.note } : {}),
      httpStatus: bridge.httpStatus == null ? null : bridge.httpStatus,
      ackMode: bridge.ackMode || null,
      // Reply-free events are enqueued as informational rows and start no
      // decision turn (astra-comb-3 lane3 #1); the receipt says which lane ran.
      noticeDelivery: bridge.noticeDelivery === true,
    },
    deliveryLost: false,
  };
  try { appendJSONL(DELIVERIES_PATH, receipt); } catch {}
  updateJob(jobPath, {
    state: "settled",
    status: outcome.status,
    reason: outcome.reason,
    inFlightMessageId: outcome.inFlightMessageId,
    bridgeStatus: bridge.status,
    bridgeReason: bridge.reason || null,
    receiptId: receipt.id,
    completedAt: nowISO(),
    deliveryLost: false,
    completionText: bridge.reason === "missing_origin_session" ? completionText : null,
  }, claimId);
  const envelope = {
    status: outcome.status,
    reason: outcome.reason,
    delivery: "claude_thread_wakeup",
    messageId: payload.messageId,
    topic: payload.topic || DEFAULT_TOPIC,
    topicSlug: slug,
    inFlightMessageId: outcome.inFlightMessageId,
    inFlightPid: outcome.inFlightPid,
    inFlightDeadlineAt: outcome.inFlightDeadlineAt,
    waitedMs: outcome.waitedMs,
    bridge: receipt.bridge,
    receiptId: receipt.id,
    receiptPath: DELIVERIES_PATH,
    jobPath,
    deliveryLost: false,
    note: "message remains in the durable inbox; re-send after the in-flight job settles",
  };
  if (bridge.status === "dry_run") envelope.wouldSendText = bridge.text;
  return envelope;
}

async function performWake(payload, jobPath, slug, claimId, timeoutSeconds, stallSeconds) {
  const prompt = formatPrompt(payload, jobPath);

  const attempts = [];
  const pointer = readSessionPointer(slug);
  const requireExistingConversation = payload.requireExistingConversation === true;
  // 2026-09-07: a continuation with no pinned wake session is still deliverable
  // when an interactive Claude is open on this Mac: that live session IS the
  // conversation (the previous message on the topic settled delivered_live into
  // it without ever pinning a headless session). Only when nothing is open is
  // the continuation genuinely unavailable.
  const interactiveForContinuation = requireExistingConversation && !pointer ? liveInteractiveClaudePid() : null;
  const liveContinuationPid = interactiveForContinuation && interactiveForContinuation !== "unavailable" ? interactiveForContinuation : null;
  const continuationUnavailable = requireExistingConversation && !pointer && !liveContinuationPid;
  const hadPointerAtStart = pointer !== null;
  let activePointer = pointer;
  let selfHeal = null;

  const attempt = async (attemptPointer) => {
    const isNewSession = !attemptPointer;
    const sessionId = attemptPointer ? attemptPointer.sessionId : crypto.randomUUID();
    const sessionArgs = isNewSession ? ["--session-id", sessionId] : ["--resume", sessionId];
    const cwd = resolveCwd(payload, attemptPointer);
    // LIVE-SESSION GUARD. Before ANY externally visible act (no "running"
    // admission, no spawn): if this resumed session is already open on this
    // Mac, hand the message over by leaving it in the durable inbox that the
    // Swift caller already wrote, and say so honestly. A second `claude
    // --resume` of a session a human is sitting in acts unattended in that
    // session's own working tree — the damage this guard exists to prevent.
    const interactiveProbe = liveInteractiveClaudePid();
    const interactivePid = interactiveProbe === "unavailable" ? null : interactiveProbe;
    const sessionProbe = interactivePid || isNewSession ? null : liveClaudeSessionPid(sessionId);
    const scanUnavailable = interactiveProbe === "unavailable" || sessionProbe === "unavailable";
    const livePid = interactivePid || (sessionProbe === "unavailable" ? null : sessionProbe);
    if (livePid || scanUnavailable) {
      // 2026-09-06: an unscannable process table is NOT evidence of a live
      // session. The no-spawn behaviour is deliberate and unchanged, but the
      // receipt must not claim a live delivery it never observed: the message
      // is in the durable inbox and presence is simply unknown.
      const presenceUnknown = scanUnavailable && !livePid;
      return {
        status: presenceUnknown ? "delivered_inbox" : "delivered_live",
        reason: presenceUnknown
          ? "process_scan_unavailable"
          : interactivePid ? "interactive_claude_live" : "session_open_interactively",
        detail: presenceUnknown
          ? "Could not scan this Mac for an open Claude session; the message is in the durable inbox and no wake was spawned, so whether a live session will read it is unknown"
          : interactivePid
          ? `An interactive Claude is open (pid ${interactivePid}); message left in the inbox for it, no wake spawned`
          : `Session ${sessionId} is open interactively (pid ${livePid}); message left in the inbox for it, no wake spawned`,
        livePid,
        exitCode: null,
        signal: null,
        durationMs: 0,
        timedOut: false,
        stalled: false,
        reply: "",
        stderrTail: "",
        sessionId,
        sessionMode: "resume",
        cwd,
      };
    }
    // Ergonomics (the agent's correction, 2026-07-25): the enqueue->claim->start
    // gap was invisible and caused three deadline mis-filings. startedAt is
    // the RUNNER's clock zero for this attempt; deadlineAt is when the
    // watchdog will SIGTERM it. Judged from these, never from createdAt.
    const startedAt = nowISO();
    const admission = updateJob(jobPath, {
      state: "running",
      startedAt,
      deadlineAt: new Date(Date.parse(startedAt) + timeoutSeconds * 1000).toISOString(),
      // The stall threshold is published too, so an observer can tell a job
      // that is merely long from one that is overdue to be killed.
      stallSeconds: stallSeconds || null,
      progressAt: null,
      progressSource: null,
      progressCpuMs: null,
      progressTranscriptBytes: null,
      progressTranscriptMtimeMs: null,
      attemptSessionId: sessionId,
      attemptSessionMode: isNewSession ? "new" : "resume",
    }, claimId);
    if (!admission) {
      return {
        status: "failed", reason: "execution_admission_unrecorded", exitCode: null,
        durationMs: 0, timedOut: false, stalled: false, reply: "", stderrTail: "",
        sessionId, sessionMode: isNewSession ? "new" : "resume", cwd,
      };
    }
    // progressAt is the CHILD's liveness, deliberately distinct from
    // heartbeatAt (which only proves the runner is alive).
    const onProgress = ({ at, transcriptBytes, transcriptMtimeMs }) => {
      updateJob(jobPath, {
        progressAt: at,
        progressSource: "claude_transcript",
        progressTranscriptBytes: transcriptBytes,
        progressTranscriptMtimeMs: transcriptMtimeMs,
      }, claimId);
    };
    const run = await runClaude({
      prompt, sessionArgs, sessionId, cwd, timeoutSeconds, stallSeconds, onProgress,
    });
    const result = classify(run, timeoutSeconds, stallSeconds);
    return { ...result, sessionId, sessionMode: isNewSession ? "new" : "resume", cwd };
  };

  let outcome = liveContinuationPid ? {
    status: "delivered_live", reason: "interactive_claude_live",
    detail: `An interactive Claude is open (pid ${liveContinuationPid}); continuation left in the inbox for it, no wake spawned`,
    livePid: liveContinuationPid, exitCode: null, signal: null,
    durationMs: 0, timedOut: false, stalled: false, reply: "", stderrTail: "",
    sessionId: null, sessionMode: "live", cwd: null,
  } : continuationUnavailable ? {
    status: "failed", reason: "continuation_unavailable", exitCode: null, signal: null,
    durationMs: 0, timedOut: false, stalled: false, reply: "", stderrTail: "",
    sessionId: null, sessionMode: "resume_unavailable", cwd: null,
  } : await attempt(activePointer);
  if (!continuationUnavailable) attempts.push({
    sessionId: outcome.sessionId,
    sessionMode: outcome.sessionMode,
    status: outcome.status,
    reason: outcome.reason,
    exitCode: outcome.exitCode,
    durationMs: outcome.durationMs,
  });

  // Conservative self-heal: ONLY an explicit session-not-found marker on a
  // RESUMED session renames the pointer aside and retries once with a fresh
  // one. A timeout, an auth failure, or any other nonzero exit leaves the
  // pointer exactly where it is.
  if (
    !requireExistingConversation &&
    activePointer &&
    outcome.status === "failed" &&
    !outcome.timedOut &&
    // A wedged session is not a missing one: never rename a live pointer aside
    // because the watchdog killed it.
    !outcome.stalled &&
    outcome.reason !== `timeout_after_${timeoutSeconds}s` &&
    sessionGone(outcome.stderrTail)
  ) {
    const stalePath = renameSessionPointerAside(slug);
    selfHeal = {
      action: "pointer_renamed_aside",
      slug,
      stalePath,
      previousSessionId: activePointer.sessionId,
      retried: true,
    };
    activePointer = null;
    outcome = await attempt(null);
    attempts.push({
      sessionId: outcome.sessionId,
      sessionMode: outcome.sessionMode,
      status: outcome.status,
      reason: outcome.reason,
      exitCode: outcome.exitCode,
      durationMs: outcome.durationMs,
    });
  }

  // ONE automatic re-arm for a stalled or timed-out run.
  //
  // A stall means the canonical transcript went silent for the entire watchdog
  // window and the child was killed; a timeout means it burned the whole
  // ceiling. Both are "the runner died without producing an answer", and until
  // now the only recovery was a human noticing the failure card and re-sending
  // the same message by hand.
  //
  // The budget is spent DURABLY BEFORE the retry runs. The counter lives on the
  // job file and the write is claim-gated like every other write here, so a
  // runner that dies mid-retry can never come back for a third attempt, and a
  // later reader can tell a first-pass failure from a re-armed one.
  //
  // The retry resumes the SAME pointer. A stall is not evidence that the
  // session is gone — only the explicit session-not-found marker above is — so
  // re-arming must never quietly fork Claude's thread with the agent.
  const rearmLimit = envNumber("NATIVE_AGENT_CLAUDE_WAKE_MAX_REARMS", DEFAULT_MAX_AUTO_REARMS);
  const priorRearms = Number((readJob(jobPath) || {}).autoRearms) || 0;
  let autoRearms = priorRearms;
  if (!continuationUnavailable && rearmLimit > 0 && priorRearms < rearmLimit
      && outcome.status === "failed" && (outcome.stalled === true || outcome.timedOut === true)) {
    const armed = updateJob(jobPath, {
      autoRearms: priorRearms + 1,
      autoRearmAt: nowISO(),
      autoRearmReason: outcome.reason,
    }, claimId);
    // A null write means the claim is gone (or the disk is): never start a
    // second claude run on the strength of an in-memory record.
    if (armed) {
      autoRearms = priorRearms + 1;
      outcome = await attempt(activePointer);
      attempts.push({
        sessionId: outcome.sessionId,
        sessionMode: outcome.sessionMode,
        status: outcome.status,
        reason: outcome.reason,
        exitCode: outcome.exitCode,
        durationMs: outcome.durationMs,
        rearm: autoRearms,
      });
    }
  }

  // An explicit continuation may not silently become a fresh conversation,
  // even when the provider proves that its old session no longer exists.
  if (requireExistingConversation && activePointer && outcome.status === "failed"
      && !outcome.timedOut && !outcome.stalled && sessionGone(outcome.stderrTail)) {
    outcome = { ...outcome, reason: "continuation_unavailable" };
  }

  // A brand-new session is only worth pinning once it actually produced a
  // turn — recording a session id that never came up would poison the topic
  // pointer with an unresumable id.
  // FENCE 1 — before anything externally visible. The claude run is over; if a
  // takeover happened while we were running, this process is a ghost: it must
  // not write the topic pointer and must not post to the agent.
  if (!ownsClaim(jobPath, claimId)) {
    return recordOrphanedClaim({ jobPath, claimId, payload, stage: "before_pointer_write" });
  }

  let pointerPath = null;
  if (outcome.sessionMode === "new" && outcome.status !== "failed") {
    pointerPath = writeSessionPointer(slug, outcome.sessionId, outcome.cwd);
  } else if (outcome.sessionMode === "resume") {
    pointerPath = sessionPointerPath(slug);
  }
  // Pointer-integrity check (the agent's correction): a wake on a topic that HAD
  // a pointer must end with that thread either resumed or explicitly healed
  // aside — a null pointerPath here means the thread was silently dropped,
  // which is Defect 3's damage shape. Loud in the receipt, never swallowed.
  const pointerIntegrity = continuationUnavailable ? "continuation_unavailable" : hadPointerAtStart && !selfHeal && pointerPath === null
    ? "violated_thread_pointer_dropped"
    : "ok";

  const completionText = formatCompletionForAgent(outcome, payload);
  // The run is terminal from here on; only delivery + settlement remain. Say
  // so on the job file BEFORE the POST, so a mid-delivery observer reads the
  // truth ("run ended at X, delivering") instead of a bare "claimed" with a
  // ticking heartbeat — the exact ambiguity behind the withdrawn Defect 2
  // filing.
  updateJob(jobPath, {
    state: "delivering",
    runStatus: outcome.status,
    runReason: outcome.reason,
    runEndedAt: nowISO(),
    detail: outcome.detail || null,
    livePid: outcome.livePid || null,
  }, claimId);
  // FENCE 2 — immediately before the POST. Re-read rather than trusting fence
  // 1: the pointer write above is not instantaneous, and a double-posted
  // completion is the single worst failure this file can produce.
  if (!ownsClaim(jobPath, claimId)) {
    return recordOrphanedClaim({ jobPath, claimId, payload, stage: "before_bridge_post" });
  }
  const bridge = await postBridgeMessage(completionText, payload.sessionId || "");
  // A reply timeout is settled by the orthogonal observer, never by the
  // transport's own opinion: marker present -> delivered. Absent or
  // unreadable both STAY unknown here — an absence read in the same breath
  // as the ambiguous exchange races the append that exchange may have
  // started. Arming waits for settleUnknownDelivery, which requires the
  // absence to persist past the settle grace.
  let sessionStoreCheck = null;
  if (bridge.status === "unknown") {
    sessionStoreCheck = confirmDeliveryViaSessionStore(payload.sessionId, payload.messageId, completionText);
    if (sessionStoreCheck === "present") {
      bridge.status = "delivered";
      bridge.reason = "confirmed_by_session_store";
    }
  }

  const receipt = {
    id: crypto.randomUUID(),
    createdAt: nowISO(),
    kind: "delivery",
    claimId: claimId || null,
    messageId: payload.messageId,
    topic: payload.topic || DEFAULT_TOPIC,
    topicSlug: slug,
    priority: payload.priority || "info",
    origin: payload.origin || null,
    agentSessionId: payload.sessionId || null,
    jobPath,
    status: outcome.status,
    reason: outcome.reason,
    exitCode: outcome.exitCode,
    signal: outcome.signal,
    durationMs: outcome.durationMs,
    timeoutSeconds,
    claudeSessionId: outcome.sessionId,
    sessionMode: outcome.sessionMode,
    // Live-session guard evidence, in the ledger delegation_status reads: a
    // `delivered_live` row must name the pid that already holds the session,
    // or the ledger cannot tell "handed to a live session" from "never ran".
    detail: outcome.detail || null,
    livePid: outcome.livePid || null,
    sessionPointerPath: pointerPath,
    pointerIntegrity,
    selfHeal,
    attempts,
    autoRearms,
    replyChars: outcome.reply ? outcome.reply.length : 0,
    stderrTail: outcome.stderrTail || null,
    bridge: {
      status: bridge.status,
      reason: bridge.reason || null,
      ...(bridge.reason === "missing_origin_session" ? { deliveryAttempted: false, note: bridge.note } : {}),
      httpStatus: bridge.httpStatus == null ? null : bridge.httpStatus,
      ackMode: bridge.ackMode || null,
      // Reply-free events are enqueued as informational rows and start no
      // decision turn (astra-comb-3 lane3 #1); the receipt says which lane ran.
      noticeDelivery: bridge.noticeDelivery === true,
      url: process.env.NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN === "1" ? null : bridgeURL(),
    },
    sessionStoreCheck,
    // Every terminal result matters, including stopped/failed work and its
    // partial evidence. Delivery truth is independent of execution success.
    // Only a PROVEN transport failure counts as lost; unknown must never arm
    // a replay merely because the worker itself failed.
    deliveryLost: bridge.status === "failed",
  };
  try {
    appendJSONL(DELIVERIES_PATH, receipt);
  } catch (error) {
    receipt.receiptWriteError = String((error && error.message) || error);
  }

  // FENCE 3 — settlement. The POST already happened, so a loss here cannot be
  // undone; what it CAN do is stop us stamping "settled" onto a job file that
  // now belongs to a live successor (which would make the successor's own
  // settlement look like a duplicate delivery).
  let settlementWritten = true;
  if (jobPath) {
    const settled = updateJob(jobPath, {
      state: "settled",
      status: outcome.status,
      reason: outcome.reason,
      bridgeStatus: bridge.status,
      bridgeReason: bridge.reason || null,
      receiptId: receipt.id,
      completedAt: nowISO(),
      // Recovery handle: a later arrival of the same messageId can REPLAY this
      // delivery verbatim instead of re-running (or worse, silently dropping)
      // Claude's terminal result, including failure/partial evidence. An
      // UNKNOWN delivery also keeps the text — not for immediate replay,
      // but so the existing later store-settlement can reconcile it.
      deliveryLost: receipt.deliveryLost,
      completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : completionText,
      sessionStoreCheck,
      // Clock zero for the absent-settle grace: absence may only arm a
      // replay once it has persisted past this stamp + the grace.
      lastBridgeAttemptAt: nowISO(),
      agentSessionId: payload.sessionId || null,
    }, claimId);
    settlementWritten = settled !== null;
  }
  if (!settlementWritten) {
    const orphan = recordOrphanedClaim({ jobPath, claimId, payload, stage: "at_settlement" });
    // The POST is already out the door — say so, rather than pretending this
    // run was inert.
    orphan.bridgeStatus = bridge.status;
    orphan.receiptId = receipt.id;
    return orphan;
  }

  const envelope = {
    status: outcome.status,
    reason: outcome.reason,
    delivery: "claude_thread_wakeup",
    messageId: payload.messageId,
    topic: payload.topic || DEFAULT_TOPIC,
    topicSlug: slug,
    sessionId: outcome.sessionId,
    sessionMode: outcome.sessionMode,
    detail: outcome.detail || null,
    livePid: outcome.livePid || null,
    exitCode: outcome.exitCode,
    durationMs: outcome.durationMs,
    timeoutSeconds,
    replyChars: receipt.replyChars,
    stderrTail: outcome.stderrTail || null,
    selfHeal,
    pointerIntegrity,
    autoRearms,
    bridge: receipt.bridge,
    receiptId: receipt.id,
    receiptPath: DELIVERIES_PATH,
    jobPath,
    deliveryLost: receipt.deliveryLost,
    sessionStoreCheck,
  };
  if (bridge.status === "dry_run") envelope.wouldSendText = bridge.text;
  return envelope;
}

function inlineMode() {
  return process.env.NATIVE_AGENT_CLAUDE_WAKE_INLINE === "1";
}

/// The child carries the claimId in its argv: it is the token that proves the
/// job file on disk is still the one this process was spawned to run.
async function spawnDetachedRunner(jobPath, claimId) {
  const child = spawn(process.execPath, [__filename, "--run", jobPath, "--claim", String(claimId || "")], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env },
  });
  await new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  child.unref();
  return child.pid || null;
}

async function main() {
  // Standalone sweep. This is the hook a supervisor (or a human) uses to drain
  // stranded completions without sending a wake — the "on start" half of the
  // recovery contract, next to the per-wake half in runWakeJob.
  if (process.argv.includes("--recover")) {
    try {
      ensureDirs();
    } catch (error) {
      jsonOut({ status: "failed", reason: "bridge_dir_create_failed",
        error: String((error && error.message) || error) });
      return;
    }
    const recovery = await sweepTerminalUndelivered();
    jsonOut({ status: "ok", delivery: "claude_thread_wakeup", mode: "recover", ...recovery });
    return;
  }

  const runIndex = process.argv.indexOf("--run");
  if (runIndex >= 0) {
    const jobPath = process.argv[runIndex + 1];
    if (!jobPath) {
      jsonOut({ status: "failed", reason: "job_path_missing" });
      return;
    }
    let job;
    try {
      job = JSON.parse(fs.readFileSync(jobPath, "utf8"));
    } catch (error) {
      jsonOut({ status: "failed", reason: "job_unreadable", jobPath, error: String((error && error.message) || error) });
      return;
    }
    const claimIndex = process.argv.indexOf("--claim");
    const claimId = claimIndex >= 0 ? process.argv[claimIndex + 1] || null : null;
    // Fence at the door: if the job was taken over between spawn and exec,
    // this child never runs claude at all.
    if (claimId && !ownsClaim(jobPath, claimId)) {
      jsonOut(recordOrphanedClaim({ jobPath, claimId, payload: job.payload || {}, stage: "runner_start" }));
      return;
    }
    jsonOut(await runWakeJob(job.payload || {}, jobPath, claimId));
    return;
  }

  let raw;
  try {
    raw = JSON.parse(readStdin() || "{}");
  } catch (error) {
    jsonOut({ status: "skipped", reason: "invalid_stdin_json", error: String((error && error.message) || error) });
    return;
  }

  let payload = sanitizePayload(raw);
  // Match the producer's 160-character bound without rewriting accepted IDs.
  // Stop counting at the bound; direct-helper oversize input never claims work.
  let messageIdCharacters = 0;
  for (const _ of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(payload.messageId)) {
    if (++messageIdCharacters > 160) {
      jsonOut({ status: "skipped", reason: "message_id_too_long", note: "Message ID exceeds the producer's 160-character bound. No work was admitted; supply a valid explicit ID." });
      return;
    }
  }
  if (!payload.text) {
    jsonOut({ status: "skipped", reason: "missing_text", messageId: payload.messageId });
    return;
  }

  try {
    ensureDirs();
  } catch (error) {
    jsonOut({
      status: "failed",
      reason: "bridge_dir_create_failed",
      error: String((error && error.message) || error),
    });
    return;
  }

  let slug = topicSlug(payload.topic);
  const rateLimit = topicRateLimit(slug, payload.messageId);
  if (rateLimit) {
    jsonOut({
      status: "skipped",
      reason: "rate_limited_topic",
      delivery: "claude_thread_wakeup",
      messageId: payload.messageId,
      topic: payload.topic,
      topicSlug: slug,
      recentJobs: rateLimit.recentJobs,
      windowMs: rateLimit.windowMs,
      maxJobs: rateLimit.maxJobs,
      // Not a loss: the durable inbox append already happened Swift-side.
      note: "message remains in the durable inbox; only the auto-wake was suppressed",
    });
    return;
  }

  const jobPath = jobPathFor(payload.messageId);
  // A FRESH claimId per successful claim (including a takeover's re-claim).
  // Every subsequent write by the winner is gated on it, so a resurrected
  // predecessor can prove — from the job file alone — that it lost.
  let claimId = null;
  const claimRecord = (acceptedPayload = payload) => {
    claimId = crypto.randomUUID();
    return {
      schemaVersion: 2,
      messageId: acceptedPayload.messageId,
      createdAt: nowISO(),
      // Explicit alias of createdAt: the O_EXCL create IS the claim. Kept as
      // its own field so readers never have to know that equivalence —
      // deadlines are judged from startedAt/deadlineAt (stamped when the
      // runner actually begins the claude attempt), never from here.
      claimedAt: nowISO(),
      heartbeatAt: nowISO(),
      state: "claimed",
      claimId,
      pid: process.pid,
      topicSlug: topicSlug(acceptedPayload.topic),
      timeoutSeconds: resolveTimeoutSeconds(acceptedPayload),
      stallSeconds: resolveStallSeconds(acceptedPayload) || null,
      // Commit hold (task #49, the user 2026-07-25): every wake session starts
      // held — build/test/verify and REPORT, but no git commit/push until
      // the user, the agent, or the interactive Claude releases this job. Two
      // same-day incidents of wake sessions pushing through intended pauses
      // (5af594ae race, f9d62ff6 through the user's held verification gate) —
      // both shipped correct content; the hold restores WHO decides.
      // Released via script/wake_hold_release.js (atomic job-record update).
      commitPolicy: "hold",
      holdReleasedAt: null,
      holdReleasedBy: null,
      payload: acceptedPayload,
    };
  };

  let claimed;
  let takeover = null;
  // Claim once. Duplicate recovery performs its exact replacement while
  // holding the topic lock, never in a later unprotected retry iteration.
  do {
    try {
      claimed = claimJob(jobPath, claimRecord());
    } catch (error) {
      jsonOut({
        status: "failed",
        reason: "job_claim_failed",
        jobPath,
        error: String((error && error.message) || error),
      });
      return;
    }
    if (claimed) break;

    const resolution = await resolveExistingJob(jobPath, payload, claimRecord);
    if (resolution.action === "replay") {
      jsonOut(await replayLostDelivery(jobPath, resolution.job));
      return;
    }
    if (resolution.action === "settle_unknown") {
      jsonOut(await settleUnknownDelivery(jobPath, resolution.job));
      return;
    }
    if (resolution.action === "reclaimed") {
      takeover = {
        reason: resolution.reason,
        stalePath: resolution.stalePath || null,
        previousPid: resolution.ownerPid == null ? null : resolution.ownerPid,
        heartbeatAgeMs: resolution.ageMs == null ? null : resolution.ageMs,
        ...(resolution.wedge ? { wedge: resolution.wedge, terminatedPids: resolution.terminatedPids || [] } : {}),
      };
      claimed = true;
      claimId = resolution.claimId;
      payload = resolution.payload;
      slug = topicSlug(payload.topic);
      break;
    }
    jsonOut({
      status: resolution.note === "missing_origin_session" ? "blocked" : "skipped",
      reason: ["execution_outcome_unknown", "missing_origin_session", "legacy_message_id_ambiguous"].includes(resolution.note) ? resolution.note : "duplicate",
      delivery: "claude_thread_wakeup",
      messageId: payload.messageId,
      // Why we deferred: `staleHeartbeat` means a live pid held it past the
      // stale threshold (we refuse to race it); `spawnGrace` means the
      // parent/child handoff window is still open.
      note: resolution.note || null,
      ...(resolution.note === "wedged_runner_rearm_exhausted" ? {
        wedgedRunnerTerminated: true,
        guidance: "The wedged runner was terminated and its automatic re-arm budget was already spent. The job is settled as failed; re-send the message explicitly if the work is still wanted.",
      } : {}),
      ...(resolution.note === "missing_origin_session" ? { bridge: missingCompletionOrigin(null), deliveryLost: false } : {}),
      ...(resolution.note === "execution_outcome_unknown" ? {
        executionOutcome: "unknown",
        guidance: "The original job is preserved. Its effects may already have occurred; inspect its receipt and conversation before explicitly authorizing new work.",
      } : {}),
      ...(resolution.note === "legacy_message_id_ambiguous" ? {
        executionOutcome: "unknown",
        guidance: "A preserved legacy job used a truncated message ID that may represent different accepted work. No execution or delivery was retried. Inspect that job and its originating conversation before explicitly authorizing new work; do not blindly resend.",
      } : {}),
      heartbeatAgeMs: resolution.ageMs == null ? null : resolution.ageMs,
      jobPath,
    });
    return;
  } while (false);
  if (!claimed) {
    jsonOut({
      status: "skipped",
      reason: "duplicate",
      delivery: "claude_thread_wakeup",
      messageId: payload.messageId,
      jobPath,
    });
    return;
  }
  if (takeover) updateJob(jobPath, { takeover }, claimId);

  if (inlineMode()) {
    const envelope = await runWakeJob(payload, jobPath, claimId);
    if (takeover) envelope.takeover = takeover;
    jsonOut(envelope);
    return;
  }

  // Production: hand the long-running turn to a detached child and report the
  // claim immediately. The Swift caller's helper deadline is measured in
  // seconds; Claude's turn is measured in minutes.
  if (!updateJob(jobPath, { state: "dispatching" }, claimId)) {
    jsonOut({ status: "failed", reason: "dispatch_admission_unrecorded", messageId: payload.messageId, jobPath });
    return;
  }
  let pid;
  try {
    pid = await spawnDetachedRunner(jobPath, claimId);
  } catch (error) {
    updateJob(jobPath, { state: "spawn_failed", error: String((error && error.message) || error) }, claimId);
    jsonOut({
      status: "failed",
      reason: "runner_spawn_failed",
      messageId: payload.messageId,
      jobPath,
      error: String((error && error.message) || error),
    });
    return;
  }
  // The child publishes its own PID/phase before attempting work. No parent
  // write after spawn can overwrite a fast child's running or settled record.
  jsonOut({
    status: "sent", delivery: "claude_thread_wakeup", mode: "detached",
    messageId: payload.messageId, topic: payload.topic, topicSlug: slug,
    runnerPid: pid, jobPath, receiptPath: DELIVERIES_PATH,
    ...(takeover ? { takeover } : {}),
  });
}

// Assemble lane owners before any command dispatch; durable state stays in the existing stores.
const {
  readLockOwnerInfo,
  topicLockDir,
  resolveLockWaitMs,
  acquireTopicLock,
  topicRateLimit,
  sanitizePayload
} = require("./wake_queue_admission.js").createClaudeQueueAdmission({
  DEFAULT_LOCK_WAIT_MS,
  DEFAULT_RATE_MAX_JOBS,
  DEFAULT_RATE_WINDOW_MS,
  DEFAULT_TOPIC,
  LOCK_ACQUIRE_GRACE_MS,
  LOCK_DEADLINE_MARGIN_MS,
  LOCK_POLL_MS,
  QUEUE_BEHIND_ABS_CAP_MS,
  QUEUE_BEHIND_MARGIN_MS,
  WAKE_JOBS_DIR,
  WAKE_SESSIONS_DIR,
  copyWakeCompletionOrigin,
  copyWakeProducerIdentity,
  currentProcessStartIdentity,
  dirLockOwnerAlive,
  ensureDir,
  envNumber,
  nowISO,
  readJob,
  sleep
});

const {
  claudeTranscriptPath,
  transcriptSnapshot,
  TranscriptProgress,
  parseCpuTimeMs,
  runClaude,
  classify
} = require("./wake_turn_observation.js").createClaudeTurnObservation({
  KILL_GRACE_MS,
  STALL_SAMPLE_MS,
  STDERR_CAP,
  STDOUT_CAP,
  envNumber,
  processTreePids,
  redactDiagnosticText,
  spawn,
  tail
});

const {
  bridgeURL,
  deliveryMarker,
  confirmDeliveryViaSessionStore,
  formatCompletionForAgent,
  isNoticeOnlyOutcome,
  isNoticeCompletionText,
  missingCompletionOrigin,
  postBridgeMessage
} = require("./wake_reply_delivery.js").createClaudeReplyDelivery({
  AGENT_NAME,
  BRIDGE_DESCRIPTOR_PATH,
  BRIDGE_MESSAGE_PATH,
  DEFAULT_BRIDGE_URL,
  DEFAULT_TOPIC,
  TOKEN_PATH,
  missingWakeCompletionOrigin,
  postWakeCompletion,
  readWakeBridgeToken,
  readWakeJSON,
  readWakeJSONLines,
  topicSlug
});

const {
  replayLostDelivery,
  settleUnknownDelivery,
  terminalUndelivered,
  sweepTerminalUndelivered,
  preDeliveryWedge,
  resolveExistingJob
} = require("./wake_recovery.js").createClaudeRecovery({
  DEFAULT_ABSENT_SETTLE_GRACE_MS,
  DEFAULT_MAX_AUTO_REARMS,
  DEFAULT_RECOVERY_MAX_PER_PASS,
  DEFAULT_SPAWN_GRACE_MS,
  DEFAULT_TOPIC,
  DELIVERIES_PATH,
  KILL_GRACE_MS,
  PRE_DELIVERY_STATES,
  WAKE_JOBS_DIR,
  WEDGED_RUNNER_MARGIN_MS,
  acquireTopicLock,
  appendJSONL,
  bridgeURL,
  claimJob,
  confirmDeliveryViaSessionStore,
  envNumber,
  jobHeartbeatAgeMs,
  missingCompletionOrigin,
  nowISO,
  pidAlive,
  postBridgeMessage,
  processTreePids,
  readJob,
  redactDiagnosticText,
  renameJobAside,
  sleep,
  staleThresholdMs,
  topicSlug,
  updateJob
});

if (require.main === module) {
  main().catch((error) => {
    jsonOut({ status: "failed", reason: "uncaught_error", error: String((error && error.message) || error) });
    process.exit(0);
  });
}

module.exports = {
  bridgeURL,
  preDeliveryWedge,
  sweepTerminalUndelivered,
  terminalUndelivered,
  classify,
  confirmDeliveryViaSessionStore,
  deliveryMarker,
  ownsClaim,
  formatCompletionForAgent,
  isNoticeOnlyOutcome,
  isNoticeCompletionText,
  formatPrompt,
  liveClaudeSessionPid,
  liveInteractiveClaudePid,
  postBridgeMessage,
  redactDiagnosticText,
  resolveTimeoutSeconds,
  resolveStallSeconds,
  claudeTranscriptPath,
  transcriptSnapshot,
  TranscriptProgress,
  runWakeJob,
  sanitizePayload,
  resolveCwd,
  sessionGone,
  topicRateLimit,
  topicSlug,
};
