# NativeAgent Architecture Blueprint

Source-owner map for the running app. Start with [NORTHSTAR](NORTHSTAR.md)
for intent and the [documentation guide](README.md) for task-specific reading.
The tables name current declarations and selected entry points, not exhaustive
APIs. Implementation details belong beside their source owners.

## First Principle

One brain, many doors. `NativeAgent.app` hosts the runtime in-process.
`EngineRuntime/NativeAgentEngine` composes chat clients, tool dispatch and the
resident services from a data root and platform ports. `NativeAgentEnginePorts+App`
binds those ports to the Mac app and constructs the live engine.
`ChatTurnRuntime` owns resident turn execution; the app and remote surfaces reach
that engine through their adapters. StandingBots owns helpers' model/tool loops
over their own instructions and transcripts; helpers reach the resident as contacts.

## Runtime Shape

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift -->
| Location | Responsibility |
|---|---|
| `Sources/NativeAgentApp/` | SwiftUI app, Mac platform adapters and live engine assembly |
| `Sources/NativeAgentFace/` | Independent window process, Shared feed client and window-call routing |
| `Sources/NativeAgentSenseHost/` | Shared isolated JavaScriptCore executor for senses, tools, skills and ad hoc scripts; app supplies source/material and owns supervision |
| `Modules/NativeAgentCore/Sources/` | Engine, turn execution, domain stores, tools and policy |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | `isValidIOSDeviceRouteKey` |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift` | Nonblocking pipe reads and EOF settlement |
| `Modules/NativeAgentShared/Sources/NativeAgentShared/` | Shared Mac/iPhone declarations |
| `iOS/NativeAgentMobile/Sources/` | iPhone UI and sync adapters |
<!-- END GENERATED BLUEPRINT -->

`project.yml` owns installed bundle assembly and shared app package/resource lists.
Root `Package.swift` owns shared gRPC/Sparkle requirements; Core owns its other requirements.
`script/sync_build_declarations.rb` replaces generated SwiftPM app, Core gRPC and
Xcode package declarations from those owners; build entry points run it. Root
`Package.resolved` owns selected versions. Bundle-only targets/resources stay in Xcode.

Each project-module import has a direct target/product dependency, including
Shared models and external GRDB imports; re-exports do not supply ownership.
Edges required for extension visibility remain even without a direct import.

Native reply entries use `TurnQuietHoursWindow` before dispatching a send. A
resident answer waits in its saved completion and pre-send route journal;
deferral writes nothing. Delegation's exact quiet-hours end deadline runs the
existing saved-delivery reconcile. What is for them is one experience addressed to
`person`, held in memory by `ForPerson`; each of the person's doors is its `deliver:` obligation and `AttentionRouter` sends what
is owed. A matter that went wrong breaks their quiet hours; a pinned door also
goes now for their own Mac act with positive local provenance, or their current
conversation request with verified person ingress.
Peer or missing provenance stays held. Their doors are the phone, the originating thread when
present, and the Mac while they are there. [Reaching them](INTERNAL_WORKINGS.md) has the whole law.
iOS asking-chat publication follows its native send verdict, before completion
settlement. An explicit Telegram resend clears its saved refusal once, even
when quiet hours delay the wire. Work and wakes continue.

### Sense Helper Boundary

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentSenseHost/main.swift Sources/NativeAgentSenseHost/PlugIO.swift Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift Modules/NativeAgentCore/Sources/Senses/SenseHostLocator.swift Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift -->
| File | Responsibility |
|---|---|
| `Modules/NativeAgentCore/Sources/Senses/SenseHostLocator.swift` | Installed helper address |
| `Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift` | Deny-default helper reach and exact-IP network fences |
| `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift` | Resident JSC contexts, exact-source turn leases and bounded execution |
| `Sources/NativeAgentSenseHost/PlugIO.swift` | Bounded JSON-line transport |
| `Sources/NativeAgentSenseHost/main.swift` | JSON-line entry loop and bundled SDK loading for the shared JavaScript executor |
<!-- END GENERATED BLUEPRINT -->

The shared contract remains `SensesContract.swift`; wire schema and integration
responsibilities are in [SENSES](SENSES.md#the-plug-protocol-helper--app).

## High-Level Flow

```text
Surface adapter
    → NativeAgentEngine.chatClient
    → ChatOrchestrationClient / SwiftNativeTurnEngine
    → provider context and turn loop
    → app → page, home item, action or script
    → domain executor under the dispatch and approval gates
    → result, transcript and turn settlement
```

The core turn files are in `ChatTurnRuntime`; `EngineRuntime` supplies the
composition root and facades. `ProviderRouting` owns provider selection and
the shared nine-transport assembly (`makeResidentProviderLLMClient`); callers
supply credential and telemetry roots, environment confinement and transport limits.
Its checked route admission binds one model/provider/Think/Fast tuple for execution
and attribution; each caller selects whether to inherit a turn or resolve independently.
`ChatSessionWork` and `Transcripts` contain session/history storage;
`ContextFlow`, `MemoryV2`, `PersonaEngine` and `Cognition` supply their respective
context and state. Their file maps below identify the owning declarations.

## Tool Dispatcher Map

[TOOL_LOADING](TOOL_LOADING.md) owns discovery and dispatch;
`AppToolExecutor.runAppDoor` owns the door and `AppActions` its actions.
At executor assembly `AppActionRegistry` supplies `ToolRegistry.AppActionBinding`: executor, fixed input,
renames, descriptor, saved Trust keys, lifecycle and argument-dependent read conditions.
Authored policy resolves a requested action's reachable dependencies from one
checked part snapshot and its id/name map. A bounded history projection batch
passes one checked catalog, including missing action ids, through receipt argument
and result redaction, including nested app calls. An unreadable catalog stops that
projection; it never becomes an empty catalog.
TrustCenter, the door and receipts consume that binding; native descriptors also own
inventory membership, categories and authored-name reservations. Declared lifecycle writes refuse peer steering before
dispatch; legacy routes resolve from each action's declared tool and fixed input.
`AbilityStore` owns `data/abilities/`: current, previous and proposed files,
run accounting in `abilities/state.json`, and JSON notebooks in `senses/<id>/state.json`.
Its bundled seed catalog owns the shipped ids reserved by `Parts.save`, together
with `native-`; future shipped parts use `native-`.
One checked catalog supplies registry publication's pre-write evidence; writes keep
destination checks and post-write readback. Each decoded source file carries its
body digest; body edits refresh it.
Lifecycle publication preserves canonical accounting instead of writing its redacted projections back. The turn carries `AbilityRounds`:
terminal execution accounting supplies exact version keys, and round settlement never selects through a shared last-run pointer.
All kinds re-read keep authority under its
publication lock before any publication write, including bundled displacement
and sense restoration, through the engine-bound checked Trust reader; owner-off
authority remains separate. File-backed run receipts record ok/error/refused/cut/network; successful native/bundled reads also record versioned use.
A source-faulted live part operation with captured input owes repair through Experiences even after a clean run; file-backed sense completions omit input and record outcomes without this obligation.
The retained source supplies its authoring call; successful operation or keeping
its repair settles it, while reads and restarts do not.
Tools, skills and senses have no automatic swap-back or notification-only healing;
only their turn heals itself (`TurnPart`: `turn.js` → `turn.prev.js` → the shipped seed,
the same turn replayed). Explicit rollback keeps its existing authority checks. Sense lifecycle saves retain store-owned
evidence; only clean reads count as sense uses. A successful sense act
keeps its receipt and effects when accounting fails, with `accounting_error` beside them.
Its authoring mutations use the engine's task-local
origin/taint reader through `CapabilityLifecycle`. Only known peers
whose existing elevation switch is off refuse; unbound launch, owner and helper
turns remain allowed. `CapabilityLifecycle.Store` declares ability directories
for their owners and the shared raw-file mutation fence; raw mutations require
lifecycle actions, including case aliases. `AgentBridgePrincipal.turnRequest` supplies the common
principal binding for peer chat, named message lanes and raw bridge tools through `TurnRequest.bind`.
Carried work retains every steering principal, including currently trusted peers, and the
elevation the person's answer gave the run; ability writes read the current elevation switch after resume.
Usage accounting and material reads remain allowed; growth writes use the same refusal. Owner-attributed off state
survives agent/peer restore, enable, rollback and publication; only explicit owner
command paths may clear it.
Receipts report execution separately: preview, not_run, executed or attempted.
the peer floor, SecurityCenter and receipt redaction read that projection.
Unknown actions return `unknown_action`; registered actions use ordinary
`PermissionLaw` admission. Folded actions keep approval on their underlying call.
Domain capabilities and saved legacy Trust keys remain
TrustCenter policy.
`AgentWorkspace` supplies home's navigation and retained places.
Home labels its snapshot time and each section's source coverage; the turn glance
and inner capsule label their snapshot time and omitted live-state coverage.

`AppScriptRunner` adapts the app door to `OwnedProgramRunner`, whose `init(dataRoot:)`
selects the installed helper and empty-reach sandbox for scripts, abilities and turn steps.
`AppActions` owns live dependency contract projection; the shared static call-fit
reader checks each ability’s own calls against the live argument schema. Original
snapshots remain sealed admission evidence, while a real run refreshes its observed
contracts in the same accounting write as its receipt. Whole-contract and legacy
digest comparisons no longer gate execution (see the manifest contract).
Admitted authored tools are scriptable actions, including routine dependencies;
their calls retain ordinary skill checks and capture validation substitutes fixtures.
Their live action contract supplies the routine's read-before-act knowledge;
execution does not require a diagnostics-page version. Skill run accepts input
and its legacy args spelling; capture input errors report an argument remedy.
`ToolPrimitiveBroker` owns authored host-call admission and execution;
the [manifest](skill_manifest_spec.md#execution-and-ownership) owns their ABI and reach.
Tools, skills and senses share AbilityStore's notebook read/write/delete owner and lock,
keyed by part id, with scratch state during proof/preview and separate lifecycle accounting; a final drop deletes the part, accounting and notebook.
ToolExecution depends on ProviderRouting for that telemetry's independent request shape.
Fetch is the broker's: it uses its existing NWConnection pinned to its checked address,
TLS server name and platform HTTP message parsing, never resolves again in URLSession, and
returns redirects without following them. Fetch and held connections share raw byte reads;
only held arrivals signal residency. A fetch naming a connector refuses, pointing to
`secret:<name>` and a card (the connector seam is gone since 10-21).
A call naming `{{secret:<name>}}` (a fetch, `network.send` text, a program's args, env or stdin) takes
the value from the one keyring only toward a host or program the person granted, over https or a
tls connection or to a loopback host. Reply/error redaction permits up to three leading secret bytes at stream-piece boundaries before redacting the remainder.
Fetch uses its own policy name `fetch.secret` or `fetch.keyless`: keyless carries `network_public` (its reach is `network_localhost` for a loopback host);
a call carrying a secret carries `secrets` and is a read only when it only reads (GET or HEAD, no body). `program.start` is a command line
(`process_spawn`, `shell`) and launches through the shell tools' one launch (`builderLaunch`: their access
check, sandbox and starting folder, reached as `performReach("program.launch")`). Its input passes Trust
as any effect; every talk re-checks the ability's admission and the shell's access, and a refusal ends the program.
`PermissionLaw` resolves admission from posture, declared class and reach.
Every effect re-enters the ordinary gate chain; no Swift tool's admission is mirrored.
EventKit remains in LocalPIMConnectorActions/LocalPIMStore and Contacts in MacContactsExecutor.
Sandboxed authored execution has no blanket Full Mac requirement; each primitive uses its effect's ordinary gate.
`OwnedProgramProcess` and `ProgramProgressWindow` own progress renewal and host-wait accounting.
Stalled receives still expire.
Its envelope uses the dispatcher's authorable-name predicate, registered with the app policies, so an ability file cannot reclassify a Swift built-in.
The part header owns structured reach; tool records consume its projected permissions rather than treating reach itself as a list.
Primitive approval replay retains the originating broker through the existing host-call
subscription, rechecks the selected version and executes only the approved call.
The broker owns only model.call, fetch, raw network primitives and the run's screen watch (its frames are reads inside the admitted watch: no admission and no ledger row each; the watch leaves one receipt); ToolHost retains
declared app targets and the shared AppleScriptExecution call.
Primitive results and a tool's `returned` value are opaque data; outcome and effect classification reads only the receipt envelope. Authored business failure is reported by throwing a JavaScript error; `OwnedProgramRunner` owns that terminal verdict. MacControl's `AppleScriptExecution` is the single in-process OSA
execution owner for authored app calls and the built-in `MacAppleScriptBridge`:
one serial `NativeAgent.AppleScript` queue that holds every OSA wait off the
cooperative pool, URL-bound process resolution, Automation preflight, native
send/active callbacks, each event's own declared reply timeout, an explicit
cancellation flag and error mapping live there.
Automation status reads resolve installed URLs in detached work, then resolve
running PIDs and call `AEDeterminePermissionToAutomateTarget` on that queue,
returning values to the facade's `LatestRead` publication; a page refresh never
performs those reads on the main actor. `ask:false` never launches or prompts.
The person's `ask:true` uses the same owner, with only app launch on the main actor.
Authored scripts may declare `read_only:true`: Trust classifies the call as a read,
and the native send callback refuses each non-read event before dispatch.
`launch:false` resolves only an already-running URL-bound PID and returns
`not_running` with no effects when absent, never opening an app for a read;
timeouts check the existing Accessibility reader for a sheet/dialog before
claiming one blocked the app. Authored bodies disable
scripting additions and refuse resource imports, script objects and self/app
target syntax. The runner wraps each body in the declared bundle id's app tell,
refuses early closure and maps error locations to body lines; every send must
address the resolved app's exact PID. Built-in
integration scripts retain their trusted Foundation/OSAX environment. An app's
response to its own events remains that app's broad reach, including opening
other apps. ToolExecution depends on MacControl; Senses receives a read closure
from app assembly that first re-enters the ordinary Trust gate at read tier,
avoiding a reverse dependency. Only an owner card tap may request macOS consent.
Candidate validation intercepts all host calls before dispatch or primitive IO.
Resume compares journaled content digests: result owners declare volatile
envelopes through the runner's call-scoped `ReadContent`, retaining subject
identity as a dependency. The journal never guesses volatility from key names.
The same normalization compares replay arguments using saved and fresh read
projections; call identity, source line and meaningful arguments still match.

[The manifest](skill_manifest_spec.md#the-one-form) owns executable admission and exact-version review.
`AppActionRegistry` and `ToolNameAliases` own native dispatch mappings.
[TOOL_LOADING](TOOL_LOADING.md#extending-their-reach) owns search, retained web reads and Maps results.
`Research+WebSearch`, `Research+SearchFetch` and `ResearchHTMLExtraction` own their implementation.

## Policy Chokepoints

`TrustCenter` and `SecurityCenter` retain effect-time authority. Full Mac uses
the operator's selected autonomy; macOS privacy-permission resets still require
explicit approval. `PeerTurnEffectPolicy` applies the
[peer-turn authority contract](TOOL_LOADING.md#authority-and-receipts);
`ApprovalTransactions` owns the corresponding approval execution paths.

## State Ownership

`PersistenceCore` supplies shared JSON/JSONL I/O, durable writers, file locks,
change observation and data-root resolution. Domain stores remain with their
owners: authored part headers, lifecycle and run context in `AuthoredCapabilities`,
memory in `MemoryV2`, persona compilation in `PersonaEngine`, chat state
in `ChatSessionWork`/`Transcripts`, work in `Desk`, approvals in
`ApprovalInbox`, and the record of what happened in `Experiences`. The tables point to those implementations rather than
restating their storage formats.

File observation reports failed initial/re-arming through `FileChangeWatcher`'s
status and failure callback. `FileChangeEvents.waitUntilArmed()` returns that
status; a failed observation finishes its stream without claiming an initial
edge. Returning from watcher construction alone does not prove usable sources.
Ancestor observation opens directories only. Living Status uses one
`FileChangeEvents` subscription for readiness and debounced refresh edges.
Status reads wait for in-progress arming to finish; a successful vnode replacement
does not terminate subscriptions during the source-table gap. The subscription
and registry locks remain free for cancellation and failure delivery during that wait.
Reload debounce and derived-invalidation delivery retain entered work separately
from their timers. Cancellation/replacement requests cancellation and keeps
single-flight ownership through actual exit; only current pending edges admit
follow-up work. Response deadlines remain bounded without joining late work,
whose execution owner must retain exclusion/resources through actual exit.

## Background Loops

`BackgroundLoopLifetimes` owns registration, execution and
status. Core `EngineLaunch` constructs the concrete loop registrations and
dependencies through installed native host effects. Each failure outcome is a Doctor reading whose
repair, when owed, is projected from Experiences (no parallel Desk finding); receipts and
execution backoff remain with the loop scheduler (`SwiftNativeLoopScheduler`).

## Source Map Convention

Directory labels are repository-relative; table filenames are directory-relative.
Ordinary sources own one `// Blueprint: <table row>` line directly after imports
(at the top without imports), using their comment syntax; commentless files stay
hand-kept outside generated regions. Bundled `Resources/abilities/*.js` rows derive
from the JSON header's kind/id and `record.description` or following comment text;
parts carry no Blueprint marker. After editing a row's source, run
`swift script/generate_architecture_blueprint.swift`; never hand-edit generated regions.
`--check` verifies generated equality, exact row placement, file existence and policy,
plus coverage of every non-test Swift file under `Modules/` and `Sources/`
(excluding `.build`) and every bundled part.
Declaration names are source locators; consult the named owner for behavior and limits.

## App Source Map

### App

Directory: `Sources/NativeAgentApp/`

Mac chat hands grouped rows to the root's Shared `TranscriptPress` actor.
FaceLink selection checks the session index and acknowledges without reading
the message file. Main and detached rooms mount their document before the
conversation face arrives. `TranscriptsFacade` owns the loaded extent: a cold
reader uses `SessionHistoryReader`'s backward JSONL read for at least the last
64 message rows, growing that demand to the viewport's opening paragraph count
when larger, and discarding the row cut by the leading byte boundary before decoding.
`displayedTranscript` returns that extent explicitly through `isComplete`;
`loadMessages`, `loadTranscript`, search, phone projection and model replay
read the whole transcript. Partial reads never enter the decoded-file cache.
The reader's first upward approach to the loaded beginning, Find, Select All,
message Copy, Remember or an older-message reveal requests a complete read.
A partial document that fits the reading area also requests completeness after
script application or viewport layout, including folded rows. Neither request
depends on following the end; promotion retains the end or the reader's paragraph
and offset according to that existing choice.
Send admission, retry and greeting eligibility also require complete messages.
The facade retains that demand through subsequent file invalidations, with
`LatestRead` ordering all publication. A missing file is an empty conversation
only when the canonical index explicitly records zero messages.
Transcript-read diagnostics distinguish cache reuse from bytes read from disk.
The press owns `TranscriptBuilder`, its content-keyed group cache, incremental
live markdown and rendered `AttributedString` paragraphs. Its per-reader edit
scripts arrive at `FaceKey.transcript(session:)`; each controller selects only
its mounted reader. Acknowledged script tokens preserve the applicable base
when feed updates coalesce or two windows use different widths. Session caches
and prepared conversation/Shotgun presentations survive reader removal. Mounts
receive retained end-viewport paragraphs from base nil only for their requested
width and scale; exact input matches do no preparation. A missing format is
rendered, never substituted from another format. Cold mounts also publish the
end viewport first. Application and first draw release each reader's older
paragraphs within its loaded extent in a second script; rejection stops delivery with its cause and
reader release discards it. Pending opening work belongs to each reader, so
other readers keep printing. The press owns the drain independently of
input-task cancellation; reader removal follows the cancelled input task.
`TranscriptDocumentController` applies native paragraph replacements in one
TextKit transaction and paces glyph slices prepared by the press. Opening,
reveal, following and live-resize deferral retain the reader's text location.
Each script states whether it includes the complete document, including older
paragraphs. Find and whole-document selection wait for that script; Copy queued
behind Select All follows it. Full-read and rendering failures surface their
cause, and closing the reader cancels its held commands. Prepended history
retains the visible paragraph by block identity and offset, or the end while
following; scrollbar growth cannot choose another reading position. A tail's
conversation face carries `transcriptComplete: false`, and an unobserved older
approval remains unknown rather than declaring the conversation free of requests.
Opening sets following true. Only reader input changes it by the landed end
position: live scroll, wheel, keyboard, Find, selection autoscroll, reveal and
Latest. Clip notifications, estimate corrections, layout, attachment sizing,
edits and resizes never change that choice. Reveal applies one prepared-glyph
storage splice outside the general place recorder, preserving a held clip origin.
Growth and TextKit layout keep the end with one last-fragment read and at most
one clip move while following; active reader navigation suspends end correction.
Only opening and Latest explicitly lay out the end viewport. SwiftUI takes the
viewport's proposed size independently of document growth; hover anchors use
drawing offsets. Unchanged text frames, visible-rect tracking registrations and
scroll-mask geometry do no repeated writes.
The Shared renderer mapping's parser source positions
map glyph reveal and Markdown copy, with raw message text retained separately.
Open/follow/first-draw diagnostics append off main to `diagnostics/TranscriptDocument.log`.
The copied face appends `diagnostics/FacePage.log` on a utility queue in `FacePageDiagnostics`.
`page.open page=<id> elapsed_ms=<ms>` measures the window's displayed-page change
through the first native drawing callback with a page snapshot. One `ContentView`
change observer covers selection and view mode, including the initial display;
one paint callback in that window's page host consumes the pending timestamp.
Links that await the body before navigating slightly undercount the person's wait.
Home rooms, tabs and setup sheets add no separate timestamps; quiet offscreen
captures do not mount this window host. A page that never arrives produces no
completed open; the next selection replaces the pending timestamp.
`page.arrival page=<id> bytes=<n> elapsed_ms=<ms> bytes_kind=display_text_utf8`
measures accepted per-page slot application on main, including equality and selection
refresh, excluding drawing and log work. Equal values produce no arrival record.
Decoded feed values have no per-page wire length: the writer counts display-text
UTF-8 bytes off main, without encoding, and records no page content.
The body classifies every `FaceAct` explicitly for failure redaction. Typed
credentials and OAuth callbacks redact their submitted bytes; open value maps
conservatively redact submitted string leaves. Named app preferences submit no
exact secrets. All failures still pass through the shared credential-pattern redactor;
other acts carry declared content, identities or decisions.
Width and text-size changes publish viewport paragraphs before the rest.
The session-revision block-cache key and main-actor build/render path are
removed. Attachment hosting and measurement retain their separate contract.
Main chat reads the document's inputs in `ChatTranscriptRoom`, so sidebar,
header and composer observation stays outside that body. Streaming identity reads
only that conversation's stable observable slot in `TurnsFacade`, including while
empty; its unobserved directory replaces the shared streaming-id dictionary, so
another conversation's stream start or finish does not invalidate this read.
Authored words observe their exact presentation face slots, including keys
whose values have not arrived. A missing headline draws an empty line; an
arriving headline changes only its paragraph. Unrelated copy preparation
cannot invalidate a transcript.
Equal session-index reads keep the same observed array. The app door's catalog
index listens to its source files and part/helper changes, without a general
UserDefaults subscription; action text reads no preference values.

Hardened-runtime Mac builds require
`com.apple.security.personal-information.calendars=true`; without it, TCC
rejects Calendar permission prompts. All four Mac entitlement templates retain
this grant, and `script/verify_release_artifact.sh` checks the signed entitlement.

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentApp/ -->
| File | Owns |
|---|---|
| `ActivityWatchController.swift` | `ActivityWatchController`: Capture watch binding and privacy-safe issue notifications |
| `AppApprovalTransactionEffects.swift` | Approval factory and live effect bindings; canonical browser outcomes |
| `AppConnectorPlatform.swift` | Voice, notification, Mac control, EventKit and device-sync platform bindings |
| `AppDelegate+BackgroundTasks.swift` | `AppDoctorPort`: Doctor platform, both Inspectors and discovery-admitted browser health |
| `AppDelegate+Launch.swift` | `AppDelegate`: Launch, turn-safe quit, ingress retirement and shared sleep settlement |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: Single-instance checks, launch alerts and login registration |
| `AppModel+ChatActions.swift` | Chat mutations, regeneration and turn admission through `MacChatTurnCommands`. |
| `AppModel+ChatSessions.swift` | `AppModel`, `composerDraft(for:)`: Shared drafts and checked session transactions |
| `AppModel+ChatState.swift` | `AppModel`: Checked profile and transcript reads, pinning and pruning |
| `AppModel+CountsFace.swift` | Per-control selections of the agent's finished counts and panel freshness |
| `AppModel+GraphCapabilityActions.swift` | Research search and shared browser/export adapters retained for other pages and the tool door |
| `AppModel+HealthEmbeddings.swift` | `AppModel`, `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`, `LatestRead`: Health publication |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` mounts checkpoint presentation through the core session delivery owner and lifecycle without forwarding a turn sink; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory` |
| `AppModel+Onboarding.swift` | `AppModel`: first-run greeting port and onboarding commands |
| `AppModel+PanelRefresh.swift` | Panel commands and selected freshness reads; `PanelFreshnessOwner` admits receipts off main |
| `AppModel+PersonalitySelfImprovement.swift` | `engine.persona`: Profile/document writes through the persona owner; support and proposals |
| `AppModel+ProviderCommands.swift` | `AppModel`: checked provider reads, chat-brain saves and disconnect outcomes |
| `AppModel+Refresh.swift` | `AppModel`, `setIfChanged`, `refreshAll`: Shared refresh reads |
| `AppModel+SchedulerActions.swift` | `AppModel`: Desk creation commands |
| `AppModel+SettingsFeed.swift` | Native settings readers select only their finished settings group |
| `AppModel+SkillsIntegrations.swift` | `AppModel`: connector updates, Telegram status/test/clear through the Telegram owner, Doctor runs |
| `AppModel+TrustActions.swift` | `AppModel`: Trust policy, backups, approval resolution and Mac control commands |
| `AppModel.swift` | `AppModel`: Composition, shared drafts, retained page sessions and owner-derived UI state |
| `AppQuietLowerOnly.swift` | `AppQuietSettingsHost`, `AppQuietToolHost`: Connector commands; Full Mac ownership |
| `AppQuietSettingsHost.swift` | Owner-declared settings; phone rows use signed requests, with no Mac copies |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: Separate real and inert dream calls; part management |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppSettingsFace.swift` | Settings face platform rows and their Mac verbs: the updater, data reference, clipboard and live app status |
| `AppShellMenuPresentation.swift` | `NavigateMenuPresentation`, `MenuBarStatusPresentation`: Rail-derived shortcuts and one status line; `ShellRailRow`: the rail's rows in layout order, a page of the agent's own among them |
| `AppToolPlatform.swift` | Browser, notification and away bindings; shared speech client |
| `AppTrustFaceActions.swift` | Mac hosts for Trust, Settings, contact and capability face actions |
| `AppearanceController.swift` | Body-owned appearance preference name; appearance is applied by the window |
| `BodyCardActions.swift` | Body-owned inline interaction answers and verified-control settlement |
| `BodyFaceConnection.swift` | Body pipe endpoint: attach, feed receipts, act dispatch and correlated window calls |
| `BodyFaceDoctor.swift` | Doctor reads the only Inspector and binds subscription repair to its connection and view |
| `BodyFaceMotor.swift` | Connection-held motor acknowledgments and driving feedback for the separate face |
| `BodyFaceNotifications.swift` | Native notification effects retain their originating renderer and canonical body action owner |
| `BodyFacePalette.swift` | Connection-owned global search using the canonical inventory, ranking and saved-result owners |
| `BodyFacePresentation.swift` | Connection-bound tool presentations and applied-frame page screenshots |
| `BodyFaceProcess.swift` | Body-owned child process, inherited pipes and explicit window reopening; process exit owns retirement |
| `BodyFaceServices.swift` | Body-owned contact, Desk, graph and resource acts for the separate window |
| `BodyFaceTranscripts.swift` | Connection-owned press readers, live conversation projections and checked transcript resource grants |
| `BodyFaceVoice.swift` | Body microphone, speech and attachment reads publish operation-bound values to the window |
| `BodyFolderPresentation.swift` | Cancellable native shared-folder selection for body presentation calls |
| `BodyInboxCardActions.swift` | Copied Inbox effects return through its pipe; draft receipts confirm the applied renderer edit |
| `BodyNativePanels.swift` | Cancellable body-native folder and exclusion panels |
| `BodyOAuthPlatform.swift` | Body OAuth protocol adapter; only authentication-session presentation crosses the pipe |
| `BodyQuietChatCommands.swift` | Connection-held quiet composer snapshots, CAS edits and canonical session commands |
| `BodySettingsActHandler.swift` | Body platform acts, mounted presentation demands and pipe-owned reverse calls |
| `BodySettingsPreferences.swift` | Body dispatcher preference projection and declaration reads |
| `BodyTrustPresentation.swift` | Confirmed native activity-exclusion picker for body presentation calls |
| `BodyUpdateUserDriver.swift` | Sparkle user-driver events and person replies held by their originating renderer |
| `BrowserWindow.swift` | MainActor WebKit event waits; interruptions retire exact views, preserving unknown outcomes |
| `CardControls.swift` | Mac inline interaction resolver ports; permission requests and typed credential owners |
| `ChatClipboardAndAttachmentSupport.swift` | Clipboard writes requested through the body settings owner |
| `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |
| `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |
| `ChatContextFillBar.swift` | `ContextFillPresentation`: Shared context usage; missing measurements remain unavailable |
| `ChatView+SlashCommands.swift` | Body-owned slash command commits for provider choice, memory, notes and scratch |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` alias to `ChromeControl.ChromeExtensionFolder`; app-bound `setUp`, `setupMessage` |
| `CommandPaletteInventory.swift` | Saved palette destinations, shared inventory and deterministic ranking |
| `ContentView.swift` | Body notification names for canonical navigation requests |
| `DisplayFrame.swift` | `DisplayFrame`: the Mac window's display rhythm; the face feed applies what arrived once per frame |
| `FacePreference.swift` | Typed settings preference values read by body-owned settings helpers |
| `InboxCardActions.swift` | `AppInboxCardActionEffects`: native navigation for core inbox transactions |
| `InlinePreviewCards.swift` | Inline approval resolve, durable-decision toasts and resolution messages retained by chat and Trust |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform`; pending proposals use the engine's review-eligible reader |
| `MemoryView.swift` | Canonical Spotlight reindex operation and checked outcome words |
| `MenuBarController.swift` | `GlobalHotkey`: Carbon summon registration and tap/hold push-to-talk state with cancellable voice lifecycle |
| `NativeAgentApp.swift` | Engine launch and app hosts; one delivery watch with launch, network and configured-door wakes |
| `NativeAgentAppCoordinator.swift` | `ApplicationLifetime`: bootstrap and scene navigation; delivery proves acceptance only |
| `NativeAgentDesign.swift` | AppKit transcript preparation tokens shared with the window's typography and geometry |
| `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |
| `NativeAgentIntents.swift` | Named resident-agent Shortcuts; NativeAgentDoctorIntent admits and settles runs through the live DoctorFacade |
| `NativeAgentNotificationActions.swift` | Native response mapping and mounted dispatch; EngineNotificationActions owns effects |
| `NativeAgentWindowChrome.swift` | Menu-bar control opening the independent window process |
| `NewDeskTaskSheet.swift` | Typed result of body-owned Desk task creation |
| `PersonalityFaceDestinations.swift` | Personality face links open its existing identity editor and Dreams |
| `QuietComposerCommands+Presentation.swift` | Quiet composer command port, checked routing projection and mounted-page effects |
| `QuietSelfAdminRender.swift` | Body page-owner text reads, card facts, catalog and renderer-bound screenshots |
| `SensesAssembly.swift` | `SensesAssembly`: gated hub bindings; scoped readiness and repair; quiet reads borrow no authority |
| `SettingsDock.swift` | Body-owned permission guidance readings; the window draws and closes the native card |
| `SettingsNavigation.swift` | Body navigation requests opening the renderer's canonical Settings pages |
| `ShellPageContent.swift` | Rail-to-page names used by body-owned page reads and renderer navigation |
| `ShellRailPages.swift` | Canonical rail-tab identities for body routing and search |
| `ShellTabs.swift` | Stable page tab identities used by body routing and search |
| `Shotgun.swift` | Body-owned global Shotgun shortcut and actual motor-event forwarding to the only window |
| `SystemPermissionPreflight.swift` | Shared consent; scoped failures, activation and Bluetooth event waits, checked cleanup |
| `TodayView.swift` | Activity section names for body navigation requests |
| `TranscriptStyle.swift` | AppKit tokens and the press's off-main paragraph renderer |
| `TrustActions.swift` | Shared Trust preset commands and action outcomes; Trust draws its core face |
| `UpdateController.swift` | Body Sparkle lifecycle, probes and update requests |
| `VoiceInputController.swift` | `VoiceInputCapture.forChat`: name context, macOS speech consent and shared failures |
| `WorkPane.swift` | Preference names for body-owned Work pane settings; window owns visibility and selection |
<!-- END GENERATED BLUEPRINT -->

### Face

Directory: `Sources/NativeAgentFace/`

