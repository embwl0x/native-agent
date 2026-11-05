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
| `app {"actions":[{…},…]}` | Many calls in one, in order, each re-entering the gate chain as its own app call. Nothing is built on a failure: after a failed or person-waiting step, later changes do not run; later reads still run. The result names the blocking step and reason, skipped changes and reads run after it, with `failed_step`, `not_run:[{index, action}]` and `steps_total` (step indexes start at 1). An action's single-valued argument given a list (`args.handle:[…]`) follows the same law per value: a failed write stops later write values; reads fan out fully. |

Home names belong under `item`; registry action IDs belong under `action`.
A home item can change state or send a message immediately. Read its room
first: home items do not support `preview` or `expected_version`.

For actions, `preview:true` reports proposed effects without performing them.
Native preflight checks policy and selected targets; authored preview runs live
reads with writes previewed; resume preview only inspects stopped work.
`expected_version` can guard against a page changing after it was read.
The door carries what the app knows: a name the action does not take binds to
the one missing argument it fits and the result says so in `argument_notes`
(`took \`ref\` as \`atom_id\``); otherwise unknown keys, invalid arguments and
stale versions refuse with a remedy. The door's missing or invalid
action-argument refusals include its `args_schema`, the names it `accepted`
and an example call. An unknown action's `nearest` suggestions use the named
page's own actions first; `actions` is the top-level batch argument, while
`{page, item:"actions"}` reads a page's action list. A failed read's default
remedy reads its argument schema and reports that the read changed nothing;
only a change's recovery asks to check what took effect before repeating it.

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
Values that truly accept any JSON say why: setting values take
with `additionalProperties:true` or a schema for map values. `params` may carry
the input's JSON Schema; ability-validation input names the schema that determines
their contents. Values that truly accept any JSON say why: setting values take
their kind from `setting.get`, resume answers belong to the stopped decision,
and declared `learned`/`choices` are retained metadata with no enforced shape.

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
policy projection and ranking use one checked inventory. Native parameter-schema
failures stop discovery and admission rather than replacing the schema with
display argument text. The always-on description names fixed hot action IDs;
their checked schemas and examples arrive through discovery.

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
posting. A route-read failure stops the post instead of substituting another
destination; a genuinely absent Telegram door retains the checked conversation's
attention policy.

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
Retired tool/action spellings, discovery/load names and argument aliases are
unknown calls. Current internal executors direct callers to their app action;
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
  `face.action`; read it with `ability.read`. Every ability verb accepts `id`
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

## Scripts

`AppScriptRunner` binds the door to [`OwnedProgramRunner`](../Modules/NativeAgentCore/Sources/Senses/OwnedProgramRunner.swift) for fresh JavaScriptCore execution with
`app.<action>(args)`, `app.call(id, args)`, `app.read`, `app.find` and `app.log`.
No direct filesystem, network, process or timer API is exposed; every nested app call re-enters the same gate chain.
The callable `app({action, args, preview?, expected_version?})` form and each
entry of `app({actions:[…]})` carry the same options as the method form's
second object. `preview:true` on either a batch or an entry dominates; an
entry can add preview to a live batch but cannot disable a batch preview.
An entry's `expected_version` overrides the batch's guard and reaches the
door unchanged.

Every registered action is callable from a script under its ordinary gates.
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
unless restoring their previous change. Trust rows retain their existing
owner-only, Full Mac and lower-only checks.

`OwnedProgramRunner` owns source, read and action limits and the shared progress clock: a renewable 60-second no-progress window by default, excluding host waits.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.
Stop ends the helper immediately and cancels its host call, then waits for
the host's actual terminal result. The final journal and receipt retain
that result, its effects and returned handles even when it arrives after
Stop. A completed call replays from its saved answer rather than running again.

## Authority and receipts

Registry discovery fails explicitly if its required `ability.read` action is
missing; it cannot publish a skill inventory without that canonical reader.

Every tool declares its effect where it is defined: class (read, write, send, destructive), reach (theirs or their), capabilities and an argument policy.
The forms carry the common case: a read is a safe read; a door action is a read when it says `read:`, else a write to app data unless it says otherwise.
The security profile projects that declaration, and argument policy only narrows it; nothing is inferred from a tool's name.
The execution result owns its effect verdict; receipts preserve it and the outer door fills only missing metadata.

An ability's run receipt uses the broker's recorded per-call `read_only`
classes, not its declared permissions: an all-read run reports `effect:read`
and `read_only:true`; an effectful part remains `effect:part`, with
irreversibility taken from the calls it reached. `effects` independently
records observed outcomes, including partial or unknown. `ability.validate`
is a read with `effect:none`, `effects:none`, and `execution:rehearsed` when
the rehearsal was reached; it does not execute intercepted effects.

Tools reads the bounded `ability.list` projection, with `runs`, `last_run_at`,
`count`, `total`, `has_more` and a named `offset` continuation. Full source
reads continue through `ability.read {id,offset}` (or the named Tools item),
rather than reconstructing raw result pages. Retained-result recovery names
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
`auto`, `read_only`, `workspace`, `full` and `none`: absent phone metadata selects
Auto, while an empty, whitespace-only or unknown supplied value is refused before
the turn runs. Phone controls always carry their supplied file-access field,
including a blank value; serialization never turns invalid input into absence.
The phone offers Auto, Read only, Workspace and Full Mac. It does not offer
"No files": the current file gate does not enforce `none` across all file tools.
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

Argument names must match the current action contract. Unknown names refuse
with that contract and an example; a read does not drop them, and dispatch
does not infer a different name from spelling, type, value or a nested shape.
Desk reads return their current row projection directly; they take no
`structured` switch. Home, readback and continuation calls use that same
declared Desk input. Helper references use `id`, and reply lists use `sort`;
`bot.reply` retains its separate `bot_id` expected-owner or latest-reply
selector. Saved navigation references reopen through these current readers.

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
