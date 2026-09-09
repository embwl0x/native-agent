"use strict";

// Tests for script/claude_thread_wakeup.js — the her→me wake path.
//
// Every test drives the helper as a real child process with a FAKE `claude`
// binary (NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN) so the classification, dedup,
// pointer, timeout, and self-heal behavior are observed end-to-end rather
// than asserted against internal state. Node stdlib only.

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { spawn, spawnSync } = require("node:child_process");
const test = require("node:test");

const HELPER = path.join(__dirname, "..", "claude_thread_wakeup.js");
const wakeup = require("../claude_thread_wakeup.js");

function makeRoot(label) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `claude-wake-${label}-`));
  const bridgeDir = path.join(root, "claude-bridge");
  fs.mkdirSync(bridgeDir, { recursive: true, mode: 0o700 });
  const cwd = path.join(root, "workspace");
  fs.mkdirSync(cwd, { recursive: true });
  return { root, bridgeDir, cwd };
}

/// Write an executable fake `claude`. The body receives $1/$2 as the session
/// args the helper chose, plus $MARKER for recording invocations.
function fakeClaude(root, name, body) {
  const file = path.join(root, `${name}.sh`);
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

function runHelper(env, payload, options = {}) {
  const result = spawnSync(process.execPath, [HELPER], {
    input: JSON.stringify(payload),
    encoding: "utf8",
    env: { ...process.env, ...env },
    timeout: options.timeoutMs || 30_000,
  });
  const stdout = String(result.stdout || "").trim();
  let parsed = null;
  try {
    parsed = JSON.parse(stdout.split("\n").filter(Boolean).pop() || "null");
  } catch {}
  assert.ok(parsed, `helper produced no JSON envelope. stdout=${stdout} stderr=${result.stderr}`);
  return parsed;
}

/// Non-blocking twin of runHelper. spawnSync would wedge the event loop, so
/// any test with an in-process HTTP bridge or two overlapping wakes uses this.
function runHelperAsync(env, payload, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HELPER], {
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const killer = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, options.timeoutMs || 30_000);
    child.on("close", () => {
      clearTimeout(killer);
      let parsed = null;
      try { parsed = JSON.parse(stdout.trim().split("\n").filter(Boolean).pop() || "null"); } catch {}
      if (!parsed) {
        reject(new Error(`helper produced no JSON envelope. stdout=${stdout} stderr=${stderr}`));
        return;
      }
      resolve(parsed);
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function jobFileFor(ctx, messageId) {
  return path.join(ctx.bridgeDir, "wake-jobs", `${messageId}.json`);
}

function readJob(ctx, messageId) {
  return JSON.parse(fs.readFileSync(jobFileFor(ctx, messageId), "utf8"));
}

function markerLines(marker) {
  if (!fs.existsSync(marker)) return [];
  return fs.readFileSync(marker, "utf8").split("\n").filter(Boolean);
}

function baseEnv(ctx, claudeBin, extra = {}) {
  return {
    NATIVE_AGENT_CLAUDE_BRIDGE_DIR: ctx.bridgeDir,
    NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN: claudeBin,
    NATIVE_AGENT_CLAUDE_WAKE_CWD: ctx.cwd,
    NATIVE_AGENT_CLAUDE_WAKE_INLINE: "1",
    NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "1",
    // The runner spawns nothing while an interactive Claude is open on the
    // Mac; the harness must still exercise the spawn path on a developer's Mac.
    NATIVE_AGENT_CLAUDE_WAKE_IGNORE_INTERACTIVE: "1",
    ...extra,
  };
}

function payloadFor(overrides = {}) {
  return {
    messageId: overrides.messageId || crypto.randomUUID(),
    text: "run the parity check",
    priority: "important",
    topic: "wake parity",
    queuedAt: "2026-07-25T12:00:00Z",
    sessionId: "fixture-origin-session",
    inboxPath: "/tmp/claude-inbox.jsonl",
    ...overrides,
  };
}

function receipts(ctx) {
  const file = path.join(ctx.bridgeDir, "wake-deliveries.jsonl");
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

for (const exitCode of [0, 7]) {
  test(`missing completion origin retains Claude ${exitCode ? "failed" : "completed"} work without posting or rerunning`, () => {
    const ctx = makeRoot(`missing-origin-${exitCode}`);
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "terminal", `echo ran >> "${marker}"\necho 'retained terminal evidence'\nexit ${exitCode}`);
    const payload = payloadFor({ messageId: `missing-origin-${exitCode}`, sessionId: null });
    const env = baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0", NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "invalid://never-contact" });
    const result = runHelper(env, payload);
    assert.equal(result.status, exitCode ? "failed" : "completed");
    assert.equal(result.bridge.status, "blocked");
    assert.equal(result.bridge.reason, "missing_origin_session");
    assert.equal(result.bridge.deliveryAttempted, false);
    assert.match(result.bridge.note, /do not rerun/);
    assert.equal(result.deliveryLost, false);
    const retained = readJob(ctx, payload.messageId);
    assert.match(retained.completionText, /retained terminal evidence/);
    const duplicate = runHelper(env, { ...payload, sessionId: "different-current-chat" });
    assert.equal(duplicate.status, "blocked");
    assert.equal(duplicate.reason, "missing_origin_session");
    assert.equal(readJob(ctx, payload.messageId).completionText, retained.completionText);
    assert.equal(readJob(ctx, payload.messageId).payload.sessionId, undefined);
    assert.equal(markerLines(marker).length, 1);
    assert.equal(receipts(ctx).length, 1);
  });
}

test("missing route on legacy lost delivery blocks replay and preserves the original result", () => {
  const ctx = makeRoot("legacy-missing-origin");
  const file = jobFileFor(ctx, "legacy-missing");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const job = { messageId: "legacy-missing", state: "settled", status: "completed", deliveryLost: true,
    completionText: "only retained result", payload: { messageId: "legacy-missing", text: "prior work" } };
  fs.writeFileSync(file, JSON.stringify(job));
  const marker = path.join(ctx.root, "must-not-run");
  const bin = fakeClaude(ctx.root, "never", `echo ran > "${marker}"`);
  const result = runHelper(baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0" }),
    payloadFor({ messageId: job.messageId, sessionId: null }));
  assert.equal(result.reason, "missing_origin_session");
  assert.equal(result.bridge.deliveryAttempted, false);
  assert.equal(result.deliveryLost, false);
  assert.equal(readJob(ctx, "legacy-missing").completionText, job.completionText);
  assert.equal(fs.existsSync(marker), false);
});

// ---------------------------------------------------------------- pure units

test("topic slug is lowercase alnum+dash with a general fallback", () => {
  assert.equal(wakeup.topicSlug("Wake Parity!"), "wake-parity");
  assert.equal(wakeup.topicSlug("  ***  "), "general");
  assert.equal(wakeup.topicSlug(undefined), "general");
  assert.equal(wakeup.topicSlug("Desk/363 — precondition"), "desk-363-precondition");
});

test("timeout resolution defaults to the 3600s ceiling and clamps payload values to 60-3600", () => {
  // Was 900s. The ceiling is now the backstop rather than the normal way a job
  // ends — a wedged job is caught by the stall watchdog in minutes instead.
  assert.equal(wakeup.resolveTimeoutSeconds({}), 3600);
  assert.equal(wakeup.resolveTimeoutSeconds({ timeoutSeconds: 5 }), 60);
  assert.equal(wakeup.resolveTimeoutSeconds({ timeoutSeconds: 99_999 }), 3600);
  assert.equal(wakeup.resolveTimeoutSeconds({ timeoutSeconds: 120 }), 120);
});

test("session-not-found detection is conservative", () => {
  assert.equal(wakeup.sessionGone("Error: No conversation found with session ID abc"), true);
  assert.equal(wakeup.sessionGone("session not found"), true);
  assert.equal(wakeup.sessionGone("Credit balance too low"), false);
  assert.equal(wakeup.sessionGone("network error: ECONNRESET"), false);
  assert.equal(wakeup.sessionGone(""), false);
});

test("classification maps every observable outcome to one honest status", () => {
  assert.equal(wakeup.classify({ exitCode: 0, stdout: "done", stderr: "", durationMs: 1 }, 900).status, "completed");
  assert.equal(wakeup.classify({ exitCode: 0, stdout: "  \n", stderr: "", durationMs: 1 }, 900).status, "completed_without_reply");
  const failed = wakeup.classify({ exitCode: 2, stdout: "", stderr: "boom", durationMs: 1 }, 900);
  assert.equal(failed.status, "failed");
  assert.equal(failed.reason, "claude_exit_2");
  const timedOut = wakeup.classify({ exitCode: null, stdout: "", stderr: "", timedOut: true, durationMs: 1 }, 30);
  assert.equal(timedOut.reason, "timeout_after_30s");
  const spawnFailed = wakeup.classify({ spawnError: "ENOENT", stdout: "", stderr: "", durationMs: 1 }, 900);
  assert.equal(spawnFailed.reason, "claude_spawn_failed");
});

test("completion text tells Agent not to auto-fire another claude_message", () => {
  const text = wakeup.formatCompletionForAgent(
    { status: "completed", reply: "artifact written", durationMs: 4000 },
    { messageId: "m-1", topic: "wake parity", priority: "important" }
  );
  assert.match(text, /Do NOT auto-fire another claude_message/);
  assert.match(text, /m-1/);
  assert.match(text, /artifact written/);
  assert.match(text, /Conversation: claude:wake-parity/);
  assert.match(text, /claude_message with conversation_id/);

  const empty = wakeup.formatCompletionForAgent(
    { status: "completed_without_reply", reply: "", durationMs: 10 },
    { messageId: "m-2" }
  );
  assert.match(empty, /NO output/);
  assert.match(empty, /failed wake, not/);
});

// ------------------------------------------------------------------ end-to-end

test("duplicate messageId is skipped without spawning claude a second time", () => {
  const ctx = makeRoot("dedup");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "first pass done"`);
  const env = baseEnv(ctx, bin);
  const payload = payloadFor({ messageId: "dedup-message-1" });

  const first = runHelper(env, payload);
  assert.equal(first.status, "completed");
  assert.equal(fs.readFileSync(marker, "utf8").split("\n").filter(Boolean).length, 1);

  const second = runHelper(env, payload);
  assert.equal(second.status, "skipped");
  assert.equal(second.reason, "duplicate");
  // The proof that matters: no second spawn.
  assert.equal(fs.readFileSync(marker, "utf8").split("\n").filter(Boolean).length, 1);
  assert.equal(receipts(ctx).length, 1);
});

for (const state of ["missing", "empty", "unreadable"]) {
  test(`explicit continuation never starts fresh when pointer is ${state}`, () => {
    const ctx = makeRoot(`required-resume-${state}`);
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "must-not-run", `echo invoked >> "${marker}"\necho accidental`);
    const pointer = path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt");
    fs.mkdirSync(path.dirname(pointer), { recursive: true });
    if (state === "empty") fs.writeFileSync(pointer, "\n");
    if (state === "unreadable") fs.mkdirSync(pointer);
    const payload = payloadFor({ messageId: `required-${state}`, requireExistingConversation: true });
    const result = runHelper(baseEnv(ctx, bin), payload);
    assert.equal(result.status, "failed");
    assert.equal(result.reason, "continuation_unavailable");
    assert.equal(result.sessionMode, "resume_unavailable");
    assert.equal(result.selfHeal, null);
    assert.match(result.wouldSendText, /No fresh conversation was started/);
    const job = readJob(ctx, payload.messageId);
    assert.equal(job.state, "settled");
    assert.equal(job.payload.requireExistingConversation, true);
    assert.equal(job.startedAt, undefined);
    assert.equal(markerLines(marker).length, 0);
    runHelper(baseEnv(ctx, bin), { ...payload, requireExistingConversation: false });
    assert.equal(markerLines(marker).length, 0);
    if (state === "missing") assert.equal(fs.existsSync(pointer), false);
    if (state === "empty") assert.equal(fs.readFileSync(pointer, "utf8"), "\n");
    if (state === "unreadable") assert.equal(fs.statSync(pointer).isDirectory(), true);
  });
}

test("explicit resume session-not-found preserves pointer without fresh retry", () => {
  const ctx = makeRoot("required-resume-gone");
  const pointer = path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt");
  fs.mkdirSync(path.dirname(pointer), { recursive: true });
  const original = `dead-session-id\n${ctx.cwd}\n`;
  fs.writeFileSync(pointer, original);
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "gone", `echo "$1 $2" >> "${marker}"\necho 'Error: No conversation found with session ID dead-session-id' >&2\nexit 1`);
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "required-gone", requireExistingConversation: true }));
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "continuation_unavailable");
  assert.equal(result.selfHeal, null);
  assert.deepEqual(markerLines(marker), ["--resume dead-session-id"]);
  assert.equal(fs.readFileSync(pointer, "utf8"), original);
  assert.deepEqual(fs.readdirSync(path.dirname(pointer)), ["wake-parity.txt"]);
});

test("first wake creates the topic pointer and the next wake resumes it", () => {
  const ctx = makeRoot("pointer");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "ack"`);
  const env = baseEnv(ctx, bin);

  const first = runHelper(env, payloadFor({ messageId: "pointer-1", topic: "Wake Parity" }));
  assert.equal(first.status, "completed");
  assert.equal(first.topicSlug, "wake-parity");
  assert.equal(first.sessionMode, "new");

  const pointerFile = path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt");
  const lines = fs.readFileSync(pointerFile, "utf8").split("\n");
  assert.equal(lines[0], first.sessionId);
  assert.equal(lines[1], ctx.cwd);
  assert.equal(fs.statSync(pointerFile).mode & 0o777, 0o600);

  const second = runHelper(env, payloadFor({ messageId: "pointer-2", topic: "Wake Parity" }));
  assert.equal(second.status, "completed");
  assert.equal(second.sessionMode, "resume");
  assert.equal(second.sessionId, first.sessionId);

  const invocations = fs.readFileSync(marker, "utf8").split("\n").filter(Boolean);
  assert.equal(invocations.length, 2);
  assert.equal(invocations[0], `--session-id ${first.sessionId}`);
  assert.equal(invocations[1], `--resume ${first.sessionId}`);

  const explicit = runHelper(env, payloadFor({ messageId: "pointer-explicit", topic: "Wake Parity", requireExistingConversation: true }));
  assert.equal(explicit.status, "completed");
  assert.equal(explicit.sessionMode, "resume");
  assert.equal(explicit.sessionId, first.sessionId);

  // A different topic gets its own pointer and its own session.
  const other = runHelper(env, payloadFor({ messageId: "pointer-3", topic: "other work" }));
  assert.equal(other.sessionMode, "new");
  assert.notEqual(other.sessionId, first.sessionId);
  assert.ok(fs.existsSync(path.join(ctx.bridgeDir, "wake-sessions", "other-work.txt")));
});

test("an explicit payload cwd overrides the topic pointer cwd", () => {
  const ctx = makeRoot("payload-cwd");
  const alternate = path.join(ctx.root, "external-project");
  fs.mkdirSync(alternate, { recursive: true });
  const marker = path.join(ctx.root, "cwd-invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `pwd >> "${marker}"\necho "ack"`);
  const env = baseEnv(ctx, bin);

  const first = runHelper(env, payloadFor({ messageId: "payload-cwd-1", topic: "same topic" }));
  assert.equal(first.status, "completed");
  const second = runHelper(env, payloadFor({
    messageId: "payload-cwd-2",
    topic: "same topic",
    cwd: alternate,
  }));
  assert.equal(second.status, "completed");
  const cwds = fs.readFileSync(marker, "utf8").trim().split("\n");
  assert.deepEqual(cwds, [fs.realpathSync(ctx.cwd), fs.realpathSync(alternate)]);
});

test("exit 0 with empty stdout is completed_without_reply, not success", () => {
  const ctx = makeRoot("empty");
  const bin = fakeClaude(ctx.root, "silent", "exit 0");
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "empty-1" }));

  assert.equal(result.status, "completed_without_reply");
  assert.equal(result.reason, "empty_stdout");
  assert.equal(result.replyChars, 0);
  // No pointer is pinned for a session that produced no turn output? It DID
  // exit cleanly, so the session exists and stays resumable.
  assert.ok(fs.existsSync(path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt")));
});

test("nonzero exit is failed with the stderr tail preserved", () => {
  const ctx = makeRoot("failed");
  const bin = fakeClaude(ctx.root, "boom", 'echo "credit balance too low" >&2\nexit 7');
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "failed-1" }));

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "claude_exit_7");
  assert.match(result.stderrTail, /credit balance too low/);
  // A failed NEW session must not pin a pointer.
  assert.equal(fs.existsSync(path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt")), false);

  const receipt = receipts(ctx)[0];
  assert.equal(receipt.status, "failed");
  assert.equal(receipt.exitCode, 7);
});

