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
const { AsyncLocalStorage } = require("async_hooks");
const heldCapacitySlot = new AsyncLocalStorage();

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
      return await withDirLock(slotDir,
        () => heldCapacitySlot.run(slotDir, fn), {
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

async function withAllWakeCapacity(fn) {
  fs.mkdirSync(WAKE_CAPACITY_DIR, { recursive: true, mode: 0o700 });
  async function acquire(index) {
    if (index === DEFAULT_WAKE_CONCURRENCY) return await fn();
    const slotDir = path.join(WAKE_CAPACITY_DIR, `slot-${index}.lock`);
    // Foreground cwd healing can already own one admission slot.
    if (heldCapacitySlot.getStore() === slotDir) return await acquire(index + 1);
    return await withDirLock(slotDir, () => acquire(index + 1),
      { waitMs: 0, preserveLiveOwner: true });
  }
  return await acquire(0);
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
  let raw;
  try {
    raw = fs.readFileSync(pendingPath, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return [];
    throw error;
  }
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) throw new Error(`pending_queue_not_array: ${pendingPath}`);
  return parsed;
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
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const existing = queue.find((entry) => entry.key === key);
    if (existing) {
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
    };
    // The app's finished launch decision, beside the payload: sanitizePayload
    // keeps no permission field, so a payload can never carry one in.
    if (options.launch) entry.launch = options.launch;
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
  // Old hang requeues have already started work. Retain them in the existing
  // dead letters for effect reconciliation rather than admitting a replay.
  if (entry && (entry.hungTurnId || Number(entry.hangRetryCount || 0) > 0)) return true;
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
  // Checkpoint terminal state before either projection. If storage is
  // unavailable, retain the brief without letting it execute again.
  const terminalEntry = await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const current = queue.find((candidate) => candidate.id === entry.id && candidate.key === entry.key);
    if (!current) return null;
    current.terminalDisposition = current.terminalDisposition || {
      deadLetteredAt: nowISO(),
      reason: reason || "terminal_failure",
      lastError: errorText ? unicodePrefix(errorText, 500) : null,
    };
    writePendingUnlocked(queue);
    return current;
  });
  if (!terminalEntry) return { status: "missing" };
  const { deadLetteredAt, reason: terminalReason, lastError } = terminalEntry.terminalDisposition;
  let persisted = false;
  try {
    const path = deadLetterPath();
    await withDirLock(`${path}.append.lock`, async () => {
      appendJSONLineAtomicUnlocked(path, {
        deadLetteredAt,
        reason: terminalReason,
        lastError,
        entry: terminalEntry,
      });
    }, { waitMs: 5000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
    persisted = true;
  } catch (error) {
    console.error(`dead-letter write failed: ${error && error.message}`);
  }
  const terminal = await markInboxTerminal([terminalEntry]);
  if (terminal.status === "failed" || terminal.status === "partial") {
    console.error(`dead-letter inbox projection ${terminal.status}: ${entry && entry.id}`);
  }
  if (!persisted) return { status: "retained_terminal", entry: terminalEntry };
  return { status: "removed", ...await removePending([entry.id]) };
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

async function checkpointPendingAdmission(entries, admission, options = {}) {
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    for (const entry of entries) {
      const current = queue.find((candidate) => candidate.id === entry.id && candidate.key === entry.key);
      if (!current) {
        if (options.allowMissing) continue;
        throw new Error("pending_admission_identity_changed");
      }
      if (current.freshAdmission && (current.freshAdmission.threadId !== admission.threadId
          || current.freshAdmission.clientUserMessageId !== admission.clientUserMessageId
          || current.freshAdmission.jobPath !== admission.jobPath
          || (current.freshAdmission.turnId && admission.turnId
            && current.freshAdmission.turnId !== admission.turnId))) {
        throw new Error("pending_admission_identity_conflict");
      }
      if (current.freshAdmission && current.freshAdmission.turnId) admission.turnId = current.freshAdmission.turnId;
      current.freshAdmission = admission;
    }
    writePendingUnlocked(queue);
    for (const entry of entries) entry.freshAdmission = admission;
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
    if (!entry || entry.terminalDisposition || !entry.payload || !entry.payload.text) continue;
    const laneKey = entryLaneKey(entry);
    if (!byLane.has(laneKey)) byLane.set(laneKey, entry);
  }
  return [...byLane.values()];
}

async function pendingHeadForLane(entryId, laneKey) {
  return await withDirLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const head = queue.find((entry) => !entry.terminalDisposition && entryLaneKey(entry) === laneKey) || null;
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
  withAllWakeCapacity,
  withWakeExecutionLane,
  readPendingAtPath,
  readPendingUnlocked,
  appendPending,
  removePending,
  isTerminalWakeFailure,
  deadLetterPendingEntry,
  bumpPendingAttempt,
  checkpointPendingAdmission,
  entryLaneKey,
  firstPendingPerLane,
  pendingHeadForLane,
  markPendingStaleRecovery
};
}

module.exports = { createCodexQueueAdmission };
