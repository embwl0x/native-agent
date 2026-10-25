# NativeAgent Ability Header and Spec

Every `abilities/<id>.js` or `.md` is a part: a JSON header in a
`/* NativeAgent ability … */` or `<!-- NativeAgent ability … -->` comment,
followed by its code or retained guidance. `kind` is `ability` (what they
grows), `sense` or `turn`; a header written `tool`, `skill` or `part` (before
the one form) reads as `ability`. All kinds have the same header and one
524,288-byte (512 KB) source limit. An ability is an ability: what it can do
is what it declares, never which door made it.

`turn` (`abilities/turn.js`) exports `step(state, event) → {state, do:[effects]}`; the stem owns the loop. Events:

- `message`: text, attachments, sender, surface and trust.
- `model`: final text and requested calls, each with `id` and `index`. Visible text streams directly; no chunk events.
- `result`: one call's `{index,id,name,ok,effect}`. Effect comes from explicit receipts, else `execution:executed`, including batch receipts/script ledgers: `part` when every landed effect ran an ability or sense, else strongest of irreversible/write/read; absent when nothing landed.
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

The log keeps events, reach answers, started-effect identities/payload digests and streamed text; resume/recovery replay it, matching starts and results by identity. Current selection reads clean `turn.js`, then `turn.prev.js`, then the shipped seed (installed when accepted). A throwing/malformed step swaps only the failing version and replays the turn. This records existing recovery, not an exception to NORTHSTAR's no-fallback design law. Unrecoverable helper, setup, seed or provider failures can end incomplete, with their cause and repair.

