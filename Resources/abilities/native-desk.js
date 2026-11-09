/* NativeAgent ability
{
  "id": "native-desk", "kind": "ability", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection":true},
  "record": {
    "description": "Draw the Desk from its packet: the selection, the board grouped by what each item waits on, other work, lines, timers and source gaps.",
    "actions": [], "inputSchema": {"type": "object",
      "required": ["items","keys","unavailable","activity","overview","jobs","timedHelpers","missedHelpers","timers","deferPresets","selected"]}
  }
}
*/
function run(input) {
    return face(input);
}
function face(input) {
    const keys = input.keys;
    const STATUS = {now:"now",next:"next",blocked:"blocked",flag:"needs attention",done:"done",todo:"to do",watch:"watching",canceled:"cancelled"};
    const ACTIVITY = {working:"Working",queued:"Queued",watching:"Watching",deferred:"Deferred",blocked:"Blocked",
        stale:"Stale — activity unconfirmed",unknown:"Activity unknown",finished:"Finished"};
    const terminal = item => item.status === "done" || item.status === "canceled";
    const trimmed = text => text === null ? "" : text.trim();
    // A row keeps only the fields it has; an empty action list stays, as the stem drew it.
    const row = fields => Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== null && value !== undefined));
    // A character is what the reader sees as one (a grapheme cluster), as the stem counts it; Intl is supplied by JavaScriptCore.
    const graphemes = new Intl.Segmenter("en", {granularity: "grapheme"});
    const characters = text => Array.from(graphemes.segment(text), s => s.segment);
    function plain(raw) {
        return raw.trim().replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map(rawLine => {
            let line = rawLine.trim(), heading = false;
            while (/^[#>]/.test(line)) { heading = heading || line[0] === "#"; line = line.slice(1).trim(); }
            if (heading && line && !/[.!?:]$/.test(line)) line += ".";
            for (const bullet of ["- ", "* ", "+ "]) if (line.startsWith(bullet)) line = line.slice(bullet.length);
            return line.replace(/[*\x60\\]/g, "").trim();
        }).filter(Boolean).join(" ").trim();
    }
    function bounded(text, limit) {
        const chars = characters(text);
        if (chars.length <= limit) return text;
        const window = chars.slice(0, limit);
        let stop = -1;
        window.forEach((c, i) => { if (c === "." || c === "!" || c === "?") stop = i; });
        if (stop >= Math.floor(limit / 2)) return window.slice(0, stop + 1).join("");
        const space = window.lastIndexOf(" "), head = space >= 0 ? window.slice(0, space).join("").trim() : "";
        return (head || window.join("")) + "…";
    }
    const line = (text, limit) => bounded(plain(text), limit);
    const ones = ["zero","one","two","three","four","five","six","seven","eight","nine","ten","eleven","twelve","thirteen","fourteen",
        "fifteen","sixteen","seventeen","eighteen","nineteen"];
    const tens = ["","","twenty","thirty","forty","fifty","sixty","seventy","eighty","ninety"];
    function lower(n) {
        if (n < 20) return ones[n];
        if (n < 100) return n % 10 === 0 ? tens[Math.floor(n / 10)] : tens[Math.floor(n / 10)] + "-" + ones[n % 10];
        if (n < 1000) {
            const hundreds = Math.floor(n / 100), head = hundreds === 1 ? "a hundred" : ones[hundreds] + " hundred";
            return n % 100 === 0 ? head : head + " and " + lower(n % 100);
        }
        return String(n);
    }
    const spelled = n => n < 0 ? String(n) : lower(n);
    const capitalized = text => text.replace(/(^|\s)(\S)(\S*)/g, (_, space, first, rest) => space + first.toUpperCase() + rest.toLowerCase());
    const byCodePoint = (a, b) => {
        const x = Array.from(a, c => c.codePointAt(0)), y = Array.from(b, c => c.codePointAt(0));
        for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
        return x.length - y.length;
    };
    const descending = (a, b) => a === b ? 0 : (a > b ? -1 : 1);
    const ascending = (a, b) => a === b ? 0 : (a < b ? -1 : 1);
    const ACTION = {
        reply: item => item.requiresOwnerInput ? "Reply" : "Discuss",
        close: item => item.requiresOwnerInput ? "Already handled" : "Close",
        note: () => "Note", unpark: () => "Un-park"
    };
    const keyActions = (id, label) => ((keys[id] || {}).actions || []).map(a => row({id: a.id, label: label(a.id), role: a.role}));
    const open = id => (keys[id] || {}).open;
    const back = {id: "desk-selection", title: "Board", actions: [{id: "board", label: "Back to the board"}]};

    const items = input.items.slice().sort((a, b) =>
        descending(a.updatedAt, b.updatedAt) || descending(a.openedAt, b.openedAt) || ascending(a.handle, b.handle));
    const sections = [];

    // The selected item or execution, as the board opened it.
    const selected = input.selected;
    if (selected !== null && selected.kind === "execution") {
        sections.push(selected.found
            ? {id: "selected-execution", title: selected.title, style: "values", rows: [row({id: "execution-detail:" + selected.id,
                title: selected.text, detail: selected.asking === null ? null : "Asking: " + selected.asking, value: selected.state,
                at: selected.at}), back]}
            : {id: "selected-unavailable", title: "Work details", style: "values", rows: [{id: "selected-missing",
                title: selected.unavailable === null ? "This execution is not in the current reading. Refresh the Desk to read it again."
                    : selected.unavailable, tone: "attention"}, back]});
    } else if (selected !== null && !selected.found) {
        sections.push({id: "selected-unavailable", title: "Item details", style: "values", rows: [{id: "selected-missing",
            title: selected.unavailable === null ? "This item is not in the current reading. Refresh the Desk to read it again."
                : selected.unavailable, tone: "attention"}, back]});
    } else if (selected !== null) {
        const s = selected, rows = [row({id: "item-detail:" + s.handle, title: s.title,
            value: [s.alias, s.itemKind, STATUS[s.status], s.project, "added by " + s.origin].join(" · "), at: s.updatedAt})];
        if (s.summary !== null && s.summary !== "") rows.push({id: "summary", title: s.summary});
        if (s.assignee !== null) rows.push({id: "assignee", title: "Assigned to", value: s.assignee});
        if (s.progress !== null) rows.push(row({id: "progress", title: "Progress", detail: s.progress.note,
            value: s.progress.done + " of " + s.progress.total}));
        if (s.blockedReason !== null && s.blockedReason !== "") rows.push({id: "blocked-reason", title: "Blocked: " + s.blockedReason, tone: "attention"});
        if (s.waitingOn !== null && s.waitingOn !== "") rows.push({id: "waiting-on", title: "Waiting on " + s.waitingOn, tone: "attention"});
        if (s.plan !== null) {
            if (s.plan.total > 0) rows.push({id: "rollup", title: "Steps closed", value: s.plan.done + "/" + s.plan.total});
            for (const b of s.plan.blockers) rows.push(row({id: "blocker:" + b.handle, title: "Waiting on " + (b.alias === null ? b.handle : b.alias),
                detail: b.title, tone: "attention", open: open("blocker:" + b.handle)}));
            if (s.plan.cycle) rows.push({id: "cycle", title: "These items block each other.", tone: "attention"});
            if (s.plan.deferred) rows.push(row({id: "deferred", title: "Deferred until", at: s.deferAt}));
            if (s.nextUp) rows.push({id: "next-up", title: "Start here"});
        }
        const p = s.pursuit;
        if (p !== null && p.state === "unavailable") {
            rows.push({id: "pursuit-unavailable", title: "Project details unavailable",
                detail: "The saved project details need to be repaired before you can act on them.", tone: "attention"});
        } else if (p !== null) {
            rows.push({id: "pursuit-why", title: p.why}, {id: "pursuit-done", title: "Done when: " + p.doneWhen},
                {id: "pursuit-sessions", title: "Sessions", value: p.sessionsUsed + "/" + p.maxSessions},
                p.sessionsToday === null ? {id: "pursuit-today", title: "Today's sessions unavailable", tone: "attention"}
                    : {id: "pursuit-today", title: "Sessions today", value: String(p.sessionsToday)});
            if (p.lastWorkedAt !== null) rows.push({id: "pursuit-last", title: "Last worked", at: p.lastWorkedAt});
            if (p.score !== null) rows.push({id: "pursuit-score", title: "Score", value: p.score.toFixed(2)});
        }
        s.notes.forEach((note, i) => rows.push({id: "note:" + i, title: note.text, at: note.at}));
        for (const ref of s.refs.slice().sort((a, b) => a.priority - b.priority)) {
            const id = "ref:" + ref.id;
            rows.push(open(id) ? {id, title: ref.label, open: open(id)}
                : {id, title: ref.label, detail: ref.text, actions: [{id: "copy-reference", label: "Copy reference"}]});
        }
        for (const action of ["reply", "close", "note", "unpark"]) {
            const id = "item-action:" + action;
            if (keys[id]) rows.push({id, title: ACTION[action](s), actions: keyActions(id, a => ACTION[a](s))});
        }
        // The person's Veto rides this row; the stem draws its action.
        if (s.vetoable) rows.push({id: "item-action:veto", title: "Veto"});
        for (const preset of input.deferPresets) {
            const id = "item-action:defer:" + preset.id;
            if (keys[id]) rows.push(row({id, title: "Defer until", at: preset.at, actions: keyActions(id, () => "Defer")}));
        }
        rows.push(back);
        sections.push({id: "selected-item", title: s.title, style: "values", rows});
    }

    sections.push({id: "desk-tools", style: "flow", rows: [["refresh", "Refresh"], ["find-item", "Find item"], ["new-task", "New task"],
        ["research", "Look something up"]].map(([id, label]) =>
        ({id: "desk:" + id, title: label, actions: keyActions("desk:" + id, () => label)}))});

    const gone = input.unavailable, gaps = [gone.desk, gone.jobs, gone.reminders, gone.helpers, gone.liveUpdates, gone.schedule]
        .filter(gap => gap !== null).concat(gone.overview);
    if (input.activity.state === "unavailable") gaps.push("Live activity: " + input.activity.reason);
    if (!input.loaded) gaps.push("The Desk has not been read.");
    if (!input.scheduleRead) gaps.push("The schedule has not returned a reading.");
    if (gaps.length) sections.push({id: "source-gaps", title: "Unavailable readings", style: "note",
        rows: [...new Set(gaps)].sort(byCodePoint).map((title, i) => ({id: "source-gap:" + i, title, tone: "attention"}))});
    if (input.activity.state === "rows") {
        const stale = input.activity.stale;
        sections.push({id: "live-reading", title: "Live activity", style: "timeline", rows: [row({id: "live-reading",
            title: stale ? "This reading is stale." : "Board reading", at: input.generatedAt, tone: stale ? "attention" : "quiet"})]});
    }

    // The board: each item in the one group that says what it waits on.
    const byHandle = new Map();
    for (const item of input.items) if (!byHandle.has(item.handle)) byHandle.set(item.handle, item);
    const ready = item => item.plan === null || item.plan.ready;
    const families = new Set();
    if (gone.jobs === null) {
        const lanes = new Map();
        for (const item of input.items) {
            const parent = trimmed(item.laneOf);
            if (!parent || parent === item.handle || !byHandle.has(parent)) continue;
            lanes.set(parent, (lanes.get(parent) || []).concat([item]));
        }
        for (const parent of input.items) {
            const family = lanes.get(parent.handle);
            if (family && [parent].concat(family).some(i => !i.requiresOwnerInput && i.activity === "working")) families.add(parent.handle);
        }
    }
    const isProject = item => gone.desk === null && !terminal(item) && item.parent === null && ["project", "plan"].includes(item.kind)
        && ["now", "next", "todo"].includes(item.status) && !item.requiresOwnerInput
        && !(item.status === "blocked" || item.status === "flag" || (item.waitingOn !== null && item.waitingOn !== ""))
        && !families.has(item.handle);
    function projectLine(item) {
        const named = (item.plan === null ? [] : item.plan.blockers).map(h => byHandle.get(h)).filter(Boolean).map(i => i.title);
        if (named.length) {
            const more = named.length - 1;
            return "Held by " + line(named[0], 70) + (more > 0 ? " and " + spelled(more) + " more." : ".");
        }
        const kids = input.items.filter(kid => kid.parent === item.handle && !terminal(kid) && ready(kid));
        for (const status of ["now", "next", "todo"]) {
            const next = kids.find(kid => kid.status === status);
            if (next) return "Next: " + line(next.title, 80) + ".";
        }
        if (trimmed(item.summary)) return line(item.summary, 96);
        return "No next step written down yet.";
    }
    function stuckReason(item) {
        if (trimmed(item.blockedReason)) return line(item.blockedReason, 96);
        if (trimmed(item.waitingOn)) return "Waiting on " + line(item.waitingOn, 60) + ".";
        const blockers = items.filter(i => item.blockedOn.includes(i.handle) && !terminal(i));
        if (blockers.length) return "Blocked on " + blockers.map(i => "desk." + i.alias).join(", ") + ".";
        if (trimmed(item.lastNote)) return "Last note: " + line(item.lastNote, 96);
        return "Blocked, with no reason written down.";
    }
    function itemDetail(item) {
        if (item.status === "blocked") return stuckReason(item);
        if (trimmed(item.summary)) return line(item.summary, 96);
        if (item.status === "flag") return "Flagged for a second look.";
        return capitalized(STATUS[item.status]);
    }
    function group(item) {
        if (terminal(item)) return item.closedToday ? "done-today" : "history";
        if (item.requiresOwnerInput || item.status === "blocked" || item.status === "flag") return "waiting";
        if (item.deferred || (isProject(item) && item.parked)) return "parked";
        if (item.activity === "working" || item.status === "now") return "now";
        if (item.status === "watch" || item.kind === "watch") return "watching";
        return "queued";
    }
    function tone(item) {
        if (item.requiresOwnerInput || item.status === "flag") return "attention";
        return {working: "live", blocked: "attention", stale: "attention", finished: "done", queued: "plain"}[item.activity] || "quiet";
    }
    for (const [id, title] of [["now", "Now"], ["waiting", "Waiting"], ["queued", "Queued"], ["watching", "Watching"], ["parked", "Parked"],
        ["done-today", "Done today"], ["history", "Finished history"]]) {
        const rows = items.filter(item => group(item) === id).map(item => {
            const detail = [item.project, isProject(item) ? projectLine(item) : itemDetail(item), ACTIVITY[item.activity]];
            if (item.plan !== null && item.plan.total > 0) detail.push(item.plan.done + " of " + item.plan.total + " closed");
            return row({id: item.handle, title: line(item.title, 110) || item.handle, detail: detail.join(" · "), value: STATUS[item.status],
                at: item.updatedAt, tone: tone(item), open: open(item.handle), actions: keyActions(item.handle, a => ACTION[a](item))});
        });
        if (rows.length) sections.push({id, title, style: "list", rows});
    }
    if (!items.length && input.boardRead && gone.desk === null) {
        sections.push({id: "empty-board", style: "note", rows: [{id: "empty", title: "No items on the board."}]});
    }

    // Other work the overview reads, apart from what the board already shows.
    if (input.overview !== null) {
        const onBoard = new Set(input.items.map(item => item.handle));
        for (const [id, title, source] of [["work-now", "Other work now", input.overview.now], ["attention", "Needs you", input.overview.needsYou],
            ["recent-work", "Recently done", input.overview.recentlyDone]]) {
            const rows = source.rows.filter(r => r.kind !== "execution" && (r.kind !== "desk" || !onBoard.has(r.ref))).map(r => row({id: r.id,
                title: r.title, detail: r.summary, value: r.state, at: r.at,
                tone: id === "attention" ? "attention" : id === "recent-work" ? "done" : "plain", open: open(r.id)}));
            if (rows.length || source.omitted > 0) sections.push(row({id, title, style: "timeline",
                footer: source.omitted > 0 ? source.omitted + " more items remain in the board, Activity and history." : null, rows}));
        }
    }
    const jobs = input.jobs.slice().sort((a, b) => descending(a.at, b.at) || ascending(a.id, b.id));
    if (jobs.length) sections.push({id: "lines", title: "Work and finished lines", style: "timeline", rows: jobs.map(job => ({id: job.id,
        title: job.title, detail: job.summary, value: job.state, at: job.at, tone: job.terminal ? "done" : job.needsYou ? "attention" : "plain",
        actions: keyActions(job.id, () => "Read details")}))});

    function scheduleLine(timer) {
        if (timer.once !== null) return timer.enabled ? timer.once : timer.once + " Paused.";
        if (!timer.enabled) return "Paused.";
        const seconds = timer.intervalSeconds;
        if (seconds === null || seconds <= 0) return "On its own schedule.";
        if (seconds % 86400 === 0) { const days = seconds / 86400; return days === 1 ? "Once a day." : "Every " + spelled(days) + " days."; }
        if (seconds % 3600 === 0) { const hours = seconds / 3600; return hours === 1 ? "Every hour." : "Every " + spelled(hours) + " hours."; }
        const minutes = Math.max(1, Math.floor(seconds / 60));
        return minutes === 1 ? "Every minute." : "Every " + spelled(minutes) + " minutes.";
    }
    const timers = input.timedHelpers.map(bot => row({id: "timer-bot:" + bot.id, title: bot.name, detail: bot.line, at: bot.at,
        open: open("timer-bot:" + bot.id)}))
        .concat(input.missedHelpers.map(bot => row({id: "missed-bot:" + bot.id, title: bot.name, detail: bot.line, at: bot.at,
            tone: "attention", open: open("missed-bot:" + bot.id)})))
        .concat(input.timers.map(timer => row({id: "timer-job:" + timer.id, title: timer.name, detail: scheduleLine(timer), at: timer.at,
            tone: timer.enabled ? "plain" : "quiet"})));
    if (!timers.length && gone.helpers === null && input.scheduleCurrent) timers.push({id: "no-timers", title: "Nothing on a timer."});
    sections.push({id: "schedule", title: "On a timer", style: "list", rows: timers});
    if (input.night) {
        const dream=input.night.dream;
        const dreamPart=dream.state === "off" ? "Dreams are off."
            : dream.state === "unavailable" ? "Dream setting unavailable: "+dream.reason : undefined;
        sections.push({id: "night", title: "The night", style: "list", rows: [row({id: "night-reading",
            title: input.night.reason, detail: dreamPart,
            at: Number.isFinite(input.night.at) ? new Date(input.night.at * 1000).toISOString() : undefined,
            tone: input.night.state === "unavailable" || dream.state === "unavailable" ? "attention" : "quiet"})]});
    }

    // The hour's latest thought outcome shares the Desk's timeline.
    const hour = input.wanderHour;
    if (hour !== null) sections.push({id: "wander-hour", style: "timeline", rows: [row({id: "wander-hour", title: hour.text, at: hour.at,
        symbol: hour.symbol})]});
    return row({title: "Desk", line: input.headline, sections});
}
