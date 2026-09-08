"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function createCodexWakeExecutionPolicy({ stringSetting, enumStringSetting, GITHUB_COMMAND_EXECUTION_PROFILE }) {
function brainControlsForEntries(entries, config) {
  const firstPayload = Array.isArray(entries) && entries[0] && entries[0].payload
    ? entries[0].payload
    : {};
  const controls = {};
  const model = typeof firstPayload.model === "string" && firstPayload.model
    ? firstPayload.model
    : stringSetting(config, "model", "NATIVE_AGENT_CODEX_WAKEUP_MODEL", "");
  const reasoningEffort = typeof firstPayload.reasoningEffort === "string" && firstPayload.reasoningEffort
    ? firstPayload.reasoningEffort
    : stringSetting(config, "reasoningEffort", "NATIVE_AGENT_CODEX_WAKEUP_REASONING_EFFORT", "");
  const serviceTier = typeof firstPayload.serviceTier === "string" && firstPayload.serviceTier
    ? firstPayload.serviceTier
    : stringSetting(config, "serviceTier", "NATIVE_AGENT_CODEX_WAKEUP_SERVICE_TIER", "");
  if (model) controls.model = model;
  if (reasoningEffort) controls.reasoningEffort = reasoningEffort;
  if (serviceTier) controls.serviceTier = serviceTier;
  return controls;
}

function trustedGitHubCommandWorkingDirectory(entries) {
  if (!Array.isArray(entries) || entries.length === 0) return null;
  const directories = new Set();
  for (const entry of entries) {
    const payload = entry && entry.payload;
    // Trust anchor is the app-verified executionProfile marker: the Swift
    // dispatcher only writes it for a checkout it resolved itself, and
    // sanitizePayload only preserves the exact constant. Any origin surface
    // (github-command, chat lanes, etc.) may carry it; a payload with no
    // origin at all still fails closed.
    if (!payload
        || payload.executionProfile !== GITHUB_COMMAND_EXECUTION_PROFILE
        || !payload.origin
        || typeof payload.origin.surface !== "string"
        || payload.origin.surface.trim() === ""
        || typeof payload.workingDirectory !== "string"
        || !path.isAbsolute(payload.workingDirectory)) return null;
    let stat;
    try { stat = fs.statSync(payload.workingDirectory); } catch { return null; }
    if (!stat.isDirectory()) return null;
    try {
      directories.add(path.normalize(fs.realpathSync(payload.workingDirectory)));
    } catch {
      return null;
    }
  }
  return directories.size === 1 ? [...directories][0] : null;
}

function repositoryWritableRoots(workingDirectory) {
  const roots = new Set([path.normalize(workingDirectory)]);
  const dotGit = path.join(workingDirectory, ".git");
  try {
    if (fs.statSync(dotGit).isDirectory()) roots.add(path.normalize(dotGit));
  } catch {}

  const result = spawnSync(
    "/usr/bin/git",
    ["-C", workingDirectory, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
    { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] }
  );
  if (result.status === 0) {
    for (const line of String(result.stdout || "").split("\n")) {
      const candidate = line.trim();
      if (!candidate || !path.isAbsolute(candidate)) continue;
      try {
        if (fs.statSync(candidate).isDirectory()) roots.add(path.normalize(candidate));
      } catch {}
    }
  }
  return [...roots];
}

function executionPolicyForEntries(entries, config) {
  const workingDirectories = [...new Set(entries
    .map((entry) => entry && entry.payload && entry.payload.workingDirectory)
    .filter((value) => typeof value === "string" && path.isAbsolute(value)))];
  const configuredCwd = stringSetting(config, "cwd", "NATIVE_AGENT_CODEX_WAKEUP_CWD", process.cwd());
  const configuredSandbox = enumStringSetting(
    config,
    "sandbox",
    "NATIVE_AGENT_CODEX_WAKEUP_SANDBOX",
    "danger-full-access",
    new Set(["read-only", "workspace-write", "danger-full-access"])
  );
  const trustedGitHubCwd = trustedGitHubCommandWorkingDirectory(entries);
  if (trustedGitHubCwd) {
    const writableRoots = repositoryWritableRoots(trustedGitHubCwd);
    return {
      cwd: trustedGitHubCwd,
      sandbox: "danger-full-access",
      sandboxPolicy: {
        type: "dangerFullAccess",
      },
      executionProfile: GITHUB_COMMAND_EXECUTION_PROFILE,
      networkAccess: true,
      writableRoots,
    };
  }
  return {
    cwd: workingDirectories.length === 1 ? workingDirectories[0] : configuredCwd,
    sandbox: configuredSandbox,
    sandboxPolicy: null,
    executionProfile: null,
    networkAccess: false,
    writableRoots: [],
  };
}

  return { brainControlsForEntries, trustedGitHubCommandWorkingDirectory, executionPolicyForEntries };
}

module.exports = { createCodexWakeExecutionPolicy };

