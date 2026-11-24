# One door: the contract

The agent has one door, `app`: one always-on `app` schema. Through it the agent
reads its home and pages, does actions, finds what it has not used and runs
scripts; pages, action arguments and results travel through that door. Its hand
is the actions it can call straight. Its abilities are JS it wrote or was given;
they join its hand like any other action. The basic actions the app itself
provides (files, shell, the Mac, the Desk and so on) are the app's own actions,
and abilities are built from them. This is a design contract; changing it
requires User's authorization.

Home and item addressing enter the home engine directly through `app`, without
another tool name. Names such as `elsewhere`, `desk.N`, `approval:<id>`, `mail.N`
and agent/helper rooms resolve to their current owners. `<agent>.say` sends
with `args:{text, conversation?, expects_reply?}`. Every selected owner read or
send re-enters its full gates under its real name, with session binding,
own-app refusal and authored-verb routing intact. Arrivals retain their item
pointers. Room action lists name existing `app {action, args}` calls.

## One door, every action

`SwiftToolDispatcher.alwaysOnCoreNames` contains only `app`. Ordinary chat
requests offer it alone. The schema is defined in
`AppToolExecutor+ToolSchemas.swift`; `AppActionRegistry.swift` owns the
`AppActions` registry behind it.

| Call | Meaning |
|---|---|
| `app {}` | Home's current rooms, places and glance-derived sections, then page descriptions and the action IDs that work on every page; `pages_version` identifies the page/action catalog. `find` supplies permission blockers. |
| `app {"page":"home"}` | Their work, arrivals, conversations and places. |
| `app {"item":"<name or ref>","args":{…}}` | Open or act on a name returned by the glance, home or one of its rooms. Message arguments are `text`, optional `conversation` and `expects_reply`. Named fields go in an action's `args`. |
| `app {"page":"home","find":"<words>"}` | Discover matching pages, actions and skills, just like find alone. |
| `app {"page":"<page>","item":"<optional item>"}` | Read a page or one of that page's items. Page reads return content first, then a version and `page_actions` (action ids plus a catalog link). Bound row actions carry their exact calls. |
| `app {"page":"<page>","item":"actions"}` | Read the page's action catalog for signatures, descriptions and blockers, independently of the page content. |
| `app {"find":"<words>"}` | Discover matching pages, actions and skills. |
| `app {"action":"find","args":{"what":"<words>"}}` | The same discovery reader; `query` is an alternative to `what`. |
| `app {"action":"<id>","args":{…}}` | Run one registered action. |
| `app {"script":"<JavaScript>"}` | Compose permitted app calls in JavaScriptCore. |
| `app {"actions":[{…},…]}` | Many calls in one, in order, each re-entering the gate chain as its own app call. Nothing is built on a surprise, and nothing the person asked for waits on a step they did not: a step the gate refuses or files on a card is reported in its place and the steps after it still run, while after a step that fails, waits in place on the person, or does not come back as they said, later changes do not run; later reads still run. The result names the blocking step and reason, skipped changes and what ran after it, with `stopped_at:{step, as, because}` (`because` is `failed`, `waiting` or `surprise`), `failed_step` when the step failed or waits, `not_run:[{step, as, action, because}]` (`because` is `stopped` for a change after the stop, `found_not_there` for a step whose `found` could not be resolved) and `steps_total`; each receipt carries its `step` and its `as` name (steps count from 1). `then_say` and `with` beside `actions` carry their closing words (below); beside a single `action` they make it a batch of one, and a `find` beside `actions` is one more step of it. An action's single-valued argument given a list (`args.handle:[…]`) follows the same law per value: a failed write stops later write values; reads fan out fully. |

`pane.show` takes `view:"steps"`, `"screen"`, `"make"` or `"table"`, with an
optional Make `ref`. `view:"table"` opens the independent table window with its
remembered frame. A closed Work pane does not block it; `pane.hide` leaves it open.

A step in `actions` may carry three keys of its own beside its call. They are
read by the batch and never reach the action.

- `expect` is what must come back, as a shape laid over the step's result.
  Text is met by containing it, whatever the case; a number or true/false by
  equality; `null` by nothing being there (missing, null or empty);
  `{exactly: v}` by the whole value; `{not: shape}` by the shape not being
  met. An object is met field by field and a list by each entry being met by
  some element. A bare string over the whole result is looked for in
  every value the action returned: not in field names, not in the receipt's
  own bookkeeping (`action`, `status`, `execution`, `effect`, `read_only`,
  `irreversible`), and not in a value that is only one of the step's own
  arguments said back; a named field is looked at as it is. A step that ran
  and is not as expected stops the deed as a failure does: the batch is not
  `ok`, `stopped_at.because` is `surprise`, and
  `surprise: [{place, expected, found}]` shows what was actually at each
  place. A step that runs after the stop is not judged, and its receipt says
  so (`expect: "not judged: …"`).
- `{found: "<step>.<path>"}` as an argument value, at any depth, takes that
  value from an earlier step's result before the step runs. The step is its
  1-based number or its `as` name; the path walks object keys and zero-based
  list positions; the step alone gives the whole result. Values pass whole;
  gluing text is a script's work. A reference that cannot be resolved (no
  such earlier step, a step that did not run or failed, a path not there)
  means the step does not run and the deed stops there, its receipt naming
  what was at the deepest place reached.
- `as` names a step for `found`. Names are unique, not empty, not all digits
  and hold no dot, or the whole batch is refused before anything runs.
- `cleanup: true` marks a step that puts back what the deed moved. It runs
  after a stop, through its own gates, unless its own `found` cannot be
  resolved, which is the case when the step that moved the thing never ran.
  What ran after a stop is listed with each cleanup marked as one, and
  each step that did not land said so.

"The result" in both is what a script receives from the same call: the
action's answer without the echoed arguments, guidance and provenance. Their own
arguments are therefore never matched. Under `preview`, a step that was only
described has no result: its `expect` is not judged, which its receipt says,
and a `found` into it cannot be resolved.
Each step's owner reports whether it ran or was previewed; the batch aggregates
those outcomes. A list that fills its requested page counts as complete even when more rows remain. The receipt keeps its continuation and any independent coverage gaps.
A preview beside a completed change never relabels the batch
as `preview`. An empty `find` returns `ok` with `reason: no_match` and does not
stop later changes. Stop before the first step returns `canceled`; Stop after
a step retains `partial` and the individual receipts.

`then_say` holds their closing words as text. `with` maps each slot name to
`{found: "<step>.<path>"}`. Put them beside `actions` and give each step an
`expect`. For a single `action`, put `expect` and `then_say` beside it.
The door runs the same check on step 1, whose result supplies any slots.

At key validation, the door treats null `then_say` or `with` as omitted and
returns `unknown_key` for either remaining key outside a batch. A
`page: "visible"` call without `action` returns `app_window_unavailable` before
key validation if no window is connected. Batch validation returns
`invalid_actions` before any step runs if `then_say` is blank or non-text, or if
`with` comes without `then_say` or lacks the required object shape of one
`found` reference per slot.

When closing words are requested, batch settlement supplies its own `then_say`
as `{stands: true, words}` with each named slot filled, or `{stands: false, because}`
with the first reason the words cannot stand. A batch grouped onto one approval
card returns `needs_person` before settlement, with no `then_say` field.

The words stand when every step ran, landed fully and met its `expect`.
A preview, Stop or hand-back keeps them from standing. So does any receipt or
script call marked `irreversible: true`, or a readable, untainted message from
the person waiting at settlement. The words can stand while a peer's message
waits. Each slot must resolve through `found` to a number, boolean or one line
of text of at most 120 characters.
Braces naming nothing in `with` stay as written. The shipped turn says standing
words and ends with no further model call when the round's only call is the
single action or batch that requested them. See the
[turn anatomy](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool).

