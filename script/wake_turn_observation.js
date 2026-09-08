"use strict";

// Lane-specific turn observation; entrypoints supply runtime policy and effects.

function createCodexTurnObservation({
  CODEX_HOME,
  appendHangWatchdogReceipt,
  connectRpc,
  createWakeEventWaiter,
  extractTurnResultFromRollout,
  extractTurnResultFromThread,
  extractTurnResultFromTurn,
  nowISO,
  numberSetting,
  sleep
}) {
const fs = require("fs");
const path = require("path");

const ROLLOUT_PATH_CACHE = new Map();

function findThreadRolloutPath(threadId, config, options = {}) {
  if (typeof config.rolloutPath === "string" && config.rolloutPath) {
    return fs.existsSync(config.rolloutPath) ? config.rolloutPath : null;
  }
  if (!options.forceRefresh && ROLLOUT_PATH_CACHE.has(threadId)) {
    const cached = ROLLOUT_PATH_CACHE.get(threadId);
    if (cached && fs.existsSync(cached)) return cached;
  }
  const sessionsRoot = path.join(CODEX_HOME, "sessions");
  const stack = [sessionsRoot];
  const matches = [];
  while (stack.length > 0) {
    const dir = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl") && entry.name.includes(threadId)) {
        let mtimeMs = 0;
        try { mtimeMs = fs.statSync(fullPath).mtimeMs; } catch {}
        matches.push({ path: fullPath, mtimeMs });
      }
    }
  }
  matches.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const match = matches[0] ? matches[0].path : null;
  if (match) ROLLOUT_PATH_CACHE.set(threadId, match);
  return match;
}

function readLocalRolloutState(threadId, config) {
  const rolloutPath = findThreadRolloutPath(threadId, config);
  if (!rolloutPath) return null;
  // A hung turn's signature is a rollout file that stops being written mid-flight.
  // Liveness is judged by last write (file mtime), not turn start, so long healthy
  // turns stay active while a frozen one goes stale after ~10 minutes.
  const activeStaleMs = numberSetting(config, "activeStaleMs", "NATIVE_AGENT_CODEX_ACTIVE_STALE_MS", 10 * 60 * 1000);
  let text;
  try {
    text = fs.readFileSync(rolloutPath, "utf8");
  } catch {
    return null;
  }
  const openTurns = new Map();
  const terminalTypes = new Set(["task_complete", "turn_aborted"]);
  for (const line of text.split("\n")) {
    if (!line.includes("\"event_msg\"") || !line.includes("\"turn_id\"")) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = row && row.payload;
    const type = payload && payload.type;
    const turnId = payload && payload.turn_id;
    if (!type || !turnId) continue;
    if (type === "task_started") {
      const startedAtSeconds = Number(payload.started_at || 0);
      const startedAtMs = startedAtSeconds > 0
        ? startedAtSeconds * 1000
        : Date.parse(row.timestamp || "") || 0;
      openTurns.set(turnId, {
        turnId,
        startedAt: startedAtSeconds || null,
        startedAtMs,
        timestamp: row.timestamp || null,
      });
    } else if (terminalTypes.has(type)) {
      openTurns.delete(turnId);
    }
  }

  const allOpenTurns = [...openTurns.values()];
  const freshOpenTurns = allOpenTurns.filter((turn) => {
    let rolloutMtimeMs = 0;
    try {
      rolloutMtimeMs = fs.statSync(rolloutPath).mtimeMs;
    } catch {}
    const lastSignalMs = Math.max(turn.startedAtMs || 0, rolloutMtimeMs);
    if (!lastSignalMs) return true;
    return Date.now() - lastSignalMs < activeStaleMs;
  });
  return {
    threadId,
    source: "local_rollout",
    rolloutPath,
    active: freshOpenTurns.length > 0,
    statusType: freshOpenTurns.length > 0 ? "active" : "idle",
    activeFlags: [],
    inProgressTurnIds: freshOpenTurns.map((turn) => turn.turnId),
    staleInProgressTurnIds: allOpenTurns
      .filter((turn) => !freshOpenTurns.includes(turn))
      .map((turn) => turn.turnId),
  };
}

