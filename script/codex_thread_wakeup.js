#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const CONFIG_PATH = process.env.NATIVE_AGENT_CODEX_WAKEUP_CONFIG ||
  path.join(os.homedir(), ".config", "codex-nativeagent-bridge", "wakeup.json");
const SOCKET_PATH = process.env.CODEX_APP_SERVER_SOCKET ||
  path.join(CODEX_HOME, "app-server-control", "app-server-control.sock");
const BRIDGE_DIR = path.dirname(CONFIG_PATH);
const PENDING_PATH = process.env.NATIVE_AGENT_CODEX_PENDING_PATH ||
  path.join(BRIDGE_DIR, "pending-wakeups.json");
const QUEUE_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_PENDING_LOCK ||
  path.join(BRIDGE_DIR, ".pending-wakeups.lock");
const DRAIN_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_DRAIN_LOCK ||
  path.join(BRIDGE_DIR, ".pending-wakeups-drain.lock");
const DRAINER_HEARTBEAT_PATH = process.env.NATIVE_AGENT_CODEX_DRAINER_HEARTBEAT_PATH ||
  path.join(BRIDGE_DIR, "drainer-heartbeat.jsonl");
const INBOX_LOCK_DIR = process.env.NATIVE_AGENT_CODEX_INBOX_LOCK ||
  path.join(BRIDGE_DIR, ".codex-inbox.lock");
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
const ROLLOUT_PATH_CACHE = new Map();
const UNHEALTHY_THREAD_STATUS_TYPES = new Set(["systemError"]);
const FRESH_THREAD_MODE = "fresh_thread";
const PINNED_THREAD_MODE = "pinned_thread";
const GITHUB_COMMAND_EXECUTION_PROFILE = "github-command-repository-network-v1";

function readStdin() {
  return fs.readFileSync(0, "utf8");
}