A readable, untainted message from the person waiting in this conversation
hands an `actions` batch back before its next step, including a read. The
result has `reason: person_arrival`, remaining entries in `unrun`, `next_step`
(1-based) and all earlier receipts. With no started entries it is `skipped` /
`not_run`, `effects: none`; otherwise it is `partial` unless an earlier receipt
failed. That failure keeps the batch failed, its remedy and failure detail;
failures nested in receipts count too. The hand-back adds the unstarted steps
without erasing that evidence, and earlier effects stay in their receipts.
This arrival is not a failed action or a Stop. Running
calls finish; peers and the agent's own arrivals keep their ordinary boundary
reading. See [turn admission](ANATOMY_OF_A_TURN.md#1-a-surface-admits-the-turn).

Home names belong under `item`; registry action IDs belong under `action`.
A home item can change state or send a message immediately. Read its room
first: home items do not support `preview` or `expected_version`.

`record.read` reads their own committed history through `ExperienceStore`:
`args:{of:"experiences", id_prefix:"happening:person."}` reads presence happenings;
`args:{of:"details", source:"attention", kind:"attention.ignite"}` reads attention
provenance. Experiences also filter by exact `id`, `kind` and `open_only`; details
by exact `subject`, `subject_prefix`, `kind`, `source` and inclusive ISO `since`.
Filters combine, prefixes are literal, and both return newest first with a
positive `limit` (default 20, raised by the caller). `matched_total`, `returned`
and `has_more` make page coverage explicit. Whole detail JSON rows retain their
8 MiB store cap; named row gaps make the result partial. Missing storage fails
without initializing it. [Experience](EXPERIENCE.md#reading-their-own-record) owns
the fields, order and absence semantics. The action declares `read:true`.

`chat.working_memory {text:"…"}` holds one private choice or unspoken plan in
the serving conversation, up to 1200 characters. Empty text explicitly clears
it. They reads it in their live context each turn while it is held; the action's
receipt contains no choice text. The session is transport-bound, never selected
by an argument. Nonempty private text must be a single app action; saved script
source refuses it with that reason. [Turn anatomy](ANATOMY_OF_A_TURN.md#3-nativeagent-prepares-the-working-set-in-parallel)
owns delivery and privacy. The existing scratch file owns the value; no second
working-memory store or action schema on the provider wire is added.

`claude.worklog` reads the writer's real `~/.claude/state/claude-worklog.jsonl`
tail, newest first, off the main actor. Missing, unreadable or malformed source
returns unavailable with its cause and repair path, never a claim that Claude
has done no work. The Agents page and action registry advertise this same read.

`app {page:"chat", item:<conversation id>}` reads saved chat and bridge sessions
and contact conversation ids through their existing owners; it does not select
the person's conversation. The [conversation contract](session-conversations.md)
owns resolution, bounded history and reply eligibility. A failed or incomplete
read part makes the page `partial` while retaining that part's cause; a readable
page shell never labels a failed conversation read `ok`.

`context.expand` opens an exact `history:<id>` across saved conversations,
including agent conversations, without pinning it to the serving conversation.
The shared binder declares `message_id` and `history` as that exact reference:
it supplies `history:` once and records the interpretation. An accompanying
`agent` is context for that reference and is consumed with its own interpretation;
it cannot narrow an exact id. Collisions and unresolved names still refuse.
Context atom pointers remain limited to the serving turn's offered generation.
An unreadable transcript remains a named coverage gap, never proof of absence.

For actions, `preview:true` reports proposed effects without performing them.
Native preflight checks policy and selected targets. An authored preview passes
the ability's own admission. Registered reads run live when their arguments are
read-only and serving them preserves read positions, learning and follow-ups.
Other steps stay previewed. Each reached step reports its execution, and each
live read carries its preview context in the trace. Resume preview only inspects
stopped work. See the [read decisions](skill_manifest_spec.md#preview-read-decisions).
Before a Trust refusal or approval, argument-only preflight validates the declared
schema and returns without executing an authored part or reading its live targets.
Scalar-list calls validate each element without dispatching a batch; this preflight
scope travels with the invocation through dispatcher forwarding. An unresolved
action refuses without opening a corrected read.
`expected_version` can guard against a page changing after it was read.
An `ok` or `partial` content read supplies the same version check and action readback;
the partial page retains its named read failures.
Trust's cloud voice, screen capture and image generation settings require a
readable features policy; an unavailable policy cannot acknowledge a no-op.
A call that names an action and has no `args` object takes every key outside
the `app` door's own, a batch step's and the deed's keys as that action's `args`,
and of the reading keys `page`, `item` and `find` each one the action declares
(an `item` too where the action declares one address word); it is read so once
where the call is admitted (`ToolNameAliases.doorCall`), so gates, receipts and
advice see the canonical `{action, args}`, and a call that has `args` keeps each
other key where it was sent, to be refused rather than merged. With an action
the action is what runs: an `item` left beside it is refused
(`beside_action`), never opened in its place.
At the shared action door, if the schema declares exactly one of `id`, `item`
and `handle`, and that field is absent while exactly one of the other two is
supplied, its value binds to the declared field before validation, Trust and
receipts. Schemas keep their declared names. A supplied declared field, two
supplied alternatives, or a schema declaring none or several leaves this
address binding untouched. Authored calls use the same binding at inspection
and execution, including expressions whose values are not yet known.
Other unknown arguments bind only when one missing accepted argument fits its
value and has the action's declared meaning, or is
the single missing required argument of that type; the declared spellings of one
argument (`find`'s `what|query`) are one target, bound to its first spelling
that fits. Two possible targets, a
collision, null, an undeclared type or any unresolved name leaves the call
unchanged for admission to refuse. The receipt says `understood message as text`;
normal validation, Trust and effect gates still judge the bound call. Apart
from the address binding, open argument maps keep their supplied keys. This
replaces suggestion-only name correction; the address rule is shared rather
than a per-action parsing path.
Argument evidence uses that same binder before redaction: transcript, trace,
approval and receipt projections see canonical names with secret values removed.
An unreadable binding contract withholds the arguments and reports its cause.
Approval replay keeps secret characters only in memory under those same bound names.

Every returned action receipt carries one compact `argument_form` line rendered
from the exact admitted `args_schema`, including its first call in a turn,
refusals and folded calls. Names, required markers, types and enum choices come
from that schema rather than a handwritten action signature.
The shared door stamps the returned receipt after call handling, so an outer-key
refusal before argument admission carries the same form as an executed call.
There is no per-turn copy of the catalog. Script data keeps its original value;
the line and interpretation stay in its receipt. Invalid arguments carry
`try_instead` and one proposed call: an exact call from supplied values
when it fits, as the remedy's `next_call`; otherwise the closest declared form
as `try_instead`'s `proposed_call`, beside `supplied_args` and its schema. Missing values remain
explicit placeholders to review before sending, so a form or a discovery
suggestion is advice and never a remedy the body follows. The door's argument refusals also retain
`args_schema` and the names it `accepted`. When accepted forms differ by
required keys, the refusal names those keys in each form. Suggested actions
list read-only ones first and each names its `effects`, so taking the first
suggestion never posts, sends or changes anything by accident. Unknown actions
read the unknown id as intent words (family and verb, such as "chat read" or
"desk list") and use the same checked semantic action index and ranking owner
as `find`, ordering the intent matches by semantic similarity before exact page
names or word overlap. Find's explicit id/page priorities stay as described below.
The separate spelling-distance ranker is removed. Per-action ranking
and schema gaps stay named beside usable suggestions; a shared catalog/index or
query-embedding failure reports its cause and repair rather than word-only advice.

The door's own judgment of their call is a refusal; an owner's evidence is a
failure. When the door finds their call wrong (route, arguments, version,
ambiguity, a name not found) and nothing changed, it answers with
`ChatToolOutcome.refusedBeforeRunning`: `status:"refused"`, `execution:"not_run"`,
`effects:"none"`, `reason`, `detail`, `decided_by` and
`side_effects:{notes_raised:[], knocks_delivered:0}`, retaining its `remedy` and
`try_instead` without `message`, `error` or `outcome`. An owner's repair remedy,
and any result after partial work or settlement, keeps the failure shape and its
effect evidence, so owed repairs still file.

When a result leaving the door already determines the next call and that call
is a read, their body makes it. At the shared top-level slot return, an owned
`remedy.next_call` of `{tool:"app", input:{…}}` follows only when
the door classifies the whole call read-only (`AppActionBinding.isAppReadOnly`); a thrown
classification follows nothing. A `script` step's and an `actions` step's own
app call follow the same way where that step returns; other parts, other nested
calls, previews and paging (`has_more`) are excluded. Each followed call re-enters the nested
door's full gates, Trust and taint on the same turn, recorded as their body's
call. Following ends when no further read is named or its serialized input
has already been called in this chain, without a chain counter or clock. An identical app read
already made in this turn is not made or copied again: the turn's existing dispatch
records supply a `repeat`/`repeat_note` pointer to its earlier result, retaining its
status and dispatch receipt id when present. This includes earlier automatic follows.
A refused, `effects:"none"` answer to a call that was itself a read becomes the
read's result with `argument_notes` naming first their call, its refusal reason and the call it ran as, and
`resolved` naming the corrected call. Otherwise every original field and its
error verdict stays intact, with the read beside it as `next_result` and the
remedy's `next_call` cleared, since the body already made it. Writes, person decisions and
terminal results stay as returned. The model sees only results that leave a choice.

Inbox cards read through `app {page:"inbox", item:"<card id>"}` with their details
and answers. Today and Inbox share one resolver: exact row ids, bare interaction
ids, `interaction:<id>`, `card:<id>`, bare approval ids and `approval:<id>` reach
the same Inbox card. Today and Desk open that Inbox item directly; a Desk item of
its own keeps its own read.
Inbox's page description exposes this read in `find`.
The page names `approvals`, `approval`, `pending approvals` and `today/approvals`
all resolve to Inbox, whose owner shows the full cards and their answers. Today
continues to show its compact Waiting for you projection.

Cross-field refusals keep their owner's proposed call. `trace.recent` with
payload `fields` and no turn window proposes reading one completed turn; the
refused call reads nothing and the agent can change the count or name a turn.
Stale versions keep their reread remedy. `actions` is the top-level batch argument, while
`{page, item:"actions"}` reads a page's action list. A malformed batch refusal
carries `try_instead`: a single call object is wrapped in a list, and shared
call fields move into its entries when they do not conflict. Supplied values
and outer preview/version options are retained. Unreadable entries, conflicting
fields and invalid batch sizes retain the supplied input beside the door's declared
input schema. A refused entry's advice includes only that entry; earlier calls
keep their receipts. Each proposed entry still passes its own admission and gates.
A missing file path's failure names `nearest_existing_ancestor` and carries a
`remedy.next_call` that runs `files.list` on that verified folder. Missing
parents are walked to the nearest existing directory; an unreadable ancestor
stays an explicit `ancestor_lookup_error`, without an invented path. Other
failed reads use the argument-schema remedy and report that the read changed
nothing; a change's recovery asks to check what took effect before repeating it.
File actions, explicit-path `mac.read` document reads and the parts'
`files.mime`, `files.query` and `files.names` primitives share that missing-path recovery owner.

An action's argument declaration exposes the shape its handler enforces.
Structured arguments use the owning validator's schema: ability saves and
sense creation share the part-header schemas; layout writes, recovered ability
accounting and connection recipes expose their store-owned shapes. `queue.add`
declares `when` as one string or a schedule object with the rhythm grammar's
fields. Cross-field timing and accounting relationships remain checked by their
owners. The loose object declarations for these structured values are removed.

Built-in actions declare their argument names, optionality and shapes at their
domain declaration. A structured record names its first field and any remaining
fields. A closed empty record declares that shape explicitly. An open record
declares its purpose and whether its wire schema omits `additionalProperties`,
sets it to `true`, or specifies a value schema. Authored actions and folds can
take their shapes from the schema their owner supplies. Discovery, binding,
credential redaction and the launch hand use the public action's projection.

The engine holds the native action owners. Each native descriptor supplies its
parameter schema and handler. Dispatch carries the held turn and invocation to
that handler. The desktop courier takes its five schemas from the same
descriptors and applies its request budget and focus checks for that delivery.
The model-facing `app` schema draws the launch forms from `ToolSignature.call`.
The appendix lists changed or added forms, removed or disabled identifiers,
and gaps reported by the owner of each unavailable part of the hand.

Ability-validation
input names the schema that determines its contents. Ability saves take
`params` and `reach`; retired `input_schema` and `permissions` arguments refuse.
`params` accepts description strings and `{type,description?}` declarations,
or an object schema whose `properties` name those parameters. A string keeps
its description; its leading type word (`string`, `number`, `integer`, `boolean`,
`array`/`list`, `object`, also `int`/`bool`), optionally after `optional`, supplies
the type. Words end at whitespace, commas, colons or parentheses. Without a
leading type word it is a string parameter. A `?` on the type or the word
`optional` anywhere in the string marks an optional parameter. For example,
`int`, `int, default 6000` and `string, page to open` are required; `int?`,
`optional int, default 6000`, `int (optional)` and `int, optional` are optional
integers; `optional note to add` is an optional string. Description text does
not supply a runtime default. An object schema's `required` still governs its
properties; a required property with an optional declaration is refused.
Plain type spellings use the same reader; object declarations retain their
explicit `type` without interpreting their description.
Parameter schemas retain constraints such as `items` and `enum` through saving
and run admission; the shared JSON Schema validator checks them. Saving stores
canonical params and the derived input schema; runs use that stored schema.
Correcting an existing declaration requires re-saving with explicit params;
omitted params inherit, and null or an empty map clears them. Values that truly
accept any JSON say why: setting values take their kind from `setting.get`,
resume answers belong to the stopped decision,
and declared `learned`/`choices` are retained metadata with no enforced shape.

Desk writes serialize under the store's lock; changed items retain their
existing changed-state refusals. Conversations, turns, native operations and
ability inputs acquire no holds. Only a stopped part-run with a retained
checkpoint reserves open Desk items identified by its journaled edit receipts.
Those receipts carry stable handles, so a title change preserves the reservation's
target. This includes `queue.add` rescheduling a matched step and `desk.add`
deferring a reused item. Reused items are reserved only when the call edits them.
Reservations last until the run is resumed or released.
Queue edits and closure, Desk mutations, subtree closure and resume check those
run reservations without acquiring any. A run refusal names its holder,
`held_since`, `held_until:"resumed or released"`, and a `remedy.next_call`
previewing that run's resume. Session evidence is included when available.
The single locked hold editor drops every non-run marker and reservations
without an open item or retained checkpoint. No clock expires reservations.
Resume releases its run's markers while keeping the claimed checkpoint through
execution. A pre-execution admission refusal or busy helper returns the same
bytes to waiting, restores eligible reservations without displacing another
stopped run, and keeps the Desk step open. A replay refusal's `resume.held`
lists the reservations actually restored. Invalid checkpoint bytes stay
claimed. An explicit drop of a resume step with a recorded run binding
retires an ownerless claim to `.abandoned` for inspection and releases its
reservations. The archive keeps that binding
for a drop retry. A live claim owns its bytes through settlement.
Reservation bookkeeping failures retain the produced result and owe Desk repair.

The admitted ability entry assembles `native-morning-brief`'s checked source
packet for `operation:"brief"`, including a call bound to their own queue step.
The part returns a proposed card; no brief clock publishes it.
Ability JavaScript exceptions carry the ability, version, engine-reported line,
source expression and cause, with the located message also in `detail` and a
read/repair call. A missing engine line stays explicitly unavailable.

Mac integration pages expose their `trust.mac_integration_<id>` setting
through the shared settings projection, alongside the integration's actions.
This is the same setting shown on `mac_integration`, with the same authority
and write checks.

Action discovery gives exact action IDs first priority. Naming a page by its
registered ID, title or door alias, or naming a registered Mac integration,
puts that page's own actions next, in their declaration order, and that page
first in the matching pages. Names match whole token sequences,
case-insensitively; the longest name at a position
wins ("Mac Integration" names that page, not also "Mac"). For example,
`find:"Notes actions"` starts with `notes.search`, `notes.create`,
`notes.update`, `notes.delete`. Explicit action exclusions still apply.
Remaining matches prioritize semantic evidence above lexical-only matches, then
order by similarity (for every match, not only semantic ones), action-word
overlap and full-text overlap; ties retain inventory order, and each action
appears once. Semantic evidence stands two deviations above the inventory, the
bar a memory clears for their message (10-29: the attention chance bar over ~420
actions sat near 4.5 deviations, so find ranked by shared words). Action vectors are shared per model epoch; `-<action id>` explicitly excludes
that action. Active authored abilities, enabled skills and current on senses share
this ranking, including declared descriptions, operations and input schemas. Skills
and sense readers appear in `actions`, rather than separate ranked lists;
sense verbs require a served thing from the current enabled version.
Find by an exact action ID returns that action's `args_schema` and example;
other searches show up to five ranked matches, with the best and explicitly
named actions carrying their contracts and `matched_actions` and `shown_actions`
counts. A contract for an action they have called also carries `gave_back`: the
shapes its results had the last times they called it (keys and type names, never
values), one per set of argument names they gave, read from their record and
merged over the calls it names in `from_calls`: a key ending in `?` was not
always there, and `a|b` is a type that varied. Known service blockers appear as `availability:"unavailable"` and
`blocker`; page and index lists show the same reason. These are saved setup
verdicts, not network-health checks, and do not change execution admission.

Discovery requires the checked semantic index and embedder; their failures return
the source cause and repair, with no word-only search. Lookup, page actions,
policy projection and ranking use one checked inventory. A selected action's
parameter-schema failure appears in `schema_gaps` with its id and cause; its
healthy siblings still return, including on an exact-id find. `shown_actions`
counts usable rows; a gap is never evidence of absence. That action's admission
still refuses, without manufacturing arguments from display text. Shared
inventory or semantic-index failures still fail the search.

The always-on description ends with their launch hand. **Their hand is what they have done.
An action their own mind completed is in their hand from the next turn on, a native
action and an ability they wrote alike. A turn's hand never changes while the
turn runs.** (User's word, 11-13; until then it was read once per process and
held only native actions.)

Their hand is the verbs a hand is born knowing (`AppActions.bornKnowing`) and
everything their own mind has done in what their record still holds, native and
authored together, alphabetical within the door and the volatile run. Each enters once, resolved
against the current inventory and written under the id they calls it by (an
ability done as `x` and as `authored.x` is one), as its `id(args)` form from
the current admitted schema (`*` marks a required argument), the form every
receipt's `argument_form` carries. Their own mind's deeds are the top-level
`tool.dispatch` rows that ended `ok` and `succeeded`, not as a preview, with no
`parentId` and no `automaticOrigin`, inside a turn holding an admitted model
(`receipt.model`). What the app runs by itself holds no admitted model and never
enters their hand: a runner's ability, a part's wake or carried habit, a person's
tap, a page's own read. One predicate (`TurnTracePersistLane`'s `Deed`) answers
for the record and for each row as it is written. The record keeps those rows
for its two-week detail horizon, and that horizon is the window: no second
number is kept here. A verb they stops using fades from their hand at a later
launch. An id that no longer resolves is not in their hand, and an action whose
schema does not render is left out.

The record is read once per process, when the door is first drawn (the engine
draws it as it is made, off the main thread, and launch waits for the engine,
so their hand is whole before anything asks for it), by one SQLite query
(`TurnTracePersistLane.doneVerbs`); after that each deed joins their done set in
memory as its row is written, never by another query. A turn's catalog is
collected once (`modelSchemas`, which the dispatcher serves) and that turn's
rounds keep it. **Once the door has drawn forms, its tool schema is frozen for
the process. Abilities added, changed, removed or disabled after launch are
listed in the volatile catalog appendix until relaunch. What they can call is
unchanged.** (User's word, 2026-11-22.) Later done verbs also ride the appendix.
Both native-tool and text-marker requests carry current forms and the IDs of
removed or disabled abilities seen in the checked catalog. If the launch
inventory cannot be read, the next collection attempts the first drawing again.
A newborn agent's hand is
what it was born knowing; an unreadable record, an unread inventory or an
unrendered verb is traced as `app.hand` and never fails a turn. Checked schemas
and examples still arrive through discovery.
A failed later-verb inventory read appends `Hand gap (catalog): <same cause>`
beside the last confirmed forms and removal notices in the volatile catalog.

Settings propagate unavailable model/account catalogs, Trust/Slack policy, helper
definitions, shelf and trigger reads. Thinking levels come only from the selected
model's descriptor; a declared empty list offers no levels, while missing
capability evidence is unavailable. An OpenRouter model with no effort selector
can run with its provider's default, omitting that optional request control.
An absent view preference uses Simple, without reading saved chats. UI and action
reads share the checked preference resolver; an existing invalid value stays
unavailable until the person explicitly chooses a supported view.

The phone's settings snapshot isolates each row's value/choice read failure:
that row has no `value`, carries `unavailableReason`, and is read-only; the
phone shows its cause while healthy rows still publish. A failed required
settings-catalog read or cancelled snapshot still fails the whole read.
Setting writes retain their throwing write/readback boundary.

An action that returned keeps its effect receipt when its page-version readback
fails: `readback_failure` names the cause and `readback_note` asks for a page read,
never another write. Page versions hash only successfully serialized bytes.
Chrome field batches require a checked fresh same-tab page between fields and
before submission; a read failure stops later effects while retaining completed
field receipts. Navigation-observer failure leaves the completed act intact and
reports why no fresh page is attached. Sense-watch selection failures report a
capture error rather than presenting the watch as switched off.

`chat.post` reads the current conversation and optional Telegram route before
posting. These are bounded recent reads, independent of total transcript size;
the [conversation contract](session-conversations.md) owns their bounds and
field-level evidence gaps. A route-read failure stops the post instead of
substituting another destination. A Telegram route outside the recent tail is
unknown, not proof that the door is absent; without a proven Telegram route,
the post retains the checked conversation's attention policy.
`chat.post` has no hourly quota: a correction or amendment can reach the person
immediately through the same action, without a guessed correction classifier or
a new argument. The speech owner deduplicates identical content within the
same turn and reconciles uncertain appends at their recorded destination.
Changed content in that turn has a different content key. Trust, exact-call
approval, route checks and the person's notification policy still apply.

Senses serve `mac.look`, `mac.read`, `files.read`, `web.read` and browser pages through the same door: named things, addresses, verbs and `via sense …` provenance.
The unreachable `mac_view`, `mac_look`, `mac_attention` and `mac_wake` schemas
are absent from the Mac tool catalog; their empty internal-name set and
unreachable conversational refusal are removed with them.
An authored part's file mutations compare protected app stores, persona and
their containing folders without letter case, including destinations not yet present.
[Senses](SENSES.md) owns raw/wrong reads, authoring, repair, corner discovery and turn-gated verbs.
An empty named-app look is a successful observation (`status:"ok"`, `app`,
`running:false`, or `running:true` with `windows:0` and any cheaply readable
`menus`); it launches nothing and creates no window. Acts keep their preconditions.
A requested visual read that fails, or has no capture timestamp, remains
unavailable with its cause and repair alongside any structural evidence.
Structural evidence never substitutes for a successful visual observation.

Mac hands accept the person's ordinary acts: point `type` clicks there then
types into the editor that took focus; targetless `type` sends literal text,
including whitespace-only text, to positively editable focus even when AX
cannot read its text (unverified, with a pixel look offered). Unknown,
noneditable or secure focus refuses, and append still requires readable
contents/end. A contextual `frame_id` alone does not turn
targetless typing into a handle selection. Key chords post keys directly.
An unnamed batch binds to the process in front at batch start, or to the app
captured at ingress during a pending takeover. That process can change windows
between steps. Batch `{verb,handle,frame_id}` steps re-resolve the recorded
identity live, stop when it cannot be confirmed or the declared effect
mismatches, and judge each effect from a fresh before-read. Editing a field's
contents preserves its handle when its control identity is unchanged.
A handle also takes `double_click`, `right_click`, `hover` and `focus` on that same
live element, with the ordinary window/input gates and any explicit `app`
constraint. `focus` sets `AXFocused` and verifies that control's focus; a
screen offers it only with that settable
attribute. Screen offers and the `mac.act` schema share the executing hand's
verb inventory. An unsupported handle
verb names itself and the allowed verbs, including in a batch.
Semantic handle presses and opens use that control's advertised `AXPress` or
`AXOpen` handler. Missing support refuses the operation; it never selects an
ancestor, an Open chord, a click or a double-click. Dismiss requires the observed
button in the same modal, and targeted scrolling requires its readable frame.
A scroll by handle or by name takes `direction` (up, down, left or right) and
`scroll_amount` (1–120 wheel lines) in a single act or a batch step. The
default direction is down. Omission and 0 select the default amount and
match the same stopped-batch step. A handle defaults to three lines and a
handle step can also use `to` for direction. When both are given they must
agree. Other handle verbs refuse these scroll options.
An empty address never matches a supplemental target's empty handle.
An absent enabled state stays unknown in the screen and offers no action.
Resolving an AX scroll target skips the enabled-state read. AX marks and
transient menu items preserve the unknown state. Pointer verbs with
unreadable target geometry report `target_geometry_unavailable`, without claiming
the verb is unsupported.
AX read failures carry their cause; they never establish enabled state, an empty
subtree or a clear screen. For lists, tables and outlines, the walk uses the same
visible count for the on-screen summary and the bounded child read. It checks
AXVisibleRows, AXVisibleChildren and AXChildren in that order, advancing on
an unsupported attribute. Menu command and visibility fields share the element's attribute batch.
A scoped look that cannot find its section refuses
with a discovery instruction. A wait that cannot subscribe to the app's
changes refuses rather than sampling after subscription failure.
An AX write, including an unsupported one, returns its own outcome and readback;
it never triggers physical typing or another AX writer. An unchanged value
leaves the write unverified; inspect the readback before another write.
Physical typing remains available when selected before an effect, including
explicit keystrokes; AX focus must actually take before keyboard delivery.
Ordinary AX typing replaces single-line fields and inserts at the current
selection in multiline editors, whether the app is in front or behind.
Only whole-value replacement can be already held; insertion still writes when
the requested text is already present. Foreground AX replacement reports
`method: ax_set_value`; `background_route` describes background delivery only.
Append requires readable contents and verified end selection; unsupported
selection/insertion stops, and continuation keeps its captured selection.
Identical full menu paths denote one command when each duplicate publishes the
same command identifier or key equivalent; an enabled copy wins. A front-only press
that opens a menu for validation settles its cancellation on every exit before
a confirmed command press, retaining the cleanup outcome in `menu_cleanup`.
Unavailable cleanup resolution retains `ax_outcome: unavailable` and its cause;
it does not establish that the captured target is invalid.
Unpublished duplicates remain ambiguous unless only one is enabled or a supplied chord
selects one. Their displayed choices include `[first]`, `[second]` (then
`[third]` through `[tenth]`, `[item 11]`, and so on), accepted as a path suffix
against the current menu order. Use a command's shown key chord when available.
Different full paths remain ambiguous. A started call interrupted by Stop returns
`execution: attempted` and `effects: unknown`, with instructions to check before
repeating it. A joined owner's receipt is retained inside that envelope as more
specific evidence; it does not replace the interruption outcome. Calls cancelled
before starting report `execution: not_run` and `effects: none`.
A bare scroll uses the selected window's main visible content. App-name
resolution prefers an exact bundle filename over display names; duplicate
winning filenames require an exact path. Foreground, Trust, Write and capture
identity checks retain their existing owners.

Relative file paths resolve once from the canonical workspace root. Signed
bundled `docs/` paths select their namespace before resolution; a failure there
returns that cause and never tries a same-named file under another root.

Sense-served file replies identify the material actually captured (`path`,
`bytes`, `version`, `offset`, `returned_bytes`), with `sense_page`, `sense_place`
and `sense_provenance`. `has_more` and `truncated` describe the sense's remaining
page or folded content; `next` carries its continuation when present, not the
raw reader's byte window. Site snapshots retain their proof envelope, put the
original byte count in `source_bytes`, the rendered count in `bytes`, and the
sense continuation in `sense_more`; `has_more` also retains the source's flag.
Each Mac screen page, including a continuation of a captured frame, carries its
address in `sense_place` and the next cursor in `sense_more` when more remains.
Native senses retain their original presentation; explicit raw file reads
return the reader's JSON envelope, without consulting the sense registry. A
failed sense returns as itself, never with a second read behind it: `ok:false`,
`status:"failed"`, `error_code`, `error`, `sense_id`, `sense_version` and
`remedy`, with `sense_provenance`
`sense <id> v<version> unavailable: <code>; no sense page served` (a registry
failure says `sense registry unavailable: <code>`). Basic and Full Mac file
reads return that failure unchanged; `raw:true` is the caller's explicit view.

## No loading lifecycle

There is no model-facing catalog/load/unload flow, turn-start schema preload
or per-session active-tools store. Installed schema updates apply next turn.

`ToolNameAliases` binds current internal executors to app actions and translates
only their declared public/internal argument names, such as `path` to `cwd`.
Retired tool-call names, action spellings and discovery/load names are unknown
calls.
Argument interpretation belongs to the shared action binding described above.
Current internal executors direct callers to their app action;
provider-safe wire names remain a separate transport encoding.
The single name declaration is
[`ToolNameAliases.canonical`](../Modules/NativeAgentCore/Sources/DeskCore/ToolRegistry/ToolNameAliases.swift):
executor names receive whitespace trimming only.

The door checks normalized arguments against the owner's schema before execution.
A malformed call returns an argument refusal. An unreadable schema returns a catalog
failure. Native action descriptors derive that schema from their typed fields.
The invocation holds the decoded arguments for the exact call so preflight, approval
wording and execution read the same value. The action context carries private transport
metadata for the handler. See [DoorArgs.swift](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatToolRuntime/DoorArgs.swift)
and [ActionDescriptor.swift](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatToolRuntime/ActionDescriptor.swift).
Required fields, types, bounds and undeclared public root arguments are checked; native
transport metadata stays outside the public argument object. Resident and helper
model calls and their batch entries lose every `__` root field at their shared
wire boundary, before the host adds session and execution metadata. Action arguments inside `args` retain
their schema-declared vocabulary, including screen paging addresses. An unavailable or
unreadable contract refuses execution. Runtime-supplied public fields are declared
by the receiving schema too: history search's `current_session_id`, and inbox
messages' origin `session_id` and stable `message_id`. Inbox routing supplies
`agent` only to the live-reader executor that uses it to select its saved door;
that executor declares the field. Command inbox executors own their recipient.
`act` declares its named, steps, handle,
image-point, focused-type and bare-scroll forms in its native schema's field
descriptions; its parser checks the required combination for the selected form.
A steps call does not need a top-level verb, and a handle, point, focused type
or bare scroll does not need a named target. Authored wakes receive `input.wake`
instead of call parameters; native actions they reach still check their own args.
Sense-aware reads declare `raw`, `wrong` and `why` in their owning native or
browser schema; folding an action does not add a second input contract. Unbound
folds project that schema, including root form constraints, through the declared
argument-name map. Bound actions expose their own public form and supply their
fixed executor arguments before the native call is admitted.

Contact reads retain unavailable state and its cause; a failed peer read never
becomes an empty directory or an old contact binding. If an effect committed
before a fresh projection failed, its receipt keeps that committed effect and
marks the projection unavailable. A declared reply file that cannot
be read reports that failure with the command evidence and repair; stdout
never stands in for its promised reply.

Internal executors and saved Trust keys still exist where actions need them.
A folded action re-enters the gated dispatcher under its underlying executor
name; home likewise re-enters its internal executor. Saved blocks and domain
gates continue to apply. Internal names are not additional request schemas
offered to the agent.

Studio-wander and bridge execution paths can have their own declared lists
for the provider request's tools field. Their internal dispatch contracts do
not enlarge the ordinary chat request. The Tools UI reads the manifest rather
than calling discovery. The manifest reports `always_on_tools` and each schema's
`model_visible` flag; it has no `currently_loaded` or `load_state` fields.
Catalog/schema and result-section encoding errors surface with their owner;
there is no invented empty contract or empty successful result. Inline model
choices require the offered `provider::model` option ID; a bare model is not a
provider selection.

## Extending their reach

- Built-in capabilities are the app's own actions: registered app actions, not
  additional request schemas.
- The built-in search action appears as `web.search`. `web.read {url,find:"context window"}`
  returns up to eight paragraphs containing every find word (case-insensitively),
  with surrounding paragraphs (`around:0...3`, default 1), in source order.
  Without `find` it returns the whole extracted text (output paging bounds a
  large one); `full:true` with `find` returns the whole text instead of passages.
  `selection` names the returned scope and omitted matches; source `coverage`
  still describes the bounded extraction. Output paging pages only the selected
  result. Every successful fetch retains the extracted text and coverage in a
  local source receipt: `source_receipt.path` names the file, `purpose` explains
  keeping evidence for inspection/citation without refetching, and `read_args`
  reads it under normal file permissions and limited retention. Resolver
  `EAI_NONAME`, refused connections and timeouts return `no_such_host`,
  `connection_refused` and `timeout`, respectively. Other resolver failures
  return `transport_error`; resolver failures retain their EAI code and text.
  Stop releases the fetch immediately even while synchronous DNS is outstanding;
  that lookup may finish later, but its result cannot resume the fetch.
  `raw:true` reads the original fetched-text view
  with the same selection; `wrong:true` reads it and offers sense repair guidance
  after success, with optional `why` explaining what was wrong.
  Research HTTP requests use a private ephemeral session with no shared app
  cookies, cache or credentials. A fetch beginning at a public address refuses
  HTTP and meta-refresh redirects to loopback, unspecified, private, link-local
  or shared addresses, or hosts whose addresses cannot be resolved. Every resolved
  redirect address must be public. Fetches beginning local keep their network reach.
  Admission checks the resolved addresses; URLSession resolves again for its
  connection. Connections are not pinned, so DNS rebinding remains a residual.
  A successful thin/JavaScript-gated HTTP extraction selects `chrome.navigate`
  through the same app door with `new_tab:true`, including from home items.
  That nested navigation owns the settled page readback. The result says
  `used_browser:true`, retains HTTP evidence/receipt under `http_read`, and
  carries Chrome's page or actual blocker. Chrome supplies top-level text only
  when its served text has more non-whitespace characters than the selected HTTP
  text, measuring both exact returned strings (including an authored `sense_page`);
  `text_reader` names `browser` or `http`. Otherwise HTTP text remains at the top,
  with partial status and Chrome's empty/shorter/unmeasured result or failure in
  `browser_read`. `used_browser` describes the attempt. Chrome may use the signed-in
  session; no consent is dismissed. HTTP failures do not select Chrome.
  Rendered `find` starts at the first matching element (`around` is HTTP-only);
  Chrome's [read contract](../Extensions/NativeAgentChrome/README.md) owns
  bounded settlement, overlays, graphics and continuations.
- `maps.search` accepts `near` separately or splits the query at its first
  `near`, `in` or `around` when `near` is absent/empty, for example
  `query:"coffee near Tampa airport"`. `query_split` reports the original text,
  separator, search terms and place; a separate `near` keeps the query intact.
  `maps.route` returns every step in route order, `steps_total` (also
  `total_steps`) and `has_more:false` before ordinary output paging. Each step's
  distance covers its associated path segment, not just its turn/exit manoeuvre.
  Timing uses `MKRoute.expectedTravelTime` under ideal conditions and states
  `traffic:"not_included"`; this route does not request a traffic-aware ETA.
- Grow executable abilities with `ability.save`; `ability.enable` keeps a draft
  or turns an ability back on. Run it as `authored.<id>` or its declared
  `face.action`; read it with `ability.read`. A part whose header declares
  `answers` is run only through the door verbs it answers. Every ability verb accepts `id`
  bare or as `authored.<id>` and receipts name the bare id; unknown ids return
  the nearest three available ids. Resume keeps its required `run_id`, with
  optional `id` binding it to that ability before claiming the run. Full Mac
  can keep their own save immediately; other keeps require rehearsal (`ability.validate`) and the
  owner's exact-version card. The owner's off-switch remains theirs. Code,
  reach, input schema, fixtures and sandboxed ESTree analysis share one candidate and admission, checked
  on every run. Retained admissions keep their identity and their exact body supplies any analysis still needed. Authoring uses only these current action names; retired names
  remain unknown under the [dispatch contract](#no-loading-lifecycle).
  At launch, a changed bundled seed replaces an untouched installed seed,
  keeping the old version as previous; authored edits are preserved. The seed
  path also seals the turn at launch and missing-turn installation. An authored
  turn hears the shipped description and source beside theirs; their own revision
  stays authored, including when they adopts shipped code. Launch logs each
  seed's installed and bundle program digests and ownership without rewriting an
  unchanged seed. Persona, guidance, memory, diary, Desk and settings stay outside it. The seed
  catalog's shipped ids and `native-` are reserved for new parts; installed
  shipped abilities can be revised through normal admission. Turn records are
  a separate kind. Future shipped parts use `native-`. See the
  [manifest spec](skill_manifest_spec.md).
- Skills are built-in guidance, found and read through `ability.list` and
  `ability.read`; they never run. Executable authored work is an ability.

`web.search` searches SearXNG and returns its results (with the engines' direct `answers` and up to three `infoboxes` knowledge panels, each a title, summary and page, when SearXNG has them) or an explicit failure with setup or repair guidance. A malformed result or `unresponsive_engines` entry is skipped with a named `gaps` entry; valid siblings still return, and an empty result with gaps cannot establish no matches. Required response/envelope failures still fail the search. Research's results view and Lab evidence retain these gaps. Without configured SearXNG, search is unavailable; it does not select a browser route. The requested time range travels with the SearXNG search.
Cancellation stops the search.

## Where actions come from

An action is declared in one of two places: natively in `AppActions+Declarations.swift`, or by a part's header `answers`
([manifest spec](skill_manifest_spec.md)). An answered verb keeps its action id, arguments and class; the door registers it on the
part's `face.page`, admits its args against the declared schema, judges it by its declared class with the Mac integration switch of
the part's app reach, and runs the part with `{verb, ...args}`. No native schema, alias or route row remains for it, and a native
declaration of the same id wins until it is deleted. Mail, Notes, Messages, Music and Chrome history are answered by parts
(`native-mail`, `native-notes`, `native-messages`, `music`, `music-library`, `native-chrome-history`) that they can revise; the stem
keeps the AppleScript executor and its per-event write checks, Trust and the cards. A verb declared read runs read-confined. A verb a shipped seed
answers never ranks below that seed's class (send stays send, irreversible stays irreversible), whatever a revision declares. Its Mac
integration switch gates it as the native verb's did: before any card, at preview and at the part's run, with the person's inline grant request;
a verb that reads the person's files with no app switch over them needs admitted Full Mac and is refused without a card.

## Scripts

`AppScriptRunner` binds the door to [`OwnedProgramRunner`](../Modules/NativeAgentCore/Sources/SenseCore/Senses/OwnedProgramRunner.swift) for fresh JavaScriptCore execution with
`app.<action>(args)`, `app.call(id, args)`, `app.read`, `app.find` and `app.log`.
No direct filesystem, network, process or timer API is exposed; every nested app call re-enters the same gate chain.
The callable `app({action, args, preview?, expected_version?})` form and each
entry of `app({actions:[…]})` carry the same options as the method form's
second object, and read the call the door's way: with no `args`, every other
key is the action's argument; beside `args`, another key throws a TypeError.
Saving an ability reads its literal `app({…})` calls by the same keys
(`OwnedProgram.Calls.requestKeys`), so its fit check sees the same arguments. A named method call takes at most those two objects: a supplied nonobject options argument or any surplus argument refuses
before execution. Static source admission rejects the same known malformed shapes; computed values are checked at the live call.
`preview:true` on either a batch or an entry dominates; an
entry can add preview to a live batch but cannot disable a batch preview.
An entry's `expected_version` overrides the batch's guard and reaches the
door unchanged.

Every registered action is callable from a script under its ordinary gates.
Script composition has no effect class of its own: each nested call reaches
admission with its own class and the held request ceiling. Read-only requests
can compose reads; any write, send or destructive step is refused before it runs.
Each write retains its gates and receipt. A call that raises an
approval card waits for the settled result; a decline throws `AppError` with
reason `declined`, which the code can catch. `card.request` likewise waits for
the person's answer. Full Mac writes need no routine approval card; untrusted
agent turns, macOS privacy resets and irreversible deletes retain their cards.
Home may be read;
use named actions for its items. Secret arguments still require a single action.

`setting.set` takes `setting`, `value` and optional `because`. Their mind's
Settings rows say they are theirs to set both ways; they need no quoted request
or Trust posture. For other settings below Full Mac, a turn the person started
runs on its ask; any other model turn's `because` quotes at least three words
of the person's or trusted agent's request, unless restoring their previous
change. A lowering of a Trust row is theirs at any posture.
**Under Full Mac a lever a card can carry is theirs, unless an untrusted voice steers the turn.**
Their call follows its ordinary class and reach, with an agent receipt and undo where its owner supplies one;
the destructive class still asks. This includes settings raises and owner-only rows.
Below Full Mac a raise, a change to an owner-only row (including a raise to Full Mac) and a lever a card can carry
stay the person's: in a turn the person started, every one the
agent calls runs on that turn's ask as the person's act (decided by the person,
their message on the receipt and consent record, no quote and no card), and in
a turn an untrusted agent steered, the agent's own thought started, or a Mac
Ask, Query Memory or Remember intent started, it asks
the person on one card for the exact call. Mac intent arrivals always wait for
their own turn; they cannot join a running turn and inherit its ask.
A card still waiting for a call the person's ask decided is withdrawn as decided,
with their message. Only what
needs the person's own hands (a secret, a sign-in, a code from another device,
a macOS prompt) stays theirs alone. The declaration's `asks == false` class stays unchanged:
system dialogs and privacy answers, the person's own chat words, answering their card, pairing by code,
damaged-policy Safe authorization and resetting identity require the person. Safe allows none of these.

`OwnedProgramRunner` owns source, read and action limits and the shared progress clock: a renewable 60-second no-progress window by default, excluding host waits.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.
Stop ends the helper immediately and cancels its host call, then waits for
the host's actual terminal result. The final journal retains that result, and
the receipt its effects and returned handles, even when it arrives after
Stop. A completed call replays from its saved answer rather than running again.
Program returns stay whole until the shared
[result boundary](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool) retains and bounds the
model view; each journaled step's answer stays in the private journal
([receipts](#authority-and-receipts)). A long result names its `result_handle` and `next_call`; use
`result.page` with that handle and the zero-based `page` offset, following
`next_page` (or `continue:true`). `raw:true` reads exact retained bytes.
`pages` says how many pages to read in one answer, from that offset; the
answer joins them in order, says `pages_read` and where the reading stands,
and holds only as many as one inline result can carry.
The helper's former 16 KiB return prefix is removed, and a program receives
each step's whole answer; its receipt's `calls` measure that answer instead of
carrying it ([receipts](#authority-and-receipts)). Retention failures are explicit and do not establish the action's
outcome.

## Authority and receipts

Each new call starts at `DoorPipeline.dispatch` with its held turn. In order, the
pipeline intersects the request's file ceiling, binds the call and its re-entry
door, opens its dispatch trace, checks peer provenance, and binds helper or
waiting-host work. Trust then judges the exact call, checks any claimed replay
against the spent approval, and decides whether to refuse, ask or run. An
admitted call runs with its own injection capability and verified session.
`executeAdmitted` consumes one `SecurityToolAdmission` holding the tool, input,
surface and turn. It cannot be stored on the invocation or passed on to a nested
call. If argument normalization changes that input, the executor still refuses it.
Outcome accounting and peer labelling finish inside the trace. Workspace tab
cleanup and arrival notices follow it.

Work that resolves or completes an admitted call keeps that admission.
Only the exact call named by a card can
spend its approval. Full Mac still respects authenticated origin, the request
ceiling, explicit blocks, integration switches and macOS grants.

Native actions and tool schemas declare their effects as `CapabilitySet`
members. Trust judges those bits directly. Receipts encode their sorted wire
names, and decoding an unknown effect name fails. A part's JS header declares
its reach through `PartReachGrant`, including exact app and secret grants.
When a native caller limits a part's reach, every declared permission must
match a wire name in the caller's ceiling.

| Entry | Source | Where admission runs |
|---|---|---|
| Batch steps and determined reads | [AppDoorPrograms.swift:201](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppDoorPrograms.swift#L201) | Each step and each follow-up read re-enters. The batch checks steering and Stop between steps. |
| JavaScript app calls | [AppDoorPrograms.swift:39](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppDoorPrograms.swift#L39) | Each call re-enters after the script checks credentials. |
| Authored actions and part calls | [AppScriptRunner.swift:351](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppScriptRunner.swift#L351) | Each call re-enters with its declared reach and originating turn. |
| New host operations | [AppActionEnvironment.swift:195](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppActionEnvironment.swift#L195) | Each primitive re-enters. Its deferred body runs inside that admission. |
| Part thoughts | [PartThoughtTools.swift:56](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/PartThoughtTools.swift#L56) | Each host call re-enters with the original user text and declared actions. |
| Desktop courier | [DesktopAgentConversationRoute.swift:218](../Modules/NativeAgentCore/Sources/BodyRuntime/Agents/DesktopAgentConversationRoute.swift#L218) | The scoped action re-enters after the courier checks its call budget and target. |
| Folds and mail locators | [AppToolExecutor.swift:360](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppToolExecutor.swift#L360) | The folded executor re-enters under its own name. For `mail.read` and `mail.triage`, the call carries the locator resolved from the workspace name. |
| Plural calls | [AppToolExecutor+AppDoor.swift:688](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppToolExecutor+AppDoor.swift#L688) | Expansion stays inside the admitted plural action. Each scalar re-enters as a batch step. |
| Home and page names | [AppToolExecutor+AppDoor.swift:520](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppToolExecutor+AppDoor.swift#L520) | Page and item resolution stays inside the call. When Home selects an owner tool, that tool re-enters. |
| Permission remedies | [AppActionEnvironment.swift:112](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppActionEnvironment.swift#L112) | The permission request re-enters with the originating conversation. |
| Contact messages | [CanonicalToolNameDispatcher.swift:277](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatToolRuntime/CanonicalToolNameDispatcher.swift#L277) | Contact coordination opens or resumes the exchange before the transport call re-enters. A pending send records the card on that exchange so approval resumes the same send. |
| Helper runs | [CanonicalToolNameDispatcher.swift:232](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatToolRuntime/CanonicalToolNameDispatcher.swift#L232) | When the conversation needs to queue a run, its callback continues to Trust with the exact input. Only that queue call spends the grant. |
| Desk titles and numbered aliases | [ActionRuntime.swift:160](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatToolRuntime/ActionRuntime.swift#L160) | Inside the admitted mutation, resolve the handle and check its hold before changing the item. |
| Undo replay | [AppToolExecutor+AppDoor.swift:508](../Modules/NativeAgentCore/Sources/BodyRuntime/AppToolRuntime/AppToolExecutor+AppDoor.swift#L508) | Inside the approved call, check the action and the conversation’s last receipt, then run the inverse with that receipt. |
| Native calls and person taps | [EngineTools.swift:201](../Modules/NativeAgentCore/Sources/BodyRuntime/EngineRuntime/EngineTools.swift#L201) | The native owner enters with its envelope. A tap verifies the sender before supplying the person’s act. |
| Approved replay | [ApprovalSettlement.swift:174](../Modules/NativeAgentCore/Sources/BodyRuntime/ApprovalTransactions/ApprovalSettlement.swift#L174) | Replay re-enters with the card payload. The inbox spends first. The pipeline verifies the exact call and origin. |
| Peer wakes and carried work | [EnginePartWake.swift:512](../Modules/NativeAgentCore/Sources/BodyRuntime/EngineRuntime/EnginePartWake.swift#L512) | Each admitted wake or carried step enters with its steering. A tainted write-capable wake ends before dispatch. |
| Model calls, Stop and receipts | [ChatOrchestration+ToolDispatch.swift:751](../Modules/NativeAgentCore/Sources/BodyRuntime/ChatTurnRuntime/ChatOrchestration+ToolDispatch.swift#L751) | Each proposed call enters the pipeline. A traced call settles its terminal event on the originating bus, including after Stop. |

Registry discovery fails explicitly if its required `ability.read` action is
missing; it cannot publish a skill inventory without that canonical reader.

Every action and internal executor declares its effect where it is defined: class (read, write, send, destructive), reach (theirs or their), capabilities and an argument policy.
The forms carry the common case: a read is a safe read; a door action is a read when it says `read:`, else a write to app data unless it says otherwise.
The security profile projects that declaration, and argument policy only narrows it; nothing is inferred from an action's or executor's name.
The execution result owns its effect verdict; receipts preserve it and the outer door fills only missing metadata.

**A receipt shows only what its call's own output is allowed to show.** A nested
call (a row of a script's, ability's or part-backed action's `calls`) keeps its
identity and outcome, never its raw result: position (`n`, `line`, `step`,
`run`), action (`call`), status, reason, detail and structured remedy, execution
and effects, its classes (`read_only`, `irreversible`, `effect` and the card
fields), returned `ids` and `version`, the result's measured identity
(`result_bytes`, `result_digest`) and `artifacts`: where a write landed (file
destination, shell directory), and a generated image only when the enclosing
output names its path. Raw answers live only in
the run's private replay journal; a stopped strict run's receipt names it by
`journal_ref` and never carries it, so no trace, transcript or experience holds
it. `CallLedger` is the
allowlist: the journal publishes its ledger through it, and a reader of a row
stored before this law reduces it the same way. What a program wants seen of a
call, it returns.

Ability admission, Trust/consent, input and part gates, wake admission and resume
refusals use the same dispatch completion writer as executed calls. Their receipts
keep the owner's reason, checker and remedy; `abilities/state.json` retains that
evidence in `lastRun` with the refused attempt's own time. Runner provenance prevents
outer app receipts from counting the same run again. An unavailable identity stays
unattributed, with its accounting failure visible, rather than selecting another
ability or version. Home's refused-run rows read this owner directly.

A receipt with `effects:none` and its own failure evidence (`error`,
`error_code`, `ok:false`, `success:false`, `failed:true`, or other evidence the
shared classifier reads as failed) gains `status:failed` when the owner has
not named `status` or `state`. An owner-named status is preserved, including
`needs_person`, `already_applied`, `already_discarded`, running and waiting
states. Effects alone and missing terminal evidence establish neither failure
nor success.

Every tool result delivered to the turn's model passes the same repeat
annotation owner, including standing-bot turns before their records are kept
and their feedback is serialized. If the same call, by name and arguments,
already returned an identical answer in that turn, its receipt adds `repeat:n`
and `repeat_note`: "Same call, same
answer as your last n; nothing has changed." The count reads the turn's
existing dispatch records, including earlier results in the same round; bots
read their own execution records before keeping the current call.
Outer dispatcher correlation ids, `ability_run` provenance and the repeat annotation do not change answer
identity. An explicitly requested call still runs; this information neither refuses nor caps work.
An automatic determined-read follow instead points to its earlier result as described above.
`tool.receipt.repeat` records the count when the annotation is prepared.

An ability's run receipt uses the broker's recorded per-call `read_only`
classes, not its declared permissions: an all-read run reports `effect:read`
and `read_only:true`; an effectful part remains `effect:part`, with
irreversibility taken from the calls it reached. `effects` independently
records observed outcomes, including partial or unknown. `ability.validate`
is a read with `effect:none`, `effects:none`, and `execution:rehearsed` when
the rehearsal was reached; it does not execute intercepted effects.

Make is a registered page: `app {page:"make"}` reads every retained piece ref,
newest first, in pages of 25. Follow its `next_call` with `args.offset`;
`app {page:"make", item:"<ref>"}` reads that ref's versions, paths, prompts
and provenance. A ref whose metadata is missing or unreadable stays on the
shelf as an unavailable row; a directory read failure fails the read. An absent
Make directory reports `read_state:not_created` with no rows. Reads
use the Make store off the main actor and never create a shelf. `make.read`
keeps its single-ref meaning (newest when ref is omitted); unknown refs offer
`try_instead:{page:"make"}`. Make actions and page discovery share the page
registry.
The Desk's standing `table` ref is absent from Make's shelf and `page:make`.
`make.read {ref:"table"}` still reads its versions. The Desk reads the standing
board by ref and joins piece cards from the Make shelf's metadata. A picture
shows an empty board before the table's first change.

The Desk's standing board has three actions: `table.put {id?, type?, x?, y?,
w?, h?, text?, color?, kind?, size?, from?, to?, fromSide?, toSide?, label?, points?, width?, item?,
piece?}` adds an element or changes only its named fields; `table.cross {id}`
closes an item card through `desk.close` or toggles a mark's crossing;
`table.remove {id}` removes the element and its arrows. Changes return their
version or `no_change` for an unchanged put on an existing element.
**THE STORE ANSWERS; NO HAND GUESSES.**
`table.put` with `type` adds a whole element under a supplied free `id` or mints `e` followed by twelve lowercase hexadecimal digits.
An occupied supplied id is `exists`.
Without `type`, it changes only supplied fields of an existing `id`: absent is `not_found`, omitted is `invalid_input`.
Refusals write nothing; an edit never recreates an element or changes its type. No shape or position defaults are invented.
A typeless put carrying `item` or `piece` is `invalid_input`, with nothing written: the pointer is set only at creation.
A new shape or container requires `x`, `y`, `w`, `h`; text requires `x`, `y`; an arrow requires `from`, `to`;
a stroke requires `x`, `y` and `points` (the points run from x,y). Missing fields are named in an `invalid_input` refusal, with nothing written.
An id must contain 1–40 letters, digits or hyphens, otherwise `invalid_input`. Cross and remove also refuse an id absent from
the table as `not_found`, naming the id with `effects:none`.
Item and piece cards keep type `shape`, place, pointer and signatures, with no copied title or state.
Arrow sides are left, right, top or bottom. Item cards store
no new `crossed` field through these actions; an existing contact mark is retained
as described in [Desk](DESK.md). Crossing here comes from the item's state.
Piece cards and marks retain their own crossing. Unknown fields and invalid pointers are refused;
text is bounded at 2,000 characters. `make.add {ref:"table"}` is refused and
names these actions. [The Desk contract](DESK.md) owns the standing table.
The Desk tab and its table window mount the table controls. Other pages draw a read-only table.
In the window, the table changes from its toolbar: item or piece card, Note, Pen, Cross off, Remove and Open for a selected piece card.
Toolbar writes call the door as a person's tap and draw when read. Hand gestures call that same door at the end:
absolute `table.put` fields addressed by id for moving, sizing, writing, adding, drawing and joining, or `table.remove {id}` for Delete.
Pen sends one stroke with x, y and relative numeric point pairs; the [Desk contract](DESK.md) owns the bounds and read-time `around` facts.
New cards, arrows and strokes carry hand-minted ids; item and piece cards cannot be written on by hand.
A section carries each contained element through an independent put. The picture is the last read with held fields overlaid;
each hold drops on a read at or past its returned version, immediately for a no-change put, or immediately on refusal or failure.
The newest gesture on an element waits for that element's call to return; different elements proceed independently.
Reply or failure words appear on the board, including an ordinary `not_found` after removal by another hand.
The table queues no documents and does no rebasing. Clicking selects, and pan, zoom and Fit work.
The agent places and moves elements with `table.put`.

Tools reads the bounded `ability.list` projection, with `run_counts`, `last_run_at`,
`count`, `total`, `has_more` and a named `offset` continuation. Full source
reads continue through `ability.read {id,offset}` (or the named Tools item),
rather than reconstructing raw result pages. List and detail share
`run_counts:{all_versions,current_version}`: lifetime `useCount` and the
selected file identity's recorded count respectively. `learned.use.scope`
is `current_version`; its `run_totals` and `rounds_per_use` cover that scope.
The ambiguous list `runs` field is removed. Retained-result recovery names
searched, matching, displayed and remaining section counts separately;
oversized structured sections expand through their named child paths.
For a large retained action batch, the first answer includes a short row per returned
step with its reported outcome, available findings, and the section page where
its receipt starts. Read that page with the same result handle for more detail.

`agent.introspect` separates `identity` (bundle id, build, data root) from
`launch` (process/instance ids that change on relaunch). Its `context_window`
names the provider/model/surface/effort route from the admitted turn only.
Outside an admitted turn its route is unavailable; it never infers a provider
from model spelling. ProviderRouting's verified model catalog supplies the
native window. That model-default window is never reduced by a custom cap or
an early compaction percentage. The composer ring reports the last matching
provider request's observed input; missing usage/window measurements remain
unavailable. The [conversation context contract](conversation-context-history.md)
owns verbatim replay, stateless whole-turn checkpoints in half-budget jumps at
the bound, exact sent-context accounting and retained tool-result pointers.
There is no compact command or compaction setting. Effort is routing context,
not a window multiplier.

Presentation preserves each source's availability. Quiet pages name a failed or
not-yet-read source with a repair issue instead of current counts. Complete
transcript, activity and capability reads refuse rejected records; part names
use the shared [Parts read schema](../Modules/NativeAgentCore/Sources/SenseCore/AuthoredCapabilities/Parts.swift)
across the Tools page, phone catalog and capability inventory, retaining name
damage on its unavailable row while siblings publish.
Attachment metadata uses the shared codec: identity/type are required, recorded
byte counts must be nonnegative integers, and absent optional evidence stays
absent. Tool groups use only the catalog's checked registry-supplied bucket.
Today folds notes only with the producer's durable `related_delegation_id`;
notes without that identity remain distinct, including earlier notes.
Unknown workflow, capability, trace and connector status stays unknown; enabled
configuration alone does not establish health. Connector rows use measured health
for Connected or Ready; set-up routes with missing or unknown health say
Set up · Not checked. Connector actions without a registry record retain absent
health, auth and enabled values; Capabilities draws absent health as Not set up.
The Latest check row and its Check trust action name the same trust evaluation.
Unknown owner attention remains visible on the agent card and Today rail.
Widget snapshot and message-data
encoding failures retain their cause and remedy in their existing presentation.
Offscreen screenshot settling ends on cancellation and releases its host before
returning the cancelled result; its four-second wait never becomes a spin.

Under Full Mac, the agent can also perform actions otherwise marked the owner's.
Explicit blocks, checked policy, actual macOS grants and connector
authentication still apply. An unavailable Trust policy returns its actual
read failure and repair; it never becomes an ordinary denied-policy result.
The canonical checked policy reader validates closed posture values and every
consumed authority field before normalization. Current postures are `strict`,
`balanced` and `full_mac_os`; workspace grants live in
`filePolicy.workspaceRoots`. Missing policy or a validated empty object uses
fresh-install defaults; unreadable or malformed policy never does. File mutation
reach uses only the operation's declared `path` and, for copy/move,
`destination`, resolved by execution's file resolver; file contents grant no reach.
Signed phone turns read the current `macControlPolicy.remote_from_ios_allowed`
grant, retaining transport verification. Phone and Mac share file-access modes
`auto`, `read_only`, `workspace`, `full` and `none`: phone metadata must include
`fileAccess`; a missing, empty, whitespace-only or unknown value is refused before
the turn runs. Phone controls always carry their supplied file-access field,
including a blank value; serialization never turns invalid input into absence.
The phone offers Auto, Read only, Workspace and Full Mac. It does not offer
"No files": the current file gate does not enforce `none` across all file actions.
An explicit request's `read_only` ceiling reaches canonical Trust admission
before consent and blocks every effectful action class, including changes inside
the agent's own workspace or data, regardless of broader saved permission or
approved replay. Folded actions and authored calls re-enter that same admission.
The request binds before expansion and conversation coordination, so a refused
send cannot leave queued work. Nested dispatch, replay and resume intersect
ceilings; `none` and `read_only` can hold together without a new wire mode.
File mutation also reads the ceiling directly from the turn before any write;
Full Mac connector reach and a part's own-data grant cannot widen it. The request
issuer must resubmit with write access to change that ceiling.
The request-file-access refusal producer supplies its remedy: `none` names the
read grant, `read_only` names a mode permitting changes, and an invalid mode names
the accepted values. Each remedy points to the originating request's `fileAccess`
setting (phone: Chat > File access) and requires a new request; every carried
ceiling must permit the operation. Dispatch, pre-approval and Trust's answer retain
this same remedy rather than replacing it with generic write-access advice.
An allowlisted Telegram group or Slack channel admits messages; only a sender on
the user allowlist is a trusted origin. Telegram private chats also prove the
sender when an allowlisted chat id equals the sender's user id, or when no user
id is supplied and the chat id itself is on the user allowlist.
Telegram turn controls, acting bot commands and model or approval buttons require
a user-allowlisted sender or an admitted private chat whose id equals its sender's
user id. A group chat's admission alone grants no control; refusal names the
owner's control without acting. Message admission remains chat-or-user allowlisted.
An unreadable Telegram/Slack sender allowlist refuses screen or conversation
effects with its cause; it never reclassifies the sender as somebody else.
macOS privacy permission resets always require
the owner's approval. An untrusted agent's effect card quotes its ask: **Just this**
admits that call; **For this task** elevates its carried peers for the run. Approve
on a door without the second button means Just this; a decline leaves the floor in place.
Independent Trust and domain gates, including destructive actions and privacy
resets, remain. Reading agent words, conversing with agents or instructing them
does not itself steer a turn or ask for approval. `SecurityCenter` and
`PeerTurnEffectPolicy` own those decisions. Agents enabled in Trust → Connected agents carry the owner's
authority on authenticated turns. Ability writes recheck each peer's grant in the turn's data root
unless the person explicitly elevated that peer for the task. Ordinary Trust and domain checks still apply.

`inbox.approve` and `inbox.deny` answer one exact pending approval id on the
person's own message from Mac chat, a signed paired-phone chat or an allowlisted
Telegram sender. `ApprovalExecution.decisionProvenance` reads the current ingress,
its canonical user row and conversation ownership. Helpers, agent contacts,
wakes, schedules and every turn carrying peer steering remain `owners_call`,
including trusted or previously elevated peers. An absent message or unverifiable
door grants nothing. Putting away a pending approval passes the same authority
check before declining it. Permanent deletion remains the person's tap, by the
action's declared destructive class, never the card's wording.
Under Full Mac a lever a card can carry is theirs, unless an untrusted voice steers the turn;
levers no card can carry keep their own tap authority. Decisions on a message record `person_message`
provenance, its session, message id and verifying door; cards and retained history
name the agent deciding on that message rather than presenting a tap.

The named row must be the exact authorizing message. A message joining a running
turn keeps its own run and door while the reading turn retains its opener's.
`ChatTurnSteering` records that join before handing the message to the turn;
message decisions then refuse because the authorizing message cannot be
established. Missing or mismatched open-turn evidence refuses the same way.
The agent never substitutes the opener or the latest row for a joined message.
Read the card first or ask the person to tap; a fresh message after the running
turn ends can be answered under its own identity.

Message decisions require a fresh turn that has started only Inbox reads or
approval-decision calls. The shared canonical dispatch entry marks every other
call in shared call evidence held on `Turn` before execution, without a list of outside
actions or inspection of text. Web, mail, files, memory, senses, authored programs,
scripts and batches therefore close message authority, including failed calls.
Nested model executions retain that evidence. Missing call evidence and checkpoint resumes also refuse. The refusal says
to read the card first or ask the person to tap; the agent can answer in a fresh
message. This restriction belongs to approval authority, not `PeerDataTaint`'s
initiating-steering policy, which reads grants in the data root held by the turn. Taps retain their verified authority.

Outside text from an earlier turn can still be in the agent's context. A message
decision is the agent's judgment on the person's authenticated message, not proof
of the person's intent or proof that outside text had no influence.

`tools.contract` records the actual wire schema count and bytes.
`turn.terminal` includes `discoveryToolDispatchCount` for executed
`app {find}` discovery calls. Action receipts distinguish refusal, waiting,
failure and observed effects; a response alone is not proof of an external
outcome.

Agent-answered grant cards carry the grant owners' completed targets and
redacted write failures into the existing card settlement. A failed write
keeps its cause and any completed grant writes on the receipt; successful
setup still requires the resolver's authority readback before success.

A call result whose owned `remedy.next_call` is `permissions.request` files
that action automatically when `AppActionEnvironment.filePermissionRemedy` receives the result.
The same gated action checks whether access is already allowed; otherwise
the transcript owner saves a permission card or reuses the open card for that
capability, including simultaneous requests and cards indexed from other
conversations. The original result and effect evidence remain intact, with
`permission_card` naming the saved card and saying it is up for their person
(from `AgentScreen.names`). Filing failures and requests without an originating
conversation report that no card was filed. Previews, cancelled calls and
hand-back-only runs file nothing. This removes the model's extra permission
request step; it does not retry the blocked work or grant access. The person's
Allow tap on the Mac, or the agent's ask on the person's own word, invokes the
foreground macOS acquisition flow; macOS still asks the person.
Answering the card continues its originating conversation without replaying
the blocked call.

Door corrections and text-tool protocol compensations emit `shim.fired` trace
receipts with their census `id` and source `site`.

### Their calls land

Argument names bind against the current action contract as described above,
including its single address field. Other unknown names need one declared
meaning or one missing required argument of the same type; unresolved names
refuse with that contract, `try_instead` and a proposed `next_call`.
Advice requiring a changed call points to discovery
when its proposed arguments would repeat the failed call. A read never drops
an unresolved argument.
Desk reads return their current row projection directly; they take no
`structured` switch. Home, readback and continuation calls use that same
declared Desk input. Helper references use `id`, and reply lists use `sort`;
`bot.reply` retains its separate `bot_id` expected-owner or latest-reply
selector. Saved navigation references reopen through these current readers.
When a helper selector instead names a saved agent contact, the refusal points
to `agent.read` with that contact's saved address. For `bot.ask`, it instead
proposes `agent.message` with that address and the original question as `text`.
The refusal starts no peer work.

Declared scalar forms normalize exactly: numbers to strings, numeric strings
to numbers (integers only when exact), `"true"`/`"false"` to booleans, and one
scalar to a declared scalar array. This is protocol normalization, without
receipt notes, like `1.0` to integer `1`; invalid values still refuse. A present
unreadable or nonobject action or executor schema fails before dispatch and
names the schema that must be repaired; it never sends unchecked input to an
executor.

`queue.add` and `queue.update` accept a plain local date/time for `when`, with
an optional weekday (for example `Sun Nov 1 at 06:00`), through the system date
reader. Accepted moments are stored as absolute ISO timestamps. A refusal quotes
the supplied words and the system's reading; incomplete matches, ranges and
repeated local clock times need one explicit instant, with an ISO offset for a
repeated time. The [intention contract](INTENTIONS.md) owns the timing grammar.

`files.read {path}` shows a local image's pixels through the existing call-local
image attachment, with normal file admission and image bounds. Without an image
slot, including inside an ability or script, it instead succeeds with verified
source dimensions, byte size and encoded type, `image_pixels:false`, and a note
to read the pixels with `files.read` from a turn. This verifies the image bytes;
it does not claim anyone saw pixels. Empty, oversized and unreadable images
still fail. A program's receipt retains its own execution verdict and all its
calls' aggregate effects, including writes before a later failed read. A direct
bridge result has no model continuation, so its JSON cannot prove that a model
saw the image.

`queue.add`'s `until?:any` reads moment strings, including relative moments, and
`{at:"<ISO time>"}` objects as times, alongside completion words and `standing`.
Malformed objects refuse rather than disappear into the default ending.

## Source owners

All paths below are under `Modules/NativeAgentCore/Sources/`.

| Owner | Contract |
|---|---|
| `AppToolRuntime/AppActionRegistry.swift`, `AppAction.swift`, `AppActions+*.swift` | Registry; action values; declarations, contracts, discovery, ranking and kept-part acknowledgement. |
| `AppToolRuntime/AppToolExecutor+AppDoor.swift`, `AppDoorReading.swift`, `AppDoorPrograms.swift`, `AppDoorActions.swift` | One door interprets home, pages, previews, scripts, batches and action dispatch. |
| `AppToolRuntime/AppScriptRunner.swift` | Door binding to the shared executor. |
| `ToolRegistry/ToolNameAliases.swift` | Action translations and underlying dispatch identity. |
| `ChatToolRuntime/ActionRuntime+Catalog.swift` | The single always-on name. |
| `ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift`, `ChatTurnSettlement.swift` | Request filtering and `tools.contract` traces. |
| `Research/Research+WebSearch.swift` | Search routing. |

See [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for the surrounding lifecycle.
