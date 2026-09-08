"use strict";

// Lane-specific reply delivery; entrypoints supply runtime policy and effects.

function createCodexReplyDelivery({
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
}) {
const fs = require("fs");
const http = require("http");
const path = require("path");

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
    ("This is an asynchronous completion event for work you delegated. Compare Codex's result with your original request, decide whether it succeeded, partially succeeded, or failed, and tell " + USER_NAME + " concisely in your own voice. Do not call it successful merely because a Codex turn completed. If important work is missing, say what is missing. Only send a focused follow-up when Codex returned an actionable partial result; when the outcome is unknown, never resend the same request without an explicit decision. Follow the resend guidance in the result section below when it is present."),
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
      ? unicodePrefix(entry.payload.text.trim(), 8000)
      : "";
    if (entries.length > 1) lines.push(`Request ${index + 1}:`);
    lines.push(original || "(original request unavailable)", "");
  }
  lines.push("Codex result:");
  if (turnResult.status === "completed") {
    lines.push(turnResult.message || "(Codex completed without a final text reply.)");
  } else if (turnResult.status === "completed_without_reply") {
    lines.push("Codex accepted the wakeup but completed without a final assistant reply. The outcome is unknown: do not assume either that the task ran nothing or that it completed.");
    lines.push(("NativeAgent did not automatically replay the request because the first turn may already have produced effects. Report the bridge failure to " + USER_NAME + "; retry only after an explicit decision."));
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
    lines.push(("NativeAgent did not automatically replay the request. Report the stall to " + USER_NAME + "; retry only after an explicit decision."));
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
  lines.push("", ("Now give " + USER_NAME + " the completion update in this same conversation. Do not wait for " + USER_NAME + " to ask whether Codex finished."));
  return lines.join("\n");
}

function shouldSuppressCompletionDelivery(entries, turnResult) {
  return turnResult && turnResult.status === "completed"
    && Array.isArray(entries) && entries.length > 0
    && entries.every((entry) => entry && entry.payload
      && entry.payload.completionMode === "receipt_only");
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
      textPreview: unicodePrefix(text, 500),
    });
  }

  const tokenPath = stringSetting(config, "bridgeTokenPath", "NATIVE_AGENT_CODEX_BRIDGE_TOKEN_PATH", BRIDGE_TOKEN_PATH);
  const { token, failure } = readWakeBridgeToken(tokenPath, (error) => String(error.message || error));
  if (failure) return Promise.resolve(failure);

  const endpoint = codexReturnBridgeEndpoint(config);
  const { host, port } = endpoint;
  // Outlive the app's 600s messageWorkDeadlineSeconds so work cancellation
  // settles before the socket deadline; equal deadlines can strand replies.
  const timeoutMs = numberSetting(config, "bridgeReplyTimeoutMs", "NATIVE_AGENT_CODEX_BRIDGE_REPLY_TIMEOUT_MS", 11 * 60 * 1000);
  const body = JSON.stringify({
    text,
    sender: "codex",
    ...(metadata.deliveryId ? { deliveryId: metadata.deliveryId } : {}),
    ...(sessionId ? { sessionId } : {}),
    ...(metadata.origin ? { origin: metadata.origin } : {}),
    ...(metadata.completion ? { completion: metadata.completion } : {}),
  });

  return postWakeCompletion(http, { host, port, path: "/codex/message", timeout: timeoutMs }, token, body, sessionId);
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

// Retry transient delivery failures with bounded jitter. completedExecution
// precedes the POST, and exhausted delivery retains the job for recovery.
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
      reason: bridge && bridge.reason ? unicodePrefix(bridge.reason, 200) : null,
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

// Keep execution and delivery as separate truths on the durable job. A Codex
// turn that ended must never continue to present as `watching_turn` merely
// because the later NativeAgent handoff was ambiguous or temporarily failed.
function persistReplyJobDeliveryState(jobPath, job, bridge) {
  const disposition = replyJobDisposition(bridge);
  const outcome = bridge && (bridge.status === "delivered" || bridge.status === "dry_run")
    ? "delivered"
    : (disposition === "preserve" ? "unknown" : null);
  job.phase = outcome === "delivered"
    ? "settled"
    : (outcome === "unknown" ? "delivery_unknown" : "delivery_pending");
  job.delivery = {
    observedAt: nowISO(),
    status: bridge && bridge.status || "unknown",
    replyStatus: bridge && bridge.replyStatus || null,
    outcome,
  };
  writeJSONAtomic(jobPath, job);
  return job.delivery;
}

