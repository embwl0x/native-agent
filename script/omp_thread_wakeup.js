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
const { nowISO: now, jsonOut: out, ensureDir: ensure, claimWakeJob: claim, readWakeJSON: readJSON, postWakeCompletion, missingWakeCompletionOrigin, safeFilePart, createWakeLivePoster, processStartIdentity, writeSyncedAndClose, fsyncDirectorySync } = require("./wake_worker_common.js");
const { dataRootLife, lifeOf, acquireWakeLock, withWakeLock, processOwnerAlive } = require("./wake_worker_common.js");

const ROOT = process.env.NATIVE_AGENT_OMP_BRIDGE_DIR || path.join(os.homedir(), ".config", "omp-bridge");
const JOBS = path.join(ROOT, "wake-jobs");
const RETIRED = path.join(ROOT, "wake-retired");
const UNANSWERED = path.join(ROOT, "wake-unanswered");
const SESSIONS = path.join(ROOT, "wake-sessions");
const DELIVERIES = path.join(ROOT, "wake-deliveries.jsonl");
const RETURN_ROOT = process.env.NATIVE_AGENT_RETURN_BRIDGE_DIR || path.join(os.homedir(), ".config", "claude-bridge");
const TOKEN_PATH = process.env.NATIVE_AGENT_OMP_WAKE_TOKEN_PATH || path.join(RETURN_ROOT, "token");
const DESCRIPTOR_PATH = path.join(RETURN_ROOT, "bridge.json");
const DEFAULT_TIMEOUT = 900;
const MAX_OUTPUT = 2 * 1024 * 1024;
const DEFAULT_TOPIC = "general";
const TERMINAL_HISTORY_LIMIT = 100;
const DELIVERY_HISTORY_LIMIT = 1000;
const DELIVERY_HISTORY_BYTES = 8 * 1024 * 1024;

function ensureAll() { ensure(ROOT); ensure(JOBS); ensure(SESSIONS); }
function safe(value) {
  return safeFilePart(value, 160);
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
function atomicWrite(file, value, raw = false) {
  ensure(path.dirname(file));
  const temp = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    const fd = fs.openSync(temp, "wx", 0o600);
    writeSyncedAndClose(fd, () => raw ? value : JSON.stringify(value, null, 2));
    fs.renameSync(temp, file);
    fsyncDirectorySync(path.dirname(file));
    try { fs.chmodSync(file, 0o600); } catch {}
  } finally {
    try { fs.rmSync(temp, { force: true }); } catch {}
  }
}
async function appendJSONL(file, value) {
  await withHistoryLock(() => compactDeliveryLedger(value));
}

async function withHistoryLock(fn, waitMs = 2000) {
  try { return await withWakeLock(lockPath(".history"), fn, { waitMs }); }
  catch (error) {
    if (error.message === "lock_busy" && waitMs === 0) return { status: "skipped", reason: "omp_history_busy" };
    throw error;
  }
}

