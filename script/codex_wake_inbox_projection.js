"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { isDeepStrictEqual } = require("util");

// Own the inbox JSONL schema, admission, history and delivery updates under one lock.
// Private protocol files: no app backup/export/phone file sync; contact status is
// projected separately. PrivacyMap resolves primary and relocated bridge directories.
function createCodexWakeInboxProjection({ BRIDGE_DIR, inboxLockDir, withDirLock, nowISO, writeJSONAtomic, writeTextAtomic }) {
function historyPath(inboxPath, messageId) {
  const key = crypto.createHash("sha256").update(messageId).digest("hex");
  return path.join(path.dirname(inboxPath), "codex-inbox-history", `${key}.json`);
}

// Archive consumed briefs and terminal delivery failures with their exact retry
// identity outside the hot inbox; pending briefs and reply jobs are never discarded.
function compactInbox(lines, inboxPath) {
  const completed = [];
  const identities = new Set();
  for (const [index, line] of lines.entries()) {
    if (!line.trim()) continue;
    let row;
    try { row = JSON.parse(line); } catch { throw new Error("codex inbox cannot be compacted; original bytes preserved"); }
    if (!row || typeof row !== "object" || Array.isArray(row)) {
      throw new Error("codex inbox cannot be compacted; original bytes preserved");
    }
    const id = messageIdForPayload(row);
    if (!id || identities.has(id) || (row.id !== undefined && row.messageId !== undefined && row.id !== row.messageId)) {
      throw new Error("codex inbox retry identity conflicts; original bytes preserved");
    }
    identities.add(id);
    if ((row.read === true && typeof row.consumedAt === "string" && row.consumedAt)
        || (row.deliveryStatus === "dead_letter"
            && typeof row.deliveryTerminalAt === "string" && row.deliveryTerminalAt)) {
      completed.push({ index, id, row });
    }
  }
  const removing = completed.slice(0, Math.max(0, completed.length - 256));
  for (const entry of removing) writeJSONAtomic(historyPath(inboxPath, entry.id), entry.row);
  const indices = new Set(removing.map((entry) => entry.index));
  return lines.filter((_line, index) => !indices.has(index));
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

async function appendInbox({ inboxPath, entry }) {
  return await withDirLock(inboxLockDir(), async () => {
    fs.mkdirSync(path.dirname(inboxPath), { recursive: true, mode: 0o700 });
    let raw;
    try { raw = fs.readFileSync(inboxPath).toString("latin1"); }
    catch (error) { if (error.code !== "ENOENT") throw error; raw = ""; }
    const rows = [];
    const valid = [];
    let malformed = 0, parsed = 0, trailingPartial = false, nonObject = false;
    const physical = raw.split("\n");
    if (physical[physical.length - 1] === "") physical.pop();
    for (const [index, bytes] of physical.entries()) {
      let row, line;
      try { line = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.from(bytes, "latin1")); }
      catch { malformed++; continue; }
      try { row = JSON.parse(line); }
      catch {
        if (index === physical.length - 1 && !raw.endsWith("\n")) trailingPartial = true;
        else malformed++;
        continue;
      }
      parsed++;
      if (!row || typeof row !== "object" || Array.isArray(row)) { nonObject = true; continue; }
      rows.push(row);
      valid.push(line);
    }
    let lines = valid;
    let quarantinedPath;
    if (malformed || trailingPartial || nonObject) {
      const base = `${inboxPath}.quarantined-${Math.floor(Date.now() / 1000)}`;
      quarantinedPath = base;
      for (let collision = 1; fs.existsSync(quarantinedPath); collision++) quarantinedPath = `${base}-${collision}`;
      fs.copyFileSync(inboxPath, quarantinedPath, fs.constants.COPYFILE_EXCL);
      writeTextAtomic(inboxPath, valid.length ? valid.join("\n") + "\n" : "");
      try { fs.appendFileSync(path.join(path.dirname(inboxPath), "bridge-inbox-quarantine.jsonl"), JSON.stringify({
        event: "builder_inbox_quarantined", quarantinedAt: nowISO(), inboxPath, quarantinedPath,
        reason: "builder inbox is malformed; original bytes preserved",
        malformedLineCount: malformed, trailingPartialLine: trailingPartial,
        physicalLineCount: physical.length, parsedRowCount: parsed,
      }) + "\n"); } catch { /* Original bytes are already preserved, as in the other bridge inboxes. */ }
    }
    const id = messageIdForPayload(entry);
    const matching = rows.filter((row) => rowMessageIds(row).includes(id));
    if (matching.length > 1) throw new Error("builder inbox message identity is ambiguous; original bytes preserved");
    let existing = matching[0];
    if (existing === undefined) {
      try { existing = JSON.parse(fs.readFileSync(historyPath(inboxPath, id), "utf8")); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    if (existing !== undefined && (!existing || typeof existing !== "object" || Array.isArray(existing)
        || (existing.id !== undefined && existing.messageId !== undefined && existing.id !== existing.messageId)
        || !rowMessageIds(existing).includes(id))) {
      throw new Error("codex inbox retry identity is unreadable; original bytes preserved");
    }
    lines = compactInbox(lines, inboxPath);
    let status = "appended", retryWake = false, queuedAt = entry.createdAt;
    if (existing !== undefined) {
      const fields = ["text", "topic", "conversationId", "workingDirectory", "executionProfile",
        "deskHandle", "completionMode", "pairReviewer", "sessionId", "origin", "brain", "priority",
        "model", "reasoningEffort", "serviceTier", "fast"];
      status = fields.every((key) => isDeepStrictEqual(existing[key], entry[key])) ? "duplicate" : "conflict";
      retryWake = existing.read === false && typeof existing.createdAt === "string" && !!existing.createdAt
        && (existing.consumedAt == null || (typeof existing.consumedAt === "string" && !existing.consumedAt.trim()));
      queuedAt = existing.createdAt || queuedAt;
    } else {
      lines = lines.filter((line) => line.trim());
      lines.push(JSON.stringify(entry));
    }
    writeTextAtomic(inboxPath, lines.filter((line) => line.trim()).join("\n") + "\n");
    return { status, retryWake, queuedAt, quarantinedPath };
  }, { waitMs: 30000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
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
        for (const [id, entry] of targets) {
          if (seen.has(id)) continue;
          const archivedPath = historyPath(inboxPath, id);
          let row;
          try { row = JSON.parse(fs.readFileSync(archivedPath, "utf8")); }
          catch (error) { if (error.code === "ENOENT") continue; throw error; }
          if (!row || typeof row !== "object" || Array.isArray(row)
              || (row.id !== undefined && row.messageId !== undefined && row.id !== row.messageId)
              || !rowMessageIds(row).includes(id)) {
            throw new Error("codex inbox retry identity conflicts; original bytes preserved");
          }
          writeJSONAtomic(archivedPath, rewriteRow(row, entry, id));
          seen.add(id);
        }
        writeTextAtomic(inboxPath, compactInbox(next, inboxPath).join("\n"));
        return {
          status: "ok",
          inboxPath,
          marked: [...seen],
          missing: [...targets.keys()].filter((id) => !seen.has(id)),
        };
      }, { waitMs: 5000, staleMs: 10 * 60 * 1000, preserveLiveOwner: true });
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
    row.deliveryStatus = terminal.reason === "restored" ? "stopped" : "dead_letter";
    row.deliveryTerminalAt = row.deliveryTerminalAt
      || terminal.deadLetteredAt
      || nowISO();
    row.deliveryFailureReason = terminal.reason || "terminal_failure";
    return row;
  }, "marked_terminal");
}

return { appendInbox, markInboxConsumed, markInboxTerminal, messageIdForPayload };
}

module.exports = { createCodexWakeInboxProjection };
