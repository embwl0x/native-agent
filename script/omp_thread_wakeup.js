#!/usr/bin/env node
"use strict";
// The agent and the user are addressed by their configured names; nothing in
// this file names a specific person.
const AGENT_NAME = process.env.NATIVE_AGENT_AGENT_NAME || "the agent";
const USER_NAME = process.env.NATIVE_AGENT_USER_NAME || "the user";

// NativeAgent -> OMP asynchronous wake runner.
//
// The Swift tool owns authorization and the durable inbox. This helper owns a
// second durable execution record, one serialized OMP session per topic, honest
// child-process classification, and the authenticated completion POST back to
// the agent. Production calls claim then detach; tests set OMP_WAKE_INLINE=1.

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const https = require("https");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const ROOT = process.env.NATIVE_AGENT_OMP_BRIDGE_DIR || path.join(os.homedir(), ".config", "omp-bridge");
const JOBS = path.join(ROOT, "wake-jobs");
const SESSIONS = path.join(ROOT, "wake-sessions");
const DELIVERIES = path.join(ROOT, "wake-deliveries.jsonl");
const RETURN_ROOT = process.env.NATIVE_AGENT_RETURN_BRIDGE_DIR || path.join(os.homedir(), ".config", "claude-bridge");
const TOKEN_PATH = process.env.NATIVE_AGENT_OMP_WAKE_TOKEN_PATH || path.join(RETURN_ROOT, "token");
const DESCRIPTOR_PATH = path.join(RETURN_ROOT, "bridge.json");
const DEFAULT_TIMEOUT = 900;
const DEFAULT_IDLE = 900;
const MAX_OUTPUT = 2 * 1024 * 1024;
const DEFAULT_TOPIC = "general";

function now() { return new Date().toISOString(); }
function out(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
function ensure(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(directory, 0o700); } catch {}
}
function ensureAll() { ensure(ROOT); ensure(JOBS); ensure(SESSIONS); }
function safe(value) {
  return String(value || "").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 160) || crypto.randomUUID();
}
function topicSlug(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64) || DEFAULT_TOPIC;
}
function redact(value) {
  return String(value || "")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    .replace(/\b(?:sk|ghp|github_pat|xox[baprs])[-_A-Za-z0-9]{12,}\b/g, "[REDACTED_TOKEN]");
}
function tail(value, limit = 2000) {
  const text = redact(value).trim();
  return text.length <= limit ? text : `…${text.slice(-limit)}`;
}
function atomicWrite(file, value) {
  ensure(path.dirname(file));
  const temp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(temp, file);
  try { fs.chmodSync(file, 0o600); } catch {}
}
function appendJSONL(file, value) {
  ensure(path.dirname(file));
  fs.appendFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  try { fs.chmodSync(file, 0o600); } catch {}
}
function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}
function processAlive(pid) {
  if (!Number.isInteger(Number(pid)) || Number(pid) <= 0) return false;
  try { process.kill(Number(pid), 0); return true; } catch (error) { return !error || error.code !== "ESRCH"; }
}
function processTree(rootPid) {
  const probe = spawnSync("/bin/ps", ["-A", "-o", "pid=,ppid="], { encoding: "utf8", timeout: 3000 });
  if (probe.status !== 0) return [rootPid];
  const children = new Map();
  for (const line of String(probe.stdout || "").split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\d+)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    const parent = Number(match[2]);
    if (!children.has(parent)) children.set(parent, []);
    children.get(parent).push(pid);
  }
  const result = [];
  const stack = [Number(rootPid)];
  const seen = new Set();
  while (stack.length) {
    const pid = stack.pop();
    if (seen.has(pid)) continue;
    seen.add(pid); result.push(pid);
    for (const child of children.get(pid) || []) stack.push(child);
  }
  return result;
}
function killTree(pid, signal) {
  for (const child of processTree(pid).reverse()) {
    if (child === process.pid) continue;
    try { process.kill(child, signal); } catch {}
  }
}

