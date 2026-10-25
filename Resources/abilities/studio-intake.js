/* NativeAgent ability
{"id":"studio-intake","kind":"tool","version":1,
 "reach":{"capabilities":["app_data_read"]},
 "record":{"description":"Order unanswered artifact consults from complete corrected history, and phrase invitations to work already in reach.","actions":["studio.intake.read"],"inputSchema":{"type":"object","required":["operation"]}}}
*/
function run(input) {
    if (input.operation === "invitations") {
        return input.candidates.map(candidate => {
            let head = candidate.title ?? candidate.reference ?? candidate.id;
            if (candidate.creator) head += " — " + candidate.creator;
            if (candidate.source === "named") return head + " is on the table, unanswered. [studio_consult_read consult_id: " + candidate.id + "]";
            if (candidate.source === "unjournaledWork") return head + " is in the graph with nothing written about it.";
            if (candidate.source === "crossedTheScreen") return head + " crossed the screen and went unremarked.";
            throw new Error("Unknown Studio encounter source.");
        });
    }
    if (input.operation !== "named") throw new Error("Choose named intake or invitations.");
    let snapshot = null;
    function read(kind) {
        let offset = 0, rows = [];
        do {
            const args = {kind,offset};
            if (snapshot !== null) args.snapshot = snapshot;
            const page = app["studio.intake.read"](args);
            snapshot = page.snapshot;
            rows.push(...page.rows);
            offset = page.next_offset;
        } while (offset !== null);
        return rows;
    }
    const history = read("history");
    const answered = new Set(history.map(row => row.origin_ref).filter(id => id !== null));
    const refs = new Set(history.flatMap(row => row.artifact_refs));
    const consults = read("consults");
    const candidates = consults.filter(row => !row.description_only && row.artifact_refs.length > 0
        && !answered.has(row.id) && !row.artifact_refs.some(ref => refs.has(ref)));
    // Filename order breaks equal-date ties, as in the native directory read.
    candidates.sort((a,b) => a.filed_at < b.filed_at ? -1 : a.filed_at > b.filed_at ? 1 : 0);
    const limit = input.limit === undefined ? 20 : input.limit;
    return {ids:candidates.slice(0,Math.max(0,limit)).map(row => row.id)};
}
