"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const wakeup = require("../codex_thread_wakeup.js");

function entry(payload) {
  return { id: "entry-1", payload };
}

test("per-message brain controls reach thread and turn start params", () => {
  const entries = [entry({
    messageId: "message-1",
    text: "check the bridge",
    model: "gpt-5.6-terra",
    reasoningEffort: "ultra",
    serviceTier: "priority",
  })];
  const thread = wakeup.freshThreadStartParams({ cwd: "/tmp/repo" }, entries);
  const turn = wakeup.turnStartParams("thread-1", entries, {});

  assert.equal(thread.model, "gpt-5.6-terra");
  assert.equal(thread.serviceTier, "priority");
  assert.equal(turn.model, "gpt-5.6-terra");
  assert.equal(turn.effort, "ultra");
  assert.equal(turn.serviceTier, "priority");
});

test("trusted per-message working directory becomes the fresh thread workspace", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-github-command-"));
  fs.mkdirSync(path.join(dir, ".git"));
  const entries = [entry({
    messageId: "github-command-1",
    text: "handle the review",
    workingDirectory: dir,
    executionProfile: "github-command-repository-network-v1",
    origin: { surface: "github-command" },
  })];
  const clean = wakeup.sanitizePayload(entries[0].payload);
  const cleanEntries = [{
    ...entries[0], payload: clean,
  }];
  const thread = wakeup.freshThreadStartParams({ cwd: "/tmp/nativeagent" }, cleanEntries);
  const turn = wakeup.turnStartParams("thread-1", cleanEntries, {});
  const canonicalDir = fs.realpathSync(dir);

  assert.equal(clean.workingDirectory, dir);
  assert.equal(clean.executionProfile, "github-command-repository-network-v1");
  assert.equal(thread.cwd, canonicalDir);
  assert.equal(thread.sandbox, "workspace-write");
  assert.equal(turn.cwd, canonicalDir);
  assert.deepEqual(turn.sandboxPolicy, {
    type: "workspaceWrite",
    writableRoots: [canonicalDir, path.join(canonicalDir, ".git")],
    networkAccess: true,
  });
  assert.match(wakeup.formatPrompt(clean), /unattended GitHub bridge/i);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("app-verified repository profile grants network from any origin surface", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-github-chatlane-"));
  fs.mkdirSync(path.join(dir, ".git"));
  const entries = [entry({
    messageId: "chat-lane-github-1",
    text: "rebase the PR and push",
    workingDirectory: dir,
    executionProfile: "github-command-repository-network-v1",
    origin: { surface: "telegram", destinationId: "12345" },
  })];
  const clean = wakeup.sanitizePayload(entries[0].payload);
  const cleanEntries = [{ ...entries[0], payload: clean }];
  const thread = wakeup.freshThreadStartParams({ cwd: "/tmp/nativeagent" }, cleanEntries);
  const turn = wakeup.turnStartParams("thread-1", cleanEntries, {});
  const canonicalDir = fs.realpathSync(dir);

  assert.equal(clean.executionProfile, "github-command-repository-network-v1");
  assert.equal(thread.cwd, canonicalDir);
  assert.deepEqual(turn.sandboxPolicy, {
    type: "workspaceWrite",
    writableRoots: [canonicalDir, path.join(canonicalDir, ".git")],
    networkAccess: true,
  });
  assert.equal(turn.sandboxPolicy.networkAccess, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("GitHub execution privileges fail closed for spoofed or mixed bridge payloads", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-github-spoof-"));
  const base = {
    messageId: "spoofed-github-command",
    text: "title says GitHub Command",
    topic: "GitHub Command fake",
    workingDirectory: dir,
  };
  const missingProfile = wakeup.turnStartParams("thread-1", [entry({
    ...base,
    origin: { surface: "github-command" },
  })], {});
  const missingOrigin = wakeup.turnStartParams("thread-2", [entry({
    ...base,
    executionProfile: "github-command-repository-network-v1",
  })], {});
  const mixed = wakeup.turnStartParams("thread-3", [
    entry({
      ...base,
      executionProfile: "github-command-repository-network-v1",
      origin: { surface: "github-command" },
    }),
    { id: "entry-2", payload: { text: "ordinary bridge work" } },
  ], {});

  assert.equal(missingProfile.sandboxPolicy, undefined);
  assert.equal(missingOrigin.sandboxPolicy, undefined);
  assert.equal(mixed.sandboxPolicy, undefined);
  assert.doesNotMatch(wakeup.formatPrompt(base), /unattended GitHub bridge/i);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("unattended app-server requests fail closed instead of hanging the turn", () => {
  const dynamic = wakeup.unattendedServerRequestReply({
    id: 41,
    method: "item/tool/call",
    params: { tool: "mcp__codex_apps__github_reply_to_review_comment" },
  });
  assert.equal(dynamic.result.success, false);
  assert.match(dynamic.result.contentItems[0].text, /cannot execute client-owned tools/i);

  assert.deepEqual(wakeup.unattendedServerRequestReply({
    id: 42, method: "item/commandExecution/requestApproval", params: {},
  }), { result: { decision: "decline" } });
  assert.deepEqual(wakeup.unattendedServerRequestReply({
    id: 43, method: "mcpServer/elicitation/request", params: {},
  }), { result: { action: "decline", content: null, _meta: null } });
  assert.equal(wakeup.unattendedServerRequestReply({
    id: 44, method: "account/chatgptAuthTokens/refresh", params: {},
  }), null);
});

test("sanitized queued payload preserves immutable origin and brain envelope", () => {
  const clean = wakeup.sanitizePayload({
    messageId: "message-1",
    text: "do work",
    model: "gpt-5.6-sol",
    reasoningEffort: "xhigh",
    serviceTier: "default",
    fast: false,
    origin: {
      surface: "slack",
      destinationId: "C123",
      threadId: "171.42",
      ignored: { secret: true },
    },
  });

  assert.deepEqual(clean.origin, {
    surface: "slack",
    destinationId: "C123",
    threadId: "171.42",
  });
  assert.equal(clean.reasoningEffort, "xhigh");
  assert.equal(clean.fast, false);
});

test("rollout completion without assistant text is a semantic failure", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-10T00:00:00Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-1" },
    }),
    JSON.stringify({
      timestamp: "2026-07-10T00:00:01Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-1", last_agent_message: null },
    }),
  ].join("\n"));

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-1");
  assert.equal(result.status, "completed_without_reply");
  assert.equal(result.message, "");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("completion prompt makes Agent assess the result and proactively tell User", () => {
  const text = wakeup.formatCodexReplyForNativeAgent({
    threadId: "thread-continue-1",
    turnId: "turn-2",
    entries: [entry({
      messageId: "message-2",
      topic: "bridge-test",
      text: "Fix the missing completion return path.",
    })],
  }, {
    status: "completed",
    completedAt: "2026-07-10T00:00:02Z",
    message: "Implemented and tested the return path.",
  });

  assert.match(text, /decide whether it succeeded, partially succeeded, or failed/i);
  assert.match(text, /Original request:\nFix the missing completion return path\./);
  assert.match(text, /Codex result:\nImplemented and tested the return path\./);
  assert.match(text, /Conversation: codex:thread-continue-1/);
  assert.match(text, /codex_message with conversation_id/);
  assert.match(text, /Do not wait for him to ask/i);
});

test("empty completion tells Agent it was not automatically replayed", () => {
  const text = wakeup.formatCodexReplyForNativeAgent({
    turnId: "turn-empty",
    attemptCount: 1,
    entries: [entry({ text: "Do the task." })],
  }, {
    status: "completed_without_reply",
    completedAt: "2026-07-10T00:00:02Z",
    message: "",
  });

  assert.match(text, /outcome is unknown/i);
  assert.doesNotMatch(text, /likely did not run/i);
  assert.match(text, /did not automatically replay the request/i);
  assert.match(text, /retry only after an explicit decision/i);
});

test("completed-without-reply never starts another thread or exec fallback", async () => {
  let waits = 0;
  const execution = await wakeup.waitForTurnResultWithEmptyRetry({
    threadId: "thread-once",
    turnId: "turn-once",
    entries: [entry({ text: "Do the work once." })],
  }, {
    emptyReplyRetryCount: 2,
    execFallbackOnEmpty: true,
  }, {
    waitForTurnResult: async () => {
      waits += 1;
      return { status: "completed_without_reply", message: "" };
    },
  });

  assert.equal(waits, 1);
  assert.equal(execution.threadId, "thread-once");
  assert.equal(execution.turnId, "turn-once");
  assert.equal(execution.attempts.length, 1);
  assert.equal(execution.turnResult.status, "completed_without_reply");
});

test("reply wait timeouts remain pending while the rollout keeps moving", async () => {
  const results = [
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "completed", message: "done" },
  ];
  let timeouts = 0;
  let waits = 0;
  let snapshots = 0;
  let probeCalls = 0;
  const clock = 10_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution({
    threadId: "thread-pending",
    turnId: "turn-pending",
  }, {}, async () => { timeouts += 1; }, {
    now: () => clock,
    // A session file written moments ago is legitimate long work: idle time
    // stays under the threshold and the liveness probe must never fire.
    rolloutStallSnapshot: () => {
      snapshots += 1;
      return { path: "/tmp/rollout.jsonl", ino: 1, size: snapshots, mtimeMs: clock - 1000 };
    },
    waitForTurnResult: async () => {
      waits += 1;
      return results.shift();
    },
    probeTurnLiveness: async () => {
      probeCalls += 1;
      return { serverReachable: false, turnFound: false, turnClaimsInProgress: false };
    },
  });

  assert.equal(waits, 3);
  assert.equal(timeouts, 2);
  assert.equal(probeCalls, 0);
  assert.equal(execution.turnResult.status, "completed");
});

