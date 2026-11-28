// The only JavaScript bridge: the app's plug and local redaction policy.
// There is no filesystem, process, network or timer API.
(function (call) {
    "use strict";
    function invoke(type, fields) { return call(type, fields || {}); }
    const api = Object.freeze({
        // Local canonical Swift policy; no plug traffic or progress credit.
        redactText: text => call("redact", String(text)),
        bytes: Object.freeze({
            utf8: bytes => call("utf8", bytes),
            text: bytes => call("text", bytes),
            inflate: (bytes, size) => call("inflate", bytes, size),
            crc32: bytes => call("crc32", bytes)
        }),
        source: Object.freeze({
            read: address => invoke("source_read", {address: address == null ? null : address}),
            watch: () => invoke("source_watch")
        }),
        apps: Object.freeze({read: args => invoke("app_read", {args})}),
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
            set: (key, value, options) => invoke("state_set", {key, value, options}),
            delete: key => invoke("state_delete", {key}),
            list: prefix => invoke("state_list", {prefix}),
            cas: (key, expected, value, options) => invoke("state_cas", {key, expected, value, options})
        }),
        log: (...values) => invoke("log", {text: values.map(value =>
            typeof value === "string" ? value : JSON.stringify(value)).join(" ")})
    });
    Object.defineProperty(globalThis, "sense", {value: api, writable: false, configurable: false});
})(__senseCall);
