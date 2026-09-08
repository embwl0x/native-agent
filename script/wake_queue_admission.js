"use strict";

// Lane-specific queue admission; entrypoints supply runtime policy and effects.

function createCodexQueueAdmission({
  DEFAULT_WAKE_CONCURRENCY,
  FRESH_THREAD_MODE,
  GITHUB_COMMAND_EXECUTION_PROFILE,
  PINNED_THREAD_MODE,
  WAKE_CAPACITY_DIR,
  WAKE_LANES_DIR,
  appendJSONLineAtomicUnlocked,
  canonicalCodexThreadId,
  copyWakeCompletionOrigin,
  copyWakeProducerIdentity,
  currentProcessStartIdentity,
  deadLetterPath,
  dirLockOwnerAlive,
  isCodexNonThreadSentinel,
  markInboxTerminal,
  nowISO,
  pendingPath,
  queueLockDir,
  readWakeJSON,
  sleep,
  unicodePrefix,
  wakeConcurrencyCap,
  wakeLaneKey,
  wakeLaneLockPath,
  writeJSONAtomic
}) {
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

function pendingKey(payload, threadId) {
  const canonicalThread = canonicalCodexThreadId(threadId);
  if (payload.messageId) return `${canonicalThread || "fresh"}:${payload.messageId}`;
  const digest = crypto
    .createHash("sha256")
    .update(`${canonicalThread || "fresh"}\n${payload.topic || ""}\n${payload.text || ""}`)
    .digest("hex")
    .slice(0, 32);
  return `${canonicalThread || "fresh"}:sha256:${digest}`;
}

function sanitizePayload(payload) {
  const clean = {
    messageId: payload.messageId || crypto.randomUUID(),
    text: payload.text,
    priority: payload.priority || "info",
    queuedAt: payload.queuedAt || nowISO(),
    source: payload.source || "codex_message",
  };
  if (payload.topic) clean.topic = payload.topic;
  if (payload.inboxPath) clean.inboxPath = payload.inboxPath;
  if (payload.sessionId) clean.sessionId = payload.sessionId;
  if (payload.model) clean.model = String(payload.model);
  if (payload.reasoningEffort) clean.reasoningEffort = String(payload.reasoningEffort);
  if (payload.serviceTier) clean.serviceTier = String(payload.serviceTier);
  if (typeof payload.fast === "boolean") clean.fast = payload.fast;
  if (payload.pairReviewer === true) clean.pairReviewer = true;
  if (payload.completionMode === "receipt_only") clean.completionMode = "receipt_only";
  copyWakeProducerIdentity(payload, clean);
  if (typeof payload.deskHandle === "string" && /^desk_[A-Za-z0-9-]+$/.test(payload.deskHandle)) {
    clean.deskHandle = payload.deskHandle;
  }
  if (typeof payload.workingDirectory === "string" && path.isAbsolute(payload.workingDirectory)) {
    clean.workingDirectory = path.normalize(payload.workingDirectory);
  }
  if (payload.executionProfile === GITHUB_COMMAND_EXECUTION_PROFILE) {
    clean.executionProfile = GITHUB_COMMAND_EXECUTION_PROFILE;
  }
  copyWakeCompletionOrigin(payload, clean);
  if (payload.brain && typeof payload.brain === "object" && !Array.isArray(payload.brain)) {
    clean.brain = payload.brain;
  }
  return clean;
}

async function withDirLock(lockDir, fn, options = {}) {
  const waitMs = options.waitMs == null ? 2000 : options.waitMs;
  const staleMs = options.staleMs == null ? 10 * 60 * 1000 : options.staleMs;
  const preserveLiveOwner = options.preserveLiveOwner === true;
  const ownerAlive = options.dirLockOwnerAlive || dirLockOwnerAlive;
  const deadline = Date.now() + waitMs;
  while (true) {
    try {
      fs.mkdirSync(lockDir, { mode: 0o700 });
      fs.writeFileSync(
        path.join(lockDir, "pid"),
        `${process.pid}\n${nowISO()}\n${currentProcessStartIdentity() || ""}\n`,
        { mode: 0o600 }
      );
      break;
    } catch (error) {
      if (error && error.code === "EEXIST") {
        try {
          const stat = fs.statSync(lockDir);
          if (preserveLiveOwner) {
            // Reply waits are configurable and may legitimately exceed
            // `staleMs`; stealing from a live owner can dispatch the same
            // completion twice. A dead/invalid owner is safe to recover now.
            // EXCEPT a just-created lock with no pid file yet: its owner is
            // between mkdir and the pid write — stealing there removes a
            // LIVE contender's lock (review dcf9cf804931 finding 1). Give
            // that window a short mtime grace; a genuinely dead owner's
            // lock ages past it immediately.
            const pidMissing = !fs.existsSync(path.join(lockDir, "pid"));
            const withinAcquireGrace = pidMissing && Date.now() - stat.mtimeMs < 2000;
            if (!withinAcquireGrace && !ownerAlive(lockDir)) {
              fs.rmSync(lockDir, { recursive: true, force: true });
              continue;
            }
          } else if (Date.now() - stat.mtimeMs > staleMs) {
            fs.rmSync(lockDir, { recursive: true, force: true });
            continue;
          }
        } catch {}
        if (Date.now() >= deadline) {
          const lockError = new Error("lock_busy");
          lockError.lockDir = lockDir;
          throw lockError;
        }
        await sleep(50);
        continue;
      }
      throw error;
    }
  }

  try {
    return await fn();
  } finally {
    fs.rmSync(lockDir, { recursive: true, force: true });
  }
}

async function withWakeCapacity(laneKey, config, fn, options = {}) {
  const capacityRoot = options.capacityRoot || WAKE_CAPACITY_DIR;
  const requestedCap = options.cap == null ? wakeConcurrencyCap(config) : Number(options.cap);
  const cap = Math.max(
    1,
    Math.min(
      DEFAULT_WAKE_CONCURRENCY,
      Number.isFinite(requestedCap) ? Math.floor(requestedCap) : wakeConcurrencyCap(config)
    )
  );
  fs.mkdirSync(capacityRoot, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(capacityRoot, 0o700); } catch {}

  // Spread independent lanes across the fixed slot set so simultaneous
  // processes do not all contend for slot zero first. Every slot is still
  // attempted, and mkdir remains the cross-process admission authority.
  const seed = Number.parseInt(
    crypto.createHash("sha256").update(String(laneKey)).digest("hex").slice(0, 8),
    16
  );
  let lastBusy = null;
  for (let offset = 0; offset < cap; offset += 1) {
    const index = (seed + offset) % cap;
    const slotDir = path.join(capacityRoot, `slot-${index}.lock`);
    try {
      return await withDirLock(slotDir, fn, {
        waitMs: 0,
        staleMs: 60 * 60 * 1000,
        preserveLiveOwner: true,
        dirLockOwnerAlive: options.dirLockOwnerAlive,
      });
    } catch (error) {
      if (!error || error.message !== "lock_busy") throw error;
      lastBusy = error;
    }
  }
  const error = lastBusy || new Error("lock_busy");
  error.message = "lock_busy";
  error.reason = "wake_capacity_busy";
  error.capacity = cap;
  error.capacityRoot = capacityRoot;
  throw error;
}

async function withWakeExecutionLane(laneKey, config, fn, options = {}) {
  const lockDir = options.laneLockDir || wakeLaneLockPath(
    laneKey,
    options.lanesRoot || WAKE_LANES_DIR
  );
  fs.mkdirSync(path.dirname(lockDir), { recursive: true, mode: 0o700 });
  try { fs.chmodSync(path.dirname(lockDir), 0o700); } catch {}
  try {
    return await withDirLock(lockDir, async () => withWakeCapacity(
      laneKey,
      config,
      fn,
      options
    ), {
      waitMs: options.laneWaitMs == null ? 0 : options.laneWaitMs,
      staleMs: 60 * 60 * 1000,
      preserveLiveOwner: true,
      dirLockOwnerAlive: options.dirLockOwnerAlive,
    });
  } catch (error) {
    if (error && error.message === "lock_busy" && !error.reason) {
      error.reason = "wake_lane_lock_busy";
      error.laneKey = laneKey;
      error.lockDir = lockDir;
    }
    throw error;
  }
}

function readPendingAtPath(pendingPath) {
  const parsed = readWakeJSON(pendingPath);
  return Array.isArray(parsed) ? parsed : [];
}

function readPendingUnlocked() {
  return readPendingAtPath(pendingPath());
}

function writePendingUnlocked(entries) {
  writeJSONAtomic(pendingPath(), entries);
}

async function appendPending(payload, threadId, options = {}) {
  const cleanPayload = sanitizePayload(payload);
  const canonicalThread = canonicalCodexThreadId(threadId);
  const mode = options.mode === FRESH_THREAD_MODE || !canonicalThread
    ? FRESH_THREAD_MODE
    : PINNED_THREAD_MODE;
  const laneKey = options.laneKey || wakeLaneKey(
    options.laneIdentityPayload || payload,
    canonicalThread,
    mode
  );
  const key = pendingKey(cleanPayload, canonicalThread);
  const requestedRetryCount = Number(options.hangRetryCount);
  const hangRetryCount = Number.isInteger(requestedRetryCount) && requestedRetryCount >= 0
    ? requestedRetryCount
    : 0;
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const existing = queue.find((entry) => entry.key === key);
    if (existing) {
      if (hangRetryCount > Number(existing.hangRetryCount || 0)) {
        existing.hangRetryCount = hangRetryCount;
        if (options.hungTurnId) existing.hungTurnId = String(options.hungTurnId);
        writePendingUnlocked(queue);
      }
      return {
        entry: existing,
        alreadyQueued: true,
        pendingCount: queue.length,
        lanePosition: queue
          .filter((entry) => entryLaneKey(entry) === laneKey)
          .findIndex((entry) => entry.id === existing.id),
      };
    }
    const entry = {
      id: crypto.randomUUID(),
      key,
      threadId: canonicalThread,
      mode,
      laneKey,
      payload: cleanPayload,
      addedAt: nowISO(),
      attempts: 0,
      hangRetryCount,
      ...(options.hungTurnId ? { hungTurnId: String(options.hungTurnId) } : {}),
    };
    queue.push(entry);
    writePendingUnlocked(queue);
    return {
      entry,
      alreadyQueued: false,
      pendingCount: queue.length,
      lanePosition: queue.filter((candidate) => entryLaneKey(candidate) === laneKey).length - 1,
    };
  });
}

