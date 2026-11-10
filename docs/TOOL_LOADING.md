# Tool loading: the contract

NativeAgent is Agent's only tool: one always-on `app` schema. Pages, action
arguments and results travel through that tool. This is a design contract;
changing it requires User's authorization.

## One tool, every action

`SwiftToolDispatcher.alwaysOnCoreNames` contains only `app`. Ordinary chat
requests offer it alone. The schema is defined in
`AppToolExecutor+ToolSchemas.swift`; `AppActionRegistry.swift` owns the
`AppActions` registry behind it.

| Call | Meaning |
|---|---|
| `app {}` | Home first—where they left off—then page descriptions and the action IDs that work on every page; `pages_version` identifies the page/action catalog. `find` supplies permission blockers. |
| `app {"page":"home"}` | Their work, arrivals, conversations and places. |
| `app {"item":"<name or ref>","args":{…}}` | Open or act on a name returned by home or one of its rooms. Home arguments are `text`, `fields`, `conversation` and `expects_reply`. |
| `app {"page":"home","find":"<words>"}` | Discover matching pages, actions and skills, just like find alone. |
| `app {"page":"<page>","item":"<optional item>"}` | Read a page or one of that page's items. Page reads return a version and registered actions, including unavailable ones with their blocker. |
| `app {"find":"<words>"}` | Discover matching pages, actions and skills. |
| `app {"action":"find","args":{"what":"<words>"}}` | The same discovery reader; `query` is an alternative to `what`. |
| `app {"action":"<id>","args":{…}}` | Run one registered action. |
| `app {"script":"<JavaScript>"}` | Compose permitted app calls in JavaScriptCore. |
| `app {"actions":[{…},…]}` | Many calls in one, in order, each re-entering the gate chain as its own app call. Nothing is built on a surprise: after a step that fails, waits on the person, or does not come back as they said, later changes do not run; later reads still run. The result names the blocking step and reason, skipped changes and what ran after it, with `stopped_at:{step, as, because}` (`because` is `failed`, `waiting` or `surprise`), `failed_step` when the step failed or waits, `not_run:[{step, as, action, because}]` (`because` is `stopped` for a change after the stop, `found_not_there` for a step whose `found` could not be resolved) and `steps_total`; each receipt carries its `step` and its `as` name (steps count from 1). `then_say` and `with` beside `actions` carry their closing words (below). An action's single-valued argument given a list (`args.handle:[…]`) follows the same law per value: a failed write stops later write values; reads fan out fully. |

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