test("a hung claude is SIGTERM'd at the timeout and reported honestly", () => {
  const ctx = makeRoot("timeout");
  const bin = fakeClaude(ctx.root, "sleepy", "exec sleep 45");
  const result = runHelper(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "1" }),
    payloadFor({ messageId: "timeout-1" }),
    { timeoutMs: 20_000 }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "timeout_after_1s");
  assert.equal(result.timeoutSeconds, 1);
  assert.ok(result.durationMs < 15_000, `expected a bounded kill, got ${result.durationMs}ms`);
  const receipt = receipts(ctx)[0];
  assert.equal(receipt.reason, "timeout_after_1s");
});

test("a completed reply that cannot reach the bridge keeps the job file and says so", () => {
  const ctx = makeRoot("bridge-down");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", 'echo "the artifact is written"');
  // Port 9 (discard) on loopback is closed in this environment: a real POST
  // attempt that fails, not a mocked failure.
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0",
    NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "http://127.0.0.1:9/claude/message",
  });
  const result = runHelper(env, payloadFor({ messageId: "bridge-down-1" }));

  assert.equal(result.status, "completed");
  assert.equal(result.bridge.status, "failed");
  assert.equal(result.deliveryLost, true);

  // The job file survives so recovery has something to replay, and the
  // receipt records the delivery failure instead of dropping the reply.
  assert.ok(fs.existsSync(result.jobPath));
  const job = JSON.parse(fs.readFileSync(result.jobPath, "utf8"));
  assert.equal(job.bridgeStatus, "failed");
  assert.equal(job.payload.messageId, "bridge-down-1");

  const receipt = receipts(ctx)[0];
  assert.equal(receipt.status, "completed");
  assert.equal(receipt.bridge.status, "failed");
  assert.equal(receipt.deliveryLost, true);
  assert.equal(receipt.replyChars, "the artifact is written".length);
});

test("dry run returns the exact text that would have gone to Agent", () => {
  const ctx = makeRoot("dry-run");
  const bin = fakeClaude(ctx.root, "ok", 'echo "receipt body"');
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "dry-1" }));

  assert.equal(result.bridge.status, "dry_run");
  assert.match(result.wouldSendText, /receipt body/);
  assert.match(result.wouldSendText, /dry-1/);
  assert.equal(result.deliveryLost, false);
});

test("an explicit session-not-found renames the pointer aside and retries once", () => {
  const ctx = makeRoot("self-heal");
  const sessionsDir = path.join(ctx.bridgeDir, "wake-sessions");
  fs.mkdirSync(sessionsDir, { recursive: true, mode: 0o700 });
  const pointerFile = path.join(sessionsDir, "wake-parity.txt");
  fs.writeFileSync(pointerFile, `dead-session-id\n${ctx.cwd}\n`, { mode: 0o600 });

  const bin = fakeClaude(
    ctx.root,
    "heal",
    'if [ "$1" = "--resume" ]; then echo "Error: No conversation found with session ID dead-session-id" >&2; exit 1; fi\necho "healed and answered"'
  );
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "heal-1" }));

  assert.equal(result.status, "completed");
  assert.equal(result.sessionMode, "new");
  assert.notEqual(result.sessionId, "dead-session-id");
  assert.equal(result.selfHeal.action, "pointer_renamed_aside");
  assert.equal(result.selfHeal.previousSessionId, "dead-session-id");

  const stale = fs.readdirSync(sessionsDir).filter((name) => name.startsWith("wake-parity.txt.stale-"));
  assert.equal(stale.length, 1, `expected one renamed-aside pointer, saw ${JSON.stringify(fs.readdirSync(sessionsDir))}`);
  assert.equal(fs.readFileSync(path.join(sessionsDir, stale[0]), "utf8").split("\n")[0], "dead-session-id");
  // The fresh session is now pinned.
  assert.equal(fs.readFileSync(pointerFile, "utf8").split("\n")[0], result.sessionId);
});

test("any other resume failure leaves the pointer exactly where it is", () => {
  const ctx = makeRoot("no-heal");
  const sessionsDir = path.join(ctx.bridgeDir, "wake-sessions");
  fs.mkdirSync(sessionsDir, { recursive: true, mode: 0o700 });
  const pointerFile = path.join(sessionsDir, "wake-parity.txt");
  fs.writeFileSync(pointerFile, `live-session-id\n${ctx.cwd}\n`, { mode: 0o600 });

  const bin = fakeClaude(ctx.root, "flaky", 'echo "API error: 529 overloaded" >&2\nexit 1');
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "no-heal-1" }));

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "claude_exit_1");
  assert.equal(result.selfHeal, null);
  assert.equal(result.sessionMode, "resume");
  assert.equal(fs.readFileSync(pointerFile, "utf8").split("\n")[0], "live-session-id");
  assert.deepEqual(fs.readdirSync(sessionsDir), ["wake-parity.txt"]);
});

test("a timeout on a resumed session never renames the pointer aside", () => {
  const ctx = makeRoot("timeout-no-heal");
  const sessionsDir = path.join(ctx.bridgeDir, "wake-sessions");
  fs.mkdirSync(sessionsDir, { recursive: true, mode: 0o700 });
  const pointerFile = path.join(sessionsDir, "wake-parity.txt");
  fs.writeFileSync(pointerFile, `live-session-id\n${ctx.cwd}\n`, { mode: 0o600 });

  const bin = fakeClaude(ctx.root, "sleepy", 'echo "no conversation found" >&2\nexec sleep 45');
  const result = runHelper(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "1" }),
    payloadFor({ messageId: "timeout-no-heal-1" }),
    { timeoutMs: 20_000 }
  );

  assert.equal(result.reason, "timeout_after_1s");
  assert.equal(result.selfHeal, null);
  assert.deepEqual(fs.readdirSync(sessionsDir), ["wake-parity.txt"]);
});

test("missing text is skipped before any job file is claimed", () => {
  const ctx = makeRoot("no-text");
  const bin = fakeClaude(ctx.root, "ok", 'echo "should never run"');
  const result = runHelper(baseEnv(ctx, bin), { messageId: "no-text-1", text: "" });

  assert.equal(result.status, "skipped");
  assert.equal(result.reason, "missing_text");
  assert.equal(fs.existsSync(path.join(ctx.bridgeDir, "wake-jobs", "no-text-1.json")), false);
});

test("detached mode claims the job and returns before the turn finishes", () => {
  const ctx = makeRoot("detached");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho done`);
  const env = baseEnv(ctx, bin);
  delete env.NATIVE_AGENT_CLAUDE_WAKE_INLINE;

  const result = runHelper(env, payloadFor({ messageId: "detached-1" }));
  assert.equal(result.status, "sent");
  assert.equal(result.mode, "detached");
  assert.ok(result.runnerPid > 0);
  assert.ok(fs.existsSync(result.jobPath));

  // Same messageId still dedups while the detached runner is in flight.
  const dup = runHelper(env, payloadFor({ messageId: "detached-1" }));
  assert.equal(dup.reason, "duplicate");
});

// ------------------------------------------------------- recovery / takeover

test("a durably unstarted job whose runner died is recovered with its original payload", () => {
  const ctx = makeRoot("dead-pid");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "recovered answer"`);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

  // Schema2 queued phase proves the child never admitted a Claude attempt.
  // 999999 is above macOS's pid ceiling, so process.kill(pid, 0) is ESRCH.
  // Timestamps are aged past the spawn-grace window (default 30s) so this is a
  // GENUINELY orphaned claim, not a parent/child handoff still in flight.
  const payload = payloadFor({ messageId: "dead-pid-1" });
  fs.writeFileSync(jobFileFor(ctx, "dead-pid-1"), JSON.stringify({
    schemaVersion: 2,
    messageId: "dead-pid-1",
    claimId: "unstarted-claim",
    createdAt: new Date(Date.now() - 120_000).toISOString(),
    heartbeatAt: new Date(Date.now() - 120_000).toISOString(),
    state: "queued",
    pid: 999999,
    topicSlug: "wake-parity",
    timeoutSeconds: 900,
    payload,
  }, null, 2), { mode: 0o600 });

  const result = runHelper(baseEnv(ctx, bin), { ...payload, text: "replacement text must not replace accepted brief" });

  assert.equal(result.status, "completed");
  assert.equal(result.takeover.reason, "unstarted_owner_dead");
  assert.equal(markerLines(marker).length, 1, "the takeover must actually run the wake");
  // The dead job is renamed aside, never deleted.
  const stale = fs.readdirSync(jobsDir).filter((name) => name.startsWith("dead-pid-1.json.stale-"));
  assert.equal(stale.length, 1, `expected one renamed-aside job, saw ${JSON.stringify(fs.readdirSync(jobsDir))}`);
  assert.equal(JSON.parse(fs.readFileSync(path.join(jobsDir, stale[0]), "utf8")).pid, 999999);
  assert.equal(readJob(ctx, "dead-pid-1").state, "settled");
  assert.equal(readJob(ctx, "dead-pid-1").payload.text, payload.text);
});

test("dead running Claude effects stay unknown while an explicit new message remains allowed", () => {
  const ctx = makeRoot("running-unknown");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho "new authorized work"`);
  fs.mkdirSync(path.join(ctx.bridgeDir, "wake-jobs"), { recursive: true });
  const payload = payloadFor({ messageId: "running-unknown" });
  const file = jobFileFor(ctx, payload.messageId);
  const original = JSON.stringify({
    schemaVersion: 2, messageId: payload.messageId, claimId: "original-claim",
    state: "running", pid: 999999, runnerPid: 999998,
    startedAt: "2026-08-01T00:00:00Z", attemptSessionId: "original-session", payload,
  });
  fs.writeFileSync(file, original, { mode: 0o600 });
  const held = runHelper(baseEnv(ctx, bin), payload);
  assert.equal(held.reason, "execution_outcome_unknown");
  assert.equal(held.executionOutcome, "unknown");
  assert.equal(fs.readFileSync(file, "utf8"), original);
  assert.equal(markerLines(marker).length, 0);
  const fresh = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "explicit-new-work" }));
  assert.equal(fresh.status, "completed");
  assert.equal(markerLines(marker).length, 1);
});

test("new-schema unstarted and proven spawn-failed Claude jobs retain recovery", () => {
  for (const state of ["claimed", "spawn_failed"]) {
    const ctx = makeRoot(`unstarted-${state}`);
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho "recovered"`);
    fs.mkdirSync(path.join(ctx.bridgeDir, "wake-jobs"), { recursive: true });
    const payload = payloadFor({ messageId: `unstarted-${state}` });
    fs.writeFileSync(jobFileFor(ctx, payload.messageId), JSON.stringify({
      schemaVersion: 2, messageId: payload.messageId, claimId: "unstarted-claim",
      state, pid: 999999, createdAt: new Date().toISOString(), payload,
    }), { mode: 0o600 });
    const result = runHelper(baseEnv(ctx, bin), payload);
    assert.equal(result.status, "completed");
    assert.equal(result.takeover.reason, "unstarted_owner_dead");
    assert.equal(markerLines(marker).length, 1);
  }
});

test("concurrent recovery of one unstarted Claude claim admits only one worker", async () => {
  const ctx = makeRoot("recovery-race");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\nsleep 0.2\necho "one result"`);
  const jobs = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  const payload = payloadFor({ messageId: "recovery-race" });
  fs.writeFileSync(jobFileFor(ctx, payload.messageId), JSON.stringify({
    schemaVersion: 2, messageId: payload.messageId, claimId: "dead-claim",
    state: "queued", pid: 999999, runnerPid: 999998, payload,
  }), { mode: 0o600 });
  const results = await Promise.all([
    runHelperAsync(baseEnv(ctx, bin), payload),
    runHelperAsync(baseEnv(ctx, bin), payload),
  ]);
  assert.equal(results.filter((result) => result.status === "completed").length, 1);
  assert.equal(results.filter((result) => result.status === "skipped").length, 1);
  assert.equal(markerLines(marker).length, 1);
  assert.equal(fs.readdirSync(jobs).filter((name) => name.startsWith("recovery-race.json.stale-")).length, 1);
});

test("Claude does not invoke Claude when durable execution admission cannot be written", () => {
  const ctx = makeRoot("admission-write-failure");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho "must not run"`);
  const payload = payloadFor({ messageId: "admission-write-failure" });
  const file = jobFileFor(ctx, payload.messageId);
  const hook = path.join(ctx.root, "reject-running-write.cjs");
  fs.writeFileSync(hook, `
const fs = require('node:fs');
const rename = fs.renameSync;
fs.renameSync = function(from, to) {
  if (to === ${JSON.stringify(file)}) {
    let row;
    try { row = JSON.parse(fs.readFileSync(from, 'utf8')); } catch {}
    if (row && row.state === 'running') {
      const error = new Error('injected admission write failure');
      error.code = 'EIO';
      throw error;
    }
  }
  return rename.apply(this, arguments);
};
`);
  const result = runHelper(baseEnv(ctx, bin, { NODE_OPTIONS: `--require=${hook}` }), payload);
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "execution_admission_unrecorded");
  assert.equal(markerLines(marker).length, 0);
  assert.equal(readJob(ctx, payload.messageId).startedAt, undefined);
});

