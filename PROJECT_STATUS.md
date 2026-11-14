# NativeAgent Project Status

Source status: 2026-10-20. This describes the checkout, not a release or
installed-app verification. Release history lives in [CHANGELOG.md](CHANGELOG.md)
and [release notes](docs/release-notes/).

## What it is

One brain, many doors. `NativeAgent.app` hosts the Swift runtime in-process.
The core's `EngineRuntime` composes it and `ChatTurnRuntime` owns resident turn
execution. StandingBots owns helpers' model/tool loops over their own transcripts.
Mac, iPhone, Telegram, Slack and local agent bridges reach that
shared engine.

The Mac has Simple, Advanced and Agent views. Simple presents chat, the
places Chat, Desk, the agent's own and Control, and folded contacts and
helpers; Advanced adds Diagnostics, the conversation list and the Work pane;
Agent draws their Home face with row actions and keeps the other rooms as
read-only text.

## Where things stand

| Area | Current source contract |
|---|---|
| Releases | Mac v0.6.9 is the current public release as of 2026-10-20 (Developer ID signed, notarized, Sparkle). The iPhone companion ships through TestFlight. The [Releases page](https://github.com/embwl0x/native-agent/releases) is authoritative for what has shipped. |
| Agent interface | The agent's one door, `app`, is always on. `app {}` is home; `page`, `item`, `find`, `action` and JavaScriptCore `script` reach capabilities through `AppActionRegistry`. |
| Discovery | Pages and actions arrive in tool results. Argument binding and refused-call advice follow [the one-door contract](docs/ONE_DOOR.md). |
| macOS grants | Owned permission remedies automatically file `permissions.request` through the composed tool return; already-allowed access skips the card and an open card for the capability is reused. Results retain the original outcome and name the card for the person. Only the person's foreground Allow tap invokes macOS acquisition. Card and Settings acquisition await activation or cancellation, release observation on every exit, and request no grant while inactive or cancelled; Settings retains acquisition problems as failures. See [the one-door contract](docs/ONE_DOOR.md). |
| Growth and MCP | Authored executable tools and legacy executable skills migrated into `data/abilities/` alongside senses and turns: one current file, optional previous/proposed files and independent run state, with exact admission/proof and explicit lifecycle actions. Built-in skill guidance remains in the persona's `skills/bodies/`, read and never run; the [manifest spec](docs/skill_manifest_spec.md) owns that distinction. An MCP server they wants is an ability they grows; NativeAgent keeps no MCP client. |
| Web search | `web.search` uses the configured SearXNG endpoint; without one it returns `searxng_not_configured`. Discovery/selection is explicit Research setup, never search or Doctor recovery through another endpoint. Checked discovery distinguishes refused listeners from failed probes/inventory: a candidate's failure is a named gap while other candidates proceed, including when a reachable endpoint is selected; required configuration/inventory failures stop discovery. Responses validate current result fields and engine-failure evidence before admission: malformed result and engine-failure rows become named gaps while valid siblings return; required envelope failures still fail the search. The Research view and tool result retain result gaps. Doctor answering/readiness checks stay unverified when no usable results remain and parse gaps prevent a conclusive empty response. Fetch receipt retention reports its own checked failure independently of completed reads. Research Lab uses the same search route; the editable `research-lab.js` part selects sources and writes the brief from explicit native evidence, while Swift commits locked capped history and receipts and requires the complete current saved run shape. No browser search route or Codex search implementation remains. |
| Web reads and maps | Chrome 0.4.70 waits for readable content. [Chrome](Extensions/NativeAgentChrome/README.md), [maps](docs/ONE_DOOR.md). |
| Memory | MemoryV2 stores durable memories; Fluid Context prepares bounded context. [Recall unavailability](docs/ANATOMY_OF_A_TURN.md#recall-unavailability) names its cause. Conversation replay follows the [input-budget law](docs/conversation-context-history.md), without a stored cut pointer or summary. |
| REM proposals | The [replacement-evidence contract](docs/COGNITION_WIRING.md#rem-proposal-replacement-evidence) owns displaced-content provenance, review and approval behavior. |
| Work | Desk holds durable work. Helpers run their own model/tool loops with their names, personalities, jobs and transcripts; they follow Chat's Providers settings unless explicitly pinned and reach the resident through the contact path. Following helpers refuse conflicting settings at the submitted field and acknowledge inherited-value no-ops. See [helper settings](docs/USER_GUIDE.md#helpers-standing-bots). |
| Providers | Chat, Work, and Memory and mind are the three routing groups; Work and Memory and mind inherit Chat's model/account unless configured. Think and Fast use effort-only and tier-only group transactions: each changes its field across every member without pinning the resolved model/account or the other control. The person's Add key / Sign in opens protected Mac entry directly; an agent's provider request points to that same entry and settles only from verified saved auth status. See [Providers](docs/USER_GUIDE.md). |
| Mac face feed | Transcript paragraphs, page faces and native readouts use Shared slots; see [feed](docs/designs/separate-face.md). |
| Shared page renderer | Stage 7 source uses image, preview and web leaves in shared Make/Sense pages and removes unused Alive parts and copied body drawing. The renderer owns the main window, detached chats, Shotgun, protected entry and page bitmaps; body settings, engine/tool hosts, permission guidance readings and paragraph preparation remain. Stage 5–7 installed acceptance and performance comparison are pending. [Contract](docs/skill_manifest_spec.md), [stage proof](docs/designs/one-renderer.md#stage-7-leaves-and-what-is-left). |
| Trust | Full Mac grants autonomy without a timer. macOS privacy permission resets still ask the owner. A turn an agent you have not trusted started with its message gets one card on its first effect, and the answer covers the rest of that turn; a read steers nothing. Agents enabled in Trust → Connected agents carry the owner's authority on authenticated turns; ordinary Trust and domain checks remain. |
| Arrivals | Any door's typed arrival joins through `TurnAdmission.run`. During generation the selected turn program's optional CPU `hear` may cut the round: prose stays, every proposed call is discarded, and the next request reads arrivals. Missing or failed hearing keeps the boundary read; failure owes repair. Reservations extend before first text, and joined readings are checkpointed for relaunch before their old checkpoints retire. Readable, untainted words from the person also withdraw unstarted proposals and slots, including batch steps. Running calls retain receipts; Stop cancels at once. One reply keeps prose in streamed order and answers joined arrivals; their doors post nothing. Unread arrivals run through their own doors. Contract: [Anatomy of a turn](docs/ANATOMY_OF_A_TURN.md#1-a-surface-admits-the-turn). Source implemented; installed proof and the agent's authored `hear` remain pending. |

Meta's API-key route offers Standard Muse Wonder 1.0 and Muse Spark 1.3 through
the shared Anthropic-format Messages adapter with Bearer auth and effort controls.
Client-side text/tool history is retained; returned thinking blocks replay across
tool rounds through the shared bounded in-memory ledger, without persistence.
Installed proof awaits the lead's key;
see [Meta setup](docs/USER_GUIDE.md#meta-model-api).

The shared action door binds one supplied `id`, `item` or `handle` to the
schema's sole declared address field when that field is absent, before
validation, Trust and receipts; schemas declaring none or several are untouched
by this address binding. Other unknown names bind only to their unique declared
meaning or the single missing required argument of the same type, recording
the interpretation. Every returned action receipt carries its live argument
form, including the first call in a turn. Unresolved arguments carry
`try_instead` and a proposed `next_call` beside the original input. Ability
parameters accept description strings, plain types and property schemas,
retaining descriptions and constraints; a leading type word, optionally after
`optional`, supplies its type. Words end at whitespace, commas, colons or
parentheses; `?` on the type or the word `optional` marks optionality.
`try_instead` and a proposed `next_call` beside the original input; advice
requiring a change points to discovery instead of repeating the failed call.
A helper selector naming a saved agent contact refuses with its `agent.read`
call; `bot.ask` instead proposes `agent.message` with the saved address and
the original question as `text`, sending nothing. Ability parameters accept
description strings, plain types and property schemas,
retaining descriptions and constraints; a leading type word supplies its type.
Exact history references open across conversations through the same declared
argument binder. Only retained stopped-run checkpoints reserve Desk items;
conversations, operations, turns and ability inputs acquire no holds. Desk writes
serialize under the store's lock and retain their changed-state refusals.
Run refusals name their checked owner and end event with a resume preview.
Direct and scheduled morning briefs use the admitted ability's one packet
assembly; ability exceptions retain their place and repair call in the receipt.
Unknown action ids become intent words for find's checked semantic ranking;
the separate spelling-distance ranker is removed. Per-action ranking/schema
gaps stay named beside healthy results; shared catalog/index failures remain
failures. Retired tool names run nothing; there is nothing to load or unload.

## Known limits

- Empty Chat greetings and provider guidance scroll within the remaining room,
  keeping the composer in the window. The shared transcript press withholds a
  missing-row warning while a reply streams; an observed live identity still
  absent after streaming ends remains an unconfirmed reply. These source changes
  need the lead's installed acceptance.
- Other-session work has a shared quiet composer line on Mac, detached chats,
  full Shotgun and phone, eligible after the first call and removed by turn
  settlement. Phone reads Mac-published movement through the activity snapshot.
  Source implemented; build, install and the bounded cross-room navigation,
  cancellation, privacy and settlement observations remain with the lead.
- The opt-in copied window carries viewport and checked visible-reply receipts,
  acknowledges chat selection without reading its message file, and opens a
  cold conversation with a backward read of its ending rows. Earlier messages
  load when the ending document fits the reading area, on upward reading toward
  its beginning, or for a full-history operation, independently of end following.
  Transcript snapshots and press scripts carry completeness; semantic readers
  retain whole-history reads, and prepended history preserves the visible paragraph. This source
  change awaits the lead's build, install and bounded first-paint, scroll, Find
  and send checks.
  The copied window also carries
  protected inline entry, typed slash acts, memory diagnostics and resident
  cognition controls/readouts, Desk search/diagnostics/work detail and Make/Sense
  Work pane feeds, contact/helper rooms and helper result documents.
  Contact text uses transient shared-press rows with body-owned receipts and
  Stop/resend commands. Inspector Live/Replay readers, graph relationship sheets
  and the composer's context receipt/disclosure use their canonical body owners.
  Global search uses canonical inventory/ranking and typed destinations with
  source failures; the conversation column keeps its canonical title/preview
  search reader. Agent-view rooms use the existing read-only pane reader.
  Make export uses the conversation's project destination before asking for a
  chosen file. The copied Chat restores the body's startup selection before
  observing a transcript, and its composer holds the canonical per-session
  provider reader. Chat, detached conversations, Shotgun, context receipts and
  dictation join observation release before replacement. The body also joins a
  releasing key's source task before admitting a reader from a reopened view,
  checking cancellation and the connection before sharing or starting its source.
  The copied Advanced shell reserves the reading room before expanding the saved Work width;
  the conversation list keeps its fixed width and chat accepts its allotted
  width without shifting its inset chrome over the list. Work's divider starts
  at its drawn width and saves only a changed drag. Offscreen drawing
  starts no chat observation, and startup selection failures retain their cause
  with an explicit reopen control. Personality's own identity and diary links
  select its copied native destinations. The body and face record link names,
  roles, correlation ids and redacted failure causes in `diagnostics/FaceLink.log`
  under the body's supplied root; no payloads enter that record. Cancelled acts
  settle their replies outside execution cancellation. Failed acts and rejected
  frame receipts leave the connection open; transport failure and owner shutdown
  close it. Departing views settle cancelled refreshes and observations without
  status or toast feedback. Active observation failures draw in that view;
  arrival refresh failures draw in inline window status until navigation or
  dismissal. Automatic receipt failures draw their own inline status. Only an
  explicit person refresh held by a mounted view task can toast. Identity editing reads the acknowledged
  onboarding disposition without opening another setup observation. Canonical
  Providers and Connectors refresh names reach their checked owners; other
  panel failures name their own failed endpoints instead of mutable window
  status. Browser, update, Settings navigation and shared preference edits run
  in arrival order within the main scene, retaining each failure until dismissal
  and settling silently on scene closure. Their command task and feedback mount
  outside preference availability, so Use default remains executable when a root
  setting is invalid. Preference edits and Settings navigation check committed
  replies and independent publication failures. Window-command admission reopens
  main from a detached conversation; preference edits open it only when navigation
  is unmounted and leave an existing scene's focus alone. Each task consumes only
  its own request. The tour's temporary Advanced presentation is renderer-local;
  it does not write or restore the saved view mode on teardown. Settings
  navigation stays in Simple and opens Control's Settings tab there. These
  feedback changes still need installed acceptance.
  Native composer model, thinking, Fast, Trust and hand-back controls keep ordered
  requests in their visible conversation. Leaving that conversation or closing its
  view cancels held work, clears pending controls and settles without feedback on
  the next page. Active failures retain individual dismissible explanations.
  Choice writes read their checked baseline when executed, skip an unchanged
  choice and hold Send from admission through settlement. Full Mac confirmation
  belongs to its opening conversation; hand-back requires the owner's acknowledgement.
  Protected transcript-card answers hold their request in the mounted entry view.
  Active failures draw a dismissible explanation there after submitted-secret and
  credential redaction. Cancel holds admission until its client request settles; entry
  closure or a different card cancels work without feedback on its replacement.
  The same card's body-owned revision changes retain its pending answer.
  Setup return verification runs in arrival order in the mounted main, detached
  or Shotgun host for that conversation's pending controls. Active failures draw
  credential-redacted, dismissible feedback there. Cancel, departure or a different
  conversation cancels held work and clears queued verification; the next request
  joins that operation before admission. Departed-host feedback is discarded.
  Reverse control closure preserves the correlated result without resurrecting
  the closed control.
  Body quit terminates and joins its face child independently of
  the child's drawing thread. Doctor measures the original and copied Inspector
  through the same platform port, preserving failed subscription admission as
  an open view. Copied repair is bound to its connection/view/subscription and
  confirms source observation independently. The shared trace observer gets one
  repair attempt; later subscription failure retains each known effect's receipt.
  Context health holds its own subscription, fed by root-owned lifecycle,
  source, reconciliation, feedback, arena and lease events through the existing
  checked health owner. Coordinator replacement preserves that event source;
  context events do not refresh cognition detail. The copied Chat capsule's
  typed Inbox actions return navigation and draft effects through its pipe.
  Desk replies share the renderer's acknowledged draft operation: existing text
  is preserved, pending attachments remain and new-conversation creation is
  awaited. Refused or unconfirmed drafts leave the Inbox note unread. The
  duplicate body-window presenter and the original window's drawing are removed.
  Mac-control values follow driver and Trust events. Person-origin composer and
  Shotgun hand-back taps capture the delivered generation and acknowledge only a real
  grant by the driver owner. Transcript resizing sends changed dimensions;
  viewport membership has its own receipt. Link records identify readers, script
  bases and mounted composer sessions, with fractional-second event timestamps.
  Copied conversation switches reuse current rows, with one store watcher per
  visited session held for the connection. Opening sends the end viewport before
  Inbox and attachment work; acknowledged scripts leave the press's pending
  packets. Cached-switch latency still requires installed measurement.
  Dock reopen, the menu-bar Open control
  and the summon shortcut also reopen the opt-in preview. A replacement child
  waits for process exit and the previous connection's release before attaching,
  including when its feed task owns closure independently of the pipe reader.
  Cross-process pointer input has acknowledged preparation, routing and release;
  its installed proof, report/refresh acceptance and installed comparison remain incomplete;
  see the face contract above.
  Quiet composer edits use the copied draft's read revision and attachment
  identities; session, provider and connector writes retain their canonical
  body owners. Pane closure checks retain their caller's turn across selection
  changes, and the copied window owns its pane visibility. Folder pickers and protected connector entry use the requesting
  face. Sparkle keeps its updater in the body and presents its native user
  driver in that face, with operation-bound callbacks. Settings opens its
  data-limits reference from the renderer bundle's resource root. Native captures prepare
  unmounted page data before their applied-frame barrier, then await native
  preview completion while holding the pane and artifact revisions.
- Mac permissions, explicit blocks, connector authentication and origin checks
  still apply under Full Mac.
- The iPhone companion needs the Mac awake with NativeAgent open.
- A configured connection or a returned tool result alone does not prove an
  external action completed; inspect the action's receipt and owning service.

## Where to read next

- [README](README.md) — install and first run.
- [User and Agent Guide](docs/USER_GUIDE.md) — pages and everyday operation.
- [Capabilities](docs/CAPABILITIES.md) — source-backed capability map.
- [One door: the contract](docs/ONE_DOOR.md) — the agent's one door, `app`.
- [Documentation guide](docs/README.md) — documents and their readers.
- [AGENTS.md](AGENTS.md) — repository working rules.
