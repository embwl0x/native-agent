#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const { execFileSync } = require("node:child_process");

const updatedDetail = "ChatGPT app updated; Dot messaging needs a check";

function fail(reason, detail = updatedDetail) {
  const error = new Error(detail);
  error.reason = reason;
  throw error;
}

function string(value) { return typeof value === "string" && value.length > 0; }
function object(value) { return value != null && typeof value === "object" && !Array.isArray(value); }
function sameIdentity(first, second) {
  return object(first) && object(second) && ["root", "aeon", "room", "account"]
    .every(key => string(first[key]) && first[key] === second[key]);
}

function selection() {
  const state = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".codex/.codex-global-state.json"), "utf8"));
  const selected = state["electron-persisted-atom-state"]?.["primary-aeon-selection-v1"];
  const identity = selected?.response?.selection;
  if (identity?.available !== true || !string(identity.thread_id) || !string(identity.aeon_id)
    || !string(identity.messaging_room_id) || !string(selected.accountId)
    || !identity.aeon_id.startsWith(`${selected.accountId}~`)) {
    fail("dot_unavailable", "Dot's current conversation cannot be followed.");
  }
  return { root: identity.thread_id, aeon: identity.aeon_id, room: identity.messaging_room_id,
    account: selected.accountId };
}

function checkApp() {
  const processes = execFileSync("/bin/ps", ["-axo", "comm="], { encoding: "utf8", timeout: 2000 });
  const apps = [...new Set(processes.split("\n").map(entry => entry.trim())
    .filter(entry => entry.endsWith("/ChatGPT.app/Contents/MacOS/ChatGPT")))];
  if (apps.length === 0) fail("app_not_running", "ChatGPT app isn't running; Dot messaging is unavailable.");
  if (apps.length !== 1) fail("app_identity_ambiguous");
  const bundle = apps[0].slice(0, -"/Contents/MacOS/ChatGPT".length);
  const info = JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-",
    path.join(bundle, "Contents/Info.plist")], { encoding: "utf8", timeout: 2000 }));
  // App updates are followed: the protocol shape checks below fail safely if
  // ChatGPT changes how followers talk to Dot.
  if (info.CFBundleIdentifier !== "com.openai.codex") fail("bridge_protocol_changed");
}

function applyPatch(state, patch) {
  if (!object(patch) || !["add", "remove", "replace"].includes(patch.op) || !Array.isArray(patch.path)
    || patch.path.some(component => !["string", "number"].includes(typeof component)
      || ["__proto__", "prototype", "constructor"].includes(String(component)))
    || patch.op !== "remove" && !Object.hasOwn(patch, "value")) fail("patch_shape_changed");
  if (!patch.path.length) {
    if (patch.op === "remove") fail("patch_shape_changed");
    return patch.value;
  }
  let parent = state;
  for (const component of patch.path.slice(0, -1)) {
    if (!object(parent) && !Array.isArray(parent) || !Object.hasOwn(parent, component)) fail("patch_path_changed");
    parent = parent[component];
  }
  const component = patch.path.at(-1);
  if (Array.isArray(parent)) {
    const index = component === "-" ? parent.length : component;
    if (!Number.isSafeInteger(index) || index < 0 || index > parent.length
      || patch.op !== "add" && index === parent.length) fail("patch_path_changed");
    if (patch.op === "add") parent.splice(index, 0, patch.value);
    else if (patch.op === "remove") parent.splice(index, 1);
    else parent[index] = patch.value;
  } else {
    if (!object(parent) || patch.op !== "add" && !Object.hasOwn(parent, component)) fail("patch_path_changed");
    if (patch.op === "remove") delete parent[component];
    else parent[component] = patch.value;
  }
  return state;
}

class Follower {
  constructor(identity) {
    this.identity = identity;
    this.client = "initializing-client";
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.socket = net.createConnection(path.join(os.homedir(), ".codex/ipc/ipc.sock"));
    this.socket.on("data", chunk => {
      try {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        while (this.buffer.length >= 4) {
          const length = this.buffer.readUInt32LE(0);
          if (!length || length > 268435456) fail("frame_shape_changed");
          if (this.buffer.length < length + 4) break;
          const message = JSON.parse(this.buffer.subarray(4, length + 4));
          this.buffer = this.buffer.subarray(length + 4);
          this.receive(message);
        }
      } catch (error) { this.stop(error); }
    });
    this.socket.on("error", () => this.stop(Object.assign(new Error("Dot's current conversation cannot be followed."), { reason: "socket_unavailable" })));
    this.socket.on("close", () => this.stop(Object.assign(new Error("Dot's current conversation cannot be followed."), { reason: "socket_closed" })));
  }

  stop(error) {
    this.error = this.error ?? error;
    for (const entry of this.pending.values()) entry.reject(error);
    this.pending.clear();
    this.snapshotReject?.(error);
    this.socket.destroy();
  }