function jobPath(messageId) { return path.join(JOBS, `${safe(messageId)}.json`); }
function claim(file, record) {
  let descriptor;
  try { descriptor = fs.openSync(file, "wx", 0o600); }
  catch (error) { if (error && error.code === "EEXIST") return false; throw error; }
  try { fs.writeFileSync(descriptor, JSON.stringify(record, null, 2)); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
  return true;
}
function updateJob(file, patch, claimId) {
  const current = readJSON(file);
  if (!current || current.claimId !== claimId) return null;
  const next = { ...current, ...patch, updatedAt: now() };
  atomicWrite(file, next);
  return next;
}

function pointerPath(slug) { return path.join(SESSIONS, `${slug}.json`); }
function readPointer(slug) {
  const value = readJSON(pointerPath(slug));
  return value && typeof value.sessionId === "string" && value.sessionId ? value : null;
}
function writePointer(slug, sessionId, cwd) {
  atomicWrite(pointerPath(slug), { schemaVersion: 1, sessionId, cwd, updatedAt: now() });
  return pointerPath(slug);
}
function lockPath(slug) { return path.join(SESSIONS, `${slug}.lock`); }
function acquireLock(slug, messageId) {
  const file = lockPath(slug);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      fs.mkdirSync(file, { mode: 0o700 });
      fs.writeFileSync(path.join(file, "owner.json"), JSON.stringify({ pid: process.pid, messageId, acquiredAt: now() }), { mode: 0o600 });
      return { acquired: true, release: () => { try { fs.rmSync(file, { recursive: true, force: true }); } catch {} } };
    } catch (error) {
      if (!error || error.code !== "EEXIST") return { acquired: false, reason: "topic_lock_unavailable", owner: null, release() {} };
      const owner = readJSON(path.join(file, "owner.json"));
      // Missing/unreadable owner may be another claimant between mkdir and
      // owner publication. Absence is not proof that this lock is abandoned.
      if (!owner || !Number.isInteger(Number(owner.pid)) || Number(owner.pid) <= 0 || processAlive(owner.pid)) return { acquired: false, reason: "topic_busy", owner, release() {} };
      try { fs.rmSync(file, { recursive: true, force: true }); } catch {}
    }
  }
  return { acquired: false, reason: "topic_lock_unavailable", owner: null, release() {} };
}

function numberEnv(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}
function timeoutSeconds(payload) {
  const test = Number(process.env.NATIVE_AGENT_OMP_WAKE_TIMEOUT_SECONDS);
  if (Number.isFinite(test) && test > 0) return Math.min(3600, test);
  const value = Number(payload.timeoutSeconds);
  return Number.isFinite(value) && value > 0 ? Math.max(60, Math.min(3600, Math.round(value))) : DEFAULT_TIMEOUT;
}
function idleSeconds(payload, timeout) {
  const test = Number(process.env.NATIVE_AGENT_OMP_WAKE_IDLE_SECONDS);
  if (Number.isFinite(test)) return test > 0 ? test : 0;
  const value = Number(payload.idleSeconds);
  if (Number.isFinite(value)) return value > 0 ? Math.min(timeout, value) : 0;
  return Math.min(timeout, DEFAULT_IDLE);
}
function resolveCwd(payload, pointer) {
  for (const candidate of [payload.cwd, pointer && pointer.cwd, process.env.NATIVE_AGENT_OMP_WAKE_CWD, process.cwd()]) {
    if (typeof candidate !== "string" || !candidate) continue;
    try { if (fs.statSync(candidate).isDirectory()) return fs.realpathSync(candidate); } catch {}
  }
  return process.cwd();
}