function safeFileStat(filePath) {
  try {
    const stat = fs.statSync(filePath);
    return { ino: stat.ino, size: stat.size, mtimeMs: stat.mtimeMs };
  } catch {
    return null;
  }
}

function sameFileStat(lhs, rhs) {
  return Boolean(lhs && rhs
    && lhs.ino === rhs.ino
    && lhs.size === rhs.size
    && lhs.mtimeMs === rhs.mtimeMs);
}

async function readCanonicalTurnResult(client, threadId, turnId, config, eventTurn = null) {
  let rolloutPath = findThreadRolloutPath(threadId, config);
  if (client) {
    try {
      const result = await client.request("thread/read", { threadId, includeTurns: true });
      const fromThread = extractTurnResultFromThread(result && result.thread, turnId, rolloutPath);
      if (fromThread) {
        // The app-server marks provider-failed turns "completed" with no
        // items, which reads as an unknown outcome. The rollout's
        // task_complete row carries the actual error — let its failed
        // verdict override the ambiguous no-reply classification.
        if (fromThread.status === "completed_without_reply") {
          let livePath = rolloutPath && fs.existsSync(rolloutPath) ? rolloutPath : null;
          let fromRollout = livePath ? extractTurnResultFromRollout(livePath, turnId) : null;
          if (!fromRollout) {
            // The app-server can report terminal before Codex flushes the
            // task_complete line — or before the session file is even
            // discoverable. One bounded delay, then re-find AND re-read;
            // never poll beyond it. forceRefresh: a resumed thread can grow a
            // NEWER session file than the cached one, and the stale cache
            // would otherwise defeat this retry in a long-lived process.
            await new Promise((resolve) => setTimeout(resolve, 400));
            livePath = findThreadRolloutPath(threadId, config, { forceRefresh: true }) || livePath;
            if (livePath && fs.existsSync(livePath)) {
              fromRollout = extractTurnResultFromRollout(livePath, turnId);
            }
          }
          if (fromRollout && fromRollout.status === "failed") {
            return fromRollout;
          }
        }
        return fromThread;
      }
    } catch {
      // The rollout is the durable repair path when the app-server connection
      // disappears after starting the turn.
    }
  }
  if (!rolloutPath || !fs.existsSync(rolloutPath)) {
    rolloutPath = findThreadRolloutPath(threadId, config);
  }
  if (rolloutPath) {
    const fromRollout = extractTurnResultFromRollout(rolloutPath, turnId);
    if (fromRollout) return fromRollout;
  }
  // `turn/completed` is exact server evidence, but it is intentionally the
  // last read source: thread/read and the durable rollout remain canonical.
  return extractTurnResultFromTurn(eventTurn, turnId, rolloutPath);
}

function createTurnCompletionEventWaiter(client, threadId, turnId, config, deadline) {
  const waiter = createWakeEventWaiter();
  const { cleanup, promise, close, signal } = waiter;

  if (client && typeof client.onNotification === "function") {
    cleanup.push(client.onNotification((message) => {
      if (!message || message.method !== "turn/completed") return;
      const params = message.params;
      if (!params || params.threadId !== threadId || !params.turn || params.turn.id !== turnId) return;
      signal({ source: "turn_completed_notification", turn: params.turn });
    }));
  }
  if (client && typeof client.onDisconnect === "function") {
    cleanup.push(client.onDisconnect(() => {
      signal({ source: "app_server_disconnect", turn: null });
    }));
  }

  const rolloutPath = findThreadRolloutPath(threadId, config);
  const watchPath = rolloutPath || path.join(CODEX_HOME, "sessions");
  if (fs.existsSync(watchPath)) {
    try {
      const initialRolloutStat = rolloutPath ? safeFileStat(rolloutPath) : null;
      const watcher = fs.watch(
        watchPath,
        { persistent: false, recursive: !rolloutPath },
        (_eventType, filename) => {
          const changed = filename == null ? "" : String(filename);
          if (!rolloutPath && changed && !changed.includes(threadId)) return;
          if (rolloutPath && initialRolloutStat) {
            const current = safeFileStat(rolloutPath);
            if (sameFileStat(initialRolloutStat, current)) return;
          }
          signal({ source: "rollout_file_event", turn: null });
        }
      );
      cleanup.push(() => watcher.close());
    } catch {
      // Exact timeout and app-server notification remain. The next process
      // restart performs the same initial canonical reread from the job file.
    }
  }

  const remaining = Math.max(0, deadline - Date.now());
  waiter.startTimeout({ source: "exact_timeout", turn: null }, remaining);
  return { promise, close, rolloutPath };
}

