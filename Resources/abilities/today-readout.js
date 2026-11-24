/* NativeAgent ability
{
  "id": "today-readout", "kind": "ability", "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"projection":true},
  "record": {
    "description": "Draw Today as a timed timeline, upcoming intentions, earlier notes and named source gaps.",
    "actions": [], "inputSchema": {"type": "object",
      "required": ["moments","dream","nextDream","toward","thinking","intentions","conversations","builders","notes","clusters",
        "keys","waitingRows","waiting","hour"]}
  }
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
    const {graphemes, plain} = kit;
    const capital = s => { const parts=graphemes(s); return parts.length ? parts[0].toUpperCase()+parts.slice(1).join("") : s; };
    const row = (id,title,line,sources,details=[]) => ({id,title,line,sources,details});
    let did = [], ahead = [], earlier = [];
    const omitted = [];
    if (input.thinking.state === "available") {
        const {today, week} = input.thinking;
        const ratio = counts => counts.turns > 0 ? (counts.calls/counts.turns).toFixed(1) : "unmeasured";
        const turns = today.turns + " " + (today.turns === 1 ? "turn" : "turns");
        const todayPart = today.turns > 0 ? ratio(today) + " steps per turn today (" + turns + ")" : "No turns today";
        const weekPart = week.turns > 0 ? ratio(week) + " this week" : "unmeasured this week";
        did.push(row("thinking", "Thinking", todayPart + " · " + weekPart, ["thinking"]));
    }
    const moments = ["available","partial"].includes(input.moments.state) ? input.moments.rows.slice().sort((a,b)=>a.at-b.at) : [];
    if (moments.length) did.push(row("kept","I kept "+spelled(input.moments.total).toLowerCase()
        +" "+(input.moments.total === 1 ? "moment" : "moments")+" today",
        "",moments.map(m=>m.key),moments.slice(-6).map(m=>"“"+m.quote+"”")));
    // The native DreamNight reading owns which dream, its title, mood and time.
    const dreamAvailable = ["available","partial"].includes(input.dream.state);
    const dreamTitle = dreamAvailable ? input.dream.title : null;
    const mood = dreamAvailable ? input.dream.mood : null;
    const bounded = (text, limit = 180) => kit.bounded(text, limit);
    if (dreamTitle) {
        const head=plain(dreamTitle).replace(/\.$/,""), tail=plain(mood === null ? "" : mood).replace(/\.$/,"");
        did.push(row("dream","I dreamed",bounded(head+"."+(tail ? " "+capital(tail)+"." : "")),["dream"]));
    }
    const nextNight=input.nextDream;
    const dreamPart=nextNight.dream.state === "off" ? " Dreams are off."
        : nextNight.dream.state === "unavailable" ? " Dream setting unavailable: "+nextNight.dream.reason : "";
    const nightLine=nextNight.reason+dreamPart;
    if (nextNight.state === "available" && Number.isFinite(nextNight.at)) ahead.push(row("nextDream", "Next night check", nightLine, ["nextDream"]));
    if (input.toward.state === "available") {
        const t=input.toward, label=capital(t.label);
        const title=t.sourceKind === "stagedApproval" ? "Pending approval"
            : t.sourceKind === "peerReply" ? "Waiting on "+label
            : t.sourceKind === "statedPlan" ? label : undefined;
        if (title) {
            const part=t.hour<12 ? "morning" : t.hour<17 ? "afternoon" : t.hour<21 ? "evening" : "night";
            const due=t.past ? "Still waiting" : t.today ? "This "+part : t.tomorrow ? "Tomorrow "+part : t.weekday+" "+part;
            ahead.push(row("facing",title,due,["facing"]));
        }
    }
    const intentions = input.intentions.state === "available" ? input.intentions.rows : [];
    intentions.slice().sort((a,b)=>a.at-b.at || a.key.localeCompare(b.key)).slice(0,5).forEach(i=>{
        const words=plain(i.words), title=i.title || "Something I mean to do";
        const day=i.time.startsWith("at ") ? "" : i.time;
        ahead.push(row(i.key, words || title, day, [i.key]));
    });
    if (input.conversations.length) {
        const count=input.conversations.length, places=[...new Set(input.conversations.map(c=>c.surface))].sort().join(" and ");
        did.push(row("talked","Talked with you",spelled(count)+" "+(count===1 ? "conversation" : "conversations")+(places ? ", on "+places : "")+".",input.conversations.map(c=>c.key)));
    }
    if (input.builders.length) {
        const names=[...new Set(input.builders.map(b=>b.agent))].sort().join(" and ");
        const count=new Set(input.builders.map(b=>b.session)).size;
        did.push(row("worked","I worked with "+names,spelled(count)+" "+(count===1 ? "conversation" : "conversations")+".",input.builders.map(b=>b.key)));
    }
    // The agent's own decisions of one kind (the kind their owner names, as the Inbox folds them) stand as one row holding each.
    // A count says what it counts: a kind's decisions are their owner's counts, summed; unreadable, there is no count.
    const decisionCount=members=>members.every(m=>Number.isInteger(m.decisions)) ? members.reduce((sum,m)=>sum+m.decisions,0) : null;
    const decisionWords=count=>count === null ? "" : count+" "+(count === 1 ? "decision" : "decisions");
    const earlierGroups=new Map();
    input.notes.filter(n=>!n.today).forEach(n=>{
        const key=n.job ? "job:"+n.job : n.kind ? "decided:"+n.kind : n.key;
        const failed=n.failed === true;
        if (!earlierGroups.has(key)) earlierGroups.set(key,{title:n.title || "A note I left you",sources:[],members:[],kind:n.job ? null : n.kind,
            failure:false});
        const g=earlierGroups.get(key);
        if (failed) g.failure=true;
        g.sources.push(n.key);
        g.members.push({key:n.key,title:n.title || "A note I left you",decisions:n.decisions,failure:failed,
            value:n.kind ? decisionWords(decisionCount([n])) : ""});
    });
    earlierGroups.forEach(g=>{
        const many=g.members.length>1;
        g.value=g.kind ? decisionWords(decisionCount(g.members)) : many ? g.members.length+" notes" : "";
        if (g.kind && many) g.title+=", and "+(g.members.length-1)+" more";
        earlier.push(g);
    });
    const units=input.notes.filter(n=>n.today && (n.title || n.summary) && !(dreamTitle && ["dream_cycle","rem_cycle"].includes(n.source.toLowerCase())))
        .map(n=>{
            const value=row(n.key,n.title || "I left you a note",n.summary,[n.key]);
            value.failure=n.failed === true;
            return {value,at:n.at,job:n.job,kind:n.job ? null : n.kind,decisions:n.decisions};
        });
    const kinds=new Map();
    units.forEach(n=>{ if (n.kind) kinds.set(n.kind,[...(kinds.get(n.kind) || []),n]); });
    const folded=units.filter(n=>!n.kind || kinds.get(n.kind).length<2);
    kinds.forEach((group,kind)=>{
        if (group.length<2) return;
        const newest=group.slice().sort((a,b)=>b.at-a.at || (a.value.id<b.value.id ? -1 : 1)), count=decisionCount(group);
        const fold=row("did.decided."+kind,newest[0].value.title+", and "+(group.length-1)+" more",decisionWords(count),
            newest.flatMap(n=>n.value.sources));
        fold.rows=newest.map(n=>n.value);
        fold.failure=fold.rows.some(n=>n.failure);
        folded.push({value:fold,at:newest[0].at,job:null});
    });
    // The latest four rows, a fold counting as one.
    const notes=folded.sort((a,b)=>a.at-b.at).slice(-4);
    const byJob=new Map();
    notes.forEach(n=>{
        if (n.job) {
            if (!byJob.has(n.job)) byJob.set(n.job,[]);
            byJob.get(n.job).push(n.value);
        } else did.push(n.value);
    });
    byJob.forEach((group,job)=>{
        if (group.length<2) { did.push(...group); return; }
        const failures=group.filter(n=>n.failure), others=group.filter(n=>!n.failure);
        const result=row("delegation:"+job,"My delegated work: "+group.length+" notes"+(failures.length ? ", "+failures.length+" failed" : ""),"",
            failures.concat(others).flatMap(n=>n.sources));
        result.failure=failures.length>0;
        did.push(result);
    });
    const facts=new Map();
    [...moments,...intentions,...input.notes,...input.conversations,...input.builders].forEach(f=>facts.set(f.key,f));
    if (dreamAvailable) facts.set("dream",{at:input.dream.at});
    if (input.nextDream.state === "available") facts.set("nextDream",{at:input.nextDream.at});
    if (input.toward.state === "available") facts.set("facing",{at:input.toward.at});
    if (input.thinking.state === "available") facts.set("thinking",{at:input.thinking.at});
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
        const times=sources.map(s=>s.at).filter(Number.isFinite);
        return times.length ? Math.min(...times) : undefined;
    }
    function ends(keys,startField,endField) {
        const start=keys.slice().sort((a,b)=>facts.get(a)[startField]-facts.get(b)[startField])[0];
        const end=keys.slice().sort((a,b)=>facts.get(b)[endField]-facts.get(a)[endField])[0];
        return start===end ? [start] : [start,end];
    }
    function chronological(a,b) {
        const left=atFor(a), right=atFor(b);
        // Undated facts follow the timeline without inventing an instant for them.
        if (left === undefined || right === undefined) {
            if (left !== right) return left === undefined ? 1 : -1;
        } else if (left !== right) return left-right;
        return a.id<b.id ? -1 : a.id>b.id ? 1 : 0;
    }
    did.sort(chronological);
    ahead.sort(chronological);
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
    if (input.mode === "waiting") return {title:"Today",
        sections:[{id:"waiting",style:"waiting",rows:[{id:"waiting",title:run(input)}]}]};
    const decision=run(input), sections=[];
    // A row leads only where its key leads; the person's decisions stand beside this face, drawn by the app.
    const keys=input.keys, open=key=>(keys[key]||{}).open;
    const waiting=input.waitingRows.map(r=>({id:r.id,title:r.title,detail:r.detail,open:open(r.id)}));
    if (input.waitingDesk) waiting.push({id:"desk",title:run(input.waitingDesk),open:open("desk")});
    for (let i=0;i<waiting.length;i+=256) {
        sections.push({id:"waiting:"+i,title:"Waiting for you",style:"list",rows:waiting.slice(i,i+256)});
    }
    const facts=new Map();
    for (const field of ["moments","intentions"]) {
        if (["available","partial"].includes(input[field].state)) for (const fact of input[field].rows) facts.set(fact.key,fact);
    }
    for (const field of ["notes","conversations","builders"]) for (const fact of input[field]) facts.set(fact.key,fact);
    for (const [key,field] of [["dream","dream"],["nextDream","nextDream"],["facing","toward"],["thinking","thinking"]]) {
        if (["available","partial"].includes(input[field].state)) facts.set(key,input[field]);
    }
    function at(keys,newest=false) {
        const times=keys.map(key=>(facts.get(key)||{}).at).filter(Number.isFinite);
        if (keys.some(key=>key.startsWith("moment:")) && Number.isFinite(input.moments.firstAt)) times.push(input.moments.firstAt);
        if (!times.length) return undefined;
        return new Date((newest ? Math.max(...times) : Math.min(...times))*1000).toISOString();
    }
    // A row that leads somewhere takes the key of the source it leads to; a row holding others leads nowhere itself.
    function drawn(row) {
        const linked=row.rows ? undefined : row.sources.find(key=>open(key)), id=linked || row.id;
        return {id,title:row.title,detail:row.line,at:at(row.sources),tone:row.failure ? "failed" : undefined,open:linked ? open(linked) : undefined,
            rows:row.rows ? row.rows.map(drawn) : undefined};
    }
    for (const area of ["did","ahead"]) {
        const rows=[];
        for (const row of decision[area]) {
            const shown=drawn(row);
            rows.push(shown);
            row.details.forEach((title,i)=>rows.push({id:"detail:"+shown.id+":"+i,title,tone:"quiet"}));
        }
        if (rows.length) sections.push({id:area,title:area === "did" ? "What I did" : "Ahead",
            style:area === "did" ? "timeline" : "list",rows});
    }
    const earlier=decision.earlier.map(group=>{
        const order=group.members.slice().sort((a,b)=>facts.get(b.key).at-facts.get(a.key).at);
        const tone=group.failure ? "failed" : "quiet", fold=group.kind && group.members.length>1;
        const rows=fold ? order.map(m=>({id:m.key,title:m.title,value:m.value || undefined,
            at:at([m.key]),tone:m.failure ? "failed" : "quiet",open:open(m.key)})) : undefined;
        const target=group.failure ? order.find(m=>m.failure) : order[0];
        return {id:fold ? "earlier.decided."+group.kind : target.key,title:fold ? group.title : target.title,
            value:group.value || undefined,at:fold ? at(group.sources,true) : at([target.key]),
            tone,open:fold ? undefined : open(target.key),rows};
    });
    for (const row of decision.omitted) earlier.push({id:"omitted:"+row.id,title:"Today row "+row.id+" omitted",
        detail:row.sources.length ? "Missing facts: "+row.sources.join(", ")+"." : "No source.",tone:"quiet"});
    const gaps=input.availability ? input.availability.unavailable.slice() : [];
    for (const [field,label] of [["moments","Memory"],["dream","Dream"],["nextDream","Dream schedule"],
        ["toward","Direction"],["thinking","Thinking"],["intentions","Intentions"]]) {
        const source=input[field];
        if (["unavailable","partial"].includes(source.state)) {
            gaps.push(label+" source "+source.state+"."+(source.reason ? " "+source.reason : ""));
        }
    }
    [...new Set(gaps)].forEach((title,i)=>earlier.push({id:"source-gap:"+i,title,tone:"quiet"}));
    // A section holds at most 256 rows, nested ones counted, so a folded group weighs what it holds.
    const weight = entry => 1 + (entry.rows || []).reduce((sum, child) => sum + weight(child), 0);
    let part = [], used = 0, offset = 0;
    const close = () => { if (part.length) { sections.push({id:"earlier:"+offset,title:"Earlier",style:"values",rows:part}); offset += part.length; part = []; used = 0; } };
    for (const entry of earlier) {
        if (part.length && used + weight(entry) > 256) close();
        part.push(entry); used += weight(entry);
    }
    close();
    sections.push({id:"queues",style:"flow",rows:[
        {id:"approvals",title:"Approvals and past decisions",open:"page:today/approvals"},
        {id:"inbox",title:"Every note I've left you",open:"page:today/inbox"},
        {id:"rem",title:"Growth proposals",open:"page:today/cognitionProposals"}
    ]});
    const failed=(input.notes || []).filter(n=>n.failed === true).length;
    return {title:"Today",line:dayLine(input,decision.did.reduce((n,row)=>n+(row.rows ? row.rows.length : 1),0),failed),sections};
}
function dayLine(input,did,failed) {
    const part=input.hour<12 ? "morning" : input.hour<17 ? "afternoon" : "evening";
    const day=did===0 ? "A quiet "+part+" so far." : did<=2 ? "A quiet "+part+"." : "I've had a full "+part+".";
    const n=input.waiting.count;
    const countWord=count=>["one","two","three","four","five","six","seven","eight","nine","ten"][count-1] || "several";
    const wrong=count=>{ const w=countWord(count); return w+" "+(count===1 ? "thing" : "things")+" went wrong."; };
    const cap=text=>text[0].toUpperCase()+text.slice(1);
    if (!input.waiting.readable) return failed>0 ? day+" "+cap(wrong(failed)) : day;
    if (n===0) {
        if (failed>0) return day+" Nothing waits for your answer; "+wrong(failed);
        return input.moments.state==="available" ? day+" Nothing is waiting on you." : day;
    }
    const waiting=cap(countWord(n))+" "+(n===1 ? "thing is" : "things are")+" waiting on you.";
    return failed>0 ? day+" "+waiting+" "+cap(wrong(failed)) : day+" "+waiting;
}
