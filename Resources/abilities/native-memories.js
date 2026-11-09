/* NativeAgent ability
{
 "id":"native-memories", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"Draw the Memories page from the memory owner's packet: what I keep, what is waiting, what search found, what I let go, and every gap by name.","actions":[],"inputSchema":{"type":"object","required":["kept","waiting","query","search","rejected","misses","statusFailures","total","momentSource","clusters","keys"]}}
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
    function provenance(source) {
        const raw = source === null ? "" : source.trim().toLowerCase();
        if (raw === "manual" || raw === "user") return "Shared by you";
        if (raw.startsWith("chat.commit_memory") || raw.startsWith("commit_memory")) return "I wrote it down myself";
        if (raw.startsWith(input.momentSource)) return "I kept it from something that happened";
        if (raw.startsWith("adaptive-promoter") || raw.startsWith("semantic-adaptive-extractor")) return "I picked it up while we talked";
        if (raw.startsWith("consolidat") || raw.startsWith("hygiene")) return "I tidied it up from older notes";
        return "I don't remember where this came from";
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
        meta.push(attributed(provenance(memory.source), memory.from));
        // Under it, the moments I came to know it, each with its own date: all of them up to three, past three the earliest, the latest and how
        // many more, so the row says it whole in four lines.
        const roots = memory.roots, count = roots.length;
        const told = count <= 3 ? roots.map(root => root.line) : [roots[0].line, roots[count - 1].line, "+" + (count - 2) + " more"];
        const detail = [meta.join(" · ")].concat(told).join("\n");
        const id = "memory:" + memory.id, excerpt = line(memory.text, 96);
        const row = {id, title: excerpt || "An empty note", detail, open: keys[id].open,
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
    // A list longer than a section holds continues in untitled sections of its own.
    function list(id, title, rows) {
        const out = [];
        for (let i = 0; i < rows.length; i += 256) {
            out.push(i === 0 ? {id, title, style: "list", rows: rows.slice(0, 256)} : {id: id + "-" + i, style: "list", rows: rows.slice(i, i + 256)});
        }
        return out;
    }

    const sections = [];
    if (input.kept.state === "unavailable") sections.push(issue("kept", "Saved memories unavailable", input.kept.reason));
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
        if (pinned.length) sections.push({id: "pinned", title: "Pinned", style: "list", rows: pinned.map(memoryRow)});
        if (recent.length) sections.push({id: "recent", title: "What I've kept", style: "list", rows: recent.map(memoryRow)});
        else if (!all.length) sections.push({id: "empty", style: "note", rows: [{id: "empty", title: "It fills up as we talk."}]});
    }
    if (input.rejected.state === "unavailable") {
        sections.push({id: "rejected-error", style: "list", rows: [{id: "rejected-error", title: "Rejected history unavailable",
            detail: input.rejected.reason, tone: "failed"}]});
    } else {
        sections.push(...list("rejected", "Things I let go", input.rejected.proposals.map(proposal => ({id: "rejected:" + proposal.id,
            title: line(proposal.content, 96), detail: "I didn't keep this", at: proposal.createdAt, tone: "quiet",
            open: keys["rejected:" + proposal.id].open}))));
    }
    // Corrections by lesson, this week against last; the newest correction's words ride its lesson. A ledger that could not be read says so.
    if (input.misses.state === "unavailable") sections.push(issue("misses", "Corrections unavailable", input.misses.reason));
    else if (!input.misses.lessons.length) {
        sections.push({id: "misses", title: "Misses", style: "list", rows: [{id: "misses-none", title: "No corrections this week or last.", tone: "quiet"}]});
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
        })));
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
        const total = input.statusFailures.length === 0 && input.total !== null ? " of " + input.total + " saved" : " · total unavailable";
        pageLine = input.kept.memories.length + " memories loaded" + total + ".";
    }
    return {title: "Memories", line: pageLine, sections};
}