  write(message) {
    if (this.error) throw this.error;
    const bytes = Buffer.from(JSON.stringify(message));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(bytes.length);
    this.socket.write(Buffer.concat([header, bytes]));
  }

  following(following) {
    this.write({ type: "broadcast", method: "thread-stream-following-changed", version: 1,
      sourceClientId: this.client, ...(this.owner ? { targetClientIds: [this.owner] } : {}),
      params: { conversationId: this.identity.root, hostId: "durable", following } });
  }

  async request(method, version, params, targeted = false) {
    const requestId = randomUUID();
    const response = new Promise((resolve, reject) => this.pending.set(requestId, { resolve, reject }));
    let timer;
    try {
      this.write({ type: "request", requestId, method, version, params, sourceClientId: this.client,
        timeoutMs: 10000, ...(targeted ? { hostId: "durable", targetClientId: this.owner } : {}) });
      return await Promise.race([response, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Object.assign(new Error("Dot acknowledgement is unavailable; nothing was resent."), { reason: "acknowledgement_unknown" })), 11000);
      })]);
    } finally { clearTimeout(timer); this.pending.delete(requestId); }
  }

  validate() {
    const state = this.state;
    if (object(state) && string(state.resumeState) && state.resumeState !== "resumed") {
      fail("dot_unavailable", "Dot's current conversation cannot be followed.");
    }
    if (!object(state) || state.id !== this.identity.root || state.hostId !== "durable"
      || state.threadSource !== "aeon" || state.mode !== "durable" || state.resumeState !== "resumed"
      || state.turnHistory?.kind !== "canonical" || !object(state.turnHistory.history?.entitiesByKey)
      || !this.turns().every(turn => object(turn) && (string(turn.turnId) || turn.turnId === null) && Array.isArray(turn.items)
        && turn.items.every(item => object(item) && string(item.id) && string(item.type)))) fail("snapshot_shape_changed");
  }

  turns() { return Object.values(this.state?.turnHistory?.history?.entitiesByKey ?? {}); }

  receive(message) {
    if (!object(message)) fail("envelope_shape_changed");
    if (message.type === "response") {
      const entry = this.pending.get(message.requestId);
      if (entry) {
        if (!["success", "error"].includes(message.resultType)) fail("response_shape_changed");
        entry.resolve(message);
      }
    } else if (message.type === "client-discovery-request") {
      this.write({ type: "client-discovery-response", requestId: message.requestId, response: { canHandle: false } });
    } else if (message.type === "request") {
      this.write({ type: "response", requestId: message.requestId, resultType: "error", error: "no-handler-for-request" });
    } else if (message.type === "broadcast" && message.method === "thread-stream-state-changed"
      && message.params?.conversationId === this.identity.root && message.params?.hostId === "durable") {
      if (this.owner && message.sourceClientId !== this.owner) fail("owner_identity_changed");
      if (message.version !== 11 || !string(message.sourceClientId)) fail("stream_version_changed");
      const change = message.params.change;
      if (!object(change) || !Number.isSafeInteger(change.revision) || change.revision < 0) fail("stream_shape_changed");
      if (change.type === "snapshot") {
        this.state = change.conversationState;
      } else if (change.type === "patches") {
        if (!this.state || change.baseRevision !== this.revision || change.revision <= this.revision
          || !Array.isArray(change.patches)) fail("stream_revision_changed");
        for (const patch of change.patches) this.state = applyPatch(this.state, patch);
      } else fail("stream_shape_changed");
      this.validate();
      this.owner = message.sourceClientId;
      this.revision = change.revision;
      this.snapshotResolve?.();
    }
  }

  async handshake() {
    await new Promise((resolve, reject) => {
      if (this.error) return reject(this.error);
      this.socket.once("connect", resolve);
      this.socket.once("error", reject);
    });
    const initialized = await this.request("initialize", 0, { clientType: "nativeagent-dot" });
    if (initialized.resultType !== "success" || initialized.method !== "initialize"
      || !string(initialized.result?.clientId) || initialized.handledByClientId !== initialized.result.clientId) fail("initialize_shape_changed");
    this.client = initialized.result.clientId;
    let timer;
    try {
      const snapshot = new Promise((resolve, reject) => { this.snapshotResolve = resolve; this.snapshotReject = reject; });
      this.following(true);
      await Promise.race([snapshot, new Promise((_, reject) => {
        timer = setTimeout(() => reject(Object.assign(new Error("Dot's current conversation cannot be followed."), { reason: "snapshot_unavailable" })), 8000);
      })]);
      if (this.error) throw this.error;
      this.validate();
    } finally { clearTimeout(timer); this.snapshotResolve = null; this.snapshotReject = null; }
  }

  close() {
    if (this.client !== "initializing-client" && !this.socket.destroyed && !this.error) this.following(false);
    this.socket.end();
  }
}

