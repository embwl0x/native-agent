"use strict";

// Lane-specific recovery; entrypoints supply runtime policy and effects.

function createCodexRecovery({
  REPLY_DELIVERIES_PATH,
  REPLY_JOBS_DIR,
  REPLY_RECOVERY_LOCK_DIR,
  appendHangWatchdogReceipt,
  appendStaleWakeRecoveryReceipt,
  boolSetting,
  connectRpcOnce,
  deadLetterPath,
  deliverReplyJob,
  entryLaneKey,
  markInboxConsumed,
  markInboxTerminal,
  markPendingStaleRecovery,
  messageIdForPayload,
  numberSetting,
  probeTurnLiveness,
  readCanonicalTurnResult,
  readWakeJSONLines,
  redactDiagnosticText,
  sleep,
  unicodePrefix,
  withWakeLock
}) {
const fs = require("fs");
const path = require("path");

async function recoverExactHungTurn(threadId, turnId, operations = {}) {
  let client;
  try {
    client = await (operations.connectRpcOnce || connectRpcOnce)(12000);
    await client.request("turn/interrupt", { threadId, turnId });
    return { action: "hung_turn_interrupted", executionOutcome: "unknown" };
  } catch (error) {
    return { action: "turn_interrupt_failed", executionOutcome: "unknown",
      error: redactDiagnosticText(String(error.message || error)) };
  } finally { if (client) client.close(); }
}

async function recoverHungTurn(job, execution, config, options = {}) {
  if (!execution || !execution.turnResult || execution.turnResult.status !== "failed_hung") {
    return { status: "not_hung" };
  }
  const turnId = execution.turnId || job.turnId;
  const threadId = execution.threadId || job.threadId;
  const reconcile = options.readCanonicalTurnResult || readCanonicalTurnResult;
  const terminal = await reconcile(null, threadId, turnId, config);
  if (terminal) return { status: "reconciled_terminal", turnResult: terminal };
  if (!boolSetting(config, "hangAutoRecover", "NATIVE_AGENT_CODEX_HANG_AUTORECOVER", true)) {
    return { status: "disabled" };
  }
  const nowFn = options.now || Date.now;
  const writeReceipt = options.appendReceipt || appendHangWatchdogReceipt;
  const receipts = [];
  async function record(result) {
    const receipt = {
      turnId,
      action: result.action,
      executionOutcome: result.executionOutcome || "unknown",
      ...(result.error ? { error: result.error } : {}),
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

  const interruption = await record(await recoverExactHungTurn(threadId, turnId, options.processOperations || {}));
  // An accepted interrupt is not terminal evidence. No process kill, lane
  // unlink or daemon restart can substitute for this exact turn's result.
  const settled = await reconcile(null, threadId, turnId, config);
  if (settled) return { status: "reconciled_terminal", turnResult: settled, interruption, receipts };
  await record({ action: "hang_effect_reconciliation_required" });
  return { status: "reconciliation_required", interruption, receipts };
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
    if (first.availability === "unavailable") return { status: "evidence_unavailable", ageMs, staleAgeMs, turnId, proof: first };
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
    if (confirm.availability === "unavailable") return { status: "evidence_unavailable", ageMs, staleAgeMs, turnId, proof: confirm };
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
  const jobsDir = options.jobsDir || REPLY_JOBS_DIR;
  const recoveryLockDir = options.recoveryLockDir || REPLY_RECOVERY_LOCK_DIR;
  try {
    return await withWakeLock(recoveryLockDir, async () => {
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
      const jobs = await Promise.all(jobPaths.map(async (jobPath) => {
        try { return await worker(jobPath); }
        catch (error) { return { status: "failed", reason: "reply_job_recovery_failed", jobPath,
          error: unicodePrefix(redactDiagnosticText(String(error.message || error)), 500) }; }
      }));
      return {
        status: "completed",
        scanned: jobPaths.length,
        started: jobs.filter((job) => job && !["failed", "already_running"].includes(job.status)).length,
        jobs,
      };
    // The kernel releases this recovery owner on helper exit.
    }, { waitMs: 0 });
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
      status: error.code === "ENOENT" ? "skipped" : "unavailable",
      reason: error.code === "ENOENT" ? "reply_deliveries_missing" : "reply_deliveries_unavailable",
      deliveriesPath: REPLY_DELIVERIES_PATH,
      error: String(error.message || error),
    };
  }

  let receipts = 0;
  let markedCount = 0;
  const details = [];
  for (const { value: receipt } of readWakeJSONLines(raw, null, REPLY_DELIVERIES_PATH)) {
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
      status: error.code === "ENOENT" ? "skipped" : "unavailable",
      reason: error.code === "ENOENT" ? "dead_letters_missing" : "dead_letters_unavailable",
      deadLetterPath: path,
      error: String(error.message || error),
    };
  }

  const byMessageId = new Map();
  let malformed = 0;
  for (const { value: receipt } of readWakeJSONLines(raw, () => { malformed += 1; }, path)) {
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
