#!/usr/bin/env node
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const { once } = require("events");

const helper = path.join(__dirname, "..", "omp_thread_wakeup.js");
const wakeup = require(helper);

function fixture(name, body) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `omp-wake-${name}-`));
  const bridge = path.join(root, "bridge");
  const cwd = path.join(root, "repo");
  fs.mkdirSync(bridge, { recursive: true });
  fs.mkdirSync(cwd, { recursive: true });
  const bin = path.join(root, "omp");
  fs.writeFileSync(bin, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return { root, bridge, cwd, bin };
}

function run(ctx, payload, extra = {}, timeout = 10_000) {
  const result = spawnSync(process.execPath, [helper], {
    input: JSON.stringify({ topic: "Bridge Topic", priority: "important", cwd: ctx.cwd, timeoutSeconds: 60, sessionId: "fixture-origin-session", ...payload }),
    encoding: "utf8",
    timeout,
    env: {
      ...process.env,
      NATIVE_AGENT_OMP_BRIDGE_DIR: ctx.bridge,
      NATIVE_AGENT_OMP_WAKE_BIN: ctx.bin,
      NATIVE_AGENT_OMP_WAKE_INLINE: "1",
      NATIVE_AGENT_OMP_WAKE_DRY_RUN: "1",
      ...extra,
    },
  });
  assert.equal(result.error, undefined, result.stderr);
  const line = result.stdout.trim().split("\n").at(-1);
  return JSON.parse(line);
}

async function waitFor(check, timeout = 3_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for OMP wake-job evidence");
}

for (const state of ["missing", "malformed", "empty-id", "unreadable"]) {
  test(`explicit continuation never starts OMP when pointer is ${state}`, () => {
    const ctx = fixture(`required-resume-${state}`, 'echo invoked >> "$0.invocations"\necho accidental');
    const pointer = path.join(ctx.bridge, "wake-sessions", "bridge-topic.json");
    fs.mkdirSync(path.dirname(pointer), { recursive: true });
    if (state === "malformed") fs.writeFileSync(pointer, "{invalid");
    if (state === "empty-id") fs.writeFileSync(pointer, JSON.stringify({ sessionId: " " }));
    if (state === "unreadable") fs.mkdirSync(pointer);
    const original = ["malformed", "empty-id"].includes(state) ? fs.readFileSync(pointer) : null;
    const payload = { messageId: `required-${state}`, text: "continue exact work", requireExistingConversation: true };
    const result = run(ctx, payload);
    assert.equal(result.status, "failed");
    assert.equal(result.reason, "continuation_unavailable");
    assert.equal(result.sessionMode, "resume_unavailable");
    assert.match(result.wouldSendText, /No OMP work or fresh conversation was started/);
    const job = JSON.parse(fs.readFileSync(result.jobPath, "utf8"));
    assert.equal(job.state, "settled");
    assert.equal(job.payload.requireExistingConversation, true);
    assert.equal(job.startedAt, undefined);
    assert.equal(fs.existsSync(`${ctx.bin}.invocations`), false);
    run(ctx, { ...payload, requireExistingConversation: false });
    assert.equal(fs.existsSync(`${ctx.bin}.invocations`), false);
    if (original) assert.deepEqual(fs.readFileSync(pointer), original);
    if (state === "missing") assert.equal(fs.existsSync(pointer), false);
    if (state === "unreadable") assert.equal(fs.statSync(pointer).isDirectory(), true);
  });
}

test("JSON event parsing extracts the final assistant reply despite a trailing user echo", () => {
  const parsed = wakeup.parseOMPOutput([
    JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "first" }] } }),
    JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "final reply" }] } }),
    JSON.stringify({ type: "message_end", message: { role: "user", content: [{ type: "text", text: "outbound prompt echo" }] } }),
  ].join("\n"));
  assert.equal(parsed.reply, "final reply");
  assert.equal(parsed.parsedEvents, 3);
});

test("JSON event parsing captures the id from OMP's session event", () => {
  const parsed = wakeup.parseOMPOutput([
    JSON.stringify({ type: "session", version: 3, id: "omp-session-123" }),
    JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "threaded reply" }] } }),
  ].join("\n"));
  assert.equal(parsed.sessionId, "omp-session-123");
  assert.equal(parsed.reply, "threaded reply");
  assert.equal(parsed.parsedEvents, 2);
});