function roomMessages(follower) {
  const seen = new Set();
  const messages = [];
  for (const turn of follower.turns()) for (const item of turn.items) {
    if (item.type === "userMessage" || item.type === "steeringUserMessage" && item.serverUserMessageId != null) {
      const text = (item.content ?? item.input).filter(part => part.type === "text").map(part => part.text).join("\n");
      const roomTime = text.match(/<external_event\b[^>]*\btimestamp="([^"]+)"/)?.[1];
      const started = item.restoreMessage?.createdAt ?? turn.turnStartedAtMs;
      const at = roomTime ?? (Number.isFinite(started) ? new Date(started).toISOString() : null);
      if (!at || !Number.isFinite(Date.parse(at))) fail("reply_shape_changed");
      messages.push({ id: item.serverUserMessageId ?? item.id, kind: "user",
        client_id: item.serverClientUserMessageId ?? item.clientId, text, at });
      continue;
    }
    if (item.type !== "mcpToolCall" || item.server !== "codex_apps" || item.tool !== "user_message.send_message"
      || item.status !== "completed" || item.error != null || item.result?.isError === true) continue;
    const post = item.result?.structuredContent;
    if (post?.room_id !== follower.identity.room) continue;
    let args = item.arguments;
    try { if (typeof args === "string") args = JSON.parse(args); } catch { fail("reply_shape_changed"); }
    if (args?.channel !== "chatgpt") continue;
    if (!string(args.text) || post.channel !== "chatgpt" || post.status !== "accepted"
      || !string(post.message_id) || !string(post.created_at) || !Number.isFinite(Date.parse(post.created_at))) fail("reply_shape_changed");
    if (seen.has(post.message_id)) continue;
    seen.add(post.message_id);
    messages.push({ id: post.message_id, kind: "dot", text: args.text, at: post.created_at });
  }
  return messages.sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

async function main(input) {
  let follower;
  let dispatched = false;
  try {
    if (!["handshake", "send", "read"].includes(input.action)) fail("invalid_action", "Dot messaging request is invalid.");
    checkApp();
    const identity = selection();
    if (input.conversation_id != null && input.conversation_id !== identity.root) {
      fail("invalid_conversation", "Dot has one conversation; conversation_id must be Dot's current root. Nothing was sent or read.");
    }
    follower = new Follower(identity);
    await follower.handshake();
    if (!sameIdentity(selection(), identity)) fail("dot_identity_changed");
    if (input.action === "handshake") return { status: "available", identity };
    if (input.action === "read") return { status: "ok", messages: roomMessages(follower) };
    if (!string(input.text) || input.text.length > 64000) fail("invalid_send", "Dot messaging request is invalid; nothing was sent.");
    checkApp();
    if (!sameIdentity(selection(), identity) || follower.error) fail("dot_identity_changed");
    const clientUserMessageId = randomUUID();
    dispatched = true;
    const response = await follower.request("thread-follower-start-turn", 3, { conversationId: identity.root,
      turnStart: { request: { threadId: identity.root, clientUserMessageId,
        input: [{ type: "text", text: input.text, text_elements: [] }] },
      context: { inheritThreadSettings: true, messageThreadId: randomUUID() } } }, true);
    const result = response.result?.result;
    if (response.resultType === "error" && /not yet confirmed/i.test(String(response.error ?? "")))
      fail("chatgpt_busy", "ChatGPT is still confirming an earlier message to Dot; try again in a moment. Nothing was sent.");
    if (response.resultType !== "success" || response.method !== "thread-follower-start-turn"
      || response.handledByClientId !== follower.owner || !string(result?.turn?.id)
      || result.clientUserMessageId !== clientUserMessageId
      || !["started", "steered", "duplicate"].includes(result.admissionOutcome)) {
      try { require("fs").writeFileSync(require("path").join(process.cwd(), "logs", "dot_ipc_admission.json"),
        JSON.stringify({ at: new Date().toISOString(), resultType: response.resultType, method: response.method,
          handledBy: response.handledByClientId === follower.owner, keys: Object.keys(result ?? {}),
          admissionOutcome: result?.admissionOutcome, hasTurn: !!result?.turn?.id,
          idMatch: result?.clientUserMessageId === clientUserMessageId, error: response.error }, null, 1)); } catch {}
      fail("admission_shape_changed");
    }
    return { status: "sent", sent: true, client_user_message_id: clientUserMessageId };
  } catch (error) {
    if (error.reason === "chatgpt_busy") return { status: "busy", sent: false, reason: error.reason, detail: error.message };
    return { status: dispatched ? "outcome_unknown" : "unavailable", sent: dispatched ? null : false,
      reason: error.reason ?? "bridge_protocol_changed",
      detail: dispatched ? "Dot acknowledgement is unavailable; nothing was resent." : error.reason ? error.message : updatedDetail };
  } finally { follower?.close(); }
}

let bytes = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { bytes += chunk; if (bytes.length > 256 * 1024) process.exit(1); });
process.stdin.on("end", async () => {
  try { console.log(JSON.stringify(await main(JSON.parse(bytes)))); }
  catch { console.log(JSON.stringify({ status: "unavailable", sent: false, completed: false, detail: "Dot messaging request is invalid." })); }
});