function prompt(payload) {
  return [
    (AGENT_NAME + " sent this through NativeAgent's unattended omp_message bridge."),
    `Message id: ${payload.messageId}`,
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Priority: ${payload.priority || "info"}`,
    "",
    String(payload.text || ""),
    "",
    ("Do the work now. Your final assistant text is returned to " + AGENT_NAME + " as an asynchronous receipt. Always provide a nonempty final answer, including for failures or no-op work."),
  ].join("\n");
}

function collectText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(collectText).filter(Boolean).join("\n");
  if (!value || typeof value !== "object") return "";
  if (typeof value.text === "string") return value.text;
  if (typeof value.output_text === "string") return value.output_text;
  if (typeof value.content === "string") return value.content;
  if (Array.isArray(value.content)) return collectText(value.content);
  return "";
}
function parseOMPOutput(stdout) {
  const values = [];
  const trimmed = String(stdout || "").trim();
  if (!trimmed) return { reply: "", partialReply: "", stopReason: null, errorMessage: null, sessionId: null, parsedEvents: 0 };
  try { values.push(JSON.parse(trimmed)); }
  catch {
    for (const line of trimmed.split("\n")) {
      try { values.push(JSON.parse(line)); } catch {}
    }
  }
  let sessionId = null;
  let reply = "";
  let lastNonemptyReply = "";
  let stopReason = null;
  let errorMessage = null;
  const visit = (value) => {
    if (!value || typeof value !== "object") return;
    const type = String(value.type || value.event || "").toLowerCase();
    if (!sessionId) {
      for (const key of ["sessionId", "session_id", "sessionID"]) {
        if (typeof value[key] === "string" && value[key]) { sessionId = value[key]; break; }
      }
      if (!sessionId && type === "session" && typeof value.id === "string" && value.id) sessionId = value.id;
    }
    const role = String(value.role || value.author || "").toLowerCase();
    if (role === "assistant" || role === "agent") {
      const text = collectText(value).trim();
      const terminalReason = typeof value.stopReason === "string" && value.stopReason.trim()
        ? value.stopReason.trim().toLowerCase() : null;
      // OMP JSON print mode can exit zero after an assistant error/abort.
      // A terminal message is evidence even when its content is empty; never
      // let an earlier assistant answer turn that terminal failure into success.
      const finalAssistant = ["stop", "error", "aborted"].includes(terminalReason);
      if (finalAssistant || text) {
        reply = text;
        stopReason = terminalReason;
        errorMessage = typeof value.errorMessage === "string" ? value.errorMessage : null;
      }
      if (text) lastNonemptyReply = text;
    }
    for (const child of Object.values(value)) {
      if (child && typeof child === "object") {
        if (Array.isArray(child)) child.forEach(visit); else visit(child);
      }
    }
  };
  values.forEach(visit);
  const failedTerminal = stopReason === "error" || stopReason === "aborted";
  return { reply, partialReply: failedTerminal && !reply ? lastNonemptyReply : "", stopReason, errorMessage, sessionId, parsedEvents: values.length };
}

function runOMP({ payload, pointer, cwd, timeout, idle, onActivity }) {
  return new Promise((resolve) => {
    const bin = process.env.NATIVE_AGENT_OMP_WAKE_BIN || "omp";
    const args = ["--model", "kimi", "-p", prompt(payload), "--mode", "json", "--max-time", `${timeout}s`];
    if (pointer) args.push("-r", pointer.sessionId);
    const started = Date.now();
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    let stalled = false;
    let lastActivityAt = Date.now();
    let child;
    let deadlineTimer = null;
    let idleTimer = null;
    let killTimer = null;
    const finish = (extra) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadlineTimer); clearInterval(idleTimer); clearTimeout(killTimer);
      resolve({ stdout, stderr, timedOut, stalled, durationMs: Date.now() - started, lastActivityAt: new Date(lastActivityAt).toISOString(), ...extra });
    };
    const kill = () => {
      if (!child || !child.pid) return;
      killTree(child.pid, "SIGTERM");
      killTimer = setTimeout(() => killTree(child.pid, "SIGKILL"), 2000);
    };
    try { child = spawn(bin, args, { cwd, stdio: ["ignore", "pipe", "pipe"] }); }
    catch (error) { return finish({ exitCode: null, signal: null, spawnError: String(error && error.message || error) }); }
    const capture = (kind, chunk) => {
      lastActivityAt = Date.now();
      if (typeof onActivity === "function") onActivity(new Date(lastActivityAt).toISOString());
      const text = chunk.toString("utf8");
      if (kind === "stdout") stdout = (stdout + text).slice(-MAX_OUTPUT);
      else stderr = (stderr + text).slice(-MAX_OUTPUT);
    };
    child.stdout.on("data", (chunk) => capture("stdout", chunk));
    child.stderr.on("data", (chunk) => capture("stderr", chunk));
    child.on("error", (error) => finish({ exitCode: null, signal: null, spawnError: String(error && error.message || error) }));
    child.on("close", (code, signal) => finish({ exitCode: code, signal }));
    deadlineTimer = setTimeout(() => { timedOut = true; kill(); }, timeout * 1000 + 2000);
    idleTimer = setInterval(() => {
      if (idle > 0 && Date.now() - lastActivityAt >= idle * 1000) { stalled = true; kill(); }
    }, Math.max(100, Math.min(5000, idle * 250)));
  });
}

function classify(run) {
  const parsed = parseOMPOutput(run.stdout);
  const base = {
    exitCode: run.exitCode,
    signal: run.signal || null,
    durationMs: run.durationMs,
    lastActivityAt: run.lastActivityAt,
    reply: parsed.reply,
    partialReply: parsed.partialReply,
    assistantStopReason: parsed.stopReason,
    assistantError: parsed.errorMessage ? tail(parsed.errorMessage) : null,
    sessionId: parsed.sessionId,
    parsedEvents: parsed.parsedEvents,
    stderrTail: tail(run.stderr),
    stdoutTail: tail(run.stdout),
    timedOut: run.timedOut === true,
    stalled: run.stalled === true,
  };
  if (run.spawnError) return { ...base, status: "failed", reason: "omp_spawn_failed", detail: redact(run.spawnError) };
  if (run.stalled) return { ...base, status: "failed", reason: "omp_idle_timeout" };
  if (run.timedOut) return { ...base, status: "failed", reason: "omp_wall_timeout" };
  if (run.exitCode !== 0) return { ...base, status: "failed", reason: `omp_exit_${run.exitCode == null ? "null" : run.exitCode}` };
  if (parsed.stopReason === "error" || parsed.stopReason === "aborted") {
    return { ...base, status: "failed", reason: `omp_assistant_${parsed.stopReason}` };
  }
  if (!parsed.reply) return { ...base, status: "failed", reason: parsed.parsedEvents ? "omp_empty_reply" : "omp_json_parse_failed" };
  return { ...base, status: "completed", reason: null };
}

function completionText(result, payload) {
  const lines = [
    "[omp-wake] Automated completion event. Reply on the same topic only when there is new work or an answer to OMP's question.",
    "",
    `Originating message id: ${payload.messageId}`,
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Conversation: omp:${topicSlug(payload.topic)}`,
    "Continue this same work by calling omp_message with conversation_id set to that exact value. Omit conversation_id for new work.",
    `Priority: ${payload.priority || "info"}`,
    `Status: ${result.status}`,
    `Duration: ${Math.round((result.durationMs || 0) / 1000)}s`,
    "",
  ];
  if (result.status === "completed") lines.push("--- OMP's reply ---", result.reply, "--- end reply ---");
  else {
    lines.push(`OMP wake FAILED: ${result.reason}`);
    if (result.reason === "continuation_unavailable") lines.push("The explicitly requested conversation pointer is unavailable. No OMP work or fresh conversation was started. Inspect the original conversation pointer before explicitly choosing how to continue; do not automatically rerun this job as new work.");
    if (result.assistantError) lines.push(`Assistant error: ${result.assistantError}`);
    if (result.timedOut) lines.push("The OMP process exceeded its wall-clock guard, was terminated, and only then classified as timed out.");
    if (result.stalled) lines.push(`The OMP process produced no stdout/stderr activity after ${result.lastActivityAt}; it was terminated and only then classified as stalled.`);
    if (result.stderrTail) lines.push("", "stderr tail:", result.stderrTail);
    if (result.reply || result.partialReply) lines.push("", "partial parsed reply:", result.reply || result.partialReply);
  }
  return lines.join("\n");
}

