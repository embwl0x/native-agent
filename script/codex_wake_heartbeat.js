"use strict";

// The worker supplies durable paths, configuration and IO; each instance owns its timer.
function createCodexWakeHeartbeat({
  DRAINER_HEARTBEAT_PATH,
  stringSetting,
  numberSetting,
  pidAlive,
  withDirLock,
  readJSONLines,
  appendJSONLineAtomicUnlocked,
}) {
function latestDrainerHeartbeat(file) {
  const records = readJSONLines(file);
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const row = records[index];
    if (!row || row.action != null) continue;
    if (!Number.isInteger(Number(row.pid)) || Number(row.pid) <= 0 || typeof row.timestamp !== "string") continue;
    return row;
  }
  return null;
}

function createDrainerHeartbeat(config, options = {}) {
  const heartbeatPath = stringSetting(
    config,
    "drainerHeartbeatPath",
    "NATIVE_AGENT_CODEX_DRAINER_HEARTBEAT_PATH",
    DRAINER_HEARTBEAT_PATH
  );
  const intervalMs = numberSetting(
    config,
    "drainerHeartbeatMs",
    "NATIVE_AGENT_CODEX_DRAINER_HEARTBEAT_MS",
    60 * 1000
  );
  const staleMs = numberSetting(
    config,
    "drainerHeartbeatStaleMs",
    "NATIVE_AGENT_CODEX_DRAINER_HEARTBEAT_STALE_MS",
    intervalMs * 3
  );
  const currentPID = Number(options.pid ?? process.pid);
  const nowFn = options.now || Date.now;
  const isPIDAlive = options.pidAlive || pidAlive;
  const setIntervalFn = options.setInterval || setInterval;
  const clearIntervalFn = options.clearInterval || clearInterval;
  const heartbeatLock = `${heartbeatPath}.lock`;
  const withHeartbeatLock = options.withLock || ((body) => withDirLock(
    heartbeatLock,
    body,
    { waitMs: 2000, staleMs: staleMs, preserveLiveOwner: true }
  ));
  let queueDepth = 0;
  let activeTurnId = null;
  let timer = null;
  let writeChain = Promise.resolve();
  let lastWriteError = null;

  function timestamp() {
    return new Date(nowFn()).toISOString();
  }

  function heartbeatRecord() {
    return {
      pid: currentPID,
      timestamp: timestamp(),
      queueDepth,
      activeTurnId,
    };
  }

  async function append(record) {
    await withHeartbeatLock(async () => appendJSONLineAtomicUnlocked(heartbeatPath, record));
  }

  function scheduleHeartbeat() {
    writeChain = writeChain.then(async () => {
      try {
        await append(heartbeatRecord());
        lastWriteError = null;
      } catch (error) {
        lastWriteError = error;
      }
    });
    return writeChain;
  }

  return {
    heartbeatPath,
    intervalMs,
    staleMs,
    update(nextQueueDepth, nextActiveTurnId = null) {
      const depth = Number(nextQueueDepth);
      queueDepth = Number.isInteger(depth) && depth >= 0 ? depth : queueDepth;
      activeTurnId = typeof nextActiveTurnId === "string" && nextActiveTurnId
        ? nextActiveTurnId
        : null;
    },
    async start() {
      const decision = await withHeartbeatLock(async () => {
        const prior = latestDrainerHeartbeat(heartbeatPath);
        if (prior) {
          const priorTimestamp = Date.parse(prior.timestamp);
          const ageMs = Number.isFinite(priorTimestamp) ? Math.max(0, nowFn() - priorTimestamp) : Infinity;
          if (ageMs < staleMs) {
            const priorPID = Number(prior.pid);
            if (isPIDAlive(priorPID)) {
              const receipt = {
                ...heartbeatRecord(),
                action: "live_pid_refusal",
                priorPid: priorPID,
              };
              appendJSONLineAtomicUnlocked(heartbeatPath, receipt);
              return { status: "refused", reason: "live_drainer_heartbeat", prior, receipt };
            }
            appendJSONLineAtomicUnlocked(heartbeatPath, {
              ...heartbeatRecord(),
              action: "dead_pid_takeover",
              priorPid: priorPID,
            });
          }
        }
        const receipt = heartbeatRecord();
        appendJSONLineAtomicUnlocked(heartbeatPath, receipt);
        return { status: "started", prior, receipt };
      });
      if (decision.status === "started") {
        timer = setIntervalFn(() => scheduleHeartbeat(), intervalMs);
        if (timer && typeof timer.unref === "function") timer.unref();
      }
      return { ...decision, heartbeatPath, intervalMs, staleMs };
    },
    pulse: scheduleHeartbeat,
    async stop() {
      if (timer != null) clearIntervalFn(timer);
      timer = null;
      await writeChain;
      return { status: lastWriteError ? "failed" : "stopped", error: lastWriteError || null };
    },
  };
}

  return { createDrainerHeartbeat };
}

module.exports = { createCodexWakeHeartbeat };
