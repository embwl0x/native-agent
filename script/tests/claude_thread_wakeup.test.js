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

test("a job whose runner pid is dead is taken over instead of poisoning the messageId", () => {
  const ctx = makeRoot("dead-pid");
  const marker = path.join(ctx.root, "invocations.txt");
  const bin = fakeClaude(ctx.root, "ok", `echo "$1 $2" >> "${marker}"\necho "recovered answer"`);
  const jobsDir = path.join(ctx.bridgeDir, "wake-jobs");
  fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

  // A runner that claimed the job and then died (crash / SIGKILL / sleep):
  // state still says running, heartbeat is fresh, but the pid is gone.
  // 999999 is above macOS's pid ceiling, so process.kill(pid, 0) is ESRCH.
  // Timestamps are aged past the spawn-grace window (default 30s) so this is a
  // GENUINELY orphaned claim, not a parent/child handoff still in flight.
  const payload = payloadFor({ messageId: "dead-pid-1" });
  fs.writeFileSync(jobFileFor(ctx, "dead-pid-1"), JSON.stringify({
    messageId: "dead-pid-1",
    createdAt: new Date(Date.now() - 120_000).toISOString(),
    heartbeatAt: new Date(Date.now() - 120_000).toISOString(),
    state: "running",
    pid: 999999,
    topicSlug: "wake-parity",
    timeoutSeconds: 900,
    payload,
  }, null, 2), { mode: 0o600 });

  const result = runHelper(baseEnv(ctx, bin), payload);

  assert.equal(result.status, "completed");
  assert.equal(result.takeover.reason, "runner_pid_dead");
  assert.equal(markerLines(marker).length, 1, "the takeover must actually run the wake");
  // The dead job is renamed aside, never deleted.
  const stale = fs.readdirSync(jobsDir).filter((name) => name.startsWith("dead-pid-1.json.stale-"));
  assert.equal(stale.length, 1, `expected one renamed-aside job, saw ${JSON.stringify(fs.readdirSync(jobsDir))}`);
  assert.equal(JSON.parse(fs.readFileSync(path.join(jobsDir, stale[0]), "utf8")).pid, 999999);
  assert.equal(readJob(ctx, "dead-pid-1").state, "settled");
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

test("the parent/child spawn window is treated as live until the grace expires", () => {
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

  // Past the grace with still no runnerPid: nothing is going to name a child
  // now, so the claim really is orphaned and takeover proceeds.
  writeOrphanedParent("spawn-grace-2", 120_000);
  const taken = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "spawn-grace-2" }));
  assert.equal(taken.status, "completed");
  assert.equal(taken.takeover.reason, "runner_pid_dead");
  assert.equal(markerLines(marker).length, 1);
  const stale = fs.readdirSync(jobsDir).filter((name) => name.startsWith("spawn-grace-2.json.stale-"));
  assert.equal(stale.length, 1);
  // The winner re-claims with a FRESH claimId — the fence the old runner would
  // fail if it ever came back.
  assert.notEqual(readJob(ctx, "spawn-grace-2").claimId, "claim-spawn-grace-2");

  // The grace is env-overridable: 0 disables it entirely.
  writeOrphanedParent("spawn-grace-3", 1000);
  const forced = runHelper(
    baseEnv(ctx, bin, { NATIVE_AGENT_CLAUDE_WAKE_SPAWN_GRACE_MS: "0" }),
    payloadFor({ messageId: "spawn-grace-3" })
  );
  assert.equal(forced.status, "completed");
  assert.equal(forced.takeover.reason, "runner_pid_dead");
  assert.equal(markerLines(marker).length, 2);
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

  // The same file aged past the write grace is genuinely corrupt: takeover.
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(jobFileFor(ctx, "mid-write-1"), old, old);
  const taken = runHelper(baseEnv(ctx, bin), payloadFor({ messageId: "mid-write-1" }));
  assert.equal(taken.status, "completed");
  assert.equal(taken.takeover.reason, "job_unreadable");
  assert.equal(markerLines(marker).length, 1);
  assert.equal(fs.readdirSync(jobsDir).filter((n) => n.startsWith("mid-write-1.json.stale-")).length, 1);
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
function startHangingBridge() {
  const sockets = new Set();
  const server = http.createServer((req) => {
    req.on("data", () => {});
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

test("a reply timeout with the receipt in her session store settles as DELIVERED", async () => {
  const ctx = makeRoot("unknown-present");
  fs.writeFileSync(path.join(ctx.bridgeDir, "token"), "test-token\n", { mode: 0o600 });
  const bin = fakeClaude(ctx.root, "ok", 'echo "confirmed answer"');
  // The bridge enqueued the row before its turn stalled: the marker is in the
  // store even though the HTTP response never comes back.
  fs.mkdirSync(storeDirFor(ctx), { recursive: true });
  fs.writeFileSync(
    path.join(storeDirFor(ctx), "SESS-B.jsonl"),
    `${JSON.stringify({ role: "user", content: `[from: claude, via bridge] [claude-wake] Automated completion event.\n\n${wakeup.deliveryMarker("unknown-2")}` })}\n`
  );
  const bridge = await startHangingBridge();
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
      `${JSON.stringify({ role: "user", content: `[claude-wake] ${wakeup.deliveryMarker("unknown-4")}` })}\n`
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
      `${JSON.stringify({ role: "user", content: `[claude-wake] ${wakeup.deliveryMarker("unknown-6")}` })}\n`
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
  // Burns no CPU at all: the exact shape of a wedged session. The ceiling is
  // set far above the stall window so a pass here can ONLY come from the stall
  // watchdog, never from the deadline timer.
  // `exec` matters: without it the shell's child would inherit the stdout pipe
  // and hold it open past the kill, so the runner could not settle. exec keeps
  // ONE pid (preserved across exec, so $$ is the pid that must die).
  const bin = fakeClaude(ctx.root, "wedged", `echo $$ > ${marker}\nexec sleep 300\n`);
  const env = baseEnv(ctx, bin, {
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
  // Exec one persistent CPU-burning process instead of a shell loop that forks
  // `date` on every iteration. The fork-heavy shape can spend most of a loaded
  // test run waiting on short-lived descendants that disappear between `ps`
  // samples, making a genuinely busy control look idle. This process burns CPU
  // for ~7s — more than 2x the 3s stall window. If the watchdog were
  // unconditional, or keyed on stdout (which stays empty until exit), it would
  // still be killed.
  const bin = fakeClaude(
    ctx.root,
    "busy",
    `exec ${JSON.stringify(process.execPath)} -e 'const end = Date.now() + 7000; while (Date.now() < end) {} console.log("the real reply")'\n`
  );
  const env = baseEnv(ctx, bin, {
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
  // the CHILD's clock, distinct from the runner's heartbeatAt.
  const job = readJob(ctx, payload.messageId);
  assert.ok(job.progressAt, "no progressAt was ever stamped — the watchdog never saw the child work");
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
  // NO `exec` here, and the background descendant inherits stdout. If the
  // watchdog killed only the direct child, the descendant would hold the pipe
  // open, node's 'close' would never fire, and the runner would hang forever
  // on a process it had already killed — the "hung to SIGTERM" shape.
  const bin = fakeClaude(
    ctx.root,
    "leaky",
    `echo $$ > ${parentMarker}\nsh -c 'echo $$ > ${childMarker}; sleep 300' &\nsleep 300\n`
  );
  const env = baseEnv(ctx, bin, {
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
  // Record shaped like claimRecord()'s output (hold fields present-and-null).
  fs.writeFileSync(path.join(jobsDir, `${jobId}.json`), JSON.stringify({
    messageId: jobId, state: "claimed", claimId: "c1",
    commitPolicy: "hold", holdReleasedAt: null, holdReleasedBy: null,
  }, null, 2));

  const released = runRelease(bridgeDir, [jobId, "--by", "agent"]);
  assert.equal(released.status, 0, released.stderr);
  assert.equal(released.out.status, "released");
  assert.equal(released.out.holdReleasedBy, "agent");

  // The AUTHORITY is the sidecar: it exists and carries the stamp.
  const releasesDir = path.join(bridgeDir, "wake-releases");
  const sidecar = JSON.parse(fs.readFileSync(path.join(releasesDir, `${jobId}.json`), "utf8"));
  assert.equal(sidecar.holdReleasedBy, "agent");
  assert.ok(sidecar.holdReleasedAt);
  assert.equal(sidecar.messageId, jobId);

  // Job record gets the best-effort mirror; untouched fields survive.
  const onDisk = JSON.parse(fs.readFileSync(path.join(jobsDir, `${jobId}.json`), "utf8"));
  assert.equal(onDisk.commitPolicy, "released");
  assert.equal(onDisk.claimId, "c1");

  // BLOCKING-fix regression: a racing runner write that resurrects the held
  // job record must NOT un-release — the sidecar survives untouched.
  fs.writeFileSync(path.join(jobsDir, `${jobId}.json`), JSON.stringify({
    messageId: jobId, state: "claimed", claimId: "c1",
    commitPolicy: "hold", holdReleasedAt: null, holdReleasedBy: null,
  }, null, 2));
  assert.ok(fs.existsSync(path.join(releasesDir, `${jobId}.json`)),
    "sidecar must survive a stale job-record rewrite");

  // Idempotent: second release reports the ORIGINAL stamp, changes nothing.
  const again = runRelease(bridgeDir, [`${jobId}.json`, "--by", "user"]);
  assert.equal(again.status, 0);
  assert.equal(again.out.status, "already_released");
  assert.equal(again.out.holdReleasedBy, "agent");
  const sidecarAfter = JSON.parse(fs.readFileSync(path.join(releasesDir, `${jobId}.json`), "utf8"));
  assert.equal(sidecarAfter.holdReleasedAt, sidecar.holdReleasedAt);
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
  fs.mkdirSync(path.join(bridgeDir, "wake-jobs"), { recursive: true });

  const missing = runRelease(bridgeDir, ["NO-SUCH-JOB", "--by", "user"]);
  assert.equal(missing.status, 1);
  assert.equal(missing.out.status, "failed");
  assert.equal(missing.out.reason, "job_not_found_or_unreadable");

  const badBy = runRelease(bridgeDir, ["whatever", "--by", "codex"]);
  assert.equal(badBy.status, 1);
  assert.equal(badBy.out.reason, "invalid_releaser");

  const traversal = runRelease(bridgeDir, ["../outside", "--by", "user"]);
  assert.equal(traversal.status, 1);
  assert.equal(traversal.out.reason, "invalid_job_id");
});
