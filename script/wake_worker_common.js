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

function lifeOf(stamp, source = "wake record") {
  if (typeof stamp !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(stamp)) {
    throw new Error(`Life identity unavailable at ${source}; preserve and reconcile this record before continuing.`);
  }
  return stamp;
}

// The Swift data-root owner creates this identity before admitting work.
function dataRootLife() {
  if (!process.env.NATIVE_AGENT_DATA_ROOT) throw new Error("NativeAgent data root is unavailable");
  const life = fs.readFileSync(path.join(process.env.NATIVE_AGENT_DATA_ROOT, "life-id"), "utf8");
  if (life.length !== 36 || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(life)) throw new Error("NativeAgent life id is unreadable");
  return life;
}

// Only proven absence admits the caller's genesis value. Existing unreadable
// bytes must never become a new policy, conversation or execution record.
function readWakeJSON(file, absent = null) {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(fs.readFileSync(file)));
  } catch (error) {
    if (error.code === "ENOENT") return absent;
    throw new Error(`Wake JSON unavailable at ${file}: ${error.message}. Repair this file before retrying.`, { cause: error });
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
function* readWakeJSONLines(raw, onMalformed = null, source = "<input>") {
  let row = 0;
  for (const line of raw.split("\n")) {
    row += 1;
    if (!line.trim()) continue;
    let value;
    try { value = JSON.parse(line); } catch (error) {
      if (!onMalformed) throw new Error(`Wake JSONL row ${row} at ${source} is unreadable: ${error.message}. Retained bytes were not rewritten.`, { cause: error });
      onMalformed(row, error);
      continue;
    }
    yield { line, value };
  }
}

// Codex commits JSONL records with LF. Snapshot only those bytes, before UTF-8
// decoding: an append may stop inside a JSON token or a multibyte scalar. The
// next owner read sees the same tail when its writer publishes the boundary.
function readRolloutRows(file) {
  const bytes = fs.readFileSync(file);
  const end = bytes.lastIndexOf(10);
  const complete = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, end + 1));
  return readWakeJSONLines(complete, null, file);
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

// BSD flock belongs to this open file description, inherited as fd 3 by lockf.
// The kernel releases it when the worker closes/exits, even during acquisition.
// Keep sidecars in place: unlinking would create two independent lock owners.
function acquireWakeLock(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const fd = fs.openSync(file, "a+", 0o600);
  try {
    const result = spawnSync("/usr/bin/lockf", ["-s", "-t", "0", "3"], {
      stdio: ["ignore", "ignore", "pipe", fd], encoding: "utf8", timeout: 2000,
    });
    if (result.error || result.signal || ![0, 75].includes(result.status)) {
      throw new Error(`Wake lock unavailable at ${file}: ${result.error?.message || result.stderr || result.signal || result.status}`);
    }
    if (result.status === 75) { fs.closeSync(fd); return { acquired: false, release() {} }; }
    const opened = fs.fstatSync(fd, { bigint: true });
    const atPath = fs.statSync(file, { bigint: true });
    if (opened.dev !== atPath.dev || opened.ino !== atPath.ino) throw new Error(`Wake lock sidecar replaced: ${file}`);
    let held = true;
    return { acquired: true, fd, release() { if (held) { held = false; fs.closeSync(fd); } } };
  } catch (error) { fs.closeSync(fd); throw error; }
}

async function withWakeLock(file, fn, options = {}) {
  const deadline = Date.now() + (options.waitMs == null ? 2000 : options.waitMs);
  while (true) {
    const lock = acquireWakeLock(file);
    if (lock.acquired) {
      try { return await fn(); } finally { lock.release(); }
    }
    if (Date.now() >= deadline) {
      const error = new Error("lock_busy");
      error.lockDir = file;
      throw error;
    }
    await sleep(Math.min(50, Math.max(1, deadline - Date.now())));
  }
}

function wakeLockHeld(file) {
  const lock = acquireWakeLock(file);
  if (!lock.acquired) return true;
  lock.release();
  return false;
}

function processOwnerAlive(pid, recordedIdentity, source) {
  if (!Number.isInteger(pid) || pid <= 0 || typeof recordedIdentity !== "string" || !/^[0-9a-f]{64}$/.test(recordedIdentity)) {
    throw new Error(`Process identity unavailable at ${source}; ownership remains unknown.`);
  }
  try { process.kill(pid, 0); }
  catch (error) { if (error.code === "ESRCH") return false; throw error; }
  const current = processStartIdentity(pid);
  if (!current) throw new Error(`Process identity unreadable for ${source}; ownership remains unknown.`);
  return current === recordedIdentity;
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
    startTimeout(event, delay) {
      if (settled) return;
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => signal(event), delay);
    },
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

