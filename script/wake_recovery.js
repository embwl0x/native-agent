"use strict";

// Lane-specific recovery; entrypoints supply runtime policy and effects.

function createCodexRecovery({
  PINNED_THREAD_MODE,
  REPLY_DELIVERIES_PATH,
  REPLY_JOBS_DIR,
  REPLY_RECOVERY_LOCK_DIR,
  appendHangWatchdogReceipt,
  appendPending,
  appendStaleWakeRecoveryReceipt,
  boolSetting,
  deadLetterPath,
  deliverReplyJob,
  dirLockOwnerAlive,
  entryLaneKey,
  markInboxConsumed,
  markInboxTerminal,
  markPendingStaleRecovery,
  messageIdForPayload,
  nonnegativeIntegerSetting,
  numberSetting,
  pidAlive,
  probeTurnLiveness,
  processStartIdentity,
  readWakeJSONLines,
  redactDiagnosticText,
  removeStaleSocket,
  sleep,
  socketOwnerPid,
  startDaemon,
  startDrainProcess,
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
  if (!boolSetting(config, "hangAutoRecover", "NATIVE_AGENT_CODEX_HANG_AUTORECOVER", true)) {
    return { status: "disabled", retryCount };
  }
  const maxRetries = nonnegativeIntegerSetting(
    config,
    "hangMaxRetries",
    "NATIVE_AGENT_CODEX_HANG_MAX_RETRIES",
    1
  );
  const turnId = execution.turnId || job.turnId;
  const nowFn = options.now || Date.now;
  const writeReceipt = options.appendReceipt || appendHangWatchdogReceipt;
  const receipts = [];
  async function record(result) {
    const receipt = {
      turnId,
      action: result.action,
      pidKilled: result.pidKilled ?? null,
      retryCount: result.retryCount ?? retryCount,
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
  const killed = await record(await terminateKnownHungAppServer(job, processOperations));
  const lock = await record(clearStaleWakeLaneLock(
    laneKey,
    options.laneLockDir || null,
    {
      dirLockOwnerAlive: options.dirLockOwnerAlive,
    }
  ));
  const respawn = await record(respawnAppServerAfterHang(processOperations));

  if (retryCount >= maxRetries) {
    await record({ action: "hang_retry_cap_reached", pidKilled: null });
    return { status: "permanent_failed_hung", retryCount, maxRetries, killed, lock, respawn, receipts };
  }

  const append = options.appendPending || appendPending;
  const nextRetryCount = retryCount + 1;
  const queued = [];
  try {
    for (const entry of Array.isArray(job.entries) ? job.entries : []) {
      queued.push(await append(entry.payload || {}, job.threadId, {
        hangRetryCount: nextRetryCount,
        hungTurnId: turnId,
      }));
    }
    if (queued.length === 0) throw new Error("hang_retry_entries_missing");
  } catch (error) {
    await record({ action: "hang_retry_requeue_failed", pidKilled: null });
    return {
      status: "permanent_failed_hung",
      retryCount,
      maxRetries,
      killed,
      lock,
      respawn,
      receipts,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
    };
  }
  const drain = (options.startDrainProcess || startDrainProcess)(config);
  await record({ action: "hung_wake_job_requeued", pidKilled: null, retryCount: nextRetryCount });
  return {
    status: "requeued",
    retryCount: nextRetryCount,
    maxRetries,
    killed,
    lock,
    respawn,
    queued,
    drain,
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

function createClaudeRecovery({
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
}) {
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

/// Replay ONLY the bridge delivery for a job that already holds a completed
/// reply the agent never received. Deliberately does not re-run claude: the answer
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

function markSessionStoreDelivered(jobPath, check) {
  updateJob(jobPath, {
    bridgeStatus: "delivered",
    bridgeReason: "confirmed_by_session_store",
    deliveryLost: false,
    completionText: null,
    sessionStoreCheck: check,
    unknownSettledAt: nowISO(),
  });
}

async function replayLostDeliveryLocked(jobPath, job) {
  const messageId = job.messageId || (job.payload && job.payload.messageId) || null;
  // 2026-09-06: jobs written before the rename carry `agentSessionId`; the
  // live bridge still holds them, and a settled job must stay matchable.
  const sessionId = job.agentSessionId || job.agentSessionId || (job.payload && job.payload.sessionId) || null;
  const missingOrigin = missingCompletionOrigin(sessionId);
  if (missingOrigin) {
    updateJob(jobPath, { bridgeStatus: "blocked", bridgeReason: missingOrigin.reason, deliveryLost: false });
    return { status: "blocked", reason: missingOrigin.reason, delivery: "claude_thread_wakeup",
      messageId, jobPath, bridge: missingOrigin, deliveryLost: false, note: missingOrigin.note };
  }
  const settleDelivered = (check) => {
    markSessionStoreDelivered(jobPath, check);
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
  if (confirmDeliveryViaSessionStore(sessionId, messageId, job.completionText) === "present") {
    return settleDelivered("present");
  }

  // Persist uncertainty before the effect: a crash during POST must reconcile
  // this attempt through the settle grace instead of replaying immediately.
  const attempting = updateJob(jobPath, {
    bridgeStatus: "unknown",
    bridgeReason: "replay_in_flight",
    deliveryLost: false,
    lastBridgeAttemptAt: nowISO(),
  });
  if (!attempting) {
    return { status: "failed", reason: "replay_checkpoint_failed",
      delivery: "claude_thread_wakeup", messageId, jobPath, deliveryLost: true };
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
      const check = confirmDeliveryViaSessionStore(sessionId, messageId, job.completionText);
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
    updateJob(jobPath, {
      bridgeStatus: bridge.status,
      bridgeReason: bridge.reason || null,
      deliveryLost: true,
    });
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
  // 2026-09-06: jobs written before the rename carry `agentSessionId`; the
  // live bridge still holds them, and a settled job must stay matchable.
  const sessionId = job.agentSessionId || job.agentSessionId || (job.payload && job.payload.sessionId) || null;
  const check = confirmDeliveryViaSessionStore(sessionId, messageId, job.completionText);
  const base = {
    delivery: "claude_thread_wakeup",
    messageId,
    jobPath,
    sessionStoreCheck: check,
    deliveryLost: false,
  };
  if (check === "present") {
    markSessionStoreDelivered(jobPath, check);
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

/// Recover only proven-unsent failures and missing-origin completions.
/// Unknown delivery may already have landed; suppressed delivery is deliberate.
function terminalUndelivered(job) {
  if (!job || job.state !== "settled") return false;
  // Recovery requires the retained reply itself, not just a delivery status.
  if (typeof job.completionText !== "string" || !job.completionText.trim()) return false;
  // Durable once-only marker. A job is swept AT MOST ONCE, ever.
  if (job.deliveryRecoveryAt) return false;
  if (job.bridgeReason === "missing_origin_session") return true;
  return job.bridgeStatus === "failed";
}

async function recoverTerminalUndelivered(jobPath, job) {
  const messageId = job.messageId || (job.payload && job.payload.messageId) || null;
  // 2026-09-06: jobs written before the rename carry `agentSessionId`; the
  // live bridge still holds them, and a settled job must stay matchable.
  const sessionId = job.agentSessionId || job.agentSessionId || (job.payload && job.payload.sessionId) || null;
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    // No origin to post INTO. Deliberately does NOT arm deliveryLost: that
    // would flip the record out of the `blocked` outcome class the existing
    // delegation-outcome card already reports it under, and the card is the
    // whole point of this branch. Stamp the once-only marker and say, on the
    // record, that the reply exists and where — the card renders the retained
    // completion head alongside the job id.
    const marked = updateJob(jobPath, {
      deliveryRecoveryAt: nowISO(),
      deliveryRecoveryOutcome: "carded_origin_unresolvable",
      deliveryRecoveryNote:
        `Completed reply is retained on ${jobPath}. No origin session is recorded, `
        + "so it cannot be posted; identify the original conversation and deliver it "
        + "explicitly. Do not rerun the worker.",
    });
    return {
      messageId, jobPath, posted: false,
      status: marked ? "carded" : "failed",
      reason: marked ? "origin_unresolvable" : "recovery_mark_failed",
    };
  }
  // Mark BEFORE posting. At-most-once beats at-least-once here: a crash
  // between the mark and the POST costs one stranded reply that a human can
  // still read straight off the record, while a repeat costs the agent a duplicate
  // completion — the single worst thing this file can produce.
  const armed = updateJob(jobPath, {
    deliveryRecoveryAt: nowISO(),
    deliveryRecoveryOutcome: "reposting",
    // Proven-undelivered IS deliveryLost; legacy records simply never said so.
    deliveryLost: true,
    agentSessionId: sessionId,
  });
  if (!armed) {
    return { messageId, jobPath, posted: false, status: "failed", reason: "recovery_mark_failed" };
  }
  // Reuse the existing replay path wholesale: it owns the per-job replay lock,
  // the under-lock re-read, the final session-store check immediately before
  // the POST, the redelivery receipt, and clearing completionText on success.
  const replay = await replayLostDelivery(jobPath, armed);
  const status = (replay && replay.status) || "unknown";
  updateJob(jobPath, {
    deliveryRecoveryOutcome: status,
    deliveryRecoveryNote: status === "redelivered"
      ? null
      : `Completed reply is retained on ${jobPath}; the recovery post did not confirm delivery.`,
  });
  return {
    messageId, jobPath,
    status,
    reason: (replay && replay.reason) || null,
    posted: status === "redelivered",
    replay,
  };
}

/// One bounded pass over the job store. Runs on the TAIL of a real wake (and
/// via `--recover`), never on the latency-bound foreground helper path.
async function sweepTerminalUndelivered(limit) {
  const max = limit == null
    ? envNumber("NATIVE_AGENT_CLAUDE_WAKE_RECOVERY_MAX", DEFAULT_RECOVERY_MAX_PER_PASS)
    : limit;
  const empty = { scanned: 0, eligible: 0, attempted: 0, results: [] };
  if (!(max > 0)) return empty;
  let names;
  try { names = fs.readdirSync(WAKE_JOBS_DIR); } catch { return empty; }
  const candidates = [];
  for (const name of names) {
    // `.stale-<uuid>` takeovers are archived dead runs, never redelivery
    // targets — the extension test excludes them exactly as the rate limiter's
    // scan does.
    if (!name.endsWith(".json")) continue;
    const jobPath = path.join(WAKE_JOBS_DIR, name);
    const job = readJob(jobPath);
    if (!terminalUndelivered(job)) continue;
    candidates.push({ jobPath, job, at: Date.parse(job.completedAt || job.updatedAt || "") || 0 });
  }
  // Oldest first: a backlog drains in the order it stranded.
  candidates.sort((a, b) => a.at - b.at);
  const slice = candidates.slice(0, max);
  const results = [];
  for (const candidate of slice) {
    try {
      results.push(await recoverTerminalUndelivered(candidate.jobPath, candidate.job));
    } catch (error) {
      results.push({
        jobPath: candidate.jobPath,
        messageId: candidate.job.messageId || null,
        status: "failed",
        reason: "recovery_error",
        posted: false,
        error: redactDiagnosticText(String((error && error.message) || error)),
      });
    }
  }
  return { scanned: names.length, eligible: candidates.length, attempted: results.length, results };
}

/// ------------------------------------------------------ wedged-runner re-arm
///
/// A runner is WEDGED when its own advertised deadline has passed by the kill
/// grace plus a margin and the process is somehow still alive — i.e. both of
/// its watchdogs failed to end it.
///
/// The state gate is the whole safety argument. performWake stamps
/// `delivering` on the job file BEFORE the bridge POST, so a job still in a
/// pre-delivery state cannot have delivered anything, and killing it cannot
/// produce a double completion.
function preDeliveryWedge(job) {
  if (!job || !PRE_DELIVERY_STATES.includes(job.state)) return null;
  const deadlineMs = Date.parse((job && job.deadlineAt) || "");
  if (!Number.isFinite(deadlineMs)) return null;
  const marginMs = envNumber("NATIVE_AGENT_CLAUDE_WAKE_WEDGED_MARGIN_MS", WEDGED_RUNNER_MARGIN_MS);
  const overdueMs = Date.now() - (deadlineMs + KILL_GRACE_MS + marginMs);
  if (overdueMs <= 0) return null;
  return { deadlineAt: job.deadlineAt, overdueMs: Math.round(overdueMs), state: job.state };
}

/// SIGTERM the whole recorded runner tree, then SIGKILL after the same grace
/// the in-run watchdogs use. Death is PROVEN by polling the recorded roots,
/// never assumed: a survivor aborts the entire re-arm.
async function terminateWedgedRunner(job) {
  const roots = [Number(job && job.runnerPid), Number(job && job.pid)]
    .filter((pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid);
  const targets = new Set();
  for (const root of roots) {
    if (!pidAlive(root)) continue;
    // Snapshot descendants BEFORE signalling: after SIGTERM the root is gone
    // and its orphaned children are no longer reachable from it.
    for (const pid of processTreePids(root)) targets.add(pid);
    targets.add(root);
  }
  targets.delete(process.pid);
  const signalledPids = [...targets];
  for (const pid of signalledPids) { try { process.kill(pid, "SIGTERM"); } catch {} }
  await sleep(KILL_GRACE_MS);
  for (const pid of signalledPids) {
    if (pidAlive(pid)) { try { process.kill(pid, "SIGKILL"); } catch {} }
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && roots.some((pid) => pidAlive(pid))) await sleep(100);
  return { terminated: !roots.some((pid) => pidAlive(pid)), signalledPids, roots };
}

function knownUnstartedWake(job) {
  const rejectedBeforeExecution = job && job.schemaVersion === 2
    && job.state === "settled" && job.status === "failed" && job.reason === "rejected_topic_busy";
  return job && job.schemaVersion >= 2
    && typeof job.claimId === "string" && job.claimId
    && (["claimed", "queued", "spawn_failed"].includes(job.state) || rejectedBeforeExecution)
    && !job.startedAt && !job.attemptSessionId && !job.progressAt
    && (job.attempts == null || (Array.isArray(job.attempts) && job.attempts.length === 0))
    && job.payload && job.payload.messageId === job.messageId
    && typeof job.payload.text === "string" && job.payload.text.trim();
}

/// A duplicate may recover proven-unstarted work or reconcile delivery, never
/// infer no effects from a dead process, old heartbeat, or unreadable record.
async function resolveExistingJob(jobPath, payload, makeClaimRecord) {
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
    return { action: "duplicate", job: null, note: "execution_outcome_unknown" };
  }
  if (job.messageId !== payload.messageId) {
    // The old sanitizer cut UTF-16 units, unlike the Swift producer's graphemes.
    // Both IDs share the existing 120-unit filename: never adopt/replay a legacy
    // claim, since distinct accepted IDs may have collapsed into that old ID.
    const legacyId = payload.messageId.slice(0, 160);
    return { action: "duplicate", job, note: legacyId !== payload.messageId && job.messageId === legacyId
      ? "legacy_message_id_ambiguous" : "message_id_conflict" };
  }
  if (job.state === "settled" && job.bridgeReason === "missing_origin_session") {
    return { action: "duplicate", job, note: "missing_origin_session" };
  }

  // A current-schema topic-busy rejection never admitted Claude execution.
  // An explicit resend may recover it through the same dead-owner/CAS path;
  // its original rejection and delivery receipt remain in the archived job.
  if (job.state === "settled" && !knownUnstartedWake(job)) {
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

  const ownerPid = Number(job.pid);
  const runnerPid = Number(job.runnerPid);
  const hasRunnerPid = Number.isInteger(runnerPid) && runnerPid > 0;
  const ageMs = jobHeartbeatAgeMs(job);
  const staleMs = staleThresholdMs(job);

  // Takeover requires that EVERY recorded owner pid be provably dead. A stale
  // heartbeat is NOT sufficient on its own: renaming a live runner's job aside
  // lets two processes run the same wake and post two completions to the agent.
  // The tradeoff is deliberate — a wedged-but-alive runner blocks retries of
  // that messageId until it dies. Safety over availability; a stuck wake costs
  // one message, a double wake costs the agent's trust in the receipt stream.
  if (pidAlive(ownerPid) || (hasRunnerPid && pidAlive(runnerPid))) {
    // The tradeoff above stands, with exactly ONE exception: a runner past its
    // own advertised deadline whose watchdogs demonstrably failed to end it.
    // That process is not doing work anybody is waiting on — it is a corpse
    // holding a messageId hostage — so it is terminated here and the wake is
    // re-armed once. Everything that makes this safe is checked below and
    // AFTER the kill, never inferred.
    const wedge = preDeliveryWedge(job);
    if (wedge) {
      const rearmLimit = envNumber("NATIVE_AGENT_CLAUDE_WAKE_MAX_REARMS", DEFAULT_MAX_AUTO_REARMS);
      const priorRearms = Number(job.autoRearms) || 0;
      const kill = await terminateWedgedRunner(job);
      const fresh = readJob(jobPath);
      if (!kill.terminated || !fresh) {
        // Could not prove it dead. Two runners on one wake is strictly worse
        // than one stuck wake; defer exactly as before.
        return { action: "duplicate", job, note: "wedged_runner_survived", ageMs, staleMs, ownerPid };
      }
      // Re-read AFTER the process is provably dead. This closes the only
      // window that mattered: `delivering` is written durably BEFORE the POST,
      // so a runner that posted while we were killing it is visible here.
      if (!preDeliveryWedge(fresh)) {
        return { action: "duplicate", job: fresh, note: "wedged_runner_delivered", ageMs, staleMs, ownerPid };
      }
      if (priorRearms >= rearmLimit) {
        // Budget spent. Settle it as a failure naming the reason so the
        // delegation-outcome card fires, instead of leaving the record parked
        // in `running` behind a pid that no longer exists.
        updateJob(jobPath, {
          state: "settled",
          status: "failed",
          reason: `wedged_runner_terminated_after_${priorRearms}_rearm${priorRearms === 1 ? "" : "s"}`,
          bridgeStatus: "suppressed",
          bridgeReason: "wedged_runner_terminated_no_completion",
          completedAt: nowISO(),
          deliveryLost: false,
          wedgedTerminatedAt: nowISO(),
          wedgedOverdueMs: wedge.overdueMs,
          wedgedSignalledPids: kill.signalledPids,
        });
        return { action: "duplicate", job: readJob(jobPath), note: "wedged_runner_rearm_exhausted", ageMs, ownerPid };
      }
      // Same serialization the unstarted-recovery path uses. The dead runner's
      // topic lock is reclaimed by acquireTopicLock's own dead-owner check.
      const wedgeLock = await acquireTopicLock(
        topicSlug((fresh.payload || job.payload || {}).topic), 0,
        { messageId: payload.messageId, recoveryOnly: true }
      );
      if (!wedgeLock.acquired) return { action: "duplicate", job: fresh, note: "recovery_in_progress" };
      try {
        const current = readJob(jobPath);
        if (!current || current.claimId !== fresh.claimId || !preDeliveryWedge(current)
            || pidAlive(current.pid) || (current.runnerPid && pidAlive(current.runnerPid))) {
          return { action: "duplicate", job: current, note: "claim_changed" };
        }
        const replacement = makeClaimRecord(current.payload || payload);
        replacement.autoRearms = priorRearms + 1;
        replacement.autoRearmAt = nowISO();
        replacement.autoRearmReason = `wedged_runner_terminated_overdue_${wedge.overdueMs}ms`;
        const stalePath = renameJobAside(jobPath);
        if (!stalePath || !claimJob(jobPath, replacement)) {
          return { action: "duplicate", job: readJob(jobPath), note: "claim_changed" };
        }
        return {
          action: "reclaimed", stalePath, reason: "wedged_runner_terminated",
          ownerPid, ageMs, claimId: replacement.claimId, payload: replacement.payload,
          wedge, terminatedPids: kill.signalledPids,
        };
      } finally { wedgeLock.release(); }
    }
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
  if (!hasRunnerPid && !knownUnstartedWake(job)) {
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

  if (!knownUnstartedWake(job) || !Number.isInteger(ownerPid) || ownerPid <= 0) {
    return { action: "duplicate", job, note: "execution_outcome_unknown", ownerPid, ageMs };
  }
  // Serialize the read/rename/reclaim under the EXISTING conversation lock.
  // A second retry must re-read our new claim rather than rename it using a
  // stale snapshot of the dead predecessor. Never wait behind active work.
  const lock = await acquireTopicLock(topicSlug(job.payload.topic), 0, { messageId: payload.messageId, recoveryOnly: true });
  if (!lock.acquired) return { action: "duplicate", job, note: "recovery_in_progress" };
  try {
    const fresh = readJob(jobPath);
    if (!fresh || fresh.claimId !== job.claimId || !knownUnstartedWake(fresh)
        || pidAlive(fresh.pid) || (fresh.runnerPid && pidAlive(fresh.runnerPid))) {
      return { action: "duplicate", job: fresh, note: "claim_changed" };
    }
    const replacement = makeClaimRecord(fresh.payload);
    const stalePath = renameJobAside(jobPath);
    if (!stalePath || !claimJob(jobPath, replacement)) {
      return { action: "duplicate", job: readJob(jobPath), note: "claim_changed" };
    }
    return { action: "reclaimed", stalePath, reason: "unstarted_owner_dead", ownerPid, ageMs, claimId: replacement.claimId, payload: fresh.payload };
  } finally { lock.release(); }
}

return {
  replayLostDelivery,
  settleUnknownDelivery,
  terminalUndelivered,
  sweepTerminalUndelivered,
  preDeliveryWedge,
  resolveExistingJob
};
}

module.exports = { createCodexRecovery, createClaudeRecovery };