function bridgeURL() {
  if (process.env.NATIVE_AGENT_OMP_WAKE_BRIDGE_URL) return process.env.NATIVE_AGENT_OMP_WAKE_BRIDGE_URL;
  const descriptor = readJSON(DESCRIPTOR_PATH);
  if (descriptor && typeof descriptor.url === "string") return new URL("/omp/message", descriptor.url).toString();
  return "http://127.0.0.1:8771/omp/message";
}
function missingCompletionOrigin(sessionId) {
  if (typeof sessionId === "string" && sessionId.trim()) return null;
  return { status: "blocked", reason: "missing_origin_session", deliveryAttempted: false,
    note: ("Completion retained without posting. Identify the original " + AGENT_NAME + " session and inspect this job before explicitly delivering the saved result; do not rerun the worker or guess from the current chat.") };
}

function postBridge(text, sessionId) {
  const missingOrigin = missingCompletionOrigin(sessionId);
  if (missingOrigin) return Promise.resolve(missingOrigin);
  sessionId = sessionId.trim();
  if (process.env.NATIVE_AGENT_OMP_WAKE_DRY_RUN === "1") return Promise.resolve({ status: "dry_run", text });
  let token;
  try { token = fs.readFileSync(TOKEN_PATH, "utf8").trim(); } catch { return Promise.resolve({ status: "failed", reason: "bridge_token_missing" }); }
  if (!token) return Promise.resolve({ status: "failed", reason: "bridge_token_empty" });
  let url;
  try { url = new URL(bridgeURL()); } catch { return Promise.resolve({ status: "failed", reason: "bridge_url_invalid" }); }
  const body = JSON.stringify({ text, sender: "omp", ackMode: "enqueue", ...(sessionId ? { sessionId } : {}) });
  return new Promise((resolve) => {
    const transport = url.protocol === "https:" ? https : http;
    const request = transport.request({
      hostname: url.hostname, port: url.port, path: `${url.pathname}${url.search}`, method: "POST", timeout: 30_000,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        let parsed = null;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch {}
        const delivered = response.statusCode >= 200 && response.statusCode < 300 && parsed && parsed.status === "ok";
        resolve({ status: delivered ? "delivered" : "unknown", reason: delivered ? null : `http_${response.statusCode}`, httpStatus: response.statusCode });
      });
    });
    request.on("timeout", () => { resolve({ status: "unknown", reason: "bridge_reply_timeout" }); request.destroy(); });
    request.on("error", (error) => resolve({ status: error.code === "ECONNREFUSED" ? "failed" : "unknown", reason: String(error.message || error) }));
    request.end(body);
  });
}

