"use strict";

const crypto = require("crypto");

// Assemble wire parameters; settings, execution policy and prompts stay with their owners.
function createCodexWakeRequestParams({
  brainControlsForEntries, executionPolicyForEntries, formatBatchPrompt,
  enumStringSetting, stringSetting,
}) {
function clientUserMessageIdForEntries(entries) {
  const retryCount = Math.max(0, ...entries.map((entry) => Number(entry && entry.hangRetryCount || 0)));
  const retrySuffix = retryCount > 0 ? `-hang-retry-${retryCount}` : "";
  if (entries.length === 1) {
    const messageId = entries[0].payload.messageId || entries[0].id || crypto.randomUUID();
    return `nativeagent-codex-${messageId}${retrySuffix}`;
  }
  const key = entries
    .map((entry) => entry.payload.messageId || entry.id || "")
    .join("|");
  return `nativeagent-codex-batch-${crypto.createHash("sha256").update(key).digest("hex").slice(0, 24)}${retrySuffix}`;
}

function freshThreadStartParams(config, entries = []) {
  const brain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  const params = {
    cwd: execution.cwd,
    approvalPolicy: enumStringSetting(
      config,
      "approvalPolicy",
      "NATIVE_AGENT_CODEX_WAKEUP_APPROVAL_POLICY",
      "never",
      new Set(["untrusted", "on-failure", "on-request", "never"])
    ),
    sandbox: execution.sandbox,
    ephemeral: false,
    sessionStartSource: "startup",
    threadSource: stringSetting(
      config,
      "threadSource",
      "NATIVE_AGENT_CODEX_THREAD_SOURCE",
      "nativeagent_codex_message"
    ),
    serviceName: stringSetting(
      config,
      "serviceName",
      "NATIVE_AGENT_CODEX_SERVICE_NAME",
      "NativeAgent codex_message"
    ),
  };
  if (brain.model) params.model = brain.model;
  if (brain.serviceTier) params.serviceTier = brain.serviceTier;
  const modelProvider = stringSetting(config, "modelProvider", "NATIVE_AGENT_CODEX_WAKEUP_MODEL_PROVIDER", "");
  if (modelProvider) params.modelProvider = modelProvider;
  return params;
}

function turnStartParams(threadId, entries, config) {
  const brain = brainControlsForEntries(entries, config);
  const execution = executionPolicyForEntries(entries, config);
  const params = {
    threadId,
    clientUserMessageId: clientUserMessageIdForEntries(entries),
    input: [{ type: "text", text: formatBatchPrompt(entries), text_elements: [] }],
  };
  if (brain.model) params.model = brain.model;
  if (brain.reasoningEffort) params.effort = brain.reasoningEffort;
  if (brain.serviceTier) params.serviceTier = brain.serviceTier;
  if (execution.sandboxPolicy) {
    params.cwd = execution.cwd;
    params.sandboxPolicy = execution.sandboxPolicy;
  }
  return params;
}

  return { clientUserMessageIdForEntries, freshThreadStartParams, turnStartParams };
}

module.exports = { createCodexWakeRequestParams };