test("a stale heartbeat NEVER takes over a live pid, no matter how old", () => {
  const ctx = makeRoot("stale-beat");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "took over"`);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

  const payload = payloadFor({ messageId: "stale-beat-1" });
  const writeJob = (messageId, extra) => {
    fs.writeFileSync(jobFileFor(ctx, messageId), JSON.stringify({
      messageId,
      createdAt: new Date(Date.now() - 600_000).toISOString(),
      heartbeatAt: new Date(Date.now() - 600_000).toISOString(),
      state: "running",
      claimId: "incumbent-claim",
      topicSlug: "wake-parity",
      timeoutSeconds: 900,
      payload: payloadFor({ messageId }),
      ...extra,
    }, null, 2), { mode: 0o600 });
  };

  // OUR pid: provably alive. A ten-minute-old heartbeat used to be enough to
  // rename this job aside and run a second Claude against the same messageId,
  // with both processes posting a completion to Agent.
  writeJob("stale-beat-1", { pid: process.pid });

  const held = runHelper(baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_STALE_MS: "600000" }), payload);
  assert.equal(held.reason, "duplicate");
  assert.equal(markerLines(marker).length, 0);

  // Stale by any measure — and still refused, because the owner is alive.
  const stillHeld = runHelper(baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_STALE_MS: "1" }), payload);
  assert.equal(stillHeld.status, "skipped");
  assert.equal(stillHeld.reason, "duplicate");
  assert.equal(stillHeld.note, "staleHeartbeat", "the refusal must be auditable, not silent");
  assert.equal(stillHeld.takeover, undefined);
  assert.equal(markerLines(marker).length, 0, "a live owner must never be raced");
  // The incumbent's job file is untouched: not renamed aside, claim intact.
  assert.deepEqual(
    fs.readdirSync(jobsDir).filter((name) => name.startsWith("stale-beat-1")),
    ["stale-beat-1.json"]
  );
  assert.equal(readJob(ctx, "stale-beat-1").claimId, "incumbent-claim");

  // A DEAD parent pid does not unlock it either while the recorded runner pid
  // is alive — "every recorded owner pid" means every one of them.
  const second = payloadFor({ messageId: "stale-beat-2" });
  writeJob("stale-beat-2", { pid: 999999, runnerPid: process.pid });
  const runnerHeld = runHelper(baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_STALE_MS: "1" }), second);
  assert.equal(runnerHeld.reason, "duplicate");
  assert.equal(runnerHeld.note, "staleHeartbeat");
  assert.equal(markerLines(marker).length, 0);
});

test("a writer that loses the claim mid-run aborts: no delivery, no pointer, an orphaned_claim row", () => {
  const ctx = makeRoot("claim-cas");
  const marker = path.join(ctx.root, "invocations.txt");
  const jobPath = jobFileFor(ctx, "claim-cas-1");
  // The fake claude is the seam: while "Claude" is thinking, a successor
  // takes the job over and writes its own claimId. Our runner comes back to a
  // job file it no longer owns.
  const stolen = JSON.stringify({
    messageId: "claim-cas-1",
    claimId: "successor-claim-id",
    state: "running",
    pid: 999999,
  });
  const bin = fakeClaude(
    ctx.root,
    "stolen",
    `echo "$1 $2" >> "${marker}"\nprintf '%s' '${stolen}' > "${jobPath}"\necho "an answer that must never reach Agent"`
  );

  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "claim-cas-1" }));

  assert.equal(result.status, "aborted");
  assert.equal(result.reason, "claim_lost");
  assert.equal(result.kind, "orphaned_claim");
  assert.equal(result.stage, "before_pointer_write");
  // claude DID run — the point is that nothing downstream of it happened.
  assert.equal(markerLines(marker).length, 1);

  const all = receipts(ctx);
  assert.equal(all.filter((entry) => entry.kind === "delivery").length, 0, "a dispossessed writer must not deliver");
  const orphans = all.filter((entry) => entry.kind === "orphaned_claim");
  assert.equal(orphans.length, 1, `expected one orphaned_claim row, saw ${JSON.stringify(all.map((e) => e.kind))}`);
  assert.equal(orphans[0].messageId, "claim-cas-1");
  assert.equal(orphans[0].status, "aborted");
  assert.ok(orphans[0].claimId, "the losing claimId is recorded so the loss is traceable");

  // The pointer is the successor's to write, not ours.
  assert.equal(fs.existsSync(path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt")), false);
  // And the successor's claim survives our exit untouched.
  assert.equal(JSON.parse(fs.readFileSync(jobPath, "utf8")).claimId, "successor-claim-id");
});

test("claim-checked writes gate on the on-disk claimId", () => {
  const ctx = makeRoot("owns-claim");
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });
  const jobPath = path.join(jobsDir, "owns.json");
  fs.writeFileSync(jobPath, JSON.stringify({ claimId: "mine" }), { mode: 0o600 });

  assert.equal(wakeup.ownsClaim(jobPath, "mine"), true);
  assert.equal(wakeup.ownsClaim(jobPath, "theirs"), false);
  fs.rmSync(jobPath);
  assert.equal(wakeup.ownsClaim(jobPath, "mine"), false, "a vanished job file is lost ownership");
});

test("legacy parent/child spawn uncertainty is not permission to replay after a grace expires", () => {
  const ctx = makeRoot("spawn-grace");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "took over"`);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

  // The exact shape of a parent that died between claimJob and the runnerPid
  // write: its own pid recorded and dead, NO runnerPid, and young.
  const writeOrphanedParent = (messageId, ageMs) => {
    const stamp = new Date(Date.now() - ageMs).toISOString();
    fs.writeFileSync(jobFileFor(ctx, messageId), JSON.stringify({
      messageId,
      createdAt: stamp,
      heartbeatAt: stamp,
      state: "claimed",
      claimId: `claim-${messageId}`,
      pid: 999999,
      topicSlug: "wake-parity",
      timeoutSeconds: 900,
      payload: payloadFor({ messageId }),
    }, null, 2), { mode: 0o600 });
  };

  // Fresh: the detached child may well be alive and simply unnamed on disk.
  writeOrphanedParent("spawn-grace-1", 1000);
  const held = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "spawn-grace-1" }));
  assert.equal(held.status, "skipped");
  assert.equal(held.reason, "duplicate");
  assert.equal(held.note, "spawnGrace");
  assert.equal(markerLines(marker).length, 0);
  assert.equal(readJob(ctx, "spawn-grace-1").claimId, "claim-spawn-grace-1");

  // Passing the grace cannot prove that an unnamed child made no changes.
  writeOrphanedParent("spawn-grace-2", 120_000);
  const taken = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "spawn-grace-2" }));
  assert.equal(taken.status, "skipped");
  assert.equal(taken.reason, "execution_outcome_unknown");
  assert.equal(markerLines(marker).length, 0);
  const stale = fs.readdirSync(jobsDir).filter((name) => name.startsWith("spawn-grace-2.json.stale-"));
  assert.equal(stale.length, 0);
  assert.equal(readJob(ctx, "spawn-grace-2").claimId, "claim-spawn-grace-2");

  // Disabling the grace changes waiting, never grants effect replay authority.
  writeOrphanedParent("spawn-grace-3", 1000);
  const forced = runHelper(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_SPAWN_GRACE_MS: "0" }),
    payloadFor({ messageId: "spawn-grace-3" })
  );
  assert.equal(forced.status, "skipped");
  assert.equal(forced.reason, "execution_outcome_unknown");
  assert.equal(markerLines(marker).length, 0);
});

test("a completed-but-undelivered reply is REPLAYED, never re-run", () => {
  const ctx = makeRoot("replay");
  const marker = path.join(ctx.root, "invocations.txt");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "the only copy of the answer"`);

  // First pass: Claude answers, the bridge is down, the reply is stranded.
  const first = runHelper(
    baseEnv(ctx, bin, {
      NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0",
      NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "http://127.0.0.1:9/claude/message",
    }),
    payloadFor({ messageId: "replay-1" })
  );
  assert.equal(first.status, "completed");
  assert.equal(first.deliveryLost, true);
  assert.equal(markerLines(marker).length, 1);
  assert.equal(readJob(ctx, "replay-1").deliveryLost, true);

  // Second arrival of the SAME messageId with the bridge reachable: the answer
  // is redelivered from the job file. The marker file is the proof there was
  // no second claude spawn.
  const second = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "replay-1" }));
  assert.equal(second.status, "redelivered");
  assert.equal(second.deliveryLost, false);
  assert.equal(markerLines(marker).length, 1, "redelivery must NOT spawn claude again");
  assert.match(second.wouldSendText, /the only copy of the answer/);

  const job = readJob(ctx, "replay-1");
  assert.equal(job.deliveryLost, false);
  assert.equal(job.completionText, null);
  assert.ok(job.redeliveredAt);

  const all = receipts(ctx);
  assert.equal(all.length, 2);
  assert.equal(all[1].kind, "redelivery");
  assert.equal(all[1].deliveryLost, false);

  // And once delivered, the id is a plain duplicate again.
  const third = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "replay-1" }));
  assert.equal(third.reason, "duplicate");
  assert.equal(markerLines(marker).length, 1);
});

// ------------------------------------------------------------ topic locking

test("a second wake on a locked topic QUEUES BEHIND the owner and resumes the same thread", async () => {
  const ctx = makeRoot("topic-lock");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "slow", `echo "$1 $2" >> "${marker}"\nsleep 3\necho "slow answer"`);
  // Baseline wait is short; queue-behind extends it to the live owner's
  // advertised hold deadline, so the second wake WAITS instead of degrading
  // to a fresh context-free session (Defect 3, 2026-07-25).
  const env = baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_LOCK_WAIT_MS: "300" });

  const [a, b] = await Promise.all([
    runHelperAsync(env, payloadFor({ messageId: "lock-a", topic: "Wake Parity" })),
    runHelperAsync(env, payloadFor({ messageId: "lock-b", topic: "Wake Parity" })),
  ]);

  // Both completed, strictly serialized: one minted the thread, the other
  // RESUMED it. Nobody ran fresh-uncontinued; that path no longer exists.
  assert.equal(a.status, "completed");
  assert.equal(b.status, "completed");
  assert.equal(markerLines(marker).length, 2);
  assert.equal(a.sessionId, b.sessionId, "queued wake must resume the SAME topic thread");
  const modes = [a.sessionMode, b.sessionMode].sort();
  assert.deepEqual(modes, ["new", "resume"]);
  assert.ok(![a, b].some((r) => r.uncontinued), "uncontinued must never appear again");
  const invocations = markerLines(marker).map((line) => line.split(" ")[0]).sort();
  assert.deepEqual(invocations, ["--resume", "--session-id"]);

  // The pointer holds the shared thread, and the next wake resumes it too.
  const pointerFile = path.join(ctx.bridgeDir, "wake-sessions", "wake-parity.txt");
  assert.equal(fs.readFileSync(pointerFile, "utf8").split("\n")[0], a.sessionId);
  const third = await runHelperAsync(env, payloadFor({ messageId: "lock-c", topic: "Wake Parity" }));
  assert.equal(third.sessionMode, "resume");
  assert.equal(third.sessionId, a.sessionId);
});

test("a wedged topic lock REJECTS the wake by id — never a silent fresh session", async () => {
  const ctx = makeRoot("topic-reject");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "never runs"`);
  // Forge a lock held by a LIVE process (this test process) with an advertised
  // deadline far in the future — a wedged-but-alive owner. Cap the queue wait
  // so the test is fast.
  const lockDir = path.join(ctx.bridgeDir, "wake-sessions", "busy-topic.lock");
  fs.mkdirSync(lockDir, { recursive: true, mode: 0o700 });
  // Must match processStartIdentity() in the helper: sha256 of the trimmed
  // `ps -p <pid> -o lstart=,command=` output for the recorded pid.
  const psOut = spawnSync("/bin/ps", ["-p", String(process.pid), "-o", "lstart=,command="], { encoding: "utf8" })
    .stdout.trim();
  const identity = crypto.createHash("sha256").update(psOut).digest("hex");
  const farDeadline = new Date(Date.now() + 3_600_000).toISOString();
  fs.writeFileSync(
    path.join(lockDir, "pid"),
    `${process.pid}\n${new Date().toISOString()}\n${identity}\nin-flight-job-42\n${farDeadline}\n`,
    { mode: 0o600 }
  );
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_LOCK_WAIT_MS: "200",
    NATIVE_AGENT_CLAUDE_WAKE_QUEUE_BEHIND_CAP_MS: "400",
  });

  const result = await runHelperAsync(env, payloadFor({ messageId: "reject-1", topic: "busy topic" }));

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "rejected_topic_busy");
  assert.equal(result.inFlightMessageId, "in-flight-job-42", "rejection must NAME the in-flight job");
  // Nothing ran, nothing was pinned: no claude invocation, no pointer file.
  assert.equal(markerLines(marker).length, 0);
  assert.ok(!fs.existsSync(path.join(ctx.bridgeDir, "wake-sessions", "busy-topic.txt")));
  // The rejection is loud in what crosses back to Agent, and never replayable.
  assert.match(result.wouldSendText || "", /REJECTED/);
  assert.match(result.wouldSendText || "", /in-flight-job-42/);
  assert.equal(result.deliveryLost, false);
  const job = readJob(ctx, "reject-1");
  assert.equal(job.state, "settled");
  assert.equal(job.status, "failed");
  assert.equal(job.reason, "rejected_topic_busy");
  assert.equal(job.deliveryLost, false);
  assert.equal(job.completionText, null);

  const jobFile = path.join(ctx.bridgeDir, "wake-jobs", "reject-1.json");
  const rejectionBytes = fs.readFileSync(jobFile, "utf8");
  fs.rmSync(lockDir, { recursive: true, force: true });
  const retried = await runHelperAsync(env, payloadFor({ messageId: "reject-1", topic: "busy topic" }));
  assert.equal(retried.status, "completed");
  assert.equal(markerLines(marker).length, 1);
  const archived = fs.readdirSync(path.dirname(jobFile)).find((name) => name.startsWith("reject-1.json.stale-"));
  assert.ok(archived, "retain the original rejection and delivery evidence");
  assert.equal(fs.readFileSync(path.join(path.dirname(jobFile), archived), "utf8"), rejectionBytes);
  assert.deepEqual(readJob(ctx, "reject-1").payload, job.payload);
  const duplicate = await runHelperAsync(env, payloadFor({ messageId: "reject-1", topic: "busy topic" }));
  assert.equal(duplicate.reason, "duplicate");
  assert.equal(markerLines(marker).length, 1);
});

