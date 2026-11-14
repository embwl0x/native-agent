/* NativeAgent ability
{"id":"native-morning-brief","kind":"ability","version":1,
 "reach":{"capabilities":["model"]},"face":{"page":"inbox"},
 "record":{"description":"Compose the morning brief and its inbox card from checked native source packets. Return inactive schedule defaults on operation defaults. Publication, consent, claims and delivery belong to the native scheduler.","actions":["calendar.upcoming","mail.recent"],"inputSchema":{"type":"object","required":["operation"],"properties":{"operation":{"type":"string","enum":["defaults","brief"]}}}}}
*/
function run(input) {
    if (input.operation === "defaults") return {
        inbox:[{name:"morning_brief",kind:"time",enabled:false,config:{hour:8,minute:0,notify:true},description:"My own built-in daily brief at the set hour. A helper that sends a brief is separate and listed on Helpers."}],
        notify:{morning_brief:true}
    };
    const current = Date.parse(input.now), yesterday = Date.parse(input.yesterday), label = input.dayLabel;
    const desk = input.desk, log = input.worklog, inbox = input.inbox, sessions = input.sessions;
    const plural = (n, one, many) => n === 1 ? one : many;
    const open = desk.state === "ready" ? desk.statuses.filter(s => ["now","next","blocked","todo","flag","watch"].includes(s)).length : 0;
    const summaries = (log.rows || []).filter(row => {
        const time = Date.parse(row.ts);
        return time >= yesterday && time <= current && row.summary.trim();
    }).map(row => row.summary.trim()).slice(-5);
    const unread = inbox.state === "ready" ? inbox.unread : null;
    let session = null, sessionAvailable = sessions.state === "ready";
    for (const row of sessions.rows || []) {
        if (!row || typeof row !== "object" || Array.isArray(row)) { sessionAvailable = false; continue; }
        if (row.archived === true) continue;
        const at = Date.parse(row.updatedAt);
        if (!Number.isFinite(at)) { sessionAvailable = false; continue; }
        if (session === null || at > session.at) session = {title:typeof row.title === "string" ? row.title.trim() : "",at};
    }
    const unavailable = desk.state !== "ready" || log.state === "unavailable" || unread === null || !sessionAvailable;
    const facts = [];
    if (open > 0) facts.push(open + " open desk " + plural(open,"item","items"));
    if (unread > 0) facts.push(unread + " unread");
    if (summaries.length) facts.push(summaries.length + " log " + plural(summaries.length,"entry","entries") + " since yesterday");
    const counts = facts.length
        ? label + " — " + facts.join(", ") + "." + (unavailable ? " Some sources are unavailable." : "")
        : "Morning brief for " + label + (unavailable
            ? " — some sources are unavailable, so I can't confirm whether anything changed."
            : " — no new activity found in the available sources.");
    const sections = [];
    if (open && desk.body) sections.push("## Desk\n\n" + desk.body);
    if (summaries.length) sections.push("## Since yesterday\n\n" + summaries.map(s => "- " + s).join("\n"));
    if (unread > 0) sections.push("## Inbox\n\n- " + unread + " unread " + plural(unread,"item","items"));
    if (unread === null) sections.push("## Inbox\n\nUnavailable: " + inbox.error);
    if (session && session.title) {
        const delta = (current - session.at) / 1000, total = Math.floor(Math.max(0,delta));
        const days = Math.floor(total / 86400), hours = Math.floor(total % 86400 / 3600), minutes = Math.floor(total % 3600 / 60);
        const age = delta < 60 ? "just now" : (days ? days + "d " + hours + "h" : hours ? hours + "h " + minutes + "m" : minutes + "m") + " ago";
        sections.push("## Last conversation\n\n- " + session.title + " (" + age + ")");
    }
    const lines = [
        "[SYSTEM: You are writing the lead of today's morning brief for " + label + ".]",
        "Objective: Prepare today's concise briefing from canonical calendar, inbox, project, and Desk state. Cite the evidence used, identify unknowns, and surface the completed report in NativeAgent without sending externally unless separately approved.",
        "You may read live context with these tools if they are available: app calendar.upcoming, app mail.recent. " +
          "If a required tool is unavailable or denied, name what remains unknown and the repair it needs.",
        "", "Verified snapshot (newer verified evidence may qualify it; cite the change):", "- Counts: " + counts
    ];
    if (sections.length) lines.push("", sections.join("\n\n"));
    lines.push("", "Say what today looks like, what you would start with, and why. Name the specific item — a brief that could describe any day is worthless. If something is unknown, say it is unknown rather than filling it in.");
    const lead = host.model.call({purpose:"morning_brief",tools:["app"],surface:"workshop",prompt:lines.join("\n")}).trim();
    if (!lead) throw new Error("Morning-brief synthesis returned no lead.");
    // Intl is supplied by JavaScriptCore; cap the card in composed characters,
    // as Swift String.prefix did, retaining the whole lead in detail.
    const characters = Array.from(new Intl.Segmenter("en",{granularity:"grapheme"}).segment(lead), s => s.segment);
    return {title:"Morning brief — " + label,
        summary:characters.length > 400 ? characters.slice(0,400).join("") + "…" : lead,
        detail:lead + (sections.length ? "\n\n---\n\n" + sections.join("\n\n") : ""),
        presentation:{icon:"sun.horizon.fill",badge:"MORNING-BRIEF",words:"Your morning brief",act_label:"Go ahead"},
        actions:[{id:"view",label:"View",description:"See full detail"},{id:"act",label:"Act",description:"Take primary action"},
            {id:"archive",label:"Archive",description:"Archive this item"},{id:"dismiss",label:"Dismiss",description:"Dismiss this item"}]};
}