async function waitForTurnResultEventFirst(threadId, turnId, config, client = null, windowMs = null) {
  const timeoutMs = numberSetting(
    config,
    "replyWaitTimeoutMs",
    "NATIVE_AGENT_CODEX_REPLY_WAIT_TIMEOUT_MS",
    60 * 60 * 1000
  );
  // A caller may shorten THIS window without shortening the overall wait: the
  // durable loop re-waits after every timeout, so a shorter window only moves
  // the stall-judging cadence (2026-08-05). It is a floor-1ms clamp, never an
  // extension -- a window longer than the configured reply wait is ignored.
  const effectiveMs = Number.isFinite(windowMs) && windowMs > 0
    ? Math.min(timeoutMs, windowMs)
    : timeoutMs;
  const deadline = Date.now() + effectiveMs;
  let lastRolloutPath = findThreadRolloutPath(threadId, config);

  while (Date.now() < deadline) {
    // Register both exact event sources before rereading canonical truth. A
    // completion racing registration is therefore caught by the initial read.
    const waiter = createTurnCompletionEventWaiter(
      client,
      threadId,
      turnId,
      config,
      deadline
    );
    lastRolloutPath = waiter.rolloutPath || lastRolloutPath;
    // fs.watch has no ready callback. Yield once so its native registration is
    // active before the canonical race-closing read.
    await new Promise((resolve) => setImmediate(resolve));
    const initial = await readCanonicalTurnResult(client, threadId, turnId, config);
    if (initial) {
      waiter.close();
      return { ...initial, waitSource: "initial_canonical_read" };
    }

    const event = await waiter.promise;
    if (event.source === "exact_timeout") break;
    const result = await readCanonicalTurnResult(
      client,
      threadId,
      turnId,
      config,
      event.turn
    );
    if (result) return { ...result, waitSource: event.source };
    // A file edge may precede the terminal line becoming visible. Re-arm the
    // event sources and close that race with another canonical read; never poll.
  }

  return {
    status: "timeout",
    completedAt: nowISO(),
    durationMs: null,
    message: "",
    rolloutPath: lastRolloutPath || findThreadRolloutPath(threadId, config) || null,
    waitSource: "exact_timeout",
  };
}

async function waitForTurnResult(threadId, turnId, config, windowMs = null) {
  const requestTimeoutMs = numberSetting(
    config,
    "requestTimeoutMs",
    "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS",
    12000
  );
  let client = null;
  try {
    client = await connectRpc(requestTimeoutMs);
  } catch {
    // The vnode-backed durable rollout path still provides event-first repair.
  }
  try {
    return await waitForTurnResultEventFirst(threadId, turnId, config, client, windowMs);
  } finally {
    if (client) client.close();
  }
}

async function waitForTurnResultWithEmptyRetry(job, config, options = {}) {
  // Despite the compatibility name, this deliberately performs no automatic
  // replay. A terminal turn without assistant cargo may already have changed
  // files or external state; starting another thread or `codex exec` would
  // repeat non-idempotent work. Manual retry remains an explicit user action.
  const threadId = job.threadId;
  const turnId = job.turnId;
  const wait = options.waitForTurnResult || waitForTurnResult;
  const turnResult = await wait(threadId, turnId, config, options.windowMs || null);
  return { threadId, turnId, turnResult, attempts: [{ threadId, turnId, turnResult }] };
}