async function removePending(ids) {
  const idSet = new Set(ids);
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const next = queue.filter((entry) => !idSet.has(entry.id));
    writePendingUnlocked(next);
    return { before: queue.length, after: next.length };
  });
}

/// Errors that RETRYING CANNOT FIX. A parse failure on the thread id, or a
/// thread the app-server will never load, is the same answer on attempt 1 and
/// attempt 741 — and 741 is not hypothetical, it is what wave 2 actually
/// reached in five minutes while starving the rows queued behind it.
const TERMINAL_WAKE_ERROR_RE =
  /invalid thread id|thread not loaded|malformed .*thread|no such thread/i;

/// Attempts cap for everything the matcher does NOT recognise. A transient
/// failure that has failed this many times in a row is indistinguishable from a
/// permanent one, and an unbounded retry is a hot loop with a queue behind it.
const MAX_WAKE_ATTEMPTS = 25;

function isTerminalWakeFailure(entry, errorText) {
  // The app-server's own words are authoritative: a parse failure or an
  // unloadable thread is the same answer on attempt 1 and attempt 741.
  if (TERMINAL_WAKE_ERROR_RE.test(String(errorText || ""))) return true;
  // A sentinel that slipped through as a pinned id can never resolve. Note this
  // asks "is it a non-thread WORD", not "is it a UUID" — aliases are valid.
  const rawThreadId = entry && entry.threadId;
  if (typeof rawThreadId === "string" && rawThreadId.trim() !== ""
      && isCodexNonThreadSentinel(rawThreadId)) {
    return true;
  }
  // Everything else gets a bounded number of tries. A fresh-thread row carries
  // `threadId: null` BY DESIGN and must keep retrying transient failures —
  // dead-lettering it on attempt 1 would turn a hot-loop fix into work loss.
  return Number(entry && entry.attempts || 0) + 1 >= MAX_WAKE_ATTEMPTS;
}

