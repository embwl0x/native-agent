/* NativeAgent ability
{
  "id": "notice",
  "kind": "tool",
  "version": 3,
  "reach": {"capabilities": ["app_data_read", "app_data_write"], "readPaths": [], "hosts": [], "apps": []},
  "wake": ["app.installed"],
  "face": {"page": "agents"},
  "resident": true,
  "record": {
    "description": "Notice a scriptable app arriving; offer once per bundle and version. Decline with authored.notice {verb: 'dismiss', bundle_id, version}.",
    "actions": ["home.arrive"],
    "inputSchema": {"type": "object"}
  }
}
*/
function run(given) {
    // Woken, what arrived is the wake's record; called, it is the call's own input.
    const input = given.wake || given;
    if (input.signal !== "app.installed" && input.verb !== "dismiss")
        return {status: "ok", effects: "none"};
    if (input.verb !== "dismiss" && input.scriptable !== true) {
        app.log("Not scriptable; nothing to offer.");
        return {status: "ok", effects: "none"};
    }
    if (typeof input.bundle_id !== "string" || !input.bundle_id || typeof input.version !== "string")
        throw new Error("A bundle id and version are required.");
    const path = "notice-state.json";
    const exists = host.files.list({root: "app_data", path: "."}).some(name => name.endsWith("/" + path));
    let state = {};
    if (exists) {
        const saved = host.files.read({root: "app_data", path});
        if (saved.truncated) throw new Error("Notice state was not read in full.");
        state = JSON.parse(saved.content);
        if (!state || typeof state !== "object" || Array.isArray(state)) throw new Error("Notice state must be an object.");
    }
    const key = JSON.stringify([input.bundle_id, input.version]);
    if (input.verb === "dismiss") {
        if (!Object.prototype.hasOwnProperty.call(state, key)) return {status: "not_found", effects: "none"};
        state[key] = "dismissed";
    } else {
        if (Object.prototype.hasOwnProperty.call(state, key)) {
            app.log("This version was already offered.");
            return {status: "ok", effects: "none"};
        }
        if (typeof input.name !== "string" || !input.name) throw new Error("A display name is required.");
        app.home.arrive({event_key: key, line: (input.name + " " + input.version).replace(/[\r\n\u2028\u2029]/g, " ") + " arrived. Want me to grow into it?"});
        state[key] = "offered";
    }
    host.files.write({root: "app_data", path, content: JSON.stringify(state)});
    return {status: "ok", effects: "occurred"};
}
