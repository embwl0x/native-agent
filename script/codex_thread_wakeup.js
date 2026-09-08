#!/usr/bin/env node
"use strict";
// The agent and the user are addressed by their configured names; nothing in
// this file names a specific person.
const AGENT_NAME = process.env.NATIVE_AGENT_AGENT_NAME || "the agent";
const USER_NAME = process.env.NATIVE_AGENT_USER_NAME || "the user";

const {
  jsonOut, nowISO, redactDiagnosticText, processStartIdentity,
  createProcessStartIdentityReader, safeFilePart: sharedSafeFilePart,
  postWakeCompletion, unicodePrefix, dirLockOwnerAlive, fsyncDirectorySync, writeSyncedAndClose,
  copyWakeProducerIdentity, copyWakeCompletionOrigin, readWakeJSON,
  appendSyncedWakeLine, createWakeEventWaiter, readWakeJSONLines, sleep, readWakeBridgeToken,
} = require("./wake_worker_common.js");

const {
  extractTurnResultFromRollout,
  extractTurnResultFromTurn,
  extractTurnResultFromThread,
} = require("./codex_turn_result.js");

const {
  threadStateFromThread, isUnhealthyThreadState, unhealthyThreadResult,
  rpcFailure, stateExcludingTurnIds,
} = require("./codex_wake_thread_state.js");

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const GITHUB_COMMAND_EXECUTION_PROFILE = "github-command-repository-network-v1";
const { brainControlsForEntries, trustedGitHubCommandWorkingDirectory, executionPolicyForEntries } =
  require("./codex_wake_execution_policy.js").createCodexWakeExecutionPolicy({
    stringSetting, enumStringSetting, GITHUB_COMMAND_EXECUTION_PROFILE,
  });
const { formatPrompt, formatBatchPrompt } = require("./codex_wake_prompt.js").createCodexWakePrompt({
  trustedGitHubCommandWorkingDirectory,
});

const { clientUserMessageIdForEntries, freshThreadStartParams, turnStartParams } =
  require("./codex_wake_request_params.js").createCodexWakeRequestParams({
    brainControlsForEntries, executionPolicyForEntries, formatBatchPrompt,
    enumStringSetting, stringSetting,
  });

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CONFIG_PATH = process.env.NATIVE_AGENT_CODEX_WAKEUP_CONFIG ||
  path.join(os.homedir(), ".config", "codex-nativeagent-bridge", "wakeup.json");
const SOCKET_PATH = process.env.CODEX_APP_SERVER_SOCKET ||
  path.join(CODEX_HOME, "app-server-control", "app-server-control.sock");
const {
  daemonVersionsMismatch, socketOwnerPid, captureAppServerIdentity,
  parseLsofWorkingDirectory, daemonWorkingDirectoryMismatch, daemonWorkingDirectoryState,
} = require("./codex_wake_daemon_probe.js").createCodexWakeDaemonProbe({
  socketPath: SOCKET_PATH, processStartIdentity,
});
const { connectRpcOnce, unattendedServerRequestReply } =
  require("./codex_wake_rpc.js").createCodexWakeRpc({ socketPath: SOCKET_PATH });
const BRIDGE_DIR = path.dirname(CONFIG_PATH);
const PENDING_PATH = process.env.NATIVE_AGENT_CODEX_PENDING_PATH ||
  path.join(BRIDGE_DIR, "pending-wakeups.json");
const QUEUE_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_PENDING_LOCK ||
  path.join(BRIDGE_DIR, ".pending-wakeups.lock");
/// Resolved PER CALL, not at module load. A caller (a test, a one-off repair
/// script) that redirects the queue with an env var after `require` would
/// otherwise silently operate on the REAL bridge queue — which is exactly the
/// mistake that made the first version of this file's dead-letter test rewrite
/// production state instead of its own temp dir.
function deadLetterPath() {
  return process.env.NATIVE_AGENT_CODEX_DEAD_LETTER_PATH ||
    path.join(BRIDGE_DIR, "dead-letter-wakeups.jsonl");
}

function pendingPath() {
  return process.env.NATIVE_AGENT_CODEX_PENDING_PATH || PENDING_PATH;
}

function queueLockDir() {
  return process.env.NATIVE_AGENT_CODEX_PENDING_LOCK || QUEUE_LOCK_DIR;
}
const WAKE_LANES_DIR = process.env.NATIVE_AGENT_CODEX_WAKE_LANES_DIR ||
  path.join(BRIDGE_DIR, ".wake-lanes");
const WAKE_CAPACITY_DIR = process.env.NATIVE_AGENT_CODEX_WAKE_CAPACITY_DIR ||
  path.join(BRIDGE_DIR, ".wake-capacity");
const STALE_WAKE_RECOVERIES_PATH = process.env.NATIVE_AGENT_CODEX_STALE_WAKE_RECOVERIES_PATH ||
  path.join(BRIDGE_DIR, "stale-wake-recoveries.jsonl");
const DRAINER_HEARTBEAT_PATH = process.env.NATIVE_AGENT_CODEX_DRAINER_HEARTBEAT_PATH ||
  path.join(BRIDGE_DIR, "drainer-heartbeat.jsonl");
const INBOX_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_INBOX_LOCK ||
  path.join(BRIDGE_DIR, ".codex-inbox.lock");
function inboxLockDir() {
  return process.env.NATIVE_AGENT_CODEX_INBOX_LOCK || INBOX_LOCK_DIR;
}
const REPLY_JOBS_DIR = process.env.NATIVE_AGENT_CODEX_REPLY_JOBS_DIR ||
  path.join(BRIDGE_DIR, "reply-jobs");
const REPLY_DELIVERIES_PATH = process.env.NATIVE_AGENT_CODEX_REPLY_DELIVERIES_PATH ||
  path.join(BRIDGE_DIR, "reply-deliveries.jsonl");
const HANG_WATCHDOG_RECEIPTS_PATH = process.env.NATIVE_AGENT_CODEX_HANG_WATCHDOG_RECEIPTS_PATH ||
  path.join(BRIDGE_DIR, "hang-watchdog.jsonl");
const REPLY_RECOVERY_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_REPLY_RECOVERY_LOCK ||
  path.join(BRIDGE_DIR, ".reply-jobs-recovery.lock");
const BRIDGE_TOKEN_PATH = path.join(os.homedir(), ".config", "claude-bridge", "token");
const BRIDGE_DESCRIPTOR_PATH = path.join(os.homedir(), ".config", "claude-bridge", "bridge.json");
const FRESH_THREAD_MODE = "fresh_thread";
const PINNED_THREAD_MODE = "pinned_thread";
const DEFAULT_WAKE_CONCURRENCY = 4;
const UNKNOWN_WAKE_LANE = "serial:unknown";
const { isCodexNonThreadSentinel, canonicalCodexThreadId, wakeLaneKey, wakeLaneLockPath } =
  require("./codex_wake_lane_identity.js").createCodexWakeLaneIdentity({
    WAKE_LANES_DIR, FRESH_THREAD_MODE, UNKNOWN_WAKE_LANE,
  });

function readStdin() {
  return fs.readFileSync(0, "utf8");
}

function fail(reason, extra = {}) {
  jsonOut({ status: "skipped", reason, ...extra });
  process.exit(0);
}

function loadJSON(file) {
  return readWakeJSON(file, {});
}

function readBridgeDescriptor(file = BRIDGE_DESCRIPTOR_PATH) {
  const value = loadJSON(file);
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value;
}

function codexReturnBridgeEndpoint(config = {}) {
  const explicitHost = config.bridgeHost || process.env.NATIVE_AGENT_CODEX_BRIDGE_HOST;
  const explicitPort = config.bridgePort || process.env.NATIVE_AGENT_CODEX_BRIDGE_PORT;
  if (explicitHost || explicitPort) {
    return {
      host: String(explicitHost || "127.0.0.1"),
      port: Number(explicitPort || 8771),
      source: "explicit",
    };
  }

  const descriptorPath = stringSetting(
    config,
    "bridgeDescriptorPath",
    "NATIVE_AGENT_CODEX_BRIDGE_DESCRIPTOR_PATH",
    BRIDGE_DESCRIPTOR_PATH
  );
  const descriptor = readBridgeDescriptor(descriptorPath);
  if (descriptor) {
    try {
      const endpoint = new URL(String(descriptor.url || ""));
      const host = endpoint.hostname;
      const port = Number(endpoint.port);
      if (endpoint.protocol === "http:" && ["127.0.0.1", "localhost", "::1", "[::1]"].includes(host) && Number.isInteger(port) && port > 0 && port <= 65535) {
        return { host: host === "[::1]" ? "::1" : host, port, source: "descriptor", descriptorPath };
      }
    } catch {}
  }
  return { host: "127.0.0.1", port: 8771, source: "fallback" };
}

function safeFilePart(value) {
  return sharedSafeFilePart(value, 96);
}