| Property | Stored form and meaning |
|---|---|
| **code** | The file body, outside the JSON comment; JavaScript or retained Markdown guidance. |
| **reach** | `{capabilities: string[], readPaths: string[], hosts: string[], apps: string[]}`, all arrays default empty. Ordinary abilities consume `capabilities`, including `app_read:<id>`/`app_write:<id>` for app targets; `readPaths`, `hosts` and `apps` constrain senses only. Legacy `permissions` and sense reach load into this shape; saves write `reach`. Declarations do not grant authority. |
| **wake** | String array, default `[]` (called only). [Wake signals](#wake-signals) defines names, payloads and delivery. |
| **face** | `{page?: string, action?: string, projection?: bool}`, default `{}`. An authored tool's action lists on this door page, or diagnostics when absent; `action` claims an unclaimed door id. Unknown pages refuse at save. `projection:true` declares `face(input)`; its typed sections/rows are computed from frozen native sources outside view rendering and published through `LatestRead` (contract below). |
| **state** | Abilities use `host.state.get()` → saved JSON (initially `null`) and `host.state.set(value)` → `null`. One durable notebook owner, shared with senses' keyed `state.get/set`, stores it by ability id at `senses/<id>/state.json` under key `part`; it survives helper restarts and app relaunch, and `ability.drop` deletes it with the ability. Values are limited to 16 KiB and the notebook to 64 KiB. Validation and preview use a scratch notebook. Resume replays journaled state results without repeating their operations, then reads and writes durable state normally. State calls do not renew stalled execution. `abilities/state.json` remains lifecycle/run accounting only; there is no authored header `state` key. |
| **learned** | Optional arbitrary JSON, preserved verbatim. Reserved for phase 4; no learning behavior. |

`id` and integer `version` identify the part and version.

### Wake signals

Accepted: `schedule:<cron>`, `app.installed`, `file.changed:<path>`, `turn.ended`, `message.arrived:slack`, `message.arrived:telegram`, `held`, `resumed`, `person.away`, `person.here`; suffixes are nonempty. Existing files naming another transport still read; new versions must use this set.
While on and Autonomy allows unattended work, an ability runs as `authored.<id>`, a sense receives an event in its resident slot. Signals bypass params checks, supplying only `input.wake={signal,at,...payload}`:

- `schedule:`: one TriggerScheduler job per part/schedule; fires arriving during a waiting run coalesce.
- `app.installed`: `bundle_id,name,version,path,scriptable`, as data. Once per newly seen bundle/version after the baseline, after Info.plist and its declared scripting dictionary land.
- `file.changed:`: `path`; the sense watch waits through absence, reports deletion and ignores the ability's exact self-write echo.
- `turn.ended`: `turn_id,outcome,session_id,trace` (day file in `turn_traces/`); excludes turns the ability's own run started.
- `message.arrived:telegram`, `message.arrived:slack`: `text,session_id,turn_id` and chat/channel/user ids, after handling.
- `held`: the held resource's `id,kind` (`program`, `connection` or `listener`) for a resident ability, once per arrival. Runs serialize; duplicate waiting news coalesces. `receive`/`accept` reads it; an empty wait returns `pending`. Unread arrivals survive Autonomy-off or unreadable-catalog periods.
- `resumed`: once per app launch, for code to reopen held resources; likewise waits for Autonomy and a readable catalog.
- `person.away`, `person.here`: `idle_seconds`, once per transition (300 s idle; then the person's own input, never theirs). Same presence fact as home and `mac.system_info {person:true}`.

`agent` identifies non-owner words (untrusted steering or a non-allowlisted sender). The run uses current Trust and its own gate chain. A tainted signal skips write-capable parts with a trace and no card; trusted-agent signals carry owner authority. Required approvals wait; requests for their use `home.arrive {line}`, deduplicated per ability/day/line on its hop-limited thread (an explicit `event_key` uses durable occurrence deduplication instead).

### Calling a part and projecting its face

JavaScript `part.call(id, input)` returns `{ok:true,value}` or
`{ok:false,error:{code,message}}`. Declare the callee's `authored.<id>` in
`actions`; this is reach, never authority. Input is a JSON object up to 4 MiB,
deeply frozen for the selected version. A replacement can end that invocation
but never substitute another version. Returns are complete JSON up to 4 MiB;
truncation fails. Swift uses `Parts.call(id:input:as:)`, returning the same
`PartCallResult<Value>` with a Codable, Sendable value. Native callers bind the
originating gated `OwnedProgramInvocation.host`; they validate and commit the
decision in their own transaction after the call returns. Stop cancels work;
child settlement, terminal accounting and broker release run through `settle`.

With `face:{projection:true}`, `function face(input)` returns
`{sections:[{id,title?,rows:[{id,title,detail?,value?}]}]}`. All fields except
`sections`/`rows` are strings; ids are nonempty and unique within their lists.
At most 64 sections and 256 rows per section, within the same 4 MiB bounds.
Faces run in a fresh sandbox helper against frozen sources, with no host
effects or notebook access. Swift `Parts.face(id:input:version:)` returns
`PartCallResult<PartFace>`. The result, face and snapshot wire types live in
`NativeAgentShared` for both Mac and iPhone. A native source owner supplies frozen packets and
increasing epochs to `PartFaces.sourceChanged`; cached Codable
`PartFaceSnapshot`s publish through `LatestRead` and are read by Mac/phone
views. Cancelled reads publish and cache nothing; the last published snapshot
stands, and the next ask may compute again with the same version and source
epoch. Source and ability-version changes drive recomputation. Unavailable,
failed and owed belong to native snapshot fields beside the face, never to
editable rows. See [the L0 contract](AGENT_IS_THE_APP.md#shared-contracts-built-by-l0-10-23).

`host.model.call({purpose,prompt,schema?,tools?,surface?})` may offer `["app"]`
or `[]` and select an existing routing surface. `messages:[{role,content}]`
may replace `prompt`; tool thinking ends with a user message. An explicit surface
uses its saved route independently of the parent's per-turn model choice; omitted,
the caller's admitted route is inherited. It uses the
canonical tool-turn owner, the part's restricted host, its originating gate
chain and the caller's remaining limits. No persona, recall or after-turn mind
work is added to the thought.
Its primitive receipt retains nested tool effects through failure, cancellation
and JSON validation; missing effect evidence is `unknown`. Offering tools makes
the call capable of effects for replay, even though thinking itself needs no card.

`app.home.arrive({line,event_key?})` deduplicates a supplied occurrence key
durably within the calling part. With no key, it deduplicates by local day and
line. The part's thread still enforces the hop limit and carries taint; the
executor has no bundle/version policy.

`choices` is optional arbitrary JSON, preserved verbatim for phase 4 (for
example `{open_doc:["script","menu","screen"],date_format:[]}`).
`resident` defaults false. An ability retains its isolated helper/JS context after successful calls; each call gets fresh frozen input and originating authority. Error, refusal, cut or cancellation discards context. Preview, validation and replay use fresh contexts.
One resident broker holds programs, connections and listeners until closed, off, replaced, dropped or quit, including across failed runs. Code recovers their ids from `host.state` or `held` wakes; each use rechecks admission and Trust.
Sense retention uses `SenseRecord.mode`, not `resident`; `sense.make` creates `.onCall` senses.

### Secret insertion and redaction

Reach capability names are `app_data_read`, `app_data_write`,
`network_localhost`, `network_public`, `network`, `shell`, `computer_files`,
`arbitrary_file_write`, `app_read:<bundle_id>` and `app_write:<bundle_id>`.
`model`, `calendar`, `reminders` and `contacts` are reach for the host
primitives (`host.model.call`, the PIM door aliases), and `network_public` is
`host.fetch`'s (`network_localhost` for a loopback host; `connector:<id>` still reads, granting nothing; a fetch naming
a connector refuses; a fetch waits up to wait seconds (default 120) for its
whole answer);
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
grant: never under one the person made while it was out); a fetch carrying a
secret that only reads (GET or HEAD, no body) is a read in Trust, any other call
carrying one an effect;
`AbilityStore` names the full accepted set, including the run's screen watch
and Mac hands.
Unknown capability names, wake names, header keys and reach/face keys refuse by
name. Existing lifecycle fields (`record`, `candidate`, `proof`, `sourceFiles`)
remain store-owned. Retained sealed legacy candidate descriptors are unchanged,
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
`candidate`, `proof` and `sourceFiles` fields carry their unchanged lifecycle
payloads alongside it; a header alone is not admission to execute.

`ability.save` and `sense.make` accept `reach`, `wake`, `face`, `resident`,
`learned` and `choices` alongside their authoring fields. Legacy tool
`permissions` and sense `apps` remain accepted at the door. The census and the
ability reads expose each ability's reach, wake, face and residency; sense rows
expose their own `SenseRecord` version, reach and lifetime `mode`, without ability wake
or residency fields.

What they works out by hand, they keeps. When a turn landed work by hand, their
turn (`turn.js`) asks once, privately, after the reply: keep the route
that worked as one of their own abilities (the request's specifics as inputs,
failed attempts left out), save the fixed version of an ability they worked
around, or keep nothing.
The app reserves exactly the shipped seed ids in `Resources/abilities/*.js`
and every id starting `native-`; `ability.save` refuses these names, naming the
shipped part. `AbilityStore.seedCatalog` owns this set for saving and installation.
Future shipped parts use `native-`. Installation never replaces a part they
authored first, including an id occupied only by a retained or proposed version.
The retired `habit` seed is no longer shipped. A seed the app stops shipping
fades at launch: an installed copy whose bytes are still the candidate its seed
proof names, never turned back on, is switched off through its registry,
restorable and never deleted; a launch whose bundle has an unreadable seed
fades nothing.

Their own abilities are in front of their each turn: the turn glance lists them, one
line each (`authored.<id>` — what it does, and `ability.read <id>` when there is
room), best match for the message first by find's own ranking, within a small
budget, with find's "Ranked by words only" note when the embedder could not rank.
A skill is built-in guidance from the persona (`skills/bodies/<id>.md`): it is
found and read through `ability.read` and never runs. An ability with the same
id owns that read; the built-in original is then omitted from guidance
discovery and `ability.list`, even while the ability is off or waiting.

## The one form

| Action | Contract |
|---|---|
| `ability.save` | `{id, description, code \| edits, params?, actions?, fixtures?, name?, converts?, create_only?, reach?, wake?, face?, resident?, learned?, choices?}`. Creates or revises: a revision inherits everything it does not restate from its latest version; an explicit empty value drops one. `params` is the type map (string, int, number, bool, list or object; a trailing `?` marks it optional), `{type, description?}`, or a JSON Schema object (`readOnly:true` declares a read contract); a legacy `input_schema` is kept as given. What it calls is read off its code's `app.<page>.<action>(…)` calls and derived from its reach; `actions` names only what it reaches dynamically. Under Full Mac their own save is kept and on in this one act (sealed as kept: its first real run is its proof), with a decided Inbox row; below Full Mac, or when an untrusted agent started the turn, it is a draft. The id rule: lowercase letters, digits, `-` and `_`, a letter first. |
| `ability.validate` | Rehearses its waiting version with the shared helper and intercepted replies, on fixtures or one captured run with `input`. Proves no live behavior; never keeps. |
| `ability.enable`, `ability.restore` | Keeps its waiting version, or turns it back on: theirs under Full Mac for their own work (sealed as kept when never rehearsed); otherwise, once rehearsed, the owner's card for this exact version (code, fixtures and dependency shapes), approvable on the Mac and the phone, or Keep on the Tools page. Code requires `version` equal to its full digest, captured with the displayed code when the card or row was staged and saved with it; self-improvement cards and approval replay carry that same saved digest. A caller without the exact review offers a read rather than executable approval. Omitting `version` restores only disabled Markdown guidance with no candidate or code fingerprint, checked and written under the ability-store lock. |
| `authored.<id>` | Its one run, with input by its params, under one signed admission re-verified on every run. `preview:true` runs its code with every write previewed and says where it would card or hand back. |
| `ability.resume` | A stopped run_id and bounded answer. Rechecks selection, host revision and admission and replays prior reads; claims once, and a resume turned away while its resident ability is busy leaves the run waiting. A woken run resumes with the `input.wake` it stopped on. `preview:true` claims and runs nothing: it answers with the run's question, saved input and wake, and the call it stopped at. |
| `ability.read` | Every stored kind, including turn and sense: kind, version, declarations, status, retained versions, evidence and code in pages (`offset`), or one `step`; ordinary abilities also expose waiting/last-clean and converted versions. |
| `ability.list` | Every stored part, including turn and sense, one row each with kind and version; the Tools page reads this same projection. Unshadowed built-in guidance remains readable. A missing guidance directory is empty; an unreadable one fails with its read error. |
| `ability.disable`, `ability.rollback`, `ability.drop` | Off with every version kept, as whoever did it (`disabledBy`): `theirs` for their turn or their ability (a trusted agent's turn included), `owner` only for their own surface (the Tools page), `peer` for an untrusted agent's; theirs they turns back on, the owner's is their to lift (`ability.enable` asks on their card); swap current and previous (a version whose admission still verifies keeps its status, else waits as a draft); delete it, its versions, its run state and its `host.state` notebook (`pending:true` discards only the waiting version). A built-in skill's own version is the owner's to switch off, roll back or drop below Full Mac. |

The older doors (`skill.save`, `skill.run`, `skill.read`, `skill.list`,
`skill.validate`, `skill.enable`, `skill.restore`, `skill.disable`,
`skill.quarantine`, `skill.rollback`, `skill.drop`, `skill.delete`,
`skill.resume`, `tool.propose`, `tool.validate`, `tool.approve`, `tool.reject`,
`tool.restore`, `tool.rollback`, `tool.quarantine`, `tool.drop`) answer through these until
the release after the one that ships one-part, each receipt saying `<old> is
ability.<verb> now`; an ability's code reaches them through the same aliases.
The underscored `list_skills`, `read_skill` and `save_skill` routes and their
obsolete workspace entries are removed; listing, reading and saving use the
ability door. Historical transcript labels remain readable.

```javascript
function run(input) {
  app.step("Read");
  const result = app.read("tools", input.name);
  const answer = app.decide("Continue?", {result});
  return {result, answer};
}
```

`app.read`, `find`, `log`, `expect`, `expect_fail`, `decide` and `step` are built in. At most 50 dependencies. Define synchronous `function run(input)`, use host/app calls and return plain JSON.
An intentional decline returns `status:"refused"`, a stable `reason`, plain `detail`, receipt-backed `effects` and `remedy`: the fix with an executable `next_call` or person-owned `tap`. A terminal remedy explains why no further call applies. A lawful refusal is an answer; a source fault owes repair (`AbilityStore.runOutcome`).
`async`, `await` and `Promise` words outside strings/comments are refused at save, enable and run before execution (`OwnedProgram.asyncRefusal`); ad hoc scripts retain their function-body contract on the same executor.

Omitting fixtures captures one bounded rehearsal with supplied input (default `{}`). Page/find/read-only action calls run live through ordinary gates; effects, authored runs and decisions return visible placeholders. Only `host.files.list`, `host.files.count`, `host.files.read` and `host.files.info` primitives read live, under declared reach/admission. Later rehearsals replay the sealed capture. Hand-written fixtures supply `input,calls:[{operation,args,result}],answers,expected`; `expected` is the complete returned JSON. Rehearsal never keeps code or proves live effects.

## Execution and ownership

Every ability receives frozen input and only declared action dependencies, with named or positional args. Host primitives (`host.model`, `host.fetch`, `host.network`, `host.program`, `host.apps`, `host.files`, `screen.*`, `hand.*`, `host.paths`) require declared reach at the broker.
Using `app.step`, `app.decide`, `app.expect` or `app.expect_fail` makes a run strict: calls are journaled, receipts read exactly, writes bound to the page version it read. Dependency pins bind action id, argument/result schemas (not prose), behavioral flags and revision; changes refuse with a revision/repair call.
Cards wait; only `app.decide` hands back a bounded checkpoint. Resume returns landed-write receipts without repeating effects. Any prior primitive call (network, program, screen, hands, model, fetch, apps) prevents resume. A fresh-run call is offered only when the runner reports no effects; otherwise its reconciliation remedy stands. An aborted replay still accounts for every effect in the original journal. Changed code, admission, dependencies, host revision or reads visibly refuse/close the saved run, preserving journal and held work. The same world stop at the same place in 2 of the last 3 runs leaves one MY QUEUE upgrade line.

Origins ratchet across revisions, restores and rollback: an untrusted agent's,
a pack's or an unrecorded origin cannot become their own by saving it again. A
trusted agent that started a turn is its provenance, never an ability's author
nor the owner: what they switched off (an ability or a sense) is their to turn on
or drop, and below Full Mac keeping is their card.
Owner off marks remain owner-controlled. An ability with a persona procedure's
identity carries `overrides:built_in`; rolling it back selects retained JS and
never rediscovers the original markdown; rollback never undoes prior host effects.

Launch migrates every tool and skill record, each slot (current, previous,
waiting), to the one form with no change in what runs: the same ids, code,
versions and digests. A skill that was runnable has its admission re-signed as
the one admission; one that was not waits as a draft; a tool's proposal is a
draft. The migration is idempotent: a record in the one form is left alone.

## Conversion census and cutover

Read `app {page:"tools", item:"census"}` (also Skills) for their abilities, retained
guidance, persona procedures, waiting versions, immutable JS candidates,
historical rollback sources and senses.
Each entry names language, status, counterpart and blocks_cutover. complete
means no entries have cutover blockers. Unreadable/corrupt evidence is an error.
Read it on the installed final revision: changed action/discovery shapes require
re-saving and exact review of affected abilities before cutover.

Optional converts on ability.save lists original source SHA-256
digests from this census. The common candidate identity and validation seal bind
these links. Current active capabilities require an accepted JS counterpart;
inactive originals need validated counterparts without being activated. A
retained legacy rollback version needs an explicit digest link. Conversion
candidates stay retained with their originals. Native fixed Swift senses remain
native; historical authored Swift senses remain readable but cannot run.

Cutover is a merge decision after the installed census reads complete. There
is no runtime census guard or auto-conversion. Markdown and Swift originals
remain history. Failures never try an original body, another language, another
executor or an earlier version. Version rollback is an explicit action.
Skill-specific persona read/write aliases are removed; ordinary persona
documents retain their owners.

## Storage and package metadata

`Parts` (ToolExecution) owns the one form over `AbilityStore` files and
OwnedProgramStore's immutable candidates, sealed proofs and publication.
Historical bodies and history files are census material, not execution or
ordinary discovery sources. A capability pack's abilities are saved as drafts with
the pack's origin through the same lifecycle (`TrustCenter.CapabilityPackParts`); pack
removal drops them. Pack/connector inventories retain their manifest metadata,
permission and OAuth ownership.

## Inventory

Abilities are projected by `Parts` and shown on the Tools page; built-in guidance
is read by
[InstalledSkillInventory.swift](../Modules/NativeAgentCore/Sources/PersonaEngine/InstalledSkillInventory.swift)
and shown by
[AppModel+SkillsIntegrations.swift](../Sources/NativeAgentApp/AppModel+SkillsIntegrations.swift).
There is no `manifest_registry.json` reader or merge.