test("topic-busy labels cannot recover legacy, attempted, generic-failed, or live-owned Claude jobs", () => {
  for (const patch of [
    { schemaVersion: 1 }, { startedAt: new Date().toISOString() },
    { attempts: [{ exitCode: 1 }] }, { reason: "claude_exit_1" }, { pid: process.pid },
  ]) {
    const ctx = makeRoot("unsafe-topic-retry");
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"`);
    const payload = payloadFor({ messageId: "unsafe-topic-retry" });
    const file = path.join(ctx.bridgeDir, "wake-jobs", `${payload.messageId}.json`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const bytes = JSON.stringify({
      schemaVersion: 2, messageId: payload.messageId, claimId: "rejected-claim", payload,
      state: "settled", status: "failed", reason: "rejected_topic_busy", pid: 999999,
      bridgeStatus: "dry_run", ...patch,
    });
    fs.writeFileSync(file, bytes);
    const result = runHelper(baseEnv(ctx, bin), payload);
    assert.equal(result.status, "skipped");
    assert.equal(markerLines(marker).length, 0);
    assert.equal(fs.readFileSync(file, "utf8"), bytes);
  }
});

// -------------------------------------------------- bridge endpoint discovery

test("the published bridge descriptor wins over the legacy fixed port", async () => {
  const ctx = makeRoot("descriptor");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", 'echo "descriptor answer"');

  const received = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      received.push({
        url: req.url,
        auth: req.headers.authorization,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  assert.notEqual(port, 8771, "the point of this test is a NONSTANDARD port");

  try {
    // Exactly the shape ClaudeBridge.writeDiscoveryFiles publishes.
    fs.writeFileSync(path.join(ctx.bridgeDir, "bridge.json"), JSON.stringify({
      schemaVersion: 1,
      host: "127.0.0.1",
      port,
      url: `http://127.0.0.1:${port}`,
      token: "test-token",
      processIdentifier: process.pid,
      writtenAt: new Date().toISOString(),
    }, null, 2), { mode: 0o600 });

    const env = baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0" });
    delete env.NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL;

    const result = await runHelperAsync(env, payloadFor({ messageId: "descriptor-1" }));
    assert.equal(result.status, "completed");
    assert.equal(result.bridge.status, "delivered");
    assert.equal(result.bridge.url, `http://127.0.0.1:${port}/claude/message`);
    assert.equal(result.deliveryLost, false);
    assert.equal(received.length, 1);
    assert.equal(received[0].url, "/claude/message");
    assert.equal(received[0].auth, "Bearer test-token");
    assert.equal(received[0].body.sender, "claude");
    assert.match(received[0].body.text, /descriptor answer/);

    // The env override still outranks a perfectly good descriptor.
    const overridden = await runHelperAsync(
      { ...env, NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "http://127.0.0.1:9/claude/message" },
      payloadFor({ messageId: "descriptor-2" })
    );
    assert.equal(overridden.bridge.url, "http://127.0.0.1:9/claude/message");
    assert.equal(overridden.bridge.status, "failed");
    assert.equal(received.length, 1, "the override must not have reached the descriptor server");
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

// -------------------------------------------------------------- rate guard

test("repeated wakes on the same topic are rate-limited without spawning", () => {
  const ctx = makeRoot("rate");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho ack`);
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_RATE_MAX: "2",
    NATIVE_AGENT_CLAUDE_WAKE_RATE_WINDOW_MS: "600000",
  });

  assert.equal(runHelper(env, payloadFor({ messageId: "rate-1", topic: "ping pong" })).status, "completed");
  assert.equal(runHelper(env, payloadFor({ messageId: "rate-2", topic: "ping pong" })).status, "completed");

  const limited = runHelper(env, payloadFor({ messageId: "rate-3", topic: "ping pong" }));
  assert.equal(limited.status, "skipped");
  assert.equal(limited.reason, "rate_limited_topic");
  assert.equal(limited.recentJobs, 2);
  assert.equal(limited.topicSlug, "ping-pong");
  assert.equal(markerLines(marker).length, 2, "a rate-limited wake must not spawn claude");
  // No job file is claimed for the suppressed wake — the message is still in
  // the durable inbox, so a later legitimate retry of the same id can run.
  assert.equal(fs.existsSync(jobFileFor(ctx, "rate-3")), false);

  // The guard is per-topic, not global: a different topic still wakes.
  const other = runHelper(env, payloadFor({ messageId: "rate-4", topic: "unrelated work" }));
  assert.equal(other.status, "completed");
  assert.equal(markerLines(marker).length, 3);

  // An aged-out window releases the guard.
  const wide = runHelper(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_RATE_MAX: "2", NATIVE_AGENT_CLAUDE_WAKE_RATE_WINDOW_MS: "1" }),
    payloadFor({ messageId: "rate-5", topic: "ping pong" })
  );
  assert.equal(wide.status, "completed");
});

// ------------------------------------------------------ detached end-to-end

test("the DETACHED runner completes the whole flow: claude, receipt, settled job", async () => {
  const ctx = makeRoot("detached-e2e");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "detached answer"`);
  const env = baseEnv(ctx, bin);
  delete env.NATIVE_AGENT_CLAUDE_WAKE_INLINE;

  const claim = runHelper(env, payloadFor({ messageId: "detached-e2e-1", topic: "detached run" }));
  assert.equal(claim.status, "sent");
  assert.equal(claim.mode, "detached");

  // Bounded poll — a detached child that never lands must FAIL the test, not
  // hang it.
  const deadline = Date.now() + 15_000;
  let job = null;
  while (Date.now() < deadline) {
    try {
      const current = readJob(ctx, "detached-e2e-1");
      if (current.state === "settled") { job = current; break; }
    } catch {}
    await sleep(100);
  }
  assert.ok(job, "detached runner did not settle the job within 15s");

  assert.equal(job.status, "completed");
  assert.equal(job.bridgeStatus, "dry_run");
  assert.equal(job.deliveryLost, false);
  assert.equal(markerLines(marker).length, 1);
  assert.equal(markerLines(marker)[0].split(" ")[0], "--session-id");

  const receipt = receipts(ctx).find((entry) => entry.messageId === "detached-e2e-1");
  assert.ok(receipt, "detached run wrote no delivery receipt");
  assert.equal(receipt.status, "completed");
  assert.equal(receipt.replyChars, "detached answer".length);
  assert.equal(receipt.pointerIntegrity, "ok");

  // The detached path pins the topic pointer exactly like the inline path.
  const pointer = fs.readFileSync(path.join(ctx.bridgeDir, "wake-sessions", "detached-run.txt"), "utf8");
  assert.equal(pointer.split("\n")[0], receipt.claudeSessionId);
});

test("replay is at-most-once: a concurrent replayer's lock defers redelivery", () => {
  const ctx = makeRoot("replay-lock");
  const marker = path.join(ctx.root, "invocations.txt");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "the only copy of the answer"`);

  // Strand a completed reply (bridge down).
  const first = runHelper(
    baseEnv(ctx, bin, {
      NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0",
      NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "http://127.0.0.1:9/claude/message",
    }),
    payloadFor({ messageId: "replay-race-1" })
  );
  assert.equal(first.deliveryLost, true);

  // A LIVE concurrent replayer holds the replay lock: this arrival must
  // defer, deliver nothing, and leave the stranded reply intact.
  const lockDir = `${jobFileFor(ctx, "replay-race-1")}.replay.lock`;
  fs.mkdirSync(lockDir, { mode: 0o700 });
  fs.writeFileSync(path.join(lockDir, "pid"), `${process.pid}\n`, { mode: 0o600 });
  const deferred = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "replay-race-1" }));
  assert.equal(deferred.status, "skipped");
  assert.equal(deferred.reason, "replay_in_progress");
  assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 0);
  assert.equal(readJob(ctx, "replay-race-1").deliveryLost, true);
  assert.ok(readJob(ctx, "replay-race-1").completionText);
  assert.equal(markerLines(marker).length, 1, "no second claude spawn while deferring");

  // A DEAD replayer's lock is stolen (renamed aside) and redelivery proceeds.
  fs.writeFileSync(path.join(lockDir, "pid"), "999999\n", { mode: 0o600 });
  const redelivered = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "replay-race-1" }));
  assert.equal(redelivered.status, "redelivered");
  assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 1);
  assert.equal(readJob(ctx, "replay-race-1").deliveryLost, false);
  assert.equal(readJob(ctx, "replay-race-1").completionText, null);
  assert.equal(markerLines(marker).length, 1);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  const staleLocks = fs.readdirSync(jobsDir).filter((n) => n.includes(".replay.lock.stale-"));
  assert.equal(staleLocks.length, 1, "dead lock is renamed aside, never deleted");
  assert.equal(fs.existsSync(lockDir), false, "winner releases its lock");
});

test("a fresh unreadable job file is a claimant mid-write, not a takeover target", () => {
  const ctx = makeRoot("mid-write");
  const marker = path.join(ctx.root, "invocations.txt");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "done"`);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

  // Fresh empty file = a live claimant between O_EXCL create and JSON write.
  fs.writeFileSync(jobFileFor(ctx, "mid-write-1"), "", { mode: 0o600 });
  const deferred = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "mid-write-1" }));
  assert.equal(deferred.status, "skipped");
  assert.equal(deferred.reason, "duplicate");
  assert.equal(deferred.note, "claimMidWrite");
  assert.equal(markerLines(marker).length, 0);
  assert.equal(fs.readdirSync(jobsDir).filter((n) => n.startsWith("mid-write-1.json.stale-")).length, 0);

  // An old unreadable record remains unknown, never proof that nothing ran.
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(jobFileFor(ctx, "mid-write-1"), old, old);
  const taken = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "mid-write-1" }));
  assert.equal(taken.status, "skipped");
  assert.equal(taken.reason, "execution_outcome_unknown");
  assert.equal(markerLines(marker).length, 0);
  assert.equal(fs.readFileSync(jobFileFor(ctx, "mid-write-1"), "utf8"), "");
  assert.equal(fs.readdirSync(jobsDir).filter((n) => n.startsWith("mid-write-1.json.stale-")).length, 0);
});

test("a pid-less replay lock defers only within the acquire grace, then is stolen", () => {
  const ctx = makeRoot("replay-lock-grace");
  const marker = path.join(ctx.root, "invocations.txt");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "stranded answer"`);

  const first = runHelper(
    baseEnv(ctx, bin, {
      NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0",
      NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: "http://127.0.0.1:9/claude/message",
    }),
    payloadFor({ messageId: "lock-grace-1" })
  );
  assert.equal(first.deliveryLost, true);

  // Pid-less lock, fresh: a contender mid-acquire — defer.
  const lockDir = `${jobFileFor(ctx, "lock-grace-1")}.replay.lock`;
  fs.mkdirSync(lockDir, { mode: 0o700 });
  const deferred = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "lock-grace-1" }));
  assert.equal(deferred.reason, "replay_in_progress");
  assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 0);

  // Same lock aged past the grace: the contender died mid-acquire — steal
  // and redeliver.
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(lockDir, old, old);
  const redelivered = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "lock-grace-1" }));
  assert.equal(redelivered.status, "redelivered");
  assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 1);
  assert.equal(markerLines(marker).length, 1, "redelivery never re-runs claude");
});

// ------------------------------------------------- unknown-vs-lost delivery

/// A bridge that ACCEPTS the POST but never responds — the live failure shape
/// of 2026-07-25: /claude/message blocks on Agent's whole turn past the
/// client timeout while the message already sits durably in her session store.
function startHangingBridge(onBody = null, { disconnectAfterBody = false } = {}) {
  const sockets = new Set();
  const server = http.createServer((req) => {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      if (onBody) onBody(JSON.parse(body));
      if (disconnectAfterBody) req.socket.destroy();
    });
  });
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({
        url: `http://127.0.0.1:${server.address().port}/claude/message`,
        close: () => new Promise((done) => {
          for (const socket of sockets) socket.destroy();
          server.close(done);
        }),
      });
    });
  });
}

function storeDirFor(ctx) {
  return path.join(ctx.root, "chat-messages");
}

function unknownEnv(ctx, bin, bridgeUrl, extra = {}) {
  return baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0",
    NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_URL: bridgeUrl,
    NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_TIMEOUT_MS: "400",
    NATIVE_AGENT_CLAUDE_WAKE_MESSAGE_STORE_DIR: storeDirFor(ctx),
    ...extra,
  });
}

test("a bridge reply timeout is UNKNOWN — never deliveryLost, never replayed", async () => {
  const ctx = makeRoot("unknown-timeout");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "answer that landed"`);
  const bridge = await startHangingBridge();
  try {
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-1", sessionId: "SESS-A" })
    );
    assert.equal(result.status, "completed");
    assert.equal(result.bridge.status, "unknown");
    assert.match(result.bridge.reason, /bridge_reply_timeout_after_400ms/);
    assert.equal(result.deliveryLost, false);
    // No session store on disk: the orthogonal observer has no opinion either.
    assert.equal(result.sessionStoreCheck, "unreadable");

    const job = readJob(ctx, "unknown-1");
    assert.equal(job.bridgeStatus, "unknown");
    assert.equal(job.deliveryLost, false);
    assert.ok(job.completionText, "unknown keeps the text for a later store-settle");

    // A duplicate arrival must NOT replay on unknown alone: rare false
    // redelivery is worse than none — it double-delivers a landed message.
    const dup = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-1", sessionId: "SESS-A" })
    );
    assert.equal(dup.status, "skipped");
    assert.equal(dup.reason, "duplicate");
    assert.equal(dup.note, "unknown_unresolved");
    assert.equal(markerLines(marker).length, 1, "no re-run and no replay on unknown");
    assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 0);
  } finally {
    await bridge.close();
  }
});

test("an earlier same-ID rejection cannot confirm delivery of the later result", async () => {
  const ctx = makeRoot("same-id-result-proof");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "ran" >> "${marker}"\necho "new completed result"`);
  const payload = payloadFor({ messageId: "same-id-result", sessionId: "SESS-EXACT" });
  const rejection = wakeup.formatCompletionForAgent({
    status: "failed", reason: "rejected_topic_busy", durationMs: 0, inFlightMessageId: "other-job",
  }, payload);
  const storePath = path.join(storeDirFor(ctx), "SESS-EXACT.jsonl");
  fs.mkdirSync(storeDirFor(ctx), { recursive: true });
  fs.writeFileSync(storePath, `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] ${rejection}` })}\n`);
  let posts = 0;
  const bridge = await startHangingBridge(() => { posts += 1; });
  try {
    const env = unknownEnv(ctx, bin, bridge.url);
    const first = await runHelperAsync(env, payload);
    assert.equal(first.status, "completed");
    assert.equal(first.bridge.status, "unknown", "old rejection is not this result's delivery");
    assert.equal(first.sessionStoreCheck, "absent");
    const job = readJob(ctx, payload.messageId);
    assert.match(job.completionText, /new completed result/);
    assert.equal(job.deliveryLost, false);

    const early = await runHelperAsync(env, payload);
    assert.equal(early.note, "unknown_absent_within_grace");
    assert.equal(posts, 1, "ambiguity alone cannot repost the result");
    assert.equal(readJob(ctx, payload.messageId).completionText, job.completionText);

    // Legacy unknown records without expected text cannot be settled using
    // a matching ID alone, and cannot invent a replay payload.
    fs.writeFileSync(jobFileFor(ctx, payload.messageId), JSON.stringify({ ...job, completionText: null }));
    const noText = await runHelperAsync(env, payload);
    assert.equal(noText.note, "unknown_unresolved");
    assert.equal(noText.sessionStoreCheck, "unreadable");
    assert.equal(readJob(ctx, payload.messageId).bridgeStatus, "unknown");
    assert.equal(posts, 1);
    fs.writeFileSync(jobFileFor(ctx, payload.messageId), JSON.stringify(job));

    // Only the exact later result, with the app's real prefix, confirms it.
    fs.appendFileSync(storePath, `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] ${job.completionText}` })}\n`);
    const settled = await runHelperAsync(env, payload);
    assert.equal(settled.note, "unknown_confirmed_delivered");
    assert.equal(readJob(ctx, payload.messageId).completionText, null);
    assert.equal(posts, 1);
    assert.equal(markerLines(marker).length, 1, "delivery settlement never reruns the worker");
  } finally {
    await bridge.close();
  }
});

