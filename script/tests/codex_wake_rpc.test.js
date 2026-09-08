"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const { parseFrames } = require("../codex_wake_rpc.js").createCodexWakeRpc({ socketPath: "unused" });

function fixture() {
  const state = { buffer: Buffer.alloc(0), fragments: null };
  const writes = [];
  const texts = [];
  let ended = 0;
  const socket = { write: frame => writes.push(frame), end: () => ended++ };
  return {
    state, writes, texts,
    feed: bytes => parseFrames(state, Buffer.from(bytes), text => texts.push(text), socket),
    status() {
      assert.equal(ended, 1);
      const frame = writes[0];
      assert.equal(frame[0], 0x88);
      assert.equal(frame[1], 0x82);
      return ((frame[6] ^ frame[2]) << 8) | (frame[7] ^ frame[3]);
    },
  };
}

test("Close echoes registered statuses and rejects reserved and unassigned statuses", () => {
  for (const code of [1000, 1003, 1007, 1011, 1012, 1013, 1014, 3000, 4999,
    999, 1004, 1005, 1006, 1015, 1016, 2000, 2999, 5000]) {
    const f = fixture();
    f.feed([0x88, 2, code >> 8, code & 255]);
    const valid = [1000, 1003, 1007, 1011, 1012, 1013, 1014, 3000, 4999].includes(code);
    assert.equal(f.status(), valid ? code : 1002, String(code));
    f.feed([0x81, 2, 0x7b, 0x7d]);
    assert.deepEqual(f.texts, []);
    assert.equal(f.state.buffer.length, 0);
    assert.equal(f.writes.length, 1);
  }
});

test("invalid control headers close before extended lengths or payload arrive", () => {
  for (const header of [[0x89, 126], [0x89, 127], [0x09, 125], [0x88, 1], [0x8b, 125]]) {
    const f = fixture();
    f.feed(header.slice(0, 1));
    assert.equal(f.writes.length, 0);
    f.feed(header.slice(1));
    assert.equal(f.status(), 1002);
    f.feed([0x81, 2, 0x7b, 0x7d]);
    assert.deepEqual(f.texts, []);
  }
});