// ------------------------------------------- stalled turns (task #46, 2026-07-30)
// Re-cut 2026-08-05 onto MEASURED idle time (stallIdleMs) so a dead turn settles
// ~15 min after its last rollout byte instead of ~2h of wait windows.

test("a dead app-server stalls one idle window after the last rollout byte", async () => {
  let timeouts = 0;
  let waits = 0;
  let probeCalls = 0;
  const clock = 10_000_000;
  const job = { threadId: "thread-stall", turnId: "turn-stall" };
  const execution = await wakeup.waitForDurableTerminalExecution(
    job, { stallProbeConfirmDelayMs: 1 }, async () => { timeouts += 1; }, {
      now: () => clock,
      waitForTurnResult: async () => {
        waits += 1;
        return { status: "timeout", waitSource: "exact_timeout" };
      },
      // 16 minutes idle: past the 15-minute default.
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - 16 * 60 * 1000,
      }),
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return { serverReachable: false, turnFound: false, turnClaimsInProgress: false };
      },
    });

  // Measured idle needs no baseline window: the verdict lands on window 1.
  assert.equal(waits, 1);
  assert.equal(timeouts, 0);
  // Probe + confirmation probe -- one reading may never settle a turn.
  assert.equal(probeCalls, 2);
  assert.equal(execution.turnResult.status, "stalled");
  assert.equal(execution.turnResult.stallEvidence.serverReachable, false);
  assert.equal(execution.turnResult.stallEvidence.idleMs, 16 * 60 * 1000);
  assert.equal(execution.turnResult.stallEvidence.idleThresholdMs, 15 * 60 * 1000);
  assert.equal(
    execution.turnResult.stallEvidence.lastActivityAt,
    new Date(clock - 16 * 60 * 1000).toISOString()
  );
  // No rollout content was scanned (path is fake), so work state is unknown.
  assert.equal(execution.turnResult.noWorkObserved, null);
});

test("a rollout idle less than stallIdleMs never probes liveness", async () => {
  const results = [
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "completed", message: "done" },
  ];
  let probeCalls = 0;
  const clock = 10_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-fresh", turnId: "turn-fresh" }, {}, async () => {}, {
      now: () => clock,
      waitForTurnResult: async () => results.shift(),
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - 14 * 60 * 1000,
      }),
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return { serverReachable: false, turnFound: false, turnClaimsInProgress: false };
      },
    });
  assert.equal(probeCalls, 0);
  assert.equal(execution.turnResult.status, "completed");
});

test("stallIdleMs is a knob", async () => {
  let waits = 0;
  const clock = 10_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-knob", turnId: "turn-knob" },
    { stallIdleMs: 60 * 1000, stallProbeConfirmDelayMs: 1 },
    async () => {},
    {
      now: () => clock,
      waitForTurnResult: async () => {
        waits += 1;
        return { status: "timeout", waitSource: "exact_timeout" };
      },
      // Only 2 minutes idle: under the default, over the configured knob.
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - 2 * 60 * 1000,
      }),
      probeTurnLiveness: async () => ({
        serverReachable: true, turnFound: false, turnClaimsInProgress: false,
      }),
    });
  assert.equal(waits, 1);
  assert.equal(execution.turnResult.status, "stalled");
  assert.equal(execution.turnResult.stallEvidence.idleThresholdMs, 60 * 1000);
});

test("a transient probe failure alone never settles a turn as stalled", async () => {
  // Regression for the 2026-07-31 audit trap, now that measured idle can reach
  // a verdict in ONE window: one unreachable reading followed by a healthy
  // confirmation must keep waiting, not settle.
  const results = [
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "completed", message: "done after a blip" },
  ];
  const probeResults = [
    { serverReachable: false, turnFound: false, turnClaimsInProgress: false },
    { serverReachable: true, turnFound: true, turnClaimsInProgress: true },
  ];
  let probeCalls = 0;
  const clock = 10_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-blip", turnId: "turn-blip" },
    { stallProbeConfirmDelayMs: 1 },
    async () => {},
    {
      now: () => clock,
      waitForTurnResult: async () => results.shift(),
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - 30 * 60 * 1000,
      }),
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return probeResults.shift() || { serverReachable: true, turnFound: true, turnClaimsInProgress: true };
      },
    });
  assert.equal(probeCalls, 2);
  assert.equal(execution.turnResult.status, "completed");
});

test("an inProgress-claiming turn needs stallWedgedIdleMs, not stallIdleMs (configurable)", async () => {
  let waits = 0;
  let probeCalls = 0;
  const clock = 10_000_000;
  const results = [
    // 20 min idle: past stallIdleMs, under the 45-min wedged knob -> keep waiting.
    20 * 60 * 1000,
    // 50 min idle: past the wedged knob -> verdict.
    50 * 60 * 1000,
  ];
  let idle = 0;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-wedged", turnId: "turn-wedged" },
    { stallWedgedIdleMs: 45 * 60 * 1000 },
    async () => {},
    {
      now: () => clock,
      waitForTurnResult: async () => {
        idle = results[Math.min(waits, results.length - 1)];
        waits += 1;
        return { status: "timeout", waitSource: "exact_timeout" };
      },
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - idle,
      }),
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return { serverReachable: true, turnFound: true, turnClaimsInProgress: true };
      },
    });

  assert.equal(waits, 2);
  assert.equal(probeCalls, 2);
  assert.equal(execution.turnResult.status, "stalled");
  assert.equal(execution.turnResult.stallEvidence.turnClaimsInProgress, true);
  assert.equal(execution.turnResult.stallEvidence.idleThresholdMs, 45 * 60 * 1000);
});

test("the default wedged threshold tolerates a long silent single-tool call", async () => {
  // A multi-hour build writes zero rollout bytes while the server honestly
  // reports inProgress. Two hours of silence -- well past stallIdleMs -- must
  // NOT stall under the 4h default; the turn completes when the tool returns.
  const results = [
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "completed", message: "build done" },
  ];
  const clock = 100_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-build", turnId: "turn-build" }, {}, async () => {}, {
      now: () => clock,
      waitForTurnResult: async () => results.shift(),
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 7, size: 100, mtimeMs: clock - 2 * 60 * 60 * 1000,
      }),
      probeTurnLiveness: async () => ({ serverReachable: true, turnFound: true, turnClaimsInProgress: true }),
    });
  assert.equal(execution.turnResult.status, "completed");
});

test("an undiscoverable rollout never stalls on the first window", async () => {
  // Pin-the-subject regression (2026-07-31 audit): "can't find the rollout"
  // is not "the turn is dead". With no file there is no mtime to measure, so
  // the window-counting baseline still governs: window 1 only sets the
  // baseline even when the liveness probe reports the server unreachable;
  // window 2 (null==null stagnation) may then reach the verdict.
  let waits = 0;
  let probeCalls = 0;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-lost", turnId: "turn-lost" },
    { stallProbeConfirmDelayMs: 1 },
    async () => {},
    {
      waitForTurnResult: async () => {
        waits += 1;
        return { status: "timeout", waitSource: "exact_timeout" };
      },
      rolloutStallSnapshot: () => null,
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return { serverReachable: false, turnFound: false, turnClaimsInProgress: false };
      },
    });
  assert.equal(execution.turnResult.status, "stalled");
  assert.equal(waits, 2);
  // One judging probe plus its confirmation.
  assert.equal(probeCalls, 2);
  assert.equal(execution.turnResult.stallEvidence.stagnantWindows, 1);
  assert.equal(execution.turnResult.stallEvidence.rolloutPath, null);
  assert.equal(execution.turnResult.stallEvidence.idleMs, null);
  assert.equal(execution.turnResult.stallEvidence.lastActivityAt, null);
});

test("a flaky thread/read (reachable-but-unconfirmed) never stalls on the idle knob", async () => {
  // The probe's catch shape for a reachable server whose thread/read failed:
  // found + inProgress. Idle past stallIdleMs must keep waiting; only the
  // wedged threshold may conclude. Regression for the gpt-5.5 review BLOCKING
  // where turnFound:false here fed the dead-liveness arm.
  const flakyProbeShape = { serverReachable: true, turnFound: true, turnClaimsInProgress: true };
  const results = [
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "timeout", waitSource: "exact_timeout" },
    { status: "completed", message: "done late but done" },
  ];
  let probeCalls = 0;
  const clock = 10_000_000;
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-flaky", turnId: "turn-flaky" }, {}, async () => {}, {
      now: () => clock,
      waitForTurnResult: async () => results.shift(),
      rolloutStallSnapshot: () => ({
        path: "/tmp/rollout.jsonl", ino: 9, size: 10, mtimeMs: clock - 30 * 60 * 1000,
      }),
      probeTurnLiveness: async () => {
        probeCalls += 1;
        return flakyProbeShape;
      },
    });

  assert.equal(probeCalls, 2);
  assert.equal(execution.turnResult.status, "completed");
});