/// One wait-window's stall evidence. A "window" is a full replyWaitTimeoutMs
/// interval (default 1h) that ended in exact_timeout — i.e. no terminal row
/// became visible the entire time.
function rolloutStallSnapshot(threadId, config) {
  const rolloutPath = findThreadRolloutPath(threadId, config, { forceRefresh: true });
  if (!rolloutPath) return null;
  const stat = safeFileStat(rolloutPath);
  if (!stat) return null;
  return { path: rolloutPath, ino: stat.ino, size: stat.size, mtimeMs: stat.mtimeMs };
}

function stallSnapshotsEqual(a, b) {
  if (!a && !b) return true; // no rollout discoverable across the window is itself stagnation
  if (!a || !b) return false;
  return a.path === b.path && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;
}

/// Ask the app-server whether it still claims this turn is running. Distinct
/// outcomes matter: an unreachable server or a turn missing from its thread
/// can never produce a terminal row, while a claimed-inProgress turn gets the
/// benefit of the doubt for one extra window.
async function probeTurnLiveness(threadId, turnId, config) {
  const probeTimeoutMs = numberSetting(
    config,
    "stallProbeRpcTimeoutMs",
    "NATIVE_AGENT_CODEX_STALL_PROBE_RPC_TIMEOUT_MS",
    5000
  );
  let client = null;
  try {
    client = await connectRpc(probeTimeoutMs);
  } catch {
    return { serverReachable: false, turnFound: false, turnClaimsInProgress: false };
  }
  try {
    const result = await client.request("thread/read", { threadId, includeTurns: true });
    const turns = result && result.thread && Array.isArray(result.thread.turns)
      ? result.thread.turns
      : [];
    const turn = turns.find((candidate) => candidate && candidate.id === turnId);
    return {
      serverReachable: true,
      turnFound: Boolean(turn),
      turnClaimsInProgress: Boolean(turn && turn.status === "inProgress"),
    };
  } catch {
    // A failed read on a reachable socket is not evidence of a dead turn.
    // Preserve found/inProgress so only the longer wedged-turn path can settle it.
    return { serverReachable: true, turnFound: true, turnClaimsInProgress: true };
  } finally {
    client.close();
  }
}

