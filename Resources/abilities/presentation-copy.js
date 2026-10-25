/* NativeAgent ability
{
  "id":"presentation-copy", "kind":"tool", "version":1,
  "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
  "face":{"projection":true},
  "record":{"description":"My page subtitles, activity phrases and automated conversation titles, over sanitized native presentation facts.","actions":[],"inputSchema":{"type":"object","required":["kind"]}}
}
*/
function run(input) { return face(input); }
function face(input) {
    if (input.kind === "conversations") {
        const rows=input.rows.map(r=>({id:r.key,title:face({kind:"conversation",opening:r.opening}).sections[0].rows[0].title}));
        const sections=[];
        for (let i=0;i<rows.length;i+=256) sections.push({id:"conversations:"+i,rows:rows.slice(i,i+256)});
        return {sections};
    }
    let text="";
    if (input.kind === "page") {
        const pages={
            Providers:"I think with the model accounts you connect here.",
            Capabilities:"This is what I can do and what's installed.",
            "Inbox Policy":"I decide here what to bring you and what to keep quiet.",
            Bots:"I run small jobs on my own here, on a schedule you set.",
            Trust:"This is what I'm allowed to do on this Mac without asking you first.",
            Connectors:"I reach your other apps and services through what you connect here.",
            Diagnostics:"This is how I'm running, and what to check when something looks wrong.",
            Personality:"This is who I am here — my name, my voice, and the documents behind them."
        };
        text=pages[input.page] || "";
    } else if (input.kind === "headline") {
        const count=input.count, failed=input.failed, asking=input.needsYou>0 ? " · "+input.needsYou+" needs you" : "";
        text=failed===0 ? "Looked something up · "+count+" tool"+(count===1 ? "" : "s")+asking
            : failed===count ? count===1 ? "That didn't work · 1 tool" : "That didn't work · all "+count+" tools failed"
            : "Looked something up · "+failed+" of "+count+" failed"+asking;
    } else if (input.kind === "tool") {
        const phrases={
            read_file:["Read a file","read a file"],file_excerpt:["Read a file","read a file"],
            write_file:["Wrote a file","write a file"],list_dir:["Looked through a folder","look through a folder"],
            grep:["Searched the files","search the files"],search_files:["Searched the files","search the files"],
            bash:["Ran a command","run a command"],run_command:["Ran a command","run a command"],
            web_search:["Looked it up on the web","look it up on the web"],web_fetch:["Looked it up on the web","look it up on the web"],
            recall_memory:["Checked what "+input.subject+" "+input.remember,"check what "+input.subject+" "+input.remember],
            memory_search:["Checked what "+input.subject+" "+input.remember,"check what "+input.subject+" "+input.remember],
            commit_memory:["Saved something to memory","save something to memory"],tool_catalog:["Looking up tools","look up tools"],
            tool_load:["Looking up tools","look up tools"],list_tools:["Looking up tools","look up tools"],
            desk_add_item:["Added it to the Desk","add it to the Desk"],
            inner_state:["Checked in with "+input.possessive+" inner state","check in with "+input.possessive+" inner state"],
            "":["Used a tool","use a tool"]
        };
        const p=phrases[input.tool] || [input.nameCharacters.slice(0,48).join(""),input.lowerCharacters.slice(0,48).join("")];
        text=input.status==="failed" ? "Couldn't "+p[1] : input.status==="needsYou" ? "Waiting on you to "+p[1] : input.status==="asked" ? "Asked you first" : p[0];
        if (input.file !== null) text+=" · "+input.file;
    } else if (input.kind === "conversation") {
        const opening=input.opening.trim();
        if (opening.startsWith("[Woken by ")) {
            const reason=opening.slice(10);
            text=reason.startsWith("my queue") ? "Woke up for my queue" : reason.startsWith("what resolved") ? "Woke up when something finished"
                : reason.startsWith("something worth sharing") ? "Woke up with something to share" : "Woke up on my own";
        } else if (/^Codex (replied to (your message|\d+ queued messages)|(wakeup failed|turn stalled|wakeup produced no reply)( for \d+ queued messages)?)\.(\s|$)/.test(opening)) text="Codex check-in";
        else if (opening.startsWith("Current standing instructions for ")) {
            const name=opening.slice(34).split(/[:\n]/,1)[0].trim();
            text=!name ? "A helper's run" : name.toLowerCase().endsWith("helper") ? name : "Helper: "+name;
        }
    } else throw new Error("Unknown presentation kind: "+input.kind);
    return {sections:[{id:"copy",rows:[{id:input.kind,title:text}]}]};
}