for (const scenario of [
  { name: "nonzero", body: 'echo "partial failure evidence"; exit 7', status: "failed", reason: "claude_exit_7", evidence: /partial failure evidence/ },
  { name: "aborted", body: 'echo "partial interrupted evidence"; kill -TERM $$', status: "failed", reason: "claude_exit_null", evidence: /partial interrupted evidence/ },
  // runs:2 — a timed-out run spends its ONE automatic re-arm inside the same
  // wake (see the re-arm block in performWake). The point of this test is
  // still that DELIVERY reconciliation never reruns the worker: the count is
  // taken once and must not move across the three duplicate arrivals below.
  { name: "timeout", runs: 2, body: 'echo "partial timed out evidence"; sleep 20', status: "failed", reason: "timeout_after_1s", evidence: /partial timed out evidence/, env: { NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "1" } },
  { name: "empty", body: 'exit 0', status: "completed_without_reply", reason: "empty_stdout", evidence: /produced NO output/ },
]) {
  test(`unknown delivery retains and reconciles ${scenario.name} result without rerunning work`, async () => {
    const ctx = makeRoot(`terminal-${scenario.name}`);
    fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "terminal", `echo "ran" >> "${marker}"\n${scenario.body}`);
    const payload = payloadFor({ messageId: `terminal-${scenario.name}`, sessionId: "SESS-TERMINAL" });
    let posts = 0;
    // The parallel gate can exhaust 400 ms before the server receives the POST.
    // Lose the acknowledgment only AFTER receipt so this reconciliation fixture
    // proves one accepted delivery without racing the socket timeout. The separate
    // reply-timeout test above still exercises the actual 400 ms timeout path.
    const bridge = await startHangingBridge(() => { posts += 1; }, { disconnectAfterBody: true });
    try {
      const env = unknownEnv(ctx, bin, bridge.url, {
        ...scenario.env,
        NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_TIMEOUT_MS: "0",
      });
      const first = await runHelperAsync(env, payload);
      assert.equal(first.status, scenario.status);
      assert.equal(first.reason, scenario.reason);
      assert.equal(first.bridge.status, "unknown");
      assert.equal(first.deliveryLost, false);
      const retained = readJob(ctx, payload.messageId);
      assert.equal(retained.status, scenario.status);
      assert.match(retained.completionText, scenario.evidence);
      assert.ok(retained.startedAt, "execution has been admitted; result replay must not rerun it");

      const runsAfterWake = markerLines(marker).length;
      assert.equal(runsAfterWake, scenario.runs || 1);
      const unresolved = await runHelperAsync(env, payload);
      assert.equal(unresolved.note, "unknown_unresolved");
      assert.equal(posts, 1);
      assert.equal(markerLines(marker).length, runsAfterWake, "a duplicate never reruns the worker");
      assert.equal(readJob(ctx, payload.messageId).completionText, retained.completionText);

      fs.mkdirSync(storeDirFor(ctx), { recursive: true });
      fs.writeFileSync(path.join(storeDirFor(ctx), "SESS-TERMINAL.jsonl"),
        `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] ${retained.completionText}` })}\n`);
      const settled = await runHelperAsync(env, payload);
      assert.equal(settled.note, "unknown_confirmed_delivered");
      assert.equal(readJob(ctx, payload.messageId).completionText, null);
      assert.equal(readJob(ctx, payload.messageId).status, scenario.status, "delivery cannot rewrite execution status");
      assert.equal(posts, 1);
      assert.equal(markerLines(marker).length, scenario.runs || 1);
    } finally {
      await bridge.close();
    }
  });
}

test("known-unsent failed result redelivers exact evidence without repeating execution", () => {
  const ctx = makeRoot("failed-result-replay");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "failed", `echo "ran" >> "${marker}"\necho "partial evidence"; exit 7`);
  const payload = payloadFor({ messageId: "failed-result-replay", sessionId: "SESS-FAILED" });
  // No token: proof the result POST could not have been sent.
  const first = runHelper(baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_DRY_RUN: "0" }), payload);
  assert.equal(first.status, "failed");
  assert.equal(first.bridge.reason, "bridge_token_missing");
  assert.equal(first.deliveryLost, true);
  const retained = readJob(ctx, payload.messageId);
  assert.match(retained.completionText, /partial evidence/);
  const replay = runHelper(baseEnv(ctx, bin), payload);
  assert.equal(replay.status, "redelivered");
  assert.equal(replay.wouldSendText, retained.completionText);
  assert.equal(readJob(ctx, payload.messageId).status, "failed");
  assert.equal(readJob(ctx, payload.messageId).completionText, null);
  assert.equal(markerLines(marker).length, 1);
});

test("a reply timeout with the receipt in her session store settles as DELIVERED", async () => {
  const ctx = makeRoot("unknown-present");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", 'echo "confirmed answer"');
  // The bridge enqueued the row before its turn stalled: the exact text is in the
  // store even though the HTTP response never comes back.
  fs.mkdirSync(storeDirFor(ctx), { recursive: true });
  const bridge = await startHangingBridge((body) => {
    fs.writeFileSync(
      path.join(storeDirFor(ctx), "SESS-B.jsonl"),
      `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] ${body.text}` })}\n`
    );
  });
  try {
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-2", sessionId: "SESS-B" })
    );
    assert.equal(result.status, "completed");
    assert.equal(result.bridge.status, "delivered");
    assert.equal(result.bridge.reason, "confirmed_by_session_store");
    assert.equal(result.deliveryLost, false);
    assert.equal(result.sessionStoreCheck, "present");

    const job = readJob(ctx, "unknown-2");
    assert.equal(job.bridgeStatus, "delivered");
    assert.equal(job.completionText, null);

    // Settled-delivered: a duplicate is a plain duplicate, no settle machinery.
    const dup = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-2", sessionId: "SESS-B" })
    );
    assert.equal(dup.status, "skipped");
    assert.equal(dup.reason, "duplicate");
    assert.equal(dup.note, null);
  } finally {
    await bridge.close();
  }
});

test("a reply timeout with a READABLE store missing the receipt is lost — and replays", async () => {
  const ctx = makeRoot("unknown-absent");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "stranded answer"`);
  // Store readable, marker absent: the orthogonal observer PROVES the message
  // never reached her — this, not the timeout, is what arms the replay.
  fs.mkdirSync(storeDirFor(ctx), { recursive: true });
  fs.writeFileSync(path.join(storeDirFor(ctx), "SESS-C.jsonl"), `${JSON.stringify({ content: "unrelated row" })}\n`);
  const hanging = await startHangingBridge();
  const received = [];
  const working = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      received.push(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
    });
  });
  await new Promise((resolve) => working.listen(0, "127.0.0.1", resolve));
  try {
    // At POST time an "absent" read races the append the exchange may have
    // started: the job stays UNKNOWN, nothing armed (gpt-5.5 2026-07-25).
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, hanging.url),
      payloadFor({ messageId: "unknown-3", sessionId: "SESS-C" })
    );
    assert.equal(result.status, "completed");
    assert.equal(result.bridge.status, "unknown");
    assert.equal(result.deliveryLost, false);
    assert.equal(result.sessionStoreCheck, "absent");
    assert.ok(readJob(ctx, "unknown-3").completionText);
    assert.equal(readJob(ctx, "unknown-3").deliveryLost, false);

    // A duplicate INSIDE the grace window still refuses to arm.
    const early = await runHelperAsync(
      unknownEnv(ctx, bin, hanging.url),
      payloadFor({ messageId: "unknown-3", sessionId: "SESS-C" })
    );
    assert.equal(early.status, "skipped");
    assert.equal(early.note, "unknown_absent_within_grace");
    assert.equal(received.length, 0);

    // Once the absence has PERSISTED past the grace, the loss is store-proven
    // and the next arrival arms + replays the stranded reply.
    const workingUrl = `http://127.0.0.1:${working.address().port}/claude/message`;
    const replayed = await runHelperAsync(
      unknownEnv(ctx, bin, workingUrl, { NATIVE_AGENT_CLAUDE_WAKE_ABSENT_GRACE_MS: "0" }),
      payloadFor({ messageId: "unknown-3", sessionId: "SESS-C" })
    );
    assert.equal(replayed.status, "redelivered");
    assert.equal(received.length, 1);
    assert.match(received[0].text, /stranded answer/);
    assert.equal(markerLines(marker).length, 1, "replay never re-runs claude");
    assert.equal(readJob(ctx, "unknown-3").deliveryLost, false);
  } finally {
    await hanging.close();
    await new Promise((resolve) => working.close(resolve));
  }
});

test("a settled UNKNOWN job is settled late once the store row appears", async () => {
  const ctx = makeRoot("unknown-late");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "late-settled answer"`);
  const bridge = await startHangingBridge();
  try {
    // Store unreadable at settle time -> unknown.
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-4", sessionId: "SESS-D" })
    );
    assert.equal(result.bridge.status, "unknown");
    assert.equal(readJob(ctx, "unknown-4").bridgeStatus, "unknown");

    // The row lands (Agent's turn finished; the store now carries the marker).
    fs.mkdirSync(storeDirFor(ctx), { recursive: true });
    fs.writeFileSync(
      path.join(storeDirFor(ctx), "SESS-D.jsonl"),
      `${JSON.stringify({ role: "user", content: readJob(ctx, "unknown-4").completionText })}\n`
    );

    const settled = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-4", sessionId: "SESS-D" })
    );
    assert.equal(settled.status, "skipped");
    assert.equal(settled.reason, "duplicate");
    assert.equal(settled.note, "unknown_confirmed_delivered");

    const job = readJob(ctx, "unknown-4");
    assert.equal(job.bridgeStatus, "delivered");
    assert.equal(job.bridgeReason, "confirmed_by_session_store");
    assert.equal(job.deliveryLost, false);
    assert.equal(job.completionText, null);
    assert.equal(markerLines(marker).length, 1, "late settle never re-runs claude");
    assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 0);
  } finally {
    await bridge.close();
  }
});

test("a reply timeout on the REPLAY sends the job back to unknown, not to lost", async () => {
  const ctx = makeRoot("replay-timeout");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "twice-stranded answer"`);
  const storePath = path.join(storeDirFor(ctx), "SESS-E.jsonl");
  const bridge = await startHangingBridge();
  try {
    // First wake: POST times out, store readable + absent -> stays unknown.
    fs.mkdirSync(storeDirFor(ctx), { recursive: true });
    fs.writeFileSync(storePath, `${JSON.stringify({ content: "unrelated row" })}\n`);
    const first = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-5", sessionId: "SESS-E" })
    );
    assert.equal(first.deliveryLost, false);
    assert.equal(first.bridge.status, "unknown");

    // Grace elapsed (0 for the test): the persisted absence arms and the
    // REPLAY fires — but ITS POST also times out. That replay must not write
    // deliveryLost:true about its own timeout: back to unknown.
    const replay = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url, { NATIVE_AGENT_CLAUDE_WAKE_ABSENT_GRACE_MS: "0" }),
      payloadFor({ messageId: "unknown-5", sessionId: "SESS-E" })
    );
    assert.equal(replay.status, "unknown");
    assert.equal(replay.deliveryLost, false);
    assert.equal(replay.sessionStoreCheck, "absent");

    const job = readJob(ctx, "unknown-5");
    assert.equal(job.bridgeStatus, "unknown");
    assert.equal(job.deliveryLost, false);
    assert.ok(job.completionText, "the answer is kept for a later settle");

    // Next arrival inside the (restored) grace window: no blind re-post.
    const dup = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "unknown-5", sessionId: "SESS-E" })
    );
    assert.equal(dup.status, "skipped");
    assert.equal(dup.note, "unknown_absent_within_grace");
    assert.equal(markerLines(marker).length, 1);
  } finally {
    await bridge.close();
  }
});

test("the replay re-reads the store under its lock and refuses to double-deliver", async () => {
  const ctx = makeRoot("replay-store-race");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", 'echo "landed late"');
  const storePath = path.join(storeDirFor(ctx), "SESS-F.jsonl");
  const hanging = await startHangingBridge();
  const received = [];
  const working = http.createServer((req, res) => {
    req.on("data", () => {});
    req.on("end", () => {
      received.push(req.url);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
    });
  });
  await new Promise((resolve) => working.listen(0, "127.0.0.1", resolve));
  try {
    // First wake: unknown, text kept. Then hand-arm the job exactly as a
    // post-grace settle would (deliveryLost:true on a stale "absent") — the
    // shape the 2026-07-25 incident left on disk.
    fs.mkdirSync(storeDirFor(ctx), { recursive: true });
    fs.writeFileSync(storePath, `${JSON.stringify({ content: "unrelated row" })}\n`);
    const first = await runHelperAsync(
      unknownEnv(ctx, bin, hanging.url),
      payloadFor({ messageId: "unknown-6", sessionId: "SESS-F" })
    );
    assert.equal(first.bridge.status, "unknown");
    const armedJob = readJob(ctx, "unknown-6");
    armedJob.deliveryLost = true;
    armedJob.bridgeStatus = "failed";
    armedJob.bridgeReason = "absent_from_session_store";
    fs.writeFileSync(jobFileFor(ctx, "unknown-6"), JSON.stringify(armedJob, null, 2));

    // …then the row lands (the original POST had been received after all).
    fs.appendFileSync(
      storePath,
      `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] ${armedJob.completionText}` })}\n`
    );

    // The replay must catch it under the lock and never POST.
    const workingUrl = `http://127.0.0.1:${working.address().port}/claude/message`;
    const settled = await runHelperAsync(
      unknownEnv(ctx, bin, workingUrl),
      payloadFor({ messageId: "unknown-6", sessionId: "SESS-F" })
    );
    assert.equal(settled.status, "skipped");
    assert.equal(settled.note, "unknown_confirmed_delivered");
    assert.equal(received.length, 0, "no POST for a completion the store proves delivered");

    const job = readJob(ctx, "unknown-6");
    assert.equal(job.bridgeStatus, "delivered");
    assert.equal(job.deliveryLost, false);
    assert.equal(job.completionText, null);
  } finally {
    await hanging.close();
    await new Promise((resolve) => working.close(resolve));
  }
});

// ------------------------------------------- ack-on-enqueue (Defect 1, 2026-07-25)

