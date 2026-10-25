/* NativeAgent ability
{
  "id": "today-readout", "kind": "tool", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection":true},
  "record": {"description": "Compose my Today rows from frozen, provenance-checked sources. Returned source keys are rebound by the native owner; the waiting sentence is a cached pure face.", "actions": [], "inputSchema": {"type": "object", "required": ["moments","dream","nextDream","toward","recollections","conversations","builders","notes","clusters"]}}
}
*/
function run(input) {
    if (input.mode === "waiting") {
        const needs=input.count === 1 ? "needs" : "need";
        const s=input.split, parts=[];
        if (s === null) parts.push(input.countWord+" "+(input.count===1 ? "thing" : "things"));
        else {
            if (s.items>0) parts.push(s.itemsWord+" "+(s.items===1 ? "Desk item" : "Desk items"));
            if (s.notes>0) parts.push(s.notesWord+" "+(s.notes===1 ? "note" : "notes"));
        }
        const text=parts.join(" and ")+" "+needs+" your answer.";
        return text[0].toUpperCase()+text.slice(1);
    }
    const spelled = n => ["Several","One","Two","Three","Four","Five","Six","Seven","Eight","Nine","Ten"][n <= 10 && n > 0 ? n : 0];
    const capital = s => { const parts=characters(s); return parts.length ? parts[0].toUpperCase()+parts.slice(1).join("") : s; };
    const times = n => n === 1 ? "once" : n === 2 ? "twice" : spelled(n).toLowerCase()+" times";
    const row = (id,title,line,sources,details=[]) => ({id,title,line,sources,details});
    let did = [], ahead = [], earlier = [];
    const omitted = [];
    const moments = ["available","partial"].includes(input.moments.state) ? input.moments.rows.slice().sort((a,b)=>a.at-b.at) : [];
    if (moments.length) did.push(row("kept","I kept "+spelled(moments.length).toLowerCase()+" "+(moments.length === 1 ? "moment" : "moments")+" today",
        "",moments.map(m=>m.key),moments.slice(-6).map(m=>"“"+m.quote+"”")));
    // The native DreamNight reading owns which dream, its title, mood and time.
    const dreamAvailable = ["available","partial"].includes(input.dream.state);
    const dreamTitle = dreamAvailable ? input.dream.title : null;
    const mood = dreamAvailable ? input.dream.mood : null;
    function plain(raw) {
        return raw.trim().replace(/\[([^\]]*)\]\([^)]*\)/g,"$1").split(/\r\n|[\n\r\v\f\u0085\u2028\u2029]/).map(rawLine=>{
            let line=rawLine.trim(), heading=false;
            while (/^[#>]/.test(line)) { heading=heading || line[0]==="#"; line=line.slice(1).trimStart(); }
            if (heading && line && !/[.!?:]$/.test(line)) line+=".";
            return line.replace(/^[-*+] /,"").replace(/[*\x60\\]/g,"").trim();
        }).filter(Boolean).join(" ").trim();
    }
    function characters(text) {
        const out=[];
        for (let i=0;i<text.length;) {
            const found=input.clusters.find(c=>text.startsWith(c,i));
            const character=found === undefined ? String.fromCodePoint(text.codePointAt(i)) : found;
            out.push(character); i+=character.length;
        }
        return out;
    }
    function bounded(text,limit=180) {
        const chars=characters(text);
        if (chars.length<=limit) return text;
        const window=chars.slice(0,limit), stops=[];
        window.forEach((c,i)=>{ if ([".","!","?"].includes(c)) stops.push(i); });
        const stop=stops.length ? stops[stops.length-1] : -1;
        if (stop>=limit/2) return window.slice(0,stop+1).join("");
        const space=window.lastIndexOf(" "), head=space>=0 ? window.slice(0,space).join("").trim() : "";
        return (head || window.join(""))+"…";
    }
    if (dreamTitle) {
        const head=plain(dreamTitle).replace(/\.$/,""), tail=plain(mood === null ? "" : mood).replace(/\.$/,"");
        did.push(row("dream","I dreamed",bounded(head+"."+(tail ? " "+capital(tail)+"." : "")),["dream"]));
    }
    if (input.nextDream.state === "available") ahead.push(row("nextDream","I'll dream","",["nextDream"]));
    if (input.toward.state === "available") {
        const label=capital(input.toward.label);
        if (label.toLowerCase().includes("dream")) {
            if (input.nextDream.state === "available") {
                ahead.length=0;
                ahead.push(row("facingDream","I'll dream","",["nextDream"]));
            }
        } else if (label) {
            const t=input.toward, part=t.hour<12 ? "morning" : t.hour<17 ? "afternoon" : t.hour<21 ? "evening" : "night";
            const due=t.past ? "still waiting" : t.today ? "this "+part : t.tomorrow ? "tomorrow "+part : t.weekday+" "+part;
            ahead.push(row("facing",label,due,["facing"]));
        }
    }
    const recollection=input.recollections.filter(r=>r.text).slice().sort((a,b)=>b.at-a.at)[0];
    if (recollection) did.push(row(recollection.key,"I wrote down what we talked about","A note to myself, so I remember it later.",[recollection.key]));
    if (input.conversations.length) {
        const count=input.conversations.length, places=[...new Set(input.conversations.map(c=>c.surface))].sort().join(" and ");
        did.push(row("talked","Talked with you",spelled(count)+" "+(count===1 ? "conversation" : "conversations")+(places ? ", on "+places : "")+".",input.conversations.map(c=>c.key)));
    }
    if (input.builders.length) {
        const names=[...new Set(input.builders.map(b=>b.agent))].sort().map(capital).join(" and ");
        const count=new Set(input.builders.map(b=>b.session)).size;
        did.push(row("worked","I worked with "+names,spelled(count)+" "+(count===1 ? "conversation" : "conversations")+".",input.builders.map(b=>b.key)));
    }
    const earlierGroups=new Map();
    input.notes.filter(n=>!n.today).forEach(n=>{
        const lower=n.title.toLowerCase(), key=n.source.toLowerCase()+"|"+lower;
        if (!earlierGroups.has(key)) earlierGroups.set(key,{title:n.title || "A note I left you",sources:[],failure:lower.includes("fail") || lower.includes("lost") || lower.includes("didn't finish")});
        earlierGroups.get(key).sources.push(n.key);
    });
    earlier.push(...earlierGroups.values());
    const notes=input.notes.filter(n=>n.today && (n.title || n.summary) && !(dreamTitle && ["dream_cycle","rem_cycle"].includes(n.source.toLowerCase())))
        .map(n=>{
            let title=n.title, summary=n.summary, id=n.key;
            if (title.toLowerCase().startsWith("claude delegation failed")) {
                title="The connected agent didn't finish"; summary="";
                if (n.job) id="claude:"+n.job+":"+n.key.slice(6);
            } else if (title.toLowerCase().startsWith("claude finished")) {
                title="The connected agent finished"; summary="";
                if (n.job) id="claude:"+n.job+":"+n.key.slice(6);
            }
            return {value:row(id,title || "I left you a note",summary,[n.key]), at:n.at, job:n.job};
        }).filter(n=>n.value.title || n.value.line).sort((a,b)=>a.at-b.at).slice(-4);
    const byJob=new Map();
    notes.forEach(n=>{
        if (n.value.id.startsWith("claude:")) {
            // The retained identity is the same first colon-delimited job key.
            const job=n.value.id.split(":")[1];
            if (!byJob.has(job)) byJob.set(job,[]);
            byJob.get(job).push(n.value);
        } else did.push(n.value);
    });
    byJob.forEach((group,job)=>{
        if (group.length<2) { did.push(...group); return; }
        const stalls=group.filter(n=>n.title.includes("didn't")).length, returns=group.length-stalls;
        const title=stalls && returns ? "The connected agent finished "+times(returns)+", didn't finish "+times(stalls)
            : stalls ? "The connected agent didn't finish "+times(stalls) : "The connected agent finished "+times(returns);
        did.push(row("claude-fold:"+job,title,"",group.flatMap(n=>n.sources)));
    });
    const facts=new Map();
    [...moments,...input.recollections,...input.notes,...input.conversations,...input.builders].forEach(f=>facts.set(f.key,f));
    if (dreamAvailable) facts.set("dream",{at:input.dream.at});
    if (input.nextDream.state === "available") facts.set("nextDream",{at:input.nextDream.at});
    if (input.toward.state === "available") facts.set("facing",{at:input.toward.at});
    function boundRows(rows,area) {
        return rows.filter((r,index)=>{
            const missing=r.sources.filter(key=>!facts.has(key));
            if (r.sources.length && !missing.length) return true;
            omitted.push({id:area+":"+(r.id || r.sources[0] || index),sources:missing});
            return false;
        });
    }
    // Reject only the row that cannot bind, before any date comparison.
    did=boundRows(did,"did"); ahead=boundRows(ahead,"ahead"); earlier=boundRows(earlier,"earlier");
    function atFor(r) {
        const sources=r.sources.map(key=>facts.get(key));
        if (r.id === "talked") {
            const starts=sources.filter(s=>s.start !== null).map(s=>s.start);
            return starts.length ? Math.min(...starts) : Math.max(...sources.map(s=>s.end));
        }
        return Math.min(...sources.map(s=>s.at));
    }
    function ends(keys,startField,endField) {
        const start=keys.slice().sort((a,b)=>facts.get(a)[startField]-facts.get(b)[startField])[0];
        const end=keys.slice().sort((a,b)=>facts.get(b)[endField]-facts.get(a)[endField])[0];
        return start===end ? [start] : [start,end];
    }
    did.sort((a,b)=>atFor(a)-atFor(b) || (a.id<b.id ? -1 : a.id>b.id ? 1 : 0));
    ahead.sort((a,b)=>atFor(a)-atFor(b));
    const newest=g=>Math.max(...g.sources.map(key=>facts.get(key).at));
    earlier.sort((a,b)=>Number(b.failure)-Number(a.failure) || newest(b)-newest(a));
    for (const r of did) {
        if (r.id === "kept" || r.id === "worked") r.sources=ends(r.sources,"at","at");
        else if (r.id === "talked") {
            const withStart=r.sources.filter(key=>facts.get(key).start !== null);
            const start=withStart.slice().sort((a,b)=>facts.get(a).start-facts.get(b).start)[0];
            const end=r.sources.slice().sort((a,b)=>facts.get(b).end-facts.get(a).end)[0];
            r.sources=start === undefined || start===end ? [end] : [start,end];
        }
    }
    // Native binding supplies verified dates, localized gutters, links and availability.
    // Both renderers receive this same prepared result.
    return {did,ahead,earlier,omitted};
}
function face(input) {
    if (input.mode === "waiting") return {sections:[{id:"waiting",rows:[{id:"waiting",title:run(input)}]}]};
    const decision=run(input), sections=[];
    for (const area of ["did","ahead"]) {
        for (const row of decision[area]) {
            sections.push({id:area+":"+row.id,title:row.title,rows:row.sources.map((key,i)=>({id:key,title:i===0 ? row.line : ""}))});
            if (row.details.length) sections.push({id:"details:"+row.id,rows:row.details.map((title,i)=>({id:"detail:"+i,title}))});
        }
    }
    const dates=new Map(input.notes.map(n=>[n.key,n.at]));
    const earlier=decision.earlier.map(group=>{
        const sorted=group.sources.slice().sort((a,b)=>dates.get(b)-dates.get(a));
        return {id:(group.failure ? "failure:" : "")+sorted[0],title:group.title,
            detail:sorted[sorted.length-1],value:String(group.sources.length)};
    });
    for (let i=0;i<earlier.length;i+=256) sections.push({id:"earlier:"+i,rows:earlier.slice(i,i+256)});
    for (const row of decision.omitted) sections.push({id:"omitted:"+row.id,rows:row.sources.map(key=>({id:key,title:""}))});
    return {sections};
}