for (const stopReason of ["error", "aborted"]) {
  for (const finalText of ["partial work before failure", ""]) {
    test(`JSON zero exit preserves ${stopReason} with ${finalText ? "partial" : "empty"} terminal content`, () => {
      const assistant = (text, stopReason, errorMessage) => ({
        role: "assistant", content: [{ type: "text", text }], stopReason, errorMessage,
      });
      const previous = assistant("earlier answer is not final completion", "stop");
      const terminal = assistant(finalText, stopReason, "provider interrupted the turn");
      const stdout = [
        { type: "message_end", message: previous },
        { type: "message_end", message: terminal },
        { type: "agent_end", messages: [previous, terminal] },
      ].map((event) => JSON.stringify(event)).join("\n");
      const result = wakeup.classify({ stdout, stderr: "", exitCode: 0, durationMs: 5 });
      assert.equal(result.status, "failed");
      assert.equal(result.reason, `omp_assistant_${stopReason}`);
      assert.equal(result.assistantError, "provider interrupted the turn");
      assert.equal(result.reply, finalText);
      assert.equal(result.partialReply, finalText ? "" : previous.content[0].text);
      const completion = wakeup.completionText(result, { messageId: "terminal-evidence" });
      assert.match(completion, /Status: failed/);
      assert.match(completion, /partial parsed reply:/);
      assert.match(completion, /provider interrupted the turn/);
    });
  }
}

test("a later successful assistant terminal supersedes a recoverable earlier error", () => {
  const stdout = JSON.stringify({ type: "agent_end", messages: [
    { role: "assistant", stopReason: "error", errorMessage: "transient", content: [{ type: "text", text: "partial" }] },
    { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "finished after recovery" }] },
  ] });
  const result = wakeup.classify({ stdout, stderr: "", exitCode: 0, durationMs: 5 });
  assert.equal(result.status, "completed");
  assert.equal(result.reply, "finished after recovery");
  assert.equal(result.assistantError, null);
  assert.equal(result.partialReply, "");
});

test("an empty successful terminal cannot reuse an earlier assistant answer", () => {
  const stdout = JSON.stringify({ type: "agent_end", messages: [
    { role: "assistant", stopReason: "stop", content: [{ type: "text", text: "earlier" }] },
    { role: "assistant", stopReason: "stop", content: [] },
  ] });
  const result = wakeup.classify({ stdout, stderr: "", exitCode: 0, durationMs: 5 });
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "omp_empty_reply");
  assert.equal(result.reply, "");
});

test("completion text carries the stable OMP conversation reference", () => {
  const text = wakeup.completionText(
    { status: "completed", reply: "done", durationMs: 1000 },
    { messageId: "omp-message-1", topic: "Bridge Topic", priority: "important" }
  );
  assert.match(text, /Conversation: omp:bridge-topic/);
  assert.match(text, /omp_message with conversation_id/);
});

test("first wake uses required OMP print/json/max-time flags and pins its session", () => {
  const ctx = fixture("new", 'printf "%s\\n" "$@" > "$0.args"\nprintf \'%s\\n\' \'{"type":"session","id":"omp-session-1"}\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OMP ok"}]}}\'');
  const result = run(ctx, { messageId: "new-1", text: "ping" });
  assert.equal(result.status, "completed");
  assert.equal(result.sessionMode, "new");
  assert.equal(result.reply, "OMP ok");
  const args = fs.readFileSync(`${ctx.bin}.args`, "utf8").trim().split("\n");
  assert.ok(args.includes("-p"));
  assert.ok(args.includes("--mode"));
  assert.ok(args.includes("json"));
  assert.ok(args.includes("--max-time"));
  assert.equal(args.includes("--profile"), false);
  const pointer = JSON.parse(fs.readFileSync(path.join(ctx.bridge, "wake-sessions", "bridge-topic.json"), "utf8"));
  assert.equal(pointer.sessionId, "omp-session-1");
  const job = JSON.parse(fs.readFileSync(path.join(ctx.bridge, "wake-jobs", "new-1.json"), "utf8"));
  assert.equal(job.state, "settled");
  assert.equal(job.sessionId, "omp-session-1");
});