test("a stalled verdict reads observed activity from the real rollout for resend guidance", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-stall-activity-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: "turn-act" } }),
    JSON.stringify({ type: "response_item", payload: { type: "function_call", name: "shell" } }),
  ].join("\n") + "\n");
  const execution = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-act", turnId: "turn-act" }, {}, async () => {}, {
      waitForTurnResult: async () => ({ status: "timeout", waitSource: "exact_timeout" }),
      rolloutStallSnapshot: () => ({ path: rollout, ino: 1, size: 2, mtimeMs: 3 }),
      probeTurnLiveness: async () => ({ serverReachable: true, turnFound: false, turnClaimsInProgress: false }),
    });

  assert.equal(execution.turnResult.status, "stalled");
  assert.equal(execution.turnResult.noWorkObserved, false);
  assert.equal(execution.turnResult.toolActivityCount, 1);

  const noWork = path.join(dir, "rollout-nowork.jsonl");
  fs.writeFileSync(noWork, JSON.stringify(
    { type: "event_msg", payload: { type: "task_started", turn_id: "turn-idle" } }
  ) + "\n");
  const idle = await wakeup.waitForDurableTerminalExecution(
    { threadId: "thread-idle", turnId: "turn-idle" }, {}, async () => {}, {
      waitForTurnResult: async () => ({ status: "timeout", waitSource: "exact_timeout" }),
      rolloutStallSnapshot: () => ({ path: noWork, ino: 1, size: 1, mtimeMs: 1 }),
      probeTurnLiveness: async () => ({ serverReachable: false, turnFound: false, turnClaimsInProgress: false }),
    });
  assert.equal(idle.turnResult.status, "stalled");
  assert.equal(idle.turnResult.noWorkObserved, true);
});

test("a shortened judging window actually reaches the event waiter deadline", async () => {
  // The stall tests all stub waitForTurnResult, so none of them would catch
  // options.windowMs failing to thread through to the real waiter -- which
  // would silently restore the 1h judging cadence this fix exists to shorten.
  const started = Date.now();
  const result = await wakeup.waitForTurnResultEventFirst(
    "thread-nonexistent", "turn-nonexistent", {}, null, 600
  );
  const elapsed = Date.now() - started;
  assert.equal(result.status, "timeout");
  assert.equal(result.waitSource, "exact_timeout");
  // Default replyWaitTimeoutMs is 1h; anything near it means the arg was dropped.
  assert.ok(elapsed < 10_000, `window override ignored: waited ${elapsed}ms`);
});

// --------------------------- connector schema diagnostics (2026-08-05 incident)
// Verbatim payload from rollout 019fd2e5-0a92-7640-a965-8dbdf55f730b: the
// GitHub connector rejected Codex's repository_full_name after a workspace-admin
// constraint change. It arrives as an MCP *success* (result.Ok) whose text is
// the failure, so nothing upstream classified it and Codex ground away until the
// harness killed the turn. These tests fail on the pre-fix code.
const CONNECTOR_FAILURE_TEXT = "Parameters failed connector schema validation: "
  + "owner [required]: Missing required property (does not match constraints configured by your "
  + "ChatGPT workspace admin. If the issue persists, instruct the user to contact their workspace admin.); "
  + "repo_name [required]: Missing required property (does not match constraints configured by your "
  + "ChatGPT workspace admin. If the issue persists, instruct the user to contact their workspace admin.); "
  + "1 additional validation error(s)";

test("a connector schema failure in mcp_tool_call_end is classified with its properties", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-connector-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: "turn-conn" } }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: {
          server: "codex_apps",
          tool: "github.search_branches",
          arguments: { repository_full_name: "NousResearch/hermes-agent" },
        },
        result: { Ok: { content: [{ type: "text", text: CONNECTOR_FAILURE_TEXT }] } },
      },
    }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: "turn-conn", last_agent_message: "gave up" } }),
  ].join("\n") + "\n");

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-conn");
  assert.equal(result.connectorDiagnostics.diagnostic, "connector_schema_mismatch");
  assert.deepEqual(result.connectorDiagnostics.properties, ["owner", "repo_name"]);
  assert.equal(result.connectorDiagnostics.occurrences, 1);
  assert.match(result.connectorDiagnostics.detail, /failed connector schema validation/);
});

test("an exec-wrapped connector failure in a tool call output is also classified", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-connector-exec-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: "turn-exec" } }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "custom_tool_call_output",
        call_id: "call_x",
        output: [{ type: "input_text", text: CONNECTOR_FAILURE_TEXT }],
      },
    }),
  ].join("\n") + "\n");

  const scanned = wakeup.extractTurnResultFromRollout(rollout, "turn-exec", { includeNonTerminal: true });
  assert.equal(scanned.status, "in_flight");
  assert.equal(scanned.connectorDiagnostics.diagnostic, "connector_schema_mismatch");
  assert.deepEqual(scanned.connectorDiagnostics.properties, ["owner", "repo_name"]);
  // A connector reply is not a tool CALL: the resend-safety count must not move.
  assert.equal(scanned.toolActivityCount, 0);
});

test("a connector failure is found even when the turn's task_started is missing", () => {
  // Rotated/truncated rollout: no task_started for this turn, so ambient
  // attribution never arms. An explicitly turn-stamped row must still be read.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-connector-rotated-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        turn_id: "turn-rotated",
        result: { Ok: { content: [{ type: "text", text: CONNECTOR_FAILURE_TEXT }] } },
      },
    }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: "turn-rotated", last_agent_message: "" } }),
  ].join("\n") + "\n");

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-rotated");
  assert.equal(result.status, "completed_without_reply");
  assert.equal(result.connectorDiagnostics.diagnostic, "connector_schema_mismatch");
  assert.deepEqual(result.connectorDiagnostics.properties, ["owner", "repo_name"]);
});

test("a healthy rollout carries no connector diagnostic", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-connector-clean-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: "turn-ok" } }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        result: { Ok: { content: [{ type: "text", text: "Action completed." }] } },
      },
    }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: "turn-ok", last_agent_message: "done" } }),
  ].join("\n") + "\n");
  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-ok");
  assert.equal(result.status, "completed");
  assert.equal(result.connectorDiagnostics, null);
});

test("a stalled turn surfaces the connector diagnostic and last-activity time to Agent", () => {
  const text = wakeup.formatCodexReplyForNativeAgent({
    entries: [entry({ messageId: "m-conn", text: "rebase PR 64288", topic: "hermes" })],
    turnId: "turn-conn",
  }, {
    status: "stalled",
    completedAt: "2026-08-05T17:27:25.000Z",
    stallEvidence: {
      serverReachable: true,
      turnFound: false,
      turnClaimsInProgress: false,
      stagnantWindows: 0,
      idleMs: 15 * 60 * 1000,
      lastActivityAt: "2026-08-05T17:12:25.974Z",
    },
    connectorDiagnostics: {
      diagnostic: "connector_schema_mismatch",
      occurrences: 3,
      properties: ["owner", "repo_name"],
      detail: CONNECTOR_FAILURE_TEXT,
    },
  });
  assert.match(text, /Codex turn stalled\./);
  assert.match(text, /unchanged since 2026-08-05T17:12:25\.974Z/);
  assert.match(text, /15 min idle/);
  assert.match(text, /connector_schema_mismatch/);
  assert.match(text, /owner, repo_name/);
  assert.match(text, /not a Codex reasoning failure/);
});

test("extractTurnResultFromRollout stays null without the includeNonTerminal flag", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-inflight-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, JSON.stringify(
    { type: "event_msg", payload: { type: "task_started", turn_id: "turn-open" } }
  ) + "\n");
  assert.equal(wakeup.extractTurnResultFromRollout(rollout, "turn-open"), null);
  const scanned = wakeup.extractTurnResultFromRollout(rollout, "turn-open", { includeNonTerminal: true });
  assert.equal(scanned.status, "in_flight");
  assert.equal(scanned.sawTurnStart, true);
  assert.equal(scanned.toolActivityCount, 0);
});

test("the stalled bridge message names the cause and the resend safety", () => {
  const text = wakeup.formatCodexReplyForNativeAgent({
    entries: [entry({ messageId: "m-stall", text: "long refactor", topic: "repo" })],
    turnId: "turn-stall",
  }, {
    status: "stalled",
    completedAt: "2026-07-30T22:00:00Z",
    noWorkObserved: true,
    stallEvidence: { serverReachable: false, turnFound: false, turnClaimsInProgress: false, stagnantWindows: 1 },
  });
  assert.match(text, /Codex turn stalled\./);
  assert.match(text, /will not complete on its own/);
  assert.match(text, /app-server is no longer reachable/);
  assert.match(text, /never executed, so resending it cannot stomp partial work/);
  assert.match(text, /retry only after an explicit decision/);
});

test("inbox consumption waits until the reply job is durable", async () => {
  const events = [];
  const result = await wakeup.attachConsumeAndReplyDelivery({
    status: "sent",
    threadId: "thread-1",
    turnId: "turn-1",
  }, [entry({ messageId: "message-1", text: "work" })], {}, {
    startReplyWatcher: () => {
      events.push("job");
      return { status: "watcher_started" };
    },
    markInboxConsumed: async () => {
      events.push("consume");
      return { status: "consumed" };
    },
  });
  assert.deepEqual(events, ["job", "consume"]);
  assert.equal(result.consume.status, "consumed");

  let consumed = false;
  const failed = await wakeup.attachConsumeAndReplyDelivery({
    status: "sent",
    threadId: "thread-2",
    turnId: "turn-2",
  }, [entry({ messageId: "message-2", text: "work" })], {}, {
    startReplyWatcher: () => ({ status: "failed", reason: "disk_full" }),
    markInboxConsumed: async () => { consumed = true; },
  });
  assert.equal(consumed, false);
  assert.equal(failed.consume.status, "deferred");
});

