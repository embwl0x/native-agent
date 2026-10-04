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
        // task_complete row carries the actual outcome — let its terminal
        // result override the ambiguous no-reply classification.
        // A different app-server can hydrate a completed resumed turn as
        // interrupted. Its exact durable terminal event wins over that view;
        // retained answer text by itself never establishes completion.
        if (fromThread.status === "completed_without_reply" || fromThread.status === "aborted") {
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
          if (fromRollout) return fromRollout;
        }
        const activity = rolloutPath
          ? extractTurnResultFromRollout(rolloutPath, turnId, { includeNonTerminal: true }) : null;
        return {
          ...fromThread,
          toolActivityCount: activity && (activity.status !== "in_flight" || activity.sawTurnStart)
            ? activity.toolActivityCount : null,
          noWorkObserved: activity && activity.status === "in_flight"
            ? (activity.sawTurnStart ? activity.toolActivityCount === 0 && !activity.hasMessage : null)
            : activity ? activity.noWorkObserved ?? null : null,
          connectorDiagnostics: activity ? activity.connectorDiagnostics || null : null,
        };
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

/// Display-only: the app-server's agent-message deltas and item starts for
/// this turn, forwarded to the app's live stream. Never turn evidence.
function forwardTurnLive(client, threadId, turnId, live) {
  if (!live || !client || typeof client.onNotification !== "function") return () => {};
  let text = "";
  let itemId = null;
  return client.onNotification((message) => {
    const params = message && message.params;
    if (!params || params.threadId !== threadId || (params.turnId && params.turnId !== turnId)) return;
    const item = params.item || {};
    // Only a message seen from its start: joining mid-message would show a
    // reply with its head cut off.
    if (message.method === "item/agentMessage/delta" && typeof params.delta === "string" && params.itemId === itemId) {
      text += params.delta;
      live.partial(text);
    } else if (message.method === "item/started" && item.type === "agentMessage") {
      text = "";
      itemId = item.id;
    } else if (message.method === "item/started" && item.type === "commandExecution") {
      live.note(`Running ${String(item.command || "a command").slice(0, 200)}`);
    } else if (message.method === "item/started" && item.type === "mcpToolCall") {
      live.note(`Using ${item.tool || "a tool"}`);
    } else if (message.method === "item/started" && item.type === "fileChange") {
      live.note("Editing files");
    } else if (message.method === "item/started" && item.type === "webSearch") {
      live.note("Searching the web");
    } else {
      live.activity();
    }
  });
}

async function waitForTurnResultEventFirst(threadId, turnId, config, client = null, windowMs = null, live = null, onObservation = null) {
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
  const stopLive = forwardTurnLive(client, threadId, turnId, live);
  try {
  // Thread events go only to connections subscribed to the thread, and this
  // one is fresh. Rejoin it (listener already registered, so nothing is
  // missed): threadId only, so no turn starts and no setting changes; the
  // reply itself still comes from the canonical reads below.
  if (live && client) {
    try { await client.request("thread/resume", { threadId, excludeTurns: true }); } catch {}
  }
  // Always close the registration race, even if resuming consumed the window.
  do {
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
    if (onObservation) {
      try { await onObservation(); }
      catch (error) { waiter.close(); throw error; }
    }

    const event = await waiter.promise;
    if (event.source === "exact_timeout") break;
    // A rollout write is a real sign of life even when no delta reaches us.
    if (live) live.activity();
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
  } while (Date.now() < deadline);
  } finally { stopLive(); }

  return {
    status: "timeout",
    completedAt: nowISO(),
    durationMs: null,
    message: "",
    rolloutPath: lastRolloutPath || findThreadRolloutPath(threadId, config) || null,
    waitSource: "exact_timeout",
  };
}

