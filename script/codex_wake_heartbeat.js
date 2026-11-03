"use strict";

// The worker supplies durable paths, configuration and IO; each instance owns its timer.
function createCodexWakeHeartbeat({
  DRAINER_HEARTBEAT_PATH,
  stringSetting,
  numberSetting,
  withWakeLock,
  appendJSONLineAtomicUnlocked,
}) {
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
  const currentPID = Number(options.pid ?? process.pid);
  const nowFn = options.now || Date.now;
  const setIntervalFn = options.setInterval || setInterval;
  const clearIntervalFn = options.clearInterval || clearInterval;
  const heartbeatLock = `${heartbeatPath}.lock`;
  const withHeartbeatLock = options.withLock || ((body) => withWakeLock(
    heartbeatLock,
    body,
    { waitMs: 2000 }
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
    update(nextQueueDepth, nextActiveTurnId = null) {
      const depth = Number(nextQueueDepth);
      queueDepth = Number.isInteger(depth) && depth >= 0 ? depth : queueDepth;
      activeTurnId = typeof nextActiveTurnId === "string" && nextActiveTurnId
        ? nextActiveTurnId
        : null;
    },
    async start() {
      const decision = await withHeartbeatLock(async () => {
        // The caller already holds the queue's kernel lock. Heartbeat rows
        // describe that owner; stale timestamps and numeric PIDs grant nothing.
        const receipt = heartbeatRecord();
        appendJSONLineAtomicUnlocked(heartbeatPath, receipt);
        return { status: "started", receipt };
      });
      if (decision.status === "started") {
        timer = setIntervalFn(() => scheduleHeartbeat(), intervalMs);
        if (timer && typeof timer.unref === "function") timer.unref();
      }
      return { ...decision, heartbeatPath, intervalMs };
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