// Callbacks preserve the worker's delivery classification and timeout ordering.
function postBridgeRequest(transport, requestOptions, token, body, onResponse, onTimeout, onError, options = {}) {
  return new Promise((resolve) => {
    let settled = false;
    const settle = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    const fail = (error) => {
      if (!settled) onError(error, settle);
    };
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
      res.on("error", fail);
      res.on("end", () => {
        if (settled) return;
        const raw = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch {}
        const httpOK = res.statusCode >= 200 && res.statusCode < 300;
        const replyStatus = parsed && parsed.status ? parsed.status : null;
        onResponse({ res, raw, parsed, httpOK, replyStatus }, settle);
      });
    });
    req.on("timeout", () => {
      if (!settled) onTimeout(req, settle);
    });
    req.on("error", fail);
    if (options.endWithBody) {
      req.end(body);
    } else {
      req.write(body);
      req.end();
    }
  });
}

// Turn execution, reply presence and onward delivery remain independent facts.
function postWakeCompletion(transport, requestOptions, token, body, sessionId, completionLifecycle = false) {
  return postBridgeRequest(transport, requestOptions, token, body,
    ({ res, raw, parsed, httpOK, replyStatus }, resolve) => {
      const onward = parsed && parsed.completionDelivery;
      const hasReply = Boolean(parsed && ((typeof parsed.reply === "string" && parsed.reply.trim()) || parsed.attachments?.length));
      const ok = httpOK && (replyStatus === "ok" || (replyStatus === "completion_already_settled" && onward?.status === "completed")
        || (parsed?.execution_result_class === "succeeded" && hasReply)) && (!onward || onward.status === "completed");
      const uncertain = completionLifecycle && ["outcome_unknown", "completion_in_progress", "in_progress", "owed", "sent_unconfirmed"].includes(onward ? onward.status : replyStatus);
      const reason = parsed?.execution_result_class === "succeeded" && !hasReply ? "no_reply" : onward?.status || replyStatus;
      resolve({
        status: ok ? "delivered" : (uncertain ? "unknown" : "failed"),
        reason: ok ? null : (httpOK ? `nativeagent_reply_${reason || "missing_status"}` : `http_${res.statusCode}`),
        delivery: "nativeagent_bridge_message",
        httpStatus: res.statusCode,
        sessionId: sessionId || null,
        replyStatus,
        execution_result_class: parsed?.execution_result_class || null,
        execution_terminal: parsed?.execution_terminal === true,
        hasReply,
        replyPersisted: parsed && parsed.replyPersisted === true,
        nativeAgentSessionId: parsed && parsed.sessionId ? parsed.sessionId : null,
        nativeAgentRunId: parsed && parsed.runId ? parsed.runId : null,
        nativeAgentReplyPreview: parsed && typeof parsed.reply === "string" ? unicodePrefix(parsed.reply, 1000) : null,
        completionDelivery: parsed && parsed.completionDelivery ? parsed.completionDelivery : null,
        rawPreview: unicodePrefix(raw, 1000),
      });
    }, (req, resolve) => {
      if (completionLifecycle) {
        // Settle uncertainty before destroy can emit an error.
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
        status: completionLifecycle && !provablyUnsent ? "unknown" : "failed",
        reason: (error && error.message) || "bridge_message_failed",
        delivery: "nativeagent_bridge_message",
        sessionId: sessionId || null,
      });
    });
}

