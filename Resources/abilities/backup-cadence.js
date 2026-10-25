/* NativeAgent ability
{"id":"backup-cadence","kind":"tool","version":1,"reach":{"capabilities":[]},"face":{"page":"diagnostics"},"record":{"description":"Choose off-disk backup freshness and identity-change cadence from native timestamps. No files, scheduling or backup effects.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":true}}}
*/
function run(input) {
    if (input.kind === "deadline") {
        if (input.newest === null) return null;
        const due = input.newest + input.interval;
        return due > input.now ? due : null;
    }
    if (input.kind === "trigger") {
        // Below the daily deadline, so a once-a-day tick never skips a day.
        if (input.newest === null || input.now - input.newest >= 20 * 60 * 60) return "daily";
        if (input.identity.status === "unavailable") throw new Error(input.identity.error);
        return input.identity.changedAt !== null && input.identity.changedAt > input.newest ? "identity change" : "current";
    }
    throw new Error("Unknown backup cadence kind: " + input.kind);
}