test("bounded codex exec fallback preserves model, effort, and service tier", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-exec-"));
  const fake = path.join(dir, "codex");
  const argsLog = path.join(dir, "args.json");
  fs.writeFileSync(fake, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.writeFileSync(process.env.FAKE_CODEX_ARGS_LOG, JSON.stringify(args));
const outputIndex = args.indexOf("-o");
fs.writeFileSync(args[outputIndex + 1], "EXEC-FALLBACK-OK\\n");
`, { mode: 0o700 });
  const oldBin = process.env.CODEX_BIN;
  const oldLog = process.env.FAKE_CODEX_ARGS_LOG;
  process.env.CODEX_BIN = fake;
  process.env.FAKE_CODEX_ARGS_LOG = argsLog;
  try {
    const result = await wakeup.runCodexExecFallback([entry({
      text: "finish the task",
      model: "gpt-5.6-luna",
      reasoningEffort: "low",
      serviceTier: "priority",
    })], {
      cwd: dir,
      sandbox: "read-only",
      execFallbackOutputDir: dir,
      execFallbackTimeoutMs: 5000,
    });
    const args = JSON.parse(fs.readFileSync(argsLog, "utf8"));
    assert.equal(result.status, "completed");
    assert.equal(result.message, "EXEC-FALLBACK-OK");
    assert.equal(result.execution, "codex_exec_fallback");
    assert.ok(args.includes("gpt-5.6-luna"));
    assert.ok(args.includes('model_reasoning_effort="low"'));
    assert.ok(args.includes('service_tier="priority"'));
  } finally {
    if (oldBin == null) delete process.env.CODEX_BIN;
    else process.env.CODEX_BIN = oldBin;
    if (oldLog == null) delete process.env.FAKE_CODEX_ARGS_LOG;
    else process.env.FAKE_CODEX_ARGS_LOG = oldLog;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("trusted GitHub exec fallback keeps network and repository metadata writable", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-github-exec-"));
  fs.mkdirSync(path.join(dir, ".git"));
  const fake = path.join(dir, "codex");
  const argsLog = path.join(dir, "args.json");
  fs.writeFileSync(fake, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.writeFileSync(process.env.FAKE_CODEX_ARGS_LOG, JSON.stringify({ args, cwd: process.cwd() }));
const outputIndex = args.indexOf("-o");
fs.writeFileSync(args[outputIndex + 1], "GITHUB-FALLBACK-OK\\n");
`, { mode: 0o700 });
  const oldBin = process.env.CODEX_BIN;
  const oldLog = process.env.FAKE_CODEX_ARGS_LOG;
  process.env.CODEX_BIN = fake;
  process.env.FAKE_CODEX_ARGS_LOG = argsLog;
  try {
    const result = await wakeup.runCodexExecFallback([entry({
      text: "finish the GitHub task",
      workingDirectory: dir,
      executionProfile: "github-command-repository-network-v1",
      origin: { surface: "github-command" },
    })], {
      cwd: "/tmp/nativeagent-default",
      sandbox: "read-only",
      execFallbackOutputDir: dir,
      execFallbackTimeoutMs: 5000,
    });
    const invocation = JSON.parse(fs.readFileSync(argsLog, "utf8"));
    const canonicalDir = fs.realpathSync(dir);
    assert.equal(result.status, "completed");
    assert.equal(result.cwd, canonicalDir);
    assert.equal(result.sandbox, "workspace-write");
    assert.equal(result.networkAccess, true);
    assert.equal(invocation.cwd, canonicalDir);
    assert.deepEqual(invocation.args.slice(0, 5), [
      "exec", "--ephemeral", "--sandbox", "workspace-write", "-C",
    ]);
    assert.ok(invocation.args.includes("sandbox_workspace_write.network_access=true"));
    assert.ok(invocation.args.includes("--add-dir"));
    assert.ok(invocation.args.includes(path.join(canonicalDir, ".git")));
  } finally {
    if (oldBin == null) delete process.env.CODEX_BIN;
    else process.env.CODEX_BIN = oldBin;
    if (oldLog == null) delete process.env.FAKE_CODEX_ARGS_LOG;
    else process.env.FAKE_CODEX_ARGS_LOG = oldLog;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("fallback diagnostics redact bearer credentials and JWTs", () => {
  const redacted = wakeup.redactDiagnosticText(
    "Authorization: Bearer secret-value access_token=token-value eyJaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbb.cccccccccccccccc"
  );
  assert.doesNotMatch(redacted, /secret-value|token-value|eyJaaaaaaaa/);
  assert.match(redacted, /\[REDACTED\]/);
  assert.match(redacted, /\[REDACTED_JWT\]/);
});

function completedTurn(overrides = {}) {
  return {
    id: "turn-event",
    status: "completed",
    completedAt: 1783987200,
    durationMs: 37,
    items: [
      { id: "user-1", type: "userMessage", text: "start" },
      { id: "agent-1", type: "agentMessage", phase: "commentary", text: "working" },
      { id: "agent-2", type: "agentMessage", phase: "final_answer", text: "EVENT-FIRST-OK" },
    ],
    ...overrides,
  };
}

function nonterminalRollout(dir, turnId = "turn-event") {
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, `${JSON.stringify({
    timestamp: new Date().toISOString(),
    type: "event_msg",
    payload: { type: "task_started", turn_id: turnId },
  })}\n`);
  return rollout;
}

test("app-server turn projection preserves terminal semantics and final answer", () => {
  const completed = wakeup.extractTurnResultFromThread({ turns: [completedTurn()] }, "turn-event");
  assert.equal(completed.status, "completed");
  assert.equal(completed.message, "EVENT-FIRST-OK");
  assert.equal(completed.durationMs, 37);

  const empty = wakeup.extractTurnResultFromTurn(
    completedTurn({ items: [] }),
    "turn-event"
  );
  assert.equal(empty.status, "completed_without_reply");

  const aborted = wakeup.extractTurnResultFromTurn(
    completedTurn({ status: "interrupted", items: [] }),
    "turn-event"
  );
  assert.equal(aborted.status, "aborted");

  const failed = wakeup.extractTurnResultFromTurn(
    completedTurn({ status: "failed", items: [], error: { message: "nope" } }),
    "turn-event"
  );
  assert.equal(failed.status, "failed");
  assert.deepEqual(failed.error, { message: "nope" });
});

test("matching turn/completed wakes one canonical reread without polling", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-event-"));
  const rollout = nonterminalRollout(dir);
  let listener = null;
  let reads = 0;
  let terminal = false;
  const client = {
    onNotification(callback) {
      listener = callback;
      return () => { if (listener === callback) listener = null; };
    },
    request: async (method, params) => {
      assert.equal(method, "thread/read");
      assert.deepEqual(params, { threadId: "thread-event", includeTurns: true });
      reads += 1;
      return {
        thread: {
          turns: [terminal
            ? completedTurn()
            : completedTurn({ status: "inProgress", completedAt: null, durationMs: null, items: [] })],
        },
      };
    },
  };

  try {
    const waiting = wakeup.waitForTurnResultEventFirst(
      "thread-event",
      "turn-event",
      { rolloutPath: rollout, replyWaitTimeoutMs: 1000 },
      client
    );
    await new Promise((resolve) => setImmediate(resolve));
    terminal = true;
    listener({
      method: "turn/completed",
      params: { threadId: "thread-event", turn: completedTurn() },
    });
    // A duplicate notification cannot schedule a second delivery/read.
    if (listener) listener({
      method: "turn/completed",
      params: { threadId: "thread-event", turn: completedTurn() },
    });
    const result = await waiting;
    assert.equal(result.status, "completed");
    assert.equal(result.message, "EVENT-FIRST-OK");
    assert.equal(result.waitSource, "turn_completed_notification");
    assert.equal(reads, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("rollout vnode event repairs a missed app-server notification", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-file-event-"));
  const rollout = nonterminalRollout(dir, "turn-file");
  try {
    const waiting = wakeup.waitForTurnResultEventFirst(
      "thread-file",
      "turn-file",
      { rolloutPath: rollout, replyWaitTimeoutMs: 1000 }
    );
    setTimeout(() => {
      fs.appendFileSync(rollout, `${JSON.stringify({
        timestamp: "2026-07-14T00:00:01Z",
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: "turn-file",
          duration_ms: 41,
          last_agent_message: "FILE-EVENT-OK",
        },
      })}\n`);
    }, 20);
    const result = await waiting;
    assert.equal(result.status, "completed");
    assert.equal(result.message, "FILE-EVENT-OK");
    assert.equal(result.waitSource, "rollout_file_event");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("terminal state present before event registration is read exactly once", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-race-"));
  const rollout = nonterminalRollout(dir, "turn-race");
  fs.appendFileSync(rollout, `${JSON.stringify({
    timestamp: "2026-07-14T00:00:01Z",
    type: "event_msg",
    payload: {
      type: "task_complete",
      turn_id: "turn-race",
      last_agent_message: "ALREADY-DONE",
    },
  })}\n`);
  try {
    const result = await wakeup.waitForTurnResultEventFirst(
      "thread-race",
      "turn-race",
      { rolloutPath: rollout, replyWaitTimeoutMs: 1000 }
    );
    assert.equal(result.status, "completed");
    assert.equal(result.message, "ALREADY-DONE");
    assert.equal(result.waitSource, "initial_canonical_read");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("event-first wait has one exact timeout and no periodic rereads", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-timeout-"));
  const rollout = nonterminalRollout(dir, "turn-timeout");
  let reads = 0;
  const client = {
    onNotification() { return () => {}; },
    request: async () => {
      reads += 1;
      return { thread: { turns: [] } };
    },
  };
  try {
    const result = await wakeup.waitForTurnResultEventFirst(
      "thread-timeout",
      "turn-timeout",
      { rolloutPath: rollout, replyWaitTimeoutMs: 35 },
      client
    );
    assert.equal(result.status, "timeout");
    assert.equal(result.waitSource, "exact_timeout");
    assert.equal(reads, 1);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function fingerprint(value) {
  return crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

test("pending drain sleeps on the busy rollout and wakes from its vnode", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-drain-rollout-"));
  const pendingPath = path.join(dir, "pending.json");
  const queue = [{ id: "entry-1", threadId: "thread-drain", payload: { text: "next" } }];
  fs.writeFileSync(pendingPath, JSON.stringify(queue));
  const rollout = nonterminalRollout(dir, "turn-drain");
  const state = {
    threadId: "thread-drain",
    active: true,
    inProgressTurnIds: ["turn-drain"],
    rolloutPath: rollout,
  };
  try {
    const waiting = wakeup.waitForPendingDrainInvalidation(
      [state],
      fingerprint(queue),
      { pendingPath, rolloutPath: rollout },
      Date.now() + 1000,
      0,
      null
    );
    setTimeout(() => {
      fs.appendFileSync(rollout, `${JSON.stringify({
        timestamp: "2026-07-14T00:00:01Z",
        type: "event_msg",
        payload: { type: "task_complete", turn_id: "turn-drain" },
      })}\n`);
    }, 20);
    const result = await waiting;
    assert.equal(result.source, "rollout_file_event");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("pending drain wakes when an atomic queue replacement adds work", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-drain-queue-"));
  const pendingPath = path.join(dir, "pending.json");
  const queue = [{ id: "entry-1" }];
  fs.writeFileSync(pendingPath, JSON.stringify(queue));
  try {
    const waiting = wakeup.waitForPendingDrainInvalidation(
      [],
      fingerprint(queue),
      { pendingPath },
      Date.now() + 1000,
      0,
      null
    );
    setTimeout(() => {
      const replacement = `${pendingPath}.tmp`;
      fs.writeFileSync(replacement, JSON.stringify([...queue, { id: "entry-2" }]));
      fs.renameSync(replacement, pendingPath);
    }, 20);
    const result = await waiting;
    assert.ok(["pending_queue_event", "initial_queue_change"].includes(result.source));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("pending drain uses a failure-specific deadline instead of a state poll", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-drain-retry-"));
  const pendingPath = path.join(dir, "pending.json");
  const queue = [{ id: "entry-1" }];
  fs.writeFileSync(pendingPath, JSON.stringify(queue));
  try {
    const result = await wakeup.waitForPendingDrainInvalidation(
      [],
      fingerprint(queue),
      { pendingPath },
      Date.now() + 1000,
      25,
      null
    );
    assert.equal(result.source, "failure_retry_deadline");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("bridge completion payload carries the stable reply-job delivery id", async () => {
  const previous = process.env.NATIVE_AGENT_CODEX_REPLY_DRY_RUN;
  process.env.NATIVE_AGENT_CODEX_REPLY_DRY_RUN = "1";
  try {
    const result = await wakeup.postBridgeMessage("finished", "session-1", {}, {
      deliveryId: "delivery-stable-1",
      origin: { surface: "slack", destinationId: "C123" },
      completion: { threadId: "thread-1", turnId: "turn-1" },
    });
    assert.equal(result.status, "dry_run");
    assert.equal(result.deliveryId, "delivery-stable-1");
  } finally {
    if (previous == null) delete process.env.NATIVE_AGENT_CODEX_REPLY_DRY_RUN;
    else process.env.NATIVE_AGENT_CODEX_REPLY_DRY_RUN = previous;
  }
});

test("Codex reply delivery follows NativeAgent's published fallback port", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-return-descriptor-"));
  const descriptorPath = path.join(dir, "bridge.json");
  try {
    fs.writeFileSync(descriptorPath, JSON.stringify({
      url: "http://127.0.0.1:49321",
      host: "127.0.0.1",
      port: 49321,
    }));
    assert.deepEqual(
      wakeup.codexReturnBridgeEndpoint({ bridgeDescriptorPath: descriptorPath }),
      { host: "127.0.0.1", port: 49321, source: "descriptor", descriptorPath }
    );
    assert.deepEqual(
      wakeup.codexReturnBridgeEndpoint({
        bridgeDescriptorPath: descriptorPath,
        bridgeHost: "localhost",
        bridgePort: 49999,
      }),
      { host: "localhost", port: 49999, source: "explicit" }
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("reply delivery identity is deterministic for a Codex thread and turn", () => {
  const first = wakeup.stableUUID("codex-reply:thread-1:turn-1");
  const duplicate = wakeup.stableUUID("codex-reply:thread-1:turn-1");
  const different = wakeup.stableUUID("codex-reply:thread-1:turn-2");
  assert.equal(first, duplicate);
  assert.notEqual(first, different);
  assert.match(first, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("reply admission is durable before turn/start and binds before watcher spawn", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-admission-"));
  const jobsDir = path.join(dir, "reply-jobs");
  const entries = [entry({ messageId: "message-admit", text: "do it" })];
  const events = [];
  const client = {
    request: async (method) => {
      assert.equal(method, "turn/start");
      const files = fs.readdirSync(jobsDir).filter((name) => name.endsWith(".json"));
      assert.equal(files.length, 1);
      const reserved = JSON.parse(fs.readFileSync(path.join(jobsDir, files[0]), "utf8"));
      assert.equal(reserved.phase, "turn_start_reserved");
      assert.equal(reserved.turnId, null);
      events.push("turn");
      return { turn: { id: "turn-admitted" } };
    },
  };
  try {
    const result = await wakeup.startTurnWithDurableReplyAdmission(
      client, "thread-admitted", entries, { deliverReplies: true }, [], {
        jobsDir,
        spawnJob: async (jobPath) => {
          const bound = JSON.parse(fs.readFileSync(jobPath, "utf8"));
          assert.equal(bound.phase, "watching_turn");
          assert.equal(bound.turnId, "turn-admitted");
          events.push("watcher");
          return { pid: 123 };
        },
      }
    );
    assert.equal(result.status, "sent");
    assert.equal(result.turn.id, "turn-admitted");
    assert.deepEqual(events, ["turn", "watcher"]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("lost turn/start response recovers the exact new turn without replay", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-admission-recovery-"));
  const jobsDir = path.join(dir, "reply-jobs");
  const entries = [entry({ messageId: "message-recover-admission", text: "do it once" })];
  let firstStarts = 0;
  try {
    await assert.rejects(() => wakeup.startTurnWithDurableReplyAdmission(
      {
        request: async (method) => {
          assert.equal(method, "turn/start");
          firstStarts += 1;
          throw new Error("response_lost_after_acceptance");
        },
      },
      "thread-recover-admission",
      entries,
      { deliverReplies: true },
      [],
      { jobsDir, spawnJob: async () => ({ pid: null }) }
    ));
    assert.equal(firstStarts, 1);

    let replayStarts = 0;
    const recovered = await wakeup.startTurnWithDurableReplyAdmission(
      {
        request: async (method) => {
          if (method === "thread/read") {
            return { thread: { turns: [{ id: "turn-already-accepted", status: "inProgress" }] } };
          }
          replayStarts += 1;
          throw new Error("must_not_start_again");
        },
      },
      "thread-recover-admission",
      entries,
      { deliverReplies: true },
      [],
      { jobsDir, spawnJob: async () => ({ pid: null }) }
    );
    assert.equal(recovered.status, "sent");
    assert.equal(recovered.turn.id, "turn-already-accepted");
    assert.equal(replayStarts, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("reply job delivery lock admits exactly one concurrent worker", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-reply-lock-"));
  const jobPath = path.join(dir, "job.json");
  let calls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const deliver = async () => {
    calls += 1;
    await gate;
    return { status: "delivered" };
  };
  try {
    const first = wakeup.deliverReplyJob(jobPath, {}, { deliver });
    await new Promise((resolve) => setImmediate(resolve));
    const duplicate = await wakeup.deliverReplyJob(jobPath, {}, { deliver });
    assert.equal(duplicate.status, "already_running");
    assert.equal(calls, 1);
    release();
    assert.deepEqual(await first, { status: "delivered" });
  } finally {
    release();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("an old reply-job lock is never stolen from a live owner", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-live-old-lock-"));
  const jobPath = path.join(dir, "job.json");
  const lockDir = `${jobPath}.delivery.lock`;
  fs.mkdirSync(lockDir);
  fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\n${new Date(0).toISOString()}\n`);
  fs.utimesSync(lockDir, new Date(0), new Date(0));
  let calls = 0;
  try {
    const duplicate = await wakeup.deliverReplyJob(jobPath, {}, {
      deliver: async () => { calls += 1; return { status: "delivered" }; },
    });
    assert.equal(duplicate.status, "already_running");
    assert.equal(calls, 0);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("reply-job lock recovers when a live PID was reused", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-reused-pid-lock-"));
  const jobPath = path.join(dir, "job.json");
  const lockDir = `${jobPath}.delivery.lock`;
  fs.mkdirSync(lockDir);
  fs.writeFileSync(
    path.join(lockDir, "pid"),
    `${process.pid}\n${new Date(0).toISOString()}\n${"0".repeat(64)}\n`
  );
  let calls = 0;
  try {
    const result = await wakeup.deliverReplyJob(jobPath, {}, {
      deliver: async () => { calls += 1; return { status: "delivered" }; },
    });
    assert.equal(result.status, "delivered");
    assert.equal(calls, 1);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("cached terminal bridge outcomes are not relaunched forever", () => {
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "outcome_unknown" }), true);
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "conflict" }), true);
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "no_reply" }), true);
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "delivery_rejected" }), true);
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "delivery_in_progress" }), false);
  assert.equal(wakeup.isTerminalBridgeReply({ replyStatus: "delivery_failed_pre_dispatch" }), false);
});

test("corrupt reply job is quarantined once instead of relaunched forever", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-corrupt-job-"));
  const jobPath = path.join(dir, "bad.json");
  fs.writeFileSync(jobPath, "{not-json");
  try {
    const result = wakeup.quarantineReplyJob(jobPath, new Error("bad json"));
    assert.equal(result.status, "quarantined");
    assert.equal(fs.existsSync(jobPath), false);
    assert.equal(fs.existsSync(result.quarantinePath), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("orphan recovery runs at most two durable jobs concurrently", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-recovery-pool-"));
  const jobsDir = path.join(dir, "reply-jobs");
  const recoveryLockDir = path.join(dir, ".recovery.lock");
  fs.mkdirSync(jobsDir);
  for (let index = 0; index < 5; index += 1) {
    fs.writeFileSync(path.join(jobsDir, `${index}.json`), "{}");
  }
  let active = 0;
  let maximumActive = 0;
  try {
    const result = await wakeup.recoverReplyJobs({}, {
      jobsDir,
      recoveryLockDir,
      worker: async (jobPath) => {
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        await new Promise((resolve) => setTimeout(resolve, 10));
        active -= 1;
        return { status: "delivered", jobPath };
      },
    });
    assert.equal(result.scanned, 5);
    assert.equal(result.started, 5);
    assert.equal(maximumActive, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("orphan recovery scans durable jobs once under one recovery lock", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-reply-recovery-"));
  const jobsDir = path.join(dir, "reply-jobs");
  const recoveryLockDir = path.join(dir, ".recovery.lock");
  fs.mkdirSync(jobsDir);
  fs.writeFileSync(path.join(jobsDir, "b.json"), "{}");
  fs.writeFileSync(path.join(jobsDir, "a.json"), "{}");
  fs.writeFileSync(path.join(jobsDir, "ignore.txt"), "{}");
  const started = [];
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const spawnJob = async (jobPath) => {
    started.push(path.basename(jobPath));
    if (started.length === 1) await gate;
    return { status: "watcher_started", jobPath };
  };
  try {
    const first = wakeup.recoverReplyJobs({}, { jobsDir, recoveryLockDir, spawnJob });
    await new Promise((resolve) => setImmediate(resolve));
    const duplicate = await wakeup.recoverReplyJobs({}, { jobsDir, recoveryLockDir, spawnJob });
    assert.equal(duplicate.status, "already_running");
    release();
    const result = await first;
    assert.equal(result.status, "completed");
    assert.equal(result.scanned, 2);
    assert.equal(result.started, 2);
    assert.deepEqual(started, ["a.json", "b.json"]);
  } finally {
    release();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// Version-drift self-heal (2026-07-16): a daemon started before a codex
// upgrade serves the old binary and every fresh-thread wakeup completes with
// zero model output. The mismatch decision must fire ONLY on two concrete,
// differing version strings — anything uncertain must not trigger a restart.
test("daemon version mismatch fires only on two concrete differing versions", () => {
  assert.equal(wakeup.daemonVersionsMismatch({ cliVersion: "0.144.4", appServerVersion: "0.142.5" }), true);
  assert.equal(wakeup.daemonVersionsMismatch({ cliVersion: "0.144.4", appServerVersion: "0.144.4" }), false);
  assert.equal(wakeup.daemonVersionsMismatch({ cliVersion: "0.144.4" }), false);
  assert.equal(wakeup.daemonVersionsMismatch({ appServerVersion: "0.142.5" }), false);
  assert.equal(wakeup.daemonVersionsMismatch({ cliVersion: "", appServerVersion: "0.142.5" }), false);
  assert.equal(wakeup.daemonVersionsMismatch({ cliVersion: "0.144.4", appServerVersion: "" }), false);
  assert.equal(wakeup.daemonVersionsMismatch(null), false);
  assert.equal(wakeup.daemonVersionsMismatch(undefined), false);
  assert.equal(wakeup.daemonVersionsMismatch({}), false);
});

test("daemon cwd identity detects a workspace pathname recreated under a live daemon", () => {
  const observed = wakeup.parseLsofWorkingDirectory([
    "p9044",
    "fcwd",
    "i695875",
    "n/Users/example/Library/Application Support/NativeAgent/workspace",
    "",
  ].join("\n"));
  assert.deepEqual(observed, {
    pid: 9044,
    inode: "695875",
    cwd: "/Users/example/Library/Application Support/NativeAgent/workspace",
  });
  assert.equal(wakeup.daemonWorkingDirectoryMismatch(observed, { inode: 701433 }), true);
  assert.equal(wakeup.daemonWorkingDirectoryMismatch(observed, { inode: 695875 }), false);
  assert.equal(wakeup.daemonWorkingDirectoryMismatch({ cwd: observed.cwd }, { inode: 701433 }), false);
  assert.equal(wakeup.daemonWorkingDirectoryMismatch(null, { inode: 701433 }), false);
});

// Heal-lock liveness (2026-07-17, audit G2): a healer killed mid-heal leaves
// an orphaned lock dir behind (SIGKILL/reboot skips the reaping finally). The
// foreground gate must read a dead-owner lock as NOT in flight, or self-heal
// is permanently disabled after one dead healer.
test("dir-lock owner liveness distinguishes live, dead, reused-pid, and missing owners", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "heal-lock-"));
  const lockDir = path.join(dir, ".daemon-heal.lock");
  try {
    // No lock dir / no pid file → dead.
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), false);
    fs.mkdirSync(lockDir);
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), false);

    // Live owner with matching start identity → alive.
    const identity = wakeup.processStartIdentity(process.pid);
    fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\nnow\n${identity}\n`);
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), true);

    // Live PID whose start identity differs → the PID was reused; dead.
    fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\nnow\nnot-the-real-identity\n`);
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), false);

    // Dead owner: a child that has already exited. A recorded identity that
    // can never match pins the reused-PID guard deterministically (review
    // dcf9cf804931 finding 3 — a bare dead pid could flake on reuse).
    const child = require("node:child_process").spawnSync("/usr/bin/true");
    fs.writeFileSync(path.join(lockDir, "pid"), `${child.pid}\nnow\ndead-owner-identity\n`);
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), false);

    // Garbage pid file → dead.
    fs.writeFileSync(path.join(lockDir, "pid"), "not-a-pid\n");
    assert.equal(wakeup.dirLockOwnerAlive(lockDir), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("preserveLiveOwner lock steals an orphaned (dead-owner) lock immediately", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "heal-steal-"));
  const lockDir = path.join(dir, ".daemon-heal.lock");
  try {
    // Orphan: lock dir whose recorded owner is a long-dead process.
    const child = require("node:child_process").spawnSync("/usr/bin/true");
    fs.mkdirSync(lockDir);
    fs.writeFileSync(path.join(lockDir, "pid"), `${child.pid}\nnow\ndead-owner-identity\n`);

    let ran = false;
    await wakeup.withDirLock(lockDir, async () => { ran = true; }, { waitMs: 0, preserveLiveOwner: true });
    assert.equal(ran, true);
    // Lock reaped after the run.
    assert.equal(fs.existsSync(lockDir), false);

    // A just-created lock with NO pid file yet is a live contender mid-
    // acquire, not an orphan — it must NOT be stolen (acquire grace).
    fs.mkdirSync(lockDir);
    await assert.rejects(
      wakeup.withDirLock(lockDir, async () => {}, { waitMs: 0, preserveLiveOwner: true }),
      (error) => error && error.message === "lock_busy"
    );
    assert.equal(fs.existsSync(lockDir), true);
    fs.rmSync(lockDir, { recursive: true, force: true });

    // A LIVE owner is never stolen: re-create the lock as ourselves and
    // expect lock_busy under waitMs 0.
    const identity = wakeup.processStartIdentity(process.pid);
    fs.mkdirSync(lockDir);
    fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\nnow\n${identity}\n`);
    await assert.rejects(
      wakeup.withDirLock(lockDir, async () => {}, { waitMs: 0, preserveLiveOwner: true }),
      (error) => error && error.message === "lock_busy"
    );
    assert.equal(fs.existsSync(lockDir), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("rollout task_complete carrying a provider error is failed, not a silent completion", () => {
  // Real shape from turn 019f988e (2026-07-25): OpenAI backend 503 written as
  // task_complete with an error object — previously folded into
  // completed_without_reply, telling Agent the outcome was unknown.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-503" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-503",
        last_agent_message: null,
        error: {
          message: "unexpected status 503 Service Unavailable: Service Unavailable, url: https://chatgpt.com/backend-api/codex/responses",
          codex_error_info: "other",
        },
        duration_ms: 47941,
      },
    }),
  ].join("\n"));

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-503");
  assert.equal(result.status, "failed");
  assert.match(result.errorMessage, /503 Service Unavailable/);
  assert.equal(result.codexErrorInfo, "other");
  assert.equal(result.toolActivityCount, 0);
  assert.equal(result.noWorkObserved, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("rollout failure after tool activity is not marked safe to resend", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-partial" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:10Z",
      type: "response_item",
      payload: { type: "function_call", name: "shell", arguments: "{\"command\":[\"git\",\"rebase\"]}" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-partial",
        last_agent_message: null,
        error: { message: "We're currently experiencing high demand, which may cause temporary errors.", codex_error_info: "internal_server_error" },
      },
    }),
  ].join("\n"));

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-partial");
  assert.equal(result.status, "failed");
  assert.equal(result.toolActivityCount, 1);
  assert.equal(result.noWorkObserved, false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("failed wakeup notification names the provider error and resend safety", () => {
  const safe = wakeup.formatCodexReplyForNativeAgent({
    turnId: "turn-503",
    entries: [entry({ text: "Rebase PR #63375." })],
  }, {
    status: "failed",
    completedAt: "2026-07-25T09:15:50Z",
    message: "",
    errorMessage: "unexpected status 503 Service Unavailable",
    noWorkObserved: true,
  });
  assert.match(safe, /Codex wakeup failed\./);
  assert.match(safe, /Failure detail: unexpected status 503 Service Unavailable/);
  assert.match(safe, /never executed/);
  assert.match(safe, /cannot stomp partial work/);

  const partial = wakeup.formatCodexReplyForNativeAgent({
    turnId: "turn-partial",
    entries: [entry({ text: "Rebase PR #63375." })],
  }, {
    status: "failed",
    completedAt: "2026-07-25T09:15:50Z",
    message: "",
    errorMessage: "high demand",
    noWorkObserved: false,
  });
  assert.match(partial, /partial work may exist/);
  assert.match(partial, /Verify external state before resending/);
});

test("canonical read lets the rollout's failed verdict override an ambiguous app-server completion", async () => {
  // The app-server marks provider-failed turns "completed" with no items;
  // thread/read alone would report completed_without_reply. The rollout knows
  // the truth and must win.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-503" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: "turn-503",
        last_agent_message: null,
        error: { message: "unexpected status 503 Service Unavailable", codex_error_info: "other" },
      },
    }),
  ].join("\n"));
  const client = {
    request: async (method) => {
      assert.equal(method, "thread/read");
      return { thread: { turns: [{ id: "turn-503", status: "completed", items: [] }] } };
    },
  };

  const result = await wakeup.readCanonicalTurnResult(client, "thread-1", "turn-503", { rolloutPath: rollout });
  assert.equal(result.status, "failed");
  assert.match(result.errorMessage, /503/);
  assert.equal(result.noWorkObserved, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("errored completion without task_started reports unknown work state, not safe-to-resend", () => {
  // Rotated/truncated rollout: terminal row present, no task_started. Absence
  // of observed activity proves nothing — noWorkObserved must be null.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, JSON.stringify({
    timestamp: "2026-07-25T09:15:50Z",
    type: "event_msg",
    payload: {
      type: "task_complete",
      turn_id: "turn-headless",
      last_agent_message: null,
      error: { message: "unexpected status 503 Service Unavailable", codex_error_info: "other" },
    },
  }) + "\n");

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-headless");
  assert.equal(result.status, "failed");
  assert.equal(result.noWorkObserved, null);

  const text = wakeup.formatCodexReplyForNativeAgent({
    turnId: "turn-headless",
    entries: [entry({ text: "Do the task." })],
  }, result);
  assert.match(text, /does not show whether any work executed/);
  assert.match(text, /verify external state before resending/i);
  assert.doesNotMatch(text, /never executed/);
  assert.doesNotMatch(text, /Tool activity was recorded/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("string-shaped task_complete error still classifies as failed", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-str" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-str", last_agent_message: null, error: "unexpected status 503" },
    }),
  ].join("\n"));

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-str");
  assert.equal(result.status, "failed");
  assert.match(result.errorMessage, /503/);
  assert.equal(result.noWorkObserved, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("turn_aborted after an errored task_complete wins as the terminal state", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-ab" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-ab", last_agent_message: null, error: { message: "boom" } },
    }),
    // Deliberately NO second task_started: the abort must win through the
    // unattributed fallback, not by re-arming the attributed branch.
    JSON.stringify({
      timestamp: "2026-07-25T09:15:51Z",
      type: "event_msg",
      payload: { type: "turn_aborted", turn_id: "turn-ab" },
    }),
  ].join("\n"));

  const result = wakeup.extractTurnResultFromRollout(rollout, "turn-ab");
  assert.equal(result.status, "aborted");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("unattributed task_complete for another turn does not drop attribution of the tracked turn", () => {
  // A task_complete for turn A arriving while tracking turn B must not null
  // the tracker: B's later activity still counts.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout.jsonl");
  fs.writeFileSync(rollout, [
    JSON.stringify({
      timestamp: "2026-07-25T09:15:02Z",
      type: "event_msg",
      payload: { type: "task_started", turn_id: "turn-B" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:03Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-A", last_agent_message: "done earlier" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:10Z",
      type: "response_item",
      payload: { type: "custom_tool_call", name: "shell" },
    }),
    JSON.stringify({
      timestamp: "2026-07-25T09:15:50Z",
      type: "event_msg",
      payload: { type: "task_complete", turn_id: "turn-B", last_agent_message: null, error: { message: "boom" } },
    }),
  ].join("\n"));

  const forB = wakeup.extractTurnResultFromRollout(rollout, "turn-B");
  assert.equal(forB.status, "failed");
  assert.equal(forB.toolActivityCount, 1);
  assert.equal(forB.noWorkObserved, false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("canonical read re-finds a late-appearing rollout before accepting ambiguous completion", async () => {
  // The session file can become discoverable AFTER thread/read returns an
  // ambiguous completed-without-reply. The bounded 400ms retry must re-find
  // the path, not only re-read an already-known one.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-rollout-"));
  const rollout = path.join(dir, "rollout-late.jsonl");
  const client = {
    request: async () => ({ thread: { turns: [{ id: "turn-late", status: "completed", items: [] }] } }),
  };
  setTimeout(() => {
    fs.writeFileSync(rollout, [
      JSON.stringify({
        timestamp: "2026-07-25T09:15:02Z",
        type: "event_msg",
        payload: { type: "task_started", turn_id: "turn-late" },
      }),
      JSON.stringify({
        timestamp: "2026-07-25T09:15:50Z",
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: "turn-late",
          last_agent_message: null,
          error: { message: "unexpected status 503 Service Unavailable", codex_error_info: "other" },
        },
      }),
    ].join("\n"));
  }, 100);

  const result = await wakeup.readCanonicalTurnResult(client, "thread-late", "turn-late", { rolloutPath: rollout });
  assert.equal(result.status, "failed");
  assert.match(result.errorMessage, /503/);
  fs.rmSync(dir, { recursive: true, force: true });
});

// --- BRIDGES-4 / 409 delivery retry -----------------------------------------

test("transport failures are retryable; lifecycle-terminal 409s are not", () => {
  // Retryable: the request never reached a handler that claimed the delivery.
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "connect ECONNREFUSED 127.0.0.1:8771",
  }), true);
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "socket hang up",
  }), true);
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "http_503", httpStatus: 503,
  }), true);
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "http_429", httpStatus: 429,
  }), true);

  // NOT retryable: 409 outcome_unknown is terminal in CodexCompletionLifecycle
  // (claim() returns .outcomeUnknown forever once the state file reaches it),
  // so a resend can only burn attempts.
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "http_409", httpStatus: 409, replyStatus: "outcome_unknown",
  }), false);
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "http_409", httpStatus: 409, replyStatus: "conflict",
  }), false);
  // NOT retryable: the app owns the turn under its own 600s work deadline.
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "http_504", httpStatus: 504,
  }), false);
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "bridge_message_timeout",
  }), false);
  // NOT retryable: config faults, not transient ones.
  assert.equal(wakeup.bridgeDeliveryRetryable({
    status: "failed", reason: "bridge_token_missing",
  }), false);
  // Success is never retried.
  assert.equal(wakeup.bridgeDeliveryRetryable({ status: "delivered" }), false);
});

