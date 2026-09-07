"use strict";

// Mechanics shared by wake workers; delivery and durability decisions stay with callers.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function jsonOut(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function nowISO() {
  return new Date().toISOString();
}

// Preserve valid JSON values verbatim; callers own shape checks and the value
// used when the file cannot be read or decoded.
function readWakeJSON(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

// Keep the caller's error formatting; Codex and Claude expose different
// historical error boundaries. Successful reads use the same trimmed token.
function readWakeBridgeToken(tokenPath, errorText) {
  let token;
  try {
    token = fs.readFileSync(tokenPath, "utf8").trim();
  } catch (error) {
    return { failure: {
      status: "failed", reason: "bridge_token_missing", tokenPath,
      error: errorText(error),
    } };
  }
  if (!token) {
    return { failure: { status: "failed", reason: "bridge_token_empty", tokenPath } };
  }
  return { token };
}

// Root-first depth-first traversal, preserving the snapshot's sibling order
// on a LIFO stack. A recycled PID in its own ancestry is visited only once.
function processTreeOrder(rootPid, children) {
  const order = [];
  const seen = new Set();
  const stack = [Number(rootPid)];
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    order.push(pid);
    for (const child of children.get(pid) || []) stack.push(child);
  }
  return order;
}

// Keep parsing lazy: receipt recovery may await between rows, and delivery
// confirmation stops at the first match. Callers retain malformed-row policy.
function* readWakeJSONLines(raw, onMalformed = () => {}) {
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let value;
    try { value = JSON.parse(line); } catch { onMalformed(); continue; }
    yield { line, value };
  }
}

// Lock waiters may have no other pending work; this timer must stay ref'd.
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function copyWakeProducerIdentity(payload, clean) {
  if (Number.isInteger(payload.producerSchemaVersion) && payload.producerSchemaVersion > 0) {
    clean.producerSchemaVersion = payload.producerSchemaVersion;
  }
  if (typeof payload.producerSourceRevision === "string"
      && /^[0-9a-f]{40}$/i.test(payload.producerSourceRevision)) {
    clean.producerSourceRevision = payload.producerSourceRevision.toLowerCase();
  }
}

function copyWakeCompletionOrigin(payload, clean) {
  if (payload.origin && typeof payload.origin === "object" && !Array.isArray(payload.origin)) {
    const origin = {};
    for (const key of ["surface", "destinationId", "threadId", "sourceKey", "replyTo", "correlationId"]) {
      if (typeof payload.origin[key] === "string" && payload.origin[key].trim() !== "") {
        origin[key] = payload.origin[key];
      }
    }
    if (Object.keys(origin).length > 0) clean.origin = origin;
  }
}

function redactDiagnosticText(value) {
  return String(value || "")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    .replace(/(["']?(?:access_token|refresh_token|api_key|token)["']?\s*[:=]\s*["']?)[^\s,"']+/gi, "$1[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g, "[REDACTED_JWT]")
    .replace(/\b(?:sk|ghp|github_pat|xox[baprs])[-_A-Za-z0-9]{12,}\b/g, "[REDACTED_TOKEN]");
}

// Start-time and command hash distinguish an original owner from a reused PID.
function processStartIdentity(pid) {
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart=,command="], {
    encoding: "utf8",
    timeout: 2000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0 || !String(result.stdout || "").trim()) return null;
  return crypto.createHash("sha256").update(String(result.stdout).trim()).digest("hex");
}

// JavaScript String.slice counts UTF-16 code units, so an exact preview cap can
// cut between an emoji's surrogate pair. JSON.stringify then persists a lone
// `\uD83D` that Node accepts but strict JSON readers reject. Walk code points
// and slice only at a complete scalar boundary.
function unicodePrefix(value, maxCodePoints) {
  const text = String(value ?? "");
  const limit = Math.max(0, Math.floor(Number(maxCodePoints) || 0));
  if (text.length <= limit) return text;
  let end = 0;
  let count = 0;
  for (const scalar of text) {
    if (count >= limit) break;
    end += scalar.length;
    count += 1;
  }
  return text.slice(0, end);
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

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(dir, 0o700); } catch {}
}