/// Minimal live bridge that answers every POST immediately with `body`,
/// recording each request's parsed JSON. This is the ack-on-enqueue shape:
/// the response arrives at durable-append time, decoupled from any turn.
function startRespondingBridge(status, body) {
  return new Promise((resolve) => {
    const requests = [];
    const server = http.createServer((req, res) => {
      let raw = "";
      req.on("data", (chunk) => { raw += chunk; });
      req.on("end", () => {
        try { requests.push(JSON.parse(raw)); } catch { requests.push(null); }
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(body));
      });
    });
    server.listen(0, "127.0.0.1", () => {
      resolve({
        url: `http://127.0.0.1:${server.address().port}/claude/message`,
        requests,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

test("an enqueue-acked bridge reply is DELIVERED in seconds, with ackMode enqueued", async () => {
  const ctx = makeRoot("enqueue-ack");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "long turn answer"`);
  const bridge = await startRespondingBridge(200, {
    status: "ok",
    ack: "enqueued",
    sessionId: "SESS-ENQ",
  });
  try {
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "enq-1", sessionId: "SESS-ENQ" })
    );
    assert.equal(result.status, "completed");
    assert.equal(result.bridge.status, "delivered");
    assert.equal(result.bridge.ackMode, "enqueued");
    assert.equal(result.deliveryLost, false);
    // The helper ASKS for the enqueue ack on every completion POST.
    assert.equal(bridge.requests.length, 1);
    assert.equal(bridge.requests[0].ackMode, "enqueue");
    const job = readJob(ctx, "enq-1");
    assert.equal(job.state, "settled");
    assert.equal(job.deliveryLost, false);
    assert.equal(job.completionText, null);
  } finally {
    await bridge.close();
  }
});

test("a 5xx enqueue_failed reply is UNKNOWN, not failed — append may have landed", async () => {
  const ctx = makeRoot("enqueue-500");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", `echo "answer"`);
  const bridge = await startRespondingBridge(500, { status: "enqueue_failed" });
  try {
    const result = await runHelperAsync(
      unknownEnv(ctx, bin, bridge.url),
      payloadFor({ messageId: "enq-500", sessionId: "SESS-B" })
    );
    assert.equal(result.status, "completed");
    // Store is absent in this ctx -> unreadable -> stays unknown. Never a
    // transport-asserted loss, never replay-eligible.
    assert.equal(result.bridge.status, "unknown");
    assert.equal(result.deliveryLost, false);
    assert.equal(result.sessionStoreCheck, "unreadable");
    const job = readJob(ctx, "enq-500");
    assert.equal(job.bridgeStatus, "unknown");
    assert.equal(job.deliveryLost, false);
    assert.ok(job.completionText, "unknown keeps the text for a later store-settle");
  } finally {
    await bridge.close();
  }
});

// ------------------- pre-disarm fixture regressions (Agent acceptance #5)
//
// These two job files are PII-scrubbed copies of the LIVE jobs the 2026-07-25
// incident armed for replay: completed wakes whose bridge POST timed out
// (because the response was coupled to Agent's turn), classified
// deliveryLost:true with completionText stored — a duplicate delivery armed
// for messages she had demonstrably received. Under the pre-disarm logic a
// duplicate arrival re-POSTed the stored text. Under current logic the store
// is consulted under the replay lock and the replay is refused.

const FIXTURES_DIR = path.join(__dirname, "fixtures", "wake-delivery-classification");

for (const fixtureName of ["armed-replay-99D377A5.fixture.json", "armed-replay-7253CCEC.fixture.json"]) {
  test(`fixture ${fixtureName}: armed replay of a delivered completion is REFUSED`, async () => {
    const fixture = JSON.parse(fs.readFileSync(path.join(FIXTURES_DIR, fixtureName), "utf8"));
    // The incident copies predate the key rename and are kept as they landed.
    fixture.agentSessionId = fixture.agentSessionId || fixture.agentSessionId;
    assert.equal(fixture.deliveryLost, true, "fixture must arrive armed");
    assert.ok(fixture.completionText, "fixture must carry the stored completion");

    const ctx = makeRoot("fixture-replay");
    fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
    const bin = fakeClaude(ctx.root, "never", `echo "must not run"`);
    // The job lands exactly as the incident left it.
    fs.mkdirSync(path.join(ctx.bridgeDir, "wake-jobs"), { recursive: true, mode: 0o700 });
    fs.writeFileSync(jobFileFor(ctx, fixture.messageId), JSON.stringify(fixture, null, 2), { mode: 0o600 });
    // Her session store HAS the completion row — the incident's ground truth:
    // the message was delivered; only the HTTP response was lost.
    fs.mkdirSync(storeDirFor(ctx), { recursive: true });
    fs.writeFileSync(
      path.join(storeDirFor(ctx), `${fixture.agentSessionId}.jsonl`),
      `${JSON.stringify({ role: "user", sessionId: fixture.agentSessionId, content: fixture.completionText })}\n`
    );
    // Live bridge counting POSTs: the regression is exactly "this counter
    // stays at zero" (pre-disarm logic re-POSTed the stored text here).
    const bridge = await startRespondingBridge(200, { status: "ok", ack: "enqueued" });
    try {
      const result = await runHelperAsync(
        unknownEnv(ctx, bin, bridge.url),
        payloadFor({ messageId: fixture.messageId, sessionId: fixture.agentSessionId })
      );
      assert.equal(bridge.requests.length, 0, "an armed-but-delivered replay must never re-POST");
      assert.equal(result.status, "skipped");
      assert.equal(result.reason, "duplicate");
      assert.equal(result.note, "unknown_confirmed_delivered");
      assert.equal(result.deliveryLost, false);
      const job = readJob(ctx, fixture.messageId);
      assert.equal(job.deliveryLost, false, "the armed replay must be disarmed on disk");
      assert.equal(job.completionText, null);
      assert.equal(job.bridgeStatus, "delivered");
      assert.equal(job.bridgeReason, "confirmed_by_session_store");
    } finally {
      await bridge.close();
    }
  });
}

// --- Stall watchdog + long ceiling -----------------------------------------
//
// The false-pass trap these guard against: a stall detector that never fires
// (keyed on the runner's own heartbeat, which beats regardless of the child)
// and one that fires unconditionally (keyed on stdout, which stays empty for
// the whole run) are both indistinguishable from a working one unless the
// tests prove BOTH directions with a real process.

test("stall watchdog KILLS a wedged child and the process is provably dead", async () => {
  const ctx = makeRoot("stall-kill");
  const marker = path.join(ctx.root, "stall.pid");
  const transcript = path.join(ctx.root, "stall-transcript.jsonl");
  // Writes one canonical row and then goes silent: the exact shape of a wedged
  // session. The ceiling is
  // set far above the stall window so a pass here can ONLY come from the stall
  // watchdog, never from the deadline timer.
  // `exec` matters: without it the shell's child would inherit the stdout pipe
  // and hold it open past the kill, so the runner could not settle. exec keeps
  // ONE pid (preserved across exec, so $$ is the pid that must die).
  const bin = fakeClaude(ctx.root, "wedged", `echo $$ > ${marker}\necho '{}' > ${transcript}\nexec sleep 300\n`);
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_TRANSCRIPT_PATH: transcript,
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SECONDS: "2",
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SAMPLE_MS: "250",
    NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "120",
  });
  const payload = payloadFor({ topic: "stall kill" });

  const started = Date.now();
  const result = await runHelperAsync(env, payload, { timeoutMs: 60_000 });
  const elapsedMs = Date.now() - started;

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "stalled_after_2s", `expected a stall verdict, got ${result.reason}`);
  // Killed by the STALL window, not by the 120s ceiling.
  assert.ok(elapsedMs < 60_000, `stall kill took ${elapsedMs}ms — that is the ceiling firing, not the watchdog`);

  // The point of the test: a field saying "failed" proves nothing. The process
  // itself must be gone.
  const pid = Number(fs.readFileSync(marker, "utf8").trim());
  assert.ok(Number.isFinite(pid) && pid > 0, "fake claude never recorded its pid");
  let alive = true;
  try { process.kill(pid, 0); } catch { alive = false; }
  assert.equal(alive, false, `pid ${pid} is STILL ALIVE — the job record lied about killing it`);

  const job = readJob(ctx, payload.messageId);
  assert.equal(job.state, "settled");
  assert.equal(job.status, "failed");
  assert.equal(job.reason, "stalled_after_2s");
  assert.equal(job.stallSeconds, 2, "the stall threshold must be legible on the job record");
});

test("CONTROL: a busy child survives well past the stall window (detector is not unconditional)", async () => {
  const ctx = makeRoot("stall-control");
  const transcript = path.join(ctx.root, "busy-transcript.jsonl");
  // This process burns essentially no CPU and keeps stdout empty until exit,
  // but appends canonical transcript movement for ~7s — more than 2x the 3s
  // stall window. This is the production shape the CPU watchdog killed.
  const bin = fakeClaude(
    ctx.root,
    "busy",
    `: > ${transcript}\ni=0\nwhile [ "$i" -lt 7 ]; do echo '{}' >> ${transcript}; sleep 1; i=$((i + 1)); done\necho "the real reply"\n`
  );
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_TRANSCRIPT_PATH: transcript,
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SECONDS: "3",
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SAMPLE_MS: "250",
    NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "120",
  });
  const payload = payloadFor({ topic: "stall control" });

  const result = await runHelperAsync(env, payload, { timeoutMs: 60_000 });

  assert.equal(result.status, "completed", `busy job was killed: reason=${result.reason}`);
  assert.ok(result.replyChars > 0, "the busy job's reply was lost");
  assert.match(result.wouldSendText || "", /the real reply/);

  // And its liveness was actually observed, not merely assumed: progressAt is
  // the transcript's clock, distinct from the runner's heartbeatAt.
  const job = readJob(ctx, payload.messageId);
  assert.ok(job.progressAt, "no progressAt was ever stamped — the watchdog never saw the child work");
  assert.equal(job.progressSource, "claude_transcript");
  assert.ok(job.progressTranscriptBytes > 0);
  assert.equal(job.progressCpuMs, null, "CPU must not remain a liveness input or receipt");
});

test("the hard ceiling is generous, and the stall window is far below it", () => {
  // The old fixed 900s ceiling SIGTERM'd real sessions mid-run. A job that
  // keeps working now gets an hour.
  assert.equal(wakeup.resolveTimeoutSeconds({}), 3600);
  assert.ok(wakeup.resolveTimeoutSeconds({}) > 900, "ceiling must exceed the old 900s deadline");
  // A wedged job still dies in minutes, not in an hour.
  assert.equal(wakeup.resolveStallSeconds({}), 600);
  assert.ok(wakeup.resolveStallSeconds({}) < wakeup.resolveTimeoutSeconds({}) / 2);
  // Still overridable per-message, and explicitly disableable.
  assert.equal(wakeup.resolveStallSeconds({ stallSeconds: 30 }), 30);
  assert.equal(wakeup.resolveStallSeconds({ stallSeconds: 0 }), 0);
});

test("deadlineAt is anchored to CLAIM time, not enqueue time", async () => {
  const ctx = makeRoot("deadline-anchor");
  // A deliberate enqueue->claim gap: the second wake is created immediately but
  // cannot start until the first releases the topic lock ~4s later. An
  // implementation that anchors deadlineAt to createdAt is off by that gap —
  // which is exactly the arithmetic that produced a withdrawn "stuck job"
  // finding.
  const slow = fakeClaude(ctx.root, "slow", "sleep 4\necho first\n");
  const quick = fakeClaude(ctx.root, "quick", "echo second\n");
  const topic = "anchor topic";

  const firstPayload = payloadFor({ topic });
  const secondPayload = payloadFor({ topic });

  const firstDone = runHelperAsync(
    baseEnv(ctx, slow, { NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "120" }),
    firstPayload,
    { timeoutMs: 60_000 }
  );
  // Let the first genuinely own the lock before the second is enqueued.
  await sleep(500);
  const secondDone = runHelperAsync(
    baseEnv(ctx, quick, {
      NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "120",
      NATIVE_AGENT_CLAUDE_WAKE_LOCK_WAIT_MS: "30000",
    }),
    secondPayload,
    { timeoutMs: 60_000 }
  );

  await firstDone;
  await secondDone;

  const job = readJob(ctx, secondPayload.messageId);
  const createdMs = Date.parse(job.createdAt);
  const startedMs = Date.parse(job.startedAt);
  const deadlineMs = Date.parse(job.deadlineAt);

  // The gap must be real, or this test proves nothing.
  assert.ok(
    startedMs - createdMs > 1500,
    `no meaningful enqueue->claim gap (${startedMs - createdMs}ms); the anchor cannot be distinguished`
  );
  // Anchored to the claim, exactly.
  assert.equal(deadlineMs - startedMs, 120_000, "deadlineAt is not startedAt + timeoutSeconds");
  // And provably NOT anchored to enqueue.
  assert.notEqual(deadlineMs - createdMs, 120_000);
  assert.ok(job.claimedAt, "claimedAt must be on the record for an observer to read");
});

test("stall kill reaps DESCENDANTS that inherited the stdout pipe (runner still settles)", async () => {
  const ctx = makeRoot("stall-descendant");
  const parentMarker = path.join(ctx.root, "parent.pid");
  const childMarker = path.join(ctx.root, "child.pid");
  const transcript = path.join(ctx.root, "descendant-transcript.jsonl");
  // NO `exec` here, and the background descendant inherits stdout. If the
  // watchdog killed only the direct child, the descendant would hold the pipe
  // open, node's 'close' would never fire, and the runner would hang forever
  // on a process it had already killed — the "hung to SIGTERM" shape.
  const bin = fakeClaude(
    ctx.root,
    "leaky",
    `echo $$ > ${parentMarker}\necho '{}' > ${transcript}\nsh -c 'echo $$ > ${childMarker}; sleep 300' &\nsleep 300\n`
  );
  const env = baseEnv(ctx, bin, {
    NATIVE_AGENT_CLAUDE_WAKE_TRANSCRIPT_PATH: transcript,
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SECONDS: "2",
    NATIVE_AGENT_CLAUDE_WAKE_STALL_SAMPLE_MS: "250",
    NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "120",
  });
  const payload = payloadFor({ topic: "stall descendant" });

  const started = Date.now();
  // The whole point: this RESOLVES. A hang here is the defect.
  const result = await runHelperAsync(env, payload, { timeoutMs: 45_000 });
  const elapsedMs = Date.now() - started;

  assert.equal(result.status, "failed");
  assert.equal(result.reason, "stalled_after_2s");
  assert.ok(elapsedMs < 30_000, `runner took ${elapsedMs}ms to settle — the pipe was held open`);

  // Both processes must actually be gone, not just the one node had a handle on.
  await sleep(500);
  for (const [label, file] of [["parent", parentMarker], ["descendant", childMarker]]) {
    const pid = Number(fs.readFileSync(file, "utf8").trim());
    let alive = true;
    try { process.kill(pid, 0); } catch { alive = false; }
    assert.equal(alive, false, `${label} pid ${pid} survived the stall kill`);
  }
});

// --- Commit hold (task #49, 2026-07-25) ---------------------------------

const RELEASE_HELPER = path.join(__dirname, "..", "wake_hold_release.js");

test("paired builder review reaches Claude prompt and stays absent from ordinary messages", () => {
  const paired = wakeup.sanitizePayload({
    messageId: "paired-review-1",
    topic: "paired-review",
    text: "build the change",
    pairReviewer: true,
    deskHandle: "desk_abc-123",
  });
  const pairedPrompt = wakeup.formatPrompt(paired, "/tmp/wake-jobs/paired-review-1.json");
  assert.equal(paired.pairReviewer, true);
  assert.equal(paired.deskHandle, "desk_abc-123");
  assert.match(pairedPrompt, /pair exactly one reviewer/i);
  assert.match(pairedPrompt, /exact committed SHA/i);
  assert.match(pairedPrompt, /Findings return to you/i);
  assert.match(pairedPrompt, /same reviewer inspect the resulting SHA/i);

  const ordinary = wakeup.sanitizePayload({
    messageId: "ordinary-1",
    topic: "ordinary",
    text: "answer a question",
    pairReviewer: false,
  });
  assert.equal(ordinary.pairReviewer, undefined);
  assert.doesNotMatch(
    wakeup.formatPrompt(ordinary, "/tmp/wake-jobs/ordinary-1.json"),
    /PAIRED REVIEW/
  );
});

test("ordinary Claude wake follows the current brief without forced swarms or reviewer models", () => {
  const brief = "Implement this small fix yourself. No delegated workers or review pass. Build the complete change, then validate once.";
  const prompt = wakeup.formatPrompt({ messageId: "scoped-brief", topic: "small-fix", text: brief });
  assert.ok(prompt.includes(brief));
  assert.match(prompt, /current delegated brief and applicable current AGENTS\.md/);
  assert.match(prompt, /latest user-requested scope and workflow govern/);
  assert.match(prompt, /bridge adds no authority to create extra workers/);
  assert.match(prompt, /You own the result and integration/);
  assert.doesNotMatch(prompt, /dispatch swarm workers for build-sized tasks/);
  assert.doesNotMatch(prompt, /every implementation diff through gpt-5\.5 review/);
  assert.doesNotMatch(prompt, /sonnet-swarm and gpt-swarm MCPs are available/);
  assert.doesNotMatch(prompt, /PAIRED REVIEW/);
});

test("Claude wake preserves a reviewer model explicitly selected in the accepted brief", () => {
  const brief = "Use exactly one gpt-5.5 reviewer after this authorized change.";
  const prompt = wakeup.formatPrompt({ messageId: "explicit-review", text: brief, pairReviewer: true });
  assert.ok(prompt.includes(brief));
  assert.match(prompt, /pair exactly one reviewer/i);
  assert.match(prompt, /preserving any explicitly requested worker count and model/);
});

for (const [label, messageId] of [["ascii", "a".repeat(160)], ["emoji", "🍎".repeat(160)], ["combining", "e\u0301".repeat(160)]]) {
  test(`accepted Claude ${label} message identity survives admission and completion`, () => {
    const ctx = makeRoot(`exact-id-${label}`);
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho 'identity evidence'`);
    // Mirrors the ID returned by Swift's accepted receipt (160 Characters).
    const acceptedReceipt = { messageId };
    const payload = payloadFor({ messageId: acceptedReceipt.messageId });
    assert.equal(wakeup.sanitizePayload(payload).messageId, acceptedReceipt.messageId);
    const env = baseEnv(ctx, bin);
    const result = runHelper(env, payload);
    assert.equal(result.status, "completed");
    assert.equal(result.messageId, acceptedReceipt.messageId);
    const job = JSON.parse(fs.readFileSync(result.jobPath, "utf8"));
    assert.equal(job.messageId, acceptedReceipt.messageId);
    assert.equal(job.payload.messageId, acceptedReceipt.messageId);
    assert.ok(result.wouldSendText.includes(wakeup.deliveryMarker(acceptedReceipt.messageId)));
    assert.equal(receipts(ctx).at(-1).messageId, acceptedReceipt.messageId);
    const duplicate = runHelper(env, payload);
    assert.equal(duplicate.reason, "duplicate");
    assert.equal(duplicate.messageId, acceptedReceipt.messageId);
    assert.equal(markerLines(marker).length, 1);
  });
}

for (const messageId of ["a".repeat(161), "🍎".repeat(161), "e\u0301".repeat(161)]) {
  test(`oversize direct Claude message ID is rejected rather than rewritten (${messageId.length} units)`, () => {
    const ctx = makeRoot("oversize-id");
    const marker = path.join(ctx.root, "invocations.txt");
    const bin = fakeClaude(ctx.root, "never", `echo ran >> "${marker}"`);
    const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId }));
    assert.equal(result.reason, "message_id_too_long");
    assert.equal(result.messageId, undefined);
    assert.deepEqual(markerLines(marker), []);
    assert.equal(fs.existsSync(path.join(ctx.bridgeDir, "wake-jobs")), false);
  });
}

test("legacy truncated Claude identity refuses execution and delivery replay without rewriting its job", () => {
  const ctx = makeRoot("legacy-id-ambiguity");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "never", `echo ran >> "${marker}"`);
  const messageId = "🍎".repeat(100);
  const legacyId = messageId.slice(0, 160);
  const legacyName = legacyId.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120);
  assert.equal(messageId.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120), legacyName);
  const jobs = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobs, { recursive: true });
  const jobPath = path.join(jobs, `${legacyName}.json`);
  const original = JSON.stringify({
    schemaVersion: 2, messageId: legacyId, claimId: "legacy-claim", state: "settled", status: "completed",
    bridgeStatus: "failed", deliveryLost: true, completionText: "retained legacy result",
    payload: payloadFor({ messageId: legacyId }),
  });
  fs.writeFileSync(jobPath, original);
  const result = runHelper(baseEnv(ctx, bin), payloadFor({ messageId }));
  assert.equal(result.reason, "legacy_message_id_ambiguous");
  assert.equal(result.messageId, messageId);
  assert.equal(result.executionOutcome, "unknown");
  assert.match(result.guidance, /Inspect that job/);
  assert.deepEqual(markerLines(marker), []);
  assert.deepEqual(receipts(ctx), []);
  assert.equal(fs.readFileSync(jobPath, "utf8"), original);
  assert.deepEqual(fs.readdirSync(jobs), [`${legacyName}.json`]);
});

