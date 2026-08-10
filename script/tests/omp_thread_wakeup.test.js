#!/usr/bin/env node
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

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
    input: JSON.stringify({ topic: "Bridge Topic", priority: "important", cwd: ctx.cwd, timeoutSeconds: 60, ...payload }),
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

test("a dead durable claim is taken over on retry after restart", () => {
  const ctx = fixture("takeover", 'printf \'%s\\n\' \'{"type":"session","id":"takeover-session"}\' \'{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"recovered"}]}}\'');
  const jobs = path.join(ctx.bridge, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  fs.writeFileSync(path.join(jobs, "takeover-id.json"), JSON.stringify({
    messageId: "takeover-id", claimId: "dead-claim", state: "running",
    claimantPid: 999999, runnerPid: 999998, payload: { messageId: "takeover-id", text: "ping" },
  }), { mode: 0o600 });
  const result = run(ctx, { messageId: "takeover-id", text: "ping" });
  assert.equal(result.status, "completed");
  assert.equal(result.reply, "recovered");
  assert.ok(fs.readdirSync(jobs).some((name) => name.startsWith("takeover-id.json.stale-")));
});