async function runJob(payload, file, claimId) {
  const admitted = readJSON(file);
  if (!admitted || admitted.claimId !== claimId) return { status: "failed", reason: "claim_lost", messageId: payload.messageId };
  if (!["claimed", "dispatching"].includes(admitted.state)) return { status: "skipped", reason: "execution_already_admitted", messageId: payload.messageId, existingState: admitted.state || "unknown" };
  const slug = topicSlug(payload.topic);
  const lock = acquireLock(slug, payload.messageId);
  if (!lock.acquired) {
    if (lock.owner && lock.owner.messageId === payload.messageId) {
      return { status: "skipped", reason: "execution_already_admitted", messageId: payload.messageId };
    }
    const result = { status: "failed", reason: lock.reason, durationMs: 0, stderrTail: "", reply: "", timedOut: false, stalled: false };
    const text = completionText(result, payload);
    const bridge = await postBridge(text, payload.sessionId || "");
    updateJob(file, { state: "settled", ...result, bridge,
      completionText: bridge.reason === "missing_origin_session" ? text : null, completedAt: now() }, claimId);
    appendJSONL(DELIVERIES, { createdAt: now(), messageId: payload.messageId, topicSlug: slug, ...result, bridge, inFlightMessageId: lock.owner && lock.owner.messageId || null });
    return { ...result, delivery: "omp_thread_wakeup", messageId: payload.messageId, topicSlug: slug, bridge, jobPath: file };
  }
  try {
    const pointer = readPointer(slug);
    const continuationUnavailable = payload.requireExistingConversation === true
      && (!pointer || !pointer.sessionId.trim());
    const cwd = resolveCwd(payload, pointer);
    const timeout = timeoutSeconds(payload);
    const idle = idleSeconds(payload, timeout);
    if (!continuationUnavailable && !updateJob(file, { state: "running", runnerPid: process.pid, startedAt: now(), cwd, sessionMode: pointer ? "resume" : "new", resumedSessionId: pointer && pointer.sessionId || null, timeoutSeconds: timeout, idleSeconds: idle }, claimId)) {
      return { status: "failed", reason: "claim_lost", messageId: payload.messageId };
    }
    const run = continuationUnavailable ? null : await runOMP({
      payload, pointer, cwd, timeout, idle,
      onActivity: (lastActivityAt) => updateJob(file, { lastActivityAt }, claimId),
    });
    const result = continuationUnavailable
      ? { status: "failed", reason: "continuation_unavailable", durationMs: 0, stderrTail: "", reply: "", timedOut: false, stalled: false }
      : classify(run);
    if (result.status === "completed" && !result.sessionId && pointer) result.sessionId = pointer.sessionId;
    let pointerFile = null;
    if (result.status === "completed" && result.sessionId) pointerFile = writePointer(slug, result.sessionId, cwd);
    const text = completionText(result, payload);
    const bridge = await postBridge(text, payload.sessionId || "");
    const sessionMode = continuationUnavailable ? "resume_unavailable" : pointer ? "resume" : "new";
    const receipt = { createdAt: now(), messageId: payload.messageId, topicSlug: slug, sessionMode, pointerPath: pointerFile, ...result, bridge };
    appendJSONL(DELIVERIES, receipt);
    updateJob(file, { state: "settled", ...result, bridge, sessionMode, pointerPath: pointerFile, completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : text, completedAt: now() }, claimId);
    const envelope = { ...result, delivery: "omp_thread_wakeup", messageId: payload.messageId, topicSlug: slug, sessionMode, pointerPath: pointerFile, bridge, jobPath: file, receiptPath: DELIVERIES };
    if (bridge.status === "dry_run") envelope.wouldSendText = bridge.text;
    return envelope;
  } finally { lock.release(); }
}