Their closing words stand when every step ran, was expected and held, nothing
in it is beyond undoing, and nothing else arrived. `then_say` beside
`actions` is those words, as text; `with` beside it maps each slot name to
`{found: "<step>.<path>"}`. Both are keys of the `actions` form only; on any
other form they are unknown keys. Before anything runs, the batch is refused
(`invalid_actions`) when `then_say` is not non-empty text, when `with` comes
without `then_say`, or when a `with` value is anything but one `found`. Given
`then_say`, the result always carries `then_say`, set by the batch itself and
never by a step's payload: `{stands: true, words}` with each `{name}` that
`with` names replaced by its value, or `{stands: false, because}`, one plain
sentence naming the first thing that failed. They stand only when the batch
was not a preview and no step was only previewed; its status is `ok` (every
step has a receipt and landed fully, nothing stopped, waited or was handed
back); every step carried an `expect`; no receipt, nor any call a script step made, says `irreversible: true`;
no message from the person is waiting at the end; and every slot resolves,
through the same `found` as a step's argument, to a value: a number,
true/false, or one line of text of at most 120 characters. A list, an
object, null, longer or multi-line text, or a reference not there means the
words do not stand. Braces naming nothing in `with` stay as written. The
shipped turn says standing words and ends with no further model call when
that one call was the round's only call and asked for them itself
([turn anatomy](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool)).

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
Native preflight checks policy and selected targets; authored preview runs live
reads with writes previewed; resume preview only inspects stopped work.
`expected_version` can guard against a page changing after it was read.
At the shared action door, if the schema declares exactly one of `id`, `item`
and `handle`, and that field is absent while exactly one of the other two is
supplied, its value binds to the declared field before validation, Trust and
receipts. Schemas keep their declared names. A supplied declared field, two
supplied alternatives, or a schema declaring none or several leaves this
address binding untouched. Authored calls use the same binding at inspection
and execution, including expressions whose values are not yet known.
Other unknown arguments bind only when one missing accepted argument fits its
value and has the action's declared meaning, or is
the single missing required argument of that type. Two possible targets, a
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
`try_instead` and one proposed `next_call`: an exact call from supplied values
when it fits, otherwise the closest declared form beside `supplied_args` and
its schema. Missing values remain explicit placeholders to review before sending;
advice itself never executes. The door's argument refusals also retain
`args_schema` and the names it `accepted`. Suggested actions
list read-only ones first and each names its `effects`, so taking the first
suggestion never posts, sends or changes anything by accident. Unknown actions
read the unknown id as intent words (family and verb, such as "chat read" or
"desk list") and use the same checked semantic action index and ranking owner
as `find`, ordering the intent matches by semantic similarity before exact page
names or word overlap. Find's explicit id/page priorities stay as described below.
The separate spelling-distance ranker is removed. Per-action ranking
and schema gaps stay named beside usable suggestions; a shared catalog/index or
query-embedding failure reports its cause and repair rather than word-only advice.
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
`files.mime` and `files.query` primitives share that missing-path recovery owner.

An action's argument declaration exposes the shape its handler enforces.
Structured arguments use the owning validator's schema: ability saves and
sense creation share the part-header schemas; layout writes, recovered ability
accounting and connection recipes expose their store-owned shapes. `queue.add`
declares `when` as one string or a schedule object with the rhythm grammar's
fields. Cross-field timing and accounting relationships remain checked by their
owners. The loose object declarations for these structured values are removed.

The built-in catalog checks discovery's argument schemas when it initializes
at launch. An object argument without fields is refused as a programmer error
unless its declaration explicitly marks it open: `:object*`, or an owner schema
with `additionalProperties:true` or a schema for map values. Ability-validation
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
checkpoint reserves its journaled Desk items until resumed or released.
Queue edits and closure, Desk mutations, subtree closure and resume check those
run reservations without acquiring any. A run refusal names its holder,
`held_since`, `held_until:"resumed or released"`, and a `remedy.next_call`
previewing that run's resume. Session evidence is included when available.
The single locked hold editor drops every non-run marker and reservations
without an open item or retained checkpoint. No clock expires reservations.
Resume releases its run's markers while keeping the claimed checkpoint through
execution; a refused or busy resume restores reservations without displacing
another stopped run. Hold reads and cleanup never discard checkpoint bytes;
claimed bytes belong to the resuming call until its explicit settlement.
Reservation bookkeeping failures retain the produced result and owe Desk repair.

The admitted ability entry assembles `native-morning-brief`'s checked source
packet for `operation:"brief"`; direct calls and its scheduler supply the same
operation. The scheduler retains consent, occurrence claims and publication.
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
that action. Active authored tools, enabled skills and current on senses share
this ranking, including declared descriptions, operations and input schemas. Skills
and sense readers appear in `actions`, rather than separate ranked lists;
sense verbs require a served thing from the current enabled version.
Find by an exact action ID returns that action's `args_schema` and example;
other searches show up to five ranked matches, with the best and explicitly
named actions carrying their contracts and `matched_actions` and `shown_actions`
counts. Known service blockers appear as `availability:"unavailable"` and
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