test("delivery backoff is bounded, jittered, and capped", () => {
  // Full jitter: delay ∈ [0, min(cap, base * 2^n)).
  assert.equal(wakeup.bridgeDeliveryBackoffMs(0, { baseMs: 500, capMs: 8000, random: () => 0 }), 0);
  assert.equal(
    wakeup.bridgeDeliveryBackoffMs(0, { baseMs: 500, capMs: 8000, random: () => 0.999 }),
    Math.floor(0.999 * 500)
  );
  assert.equal(
    wakeup.bridgeDeliveryBackoffMs(2, { baseMs: 500, capMs: 8000, random: () => 0.5 }),
    1000
  );
  // Cap holds no matter how many attempts.
  for (const attempt of [5, 10, 40]) {
    assert.ok(
      wakeup.bridgeDeliveryBackoffMs(attempt, { baseMs: 500, capMs: 8000, random: () => 0.999 }) < 8000
    );
  }
  // Jitter actually varies the delay.
  const values = new Set();
  for (let i = 0; i < 50; i += 1) values.add(wakeup.bridgeDeliveryBackoffMs(3, { baseMs: 500 }));
  assert.ok(values.size > 1);
});

test("delivery POST retries a refused connection and succeeds on attempt 2", async () => {
  const seen = [];
  const slept = [];
  const bridge = await wakeup.postBridgeMessageWithRetry(
    async (attempt) => {
      seen.push(attempt);
      return attempt === 1
        ? { status: "failed", reason: "connect ECONNREFUSED 127.0.0.1:8771" }
        : { status: "delivered", replyStatus: "ok" };
    },
    { maxAttempts: 4, baseMs: 500, sleep: async (ms) => { slept.push(ms); } }
  );
  assert.deepEqual(seen, [1, 2]);
  assert.equal(bridge.status, "delivered");
  assert.equal(bridge.deliveryAttempts, 2);
  assert.equal(bridge.retriesExhausted, false);
  assert.equal(slept.length, 1);
  assert.ok(slept[0] >= 0 && slept[0] < 500);
});

