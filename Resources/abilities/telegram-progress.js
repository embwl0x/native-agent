/* NativeAgent ability
{"id":"telegram-progress","kind":"ability","version":1,
 "reach":{"capabilities":[]},"face":{"page":"telegram","projection":true},
 "record":{"description":"My Telegram progress and status voice over sanitized native lifecycle facts. No transport, approval, or terminal authority.","actions":[],"inputSchema":{"type":"object"}}}
*/
function run(input) { return face(input); }
function face(input) {
    const words = text => text.replace(/\b(?:invoke_claude|claude_message|invoke_codex|codex_message|omp_message|agent_swarm|Claude|Claude|Codex|OMP)\b/gi, "background work");
    const duration = seconds => {
        const total = Math.max(0, Math.floor(seconds));
        if (total < 60) return total + "s";
        if (total < 3600) return Math.floor(total / 60) + "m " + total % 60 + "s";
        return Math.floor(total / 3600) + "h " + Math.floor(total % 3600 / 60) + "m";
    };
    if (input.kind === "status" || input.kind === "connection") {
        let text;
        if (input.kind === "connection" && !input.connected) return {sections:[{id:"status",rows:[{id:"status",title:"Telegram isn't connected right now — turn it on in the Mac app."}]}]};
        if (input.kind === "connection") text = "Telegram is connected";
        else if (input.waitingOnUser) text = "The agent is waiting for approval";
        else if (input.running) text = input.hasPreview ? "The agent is working on “" + input.preview + "”" : "The agent is working on a request";
        else text = "The agent is idle";
        text += ".";
        if (input.model.status === "available") text += " Next-turn model: " + input.model.phrase + ".";
        const approvals = input.approvals.count === 0 ? "No pending approvals in this conversation."
            : input.approvals.count + " approval request(s) waiting in this conversation.";
        if (input.approvals.status === "available") text += " " + approvals;
        return {sections:[{id:"status",rows:[{id:"status",title:text}]}]};
    }
    const detail = input.action === null ? "" : words(input.action).trim();
    let line;
    switch (input.phase) {
    case "acknowledged": line = "Got your message, starting now."; break;
    case "working": case "tool": line = detail || "Still on it."; break;
    case "delegation": line = detail || "Working on a longer step…"; break;
    case "retrying": line = detail ? "That hiccuped, trying again: " + detail : "That hiccuped, trying again."; break;
    case "waiting": line = detail || "Waiting before the task can continue."; break;
    case "blocked": line = detail ? "Waiting on an approval from you: " + detail : "Waiting on an approval from you."; break;
    case "stalled": line = detail ? "Still on it, but it's been quiet: " + detail : "Still on it, but it's been quiet for a while."; break;
    case "completed": line = "Done."; break;
    case "failed": line = detail ? "That didn't work: " + detail : "That didn't work."; break;
    case "canceled": line = "Stopped."; break;
    case "outcome_unknown": line = detail ? "The outcome is unclear: " + detail : "The outcome is unclear."; break;
    default: throw new Error("Unknown native Telegram phase: " + input.phase);
    }
    const lines = [line, "Started " + duration(input.elapsed) + " ago; last update " + duration(input.sinceMovement) + " back."];
    if (input.action !== null && !line.includes(input.action)) lines.push("Right now: " + input.action);
    if (input.delegate !== null && !line.includes(input.delegate)) lines.push("Task: " + input.delegate + ".");
    const summary = input.replyTextSettled ? "Done." : line + (input.terminal ? "" : " (" + duration(input.elapsed) + " so far)");
    return {sections:[{id:"progress",rows:[
        {id:"summary",title:words(summary)},
        {id:"details",title:input.replyTextSettled ? "Done." : words(lines.join("\n"))}
    ]}]};
}