/// Retire a row that can never succeed: off the queue, into a dated
/// dead-letter file, so the lane behind it drains and the payload is still
/// recoverable. Deleting it outright would lose the caller's brief.
async function deadLetterPendingEntry(entry, errorText, reason) {
  const deadLetteredAt = nowISO();
  const terminalReason = reason || "terminal_failure";
  try {
    const path = deadLetterPath();
    await withDirLock(`${path}.append.lock`, async () => {
      appendJSONLineAtomicUnlocked(path, {
        deadLetteredAt,
        reason: terminalReason,
        lastError: errorText ? unicodePrefix(errorText, 500) : null,
        entry,
      });
    }, { waitMs: 5000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
  } catch (error) {
    // A dead-letter write failure must not resurrect the hot loop; the row
    // still comes off the queue and the reason is reported to the caller.
    console.error(`dead-letter write failed: ${error && error.message}`);
  }
  const terminal = await markInboxTerminal([{
    ...entry,
    terminalDisposition: { deadLetteredAt, reason: terminalReason },
  }]);
  if (terminal.status === "failed" || terminal.status === "partial") {
    console.error(`dead-letter inbox projection ${terminal.status}: ${entry && entry.id}`);
  }
  return await removePending([entry.id]);
}

async function bumpPendingAttempt(id, errorText) {
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const next = queue.map((entry) => {
      if (entry.id !== id) return entry;
      return {
        ...entry,
        attempts: Number(entry.attempts || 0) + 1,
        lastAttemptAt: nowISO(),
        lastError: errorText ? unicodePrefix(errorText, 500) : null,
      };
    });
    writePendingUnlocked(next);
    return next.length;
  });
}

function entryLaneKey(entry) {
  if (entry && typeof entry.laneKey === "string" && entry.laneKey) return entry.laneKey;
  return wakeLaneKey(
    entry && entry.payload || {},
    entry && entry.threadId || null,
    entry && entry.mode || (entry && entry.threadId ? PINNED_THREAD_MODE : FRESH_THREAD_MODE)
  );
}