test("delivery POST exhausts its bounded attempts and terminates cleanly", async () => {
  const seen = [];
  const slept = [];
  const bridge = await wakeup.postBridgeMessageWithRetry(
    async (attempt) => {
      seen.push(attempt);
      return { status: "failed", reason: "connect ECONNREFUSED 127.0.0.1:8771" };
    },
    { maxAttempts: 4, baseMs: 500, sleep: async (ms) => { slept.push(ms); } }
  );
  // Bounded: exactly maxAttempts posts, exactly maxAttempts-1 sleeps. No loop.
  assert.deepEqual(seen, [1, 2, 3, 4]);
  assert.equal(slept.length, 3);
  assert.equal(bridge.status, "failed");
  assert.equal(bridge.retriesExhausted, true);
  assert.equal(bridge.retriedFailures.length, 4);
});

test("a 409 outcome_unknown is posted exactly once — never resent", async () => {
  const seen = [];
  const bridge = await wakeup.postBridgeMessageWithRetry(
    async (attempt) => {
      seen.push(attempt);
      return {
        status: "failed", reason: "http_409", httpStatus: 409, replyStatus: "outcome_unknown",
      };
    },
    { maxAttempts: 4, baseMs: 1, sleep: async () => {} }
  );
  assert.deepEqual(seen, [1]);
  assert.equal(bridge.replyStatus, "outcome_unknown");
  assert.equal(bridge.retriedFailures, undefined);
});

