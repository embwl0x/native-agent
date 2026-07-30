#!/usr/bin/env node
"use strict";

// claude_thread_wakeup.js — the her→me wake path.
//
// `codex_message` wakes Codex through its app-server (threads, rollout files,
// turn events). Claude has none of that: her runtime IS a spawned `claude`
// process, so this helper is deliberately MUCH simpler than
// script/codex_thread_wakeup.js — no app-server RPC, no rollout watching, no
// file inference. The return path is direct: the child's stdout is the reply,
// and it goes straight back to Agent over the local bridge POST.
//
// Flow (see docs/build_plans/claude-wakeup-parity.md — that file is the
// contract):
//   stdin payload -> O_EXCL job file (dedup on messageId) -> per-topic session
//   pointer -> `claude -p` (--resume or --session-id) -> honest classification
//   -> bridge POST to Agent -> delivery receipt.
//
// Production invocations detach: the foreground process claims the job and
// hands the (minutes-long) run to a detached child so the Swift caller's
// bounded helper deadline is never the thing that kills Claude's turn. Tests
// (and anyone wanting the full envelope on stdout) set
// NATIVE_AGENT_CLAUDE_WAKE_INLINE=1 to run the whole flow in-process.

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const https = require("https");
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
// So progress is measured from evidence the child itself cannot fake while
// wedged: CPU time accumulated across its process tree. A blocked/hung process
// burns no CPU; a thinking or tool-running session always does.
//
// WHY 600s and not 180s: a legitimately quiet stretch is longer than it looks.
// One long model response, or a nested worker dispatch (gpt-5.5 reviews run
// ~5 min), sits near 0% CPU blocked on a socket read the whole time. 180s has
// NEGATIVE margin against known-good behavior and would reproduce the exact
// failure this watchdog exists to prevent. 600s keeps ~2x margin over the
// worst observed legitimate quiet period while still killing a wedged job 6x
// faster than the ceiling.
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
// in-flight wake (Agent work order 2026-07-25, Defect 3): the effective wait
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
// (gpt-5.5 review, 2026-07-25: immediate absent-read after unknown re-armed
// the exact false-replay class this file exists to prevent.)
const DEFAULT_ABSENT_SETTLE_GRACE_MS = 120_000;

// Structural ping-pong guard: N wakes on the SAME topic inside the window and
// we stop spawning.
const DEFAULT_RATE_WINDOW_MS = 10 * 60 * 1000;
const DEFAULT_RATE_MAX_JOBS = 3;

// The ONLY stderr shapes that prove the pinned session is genuinely gone.
// Anything else (auth blip, transient crash, our own timeout) must leave the
// pointer alone — a conservative miss costs one fresh thread, a false positive
// throws away Claude's whole conversation with Agent.
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

function jsonOut(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function nowISO() {
  return new Date().toISOString();
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(dir, 0o700); } catch {}
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
  return String(value || "")
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(0, 120) || crypto.randomUUID();
}

function redactDiagnosticText(value) {
  return String(value || "")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    .replace(/(["']?(?:access_token|refresh_token|api_key|token)["']?\s*[:=]\s*["']?)[^\s,"']+/gi, "$1[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g, "[REDACTED_JWT]")
    .replace(/\b(?:sk|ghp|github_pat|xox[baprs])[-_A-Za-z0-9]{12,}\b/g, "[REDACTED_TOKEN]");
}

function tail(text, limit) {
  const clean = redactDiagnosticText(String(text || "")).trim();
  if (clean.length <= limit) return clean;
  return `…${clean.slice(clean.length - limit)}`;
}

function fsyncDirectorySync(dir) {
  try {
    const fd = fs.openSync(dir, "r");
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  } catch {}
}

function writeJSONAtomic(file, obj) {
  const dir = path.dirname(file);
  ensureDir(dir);
  const tmp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    const fd = fs.openSync(tmp, "wx", 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify(obj, null, 2));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, file);
    try { fs.chmodSync(file, 0o600); } catch {}
  } finally {
    try { fs.rmSync(tmp, { force: true }); } catch {}
  }
}

function appendJSONL(file, obj) {
  ensureDir(path.dirname(file));
  const existed = fs.existsSync(file);
  const fd = fs.openSync(file, "a", 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(obj)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  if (!existed) fsyncDirectorySync(path.dirname(file));
  try { fs.chmodSync(file, 0o600); } catch {}
}

function envNumber(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

/// Deliberately NOT unref'd: this is the lock-wait tick, and it is the only
/// pending work while a contender waits. An unref'd timer lets the event loop
/// drain and the process exits silently with no envelope at all.
function sleep(ms) {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
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
    return Boolean(error && error.code === "EPERM");
  }
}

let cachedCurrentProcessStartIdentity;

/// Start-time + command hash, so a RECYCLED pid is not mistaken for the
/// original owner. Same shape as codex_thread_wakeup.js's lock identity
/// (pattern lifted deliberately — that script is not imported or modified).
function processStartIdentity(pid) {
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart=,command="], {
    encoding: "utf8",
    timeout: 2000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0 || !String(result.stdout || "").trim()) return null;
  return crypto.createHash("sha256").update(String(result.stdout).trim()).digest("hex");
}

function currentProcessStartIdentity() {
  if (cachedCurrentProcessStartIdentity === undefined) {
    cachedCurrentProcessStartIdentity = processStartIdentity(process.pid);
  }
  return cachedCurrentProcessStartIdentity;
}

function dirLockOwnerAlive(lockDir) {
  let ownerAlive = false;
  try {
    const fields = fs.readFileSync(path.join(lockDir, "pid"), "utf8").split("\n");
    const ownerPID = Number(fields[0]);
    if (Number.isInteger(ownerPID) && ownerPID > 0) {
      process.kill(ownerPID, 0);
      ownerAlive = true;
      const recordedIdentity = fields[2] || null;
      if (recordedIdentity) {
        ownerAlive = processStartIdentity(ownerPID) === recordedIdentity;
      }
    }
  } catch (error) {
    ownerAlive = Boolean(error && error.code === "EPERM");
  }
  return ownerAlive;
}

/// Who holds the topic lock, as advertised in its pid file. Lines 4/5 (the
/// owner's wake messageId and its self-declared hold deadline) were added for
/// the queue-behind waiter; older pid files simply yield nulls.
function readLockOwnerInfo(lockDir) {
  try {
    const fields = fs.readFileSync(path.join(lockDir, "pid"), "utf8").split("\n");
    const pid = Number(fields[0]);
    const deadlineMs = Date.parse(fields[4] || "");
    return {
      pid: Number.isInteger(pid) && pid > 0 ? pid : null,
      acquiredAt: fields[1] || null,
      messageId: fields[3] || null,
      deadlineAt: Number.isFinite(deadlineMs) ? fields[4] : null,
      deadlineMs: Number.isFinite(deadlineMs) ? deadlineMs : null,
    };
  } catch {
    return { pid: null, acquiredAt: null, messageId: null, deadlineAt: null, deadlineMs: null };
  }
}

function topicLockDir(slug) {
  return path.join(WAKE_SESSIONS_DIR, `${slug}.lock`);
}

function resolveLockWaitMs() {
  return envNumber("NATIVE_AGENT_CLAUDE_WAKE_LOCK_WAIT_MS", DEFAULT_LOCK_WAIT_MS);
}

