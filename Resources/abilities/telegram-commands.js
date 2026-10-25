/* NativeAgent ability
{"id":"telegram-commands","kind":"ability","version":1,
 "reach":{"capabilities":[]},"face":{"page":"telegram","projection":true},
 "record":{"description":"My Telegram command menu, help, and memory-command reply words. Native controls, memory provenance and awaited delivery stay with their owners.","actions":[],"inputSchema":{"type":"object"}}}
*/
function run(input) {
    if (input.op === "memory") {
        if (!["remember","note"].includes(input.command)) throw new Error("Unknown native memory command.");
        return {requiresText:"/" + input.command + " requires text",
            unavailable:"Memory is unavailable; check NativeAgent on the Mac.",
            success:input.command === "remember" ? "Remembered: " : "Saved note: ",
            failure:input.command === "remember" ? "Failed to remember: " : "Failed to save note: "};
    }
    return face(input);
}
function face(input) {
    const summaries = {stop:"Stop the current task",new:"Start a fresh conversation",retry:"Try your last message again",
        approve:"Approve a pending request",deny:"Deny a pending request",help:"What you can type here"};
    const rows = input.commands.map(command => {
        if (!Object.prototype.hasOwnProperty.call(summaries,command.name)) throw new Error("Unknown native Telegram menu command: " + command.name);
        return {id:command.name,title:summaries[command.name],detail:command.usage + " - " + summaries[command.name]};
    });
    const help = rows.map(row => row.detail).concat(["",'Anything else, just say it: "use opus", "think harder", "go fast", "use the default persona", "what model".']).join("\n");
    return {sections:[{id:"menu",rows},{id:"help",rows:[{id:"body",title:help}]}]};
}
