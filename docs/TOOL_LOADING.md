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
| `app {"action":"<id>","args":{…}}` | Run one registered action. |
| `app {"script":"<JavaScript>"}` | Compose permitted app calls in JavaScriptCore. |
| `app {"actions":[{…},…]}` | Many calls in one, in order, each re-entering the gate chain as its own app call; every one runs and reports itself. An action's single-valued argument given a list (`args.handle:[…]`) runs once per value. |

Home names belong under `item`; registry action IDs belong under `action`.
A home item can change state or send a message immediately. Read its room
first: home items do not support `preview` or `expected_version`.

For actions, `preview:true` reports proposed effects without performing them.
Native preflight checks policy and selected targets; authored preview runs live
reads with writes previewed; resume preview only inspects stopped work.
`expected_version` can guard against a page changing after it was read.
Unknown keys, invalid arguments and stale versions refuse with a remedy. The
door's missing or invalid action-argument refusals include its `args_schema`
and an example call. An unknown action's `nearest` suggestions use the named
page's own actions first; `actions` is the top-level batch argument, while
`{page, item:"actions"}` reads a page's action list. A failed read's default
remedy reads its argument schema and reports that the read changed nothing;
only a change's recovery asks to check what took effect before repeating it.

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

Senses serve `mac.look`, `mac.read`, `files.read`, `web.read` and browser pages through the same door: named things, addresses, verbs and `via sense …` provenance.
[Senses](SENSES.md) owns raw/wrong reads, authoring, repair, corner discovery and turn-gated verbs.

Sense-served file replies identify the material actually captured (`path`,
`bytes`, `version`, `offset`, `returned_bytes`), with `sense_page`, `sense_place`
and `sense_provenance`. `has_more` and `truncated` describe the sense's remaining
page or folded content; `next` carries its continuation when present, not the
raw reader's byte window. Site snapshots retain their proof envelope, put the
original byte count in `source_bytes`, the rendered count in `bytes`, and the
sense continuation in `sense_more`; `has_more` also retains the source's flag.
Native senses retain their original presentation; explicit raw file reads
return the reader's JSON envelope. A failed sense returns `ok:false`,
`status:"failed"`, `error_code`, `error`, `raw` evidence and `remedy`, with:
`raw view · sense <id> v<version> unavailable: <code>; no sense page served`.

## No loading lifecycle

There is no model-facing catalog/load/unload flow, turn-start schema preload
or per-session active-tools store. Installed schema updates apply next turn.

`ToolNameAliases` translates spellings and arguments without granting visibility.
Folded, merged and retired model calls run nothing and receive an equivalent
`app` call where one exists, or direction to `app`. `workspace` maps to home;
catalog queries map to `find`.

Internal executors and saved Trust keys still exist where actions need them.
A folded action re-enters the gated dispatcher under its underlying tool name;
home likewise re-enters its internal executor. Saved blocks and domain gates
continue to apply. Internal names are not additional tools offered to Agent.

Workshop, studio-wander, swarm and bridge execution paths can have their own
declared tool lists. Their internal dispatch contracts do not enlarge the
ordinary chat request. The Tools UI reads the manifest rather than calling a
discovery tool.

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
  on every run. Legacy tool/skill authoring calls delegate to this lifecycle.
  At launch, a changed bundled seed replaces an untouched installed seed,
  keeping the old version as previous; authored edits are preserved. The seed
  catalog's shipped ids and `native-` are reserved for new parts; installed
  shipped abilities can be revised through normal admission. Turn records are
  a separate kind. Future shipped parts use `native-`. See the
  [manifest spec](skill_manifest_spec.md).
- Skills are built-in guidance, found and read through `ability.list` and
  `ability.read`; they never run. Executable authored work is an ability.

`web.search` searches SearXNG, every engine it has, and returns its results or its failure said plainly (no fallback; Doctor names a broken SearXNG); on a Mac without SearXNG the result hands their `browser_search`, the same search in a browser (Chrome through the extension when it is connected, else their own browser), which they runs and reads; a time range travels with either.
Cancellation stops the search.

## Scripts

`AppScriptRunner` binds the door to [`OwnedProgramRunner`](../Modules/NativeAgentCore/Sources/Senses/OwnedProgramRunner.swift) for fresh JavaScriptCore execution with
`app.<action>(args)`, `app.call(id, args)`, `app.read`, `app.find` and `app.log`.
No direct filesystem, network, process or timer API is exposed; every nested app call re-enters the same gate chain.

Every registered action is callable from a script under its ordinary gates.
Each write retains its gates and receipt. A call that raises an
approval card waits for the settled result; a decline throws `AppError` with
reason `declined`, which the code can catch. `card.request` likewise waits for
the person's answer. Full Mac writes need no routine approval card; untrusted
agent turns, macOS privacy resets and irreversible deletes retain their cards.
Home may be read;
use named actions for its items. Secret arguments still require a single action.

`OwnedProgramRunner` owns source, read and action limits and the shared progress clock: a renewable 60-second no-progress window by default, excluding host waits.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.

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
names the provider/model/surface/effort route and its source (live turn or
configured Chat). ProviderRouting's verified model catalog supplies the
native window; Settings → Context window owns the effective history budget,
capped at 60% of native capacity to leave room for persona, tool schemas,
Fluid Context, tool output and the reply. A Custom cap may lower that budget;
effort is routing context, not another window multiplier.

Under Full Mac, Agent can also perform actions otherwise marked the owner's.
Explicit blocks, checked policy, actual macOS grants and connector
authentication still apply. macOS privacy permission resets always require
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

Door corrections and text-tool protocol compensations emit `shim.fired` trace
receipts with their census `id` and source `site`.

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