test("next wake on the topic resumes with -r", () => {
  const ctx = fixture("resume", 'printf "%s\\n" "$@" > "$0.args"\nprintf \'%s\\n\' \'{"type":"session","id":"omp-session-1"}\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"threaded"}]}}\'');
  const first = run(ctx, { messageId: "resume-1", text: "first" });
  assert.equal(first.status, "completed");
  const second = run(ctx, { messageId: "resume-2", text: "second" });
  assert.equal(second.status, "completed");
  assert.equal(second.sessionMode, "resume");
  const args = fs.readFileSync(`${ctx.bin}.args`, "utf8").trim().split("\n");
  assert.equal(args[args.indexOf("-r") + 1], "omp-session-1");
  const explicit = run(ctx, { messageId: "resume-explicit", text: "third", requireExistingConversation: true });
  assert.equal(explicit.status, "completed");
  assert.equal(explicit.sessionMode, "resume");
  const resumedArgs = fs.readFileSync(`${ctx.bin}.args`, "utf8").trim().split("\n");
  assert.equal(resumedArgs[resumedArgs.indexOf("-r") + 1], "omp-session-1");
});

test("exit zero without a parsed assistant reply is a failure", () => {
  const ctx = fixture("empty", 'printf \'%s\\n\' \'{"type":"session","sessionId":"empty-session"}\'');
  const result = run(ctx, { messageId: "empty-1", text: "ping" });
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "omp_empty_reply");
  assert.equal(fs.existsSync(path.join(ctx.bridge, "wake-sessions", "bridge-topic.json")), false);
});

test("nonzero OMP exit preserves stderr and never reports completed", () => {
  const ctx = fixture("exit", 'echo "provider unavailable" >&2\nexit 7');
  const result = run(ctx, { messageId: "exit-1", text: "ping" });
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "omp_exit_7");
  assert.match(result.stderrTail, /provider unavailable/);
});

test("measured idle kills a dead turn and classifies it as stalled", () => {
  const ctx = fixture("idle", "exec sleep 30");
  const result = run(ctx, { messageId: "idle-1", text: "ping" }, {
    NATIVE_AGENT_OMP_WAKE_IDLE_SECONDS: "0.2",
    NATIVE_AGENT_OMP_WAKE_TIMEOUT_SECONDS: "5",
  }, 8_000);
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "omp_idle_timeout");
  assert.equal(result.stalled, true);
});