function jsonOut(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function fail(reason, extra = {}) {
  jsonOut({ status: "skipped", reason, ...extra });
  process.exit(0);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function loadJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
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

function nowISO() {
  return new Date().toISOString();
}

function safeFilePart(value) {
  return String(value || "")
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(0, 96) || crypto.randomUUID();
}

function stableUUID(value) {
  const bytes = Buffer.from(crypto.createHash("sha256").update(String(value)).digest().subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

let cachedCurrentProcessStartIdentity;
function processStartIdentity(pid) {
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart=,command="], {
    encoding: "utf8",
    timeout: 2000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0 || !String(result.stdout || "").trim()) return null;
  return crypto.createHash("sha256").update(String(result.stdout).trim()).digest("hex");
}

function currentProcessStartIdentity() {
  if (cachedCurrentProcessStartIdentity === undefined) {
    cachedCurrentProcessStartIdentity = processStartIdentity(process.pid);
  }
  return cachedCurrentProcessStartIdentity;
}

/// Whether a dir-lock's recorded owner is a live process (with a matching
/// start identity when one was recorded — a reused PID is not the owner).
/// Behavior-identical to the historical inline check in withDirLock: ANY
/// error in the read/kill/identity chain resolves via the EPERM test, so an
/// unreadable-but-permission-denied pid file conservatively reads as alive,
/// while a missing or garbage pid file reads as dead.
function dirLockOwnerAlive(lockDir, operations = {}) {
  const signal = operations.kill || ((pid, name) => process.kill(pid, name));
  const identity = operations.processStartIdentity || processStartIdentity;
  let ownerAlive = false;
  try {
    const ownerFields = fs.readFileSync(path.join(lockDir, "pid"), "utf8").split("\n");
    const ownerPID = Number(ownerFields[0]);
    if (Number.isInteger(ownerPID) && ownerPID > 0) {
      signal(ownerPID, 0);
      ownerAlive = true;
      // A live process with a different start identity means the PID was
      // reused after the original lock owner died. Legacy locks without an
      // identity retain the conservative old behavior.
      const recordedIdentity = ownerFields[2] || null;
      if (recordedIdentity) {
        ownerAlive = identity(ownerPID) === recordedIdentity;
      }
    }
  } catch (ownerError) {
    ownerAlive = Boolean(ownerError && ownerError.code === "EPERM");
  }
  return ownerAlive;
}

function redactDiagnosticText(value) {
  return String(value || "")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    .replace(/(["']?(?:access_token|refresh_token|api_key|token)["']?\s*[:=]\s*["']?)[^\s,"']+/gi, "$1[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g, "[REDACTED_JWT]")
    .replace(/\b(?:sk|ghp|github_pat|xox[baprs])[-_A-Za-z0-9]{12,}\b/g, "[REDACTED_TOKEN]");
}

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
  if (payload && typeof payload.threadId === "string" && payload.threadId.trim() !== "") {
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

// Version-drift self-heal (2026-07-16). A wakeup app-server daemon started
// before a codex upgrade keeps serving the OLD binary: turns start, inject
// the message, and complete in ~3s with ZERO model output and zero errors —
// every fresh-thread wakeup from Jul 12–16 died this way while codex's own
// sessions (new binaries) looked healthy. `codex app-server daemon start` is
// idempotent and reports BOTH versions, so every wakeup invocation checks the
// pair and restarts the daemon on mismatch. This socket serves ONLY bridge
// wakeups, so a restart cannot interrupt interactive codex sessions.
const daemonHealState = { checked: false, record: null };

function daemonControlStart(candidate) {
  // 4s, not 8s: this runs on the FOREGROUND wakeup path before the 12s RPC
  // budget, and the app's helper deadline is 20s — one hung control start
  // must leave room for the actual turn start (review round 2).
  const result = spawnSync(candidate, ["app-server", "daemon", "start"], {
    encoding: "utf8",
    timeout: 4000,
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

function daemonVersionsMismatch(info) {
  return Boolean(
    info &&
    typeof info.cliVersion === "string" && info.cliVersion !== "" &&
    typeof info.appServerVersion === "string" && info.appServerVersion !== "" &&
    info.cliVersion !== info.appServerVersion
  );
}

function socketOwnerPid() {
  const result = spawnSync("/usr/sbin/lsof", ["-t", SOCKET_PATH], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pid = parseInt(String(result.stdout || "").trim().split("\n")[0], 10);
  return Number.isFinite(pid) && pid > 1 ? pid : null;
}

function captureAppServerIdentity() {
  const pid = socketOwnerPid();
  if (pid == null) return null;
  return {
    pid,
    startIdentity: processStartIdentity(pid),
    socketPath: SOCKET_PATH,
  };
}

function parseLsofWorkingDirectory(output) {
  let pid = null;
  let inode = null;
  let cwd = null;
  for (const line of String(output || "").split("\n")) {
    if (line.startsWith("p")) {
      const value = parseInt(line.slice(1), 10);
      if (Number.isFinite(value) && value > 1) pid = value;
    } else if (line.startsWith("i")) {
      const value = line.slice(1).trim();
      if (value) inode = value;
    } else if (line.startsWith("n")) {
      const value = line.slice(1);
      if (value) cwd = value;
    }
  }
  return { pid, inode, cwd };
}

function daemonWorkingDirectoryMismatch(observed, current) {
  if (!observed || !current) return false;
  if (!observed.inode || current.inode == null) return false;
  return String(observed.inode) !== String(current.inode);
}

/// A bridge-owned Codex daemon can outlive an app uninstall. If its cwd was
/// the NativeAgent workspace, deleting and recreating that pathname leaves the
/// process pinned to the unlinked OLD inode. `thread/start` then fails with the
/// misleading app-server error "failed to load configuration: No such file or
/// directory" even though ~/.codex/config.toml and the new workspace exist.
/// lsof exposes the process-held inode; stat exposes the pathname's current
/// inode. Comparing both catches the replacement without guessing from the
/// RPC wording or restarting a healthy daemon whose cwd is simply elsewhere.
function daemonWorkingDirectoryState() {
  const pid = socketOwnerPid();
  if (pid == null) return { status: "no_owner", mismatch: false };
  const result = spawnSync("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Ffni"], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    return { status: "cwd_unavailable", mismatch: false, pid };
  }
  const observed = parseLsofWorkingDirectory(result.stdout);
  if (!observed.cwd) {
    return { status: "cwd_unavailable", mismatch: false, pid };
  }
  const displayedPath = observed.cwd.replace(/\s+\(deleted\)$/, "");
  let current;
  try {
    const stat = fs.statSync(displayedPath);
    current = { inode: stat.ino, cwd: displayedPath };
  } catch {
    return {
      status: "cwd_missing",
      mismatch: true,
      pid,
      cwd: displayedPath,
      observedInode: observed.inode,
    };
  }
  const mismatch = daemonWorkingDirectoryMismatch(observed, current);
  return {
    status: mismatch ? "cwd_replaced" : "ok",
    mismatch,
    pid,
    cwd: displayedPath,
    observedInode: observed.inode,
    currentInode: String(current.inode),
  };
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
    // try the next candidate (review round: broken standalone + healthy brew).
    if (!info) continue;
    if (!daemonVersionsMismatch(info)) return null;
    const record = {
      action: "heal_scheduled",
      staleAppServerVersion: info.appServerVersion,
      cliVersion: info.cliVersion,
      at: nowISO(),
    };
    // A bare existence check here permanently disabled self-heal after any
    // healer died mid-heal (SIGKILL/reboot skips its lock-reaping finally,
    // and no healer is ever spawned again to steal the orphan — audit round
    // 2, G2). Only a lock with a LIVE owner means a heal is in flight; a
    // dead-owner lock must not block the spawn — the healer's own
    // withDirLock (preserveLiveOwner) reclaims the orphan safely.
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

function wsFrame(text) {
  const payload = Buffer.from(text);
  const mask = crypto.randomBytes(4);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, 0x80 | payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i += 1) {
    masked[i] = payload[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function parseFrames(state, chunk, onText, socket) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  while (state.buffer.length >= 2) {
    const b0 = state.buffer[0];
    const b1 = state.buffer[1];
    let len = b1 & 0x7f;
    let offset = 2;
    if (len === 126) {
      if (state.buffer.length < 4) return;
      len = state.buffer.readUInt16BE(2);
      offset = 4;
    } else if (len === 127) {
      if (state.buffer.length < 10) return;
      len = Number(state.buffer.readBigUInt64BE(2));
      offset = 10;
    }
    let mask = null;
    if ((b1 & 0x80) !== 0) {
      if (state.buffer.length < offset + 4) return;
      mask = state.buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (state.buffer.length < offset + len) return;
    const payload = Buffer.from(state.buffer.subarray(offset, offset + len));
    state.buffer = state.buffer.subarray(offset + len);
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    const opcode = b0 & 0x0f;
    if (opcode === 1) onText(payload.toString("utf8"));
    if (opcode === 8) socket.end();
    if (opcode === 9) socket.write(Buffer.from([0x8a, 0x00]));
  }
}

function formatPrompt(payload) {
  const lines = [
    "NativeAgent sent Codex this message through its codex_message bridge.",
    "",
    `Priority: ${payload.priority || "info"}`,
  ];
  if (payload.topic) lines.push(`Topic: ${payload.topic}`);
  if (payload.messageId) lines.push(`Message id: ${payload.messageId}`);
  if (payload.queuedAt) lines.push(`Queued at: ${payload.queuedAt}`);
  if (trustedGitHubCommandWorkingDirectory([{ payload }])) {
    lines.push("This unattended GitHub bridge cannot answer Codex client approval, interactive-input, or app/MCP connector requests. Work in the verified local checkout with already-permitted noninteractive tools. If an external write is unavailable, return the exact blocker in the final text instead of waiting for a client response.");
  }
  lines.push("", payload.text || "", "");
  lines.push("Treat this as the local assistant speaking to Codex. If it needs work, handle it in this thread; if it is just status, acknowledge briefly. Always produce a final text answer, even when the task fails or no changes are needed, because NativeAgent uses that answer as the async completion receipt.");
  return lines.join("\n");
}

/// Codex app-server may ask its initiating client to execute a dynamic tool or
/// make an approval/elicitation decision. This bridge has no user in that
/// client loop and must never leave the turn waiting forever or invent consent.
/// Return the protocol's explicit failure/decline shape; app-server can then
/// feed the blocker back to the model so it can still produce a final receipt.
function unattendedServerRequestReply(message) {
  if (!message || message.id == null || typeof message.method !== "string") return null;
  const unavailable = "NativeAgent's unattended Codex bridge cannot execute client-owned tools or collect interactive approval. Use already-permitted local tools or return this blocker in the final result.";
  switch (message.method) {
    case "item/tool/call":
      return {
        result: {
          contentItems: [{ type: "inputText", text: unavailable }],
          success: false,
        },
      };
    case "item/commandExecution/requestApproval":
    case "item/fileChange/requestApproval":
      return { result: { decision: "decline" } };
    case "execCommandApproval":
    case "applyPatchApproval":
      return { result: { decision: "denied" } };
    case "mcpServer/elicitation/request":
      return { result: { action: "decline", content: null, _meta: null } };
    case "item/tool/requestUserInput":
    case "item/permissions/requestApproval":
      return { error: { code: -32001, message: unavailable } };
    default:
      return null;
  }
}

function formatBatchPrompt(entries) {
  if (entries.length === 1) return formatPrompt(entries[0].payload);
  const lines = [
    `NativeAgent sent Codex ${entries.length} queued messages through its codex_message bridge while this thread was busy.`,
    "",
  ];
  if (trustedGitHubCommandWorkingDirectory(entries)) {
    lines.push("This unattended GitHub bridge cannot answer Codex client approval, interactive-input, or app/MCP connector requests. Work in the verified local checkout with already-permitted noninteractive tools. If an external write is unavailable, return the exact blocker in the final text instead of waiting for a client response.", "");
  }
  for (const [index, entry] of entries.entries()) {
    const payload = entry.payload;
    lines.push(`Message ${index + 1}`);
    lines.push(`Priority: ${payload.priority || "info"}`);
    if (payload.topic) lines.push(`Topic: ${payload.topic}`);
    if (payload.messageId) lines.push(`Message id: ${payload.messageId}`);
    if (payload.queuedAt) lines.push(`Queued at: ${payload.queuedAt}`);
    lines.push("", payload.text || "", "");
  }
  lines.push("Treat these as the local assistant speaking to Codex. Handle anything actionable in this thread; if they are just status, acknowledge briefly. Always produce a final text answer, even when the task fails or no changes are needed, because NativeAgent uses that answer as the async completion receipt.");
  return lines.join("\n");
}

async function connectRpcOnce(timeoutMs) {
  if (!fs.existsSync(SOCKET_PATH)) {
    const error = new Error("app_server_socket_missing");
    error.detail = {
      socketPath: SOCKET_PATH,
      fix: "Run `codex app-server daemon start`, or open Codex Desktop with remote control enabled.",
    };
    throw error;
  }

  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
    const key = crypto.randomBytes(16).toString("base64");
    const state = { buffer: Buffer.alloc(0), handshaken: false, nextId: 1, ready: false, settled: false };
    const pending = new Map();
    const notificationListeners = new Set();
    const disconnectListeners = new Set();
    let initializeId = null;
    const readyTimer = setTimeout(() => {
      failReady(new Error("app_server_timeout"));
    }, timeoutMs);

    function failReady(error) {
      if (state.settled) return;
      state.settled = true;
      clearTimeout(readyTimer);
      try { socket.end(); } catch {}
      reject(error);
    }

    function send(method, params, withId = true) {
      const message = withId
        ? { id: state.nextId++, method, params }
        : { method, params };
      socket.write(wsFrame(JSON.stringify(message)));
      return message.id;
    }

    function rejectPending(error) {
      for (const { reject: rejectRequest, timer } of pending.values()) {
        clearTimeout(timer);
        rejectRequest(error);
      }
      pending.clear();
    }

    function emitNotification(message) {
      for (const listener of [...notificationListeners]) {
        try { listener(message); } catch {}
      }
    }

    function emitDisconnect(error) {
      for (const listener of [...disconnectListeners]) {
        try { listener(error); } catch {}
      }
    }

    function request(method, params, requestTimeoutMs = timeoutMs) {
      const id = send(method, params);
      return new Promise((resolveRequest, rejectRequest) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          const error = new Error(`${method}_timeout`);
          error.method = method;
          rejectRequest(error);
        }, requestTimeoutMs);
        pending.set(id, { method, resolve: resolveRequest, reject: rejectRequest, timer });
      });
    }

    function close() {
      rejectPending(new Error("app_server_client_closed"));
      notificationListeners.clear();
      disconnectListeners.clear();
      try { socket.end(); } catch {}
    }

    function onNotification(listener) {
      notificationListeners.add(listener);
      return () => notificationListeners.delete(listener);
    }

    function onDisconnect(listener) {
      disconnectListeners.add(listener);
      return () => disconnectListeners.delete(listener);
    }

    socket.on("connect", () => {
      socket.write([
        "GET / HTTP/1.1",
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n"));
    });

    socket.on("data", (chunk) => {
      state.buffer = Buffer.concat([state.buffer, chunk]);
      if (!state.handshaken) {
        const headerEnd = state.buffer.indexOf("\r\n\r\n");
        if (headerEnd < 0) return;
        const header = state.buffer.subarray(0, headerEnd).toString("utf8");
        state.buffer = state.buffer.subarray(headerEnd + 4);
        if (!header.startsWith("HTTP/1.1 101")) {
          const error = new Error("websocket_upgrade_failed");
          error.detail = header.split("\r\n")[0];
          failReady(error);
          return;
        }
        state.handshaken = true;
        initializeId = send("initialize", {
          clientInfo: { name: "nativeagent-codex-wakeup", title: "NativeAgent Codex Wakeup", version: "1.1" },
          capabilities: { experimentalApi: true },
        });
      }

      parseFrames(state, Buffer.alloc(0), (text) => {
        let message;
        try {
          message = JSON.parse(text);
        } catch {
          return;
        }
        if (message.id === initializeId) {
          if (message.error) {
            const error = new Error(message.error.message || "initialize_failed");
            error.detail = message.error;
            failReady(error);
            return;
          }
          send("initialized", {}, false);
          if (!state.settled) {
            state.settled = true;
            state.ready = true;
            clearTimeout(readyTimer);
            resolve({ request, close, onNotification, onDisconnect });
          }
          return;
        }
        if (message.id != null && pending.has(message.id)) {
          const item = pending.get(message.id);
          pending.delete(message.id);
          clearTimeout(item.timer);
          if (message.error) {
            const error = new Error(message.error.message || `${item.method}_failed`);
            error.method = item.method;
            error.detail = message.error;
            item.reject(error);
          } else {
            item.resolve(message.result);
          }
          return;
        }
        if (message.id != null && typeof message.method === "string") {
          const reply = unattendedServerRequestReply(message);
          if (reply) {
            socket.write(wsFrame(JSON.stringify({ id: message.id, ...reply })));
            return;
          }
        }
        if (message.id == null && typeof message.method === "string") {
          emitNotification(message);
        }
      }, socket);
    });

    socket.on("error", (error) => {
      if (!state.ready) {
        failReady(error);
      } else {
        rejectPending(error);
        emitDisconnect(error);
      }
    });

    socket.on("close", () => {
      if (!state.ready) {
        failReady(new Error("app_server_socket_closed"));
      } else {
        const error = new Error("app_server_socket_closed");
        rejectPending(error);
        emitDisconnect(error);
      }
    });
  });
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

function threadStateFromThread(thread, threadId) {
  const status = thread && thread.status ? thread.status : {};
  const turns = thread && Array.isArray(thread.turns) ? thread.turns : [];
  const inProgressTurns = turns.filter((turn) => turn && turn.status === "inProgress");
  return {
    threadId: (thread && thread.id) || threadId,
    statusType: status.type || "unknown",
    activeFlags: Array.isArray(status.activeFlags) ? status.activeFlags : [],
    inProgressTurnIds: inProgressTurns.map((turn) => turn.id).filter(Boolean),
    active: status.type === "active" || inProgressTurns.length > 0,
  };
}

function isUnhealthyThreadState(state) {
  return Boolean(state && UNHEALTHY_THREAD_STATUS_TYPES.has(state.statusType));
}

function unhealthyThreadResult(threadId, state, extra = {}) {
  return {
    status: "failed",
    reason: "target_thread_unhealthy",
    threadId,
    active: Boolean(state && state.active),
    activeStatus: state && state.statusType ? state.statusType : "unknown",
    activeFlags: state && Array.isArray(state.activeFlags) ? state.activeFlags : [],
    inProgressTurnIds: state && Array.isArray(state.inProgressTurnIds) ? state.inProgressTurnIds : [],
    fix: "Use deliveryMode=fresh_thread, or point pinned_thread mode at a healthy Codex thread.",
    ...extra,
  };
}

async function readThreadState(client, threadId) {
  const result = await client.request("thread/read", { threadId, includeTurns: true });
  return threadStateFromThread(result && result.thread, threadId);
}

function rpcFailure(error, threadId, extra = {}) {
  return {
    status: "failed",
    reason: error && error.message ? error.message : "app_server_error",
    threadId,
    error: String(error && error.message || error),
    ...(error && error.detail ? { detail: error.detail } : {}),
    ...extra,
  };
}

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

  const freshOpenTurns = [...openTurns.values()].filter((turn) => {
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
  };
}

function combineThreadStates(primary, secondary) {
  if (!primary) return secondary;
  if (!secondary) return primary;
  const unhealthy = isUnhealthyThreadState(primary)
    ? primary
    : (isUnhealthyThreadState(secondary) ? secondary : null);
  const ids = new Set([
    ...(primary.inProgressTurnIds || []),
    ...(secondary.inProgressTurnIds || []),
  ]);
  return {
    threadId: primary.threadId || secondary.threadId,
    source: `${primary.source || "primary"}+${secondary.source || "secondary"}`,
    rolloutPath: primary.rolloutPath || secondary.rolloutPath,
    active: Boolean(primary.active || secondary.active),
    statusType: unhealthy ? unhealthy.statusType : (primary.active || secondary.active ? "active" : (primary.statusType || secondary.statusType || "idle")),
    activeFlags: [...new Set([...(primary.activeFlags || []), ...(secondary.activeFlags || [])])],
    inProgressTurnIds: [...ids],
  };
}

function stateExcludingDeclaredHungTurn(state, entry) {
  const retryCount = Number(entry && entry.hangRetryCount || 0);
  const hungTurnId = entry && entry.hungTurnId;
  if (!state || retryCount <= 0 || !hungTurnId) return state;
  const inProgressTurnIds = (state.inProgressTurnIds || []).filter((id) => id !== hungTurnId);
  return {
    ...state,
    active: inProgressTurnIds.length > 0,
    statusType: inProgressTurnIds.length > 0 ? state.statusType : "idle",
    inProgressTurnIds,
  };
}

function clientUserMessageIdForEntries(entries) {
  const retryCount = Math.max(0, ...entries.map((entry) => Number(entry && entry.hangRetryCount || 0)));
  const retrySuffix = retryCount > 0 ? `-hang-retry-${retryCount}` : "";
  if (entries.length === 1) {
    const messageId = entries[0].payload.messageId || entries[0].id || crypto.randomUUID();
    return `nativeagent-codex-${messageId}${retrySuffix}`;
  }
  const key = entries
    .map((entry) => entry.payload.messageId || entry.id || "")
    .join("|");
  return `nativeagent-codex-batch-${crypto.createHash("sha256").update(key).digest("hex").slice(0, 24)}${retrySuffix}`;
}

async function startTurnForEntries(
  client,
  threadId,
  entries,
  config,
  respectActive = true,
  ignoredActiveTurnId = null
) {
  const resume = await client.request("thread/resume", { threadId });
  const resumeState = stateExcludingDeclaredHungTurn(
    threadStateFromThread(resume && resume.thread, threadId),
    ignoredActiveTurnId ? { hangRetryCount: 1, hungTurnId: ignoredActiveTurnId } : null
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

function brainControlsForEntries(entries, config) {
  const firstPayload = Array.isArray(entries) && entries[0] && entries[0].payload
    ? entries[0].payload
    : {};
  const controls = {};
  const model = typeof firstPayload.model === "string" && firstPayload.model
    ? firstPayload.model
    : stringSetting(config, "model", "NATIVE_AGENT_CODEX_WAKEUP_MODEL", "");
  const reasoningEffort = typeof firstPayload.reasoningEffort === "string" && firstPayload.reasoningEffort
    ? firstPayload.reasoningEffort
    : stringSetting(config, "reasoningEffort", "NATIVE_AGENT_CODEX_WAKEUP_REASONING_EFFORT", "");
  const serviceTier = typeof firstPayload.serviceTier === "string" && firstPayload.serviceTier
    ? firstPayload.serviceTier
    : stringSetting(config, "serviceTier", "NATIVE_AGENT_CODEX_WAKEUP_SERVICE_TIER", "");
  if (model) controls.model = model;
  if (reasoningEffort) controls.reasoningEffort = reasoningEffort;
  if (serviceTier) controls.serviceTier = serviceTier;
  return controls;
}

function trustedGitHubCommandWorkingDirectory(entries) {
  if (!Array.isArray(entries) || entries.length === 0) return null;
  const directories = new Set();
  for (const entry of entries) {
    const payload = entry && entry.payload;
    // Trust anchor is the app-verified executionProfile marker: the Swift
    // dispatcher only writes it for a checkout it resolved itself, and
    // sanitizePayload only preserves the exact constant. Any origin surface
    // (github-command, chat lanes, etc.) may carry it; a payload with no
    // origin at all still fails closed.
    if (!payload
        || payload.executionProfile !== GITHUB_COMMAND_EXECUTION_PROFILE
        || !payload.origin
        || typeof payload.origin.surface !== "string"
        || payload.origin.surface.trim() === ""
        || typeof payload.workingDirectory !== "string"
        || !path.isAbsolute(payload.workingDirectory)) return null;
    let stat;
    try { stat = fs.statSync(payload.workingDirectory); } catch { return null; }
    if (!stat.isDirectory()) return null;
    try {
      directories.add(path.normalize(fs.realpathSync(payload.workingDirectory)));
    } catch {
      return null;
    }
  }
  return directories.size === 1 ? [...directories][0] : null;
}

function repositoryWritableRoots(workingDirectory) {
  const roots = new Set([path.normalize(workingDirectory)]);
  const dotGit = path.join(workingDirectory, ".git");
  try {
    if (fs.statSync(dotGit).isDirectory()) roots.add(path.normalize(dotGit));
  } catch {}

  const result = spawnSync(
    "/usr/bin/git",
    ["-C", workingDirectory, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
    { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] }
  );
  if (result.status === 0) {
    for (const line of String(result.stdout || "").split("\n")) {
      const candidate = line.trim();
      if (!candidate || !path.isAbsolute(candidate)) continue;
      try {
        if (fs.statSync(candidate).isDirectory()) roots.add(path.normalize(candidate));
      } catch {}
    }
  }
  return [...roots];
}

function executionPolicyForEntries(entries, config) {
  const workingDirectories = [...new Set(entries
    .map((entry) => entry && entry.payload && entry.payload.workingDirectory)
    .filter((value) => typeof value === "string" && path.isAbsolute(value)))];
  const configuredCwd = stringSetting(config, "cwd", "NATIVE_AGENT_CODEX_WAKEUP_CWD", process.cwd());
  const configuredSandbox = enumStringSetting(
    config,
    "sandbox",
    "NATIVE_AGENT_CODEX_WAKEUP_SANDBOX",
    "danger-full-access",
    new Set(["read-only", "workspace-write", "danger-full-access"])
  );
  const trustedGitHubCwd = trustedGitHubCommandWorkingDirectory(entries);
  if (trustedGitHubCwd) {
    const writableRoots = repositoryWritableRoots(trustedGitHubCwd);
    return {
      cwd: trustedGitHubCwd,
      sandbox: "danger-full-access",
      sandboxPolicy: {
        type: "dangerFullAccess",
      },
      executionProfile: GITHUB_COMMAND_EXECUTION_PROFILE,
      networkAccess: true,
      writableRoots,
    };
  }
  return {
    cwd: workingDirectories.length === 1 ? workingDirectories[0] : configuredCwd,
    sandbox: configuredSandbox,
    sandboxPolicy: null,
    executionProfile: null,
    networkAccess: false,
    writableRoots: [],
  };
}

function freshThreadStartParams(config, entries = []) {
  const brain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  const params = {
    cwd: execution.cwd,
    approvalPolicy: enumStringSetting(
      config,
      "approvalPolicy",
      "NATIVE_AGENT_CODEX_WAKEUP_APPROVAL_POLICY",
      "never",
      new Set(["untrusted", "on-failure", "on-request", "never"])
    ),
    sandbox: execution.sandbox,
    ephemeral: false,
    sessionStartSource: "startup",
    threadSource: stringSetting(
      config,
      "threadSource",
      "NATIVE_AGENT_CODEX_THREAD_SOURCE",
      "nativeagent_codex_message"
    ),
    serviceName: stringSetting(
      config,
      "serviceName",
      "NATIVE_AGENT_CODEX_SERVICE_NAME",
      "NativeAgent codex_message"
    ),
  };
  if (brain.model) params.model = brain.model;
  if (brain.serviceTier) params.serviceTier = brain.serviceTier;
  const modelProvider = stringSetting(config, "modelProvider", "NATIVE_AGENT_CODEX_WAKEUP_MODEL_PROVIDER", "");
  if (modelProvider) params.modelProvider = modelProvider;
  return params;
}

function turnStartParams(threadId, entries, config) {
  const brain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  const params = {
    threadId,
    clientUserMessageId: clientUserMessageIdForEntries(entries),
    input: [{ type: "text", text: formatBatchPrompt(entries), text_elements: [] }],
  };
  if (brain.model) params.model = brain.model;
  if (brain.reasoningEffort) params.effort = brain.reasoningEffort;
  if (brain.serviceTier) params.serviceTier = brain.serviceTier;
  if (execution.sandboxPolicy) {
    params.cwd = execution.cwd;
    params.sandboxPolicy = execution.sandboxPolicy;
  }
  return params;
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

function pendingKey(payload, threadId) {
  if (payload.messageId) return `${threadId}:${payload.messageId}`;
  const digest = crypto
    .createHash("sha256")
    .update(`${threadId}\n${payload.topic || ""}\n${payload.text || ""}`)
    .digest("hex")
    .slice(0, 32);
  return `${threadId}:sha256:${digest}`;
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
  if (typeof payload.workingDirectory === "string" && path.isAbsolute(payload.workingDirectory)) {
    clean.workingDirectory = path.normalize(payload.workingDirectory);
  }
  if (payload.executionProfile === GITHUB_COMMAND_EXECUTION_PROFILE) {
    clean.executionProfile = GITHUB_COMMAND_EXECUTION_PROFILE;
  }
  if (payload.origin && typeof payload.origin === "object" && !Array.isArray(payload.origin)) {
    const origin = {};
    for (const key of ["surface", "destinationId", "threadId", "sourceKey", "replyTo", "correlationId"]) {
      if (typeof payload.origin[key] === "string" && payload.origin[key].trim() !== "") {
        origin[key] = payload.origin[key];
      }
    }
    if (Object.keys(origin).length > 0) clean.origin = origin;
  }
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

function ensureBridgeDir() {
  fs.mkdirSync(BRIDGE_DIR, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(BRIDGE_DIR, 0o700); } catch {}
}

function readPendingAtPath(pendingPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(pendingPath, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function readPendingUnlocked() {
  return readPendingAtPath(PENDING_PATH);
}

function writePendingUnlocked(entries) {
  writeJSONAtomic(PENDING_PATH, entries);
}

function appendJSONL(file, obj) {
  ensureBridgeDir();
  const line = `${JSON.stringify(obj)}\n`;
  const existed = fs.existsSync(file);
  const fd = fs.openSync(file, "a", 0o600);
  try {
    fs.writeFileSync(fd, line);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  if (!existed) fsyncDirectorySync(path.dirname(file));
  try { fs.chmodSync(file, 0o600); } catch {}
}

function fsyncDirectorySync(dir) {
  const fd = fs.openSync(dir, "r");
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function writeJSONAtomic(file, obj) {
  ensureBridgeDir();
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${Date.now()}.${crypto.randomUUID()}.tmp`;
  let renamed = false;
  try {
    const fd = fs.openSync(tmp, "wx", 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify(obj, null, 2));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
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

function writeTextAtomic(file, text) {
  ensureBridgeDir();
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${Date.now()}.${crypto.randomUUID()}.tmp`;
  let renamed = false;
  try {
    const fd = fs.openSync(tmp, "wx", 0o600);
    try {
      fs.writeFileSync(fd, text);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
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
    return fs.readFileSync(file, "utf8")
      .split("\n")
      .filter((line) => line.trim() !== "")
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      });
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
  fs.mkdirSync(path.dirname(receiptsPath), { recursive: true, mode: 0o700 });
  await withDirLock(`${receiptsPath}.append.lock`, async () => {
    appendJSONL(receiptsPath, receipt);
  }, { waitMs: 10000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
  return receiptsPath;
}

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
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
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
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
    };
  }
  if (await waitForPIDExit(pid, operations.killWaitMs ?? 2000, ops)) {
    return { action: "app_server_killed", pidKilled: pid };
  }
  return { action: "app_server_kill_failed_still_alive", pidKilled: null };
}

function clearStaleDrainLock(lockDir = DRAIN_LOCK_DIR, operations = {}) {
  if (!fs.existsSync(lockDir)) {
    return { action: "drain_lock_absent", pidKilled: null };
  }
  const ownerAlive = operations.dirLockOwnerAlive || dirLockOwnerAlive;
  if (ownerAlive(lockDir)) {
    return { action: "drain_lock_preserved_live_owner", pidKilled: null };
  }
  try {
    fs.rmSync(lockDir, { recursive: true, force: true });
    return { action: "stale_drain_lock_cleared", pidKilled: null };
  } catch (error) {
    return {
      action: "stale_drain_lock_clear_failed",
      pidKilled: null,
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
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
    await writeReceipt(receipt, config);
    receipts.push(receipt);
    return result;
  }

  const processOperations = options.processOperations || {};
  const killed = await record(await terminateKnownHungAppServer(job, processOperations));
  const lock = await record(clearStaleDrainLock(options.drainLockDir || DRAIN_LOCK_DIR, {
    dirLockOwnerAlive: options.dirLockOwnerAlive,
  }));
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
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
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

function inboxPathForPayload(payload) {
  if (payload && typeof payload.inboxPath === "string" && payload.inboxPath) return payload.inboxPath;
  return path.join(BRIDGE_DIR, "codex-inbox.jsonl");
}

function messageIdForPayload(payload) {
  if (!payload) return "";
  return String(payload.messageId || payload.id || "").trim();
}

function rowMessageIds(row) {
  const ids = [];
  if (row && row.id != null) ids.push(String(row.id));
  if (row && row.messageId != null) ids.push(String(row.messageId));
  return ids.filter(Boolean);
}

async function markInboxConsumed(entries, sent) {
  const targetsByPath = new Map();
  for (const entry of entries) {
    const payload = entry && entry.payload ? entry.payload : {};
    const messageId = messageIdForPayload(payload);
    if (!messageId) continue;
    const inboxPath = inboxPathForPayload(payload);
    if (!targetsByPath.has(inboxPath)) targetsByPath.set(inboxPath, new Set());
    targetsByPath.get(inboxPath).add(messageId);
  }
  if (targetsByPath.size === 0) {
    return { status: "skipped", reason: "message_id_missing" };
  }

  const changed = [];
  const missing = [];
  const errors = [];
  for (const [inboxPath, targetIds] of targetsByPath.entries()) {
    try {
      const result = await withDirLock(INBOX_LOCK_DIR, async () => {
        let raw;
        try {
          raw = fs.readFileSync(inboxPath, "utf8");
        } catch (error) {
          return {
            status: "failed",
            reason: "inbox_read_failed",
            inboxPath,
            error: String(error.message || error),
          };
        }
        const lines = raw.split("\n");
        const seen = new Set();
        const next = lines.map((line) => {
          if (!line.trim()) return line;
          let row;
          try {
            row = JSON.parse(line);
          } catch {
            return line;
          }
          const ids = rowMessageIds(row);
          const match = ids.find((id) => targetIds.has(id));
          if (!match) return line;
          seen.add(match);
          row.read = true;
          row.messageId = row.messageId || row.id || match;
          row.readAt = row.readAt || nowISO();
          row.consumedAt = row.consumedAt || row.readAt;
          row.consumedBy = row.consumedBy || "codex_thread_wakeup";
          row.consumedThreadId = sent.threadId || row.consumedThreadId || null;
          row.consumedTurnId = sent.turnId || row.consumedTurnId || null;
          return JSON.stringify(row);
        });
        const tmp = `${inboxPath}.${process.pid}.${Date.now()}.tmp`;
        fs.writeFileSync(tmp, next.join("\n"), { mode: 0o600 });
        fs.renameSync(tmp, inboxPath);
        try { fs.chmodSync(inboxPath, 0o600); } catch {}
        return {
          status: "ok",
          inboxPath,
          marked: [...seen],
          missing: [...targetIds].filter((id) => !seen.has(id)),
        };
      }, { waitMs: 5000, staleMs: 10 * 60 * 1000 });
      if (result.status === "ok") {
        changed.push(...result.marked.map((messageId) => ({ inboxPath, messageId })));
        missing.push(...result.missing.map((messageId) => ({ inboxPath, messageId })));
      } else {
        errors.push(result);
      }
    } catch (error) {
      errors.push({
        status: "failed",
        reason: error && error.message === "lock_busy" ? "inbox_lock_busy" : "inbox_mark_failed",
        inboxPath,
        error: String(error && error.message || error),
      });
    }
  }

  if (errors.length > 0) {
    return {
      status: changed.length > 0 ? "partial" : "failed",
      markedCount: changed.length,
      changed,
      missing,
      errors,
    };
  }
  return {
    status: missing.length > 0 ? "partial" : "marked_read",
    markedCount: changed.length,
    changed,
    missing,
  };
}

async function appendPending(payload, threadId, options = {}) {
  const cleanPayload = sanitizePayload(payload);
  const key = pendingKey(cleanPayload, threadId);
  const requestedRetryCount = Number(options.hangRetryCount);
  const hangRetryCount = Number.isInteger(requestedRetryCount) && requestedRetryCount >= 0
    ? requestedRetryCount
    : 0;
  return await withDirLock(QUEUE_LOCK_DIR, async () => {
    const queue = readPendingUnlocked();
    const existing = queue.find((entry) => entry.key === key);
    if (existing) {
      if (hangRetryCount > Number(existing.hangRetryCount || 0)) {
        existing.hangRetryCount = hangRetryCount;
        if (options.hungTurnId) existing.hungTurnId = String(options.hungTurnId);
        writePendingUnlocked(queue);
      }
      return {
        entry: existing,
        alreadyQueued: true,
        pendingCount: queue.length,
      };
    }
    const entry = {
      id: crypto.randomUUID(),
      key,
      threadId,
      payload: cleanPayload,
      addedAt: nowISO(),
      attempts: 0,
      hangRetryCount,
      ...(options.hungTurnId ? { hungTurnId: String(options.hungTurnId) } : {}),
    };
    queue.push(entry);
    writePendingUnlocked(queue);
    return {
      entry,
      alreadyQueued: false,
      pendingCount: queue.length,
    };
  });
}

async function removePending(ids) {
  const idSet = new Set(ids);
  return await withDirLock(QUEUE_LOCK_DIR, async () => {
    const queue = readPendingUnlocked();
    const next = queue.filter((entry) => !idSet.has(entry.id));
    writePendingUnlocked(next);
    return { before: queue.length, after: next.length };
  });
}

async function bumpPendingAttempt(id, errorText) {
  return await withDirLock(QUEUE_LOCK_DIR, async () => {
    const queue = readPendingUnlocked();
    const next = queue.map((entry) => {
      if (entry.id !== id) return entry;
      return {
        ...entry,
        attempts: Number(entry.attempts || 0) + 1,
        lastAttemptAt: nowISO(),
        lastError: errorText ? String(errorText).slice(0, 500) : null,
      };
    });
    writePendingUnlocked(next);
    return next.length;
  });
}

function firstPendingPerThread(queue) {
  const byThread = new Map();
  for (const entry of queue) {
    if (!entry || !entry.threadId || !entry.payload || !entry.payload.text) continue;
    if (!byThread.has(entry.threadId)) byThread.set(entry.threadId, entry);
  }
  return [...byThread.values()];
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
        NATIVE_AGENT_CODEX_PENDING_PATH: PENDING_PATH,
        NATIVE_AGENT_CODEX_PENDING_LOCK: QUEUE_LOCK_DIR,
        NATIVE_AGENT_CODEX_DRAIN_LOCK: DRAIN_LOCK_DIR,
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
    NATIVE_AGENT_CODEX_PENDING_PATH: PENDING_PATH,
    NATIVE_AGENT_CODEX_PENDING_LOCK: QUEUE_LOCK_DIR,
    NATIVE_AGENT_CODEX_DRAIN_LOCK: DRAIN_LOCK_DIR,
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

const CONNECTOR_SCHEMA_MISMATCH_MARKER = "failed connector schema validation";

/// Pull the failing property names out of a connector schema-validation reply.
/// Observed shape (2026-08-05, GitHub connector after a workspace-admin
/// constraint change):
///   "Parameters failed connector schema validation: owner [required]: Missing
///    required property (does not match constraints configured by your ChatGPT
///    workspace admin...); repo_name [required]: Missing required property..."
/// These arrive as an MCP *success* (`result.Ok`) whose text is the failure, so
/// nothing upstream classifies them — Codex just retries into a wall.
function parseConnectorSchemaMismatch(text) {
  if (typeof text !== "string" || !text.toLowerCase().includes(CONNECTOR_SCHEMA_MISMATCH_MARKER)) {
    return null;
  }
  const properties = [];
  const pattern = /([A-Za-z_][A-Za-z0-9_.-]*)\s*\[(required|optional)\]\s*:\s*([^;)]+)/g;
  let match;
  while ((match = pattern.exec(text)) !== null) {
    if (properties.some((entry) => entry.property === match[1])) continue;
    properties.push({
      property: match[1],
      requirement: match[2],
      detail: match[3].trim(),
    });
    if (properties.length >= 12) break;
  }
  return {
    diagnostic: "connector_schema_mismatch",
    properties,
    message: redactDiagnosticText(text.trim().slice(0, 600)),
  };
}

/// Text payloads live in several shapes across event_msg/response_item rows.
/// Flatten defensively rather than matching one shape: a missed shape silently
/// drops the diagnostic, which is the failure mode this fix exists to end.
function connectorDiagnosticTextsFromPayload(payload, depth = 0) {
  if (depth > 6 || payload == null) return [];
  if (typeof payload === "string") return [payload];
  if (Array.isArray(payload)) {
    return payload.flatMap((item) => connectorDiagnosticTextsFromPayload(item, depth + 1));
  }
  if (typeof payload !== "object") return [];
  return Object.values(payload)
    .flatMap((value) => connectorDiagnosticTextsFromPayload(value, depth + 1));
}

function collectConnectorSchemaMismatch(payload, sink) {
  for (const text of connectorDiagnosticTextsFromPayload(payload)) {
    const parsed = parseConnectorSchemaMismatch(text);
    if (!parsed) continue;
    const key = parsed.properties.map((entry) => entry.property).join(",");
    if (sink.seen.has(key)) {
      sink.occurrences += 1;
      continue;
    }
    sink.seen.add(key);
    sink.occurrences += 1;
    sink.failures.push(parsed);
  }
}

function summarizeConnectorDiagnostics(sink) {
  if (!sink || sink.failures.length === 0) return null;
  const properties = [];
  for (const failure of sink.failures) {
    for (const entry of failure.properties) {
      if (!properties.includes(entry.property)) properties.push(entry.property);
    }
  }
  return {
    diagnostic: "connector_schema_mismatch",
    occurrences: sink.occurrences,
    properties,
    detail: sink.failures[0].message,
  };
}

function extractTurnResultFromRollout(rolloutPath, turnId, options = {}) {
  let text;
  try {
    text = fs.readFileSync(rolloutPath, "utf8");
  } catch {
    return null;
  }

  let currentTurnId = null;
  let sawTurnStart = false;
  let finalAgentMessage = "";
  let assistantMessage = "";
  let toolActivityCount = 0;
  let completed = null;
  const connectorSink = { failures: [], seen: new Set(), occurrences: 0 };
  // Codex writes provider/backend failures (e.g. OpenAI 503) as task_complete
  // rows carrying an `error` field and last_agent_message:null — NOT as
  // turn_aborted. Folding those into "completed" produced the 2026-07-25
  // silent-completion incidents: a deterministic upstream failure was
  // reported to Agent as an unknown outcome she could not safely retry.
  const taskCompleteResult = (row, payload) => {
    // The error field has been observed object-shaped ({message,
    // codex_error_info}); tolerate string/other shapes rather than silently
    // reclassifying an errored turn as completed.
    const rawError = payload.error;
    const hasError = rawError !== undefined && rawError !== null && rawError !== "";
    const errorMessage = !hasError ? null
      : typeof rawError === "string" ? rawError
      : typeof rawError === "object" && typeof rawError.message === "string" ? rawError.message
      : String(rawError.message || JSON.stringify(rawError) || "codex turn error");
    return {
      status: hasError ? "failed" : "completed",
      completedAt: row.timestamp || nowISO(),
      durationMs: payload.duration_ms || null,
      lastAgentMessage: typeof payload.last_agent_message === "string" ? payload.last_agent_message : "",
      errorMessage,
      codexErrorInfo: hasError && typeof rawError === "object" && rawError.codex_error_info
        ? String(rawError.codex_error_info)
        : null,
    };
  };
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = row && row.payload;
    if (row.type === "event_msg" && payload && payload.type === "task_started" && payload.turn_id) {
      currentTurnId = payload.turn_id;
      if (payload.turn_id === turnId) sawTurnStart = true;
      continue;
    }
    if (currentTurnId === turnId && row.type === "event_msg" && payload) {
      // mcp_tool_call_end carries the connector reply, including the
      // schema-validation failures that arrive as an MCP success.
      if (payload.type === "mcp_tool_call_end") collectConnectorSchemaMismatch(payload, connectorSink);
      if (payload.type === "agent_message" && payload.phase === "final_answer" && typeof payload.message === "string") {
        finalAgentMessage = payload.message;
      } else if (payload.type === "task_complete" && payload.turn_id === turnId) {
        completed = taskCompleteResult(row, payload);
        currentTurnId = null;
      } else if (payload.type === "turn_aborted" && payload.turn_id === turnId) {
        completed = {
          status: "aborted",
          completedAt: row.timestamp || nowISO(),
          durationMs: payload.duration_ms || null,
          lastAgentMessage: "",
        };
        currentTurnId = null;
      }
      continue;
    }
    if (currentTurnId === turnId && row.type === "response_item" && payload) {
      if (payload.type === "message" && payload.role === "assistant" && Array.isArray(payload.content)) {
        const parts = [];
        for (const item of payload.content) {
          if (item && item.type === "output_text" && typeof item.text === "string") parts.push(item.text);
        }
        if (parts.length > 0) assistantMessage = parts.join("\n");
      } else if (payload.type === "custom_tool_call_output" || payload.type === "function_call_output") {
        // exec-wrapped connector calls surface the same failure text here.
        collectConnectorSchemaMismatch(payload, connectorSink);
      } else if (typeof payload.type === "string" && payload.type.endsWith("_call")) {
        // Structural match: this Codex build writes custom_tool_call and
        // function_call today, and has written other *_call shapes across
        // versions. Outputs are *_call_output and never match.
        toolActivityCount += 1;
      }
      continue;
    }
    if (row.type === "event_msg" && payload && payload.turn_id === turnId
        && payload.type === "mcp_tool_call_end") {
      // Explicitly-attributed fallback: today's Codex omits turn_id on this row
      // shape, so ambient attribution above is the live path. If the turn's
      // task_started is missing (rotated rollout) and a future build does stamp
      // turn_id, the diagnostic must still be found rather than silently lost.
      collectConnectorSchemaMismatch(payload, connectorSink);
    }
    if (row.type === "event_msg" && payload && payload.turn_id === turnId && payload.type === "task_complete") {
      // Unattributed fallback: the file lacked (or we missed) this turn's
      // task_started — including the case where task_complete already cleared
      // currentTurnId in the attributed branch above. Do NOT clear
      // currentTurnId — that would drop attribution for whichever other turn
      // is being tracked.
      completed = taskCompleteResult(row, payload);
    } else if (row.type === "event_msg" && payload && payload.turn_id === turnId && payload.type === "turn_aborted") {
      // Same fallback for turn_aborted, so "last terminal event wins" holds
      // even when an abort lands after an errored task_complete without a
      // fresh task_started re-arming the attributed branch.
      completed = {
        status: "aborted",
        completedAt: row.timestamp || nowISO(),
        durationMs: payload.duration_ms || null,
        lastAgentMessage: "",
      };
    }
  }

  if (!completed) {
    // Stall probing needs the turn's observed activity even without a
    // terminal row. Opt-in only: every existing caller treats null as "no
    // result yet", and an in_flight object leaking into those paths would
    // read as a terminal outcome.
    if (options.includeNonTerminal) {
      return {
        status: "in_flight",
        sawTurnStart,
        toolActivityCount,
        hasMessage: Boolean((finalAgentMessage || assistantMessage || "").trim()),
        connectorDiagnostics: summarizeConnectorDiagnostics(connectorSink),
      };
    }
    return null;
  }
  const connectorDiagnostics = summarizeConnectorDiagnostics(connectorSink);
  const message = (completed.lastAgentMessage || finalAgentMessage || assistantMessage || "").trim();
  if (completed.status === "failed") {
    // Three-state: true = we watched the whole turn and saw nothing execute
    // (resend cannot stomp partial work); false = activity was observed;
    // null = the file never showed this turn's task_started, so absence of
    // observed activity proves nothing (rotated/truncated rollout).
    const noWorkObserved = !sawTurnStart ? null : (toolActivityCount === 0 && !message);
    return {
      ...completed,
      message,
      rolloutPath,
      toolActivityCount,
      noWorkObserved,
      connectorDiagnostics,
    };
  }
  if (completed.status === "completed" && !message) {
    return {
      ...completed,
      status: "completed_without_reply",
      message,
      rolloutPath,
      toolActivityCount,
      connectorDiagnostics,
    };
  }
  return { ...completed, message, rolloutPath, toolActivityCount, connectorDiagnostics };
}

function extractTurnResultFromTurn(turn, turnId, rolloutPath = null) {
  if (!turn || turn.id !== turnId || turn.status === "inProgress") return null;
  const messages = Array.isArray(turn.items)
    ? turn.items.filter((item) => item && item.type === "agentMessage"
        && typeof item.text === "string" && item.text.trim() !== "")
    : [];
  const final = [...messages].reverse().find((item) => item.phase === "final_answer")
    || messages[messages.length - 1];
  const message = final ? final.text.trim() : "";
  const completedAt = Number.isFinite(turn.completedAt)
    ? new Date(Number(turn.completedAt) * 1000).toISOString()
    : nowISO();
  const base = {
    completedAt,
    durationMs: Number.isFinite(turn.durationMs) ? Number(turn.durationMs) : null,
    message,
    rolloutPath,
  };
  if (turn.status === "completed") {
    return { ...base, status: message ? "completed" : "completed_without_reply" };
  }
  if (turn.status === "interrupted" || turn.status === "cancelled" || turn.status === "canceled") {
    return { ...base, status: "aborted" };
  }
  return {
    ...base,
    status: "failed",
    error: turn.error || null,
  };
}

function extractTurnResultFromThread(thread, turnId, rolloutPath = null) {
  const turns = thread && Array.isArray(thread.turns) ? thread.turns : [];
  const turn = turns.find((candidate) => candidate && candidate.id === turnId);
  return extractTurnResultFromTurn(turn, turnId, rolloutPath);
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

  let settled = false;
  let timer = null;
  let resolveEvent;
  const cleanup = [];
  const promise = new Promise((resolve) => { resolveEvent = resolve; });

  function close() {
    if (timer) clearTimeout(timer);
    timer = null;
    while (cleanup.length > 0) {
      const dispose = cleanup.pop();
      try { dispose(); } catch {}
    }
    if (client) client.close();
    client = null;
  }

  function signal(source) {
    if (settled) return;
    settled = true;
    close();
    resolveEvent({ source });
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

  const pendingPath = typeof config.pendingPath === "string" && config.pendingPath
    ? config.pendingPath
    : PENDING_PATH;
  watchFile(pendingPath, "pending_queue_event");

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
  timer = setTimeout(() => signal(timerSource), delay);

  // Close registration races once. Further reads happen only after an exact
  // queue/rollout/RPC event or a failure-specific retry deadline.
  await new Promise((resolve) => setImmediate(resolve));
  if (queueFingerprint(readPendingAtPath(pendingPath)) !== expectedQueueFingerprint) {
    signal("initial_queue_change");
  }
  if (!settled) {
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
  let settled = false;
  let timer = null;
  const cleanup = [];
  let resolveEvent;
  const promise = new Promise((resolve) => { resolveEvent = resolve; });

  function close() {
    if (timer) clearTimeout(timer);
    timer = null;
    while (cleanup.length > 0) {
      const dispose = cleanup.pop();
      try { dispose(); } catch {}
    }
  }

  function signal(event) {
    if (settled) return;
    settled = true;
    close();
    resolveEvent(event);
  }

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
            if (current
                && current.ino === initialRolloutStat.ino
                && current.size === initialRolloutStat.size
                && current.mtimeMs === initialRolloutStat.mtimeMs) return;
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
  timer = setTimeout(() => signal({ source: "exact_timeout", turn: null }), remaining);
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
    // Reachable socket but a failed read proves nothing either way. Report
    // the turn as found-and-inProgress so a flaky thread/read can never
    // manufacture a one-window stall (gpt-5.5 review BLOCKING, 2026-07-30:
    // turnFound:false here fed the !turnFound dead-liveness arm). The
    // wedged-inProgress path still bounds a persistently unreadable turn at
    // two stagnant windows.
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
  // Stall judging used to happen only at replyWaitTimeoutMs boundaries (1h), so
  // the earliest possible stalled verdict was ~2h and Agent saw dead turns sit
  // "in flight" indefinitely (2026-08-05 incident, turn
  // 019fd2e5-0a92-7640-a965-8dbdf55f730b: died mid custom_tool_call at
  // 17:12:25Z with no task_complete). The judging cadence is now its own knob.
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
  // RATIFIED, do not lower without User (2026-08-05): the 4h default was raised
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

    // Stalled-turn detection (2026-07-30): a turn whose runtime died without
    // writing task_complete/turn_aborted used to cycle timeout->rewait
    // forever, indistinguishable from legitimate long work. Evidence, judged
    // at each window boundary:
    //   - rollout stagnation: the session file did not change (ino+size+mtime)
    //     across one full wait window, or stayed undiscoverable;
    //   - liveness: the app-server is unreachable, or reachable but no longer
    //     lists this turn.
    // Stagnant + dead liveness => stalled. When the rollout is discoverable the
    // gate is MEASURED idle time (now - mtime >= stallIdleMs), not a count of
    // windows: mtime is a real timestamp, so no baseline window is needed to
    // interpret it, and a dead-liveness stall settles ~15 min after the last
    // rollout byte instead of ~2h. When the rollout is NOT discoverable there is
    // no timestamp to measure, so the original window-counting baseline still
    // applies -- "I can't find the subject" must never read as "the subject is
    // dead" (2026-07-31 audit: a rotated rolloutPath plus one transient RPC
    // failure manufactured a one-window terminal stall on a healthy turn). The
    // transient-RPC half of that trap is closed separately by confirming every
    // dead-liveness reading with a second probe before settling.
    // A server still claiming inProgress needs `stallWedgedIdleMs` (default 4h,
    // matching the old 4 x 1h windows): rollout stagnation measures BYTES
    // WRITTEN, and a single long tool call — a multi-hour build under the
    // github-command profile — legitimately writes nothing until the call
    // returns (2026-07-31 audit). Rollout movement resets everything.
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
      // First window ONLY establishes a baseline — even when the rollout is
      // undiscoverable. "I can't find the subject" must never read as "the
      // subject is dead" (2026-07-31 audit: a rotated rolloutPath or
      // CODEX_HOME mismatch plus one transient RPC failure manufactured a
      // one-window terminal stall on a healthy turn). A persistently
      // undiscoverable rollout still converges: the next window compares
      // null==null as stagnant and probes with a real baseline behind it.
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
        // Confirm before settling: a single transient connectRpc failure or a
        // mid-restart app-server must never be the sole evidence that a turn
        // died. Two independent readings must agree (2026-07-31 audit).
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

function formatCodexReplyForNativeAgent(job, turnResult) {
  const entries = Array.isArray(job.entries) ? job.entries : [];
  const firstPayload = (entries[0] && entries[0].payload) || {};
  const title = turnResult.status === "completed"
    ? (entries.length > 1
      ? `Codex replied to ${entries.length} queued messages.`
      : "Codex replied to your message.")
    : turnResult.status === "failed" || turnResult.status === "failed_hung"
      ? (entries.length > 1
        ? `Codex wakeup failed for ${entries.length} queued messages.`
        : "Codex wakeup failed.")
      : turnResult.status === "stalled"
        ? (entries.length > 1
          ? `Codex turn stalled for ${entries.length} queued messages.`
          : "Codex turn stalled.")
        : (entries.length > 1
          ? `Codex wakeup produced no reply for ${entries.length} queued messages.`
          : "Codex wakeup produced no reply.");
  const lines = [
    title,
    "",
    "This is an asynchronous completion event for work you delegated. Compare Codex's result with your original request, decide whether it succeeded, partially succeeded, or failed, and tell User concisely in your own voice. Do not call it successful merely because a Codex turn completed. If important work is missing, say what is missing. Only send a focused follow-up when Codex returned an actionable partial result; when the outcome is unknown, never resend the same request without an explicit decision. Follow the resend guidance in the result section below when it is present.",
    "",
  ];
  if (firstPayload.topic) lines.push(`Topic: ${firstPayload.topic}`);
  if (firstPayload.messageId) lines.push(`Message id: ${firstPayload.messageId}`);
  if (job.threadId) {
    lines.push(`Conversation: codex:${job.threadId}`);
    lines.push("Continue this same work by calling codex_message with conversation_id set to that exact value. Omit conversation_id for new work.");
  }
  if (job.turnId) lines.push(`Codex turn: ${job.turnId}`);
  if (turnResult.execution) lines.push(`Completion path: ${turnResult.execution}`);
  if (turnResult.waitSource) lines.push(`Wake source: ${turnResult.waitSource}`);
  if (turnResult.completedAt) lines.push(`Completed: ${turnResult.completedAt}`);
  lines.push("", "Original request:");
  for (const [index, entry] of entries.entries()) {
    const original = entry && entry.payload && typeof entry.payload.text === "string"
      ? entry.payload.text.trim().slice(0, 8000)
      : "";
    if (entries.length > 1) lines.push(`Request ${index + 1}:`);
    lines.push(original || "(original request unavailable)", "");
  }
  lines.push("Codex result:");
  if (turnResult.status === "completed") {
    lines.push(turnResult.message || "(Codex completed without a final text reply.)");
  } else if (turnResult.status === "completed_without_reply") {
    lines.push("Codex accepted the wakeup but completed without a final assistant reply. The outcome is unknown: do not assume either that the task ran nothing or that it completed.");
    lines.push("NativeAgent did not automatically replay the request because the first turn may already have produced effects. Report the bridge failure to User; retry only after an explicit decision.");
  } else if (turnResult.status === "aborted") {
    lines.push("Codex turn was aborted before a final reply landed.");
  } else if (turnResult.status === "stalled") {
    const ev = turnResult.stallEvidence || {};
    const cause = !ev.serverReachable
      ? "the Codex app-server is no longer reachable"
      : !ev.turnFound
        ? "the Codex app-server no longer lists this turn"
        : `the turn still claims to be running but wrote nothing across ${ev.stagnantWindows} full wait windows`;
    const idleClause = ev.lastActivityAt
      ? `the session file has been unchanged since ${ev.lastActivityAt}`
        + (Number.isFinite(ev.idleMs) ? ` (${Math.round(ev.idleMs / 60000)} min idle)` : "")
      : `the session file stayed unchanged across ${ev.stagnantWindows} consecutive wait window(s) after a baseline observation`;
    lines.push(`Codex stopped making progress: no terminal row landed, ${idleClause}, and ${cause}. This turn will not complete on its own.`);
    if (turnResult.noWorkObserved === true) {
      lines.push("No tool or shell activity was recorded before the stall: the request never executed, so resending it cannot stomp partial work.");
    } else if (turnResult.noWorkObserved === false) {
      lines.push("Tool activity was recorded before the stall, so partial work may exist on disk. Verify external state before resending.");
    } else {
      lines.push("The local record does not show whether any work executed before the stall. Treat partial work as possible: verify external state before resending.");
    }
    lines.push("NativeAgent did not automatically replay the request. Report the stall to User; retry only after an explicit decision.");
  } else if (turnResult.status === "failed_hung") {
    const ev = turnResult.hangEvidence || {};
    const recovery = turnResult.hangRecovery || null;
    const idleClause = ev.lastWriteAt
      ? `Its rollout file stopped changing at ${ev.lastWriteAt}`
        + (Number.isFinite(ev.idleMs) ? ` (${Math.round(ev.idleMs / 60000)} min idle).` : ".")
      : "Its rollout file stopped changing during the active turn.";
    lines.push(`NativeAgent's hang watchdog declared this Codex turn failed-hung. ${idleClause}`);
    if (turnResult.noWorkObserved === true) {
      lines.push("No tool or shell activity was recorded before the hang: the request never executed, so resending it cannot stomp partial work.");
    } else {
      lines.push("Partial work may exist on disk. Verify external state before resending.");
    }
    if (recovery && recovery.status === "permanent_failed_hung") {
      lines.push(`NativeAgent's automatic recovery reached its retry cap (${recovery.retryCount}/${recovery.maxRetries}); this message will not be retried again.`);
    } else {
      lines.push("NativeAgent did not automatically replay the request.");
    }
  } else if (turnResult.status === "failed") {
    lines.push("Codex's turn failed before a final reply landed.");
    const failureDetail = turnResult.errorMessage
      || (typeof turnResult.error === "string" ? turnResult.error : turnResult.error && turnResult.error.message)
      || turnResult.stderrPreview;
    if (failureDetail) lines.push(`Failure detail: ${failureDetail}`);
    if (turnResult.noWorkObserved === true) {
      lines.push("No tool or shell activity was recorded before the failure: the request never executed, so resending it cannot stomp partial work. If the failure detail is a transient provider error (503 / high demand), waiting and resending the same request is safe.");
    } else if (turnResult.noWorkObserved === false) {
      lines.push("Tool activity was recorded before the failure, so partial work may exist on disk. Verify external state before resending.");
    } else {
      lines.push("The local record does not show whether any work executed before the failure. Treat partial work as possible: verify external state before resending.");
    }
  } else {
    lines.push("Codex did not finish before the reply watcher timed out.");
  }
  const connector = turnResult.connectorDiagnostics;
  if (connector && connector.diagnostic === "connector_schema_mismatch") {
    const properties = Array.isArray(connector.properties) && connector.properties.length > 0
      ? connector.properties.join(", ")
      : "(unnamed)";
    lines.push(
      "",
      `Diagnostic: connector_schema_mismatch — ${connector.occurrences || 1} connector call(s) were rejected by workspace-admin schema validation on required property/properties: ${properties}.`,
      "This is a tool-surface configuration failure, not a Codex reasoning failure: the connector's required parameters no longer match what Codex sends, so every retry down that path fails identically. Resending the same request will not help until the connector schema or the caller's parameters are reconciled (a workspace admin change is the usual cause).",
    );
    if (connector.detail) lines.push(`Verbatim: ${connector.detail}`);
  }
  lines.push("", "Now give User the completion update in this same conversation. Do not wait for him to ask whether Codex finished.");
  return lines.join("\n");
}

function postBridgeMessage(text, sessionId, config, metadata = {}) {
  if (process.env.NATIVE_AGENT_CODEX_REPLY_DRY_RUN === "1") {
    return Promise.resolve({
      status: "dry_run",
      delivery: "nativeagent_bridge_message",
      sessionId: sessionId || null,
      deliveryId: metadata.deliveryId || null,
      origin: metadata.origin || null,
      completion: metadata.completion || null,
      textPreview: text.slice(0, 500),
    });
  }

  const tokenPath = stringSetting(config, "bridgeTokenPath", "NATIVE_AGENT_CODEX_BRIDGE_TOKEN_PATH", BRIDGE_TOKEN_PATH);
  let token;
  try {
    token = fs.readFileSync(tokenPath, "utf8").trim();
  } catch (error) {
    return Promise.resolve({
      status: "failed",
      reason: "bridge_token_missing",
      tokenPath,
      error: String(error.message || error),
    });
  }
  if (!token) {
    return Promise.resolve({ status: "failed", reason: "bridge_token_empty", tokenPath });
  }

  const endpoint = codexReturnBridgeEndpoint(config);
  const { host, port } = endpoint;
  // 11 min, deliberately ABOVE the app's 600s messageWorkDeadlineSeconds so
  // the two deadlines can never fire in the same second with an undefined
  // winner (2026-07-31 audit: identical 600s/600s produced a socket-destroy vs
  // work-cancel race that stranded completed replies). Same staggering rule as
  // the +8s helper-deadline pair in SwiftToolDispatcher+AgentBridgeTools.
  const timeoutMs = numberSetting(config, "bridgeReplyTimeoutMs", "NATIVE_AGENT_CODEX_BRIDGE_REPLY_TIMEOUT_MS", 11 * 60 * 1000);
  const body = JSON.stringify({
    text,
    sender: "codex",
    ...(metadata.deliveryId ? { deliveryId: metadata.deliveryId } : {}),
    ...(sessionId ? { sessionId } : {}),
    ...(metadata.origin ? { origin: metadata.origin } : {}),
    ...(metadata.completion ? { completion: metadata.completion } : {}),
  });

  return new Promise((resolve) => {
    const req = http.request({
      host,
      port,
      path: "/codex/message",
      method: "POST",
      timeout: timeoutMs,
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch {}
        const httpOK = res.statusCode >= 200 && res.statusCode < 300;
        const replyStatus = parsed && parsed.status ? parsed.status : null;
        const semanticOK = httpOK && replyStatus === "ok";
        resolve({
          status: semanticOK ? "delivered" : "failed",
          reason: semanticOK
            ? null
            : (httpOK ? `nativeagent_reply_${replyStatus || "missing_status"}` : `http_${res.statusCode}`),
          delivery: "nativeagent_bridge_message",
          httpStatus: res.statusCode,
          sessionId: sessionId || null,
          replyStatus,
          nativeAgentSessionId: parsed && parsed.sessionId ? parsed.sessionId : null,
          nativeAgentReplyPreview: parsed && typeof parsed.reply === "string" ? parsed.reply.slice(0, 1000) : null,
          completionDelivery: parsed && parsed.completionDelivery ? parsed.completionDelivery : null,
          rawPreview: raw.slice(0, 1000),
        });
      });
    });
    req.on("timeout", () => {
      req.destroy(new Error("bridge_message_timeout"));
    });
    req.on("error", (error) => {
      resolve({
        status: "failed",
        reason: error && error.message ? error.message : "bridge_message_failed",
        delivery: "nativeagent_bridge_message",
        sessionId: sessionId || null,
      });
    });
    req.write(body);
    req.end();
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
        error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
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
    delete job.lastWait;
    delete job.stallProbe;
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
  const text = formatCodexReplyForNativeAgent({
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
  const bridge = await postBridgeMessageWithRetry(
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
      messagePreview: (turnResult.message || "").slice(0, 1000),
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
    delivery: "nativeagent_bridge_message_after_codex_turn",
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
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
    };
  } catch (quarantineError) {
    return {
      status: "failed",
      reason: "reply_job_read_failed_and_quarantine_failed",
      jobPath,
      error: redactDiagnosticText(String(quarantineError && quarantineError.message || quarantineError)).slice(0, 500),
    };
  }
}

// Transport-level (not semantic) failures of the delivery POST. These say
// nothing about whether the app processed the completion — the request never
// reached a handler, or reached one that never claimed the delivery — so
// resending the SAME deliveryId is exactly-once-safe: CodexCompletionLifecycle
// .claim() is keyed on (deliveryId, requestDigest) and answers .cached /
// .inProgress / .outcomeUnknown for anything already started.
//
// Deliberately NOT retryable:
//   - 409 (outcome_unknown / conflict): terminal in the lifecycle. Once a state
//     file reaches .outcomeUnknown, claim() returns .outcomeUnknown forever
//     (CodexCompletionLifecycle.swift:198-199) and nothing transitions out of
//     it. Retrying can only burn attempts.
//   - 504 work_timeout: the app is mid-turn under its own 600s work deadline.
//     A resend inside a short backoff window can only draw 202/409.
//   - missing/empty bridge token: a config fault, not a transient one.
function bridgeDeliveryRetryable(bridge) {
  if (!bridge || bridge.status !== "failed") return false;
  const httpStatus = Number(bridge.httpStatus);
  if (Number.isFinite(httpStatus) && httpStatus > 0) {
    if (httpStatus === 504) return false;
    return httpStatus === 408 || httpStatus === 429 || httpStatus >= 500;
  }
  // No HTTP status at all: either a socket-level error or a local precondition.
  const reason = String(bridge.reason || "");
  if (reason === "bridge_token_missing" || reason === "bridge_token_empty") return false;
  // An 11-minute request timeout means the app owns the turn; the durable job
  // file outlives us and the launch-time recovery scan re-delivers.
  if (reason === "bridge_message_timeout") return false;
  return true;
}

// Full-jitter exponential backoff: delay_n ∈ [0, min(cap, base * 2^n)).
function bridgeDeliveryBackoffMs(attemptIndex, options = {}) {
  const baseMs = Number(options.baseMs) > 0 ? Number(options.baseMs) : 500;
  const capMs = Number(options.capMs) > 0 ? Number(options.capMs) : 8000;
  const random = typeof options.random === "function" ? options.random : Math.random;
  const ceiling = Math.min(capMs, baseMs * Math.pow(2, Math.max(0, attemptIndex)));
  return Math.floor(random() * ceiling);
}

// BRIDGES-4: a refused/reset delivery POST used to strand a completed Codex
// reply in reply-jobs/ until the next app launch ran --recover-reply-jobs
// (ClaudeBridge.swift:328). Retry a bounded, jittered handful of times first;
// the app is usually mid-launch, not gone. Exhaustion is NOT a data loss path:
// job.completedExecution is already persisted before the POST, and an
// exhausted delivery leaves the job file in place for the recovery scan.
async function postBridgeMessageWithRetry(post, options = {}) {
  const maxAttempts = Math.max(1, Math.min(8, Number(options.maxAttempts) || 4));
  const wait = typeof options.sleep === "function" ? options.sleep : sleep;
  const attempts = [];
  let bridge = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    bridge = await post(attempt);
    if (!bridgeDeliveryRetryable(bridge)) break;
    attempts.push({
      attempt,
      reason: bridge && bridge.reason ? String(bridge.reason).slice(0, 200) : null,
      httpStatus: bridge && bridge.httpStatus != null ? bridge.httpStatus : null,
    });
    if (attempt === maxAttempts) break;
    await wait(bridgeDeliveryBackoffMs(attempt - 1, options));
  }
  if (attempts.length && bridge && typeof bridge === "object") {
    bridge = {
      ...bridge,
      deliveryAttempts: attempts.length + (bridgeDeliveryRetryable(bridge) ? 0 : 1),
      retriedFailures: attempts,
      retriesExhausted: bridgeDeliveryRetryable(bridge),
    };
  }
  return bridge;
}

// What to do with the durable job file once the POST has settled.
//
//   "unlink"   — the app owns the completion now (delivered) or has definitively
//                consumed/refused it; replaying would double-book.
//   "preserve" — the app's outcome is AMBIGUOUS (409). Deleting here is what
//                lost the reply: the receipt keeps only a 1000-char preview.
//                Move the job aside so the full text survives for a human/agent,
//                without leaving it in the scan path to relaunch forever.
//   "retain"   — retryable/unknown failure; leave it for the recovery scan.
function replyJobDisposition(bridge) {
  if (!bridge) return "retain";
  if (bridge.status === "delivered" || bridge.status === "dry_run") return "unlink";
  if (!isTerminalBridgeReply(bridge)) return "retain";
  return bridge.replyStatus === "outcome_unknown" || bridge.replyStatus === "conflict"
    ? "preserve"
    : "unlink";
}

// Preserve out of the *.json scan path: recoverReplyJobs only reads files
// directly in jobsDir (see readdirSync + isFile filter), so a subdirectory is
// never rescanned and can never relaunch a turn.
// Newest-first bound on preserved replies. Preserved jobs hold full reply
// text and nothing else ever deletes them, so the store must bound itself
// (gpt-5.5 review MED): a stuck lifecycle 409-ing distinct completions for
// days would otherwise grow this directory forever.
const UNDELIVERED_REPLY_JOBS_CAP = 200;

function pruneUndeliveredReplyJobs(undeliveredDir, cap = UNDELIVERED_REPLY_JOBS_CAP) {
  let entries;
  try {
    entries = fs.readdirSync(undeliveredDir).filter((name) => name.endsWith(".json"));
  } catch {
    return;
  }
  if (entries.length <= cap) return;
  const stamped = entries.map((name) => {
    let mtimeMs = 0;
    try { mtimeMs = fs.statSync(path.join(undeliveredDir, name)).mtimeMs; } catch {}
    return { name, mtimeMs };
  });
  stamped.sort((a, b) => a.mtimeMs - b.mtimeMs);
  for (const victim of stamped.slice(0, stamped.length - cap)) {
    try { fs.unlinkSync(path.join(undeliveredDir, victim.name)); } catch {}
  }
}

function preserveUndeliverableReplyJob(jobPath, bridge) {
  const undeliveredDir = path.join(path.dirname(jobPath), "undelivered");
  try {
    fs.mkdirSync(undeliveredDir, { recursive: true, mode: 0o700 });
    const target = path.join(
      undeliveredDir,
      `${path.basename(jobPath, ".json")}.${Date.now()}.${bridge && bridge.replyStatus || "unknown"}.json`
    );
    fs.renameSync(jobPath, target);
    // rename keeps the source file's mode; a legacy 0644 job must not land
    // world-readable with full reply text (gpt-5.5 review MED).
    try { fs.chmodSync(target, 0o600); } catch {}
    pruneUndeliveredReplyJobs(undeliveredDir);
    fsyncDirectorySync(path.dirname(jobPath));
    fsyncDirectorySync(undeliveredDir);
    return { preserved: true, undeliveredPath: target };
  } catch (error) {
    return {
      preserved: false,
      error: redactDiagnosticText(String(error && error.message || error)).slice(0, 300),
    };
  }
}

function finalizeReplyJobFile(jobPath, bridge) {
  const disposition = replyJobDisposition(bridge);
  if (disposition === "unlink") {
    try { fs.unlinkSync(jobPath); } catch {}
    return { disposition };
  }
  if (disposition === "preserve") {
    return { disposition, ...preserveUndeliverableReplyJob(jobPath, bridge) };
  }
  return { disposition };
}

function isTerminalBridgeReply(bridge) {
  // These states cannot improve by replaying the same durable, cached Agent
  // response. `outcome_unknown` and `conflict` must not resend; `no_reply`
  // would otherwise leave an orphan job that relaunches forever.
  return Boolean(bridge && [
    "outcome_unknown",
    "conflict",
    "no_reply",
    "delivery_rejected",
    "completion_already_settled",
  ].includes(bridge.replyStatus));
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
              error: redactDiagnosticText(String(error && error.message || error)).slice(0, 500),
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
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let receipt;
    try {
      receipt = JSON.parse(line);
    } catch {
      continue;
    }
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

async function deferUntilIdle(payload, threadId, state, config) {
  const queued = await appendPending(payload, threadId);
  const drain = startDrainProcess(config);
  return {
    status: "queued_pending_idle",
    reason: "thread_active",
    delivery: "codex_app_server_deferred_until_idle",
    threadId,
    pendingPath: PENDING_PATH,
    pendingCount: queued.pendingCount,
    alreadyQueued: queued.alreadyQueued,
    activeStatus: state.statusType,
    activeFlags: state.activeFlags,
    inProgressTurnIds: state.inProgressTurnIds,
    busySource: state.source || "unknown",
    rolloutPath: state.rolloutPath || null,
    drain,
  };
}

async function requestTurnStart(payload, threadId, config) {
  const prompt = formatPrompt(payload);
  if (process.env.NATIVE_AGENT_CODEX_WAKEUP_DRY_RUN === "1") {
    return { status: "dry_run", threadId, promptBytes: Buffer.byteLength(prompt) };
  }

  const timeoutMs = numberSetting(config, "requestTimeoutMs", "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS", 12000);
  const deferWhenActive = boolSetting(config, "deferWhenActive", "NATIVE_AGENT_CODEX_WAKEUP_DEFER_WHEN_ACTIVE", true);
  try {
    const localState = readLocalRolloutState(threadId, config);
    if (deferWhenActive && localState && localState.active) {
      return await deferUntilIdle(payload, threadId, localState, config);
    }
    return await withRpc(async (client) => {
      const rpcState = await readThreadState(client, threadId);
      const state = combineThreadStates(localState, rpcState);
      if (isUnhealthyThreadState(state)) {
        return unhealthyThreadResult(threadId, state, { delivery: "codex_app_server_thread_read" });
      }
      if (deferWhenActive && state.active) {
        return await deferUntilIdle(payload, threadId, state, config);
      }
      const entries = [{
        id: crypto.randomUUID(),
        threadId,
        payload: sanitizePayload(payload),
      }];
      const sent = await startTurnForEntries(client, threadId, entries, config, deferWhenActive);
      if (sent.status === "busy") {
        return await deferUntilIdle(payload, threadId, {
          statusType: sent.activeStatus || "active",
          activeFlags: sent.activeFlags || [],
          inProgressTurnIds: sent.inProgressTurnIds || [],
        }, config);
      }
      return await attachConsumeAndReplyDelivery(sent, entries, config);
    }, timeoutMs);
  } catch (error) {
    return rpcFailure(error, threadId);
  }
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

  const timeoutMs = numberSetting(config, "requestTimeoutMs", "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS", 12000);
  try {
    return await withRpc(async (client) => {
      const sent = await startFreshThreadForEntries(client, entries, config);
      return await attachConsumeAndReplyDelivery(sent, entries, config);
    }, timeoutMs);
  } catch (error) {
    return rpcFailure(error, null, { mode: FRESH_THREAD_MODE });
  }
}

async function drainPending(config, options = {}) {
  const timeoutMs = numberSetting(config, "requestTimeoutMs", "NATIVE_AGENT_CODEX_WAKEUP_REQUEST_TIMEOUT_MS", 12000);
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
  heartbeat.update(readPendingAtPath(PENDING_PATH).length, null);
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

  return await withDirLock(DRAIN_LOCK_DIR, async () => {
    while (Date.now() < deadline) {
      const queue = await withDirLock(QUEUE_LOCK_DIR, async () => readPendingUnlocked(), { waitMs: 2000 });
      heartbeat.update(queue.length, null);
      if (queue.length === 0) {
        return { status: "drained", delivered, pendingCount: 0 };
      }

      let madeProgress = false;
      let iterationFailure = false;
      let retryAttempt = 0;
      const busyStates = [];
      for (const entry of firstPendingPerThread(queue)) {
        try {
          const localState = stateExcludingDeclaredHungTurn(
            readLocalRolloutState(entry.threadId, config),
            entry
          );
          if (localState && localState.active) {
            lastBusy = localState;
            busyStates.push(localState);
            heartbeat.update(queue.length, localState.inProgressTurnIds && localState.inProgressTurnIds[0] || null);
            continue;
          }
          const result = await withRpc(async (client) => {
            const rpcState = await readThreadState(client, entry.threadId);
            const state = stateExcludingDeclaredHungTurn(
              combineThreadStates(localState, rpcState),
              entry
            );
            if (isUnhealthyThreadState(state)) {
              return unhealthyThreadResult(entry.threadId, state, { delivery: "codex_app_server_thread_read" });
            }
            if (state.active) {
              return {
                status: "busy",
                threadId: entry.threadId,
                activeStatus: state.statusType,
                activeFlags: state.activeFlags,
                inProgressTurnIds: state.inProgressTurnIds,
              };
            }
            return await startTurnForEntries(
              client,
              entry.threadId,
              [entry],
              config,
              true,
              Number(entry.hangRetryCount || 0) > 0 ? entry.hungTurnId || null : null
            );
          }, timeoutMs);

          if (result.status === "busy") {
            lastBusy = result;
            busyStates.push(result);
            heartbeat.update(queue.length, result.inProgressTurnIds && result.inProgressTurnIds[0] || null);
            continue;
          }
          if (result.status === "sent") {
            const sent = await attachConsumeAndReplyDelivery(result, [entry], config);
            lastReplyDelivery = sent.replyDelivery || null;
            await removePending([entry.id]);
            delivered += 1;
            madeProgress = true;
            heartbeat.update(Math.max(0, queue.length - 1), null);
            break;
          }
          lastFailure = result;
          iterationFailure = true;
          retryAttempt = Math.max(retryAttempt, Number(entry.attempts || 0) + 1);
          await bumpPendingAttempt(entry.id, JSON.stringify(result));
        } catch (error) {
          lastFailure = rpcFailure(error, entry.threadId);
          iterationFailure = true;
          retryAttempt = Math.max(retryAttempt, Number(entry.attempts || 0) + 1);
          await bumpPendingAttempt(entry.id, error && error.message ? error.message : String(error));
        }
      }

      if (!madeProgress) {
        const retryDelayMs = iterationFailure
          ? Math.min(30_000, failureRetryBaseMs * (2 ** Math.min(5, Math.max(0, retryAttempt - 1))))
          : 0;
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
    }

    const remaining = await withDirLock(QUEUE_LOCK_DIR, async () => readPendingUnlocked().length, { waitMs: 2000 });
    heartbeat.update(remaining, lastBusy && lastBusy.inProgressTurnIds && lastBusy.inProgressTurnIds[0] || null);
    return {
      status: "pending",
      reason: "drain_timeout",
      delivered,
      pendingCount: remaining,
      pendingPath: PENDING_PATH,
      lastBusy,
      lastFailure,
      lastReplyDelivery,
      lastWakeSource,
    };
  }, { waitMs: 0, staleMs: 60 * 60 * 1000, preserveLiveOwner: true }).finally(() => heartbeat.stop());
}

async function main() {
  const config = loadJSON(CONFIG_PATH);
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
      jsonOut(await recoverReplyJobs(config));
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
    const threadId = process.env.NATIVE_AGENT_CODEX_THREAD_ID || (mode === PINNED_THREAD_MODE ? config.threadId : null);
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
      if (error && error.message === "lock_busy") {
        jsonOut({ status: "already_running", reason: "drain_lock_busy", lockDir: DRAIN_LOCK_DIR });
      } else {
        jsonOut({ status: "failed", reason: "drain_failed", error: String(error && error.message || error) });
      }
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
  const threadId = payload.threadId || process.env.NATIVE_AGENT_CODEX_THREAD_ID || (mode === PINNED_THREAD_MODE ? config.threadId : null);
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

if (require.main === module) {
  main().catch((error) => {
    jsonOut({ status: "failed", reason: "uncaught_error", error: String(error && error.message || error) });
    process.exit(0);
  });
}

module.exports = {
  attachConsumeAndReplyDelivery,
  brainControlsForEntries,
  createDrainerHeartbeat,
  daemonVersionsMismatch,
  daemonWorkingDirectoryMismatch,
  daemonWorkingDirectoryState,
  parseLsofWorkingDirectory,
  deliverReplyJob,
  dirLockOwnerAlive,
  extractTurnResultFromRollout,
  extractTurnResultFromThread,
  extractTurnResultFromTurn,
  formatCodexReplyForNativeAgent,
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
  finalizeReplyJobFile,
  pruneUndeliveredReplyJobs,
  quarantineReplyJob,
  readCanonicalTurnResult,
  redactDiagnosticText,
  recoverReplyJobs,
  recoverHungTurn,
  runCodexExecFallback,
  sanitizePayload,
  stableUUID,
  startTurnWithDurableReplyAdmission,
  turnStartParams,
  unattendedServerRequestReply,
  waitForPendingDrainInvalidation,
  waitForDurableTerminalExecution,
  waitForTurnResultWithEmptyRetry,
  waitForTurnResultEventFirst,
  withDirLock,
};
