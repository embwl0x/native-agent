"use strict";

const fs = require("fs");
const net = require("net");
const crypto = require("crypto");

// The worker resolves the path and owns daemon lifecycle and reconnect policy.
function createCodexWakeRpc({ socketPath: SOCKET_PATH }) {
// Client frames are always masked (RFC 6455 5.1); opcode 0x1 for text,
// 0xA for the pong that must echo a ping's payload (5.5.3).
function wsFrame(text, opcode = 0x1) {
  const payload = Buffer.isBuffer(text) ? text : Buffer.from(text);
  const mask = crypto.randomBytes(4);
  const first = 0x80 | opcode;
  let header;
  if (payload.length < 126) {
    header = Buffer.from([first, 0x80 | payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = first;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = first;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i += 1) {
    masked[i] = payload[i] ^ mask[i % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function parseFrames(state, chunk, onText, socket) {
  if (state.closing) return;
  state.buffer = Buffer.concat([state.buffer, chunk]);
  while (state.buffer.length >= 2) {
    const b0 = state.buffer[0];
    const b1 = state.buffer[1];
    let len = b1 & 0x7f;
    const opcode = b0 & 0x0f;
    const fin = (b0 & 0x80) !== 0;
    const reservedOpcode = (opcode >= 0x3 && opcode <= 0x7) || opcode >= 0xb;
    // Control length markers 126/127 are already invalid at the base header;
    // never wait for extended lengths, masks or payload to reject them.
    if (reservedOpcode || (opcode >= 0x8 && (!fin || len > 125 || (opcode === 8 && len === 1)))) {
      state.closing = true;
      state.buffer = Buffer.alloc(0);
      state.fragments = null;
      try { socket.write(wsFrame(Buffer.from([0x03, 0xea]), 0x8)); } catch { /* peer already gone */ }
      socket.end();
      return;
    }
    let offset = 2;
    if (len === 126) {
      if (state.buffer.length < 4) return;
      len = state.buffer.readUInt16BE(2);
      offset = 4;
    } else if (len === 127) {
      if (state.buffer.length < 10) return;
      len = Number(state.buffer.readBigUInt64BE(2));
      offset = 10;
    }
    let mask = null;
    if ((b1 & 0x80) !== 0) {
      if (state.buffer.length < offset + 4) return;
      mask = state.buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (state.buffer.length < offset + len) return;
    const payload = Buffer.from(state.buffer.subarray(offset, offset + len));
    state.buffer = state.buffer.subarray(offset + len);
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    if (opcode === 1 || opcode === 0) {
      // 2026-09-07: a text message may arrive as a FIN=0 text frame followed
      // by continuation frames (opcode 0); only the assembled message is JSON.
      // Control frames (8/9) may interleave and are handled below regardless.
      // A continuation needs an open message and a new message needs none
      // (RFC 6455 5.4); either violation is a protocol error, closed with 1002.
      if ((opcode === 0) === !state.fragments) {
        state.closing = true;
        try { socket.write(wsFrame(Buffer.from([0x03, 0xea]), 0x8)); } catch { /* peer already gone */ }
        state.buffer = Buffer.alloc(0);
        state.fragments = null;
        socket.end();
        return;
      }
      if (opcode === 1) state.fragments = [];
      state.fragments.push(payload);
      if (fin) {
        const text = Buffer.concat(state.fragments).toString("utf8");
        state.fragments = null;
        onText(text);
      }
    }
    if (opcode === 8) {
      // 2026-09-07: answer the closing handshake with a Close frame (echoing
      // the peer's status code), then stop dispatching anything still buffered.
      // A Close status is either absent or a full two-byte code; a one-byte
      // payload is rejected from its header above.
      // Echo the status only when it is one a peer may send (RFC 6455 7.4);
      // 1005/1006/1015 and other reserved codes are answered with 1002.
      let closeStatus = Buffer.alloc(0);
      if (payload.length >= 2) {
        const code = payload.readUInt16BE(0);
        const sendable = (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999);
        closeStatus = sendable ? payload.subarray(0, 2) : Buffer.from([0x03, 0xea]);
      }
      state.closing = true;
      try { socket.write(wsFrame(closeStatus, 0x8)); } catch { /* peer already gone */ }
      state.buffer = Buffer.alloc(0);
      state.fragments = null;
      socket.end();
      return;
    }
    if (opcode === 9) socket.write(wsFrame(payload, 0xa));
  }
}

/// Codex app-server may ask its initiating client to execute a dynamic tool or
/// make an approval/elicitation decision. This bridge has no user in that
/// client loop and must never leave the turn waiting forever or invent consent.
/// Return the protocol's explicit failure/decline shape; app-server can then
/// feed the blocker back to the model so it can still produce a final receipt.
function unattendedServerRequestReply(message) {
  if (!message || message.id == null || typeof message.method !== "string") return null;
  const unavailable = "NativeAgent's unattended Codex bridge cannot execute client-owned tools or collect interactive approval. Use already-permitted local tools or return this blocker in the final result.";
  switch (message.method) {
    case "item/tool/call":
      return {
        result: {
          contentItems: [{ type: "inputText", text: unavailable }],
          success: false,
        },
      };
    case "item/commandExecution/requestApproval":
    case "item/fileChange/requestApproval":
      return { result: { decision: "decline" } };
    case "execCommandApproval":
    case "applyPatchApproval":
      return { result: { decision: "denied" } };
    case "mcpServer/elicitation/request":
      return { result: { action: "decline", content: null, _meta: null } };
    case "item/tool/requestUserInput":
    case "item/permissions/requestApproval":
      return { error: { code: -32001, message: unavailable } };
    default:
      return null;
  }
}

async function connectRpcOnce(timeoutMs) {
  if (!fs.existsSync(SOCKET_PATH)) {
    const error = new Error("app_server_socket_missing");
    error.detail = {
      socketPath: SOCKET_PATH,
      fix: "Run `codex app-server daemon start`, or open Codex Desktop with remote control enabled.",
    };
    throw error;
  }

  return await new Promise((resolve, reject) => {
    const socket = net.createConnection(SOCKET_PATH);
    const key = crypto.randomBytes(16).toString("base64");
    const state = { buffer: Buffer.alloc(0), handshaken: false, nextId: 1, ready: false, settled: false };
    const pending = new Map();
    const notificationListeners = new Set();
    const disconnectListeners = new Set();
    let initializeId = null;
    const readyTimer = setTimeout(() => {
      failReady(new Error("app_server_timeout"));
    }, timeoutMs);

    function failReady(error) {
      if (state.settled) return;
      state.settled = true;
      clearTimeout(readyTimer);
      try { socket.end(); } catch {}
      reject(error);
    }

    function send(method, params, withId = true) {
      const message = withId
        ? { id: state.nextId++, method, params }
        : { method, params };
      socket.write(wsFrame(JSON.stringify(message)));
      return message.id;
    }

    function rejectPending(error) {
      for (const { reject: rejectRequest, timer } of pending.values()) {
        clearTimeout(timer);
        rejectRequest(error);
      }
      pending.clear();
    }

    function emitNotification(message) {
      for (const listener of [...notificationListeners]) {
        try { listener(message); } catch {}
      }
    }

    function emitDisconnect(error) {
      for (const listener of [...disconnectListeners]) {
        try { listener(error); } catch {}
      }
    }

    function request(method, params, requestTimeoutMs = timeoutMs) {
      const id = send(method, params);
      return new Promise((resolveRequest, rejectRequest) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          const error = new Error(`${method}_timeout`);
          error.method = method;
          rejectRequest(error);
        }, requestTimeoutMs);
        pending.set(id, { method, resolve: resolveRequest, reject: rejectRequest, timer });
      });
    }

    function close() {
      rejectPending(new Error("app_server_client_closed"));
      notificationListeners.clear();
      disconnectListeners.clear();
      try { socket.end(); } catch {}
    }

    function onNotification(listener) {
      notificationListeners.add(listener);
      return () => notificationListeners.delete(listener);
    }

    function onDisconnect(listener) {
      disconnectListeners.add(listener);
      return () => disconnectListeners.delete(listener);
    }

    socket.on("connect", () => {
      socket.write([
        "GET / HTTP/1.1",
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      ].join("\r\n"));
    });

    socket.on("data", (chunk) => {
      if (state.closing) return;
      state.buffer = Buffer.concat([state.buffer, chunk]);
      if (!state.handshaken) {
        const headerEnd = state.buffer.indexOf("\r\n\r\n");
        if (headerEnd < 0) return;
        const header = state.buffer.subarray(0, headerEnd).toString("utf8");
        state.buffer = state.buffer.subarray(headerEnd + 4);
        if (!header.startsWith("HTTP/1.1 101")) {
          const error = new Error("websocket_upgrade_failed");
          error.detail = header.split("\r\n")[0];
          failReady(error);
          return;
        }
        state.handshaken = true;
        initializeId = send("initialize", {
          clientInfo: { name: "nativeagent-codex-wakeup", title: "NativeAgent Codex Wakeup", version: "1.1" },
          capabilities: { experimentalApi: true },
        });
      }

      parseFrames(state, Buffer.alloc(0), (text) => {
        let message;
        try {
          message = JSON.parse(text);
        } catch {
          return;
        }
        if (message.id === initializeId) {
          if (message.error) {
            const error = new Error(message.error.message || "initialize_failed");
            error.detail = message.error;
            failReady(error);
            return;
          }
          send("initialized", {}, false);
          if (!state.settled) {
            state.settled = true;
            state.ready = true;
            clearTimeout(readyTimer);
            resolve({ request, close, onNotification, onDisconnect });
          }
          return;
        }
        if (message.id != null && pending.has(message.id)) {
          const item = pending.get(message.id);
          pending.delete(message.id);
          clearTimeout(item.timer);
          if (message.error) {
            const error = new Error(message.error.message || `${item.method}_failed`);
            error.method = item.method;
            error.detail = message.error;
            item.reject(error);
          } else {
            item.resolve(message.result);
          }
          return;
        }
        if (message.id != null && typeof message.method === "string") {
          const reply = unattendedServerRequestReply(message);
          if (reply) {
            socket.write(wsFrame(JSON.stringify({ id: message.id, ...reply })));
            return;
          }
        }
        if (message.id == null && typeof message.method === "string") {
          emitNotification(message);
        }
      }, socket);
    });

    socket.on("error", (error) => {
      if (!state.ready) {
        failReady(error);
      } else {
        rejectPending(error);
        emitDisconnect(error);
      }
    });

    socket.on("close", () => {
      if (!state.ready) {
        failReady(new Error("app_server_socket_closed"));
      } else {
        const error = new Error("app_server_socket_closed");
        rejectPending(error);
        emitDisconnect(error);
      }
    });
  });
}

  return { connectRpcOnce, unattendedServerRequestReply, parseFrames };
}

module.exports = { createCodexWakeRpc };
