"use strict";

// Render admitted handoffs; the worker retains checkout validation and state.
function createCodexWakePrompt({ trustedGitHubCommandWorkingDirectory }) {
function pairedReviewInstruction(payload) {
  if (!payload || payload.pairReviewer !== true) return null;
  return "PAIRED REVIEW: At the start of this implementation task, pair exactly one reviewer through Codex's normal sub-agent collaboration. You remain the builder and owner. Finish the coherent change and commit it before review, then send that reviewer the exact committed SHA to inspect. Findings return to you; fix valid findings yourself, commit the fixes, and have the same reviewer inspect the resulting SHA before you report the final candidate. Do not create reviewer waves, and do not hand implementation to the reviewer.";
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
  const reviewInstruction = pairedReviewInstruction(payload);
  if (reviewInstruction) lines.push(reviewInstruction, "");
  lines.push("Treat this as the local assistant speaking to Codex. If it needs work, handle it in this thread; if it is just status, acknowledge briefly. Always produce a final text answer, even when the task fails or no changes are needed, because NativeAgent uses that answer as the async completion receipt.");
  return lines.join("\n");
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
    const reviewInstruction = pairedReviewInstruction(payload);
    if (reviewInstruction) lines.push(reviewInstruction, "");
  }
  lines.push("Treat these as the local assistant speaking to Codex. Handle anything actionable in this thread; if they are just status, acknowledge briefly. Always produce a final text answer, even when the task fails or no changes are needed, because NativeAgent uses that answer as the async completion receipt.");
  return lines.join("\n");
}

  return { formatPrompt, formatBatchPrompt };
}

module.exports = { createCodexWakePrompt };