// Preserve out of the *.json scan path: recoverReplyJobs only reads files
// directly in jobsDir (see readdirSync + isFile filter), so a subdirectory is
// never rescanned and can never relaunch a turn.
// Bound preserved full replies independently of the live recovery queue.
const UNDELIVERED_REPLY_JOBS_CAP = 200;

// Terminal replies expire after a 30-day forensic window, even below the cap.
const UNDELIVERED_REPLY_JOBS_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

function pruneUndeliveredReplyJobs(
  undeliveredDir,
  cap = UNDELIVERED_REPLY_JOBS_CAP,
  maxAgeMs = UNDELIVERED_REPLY_JOBS_MAX_AGE_MS
) {
  let entries;
  try {
    entries = fs.readdirSync(undeliveredDir).filter((name) => name.endsWith(".json"));
  } catch {
    return;
  }
  const stamped = entries.map((name) => {
    let mtimeMs = 0;
    try { mtimeMs = fs.statSync(path.join(undeliveredDir, name)).mtimeMs; } catch {}
    return { name, mtimeMs };
  });
  stamped.sort((a, b) => a.mtimeMs - b.mtimeMs);
  // Age out first, then enforce the count cap on whatever survived. A file
  // whose stat failed carries mtimeMs 0 and would age out on every run, so it
  // is left to the count cap instead of being deleted on an unread stat.
  const ageCutoff = maxAgeMs > 0 ? Date.now() - maxAgeMs : null;
  const survivors = [];
  for (const entry of stamped) {
    if (ageCutoff !== null && entry.mtimeMs > 0 && entry.mtimeMs < ageCutoff) {
      try { fs.unlinkSync(path.join(undeliveredDir, entry.name)); } catch {}
      continue;
    }
    survivors.push(entry);
  }
  if (survivors.length <= cap) return;
  for (const victim of survivors.slice(0, survivors.length - cap)) {
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
    // world-readable with full reply text.
    try { fs.chmodSync(target, 0o600); } catch {}
    pruneUndeliveredReplyJobs(undeliveredDir);
    fsyncDirectorySync(path.dirname(jobPath));
    fsyncDirectorySync(undeliveredDir);
    return { preserved: true, undeliveredPath: target };
  } catch (error) {
    return {
      preserved: false,
      error: unicodePrefix(redactDiagnosticText(String(error && error.message || error)), 300),
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
  // These states cannot improve by replaying the same durable, cached the agent
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

return {
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
};
}

function createClaudeReplyDelivery({
  AGENT_NAME,
  BRIDGE_DESCRIPTOR_PATH,
  BRIDGE_MESSAGE_PATH,
  DEFAULT_BRIDGE_URL,
  DEFAULT_TOPIC,
  TOKEN_PATH,
  missingWakeCompletionOrigin,
  postWakeCompletion,
  readWakeBridgeToken,
  readWakeJSON,
  readWakeJSONLines,
  topicSlug
}) {
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");

/// The descriptor ClaudeBridge.swift publishes (writeDiscoveryFiles):
/// {schemaVersion, host, port, url, token, processIdentifier, writtenAt}.
function readBridgeDescriptor() {
  const parsed = readWakeJSON(BRIDGE_DESCRIPTOR_PATH);
  return parsed && typeof parsed === "object" ? parsed : null;
}

/// Precedence: explicit env override (tests / operator) -> the descriptor the
/// running bridge published -> the legacy fixed port. The bridge advances off
/// 8771 on collision, so hardcoding it meant every reply could be recorded as
/// deliveryLost while a perfectly healthy bridge listened one port over.
function bridgeURL() {
  const override = process.env.NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL;
  if (override) return override;

  const descriptor = readBridgeDescriptor();
  if (descriptor) {
    if (typeof descriptor.url === "string" && descriptor.url.trim() !== "") {
      try {
        return new URL(BRIDGE_MESSAGE_PATH, descriptor.url.trim()).toString();
      } catch {}
    }
    const port = Number(descriptor.port);
    if (Number.isInteger(port) && port > 0 && port < 65536) {
      const host = typeof descriptor.host === "string" && descriptor.host.trim() !== ""
        ? descriptor.host.trim()
        : "127.0.0.1";
      return `http://${host}:${port}${BRIDGE_MESSAGE_PATH}`;
    }
  }
  return DEFAULT_BRIDGE_URL;
}

/// Where the app persists the agent's per-session transcript
/// (data/chat/messages/<sessionId>.jsonl). The helper lives in <repo>/script
/// and the app's data root is the repo checkout, so __dirname-relative is the
/// production path; the env override exists for tests.
function messageStoreDir() {
  return process.env.NATIVE_AGENT_CLAUDE_WAKE_MESSAGE_STORE_DIR ||
    path.join(__dirname, "..", "data", "chat", "messages");
}

/// The one line of the completion text unique to OUR posted receipt. The bare
/// messageId is NOT a usable marker: the agent's transcript already carries it in
/// the original claude_message tool rows.
function deliveryMarker(messageId) {
  return `Originating message id: ${messageId}`;
}

/// Orthogonal delivery observer (the agent, 2026-07-25): a transport must not
/// grade its own delivery. The bridge enqueues the row into her session store
/// durably BEFORE her turn runs, so whether the completion reached her is
/// answered by that store — never by whether the HTTP response came back in
/// time. Returns "present" | "absent" | "unreadable"; "absent" is only
/// meaningful because the store file itself was readable.
function confirmDeliveryViaSessionStore(sessionId, messageId, expectedCompletionText) {
  const id = String(sessionId || "");
  if (!id || !messageId || !/^[A-Za-z0-9._:-]+$/.test(id)) return "unreadable";
  const marker = deliveryMarker(messageId);
  if (typeof expectedCompletionText !== "string" || !expectedCompletionText.includes("[claude-wake]")
      || !expectedCompletionText.includes(marker)) return "unreadable";
  let content;
  try {
    content = fs.readFileSync(path.join(messageStoreDir(), `${id}.jsonl`), "utf8");
  } catch {
    return "unreadable";
  }
  let sawMalformedLine = false;
  for (const { line, value: row } of readWakeJSONLines(content, () => { sawMalformedLine = true; })) {
    if (!line.includes(marker)) continue;
    const text = row && typeof row.content === "string" ? row.content : "";
    // One admitted message can first receive a topic-busy rejection and later
    // complete on an explicit same-ID retry. The shared marker is not proof
    // THIS result landed. Compare the retained result verbatim, accepting the
    // exact prefix added by ClaudeBridge.handleMessage (and legacy raw rows).
    if (text === expectedCompletionText || text === `[from: claude, via bridge] ${expectedCompletionText}`) return "present";
  }
  // A malformed line means the store was mid-write (or damaged) when we read
  // it — the missing row could BE the truncated one. "Absent" must mean the
  // store was fully readable and the message provably is not there; anything
  // less stays unknown rather than arming a false replay.
  return sawMalformedLine ? "unreadable" : "absent";
}

function formatCompletionForAgent(result, payload) {
  const lines = [
    "[claude-wake] Automated completion event. Do NOT auto-fire another claude_message in response unless you have new work for Claude — OR unless Claude ended with a question or decision request, in which case answering on the SAME topic resumes that session with full context. Question-and-answer on one topic is the supported conversation pattern; reflexive acknowledgment messages are the loop to avoid.",
    "",
    deliveryMarker(payload.messageId),
    `Topic: ${payload.topic || DEFAULT_TOPIC}`,
    `Conversation: claude:${topicSlug(payload.topic)}`,
    "Continue this same work by calling claude_message with conversation_id set to that exact value. Omit conversation_id for new work.",
    `Priority: ${payload.priority || "info"}`,
    `Status: ${result.status}`,
  ];
  if (result.durationMs != null) lines.push(`Duration: ${Math.round(result.durationMs / 1000)}s`);
  lines.push("");
  if (result.status === "completed") {
    lines.push("--- Claude's reply ---", result.reply, "--- end reply ---");
  } else if (result.status === "delivered_inbox") {
    // Presence could not be established. Say exactly that: no claim about a
    // live session, and no completion to wait for.
    lines.push(
      result.detail || "This Mac could not be scanned for an open Claude session; the message is in the durable inbox and no wake was spawned",
      "",
      "The message is in the durable inbox and NO unattended session was started for it. Live presence could NOT be established — this is not evidence that a session is open, nor that one is gone. If an open session reads the inbox it picks the message up; otherwise it waits there. There is no reply to relay, and no completion event is coming for this message."
    );
  } else if (result.status === "delivered_live") {
    // Not a failure and not a completion: the message reached a session that
    // is already open, and nothing was run unattended.
    lines.push(
      result.detail || `Session ${result.sessionId} is open interactively; message left in the inbox for it, no wake spawned`,
      "",
      "NO unattended session was started for this message, and the live session was NOT interrupted, resumed, or replaced — it is still running and still owns its working tree. The message sits in the durable inbox and reaches that session when it next reads the inbox. There is no reply to relay yet; do not treat this as a completion, a failure, or evidence that the session is gone."
    );
  } else if (result.status === "completed_without_reply") {
    lines.push(
      "Claude's session exited cleanly (exit 0) but produced NO output. There is no reply to relay — treat this as a failed wake, not as a silent success."
    );
  } else if (result.reason === "continuation_unavailable") {
    lines.push("The explicitly requested conversation could not be resumed. No fresh conversation was started. Inspect the original conversation pointer/transcript before explicitly choosing how to continue; this job must not be automatically rerun as new work.");
    if (result.stderrTail) lines.push("", "stderr tail:", result.stderrTail);
    if (result.reply) lines.push("", "partial stdout:", result.reply);
  } else if (result.reason === "rejected_topic_busy" || result.reason === "topic_lock_unavailable") {
    // Defect 3 contract: a topic collision is REJECTED loudly, by id — never
    // silently downgraded to a fresh context-free session.
    const inFlight = result.inFlightMessageId || "unknown-id";
    lines.push(
      result.reason === "topic_lock_unavailable"
        ? "Claude's wake was REJECTED: the topic lock could not be created at all, and an unserialized wake is never run (it can corrupt the topic's thread)."
        : `Claude's wake was REJECTED: another wake is already in flight on this topic (in-flight message id: ${inFlight}${result.inFlightDeadlineAt ? `, its deadline: ${result.inFlightDeadlineAt}` : ""}). This message was NOT worked and NO session — threaded or fresh — was started for it.`,
      "",
      "It remains in the durable inbox. Re-send it on this topic after the in-flight job settles; it will then resume the topic's thread with full context."
    );
  } else {
    lines.push(`Claude's wake FAILED: ${result.reason}`);
    if (result.stalled) {
      lines.push(
        "The runner was killed by the STALL watchdog, not at its deadline: Claude's canonical session transcript did not advance for the whole stall window. SIGTERM then SIGKILL after 2s — its exit is CONFIRMED. Any partial stdout below is everything it produced."
      );
    } else if (result.timedOut) {
      lines.push(
        "The runner was killed at its deadline (SIGTERM, then SIGKILL after 2s) and its exit is CONFIRMED — this verdict is about a provably stopped process, not a guess about a running one. Any partial stdout below is everything it produced."
      );
    }
    if (result.stderrTail) lines.push("", "stderr tail:", result.stderrTail);
    if (result.reply) lines.push("", "partial stdout:", result.reply);
  }
  return lines.join("\n");
}

function missingCompletionOrigin(sessionId) {
  return missingWakeCompletionOrigin(sessionId, AGENT_NAME);
}

function postBridgeMessage(text, sessionId) {
  const missingOrigin = missingCompletionOrigin(sessionId);
  if (missingOrigin) return Promise.resolve(missingOrigin);
  sessionId = sessionId.trim();
  if (process.env.NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN === "1") {
    return Promise.resolve({
      status: "dry_run",
      delivery: "nativeagent_bridge_message",
      sessionId: sessionId || null,
      text,
    });
  }

  const { token, failure } = readWakeBridgeToken(TOKEN_PATH, (error) => String((error && error.message) || error));
  if (failure) return Promise.resolve(failure);

  let url;
  try {
    url = new URL(bridgeURL());
  } catch (error) {
    return Promise.resolve({
      status: "failed",
      reason: "bridge_url_invalid",
      error: String((error && error.message) || error),
    });
  }

  const body = JSON.stringify({
    text,
    sender: "claude",
    // Request acknowledgment after durable append. Legacy bridges ignore the
    // field and acknowledge after turn completion; both shapes prove delivery.
    ackMode: "enqueue",
    ...(sessionId ? { sessionId } : {}),
  });
  const transport = url.protocol === "https:" ? https : http;
  // With ack-on-enqueue the response is disk-bound and arrives in seconds;
  // the generous ceiling only matters against a legacy bridge that still
  // couples the response to turn completion. Either way a timeout is
  // classified "unknown" — never "failed" — so it can never arm a replay.
  // The caller settles "unknown" against the session store, the orthogonal
  // observer.
  const timeoutMs = Number(process.env.NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_TIMEOUT_MS || 600_000);

  return postWakeCompletion(transport, {
    host: url.hostname,
    port: url.port || (url.protocol === "https:" ? 443 : 80),
    path: `${url.pathname}${url.search}`,
    timeout: timeoutMs,
  }, token, body, sessionId, true);
}

return {
  bridgeURL,
  deliveryMarker,
  confirmDeliveryViaSessionStore,
  formatCompletionForAgent,
  missingCompletionOrigin,
  postBridgeMessage
};
}

module.exports = { createCodexReplyDelivery, createClaudeReplyDelivery };