function stableUUID(value) {
  const bytes = Buffer.from(crypto.createHash("sha256").update(String(value)).digest().subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function wakeConcurrencyCap(config = {}) {
  const configured = nonnegativeIntegerSetting(
    config,
    "wakeConcurrency",
    "NATIVE_AGENT_CODEX_WAKE_CONCURRENCY",
    DEFAULT_WAKE_CONCURRENCY
  );
  // Four is a safety ceiling, not merely the default. A local config may
  // deliberately lower admission for diagnostics, but can never expand the
  // production pool beyond the contract shared by every helper process.
  return Math.max(
    1,
    Math.min(DEFAULT_WAKE_CONCURRENCY, configured || DEFAULT_WAKE_CONCURRENCY)
  );
}

const currentProcessStartIdentity = createProcessStartIdentityReader();

function boolSetting(config, key, envName, fallback) {
  const env = process.env[envName];
  if (env != null) return ["1", "true", "yes", "on"].includes(env.toLowerCase());
  if (typeof config[key] === "boolean") return config[key];
  return fallback;
}

function numberSetting(config, key, envName, fallback) {
  const env = process.env[envName];
  const raw = env != null ? env : config[key];
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function nonnegativeIntegerSetting(config, key, envName, fallback) {
  const env = process.env[envName];
  const raw = env != null ? env : config[key];
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}

function stringSetting(config, key, envName, fallback) {
  const env = process.env[envName];
  if (env != null && env !== "") return env;
  if (typeof config[key] === "string" && config[key] !== "") return config[key];
  return fallback;
}

function enumStringSetting(config, key, envName, fallback, allowed) {
  const value = stringSetting(config, key, envName, fallback);
  return allowed.has(value) ? value : fallback;
}

function normalizeWakeupMode(value) {
  const raw = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/-/g, "_");
  if (["fresh", "fresh_thread", "new", "new_thread", "new_session", "fresh_session"].includes(raw)) {
    return FRESH_THREAD_MODE;
  }
  if (["pinned", "pinned_thread", "configured", "configured_thread", "thread", "legacy"].includes(raw)) {
    return PINNED_THREAD_MODE;
  }
  return null;
}

function wakeupMode(config, payload = {}) {
  // Canonicalize before choosing pinned mode so sentinels such as `codex:new`
  // remain fresh-thread requests.
  if (payload && canonicalCodexThreadId(payload.threadId)) {
    return PINNED_THREAD_MODE;
  }
  if (process.env.NATIVE_AGENT_CODEX_THREAD_ID) {
    return PINNED_THREAD_MODE;
  }
  const envMode = process.env.NATIVE_AGENT_CODEX_WAKEUP_MODE || process.env.NATIVE_AGENT_CODEX_DELIVERY_MODE;
  const configured = normalizeWakeupMode(envMode || config.deliveryMode || config.mode);
  if (configured) return configured;
  if (typeof config.freshThread === "boolean") {
    return config.freshThread ? FRESH_THREAD_MODE : PINNED_THREAD_MODE;
  }
  return FRESH_THREAD_MODE;
}

function codexCandidates() {
  const home = os.homedir();
  return [
    process.env.CODEX_BIN,
    path.join(CODEX_HOME, "packages", "standalone", "current", "codex"),
    "/opt/homebrew/bin/codex",
    path.join(home, "Desktop", "Codex.app", "Contents", "Resources", "codex"),
  ].filter(Boolean);
}

function startDaemon() {
  for (const candidate of codexCandidates()) {
    if (!fs.existsSync(candidate)) continue;
    const result = spawnSync(candidate, ["app-server", "daemon", "start"], {
      encoding: "utf8",
      timeout: 8000,
      killSignal: "SIGKILL",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (result.status === 0 && fs.existsSync(SOCKET_PATH)) return;
  }
}

function ensureDaemon() {
  if (!fs.existsSync(SOCKET_PATH)) {
    startDaemon();
    return;
  }
  ensureDaemonVersionAligned();
}

// Check the running app-server version against the installed CLI after upgrades.
// This socket serves only bridge wakeups, not interactive Codex sessions.
const daemonHealState = { checked: false, record: null };

function daemonControlStart(candidate) {
  // Leave room for the 12s RPC budget within the app's 20s helper deadline.
  const result = spawnSync(candidate, ["app-server", "daemon", "start"], {
    encoding: "utf8",
    timeout: 4000,
    // spawnSync waits for exit after timeout; SIGTERM can leave it blocked.
    killSignal: "SIGKILL",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) return null;
  const text = String(result.stdout || "").trim();
  if (!text) return null;
  const lines = text.split("\n");
  try {
    return JSON.parse(lines[lines.length - 1]);
  } catch {
    return null;
  }
}


function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return Boolean(error && error.code === "EPERM");
  }
}

function sleepSyncMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function stopDaemonForRestart(candidate) {
  // Managed daemons honor the official stop; an UNMANAGED holder of the
  // socket (the Jul 16 zombie survived SIGTERM from outside) is killed by
  // socket-owner pid with bounded TERM→KILL escalation. Runs ONLY inside the
  // background healer under the heal lock — never on a wakeup's foreground
  // path (a synchronous multi-second stall there collides with the app's
  // helper deadline and can poison inbox dedup on retry).
  spawnSync(candidate, ["app-server", "daemon", "stop"], {
    encoding: "utf8",
    timeout: 8000,
    killSignal: "SIGKILL",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pid = socketOwnerPid();
  if (pid == null) return true;
  try { process.kill(pid, "SIGTERM"); } catch {}
  const termDeadline = Date.now() + 3000;
  while (Date.now() < termDeadline) {
    if (!pidAlive(pid)) return true;
    sleepSyncMs(150);
  }
  try { process.kill(pid, "SIGKILL"); } catch {}
  const killDeadline = Date.now() + 2000;
  while (Date.now() < killDeadline) {
    if (!pidAlive(pid)) return true;
    sleepSyncMs(150);
  }
  return !pidAlive(pid);
}

const HEAL_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_HEAL_LOCK ||
  path.join(BRIDGE_DIR, ".daemon-heal.lock");
const HEAL_LOG_PATH = process.env.NATIVE_AGENT_CODEX_HEAL_LOG ||
  path.join(BRIDGE_DIR, "daemon-heal.jsonl");

function appendHealLog(record) {
  try {
    ensureBridgeDir();
    fs.appendFileSync(HEAL_LOG_PATH, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  } catch {}
}

/// Foreground: detect drift cheaply and hand the actual restart to a
/// DETACHED background healer. The current wakeup proceeds against the old
/// daemon (one more empty, outcome-unknown turn at worst); the next invocation
/// lands on the healed daemon. The domain owner must not replay that turn just
/// because no final assistant text was returned.
function ensureDaemonVersionAligned() {
  if (daemonHealState.checked) return daemonHealState.record;
  daemonHealState.checked = true;
  // Foreground worst case is bounded: at most TWO control-start attempts
  // (4s timeout each), so a directory of broken installs cannot stack hung
  // spawns ahead of the 12s RPC budget under the app's 20s helper deadline.
  let attempts = 0;
  for (const candidate of codexCandidates()) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    if (attempts >= 2) return null;
    attempts += 1;
    const info = daemonControlStart(candidate);
    // Unparseable control output from one install must not disable healing —
    // try the next candidate.
    if (!info) continue;
    if (!daemonVersionsMismatch(info)) return null;
    const record = {
      action: "heal_scheduled",
      staleAppServerVersion: info.appServerVersion,
      cliVersion: info.cliVersion,
      at: nowISO(),
    };
    // Only a live owner means a heal is in flight. Dead-owner locks pass to
    // the healer's withDirLock recovery rather than blocking its spawn.
    if (fs.existsSync(HEAL_LOCK_DIR)) {
      if (dirLockOwnerAlive(HEAL_LOCK_DIR)) {
        record.action = "heal_already_in_flight";
        daemonHealState.record = record;
        return record;
      }
      record.orphanedHealLock = true;
    }
    try {
      const child = spawn(process.execPath, [__filename, "--heal-daemon"], {
        detached: true,
        stdio: "ignore",
        env: { ...process.env, NATIVE_AGENT_CODEX_WAKEUP_CONFIG: CONFIG_PATH },
      });
      child.unref();
      record.healerPid = child.pid || null;
    } catch (error) {
      record.action = "heal_spawn_failed";
      record.error = String((error && error.message) || error);
    }
    daemonHealState.record = record;
    return record;
  }
  return null;
}

/// Background healer (--heal-daemon): serialized by a cross-process lock;
/// re-checks the mismatch under the lock so racing healers converge, and
/// never unlinks a socket that has a live owner (a replacement daemon
/// started by someone else must not lose its pathname).
async function healDaemonVersionDrift() {
  try {
    return await withDirLock(HEAL_LOCK_DIR, async () => {
      for (const candidate of codexCandidates()) {
        if (!candidate || !fs.existsSync(candidate)) continue;
        const info = daemonControlStart(candidate);
        if (!info) continue;
        if (!daemonVersionsMismatch(info)) {
          const record = { action: "heal_noop_already_aligned", at: nowISO(), versions: info };
          appendHealLog(record);
          return record;
        }
        const record = {
          action: "heal",
          staleAppServerVersion: info.appServerVersion,
          cliVersion: info.cliVersion,
          at: nowISO(),
          healed: false,
        };
        if (!stopDaemonForRestart(candidate)) {
          record.reason = "stale_daemon_kill_failed";
          appendHealLog(record);
          return record;
        }
        // Identity-aware cleanup: only unlink an ORPHANED socket. A live
        // owner at this point is a replacement daemon someone else started.
        if (socketOwnerPid() == null) removeStaleSocket();
        const restarted = daemonControlStart(candidate);
        record.restart = restarted;
        record.healed = Boolean(restarted && !daemonVersionsMismatch(restarted));
        if (!record.healed) record.reason = "restart_version_still_mismatched";
        appendHealLog(record);
        return record;
      }
      const record = { action: "heal_no_codex_candidate", at: nowISO() };
      appendHealLog(record);
      return record;
    }, { waitMs: 0, preserveLiveOwner: true });
  } catch (error) {
    if (error && error.message === "lock_busy") {
      const record = { action: "heal_lock_busy", at: nowISO() };
      appendHealLog(record);
      return record;
    }
    const record = { action: "heal_failed", error: String((error && error.message) || error), at: nowISO() };
    appendHealLog(record);
    return record;
  }
}

/// Foreground repair for an app-server whose cwd inode was removed beneath
/// it. Unlike version drift, this must heal before the current `thread/start`:
/// the stale daemon cannot execute even one useful turn. The socket is the
/// bridge-dedicated app-server daemon, never an interactive Codex session.
async function ensureDaemonWorkingDirectoryAligned() {
  const initial = daemonWorkingDirectoryState();
  if (!initial.mismatch) return null;
  try {
    return await withDirLock(HEAL_LOCK_DIR, async () => {
      const state = daemonWorkingDirectoryState();
      if (!state.mismatch) {
        return { action: "cwd_heal_noop_already_aligned", at: nowISO(), state };
      }
      for (const candidate of codexCandidates()) {
        if (!candidate || !fs.existsSync(candidate)) continue;
        const record = {
          action: "cwd_heal",
          at: nowISO(),
          reason: state.status,
          stalePid: state.pid || null,
          cwd: state.cwd || null,
          observedInode: state.observedInode || null,
          currentInode: state.currentInode || null,
          healed: false,
        };
        if (!stopDaemonForRestart(candidate)) {
          record.failure = "stale_daemon_kill_failed";
          appendHealLog(record);
          daemonHealState.record = record;
          return record;
        }
        if (socketOwnerPid() == null) removeStaleSocket();
        record.restart = daemonControlStart(candidate);
        const after = daemonWorkingDirectoryState();
        record.after = after;
        record.healed = after.status === "ok" && !after.mismatch;
        if (!record.healed) record.failure = "restart_cwd_still_unavailable";
        appendHealLog(record);
        daemonHealState.record = record;
        return record;
      }
      const record = { action: "cwd_heal_no_codex_candidate", at: nowISO(), healed: false };
      appendHealLog(record);
      daemonHealState.record = record;
      return record;
    }, { waitMs: 8000, preserveLiveOwner: true });
  } catch (error) {
    const record = {
      action: "cwd_heal_failed",
      at: nowISO(),
      healed: false,
      error: String(error && error.message || error),
    };
    appendHealLog(record);
    daemonHealState.record = record;
    return record;
  }
}

function removeStaleSocket() {
  try {
    const stat = fs.lstatSync(SOCKET_PATH);
    if (stat.isSocket()) fs.unlinkSync(SOCKET_PATH);
  } catch {}
}

function recoverableSocketStartupError(error) {
  const code = error && error.code;
  const message = String(error && error.message || "");
  return code === "ECONNREFUSED"
    || code === "ENOENT"
    || code === "ECONNRESET"
    || message === "app_server_socket_closed";
}

async function connectRpc(timeoutMs) {
  ensureDaemon();
  // A public reinstall can recreate NativeAgent's workspace while the
  // bridge-dedicated Codex daemon survives. Repair that stale cwd inode before
  // initializing RPC; no user restart or second codex_message should be
  // required for the first fresh thread to work.
  await ensureDaemonWorkingDirectoryAligned();
  try {
    return await connectRpcOnce(timeoutMs);
  } catch (error) {
    if (!recoverableSocketStartupError(error)) throw error;

    if (error && (error.code === "ECONNREFUSED" || error.code === "ENOENT")) {
      // Owner-aware (same rule as the healer): a replacement daemon may have
      // bound the pathname between our failed connect and this cleanup —
      // unlinking a LIVE socket would strand that daemon. Only orphaned
      // sockets are removed.
      if (socketOwnerPid() == null) removeStaleSocket();
    }
    startDaemon();

    try {
      return await connectRpcOnce(timeoutMs);
    } catch (retryError) {
      retryError.detail = {
        ...(retryError.detail || {}),
        retryAfterDaemonStart: true,
        firstError: String(error && error.message || error),
        firstCode: error && error.code ? String(error.code) : undefined,
        socketPath: SOCKET_PATH,
        fix: "Open Codex Desktop or run `codex app-server daemon start`; remove a stale socket if the app-server is not listening.",
      };
      throw retryError;
    }
  }
}

async function withRpc(fn, timeoutMs = 12000) {
  const client = await connectRpc(timeoutMs);
  try {
    return await fn(client);
  } finally {
    client.close();
  }
}

async function readThreadState(client, threadId) {
  const result = await client.request("thread/read", { threadId, includeTurns: true });
  return threadStateFromThread(result && result.thread, threadId);
}

async function startTurnForEntries(
  client,
  threadId,
  entries,
  config,
  respectActive = true,
  ignoredActiveTurnIds = []
) {
  const ignored = Array.isArray(ignoredActiveTurnIds)
    ? ignoredActiveTurnIds
    : (ignoredActiveTurnIds ? [ignoredActiveTurnIds] : []);
  const resume = await client.request("thread/resume", { threadId });
  const resumeState = stateExcludingTurnIds(
    threadStateFromThread(resume && resume.thread, threadId),
    ignored
  );
  if (isUnhealthyThreadState(resumeState)) {
    return unhealthyThreadResult(threadId, resumeState, { delivery: "codex_app_server_resume" });
  }
  if (respectActive && resumeState.active) {
    return {
      status: "busy",
      reason: "thread_active_after_resume",
      threadId,
      activeStatus: resumeState.statusType,
      activeFlags: resumeState.activeFlags,
      inProgressTurnIds: resumeState.inProgressTurnIds,
    };
  }

  const priorTurnIds = Array.isArray(resume && resume.thread && resume.thread.turns)
    ? resume.thread.turns.map((turn) => turn && turn.id).filter(Boolean)
    : [];
  const admitted = await startTurnWithDurableReplyAdmission(
    client, threadId, entries, config, priorTurnIds
  );
  if (admitted.status !== "sent") return admitted;
  const turn = admitted.turn;
  return {
    status: "sent",
    delivery: "codex_app_server_turn_start",
    threadId,
    turnId: turn && turn.id ? turn.id : null,
    safePoint: "thread_idle",
    messageCount: entries.length,
    brain: { requested: brainControlsForEntries(entries, config) },
    replyDelivery: admitted.replyDelivery,
  };
}

async function startFreshThreadForEntries(client, entries, config) {
  const params = freshThreadStartParams(config, entries);
  const threadResponse = await client.request("thread/start", params);
  const thread = threadResponse && threadResponse.thread;
  const threadId = thread && thread.id ? thread.id : null;
  if (!threadId) {
    return {
      status: "failed",
      reason: "thread_start_missing_thread_id",
      delivery: "codex_app_server_thread_start",
      threadResponse,
    };
  }

  const admitted = await startTurnWithDurableReplyAdmission(
    client, threadId, entries, config, []
  );
  if (admitted.status !== "sent") return admitted;
  const turn = admitted.turn;
  const requestedBrain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  return {
    status: "sent",
    delivery: "codex_app_server_fresh_thread_turn_start",
    mode: FRESH_THREAD_MODE,
    threadId,
    turnId: turn && turn.id ? turn.id : null,
    safePoint: "fresh_thread",
    messageCount: entries.length,
    threadPath: thread && thread.path ? thread.path : null,
    cwd: params.cwd,
    sandbox: params.sandbox,
    networkAccess: execution.networkAccess,
    writableRoots: execution.writableRoots,
    approvalPolicy: params.approvalPolicy,
    brain: {
      requested: requestedBrain,
      effective: {
        model: requestedBrain.model || threadResponse && threadResponse.model || null,
        reasoningEffort: requestedBrain.reasoningEffort || threadResponse && threadResponse.reasoningEffort || null,
        serviceTier: requestedBrain.serviceTier || threadResponse && threadResponse.serviceTier || null,
      },
    },
    replyDelivery: admitted.replyDelivery,
  };
}

function ensureBridgeDir() {
  fs.mkdirSync(BRIDGE_DIR, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(BRIDGE_DIR, 0o700); } catch {}
}

function appendJSONL(file, obj) {
  ensureBridgeDir();
  const line = `${JSON.stringify(obj)}\n`;
  appendSyncedWakeLine(file, () => line);
}

function writeJSONAtomic(file, obj) {
  writeAtomic(file, () => JSON.stringify(obj, null, 2));
}

function writeTextAtomic(file, text) {
  writeAtomic(file, () => text);
}

function writeAtomic(file, contents) {
  ensureBridgeDir();
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${Date.now()}.${crypto.randomUUID()}.tmp`;
  let renamed = false;
  try {
    const fd = fs.openSync(tmp, "wx", 0o600);
    writeSyncedAndClose(fd, contents);
    fs.renameSync(tmp, file);
    renamed = true;
    try { fs.chmodSync(file, 0o600); } catch {}
    fsyncDirectorySync(dir);
  } finally {
    if (!renamed) {
      try { fs.unlinkSync(tmp); } catch {}
    }
  }
}

function readJSONLines(file) {
  try {
    return Array.from(readWakeJSONLines(fs.readFileSync(file, "utf8")), ({ value }) => value);
  } catch {
    return [];
  }
}

function appendJSONLineAtomicUnlocked(file, record) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const lines = readJSONLines(file)
    .slice(-4999)
    .map((row) => JSON.stringify(row));
  lines.push(JSON.stringify(record));
  writeTextAtomic(file, `${lines.join("\n")}\n`);
}

async function appendReplyDeliveryReceipt(receipt) {
  const lockDir = `${REPLY_DELIVERIES_PATH}.append.lock`;
  await withDirLock(lockDir, async () => {
    appendJSONL(REPLY_DELIVERIES_PATH, receipt);
    let size = 0;
    try { size = fs.statSync(REPLY_DELIVERIES_PATH).size; } catch {}
    const maxBytes = 16 * 1024 * 1024;
    if (size <= maxBytes) return;
    let lines = fs.readFileSync(REPLY_DELIVERIES_PATH, "utf8")
      .split("\n")
      .filter((line) => line.trim() !== "")
      .slice(-5000);
    while (lines.length > 1 && Buffer.byteLength(`${lines.join("\n")}\n`) > maxBytes) {
      lines.shift();
    }
    writeTextAtomic(REPLY_DELIVERIES_PATH, `${lines.join("\n")}\n`);
  }, { waitMs: 10000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
}

async function appendHangWatchdogReceipt(receipt, config) {
  const receiptsPath = stringSetting(
    config,
    "hangWatchdogReceiptsPath",
    "NATIVE_AGENT_CODEX_HANG_WATCHDOG_RECEIPTS_PATH",
    HANG_WATCHDOG_RECEIPTS_PATH
  );
  return appendLockedWakeReceipt(receiptsPath, receipt);
}

async function appendStaleWakeRecoveryReceipt(receipt, config) {
  const receiptsPath = stringSetting(
    config,
    "staleWakeRecoveriesPath",
    "NATIVE_AGENT_CODEX_STALE_WAKE_RECOVERIES_PATH",
    STALE_WAKE_RECOVERIES_PATH
  );
  return appendLockedWakeReceipt(receiptsPath, receipt);
}

async function appendLockedWakeReceipt(receiptsPath, receipt) {
  fs.mkdirSync(path.dirname(receiptsPath), { recursive: true, mode: 0o700 });
  await withDirLock(`${receiptsPath}.append.lock`, async () => {
    appendJSONL(receiptsPath, receipt);
  }, { waitMs: 10000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
  return receiptsPath;
}

function summarizeExecutionAttempts(attempts) {
  return (Array.isArray(attempts) ? attempts : []).map((attempt) => {
    const result = attempt && attempt.turnResult;
    return {
      threadId: attempt && attempt.threadId || null,
      turnId: attempt && attempt.turnId || null,
      ...(attempt && attempt.brain ? { brain: attempt.brain } : {}),
      turnResult: result ? {
        status: result.status || null,
        completedAt: result.completedAt || null,
        durationMs: result.durationMs || null,
        execution: result.execution || "codex_app_server",
        waitSource: result.waitSource || null,
        messageLength: typeof result.message === "string" ? result.message.length : 0,
        messageDigest: typeof result.message === "string"
          ? crypto.createHash("sha256").update(result.message).digest("hex")
          : null,
        errorMessage: result.errorMessage || null,
        codexErrorInfo: result.codexErrorInfo || null,
        noWorkObserved: result.noWorkObserved ?? null,
      } : null,
    };
  });
}

function startDrainProcess(config) {
  if (boolSetting(config, "disableDrain", "NATIVE_AGENT_CODEX_WAKEUP_NO_DRAIN", false)) {
    return { status: "skipped", reason: "drain_disabled" };
  }
  try {
    const child = spawn(process.execPath, [__filename, "--drain"], {
      cwd: process.cwd(),
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        NATIVE_AGENT_CODEX_WAKEUP_CONFIG: CONFIG_PATH,
        NATIVE_AGENT_CODEX_PENDING_PATH: pendingPath(),
        NATIVE_AGENT_CODEX_PENDING_LOCK: queueLockDir(),
        NATIVE_AGENT_CODEX_WAKE_LANES_DIR: WAKE_LANES_DIR,
        NATIVE_AGENT_CODEX_WAKE_CAPACITY_DIR: WAKE_CAPACITY_DIR,
        NATIVE_AGENT_CODEX_STALE_WAKE_RECOVERIES_PATH: STALE_WAKE_RECOVERIES_PATH,
      },
    });
    child.unref();
    return { status: "started", pid: child.pid || null };
  } catch (error) {
    return { status: "failed", reason: "drain_spawn_failed", error: String(error.message || error) };
  }
}

function replyJobChildEnvironment() {
  return {
    ...process.env,
    NATIVE_AGENT_CODEX_WAKEUP_CONFIG: CONFIG_PATH,
    NATIVE_AGENT_CODEX_PENDING_PATH: pendingPath(),
    NATIVE_AGENT_CODEX_PENDING_LOCK: queueLockDir(),
    NATIVE_AGENT_CODEX_WAKE_LANES_DIR: WAKE_LANES_DIR,
    NATIVE_AGENT_CODEX_WAKE_CAPACITY_DIR: WAKE_CAPACITY_DIR,
    NATIVE_AGENT_CODEX_STALE_WAKE_RECOVERIES_PATH: STALE_WAKE_RECOVERIES_PATH,
    NATIVE_AGENT_CODEX_REPLY_JOBS_DIR: REPLY_JOBS_DIR,
    NATIVE_AGENT_CODEX_REPLY_DELIVERIES_PATH: REPLY_DELIVERIES_PATH,
    NATIVE_AGENT_CODEX_REPLY_RECOVERY_LOCK: REPLY_RECOVERY_LOCK_DIR,
  };
}

function spawnReplyJob(jobPath) {
  const child = spawn(process.execPath, [__filename, "--deliver-reply", jobPath], {
    cwd: process.cwd(),
    detached: true,
    stdio: "ignore",
    env: replyJobChildEnvironment(),
  });
  child.unref();
  return { status: "watcher_started", pid: child.pid || null, jobPath };
}

function replyAdmissionJob(config, threadId, entries, priorTurnIds = [], options = {}) {
  if (!boolSetting(config, "deliverReplies", "NATIVE_AGENT_CODEX_DELIVER_REPLIES", true)) {
    return { status: "skipped", reason: "reply_delivery_disabled" };
  }
  const jobsDir = options.jobsDir || REPLY_JOBS_DIR;
  const clientUserMessageId = clientUserMessageIdForEntries(entries);
  const hangRetryCount = Math.max(0, ...entries.map((entry) => Number(entry && entry.hangRetryCount || 0)));
  const id = stableUUID(`codex-reply:${threadId}:${clientUserMessageId}`);
  const jobPath = path.join(jobsDir, `${safeFilePart(clientUserMessageId)}-${safeFilePart(id)}.json`);
  return {
    status: "reserved",
    jobPath,
    job: {
      id,
      phase: "turn_start_reserved",
      createdAt: nowISO(),
      threadId,
      turnId: null,
      clientUserMessageId,
      hangRetryCount,
      priorTurnIds: [...new Set(priorTurnIds.filter(Boolean))],
      entries: entries.map((entry) => ({
        id: entry.id || null,
        key: entry.key || null,
        hangRetryCount: Number(entry.hangRetryCount || 0),
        payload: sanitizePayload(entry.payload || {}),
      })),
    },
  };
}

async function startTurnWithDurableReplyAdmission(
  client,
  threadId,
  entries,
  config,
  priorTurnIds = [],
  options = {}
) {
  const reservation = replyAdmissionJob(config, threadId, entries, priorTurnIds, options);
  if (reservation.status === "skipped") {
    const turnResponse = await client.request("turn/start", turnStartParams(threadId, entries, config));
    return {
      status: "sent",
      turn: turnResponse && turnResponse.turn,
      replyDelivery: reservation,
    };
  }
  const spawnJob = options.spawnJob || spawnReplyJob;
  fs.mkdirSync(path.dirname(reservation.jobPath), { recursive: true, mode: 0o700 });
  const lockDir = `${reservation.jobPath}.admission.lock`;
  return await withDirLock(lockDir, async () => {
    let job = reservation.job;
    let existed = false;
    try {
      job = JSON.parse(fs.readFileSync(reservation.jobPath, "utf8"));
      existed = true;
    } catch (error) {
      if (error && error.code !== "ENOENT") return quarantineReplyJob(reservation.jobPath, error);
      writeJSONAtomic(reservation.jobPath, job);
    }
    if (job.id !== reservation.job.id || job.threadId !== threadId
        || job.clientUserMessageId !== reservation.job.clientUserMessageId) {
      return { status: "failed", reason: "reply_admission_identity_conflict" };
    }

    let turn = job.turnId ? { id: job.turnId } : null;
    if (!turn && existed) {
      const read = await client.request("thread/read", { threadId, includeTurns: true });
      const prior = new Set(Array.isArray(job.priorTurnIds) ? job.priorTurnIds : []);
      const candidates = Array.isArray(read && read.thread && read.thread.turns)
        ? read.thread.turns.filter((candidate) => candidate && candidate.id && !prior.has(candidate.id))
        : [];
      if (candidates.length > 1) {
        job.phase = "admission_outcome_unknown";
        job.admissionDetail = "multiple_post_reservation_turns";
        writeJSONAtomic(reservation.jobPath, job);
        return { status: "failed", reason: "reply_admission_outcome_unknown" };
      }
      if (candidates.length === 1) turn = candidates[0];
    }
    if (!turn) {
      // The reservation is durable before this call. If the RPC response is
      // lost, recovery rereads the exact thread and binds the one new turn;
      // it never blindly starts a second Codex task.
      const response = await client.request(
        "turn/start", turnStartParams(threadId, job.entries, config)
      );
      turn = response && response.turn;
    }
    if (!turn || !turn.id) {
      return { status: "failed", reason: "turn_start_missing_turn_id" };
    }
    job.phase = "watching_turn";
    job.turnId = turn.id;
    job.appServer = captureAppServerIdentity();
    job.boundAt = nowISO();
    writeJSONAtomic(reservation.jobPath, job);
    const watcher = await spawnJob(reservation.jobPath);
    return {
      status: "sent",
      turn,
      replyDelivery: {
        status: "watcher_started",
        delivery: "nativeagent_bridge_message_after_codex_turn",
        pid: watcher && watcher.pid || null,
        jobPath: reservation.jobPath,
        deliveriesPath: REPLY_DELIVERIES_PATH,
        recoveredAdmission: existed,
      },
    };
  }, { waitMs: 2000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
}

function startReplyWatcher(config, threadId, turnId, entries) {
  if (!turnId) {
    return { status: "skipped", reason: "turn_id_missing" };
  }
  if (!boolSetting(config, "deliverReplies", "NATIVE_AGENT_CODEX_DELIVER_REPLIES", true)) {
    return { status: "skipped", reason: "reply_delivery_disabled" };
  }
  try {
    ensureBridgeDir();
    fs.mkdirSync(REPLY_JOBS_DIR, { recursive: true, mode: 0o700 });
    const job = {
      id: stableUUID(`codex-reply:${threadId}:${turnId}`),
      createdAt: nowISO(),
      threadId,
      turnId,
      hangRetryCount: Math.max(0, ...entries.map((entry) => Number(entry && entry.hangRetryCount || 0))),
      appServer: captureAppServerIdentity(),
      entries: entries.map((entry) => ({
        id: entry.id || null,
        key: entry.key || null,
        hangRetryCount: Number(entry.hangRetryCount || 0),
        payload: sanitizePayload(entry.payload || {}),
      })),
    };
    const jobPath = path.join(REPLY_JOBS_DIR, `${safeFilePart(turnId)}-${safeFilePart(job.id)}.json`);
    writeJSONAtomic(jobPath, job);
    const watcher = spawnReplyJob(jobPath);
    return {
      status: "watcher_started",
      delivery: "nativeagent_bridge_message_after_codex_turn",
      pid: watcher.pid,
      jobPath,
      deliveriesPath: REPLY_DELIVERIES_PATH,
    };
  } catch (error) {
    return { status: "failed", reason: "reply_watcher_spawn_failed", error: String(error.message || error) };
  }
}

async function attachConsumeAndReplyDelivery(result, entries, config, options = {}) {
  if (result && result.status === "sent") {
    const startWatcher = options.startReplyWatcher || startReplyWatcher;
    const consume = options.markInboxConsumed || markInboxConsumed;
    result.replyDelivery = result.replyDelivery
      || startWatcher(config, result.threadId, result.turnId, entries);
    // The inbox remains recoverable until the completion job itself is durable.
    // An explicit no-reply policy is the sole exception because no job is
    // expected by configuration. Spawn/preflight failures leave it unconsumed.
    if (result.replyDelivery.status === "watcher_started"
        || (result.replyDelivery.status === "skipped"
          && result.replyDelivery.reason === "reply_delivery_disabled")) {
      result.consume = await consume(entries, result);
    } else {
      result.consume = { status: "deferred", reason: "reply_job_not_durable" };
    }
  }
  return result;
}

async function inspectBridgeThread(threadId, config = {}, connect = connectRpcOnce) {
  const canonicalId = canonicalCodexThreadId(threadId);
  if (!canonicalId) return { status: "failed", reason: "target_thread_missing" };
  // Diagnostics must never ensure/restart the daemon, resume a thread, or
  // create a writer. In particular do not replace this with withRpc().
  let client;
  try {
    client = await connect(12000);
    const { thread } = await client.request("thread/read", { threadId: canonicalId, includeTurns: true });
    if (!thread || thread.id !== canonicalId) throw new Error("thread_identity_mismatch");
    const state = threadStateFromThread(thread, canonicalId);
    const turn = Array.isArray(thread.turns) ? thread.turns.at(-1) : null;
    const rolloutPath = turn ? findThreadRolloutPath(canonicalId, config) : null;
    const terminal = turn && (extractTurnResultFromThread(thread, turn.id, rolloutPath)
      || (rolloutPath && extractTurnResultFromRollout(rolloutPath, turn.id)));
    return {
      status: "ok",
      source: "bridge_app_server",
      ...state,
      turnId: turn?.id || null,
      reportedTurnStatus: turn?.status || null,
      outcome: terminal?.status || (state.active ? "in_progress" : "unknown"),
      replaySafe: false,
      note: "Runtime status is server-local. Unknown/notLoaded is not cancellation or permission to launch replacement work.",
    };
  } catch (error) {
    return { status: "unavailable", source: "bridge_app_server", threadId: canonicalId,
      outcome: "unknown", replaySafe: false, reason: redactDiagnosticText(String(error?.message || error)) };
  } finally {
    if (client) client.close();
  }
}

function queueFingerprint(entries) {
  const normalized = Array.isArray(entries) ? entries : [];
  return crypto.createHash("sha256").update(JSON.stringify(normalized)).digest("hex");
}

function threadActivityChanged(previous, current) {
  if (!previous || !current) return false;
  if (Boolean(previous.active) !== Boolean(current.active)) return true;
  const before = [...new Set(previous.inProgressTurnIds || [])].sort();
  const after = [...new Set(current.inProgressTurnIds || [])].sort();
  return JSON.stringify(before) !== JSON.stringify(after);
}

async function waitForPendingDrainInvalidation(
  busyStates,
  expectedQueueFingerprint,
  config,
  deadline,
  failureRetryMs = 0,
  clientOverride = undefined
) {
  const states = Array.isArray(busyStates) ? busyStates.filter(Boolean) : [];
  const requestTimeoutMs = numberSetting(
    config,
    "requestTimeoutMs",
    "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS",
    12000
  );
  let client = clientOverride === undefined ? null : clientOverride;
  if (clientOverride === undefined && states.length > 0) {
    try { client = await connectRpc(requestTimeoutMs); } catch {}
  }

  const waiter = createWakeEventWaiter(() => {
    if (client) client.close();
    client = null;
  });
  const { cleanup, promise, close } = waiter;

  function signal(source) {
    waiter.signal({ source });
  }

  const stateByThread = new Map(states
    .filter((state) => state.threadId)
    .map((state) => [state.threadId, state]));
  if (client && typeof client.onNotification === "function") {
    cleanup.push(client.onNotification((message) => {
      if (!message || message.method !== "turn/completed") return;
      const params = message.params;
      const previous = params && stateByThread.get(params.threadId);
      if (!previous || !params.turn) return;
      const activeIds = new Set(previous.inProgressTurnIds || []);
      if (activeIds.size > 0 && !activeIds.has(params.turn.id)) return;
      signal("turn_completed_notification");
    }));
  }
  if (client && typeof client.onDisconnect === "function") {
    cleanup.push(client.onDisconnect(() => signal("app_server_disconnect")));
  }

  function watchFile(filePath, source) {
    if (!filePath || !fs.existsSync(filePath)) return;
    const initial = safeFileStat(filePath);
    try {
      const watcher = fs.watch(filePath, { persistent: false }, () => {
        const current = safeFileStat(filePath);
        if (sameFileStat(initial, current)) return;
        signal(source);
      });
      cleanup.push(() => watcher.close());
    } catch {}
  }

  const watchedPendingPath = typeof config.pendingPath === "string" && config.pendingPath
    ? config.pendingPath
    : pendingPath();
  watchFile(watchedPendingPath, "pending_queue_event");

  const watchedRollouts = new Set();
  const unresolvedThreadIds = new Set();
  for (const state of states) {
    const rolloutPath = state.rolloutPath || findThreadRolloutPath(state.threadId, config);
    if (rolloutPath && !watchedRollouts.has(rolloutPath)) {
      watchedRollouts.add(rolloutPath);
      watchFile(rolloutPath, "rollout_file_event");
    } else if (!rolloutPath && state.threadId) {
      unresolvedThreadIds.add(state.threadId);
    }
  }
  if (unresolvedThreadIds.size > 0) {
    const sessionsRoot = path.join(CODEX_HOME, "sessions");
    if (fs.existsSync(sessionsRoot)) {
      try {
        const watcher = fs.watch(sessionsRoot, { persistent: false, recursive: true }, (_event, filename) => {
          const changed = filename == null ? "" : String(filename);
          if (changed && ![...unresolvedThreadIds].some((threadId) => changed.includes(threadId))) return;
          signal("rollout_file_event");
        });
        cleanup.push(() => watcher.close());
      } catch {}
    }
  }

  const remaining = Math.max(0, deadline - Date.now());
  const retryDelay = Math.max(0, Number(failureRetryMs) || 0);
  const delay = retryDelay > 0 ? Math.min(remaining, retryDelay) : remaining;
  const timerSource = retryDelay > 0 && retryDelay < remaining
    ? "failure_retry_deadline"
    : "drain_timeout";
  waiter.startTimeout({ source: timerSource }, delay);

  // Close registration races once. Further reads happen only after an exact
  // queue/rollout/RPC event or a failure-specific retry deadline.
  await new Promise((resolve) => setImmediate(resolve));
  if (queueFingerprint(readPendingAtPath(watchedPendingPath)) !== expectedQueueFingerprint) {
    signal("initial_queue_change");
  }
  if (!waiter.settled) {
    for (const previous of states) {
      const local = readLocalRolloutState(previous.threadId, config);
      if (threadActivityChanged(previous, local)) {
        signal("initial_thread_change");
        break;
      }
      if (client) {
        try {
          const result = await client.request("thread/read", {
            threadId: previous.threadId,
            includeTurns: true,
          });
          const current = threadStateFromThread(result && result.thread, previous.threadId);
          if (threadActivityChanged(previous, current)) {
            signal("initial_thread_change");
            break;
          }
        } catch {
          // Rollout/file events and the exact deadline remain authoritative.
        }
      }
    }
  }

  const event = await promise;
  close();
  return event;
}

function runCodexExecFallback(entries, config) {
  const brain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  const cwd = execution.cwd;
  const sandbox = execution.sandbox;
  const executable = codexCandidates().find((candidate) => fs.existsSync(candidate)) || "codex";
  const outputDir = stringSetting(
    config,
    "execFallbackOutputDir",
    "NATIVE_AGENT_CODEX_EXEC_FALLBACK_OUTPUT_DIR",
    BRIDGE_DIR
  );
  fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  const outputPath = path.join(outputDir, `.codex-exec-reply-${crypto.randomUUID()}.txt`);
  const args = [
    "exec",
    "--ephemeral",
    "--sandbox", sandbox,
    "-C", cwd,
    "--color", "never",
    "-o", outputPath,
  ];
  if (execution.networkAccess) {
    args.push("-c", "sandbox_workspace_write.network_access=true");
    for (const root of execution.writableRoots) {
      if (root !== cwd) args.push("--add-dir", root);
    }
  }
  if (brain.model) args.push("-m", brain.model);
  if (brain.reasoningEffort) args.push("-c", `model_reasoning_effort="${brain.reasoningEffort}"`);
  if (brain.serviceTier) args.push("-c", `service_tier="${brain.serviceTier}"`);
  args.push(formatBatchPrompt(entries));

  const timeoutMs = numberSetting(
    config,
    "execFallbackTimeoutMs",
    "NATIVE_AGENT_CODEX_EXEC_FALLBACK_TIMEOUT_MS",
    60 * 60 * 1000
  );
  const startedAt = Date.now();
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timeoutTriggered = false;
    let child;
    try {
      child = spawn(executable, args, {
        cwd,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      resolve({
        status: "failed",
        completedAt: nowISO(),
        durationMs: Date.now() - startedAt,
        message: "",
        execution: "codex_exec_fallback",
        error: String(error && error.message || error),
      });
      return;
    }

    const appendBounded = (current, chunk, cap = 64 * 1024) => {
      const next = current + chunk.toString("utf8");
      return next.length > cap ? next.slice(next.length - cap) : next;
    };
    child.stdout.on("data", (chunk) => { stdout = appendBounded(stdout, chunk); });
    child.stderr.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });

    const finish = (exitCode, timedOut = false, spawnError = null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      let lastMessage = "";
      try { lastMessage = fs.readFileSync(outputPath, "utf8").trim(); } catch {}
      try { fs.unlinkSync(outputPath); } catch {}
      const message = lastMessage || stdout.trim();
      let status = "failed";
      if (!timedOut && exitCode === 0) status = message ? "completed" : "completed_without_reply";
      resolve({
        status,
        completedAt: nowISO(),
        durationMs: Date.now() - startedAt,
        message,
        execution: "codex_exec_fallback",
        exitCode,
        timedOut,
        brain,
        cwd,
        sandbox,
        networkAccess: execution.networkAccess,
        writableRoots: execution.writableRoots,
        stderrPreview: redactDiagnosticText(spawnError || stderr).trim().slice(-4000),
      });
    };

    const timer = setTimeout(() => {
      timeoutTriggered = true;
      try { child.kill("SIGTERM"); } catch {}
      setTimeout(() => {
        if (!settled) {
          try { child.kill("SIGKILL"); } catch {}
          finish(null, true);
        }
      }, 1000).unref();
    }, timeoutMs);
    timer.unref();
    child.on("error", (error) => finish(null, false, String(error && error.message || error)));
    child.on("close", (code) => finish(code, timeoutTriggered));
  });
}

async function deliverReplyJobUnlocked(jobPath, config) {
  let job;
  try {
    job = JSON.parse(fs.readFileSync(jobPath, "utf8"));
  } catch (error) {
    return quarantineReplyJob(jobPath, error);
  }
  if (job.hangRecovery && job.hangRecovery.status === "requeued") {
    try {
      fs.unlinkSync(jobPath);
      fsyncDirectorySync(path.dirname(jobPath));
    } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
    }
    return {
      status: "requeued_after_hang",
      reason: "hang_autorecovery_already_admitted",
      jobPath,
      retryCount: Number(job.hangRecovery.retryCount || 0),
    };
  }
  if (!job.turnId) {
    let admission;
    try {
      admission = await withRpc(
        (client) => startTurnWithDurableReplyAdmission(
          client,
          job.threadId,
          Array.isArray(job.entries) ? job.entries : [],
          config,
          Array.isArray(job.priorTurnIds) ? job.priorTurnIds : [],
          { spawnJob: async () => ({ pid: null }) }
        ),
        numberSetting(config, "requestTimeoutMs", "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS", 12000)
      );
    } catch (error) {
      return {
        status: "failed",
        reason: "reply_admission_recovery_unavailable",
        jobPath,
        error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
      };
    }
    if (!admission || admission.status !== "sent" || !admission.turn || !admission.turn.id) {
      return {
        status: "failed",
        reason: admission && admission.reason || "reply_admission_recovery_failed",
        jobPath,
      };
    }
    job = JSON.parse(fs.readFileSync(jobPath, "utf8"));
  }
  if (!job.id || typeof job.id !== "string") {
    job.id = job.threadId && job.turnId
      ? stableUUID(`codex-reply:${job.threadId}:${job.turnId}`)
      : crypto.randomUUID();
    writeJSONAtomic(jobPath, job);
  }
  const entries = Array.isArray(job.entries) ? job.entries : [];
  let execution = job.completedExecution && job.completedExecution.turnResult
    ? job.completedExecution
    : null;
  if (!execution) {
    execution = await waitForDurableTerminalExecution(job, config, async (observed) => {
      // Timeout is a bounded wait interval, not evidence that the Codex turn
      // ended. Persist the observation and resubscribe to exact app-server/file
      // events; never synthesize a terminal reply or delete the job.
      job.lastWait = {
        observedAt: nowISO(),
        status: "pending",
        waitSource: observed.turnResult.waitSource || "exact_timeout",
        threadId: observed.threadId,
        turnId: observed.turnId,
      };
      writeJSONAtomic(jobPath, job);
    });
  }
  if (!job.completedExecution && execution.turnResult.status === "failed_hung") {
    const hangRecovery = await recoverHungTurn(job, execution, config);
    execution.turnResult.hangRecovery = hangRecovery;
    if (hangRecovery.status === "requeued") {
      job.phase = "hang_requeued";
      job.completedExecution = execution;
      job.hangRecovery = hangRecovery;
      delete job.lastWait;
      delete job.stallProbe;
      writeJSONAtomic(jobPath, job);
      fs.unlinkSync(jobPath);
      fsyncDirectorySync(path.dirname(jobPath));
      return {
        status: "requeued_after_hang",
        reason: "hang_autorecovery",
        jobPath,
        threadId: execution.threadId,
        turnId: execution.turnId,
        retryCount: hangRecovery.retryCount,
        drain: hangRecovery.drain,
      };
    }
  }
  if (!job.completedExecution) {
    job.completedExecution = execution;
    job.phase = "execution_completed";
    delete job.lastWait;
    delete job.stallProbe;
    writeJSONAtomic(jobPath, job);
  } else if (job.phase === "watching_turn") {
    // Legacy/recovered jobs could already carry the terminal execution while
    // retaining the pre-terminal watcher label. The execution is finished;
    // only bridge delivery remains unsettled.
    job.phase = "execution_completed";
    writeJSONAtomic(jobPath, job);
  }
  const turnResult = execution.turnResult;
  const sessionId = entries
    .map((entry) => entry && entry.payload && entry.payload.sessionId)
    .find((value) => typeof value === "string" && value.trim() !== "");
  const origin = entries
    .map((entry) => entry && entry.payload && entry.payload.origin)
    .find((value) => value && typeof value === "object" && !Array.isArray(value)) || null;
  const messageIds = entries.map((entry) => entry && entry.payload && entry.payload.messageId).filter(Boolean);
  const receiptOnly = shouldSuppressCompletionDelivery(entries, turnResult);
  const text = receiptOnly ? "" : formatCodexReplyForNativeAgent({
    ...job,
    turnId: execution.turnId,
    attemptCount: execution.attempts.length,
  }, turnResult);
  const completionMetadata = {
    deliveryId: job.id,
    origin,
    completion: {
      messageIds,
      codexStatus: turnResult.status,
      threadId: execution.threadId,
      turnId: execution.turnId,
      attemptCount: execution.attempts.length,
      execution: turnResult.execution || "codex_app_server",
      waitSource: turnResult.waitSource || null,
      errorMessage: turnResult.errorMessage || null,
      codexErrorInfo: turnResult.codexErrorInfo || null,
      noWorkObserved: turnResult.noWorkObserved ?? null,
      stallEvidence: turnResult.stallEvidence || null,
      hangEvidence: turnResult.hangEvidence || null,
      hangRecovery: turnResult.hangRecovery || null,
      connectorDiagnostics: turnResult.connectorDiagnostics || null,
    },
  };
  const bridge = receiptOnly
    ? {
      status: "delivered",
      reason: null,
      delivery: "receipt_only",
      sessionId: sessionId || null,
      replyStatus: "ok",
      nativeAgentSessionId: sessionId || null,
      nativeAgentReplyPreview: null,
      completionDelivery: { status: "not_requested", delivery: "receipt_only" },
    }
    : await postBridgeMessageWithRetry(
      () => postBridgeMessage(text, sessionId || "", config, completionMetadata),
      {
        maxAttempts: numberSetting(
          config, "bridgeDeliveryMaxAttempts",
          "NATIVE_AGENT_CODEX_BRIDGE_DELIVERY_MAX_ATTEMPTS", 4
        ),
        baseMs: numberSetting(
          config, "bridgeDeliveryRetryBaseMs",
          "NATIVE_AGENT_CODEX_BRIDGE_DELIVERY_RETRY_BASE_MS", 500
        ),
        capMs: numberSetting(
          config, "bridgeDeliveryRetryCapMs",
          "NATIVE_AGENT_CODEX_BRIDGE_DELIVERY_RETRY_CAP_MS", 8000
        ),
      }
    );
  persistReplyJobDeliveryState(jobPath, job, bridge);
  const receipt = {
    id: crypto.randomUUID(),
    createdAt: nowISO(),
    jobId: job.id || null,
    jobPath,
    threadId: execution.threadId,
    turnId: execution.turnId,
    initialThreadId: job.threadId,
    initialTurnId: job.turnId,
    messageIds,
    topics: entries.map((entry) => entry && entry.payload && entry.payload.topic).filter(Boolean),
    sessionId: sessionId || null,
    origin,
    attempts: summarizeExecutionAttempts(execution.attempts),
    turnResult: {
      status: turnResult.status,
      completedAt: turnResult.completedAt || null,
      durationMs: turnResult.durationMs || null,
      rolloutPath: turnResult.rolloutPath || null,
      execution: turnResult.execution || "codex_app_server",
      waitSource: turnResult.waitSource || null,
      exitCode: turnResult.exitCode ?? null,
      timedOut: turnResult.timedOut || false,
      stderrPreview: turnResult.stderrPreview || null,
      errorMessage: turnResult.errorMessage || null,
      codexErrorInfo: turnResult.codexErrorInfo || null,
      noWorkObserved: turnResult.noWorkObserved ?? null,
      stallEvidence: turnResult.stallEvidence || null,
      hangEvidence: turnResult.hangEvidence || null,
      hangRecovery: turnResult.hangRecovery || null,
      connectorDiagnostics: turnResult.connectorDiagnostics || null,
      brain: turnResult.brain || null,
      messagePreview: unicodePrefix(turnResult.message || "", 1000),
    },
    bridge,
  };
  await appendReplyDeliveryReceipt(receipt);
  const terminalBridgeReply = isTerminalBridgeReply(bridge);
  const jobFile = finalizeReplyJobFile(jobPath, bridge);
  return {
    jobFile,
    status: terminalBridgeReply
      ? bridge.replyStatus
      : (bridge.status === "delivered" || bridge.status === "dry_run" ? "delivered" : "failed"),
    delivery: receiptOnly ? "receipt_only_after_codex_turn" : "nativeagent_bridge_message_after_codex_turn",
    threadId: execution.threadId,
    turnId: execution.turnId,
    initialThreadId: job.threadId,
    initialTurnId: job.turnId,
    sessionId: sessionId || null,
    origin,
    attemptCount: execution.attempts.length,
    turnResult: turnResult.status,
    execution: turnResult.execution || "codex_app_server",
    waitSource: turnResult.waitSource || null,
    bridge,
    deliveriesPath: REPLY_DELIVERIES_PATH,
  };
}

function quarantineReplyJob(jobPath, error) {
  const quarantineDir = path.join(path.dirname(jobPath), "quarantine");
  try {
    fs.mkdirSync(quarantineDir, { recursive: true, mode: 0o700 });
    const target = path.join(
      quarantineDir,
      `${path.basename(jobPath)}.${Date.now()}.${crypto.randomUUID()}.corrupt`
    );
    fs.renameSync(jobPath, target);
    fsyncDirectorySync(path.dirname(jobPath));
    fsyncDirectorySync(quarantineDir);
    return {
      status: "quarantined",
      reason: "reply_job_corrupt",
      jobPath,
      quarantinePath: target,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 500),
    };
  } catch (quarantineError) {
    return {
      status: "failed",
      reason: "reply_job_read_failed_and_quarantine_failed",
      jobPath,
      error: unicodePrefix(redactDiagnosticText(String(quarantineError && quarantineError.message || quarantineError)), 500),
    };
  }
}

async function deliverReplyJob(jobPath, config, options = {}) {
  const lockDir = `${jobPath}.delivery.lock`;
  const deliver = options.deliver || (() => deliverReplyJobUnlocked(jobPath, config));
  try {
    return await withDirLock(
      lockDir,
      deliver,
      { waitMs: 0, staleMs: 2 * 60 * 60 * 1000, preserveLiveOwner: true }
    );
  } catch (error) {
    if (error && error.message === "lock_busy") {
      return { status: "already_running", reason: "reply_job_lock_busy", jobPath, lockDir };
    }
    throw error;
  }
}

function pendingBusyResult(entry, state, reason, extra = {}) {
  return {
    status: "busy",
    reason,
    delivery: "codex_app_server_deferred_until_idle",
    threadId: entry && entry.threadId || null,
    laneKey: entryLaneKey(entry),
    activeStatus: state && state.statusType || "unknown",
    activeFlags: state && state.activeFlags || [],
    inProgressTurnIds: state && state.inProgressTurnIds || [],
    busySource: state && state.source || "unknown",
    rolloutPath: state && state.rolloutPath || null,
    ...extra,
  };
}

async function consumePendingEntry(entry, config, options = {}) {
  const laneKey = entryLaneKey(entry);
  const runInLane = options.withWakeExecutionLane || withWakeExecutionLane;
  const readHead = options.pendingHeadForLane || pendingHeadForLane;
  const connect = options.withRpc || withRpc;
  const attach = options.attachConsumeAndReplyDelivery || attachConsumeAndReplyDelivery;
  const remove = options.removePending || removePending;
  const recoverStale = options.recoverStaleQueuedWake || recoverStaleQueuedWake;
  const laneOptions = options.laneOptions || {};

  try {
    return await runInLane(laneKey, config, async () => {
      // The filesystem lane lock decides exclusivity; the queue lock decides
      // order. Re-read the head only after owning the lane so a later process
      // cannot win an OS scheduling race over an earlier durable row.
      const head = await readHead(entry.id, laneKey);
      if (!head.isHead || !head.head) {
        return pendingBusyResult(entry, null, "lane_queue_order", {
          pendingCount: head.pendingCount,
          headEntryId: head.head && head.head.id || null,
        });
      }
      let current = head.head;
      if (options.executeEntry) return await options.executeEntry(current);

      const mode = current.mode === FRESH_THREAD_MODE || !current.threadId
        ? FRESH_THREAD_MODE
        : PINNED_THREAD_MODE;
      const timeoutMs = numberSetting(
        config,
        "requestTimeoutMs",
        "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS",
        12000
      );
      let ignoredTurnIds = Number(current.hangRetryCount || 0) > 0 && current.hungTurnId
        ? [current.hungTurnId]
        : [];
      let staleRecovery = null;

      if (mode === PINNED_THREAD_MODE) {
        const localState = stateExcludingTurnIds(
          readLocalRolloutState(current.threadId, config),
          ignoredTurnIds
        );
        const localCandidate = localState && (
          localState.active || (localState.staleInProgressTurnIds || []).length > 0
        );
        if (localCandidate) {
          staleRecovery = await recoverStale(current, localState, config, options.staleRecoveryOptions || {});
          if (staleRecovery.status === "requeued") {
            current = staleRecovery.entry || current;
            ignoredTurnIds = [...new Set([...ignoredTurnIds, ...staleRecovery.ignoredTurnIds])];
          } else if (staleRecovery.status === "released_terminal") {
            ignoredTurnIds = [...new Set([...ignoredTurnIds, staleRecovery.turnId])];
          } else if (localState.active || staleRecovery.status === "preserved_live") {
            return pendingBusyResult(current, localState, "thread_active", {
              staleRecovery,
              retryAfterMs: staleRecovery.retryAfterMs || null,
            });
          }
        }
      }

      const result = await connect(async (client) => {
        if (mode === FRESH_THREAD_MODE) {
          return await startFreshThreadForEntries(client, [current], config);
        }

        const rpcState = await readThreadState(client, current.threadId);
        let state = stateExcludingTurnIds(rpcState, ignoredTurnIds);
        if (isUnhealthyThreadState(state)) {
          return unhealthyThreadResult(current.threadId, state, {
            delivery: "codex_app_server_thread_read",
          });
        }
        if (state.active) {
          staleRecovery = await recoverStale(current, state, config, options.staleRecoveryOptions || {});
          if (staleRecovery.status === "requeued") {
            current = staleRecovery.entry || current;
            ignoredTurnIds = [...new Set([...ignoredTurnIds, ...staleRecovery.ignoredTurnIds])];
            state = stateExcludingTurnIds(state, ignoredTurnIds);
          } else if (staleRecovery.status === "released_terminal") {
            ignoredTurnIds = [...new Set([...ignoredTurnIds, staleRecovery.turnId])];
            state = stateExcludingTurnIds(state, ignoredTurnIds);
          }
          if (state.active || staleRecovery.status === "preserved_live") {
            return pendingBusyResult(current, state, "thread_active", {
              staleRecovery,
              retryAfterMs: staleRecovery.retryAfterMs || null,
            });
          }
        }
        return await startTurnForEntries(
          client,
          current.threadId,
          [current],
          config,
          true,
          ignoredTurnIds
        );
      }, timeoutMs);

      if (result.status !== "sent") return result;
      const sent = await attach(result, [current], config);
      await remove([current.id]);
      if (staleRecovery && staleRecovery.status === "requeued") {
        sent.staleRecovery = staleRecovery.recovery;
      }
      return sent;
    }, laneOptions);
  } catch (error) {
    if (error && error.message === "lock_busy") {
      return pendingBusyResult(entry, null, error.reason || "wake_lane_lock_busy", {
        lockDir: error.lockDir || null,
        capacity: error.capacity || null,
      });
    }
    return rpcFailure(error, entry && entry.threadId || null, { laneKey });
  }
}

async function enqueueWake(payload, threadId, mode, config) {
  const canonicalThread = canonicalCodexThreadId(threadId);
  const laneKey = wakeLaneKey(payload, canonicalThread, mode);
  const queued = await appendPending(payload, canonicalThread, {
    mode,
    laneKey,
    laneIdentityPayload: payload,
  });
  const result = await consumePendingEntry(queued.entry, config);
  if (result.status === "sent") return result;

  const drain = startDrainProcess(config);
  if (result.status === "busy") {
    return {
      status: "queued_pending_idle",
      reason: result.reason,
      delivery: "codex_app_server_deferred_until_idle",
      mode,
      threadId: canonicalThread,
      laneKey,
      pendingPath: pendingPath(),
      pendingCount: queued.pendingCount,
      alreadyQueued: queued.alreadyQueued,
      lanePosition: queued.lanePosition,
      activeStatus: result.activeStatus,
      activeFlags: result.activeFlags,
      inProgressTurnIds: result.inProgressTurnIds,
      busySource: result.busySource,
      rolloutPath: result.rolloutPath,
      staleRecovery: result.staleRecovery || null,
      drain,
    };
  }
  return {
    ...result,
    pendingPath: pendingPath(),
    pendingCount: queued.pendingCount,
    alreadyQueued: queued.alreadyQueued,
    laneKey,
    drain,
  };
}

async function requestTurnStart(payload, threadId, config) {
  const prompt = formatPrompt(payload);
  if (process.env.NATIVE_AGENT_CODEX_WAKEUP_DRY_RUN === "1") {
    return { status: "dry_run", threadId, promptBytes: Buffer.byteLength(prompt) };
  }

  return await enqueueWake(payload, threadId, PINNED_THREAD_MODE, config);
}

async function requestFreshThreadTurnStart(payload, config) {
  const prompt = formatPrompt(payload);
  const entries = [{
    id: crypto.randomUUID(),
    threadId: null,
    payload: sanitizePayload(payload),
  }];
  const params = freshThreadStartParams(config, entries);
  if (process.env.NATIVE_AGENT_CODEX_WAKEUP_DRY_RUN === "1") {
    const execution = executionPolicyForEntries(entries, config);
    return {
      status: "dry_run",
      delivery: "codex_app_server_fresh_thread_dry_run",
      mode: FRESH_THREAD_MODE,
      promptBytes: Buffer.byteLength(prompt),
      cwd: params.cwd,
      sandbox: params.sandbox,
      networkAccess: execution.networkAccess,
      writableRoots: execution.writableRoots,
      approvalPolicy: params.approvalPolicy,
      brain: brainControlsForEntries(entries, config),
    };
  }

  return await enqueueWake(payload, null, FRESH_THREAD_MODE, config);
}

async function drainPending(config, options = {}) {
  const drainTimeoutMs = numberSetting(config, "drainTimeoutMs", "NATIVE_AGENT_CODEX_DRAIN_TIMEOUT_MS", 30 * 60 * 1000);
  const failureRetryBaseMs = numberSetting(
    config,
    "drainFailureRetryBaseMs",
    "NATIVE_AGENT_CODEX_DRAIN_FAILURE_RETRY_BASE_MS",
    1000
  );
  const deadline = Date.now() + drainTimeoutMs;
  let delivered = 0;
  let lastBusy = null;
  let lastFailure = null;
  let lastReplyDelivery = null;
  let lastWakeSource = null;
  const heartbeat = options.heartbeat || createDrainerHeartbeat(config, options.heartbeatOptions || {});
  heartbeat.update(readPendingAtPath(pendingPath()).length, null);
  const heartbeatStartup = await heartbeat.start();
  if (heartbeatStartup.status === "refused") {
    return {
      status: "already_running",
      reason: "live_drainer_heartbeat",
      heartbeatPath: heartbeatStartup.heartbeatPath,
      priorPid: heartbeatStartup.prior && heartbeatStartup.prior.pid || null,
      receipt: heartbeatStartup.receipt,
    };
  }
  const consume = options.consumePendingEntry || consumePendingEntry;

  try {
    while (Date.now() < deadline) {
      const queue = await withDirLock(queueLockDir(), async () => readPendingUnlocked(), { waitMs: 2000 });
      heartbeat.update(queue.length, null);
      if (queue.length === 0) {
        return { status: "drained", delivered, pendingCount: 0 };
      }

      let madeProgress = false;
      let iterationFailure = false;
      let retryAttempt = 0;
      const busyStates = [];
      let capacityRetryMs = 0;
      const heads = firstPendingPerLane(queue);
      const results = await Promise.all(heads.map(async (entry) => {
        try {
          return { entry, result: await consume(entry, config, options.consumeOptions || {}) };
        } catch (error) {
          return { entry, error };
        }
      }));

      for (const item of results) {
        const { entry } = item;
        if (item.error) {
          lastFailure = rpcFailure(item.error, entry.threadId);
          iterationFailure = true;
          retryAttempt = Math.max(retryAttempt, Number(entry.attempts || 0) + 1);
          {
            const errorText = item.error && item.error.message
              ? item.error.message
              : String(item.error);
            if (isTerminalWakeFailure(entry, errorText)) {
              await deadLetterPendingEntry(entry, errorText, "terminal_rpc_failure");
              console.error(
                `wake ${entry.id} dead-lettered (threadId=${JSON.stringify(entry.threadId)}): ${errorText}`
              );
            } else {
              await bumpPendingAttempt(entry.id, errorText);
            }
          }
          continue;
        }
        const result = item.result;
        if (result.status === "busy") {
          lastBusy = result;
          busyStates.push(result);
          heartbeat.update(queue.length, result.inProgressTurnIds && result.inProgressTurnIds[0] || null);
          if (result.reason === "wake_capacity_busy" || result.reason === "wake_lane_lock_busy") {
            capacityRetryMs = capacityRetryMs === 0 ? 50 : Math.min(capacityRetryMs, 50);
          } else if (Number.isFinite(result.retryAfterMs) && result.retryAfterMs > 0) {
            capacityRetryMs = capacityRetryMs === 0
              ? result.retryAfterMs
              : Math.min(capacityRetryMs, result.retryAfterMs);
          }
          continue;
        }
        if (result.status === "sent") {
          lastReplyDelivery = result.replyDelivery || null;
          delivered += 1;
          madeProgress = true;
          continue;
        }
        lastFailure = result;
        iterationFailure = true;
        retryAttempt = Math.max(retryAttempt, Number(entry.attempts || 0) + 1);
        {
          const errorText = JSON.stringify(result);
          if (isTerminalWakeFailure(entry, errorText)) {
            await deadLetterPendingEntry(entry, errorText, "terminal_result");
            console.error(
              `wake ${entry.id} dead-lettered (threadId=${JSON.stringify(entry.threadId)}): ${unicodePrefix(errorText, 200)}`
            );
          } else {
            await bumpPendingAttempt(entry.id, errorText);
          }
        }
      }

      if (madeProgress) {
        heartbeat.update(Math.max(0, queue.length - delivered), null);
        continue;
      }

      const retryDelayMs = capacityRetryMs || (iterationFailure
          ? Math.min(30_000, failureRetryBaseMs * (2 ** Math.min(5, Math.max(0, retryAttempt - 1))))
          : 0);
      const event = await waitForPendingDrainInvalidation(
        busyStates,
        queueFingerprint(queue),
        config,
        deadline,
        retryDelayMs
      );
      lastWakeSource = event.source;
      if (event.source === "drain_timeout") break;
    }

    const remaining = await withDirLock(queueLockDir(), async () => readPendingUnlocked().length, { waitMs: 2000 });
    heartbeat.update(remaining, lastBusy && lastBusy.inProgressTurnIds && lastBusy.inProgressTurnIds[0] || null);
    return {
      status: "pending",
      reason: "drain_timeout",
      delivered,
      pendingCount: remaining,
      pendingPath: pendingPath(),
      lastBusy,
      lastFailure,
      lastReplyDelivery,
      lastWakeSource,
    };
  } finally {
    await heartbeat.stop();
  }
}

async function main() {
  const config = loadJSON(CONFIG_PATH);
  const readThreadIndex = process.argv.indexOf("--read-thread");
  if (readThreadIndex >= 0) {
    jsonOut(await inspectBridgeThread(process.argv[readThreadIndex + 1], config));
    return;
  }
  const deliverIndex = process.argv.indexOf("--deliver-reply");
  if (deliverIndex >= 0) {
    const jobPath = process.argv[deliverIndex + 1];
    if (!jobPath) {
      jsonOut({ status: "failed", reason: "reply_job_path_missing" });
      return;
    }
    try {
      jsonOut(await deliverReplyJob(jobPath, config));
    } catch (error) {
      jsonOut({ status: "failed", reason: "reply_delivery_failed", error: String(error && error.message || error), jobPath });
    }
    return;
  }

  if (process.argv.includes("--recover-reply-jobs")) {
    try {
      const recovery = await recoverReplyJobs(config);
      recovery.inboxTerminalRepair = await repairTerminalFromDeadLetters();
      jsonOut(recovery);
    } catch (error) {
      jsonOut({
        status: "failed",
        reason: "reply_job_recovery_failed",
        error: String(error && error.message || error),
      });
    }
    return;
  }

  if (process.argv.includes("--repair-consumed-from-deliveries")) {
    try {
      jsonOut(await repairConsumedFromDeliveries(config));
    } catch (error) {
      jsonOut({ status: "failed", reason: "repair_consumed_failed", error: String(error && error.message || error) });
    }
    return;
  }

  if (process.argv.includes("--heal-daemon")) {
    jsonOut(await healDaemonVersionDrift());
    return;
  }

  if (process.argv.includes("--probe")) {
    const mode = wakeupMode(config);
    const threadId = canonicalCodexThreadId(
      process.env.NATIVE_AGENT_CODEX_THREAD_ID || (mode === PINNED_THREAD_MODE ? config.threadId : null)
    );
    if (mode === PINNED_THREAD_MODE && !threadId) {
      fail("target_thread_missing", {
        mode,
        configPath: CONFIG_PATH,
        fix: "Set NATIVE_AGENT_CODEX_THREAD_ID or write {\"deliveryMode\":\"pinned_thread\",\"threadId\":\"<Codex thread id>\"} to the wakeup config.",
      });
    }
    try {
      const result = await withRpc(async (client) => {
        if (mode === FRESH_THREAD_MODE) {
          const params = freshThreadStartParams(config);
          return {
            status: "ok",
            delivery: "codex_app_server_probe",
            mode,
            freshThread: true,
            cwd: params.cwd,
            sandbox: params.sandbox,
            approvalPolicy: params.approvalPolicy,
            active: false,
            note: "Fresh-thread mode probes app-server connectivity without creating a Codex thread.",
          };
        }
        const resume = await client.request("thread/resume", { threadId });
        const state = threadStateFromThread(resume && resume.thread, threadId);
        if (isUnhealthyThreadState(state)) {
          return unhealthyThreadResult(threadId, state, { delivery: "codex_app_server_probe", mode });
        }
        return {
          status: "ok",
          delivery: "codex_app_server_probe",
          mode,
          threadId,
          active: state.active,
          activeStatus: state.statusType,
          activeFlags: state.activeFlags,
          inProgressTurnIds: state.inProgressTurnIds,
        };
      });
      jsonOut(result);
    } catch (error) {
      jsonOut({
        status: "failed",
        reason: "probe_failed",
        error: String(error && error.message || error),
        code: error && error.code ? String(error.code) : null,
        detail: error && error.detail ? error.detail : null,
      });
    }
    return;
  }

  if (process.argv.includes("--drain")) {
    try {
      jsonOut(await drainPending(config));
    } catch (error) {
      jsonOut({ status: "failed", reason: "drain_failed", error: String(error && error.message || error) });
    }
    return;
  }

  let payload;
  try {
    payload = JSON.parse(readStdin() || "{}");
  } catch (error) {
    fail("invalid_stdin_json", { error: String(error.message || error) });
  }

  const mode = wakeupMode(config, payload);
  const threadId = canonicalCodexThreadId(
    payload.threadId || process.env.NATIVE_AGENT_CODEX_THREAD_ID || (mode === PINNED_THREAD_MODE ? config.threadId : null)
  );
  if (mode === PINNED_THREAD_MODE && !threadId) {
    fail("target_thread_missing", {
      mode,
      configPath: CONFIG_PATH,
      fix: "Set NATIVE_AGENT_CODEX_THREAD_ID or write {\"deliveryMode\":\"pinned_thread\",\"threadId\":\"<Codex thread id>\"} to the wakeup config.",
    });
  }
  if (!payload.text || typeof payload.text !== "string") {
    fail("missing_text");
  }

  const result = mode === FRESH_THREAD_MODE
    ? await requestFreshThreadTurnStart(payload, config)
    : await requestTurnStart(payload, threadId, config);
  // Surface a version-drift daemon restart in the wakeup receipt so a heal
  // (or a failed heal) is auditable instead of silent.
  if (daemonHealState.record) result.daemonHeal = daemonHealState.record;
  jsonOut(result);
}

// Assemble lane owners before any command dispatch; durable state stays in the existing stores.
const { markInboxConsumed, markInboxTerminal, messageIdForPayload } =
  require("./codex_wake_inbox_projection.js").createCodexWakeInboxProjection({
    BRIDGE_DIR,
    inboxLockDir,
    // Queue admission supplies the lock and consumes terminal projection; defer the lookup.
    withDirLock: (...args) => withDirLock(...args),
    nowISO,
  });

const {
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
} = require("./wake_queue_admission.js").createCodexQueueAdmission({
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
});

const { createDrainerHeartbeat } = require("./codex_wake_heartbeat.js").createCodexWakeHeartbeat({
  DRAINER_HEARTBEAT_PATH,
  stringSetting,
  numberSetting,
  pidAlive,
  withDirLock,
  readJSONLines,
  appendJSONLineAtomicUnlocked,
});

const {
  findThreadRolloutPath,
  readLocalRolloutState,
  safeFileStat,
  sameFileStat,
  readCanonicalTurnResult,
  waitForTurnResultEventFirst,
  waitForTurnResultWithEmptyRetry,
  probeTurnLiveness,
  waitForDurableTerminalExecution
} = require("./wake_turn_observation.js").createCodexTurnObservation({
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
});

const {
  formatCodexReplyForNativeAgent,
  shouldSuppressCompletionDelivery,
  postBridgeMessage,
  bridgeDeliveryRetryable,
  bridgeDeliveryBackoffMs,
  postBridgeMessageWithRetry,
  replyJobDisposition,
  persistReplyJobDeliveryState,
  pruneUndeliveredReplyJobs,
  finalizeReplyJobFile,
  isTerminalBridgeReply
} = require("./wake_reply_delivery.js").createCodexReplyDelivery({
  BRIDGE_TOKEN_PATH,
  USER_NAME,
  codexReturnBridgeEndpoint,
  fsyncDirectorySync,
  nowISO,
  numberSetting,
  postWakeCompletion,
  readWakeBridgeToken,
  redactDiagnosticText,
  sleep,
  stringSetting,
  unicodePrefix,
  writeJSONAtomic
});

const {
  recoverHungTurn,
  recoverStaleQueuedWake,
  recoverReplyJobs,
  repairConsumedFromDeliveries,
  repairTerminalFromDeadLetters
} = require("./wake_recovery.js").createCodexRecovery({
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
});

if (require.main === module) {
  main().catch((error) => {
    jsonOut({ status: "failed", reason: "uncaught_error", error: String(error && error.message || error) });
    process.exit(0);
  });
}

module.exports = {
  appendPending,
  attachConsumeAndReplyDelivery,
  brainControlsForEntries,
  createDrainerHeartbeat,
  consumePendingEntry,
  canonicalCodexThreadId,
  isCodexNonThreadSentinel,
  isTerminalWakeFailure,
  deadLetterPendingEntry,
  markInboxTerminal,
  repairTerminalFromDeadLetters,
  removePending,
  wakeupMode,
  daemonVersionsMismatch,
  daemonWorkingDirectoryMismatch,
  daemonWorkingDirectoryState,
  parseLsofWorkingDirectory,
  deliverReplyJob,
  dirLockOwnerAlive,
  drainPending,
  entryLaneKey,
  extractTurnResultFromRollout,
  extractTurnResultFromThread,
  extractTurnResultFromTurn,
  inspectBridgeThread,
  formatCodexReplyForNativeAgent,
  unicodePrefix,
  shouldSuppressCompletionDelivery,
  formatBatchPrompt,
  formatPrompt,
  executionPolicyForEntries,
  freshThreadStartParams,
  postBridgeMessage,
  codexReturnBridgeEndpoint,
  readBridgeDescriptor,
  processStartIdentity,
  isTerminalBridgeReply,
  bridgeDeliveryRetryable,
  bridgeDeliveryBackoffMs,
  postBridgeMessageWithRetry,
  replyJobDisposition,
  persistReplyJobDeliveryState,
  finalizeReplyJobFile,
  pruneUndeliveredReplyJobs,
  quarantineReplyJob,
  readCanonicalTurnResult,
  redactDiagnosticText,
  recoverReplyJobs,
  recoverHungTurn,
  recoverStaleQueuedWake,
  runCodexExecFallback,
  sanitizePayload,
  stableUUID,
  firstPendingPerLane,
  startTurnWithDurableReplyAdmission,
  turnStartParams,
  unattendedServerRequestReply,
  waitForPendingDrainInvalidation,
  waitForDurableTerminalExecution,
  waitForTurnResultWithEmptyRetry,
  waitForTurnResultEventFirst,
  wakeConcurrencyCap,
  wakeLaneKey,
  wakeLaneLockPath,
  withWakeCapacity,
  withWakeExecutionLane,
  withDirLock,
};
