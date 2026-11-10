# NativeAgent Ability Header and Spec

Every `abilities/<id>.js` or `.md` is a part: a JSON header in a
`/* NativeAgent ability … */` or `<!-- NativeAgent ability … -->` comment,
followed by its code or retained guidance. `kind` is `ability` (what they
grows), `sense` or `turn`. All kinds have the same header and one
524,288-byte (512 KB) source limit. An ability is an ability: what it can do
is what it declares, never which door made it.

`turn` (`abilities/turn.js`) exports `step(state, event) → {state, do:[effects]}`; the stem owns the loop. Events:

- `message`: the moment, read-only: `text`, `surface` (authorizing) and `door` (arrival), `attachments`, `who` (`person`, `self` or `agent:<id>`), `verified` (transport-attested user id or null), `trust`, `steered_by` (steering peers) and `posture` (`full_mac`, `work`, `safe` or `unreadable: <cause>`; the saved posture, which untrusted steering caps to Work at each gate).
  A thought of the agent's own (session `mind`, `who: "self"`) also carries `attended`: `mode` (`awake`, or `waking` for what waited through sleep),
  `class` (the node it ignited on, or the owed kinds and doors it carries), `node: {key, about}` and `drive` when a node ignited it, `happenings`
  (each happening's fields with its record `id` and `at`), `readings` (the `felt` it was weighed with), `unread` when a reading failed, and
  `noop: {tries, empty, lower, stands, silent}`, its class's no-op record by `Expectation`; `silent` is the stem's one draw at the
  rule-of-succession rate, so a replay reads the same. The seed ends the thought on CPU with `reply.end` when `noop.silent` is true.
- `model`: final text and requested calls, each with `id` and `index`. Visible text streams directly; no chunk events. If readable, untainted words from the person wait before the proposal reaches the part, the stem keeps the prose and delivers an `observation` naming the unstarted calls instead. The part decides again; no turn-program edit is required.
- `result`: one call's `{index,id,name,ok,effect}`; their own call's result has its `id` and no `index`. A round's last result may carry `practice: {route, hand, loop?: {call, count}}`, the familiarity nerve's signal for their next thought. Effect comes from explicit receipts, else `execution:executed`, including batch receipts/script ledgers: an ability's all-read ledger reports `read`; `part` names effectful ability/sense work, else strongest of irreversible/write/read; absent when nothing landed. The broker's per-call class, not declared ability permissions or its prose, decides whether a reached call reads.
- `provider_failure`: provider, model, text, remedy, work, owed, tries and available repair calls.
- `observation`; `resumed`, whose `effect` uses the same reading over saved receipts.

The same program may define `hear(h, felt)`, a CPU-only judgment while a model
round generates. `h` carries `kind: "arrival"`, `who` (the origin
principal), `door`, `words`, `trust` (`trusted` or `untrusted`) and `steered_by`; `felt` carries the turn's gathered
`runtime` and the checked `notebook`. It has the same effect-free host as
`weigh`, without `step` state or reach. Only an arrival the open turn can read
reaches it. `{cut: true}` closes this round's stream and discards its calls;
prose stays said and the next request reads arrivals. Nothing, `{}` or
`{cut: false}` leaves the stream open. A missing `hear` retains boundary reads.
A thrown or malformed judgment owes repair, cuts nothing and never invokes
step recovery. The shipped seed cuts only for the person's untainted words;
installed programs gain `hear` only through their agent's authored revision.

Calls handed to dispatch still face the person's arrival at each start boundary.
A skipped slot keeps its result event and wire pairing, with no landed `effect`;
its receipt says `skipped`, `not_run`, `effects: none`, `reason: person_arrival`.
A running call is never cancelled by an arrival. App batches check between
steps and return the remaining `unrun` entries beside completed receipts.
Earlier failures, including nested receipts, keep the batch failed with its
remedy and provider error bit; a hand-back only adds which steps did not start.

Effects are `model.call`, `app`, `reply.stream`, `reply.end`, `after` and `notebook`. `model.call` accepts `effect`, optional `id`, `purpose`, `note` (adds
the agent's words before the call); the first requires `system:{stable,dynamic}` and may name `tools:[names]`. Later `system`/`tools` and all
`messages`/`stream`/`chunks` fields fail validation and trigger current recovery; the stem owns conversation and streaming. This ABI differs from the host
primitive `host.model.call` below.
`app` either runs one model-requested call verbatim, by id or index, or, at any step, runs their own `call:{tool:"app",input:{…}}`, named `own_<event>_<position>_<input digest>`; each runs once through the turn's door and gates, and resume never reruns a started one. A step cannot call `app.*` itself (`effects_only`): steps replay.
`notebook` is `{effect:"notebook", set:{…}}`: it merges `set` into the turn program's notebook (`attention/notebook.json`; a null value removes
its key), the settings `weigh` reads ("hold the world until five"). An unchanged merge writes nothing, including an empty merge or removing an absent key.
It runs once and a replay matches it by identity; one without an object `set`
is malformed and invokes recovery.
`reply.end` may come at any step, after their own words or none; in its step only
`after` may follow it, and nothing of theirs runs after it. With no words or selected
attachments, a silent end posts nothing and settles completed. The heard
experience's `answer` obligation settles `accepted` with silence evidence naming
the turn ([turn anatomy §6](ANATOMY_OF_A_TURN.md)). Reach: `turn.persona()`,
`turn.pins()`, `turn.recall()`, `turn.context()`.

<a id="weigh"></a>

`turn` may also define `weigh(h, felt)`: what a happening nobody asked about (`world`) or a care of the agent's moving (`self`) is worth, in
thoughts (one ignites a thought). The stem runs it on CPU outside any turn, through the same source-bound helper turns lease, with no reach
(`TurnWeigh`, `ChatTurnRuntime/TurnPart.swift`; the prelude's `run` dispatches `{weigh}`). `h` is the happening (`kind`, `subject`, `door`, `who`,
`words`, `once`, and for `self` `care`, `moved`, `open`). `felt` is `touch` (the nearest live care: `care`, `id`, `standout`, `bar`, `charge`,
`depth`, `seed`; `{unavailable}` when nothing can judge; null when no care is live), `yield: {hits, tries}` (thoughts on that node through that
door within the record's horizon), `presence`, `quiet`, `busy: {open, idleMinutes}`, `mode`, `affect: {arousal, taskPressure, warmth}`, `body:
{fatigue, curiosity, vigilance, novelty}` or null, and `notebook`. A `night` line from `sense:night` also carries `rest: {awayMinutes, activeShare, hoursSinceNight}`;
null means the named evidence is absent. An `hour` line from `sense:hour` carries the same `rest` plus `curiosity` (a number or null).
Its `self` kind gathers on subject `hour`; `yield` reads that thought class through `sense:hour`.
The seed gives it worth `2 * curiosity * min(1, (yield.hits + 1) / (yield.tries + 1))`, or zero without curiosity.
Its ordinary thought carries `attended.hour`, the offered material, alongside its happenings and readings.
[Subconscious: Attention](SUBCONSCIOUS.md#attention) owns the night policy. It returns a number, or an object whose `worth` is that number and whose other
fields are recorded beside it in the `attention.weigh` detail. A program without `weigh` is never upgraded by launch: what it would weigh waits
unweighed and one `body` happening per program digest tells the agent of the organ to grow, showing the seed's. A `weigh` that throws or returns
no finite worth leaves the same wait and says so once per program; a helper that cannot run it leaves the wait and logs it. What waited is weighed
after every thought settles, when admission opens and on waking.

The seed returns zero worth for a judged touch with `standout < bar`; at or above the bar it keeps the charge, yield and felt-state weighting.
Below-bar happenings remain on the record. The installed turn program changes only by the agent's own hand; a seed change does not replace it.

The turn program is the one shipped id the agent revises: `ability.save {id:"turn", code | edits, why}` (`Parts+TurnProgram.swift`) under the
save law, kept and on in one act under Full Mac for the agent's own work and the owner's otherwise, the replaced version kept as `turn.prev.js` for
the turn recovery exception. Every revision of it is a trial carrying its `why`, judged per turn from the traces against the kept self in
`turn.prev.js`, whose turns the night keeps on the trial (`kept_turns`) the first time it reads them, since traces are forgotten past their
horizon. Turn comparisons and baseline freezing require complete trace details and an available correction ledger; partial or whole-source
gaps leave the trial open as `unread`. Frozen turn baselines carry `counting:"settled_turn_union"` and
`evidence:"complete_traces_and_corrections"`; a baseline without that evidence, or with counts outside its settled
uses, is named unavailable and preserved for repair, never judged or silently reconstructed from a shortened trace window.
A trial never became the agent: revising the version under trial supersedes that trial and leaves `turn.prev.js` the kept self,
transferring its already frozen `kept_turns` into the new trial's opening write under the same lock. A different kept version inherits no baseline.
The proposed turn file is fully encoded before either retained slot changes. Publication rechecks the exact selected file under its lock;
a stale save changes no slot. A failure after a slot write reports partial or unknown effects and asks for both retained versions to be read.
`ability.save {id:"turn", set_aside:true, why?}` saves `turn.prev.js` forward and keeps it there, so the version set aside is no throwing turn's way
back; a heal away from the version under trial closes that trial as set aside. `ability.read {id:"turn"}` shows the agent's program with `weighs` and the seed's `seed_weigh` beside it; the organ's
`body` happening names both calls.

`turn.persona()` supplies the compiled `prompt`, caller-supplied `guidance` and
`expression:{established:bool|null}` for ordinary turns (the whole expression is
null for internal thoughts). An unavailable user-memory read makes `established`
null, not false; the seed adds first-run guidance only for an explicit false.
The turn seed owns baseline and first-run expression instructions, with no
persona edits. `turn.context()` supplies tools, digest, packet, history, facts
and optional `runtime:{view_mode,contacts,fact_index}`. The native report of the
admitted surface/provider/model remains in `facts`; contacts are `{status:"available",rows:[...]}`
or `{status:"unavailable",reason}`. The seed authors model-reporting and setup
advice from these facts; `fact_index` identifies the report in `facts`, where
the seed adds its words. Swift retains settlement classifiers and identity storage.

A settled Desk wait returns as a `returned` happening (`EngineRuntime/EngineTurnContinuation.swift`): to the conversation that started the work
with its recorded reply route, or to the mind stream for a helper's item. Its line names the item; beside it the thought is shown the checked
record's remaining work, last twelve settled receipts and first 1,000 characters of the last reply. Native verification, claims, CAS, scope and
settlement remain authoritative.

<a id="turn-recovery"></a>

The turn log keeps events, reach answers, started-effect identities and streamed text for identity-matched resume/replay. Payload hashing supplies identity only for effects without an explicit identity; starts do not store a separate digest. Current selection reads `turn.js`; only a missing current slot installs the shipped seed, and that write must succeed before it runs. An unreadable or wrong-kind current slot ends with its storage cause and repair, without consulting another version.

Every non-Stop failure of the selected turn program or its helper invokes the one exception in [NORTHSTAR clause 2](NORTHSTAR.md#clause-2--no-theater-alive-means-real), including JavaScript exceptions, invalid answers, timeout, startup, resource and transport failures. Recovery consults the previous slot, or selects the shipped seed if no unfailed previous source exists, and replays the same identity-matched log. Each source is attempted once per turn; a helper failure while running the seed admits one extra fresh lease (`freshHelper:true`), through the same checked current-slot admission. A consulted unreadable previous slot or failed recovery write ends with its storage cause; an uncommitted replacement never runs. A concurrent checked current write is adopted without swapping it unless already failed this turn. `turn.part.unavailable` preserves the original helper cause; `turn.part.recovered` names `program` (`previous`, `seed`, or a concurrent `current`) and `sourceDigest`, and `turn.part.helper` proves the selected source ran. The repair arrival tells their which program replaced the failure or which helper lease was renewed. Stop remains cancellation. If every available source fails, recovery ends plainly rather than retrying forever; provider failures keep their own turn path.

| Property | Stored form and meaning |
|---|---|
| **code** | The file body, outside the JSON comment; JavaScript or retained Markdown guidance. |
| **reach** | `{capabilities: string[], readPaths: string[], hosts: string[], apps: string[]}`, all arrays default empty. Ordinary abilities consume `capabilities`, including `app_read:<id>`/`app_write:<id>` for app targets; with `computer_files`, `readPaths` bounds an ability's `host.files.query` and `host.files.mime` (a `*` is one path component; a directory covers what is beneath it); `hosts` and `apps` constrain senses only. Retained historical headers and sense reach load into this shape; ability saves take `reach`. Declarations do not grant authority. |
| **wake** | String array, default `[]` (called only). [Wake signals](#wake-signals) defines names, payloads and delivery. |
| **face** | `{page?: string, action?: string, projection?: bool}`, default `{}`. An authored tool's action lists on this door page, or diagnostics when absent; `action` claims an unclaimed door id, never beside `answers`. Unknown pages refuse at save. `projection:true` declares `face(input)`; its typed sections/rows are computed from frozen native sources outside view rendering and published through `LatestRead` (contract below). |
| **answers** | Door verbs the part answers, by action id: `{description, class, args, irreversible?, screen?, summary?}` each, absent when none. `class` is `read`, `write`, `send` or `destructive`; `args` is the verb's JSON Schema (no argument named `verb`). The door registers each verb on `face.page` with that contract and judges it by its class, its Mac integration switch taken from the part's `app_read:`/`app_write:` reach; a verb a native declaration still holds stays native, and a verb two active parts answer is the first by id. `run(input)` receives `{verb, ...args}`; the part's input schema is derived from the verbs and takes no `params`. A `read` verb runs read-confined: read-only app events, read actions and read primitives only. A class other than the four refuses at admission. A verb a shipped seed answers keeps that seed's class and irreversibility as its floor: a revision may raise them, never lower them; and every revision's keep passes the one keep gate (the person's card below Full Mac, the agent's own keep under Full Mac). |
| **state** | Abilities use `host.state.get()` → saved JSON (initially `null`) and `host.state.set(value)` → `null`. One durable notebook owner, shared with senses' keyed `state.get/set`, stores it by ability id at `senses/<id>/state.json` under key `part`; it survives helper restarts and app relaunch, and `ability.drop` deletes it with the ability. Values are limited to 16 KiB and the notebook to 64 KiB. Validation and preview use a scratch notebook. Resume replays journaled state results without repeating their operations, then reads and writes durable state normally. State calls do not renew stalled execution. `abilities/state.json` remains lifecycle/run accounting only; there is no authored header `state` key. |
| **learned** | Optional arbitrary JSON, preserved verbatim; a declared value teaches nothing, and a declared `trial` is refused at save. The stem projects `learned.use`, `learned.versions`, `learned.trial` and `learned.trials` (below). A part's prediction (`applies`, `after`, `record`) is the stem's, never declared: see [Expansion](#expansion-a-part-is-a-prediction). |

`id` and integer `version` identify the part and version.

### Wake signals

Accepted: `schedule:<cron>`, `app.installed`, `file.changed:<path>`, `turn.ended`, `message.arrived:slack`, `message.arrived:telegram`, `held`, `resumed`, `person.away`, `person.here`, `network.down`, `network.up`, `chrome.tab_taken`; suffixes are nonempty. Existing files naming another transport still read; new versions must use this set.
While on and Autonomy allows unattended work, an ability runs as `authored.<id>`, a sense receives an event in its resident slot. Signals bypass params checks, supplying only `input.wake={signal,at,...payload}`:

- `schedule:<cron>`: one time on the one clock per part and schedule (`part:<id>:<cron>`, five-field cron), declared from part headers and
  withdrawn when the wake is removed (`EngineScheduledWork.declarePartTimes`); each occurrence posts the signal to that part, coalescing like any
  identical pending signal.
- `app.installed`: `bundle_id,name,version,path,scriptable`, as data. Once per newly seen bundle/version after the baseline, after Info.plist and its declared scripting dictionary land.
- `file.changed:`: the signal keeps the declared watched path, including a folder
  (never a child-path signal). `changed:[{path,change}]` names added, edited
  (identity changed) and removed members, recursively within the senses' bounded
  directory manifest. `path` names the changed member when exactly one changed,
  otherwise the watched folder. Directory size/mtime churn alone is not an edit;
  directory additions, removals and replacements are news. A single watched file
  uses the same change records and keeps its own `path`. Each arrival retains up
  to 50 records, sorted by path; `changed_more:N` counts records beyond that cap
  and is absent when none were omitted. Arrivals for the same watched path and
  provenance coalesce into one waiting wake per part, merging their change lists
  under the same cap and adding omitted counts. Successive changes to a member
  remain separate records; a merged `path` names that member only if every
  arrival names the same one. A gated ENOENT read establishes an absent root:
  previously observed members are removed and the baseline becomes empty, so
  later creation is added. The same source subscription waits through absence.
  An unavailable reading preserves its last admitted identity. A failed read
  cannot prove deletion. A repaired reading signals watch `available:true`, including a checked
  absent root and `changed:[]` when no earlier identity was admitted or no member changed;
  ordinary changes omit `available`. Exact self-write suppression stays tied to the declared watched path,
  including the folder rather than a changed child.
- `turn.ended`: `turn_id,outcome,session_id,seq` (`Int64` sequence of the terminal detail in the life record);
  excludes turns the ability's own run started.
- `message.arrived:telegram`, `message.arrived:slack`: `text,session_id,turn_id` and chat/channel/user ids, after handling.
- `held`: the held resource's `id,kind` (`program`, `connection` or `listener`) for a resident ability, once per arrival. Runs serialize; duplicate waiting news coalesces. `receive`/`accept` reads it; an empty wait returns `pending`. Unread arrivals survive Autonomy-off or unreadable-catalog periods.
- `resumed`: once per app launch, for code to reopen held resources; likewise waits for Autonomy and a readable catalog.
- `person.away`, `person.here`: Mac edges carry `idle_seconds` (300 s idle;
  then the person's own input, never theirs). Fresh phone walking/driving newer
  than physical Mac input can also emit `person.away` with `source:"phone motion"`.
  The first physical input after phone departure emits `person.here` even
  before the Mac's 300-second idle threshold. Mac and phone reports of the
  same absence emit one signal, including phone evidence delivered late.
  `PersonPresence` owns that combined reading for home, senses, capsule and
  queue conditions. Unknown/stale phone evidence emits no presence verdict.
  `mac.system_info {person:true}` remains the raw Mac-input fact for hardware
  decisions. [Phone evidence contract](mobile_companion.md#where-the-person-is).
- `chrome.tab_taken`: `tab_id`, `reason`, `host` when the tab had one, the moment the person selects, touches or navigates one of the agent's Chrome tabs. It
  also posts a world happening (door `chrome`) that attention weighs like any other. The agent's own close and group changes do not post it. The person can
  still take a tab after this has passed, so `tab_not_owned` stays the final answer on a call.
- `network.down`, `network.up`: `is_up`, from the one process-wide `NetworkSense` path owner, through the same signal delivery as presence. The first
  observation establishes the launch baseline; later changes must hold five seconds before posting, and a flap back to the last posted state posts nothing.
  This reports a usable Mac network path, not provider health. Transport waits read the immediate state; abilities and `on network.up` intentions receive the
  settled signal.

`agent` identifies non-owner words (untrusted steering or a non-allowlisted sender). The run uses current Trust and its own gate chain. A tainted signal skips write-capable parts with a trace and no card; trusted-agent signals carry owner authority. Required approvals wait; requests for their use `home.arrive {line}`, deduplicated per ability/day/line on its hop-limited thread (an explicit `event_key` uses durable occurrence deduplication instead).

### Calling a part and projecting its face

JavaScript `part.call(id, input)` returns `{ok:true,value}` or
`{ok:false,error:{code,message}}`. Declare the callee's `authored.<id>` in
`actions`; this is reach, never authority. Input is a JSON object up to 4 MiB,
deeply frozen, with the version pinned before suspension. Replacement/off can end that invocation
but never substitute another version. Returns are complete JSON up to 4 MiB;
truncation fails. Swift uses `Parts.call(id:input:preview:within:as:)`, returning the same
`PartCallResult<Value>` with a Codable, Sendable value. Native callers bind the
originating gated `OwnedProgramInvocation.host`; they validate and commit the
decision in their own transaction after the call returns. Optional
`within: Parts.CallReach` narrows the selected version's actions and primitive
capabilities, checked before any suspension or effect; it grants no authority.
Native `preview` defaults false; true propagates the runner/host preview posture
through nested calls without changing version pinning, typed answers or settlement.
Stop cancels work;
child settlement, terminal accounting and broker release run through `settle`.

With `face:{projection:true}`, `function face(input)` (optionally async) returns a page:
`{title?,line?,detail?:{of:<section id>},sections:[{id,title?,style?,footer?,folded?,rows?:[...],block?,more?,filter?,revision?}]}`.
A section has rows or a block, never both in authored output.
A document block is `{kind:"document",key,text?,format?:plain|markdown|code,language?,copy?}`.
A form block is `{kind:"form",key,fields:[{id,label,kind,value?,placeholder?,required?,options?,min?,max?,step?}],
submit:[{id,label,role?,unavailable?}],revision?,protected?,receiver?,doors?}`. Field kinds are open strings;
current doors draw `line`, `lines`, `choice`, `switch`, `number` and `date`. Options are
`{id,label}`. Missing optional values stay absent, required fields validate before dispatch,
and errors name the field id. A protected authored form has `protected:true`,
`receiver:"keyring:<name>"`, `doors:["mac"]`, exactly one `secret` field without `value`,
and packet-owned submit calls to that exact receiver with no arguments. The Mac
mounts it only after capture exclusion is acknowledged; secret bytes stay in its
transient host and travel through a typed credential act, never ordinary form
arguments, drafts, records or feedback. The body validates the current form and
writes its Keychain owner without granting destinations. It supplies only presence
(`secretSet`) and the exact owner namespace (`secretPage`); authored faces cannot
supply either. Page prose says set, not set, or status not read. The phone says this
opens on the Mac; installed older phones retain the section's update note. Ordinary
form actions still refuse secret fields. Unknown field kinds draw the update note.
Each submit binds to `keys[key].submit[id]`, a call `{action,args?}`. The submitted object
supplies field arguments; the key's fixed arguments win. The owner compares the drawn
base call and form revision before running anything. The Mac carries that object as
`PageActRequest.value`; the signed phone carries its JSON as `values` and the revision
as `formRevision` inside the existing string-map envelope. Page text lists labels,
committed values and submit calls; unfinished values belong only to the door session.
The retained operation records each field's submitted edit revision. Only explicit
owner `committed` fields settle edits; later typing remains and rebases on that committed
value. A failure keeps the draft and field errors. A known failure with no effect
releases submit with its cause. An unresolved effect stays held; read-current-state
keeps the original operation identity and never resubmits it. A failed read keeps
that hold; successful owner evidence or approval execution/decline settles the
same operation through the shared session. Consent alone proves no execution.
Cancel awaits the owner's actual settlement.
A native leaf is `{kind:"leaf",key,leaf,ref,alt}`: the owner resolves its resource;
`alt` is its text representation. A missing grant or unsupported leaf shows its words,
and never opens another resource. Graph is a leaf; its surrounding list and detail remain faces.
Kind is an open string; `Style`, `Tone`, `Role` and `Status` keep their existing values.
Inline text is at most 16 KiB. Without inline text, the document's key declares
`read:{action,args?}`. The reader checks the current call and its read-only declaration,
runs it through the originating app door, freezes the result as `input.read`, and invokes the
same selected pure projection. Only complete read evidence permits unwrapping a `result` field;
otherwise the owner's structured outcome, including continuation and remedy, enters `input.read`
unchanged. Pending or unknown evidence is never relabeled as a terminal document-read failure.
That demand projection supplies the requested document's text;
its long body goes to the document reader, never into the retained page or `faces.json`.
An inline document's text is also readable by its key. Page text names its opening words,
known byte length or its owed read, the read call and its `page:<page>/<key>` link.
Unknown kinds draw the update note. Encoding a block section supplies exactly one note row,
"Update NativeAgent on this iPhone to see this." Installed phones ignore the new block field
and draw that row; current doors draw the block. Native value copies retain the block.
A section's `style` is
`list`, `values`, `timeline`, `flow`, `note` or `waiting`; a `folded` section draws as one
row, its title, that each reader opens to see its rows (open or closed is the view's own,
never written to the face), and reads on the door as its title and footer, marked folded. A row is
`{id,title,detail?,value?,at?,symbol?,tone?,open?,actions?,control?,rows?,expands?}`: `at` is ISO 8601,
`symbol` an SF Symbols name, `tone` one of `plain`, `quiet`, `attention`, `failed`, `done`,
`live`; `open` leads to `chat:<session>`, `page:<page>[/<item>]`, `approval:<id>`,
`card:<id>`, `dream:<date>` or `url:<http(s) url>`; `actions` are up to four
`{id,label,role?}` (`plain`, `primary`, `destructive`); `control` is a switch `{on}`, a choice
`{options:[{id,label}],selected}`, a field `{text,placeholder?}`, a number
`{number:{value,min?,max?,step?}}` or a date `{date:<ISO 8601>}`, each with an optional
`confirm` question, and changing it is the action `set` with the new value. Ids are nonempty and
unique within their section including nested rows; at most 64 sections and 256 rows per section including children, within the same
4 MiB bounds. Faces run the same signed bytes in a fresh sandbox helper against frozen
sources, with no host effects or notebook access, through the one face door
(`ToolsFacade.face`, `withPartDoor` with origin `background:faces`). Swift
`Parts.face(id:input:version:)` returns `PartCallResult<PartFace>`. The result, face and
snapshot wire types live in `NativeAgentShared` for both Mac and iPhone; `FaceView` draws every
page on both, and `PartFaceSnapshot.text` reads it for the agent's door and Telegram.

A page's rows are bound to its packet (`PartFace.bound(to:levers:)`): the packet's `keys`
object declares each key a row, document or form may carry,
`{"<key>":{open?,actions?:[{id,role?,doors?,call:{action,args?}|open}],set?:{action,args?},read?:{action,args?},submit?:{"<id>":{action,args?}}}}`.
A row that opens, acts or holds a control has a declared key as its id, leads only to that key's
`open`, offers only its actions (a destructive one stays destructive) and holds a control only
when the key declares `set`; a row that only tells may have any id. The face names and labels an
action; what it does comes from the key alone. A face that breaks this does not draw, and the
page shows the stem's words for why.

Inline children use `rows` and nest to depth four within the section's shared 256-row bound.
An `expands:true` row declares its key's `read`; the window holds that demand while expanded.
Nested actions, controls and expanding reads bind to the same packet keys as top-level rows.
The authored face never supplies a call, read or resource authority of its own.

A long collection posts `more:{next:<cursor>,total?,revision?}` and its section id declares
`read:{action,args?}`. Its optional `revision` identifies the first page; each continuation carries
that revision. The held request supplies `args.cursor`, `args.anchor`, `args.revision` and,
for an owner query, `args.query`. The reader's frozen result enters the selected projection as
`input.read`, and the result is another face. A local `filter` label searches already-retained rows;
it does not fetch. A query demand's query and result share their request identity.

`detail:{of:<section id>}` makes that section the selection list. Each selected row links
`page:<page>/<item>`; the host holds the item's face while selected, under the `page/item`
namespace. Native owners register one structured item reader; authored owners use the item's
declared read and pure projection. Item actions re-read their owner before comparing the drawn
call, and use that item namespace for settlement. Item snapshots stay outside top-level
`faces.json`. A missing or unreadable item supplies its own error; a pending read stays waiting
with Cancel until its owner answers, closes or the demand is released. No clock supplies an outcome.
The agent reads the same structured item through `app {page,item}`; `offset` reads a current
collection page, without appending it to a previous revision. Collection prose names that page/item
route beside its cursor. Native Dreams, Graph, Cognition and memory upkeep are discoverable by their
registered page ids; their visual locations remain the existing tabs and destinations.

`FaceDoor.read` is the document's native adapter; `readFace` answers structured demands.
The existing signed `faceRead` command carries both, outside cognitive observation.
Structured demand replies encode the face as bounded JSON chunks in `FaceReadPage.text`;
the first chunk holds one owner answer and subsequent cursors read that held answer,
without rerunning the owner or regenerating a review token. Request id, cursor and
SHA-256 revision must match throughout. The phone decodes the face off its main thread
only after every chunk arrives; a failure supplies no partial face. Releasing the demand
removes its matching held identity and inverses, and a later continuation refuses it.
`FacePageSession.documents` retains its
request identity, answer, failure or explicit cancellation above cells. The page host holds
the demand; a document drawing starts no read. Each read lives while its demand is held;
changing other demands leaves it running. Removing its last holder cancels and releases it,
and a cancelled reading cannot satisfy a later demand. A read is not retried on cell remount.
Read identity includes its key, drawn call and native owner revision. Helpers publish their
definition's persisted update stamp as the brief revision. Changing that identity admits a new read.
Passive document readers require the identity of their source and hold their answer and projection
inside it; context disclosure uses session and turn, saved runs use the drawn record, and frozen
text uses its contents and format. Quiet capture draws
the held answer or its waiting state without starting lifecycle work. Both platforms use the
same read-only TextKit component for selection, Find and Copy. Copy uses the displayed characters,
including rendered Markdown, and is available once those characters are ready. The editable `native-document`
seed draws native document packets with a title, format and frozen opening/byte metadata;
the native owner keeps the body outside that packet. Its projection is restricted to one body
document and passive rows. The 16 KiB bound applies only to inline document text;
it does not bound the whole projection, its title or its passive rows. Context receipt rows carry no undisclosed body;
opening the disclosure reads the saved context record on demand, on the Mac. Receipt summaries
carry their source turn id so an open disclosure reads again when a later turn arrives.

**One act.** A row's action is a door call (`PartFace.Call {action, args}`, one `app` call) or a
place it opens; a control's change makes its key's `set` call with the new value as `args.value`.
The person's tap runs the row's call through the person's door (`PartFaces.act` →
`ToolsFacade.personTap`: the Mac, the signed phone, Telegram's one owner), read from the page as
it stands, never from the door; the agent makes the same call through its own turn's door, and
its door's page read prints each call. One Trust law judges both (`PermissionLaw`): a tap on a
row the stem composed (a lever, a key lever, a page the stem registered) is the person's own
decision of that exact call (`PersonAct`), admitted once per run; a row the agent drew on a page
of its own is the agent's call, so the tap only asks. A lever's verb (`owner: .person(why, asks:)`)
is never the agent's at any posture: its call raises the person's card, or is refused where no
card can carry it; a change that widens the agent's own reach is a lever the same way, and
lowering it stays the agent's. An owner of the stem's that needs the person's yes for an exact
call replies `needs_person`, and the gate puts that call on the person's card; Approve replays it
as the person's act.

Approval answers (`inbox.approve`, `inbox.deny`, and declining a pending approval
when putting it away) also accept one exact card on the person's own authenticated
message, through the shared [decision authority](TOOL_LOADING.md#authority-and-receipts).
They are not tap-only levers. The decision names that message and door; helpers,
wakes and peer-steered turns remain refused. If a message joins the running turn,
its exact authorization cannot be attributed and message decisions refuse;
missing or mismatched open-turn evidence also refuses. The agent asks for a tap
or a fresh message after the turn ends, never guesses an authorizing row.
Permanent deletion still requires a tap according to the tool's declared class.
A message decision needs a fresh turn
with only Inbox reads or approval-decision calls; any other started call, missing
execution evidence or checkpoint resume requires a fresh message or the person's
tap. Outside text from an earlier turn can remain in context: this is the agent's
judgment on the authenticated message, not proof of the person's intent.

**One card.** A card (an approval, or a request the agent raised) is its matter's Inbox row: the
Mac's chat, the iPhone's chat, the Inbox and Telegram's buttons all draw that row and answer it
through `PartFaces.act` on the Inbox page. Approvals reach the person's own conversation through
the one mirror requests use. Key entry is a protected shared form beside that row: a secret goes from its
transient field to its named owner, never into a face value, a part or a transcript.

**Levers.** What tells is the agent's; the person's authority over the agent (Trust and
consent, macOS grants, models and providers, keys, the off-switch on the agent's parts,
approvals, a trial's Set aside, forgetting, reset) is a lever, and levers are the stem's. A
lever belongs to the page or to a key, and the page's owner composes both beside the facts,
never among them. Page levers (`PartFaceSnapshot.levers`: minds, reset, the night's Set aside)
are sections drawn first by every door whatever the face says. Key levers
(`PartFaceSnapshot.keyLevers`: Forget on `memory:<id>`, Keep / Don't keep on `proposal:<id>`,
Veto on a pursuit) are rows keyed like the face's: every door draws a key lever's actions after
the agent's own on each row of the face with that id, so the face can neither omit nor reorder
them on a row it shows; when the face did not draw, the key levers stand as the stem's own rows
beside its words. No key a packet declares is a page lever's, no key declares an action its key
lever holds, and no row of the face takes a page lever's id or offers a key lever's action. The
lever pages (Settings, Trust, Providers, Connectors, Inbox, Capabilities, Helpers) are the
stem's own reads, drawn by the same `FaceView`.
Trial explanations (open, kept and set aside) pass through the secret-content policy
before clipping into Home or Today levers and their phone snapshots; the accounting record stays canonical.

**The agent's pages.** Desk, Memories, Personality and Diagnostics are drawn by the parts
`native-desk`, `native-memories`, `native-personality` and `native-diagnostics`: each page's
owner registers the part and its packet read (`PartFaces.register(page:part:read:)`:
facts, record epoch, page and key levers, owed), and `refresh(page:)` reads the packet and projects it.
Authored-page inventory failures reach page discovery and reads even before a first face exists; an unread inventory cannot establish an empty page list.
Declaration conflicts belong to their page ids: those pages expose their claim failures while unrelated valid pages keep their readers and faces.
Memories' phone projection uses a separate packet classified for `ios` by the memory owner before facts, keys or levers are built; it never
exports the unrestricted Mac face. Both use `native-memories` and the same canonical stores. At the packet owner, every facts string recursively passes
through `ContextSecretContentPolicy.redactedFragment`, and character clusters derive from those safe facts. Native memory/proposal lever text uses the
same policy before clipping. This covers kept/search records, pending/rejected proposals, lessons, provenance, queries and failures for both Mac and phone.
A phone tap reads its disclosed snapshot's own rows and retains the person's Keep / Don't keep decision.
A part whose face is `{projection:true, page:"<id>"}` is a page of the agent's own, `<id>`
being a short lowercase id no app page, alias, room or tab uses: its packet is its own notebook
(`host.state`, an object holding its `keys`), read again whenever the part writes it, and
`layout.write` places it as `page:<id>` on `rail` or `more`. A `face.page` that names an
app page (with or without projection) is where the part is placed, never a page of its own. Cached Codable `PartFaceSnapshot`s publish
through `LatestRead`. The Mac draws their page-keyed face-feed slots; the phone
decodes the same snapshot shape from `faces.json`. Presentation copy and Make
titles have distinct copy-key and file/revision slots. Agent page text reads the
engine owner's admitted result without waiting for a display frame. The catalog
of authored pages travels in its own slot, retaining inventory failures beside
known claims. Cancelled reads publish and cache
nothing; the last published snapshot stands, and the next ask may compute again with the same
version and source. A face is cached by the input it was drawn from: the same selected version
over the same input reuses it whatever epoch carried it. Source and ability-version changes drive recomputation.
Page file watches compare exact file identities off the main actor. Directory owners
select their read dependencies: diary discovery includes archives and traversal directories,
guidance uses its inventory, helpers use their definition files, and providers use their
configuration, routing and account sources. Trial levers compare trial fields through
their owner rather than run counters sharing `abilities/state.json`.
Directory source selection matches canonical paths, independent of a URL's trailing separator.
Selected files and traversal directories stay watched, including in-place edits and symlink
targets. Every link's own parent along the resolved chain is subscribed, including ancestor
links and links inside another link's target; any retarget rearms the selected tree.
Unreadable chains invalidate their owner's read and retain observed link parents for repair.
Unrelated directory metadata is not a reason to reread a page. Notifications still
reach their owners independently of file identity. Today watches its selected conversations,
and its facts exclude the unrelated experience-detail sequence used only for read ordering.
Its source owner holds one read and unions pending changes for the next read
of the latest state, without a debounce timer. Only changed sources are reread;
only changed or newly selected transcripts are decoded for conversation
evidence. Contact changes rename retained evidence. Equal finished source
readings retain a ready packet without assembly. Each intentions reading arms
one event deadline at its earliest next occurrence, invalidating intentions
alone when it passes; an empty reading cancels it. Opening Today consumes its posted face,
with a reading line until the first face arrives; it invokes no source reader.
Persona display-name publication invalidates only Today's trial source, and
an unchanged name causes no reread on other profile publications.
Native projection input is recursively masked by `Parts.prepareFace` before admission,
with reuse only for equal content, including unchanged packet subtrees. Direct calls
retain raw-input credential refusal. Home reuses derived sections from their retained
owner readings and unchanged thought, owed and repair content; clock-dependent queue
verdicts and trial levers still read the current time. Other page-source and Home
notification bursts retain their fixed coalescing windows.
Unavailable, failed and owed belong to native snapshot fields beside the face, never to
editable rows; a packet that could not be read publishes its cause, never an empty page.
Native invocation and publication details live beside `Parts` and `PartFaces`.

The person's page acts still enter `PartFaces.act` and resolve the owner's
current row. A caller that holds the selected call may require an exact match
before running it; Desk's palette Close does so after checking the revision it
showed. A delayed face cannot authorize closing a newer item revision.

`host.model.call({purpose,prompt,schema?,tools?,surface?})` may offer `["app"]`
or `[]` and select an existing routing surface. `messages:[{role,content}]`
may replace `prompt`; tool thinking ends with a user message. An explicit surface
uses its saved route independently of the parent's per-turn model choice; omitted,
the caller's admitted route is inherited. It uses the
canonical tool-turn owner, the part's restricted host, its originating gate
chain and the caller's remaining limits, taint and preview posture. The thought
has no reply destination, parent checkpoint, persona, recall or after-turn mind
work. Its own trace separates provider recovery and context evidence from its
caller; its heard/answer settle in Experiences through `settle`. Effect checks
retain the originating ask.
Its primitive receipt retains nested tool effects through failure, cancellation
and JSON validation; missing effect evidence is `unknown`. Offering tools makes
the call capable of effects for replay, even though thinking itself needs no card.

`app.home.arrive({line,event_key?})` posts the line as a `world` happening from the calling part, keyed by a supplied occurrence key within that
part, otherwise by local day and line; a repeat is the same happening and writes nothing. Peers that steered the run travel with it as taint; the
executor has no bundle/version policy and judges nothing. The agent's [`weigh`](#weigh) gives the line its worth
([SUBCONSCIOUS.md](SUBCONSCIOUS.md#attention)).

`choices` is optional arbitrary JSON, preserved verbatim; nothing reads it (for
example `{open_doc:["script","menu","screen"],date_format:[]}`).
`resident` defaults false. An ability retains its isolated helper/JS context after successful calls; each call gets fresh frozen input and originating authority. Error, refusal, cut or cancellation discards context. Preview, validation and replay use fresh contexts.
One resident broker holds programs, connections and listeners until closed, off, replaced, dropped or quit, including across failed runs. Code recovers their ids from `host.state` or `held` wakes; each use rechecks admission and Trust.
Sense retention uses `SenseRecord.mode`, not `resident`; `sense.make` creates `.onCall` senses.

### Expansion: a part is a prediction

Exact call matching and template grouping retain container type, presence and
empty objects/arrays. `JSONValue` owns leaf traversal and pointer operations;
Expansion requires completeness within 2,048 leaves and depth 128, while practice
searches its first 20,000 leaves. Incomplete bounded traversal cannot supply a template,
an exact match, a source index or evidence of a delivered value's use.
Prediction identity serializes the verb, full structural shape and every
slot's constant and sorted source paths. A changed mapping earns a new record;
historical records remain readable and cannot lend it standing.
Expansion diagnostics derive rejection counts from the retained example
window: insufficient examples, judgment without a source, no shared source,
incomplete traversal and unserializable shape/mapping. These explain missing
predictions without relaxing exact flow or adding persisted learning state.
Persisted accounting counters are nonnegative integers with checked
relationships (hits within tries, outcomes within run totals, reads within
successful runs). Increment overflow names the owning field and refuses the
accounting write; invalid records remain byte-preserved and unavailable.

Expansion gives a part three
fields, all kept by the stem and none written in a header: `applies` (the
situation it is for), `after` (what will be true when it has run, checked
against what the mind did next) and `record` (hits over tries). This version
keeps them for turn-start reads and follow-up calls a mind makes at the door,
per mind and authority (`own`, or `steered:<principals>` for turns untrusted principals
steered; one authority never learns from or is offered another's), in `<dataRoot>/expansion/record.json` (types in `ChatTurnRuntime/Expansion+Practice.swift`, writer in `Expansion.swift`):

```json
{"version":3,"practices":{"self\u0001own":{"agent":"self","steered":[],"lastAt":"<ISO time>",
  "situations":{"action:result.page args:cursor status:ok":{"lastAt":"<ISO time>",
    "examples":[{"at":"<ISO time>","call":{"action":"result.page","args":{"cursor":"c-2"}},
      "sources":{"/args/cursor":["out/next_cursor"]},"gap":6.1,"ran":0.2}]}},
  "records":{"<situation>\u0001<form>":{"situation":"<situation>",
    "form":"<serialized verb, structural shape and complete per-slot source mapping>",
    "tries":4,"hits":4,"lifetimeTries":4,"lifetimeHits":4,"unknown":1,"misses":0,"changes":0,
    "delivered":2,"prepared":0,"withheld":1,"costs":[0.2,0.3],"lastAt":"<ISO time>"}}}}}
```

`applies` is the situation key (the call's verb and argument names, the
result's status word, and for a turn's first call what
woke it) and the form its examples make: the last 8 next calls, each with the
paths of the step's call (`in/…`) and result (`out/…`) that held each of its
text or number values exactly. A form seen twice predicts when every argument
keeps a common source or is a structural constant (true/false/null,
the action id or a door page, or a member of the enum the action's schema declares
for it); a repeated free text or number with no source blocks the form; `call` is the mind's
own call, kept at most 4,096 UTF-8 bytes and never with a `:secret`
argument, a nested credential field or credential text recognized by the shared
secret redactor. `after`: unshown, the next call is exactly it; shown, a read's
distinctive value appears in the next call (called again is a miss, anything
else unknown); a prepared act is made. `record` is `tries`/`hits` since the
last change, the lifetime counts, `unknown`, `misses` in a row, `changes`, how
often the stem ran (`delivered`), previewed (`prepared`) or withheld it, and
`costs`, the stem's own run times in seconds. Standing arithmetic belongs to
[`Expectation`](../Modules/NativeAgentCore/Sources/NativeAgentCore/Expectation.swift);
Expansion's practice owner measures its costs;
nothing in the file is a setting. Only a missing file starts empty; unreadable, invalid or unsupported records remain byte-preserved and unavailable.
Expansion diagnostics expose the cause; activity cannot replace the record.
The one coalescing writer acknowledges a save only after the durable byte owner
returns successfully (`expansion.record.saved`, with the exact path, version and
whether newer changes remain pending). Diagnostics label pending practice.
A failed save reaches that same owner, retains the unsaved practice and dirty
state as unavailable, stops further learning, prediction and automatic writes
for that root, and owes repair for the exact file under `expansion.record.save`.
Diagnostics and `expansion.record.failed` name the cause. A publication can
precede a durability failure; neither the old bytes nor a committed save is
asserted. Inspect and repair that exact storage failure, then restart to read
the repaired record; only a successful durable save settles the save debt.
Turn closure joins this writer's result; repair reporting uses the existing
per-operation experience queue. Pending deliveries still release and the turn
closes without undoing completed tools.
Trace rows: `expansion.check` per settled try, `mind.why` lane `expansion`
per delivery. The caller's admitted model is diagnostic, never a practice or
thread partition. On load, v3 folds v2 practices by mind and authority, unions
field-free situations with the newest 8 examples each within existing caps,
and sums counters only for identical record signatures. The newest record's
trailing miss streak and bounded run costs are retained. Historical
field-qualified claims keep their exact signatures and counts; the broader
field-free claims earn fresh standing.

Before a fresh message's first `model.call`, `start woke:<what woke the turn>`
predicts its actual first read under the same inference, cost standing and
withholding. With no preceding result to supply values, only structural
constants can fill that opening form. Its gated read reaches the model as
`already_looked: [{call, result}]` under the same wall-clock deadline and inline
ceiling below, with no act preparation or follow-up chain. The actual first
call labels this claim by exact call/argument match even when delivered;
another call or turn closure without a call misses. Retries keep the one
opening read; resumed turns do not rerun it. Its trace is the same
`expansion.check` with situation, outcome and standing.

Resident/ephemeral and helper turns settle remaining predictions
on their own exit, including failure and Stop, and wait for the same record
writer. An unshown final prediction misses; an unused delivered read remains
unknown. A live thread trimmed for room records its pending outcomes as
unknown, never an invented miss or a silently lost try.
A reply with deferred private work transfers settlement to that flight; it closes
after the work, or after abandonment when the answer could not be saved.
Every in-flight delivery has its own invocation identity. Concurrent arrivals
retain that attempt and its first next-call observation until delivery and
outcome accounting settle; turn closure joins these deliveries before the
record writer. Closing or trimming a thread cannot erase an in-flight attempt.
Its terminal `expansion.check` row retains that identity as `invocation`.

**Delivery.** A read runs through the same chain only by the judgment the Trust
gate makes of the call as it runs (`PermissionLaw.toolClass` of its ran call)
and by its enforced declaration: read-only capabilities and a declared class
that reads (for their parts, their reach over every permission and dependency,
so a part's own readOnly flag beside a write permission is no read; never who
wrote them); a preview; or a page, page item, find or home, by where the door
itself resolves the call (`AppDoorNames.place`, the same steps `runAppDoor`
takes). It waits for the selected operation's result or cancellation, without
a measured-duration admission gate or wall-clock cutoff, and rides inside the
result under `already_looked` (`{call, result}`); the read it brings may carry
the next one, three deep. An act is only previewed and rides under
`ready_to_confirm` (`{call, preview}`); it never runs. A batch, a script, or any
page or path the door resolves to one of home's items (which does what its
name says) is neither. Nothing rides on a result parked on a person, on a
stopped turn, or past the provider's inline ceiling (`ProviderToolResultPage`).
Every delivery passes the whole gate chain as the mind's own call would and
grants nothing that call would not have.

### Secret insertion and redaction

Reach capability names are `app_data_read`, `app_data_write`,
`network_localhost`, `network_public`, `network`, `shell`, `computer_files`,
`arbitrary_file_write`, `app_read:<bundle_id>` and `app_write:<bundle_id>`.
`AbilityStore.reachActions` defines the exact app actions included by a
capability; page membership never expands reach. `computer_files` and
`app_data_read` include only `files.read/list/info/excerpt/grep/spotlight`,
and write reach adds `files.write/move/copy/trash/patch`. Photos actions are
not file reach. The save receipt prints the resulting `actions` (including
code calls and explicit dynamic dependencies).
`model`, `calendar`, `reminders` and `contacts` are reach for the host
primitives (`host.model.call`, the PIM door aliases), and `network_public` is
`host.fetch`'s (`network_localhost` for a loopback host; `connector:<id>` still reads, granting nothing; a fetch naming
a connector refuses. A fetch waits for its transport result/error or explicit
cancellation. NativeAgent adds no response or transport timeout and never resends
a request after credential rejection. Its admitted transport retains settlement,
including synchronous DNS. For a modifying request (any method but GET/HEAD),
settlement saves the complete redacted receipt once at
`ability_fetches/<uuid>.json` and links it from that experience, then accepts
its `finish` obligation. A received HTTP response does not prove the service
applied a write: effects remain unknown in that receipt. Read the receipt and
inspect service state before another modifying request. Missing/unreadable
settlement is unavailable evidence, never permission to resend; persistence
failure owes repair. A pending experience after app termination requires service
reconciliation, never automatic request replay);
`shell` serves `host.program` (a named program over stdio for the run, ended
with the run as a shell command is unless a resident ability holds it; a program that deliberately detaches into
its own session outlives the run, as from the shell), and
`secret:<name>` lets a call write `{{secret:<name>}}` where a keyring secret's
value belongs (a fetch's url, headers or body, `network.send` text, a program's
args, env or stdin): the broker inserts it only toward a host or program the
person granted and redacts replies (stream-piece boundaries may expose up to three leading secret bytes before redacting the remainder), in each form
an insertion writes it (as written, URL-encoded, escaped in a JSON string,
base64; in a reply's header name, in any case). The honest limit: a program or service granted a value can echo it in
another encoding (a JSON escape of an unusual character, its own transform), and
that echo is not caught, so the grant (which programs, which hosts) is the fence.
A signed-in secret is renewed shortly before it expires. A fetch's credential
rejection surfaces without resending the request. A permitted omitted
token expiry is stored as unknown and renewed before the next use when a refresh
grant exists; a supplied invalid lifetime refuses the grant or renewal. Device
authorization requires its server's code lifetime, polls at its valid interval
(RFC 8628's five seconds only when the interval is omitted), and ends at expiry,
denial or cancellation. A fetch carrying a
secret that only reads (GET or HEAD, no body) is a read in Trust, any other call
carrying one an effect;
`AbilityStore` names the full accepted set, including the run's screen watch
and Mac hands.
Unknown capability names, wake names, header keys and reach/face keys refuse by
name. Lifecycle fields (`record`, `candidate`, `proof`) remain store-owned.
Sense source membership comes from the checked sealed manifest and entry, never
a separate header inventory. Reads require a current `reach` object and accept
the same wake names as saves; old header authority is not projected.
Retained sealed legacy candidate descriptors are unchanged,
including their internal permission spelling, so loading does not invalidate
their exact-code admission or proof.

```json
{
  "id": "mail_summary", "kind": "ability", "version": 1,
  "reach": {"capabilities": ["app_read:com.apple.mail"], "readPaths": [], "hosts": [], "apps": []},
  "wake": [], "face": {"page": "mail"}, "resident": true,
  "learned": {}, "choices": {"open_doc": ["script", "menu", "screen"]}
}
```

```json
{"id":"mail_reader","kind":"sense","version":1,"reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":["com.apple.mail"]},"wake":["file.changed:/tmp/example"],"face":{"page":"mail"},"resident":true,"learned":{},"choices":{}}
```

```json
{"id":"turn","kind":"turn","version":1,"reach":{"capabilities":["model","calendar","reminders","contacts"],"readPaths":[],"hosts":[],"apps":[]},"wake":["message.arrived:telegram","turn.ended","app.installed","schedule:0 9 * * *"],"face":{"page":"chat"},"resident":false,"learned":{},"choices":{}}
```

These examples show the common header. Existing store-owned `record`,
`candidate` and `proof` fields carry their unchanged lifecycle
payloads alongside it; a header alone is not admission to execute.

`ability.save` and `sense.make` accept `reach`, `wake`, `face`, `resident`,
`learned` and `choices` alongside their authoring fields. Ability saves use
`reach`; sense creation still accepts its current `apps` field. The census and the
`learned` and `choices` alongside their authoring fields. `ability.save` uses
`reach.capabilities`; its old `permissions` argument is removed. The current
sense authoring `apps` field remains declared at that door. The census and the
ability reads expose each ability's reach, wake, face and residency; sense rows
expose their own `SenseRecord` version, reach and lifetime `mode`, without ability wake
or residency fields.

`learned.use` projects version totals and bounded recent input/call outcomes;
its `scope:"current_version"` names the scope of `run_totals` and
`rounds_per_use`. List and detail share one store projection,
`run_counts:{all_versions,current_version}`: `all_versions` reads lifetime
`useCount`, including versions no longer retained, and `current_version`
reads the selected file identity's `runs.versions` count. A version with no
record has zero observed runs; unavailable accounting fails the read rather
than inventing zero. The list's ambiguous `runs` field is removed.
Successful runner receipts with explicitly empty `calls`, `effects:none` and
`notebook_changed:false` write no run accounting: a computation that called
nothing and changed nothing must not wake readers through `abilities/state.json`.
The notebook owner compares before writing and emits no change for an identical
value; its committed-write callback supplies `notebook_changed`, including state
writes outside the call ledger. Missing evidence never proves a no-op; failures,
unknown effects, actual calls and changed notebooks retain their accounting.
Run accounting retains the terminal refusal's `reason`, `reasons`, `gate_reason`,
`detail`, `message`, `checker` and `remedy` in `lastRun`, beside status, effects,
version, calls and terminal error/stop evidence. `at` is the start of that run or
refused attempt, not its accounting-write time; an older settlement cannot replace
a newer `lastRun`. A successful explicit no-op leaves the retained run untouched.
A failed notebook operation makes `notebook_changed` null even if its code
catches the error: a durable write may have renamed the file before failing.
Run call labels and input previews are redacted before accounting is saved;
retained accounting text is redacted again when projected, including previews
saved under an older content policy. Retained accounting bytes are not migrated.
Lifecycle publication preserves canonical run and trial accounting directly from the store, never from redacted registry rows.
Version evidence requires its recorded `count`; outcomes must sum to it. A new
version starts with zero observed runs. Each version's evidence also keeps
`rounds` (tool rounds of each turn that ran it → uses; `rounds_per_use` is the
current version's), `surprise` (kinds the stem attributes after a run:
`corrected`, `slog`), `hours` (UTC hour → runs by the same outcome classes as
its totals, pruned at 28 days) and `first_seen` (the earliest time the record
saw it run). Failed is a version's `error + cut`, read, never stored.
`learned.versions` shows the current and previous versions with uses, ok,
surprise and rounds.
Each execution's terminal accounting supplies its exact part id and full version key to the turn's round owner, including answered verbs and
nested scripts/batches. A tool round counts once per executed version; two versions in one turn retain separate counts. Settlement never reads
the store-wide last-run pointer. A version no longer in either retained executable slot, or with no run evidence, gets no invented rounds.
`AbilityStore.tallyCounters` owns counter validation for store admission and the trial reader. Outcomes sum to the version's count; retained
UTC hours total at most that count and each retained outcome totals at most its version outcome. Hour keys and outcome names must be valid.
Histogram keys must be canonical nonnegative integers and frequencies total at most that version's uses; surprise kinds and aggregate counters
are checked without overflow. The non-throwing trial tally retains an `accountingGap`; the night reports it before using counts, and an invalid
tally cannot decide a trial. Saved bytes stay preserved. Mean rounds uses floating-point products.

A revision may be a **trial** (`ability.save {…, trial:true, why}`): a revision
of a kept ability, judged by the stem against the version it replaces (the kept
self) from their records, by `PartTrial` over `Expectation`. Kept when its
target surprise is confidently rarer; set aside when total surprise or cost is
confidently worse, the trial's lower bound above the kept self's upper bound;
otherwise open, with no date. One open trial per ability. The trial is the
stem's record (`trial`, then `trials` once closed, in `abilities/state.json`),
never a header. A trial lives while its version is current or waiting: when
neither slot holds it, it closes as superseded, or as set aside when its
setting aside is current. `ability.save {id, set_aside:true, why?}` saves the
kept self forward as a new version, with that version as the base every field
inherits from, under the same Trust as any save. `why` is shown, never scored.
The night (`EngineSleep.night`, after the dream) closes kept verdicts and
superseded trials as the stem; setting aside stays the agent's forward revision
or the person's lever. It folds the window's `corrected` and `slog` surprise
into the version that ran (the current or previous version whose `first_seen`
is not after the turn), from the last night's row onward. The accounting owner durably prepares exact window/version/count inputs in
`abilities/.night-fold.json` before folding; each version's counts and `surprise_through` watermark commit together, making a replay inert.
Run accounting retains versions owed by that prepared window. Only after every fold settles does the durable night row advance `through`,
then the prepared file is removed. A failed fold or catalog read holds the cursor; siblings still settle. Unreadable traces or corrections
hold an unprepared window for another night. Prepared inputs survive trace retention; an unavailable version record is a named gap, never zero.
Each caught night operation retains its source and original reason in the reading
and the durable row's `gap_details`. Cursor, storage and prepared-window cleanup
failures owe repair at the failed operation. Missing `first_seen` without a frozen
baseline leaves the trial unread; it supplies no guessed date. A current turn
program has no elapsed-age veto: admission depends on recorded evidence.
Unmeasured rounds remain null and cannot supply a numeric candidate cost rank.
A run never reconstructs a count from
outcomes or a previous-version success from last-run fields. Missing counts
leave the stored bytes preserved and unavailable. `states()` reads without
writing and reuses only the exact checked accounting file identity.
Night readers check counter sums and retained-hour totals (also per outcome)
against the version total; overflow or inconsistent evidence produces a named
`part_accounting` gap and no verdict for that part. Model-round means multiply
in floating point, with checked histogram counts. Hour coverage is
`[floorUTC(since), floorUTC(through))`, exposed separately as `parts_since` and
`parts_through`: the partial hour remains for the next night, including uses
after the night. Trace/correction coverage keeps its exact times.

What they works out by hand repeatedly, they keeps, inside the turn. After
each tool round the native stem meets the hand work's ordered tool/action ids
(landed writes or irreversible non-ability calls, with incidental reads and
arguments left out), or the one call repeated with the same input 3+ rounds
when there is no such hand work, as one `practice: ` line through
`FamiliarLines` in `mind/familiar.bin`. The first meeting only records it.
A later meeting, unless an active ability's current learned-use or validation
route covers those ids in order, sends `practice` on that round's last result,
once a turn; the shipped turn makes it their next call's note: keep the route as
an ability, revise the part they worked around or looped, or keep nothing.
This uses the same bounded habituation as lines
([Habits H3](HABITS.md#h3--keep-what-repeats-not-what-happened-once)).
New parts cannot take shipped seed ids in `Resources/abilities/*.js` or ids
starting `native-` (`AbilityStore.seedCatalog`). `ability.save` can revise an
installed shipped ability through normal admission; `turn` records remain a separate kind.
Future shipped parts use `native-`. Installation never replaces a part they
authored first, including an id occupied only by a retained or proposed version.
The retired `habit` seed is no longer shipped. A seed the app stops shipping
fades at launch: an installed copy whose bytes are still the candidate its seed
proof names, never turned back on, is switched off through its registry,
restorable and never deleted; a launch whose bundle has an unreadable seed
fades nothing.

Their own abilities are in front of their each turn: the turn glance lists callable
abilities one line each (their own action, `authored.<id>` unless a face names
it), by find's ranking against the message. Unranked rows
put failures first, then the most recently used, then the existing action order.
An empty message has no ranking; it shows failed and recent abilities first.
Each description ends at a word boundary within 100 characters, including a
truncation ellipsis. Explicit zero/one use counts appear only as "never used" or
"used once"; a missing use counter adds no count label.
A recorded non-ok last run, classified by `AbilityStore.runOutcome`, is marked
"failed last run <h:mm a>: <reason>" (at most eight words of reason) only while
its `lastRunVersion` matches the current file's accounting identity. Missing run
evidence adds no failure; a known failure without a timestamp says "time unknown".
The census computes `call_fit` on demand; it is not a stored stale verdict, and
`ability.list` supplies no such verdict, so the glance invents no stale status.
Abilities whose header has `resident:true` or a nonempty `wake` leave the rows
and become "+N run on their own (find)"; find still offers their full actions.
The 900-character row budget includes that count, and `ability.read <id>` hints
appear only when all rows fit with them. Rendering writes nothing.
Find requires checked semantic ranking. An unavailable embedder, unusable vectors
or mismatched index epoch returns `action_ranking_unavailable` and the owner repair;
it produces no word-only substitute. Exact current action addressing remains a
separate lookup. Lookup, page actions, policy projection and ranking consume the
same checked action inventory; a failed peer, sense or authored-store read is
unavailable, never a successful empty catalog. A selected action's schema parse/property
failure is named in find's `schema_gaps`; healthy action results continue and
`shown_actions` counts their usable rows. Admission still refuses that broken
action, without manufacturing arguments from display text. A gap proves no absence.

Ability file contents and parsed run accounting are reused only while their
`lstat` identity (device, inode, size, mode, mtime and ctime with nanoseconds)
matches; every read checks it. A walk uses one `lstat` per member for its type
and decode identity, and compares header/file names without another disk read.
Successful canonical file and accounting writes warm their memo with the written
content and post-write identity. Each abilities root keeps its own latest
validated state rows; missing state remains empty, and failed reads/validation
are never memoized. Redaction keys on that state identity rather than serialized
accounting bytes. Immutable bundled sense defaults are read once per resource
root; pure tool-name prose folding, ranking's word sets and action-index text
hashes are reused per exact input text under a lock with a 4096-entry bound. No watcher, notification, timer, background refresh or
wait decides freshness. `FileSenseRegistry.withStore` keeps its existing logic.

A skill is built-in guidance from the persona (`skills/bodies/<id>.md`): it is
found and read through `ability.read` and never runs. An ability with the same
id owns that read; the built-in original is then omitted from guidance
discovery and `ability.list`, even while the ability is off or waiting.
An unreadable body remains a named `unavailable` guidance row, with its path
and cause in `description`; readable siblings continue. `ability.read` refuses
that row as `skill_body_unavailable` rather than returning empty guidance.
`ability.list` carries these rows' ids and names their failures in
`guidance_gaps`; Skills, capability discovery and Mac/phone inventories retain
the same row description. A failed directory or ability inventory read still
fails the shared inventory; only a proven missing guidance directory is empty.

## The one form

Every ability verb accepts its `id` as the bare id (`quit-app-verify`) or its
registry action (`authored.quit-app-verify`), through one reference resolver;
receipts name the resolved bare id. This includes new ids and revisions on
`ability.save`. Existing display names still resolve after ids. Unknown-id
refusals list the nearest three available ids (or all when fewer exist);
suggestions never select a target. `ability.resume` still requires the exact
`run_id`; its optional `id` binds that checkpoint to the named ability before
claiming it, in either spelling.

| Action | Contract |
|---|---|
| `ability.save` | `{id, description?, code?, edits?, params?, actions?, fixtures?, name?, triggers?, converts?, create_only?, reach?, wake?, face?, resident?, learned?, choices?, trial?, set_aside?, why?}`. `trial:true` with why makes a revision a trial; `set_aside:true` saves the kept self forward (trials: see `learned.use`). Creates or revises: a new ability needs description and code; a revision inherits everything it does not restate from its latest version; an explicit empty value drops one. Send code or edits, never both. `params` is the description/type map (a leading type word, optionally after `optional`, sets the type; otherwise string; words end at whitespace, commas, colons or parentheses; `?` on the type or the word `optional` marks it optional), `{type, description?}`, or a JSON Schema object (`readOnly:true` declares a read contract); `params` is its sole input-contract argument. Direct app dot/bracket members and reach derive dependencies; `actions` declares indirect calls (literal or computed). Literal calls and declarations are checked before staging; unknown actions and missing dependencies refuse save, while computed names produce warnings and keep runtime checks. Under Full Mac their own save is kept and on in this one act (sealed as kept: its first real run is its proof), with a decided Inbox row; below Full Mac, or when an untrusted agent started the turn, it is a draft. A revision inheriting older `compiled` provenance remains staged until its exact version replays ([compiled from practice](#compiled-from-practice)); no new nightly compiled candidates are produced. A revision may name an existing ability by id or name. New ids are normalized by trimming whitespace, lowercasing, replacing runs outside `a-z`, digits, `-` and `_` with `-`, and trimming edge hyphens; the result must be 2–64 characters, a letter first (`^[a-z][a-z0-9_-]{1,63}$`). |
| `ability.validate` | A read: `effect:none`, `read_only:true`; a reached rehearsal reports `execution:rehearsed` and `effects:none`. Rehearses its waiting version with the shared helper and intercepted replies, on fixtures or one captured run with `input`. A version compiled from practice replays its tape instead (`candidateValidation` `replayed`). Proves no live behavior; never keeps. |
| `ability.enable`, `ability.restore` | Keeps its waiting version, or turns it back on: theirs under Full Mac for their own work (sealed as kept when never rehearsed); otherwise, once rehearsed, the owner's card for this exact version (code, fixtures and dependency shapes), approvable on the Mac and the phone, or Keep on the Tools page. Code requires `version` equal to its full digest, captured with the displayed code when the card or row was staged and saved with it; self-improvement cards and approval replay carry that same saved digest. A caller without the exact review offers a read rather than executable approval. A version compiled from practice is kept by no one until its tape replayed (`not_replayed`). Omitting `version` restores only disabled Markdown guidance with no candidate or code fingerprint, checked and written under the ability-store lock. |
| `authored.<id>` | Its one run, with input by its params, under one signed admission re-verified on every run. `preview:true` runs its code with every write previewed and says where it would card or hand back. |
| `ability.resume` | A stopped run_id and bounded answer; optional `id` binds it to that ability, with a mismatch claiming nothing. A rename claims the checkpoint; its bytes are read and verified once. Read/admission failures preserve the claimed evidence; pre-run refusals and busy admission release the original bytes. Completed or deliberately closed runs consume the checkpoint at settlement; cleanup failures stay in `settlement_failures` with cause and remedy. Rechecks selection, host revision and admission and replays prior reads. A woken run resumes with the `input.wake` it stopped on. `preview:true` only reads the checkpoint: it reports the question, input, wake and stopped call, without claiming the run, transferring holds or closing its queued step. |
| `ability.read` | Every stored kind, including turn and sense: kind, version, declarations, status, retained versions, `run_counts` (all_versions, current_version), evidence and code in pages (`offset`), or one `step`; ordinary abilities also expose waiting/last-clean and converted versions. |
| `ability.disable`, `ability.drop` | Off with every version kept, as whoever did it (`disabledBy`): `theirs` for their turn or their ability (a trusted agent's turn included), `owner` only for their own surface (the Tools page), `peer` for an untrusted agent's; theirs they turns back on, the owner's is their to lift (`ability.enable` asks on their card); delete it, its versions, its run state and its `host.state` notebook (`pending:true` discards only the waiting version). A built-in skill's own version is the owner's to switch off or drop below Full Mac. |
| `ability.list` | Every stored part, including turn and sense, in a bounded page (at most 40 rows and a 24 KB row budget), ordered by id. Rows carry kind, version, `run_counts` (all_versions from stored useCount, current_version from the selected version's count) and `last_run_at` from stored `lastUsedAt` (ISO timestamp, null when never run). `count` is the rows printed, `total` is the inventory; follow `next_call`/`next_offset` with `offset` when `has_more`. The Tools page reads this same projection and accepts `args.offset`; a named Tools item accepts a source offset, also reachable by `ability.read`. Full declarations and versions remain on `ability.read`. Unshadowed built-in guidance remains discoverable; unreadable bodies are named in `guidance_gaps` and refuse only their own read. A missing guidance directory is empty; an unreadable one fails with its read error. |

An ability save whose normalized authored source, declarations, fixtures and provenance already match its latest version returns
`status:ok, effects:none`. It stages, signs and publishes nothing, leaves any open trial and kept baseline intact, and does not enable a draft or
disabled part. Use the lifecycle action to keep or restore that existing version.

`ability.save` discovery and argument refusals expose `Parts.saveArgumentsSchema`,
owned beside the save validators. Only `id` is unconditionally required; new
abilities also need description and code, and revisions inherit omitted fields.
Only a checked retained candidate with no proof field can receive a new Full
Mac keep seal. A present proof (including null) must authenticate against the
original signing key, exact candidate, fixtures, host revision and dependency
shapes; unreadable or stale evidence refuses keep and remains intact. Missing
signing authority for an existing proof is an error. The same check runs under
the store lock before a keep seal is written, including an identical save; a
valid existing proof is preserved. Explicit validation can produce new evidence.
Description is nonempty after trimming. Save keeps its first line within 500
characters, cutting at the last sentence end within that limit or making a hard
cut with `…` when none fits. A shortened description is reported in
`description_note` and the receipt's detail as “description kept to its first N
characters”; extra length or line breaks never refuse the save.
Code defines `function run(input)` or `async function run(input)` and returns
JSON. App and host calls answer synchronously and may be awaited. The helper
reads a returned thenable after JavaScriptCore drains microtasks when its API
call returns: fulfillment supplies the result, rejection is the thrown error.
A Promise still pending after that drain fails with “Its Promise never settled:
only app and host calls, which answer at once, can be awaited here.”
`app` is a frozen callable door with its existing properties:
use `app.<page>.<action>(args)` or `app({action:"page.action",args})`; declared
indirect actions use `host.call(actionID,args)` or `app.call(actionID,args)`. Literal bracket members
(`app["page.action"](args)`, `app["page"]["action"](args)`) have the same direct
dependency derivation as dotted app members. Literal actions in callable requests
derive dependencies the same way. `app({actions:[{action,args},…]})` runs in order
and returns an array of answers, stopping at the first throw. `app({find:"words"})`
is `app.find("words")`; `app({action:"find",args:{what:"words"}})` (or `query`)
reaches that same discovery reader as a registered read action. Item/page
requests go through `app.read(page,item)`.
Every action form uses the same invocation, allowlist, declaration and error gates.
Caught `AppError`s expose `try_instead` from one top-level invocation field for
both pre-dispatch and runtime refusals (`null` when no advice applies), retaining
the original `receipt` when a call reached an owner.
Calling a namespace alone, such as `app.desk(args)`, refuses with the working
`app.desk.<verb>(args)` and `app({action,args})` shapes. Malformed callable
requests and batch entries name those working forms as well. Saving checks
their static call shapes; it never executes code to discover a runtime fault.

Before any candidate is staged, `OwnedProgram.calls` reads literal calls using
the shared source lexer: app members, callable action/batch requests and
`app.call`, action names in `app.read`, host members and `host.call` (including
file/PIM aliases), and `part.call`.
`Parts` checks the live door's action catalog and existing authored abilities.
An unknown action refuses save, naming it and `try_instead` with the nearest
current action shapes from the door's declaration-based correction mechanism.
Supplied arguments use the shared door binder before inspection separates known
values from unknown expressions. A schema declaring exactly one of `id`, `item`
and `handle` reads exactly one supplied alternative as its declared field when
that field is absent, including unknown expressions. A supplied declared field,
two supplied alternatives, or a schema declaring none or several leaves this
address binding untouched. A unique action-declared meaning or the single
missing required argument whose schema can accept the expression binds at
inspection and execution alike; unknown values still face runtime admission.
A collision or unresolved name still refuses, carrying
one proposed `next_call` beside the original values and argument shape; advice
requiring a change points to discovery if the proposed arguments repeat the
failed call. Static inspection runs nothing; execution records each
interpretation in the receipt.
Declared exact references also bind their namespace and contextual qualifiers:
`context.expand` maps `message_id` or `history` to `atom_id:"history:<id>"`,
consuming an accompanying `agent` as context without narrowing that identity.
The same binder serves execution, evidence and saved-call inspection.
Contacts calls pass that binder too, retaining raw values and unknown expressions
under the same no-coercion policy as their runtime owner.
Replay journals retain the same bound, redacted action arguments as other
receipts; secret characters are represented by their count and digest.
A literal indirect action absent from effective
`actions` refuses save with `undeclared_dependency` and the missing declaration;
explicit `actions`, literal callable requests, direct app members and capability-derived reach form that
effective set. A known host primitive is identified by the execution broker's
operation inventory, rather than mistaken for a missing app action; its reach
and arguments remain broker-gated. A saved off/draft `authored.<id>` dependency
pins its exact retained version and still needs admission when called. A part's
own `authored.<id>` pins its identity inside the signed candidate, so a new
self-reference does not require an already-published catalog entry.

Impossible prelude shapes (`app.files(…)`, `host.files(…)`, or an
unexposed host method) refuse save naming the supported form. Strings, comments
and regex bodies do not produce calls; code within template expressions does.
Callable requests, args and batches share one shape reader, including object
literals, shorthand properties and lexical variables. Unchanged lexical
initializers can be read; parameters, reassigned values, object/array aliases or
escapes, spreads and computed forms that cannot be read stay `unknown shape`,
never an invented empty object. Save-time and run-admission checks both consume
`OwnedProgram.calls`; point-of-call admission still checks the actual value.
Computed action names (concatenation and interpolated templates included) remain
runtime checks; completed save receipts carry `warnings` naming their lines,
rather than refusing them. In particular `"authored." + id` is never validated
as an action called `authored.`. `ability.validate` applies the same check
before starting rehearsal. Inspection executes no code and does not prove
arbitrary JavaScript behavior or external availability.
Local bindings and parameters are respected, so their own `part` helper or
`screen` value is not mistaken for the prelude's object.
The schema describes `params` as a description/type map, per-param `{type,description?}`
or `{type:"object",properties,required?,additionalProperties?:false,readOnly?:bool}`;
`integer`, `boolean` and `array` alias `int`, `bool` and `list`, and a trailing
`?` on the type marks optional inputs. Each string is retained as its description.
A complete leading type word, optionally after `optional`, supplies the type;
words end at whitespace, commas, colons or parentheses. The word `optional`
anywhere also marks an optional input, including an untyped string description.
A description without a leading type names a string parameter. Plain types pass
through this same reader; object declarations keep their explicit type. The
[parameter contract](TOOL_LOADING.md#one-tool-every-action) gives examples.
Param names match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`;
each declaration takes `type`, an optional nonempty text `description`, and
parameter schema constraints such as `items` or `enum`. Those constraints survive
the `properties` → named-parameter reading, canonical type spelling and saved
input schema; the shared JSON Schema validator checks malformed rules before
save and applies them on calls. The JSON Schema envelope uses its `required`
names to distinguish required and optional parameters.
An omitted params inherits; `null` or `{}` clears it. Its structured declaration
replaces `params:any`; fixture shape is also owned here rather than restated in
discovery. The door preserves the original `params`, `reach` and `face` through
argument normalization: explicit param clearing reaches save, and invalid
header nulls are refused rather than dropped into defaults or inheritance.

Completed `ability.save` receipts include `timing: {validate_ms, proof_ms,
write_ms}` in milliseconds, measured with the monotonic clock. Validation
covers candidate preparation and dependency shapes, resolved once per action;
proof time covers the Full Mac keep seal and its signing key; write time covers
staging, admission and the remaining publication work. A draft runs no proof
and reports zero proof time. A Full Mac save seals a keep, without starting a
JavaScript helper or running fixtures; rehearsal remains `ability.validate`.
Repeated catalog reads reuse redacted accounting only for byte-identical
accounting, without rewriting source files or changing the content policy.

Catalog argument rendering accepts native object schemas without `properties`,
including a `required` list with unconstrained values (shown as `any`). Discovery
preserves authored native contracts and schemas with no projected door fields.
Malformed JSON or malformed present `properties`/`required` fails through the
schema owner; it never becomes an empty successful contract. Primitive argument recognition,
effect classification and redaction share `AuthoredToolEffects`' current
vocabulary, including fetch's keyless/secret admission identities. Unknown
calls still withhold arguments and cannot be admitted with withheld input.

`ability.validate` reuses an existing authenticated rehearsal only for its exact
candidate, fixtures, dependency shapes and host revision. A keep or bundled
seed seal is not rehearsal. An existing capture must match a requested input;
an explicit new capture without an existing capture still runs. When rehearsal
is needed, its fixtures and decision replays share one helper, started lazily
at the first run and released at settlement; every run has a fresh journal,
scratch notebook and JavaScript context. No save or proof completion waits on a
timer.

Current calls use `ability.*` and `authored.<id>`. Retired `skill.*`,
`tool.*` and old public tool spellings are unknown calls; they do not execute
or translate to another action. Saved authored callers must use the current
IDs and exact argument names. Historical transcript labels remain readable.
Only current `ability.<verb>` and `authored.<id>` actions execute. The older
`skill.*` and `tool.*` doors, old authored-name adapters and old skill-read response
shape are removed from direct calls, scripts and dependency classification.
Saved abilities using those calls must be revised by the agent; loading saved source
does not revive the old door. Retired action names use ordinary unknown-action
handling. Historical transcript labels remain recorded text.

Desk writes serialize under the store's lock and retain their changed-state
refusals. Conversations, turns, operations and ability inputs acquire no holds.
Only a stopped part-run with a retained checkpoint reserves its journaled Desk
items until resumed or released. Mutation and resume callers only check those
reservations. Run refusals name the holder, since and end event, with a next call
previewing that run's resume; session evidence is optional. The single locked
editor drops non-run markers and reservations without an open item or checkpoint.
Resume releases its run's markers while retaining the claimed checkpoint through
execution. A refused or busy resume restores reservations without displacing
another stopped run. No reservation uses a clock. A stopped run's
reservation or metadata failure retains the run result and identifies the failed
settlement with a repair debt. Upgrade evidence remains on the result until its
queue append succeeds. Resume reservation release, queue closure and restoration
report their owner failures; none claims an empty reservation set after a
failed read or write. A resumed result retains completed effects when queue
settlement still needs repair.

The admitted entry assembles the native morning brief's checked packet for
`operation:"brief"` on direct calls and scheduler calls alike. The scheduler
owns consent, occurrence claims and publication, without a second packet builder.
All ability JavaScript exceptions retain their located ability/version message
in the presented `detail`, their original cause and engine line/source when
available, and a read/repair call. Missing location evidence is explicit;
it never selects a substitute source line.

```javascript
function run(input) {
  app.step("Read");
  const result = app.read("tools", input.name);
  const answer = app.decide("Continue?", {result});
  return {result, answer};
}
```

`app.read`, `find`, `log`, `expect`, `expect_fail`, `decide` and `step` are built in. At most 50 dependencies. Define `function run(input)` or `async function run(input)`, use host/app calls and return JSON.
A part that is not done returns `{again: <input>, ...what it has so far}`: the stem runs it again on that input through the same admission and gates (each run its own run on its record), until it answers without `again`, a run fails or is refused, Stop, a message arrives in the calling conversation, its runs' ledger reaches 4 MiB, or a run repeats the one before in input and answer; it goes on only inside a conversation turn in flight that the person can Stop. Its one call answers with the last answer and `runs`, its `effects`, `calls` and `changed` covering every run (a later run that cannot start, its input or admission refused, answers as that run's refusal beside what the runs before it did, which is never replayed); handed back early, `again` stays and `handed_back` says why. The combined effect summary preserves `unknown` before `partial` before `occurred`, so a later uncertain run cannot be hidden by an earlier confirmed effect. A call-ledger encoding failure ends carrying with `call_ledger_encoding_failed`, unknown effects and a reconciliation instruction; its completed run has already settled, and no next run starts. It never counts an unreadable ledger as zero bytes. Previews, rehearsal and resume never go on.
An intentional decline returns `status:"refused"`, a stable `reason`, plain `detail`, receipt-backed `effects` and `remedy`: the fix with an executable `next_call` or person-owned `tap`. A terminal remedy explains why no further call applies. A lawful refusal is an answer; a source fault owes repair (`AbilityStore.runOutcome`).
When completed code returns that explicit refusal, the runner promotes its cause,
checker and remedy to the run receipt before accounting. It counts as refused even
if it made no calls or notebook changes; `lastRun` and Home retain that refusal.
The returned value stays intact, and effects and calls remain the runner's evidence.
Native value calls, authored actions and resumes pass the originating gated door.
Authored admission carries the run body through that same chain, including its
consent audit; it has no separate Security Center evaluation path. A selected
version is rechecked after admission before its body starts. Refusals before
runner entry, wake admission and offered-call admission use the ordinary dispatch
completion writer too. Each retained version's run settles once; outer receipts
carry the runner's `ability_run:{id,version,at}` provenance instead of counting it
again. This metadata leaves a verb's returned business fields intact and is excluded
from repeat-answer identity.
Missing or unreadable identity is not permission to account a different version:
the dispatch receipt retains the refusal and any `accounting_error`. Native calls
that cannot read the catalog or select a fingerprint use this same completion
writer, retaining the original cause, `part_selection` checker and owner's remedy.
Their failed selection stays unattributed even if a later catalog read succeeds. Checkpoint
identity is read and verified before a resume can consume its checkpoint. Previews
and face projections create no run accounting. Home reads the five newest retained
refused runs from this same accounting owner, with their causes and run times.
A program's `execution` describes that program (`executed` on a completed run,
`attempted` on a failed/stopped run, `preview` for preview); a nested call's
`not_run` belongs to that call. Aggregate effects include earlier writes even
when a later read fails. Image `files.read` inside a text-only ability/script
succeeds with verified dimensions, byte size and encoded type and
`image_pixels:false`, telling their to read the pixels from a turn.
Save, enable and run accept async code under the settlement rule above; ad hoc scripts retain their function-body contract on the same executor and may return a thenable under that rule.

An ability is stale only when one of its statically readable calls no longer
fits the live argument schema: a supplied field is not accepted, its known value
has an incompatible type or constraint, or a required field is absent. Save,
execution (including resumed/value/face calls), keeping, bundled seed admission and
rehearsal share this call-fit check. `stale_dependency` names the action, source
line and field, with the exact re-save remedy. The door's existing argument
names, scalar normalization, read corrections and supported scalar-list
expansion also apply to preflight: each expanded call must fit. Both
`part.call(id, input)` and `host.call("part.call", {id, input})` check readable
child input against that child's schema. Host-file roots are consumed by the
prelude before checking door arguments.
Changes to unused fields, result contracts, revisions or old digest-only pins
do not by themselves make code stale. Computed names, argument objects, spreads
and values that cannot be established statically keep their ordinary
point-of-call declaration, argument, Trust and domain checks. Missing contracts
are unavailable evidence, never proof of removal or compatibility; the actual
call resolves them at the door. No new wait or execution is added to preflight.

The sealed candidate retains its original dependency snapshot as historical
admission evidence: changing it would change the exact reviewed version. A live
execution attempt stores its observed live snapshot in that version's
existing `abilities/state.json` accounting at
`runs.versions["<digest>@<file-version>"].dependencySnapshot`, in the same atomic
write as the terminal receipt. Changed contracts are named in `refreshed`
(also retained in `lastRun`); the note explicitly leaves computed arguments to
the door. A null snapshot entry means its contract was unavailable, not removed
or changed; it never earns a refresh note by absence alone.
A failed accounting write reports `accounting_error` and makes no
refresh claim. Preview, projection, rehearsal and census do not refresh it.
The Tools census's `call_fit` reports static fit, unavailable contracts or the
exact failure independently of proof/admission errors. Static fit is not a
claim that the ability is admitted, healthy or has run successfully.

Omitting fixtures captures one bounded rehearsal with supplied input (default `{}`). Page/find/read-only action calls run live through ordinary gates; effects, authored runs and decisions return visible placeholders. Only `host.files.list`, `host.files.count`, `host.files.read` and `host.files.info` primitives read live, under declared reach/admission. Later rehearsals replay the sealed capture. Hand-written fixtures supply `input,calls:[{operation,args,options,result}],answers,expected`; `expected` is the complete returned JSON. Rehearsal never keeps code or proves live effects.

### Compiled from practice

The nightly compiler, its compile-only save context and tape recording are
removed ([Habits H4](HABITS.md#h4--one-crystallizer)). The practice note inside
the turn is now the only crystallizer. Ordinary hand-written fixtures still supply
input and expected, with optional calls and answers, within 16 cases in
256 KiB; `fixtures:[]` explicitly clears inherited fixtures.

Existing abilities can carry embedded tape fixtures
`{input, calls:[{operation,args,options,result}], tape:true}` and
stem-authored `compiled` provenance `{key, principal, examples}`.
A revision inherits omitted fixtures, conversion sources, provenance and
the recorded origin. Callers cannot supply tape. Every revision carrying
`compiled` stays staged until its own exact version replays, including
under Full Mac.

`ability.validate` answers every app call, read, primitive and nested part
from that embedded tape: exact operation, arguments and outer operational
options, in order, all consumed, nothing reaching the app. A decision or an
unrecorded call fails it. Missing result paths remain absent; nothing is
reconstructed. The part's returned value is not compared: replay proves the
recorded calls, no other input or branch. A hand-written fixture carries no
`tape`, and a candidate never mixes the two.

The seal retains `tape` `{examples, calls, consumed, effects}`.
`ability.read` still displays `compiled.lifecycle`: `staged`, `verified`,
`admitted` or `off`; validation evidence is `tape_replay`. The examples'
steer remains provenance, so keeping another agent's work still requires
the owner's card. Replay earns no live record. Gated live runs project
execution counts and bounded call scopes in `learned.use`; they do not
confer autonomous standing. The existing cost/confidence law governs
Expansion's turn-start and follow-up predictions.

## Execution and ownership

Every ability receives frozen input and only declared action dependencies, with named or positional args. A named method call takes its argument
object and at most one options object (`preview`, `expected_version`); a supplied nonobject or any surplus argument refuses before execution,
both in static admission when known and at the live door. Host primitives (`host.model`, `host.fetch`, `host.network`, `host.program`, `host.apps`, `host.files`, `screen.*`, `hand.*`, `host.paths`) require declared reach at the broker.

Apple Event parameters in `host.apps.call` and `sense.apps.read` use four-character
keys and JSON primitives, lists, `{type}`, `{enum}`, `{ordinal}`, `{record}`, or
`{object:{want,form,seld,from}}` descriptors. Absolute ordinals are validated
against `"all "`, `"firs"`, `"last"`, `"midd"` and `"any "`, including the
spaces, and encoded as `typeAbsoluteOrdinal` (`abso`). For example,
`{object:{want:"docu",form:"indx",seld:{ordinal:"all "},from:null}}` selects
every document of the application. `{enum:"all "}` remains an enumeration,
not an ordinal. This encoding is generic for every app.

A held call, `host.apps.call({…, read_only:false, hold:{seconds, settle}})`
(seconds 1–30, `settle` an AppleScript body under the same checks as `script`),
waits after its script returns and then runs `settle` against the same app
process, write-capable and never launching it. The stem owns the timer: Stop ends
the wait and the settle still runs; a script failure after a possible effect
settles at once and keeps its failure; a script that sent no write event holds
nothing. A later write to the same process supersedes the hold: its settle is
skipped (`outcome:"superseded"`), and a process that quit gives `player_exited`.
The answer keeps the script's reply with `hold:{seconds, cancelled, outcome,
settle}`; an unconfirmed settle is `hold.state:"settle_failed"` with unknown
effects. What to settle is the part's
judgment: Music's play stops only if the current track is the one it started.

`host.files.query({path, sql, params?, limit?})` opens the source read-only and uses SQLite's backup API for one consistent
private temporary snapshot, including committed WAL pages, then runs one read-only
statement with the stem's `folded_contains(text_or_blob, needle)` (containment that
ignores case and diacritics) beside SQLite's own functions: at most `limit` rows
(1–1000, default 200, `truncated` when more exist). Snapshot and query finish on
SQLite completion/error or Stop. Busy/locked snapshot acquisition reports its
actual SQLite failure without sleeping or retrying; sidecars are never copied
independently. Nil SQLite conversion is a failure, except a genuine zero-byte
blob. SQL tail validation completes within the SQL string buffer's lifetime.
Cells come back as read: text as text, blobs as `{base64}`.
`host.files.mime({path, max_text_bytes?})` reads an `.emlx` or RFC 822 file:
headers and parts, text parts decoded, attachments as metadata only. Downloaded attachments are sized from file metadata without loading their
contents; only attachment saving requests those bytes. `max_text_bytes` bounds returned UTF-8 text (1 KiB–16 MiB, default 1 MiB), with
`partial:true` when cut; the saved message itself and inline MIME content are still parsed whole. What the parts
read is what the app holds, as a native reader would read it; nothing is redacted.

Using `app.step`, `app.decide`, `app.expect` or `app.expect_fail` makes a run strict: calls are journaled, receipts read exactly, writes bound to the page version it read. Dependencies use the same call-fit law above; whole argument/result snapshots, behavioral flags and revision changes alone never refuse a run.

Recorded practice calls also carry `options` (`preview`, `expected_version`)
beside `args`; replay compares these outer operational choices exactly.
Versions returned from a prior taped read remain exact and flow into later
options. Old action tape rows with no recorded options cannot replay. In
hand-written fixtures an omitted `options` means `{}`.
Cards wait; only `app.decide` hands back a bounded checkpoint. Resume returns landed-write receipts without repeating effects. Any prior primitive call (network, program, screen, hands, model, fetch, apps) prevents resume. A fresh-run call is offered only when the runner reports no effects; otherwise its reconciliation remedy stands. An aborted replay still accounts for every effect in the original journal. Changed code, admission, host revision or reads, or a dependency call that no longer fits, visibly refuse/close the saved run, preserving journal and held work. The same world stop at the same place in 2 of the last 3 runs leaves one MY QUEUE upgrade line.

The checkpoint owner reports save, inventory, read, seal, claim and cleanup
failures through the typed failure/remedy shape. A claim verifies one byte
image and preserves it on failure; successful consumption and release are
explicit settlement operations. A failed cleanup cannot turn a committed
queue closure or run result into an unrecorded outcome.
Queue closure discards only waiting checkpoints. A claimed
checkpoint survives hold reads and cleanup until its claimant consumes
or releases it; ending another hold grants no ownership of the claimed bytes.

Origins ratchet across revisions and restores: an untrusted agent's,
a pack's or an unrecorded origin cannot become their own by saving it again. A
trusted agent that started a turn is its provenance, never an ability's author
nor the owner: what they switched off (an ability or a sense) is their to turn on
or drop, and below Full Mac keeping is their card.
Owner off marks remain owner-controlled. An ability with a persona procedure's
identity carries `overrides:built_in`; revisions never rediscover the original
markdown. Previous files remain history; abilities and senses have no public
version-swap action and repairs go forward. Prior host effects remain real.

Legacy numeric versions must be positive integers before migration prepares
any slot; invalid versions preserve the old layout and report the cause.
Launch admits current bundled seeds. Only an untouched seed follows a changed
bundle: the seed owner compares its complete authored/sealed identity (body,
header version, reach/wake/face/residency, manifest and dependency contracts),
excluding installation timestamps, admission and status bookkeeping. A changed
seed retains the displaced version as previous and preserves its installed off
switch, including who switched it off and why. An authored version is left
alone; first installation skips an id occupied in another retained slot.
The unsigned candidate uses that same identity comparison before admission:
an already-current seed is left alone without signing or proof work. Body,
header and live dependency-contract changes still require admission. For an
update, the executable owner checks the installed candidate and seal under
the seed selection lock before replacement. Missing authority or changed
sealed bytes preserve the installed source and report the seed failure through
Doctor. Ordinary execution still verifies each admitted version on use.
Launch-time dependency discovery projects the checked file registry before
the live senses hub is wired; sense execution requires the live hub.
Doctor's `ability_files` reading reports this launch's current seeds that skipped
admission and new admissions prepared, or explicitly says the launch pass was
not observed; successful file reads alone do not claim seed installation.
Launch does not rewrite or re-sign retained tool and skill records.
Retained historical candidate script declarations and
origins remain readable until their owning conversion preserves that evidence.
Historical steer origins must be arrays of nonempty strings; malformed entries
remain unrecorded provenance and cannot be filtered into their authorship.

## Conversion census and cutover

Read `app {page:"tools", item:"census"}` (also Skills) for their abilities, retained
guidance, persona procedures, waiting versions, immutable JS candidates,
historical previous-version sources and senses.
Each entry names language, status, counterpart and blocks_cutover. complete
means no entries have cutover blockers. Unreadable/corrupt evidence is an error.
Read it on the installed final revision: changed action/discovery shapes require
re-saving and exact review of affected abilities before cutover.

Optional converts on ability.save lists original source SHA-256
digests from this census. The common candidate identity and validation seal bind
these links. Current active capabilities require an accepted JS counterpart;
inactive originals need validated counterparts without being activated. A
retained historical previous version needs an explicit digest link. Conversion
candidates stay retained with their originals. Native fixed Swift senses remain
native. Authored sense files require the current JavaScript candidate form;
historical Swift and source-only sense readers are removed.

Sense inventory checks source membership and proof per retained version. A
source/proof failure is named on that version, with unknown membership rather
than an empty file list. A failed selected on-version is presented as unavailable;
a failed previous version remains visible without disabling the healthy current
version. Siblings still load. These are read projections: their errors do not
rewrite saved lifecycle or authority during another sense's publication. Source
use, export and explicit version selection retain their checked owner; a failed
version never selects another source. Required catalog/accounting and bundled
default reads still fail as a whole when unreadable.

Cutover is a merge decision after the installed census reads complete. There
is no runtime census guard or auto-conversion. Markdown and Swift originals
remain history. Ordinary ability/sense execution failures never try an original
body, another language, another executor or an earlier version. No public
action selects an earlier ability or sense version. The turn part's existing recovery is described
[above](#turn-recovery) and is the one stated exception in
[NORTHSTAR clause 2](NORTHSTAR.md#clause-2--no-theater-alive-means-real).
Skill-specific persona read/write aliases are removed; ordinary persona
documents retain their owners. `persona.read` declares only `kind`; the retired,
unused `skill_name`, `source` and `content` arguments are no longer advertised.

## Storage and package metadata

Every decoded `AbilityStore.File` has a derived record, including an unkept draft.
Headers accept only `ability`, `sense` and `turn`; bundled seed headers use the
same vocabulary. The retired tools/skills/senses registry adoption and old-backup
reconstruction are removed. Retained sealed `tool`/`skill` program kinds and
historical manifest `permissions` remain readable only where the existing
installed files still require conversion; the executable program's current
`permissions` declaration is distinct from that header compatibility.
Backup restore admits only the current snapshot with its captured abilities
and live persona, validated before staging under the
[restore law](canonical_data_paths.md#restore-law).
Candidate file identity must match its sealed program identity; reads never
rebind a program to another owner. Retired `connector:` reach is rejected.

Helper argument transport must be a JSON array before replay classification or
dispatch. Receipt/output byte accounting uses successfully encoded bytes;
serialization failure preserves the completed effect and stops further calls
with `serialization_failed`, never a zero-byte ledger entry.

`Parts` (ToolExecution) owns the one form over `AbilityStore` files and
OwnedProgramStore's immutable candidates, sealed proofs and publication.
Historical bodies and history files are census material, not execution or
ordinary discovery sources. Capability-pack installation, receipt listing and
removal are retired; abilities are created through Parts/AbilityStore. Connector
inventories retain their manifest metadata, permission and OAuth ownership.

## Inventory

Abilities are projected by `Parts` and shown on the Tools page; built-in guidance
is read by
[InstalledSkillInventory.swift](../Modules/NativeAgentCore/Sources/PersonaEngine/InstalledSkillInventory.swift)
as `SkillRecord` throughout discovery, source reads and Mac/phone presentation,
and shown by
[AppModel+SkillsIntegrations.swift](../Sources/NativeAgentApp/AppModel+SkillsIntegrations.swift).
There is no `manifest_registry.json` reader or merge.

Part publication reports settlement failure with committed evidence: kept versions,
discarded drafts, and written turn slots remain named. Trial bookkeeping must
succeed before automatic keeping. An open turn trial requires its recorded kept
baseline; an inconsistent baseline refuses before writes. Weighing requires an
installed turn program and returns its finite authored worth without clamping.

`host.network.receive`, `host.network.accept`, `host.network.send`,
`host.program.receive` and `host.program.send` wait for data, protocol completion,
EOF/exit, transport failure or cancellation. They take no `wait` argument and do
not return a timer-produced pending result. `host.fetch` follows the same rule.
Read a started program with `host.program.receive({id: program.id})`; each read returns output or terminal evidence, and Stop cancels a pending read.