The independent window target links only NativeAgentShared and Apple UI frameworks.
The body retains its existing window while the copied renderer is assembled.

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentFace/ -->
| File | Owns |
|---|---|
| `AdvancedPageComponents.swift` | Inline page-read status and checked display words for item status |
| `AgentPresence.swift` | Agent presence card and Core Animation breathing orb reflect shared turn state and motion preferences |
| `AgentScreenView.swift` | Home and room slots with typed page acts |
| `AlivePageKit.swift` | Shared page style, native header and accessibility-aware card surface |
| `AnthropicSetupTokenInput.swift` | A protected shared form sends transient setup-token bytes to the Anthropic owner |
| `AppConnectorPlatform.swift` | Protected account windows and folder presentation requested by the body |
| `AppModel+ChatActions.swift` | Chat acts and typed admission receipts; the body owns execution and settlement |
| `AppModel+ChatSessions.swift` | Local drafts, body session acts and composer compare-and-set calls |
| `AppModel+ChatState.swift` | Drawing selections and explicit body refreshes; mounted views hold observations |
| `AppModel+CountsFace.swift` | Per-control selections of the agent's finished counts and panel freshness |
| `AppModel+GraphCapabilityActions.swift` | Research and export commands consume typed body replies |
| `AppModel+HealthEmbeddings.swift` | Health refresh belongs to the body; the window requests its diagnostics panel |
| `AppModel+MacChatTurnPort.swift` | Renderer Stop requests; execution, continuations and turn settlement belong to the body |
| `AppModel+MemoryActions.swift` | Memory pin/forget acts carry identities and await committed body outcomes |
| `AppModel+Onboarding.swift` | Onboarding commands and durable disposition readback through the body |
| `AppModel+PanelRefresh.swift` | Scoped body refresh acts and selected panel freshness presentation |
| `AppModel+PersonalitySelfImprovement.swift` | Persona, proposals and explicit mind work through checked body acts |
| `AppModel+ProviderCommands.swift` | Provider presentation and commands over FaceClient; save replies carry the committed choice |
| `AppModel+Refresh.swift` | Checked refresh replies and mounted person-request feedback; `FaceRefreshButton` holds its view task |
| `AppModel+SchedulerActions.swift` | Desk creation through the body act owner |
| `AppModel+SettingsFeed.swift` | Finished settings readers and scene-held preference write admission |
| `AppModel+SkillsIntegrations.swift` | Connector, Telegram, Doctor and Inbox acts; the body owns their effects |
| `AppModel+TrustActions.swift` | Trust, approval, backup and Mac control requests through the body dispatcher |
| `AppModel.swift` | Renderer selections, shared edit drafts and the pipe client's finished face values |
| `AppShellMenuPresentation.swift` | Rail-derived shortcuts, status words and ordered rail rows |
| `AppTrustFaceActions.swift` | Native Trust workbench and confirmed app-exclusion picker |
| `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |
| `ApplicationLifetime.swift` | Renderer-owned scene mounting, command admission and acknowledged navigation |
| `CardChrome.swift` | Shared protected card forms retain nonsecret edits and route secret bytes to the card's own control |
| `CardControls.swift` | Native card presentations and checked verification; mounted hosts own return work and feedback |
| `ChatClipboardAndAttachmentSupport.swift` | Picker, paste and drop transfers; body attachment validation, capture and voice acts |
| `ChatComposerChrome.swift` | `ComposerKeys`: editor-scoped Tab, slash, Shift-Return and attachment paste interception; shared composer chrome |
| `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |
| `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |
| `ChatComposerSettings.swift` | Native composer menus, context receipt and view-held control requests with checked feedback |
| `ChatContextFillBar.swift` | `ContextFillPresentation`: Shared context usage; missing measurements remain unavailable |
| `ChatFaceCalls.swift` | Mounted conversation, detached-window, composer and acknowledged chat-draft reverse calls |
| `ChatFocusedCommands.swift` | `ChatFocusedCommands`: Visible-window commands |
| `ChatInboxStrip.swift` | `InboxStripContainer`: Inbox projection; reads do not resolve |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableView`: a parsed transcript table (`ChatMarkdownTable`, NativeAgentShared) as a Grid |
| `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops with mounted-page visibility |
| `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |
| `ChatShellViews.swift` | Shared header, conversation slot rows, title selections and row-local relative age |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatTurnFailure.swift` | Message-scoped continue/restart acts and body-authored failure confirmation |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+Conversation.swift` | Conversation, read availability, composer and cross-surface observation |
| `ChatView+DetachedSessionMenu.swift` | `DetachedSessionMenu`: conversation window commands |
| `ChatView+PinnedSessions.swift` | `ChatView`: feed pin presentation, body pin acts and local drop intake |
| `ChatView+SessionActions.swift` | Session rename and export acts; saved transcript and speech remain body-owned |
| `ChatView+ShellColumn.swift` | `ChatView`: identity-only conversation sections, archive and row commands |
| `ChatView+SlashCommands.swift` | Draft-preserving sends and slash acts; execution and route validation belong to the body |
| `ChatView.swift` | `ChatView`: local composer state, feed demands and mounted lifecycle; stale-panel notice leaves |
| `ChatViewStateCoordinators.swift` | Card clearance, one-shot clear and occurrence-preserving toasts |
| `ClaudeConnectionPanels.swift` | Direct Anthropic OAuth sign-in and setup-token connection panel |
| `CognitionObservatoryView.swift` | Shared cognition page, context and Desk evidence with retained person commands |
| `CognitionProposalsView.swift` | Canonical proposal lineage uses the shared page rows and its held cognition read |
| `CommandPalette.swift` | Finished global and Desk search results; mounted keyboard navigation |
| `CommandPaletteInventory.swift` | Local saved navigation and mounted Desk palette callbacks |
| `ComposerContextReceipt.swift` | Shared receipt rows and demand-read context disclosure from the body |
| `ComposerControlCommand.swift` | Checked native composer requests retain their conversation and real body result |
| `ComposerShellState.swift` | Mounted menus, context receipt, Trust confirmation and ordered composer control requests |
| `ConnectorWizardView.swift` | Protected shared Slack setup retains public edits and sends token bytes only to its native owner |
| `ContactPortraits.swift` | Finished portrait bytes and local initial tints; Clawd and helper tile drawing |
| `ContentView.swift` | `ContentView`: shell, scene navigation, first-run and window navigation |
| `ContextFlowObservatoryPanel.swift` | Shared context rows retain the separately held context health owner |
| `DeskDebugPanels.swift` | Finished body Desk diagnostics |
| `DeskFaceEditors.swift` | Mounted Desk editors await chat draft receipts; notes commit through the body owner |
| `DetachedChatPanel.swift` | `DetachedChatWindowController`: session windows, pins, frames, focus and teardown |
| `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session transcript/composer through shared owners |
| `DisclosureRowToggle.swift` | `DisclosureRowToggle`: whole-label disclosure hit target sharing the DisclosureGroup's existing binding |
| `DisplayFrame.swift` | `DisplayFrame`: the Mac window's display rhythm; the face feed applies what arrived once per frame |
| `DreamsView.swift` | Shared diary selection, owner-held entry demands and the diary's checked cycle levers |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `FaceCallRouter.swift` | Renderer reverse calls: cancellable sheets, owner presentations and the applied-frame page capture callback |
| `FaceComposerFocus.swift` | Exact mounted native composer identification and confirmed first-responder focus |
| `FacePageView.swift` | Page slots, answering doors, document demands and diagnostics; MacFaceLinks owns destinations |
| `FacePreference.swift` | Preference leaf selections and explicit read availability; person edits reach the settings owner |
| `FaceReports.swift` | Ordered scene and Inspector reports from renderer lifecycle events |
| `FaceWindowAction.swift` | Window commands and shared preference edits retain ordered, checked requests through their mounted scene |
| `GrokSecureSetupCard.swift` | Shared protected routine entry sends transient credentials to the native Grok owner |
| `InboxCardActions.swift` | Native Inbox commands cross to the body's transaction owner |
| `InboxItemDetailSheet.swift` | Shared capsule-note rows/documents and retained actions; the typed Inbox owner settles every outcome |
| `InboxNotesCapsule.swift` | Shared unread-note capsule/list, bounded continuations and checked batch read outcomes |
| `InlinePreviewCards.swift` | Approval feedback from the body's durable resolution reply |
| `InspectorView.swift` | Selected Inspector faces, held view/subscription identities and checked source-health replies |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphPresentation.swift` | Local graph view and recency choices; canvas edge drawing identity |
| `KnowledgeGraphRows.swift` | Graph canvas colors for the shared entity-kind vocabulary |
| `KnowledgeGraphView.swift` | Shared graph collection and selected item demands; the native canvas is a page leaf |
| `MacChatOtherSessionsBanner.swift` | Shared cross-conversation movement with existing navigation and Stop owners |
| `MacChatTurnCard.swift` | `MacChatTurnCard`: main/detached display of the shared turn face |
| `MacControlWorkbenchView.swift` | Shared Mac control forms, policy availability and retained owner outcomes |
| `MacWorkOverviewDetail.swift` | Shared work facts and document body; approvals and Inbox draw the Inbox page |
| `MemoriesFaceNavigation.swift` | Memory and helper document demands; existing correction/Forget controls and local graph/upkeep destinations |
| `MemoryView.swift` | Memory upkeep acts, full text, feed read status and scoped face observations |
| `MessageAttachments.swift` | Granted transcript resources: image previews, file chips and off-main bookmark resolution |
| `MessageBubbleActions.swift` | Bubble hover controls, canonical message JSON sheet and advanced text editor |
| `MindFaceCalls.swift` | Inspector reverse calls read and rearm the mounted renderer subscription |
| `MoodTint.swift` | Feed warmth drives local display damping; window visibility owns the animation timer |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`; centered shell layout and shared surfaces |
| `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |
| `NativeAgentFaceApp.swift` | Copied window bootstrap; its only agent owner is the inherited pipe client |
| `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |
| `NativeAgentMotion.swift` | `NativeAgentMotion`: shared transitions; Reduce Motion stops layout, retains fades |
| `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |
| `NativeDisclosureTriangle.swift` | `NativeDisclosureTriangle`: AppKit disclosure button bridge sharing the row's expansion binding |
| `NativeOAuthPlatform+SessionRunner.swift` | Authentication callbacks, explicit cancellation and one session settlement |
| `NativeOAuthPlatform.swift` | Authentication-session presentation scoped to the body's operation |
| `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge with native clear/escape/return behavior and explicit focus tokens |
| `NewDeskTaskSheet.swift` | Shared task form with retained drafts, field validation and owner settlement |
| `OAuthSignInButton.swift` | `OAuthSignInButton`: sign-in, CLI consent and persisted credential presentation |
| `OnboardingProfileRepair.swift` | Profile-only repair and completion; preserves persona and skips fresh-install work |
| `OnboardingRecovery.swift` | Recovery uses the durable disposition returned by an act, never the drawing feed |
| `OnboardingTourOverlay.swift` | Stable rail-stop identity from the layout face; local overlay progress |
| `OnboardingWizard.swift` | Shared onboarding pages with native identity commands, recovery and OAuth leaves |
| `OnboardingWizardState.swift` | Local name/progress drafts; the Providers face supplies Chat readiness |
| `PageSheetHost.swift` | Shared page sheet framing and the focused Desk research sheet |
| `PersonalityEditor.swift` | Shared starter and identity forms, field settlement and document conflicts; memory owns USER |
| `PersonalityFaceDestinations.swift` | Personality face links open its existing identity editor and Dreams |
| `PipeFaceClient.swift` | Renderer act correlation, frame application and body-call dispatch over the inherited pipes |
| `ProtectedFaceEntry.swift` | Credential-sheet content appears only after its actual window is excluded by the body |
| `ProviderCards.swift` | Shared provider cards, notes, titles and account status words |
| `ProviderConfigSheet.swift` | Protected provider drafts and committed account readbacks |
| `ProviderThenModelPicker.swift` | Shared provider/model menu for onboarding and helper editors |
| `QuietCaptureSession.swift` | Read-only capture assets, native preview completion receipts and scoped resource settlement |
| `QuietComposerCommands+Presentation.swift` | Feed-only composer labels and body-owned routing transactions; window card call endpoints |
| `QuietSelfAdminRender.swift` | Offscreen bitmap drawing, local page routing and composer presentation |
| `RendererProtection.swift` | Whole-renderer protected windows, lifecycle notifications and ordered acknowledged publication |
| `ResearchView.swift` | Shared research form and result rows over the existing search owner |
| `RunDetailSheet.swift` | Saved run detail uses the shared document demand and TextKit renderer |
| `SessionDragSourceView.swift` | `SessionDragSource`: AppKit desktop-detach bridge and monitor teardown |
| `SessionRow.swift` | `SessionRenameRow`, `ChatRenameStateMachine`: exactly-once rename settlement |
| `SettingsDock.swift` | Permission guidance from body slots, with the grant-holding body bundle as its drag source |
| `SettingsFaceCalls.swift` | Mounted settings presentations, bundle-root references, native pickers and disconnect cancellation |
| `SettingsNavigation.swift` | SettingsLink routes to canonical pages; ShellPageFrame supplies shared page layout |
| `ShellFaceCalls.swift` | Scene, Desk, Work pane and clipboard reverse presentations |
| `ShellPageContent.swift` | Page drawing map and local rail/profile vocabulary |
| `ShellRailPages.swift` | `SurfaceLayoutContent`: checked layout; `ShellRailTab`: canonical tab routing |
| `ShellSidebarRail.swift` | Canonical rail rows, unavailable page owners, selection and focus rings |
| `ShellTabs.swift` | Shell page/tab components: content-local action rows, shared scroll gutter and tabbed page layout |
| `ShellWindowChrome.swift` | `ShellWindowChrome`, `ShellFrame`: native chrome, split layout and keyboard order |
| `Shotgun.swift` | `ShotgunController`: person-only driving chat; scoped Stop/Resume, placement and fade settlement |
| `ShotgunFaceCalls.swift` | Reverse-call owners for renderer step-aside, driving feedback and operation-held pointer passage |
| `ShotgunPointer.swift` | `AgentPointerOverlay`: noninteractive pointer and fades; excluded from agent captures |
| `ShotgunView.swift` | `ShotgunView`: driving-session transcript/composer, live step and Stop/Resume/Watch controls through existing owners |
| `SimpleContactThread.swift` | Finished contact-thread lines, links, pending rows and body-owned action receipts |
| `SimpleHelperThread.swift` | Helper run rows, full documents and helper-contact messages use body DTOs and acts |
| `SimpleSetupPanel.swift` | Setup hosts hold conversation-bound return verification, cancellation and dismissible feedback |
| `SimpleShellView.swift` | Simple's local selection draws contact and helper slots without owning either catalog |
| `SimpleSidebar.swift` | Selected contacts, helpers, layout and shared face preferences |
| `SimpleThreadComposer.swift` | Thread-bound drafts clear only on acceptance; shared send and accessibility |
| `SimpleThreadPresentation.swift` | Thread typography, line formatting and local geometry |
| `SimpleViewMode.swift` | `ViewModeSwitch`: Simple/Advanced/Agent selection and shared top chrome placement |
| `SystemToastBar.swift` | platform notice rendering and room-scoped positioning; values, queue and timers belong to NativeAgentShared |
| `ThinkingGlow.swift` | `ThinkingGlow`: leaf-layer working shimmer and composer rim driven by turn state, fading when reply text begins |
| `TodayView.swift` | Today's posted face and Activity destinations; opening the page starts no source reads |
| `TranscriptAttachmentViews.swift` | Resolved conversation attachments, Inbox acts and contact-thread feed presentation |
| `TranscriptAttachments.swift` | Document view attachments: one hosted view per block id, fed from the model, sized to fit |
| `TranscriptDocumentController.swift` | Applies press scripts; TextKit viewport, reader place and prepared-glyph reveal |
| `TranscriptDocumentView.swift` | `TranscriptDocumentView`: any run of a conversation as one document; hover bar, sheets, host handle |
| `TranscriptFragments.swift` | One layout fragment per drawn paragraph kind, and the delegate that picks them and hides closed folds |
| `TranscriptStyle.swift` | AppKit tokens and the press's off-main paragraph renderer |
| `TranscriptTextView.swift` | The one NSTextView (TextKit 2) and its scroll view: menu, pasteboard, keys, hover, folds and the soft edges |
| `TrustActions.swift` | Trust preset presentation and committed policy replies |
| `TurnFace+View.swift` | Session-keyed turn slot reads and rendering of encoded preview images |
| `UpdateController.swift` | Sparkle's native user driver; the body owns checking, download and installation |
| `VoiceInputController.swift` | Operation-scoped renderer dictation; microphone, consent and recognition stay in the body |
| `WindowHaze.swift` | Mac window haze palette, controls and shared `HazeView` presentation |
| `WorkPane.swift` | Pane state and native Make/Sense hosts; shared Steps, Screen facts and read documents |
| `WorkPaneMakeView.swift` | Shared Make page, retained version-bound actions, granted native leaves and checked exports |
| `WorkPaneSenseView.swift` | Shared Sense page and sealed revision-bound WebKit event leaf |
<!-- END GENERATED BLUEPRINT -->

### Models

Directory: `Sources/NativeAgentApp/Models/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentApp/Models/ -->
| File | Owns |
|---|---|
<!-- END GENERATED BLUEPRINT -->

### Chrome Relay

Directory: `Sources/NativeAgentChromeRelay/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentChromeRelay/ -->
| File | Owns |
|---|---|
| `main.swift` | Authenticated Chrome relay; bounded native-message forwarding over the private socket |
<!-- END GENERATED BLUEPRINT -->

### Agent Link

Directory: `Sources/NativeAgentLink/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentLink/ -->
| File | Owns |
|---|---|
| `NativeAgentLink.swift` | `NativeAgentLink`: authenticated bridge framing; credentials stay out of arguments, output and saved state |
<!-- END GENERATED BLUEPRINT -->

## Core Runtime Map

### Package

Directory: `Modules/NativeAgentCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/ -->
| File | Owns |
|---|---|
| `Package.swift` | Core package products, target boundaries and direct dependencies, including the runtime-gated ActivityWatch target |
<!-- END GENERATED BLUEPRINT -->

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/Owned*.swift Modules/NativeAgentCore/Sources/Senses/SensesContract.swift Modules/NativeAgentCore/Sources/Senses/SensesHub.swift Modules/NativeAgentCore/Sources/Senses/SenseNewsBoard.swift Modules/NativeAgentCore/Sources/Senses/Helper*.swift Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift Modules/NativeAgentCore/Sources/Senses/SenseScreenThings.swift -->
| File | Owns |
|---|---|
| `HelperSenseRunner.swift` | Progress supervision, selected-lifetime retirement, source wakes and cancellation-safe receipts |
| `OwnedProgram.swift` | Source and candidate identities, run/face entries and shared monotonic progress-window policy |
| `OwnedProgramCalls.swift` | Static prelude call and argument inspection; unknown expressions retain runtime validation |
| `OwnedProgramJournal.swift` | Request-owned replay, read freshness and receipts; Stop retains each call's actual effects |
| `OwnedProgramPrelude.swift` | Frozen app/host namespaces, preview/version propagation, ordered batches and strict replay |
| `OwnedProgramProcess.swift` | Shared helper process framing, IO and deadlines |
| `OwnedProgramRunner.swift` | `holding`, `endResidents`, `host.state.get/set`, `ReadContent`: resident leases, replay and receipts |
| `OwnedProgramStore.swift` | Sealed candidates, exact rehearsal reuse and publication; `tape: true` replays seal `tape` coverage |
| `SenseDoor.swift` | Registry-first reads, exact captured views and provenance; raw reads stay explicit and acts retain ordinary gates |
| `SenseNewsBoard.swift` | Bounded deduplicated news; checked persistence precedes publication, and each new item is a world happening |
| `SenseScreenThings.swift` | Exact window selections, related-action bindings and in-turn mac.act verbs |
| `SensesContract.swift` | Sense wire records, bounds, origins and provenance contracts |
| `SensesHub.swift` | Owned installation readiness, watch inventory and exact-version provenance |
<!-- END GENERATED BLUEPRINT -->

### ActivityWatch

Directory: `Modules/NativeAgentCore/Sources/ActivityWatch/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ActivityWatch/ -->
| File | Owns |
|---|---|
| `ActivityPolicy.swift` | `ActivityPolicy`, `ActivityPolicyStore`: capture consent, exclusions, title gates and persistence |
| `ActivityQuery.swift` | `ActivityQueries.run`: gated activity reads, current-policy re-filtering, bounded rows and honest truncation |
| `ActivityRetention.swift` | `ActivityRetentionRunner`: checked prune cadence; unavailable state pauses cleanup; completion is durable |
| `ActivityRollups.swift` | `ActivityRollups`: timezone-relative buckets, top apps and exemplars; span overlap is clipped to the requested range |
| `ActivitySpan.swift` | `ActivitySpan` and `ActivityCloseReason`: persisted activity intervals, redacted titles and close vocabulary |
| `ActivitySpanEngine.swift` | `ActivitySpanEngine.process`: capture state transitions, policy gates, source title redaction and store commands |
| `ActivitySpanStore.swift` | `ActivitySpanStore`: per-root acquisition; retention owes compaction until VACUUM and checkpoints succeed |
| `ActivityTitleRedaction.swift` | `ActivityTitleRedaction.redact`: the source boundary that removes secrets before titles enter spans or disk |
| `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`: policy, lifecycle, ordered purge and retention |
| `ActivityWatchPaths.swift` | `ActivityWatchPaths`: private ambient history paths, separate from exported activity event feeds |
| `ActivityWatcher+Foreground.swift` | Workspace/lock events, AX titles, motor provenance and heartbeat/idle; capture-thread callback lifetime |
| `ActivityWatcher+Policy.swift` | Capture-thread policy and purge ordering; external policy may tighten only; deletion follows older writes |
| `ActivityWatcher.swift` | `ActivityWatcher`: capture-thread lifecycle and ordered store pump; only the drained pump releases restart ownership |
<!-- END GENERATED BLUEPRINT -->

### AgentConversations

Directory: `Modules/NativeAgentCore/Sources/AgentConversations/`

ACP agents run as the user and can act directly. Their requested permission
modes are vendor restrictions, not NativeAgent enforcement guarantees;
NativeAgent approval cards cover only requests the agent submits.
`AgentHostConnection.swift` discloses this boundary when connecting an agent.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentConversations/ -->
| File | Owns |
|---|---|
| `AgentA2ACard.swift` | `AgentPeerDiscovery`, `authenticatedInterface`, `a2aCheck`, `listTasks`, `resolve` |
| `AgentACPApproval.swift` | `AgentACPApproval` enum; `connect`, `request`, `job` |
| `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` |
| `AgentContactHealth.swift` | `not_reached`, `repair`, `agent.verify`; Reply health requires exchange evidence. |
| `AgentConversationDelivery.swift` | Delivery states require retained evidence. |
| `AgentConversationExchange.swift` | `AgentConversationExchange`, `started`, `absorb`, `validate` |
| `AgentConversationFollowups.swift` | Queued sends retain order, authority and settlement. |
| `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |
| `AgentConversationLive.swift` | `AgentConversationLive`, `projection` |
| `AgentConversationPersistence.swift` | Checked conversation serialization and projection publication under the existing file lock |
| `AgentConversationPresentation.swift` | Canonical receipt interpretation and retained-history reads through AgentConversationView |
| `AgentConversationRelease.swift` | Release requires positive owner evidence. |
| `AgentConversationReplies.swift` | Locked retained-answer delivery, inline waits and reply settlement on the existing conversation store |
| `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |
| `AgentConversationRunning.swift` | `AgentConversationRunning`, `begin`, `end` |
| `AgentConversationSession.swift` | Conversation admission, approval replay, inline observation and one send settlement. |
| `AgentConversationStore.swift` | Retained conversation identity, send evidence, queue reservations and checked mutations. |
| `AgentConversationView.swift` | Retained send evidence, live progress, queues and conversation presentation. |
| `AgentConversationWaiting.swift` | Waits preserve checked approval and restart evidence. |
| `AgentDiscoverySession.swift` | `AgentDiscoveryCandidate`, `AgentDiscoverySession`, `app.installed` |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter`, `edit`, `grantMessaging`, `removeMessaging`, `checkEntry`, `writeEnvironment`, `ensureEnvironment`, `checking` |
| `AgentHostConnection.swift` | `AgentHostConnection`, `builderWorkspaceRoot`, `isNamedConnect`, `verifySetup` |
| `AgentHostDirectory.swift` | `AgentHostDirectory`, `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`, `installation.evidence`, `executables`, `discoveryWords`, `searchPaths`, `messagingPermissionsPath`, `messagingPermissionSyntax` |
| `AgentJob.swift` | `AgentJob` record, `AgentJobStore` (agents/jobs.json), the `JobRunner` door contract, its refusing stub, `OwnLineRunner` |
| `AgentJobStem.swift` | `AgentJobs`: commission, read, stop, required checks, deliverables and settlement |
| `AgentJobWorktree.swift` | A repo job's own worktree: the cut, its diff captured as the agent's deliverable, the agent's apply and discard |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentMessageFiles.swift` | Admit outgoing files before sending. |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery`, `probe`, `Launch`, `agentProgramLaunch` |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy`, `peerFailure`, `peerAuthorizeInterface` |
| `AgentPeerStore.swift` | `isReady`, `AgentContactHealth`, `list` |
| `AgentPeerTransport.swift` | `AgentPeerCredentials`, `BridgeCore` |
| `AgentRecipeStore+Schema.swift` | Writes require the exact Codable recipe shape. |
| `AgentRecipeStore.swift` | `AgentRecipeStore`, `Resources/agent-hosts.json`, `Resources/grok-routine.json`, `AgentHostDirectory.rows`, `AgentHostRow.A2A`, `recipe(for:)`, `load`, `recipe`, `launch`, `read`, `write`, `learn`; dry-run mode belongs to the explicit conversation operation |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator`, `resolve`, `discard`: one worktree per job |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport`, `listen`, `reconnect`, `stop`, `readiness` |
| `GrokBotRoute.swift` | `GrokBotRoute` enum; `withHistory`, `takenByWaiter`; cancellation ends the waiter handoff without resampling |
| `HelperContact.swift` |  |
| `JSONEntrySplice.swift` |  |
| `JobDoor.swift` | `JobDoors.install`; what every job door shares: its outlet and beat, the envelope broker, what the organ made, its live runs |
| `JobDoorA2A.swift` | `A2AJobDoor`: a job as an A2A task, followed until it ends; its returned artifacts are written into the job's folder |
| `JobDoorACP.swift` | `ACPJobDoor`: a job as one ACP session in the job's folder, `session/request_permission` answered against the envelope |
| `JobDoorClaude.swift` | `ClaudeCodeJobDoor`: stream-json jobs and brokered stdio permission replies |
| `JobDoorCodex.swift` | `CodexJobDoor`, `JobRPC`: a job through `codex app-server` over stdio, one thread in the job's folder |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentConversations diagnostics |
| `PeerTrust.swift` | `PeerTrust` |
| `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |
| `TOMLEntrySplice.swift` | `TOMLEntrySplice` enum; byte-preserving TOML table splicing and ownership fields |
| `Turn+Agents.swift` | `Turn` parts agent conversations own: the person's own send and a person-approved host act |
<!-- END GENERATED BLUEPRINT -->

### AgentLinkTransport

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentLinkTransport/ -->
| File | Owns |
|---|---|
| `AgentA2AGRPC.swift` | `AgentA2AGRPC` enum; `send` projects protobuf framing and yields live updates into the peer exchange's channel |
| `AgentA2APushReceiver.swift` | `AgentA2APushReceiver`, `receive`, `consume`; Push hints wake canonical task reads. |
| `AgentA2AStream.swift` | `AgentA2AStream` enum; `normalize`; shared stream accumulator |
| `AgentA2AWire+Mapping.swift` | `AgentA2AWire`: `canonicalPart`, `wirePart`, `canonicalState` |
| `AgentA2AWire+Operations.swift` | `AgentA2AWire`: `operationRequest`, `operationResult`, `normalizeTaskList` |
| `AgentA2AWire.swift` | `AgentA2AWire`, `selectInterface`, `messageRequest`; One versioned part encoder. |
| `AgentACPClient.swift` | `AgentACPClient`, `startupTimeoutReceipt`, `turn`, `learned`, `Mismatch` |
| `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |
| `AgentACPProcess.swift` | `AgentACPProcess`, `OwnedProcessGroup`; Verified, group-contained launch and settlement. |
| `AgentLineProcess.swift` | `AgentLineProcess`: one approved program speaking line-delimited JSON over stdio, in its own process group |
| `AgentPeerHTTP.swift` | `AgentPeerHTTP` enum; `send` owns the bounded live-update channel and forwarder for either binding; `get` |
<!-- END GENERATED BLUEPRINT -->

### AgentLinkTransport/Generated

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/Generated/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentLinkTransport/Generated/ -->
| File | Owns |
|---|---|
| `a2a.grpc.swift` | `GRPCCore`: `Lf_A2a_V1_A2AService`, `Method`, `SendMessage` |
| `a2a.pb.swift` | `Lf_A2a_V1_TaskState`: `_2`, `Version`, `RawValue` |
<!-- END GENERATED BLUEPRINT -->

### AgentWorkspace

Directory: `Modules/NativeAgentCore/Sources/AgentWorkspace/`