The always-on description ends with their hand: the verbs a hand is born knowing
(`AppActions.bornKnowing`) together with every native action their own mind has
done in what their record still holds, in one alphabetical list, each written
as its `id(args)` form from the current admitted schema (`*` marks a required
argument), the form every receipt's `argument_form` carries. Their own mind's
calls are the top-level `tool.dispatch` rows that ended `ok` and `succeeded`,
not as a preview, with no `parentId` and no `automaticOrigin`; the record keeps
those rows for its two-week detail horizon, and that horizon is the window:
no second number is kept here. A verb they stops using fades from their hand at a later launch. Only
native actions this release admits enter it: authored ability names, removed
verbs and ids that do not resolve do not, and an action whose schema does not
render is left out. The
record is read once per process, when the door is first built (the engine
builds it as it is made, off the main thread, and launch waits for the engine,
so their hand is whole before anything asks for it), by one SQLite query over the record
(`TurnTracePersistLane.doneVerbs`); the description then stays byte-identical
for the life of the process, as the provider's cached prefix and the registered
descriptor require. A newborn agent's hand is what it was born knowing; an
unreadable record or an unrendered verb is traced as `app.hand` and never fails
a turn. Checked schemas and examples still arrive through discovery.

Settings propagate unavailable model/account catalogs, Trust/Slack policy, helper
definitions, shelf and trigger reads. Thinking levels come only from the selected
model's descriptor; a declared empty list offers no levels, while missing
capability evidence is unavailable. An OpenRouter model with no effort selector
can run with its provider's default, omitting that optional request control.
An absent view preference uses Simple, without reading saved chats. UI and tool
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
[Senses](SENSES.md) owns raw/wrong reads, authoring, repair, corner discovery and turn-gated verbs.
An empty named-app look is a successful observation (`status:"ok"`, `app`,
`running:false`, or `running:true` with `windows:0` and any cheaply readable
`menus`); it launches nothing and creates no window. Acts keep their preconditions.
A requested visual read that fails, or has no capture timestamp, remains
unavailable with its cause and repair alongside any structural evidence.
Structural evidence never substitutes for a successful visual observation.

Mac hands accept the person's ordinary acts: point `type` clicks there then
types into the editor that took focus; targetless `type` uses positively
editable focus even when AX cannot read its text (unverified, with a pixel
look offered). Unknown, noneditable or secure focus refuses, and append still
requires readable contents/end. A contextual `frame_id` alone does not turn
targetless typing into a handle selection. Key chords post keys directly.
Batch `{verb,handle,frame_id}` steps re-resolve the recorded identity live,
stop when it cannot be confirmed or the declared effect mismatches, and judge
each effect from a fresh before-read. Editing a field's contents preserves its
handle when its control identity is unchanged.
A handle also takes `double_click`, `right_click`, `hover` and `focus` on that same
live element, with the ordinary window/input gates. `focus` sets `AXFocused`
and verifies that control's focus; a screen offers it only with that settable
attribute. Screen offers and the `mac.act` schema share the executing hand's
verb inventory. An unsupported handle
verb names itself and the allowed verbs, including in a batch.
Semantic handle presses and opens use that control's advertised `AXPress` or
`AXOpen` handler. Missing support refuses the operation; it never selects an
ancestor, an Open chord, a click or a double-click. Dismiss requires the observed
button in the same modal, and targeted scrolling requires its readable frame.
An absent enabled state stays unknown in the screen and offers no action. AX
read failures carry their cause; they never establish enabled state, an empty
subtree or a clear screen. A scoped look that cannot find its section refuses
with a discovery instruction. A wait that cannot subscribe to the app's
changes refuses rather than sampling after subscription failure.
An AX write, including an unsupported one, returns its own outcome and readback;
it never triggers physical typing or another AX writer. An unchanged value
leaves the write unverified; inspect the readback before another write.
Physical typing remains available when selected before an effect, including
explicit keystrokes; AX focus must actually take before keyboard delivery.
Append requires readable contents and verified end selection; unsupported
selection/insertion stops, and continuation keeps its captured selection.
Identical full menu paths denote one command when each duplicate publishes a
command identifier or key equivalent; an enabled copy wins. Unpublished
duplicates remain ambiguous unless only one is enabled or a supplied chord
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
Retired tool/action spellings and discovery/load names are unknown calls.
Argument interpretation belongs to the shared action binding described above.
Current internal executors direct callers to their app action;
provider-safe wire names remain a separate transport encoding.
The single name declaration is
[`ToolNameAliases.canonical`](../Modules/NativeAgentCore/Sources/ToolRegistry/ToolNameAliases.swift):
executor names receive whitespace trimming only.