async function detach(file, claimId) {
  // Admission precedes spawn. A crash in the spawn/PID-write window is an
  // uncertain dispatch, not a safe-to-retry claim. The child alone publishes
  // running/settled state and its PID before invoking OMP; the parent must not
  // rewind a fast child's settled record with a late "dispatched" write.
  if (!updateJob(file, { state: "dispatching" }, claimId)) throw new Error("claim_lost");
  let child;
  try {
    child = spawn(process.execPath, [__filename, "--run", file, "--claim", claimId], { detached: true, stdio: "ignore", env: process.env });
    await new Promise((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });
  } catch (error) {
    updateJob(file, { state: "spawn_failed", reason: "runner_spawn_failed" }, claimId);
    throw error;
  }
  child.unref();
  return child.pid;
}

function knownUnstartedJob(job) {
  // Only this schema records dispatch admission BEFORE spawning. A legacy
  // claimed row can hide an unrecorded child, and dead PIDs cannot prove that
  // a running worker made no filesystem or external changes.
  const rejectedBeforeExecution = job && job.schemaVersion === 2
    && job.state === "settled" && job.status === "failed" && job.reason === "topic_busy";
  return job && job.schemaVersion >= 2
    && (["claimed", "spawn_failed"].includes(job.state) || rejectedBeforeExecution)
    && !job.startedAt && !job.lastActivityAt && !job.runnerPid
    && job.payload && typeof job.payload.text === "string" && job.payload.text.trim()
    && job.payload.messageId === job.messageId;
}