function firstPendingPerLane(queue) {
  const byLane = new Map();
  for (const entry of queue) {
    if (!entry || !entry.payload || !entry.payload.text) continue;
    const laneKey = entryLaneKey(entry);
    if (!byLane.has(laneKey)) byLane.set(laneKey, entry);
  }
  return [...byLane.values()];
}

async function pendingHeadForLane(entryId, laneKey) {
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const head = queue.find((entry) => entryLaneKey(entry) === laneKey) || null;
    return {
      isHead: Boolean(head && head.id === entryId),
      head,
      pendingCount: queue.length,
    };
  }, { waitMs: 2000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
}

async function markPendingStaleRecovery(entry, recovery) {
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const index = queue.findIndex((candidate) => candidate.id === entry.id);
    if (index < 0) return { status: "missing", entry: null };
    const current = queue[index];
    if (current.key !== entry.key || entryLaneKey(current) !== entryLaneKey(entry)) {
      return { status: "identity_conflict", entry: current };
    }
    const updated = {
      ...current,
      // id/key/addedAt/payload and array position deliberately do not change:
      // recovery is a fresh admission attempt for the same ordered work, not
      // a new message that could jump behind later work or lose audit lineage.
      staleRecoveryCount: Number(current.staleRecoveryCount || 0) + 1,
      requeuedAt: recovery.recoveredAt,
      staleRecovery: recovery,
    };
    queue[index] = updated;
    writePendingUnlocked(queue);
    return { status: "requeued", entry: updated, pendingCount: queue.length };
  }, { waitMs: 2000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
}

return {
  sanitizePayload,
  withDirLock,
  withWakeCapacity,
  withWakeExecutionLane,
  readPendingAtPath,
  readPendingUnlocked,
  appendPending,
  removePending,
  isTerminalWakeFailure,
  deadLetterPendingEntry,
  bumpPendingAttempt,
  entryLaneKey,
  firstPendingPerLane,
  pendingHeadForLane,
  markPendingStaleRecovery
};
}

function createClaudeQueueAdmission({
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
}) {
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

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
/// QUEUE-BEHIND (the agent work order 2026-07-25, Defect 3): a waiter behind a
/// LIVE owner extends its wait to the owner's advertised hold deadline plus
/// margin (capped at QUEUE_BEHIND_ABS_CAP_MS) so back-to-back wakes on one
/// topic thread cleanly instead of colliding. If the lock is STILL held by a
/// live owner at the final deadline, the caller must REJECT the wake, naming
/// the in-flight job — the old fallback (run a fresh uncontinued session)
/// silently delivered the agent's message to a context-free Claude and is gone.
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
      let inspectedLock = false;
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
        inspectedLock = true;
      } catch {}
      // The owner can remove the directory after our mkdir observed EEXIST
      // but before the inspection above. That is an unlocked retry, not a
      // busy lock whose (already elapsed) base deadline should reject the
      // queued wake. Under load this tiny release/acquire window used to turn
      // an honestly serialized second wake into rejected_topic_busy.
      if (!inspectedLock || !fs.existsSync(lockDir)) continue;
      if (ownerMeta && ownerMeta.recoveryOnly) {
        return { acquired: false, lockDir, reason: "lock_busy", inFlight: owner, waitedMs: Date.now() - startedMs, release() {} };
      }
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

/// Structural ping-pong guard. The prompt preamble asks the agent not to auto-fire
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
      ? payload.messageId.trim()
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
  copyWakeProducerIdentity(payload, clean);
  if (payload.pairReviewer === true) clean.pairReviewer = true;
  if (payload.requireExistingConversation === true) clean.requireExistingConversation = true;
  if (typeof payload.deskHandle === "string" && /^desk_[A-Za-z0-9-]+$/.test(payload.deskHandle)) {
    clean.deskHandle = payload.deskHandle;
  }
  // 0 survives sanitization: it is the explicit "disable the stall watchdog"
  // signal, not a missing value.
  if (Number.isFinite(Number(payload.stallSeconds)) && Number(payload.stallSeconds) >= 0) {
    clean.stallSeconds = Number(payload.stallSeconds);
  }
  if (Number.isFinite(Number(payload.timeoutSeconds)) && Number(payload.timeoutSeconds) > 0) {
    clean.timeoutSeconds = Number(payload.timeoutSeconds);
  }
  copyWakeCompletionOrigin(payload, clean);
  return clean;
}

return {
  readLockOwnerInfo,
  topicLockDir,
  resolveLockWaitMs,
  acquireTopicLock,
  topicRateLimit,
  sanitizePayload
};
}

module.exports = { createCodexQueueAdmission, createClaudeQueueAdmission };
