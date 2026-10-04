"use strict";

// Lane-specific recovery; entrypoints supply runtime policy and effects.

function createCodexRecovery({
  DEFAULT_WAKE_CONCURRENCY,
  WAKE_CAPACITY_DIR,
  PINNED_THREAD_MODE,
  REPLY_DELIVERIES_PATH,
  REPLY_JOBS_DIR,
  REPLY_RECOVERY_LOCK_DIR,
  appendHangWatchdogReceipt,
  appendStaleWakeRecoveryReceipt,
  boolSetting,
  connectRpcOnce,
  deadLetterPath,
  deliverReplyJob,
  dirLockOwnerAlive,
  entryLaneKey,
  isUnhealthyThreadState,
  markInboxConsumed,
  markInboxTerminal,
  markPendingStaleRecovery,
  messageIdForPayload,
  numberSetting,
  pidAlive,
  probeTurnLiveness,
  readCanonicalTurnResult,
  processStartIdentity,
  readWakeJSONLines,
  redactDiagnosticText,
  removeStaleSocket,
  sleep,
  socketOwnerPid,
  startDaemon,
  threadStateFromThread,
  unicodePrefix,
  wakeLaneKey,
  wakeLaneLockPath,
  withDirLock
}) {
const fs = require("fs");
const path = require("path");

async function waitForPIDExit(pid, timeoutMs, operations) {
  const deadline = operations.now() + Math.max(0, timeoutMs);
  do {
    if (!operations.pidAlive(pid)) return true;
    if (operations.now() >= deadline) break;
    await operations.sleep(Math.min(100, Math.max(1, deadline - operations.now())));
  } while (operations.now() <= deadline);
  return !operations.pidAlive(pid);
}

async function terminateKnownHungAppServer(job, operations = {}) {
  const known = job && job.appServer;
  const pid = Number(known && known.pid);
  if (!Number.isInteger(pid) || pid <= 1) {
    return { action: "app_server_kill_skipped_no_known_pid", pidKilled: null };
  }
  const ownerPID = (operations.socketOwnerPid || socketOwnerPid)();
  if (ownerPID !== pid) {
    return { action: "app_server_kill_skipped_owner_mismatch", pidKilled: null };
  }
  const identity = operations.processStartIdentity || processStartIdentity;
  if (known.startIdentity && identity(pid) !== known.startIdentity) {
    return { action: "app_server_kill_skipped_identity_mismatch", pidKilled: null };
  }
  const ops = {
    now: operations.now || Date.now,
    sleep: operations.sleep || sleep,
    pidAlive: operations.pidAlive || pidAlive,
  };
  const signal = operations.kill || ((target, name) => process.kill(target, name));
  try {
    signal(pid, "SIGTERM");
  } catch (error) {
    return {
      action: "app_server_kill_failed",
      pidKilled: null,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
    };
  }
  if (await waitForPIDExit(pid, operations.termWaitMs ?? 3000, ops)) {
    return { action: "app_server_killed", pidKilled: pid };
  }
  try {
    signal(pid, "SIGKILL");
  } catch (error) {
    return {
      action: "app_server_kill_failed",
      pidKilled: null,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
    };
  }
  if (await waitForPIDExit(pid, operations.killWaitMs ?? 2000, ops)) {
    return { action: "app_server_killed", pidKilled: pid };
  }
  return { action: "app_server_kill_failed_still_alive", pidKilled: null };
}

async function recoverExactHungTurn(job, threadId, turnId, operations = {}) {
  let client;
  const connect = operations.connectRpcOnce || connectRpcOnce;
  try {
    client = await connect(12000);
    try {
      await client.request("turn/interrupt", { threadId, turnId });
      return { action: "hung_turn_interrupted", pidKilled: null };
    } catch {}

    // Hold every admission slot while checking the shared server, so another
    // wake cannot start between the inventory and termination.
    const capacityRoot = operations.capacityRoot || WAKE_CAPACITY_DIR;
    fs.mkdirSync(capacityRoot, { recursive: true, mode: 0o700 });
    async function withAllSlots(index, fn) {
      if (index === DEFAULT_WAKE_CONCURRENCY) return await fn();
      return await withDirLock(path.join(capacityRoot, `slot-${index}.lock`),
        async () => withAllSlots(index + 1, fn),
        { waitMs: 0, preserveLiveOwner: true });
    }
    return await withAllSlots(0, async () => {
      const loaded = await client.request("thread/loaded/list", {});
      if (!loaded || !Array.isArray(loaded.data) || loaded.nextCursor) {
        return { action: "app_server_kill_skipped_unverified_lanes", pidKilled: null };
      }
      for (const id of loaded.data) {
        const read = await client.request("thread/read", { threadId: id, includeTurns: true });
        if (!read || !read.thread || read.thread.id !== id) {
          return { action: "app_server_kill_skipped_unverified_lanes", pidKilled: null };
        }
        const state = threadStateFromThread(read.thread, id);
        const otherActiveTurn = state.inProgressTurnIds.some((active) => id !== threadId || active !== turnId);
        if (isUnhealthyThreadState(state) || !["idle", "active"].includes(state.statusType)
            || otherActiveTurn || (state.active && (id !== threadId || state.inProgressTurnIds.length === 0))) {
          return { action: "app_server_kill_skipped_other_active_lane", pidKilled: null };
        }
      }
      const confirmed = await client.request("thread/loaded/list", {});
      if (!confirmed || !Array.isArray(confirmed.data) || confirmed.nextCursor
          || JSON.stringify([...confirmed.data].sort()) !== JSON.stringify([...loaded.data].sort())) {
        return { action: "app_server_kill_skipped_unverified_lanes", pidKilled: null };
      }
      return await terminateKnownHungAppServer(job, operations);
    });
  } catch (error) {
    return { action: error && error.message === "lock_busy"
      ? "app_server_kill_skipped_active_admission" : "app_server_kill_skipped_unverified_lanes", pidKilled: null };
  } finally {
    if (client) client.close();
  }
}

function clearStaleWakeLaneLock(laneKey, lockDir = null, operations = {}) {
  const resolvedLockDir = lockDir || wakeLaneLockPath(laneKey);
  if (!fs.existsSync(resolvedLockDir)) {
    return {
      action: "wake_lane_lock_absent",
      laneKey,
      lockDir: resolvedLockDir,
      pidKilled: null,
    };
  }
  const ownerAlive = operations.dirLockOwnerAlive || dirLockOwnerAlive;
  if (ownerAlive(resolvedLockDir)) {
    return {
      action: "wake_lane_lock_preserved_live_owner",
      laneKey,
      lockDir: resolvedLockDir,
      pidKilled: null,
    };
  }
  try {
    fs.rmSync(resolvedLockDir, { recursive: true, force: true });
    return {
      action: "stale_wake_lane_lock_cleared",
      laneKey,
      lockDir: resolvedLockDir,
      pidKilled: null,
    };
  } catch (error) {
    return {
      action: "stale_wake_lane_lock_clear_failed",
      laneKey,
      lockDir: resolvedLockDir,
      pidKilled: null,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
    };
  }
}

function respawnAppServerAfterHang(operations = {}) {
  const owner = operations.socketOwnerPid || socketOwnerPid;
  const existingPID = owner();
  if (existingPID != null) {
    return { action: "app_server_respawn_skipped_live_owner", pidKilled: null };
  }
  (operations.removeStaleSocket || removeStaleSocket)();
  (operations.startDaemon || startDaemon)();
  const restartedPID = owner();
  return {
    action: restartedPID == null ? "app_server_respawn_failed" : "app_server_respawned",
    pidKilled: null,
  };
}

async function recoverHungTurn(job, execution, config, options = {}) {
  if (!execution || !execution.turnResult || execution.turnResult.status !== "failed_hung") {
    return { status: "not_hung", retryCount: Number(job && job.hangRetryCount || 0) };
  }
  const retryCount = Math.max(0, Number(job && job.hangRetryCount || 0));
  const turnId = execution.turnId || job.turnId;
  const threadId = execution.threadId || job.threadId;
  const reconcile = options.readCanonicalTurnResult || readCanonicalTurnResult;
  const terminal = await reconcile(null, threadId, turnId, config);
  if (terminal) return { status: "reconciled_terminal", retryCount, turnResult: terminal };
  if (!boolSetting(config, "hangAutoRecover", "NATIVE_AGENT_CODEX_HANG_AUTORECOVER", true)) {
    return { status: "disabled", retryCount };
  }
  const nowFn = options.now || Date.now;
  const writeReceipt = options.appendReceipt || appendHangWatchdogReceipt;
  const receipts = [];
  async function record(result) {
    const receipt = {
      turnId,
      action: result.action,
      pidKilled: result.pidKilled ?? null,
      retryCount: result.retryCount ?? retryCount,
      toolActivityCount: execution.turnResult.toolActivityCount ?? null,
      noWorkObserved: execution.turnResult.noWorkObserved ?? null,
      timestamp: new Date(nowFn()).toISOString(),
    };
    if (result.laneKey) receipt.laneKey = result.laneKey;
    if (result.lockDir) receipt.lockDir = result.lockDir;
    await writeReceipt(receipt, config);
    receipts.push(receipt);
    return result;
  }

  const processOperations = options.processOperations || {};
  const laneKey = wakeLaneKey({}, job && job.threadId, PINNED_THREAD_MODE);
  const killed = await record(await recoverExactHungTurn(job, threadId, turnId, processOperations));
  const lock = await record(clearStaleWakeLaneLock(
    laneKey,
    options.laneLockDir || null,
    {
      dirLockOwnerAlive: options.dirLockOwnerAlive,
    }
  ));
  // A terminal write can land during shutdown. Preserve it before repairing
  // the process; an activity count never proves which effects completed.
  const settled = await reconcile(null, threadId, turnId, config);
  const respawn = await record(respawnAppServerAfterHang(processOperations));
  if (settled) {
    return { status: "reconciled_terminal", retryCount, turnResult: settled, killed, lock, respawn, receipts };
  }
  await record({ action: "hang_effect_reconciliation_required", pidKilled: null });
  return {
    status: "reconciliation_required",
    retryCount,
    killed,
    lock,
    respawn,
    receipts,
  };
}

async function recoverStaleQueuedWake(entry, state, config, options = {}) {
  const nowFn = options.now || Date.now;
  const staleAgeMs = numberSetting(
    config,
    "staleWakeAgeMs",
    "NATIVE_AGENT_CODEX_STALE_WAKE_AGE_MS",
    15 * 60 * 1000
  );
  const addedAtMs = Date.parse(entry && entry.addedAt || "");
  const ageMs = Number.isFinite(addedAtMs) ? Math.max(0, nowFn() - addedAtMs) : 0;
  if (ageMs < staleAgeMs) {
    return { status: "not_old_enough", ageMs, staleAgeMs, retryAfterMs: staleAgeMs - ageMs };
  }

  const turnIds = [...new Set([
    ...(state && state.inProgressTurnIds || []),
    ...(state && state.staleInProgressTurnIds || []),
  ].filter(Boolean))];
  if (turnIds.length === 0) {
    return { status: "unproven", reason: "owning_turn_unknown", ageMs, staleAgeMs };
  }

  // A recovery proof belongs to this exact durable queue row. If admission
  // later fails for an unrelated reason (for example the app-server restarts),
  // reuse the already-confirmed dead-turn evidence instead of probing and
  // appending another receipt forever. Any newly observed turn still needs its
  // own two-probe proof below.
  const candidatePriorRecovery = entry && entry.staleRecovery;
  const priorRecovery = candidatePriorRecovery
    && candidatePriorRecovery.status === "requeued"
    && candidatePriorRecovery.queueEntryId === entry.id
    && candidatePriorRecovery.laneKey === entryLaneKey(entry)
    && candidatePriorRecovery.originalAddedAt === (entry.addedAt || null)
    && candidatePriorRecovery.messageId === (messageIdForPayload(entry.payload) || null)
    ? candidatePriorRecovery
    : null;
  const previouslyRecoveredTurnIds = new Set(
    priorRecovery && Array.isArray(priorRecovery.deadTurnIds)
      ? priorRecovery.deadTurnIds.filter(Boolean)
      : []
  );
  const unresolvedTurnIds = turnIds.filter((turnId) => !previouslyRecoveredTurnIds.has(turnId));
  if (unresolvedTurnIds.length === 0) {
    return {
      status: "requeued",
      ageMs,
      staleAgeMs,
      ignoredTurnIds: turnIds,
      entry,
      receiptPath: null,
      recovery: priorRecovery,
      reusedRecovery: true,
    };
  }

  const probe = options.probeTurnLiveness || probeTurnLiveness;
  const pause = options.sleep || sleep;
  const confirmDelayMs = numberSetting(
    config,
    "staleWakeProbeConfirmDelayMs",
    "NATIVE_AGENT_CODEX_STALE_WAKE_PROBE_CONFIRM_DELAY_MS",
    5000
  );
  const proofs = [];
  for (const turnId of unresolvedTurnIds) {
    const first = await probe(entry.threadId, turnId, config);
    const firstDead = !first.serverReachable || !first.turnFound;
    if (!firstDead) {
      return {
        status: first.turnClaimsInProgress ? "preserved_live" : "released_terminal",
        ageMs,
        staleAgeMs,
        turnId,
        proof: first,
      };
    }
    await pause(confirmDelayMs);
    const confirm = await probe(entry.threadId, turnId, config);
    const confirmedDead = !confirm.serverReachable || !confirm.turnFound;
    proofs.push({ turnId, first, confirm });
    if (!confirmedDead) {
      return {
        status: confirm.turnClaimsInProgress ? "preserved_live" : "released_terminal",
        ageMs,
        staleAgeMs,
        turnId,
        proof: confirm,
      };
    }
  }

  const recoveredAt = new Date(nowFn()).toISOString();
  const recovery = {
    status: "requeued",
    recoveredAt,
    originalAddedAt: entry.addedAt || null,
    ageMs,
    staleAgeMs,
    laneKey: entryLaneKey(entry),
    queueEntryId: entry.id,
    messageId: messageIdForPayload(entry.payload) || null,
    deadTurnIds: [...new Set([...previouslyRecoveredTurnIds, ...unresolvedTurnIds])],
    proof: [
      ...(priorRecovery && Array.isArray(priorRecovery.proof) ? priorRecovery.proof : []),
      ...proofs,
    ],
  };
  const requeue = options.markPendingStaleRecovery
    ? await options.markPendingStaleRecovery(entry, recovery)
    : await markPendingStaleRecovery(entry, recovery);
  if (!requeue || requeue.status !== "requeued") {
    return { status: "unproven", reason: "queue_identity_changed", ageMs, staleAgeMs, requeue };
  }
  const receiptPath = options.appendReceipt
    ? await options.appendReceipt(recovery, config)
    : await appendStaleWakeRecoveryReceipt(recovery, config);
  return {
    status: "requeued",
    ageMs,
    staleAgeMs,
    ignoredTurnIds: recovery.deadTurnIds,
    entry: requeue.entry,
    receiptPath,
    recovery,
  };
}

async function recoverReplyJobs(config, options = {}) {
  const worker = options.worker || options.spawnJob || ((jobPath) => deliverReplyJob(jobPath, config));
  const concurrency = Math.max(1, Math.min(2, Number(options.concurrency || 2)));
  const jobsDir = options.jobsDir || REPLY_JOBS_DIR;
  const recoveryLockDir = options.recoveryLockDir || REPLY_RECOVERY_LOCK_DIR;
  try {
    return await withDirLock(recoveryLockDir, async () => {
      let jobPaths = [];
      try {
        jobPaths = fs.readdirSync(jobsDir, { withFileTypes: true })
          .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
          .map((entry) => path.join(jobsDir, entry.name))
          .sort();
      } catch (error) {
        if (error && error.code === "ENOENT") {
          return { status: "completed", scanned: 0, started: 0, jobs: [] };
        }
        throw error;
      }
      const jobs = new Array(jobPaths.length);
      let nextIndex = 0;
      const runWorker = async () => {
        while (true) {
          const index = nextIndex;
          nextIndex += 1;
          if (index >= jobPaths.length) return;
          const jobPath = jobPaths[index];
          try {
            jobs[index] = await worker(jobPath);
          } catch (error) {
            jobs[index] = {
              status: "failed",
              reason: "reply_job_recovery_failed",
              jobPath,
              error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
            };
          }
        }
      };
      await Promise.all(
        Array.from({ length: Math.min(concurrency, jobPaths.length) }, () => runWorker())
      );
      return {
        status: "completed",
        scanned: jobPaths.length,
        started: jobs.filter((job) => job && !["failed", "already_running"].includes(job.status)).length,
        jobs,
      };
    }, { waitMs: 0, staleMs: 10 * 60 * 1000 });
  } catch (error) {
    if (error && error.message === "lock_busy") {
      return { status: "already_running", reason: "reply_recovery_lock_busy", lockDir: recoveryLockDir };
    }
    throw error;
  }
}

async function repairConsumedFromDeliveries(config) {
  let raw;
  try {
    raw = fs.readFileSync(REPLY_DELIVERIES_PATH, "utf8");
  } catch (error) {
    return {
      status: "skipped",
      reason: "reply_deliveries_missing",
      deliveriesPath: REPLY_DELIVERIES_PATH,
      error: String(error.message || error),
    };
  }

  let receipts = 0;
  let markedCount = 0;
  const details = [];
  for (const { value: receipt } of readWakeJSONLines(raw)) {
    const bridgeStatus = receipt && receipt.bridge && receipt.bridge.status;
    if (bridgeStatus !== "delivered" && bridgeStatus !== "dry_run") continue;
    const messageIds = Array.isArray(receipt.messageIds) ? receipt.messageIds.filter(Boolean) : [];
    if (messageIds.length === 0) continue;
    receipts += 1;
    const sent = {
      threadId: receipt.threadId || null,
      turnId: receipt.turnId || null,
    };
    const entries = messageIds.map((messageId) => ({
      id: `repair-${messageId}`,
      threadId: receipt.threadId || null,
      payload: {
        messageId,
        source: "codex_message",
      },
    }));
    const result = await markInboxConsumed(entries, sent);
    markedCount += Number(result.markedCount || 0);
    details.push({
      messageIds,
      result,
    });
  }
  return {
    status: "completed",
    delivery: "reply_deliveries_to_inbox_read_flags",
    deliveriesPath: REPLY_DELIVERIES_PATH,
    receipts,
    markedCount,
    details,
  };
}

/// Reconcile historical dead-letter receipts onto their original inbox rows.
/// This is metadata-only recovery: the brief stays unread and recoverable, but
/// no longer masquerades as a live queue item that nobody has consumed.
async function repairTerminalFromDeadLetters(options = {}) {
  const path = options.path || deadLetterPath();
  let raw;
  try {
    raw = fs.readFileSync(path, "utf8");
  } catch (error) {
    return {
      status: "skipped",
      reason: "dead_letters_missing",
      deadLetterPath: path,
      error: String(error.message || error),
    };
  }

  const byMessageId = new Map();
  let malformed = 0;
  for (const { value: receipt } of readWakeJSONLines(raw, () => { malformed += 1; })) {
    const original = receipt && receipt.entry;
    const payload = original && original.payload || {};
    const messageId = messageIdForPayload(payload);
    if (!messageId) continue;
    byMessageId.set(messageId, {
      ...(original || {}),
      payload: { ...payload, messageId },
      terminalDisposition: {
        deadLetteredAt: receipt.deadLetteredAt || null,
        reason: receipt.reason || "terminal_failure",
      },
    });
  }
  const entries = [...byMessageId.values()];
  if (entries.length === 0) {
    return {
      status: malformed > 0 ? "partial" : "completed",
      deadLetterPath: path,
      receipts: 0,
      malformed,
      markedCount: 0,
    };
  }
  const projection = await (options.markInboxTerminal || markInboxTerminal)(entries);
  return {
    status: projection.status === "failed" ? "failed"
      : (malformed > 0 || projection.status === "partial" ? "partial" : "completed"),
    deadLetterPath: path,
    receipts: entries.length,
    malformed,
    markedCount: Number(projection.markedCount || 0),
    projection,
  };
}

return {
  recoverHungTurn,
  recoverStaleQueuedWake,
  recoverReplyJobs,
  repairConsumedFromDeliveries,
  repairTerminalFromDeadLetters
};
}

module.exports = { createCodexRecovery };