test("job file disposition: unlink on delivery, retain on transport failure", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-job-disposition-"));
  try {
    const delivered = path.join(dir, "delivered.json");
    fs.writeFileSync(delivered, JSON.stringify({ id: "a" }));
    assert.equal(wakeup.finalizeReplyJobFile(delivered, { status: "delivered", replyStatus: "ok" }).disposition, "unlink");
    assert.equal(fs.existsSync(delivered), false);

    // BRIDGES-4: an exhausted transport failure must LEAVE the durable job in
    // the scan path — that is the state the recovery scan already picks up.
    const retained = path.join(dir, "retained.json");
    fs.writeFileSync(retained, JSON.stringify({ id: "b" }));
    const result = wakeup.finalizeReplyJobFile(retained, {
      status: "failed", reason: "connect ECONNREFUSED 127.0.0.1:8771", retriesExhausted: true,
    });
    assert.equal(result.disposition, "retain");
    assert.equal(fs.existsSync(retained), true);

    // A consumed-but-empty reply is still the app's to own; don't relaunch it.
    const noReply = path.join(dir, "noreply.json");
    fs.writeFileSync(noReply, JSON.stringify({ id: "c" }));
    assert.equal(wakeup.finalizeReplyJobFile(noReply, { status: "failed", replyStatus: "no_reply" }).disposition, "unlink");
    assert.equal(fs.existsSync(noReply), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("an ambiguous 409 preserves the full reply instead of deleting it", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-job-preserve-"));
  const jobsDir = path.join(dir, "reply-jobs");
  fs.mkdirSync(jobsDir);
  try {
    const jobPath = path.join(jobsDir, "job-1.json");
    const job = { id: "job-1", threadId: "t", turnId: "u", completedExecution: { turnResult: { message: "the full codex reply" } } };
    fs.writeFileSync(jobPath, JSON.stringify(job));

    const result = wakeup.finalizeReplyJobFile(jobPath, {
      status: "failed", httpStatus: 409, replyStatus: "outcome_unknown",
    });
    assert.equal(result.disposition, "preserve");
    assert.equal(result.preserved, true);
    assert.equal(fs.existsSync(jobPath), false);
    // The full text survives — the receipt only ever kept a 1000-char preview.
    assert.deepEqual(JSON.parse(fs.readFileSync(result.undeliveredPath, "utf8")), job);

    // ...and it is OUT of the recovery scan path, so it can never relaunch a turn.
    const scanned = [];
    const recovery = await wakeup.recoverReplyJobs({}, {
      jobsDir,
      recoveryLockDir: path.join(dir, ".recovery.lock"),
      worker: async (p) => { scanned.push(p); return { status: "delivered" }; },
    });
    assert.equal(recovery.scanned, 0);
    assert.deepEqual(scanned, []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("preserved replies are 0600 and the undelivered store is capped", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-job-preserve-hygiene-"));
  const jobsDir = path.join(dir, "reply-jobs");
  fs.mkdirSync(jobsDir);
  try {
    // gpt-5.5 review MED: rename keeps the source mode — a 0644 legacy job
    // must not land world-readable with full reply text.
    const loosePath = path.join(jobsDir, "loose.json");
    fs.writeFileSync(loosePath, JSON.stringify({ id: "loose" }), { mode: 0o644 });
    const preserved = wakeup.finalizeReplyJobFile(loosePath, {
      status: "failed", httpStatus: 409, replyStatus: "outcome_unknown",
    });
    assert.equal(preserved.preserved, true);
    assert.equal(fs.statSync(preserved.undeliveredPath).mode & 0o777, 0o600);

    // gpt-5.5 review MED: nothing else ever deletes preserved jobs, so the
    // store bounds itself — oldest evicted past the cap, newest kept.
    const undeliveredDir = path.join(jobsDir, "undelivered");
    for (let i = 0; i < 210; i += 1) {
      const p = path.join(undeliveredDir, `old-${String(i).padStart(3, "0")}.json`);
      fs.writeFileSync(p, "{}", { mode: 0o600 });
      fs.utimesSync(p, new Date(1000000 + i), new Date(1000000 + i));
    }
    wakeup.pruneUndeliveredReplyJobs(undeliveredDir);
    const left = fs.readdirSync(undeliveredDir).filter((n) => n.endsWith(".json"));
    assert.equal(left.length, 200);
    assert.equal(left.includes("old-000.json"), false, "oldest evicted first");
    assert.equal(left.includes("old-209.json"), true, "newest kept");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a retained job is re-delivered by the existing recovery scan", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nativeagent-codex-job-retain-scan-"));
  const jobsDir = path.join(dir, "reply-jobs");
  fs.mkdirSync(jobsDir);
  try {
    const jobPath = path.join(jobsDir, "job-2.json");
    // completedExecution is persisted BEFORE the POST, so the retained file
    // already carries everything a later delivery needs. No new state.
    fs.writeFileSync(jobPath, JSON.stringify({
      id: "job-2", threadId: "t", turnId: "u",
      completedExecution: { threadId: "t", turnId: "u", attempts: [], turnResult: { status: "completed", message: "reply" } },
    }));
    wakeup.finalizeReplyJobFile(jobPath, { status: "failed", reason: "connect ECONNREFUSED", retriesExhausted: true });

    const redelivered = [];
    const recovery = await wakeup.recoverReplyJobs({}, {
      jobsDir,
      recoveryLockDir: path.join(dir, ".recovery.lock"),
      worker: async (p) => {
        const loaded = JSON.parse(fs.readFileSync(p, "utf8"));
        redelivered.push(loaded.completedExecution.turnResult.message);
        return { status: "delivered", jobPath: p };
      },
    });
    assert.equal(recovery.scanned, 1);
    assert.deepEqual(redelivered, ["reply"]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- BRIDGES-5 source conformance guard -------------------------------------

test("all builder wake helpers use the shared event-driven process owner", () => {
  const swiftPath = path.join(
    __dirname, "..", "..",
    "Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+AgentBridgeTools.swift"
  );
  const source = fs.readFileSync(swiftPath, "utf8");
  const ownerStart = source.indexOf("private static func runBuilderWakeupHelper");
  const ownerEnd = source.indexOf("private static func runCodexWakeupHelper", ownerStart);
  assert.ok(ownerStart > 0 && ownerEnd > ownerStart, "shared builder process owner not found");
  const owner = source.slice(ownerStart, ownerEnd);
  assert.ok(owner.includes("SystemProcessAdapter().run("), "shared owner must use the native process adapter");
  assert.ok(owner.includes("standardInput: inputData"), "stdin payload must use the adapter's off-thread writer");
  assert.ok(owner.includes("outputByteLimit: 8 * 1024 * 1024"), "helper output must stay bounded");
  assert.equal(owner.includes("while process.isRunning"), false, "shared owner must not poll child state");
  assert.equal(owner.includes("Thread.sleep"), false, "shared owner must not sleep-poll");

  for (const name of ["runClaudeWakeupHelper", "runOMPWakeupHelper", "runCodexWakeupHelper"]) {
    const start = source.indexOf(`private static func ${name}`);
    assert.ok(start > 0, `${name} not found`);
    const wrapper = source.slice(start, start + 2200);
    assert.ok(wrapper.includes("runBuilderWakeupHelper("), `${name} must delegate to the shared owner`);
  }
});