test("delegation producer identity survives Claude payload sanitization", () => {
  const revision = "1234567890abcdef1234567890abcdef12345678";
  const clean = wakeup.sanitizePayload({
    messageId: "producer-stamp",
    text: "do the bounded work",
    producerSchemaVersion: 1,
    producerSourceRevision: revision.toUpperCase(),
  });
  assert.equal(clean.producerSchemaVersion, 1);
  assert.equal(clean.producerSourceRevision, revision);

  const invalid = wakeup.sanitizePayload({
    messageId: "invalid-producer-stamp",
    text: "do the bounded work",
    producerSchemaVersion: 0,
    producerSourceRevision: "not-a-revision",
  });
  assert.equal(invalid.producerSchemaVersion, undefined);
  assert.equal(invalid.producerSourceRevision, undefined);
});

function runRelease(bridgeDir, args) {
  const result = spawnSync(process.execPath, [RELEASE_HELPER, ...args], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_AGENT_CLAUDE_BRIDGE_DIR: bridgeDir },
    timeout: 15_000,
  });
  let parsed = null;
  try { parsed = JSON.parse(String(result.stdout || "").trim()); } catch {}
  return { status: result.status, out: parsed, stderr: String(result.stderr || "") };
}

test("wake prompt carries the COMMIT HOLD clause with the job record path", () => {
  const prompt = wakeup.formatPrompt(
    { messageId: "m-hold-1", topic: "hold-topic", text: "verify the thing" },
    "/tmp/wake-jobs/m-hold-1.json"
  );
  assert.match(prompt, /COMMIT HOLD/);
  assert.match(prompt, /do NOT `git commit` or `git push`/);
  // Authority is the runner-untouchable SIDECAR, not the job record.
  assert.match(prompt, /\/tmp\/wake-releases\/m-hold-1\.json/);
  assert.match(prompt, /informational mirrors, not authority/);
  // Release authority is named and explicitly excludes the wake session.
  assert.match(prompt, /never this session's/);
});

test("wake job record is created held; release script flips it atomically and idempotently", () => {
  const { bridgeDir } = makeRoot("hold-release");
  const jobsDir = path.join(bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true });
  const jobId = "AAAA1111-HOLD-TEST";
  const jobPath = path.join(jobsDir, `${jobId}.json`);
  const releasePath = path.join(bridgeDir, "wake-releases", `${jobId}.json`);
  // Record shaped like claimRecord()'s output (hold fields present-and-null).
  fs.writeFileSync(jobPath, JSON.stringify({
    messageId: jobId, state: "claimed", claimId: "c1",
    commitPolicy: "hold", holdReleasedAt: null, holdReleasedBy: null,
  }, null, 2));

  const released = runRelease(bridgeDir, [jobId, "--by", "agent"]);
  assert.equal(released.status, 0, released.stderr);
  assert.equal(released.out.status, "released");
  assert.equal(released.out.holdReleasedBy, "agent");
  assert.equal(released.out.jobPath, jobPath);
  assert.equal(released.out.releasePath, releasePath);

  // The AUTHORITY is the sidecar: it exists and carries the stamp.
  const sidecar = JSON.parse(fs.readFileSync(releasePath, "utf8"));
  assert.deepEqual(sidecar, {
    holdReleasedAt: released.out.holdReleasedAt,
    holdReleasedBy: "agent",
    messageId: jobId,
  });

  // Job record gets the best-effort mirror; untouched fields survive.
  const onDisk = JSON.parse(fs.readFileSync(jobPath, "utf8"));
  assert.equal(onDisk.commitPolicy, "released");
  assert.equal(onDisk.claimId, "c1");
  assert.equal(onDisk.holdReleasedAt, sidecar.holdReleasedAt);
  assert.equal(onDisk.holdReleasedBy, sidecar.holdReleasedBy);
  assert.equal(onDisk.updatedAt, sidecar.holdReleasedAt);

  // BLOCKING-fix regression: a racing runner write that resurrects the held
  // job record must NOT un-release — the sidecar survives untouched.
  fs.writeFileSync(jobPath, JSON.stringify({
    messageId: jobId, state: "claimed", claimId: "c1",
    commitPolicy: "hold", holdReleasedAt: null, holdReleasedBy: null,
  }, null, 2));
  assert.deepEqual(JSON.parse(fs.readFileSync(releasePath, "utf8")), sidecar,
    "sidecar authority must survive a stale job-record rewrite unchanged");

  // Idempotent: second release reports the ORIGINAL stamp, changes nothing.
  const again = runRelease(bridgeDir, [`${jobId}.json`, "--by", "user"]);
  assert.equal(again.status, 0);
  assert.equal(again.out.status, "already_released");
  assert.equal(again.out.holdReleasedBy, "agent");
  const sidecarAfter = JSON.parse(fs.readFileSync(releasePath, "utf8"));
  assert.deepEqual(sidecarAfter, sidecar);
});

test("release script fails LOUD on an array-shaped job record (typeof [] === 'object' trap)", () => {
  const { bridgeDir } = makeRoot("hold-release-array");
  const jobsDir = path.join(bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true });
  fs.writeFileSync(path.join(jobsDir, "ARRAY-JOB.json"), "[]");
  const res = runRelease(bridgeDir, ["ARRAY-JOB", "--by", "user"]);
  assert.equal(res.status, 1);
  assert.equal(res.out.reason, "job_malformed");
  assert.ok(!fs.existsSync(path.join(bridgeDir, "wake-releases", "ARRAY-JOB.json")));
});

test("a job created through the REAL runner is born held (claimRecord fields)", () => {
  const ctx = makeRoot("hold-born-held");
  const claudeBin = fakeClaude(ctx.root, "ok", 'echo "hold-born-held done"');
  const messageId = crypto.randomUUID();
  const envelope = runHelper({
    NATIVE_AGENT_CLAUDE_BRIDGE_DIR: ctx.bridgeDir,
    NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_BIN: claudeBin,
    NATIVE_AGENT_CLAUDE_WAKE_BRIDGE_DRY_RUN: "1",
  }, { messageId, text: "verify something", topic: "hold-born-held", cwd: ctx.cwd });
  assert.ok(envelope, "no envelope from runner");
  const jobFile = path.join(ctx.bridgeDir, "wake-jobs", `${messageId}.json`);
  const record = JSON.parse(fs.readFileSync(jobFile, "utf8"));
  assert.equal(record.commitPolicy, "hold");
  assert.equal(record.holdReleasedAt, null);
  assert.equal(record.holdReleasedBy, null);
});

test("release script fails LOUD on unknown job, bad releaser, and path-shaped ids", () => {
  const { bridgeDir } = makeRoot("hold-release-loud");
  const jobsDir = path.join(bridgeDir, "wake-jobs");
  const releasesDir = path.join(bridgeDir, "wake-releases");
  fs.mkdirSync(jobsDir, { recursive: true });
  fs.writeFileSync(path.join(jobsDir, "KNOWN-JOB.json"), JSON.stringify({
    messageId: "KNOWN-JOB", commitPolicy: "hold",
  }));

  const missingId = runRelease(bridgeDir, ["--by", "user"]);
  assert.equal(missingId.status, 1);
  assert.equal(missingId.out.reason, "missing_job_id");

  const missing = runRelease(bridgeDir, ["NO-SUCH-JOB", "--by", "user"]);
  assert.equal(missing.status, 1);
  assert.equal(missing.out.status, "failed");
  assert.equal(missing.out.reason, "job_not_found_or_unreadable");

  const badBy = runRelease(bridgeDir, ["KNOWN-JOB", "--by", "codex"]);
  assert.equal(badBy.status, 1);
  assert.equal(badBy.out.reason, "invalid_releaser");

  const traversal = runRelease(bridgeDir, ["../outside", "--by", "user"]);
  assert.equal(traversal.status, 1);
  assert.equal(traversal.out.reason, "invalid_job_id");
  assert.equal(fs.existsSync(releasesDir), false,
    "no failed invocation may create release authority");
});

// -------------------------------------- transcript watchdog progress (2026-08-29)
test("transcript progress advances on append or replacement and stays quiet when unchanged", () => {
  const p = new wakeup.TranscriptProgress();
  assert.equal(p.observe({ state: "missing" }), null);
  assert.equal(p.observe({ state: "unreadable" }), null);
  assert.equal(p.observe({ state: "present", bytes: 10, mtimeMs: 100 }).advanced, true);
  assert.equal(p.observe({ state: "present", bytes: 10, mtimeMs: 100 }).advanced, false);
  assert.equal(p.observe({ state: "present", bytes: 20, mtimeMs: 101 }).advanced, true);
  // Atomic replacement/truncation is still movement, not regression.
  assert.equal(p.observe({ state: "present", bytes: 5, mtimeMs: 102 }).advanced, true);
});

test("canonical transcript path is cwd- and session-bound", () => {
  const previousRoot = process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_PROJECTS_DIR;
  process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_PROJECTS_DIR = "/tmp/claude-projects";
  try {
    assert.equal(
      wakeup.claudeTranscriptPath("/Users/user/Projects/NativeAgent", "session-1"),
      "/tmp/claude-projects/-Users-user-Projects-NativeAgent/session-1.jsonl"
    );
    assert.equal(wakeup.claudeTranscriptPath("/tmp", "../escape"), null);
  } finally {
    if (previousRoot == null) delete process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_PROJECTS_DIR;
    else process.env.NATIVE_AGENT_CLAUDE_WAKE_CLAUDE_PROJECTS_DIR = previousRoot;
  }
});

// ------------------------------------------- terminal-undelivered recovery (A)
//
// The defect these close: a completed reply the bridge PROVABLY never delivered
// sat on its job file forever, because `replayLostDelivery` only ran when the
// same messageId happened to be re-sent. Nobody re-sends a message they don't
// know was stranded, so 34 of 156 live jobs never got a second chance.
//
// The counter-defect they also close: re-posting anything AMBIGUOUS. An
// `unknown` delivery may already have landed, and a duplicate completion in
// Agent's thread is strictly worse than a stranded one.

function runRecover(env, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HELPER, "--recover"], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const killer = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, options.timeoutMs || 30_000);
    child.on("close", () => {
      clearTimeout(killer);
      let parsed = null;
      try { parsed = JSON.parse(stdout.trim().split("\n").filter(Boolean).pop() || "null"); } catch {}
      if (!parsed) { reject(new Error(`--recover produced no envelope. stdout=${stdout} stderr=${stderr}`)); return; }
      resolve(parsed);
    });
  });
}

