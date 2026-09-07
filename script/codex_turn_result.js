"use strict";

// Project durable rollout and app-server evidence without starting or replaying work.
const fs = require("fs");
const { nowISO, redactDiagnosticText, unicodePrefix } = require("./wake_worker_common.js");

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
    message: redactDiagnosticText(unicodePrefix(text.trim(), 600)),
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
  // reported to the agent as an unknown outcome she could not safely retry.
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
  // Another app-server can hydrate a still-running shared rollout as
  // notLoaded/interrupted. That server does not own the live writer. Require
  // a durable terminal event (or an exact turn/completed event) before the
  // canonical reader settles this as aborted. Never infer permission to replay.
  if (thread?.status?.type === "notLoaded"
      && ["interrupted", "cancelled", "canceled"].includes(turn?.status)) return null;
  return extractTurnResultFromTurn(turn, turnId, rolloutPath);
}

module.exports = { extractTurnResultFromRollout, extractTurnResultFromTurn, extractTurnResultFromThread };