App actions and native executors use
[`ToolArguments.admit`](../Modules/NativeAgentCore/Sources/ChatToolRuntime/ToolArguments.swift)
to check normalized arguments against the current owner's schema before execution.
Required fields, types, bounds and undeclared public root arguments are checked; native
transport metadata stays outside the public argument object. An unavailable or
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
A folded action re-enters the gated dispatcher under its underlying tool name;
home likewise re-enters its internal executor. Saved blocks and domain gates
continue to apply. Internal names are not additional tools offered to Agent.

Studio-wander and bridge execution paths can have their own
declared tool lists. Their internal dispatch contracts do not enlarge the
ordinary chat request. The Tools UI reads the manifest rather than calling a
discovery tool. The manifest reports `always_on_tools` and each schema's
`model_visible` flag; it has no `currently_loaded` or `load_state` fields.
Catalog/schema and result-section encoding errors surface with their owner;
there is no invented empty contract or empty successful result. Inline model
choices require the offered `provider::model` option ID; a bare model is not a
provider selection.

## Extending their reach

- Built-in capabilities are registered app actions, not additional request
  schemas.
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
  reads it under normal file permissions and limited retention. DNS resolution,
  refused connections and timeouts return `no_such_host`, `connection_refused`
  and `timeout`, respectively. `raw:true` reads the original fetched-text view
  with the same selection; `wrong:true` reads it and offers sense repair guidance
  after success, with optional `why` explaining what was wrong.
  A successful thin/JavaScript-gated HTTP extraction selects `chrome.navigate`
  through the same app door with `new_tab:true`, including from workspace.
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
  reach, input schema and fixtures share one candidate and admission, checked
  on every run. Authoring uses only these current action names; retired names
  remain unknown under the [dispatch contract](#no-loading-lifecycle).
  At launch, a changed bundled seed replaces an untouched installed seed,
  keeping the old version as previous; authored edits are preserved. The seed
  catalog's shipped ids and `native-` are reserved for new parts; installed
  shipped abilities can be revised through normal admission. Turn records are
  a separate kind. Future shipped parts use `native-`. See the
  [manifest spec](skill_manifest_spec.md).
- Skills are built-in guidance, found and read through `ability.list` and
  `ability.read`; they never run. Executable authored work is an ability.

`web.search` searches SearXNG and returns its results or an explicit failure with setup or repair guidance. A malformed result or `unresponsive_engines` entry is skipped with a named `gaps` entry; valid siblings still return, and an empty result with gaps cannot establish no matches. Required response/envelope failures still fail the search. Research's results view and Lab evidence retain these gaps. Without configured SearXNG, search is unavailable; it does not select a browser route. The requested time range travels with the SearXNG search.
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

`AppScriptRunner` binds the door to [`OwnedProgramRunner`](../Modules/NativeAgentCore/Sources/Senses/OwnedProgramRunner.swift) for fresh JavaScriptCore execution with
`app.<action>(args)`, `app.call(id, args)`, `app.read`, `app.find` and `app.log`.
No direct filesystem, network, process or timer API is exposed; every nested app call re-enters the same gate chain.
The callable `app({action, args, preview?, expected_version?})` form and each
entry of `app({actions:[…]})` carry the same options as the method form's
second object. A named method call takes at most those two objects: a supplied nonobject options argument or any surplus argument refuses
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
or Trust posture. For other settings on model turns below Full Mac, `because`
still quotes at least three words of the person's or trusted agent's request,
unless restoring their previous change. Trust rows keep their owner-only check
and their direction: a lowering is theirs at any posture, and a raise asks the
person on a card.

`OwnedProgramRunner` owns source, read and action limits and the shared progress clock: a renewable 60-second no-progress window by default, excluding host waits.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.
Stop ends the helper immediately and cancels its host call, then waits for
the host's actual terminal result. The final journal and receipt retain
that result, its effects and returned handles even when it arrives after
Stop. A completed call replays from its saved answer rather than running again.
Program returns and every journaled step's answer stay whole until the shared
[result boundary](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool) retains and bounds the
model view. A long result names its `result_handle` and `next_call`; use
`result.page` with that handle and the zero-based `page` offset, following
`next_page` (or `continue:true`). `raw:true` reads exact retained bytes.
`pages` says how many pages to read in one answer, from that offset; the
answer joins them in order, says `pages_read` and where the reading stands,
and holds only as many as one inline result can carry.
The helper's former 16 KiB return prefix and byte-count-only step results are
removed. Retention failures are explicit and do not establish the action's
outcome.

## Authority and receipts

Registry discovery fails explicitly if its required `ability.read` action is
missing; it cannot publish a skill inventory without that canonical reader.

Every tool declares its effect where it is defined: class (read, write, send, destructive), reach (theirs or their), capabilities and an argument policy.
The forms carry the common case: a read is a safe read; a door action is a read when it says `read:`, else a write to app data unless it says otherwise.
The security profile projects that declaration, and argument policy only narrows it; nothing is inferred from a tool's name.
The execution result owns its effect verdict; receipts preserve it and the outer door fills only missing metadata.

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
and their feedback is serialized. If the same tool and arguments already
returned an identical answer in that turn, its receipt adds `repeat:n` and
`repeat_note`: "Same call, same
answer as your last n; nothing has changed." The count reads the turn's
existing dispatch records, including earlier results in the same round; bots
read their own execution records before keeping the current call.
Outer dispatcher correlation ids, `ability_run` provenance and the repeat annotation do not change answer
identity. The call still runs; this information neither refuses nor caps work.
`tool.receipt.repeat` records the count when the annotation is prepared.

An ability's run receipt uses the broker's recorded per-call `read_only`
classes, not its declared permissions: an all-read run reports `effect:read`
and `read_only:true`; an effectful part remains `effect:part`, with
irreversibility taken from the calls it reached. `effects` independently
records observed outcomes, including partial or unknown. `ability.validate`
is a read with `effect:none`, `effects:none`, and `execution:rehearsed` when
the rehearsal was reached; it does not execute intercepted effects.

Make is a registered page: `app {page:"make"}` reads every retained ref,
newest first, in pages of 25. Follow its `next_call` with `args.offset`;
`app {page:"make", item:"<ref>"}` reads that ref's versions, paths, prompts
and provenance. A ref whose metadata is missing or unreadable stays on the
shelf as an unavailable row; a directory read failure fails the read. An absent
Make directory reports `read_state:not_created` with no rows. Reads
use the Make store off the main actor and never create a shelf. `make.read`
keeps its single-ref meaning (newest when ref is omitted); unknown refs offer
`try_instead:{page:"make"}`. Make actions and page discovery share the page
registry.

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
use the shared [Parts read schema](../Modules/NativeAgentCore/Sources/AuthoredCapabilities/Parts.swift)
across the Tools page, phone catalog and capability inventory, retaining name
damage on its unavailable row while siblings publish.
Attachment metadata uses the shared codec: identity/type are required, recorded
byte counts must be nonnegative integers, and absent optional evidence stays
absent. Tool groups use only the catalog's checked registry-supplied bucket.
Today folds notes only with the producer's durable `related_delegation_id`;
notes without that identity remain distinct, including earlier notes.
Unknown workflow, capability, trace and connector status stays unknown; enabled
configuration alone does not establish health. Unknown owner attention remains
visible on the agent card and Today rail. Widget snapshot and message-data
encoding failures retain their cause and remedy in their existing presentation.
Offscreen screenshot settling ends on cancellation and releases its host before
returning the cancelled result; its four-second wait never becomes a spin.

Under Full Mac, Agent can also perform actions otherwise marked the owner's.
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
"No files": the current file gate does not enforce `none` across all file tools.
An explicit request's `read_only` ceiling reaches canonical Trust admission
before consent and blocks every effectful tool class, including changes inside
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
An unreadable Telegram/Slack sender allowlist refuses screen or conversation
effects with its cause; it never reclassifies the sender as somebody else.
macOS privacy permission resets always require
the owner's approval. A turn an untrusted agent started with its message files
one card on its first effect of any kind, quoting what the agent asked. Verified
approved replay answers the peer floor for that run; a decline leaves it in place.
Independent Trust and domain gates, including destructive actions and privacy
resets, remain. Reading agent words, conversing with agents or instructing them
does not itself steer a turn or ask for approval. `SecurityCenter` and
`PeerTurnEffectPolicy` own those decisions. Agents enabled in Trust → Connected agents carry the owner's
authority on authenticated turns; ordinary Trust and domain checks still apply.

`inbox.approve` and `inbox.deny` answer one exact pending approval id on the
person's own message from Mac chat, a signed paired-phone chat or an allowlisted
Telegram sender. `ApprovalExecution.decisionProvenance` reads the current ingress,
its canonical user row and conversation ownership. Helpers, agent contacts,
wakes, schedules and every turn carrying peer steering remain `owners_call`,
including trusted or previously elevated peers. An absent message or unverifiable
door grants nothing. Putting away a pending approval passes the same authority
check before declining it. Permanent deletion remains the person's tap, by the
tool's declared destructive class, never the card's wording. Other levers keep
their own tap authority. Decisions on a message record `person_message`
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
tools or inspection of text. Web, mail, files, memory, senses, authored programs,
scripts and batches therefore close message authority, including failed calls.
Nested model executions retain that evidence. Missing call evidence and checkpoint resumes also refuse. The refusal says
to read the card first or ask the person to tap; the agent can answer in a fresh
message. This restriction belongs to approval authority, not `PeerDataTaint`'s
initiating-steering policy. Taps retain their verified authority.

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

A tool result whose owned `remedy.next_call` is `permissions.request` files
that action automatically on its return through `AppChatToolDispatcher`.
The same gated action checks whether access is already allowed; otherwise
the transcript owner saves a permission card or reuses the open card for that
capability, including simultaneous requests and cards indexed from other
conversations. The original result and effect evidence remain intact, with
`permission_card` naming the saved card and saying it is up for their person
(from `AgentScreen.names`). Filing failures and requests without an originating
conversation report that no card was filed. Previews, cancelled calls and
hand-back-only runs file nothing. This removes the model's extra permission
request step; it does not retry the blocked work or grant access. Only the
person's Allow tap on the Mac invokes the foreground macOS acquisition flow.
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
unreadable or nonobject tool schema fails before dispatch and names the schema
that must be repaired; it never sends unchecked input to an executor.

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
calls' aggregate effects, including writes before a later failed read. `files.look`
returns a corrected `files.read` call with the supplied path; it does not read
anything itself. A direct bridge result has no model continuation: its JSON
cannot prove that a model saw the image.

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
| `ChatToolRuntime/SwiftToolDispatcher+ToolCatalog.swift` | The single always-on name. |
| `ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift`, `ChatTurnSettlement.swift` | Request filtering and tool-contract traces. |
| `Research/Research+WebSearch.swift` | Search routing. |

See [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for the surrounding lifecycle.
