// The only JavaScript bridge: the app's plug and local redaction policy.
// There is no filesystem, process, network or timer API.
(function (call, redactText) {
    "use strict";
    function invoke(type, fields) {
        const reply = JSON.parse(call(type, JSON.stringify(fields || {})));
        if (reply.failure) {
            const error = new Error(reply.failure.message);
            error.code = reply.failure.code;
            throw error;
        }
        return reply.value;
    }
    function material(raw) {
        if (raw.kind !== "file") return raw;
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const encoded = raw.data;
        const bytes = new Uint8Array(raw.bytes);
        let bits = 0, buffer = 0, offset = 0;
        for (let i = 0; i < encoded.length && encoded[i] !== "="; i++) {
            buffer = (buffer << 6) | alphabet.indexOf(encoded[i]);
            bits += 6;
            if (bits >= 8) { bits -= 8; bytes[offset++] = (buffer >> bits) & 255; }
        }
        return {kind: "file", path: raw.path, bytes: raw.bytes, version: raw.version, data: bytes};
    }
    const api = Object.freeze({
        // Local canonical Swift policy; no plug traffic or progress credit.
        redactText: text => redactText(String(text)),
        source: Object.freeze({
            read: address => material(invoke("source_read", {address: address == null ? null : address})),
            watch: () => invoke("source_watch")
        }),
        publish: page => invoke("publish", {page}),
        notify: news => invoke("notify", {news}),
        // Report completed work, never a heartbeat. Omit n for one completed
        // unit; an explicit finite n must exceed this entry's last value.
        progress: n => {
            if (n !== undefined && (typeof n !== "number" || !Number.isFinite(n)))
                throw new TypeError("Sense progress requires a finite number.");
            return invoke("progress", {n: n === undefined ? null : n});
        },
        present: view => invoke("present", {view: view == null ? null : view}),
        act: (verb, address, args) => invoke("act", {verb, address, args: args === undefined ? {} : args}),
        state: Object.freeze({
            get: key => invoke("state_get", {key}),
            set: (key, value) => invoke("state_set", {key, value})
        }),
        log: (...values) => invoke("log", {text: values.map(value =>
            typeof value === "string" ? value : JSON.stringify(value)).join(" ")})
    });
    Object.defineProperty(globalThis, "sense", {value: api, writable: false, configurable: false});
})(__senseCall, __senseRedactText);