function fsyncDirectorySync(dir) {
  const fd = fs.openSync(dir, "r");
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

// Contents remain lazy so serialization still happens after the caller opens
// the descriptor. Close on serialization, write, or sync failure as well.
function writeSyncedAndClose(fd, contents) {
  try {
    fs.writeFileSync(fd, contents());
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

// Callers retain directory preparation, serialization timing, and whether a
// newly created file's directory-sync error escapes.
function appendSyncedWakeLine(file, contents, syncDirectory = fsyncDirectorySync) {
  const existed = fs.existsSync(file);
  const fd = fs.openSync(file, "a", 0o600);
  writeSyncedAndClose(fd, contents);
  if (!existed) syncDirectory(path.dirname(file));
  try { fs.chmodSync(file, 0o600); } catch {}
}

// Settlement closes registered resources in reverse order before resolving.
// Explicit close remains repeatable, including resources registered afterward.
function createWakeEventWaiter(onClose = () => {}) {
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
    onClose();
  }

  function signal(event) {
    if (settled) return;
    settled = true;
    close();
    resolveEvent(event);
  }

  return {
    promise, cleanup, close, signal,
    get settled() { return settled; },
    startTimeout(event, delay) { timer = setTimeout(() => signal(event), delay); },
  };
}

// O_EXCL chooses the claimant. Keep serialization after creation, close even
// on write/sync failure, and let every error except an existing claim escape.
function claimWakeJob(file, record) {
  let fd;
  try {
    fd = fs.openSync(file, "wx", 0o600);
  } catch (error) {
    if (error && error.code === "EEXIST") return false;
    throw error;
  }
  writeSyncedAndClose(fd, () => JSON.stringify(record, null, 2));
  return true;
}

function safeFilePart(value, limit) {
  return String(value || "")
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .slice(0, limit) || crypto.randomUUID();
}

// Each worker retains its own lazy cache, including a cached null observation.
function createProcessStartIdentityReader() {
  let cachedCurrentProcessStartIdentity;
  return function currentProcessStartIdentity() {
    if (cachedCurrentProcessStartIdentity === undefined) {
      cachedCurrentProcessStartIdentity = processStartIdentity(process.pid);
    }
    return cachedCurrentProcessStartIdentity;
  };
}

// Callbacks preserve the worker's delivery classification and timeout ordering.
function postBridgeRequest(transport, requestOptions, token, body, onResponse, onTimeout, onError, options = {}) {
  return new Promise((resolve) => {
    const req = transport.request({
      ...requestOptions,
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        ...(options.acceptJSON === false ? {} : { "Accept": "application/json" }),
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
        onResponse({ res, raw, parsed, httpOK, replyStatus }, resolve);
      });
    });
    req.on("timeout", () => onTimeout(req, resolve));
    req.on("error", (error) => onError(error, resolve));
    if (options.endWithBody) {
      req.end(body);
    } else {
      req.write(body);
      req.end();
    }
  });
}

// Claude reconciles ambiguous delivery against its session store. Codex keeps
// its explicit reply fields and existing failed/retry classification. Both
// require a clean 2xx {status:"ok"}; transport success alone is not delivery.
function postWakeCompletion(transport, requestOptions, token, body, sessionId, sessionStoreConfirmation = false) {
  return postBridgeRequest(transport, requestOptions, token, body,
    ({ res, raw, parsed, httpOK, replyStatus }, resolve) => {
      const ok = httpOK && replyStatus === "ok";
      const prefix = sessionStoreConfirmation ? "bridge" : "nativeagent";
      resolve({
        status: ok ? "delivered" : (sessionStoreConfirmation ? "unknown" : "failed"),
        reason: ok ? null : (httpOK ? `${prefix}_reply_${replyStatus || "missing_status"}` : `http_${res.statusCode}`),
        ...(sessionStoreConfirmation ? {
          // Legacy turn-completion acknowledgments still prove delivery.
          ackMode: ok ? (parsed && parsed.ack === "enqueued" ? "enqueued" : "turn_completion") : null,
        } : {}),
        delivery: "nativeagent_bridge_message",
        httpStatus: res.statusCode,
        sessionId: sessionId || null,
        ...(sessionStoreConfirmation ? {} : {
          replyStatus,
          nativeAgentSessionId: parsed && parsed.sessionId ? parsed.sessionId : null,
          nativeAgentReplyPreview: parsed && typeof parsed.reply === "string" ? unicodePrefix(parsed.reply, 1000) : null,
          completionDelivery: parsed && parsed.completionDelivery ? parsed.completionDelivery : null,
        }),
        rawPreview: sessionStoreConfirmation ? raw.slice(0, 500) : unicodePrefix(raw, 1000),
      });
    }, (req, resolve) => {
      if (sessionStoreConfirmation) {
        // Settle uncertainty before destroy can emit an error. Codex instead
        // keeps its existing error-handler resolution after destruction.
        resolve({
          status: "unknown",
          reason: `bridge_reply_timeout_after_${requestOptions.timeout}ms`,
          delivery: "nativeagent_bridge_message",
          sessionId: sessionId || null,
        });
      }
      req.destroy(new Error("bridge_message_timeout"));
    }, (error, resolve) => {
      const code = error && error.code;
      const provablyUnsent = code === "ECONNREFUSED" || code === "ENOTFOUND" || code === "EAI_AGAIN";
      resolve({
        status: sessionStoreConfirmation && !provablyUnsent ? "unknown" : "failed",
        reason: (error && error.message) || "bridge_message_failed",
        delivery: "nativeagent_bridge_message",
        sessionId: sessionId || null,
      });
    });
}

function missingWakeCompletionOrigin(sessionId, agentName) {
  if (typeof sessionId === "string" && sessionId.trim()) return null;
  return {
    status: "blocked", reason: "missing_origin_session", deliveryAttempted: false,
    note: ("Completion retained without posting. Identify the original " + agentName + " session and inspect this job before explicitly delivering the saved result; do not rerun the worker or guess from the current chat."),
  };
}

module.exports = {
  jsonOut, nowISO, redactDiagnosticText, processStartIdentity, unicodePrefix,
  dirLockOwnerAlive, ensureDir, fsyncDirectorySync, safeFilePart,
  createProcessStartIdentityReader, postBridgeRequest, postWakeCompletion, writeSyncedAndClose,
  copyWakeProducerIdentity, copyWakeCompletionOrigin, claimWakeJob, readWakeJSON, missingWakeCompletionOrigin,
  appendSyncedWakeLine, createWakeEventWaiter, readWakeJSONLines, sleep,
  readWakeBridgeToken, processTreeOrder,
};