function retainUnansweredSession(receipt) {
  if (!receipt || receipt.status !== "failed" || !receipt.topicSlug
      || typeof receipt.sessionId !== "string" || !receipt.sessionId.trim()) return;
  const file = path.join(UNANSWERED, `${topicSlug(receipt.topicSlug)}.json`);
  let saved;
  try { saved = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  if (saved && saved.createdAt >= receipt.createdAt) return;
  // History owns this compact identity; it never takes a conversation lock.
  atomicWrite(file, { sessionId: receipt.sessionId, model: receipt.model || null,
    reason: receipt.reason, assistantError: receipt.assistantError || null, createdAt: receipt.createdAt });
}

function compactDeliveryLedger(receipt = null) {
  let raw;
  try { raw = fs.readFileSync(DELIVERIES, "utf8"); }
  catch (error) { if (error.code !== "ENOENT") throw error; raw = ""; }
  const lines = raw.split("\n").filter((line) => line.trim());
  // Decode before replacing the ledger: malformed retained evidence stays put.
  for (const line of lines) retainUnansweredSession(JSON.parse(line));
  if (receipt) {
    retainUnansweredSession(receipt);
    lines.push(JSON.stringify(receipt));
  }
  const kept = lines.slice(-DELIVERY_HISTORY_LIMIT);
  let bytes = kept.reduce((sum, line) => sum + Buffer.byteLength(line) + 1, 0);
  while (kept.length > 1 && bytes > DELIVERY_HISTORY_BYTES) bytes -= Buffer.byteLength(kept.shift()) + 1;
  if (bytes > DELIVERY_HISTORY_BYTES) throw new Error("omp_delivery_receipt_too_large");
  if (receipt || kept.length !== lines.length) atomicWrite(DELIVERIES, `${kept.join("\n")}\n`, true);
}

function retiredJob(messageId) {
  const file = path.join(RETIRED, `${safe(messageId)}.json`);
  let record;
  try { record = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { if (error.code === "ENOENT") return null; throw error; }
  if (!record || record.messageId !== messageId) throw new Error("retired_message_id_conflict");
  return { status: "skipped", reason: "duplicate", messageId, existingState: "settled", jobPath: file };
}

function prunableJob(job) {
  return job && job.state === "settled" && !job.completionText && !knownUnstartedJob(job)
    && job.bridge && ["delivered", "dry_run"].includes(job.bridge.status)
    && typeof job.messageId === "string" && Number.isFinite(Date.parse(job.completedAt));
}

async function pruneTerminalHistory() {
  return await withHistoryLock(() => {
    compactDeliveryLedger();
    const terminal = [];
    for (const name of fs.readdirSync(JOBS).filter((name) => name.endsWith(".json"))) {
      const file = path.join(JOBS, name);
      try {
        const job = readJob(file);
        if (prunableJob(job)) terminal.push({ file, job });
      } catch (error) { process.stderr.write(`OMP retention unavailable at ${file}: ${error.message}\n`); }
    }
    terminal.sort((a, b) => Date.parse(b.job.completedAt) - Date.parse(a.job.completedAt));
    for (const { file, job } of terminal.slice(TERMINAL_HISTORY_LIMIT)) {
      const lock = acquireLock(topicSlug(job.payload && job.payload.topic), job.messageId);
      if (!lock.acquired) continue;
      try {
        const current = readJob(file);
        if (!prunableJob(current) || current.claimId !== job.claimId
            || jobOwnersAlive(current, file)) continue;
        // Keep a compact permanent replay marker OUTSIDE the enumerated jobs.
        // Publish it first; a crash or concurrent admission cannot reopen work.
        atomicWrite(path.join(RETIRED, `${safe(job.messageId)}.json`), {
          messageId: job.messageId, completedAt: job.completedAt, deliveryId: job.deliveryId || null,
        });
        fs.unlinkSync(file);
        fsyncDirectorySync(JOBS);
      } catch (error) { process.stderr.write(`OMP retention unavailable at ${file}: ${error.message}\n`); }
      finally { lock.release(); }
    }
  }, 0);
}
function jobOwnersAlive(job, file) {
  // A reused PID is not this owner. Missing identity is unavailable, never dead.
  return [[job.claimantPid, job.claimantIdentity], [job.runnerPid, job.runnerIdentity]]
    .filter(([pid]) => pid != null)
    .map(([pid, identity]) => processOwnerAlive(pid, identity, file)).some(Boolean);
}
function stopOwnedProcessGroup(pid, signal) {
  try { process.kill(-pid, signal); }
  catch (error) { if (error.code !== "ESRCH") throw error; }
}

function jobPath(messageId) { return path.join(JOBS, `${safe(messageId)}.json`); }
function readJob(file) {
  const absent = Symbol("absent");
  const value = readJSON(file, absent);
  if (value === absent) return null;
  if (!value || value.schemaVersion !== 2 || typeof value.messageId !== "string"
      || typeof value.claimId !== "string" || !value.payload || typeof value.payload !== "object"
      || !Number.isInteger(value.claimantPid) || value.claimantPid <= 0
      || typeof value.claimantIdentity !== "string" || !/^[0-9a-f]{64}$/.test(value.claimantIdentity)) {
    throw new Error(`OMP job schema is unavailable at ${file}. Repair its current admission record before continuing; effects remain unknown.`);
  }
  lifeOf(value.lifeID, file);
  lifeOf(value.payload.lifeID, `${file}.payload`);
  if (value.lifeID !== value.payload.lifeID) throw new Error(`OMP job life identity conflict at ${file}`);
  return value;
}
function updateJob(file, patch, claimId) {
  const current = readJob(file);
  if (!current || current.claimId !== claimId) return null;
  const next = { ...current, ...patch, updatedAt: now() };
  atomicWrite(file, next);
  return next;
}

function pointerPath(slug) { return path.join(SESSIONS, `${slug}.json`); }
function readPointer(slug) {
  const absent = Symbol("absent");
  const value = readJSON(pointerPath(slug), absent);
  if (value === absent) return null;
  if (!value || typeof value !== "object" || Array.isArray(value) || value.schemaVersion !== 1
      || typeof value.sessionId !== "string" || !value.sessionId.trim()
      || typeof value.cwd !== "string" || !value.cwd.trim()) {
    throw new Error(`OMP conversation pointer is invalid at ${pointerPath(slug)}. Repair it before continuing; no new session was started.`);
  }
  return value;
}
function writePointer(slug, sessionId, cwd, model) {
  atomicWrite(pointerPath(slug), { schemaVersion: 1, sessionId, cwd, ...(model ? { model } : {}), updatedAt: now() });
  return pointerPath(slug);
}
/// The newest OMP session this topic ran in, retained from delivery receipts, for a
/// conversation that has no pointer because no turn of it was ever answered.
function unansweredSession(slug) {
  const file = path.join(UNANSWERED, `${slug}.json`);
  const absent = Symbol("absent");
  const value = readJSON(file, absent);
  if (value === absent) return null;
  if (!value || typeof value !== "object" || typeof value.sessionId !== "string" || !value.sessionId.trim()) {
    throw new Error(`OMP unanswered conversation record is invalid at ${file}. Repair it before continuing.`);
  }
  return value;
}
function lockPath(slug) { return path.join(SESSIONS, `${slug}.lock`); }
function acquireLock(slug) {
  const lock = acquireWakeLock(lockPath(slug));
  return { ...lock, reason: lock.acquired ? null : "topic_busy" };
}

function timeoutSeconds(payload) {
  const test = Number(process.env.NATIVE_AGENT_OMP_WAKE_TIMEOUT_SECONDS);
  if (Number.isFinite(test) && test > 0) return Math.min(3600, test);
  const value = Number(payload.timeoutSeconds);
  return Number.isFinite(value) && value > 0 ? Math.max(60, Math.min(3600, Math.round(value))) : DEFAULT_TIMEOUT;
}
function resolveCwd(payload, pointer) {
  const candidate = payload.cwd ?? pointer?.cwd ?? process.env.NATIVE_AGENT_OMP_WAKE_CWD ?? process.cwd();
  if (typeof candidate !== "string" || !candidate.trim() || !fs.statSync(candidate).isDirectory()) {
    throw new Error("OMP working directory is invalid. Repair the selected checkout before retrying; OMP was not started.");
  }
  return fs.realpathSync(candidate);
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
function createOMPOutputReader(live) {
  let pending = "";
  let row = 0;
  let parsedEvents = 0;
  let integrityError = null;
  let sessionId = null;
  let reply = "";
  let lastNonemptyReply = "";
  let stopReason = null;
  let errorMessage = null;
  let model = null;
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
      if (typeof value.model === "string" && value.model) {
        model = typeof value.provider === "string" && value.provider ? `${value.provider}/${value.model}` : value.model;
      }
      if (text) lastNonemptyReply = text;
    }
    for (const child of Object.values(value)) {
      if (child && typeof child === "object") {
        if (Array.isArray(child)) child.forEach(visit); else visit(child);
      }
    }
  };
  const consume = (line) => {
    row += 1;
    if (!line.trim() || integrityError) return;
    try {
      const value = JSON.parse(line);
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("OMP JSON events must be objects");
      visit(value);
      parsedEvents += 1;
      if (live) forwardOMPLive(value, live);
    } catch (error) { integrityError = `OMP output row ${row} is unreadable: ${error.message}`; }
  };
  return {
    push(text) {
      if (integrityError) return;
      pending += text;
      let newline;
      while ((newline = pending.indexOf("\n")) >= 0) {
        consume(pending.slice(0, newline));
        pending = pending.slice(newline + 1);
      }
      if (integrityError) pending = "";
    },
    finish() {
      // Process exit closes the final frame even if its last LF was omitted.
      if (pending) consume(pending);
      pending = "";
      const failedTerminal = stopReason === "error" || stopReason === "aborted";
      return { reply, partialReply: failedTerminal && !reply ? lastNonemptyReply : "", stopReason, errorMessage, sessionId, model, parsedEvents, integrityError };
    },
  };
}

/// Display-only reading of one `--mode json` event for the live stream: the
/// assistant message being written (whole text so far) and tool starts.
function forwardOMPLive(value, live) {
  const type = String(value.type || "");
  const message = value.message && typeof value.message === "object" ? value.message : null;
  if (message && String(message.role || "").toLowerCase() === "assistant" && /^message/.test(type)) {
    const text = collectText(message.content).trim();
    if (text) { live.partial(text); return; }
  }
  if (type === "tool_execution_start" && typeof value.toolName === "string") { live.note(`Using ${value.toolName}`); return; }
  live.activity();
}

/// OMP's own configured default model (`modelRoles.default`), read fresh on
/// every resume. A new session picks it up by itself; a resumed session keeps
/// the model it was created on (even one whose provider is gone), so resumes
/// pass it explicitly. An unreadable model policy blocks launch.
function ompDefaultModel(bin) {
  const probe = spawnSync(bin, ["config", "get", "modelRoles", "--json"], { encoding: "utf8", timeout: 5000 });
  if (probe.status !== 0) throw new Error(`OMP default-model read failed: ${probe.error?.message || tail(probe.stderr) || probe.status}. Repair OMP modelRoles before retrying.`);
  const value = JSON.parse(String(probe.stdout || "")).value;
  if (!value || typeof value.default !== "string" || !value.default.trim()) throw new Error("OMP modelRoles.default is unavailable. Set it before continuing this conversation.");
  return value.default.trim();
}

function runOMP({ payload, pointer, cwd, timeout, onActivity, live, lock }) {
  return new Promise((resolve) => {
    const bin = process.env.NATIVE_AGENT_OMP_WAKE_BIN || "omp";
    const args = ["-p", prompt(payload), "--mode", "json", "--max-time", `${timeout}s`];
    if (pointer) {
      const model = ompDefaultModel(bin);
      args.push("--model", model);
      args.push("-r", pointer.sessionId);
    }
    const started = Date.now();
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    let lastActivityAt = Date.now();
    let child;
    let deadlineTimer = null;
    let killTimer = null;
    let heartbeatTimer = null;
    let terminationError = null;
    const protocol = createOMPOutputReader(live);
    const finish = (extra) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadlineTimer); clearTimeout(killTimer); clearInterval(heartbeatTimer);
      if (timedOut && child?.pid) {
        try { stopOwnedProcessGroup(child.pid, "SIGKILL"); }
        catch (error) { terminationError = `OMP process group cleanup is incomplete: ${error.message}`; }
      }
      resolve({ stdout, stderr, parsed: protocol.finish(), timedOut, terminationError, durationMs: Date.now() - started, lastActivityAt: new Date(lastActivityAt).toISOString(), ...extra });
    };
    const kill = () => {
      if (!child || !child.pid) return;
      try { stopOwnedProcessGroup(child.pid, "SIGTERM"); }
      catch (error) { terminationError = `OMP process group could not be stopped: ${error.message}`; }
      killTimer = setTimeout(() => {
        try { stopOwnedProcessGroup(child.pid, "SIGKILL"); }
        catch (error) { terminationError = `OMP process group could not be killed: ${error.message}`; }
      }, 2000);
    };
    // Node creates this child's process group before exec on macOS; cancellation
    // signals this one containment owner, without a guessed process-tree scan.
    // The actual OMP child also holds this topic's open file description: a
    // runner crash cannot unlock a topic while its accepted work is still alive.
    try { child = spawn(bin, args, { cwd, detached: true, stdio: ["ignore", "pipe", "pipe", lock.fd] }); }
    catch (error) { return finish({ exitCode: null, signal: null, spawnError: String(error && error.message || error) }); }
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    const capture = (kind, chunk) => {
      lastActivityAt = Date.now();
      if (typeof onActivity === "function") onActivity(new Date(lastActivityAt).toISOString());
      const text = chunk;
      if (kind === "stdout") { protocol.push(text); stdout = (stdout + text).slice(-MAX_OUTPUT); }
      else stderr = (stderr + text).slice(-MAX_OUTPUT);
    };
    child.stdout.on("data", (chunk) => capture("stdout", chunk));
    child.stderr.on("data", (chunk) => capture("stderr", chunk));
    child.on("error", (error) => finish({ exitCode: null, signal: null, spawnError: String(error && error.message || error) }));
    child.on("close", (code, signal) => finish({ exitCode: code, signal }));
    deadlineTimer = setTimeout(() => { timedOut = true; kill(); }, timeout * 1000 + 2000);
    // While OMP is alive but silent (a model thinking before its first token),
    // say so with timestamps, so a slow OMP never reads like a dead one. The
    // beat stops when the process ends or this runner dies.
    if (live) heartbeatTimer = setInterval(() => {
      if (settled || child.exitCode !== null || child.signalCode !== null) return;
      if (Date.now() - lastActivityAt < 15_000) return;
      live.note(`OMP process alive at ${now()}; last output ${new Date(lastActivityAt).toISOString()}.`);
    }, 15_000);
  });
}