/// Write a settled job record straight onto the store, the way a finished
/// runner would have left it.
function writeSettledJob(ctx, messageId, fields) {
  const file = jobFileFor(ctx, messageId);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const job = {
    schemaVersion: 2,
    messageId,
    createdAt: "2026-08-01T00:00:00.000Z",
    completedAt: "2026-08-01T00:10:00.000Z",
    state: "settled",
    status: "completed",
    topicSlug: "recovery",
    payload: { messageId, text: "prior work", topic: "recovery" },
    ...fields,
  };
  fs.writeFileSync(file, JSON.stringify(job, null, 2), { mode: 0o600 });
  return job;
}

test("a PROVEN-undelivered completion re-posts on the next bridge contact, exactly once", async () => {
  const ctx = makeRoot("recovery-repost");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  writeSettledJob(ctx, "stranded-1", {
    bridgeStatus: "failed",
    bridgeReason: "connect ECONNREFUSED 127.0.0.1:8771",
    deliveryLost: false,
    completionText: "stranded terminal evidence",
    agentSessionId: "SESS-RECOVER",
  });
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho "fresh wake answer"`);
  const bridge = await startRespondingBridge(200, { status: "ok", ack: "enqueued" });
  try {
    const env = unknownEnv(ctx, bin, bridge.url);
    // A NORMAL wake. Nothing about it mentions the stranded job — the sweep on
    // its tail is the whole mechanism.
    const wake = await runHelperAsync(env, payloadFor({ messageId: "live-1", sessionId: "SESS-LIVE" }));
    assert.equal(wake.status, "completed");
    assert.equal(wake.bridge.status, "delivered");
    assert.equal(wake.recovery.eligible, 1);
    assert.equal(wake.recovery.results[0].posted, true);

    const texts = bridge.requests.map((r) => r && r.text);
    assert.equal(texts.filter((t) => /stranded terminal evidence/.test(t)).length, 1);
    assert.equal(bridge.requests.find((r) => /stranded terminal evidence/.test(r.text)).sessionId, "SESS-RECOVER");

    const recovered = readJob(ctx, "stranded-1");
    assert.equal(recovered.bridgeStatus, "delivered");
    assert.equal(recovered.deliveryLost, false);
    assert.equal(recovered.completionText, null, "a delivered completion is not kept for a second replay");
    assert.ok(recovered.deliveryRecoveryAt, "the once-only marker must be durable");
    assert.equal(recovered.deliveryRecoveryOutcome, "redelivered");
    assert.equal(receipts(ctx).filter((r) => r.kind === "redelivery").length, 1);

    // The second bridge contact must NOT post it again.
    const again = await runHelperAsync(env, payloadFor({ messageId: "live-2", sessionId: "SESS-LIVE" }));
    assert.equal(again.recovery, undefined, "nothing is eligible on the second pass");
    assert.equal(bridge.requests.filter((r) => /stranded terminal evidence/.test(r.text)).length, 1);
    assert.equal(markerLines(marker).length, 2, "recovery re-posts a reply; it never reruns the worker");
  } finally {
    await bridge.close();
  }
});

test("recovery refuses everything that is not PROVEN undelivered", async () => {
  const ctx = makeRoot("recovery-refuses");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  // Ambiguous: may already have landed. Re-posting is the double-delivery.
  writeSettledJob(ctx, "amb-1", {
    bridgeStatus: "unknown", bridgeReason: "http_504",
    completionText: "ambiguous evidence", agentSessionId: "SESS-AMB",
  });
  // An operator decision, not a transport fault.
  writeSettledJob(ctx, "sup-1", {
    status: "canceled", bridgeStatus: "suppressed",
    bridgeReason: "operator_cleanup_no_completion_delivery",
    completionText: "suppressed evidence", agentSessionId: "SESS-SUP",
  });
  // Delivered, text already cleared.
  writeSettledJob(ctx, "ok-1", { bridgeStatus: "delivered", completionText: null, agentSessionId: "SESS-OK" });
  // Proven-failed but the reply is not on the record: nothing to re-post. This
  // is the shape of the four legacy failures in the live store.
  writeSettledJob(ctx, "textless-1", {
    bridgeStatus: "failed", bridgeReason: "bridge_message_timeout",
    completionText: null, agentSessionId: "SESS-TEXTLESS",
  });
  const bridge = await startRespondingBridge(200, { status: "ok", ack: "enqueued" });
  try {
    const bin = fakeClaude(ctx.root, "never", "echo unused");
    const recovery = await runRecover(unknownEnv(ctx, bin, bridge.url));
    assert.equal(recovery.eligible, 0);
    assert.equal(recovery.attempted, 0);
    assert.equal(bridge.requests.length, 0, "not one post may leave for an unproven loss");
    assert.equal(readJob(ctx, "amb-1").completionText, "ambiguous evidence");
    assert.equal(readJob(ctx, "amb-1").deliveryRecoveryAt, undefined);
    assert.equal(readJob(ctx, "sup-1").deliveryLost, undefined);
  } finally {
    await bridge.close();
  }
});

test("a stranded completion with no origin session is carded, never posted or rerun", async () => {
  const ctx = makeRoot("recovery-no-origin");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  writeSettledJob(ctx, "no-origin-1", {
    bridgeStatus: "blocked",
    bridgeReason: "missing_origin_session",
    completionText: "retained result with nowhere to go",
    agentSessionId: null,
    payload: { messageId: "no-origin-1", text: "prior work", topic: "recovery" },
  });
  const bridge = await startRespondingBridge(200, { status: "ok", ack: "enqueued" });
  try {
    const bin = fakeClaude(ctx.root, "never", "echo unused");
    const recovery = await runRecover(unknownEnv(ctx, bin, bridge.url));
    assert.equal(recovery.eligible, 1);
    assert.equal(recovery.results[0].status, "carded");
    assert.equal(recovery.results[0].posted, false);
    assert.equal(bridge.requests.length, 0);

    const job = readJob(ctx, "no-origin-1");
    // The record must still present as BLOCKED — that is the outcome class the
    // delegation-outcome card reports it under, and arming deliveryLost here
    // would silently reclassify it.
    assert.equal(job.bridgeStatus, "blocked");
    assert.notEqual(job.deliveryLost, true);
    assert.equal(job.completionText, "retained result with nowhere to go", "the reply stays on the record");
    assert.equal(job.deliveryRecoveryOutcome, "carded_origin_unresolvable");
    assert.match(job.deliveryRecoveryNote, /no-origin-1\.json/);
    assert.match(job.deliveryRecoveryNote, /Do not rerun the worker/);

    // Once only.
    const second = await runRecover(unknownEnv(ctx, bin, bridge.url));
    assert.equal(second.eligible, 0);
  } finally {
    await bridge.close();
  }
});

test("one recovery pass is bounded and drains oldest-first", async () => {
  const ctx = makeRoot("recovery-bounded");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  for (const [id, at] of [["old", "2026-08-01"], ["mid", "2026-08-02"], ["new", "2026-08-03"]]) {
    writeSettledJob(ctx, `bounded-${id}`, {
      completedAt: `${at}T00:00:00.000Z`,
      bridgeStatus: "failed", bridgeReason: "ECONNREFUSED",
      completionText: `evidence ${id}`, agentSessionId: "SESS-BOUND",
    });
  }
  const bridge = await startRespondingBridge(200, { status: "ok", ack: "enqueued" });
  try {
    const bin = fakeClaude(ctx.root, "never", "echo unused");
    const env = unknownEnv(ctx, bin, bridge.url, { NATIVE_AGENT_CLAUDE_WAKE_RECOVERY_MAX: "2" });
    const recovery = await runRecover(env);
    assert.equal(recovery.eligible, 3);
    assert.equal(recovery.attempted, 2);
    assert.deepEqual(bridge.requests.map((r) => r.text), ["evidence old", "evidence mid"]);
    assert.equal(readJob(ctx, "bounded-new").deliveryRecoveryAt, undefined);
    await runRecover(env);
    assert.deepEqual(bridge.requests.map((r) => r.text), ["evidence old", "evidence mid", "evidence new"]);
  } finally {
    await bridge.close();
  }
});

// ------------------------------------------------------- stalled re-arm (B)

test("a timed-out run re-arms exactly ONCE and records the attempt durably", async () => {
  const ctx = makeRoot("rearm-timeout");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "slow", `echo ran >> "${marker}"\nexec sleep 30`);
  const env = baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "1" });
  const payload = payloadFor({ messageId: "rearm-1", topic: "rearm timeout" });
  const result = await runHelperAsync(env, payload, { timeoutMs: 60_000 });
  assert.equal(result.status, "failed");
  assert.equal(result.reason, "timeout_after_1s");
  assert.equal(result.autoRearms, 1);
  assert.equal(markerLines(marker).length, 2, "exactly one retry — not zero, not two");
  const job = readJob(ctx, "rearm-1");
  assert.equal(job.autoRearms, 1);
  assert.equal(job.autoRearmReason, "timeout_after_1s");
  assert.ok(job.autoRearmAt);
  assert.equal(job.state, "settled");
  assert.equal(job.status, "failed", "past the budget the honest end state is a failure card");
});

test("CONTROL: the re-arm budget is honoured — 0 disables it, and a clean run never re-arms", async () => {
  const ctx = makeRoot("rearm-control");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "slow", `echo ran >> "${marker}"\nexec sleep 30`);
  const off = await runHelperAsync(
    baseEnv(ctx, bin, {
      NATIVE_AGENT_CLAUDE_WAKE_TIMEOUT_SECONDS: "1",
      NATIVE_AGENT_CLAUDE_WAKE_MAX_REARMS: "0",
    }),
    payloadFor({ messageId: "rearm-off", topic: "rearm off" }),
    { timeoutMs: 60_000 }
  );
  assert.equal(off.reason, "timeout_after_1s");
  assert.equal(off.autoRearms, 0);
  assert.equal(markerLines(marker).length, 1);

  const cleanMarker = path.join(ctx.root, "clean.txt");
  const cleanBin = fakeClaude(ctx.root, "clean", `echo ran >> "${cleanMarker}"\necho "answered"`);
  const clean = await runHelperAsync(
    baseEnv(ctx, cleanBin),
    payloadFor({ messageId: "rearm-clean", topic: "rearm clean" })
  );
  assert.equal(clean.status, "completed");
  assert.equal(clean.autoRearms, 0);
  assert.equal(markerLines(cleanMarker).length, 1);
});

// ------------------------------------------------- wedged runner re-arm (B2)
//
// Before this, a runner that was alive but wedged past its own deadline held
// its messageId hostage until the process died: every retry returned
// "duplicate" forever. The kill is admissible ONLY because the runner stamps
// `delivering` before it posts, so a pre-delivery job cannot have delivered.

function spawnWedgedRunner() {
  const child = spawn("/bin/sh", ["-c", "exec sleep 300"], { detached: true, stdio: "ignore" });
  child.unref();
  return child.pid;
}

function writeWedgedJob(ctx, messageId, pid, fields = {}) {
  const file = jobFileFor(ctx, messageId);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const past = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const job = {
    schemaVersion: 2,
    messageId,
    createdAt: past,
    claimedAt: past,
    heartbeatAt: new Date().toISOString(),
    startedAt: past,
    deadlineAt: past,
    state: "running",
    claimId: "wedged-claim",
    pid,
    runnerPid: pid,
    attemptSessionId: "wedged-session",
    topicSlug: "wedged",
    timeoutSeconds: 60,
    payload: { messageId, text: "the wedged work", topic: "wedged" },
    ...fields,
  };
  fs.writeFileSync(file, JSON.stringify(job, null, 2), { mode: 0o600 });
  return job;
}

test("a wedged runner past its deadline is TERMINATED and the wake re-arms once", async () => {
  const ctx = makeRoot("wedged-rearm");
  const pid = spawnWedgedRunner();
  writeWedgedJob(ctx, "wedged-1", pid);
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo ran >> "${marker}"\necho "the re-armed answer"`);
  const result = await runHelperAsync(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_WEDGED_MARGIN_MS: "0" }),
    payloadFor({ messageId: "wedged-1", topic: "wedged" }),
    { timeoutMs: 60_000 }
  );
  assert.equal(result.status, "completed", `expected the re-armed run to answer, got ${JSON.stringify(result)}`);
  assert.equal(result.takeover.reason, "wedged_runner_terminated");
  assert.ok(result.takeover.wedge.overdueMs > 0);
  // A field saying "terminated" proves nothing; the process must be gone.
  let alive = true;
  try { process.kill(pid, 0); } catch { alive = false; }
  assert.equal(alive, false, `wedged pid ${pid} is STILL ALIVE — the re-arm ran beside a live runner`);
  assert.equal(markerLines(marker).length, 1);
  const job = readJob(ctx, "wedged-1");
  assert.equal(job.autoRearms, 1);
  assert.equal(job.state, "settled");
  assert.match(job.autoRearmReason, /^wedged_runner_terminated_overdue_/);
});

test("a wedged runner whose re-arm budget is spent is terminated and CARDED as failed", async () => {
  const ctx = makeRoot("wedged-exhausted");
  const pid = spawnWedgedRunner();
  writeWedgedJob(ctx, "wedged-2", pid, { autoRearms: 1 });
  const marker = path.join(ctx.root, "must-not-run");
  const bin = fakeClaude(ctx.root, "never", `echo ran >> "${marker}"\necho hi`);
  const result = await runHelperAsync(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_WEDGED_MARGIN_MS: "0" }),
    payloadFor({ messageId: "wedged-2", topic: "wedged" }),
    { timeoutMs: 60_000 }
  );
  assert.equal(result.status, "skipped");
  assert.equal(result.note, "wedged_runner_rearm_exhausted");
  assert.equal(result.wedgedRunnerTerminated, true);
  let alive = true;
  try { process.kill(pid, 0); } catch { alive = false; }
  assert.equal(alive, false, "the hostage-holding runner must still be released");
  assert.equal(fs.existsSync(marker), false, "past the budget nothing reruns");
  const job = readJob(ctx, "wedged-2");
  assert.equal(job.state, "settled");
  assert.equal(job.status, "failed");
  assert.equal(job.reason, "wedged_runner_terminated_after_1_rearm");
  assert.equal(job.bridgeStatus, "suppressed");
  assert.equal(job.deliveryLost, false);
});

test("CONTROL: a runner that reached DELIVERING is never killed, however overdue", async () => {
  const ctx = makeRoot("wedged-delivering");
  const pid = spawnWedgedRunner();
  writeWedgedJob(ctx, "wedged-3", pid, { state: "delivering", runStatus: "completed" });
  const marker = path.join(ctx.root, "must-not-run");
  const bin = fakeClaude(ctx.root, "never", `echo ran >> "${marker}"\necho hi`);
  try {
    const result = await runHelperAsync(
      baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_WEDGED_MARGIN_MS: "0" }),
      payloadFor({ messageId: "wedged-3", topic: "wedged" }),
      { timeoutMs: 60_000 }
    );
    assert.equal(result.status, "skipped");
    assert.equal(result.reason, "duplicate");
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    assert.equal(alive, true, "a job at or past `delivering` may already have posted — killing it risks a double completion");
    assert.equal(fs.existsSync(marker), false);
  } finally {
    try { process.kill(pid, "SIGKILL"); } catch {}
  }
});
