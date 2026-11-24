/* NativeAgent ability
{
  "id": "growth-week", "kind": "ability", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection": true},
  "record": {"description": "My seven-day growth readout, from frozen native REM timeline evidence.", "actions": [], "inputSchema": {"type": "object", "required": ["events","transitions","clusters"]}}
}
*/
function face(input) {
    const verdict = {proposed:"proposed", expiredUnresolved:"expired",
        unavailable:"unavailable", held:"held", approved:"accepted",
        letGo:"released", declined:"rejected", replayed:"replayed"};
    const {graphemes} = kit;
    const prefix = (s, n) => graphemes(s).slice(0, n).join("");
    function clause(raw) {
        const flat = raw.replace(/\s*\n\s*/g, " ").trim();
        return graphemes(flat).length > 160 ? prefix(flat, 159) + "…" : flat;
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
        if (!groups.has(e.artifactId)) groups.set(e.artifactId, {id:e.artifactId, title:e.title, body:e.summary,
            first:e.at, last:e.at, outcome:"proposed", settled:null, count:0,
            lineage:e.lineageId, reason:"", replayOnly:true, replaySummary:""});
        const a = groups.get(e.artifactId);
        a.count++; a.last = Math.max(a.last,e.at);
        if (e.kind === "replayRun" || e.kind === "dreamEpisode") a.replaySummary = e.summary;
        else a.replayOnly = false;
        if (e.outcome) {
            a.outcome = e.outcome; a.settled = e.at;
            a.reason = clause(e.summary);
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
        const replayed = a.outcome === "proposed" && a.replayOnly;
        const outcome = replayed ? "replayed" : a.outcome;
        const reason = a.reason || (replayed ? replayReason(a) : "");
        const verdictWords = verdict[outcome] + (["held","letGo"].includes(outcome) ? " (my own)" : "");
        const steps = a.count > 1 ? (a.count - 1) + (a.count === 2 ? " earlier step" : " earlier steps") : "";
        const body = a.lineage.startsWith("rem:") && a.body && a.body !== reason ? a.body : "";
        const tone = outcome === "approved" || outcome === "held" ? "done"
            : outcome === "proposed" || outcome === "unavailable" ? "attention" : "quiet";
        return {id:a.id, title:a.title, detail:reason || undefined, value:[verdictWords,steps].filter(Boolean).join(" · "), tone,
            rows:body ? [{id:a.id+":rem",title:"REM evidence",detail:body}] : undefined};
    });
    const transitions = input.transitions;
    if (!rows.length && !transitions.length) return {sections:[{id:"week",rows:[{id:"empty",title:"Nothing settled this week."}]}]};
    if (rows.length > 12) shown.push({id:"omitted",title:"and " + (rows.length-12) + " more this week, not shown"});
    if (!releases) shown.push({id:"no-releases",title:"Nothing was rejected or released this week."});
    transitions.slice(-3).forEach((t,i) => shown.push({id:"undertone:"+i,
        title:"Undertone " + t.before + " → " + t.after,
        detail:"Faded " + t.faded + ", " + t.source + " moved it " + t.moved, tone:"quiet"}));
    return {sections:[{id:"week",rows:shown}]};
}