Home navigation behind `app`; this module is not a separate model tool.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentWorkspace/ -->
| File | Owns |
|---|---|
| `AgentContactState.swift` | `AgentPeerStore`, `AgentLocalHealth`, `not_reached`: contact identity and exact health evidence |
| `AgentConversationProjection.swift` | `AgentConversationRecord`, `sendEvidence`, `sendStatus`, `sendFailed`, `sendReceipt`, `AgentConversationExchange.messageID`, `nextReadAt`, `ContactThread.project` |
| `AgentMemo.swift` | `AgentMemo`: checked retained reads, invalidations and turn pins |
| `AgentNamed.swift` | The agent's named room bindings and first-draw state |
| `AgentOpened.swift` | Application-launch attribution; observers close at work end or shutdown; apps still running are a body happening |
| `AgentQueue.swift` | `MyQueueReady` (`due`, `next`, `line`), `AgentScreen.queueContext`, `resume`: checked conditions and moments |
| `AgentRoomCache.swift` | Session-scoped room bindings with bounded lasting item names and current-draw verbs |
| `AgentScreen.swift` | `AgentScreen`, `withNames`, `resolve`: stable names and checked owner projections |
| `AgentScreenPreview.swift` | shared screen/room text projection |
| `AgentScreenRooms+Agents.swift` | `AgentScreen`, `agentsTarget`, `delegationsRoom`: exact owner liveness; crews are the agent's lines |
| `AgentScreenRooms+Build.swift` | `AgentScreen`, `buildRoom`, `buildTarget`, `buildRecordRoom`: partial coverage stays visible |
| `AgentScreenRooms+Comms.swift` | `AgentScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `AgentScreenRooms+Core.swift` | `AgentScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `AgentScreenRooms+Elsewhere.swift` | Moment-only recent exchanges and compact day continuity; private words stay on person turns |
| `AgentScreenRooms+Life.swift` | `workspace-readout.js`, `lifeRoom`, `lifePulse`, `opening`, `AgentItemPages`: exact control/readback evidence |
| `AgentScreenRooms+Web.swift` | `AgentScreen`, `tabName`, `tabTitle`, `webTabCell`: source-label lookup |
| `AgentScreenRooms.swift` | owner-bound room identities; partial pages retain gaps and lock uncertainty |
| `AgentTouched.swift` | commit before publishing retained app facts; preserve unreadable bytes |
| `AgentWorkspace.swift` | `AgentWorkspace`, `dispatch`: owner-routed input; covered partial pages remain usable |
| `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback`, `dispatchEffect`, `followUp`: exact-recipient readback without replay |
| `AgentWorkspaceActivity.swift` | owner reads preserve availability, groups and paging |
| `AgentWorkspaceApps.swift` | `AgentWorkspaceApps` enum; `quickAction`, `project` |
| `AgentWorkspaceArrivals.swift` | `AgentWorkspaceArrivals` enum; `pending`, `hash` |
| `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: `observationStamps`, `observe`, `bindCurrent` |
| `AgentWorkspaceChanges.swift` | `AgentWorkspaceChanges`, `evaluate`, `evaluateHumanListing`: source-stamped conversation change evidence |
| `AgentWorkspaceConversation.swift` | `AgentWorkspaceConversation` enum; `project` |
| `AgentWorkspaceConversations.swift` | `AgentWorkSession`, `AgentScreen.conversationsRoom`: verified sessions; owner-rendered threads |
| `AgentWorkspaceDesktopNavigation.swift` | `AgentWorkspaceNavigation`, `restoredSession`, `canEvict`, `draftAttemptIsDurable`: durable drafts |
| `AgentWorkspaceDesktopStore.swift` | `AgentWorkspaceDesktopStore`, `load`, `save`: checked v2 desktop; preserve damaged bytes |
| `AgentWorkspaceEnvironment.swift` | `AgentWorkspaceEnvironment` enum; `isStatusReader`, `title` |
| `AgentWorkspaceFileRevision.swift` | `AgentWorkspaceFileRevision` struct; `prepare` |
| `AgentWorkspaceFind.swift` | `project`: exact owner identities precede topic search |
| `AgentWorkspaceForm.swift` | `AgentWorkspaceForm` struct; `readingHelperSettings`, `withSchemaIssue` |
| `AgentWorkspaceHumanProjection.swift` | `HumanConversationRead` enum; `read`, `project` |
| `AgentWorkspaceKnowledge.swift` | `AgentWorkspaceKnowledge` enum; `project`, `memoryTitle` |
| `AgentWorkspaceLocation.swift` | `AgentWorkspaceDocument`: source-bound navigation evidence |
| `AgentWorkspaceMail.swift` | `AgentWorkspaceMail`: retain partial account coverage and continuation |
| `AgentWorkspaceMessages.swift` | `AgentWorkspaceMessages` enum; `project` |
| `AgentWorkspaceNavigation.swift` | `AgentWorkspaceNavigation`, `Session`: root/scope-bound arrangement; no duplicate ledger |
| `AgentWorkspaceOverview.swift` | `AgentWorkspaceNavigation`: `windowTitle`, `windowAction`, `window` |
| `AgentWorkspacePorts.swift` | `AgentWorkspacePorts`: native ports retain authority and delivery stamps |
| `AgentWorkspaceProjection.swift` | `WorkspacePage`, `project`, `AgentWorkspace`: owner-routed pages and read bindings |
| `AgentWorkspaceReadiness.swift` | `AgentWorkspaceReadiness` enum; explicit operation permission evidence through `withSnapshot`, `filter` |
| `AgentWorkspaceSavedReply.swift` | `AgentWorkspaceSavedReply` struct; `title`, `evidence` |
| `AgentWorkspaceWork.swift` | `AgentWorkspaceWork` enum; `desk`, `continuation` |
| `AgentWorkspaceWorkOverview.swift` | `AgentWorkspaceNavigation`: `workReceiptKey`, `placeAction`, `focusWork` |
| `AgentWorld.swift` | Retained owner projections; asks read ForPerson's inbox, thoughts and owed happenings the record, no second cache |
| `BodyQueue.swift` | `BodyQueue`, `BodyFinding`, `file`, `resolve`, `fold`: stable finding identities |
| `CarriedHabits.swift` | `CarriedHabits`: bounded trials; daily offers never bind |
| `DelegationCaches.swift` | Read acceleration over unchanged file stamps |
| `DelegationReadout.swift` | retain source availability and distinct delivery/execution times |
| `DelegationStatusProjection.swift` | Retained reply deliveries; an unreadable record is its own gap and readable siblings proceed |
| `FamiliarLines.swift` | `FamiliarLines`, `mind/familiar.bin`: first encounters alone prime recall |
| `HomeFace+Rows.swift` | Home's sections as keyed facts with the stem's verdict codes; approvals and the night's trials as the person's levers |
| `HomeFace.swift` | Home's packet for `native-home`: world parts as keyed facts, thoughts, owed, attention; lifetime and gaps |
| `HumanConversationIndex.swift` | bounded human index; unavailable source/revision never invents provenance |
| `IntentionClock.swift` | `IntentionClock`: a MY QUEUE rhythm's occurrences from its own anchors, grace and end |
| `MacScreenPreviewBus.swift` | Shared masked screen previews, capture geometry and bounded read text; source replacement clears stale content. |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentWorkspace diagnostics |
| `MyQueueCarried.swift` | MY QUEUE's per-moment run reservations and owed Desk settlements. |
| `SurfaceLayoutStore.swift` | `SurfaceLayoutAvailability`, `SurfaceLayoutLive`, `read`, `write`, `setSurfaceExpanded`, `LatestRead` |
| `ToolSignature.swift` | `call`, `doorArgs`: checked argument shapes |
| `TrialLevers.swift` | `TrialLevers`: the night's trials as the person's levers, one producer for every page that draws them (Home, Today) |
| `Turn+Workspace.swift` | `Turn` part the workspace owns: the turn's screen-preview sink |
| `WorkContextQuery.swift` | `WorkContextQuery` struct; `matchedTerms`, `score` |
| `WorkspaceMacCall.swift` | Workspace-owned Mac calls refuse reading the agent's own app |
| `WorkspaceReadout.swift` | `workspace-readout.js`: native bindings and authority |
<!-- END GENERATED BLUEPRINT -->

### Agents

Directory: `Modules/NativeAgentCore/Sources/Agents/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Agents/ -->
| File | Owns |
|---|---|
| `AgentBridgeCompletionRouter.swift` | `AgentBridgeCompletionRouter`, `validatedRoute`, `deliverAnswer` |
| `AgentBridgeSurface.swift` | Peer framing grants no authority. |
| `AgentContactHeldAnswer.swift` | `AgentContactHeldAnswer`: a contact's answer held as its one send row for the conversation store to deliver |
| `AgentContactRoutes.swift` | Authenticated ingress shares retained task ownership. |
| `AgentContactTaskCallbacks.swift` | Durable callbacks retain per-task recovery debt. |
| `AgentContactTaskReceipts.swift` | SQLite owns checked task receipts and payload debt. |
| `AgentContactTaskValues.swift` | Execution and payload debt remain distinct. |
| `AgentContactTaskWire.swift` | A2A wire projection of retained task and stream facts |
| `AgentContactTasks+Bridge.swift` | Builder ingress shares retained task admission. |
| `AgentContacts.swift` | One root owns contact execution and delivery. |
| `AgentConversationContinuation.swift` | Read delayed replies without resending. |
| `AgentPeerReplayClaimStore.swift` | `AgentPeerReplayClaimStore` |
| `BridgeLane.swift` | `BridgeLane`: bridge surface spelling and agent-authorship classification, without assigning identity or effect authority |
| `ChatGPTDotConversation.swift` | `ChatGPTDotConversation`, `refresh`, `conversation`, `TurnAdmission` |
| `ClaudeBridgeDebug.swift` | Authenticated organism debug routes using the listener's existing request claim and response latch |
| `ClaudeBridgeMessageRuntime.swift` | HTTP waits never own accepted turns. |
| `ClaudeBridgeOperations.swift` | Message and tool endpoint execution under the existing listener admission and actual-exit worker lifetime |
| `ClaudeBridgeRuntime.swift` | Retain accepted work until exit; connections own passive reads. |
| `ClaudeBridgeStateProjection.swift` | Bridge state; recent notes read ForPerson's in-memory inbox and retain read failures |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` |
| `DesktopAgentConversationRoute.swift` | `Resources/abilities/desktop-courier.js`, `Parts.call` |
| `DesktopChatRoute.swift` | `accessibility_permission_missing`, `settle`; Non-main recipe-bound sends retain uncertainty and settlement. |
| `DesktopRouteObservation.swift` | Sendable observation owns locked wake state; AX and workspace events wake cancellable desktop waits. |
| `GrokBotConnection.swift` | Uncertain setup never authorizes resend. |
| `GrokDesktopReply.swift` | `settle`; Correlate replies through AX transcript and idle evidence and retain cancellable waits. |
| `GrokInboundReply.swift` | `TurnAdmission.admittedRun`, `settle`; Claim and retain handovers through actual exit. |
| `GrokRoutineAccessibility.swift` | Non-main native setup and sends; secret values and clipboard settlement stay native. |
| `HumanConversationReplyService.swift` | `HumanConversationReplies.reply` |
| `MindStream.swift` | Thoughts including the hour's opportunity, commissioned returns and the night's reading |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Agents diagnostics |
| `NativeAgentA2AGRPCListener.swift` | Retain listener ownership through graceful drain. |
| `NativeAgentA2AGRPCService.swift` | gRPC authentication, protocol/error projection and acknowledged stream delivery |
| `NativeAgentA2AWire+Parts.swift` | A2A content validation; file byte ceiling comes from Shared's `ChatAttachmentTypeResolver` |
| `NativeAgentA2AWire+Push.swift` | `AgentContactCallback`, `AgentContactPushConfig` |
| `NativeAgentA2AWire+REST.swift` | `AgentContactA2AEndpoint.handleREST` |
| `NativeAgentA2AWire+Runtime.swift` | Shared admission and canonical reply framing. |
| `NativeAgentA2AWire+Tasks.swift` | Accepted workers retain canonical task ownership. |
| `NativeAgentA2AWire.swift` | A2A bindings use contact task workers and a dedicated gRPC listener; turns execute through shared chat |
| `NativeAgentMCPWire.swift` | MCP negotiation, parsing, caller-supplied request identity and reply projection |
| `OwnLineDoor.swift` | `OwnLineDoor`: agent.job self runs a turn of the agent's in its own work conversation, admitted like any turn |
<!-- END GENERATED BLUEPRINT -->

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AppToolRuntime/ -->
| File | Owns |
|---|---|
| `AppAction.swift` | Action declarations, folded gates, argument policy and effect receipts |
| `AppActionRegistry.swift` | One native/authored/guidance/sense inventory and policy bindings |
| `AppActions+AgentPageVerbs.swift` | Owner page commands for Desk, memory, Graph, identity and helpers |
| `AppActions+CardVerbs.swift` | `AppActions.cardVerbs` (a card's answers are the declared `inbox.*` and `card.*` verbs) and `AppToolExecutor.personDecided`, the one admission of the person's own act in the inbox and card handlers |
| `AppActions+Contracts.swift` | Argument shapes, dependency flags and canonical live contracts |
| `AppActions+Declarations.swift` | Seed actions, owner schemas, fixed input and hot-action vocabulary |
| `AppActions+Discovery.swift` | Guides, schema constraints, examples and scalar-list discovery |
| `AppActions+KeptParts.swift` | Bounded kept-part glance |
| `AppActions+ProvidersConnectorsCapabilitiesVerbs.swift` | The verbs the rows of Providers, Connectors (Telegram, iPhone, agents) and Capabilities call that no other verb runs; each is a `connections` host verb running the code its row ran |
| `AppActions+Ranking.swift` | Exact ids/pages precede checked semantic matches; item gaps stay local |
| `AppActions+TrustSettingsVerbs.swift` | The verbs Trust's and Settings' rows call beyond `setting.set` and the existing backup, history and grant verbs: the Mac's own buttons, each the person's lever where it needs the person at the Mac |
| `AppChatToolDispatcher.swift` | `withAuthoredProgramHost`; Gated dispatch and settled-result observation |
| `AppDoorActions.swift` | Shared admission, previews and typed receipts; accepted matters supply the call's knock count |
| `AppDoorPrograms.swift` | Ordered gated calls; a failed, waiting or unexpected step bars later changes, not reads or cleanups; their `then_say` stands only when the deed came back wholly as said |
| `AppDoorReading.swift` | Home/page/item/find reads; call-fit census independent of admission |
| `AppScriptRunner.swift` | Gated program host, live contracts and shared normalization |
| `AppToolExecutor+AppDoor.swift` | `app`, `visible`, `undo`; App dispatch, version recovery and action-owned undo |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpCheck`; one transient Screen preview after a Chrome door call, masking returned pictures locally from capture-relative geometry or showing the background read's served text without recapture; follow-ups stop on Trust receipt failure; Chrome internal reads return one text line with read_mode none; chrome.look and DOM-inaccessible Chrome/PDF snapshot reads deliver the owned tab's bounded picture through the shared file-reader image slot, with source dimensions, explicit picture mode, independent debugger cleanup errors and raw Chrome provenance; PDF text remains unread with no independent fetch; action readback preserves non-DOM receipts; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`, `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall`; observed-field batches |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+Make.swift` | `AppToolExecutor`; Studio versions, intake and workspace-fenced reply images |
| `AppToolExecutor+MyQueue.swift` | `runMyQueue`, `runHouseFile`; Exact-id intentions, schedules, habits and closure receipts |
| `AppToolExecutor+PagePresentation.swift` | screenshot results, quiet page reads, and a door-only page's read (summary, actions, Trust's access rows) |
| `AppToolExecutor+PartRun.swift` | Part admission, previews, stopped-run checkpoints, Desk reservations and result settlement |
| `AppToolExecutor+Photos.swift` | `AppToolExecutor`, `runPhotosRead`; Read-only PhotoKit metadata and permission remedies |
| `AppToolExecutor+QuietMind.swift` | Owner previews precede bootstrap and effect callbacks |
| `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`, `performMacSelfAppRoute`, `behind`, `quietPosture`, `freshQuietPosture`; posture |
| `AppToolExecutor+SenseMake.swift` | `AppToolExecutor`; Author captured material under owner-off authority |
| `AppToolExecutor+Senses.swift` | Sense corner reads, served verb discovery and gated in-turn acts |
| `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`, `appToolSchemas`; Lazy door schema avoids registry initialization cycles |
| `AppToolExecutor+UpkeepTarget.swift` | backup restore target validation |
| `AppToolExecutor.swift` | Platform routing and canonical effect owners; phone sends and chat.post knocks tell one matter |
| `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |
| `AppToolPorts.swift` | `AppActionExecution`, `BrowserToolPlatformPort`, `QuietToolPresentationPort`: operation ports |
| `ChromePageText.swift` | `ChromePageText`, `VisiblePageText`, `project`, `rows`, `next`, `contentVersion`; shared text, rows and versions |
| `DoorNotesSnapshot.swift` | Script-owned inbox snapshot and nested batch versions, handed through `AppActionExecution` |
| `ExistingCornersReaders.swift` | `ExistingCornersSourceProvider`, `ExistingCornerReadOperation`, `NativeChromeNews`, `SenseNewsBoard`: gated |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AppToolRuntime diagnostics |
| `NativeActionRoutes.swift` | `NativeActionRoutes`, `runNativeAction`, `swiftNativeActionRecords`; canonical native receipts |
| `NativeAgentNotificationPostResult.swift` | Re-exports `AttentionRouting` notification result contracts |
| `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |
| `NativeSkillRegistryActions.swift` | owner-facing enable through `Parts`; `enableSkill` |
| `PartThoughtTools.swift` | Part thought shares the originating ToolHost and gate chain; retains uncertain effects |
| `PhoneSensesGuide.swift` | Pairing guide reads canonical phone evidence and per-organ setup |
| `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; Shared checked view and appearance preferences |
| `QuietChatSessionCommands.swift` | `QuietChatSessionCommands`; Effect-free fences and canonical session receipts |
| `QuietComposerCommands.swift` | `QuietComposerCommands`; Composer commands share preview and execution fences |
| `QuietInboxCommands.swift` | `QuietInboxHost`; tap/message authority and receipts; committed effects survive unknown readback |
| `QuietSelfAdminSettings+LowerOnly.swift` | Lower-only rows enforce subsets under the authority lock; Slack rows share an asynchronous checked policy per read and refresh it for mutations |
| `QuietSelfAdminSettings.swift` | Shared authority/validation and platform settings catalog |
| `QuietSetting.swift` | Throwing read/choice contract, explicit turn-bound writes, checked Trust and MainActor receipt detail |
| `QuietSettings+BotSchedules.swift` | Bot cadence rows; mutation rereads canonical definitions |
| `QuietSettings+Models.swift` | Group model/account/effort transactions retain inheritance |
| `QuietSettings+Navigation.swift` | Settings navigation labels from the canonical registry with off-main discovery |
| `QuietSettings+Personality.swift` | Profile-owned name and checked-Trust dream controls |
| `QuietSettingsHost.swift` | Settings owner ports, mounted platform control declarations and asynchronous phone-owned control resolution |
| `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |
| `QuietTrustPolicyPreset.swift` | `MobileTrustAction.Preset` policy plans, locked save and effective-policy matching |
<!-- END GENERATED BLUEPRINT -->

### ApprovalInbox

Directory: `Modules/NativeAgentCore/Sources/ApprovalInbox/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalInbox/ -->
| File | Owns |
|---|---|
| `ApprovalContinuations.swift` | Reporting claims retain delivery ownership. |
| `ApprovalExecutionOwners.swift` | Shared approval execution claims and retained outcome settlement for coordinator and resident drain |
| `ApprovalInbox+ChatReceipt.swift` | Approval receipt rows and healing order; transcript bytes are written through ContactThread |
| `ApprovalInbox+EffectSpend.swift` | `SwiftNativeApprovalInbox`; Durable spend fences replay, not outcome. |
| `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `loadSpends` |
| `ApprovalInbox+RestoreFences.swift` | `SwiftNativeApprovalInbox.mergeRestoreFences`; Monotonic restore merge. |
| `ApprovalInbox+SkillScriptInstall.swift` | `SwiftNativeApprovalInbox.askUserToInstallScript`; Exact-digest reviews. |
| `ApprovalInbox.swift` | Checked approval authority; its decision experience is born as a matter with its doors, then only appended |
| `ApprovalLifecycle.swift` | `ApprovalLifecycleBus`; Post-commit fan-out, no decision authority. |
| `ApprovalRecord.swift` | Approval substance, checked origin doors and decision faces; the person's resolution provenance owns authority. |
| `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`; Match grant, spend and effect. |
| `ApprovalStorage.swift` | Checked canonical approval storage |
| `ApprovalWords.swift` | `ApprovalWords.call`: a tool call in the person's words, the act and what it does, for the card that asks them |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ApprovalInbox diagnostics |
<!-- END GENERATED BLUEPRINT -->

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalTransactions/ -->
| File | Owns |
|---|---|
| `ApprovalChatCards+Interactions.swift` | Conversation mirrors and Telegram receipts read the matter's doors; every answer settles the origin |
| `ApprovalChatCards.swift` | The one mirror: an ask whose matter owes the person's conversation gets its card row there, then that door is accepted with the row |
| `ApprovalReconciliation.swift` | Approval execution reconciliation and Desk settlement |
| `ApprovalReplay.swift` | Exact chat tool approval replay interpretation |
| `ApprovalSettlement.swift` | Provenance checks precede spend; receipts precede continuation. |
| `ApprovalSubjects.swift` | Domain outcomes feed shared settlement. |
| `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects`, `ApprovalExecution.approvedEffectTurn` |
| `ApprovalTransactionCoordinator.swift` | Shared tap or person-message authority; approval execution retains outcomes until receipt settlement |
| `BrowserApprovalExecution.swift` | Retain returned browser outcomes until receipted. |
| `ConnectorApprovalExecution.swift` | Connector approval replay and verified execution |
| `DeskClickApprovalFiler.swift` | Package-scoped local-click approval filing under `ApprovalTransactions` |
| `InboxCardActions.swift` | Inbox actions change the matter's reading; putting away an open ask first declines through its resolver |
| `InlineDecisions.swift` | Owner-backed controls and honest receipts. |
| `InlineInteractionContinuation.swift` | Claim before replay; settle after Stop. |
| `InlineInteractionDelivery.swift` | Transcript-owned asks file one matter with origin doors; inbox pointers read ForPerson |
| `InlineInteractionPersistence.swift` | Checked same-row persistence and originating envelopes |
| `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort`; Platform effects, resolver authority. |
| `InlineInteractionResolver+ChatLifecycle.swift` | `InlineInteractionResolver`; Verify control effects. |
| `InlineInteractionResolver+MissingProvider.swift` | `InlineInteractionResolver.raiseMissingChatProvider`; Text-only resume. |
| `InlineInteractionResolver.swift` | Transcript CAS owns answers; asks are matters born with origin doors and verified answers settle decide |
| `InlineInteractionVerification.swift` | Canonical owners alone confirm completion. |
| `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |
| `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedKindBackfill`, `stageKindBackfillIfNeeded` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ApprovalTransactions diagnostics |
| `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |
| `REMLessonOrigin.swift` | `REMLessonOrigin`; Idempotent origins preserve source disclosure. |
| `TelegramApprovalCoordinator.swift` | Telegram prompt transactions and the Inbox row's buttons, answers and delivery receipts. |
| `Turn+Approvals.swift` | `ApprovalResolutionProvenance.resolvingTurn`: tap envelopes; message records recreate no person authority |
<!-- END GENERATED BLUEPRINT -->

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AttentionRouting/ -->
| File | Owns |
|---|---|
| `AttentionDeliveryPorts.swift` | Host ports classify delivery; phone receipts never imply acceptance |
| `AttentionFacts.swift` | Shared transport verdicts drive attention; queued or absent evidence never proves acceptance |
| `AttentionRouter+HeldDelivery.swift` | Release ForPerson's owed deliveries; retain failed observation results |
| `AttentionRouter+MacNotifications.swift` | Mac banners: UI-physics posts, and the Mac door's post whose OS callback settles its delivery |
| `AttentionRouter+MemoryReview.swift` | Memory-review crossing tells one Mac matter; dropping below threshold resolves that matter |
| `AttentionRouter+Policy.swift` | The person's doors from the person's rulings (phone always, the thread it came from, the Mac while the person is at it); quiet hours |
| `AttentionRouter+RequestedResults.swift` | Result and bot-condition matters; transcript acknowledgement follows every door's acceptance |
| `AttentionRouter.swift` | One matter reaches the person's doors through ForPerson's delivery obligations |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AttentionRouting diagnostics |
| `NativeAgentNotificationActions.swift` | `NativeAgentNotificationActions` |
| `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult`: confirmed native delivery fields |
| `NativeAgentScheduledProactiveScan.swift` | Checked source opportunities; ProactiveScanArguments owns admission and execution |
| `TriggerNotificationDelivery.swift` | Deliver the trigger's already-filed obligations; no second tell or separate occurrence |
<!-- END GENERATED BLUEPRINT -->

### BackgroundLoops

Directory: `Modules/NativeAgentCore/Sources/BackgroundLoops/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/BackgroundLoops/ -->
| File | Owns |
|---|---|
| `BackgroundLoopWakes.swift` | BackgroundLoopLifetimes listeners, wake coalescing, clock invalidation, deadlines and settlement |
| `BackgroundLoops.swift` | SwiftNativeLoopScheduler registrations, timing, backoff and worker lifecycle; LoopTickAccounting settlement |
| `BackgroundLoopsManager.swift` | BackgroundLoopLifetimes registration, execution, status, resident observation and lifecycle settlement |
| `ErrorFeeds.swift` | `ErrorFeeds`: shared live error-feed inventory and bounded recent-burst scans with explicit read/integrity availability |
| `LoopContracts.swift` | LoopRunner and event/deadline contracts, registrations, outcomes, backoff policy and bounded tick execution |
| `LoopFailureReceipts.swift` | Loop failure occurrence details, read-time incident folding, classification and result accounting |
| `LoopHistory.swift` | SwiftNativeLoopScheduler durable run/completion history, first-seen stamps, organ pulses and ordered checkpoints |
| `LoopStatusEvidence.swift` | WatchdogStatus wire encoding, scheduler LoopState, LoopStatus and event-listener health evidence |
| `ManagedLoopRunner.swift` | LoopExecutionGate and ManagedLoopRunner: serialize each registration until body exit and accounting settle |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundLoops diagnostics |
| `PhysiologySelfWriteRegistry.swift` | `PhysiologySelfWriteRegistry`: generation-based echo suppression without hiding external writes |
<!-- END GENERATED BLUEPRINT -->

### BackgroundWork

Directory: `Modules/NativeAgentCore/Sources/BackgroundWork/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/BackgroundWork/ -->
| File | Owns |
|---|---|
| `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient`, `complete`, `streamMessages`, `servingProviderID`, `recall_judge`, `memory_interpret`, `memory_held`, `kind_backfill` |
| `BackgroundWorkLease.swift` | `BackgroundWorkLease` actor; persisted window claims and release of the holder’s newest unused claim |
| `BackgroundWorkPorts.swift` | Body notices tell one matter through the attention port; episode identity and owner resolution read ForPerson |
| `BodyReport.swift` | Crash breadcrumb paths and fatal-signal/process-exit logging |
| `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork`, `makeTelegramChatHandler`, `fileSystemPermissionNotice`; chat delivery |
| `DataRootDiskHygiene.swift` | Disk matters point to locked saved cleanup offers; reclamation settles its receipt |
| `DelegationBackgroundWork.swift` | Delegation matters roll up canonical jobs; handled outcomes read their recorded claims |
| `DelegationOutcome.swift` | Owner-proven terminal outcomes; durable cursor progress requires card settlement |
| `DelegationOutcomeCard.swift` | One stable delegated-job inbox card and grounded resident wake text |
| `DelegationOutcomeCursor.swift` | Exact durable handled identities and receipt versions; advances only after corresponding card settlement |
| `DelegationOutcomeLoop.swift` | One delegation reconciliation/settlement runner; dry runs advance without a card or delegation settlement |
| `DeskNotifyRunner.swift` | Desk matters and nags; ForPerson changes arm the quiet-window end deadline, which releases owed doors |
| `DoctorAutoRunLoop.swift` | Doctor asks are episodes in ForPerson; measured source checks clear them |
| `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; Health and schedule rules |
| `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |
| `DreamBackgroundWork.swift` | Dream and REM settlement; care and growth approvals tell their one ForPerson face |
| `DreamSurprises.swift` | `makeDreamSurpriseProvider`, `SurpriseReading`; CPU-only owner-attributed surprise for the dream and the night |
| `HeartbeatAssessment.swift` | Heartbeat assessment, notice and action values consumed by the existing work and loop owners |
| `HeartbeatBackgroundWork.swift` | Existing heartbeat work binding, event/deadline loop construction and age limits |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `HeartbeatDurableResidue.swift` | Durable residue tells an inbox-only episode; incomplete inventory never clears it |
| `HeartbeatHealthAssessment.swift` | Heartbeat health from owner-reported conditions; time windows project recorded evidence |
| `HeartbeatLoop.swift` | Event/deadline heartbeat checklist lifetime and per-condition notice settlement; missing checklist claims no health |
| `HeartbeatNoticeCards.swift` | Heartbeat condition episodes are matters; measured clearance resolves them without another alert |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundWork diagnostics |
| `OffDiskBackupRunner.swift` | `MaintenanceBackgroundWork.makeOffDiskBackupLoop`; Native metadata, root protection and copying |
| `TelegramBackgroundBridges.swift` | Telegram memory-write bridge through the canonical memory owner |
| `UnattendedWork.swift` | `UnattendedWork.allowed`: the one admission for work the agent does while nobody is watching |
<!-- END GENERATED BLUEPRINT -->

### Browser

Directory: `Modules/NativeAgentCore/Sources/Browser/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Browser/ -->
| File | Owns |
|---|---|
| `Browser+ActiveRuns.swift` | process-local run cancellation registry and attachment latch |
| `Browser+MotorReadModel.swift` | `SwiftNativeBrowserClient.motorActionReadModel`: canonical payload-free projection |
| `Browser+OperationStore.swift` | Canonical run/outbox owner; preserve damaged rows; exclude backup/export/phone sync |
| `Browser.swift` | Owner recovery and damaged-run status; capture paths; WebKit owns website data |
| `BrowserActionRoutes+DOM.swift` | DOM reads use one 3750ms deadline; cleanup and decoding preserve unknown outcomes |
| `BrowserActionRoutes+IPC.swift` | authenticated IPC route decisions over window effects |
| `BrowserActionRoutes+NativeActions.swift` | `runBrowserNativeAction` and `stringInput`; previews retain no artifacts |
| `BrowserActionRoutes.swift` | Canonical claims settle every exit; previews stay in memory; `retainRead` owns exact captures |
| `BrowserCaptureCache.swift` | `BrowserCaptureCache`: bounded grouped artifact eviction; expired captures require new observation |
| `BrowserIPCServer.swift` | Authenticated discovery precedes admission; failed publication stops listening; deadlines retain uncertainty |
| `BrowserLink.swift` | `BrowserLink` struct |
| `BrowserRouteEffects.swift` | visible browser port; shared begin/finish/cancel lifecycle over BrowserActiveRunRegistry |
| `BrowserRouteModels.swift` | `BrowserRun`, `NativeActionReceipt`; failed navigation receipts expose the retained openError as detail |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Browser diagnostics |
<!-- END GENERATED BLUEPRINT -->

### ChatSessionWork

Directory: `Modules/NativeAgentCore/Sources/ChatSessionWork/`

Quiet never ends what they holds. A conversation is held whole until the request
reaches the input budget; then the oldest whole turns go in half-budget jumps.
The input budget is min(model window minus response allowance, 200,000 tokens).
History fitting uses the input budget; refusal and result pointers use model
window minus response allowance, the physical limit.
`SessionHistoryMessages.admission` admits the whole conversation.
`SessionHistoryTail` derives checkpoints from cumulative replay row sizes from
the transcript's start, without a stored cut pointer. Every composed request
selects leads only from rows outside its held replay and recent receipts.
Transcript bytes stay intact. Resident and
helper rounds retain overflowing oldest result bodies before delivering file
pointers, with no generated summary. `ContextBudgetPolicy` retains memory,
packet, capsule and relevance duties. `ConversationHistory` retains exchange
pairing, provenance, experience resolution and dream marks. The
[conversation context contract](conversation-context-history.md) owns the law.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatSessionWork/ -->
| File | Owns |
|---|---|
| `ChatSecretRedactor.swift` | `ChatSecretRedactor` typealias |
| `ChatSessionDirective.swift` | `ChatSessionDirective.recordURL`. |
| `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` selects repairs and commits through ChatSessionIndexFile |
| `ChatTranscriptEvidenceRendering.swift` | ChatTranscriptEvidenceRendering owner. |
| `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |
| `ContextBudgetPolicy.swift` | ContextBudgetPolicy owner. |
| `ContextWindowPolicy.swift` | Context-window readout from the powering model's verified default. |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatSessionWork diagnostics |
| `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore`, `record`, `recordConversationContinuation`. |
| `OutcomeTissueV2.swift` | `OutcomeEvidenceState` enum |
| `OutcomeTraceIdentity.swift` | `OutcomeTraceIdentity` enum; `normalized` |
| `PriorChatSession.swift` | Participant-bound previous conversation lookup for transcript recall. |
| `SentTurnContext.swift` | SentTurnContext owner. |
| `SessionContextMeasurement.swift` | SessionContextMeasurement owner. |
| `SessionContextRequest.swift` | SessionContextRequest owner. |
| `SessionHistoryMessageProjection.swift` | `admission`, `project`. |
| `SessionHistoryPromptRenderer.swift` | `renderDetailed`, `recallQuery`. |
| `SessionHistoryReader.swift` | `SessionHistoryReader`, `messages`, `messagesWithStats`. |
| `SessionHistoryTail.swift` | Stateless whole-turn checkpoints from the admitted replay and its row sizes. |
| `SessionMessageProvenance.swift` | `SessionMessageProvenance` |
| `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearchResult`, `TranscriptSearchResponse`, `TranscriptSearch` |
<!-- END GENERATED BLUEPRINT -->

### ChatToolParsing

Directory: `Modules/NativeAgentCore/Sources/ChatToolParsing/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatToolParsing/ -->
| File | Owns |
|---|---|
| `ChatToolOutcome.swift` | `projection`: shared outcome evidence |
| `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |
| `ToolResult.swift` | `ToolResult`: parse replies once for core decisions; retain the JSON payload for the model, transcript and trace |
<!-- END GENERATED BLUEPRINT -->

### ChatToolRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatToolRuntime/ -->
| File | Owns |
|---|---|
| `AgentContactACP.swift` | Approve current executable identity before peer launch. |
| `AgentContactCancellation.swift` | Contact transport cancellation and unknown outcomes |
| `AgentContactCommand.swift` | Keep launch, reply and delivery evidence distinct. |
| `AgentContactConnection.swift` | Read one checked peer snapshot; preserve committed setup evidence. |
| `AgentContactPresentation.swift` | Retained contact and conversation history projection |
| `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding`, `pending`, `glance`: Bind owner ports without copying authority. |
| `AppRestartCoordinator.swift` | Wait for exit before relaunch; bound stalled settlement and quit. |
| `BodyDecidedRow.swift` | Rolling decision matters keep their count on the face; settled rollups get new identities |
| `BotChatContract.swift` | Follow Chat unless pinned; reject conflicting settings. |
| `BotRunConversation.swift` | `BotRunConversation` enum; `enqueueRequestedCheck`, `dispatch` |
| `BuilderAudit.swift` | Redacted builder audits and bounded retention |
| `BuilderInstaller.swift` | Installer launch, helper lifetime and settlement |
| `BuilderPatchExecution.swift` | Patch admission and native execution through the dispatcher |
| `BuilderPatchGrammar.swift` | Patch grammar, path authority and range-less application |
| `BuilderProcess.swift` | Checked workspace and required SwiftPM shim admission before process launch; environment and confinement |
| `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas` |
| `BuiltInToolSchemaFactory+CollaborationSchemas.swift` | `BuiltInToolSchemaFactory`, `collaborationSchemas`: Shared work schemas. |
| `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
| `BuiltInToolSchemaFactory+DeskSchemas.swift` | `BuiltInToolSchemaFactory`: `deskSchemas` |
| `BuiltInToolSchemaFactory+DreamSchemas.swift` | `BuiltInToolSchemaFactory`: `dreamSchemas` |
| `BuiltInToolSchemaFactory+FileSchemas.swift` | `BuiltInToolSchemaFactory`: `fileSchemas`, canonical `context_expand` descriptor |
| `BuiltInToolSchemaFactory+HistorySchemas.swift` | `BuiltInToolSchemaFactory`: `historySchemas` |
| `BuiltInToolSchemaFactory+InnerStateSchemas.swift` | `BuiltInToolSchemaFactory`: `innerStateSchemas` |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |
| `BuiltInToolSchemaFactory+MemorySchemas.swift` | `BuiltInToolSchemaFactory`: `memoryReadSchemas`, `memoryWriteSchemas`, `memoryReviewSchemas` |
| `BuiltInToolSchemaFactory+PersonaSchemas.swift` | `BuiltInToolSchemaFactory`: `personaSchemas` |
| `BuiltInToolSchemaFactory+PersonalAppSchemas.swift` | `BuiltInToolSchemaFactory`, `personalAppSchemas`: Owned app schemas. |
| `BuiltInToolSchemaFactory+SchedulerSchemas.swift` | `BuiltInToolSchemaFactory`: `schedulerSchemas` |
| `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |
| `BuiltInToolSchemaFactory+StudioSchemas.swift` | `BuiltInToolSchemaFactory`, `studioSchemas`: Canon stays agent-owned. |
| `BuiltInToolSchemaFactory+TurnSchemas.swift` | `BuiltInToolSchemaFactory`, `turnSchemas`: Bound turn controls. |
| `BuiltInToolSchemaFactory+WebSchemas.swift` | `BuiltInToolSchemaFactory`: `webSchemas`: maps, routes, web search and page reads |
| `BuiltInToolSchemaFactory+WorkspaceSchemas.swift` | `BuiltInToolSchemaFactory`: `workspaceSchemas` |
| `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory`, `schemas`, `requestedSchema`, `PersistenceCore.ToolSchema`: Lazy schemas. |
| `CanonicalToolNameDispatcher.swift` | Canonical dispatch; records non-Inbox calls before execution for message decisions |
| `ChatHistoryIndex.swift` | Content hashes deduplicate reads; SQLite owns cold rows and receipts. |
| `ChatHistoryMessage.swift` | Keep selected-transcript gaps explicit. |
| `ChatHistoryProjection.swift` | Persisted row and explicit receipt projection; ordinary turn recall never injects tool metadata |
| `ChatToolDispatchTrace.swift` | `ChatToolDispatchTracer`, `isPreview`: Preserve redacted failure evidence. |
| `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction`, `redactedResultJSON`: Redact before preview bounds. |
| `ChatToolOutcome.swift` | `ChatToolOutcome`: Share exact classification; preserve effect and repair evidence. |
| `ChatToolRuntimeImports.swift` | Re-exports `ChatTurnContracts`, `AgentConversations`, `AgentWorkspace`, `ChatSessionWork`, `ChatToolParsing` |
| `ChatToolSessionInjection.swift` | `ChatToolSessionInjection`: Caller input cannot verify identity. |
| `CodexImageGenerationControls.swift` | `CodexImageGenerationRequest`: `normalizedForBuiltIn` |
| `CodexImageGenerationHelp.swift` | `CodexImageGenerationHelp` enum |
| `FluidContextToolScope.swift` | Explicit prepared-context dependency; expanded memory pages retain stored untrusted sources |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | Checked inline interaction descriptors for connector, provider, permission and capability owners |
| `MailAttachmentRead.swift` | `MailAttachmentRead`: one local Mail attachment's bytes for mail.save_attachment |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatToolRuntime diagnostics |
| `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher`, `peerApproval`: Read trust live; reads attribute, never steer. |
| `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`, `impl_tool_result_page`: Retain turn-bound results without loss. |
| `SecurityOriginContext+Turn.swift` | `SecurityOriginContext.currentTurn`: ingress-bound origin proof |
| `StudioCanonProposal.swift` | `StudioCanonProposal`: Stage independently; only a trusted live seat decides canon. |
| `StudioCanonSeatGate.swift` | `StudioCanonSeatGate`: Bind canon authority to the live trusted turn. |
| `StudioCanonTending.swift` | `StudioCanonTendingReport`, `StudioCanonTending`: Commit cards independently; retain evidence. |
| `SwiftCodexImageGenerationClient.swift` | Isolate execution; retain produced images through failure and Stop. |
| `SwiftOpenAIImageGenerationClient.swift` | Admit only declared routes; report per-item response failures. |
| `SwiftToolDispatcher+ActivityQuery.swift` | `SwiftToolDispatcher`: Bound reads by capture and origin gates. |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: Recheck program authority before launch. |
| `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `impl_agentCommunication`; command settlement joins its output consumer before reading replies and releasing its directory/probe; physical launch, exit success and proven delivery remain separate, launched unanswered commands retain unknown delivery |
| `SwiftToolDispatcher+ArtifactContext.swift` | `SwiftToolDispatcher`: Keep recall gaps and sampling explicit. |
| `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots`; workspace-default shell cwd and explicit pre-launch/executed receipts; certified shell reads use the Git reader's fixed argv/environment/sandbox; `builderLaunch`, the one way a command line starts (sandbox, starting folder, SwiftPM shim) for the shell tools and a part's program; builder and detached installer terminal audits run in SubprocessWork settlement |
| `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage` |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | Scoped history ranking; coverage gaps and chronological digests |
| `SwiftToolDispatcher+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, bounded anchored `impl_recent_trace_summary` pages; receipts span conversations by default, rank non-read actions first and scan complete retained since windows; `trace.usage` and `trace.model_calls` share this route and `TurnTraceRecentReader` for recorded sums, purpose counts and retention coverage; explicit session filters and bound turn refs |
| `SwiftToolDispatcher+DelegationTools.swift` | `SwiftToolDispatcher` `impl_delegation_status` `delegationStatusLimit` `delegationStatusOffset` |
| `SwiftToolDispatcher+DeskNotifications.swift` | `SwiftToolDispatcher`; stable scopes, mute windows, nag settlement |
| `SwiftToolDispatcher+DeskPlans.swift` | `SwiftToolDispatcher`; locked plans; partial-write receipts |
| `SwiftToolDispatcher+DeskReadout.swift` | `SwiftToolDispatcher`; canonical live/archive paging |
| `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`; raw mutation admission; checked waits and close |
| `SwiftToolDispatcher+DesktopPixels.swift` | `SwiftToolDispatcher`, `desktopPixelsRequested`, `desktopPixels`; masked capture; settled saves |
| `SwiftToolDispatcher+Dispatch.swift` | Normalized dispatch; pure validation; part-write receipts |
| `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |
| `SwiftToolDispatcher+FileAdmission.swift` | `SwiftToolDispatcher`; file admission; call-scoped connectors |
| `SwiftToolDispatcher+HumanConversations.swift` | Index/transcript-owned routes; bounded remote provenance reads |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`; Work-owned images; per-file settlement |
| `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |
| `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`, `impl_search_kg`, `kgSeenDate`; partial search preserves causes |
| `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |
| `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`; declared integration admission; checked routes and maps |
| `SwiftToolDispatcher+MacVerbs.swift` | Four-verb arguments; observed image identity; shared deadlines |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` restates roots and writes nothing when the memory already reads that way (a read steers nothing); `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`, `cappedRecallK`, `recallHitsJSON`, `telling`; bounded recall |
| `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`; persona writes; build and route owners |
| `SwiftToolDispatcher+ProposalReview.swift` | `SwiftToolDispatcher`: `impl_memory_proposals_pending`, `impl_memory_proposal_review` |
| `SwiftToolDispatcher+Reach.swift` | `performReach`: `programReach`, a part program's shell access check and launch plan |
| `SwiftToolDispatcher+RemoteNodes.swift` | `SwiftToolDispatcher`; SSH admission; unknown effects on Stop |
| `SwiftToolDispatcher+Senses.swift` | `SwiftToolDispatcher`: sense corner resolution and authorized raw material adapters |
| `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher` `standingBotApprovalReason` `standingBotsArgumentRefusal` `impl_standingBots` |
| `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`, `impl_studio_canon`, `impl_studio_canon_resolve`; live-turn resolution |
| `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`; durable journal; derived failures |
| `SwiftToolDispatcher+SubprocessSupport.swift` | `SubprocessWork`, `settle`; one process owner; bounded observation; output/audit settlement |
| `SwiftToolDispatcher+TaskLedgerTools.swift` | `SwiftToolDispatcher`; the shared paged task ledger |
| `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: exact `jsonInt` |
| `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file` (window parsing, ceilings and omitted defaults belong to `FileSystemActions`), `fileReadPresentation`, shared `impl_file_metadata` for list/info, `impl_trusted_file_mutation` (workspace writes and Trash) |
| `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |
| `SwiftToolDispatcher+WorkContext.swift` | `SwiftToolDispatcher`: `impl_work_context`, `workContextDeskItem`, `boundedWorkContextValue` |
| `SwiftToolDispatcher+WorkspaceDesk.swift` | `SwiftToolDispatcher`, `workspaceDesk`; lossless canonical paging |
| `SwiftToolDispatcher.swift` | Dispatcher/catalog construction; checked registry revision and selected schema encoding |
| `ToolApproval.swift` | PreApprovalToolValidating contract and SwiftToolDispatcher refusal/proposal wording before approval admission |
| `ToolArguments.swift` | Checked admission; lossless normalization; explicit tool operation and app-door dependencies |
| `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |
| `ToolResultSections.swift` | `ToolResultSections`, `pages`; lossless paging; small fields before bulk; raw oversized atoms |
| `Turn+ChatTools.swift` | `Turn` holds approved model override, image-generation admission and Make evidence |
| `VisualContinuity.swift` | `VisionLiveSceneSnapshot`, `SwiftToolDispatcherFourVerbLiveScene`; bounded motion and occlusion |
| `WindowObservation.swift` | `SwiftToolDispatcherFourVerbPerceptionSource`; masked capture; visual recognition; live preview |
| `WindowPixels.swift` | Crop before deduplication; bounded JPEGs retain capture provenance |
<!-- END GENERATED BLUEPRINT -->

### ChatTurnContracts

Directory: `Modules/NativeAgentCore/Sources/ChatTurnContracts/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatTurnContracts/ -->
| File | Owns |
|---|---|
| `ChatApprovalContracts.swift` | `AutonomyDecision` enum |
| `ChatPersistenceContext.swift` | Ingress provenance and durable completion identity; transcript choices live on Turn.rows |
| `ChatToolBridges.swift` | `PureToolArgumentValidating`; `argumentRefusal`; Execution-parser preflight without I/O |
| `ChatToolSessionContext.swift` | `ChatToolSessionContext`, `TurnEnvelope.workIdentity`, `answerExperienceID`: attribution, not authority |
| `ChatTurnExecution.swift` | `ChatTurnExecution` class; `keepCapabilityNote` |
| `PeerDataTaint.swift` | `PeerDataTaint`; `mark`; `markConsumed`; `elevate`; `steer` |
| `ToolDispatchRecord.swift` | `ToolDispatchRecord`; Pre-execution call identity |
| `ToolNoticeBus.swift` | A turn's explicit notice sink; no ambient notice route |
| `ToolTurnContracts.swift` | `ToolDispatchClient`: `dispatch`, `listAvailableTools`, `listAvailableToolSchemas` |
| `Turn+Contracts.swift` | `Turn` holds admission, execution, sinks and sticky message-decision call evidence; `TurnRows` owns rows |
<!-- END GENERATED BLUEPRINT -->

### ChatTurnRuntime

Chat consumers import the symbol-owning modules directly; the re-export-only
`ChatOrchestration` target is dissolved.

Directory: `Modules/NativeAgentCore/Sources/ChatTurnRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatTurnRuntime/ -->
| File | Owns |
|---|---|
| `AfterReply.swift` | `AfterReply`; `SwiftNativeTurnEngine.afterReply`; Saved-answer release and once-only private settlement |
| `AgentConversationsExports.swift` | Re-exports `AgentConversations` |
| `AgentScreenPreview.swift` | shared screen/room text projection |
| `AgentWorkspaceExports.swift` | Re-exports `AgentWorkspace` |
| `ApprovalActionText.swift` | `ApprovalActionText`: approval action/reason presentation; original arguments remain execution authority |
| `BodyFelt.swift` | `BodyFelt`: the one body line a turn carries for deviations the agent's turns have not been told, and its said-memory |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`; Bounded off-main attachment admission |
| `ChatGeneratedImageArtifacts.swift` | `ChatGeneratedImageArtifacts`; Receipt-backed reply images |
| `ChatLiveTap.swift` | `ChatLiveTap` enum; `observe` (every turn's deltas and saved answer, for the phone) |
| `ChatOrchestration+AfterTurn.swift` | `SwiftNativeTurnEngine`; Owed recording before retained interpretation |
| `ChatOrchestration+AutonomyGate.swift` | `AutonomyGate`: TrustCenter autonomy resolution and approval filing before concrete tool dispatch |
| `ChatOrchestration+CameToMind.swift` | `SwiftNativeTurnEngine.cameToMind(after:turn:held:sessionId:surface:)`: non-preview lines first met (`FamiliarLines`) form a moment; the recorder's dispatch predicate and ExpansionDispatcher's nested preview marker exclude proposals before familiarity and recall; memories join the agent's conversation at most two a round and four a turn, traced as `mind.came_to_mind` |
| `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop`, closing expansion predictions through `Expansion.withTurn` after the whole turn, including deferred after-reply work or its abandonment; explicit checkpoint and resume inputs, serialized `TurnCheckpointWriter`; same-turn transcript/receipt recovery and finished-run cleanup |
| `ChatOrchestration+CurrentTurnFacts.swift` | `SwiftNativeTurnEngine`; Parallel read-only facts; consuming reads at composition |
| `ChatOrchestration+Intentions.swift` | `SwiftNativeTurnEngine`; Bounded live intentions from their owner |
| `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`; `fireAssemblyStageEvent` |
| `ChatOrchestration+Streaming.swift` | `TurnStreamEvent`; Transient display, never terminal evidence |
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: delivers the message's facts (text, door, who, verified id, trust, steering, posture), runs the agent's turn part's effects, hands it each event with each result's declared effect (and, for a round's one deed whose call asked for `then_say`, its standing words as `say`), logs at every host-call boundary; the agent's own `app` calls run once as their own dispatch round through the same door and gates, and a turn may act or end before any model call; the turn returns at `reply.end` and `after`, and nothing of the agent's runs after it); before a fresh message’s opening model call, mind/authority practice may supply one gated standing read as `already_looked`; after each tool round the familiarity nerve meets the turn's landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), and on a later meeting no active ability's recorded route covers it puts `practice` on the round's last result once a turn, traced as `practice.keep`; `joinedProse`; `provider.roundOutput` counts safe prose and tool calls per parsed round; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated for `took`): `took` is the after-turn line, and each part called records its rounds |
| `ChatOrchestration+ToolDispatch.swift` | Offered-call admission; deadlines end only the wait |
| `ChatOrchestration+ToolLoop.swift` | `TurnContext`; `withToolSchemas`; `finishReplyTurn`; `.completed` |
| `ChatOrchestration+TurnEngine.swift` | SwiftNativeTurnEngine actor dependencies and retained task lifetimes |
| `ChatOrchestration+TurnReach.swift` | `SwiftNativeTurnEngine`; Frozen packet rendering and exact delivery credit |
| `ChatOrchestrationClient+AttachmentEvidence.swift` | `CodexCompletionTranscriptEvidence`; Exact completion and saved-attachment recovery |
| `ChatOrchestrationClient+Attachments.swift` | Trust-gated images and bounded document excerpts; audio stays attached |
| `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `chat`, `chatExecution`; `StructuredChatExecution` carries the response and typed success/failure; `withCurrentChatModel` admits the current Chat pick at a wake's `model.call`, so a run that never thinks needs no model; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |
| `ChatOrchestrationClient+DispatchWrappers.swift` | File-access gates; exact-call consent carried to dispatch; audit failures owe repairs |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`; `runEphemeralToolTurn`; `runPartToolTurn` |
| `ChatOrchestrationClient+Factories.swift` | `makeChatOrchestrationClient`; `makeGatedToolDispatchClient`; Shared canonical gated construction |
| `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`; `appendHumanConversationReply` |
| `ChatOrchestrationClient+InteractionTranscript.swift` | `SwiftNativeChatOrchestrationClient`; Locked card deduplication and redacted receipts |
| `ChatOrchestrationClient+LivedObservations.swift` | `SwiftNativeChatOrchestrationClient`; Explicit provenance and bounded cognitive events |
| `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`; Exact-row durable persistence and index publication |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `contextFingerprint` |
| `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`,`chatStream`,`chatStreamExecution`,`ChatStreamExecution` |
| `ChatOrchestrationClient+StructuredChat.swift` | Session-owned delivery, accepted input and canonical settlement |
| `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |
| `ChatOrchestrationClient+ToolReceipts.swift` | `ToolReceipt`, `ToolProgress`; `SwiftNativeChatOrchestrationClient.persistToolReceipt` |
| `ChatOrchestrationClient+Types.swift` | chat response, progress and enqueue receipt values |
| `ChatSessionWork.swift` | `ChatSessionWork`; `SwiftNativeChatOrchestrationClient`; Bind the composed request tail fitting to its turn |
| `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |
| `ChatToolRuntime.swift` | Re-exports `ChatToolRuntime`, `ChatTurnContracts` |
| `ChatTranscriptLineCountCache.swift` | `ChatTranscriptLineCountCache`; Revision-validated counts under transcript lock |
| `ChatTurnEvidence.swift` | Produced turn evidence and the durable owner-turn stamp; records retain their existing locks and formats |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`; `chat`; Explicit route, budget and mechanical provenance |
| `ChatTurnFailure.swift` | `ChatTurnFailure`; Retry from exact dispatch/effect evidence |
| `ChatTurnSettlement.swift` | One joined turn settlement preserves append-before-observe, produced output, terminal evidence and releases |
| `ChatTurnSteering.swift` | Open turns and waiting arrivals; joined-message evidence prevents guessed approval attribution |
| `ChatUpdateNote.swift` | Version note selection and launch transaction with supplied bundle resource/version inputs |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ContextStageTrace.swift` | `ContextStageTrace`; Payload-free bounded context telemetry |
| `ConversationPrefixSeeding.swift` | Public moment context is retained on its sent row; private choices join only live provider input |
| `DelegatedCampaignGuidance.swift` | `DelegatedCampaignGuidance`; Delegated campaign guidance; Trust retains authority |
| `DocumentExcerpt.swift` | `DocumentExcerpt.selected`; Bounded query-scored passages; absence stays explicit |
| `Expansion+Practice.swift` | `Expansion`; `Expectation`; Measured authority-separated practice |
| `Expansion.swift` | `Expansion`; `expansion/record.json`; Coalesced practice writes with repair owed |
| `ExpansionDispatcher.swift` | `ExpansionDispatcher`; `already_looked`; `ready_to_confirm`; Gated bounded reads and excluded act previews |
| `FirstConversationPersonaProgression.swift` | `FirstConversationPersonaProgression`; One-shot session/title progression |
| `FirstRunWelcomeTransaction.swift` | Claimed public welcome; checked receipt settlement |
| `GlobalHotkeyVoiceTurn.swift` | `GlobalHotkeyVoiceTurn`; Once-only push-to-talk through Mac send |
| `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |
| `InlineInteractionSignatureWitness.swift` | MAC-bound immutable continuation witness; persisted claims grant no signing authority |
| `MacChatRetrySnapshot.swift` | `MacChatRetrySnapshot` struct; `capture`, `stillMatchesLocal` |
| `MacChatSessionTransactions.swift` | `LatestRead`; `write`; Transactional selection and rename |
| `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator`; `TurnStreamEvent`; Coalesced deltas; joined final publication |
| `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |
| `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |
| `MacChatTurnCommands.swift` | `NativeChatTurnOptions`; `MacChatTurnRuntime`; Shared picker and Mac command ownership |
| `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`; `beginChatTurnLifecycle`; `applyChatTurnLifecycleInput`; `OtherDoorTurns` |
| `MacChatTurnLifecycleState.swift` | `MacChatPersistedTurnLifecycle`; Payload-free lifecycle state and terminal proof |
| `MacChatTurnLifecycleStore.swift` | `MacChatTurnLifecycleStore`; Exact-turn durable lifecycle |
| `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |
| `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry` |
| `MacChatTurnRuntime.swift` | Canonical Mac admission, lifecycle and preview state |
| `MacChatTurnStreamSettlement.swift` | Joined Mac/helper stream settlement |
| `MacChatTurnTranscriptProofReader.swift` | `MacChatTurnLifecycleRestartRepair`; Bounded exact terminal proof |
| `MindMemoryManager.swift` | One judgment per moment, evidence-backed intention outcomes, promise matching and recall |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatTurnRuntime diagnostics |
| `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`; User-authored head classification |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch`; `isSerialFallbackForced`; `isParallelSafe` |
| `PersistedToolReceipt.swift` | `PersistedToolReceipt.project`; `SwiftNativeTurnEngine.landedEffect` |
| `PersonParkedCalls.swift` | `PersonParkedCalls`: the cards a call the person decided waits on, so the call resumes as the person's when the person answers |
| `ProactiveAssistantSpeech.swift` | `speakProactively`; Locked deduplicated speech and destination reconciliation |
| `ProviderRecoveryPolicy.swift` | `TurnEngineError`; Typed provider failures retain partial work evidence |
| `ProviderToolNameMap.swift` | `ProviderToolNameMap`: stable provider-safe tool aliases with reverse mapping to canonical dispatch names |
| `SessionContextRequestBuilder.swift` | Fit the already-read replay at transcript-anchored half-budget checkpoints. |
| `SessionTurnDelivery.swift` | Session-owned live delivery and exact-run repair debt |
| `StandingBotContinuity.swift` | Helper-owned ingress and exact session ownership |
| `StandingBotModel.swift` | `Expansion.withTurn`; Helper-owned measured conversation replay |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolCallCodec.swift` | `ToolCallCodec`; Offered wire grammar; dispatch stays with the loop |
| `ToolLoopSupport.swift` | `ToolLoopTraceObservation`; `ToolDispatchDeadline`; Retained loop evidence and response deadlines |
| `Turn+Runtime.swift` | `Turn` holds runtime state; `ChatTurnWork` holds operation dependencies and LLMCall refinement |
| `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`; Checked local quiet hours shared with delivery |
| `TurnContextPreparation.swift` | Admitted route, frozen facts and bounded attention input |
| `TurnContextSnapshotTrace.swift` | Opening-request sizes, public context snapshots and ordered fed-context writes |
| `TurnDispatchBookkeeping.swift` | Joined dispatch bookkeeping on success, failure and Stop |
| `TurnEngineContracts.swift` | `TurnContext`; `TurnEngineResult`; Prepared context and engine-owned terminal truth |
| `TurnEpisodicContext.swift` | Turn-bound person continuity; recent acts from records and receipts, private choices from scratch |
| `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |
| `TurnPart.swift` | `TurnPart`; Source-bound helper and bounded throwing-program recovery |
| `TurnRequest.swift` | `TurnRequest` made a `Turn`; `TurnArrival`; `TurnAdmission`: per-session order, offering waiters to the agent's open turn |
| `TurnSettle.swift` | `TurnSettle` enum; `requestedResultIntent`, `takeStreamSuffix`, `transcriptRow` |
| `TurnToolResultPointers.swift` | Replace only overflowing tool-result bodies with pointers to their exact retained bytes. |
| `VoiceInputCapture.swift` | Consent-driven capture with terminal quality and audio attachments |
<!-- END GENERATED BLUEPRINT -->

### ChromeControl

Directory: `Modules/NativeAgentCore/Sources/ChromeControl/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChromeControl/ -->
| File | Owns |
|---|---|
| `BrowserConnectionMirror.swift` | `BrowserConnectionMirror`; Synchronous home reads; nil is unobserved. |
| `ChromeControlChannel.swift` | `ChromeControlChannel`, `ChromeConversationTab`; ordered socket effects; tab/document authority; local preview responses wait at most two seconds. |
| `ChromeControlHandshake.swift` | `ChromeControlHandshake`; Authenticated relay identity and bounded hello. |
| `ChromeControlRuntime+ConnectionEvidence.swift` | `ChromeControlRuntime`; Historical facts never prove connection. |
| `ChromeControlRuntime+ConversationTabs.swift` | `ChromeControlRuntime`, `ChromeTabTaken`; Per-conversation tab memory, release evidence and the person taking a tab. |
| `ChromeControlRuntime+Reload.swift` | `ChromeControlRuntime`; Accepted identity alone proves reload. |
| `ChromeControlRuntime.swift` | `ChromeControlRuntime`; Listener-fenced relay lifecycle and effect authority. |
| `ChromeExtensionFiles.swift` | `ChromeExtensionFiles`; Registered/shipped identity and executable digest. |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder`; Checked staged setup and registered-host refresh. |
| `ChromeNativeHostRegistration.swift` | `ChromeNativeHostRegistration`; Locked registration ownership. |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChromeControl diagnostics |
| `Turn+Chrome.swift` | `Turn` part Chrome control owns: the authority origin of its invocation |
<!-- END GENERATED BLUEPRINT -->

### Cognition

Directory: `Modules/NativeAgentCore/Sources/Cognition/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Cognition/ -->
| File | Owns |
|---|---|
| `AutonomousPursuitProposer.swift` | `AutonomousPursuitProposer`. |
| `CaringReceiptLog.swift` | `CaringReceiptLog`. |
| `CognitionHost.swift` | CognitionHost owner. |
| `CognitiveAttentionResidentProjection.swift` | `ResidentAttention`. |
| `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |
| `EventDeadlinePhysiology.swift` | `EventDeadlinePhysiology`. |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Cognition diagnostics |
| `NativeCognitionRuntime+Attention.swift` | Serial committed intake, checked weighing, retained claims and sleep |
| `NativeCognitionRuntime+BodyContinuity.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+BodyEvidence.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Continuity.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Deadlines.swift` | `CoalescingDeadline`. |
| `NativeCognitionRuntime+Door.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Events.swift` | `NativeCognitiveEventFactory`. |
| `NativeCognitionRuntime+Expectations.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+MindLedger.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Notify.swift` | `NativeCognitionRuntime.innerStateReading`. |
| `NativeCognitionRuntime+Organism.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Preferences.swift` | `NativeCognitionRuntime` preferences, checked configuration refresh and onboarding transitions |
| `NativeCognitionRuntime+ProviderEvidence.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+ProviderVitals.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Pursuit.swift` | Desk moments on the one clock, checked habit receipts and fixed-word delivery |
| `NativeCognitionRuntime+Readouts.swift` | `NativeCognitionRuntime`, `GrowthWeekFace`. |
| `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Rhythm.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+RunNow.swift` | `MindClockVerb`, `MindClockResult`. |
| `NativeCognitionRuntime+SourceWakes.swift` | Source observations and checked care-movement consumption |
| `NativeCognitionRuntime+StudioCanon.swift` | NativeCognitionRuntime+StudioCanon owner. |
| `NativeCognitionRuntime+StudioWander.swift` | The hour's presence opportunity, material and wondering inside its ordinary thought |
| `NativeCognitionRuntime+TurnPresentation.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail`. |
| `OrganJudge.swift` | `OrganJudge` beat law for the mind's judges; organ names of the clock owners; loop-shaped passes as beats |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |
| `StudioWanderLane.swift` | The hour's installation, material and Desk projection of its ordinary thought |
<!-- END GENERATED BLUEPRINT -->

### CognitiveSubstrate

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/CognitiveSubstrate/ -->
| File | Owns |
|---|---|
| `CognitiveCare.swift` | Care stance, relationships, depth and bounded story; durable merge links retain movement evidence |
| `CognitiveConfiguration.swift` | `CognitiveConfiguration`: cognition settings, Observatory availability and reflection spend ceilings |
| `CognitiveEpisodeReplay.swift` | Episode, schema proposal, developmental timeline and dream/REM replay values |
| `CognitiveEvent.swift` | `CognitiveEvent`: typed observations, turn kinds and mechanical-row metadata |
| `CognitiveLivedMoment.swift` | `CognitiveLivedMoment` journal; `LivedMomentDoor` records before folding |
| `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |
| `CognitiveModels.swift` | `CognitiveNode`, snapshots and `CognitiveFrozenRead`: bounded state and health |
| `CognitiveReflection.swift` | Captured reflection provenance, judgment, request, receipts and observatory values |
| `CognitiveSQLiteStore+LivedMoments.swift` | `CognitiveSQLiteStore`: checked `lived_moments` journal and settlement |
| `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadRestoreBundle`, `loadReceiptRecords` |
| `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore`, `backupForDoctor`, `commitMaintenance`: checked storage |
| `CognitiveSelfKnowledge.swift` | Evidence-linked nightly self reading; cached, epoch-checked atomic mind/self.json |
| `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |
| `CognitiveSubstrate+Attention.swift` | Checked care identity, atomic worth landing, drive claims and returns |
| `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.makeAttentionSignals`: bounded resident attention |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: frozen cues, shared presence and presentation commits |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `soundEchoShouldSpeak` |
| `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate`: provenance-gated care birth, movement and durable merges |
| `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate`: care pressure, turn cues, the stories attention reads and the hour's wondering |
| `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate`: checked nightly care/self settlement and pure previews |
| `CognitiveSubstrate+CaresSettlement.swift` | Shared care answers, stance and complete-link merge transformations |
| `CognitiveSubstrate+CaringAppraisal.swift` | `CaringAppraisalRequest`: caring judgment and distinctness contracts |
| `CognitiveSubstrate+CaringEvent.swift` | `CognitiveSubstrate`: provenance-gated caring and encounter accounting |
| `CognitiveSubstrate+Continuity.swift` | `CognitiveSubstrate`: dream and gap candidates for the single felt slot |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: phrase appraisal, provenance and completions |
| `CognitiveSubstrate+DreamResidue.swift` | `CognitiveSubstrate`, `CognitiveDreamResidue`: durable night claims |
| `CognitiveSubstrate+FeltFingerprint.swift` | `CognitiveSubstrate` felt fingerprint: graded live feeling words and capsule line composition |
| `CognitiveSubstrate+FeltOrigins.swift` | `CognitiveSubstrate.feltDayOrigins`: shared felt-day provenance |
| `CognitiveSubstrate+GrowthWeek.swift` | `growthWeek`/`growthWeekLines`: frozen evidence for `growth-week.js` |
| `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidateCompletion` |
| `CognitiveSubstrate+InnerState.swift` | `CognitiveSubstrate.innerStateReading`: bounded mind/body introspection |
| `CognitiveSubstrate+Maintenance.swift` | `CognitiveSubstrate`: microcycle settlement, maintenance deadlines and emotional consolidation |
| `CognitiveSubstrate+MindLedger.swift` | `CognitiveSubstrate`: bounded suppressions and disposition undo |
| `CognitiveSubstrate+Mood.swift` | `CognitiveSubstrate` mood: read-time emotional-tag integration, disposition, congruence, felt-day summaries |
| `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistAffectAndNodes`, checked stage repair |
| `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: `planReflectionChecked`, frozen causes and receipts |
| `CognitiveSubstrate+RemindedOf.swift` | `CognitiveSubstrate`: cached association, cadence and revalidation |
| `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`, proposal-owned REM history |
| `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: workspace intervention and frozen Observatory reads |
| `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState` |
| `CognitiveSubstrate+SemanticAppraisal.swift` | `SemanticAppraisal`: meaning, care stakes and grounded belief reactions |
| `CognitiveSubstrate+Serialization.swift` | `CognitiveArtifactCodec`, `cleanedSessionId`: checked evidence decoding |
| `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |
| `CognitiveSubstrate+TopicNaming.swift` | `CognitiveSubstrate`: private noun phrases and persisted-label admission |
| `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate` `metadataString` `isConversationalPresenceStatement` `isOperationalSubconsciousNoise` |
| `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead` from copied fields |
| `CognitiveSubstrate.swift` | `CognitiveSubstrate`: `waitForMaintenanceTransition`, `beginMaintenanceTransition` |
| `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies`, `CognitiveEmbeddingBatch`: checked reads |
| `CognitiveTurnCapsule.swift` | Attention, workspace, prepared capsule and fixed-time turn projections; advisory cognition runtime contract |
| `ContinuityField.swift` | `ContinuityField`: bounded nodes, associations, dedup, decay and emotion blending |
| `DoubleClamping.swift` | `Double.clamped01` and `clampedSigned`: shared unit/signed clamps for substrate and organism magnitudes |
| `JSONValueBounding.swift` | `JSONValueBounding`: shared metadata bounds and secret redaction |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for CognitiveSubstrate diagnostics |
| `PersonRhythm.swift` | `PersonRhythm`: zone-bound daily evidence, standing claims and break identities |
| `PersonalityDynamicsConfiguration.swift` | `PersonalityDynamicsConfiguration`: bounds and checked persona warmth/humor |
| `Turn+Cognitive.swift` | `Turn` parts cognition owns: the incoming row's after-turn origin, claimed care wakes and what a thought attends |
<!-- END GENERATED BLUEPRINT -->

### CognitiveSubstrate/Organism

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/ -->
| File | Owns |
|---|---|
| `BodyEvidence.swift` | Body evidence classes, secret-free identities and bounded freshness/uncertainty metrics |
| `CognitiveSomaticSignalAdapter.swift` | `CognitiveSomaticSignals` enum; `signal`, `safeSourceComponent` |
| `OrganismBehaviorPosture.swift` | `OrganismBehaviorPosture`: typed evidence, optimism bounds and directives |
| `OrganismBodySchema.swift` | `ProviderPathEvidenceOutcome` enum |
| `OrganismCapabilitySelfModel.swift` | `OrganismCapabilitySelfModel` enum; `beliefs` |
| `OrganismCaringEvent.swift` | `OrganismCaringEvent`: rolling encounters and once-per-encounter dosing |
| `OrganismChemistry.swift` | `OrganismChemistry` enum; `applying`, `dosedByCaringEvent` |
| `OrganismDreamRepair.swift` | `OrganismDreamRepair` enum; `applying`, `applyingResidualPressure` |
| `OrganismField.swift` | `OrganismField` struct; `summary`, `edge` |
| `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `foldTurn` (the body's whole share of one lived moment, with its watermark) |
| `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value` |
| `OrganismModels.swift` | `SomaticSignalKind` enum |
| `OrganismPersistence.swift` | `OrganismPersistentState`: checked identity, body continuity and restore decay |
| `OrganismPrediction+Horizon.swift` | Bounded horizon registers; named identity and whole-second unnamed plans |
| `OrganismPrediction+Semantic.swift` | `OrganismPredictiveBody`: scoped expectations, reactions and stable IDs |
| `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |
| `OrganismPredictionModels.swift` | Shared prediction rows, ledger, body confidence and cumulative outcome evidence |
| `OrganismProspectiveAffect.swift` | `OrganismProspectiveAffect`: pure prediction/horizon chemistry projection |
| `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |
| `OrganismResolutionFelt.swift` | `OrganismResolutionFelt`: bounded notable resolutions with aboutness |
| `OrganismSignalBus.swift` | `SomaticSignalBus` actor; `observe`, `configure` |
| `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |
| `OrganismTypedBodyBeliefs.swift` | Seven typed domain readings: evidence-bounded categories, freshness and compatibility values |
| `SomaticSignalValence.swift` | `SomaticSignalKind`: shared intrinsic valence for adaptation and field defaults |
<!-- END GENERATED BLUEPRINT -->

### Connectors

Directory: `Modules/NativeAgentCore/Sources/Connectors/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Connectors/ -->
| File | Owns |
|---|---|
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `spotlight`, `postMessage`, `statusEvidence`, `runGit` |
| `ConnectorActions.swift` | `ConnectorActions`: shared admission; CodexHandoff identity; redacted native reads; journal gaps |
| `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and checked `ConnectorProofLedger`: receipt-backed health decays without polling |
| `ConnectorOAuthRegistry.swift` | Registry owner: `mutateConnectorRegistryEntry`, `removeConnectorRegistryEntries` |
| `ConnectorRegistryActions.swift` | Ordered registry verification; disconnect intent precedes credential removal |
| `ConnectorWizardActions.swift` | Connector registry entry reads under the persistence lock |
| `Connectors.swift` | Workspace registry read and workspace path spelling |
| `LocalPIMConnectorActions+Authorization.swift` | EventKit read/write grants, permission prompts and wizard status |
| `LocalPIMConnectorActions+Calendar.swift` | Calendar CRUD on LocalPIMStore; exclusive day bounds; titles-only perception |
| `LocalPIMConnectorActions+Reminders.swift` | Reminder CRUD; exact IDs; unknown saves and unavailable callbacks stay explicit |
| `LocalPIMConnectorActions.swift` | Shared EventKit grants, checked query flags and Calendar/Reminders refusals |
| `LocalPIMStore.swift` | `LocalPIMStore`: main-actor mutations, queue-confined reads and nonisolated callbacks |
| `NativeOAuthFlow+Connectors.swift` | `NativeOAuthFlow`: `saveInlineConnector`, a connector card's token save (Slack, Telegram) |
| `NativeOAuthFlow+Slack.swift` | `saveSlackToken` verifies via `SlackWebAPI`; SlackCredentials owns revision-checked publication |
<!-- END GENERATED BLUEPRINT -->

### Context

Directory: `Modules/NativeAgentCore/Sources/Context/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Context/ -->
| File | Owns |
|---|---|
| `Context.swift` | `SwiftNativeContextClient`: current feature-surface lookup with one typed query and bounded results |
| `ContextArena.swift` | `ContextArena`: bounded generations, leases, pressure and post-lock health invalidations |
| `ContextAtomMatching.swift` | `ContextMarkdownCompiler` atom matching: ordered exact identity reuse and heading-scoped fuzzy matching |
| `ContextCandidateScore.swift` | Context eligibility decisions and candidate scoring values with their existing codecs |
| `ContextCorrectionScope.swift` | `ContextCorrectionScope`: canonical scope gates, never authority |
| `ContextExpansion.swift` | `ContextExpander.expand`: offered-pointer expansion without mutation or authority |
| `ContextFeedback.swift` | `ContextFeedbackReducer`: rebuildable utility and use reachability |
| `ContextFlowModels.swift` | Context identities, policy and immutable generations |
| `ContextHealthEvents.swift` | Root-owned context health invalidations; readers subscribe before reading and release on cancellation |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`, `triggerTokens`: bounded Markdown atoms and source-specific triggers |
| `ContextMarkdownGrammar.swift` | `ContextMarkdownCompiler` grammar: UTF-8 block ranges, Markdown boundaries and generated USER fact bullets |
| `ContextMemoryLead.swift` | `ContextMemoryLead`: rendered age, roots and source |
| `ContextPacket.swift` | Context packet, expandable pointers, safe representation leads and retained memory roots |
| `ContextPreparation+Feedback.swift` | ordered feedback replay and delivery-backed local rest |
| `ContextPreparation+SourceReconciliation.swift` | source compilation, checked faults and gated generation publication |
| `ContextPreparation+TurnSelection.swift` | turn leases, authorization, precoverage and verified delivery |
| `ContextPreparation.swift` | Context lifecycle, health invalidation, publication admission and shutdown drain |
| `ContextPreparedTurn+CameToMind.swift` | `cameToMind(by:embedding:excluding:limit:)`, `ambientStandoutDeviations` |
| `ContextProjectionSources.swift` | `ContextCompiledProjectionProvider`: derived sources, exclusions and checked publication |
| `ContextRelevance.swift` | `ContextSelector`, `ContextLexicalTokenizer`: shared relevance and normalization |
| `ContextSQLiteCodecs.swift` | `ContextSQLiteStore` persisted atom payloads, row decoding, JSON dates and vector bytes |
| `ContextSQLiteMaintenance.swift` | `ContextSQLiteStore`: feedback, health, pruning and vacuum |
| `ContextSQLiteSchema.swift` | checked current Context schema and fresh creation |
| `ContextSQLiteStore.swift` | `ContextSQLiteStore`: derived generations; canonical sources remain truth |
| `ContextSelection.swift` | `ContextSelector.select`, `commonEligibilityFailure`: eligibility, touch, rest, quotas and receipts |
| `ContextSelectionConfiguration.swift` | Context selector limits, ranking weights and named admission errors |
| `ContextSelectionReceipt.swift` | Selection degraded sources, budget, index and explicit current receipt evidence |
| `ContextSourceMonitoring.swift` | `ContextSourceRegistry`: allowlists, owner inventories and source-count health edges |
| `ContextTurnRuntime.swift` | `ContextPreparedTurn`: turn leases, query handoff and delivery |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Context diagnostics |
| `NeedSignal.swift` | Context need, admitted origin/authorization, cache identity vocabulary |
| `RequiredDocumentMirror.swift` | `RequiredDocumentMirror`, `StablePromptKernel`: required document and stable-prompt ownership |
<!-- END GENERATED BLUEPRINT -->

### ContextFlow

Directory: `Modules/NativeAgentCore/Sources/ContextFlow/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ContextFlow/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ContextFlow diagnostics |
| `NativeContextFlowConfiguration.swift` | `NativeContextFlowConfiguration`: checked modes/budgets; absent defaults; invalid unavailable |
| `NativeContextFlowRuntime+QueryEmbedding.swift` | `NativeContextFlowRuntime`: actor-owned joined embeddings and epoch-checked cache |
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime`: checked admission, joined lifecycle, health events, drain and provenance |
| `NativeContextMemoryPressureObserver.swift` | `DispatchContextMemoryPressureObserver`: cancellable OS pressure bridge |
| `NativeContextMemoryProvenance.swift` | `NativeContextMemoryProvenance.attach`: advisory lookup on the exact lease |
| `NativeContextProjectionText.swift` | `NativeContextProjectionText`; `clean`, `bounded`; ContextMarkdownCompiler triggers |
| `NativeKnowledgeGraphContextProjection.swift` | `KnowledgeGraphContext`: bounded selectable graph atoms; canonical verification |
| `NativeMemoryContextProjection.swift` | `MemoryContext`: canonical records, immutable untrusted-source entities and hashes |
| `NativeResidentWorkContextProjection.swift` | `ResidentWorkContext`, `ResidentWorkDecisionNeed`: provenance without work authority |
| `NativeStudioContextProjection.swift` | `StudioContext`: bounded journal/canon pointers; judgments stay on demand |
| `PersonaContextFlowProvider.swift` | `PersonaContextFlowProvider`: one persona/mirror compiler batch with provenance |
| `PersonaContextInvalidation.swift` | `DerivedPersonaPinInvalidationSink`, `ContextFlowInvalidationRelay`, `REMPinRebuildCoalescer` |
| `SensesContextProjection.swift` | `UnreadSenseNews`: bounded `news` from `SenseNewsBoard`; verify unread, acknowledge on output |
<!-- END GENERATED BLUEPRINT -->

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/SenseTurnReads.swift -->
| File | Owns |
|---|---|
| `SenseTurnReads.swift` | `SenseTurnReads`: bounded turn-local served-version evidence |
<!-- END GENERATED BLUEPRINT -->

### Desk

Directory: `Modules/NativeAgentCore/Sources/Desk/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Desk/ -->
| File | Owns |
|---|---|
| `DeskArchiveQueries.swift` | Archival and locked hierarchy queries; partial archive commits preserve receipts |
| `DeskBoardLayout.swift` | `DeskBoardLayout`: active work and the pursuit lane; `DeskPage` reads a stored timestamp |
| `DeskCadence.swift` | Checked step provenance and cadence; malformed saved values cannot become defaults |
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation`; life-stamped resumable work, stopped/restored projection; receiptIsUnresolved and toJSON |
| `DeskDependencyTransitions.swift` | Dependencies, hierarchy settlement and locked revalidation |
| `DeskHolds.swift` | Stopped-run reservations backed by retained checkpoints under the Desk feed lock |
| `DeskItem.swift` | Derived work and explicit progress; statusDescription shares persisted wait truth |
| `DeskJournal.swift` | Locked event feed append, integrity and compaction |
| `DeskLiveStateMemo.swift` | Replay memo keyed by the canonical feed stamp |
| `DeskModels.swift` | Shared Desk enum vocabulary and JSON scalar interpretation |
| `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |
| `DeskNotify.swift` | `DeskNotificationRead`, `DeskNotificationProposal`: native consent and locked settlement |
| `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for BodyQueue |
| `DeskOperations.swift` | `DeskOpBody`: complete ops and explicit clears; `updateTitle` commits refs atomically |
| `DeskPalette.swift` | `DeskPaletteRow`, `DeskFuzzy`, `DeskPaletteQuery`, `DeskPaletteCommandApplication`: revision-bound matching |
| `DeskParking.swift` | `DeskDeferPreset`; deferred-work interpretation |
| `DeskPursuitChoice.swift` | `PursuitChoiceScore`, `DeskPursuitChoice`: pure pursuit scoring and the Desk-day window key |
| `DeskQuickAction.swift` | `DeskQuickAction`: Desk tool names and dispatch arguments |
| `DeskRef.swift` | Stable Desk references and their persisted tagged-union identity |
| `DeskRefActions.swift` | `DeskRefAction`, `DeskRefAffordance`: reference open destinations and copy text |
| `DeskSequencing.swift` | `DeskSequencing.compute`: blockedness derives from edges without unblocking writes |
| `DeskState.swift` | Append-only archive records and materialized Desk state formats |
| `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |
| `DeskStore.swift` | `SwiftNativeDeskStore`, `currentRevision`, `continuation`, `setContinuation`, `updateTitle` |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `DeskText.swift` | `DeskPage`: compact board and exact-record text, sequencing segments, duration and archive presentation |
| `DeskWorkTransitions.swift` | Locked work creation, bounded reservations and idempotent receipts |
| `MyQueue.swift` | `MyQueue`, `entries`, `add`, `isReady`, `releaseSignal`, `releaseNews`, `freeAfter`, `shown`, `Entry.owedToPerson` |
| `OwnerAttentionPolicy.swift` | One owner-attention policy from approvals, Desk waits and inbox choices |
| `PartRunStore.swift` | Sealed bounded checkpoints; rename claims bytes until explicit settlement |
| `PromotionDossier.swift` | Desk notes and typed evidence dossiers for self-authored pursuits |
| `Pursuit.swift` | Durable work attempts and pursuit accounting values |
| `TaskLedger.swift` | `SwiftNativeTaskLedger`: locked history; `PersistenceCore.defaultDataRoot()` or explicit `--data-root` |
<!-- END GENERATED BLUEPRINT -->

### DeviceSync

Directory: `Modules/NativeAgentCore/Sources/DeviceSync/`

CloudKit chat and notification delivery records become eligible for deletion
after 14 days (`CloudKitDeviceTransport.retentionWindow`). Phone catch-up uses
snapshots bounded to **16 sessions**, the last **80 messages** per session and
the first **6,000 characters** of each message (plus a truncation marker),
subject to a **2 MiB** transcript group budget and transport limits, enforced
by `MacSyncEngine+Snapshots.swift`. Optional attachment previews are omitted
before dropping sessions to meet raw or compressed transport budgets; history
pages likewise omit previews before dropping rows or clipping words to 256 KiB.
Older missed content may remain unavailable
on the phone; Mac transcripts are unaffected.

Phone transcript reads use the plain projection reader, never the Mac's saved-row
publication. Snapshot encoding, payload/wire hashing, revision wrapping and file
inspection run off main; main holds lifecycle/publication state and takes finished
values. Snapshot payload clocks describe the state's last change, never a repeated read.
The writer canonicalizes sorted-key JSON and compares the payload bytes with the
last committed file before adding its revision envelope; there is no per-filename
clock filter. Unchanged state preserves the file and sends no digest; unchanged
digest metadata is not rewritten. Integrity repair and explicit republication
retain their owned demand. Typed mobile producers compare against the committed
phone file through `MobileSnapshotBuilder.state`, at the file's encoded date precision.
The integrity owner names the damaged files it reconstructs from canonical producers;
normal reads cannot treat an unreadable prior copy as an empty state.
An equal state retains every clock, including across app launches;
a changed state advances at least one encoded unit (milliseconds for overview,
seconds for organism's Date codec), preserving newer-wins ordering on the phone.
Health contains the engine's `launchedAt`, and the phone derives uptime when drawing.
Equal health facts reuse the committed bytes; the encoding-time `uptimeSeconds` sample
and `startedAt` launch remain required wire fields for installed phones 61/63.
Existing snapshots decode their `startedAt` launch when `launchedAt` is absent;
every new encoding writes `launchedAt`. Sampling uptime alone writes nothing.
Trust keeps only a saved policy's date. Telegram retains `observedAt` for equal
state while publishing actual `lastSuccessfulPollAt` evidence; a newer poll is a change.
Overview, Telegram and organism keep the bare objects and clock types decoded by
installed phone builds 61/63; no revision envelope wraps them. Their phone readers
order by `capturedAt`, `observedAt` and `generatedAt`. The status intent dates
organism's `generatedAt`; Mac last-seen still reads transport presence. Unavailable work
carries a reason, not an activity with invented dates, and cannot remove current
phone activities. Age or an omitted row cannot end a work Live Activity; canonical
terminal evidence, opt-out and ActivityKit's ended/dismissed events settle it.
The Mac push sender resolves registered activities outside the bounded snapshot
through the same exact experience lookup as the phone's signed work-state action.
It needs no retained pushed content to read settlement; missing or unreadable
evidence leaves that activity unresolved and reports its cause without blocking siblings.
Page snapshots retain their epoch until their face, version,
status, error, owed state or levers change; Diagnostics carries the stable start
time and Privacy's face omits its inventory read clock. The Telegram face omits
the idle poll clock and formats reply/diagnostic source dates absolutely, so a
read alone cannot change its words.

Both inbound chat transports reserve the authenticated envelope in local
`icloud/chat_transactions` before starting a turn. `iCloudBridge` owns its typed
chat schema and every mutation under the same file lock; completion preserves
reply-session and resend bindings, and recovery rereads the current row before
settlement. Terminal writes and admission release run through `settle`.
Rejected CloudKit envelopes create no unread local journal or payload copy.
Interrupted reservations
produce a correlated unknown-outcome reply without redispatch. The existing
inbox processor and admitted Drive backlogs retain their tasks through actual
settlement. Stop closes future dispatch, including after suspended reservation
writes. Retirement before dispatch releases only that admission's exact new
reservation; once a handler enters, its outcome record remains. Accepted
actions keep their captured ledger directory for completion. An action retired
before dispatch restores only its exact written reservation to `received` at
the captured path. Drive also releases its matching `pending_` envelope claim;
comparison and replacement are coordinated, leaving changed rows or files intact.
Accepted phone turns remain registered until their forwarder settles; remote
Stop is the separate explicit cancellation path. The existing
archive owner retains terminal chat and action rows for 30 days on both
transports, using the chat owner's terminal states (including reply-only rows,
`sent_unconfirmed` and `failed_before_answer`), and bounds rejected Drive inbox
archives to seven days / 50 MiB.
Completion markers survive until their actual bookkeeping succeeds. The archive
watcher observes directories before discovering and arming exact transaction files,
then pruning reads them. Pending input and unconfirmed responses are not archives.
Without a future retention crossing it parks until file events wake it, including
repairs that make an overdue transaction readable. Item-specific read/delete errors
preserve that item while siblings proceed; no failed-delete retry timer runs.
The snapshot integrity owner observes exact snapshot files and `snapshot_skips`
before launch reconciliation, with the existing 15-minute missed-event sweep
retained. It coalesces behind the physical writer and retries skipped groups
on a changed failure map or that sweep, without requiring a retained digest;
its own unchanged failure markers cannot drive a retry loop.
Live Activity start reservations retain their
expiry and are retired after a day only when no eligible start or token remains.
Permanent APNs activity-token rejections remove the token without releasing the
start reservation. Mac Integration permissions ride in the core CloudKit snapshot
as a canonical read projection. Generated phone replies carry JPEG previews
sharing the chat record budget; full image artifacts remain on the Mac.

Mac receive has its own 20-second transport lifetime regardless of push proof,
phone activity or presence publication. Launch, CloudKit push, KVS message nudge,
wake and network regain also drain incoming work; foreground phone contact
adds the 0.75-second message/control reader.
Signed foreground or active-talk phone contact supplies observed activity; the
[mobile transport contract](mobile_companion.md#transport-architecture) owns
its beat and foreground receive cadence. Pairing/status reads have one retained
task beside chat fetching so their latency cannot hold the chat drain's slot.
The phone's contact loop also reads signed Mac presence. Connection facts expire
to waiting at `phoneWindow` from the bridge's single contact timestamp, even
while a remote read remains open; snapshot delivery age alone is no stale verdict.
The receive timer owns its sleep and a separate retained drain owns accepted
work through actual exit; teardown cannot reopen its exclusion or let it
rearm an old transport's housekeeping. Subscription registration is retained
and serialized, and metadata callbacks require their exact live query.
Phone-request teardown settles its waiter with an unknown-delivery error and
cancels the send; that send keeps its exclusion until its actual exit.
Mac presence publishes on launch, app activation/deactivation, wake, network regain
and completed conversation edges, with a 240-second renewal after completion.
It does not renew unchanged snapshots. `BackgroundLoops` owns that deadline and
a 300-second due-only reconciliation cadence; the transport owns independent
20-second reads. Start/stop registration
changes are ordered, and late publication cannot update a new lifecycle.
Skipped beats are health-neutral: only a successful current publication can clear
an unresolved presence failure. Missing CloudKit transport, unsettled pairing,
or a phone deliberately paired elsewhere makes publication ineligible, not
failed. Each completion schedules the next protocol renewal; an eligible failed
attempt records its failure without selecting a retry path or a different cadence.
Phone delivery owns a pairing-scoped durable map of unaccepted record identities.
Verified correlated Mac progress/replies/action responses retire that ownership;
messages with no answer use the same signed progress path for acceptance.
No delivery re-signal or confirmation-poll timer runs. Missing transport or reply
evidence stays pending until an actual owner event or cancellation. Failed
no-text terminals retain a stable signed envelope in the chat ledger and complete
their presentation only after transport acceptance. Admission failure preserves queued work and exposes its cause through the
connection owner. Correlated failure replies still require separating retained
action settlement from control traversal; the initial response acknowledges only
the offer.

Phone catch-up runs through the full bridge drain at most once per existing
30-second foreground/talk presence beat, only while owed. Busy drains receive
no beat-driven rerun; the independent 0.75-second message reader starts no status
or cache work. One retained catch-up task leaves chat and presence renewal free
of status latency. Foreground/talk exit cancels it; its actual exit releases
admission. Failed reads retain their actual cause in the sync warning until
complete catch-up or reset, without changing either cadence.

CloudKit operations await their own completion/error, without an app timeout race
or custom SDK resource limit. KVS wake hints run once after publication acceptance;
one worker joins each actual synchronization result. Transcript and work-activity
publications enter the existing snapshot writer immediately; its completion owns
the dirty follow-up. Faces encode as a complete dictionary or fail that group.
Desk question-read and publication failures retain pending items and their cause;
replacement publication precedes retirement, while atomic multi-question replacement
still requires a transaction in the matters owner.

`MobileSnapshotBuilder` owns snapshot encoding and post-history session-index
reads. Blocking Drive work, including status-file reads, runs through `VolumeIO`;
publication awaits physical completion and retains lifecycle fencing.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DeviceSync/ -->
| File | Owns |
|---|---|
| `APNSNotificationDelivery.swift` | Transport-owned APNs fan-out, per-target receipts and confirmed token retirement. |
| `APNSNotificationReadiness.swift` | Checked pairing, registration and optional APNs configuration. |
| `BridgeEvalSeams.swift` | Replay bounds, KVS headroom, nudge admission and retention plans. |
| `CKLandmine.swift` | CloudKit entitlement probes and guarded account-status projection |
| `DeviceSync.swift` | Canonical-root phone bridge; Desk waits are ask matters, answered only by an observed Desk item |
| `DeviceSyncHost.swift` | Shared snapshot/action seam, checked layout and bounded message projections. |
| `ICloudConnection.swift` | Checked CloudKit/account setup; push and lifecycle events own drains. |
| `ICloudDeliveryNudgeQueue.swift` | Acceptance-triggered wake hints; one worker joins each KVS completion. |
| `ICloudDriveOutbox.swift` | Coordinated Drive outbox scanning, consumption and observation |
| `ICloudIncomingTurnForwarder.swift` | `ICloudConflatedSender`, `surface.replyDeliveryStarted`; Signed phone turns and retained delivery. |
| `ICloudIncomingTurnPort.swift` | Incoming phone turn engine port: resident chat, helper execution, presentation and control handoff |
| `ICloudIncomingVerification.swift` | Incoming message verification and receipt vocabulary |
| `ICloudReceiving.swift` | Retained chat drains; separate metadata reads cannot hold pickup. |
| `ICloudTextDeltaCoalescer.swift` | Immediate full snapshots; clock sequences outrank prior runs. |
| `LivingAttentionPolicy.swift` | `LivingAttentionPolicy.organismNeedsAttention`; Desk owns needs-person attention. |
| `MacPhoneRequestChannel.swift` | Authenticated phone-request results; sends retain exclusion until completion. |
| `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`, `chatHistoryPage`; Generation-bound history. |
| `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |
| `MacSyncActionRouter.swift` | `MacSyncActionRouter`, `surfaceSelection`; Canonical mutation receipts and bounded readbacks. |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | Both transports share ledger admission, replay, recovery and settlement. |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`, `start`, `stop`; Transport-selected roots; one snapshot lifecycle. |
| `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |
| `MacSyncEngine+Security.swift` | Pairing verification gates signing; bounded signed responses settle ledger outcomes. |
| `MacSyncEngine+SnapshotFreshness.swift` | Manifest-derived stale-page accounting and group build outcomes; cancelled reads remain unavailable |
| `MacSyncEngine+Snapshots.swift` | Revisioned payload/wire digests; host-owned Inspector and bounded chat projections. |
| `MacSyncEngine+Storage.swift` | `MacSyncEngine`, `DeviceSyncStorage`; Checked replay/digest and ledger storage. |
| `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |
| `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`, `startWorkActivityObservation`, `requestWorkActivityPublication` |
| `MacSyncEngine.swift` | Snapshot/inbox lifecycle state; durable scoped Stop and active phone turns. |
| `MacSyncInboxAction.swift` | Shared `InboxAction` alias and checked remote message/transaction filename identities |
| `MacSyncMobileNotificationRelay.swift` | Sole registration writer; immutable publication intents keyed by the canonical event |
| `MobileNotificationDeliveryReceipt.swift` | CloudKit alert/result receipts; optional APNs wakes never prove display. |
| `MobileSnapshotBuilder.swift` | Snapshot integrity vocabulary and bounded mobile projection construction |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DeviceSync diagnostics |
| `NativeAgentNotificationDefaults.swift` | `NativeAgentNotificationDefaults`; Shared title resolution. |
| `PairedPhoneStore.swift` | Canonical pairing-array mutations; local approval authority excluded from export and sync. |
| `PairingSecretManager.swift` | `PairingSecret`; Device-only secret, explicit rotation and readback. |
| `PhoneConnectionReader.swift` | `PhoneConnectionReader`: weak on-demand reader of the running bridge's one phone-connection assessment |
| `SwiftNativeAPNSSender.swift` | One APNs sender actor owns bounded transport, credential state, JWT reuse/expiry, rejection holds and signing |
| `WorkActivityPushRegistration.swift` | Push registration, retained start reservations and pairing fingerprints. |
| `iCloudBridge+ChatAdmission.swift` | One durable ledger for admission, Stop, signed reply retention and settlement. |
| `iCloudBridge+DeliveryReceipts.swift` | Signed phone receipts accept their matter's phone obligation at arrival; transport evidence journal |
| `iCloudBridge+Pairing.swift` | Exact-item reconciliation gates signing; account claims and phone connection facts. |
| `iCloudBridge+Publication.swift` | Pairing-bound canonical status/catalog groups, presence and progress. |
| `iCloudBridge+ReplyDelivery.swift` | Observed acceptance, retained signed recovery and stable control/reply identities. |
| `iCloudBridge+SessionDelivery.swift` | Bound device route; conflated progress joins before terminal recovery. |
| `iCloudBridge.swift` | Canonical chat ledger; push/lifecycle receives never select a timed alternate reader. |
<!-- END GENERATED BLUEPRINT -->

### DeviceSync/State

Directory: `Modules/NativeAgentCore/Sources/DeviceSync/State/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DeviceSync/State/ -->
| File | Owns |
|---|---|
| `ICloudSyncStatePaths.swift` | `ICloudSyncStatePaths`; Local bookkeeping and read-only bridge health. |
<!-- END GENERATED BLUEPRINT -->

### Dispatcher

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Dispatcher/ -->
| File | Owns |
|---|---|
| `ChatSlashCommands.swift` | `ChatSlashCommandHost`: body-window command execution and presentation admission |
| `Dispatcher.swift` | `DispatchResult`, `SwiftNativeDispatcher`: read-only admission; `ChatToolOutcome` owns verification |
| `LocalToolImage.swift` | `LocalToolImage`: explicitly supplied image sinks and bounded thumbnails; pixels never enter durable receipts |
| `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `dispatchNativeAction` uses `LocalConnectorActions.nativeReadOnly` |
<!-- END GENERATED BLUEPRINT -->

### Dispatcher/Actions

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/Actions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Dispatcher/Actions/ -->
| File | Owns |
|---|---|
| `DirectoryInventory.swift` | File metadata and bounded directory inventory |
| `FileActionContext.swift` | File path authority and connector context; Trust-fenced descriptor-bound attachments |
| `FileMutation.swift` | Guarded write, transfer and Trash operations |
| `FileReading.swift` | Descriptor-bound UTF-8 windows and exact bytes; only ENOENT proves absence; metadata-only watches |
| `FileSystemActions.swift` | `FileSystemActions`; `SwiftNativeSecurityCenter.fencedAttachment`; `FileReadSourceMaterial` |
| `FileSystemVerifiedPath.swift` | `VerifiedImageRead`: verified file/Chrome bytes; metadata never claims pixel delivery |
| `LocalConnectorActions.swift` | File/system handlers; `nativeReadOnly` selects seven native/slash tools |
| `MachineFactsActions.swift` | `FileSystemActions.systemInfo`: OS memory/power and bounded processes; per-field gaps |
| `PersonaSystemActions.swift` | Descriptor-fenced persona reads; skill/workspace adapters; `ClockReply` owns time projection |
| `ProcessCapture.swift` | `runProcess`: `ManagedProcess` lifetime/group settlement; strict UTF-8 or caller-owned bytes |
| `RepositoryReadActions.swift` | `FileSystemActions`: confined grep/Git; `FileReadSourceMaterial.shellReadLaunch` shares Git policy |
<!-- END GENERATED BLUEPRINT -->

### DoctorChecks

Directory: `Modules/NativeAgentCore/Sources/DoctorChecks/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DoctorChecks/ -->
| File | Owns |
|---|---|
| `ChatChecks.swift` | Checked ChatSession/SessionHistoryReader reads; ChatMessagesScanCache memoizes path fingerprints |
| `DoctorChecks.swift` | Ordered Doctor inventory; StorageCheck-first setup; concurrent readings and scoped repair |
| `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |
| `DoctorReadings.swift` | Checked findings and recovery; explicit human_action; CheckResult report/experience projection |
| `DoctorRunsInspectorChecks.swift` | Inspector health verdict from the engine's persisted-trace observation state |
| `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |
| `DoctorStatusProjection+Config.swift` | `AutoDoctorConfig`; `DoctorReadout`: `readAutoDoctorConfig`, `boolValue`, `intValue` |
| `DoctorStatusProjection+Hardening.swift` | `DoctorReadout`: `getProductionHardening` |
| `DoctorStatusProjection.swift` | `DoctorReadout`: `healthReadings`, `persistDoctorSnapshot`, `recordReadings`, `repairProjection` |
| `ICloudChecks.swift` | Active transport and local sync verdicts; repair missing directories without replacing signed evidence |
| `IdentityAbilityChecks.swift` | Canonical persona compilation and checked genesis; named profile/ability/seed failures |
| `MemoryModelChecks.swift` | Canonical memory/graph counts; activation verdict and installed prediction; epoch repair |
| `ModelCompensationsCheck.swift` | Bounded Doctor-only `shim.fired` counts since launch; no judgment or repair |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DoctorChecks diagnostics |
| `OAuthChecks.swift` | Owner-measured credential expiry; inspection never exchanges; repair refreshes expired credentials |
| `ProductionHardeningSummary.swift` | `ProductionHardeningSummary` struct |
| `PromptPrefixHealthCheck.swift` | `PromptPrefixHealthCheck`: measured prefix/cache health from turn and provider evidence |
| `ReleaseChecklist.swift` | `ReleaseChecklist` struct |
| `SessionIdentityCheck.swift` | `SessionIdentityCheck.run`: session mint-site counts and source/row disagreement diagnostics |
| `StorageChecks.swift` | Canonical scaffold only; read-only owner inspection; checked feed readability and compaction |
| `SubconsciousVitalsCheck.swift` | `SubconsciousVitalsCheck`: measured capsule, felt vocabulary and chemistry |
| `SupportDiagnostics.swift` | support diagnostics read model |
| `TurnTraceWindowReader.swift` | Measurement-window policy and coverage through canonical TurnTrace framing |
<!-- END GENERATED BLUEPRINT -->

### DreamREMCycle

Directory: `Modules/NativeAgentCore/Sources/DreamREMCycle/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DreamREMCycle/ -->
| File | Owns |
|---|---|
| `DreamCycleContracts.swift` | DreamCycleContracts owner. |
| `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`, `gatherRecentMessagesAcrossSessions`, `feltRankIndex`. |
| `DreamCycleRunner.swift` | `DreamCycleRunner`. |
| `DreamNight.swift` | `DreamNight`, `DreamDiaryWeeks`. |
| `DreamPayload.swift` | `DreamPayload`, `DreamClaim`, `DreamLesson`. |
| `DreamPendingWork.swift` | DreamPendingWork owner. |
| `DreamProvenance.swift` | `DreamEntryProvenance`, `DreamClaimSection`, `DreamSourceRef`. |
| `DreamREMCycle+Consolidation.swift` | `REMConsolidator`. |
| `DreamREMCycle+HeavyLogic.swift` | DreamREMCycle+HeavyLogic owner. |
| `DreamREMCycle.swift` | `FileBackedDreamDiary`, `SwiftNativeDreamREMCycle`. |
| `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DreamREMCycle diagnostics |
| `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |
| `REMConsolidator.swift` | `REMConsolidator`, `runWeeklyREM`, `rankedByRecurrence`. |
| `REMGrowthEvictionHistory.swift` | `REMGrowthEvictionHistory`. |
| `REMGrowthWriter.swift` | REMGrowthWriter owner. |
| `REMPinsReader.swift` | `REMPinsReader`: checked mtime-cached pin reads; only absence is empty, unavailable bytes throw to the caller; `latest` |
| `REMProposalStore.swift` | `REMProposalStore`. |
| `REMReport.swift` | `REMReport`, `REMRunReportPayload`. |
<!-- END GENERATED BLUEPRINT -->

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

`EngineLaunch` keeps recovery, launch admission, task lifetime, loop ordering and
quit settlement. `EngineChatSurfaces`, `EngineDreams` and `EngineScheduledWork`
compose chat transports, attention's night (dream, REM and part accounting), and the one clock's owners
(part schedules, watches, scans and inbox briefs). Happenings and MY QUEUE's current
carried ledger own their saved state; launch reads no retired arrival ledger.

Presentation declarations live by nature: `PresentationFaces`, `TelegramEvidence`,
`ProviderChoices`, `ConversationRoutes`, `ToolReceipts` and `AgentVoice`; shared
health, capability and formatting values live in `PresentationValues`.
`ApprovalTransactions/InlineDecisions` projects Mac and quiet-page cards;
`EngineRuntime/TranscriptReading` assembles their transcript rows.

`EnginePartWake` owns one launch lifecycle: its observers and passive watches
are removed on stop, queued admission checks its lifecycle after suspension,
retired parts lose held arrivals, and completed run handles retire at actual exit.
File wakes stop and report an unavailable watch when path observation cannot arm
or ends without a change; failed observation never admits another registration.
Engine launch retains its startup tasks; BackgroundLoops owns the approval-reconciliation subscriber;
termination closes launch admission before draining BackgroundLoops and the
domain owners. Senses registration never holds resident launch; each sense read
or file subscription awaits readiness at its owner. A delayed registration
success cannot revive a stopped subscription.
Launch stop also disarms the first-anchor observation/wait and Doctor's
first-turn observation/refresh; completed one-shot task handles retire.
Quit follows in-flight-turn changes and an explicit restart wake, armed before
reading, with one 20-second response deadline and no turn-state sampling.
Doctor repair verification consumes successful Telegram poll notifications
(including empty polls, without extra checkpoints) and the bridges' existing
ready-callback descriptor publications, then rereads owner health. The 35/3-second
verification bounds remain; SearXNG HTTP readiness still polls within 30 seconds.

Desk readiness, prepared rows and deadline selection all use the retained
page's explicit snapshot clock. Sequencing is derived with the rows after
the board and schedule reads, rather than using its own implicit wall clock.
Scheduler refresh callers join the retained operation through its queued
trailing read before assembling a page; coalescing never returns the old feed
while the requested refresh is still suspended.
System-clock and time-zone notifications invalidate the same Desk refresh
owner, replacing the page's clock and rearming its deadline. The retained
notification observation is cancelled with the facade.
Desk's research history requires every saved run to decode. Malformed or
partially malformed history fails the read with rejected-row accounting;
the prior rows remain labelled unavailable and the file is never rewritten.
The [built-in browser ownership contract](INTERNAL_WORKINGS.md#built-in-browser-operation-ownership)
defines recovery before engine creation or ingress, checked canonical evidence,
pure previews, approval settlement, native WebKit bounds and IPC readiness.
Resident approval reconciliation never runs restart recovery against newly
admitted work.
Desk's finished execution history includes the execution owner's `stopped`
status, including active records projected as stopped after a backup restore.
Desk presentation treats nonfinite or unrepresentable ages as unknown and
invalid or overflowing timer counts as unavailable. Step progress clamps
before adding its one-based offset; movement evidence binds each handle
before grouping rather than force-unwrapping a filtered optional.

`RuntimeReadProjection` owns the Mac-local `ActivityEvent` ledger value beside
its tail reader. Its decoder and writer use `executionId` only; no historical
mission-identity reader remains.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/EngineRuntime/ -->
| File | Owns |
|---|---|
| `AgentContactRow.swift` | Shared contact health and per-door grants |
| `AgentVoice.swift` | Agent name grammar and lock-protected live voice shared across presentation surfaces |
| `BodyChatCommands.swift` | Body-owned Mac admission, selection, commands and turn presentation without a mounted window |
| `BotsFace.swift` | Helpers rows and brief document bodies from the helper owner; Run once and Paused call their owners |
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilitiesFace.swift` | Owner-backed capability rows, action calls, approval levers and availability |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |
| `ChatModels.swift` | `ChatMessage`; Checked transcript codec, attachment previews and export |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `ChatTranscriptCache.swift` | `ChatTranscriptCache`; One decoded disk revision shared by transcript readers |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `CognitionFace.swift` | Cognition and memory upkeep packets, held collection reads and canonical person commands |
| `ConnectorFace+Agents.swift` | Connectors' agent rows: contact doors, their threads and the person's send; Connect, Test and Disconnect ask in a new Mac chat; a read never discovers; each row is a door call, and the agent verbs no other verb runs run here |
| `ConnectorFace+Phone.swift` | Connectors' iPhone rows: iCloud pairing facts, paired devices, notification route, phone senses; Pair, Remove and Rotate are the person's; each row is a door call, and the pairing verbs no other verb runs run here |
| `ConnectorFace+Telegram.swift` | Connectors' Telegram rows: transport health, the person's levers (on, token card, who may reach, mention, model), receipts, blocked and errors; each row is a door call, and the Telegram verbs no other verb runs run here |
| `ConnectorFace.swift` | The Connectors page: accounts, kept secrets and folders from `ConnectorReadiness`, composed with Telegram, iPhone and agent sections; each row is a door call, and the `connections` verbs the stem pages call run here |
| `ConnectorRecord.swift` | `ConnectorRecord`, `ConnectorActionRecord` and descriptor readiness projection |
| `ConnectorStatusProjection+Actions.swift` | connector action registry, records and checked capability statuses |
| `ConnectorStatusProjection+LocalIntegrations.swift` | `mac-watch-catalog`; Read-only catalog and native recovery words |
| `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile snapshots and checked mutations |
| `ConnectorStatusProjection.swift` | `ConnectorReadiness`, `LatestRead`, `write`, `connectorRowWithRuntimeOverlay`, `readConnectorRecords`, `updateConnector`, `restartSlackLane` |
| `ContactAddressBook.swift` | ContactListFacade owns checked address-book doors and their LatestRead publication and contact-change watch |
| `ContactConversationReads.swift` | Canonical contact history, helper results and isolated live flights |
| `ContactThreadReadouts.swift` | Root-scoped contact and independent helper watches; checked in-memory publication feeds the Helpers face |
| `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceipts` |
| `ConversationAttention.swift` | `MacChatUnreadSessions`; Phone activity remains unread until its chat opens |
| `ConversationRoutes.swift` | Sidebar routes, tab homes and fixed provenance labels |
| `ConversationRows.swift` | `ChatShellConversationRow`, `ChatShellEnvelope`, `ChatShellOpeningLine`, `LatestRead` |
| `ConversationSearch.swift` | Canonical conversation ranking, saved-result readers and cause-preserving message index |
| `CountsFeedProjection.swift` | `CountsFeedProjection`: off-main counts and availability assembly, comparison and feed publication |
| `CountsStatusProjection.swift` | `CountsStatusProjection`: ordered off-main phone, health, capture, download, transport and toast values |
| `DeskActivityPresentation.swift` | Desk availability, movement and expiry; a job carrying an item is its movement |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `DeskFace.swift` | The Desk packet `native-desk` draws: the Desk revision's facts, its rows' keys, the Reminders levers and Veto key levers |
| `DeskFaceActions.swift` | Desk's Mac-only places (editors, palette, clipboard, the item shown) as links its rows open, and the owner code behind desk.refresh, desk.remind and desk.veto |
| `DeskFaceItem.swift` | The selected Desk item or execution's canonical details, dependencies, pursuit, notes and references as Desk packet facts |
| `DeskPagePresentation.swift` | Desk page snapshots and what one frozen board read measures for the Desk packet (live activity, parking, the next change); the stuck-reason and chat-draft words other owners read |
| `DiagnosticsLivingStatus.swift` | `LivingStatusOwner`: actor-owned living reading, coalescing and launch-scoped source/face subscriptions |
| `DiagnosticsPacket.swift` | Diagnostics' packet for `native-diagnostics`: measured verdicts and row keys, each action calling its Doctor verb |
| `DoctorEmbeddingDownloadCheck.swift` | `DoctorEmbeddingDownloadCheck` enum; embedding download health `read`, `repair` |
| `DoctorProviderPathReading.swift` | Capture route faults before catalog recovery |
| `EngineApprovalNotifications.swift` | Approval observation delivers conversation cards; ForPerson owns the inbox reading and owed doors |
| `EngineApprovals.swift` | `ApprovalsFacade`: actor-owned approval reads, comparisons, face values and single-flight decisions |
| `EngineBodyNerve.swift` | `BodyNerve`: each beat re-reads the body; a newly felt deviation becomes a somatic signal and a fault owes repair |
| `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands`, `ability_manage`, `Parts`, `CapabilityCommandOutcome` |
| `EngineCarriedHabits.swift` | Join terminal and dispatch evidence off-turn to record carried-work trials from the agent's thoughts |
| `EngineChatSurfaces.swift` | Slack and Telegram ingress; speech permission episodes use the body attention port |
| `EngineCognitionModels.swift` | `LivingStatusSnapshot` and `DreamReport` completion and status interpretation |
| `EngineCognitionView.swift` | Cognition controls, checked diary and observatory reads; living status belongs to LivingStatusOwner |
| `EngineComposition.swift` | Root-bound body ports forward typed matters to the attention router |
| `EngineConnectors.swift` | `ToolsFacade.withPartDoor`; Checked connector reads and rooted gated execution |
| `EngineContactCommands.swift` | Person-initiated sends, original-scope Stop and held-message withdrawal |
| `EngineDaySense.swift` | Clock-driven day perception with authorized calendar titles, posted once per local day as a world happening |
| `EngineDesk.swift` | One retained board revision, ForPerson inbox changes, checked reads and gated local mutations |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeviceSync+Snapshots.swift` | `engine.connectors`, `engine.persona`, `engine.runs`, `engine.trust.snapshotData`; Checked phone adapter |
| `EngineDeviceSyncHelpers.swift` | `botsShelfRead`, the phone's helpers snapshot and its agent thread: read, or the person's words sent through the door |
| `EngineDoctor+CapabilityActions.swift` | Improvement runs and verified exports live in Doctor, publishing start and settlement to Capabilities |
| `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`; Mounted cognition health and canonical phone authority |
| `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`; One launch refresh after durable terminal evidence |
| `EngineDoctor+StatusChecks.swift` | `DoctorFacade`; Native Desk and Activity evidence with authored narration |
| `EngineDoctor.swift` | Shared report availability, route health, liveness and checked publication |
| `EngineDoctorHealthReads.swift` | Shared live health cards and bounded completed-report reuse |
| `EngineDoctorMeasurements.swift` | Mounted provider, memory, tool, transport and organ health |
| `EngineDoctorRepairs.swift` | Owner repairs with receipts; search stays on its configured endpoint |
| `EngineDoctorRuntime.swift` | Frozen repair admission, cancellation, rechecks and obligations |
| `EngineDocumentRead.swift` | Canonical document and structured page reads with held revision-checked phone continuations |
| `EngineDreams.swift` | Manual and scheduled dreams share one matter and delivery receipt; previews commit nothing |
| `EngineFaceActs+Capture.swift` | Finite native capture reads and checked Diagnostics run presentations |
| `EngineFaceActs+Cognition.swift` | Copied Observatory commands use the resident mind's checked outcomes and configuration |
| `EngineFaceActs+CredentialReads.swift` | Credential reconciliation reads owners without repeating saves or provider requests |
| `EngineFaceActs+Owners.swift` | Body onboarding, backup, research and dream acts return their owner's checked outcomes |
| `EngineFaceActs+SettingsConnectors.swift` | Connector settings use credential and allowlist owners, then reconcile their live transport |
| `EngineFaceActs+SettingsPrivacy.swift` | Typed credential redaction for body failures and probe replies before either face transport |
| `EngineFaceActs+SettingsProviders.swift` | Provider acts use checked routing transactions, credential owners and committed account readbacks |
| `EngineFaceActs+SettingsTrust.swift` | Trust and activity acts preserve locked edit admission and publish exact committed policy values |
| `EngineFaceActs.swift` | Body act dispatch, renderer-call attachment and connection-owned observation lifetimes |
| `EngineFaceCognitionProjection.swift` | Frozen Observatory detail becomes finished controls, sections, body signals and provenance rows |
| `EngineFaceContextProjection.swift` | Connection-held context summary rows; saved disclosure belongs to the document demand |
| `EngineFaceMacControlProjection.swift` | Driver and Trust events publish the canonical Mac-control presentation |
| `EngineFaceMindProjection.swift` | Independently held memory, cognition and event-driven context health presentations |
| `EngineFaceProjection.swift` | Body owner observations assemble finished Shared presentations off main, without consulting face slots |
| `EngineFaceThreadProjection.swift` | Finished contact rooms, helper history and record-bound Stop/resend commands |
| `EngineFaceWorkProjection.swift` | Finished Desk search/details, Make grants and version-bound Sense presentations from body owners |
| `EngineFrontSense.swift` | Front-app perception with presence, policy and provenance gates; once per app per local day as a world happening |
| `EngineHome.swift` | Home's packet read for `native-home` with the cognition runtime's attention reading; its rows' keys carry their calls |
| `EngineInbox.swift` | Root-specific ForPerson inbox reading, face-change subscription lifetime and checked trigger publication |
| `EngineLaunch.swift` | `NativeAgentEngine`; Ordered bring-up, ingress and retained settlement |
| `EngineMacIntegration.swift` | `MacIntegrationFacade`, `LatestRead`; Shared checked grants and watch readiness |
| `EngineMaintenanceParts.swift` | Effect-free authored maintenance words, deadlines and trigger choices |
| `EngineMemory.swift` | Canonical memory projections; lifecycle-bound SQLite/WAL graph observation through the shared LatestRead snapshot |
| `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`; Authenticated native response admission |
| `EnginePageVerbs.swift` | Packet key calls and page-owned verbs through the person's app door |
| `EnginePages.swift` | The pages registered on `engine.pages`: the agent's pages (the part that draws each and its owner's packet read, levers included), the stem's lever pages (their native read), the agent's own pages, and the one way a tap runs a row's call |
| `EnginePartWake.swift` | `EnginePartWake`, `start`, `deliver`, `run`, `readsOnly`, `reindex`, `held`, `resumed`, `holdBack`, `tainted_signal`, `changed`, `changed_more`, `person.away`, `person.here`, `network.down`, `network.up`, `chrome.tab_taken`, `AgentOpened` |
| `EnginePersona.swift` | Checked profile and document publication with independent save/read outcomes |
| `EngineProviderHelpers.swift` | Checked account contracts, inheritance and committed routing publication |
| `EngineProviders+Adoption.swift` | Transactional Chat adoption preserving intentional overrides and pending edits |
| `EngineProviders+Probe.swift` | `ProvidersFacade`, `clearProvider`; Native probes and matched credential verification |
| `EngineProviders.swift` | One checked root-specific settings/catalog owner across surfaces |
| `EngineRouteError.swift` | Plain failure remedies and full-width POSIX error interpretation |
| `EngineScheduledWork.swift` | Attention's night and the clock's part schedules, watches, scans, inbox briefs and helpers |
| `EngineSenses.swift` | `SensesFacade`: the work pane's sense view, current against the senses as last read, refreshed by their owners |
| `EngineSessionDelivery.swift` | Bound-route reply delivery through canonical transcript and transport journals |
| `EngineSleep.swift` | `EngineSleep`: evidence-based trial and candidate readings, measured costs and explicit source gaps |
| `EngineSleepNight.swift` | `EngineSleep`: night cursor, decided-trial settlement and durable surprise-window accounting |
| `EngineSync.swift` | `SyncFacade`, `LatestRead`; Checked pairing and owed key publication |
| `EngineTelegram+Commands.swift` | Checked token/configuration mutations and diagnostic receipts |
| `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |
| `EngineTelegram.swift` | `TelegramFacade.loadStatus`, `load`, `refresh`, `LatestRead`; Checked transport and diagnostic publication |
| `EngineTools+CapabilityActions.swift` | Mac actions and browser previews use canonical routes and publish their cached state |
| `EngineTools.swift` | `PartDoor`, `withPartDoor`; gated native calls and owner-supplied page outcomes |
| `EngineTrust.swift` | Checked policy, audit and capability publication through canonical mutation owners |
| `EngineTrustFace+Readings.swift` | Trust's security, live macOS grants (the reach and per-app Automation), watches and activity readings with source failures; each action its door call |
| `EngineTrustFace.swift` | Trust's checked policy, Mac grants, peers, receipts, privacy and backup controls |
| `EngineTurnContinuation.swift` | `TurnContinuationRuntime`: turns a relaunch interrupted resume, settled Desk waits return, reply settlement |
| `EngineTurns.swift` | Operational turn/Stop facade, off-main face publication and independent read-only panes |
| `GraphUpkeepOwner.swift` | One owner holds reviewed orphan identities and consumes their Apply token exactly once |
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletRun`, `GauntletCheck`; Stored promotion evidence |
| `InboxFace.swift` | Inbox's one face reads ForPerson's matters, put-away ones as folded history; each answer is its one door call, the person's tap and the agent's call alike |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `TurnsFacade.receiveScreenPreview`: off-main encoded masked preview, scoped to its exact active turn |
| `MacChatTurnExecution.swift` | `NativeAgentEngine`, `TurnsFacade.runtime`, `ChatTurnToolPlacement`; Ordered stream settlement |
| `MacIntegrationDeliveryActions.swift` | Rooted integration execution with native evidence and shared notification delivery |
| `MemoriesFace.swift` | Owner-backed memory facts, row calls, review levers, search and refresh |
| `MemorySearchReading.swift` | One memory search's checked reply, independent of later snapshot publication |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for EngineRuntime diagnostics |
| `MountedTranscriptRefresh.swift` | Mounted conversations read the store when it publishes; no turn refreshes a view |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`; Capture location before queue admission |
| `NativeAgentEngine.swift` | Root composition; Chrome refusals tell ForPerson and Activity follows its changes |
| `NativeAgentEnginePorts.swift` | Native host factories and read faces; cognition's shoulder tap tells its conversation matter |
| `NativeAgentResidentRefresh.swift` | `NativeAgentEngine`; Defer mind/context reload until admitted turns settle |
| `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |
| `NativeCollectionPackets.swift` | Dream and graph packets, revision-bound collection demands and canonical selected items |
| `PanelFreshnessOwner.swift` | `PanelFreshnessOwner`: canonical panel receipts, ordered refresh admission and off-main face publication |
| `PersonalityFace+Minds.swift` | Personality's levers: Memory and mind (`personality.mind`, a group transaction) and Reset identity (`personality.reset`, the onboarding reset), and the owner code behind both |
| `PersonalityFace.swift` | Personality's packet for `native-personality` and its page levers (minds, reset) |
| `PresentationFaces.swift` | Root-scoped authored copy from frozen inputs; each copy key posts its finished snapshot to the face feed |
| `PresentationValues.swift` | Shared health and capability presentation values, shared formatter alias and display-string truncation |
| `ProviderChoices.swift` | Provider catalogs and shared descriptor, auth and reasoning conversion |
| `ProviderFaceProjection.swift` | Ordered off-main provider settings and conversation control projection |
| `ProvidersFace.swift` | Checked provider pages and native group, sign-in and CLI-consent acts |
| `RunStatusBadgePresentation.swift` | The Mac run sheet's run outcome words and status tint |
| `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`, `LatestRead`; Checked saved configuration |
| `RuntimeReadProjection+Feeds.swift` | Checked owner-backed guidance, history, approval counts and bounded evidence tails |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadError`: unreadable feed detail shared by checked runtime readers |
| `RuntimeReadProjection.swift` | Checked activity and observed context usage; unknown measurements stay unavailable |
| `RuntimeSummaryModels.swift` | `KernelGuardrail`, `ApprovalClass`, `AutonomyKernelSummary`; Policy-only summaries |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SettingsFace+Status.swift` | Settings runtime evidence and remedies read cognition, Trust, Mac permissions and memory owners |
| `SettingsFace.swift` | Settings rows: registry, notification policy and triggers, search service; every control and action is its setting.set or verb call |
| `SettingsFeedProjection.swift` | Ordered settings-group admission, off-main projection and equal-value suppression |
| `SettingsInnerLifeStatus.swift` | Settings inner-life runtime status and its provider, model or reapply remedy |
| `SurfaceRuntimeStatusModels.swift` | Approval-backed pending status and browser recovery availability |
| `TelegramEvidence.swift` | Transport health, checked diagnostics and native receipts |
| `ToolReceipts.swift` | Frozen tool facts, shared status and exact successful persona-write receipts |
| `TranscriptReading.swift` | TranscriptsFacade canonical file/index reads, retention and one-revision card/attachment preparation |
| `TranscriptReadout.swift` | Transcript/card structures, page-bounded inline mounts and structural message grouping |
| `TranscriptRowFace+Mac.swift` | Mac and phone transcript row faces; unreadable tool input names its cause. |
| `TranscriptSessionMutations.swift` | Canonical session creation, archive and generation-checked clearing |
| `TranscriptsFacade.swift` | Root-scoped transcripts, press, session faces, mounted invalidations and live tail boxes |
| `TrustFaceGuardrails.swift` | Policy-derived guardrail rows used by Trust’s shared face |
| `TurnCardReadout.swift` | `TurnCardReadout`; Off-main lifecycle and canonical approval projection |
| `TurnFaceProjection.swift` | `TurnFaceProjection`: off-main finished turn faces, ordered from canonical owners and deduplicated before posting |
| `WorkOverviewRead+Today.swift` | Source-specific Today readings and the off-main owner posting its finished `today-readout` face |
| `WorkOverviewRead.swift` | `WorkOverviewRead`, `project`, `row`, `text`; owner attention and the agent's jobs at work |
| `WorkStatusPublication.swift` | Coalesced board publication for attention and widget; unknown identity withholds its name |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/ !Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift !Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `FoldedText.swift` | case- and diacritic-insensitive matching and the `folded_contains` SQLite function |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge.clampedInt`: shared integer argument bounds |
| `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in AppleScriptExecution |
| `MacAssistantStatus.swift` | `Resources/abilities/mac-watch-catalog.js`: Checked readiness verdicts beside the catalog part's words; never creates jobs |
| `MacContactsExecutor.swift` | `CNContactStore`: checked Contacts reads and labeled mutations |
| `MacLocationReader.swift` | Held location fixes with age; fresh requests settle on CoreLocation callbacks or caller cancellation |
| `SystemPermissionPreflight.swift` | Observed OS grants, request admission and one capability vocabulary for permission cards |
<!-- END GENERATED BLUEPRINT -->