async function waitForTurnResult(threadId, turnId, config, windowMs = null, live = null, onObservation = null) {
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
    return await waitForTurnResultEventFirst(threadId, turnId, config, client, windowMs, live, onObservation);
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
  const turnResult = await wait(threadId, turnId, config, options.windowMs || null, options.live || null, options.onObservation || null);
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
/// can never produce a terminal row, while any found turn without an authoritative
/// terminal result gets the longer bounded wait, including unloaded interruptions.
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
    const priorProbe = job.stallProbe && job.stallProbe.lastProbe;
    const nextIdleThresholdMs = priorProbe && priorProbe.serverReachable && priorProbe.turnFound
      ? stallWedgedIdleMs : Math.min(stallIdleMs, hangWatchdogMs);
    const watchdogRemainingMs = beforeWait && Number.isFinite(beforeWait.mtimeMs)
      ? Math.max(1, beforeWait.mtimeMs + nextIdleThresholdMs - nowFn())
      : judgingWindowMs;
    const waitOptions = {
      ...options,
      windowMs: Math.min(judgingWindowMs, watchdogRemainingMs),
      onObservation: async () => {
        const snapshot = snapshotFn(job.threadId, config);
        const prior = job.stallProbe;
        if (prior && stallSnapshotsEqual(prior.rolloutSnapshot, snapshot)) return;
        const activity = snapshot
          ? extractTurnResultFromRollout(snapshot.path, job.turnId, { includeNonTerminal: true }) : null;
        job.stallProbe = {
          rolloutSnapshot: snapshot,
          stagnantWindows: 0,
          toolActivityCount: activity && activity.sawTurnStart ? activity.toolActivityCount : null,
          noWorkObserved: activity && activity.sawTurnStart
            ? activity.toolActivityCount === 0 && !activity.hasMessage : null,
          idleThresholdMs: stallWedgedIdleMs,
          observedAt: nowISO(),
        };
        await onTimeout({ threadId: job.threadId, turnId: job.turnId,
          turnResult: { waitSource: "rollout_observation" } });
      },
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
    const activity = currentSnapshot
      ? extractTurnResultFromRollout(currentSnapshot.path, observed.turnId, { includeNonTerminal: true })
      : null;
    if (activity && activity.status !== "in_flight") {
      return { ...observed, turnResult: activity };
    }
    const toolActivityCount = activity && activity.sawTurnStart ? activity.toolActivityCount : null;
    const noWorkObserved = activity && activity.sawTurnStart
      ? activity.toolActivityCount === 0 && !activity.hasMessage : null;
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
    const idleReady = idleMs != null ? idleMs >= Math.min(stallIdleMs, hangWatchdogMs) : effectiveStagnant >= 1;
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
      const wedgedLiveness = !deadLiveness && wedgedReady;
      if (deadLiveness || wedgedLiveness) {
        // The confirmation wait can race a tool result or terminal write.
        // Reconcile the exact turn and require the same rollout before repair.
        const confirmedSnapshot = snapshotFn(observed.threadId, config);
        const reconciled = confirmedSnapshot
          ? extractTurnResultFromRollout(confirmedSnapshot.path, observed.turnId, { includeNonTerminal: true })
          : null;
        if (reconciled && reconciled.status !== "in_flight") return { ...observed, turnResult: reconciled };
        if (!stallSnapshotsEqual(currentSnapshot, confirmedSnapshot)) continue;
        const rolloutPath = currentSnapshot ? currentSnapshot.path : null;
        const failedHung = Boolean(activity && activity.sawTurnStart && idleMs >= hangWatchdogMs);
        const detectedAt = new Date(nowFn()).toISOString();
        const hangEvidence = failedHung ? {
          turnId: observed.turnId,
          rolloutPath,
          lastWriteAt: new Date(currentSnapshot.mtimeMs).toISOString(),
          declaredAt: detectedAt,
          idleMs,
          idleThresholdMs: wedgedLiveness ? stallWedgedIdleMs : hangWatchdogMs,
          toolActivityCount,
          noWorkObserved,
        } : null;
        if (hangEvidence) hangEvidence.receiptsPath = await appendHangWatchdogReceipt(hangEvidence, config);
        return {
          ...observed,
          turnResult: {
            ...observed.turnResult,
            status: failedHung ? "failed_hung" : "stalled",
            completedAt: detectedAt,
            message: activity ? activity.message || "" : "",
            hangEvidence,
            noWorkObserved,
            toolActivityCount,
            connectorDiagnostics: activity ? activity.connectorDiagnostics || null : null,
            stallEvidence: {
              stagnantWindows: effectiveStagnant,
              rolloutPath,
              serverReachable: liveness.serverReachable,
              turnFound: liveness.turnFound,
              turnClaimsInProgress: liveness.turnClaimsInProgress,
              idleMs,
              idleThresholdMs: liveness.serverReachable && liveness.turnFound
                ? stallWedgedIdleMs
                : Math.min(stallIdleMs, hangWatchdogMs),
              lastActivityAt: currentSnapshot && Number.isFinite(currentSnapshot.mtimeMs)
                ? new Date(currentSnapshot.mtimeMs).toISOString()
                : null,
              detectedAt,
            },
          },
        };
      }
    }
    job.stallProbe = {
      rolloutSnapshot: currentSnapshot,
      stagnantWindows: effectiveStagnant,
      lastProbe: liveness,
      toolActivityCount,
      noWorkObserved,
      idleThresholdMs: stallWedgedIdleMs,
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

module.exports = { createCodexTurnObservation };