/// Serialize pointer-read -> claude run -> pointer-write per topic. Two wakes
/// on the same topic must not both start fresh sessions (last writer wins) or
/// both `--resume` the same session id.
///
/// QUEUE-BEHIND (Agent work order 2026-07-25, Defect 3): a waiter behind a
/// LIVE owner extends its wait to the owner's advertised hold deadline plus
/// margin (capped at QUEUE_BEHIND_ABS_CAP_MS) so back-to-back wakes on one
/// topic thread cleanly instead of colliding. If the lock is STILL held by a
/// live owner at the final deadline, the caller must REJECT the wake, naming
/// the in-flight job — the old fallback (run a fresh uncontinued session)
/// silently delivered Agent's message to a context-free Claude and is gone.
async function acquireTopicLock(slug, waitMs, ownerMeta) {
  const lockDir = topicLockDir(slug);
  const startedMs = Date.now();
  const baseDeadline = startedMs + Math.max(0, waitMs);
  const absCap = startedMs + envNumber("NATIVE_AGENT_CLAUDE_WAKE_QUEUE_BEHIND_CAP_MS", QUEUE_BEHIND_ABS_CAP_MS);
  for (;;) {
    try {
      ensureDir(WAKE_SESSIONS_DIR);
      fs.mkdirSync(lockDir, { mode: 0o700 });
      const holdDeadline = new Date(
        Date.now() + ((ownerMeta && ownerMeta.holdMs) || LOCK_DEADLINE_MARGIN_MS)
      ).toISOString();
      fs.writeFileSync(
        path.join(lockDir, "pid"),
        `${process.pid}\n${nowISO()}\n${currentProcessStartIdentity() || ""}\n${(ownerMeta && ownerMeta.messageId) || ""}\n${holdDeadline}\n`,
        { mode: 0o600 }
      );
      return {
        acquired: true,
        lockDir,
        waitedMs: Date.now() - startedMs,
        release() { try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {} },
      };
    } catch (error) {
      if (!error || error.code !== "EEXIST") {
        // Can't lock at all (permissions, missing dir). This used to degrade
        // to an unlocked run; now the caller fails the wake loudly instead —
        // an unserialized wake can corrupt the topic's session pointer.
        return { acquired: false, lockDir, reason: "lock_unavailable", inFlight: null, waitedMs: Date.now() - startedMs, release() {} };
      }
      let owner = null;
      try {
        const stat = fs.statSync(lockDir);
        // A lock whose owner is between mkdir and the pid write is LIVE, not
        // stale — give that window a short grace before reclaiming.
        const pidMissing = !fs.existsSync(path.join(lockDir, "pid"));
        const withinAcquireGrace = pidMissing && Date.now() - stat.mtimeMs < LOCK_ACQUIRE_GRACE_MS;
        if (!withinAcquireGrace && !dirLockOwnerAlive(lockDir)) {
          fs.rmSync(lockDir, { recursive: true, force: true });
          continue;
        }
        owner = readLockOwnerInfo(lockDir);
      } catch {}
      // Queue behind a live owner: wait out its advertised deadline + margin.
      // No advertised deadline (pre-metadata lock) -> the base wait applies.
      let deadline = baseDeadline;
      if (owner && owner.deadlineMs != null) {
        deadline = Math.max(baseDeadline, owner.deadlineMs + QUEUE_BEHIND_MARGIN_MS);
      }
      deadline = Math.min(deadline, absCap);
      if (Date.now() >= deadline) {
        return {
          acquired: false,
          lockDir,
          reason: "lock_busy",
          inFlight: owner,
          waitedMs: Date.now() - startedMs,
          release() {},
        };
      }
      await sleep(LOCK_POLL_MS);
    }
  }
}

function jobPathFor(messageId) {
  return path.join(WAKE_JOBS_DIR, `${safeFilePart(messageId)}.json`);
}

