/* NativeAgent ability
{
 "id":"native-personality", "kind":"ability", "version":1,
 "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
 "face":{"projection":true},
 "record":{"description":"Draw the Personality page from the persona owner's packet: who I am, my persona documents, how I am becoming, and my dreams.","actions":[],"inputSchema":{"type":"object","required":["profile","documents","identityInitialized","becoming","dreams","keys"]}}
}
*/
function face(input) {
    const keys = input.keys;
    const issue = (id, title, reason) => ({id, title, style: "note",
        rows: [{id: id + "-unavailable", title: title + " could not be read.", detail: reason, tone: "failed"}]});
    // A row keeps a time only when its owner has one.
    const timed = (row, at) => { if (at !== null) row.at = at; return row; };
    const sections = [];

    const profile = input.profile;
    sections.push(profile.state === "available"
        ? {id: "identity", title: "Who I am", style: "values",
            rows: [timed({id: "name", title: "Name", value: profile.name, open: keys.name.open}, profile.updatedAt)]}
        : issue("identity", "Identity", profile.reason));

    const documents = input.documents;
    sections.push(documents.state === "available"
        ? {id: "documents", title: "Persona documents", style: "list",
            footer: "Open a document to read or edit it. About you is written from memory and stays read-only here.",
            rows: documents.documents.map(doc => timed({id: "document:" + doc.id, title: doc.title, detail: doc.firstLine,
                open: keys["document:" + doc.id].open}, doc.updatedAt))}
        : issue("documents", "Persona documents", documents.reason));

    const becoming = input.becoming;
    let reading;
    if (becoming.state === "not_running") {
        reading = [{id: "becoming-unavailable", title: "My self-reading is unavailable while cognition is not running.", tone: "quiet"}];
    } else if (becoming.state === "failed") {
        reading = [{id: "becoming-unavailable", title: "My self-reading is unavailable.", detail: becoming.reason, tone: "failed"}];
    } else if (becoming.state === "none") {
        reading = [{id: "becoming-unavailable", title: "No self-reading is available yet.", tone: "quiet"}];
    } else {
        reading = becoming.traits.map((line, i) => ({id: "trait:" + i, title: line, at: becoming.writtenAt}))
            .concat(becoming.story.map((line, i) => ({id: "story:" + i, title: line, at: becoming.writtenAt})));
    }
    sections.push({id: "becoming", title: "Becoming", style: "note", rows: reading});

    const dreams = input.dreams;
    if (dreams.state === "available") {
        const rows = [{id: "dreams", title: "Dream diary", value: dreams.enabled ? "Dream cycle on" : "Dream cycle off", open: keys.dreams.open}];
        for (const entry of dreams.entries) {
            const row = {id: "dream:" + entry.date, title: entry.date, open: keys["dream:" + entry.date].open};
            if (entry.firstLine !== null) row.detail = entry.firstLine;
            rows.push(timed(row, entry.modifiedAt));
        }
        if (dreams.unreadable !== null && dreams.unreadable > 0) {
            rows.push({id: "dreams-unreadable", title: dreams.unreadable + " diary files could not be read.", tone: "attention"});
        }
        sections.push({id: "dreams", title: "Dreams", style: "timeline", rows});
    } else sections.push(issue("dreams", "Dreams", dreams.reason));

    sections.push({id: "identity-care", style: "list", rows: [{id: "edit", title: "Read or edit my identity", open: keys.edit.open}]});
    return {title: "Personality", line: "Who I am, how I express myself, and how I grow.", sections};
}
