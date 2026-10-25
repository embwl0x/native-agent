/* NativeAgent ability
{
  "id": "growth-week", "kind": "tool", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection": true},
  "record": {"description": "My seven-day growth readout, from frozen native timeline and revision evidence.", "actions": [], "inputSchema": {"type": "object", "required": ["events","views","transitions","clusters"]}}
}
*/
function run(input) { return face(input); }
function face(input) {
    const verdict = {proposed:"proposed", revisionProposed:"proposed", expiredUnresolved:"expired",
        unavailable:"unavailable", held:"held", approved:"accepted", revised:"revised",
        letGo:"released", outOfSet:"released", declined:"rejected", replayed:"replayed"};
    const reasons = {revisionProposed:"a revision of it is waiting on an answer", letGo:"she let it go",
        declined:"the person declined it", outOfSet:"the set was full — capacity, not reconsidered",
        expiredUnresolved:"nobody answered it and it aged out", unavailable:"the decision is unavailable", replayed:"no proposal"};
    function chars(s) {
        const out=[];
        for (let i=0;i<s.length;) {
            const found=input.clusters.find(c=>s.startsWith(c,i));
            const character=found === undefined ? String.fromCodePoint(s.codePointAt(i)) : found;
            out.push(character); i+=character.length;
        }
        return out;
    }
    const prefix = (s, n) => chars(s).slice(0, n).join("");
    function clause(raw) {
        const flat = raw.replace(/\n/g, " ").trim();
        return chars(flat).length > 160 ? prefix(flat, 159) + "…" : flat;
    }
    function title(event) {
        const t = event.title.trim(), lower = t.toLowerCase();
        if (!lower.startsWith("schema proposal") && !lower.startsWith("identity proposal") && !lower.endsWith("rem proposal")) return t;
        const lesson = clause(event.summary);
        if (!lesson) return t;
        const sentence = lesson.match(/^.*?[.?!]/);
        return sentence && chars(sentence[0]).length >= 16 ? sentence[0] : lesson;
    }
    function evidenceReason(event) {
        const nights = [...new Set(event.evidence.filter(x => x.startsWith("dream:")).map(x => prefix(x.slice(6), 10)))].sort();
        const settled = (event.lineageId.startsWith("rem:") ? "settled by the REM pass " : "settled ") + event.day;
        return nights.length ? "first dreamt " + nights[0] + (nights.length > 1 ? ", dwelt on across " + nights.length + " nights" : "") + ", " + settled : settled;
    }
    const compare = (a,b) => a < b ? -1 : a > b ? 1 : 0;
    const events = input.events.slice().sort((a,b) => a.at - b.at || compare(a.id,b.id));
    const views = new Map(input.views.map(v => [v.id,v]));
    const resolution = new Map(), harvest = new Map(), groups = new Map();
    events.filter(e => e.kind === "proposalResolution").forEach(e => resolution.set(e.artifactId || e.id, e.outcome || "proposed"));
    events.filter(e => e.kind === "proposalResolution" || e.kind === "schemaProposal").forEach(e => {
        const id = e.artifactId || e.id, outcome = resolution.get(id) || e.outcome || "proposed";
        e.evidence.filter(x => x.startsWith("dream:")).forEach(x => {
            const night = prefix(x,16);
            if (!harvest.has(night)) harvest.set(night,new Map());
            harvest.get(night).set(id,outcome);
        });
    });
    for (const e of events) {
        if (!e.artifactId) continue;
        if (!groups.has(e.artifactId)) groups.set(e.artifactId, {id:e.artifactId, title:title(e), body:e.summary,
            first:e.at, last:e.at, outcome:"proposed", settled:null, count:0, revisits:0,
            lineage:e.lineageId, reason:"", prior:null, replayOnly:true, replaySummary:""});
        const a = groups.get(e.artifactId);
        a.count++; a.last = Math.max(a.last,e.at);
        if (e.kind === "replayRun" || e.kind === "dreamEpisode") a.replaySummary = e.summary;
        else a.replayOnly = false;
        if (e.title.startsWith("Standing view revisited")) a.revisits++;
        else if (e.outcome) {
            a.outcome = e.outcome; a.settled = e.at;
            const summary = clause(e.summary);
            a.reason = summary.startsWith(a.title) ? evidenceReason(e) : summary;
        }
        if (!a.lineage) a.lineage = e.lineageId;
    }
    const revisions = input.views.filter(v => v.status !== "retired" && v.revises)
        .map(v => ({view:v, at:v.released ? v.releasedAt : v.createdAt}))
        .sort((a,b) => a.at-b.at || compare(a.view.id,b.view.id));
    for (const r of revisions) {
        const v = r.view, a = groups.get(v.revises);
        if (!v.inWindow || !a) continue;
        const outcome = v.released ? "revised" : "revisionProposed";
        if (a.outcome !== outcome && !["proposed","revisionProposed","expiredUnresolved","unavailable","replayed"].includes(a.outcome)) a.prior = a.outcome;
        a.outcome = outcome; a.reason = v.title || v.body;
        if (v.released) a.settled = v.releasedAt;
        a.last = Math.max(a.last,r.at);
    }
    function replayReason(a) {
        if (!a.lineage.startsWith("dream:")) return clause(a.replaySummary) || "no proposal";
        const outcomes = [...(harvest.get(prefix(a.lineage,16)) || new Map()).values()];
        if (!outcomes.length) return "no proposal came out of it";
        const counts = {};
        outcomes.forEach(o => { const v = ["proposed","revisionProposed"].includes(o) ? "still open" : verdict[o]; counts[v] = (counts[v] || 0)+1; });
        const noun = outcomes.length === 1 ? "1 proposal" : outcomes.length + " proposals";
        const keys = Object.keys(counts).sort();
        if (keys.length === 1) return noun + " came out of it, " + (outcomes.length === 1 ? "" : outcomes.length === 2 ? "both " : "all ") + keys[0];
        return noun + " came out of it: " + keys.map(k => counts[k] + " " + k).join(", ");
    }
    function alternative(a) {
        if (!["held","approved","revised"].includes(a.outcome)) return "";
        const v = views.get(a.id);
        if (!v) return "no alternative recorded";
        const challenger = input.views.filter(q => q.revises === a.id).slice().sort((x,y) => x.createdAt-y.createdAt || compare(x.id,y.id))[0];
        const other = views.get(v.revises) || challenger;
        if (!other) return "nothing contradicted it";
        const name = other.title.trim() || clause(other.body);
        return "held over " + (chars(name).length > 60 ? prefix(name,59) + "…" : name);
    }
    const rows = [...groups.values()].sort((a,b) => (b.settled === null ? b.first : b.settled) - (a.settled === null ? a.first : a.settled) || compare(a.id,b.id));
    const releases = rows.filter(a => ["declined","letGo","outOfSet"].includes(a.outcome)).length;
    const shown = rows.slice(0,12).map(a => {
        if (a.outcome === "proposed" && a.replayOnly) { a.outcome = "replayed"; a.reason = replayReason(a); }
        const v = views.get(a.id), name = v && v.title ? v.title : a.title;
        let text = name + " — " + verdict[a.outcome];
        if (a.prior && a.prior !== a.outcome) text += " (was " + verdict[a.prior] + ")";
        const revisits = Math.max(a.revisits,v ? v.revisitCount : 0);
        if (revisits > 0) text += ", revisited " + revisits + "×";
        const reason = clause(a.reason || reasons[a.outcome] || "");
        if (reason) text += " — " + reason;
        const alt = alternative(a);
        if (alt) text += " — " + alt;
        if (["held","letGo"].includes(a.outcome)) text += " (her own)";
        return {id:a.id, title:text, detail:v ? v.originExcerpt : "",
            value:a.count > 1 ? (a.count-1) + " earlier step(s) collapsed · " + a.lineage : ""};
    });
    const transitions = input.transitions;
    if (!rows.length && !transitions.length) return {sections:[{id:"week",rows:[{id:"empty",title:"Nothing settled this week."}]}]};
    if (rows.length > 12) shown.push({id:"omitted",title:"and " + (rows.length-12) + " more this week, not shown"});
    if (!releases) shown.push({id:"no-releases",title:"Nothing was rejected or released this week."});
    transitions.slice(-3).forEach((t,i) => shown.push({id:"undertone:"+i,
        title:"undertone " + t.before + " → " + t.after +
        " (faded " + t.faded + ", " + t.source + " moved it " + t.moved + ")"}));
    return {sections:[{id:"week",rows:shown}]};
}