async function waitForDurableTerminalExecution(job, config, onTimeout, options = {}) {
  const snapshotFn = options.rolloutStallSnapshot || rolloutStallSnapshot;
  const probeFn = options.probeTurnLiveness || probeTurnLiveness;
  const nowFn = options.now || Date.now;
  const hangWatchdogMs = numberSetting(
    config,
    "hangWatchdogMs",
    "NATIVE_AGENT_CODEX_HANG_WATCHDOG_MS",
    5 * 60 * 1000
  );
  // Judge rollout idle time independently of the reply-wait timeout.
  const stallIdleMs = numberSetting(
    config,
    "stallIdleMs",
    "NATIVE_AGENT_CODEX_STALL_IDLE_MS",
    15 * 60 * 1000
  );
  // A server still claiming inProgress is NOT judged on the 15-minute knob: a
  // single long tool call (a multi-hour build under the github-command profile)
  // legitimately writes zero rollout bytes while running (2026-07-31 audit).
  // Default preserves the pre-change effective behavior (4 x 1h windows).
  //
  // RATIFIED, do not lower without the user (2026-08-05): the 4h default was raised
  // as an explicit question at ship time and kept deliberately. Reasoning is
  // forward-looking, not legacy — delegation is scaling to multi-hour project
  // chunks, so server-claimed-live turns that write nothing for hours become
  // NORMAL. Killing them at the dead-liveness knob would destroy real work; a
  // wedged turn that is genuinely dead still converges, just slowly. The fast
  // path is the dead-liveness arm (server unreachable / turn unlisted), which
  // is the shape the 2026-08-05 incident actually took.
  const stallWedgedIdleMs = Math.max(stallIdleMs, numberSetting(
    config,
    "stallWedgedIdleMs",
    "NATIVE_AGENT_CODEX_STALL_WEDGED_IDLE_MS",
    4 * 60 * 60 * 1000
  ));
  const judgingWindowMs = options.windowMs || stallIdleMs;
  while (true) {
    // Wake exactly when the currently visible rollout would cross the hang
    // threshold. Rollout vnode edges still wake the inner waiter earlier; the
    // post-wait stat below then observes the new mtime and rearms from it.
    const beforeWait = snapshotFn(job.threadId, config);
    const watchdogRemainingMs = beforeWait && Number.isFinite(beforeWait.mtimeMs)
      ? Math.max(1, beforeWait.mtimeMs + hangWatchdogMs - nowFn())
      : hangWatchdogMs;
    const waitOptions = {
      ...options,
      windowMs: Math.min(judgingWindowMs, watchdogRemainingMs),
    };
    const observed = await waitForTurnResultWithEmptyRetry(job, config, waitOptions);
    if (observed.turnResult.status !== "timeout") return observed;

    // Dead-liveness settlement needs a stagnant rollout and confirmed probes.
    // A discoverable rollout supplies measured idle time; otherwise establish
    // a baseline and count unchanged windows (ino/size/mtime, including null).
    // An undiscoverable file alone does not prove death, and every dead-liveness
    // reading needs a second probe. A server still claiming inProgress uses
    // stallWedgedIdleMs: a long tool call can legitimately write no rollout bytes.
    // Rollout movement resets the window count.
    const currentSnapshot = snapshotFn(observed.threadId, config);
    const idleMs = currentSnapshot && Number.isFinite(currentSnapshot.mtimeMs)
      ? Math.max(0, nowFn() - currentSnapshot.mtimeMs)
      : null;
    if (currentSnapshot && idleMs >= hangWatchdogMs) {
      const activity = extractTurnResultFromRollout(
        currentSnapshot.path,
        observed.turnId,
        { includeNonTerminal: true }
      );
      if (activity && activity.status === "in_flight" && activity.sawTurnStart) {
        const declaredAt = new Date(nowFn()).toISOString();
        const lastWriteAt = new Date(currentSnapshot.mtimeMs).toISOString();
        const receipt = {
          turnId: observed.turnId,
          rolloutPath: currentSnapshot.path,
          lastWriteAt,
          declaredAt,
        };
        const receiptsPath = await appendHangWatchdogReceipt(receipt, config);
        return {
          ...observed,
          turnResult: {
            ...observed.turnResult,
            status: "failed_hung",
            reason: "failed-hung",
            completedAt: declaredAt,
            rolloutPath: currentSnapshot.path,
            waitSource: "hang_watchdog",
            errorMessage: `hang_watchdog: rollout unchanged for ${Math.round(idleMs)} ms`,
            noWorkObserved: activity.toolActivityCount === 0 && !activity.hasMessage,
            toolActivityCount: activity.toolActivityCount,
            connectorDiagnostics: activity.connectorDiagnostics || null,
            hangEvidence: {
              ...receipt,
              idleMs,
              idleThresholdMs: hangWatchdogMs,
              receiptsPath,
            },
          },
        };
      }
    }
    const prior = job.stallProbe || null;
    let effectiveStagnant;
    if (!prior) {
      // An undiscoverable rollout needs a baseline first; the next null==null
      // observation can count as stagnant without treating initial absence as death.
      effectiveStagnant = 0;
    } else if (stallSnapshotsEqual(prior.rolloutSnapshot, currentSnapshot)) {
      effectiveStagnant = (prior.stagnantWindows || 0) + 1;
    } else {
      effectiveStagnant = 0;
    }
    const wedgedWindows = Math.max(2, numberSetting(
      config,
      "stallWedgedWindows",
      "NATIVE_AGENT_CODEX_STALL_WEDGED_WINDOWS",
      4
    ));
    // Idle-time gates when the rollout is discoverable; window counts otherwise.
    const idleReady = idleMs != null ? idleMs >= stallIdleMs : effectiveStagnant >= 1;
    const wedgedReady = idleMs != null
      ? idleMs >= stallWedgedIdleMs
      : effectiveStagnant >= wedgedWindows;
    let liveness = null;
    if (idleReady) {
      liveness = await probeFn(observed.threadId, observed.turnId, config);
      let deadLiveness = !liveness.serverReachable || !liveness.turnFound;
      if (deadLiveness) {
        // Two readings must agree; a transient connection failure or server
        // restart cannot be the sole evidence that a turn died.
        await sleep(numberSetting(
          config,
          "stallProbeConfirmDelayMs",
          "NATIVE_AGENT_CODEX_STALL_PROBE_CONFIRM_DELAY_MS",
          5000
        ));
        const confirm = await probeFn(observed.threadId, observed.turnId, config);
        if (confirm.serverReachable && confirm.turnFound) {
          deadLiveness = false;
        }
        liveness = confirm;
      }
      const wedgedInProgress = liveness.turnClaimsInProgress && wedgedReady;
      if (deadLiveness || wedgedInProgress) {
        const rolloutPath = currentSnapshot ? currentSnapshot.path : null;
        const activity = rolloutPath
          ? extractTurnResultFromRollout(rolloutPath, observed.turnId, { includeNonTerminal: true })
          : null;
        const inFlight = activity && activity.status === "in_flight" ? activity : null;
        const noWorkObserved = !inFlight || !inFlight.sawTurnStart
          ? null
          : (inFlight.toolActivityCount === 0 && !inFlight.hasMessage);
        return {
          ...observed,
          turnResult: {
            ...observed.turnResult,
            status: "stalled",
            noWorkObserved,
            toolActivityCount: inFlight ? inFlight.toolActivityCount : null,
            connectorDiagnostics: inFlight ? inFlight.connectorDiagnostics || null : null,
            stallEvidence: {
              stagnantWindows: effectiveStagnant,
              rolloutPath,
              serverReachable: liveness.serverReachable,
              turnFound: liveness.turnFound,
              turnClaimsInProgress: liveness.turnClaimsInProgress,
              idleMs,
              idleThresholdMs: liveness.turnClaimsInProgress && !(!liveness.serverReachable || !liveness.turnFound)
                ? stallWedgedIdleMs
                : stallIdleMs,
              lastActivityAt: currentSnapshot && Number.isFinite(currentSnapshot.mtimeMs)
                ? new Date(currentSnapshot.mtimeMs).toISOString()
                : null,
              detectedAt: nowISO(),
            },
          },
        };
      }
    }
    job.stallProbe = {
      rolloutSnapshot: currentSnapshot,
      stagnantWindows: effectiveStagnant,
      lastProbe: liveness,
      observedAt: nowISO(),
    };
    await onTimeout(observed);
  }
}

