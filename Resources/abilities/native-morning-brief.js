/* NativeAgent ability
{"id":"native-morning-brief","kind":"ability","version":1,
 "reach":{"capabilities":["model"]},"face":{"page":"inbox"},
 "record":{"description":"Compose the morning brief and its inbox card from checked native source packets. Return inactive schedule defaults on operation defaults. Publication, consent, claims and delivery belong to the native scheduler.","actions":["calendar.upcoming","mail.recent","workshop.status"],"inputSchema":{"type":"object","required":["operation"],"properties":{"operation":{"type":"string","enum":["defaults","brief"]}}}}}
*/
function run(input) {
    if (input.operation === "defaults") return {
        inbox:[{name:"morning_brief",kind:"time",enabled:false,config:{hour:8,minute:0,notify:true},description:"Daily morning brief at configured hour."}],
        workshop:[{name:"morning_brief",kind:"time",config:{hour:8,minute:0},objective:"Read calendar + email summary, draft a morning brief",title:"Morning Brief",trust_required:"send_approval",enabled:false}],
        notify:{morning_brief:true}
    };
    const current = Date.parse(input.now), yesterday = Date.parse(input.yesterday), label = input.dayLabel;
    const desk = input.desk, log = input.worklog, workshop = input.workshop, inbox = input.inbox, sessions = input.sessions;
    const plural = (n, one, many) => n === 1 ? one : many;
    const open = desk.state === "ready" ? desk.statuses.filter(s => ["now","next","blocked","todo","flag","watch"].includes(s)).length : 0;
    const summaries = (log.rows || []).filter(row => {
        const time = Date.parse(row.ts);
        return time >= yesterday && time <= current && row.summary.trim();
    }).map(row => row.summary.trim()).slice(-5);
    let active = 0, moved = 0, workshopAvailable = workshop.state === "ready";
    for (const row of workshop.rows || []) {
        const status = row && typeof row.status === "string" ? row.status.toLowerCase() : "";
        if (!status || status === "corrupt") { workshopAvailable = false; continue; }
        if (!["done","completed","failed","canceled","cancelled"].includes(status)) active++;
        if (["completedAt","completed_at","updatedAt","updated_at"].some(key => {
            const time = typeof row[key] === "string" ? Date.parse(row[key]) : NaN;
            return time >= current - 86400000 && time <= current;
        })) moved++;
    }
    let unread = null;
    if (inbox.state === "ready") {
        const latest = new Map();
        let valid = true;
        for (const row of inbox.rows) {
            if (!row || typeof row.id !== "string") { valid = false; break; }
            latest.set(row.id, typeof row.status === "string" ? row.status.toLowerCase() : "unread");
        }
        if (valid) unread = Array.from(latest.values()).filter(s => s === "unread").length;
    }
    let session = null, sessionAvailable = sessions.state === "ready";
    for (const row of sessions.rows || []) {
        if (!row || typeof row !== "object" || Array.isArray(row)) { sessionAvailable = false; continue; }
        if (row.archived === true) continue;
        const at = Date.parse(row.updatedAt);
        if (!Number.isFinite(at)) { sessionAvailable = false; continue; }
        if (session === null || at > session.at) session = {title:typeof row.title === "string" ? row.title.trim() : "",at};
    }
    const unavailable = desk.state !== "ready" || log.state === "unavailable" || !workshopAvailable || unread === null || !sessionAvailable;
    const facts = [];
    if (open > 0) facts.push(open + " open desk " + plural(open,"item","items"));
    if (moved > 0) facts.push(moved + " Workshop " + plural(moved,"task","tasks") + " moved");
    else if (active > 0) facts.push(active + " Workshop " + plural(active,"task","tasks") + " active");
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
    if (active || moved) sections.push("## Workshop\n\n- " + active + " active\n- " + moved + " moved in the last 24h");
    if (unread > 0) sections.push("## Inbox\n\n- " + unread + " unread " + plural(unread,"item","items"));
    if (session && session.title) {
        const delta = (current - session.at) / 1000, total = Math.floor(Math.max(0,delta));
        const days = Math.floor(total / 86400), hours = Math.floor(total % 86400 / 3600), minutes = Math.floor(total % 3600 / 60);
        const age = delta < 60 ? "just now" : (days ? days + "d " + hours + "h" : hours ? hours + "h " + minutes + "m" : minutes + "m") + " ago";
        sections.push("## Last conversation\n\n- " + session.title + " (" + age + ")");
    }
    const lines = [
        "[SYSTEM: You are writing the lead of today's morning brief for " + label + ".]",
        "Objective: Prepare today's concise briefing from canonical calendar, inbox, project, and Desk state. Cite the evidence used, identify unknowns, and surface the completed report in NativeAgent without sending externally unless separately approved.",
        "You may read live context with these tools if they are available: app calendar.upcoming, app mail.recent, app workshop.status. If a required tool is unavailable or denied, name what remains unknown and the repair it needs.",
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
