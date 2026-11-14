/* NativeAgent ability
{
  "id": "native-desk", "kind": "ability", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection":true},
  "record": {
    "description": "Draw the Desk from its packet: what is on the table, the selection, the board by what each waits on, other work, lines, timers and gaps.",
    "actions": [], "inputSchema": {"type": "object",
      "required": ["items","keys","unavailable","activity","jobs","timedHelpers","missedHelpers","timers","deferPresets"]}
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
    // "watch" is the status every item starts with, before anyone sets one. Only a watch is watching; anything else has no status to say yet.
    const said = (status, kind) => status === "watch" && kind !== "watch" ? null : STATUS[status];
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
    // A step's column on its item's board, and the moves each column offers: a step not under way starts, an open one is done.
    const COLUMNS = [["now", "Now"], ["next", "Next"], ["waiting", "Waiting"], ["done", "Done"]];
    const MOVE = {start: "Start", close: "Done"};
    const MOVES = {now: ["close"], next: ["start", "close"], waiting: ["start", "close"], done: []};
    // A column is read at a glance and never passes a section's 256 rows: Done shows the latest few, the open columns their first 64.
    const COLUMN_ROWS = {now: 64, next: 64, waiting: 64, done: 8};
    // An item an open dependency holds, or a cycle of them, is waiting whatever status it was left in.
    function held(item) { return item.plan !== null && (item.plan.blockers.length > 0 || item.plan.cycle); }
    function column(step) {
        if (terminal(step)) return "done";
        if (step.requiresOwnerInput || step.status === "blocked" || step.status === "flag" || trimmed(step.waitingOn) || held(step)) {
            return "waiting";
        }
        if (step.activity === "working" || step.status === "now") return "now";
        return "next";
    }
    // Steps keep their plan's order: "3.2" before "3.10".
    const byAlias = (a, b) => {
        const x = a.split("."), y = b.split(".");
        for (let i = 0; i < Math.min(x.length, y.length); i++) {
            const m = Number(x[i]), n = Number(y[i]);
            const order = Number.isNaN(m) || Number.isNaN(n) ? byCodePoint(x[i], y[i]) : m - n;
            if (order) return order;
        }
        return x.length - y.length;
    };
    const keyActions = (id, label) => ((keys[id] || {}).actions || []).map(a => row({id: a.id, label: label(a.id), role: a.role}));
    const open = id => (keys[id] || {}).open;
    const back = {id: "desk-selection", title: "Board", actions: [{id: "board", label: "Back to the board"}]};

    // A piece is something I made, laid on an item. A person reads its own title and what it is; the agent at the door reads its Make
    // ref and the two calls that work on it.
    const PIECE_ACTION = {"open-piece": "Open in Make", "copy-reference": "Copy reference"};
    const WHAT = {picture: "a picture", page: "a page", document: "a document", sheet: "a table", file: "a file"};
    const pieceTitle = piece => piece.title === null ? "Something I made" : piece.title;
    const versionsLine = n => n === 1 ? "one version" : spelled(n) + " versions";
    function pieceLine(piece) {
        if (piece.state === "waiting") return "Waiting on Make.";
        if (piece.state === "missing") return "I can't find this in Make any more.";
        if (piece.state === "unavailable") return piece.reason;
        const what = WHAT[piece.what];
        return what[0].toUpperCase() + what.slice(1) + " · " + versionsLine(piece.versions);
    }
    function pieceDoor(piece) {
        return pieceTitle(piece) + " is " + WHAT[piece.what] + " I made, " + versionsLine(piece.versions) + ", in Make as " + piece.ref
            + ". make.read " + JSON.stringify({ref: piece.ref}) + " gives its file path and versions; make.add "
            + JSON.stringify({path: "<file>", ref: piece.ref}) + " lays a new version.";
    }
    // A table reads as its size and its first rows; the person changes its cells in the window, each change a new version.
    const counted = (n, one) => (n === 1 ? "one " + one : spelled(n) + " " + one + "s");
    function sheetDoor(piece) {
        const t = piece.table;
        const size = t === undefined ? "" : ", " + counted(t.rows, "row") + " by " + counted(t.columns, "column");
        return pieceTitle(piece) + " is a table I made" + size + ", " + versionsLine(piece.versions) + ", in Make as " + piece.ref
            + ". make.read " + JSON.stringify({ref: piece.ref}) + " gives its file path and versions; make.add "
            + JSON.stringify({content: "<the whole table>", name: t === undefined ? "<name>.csv" : t.file, ref: piece.ref})
            + " lays a new version; a version the person changed by hand reads person_edit_of there."
            + (t === undefined ? " " + piece.reason : " Its first rows:\n" + utf8Fit(t.first, 4096).text);
    }
    const pieceTone = piece => piece.state === "missing" || piece.state === "unavailable" ? "attention" : null;
    const thingsLine = n => (n === 1 ? "one thing" : spelled(n) + " things") + " on the table";
    // A page's inline words are at most 16 KiB of UTF-8; a cut falls between characters.
    function utf8Fit(text, limit) {
        let used = 0, end = 0;
        for (const c of text) {
            const point = c.codePointAt(0), size = point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
            if (used + size > limit) return {text: text.slice(0, end), cut: true};
            used += size; end += c.length;
        }
        return {text, cut: false};
    }

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
            value: [s.alias, s.itemKind, said(s.status, s.itemKind), s.project,
                // "owner" is what every item is recorded as unless it is my own pursuit, so it says nothing about who added it.
                s.origin === "owner" ? null : "added by " + s.origin].filter(part => part !== null && part !== "").join(" · "), at: s.updatedAt})];
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
            if (s.nextUp) rows.push({id: "next-up", title: "This is next up."});
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
        const pieces = new Map(s.pieces.map(piece => [piece.id, piece]));
        for (const ref of s.refs.slice().sort((a, b) => a.priority - b.priority)) {
            const id = "ref:" + ref.id, piece = pieces.get(ref.id);
            rows.push(piece ? row({id, title: pieceTitle(piece), detail: pieceLine(piece), at: piece.newestAt, tone: pieceTone(piece),
                    actions: keyActions(id, a => PIECE_ACTION[a])})
                : open(id) ? {id, title: ref.label, open: open(id)}
                : {id, title: ref.label, detail: ref.text, actions: [{id: "copy-reference", label: "Copy reference"}]});
        }
        // What can be done with the item is a row of buttons under it, like the Desk's own tools: a row that is only its action is a button.
        const acts = [];
        for (const action of ["reply", "close", "note", "unpark"]) {
            const id = "item-action:" + action;
            if (keys[id]) acts.push({id, title: ACTION[action](s), actions: keyActions(id, a => ACTION[a](s))});
        }
        // The person's Veto rides this row; the stem draws its action.
        if (s.vetoable) rows.push({id: "item-action:veto", title: "Veto"});
        const DEFER = {tomorrow: "Defer to tomorrow", nextWeek: "Defer a week"};
        for (const preset of input.deferPresets) {
            const id = "item-action:defer:" + preset.id, words = DEFER[preset.id] || "Defer";
            if (keys[id]) acts.push({id, title: words, actions: keyActions(id, () => words)});
        }
        acts.push({id: back.id, title: "Back to the board", actions: back.actions});
        sections.push({id: "selected-item", title: s.title, style: "values", rows});
        sections.push({id: "item-actions", style: "flow", rows: acts});
        // An item with steps under it is a board: one column per state its steps are in, side by side; the agent reads each column as a
        // section of steps, each with its handle and the moves its column offers.
        const steps = input.items.filter(item => item.parent === s.handle).sort((a, b) => byAlias(a.alias, b.alias));
        for (const [id, title] of COLUMNS) {
            const members = steps.filter(step => column(step) === id);
            // Done shows what closed most recently; every column holds at most its own count and says how many more there are.
            const shown = id === "done" ? members.slice().sort((a, b) => descending(a.updatedAt, b.updatedAt) || ascending(a.handle, b.handle))
                : members;
            const cards = shown.slice(0, COLUMN_ROWS[id]).map(step => row({id: "step:" + step.handle,
                title: line(step.title, 110) || step.handle, detail: itemDetail(step), value: step.alias, tone: tone(step),
                open: open("step:" + step.handle), actions: keyActions("step:" + step.handle, a => MOVE[a])
                    .filter(move => MOVES[id].includes(move.id))}));
            const rest = members.length - cards.length, more = spelled(rest) + " more " + (id === "done" ? "done" : "in " + title);
            if (cards.length) sections.push({id: "steps:" + id, title, style: "list", rows: cards, beside: "steps",
                footer: rest > 0 ? more[0].toUpperCase() + more.slice(1) + ". Every step is in the Desk's full reading." : undefined});
        }
        const addStep = Object.keys(keys).find(key => key.startsWith("add-step:"));
        if (addStep && (steps.length || ["plan", "project"].includes(s.itemKind))) {
            sections.push({id: "add-step", title: "Add a step", block: {kind: "form", key: addStep,
                fields: [{id: "title", label: "Step", kind: "line", required: true, placeholder: "What comes next"}],
                submit: [{id: "add", label: "Add"}]}});
        }
        // Each piece the item holds, drawn to be looked at in the order it was laid, newest version of each. Mockups, pages and pictures
        // stand side by side as one canvas; a table and a document's own words keep the full width under them.
        // A face holds 64 sections, so an item draws its first 24 pieces and says how many more its rows list.
        const ready = s.pieces.filter(piece => piece.state === "ready"), laid = ready.slice(0, 24);
        const wide = piece => piece.what === "document" || piece.what === "sheet";
        for (const piece of laid.filter(piece => !wide(piece))) {
            const key = "piece:" + piece.id;
            sections.push({id: key, title: pieceTitle(piece), beside: "pieces", block: {kind: "leaf", key, leaf: piece.leaf, ref: piece.ref,
                revision: piece.version, alt: pieceDoor(piece)}});
        }
        for (const piece of laid.filter(wide)) {
            const key = "piece:" + piece.id, title = pieceTitle(piece);
            if (piece.what === "sheet") {
                sections.push({id: key, title, block: {kind: "leaf", key, leaf: piece.leaf, ref: piece.ref, revision: piece.version,
                    alt: sheetDoor(piece)}});
            } else if (piece.text === undefined) {
                sections.push({id: key, title, style: "note", rows: [{id: "piece-words:" + piece.id, title: piece.reason, tone: "attention"}],
                    footer: "In Make as " + piece.ref + "."});
            } else {
                const words = utf8Fit(piece.text, 16 * 1024);
                sections.push({id: key, title, block: {kind: "document", key, text: words.text, format: piece.format, copy: true},
                    // Under a document a person reads only what is true for them; the agent has the Make ref on the piece's row and its
                    // own make.read and make.add.
                    footer: piece.textCut || words.cut ? "This is its beginning. The whole thing opens in Make." : undefined});
            }
        }
        if (ready.length > laid.length) {
            const more = spelled(ready.length - laid.length) + " more pieces are listed on the item above.";
            sections.push({id: "pieces-more", style: "note", rows: [{id: "pieces-more", title: more[0].toUpperCase() + more.slice(1)}]});
        }
    }

    // The board: each item in the one group that says what it waits on.
    const gone = input.unavailable;
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
        // What still holds it, as sequencing judged it: a Desk item by its number, anything else by its own id.
        const holding = item.plan === null ? [] : item.plan.blockers.map(h => {
            const on = items.find(i => i.handle === h);
            return on ? "desk." + on.alias : h.replace(/^exp:/, "");
        });
        if (holding.length) return "Waiting on " + holding.join(", ") + ".";
        if (item.plan !== null && item.plan.cycle) return "These items block each other.";
        if (trimmed(item.lastNote)) return "Last note: " + line(item.lastNote, 96);
        return "Blocked, with no reason written down.";
    }
    function itemDetail(item) {
        if (item.status === "blocked" || held(item)) return stuckReason(item);
        if (trimmed(item.summary)) return line(item.summary, 96);
        if (item.status === "flag") return "Flagged for a second look.";
        // An item nobody has started says nothing here; "Queued" beside it already does.
        const words = said(item.status, item.kind);
        return words ? words[0].toUpperCase() + words.slice(1) : null;
    }
    function group(item) {
        if (terminal(item)) return item.closedDay === input.day ? "done-today" : "history";
        if (item.requiresOwnerInput || item.status === "blocked" || item.status === "flag" || held(item)) return "waiting";
        if (item.deferred || (isProject(item) && item.parked)) return "parked";
        if (item.activity === "working" || item.status === "now") return "now";
        if (item.kind === "watch") return "watching";
        return "queued";
    }
    function tone(item) {
        if (item.requiresOwnerInput || item.status === "flag") return "attention";
        return {working: "live", blocked: "attention", stale: "attention", finished: "done", queued: "plain"}[item.activity] || "quiet";
    }
    function itemRow(item) {
        // A held item's detail already says what it waits on; "Queued" beside that would contradict it.
        // A row leads with its number, the name the person and the agent both call it by; its stored handle names nothing to either.
        const detail = [item.alias, item.project, isProject(item) ? projectLine(item) : itemDetail(item), held(item) ? null : ACTIVITY[item.activity]];
        if (item.plan !== null && item.plan.total > 0) detail.push(item.plan.done + " of " + item.plan.total + " closed");
        if (item.pieces.length) detail.push(thingsLine(item.pieces.length));
        // A plan with steps draws how far it has come: its closed steps out of all of them (done counts only its own steps).
        const meter = item.plan !== null && item.plan.total > 0 ? {value: item.plan.done, max: item.plan.total} : null;
        // The detail already says how many steps closed; an empty value keeps the reading from saying it again as the meter's amount.
        return row({id: item.handle, title: line(item.title, 110) || item.handle, detail: detail.filter(part => part !== null && part !== "").join(" · "),
            value: said(item.status, item.kind) ?? (meter ? "" : null),
            at: item.updatedAt, tone: tone(item), open: open(item.handle), actions: keyActions(item.handle, a => ACTION[a](item)), meter});
    }
    // My own upkeep stands apart from the work: what I finished today under one row of Done today, the rest at the end. An upkeep item the
    // page marks for attention, or that is blocked, is work again and stands with it.
    const gathered = item => item.upkeep && tone(item) !== "attention" && item.status !== "blocked";
    const dayName = new Intl.DateTimeFormat("en", {weekday: "long", month: "long", day: "numeric", timeZone: "UTC"});
    const datedName = new Intl.DateTimeFormat("en", {weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC"});
    const utcDay = stamp => { const [y, m, d] = stamp.split("-").map(Number); return Date.UTC(y, m - 1, d); };
    function dayTitle(day) {
        if (day === null) return "Closing day not recorded";
        if (utcDay(input.day) - utcDay(day) === 86400000) return "Yesterday";
        return (day.slice(0, 4) === input.day.slice(0, 4) ? dayName : datedName).format(new Date(utcDay(day)));
    }
    // Finished history reads by the day each item closed, newest day first.
    function byDay(prefix, list) {
        const days = new Map();
        for (const item of list) days.set(item.closedDay, (days.get(item.closedDay) || []).concat([item]));
        return [...days.keys()].sort((a, b) => a === b ? 0 : a === null ? 1 : b === null ? -1 : descending(a, b)).map(day => ({
            id: prefix + "day:" + (day === null ? "unrecorded" : day), title: dayTitle(day), value: String(days.get(day).length),
            rows: days.get(day).map(itemRow)}));
    }
    const board = {};
    for (const [id, title] of [["now", "Now"], ["waiting", "Waiting"], ["queued", "Queued"], ["watching", "Watching"], ["parked", "Parked"],
        ["done-today", "Done today"], ["history", "Finished history"]]) {
        // A step waiting its turn stays on its plan's board; the plan's own row counts it.
        const waitsOnBoard = item => id === "queued" && item.parent !== null && byHandle.has(item.parent) && !terminal(byHandle.get(item.parent));
        const members = items.filter(item => group(item) === id), work = members.filter(item => !gathered(item) && !waitsOnBoard(item));
        const rows = id === "history" ? byDay("", work) : work.map(itemRow);
        // What I finished for myself today stays readable under Done today, gathered under one row after the real work.
        const upkeep = id === "done-today" ? members.filter(gathered) : [];
        if (upkeep.length) rows.push({id: "upkeep:" + id, title: "My own upkeep", value: String(upkeep.length), rows: upkeep.map(itemRow)});
        if (rows.length) board[id] = row({id, title, style: "list", rows, folded: id === "history" ? true : null});
    }
    // The rest of my own upkeep, what is open and what closed on earlier days, sits apart at the end.
    const marks = items.filter(item => gathered(item) && group(item) !== "done-today");

    // Other work the overview reads, apart from what the board already shows.
    const overview = {};
    if (input.overview !== null) {
        const onBoard = new Set(input.items.map(item => item.handle));
        for (const [id, title, source] of [["work-now", "Other work now", input.overview.now], ["attention", "Needs you", input.overview.needsYou],
            ["recent-work", "Recently done", input.overview.recentlyDone]]) {
            const rows = source.rows.filter(r => r.kind !== "execution" && (r.kind !== "desk" || !onBoard.has(r.ref))).map(r => row({id: r.id,
                title: r.title, detail: r.summary, value: r.state, at: r.at,
                tone: id === "attention" ? "attention" : id === "recent-work" ? "done" : "plain", open: open(r.id)}));
            if (rows.length || source.omitted > 0) overview[id] = row({id, title, style: "timeline",
                footer: source.omitted > 0 ? source.omitted + " more items remain in the board, Activity and history." : null, rows});
        }
    }

    // The tools stay within reach at the top; then what waits, what I made, the work under way; what is set aside, the readings and what is
    // finished follow, and my own marks last.
    sections.push({id: "desk-tools", style: "flow", rows: [["refresh", "Refresh"], ["find-item", "Find item"], ["new-task", "New task"],
        ["research", "Look something up"]].map(([id, label]) =>
        ({id: "desk:" + id, title: label, actions: keyActions("desk:" + id, () => label)}))});
    // What I made, laid on live items: first on the board, newest first, each opening its item.
    const table = items.filter(item => !terminal(item)).flatMap(item => item.pieces.map(piece => ({item, piece})))
        .sort((a, b) => descending(a.piece.newestAt || "", b.piece.newestAt || "") || ascending(a.piece.id, b.piece.id))
        .map(({item, piece}) => row({id: "table:" + piece.id, title: pieceTitle(piece), detail: pieceLine(piece) + " · " + line(item.title, 80),
            at: piece.newestAt, tone: pieceTone(piece), open: open("table:" + piece.id), actions: keyActions("table:" + piece.id, a => PIECE_ACTION[a])}));
    for (const needs of [board.waiting, overview.attention]) if (needs) sections.push(needs);
    if (table.length) sections.push({id: "on-the-table", title: "On the table", style: "list", rows: table});
    for (const live of [board.now, board.watching, board.queued, overview["work-now"]]) if (live) sections.push(live);
    if (!items.length && input.boardRead && gone.desk === null) {
        sections.push({id: "empty-board", style: "note", rows: [{id: "empty", title: "No items on the board."}]});
    }
    if (board.parked) sections.push(board.parked);
    const gaps = [gone.desk, gone.jobs, gone.reminders, gone.helpers, gone.liveUpdates, gone.schedule]
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
    for (const finished of [board["done-today"], overview["recent-work"]]) if (finished) sections.push(finished);
    const jobs = input.jobs.slice().sort((a, b) => descending(a.at, b.at) || ascending(a.id, b.id));
    if (jobs.length) sections.push({id: "lines", title: "Work and finished lines", style: "timeline", rows: jobs.map(job => ({id: job.id,
        title: job.title, detail: job.summary, value: job.state, at: job.at, tone: job.terminal ? "done" : job.needsYou ? "attention" : "plain",
        actions: keyActions(job.id, () => "Read details")}))});
    // A section holds at most 256 rows, nested ones counted: history past that goes on in further folded sections, and a single
    // row that holds more than fit is drawn as several.
    const weight = entry => 1 + (entry.rows || []).reduce((sum, child) => sum + weight(child), 0);
    function packed(rows, limit) {
        const groups = [];
        let current = [], used = 0;
        for (const entry of rows.flatMap(entry => fitted(entry, limit))) {
            const size = weight(entry);
            if (current.length && used + size > limit) { groups.push(current); current = []; used = 0; }
            current.push(entry); used += size;
        }
        if (current.length) groups.push(current);
        return groups;
    }
    function fitted(entry, limit) {
        if (weight(entry) <= limit || !entry.rows) return [entry];
        return packed(entry.rows, limit - 1).map((rows, index) => ({...entry, id: index ? entry.id + "-" + index : entry.id, rows}));
    }
    if (board.history) {
        packed(board.history.rows, 256).forEach((rows, index) => sections.push(row({id: index ? "history-" + index : "history",
            title: index ? "Finished history, older" : "Finished history", style: "list", rows, folded: true})));
    }

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

    // My own upkeep, apart and folded: what is open, then what closed on earlier days, by day. Its one line counts what is open and names
    // what I am on.
    if (marks.length) {
        const live = marks.filter(item => !terminal(item)), current = live.find(item => group(item) === "now");
        const title = ["My own upkeep", live.length ? live.length + " open" : "earlier days", current ? "working on " + line(current.title, 60) : null]
            .filter(Boolean).join(" · ");
        packed(live.map(itemRow).concat(byDay("marks:", marks.filter(terminal))), 256).forEach((rows, index) => sections.push({
            id: index ? "my-marks-" + index : "my-marks", title: index ? "My own upkeep, older" : title, style: "list", rows, folded: true}));
    }
    // What the Desk has open, for the ask bar and the agent's page read. A title is one line there, so its line breaks become spaces.
    const opened = selected !== null && selected.kind === "item" && selected.found
        ? {link: "page:desk/" + selected.handle, title: (selected.title + " · desk." + selected.alias).replace(/\s+/g, " ").trim()} : null;
    return row({title: "Desk", line: input.headline, opened, sections});
}