test("ongoing output durably advances liveness while the OMP job is running", async () => {
  const ctx = fixture("live-activity", `
i=0
while [ "$i" -lt 12 ]; do
  printf '%s\\n' '{"type":"progress"}'
  i=$((i + 1))
  sleep 0.1
done
printf '%s\\n' '{"type":"session","id":"live-session"}' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"still alive"}]}}'
`);
  const payload = {
    topic: "Bridge Topic", priority: "important", cwd: ctx.cwd,
    timeoutSeconds: 60, messageId: "live-activity-1", text: "ping",
  };
  const child = spawn(process.execPath, [helper], {
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      NATIVE_AGENT_OMP_BRIDGE_DIR: ctx.bridge,
      NATIVE_AGENT_OMP_WAKE_BIN: ctx.bin,
      NATIVE_AGENT_OMP_WAKE_INLINE: "1",
      NATIVE_AGENT_OMP_WAKE_DRY_RUN: "1",
      // This case checks durable progress, not cold process-start deadlines.
      // The separate idle-timeout fixture retains the aggressive kill budget.
      NATIVE_AGENT_OMP_WAKE_IDLE_SECONDS: "2",
      NATIVE_AGENT_OMP_WAKE_TIMEOUT_SECONDS: "5",
    },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
  child.stdin.end(JSON.stringify(payload));

  const file = path.join(ctx.bridge, "wake-jobs", "live-activity-1.json");
  const first = await waitFor(() => {
    try {
      const job = JSON.parse(fs.readFileSync(file, "utf8"));
      return job.state === "running" && job.lastActivityAt ? job : null;
    } catch { return null; }
  });
  const firstActivity = Date.parse(first.lastActivityAt);
  const advanced = await waitFor(() => {
    try {
      const job = JSON.parse(fs.readFileSync(file, "utf8"));
      return job.state === "running" && Date.parse(job.lastActivityAt) > firstActivity ? job : null;
    } catch { return null; }
  });
  assert.equal(advanced.state, "running");

  const [code] = await once(child, "close");
  assert.equal(code, 0, stderr);
  const result = JSON.parse(stdout.trim().split("\n").at(-1));
  assert.equal(result.status, "completed");
  assert.equal(result.stalled, false);
});

test("message id claim deduplicates and durable receipts survive", () => {
  const ctx = fixture("dedup", 'printf \'%s\\n\' \'{"type":"session","id":"dedup-session"}\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"once"}]}}\'');
  const first = run(ctx, { messageId: "same-id", text: "ping" });
  assert.equal(first.status, "completed");
  const second = run(ctx, { messageId: "same-id", text: "ping" });
  assert.equal(second.status, "skipped");
  assert.equal(second.reason, "duplicate");
  const receipts = fs.readFileSync(path.join(ctx.bridge, "wake-deliveries.jsonl"), "utf8").trim().split("\n");
  assert.equal(receipts.length, 1);
});

test("a known-unstarted durable claim is taken over without replacing its accepted brief", () => {
  const ctx = fixture("takeover", 'printf \'%s\\n\' \'{"type":"session","id":"takeover-session"}\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"recovered"}]}}\'');
  const jobs = path.join(ctx.bridge, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  fs.writeFileSync(path.join(jobs, "takeover-id.json"), JSON.stringify({
    schemaVersion: 2, messageId: "takeover-id", claimId: "dead-claim", state: "claimed",
    claimantPid: 999999, payload: { messageId: "takeover-id", topic: "Bridge Topic", cwd: ctx.cwd, text: "original brief" },
  }), { mode: 0o600 });
  const result = run(ctx, { messageId: "takeover-id", text: "ping" });
  assert.equal(result.status, "completed");
  assert.equal(result.reply, "recovered");
  assert.ok(fs.readdirSync(jobs).some((name) => name.startsWith("takeover-id.json.stale-")));
  const stored = JSON.parse(fs.readFileSync(path.join(jobs, "takeover-id.json"), "utf8"));
  assert.equal(stored.payload.text, "original brief");
});

test("dead running, dispatched, and legacy claims preserve uncertain effects without rerunning", () => {
  for (const [schemaVersion, state] of [[2, "running"], [2, "dispatching"], [1, "claimed"], [1, "dispatched"]]) {
    const ctx = fixture(`uncertain-${state}`, 'echo ran > "$0.executed"');
    const jobs = path.join(ctx.bridge, "wake-jobs");
    fs.mkdirSync(jobs, { recursive: true });
    const file = path.join(jobs, "uncertain-id.json");
    const original = JSON.stringify({
      schemaVersion, messageId: "uncertain-id", claimId: "dead-claim", state,
      claimantPid: 999999, payload: { messageId: "uncertain-id", topic: "Bridge Topic", text: "ping" },
    });
    fs.writeFileSync(file, original, { mode: 0o600 });
    const result = run(ctx, { messageId: "uncertain-id", text: "ping" });
    assert.equal(result.status, "skipped");
    assert.equal(result.reason, "execution_outcome_unknown");
    assert.equal(fs.readFileSync(file, "utf8"), original);
    assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
    assert.equal(fs.existsSync(path.join(ctx.bridge, "wake-deliveries.jsonl")), false);
  }
});

test("an explicit same-id retry recovers a topic-busy rejection after the owner releases it", () => {
  const ctx = fixture("busy-retry", 'echo ran >> "$0.executed"\nprintf \'%s\\n\' \'{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"completed once"}]}}\'');
  const lock = path.join(ctx.bridge, "wake-sessions", "bridge-topic.lock");
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: process.pid, messageId: "other-work" }));
  const payload = { messageId: "busy-retry-id", text: "original accepted work", sessionId: "original-return-route" };
  const rejected = run(ctx, payload);
  assert.equal(rejected.reason, "topic_busy");
  assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
  const jobs = path.join(ctx.bridge, "wake-jobs");
  const file = path.join(jobs, "busy-retry-id.json");
  const bytes = fs.readFileSync(file, "utf8");
  const original = JSON.parse(bytes);
  fs.rmSync(lock, { recursive: true, force: true });
  const retried = run(ctx, payload);
  assert.equal(retried.status, "completed");
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).payload, original.payload);
  const archived = fs.readdirSync(jobs).find((name) => name.startsWith("busy-retry-id.json.stale-"));
  assert.ok(archived);
  assert.equal(fs.readFileSync(path.join(jobs, archived), "utf8"), bytes);
  assert.equal(run(ctx, payload).reason, "duplicate");
  assert.equal(fs.readFileSync(`${ctx.bin}.executed`, "utf8").trim().split("\n").length, 1);
});