async function recoverExistingJob(file, payload, record, claimId) {
  const existing = readJSON(file);
  if (!existing) return { status: "skipped", reason: "existing_job_unreadable", messageId: payload.messageId, jobPath: file };
  if (existing.messageId !== payload.messageId) return { status: "failed", reason: "message_id_conflict", messageId: payload.messageId, jobPath: file };
  const slug = topicSlug(existing.payload && existing.payload.topic);
  // Reuse the existing conversation lock for duplicate recovery; two retries
  // must not both POST the same known-unsent completion or rename a new claim.
  const lock = acquireLock(slug, payload.messageId);
  if (!lock.acquired) return { status: "skipped", reason: "duplicate", messageId: payload.messageId, jobPath: file, existingState: existing.state || "unknown" };
  try {
    const job = readJSON(file);
    if (!job || job.claimId !== existing.claimId) return { status: "skipped", reason: "claim_changed", messageId: payload.messageId, jobPath: file };
    if (job.state === "settled" && job.bridge && job.bridge.reason === "missing_origin_session") {
      return { status: "blocked", reason: "missing_origin_session", messageId: payload.messageId,
        bridge: job.bridge, jobPath: file, note: job.bridge.note };
    }
    if (job.state === "settled" && typeof job.completionText === "string" && job.completionText) {
      if (!job.bridge || job.bridge.status !== "failed") {
        return { status: "skipped", reason: "delivery_outcome_unknown", messageId: payload.messageId, bridge: job.bridge || { status: "unknown" }, jobPath: file, note: "Completion retained. Reconcile the original delivery before any resend; a timeout is not proof of non-delivery." };
      }
      const missingOrigin = missingCompletionOrigin(job.payload && job.payload.sessionId);
      if (missingOrigin) {
        updateJob(file, { bridge: missingOrigin }, job.claimId);
        return { status: "blocked", reason: missingOrigin.reason, messageId: payload.messageId,
          bridge: missingOrigin, jobPath: file, note: missingOrigin.note };
      }
      // Persist uncertainty BEFORE POST. If this process dies, a later retry
      // cannot mistake the previous proven-unsent state for the new attempt.
      if (!updateJob(file, { bridge: { status: "unknown", reason: "completion_replay_in_flight" } }, job.claimId)) {
        return { status: "failed", reason: "claim_lost", messageId: payload.messageId, jobPath: file };
      }
      const bridge = await postBridge(job.completionText, job.payload && job.payload.sessionId || "");
      updateJob(file, { bridge, completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : job.completionText, replayedAt: now() }, job.claimId);
      appendJSONL(DELIVERIES, { createdAt: now(), kind: "delivery_replay", messageId: payload.messageId, status: job.status || "unknown", reason: job.reason || null, bridge });
      return { status: bridge.status === "delivered" || bridge.status === "dry_run" ? "replayed" : "skipped", reason: "duplicate_delivery_replay", messageId: payload.messageId, bridge, jobPath: file };
    }
    const owners = [job.claimantPid, job.runnerPid].filter((pid) => Number.isInteger(Number(pid)) && Number(pid) > 0);
    // Settled topic-busy rejections are proven before OMP execution. Only an
    // explicit same-id call can re-admit them; archive the rejection/delivery
    // record and retain the original payload under this existing topic lock.
    if ((job.state !== "settled" || knownUnstartedJob(job))
        && owners.length > 0 && owners.every((pid) => !processAlive(pid))) {
      if (!knownUnstartedJob(job)) {
        return { status: "skipped", reason: "execution_outcome_unknown", messageId: payload.messageId, jobPath: file, existingState: job.state || "unknown", note: "The owner is gone, but effects may already have occurred. Inspect this job and the original conversation before explicitly authorizing new work." };
      }
      const stale = `${file}.stale-${crypto.randomUUID()}`;
      fs.renameSync(file, stale);
      // Recover the original accepted payload, never a replacement brief or
      // session supplied alongside a reused message id.
      if (claim(file, { ...record, payload: job.payload, takeover: { reason: "unstarted_owner_dead", staleJobPath: stale } })) {
        return { recoveredPayload: job.payload };
      }
    }
    return { status: "skipped", reason: "duplicate", messageId: payload.messageId, jobPath: file, existingState: job.state || "unknown" };
  } finally { lock.release(); }
}

async function main() {
  ensureAll();
  if (process.argv[2] === "--run") {
    const file = process.argv[3];
    const claimId = process.argv[5];
    const record = readJSON(file);
    if (!record || record.claimId !== claimId) return out({ status: "failed", reason: "claim_lost" });
    return out(await runJob(record.payload, file, claimId));
  }
  let payload;
  try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { return out({ status: "skipped", reason: "invalid_json" }); }
  if (!payload || !String(payload.text || "").trim()) return out({ status: "skipped", reason: "missing_text" });
  payload.messageId = String(payload.messageId || crypto.randomUUID());
  const file = jobPath(payload.messageId);
  const claimId = crypto.randomUUID();
  const record = { schemaVersion: 2, messageId: payload.messageId, claimId, state: "claimed", createdAt: now(), claimantPid: process.pid, payload };
  if (!claim(file, record)) {
    const resolution = await recoverExistingJob(file, payload, record, claimId);
    if (!resolution.recoveredPayload) return out(resolution);
    payload = resolution.recoveredPayload;
    if (process.env.NATIVE_AGENT_OMP_WAKE_INLINE === "1") return out(await runJob(payload, file, claimId));
    const runnerPid = await detach(file, claimId);
    return out({ status: "sent", mode: "detached", delivery: "omp_thread_wakeup", messageId: payload.messageId, runnerPid, jobPath: file, takeover: true });
  }
  if (process.env.NATIVE_AGENT_OMP_WAKE_INLINE === "1") return out(await runJob(payload, file, claimId));
  const runnerPid = await detach(file, claimId);
  return out({ status: "sent", mode: "detached", delivery: "omp_thread_wakeup", messageId: payload.messageId, runnerPid, jobPath: file });
}

if (require.main === module) main().catch((error) => { out({ status: "failed", reason: "runner_exception", error: redact(error && error.stack || error) }); process.exitCode = 1; });

module.exports = { topicSlug, parseOMPOutput, classify, timeoutSeconds, idleSeconds, completionText };