function classify(run) {
  const parsed = run.parsed;
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
    model: parsed.model,
    parsedEvents: parsed.parsedEvents,
    stderrTail: tail(run.stderr),
    stdoutTail: tail(run.stdout),
    timedOut: run.timedOut === true,
    terminationError: run.terminationError || null,
  };
  if (parsed.integrityError) return { ...base, status: "failed", reason: "omp_output_unreadable", executionOutcome: "unknown", detail: parsed.integrityError };
  if (run.terminationError) return { ...base, status: "failed", reason: "omp_termination_incomplete", executionOutcome: "unknown", detail: run.terminationError };
  if (run.spawnError) return { ...base, status: "failed", reason: "omp_spawn_failed", detail: redact(run.spawnError) };
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
    "Continue this same work with agent_message: agent \"omp\" with conversation_id set to that exact value (it goes on in the conversation you named). Omit conversation_id for new work.",
    `Priority: ${payload.priority || "info"}`,
    `Status: ${result.status}`,
    `Duration: ${Math.round((result.durationMs || 0) / 1000)}s`,
  ];
  if (result.model) lines.push(`Model: ${result.model}`);
  if (result.continuityNote) lines.push(result.continuityNote);
  lines.push("");
  if (result.status === "completed") lines.push("--- OMP's reply ---", result.reply, "--- end reply ---");
  else {
    lines.push(`OMP wake FAILED: ${result.reason}`);
    if (result.detail) lines.push(result.detail);
    if (result.executionOutcome === "unknown") lines.push("The execution outcome is unknown. Inspect the retained OMP session and produced effects, and repair the reported owner before any explicit retry. NativeAgent did not replay the request.");
    if (result.reason === "continuation_unavailable") lines.push("The explicitly requested conversation pointer is unavailable. No OMP work or fresh conversation was started. Inspect the original conversation pointer before explicitly choosing how to continue; do not automatically rerun this job as new work.");
    if (result.assistantError) lines.push(`Assistant error: ${result.assistantError}`);
    if (result.timedOut && !result.terminationError) lines.push("The OMP process exceeded its wall-clock guard, was terminated, and only then classified as timed out.");
    if (result.stderrTail) lines.push("", "stderr tail:", result.stderrTail);
    if (result.reply || result.partialReply) lines.push("", "partial parsed reply:", result.reply || result.partialReply);
  }
  return lines.join("\n");
}