test("topic-busy labels cannot recover legacy, attempted, generic-failed, or live-owned OMP jobs", () => {
  for (const patch of [
    { schemaVersion: 1 }, { startedAt: new Date().toISOString() },
    { runnerPid: 999998 }, { reason: "omp_exit_1" }, { claimantPid: process.pid },
  ]) {
    const ctx = fixture("unsafe-topic-retry", 'echo ran > "$0.executed"');
    const jobs = path.join(ctx.bridge, "wake-jobs");
    fs.mkdirSync(jobs, { recursive: true });
    const file = path.join(jobs, "unsafe-topic-retry.json");
    const bytes = JSON.stringify({
      schemaVersion: 2, messageId: "unsafe-topic-retry", claimId: "rejected-claim",
      state: "settled", status: "failed", reason: "topic_busy", claimantPid: 999999,
      payload: { messageId: "unsafe-topic-retry", topic: "Bridge Topic", text: "original" },
      bridge: { status: "dry_run" }, ...patch,
    });
    fs.writeFileSync(file, bytes);
    const result = run(ctx, { messageId: "unsafe-topic-retry", text: "original" });
    assert.equal(result.status, "skipped");
    assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
    assert.equal(fs.readFileSync(file, "utf8"), bytes);
  }
});

test("unknown completion delivery is retained without a blind repost", () => {
  for (const bridge of [{ status: "unknown", reason: "bridge_reply_timeout" }, null]) {
    const ctx = fixture("unknown-delivery", 'echo ran > "$0.executed"');
    const jobs = path.join(ctx.bridge, "wake-jobs");
    fs.mkdirSync(jobs, { recursive: true });
    const file = path.join(jobs, "reply-id.json");
    const original = JSON.stringify({
      schemaVersion: 2, messageId: "reply-id", claimId: "settled-claim", state: "settled",
      status: "completed", completionText: "original completion", bridge,
      payload: { messageId: "reply-id", topic: "Bridge Topic", text: "ping" },
    });
    fs.writeFileSync(file, original, { mode: 0o600 });
    const result = run(ctx, { messageId: "reply-id", text: "ping" });
    assert.equal(result.status, "skipped");
    assert.equal(result.reason, "delivery_outcome_unknown");
    assert.equal(fs.readFileSync(file, "utf8"), original);
    assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
    assert.equal(fs.existsSync(path.join(ctx.bridge, "wake-deliveries.jsonl")), false);
  }
});

test("proven-unsent completion can be explicitly retried without rerunning OMP", () => {
  const ctx = fixture("unsent-delivery", 'echo ran > "$0.executed"');
  const jobs = path.join(ctx.bridge, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  const file = path.join(jobs, "reply-id.json");
  fs.writeFileSync(file, JSON.stringify({
    schemaVersion: 2, messageId: "reply-id", claimId: "settled-claim", state: "settled",
    status: "completed", completionText: "original completion", bridge: { status: "failed", reason: "bridge_token_missing" },
    payload: { messageId: "reply-id", topic: "Bridge Topic", text: "ping", sessionId: "fixture-origin-session" },
  }), { mode: 0o600 });
  const result = run(ctx, { messageId: "reply-id", text: "ping" });
  assert.equal(result.status, "replayed");
  assert.equal(result.bridge.status, "dry_run");
  assert.equal(result.bridge.text, "original completion");
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).completionText, null);
  assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
  const second = run(ctx, { messageId: "reply-id", text: "ping" });
  assert.equal(second.reason, "duplicate");
  assert.equal(fs.readFileSync(path.join(ctx.bridge, "wake-deliveries.jsonl"), "utf8").trim().split("\n").length, 1);
});

