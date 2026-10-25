# Tool loading: the contract

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

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
| `app {}` | Home first—where they left off—then a line per page (with what blocks any of its actions) and the action IDs that work on every page; `pages_version` changes when pages, actions or readiness do. A page read lists the page's actions. |
| `app {"page":"home"}` | Their work, arrivals, conversations and places. |
| `app {"item":"<name or ref>","args":{…}}` | Open or act on a name returned by home or one of its rooms. Home arguments are `text`, `fields`, `conversation` and `expects_reply`. |
| `app {"page":"home","find":"<words>"}` | Discover matching pages, actions and skills, just like find alone. |
| `app {"page":"<page>","item":"<optional item>"}` | Read a page or one of that page's items. Page reads return a version and registered actions, including unavailable ones with their blocker. |
| `app {"find":"<words>"}` | Discover matching pages, actions and skills. |
| `app {"action":"<id>","args":{…}}` | Run one registered action. |
| `app {"script":"<JavaScript>"}` | Compose permitted app calls in JavaScriptCore. |
| `app {"actions":[{…},…]}` | Many calls in one, in order, each re-entering the gate chain as its own app call; every one runs and reports itself. An action's single-valued argument given a list (`args.handle:[…]`) runs once per value. |

Home names belong under `item`; registry action IDs belong under `action`.
A home item can change state or send a message immediately. Read its room to
understand it first: home items do not support `preview` or
`expected_version`.

For actions, `preview:true` describes the call without executing it.
`expected_version` can guard against a page changing after it was read.
Unknown keys, invalid arguments and stale versions refuse with a remedy.

Action discovery blends MemoryV2's on-device embeddings with lexical matching.
Information questions without a strong local action match offer a `web.search`
next call and `web.read` for the chosen result URL. Nearby queries state when
the current location is unknown; timezone is not location evidence.
Action vectors are shared per model epoch; negative clauses lower matching
actions. Active authored tools, enabled skills and current on senses share this
ranking, including declared descriptions, operations and input schemas. Skills
and sense readers appear in `actions`, rather than separate ranked lists;
sense verbs require a served thing from the current enabled version.
Find shows five ranked actions with `matched_actions` and `shown_actions`
counts. Known service blockers appear as `availability:"unavailable"` and
`blocker`; page and index lists show the same reason. These are saved setup
verdicts, not network-health checks, and do not change execution admission.

Senses serve `mac.look`, `mac.read`, `files.read`, `web.read` and browser pages through the same door: named things, addresses, verbs and `via sense …` provenance. `args:{raw:true}` reads the original route with raw provenance.
`args:{wrong:true,why:"one sentence"}` reads the place and, if successful, adds repair guidance; `why` is optional. App corners keep their sense view; others use raw. The usual reply is:
“Noted. Fix it now: write how <corner> should read with app sense.make (it runs on this place and shows you the page; keep:true makes it stay).”
For an already-readable file, it explains why rejecting a text view does not grow a file sense. No rejected-view wall or background growth request is recorded.
`sense.make` trials complete `sense.js` against material captured in the same conversation, without rereading. A kept trial returns `status:"kept",place,sense_id,version,page`. Reread that place for its page/provenance/verbs. Revisions need a fresh trial and `keep:true`, with code or `trial_id` and `digest`. A pageless trial is discarded with its failure; a failed sense serves no page. Without a matching sense, the original payload names its actual generic reader or raw-view reason.

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

`find` can discover corners by `app:<bundle id>`, `file:<extension>` or
`site:<host>`. Read one with `page` set to its corner key and `item` set to
the file path or site URL (an app corner needs no item). A served thing's
verbs appear as `sense.<id>.<verb>(address, args?)`; invoke that action with
the thing's address and an optional object of verb arguments. These verbs
run only in their turn. Every existing action the sense requests re-enters
the normal Trust gate; a sense grants no authority and cannot act on a read.

## No loading lifecycle

There is no model-facing catalog/load/unload flow, turn-start schema preload
or per-session active-tools store. An installed schema update is available on
the next turn.