function bridgeURL() {
  if (process.env.NATIVE_AGENT_OMP_WAKE_BRIDGE_URL) return process.env.NATIVE_AGENT_OMP_WAKE_BRIDGE_URL;
  const descriptor = readJSON(DESCRIPTOR_PATH);
  if (descriptor && typeof descriptor.url === "string") return new URL("/omp/message", descriptor.url).toString();
  // Each install listens on its own port: no descriptor, no address.
  return null;
}
function missingCompletionOrigin(sessionId) {
  return missingWakeCompletionOrigin(sessionId, AGENT_NAME);
}

function postBridge(text, sessionId, payload, deliveryId = `omp:${payload.messageId}`) {
  if (lifeOf(payload.lifeID) !== dataRootLife()) return Promise.resolve({ status: "stopped", reason: "restored" });
  const missingOrigin = missingCompletionOrigin(sessionId);
  if (missingOrigin) return Promise.resolve(missingOrigin);
  sessionId = sessionId.trim();
  if (process.env.NATIVE_AGENT_OMP_WAKE_DRY_RUN === "1") return Promise.resolve({ status: "dry_run", text });
  let target;
  try { target = bridgeURL(); } catch { return Promise.resolve({ status: "failed", reason: "bridge_url_invalid" }); }
  if (!target) return Promise.resolve({ status: "failed", reason: "bridge_descriptor_unavailable", descriptorPath: DESCRIPTOR_PATH });
  let token;
  try { token = fs.readFileSync(TOKEN_PATH, "utf8").trim(); } catch { return Promise.resolve({ status: "failed", reason: "bridge_token_missing" }); }
  if (!token) return Promise.resolve({ status: "failed", reason: "bridge_token_empty" });
  let url;
  try { url = new URL(target); } catch { return Promise.resolve({ status: "failed", reason: "bridge_url_invalid" }); }
  const body = JSON.stringify({
    text, sender: "omp", sessionId,
    lifeID: payload.lifeID,
    origin: payload.origin,
    deliveryId,
    completion: { messageIds: [payload.messageId] },
  });
  const transport = url.protocol === "https:" ? https : http;
  return postWakeCompletion(transport, {
    hostname: url.hostname, port: url.port, path: `${url.pathname}${url.search}`, timeout: 30_000,
  }, token, body, sessionId, true);
}