### MultimodalTTS

Directory: `Modules/NativeAgentCore/Sources/MultimodalTTS/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MultimodalTTS/MultimodalTTS+VoiceSelection.swift -->
| File | Owns |
|---|---|
| `MultimodalTTS+VoiceSelection.swift` | one Trust-owned voice and cancellation |
<!-- END GENERATED BLUEPRINT -->

### MacControl

AX and pixel perception share this owner and the same geometry/redaction
contracts. Screen capture and the four-verb fusion bridge keep their existing
owners.

Running app identity includes non-terminated regular and accessory processes;
`MacAXAppInfo.isDockApp` comes from the same activation policy in enumeration,
foreground and PID reads. Exact background resolution prefers Dock apps;
partial names and running-app projections stay Dock-only. Fused coverage failures
withhold pixels with a named cause while retaining the structural observation.
Typed subrole gaps alone are covered by the element's finite frame; text-role
values with that gap never enter observations through the shared AX value reader,
including caption and selector reads. Self-window routing carries
`behind_app` from window ownership to the failed page look's correcting call.
Window OCR runs on every look under caption redaction, without the whole-window
walk; when a picture is released it shares that picture's pre/post mask union and
omits any intersecting row. Unproven capture geometry or OCR positions withhold
all recognized text for that capture
with a named cause while retaining the AX observation.

Interactive menu reads, menu presses, handle acts and looks admit their resolved
process through `macAdmit` before AX reads. Its private application element asks
for a reply off `MacAXExecutionLane`, with a six-second IPC limit; this is the
one exception to lane-owned AX IPC. Slow cannot-complete answers repeat on that
worker; a fast answer waits for launch completion once or reports unreachable.
The ten-second patience is capped by the operation deadline. Stop retires the
wait; a late worker reply has no authority to emit input. Passive looks skip
admission, and post-effect passes do not admit.

`macSettle` judges evidence immediately and after coalesced event batches, one
pass at a time. Navigation and menu surface commands retain their transition
filter and read once at patience even without a transition. Only the chosen
pass supplies the receipt and next frame. The 300 ms effect patience (1.5 s for
navigation) bounds observation, never proves failure or no effect. Menu
revalidation uses the same form with 150 ms patience. Equal replacement text,
already-selected controls and held focus need no emission; presses and toggles
always emit. Payload-free `mac.settled` rows carry the end cause, first event
latency, winning event-to-pass gap, pass count and app-reply wait duration.
A judge's thrown evidence-read error ends settlement as `failed`, with its cause
retained and reported by the caller; cancellation still ends it as `stopped`.
The first notification, lifetime count and observed kinds are retained separately
from drained wake batches, so an early burst cannot hide a later transition.
The fixed 80 ms post-notification sleep and 150 ms menu sleep are absent.
NativeAgent's body and face remain person-only through `PersonOnlyWindows.isOwnProcess`.

Keyboard grammar, pointer ownership, input emission, AX actions, approval
evidence, Apple events, process execution, app navigation, file access,
screen readiness and protected paths are filed by nature. Image geometry,
visual objects, watch capture, frame questions and hands retain their type owners.
Dispatch and the operation store retain execution and effect-lifetime ownership.

`MacAXExecutionLane` owns one serial thread (`com.nativeagent.mac-ax`) and its
run loop. Except for the private admission probe, synchronous AX transactions
enter that thread; nested calls execute
there directly. Its AX observers install, deliver, renew and remove on that
same run loop. A port holds the loop open between subscriptions; work completion
releases each synchronous caller, without a clock or a main-queue hop.

Mac verb entry points and motor-count dispatch explicitly leave the caller's
actor with `@concurrent`; raw sense flights use the same boundary. Native Mac
dispatch retains its own actor, and screen-wake snapshot ordering belongs to
its private `LatestRead` actor. AX IPC and screen-wake work stay off the window's
thread. The app's own window/view changes use the awaited
`PersonOnlyWindows.stepAsideForScreen` hook on the main actor, outside the AX lane.
Desktop chat and routine sends, setup, predicates and action cleanup are non-main
work. Their async entries, renderer preparation, activation and continuation capture
explicitly leave the calling actor with `@concurrent`; synchronous AX helpers run
only within those non-main paths. Existing send and observation bookkeeping uses
short mutex transactions, never held through AX or an await. Clipboard settlement
carries copied bytes instead of sharing AppKit clipboard objects across executors.
Desktop chat observation awaits AX installation and coverage reads; cancellation
queues cleanup on the AX thread and retains its source until subscriptions are removed.
`PersonOnlyWindows.isOwnProcess` fences both the body and its spawned window at
Accessibility target resolution, native key emission, capture and foreground
attribution. The child is registered before pipe attachment and retired by its
process exit; disconnect settles routing receipts without unprotecting live UI.
Approval-card buttons remain person-only. Navigation may activate an owned app
without acquiring its AX tree; app pages retain their presentation route.

Directory: `Modules/NativeAgentCore/Sources/MacControl/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacControl/ -->
| File | Owns |
|---|---|
| `MacAXActSource.swift` | AX targets retain stage, cause and remedy; window identity and URL evidence stay exact |
| `MacAXAttributeRead.swift` | Checked AX reads isolate node gaps, retain sibling evidence and share ordering |
| `MacAXEffectObservation.swift` | `MacAXEffectObserverSource`: Payload-free signals; bounded waits and lane-owned cleanup |
| `MacAXElementSource.swift` | Read-only AX contracts preserve gaps and observation-bound focus |
| `MacAXObservation.swift` | Anchored AX search retains optional-attribute and action-name gaps |
| `MacAXValues.swift` | AX identity, geometry and queries preserve gaps and bounded failure evidence |
| `MacAccessibilityActuator.swift` | Requested AX mutation only; unsupported outcomes stop without substitution |
| `MacAccessibilityReader.swift` | `SystemMacAXElementSource`: Bounded read-only walker; exact window/menu roots |
| `MacActClosedLoop+EffectDifferences.swift` | `MacActClosedLoop`, `diff`: Redacted diff and target-owned press evidence |
| `MacActClosedLoop.swift` | Closed-loop grammar, live identity, geometry guards, declared effects and bounded waits |
| `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |
| `MacActSerial.swift` | `MacActSerial`: FIFO acts/watch hands; release held input on transfer and pass raced slots |
| `MacAppActGate.swift` | Saved Write switches govern all acts; retain target/authority failures without cold-index waits |
| `MacAppIndex.swift` | Resident Spotlight snapshots retain row/directory gaps; initial reads await gather, failure or shutdown |
| `MacAppMaps.swift` | `MacAppMapStore`: Verified control maps; scoped press evidence; checked reads/flushes |
| `MacAppNavigation.swift` | `MacApplications`, `AppControlRunResult`, `OpenTarget`: Checked app identity and workspace-owned activation |
| `MacAppSourceEvents.swift` | Descendant AX notifications and coalesced reads retain coverage gaps; bounded content-stall signals |
| `MacAppWindowText.swift` | `MacAppWindowText`: On-device window OCR; retain only redacted text/positions |
| `MacAppWord.swift` | Event-paced effect settlement, off-lane app admission and payload-free mac.settled receipts |
| `MacAppleEvents.swift` | Native OSA: per-event target/Write checks, bounded replies, held calls and their settle, volume recipe |
| `MacAttention.swift` | `MacAttentionSessionStore`, `MacDriverBinding`: Driver takeover, view continuity and held-input settlement |
| `MacAttentionEvents.swift` | Passive input/scene events retain provenance; coalescing never delays synchronous takeover |
| `MacAttentionObservation.swift` | Bounded attention readout and observation continuity |
| `MacBackgroundSight.swift` | `MacBackgroundSight.resolve`: Exact identities precede partial names; preserve ambiguity and source failures |
| `MacChromiumAccessibility.swift` | Renderer identity and activation; descendant events wake async content judging; synchronous reads never sleep |
| `MacClipboard.swift` | `MacClipboardRead`: Permission-bound pasteboard reads/writes; bounded redacted text and type metadata |
| `MacControl+Client.swift` | `SwiftNativeMacControl`, `dispatch`, `dispatchApprovedInjection`, `MacObservationMode` |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl.handleAct`: Same-window live identity and per-step declared effects |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: Event-judged editor focus and input; per-event image/window guards |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`, `handleMenu`, `handleMenuPress`, `handleClipboardRead` |
| `MacControl+OperationSupport.swift` | Bounded response waits retain actual-exit ownership, produced output and unknown effects |
| `MacControl+Perception.swift` | Checked shallow menus retain availability/coverage for native pages and windowless apps |
| `MacControl+SystemActions.swift` | Lossless file windows, checked mutations, scoped Spotlight, exact media and per-event app scripts |
| `MacControl+TextEditing.swift` | `SwiftNativeMacControl.typeText`: One writer; event-judged focus and selection acknowledgement |
| `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |
| `MacControlActionRoutes.swift` | Canonical MacControlResult dispatch receipts and bridge action paths |
| `MacControlAdmission.swift` | Canonical desktop policy and input admission; passive observation carries no motor authority |
| `MacControlContracts.swift` | `MacControlResult`, `MacControlClient`, `MacMotorCount`: Dispatch receipts and policy categories |
| `MacControlOperationStore.swift` | `MacControlOperationStore`: Payload-free lifecycle, recovery admission and cancellation |
| `MacControlSettlement.swift` | Settlement retains output and unknown effects; refusal audit failures never invent acknowledgement |
| `MacCrossAppDrag.swift` | `MacCrossAppDrag` `MacFourVerbs.performCrossAppDrag` |
| `MacDocumentObservation.swift` | Document reading and screen text extraction within the existing observation |
| `MacDocumentRead.swift` | `MacDocumentRead`: Bounded extraction, accumulation and observed scroll restoration |
| `MacDocumentReadTakeover.swift` | `MacDocumentReadTakeover.mark`: Physical takeover blocks later read-scroll emissions |
| `MacFileAccess.swift` | `FileBytes`, `MacFileText`: Checked regular-file IO and lossless bounded text windows |
| `MacFourVerbs+Act.swift` | `MacFourVerbs`, `act`, `addAttention`: Deadline-bound named acts, repetition and effect receipts |
| `MacFourVerbs+AppMap.swift` | `MacFourVerbs`: Verified chrome maps and control-scoped pointer evidence; fresh identity remains required |
| `MacFourVerbs+Batches.swift` | `MacFourVerbs`: Live ordered selections, complete step digests and stop settlement |
| `MacFourVerbs+Foreground.swift` | `MacFourVerbs`, `FrontExpectation`, `actBroughtForward`, `settlementDispatch`, `missBeforeRaise` |
| `MacFourVerbs+MenuCommands.swift` | `MacFourVerbs`: Menu/popup actions retain ambiguity, effect verification and read failures |
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: Launch Services recipient landing; event-judged sight when arrival is unconfirmed |
| `MacFourVerbs+Observation.swift` | `MacFourVerbs`, `screen`, `observedReply`, `visible`, `appBehindMe` |
| `MacFourVerbs+PerceptionSupport.swift` | `MacFourVerbs`: shared rendering/targeting `partition` and `supplementalDuplicateIndex` |
| `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: Shared name/image gestures retain focus and capture identity |
| `MacFourVerbs+ScreenFusion.swift` | Call-local AX/pixel fusion binds window identity, targets and read gaps; empty looks grant no act window |
| `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: supplemental AX native-page merge, `zoom`, `parseVerb`, `isRightClick` |
| `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: Exact names, ordinals and visible main-content scroll targets |
| `MacFourVerbs+Wait.swift` | `MacFourVerbs.wait`: Required AX/app signals, bounded text rechecks and settling within one deadline |
| `MacFourVerbs+WorkspaceControl.swift` | `MacFourVerbs`: One verb vocabulary and exact frame/handle admission with canonical effects |
| `MacFourVerbs.swift` | `MacFourVerbs` struct |
| `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient`; permissionRemedy is the shared macOS grant remedy builder consumed by SystemPermissionPreflight and lower-level MacControl producers |
| `MacFusedObservation.swift` | Exact-window fusion with complete pre/post secret masks, identity checks and explicit omissions |
| `MacHandRepertoire.swift` | `MacHandRepertoire`: Bounded gestures with interpolated drags, balanced holds and residual releases |
| `MacInjectionApproval.swift` | `MacInjectionCapability`: Expiring single-use input authority, approval digests and redacted secret replay |
| `MacInputEvents.swift` | Per-event driver and target Write checks; reading and held-input release remain available |
| `MacInputRouting.swift` | Routed-event receipts and epoch-bound face input identity |
| `MacIntegrationPermissionStore.swift` | Checked, flocked consent; complete supported axes; explicit OFF fences Full Mac |
| `MacIntegrationPermissions.swift` | Integration identity, consent values and mutation provenance; persisted integration IDs are stable |
| `MacKeyboard.swift` | `MacKeyModifiers`, `MacKeyChord`, `MacKeySyntax`, `MacKeyEvent`, `MacSecureEventInput`: Layout and secure-input rules |
| `MacLookFrames.swift` | LatestRead frame publication, explicit compile bounds and batch snapshots retaining original TTL |
| `MacLookPercept.swift` | Immutable semantic percept, handle and readout vocabulary |
| `MacMediaTarget.swift` | Bounded Now Playing identity discovery; no-player evidence is nil, cancellation and process failures stay typed |
| `MacMenuBar.swift` | Scoped AX gaps; exact-branch press discovery retains siblings; normalized paths and choices share identity |
| `MacNativeAction.swift` | Native actions share text/hand owners, exact resolved targets, per-event focus checks and effect verification |
| `MacNotification.swift` | Notification posting through the app's injected banner exit with truthful unverified acceptance |
| `MacNotificationDelivery.swift` | `NotificationPostReceipt`, `NotificationPosting`: Acceptance evidence never proves observed delivery |
| `MacPerceptionCompiler.swift` | `MacPerceptionCompiler`: One AX snapshot supplies graded, redacted perception and stable target handles |
| `MacPersonInput.swift` | `MacPersonInput`, `observeReturn`, `NativeAgentMacEventIdentity`, `ScriptedInputSources`, `NativeAgentMotorEpoch` |
| `MacPointer.swift` | `MacMouseEvent`, `MacScrollEvent`, `AgentPointerHold`: Input-owned pointer holds restore the person's cursor |
| `MacPointerObservation.swift` | `MacPointerPosition`, `MacRegionAim`: Actual cursor and clear-region aim; unknown never invents origin |
| `MacProcessExecution.swift` | `ProcessExecution`, `ProcessRunResult`, `ProcessRunCancellation`, `ProcessRunIOFailure`: Process lifecycle |
| `MacProtectedPaths.swift` | `MacControlSensitivePathFence`: Protect data, OS/store mutation and parent paths without widening read fences |
| `MacSavePanelPlacement.swift` | Event-ordered Go-to-folder sheet, focused-field delivery and native directory URL proof |
| `MacScreenPageCompiler.swift` | Structural AX reading order, scoped alias folding, whole sentences, secret redaction and exact related actions |
| `MacScreenReadiness.swift` | Session readiness; event-judged automatic screen wake and caller-requested explicit settling |
| `MacScreenRender.swift` | `MacScreenText`, `MacScreenRender`: Shared semantic/pixel formatting retains compiler redaction |
| `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`, `MacScreenViewTextRedaction`, `MacImageFrames`, `MacImageCapture`: Capture |
| `MacScreenViewBuilder.swift` | View and mark construction from captured geometry and accessibility |
| `MacScreenViewCapture.swift` | `SystemMacVisualObstructionProbe`, `SystemMacScreenCaptureSource`: Exact capture, hit evidence and cancellation |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG` masks secret frames before encoding; `encodePNG` |
| `MacScreenViewResultRedaction.swift` | Persisted result previews omit image payloads |
| `MacScreenViewTextRedaction.swift` | One secret-decision owner for text, pixels and enclosing captions |
| `MacScreenWatch+Capture.swift` | `MacScreenWatch`: Exact capture with complete secret masks; inspect the newest pending frame even when static |
| `MacScreenWatch+FrameQueries.swift` | `MacScreenWatch.read`: Exact-frame pixel/text queries require current watch and secret verdicts |
| `MacScreenWatch+Hands.swift` | `MacScreenWatch.hand`: Watch-owned input, per-event authority, exact-window and secret drag checks |
| `MacScreenWatch.swift` | Exact-window stream; complete secret masks precede publication; bounded settlement and immediate takeover |
| `MacSemanticAct.swift` | `MacFourVerbs.actOnce`: Fresh-name transactions preserve key intent, focus typing and current-content scroll |
| `MacSemanticExecution.swift` | Shared semantic/physical execution; uncertain delivered text remains unverified with a pixel-look remedy |
| `MacSemanticObservation.swift` | Shared semantic reads and exact-node search; named stopped/windowless apps report absence without launch |
| `MacTransientMenus.swift` | Bounded near-focus menu reads retain scoped AX gaps and structure without widening window capture |
| `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |
| `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactedText`: Shared OCR caption/proximity and overlap redaction |
| `MacWaitSignals.swift` | `MacWaitSignals`: Cancellable AX/app signal waits with owned observer lifetimes |
| `MacWindowActivation.swift` | `SystemMacAXActSource`: Synchronous raise; event-woken activation off the AX lane; app-only avoids self-AX |
| `MacWorkContinuation.swift` | One request's bounded native takeover continuation |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MacControl diagnostics |
| `PersonPresence.swift` | One Mac/phone presence; phone departure arms physical return, missing evidence stays unknown |
| `SystemMacAXActSource.swift` | Dedicated AX thread and run loop; CF-equal identity, scoped gaps and target-pid Write/driver gates |
| `SystemMacAXElementSource.swift` | Scoped locked AX, snapshot focus and renderer-safe continuation; per-node gaps and complete secret evidence |
| `TrustedRemoteEffectNodes.swift` | Provisioned SSH nodes retain bounded settlement evidence without claiming remote cancellation |
| `Turn+Mac.swift` | `Turn` holds Mac admission and continuation; `MacOperationContext` carries native call-stack state |
| `VisionColorRegionLayer.swift` | `VisionColorRegionResult`, `VisionPixelGrid`, `VisionColorRegionLayer` |
| `VisionFourVerbAdapter.swift` | `VisionPercept.fourVerbSupplement`: Additive physical evidence retains provenance and abstention |
| `VisionHandles.swift` | `VisionHandles` |
| `VisionImageGeometry.swift` | Owned bitmaps and geometry-preserving crops; failed requested crops remain unavailable |
| `VisionPercept.swift` | `VisionAffordanceRow`, `VisionReadoutRow`, `VisionRecognizedText`, `VisionPercept` |
| `VisionPerceptionCompiler.swift` | `VisionPerceptionError`, `VisionRowDraft`, `VisionPerceptionCompiler` |
| `VisionPerceptionTypes.swift` | `VisionConfidence`, `VisionStateGuess`, `VisionEvidenceSource`, `VisionCandidate` |
| `VisionRoleGuess.swift` | `VisionRoleGuess` |
| `VisionSaliencyLayer.swift` | `VisionSaliencyLayer`, `VisionKitSalienceProvider` |
| `VisionTextBandLayer.swift` | `VisionTextBand`, `VisionTextBandLayer` |
| `VisionTextLayer.swift` | `VisionTextLayerResult`, `VisionTextLayer`, `VisionKitTextRecognizer` |
| `VisionVisualObjects.swift` | `VisionLiveRegionIdentity`, `VisionLiveOccludedRegion`, `VisionPercept`: Physical evidence and spatial relations |
<!-- END GENERATED BLUEPRINT -->

`MacAttentionSessionStore.shutdown()` closes driver/session admission and ends
passive observation; ordinary session stop/expiry intentionally leaves that
observation protecting acts. `MacPersonInput.shutdown()` disables the tap/timer,
stops its retained run loop and acknowledges actual thread exit. These terminal
domain APIs, and `MacAppIndex.shutdown()`, still require the engine termination
caller outside the MacControl lane; they do not run merely because they exist.

### MemoryV2

Canonical memory, graph schema, derived indexing and checked graph reads share
one owner. The graph resolves MemoryStorage directly while retaining its
missing-database refusal and per-path single-flight pool cache.

Directory: `Modules/NativeAgentCore/Sources/MemoryV2/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MemoryV2/ -->
| File | Owns |
|---|---|
| `AdaptiveMemoryFacts.swift` | shared interpretation with person words, completed acts, reply delivery and open moments; durable fact/fold settlement |
| `AdaptiveMemoryPromises.swift` | `AdaptiveMemoryPromoter`: which turns are moments and of what share, turn-owned completed acts, promise matching and evidence-backed closure |
| `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: event-owned owed-turn recovery with recorded provenance |
| `AdaptiveMemoryValues.swift` | Adaptive candidates, extraction evidence, observation and shared hygiene vocabulary |
| `EmbeddingModelDownload.swift` | `EmbeddingModelDownload`: checked resumable installation and convergence |
| `KnowledgeGraph+CanonicalRebuild.swift` | `SwiftNativeKnowledgeGraphIndexer`, `rebuildMemoryDerivedGraphFromCanonicalStore`, `reconcileMemoryIndexFingerprints` |
| `KnowledgeGraph+ContextRelations.swift` | Bounded typed entity relations with disclosure and provenance evidence |
| `KnowledgeGraph+Disclosure.swift` | `KnowledgeGraphMemoryDisclosure`: source-backed audience checks |
| `KnowledgeGraph+GC.swift` | Explicit/approved orphan collection retaining source provenance and the primary-user role hub |
| `KnowledgeGraph+GrowthDistillation.swift` | Independent REM/GROWTH provenance through the canonical graph store |
| `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact`: canonical indexing and fenced reconciliation |
| `KnowledgeGraph+PoolCache.swift` | MemoryStorage pool resolution, missing-file refusal and per-path single-flight |
| `KnowledgeGraph+PrimaryUserIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`, `profileNames`, `primaryUserName`, `consolidatePrimaryUserEntities`, `removeUnreferencedPrimaryUserRole` |
| `KnowledgeGraph+RelatedEntities.swift` | Bounded one-hop entity reads for already-disclosed memory IDs |
| `KnowledgeGraph+SQLite.swift` | checked canonical SQLite reads and strict bounded graph serialization |
| `KnowledgeGraph+StudioRelationAudit.swift` | Checked Studio relation audit and reconciliation evidence |
| `KnowledgeGraph+StudioRelations.swift` | Studio journal relation publication with its own provenance |
| `KnowledgeGraph.swift` | Canonical graph candidate ranking and entity search |
| `KnowledgeGraphMaintenanceActions.swift` | `KnowledgeGraphMaintenanceActions`: exact-reviewed-set orphan removal |
| `KnowledgeGraphProjectionModels.swift` | `AgentGraphNode` struct |
| `KnowledgeGraphReadProjection.swift` | `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData`: checked graph projections |
| `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: bounded checked canonical reads |
| `KnowledgeGraphTypedRead.swift` | Typed checked projections on `SwiftNativeKnowledgeGraphReader` |
| `MemoryCandidateQuality.swift` | `MemoryCandidateQuality`: source-independent shape gates |
| `MemoryDataProvenance.swift` | `MemoryDataProvenance` builds a write's root from the stem and reads the steer from roots; `MemoryWriteContext` holds the turn, sense reads and telling |
| `MemoryEmbeddingEpoch.swift` | vector-space identity, item outcomes and owned convergence |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring`: candidate bounds, decay and explicit kinds |
| `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: record privacy independent of tool admission |
| `MemorySenseProvenance.swift` | `MemorySenseProvenance`, `MemoryStorage.markVersionWrong`: warnings and sense-version metadata |
| `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery (the journal's owed turns) wire models |
| `MemoryStatusProjection.swift` | `MemoryV2NativeStackSnapshot`: memory and embedding health, recent misses |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+Comparison.swift` | `MemoryStorage`: comparison keys, scope, epochs and polarity |
| `MemoryStorage+Corrections.swift` | `MemoryStorage`, `correctionMoments`: idempotent canonical correction occurrences; session-and-time read |
| `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: atomic corpus activation and per-item failures |
| `MemoryStorage+Integrity.swift` | `MemoryStorage`, `requireSemanticIntegrity`, `spotlightSnapshot`, `createConsistentBackup` |
| `MemoryStorage+Migrations.swift` | `MemoryStorage.migrator`; registered GRDB schema migrations |
| `MemoryStorage+Projections.swift` | `MemoryStorage`, `userPromptCore`: ordered derived hooks and user prompt core |
| `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |
| `MemoryStorage+Recall.swift` | `MemoryStorage`, `invalidateRecallCache`, `rankedRecall`, `recall` |
| `MemoryStorage+Tombstones.swift` | `MemoryStorage`, `nearestTombstones`: exact/semantic suppression and owed vectors |
| `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |
| `MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter`: live interpretation and provenance-bound settlement |
| `MemoryV2+DueDateStamp.swift` | `MemoryDueDateStamp`: writer-named instants and horizon labels |
| `MemoryV2+Embedding.swift` | `CoreMLEmbeddingProvider`: checked real-model loading and batch outcomes |
| `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`: serving backend, action index and owned convergence |
| `MemoryV2+FoundationModels.swift` | `OnDeviceClassification`: exact category prompt and reply parsing |
| `MemoryV2+KindBackfill.swift` | Approved canonical category writes; the approval is the one matter the person sees and its owner draws its face |
| `MemoryV2+KindStamp.swift` | `MemoryKindStamp`, `writerKinds`, `personKinds`: shared kind vocabulary and conservative defaults |
| `MemoryV2+MemoryManager.swift` | Grounded decisions, promise candidates and evidence-backed intention outcomes |
| `MemoryV2+Moments.swift` | `MemoryMoments`: moment-row classification and recall origin |
| `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate`: checked saved memory authority |
| `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |
| `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`, `recordRecallHits`, `recall`, `readMemoryRecord`: paged recall and delivered-hit credit |
| `MemoryV2+RecallQueryExpansion.swift` | `MemoryRecallQueryExpansion`: persona/user name-aware first-person recall rewrites |
| `MemoryV2+SharedInstance.swift` | `SwiftNativeMemoryV2`, `MemoryStorage`: canonical owner, attachment and projections |
| `MemoryV2+Spotlight.swift` | generation-proven rebuilds and serialized projection |
| `MemoryV2+Storage.swift` | `MemoryStorage`, `statusCounts`, `curationPage`: canonical mutations and bounded curation |
| `MemoryV2+TextClip.swift` | `MemoryTextClip`: shared sentence/word-safe display clipping and bounded memory text presentation |
| `MemoryV2+UserMDGen.swift` | `UserMDGenerator`, `MemoryKindStamp.personKinds`, `UserMDAutogenMarkers.promptByteCap` |
| `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |
| `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `emitDiagnostic` |
| `MemoryV2Contracts.swift` | `MemoryCommitArguments`, `MemoryProposalEvidence`, `MemoryPatchContract` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MemoryV2 diagnostics |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractEntities`, `taggedNameIsCredible` |
| `WordPieceTokenizer.swift` | `WordPieceTokenizer`: bge BERT vocabulary tokenization, greedy subwords and encoded token IDs |
<!-- END GENERATED BLUEPRINT -->

### NativeAgentCore

Directory: `Modules/NativeAgentCore/Sources/NativeAgentCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentCore/ -->
| File | Owns |
|---|---|
| `AgentHostACP.swift` | `AgentHostACP`: stdio contracts and version admission |
| `AgentHostCommandLines.swift` | `AgentHostCommandLines`: CLI contracts and scrubbed launches |
| `AgentPeerTransport.swift` | Canonical contact transport vocabulary shared by contact storage and checked security effect profiling |
| `BridgeCore.swift` | Shared HTTP framing, bearer comparison, loopback/authentication admission and response transport |
| `BridgeRoutingPrefix.swift` | `BridgeRoutingPrefix`: bounded stored-prefix parsing/stripping; caller retains provenance admission |
| `CapabilityLifecycle.swift` | `CapabilityLifecycle`: shared lifecycle and keep authority |
| `CausalTransitionEvidence.swift` | `CausalTransitionEvidence`: assignment evidence grants no authority |
| `ChatSessionIDPath.swift` | `NativeAgentChatSessionID`: colon IDs without traversal |
| `ChatToolInvocation.swift` | `ChatToolInvocation`: explicit tool-operation state with owner-declared parts |
| `ContactCaller.swift` | `ContactCaller`: who calls through a contact's door, its own conversation id, its name and whether it still runs |
| `ContextSecretContentPolicy.swift` | Shared credential redaction and nested URL decoding |
| `DerivedStateInvalidation.swift` | `DerivedStateInvalidationCenter`: writes wake derived readers |
| `Expectation.swift` | `Expectation`: confidence and measured-cost admission |
| `LLMCall.swift` | `LLMCall`: explicit call identity and request shape shared by all `LLMClient` methods |
| `LLMClient.swift` | `LLMClient`, `LLMToolSchema`: completion, streams and local tool effect declarations |
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `LifecyclePrimitives.swift` | `ScopedWaiter`, `BoundedWait`: parking and bounded waits |
| `MacIntegrationAccess.swift` | `MacIntegrationAccess`, `MacIntegrationPermissionMode`: a tool's declared integration and axis |
| `ManagedProcess.swift` | `ManagedProcess`, `OwnedProcessGroup`: checked process groups and settlement |
| `MemoryDisplayText.swift` | `MemoryDisplayText`: prompt rendering and coverage keys |
| `MotorActionReadModel.swift` | `MotorActionReadModel`: progress projection; domain authority stays native |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | checked process-cached current app stamps; incomplete identity unavailable; `writeLaunchStamp` refuses it |
| `NativeLoopbackListenerParameters.swift` | Fixed-port listeners and retained bounded diagnostics |
| `NativeTimestampFormat.swift` | Core alias to Shared's locked wire timestamp owner |
| `NetworkSense.swift` | One path monitor; network-return waits and body wakes follow path events |
| `OrganBody.swift` | `OrganBody`: the one body projection (each organ's line and deviation), the felt-memory rule and the body read hook |
| `OrganPulse.swift` | `OrganPulse` beats and recording hook; `OrganRecord` derives profile and deviation from the record's newest beats |
| `PersonOnlyWindows.swift` | `PersonOnlyWindows`: capture exclusion and input coordination |
| `ProcessTreeReaper.swift` | `ProcessTreeReaper`, `OwnedProcessGroup`: identity-bound process evidence |
| `ProviderCallEvidence.swift` | Payload-free provider lifecycle and first-output timing evidence |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `REMReplacement.swift` | Source-bound displaced REM content and shared review wording; missing history is not recorded |
| `RecallLexicalNormalization.swift` | `characterEditDistance`, `RecallLexicalNormalization`: shared retrieval normalization |
| `SSEEventStream.swift` | `ProviderRequestLifetime`, `ProviderStreamContext`: explicit SSE activity and trace-only event capture |
| `Settle.swift` | `settle`: the Stop law's one primitive; settlement runs outside the caller's cancellation, exactly once (docs/STOP.md) |
| `TimeoutRace.swift` | `raceAgainstTimeout`, `ContinuationOnce`: first-wins deadline and cancellation |
| `ToolFailureAndEffects.swift` | Owner-supplied failures, remedies and declared effects |
| `Turn.swift` | `Turn`: one identity handed to everything serving it; `TurnPart` keys each owner's state |
| `TurnDeadline.swift` | `OperationDeadlines`, `TurnDeadline`, `TurnBodyLifetime`: work ceilings and owned settlement |
| `TurnPresentation.swift` | `TurnPresentationReducer`: bounded lifecycle evidence without payloads; only their acts are steps, each one identity from start to end |
| `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |
| `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`, `promptByteCap`: markers and picture bound |
| `UserMessageIntentSignals.swift` | `UserMessageIntentSignals`: lexical signals grant no effect authority |
| `VectorMath.swift` | `requireUsable`, `cosine`, `standout`, `chanceBar`: vector gates and attention thresholds |
| `WorkshopWireVocabulary.swift` | The `workshop` surface spelling and trimmed event-kind matching |
<!-- END GENERATED BLUEPRINT -->

### Onboarding

Directory: `Modules/NativeAgentCore/Sources/Onboarding/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Onboarding/ -->
| File | Owns |
|---|---|
| `Onboarding.swift` | Onboarding client roots, start verdict and ability catalog |
| `OnboardingCompletion.swift` | intent verifies persona bytes before the sentinel |
| `OnboardingIdentity.swift` | Checked identity and shared manifest/byte writer; profile and USER publication use their domain owners |
| `OnboardingProfileRepair.swift` | Missing-only profile repair under completion and profile locks; completed persona bytes stay intact |
| `OnboardingReset.swift` | Durable reset intent, exact-byte backups and recovery; backups precede completion evidence removal |
| `OnboardingTourReplay.swift` | MainActor tour replay request and once-only claim |
| `OnboardingValues.swift` | Onboarding payload, result and recovery verdict vocabulary |
| `StarterPersona.swift` | Starter persona publication through canonical document owners |
<!-- END GENERATED BLUEPRINT -->

### AuthoredCapabilities

Directory: `Modules/NativeAgentCore/Sources/AuthoredCapabilities/`

Depends on NativeAgentCore support, PersistenceCore durable I/O and Experiences for source-fault repair obligations from live part runs carrying input; file-backed sense completions record outcomes without this obligation; owns the authored part contract without importing feature executors.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AuthoredCapabilities/ -->
| File | Owns |
|---|---|
| `AbilityAccounting.swift` | Locked terminal evidence and learned-use accounting |
| `AbilityCatalog.swift` | Checked inventory and redacted identity-matched accounting projections |
| `AbilityFile.swift` | Shared canonical part file, header, reach and argument schemas |
| `AbilityStorage.swift` | Checked identity-matched file/state encoding and recovery validation |
| `AbilityStore+Seed.swift` | `AbilityStore.seedFunction`: one function of a shipped seed, as its source shows it |
| `AbilityStore.swift` | `signalled`, `wakes`, `recordRounds`, `replayed`, `tape_replay`; sealed lifecycle, state and notebooks |
| `PartCall.swift` | Strict document, form and collection vocabulary bound to packet-owned calls and reads |
| `PartFaces.swift` | Actor-owned page admission and demands; LatestRead snapshots, drawn-call checks and settlement |
| `PartTrial.swift` | `PartTrial`: the trial judge over two version tallies, decidability and the candidate test; pure, no I/O |
| `Parts.swift` | `storedRows`, `rows`; One part reader; display projections never write back; row-local name damage |
| `PersonAct.swift` | `PersonAct`, `Turn.personAct`: the person's own decision of one run of one exact door call (a tap on a row the stem composed, or a card they approved) |
| `SkillRunContext.swift` | Explicit authored run options and hand-back refusal |
| `Turn+Skills.swift` | `Turn` holds authored run ownership and file reach |
<!-- END GENERATED BLUEPRINT -->

### PersistenceCore

Directory: `Modules/NativeAgentCore/Sources/PersistenceCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersistenceCore/ -->
| File | Owns |
|---|---|
| `CapabilityLifecycle+FileAdmission.swift` | CapabilityLifecycle file-write admission, peer-content protection and owner-off reconciliation |
| `CheckedFixedSizeSecretFile.swift` | `CheckedFixedSizeSecretFile`; Missing-only creation; invalid bytes preserved. |
| `CodexHandoff.swift` | `CodexHandoff.path`; One explicit handoff identity. |
| `ConnectorActionReceipt.swift` | Sole capped receipt writer; health projects outcomes. |
| `ConnectorInputValue.swift` | Checked transport scalars and allowlists; damaged authority throws. |
| `ConnectorOAuthRegistry.swift` | `writeRegistry`, `connectionDecision`; Only owner acts record consent. |
| `DataRootLife.swift` | `DataRootLife`, `first`, `life(of:)`; Stamp work at birth; restore stops cross-life work. |
| `DeviceSecretKeychain.swift` | Device-only writes retain unverified outcomes for exact-item repair. |
| `DiskStorageOwner.swift` | `DiskStorageOwner`; Contained retention moves preserve history in Trash. |
| `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy`; Path-owned retention budgets. |
| `FileChangeEvents.swift` | `FileChangeEvents`: bounded cancellable async vnode event bridge with one initial edge only after successful arming |
| `FileChangeWatcher.swift` | `FileChangeWatcher`, `Entry`; Shared vnode, independent cancellation. |
| `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |
| `InlineInteraction.swift` | `InlineInteraction`: durable card/continuation contract; owners retain authority |
| `InlineInteractionDescriptor.swift` | A card's control binding and `InlineCardField` vocabulary, beside the record its owners keep; no executable descriptors |
| `InstallPaths.swift` | Install-owned ports, bridge paths and Chrome relay identity. |
| `JSONLRetention.swift` | Path-owned envelope, capped append and retention cadence. |
| `JSONRow.swift` | `JSONRow` checked stored-object reads; required/optional typed fields and named malformed-row errors |
| `JSONSchema.swift` | `JSONValue.SchemaProblem`, `validate`, `schemaProblem`, `ToolSchema`; Validate complete schemas. |
| `JSONValue+Accessors.swift` | Explicit numeric coercion and unknown-field handling. |
| `JSONValue.swift` | `JSONValue`, `decodeCompletion`, `fromEncodable`, `mapStrings`, `decodedExactly`, `digest`, `differences` |
| `Keyring.swift` | `Keyring`, `kept`, `{{secret:<name>}}`; Secret storage and grant identity only. |
| `MemoryRoot.swift` | `MemoryRoot`: one moment a memory reached the agent (how, by, at, through); its codec, union, lines and short lead form |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for PersistenceCore diagnostics |
| `NativeActionRouteSupport.swift` | `NativeActionWire` enum; `jsonValueBody`, `notImplemented` |
| `NativeAgentWorkspaceRoot.swift` | Byte-exact containment and entry identity; callers own admission. |
| `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |
| `NotificationChannelPreference.swift` | Shared delivery-admission preferences. |
| `NotificationDeliveryOutcome.swift` | One door's delivery or quiet-hours deferral; recorded intent is not transport acceptance |
| `OncePerPeriodReservation.swift` | `OncePerPeriodReservation`; Locked durable periodic admission. |
| `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock`; inode-checked kernel locks and async acquisition. |
| `PersistenceCore.swift` | `PhonePlaceHistory`; Durable atomic storage and strict physical-line reads. |
| `PersistenceDataRoot.swift` | `DataRootLife.life(of:)`; Stable process root; explicit roots retain literal spelling. |
| `PhoneSenseHistory.swift` | Bounded phone evidence preserves each source and first movement. |
| `RegistryTimestampSortKey.swift` | Absent dates stay undated; malformed dates throw. |
| `Repair.swift` | Owner-issued remedies, reconciliation and honest terminal outcomes. |
| `SnapshotTailOpLog.swift` | `SnapshotTailOpLog`: shared base-plus-tail replay, feed integrity and bounded compaction bookkeeping |
| `StoreChangeBus.swift` | `StoreChangeBus`: process-local multicast store invalidations; files remain authoritative |
| `VerifiedPath.swift` | VerifiedPath owns symlink-refusing descriptor-relative path walks, opens and file transfers |
<!-- END GENERATED BLUEPRINT -->

### Experiences

Directory: `Modules/NativeAgentCore/Sources/Experiences/`

Depends only on GRDB, so every owner of a happening can write it ([EXPERIENCE](EXPERIENCE.md)).
`Attention.swift` is the one intake every happening is posted through ([Subconscious](SUBCONSCIOUS.md#attention)).

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Experiences/ -->
| File | Owns |
|---|---|
| `Attention.swift` | `Attention`: committed happening intake and checked membership, weighing and thought records |
| `Detail.swift` | `ExperienceStore`: ordered detail writes, checked durable flush and retained attention provenance |
| `Experience.swift` | `ExperienceStore`: append-only experiences, obligations, checked projections and write-fed changes |
| `Flow.swift` | `Flow`. |
| `ForPerson.swift` | `Matter`, `Door`, `ForPerson`: the person's matters, deliveries, reading and inbox wire |
| `Owed.swift` | Nonperson births and existing obligation settlements; person asks are born only through Matter |
| `RepairDebt.swift` | `RepairDebt`: typed repair owed by an experience, with one codec to persisted claim lines |
| `RepairOwed.swift` | `RepairOwed`, `attempt`, `isOwed`. |
<!-- END GENERATED BLUEPRINT -->

### PersonaEngine

Built-in skill guidance inventory and display models live with the persona;
they read persona/skills/bodies and do not execute guidance.

Directory: `Modules/NativeAgentCore/Sources/PersonaEngine/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersonaEngine/ -->
| File | Owns |
|---|---|
| `InstalledSkillInventory.swift` | InstalledSkillInventory owner. |
| `NativeAgentPublicSafety.swift` | `NativeAgentPublicSafety`. |
| `PersonaCompiler+Normalization.swift` | `PersonaCompiler.decodeProfile`. |
| `PersonaEngine+Compiler.swift` | `PersonaCompiler`, `configuredNames`. |
| `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`. |
| `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`. |
| `PersonaEngine.swift` | `SwiftNativePersonaEngine`, `PersonaSelection`. |
| `PersonaTemplates.swift` | One genesis template owner shared by onboarding and compilation's named missing-only document creation |
| `Skills.swift` | `SkillRecord`: built-in guidance carried directly through discovery, reads, Mac and phone |
<!-- END GENERATED BLUEPRINT -->

### Privacy

Directory: `Modules/NativeAgentCore/Sources/Privacy/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Privacy/ -->
| File | Owns |
|---|---|
| `NativeAgentSecretRedactor.swift` | Canonical credential recognition and redaction. |
| `NativeAppSecretRedactor.swift` | App privacy extends canonical credential redaction. |
| `PrivacyMap.swift` | Owner-aligned inventory and export scopes; phone projections stay distinct. |
<!-- END GENERATED BLUEPRINT -->

### ProviderRouting

Directory: `Modules/NativeAgentCore/Sources/ProviderRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ProviderRouting/ -->
| File | Owns |
|---|---|
| `AsyncSerialQueue.swift` | FIFO completion and caller cancellation for shared single-use OAuth token refreshes |
| `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |
| `ChatCompletionsStreamDecoder.swift` | `ChatCompletionsStreamDecoder`: checked stream terminals and fragments |
| `ChatGPTAccountModelRefresh.swift` | `ChatGPTAccountModelRefresh`: account discovery outside dispatch |
| `ChatGPTCredentials.swift` | ChatGPTTransport credential discovery, exact account binding and serialized single-use token refresh |
| `ChatGPTResponsesBody.swift` | ChatGPTTransport Responses wire body, structured input roles and native tool encoding |
| `ChatGPTTransport.swift` | ChatGPT OAuth request/stream/error execution with conversation or stable workshop-surface cache routing |
| `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog`, `load`, `matchingModels`, `codex.model_catalog:<file path>` |
| `CodexExecutable.swift` | `CodexExecutable`: shared executable selection |
| `CodexOAuthAccessContext.swift` | Checked Codex OAuth access identity and stable re-sign-in-required exhaustion marker |
| `FirstPartyModelCatalog.swift` | `FirstPartyModelCatalog`: route-owned model contracts |
| `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`, `spent`: one receipt per request; partial output settles |
| `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared Messages transport |
| `LLMClient+AnthropicNativeTools.swift` | `AnthropicTransport`, `ProviderWire`: ordered native calls and signed replay |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthTransport`, `requestOutputTokens`: OAuth refresh and indexed blocks |
| `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthTransport`, `ephemeralCacheControl`, `currentTurnUserIndex` |
| `LLMClient+CodexAdapter.swift` | `CodexProcess`: one process lifecycle; strict UTF-8 pipes |
| `LLMClient+MoonshotAdapter.swift` | `MoonshotTransport`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |
| `LLMClient+OpenAIAdapter.swift` | `OpenAITransport`: checked API transport and message encoding |
| `LLMClient+OpenAIOAuthCredentials.swift` | `ChatGPTTransport.preferredAuthPath`: one pinned credential source |
| `LLMClient+OpenAIResponsesDecoding.swift` | `ChatGPTTransport`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |
| `LLMClient+OpenRouterAdapter.swift` | `OpenRouterTransport`: gateway-owned model transport |
| `LLMClient+Real.swift` | `makeResidentProviderLLMClient`, `SwiftNativeLLMClient`, `ProviderToolCapability.checkedWire` |
| `LLMClient+XAIOAuthDirectAdapter.swift` | `XAIOAuthTransport`: path-serialized token refresh |
| `LLMProviderStatusFeed.swift` | checked, credential-bound observation |
| `LLMRequestShape.swift` | `ToolContractWeight`: bounded request receipts and secondary-call isolation |
| `LLMUsage.swift` | Provider usage parsing, counter semantics, streaming accumulation and saturating logical input totals |
| `ModelCatalogCache.swift` | Credential-bound catalog reads and explicitly refreshed, ordered publication |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ProviderRouting diagnostics |
| `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model discovery |
| `NativeOAuthCallbackPolicy.swift` | exact callback state |
| `NativeOAuthFlow+Configs.swift` | ProviderOAuthConfig owns provider client identities and token endpoints; buildAuthURL, exchangeCode |
| `NativeOAuthFlow+Helpers.swift` | redirect-refusing grants; checked token replies and server-paced device authorization |
| `NativeOAuthFlow+Keyring.swift` | `Keyring`, `granted`, `grant`, `forget`, `values`, `NativeOAuthFlow`, `grantSecret` |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackPageMessage` |
| `NativeOAuthFlow+TokenStatus.swift` | Adapter-owned sign-in verdicts and off-UI credential deletion, CLI consent and confirmed repair |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | Checked sign-in ownership and setup-token persistence off the UI actor; browser presentation uses its platform port |
| `NativeOAuthLoopbackCallbackServer.swift` | callback-owned wait; cancellation closes blocking socket I/O on Dispatch |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort`, `runAuthSession`, `isCanceledLogin`, `makeLoopbackSession`, `openBrowser`, `runLoopbackAuthSession` |
| `OAuthCredentialDecoding.swift` | Shared JWT payload and OAuth expiry decoding; `OAuthRefreshBinding`: account identity and refresh continuity |
| `OAuthCredentialHealth.swift` | Secret-free maintenance projection of adapter-owned expiry, refresh binding and readiness verdicts |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` (per credential path or key) |
| `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: route-owned controls |
| `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed membership and controls |
| `ProviderAPIKeyStore.swift` | Provider reference/string validation; byte insertion, readback and deletion delegate to DeviceSecretKeychain |
| `ProviderConfiguration.swift` | Byte-checked provider configuration decode under the writer's lock with fresh credential/readiness facts |
| `ProviderConnectionProbe.swift` | Native probe capabilities and request-bound OAuth credential evidence; API-key connection probes |
| `ProviderErrorBodyDrain.swift` | Error diagnostics settled by body EOF, read error, byte cap or cancellation |
| `ProviderFailure.swift` | `Diagnostic`, `ToolFailureError`, `repair`: typed failure and repair ownership |
| `ProviderOAuthAdmission.swift` | Observed OAuth credential admission and expiry interpretation |
| `ProviderOutputDiagnostics.swift` | Redacted provider-output diagnostics and checked retention |
| `ProviderReadiness.swift` | exact credential/catalog readiness |
| `ProviderReasoningSelection.swift` | Preserves an explicit effort or the row's declared default; capability admission belongs to routing |
| `ProviderRecoveryPolicy.swift` | `ProviderRecoveryPolicy`: typed failure classification and descriptions |
| `ProviderReplyWork.swift` | stop joins transport exit and drain |
| `ProviderRouteDerivation.swift` | one snapshot; catalog faults stay route-local |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting`, `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `adoptConnectedProvider`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting` |
| `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot`, `TurnRouteAdmission`, `SwiftNativeProviderRouting` |
| `ProviderRoutingValues.swift` | checked scalar vocabulary; no inferred controls |
| `ProviderSelection.swift` | recoverable forward picker transactions |
| `ProviderSignInHandoff.swift` | provider sign-in handoff state |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderStreamGuard.swift` | Provider HTTP session and one stream lifetime; external envelope configuration |
| `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared wire grammar |
| `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive bounded lifecycle evidence |
| `RequestPrefixReceipt.swift` | `RequestPrefixReceipt`: hash exact bytes without retaining prompt text |
| `Turn+Provider.swift` | `Turn` part ProviderRouting owns: the per-turn provider/model choice |
| `XAIOAuthCredentialStore.swift` | Locked xAI token storage, immutable Keychain references, refresh reads and sign-out cleanup |
<!-- END GENERATED BLUEPRINT -->

### Research

Directory: `Modules/NativeAgentCore/Sources/Research/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Research/ -->
| File | Owns |
|---|---|
| `BoundedResearchDownload.swift` | `BoundedResearchDownload`: bound bytes before appending |
| `Research+Autodetect.swift` | Checked setup discovery; candidate gaps stay local |
| `Research+Helpers.swift` | Checked receipt retention preserves completed fetches |
| `Research+Lab.swift` | `SwiftNativeResearchClient`: saved research runs, read whole or refused |
| `Research+SearchFetch.swift` | Checked search and retained web reads |
| `Research+WebSearch.swift` | `WebSearchRoutes`: checked SearXNG results and setup failures |
| `Research.swift` | Checked search rows, named gaps and complete saved Lab records |
| `ResearchHTMLExtraction.swift` | `ResearchHTMLExtraction`: cancellable HTML extraction |
| `ResearchTextDecoding.swift` | `ResearchTextDecoding`: strict response encoding |
| `ResearchTransports.swift` | `URLSessionResearchHTTPClient.getBounded`, `MacControl.ProcessExecution` |
<!-- END GENERATED BLUEPRINT -->

### SchedulerExecution

Directory: `Modules/NativeAgentCore/Sources/SchedulerExecution/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SchedulerExecution/ -->
| File | Owns |
|---|---|
| `ClockWork+Cycles.swift` | The dream and REM cards' wording and today's diary entries |
| `ClockWork.swift` | `ClockWork`: what the one clock's dream, REM, watch and scan deliveries tell; one dream matter shared with manual dreams |
<!-- END GENERATED BLUEPRINT -->

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/ !Modules/NativeAgentCore/Sources/Senses/Owned*.swift !Modules/NativeAgentCore/Sources/Senses/SensesContract.swift !Modules/NativeAgentCore/Sources/Senses/SensesHub.swift !Modules/NativeAgentCore/Sources/Senses/SenseNewsBoard.swift !Modules/NativeAgentCore/Sources/Senses/Helper*.swift !Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift !Modules/NativeAgentCore/Sources/Senses/SenseScreenThings.swift !Modules/NativeAgentCore/Sources/Senses/SenseTurnReads.swift -->
| File | Owns |
|---|---|
| `BuiltInSenses.swift` | Locked bundle manifests; file overrides win; AbilityStore owns accounting |
| `ExistingCornersSourceProvider.swift` | `ExistingCornersSourceProvider`, `SenseNativePages`: gated material, watches and bounded pages |
| `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |
| `FileSenseRegistry+Storage.swift` | Sealed source validation, bounded manifests, timestamp validation and path/symlink fences |
| `FileSenseRegistry.swift` | AbilityStore projections and publication; locked helper lifetimes exclude read bookkeeping |
| `SenseHelperMaterial.swift` | Bounded file and package material conversion for the existing sense helper |
| `SenseHelperProcess.swift` | Request and watch supervision; pending calls join settlement and receipts retain returned effects |
<!-- END GENERATED BLUEPRINT -->

### SlackBot

Directory: `Modules/NativeAgentCore/Sources/SlackBot/`

`SlackSocketModeLoop.swift` owns connection lifetime, ingress and shared state.
Its extensions organize methods over that same state. Socket Mode alone owns
ingress; `+WebAPI` reads exact reply effects only for acceptance reconciliation.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SlackBot/ -->
| File | Owns |
|---|---|
| `SlackCredentials.swift` | Immutable Keychain grants selected by connectors/slack/auth.json; locked metadata save and revocation |
| `SlackInboundDeliveryJournal.swift` | Durable admission and canonical replies; generation uncertainty never authorizes replay |
| `SlackNotificationDelivery.swift` | `SlackWebAPI.notificationOutcome`: checked preflight, API refusal and uncertain dispatch |
| `SlackReplyPreview.swift` | `SlackReplyPreview`: latest-value publication joins admitted sends before final delivery |
| `SlackRuntimeDiagnostics.swift` | Checked diagnostic storage; connection evidence reads the live socket owner without a freshness clock |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | TransportAllowlist's canonical Slack policy; throwing ingress and toggle readers retain unavailable authority |
| `SlackSocketModeLoop+Answers.swift` | `SlackSocketModeLoop`: durable replies, live publication and reconciliation |
| `SlackSocketModeLoop+Evidence.swift` | `SlackSocketModeLoop`: bounded, redacted diagnostics and envelope evidence |
| `SlackSocketModeLoop+Media.swift` | Complete attachment hydration precedes chat; preparation failures retain their own reply |
| `SlackSocketModeLoop+SessionClassification.swift` | Protocol disconnect reason owns session closure; elapsed time decides nothing |
| `SlackSocketModeLoop+SessionDelivery.swift` | Journal previews; final recovery joins the preview writer before updating its message |
| `SlackSocketModeLoop+WebAPI.swift` | `SlackSocketModeLoop.slackAPI`: checked reads for accepted-reply reconciliation |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop`, `tick`, `tickOutcome`: socket lifetime independent of accepted handlers |
| `SlackSocketModeSupport.swift` | Checked socket errors |
| `SlackTurnContracts.swift` | `SlackInboundFile` struct |
| `SlackTurnIngress.swift` | Configured Slack ingress shares persona selection, profiled chat and allowlist authority |
| `SlackWebAPI.swift` | Canonical text sends; strict response envelopes and delivery evidence |
<!-- END GENERATED BLUEPRINT -->

### StandingBots

Directory: `Modules/NativeAgentCore/Sources/StandingBots/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/StandingBots/ -->
| File | Owns |
|---|---|
| `BotDefinitionStore.swift` | Atomic definition/audit persistence, exact session ownership and typed edits |
| `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |
| `BotEventTriggers.swift` | `BotEventRouter`, `BotEventStore`: Slack admission and durable wake evidence |
| `BotHeadline.swift` | `BotHeadline` enum; `make`, `clipped` preserve whole-word reply headlines |
| `BotRunQueue.swift` | `BotRunQueue`; `enqueue`, `presence`, `refusal`: commit claim/refusal before removal; daily reservations |
| `BotRunner.swift` | `BotRunner` actor; `run`, `ask`: shared admission, accounting and typed notification verdicts |
| `BotRunnerDeadline.swift` | Await the helper session's own terminal result |
| `BotRunnerScheduler.swift` | `BotRunnerScheduler`: helper cadence declarations, queued runs and durable scheduling failures |
| `BotTurnRunner.swift` | `BotTurnRunner`: helper rounds; `JobResult` precedes progress/persistence; Stop settles partial output |
| `BotsShelfRead.swift` | `BotRunnerScheduler.BotSchedule` drives shared shelf, Desk and phone classification |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for StandingBots diagnostics |
| `ShelfApprovalReconciliation.swift` | `ShelfStore`: all readers project canonical approval decisions after shelf evidence |
| `ShelfStore.swift` | `ShelfStore`; `append`, `settleApproval`: indexed history, canonical approvals and exact notification acknowledgement |
| `StandingBotSchedule.swift` | `StandingBotSchedule` enum; `parse`, `words` |
| `StandingBotsDisk.swift` | `StandingBotsDisk` struct; `validatePath`, `locked` |
| `StandingBotsModels.swift` | Helper identity/job/provider/budget definitions and cadence, run and shelf values |
| `Turn+Bots.swift` | `Turn` part standing bots own: the authenticated event a helper run answers |
<!-- END GENERATED BLUEPRINT -->

### Studio

Directory: `Modules/NativeAgentCore/Sources/Studio/`

Studio and its consumers use NativeTimestampFormat directly for pure timestamp
formatting/parsing; Studio has no clock-only dependency on Desk. Desk owns
its page deadline, invalidated by system-clock and time-zone changes.

`NativeAgentEngine.make` owns its immutable-root `MakeStudio.Shelf`, preview
reads, file/revision title projections, coalesced refresh task and file watcher.
Each preview carries its file/revision title feed key; the view reads that slot.
Terminal shutdown closes future starts;
cancelled reads never publish or rearm the retired shelf.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Studio/ -->
| File | Owns |
|---|---|
| `MakeStudio.swift` | Root-scoped artifacts, versions and previews; LatestRead shelf; file/revision title feed slots; shutdown drain |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Studio diagnostics |
| `StudioCanon.swift` | `Resources/abilities/studio-canon.js`: Append-only canon and repair debt |
| `StudioConsult.swift` | Immutable consults and checked errors |
| `StudioJournalEntry.swift` | Strict encounter rows and projected amendments |
| `StudioRecall.swift` | Read-only recall and encounter-intake values |
| `StudioStore.swift` | `encounterIntakePage`, `namedEncounterIntake`, `Resources/abilities/studio-intake.js`: Append-only checked intake |
| `StudioWorkingShelf.swift` | Shelf quotes preserve corrections and read gaps |
<!-- END GENERATED BLUEPRINT -->

### SwarmRuns

Directory: `Modules/NativeAgentCore/Sources/SwarmRuns/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SwarmRuns/ -->
| File | Owns |
|---|---|
| `RunLedger.swift` | `RunLedger`: cross-surface completed-run summary |
<!-- END GENERATED BLUEPRINT -->

### SystemOps

Directory: `Modules/NativeAgentCore/Sources/SystemOps/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SystemOps/ -->
| File | Owns |
|---|---|
| `SoftwareUpdateState.swift` | checked update-notice persistence: absent, available, stale or byte-preserved unreadable evidence |
| `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |
| `SystemOps+Production.swift` | `ProductionExport`: Checked newest-first export registry and archives |
<!-- END GENERATED BLUEPRINT -->

### TelegramBot

Directory: `Modules/NativeAgentCore/Sources/TelegramBot/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TelegramBot/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TelegramBot diagnostics |
| `TelegramApprovalHandling.swift` | `TelegramApprovalHandling`: a card's button or a slash decision names one action of its matter's Inbox row |
| `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver`, `onDelta`, `finalize`: join before final send |
| `TelegramBot+APIHelpers.swift` | `_tgBuildBotURL`: canonical path-segment and query encoding for Telegram Bot API URLs |
| `TelegramBot+Client.swift` | `SwiftNativeTelegramBot`: checked status and send lanes |
| `TelegramBot+Config.swift` | `voice_max_bytes`, `ownerUserId`, `readConfigurationStatus`: locked grants and revisions |
| `TelegramBot+Models.swift` | Typed wire failures, sender identity, reply context and exact numeric decoding |
| `TelegramBot+Settings.swift` | Mobile operation prerequisites delegate saved field validation to `TelegramConfig.validateSavedConfiguration` |
| `TelegramChatHandling.swift` | Sender identity stays separate from chat identity; handlers return reply faces |
| `TelegramCommandMenu.swift` | `TelegramCommandMenuStatus` and `TelegramCommandMenuSync`: command-menu synchronization status contract |
| `TelegramCommandPolicy.swift` | Parts author menu/help words; native code owns reserved controls, provenance and writes |
| `TelegramCommands.swift` | Command identities, parsing and dispatch into the destination conversation |
| `TelegramMediaAttachment.swift` | `TelegramMediaDownloader`: bound declared and actual bytes |
| `TelegramModelSelection.swift` | Checked account-scoped catalogs; `TelegramCommandSender` attests command provenance and the single owner; model controls invoke the person's canonical Providers call |
| `TelegramModelSelectionHandling.swift` | `TelegramModelSelectionCallback`: checked callback identities |
| `TelegramNotificationDelivery.swift` | `TelegramPollLoop.notificationOutcome`: accept only complete chunked sends; failures after accepted parts remain unknown and cannot authorize whole-message replay |
| `TelegramOffsetCursor.swift` | `TelegramOffsetCursor`: monotonic; only missing state bootstraps |
| `TelegramPartPolicy.swift` | Parts draw checked choices; native code owns callback admission and routing writes |
| `TelegramPollBackoff.swift` | `TelegramExponentialBackoff`, `TelegramErrorLog`: bounded locked rotation |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`: an allowlisted sender's card answers go to the card's matter's Inbox row |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`, `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: verified command admission and explicit saved-answer resends |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `chatAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+SessionDelivery.swift` | Resolve bound destinations and join previews before journal recovery |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: sole checked state.json reader and mutation owner (`readState`, `mutateState`) for polling and status consumers; only missing state is empty, and unreadable/non-object state fails with a dedicated telegram/state.json error and is never overwritten; bot ingress validates its current identity without global-storage migration; `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |
| `TelegramPollLoop+Transport.swift` | Checked Bot API calls; one send per admission; server-prescribed pacing and per-chat serialization |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramPollLoop.swift` | Durable admission; complete media preparation; admitted generation never replays from missing output |
| `TelegramProgressFace.swift` | Per-card epoch and LatestRead cache over redacted facts; parts author progress words |
| `TelegramRestart.swift` | Only the owner may restart; defer termination until the reply attempt |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramSessionStore.swift` | `TelegramSessionStore`: locked mint/adoption; shared anchor selects owner DM |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger`, `upsert`, `remove`, `TelegramTurnCardRestartRepairer`; unchanged durable card facts preserve their timestamp and write nothing |
| `TelegramTurnControls.swift` | `TelegramTurnControlCallback`: active-turn control markup and callback decoding retaining forum-topic identity |
| `TelegramTurnCoordinator.swift` | `TelegramTurns`: retain ownership through receipt and ingress settlement |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase`: canonical lifecycle semantics |
| `TelegramTurnProgressCardDriver.swift` | `TelegramTurnProgressCardDriver`: persist terminal identity before release |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox`, `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`: life-bound recovery |
| `TelegramVoiceTranscription.swift` | Speech final/error and cancellation own recognition; process exit owns conversion |
<!-- END GENERATED BLUEPRINT -->

### ToolRegistry

Directory: `Modules/NativeAgentCore/Sources/ToolRegistry/`

| File | Owns |
|---|---|

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ToolRegistry/ -->
| `ChatToolCatalog.swift` | `ChatToolCatalogSnapshot`: typed schema and execution policy |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ToolRegistry diagnostics |
| `ToolDescriptor.swift` | `ToolDescriptor`, `ToolExecutor`, `AppActionBinding`: one call/effect declaration |
| `ToolNameAliases.swift` | `ToolNameAliases`: one public argument/schema projection |
| `ToolRegistry.swift` | `ToolRecord`, `keepReview`, `reviewedKeepDigest`: checked records; version-bound review |
<!-- END GENERATED BLUEPRINT -->

### Transcripts

Directory: `Modules/NativeAgentCore/Sources/Transcripts/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Transcripts/ -->
| File | Owns |
|---|---|
| `ChatCancelFlag.swift` | `ChatCancelFlag`: Run-tagged Stop survives later acceptance |
| `ChatExportService.swift` | Shared chat export errors and completion value; concrete Markdown export lives beside EngineRuntime's ChatMessage |
| `ChatSessionIndexFile.swift` | `recordContinuityParticipant`, `recordConversationChange`: Durable index and continuity transactions |
| `ChatSessionRetention+ArchiveHistory.swift` | Checked archive restoration under index → transcript locks |
| `ChatSessionRetention+PinnedChats.swift` | Durable pins protect navigation and retention |
| `ChatSessionRetention+StateExpiry.swift` | Bounded orphan state expiry preserves history |
| `ChatSessionRetention.swift` | Locked archival preserves acknowledged transcript bytes |
| `ChatSessionScratch.swift` | Locked conversation scratch and one private working-memory slot; off-disk backup only |
| `ConversationAnchor.swift` | `ConversationAnchor`, `mayAnchor`: Direct-user anchor; unknown protection holds retention |
| `ConversationHistory.swift` | Exchange pairing, transcript provenance and dream consumption marks |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Transcripts diagnostics |
| `SessionConversation.swift` | `SessionConversation`: Row-backed kind and stamped index reads |
| `TranscriptRowStamp.swift` | Verified speaker and steering stamps; imports attest none |
| `TranscriptRows.swift` | `ContactThread`, `read`, `Line`, `project`, `consume`, `DelegatedReplyEnvelope`: Locked transcripts; shared display |
<!-- END GENERATED BLUEPRINT -->

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

`OneClock.swift` is the one clock: every declared time is delivered to whoever declared it
([What stays a rhythm](INTENTIONS.md#what-stays-a-rhythm)).

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TriggerScheduler/ -->
| File | Owns |
|---|---|
| `ClockRestoreFence.swift` | `ClockRestoreFence`: a restored clock keeps each time's current next occurrence, so a restore never repeats one |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TriggerScheduler diagnostics |
| `MorningBriefAssembly.swift` | Authored brief cards and inactive schedule defaults |
| `MorningBriefPart.swift` | Door-bound brief proposals; native claims and publication |
| `MorningBriefSources.swift` | Checked brief sources; unread notes read ForPerson's in-memory inbox |
| `OneClock.swift` | `OneClock`: declared times, checked recurrence and durable consumption before delivery |
| `ScheduledReads.swift` | `ScheduledReads`: create, list and cancel checked `watch:<id>` and `scan:<id>` clock times |
| `SchedulerJobNormalizer.swift` | Strict scalar, payload and watch admission shared by the rhythm grammar and scheduled reads |
| `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: a civil minute's identity, which no zone change can repeat |
| `SchedulerRecurrence.swift` | Shared recurrence, civil-minute and intention timing grammar |
| `TriggerInboxPublication.swift` | Locked inbox acceptance before delivery and receipts |
| `TriggerNotificationInbox.swift` | Trigger acceptance tells one matter with its doors; duplicates and superseded briefs read ForPerson |
| `TriggerOccurrences.swift` | Each enabled inbox time trigger is a daily `brief:<name>` time on the one clock; its delivery publishes the card |
| `TriggerScheduler.swift` | Trigger config and consent |
| `TriggerWireValues.swift` | Trigger configuration, errors, result envelopes and notification values; lossless saved-field round trips |
<!-- END GENERATED BLUEPRINT -->

### TrustCenter

Directory: `Modules/NativeAgentCore/Sources/TrustCenter/`

TrustCenter owns `SavedWorkflows`, its records, checked registry reads, stable sorting
and historical pack removal. Read projections normalize only the exact original
`memory-capture` seed to a template; customized rows and saved bytes stay intact.
Absent registries remain empty without seeding; workflow execution is unavailable.
The workflow capability reader does not write back. The demo-only installer is retired.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TrustCenter/ -->
| File | Owns |
|---|---|
| `CapabilityCatalog.swift` | Read-only checked sources/roots. |
| `CapabilityRecords+Dynamic.swift` | Owner-derived capability rows preserve missing evidence. |
| `CapabilityTrust.swift` | `SwiftNativeCapabilityTrust`: checked capability trust/catalog values, scoring, evaluation and display projections |
| `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor`, `connectorActionDescriptors`; Static schemas. |
| `ConversationSurfaceProfile.swift` | `ConversationSurfaceProfile`; One security-relevant surface identity. |
| `FeatureSurfaceRecords.swift` | `FeatureSurfaceRecord`, `featureSurfaceRecords`; Manifest reach. |
| `MacControlGate.swift` | `MacControlGate`; Origin-aware Full Mac and resolved-path policy. |
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Untrusted peer effects ask; memory retains provenance. |
| `SavedWorkflows.swift` | `SavedWorkflows`, `WorkflowStep`, `WorkflowRecord`; Checked read-only templates. |
| `SecurityCenter+FullMacPolicy.swift` | Origin-aware Full Mac admission and driven-agent launch permission |
| `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: audit `redactValue`, using Privacy's canonical detection predicates |
| `SecurityCenter+JSONUtilities.swift` | Resolved workspace containment shares execution spelling. |
| `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |
| `SecurityCenter+PathPolicy.swift` | `capabilityWritesOutsideAppData`, `pathIsInsideRoots`, `pathLikeStrings`; Byte-exact path reach. |
| `SecurityCenter+ReceiptJSON.swift` | `SecurityToolEnvelope`: `toJSONValue` |
| `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary`, `isoTimestamp` |
| `SecurityCenter+ToolProfiles.swift` | Canonical effect classification; advisory metadata grants no authority. |
| `SecurityCenter.swift` | Origin-aware checked decisions and retained audit evidence. |
| `SecurityToolAdmission.swift` | Exact-call consent carried from the approval membrane to the app dispatcher |
| `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner`, `canonicalBytes`, `existingSigningKey`; Exact signing authority. |
| `TrustAccessModeCapabilityCatalog+Read.swift` | Effective grants preserve saved restricted settings. |
| `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog`, `normalizedMode`, `macControlPolicy`; Canonical presets. |
| `TrustCenter+Autonomy.swift` | `PermissionLaw`: one posture, class, reach and effective level for authorization and scheduling |
| `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter.authorizeChromeControlEffect`; Fresh authority per effect. |
| `TrustCenter+Defaults.swift` | Canonical scalar defaults shared with typed and phone reads. |
| `TrustCenter+PolicyLoading.swift` | One checked generation; only proven fresh policy bootstraps. |
| `TrustCenter+PolicyModels.swift` | `TrustCenterDefaultWorkspaceRoots`, `TrustCenterError` |
| `TrustCenter.swift` | `getTrust`, `applyPolicyPatchChecked`; Locked exact-generation writes preserve damaged authority. |
| `TrustPolicy.swift` | Typed checked policy decoding and effect-time Mac control serialization |
| `TrustPolicyActions.swift` | `TrustPolicyActions`, `developerModePatchBody`, `saveMemoryPolicy`, `saveAgentAccessMode`, `saveMacControlPolicy` |
| `TrustPolicyToolWriter.swift` | `TrustPolicyToolWriter` enum; `applyTrustPolicyPatch` |
<!-- END GENERATED BLUEPRINT -->

### TrustPersistence

Directory: `Modules/NativeAgentCore/Sources/TrustPersistence/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TrustPersistence/ -->
| File | Owns |
|---|---|
| `ProductionExport+Archive.swift` | Owner-selected copy scopes, coherent SQLite and credential exclusions. |
| `TrustBackupCapture.swift` | Locked scope capture and read-only SQLite; canonical live persona. |
| `TrustBackupCatalog.swift` | Verified restore points, pins and staged dependencies govern retention. |
| `TrustBackupFoundation.swift` | `JSONDecoder`: extension |
| `TrustBackupModels.swift` | Staged and installed results remain distinct. |
| `TrustBackupOffDisk.swift` | Credential-filtered coherent copies; verify before retention. |
| `TrustBackupRestore.swift` | Validate before intent; preserve life and continuity before replacement. |
| `TrustBackupSnapshot.swift` | Complete sealed evidence, canonical persona and contained links. |
<!-- END GENERATED BLUEPRINT -->

### TurnTrace

Directory: `Modules/NativeAgentCore/Sources/TurnTrace/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TurnTrace/ -->
| File | Owns |
|---|---|
| `AbandonedTurnReconciler.swift` | `TurnCheckpoint`: Life-bound checkpoint recovery and guarded retirement |
| `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook`, `arm`, `disarm`: Bounded recovery; cancellation-aware trace flush |
| `SessionIdentity.swift` | Session identity ledger, mint-site traces and source-flapping diagnostics |
| `Turn+Trace.swift` | `Turn` parts TurnTrace owns: the reply row the surface already draws and a reader of the envelope's trace route |
| `TurnFirstRenderRegistry.swift` | Bounded single-claim first-render correlation and publication |
| `TurnInspectorFeed.swift` | Actor-owned checked evidence, grouping, selection-keyed faces and phone summaries through LatestRead |
| `TurnInspectorPresentation.swift` | Inspector grouping and bounded redacted row preparation from persisted evidence |
| `TurnSummaryRecord.swift` | `TurnSummaryComputer`, `TurnSummarySource`: Mac-owned Inspector privacy projection and byte budgets |
| `TurnTraceBus.swift` | Bounded live/disk queues; durable terminals and scoped flush |
| `TurnTraceContext.swift` | Trace-only correlation; reply-row identity is held on `Turn.replyRow` |
| `TurnTraceEvent.swift` | Canonical events; bounded envelopes retain receipt evidence |
| `TurnTraceGrouping.swift` | Stable grouping and exact metrics with coverage gaps |
| `TurnTracePersistLane.swift` | The one trace writer and reader over the record's detail grain (`ExperienceStore.note`/`details`); terminal and dispatch notices after the write |
| `TurnTraceRecentReader.swift` | Checked record windows, model-call evidence and measured coverage |
| `TurnTraceReplayReader.swift` | Record queries and positive terminal evidence |
| `TurnTraceThinkingReader.swift` | `TurnTraceThinkingReader`: Recorded model/turn counts in local day buckets |
| `TurnTraceW2.swift` | `TurnTraceRedactor`, `InspectorThinkingLane`: Redaction and opt-in display |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

Checked Mac integration permission storage and mail read locations.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `MacIntegrationConsent.swift` | Re-export MacControl consent without a dependency cycle |
| `MailReadLocator.swift` | `MailReadLocator` |
<!-- END GENERATED BLUEPRINT -->

### NotificationInbox

Directory: `Modules/NativeAgentCore/Sources/NotificationInbox/`

Notification records, checked live inbox storage and status reads. Depends on
Desk for the one OwnerAttentionPolicy; inbox prominence and overview counts
share it rather than implementing their own definitions of an obligation.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NotificationInbox/ -->
| File | Owns |
|---|---|
| `InboxItemRecord.swift` | Inbox wire meaning: presentation, reading status, owner attention and system lanes |
<!-- END GENERATED BLUEPRINT -->

### MultimodalTTS

Directory: `Modules/NativeAgentCore/Sources/MultimodalTTS/`

Speech synthesis contracts and provider implementation.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MultimodalTTS/ !Modules/NativeAgentCore/Sources/MultimodalTTS/MultimodalTTS+VoiceSelection.swift -->
| File | Owns |
|---|---|
| `MultimodalTTS.swift` | `MultimodalTTSError`, `SwiftOpenAITTSClient` |
<!-- END GENERATED BLUEPRINT -->

### ScreenVision

Directory: `Modules/NativeAgentCore/Sources/ScreenVision/`

Screen capture, screen-understanding operations and permission observation.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ScreenVision/ -->
| File | Owns |
|---|---|
| `ScreenVision.swift` | Screen vision owner; NativeScreenCapture encoding and capture error mapping |
<!-- END GENERATED BLUEPRINT -->

### ToolExecution

Directory: `Modules/NativeAgentCore/Sources/ToolExecution/`

Tool execution, sandbox primitive broker and promotion boundary.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ToolExecution/ -->
| File | Owns |
|---|---|
| `PartFileReads.swift` | `PartFileReads`: a part's readPaths admission, `files.query` over a private snapshot, `files.mime`'s budget |
| `PartHost.swift` | `Parts.rehearse`, `ToolHost`: gated host; previews suppress effects; a read verb's run only reads |
| `PartMIMERead.swift` | `PartMIMERead`: pure saved-message reader behind `files.mime` and the native attachment save |
| `Parts+BundledSeed.swift` | Parts bundled seed admission from the shipped current part contract |
| `Parts+CallValidation.swift` | static call-fit against current declarations |
| `Parts+Creation.swift` | checked save/rehearsal; ratcheted provenance |
| `Parts+Execution.swift` | pinned calls and pure faces; exact run admission |
| `Parts+HTTPWire.swift` | HTTP request and bounded response wire conversion for the existing resource broker |
| `Parts+Keeping.swift` | sealed keep decisions and owner-off authority |
| `Parts+Reading.swift` | shared checked inventory and latest-version reads |
| `Parts+TurnProgram.swift` | The agent's own turn program, revised by ability.save under trial and the save law, the version it replaces kept as turn.prev.js |
| `Parts.swift` | PartError and executable Parts access over the shared part reader; shared store access and JSON values |
| `SecretRedactor.swift` | Exact-secret insertion and whole/stream redaction formats shared by one admitted execution |
| `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`, `held`: declared reach; retained transport settlement |
<!-- END GENERATED BLUEPRINT -->

### Chrome Relay Core

Directory: `Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/ -->
| File | Owns |
|---|---|
| `ChromeHostIdentity.swift` | `ChromeHostIdentity`; Browser/relay identity, allowed origins and private refusal evidence. |
| `ChromeSocketIdentity.swift` | `ChromeSocketIdentity`; Kernel peer and signer proof with exact failures. |
| `NativeMessagingFraming.swift` | `NativeMessagingFramer`; Bounded little-endian JSON frames; exact fragmented reads. |
<!-- END GENERATED BLUEPRINT -->

### Task Ledger CLI

Directory: `Modules/NativeAgentCore/Sources/TaskLedgerCLI/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TaskLedgerCLI/ -->
| File | Owns |
|---|---|
| `main.swift` | `TaskLedgerCLI`: Strict ledger CLI and explicit data-root resolution |
<!-- END GENERATED BLUEPRINT -->

## Shared Source Map

### Package

Directory: `Modules/NativeAgentShared/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentShared/ Modules/NativeAgentShared/FaceApp/ -->
| File | Owns |
|---|---|
| `Package.swift` | Shared package manifest: Mac/iPhone library target, platform floors and shared source dependencies |
<!-- END GENERATED BLUEPRINT -->

### NativeAgentShared

Directory: `Modules/NativeAgentShared/Sources/NativeAgentShared/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentShared/Sources/NativeAgentShared/ Modules/NativeAgentShared/Sources/NativeAgentShared/FaceLink/ -->
| File | Owns |
|---|---|
| `ApprovalRequest.swift` | Mac-owned consent, execution evidence and exact chat provenance |
| `ApprovalsFace.swift` | Finished approval count, availability and public row words for the face feed |
| `BridgeMessage.swift` | `BridgeMessage`: signed device envelope, exact reply correlation and inner HMAC |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`, `typeAndMime`, `fileByteLimit`, `submittingSpeech` |
| `ChatComposerModelGroup.swift` | Finished provider/model menu groups and their vendor sections |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableParser`: pure prose segmentation and alignment/cell parsing of transcript tables |
| `ChatPacedReveal.swift` | `ChatStreamPacer`: paragraph reveal, fade and settle shared by Mac/phone |
| `ChatRichContentParser.swift` | `ChatRichContentParser`: checked grammar; `ChatContentCache`: bounded FIFO |
| `ChatSlashCommands.swift` | `ChatSlashCommandRegistry`, `ChatSlashCommandRouting`: one immutable command vocabulary and recognition |
| `CloudKitDeviceTransport+Messages.swift` | Signed sends and serialized two-family drains |
| `CloudKitDeviceTransport+PairingStatus.swift` | Account-slot claims, pairing, presence and serialized status delivery |
| `CloudKitDeviceTransport+Pull.swift` | Paginated record pulls with call-local traversal cursors up to the durable server-date watermark |
| `CloudKitDeviceTransport+Retention.swift` | Bounded oldest-page record retention; subsequent sweeps advance through confirmed deletions |
| `CloudKitDeviceTransport+Subscriptions.swift` | Visible alerts, silent chat/results and exact registration proof |
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport`: checked account, push and cursor ownership |
| `ColorHex.swift` | `NativeAgentSpacing`, `NativeAgentRadius`, `HazeColor`, `HazeMood`, `Color.init(hex:)`: shared values |
| `CompactDurationFormatter.swift` | `CompactDurationFormatter.string`: shared rounded compact duration wording with finite/range admission |
| `ConnectorSetup.swift` | Canonical connector identity, entry routes and Slack allowlist text parsing |
| `ContinuationOnce.swift` | `ContinuationOnce`: first outcome wins; typed Stop/deadline waits preserve writes |
| `ConversationModels.swift` | `ChatThreadKind`, transcript codecs, session row/list faces, attachments and Mac-owned navigation |
| `CountStatusValues.swift` | `CountStatusValues`: phone, transport, health, capture, download and notice facts drawn through the counts slot |
| `CountsFace.swift` | `CountsFace`, `CountReading`, `InboxCountsFace`: finished attention, availability and status values for the Mac face |
| `DeviceApprovalSignature.swift` | `DeviceApprovalSignature`: device identity and approval verification; outer HMAC required |
| `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |
| `DeviceEventIdentity.swift` | Stable cross-device notification/collapse identity and shared authenticated notification category construction |
| `DeviceSyncTransport.swift` | Shared role/message codecs, checked transport and signed phone contact |
| `Experience.swift` | Canonical experience and obligation lifecycle value contracts shared by domain owners |
| `FaceCollectionView.swift` | Session-held collection continuations, nested item reads and adaptive selection |
| `FaceDeliveryReceipt.swift` | Event-settled pipeline delivery with cancellation and owner-close settlement |
| `FaceDocumentView.swift` | Held document reads and the shared read-only TextKit view, selection, Find and Copy |
| `FaceDoor.swift` | Drawn acts, held document reads and navigation shared by native page doors |
| `FaceFeed.swift` | Finished values, replayable connection sinks and applied-frame barriers for local and remote faces |
| `FaceFormView.swift` | Shared public and protected field drawing, validation and retained form settlement |
| `FaceClient.swift` | `FaceClient`, `FaceActHandler`, `InProcessFaceClient`: the one way a window view acts on them, in-process or over the pipe |
| `FaceContracts.swift` | Typed body–face requests, effects and optional field settlement without changing installed-phone enums |
| `FaceEnvelope.swift` | Complete typed act/call vocabulary and correlated replies on the body–face pipe |
| `FaceLink.swift` | Ordered asynchronous binary property-list framing over parent/child pipe handles |
| `FaceLinkLog.swift` | Body and face link record of the recent past, turned over at 32 MiB; identities and redacted failures, no payloads |
| `FacePresentations.swift` | Finished renderer feed values; read state distinguishes waiting, known empty and unavailable |
| `FaceValueRegistry.swift` | Stable wire names for every Shared face value; unknown or ambiguous names fail decoding |
| `SecureCardFace.swift` | Protected card entry fields and controls projected by the interaction owner without secret values |
| `FacePageSession.swift` | Door-held edits, document demands and subject-owned operations above disposable rows |
| `FaceProtectedForm.swift` | Transient secret fields use named native receivers outside page edits and retained operations |
| `FaceReadPage.swift` | Revision-bound document chunks for the signed phone read door |
| `FaceRowView.swift` | Quiet native rows, drawn-call submission and row-local pending, failure and undo |
| `FaceSectionView.swift` | Shared face sections in native lists or door-supplied cards |
| `FaceStyle.swift` | Door-supplied card surface, row density, insets and type |
| `FaceView.swift` | Shared page renderer, adaptive sections and keyboard row navigation |
| `Happening.swift` | `Happening` and `Thought`: the one form of every change the agent's attention takes in, and what one thought attended |
| `HazeView.swift` | `HazeView`: shared radial haze rig, overlap cap, weight and tempo; native geometry, lifecycle and phone tab clock |
| `ICloudBridgeConstants.swift` | Bundle-owned iCloud identity and shared wire/storage namespaces |
| `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.Mode`, `normalized`: invalid modes stay refused |
| `InboxAction.swift` | Shared signed iPhone-to-Mac inbox envelope; Codable wire schema for both transports and platforms |
| `InboxDigestGroupProjection.swift` | `InboxDigestGroups`: read-only structured inbox groups; historical prose remains text |
| `InboxVisibleActionsPresentation.swift` | Canonical native Inbox action filtering for finished body and renderer presentations |
| `InboxWireModels.swift` | Inbox rows and `InboxActionVocabulary`: signed actions; `view` stays phone-local |
| `InspectorFace.swift` | Inspector membership, redacted cards and pure shared collection/document projection |
| `InspectorModels.swift` | Shared checked content-free Inspector turn summaries and mobile tool catalog rows |
| `JSONByteScanner.swift` | JSON byte spans; callers own validation and duplicate keys |
| `KnowledgeGraphEdgeWireSnapshot.swift` | `KnowledgeGraphEdgeWireSnapshot`: checked edge decoding; platforms own UI identity |
| `LatestRead.swift` | `LatestRead`: owner-isolated reads return their result; publication advances only |
| `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: policy projection; TrustCenter owns authority |
| `MacControlWorkbenchAction.swift` | Workbench action routes and category-policy availability shared by body and renderer |
| `MemoriesFaceTarget.swift` | `MemoriesFaceTarget`: the exact places a Memories row leads (graph, upkeep, a memory, a rejected proposal) |
| `MemoryModels.swift` | Memory/proposal values preserve absence and source timestamps |
| `MobileAppSettings.swift` | `MobileAppSetting`: owner-projected settings; unavailable rows retain read failures |
| `MobileConnectorSnapshot.swift` | MobileConnectorSnapshot: credential-free connector state and available phone controls |
| `MobileDeskSnapshot.swift` | `DeskKind`, `DeskStatus`, `WorkOverview`: bounded Desk copies; no decision authority |
| `MobileHelpers.swift` | Revisioned helper edits and reading copies; explicit Fast intent |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup`, `groups`: live phone snapshot input declarations |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | Closed `MobileTrustAction` requests; TrustCenter retains policy authority |
| `MobileVoicePreference.swift` | Read-only Mac voice preference carried by the core mobile snapshot |
| `MobileWorkActivity.swift` | Bounded mobile experience projection, activity DTOs and revisioned experience snapshot |
| `ModuleLogging.swift` | `ModuleLog`: shared public diagnostic formatting and credential scrubbing; `nativeLog` retains the Shared category |
| `NativeCollectionPages.swift` | Shared graph collection and item projections from canonical device or body readings |
| `NativePersonInput.swift` | Shared person-event provenance for body input and renderer hand-back controls |
| `NativeTimestampFormat.swift` | Locked wire timestamp formats and Foundation parsers; explicit precision, UTC suffixes and calendar-day zones |
| `OrganismLivingStatus.swift` | `OrganismLivingStatusFile`: read-only body status; unavailable stays explicit |
| `PanelFreshnessFace.swift` | Shared panel refresh receipts and selected panel reading state |
| `PartFace.swift` | Shared page values, documents, typed forms and installed-phone notes; feed keys and catalog |
| `PartFaceText.swift` | Page prose, committed form values, document openings and demand links for the agent door and Telegram |
| `PersonaDocument.swift` | Shared finished personality document used by the editor and agent pages |
| `PersonaModels.swift` | Shared persona values and name validation; PersonaEngine owns identity |
| `PhoneConnection.swift` | `NAPhoneConnection`: pairing/transport/exchange assessment; `NAPhoneStanding`: connected and can-approve |
| `PhoneMacControlAction.swift` | Phone Mac-control routes with native executors; Trust admission stays separate |
| `PhonePlaceEvent.swift` | `PhonePlaceEvent`: authenticated cross-device place observations |
| `PhoneRequest.swift` | `PhoneRequest` and `PhoneRequestResult`: typed signed request/result bodies over the existing device chat lane |
| `PhoneSenseEvent.swift` | Authenticated phone observations and setup evidence; confidence never proves absence |
| `ProviderAuthModePicker.swift` | Canonical advertised authentication choices and unresolved saved-mode presentation |
| `ProviderAuthStatus.swift` | `ProviderAuthStatus`: credential-proof display; providers own dispatch eligibility |
| `ProviderCatalogFaceValues.swift` | Shared provider catalog and credential-status display values |
| `ProviderCatalogStatus.swift` | `NAProviderCatalogStatusCodec`: credential-free metadata over device status |
| `ProviderCatalogWireModels.swift` | Shared provider/model values and group vocabulary; callers own reasoning policy |
| `ProviderRoutingFaceValues.swift` | Checked routing and preference values shared by execution and faces |
| `ProviderSettingsFaceValues.swift` | Finished provider settings, conversation controls and catalog values for the face feed |
| `RunDocument.swift` | One saved run's complete read-only document, shared by every door |
| `RunKindVocabulary.swift` | Safe display vocabulary for extensible run kinds; platforms own unknown symbols |
| `RunRecord.swift` | RunRecord: shared Codable run-history fields |
| `RuntimeHealth.swift` | RuntimeHealth: shared runtime liveness metadata; lifecycle facts remain with their owners |
| `ScopedWaiter.swift` | `ScopedWaiter`: one-shot parking; cancellation and deadlines release only their parker |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope`: shared seal/open wire contract for authenticated secret actions |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SettingsFace.swift` | Finished settings groups, preference scalars and permission-dock words at the settings feed key |
| `SimpleViewMode.swift` | Canonical view preference key and offered window modes |
| `SpeechUtterance.swift` | `SpeechUtterance`: original recognition evidence and compact uncertainty |
| `StoreReloadDebouncer.swift` | `StoreReloadDebouncer`, `Timer`: one reload in flight until actual exit |
| `SurfaceLayout.swift` | `SurfaceLayout` owns the document shape, vocabulary and seed; `SurfaceLayoutAvailability` carries its checked value or `SurfaceLayoutFailure` path/detail/repair across Mac and phone, and exposes shipped content names through their shipped profiles without supplying a substitute layout. `addMissing`, `shown`, `arranged` project validated layouts; `QuietToolPage` owns shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases and door resolution (`step`, `place`, home rooms), deriving accepted part face pages from those definitions and the ids a page of the agent's own may have (`ownPageRefusal`); `ownPage` reads a `page:<id>` block on the surfaces that take one (rail, more) |
| `SystemToast.swift` | `SystemToast`, `SystemToastCenter`: replace-by-ID notices and owned dismissal timers |
| `TaskWaitDeadline.swift` | `OperationWaitBudget`: explicit call ceiling; producer owns settlement after timeout |
| `ToolActivityPresentation.swift` | `ToolActivityPresentation`: bounded display copy; execution stays unchanged |
| `TranscriptAttributes.swift` | Codable transcript attributes preserved by the press and TextKit's native bridge |
| `TranscriptBuild.swift` | Content-keyed conversation blocks for the press and phone |
| `TranscriptDocument.swift` | The conversation as one document on Mac and iPhone: blocks, attachment references, the edit between two |
| `TranscriptLiveMarkdown.swift` | Incremental complete markdown blocks, one reparsed open tail and source-to-glyph reveal cuts |
| `TranscriptMarkdown.swift` | A message's markdown as document pieces (paragraphs, lists, headings, quotes, code, tables), stamped as blocks |
| `TranscriptPress.swift` | Actor-owned transcript blocks, rendered paragraphs and acknowledged per-reader edit scripts |
| `TranscriptRevealMapping.swift` | Parser-position glyph cuts shared by Mac and phone transcript renderers |
| `TranscriptRow.swift` | The row a conversation's face is built from, the same on the Mac and the iPhone, and its groups: tool runs, mirrored cards, replies, quiet gaps, and the reply that hosts a run's cards |
| `TranscriptRowFace.swift` | Mac-owned transcript presentation carried to the phone |
| `TrustPolicy.swift` | Shared checked policy presentation and its typed surface values |
| `TurnFace.swift` | `TurnFace`, `TurnSessionsFace`, `TurnElsewhereLine`: turn values and quiet cross-conversation movement drawing |
| `TurnSecretRedactor.swift` | `TurnSecretRedactor`: shared credential recognition; callers own size bounds |
| `UserDisplayFormatters.swift` | Shared timestamp/path display and `CompactDurationFormatter`; parsing is cached |
| `VoiceNoteBubble.swift` | Mac/phone voice-note face; original audio, playback and expandable transcript |
| `VolumeIO.swift` | Serial off-pool filesystem work; issued writes own physical completion |
| `WorkPaneFace.swift` | Shared Work pages: Steps, Screen, version-bound Make controls and owner-resolved preview leaves |
<!-- END GENERATED BLUEPRINT -->

## Parts

Directory: `Resources/abilities/`

Every bundled JavaScript part owns its row. Existing Swift owners retain
native effects, consent and settlement.

<!-- BEGIN GENERATED BLUEPRINT: Resources/abilities/ -->
| File | Owns |
|---|---|
| `backup-cadence.js` | ability `backup-cadence`: Choose off-disk backup freshness and identity-change cadence from native timestamps. |
| `desk-notify.js` | ability `desk-notify`: My Desk interruption policy: changed work, earned nudges, quiet-window drift and exact deadlines. |
| `desktop-courier.js` | ability `desktop-courier`: Prepare the desktop courier's reply address and constrained tool-turn procedure. |
| `due-reminders.js` | ability `due-reminders`: The day split behind reminders.due_today: one native reminders query cut at the local day's start into today and overdue parts. |
| `growth-week.js` | ability `growth-week`: My seven-day growth readout, from frozen native REM timeline evidence. |
| `mac-watch-catalog.js` | ability `mac-watch-catalog`: Return inactive Mail, Calendar and Reminders watch recipes and the words for each Mac access row. |
| `make-generated.js` | ability `make-generated`: Compose raw generated images with make.add, preserving their prompt, model and requested ref, and report each registration failure. |
| `make-title.js` | ability `make-title`: The title of a Make preview, from its decoded HTML title, prompt or filename. |
| `music-library.js` | ability `music-library`: Read Music playback state and observed timing; page typed playlists and sorted, filtered library/search results with totals, without opening Music. |
| `music.js` | ability `music`: Play, pause, stop or skip Music; bound play with seconds through the native player call, resolve an exact library track, and read playback through music-library. |
| `native-chrome-history.js` | ability `native-chrome-history`: Read Chrome's Default profile history from a private snapshot: recent pages, title/URL search, or the most visited domains since a time. |
| `native-cognition.js` | ability `native-cognition`: Draw my cognition reading, controls and evidence from the resident mind's packet. |
| `native-desk.js` | ability `native-desk`: Draw the Desk from its packet: the selection, the board grouped by what each item waits on, other work, lines, timers and source gaps. |
| `native-diagnostics.js` | ability `native-diagnostics`: My Diagnostics page from Doctor's measured verdicts, and my words for Desk and Activity checks, Doctor asks, storage and speech cards. |
| `native-document.js` | ability `native-document`: My passive document page from its owner's title and frozen reading, with selection, Find and Copy at every door. |
| `native-dreams.js` | ability `native-dreams`: My dream diary from the diary owner's bounded reading, with selection and the person's cycle levers. |
| `native-graph.js` | ability `native-graph`: My knowledge graph from the canonical graph owner's bounded reading, with each selected entity and a reviewed upkeep. |
| `native-home.js` | ability `native-home`: Draw Home from its packet: my mind (awake or asleep, my latest thoughts, what is owed to me), then my layout's sections. |
| `native-mail.js` | ability `native-mail`: Apple Mail through the door: list, search and read mail from Mail's local index and message files, rank senders, triage, mark read, archive, move to Trash, send, reply and save drafts through Mail's own Apple Events. |
| `native-memories.js` | ability `native-memories`: Draw the Memories page from the memory owner's packet: what I keep, what is waiting, what search found, what I let go, and every gap by name. |
| `native-memory-upkeep.js` | ability `native-memory-upkeep`: Draw memory upkeep, its checked diagnostics and each unavailable reading from the memory owner's packet. |
| `native-messages.js` | ability `native-messages`: Read Messages conversations and history from chat.db and send texts through Messages, with the recovery words for each failure reason. |
| `native-morning-brief.js` | ability `native-morning-brief`: Compose the morning brief and its inbox card from checked native source packets. |
| `native-notes.js` | ability `native-notes`: Apple Notes: find, read, create, update and delete notes through the app's own scripting, with named read gaps and recovery wording for every refusal. |
| `native-personality.js` | ability `native-personality`: Draw the Personality page from the persona owner's packet: who I am, my persona documents, how I am becoming, and my dreams. |
| `notice.js` | ability `notice`: Notice a scriptable app arriving; offer once per bundle and version. |
| `presentation-copy.js` | ability `presentation-copy`: My page subtitles, activity phrases and automated conversation titles, over sanitized native presentation facts. |
| `studio-canon.js` | ability `studio-canon`: Propose canon tending from neutral recurrence, production-pull and membership facts, with reasons and the next silence deadline. |
| `studio-intake.js` | ability `studio-intake`: Order unanswered artifact consults from complete corrected history, and phrase invitations to work already in reach. |
| `telegram-commands.js` | ability `telegram-commands`: My Telegram command menu, help, and memory-command reply words. |
| `telegram-model-picker.js` | ability `telegram-model-picker`: Interpret Telegram model requests and draw checked model menus. |
| `telegram-progress.js` | ability `telegram-progress`: My Telegram progress and status voice over sanitized native lifecycle facts. |
| `today-readout.js` | ability `today-readout`: Draw Today as a timed timeline, upcoming intentions, earlier notes and named source gaps. |
| `turn.js` | turn `turn`: The stem hands step one event at a time (message, model, result, observation, provider_failure, resumed) and runs the effects it returns (model.call, app, reply.stream, reply.end, after, notebook). |
| `weather.js` | ability `weather`: Read current weather and daily temperature high/low, rain chance, wind, sunrise and sunset from Open-Meteo. |
| `workspace-readout.js` | ability `workspace-readout`: Compose Today, Music and helper workspace faces from native read facts, selecting only bound item and action keys. |
<!-- END GENERATED BLUEPRINT -->

## iOS Companion Map

### Companion

Directory: `iOS/NativeAgentMobile/Sources/`

`MobileTranscriptPress` owns the phone's instance of the Shared `TranscriptPress`
and its frame-driven face feed. A controller's cancellable input drain merges
synced records and local rows and groups them off main. Shared owns blocks,
incremental Markdown and rendered UIKit attributed paragraphs; width and Dynamic
Type are reader parameters. `TranscriptDoor` carries the phone's history and
message actions, owed decisions and live waiting words. Synced rows use their
carried Mac headline/detail words. Each mounted controller selects its own
reader packet, validates its acknowledged base and applies one TextKit transaction.
The Shared parser-position cuts drive reveal and Markdown copy on both platforms.
Application and first draw release older history, and reader removal follows the
cancelled input drain. The phone's former main-actor builder, renderer and per-frame
Markdown composition are removed. Attachment fitting and host retention keep their
separate contract. No saved or CloudKit format changes.

<!-- BEGIN GENERATED BLUEPRINT: iOS/NativeAgentMobile/Sources/ -->
| File | Owns |
|---|---|
| `AdvancedPresentation.swift` | Shared mobile presentation and design samples |
| `AdvancedView.swift` | Shared More rows over the Mac layout, local destinations and native pairing |
| `AliveCards.swift` | Native card surfaces, sections, pairing-row insets and footnotes |
| `AliveConnection.swift` | Shared Mac connection wording, pairing guidance and snapshot freshness |
| `AliveControls.swift` | Status lights, search, glass controls and haze swatches |
| `AlivePage.swift` | Native list page, headers, list environment and scroll-edge fades |
| `AlivePalette.swift` | Phone haze colours, contrast tokens and page metrics |
| `AliveRoom.swift` | Phone room and chat-driven mood presenting the shared `HazeView` |
| `AliveWords.swift` | Count, identifier and timestamp wording for phone screens |
| `ApprovalsStore.swift` | Synced approvals and their snapshot's health; an approval is decided on its card, its matter's Inbox row; the Mac's routed alert is the phone's only approval alert |
| `ChatModels.swift` | Chat values, runtime controls and Mac transcript projection onto ChatMessage |
| `ChatPresentation.swift` | Chat controls and picker presentation; model controls read the shared `iCloudSyncEngine.surfaceModels` projection |
| `ChatStore+ICloudReplies.swift` | Signed delivery evidence before early exits; shared terminal/snapshot settlement preserves partial words |
| `ChatStore+PendingExchanges.swift` | Durable reply observation; unknown delivery retains its exact request and late replies |
| `ChatStore+ReplyObservation.swift` | Shared signed reply, rejection and pairing-resync receiver |
| `ChatView+Choices.swift` | Shared Chat option forms over the Mac-owned model tuple and local file-access choice |
| `ChatView+Composer.swift` | Session-bound drafts, dictation, talk entry and attachment preparation on ChatView |
| `ChatView+ConversationEvents.swift` | Store-owned reply receiver; foreground refresh and session-bound dictation callbacks |
| `ChatView+Notices.swift` | One condition-bound banner lane for chat, sync and voice notices |
| `ChatView+Thread.swift` | Conversation document, Inbox cards and actions, composer, Latest and shared options sheet |
| `ChatView.swift` | Conversation state, session navigation and anchor reconciliation; composes thread, composer, choices and notices |
| `ComposerVoiceMicrophone.swift` | Mic gestures and accessible dictation, voice-note recording, cancel and lock |
| `DeskStatus.swift` | Desk and task status words |
| `DiagnosticsView.swift` | Mac diagnostics face and phone push, verification, refusal and connection evidence |
| `DictationComposer.swift` | Capped full-width dictation and live waveform; redraw independently of chat |
| `InboxModels.swift` | Phone inbox reading; the Mac supplies status/source meaning, and every card is the Inbox face's row |
| `InboxStore.swift` | Inbox refresh and notification permission; the Mac's routed alert is the phone's only inbox alert |
| `KnowledgeGraphView.swift` | Device-local graph pages, held queries and revision-bound collection/item reads |
| `MacActionReceipts.swift` | Mac Tools receipt identities, original retry values and approval reconciliation |
| `MacBridgeClient.swift` | Signed iCloud chat transport, pairing and connection observation |
| `MacToolsPresentation.swift` | Mac policy remedies, requested volume and off-main Spotlight result decoding |
| `MacToolsView.swift` | Shared forms and receipt rows over policy-gated signed Mac controls |
| `MobileAgentThreadView.swift` | Shared contact conversation rows and retained message form over the signed Mac owner |
| `MobileAppIntents.swift` | Named-agent Siri/Shortcuts actions, including authenticated foreground talk entry and ordinary Ask replies |
| `MobileFacePage.swift` | Phone page rows, signed document demands and retained action outcomes |
| `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |
| `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
| `MobileSearchIndex.swift` | Actor-owned local row search shared by memory, tools and knowledge graph |
| `MobileSpeechAnalyzer.swift` | On-device timed recognition, name context and PCM conversion; detector events retain capture |
| `MobileTalkAudio.swift` | Full-duplex voice capture, timed on-device recognition and quiet acknowledgment |
| `MobileTranscriptAttachments.swift` | Phone document attachments: one hosted view per block id, fed from the model, sized to fit |
| `MobileTranscriptBuilder.swift` | Off-main phone rows and door inputs; Shared press and display feed |
| `MobileTranscriptController.swift` | Applies Shared press scripts; phone viewport, reader place and prepared-glyph reveal |
| `MobileTranscriptFragments.swift` | One layout fragment per drawn paragraph kind, and the delegate that picks them and hides closed folds |
| `MobileTranscriptStyle.swift` | Phone paragraph preparation on the Shared press, UIKit tokens and action links |
| `MobileTranscriptView.swift` | The phone's conversation as one selectable document: the text view, its host handle and actions |
| `NativeAgentDesign.swift` | `NativeAgentAppearance` (the phone's color-scheme control), `AppFont` and `AppMotion` tokens |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PairingStore.swift` | Sole phone identity/Keychain transaction owner; checked pairing evidence governs sense/delivery retention |
| `PhoneBodyReadings.swift` | Wake-only body readings; network and photo callbacks own pending queries |
| `PhoneLocalSettings.swift` | Owner-declared local controls; signed requests read current owners and use consent sheets for raises |
| `PhonePlaces.swift` | Opt-in places and pairing-bound outbox; per-observation admission errors and receipt-driven delivery |
| `PhoneSenses.swift` | Opt-in sense outbox; callback-owned wake readings and pairing-bound durable delivery |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities`; shared projected activity |
| `RunDetailView.swift` | Saved run detail uses the signed document door and shared TextKit renderer |
| `SettingsViewFull.swift` | Device settings, appearance and release version; shared refresh/availability; push diagnostics in Status |
| `TalkModeController.swift` | Session-bound hands-free talk; detector endpoints, final recognition, speech and explicit End |
| `TalkModeView.swift` | Haze call face, latest words and mute/end; accessible motion/transparency and speaking presence |
| `TurnInspectorView.swift` | Device-local summary faces, bounded continuations and demanded count evidence |
| `VoiceInputController.swift` | Session-bound capture; recognition completion or cancellation settles the draft |
| `iCloudBridge+CloudKit.swift` | Pairing-bound reads while the phone is open, presence beat and lifecycle-fenced recovery |
| `iCloudBridge.swift` | Authenticated admission, consumer dispatch and durable receive settlement; unresolved delivery stays open |
| `iCloudSyncEngine+Actions.swift` | Signed submissions, verified response settlement and event-held action waits |
| `iCloudSyncEngine+Commands.swift` | Signed subject commands, drawn-call page outcomes and read-only reconciliation |
| `iCloudSyncEngine+FaceReads.swift` | Signed document and structured page demands, revision-checked cursors and owner release |
| `iCloudSyncEngine+SnapshotReading.swift` | Local CloudKit cache reads, strict document decoding and per-file read health |
| `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot`, `refreshHelpersSnapshot`, `applyProviderState` |
| `iCloudSyncEngine+Transactions.swift` | Signed envelope retention, pairing reconciliation, mailbox recovery and completion-held persistence |
| `iCloudSyncEngine+Transcripts.swift` | Version-ordered transcript/history reconciliation; retained fuller text and attachment bytes |
<!-- END GENERATED BLUEPRINT -->

### Diagnostics

Directory: `iOS/NativeAgentMobile/Sources/Diagnostics/`

<!-- BEGIN GENERATED BLUEPRINT: iOS/NativeAgentMobile/Sources/Diagnostics/ -->
| File | Owns |
|---|---|
<!-- END GENERATED BLUEPRINT -->

## Executable Architecture Policy

`script/generate_architecture_blueprint.swift --check` reads the following JSON block.
Change ownership rules here in the same commit as the source change. It checks complete
headers, exact file/row placement and generated equality, then validates policy
markers/imports from the same source text without compiler type-checking. `blueprintRoots`
owns source-header discovery, including package manifests and bundled parts;
`.build` directories and test trees are excluded. `sourceRoots` retains
the production scope consumed by `script/check_timer_inventory.swift`. Paths are repository-relative.
`files` are required, `optionalFiles` are checked when present, and `roots` select
Swift sources recursively. Literal contracts are case-sensitive; pattern rules may
declare case-insensitivity. Import rules inspect import declarations.

Every app source must import SwiftUI or AppKit. The temporary per-file allowlist
below records the area responsible for extracting existing nonplatform work. An
exception is an outstanding ownership item, not a permanent exemption; remove it
when its file moves or is colocated with its genuine UI/platform owner. Missing files
and exceptions that already satisfy the rule fail so the list tightens with each wave.
Area numbers absent from the supplied map remain explicitly unmapped.

```json architecture-policy
{
  "sourceRoots": ["Sources", "Modules/NativeAgentCore/Sources", "Modules/NativeAgentShared/Sources", "iOS/NativeAgentMobile/Sources"],
  "blueprintRoots": ["Modules", "Sources", "Resources/abilities", "iOS/NativeAgentMobile/Sources"],
  "forbiddenFiles": [
    "Modules/NativeAgentCore/Sources/PersistenceCore/OperationalTransitionShadowModel.swift",
    "Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox+TransitionShadowAuthorization.swift",
    "Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox+AdaptiveReasoningEffort.swift",
    "Modules/NativeAgentCore/Sources/ChatOrchestration/ChatOrchestrationClient+AdaptiveReasoningEffort.swift",
    "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+AdaptiveReasoningEffort.swift",
    "Modules/NativeAgentCore/Sources/PersistenceCore/AdaptiveReasoningEffortStore.swift"
  ],
  "rules": [
    {"id": "retired-identity", "files": ["README.md", "AGENTS.md", "SECURITY.md", "PROJECT_STATUS.md", "docs/ARCHITECTURE_BLUEPRINT.md", "docs/PROJECT_DIRECTION.md", "docs/data-bounds.md", "docs/mobile_companion.md", "docs/approval-schema.md", "docs/threat-model.md", "docs/apns-push.md"], "optionalFiles": ["docs/HANDOFF_CURRENT.md"], "forbiddenPatterns": ["\\bJen(?:na)\\b"], "caseInsensitive": true},
    {"id": "retired-daemon-http", "files": ["AGENTS.md"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765|/v1/consolidation/audit"], "caseInsensitive": true, "message": "agent instructions must not call retired daemon HTTP endpoints"},
    {"id": "retired-smoke-runtime", "files": ["script/smoke_all.sh"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765|native_agentd\\.py|daemon HTTP"], "caseInsensitive": true, "message": "the active smoke workflow must not direct operators to the retired daemon runtime"},
    {"id": "retired-codex-environment", "files": [".codex/environments/environment.toml"], "forbiddenPatterns": ["\\bdaemon\\b"], "caseInsensitive": true, "message": "Codex environment actions must describe the Swift-native app"},
    {"id": "retired-security-model", "files": ["SECURITY.md"], "forbiddenPatterns": ["daemon port|LAN with pairing token|LAN[^`]*daemon"], "caseInsensitive": true, "message": "security policy must describe the current Swift/iCloud trust model"},
    {"id": "retired-prune-owner", "files": ["docs/data-bounds.md"], "forbiddenPatterns": ["native_agentd\\.py|_prune_unbounded_state\\(\\)|Same prune pass"], "caseInsensitive": true, "message": "data bounds must attribute live retention to Swift app-owned paths"},
    {"id": "retired-mobile-transport", "files": ["docs/mobile_companion.md"], "forbiddenPatterns": ["daemon forwarding|from daemon|daemon HTTP|/v1/missions` from daemon"], "caseInsensitive": true, "message": "mobile companion docs must stay iCloud/Swift-runtime oriented"},
    {"id": "retired-approval-runtime", "files": ["docs/approval-schema.md"], "forbiddenPatterns": ["Mac daemon|running daemon|native_agentd\\.py|_internal_approval_token|daemon's live process|local loopback HTTP path"], "caseInsensitive": true, "message": "approval docs must describe durable Swift-owned approval execution"},
    {"id": "retired-ios-project-comment", "files": ["iOS/NativeAgentMobile/project.yml"], "forbiddenPatterns": ["LAN daemon|Tailscale.*server URL"], "caseInsensitive": true, "message": "iOS project comments must not describe retired LAN daemon setup"},
    {"id": "retired-ios-action-routing", "files": ["iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift", "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift", "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Transactions.swift", "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Setup.swift", "iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Snapshots.swift"], "forbiddenPatterns": ["dispatches to daemon|daemon endpoint"], "caseInsensitive": true, "message": "iOS comments must route to MacSyncEngine and Swift runtime"},
    {"id": "retired-ios-pairing-comment", "files": ["iOS/NativeAgentMobile/Sources/PairingStore.swift"], "forbiddenPatterns": ["<lan-ip>:8765|LAN daemon"], "caseInsensitive": true, "message": "iOS pairing comments must not document retired LAN pairing as current setup"},
    {"id": "retired-ios-kg-comment", "files": ["iOS/NativeAgentMobile/Sources/KnowledgeGraphView.swift"], "forbiddenPatterns": ["Mac daemon|old daemon /v1"], "caseInsensitive": true, "message": "iOS knowledge graph comments must describe iCloud snapshots and retired envelopes accurately"},
    {"id": "retired-ios-onboarding-comment", "files": ["iOS/NativeAgentMobile/Sources/NativeAgentMobileApp.swift"], "forbiddenPatterns": ["/v1/onboarding/start|now-dead daemon|post-wave-20 daemon"], "caseInsensitive": true, "message": "iOS onboarding comments must not point to retired onboarding HTTP routes"},
    {"id": "retired-ios-http-runtime", "files": ["iOS/NativeAgentMobile/Sources/MacBridgeClient.swift"], "forbiddenPatterns": ["daemon HTTP server|Mac daemon returned HTTP"], "caseInsensitive": true, "message": "iOS bridge facade must not describe a live daemon HTTP runtime"},
    {"id": "retired-skill-manifest-runtime", "files": ["docs/skill_manifest_spec.md"], "forbiddenPatterns": ["(?i)\\bdaemon\\b|native_agentd\\.py|daemon's venv Python|Daemon-Side"], "caseInsensitive": true, "message": "skill manifest spec must describe the Swift runtime rather than daemon-owned skills"},
    {"id": "retired-release-migration-instructions", "files": ["docs/release-migration.md"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765|native_agentd\\.py|Verify daemon started|Bundled Python hash verification"], "caseInsensitive": true, "message": "release migration docs must not prescribe retired daemon/Python runtime checks"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/slack.json", "docs/example_manifests/gmail.json", "docs/example_manifests/google_calendar.json", "docs/example_manifests/notion.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "retired-core-machinery", "roots": ["Modules/NativeAgentCore/Sources"], "forbidden": ["OperationalTransitionShadow", "personal_trace_shadow", "WorkshopTerminalOutcomeInterpreter"]},
    {"id": "retired-adaptive-effort", "files": ["Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestration+ToolLoop.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Factories.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift", "Modules/NativeAgentCore/Sources/AppToolRuntime/AppChatToolDispatcher.swift", "Sources/NativeAgentApp/AppModel.swift", "Modules/NativeAgentCore/Sources/EngineRuntime/EngineTurns.swift", "Sources/NativeAgentApp/ChatView+SlashCommands.swift", "Sources/NativeAgentApp/AppApprovalTransactionEffects.swift", "Modules/NativeAgentCore/Sources/ApprovalTransactions/ApprovalTransactionCoordinator.swift"], "forbiddenPatterns": ["adaptiveReasoningEffort"], "caseInsensitive": true},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift"], "required": ["checkedRouteAdmission"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/TurnContextPreparation.swift"], "required": ["provider.admissionReused"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/CognitiveSubstrate/CognitiveSubstrate+Maintenance.swift"], "required": ["persistMaintenanceTransition"], "forbidden": ["try await persistSnapshot(", "try await persistThoughtSeedFamily(", "try await recordReceiptChecked("]},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/TurnTrace/TurnTraceBus.swift"], "required": ["_FIFO<TrackedEvent>", "persistLane", "capacity: 4096", "func flush(turnId:"], "forbidden": []},
    {"id": "core-does-not-import-app", "roots": ["Modules/NativeAgentCore/Sources"], "forbiddenImports": ["NativeAgentApp"]}
  ]
}
```
