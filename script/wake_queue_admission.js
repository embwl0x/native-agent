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
  deadLetterPath,
  isCodexNonThreadSentinel,
  markInboxTerminal,
  nowISO,
  pendingPath,
  queueLockDir,
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
const { dataRootLife, lifeOf, readWakeJSON, withWakeLock } = require("./wake_worker_common.js");
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
  // attempted, and the kernel lock remains the cross-process authority.
  const seed = Number.parseInt(
    crypto.createHash("sha256").update(String(laneKey)).digest("hex").slice(0, 8),
    16
  );
  let lastBusy = null;
  for (let offset = 0; offset < cap; offset += 1) {
    const index = (seed + offset) % cap;
    const slotDir = path.join(capacityRoot, `slot-${index}.lock`);
    try {
      return await withWakeLock(slotDir,
        () => heldCapacitySlot.run(slotDir, fn), {
        waitMs: 0,
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
    return await withWakeLock(slotDir, () => acquire(index + 1),
      { waitMs: 0 });
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
    return await withWakeLock(lockDir, async () => withWakeCapacity(
      laneKey,
      config,
      fn,
      options
    ), {
      waitMs: options.laneWaitMs == null ? 0 : options.laneWaitMs,
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
  const parsed = readWakeJSON(pendingPath, []);
  if (!Array.isArray(parsed)) throw new Error(`pending_queue_not_array: ${pendingPath}`);
  const ids = new Set();
  const keys = new Set();
  for (const [index, row] of parsed.entries()) {
    const source = `${pendingPath}[${index}]`;
    const nonempty = (value) => typeof value === "string" && value.trim().length > 0;
    const object = (value) => value != null && typeof value === "object" && !Array.isArray(value);
    if (!row || typeof row !== "object" || Array.isArray(row)
        || !nonempty(row.id) || !nonempty(row.key) || !nonempty(row.laneKey)
        || ![FRESH_THREAD_MODE, PINNED_THREAD_MODE].includes(row.mode)
        || (row.mode === PINNED_THREAD_MODE && !canonicalCodexThreadId(row.threadId))
        || (row.mode === FRESH_THREAD_MODE && row.threadId !== null)
        || !nonempty(row.addedAt) || !Number.isFinite(Date.parse(row.addedAt))
        || !Number.isInteger(row.attempts) || row.attempts < 0
        || !row.payload || typeof row.payload !== "object" || Array.isArray(row.payload)
        || !nonempty(row.payload.messageId) || !nonempty(row.payload.text)
        || (row.terminalDisposition !== undefined && (!object(row.terminalDisposition)
          || !nonempty(row.terminalDisposition.deadLetteredAt) || !Number.isFinite(Date.parse(row.terminalDisposition.deadLetteredAt))
          || !nonempty(row.terminalDisposition.reason)))
        || (row.freshAdmission !== undefined && (!object(row.freshAdmission)
          || !nonempty(row.freshAdmission.threadId) || !nonempty(row.freshAdmission.clientUserMessageId)
          || !nonempty(row.freshAdmission.jobPath)
          || (row.freshAdmission.turnId !== undefined && !nonempty(row.freshAdmission.turnId))))
        || Object.keys(row).some((key) => ![
          "lifeID", "id", "key", "threadId", "mode", "laneKey", "payload", "addedAt", "attempts", "launch",
          "terminalDisposition", "lastAttemptAt", "lastError", "freshAdmission", "staleRecoveryCount", "requeuedAt", "staleRecovery",
        ].includes(key))
        || ids.has(row.id) || keys.has(row.key)) {
      throw new Error(`Pending wake schema unavailable at ${source}; retained source was not rewritten.`);
    }
    lifeOf(row.lifeID, source);
    ids.add(row.id); keys.add(row.key);
  }
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
  return await withWakeLock(queueLockDir(), async () => {
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
      lifeID: dataRootLife(),
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
  return await withWakeLock(queueLockDir(), async () => {
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
  // Checkpoint terminal state before either projection. If storage is
  // unavailable, retain the brief without letting it execute again.
  const terminalEntry = await withWakeLock(queueLockDir(), async () => {
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
    await withWakeLock(`${path}.append.lock`, async () => {
      appendJSONLineAtomicUnlocked(path, {
        deadLetteredAt,
        reason: terminalReason,
        lastError,
        entry: terminalEntry,
      });
    }, { waitMs: 5000 });
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
  return await withWakeLock(queueLockDir(), async () => {
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
  return await withWakeLock(queueLockDir(), async () => {
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
  if (!entry || typeof entry.laneKey !== "string" || !entry.laneKey) throw new Error("Pending wake lane identity unavailable");
  return entry.laneKey;
}

function firstPendingPerLane(queue) {
  const byLane = new Map();
  for (const entry of queue) {
    if (entry.terminalDisposition) continue;
    const laneKey = entryLaneKey(entry);
    if (!byLane.has(laneKey)) byLane.set(laneKey, entry);
  }
  return [...byLane.values()];
}

async function pendingHeadForLane(entryId, laneKey) {
  return await withWakeLock(queueLockDir(), async () => {
    const queue = readPendingUnlocked();
    const head = queue.find((entry) => !entry.terminalDisposition && entryLaneKey(entry) === laneKey) || null;
    return {
      isHead: Boolean(head && head.id === entryId),
      head,
      pendingCount: queue.length,
    };
  }, { waitMs: 2000 });
}

async function markPendingStaleRecovery(entry, recovery) {
  return await withWakeLock(queueLockDir(), async () => {
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
  }, { waitMs: 2000 });
}

return {
  sanitizePayload,
  withWakeLock,
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