for (const exitCode of [0, 7]) {
  test(`missing completion origin retains OMP ${exitCode ? "failed" : "completed"} work without posting or rerunning`, () => {
    const ctx = fixture(`missing-origin-${exitCode}`, `echo ran >> "$0.invocations"\nprintf '%s\\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"retained terminal evidence"}]}}'\nexit ${exitCode}`);
    const payload = { messageId: `missing-origin-${exitCode}`, text: "bounded fixture", sessionId: "   " };
    const env = { NATIVE_AGENT_OMP_WAKE_DRY_RUN: "0", NATIVE_AGENT_OMP_WAKE_BRIDGE_URL: "invalid://never-contact" };
    const result = run(ctx, payload, env);
    assert.equal(result.status, exitCode ? "failed" : "completed");
    assert.equal(result.bridge.status, "blocked");
    assert.equal(result.bridge.reason, "missing_origin_session");
    assert.equal(result.bridge.deliveryAttempted, false);
    assert.match(result.bridge.note, /do not rerun/);
    const file = path.join(ctx.bridge, "wake-jobs", `${payload.messageId}.json`);
    const retained = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.match(retained.completionText, /retained terminal evidence/);
    const duplicate = run(ctx, { ...payload, sessionId: "different-current-chat" }, env);
    assert.equal(duplicate.reason, "missing_origin_session");
    assert.equal(duplicate.status, "blocked");
    assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).completionText, retained.completionText);
    assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).payload.sessionId, "   ");
    assert.equal(fs.readFileSync(`${ctx.bin}.invocations`, "utf8").trim().split("\n").length, 1);
    assert.equal(fs.readFileSync(path.join(ctx.bridge, "wake-deliveries.jsonl"), "utf8").trim().split("\n").length, 1);
  });
}

test("missing route on legacy OMP lost delivery blocks replay without changing execution", () => {
  const ctx = fixture("legacy-missing-origin", 'echo ran > "$0.executed"');
  const jobs = path.join(ctx.bridge, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  const file = path.join(jobs, "legacy-missing.json");
  const job = { schemaVersion: 2, messageId: "legacy-missing", claimId: "original", state: "settled", status: "failed",
    completionText: "retained failed result", bridge: { status: "failed", reason: "bridge_token_missing" },
    payload: { messageId: "legacy-missing", topic: "Bridge Topic", text: "prior work" } };
  fs.writeFileSync(file, JSON.stringify(job));
  const result = run(ctx, { messageId: job.messageId, text: "prior work" }, { NATIVE_AGENT_OMP_WAKE_DRY_RUN: "0" });
  assert.equal(result.reason, "missing_origin_session");
  assert.equal(result.bridge.deliveryAttempted, false);
  const retained = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(retained.status, "failed");
  assert.equal(retained.completionText, job.completionText);
  assert.equal(fs.existsSync(`${ctx.bin}.executed`), false);
});

test("unknown older outcome does not block explicitly authorized new work on that conversation", () => {
  const ctx = fixture("explicit-new", 'printf \'%s\\n\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"new work"}]}}\'');
  const jobs = path.join(ctx.bridge, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  fs.writeFileSync(path.join(jobs, "old-id.json"), JSON.stringify({
    schemaVersion: 2, messageId: "old-id", claimId: "dead", state: "running", claimantPid: 999999,
    payload: { messageId: "old-id", topic: "Bridge Topic", text: "old work" },
  }), { mode: 0o600 });
  const result = run(ctx, { messageId: "new-id", text: "authorized new work" });
  assert.equal(result.status, "completed");
  assert.equal(result.reply, "new work");
});

test("detached parent's admission never rewinds the child's terminal lifecycle", async () => {
  const ctx = fixture("detached-owner", 'printf \'%s\\n\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"fast result"}]}}\'');
  const result = run(ctx, { messageId: "detached-id", text: "ping" }, { NATIVE_AGENT_OMP_WAKE_INLINE: "0" });
  assert.equal(result.status, "sent");
  const file = path.join(ctx.bridge, "wake-jobs", "detached-id.json");
  const settled = await waitFor(() => {
    const job = JSON.parse(fs.readFileSync(file, "utf8"));
    return job.state === "settled" ? job : null;
  });
  assert.equal(settled.reply, "fast result");
  assert.equal(settled.runnerPid, result.runnerPid);
  const duplicate = run(ctx, { messageId: "detached-id", text: "ping" });
  assert.equal(duplicate.reason, "duplicate");
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).state, "settled");
});
