/* NativeAgent ability
{
  "id":"workspace-readout", "kind":"tool", "version":1,
  "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
  "face":{"projection":true},
  "record":{"description":"Compose Today, Music and helper workspace faces from native read facts, selecting only bound item and action keys.","actions":[],"inputSchema":{"type":"object","required":["mode"]}}
}
*/
function face(input) {
    if (input.mode !== "helpersRoom") throw new Error("The workspace face requires a native helper-room packet.");
    const decided=run(input);
    const sections=[{id:"header",rows:decided.header.map((title,i)=>({id:"header:"+i,title}))}];
    for (let i=0;i<decided.rows.length;i+=256) sections.push({id:"helpers:"+i,rows:decided.rows.slice(i,i+256).map(r=>({id:r.key,title:r.detail}))});
    sections.push({id:"empty",rows:decided.empty.map((title,i)=>({id:"empty:"+i,title}))},
        {id:"verbs",rows:decided.verbs.map(v=>({id:v.key,title:v.label}))});
    return {sections};
}
function run(input) {
    const text = v => typeof v === "string" && v.trim() ? v.trim() : null;
    const labels={create:"Create a helper",replies:"Saved replies",all:"All helpers",open:"Open helper",talk:"Talk",
        conversation:"Open conversation",run:"Run once",settings:"Settings",play:"Play",pause:"Pause",next:"Next track",
        previous:"Previous track",playlist:"Play a playlist",track:"Play a song",find:"Find in library",playlists:"Playlists"};
    const action = key => ({key,label:labels[key.split(":").slice(-1)[0]]});
    if (input.mode === "helpersRoom") {
        const ordered=input.rows.slice().sort((a,b)=>Number(b.running)-Number(a.running) || (b.runAt === null ? -Infinity : b.runAt)-(a.runAt === null ? -Infinity : a.runAt));
        const busy=input.rows.filter(r=>r.running).length, paused=input.rows.filter(r=>r.paused).length;
        return {header:["HELPERS",input.rows.length+" helper"+(input.rows.length===1 ? "" : "s")]
            .concat(busy ? [busy+" running"] : []).concat(paused ? [paused+" paused"] : []),
            rows:ordered.map(r=>({key:r.key,detail:r.cadence+" · "+(r.age === null ? "never run" : "ran "+r.age+" ago" )})),empty:["no helpers yet"],
            verbs:[{key:"open",label:"open its room"},{key:"run",label:"run it once now"},
                {key:"say",label:"sends a message now (text)"},{key:"settings",label:"change how it works"}]};
    }
    if (input.mode === "today") {
        const overdue=input.rows.filter(r=>r.overdue), counts={};
        const items=input.rows.filter(r=>!r.overdue).filter(r=>{ counts[r.area]=(counts[r.area] || 0)+1; return counts[r.area]<=8; })
            .map(r=>({key:r.key,title:r.area+": "+r.title,content:null,actions:r.actions.map(k=>({key:k,label:null}))}));
        const content={status:"ok",sections:input.sections,
            scope:"At most eight appointments today and eight incomplete reminders due today; overdue ones are counted, not listed. Empty and unavailable sections are different. Open each area for more."};
        if (overdue.length) {
            const oldest=overdue.filter(r=>r.due!==null).slice().sort((a,b)=>a.due-b.due)[0];
            content.message=overdue.length+" overdue reminder"+(overdue.length===1 ? "" : "s")+", "+(oldest ? "oldest from "+oldest.month : "oldest date unavailable")+" · today.due lists them";
        }
        return {title:"Today",content,items,actions:[{key:"calendar",label:"Today's calendar"},{key:"due",label:"All due reminders"},
            {key:"desk",label:"Desk (work in progress)"},{key:"refresh",label:"Refresh today"}]};
    }
    if (input.mode === "bots") {
        const items=input.rows.map(r=>({key:r.key,title:r.name,content:null,
            actions:r.actions.filter(k=>!input.selected || !k.endsWith(":open")).map(k=>k.endsWith(":pause") ? {key:k,label:r.paused ? "Resume schedule" : "Pause schedule"} : action(k))}));
        return {title:"My helpers",content:{},items,actions:(input.selected ? ["all"] : ["create","replies"]).map(action)};
    }
    if (input.mode === "music") {
        if (input.state === "unavailable") return {title:"Music",content:{},items:[],actions:["play","pause","next","previous","playlist","track","find","playlists"].map(action)};
        const r=input.result, now=input.tool === "music_control" ? r.now_playing : r;
        function playing(row) {
            if (row.playerState === "not_running") return "Music isn't open. music.play starts it.";
            if (row.track === null) return "Nothing playing.";
            const track=row.track, name=text(track.name);
            if (!name) return "Nothing playing.";
            function clock(n) { n=Number(n); return Number.isFinite(n) && n>0 ? Math.floor(n/60)+":"+String(Math.floor(n)%60).padStart(2,"0") : null; }
            const state=row.isPlaying === true ? "Playing" : text(row.playerState) ? text(row.playerState).toLowerCase().replace(/(^|\s)(\S)/g,(_,space,c)=>space+c.toUpperCase()) : "Paused";
            const parts=[name+(text(track.artist) ? " — "+text(track.artist) : "")];
            if (text(track.album)) parts.push(text(track.album));
            const at=clock(track.position_seconds), of=clock(track.duration_seconds);
            if (at && of) parts.push(at+" of "+of);
            return state+": "+parts.join(" · ");
        }
        const content={}, items=[];
        if (["music_now_playing","music_control"].includes(input.tool) && !input.failed) content.message=playing(now);
        [...(r.results || []),...(r.tracks || [])].forEach((track,index)=>{
            const name=text(track.name); if (!name) return;
            const key="track:"+index;
            items.push({key,title:name,content:null,actions:[action(key+":play")]});
        });
        if (!items.length && !content.message && text(r.reason)) content.message=text(r.reason);
        const counts=new Set();
        (r.playlists || []).forEach((list,index)=>{
            const name=text(list.name); if (!name) return;
            const count=list.track_count === undefined || list.track_count === null ? null : Math.trunc(Number(list.track_count));
            if (count !== null && text(list.special_kind) && text(list.special_kind) !== "none") {
                if (counts.has(count)) return;
                counts.add(count);
            }
            const key="playlist:"+index;
            items.push({key,title:name,content:{summary:count === null ? "Track count unknown" : count+" track"+(count===1 ? "" : "s")},actions:[action(key+":play")]});
        });
        return {title:"Music",content,items,actions:["play","pause","next","previous","playlist","track","find","playlists"].map(action)};
    }
    throw new Error("Unknown workspace readout mode: "+input.mode);
}