function readJob(jobPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(jobPath, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

/// Atomic claim. O_EXCL is the whole dedup mechanism: whoever creates the file
/// owns the wake, every later arrival of the same messageId sees EEXIST and
/// returns without spawning anything.
function claimJob(jobPath, record) {
  let fd;
  try {
    fd = fs.openSync(jobPath, "wx", 0o600);
  } catch (error) {
    if (error && error.code === "EEXIST") return false;
    throw error;
  }
  try {
    fs.writeFileSync(fd, JSON.stringify(record, null, 2));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  return true;
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
/// There is a small TOCTOU window between the claimId read and the atomic
/// rename. It is ACCEPTABLE because takeover requires that every recorded
/// owner pid be provably dead (ESRCH), and the one takeover path with no pid
/// to check (an unreadable job) is guarded by a claim-write grace on the
/// file's mtime — so a live writer cannot be dispossessed while it is
/// running. The CAS exists to fence the writer that came back from the dead
/// (Mac sleep, SIGSTOP'd process resumed, pid reuse), and for that a
/// read-verify immediately before each externally-visible act is exactly the
/// guarantee we need.
function updateJob(jobPath, patch, claimId) {
  let record = null;
  try {
    record = JSON.parse(fs.readFileSync(jobPath, "utf8"));
  } catch {}
  if (claimId != null && claimId !== "") {
    if (!record || record.claimId !== claimId) return null;
  }
  const merged = { ...(record || {}), ...patch, updatedAt: nowISO() };
  try { writeJSONAtomic(jobPath, merged); } catch {}
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

/// Liveness beacon. The job file is the dedup marker AND the recovery handle,
/// so a runner that dies must be *detectably* dead: pid + a heartbeat that a
/// live runner keeps refreshing. Without this, a crash/sleep between
/// state:"running" and settle poisons the messageId forever.
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
  const stale = `${jobPath}.stale-${Math.floor(Date.now() / 1000)}`;
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

/// Pointer contract (same as invoke_claude's claude_agent_session.txt):
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
    pointer && pointer.cwd,
    payload && payload.cwd,
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

/// The descriptor ClaudeBridge.swift publishes (writeDiscoveryFiles):
/// {schemaVersion, host, port, url, token, processIdentifier, writtenAt}.
function readBridgeDescriptor() {
  try {
    const parsed = JSON.parse(fs.readFileSync(BRIDGE_DESCRIPTOR_PATH, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

/// Precedence: explicit env override (tests / operator) -> the descriptor the
/// running bridge published -> the legacy fixed port. The bridge advances off
/// 8771 on collision, so hardcoding it meant every reply could be recorded as
/// deliveryLost while a perfectly healthy bridge listened one port over.
function bridgeURL() {
  const override = process.env.NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL;
  if (override) return override;

  const descriptor = readBridgeDescriptor();
  if (descriptor) {
    if (typeof descriptor.url === "string" && descriptor.url.trim() !== "") {
      try {
        return new URL(BRIDGE_MESSAGE_PATH, descriptor.url.trim()).toString();
      } catch {}
    }
    const port = Number(descriptor.port);
    if (Number.isInteger(port) && port > 0 && port < 65536) {
      const host = typeof descriptor.host === "string" && descriptor.host.trim() !== ""
        ? descriptor.host.trim()
        : "127.0.0.1";
      return `http://${host}:${port}${BRIDGE_MESSAGE_PATH}`;
    }
  }
  return DEFAULT_BRIDGE_URL;
}

/// Where the app persists Agent's per-session transcript
/// (data/chat/messages/<sessionId>.jsonl). The helper lives in <repo>/script
/// and the app's data root is the repo checkout, so __dirname-relative is the
/// production path; the env override exists for tests.
function messageStoreDir() {
  return process.env.NATIVE_AGENT_CLAUDE_WAKE_MESSAGE_STORE_DIR ||
    path.join(__dirname, "..", "data", "chat", "messages");
}

/// The one line of the completion text unique to OUR posted receipt. The bare
/// messageId is NOT a usable marker: Agent's transcript already carries it in
/// the original claude_message tool rows.
function deliveryMarker(messageId) {
  return `Originating message id: ${messageId}`;
}

/// Orthogonal delivery observer (Agent, 2026-07-25): a transport must not
/// grade its own delivery. The bridge enqueues the row into her session store
/// durably BEFORE her turn runs, so whether the completion reached her is
/// answered by that store — never by whether the HTTP response came back in
/// time. Returns "present" | "absent" | "unreadable"; "absent" is only
/// meaningful because the store file itself was readable.
function confirmDeliveryViaSessionStore(sessionId, messageId) {
  const id = String(sessionId || "");
  if (!id || !messageId || !/^[A-Za-z0-9._:-]+$/.test(id)) return "unreadable";
  let content;
  try {
    content = fs.readFileSync(path.join(messageStoreDir(), `${id}.jsonl`), "utf8");
  } catch {
    return "unreadable";
  }
  const marker = deliveryMarker(messageId);
  let sawMalformedLine = false;
  for (const line of content.split("\n")) {
    if (!line.trim()) continue;
    let row = null;
    try { row = JSON.parse(line); } catch { sawMalformedLine = true; continue; }
    if (!line.includes(marker)) continue;
    const text = row && typeof row.content === "string" ? row.content : "";
    // The marker must sit inside a real completion row — "[claude-wake]" and
    // the marker in the same row's content — so a stray quotation of the
    // phrase elsewhere in the transcript cannot confirm an undelivered
    // completion. (A row QUOTING our full completion still counts, correctly:
    // she cannot quote what she never received.)
    if (text.includes("[claude-wake]") && text.includes(marker)) return "present";
  }
  // A malformed line means the store was mid-write (or damaged) when we read
  // it — the missing row could BE the truncated one. "Absent" must mean the
  // store was fully readable and the message provably is not there; anything
  // less stays unknown rather than arming a false replay.
  return sawMalformedLine ? "unreadable" : "absent";
}

function formatPrompt(payload, jobPath) {
  const lines = [
    "Agent woke you through NativeAgent's claude_message bridge. No human typed this — you are being started as an unattended turn.",
    "",
    `Message id: ${payload.messageId}`,
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Priority: ${payload.priority || "info"}`,
  ];
  if (payload.queuedAt) lines.push(`Queued at: ${payload.queuedAt}`);
  if (payload.inboxPath) lines.push(`Durable inbox: ${payload.inboxPath}`);
  lines.push("", "--- message from Agent ---", String(payload.text || ""), "--- end message ---", "");
  lines.push(
    "Do the work in this session. There is no human in this loop, so do not block waiting for input mid-task. If you genuinely need a decision or answer from Agent, END your turn with that question as your final message — it reaches her as the completion event, and her reply RESUMES this same session with full context. Ask-and-end is the supported pattern; idle waiting is not.",
    "You are the FULL Claude (User's directive, 2026-07-25): your standard operating doctrine applies here exactly as in User's own sessions — orchestrate, dispatch swarm workers for build-sized tasks, put every implementation diff through gpt-5.5 review, verify before you assert. The sonnet-swarm and gpt-swarm MCPs are available.",
    "COMMIT HOLD (User's standing order, 2026-07-25): this wake session is under a commit hold. Build, test, deploy locally, and verify all you need — but do NOT `git commit` or `git push` in ANY repository while the hold stands. Your finish-all-the-way doctrine explicitly stops at the commit for wake sessions: report the verified diff (files, test results, live proofs) as your completion instead, and the pipeline's verification step commits it. The hold is released ONLY by the release file" + (jobPath ? ` at ${path.join(path.dirname(path.dirname(jobPath)), "wake-releases", path.basename(jobPath))}` : " (your job record's filename under the sibling wake-releases/ directory)") + " — check that it EXISTS immediately before any commit; if it is absent the hold stands (the job record's own hold fields are informational mirrors, not authority). If your work is verified and you believe it should ship, END your turn saying exactly that — release is User's, Agent's, or the interactive Claude's call, never this session's.",
    "Your FINAL message is what crosses back to Agent as the completion receipt — always end with a real answer, including when the task failed or needed no changes. A completed session with an empty reply is a failure, not evidence."
  );
  return lines.join("\n");
}

function formatCompletionForAgent(result, payload) {
  const lines = [
    "[claude-wake] Automated completion event. Do NOT auto-fire another claude_message in response unless you have new work for Claude — OR unless Claude ended with a question or decision request, in which case answering on the SAME topic resumes her session with full context. Question-and-answer on one topic is the supported conversation pattern; reflexive acknowledgment messages are the loop to avoid.",
    "",
    deliveryMarker(payload.messageId),
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Priority: ${payload.priority || "info"}`,
    `Status: ${result.status}`,
  ];
  if (result.durationMs != null) lines.push(`Duration: ${Math.round(result.durationMs / 1000)}s`);
  lines.push("");
  if (result.status === "completed") {
    lines.push("--- Claude's reply ---", result.reply, "--- end reply ---");
  } else if (result.status === "completed_without_reply") {
    lines.push(
      "Claude's session exited cleanly (exit 0) but produced NO output. There is no reply to relay — treat this as a failed wake, not as a silent success."
    );
  } else if (result.reason === "rejected_topic_busy" || result.reason === "topic_lock_unavailable") {
    // Defect 3 contract: a topic collision is REJECTED loudly, by id — never
    // silently downgraded to a fresh context-free session.
    const inFlight = result.inFlightMessageId || "unknown-id";
    lines.push(
      result.reason === "topic_lock_unavailable"
        ? "Claude's wake was REJECTED: the topic lock could not be created at all, and an unserialized wake is never run (it can corrupt the topic's thread)."
        : `Claude's wake was REJECTED: another wake is already in flight on this topic (in-flight message id: ${inFlight}${result.inFlightDeadlineAt ? `, its deadline: ${result.inFlightDeadlineAt}` : ""}). This message was NOT worked and NO session — threaded or fresh — was started for it.`,
      "",
      "It remains in the durable inbox. Re-send it on this topic after the in-flight job settles; it will then resume the topic's thread with full context."
    );
  } else {
    lines.push(`Claude's wake FAILED: ${result.reason}`);
    if (result.stalled) {
      lines.push(
        "The runner was killed by the STALL watchdog, not at its deadline: its process tree burned no CPU for the whole stall window, so the session was wedged rather than slow. SIGTERM then SIGKILL after 2s — its exit is CONFIRMED. Any partial stdout below is everything it produced."
      );
    } else if (result.timedOut) {
      lines.push(
        "The runner was killed at its deadline (SIGTERM, then SIGKILL after 2s) and its exit is CONFIRMED — this verdict is about a provably stopped process, not a guess about a running one. Any partial stdout below is everything it produced."
      );
    }
    if (result.stderrTail) lines.push("", "stderr tail:", result.stderrTail);
    if (result.reply) lines.push("", "partial stdout:", result.reply);
  }
  return lines.join("\n");
}

/// Cumulative CPU milliseconds burned by `rootPid` and every descendant.
///
/// This is the stall watchdog's liveness evidence. It is deliberately a
/// WHOLE-TREE sum: `claude` spends most of a wake blocked while its children
/// (builds, tests, dispatched workers) do the actual burning, so sampling the
/// direct child alone would read a busy session as idle.
///
/// Returns null when the tree cannot be sampled at all. null means "no
/// evidence", which is NOT the same as "no progress" — the caller treats it as
/// non-advancing but never lets it be the sole basis for a kill decision it
/// could not observe.
/// Every pid in `rootPid`'s tree, root first. Used to kill the whole tree, not
/// just the direct child: `claude` spawns descendants that INHERIT its stdout
/// pipe, and a surviving descendant holds that pipe open so node's `close`
/// never fires — the runner then hangs forever on a child it already killed.
/// That is the "hung to SIGTERM" shape this watchdog exists to end.
function processTreePids(rootPid) {
  const tree = walkProcessTree(rootPid);
  return tree ? tree.order : [];
}

function processTreeCpuMs(rootPid) {
  const tree = walkProcessTree(rootPid);
  return tree ? tree.cpuMs : null;
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
  // Iterative walk with a seen-set: `ps` is a snapshot, and a pid recycled into
  // its own ancestry would otherwise spin forever.
  let total = 0;
  const seen = new Set();
  const order = [];
  const stack = [Number(rootPid)];
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    order.push(pid);
    total += cpu.get(pid) || 0;
    for (const kid of children.get(pid) || []) stack.push(kid);
  }
  return { cpuMs: total, order };
}

/// Parse `ps -o time=` ("MM:SS.ss", "HH:MM:SS", "D-HH:MM:SS") to milliseconds.
function parseCpuTimeMs(raw) {
  const text = String(raw || "").trim();
  if (!text) return 0;
  let days = 0;
  let rest = text;
  const dash = text.indexOf("-");
  if (dash > 0) {
    days = Number(text.slice(0, dash)) || 0;
    rest = text.slice(dash + 1);
  }
  const parts = rest.split(":").map((p) => Number(p));
  if (parts.some((p) => !Number.isFinite(p))) return 0;
  let seconds = 0;
  for (const part of parts) seconds = seconds * 60 + part;
  return (days * 86400 + seconds) * 1000;
}

/// Spawn `claude -p` and settle EXACTLY once. Four racers can finish this
/// run — the exit handler, the deadline watchdog, the stall watchdog, and a
/// spawn error — and any double-settle would double-post a completion to Agent.
function runClaude({ prompt, sessionArgs, cwd, timeoutSeconds, stallSeconds, onProgress }) {
  return new Promise((resolve) => {
    const started = Date.now();
    const binOverride = process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN;
    const command = binOverride || "/usr/bin/env";
    const args = binOverride
      ? [...sessionArgs, "-p", prompt]
      : ["claude", ...sessionArgs, "-p", prompt];

    let settled = false;
    let timedOut = false;
    let stalled = false;
    let killTimer = null;
    let timeoutTimer = null;
    let stallTimer = null;
    let stdoutText = "";
    let stderrText = "";

    const settle = (extra) => {
      if (settled) return;
      settled = true;
      if (timeoutTimer) clearTimeout(timeoutTimer);
      if (killTimer) clearTimeout(killTimer);
      if (stallTimer) clearInterval(stallTimer);
      resolve({
        durationMs: Date.now() - started,
        stdout: stdoutText,
        stderr: stderrText,
        timedOut,
        stalled,
        command,
        args: binOverride ? args : args.slice(0, args.length - 1),
        ...extra,
      });
    };

    let child;
    try {
      child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      settle({ exitCode: null, signal: null, spawnError: String((error && error.message) || error) });
      return;
    }

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      if (stdoutText.length < STDOUT_CAP) stdoutText += chunk;
    });
    child.stderr.on("data", (chunk) => {
      if (stderrText.length < STDERR_CAP) stderrText += chunk;
    });

    child.on("error", (error) => {
      settle({ exitCode: null, signal: null, spawnError: String((error && error.message) || error) });
    });
    child.on("close", (code, signal) => {
      settle({ exitCode: code, signal: signal || null });
    });

    // Both watchdogs escalate identically: SIGTERM, then SIGKILL after the
    // grace window, so a child that ignores TERM still provably dies.
    const killChild = () => {
      // Snapshot the tree BEFORE signalling: after SIGTERM the root may be
      // gone and its orphaned descendants un-enumerable, but those are exactly
      // the ones holding the stdout pipe open.
      const treePids = processTreePids(child.pid).filter(
        (pid) => pid !== process.pid && pid !== child.pid
      );
      const signalTree = (signal) => {
        for (const pid of treePids) {
          try { process.kill(pid, signal); } catch {}
        }
        try { child.kill(signal); } catch {}
      };
      signalTree("SIGTERM");
      killTimer = setTimeout(() => { signalTree("SIGKILL"); }, KILL_GRACE_MS);
      if (killTimer.unref) killTimer.unref();
    };

    timeoutTimer = setTimeout(() => {
      timedOut = true;
      killChild();
    }, timeoutSeconds * 1000);
    if (timeoutTimer.unref) timeoutTimer.unref();

    // Stall watchdog. Progress is CPU burned by the child's whole process tree
    // (see processTreeCpuMs). Any advance resets the clock and is reported via
    // onProgress so the job record carries a liveness fact distinct from the
    // runner's own heartbeat.
    const stallMs = Number(stallSeconds) > 0 ? Number(stallSeconds) * 1000 : 0;
    if (stallMs > 0) {
      let lastCpuMs = processTreeCpuMs(child.pid);
      let lastAdvanceAt = Date.now();
      const sampleMs = Math.max(
        250,
        Math.min(envNumber("NATIVE_AGENT_CLAUDE_WAKE_STALL_SAMPLE_MS", STALL_SAMPLE_MS), stallMs)
      );
      stallTimer = setInterval(() => {
        if (settled) return;
        const cpuMs = processTreeCpuMs(child.pid);
        // A sample we could not take is not evidence of death. Skip it and let
        // the next one decide, rather than letting an unreadable `ps` kill a
        // healthy job.
        if (cpuMs == null) return;
        if (lastCpuMs == null || cpuMs > lastCpuMs) {
          lastCpuMs = cpuMs;
          lastAdvanceAt = Date.now();
          if (typeof onProgress === "function") {
            try { onProgress({ cpuMs, at: new Date(lastAdvanceAt).toISOString() }); } catch {}
          }
          return;
        }
        if (Date.now() - lastAdvanceAt >= stallMs) {
          // If the deadline already fired, that is the true cause; a no-CPU
          // child sitting in the 2s kill grace must not be relabelled a stall.
          if (timedOut) { clearInterval(stallTimer); return; }
          stalled = true;
          clearInterval(stallTimer);
          killChild();
        }
      }, sampleMs);
      if (stallTimer.unref) stallTimer.unref();
    }
  });
}

/// Honest classification. Every observable outcome maps to exactly one status;
/// there is no "unknown" bucket and no state where a completed run is reported
/// as anything but what the exit code and stdout actually said.
function classify(run, timeoutSeconds, stallSeconds) {
  const reply = String(run.stdout || "").trim();
  const stderrTail = tail(run.stderr, 2000);
  const base = {
    exitCode: run.exitCode,
    signal: run.signal || null,
    durationMs: run.durationMs,
    reply,
    stderrTail,
    // Threaded through so receipts and completion text can distinguish "the
    // watchdog killed a confirmed-dead runner" from other failures. classify
    // only ever runs after the child's close event — death is proven, not
    // assumed.
    timedOut: run.timedOut === true,
    // Kept separate from timedOut: "ran the full hour" and "went dark for ten
    // minutes" are different diagnoses and must not be reported as one.
    stalled: run.stalled === true,
  };
  if (run.spawnError) {
    return { ...base, status: "failed", reason: "claude_spawn_failed", detail: redactDiagnosticText(run.spawnError) };
  }
  if (run.stalled) {
    return { ...base, status: "failed", reason: `stalled_after_${stallSeconds}s` };
  }
  if (run.timedOut) {
    return { ...base, status: "failed", reason: `timeout_after_${timeoutSeconds}s` };
  }
  if (run.exitCode !== 0) {
    return { ...base, status: "failed", reason: `claude_exit_${run.exitCode == null ? "null" : run.exitCode}` };
  }
  if (reply === "") {
    return { ...base, status: "completed_without_reply", reason: "empty_stdout" };
  }
  return { ...base, status: "completed", reason: null };
}

function postBridgeMessage(text, sessionId) {
  if (process.env.NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN === "1") {
    return Promise.resolve({
      status: "dry_run",
      delivery: "nativeagent_bridge_message",
      sessionId: sessionId || null,
      text,
    });
  }

  let token;
  try {
    token = fs.readFileSync(TOKEN_PATH, "utf8").trim();
  } catch (error) {
    return Promise.resolve({
      status: "failed",
      reason: "bridge_token_missing",
      tokenPath: TOKEN_PATH,
      error: String((error && error.message) || error),
    });
  }
  if (!token) {
    return Promise.resolve({ status: "failed", reason: "bridge_token_empty", tokenPath: TOKEN_PATH });
  }

  let url;
  try {
    url = new URL(bridgeURL());
  } catch (error) {
    return Promise.resolve({
      status: "failed",
      reason: "bridge_url_invalid",
      error: String((error && error.message) || error),
    });
  }

  const body = JSON.stringify({
    text,
    sender: "claude",
    // Ack-on-enqueue (the app-side fix for the 2026-07-25 false-negative
    // class): the bridge answers the moment the row is durably in her session
    // store, never after her turn. A legacy bridge ignores this field and
    // answers at turn completion — both shapes are handled below.
    ackMode: "enqueue",
    ...(sessionId ? { sessionId } : {}),
  });
  const transport = url.protocol === "https:" ? https : http;
  // With ack-on-enqueue the response is disk-bound and arrives in seconds;
  // the generous ceiling only matters against a legacy bridge that still
  // couples the response to turn completion. Either way a timeout is
  // classified "unknown" — never "failed" — so it can never arm a replay.
  // The caller settles "unknown" against the session store, the orthogonal
  // observer.
  const timeoutMs = Number(process.env.NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_TIMEOUT_MS || 600_000);

  return new Promise((resolve) => {
    const req = transport.request({
      host: url.hostname,
      port: url.port || (url.protocol === "https:" ? 443 : 80),
      path: `${url.pathname}${url.search}`,
      method: "POST",
      timeout: timeoutMs,
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch {}
        const httpOK = res.statusCode >= 200 && res.statusCode < 300;
        const replyStatus = parsed && parsed.status ? parsed.status : null;
        // STRICT: only an explicit {status:"ok"} proves delivery. A 2xx with
        // a non-JSON or status-less body (wrong endpoint, proxy page, half a
        // response) must not be recorded as delivered with the completion
        // text discarded — it goes to "unknown" and the store decides.
        const ok = httpOK && replyStatus === "ok";
        // Ownership honesty: only a clean 2xx ok proves delivery. Anything
        // else — enqueue_failed, enqueue_timeout, a 5xx, a mangled body — is
        // AMBIGUOUS, because the new bridge's append seam can throw after the
        // row durably landed. The transport never asserts a loss it cannot
        // prove; the caller settles "unknown" against the session store,
        // which answers definitively either way.
        resolve({
          status: ok ? "delivered" : "unknown",
          reason: ok ? null : (httpOK ? `bridge_reply_${replyStatus || "missing_status"}` : `http_${res.statusCode}`),
          // "enqueued" = the new ack-on-enqueue bridge answered at durable
          // append; "turn_completion" = a legacy bridge answered after the
          // turn (still delivered — just late, and timeout-prone).
          ackMode: ok
            ? (parsed && parsed.ack === "enqueued" ? "enqueued" : "turn_completion")
            : null,
          delivery: "nativeagent_bridge_message",
          httpStatus: res.statusCode,
          sessionId: sessionId || null,
          rawPreview: raw.slice(0, 500),
        });
      });
    });
    req.on("timeout", () => {
      // Resolve BEFORE destroy: destroy fires the "error" handler, whose
      // "failed" resolution must lose the race. A reply timeout is not a
      // delivery failure — it is the absence of an opinion.
      resolve({
        status: "unknown",
        reason: `bridge_reply_timeout_after_${timeoutMs}ms`,
        delivery: "nativeagent_bridge_message",
        sessionId: sessionId || null,
      });
      req.destroy(new Error("bridge_message_timeout"));
    });
    req.on("error", (error) => {
      // Connection-level errors that PROVE the request never reached a
      // server stay "failed" (a store check would also say absent, but the
      // proof is free here). Anything after the request may have been read —
      // a reset mid-response, a dropped socket — is ambiguous: "unknown",
      // settled against the store like every other absence-of-opinion.
      const code = error && error.code;
      const provablyUnsent = code === "ECONNREFUSED" || code === "ENOTFOUND" || code === "EAI_AGAIN";
      resolve({
        status: provablyUnsent ? "failed" : "unknown",
        reason: (error && error.message) || "bridge_message_failed",
        delivery: "nativeagent_bridge_message",
        sessionId: sessionId || null,
      });
    });
    req.write(body);
    req.end();
  });
}

/// The actual wake. Runs in the detached child in production, or in-process
/// when NATIVE_AGENT_CLAUDE_WAKE_INLINE=1.
///
/// ONE in-flight wake per topic (Agent work order + correction, 2026-07-25,
/// Defect 3 — promoted to top by live proof, twice): the topic lock is the
/// serialization point, and a waiter QUEUES BEHIND the live owner out to its
/// advertised hold deadline. If the lock still cannot be acquired, the wake
/// is REJECTED LOUDLY, naming the in-flight job — the old fallback (run a
/// fresh, context-free session that silently skips the topic's thread) is
/// deleted. That downgrade turned Agent's most consequential message into an
/// amnesiac 'Execution error' session; it must never be reachable again.
async function runWakeJob(payload, jobPath, claimId) {
  ensureDirs();
  const slug = topicSlug(payload.topic);
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
/// and Agent is told over the bridge that the message was NOT worked and
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
      httpStatus: bridge.httpStatus == null ? null : bridge.httpStatus,
      ackMode: bridge.ackMode || null,
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
    completionText: null,
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
  const hadPointerAtStart = pointer !== null;
  let activePointer = pointer;
  let selfHeal = null;

  const attempt = async (attemptPointer) => {
    const isNewSession = !attemptPointer;
    const sessionId = attemptPointer ? attemptPointer.sessionId : crypto.randomUUID();
    const sessionArgs = isNewSession ? ["--session-id", sessionId] : ["--resume", sessionId];
    const cwd = resolveCwd(payload, attemptPointer);
    // Ergonomics (Agent's correction, 2026-07-25): the enqueue->claim->start
    // gap was invisible and caused three deadline mis-filings. startedAt is
    // the RUNNER's clock zero for this attempt; deadlineAt is when the
    // watchdog will SIGTERM it. Judged from these, never from createdAt.
    const startedAt = nowISO();
    updateJob(jobPath, {
      state: "running",
      startedAt,
      deadlineAt: new Date(Date.parse(startedAt) + timeoutSeconds * 1000).toISOString(),
      // The stall threshold is published too, so an observer can tell a job
      // that is merely long from one that is overdue to be killed.
      stallSeconds: stallSeconds || null,
      progressAt: null,
      attemptSessionId: sessionId,
      attemptSessionMode: isNewSession ? "new" : "resume",
    }, claimId);
    // progressAt is the CHILD's liveness, deliberately distinct from
    // heartbeatAt (which only proves the runner is alive).
    const onProgress = ({ at, cpuMs }) => {
      updateJob(jobPath, { progressAt: at, progressCpuMs: cpuMs }, claimId);
    };
    const run = await runClaude({ prompt, sessionArgs, cwd, timeoutSeconds, stallSeconds, onProgress });
    const result = classify(run, timeoutSeconds, stallSeconds);
    return { ...result, sessionId, sessionMode: isNewSession ? "new" : "resume", cwd };
  };

  let outcome = await attempt(activePointer);
  attempts.push({
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

  // A brand-new session is only worth pinning once it actually produced a
  // turn — recording a session id that never came up would poison the topic
  // pointer with an unresumable id.
  // FENCE 1 — before anything externally visible. The claude run is over; if a
  // takeover happened while we were running, this process is a ghost: it must
  // not write the topic pointer and must not post to Agent.
  if (!ownsClaim(jobPath, claimId)) {
    return recordOrphanedClaim({ jobPath, claimId, payload, stage: "before_pointer_write" });
  }

  let pointerPath = null;
  if (outcome.sessionMode === "new" && outcome.status !== "failed") {
    pointerPath = writeSessionPointer(slug, outcome.sessionId, outcome.cwd);
  } else if (outcome.sessionMode === "resume") {
    pointerPath = sessionPointerPath(slug);
  }
  // Pointer-integrity check (Agent's correction): a wake on a topic that HAD
  // a pointer must end with that thread either resumed or explicitly healed
  // aside — a null pointerPath here means the thread was silently dropped,
  // which is Defect 3's damage shape. Loud in the receipt, never swallowed.
  const pointerIntegrity = hadPointerAtStart && !selfHeal && pointerPath === null
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
    sessionStoreCheck = confirmDeliveryViaSessionStore(payload.sessionId, payload.messageId);
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
    sessionPointerPath: pointerPath,
    pointerIntegrity,
    selfHeal,
    attempts,
    replyChars: outcome.reply ? outcome.reply.length : 0,
    stderrTail: outcome.stderrTail || null,
    bridge: {
      status: bridge.status,
      reason: bridge.reason || null,
      httpStatus: bridge.httpStatus == null ? null : bridge.httpStatus,
      ackMode: bridge.ackMode || null,
      url: process.env.NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN === "1" ? null : bridgeURL(),
    },
    sessionStoreCheck,
    // A completed reply that never reached Agent is the one thing we must
    // never lose: the job file is kept (it always is — it is also the dedup
    // record) and the failure is written into the receipt so recovery has
    // something to read. Only a PROVEN failure counts — "unknown" must never
    // read as lost, or the replay double-delivers a message that landed.
    deliveryLost: bridge.status === "failed" && outcome.status === "completed",
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
      // Claude's answer. An UNKNOWN delivery also keeps the text — not for
      // replay (unknown never replays) but so a later settle-against-the-store
      // can arm one if the store proves absence.
      deliveryLost: receipt.deliveryLost,
      completionText: (receipt.deliveryLost || (bridge.status === "unknown" && outcome.status === "completed"))
        ? completionText
        : null,
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
    exitCode: outcome.exitCode,
    durationMs: outcome.durationMs,
    timeoutSeconds,
    replyChars: receipt.replyChars,
    stderrTail: outcome.stderrTail || null,
    selfHeal,
    pointerIntegrity,
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

/// Replay ONLY the bridge delivery for a job that already holds a completed
/// reply Agent never received. Deliberately does not re-run claude: the answer
/// exists, the transport failed.
///
/// At-most-once under concurrent duplicates: two helpers can both lose the
/// O_EXCL claim, both read deliveryLost:true, and both reach here before
/// either clears completionText — so the POST is fenced by an atomic replay
/// lock. The loser reports replay_in_progress; a lock whose recorded pid is
/// dead is stolen (rename-aside, never deleted) so a crashed replayer cannot
/// poison redelivery.
async function replayLostDelivery(jobPath, job) {
  const lockDir = `${jobPath}.replay.lock`;
  const claimReplayLock = () => {
    fs.mkdirSync(lockDir, { mode: 0o700 });
    fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\n`, { mode: 0o600 });
  };
  try {
    claimReplayLock();
  } catch (error) {
    if (!error || error.code !== "EEXIST") {
      return {
        delivery: "claude_thread_wakeup",
        messageId: job.messageId || (job.payload && job.payload.messageId) || null,
        jobPath,
        status: "failed",
        reason: "replay_lock_failed",
        deliveryLost: true,
        error: String((error && error.message) || error),
      };
    }
    let ownerPid = NaN;
    try {
      ownerPid = Number(fs.readFileSync(path.join(lockDir, "pid"), "utf8").trim());
    } catch {}
    let lockLooksLive = Number.isFinite(ownerPid) && pidAlive(ownerPid);
    if (!Number.isFinite(ownerPid)) {
      // A missing pid file is a contender mid-acquire — but only briefly. A
      // contender that crashed inside the mkdir->pid-write window must not
      // block redelivery forever, so an aged pid-less lock is stale.
      let lockMtimeMs = 0;
      try { lockMtimeMs = fs.statSync(lockDir).mtimeMs; } catch {}
      const acquireGraceMs = Number(process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAIM_WRITE_GRACE_MS || 5000);
      lockLooksLive = lockMtimeMs !== 0 && Date.now() - lockMtimeMs < acquireGraceMs;
    }
    if (lockLooksLive) {
      return {
        delivery: "claude_thread_wakeup",
        messageId: job.messageId || (job.payload && job.payload.messageId) || null,
        jobPath,
        status: "skipped",
        reason: "replay_in_progress",
        deliveryLost: true,
      };
    }
    try {
      fs.renameSync(lockDir, `${lockDir}.stale-${nowISO().replace(/[:.]/g, "-")}`);
      claimReplayLock();
    } catch {
      return {
        delivery: "claude_thread_wakeup",
        messageId: job.messageId || (job.payload && job.payload.messageId) || null,
        jobPath,
        status: "skipped",
        reason: "replay_in_progress",
        deliveryLost: true,
      };
    }
  }
  try {
    // Re-read under the lock: a racing replayer may have finished while we
    // were acquiring, in which case there is nothing left to redeliver.
    const fresh = readJob(jobPath);
    if (!fresh || fresh.deliveryLost !== true
        || typeof fresh.completionText !== "string" || !fresh.completionText) {
      return {
        delivery: "claude_thread_wakeup",
        messageId: job.messageId || (job.payload && job.payload.messageId) || null,
        jobPath,
        status: "skipped",
        reason: "duplicate",
        note: "already_redelivered",
        deliveryLost: false,
      };
    }
    return await replayLostDeliveryLocked(jobPath, fresh);
  } finally {
    try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {}
  }
}

async function replayLostDeliveryLocked(jobPath, job) {
  const messageId = job.messageId || (job.payload && job.payload.messageId) || null;
  const sessionId = job.agentSessionId || (job.payload && job.payload.sessionId) || null;
  const settleDelivered = (check) => {
    updateJob(jobPath, {
      bridgeStatus: "delivered",
      bridgeReason: "confirmed_by_session_store",
      deliveryLost: false,
      completionText: null,
      sessionStoreCheck: check,
      unknownSettledAt: nowISO(),
    });
    return {
      delivery: "claude_thread_wakeup",
      messageId,
      jobPath,
      status: "skipped",
      reason: "duplicate",
      note: "unknown_confirmed_delivered",
      deliveryLost: false,
      sessionStoreCheck: check,
    };
  };
  // Final store read UNDER the replay lock, immediately before the POST: a
  // late-landing row (or a racing present-settlement by another duplicate)
  // must beat a stale "absent" observation — replaying a completion that
  // landed double-delivers it.
  if (confirmDeliveryViaSessionStore(sessionId, messageId) === "present") {
    return settleDelivered("present");
  }

  const bridge = await postBridgeMessage(job.completionText, sessionId || "");
  const ok = bridge.status === "delivered" || bridge.status === "dry_run";
  const base = {
    delivery: "claude_thread_wakeup",
    messageId,
    jobPath,
    bridge: {
      status: bridge.status,
      reason: bridge.reason || null,
      httpStatus: bridge.httpStatus == null ? null : bridge.httpStatus,
      url: process.env.NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN === "1" ? null : bridgeURL(),
    },
  };
  if (!ok) {
    if (bridge.status === "unknown") {
      // An ambiguous outcome on the REPLAY proves nothing either — same
      // defect, same rule. present -> delivered. Absent AND unreadable both
      // send the job BACK to unknown — deliveryLost cleared, completionText
      // kept — because an absent read here races THIS replay's own append.
      // The next arrival routes through settle_unknown, whose grace lets a
      // persisted absence re-arm honestly.
      const check = confirmDeliveryViaSessionStore(sessionId, messageId);
      if (check === "present") return settleDelivered(check);
      updateJob(jobPath, {
        bridgeStatus: "unknown",
        bridgeReason: bridge.reason || null,
        deliveryLost: false,
        sessionStoreCheck: check,
        lastBridgeAttemptAt: nowISO(),
      });
      return { ...base, status: "unknown", reason: bridge.reason || null, deliveryLost: false, sessionStoreCheck: check };
    }
    return { ...base, status: "failed", reason: "redelivery_failed", deliveryLost: true };
  }

  const receipt = {
    id: crypto.randomUUID(),
    createdAt: nowISO(),
    kind: "redelivery",
    messageId: base.messageId,
    topic: (job.payload && job.payload.topic) || DEFAULT_TOPIC,
    topicSlug: job.topicSlug || topicSlug(job.payload && job.payload.topic),
    jobPath,
    status: job.status || "completed",
    originalReceiptId: job.receiptId || null,
    bridge: base.bridge,
    deliveryLost: false,
  };
  try { appendJSONL(DELIVERIES_PATH, receipt); } catch {}
  // Deliberately NOT claim-gated: the replayer never claimed this job, and the
  // job is already SETTLED — its original runner is finished and will never
  // write again. Fencing here would make redelivery impossible.
  updateJob(jobPath, {
    deliveryLost: false,
    bridgeStatus: bridge.status,
    bridgeReason: bridge.reason || null,
    redeliveredAt: nowISO(),
    redeliveryReceiptId: receipt.id,
    completionText: null,
  });

  return {
    ...base,
    status: "redelivered",
    reason: null,
    deliveryLost: false,
    receiptId: receipt.id,
    receiptPath: DELIVERIES_PATH,
    ...(bridge.status === "dry_run" ? { wouldSendText: bridge.text } : {}),
  };
}

/// Late settlement for a job whose delivery outcome was UNKNOWN (bridge reply
/// timeout with the session store unreadable at the time). Reads the store
/// again: present -> the message landed, settle as delivered; provably absent
/// -> arm deliveryLost and replay; still unreadable -> stay unknown, honest
/// duplicate, no replay. deliveryLost:true is only ever written here on
/// store-read evidence — a bare timeout can never produce it.
async function settleUnknownDelivery(jobPath, job) {
  const messageId = job.messageId || (job.payload && job.payload.messageId) || null;
  const sessionId = job.agentSessionId || (job.payload && job.payload.sessionId) || null;
  const check = confirmDeliveryViaSessionStore(sessionId, messageId);
  const base = {
    delivery: "claude_thread_wakeup",
    messageId,
    jobPath,
    sessionStoreCheck: check,
    deliveryLost: false,
  };
  if (check === "present") {
    updateJob(jobPath, {
      bridgeStatus: "delivered",
      bridgeReason: "confirmed_by_session_store",
      deliveryLost: false,
      completionText: null,
      sessionStoreCheck: check,
      unknownSettledAt: nowISO(),
    });
    return { ...base, status: "skipped", reason: "duplicate", note: "unknown_confirmed_delivered" };
  }
  if (check === "absent" && typeof job.completionText === "string" && job.completionText) {
    // Absence only counts once it has PERSISTED past the settle grace since
    // the last bridge attempt — an immediate re-read races the append that
    // attempt may have started (the false-replay class, gpt-5.5 2026-07-25).
    const attemptMs = Date.parse(job.lastBridgeAttemptAt || job.completedAt || job.updatedAt || "");
    const ageMs = Number.isFinite(attemptMs) ? Date.now() - attemptMs : Infinity;
    const graceMs = envNumber("NATIVE_AGENT_CLAUDE_WAKE_ABSENT_GRACE_MS", DEFAULT_ABSENT_SETTLE_GRACE_MS);
    if (ageMs < graceMs) {
      return { ...base, status: "skipped", reason: "duplicate", note: "unknown_absent_within_grace", ageMs, graceMs };
    }
    const armed = updateJob(jobPath, {
      bridgeStatus: "failed",
      bridgeReason: "absent_from_session_store",
      deliveryLost: true,
      sessionStoreCheck: check,
      unknownSettledAt: nowISO(),
    });
    return replayLostDelivery(jobPath, armed || { ...job, deliveryLost: true });
  }
  return { ...base, status: "skipped", reason: "duplicate", note: "unknown_unresolved" };
}

/// What to do when the O_EXCL claim loses. The job file is the dedup marker,
/// but it must also be a RECOVERY handle: a runner that died mid-flight (crash,
/// SIGKILL, Mac sleep) previously poisoned its messageId permanently.
async function resolveExistingJob(jobPath, payload) {
  const job = readJob(jobPath);
  if (!job) {
    // Unreadable claim: usually corrupt — but a FRESH unreadable file is a
    // live claimant between its O_EXCL create and its first JSON write.
    // Stealing it would rename a live claim aside; give the write a grace.
    let mtimeMs = 0;
    try { mtimeMs = fs.statSync(jobPath).mtimeMs; } catch {}
    const writeGraceMs = Number(process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAIM_WRITE_GRACE_MS || 5000);
    if (mtimeMs && Date.now() - mtimeMs < writeGraceMs) {
      return { action: "duplicate", job: null, note: "claimMidWrite" };
    }
    return { action: "takeover", stalePath: renameJobAside(jobPath), reason: "job_unreadable" };
  }

  if (job.state === "settled") {
    if (job.deliveryLost === true && typeof job.completionText === "string" && job.completionText) {
      return { action: "replay", job };
    }
    // An unknown-delivery settlement is re-examined on every duplicate
    // arrival: the store may be readable now, or the row may have landed.
    // Unknown NEVER reaches the replay branch above directly — replay
    // requires store-proven absence (settleUnknownDelivery is the only path
    // that can arm deliveryLost on such a job).
    if (job.bridgeStatus === "unknown") {
      return { action: "settle_unknown", job };
    }
    return { action: "duplicate", job };
  }

  if (job.state === "spawn_failed") {
    return { action: "takeover", stalePath: renameJobAside(jobPath), reason: "runner_spawn_failed" };
  }

  const ownerPid = Number(job.pid);
  const runnerPid = Number(job.runnerPid);
  const hasRunnerPid = Number.isInteger(runnerPid) && runnerPid > 0;
  const ageMs = jobHeartbeatAgeMs(job);
  const staleMs = staleThresholdMs(job);

  // Takeover requires that EVERY recorded owner pid be provably dead. A stale
  // heartbeat is NOT sufficient on its own: renaming a live runner's job aside
  // lets two processes run the same wake and post two completions to Agent.
  // The tradeoff is deliberate — a wedged-but-alive runner blocks retries of
  // that messageId until it dies. Safety over availability; a stuck wake costs
  // one message, a double wake costs Agent's trust in the receipt stream.
  if (pidAlive(ownerPid) || (hasRunnerPid && pidAlive(runnerPid))) {
    return {
      action: "duplicate",
      job,
      note: ageMs > staleMs ? "staleHeartbeat" : null,
      ageMs,
      staleMs,
      ownerPid,
    };
  }

  // Every recorded pid is dead. One window remains where that is a LIE: the
  // parent claimed with its own pid, spawned the detached child, and died
  // before it could record runnerPid. Nothing on disk names the live child, so
  // give that window a bounded grace before believing the job is orphaned.
  if (!hasRunnerPid) {
    const graceMs = envNumber("NATIVE_AGENT_CLAUDE_WAKE_SPAWN_GRACE_MS", DEFAULT_SPAWN_GRACE_MS);
    const createdMs = Date.parse((job && job.createdAt) || "");
    const createdAgeMs = Number.isFinite(createdMs) ? Date.now() - createdMs : Infinity;
    const youngestAgeMs = Math.min(ageMs, createdAgeMs);
    if (graceMs > 0 && youngestAgeMs < graceMs) {
      return {
        action: "duplicate",
        job,
        note: "spawnGrace",
        ageMs: youngestAgeMs,
        graceMs,
        ownerPid,
      };
    }
  }

  return { action: "takeover", stalePath: renameJobAside(jobPath), reason: "runner_pid_dead", ownerPid, ageMs };
}

/// Structural ping-pong guard. The prompt preamble asks Agent not to auto-fire
/// another claude_message on a completion receipt; this is the part that does
/// not depend on her cooperating. Every wake of the SAME topic writes a job
/// file, so counting recent same-topic jobs bounds the loop rate regardless of
/// how many distinct messageIds she mints.
///
/// Residual risk (accepted, documented): a loop that stays UNDER the threshold
/// — e.g. two wakes per ten minutes forever, each with a new messageId — is
/// still possible. This caps the burst rate, not the existence of a slow loop.
/// Nothing is lost when it fires: Swift already appended the message to the
/// durable inbox before spawning us, so the message still reaches Claude as
/// the old note-in-a-bottle; only the auto-wake is suppressed.
function topicRateLimit(slug, messageId) {
  const windowMs = envNumber("NATIVE_AGENT_CLAUDE_WAKE_RATE_WINDOW_MS", DEFAULT_RATE_WINDOW_MS);
  const maxJobs = envNumber("NATIVE_AGENT_CLAUDE_WAKE_RATE_MAX", DEFAULT_RATE_MAX_JOBS);
  if (maxJobs <= 0 || windowMs <= 0) return null;

  let names;
  try { names = fs.readdirSync(WAKE_JOBS_DIR); } catch { return null; }
  const cutoff = Date.now() - windowMs;
  let count = 0;
  for (const name of names) {
    // `.stale-<ts>` takeovers are dead runs, not live traffic — excluded by
    // the extension test.
    if (!name.endsWith(".json")) continue;
    const job = readJob(path.join(WAKE_JOBS_DIR, name));
    if (!job || job.topicSlug !== slug) continue;
    if (job.messageId && job.messageId === messageId) continue;
    const created = Date.parse(job.createdAt || "");
    if (!Number.isFinite(created) || created < cutoff) continue;
    count += 1;
  }
  if (count < maxJobs) return null;
  return { recentJobs: count, windowMs, maxJobs };
}

function sanitizePayload(raw) {
  const payload = raw && typeof raw === "object" ? raw : {};
  const clean = {
    messageId: typeof payload.messageId === "string" && payload.messageId.trim() !== ""
      ? payload.messageId.trim().slice(0, 160)
      : crypto.randomUUID(),
    text: typeof payload.text === "string" ? payload.text : "",
    priority: ["info", "important", "urgent"].includes(String(payload.priority || "").toLowerCase())
      ? String(payload.priority).toLowerCase()
      : "info",
    topic: typeof payload.topic === "string" && payload.topic.trim() !== ""
      ? payload.topic.trim().slice(0, 160)
      : DEFAULT_TOPIC,
    queuedAt: typeof payload.queuedAt === "string" && payload.queuedAt ? payload.queuedAt : nowISO(),
    source: "claude_message",
  };
  if (typeof payload.inboxPath === "string" && payload.inboxPath) clean.inboxPath = payload.inboxPath;
  if (typeof payload.sessionId === "string" && payload.sessionId) clean.sessionId = payload.sessionId;
  if (typeof payload.cwd === "string" && payload.cwd) clean.cwd = payload.cwd;
  // 0 survives sanitization: it is the explicit "disable the stall watchdog"
  // signal, not a missing value.
  if (Number.isFinite(Number(payload.stallSeconds)) && Number(payload.stallSeconds) >= 0) {
    clean.stallSeconds = Number(payload.stallSeconds);
  }
  if (Number.isFinite(Number(payload.timeoutSeconds)) && Number(payload.timeoutSeconds) > 0) {
    clean.timeoutSeconds = Number(payload.timeoutSeconds);
  }
  if (payload.origin && typeof payload.origin === "object" && !Array.isArray(payload.origin)) {
    const origin = {};
    for (const key of ["surface", "destinationId", "threadId", "sourceKey", "replyTo", "correlationId"]) {
      if (typeof payload.origin[key] === "string" && payload.origin[key].trim() !== "") {
        origin[key] = payload.origin[key];
      }
    }
    if (Object.keys(origin).length > 0) clean.origin = origin;
  }
  return clean;
}

function inlineMode() {
  return process.env.NATIVE_AGENT_CLAUDE_WAKE_INLINE === "1";
}

/// The child carries the claimId in its argv: it is the token that proves the
/// job file on disk is still the one this process was spawned to run.
function spawnDetachedRunner(jobPath, claimId) {
  const child = spawn(process.execPath, [__filename, "--run", jobPath, "--claim", String(claimId || "")], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env },
  });
  child.unref();
  return child.pid || null;
}

async function main() {
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

  const payload = sanitizePayload(raw);
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

  const slug = topicSlug(payload.topic);
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
  const claimRecord = () => {
    claimId = crypto.randomUUID();
    return {
      messageId: payload.messageId,
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
      topicSlug: slug,
      timeoutSeconds: resolveTimeoutSeconds(payload),
      stallSeconds: resolveStallSeconds(payload) || null,
      // Commit hold (task #49, User 2026-07-25): every wake session starts
      // held — build/test/verify and REPORT, but no git commit/push until
      // User, Agent, or the interactive Claude releases this job. Two
      // same-day incidents of wake sessions pushing through intended pauses
      // (5af594ae race, f9d62ff6 through User's held verification gate) —
      // both shipped correct content; the hold restores WHO decides.
      // Released via script/wake_hold_release.js (atomic job-record update).
      commitPolicy: "hold",
      holdReleasedAt: null,
      holdReleasedBy: null,
      payload,
    };
  };

  let claimed;
  let takeover = null;
  // Two attempts at most: the second only happens after we renamed a provably
  // dead job aside.
  for (let attempt = 0; attempt < 2; attempt += 1) {
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

    const resolution = await resolveExistingJob(jobPath, payload);
    if (resolution.action === "replay") {
      jsonOut(await replayLostDelivery(jobPath, resolution.job));
      return;
    }
    if (resolution.action === "settle_unknown") {
      jsonOut(await settleUnknownDelivery(jobPath, resolution.job));
      return;
    }
    if (resolution.action === "takeover" && attempt === 0) {
      takeover = {
        reason: resolution.reason,
        stalePath: resolution.stalePath || null,
        previousPid: resolution.ownerPid == null ? null : resolution.ownerPid,
        heartbeatAgeMs: resolution.ageMs == null ? null : resolution.ageMs,
      };
      continue;
    }
    jsonOut({
      status: "skipped",
      reason: "duplicate",
      delivery: "claude_thread_wakeup",
      messageId: payload.messageId,
      // Why we deferred: `staleHeartbeat` means a live pid held it past the
      // stale threshold (we refuse to race it); `spawnGrace` means the
      // parent/child handoff window is still open.
      note: resolution.note || null,
      heartbeatAgeMs: resolution.ageMs == null ? null : resolution.ageMs,
      jobPath,
    });
    return;
  }
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
  try {
    const pid = spawnDetachedRunner(jobPath, claimId);
    // Record the runner pid ONLY. The detached child owns `state` and the
    // heartbeat (it may already have settled by now, and a parent write of
    // state:"running" would rewind a settled job — which reads as a crashed
    // runner and invites a spurious takeover re-run).
    // `pid` is repointed at the runner so a duplicate arriving in the window
    // before the child's first heartbeat sees a LIVE owner, not the exited
    // foreground claimer.
    // Claim-gated like every other write: if the child already settled and a
    // later arrival took the job over, the parent must not stamp its runner pid
    // onto somebody else's claim. Recording runnerPid ALSO closes the
    // spawn-grace window — from here on the child is nameable on disk.
    updateJob(jobPath, { runnerPid: pid, pid: pid || process.pid, heartbeatAt: nowISO() }, claimId);
    jsonOut({
      status: "sent",
      delivery: "claude_thread_wakeup",
      mode: "detached",
      messageId: payload.messageId,
      topic: payload.topic,
      topicSlug: slug,
      runnerPid: pid,
      jobPath,
      receiptPath: DELIVERIES_PATH,
      ...(takeover ? { takeover } : {}),
    });
  } catch (error) {
    updateJob(jobPath, { state: "spawn_failed", error: String((error && error.message) || error) }, claimId);
    jsonOut({
      status: "failed",
      reason: "runner_spawn_failed",
      messageId: payload.messageId,
      jobPath,
      error: String((error && error.message) || error),
    });
  }
}

if (require.main === module) {
  main().catch((error) => {
    jsonOut({ status: "failed", reason: "uncaught_error", error: String((error && error.message) || error) });
    process.exit(0);
  });
}

module.exports = {
  bridgeURL,
  classify,
  confirmDeliveryViaSessionStore,
  deliveryMarker,
  ownsClaim,
  formatCompletionForAgent,
  formatPrompt,
  postBridgeMessage,
  redactDiagnosticText,
  resolveTimeoutSeconds,
  resolveStallSeconds,
  processTreeCpuMs,
  runWakeJob,
  sanitizePayload,
  sessionGone,
  topicRateLimit,
  topicSlug,
};
