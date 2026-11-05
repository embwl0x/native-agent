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
| `Sources/NativeAgentSenseHost/` | Shared isolated JavaScriptCore executor for senses, tools, skills and ad hoc scripts; app supplies source/material and owns supervision |
| `Modules/NativeAgentCore/Sources/` | Engine, turn execution, domain stores, tools and policy |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | `isValidIOSDeviceRouteKey` |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift` | Nonblocking pipe reads bounded by process deadlines |
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
is owed. Only a matter that went wrong breaks their quiet hours. Their doors are the phone, the originating thread when
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
cancellation flag and error mapping live there;
authored scripts may declare `read_only:true`: Trust classifies the call as a read,
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
execution backoff remain with the scheduler.

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

Mac chat builds through Shared's `TranscriptBuilder` from the transcript's
groups, Core's `TranscriptRowFace.read`, and the presentation owner's words.
Each `TranscriptDocumentController` owns its `TranscriptBuildCache`; the Mac
adds its trailing trouble block and paced live reply, preserving text location.
The separate Mac document builder and persona-receipt view are removed.

Hardened-runtime Mac builds require
`com.apple.security.personal-information.calendars=true`; without it, TCC
rejects Calendar permission prompts. All four Mac entitlement templates retain
this grant, and `script/verify_release_artifact.sh` checks the signed entitlement.

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentApp/ -->
| File | Owns |
|---|---|
| `ActivityWatchController.swift` | `ActivityWatchController`: Capture watch binding and privacy-safe issue notifications |
| `AdvancedPageComponents.swift` | Shared Advanced page sections and read status |
| `AgentContactsSection.swift` | `AgentContactsSection`: Contact actions; offscreen reads do not discover |
| `AgentPresence.swift` | Agent presence card and Core Animation breathing orb reflect shared turn state and motion preferences |
| `AgentScreenView.swift` | Agent Home draws the shared face; other rooms retain read-only text, and explicit Home row acts reach engine.pages |
| `AlivePageKit.swift` | Alive page components: shared glass metrics/palette, headers, cards, pills, progress and flow layout for Today/Desk |
| `AnthropicSetupTokenInput.swift` | `AnthropicSetupTokenInput`: Setup-token submission and provider status |
| `AppApprovalTransactionEffects.swift` | Approval factory and live effect bindings; canonical browser outcomes |
| `AppConnectorPlatform.swift` | Voice, notification, Mac control, EventKit and device-sync platform bindings |
| `AppDelegate+BackgroundTasks.swift` | Background handlers; browser health uses the discovery-admitted listener |
| `AppDelegate+Launch.swift` | `AppDelegate`: Launch, turn-safe quit, ingress retirement and shared sleep settlement |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: Single-instance checks, launch alerts and login registration |
| `AppModel+ChatActions.swift` | Chat mutations, regeneration and turn admission through `MacChatTurnCommands`. |
| `AppModel+ChatSessions.swift` | `AppModel`, `composerDraft(for:)`: Shared drafts and checked session transactions |
| `AppModel+ChatState.swift` | `AppModel`: Checked profile and transcript reads, pinning and pruning |
| `AppModel+GraphCapabilityActions.swift` | Research search and shared browser/export adapters retained for other pages and the tool door |
| `AppModel+HealthEmbeddings.swift` | `AppModel`, `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`, `LatestRead`: Health publication |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` mounts checkpoint presentation through the core session delivery owner and lifecycle without forwarding a turn sink; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory` |
| `AppModel+Onboarding.swift` | `AppModel`: first-run greeting port and onboarding commands |
| `AppModel+PanelRefresh.swift` | `AppModel`, `LatestRead`: Ordered panel reads and shared activity badges |
| `AppModel+PersonalitySelfImprovement.swift` | `engine.persona`: Profile/document writes through the persona owner; support and proposals |
| `AppModel+ProviderCommands.swift` | `AppModel`: checked provider reads, chat-brain saves and disconnect outcomes |
| `AppModel+Refresh.swift` | `AppModel`, `setIfChanged`, `refreshAll`, `refreshTelegramSettingsDraft`: Shared refresh and Telegram draft reads |
| `AppModel+SchedulerActions.swift` | `AppModel`: scheduler and Desk creation commands; nightly reflection outcome wording |
| `AppModel+SkillsIntegrations.swift` | `AppModel`, `refreshTelegramSettingsDraft`, `LatestRead.refreshDraft`, `engine.connectors.update`: UI |
| `AppModel+TrustActions.swift` | `AppModel`: Trust policy, backups, approval resolution and Mac control commands |
| `AppModel.swift` | `AppModel`: Composition, shared drafts and owner-derived UI state |
| `AppQuietLowerOnly.swift` | `AppQuietSettingsHost`, `AppQuietToolHost`: Connector commands; Full Mac ownership |
| `AppQuietSettingsHost.swift` | Owner-declared settings; phone rows use signed requests, with no Mac copies |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: Separate real and inert dream calls; part management |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppSettingsFace.swift` | Settings face platform rows and actions use the updater, data reference, clipboard and live app status |
| `AppShellMenuPresentation.swift` | `NavigateMenuPresentation`, `MenuBarStatusPresentation`: Rail-derived shortcuts and one status line |
| `AppToolPlatform.swift` | Browser, notification and away bindings; shared speech client |
| `AppTrustFaceActions.swift` | Trust's native permission controls, Chrome setup, app chooser, workbench and restore adapter |
| `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |
| `AuthoredToolsSection.swift` | Authored tool lifecycle labels, controls and confirmation through AppModel commands |
| `BrowserWindow.swift` | MainActor WebKit waits; deadlines retire exact views, preserving unknown outcomes |
| `ChatClipboardAndAttachmentSupport.swift` | `ChatAttachmentTypeResolver`, `ChatClipboard`: Shared intake; fenced dictation |
| `ChatCodeBlockView.swift` | `ChatCodeBlockView`: selectable fenced code, language label and idempotent copy; no renderer state or clock |
| `ChatComposerChrome.swift` | `ComposerKeys`: editor-scoped Tab, slash, Shift-Return and attachment paste interception; shared composer chrome |
| `ChatComposerDraft.swift` | `ChatComposerDraft`: Session-owned draft shared by composers |
| `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |
| `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |
| `ChatContextFillBar.swift` | `ContextFillPresentation`: Shared context usage; missing measurements remain unavailable |
| `ChatFocusedCommands.swift` | `ChatFocusedCommands`: Visible-window commands |
| `ChatInboxStrip.swift` | `InboxStripContainer`: Inbox projection; reads do not resolve |
| `ChatInlineApprovalCard.swift` | Approval card with record-owned scope and facade decisions |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableView`: a parsed transcript table (`ChatMarkdownTable`, NativeAgentShared) as a Grid |
| `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops with mounted-page visibility; Telegram allowlist presentation |
| `ChatPreparedContent.swift` | Settled rich text, list/table preparation and bounded Markdown/content caches retaining shared parse outcomes |
| `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |
| `ChatShellViews.swift` | `ShellRoomHeader`, `ShellConversationRow`: Shared header and owner-read subtitles |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatToolCatalogSection.swift` | Catalog classification, search, approval controls and shared status tones |
| `ChatToolPillView.swift` | `ToolPillPresentation` (a tool row's title, target, outcome and duration) and `ToolDiffPresentation` |
| `ChatTurnFailure.swift` | `FailedTurnRetryConfirmation`: Shared retry confirmation and session-local continuation |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+Conversation.swift` | `ChatView`: Transcript, composer, search and cross-surface observation |
| `ChatView+DetachedSessionMenu.swift` | `ChatView`: `detachedSessionMenu` |
| `ChatView+PinnedSessions.swift` | `ChatView`: human pin reads and pruning; additive pinning delegates to `TranscriptsFacade` |
| `ChatView+SessionActions.swift` | `ChatView`: toast publication, committed session rename and voice/export actions |
| `ChatView+ShellColumn.swift` | `ChatView`: Conversation sidebar, archive, opening lines and stable row identities |
| `ChatView+SlashCommands.swift` | `ChatView`: Shared slash dispatch, setup navigation and attachment preservation |
| `ChatView.swift` | `ChatView`: conversation state and mounted lifecycle; `ChatTurnNoticePresentation`; stale-panel notice leaves |
| `ChatViewStateCoordinators.swift` | Transcript group preparation, card clearance, one-shot clear and occurrence-preserving toasts |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` alias to `ChromeControl.ChromeExtensionFolder`; app-bound `setUp`, `setupMessage` |
| `ClaudeConnectionPanels.swift` | Direct Anthropic OAuth sign-in and setup-token connection panel |
| `CognitionObservatoryView+Affect.swift` | Affect axes distinguish unavailable evidence from zero |
| `CognitionObservatoryView+Capsule.swift` | Read-only capsule, reflection and felt-mode presentation |
| `CognitionObservatoryView+LoopHarness.swift` | Same-snapshot association graph and explicit receipt availability |
| `CognitionObservatoryView+Metrics.swift` | `CognitionTensionsPresentation`: Same-snapshot capacities and counters |
| `CognitionObservatoryView+Organism.swift` | Kernel rows distinguish off, empty, stale and malformed |
| `CognitionObservatoryView+Proposals.swift` | Read-only growth timeline and current cognition receipts |
| `CognitionObservatoryView+Shared.swift` | Count badges preserve zero and withhold unavailable evidence |
| `CognitionObservatoryView.swift` | `CognitionObservatoryView`: Live panels, overrides and persistence feedback |
| `CognitionProposalsView.swift` | `CognitionProposalsView`: Canonical REM lineage and proposal-owned displaced content |
| `CommandPalette.swift` | Mounted command search, navigation and window-scoped key interception; actions remain with canonical owners |
| `CommandPaletteInventory.swift` | Saved palette destinations, shared inventory and deterministic ranking |
| `ComposerContextReceipt.swift` | Shared receipt views; LatestRead publishes current session evidence |
| `ComposerShellState.swift` | Mounted native menu tracking, context receipt and Trust confirmation state; quiet reads use the open menu |
| `ConnectorStatusViews.swift` | Status pill and note still shared by the iPhone pairing and agent-contact instruments |
| `ConnectorWizardView.swift` | `ConnectorWizardView`: cancellable setup; `settle` reconciles saved Slack state despite cancellation |
| `ContactPortraits.swift` | Contact app icons, initial tints, Clawd drawing and helper/crew clock tiles |
| `ContentView.swift` | `ContentView`: shell, scene navigation, first-run and iCloud refresh routing |
| `ContextFlowObservatoryPanel.swift` | `ContextFlowObservatoryPanel`: distinct off, unreadable and failed health |
| `DeskDebugPanels.swift` | `DeskDebugPanels`: diagnostic disclosures over the engine's retained Desk revision |
| `DeskFaceEditors.swift` | Mounted Mac adapters for Desk face editor requests; note drafts use the existing Desk tool router |
| `DetachedChatPanel.swift` | `DetachedChatWindowController`: session windows, pins, frames, focus and teardown |
| `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session transcript/composer through shared owners |
| `DisclosureRowToggle.swift` | `DisclosureRowToggle`: whole-label disclosure hit target sharing the DisclosureGroup's existing binding |
| `DreamsView.swift` | `DreamsView`: checked diary reads, exact dates and Dream/REM controls |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `FacePageView.swift` | `FacePageView`: any faced page drawn with FaceView over engine.pages, its links followed through Mac navigation and its row actions answered by the page's owner |
| `GrokSecureSetupCard.swift` | `GrokSecureSetupCard`: secure credential submission without secret exposure |
| `InboxCardActions.swift` | `AppInboxCardActionEffects`: native navigation for core inbox transactions |
| `InboxItemDetailSheet.swift` | Chat-capsule note detail, shared source presentation and single-flight outcomes; Activity uses the Inbox face |
| `InboxNotesCapsule.swift` | Chat-header unread notes capsule, note selection and failed-read retries |
| `InboxSettingsView.swift` | Notification preferences, trigger labels and shared history navigation over InboxFacade's ForPerson reading |
| `InlineCard.swift` | Inline card visual grammar: surfaces, controls, symbols and receipts; no store or work lifecycle ownership |
| `InlineCardView.swift` | InlineCardView renders every interaction state, field and choice; actions remain closures owned by the interaction |
| `InlineInteractionChatBinding.swift` | `InlineInteractionChatBinding`: card controls and verify-on-return settlement |
| `InlinePreviewCards.swift` | Inline approval resolve, durable-decision toasts and resolution messages retained by chat and Trust |
| `InspectorView.swift` | `InspectorView`, `TurnInspectorStore`: window-owned replay/live trace provenance |
| `InteractionCardDelivery.swift` | Shared card transactions and navigation; open card pointers read ForPerson's in-memory inbox |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphMaintenance.swift` | Orphan preview and deletion require the exact reviewed candidate set |
| `KnowledgeGraphPolicy.swift` | Checked Memory Policy reads/writes and enable/disable presentation |
| `KnowledgeGraphPresentation.swift` | Shared graph filters, date cache, selection and checked content/error states |
| `KnowledgeGraphRows.swift` | Entity rows and detail render `MemoryFacade.graphSnapshot`, without separate neighborhood reads |
| `KnowledgeGraphStatusHeader.swift` | `KGNativeStackHeader`: renders the engine memory diagnostics and graph counts |
| `KnowledgeGraphView.swift` | KnowledgeGraphView: shared graph snapshot, policy, maintenance and filters |
| `MacChatOtherSessionsBanner.swift` | `MacChatOtherSessionsBanner`: navigation and stop controls directly over the other running sessions |
| `MacChatRunningSessionMenu.swift` | `MacChatRunningSessionMenu`: shared go-to menu for sessions with background turns |
| `MacChatTurnCard.swift` | `MacChatTurnCard`: main/detached display over canonical turn lifecycle |
| `MacControlWorkbenchView.swift` | Concrete Mac control workbench, retained drafts, action commands and result feedback |
| `MacIntegrationView.swift` | Foreground macOS permission controls opened from Trust's face |
| `MacPairingView.swift` | `MacPairingView`: checked iCloud pairing; explicit rotation; quiet reads generate no keys |
| `MacWorkOverviewDetail.swift` | Work detail reads canonical work owners; inbox and approval destinations draw the shared Inbox face |
| `MemoriesFaceNavigation.swift` | Memory face links to native graph, full text/correction and upkeep |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform`; pending proposals use the engine's review-eligible reader |
| `MemoryView.swift` | Memory page upkeep/status components: canonical Spotlight actions, full text and explicit storage/embedder availability |
| `MenuBarController.swift` | `GlobalHotkey`: Carbon summon registration and tap/hold push-to-talk state with cancellable voice lifecycle |
| `MessageAttachments.swift` | Transcript-owned local image previews, voice-note partition and attachment chips |
| `MessageBubbleActions.swift` | Bubble hover controls, canonical message JSON sheet and advanced text editor |
| `MoodTint.swift` | Canonical mood sampling, capped damping and accessibility-aware glass |
| `NativeAgentApp.swift` | Engine launch and app hosts; one delivery watch with launch, network and configured-door wakes |
| `NativeAgentAppCoordinator.swift` | `ApplicationLifetime`: bootstrap and scene navigation; delivery proves acceptance only |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`; centered shell layout and shared surfaces |
| `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |
| `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |
| `NativeAgentIntents.swift` | Named resident-agent Shortcuts; NativeAgentDoctorIntent admits and settles runs through the live DoctorFacade |
| `NativeAgentMotion.swift` | `NativeAgentMotion`: shared transitions; Reduce Motion stops layout, retains fades |
| `NativeAgentNotificationActions.swift` | Native response mapping and mounted dispatch; EngineNotificationActions owns effects |
| `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |
| `NativeDisclosureTriangle.swift` | `NativeDisclosureTriangle`: AppKit disclosure button bridge sharing the row's expansion binding |
| `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession`; nonisolated callbacks, actor settlement |
| `NativeOAuthPlatform.swift` | `NativeOAuthPlatform`: `NativeOAuthPlatformPort` conformance and `isCanceledLogin` adapter |
| `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge with native clear/escape/return behavior and explicit focus tokens |
| `NewDeskTaskSheet.swift` | `NewDeskTaskSheet`: retained task draft opened by the Desk face's new-task action |
| `OAuthSignInButton.swift` | `OAuthSignInButton`: sign-in, CLI consent and persisted credential presentation |
| `ObservatoryNoticeRow.swift` | `ObservatoryNoticeRow`: one compact tinted notice presentation shared by Observatory panels |
| `OnboardingProfileRepair.swift` | Profile-only repair and completion; preserves persona and skips fresh-install work |
| `OnboardingProviderRow.swift` | Onboarding's account setup row; the Providers page is drawn from its face |
| `OnboardingRecovery.swift` | Durable-state recovery; resume interrupted transactions through onboarding |
| `OnboardingTourOverlay.swift` | Stable rail-stop identity from engine layout; local overlay progress |
| `OnboardingWizard.swift` | Fresh identity and wizard presentation; distinct recovery, repair and reset |
| `OnboardingWizardState.swift` | Local name/progress drafts; ProvidersFacade owns Chat readiness |
| `PageSheetHost.swift` | Shared page sheet framing and focused Desk schedule/research sheets |
| `PersonalityEditor.swift` | Linked identity editor and starter; existing draft, name and document save owners; memory owns USER.md |
| `PersonalityFaceDestinations.swift` | Personality face links open its existing editor, minds picker, Dreams and confirmed identity reset |
| `ProviderCards.swift` | Shared provider cards, notes, titles and account status words |
| `ProviderConfigSheet.swift` | ProviderConfigSheet holds connection credentials, protected drafts, model defaults and explicit verification |
| `ProviderThenModelPicker.swift` | Shared provider/model menu for onboarding and helper editors |
| `QuietComposerCommands+Presentation.swift` | Quiet composer command port, checked routing projection and mounted-page effects |
| `QuietSelfAdminRender.swift` | Quiet pages read engine.pages faces as text before page-specific projections; offscreen rendering |
| `ResearchView.swift` | `ResearchView`: search/configuration actions and eligibility/status presentation over root-scoped Research owners |
| `ResetPersonaView.swift` | ResetPersonaView and OnboardingWizard pending-setup reset; both use the backup-preserving onboarding reset owner |
| `RunDetailSheet.swift` | Full prompt, output and saved run facts remain an instrument reached from Diagnostics run rows |
| `SchedulerView.swift` | `SchedulerView`: scheduled job controls and explicit accepted/refused toggle receipts |
| `SelfImprovementView.swift` | `SelfImprovementView`: weekly improvement switch, corrected-lesson growth reads and explicit manual-run feedback |
| `SensesAssembly.swift` | `SensesAssembly`: gated hub bindings; scoped readiness and repair; quiet reads borrow no authority |
| `SensesView.swift` | `SensesView`: engine projection, scoped changes, live watches and lifecycle controls |
| `SessionDragSourceView.swift` | `SessionDragSource`: AppKit desktop-detach bridge and monitor teardown |
| `SessionRow.swift` | `SessionRow`, `ChatRenameStateMachine`: pin/origin display; exactly-once rename settlement |
| `SettingsDock.swift` | `SettingsDock`: helper card docked beside System Settings with the app icon to drag into the list; closes on grant, Settings quit or Close |
| `SettingsNavigation.swift` | SettingsLink routes to canonical pages; ShellPageFrame supplies shared page layout |
| `SetupMindsView.swift` | Personality minds tab shares the Memory and mind group transaction |
| `ShellRailPages.swift` | `SurfaceLayoutContent`: checked layout; `ShellRailTab`: canonical tab routing |
| `ShellSidebarRail.swift` | `ShellSidebarRail`: canonical rail item presentation, selection and focus-ring rendering |
| `ShellTabs.swift` | Shell page/tab components: content-local action rows, shared scroll gutter and tabbed page layout |
| `ShellWindowChrome.swift` | `ShellWindowChrome`, `ShellFrame`: native chrome, split layout and keyboard order |
| `Shotgun.swift` | `ShotgunController`: person-only driving chat; scoped Stop/Resume, placement and fade settlement |
| `ShotgunPointer.swift` | `AgentPointerOverlay`: noninteractive pointer and fades; excluded from agent captures |
| `ShotgunView.swift` | `ShotgunView`: driving-session transcript/composer, live step and Stop/Resume/Watch controls through existing owners |
| `SimpleContactThread.swift` | Contact replies, Stop and queued resend through canonical session acceptance |
| `SimpleHelperThread.swift` | Helper history and read failures; accepted drafts route to helper or resident chat |
| `SimpleSetupPanel.swift` | `InlineCardSetupPresentation`: existing setup controls in a floating Simple panel or Advanced sheet/page |
| `SimpleShellView.swift` | Simple and Advanced shells select the engine's shared contact and helper threads |
| `SimpleSidebar.swift` | Engine contact and helper rows and shared settings |
| `SimpleThreadComposer.swift` | Thread-bound drafts clear only on acceptance; shared send and accessibility |
| `SimpleThreadPresentation.swift` | Thread typography, outcomes, `SimpleThreadDocument` rows; absent time and pending work stay explicit |
| `SimpleViewMode.swift` | `ViewModeSwitch`: Simple/Advanced/Agent selection and shared top chrome placement |
| `SkillLifecycleView.swift` | `SkillLifecycleView`: persona-guidance reads and build-draft handoff through chat owners |
| `SystemPermissionPreflight.swift` | Shared consent; scoped failures, bounded activation and Bluetooth waits, checked cleanup |
| `SystemToastBar.swift` | platform notice rendering and room-scoped positioning; values, queue and timers belong to NativeAgentShared |
| `TelegramView.swift` | `TelegramView`: credential-free settings and receipts; outbound success proves no inbound health |
| `ThinkingGlow.swift` | `ThinkingGlow`: leaf-layer working shimmer and composer rim driven by turn state, fading when reply text begins |
| `TodayView.swift` | Today's source lifecycle and Activity destinations; the page itself is FacePageView over engine.pages |
| `ToolOperationStatusReceipt.swift` | Bounded AppModel operation feedback; repeated results retain independent receipt identities |
| `ToolsView.swift` | Tools screen, scoped refresh feedback and Trust navigation through AppModel |
| `TranscriptAttachmentViews.swift` | What each document attachment draws: the transcript's existing card, table and row views |
| `TranscriptAttachments.swift` | Document view attachments: one hosted view per block id, fed from the model, sized to fit |
| `TranscriptCards.swift` | Mounted transcript cards; action environment reaches the interaction owner |
| `TranscriptDocumentController.swift` | Owns the document and the one law: place is a text location, never a measured height |
| `TranscriptDocumentView.swift` | `TranscriptDocumentView`: any run of a conversation as one document; hover bar, sheets, host handle |
| `TranscriptFragments.swift` | One layout fragment per drawn paragraph kind, and the delegate that picks them and hides closed folds |
| `TranscriptStyle.swift` | The document's look: paragraph attribute keys, the app's tokens in AppKit units, one block rendered as one paragraph |
| `TranscriptTextView.swift` | The one NSTextView (TextKit 2) and its scroll view: menu, pasteboard, keys, hover, folds and the soft edges |
| `TrustActions.swift` | Shared Trust preset commands, action outcomes, navigation keys and Telegram status tone; Trust draws its core face |
| `TrustPermissionsViews.swift` | Shared Settings memory permissions and feature-switch rows; Trust permission controls live in its face |
| `UpdateController.swift` | `UpdateController`: configured Sparkle lifecycle, version probes and explicit unavailable/update presentation |
| `VoiceInputController.swift` | `VoiceInputCapture.forChat`: name context, macOS speech consent and shared failures |
| `WindowHaze.swift` | Mac window haze palette, controls and shared `HazeView` presentation |
| `WorkPane.swift` | `WorkPaneState`, `WorkPane`: read-only tabs, visibility and turn-driven auto-open |
| `WorkPaneMakeView.swift` | Canonical Make versions; image failures stay visible; export retains both outcomes |
| `WorkPaneSenseView.swift` | `WorkPaneSenseView`; separate offline script-enabled WebKit host, one version-bound sense event channel |
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
| `SenseNewsBoard.swift` | Bounded deduplicated news and care crossing; checked persistence precedes publication |
| `SenseScreenThings.swift` | Exact window selections, related-action bindings and in-turn mac.act verbs |
| `SensesContract.swift` | Sense wire records, bounds, origins, provenance and crossing contracts |
| `SensesHub.swift` | Locked installation task, bounded cancellable readiness, watch inventory and exact-version provenance |
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
| `AgentConversationSession.swift` | `AgentConversationSession`, `approvalRow`, `replayApproval`, `viaAbility`, `answer`, `agent.reply`, `clear_queue`, `settle` |
| `AgentConversationStore.swift` | `save`, `restoreProjections`, `records`, `AgentConversationDelivery.answersLive`, `offerReplyToInlineWait`, `offerBridgeReplyToInlineWait`, `outcome_unknown`, `unsettledAttention`, `recordsUnlocked`, `AgentConversationView` |
| `AgentConversationView.swift` | `AgentConversationView`, `read`, `view`, `conversationPresentation`, `compact`, `queueProjection`, `withQueue`, `withLive`, `expiringReply`, `dotReply`, `claudeWorklogTail`, `claudeWorklog` |
| `AgentConversationWaiting.swift` | Waits preserve checked approval and restart evidence. |
| `AgentDiscoverySession.swift` | `AgentDiscoveryCandidate`, `AgentDiscoverySession`, `app.installed` |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter`, `edit`, `grantMessaging`, `removeMessaging`, `checkEntry`, `writeEnvironment`, `ensureEnvironment`, `checking` |
| `AgentHostConnection.swift` | `AgentHostConnection`, `builderWorkspaceRoot`, `isNamedConnect`, `verifySetup` |
| `AgentHostDirectory.swift` | `AgentHostDirectory`, `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`, `installation.evidence`, `executables`, `discoveryWords`, `searchPaths`, `messagingPermissionsPath`, `messagingPermissionSyntax` |
| `AgentJob.swift` | `AgentJob` record, `AgentJobStore` (agents/jobs.json), the `JobRunner` door contract, its refusing stub, `OwnLineRunner` |
| `AgentJobStem.swift` | `AgentJobs`: commission, read, stop, the done-check, deliverable registration and the settle into the agent's own context |
| `AgentJobWorktree.swift` | A repo job's own worktree: the cut, its diff captured as the agent's deliverable, the agent's apply and discard |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentMessageFiles.swift` | Admit outgoing files before sending. |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery`, `probe`, `Launch`, `agentProgramLaunch` |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy`, `peerFailure`, `peerAuthorizeInterface` |
| `AgentPeerStore.swift` | `isReady`, `AgentContactHealth`, `list` |
| `AgentPeerTransport.swift` | `AgentPeerCredentials`, `BridgeCore` |
| `AgentRecipeStore+Schema.swift` | Writes require the exact Codable recipe shape. |
| `AgentRecipeStore.swift` | `AgentRecipeStore`, `Resources/grok-routine.json`, `AgentHostDirectory.rows`, `AgentHostRow.A2A`, `recipe(for:)`, `load`, `recipe`, `launch`, `read`, `write`, `learn`; dry-run mode belongs to the explicit conversation operation |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator`, `resolve`, `discard`: one worktree per job |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport`, `listen`, `reconnect`, `stop`, `readiness` |
| `GrokBotRoute.swift` | `GrokBotRoute` enum; `withHistory`, `takenByWaiter`; cancellation ends the waiter handoff without resampling |
| `HelperContact.swift` |  |
| `JSONEntrySplice.swift` |  |
| `JobDoor.swift` | `JobDoors.install`; what every job door shares: its outlet and beat, the envelope broker, what the organ made, its live runs |
| `JobDoorA2A.swift` | `A2AJobDoor`: a job as an A2A task, followed until it ends; its returned artifacts are written into the job's folder |
| `JobDoorACP.swift` | `ACPJobDoor`: a job as one ACP session in the job's folder, `session/request_permission` answered against the envelope |
| `JobDoorClaude.swift` | `ClaudeCodeJobDoor`: a job through `claude -p` stream-json, its permission prompts answered by the agent's broker over stdio |
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
| `AgentOpened.swift` | Application-launch attribution; observers close at work end or shutdown |
| `AgentQueue.swift` | `MyQueueTurnProjectionProviding`, `MyQueueReady`, `AgentScreen.queueContext`, `resume`: checked conditions |
| `AgentRoomCache.swift` | Session-scoped room bindings with bounded lasting item names and current-draw verbs |
| `AgentScreen.swift` | `AgentScreen`, `withNames`, `resolve`: stable names and checked owner projections |
| `AgentScreenPreview.swift` | shared screen/room text projection |
| `AgentScreenRooms+Agents.swift` | `AgentScreen`, `agentsTarget`, `delegationsRoom`: exact owner liveness; crews are the agent's lines |
| `AgentScreenRooms+Build.swift` | `AgentScreen`, `buildRoom`, `buildTarget`, `buildRecordRoom`: partial coverage stays visible |
| `AgentScreenRooms+Comms.swift` | `AgentScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `AgentScreenRooms+Core.swift` | `AgentScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `AgentScreenRooms+Elsewhere.swift` | read-only cross-door continuity; peer turns omit person/helper words |
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
| `AgentWorld.swift` | Retained owner projections; asks read ForPerson's in-memory inbox without a second cache |
| `CarriedHabits.swift` | `CarriedHabits`: bounded trials; daily offers never bind |
| `DelegationCaches.swift` | Read acceleration over unchanged file stamps |
| `DelegationReadout.swift` | retain source availability and distinct delivery/execution times |
| `DelegationStatusProjection.swift` | Retained reply deliveries; an unreadable record is its own gap and readable siblings proceed |
| `FamiliarLines.swift` | `FamiliarLines`, `mind/familiar.bin`: first encounters alone prime recall |
| `HarnessQueue.swift` | `HarnessQueue`, `HarnessFinding`, `file`, `resolve`, `fold`: stable finding and carry identities |
| `HomeFace+Rows.swift` | Home's waits, queue, repairs and contacts as structured rows; cached condition evidence never becomes an empty verdict |
| `HomeFace.swift` | Home's shared native face from retained world parts; source-fed lifetime, cached reads and section gaps |
| `HumanConversationIndex.swift` | bounded human index; unavailable source/revision never invents provenance |
| `IntentionClock.swift` | `IntentionClock`: shared scheduler occurrence identity |
| `MacScreenPreviewBus.swift` | `MacScreenPreviewUpdate`, captions and source-masked resizing; the turn carries its screen-preview sink |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentWorkspace diagnostics |
| `PrimedMoments.swift` | `PrimedMoments`: five moments within twelve hours, consumed once |
| `ResidentWake.swift` | `ResidentWake`: one retained arrival and settlement ledger |
| `SurfaceLayoutStore.swift` | `SurfaceLayoutAvailability`, `SurfaceLayoutLive`, `read`, `write`, `setSurfaceExpanded`, `LatestRead` |
| `ToolSignature.swift` | `call`, `doorArgs`: checked argument shapes |
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
| `ClaudeBridgeRuntime.swift` | Response deadlines retain accepted work until exit. |
| `ClaudeBridgeStateProjection.swift` | Bridge state; recent notes read ForPerson's in-memory inbox and retain read failures |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` |
| `DesktopAgentConversationRoute.swift` | `Resources/abilities/desktop-courier.js`, `Parts.call` |
| `DesktopChatRoute.swift` | `accessibility_permission_missing`, `settle`; Recipe-bound sends retain uncertainty and settlement. |
| `DesktopRouteObservation.swift` | Event wakes retain bounded deadlines. |
| `GrokBotConnection.swift` | Uncertain setup never authorizes resend. |
| `GrokDesktopReply.swift` | `settle`; Correlate exact replies through bounded AX reads. |
| `GrokInboundReply.swift` | `TurnAdmission.admittedRun`, `settle`; Claim and retain handovers through actual exit. |
| `GrokRoutineAccessibility.swift` | Native-only secret and clipboard handling. |
| `HumanConversationReplyService.swift` | `HumanConversationReplies.reply` |
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
| `ResidentWakeRuntime.swift` | Resident wakes share one scheduler and reply routes. |
<!-- END GENERATED BLUEPRINT -->

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AppToolRuntime/ -->
| File | Owns |
|---|---|
| `AppAction.swift` | Action declarations, folded gates, argument policy and effect receipts |
| `AppActionRegistry.swift` | One native/authored/guidance/sense inventory and policy bindings |
| `AppActions+Contracts.swift` | Argument shapes, dependency flags and canonical live contracts |
| `AppActions+Declarations.swift` | Seed actions, owner schemas, fixed input and hot-action vocabulary |
| `AppActions+Discovery.swift` | Guides, schema constraints, examples and scalar-list discovery |
| `AppActions+KeptParts.swift` | Bounded kept-part glance |
| `AppActions+Ranking.swift` | Exact ids/pages precede checked semantic matches; item gaps stay local |
| `AppChatToolDispatcher.swift` | `withAuthoredProgramHost`; Gated dispatch and settled-result observation |
| `AppDoorActions.swift` | Shared admission, previews and typed receipts; accepted matters supply the call's knock count |
| `AppDoorPrograms.swift` | Ordered gated calls; failed/waiting steps bar changes, not independent reads |
| `AppDoorReading.swift` | Home/page/item/find reads; call-fit census independent of admission |
| `AppScriptRunner.swift` | Gated program host, live contracts and shared normalization |
| `AppToolExecutor+AppDoor.swift` | `app`, `visible`, `undo`; App dispatch, version recovery and action-owned undo |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpCheck`, `runChromeHistory`; follow-ups stop on Trust receipt failure; Chrome internal reads return one text line with read_mode none; chrome.look and DOM-inaccessible Chrome/PDF snapshot reads deliver the owned tab's bounded picture through the shared file-reader image slot, with source dimensions, explicit picture mode, independent debugger cleanup errors and raw Chrome provenance; PDF text remains unread with no independent fetch; action readback preserves non-DOM receipts; history reads only a stable private copy of the admitted Default profile History/WAL/journal under Full Mac/file-read authority, independent of extension connection; SQLite opens only the copy read-only, aggregates all qualifying visits before limiting domains, and bounds returned rows and query work; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`, `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall`; observed-field batches |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+Make.swift` | `AppToolExecutor`; Studio versions, intake and workspace-fenced reply images |
| `AppToolExecutor+MyQueue.swift` | `runMyQueue`, `runHouseFile`; Exact-id intentions, schedules, habits and closure receipts |
| `AppToolExecutor+PagePresentation.swift` | screenshot results with an explicit image sink and quiet page/read rendering |
| `AppToolExecutor+PartRun.swift` | `AppToolExecutor`: a part's own run (`doorPart`: Desk holds, the gated `authored.<id>` with its in-flight turn's arrival check (a message or that turn's Stop), `afterPartRun`: MY QUEUE upgrade line, runner-owned effect reconciliation and action-owned version recovery, with fresh-run calls only for no effects, a strict stop kept to resume), `doorPartPreview` retains nested value-call version pins, `doorPartResume` (optional bare/action ability id checked before claiming its checkpoint; receipts name the bare id); holds and bookkeeping failures retain the result and owe their owner repair, `doorWouldCard`; stopped checkpoints delegate to Desk’s `PartRunStore` |
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
| `NativeSkillRegistryActions.swift` | owner-facing enable/disable through `Parts`; `enableSkill`, `disableSkill` |
| `PartThoughtTools.swift` | Part thought shares the originating ToolHost and gate chain; retains uncertain effects |
| `PhoneSensesGuide.swift` | Pairing guide reads canonical phone evidence and per-organ setup |
| `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; Shared checked view and appearance preferences |
| `QuietChatSessionCommands.swift` | `QuietChatSessionCommands`; Effect-free fences and canonical session receipts |
| `QuietComposerCommands.swift` | `QuietComposerCommands`; Composer commands share preview and execution fences |
| `QuietInboxCommands.swift` | `QuietInboxHost`; Inbox fences and receipts; committed effects survive unknown readback |
| `QuietSelfAdminSettings+LowerOnly.swift` | Lower-only rows enforce subsets under the authority lock |
| `QuietSelfAdminSettings+Mobile.swift` | mobile settings projection and writes |
| `QuietSelfAdminSettings.swift` | Shared authority/validation and platform settings catalog |
| `QuietSetting.swift` | Throwing read/choice contract, explicit turn-bound writes, checked Trust and MainActor receipt detail |
| `QuietSettings+BotSchedules.swift` | Bot cadence rows; mutation rereads canonical definitions |
| `QuietSettings+Models.swift` | Group model/account/effort transactions retain inheritance |
| `QuietSettings+Personality.swift` | Profile-owned name and checked-Trust dream controls |
| `QuietSettingsHost.swift` | Settings owner ports, mounted platform control declarations and asynchronous phone-owned control resolution |
| `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |
| `QuietTrustPolicyPreset.swift` | `MobileTrustAction.Preset` policy plans, locked save and effective-policy matching |
| `Turn+AppTools.swift` | `Turn` parts app tools own: setting-write authority and the signed phone change |
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
| `ApprovalRecord.swift` | Approval substance, checked origin doors and the one decision face; resolution provenance remains authority |
| `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`; Match grant, spend and effect. |
| `ApprovalStorage.swift` | Checked canonical approval storage |
| `ApprovalWords.swift` | `ApprovalWords.title`: shared plain-language approval names for Today and agent home |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ApprovalInbox diagnostics |
<!-- END GENERATED BLUEPRINT -->

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalTransactions/ -->
| File | Owns |
|---|---|
| `ApprovalCardPresentation.swift` | Scope comes from approved arguments, never prose. |
| `ApprovalChatCards+Interactions.swift` | Conversation mirrors and Telegram receipts read the matter's doors; every answer settles the origin |
| `ApprovalChatCards.swift` | A conversation delivers its matter's card, then accepts its conversation door with the transcript row |
| `ApprovalReconciliation.swift` | Approval execution reconciliation and Desk settlement |
| `ApprovalReplay.swift` | Exact chat tool approval replay interpretation |
| `ApprovalSettlement.swift` | Provenance checks precede spend; receipts precede continuation. |
| `ApprovalSubjects.swift` | Domain outcomes feed shared settlement. |
| `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects`, `ApprovalExecution.approvedEffectTurn` |
| `ApprovalTransactionCoordinator.swift` | Shared approval execution retains outcomes until receipt settlement; the decision archives its matter |
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
| `TelegramApprovalCoordinator.swift` | Prompt transactions retain unknown sends; returned message receipts accept the matter's Telegram door |
| `Turn+Approvals.swift` | `ApprovalResolutionProvenance.resolvingTurn`: card decision held by its verifying door |
<!-- END GENERATED BLUEPRINT -->

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AttentionRouting/ -->
| File | Owns |
|---|---|
| `AttentionDeliveryPorts.swift` | Host ports classify delivery; phone receipts never imply acceptance |
| `AttentionFacts.swift` | Shared transport verdicts drive attention; queued or absent evidence never proves acceptance |
| `AttentionRouter+HeldDelivery.swift` | Releasing what the person's quiet hours held, and doors refused once what they depend on changed; read from ForPerson in memory |
| `AttentionRouter+MacNotifications.swift` | Mac banners: UI-physics posts, and the Mac door's post whose OS callback settles its delivery |
| `AttentionRouter+MemoryReview.swift` | Memory-review crossing tells one Mac matter; dropping below threshold resolves that matter |
| `AttentionRouter+Policy.swift` | The person's doors from the person's rulings (phone always, the thread it came from, the Mac while the person is at it); quiet hours |
| `AttentionRouter+RequestedResults.swift` | Result and bot-condition matters; transcript acknowledgement follows every door's acceptance |
| `AttentionRouter.swift` | One way to the person: a matter is told once (ForPerson) with the doors the person's rulings give it, and each door's delivery is its `deliver:<door>` obligation; origin-bound transports |
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
| `DelegationOutcome.swift` | Owner-proven terminal outcomes remain distinct from stalls |
| `DelegationOutcomeCard.swift` | One stable delegated-job inbox card and grounded resident wake text |
| `DelegationOutcomeCursor.swift` | Exact durable handled identities and receipt versions; advances only after corresponding card settlement |
| `DelegationOutcomeLoop.swift` | One delegation reconciliation/settlement runner; dry runs advance without a card or delegation settlement |
| `DeskContinuationScheduler.swift` | `DeskContinuationScheduler`, `nextDeadline`, `runDue`, `prompt`, `turn-continuation`; native claims |
| `DeskNotifyRunner.swift` | Desk matters and nags; ForPerson changes arm the quiet-window end deadline, which releases owed doors |
| `DoctorAutoRunLoop.swift` | Doctor asks are episodes in ForPerson; measured source checks clear them |
| `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; Health and schedule rules |
| `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |
| `DreamBackgroundWork.swift` | Dream and REM settlement; care and growth approvals tell their one ForPerson face |
| `DreamSurprises.swift` | `DreamBackgroundWork.makeDreamSurpriseProvider`; CPU-only retained surprise material |
| `HeartbeatAssessment.swift` | Heartbeat assessment, notice and action values consumed by the existing work and loop owners |
| `HeartbeatBackgroundWork.swift` | Existing heartbeat work binding, event/deadline loop construction and age limits |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `HeartbeatDurableResidue.swift` | Durable residue tells an inbox-only episode; incomplete inventory never clears it |
| `HeartbeatHealthAssessment.swift` | HeartbeatBackgroundWork compact health assessment and exact age deadlines |
| `HeartbeatLoop.swift` | Event/deadline heartbeat checklist lifetime and per-condition notice settlement; missing checklist claims no health |
| `HeartbeatNoticeCards.swift` | Heartbeat condition episodes are matters; measured clearance resolves them without another alert |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundWork diagnostics |
| `OffDiskBackupRunner.swift` | `MaintenanceBackgroundWork.makeOffDiskBackupLoop`; Native metadata, root protection and copying |
| `SelfImprovementProposals.swift` | `SelfImprovementProposal`; Exact approval code and stable finding identity |
| `TelegramBackgroundBridges.swift` | Telegram memory-write bridge through the canonical memory owner |
| `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork`, `BackgroundLoopLifetimes`, `native-morning-brief.js`; scheduling |
| `UnattendedWork.swift` | `UnattendedWork.allowed`: the one admission for work the agent does while nobody is watching |
| `WeeklySelfImprovementLoop+Evidence.swift` | `SelfImprovementLearning`; Bounded usage and prior-card evidence |
| `WeeklySelfImprovementLoop.swift` | `WeeklySelfImprovementLoop`; Shared reservation, checked proposals and digest |
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

`SessionHistoryTail` derives whole-turn checkpoints from cumulative replay row
sizes in the admitted transcript, without a stored cut pointer. The composed
request uses the powering model's full default window; at its bound one oldest
block drops in half-budget jumps. Transcript bytes stay intact. Resident and
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
| `CanonicalToolNameDispatcher.swift` | `CanonicalToolNameDispatcher` class; `canonical`, `dispatch` |
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
| `GitHubCommandCheckoutResolver.swift` | Match exact repository remotes; refuse ambiguity and read failures. |
| `HarnessDecidedRow.swift` | Rolling decision matters keep their count on the face; settled rollups get new identities |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | `InlineInteractionRegistry` enum; `connectorSetup`, `canonicalConnectorID` |
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
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` retain provenance on readback (a read steers nothing); `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`, `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata`; bounded recall |
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
| `ToolResultSections.swift` | `ToolResultSections`, `pages`; lossless paging; verdict before bulk; raw oversized atoms |
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
| `Turn+Contracts.swift` | `Turn` holds chat admission, execution and sinks; `TurnRows` holds transcript state |
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
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: delivers the message's facts (text, door, who, verified id, trust, steering, posture), runs the agent's turn part's effects, hands it each event with each result's declared effect, logs at every host-call boundary; the agent's own `app` calls run once as their own dispatch round through the same door and gates, and a turn may act or end before any model call; the turn returns at `reply.end` and `after`, and nothing of the agent's runs after it); before a fresh message’s opening model call, mind/authority practice may supply one gated standing read as `already_looked`; after each tool round the familiarity nerve meets the turn's landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), and on a later meeting no active ability's recorded route covers it puts `practice` on the round's last result once a turn, traced as `practice.keep`; `joinedProse`; `provider.roundOutput` counts safe prose and tool calls per parsed round; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated for `took`): `took` is the after-turn line, and each part called records its rounds |
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
| `ChatTurnEvidence.swift` | Produced turn evidence and durable answer/owner-turn stamps; records retain their existing locks and formats |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`; `chat`; Explicit route, budget and mechanical provenance |
| `ChatTurnFailure.swift` | `ChatTurnFailure`; Retry from exact dispatch/effect evidence |
| `ChatTurnSettlement.swift` | One joined turn settlement preserves append-before-observe, produced output, terminal evidence and releases |
| `ChatTurnSteering.swift` | `ChatTurnSteering`; Canonical open turns, offers from waiting arrivals and atomic resident reservation |
| `ChatUpdateNote.swift` | Version note selection and launch transaction with supplied bundle resource/version inputs |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ContextStageTrace.swift` | `ContextStageTrace`; Payload-free bounded context telemetry |
| `ConversationPrefixSeeding.swift` | User-leading deltas, keyframes and exact sent-row metadata |
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
| `MindMemoryManager.swift` | `MindMemoryJudgment` struct; `predictionModelKey` (the record's key for the model the judgment runs on, read without changing the request; the interpretation reports the same model), `interpret` (with cares when shown and optional reply-grounded promises), `interpretBatch` (owed turns in one call, the same parser and rules once, one section per turn; a missing section stays owed), `appraiseCares`, `relevantRecallIDs`; incremental ranked evidence and catalog-budgeted relevance batches; `AfterTurnMemoryFailure` preserves output limits, request rejections and refusals with distinct recovery |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatTurnRuntime diagnostics |
| `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`; User-authored head classification |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch`; `isSerialFallbackForced`; `isParallelSafe` |
| `PersistedToolReceipt.swift` | `PersistedToolReceipt.project`; `SwiftNativeTurnEngine.landedEffect` |
| `ProactiveAssistantSpeech.swift` | `speakProactively`; Locked deduplicated speech; initiative quota |
| `ProviderRecoveryPolicy.swift` | `TurnEngineError`; Typed provider failures retain partial work evidence |
| `ProviderToolNameMap.swift` | `ProviderToolNameMap`: stable provider-safe tool aliases with reverse mapping to canonical dispatch names |
| `SessionContextRequestBuilder.swift` | Fit the already-read replay at transcript-anchored half-budget checkpoints. |
| `SessionTurnDelivery.swift` | Session-owned live delivery and exact-run repair debt |
| `StandingBotContinuity.swift` | Helper-owned ingress and exact session ownership |
| `StandingBotModel.swift` | `Expansion.withTurn`; Helper-owned measured replay and paragraph deltas |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolCallCodec.swift` | `ToolCallCodec`; Offered wire grammar; dispatch stays with the loop |
| `ToolLoopSupport.swift` | `ToolLoopTraceObservation`; `ToolDispatchDeadline`; Retained loop evidence and response deadlines |
| `Turn+Runtime.swift` | `Turn` holds runtime state; `ChatTurnWork` holds operation dependencies and LLMCall refinement |
| `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`; Checked local quiet hours shared with delivery |
| `TurnContextPreparation.swift` | Admitted route, frozen facts and bounded attention input |
| `TurnContextSnapshotTrace.swift` | Exact opening-request snapshots and ordered fed-context writes |
| `TurnDispatchBookkeeping.swift` | Joined dispatch bookkeeping on success, failure and Stop |
| `TurnEngineContracts.swift` | `TurnContext`; `TurnEngineResult`; Prepared context and engine-owned terminal truth |
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
| `ChromeControlChannel.swift` | `ChromeControlChannel`, `ChromeConversationTab`; Ordered socket effects; tab/document authority. |
| `ChromeControlHandshake.swift` | `ChromeControlHandshake`; Authenticated relay identity and bounded hello. |
| `ChromeControlRuntime+ConnectionEvidence.swift` | `ChromeControlRuntime`; Historical facts never prove connection. |
| `ChromeControlRuntime+ConversationTabs.swift` | `ChromeControlRuntime`; Per-conversation tab memory and release evidence. |
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
| `NativeCognitionRuntime+Pursuit.swift` | NativeCognitionRuntime+Pursuit owner. |
| `NativeCognitionRuntime+Reach.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Readouts.swift` | `NativeCognitionRuntime`, `GrowthWeekFace`. |
| `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+Rhythm.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+RunNow.swift` | `MindClockVerb`, `MindClockResult`. |
| `NativeCognitionRuntime+SourceWakes.swift` | `SenseCrossing`. |
| `NativeCognitionRuntime+StudioCanon.swift` | NativeCognitionRuntime+StudioCanon owner. |
| `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime+TurnPresentation.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime`. |
| `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail`. |
| `OrganJudge.swift` | `OrganJudge` beat law for the mind's judges; organ names of the clock owners; loop-shaped passes as beats |
| `Reach.swift` | `ReachCandidate` and pure `Reach` pacing, eligibility, provenance and delivery policy |
| `ReachLedger.swift` | `ReachLedger`: bounded outreach facts, checked reads and locked answer-settlement writes at cognition/reach.json |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |
| `StudioWanderLane.swift` | `StudioWanderLane`. |
| `StudioWanderToolWitness.swift` | `StudioWanderToolWitness`: hour action admission and encounter evidence at the gated dispatch seam |
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
| `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.makeAttentionSignals`: bounded resident attention |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: frozen cues, shared presence and presentation commits |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `soundEchoShouldSpeak` |
| `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate`: provenance-gated care birth, movement and durable merges |
| `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate`: care pressure, turn cues, watch attention and habituation |
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
| `Turn+Cognitive.swift` | `Turn` parts cognition owns: the incoming row's after-turn origin and claimed care wakes |
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
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |
| `ConnectorActions.swift` | `ConnectorActions`: shared admission; CodexHandoff identity; redacted native reads; journal gaps |
| `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and checked `ConnectorProofLedger`: receipt-backed health decays without polling |
| `ConnectorOAuthRegistry.swift` | Registry owner: `mutateConnectorRegistryEntry`, `removeConnectorRegistryEntries` |
| `ConnectorRegistryActions.swift` | Ordered registry verification; disconnect intent precedes credential removal |
| `ConnectorWizardActions.swift` | `ConnectorWizardSetupRoute`: wizard and inline cards share the setup registry |
| `Connectors.swift` | Checked workspace search and identity; capped or unvisited scope remains explicit |
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
| `ContextArena.swift` | `ContextArena`: bounded generations, leases and pressure |
| `ContextAtomMatching.swift` | `ContextMarkdownCompiler` atom matching: ordered exact identity reuse and heading-scoped fuzzy matching |
| `ContextCandidateScore.swift` | Context eligibility decisions and candidate scoring values with their existing codecs |
| `ContextCorrectionScope.swift` | `ContextCorrectionScope`: canonical scope gates, never authority |
| `ContextExpansion.swift` | `ContextExpander.expand`: offered-pointer expansion without mutation or authority |
| `ContextFeedback.swift` | `ContextFeedbackReducer`: rebuildable utility and use reachability |
| `ContextFlowModels.swift` | Context identities, policy and immutable generations |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`, `triggerTokens`: bounded Markdown atoms and source-specific triggers |
| `ContextMarkdownGrammar.swift` | `ContextMarkdownCompiler` grammar: UTF-8 block ranges, Markdown boundaries and generated USER fact bullets |
| `ContextMemoryLead.swift` | `ContextMemoryLead`: rendered age, provenance and source |
| `ContextPacket.swift` | Context packet, expandable pointers, safe representation leads and retained memory provenance |
| `ContextPreparation+Feedback.swift` | ordered feedback replay and delivery-backed local rest |
| `ContextPreparation+SourceReconciliation.swift` | source compilation, checked faults and gated generation publication |
| `ContextPreparation+TurnSelection.swift` | turn leases, authorization, precoverage and verified delivery |
| `ContextPreparation.swift` | Context lifecycle, health, publication admission and shutdown drain |
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
| `ContextSourceMonitoring.swift` | `ContextSourceRegistry`: allowlists, owner inventories and bounded invalidation |
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
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime`: checked admission; joined lifecycle; drain and provenance |
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
| `DeskBoardLayout.swift` | `DeskBoardLayout` partitions active work; `DeskPage` interprets freshness |
| `DeskCadence.swift` | Checked step provenance and cadence; malformed saved values cannot become defaults |
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation`; life-stamped resumable work, stopped/restored projection; receiptIsUnresolved and toJSON |
| `DeskDependencyTransitions.swift` | Dependencies, hierarchy settlement and locked revalidation |
| `DeskHolds.swift` | Durable Desk hold ownership under the existing feed lock |
| `DeskItem.swift` | Derived work and explicit progress; statusDescription shares persisted wait truth |
| `DeskJournal.swift` | Locked event feed append, integrity and compaction |
| `DeskLiveStateMemo.swift` | Replay memo keyed by the canonical feed stamp |
| `DeskModels.swift` | Shared Desk enum vocabulary and JSON scalar interpretation |
| `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |
| `DeskNotify.swift` | `DeskNotificationRead`, `DeskNotificationProposal`: native consent and locked settlement |
| `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for HarnessQueue |
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
| `DeskStore.swift` | `SwiftNativeDeskStore`, `currentRevision`, `continuation`, `setContinuation`, `heldBy`, `updateTitle` |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `DeskText.swift` | `DeskPage`: compact board and exact-record text, sequencing segments, duration and archive presentation |
| `DeskWorkTransitions.swift` | Locked work creation, bounded reservations and idempotent receipts |
| `MyQueue.swift` | `MyQueue`, `entries`, `add`, `isReady`, `releaseSignal`, `releaseNews`, `When.isPrompt`, `Entry.owedToPerson` |
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
Its deadline includes 30-day completion-marker expiry; the archive watcher
observes directories before discovering and arming exact transaction files,
then pruning reads them. With no crossing or failed deletion it parks until
that watcher wakes it, including content or attribute changes that make an
overdue transaction readable. Watch replacement keeps observation continuous;
failed deletion retains its 60-second retry floor.
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

Mac receive deadlines exist only for live reply/request obligations, active
phone turns, the 120-second peer-activity window, or push that is unavailable
or lacking retained proof of a received CloudKit push across launches. Otherwise the
drain has no timer and its OrganPulse is off/resting. Launch, CloudKit push,
KVS message nudge, wake and network regain drain incoming work.
Signed foreground or active-talk phone contact renews that same activity window; the
[mobile transport contract](mobile_companion.md#transport-architecture) owns
its beat and foreground receive cadence. Pairing/status reads have one retained
task beside chat fetching so their latency cannot hold the chat drain's slot.
The receive timer owns its sleep and a separate retained drain owns accepted
work through actual exit; teardown cannot reopen its exclusion or let it
rearm an old transport's housekeeping. Subscription registration is retained
and serialized, and metadata callbacks require their exact live query.
Phone-request teardown settles its waiter with an unknown-delivery error and
cancels the send; that send keeps its exclusion until its actual exit.
Mac presence remains an external protocol beat, not change observation: the
engine holds its next due date and 120-second healthy / 240-then-300-second
failure backoff; `BackgroundLoops` owns the deadlines and a 300-second
reconciliation cadence that publishes only when due. Start/stop registration
changes are ordered, and late publication cannot update a new lifecycle.
Skipped beats are health-neutral: only a successful current publication can clear
an unresolved presence failure. Missing CloudKit transport, unsettled pairing,
or a phone deliberately paired elsewhere makes publication ineligible, not
failed. Such skips preserve the current delay; only an eligible publication
attempt can record failure and advance backoff.
Phone delivery
owns a pairing-scoped durable map of unaccepted record identities and renews
those original records on an eight-second deadline while iOS grants execution.
Verified correlated Mac progress/replies/action responses retire that ownership;
messages with no answer use the same signed progress path for acceptance.
The query projection clock can advance on renewal; the signed timestamp cannot.
Older phones do not renew: a lost push waits for the next real receive change,
with their existing waiting/no-update UI and signed expiry refusal preserved.

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
| `ICloudDeliveryNudgeQueue.swift` | `ICloudDeliveryNudgeQueue`; Bounded single-flight wake hints. |
| `ICloudDriveOutbox.swift` | Coordinated Drive outbox scanning, consumption and observation |
| `ICloudIncomingTurnForwarder.swift` | `ICloudConflatedSender`, `surface.replyDeliveryStarted`; Signed phone turns and retained delivery. |
| `ICloudIncomingTurnPort.swift` | Incoming phone turn engine port: resident chat, helper execution, presentation and control handoff |
| `ICloudIncomingVerification.swift` | Incoming message verification and receipt vocabulary |
| `ICloudReceiving.swift` | Retained chat drains; separate metadata reads cannot hold pickup. |
| `ICloudTextDeltaCoalescer.swift` | Immediate full snapshots; clock sequences outrank prior runs. |
| `LivingAttentionPolicy.swift` | `LivingAttentionPolicy.organismNeedsAttention`; Desk owns needs-person attention. |
| `MacPhoneRequestChannel.swift` | `MacPhoneRequestChannel`; Authenticated bounded wait; sends own exclusion. |
| `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`, `chatHistoryPage`; Generation-bound history. |
| `MacSyncActionRouter+Connectors.swift` | `MacSyncActionRouter`: `connectorAction` |
| `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |
| `MacSyncActionRouter+Providers.swift` | `MacSyncActionRouter`: `configureEncryptedProvider`, `startProviderSignIn` |
| `MacSyncActionRouter+Scheduler.swift` | `MacSyncActionRouter`, `schedulerAction`; Validated phone jobs. |
| `MacSyncActionRouter+Telegram.swift` | `MacSyncActionRouter`: `telegramAction` |
| `MacSyncActionRouter+Trust.swift` | `MacSyncActionRouter`: `applyTrustAction` |
| `MacSyncActionRouter+TrustCommand.swift` | `MobileTrustAction`: checked trust writes |
| `MacSyncActionRouter.swift` | `MacSyncActionRouter`, `surfaceSelection`; Canonical mutation receipts and bounded readbacks. |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | Both transports share ledger admission, replay, recovery and settlement. |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`, `start`, `stop`; Transport-selected roots; one snapshot lifecycle. |
| `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |
| `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |
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
| `ChatSlashCommands.swift` | `ChatSlashCommandRegistry`: shared recognition and execution; local presentation |
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
| `REMPinsReader.swift` | `REMPinsReader`: checked mtime-cached pin reads; only absence is empty, unavailable bytes fail the turn; `latest` |
| `REMProposalStore.swift` | `REMProposalStore`. |
| `REMReport.swift` | `REMReport`, `REMRunReportPayload`. |
<!-- END GENERATED BLUEPRINT -->

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

`EngineLaunch` keeps recovery, launch admission, task lifetime, loop ordering and
quit settlement. `EngineChatSurfaces`, `EngineDreams` and `EngineScheduledWork`
compose chat transports, Dream/REM and scheduler capabilities.

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
| `BotsFace.swift` | Helpers face over the helper owner's published memory; Run once and Paused return to the canonical owners |
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilitiesFace+Actions.swift` | Cached Mac, connector and check rows; every face action returns to its native owner |
| `CapabilitiesFace.swift` | Capabilities reads cached inventory, workflows, catalog and guardrails into one face for every door |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |
| `ChatModels.swift` | `ChatMessage`; Checked transcript codec, attachment previews and export |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `ChatTranscriptCache.swift` | `ChatTranscriptCache`; One decoded disk revision shared by transcript readers |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `ConnectorFace.swift` | `ConnectorReadiness`: in-memory Connectors face, status words and row actions |
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
| `ConversationSearch.swift` | `CommandPaletteMessageIndex`, `TranscriptsFacade`, `LatestRead`, `TranscriptSearch` |
| `DeskActivityPresentation.swift` | Desk availability, movement and expiry; a job carrying an item is its movement |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `DeskFace.swift` | Desk's board, attention, timers and reminders as one face over the retained Desk revision |
| `DeskFaceActions.swift` | Desk face actions return to the existing tool router, pursuit veto owner and mounted Mac editors |
| `DeskFaceItem.swift` | The selected Desk item or execution's canonical details, dependencies, notes and references in the Desk face |
| `DeskItemPresentation.swift` | Desk tones, item freshness and shared relative-time wording with exact next-change boundaries |
| `DeskPagePresentation.swift` | Desk page snapshots, attention, project/deadline composition and wording from one frozen board read |
| `DiagnosticsFace.swift` | Diagnostics reads the Doctor, runs and living-status owners in memory; native actions return to their existing host |
| `DiagnosticsFaceCopy.swift` | Shared diagnostics severity, check counts, malformed-time evidence and run outcome words |
| `DiagnosticsLivingStatus.swift` | Runtime-owned living-status subscriptions; source changes refresh the owner and its face until quit |
| `DoctorEmbeddingDownloadCheck.swift` | `DoctorEmbeddingDownloadCheck` enum; embedding download health `read`, `repair` |
| `DoctorProviderPathReading.swift` | Capture route faults before catalog recovery |
| `EngineApprovalNotifications.swift` | Approval observation delivers conversation cards; ForPerson owns the inbox reading and owed doors |
| `EngineApprovals.swift` | `ApprovalsFacade`; Checked shared inbox and gated single-flight decisions |
| `EngineBodyNerve.swift` | `BodyNerve`: each beat re-reads the body; a newly felt deviation becomes a somatic signal and a fault owes repair |
| `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands`, `ability_manage`, `Parts`, `CapabilityCommandOutcome` |
| `EngineCarriedHabits.swift` | Join terminal and dispatch evidence off-turn to record carried-work trials |
| `EngineChatSurfaces.swift` | Slack and Telegram ingress; speech permission episodes use the body attention port |
| `EngineCognitionModels.swift` | `LivingStatusSnapshot` and `DreamReport` completion and status interpretation |
| `EngineCognitionView.swift` | `CognitionViewFacade`, `LatestRead`, `DreamDiary`, `FileBackedDreamDiary`; Shared checked cognition projections |
| `EngineComposition.swift` | Root-bound body ports forward typed matters to the attention router |
| `EngineConnectors.swift` | `ToolsFacade.withPartDoor`; Checked connector reads and rooted gated execution |
| `EngineContactCommands.swift` | Person-initiated sends, original-scope Stop and held-message withdrawal |
| `EngineDaySense.swift` | Clock-driven day perception with authorized calendar titles and care rest |
| `EngineDesk.swift` | One retained board revision, ForPerson inbox changes, checked reads and gated local mutations |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeviceSync+Snapshots.swift` | `engine.connectors`, `engine.persona`, `engine.runs`, `engine.trust.snapshotData`; Checked phone adapter |
| `EngineDeviceSyncHelpers.swift` | `editBotDefinition`, `botsShelfRead`, `helpers_snapshot_error`; Checked helper edits and snapshots |
| `EngineDoctor+CapabilityActions.swift` | Improvement runs and verified exports live in Doctor, publishing start and settlement to Capabilities |
| `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`; Mounted cognition health and canonical phone authority |
| `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`; One launch refresh after durable terminal evidence |
| `EngineDoctor+StatusChecks.swift` | `DoctorFacade`; Native Desk and Activity evidence with authored narration |
| `EngineDoctor.swift` | Shared report availability, route health, liveness and checked publication |
| `EngineDoctorHealthReads.swift` | Shared live health cards and bounded completed-report reuse |
| `EngineDoctorMeasurements.swift` | Mounted provider, memory, tool, transport and organ health |
| `EngineDoctorRepairs.swift` | Owner repairs with receipts; search stays on its configured endpoint |
| `EngineDoctorRuntime.swift` | Frozen repair admission, cancellation, rechecks and obligations |
| `EngineDreams.swift` | Manual and scheduled dreams share one matter and delivery receipt; previews commit nothing |
| `EngineFrontSense.swift` | Bounded stable-front perception with presence, policy and provenance gates |
| `EngineHome.swift` | Registers Home's retained world lifetime and binds the agent's door and row actions to the shared page owner |
| `EngineInbox.swift` | Root-specific ForPerson inbox reading, face-change subscription lifetime and checked trigger publication |
| `EngineIntentionMigration.swift` | Locked one-time conversion of scheduled work into Desk intentions |
| `EngineLaunch.swift` | `NativeAgentEngine`; Ordered bring-up, ingress and bounded retained settlement |
| `EngineMacIntegration.swift` | `MacIntegrationFacade`, `LatestRead`; Shared checked grants and watch readiness |
| `EngineMaintenanceParts.swift` | Effect-free authored maintenance words, deadlines and trigger choices |
| `EngineMemory.swift` | `refreshStatuses`, `proposals(status:)`, `graphSnapshot`, `ProposalRecord`; Canonical memory projections |
| `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`; Authenticated native response admission |
| `EnginePages.swift` | The native pages registered on `engine.pages`: each page's read (its face and the record position or moment it read) and its row actions |
| `EnginePartWake.swift` | `EnginePartWake`, `start`, `deliver`, `run`, `readsOnly`, `reindex`, `held`, `resumed`, `holdBack`, `tainted_signal`, `changed`, `changed_more`, `person.away`, `person.here`, `network.down`, `network.up`, `AgentOpened` |
| `EnginePersona.swift` | Checked profile and document publication with independent save/read outcomes |
| `EngineProviderHelpers.swift` | Checked account contracts, inheritance and committed routing publication |
| `EngineProviders+Adoption.swift` | Transactional Chat adoption preserving intentional overrides and pending edits |
| `EngineProviders+Probe.swift` | `ProvidersFacade`, `clearProvider`; Native probes and matched credential verification |
| `EngineProviders.swift` | One checked root-specific settings/catalog owner across surfaces |
| `EngineRouteError.swift` | Plain failure remedies and full-width POSIX error interpretation |
| `EngineScheduledWork.swift` | Canonical job deadlines and gated reads; the due-job owner tells scheduled matters |
| `EngineSenses.swift` | `LatestRead`, `write`; Checked source state and owner-driven visible refresh |
| `EngineSessionDelivery.swift` | Bound-route reply delivery through canonical transcript and transport journals |
| `EngineSync.swift` | `SyncFacade`, `LatestRead`; Checked pairing and owed key publication |
| `EngineTelegram+Commands.swift` | Checked token/configuration mutations and diagnostic receipts |
| `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |
| `EngineTelegram.swift` | `TelegramFacade.loadStatus`, `load`, `refresh`, `LatestRead`; Checked transport and diagnostic publication |
| `EngineTools+CapabilityActions.swift` | Mac actions and browser previews use canonical routes and publish their cached state |
| `EngineTools.swift` | `PartDoor`, `withPartDoor`; Explicit turn, host and originating gated chain for native part calls |
| `EngineTrust.swift` | Checked policy, audit and capability publication through canonical mutation owners |
| `EngineTrustFace+Actions.swift` | Trust row answers through existing person setters or the agent's Turn's setting.set checks |
| `EngineTrustFace+Readings.swift` | Trust's security, system grants, watches and activity readings with source failures |
| `EngineTrustFace.swift` | Trust's face over checked policy, grants, peers, receipts, privacy and backups |
| `EngineTurnContinuation.swift` | `TurnContinuationRuntime`; Shared admission and reply settlement |
| `EngineTurns.swift` | Canonical turn/Stop presentation and independent read-only pane publication |
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletRun`, `GauntletCheck`; Stored promotion evidence |
| `InboxFace.swift` | Inbox's one face reads ForPerson's matters and change stream; person actions use existing owners and agent actions retain the invoking turn's inbox admission |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `TurnsFacade.receiveScreenPreview` publishes the runtime's transient preview vocabulary |
| `MacChatTurnExecution.swift` | `NativeAgentEngine`, `TurnsFacade.runtime`, `ChatTurnToolPlacement`; Ordered stream settlement |
| `MacIntegrationDeliveryActions.swift` | Rooted integration execution with native evidence and shared notification delivery |
| `MemoriesFace.swift` | Memories face and actions over canonical MemoryFacade reads and writes |
| `MemoriesFaceText.swift` | Memory face wording, ordering and exact row-link destinations |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for EngineRuntime diagnostics |
| `MountedTranscriptRefresh.swift` | Mounted conversations read the store when it publishes; no turn refreshes a view |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`; Capture location before queue admission |
| `NativeAgentEngine.swift` | Root composition; Chrome refusals tell ForPerson and Activity follows its changes |
| `NativeAgentEnginePorts.swift` | Native host factories and read faces; cognition's shoulder tap tells its conversation matter |
| `NativeAgentResidentRefresh.swift` | `NativeAgentEngine`; Defer mind/context reload until admitted turns settle |
| `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |
| `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |
| `PersonalityFace+Minds.swift` | Checked Memory and mind choices; the existing provider group transaction owns saves |
| `PersonalityFace.swift` | Personality's one face: checked identity, authored document previews, becoming, dreams and proposal destinations |
| `PresentationFaces.swift` | Root-scoped PresentationFaces feeds L0's pure presentation-copy.js cache from frozen inputs outside rendering |
| `PresentationValues.swift` | Shared health and capability presentation values, shared formatter alias and display-string truncation |
| `ProviderChoices.swift` | Provider catalogs and shared descriptor, auth and reasoning conversion |
| `ProvidersFace+Actions.swift` | Providers rows use group transactions, provider operations and the credential card |
| `ProvidersFace.swift` | ProvidersFacade reads the Providers face from its checked in-memory settings and publishes at owner writes |
| `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`, `LatestRead`; Checked saved configuration |
| `RuntimeReadProjection+Feeds.swift` | Checked owner-backed guidance, history, approval counts and bounded evidence tails |
| `RuntimeReadProjection+QuietPages.swift` | Shared semantic pages; permission-card pointers read ForPerson's in-memory inbox |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadError`: unreadable feed detail shared by checked runtime readers |
| `RuntimeReadProjection.swift` | Checked activity and observed context usage; unknown measurements stay unavailable |
| `RuntimeSummaryModels.swift` | `KernelGuardrail`, `ApprovalClass`, `AutonomyKernelSummary`; Policy-only summaries |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SelfImprovement+TrainingReads.swift` | `HarnessBenchmarkRun`, `HarnessBenchmarkCheck`, `evals/runs.json`, `harness/benchmark/runs.jsonl` |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SettingsFace+Status.swift` | Settings runtime evidence and remedies read cognition, Trust, Mac permissions and memory owners |
| `SettingsFace.swift` | Settings face reads the registry; person controls use its owner setters, agent controls retain setting.set admission |
| `SettingsInnerLifeStatus.swift` | Settings inner-life runtime status and its provider, model or reapply remedy |
| `SurfaceRuntimeStatusModels.swift` | Approval-backed pending status and browser recovery availability |
| `TelegramEvidence.swift` | Transport health, checked diagnostics and native receipts |
| `ToolReceipts.swift` | Frozen tool facts, shared status and exact successful persona-write receipts |
| `TranscriptReading.swift` | TranscriptsFacade canonical file/index reads, retention and one-revision card/attachment preparation |
| `TranscriptReadout.swift` | Transcript/card structures, page-bounded inline mounts and structural message grouping |
| `TranscriptRowFace+Mac.swift` | The Mac's one reading of a transcript row into its face (seat, tag, bridge line, tool line and outcome, persona receipt, owed decision), for its own chat and for the phone's |
| `TranscriptSessionMutations.swift` | Canonical session creation, archive and generation-checked clearing |
| `TranscriptsFacade.swift` | Root-scoped transcript publication and consumer-held live tail boxes |
| `TrustFaceGuardrails.swift` | Policy-derived guardrail rows used by Trust’s shared face |
| `TurnCardReadout.swift` | `MacChatTurnCardModel`, `TurnCardReadout`, `MacChatTurnCardFormat`; Derived lifecycle presentation |
| `WorkOverviewRead+Today.swift` | Frozen Today sources at the experience record's sequence; engine.pages projects today-readout.js |
| `WorkOverviewRead.swift` | `WorkOverviewRead`, `project`, `row`, `text`; owner attention and the agent's jobs at work |
| `WorkStatusPublication.swift` | Coalesced board publication for attention and widget; unknown identity withholds its name |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/ !Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift !Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: exact Mail effects and reply evidence |
| `MacAppleScriptBridge+MailAppleEvents.swift` | `MacAppleScriptBridge`: checked mailbox identity and metadata |
| `MacAppleScriptBridge+MailIndex.swift` | `MacAppleScriptBridge`: account coverage and read-only mailbox pages |
| `MacAppleScriptBridge+MailMessageBytes.swift` | `MacAppleScriptBridge`: identity-bound bytes and attachments |
| `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: checked scope and local-byte reads |
| `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: exact messages and Notes effects with read gaps |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`, `runAppleScript`, `deniedEnvelope`, `Resources/abilities/music-library.js`, `music.js`, `Parts.call`, `now_playing`: shared script envelopes and Music parts |
| `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in AppleScriptExecution |
| `MacAssistantStatus.swift` | `Resources/abilities/mac-watch-catalog.js`: Checked readiness and catalog data; never creates jobs |
| `MacContactsExecutor.swift` | `CNContactStore`: checked Contacts reads and labeled mutations |
| `MacLocationReader.swift` | bounded fixes and caller-owned cancellation |
| `MacMessagesHistory.swift` | bounded SQLite history and folded matching |
| `MacMessagesTypedString.swift` | bounded attributed-body archive decoding |
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

Keyboard grammar, pointer ownership, input emission, AX actions, approval
evidence, Apple events, process execution, app navigation, file access,
screen readiness and protected paths are filed by nature. Image geometry,
visual objects, watch capture, frame questions and hands retain their type owners.
Dispatch and the operation store retain execution and effect-lifetime ownership.

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
| `MacAppIndex.swift` | Resident Spotlight snapshots retain row/directory gaps; bounded async gather never stops the query |
| `MacAppMaps.swift` | `MacAppMapStore`: Verified control maps; scoped press evidence; checked reads/flushes |
| `MacAppNavigation.swift` | `MacApplications`, `AppControlRunResult`, `OpenTarget`: Checked app identity; bounded launch waits |
| `MacAppSourceEvents.swift` | Event-backed AX coverage retains gaps; complete traversal prunes; bounded content-stall signals |
| `MacAppWindowText.swift` | `MacAppWindowText`: On-device window OCR; retain only redacted text/positions |
| `MacAppleEvents.swift` | Native OSA: per-event target/Write checks, bounded replies, playback settlement and volume recipe |
| `MacAttention.swift` | `MacAttentionSessionStore`, `MacDriverBinding`: Driver takeover, view continuity and held-input settlement |
| `MacAttentionEvents.swift` | Passive input/scene events retain provenance; coalescing never delays synchronous takeover |
| `MacAttentionObservation.swift` | Bounded attention readout and observation continuity |
| `MacBackgroundSight.swift` | `MacBackgroundSight.resolve`: Exact identities precede partial names; preserve ambiguity and source failures |
| `MacChromiumAccessibility.swift` | Bundle-based renderer identity; shared bounded AX activation retains failures and passive authority |
| `MacClipboard.swift` | `MacClipboardRead`: Permission-bound pasteboard reads/writes; bounded redacted text and type metadata |
| `MacControl+Client.swift` | `SwiftNativeMacControl`, `dispatch`, `dispatchApprovedInjection`, `MacObservationMode` |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl.handleAct`: Same-window live identity and per-step declared effects |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: Bounded editor focus and gestures; per-event image/window guards |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`, `handleMenu`, `handleMenuPress`, `handleClipboardRead` |
| `MacControl+OperationSupport.swift` | Bounded response waits retain actual-exit ownership, produced output and unknown effects |
| `MacControl+Perception.swift` | Checked shallow menus retain availability/coverage for native pages and windowless apps |
| `MacControl+SystemActions.swift` | Lossless file windows, checked mutations, scoped Spotlight, exact media and per-event app scripts |
| `MacControl+TextEditing.swift` | `SwiftNativeMacControl.typeText`: One selected writer; checked focus/selection; no substitution |
| `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |
| `MacControlActionRoutes.swift` | Canonical MacControlResult dispatch receipts plus workbench availability and category policy |
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
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `webURL`; landing targets the recipient returned by Launch Services |
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
| `MacPointer.swift` | `MacMouseEvent`, `MacScrollEvent`, `AgentPointerHold`: Bounded pointer ownership restores the person's cursor |
| `MacPointerObservation.swift` | `MacPointerPosition`, `MacRegionAim`: Actual cursor and clear-region aim; unknown never invents origin |
| `MacProcessExecution.swift` | `ProcessExecution`, `ProcessRunResult`, `ProcessRunCancellation`, `ProcessRunIOFailure`: Process lifecycle |
| `MacProtectedPaths.swift` | `MacControlSensitivePathFence`: Protect data, OS/store mutation and parent paths without widening read fences |
| `MacSavePanelPlacement.swift` | Shared act verification requires native full-directory URL and exact basename readback |
| `MacScreenPageCompiler.swift` | Structural AX reading order, scoped alias folding, whole sentences, secret redaction and exact related actions |
| `MacScreenReadiness.swift` | `MacSessionState`, `MacWakeGuard`, `MacScreenLock.wakeIfCovered`, `SwiftNativeMacControl.handleWake`: Readiness |
| `MacScreenRender.swift` | `MacScreenText`, `MacScreenRender`: Shared semantic/pixel formatting retains compiler redaction |
| `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`, `MacScreenViewTextRedaction`, `MacImageFrames`, `MacImageCapture`: Capture |
| `MacScreenViewBuilder.swift` | View and mark construction from captured geometry and accessibility |
| `MacScreenViewCapture.swift` | `SystemMacVisualObstructionProbe`, `SystemMacScreenCaptureSource`: Exact capture, hit evidence and cancellation |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG` masks secret frames before encoding; `encodePNG` |
| `MacScreenViewResultRedaction.swift` | Persisted result previews omit image payloads |
| `MacScreenViewTextRedaction.swift` | One secret-decision owner for text, pixels and enclosing captions |
| `MacScreenWatch+Capture.swift` | `MacScreenWatch`: Exact capture with complete secret masks; inspect the newest pending frame even when static |
| `MacScreenWatch+FrameQueries.swift` | `MacScreenWatch.read`: Exact-frame pixel/text queries require current watch and secret verdicts |
| `MacScreenWatch+Hands.swift` | `MacScreenWatch.hand`: One deadline, per-event authority, exact-window input and secret drag checks |
| `MacScreenWatch.swift` | Exact-window stream; complete secret masks precede publication; bounded settlement and immediate takeover |
| `MacSemanticAct.swift` | `MacFourVerbs.actOnce`: Fresh-name transactions preserve key intent, focus typing and current-content scroll |
| `MacSemanticExecution.swift` | Shared semantic/physical execution; uncertain delivered text remains unverified with a pixel-look remedy |
| `MacSemanticObservation.swift` | Shared semantic reads and exact-node search; named stopped/windowless apps report absence without launch |
| `MacTransientMenus.swift` | Bounded near-focus menu reads retain scoped AX gaps and structure without widening window capture |
| `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |
| `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactedText`: Shared OCR caption/proximity and overlap redaction |
| `MacWaitSignals.swift` | `MacWaitSignals`: Cancellable AX/app signal waits with owned observer lifetimes |
| `MacWindowActivation.swift` | `SystemMacAXActSource`: Driver-checked raise and measured activation; app-only routes avoid self-AX |
| `MacWorkContinuation.swift` | One request's bounded native takeover continuation |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MacControl diagnostics |
| `PersonPresence.swift` | One Mac/phone presence; phone departure arms physical return, missing evidence stays unknown |
| `SystemMacAXActSource.swift` | Main-lane AX, CF-equal identity and scoped read gaps; actual target-pid Write and driver gates precede mutation |
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
| `AdaptiveMemoryFacts.swift` | shared interpretation, deferred judgment and durable fact/fold settlement |
| `AdaptiveMemoryPromises.swift` | `AdaptiveMemoryPromoter.applyPromises`: reply-grounded promises under recorded turn authority |
| `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: bounded owed-turn recovery with recorded provenance |
| `AdaptiveMemoryValues.swift` | Adaptive candidates, extraction evidence, observation and shared hygiene vocabulary |
| `AfterTurnMemorySurprise.swift` | `AfterTurnMemorySurprise`: complete-no-op prediction under learned standing |
| `AfterTurnSurpriseLedger.swift` | `AfterTurnSurpriseLedger`, `Expectation`: labelled predictions and measured cost standing |
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
| `MemoryDataProvenance.swift` | `MemoryDataProvenance` stamps evidence; `MemoryWriteContext` holds the turn and sense-read owner |
| `MemoryEmbeddingEpoch.swift` | vector-space identity, item outcomes and owned convergence |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring`: candidate bounds, decay and explicit kinds |
| `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: record privacy independent of tool admission |
| `MemorySenseProvenance.swift` | `MemorySenseProvenance`, `MemoryStorage.markVersionWrong`: warnings and sense-version metadata |
| `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery (the journal's owed turns) wire models |
| `MemoryStatusProjection.swift` | `MemoryV2NativeStackSnapshot`: memory and embedding health, recent misses |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+Comparison.swift` | `MemoryStorage`: comparison keys, scope, epochs and polarity |
| `MemoryStorage+Corrections.swift` | `MemoryStorage`: idempotent canonical correction occurrences |
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
| `MemoryV2+MemoryManager.swift` | `MemoryManagerLane`, `MemoryManagerPromise`: grounded decisions, reviewed targets and promises |
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
| `ContextSecretContentPolicy.swift` | Shared credential redaction and nested URL decoding |
| `DerivedStateInvalidation.swift` | `DerivedStateInvalidationCenter`: writes wake derived readers |
| `Expectation.swift` | `Expectation`: confidence and measured-cost admission |
| `LLMCall.swift` | `LLMCall`: explicit call identity and request shape shared by all `LLMClient` methods |
| `LLMClient.swift` | `LLMClient`, `LLMToolSchema`: completion, streams and local tool effect declarations |
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `LifecyclePrimitives.swift` | `ScopedWaiter`, `OnceByKey`, `BoundedWait`: parking, keyed once and bounded waits |
| `MacIntegrationAccess.swift` | `MacIntegrationAccess`, `MacIntegrationPermissionMode`: a tool's declared integration and axis |
| `ManagedProcess.swift` | `ManagedProcess`, `OwnedProcessGroup`: checked process groups and settlement |
| `MemoryDisplayText.swift` | `MemoryDisplayText`: prompt rendering and coverage keys |
| `MotorActionReadModel.swift` | `MotorActionReadModel`: progress projection; domain authority stays native |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | checked process-cached current app stamps; incomplete identity unavailable; `writeLaunchStamp` refuses it |
| `NativeLoopbackListenerParameters.swift` | Fixed-port listeners and retained bounded diagnostics |
| `NativeTimestampFormat.swift` | Core alias to Shared's locked wire timestamp owner |
| `NetworkSense.swift` | `NetworkSense`, `isUp`, `changes`, `returns(within:)`, `changed`: one path monitor and bounded waits |
| `OrganBody.swift` | `OrganBody`: the one body projection (each organ's line and deviation), the felt-memory rule and the body read hook |
| `OrganPulse.swift` | `OrganPulse` beats and recording hook; `OrganRecord` derives profile and deviation from the record's newest beats |
| `PersonOnlyWindows.swift` | `PersonOnlyWindows`: capture exclusion and input coordination |
| `ProcessTreeReaper.swift` | `ProcessTreeReaper`, `OwnedProcessGroup`: identity-bound process evidence |
| `ProviderCallEvidence.swift` | Provider lifecycle evidence and learned first-output deadlines |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `REMReplacement.swift` | Source-bound displaced REM content and shared review wording; missing history is not recorded |
| `RecallLexicalNormalization.swift` | `characterEditDistance`, `RecallLexicalNormalization`: shared retrieval normalization |
| `SSEEventStream.swift` | `ProviderRequestLifetime`, `ProviderStreamContext`: explicit SSE activity and trace-only event capture |
| `Settle.swift` | `settle`: the Stop law's one primitive; settlement runs outside the caller's cancellation, exactly once (docs/STOP.md) |
| `TimeoutRace.swift` | `raceAgainstTimeout`, `ContinuationOnce`: first-wins deadline and cancellation |
| `ToolFailureAndEffects.swift` | Owner-supplied failures, remedies and declared effects |
| `Turn.swift` | `Turn`: one identity handed to everything serving it; `TurnPart` keys each owner's state |
| `TurnDeadline.swift` | `OperationDeadlines`, `TurnDeadline`, `TurnBodyLifetime`: work ceilings and owned settlement |
| `TurnPresentation.swift` | `TurnPresentationReducer`: bounded lifecycle evidence without payloads |
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
| `AbilityStore.swift` | `signalled`, `wakes`, `recordRounds`, `replayed`, `tape_replay`; sealed lifecycle, state and notebooks |
| `PartCall.swift` | Shared part/face wire contracts; editable content cannot forge status |
| `PartFaces.swift` | `PartFaces`, `PartFaceSnapshot`; source-owned face projections (the agent's JS parts and native pages) published through LatestRead, and the one port a row's action returns through |
| `Parts.swift` | `storedRows`, `rows`; One part reader; display projections never write back; row-local name damage |
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
| `FileLockSidecarLifecycle.swift` | `FileLockSidecarLifecycle`; Reap only old locked orphan sidecars. |
| `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |
| `InstallPaths.swift` | Install-owned ports, bridge paths and Chrome relay identity. |
| `JSONLRetention.swift` | Path-owned envelope, capped append and retention cadence. |
| `JSONRow.swift` | `JSONRow` checked stored-object reads; required/optional typed fields and named malformed-row errors |
| `JSONSchema.swift` | `JSONValue.SchemaProblem`, `validate`, `schemaProblem`, `ToolSchema`; Validate complete schemas. |
| `JSONValue+Accessors.swift` | Explicit numeric coercion and unknown-field handling. |
| `JSONValue.swift` | `JSONValue`, `decodeCompletion`, `fromEncodable`, `mapStrings`, `decodedExactly`, `digest`, `differences` |
| `Keyring.swift` | `Keyring`, `kept`, `{{secret:<name>}}`; Secret storage and grant identity only. |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for PersistenceCore diagnostics |
| `NativeActionRouteSupport.swift` | `NativeActionWire` enum; `jsonValueBody`, `notImplemented` |
| `NativeAgentWorkspaceRoot.swift` | Byte-exact containment and entry identity; callers own admission. |
| `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |
| `NotificationChannelPreference.swift` | Shared delivery-admission preferences. |
| `NotificationDeliveryOutcome.swift` | A transport's classified verdict for one door; the door's `deliver:` obligation records it |
| `OncePerPeriodReservation.swift` | `OncePerPeriodReservation`; Locked durable periodic admission. |
| `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock`; Bounded inode-checked locks. |
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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Experiences/ -->
| File | Owns |
|---|---|
| `Detail.swift` | `ExperienceStore` detail grain: what the body noticed while a happening ran (a turn's steps, power draws, consent answers, organ beats), one ordered `detail` table in the same store, read by subject, kind and time, forgotten after `detailHorizon` |
| `Experience.swift` | `ExperienceStore`, the append-only owner per data root over `experiences/experiences.sqlite`; `begin`, `append`, `experience`, `open`, indexed open/recent `projection` and commit-fed `changes`. Shared `Experience`/`ObligationPhase` live in NativeAgentShared. Recording stays off reply paths; projection drains queued writes and reports persistence gaps; a write the law refuses is logged and never poisons reads. Turn owners record answer lifetimes and recover saved-answer settlements; conversation and shelf owners publish peer obligations and completed run identities |
| `Flow.swift` | `Flow`. |
| `ForPerson.swift` | `Matter`, `Door`, `ForPerson`: what is for the person is the experiences addressed to `person`, held in memory (loaded once, fed at write); the person's reading, door deliveries and the inbox wire are readings of them |
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
| `ModelCatalogTTLCache.swift` | `ModelCatalogDecodeCache`: credential-bound cache; ordered publication |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ProviderRouting diagnostics |
| `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model discovery |
| `NativeOAuthCallbackPolicy.swift` | exact callback state |
| `NativeOAuthCallbackRegistry.swift` | `PendingCallbacks` class; `register`, `forget` |
| `NativeOAuthFlow+Configs.swift` | ProviderOAuthConfig owns provider client identities and token endpoints; buildAuthURL, exchangeCode |
| `NativeOAuthFlow+Helpers.swift` | redirect-refusing bounded grants; checked token replies |
| `NativeOAuthFlow+Keyring.swift` | `Keyring`, `granted`, `grant`, `forget`, `values`, `NativeOAuthFlow`, `grantSecret` |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackPageMessage` |
| `NativeOAuthFlow+TokenStatus.swift` | adapter-owned sign-in verdicts |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | `NativeOAuthFlow`, `validateSignInDestination`, `startOAuthFlow`: checked sign-in ownership |
| `NativeOAuthLoopbackCallbackServer.swift` | one bounded wait; blocking I/O on Dispatch |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort`, `runAuthSession`, `isCanceledLogin`, `makeLoopbackSession`, `openBrowser`, `runLoopbackAuthSession` |
| `OAuthCredentialDecoding.swift` | Shared JWT payload and OAuth expiry decoding; `OAuthRefreshBinding`: account identity and refresh continuity |
| `OAuthCredentialHealth.swift` | Secret-free maintenance projection of adapter-owned expiry, refresh binding and readiness verdicts |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` (per credential path or key) |
| `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: route-owned controls |
| `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed membership and controls |
| `ProviderAPIKeyStore.swift` | Provider reference/string validation; byte insertion, readback and deletion delegate to DeviceSecretKeychain |
| `ProviderConfiguration.swift` | Byte-checked provider configuration decode under the writer's lock with fresh credential/readiness facts |
| `ProviderConnectionProbe.swift` | Native probe capabilities and request-bound OAuth credential evidence; API-key connection probes |
| `ProviderErrorBodyDrain.swift` | `ProviderErrorBodyDrain`: bounded request-owned diagnostics |
| `ProviderFailure.swift` | `Diagnostic`, `ToolFailureError`, `repair`: typed failure and repair ownership |
| `ProviderOAuthAdmission.swift` | Observed OAuth credential admission and expiry interpretation |
| `ProviderReadiness.swift` | exact credential/catalog readiness |
| `ProviderReasoningSelection.swift` | Preserves an explicit effort or the row's declared default; capability admission belongs to routing |
| `ProviderRecoveryPolicy.swift` | `ProviderWire`: typed verdicts; wire-owned redelivery |
| `ProviderReplyWork.swift` | stop joins transport exit and drain |
| `ProviderRouteDerivation.swift` | one snapshot; catalog faults stay route-local |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting`, `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `adoptConnectedProvider`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting` |
| `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot`, `TurnRouteAdmission`, `SwiftNativeProviderRouting` |
| `ProviderRoutingValues.swift` | checked scalar vocabulary; no inferred controls |
| `ProviderSelection.swift` | recoverable forward picker transactions |
| `ProviderSignInHandoff.swift` | provider sign-in handoff state |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderStreamGuard.swift` | `ProviderWire`: bounded pre-answer redelivery; wire-owned clocks |
| `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared wire grammar |
| `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |
| `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive bounded lifecycle evidence |
| `RequestPrefixReceipt.swift` | `RequestPrefixReceipt`: hash exact bytes without retaining prompt text |
| `RunawayOutputDetector.swift` | `RunawayOutputDetector`: complete-call retention and redacted cuts |
| `Turn+Provider.swift` | `Turn` part ProviderRouting owns: the per-turn provider/model choice |
| `XAIOAuthCredentialStore.swift` | Locked xAI token storage, immutable Keychain references, refresh reads and sign-out cleanup |
<!-- END GENERATED BLUEPRINT -->

### Research

Directory: `Modules/NativeAgentCore/Sources/Research/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Research/ -->
| File | Owns |
|---|---|
| `BoundedResearchDownload.swift` | `BoundedResearchDownload`: bound bytes before appending |
| `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |
| `Research+Autodetect.swift` | Checked setup discovery; candidate gaps stay local |
| `Research+Helpers.swift` | Checked receipt retention preserves completed fetches |
| `Research+Lab.swift` | `SwiftNativeResearchClient`: authored briefs; native evidence and receipts |
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
| `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |
| `SchedulerDueJobRunner+CycleHelpers.swift` | Cycle wording and diary identities read from matter artifacts |
| `SchedulerDueJobRunner+DreamCommands.swift` | canonical recurring-dream command selection and job receipts |
| `SchedulerDueJobRunner+Execution.swift` | Shared dream matters and REM receipts; due jobs consume the same recorded result |
| `SchedulerDueJobRunner+Persistence.swift` | Activity evidence, one scheduled tell, and in-memory dream receipt readings |
| `SchedulerDueJobRunner+ProactiveScan.swift` | Proactive matters refer to their source experiences |
| `SchedulerDueJobRunner+Selection.swift` | Canonical cycles and one backfilled dream matter from observed diary files |
| `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`, `jobTimeoutSeconds`, `executeWithTimeout` |
| `SchedulerDueJobRunner.swift` | Canonical rhythm claims and settlement; reconciliation tells one matter |
| `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `read` (a scheduled read through the app door) |
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
| `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; socket/recovery admission, retains accepted handler tasks until actual exit with one active handler per event in the process (across loop replacements), and terminal delivery truth; `recordPreview` retains live message identity and uncertain creation, `path`, `recoverySummary`, `failedReplyClaims`, `confirmReplyPart` retain confirmed text/image progress across holds; malformed canonical bytes remain in place and throw; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `SlackNotificationDelivery.swift` | `SlackWebAPI.notificationOutcome`: checked preflight, API refusal and uncertain dispatch |
| `SlackReplyPreview.swift` | `SlackReplyPreview`: latest-value publication joins admitted sends before final delivery |
| `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | TransportAllowlist's canonical Slack policy; throwing ingress and toggle readers retain unavailable authority |
| `SlackSocketModeLoop+Answers.swift` | `SlackSocketModeLoop`: durable replies, live publication, reconciliation and settings settlement |
| `SlackSocketModeLoop+Evidence.swift` | `SlackSocketModeLoop`: bounded, redacted diagnostics and envelope evidence |
| `SlackSocketModeLoop+Media.swift` | `SlackSocketModeLoop`: inbound files, bounded image hydration and upload selection |
| `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: fatal disconnects outrank recycling |
| `SlackSocketModeLoop+SessionDelivery.swift` | Journal previews; final recovery joins the preview writer before updating its message |
| `SlackSocketModeLoop+WebAPI.swift` | `SlackSocketModeLoop.slackAPI`: checked reads for accepted-reply reconciliation |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop`, `tick`, `tickOutcome`: socket lifetime independent of accepted handlers |
| `SlackSocketModeSupport.swift` | `SlackHandlingCompletion` retains deferred settings work through reply settlement; checked socket errors |
| `SlackTurnContracts.swift` | `SlackInboundFile` struct |
| `SlackTurnIngress.swift` | Configured Slack ingress shares persona selection, profiled chat and allowlist authority |
| `SlackWebAPI.swift` | `requireConfiguredToken`; checked HTTP replies, uploads and reconciliation with ConnectorActionReceipt proofs |
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
| `BotRunnerDeadline.swift` | Report helper deadlines without cancelling work; scheduled runs and conversations share settlement |
| `BotRunnerScheduler.swift` | `BotRunnerScheduler` actor; `effectiveSchedule` shares reconciled timing and admission with live deadlines |
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
Each preview reads its own title face. Terminal shutdown closes future starts;
cancelled reads never publish or rearm the retired shelf.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Studio/ -->
| File | Owns |
|---|---|
| `MakeStudio.swift` | Root-scoped artifact metadata, native decoding, durable version allocation and previews; generated-image registration is editable `Resources/abilities/make-generated.js`, composing native raw generation results with `make.add` (prompt/model metadata retained); `MakeRegistration` explicitly carries native generation receipt paths to that registration call, and the registration primitive admits those verified app outputs while arbitrary files retain the workspace fence; `MakeStudio.Shelf` owns watcher/coalescing lifetime and publishes its read results through `LatestRead`; each preview file/revision owns L0 `PartFaces` for editable `Resources/abilities/make-title.js` (HTML title → prompt → filename); native unavailable/failed status accompanies the face, views only read their preview's snapshots; shutdown drains projections and cancellation never rearms a retired shelf |
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
| `TelegramApprovalHandling.swift` | `TelegramApprovalHandling`: addressed approval resolution |
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
| `TelegramModelSelection.swift` | Use checked account-scoped catalogs; retain each provider's cause and declared capabilities |
| `TelegramModelSelectionHandling.swift` | `TelegramModelSelectionCallback`: checked callback identities |
| `TelegramNotificationDelivery.swift` | `TelegramPollLoop.notificationOutcome`: accept only complete chunked sends |
| `TelegramOffsetCursor.swift` | `TelegramOffsetCursor`: monotonic; only missing state bootstraps |
| `TelegramPartPolicy.swift` | Parts draw checked choices; native code owns callback admission and routing writes |
| `TelegramPollBackoff.swift` | `TelegramExponentialBackoff`, `TelegramErrorLog`: bounded locked rotation |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`: shared approval ownership; session journal delivers replies |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`, `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`, `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand` |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `chatAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+SessionDelivery.swift` | Resolve bound destinations and join previews before journal recovery |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: sole checked state.json reader and mutation owner (`readState`, `mutateState`) for polling and status consumers; only missing state is empty, and unreadable/non-object state fails with a dedicated telegram/state.json error and is never overwritten; bot ingress validates its current identity without global-storage migration; `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |
| `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody`, `defaultEditRichMessage` edits retained group replies; photo transport carries the reply's silent notification policy |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramPollLoop.swift` | `TelegramPollLoop`: durable admission; owned media preparation and recovery |
| `TelegramProgressFace.swift` | Per-card epoch and LatestRead cache over redacted facts; parts author progress words |
| `TelegramRestart.swift` | Only the owner may restart; defer termination until the reply attempt |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramSessionStore.swift` | `TelegramSessionStore`: locked mint/adoption; shared anchor selects owner DM |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger`, `upsert`, `remove`, `TelegramTurnCardRestartRepairer` |
| `TelegramTurnControls.swift` | `TelegramTurnControlCallback`: active-turn control markup and callback decoding retaining forum-topic identity |
| `TelegramTurnCoordinator.swift` | `TelegramTurns`: retain ownership through receipt and ingress settlement |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase`: canonical lifecycle semantics |
| `TelegramTurnProgressCardDriver.swift` | `TelegramTurnProgressCardDriver`: persist terminal identity before release |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox`, `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`: life-bound recovery |
| `TelegramVoiceTranscription.swift` | Convert declared containers once; join recognition and temp cleanup on Stop and deadline |
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
| `ChatSessionScratch.swift` | `ChatSessionScratch`: Locked scratch state; off-disk backup only |
| `ConversationAnchor.swift` | `ConversationAnchor`, `mayAnchor`: Direct-user anchor; unknown protection holds retention |
| `ConversationHistory.swift` | Exchange pairing, transcript provenance and dream consumption marks |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Transcripts diagnostics |
| `SessionConversation.swift` | `SessionConversation`: Row-backed kind and stamped index reads |
| `TranscriptRowStamp.swift` | Verified speaker and steering stamps; imports attest none |
| `TranscriptRows.swift` | `ContactThread`, `read`, `Line`, `project`, `consume`, `DelegatedReplyEnvelope`: Locked transcripts; shared display |
<!-- END GENERATED BLUEPRINT -->

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TriggerScheduler/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TriggerScheduler diagnostics |
| `MorningBriefAssembly.swift` | Authored brief cards and inactive schedule defaults |
| `MorningBriefPart.swift` | Door-bound brief proposals; native claims and publication |
| `MorningBriefSources.swift` | Checked brief sources; unread notes read ForPerson's in-memory inbox |
| `ScheduledJob.swift` | `ScheduledJob`: strict scheduler row decoding and projected civil next-run decoration while preserving claimed instants |
| `SchedulerJobNormalizer.swift` | Strict job admission shared by creation, updates and execution |
| `SchedulerJobOccurrences.swift` | Life-stamped occurrence claims, settlement and pruning |
| `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: Civil timing prevents duplicate occurrences across zones |
| `SchedulerJobs.swift` | Locked job storage, stopped conversion evidence and read-only watches |
| `SchedulerRecurrence.swift` | Shared recurrence, civil-minute and intention timing grammar |
| `SchedulerRestoreFences.swift` | Restore selected definitions with current occurrence facts |
| `TriggerInboxPublication.swift` | Locked inbox acceptance before delivery and receipts |
| `TriggerNotificationInbox.swift` | Trigger acceptance tells one matter with its doors; duplicates and superseded briefs read ForPerson |
| `TriggerOccurrences.swift` | Locked trigger claims, repair, deadlines and checked reads |
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
| `CapabilityCatalog.swift` | Read-only checked sources/roots; writes validate identity under lock. |
| `CapabilityRecords+Dynamic.swift` | Owner-derived capability rows preserve missing evidence. |
| `CapabilityTrust.swift` | `SwiftNativeCapabilityTrust`: checked capability trust/catalog values, scoring, evaluation and display projections |
| `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor`, `connectorActionDescriptors`; Static schemas. |
| `ConversationSurfaceProfile.swift` | `ConversationSurfaceProfile`; One security-relevant surface identity. |
| `FeatureSurfaceRecords.swift` | `FeatureSurfaceRecord`, `featureSurfaceRecords`; Manifest reach. |
| `MacControlGate.swift` | `MacControlGate`; Origin-aware Full Mac and resolved-path policy. |
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Untrusted peer effects ask; memory retains provenance. |
| `SavedWorkflows.swift` | `SavedWorkflows`, `WorkflowStep`, `WorkflowRecord`; Checked read-only templates. |
| `SecurityCenter+FullMacPolicy.swift` | Origin-aware Full Mac admission and driven-agent launch ceilings |
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
| `TrustPolicy.swift` | UI subset cannot replace raw checked authority. |
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
| `TurnInspectorFeed.swift` | `LatestRead`: Checked evidence via `LatestRead`; shared Mac/phone grouping |
| `TurnInspectorPresentation.swift` | Shared Inspector rows and bounded redacted details |
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
| `PartHost.swift` | `Parts.rehearse`, `ToolHost`: gated host; previews suppress effects |
| `Parts+BundledSeed.swift` | Parts bundled seed admission from the shipped current part contract |
| `Parts+CallValidation.swift` | static call-fit against current declarations |
| `Parts+Creation.swift` | checked save/rehearsal; ratcheted provenance |
| `Parts+Execution.swift` | pinned calls and pure faces; exact run admission |
| `Parts+HTTPWire.swift` | HTTP request and bounded response wire conversion for the existing resource broker |
| `Parts+Keeping.swift` | sealed keep decisions and owner-off authority |
| `Parts+Reading.swift` | shared checked inventory and latest-version reads |
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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentShared/ -->
| File | Owns |
|---|---|
| `Package.swift` | Shared package manifest: Mac/iPhone library target, platform floors and shared source dependencies |
<!-- END GENERATED BLUEPRINT -->

### NativeAgentShared

Directory: `Modules/NativeAgentShared/Sources/NativeAgentShared/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentShared/Sources/NativeAgentShared/ -->
| File | Owns |
|---|---|
| `ApprovalRequest.swift` | Mac-owned consent, execution evidence and exact chat provenance |
| `BridgeMessage.swift` | `BridgeMessage`: signed device envelope, exact reply correlation and inner HMAC |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`, `typeAndMime`, `fileByteLimit`, `submittingSpeech` |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableParser`: pure prose segmentation and alignment/cell parsing of transcript tables |
| `ChatPacedReveal.swift` | `ChatStreamPacer`: paragraph reveal, fade and settle shared by Mac/phone |
| `ChatRichContentParser.swift` | `ChatRichContentParser`: checked grammar; `ChatContentCache`: bounded FIFO |
| `CloudKitDeviceTransport+Messages.swift` | Signed sends, exact replay proof and serialized two-family drains |
| `CloudKitDeviceTransport+PairingStatus.swift` | Account-slot claims, pairing, presence and serialized status delivery |
| `CloudKitDeviceTransport+Pull.swift` | Paginated record pulls with call-local traversal cursors up to the durable server-date watermark |
| `CloudKitDeviceTransport+Retention.swift` | Bounded oldest-page record retention; subsequent sweeps advance through confirmed deletions |
| `CloudKitDeviceTransport+Subscriptions.swift` | Visible alerts, silent chat/results and exact registration proof |
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport`: checked account, push and cursor ownership |
| `ColorHex.swift` | `NativeAgentSpacing`, `NativeAgentRadius`, `HazeColor`, `HazeMood`, `Color.init(hex:)`: shared values |
| `CompactDurationFormatter.swift` | `CompactDurationFormatter.string`: shared rounded compact duration wording with finite/range admission |
| `ContinuationOnce.swift` | `ContinuationOnce`: first outcome wins; typed Stop/deadline waits preserve writes |
| `ConversationModels.swift` | `ChatThreadKind`, shared transcript codecs, attachments and Mac-owned navigation |
| `DetachedCloudKitTimeoutRace.swift` | Detached CloudKit race and diagnostic `withCKTimeout` optional-result policy |
| `DeviceApprovalSignature.swift` | `DeviceApprovalSignature`: device identity and approval verification; outer HMAC required |
| `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |
| `DeviceEventIdentity.swift` | Stable cross-device notification/collapse identity and shared authenticated notification category construction |
| `DeviceSyncTransport.swift` | Shared role/message codecs, checked transport and signed phone contact |
| `Experience.swift` | Canonical experience and obligation lifecycle value contracts shared by domain owners |
| `FaceView.swift` | The one renderer of a page's face on the Mac and the iPhone: header, sections by style, rows with time, symbol, tone, value, actions and controls |
| `HazeView.swift` | `HazeView`: shared radial haze rig, overlap cap, weight and tempo; native geometry, lifecycle and phone tab clock |
| `ICloudBridgeConstants.swift` | Bundle-owned iCloud identity and shared wire/storage namespaces |
| `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.Mode`, `normalized`: invalid modes stay refused |
| `InboxAction.swift` | Shared signed iPhone-to-Mac inbox envelope; Codable wire schema for both transports and platforms |
| `InboxDigestGroupProjection.swift` | `InboxDigestGroups`: read-only structured inbox groups; historical prose remains text |
| `InboxWireModels.swift` | Inbox rows and `InboxActionVocabulary`: signed actions; `view` stays phone-local |
| `InlineInteraction.swift` | `InlineInteraction`: durable card/continuation contract; owners retain authority |
| `InlineInteractionDescriptor.swift` | Shared control bindings and `InlineCardField` vocabulary; no executable descriptors |
| `InspectorModels.swift` | Shared checked content-free Inspector turn summaries and mobile tool catalog rows |
| `JSONByteScanner.swift` | JSON byte spans; callers own validation and duplicate keys |
| `KnowledgeGraphEdgeWireSnapshot.swift` | `KnowledgeGraphEdgeWireSnapshot`: checked edge decoding; platforms own UI identity |
| `LatestRead.swift` | `LatestRead`, `refreshDraft`: owner-isolated reads return their result; publication advances only |
| `LeftOutWhenUnreadable.swift` | The one law for reading what a newer build wrote: a value this build cannot read is left out of what carries it |
| `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: policy projection; TrustCenter owns authority |
| `MemoryModels.swift` | Memory/proposal values preserve absence and source timestamps |
| `MobileAppSettings.swift` | `MobileAppSetting`: owner-projected settings; unavailable rows retain read failures |
| `MobileConnectorSnapshot.swift` | MobileConnectorSnapshot: credential-free connector state and available phone controls |
| `MobileDeskSnapshot.swift` | `DeskKind`, `DeskStatus`, `WorkOverview`: bounded Desk copies; no decision authority |
| `MobileHelpers.swift` | Revisioned helper edits and reading copies; explicit Fast intent |
| `MobileSchedulerSnapshot.swift` | `MobileSchedulerSnapshot` struct |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup`, `groups`: live phone snapshot input declarations |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | Closed `MobileTrustAction` requests; TrustCenter retains policy authority |
| `MobileVoicePreference.swift` | Read-only Mac voice preference carried by the core mobile snapshot |
| `MobileWorkActivity.swift` | Bounded mobile experience projection, activity DTOs and revisioned experience snapshot |
| `ModuleLogging.swift` | `ModuleLog`: shared public diagnostic formatting and credential scrubbing; `nativeLog` retains the Shared category |
| `NativeTimestampFormat.swift` | Locked wire timestamp formats and Foundation parsers; explicit precision, UTC suffixes and calendar-day zones |
| `OrganismLivingStatus.swift` | `OrganismLivingStatusFile`: read-only body status; unavailable stays explicit |
| `PartFace.swift` | Shared part results and faces; native owners supply availability and repair evidence |
| `PartFaceText.swift` | A page's face read as text for the agent's door and Telegram, and the links a row may lead to |
| `PersonaModels.swift` | Shared persona values and name validation; PersonaEngine owns identity |
| `PhoneConnection.swift` | `NAPhoneConnection`: pairing/transport/exchange assessment; `NAPhoneStanding`: connected and can-approve |
| `PhoneMacControlAction.swift` | Phone Mac-control routes with native executors; Trust admission stays separate |
| `PhonePlaceEvent.swift` | `PhonePlaceEvent`: authenticated cross-device place observations |
| `PhoneRequest.swift` | `PhoneRequest` and `PhoneRequestResult`: typed signed request/result bodies over the existing device chat lane |
| `PhoneSenseEvent.swift` | Authenticated phone observations and setup evidence; confidence never proves absence |
| `ProviderAuthStatus.swift` | `ProviderAuthStatus`: credential-proof display; providers own dispatch eligibility |
| `ProviderCatalogStatus.swift` | `NAProviderCatalogStatusCodec`: credential-free metadata over device status |
| `ProviderCatalogWireModels.swift` | Shared provider/model values and group vocabulary; callers own reasoning policy |
| `RunKindVocabulary.swift` | Safe display vocabulary for extensible run kinds; platforms own unknown symbols |
| `RunRecord.swift` | RunRecord: shared Codable run-history fields |
| `RuntimeHealth.swift` | RuntimeHealth: shared runtime liveness metadata; lifecycle facts remain with their owners |
| `ScopedWaiter.swift` | `ScopedWaiter`: one-shot parking; cancellation and deadlines release only their parker |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope`: shared seal/open wire contract for authenticated secret actions |
| `SpeechUtterance.swift` | `SpeechUtterance`: original recognition evidence and compact uncertainty |
| `StoreReloadDebouncer.swift` | `StoreReloadDebouncer`, `Timer`: one reload in flight until actual exit |
| `SurfaceLayout.swift` | `SurfaceLayout` owns the document shape, vocabulary and seed; `SurfaceLayoutAvailability` carries its checked value or `SurfaceLayoutFailure` path/detail/repair across Mac and phone, and exposes shipped content names through their shipped profiles without supplying a substitute layout. `addMissing`, `shown`, `arranged` project validated layouts; `QuietToolPage` owns shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases and door resolution (`step`, `place`, home rooms), deriving accepted part face pages from those definitions |
| `SystemToast.swift` | `SystemToast`, `SystemToastCenter`: replace-by-ID notices and owned dismissal timers |
| `TaskWaitDeadline.swift` | `OperationWaitBudget`: explicit call ceiling; producer owns settlement after timeout |
| `ToolActivityPresentation.swift` | `ToolActivityPresentation`: bounded display copy; execution stays unchanged |
| `TranscriptBuild.swift` | A conversation's face built once for every door: replies, tool runs with the agent's words, cards under their host reply, approvals where they were asked, quiet gaps, other-room rows, and each door's own physics |
| `TranscriptDocument.swift` | The conversation as one document on Mac and iPhone: blocks, attachment references, the edit between two |
| `TranscriptMarkdown.swift` | A message's markdown as document pieces (paragraphs, lists, headings, quotes, code, tables), stamped as blocks |
| `TranscriptRow.swift` | The row a conversation's face is built from, the same on the Mac and the iPhone, and its groups: tool runs, mirrored cards, replies, quiet gaps, and the reply that hosts a run's cards |
| `TranscriptRowFace.swift` | What the Mac read of one transcript row (where it sits, its tag, its fold line, the agent's words for it), read once on the Mac and carried to the phone with the row |
| `TurnSecretRedactor.swift` | `TurnSecretRedactor`: shared credential recognition; callers own size bounds |
| `UserDisplayFormatters.swift` | Shared timestamp/path display and `CompactDurationFormatter`; parsing is cached |
| `VoiceNoteBubble.swift` | Mac/phone voice-note face; original audio, playback and expandable transcript |
| `VolumeIO.swift` | Serial off-pool filesystem work; bounded waits never cancel issued writes |
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
| `diagnostic-narration.js` | ability `diagnostic-narration`: Narrate checked Desk and Activity facts. |
| `due-reminders.js` | ability `due-reminders`: Read reminders in two named parts: today (local day, earliest first) and overdue (before today, oldest first). |
| `growth-week.js` | ability `growth-week`: My seven-day growth readout, from frozen native REM timeline evidence. |
| `mac-watch-catalog.js` | ability `mac-watch-catalog`: Return inactive Mail, Calendar and Reminders watch recipes. |
| `mail-recovery.js` | ability `mail-recovery`: Recovery wording for structured mail failure reasons. |
| `maintenance-assistance.js` | ability `maintenance-assistance`: Group and explain checked Doctor asks, saved storage plans and Speech Recognition permission facts. |
| `make-generated.js` | ability `make-generated`: Compose raw generated images with make.add, preserving their prompt, model and requested ref, and report each registration failure. |
| `make-title.js` | ability `make-title`: The title of a Make preview, from its decoded HTML title, prompt or filename. |
| `messages-recovery.js` | ability `messages-recovery`: Recovery wording for structured messages failure reasons. |
| `music-library.js` | ability `music-library`: Read Music playback state and observed timing; page typed playlists and sorted, filtered library/search results with totals, without opening Music. |
| `music.js` | ability `music`: Play, pause, stop or skip Music; bound play with seconds through the native player call, resolve an exact library track, and read playback through music-library. |
| `native-morning-brief.js` | ability `native-morning-brief`: Compose the morning brief and its inbox card from checked native source packets. |
| `notes-recovery.js` | ability `notes-recovery`: Recovery wording for structured notes failure reasons. |
| `notice.js` | ability `notice`: Notice a scriptable app arriving; offer once per bundle and version. |
| `presentation-copy.js` | ability `presentation-copy`: My page subtitles, activity phrases and automated conversation titles, over sanitized native presentation facts. |
| `research-lab.js` | ability `research-lab`: Select sources and compose a Research Lab brief from the native SearXNG evidence packet. |
| `studio-canon.js` | ability `studio-canon`: Propose canon tending from neutral recurrence, production-pull and membership facts, with reasons and the next silence deadline. |
| `studio-intake.js` | ability `studio-intake`: Order unanswered artifact consults from complete corrected history, and phrase invitations to work already in reach. |
| `telegram-commands.js` | ability `telegram-commands`: My Telegram command menu, help, and memory-command reply words. |
| `telegram-model-picker.js` | ability `telegram-model-picker`: Interpret Telegram model requests and draw checked model menus. |
| `telegram-progress.js` | ability `telegram-progress`: My Telegram progress and status voice over sanitized native lifecycle facts. |
| `today-readout.js` | ability `today-readout`: Draw Today as a timed timeline, upcoming intentions, earlier notes and named source gaps. |
| `turn-continuation.js` | ability `turn-continuation`: Compose a Desk continuation cue with native checkpoint evidence slots. |
| `turn.js` | turn `turn`: The stem hands step one event at a time (message, model, result, observation, provider_failure, resumed) and runs the effects it returns (model.call, app, reply.stream, reply.end, after). |
| `weather.js` | ability `weather`: Read current weather and daily temperature high/low, rain chance, wind, sunrise and sunset from Open-Meteo. |
| `workspace-readout.js` | ability `workspace-readout`: Compose Today, Music and helper workspace faces from native read facts, selecting only bound item and action keys. |
<!-- END GENERATED BLUEPRINT -->

## iOS Companion Map

### Companion

Directory: `iOS/NativeAgentMobile/Sources/`

<!-- BEGIN GENERATED BLUEPRINT: iOS/NativeAgentMobile/Sources/ -->
| File | Owns |
|---|---|
| `AdvancedPresentation.swift` | Shared mobile presentation, bounded request summaries with raw prompts retained, and design samples |
| `AdvancedView.swift` | More navigation reads the Mac's checked layout; missing/damaged snapshots expose recovery; Status and Runs |
| `AliveCards.swift` | Card surfaces, sections, rows and row press presentation |
| `AliveConnection.swift` | Shared Mac connection wording, pairing guidance and snapshot freshness |
| `AliveControls.swift` | Status lights, actions, search, glass controls and haze swatches |
| `AlivePage.swift` | Native list page, headers, list environment and scroll-edge fades |
| `AlivePalette.swift` | Phone haze colours, contrast tokens and page metrics |
| `AliveRoom.swift` | Phone room and chat-driven mood presenting the shared `HazeView` |
| `AliveWords.swift` | Count, identifier and timestamp wording for phone screens |
| `ApprovalPayloadView.swift` | An approval's words (title, kind, reason) and readable payload fields with the exact Mac-sent details |
| `ApprovalsStore.swift` | Signed approval decisions and refresh state; the Mac's routed alert is the phone's only approval alert |
| `ChatBubbleViews.swift` | Inline approvals in the conversation: which are pending here, and the card that decides one |
| `ChatModels.swift` | Chat values, runtime controls and Mac transcript projection onto ChatMessage |
| `ChatPresentation.swift` | Chat controls and picker presentation; model controls read the shared `iCloudSyncEngine.surfaceModels` projection |
| `ChatStore+ICloudReplies.swift` | Signed delivery evidence before early exits; shared terminal/snapshot settlement preserves partial words |
| `ChatStore+PendingExchanges.swift` | Durable bounded reply observation; unknown delivery retains exact retry and late replies |
| `ChatStore+ReplyObservation.swift` | Shared signed reply/rejection/resync receiver; restores bounded delivery observation |
| `ChatView+Choices.swift` | Mac-owned model configuration and ChatView option controls |
| `ChatView+Composer.swift` | Session-bound drafts, dictation, talk entry and attachment preparation on ChatView |
| `ChatView+ConversationEvents.swift` | Store-owned reply receiver; foreground refresh and session-bound dictation callbacks |
| `ChatView+Notices.swift` | One condition-bound banner lane for chat, sync and voice notices |
| `ChatView+Thread.swift` | The conversation's document: its rows, cards and actions, the composer's room and Latest |
| `ChatView.swift` | Conversation state, session navigation and anchor reconciliation; composes thread, composer, choices and notices |
| `ComposerVoiceMicrophone.swift` | Mic gestures and accessible dictation, voice-note recording, cancel and lock |
| `DeskStatus.swift` | Desk and task status marks, status words and kind words |
| `DiagnosticsView.swift` | Diagnostics: the Mac's diagnostics face (checks, status, runs), then this iPhone's own readback: recent pushes, unverified Mac records and the connection |
| `DictationComposer.swift` | Capped full-width dictation and live waveform; redraw independently of chat |
| `InboxCardRow.swift` | A note of mine as a card in the conversation: its words and the actions it declares; the Inbox face reads every note |
| `InboxModels.swift` | Phone inbox presentation; the Mac supplies status/source meaning |
| `InboxStore.swift` | Inbox refresh/actions and notification permission; the Mac's routed alert is the phone's only inbox alert |
| `KnowledgeGraphView.swift` | Shared typed graph presentation and ID-resolved details/neighbors; local search/loading state |
| `MacActionReceipts.swift` | Mac Tools receipt ledger, approval reconciliation and receipt rows |
| `MacBridgeClient.swift` | Signed iCloud chat transport, pairing and connection observation |
| `MacToolsPresentation.swift` | Shared Mac action policy hints, requested volume, notification feedback and Spotlight results |
| `MacToolsView.swift` | Mac controls use PhoneMacControlAction and the shared Trust snapshot; receipts live in MacActionReceipts |
| `MemoryStore.swift` | Memory refresh, deletion and proposal decision state |
| `MemoryView.swift` | Memories to keep: the memory proposals page and its rows read the shared sync projection; the memories themselves are the memories face |
| `MobileAgentsView.swift` | Contact state/time and ID-resolved chats; bounded requests/diagnostics retain readbacks and drafts |
| `MobileAppIntents.swift` | Named-agent Siri/Shortcuts actions, including authenticated foreground talk entry and ordinary Ask replies |
| `MobileFacePage.swift` | Any faced page on the phone: the shared FaceView over the face the Mac published, its links followed on the phone (a faced page or a saved run pushed here, every other place through the shell's router), its row actions answered by the page's owner on the Mac |
| `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |
| `MobileInteractionCard.swift` | Inline interaction fields, setup routing and signed answers |
| `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
| `MobileSchedulerView.swift` | `MobileSchedulerView` struct |
| `MobileSearchIndex.swift` | Actor-owned local row search shared by memory, tools and knowledge graph |
| `MobileSpeechAnalyzer.swift` | On-device timed recognition, name context and PCM conversion; detector events retain capture |
| `MobileTalkAudio.swift` | Full-duplex voice capture, timed on-device recognition and quiet acknowledgment |
| `MobileTranscriptAttachments.swift` | Phone document attachments: one hosted view per block id, fed from the model, sized to fit |
| `MobileTranscriptBuilder.swift` | The phone's door onto the shared transcript builder: the Mac's rows with their faces, the phone's own rows, and the phone's physics (earlier history, send buttons, decisions still owed, the live reply) |
| `MobileTranscriptController.swift` | Owns the phone's document and the one law: place is a text location, never a measured height |
| `MobileTranscriptFragments.swift` | One layout fragment per drawn paragraph kind, and the delegate that picks them and hides closed folds |
| `MobileTranscriptStyle.swift` | The phone document's look: paragraph keys, tokens in UIKit units, one block as one paragraph, action links |
| `MobileTranscriptView.swift` | The phone's conversation as one selectable document: the text view, its host handle and actions |
| `NativeAgentDesign.swift` | `View`: `appShimmer` |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PairingStore.swift` | Sole phone identity/Keychain transaction owner; checked pairing evidence governs sense/delivery retention |
| `PhoneBodyReadings.swift` | Wake-only battery, audio, network, Music/photo readings; scoped consent and bounded queries |
| `PhoneLocalSettings.swift` | Owner-declared local controls; signed requests read current owners and use consent sheets for raises |
| `PhonePlaces.swift` | Opt-in places and pairing-bound outbox; per-observation admission errors and receipt-driven delivery |
| `PhoneSenses.swift` | Opt-in sense outbox; local opt-out, checked pairing and durable delivery; bounded wake-only sampling |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities`; shared projected activity |
| `RunDetailView.swift` | One saved run, opened from Diagnostics: its readable prompt summary, the exact captured prompt copyable behind disclosure |
| `SettingsViewFull.swift` | Device settings, appearance and release version; shared refresh/availability; push diagnostics in Status |
| `SkillLifecycleView.swift` | Built-in guidance and ID-resolved details; Tools owns abilities; SkillsToolsView owns refresh/loading |
| `SkillsToolsView.swift` | Combined catalog refresh/loading; abilities and native tools read shared sync state with local search |
| `TalkModeController.swift` | Session-bound hands-free talk; bounded startup, timed endpointing, speech, barge-in and settlement |
| `TalkModeView.swift` | Haze call face, latest words and mute/end; accessible motion/transparency and speaking presence |
| `TelegramView.swift` | `TelegramView` struct; reads the shared revision-ordered Telegram projection |
| `TurnInspectorView.swift` | Turn summary presentation reads the shared sync projection directly |
| `VoiceInputController.swift` | Session-bound capture and bounded on-device recognition; unsupported devices/locales name blockers |
| `iCloudBridge+CloudKit.swift` | Pairing-bound catch-up/presence; retained incomplete reads, bounded receive and fenced recovery |
| `iCloudBridge+Drive.swift` | Drive setup/outbox, consumed-reply archive retention and bounded staged publication |
| `iCloudBridge.swift` | Authenticated delivery; bounded unknown-send observation, pre-dispatch receipt listeners and checked retention |
| `iCloudSyncEngine+Actions.swift` | Signed submissions and repair admission; verified responses, settlement and bounded arrival waits |
| `iCloudSyncEngine+Commands.swift` | Subject commands and receipt adoption through the signed action transaction |
| `iCloudSyncEngine+SnapshotReading.swift` | Replica freshness, bounded checked reads, whole-document decoding and read health |
| `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot`, `refreshHelpersSnapshot`, `applySchedulerSnapshot`, `refreshSchedulerSnapshot`, `applyProviderState` |
| `iCloudSyncEngine+Transactions.swift` | Signed envelope retention, pairing reconciliation, mailbox recovery and bounded locked persistence |
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
    {"id": "core-does-not-import-app", "roots": ["Modules/NativeAgentCore/Sources"], "forbiddenImports": ["NativeAgentApp"]},
    {
      "id": "app-is-a-platform-door",
      "roots": ["Sources/NativeAgentApp"],
      "requiredAnyImports": ["SwiftUI", "AppKit"],
      "allowlist": {
        "Sources/NativeAgentApp/InboxCardActions.swift": "Area 4 — approval transaction app effects and presentation assembly",
        "Sources/NativeAgentApp/ActivityWatchController.swift": "App presentation/platform integration — area number unmapped",
        "Sources/NativeAgentApp/AppApprovalTransactionEffects.swift": "Trust and shared model projections — area number unmapped",
        "Sources/NativeAgentApp/AppQuietLowerOnly.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietSettingsHost.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietToolHost+Mind.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietToolHost.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppToolPlatform.swift": "Area 1 composition handoff — live executor/browser/Doctor bindings",
        "Sources/NativeAgentApp/MemoryAppIntents.swift": "MemoryV2 — area number unmapped",
        "Sources/NativeAgentApp/NativeAgentIntents.swift": "App presentation/platform integration — area number unmapped",
        "Sources/NativeAgentApp/SensesAssembly.swift": "Area 1 composition handoff — live sense runner/provenance bindings",
        "Sources/NativeAgentApp/AppModel+ChatActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+ChatSessions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+GraphCapabilityActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+HealthEmbeddings.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+MemoryActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+Refresh.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own"
      },
      "message": "Engine logic belongs in NativeAgentCore; the app retains views and platform adapters."
    }
  ]
}
```
