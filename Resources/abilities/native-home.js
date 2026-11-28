/* NativeAgent ability
{
  "id": "native-home", "kind": "ability", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection":true},
  "record": {
    "description": "Draw Home's mind, owner facts and named rooms from its packet in layout order.",
    "actions": [], "inputSchema": {"type": "object",
      "required": ["person","order","attention","thoughts","owed","waits","queue","working","people","helpers","senses","elsewhere",
        "places","mac","gaps","keys"]}
  }
}
*/
function face(input) {
    const keys = input.keys;
    const {row} = kit;
    const open = id => (keys[id] || {}).open;
    const LABEL = {"queue.done": "Done", "queue.drop": "Drop", "desk.close": "Close", "agent.read": "Read job"};
    const actions = id => {
        const held = (keys[id] || {}).actions || [];
        return held.length ? held.map(a => row({id: a.id, label: LABEL[a.id] || a.id,
            role: a.id === "queue.done" ? "primary" : a.role,
            aside: a.id === "queue.drop" ? true : undefined})) : undefined;
    };
    const person = input.person;
    const capital = text => text.replace(/(^|\s)(\S)/g, (_, space, first) => space + first.toUpperCase());

    // My mind: whether I am awake, what I last thought about, and what is owed to me.
    const ATTENTION = {
        awake: {title: "Awake", detail: "Last read", tone: "plain"},
        asleep: {title: "Asleep", detail: "Last read", tone: "quiet"},
        unavailable: {title: "Attention unreadable", detail: "No cognition runs, so whether I am awake is not known.", tone: "failed"}
    };
    const OUTCOME = {hit: ["Did something", "done"], empty: ["Let it be", "quiet"], failed: ["Failed", "failed"]};
    const KIND = {returned: "Work returned", moment: "A moment I set", body: "My body", world: "The world", self: "A care of mine"};
    const said = h => h.words + (h.quoted ? " (from an agent's turn)" : "");
    const attention = ATTENTION[input.attention.state] || {title: "Attention: " + input.attention.state, tone: "attention"};
    const mind = [row({id: "attention", title: attention.title, detail: attention.detail, tone: attention.tone, at: input.attention.at})];
    for (const t of input.thoughts) {
        const first = t.attended[0];
        const outcome = OUTCOME[t.outcome] || [t.outcome || "Open", "attention"];
        const more = t.count - t.attended.length;
        const detail = [t.attended.slice(1).map(said).join(" · "), more > 0 ? "+" + more + " more" : ""].filter(Boolean).join(" · ");
        mind.push(row({id: t.id, title: first ? said(first) : (t.node || t.kind || "A thought"),
            detail: detail || null,
            value: t.mattered ? "Mattered" : outcome[0], at: t.at, tone: t.mattered ? "done" : outcome[1]}));
    }
    const owed = input.owed.rows.map(h => row({id: h.id, title: said(h),
        detail: [KIND[h.kind] || h.kind, h.returns ? "returns to the conversation that started it" : ""].filter(Boolean).join(" · "),
        at: h.at, tone: "attention"}));
    if (input.owed.count > owed.length) owed.push({id: "owed:more", title: "+" + (input.owed.count - owed.length) + " more owed", tone: "quiet"});

    const sections = [{id: "mind", title: "My mind", style: "list",
        footer: "My latest thoughts from the record; Thoughts holds them all.", rows: mind.concat(gaps("mind"))}];
    if (owed.length) sections.push({id: "owed", title: "Owed to me", style: "list",
        footer: "Returns, moments I set and my body's asks, each opening a thought.", rows: owed});

    const PEOPLE = {
        unread: c => ["Exchange not read yet", "attention"], unavailable: c => ["Exchange unavailable", "attention"],
        send_failed: c => ["Send failed", "failed"], problem: c => [c.problem, "failed"], ready: c => ["Ready", "plain"],
        replied_in_chat: c => ["Replied in chat", "done"], replied: c => ["Replied", "done"], waiting: c => ["Waiting", "attention"],
        asks_input: c => ["Asks for input", "attention"], send_unconfirmed: c => ["Send unconfirmed", "attention"],
        needs_attention: c => ["Needs attention", "attention"], sent: c => ["Sent", "plain"], none: c => ["No recorded exchange", "quiet"],
        execution: c => ["Execution: " + c.execution.run + (c.execution.delivery ? " · delivery: " + c.execution.delivery : "")
            + (c.execution.failed ? " · execution error recorded" : ""), c.execution.failed ? "failed" : "plain"]
    };
    const HELPER = {unread: ["Run queue not read", "attention"], running: ["Running or queued", "attention"], never: ["Never run", "quiet"]};
    const QUEUE_STATE = {
        ready: "Ready", blocked: "Blocked", deferred: "Deferred", stopped: "Stopped",
        conditions: "Waiting on conditions", conditions_unavailable: "Conditions unavailable",
        cycle: "Blocked by cycle", waits: "Waiting", unread: "Not read yet", unavailable: "Unavailable"
    };
    const BODY_OWNER = {agent: "Upkeep", builder: "Builder", owner: "Waits on " + person};
    const repair = r => row({id: r.key, title: r.title, detail: r.detail, value: r.state, at: r.at, tone: "attention", open: open(r.key)});

    const draw = {
        notable: () => input.mail ? [row({id: input.mail.key, title: "Last Mail read", detail: input.mail.words, at: input.mail.at,
            open: open(input.mail.key)})] : [],
        waits: () => input.waits.map(w => w.kind === "repair" ? repair(w)
            : w.kind === "desk" ? row({id: w.key, title: w.title, value: "Waits on " + person, at: w.at, tone: "attention", open: open(w.key)})
            : row({id: w.key, title: w.title, detail: w.detail, at: w.at, tone: "attention", open: open(w.key)})),
        queue: () => input.queue.filter(q => q.kind !== "repair").map(q => {
            if (q.kind === "step" || q.kind === "blocked" || q.kind === "body") {
                const value = q.when || (q.state ? (QUEUE_STATE[q.state] || q.state)
                    : q.kind === "blocked" ? "Blocked" : BODY_OWNER[q.assignee] || "Upkeep");
                const detail = q.detail || q.blockedReason
                    || (Array.isArray(q.blockers) && q.blockers.length ? q.blockers.join(" · ") : null)
                    || (Array.isArray(q.waitsOn) && q.waitsOn.length ? "Waiting on " + q.waitsOn.join(", ") : null);
                return row({id: q.key, title: q.title, detail, value, open: open(q.key), actions: actions(q.key)});
            }
            if (q.kind === "reviews") return row({id: q.key, title: "Memories to review", detail: "Waiting for Keep or Don't keep",
                value: q.count + (q.capped ? "+" : ""), open: open(q.key)});
            if (q.kind === "input") return row({id: q.key, title: q.name, value: "Asks for input", at: q.at, tone: "attention",
                open: open(q.key)});
            return repair(q);
        }),
        working: () => input.working.map(j => row({id: j.key, title: j.title, detail: j.name, value: j.state, at: j.at, tone: "live",
            actions: actions(j.key)})),
        people: () => input.people.map(p => {
            if (p.kind === "found") return row({id: p.key, title: "Found " + p.name,
                detail: p.app ? "No recipe yet; tell me in chat to look." : "Tell me in chat to connect.", at: p.at, tone: "attention",
                open: open(p.key)});
            const [value, tone] = (PEOPLE[p.state] || (() => [p.state, "attention"]))(p);
            return row({id: p.key, title: p.name, detail: p.about, value, at: p.at, tone, open: open(p.key)});
        }),
        helpers: () => input.helpers.map(h => {
            const [status, tone] = HELPER[h.state] || [h.state, h.failed ? "failed" : "plain"];
            return row({id: h.key, title: h.name, detail: h.detail, value: status + (h.paused ? " · paused" : ""), at: h.at, tone,
                open: open(h.key)});
        }),
        senses: () => input.senses.map(s => s.failure
            ? row({id: s.key, title: "Sense source unavailable", detail: s.failure, tone: "failed", open: open(s.key)})
            : row({id: s.key, title: s.words, at: s.at, open: open(s.key)})),
        elsewhere: () => input.elsewhere.map(e => row({id: e.key, title: e.door, detail: e.who, at: e.at, open: open(e.key)})),
        places: () => input.places.map(p => row({id: p.key, title: p.name, detail: p.detail, at: p.at, open: open(p.key)})),
        mac: () => input.mac.map(m => row({id: m.key, title: m.app, detail: m.about, value: m.readout, at: m.at, open: open(m.key)}))
    };
    const TITLE = {notable: "Notable", waits: capital(person) + " waits", queue: "My queue", working: "Working",
        people: "People", helpers: "Helpers", senses: "My senses", elsewhere: "Elsewhere", places: "Places", mac: "Mac"};
    const EMPTY = {
        waits: "Nothing waiting on " + person + ".", queue: "Nothing queued.", working: "Nothing running.",
        people: "No recent people.", helpers: "No helpers.", senses: "No senses.",
        elsewhere: "No recent messages elsewhere.", places: "No recent places.", mac: "No recent Mac reads."
    };
    const COVERAGE = {
        notable: "Prior Mail previews, not a current inbox scan.",
        waits: "Desk, inbox asks and repairs; approvals stand above, yours to decide; no fresh calendar, reminders or Mail read.",
        queue: "Queued Desk steps, reviews and handoffs; not all of my own activity.",
        working: "Jobs and lines at work; agent.jobs lists them all.",
        people: "Contacts, exchanges, discovery offers and local health; no full Doctor check.",
        helpers: "Definitions, latest shelf results and run queue; not full run history.", senses: "Abilities, senses and watches at the last read.",
        elsewhere: "Latest speakers across recent transcripts; not a complete activity log.",
        places: "Navigation, Chrome connection and prior read badges; browser tabs stay with their conversation.",
        mac: "Recorded reads/actions retained at their last write; no fresh window content."
    };
    function gaps(name) {
        return (input.gaps[name] || []).map(g => g.failure
            ? {id: name + ":failed:" + g.source, title: g.source + " unavailable", detail: g.failure, tone: "failed"}
            : g.at ? {id: name + ":stale:" + g.source, title: g.source + " is refreshing",
                detail: "Showing its last reading.", at: g.at, tone: "attention"}
            : {id: name + ":unread:" + g.source, title: g.source + " not read yet",
                detail: "This section is incomplete until its first reading lands.", tone: "attention"});
    }
    for (const name of input.order) {
        if (!draw[name]) continue;
        const warnings = gaps(name);
        if (name === "notable" && input.layoutFailure) warnings.push({id: "layout.failed", title: "Layout unavailable", detail: input.layoutFailure,
            tone: "failed"});
        let body = draw[name]().slice(0, Math.max(0, 256 - warnings.length)).concat(warnings);
        if (name === "notable" && !body.length) continue;
        if (!body.length) body = [{id: name + ":empty", title: EMPTY[name] || "Nothing here yet.", tone: "quiet"}];
        sections.push({id: name, title: TITLE[name], style: "list", footer: COVERAGE[name], rows: body.slice(0, 256)});
        if (name === "queue") {
            const repairs = input.queue.filter(q => q.kind === "repair").map(repair);
            if (repairs.length) {
                sections.push({id: "repairs", title: "Owed repairs", style: "list",
                    footer: "Unfinished repair obligations filed from prior failures.", rows: repairs.slice(0, 256)});
            }
        }
    }
    return row({title: input.agent, line: "Where I am, what waits and what is within reach.", sections: sections.slice(0, 64)});
}
