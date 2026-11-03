# NativeAgent Ability Header and Spec

Every `abilities/<id>.js` or `.md` is a part: a JSON header in a
`/* NativeAgent ability … */` or `<!-- NativeAgent ability … -->` comment,
followed by its code or retained guidance. `kind` is `ability` (what they
grows), `sense` or `turn`. All kinds have the same header and one
524,288-byte (512 KB) source limit. An ability is an ability: what it can do
is what it declares, never which door made it.

`turn` (`abilities/turn.js`) exports `step(state, event) → {state, do:[effects]}`; the stem owns the loop. Events:

- `message`: text, attachments, sender, surface and trust.
- `model`: final text and requested calls, each with `id` and `index`. Visible text streams directly; no chunk events. The closing one (no calls) carries `repeated: {call, count}` with the longest stretch of one call, with the same input, made again round after round.
- `result`: one call's `{index,id,name,ok,effect}`. Effect comes from explicit receipts, else `execution:executed`, including batch receipts/script ledgers: an ability's all-read ledger reports `read`; `part` names effectful ability/sense work, else strongest of irreversible/write/read; absent when nothing landed. The broker's per-call class, not declared ability permissions or its prose, decides whether a reached call reads.
- `provider_failure`: provider, model, text, remedy, work, owed, tries and available repair calls.
- `observation`; `resumed`, whose `effect` uses the same reading over saved receipts.

Effects are `model.call`, `app`, `reply.stream`, `reply.end` and `after`. `model.call` accepts `effect`, optional `id`, `purpose`, `note` (adds their words before the call); the first requires `system:{stable,dynamic}` and may name `tools:[names]`. Later `system`/`tools` and all `messages`/`stream`/`chunks` fields fail validation and trigger current recovery; the stem owns conversation and streaming. This ABI differs from the host primitive `host.model.call` below.
`app` runs one requested call verbatim, by id or index, once through the turn's gates. Only `provider_failure` also admits an explicit repair `call:{tool:"app",input:{…}}`, assigned a new repair identity.
`reply.end` follows a model reply without calls, an owned provider failure or its repair result (incomplete). Delivery completes at `reply.end` and `after`; later effects run privately after return ([turn anatomy §6](ANATOMY_OF_A_TURN.md)). Reach: `turn.persona()`, `turn.pins()`, `turn.recall()`, `turn.context()`.

`turn.persona()` supplies the compiled `prompt`, caller-supplied `guidance` and
`expression:{established:bool}` for ordinary turns (null for internal thoughts).
The turn seed owns baseline and first-run expression instructions, with no
persona edits. `turn.context()` supplies tools, digest, packet, history, facts
and optional `runtime:{view_mode,contacts,fact_index}`. The native report of the
admitted surface/provider/model remains in `facts`; contacts are `{status:"available",rows:[...]}`
or `{status:"unavailable",reason}`. The seed authors model-reporting and setup
advice from these facts; `fact_index` identifies the report in `facts`, where
the seed adds its words. Swift retains settlement classifiers and identity storage.

Desk continuation cues use the ordinary `turn-continuation` ability through
L0 `Parts.call`, bound by `ToolsFacade.withPartDoor` to the continuation's work
identity and restored taint. Its input is only the Desk handle; its result is
an array of Codable cue cases: `{text:{_0:string}}`, `{remainingWork:{}}`,
`{settled:{}}`, `{lastReply:{}}`. Swift inserts the checked record's remaining
work, last twelve settled receipts and first 4,000 reply characters after the
part returns. Receipt/reply text can quote credentials and never enters the
part. The seed authors the instructions; native verification, claims, CAS,
scope, settlement and the original reply route remain authoritative. Missing,
disabled or failed parts fail the dispatch visibly; no Swift template runs.

<a id="turn-recovery"></a>

The turn log keeps events, reach answers, started-effect identities and streamed text for identity-matched resume/replay. Payload hashing supplies identity only for effects without an explicit identity; starts do not store a separate digest. Current selection reads `turn.js`; only a missing current slot installs the shipped seed, and that write must succeed before it runs. An unreadable or wrong-kind current slot ends with its storage cause and repair, without consulting another version.

