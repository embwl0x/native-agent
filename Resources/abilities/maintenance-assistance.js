/* NativeAgent ability
{"id":"maintenance-assistance","kind":"tool","version":1,"reach":{"capabilities":[]},"face":{"page":"diagnostics"},"record":{"description":"Group and explain checked Doctor asks, saved storage plans and Speech Recognition permission facts. Content only; native owners publish the cards.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":true}}}
*/
function run(input) {
    if (input.kind === "doctor") {
        const asks = [...new Set(input.asks.map(row => "• " + row.title + ": " + row.action))].sort();
        return {title: asks.length === 1 ? "Doctor needs one thing from you" : "Doctor needs " + asks.length + " things from you",
            summary: "Sign-ins and permissions Doctor cannot do itself.", detail: asks.join("\n")};
    }
    if (input.kind === "storage") {
        const lines = [
            "Measured dynamic storage: " + input.dynamicSize + " / " + input.budgetSize + " budget (includes backups and derived data).",
            "Required embedding model: " + input.modelSize + ", outside that budget."
        ];
        input.usage.slice().sort((a, b) => b.bytes - a.bytes).filter(row => row.bytes > 0).forEach(row => {
            lines.push("• " + row.owner + ": " + row.size + "; reclaimable " + row.reclaimSize + ". " +
                (row.policy === null ? "Kept: app state without a recoverable cleanup policy." : row.policy));
        });
        input.plans.forEach(plan => lines.push(...plan.notes));
        input.planReads.filter(row => row.status === "unavailable").forEach(row => lines.push(row.owner + " kept: " + row.error));
        if (input.accounting.status === "partial") {
            lines.push("Storage accounting is incomplete; usage may be undercounted or required assets unclassified. Cleanup amounts come from complete owner plans.");
        }
        lines.push(input.reclaimable > 0
            ? "Clean Up will move " + input.reclaimSize + " out of app storage to Trash, recoverably. Disk space remains occupied until you empty the Trash."
            : "Nothing is safely reclaimable. All storage above is kept for the reasons shown; no Clean Up is offered.");
        return {title: "Disk usage is piling up", summary: "Dynamic storage " + input.dynamicSize + "; reclaimable " + input.reclaimSize,
            detail: lines.join("\n")};
    }
    if (input.kind === "speech") {
        return {title: "Speech Recognition is not approved", summary: input.warningSummary,
            detail: "A Telegram voice note could not be transcribed because macOS Speech Recognition is not approved for NativeAgent (current state: " + input.permission + ").\n\n" +
                input.warningSummary + "\n\nTwo ways to fix it:\n" +
                "• In NativeAgent: Trust → Mac → System permissions → Speech recognition → Grant.\n" +
                "• In macOS: open System Settings → Privacy & Security → Speech Recognition and switch NativeAgent on." +
                (input.settingsLink === null ? "" : "\n\nDirect link: " + input.settingsLink) +
                "\n\nUntil then, inbound voice notes will keep replying with the permission notice instead of a transcript."};
    }
    throw new Error("Unknown assistance card kind: " + input.kind);
}
