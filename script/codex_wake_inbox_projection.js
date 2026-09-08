"use strict";

const fs = require("fs");
const path = require("path");

// Project already-decided delivery outcomes into the existing inbox under its lock.
function createCodexWakeInboxProjection({ BRIDGE_DIR, inboxLockDir, withDirLock, nowISO }) {
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

async function rewriteInboxEntries(entries, rewriteRow, successStatus) {
  const targetsByPath = new Map();
  for (const entry of entries) {
    const payload = entry && entry.payload ? entry.payload : {};
    const messageId = messageIdForPayload(payload);
    if (!messageId) continue;
    const inboxPath = inboxPathForPayload(payload);
    if (!targetsByPath.has(inboxPath)) targetsByPath.set(inboxPath, new Map());
    targetsByPath.get(inboxPath).set(messageId, entry);
  }
  if (targetsByPath.size === 0) {
    return { status: "skipped", reason: "message_id_missing" };
  }

  const changed = [];
  const missing = [];
  const errors = [];
  for (const [inboxPath, targets] of targetsByPath.entries()) {
    try {
      const result = await withDirLock(inboxLockDir(), async () => {
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
          const match = ids.find((id) => targets.has(id));
          if (!match) return line;
          seen.add(match);
          return JSON.stringify(rewriteRow(row, targets.get(match), match));
        });
        const tmp = `${inboxPath}.${process.pid}.${Date.now()}.tmp`;
        fs.writeFileSync(tmp, next.join("\n"), { mode: 0o600 });
        fs.renameSync(tmp, inboxPath);
        try { fs.chmodSync(inboxPath, 0o600); } catch {}
        return {
          status: "ok",
          inboxPath,
          marked: [...seen],
          missing: [...targets.keys()].filter((id) => !seen.has(id)),
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
    status: missing.length > 0 ? "partial" : successStatus,
    markedCount: changed.length,
    changed,
    missing,
  };
}

async function markInboxConsumed(entries, sent) {
  return await rewriteInboxEntries(entries, (row, _entry, match) => {
    row.read = true;
    row.messageId = row.messageId || row.id || match;
    row.readAt = row.readAt || nowISO();
    row.consumedAt = row.consumedAt || row.readAt;
    row.consumedBy = row.consumedBy || "codex_thread_wakeup";
    row.consumedThreadId = sent.threadId || row.consumedThreadId || null;
    row.consumedTurnId = sent.turnId || row.consumedTurnId || null;
    return row;
  }, "marked_read");
}

/// A dead-letter is a terminal DELIVERY failure, not an unconsumed message
/// still waiting in the queue. Project that exact distinction onto the durable
/// inbox row without marking the brief read/consumed or deleting its contents.
async function markInboxTerminal(entries) {
  return await rewriteInboxEntries(entries, (row, entry, match) => {
    const terminal = entry && entry.terminalDisposition || {};
    row.messageId = row.messageId || row.id || match;
    row.deliveryStatus = "dead_letter";
    row.deliveryTerminalAt = row.deliveryTerminalAt
      || terminal.deadLetteredAt
      || nowISO();
    row.deliveryFailureReason = terminal.reason || "terminal_failure";
    return row;
  }, "marked_terminal");
}

return { markInboxConsumed, markInboxTerminal, messageIdForPayload };
}

module.exports = { createCodexWakeInboxProjection };