async function runJob(payload, file, claimId) {
  const admitted = readJob(file);
  if (!admitted || admitted.claimId !== claimId) return { status: "failed", reason: "claim_lost", messageId: payload.messageId };
  if (lifeOf(admitted.lifeID) !== dataRootLife()) {
    updateJob(file, { state: "stopped", status: "stopped", reason: "restored" }, claimId);
    return { status: "stopped", reason: "restored", messageId: payload.messageId };
  }
  if (!["claimed", "dispatching"].includes(admitted.state)) return { status: "skipped", reason: "execution_already_admitted", messageId: payload.messageId, existingState: admitted.state || "unknown" };
  const slug = topicSlug(payload.topic);
  const lock = acquireLock(slug, payload.messageId);
  if (!lock.acquired) {
    const result = { status: "failed", reason: lock.reason, durationMs: 0, stderrTail: "", reply: "", timedOut: false };
    const text = completionText(result, payload);
    // A later explicit same-ID retry must keep its result's completion identity.
    const deliveryId = `omp-rejected:${claimId}`;
    if (!updateJob(file, { state: "delivering", ...result, runEndedAt: now(), completionText: text,
      deliveryId, bridge: { status: "unknown", reason: "completion_delivery_in_flight" } }, claimId)) {
      return { status: "failed", reason: "completion_checkpoint_failed", messageId: payload.messageId, jobPath: file };
    }
    const bridge = await postBridge(text, payload.sessionId || "", payload, deliveryId);
    updateJob(file, { state: "settled", ...result, bridge,
      completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : text, completedAt: now() }, claimId);
    await appendJSONL(DELIVERIES, { createdAt: now(), messageId: payload.messageId, topicSlug: slug, ...result, bridge });
    return { ...result, delivery: "omp_thread_wakeup", messageId: payload.messageId, topicSlug: slug, bridge, jobPath: file };
  }
  let executionStarted = false;
  try {
    const saved = readPointer(slug);
    // A conversation whose turns all failed never got a pointer (only an
    // answered turn writes one), yet OMP kept the session. Continue that
    // session rather than refusing the explicit follow-up.
    const unanswered = payload.requireExistingConversation === true && !fs.existsSync(pointerPath(slug))
      ? await withHistoryLock(() => unansweredSession(slug)) : null;
    const pointer = saved || (unanswered && { sessionId: unanswered.sessionId });
    const continuationUnavailable = payload.requireExistingConversation === true
      && (!pointer || !pointer.sessionId.trim());
    const cwd = resolveCwd(payload, pointer);
    const timeout = timeoutSeconds(payload);
    const runnerIdentity = processStartIdentity(process.pid);
    if (!runnerIdentity) throw new Error("OMP runner identity unavailable; execution was not started.");
    if (!continuationUnavailable && !updateJob(file, { state: "running", runnerPid: process.pid, runnerIdentity, startedAt: now(), cwd, sessionMode: pointer ? "resume" : "new", resumedSessionId: pointer && pointer.sessionId || null, timeoutSeconds: timeout }, claimId)) {
      return { status: "failed", reason: "claim_lost", messageId: payload.messageId };
    }
    // The app's live stream for this message: working, reply so far, finished.
    let liveURL = null;
    try { liveURL = new URL("/omp/live", bridgeURL()).toString(); } catch {}
    const live = createWakeLivePoster({ url: liveURL, tokenPath: TOKEN_PATH, messageIds: [payload.messageId] });
    if (!continuationUnavailable) live.started();
    if (!continuationUnavailable) executionStarted = true;
    const run = continuationUnavailable ? null : await runOMP({
      payload, pointer, cwd, timeout, live, lock,
      onActivity: (lastActivityAt) => updateJob(file, { lastActivityAt }, claimId),
    });
    const liveProgress = await live.finished(!run ? "the conversation to continue is unavailable; OMP was not started" : run.timedOut ? "timed out" : `exit ${run.exitCode}`);
    const result = continuationUnavailable
      ? { status: "failed", reason: "continuation_unavailable", durationMs: 0, stderrTail: "", reply: "", timedOut: false }
      : classify(run);
    result.liveProgress = liveProgress;
    if (result.status === "completed" && !result.sessionId && pointer) result.sessionId = pointer.sessionId;
    if (unanswered) {
      result.continuityNote = `Continuity: this conversation's earlier turn never got an answer (${unanswered.reason}${unanswered.assistantError ? `: ${String(unanswered.assistantError).slice(0, 200)}` : ""}), so it had no saved pointer. OMP ${result.status === "completed" ? "continued" : "tried to continue"} that same session on its current default model.`;
    } else if (saved && result.model && saved.model !== result.model) {
      result.continuityNote = `Continuity: this conversation was on ${saved.model || "a model this bridge did not record"}; OMP ${result.status === "completed" ? "continued" : "tried to continue"} it on its current default model.`;
    }
    let pointerFile = null;
    if (result.status === "completed" && result.sessionId) pointerFile = writePointer(slug, result.sessionId, cwd, result.model);
    const text = completionText(result, payload);
    const sessionMode = continuationUnavailable ? "resume_unavailable" : pointer ? "resume" : "new";
    if (!updateJob(file, { state: "delivering", ...result, sessionMode, pointerPath: pointerFile,
      runEndedAt: now(), completionText: text, deliveryId: `omp:${payload.messageId}`,
      bridge: { status: "unknown", reason: "completion_delivery_in_flight" } }, claimId)) {
      return { status: "failed", reason: "completion_checkpoint_failed", messageId: payload.messageId, jobPath: file };
    }
    const bridge = await postBridge(text, payload.sessionId || "", payload);
    const receipt = { createdAt: now(), messageId: payload.messageId, topicSlug: slug, sessionMode, pointerPath: pointerFile, ...result, bridge };
    await appendJSONL(DELIVERIES, receipt);
    updateJob(file, { state: "settled", ...result, bridge, sessionMode, pointerPath: pointerFile, completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : text, completedAt: now() }, claimId);
    const envelope = { ...result, delivery: "omp_thread_wakeup", messageId: payload.messageId, topicSlug: slug, sessionMode, pointerPath: pointerFile, bridge, jobPath: file, receiptPath: DELIVERIES };
    if (bridge.status === "dry_run") envelope.wouldSendText = bridge.text;
    return envelope;
  } catch (error) {
    // Keep failed preparation/source reads on the durable owning job; a
    // detached worker's stderr alone cannot carry the repair obligation.
    const failure = { at: now(), error: redact(String(error.message || error)),
      executionOutcome: executionStarted ? "unknown" : "not_started" };
    updateJob(file, { ownerFailure: failure }, claimId);
    throw error;
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
  // Only this schema records dispatch admission BEFORE spawning. Missing
  // admission proof never permits replay of uncertain effects.
  const rejectedBeforeExecution = job && job.schemaVersion === 2
    && job.state === "settled" && job.status === "failed" && job.reason === "topic_busy";
  return job && job.schemaVersion === 2
    && (["claimed", "spawn_failed"].includes(job.state) || rejectedBeforeExecution)
    && !job.startedAt && !job.lastActivityAt && !job.runnerPid
    && job.payload && typeof job.payload.text === "string" && job.payload.text.trim()
    && job.payload.messageId === job.messageId;
}

async function recoverExistingJob(file, payload, record, claimId) {
  const existing = readJob(file);
  if (!existing) return { status: "skipped", reason: "existing_job_unreadable", messageId: payload.messageId, jobPath: file };
  if (existing.messageId !== payload.messageId) return { status: "failed", reason: "message_id_conflict", messageId: payload.messageId, jobPath: file };
  const slug = topicSlug(existing.payload && existing.payload.topic);
  // Reuse the existing conversation lock for duplicate recovery; two retries
  // must not both POST the same known-unsent completion or rename a new claim.
  const lock = acquireLock(slug, payload.messageId);
  if (!lock.acquired) return { status: "skipped", reason: "duplicate", messageId: payload.messageId, jobPath: file, existingState: existing.state || "unknown" };
  try {
    const job = readJob(file);
    if (!job || job.claimId !== existing.claimId) return { status: "skipped", reason: "claim_changed", messageId: payload.messageId, jobPath: file };
    if (lifeOf(job.lifeID) !== dataRootLife()) {
      updateJob(file, { state: "stopped", status: "stopped", reason: "restored" }, job.claimId);
      return { status: "stopped", reason: "restored", messageId: payload.messageId, jobPath: file };
    }
    if (job.state === "settled" && job.bridge && job.bridge.reason === "missing_origin_session") {
      return { status: "blocked", reason: "missing_origin_session", messageId: payload.messageId,
        bridge: job.bridge, jobPath: file, note: job.bridge.note };
    }
    if (["settled", "delivering"].includes(job.state) && typeof job.completionText === "string" && job.completionText) {
      const routedDelivery = job.payload && (job.deliveryId === `omp:${job.payload.messageId}`
        || job.deliveryId === `omp-rejected:${job.claimId}`
        || job.deliveryId === `omp:${job.payload.messageId}:rejected:${job.claimId}`);
      if (!routedDelivery && (!job.bridge || job.bridge.status !== "failed")) {
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
      if (!updateJob(file, { state: "delivering", bridge: { status: "unknown", reason: "completion_replay_in_flight" } }, job.claimId)) {
        return { status: "failed", reason: "claim_lost", messageId: payload.messageId, jobPath: file };
      }
      const bridge = await postBridge(job.completionText, job.payload && job.payload.sessionId || "", job.payload || {}, job.deliveryId || undefined);
      updateJob(file, { state: "settled", completedAt: job.completedAt || job.runEndedAt || now(), bridge,
        completionText: bridge.status === "delivered" || bridge.status === "dry_run" ? null : job.completionText, replayedAt: now() }, job.claimId);
      await appendJSONL(DELIVERIES, { createdAt: now(), kind: "delivery_replay", messageId: payload.messageId, status: job.status || "unknown", reason: job.reason || null, bridge });
      return { status: bridge.status === "delivered" || bridge.status === "dry_run" ? "replayed" : "skipped", reason: "duplicate_delivery_replay", messageId: payload.messageId, bridge, jobPath: file };
    }
    // Settled topic-busy rejections are proven before OMP execution. Only an
    // explicit same-id call can re-admit them; archive the rejection/delivery
    // record and retain the original payload under this existing topic lock.
    if ((job.state !== "settled" || knownUnstartedJob(job))
        && !jobOwnersAlive(job, file)) {
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
    const record = readJob(file);
    if (!record || record.claimId !== claimId) return out({ status: "failed", reason: "claim_lost" });
    const result = await runJob(record.payload, file, claimId);
    await pruneTerminalHistory();
    return out(result);
  }
  let payload;
  try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { return out({ status: "skipped", reason: "invalid_json" }); }
  if (!payload || !String(payload.text || "").trim()) return out({ status: "skipped", reason: "missing_text" });
  payload.messageId = String(payload.messageId || crypto.randomUUID());
  payload.lifeID = dataRootLife();
  await pruneTerminalHistory();
  const retired = retiredJob(payload.messageId);
  if (retired) return out(retired);
  const file = jobPath(payload.messageId);
  const claimId = crypto.randomUUID();
  const claimantIdentity = processStartIdentity(process.pid);
  if (!claimantIdentity) throw new Error("OMP claimant identity unavailable; work was not admitted.");
  const record = { schemaVersion: 2, lifeID: payload.lifeID, messageId: payload.messageId, claimId, state: "claimed", createdAt: now(), claimantPid: process.pid, claimantIdentity, payload };
  if (!claim(file, record)) {
    const resolution = await recoverExistingJob(file, payload, record, claimId);
    if (!resolution.recoveredPayload) return out(resolution);
    payload = resolution.recoveredPayload;
    if (process.env.NATIVE_AGENT_OMP_WAKE_INLINE === "1") return out(await runJob(payload, file, claimId));
    const runnerPid = await detach(file, claimId);
    return out({ status: "sent", mode: "detached", delivery: "omp_thread_wakeup", messageId: payload.messageId, runnerPid, jobPath: file, takeover: true });
  }
  // Close the window between the retirement lookup and exclusive job creation.
  const retiredAfterClaim = retiredJob(payload.messageId);
  if (retiredAfterClaim) {
    fs.unlinkSync(file);
    fsyncDirectorySync(JOBS);
    return out(retiredAfterClaim);
  }
  if (process.env.NATIVE_AGENT_OMP_WAKE_INLINE === "1") return out(await runJob(payload, file, claimId));
  const runnerPid = await detach(file, claimId);
  return out({ status: "sent", mode: "detached", delivery: "omp_thread_wakeup", messageId: payload.messageId, runnerPid, jobPath: file });
}

if (require.main === module) main().catch((error) => { out({ status: "failed", reason: "runner_exception", error: redact(error && error.stack || error) }); process.exitCode = 1; });

module.exports = { topicSlug, classify, timeoutSeconds, completionText };
