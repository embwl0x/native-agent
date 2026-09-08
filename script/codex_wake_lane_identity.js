"use strict";

const crypto = require("crypto");
const path = require("path");

function createCodexWakeLaneIdentity({ WAKE_LANES_DIR, FRESH_THREAD_MODE, UNKNOWN_WAKE_LANE }) {
/// These values mean no thread. Other non-UUID aliases remain valid:
/// `thread-a` and `codex:thread-a` must normalize to the same lane.
const CODEX_NIL_THREAD_ID = "00000000-0000-0000-0000-000000000000";
const CODEX_NON_THREAD_SENTINELS = new Set([
  "new", "fresh", "latest", "none", "null", "undefined", CODEX_NIL_THREAD_ID,
]);

function isCodexNonThreadSentinel(value) {
  const text = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (!text) return true;
  return CODEX_NON_THREAD_SENTINELS.has(text);
}

function canonicalCodexThreadId(value) {
  let result = typeof value === "string" ? value.trim() : "";
  while (/^codex:/i.test(result)) result = result.slice("codex:".length).trim();
  if (!result) return null;
  // `new`, an empty conversation_id, the nil UUID: the caller has no thread.
  // `null` is exactly what downstream already means by that — wakeLaneKey routes
  // it to a per-message fresh lane and fresh-thread mode opens a real
  // conversation, instead of pinning to a name nothing can resolve.
  if (isCodexNonThreadSentinel(result)) return null;
  return result;
}

/// One logical Codex conversation maps to one lane even when callers use the
/// public `codex:<id>` handle in one place and the raw app-server thread id in
/// another. Fresh work has no thread yet, so its durable message/correlation
/// identity is the intended lane. Truly identity-free work fails closed onto
/// one serial lane instead of guessing that two invocations are independent.
function wakeLaneKey(payload = {}, threadId = null, mode = null) {
  const canonicalThread = canonicalCodexThreadId(
    threadId || payload.threadId || payload.conversationId
  );
  if (canonicalThread) return `thread:${canonicalThread}`;

  const messageId = typeof payload.messageId === "string" && payload.messageId.trim()
    ? payload.messageId.trim()
    : (typeof payload.id === "string" && payload.id.trim() ? payload.id.trim() : null);
  if (messageId) return `fresh-message:${messageId}`;

  const correlationId = payload.origin && typeof payload.origin === "object"
    && typeof payload.origin.correlationId === "string"
    && payload.origin.correlationId.trim()
    ? payload.origin.correlationId.trim()
    : null;
  if (correlationId && mode === FRESH_THREAD_MODE) {
    return `fresh-correlation:${correlationId}`;
  }
  return UNKNOWN_WAKE_LANE;
}

function wakeLaneLockPath(laneKey, root = WAKE_LANES_DIR) {
  const normalized = String(laneKey || UNKNOWN_WAKE_LANE);
  const digest = crypto.createHash("sha256").update(normalized).digest("hex");
  // No user/thread identifier reaches the filesystem path. The fixed prefix
  // remains readable while the full digest prevents sanitized-alias clashes.
  return path.join(root, `lane-${digest}.lock`);
}

return { isCodexNonThreadSentinel, canonicalCodexThreadId, wakeLaneKey, wakeLaneLockPath };
}

module.exports = { createCodexWakeLaneIdentity };
