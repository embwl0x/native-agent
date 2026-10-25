/* NativeAgent ability
{
  "id": "growth-week", "kind": "tool", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection": true},
  "record": {"description": "My seven-day growth readout, from frozen native REM timeline evidence.", "actions": [], "inputSchema": {"type": "object", "required": ["events","transitions","clusters"]}}
}
*/
function run(input) { return face(input); }
function face(input) {
    const verdict = {proposed:"proposed", expiredUnresolved:"expired",
        unavailable:"unavailable", held:"held", approved:"accepted",
        letGo:"released", declined:"rejected", replayed:"replayed"};
    const reasons = {letGo:"she let it go",
        declined:"the person declined it",
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
            first:e.at, last:e.at, outcome:"proposed", settled:null, count:0,
            lineage:e.lineageId, reason:"", replayOnly:true, replaySummary:""});
        const a = groups.get(e.artifactId);
        a.count++; a.last = Math.max(a.last,e.at);
        if (e.kind === "replayRun" || e.kind === "dreamEpisode") a.replaySummary = e.summary;
        else a.replayOnly = false;
        if (e.outcome) {
            a.outcome = e.outcome; a.settled = e.at;
            const summary = clause(e.summary);
            a.reason = summary.startsWith(a.title) ? evidenceReason(e) : summary;
        }
        if (!a.lineage) a.lineage = e.lineageId;
    }
    function replayReason(a) {
        if (!a.lineage.startsWith("dream:")) return clause(a.replaySummary) || "no proposal";
        const outcomes = [...(harvest.get(prefix(a.lineage,16)) || new Map()).values()];
        if (!outcomes.length) return "no proposal came out of it";
        const counts = {};
        outcomes.forEach(o => { const v = o === "proposed" ? "still open" : verdict[o]; counts[v] = (counts[v] || 0)+1; });
        const noun = outcomes.length === 1 ? "1 proposal" : outcomes.length + " proposals";
        const keys = Object.keys(counts).sort();
        if (keys.length === 1) return noun + " came out of it, " + (outcomes.length === 1 ? "" : outcomes.length === 2 ? "both " : "all ") + keys[0];
        return noun + " came out of it: " + keys.map(k => counts[k] + " " + k).join(", ");
    }
    const rows = [...groups.values()].sort((a,b) => (b.settled === null ? b.first : b.settled) - (a.settled === null ? a.first : a.settled) || compare(a.id,b.id));
    const releases = rows.filter(a => ["declined","letGo"].includes(a.outcome)).length;
    const shown = rows.slice(0,12).map(a => {
        if (a.outcome === "proposed" && a.replayOnly) { a.outcome = "replayed"; a.reason = replayReason(a); }
        const name = a.title;
        let text = name + " — " + verdict[a.outcome];
        const reason = clause(a.reason || reasons[a.outcome] || "");
        if (reason) text += " — " + reason;
        if (["held","letGo"].includes(a.outcome)) text += " (her own)";
        return {id:a.id, title:text,
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