Every non-Stop failure of the selected turn program or its helper invokes the one exception in [NORTHSTAR clause 2](NORTHSTAR.md#clause-2--no-theater-alive-means-real), including JavaScript exceptions, invalid answers, timeout, startup, resource and transport failures. Recovery consults the previous slot, or selects the shipped seed if no unfailed previous source exists, and replays the same identity-matched log. Each source is attempted once per turn; a helper failure while running the seed admits one extra fresh lease (`freshHelper:true`), through the same checked current-slot admission. A consulted unreadable previous slot or failed recovery write ends with its storage cause; an uncommitted replacement never runs. A concurrent checked current write is adopted without swapping it unless already failed this turn. `turn.part.unavailable` preserves the original helper cause; `turn.part.recovered` names `program` (`previous`, `seed`, or a concurrent `current`) and `sourceDigest`, and `turn.part.helper` proves the selected source ran. The repair arrival tells their which program replaced the failure or which helper lease was renewed. Stop remains cancellation. If every available source fails, recovery ends plainly rather than retrying forever; provider failures keep their own turn path.

| Property | Stored form and meaning |
|---|---|
| **code** | The file body, outside the JSON comment; JavaScript or retained Markdown guidance. |
| **reach** | `{capabilities: string[], readPaths: string[], hosts: string[], apps: string[]}`, all arrays default empty. Ordinary abilities consume `capabilities`, including `app_read:<id>`/`app_write:<id>` for app targets; `readPaths`, `hosts` and `apps` constrain senses only. Retained historical headers and sense reach load into this shape; ability saves take `reach`. Declarations do not grant authority. |
| **wake** | String array, default `[]` (called only). [Wake signals](#wake-signals) defines names, payloads and delivery. |
| **face** | `{page?: string, action?: string, projection?: bool}`, default `{}`. An authored tool's action lists on this door page, or diagnostics when absent; `action` claims an unclaimed door id. Unknown pages refuse at save. `projection:true` declares `face(input)`; its typed sections/rows are computed from frozen native sources outside view rendering and published through `LatestRead` (contract below). |
| **state** | Abilities use `host.state.get()` → saved JSON (initially `null`) and `host.state.set(value)` → `null`. One durable notebook owner, shared with senses' keyed `state.get/set`, stores it by ability id at `senses/<id>/state.json` under key `part`; it survives helper restarts and app relaunch, and `ability.drop` deletes it with the ability. Values are limited to 16 KiB and the notebook to 64 KiB. Validation and preview use a scratch notebook. Resume replays journaled state results without repeating their operations, then reads and writes durable state normally. State calls do not renew stalled execution. `abilities/state.json` remains lifecycle/run accounting only; there is no authored header `state` key. |
| **learned** | Optional arbitrary JSON, preserved verbatim; a declared value teaches nothing. The stem projects `learned.use` (below). A part's prediction (`applies`, `after`, `record`) is the stem's, never declared: see [Expansion](#expansion-a-part-is-a-prediction). |

`id` and integer `version` identify the part and version.

### Wake signals

Accepted: `schedule:<cron>`, `app.installed`, `file.changed:<path>`, `turn.ended`, `message.arrived:slack`, `message.arrived:telegram`, `held`, `resumed`, `person.away`, `person.here`, `network.down`, `network.up`; suffixes are nonempty. Existing files naming another transport still read; new versions must use this set.
While on and Autonomy allows unattended work, an ability runs as `authored.<id>`, a sense receives an event in its resident slot. Signals bypass params checks, supplying only `input.wake={signal,at,...payload}`:

- `schedule:`: one TriggerScheduler job per part/schedule; fires arriving during a waiting run coalesce.
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
- `turn.ended`: `turn_id,outcome,session_id,trace` (day file in `turn_traces/`); excludes turns the ability's own run started.
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
- `network.down`, `network.up`: `is_up`, from the one process-wide `NetworkSense` path owner, through the same signal delivery as presence. The first observation establishes the launch baseline; later changes must hold five seconds before posting, and a flap back to the last posted state posts nothing. This reports a usable Mac network path, not provider health. Transport waits and resident wake admission read the immediate state; abilities and `on network.up` intentions receive the settled signal.

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

With `face:{projection:true}`, `function face(input)` (optionally async) returns
`{sections:[{id,title?,rows:[{id,title,detail?,value?}]}]}`. All fields except
`sections`/`rows` are strings; ids are nonempty and unique within their lists.
At most 64 sections and 256 rows per section, within the same 4 MiB bounds.
Faces run the same signed bytes in a fresh sandbox helper against frozen sources, with no host
effects or notebook access. Swift `Parts.face(id:input:version:)` returns
`PartCallResult<PartFace>`. The result, face and snapshot wire types live in
`NativeAgentShared` for both Mac and iPhone. A native source owner supplies frozen packets and
increasing epochs to `PartFaces.sourceChanged`; cached Codable
`PartFaceSnapshot`s publish through `LatestRead` and are read by Mac/phone
views. Cancelled reads publish and cache nothing; the last published snapshot
stands, and the next ask may compute again with the same version and source
epoch. Source and ability-version changes drive recomputation. Unavailable,
failed and owed belong to native snapshot fields beside the face, never to
editable rows. Native invocation and publication details live beside `Parts`
and `PartFaces`.

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

`app.home.arrive({line,event_key?})` deduplicates a supplied occurrence key
durably within the calling part. With no key, it deduplicates by local day and
line. The part's thread still enforces the hop limit and carries taint; the
executor has no bundle/version policy. A line that touches one of their cares,
or that nothing can judge, wakes their; the rest waits on the news board for their
next turn ([SUBCONSCIOUS.md](SUBCONSCIOUS.md) Cares).

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
[`Expectation`](../Modules/NativeAgentCore/Sources/NativeAgentCore/Expectation.swift),
shared with after-turn claims; Expansion's practice owner measures its costs;
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

**Delivery.** a read runs through the same chain only by the judgment the Trust gate makes of the call as it runs (`PermissionLaw.toolClass` of its ran call) and by its enforced declaration: read-only capabilities and a declared class that reads (for their parts, their reach over every permission and dependency, so a part's own readOnly flag beside a write permission is no read; never who wrote them); a preview; or a page, page item, find or home, by where the door itself resolves the call (`AppDoorNames.place`, the same steps `runAppDoor` takes). It waits no longer than the round it would save and at most half of what the call's own enclosing ceiling still leaves (`TurnDeadline.secondsLeft`), on a wall clock that neither progress nor a person's wait renews or pauses, and does not start when its usual run would not fit, so the call's own result is never lost or late; and rides inside the result under `already_looked` (`{call, result}`); the read it brings may carry the next one, three deep. An act is only previewed and rides under `ready_to_confirm` (`{call, preview}`); it never runs. A batch, a script, or any page or path the door resolves to one of home's items (which does what its name says) is neither. Nothing rides on a result parked on a person, on a stopped turn, or past the provider's inline ceiling (`ProviderToolResultPage`). Every delivery passes the whole gate chain as the mind's own call would and grants nothing that call would not have.

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
a connector refuses; a fetch waits up to `wait` seconds (default 120, accepted
0–86400) for its whole answer. Expiry or Stop ends only that response wait,
reporting an unknown outcome and its `fetch:<uuid>` experience id. The admitted
request survives run close under a wall-clock transport ceiling of
`max(600, wait)` seconds; transport expiry cancels it and joins its actual exit,
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
A signed-in secret is renewed shortly before it expires and once when a fetch
carrying it is answered 401 (the fetch then sent once more, under the same
grant: never under one the person made while it was out). A permitted omitted
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

`learned.use` projects version totals and bounded recent input/call outcomes.
Run call labels and input previews are redacted before accounting is saved;
retained accounting text is redacted again when projected, including previews
saved under an older content policy. Retained accounting bytes are not migrated.
Version evidence requires its recorded `count`; outcomes must sum to it. A new
version starts with zero observed runs. A run never reconstructs a count from
outcomes or a previous-version success from last-run fields. Missing counts
leave the stored bytes preserved and unavailable. `states()` reads without
writing and reuses only the exact checked accounting file identity.

What they works out by hand repeatedly, they keeps. Hand work or one call
repeated with the same input 3+ rounds offers a private keep after the reply:
keep the route as an ability, revise the part they worked around or looped,
or keep nothing. The native stem meets only the hand work's ordered
tool/action ids (landed writes or irreversible non-ability calls, with
incidental reads and arguments left out), or the one repeated call when
there is no such hand work, as one `practice: ` line through `FamiliarLines`
in `mind/familiar.bin`. The first meeting records it without a keep call.
The second and later meetings admit it unless an active ability's current
learned-use or validation route covers those ids in order. Later rounds
finish an admitted keep. This uses the same bounded habituation as lines
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
it), newly kept first, then by find's ranking against the message. Unranked rows
put failures first, then the most recently used, then the existing action order.
An empty message has no ranking; it shows new, failed and recent abilities first.
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
appear only when all rows fit with them. Rendering captures fresh rows' exact
kept stamps without writing shown markers. The accepted-context delivery hook
conditionally acknowledges those stamps on the first nonempty provider text or
tool call, only when their text is carried in that context and the live turn/time
stamp still matches. A failed preparation, cancellation before output or screen
preview consumes nothing; an omitted row or collapsed autonomous count does
not acknowledge a new part. A shown-marker save failure leaves the provider reply
proceeding and reports a `readFailure` repair note through `RepairOwed` for
`abilities.shown`; marker effects remain unknown and any markers already saved
are preserved. The existing home repair rows carry the note after the turn.
Find requires checked semantic ranking. An unavailable embedder, unusable vectors
or mismatched index epoch returns `action_ranking_unavailable` and the owner repair;
it produces no word-only substitute. Exact current action addressing remains a
separate lookup. Lookup, page actions, policy projection and ranking consume the
same checked action inventory; a failed peer, sense or authored-store read is
unavailable, never a successful empty catalog. Native schema parse/property failures
stop discovery and admission instead of manufacturing arguments from display text.

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
| `ability.save` | `{id, description?, code?, edits?, params?, actions?, fixtures?, name?, triggers?, converts?, create_only?, reach?, wake?, face?, resident?, learned?, choices?}`. Creates or revises: a new ability needs description and code; a revision inherits everything it does not restate from its latest version; an explicit empty value drops one. Send code or edits, never both. `params` is the type map (string, int, number, bool, list or object; a trailing `?` marks it optional), `{type, description?}`, or a JSON Schema object (`readOnly:true` declares a read contract); `params` is its sole input-contract argument. Direct app dot/bracket members and reach derive dependencies; `actions` declares indirect calls (literal or computed). Literal calls and declarations are checked before staging; unknown actions and missing dependencies refuse save, while computed names produce warnings and keep runtime checks. Under Full Mac their own save is kept and on in this one act (sealed as kept: its first real run is its proof), with a decided Inbox row; below Full Mac, or when an untrusted agent started the turn, it is a draft. A revision inheriting older `compiled` provenance remains staged until its exact version replays ([compiled from practice](#compiled-from-practice)); no new nightly compiled candidates are produced. A revision may name an existing ability by id or name. New ids are normalized by trimming whitespace, lowercasing, replacing runs outside `a-z`, digits, `-` and `_` with `-`, and trimming edge hyphens; the result must be 2–64 characters, a letter first (`^[a-z][a-z0-9_-]{1,63}$`). |
| `ability.validate` | A read: `effect:none`, `read_only:true`; a reached rehearsal reports `execution:rehearsed` and `effects:none`. Rehearses its waiting version with the shared helper and intercepted replies, on fixtures or one captured run with `input`. A version compiled from practice replays its tape instead (`candidateValidation` `replayed`). Proves no live behavior; never keeps. |
| `ability.enable`, `ability.restore` | Keeps its waiting version, or turns it back on: theirs under Full Mac for their own work (sealed as kept when never rehearsed); otherwise, once rehearsed, the owner's card for this exact version (code, fixtures and dependency shapes), approvable on the Mac and the phone, or Keep on the Tools page. Code requires `version` equal to its full digest, captured with the displayed code when the card or row was staged and saved with it; self-improvement cards and approval replay carry that same saved digest. A caller without the exact review offers a read rather than executable approval. A version compiled from practice is kept by no one until its tape replayed (`not_replayed`). Omitting `version` restores only disabled Markdown guidance with no candidate or code fingerprint, checked and written under the ability-store lock. |
| `authored.<id>` | Its one run, with input by its params, under one signed admission re-verified on every run. `preview:true` runs its code with every write previewed and says where it would card or hand back. |
| `ability.resume` | A stopped run_id and bounded answer; optional `id` binds it to that ability, with a mismatch claiming nothing. A rename claims the checkpoint; its bytes are read and verified once. Read/admission failures preserve the claimed evidence; pre-run refusals and busy admission release the original bytes. Completed or deliberately closed runs consume the checkpoint at settlement; cleanup failures stay in `settlement_failures` with cause and remedy. Rechecks selection, host revision and admission and replays prior reads. A woken run resumes with the `input.wake` it stopped on. `preview:true` only reads the checkpoint: it reports the question, input, wake and stopped call, without claiming the run, transferring holds or closing its queued step. |
| `ability.read` | Every stored kind, including turn and sense: kind, version, declarations, status, retained versions, evidence and code in pages (`offset`), or one `step`; ordinary abilities also expose waiting/last-clean and converted versions. |
| `ability.disable`, `ability.drop` | Off with every version kept, as whoever did it (`disabledBy`): `theirs` for their turn or their ability (a trusted agent's turn included), `owner` only for their own surface (the Tools page), `peer` for an untrusted agent's; theirs they turns back on, the owner's is their to lift (`ability.enable` asks on their card); delete it, its versions, its run state and its `host.state` notebook (`pending:true` discards only the waiting version). A built-in skill's own version is the owner's to switch off or drop below Full Mac. |
| `ability.list` | Every stored part, including turn and sense, in a bounded page (at most 40 rows and a 24 KB row budget), ordered by id. Rows carry kind, version, `runs` from stored `useCount` and `last_run_at` from stored `lastUsedAt` (ISO timestamp, null when never run). `count` is the rows printed, `total` is the inventory; follow `next_call`/`next_offset` with `offset` when `has_more`. The Tools page reads this same projection and accepts `args.offset`; a named Tools item accepts a source offset, also reachable by `ability.read`. Full declarations and versions remain on `ability.read`. Unshadowed built-in guidance remains discoverable; unreadable bodies are named in `guidance_gaps` and refuse only their own read. A missing guidance directory is empty; an unreadable one fails with its read error. |

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
Calling a namespace alone, such as `app.desk(args)`, refuses with the working
`app.desk.<verb>(args)` and `app({action,args})` shapes. Malformed callable
requests and batch entries name those working forms as well. Saving checks
their static call shapes; it never executes code to discover a runtime fault.

Before any candidate is staged, `OwnedProgram.calls` reads literal calls using
the shared source lexer: app members, callable action/batch requests and
`app.call`, action names in `app.read`, host members and `host.call` (including
file/PIM aliases), and `part.call`.
`Parts` checks the live door's action catalog and existing authored abilities.
An unknown action refuses save, naming it and the nearest real actions from the
door's existing ranking. A literal indirect action absent from effective
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
Computed action names (concatenation and interpolated templates included) remain
runtime checks; completed save receipts carry `warnings` naming their lines,
rather than refusing them. In particular `"authored." + id` is never validated
as an action called `authored.`. `ability.validate` applies the same check
before starting rehearsal. Inspection executes no code and does not prove
arbitrary JavaScript behavior or external availability.
Local bindings and parameters are respected, so their own `part` helper or
`screen` value is not mistaken for the prelude's object.
The schema describes `params` as a type map, per-param `{type,description?}`
or `{type:"object",properties,required?,additionalProperties?:false,readOnly?:bool}`;
`integer`, `boolean` and `array` alias `int`, `bool` and `list`, and a trailing
`?` marks optional inputs. Param names match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`;
each declaration accepts only `type` and an optional nonempty text `description`.
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

Desk holds are checked before ability work or queue completion. A stopped run's
hold or metadata failure retains the run result and identifies the failed
settlement with a repair debt. Upgrade evidence remains on the result until its
queue append succeeds. Resume hold transfer, queue closure and returning busy-run
holds report their owner failures; none claims an empty ownership set after a
failed read or write. A resumed result retains completed effects when queue
settlement still needs repair.

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
removed ([Habits H4](HABITS.md#h4--one-crystallizer)). The turn's private keep
is now the only crystallizer. Ordinary hand-written fixtures still supply
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

Every ability receives frozen input and only declared action dependencies, with named or positional args. Host primitives (`host.model`, `host.fetch`, `host.network`, `host.program`, `host.apps`, `host.files`, `screen.*`, `hand.*`, `host.paths`) require declared reach at the broker.

Apple Event parameters in `host.apps.call` and `sense.apps.read` use four-character
keys and JSON primitives, lists, `{type}`, `{enum}`, `{ordinal}`, `{record}`, or
`{object:{want,form,seld,from}}` descriptors. Absolute ordinals are validated
against `"all "`, `"firs"`, `"last"`, `"midd"` and `"any "`, including the
spaces, and encoded as `typeAbsoluteOrdinal` (`abso`). For example,
`{object:{want:"docu",form:"indx",seld:{ordinal:"all "},from:null}}` selects
every document of the application. `{enum:"all "}` remains an enumeration,
not an ordinal. This encoding is generic for every app.

The Music seed's bounded play uses `host.apps.call` with a playback `script`,
`bundle_id:"com.apple.Music"`, `read_only:false`, `seconds` (integer 1–30) and
the selected song's `track_id` (16-digit hex persistent ID resolved before play).
Only Music playback scripts take that duration. The script returns
`ok|||<current track persistent ID>` after starting playback at position zero;
the native adapter waits, then settles a stop bound to that process, track and
playback command, even if cancelled. Any later native Music playback command
transfers ownership, including another play of the same song. A script failure
after a possible playback effect settles an immediate stop and retains the
original failure. Both `play_receipt` and
`stop_receipt` remain in the answer; a failed stop is `bounded_stop_failed`
with unknown effects. Other apps and read calls refuse `seconds`. Ordinary
authored work uses the declared `music.control` action with `seconds`.

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
