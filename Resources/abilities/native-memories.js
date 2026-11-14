/* NativeAgent ability
{
 "id":"native-memories", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"Draw the Memories page from the memory owner's packet: what I keep, what is waiting, what search found, what I let go, and every gap by name.","actions":[],"inputSchema":{"type":"object","required":["kept","waiting","rejected","misses","statusFailures","momentSource","clusters","keys"]}}
}
*/
function face(input) {
    const keys = input.keys;
    // A character is what Swift counts as one: the packet names every cluster that spans several code units, longest first.
    function characters(text) {
        const out = [];
        for (let i = 0; i < text.length;) {
            const found = input.clusters.find(c => text.startsWith(c, i));
            const character = found === undefined ? String.fromCodePoint(text.codePointAt(i)) : found;
            out.push(character); i += character.length;
        }
        return out;
    }
    // Markdown out, one line: link targets dropped, heading and quote marks folded into sentences, bullets and emphasis gone.
    function plain(raw) {
        const text = raw.trim();
        if (!text) return "";
        return text.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map(rawLine => {
            let line = rawLine.trim(), heading = false;
            while (line[0] === "#" || line[0] === ">") { heading = heading || line[0] === "#"; line = line.slice(1).trimStart(); }
            if (heading && line && !".!?:".includes(line[line.length - 1])) line += ".";
            for (const bullet of ["- ", "* ", "+ "]) if (line.startsWith(bullet)) line = line.slice(bullet.length);
            return line.replace(/[*`\\]/g, "").trim();
        }).filter(Boolean).join(" ").trim();
    }
    // Cut at a sentence end past the middle, else at a word, never inside a word or character.
    function bounded(text, limit) {
        const chars = characters(text);
        if (chars.length <= limit) return text;
        const window = chars.slice(0, limit);
        let stop = -1;
        window.forEach((c, i) => { if (c === "." || c === "!" || c === "?") stop = i; });
        if (stop >= limit / 2) return window.slice(0, stop + 1).join("");
        const space = window.lastIndexOf(" "), head = space >= 0 ? window.slice(0, space).join("").trim() : "";
        return (head || window.join("")) + "…";
    }
    const line = (text, limit) => bounded(plain(text), limit);
    // Where a memory came from, read from the run that wrote it: a few words for the row's value and the sentence its detail tells.
    function provenance(source) {
        const raw = source === null ? "" : source.trim().toLowerCase();
        if (raw === "manual" || raw === "user") return {words: "you said", sentence: "Shared by you"};
        if (raw.startsWith("chat.commit_memory") || raw.startsWith("commit_memory")) return {words: "I wrote it", sentence: "I wrote it down myself"};
        if (raw.startsWith(input.momentSource)) return {words: "a moment", sentence: "I kept it from something that happened"};
        if (raw.startsWith("adaptive-promoter") || raw.startsWith("semantic-adaptive-extractor") || raw.startsWith("memory-manager")) {
            return {words: "picked up", sentence: "I picked it up while we talked"};
        }
        if (raw.startsWith("standing-correction")) return {words: "you corrected me", sentence: "You corrected me"};
        if (raw.startsWith("dream:")) return {words: "a dream", sentence: "It came to me while dreaming"};
        if (raw.startsWith("consolidat") || raw.startsWith("hygiene")) return {words: "tidied up", sentence: "I tidied it up from older notes"};
        return {words: null, sentence: "I don't remember where this came from"};
    }
    // Who else's words a memory holds travels beside it, each name one clean line of at most 160 characters.
    function attributed(text, sources) {
        const names = sources.map(source => Array.from(source.replace(/[\p{Cc}\p{Cf}]/gu, " ").split(/\s+/).filter(Boolean).join(" "))
            .slice(0, 160).join("")).filter(Boolean);
        return names.length ? text + " — from " + names.join(", ") : text;
    }
    function memoryRow(memory) {
        const meta = [];
        if (memory.warning !== null) meta.push(memory.warning);
        if (memory.pinned) meta.push("Pinned");
        if (memory.lifecycle === "graduated") meta.push("graduated → GROWTH");
        if (!memory.atReadable) meta.push("when, I'm not sure");
        const from = provenance(memory.source);
        meta.push(attributed(from.sentence, memory.from));
        // Under it, the moments I came to know it, each with its own date: all of them up to three, past three the earliest, the latest and how
        // many more, so the row says it whole in four lines.
        const roots = memory.roots, count = roots.length;
        const told = count <= 3 ? roots.map(root => root.line) : [roots[0].line, roots[count - 1].line, "+" + (count - 2) + " more"];
        const detail = [meta.join(" · ")].concat(told).join("\n");
        const id = "memory:" + memory.id, excerpt = line(memory.text, 96);
        const row = {id, title: excerpt || "An empty note", detail, value: from.words, open: keys[id].open,
            actions: [memory.pinned ? {id: "unpin", label: "Unpin"} : {id: "pin", label: "Pin to the top"}]};
        if (memory.at !== null) row.at = memory.at;
        if (memory.pinned) row.symbol = "pin.fill";
        return row;
    }
    // Pinned first, then the newest; a memory whose time cannot be read is the oldest.
    function ordered(memories) {
        const time = memory => memory.orderSeconds === null ? -Infinity : memory.orderSeconds;
        return memories.slice().sort((a, b) => {
            if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
            if (time(a) !== time(b)) return time(b) > time(a) ? 1 : -1;
            return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
        });
    }
    const issue = (id, title, reason) => ({id: id + "-error", style: "list", rows: [{id: id + "-error", title, detail: reason, tone: "failed"}]});
    // A list longer than a section holds continues in untitled sections of its own; a folded list names each part, since each folds to its title.
    function list(id, title, rows, folded) {
        const out = [];
        for (let i = 0; i < rows.length; i += 256) {
            const part = i === 0 ? {id, title, style: "list", rows: rows.slice(0, 256)} : {id: id + "-" + i, style: "list", rows: rows.slice(i, i + 256)};
            if (folded) { part.title = title; part.folded = true; }
            out.push(part);
        }
        return out;
    }
    // What I've kept, by when its row's time falls: each span one row holding its count and its memories, newest first; a memory whose time
    // cannot be read is Earlier.
    function spans(memories) {
        return [["kept-today", "Today", "sun.max", "today"], ["kept-week", "This week", "calendar", "week"],
            ["kept-earlier", "Earlier", "clock.arrow.circlepath", null]].map(([id, title, symbol, when]) => {
            const held = memories.filter(memory => when === null ? memory.when !== "today" && memory.when !== "week" : memory.when === when);
            return {id, title, symbol, value: String(held.length), rows: held.map(memoryRow)};
        }).filter(span => span.rows.length);
    }
    const total = input.statusFailures.length === 0 && input.total !== null ? input.total : null;

    const sections = [];
    if (input.kept.state === "unavailable") sections.push(issue("kept", "Saved memories unavailable", input.kept.reason));
    else {
        // How many I remember is the store's own count, unknown when its status could not be read; pinned and this week count the memories read here.
        const memories = input.kept.memories, pinned = memories.filter(memory => memory.pinned).length;
        const week = memories.filter(memory => memory.when === "today" || memory.when === "week").length;
        sections.push({id: "readout", style: "list", rows: [{id: "readout", symbol: "brain.head.profile",
            title: total === null ? "I can't read how many things I remember" : "I remember " + total + (total === 1 ? " thing" : " things"),
            detail: pinned + " pinned · " + week + " this week"}]});
    }
    if (input.waiting.state === "unavailable") sections.push(issue("waiting", "Proposals unavailable", input.waiting.reason));
    else sections.push(...list("waiting", "Waiting for you", input.waiting.proposals.map(proposal => ({id: "proposal:" + proposal.id,
        title: proposal.content, detail: proposal.kind === "correction" ? "Correction" : "Fact", at: proposal.createdAt, tone: "attention"}))));
    sections.push({id: "find", style: "list", rows: [{id: "search-field", title: "Search what I've kept",
        control: {text: input.query === null ? "" : input.query, placeholder: "At least three letters"}}]});
    if (input.search !== null) {
        const search = input.search;
        let rows = [];
        if (search.records !== null) {
            if (search.records.state === "available") rows = search.records.memories.map(memoryRow);
            else rows.push({id: "search-records-error", title: "Search records unavailable", detail: search.records.reason, tone: "failed"});
        }
        if (search.error !== null) rows.unshift({id: "search-error", title: "Search unavailable", detail: search.error, tone: "failed"});
        else if (search.loading || search.records === null) rows.push({id: "search-unread", title: "Search results have not arrived.", tone: "quiet"});
        else if (!rows.length) rows.push({id: "search-empty", title: "Nothing I've kept matches that.", tone: "quiet"});
        const found = {id: "search", title: "What I found", style: "list", rows};
        if (search.resultQuery !== null) found.footer = "Results for ‘" + search.resultQuery + "’.";
        sections.push(found, {id: "search-query", style: "list", rows: [{id: "search", title: "Search: “" + input.query + "”",
            actions: [{id: "clear", label: "Show all memories"}]}]});
    } else if (input.kept.state === "available") {
        const all = ordered(input.kept.memories);
        const pinned = all.filter(memory => memory.pinned), recent = all.filter(memory => !memory.pinned);
        // Every pin is drawn: a section holds 256 rows, so more pins continue in the next one.
        for (let at = 0; at < pinned.length; at += 256) sections.push({id: at ? "pinned:" + at : "pinned",
            title: at ? "Pinned, continued" : "Pinned", style: "list", rows: pinned.slice(at, at + 256).map(memoryRow)});
        if (recent.length) sections.push({id: "recent", title: "What I've kept", style: "list", rows: spans(recent)});
        else if (!all.length) sections.push({id: "empty", style: "note", rows: [{id: "empty", title: "It fills up as we talk."}]});
    }
    if (input.rejected.state === "unavailable") {
        sections.push({id: "rejected-error", style: "list", rows: [{id: "rejected-error", title: "Rejected history unavailable",
            detail: input.rejected.reason, tone: "failed"}]});
    } else {
        sections.push(...list("rejected", "Things I let go", input.rejected.proposals.map(proposal => ({id: "rejected:" + proposal.id,
            title: line(proposal.content, 96), detail: "I didn't keep this", at: proposal.createdAt, tone: "quiet",
            open: keys["rejected:" + proposal.id].open})), false));
    }
    // Corrections by lesson, this week against last; the newest correction's words ride its lesson. A ledger that could not be read says so.
    if (input.misses.state === "unavailable") sections.push(issue("misses", "Corrections unavailable", input.misses.reason));
    else if (!input.misses.lessons.length) {
        sections.push({id: "misses", title: "Misses", style: "list",
            rows: [{id: "misses-none", title: "No corrections this week or last.", tone: "quiet"}]});
    } else {
        sections.push(...list("misses", "Misses", input.misses.lessons.map(lesson => {
            const row = {id: "miss:" + lesson.lesson, title: line(lesson.lesson, 96) || "An unnamed lesson",
                value: lesson.thisWeek + " this week · " + lesson.lastWeek + " last week"};
            if (lesson.latest !== null) {
                const words = line(lesson.latest.text, 160);
                if (words) row.detail = words;
                row.at = lesson.latest.at;
            }
            return row;
        }), false));
    }
    for (const failure of input.statusFailures) sections.push(issue("status-" + failure.endpoint, failure.label, failure.reason));
    sections.push({id: "details", title: "Upkeep and details", style: "list", rows: [
        {id: "graph", title: "Knowledge graph", symbol: "circle.hexagonpath", open: keys.graph.open},
        {id: "upkeep", title: "Memory status and Spotlight", detail: "Search model, saved-memory status and reindexing.", symbol: "brain",
            open: keys.upkeep.open},
        {id: "refresh", title: "Read my memories again", actions: [{id: "refresh", label: "Check again"}]}
    ]});
    let pageLine = "Saved memories could not be read.";
    if (input.kept.state === "available") {
        pageLine = input.kept.memories.length + " memories loaded" + (total === null ? " · total unavailable" : " of " + total + " saved") + ".";
    }
    return {title: "Memories", line: pageLine, sections};
}