/// Live progress for one wake, into the app's shared update stream
/// (`POST /<lane>/live`, keyed by the accepted message id): started, the reply
/// text so far (coalesced to one POST per interval), tool/progress notes, and
/// finished. Display only: execution and completion keep their own outcomes;
/// the progress owner returns its availability and reports each failure. Off unless the app launched this
/// helper (NATIVE_AGENT_WAKE_LIVE=1), so tests and manual runs stay quiet.
function createWakeLivePoster({ url, tokenPath, messageIds, intervalMs = 400 }) {
  const disabled = { started() {}, partial() {}, note() {}, activity() {}, finished() { return Promise.resolve({ status: "not_requested" }); } };
  const ids = (Array.isArray(messageIds) ? messageIds : [messageIds]).filter((id) => typeof id === "string" && id);
  if (process.env.NATIVE_AGENT_WAKE_LIVE !== "1") return disabled;
  const state = { status: "available", errors: [] };
  const unavailable = (error) => {
    const detail = redactDiagnosticText(`Live progress unavailable: ${error.message || error}. Repair the bridge progress channel; execution and completion keep their own outcomes.`);
    state.status = "unavailable";
    if (!state.errors.includes(detail) && state.errors.length < 8) {
      state.errors.push(detail);
      process.stderr.write(`${detail}\n`);
    }
  };
  let target;
  let token;
  try {
    if (!url || ids.length === 0) throw new Error("missing live endpoint or message identity");
    target = new URL(url);
    token = require("fs").readFileSync(tokenPath, "utf8").trim();
    if (!token || !["http:", "https:"].includes(target.protocol)) throw new Error("invalid live endpoint or empty bridge token");
  } catch (error) {
    unavailable(error);
    return { ...disabled, finished() { return Promise.resolve(state); } };
  }
  const transport = target.protocol === "https:" ? require("https") : require("http");
  const queue = [];
  let draining = null;
  let pendingText = null;
  let timer = null;
  let lastActivity = 0;
  const post = (fields) => new Promise((resolve) => {
    const body = JSON.stringify(fields);
    const req = transport.request({
      hostname: target.hostname, port: target.port, path: `${target.pathname}${target.search}`,
      method: "POST", timeout: 2000,
      headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, (res) => {
      res.resume();
      res.on("end", () => {
        if (res.statusCode < 200 || res.statusCode >= 300) unavailable(new Error(`HTTP ${res.statusCode}`));
        resolve();
      });
      res.on("error", (error) => { unavailable(error); resolve(); });
    });
    req.on("timeout", () => { unavailable(new Error("live POST timed out after 2000ms")); req.destroy(); resolve(); });
    req.on("error", (error) => { unavailable(error); resolve(); });
    req.end(body);
  });
  const drain = async () => {
    while (queue.length) {
      const { event, fields } = queue.shift();
      for (const id of ids) await post({ message_id: id, event, ...fields }).catch(unavailable);
    }
    draining = null;
  };
  // Keep notes in order and only the newest unsent text snapshot.
  const send = (event, fields = {}) => {
    if (event === "partial") {
      const previous = queue.findIndex((item) => item.event === "partial");
      if (previous >= 0) queue.splice(previous, 1);
    }
    queue.push({ event, fields });
    if (!draining) draining = drain();
    return draining;
  };
  const flushText = () => {
    if (timer) { clearTimeout(timer); timer = null; }
    if (pendingText === null) return;
    const text = pendingText;
    pendingText = null;
    send("partial", { text: text.length > 65536 ? text.slice(-32768) : text });
  };
  return {
    started(fields = {}) { send("started", fields); },
    /// The whole reply text so far (replacement, not a delta).
    partial(text) {
      if (typeof text !== "string" || !text) return;
      pendingText = text;
      if (!timer) {
        timer = setTimeout(flushText, intervalMs);
        if (timer.unref) timer.unref();
      }
    },
    note(text) {
      if (typeof text !== "string" || !text.trim()) return;
      flushText();
      send("note", { note: text.trim().slice(0, 300) });
    },
    /// A sign of life with nothing to show; at most one POST per 5s.
    activity() {
      if (Date.now() - lastActivity < 5000) return;
      lastActivity = Date.now();
      send("activity");
    },
    async finished(note) {
      flushText();
      await send("finished", note ? { note: `Run ended: ${String(note).slice(0, 200)}` } : {});
      return state;
    },
  };
}

function missingWakeCompletionOrigin(sessionId, agentName) {
  if (typeof sessionId === "string" && sessionId.trim()) return null;
  return {
    status: "blocked", reason: "missing_origin_session", deliveryAttempted: false,
    note: ("Completion retained without posting. Identify the original " + agentName + " session and inspect this job before explicitly delivering the saved result; do not rerun the worker or guess from the current chat."),
  };
}

module.exports = {
  dataRootLife,
  lifeOf,
  jsonOut, nowISO, redactDiagnosticText, processStartIdentity, unicodePrefix,
  acquireWakeLock, withWakeLock, wakeLockHeld, processOwnerAlive, readRolloutRows,
  ensureDir, fsyncDirectorySync, safeFilePart,
  postBridgeRequest, postWakeCompletion, writeSyncedAndClose,
  copyWakeProducerIdentity, copyWakeCompletionOrigin, claimWakeJob, readWakeJSON, missingWakeCompletionOrigin,
  appendSyncedWakeLine, createWakeEventWaiter, readWakeJSONLines, sleep,
  readWakeBridgeToken, processTreeOrder, createWakeLivePoster,
};
