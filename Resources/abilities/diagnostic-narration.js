/* NativeAgent ability
{"id":"diagnostic-narration","kind":"tool","version":1,"reach":{"capabilities":[]},"face":{"page":"diagnostics"},"record":{"description":"Narrate checked Desk and Activity facts. Native owners retain measured status, corruption detection, reconciliation and repair authority.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":true}}}
*/
function labels(group) {
    return group.aliases.slice(0, 5).map(alias => "#" + alias).join(", ") +
        (group.count > 5 ? " and " + (group.count - 5) + " more" : "");
}
function run(input) {
    if (input.kind === "desk") {
        const waiting = input.waiting, blocked = input.blocked, contradictions = input.contradictions;
        if (input.pendingApprovals === 0 && waiting.count === 0 && blocked.count === 0 && contradictions.count === 0) {
            return {detail: "No blocked Desk work, owner decision, or terminal-parent contradiction.", humanAction: null};
        }
        const parts = [], actions = [];
        if (waiting.count > 0) {
            parts.push(waiting.count + " item(s) wait on your decision: " + labels(waiting));
            actions.push("open Desk and decide items " + labels(waiting) + " marked waiting on you");
        }
        if (input.pendingApprovals > 0) {
            parts.push(input.pendingApprovals + " pending approval(s) wait for your decision");
            actions.push("open Approvals and decide the " + input.pendingApprovals + " pending request(s)");
        }
        if (blocked.count > 0) {
            const reasons = blocked.items.slice(0, 5).map(item => "#" + item.alias + ": " + item.reason).join("; ") +
                (blocked.count > 5 ? "; and " + (blocked.count - 5) + " more" : "");
            parts.push(blocked.count + " blocked item(s): " + reasons);
            actions.push("open Desk and resolve " + labels(blocked) + " using each recorded blocked reason or waiting party, clarifying the block there if neither is recorded");
        }
        if (contradictions.count > 0) {
            parts.push(contradictions.count + " terminal parent(s) contain open descendants: " + labels(contradictions));
            actions.push("press Repair in Diagnostics → Health checks to reconcile terminal parents " + labels(contradictions));
        }
        return {detail: parts.join("; ") + ".", humanAction: "For the named work, " + actions.join("; ") + "."};
    }
    if (input.kind === "activity") {
        const partial = input.malformedCount > 0
            ? "Activity log " + (input.recordCount === 0 ? "unreadable" : "partially readable") + ": " + input.malformedCount + " malformed row(s) in its bounded tail; " : "";
        const titles = input.recent.slice().sort((a, b) => a.createdAt === b.createdAt ? 0 : a.createdAt > b.createdAt ? -1 : 1)
            .slice(0, 3).map(row => row.title).join("; ");
        return {detail: partial + input.reconciliationCount + " outcome(s) need reconciliation; " + input.failureCount +
            " historical failure receipt(s) in the last 15 minutes of the retained activity tail" +
            (titles.length === 0 ? "" : "; latest: " + titles) + ".", humanAction: null};
    }
    throw new Error("Unknown diagnostic narration kind: " + input.kind);
}