return {
  findThreadRolloutPath,
  readLocalRolloutState,
  safeFileStat,
  sameFileStat,
  readCanonicalTurnResult,
  waitForTurnResultEventFirst,
  waitForTurnResultWithEmptyRetry,
  probeTurnLiveness,
  waitForDurableTerminalExecution
};
}

function createClaudeTurnObservation({
  KILL_GRACE_MS,
  STALL_SAMPLE_MS,
  STDERR_CAP,
  STDOUT_CAP,
  envNumber,
  processTreePids,
  redactDiagnosticText,
  spawn,
  tail
}) {
const fs = require("fs");
const os = require("os");
const path = require("path");

/// Exact canonical transcript path for one Claude session. Claude derives its
/// project directory by replacing non path-name characters in the absolute cwd
/// with `-`; the explicit path override is a narrow end-to-end test seam.
function claudeTranscriptPath(cwd, sessionId) {
  const override = process.env.NATIVE_AGENT_CLAUDE_WAKE_TRANSCRIPT_PATH;
  if (override) return override;
  const safeId = path.basename(String(sessionId || ""));
  if (!safeId || safeId !== String(sessionId || "")) return null;
  const projectKey = path.resolve(cwd).replace(/[^A-Za-z0-9_-]/g, "-");
  const projectsRoot = process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_PROJECTS_DIR ||
    path.join(os.homedir(), ".claude", "projects");
  return path.join(projectsRoot, projectKey, `${safeId}.jsonl`);
}

/// Read only filesystem metadata: transcript contents can contain secrets and
/// never belong in a liveness record. `missing` means no canonical movement has
/// appeared; `unreadable` means the observer lacks evidence and must fail open
/// to the hard deadline rather than kill on uncertainty.
function transcriptSnapshot(cwd, sessionId) {
  const file = claudeTranscriptPath(cwd, sessionId);
  if (!file) return { state: "unreadable" };
  try {
    const stat = fs.statSync(file);
    return { state: "present", path: file, bytes: stat.size, mtimeMs: stat.mtimeMs };
  } catch (error) {
    return error && error.code === "ENOENT"
      ? { state: "missing", path: file }
      : { state: "unreadable", path: file };
  }
}

class TranscriptProgress {
  constructor() {
    this.last = null;
  }

  observe(snapshot) {
    if (!snapshot || snapshot.state !== "present") return null;
    const advanced = this.last == null
      || snapshot.bytes !== this.last.bytes
      || snapshot.mtimeMs !== this.last.mtimeMs;
    this.last = snapshot;
    return { advanced, bytes: snapshot.bytes, mtimeMs: snapshot.mtimeMs };
  }
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
/// spawn error — and any double-settle would double-post a completion to the agent.
function runClaude({ prompt, sessionArgs, sessionId, cwd, timeoutSeconds, stallSeconds, onProgress }) {
  return new Promise((resolve) => {
    const started = Date.now();
    const binOverride = process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN;
    const command = binOverride || "/usr/bin/env";
    // the user, 2026-09-04: a wake session is a worker, and workers run Opus 5.
    const model = process.env.NATIVE_AGENT_CLAUDE_WAKE_MODEL || "claude-opus-5";
    const args = binOverride
      ? [...sessionArgs, "-p", prompt, "--model", model]
      : ["claude", ...sessionArgs, "-p", prompt, "--model", model];

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

    // Stall watchdog. Progress is canonical Claude transcript movement. Any
    // append resets the clock even when the child is blocked and burns no CPU.
    const stallMs = Number(stallSeconds) > 0 ? Number(stallSeconds) * 1000 : 0;
    if (stallMs > 0) {
      const progress = new TranscriptProgress();
      const first = transcriptSnapshot(cwd, sessionId);
      if (first.state === "present") progress.observe(first);
      let lastAdvanceAt = Date.now();
      let observationReadable = first.state !== "unreadable";
      const sampleMs = Math.max(
        250,
        Math.min(envNumber("NATIVE_AGENT_CLAUDE_WAKE_STALL_SAMPLE_MS", STALL_SAMPLE_MS), stallMs)
      );
      stallTimer = setInterval(() => {
        if (settled) return;
        const snapshot = transcriptSnapshot(cwd, sessionId);
        if (snapshot.state === "unreadable") {
          observationReadable = false;
          return;
        }
        observationReadable = true;
        const sample = progress.observe(snapshot);
        if (sample && sample.advanced) {
          lastAdvanceAt = Date.now();
          if (typeof onProgress === "function") {
            try {
              onProgress({
                transcriptBytes: sample.bytes,
                transcriptMtimeMs: sample.mtimeMs,
                at: new Date(lastAdvanceAt).toISOString(),
              });
            } catch {}
          }
          return;
        }
        if (observationReadable && Date.now() - lastAdvanceAt >= stallMs) {
          // If the deadline already fired, that is the true cause; a transcript-
          // silent child in the 2s kill grace must not be relabelled a stall.
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

return {
  claudeTranscriptPath,
  transcriptSnapshot,
  TranscriptProgress,
  parseCpuTimeMs,
  runClaude,
  classify
};
}

module.exports = { createCodexTurnObservation, createClaudeTurnObservation };