Legacy model-facing tool names run nothing. `ToolNameAliases` returns an
equivalent `app` call where one exists, or directs the caller to `app`.
The former `workspace` interface is home; a catalog query becomes `find`.

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
- The built-in search action appears as `web.search`; `web.read` reads a page.
- Grow executable abilities with `ability.save`; `ability.enable` keeps a draft
  or turns an ability back on. Run it as `authored.<id>` or its declared
  `face.action`; read it with `ability.read`. Full Mac can keep their own save
  immediately; other keeps require rehearsal (`ability.validate`) and the
  owner's exact-version card. The owner's off-switch remains theirs. Code,
  reach, input schema and fixtures share one candidate and admission, checked
  on every run. Legacy tool/skill authoring calls delegate to this lifecycle.
  At launch, a changed bundled seed replaces an untouched installed seed,
  keeping the old version as previous; authored edits are preserved. The seed
  catalog's shipped ids and `native-` are reserved by `ability.save`; future
  shipped parts use `native-`. See the
  [manifest spec](skill_manifest_spec.md).
- Skills are built-in guidance, found and read through `ability.list` and
  `ability.read`; they never run. Executable authored work is an ability.

`web.search` searches SearXNG, every engine it has, and returns its results or its failure said plainly (no fallback; Doctor names a broken SearXNG); on a Mac without SearXNG the result hands their `browser_search`, the same search in a browser (Chrome through the extension when it is connected, else their own browser), which they runs and reads; a time range travels with either.
Cancellation stops the search.

## Scripts

`AppScriptRunner` creates a fresh JavaScriptCore context with
`app.<action>(args)`, `app.call(id, args)`, `app.read`, `app.find` and `app.log`. It exposes no
direct filesystem, network, process or timer API. Every nested app call
re-enters the same gate chain.

Every registered action is callable from a script under its ordinary gates.
Each write retains its gates and receipt. A call that raises an
approval card waits for the settled result; a decline throws `AppError` with
reason `declined`, which the code can catch. `card.request` likewise waits for
the person's answer. Full Mac writes need no routine approval card; untrusted
agent turns, macOS privacy resets and irreversible deletes retain their cards.
Home may be read;
use named actions for its items. Secret arguments still require a single action.

The runner bounds source size, reads, actions and script time; time spent waiting on app calls is not counted.
Its receipt retains completed effects if a later step fails; a script is not
an atomic transaction or a rollback mechanism.

## Authority and receipts

Every tool declares its effect where it is defined: class (read, write, send, destructive), reach (theirs or their), capabilities and an argument policy.
The forms carry the common case: a read is a safe read; a door action is a read when it says `read:`, else a write to app data unless it says otherwise.
The security profile projects that declaration, and argument policy only narrows it; nothing is inferred from a tool's name.

Under Full Mac, Agent can also perform actions otherwise marked the owner's.
Explicit blocks, checked policy, actual macOS grants and connector
authentication still apply. macOS privacy permission resets always require
the owner's approval. A turn an agent the owner has not trusted started with
its message files one card on its first effect, quoting what the agent asked;
the owner's answer covers the rest of that turn. Reading any agent's words
steers nothing. `SecurityCenter` and `PeerTurnEffectPolicy` own those
decisions. Agents enabled in Trust → Connected agents carry the owner's
authority on authenticated turns; ordinary Trust and domain checks still apply.

`tools.contract` records the actual wire schema count and bytes.
`turn.terminal` includes `discoveryToolDispatchCount` for executed
`app {find}` discovery calls. Action receipts distinguish refusal, waiting,
failure and observed effects; a response alone is not proof of an external
outcome.

Door corrections and text-tool protocol compensations emit `shim.fired` trace
receipts with their census `id` and source `site`.

## Source owners

All paths below are under `Modules/NativeAgentCore/Sources/`.

| Owner | Contract |
|---|---|
| `AppToolRuntime/AppActionRegistry.swift` | Actions, arguments, ownership and dependency contracts. |
| `AppToolRuntime/AppToolExecutor+AppDoor.swift` | Home, pages, discovery, previews and action dispatch. |
| `AppToolRuntime/AppScriptRunner.swift` | JavaScript execution and bounds. |
| `ToolRegistry/ToolNameAliases.swift` | Action translations and underlying dispatch identity. |
| `ChatToolRuntime/SwiftToolDispatcher+ToolCatalog.swift` | The single always-on name. |
| `ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` | Request filtering and tool-contract traces. |
| `Research/Research+WebSearch.swift` | Search routing. |

See [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for the surrounding lifecycle.
