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
| `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | Shared completion route/requester identity and destination validation; `isValidIOSDeviceRouteKey` |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift` | One nonblocking subprocess pipe reader shared by provider transport and Mac execution; MacControl translates setup failures at its execution boundary |
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
Edges required for extension visibility remain even without a direct import,
including WorkshopExecution's persisted procedure identity constraints.

Native reply entries use `TurnQuietHoursWindow` before dispatching a send. A
resident answer waits in its saved completion and pre-send route journal;
deferral writes nothing. Delegation's exact quiet-hours end deadline runs the
existing saved-delivery reconcile. `LiveNotificationInbox` retains notification
intent, including Mac metadata and sound, for `AttentionRouter.releaseHeld`.
The router's defer decision also owns scheduled banners, posting them before
push transport so either channel can fail independently. Held Mac dispatch is
claimed on its inbox row; an unconfirmed attempt is never automatically replayed.
iOS asking-chat publication follows its native send verdict, before completion
settlement. An explicit Telegram resend clears its saved refusal once, even
when quiet hours delay the wire. Work and wakes continue.

### Sense Helper Boundary

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentSenseHost/main.swift Sources/NativeAgentSenseHost/PlugIO.swift Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift Modules/NativeAgentCore/Sources/Senses/SenseHostLocator.swift Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift -->
| File | Responsibility |
|---|---|
| `Modules/NativeAgentCore/Sources/Senses/SenseHostLocator.swift` | Installed helper address |
| `Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift` | Deny-default Seatbelt reach, shared private-root policy (workspace allowed only through app delivery), and exact-IP network fence |
| `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift` | Persistent sense/resident-part contexts with fresh frozen input per call; native rehearsal requests reset context/body/input references between fixtures in one helper; synchronous run/face entries, fresh projection helpers, shared Swift fragment-redaction binding and SenseWire validation, JSC execution watchdog with ProgramProgressWindow arithmetic |
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
shares one catalog, including missing action ids, across redaction and provenance.
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
`AppActions` owns dependency contract projection and frozen legacy pin identities;
argument/result schemas and revision are pinned independently of discovery prose.
Admitted authored tools are scriptable actions, including routine dependencies;
their calls retain ordinary skill checks and capture validation substitutes fixtures.
Their pinned action contract supplies the routine's read-before-act knowledge;
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

Hardened-runtime Mac builds require
`com.apple.security.personal-information.calendars=true`; without it, TCC
rejects Calendar permission prompts. All four Mac entitlement templates retain
this grant, and `script/verify_release_artifact.sh` checks the signed entitlement.

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentApp/ -->
| File | Owns |
|---|---|
| `ActivityCapturePermissionsView.swift` | `ActivityCapturePermissionsView`: Trust Center consent/title/exclusion controls and honest capture privacy/issue presentation |
| `ActivityWatchController.swift` | `ActivityWatchController`: app-side watcher binding and sensitive-detail-free issue notifications; Trust Center retains issue detail |
| `AdvancedPageComponents.swift` | Shared Advanced page sections and read status |
| `AgentContactsSection.swift` | `AgentContactsSection`: contact rows/actions from discovery state; offscreen capture reads never initiate discovery |
| `AgentPresence.swift` | Agent presence card and Core Animation breathing orb reflect shared turn state and motion preferences |
| `AgentScreenView.swift` | `AgentScreenView`: read-only agent home/room projection; preview never marks seen, writes or dispatches tools |
| `AlivePageKit.swift` | Alive page components: shared glass metrics/palette, headers, cards, pills, progress and flow layout for Today/Desk |
| `AnthropicSetupTokenInput.swift` | `AnthropicSetupTokenInput`: setup-token paste, submission and visible status through existing provider setup |
| `AppApprovalTransactionEffects.swift` | `AppApprovalTransactionEffects` struct and `ApprovalExecution.app`: app-bound approval factory and live executor/platform bindings; `AppApprovalTransactionEffects` struct; `ApprovalExecution.app` |
| `AppConnectorPlatform.swift` | live voice, notification, Mac control and device-sync bindings over core connector/integration policy and status owners; remaining composition belongs to Area 1; notification, EventKit and connector platform bindings over core policy/status owners |
| `AppDelegate+BackgroundTasks.swift` | `AppDelegate`: `registerBackgroundTaskHandlers` |
| `AppDelegate+Launch.swift` | `AppDelegate`: launch and turn-safe quit; closes external ingress, retains launch/approval observation settlement, joins the engine's shared quit sleep, retires browser IPC after tracked turns and wake runs |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: `claimSingleAppInstance`, `presentSingleInstanceWedgedAlert`, `presentPublicReleaseDataRootError` |
| `AppModel+ChatActions.swift` | `AppModel`: `compactSession`, `compactActiveChat`, `clearActiveChatMessages`, `regenerateAssistantMessage`, `startActiveChatTurn`, `startChatTurnForSession`; turn options from `ChatTurnRuntime/MacChatTurnCommands.swift` |
| `AppModel+ChatSessions.swift` | `AppModel`: chat load/selection/index refresh; `composerDraft(for:)` owns one draft per session for main/detached composers and commands, exact accepted-edit clearing and empty-only prefills; quiet chat commands delegate to shared transcript/session transactions |
| `AppModel+ChatState.swift` | `AppModel`: `loadDetachedSessionMessages`, `pinChatSessionForDetachedWindow`, `pruneSessionChatState`, `pruneStaleSessionChatState` |
| `AppModel+GraphCapabilityActions.swift` | `AppModel`: `searchGraph`, `refreshGraph`, `runResearchLab`; Lab's frozen evidence calls the editable `research-lab` part through `Parts.call` and the canonical admission-only gate; native Research commits the accepted proposal |
| `AppModel+HealthEmbeddings.swift` | `AppModel`: `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`; the Doctor owner's `LatestRead` orders health-card publication |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` reconnects checkpoint progress to the core event stream and lifecycle; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory` |
| `AppModel+Onboarding.swift` | `AppModel`: first-run greeting port and onboarding commands |
| `AppModel+PanelRefresh.swift` | `AppModel`: per-panel `LatestRead` and freshness receipts; sidebar reads engine-owned sources without claiming unrelated refreshes |
| `AppModel+PersonalitySelfImprovement.swift` | Mac personality editor outcomes delegate profile/document publication and writes to `engine.persona`; support diagnostics and proposal actions |
| `AppModel+ProviderCommands.swift` | `AppModel`: checked provider reads, chat-brain saves and disconnect outcomes |
| `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll`; Telegram form reads share `refreshTelegramSettingsDraft` with the direct refresh |
| `AppModel+RoutingWorkflowMCP.swift` | `ResearchSearchFailure`; `AppModel`: research `search`, `resolveApproval`, `resolveApprovalOnce` |
| `AppModel+SchedulerActions.swift` | `AppModel`: scheduler and Desk creation commands; nightly reflection outcome wording |
| `AppModel+SkillsIntegrations.swift` | `AppModel`: built-in skill guidance and part Keep/off-switch; toolbar Tools refresh and inbox actions; workspace creation, SearXNG autodetection and projection readback, Telegram settings/log actions and Doctor commands; `refreshTelegramSettingsDraft` captures and merges untouched form fields through one newest-started `LatestRead.refreshDraft` owner; connector updates verify through `engine.connectors.update` |
| `AppModel+TrustActions.swift` | `AppModel`: Trust policy, backups, approval resolution and Mac control commands |
| `AppModel.swift` | `AppModel`: app composition and UI/editor state; canonical state derives from engine owners; shared draft/session storage and surface presentation |
| `AppQuietLowerOnly.swift` | `AppQuietSettingsHost` and `AppQuietToolHost`: app connector/permission command bindings with Full Mac ownership limits and visible decisions |
| `AppQuietSettingsHost.swift` | `AppQuietSettingsHost` class; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: `runMind`, `managePart` |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppShellMenuPresentation.swift` | `NavigateMenuPresentation` and `MenuBarStatusPresentation`: menu order/shortcuts projected from the rail and one canonical status line |
| `AppToolPlatform.swift` | AppToolExecutor platform bindings: browser, notification, workshop decisions and away sensing; chat.post receives the engine's existing background speech client |
| `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |
| `ApprovalsView.swift` | `ApprovalsView`: checked approval decisions/history, payload preview and known risk-badge/toast presentation |
| `AuthoredToolsSection.swift` | Authored tool lifecycle labels, controls and confirmation through AppModel commands |
| `BotRow.swift` | Helper shelf rows, status marks, timing and shared accessibility wording |
| `BotRunCard.swift` | Helper run receipts, quiet-run folds and artifact links; recorded outcomes and model remain run-owned |
| `BotsEditorSheet.swift` | facade provider accounts and checked settings, shelf next-run projection, engine-owned fresh definition merge |
| `BotsShelfView.swift` | shared helper status and transcript messages/streaming tail; no private transcript rows or JSONL observation |
| `BrowserWindow.swift` | MainActor-owned `BrowserNavDelegate` and `BrowserCallbackWait`; `BrowserActionRoutes.app` over the visible window's route effects; callbacks or cancellation settle once; physical exclusion remains until late WebKit callbacks exit |
| `CapabilitiesView+DeveloperTools.swift` | `CapabilitiesView`: research receipts, memory graph and autonomy guardrail controls |
| `CapabilitiesView+MacActions.swift` | `CapabilitiesView`: native Mac actions, checked availability and browser/improvement run receipts |
| `CapabilitiesView.swift` | `CapabilitiesView`: capability inventory, catalogs and saved workflows |
| `CapabilityProductionHardeningPanel.swift` | `CapabilityProductionHardeningPanel` struct |
| `ChatClipboardAndAttachmentSupport.swift` | `ChatAttachmentTypeResolver` and `ChatClipboard`: shared dictation preparation, screenshot submission/reconciliation, drop/paste/picker intake and off-main image conversion |
| `ChatCodeBlockView.swift` | `ChatCodeBlockView`: selectable fenced code, language label and idempotent copy; no renderer state or clock |
| `ChatComposerChrome.swift` | `ComposerKeys`: editor-scoped Tab, slash, Shift-Return and attachment paste interception; shared composer chrome |
| `ChatComposerDraft.swift` | `ChatComposerDraft`: the shared session text, edit timestamp and manual-edit revision for dictation; AppModel owns its lifetime and composers bind to the same object |
| `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |
| `ChatComposerSettings.swift` | Native composer menus and context receipt: keyboard access and shared routing/actions |
| `ChatContextFillBar.swift` | `ContextFillPresentation` and context strip/ring: measured usage, model window and compaction controls; missing figures stay visibly unavailable |
| `ChatFocusedCommands.swift` | `ChatFocusedCommands`: active-window chat action closures and page visibility, keeping shortcuts out of hidden controls |
| `ChatInboxStrip.swift` | `InboxStripContainer`: compact unread-note/approval/card projection; reading does not resolve and settled origins archive their pointer |
| `ChatInlineApprovalCard.swift` | mounted approval card, transient interaction state and facade-owned decisions |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableParser` and view: pure prose segmentation, alignment/cell parsing and rendered transcript tables |
| `ChatMessageListView.swift` | Windowed transcript interleaves HerScreen other-room exchanges from the contact projection; rows open the sidebar's contact thread; paging, grouping and card placement stay on the transcript rows |
| `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops and scroll event bridges with mounted-page visibility |
| `ChatPreparedContent.swift` | Settled rich text, list/table preparation and bounded Markdown/content caches |
| `ChatQueuedTurnsView.swift` | `ChatQueuedTurnsView`: bounded session-scoped send-next chips, overflow and steer/send-now controls |
| `ChatShellPresentation.swift` | `ChatShellStatus`, `ChatShellCopy`; waiting/failure status and composer/greeting copy |
| `ChatShellViews.swift` | `ShellRoomHeader`; `ShellConversationRow` reads subtitle timestamps from its injected transcript-root opening-line owner |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatStreamingTail.swift` | `StreamingTailBubble` and observer: row-local live text updates without republishing the whole transcript |
| `ChatToolCatalogSection.swift` | Mounted tool catalog classification/search, approval and Full Mac presentation, detail controls and shared status tones |
| `ChatToolPillView.swift` | `ToolPillPresentation` struct; retained metadata projection, `outcome`, `title`; `ToolCallGroup` preserves approval expansion and persona receipt partitioning |
| `ChatTurnFailure.swift` | `FailedTurnRetryConfirmation` and continuation binding: shared confirmation after effects/unknown outcomes and session-local continue action |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+Conversation.swift` | `ChatView`: transcript viewport, composer, search/navigation and cross-door turn observation; existing quiet and visibility gates |
| `ChatView+DetachedSessionMenu.swift` | `ChatView`: `detachedSessionMenu` |
| `ChatView+PinnedSessions.swift` | `ChatView`: human pin reads and pruning; additive pinning delegates to `TranscriptsFacade` |
| `ChatView+SessionActions.swift` | `ChatView`: toast publication, committed session rename and voice/export actions |
| `ChatView+ShellColumn.swift` | `ChatView`: conversation sidebar, archive control and cached opening-line/pin projection; stable section row identities |
| `ChatView+SlashCommands.swift` | `ChatView`: `send` admits ordinary chat; built-in commands use `ChatSlashCommandRouting.perform` and preserve pending attachments |
| `ChatView.swift` | `ChatView`: conversation state and mounted lifecycle; `ChatTurnNoticePresentation`; stale-panel notice leaves |
| `ChatViewStateCoordinators.swift` | Chat viewport/follow state, measured turn-card/composer clearance and clear confirmation; occurrence-preserving toast queue |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` alias to `ChromeControl.ChromeExtensionFolder`; app-bound `setUp`, `setupMessage` |
| `ClaudeConnectionPanels.swift` | Claude connection panels show CLI availability, persistent process evidence and direct OAuth sign-in |
| `CognitionObservatoryView+Affect.swift` | Observatory affect presentation: snapshot axes and warmth context distinguish disabled/unavailable evidence from real zero |
| `CognitionObservatoryView+Capsule.swift` | Observatory capsule/reflection panels and felt-mode gloss: read-only projection with no capsule text or behavior mutation |
| `CognitionObservatoryView+LoopHarness.swift` | Observatory loop/workspace/association panels: same-snapshot endpoint resolution and honest unavailable receipt/graph presentation |
| `CognitionObservatoryView+Metrics.swift` | `CognitionTensionsPresentation`: same-snapshot capacity/counter models for Observatory metrics and pruning panels |
| `CognitionObservatoryView+Organism.swift` | Observatory organism panel: read-only kernel rows distinguish off, empty, stale and malformed readings |
| `CognitionObservatoryView+Proposals.swift` | Observatory growth-week and developmental timeline: readout/receipt presentation from current cognition state |
| `CognitionObservatoryView+Shared.swift` | Observatory shared rows/count badges: explicit zero stays visible; unavailable or malformed counts never become fabricated badges |
| `CognitionObservatoryView.swift` | `CognitionObservatoryView`: live panel assembly, live dependency reads, override controls and persistence/feedback presentation |
| `CognitionProposalsView.swift` | `CognitionProposalsView`: read-only schema lineage from canonical Dream/REM approvals |
| `CommandPalette.swift` | Mounted command search, navigation and window-scoped key interception; actions remain with canonical owners |
| `CommandPaletteInventory.swift` | Palette item inventory, saved-owner projections and deterministic search ranking |
| `ComposerContextReceipt.swift` | `ComposerContextReceiptBody`, `ComposerContextReceiptCard` views; `LatestRead` on the shell (or standalone card) orders receipt publication |
| `ComposerShellState.swift` | Mounted native menu tracking, context receipt and Trust confirmation state; quiet reads use the open menu |
| `ConnectorWizardView.swift` | `ConnectorWizardView` and state: existing connector setup routes, cancellable sign-in/save steps; successful Slack save reconciles the worker and connector projection through `settle` before canceled view updates stop; truthful external-browser handoff outcomes |
| `ConnectorsView.swift` | `ConnectorsView` struct: engine connector projection for the secrets the keyring keeps (name, where each may go, account, when granted; Remove after a confirmation) and the built-in accounts |
| `ContactPortraits.swift` | Contact app icons, initial tints, Clawd drawing and helper/crew clock tiles |
| `ContentView.swift` | `ContentView`: Simple/Advanced/Agent shell assembly, navigation destinations, first-run presentation and iCloud action refresh routing |
| `ContextFlowObservatoryPanel.swift` | `ContextFlowObservatoryPanel`: health rows preserve off, unreadable and failed states instead of a reassuring zero table |
| `DeskBoardFolds.swift` | `DeskPageView` folds: board, finished history, schedule and bounded row reveals |
| `DeskDebugPanels.swift` | `DeskDebugPanels`: diagnostic disclosures over the engine's retained Desk revision |
| `DeskItemInspector.swift` | `DeskItemInspector` struct |
| `DeskNagsPanel.swift` | `DeskNagsPanel`: current nag configuration reads and explicit owner controls through Desk quick actions |
| `DeskPageRows.swift` | Desk row metrics, project/detail rows, action notices and execution labels |
| `DeskPageView.swift` | `DeskPageView`: canonical work page, state, navigation and actions; store/execution failures stay distinct |
| `DetachedChatPanel.swift` | `DetachedChatWindowController`: session-window creation, persisted pins/frames, focus, appearance and lifecycle teardown |
| `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session-bound transcript/composer, search, speech and attachment intake through shared chat owners |
| `DiagnosticsView.swift` | `DiagnosticsView` and refresh coalescer: one sequential shared snapshot across status/runs segments, with legacy tab routing; each mind's door predictions and their records (`Expansion.summary`) |
| `DisclosureRowToggle.swift` | `DisclosureRowToggle`: whole-label disclosure hit target sharing the DisclosureGroup's existing binding |
| `DoctorView.swift` | `DoctorView`: measured report rows/footer, run/repair/support actions and explicit action failure presentation |
| `DreamsView.swift` | `DreamsView`: shared diary reads, selection, dream/REM controls and unavailable/error presentation |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `GrokSecureSetupCard.swift` | `GrokSecureSetupCard`: masked credential submission through secure setup, without exposing secret values in the view |
| `HealthPill.swift` | `HealthPill`: compact health status color/label presentation |
| `InboxCardActions.swift` | `AppInboxCardActionEffects`: mounted navigation and injected engine inbox; callers use the core inbox transaction directly |
| `InboxItemDetailSheet.swift` | Full note reader, related-note routes, action words and shared single-flight outcomes |
| `InboxNotesCapsule.swift` | Chat-header unread notes capsule, note selection and failed-read retries |
| `InboxSettingsView.swift` | `InboxSettingsView`: master/trigger controls, independent writer outcomes and history navigation over canonical inbox policy |
| `InboxView.swift` | `InboxView`: canonical inbox lanes, digest groups and row actions; unknown sources stay visible |
| `InlineCard.swift` | Inline card visual grammar: surfaces, controls, symbols and receipts; no store or work lifecycle ownership |
| `InlineCardView.swift` | InlineCardView renders every interaction state, field and choice; actions remain closures owned by the interaction |
| `InlineInteractionChatBinding.swift` | `InlineInteractionChatBinding`: card action/control presentation, existing setup sheets and verify-on-return settlement |
| `InlinePreviewCards.swift` | `ApprovalDecisionAction.resolve`: one inline approval resolve/toast/refresh sequence shared by deciding surfaces |
| `InspectorView.swift` | `InspectorView` and `TurnInspectorStore`: per-window live/replay selection over engine traces with separate requested/displayed date provenance |
| `InteractionCardDelivery.swift` | `InteractionCardDelivery`: `answer`, `act`; shared card transactions with native navigation; `AppInlineInteractionPlatformPort`, `AppInlineInteractionControlPort`, `InteractionInboxCard` |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphMaintenance.swift` | Knowledge Graph orphan preview and reviewed deletion presentation; canonical maintenance actions require the exact candidate set |
| `KnowledgeGraphPolicy.swift` | Knowledge Graph policy presentation and checked Memory Policy writes; mounted policy reads and enable/disable actions |
| `KnowledgeGraphPresentation.swift` | Graph modes, filters, cached date projection, selection and content/error presentation; retains the canvas size boundary |
| `KnowledgeGraphRows.swift` | Entity rows and detail render `MemoryFacade.graphSnapshot`, without separate neighborhood reads |
| `KnowledgeGraphStatusHeader.swift` | `KGNativeStackHeader`: renders the engine memory diagnostics and graph counts |
| `KnowledgeGraphView.swift` | KnowledgeGraphView: mounted graph browsing and shared MemoryFacade refresh; policy, maintenance and filtering retain their owners |
| `LivingStatusPanel.swift` | `LivingStatusPanel` struct |
| `MacAssistantWatchSetupView.swift` | `MacAssistantWatchSetupView`: assistant watch/access controls, readiness reads and actionable Mail/permission checks |
| `MacChatOtherSessionsBanner.swift` | `MacChatOtherSessionsBanner`: navigation and stop controls directly over the other running sessions |
| `MacChatRunningSessionMenu.swift` | `MacChatRunningSessionMenu`: shared go-to menu for sessions with background turns |
| `MacChatTranscriptSearch.swift` | `MacChatTranscriptSearch` alias to `ChatSessionWork.TranscriptSearch`; `MacChatTranscriptSearchCursor`, `MacChatTranscriptSearchController`, `MacChatTranscriptSearchBar`; source preparation and search results publish through `LatestRead`, with input revisions retained only for coalescing; `TranscriptSearch.scrollTargetID` |
| `MacChatTurnCard.swift` | `MacChatTurnCard`: one display over canonical lifecycle state, shared by main/detached windows without card-local clocks or state machines |
| `MacControlAuditSheet.swift` | Mac control audit rows, read failures and loading feedback through the existing bindings |
| `MacControlCategoryRow.swift` | Mac control capability switches and explicit unavailable-category presentation |
| `MacControlPermissionsView.swift` | Checked consent controls, policy saves and explicit permission feedback |
| `MacControlSetupPresentation.swift` | Mac integration preset labels and badges derived only from checked saved policy |
| `MacControlWorkbenchView.swift` | Concrete Mac control workbench, retained drafts, action commands and result feedback |
| `MacIntegrationView.swift` | `MacIntegrationView`: checked integration read/write controls, actual permission probes and truthful System Settings handoff outcomes |
| `MacPairingView.swift` | `MacPairingView`: shared pairing assessment, key presentation/rotation and reveal lifecycle; offscreen reads never generate keys |
| `MacWorkOverviewDetail.swift` | `MacWorkOverviewDetail`: canonical work detail and decision actions, never the clipped overview copy |
| `MemoriesPageView.swift` | `MemoriesPageView`: canonical recall rows without inventory substitution; request-scoped loading/failure, retained rows labeled by their original query |
| `MemoriesRowText.swift` | Memory provenance, time, ordering and page/row wording from canonical records; no store ownership |
| `MemoriesRows.swift` | Memory row, proposal, history and disclosure views with full-text sheet identity; actions remain page-owned closures |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform`; pending proposals use the engine's review-eligible reader |
| `MemoryView.swift` | Memory page upkeep/status components: canonical Spotlight actions, full text and explicit storage/embedder availability |
| `MenuBarController.swift` | `GlobalHotkey`: Carbon summon registration and tap/hold push-to-talk state with cancellable voice lifecycle |
| `MessageAttachments.swift` | Transcript-owned local image previews and attachment chips |
| `MessageBubble.swift` | Transcript message bubbles, provenance, streaming settlement, hover and accessible actions |
| `MessageBubbleActions.swift` | Bubble hover controls, canonical message JSON sheet and advanced text editor |
| `MoodTint.swift` | Mood tint presentation: sampled canonical mood, damping/caps and accessibility-aware glass modifiers without independent feeling state |
| `NativeAgentApp.swift` | SwiftUI app and scene declarations; coordinator-gated async restore/recovery before model and ingress, off-main engine/layout preparation; `NativeAgentEngine.installRuntimeObservationsAtLaunch` through `EngineLaunch` to `BackgroundWork.BodyReport` Swift crash/exit logging |
| `NativeAgentAppCoordinator.swift` | `ApplicationLifetime`: process bootstrap and queued scene navigation; delivery receipts prove scene acceptance, not finished rendering or work |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`; centered shell layout and shared surfaces |
| `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |
| `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |
| `NativeAgentIntents.swift` | `NativeAgentChatIntent`: `perform`, `reply` |
| `NativeAgentMotion.swift` | `NativeAgentMotion`: shared timing/arrival transitions with Reduce Motion-aware layout and retained opacity crossfades |
| `NativeAgentNotificationActions.swift` | Native response mapping, shared category registration and mounted window/conversation dispatch; effects stay in EngineNotificationActions |
| `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |
| `NativeDisclosureTriangle.swift` | `NativeDisclosureTriangle`: AppKit disclosure button bridge sharing the row's expansion binding |
| `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession` |
| `NativeOAuthPlatform.swift` | `NativeOAuthPlatform`: `NativeOAuthPlatformPort` conformance and `isCanceledLogin` adapter |
| `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge with native clear/escape/return behavior and explicit focus tokens |
| `OAuthSignInButton.swift` | `OAuthSignInButton` and presenter: in-process sign-in/sign-out, CLI session consent and current credential-state presentation |
| `ObservatoryNoticeRow.swift` | `ObservatoryNoticeRow`: one compact tinted notice presentation shared by Observatory panels |
| `OnboardingProfileRepair.swift` | OnboardingWizard profile-only repair, failure copy, ProfileRepairStep and DoneStep; completion bypasses fresh-install scaffolding and welcome |
| `OnboardingRecovery.swift` | OnboardingWizard durable-state recovery and ErrorStep; interrupted transactions resume through the onboarding owner |
| `OnboardingTourOverlay.swift` | Tour progress uses stable stop identity and reconciles rail changes from the engine layout passed by ContentView; only in-overlay progress is local |
| `OnboardingWizard.swift` | Fresh identity setup and shared wizard presentation; recovery, profile repair and reset are separate identity operations |
| `OnboardingWizardState.swift` | OnboardingWizardState: local progress and name drafts; provider connections and Chat readiness derive from ProvidersFacade |
| `PageSheetHost.swift` | Shared page sheet framing and focused Desk schedule/research sheets |
| `PersonaWriteReceiptRow.swift` | `PersonaWriteReceiptRow`: settled persona-write receipt projection using the existing inline receipt grammar |
| `PersonalityView.swift` | `PersonalityView` struct; document editing makes no claim that memory review writes the optional MEMORY.md input |
| `ProviderAccounts.swift` | Provider account rows, sign-in presentation and catalog refresh; ProviderSettingsView keeps page state |
| `ProviderActivityChoices.swift` | Grouped activity model choices and pending-write lifecycle use ProvidersFacade routing transactions and inline receipts |
| `ProviderCards.swift` | Shared provider cards, notes, titles and account status words |
| `ProviderConfigSheet.swift` | ProviderConfigSheet holds connection credentials, protected drafts, model defaults and explicit verification |
| `ProviderSettingsView.swift` | ProviderSettingsView owns account and activity draft state and composes their columns |
| `QuietComposerCommands+Presentation.swift` | Quiet composer command port, checked routing projection and mounted-page effects |
| `QuietSelfAdminRender.swift` | Quiet page assembly and app read/action host; Tools ability rows use Parts.list, including turn and senses; mounted presentation supplies the visible mode and Agent room for self-window reads, independently of Advanced sidebar `current` and its screenshot restriction; Today waiting uses `WorkOverviewRead`, helpers use the engine bot shelf, chat cards use the transcript owner's checked projection; page indexing/rendering receives live layout; context receipts read the engine data root |
| `ResearchView.swift` | `ResearchView`: search/configuration actions and eligibility/status presentation over root-scoped Research owners |
| `ResetPersonaView.swift` | ResetPersonaView and OnboardingWizard pending-setup reset; both use the backup-preserving onboarding reset owner |
| `RunsView.swift` | `RunsView`: shared ledger list/details and explicit unknown/failure badge vocabulary from canonical run rows |
| `SchedulerView.swift` | `SchedulerView`: scheduled job controls and explicit accepted/refused toggle receipts |
| `SecurityCenterPanel.swift` | `NativeSecurityCenterPanel`: checked posture, kill-switch, flags and receipt presentation; local pending state lasts only through saved-policy reread |
| `SelfImprovementView.swift` | `SelfImprovementView`: weekly improvement switch, corrected-lesson growth reads and explicit manual-run feedback |
| `SensesAssembly.swift` | `SensesAssembly`: launch-only shared hub installation and gated raw-read bindings; quiet reads borrow no turn authority |
| `SensesView.swift` | `SensesView`; engine Senses projection with scoped changes and actual live watches, lifecycle controls and native share picker |
| `SessionDragSourceView.swift` | `SessionDragSource`: AppKit drag completion/desktop-detach bridge with pasteboard identity and monitor teardown |
| `SessionRow.swift` | `SessionRow` and `ChatRenameStateMachine`: session pin/source presentation and one terminal rename result across submit/cancel/focus loss |
| `SetupFeatureRows.swift` | `SetupFeatureRows`: settings-page controls over existing cognition/context/dream/memory/embedding owners; no new settings store |
| `SetupRestRows.swift` | `SetupRestRows`: remaining settings controls in shared page rows, build identity and bundled data-limit reference handoff |
| `SetupView.swift` | `SetupView`: settings page assembly, shared row controls and model pickers over canonical settings owners |
| `ShellRailPages.swift` | `ShellRailTab` and rail page wrappers: per-page remembered tab selection and canonical route-to-tab projection |
| `ShellSidebarRail.swift` | `ShellSidebarRail`: canonical rail item presentation, selection and focus-ring rendering |
| `ShellTabs.swift` | Shell page/tab components: content-local action rows, shared scroll gutter and tabbed page layout |
| `ShellWindowChrome.swift` | `ShellWindowChrome` and `ShellFrame`: native window/titlebar integration, split shell layout and explicit keyboard target order |
| `Shotgun.swift` | `ShotgunController`: person-only floating chat/window lifecycle while the agent drives, with step-aside, resume and saved placement |
| `ShotgunPointer.swift` | `AgentPointerOverlay`: noninteractive agent pointer presentation and fade lifecycle, excluded from agent captures |
| `ShotgunView.swift` | `ShotgunView`: driving-session transcript/composer, live step and Stop/Resume/Watch controls through existing owners |
| `SimpleContactThread.swift` | Contact conversation, live reply, stop and queued resend retain canonical session acceptance and delivery evidence |
| `SimpleCrewThread.swift` | Read-only crew progress, worker evidence, outcomes and synthesis |
| `SimpleHelperThread.swift` | SimpleHelperRuns shows helper history and messages; accepted drafts send to the helper or the resident's chat |
| `SimpleSetupPanel.swift` | `InlineCardSetupPresentation`: existing setup controls in a floating Simple panel or Advanced sheet/page |
| `SimpleShellView.swift` | Simple and Advanced shells select the engine's shared contact, helper and crew threads |
| `SimpleSidebar.swift` | Shared contact/helper/crew sidebar and Simple settings menu retain engine projections and native navigation |
| `SimpleThreadComposer.swift` | SimpleComposer binds drafts to their thread and clears only accepted sends, retaining alternate routes and accessibility |
| `SimpleThreadPresentation.swift` | Shared thread column, header and transcript text render the chat's typography and retained inline parsing |
| `SimpleViewMode.swift` | `ViewModeSwitch`: Simple/Advanced/Agent selection and shared top chrome placement |
| `SkillLifecycleView.swift` | `SkillLifecycleView`: persona-guidance list/search/source reads and explicit build-draft handoff through existing chat owners |
| `SlimSettingsView.swift` | Operational settings presentation: Fluid Context labels, status wording and updater availability shared by settings page rows |
| `StatusView.swift` | `StatusView`: living system status and latest chronological activity projection with raw malformed-time evidence retained |
| `SystemPermissionPreflight.swift` | `SystemPermissionPreflight`: shared card and Settings consent acquisition, checked unresolved-grant handoff and Bluetooth prompt lifecycle |
| `SystemToastBar.swift` | platform notice rendering and room-scoped positioning; values, queue and timers belong to NativeAgentShared |
| `TelegramView.swift` | `TelegramView`: credential-free settings/status projections, access confirmation and save/test/log controls; outbound success never proves inbound poller health |
| `ThinkingGlow.swift` | `ThinkingGlow`: leaf-layer working shimmer and composer rim driven by turn state, fading when reply text begins |
| `TodayView.swift` | Visible Today lanes and activity from `engine.today`; waiting shares WorkOverview with quiet Today; engine layout renders current blocks; note actions use `engine.inbox`; local row/sheet interaction state |
| `ToolOperationStatusReceipt.swift` | Bounded AppModel operation feedback; repeated results retain independent receipt identities |
| `ToolsView.swift` | Tools screen, scoped refresh feedback and Trust navigation through AppModel |
| `TranscriptCards.swift` | ChatInlineCardHost draws the page mount's current-message card models; the action environment reaches the interaction owner |
| `TranscriptLayoutProbe.swift` | `TranscriptLayoutProbe`: opt-in per-row layout measurement and bounded diagnostic ledger, without changing transcript content |
| `TrustCenterView.swift` | `TrustCenterView`; confirmation states a normal backup is kept before scope replacement, failure replaces nothing, and previous-life work stays stopped until fresh Resume |
| `TrustGuardrailSummary.swift` | `TrustGuardrailSummary`: derived plain-language effective file/autonomy/backup/Mac/send reach, never another saved policy |
| `TrustPermissionsViews.swift` | Trust permission views: checked Chrome/multimodal/training/Workshop/memory policy controls through existing Trust owners |
| `UpdateController.swift` | `UpdateController`: configured Sparkle lifecycle, version probes and explicit unavailable/update presentation |
| `VoiceInputController.swift` | `VoiceInputCapture.forChat`: binds agent-name recognition context, person-visible macOS speech authorization and shared user-facing failures |
| `WindowHaze.swift` | Mac window haze palette, controls and shared `HazeView` presentation |
| `WorkPane.swift` | `WorkPaneState` and `WorkPane`: one read-only work column's Steps/Screen/Make selection, explicit visibility and turn-driven auto-open |
| `WorkPaneMakeView.swift` | `WorkPaneMakeView`: Make studio refs/version preview and actions over canonical studio state |
| `WorkPaneSenseView.swift` | `WorkPaneSenseView`; separate offline script-enabled WebKit host, one version-bound sense event channel |
| `WorkshopHubView.swift` | `DeskRootRoutePresentation` and `NewWorkshopTaskSheet`: root-navigation token and explicit task submission with retained draft/error state |
| `WorkshopObservatoryPanel.swift` | `WorkshopObservatoryPanel` struct |
<!-- END GENERATED BLUEPRINT -->

### Models

Directory: `Sources/NativeAgentApp/Models/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentApp/Models/ -->
| File | Owns |
|---|---|
| `ImprovementNextGenModels.swift` | `ImprovementGauntletRun.run`; app-bound process execution and bounded-run logging adapters |
<!-- END GENERATED BLUEPRINT -->

### Chrome Relay

Directory: `Sources/NativeAgentChromeRelay/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentChromeRelay/ -->
| File | Owns |
|---|---|
| `main.swift` | Chrome relay executable: authenticated browser/app handshake and opaque bounded native-message forwarding over the private socket |
<!-- END GENERATED BLUEPRINT -->

### Agent Link

Directory: `Sources/NativeAgentLink/`

<!-- BEGIN GENERATED BLUEPRINT: Sources/NativeAgentLink/ -->
| File | Owns |
|---|---|
| `NativeAgentLink.swift` | `NativeAgentLink`: authenticated local bridge client for host stdio relay and explicit replies; credentials stay out of arguments, output and persisted state |
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
| `HelperSenseRunner.swift` | Isolated plug supervision with validated progress-based stall detection excluding app-served reply waits, read-to-watch idle holds, subscription-owned lifetime and restarts; source callbacks keep newest material and signal EnginePartWake for unattended interpretation, fenced by helper generation; canonical sense disable/replacement retires only that selected lifetime's passive helpers (including unattended on-call wakes) and pending admissions; late retirement and failure reporting cannot affect a replacement, and availability reports rejected by the registry post no news, while sense-identified accepted human on-call work settles with its requesting owner; notebook access delegates to AbilityStore; versioned use and visible live failure news, sealed view events, detached site following and app change deduplication/news; app reads use assembly's Trust-admitted read closure. Live-watch reporting reads actual helper subscriptions, with presentation invalidation at their lifecycle edges. Cancellation joins the worker through settle before terminal accounting and preserves returned action receipts. |
| `OwnedProgram.swift` | Program contract separating source digest from caller/candidate version, run/face entries over the same source, and ProgramProgressWindow: shared ContinuousClock renewal, host-wait exclusion and deadlines, with independent supervisor/JSC enforcement |
| `OwnedProgramJournal.swift` | Request-owned mutable replay, receipt and read-freshness journal |
| `OwnedProgramPrelude.swift` | JavaScript app bindings and strict replay vocabulary |
| `OwnedProgramProcess.swift` | Shared helper process framing, IO and deadlines |
| `OwnedProgramRunner.swift` | lazy proof-scoped helper reuse across fixtures and decision replays with fresh contexts and journals; Invocation-bound selection/dependency proof shared until canonical catalog revision changes; shared program execution, resident helper leases invalidated by canonical ability changes/removal, and what a resident ability holds (`holding`, one broker per resident life) kept in the same slot, selected under the store lock, surviving a failed run's dropped helper; retirement closes admission and retains teardown through completion before replacement publication, and terminal quit (`endResidents`) removes the catalog observer and drains teardown; helper-owned one-second process-tree RSS sampling remains because no equivalent threshold event is confirmed; fresh per-call authority/journal and resume freshness; host calls carry the part and its input in SkillRunContext; `host.state.get/set` for tools and skills reaches AbilityStore's notebook by part id (scratch for preview/validation); skill resume replays saved state results then persists new state operations normally, without renewing stalled execution; authored tools receive frozen home/workspace paths and their requesting data root; rooted file calls resolve app_data/workspace before the door, retaining path-array listing compatibility through ordinary paging; `ReadContent` collects owner-declared envelope projections and content dependencies, sharing normalization with replay argument comparisons without changing replies; a ledger row for a batch call carries its receipts' effects |
| `OwnedProgramStore.swift` | exact authenticated rehearsal reuse with capture-input checks, without treating keep or seed seals as rehearsals; Retained ability file URLs, candidate identity, sealed rehearsal and publication through AbilityStore headers; rehearsal scopes supplied inputs and reached calls, never behavioral proof from intercepted replies; trusted bundled-seed proofs seal exact bytes without validation receipts or staging; kept proofs seal their Full Mac keeps without rehearsal; source-bound sense reads bind captured-material proof; OwnedProgramFixtures reads live and intercepts tool/routine effects and decisions; fixtures written from recorded practice (`tape: true` on every case) replay their calls alone, never captured afresh, each call matched and answered from the tape with complete consumption, and seal their `tape` coverage |
| `SenseDoor.swift` | Registry-first reads, bundled-kind ownership, exact served provenance and file-material envelopes; the admitted request owns/cancels its shared raw flight, and cancelled reads cannot cache late material; captured views retain the turn's growth refusal, discarding refused file bytes while preserving screen/site read and action snapshots; distinct private web/visible browser/group-owned Chrome provenance, same-corner act verification without re-entry, wrong-version reporting, captured native/JS site action material, Chrome envelope continuations and native screen continuation snapshots |
| `SenseNewsBoard.swift` | Durable bounded unread/recent news, deduplication, acknowledgement, storage failures and care crossing |
| `SenseScreenThings.swift` | Exact screen thing selections, captured related-action bindings on composite rows, and in-turn mac.act verb requests |
| `SensesContract.swift` | Shared sense records, wire validators, notebook bounds, native catalog, memory provenance and crossing contracts; built-in origins retain legacy spelling and provenance age formatting rejects invalid times |
| `SensesHub.swift` | Lock-protected sense installation, live-watch aggregation, exact-version view events and served/wrong-version provenance |
<!-- END GENERATED BLUEPRINT -->

### ActivityWatch

Directory: `Modules/NativeAgentCore/Sources/ActivityWatch/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ActivityWatch/ -->
| File | Owns |
|---|---|
| `ActivityPolicy.swift` | `ActivityPolicy` and `ActivityPolicyStore`: checked capture consent, exclusions, title permissions and policy persistence |
| `ActivityQuery.swift` | `ActivityQueries.run`: gated activity reads, current-policy re-filtering, bounded rows and honest truncation |
| `ActivityRetention.swift` | `ActivityRetentionRunner`: durable last-run stamp, prune deadlines and policy-selected retention |
| `ActivityRollups.swift` | `ActivityRollups`: timezone-relative buckets, top apps and exemplars; span overlap is clipped to the requested range |
| `ActivitySpan.swift` | `ActivitySpan` and `ActivityCloseReason`: persisted activity intervals, redacted titles and close vocabulary |
| `ActivitySpanEngine.swift` | `ActivitySpanEngine.process`: capture state transitions, policy gates, source title redaction and store commands |
| `ActivitySpanStore.swift` | `ActivitySpanStore`; asynchronous per-root store acquisition shared by capture, retention and queries |
| `ActivityTitleRedaction.swift` | `ActivityTitleRedaction.redact`: the source boundary that removes secrets before titles enter spans or disk |
| `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`; capture lifecycle and retained termination join of startup, policy, event, retention and watcher bodies; serialized off-main policy reads/writes and capture-ordered exclusion purges, exact policy-file invalidation and one retention schedule using the runner's completed-run stamp and effective clamped capture policy; issues join their Experience receipts, with injected platform error and notification presentation; Mac permissions, quiet controls and the menu indicator reach this same lifecycle/policy owner through engine.activityWatch |
| `ActivityWatchPaths.swift` | `ActivityWatchPaths`: one directory and file vocabulary for private ambient history, separate from activity event feeds |
| `ActivityWatcher+Foreground.swift` | The same watcher's workspace/lock observation, foreground activation, AX attachment and title reads; policy/title exclusions and motor provenance; one heartbeat/idle timer; canonical person-here events and sampled session activity resume capture without asserting presence; AX callback context lives with its observer |
| `ActivityWatcher+Policy.swift` | The same watcher's queued policy updates, tightening-only external policy reads and capture-ordered purge/wipe requests; policy reaches the engine before capture and deletion follows every older store write |
| `ActivityWatcher.swift` | `ActivityWatcher`: capture-thread lifetime, command handoff and ordered store pump; unexpected run-loop return degrades and retires capture; only the drained pump releases installation and pending restart ownership |
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
| `AgentA2ACard.swift` | `AgentPeerDiscovery` card exchange: `authenticatedInterface`, `a2aCheck` hold every A2A call and dry run to the recipe's effective card, auth and offer; `listTasks` proves 1.0 auth; `resolve` validates A2A and NativeAgent endpoints without saving contacts or sending messages. |
| `AgentACPApproval.swift` | `AgentACPApproval` enum; `connect`, `request` |
| `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` enum; helper discovery and shared execution; wake-runner process identity; OMP reply-job recovery |
| `AgentContactHealth.swift` | Shared reply-path health from the newest receipt's `no_reply_expired`, delivery failures and round trips; an app, program or recipe change since the proof is unverified, named ("Unverified since Muse updated to 7.0", "…since Hermes updated to 0.22.0", "…since the recipe changed"), with no repair; the next send or `agent.verify` re-proves. `repair` is the one repair: the contact's own send run dry (`AgentRecipeStore.dryRun`), for a send that sent nothing (`heal`: one retry of the same operation, or a harness item), and `agent.verify`, never the background check, which reads the last send's repair (an A2A contact's runs its dry run, `AgentPeerDiscovery.a2aCheck`); a desktop chat whose log changed shape after Return is filed, never retried, and a send that lands closes the contact's bridge items. Detached refreshes share one projection. Durable verification claims bound background checks to once per episode and once per contact per hour, without resend or a new poller. |
| `AgentConversationDelivery.swift` | Conversation delivery and admitted context vocabulary from retained evidence |
| `AgentConversationExchange.swift` | `AgentConversationExchange`: `started`, `absorb`, `validate`; partial text is retained separately from a finished reply; each exchange retains its receipt's shelf result UUID across subsequent sends |
| `AgentConversationFollowups.swift` | Durable queued follow-ups and cancellation |
| `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |
| `AgentConversationLive.swift` | `AgentConversationLive` struct; `projection`; the live hub flushes pending text when the resident owner stops, and already accepted sends publish later text immediately until they settle; flush identities reject superseded coalescing tasks |
| `AgentConversationPersistence.swift` | Checked conversation serialization and projection publication under the existing file lock |
| `AgentConversationPresentation.swift` | Canonical receipt interpretation and retained-history reads through AgentConversationView |
| `AgentConversationRelease.swift` | Conversation release and experience settlement; pending drains remain under one claim |
| `AgentConversationReplies.swift` | Locked retained-answer delivery, inline waits and reply settlement on the existing conversation store |
| `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |
| `AgentConversationRunning.swift` | `AgentConversationRunning` class; `begin`, `end`; retains sends by row and operation through their matching exit, including Stop waiters when a follow-up begins; retains queued senders and background conclusions through actual exit; a response timeout does not release an accepted send's owner; withdrawing queued work wakes its sender to exit; Stop joins local send settlement before retiring and joining exchange-owned desktop readers; the continuation lifecycle closes reader admission and drains settlement before closing live publication |
| `AgentConversationSession.swift` | `AgentConversationSession` owns dispatch, waits, queues, state transitions and TaskLocal history selection; `approvalRow`, `replayApproval`; `viaAbility` and `answer` (`agent.reply`): a contact reached through one of their abilities; live message waits default to 20 seconds (0–120), include held MCP sends through reply arrival, reuse conversation changes and release inline ownership under the settlement lock; explicit protocol sends share that owner; queued follow-ups wait until an inline waiter takes its answer; queued senders register for approval resolutions and execution settlements before reading, including replay failures recorded only in the approval store, and hold unsent at the one-day boundary; `clear_queue` withdraws queued and reserved messages before cancelling or joining local work; sends and Stop settle through `settle`, with no persisted stopping state or second desktop terminal writer |
| `AgentConversationStore.swift` | `save` publishes experience/live projections; `restoreProjections` replays durable state at contact startup; `records` reconciles/saves denied approvals without replaying projections; `AgentConversationDelivery.answersLive` includes live inbox readers and MCP return bridges; `offerReplyToInlineWait` and `offerBridgeReplyToInlineWait` serialize collected/inbound answers with the send deadline, recording bridge receipts before publishing inline answers and keeping them out of delayed turns and resident wakes; held answers require the sole delivered exchange in the returned conversation; `outcome_unknown` attention receipts use the session's `unsettledAttention` owner; `records` and `recordsUnlocked` project stored reply deadlines through `AgentConversationView`; reporting expiry releases the conversation without settling its retained desktop observer, which writes its terminal receipt, partial text and local release together at settlement; other reply expiry is terminal with no reply, while transport still accepts late answers; resumable work retains DataRootLife; other-life work reads stopped/restored and explicit resumption starts fresh |
| `AgentConversationView.swift` | `AgentConversationView` owns receipt and named-conversation rendering: `read`, `view`, `conversationPresentation`, `compact`, `queueProjection`, `withQueue`, `withLive`, `codingReply`, `expiringReply`; history selection stays with the session caller; `dotReply` projects Dot's existing half-hour wait from its stored send time for UI and contact reads. `claudeWorklogTail` is the shared bounded continuity/worklog reader; `claudeWorklog` exposes recent recorded work for contact reads and the read-only app action. |
| `AgentConversationWaiting.swift` | Conversation waits, interrupted recovery and approval readiness |
| `AgentDiscoverySession.swift` | `AgentDiscoveryCandidate` presents observed routes; `AgentDiscoverySession` owns discovery lifetime and offers. Launch connects settings hosts from recipes without awaiting Spotlight; index arrivals wait for any in-flight scan, recipe-location watches reconcile after arming. Saved declines/disconnects win; running hosts get one restart note. Candidate/wake setup failures name files, fields and remedies, keep dismissible offers and clear on recovery. `app.installed` signals whole bundles at new id/version pairs after a silent installed-apps.json baseline. |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter` enum; `edit` owns file transactions, backups and replacement; `checkEntry`, `writeEnvironment`, `ensureEnvironment`; absent/exact entries, same-peer reconciliation and stale-install helper replacement; foreign-entry refusal; `checking` validates without writing; removal names missing ownership receipts and preserves unproven bytes |
| `AgentHostConnection.swift` | `AgentHostConnection` enum; `builderWorkspaceRoot`, `isNamedConnect`; Connect resolves host or exact peer identity (a peer only in its own workspace; another folder is that folder's own contact), re-mints a missing key on the same contact, retires proof and rewrites only its connector entry under the settings lock; elevation remains store-owned; disconnect revokes before settings cleanup and keeps failed cleanup owed to the person through RepairOwed and fileRepairInstruction; missing helpers and secure-random failures name the defect and person; `verifySetup` stays read-only |
| `AgentHostDirectory.swift` | `AgentHostDirectory` enum; `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`; `installation.evidence` is discovery/Connect/verify's one installation check; install markers must resolve to executable files or app bundles with executable programs, never profiles; recipe `executables`, `discoveryWords`, `searchPaths` and `messagingPermissionsPath` replace inferred program names, fixed discovery words, ambient path additions and a hardcoded host permission file |
| `AgentLaneHandles.swift` | `AgentLaneHandles.migrate`: once-per-launch migration of historically read lanes into explicit contact handles; grants remain door-owned |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery` enum; `probe` discovers protocols, never names: loopback A2A cards, programs carrying ACP methods or advertising an ACP entry, and settings holding mcpServers, read from verified regular files. Recipes claim known finds; unknown finds carry a draft under an id of protocol and path. Only Agents and explicit discover probe; `Launch` admits bounded --help and initialize under the send's `agentProgramLaunch` rule (Full Mac as is, otherwise the builder sandbox, denied or locked down never). |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy`: shared A2A origin normalization, `peerFailure`, `peerAuthorizeInterface`; discovery retains its separate card-to-contact check |
| `AgentPeerStore.swift` | Canonical contact decoding, identity projections and proof; authenticated inbound proof connects hosts without a command line too. `isReady` checks route/key proof, unavailable mark and ACP startability, while `AgentContactHealth` owns version/digest freshness. `list` prepares/chmods its directory before reading; summaries retain every contact with reachability and owner trust separately |
| `AgentPeerTransport.swift` | `AgentPeerCredentials`: credential uniqueness and availability; bearer comparison delegates to `BridgeCore` |
| `AgentRecipeStore.swift` | `AgentRecipeStore` enum: one recipe per agent host under agents/recipes/, seeded from the host tables and bundled `Resources/grok-routine.json` through the existing authored-field-preserving merge, read by `AgentHostDirectory.rows`, and one per A2A contact under its id (`AgentHostRow.A2A`, `recipe(for:)` seeds a missing one on the spot); `grokRoutine(dataRoot:)` rereads the editable Grok navigation file at each setup under the store/file locks; `load`, `recipe`, `launch` (Trust's reader), `read`/`write` (the door's, one shape check, under the file lock; write can create a new host.id without overwriting existing bytes), `learn` (a dry run's findings, source "learned"), `dryRun` |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport` enum; `listen`, `reconnect`, `stop`, `readiness`; retained socket observation and helper pipes close on the delegation runner's shutdown; generation guards reject old callbacks, accepted room deliveries retain their handles until exit |
| `GrokBotRoute.swift` | `GrokBotRoute` enum; `withHistory`, `takenByWaiter`; cancellation ends the waiter handoff without resampling |
| `HelperContact.swift` | Turn-local resident contact door for this install's helper; argument routing grants no authority and the actual send remains below the existing tool gates |
| `JSONEntrySplice.swift` | Byte-preserving JSON/JSONC member splicing, validation and duplicate-key refusal over shared JSONByteScanner spans |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentConversations diagnostics |
| `PeerTrust.swift` | `PeerTrust`: installed trust reader and exact contact/principal resolution; authority follows attested doors and person grants |
| `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |
| `TOMLEntrySplice.swift` | `TOMLEntrySplice` enum; byte-preserving TOML table splicing and ownership fields |
<!-- END GENERATED BLUEPRINT -->

### AgentLinkTransport

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentLinkTransport/ -->
| File | Owns |
|---|---|
| `AgentA2AGRPC.swift` | `AgentA2AGRPC` enum; `send` projects protobuf framing and yields live updates into the peer exchange's channel |
| `AgentA2APushReceiver.swift` | `AgentA2APushReceiver` actor; `receive`, `consume`; authenticated task pushes invalidate the continuation through its canonical record writer; an owned invalidator registers before reads, replays pending hints, and retires on resident stop. Continuation startup makes saved waiting A2A task reads due after registering the invalidator, reconciling deadlines whose process-local push proof was lost at restart. The bounded mailbox retains current-process proof of delivery for each peer/task after consumption: proven push suspends sampling only after a validated task read; unavailable, invalid or thrown reads retain their short deadlines, while absent proof or an ended stream without push keeps fallback reads; GetTask stays authoritative and the one-day boundary remains |
| `AgentA2AStream.swift` | `AgentA2AStream` enum; `normalize`; shared stream accumulator |
| `AgentA2AWire+Mapping.swift` | `AgentA2AWire`: `canonicalPart`, `wirePart`, `canonicalState` |
| `AgentA2AWire+Operations.swift` | `AgentA2AWire`: `operationRequest`, `operationResult`, `normalizeTaskList` |
| `AgentA2AWire.swift` | `AgentA2AWire` enum; `selectInterface`, `messageRequest` |
| `AgentACPClient.swift` | `AgentACPClient` actor; `startupTimeoutReceipt`, `turn` (recipe-driven; no message is a dry run), `learned`; `Mismatch`: nothing sent |
| `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |
| `AgentACPProcess.swift` | `AgentACPProcess` approved spawn, process-group termination and reap |
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
| `AgentContactState.swift` | Folds validated contact projections from `AgentPeerStore` into presentation identities; labels only ACP/MCP schemes as such. `AgentLocalHealth` owns 600-second freshness and 300-second refresh spacing; exact pull-reply read receipts. Authentication recovery requires structured failure evidence for the exact observed operation; reply prose cannot erase failures. |
| `AgentConversationProjection.swift` | `AgentConversationRecord`: `sendEvidence`, `sendStatus`, `sendFailed` and `sendReceipt` project one send outcome from its receipt, with failed dispatch above stale executor progress; reply expectation defaults true; `nextReadAt` schedules reads/delivery, not reply lifetime. Associated-door history projects through Transcripts' `ContactThread.project`; resumable work retains DataRootLife; other-life work reads stopped/restored. Selected history read and UTF-8 failures propagate as unavailable. |
| `AgentWorkspace.swift` | `AgentWorkspace` enum; `dispatch` validates workspace input and routes reads and effects through their owners |
| `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback` enum; `dispatchEffect`, `followUp`. Computer readback retains the resolved recipient; unidentified recipients return unavailable rather than reading an unrelated foreground app. |
| `AgentWorkspaceActivity.swift` | Native Calendar/Reminders, shelf and shared-ledger adapters; ledger tasks and timelines carry More actions from the owner's next_offset; Today supplies checked reads and bound item/action keys to `workspace-readout.js`, including separate due-today and overdue count rows; helper selection/copy is owned by that part, not a Swift bot projection. Today starts independent Calendar and Reminders reads together in the requesting context. |
| `AgentWorkspaceApps.swift` | `AgentWorkspaceApps` enum; `quickAction`, `project` |
| `AgentWorkspaceArrivals.swift` | `AgentWorkspaceArrivals` enum; `pending`, `hash` |
| `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: `observationStamps`, `observe`, `bindCurrent` |
| `AgentWorkspaceChanges.swift` | `AgentWorkspaceChanges` enum; `evaluate`, `evaluateHumanListing`, conversation change observations through the bound owner port |
| `AgentWorkspaceConversation.swift` | `AgentWorkspaceConversation` enum; `project` |
| `AgentWorkspaceConversations.swift` | `AgentWorkSession`: verified bridge sessions, titles and contact associations; Conversations renders only through `HerScreen.conversationsRoom` |
| `AgentWorkspaceDesktopNavigation.swift` | `AgentWorkspaceNavigation`: `restoredSession`, `canEvict`, `draftAttemptIsDurable` |
| `AgentWorkspaceDesktopStore.swift` | `AgentWorkspaceDesktopStore` struct; `load`, `save` |
| `AgentWorkspaceEnvironment.swift` | `AgentWorkspaceEnvironment` enum; `isStatusReader`, `title` |
| `AgentWorkspaceFileRevision.swift` | `AgentWorkspaceFileRevision` struct; `prepare` |
| `AgentWorkspaceFind.swift` | Exact owned contact/helper, Desk, session, approval and message IDs enter their canonical readers before topic search; `project` |
| `AgentWorkspaceForm.swift` | `AgentWorkspaceForm` struct; `readingHelperSettings`, `withSchemaIssue` |
| `AgentWorkspaceHumanProjection.swift` | `HumanConversationRead` enum; `read`, `project` |
| `AgentWorkspaceKnowledge.swift` | `AgentWorkspaceKnowledge` enum; `project`, `memoryTitle` |
| `AgentWorkspaceLocation.swift` | Navigation references, action and page values; `AgentWorkspaceDocument` binds shared evidence to its source fingerprint |
| `AgentWorkspaceMail.swift` | `AgentWorkspaceMail` enum; `project` |
| `AgentWorkspaceMessages.swift` | `AgentWorkspaceMessages` enum; `project` |
| `AgentWorkspaceNavigation.swift` | Shared `AgentWorkspaceNavigation` actor requires data root and scope to restore each `Session`'s conversation arrangement and last undo receipt, never in a second ledger |
| `AgentWorkspaceOverview.swift` | `AgentWorkspaceNavigation`: `windowTitle`, `windowAction`, `window` |
| `AgentWorkspacePorts.swift` | `AgentWorkspacePorts` enum; the parts ranking the app door registers, read by the turn glance; workspace row decisions and pure helper faces enter L0 through the caller's native tool port |
| `AgentWorkspaceProjection.swift` | `WorkspacePage`: async `project` sends Music and helpers through the owned workspace part while native readers retain the other areas; record titles stay native; `AgentWorkspace` binds receipt read refs through the existing workspace name book |
| `AgentWorkspaceReadiness.swift` | `AgentWorkspaceReadiness` enum; `withSnapshot`, `filter` |
| `AgentWorkspaceSavedReply.swift` | `AgentWorkspaceSavedReply` struct; `title`, `evidence` |
| `AgentWorkspaceWork.swift` | `AgentWorkspaceWork` enum; `desk`, `continuation` |
| `AgentWorkspaceWorkOverview.swift` | `AgentWorkspaceNavigation`: `workReceiptKey`, `placeAction`, `focusWork` |
| `DelegationCaches.swift` | Read acceleration over authoritative delivery ledgers and unchanged file stamps |
| `DelegationContactEvidence.swift` | Contact-specific retained delivery evidence, lifecycle ordering and scalar interpretation |
| `DelegationReadout.swift` | Delegation read values, source availability and retained status snapshots |
| `DelegationStatusProjection.swift` | Delegation source inventory and read snapshots; retained facts preserve originating DataRootLife and unknown delivery |
| `HarnessQueue.swift` | `HarnessQueue` enum, `HarnessFinding` struct; `file`, `resolve`, `fold`: keyed findings refresh in place, preserving closure and person ownership; wake carry opportunities share the existing ledger and its retained material fingerprint, reoffering only changed work; settled experience conditions name their release |
| `HerMemo.swift` | `HerMemo` singleton retained workspace reads; file and owner lifecycle invalidations track revisions, publish completion and rebind child watches; observations share the 30-minute/128-key window, including keys without values; shutdown closes admission and cancels passive resources; serialized seen-file access, turn-pinned glances and repeated-home retention |
| `HerNamed.swift` | Their named room bindings and first-draw state |
| `HerOpened.swift` | Application-launch attribution and its observer lifetime, retired at work end or shutdown |
| `HerQueue.swift` | `MyQueueTurnProjectionProviding` protocol over cognition's Desk-revision-checked candidates and explicit refresh-pending-after-write state; `MyQueueReady` reads named experience conditions by primary key for unattended and recorded-session eligibility; `HerScreen`: `queueContext`, async `queueRows` shows those obligations, `resume` |
| `HerRoomCache.swift` | Session-scoped room bindings with bounded lasting item names and current-draw verbs |
| `HerScreen.swift` | `HerScreen` enum; `withNames`, `resolve`, compact Senses home projection and readable full senses item from registry/news and owner-reported live watches, with scoped sense changes and named corners, sharing the live built-ability line with turn context; shared home/room crew rows and worker details preserve canonical SwarmCrew liveness. Name counters and retained mappings validate; checked allocation reports exhaustion through rendering and resolution. Only a missing name book bootstraps; damaged bytes are preserved and cached executable aliases share the checked read. Home acknowledges displayed identities only, retaining hidden and capped changes. Invalid saved observation timestamps remain visible and preserved; age conversion is checked. |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom`; crews reuse HerScreen's crew rows and canonical SwarmCrew liveness, counting unknown separately from running |
| `HerScreenRooms+Build.swift` | `HerScreen`: `buildRoom`, `buildTarget`, `buildRecordRoom`. Files distinguishes unavailable enumeration from empty results and labels metadata/enumeration failures as partial coverage. |
| `HerScreenRooms+Comms.swift` | `HerScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `HerScreenRooms+Core.swift` | `HerScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `HerScreenRooms+Elsewhere.swift` | HerScreen door lines own completed other-room exchanges for the person's Mac/phone timeline and bounded words in home-turn context; peer turns never carry the person's words |
| `HerScreenRooms+Life.swift` | Native Music target bindings, status/unavailable evidence and rendering; playback narration, track/playlist curation and action labels are removed to `workspace-readout.js`; `lifeRoom` presents a failed nested Music readback with its full cause while retaining the original control receipt on its separate DONE line; `lifePulse`, `opening`; `HerItemPages` caches text without read-side peer lists |
| `HerScreenRooms+Web.swift` | `HerScreen`: `tabName`, `tabTitle`, `webTabCell`. Browser label lookup selects only actionable source labels, never nearby text. |
| `HerScreenRooms.swift` | HerScreen room rendering, names and screen interpretation; helper facts bind native identity, freshness and status; covered sessions retain lock uncertainty until wake evidence |
| `HerTouched.swift` | Retained touched-application facts |
| `HerWorld.swift` | `HerWorld` retained owner picture including contact histories and delegations, assembled from `HerMemo` projections; room acknowledgements preserve stale parts; crew notices preserve canonical SwarmCrew liveness; turn-pinned glance rendering |
| `HumanConversationIndex.swift` | `HumanConversationIndex` enum; `rows`, `list` |
| `MacScreenPreviewBus.swift` | `MacScreenPreviewBus` enum; preview resizes the source-masked observation |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentWorkspace diagnostics |
| `PrimedMoments.swift` | `PrimedMoments`: what happened while they was between turns (each line that reaches their crossing) stays primed for their next turn, the last five within twelve hours; their next own turn takes them once and asks each what it brings to mind |
| `ResidentWake.swift` | `ResidentWake`; declares its own session builder before its next turn; arrival queue/claims stamp their beginning DataRootLife; pending work from another life (no stamp is the first life) reads stopped/restored and cannot wake, hand back or accept; retained original arrival content/evidence remains visible |
| `SurfaceLayoutStore.swift` | Root-scoped layout store and `SurfaceLayoutLive`; the engine's one observed layout feeds Mac, DeviceSync, quiet Today, page index and live tour stops. `read`/`write` validate one shape/version and preserve replaced bytes; chat fold writes route through `setSurfaceExpanded`. Snapshot reads publish through `LatestRead`; PrivacyMap inventories the whole ui directory, including the previous revision. Positive persisted versions and checked increments refuse exhaustion before touching either file. |
| `ToolSignature.swift` | `ToolSignature` enum; `call`, `doorArgs` |
| `WorkContextQuery.swift` | `WorkContextQuery` struct; `matchedTerms`, `score` |
| `WorkspaceMacCall.swift` | Workspace-owned Mac calls refuse reading the agent's own app |
| `WorkspaceReadout.swift` | Frozen workspace facts and exact native item/action bindings; typed `workspace-readout.js` decisions select existing keys and labels, never manufacture targets, permissions or source status; selected helper details retain native identity and content |
<!-- END GENERATED BLUEPRINT -->

### Agents

Directory: `Modules/NativeAgentCore/Sources/Agents/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Agents/ -->
| File | Owns |
|---|---|
| `AgentBridgeCompletionRouter.swift` | Completion-route adapters and destination validation; saved let-go delivery stops at admission before asking-chat rows or dispatch; retained tasks own caller-result artifact idempotence under delivery admission; cancellation fences the append; `AgentBridgeCompletionRouter`: `validatedRoute`, `deliverAnswer` |
| `AgentBridgeSurface.swift` | Peer framing, bound turns and conversation identity, including the in-process helper sender; header names the person's live exchange view and chat.post through the existing proactive speech owner; surface names confer no authority |
| `AgentContactRoutes.swift` | Authenticated contact ingress, MCP/A2A requests, retained reply pagination (failed prose followed by its terminal cause), event waits and transport-confirmed fetch acknowledgements; A2A HTTP waits retain their worker and cancel on connection failure or stop, preserving the reply path on receive half-close without canceling the accepted canonical turn |
| `AgentContactTaskCallbacks.swift` | Persisted callback delivery and recovery |
| `AgentContactTaskReceipts.swift` | Retained task receipts, checked archive and payload compaction |
| `AgentContactTaskValues.swift` | A2A task, event and turn result vocabulary |
| `AgentContactTaskWire.swift` | A2A wire projection of retained task and stream facts |
| `AgentContacts.swift` | Root-retained contact clients, tasks, reply handovers and desktop routes; helpers of this install reach the resident through the same contact runtime with their own sender and thread |
| `AgentConversationContinuation.swift` | `AgentConversationContinuation`: durable reply reads, queued follow-ups and completion delivery through the existing delegation lifecycle; a collected answer is offered atomically to an inline send waiter before starting a delayed turn; requested helper outcomes return as one native receipt through the peer reply writer/router and arrival signal, without another model turn |
| `AgentPeerReplayClaimStore.swift` | `AgentPeerReplayClaimStore`: principal/protocol/message digest claims and retained receipts; conflicting bytes refuse and prior-life unfinished claims do not resume |
| `BridgeLane.swift` | `BridgeLane`: bridge surface spelling and agent-authorship classification, without assigning identity or effect authority |
| `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation`; saved arrivals wait on `TurnAdmission` capacity signals; only a retained typed network cause admits link recovery, and legacy untyped failed admissions migrate once to terminal; cached network-failed peer IDs gate recovery before peer/file reads; room cleanup keeps the first revised message per ID; successful recovery owns network/provider subscriptions until retirement, which releases recovery admission on failure, cancellation and stop; the delegation runner stops subscriptions with discovery and Dot socket observation; old lifecycle callbacks cannot retry admissions |
| `ClaudeBridgeDebug.swift` | Authenticated organism debug routes using the listener's existing request claim and response latch |
| `ClaudeBridgeMessageRuntime+AgentLive.swift` | `ClaudeBridgeMessageRuntime`: `agentLiveJobActive`, `handleAgentLive` |
| `ClaudeBridgeMessageRuntime.swift` | Bridge message admission/delivery and the retained chat client; replies omit working commentary at the turn's recorded boundary; an exact text reply records its durable receipt before publishing an inline answer, without starting another turn; event publication is a weak callback to the HTTP runtime |
| `ClaudeBridgeOperations.swift` | Message and tool endpoint execution under the existing listener admission and actual-exit worker lifetime |
| `ClaudeBridgeRuntime.swift` | Authenticated HTTP/contact routes and generation-ordered contact lifecycle; stop closes admission before passive cleanup, preserving accepted turns/tools; the 64-request ceiling inherited from connection admission now holds workers/actual tool dispatches until exit, beyond response deadlines; the shared human-pausable tool ceiling returns unknown on timeout without prematurely settling the tool receipt; one recovery per listener generation owns concurrent Codex/OMP children through exit, including ProcessExecution-owned helper reaping; live payload publication, retained clients and event transport |
| `ClaudeBridgeStateProjection.swift` | `ClaudeBridgeReadout` enum; `procedureStatusJSON`, `microcycleTelemetryJSON` |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` struct; claims require the pinned response run; digest-bound answer and exact return intent; remote settlement delegates to the route journal; launch/event reconciliation isolates corrupt jobs and sends settlement candidates to codex_thread_wakeup.js, the sole reply-deliveries.jsonl writer; its existing ledger.lock protects compare-and-append and producer rotation; closed peer reply findings settle covered records as let_go; caller-result admission holds the delivery lock through the retained-task append and preserves historical artifact verdicts without writing new ones; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `DesktopAgentConversationRoute.swift` | The originating app door calls `Resources/abilities/desktop-courier.js` through L0 `Parts.call` for reply-address wording and the courier's constrained tool-turn procedure. Native code serializes exact recipient/message data and retains the tool-turn owner, exact-recipient/send-evidence fence, screen/input ownership, uncertain outcomes and settlement. Grok's direct native send/reply watch remains separate; part failure stops before courier typing, with no compiled procedure fallback |
| `DesktopChatRoute.swift` | Recipe-bound conversation selection, send confirmation and learned reads; deepest exact-title entries come from one bounded postorder snapshot; MacControl owns window/subtree reads, attributes, activation, AX mutations and input construction/emission; control searches exclude the message log, and incomplete reads remain read failures through waits and delivery receipts; shared desktop observation preserves reply quiet, title and setup deadlines, including a final condition read; answered receipts name the read method and wake; uncertain delivery without automatic resend; sends and late readers preserve produced text and release their resources through `settle` |
| `DesktopRouteObservation.swift` | Existing operation-owned AX/workspace/keyboard observation, exact boundary timer and bounded unsupported-source polling |
| `GrokBotConnection.swift` | Grok connection coordination and secure Bot selection/credential transactions; unfinished contacts resume from the durable pre-submission boundary without resending an uncertain request; setup blockers retain their own remedy |
| `GrokDesktopReply.swift` | MacControl owns bounded native window/subtree reads and reply-text traversal; incomplete reads propagate to send and reply receipts; submission-owned shared desktop observation transfers once to its reply reader; a last non-answering reply must match across two idle AX reads at least 300ms apart, with one quiet-boundary read independent of notifications; the three-minute reporting deadline releases foreground ownership without claiming completion; no-notification interval observation ends at that deadline while supported events retain late-answer reach; reader settlement through `settle` saves the answer or partial with its actual read method/wake and releases observation and foreground once |
| `GrokInboundReply.swift` | Root-retained handover tasks deduplicate by message until actual exit; canonical `TurnAdmission.admittedRun` registers accepted runs for Stop/quit before session admission; `settle` writes their terminal handover result and releases ownership; the continuation lifecycle closes admission, cancels and joins them before closing live publication |
| `GrokRoutineAccessibility.swift` | Native Grok routine setup/submission/import and masked-field transfer through the existing MacControl driver |
| `HumanConversationReplyService.swift` | `HumanConversationReplies.reply`: explicit assistant replies through transcript and delivery owners; claim before mutation and no automatic replay |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Agents diagnostics |
| `NativeAgentA2AGRPCListener.swift` | gRPC loopback listener generation and endpoint publication; stop closes publication and retains the serving worker through graceful drain, excluding restart until actual exit |
| `NativeAgentA2AGRPCService.swift` | gRPC authentication, protocol/error projection and acknowledged stream delivery |
| `NativeAgentA2AWire+Parts.swift` | A2A content validation; file byte ceiling comes from Shared's `ChatAttachmentTypeResolver` |
| `NativeAgentA2AWire+Push.swift` | `AgentContactCallback` and `AgentContactPushConfig`: durable callback obligations, Keychain destination references and bounded push delivery |
| `NativeAgentA2AWire+REST.swift` | `AgentContactA2AEndpoint.handleREST`: authenticated REST binding over the shared A2A parser, task owner and projections |
| `NativeAgentA2AWire+Runtime.swift` | Contact task admission, runtime dispatch and reply/event framing; an authenticated text reply to a delivered held message enters its active inline waiter before turn admission; the same contact runtime revalidates a local helper against this install's definition, without granting peer elevation |
| `NativeAgentA2AWire+Tasks.swift` | Canonical contact task projection and record-owned accepted workers; failed settlement preserves streamed prose and offsets; transmitted reply acknowledgements route outbound evidence through AgentPeerStore.recordProof for MCP-host reply health; synchronous bridge admission closure precedes generation-ordered passive cleanup; approval/receipt observations, reply waiters/streams and push tails retire on stop, with canceled handles retained through exit; activation restores persisted owed callbacks, including terminal tasks outside live records; coalesced approval-refresh requests retain a pending pass so worker settlement and observation rearming cannot lose their wake; accepted workers and durable recovery finish independently of the listener, and explicit task cancellation remains separate; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `NativeAgentA2AWire.swift` | A2A bindings use contact task workers and a dedicated gRPC listener; turns execute through shared chat |
| `NativeAgentMCPWire.swift` | MCP negotiation, parsing, caller-supplied request identity and reply projection |
<!-- END GENERATED BLUEPRINT -->

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AppToolRuntime/ -->
| File | Owns |
|---|---|
| `AppAction.swift` | AppAction value, folded calls, argument policy and receipt effects; run receipts use broker-recorded read classes and validation has effect none |
| `AppActionRegistry.swift` | AppActions registry lookup, page inventory and policy bindings; native, authored, built-in guidance and sense actions share one inventory |
| `AppActions+Contracts.swift` | AppActions authored dependency classification, canonical contracts and persisted pin compatibility |
| `AppActions+Declarations.swift` | AppActions seed declarations, fixed input, layout vocabulary and hot actions in their catalog order |
| `AppActions+Discovery.swift` | AppActions argument guides, non-door folded schemas, call discovery, plural expansion and disabled-ability records |
| `AppActions+KeptParts.swift` | AppActions kept-part turn glance and acknowledgement; only shown fresh parts receive conditional shown markers |
| `AppActions+Ranking.swift` | AppActions find ranking; exact IDs precede named pages in declaration order, then semantic and exact-token matches with retrieval-epoch attention evidence |
| `AppChatToolDispatcher.swift` | Composed tool dispatch, Security Center admission and settled-result observers; `withAuthoredProgramHost` is the one host binding for turns and native scheduled/UI owners, retaining their originating gated reentry |
| `AppDoorActions.swift` | App action execution, version recovery and result handling |
| `AppDoorPrograms.swift` | Scripts and ordered batches re-enter the same gates |
| `AppDoorReading.swift` | Home, page, item, version and find readings through the app door |
| `AppScriptRunner.swift` | Shared-runner app host adapter, the signing key's file revision for invocation bindings, dependency shapes and ordinary turn-chain re-entry; NativeAgentSecretRedactor owns recursive credential recognition for ordinary typing and flow steps, alongside declared credential args; digest-only saved pins retain their historical encoding, while full saved contracts ignore retired scriptability metadata; an older door id or an older spelling of a part's action in a part's code resolves through `partAlias`, as a turn's call does; declarations grant no action authority |
| `AppToolExecutor+AppDoor.swift` | The `app` schema and home/page/item/find/action/actions/script dispatch; self-window `visible` resolves through the mounted presentation before ordinary page lookup; compact expandable action catalogs, read-only conversion census and preserved domain execution receipts; owns version recovery, including sense.versions; generic failures and wrong or absent version scopes use action discovery, never registry scopes as page ids; `undo` re-enters the receipted layout, recipe or setting action's gates and restores through that owner; page action lists and guides use the same originating data root as their rows, including all face-page parts on Tools; Tools reads the bounded accounting-bearing ability list with named list/source offsets |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpAllowed`, `runChromeHistory`; Chrome internal reads return one text line with read_mode none; chrome.look and DOM-inaccessible Chrome/PDF snapshot reads deliver the owned tab's bounded picture through the shared file-reader image slot, with source dimensions, explicit picture mode and raw Chrome provenance; PDF snapshots retain the unverified independent HTTP transcript beside the verified picture in one receipt; action readback preserves non-DOM receipts; history reads a private SQLite copy of Chrome's Default profile under Full Mac/file-read authority, with bounded rows and query deadline; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`: `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall` |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+Make.swift` | `AppToolExecutor` Make actions: studio ref reads/writes, intake reads and reply image attachment behind the workspace fence |
| `AppToolExecutor+MyQueue.swift` | `AppToolExecutor`: `runMyQueue`, `runHouseFile`; filing receipts report the stored owner and explicitly say when a requested reassignment was not made |
| `AppToolExecutor+PagePresentation.swift` | screenshot results and quiet page/read rendering |
| `AppToolExecutor+PartRun.swift` | `AppToolExecutor`: a part's own run (`doorPart`: Desk holds, the gated `authored.<id>` with its in-flight turn's arrival check (a message or that turn's Stop), `afterPartRun`: MY QUEUE upgrade line, runner-owned effect reconciliation and action-owned version recovery, with fresh-run calls only for no effects, a strict stop kept to resume), `doorPartPreview` retains nested value-call version pins, `doorPartResume` (optional bare/action ability id checked before claiming its checkpoint; receipts name the bare id), `partAlias` (the older skill.*/tool.* doors and older spellings of a part's action, until the release after the one that ships one-part), `doorWouldCard`; stopped checkpoints delegate to Desk’s `PartRunStore` |
| `AppToolExecutor+Photos.swift` | `AppToolExecutor`: `runPhotosRead`; read-only PhotoKit counts and recent asset metadata, with action-time macOS authorization |
| `AppToolExecutor+QuietMind.swift` | quiet mind commands and decision receipts |
| `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`: `performMacSelfAppRoute` propagates self-window look outcomes, carrying `behind` (the person's app behind their own window) onto the read; only independently verified navigation retains its success with a supplementary observation; `quietPosture`, `freshQuietPosture` |
| `AppToolExecutor+SenseMake.swift` | `AppToolExecutor` sense authoring: captured admitted material, explicit authorable corner/refusal scope, most-recent or explicitly selected read, phase timing, preview/keep lifecycle and owner-off authority without re-reading the source |
| `AppToolExecutor+Senses.swift` | Sense corner reads, served verb discovery and gated in-turn acts |
| `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`: immutable non-door schemas and independently lazy door schema via `appToolSchemas`, preserving the registry initialization boundary |
| `AppToolExecutor+UpkeepTarget.swift` | backup restore target validation |
| `AppToolExecutor.swift` | `AppToolExecutor` class; shared immutable descriptors; `execute`; chat.post routes to the conversation anchor through Reach's existing speech claim/quota; `macPersonAway` callback; a part's home arrival wakes their only through the care crossing, otherwise it waits on the news board and its receipt says so; mobileNotify owns app/bridge notification defaults, verified session binding and previews, while AttentionRouter delivers |
| `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |
| `AppToolPorts.swift` | `BrowserToolPlatformPort` struct; `QuietToolPresentationPort` supplies mounted visible-page input separately from the Advanced sidebar page |
| `ChromePageText.swift` | `ChromePageText` enum; one `VisiblePageText` shares rendered text and addressable rows with the mirror and envelope; ordered inline prose with link proofs, section-named continuation headers, `project`, `rows`, page and folded-control `next`; empty image-document reads point to chrome.look; `readDocument` adds a bounded independent HTTP PDF transcript explicitly unverified against Chrome beside its displayed picture; `contentVersion` shared by the envelope and Chrome news without rendering |
| `DoorNotesSnapshot.swift` | Task-local script inbox snapshot and nested batch versions |
| `ExistingCornersReaders.swift` | `ExistingCornersSourceProvider`: gated raw readers for screen, files, documents, connectors, private web, visible browser and Chrome; event-backed Chrome material for ordinary reads/following; `NativeChromeNews` observes from tab navigation, owns one tab-bound native reader subscription into `SenseNewsBoard`, retires it when its canonical sense is disabled/replaced, observes catalog changes only while subscriptions start/live, reports its actual tab-to-sense watches for Senses presentation, and sends capture failures to Chrome status without consuming its successful baseline |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AppToolRuntime diagnostics |
| `NativeActionRoutes.swift` | `NativeActionRoutes` enum; `runNativeAction`, `swiftNativeActionRecords`; native receipts use Browser's shared path and appendPathOwnedJSONL retention |
| `NativeAgentNotificationPostResult.swift` | Re-exports `AttentionRouting` notification result contracts |
| `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |
| `NativeSkillRegistryActions.swift` | owner-facing enable/disable through `Parts`; `enableSkill`, `disableSkill` |
| `PartThoughtTools.swift` | Restricted app-tool dispatcher for a part's thought, through its exact ToolHost and originating gate chain, with no independent effect authority; aggregates canonical nested receipt effects, including unknown in-flight effects, through thought failure/cancellation |
| `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; shared appearance and view preferences |
| `QuietChatSessionCommands.swift` | `QuietChatSessionCommands`: effect-free session fences, session operations and queued-turn receipts through canonical turn owners |
| `QuietComposerCommands.swift` | `QuietComposerCommands`: draft/model/effort/persona/speech commands through composer ports; preview and execution share admission fences |
| `QuietInboxCommands.swift` | `QuietInboxHost`: inbox fences and commands |
| `QuietSelfAdminSettings+LowerOnly.swift` | lower-only settings rows and cognition/provider controls; Mac permission reductions enforce their subset under the authority file lock |
| `QuietSelfAdminSettings+Mobile.swift` | mobile settings projection and writes |
| `QuietSelfAdminSettings.swift` | QuietSettings authority and shared validation; static-first catalog composes model, personality and bot rows in their existing order, with fresh mutation lookup |
| `QuietSetting.swift` | QuietSetting value and read/write contract, setting errors, host provider and MainActor write receipt detail |
| `QuietSettings+BotSchedules.swift` | QuietSettings bot cadence parsing and schedule rows; snapshot reads stay scoped to display and writes reread the definition |
| `QuietSettings+Models.swift` | QuietSettings model/account/effort choices and provider-group transactions; thinking and fast writes preserve model/account inheritance |
| `QuietSettings+Personality.swift` | QuietSettings personality lists, dreams and name; writes use the loaded profile and checked persistence |
| `QuietSettingsHost.swift` | `QuietSettingsHost` protocol; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |
| `QuietTrustPolicyPreset.swift` | `MobileTrustAction.Preset` policy plans, locked save and effective-policy matching |
<!-- END GENERATED BLUEPRINT -->

### ApprovalInbox

Directory: `Modules/NativeAgentCore/Sources/ApprovalInbox/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalInbox/ -->
| File | Owns |
|---|---|
| `ApprovalContinuations.swift` | Locked continuation and card claims |
| `ApprovalInbox+ChatReceipt.swift` | Approval receipt rows and healing order; transcript bytes are written through ContactThread |
| `ApprovalInbox+EffectSpend.swift` | `SwiftNativeApprovalInbox` effect spends: durable consumption immediately before execution; a spend is not an outcome or permission to replay |
| `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `loadSpends` |
| `ApprovalInbox+ProcedureExactActivation.swift` | `SwiftNativeApprovalInbox` exact procedure activation cards and decisions, bound to the saved proposal and preview |
| `ApprovalInbox+ProcedureReview.swift` | `SwiftNativeApprovalInbox.approvedProcedureReviewerDecision`: production reviewer decisions bound to candidate evidence digests |
| `ApprovalInbox+RestoreFences.swift` | `SwiftNativeApprovalInbox.mergeRestoreFences`: pre-owner restore merge of monotonic spends, resolutions and continuation facts, with unreadable-piece receipts |
| `ApprovalInbox+SkillScriptInstall.swift` | `SwiftNativeApprovalInbox.askUserToInstallScript`: exact-digest executable review cards and install bindings; every deciding surface must show saved review |
| `ApprovalInbox.swift` | `SwiftNativeApprovalInbox`; canonical checked authority storage and decision/grant facts; recordsUnlocked/list share the originating DataRootLife projection for execution and chat continuation. Old approved but unexecuted work reads stopped/restored without changing the grant or settled outcomes; resolution stamps new work; raw offline validation remains side effect free |
| `ApprovalLifecycle.swift` | `ApprovalLifecycleBus`: post-commit approval transition fan-out and host reply context; the inbox remains decision authority |
| `ApprovalRecord.swift` | `ApprovalRecord`, `ApprovalFilter`, `ApprovalDecision` and `ApprovalResolutionProvenance`; approval presentation, tolerant saved JSON reads and nullable-versus-omitted wire fields; typed decision origin without queue authority |
| `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`: verifies replay authority against canonical inbox state and effect identity before approved dispatch |
| `ApprovalStorage.swift` | Checked approval storage and legacy import |
| `ApprovalWords.swift` | `ApprovalWords.title`: shared plain-language approval names for Today and agent home |
<!-- END GENERATED BLUEPRINT -->

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalTransactions/ -->
| File | Owns |
|---|---|
| `ApprovalChatCards+Interactions.swift` | `ApprovalChatCards`: mirrors inline interactions into the person's conversation and Telegram while answers retain the origin card's identity and settlement |
| `ApprovalChatCards.swift` | Approval-card projection and notifications; transcript appends delegate to the chat owner, projection generations to ChatSessionIndexFile |
| `ApprovalReconciliation.swift` | Approval execution reconciliation and Desk settlement |
| `ApprovalReplay.swift` | Exact chat tool approval replay interpretation |
| `ApprovalSettlement.swift` | Chat tool execution and receipt settlement |
| `ApprovalSubjects.swift` | Existing proposal subject applications |
| `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects` port; `ApprovalExecution.decideBlockedWorkshopStep`; workshop-step decision/approval transaction |
| `ApprovalTransactionCoordinator.swift` | `ApprovalExecution` struct; chat/connector execution owners retain returned outcomes on save failure; a matching decision re-tap repairs only the receipt through `settle`, which owns annotation and terminal slot release; delegates execution-record claim changes to Workshop's executor and terminal browser reads to the browser owner; reconciliation cursor coverage is declared here; Desk resolution observation runs in BackgroundLoops' resident body; admitted Desk decision writes finish through `settle` |
| `ChatToolApprovalExecution.swift` | Exact execution claims and retained settlement outcomes |
| `ConnectorApprovalExecution.swift` | Connector approval replay and verified execution |
| `DeskClickApprovalFiler.swift` | Package-scoped local-click approval filing under `ApprovalTransactions` |
| `InboxCardActions.swift` | `InboxCardActions`: engagement-before-effect ordering, primary action projection and spoken/draft delivery through one inbox claim |
| `InlineDecisions.swift` | Shared inline decision card values and projection, unsupported-control handling, secret fields and Mac/quiet-page receipts |
| `InlineInteractionContinuation.swift` | Card continuation and reclamation under existing claims |
| `InlineInteractionDelivery.swift` | Inbox pointers and inline-card delivery; BackgroundLoops owns observation and cancellation; `settle` releases its notification token and joins the retained recovery scan |
| `InlineInteractionPersistence.swift` | Checked same-row persistence and originating envelopes |
| `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort` protocol; platform probes/acquisition and activation/System Settings quit events for non-polling card settlement; GrantWatch consumes them in BackgroundLoops' resident body, coalescing taps and retiring each card's refresher |
| `InlineInteractionResolver+ChatLifecycle.swift` | `InlineInteractionResolver` owns local and signed-phone control effects with retained provenance, local OS prompts, permission return checks and verified card settlement |
| `InlineInteractionResolver+MissingProvider.swift` | `InlineInteractionResolver.raiseMissingChatProvider`: setup card before provider dispatch; only text-only questions can resume |
| `InlineInteractionResolver.swift` | Control/continuation resolution uses the chat owner's transcript CAS and stopped projection; same-life stranded claims alone may reclaim/replay. The person's Resume replaces stopped continuations with fresh work without captured blocked calls. Existing setup admission, Stop settlement and slot ownership remain canonical |
| `InlineInteractionVerification.swift` | Real-world card completion verification |
| `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |
| `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedKindBackfill`, `stageKindBackfillIfNeeded` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ApprovalTransactions diagnostics |
| `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |
| `ProcedureExactActivationApproval.swift` | `ApprovalExecution`: `applyResolvedProcedureExactActivation` |
| `REMLessonOrigin.swift` | `REMLessonOrigin`: approved lesson provenance and origin moments, retaining what changed and the exchange that taught it |
| `TelegramApprovalCoordinator.swift` | `TelegramApprovalFiler` actor; Stop closes prompt admission and drains accepted units through `settle`; approval and inline sends own their response and receipt, independently of transcript mirrors and cancelled callers; recovery covers pending prompts and delivered inline cards missing settlement receipts, honoring resident-wake quiet holds for new inline prompts; matching terminal taps reach the shared resolver for receipt-only repair after identity/routing checks; per-card edits retain their receipts; nonblocking filing leaves resolution and execution to the canonical inbox; expiry guidance names from PersonaEngine |
| `WorkshopApprovalExecution.swift` | Browser and Workshop approval effects |
<!-- END GENERATED BLUEPRINT -->

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AttentionRouting/ -->
| File | Owns |
|---|---|
| `AttentionDeliveryPorts.swift` | `AttentionDeliveryPorts` struct |
| `AttentionFacts.swift` | Attention importance, origin, surface, delivery and outcome values with transport-derived delivery projection |
| `AttentionRouter+HeldDelivery.swift` | `AttentionRouter` quiet-hour holding and per-destination release; banners settle independently and unknown sends remain held |
| `AttentionRouter+Ledger.swift` | `AttentionRouter.State` deduplication ledger, event/reason digests, checked damaged-ledger reads and bounded durable persistence |
| `AttentionRouter+MacNotifications.swift` | Native UserNotifications transport, message-route binding and notification admission/receipts; fire-and-forget posts retain their handles through the OS outcome, and shutdown closes admission without joining or cancelling accepted banners |
| `AttentionRouter+Policy.swift` | `AttentionRouter` class/origin routing policy, channel switches, urgency and shared quiet-hour window |
| `AttentionRouter+RequestedResults.swift` | `AttentionRouter`: `retryRequestedResults`, `deliverRequestedResult` |
| `AttentionRouter.swift` | `AttentionRouter` sole routing and send owner: origin-bound transports, retained accepted sends, independent card settlement, closed admission at shutdown |
| `InboxPushNotifier.swift` | `AttentionRouter.notifyIfAttentionWorthy`: severity and live-root notification routing |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AttentionRouting diagnostics |
| `NativeAgentNotificationActions.swift` | `NativeAgentNotificationActions` |
| `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult`: confirmed native delivery fields |
| `NativeAgentScheduledProactiveScan.swift` | `NativeAgentScheduledProactiveScan` enum; `inboxActions`, `evaluate` |
| `NotificationChannelPreference.swift` | `NotificationChannelPreference` enum; `push`, `telegram` |
| `TriggerNotificationDelivery.swift` | `TriggerNotificationDelivery` enum; `importance`, `notify` |
<!-- END GENERATED BLUEPRINT -->

### BackgroundLoops

Directory: `Modules/NativeAgentCore/Sources/BackgroundLoops/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/BackgroundLoops/ -->
| File | Owns |
|---|---|
| `BackgroundLoopWakes.swift` | BackgroundLoopLifetimes event listeners, coalesced wakes, wall-clock invalidation, deadlines and retained wake settlement |
| `BackgroundLoops.swift` | SwiftNativeLoopScheduler registrations, timing, backoff and worker lifecycle; LoopTickAccounting settlement |
| `BackgroundLoopsManager.swift` | BackgroundLoopLifetimes registration, execution, status, resident observation and lifecycle settlement |
| `ErrorFeeds.swift` | `ErrorFeeds`: shared live error-feed inventory and bounded recent-burst scans for heartbeat and weekly improvement |
| `LoopContracts.swift` | LoopRunner and event/deadline contracts, registrations, outcomes, backoff policy and bounded tick execution |
| `LoopFailureReceipts.swift` | SwiftNativeLoopScheduler failure classification, coalesced durable receipts and result accounting |
| `LoopHistory.swift` | SwiftNativeLoopScheduler durable run/completion history, first-seen stamps, organ pulses and ordered checkpoints |
| `LoopStatusEvidence.swift` | WatchdogStatus wire encoding, scheduler LoopState, LoopStatus and event-listener health evidence |
| `ManagedLoopRunner.swift` | LoopExecutionGate and ManagedLoopRunner serialize each registration through physical worker exit and durable accounting |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundLoops diagnostics |
| `PhysiologySelfWriteRegistry.swift` | `PhysiologySelfWriteRegistry`: writer-generation suppression of watcher echoes, without time-window suppression of external writes |
<!-- END GENERATED BLUEPRINT -->

### BackgroundWork

Directory: `Modules/NativeAgentCore/Sources/BackgroundWork/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/BackgroundWork/ -->
| File | Owns |
|---|---|
| `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `streamMessages`; task-only context for `recall_judge`, `memory_interpret`, `memory_held`, and `kind_backfill`; other work honors caller-bound context assembly |
| `BackgroundWorkPorts.swift` | Background effect ports; typed content-only `AssistanceCardContent`, `BackupTrigger` and maintenance part invocation seams |
| `BodyReport.swift` | Crash breadcrumb paths and fatal-signal/process-exit logging |
| `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork` enum; `makeTelegramChatHandler`; `fileSystemPermissionNotice` passes native Speech Recognition facts to maintenance-assistance, retaining permission checks, retirement, sticky-status publication and delivery |
| `DataRootDiskHygiene.swift` | `MaintenanceBackgroundWork` stores its port and disk card identity; `DataRootDiskHygiene`, reports and daily accounting; maintenance-assistance supplies storage prose; native owners retain unavailable plan reads, saved cleanup scope, receipts and acknowledgment by finding identity; no JS under the publication lock |
| `DelegationBackgroundWork.swift` | `DelegationBackgroundWork` struct; `makeDelegationOutcomeLoop`; one owed-answer notice per peer, retires the duplicate Codex backlog card; one failed-before-answer finding per peer or human route, dated counts and bounded newest-first file refs; per-peer findings persist and refresh every covered delivery ID as a trace ref; closed peer findings settle only those IDs before reply reconciliation; Telegram's index and exact iOS events retain settlement ownership |
| `DelegationOutcome.swift` | Store-read availability and delegated outcome/liveness interpretation; terminal outcomes remain distinct from stalls |
| `DelegationOutcomeCard.swift` | One stable delegated-job inbox card and grounded resident wake text |
| `DelegationOutcomeCursor.swift` | Exact durable handled identities and receipt versions; advances only after corresponding card settlement |
| `DelegationOutcomeLoop.swift` | One delegation reconciliation/settlement runner; dry runs advance without a card or delegation settlement |
| `DeskContinuationScheduler.swift` | `DeskContinuationScheduler` actor; `nextDeadline`, `runDue`; checkpointed runs retain their process-resume owner; `prompt` calls the editable `turn-continuation` seed through L0, then inserts native checkpoint evidence into typed cue slots without sending receipt/partial-reply text into JavaScript; claims, verification and CAS stay native; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `DeskNotifyRunner.swift` | `DeskNotifyRunner`: calls the desk-notify part through the scheduled owner's originating app door; revision-checked native preparation, quiet hours and exact-deadline scheduling; direct stamps and nag consumption follow channel acceptance or durable hold, leaving failed occurrences retryable; already-held deliveries retain their native release path even when a new proposal fails |
| `DoctorAutoRunLoop.swift` | `DoctorAutoRunLoop` and configured factory; native Doctor ask eligibility and sticky cards with maintenance-assistance prose; Doctor and loop failures owe repair through DoctorReadout; config-bound loop restarts and honest outcomes |
| `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; health, dormancy and schedule interpretation of supplied manager observations, plus bounded failure-receipt parsing |
| `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |
| `DreamBackgroundWork.swift` | `DreamBackgroundWork` enum; `runDream` lives the day's owed moments (night batch drain) before the dream; `runREM` routes typed decode failures and healthy settlement to the shared finding sink; `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager` |
| `HeartbeatAssessment.swift` | Heartbeat assessment, notice and action values consumed by the existing work and loop owners |
| `HeartbeatBackgroundWork.swift` | Existing heartbeat work binding, event/deadline loop construction and age limits |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `HeartbeatDurableResidue.swift` | HeartbeatBackgroundWork durable-residue summary and idempotent review-card reconciliation |
| `HeartbeatHealthAssessment.swift` | HeartbeatBackgroundWork compact health assessment and exact age deadlines |
| `HeartbeatLoop.swift` | Event/deadline heartbeat checklist lifetime and per-condition notice settlement; missing checklist claims no health |
| `HeartbeatNoticeCards.swift` | HeartbeatBackgroundWork stable notice cards, attention delivery and inactive-condition retirement |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundWork diagnostics |
| `OffDiskBackupRunner.swift` | `MaintenanceBackgroundWork.makeOffDiskBackupLoop`; backup-cadence selects freshness and identity-change timing from native volume/metadata observations; native root protection and backup execution; canceled deadline reads publish no outcome and canceled ticks skip; actual cadence failures name the part, cause and repair lever in scheduler receipts and Doctor health; unavailable observations remain unavailable |
| `SelfImprovementProposals.swift` | Maintenance weekly-loop factory and existing staging closures; runtime approval cards bind exact reviewed code and finding identity; code findings enter the builder queue; standing lessons use REM; `SelfImprovementProposal` owns stable finding identity |
| `TelegramBackgroundBridges.swift` | Telegram memory-write bridge through the canonical memory owner |
| `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork` composes sequential jobs, bots and continuations inside the managed tick; `BackgroundLoopLifetimes` alone owns task lifetime and shutdown settlement; event/deadline runner for canonical scheduler jobs and inbox occurrences; briefing prompt and synthesis policy live in `native-morning-brief.js` |
| `TurnTraceRetentionRunner.swift` | `MaintenanceBackgroundWork.makeTurnTraceRetentionLoop`; bounded trace expiry, orphan lock sidecars and pre-compaction transcript backup retention with named outcomes |
| `WeeklySelfImprovementLoop+Evidence.swift` | Weekly chat, live error-feed and Doctor evidence; deterministic conversation sampling weighted by caring receipts; `SelfImprovementLearning`, prior-card outcomes and standing-lesson recurrence |
| `WeeklySelfImprovementLoop.swift` | `WeeklySelfImprovementLoop`: weekly/manual reservation, model synthesis, proposal validation, settlement and digest; EngineLaunch supplies Workshop outcomes through the maintenance part door; unavailable evidence fails the pass; DoctorFacade owns observed digest reads |
| `WorkshopBackgroundWork.swift` | `WorkshopBackgroundWork` enum; `makeWorkshopExecutor`, `unattendedWorkAllowed`, Full Mac unattended override |
| `WorkshopExecutorDrainRunner.swift` | `WorkshopExecutorDrainRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
| `WorkshopPumpLoopRunner.swift` | `WorkshopPumpLoopRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
<!-- END GENERATED BLUEPRINT -->

### Browser

Directory: `Modules/NativeAgentCore/Sources/Browser/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Browser/ -->
| File | Owns |
|---|---|
| `Browser+ActiveRuns.swift` | process-local run cancellation registry and attachment latch |
| `Browser+MotorReadModel.swift` | `SwiftNativeBrowserClient.motorActionReadModel`: payload-free projection from canonical runs only; Browser retains outcome and effect authority |
| `Browser+OperationStore.swift` | SwiftNativeBrowserClient's checked run-array schema, lifecycle writes and terminal vocabulary shared by reconciliation; derived receipts use appendPathOwnedJSONL, transition traces use TurnTracePersistLane with checked deduplication; local backup/export/raw phone sync excluded, PrivacyMap lists Browser Runs |
| `Browser.swift` | Browser status delegates run decoding to the operation owner and retains its existing malformed-feed error; operation/capture paths and status projection; WebKit owns website data, with no advertised data-root profile |
| `BrowserActionRoutes+DOM.swift` | DOM scripts, mutation/readiness-driven reads with one 3750ms deadline and operation-owned cancellation, result decoding and browser errors |
| `BrowserActionRoutes+IPC.swift` | authenticated IPC route decisions over window effects |
| `BrowserActionRoutes+NativeActions.swift` | `BrowserActionRoutes`: `runBrowserNativeAction`, `stringInput` |
| `BrowserActionRoutes.swift` | `BrowserActionRoutes` struct; `observeBrowserMotorAction`, `runBrowser`, direct dry-run/cancel commands to the canonical operation store, task-local `retainRead` delivery of the exact visible read capture |
| `BrowserCaptureCache.swift` | `BrowserCaptureCache`: serialized bounded storage and grouped eviction of disposable perception artifacts; expired captures require new observation |
| `BrowserIPCServer.swift` | browser IPC routing with NativeLoopbackListener and BridgeCore HTTP parsing/writing; invalid response objects close the connection; browser_ipc.json alone publishes endpoint/token discovery and Doctor readiness events, with backup/export/phone exclusions and privacy coverage; no duplicate token file writer; connection retirement cancels its routed task; deadlines report unknown effect outcome |
| `BrowserLink.swift` | `BrowserLink` struct |
| `BrowserRouteEffects.swift` | visible browser port; shared begin/finish/cancel lifecycle over BrowserActiveRunRegistry |
| `BrowserRouteModels.swift` | `BrowserRun`, `NativeActionReceipt`; failed navigation receipts expose the retained openError as detail |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Browser diagnostics |
<!-- END GENERATED BLUEPRINT -->

### ChatSessionWork

Directory: `Modules/NativeAgentCore/Sources/ChatSessionWork/`

Manual compaction on Mac, iOS and Telegram uses `ChatOrchestrationClient.compactSession`:
the same pending recollection (unrendered until distillation succeeds), transcript-generation bump and background distillation.
Foreground chat and aging share `ChatSessionAutocompactor` and `ChatCompactionDistiller`;
aging starts at 85% of the effective threshold. Both lanes fold oldest turns
until raw history is about 55% of that threshold, preserving whole user turns,
live cards/results and the dream boundary rather than a fixed row count.
At 240k, a first crossing folds about 72k of 204k tokens and keeps 132k raw;
a manual fold already below the target keeps half of its smaller raw stretch.
The 100% backstop can replace an in-flight aging source; the turn waits for its
foreground recollection and aging's prefix check discards its stale result.
Provider distillation runs outside the transcript lock. Consecutive chunks of at
most 32,000 rendered source characters distill concurrently; each block targets
1/5 of its source and accepts 1/10–1/3 (up to 10,666 body characters), plus its own
receipt/card notes, coverage and provenance. Ordinary folds retain earlier blocks
verbatim and exclude them from the prompt. All new blocks append in source order
in one durable replacement, or none do on any chunk failure. Normal expected wall
time is roughly 35–55 seconds, the slowest chunk rather than their sum, subject to
provider overhead and concurrency limits. At a needed compaction pass, a leading
recollection run above 10% of the effective window and 8,000 characters can roll up;
each selected group must exceed 8,000 characters and uses the same proportional
parallel chunks. New blocks never span the dream high-water mark, including rare
rollups; newer raw turns stay outside those rollups.
See [Turn resilience](TURN_RESILIENCE.md#8-context-compaction) for the full contract.
History projection and cross-session carryover both carry the preserved and newer
recollection spans in transcript order.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatSessionWork/ -->
| File | Owns |
|---|---|
| `CarriedAnchorRecollection.swift` | `CarriedAnchorRecollection` enum; `isEnabled`, `seeded` |
| `ChatCompactionBackupRetention.swift` | `ChatCompactionBackupRetention` enum; `enforce` |
| `ChatCompactionCommit.swift` | Verified compaction commit, pending recovery and settlement |
| `ChatCompactionDistiller+SourceComposition.swift` | Consecutive source chunks and proportional output allowances; verified-window prompt budget and first-person recollection prompt composition |
| `ChatCompactionDistiller+VoiceDiagnostic.swift` | Quote-aware third-person subject counts, advisory receipt threshold and configured agent name |
| `ChatCompactionDistiller.swift` | One checked compaction route executes concurrent chunks; all ordered blocks commit or none, with coverage, provenance and receipt notes; shared source/output bounds and 40,000-character history read allowance; Transcripts owns durable replacement/index writes |
| `ChatCompactionEvidence.swift` | Compaction trace, retained coverage and safe replacement accounting |
| `ChatCompactionPolicy.swift` | Compaction policy, outcome and honest transcript errors |
| `ChatCompactionRowRendering.swift` | Canonical compaction reading of tool row metadata |
| `ChatCompactionSelection.swift` | Compaction pass selection and recollection fold |
| `ChatCompactionStorage.swift` | Retained originals, backups and bounded backup reclamation |
| `ChatSecretRedactor.swift` | `ChatSecretRedactor` typealias |
| `ChatSessionAgingConsolidation.swift` | Append-triggered aging at 85% keeps ~55% raw history and distills proportional consecutive chunks concurrently before one ordered commit; coordinator retains bodies and 300-second cancellation deadlines, releases claims only at body exit, closes admission and joins admitted bodies and deadlines at engine termination |
| `ChatSessionAutocompactor.swift` | Aging at 85% folds oldest raw history toward 55% of the effective threshold, retaining earlier blocks and live cards; rare dream-safe rollups above 10% of the effective window; ContactThread owns verified-backup replacements and original-history bytes; config owns `effectiveWindowTokens` and `contextWindowReadout` |
| `ChatSessionDirective.swift` | `ChatSessionDirective.recordURL` uses canonical session path validation; seven-day delivery eligibility leaves expired/delivered records on disk |
| `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` selects repairs and commits through ChatSessionIndexFile |
| `ChatTranscriptEvidenceRendering.swift` | historical receipt reconstruction, recorded tool outcomes and attachment evidence; voice history renders the retained utterance and original audio reference; re-exports ChatToolParsing's shared result classification |
| `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |
| `ContextBudgetPolicy.swift` | Shared model-input budgets for every door; `compactionHistoryCharacters`, `floors`; derived budget reuse by exact effective window after current model/catalog resolution |
| `HistoryWindowCursor.swift` | `HistoryWindowCursor`, `HistoryWindowCursorStore`; locked reads validate nonnegative representable counters; checked advances preserve stored bytes on failure; row/character hysteresis persists only changed boundaries |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatSessionWork diagnostics |
| `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore` struct; `record`, `recordConversationContinuation`; the locked validation supplies physical rows and append bytes to shared retention |
| `OutcomeTissueV2.swift` | `OutcomeEvidenceState` enum |
| `OutcomeTraceIdentity.swift` | `OutcomeTraceIdentity` enum; `normalized` |
| `SentTurnContext.swift` | Exact user-leading delivery and complete-state metadata; ordered paragraph replacements against the preceding replayed state, with route/window keyframes and optional locked user-row persistence; human content stays unchanged |
| `SessionDigestProvider.swift` | Participant-bound prior-conversation selection and frozen handoff; `pointerSentence`, `digest`; peer identity is independent of session-id shape |
| `SessionHistoryMessageProjection.swift` | `admission` counts exact sent user text and context blocks; `project` replays nonempty blocks on their user rows without rewriting their bytes, omits empty text for captionless images and returns delivered row identities, retained keyframes and the window identity |
| `SessionHistoryPromptRenderer.swift` | `renderDetailed`, `recallQuery`: message text retains bracketed headings; sent context metadata remains separate from speech/relevance and is read only by structured replay |
| `SessionHistoryReader.swift` | `SessionHistoryReader` actor; `promptMessagesWithStats` retains the cursor boundary regardless of raw bytes/rows; `messages`, `messagesWithStats`; initialization leaves retired middle-index files untouched |
| `SessionMessageProvenance.swift` | `SessionMessageProvenance` |
| `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearchResult`, `TranscriptSearchResponse`, `TranscriptSearch` |
<!-- END GENERATED BLUEPRINT -->

### ChatToolParsing

Directory: `Modules/NativeAgentCore/Sources/ChatToolParsing/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatToolParsing/ -->
| File | Owns |
|---|---|
| `ChatToolOutcome.swift` | exact/display result classes, explanation and common waiting/failure predicates; `projection` gives folds and expanded receipts one interaction-metadata precedence; below ApprovalInbox so readers share classification without importing session persistence |
| `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |
<!-- END GENERATED BLUEPRINT -->

### ChatToolRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatToolRuntime/ -->
| File | Owns |
|---|---|
| `AgentContactACP.swift` | ACP launch, execution and live updates |
| `AgentContactCancellation.swift` | Contact transport cancellation and unknown outcomes |
| `AgentContactCommand.swift` | Contact command execution through admitted transport |
| `AgentContactConnection.swift` | Named contact connection and disconnection |
| `AgentContactPresentation.swift` | Retained contact and conversation history projection |
| `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding` enum; `pending`, `glance`; workspace tool port derives bounded built/recent ability names from canonical tool, skill and sense availability |
| `AppRestartCoordinator.swift` | Shared detached native relauncher observes parent exit before opening; tool restart audit/cooldown, originating-turn settlement with a 60-second stalled-turn bound and 120-second exit deadline; operator menu/restore 60-second deadline covering the whole quit (turn wait, their sleep, termination drain); stalled quit aborts relaunch |
| `BotChatContract.swift` | Helper identity, personality, job/output instructions and checked provider choice; helpers follow Chat unless explicitly pinned |
| `BotRunConversation.swift` | `BotRunConversation` enum; `enqueueRequestedCheck`, `dispatch` |
| `BuilderAudit.swift` | Redacted builder audits and bounded retention |
| `BuilderInstaller.swift` | Installer launch, helper lifetime and settlement |
| `BuilderPatchExecution.swift` | Patch admission and native execution through the dispatcher |
| `BuilderPatchGrammar.swift` | Patch grammar, path authority and range-less application |
| `BuilderProcess.swift` | Process launch, environment and confinement |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator` actor; `resolve`, `bind`; allocation reserves config root/agent/conversation before suspension and waiters reread the winning assignment; checkout reservations exclude reuse/allocation/binding from retirement through Git awaits, with freshness reread while held; unreadable or invalid retained pointers refuse continuity with the exact field and fileRepairInstruction for the person, never a coding-agent repair call |
| `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas`, `inboxOptionsSchema` |
| `BuiltInToolSchemaFactory+BridgeSchemas.swift` | `BuiltInToolSchemaFactory`: `bridgeSchemas`: Claude, OMP and Codex |
| `BuiltInToolSchemaFactory+CollaborationSchemas.swift` | `BuiltInToolSchemaFactory`: `collaborationSchemas`: workshop, shared task ledger and delegation status |
| `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
| `BuiltInToolSchemaFactory+DeskSchemas.swift` | `BuiltInToolSchemaFactory`: `deskSchemas` |
| `BuiltInToolSchemaFactory+DreamSchemas.swift` | `BuiltInToolSchemaFactory`: `dreamSchemas` |
| `BuiltInToolSchemaFactory+FileSchemas.swift` | `BuiltInToolSchemaFactory`: `fileSchemas`, canonical `context_expand` descriptor |
| `BuiltInToolSchemaFactory+HistorySchemas.swift` | `BuiltInToolSchemaFactory`: `historySchemas` |
| `BuiltInToolSchemaFactory+InnerStateSchemas.swift` | `BuiltInToolSchemaFactory`: `innerStateSchemas` |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |
| `BuiltInToolSchemaFactory+MemorySchemas.swift` | `BuiltInToolSchemaFactory`: `memoryReadSchemas`, `memoryWriteSchemas`, `memoryReviewSchemas` |
| `BuiltInToolSchemaFactory+PersonaSchemas.swift` | `BuiltInToolSchemaFactory`: `personaSchemas` |
| `BuiltInToolSchemaFactory+PersonalAppSchemas.swift` | `BuiltInToolSchemaFactory`: `personalAppSchemas`: calendar, reminders, notifications, Spotlight, contacts, Mail, Messages, Notes and Music; bridge declarations retain their place in the sequence |
| `BuiltInToolSchemaFactory+SchedulerSchemas.swift` | `BuiltInToolSchemaFactory`: `schedulerSchemas` |
| `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |
| `BuiltInToolSchemaFactory+StudioSchemas.swift` | `BuiltInToolSchemaFactory`: `studioSchemas`: consultation, shelf, journal, recall and canon; dream declarations retain their place in the sequence |
| `BuiltInToolSchemaFactory+TurnSchemas.swift` | `BuiltInToolSchemaFactory`: `turnSchemas`: result paging, interaction, images, context, scratchpad, time, traces and swarms |
| `BuiltInToolSchemaFactory+WebSchemas.swift` | `BuiltInToolSchemaFactory`: `webSchemas`: maps, routes, web search and page reads |
| `BuiltInToolSchemaFactory+WorkspaceSchemas.swift` | `BuiltInToolSchemaFactory`: `workspaceSchemas` |
| `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory` struct; `schemas` composes domain declarations in catalog order; lazy `requestedSchema`; common constructors come from `PersistenceCore.ToolSchema` |
| `CanonicalToolNameDispatcher.swift` | `CanonicalToolNameDispatcher` class; `canonical`, `dispatch` |
| `ChatFullMacYoloAdmission.swift` | `ChatFullMacYoloAdmission` enum; `admitted` |
| `ChatHistoryIndex.swift` | SQLite-owned content-addressed history; on-demand rows and receipts, semantics-versioned cancellable absorption, transactional manifest reference reclamation |
| `ChatHistoryMessage.swift` | Verbatim persisted messages, including boilerplate hidden by search, and bounded receipt pages |
| `ChatHistoryProjection.swift` | Persisted row and explicit receipt projection; ordinary turn recall never injects tool metadata |
| `ChatToolDispatchTrace.swift` | `ChatToolDispatchTracer`: dispatch timing, redacted receipts and file-touch evidence; turn-bound receipts record act experience and repair attribution; nominated practice calls keep one redacted tape row with exact paths, steer and call-end sequence, built off the dispatch path (`TurnPractice`), every other call none |
| `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction`: typed argument redaction; `redactedResultJSON` parses once, strips screen pixels then injected values and encodes once; malformed screen-only text passes through, malformed injection-shaped text is suppressed |
| `ChatToolOutcome.swift` | `ChatToolOutcome` runtime extension: failure normalization, waiting/effect evidence, refusal interpretation, cognitive grading and repair operation identity; uses ChatToolParsing's exact result classification |
| `ChatToolRuntimeImports.swift` | Re-exports `ChatTurnContracts`, `AgentConversations`, `AgentWorkspace`, `ChatSessionWork`, `ChatToolParsing` |
| `ChatToolSessionInjection.swift` | `ChatToolSessionInjection`: explicit-input extraction, verified-session → tool-loop-session selection and shared internal/tool-specific session injection |
| `CodexImageGenerationControls.swift` | `CodexImageGenerationRequest`: `normalizedForBuiltIn` |
| `CodexImageGenerationHelp.swift` | `CodexImageGenerationHelp` enum |
| `FluidContextToolScope.swift` | `FluidContextToolScope` enum; expanded memory pages retain stored untrusted sources |
| `GitHubCommandCheckoutResolver.swift` | `GitHubCommandCheckoutResolver` enum; `resolve` |
| `HarnessDecidedRow.swift` | `HarnessDecidedRow`: rolling per-requester/tool decision visibility without push; info writes stay off the tool gate's path |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | `InlineInteractionRegistry` enum; `connectorSetup`, `canonicalConnectorID` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatToolRuntime diagnostics |
| `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher` class; `peerApproval` shares live trusted-turn and peer-floor decisions between preview and execution; a peer-steered lifecycle write asks its one command card at the gate like any effect, and the ability stores refuse it until that card is answered; memory notes retain origin attribution checks; read results keep source labels without collecting steering peers or quoted lines |
| `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`: `impl_tool_result_page`; retained-response search coverage, matching/displayed/remaining counts and source-positioned matching records |
| `StudioCanonProposal.swift` | `StudioCanonProposal`: compatible approval payloads, pending cap, action/work and evidence-fingerprint dedupe; resolved cards append idempotently only with their seat and live-turn provenance |
| `StudioCanonSeatGate.swift` | `StudioCanonSeatGate`: trusted live-turn identity and matching runtime surface for canon authority; production pulls share the live-turn gate and projection's taste-judgment admission |
| `StudioCanonTending.swift` | `StudioCanonTendingReport`, `StudioCanonTending`: native evidence reads and transactional proposal staging retain pending/pass caps; unavailable sources throw; relation audits persist without repair or blocking |
| `SwiftCodexImageGenerationClient.swift` | Codex image request/result values and process transport; isolated workspace, allowlisted environment and exact-thread raster collection; Stop settles captured output and produced images |
| `SwiftOpenAIImageGenerationClient.swift` | OpenAI image request/result values and HTTP transport; default-deny admission, API credentials and named response failures |
| `SwiftToolDispatcher+ActivityQuery.swift` | `SwiftToolDispatcher`: activity-query discovery, argument parsing and named failures; capture policy and actual-origin authority admit bounded local history answers |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: driven-agent launch admission, executable rebinding, cwd authority and wake-helper execution |
| `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `builtInAgentLaneUsable`, `impl_agentCommunication`; command settlement joins its output consumer before reading replies and releasing its directory/probe; physical launch, exit success and proven delivery remain separate, launched unanswered commands retain unknown delivery |
| `SwiftToolDispatcher+ArtifactContext.swift` | `SwiftToolDispatcher`: artifact recall through the canonical hot/archive transcript inventory, deduplicating retained messages and reporting unavailable or sampled evidence |
| `SwiftToolDispatcher+BuilderConversation.swift` | `SwiftToolDispatcher`: builder conversation handles, topic spelling and inbox/wake/receipt projections |
| `SwiftToolDispatcher+BuilderInbox.swift` | `SwiftToolDispatcher`: message-ID admission, locked deduplication, durable inbox append, quarantine evidence and explicit wake retries |
| `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots`; workspace-default shell cwd and explicit pre-launch/executed receipts; certified shell reads use the Git reader's fixed argv/environment/sandbox; `builderLaunch`, the one way a command line starts (sandbox, starting folder, SwiftPM shim) for the shell tools and a part's program; builder and detached installer terminal audits run in SubprocessWork settlement |
| `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage` |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | Explicit history search selection and ranking; coverage honors parse validity and cached structure; chronological digests retain true first/last instants |
| `SwiftToolDispatcher+ClaudeBridgeTools.swift` | `SwiftToolDispatcher`: `runClaudeMessage`, `markWakeStartedNothing` finishes shared wake receipts |
| `SwiftToolDispatcher+CodexBridgeTools.swift` | `SwiftToolDispatcher`: `codexBrainControls`, `agentBridgeReplyOrigin`, `runCodexMessage`; inbox admission delegates to `codex_wake_inbox_projection.js`, the sole inbox/history mutation owner, with the helper's directory lock; SubprocessWork settlement retains partial replies and writes the terminal audit and Runs projection |
| `SwiftToolDispatcher+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, bounded anchored `impl_recent_trace_summary` pages; receipts span conversations by default, rank non-read actions first and scan complete retained since windows; `trace.usage` and `trace.model_calls` share this route and `TurnTraceRecentReader` for recorded sums, purpose counts and retention coverage; explicit session filters and bound turn refs |
| `SwiftToolDispatcher+DelegationTools.swift` | `SwiftToolDispatcher`: `impl_delegation_status`, `delegationStatusLimit`, `delegationStatusOffset` |
| `SwiftToolDispatcher+DeskNotifications.swift` | `SwiftToolDispatcher`: item notification preferences and explicit nag controls; permanent-handle scopes, mute windows, proposal validation and unmute drift settlement |
| `SwiftToolDispatcher+DeskPlans.swift` | `SwiftToolDispatcher`: Desk plan construction; stable-handle reuse, validated batch-position dependencies, ordered child writes and explicit partial-write reporting |
| `SwiftToolDispatcher+DeskReadout.swift` | `SwiftToolDispatcher`: live and archive Desk reading through the existing store; canonical row paging retains all fields independent of sort and carries archive continuations |
| `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`: ordinary Desk mutations, shared store and handle/argument methods; person waits use existing status fields, dependency waits retain their conditions, and close resolves holds once while retaining closed children on conflict |
| `SwiftToolDispatcher+DesktopPixels.swift` | `SwiftToolDispatcher`: `desktopPixelsRequested`, `desktopPixels`; screenshot saving uses cancellable SubprocessWork and settles observed saved paths exactly once without model pixel delivery |
| `SwiftToolDispatcher+Dispatch.swift` | One normalized dispatch ingress, pure argument validation and part-write receipts with unchanged routes and artifact results |
| `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |
| `SwiftToolDispatcher+FileAdmission.swift` | `SwiftToolDispatcher`: file-root admission, bundled document reads, Full Mac access projection, local connector execution and file-result errors; connector work preserves call-scoped image and source-material context |
| `SwiftToolDispatcher+HumanConversations.swift` | `HumanConversationSnapshot` struct |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`: image generation, display and references; checked routing failures propagate without a model-choice card; Codex settlement preserves captured output and produced images through Stop, then writes one terminal receipt; successful responses normalize to ok for Make registration while stopped receipts stay stopped |
| `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |
| `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`: `impl_search_kg`, `kgSeenDate`; failed semantic recall or graph hydration returns partial search with the checked read's cause |
| `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |
| `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`: one Mac integration invocation selected by `MacIntegrationGates.byTool`, with Mail binding before admission, backend execution after admission and result observations afterward; due-reminders carries the dispatcher's data root; read-only MapKit routes with every step, segment-distance meaning and explicit no-traffic timing; radius-bounded place search splits inline near/in/around locations and reports the split; distance-fraction lookup shares place/describe |
| `SwiftToolDispatcher+MacVerbs.swift` | `SwiftToolDispatcher`: four-verb arguments and execution, screen-watch admission, clipboard, menu, document and input routes; implicit point acts use MacImageFrames' newest session image, acquiring the first through mac.look pixels:true before input; explicit unknown image references remain refused |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` retain provenance on readback (a read steers nothing); `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`: counted/capped recall and versioned record pages, `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata` |
| `SwiftToolDispatcher+OMPBridgeTools.swift` | `SwiftToolDispatcher`: `runOMPMessage`, `ompSessionSaved` |
| `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`: persona read/write tools; introspection separates durable bundle/build/data-root identity from launch ids and names the surface/model/effort route and context-budget owners; get-persona-document truncates at a valid UTF-8 scalar boundary within its 64 KiB source cap |
| `SwiftToolDispatcher+ProposalReview.swift` | `SwiftToolDispatcher`: `impl_memory_proposals_pending`, `impl_memory_proposal_review` |
| `SwiftToolDispatcher+Reach.swift` | `performReach`: `programReach`, a part program's shell access check and launch plan |
| `SwiftToolDispatcher+RemoteNodes.swift` | `SwiftToolDispatcher`: remote node listing and execution; admission refusals stay distinct from cancellation and transport failures with unknown effects |
| `SwiftToolDispatcher+Senses.swift` | `SwiftToolDispatcher`: sense corner resolution and authorized raw material adapters |
| `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher`: `standingBotApprovalReason`, `standingBotsArgumentRefusal`, `impl_standingBots` |
| `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`: `impl_studio_canon`, `impl_studio_canon_resolve`; canon membership and proposal reads, agent-only live-turn resolution and idempotent action results |
| `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`: `impl_studio_shelf`, `studioImageInvitation`, `impl_studio_consult`; journal refresh holds the existing journal flock from read through graph commit and audit |
| `SwiftToolDispatcher+SubprocessSupport.swift` | `SubprocessWork` owns launch admission, verified process tree, timeout and physical exit; Stop freezes and kills the effect tree immediately, then `settle` releases descendants and runs the adapter's one output/audit settlement; shared bounded invoke/image pipe capture with adapter-specific limits and decoding |
| `SwiftToolDispatcher+SwarmTools.swift` | `SwiftToolDispatcher`: `impl_agent_swarm` |
| `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: exact `jsonInt` |
| `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file` (window parsing, ceilings and omitted defaults belong to `FileSystemActions`), `fileReadPresentation`, shared `impl_file_metadata` for list/info, `impl_trusted_file_mutation` (workspace writes and Trash) |
| `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |
| `SwiftToolDispatcher+WorkContext.swift` | `SwiftToolDispatcher`: `impl_work_context`, `workContextDeskItem`, `boundedWorkContextValue` |
| `SwiftToolDispatcher+WorkshopTools.swift` | `SwiftToolDispatcher`: Workshop submission/status and the separately labeled, paged shared task ledger; explicit compiled requests retain their declared route and report activation/preflight failures without model planning |
| `SwiftToolDispatcher+WorkspaceDesk.swift` | `SwiftToolDispatcher`: `workspaceDesk` projects every board item through one paged row shape, preserving fields across recent/stale ordering and carrying limit/sort in continuations |
| `SwiftToolDispatcher.swift` | Native dispatcher construction; capability-filtered schema factory owns native catalog membership; authored projections share AbilityStore's checked ToolRecord projection and exact catalog revision; named schema construction consumes parsed registry rows and selects before encoding |
| `ToolApproval.swift` | PreApprovalToolValidating contract and SwiftToolDispatcher refusal/proposal wording before approval admission |
| `ToolArguments.swift` | Canonical named-schema argument admission preserves required nulls, false and the current normalized invocation |
| `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |
| `ToolResultSections.swift` | `ToolResultSections` enum; `pages`; complete line/value records, search records first and then shortest fields first (a result's verdict before its bulk), source-order query selection, oversized structured records expand by child path; raw references remain for oversized atoms |
| `VisualContinuity.swift` | `VisionLiveSceneSnapshot` struct and `SwiftToolDispatcherFourVerbLiveScene` actor; dispatcher-owned temporal identities, motion hypotheses and occlusion tracking |
| `WindowObservation.swift` | `SwiftToolDispatcherFourVerbPerceptionSource` struct; native masked window observation, structural and visual recognition, live preview and obstruction exclusion |
| `WindowPixels.swift` | `FourVerbPixelAttachment` class; call-scoped captured pixels, region cropping, attachment deduplication and bounded JPEG delivery |
<!-- END GENERATED BLUEPRINT -->

### ChatTurnContracts

Directory: `Modules/NativeAgentCore/Sources/ChatTurnContracts/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatTurnContracts/ -->
| File | Owns |
|---|---|
| `ChatApprovalContracts.swift` | `AutonomyDecision` enum |
| `ChatPersistenceContext.swift` | Request-scoped transcript intent, declared conversation kind and exact session owner; exact assistant/question replacement identities, provenance and imported-message bindings |
| `ChatToolBridges.swift` | `PureToolArgumentValidating` protocol; `argumentRefusal`; MacIntegrationToolBridge requires the requesting data root for due-reminders |
| `ChatToolSessionContext.swift` | `ChatToolSessionContext` enum; `rendersInlineCards`, `withReplyRoute`; `TurnEnvelope.workIdentity` carries attribution, `answerExperienceID` carries the owed answer through continuations; neither grants authority |
| `ChatTurnExecution.swift` | `ChatTurnExecution` class; `bindHistoryRunID`, `keepCapabilityNote` |
| `PeerDataTaint.swift` | `PeerDataTaint` class; `withScope`, `mark` (latches any sender the owner does not trust, recognized or not, but their own `self` and bots), `markConsumed` (latches nothing: a read steers nothing), `elevate` (the person answered the run's card); one restore initializer retains provenance and answers without a read-latch marker; ability write refusal reads current origin principal and live/carried peer steering |
| `SwarmChatClientFactory.swift` | `SwarmChatClient` supplies inherited workers and their trace bus directly to the executor; `SwarmChatClientFactory.makeClient` retains chat-owned construction |
| `ToolDispatchRecord.swift` | `ToolDispatchRecord` struct; retains the call resolved before execution for outcome attribution and argument evidence |
| `ToolNoticeBus.swift` | `ToolNoticeBus` enum |
| `ToolTurnContracts.swift` | `ToolDispatchClient`: `dispatch`, `listAvailableTools`, `listAvailableToolSchemas` |
<!-- END GENERATED BLUEPRINT -->

### ChatTurnRuntime

Chat consumers import the symbol-owning modules directly; the re-export-only
`ChatOrchestration` target is dissolved.

Directory: `Modules/NativeAgentCore/Sources/ChatTurnRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatTurnRuntime/ -->
| File | Owns |
|---|---|
| `AfterReply.swift` | `AfterReply`, `SwiftNativeTurnEngine.afterReply`: saved-answer release, recording before start, abandonment release and retained private flights through once-only settlement, surviving conversational Stop |
| `AgentConversationsExports.swift` | Re-exports `AgentConversations` |
| `AgentWorkspaceExports.swift` | Re-exports `AgentWorkspace` |
| `ApprovalActionText.swift` | `ApprovalActionText`: approval action/reason presentation; original arguments remain execution authority |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`: type/size admission, bounded off-main file reads and voice draft attachments |
| `ChatGeneratedImageArtifacts.swift` | `ChatGeneratedImageArtifacts`: reply attachment projection from actual generation receipts and explicit reply choices |
| `ChatLiveTap.swift` | `ChatLiveTap` enum; `observe` (every turn's deltas and saved answer, for the phone) |
| `ChatOrchestration+AfterTurn.swift` | `SwiftNativeTurnEngine`: owed memory recording and serialized retained interpretation; predecessor tasks settle before current-handle cleanup |
| `ChatOrchestration+AutonomyGate.swift` | `AutonomyGate`: TrustCenter autonomy resolution and approval filing before concrete tool dispatch |
| `ChatOrchestration+CameToMind.swift` | `SwiftNativeTurnEngine.cameToMind(after:turn:held:sessionId:surface:)`: what a round's results said is a moment; the memories it singles out (by the turn's own rule, `ContextPreparedTurn.cameToMind`) join their conversation as memories, at most two a round and four a turn, traced as `mind.came_to_mind` |
| `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop`, closing expansion predictions through `Expansion.withTurn` after the whole turn, including deferred after-reply work or its abandonment; `TurnCheckpointScope`, serialized `TurnCheckpointWriter`; same-turn transcript/receipt recovery and finished-run cleanup |
| `ChatOrchestration+CurrentTurnFacts.swift` | `SwiftNativeTurnEngine`: frozen current facts, runtime/contact availability, dynamic composition and provider-accepted delivery bookkeeping |
| `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: `buildTurnContextWithHistory` pins selection to the persisted window before row/character advancement; exact sent user context and keyframe/window metadata replayed from the row; history and digest gathered for their turn part; `fireAssemblyStageEvent`, `injectingSessionDigest` |
| `ChatOrchestration+Streaming.swift` | `TurnStreamEvent`: reversible streaming display and transient tool notices; never durable reply or terminal evidence |
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: runs their turn part's effects, hands it each event with each result's declared effect, logs at every host-call boundary; the turn returns at `reply.end` and `after`, and effects after them run privately on the same turn id, never streamed, saved to the conversation or checkpointed), `joinedProse`; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated, on the closing `model` event as `repeated`): `took` is the after-turn line, and each part called records its rounds |
| `ChatOrchestration+ToolDispatch.swift` | Shared per-iteration tool dispatch and refusal of unoffered folded calls; retains the actual tool body inside its deadline scope, cancels the effect and joins its settlement before closing the dispatch checkpoint |
| `ChatOrchestration+ToolLoop.swift` | `TurnContext`: `withToolSchemas`; `finishReplyTurn` settles reply.end, including incomplete work; ContextFlow's `.completed` records this loop exit; tool rounds distinguish Stop, control return and failed observation; failed handback waits end the turn without resuming, and the return nudge requires current driver permission |
| `ChatOrchestration+TurnEngine.swift` | SwiftNativeTurnEngine actor dependencies and retained task lifetimes |
| `ChatOrchestration+TurnReach.swift` | `SwiftNativeTurnEngine`: packet, recall and stable-persona rendering; memory selection explanation and exact delivered recall identities |
| `ChatOrchestrationClient+AttachmentEvidence.swift` | `CodexCompletionTranscriptEvidence`: exact completion binding and saved attachment recovery; transcript/queue attachment writer and speech corrections |
| `ChatOrchestrationClient+Attachments.swift` | image/document admission and voice evidence projection; audio remains an attachment, never a provider content block |
| `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `chat`, `chatExecution`; `StructuredChatExecution` carries the response and typed success/failure; `withCurrentChatModel` admits the current Chat pick at a wake's `model.call`, so a run that never thinks needs no model; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |
| `ChatOrchestrationClient+DispatchWrappers.swift` | `FileAccessGatedDispatcher` class; `preApprovalRefusal`, `approvalCardReason`, `sharedFileAccess`; carries the chain's file access to the organs and refuses only an unrecognized mode and a pathful read under `none` (no tool-name lists; admission is posture × declared class in TrustCenter); peer approval uses the declared class without an external-tool resolver; `AutonomyGatedDispatcher` audit rows that fail are owed repairs |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn`, `runPartToolTurn`; prepared part messages enter the same canonical loop and admitted routing with caller limits, restricted tools and taint, without persona/recall assembly, parent checkpoints or after-turn mind work; every exit joins answer/heard settlement with retained prose and dispatch artifacts; interrupted errors keep partial output and distinguish Stop; explicit part-thought surfaces admit their saved route without the parent's ProviderTurnChoice, omitted surfaces inherit; PartToolThinkingContext marks only that internal thought |
| `ChatOrchestrationClient+Factories.swift` | `makeChatOrchestrationClient`, `makeGatedToolDispatchClient` (outermost node `ExpansionDispatcher`), the factory shares its injected clock with engine and chat client; uses ProviderRouting’s canonical provider assembly; stall-only calls share a transport without a resource wall; `SwiftNativeMemoryV2Recaller`: disclosure-aware recall and served-hit credit |
| `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`: `appendHumanConversationReply` binds its checked conversation destination once before append |
| `ChatOrchestrationClient+InteractionTranscript.swift` | `SwiftNativeChatOrchestrationClient`: tool/approval/card rows, same-row CAS, supersession and exact replay witnesses; one shared durable append and receipt redaction policy |
| `ChatOrchestrationClient+LivedObservations.swift` | `SwiftNativeChatOrchestrationClient`: persisted incoming-turn origin and bounded redacted message/tool/progress cognitive events with explicit authorship |
| `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`: durable message append/replacement, partial/failure settlement, contact sends/imports and session-index publication; exact row identities and source keys from bound delivery identity |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `contextFingerprint`, `iso8601` |
| `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`: `chatStream`, `chatStreamExecution`; `ChatStreamExecution` joins or cancels its producer Task's settled result |
| `ChatOrchestrationClient+StructuredChat.swift` | Accepted turn ingress and execution with captured run identity, carried offers and prepared cognitive context; effect completion joins canonical turn settlement |
| `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |
| `ChatOrchestrationClient+ToolReceipts.swift` | `SwiftNativeChatOrchestrationClient`: `persistToolReceipt` |
| `ChatOrchestrationClient+Types.swift` | chat response, progress and enqueue receipt values |
| `ChatSessionWork.swift` | Re-exports `ChatSessionWork`; `SwiftNativeChatOrchestrationClient` history preparation, automatic/manual compaction and transcript-aging integration |
| `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |
| `ChatToolRuntime.swift` | Re-exports `ChatToolRuntime`, `ChatTurnContracts` |
| `ChatTranscriptLineCountCache.swift` | `ChatTranscriptLineCountCache`: bounded stat-validated counts; writers establish deltas under the transcript flock |
| `ChatTurnEvidence.swift` | Produced turn evidence and durable answer/owner-turn stamps; records retain their existing locks and formats |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`: `chat` supplies explicit provider choice, aggregate token budget and mechanical-row provenance; ordinary turns settle without requiring a token budget |
| `ChatTurnFailure.swift` | `ChatTurnFailure`: failure metadata and retry-confirmation classification from the turn's own dispatch/effect evidence |
| `ChatTurnSettlement.swift` | One joined turn settlement preserves append-before-observe, produced output, terminal evidence and releases |
| `ChatTurnSteering.swift` | `ChatTurnSteering` actor; open turns and turn-activity clock; atomic resident claim/reservation under the common free-time law; person admission opens immediately |
| `ChatUpdateNote.swift` | Version note selection and launch transaction with supplied bundle resource/version inputs |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ContextStageTrace.swift` | `ContextStageTrace`, stage vocabularies and lifecycle telemetry: bounded context timing, counts and recall/admission trace recording |
| `ConversationPrefixSeeding.swift` | One provider-independent user-leading context delivery; ordered paragraph replacements from the preceding replayed complete state, keyframes, sent-row metadata and full/delta byte telemetry |
| `DelegatedCampaignGuidance.swift` | `DelegatedCampaignGuidance`: provider-neutral campaign prompt contract; Trust, dispatch and domain verification retain authority |
| `DocumentExcerpt.swift` | `DocumentExcerpt.selected`: query-scored attachment line windows rendered in document order with explicit line ranges |
| `Expansion+Practice.swift` | `Expansion`: exact template/argument-flow inference, call shapes, confidence/cost law, persisted record types and diagnostics |
| `Expansion.swift` | `Expansion`: live call threads, per-mind/model/authority practice storage, settlement and one coalescing writer; `expansion/record.json` |
| `ExpansionDispatcher.swift` | `ExpansionDispatcher`: outermost gated door; bounded speculative reads and act previews from the caller’s own admitted practice |
| `FirstConversationPersonaProgression.swift` | `FirstConversationPersonaProgression`: exact-session one-shot progression tokens and pending voice step; Trust authorizes writes; atomic spending prevents reuse |
| `FirstRunWelcomeTransaction.swift` | `FirstRunWelcomeTransaction` class; `hasConversationRows`, `isPersistedFailureRow` |
| `GlobalHotkeyVoiceTurn.swift` | `GlobalHotkeyVoiceTurn`: push-to-talk authorization, capture and final speech result through the shared Mac send boundary |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |
| `InlineInteractionSignatureWitness.swift` | Shared continuation stamping binds replay identity, peer steering, DataRootLife and the persisted origin to a cryptographic witness; persisted transcript claims confer no signing authority |
| `IntraTurnContextCompaction.swift` | `IntraTurnContextCompaction`: context measurement and pressure receipts; working notes cover the complete rendered span in bounded consecutive chunks before replacement, with explicit output allowance and oversized-note rejection |
| `MacChatRetrySnapshot.swift` | `MacChatRetrySnapshot` struct; `capture`, `stillMatchesLocal` |
| `MacChatSessionTransactions.swift` | explicit selection intent/transactions, live direct automatic selection, load-completion waiter and running-session navigation; `LatestRead` owns session-index publication, and committed create/open/rename changes use `write`; selection and durable rename intents retain their independent action identities |
| `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator` actor consumes core `TurnStreamEvent` directly and sanitizes activity; deltas arm one publication deadline, rearmed only for owed text; settlement/termination cancel and join publication |
| `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |
| `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |
| `MacChatTurnCommands.swift` | `NativeChatTurnOptions` and `MacChatTurnRuntime`: shared Mac turn options, memory facts, notes and scratch commands; transcript commands live on NativeAgentEngine |
| `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`: `beginChatTurnLifecycle`, `applyChatTurnLifecycleInput`; `OtherDoorTurns` retains its trace subscription consumer, counts reply progress only from surface output evidence, stops at engine termination and unsubscribes on exit |
| `MacChatTurnLifecycleState.swift` | Lifecycle state, input, terminal evidence and reducer; `MacChatPersistedTurnLifecycle` validates the payload-free durable projection |
| `MacChatTurnLifecycleStore.swift` | `MacChatTurnLifecycleStore` owns its envelope, file URL and durable read/write boundary; bounded exact-turn persistence and durable queue/attachments; new requests retain DataRootLife, missing stamps mean first life and cross-life requests project stopped |
| `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |
| `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry` |
| `MacChatTurnRuntime.swift` | Canonical Mac admission/lifecycle, replying/preview state and Send-next projection; queue writes use MacChatTurnLifecycleStore; cross-life requests stay stopped until the person's Resume or Send now creates fresh requests without old steering or continuations |
| `MacChatTurnStreamSettlement.swift` | Mac stream completion, joined persistence and lifecycle settlement; helper conversations enter their own runner with the existing Mac admission |
| `MacChatTurnTranscriptProofReader.swift` | Bounded, symlink-refusing transcript proof with exact outcome correlation; terminal proof/error vocabulary and `MacChatTurnLifecycleRestartRepair` |
| `MindMemoryManager.swift` | `MindMemoryJudgment` struct; `predictionModelKey` (the record's key for the model the judgment runs on, read without changing the request; the interpretation reports the same model), `interpret` (with the cares section when cares are shown), `interpretBatch` (owed turns in one call, the rules once, one section per turn; a missing section stays owed), `appraiseCares`, `relevantRecallIDs`; incremental ranked evidence and catalog-budgeted relevance batches; `AfterTurnMemoryFailure` preserves output limits, request rejections and refusals with distinct recovery |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatTurnRuntime diagnostics |
| `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`: native requested-result settlement classification of the user-authored message head |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` reads the declared class and the catalog bucket (reads of their own data and files run side by side; their devices, the app door and the unplaced run one at a time); keyword scheduling inference removed |
| `PersistedToolReceipt.swift` | `PersistedToolReceipt.project`: bounded, redacted historical tool facts and exact continuations; oversized locators are omitted rather than clipped; `SwiftNativeTurnEngine.landedEffect` reads declared landed effects from execution receipts |
| `ProactiveAssistantSpeech.swift` | `speakProactively` owns proactive transcript writes, claims, quota and destination reconciliation; Reach and chat.post share reachOut, inbox Act uses morningBrief |
| `ProviderRecoveryPolicy.swift` | `TurnEngineError` provider failure wrapping: preserves interrupted-stream causes and classifies nonempty partial output as work that ran partly |
| `ProviderToolNameMap.swift` | `ProviderToolNameMap`: stable provider-safe tool aliases with reverse mapping to canonical dispatch names |
| `StandingBotContinuity.swift` | Helper ingress routes to StandingBots' own turn runner; session creation records agent kind and exact helper owner, correcting older rows; legacy shelf import retains the existing transcript format |
| `StandingBotModel.swift` | Helper adapter uses shared cursor admission, prefix seeding and cache markers with its own instructions/history; checked codecs, tools and transcript writer feed StandingBots' own loop without resident context or after-turn work; `Expansion.withTurn` closes its predictions on every exit; contact thread rides the shared paragraph delta/keyframe block stored and replayed on its user row |
| `SwarmChatClientFactory.swift` | `NativeSwarmChatClientFactory.makeClient` constructs the orchestration actor, whose `SwarmChatClient` conformance runs completed-required ephemeral tool turns |
| `SwiftToolDispatcherConstruction.swift` | `SwiftToolDispatcher`: extension |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolCallCodec.swift` | `ToolCallCodec`: provider tool offerings, streamed prose release and native/text-marker call decoding; the turn loop owns dispatch and budgets |
| `ToolLoopSupport.swift` | `ToolLoopTraceObservation` retains prose and dispatch evidence across every loop throw and owns failed-attempt classification; legacy failed-slot counting stays separate; `ToolDispatchDeadline` |
| `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`: local wall-clock quiet-hours membership, wraparound and exact end deadline shared by native reply admission |
| `TurnContextPreparation.swift` | SwiftNativeTurnEngine context preparation, checked route admission, frozen reach and bounded attention inputs |
| `TurnContextSnapshotTrace.swift` | `SwiftNativeTurnEngine.fireContextSnapshotEvent`: local bounded, redacted context snapshots and prompt/schema fingerprints tied to the current turn trace |
| `TurnEngineContracts.swift` | `TurnContext` value projections with module-scoped setters, immutable admitted routing and retained sent-context/window metadata; `TurnEngineResult` aliases TurnTraceEvent's terminal status vocabulary |
| `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |
| `TurnPart+ShippedBodies.swift` | `TurnPart.shipped`: generated prior shipped turn-body versions and digests from git history; the currently bundled body is not an upgrade candidate |
| `TurnPart.swift` | `TurnPart`: their turn as a part (`abilities/turn.js` `step(state, event)`) in one held helper per turn (a helper short of resources is an observation retried on the helper backoff until Stop; any other start failure ends the turn with its fix), version choice (prior shipped bodies come from generated `shipped`) and seed install (write failures name the person and storage repair), the effect queue, the turn's event log and reconstruction for resume and heal; `provider_failure` carries the repair's callable input, permits explicit `app` repair calls through the ordinary dispatcher or a re-issued `model.call`, and can end incomplete without healing an authored part; compare-and-swap heal in one store transaction |
| `TurnRequest.swift` | `TurnRequest`: shared turn binding; `TurnAdmission`: per-session serialization, bounded admission queues and release/cancellation capacity signals for durable arrivals |
| `TurnSettle.swift` | `TurnSettle` enum; `requestedResultIntent`, `takeStreamSuffix`, `transcriptRow` |
| `VoiceInputCapture.swift` | consent-driven native microphone lifecycle; shared SpeechUtterance recognition and original audio travel through existing chat attachments |
<!-- END GENERATED BLUEPRINT -->

### ChromeControl

Directory: `Modules/NativeAgentCore/Sources/ChromeControl/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChromeControl/ -->
| File | Owns |
|---|---|
| `BrowserConnectionMirror.swift` | `BrowserConnectionMirror`: last runtime-published Chrome connection state for synchronous home reads; nil remains unobserved |
| `ChromeControlChannel.swift` | `ChromeControlChannel` actor, private socket/request ownership and shared offPool socket dispatch; ordered frames, cancellation/timeout settlement and unknown mutation outcomes; Chrome group tab authority, `ChromeConversationTab` values, snapshot/element/user-sequence safety, call-scoped pixels and bounded mutation-backed page change streams |
| `ChromeControlHandshake.swift` | `ChromeControlHandshake`: private per-listener token, registered relay executable/signer and browser-parent authentication, bounded hello framing and listener-generation acknowledgement |
| `ChromeControlRuntime+ConnectionEvidence.swift` | `ChromeControlRuntime` connection evidence: historical persisted facts, setup verification, connection diagnosis, capture/relay diagnostics, extension errors and observed browser signature preflight; observations never prove connection or permission |
| `ChromeControlRuntime+ConversationTabs.swift` | `ChromeControlRuntime` conversation tab members: durable last-tab memory rebuilt from the group, numeric addressing, per-tab reading views and remembered owned-tab page.look; last eight release causes/times/URLs survive reconnects for this app run |
| `ChromeControlRuntime+Reload.swift` | `ChromeControlRuntime` reload members: manifest/file observations, automatic/manual attempts and reconnect-confirmed receipts with running/folder code digests; browser process identity and listener generation fence reload proof |
| `ChromeControlRuntime.swift` | `ChromeControlRuntime`: one actor and stored state; authenticated listener/relay attach, authority, channel dispatch and connection streams; listener identities fence late work; transport stop retires passive observations, reconciliation rearms them and terminal stop closes admission/streams; only explicit tab.close removes tabs, shutdown/reload leave them open |
| `ChromeExtensionFiles.swift` | `ChromeExtensionFiles`: registered unpacked and bundled manifest identity/version reads; one executable closure supplies completeness, watched paths including missing files and the loaded-code SHA-256 digest shared with the extension |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` enum; executable-closure completeness through ChromeExtensionFiles, staged replacement and registered-host refresh; incomplete bundles and copy failures name the defect and person recovery step, never a coding request |
| `ChromeNativeHostRegistration.swift` | `ChromeNativeHostRegistration`: bundled relay identity and native-host manifest install/uninstall; directory-locked ownership checks preserve the registered install and shared extension origin |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChromeControl diagnostics |
<!-- END GENERATED BLUEPRINT -->

### Cognition

Directory: `Modules/NativeAgentCore/Sources/Cognition/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Cognition/ -->
| File | Owns |
|---|---|
| `AutonomousPursuitProposer.swift` | `AutonomousPursuitProposer`: at most one reflection pursuit from a live non-seed life-depth care with a stance; life approval, Desk cap and citation dedup guard admission |
| `CaringReceiptLog.swift` | `CaringReceiptLog`: typed interpretation receipts, serialized amendments and dosing evidence |
| `CognitionHost.swift` | Native cognition reach, including the sender-owned phone notification target count and root-bound pure readout-face invocation; domain facts and canonical commits remain outside editable code |
| `CognitiveAttentionResidentProjection.swift` | `ResidentAttention`: lock-backed immutable cognition/organism handoff for turn reads without actor, disk or provider work |
| `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |
| `EventDeadlinePhysiology.swift` | `EventDeadlinePhysiology`: store/file invalidations and cancellable refresh adapters; canonical runners reread state and suppress only known self-write generations |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Cognition diagnostics |
| `NativeCognitionRuntime+BodyContinuity.swift` | `NativeCognitionRuntime` body continuity: restore-gated organism persistence through one coalescing drain and atomic writer |
| `NativeCognitionRuntime+BodyEvidence.swift` | `NativeCognitionRuntime` body evidence: phone, notification, memory, dream, tool, approval and thermal readings with debug projections |
| `NativeCognitionRuntime+Continuity.swift` | `NativeCognitionRuntime` continuity reads: dream residue, local gap cues and builder activity; absent and unreadable sources remain distinct |
| `NativeCognitionRuntime+Deadlines.swift` | `CoalescingDeadline` and cognition background settlement: dirty microcycles, checked maintenance, residual repair and exact wakes |
| `NativeCognitionRuntime+Door.swift` | `NativeCognitionRuntime` opening and joined sleep settlement; the one lived-moment door records, prepares, folds, settles, prunes and imports held turns |
| `NativeCognitionRuntime+Events.swift` | `NativeCognitiveEventFactory` and runtime event ingestion: payload-free motor/provider observations; domain owners retain outcome authority |
| `NativeCognitionRuntime+Expectations.swift` | `NativeCognitionRuntime` horizon expectations: Desk plans named and deduplicated by work title, unnamed memory plans by whole-second due instant, composed dated evidence and refresh deadlines |
| `NativeCognitionRuntime+MindLedger.swift` | `NativeCognitionRuntime` mind ledger: trace-backed why (cue, memory, outreach, expansion and interpretation lanes), association rejection and undertone undo through substrate owners |
| `NativeCognitionRuntime+Notify.swift` | `NativeCognitionRuntime.innerStateReading`: one reading across mind/body owners and pending stake-bearing expectations |
| `NativeCognitionRuntime+Organism.swift` | `NativeCognitionRuntime` live organism integration: approval lifecycle expectations, somatic ingestion, felt resolutions and live body projections |
| `NativeCognitionRuntime+Preferences.swift` | `NativeCognitionRuntime` preferences, checked configuration refresh and onboarding transitions |
| `NativeCognitionRuntime+ProviderEvidence.swift` | `NativeCognitionRuntime` provider evidence: bounded lifecycle history restored from canonical traces and durable capability projection |
| `NativeCognitionRuntime+ProviderVitals.swift` | `NativeCognitionRuntime` provider interoception: passive vitals persistence, health-band transitions and graded somatic ingestion |
| `NativeCognitionRuntime+Pursuit.swift` | Complete Desk/queue advisory snapshots publish through LatestRead on the runtime actor; source invalidations publish unavailable; resident intent has no turn-time Desk I/O |
| `NativeCognitionRuntime+Reach.swift` | `NativeCognitionRuntime` outreach execution, durable offer settlement, care landing and exact delivery deadlines |
| `NativeCognitionRuntime+Readouts.swift` | `NativeCognitionRuntime` change stream, Observatory, Doctor and capsule readouts; `GrowthWeekFace` binds frozen facts to the part face cache |
| `NativeCognitionRuntime+RecentLife.swift` | `NativeCognitionRuntime` recent life: once-only conversation/day/speaker cares reading and moment-to-care migration |
| `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime` reflection: dream/REM-triggered single-flight reflection, budget admission, result settlement and pursuit proposals |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime` replay evidence composition, checked integration and bounded event-driven reconciliation |
| `NativeCognitionRuntime+SourceWakes.swift` | Runtime-owned source observations for canon, horizon, Reach, cares and quiet-hour preferences; the crossing (`SenseCrossing`): a part's arrival or a sense's news that touches a care asks for one ResidentWake naming it, once per watch per care until the care rests; registration precedes reads, renewed directory children remain watched, canon arms journal membership before enumerating input children and compares input stamps to ignore audit output and unchanged directory events, stop cancels observations, and the existing residual deadline owns source cooldown/eligibility/expiry boundaries |
| `NativeCognitionRuntime+StudioCanon.swift` | Native source invalidations, background admission, throttle, audit receipts and exact deadline ownership; proposals and next deadline share one read-constrained studio-canon projection; no new timer or schedule activation |
| `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`: retained hour flight, checked admission and terminal settlement; installation, material composition and editable studio-intake invitations |
| `NativeCognitionRuntime+TurnPresentation.swift` | `NativeCognitionRuntime` fixed-time turn preparation and committed capsule/body-line presentation |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime` actor composition, retained state and sensory admission; run-scoped turn classification and live-turn latches |
| `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail` and runtime read models; shared affect validity and organism sample freshness/validity |
| `Reach.swift` | `ReachCandidate` and pure `Reach` pacing, eligibility, provenance and delivery policy |
| `ReachLedger.swift` | `ReachLedger`: bounded outreach facts, checked reads and locked answer-settlement writes at cognition/reach.json |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |
| `StudioWanderLane.swift` | `StudioWanderLane` enum; installation, eligibility, carried-hour state and prompt for studio wandering |
| `StudioWanderToolWitness.swift` | `StudioWanderToolWitness`: hour action admission and encounter evidence at the gated dispatch seam |
<!-- END GENERATED BLUEPRINT -->

### CognitiveSubstrate

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/CognitiveSubstrate/ -->
| File | Owns |
|---|---|
| `CognitiveCare.swift` | Care stance, relationships, depth and bounded lived story with unchanged Codable representation |
| `CognitiveConfiguration.swift` | `CognitiveConfiguration`: cognition settings, Observatory availability and reflection spend ceilings |
| `CognitiveEpisodeReplay.swift` | Episode, schema proposal, developmental timeline and dream/REM replay values |
| `CognitiveEvent.swift` | `CognitiveEvent` and event/turn-kind vocabularies: typed cognition observations, mechanical-row classification and metadata signals |
| `CognitiveLivedMoment.swift` | `CognitiveLivedMoment`: a settled turn's journal record (identity, life, forgetting epochs, state owed → meant → lived or refused, fold seq, recorded input and caring request, meaning) and `LivedMomentDoor`, the interpretation owner's closures |
| `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |
| `CognitiveModels.swift` | `CognitiveNode`, snapshots and `CognitiveFrozenRead`: source/subject identity, bounded emotional tags, association edges and persistence health values |
| `CognitiveReflection.swift` | Captured reflection provenance, judgment, request, receipts and observatory values |
| `CognitiveSQLiteStore+LivedMoments.swift` | `CognitiveSQLiteStore`: the lived-moment journal (`lived_moments`, migration v8): record owed, save input and meaning, assign fold seq, settle lived or refused, prune settled payload-free rows; checked decoding refuses damaged rows individually with reason, preserves payloads and owes repair; reads legacy sealed requests and `folding` rows (as meant) |
| `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadRestoreBundle`, `loadReceiptRecords` |
| `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore` actor; `backupForDoctor`, `commitMaintenance` |
| `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |
| `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.makeAttentionSignals`: pure bounded workspace/question/subject projection for resident handoff publication |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: `compileFrozenCapsulePresentation` owns chat and inspect-only reflection assembly |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `soundEchoShouldSpeak` |
| `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate` cares: four life seeds, embedder-ordered care lines (the call names the care), shared embedding text and provenance-gated apply returning affected IDs; converts retired views and thought seeds once |
| `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate` cares on their mind: one pressure, the capsule's care cue, intentions, watch touches and rest, Reach and their hour |
| `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate` cares at night: the dream's material (moved today, still open), its settle and let-go lines, fade past the depth's horizon, deepen by distinct days moved, the cares ready for the life card and its approval, their story lines |
| `CognitiveSubstrate+CaringAppraisal.swift` | `CaringAppraisalRequest`, verdict and lane contracts: semantic caring judgments, distinctness and admission/refusal interfaces |
| `CognitiveSubstrate+CaringEvent.swift` | `CognitiveSubstrate` caring event admission: turn context, semantic verdict delivery and distinct encounter/refusal accounting |
| `CognitiveSubstrate+Continuity.swift` | `CognitiveSubstrate` continuity cues: dream-theme association and since-gap candidates compete for the existing felt slot |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: conversational phrase matching, appraisal and warmth, relational provenance, open completion and association signatures |
| `CognitiveSubstrate+DreamResidue.swift` | `CognitiveSubstrate` dream contribution: single-flight integration, night claims, residue minting, consumption and persistence; `CognitiveDreamResidue` |
| `CognitiveSubstrate+FeltFingerprint.swift` | `CognitiveSubstrate` felt fingerprint: graded live feeling words and capsule line composition |
| `CognitiveSubstrate+FeltOrigins.swift` | `CognitiveSubstrate.feltDayOrigins`: last-day felt-node provenance for dreams, using the same population as the felt-day summary |
| `CognitiveSubstrate+GrowthWeek.swift` | Frozen REM timeline and decoded disposition transitions; `growthWeek`/`growthWeekLines` share the owned `growth-week.js` face. Readout grouping, titles, reasons, alternatives, ordering, cap and undertone prose are removed from Swift; canonical timeline source titles stay in Replay for its other consumers. |
| `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidateCompletion` |
| `CognitiveSubstrate+InnerState.swift` | `CognitiveSubstrate.innerStateReading`: record-backed mind/body introspection, selection reasons and felt/care/toward projections |
| `CognitiveSubstrate+Maintenance.swift` | `CognitiveSubstrate`: microcycle settlement, maintenance deadlines and emotional consolidation |
| `CognitiveSubstrate+MindLedger.swift` | `CognitiveSubstrate` mind ledger: bounded association suppressions and one disposition undo, persistence and restoration |
| `CognitiveSubstrate+Mood.swift` | `CognitiveSubstrate` mood: read-time emotional-tag integration, disposition, congruence, felt-day summaries |
| `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistAffectAndNodes`, `recordReceipt` |
| `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: causal `planReflectionChecked`, frozen per-cause peer/node provenance, judged reflection integration and receipts |
| `CognitiveSubstrate+RemindedOf.swift` | `CognitiveSubstrate` unbidden association: the felt line drags up a care's newest movement; cadence and selection revalidation |
| `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`; schema status and dated REM resolutions share the inbox's decision snapshot by proposal identity; adoption requires its application claim; unmatched retained history stays explicitly unavailable; retired view/opinion/interest events never enter timeline or growth-week readouts |
| `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: live workspace intervention and frozen Observatory summary; experiment metrics are retired |
| `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState` |
| `CognitiveSubstrate+SemanticAppraisal.swift` | `SemanticAppraisal`: meaning-weighted event appraisal against outcomes and embedding-touched cares |
| `CognitiveSubstrate+Serialization.swift` | `CognitiveSubstrate`: `cleanedSessionId` |
| `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |
| `CognitiveSubstrate+TopicNaming.swift` | `CognitiveSubstrate` topic naming: privacy-filtered noun phrases, producer labels, comparison terms and persisted-label admission for introspection |
| `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate`: `metadataString`, `isConversationalPresenceStatement`, `isOperationalSubconsciousNoise` |
| `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead` |
| `CognitiveSubstrate.swift` | `CognitiveSubstrate` actor; `waitForMaintenanceTransition`, `beginMaintenanceTransition` |
| `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies` struct; injected frozen growth projection, explicit unavailable when unbound |
| `CognitiveTurnCapsule.swift` | Attention, workspace, prepared capsule and fixed-time turn projections; advisory cognition runtime contract |
| `ContinuityField.swift` | `ContinuityField`: bounded canonical node/association field, event deduplication, activation/decay and emotional-tag blending |
| `DoubleClamping.swift` | `Double.clamped01` and `clampedSigned`: shared unit/signed clamps for substrate and organism magnitudes |
| `JSONValueBounding.swift` | `JSONValueBounding`: shared recursive metadata bounds, depth limits and secret redaction for substrate, continuity and somatic persistence |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for CognitiveSubstrate diagnostics |
| `PersonalityDynamicsConfiguration.swift` | `PersonalityDynamicsConfiguration`: fixed felt-layer bounds and persona-derived warmth/humor parameters |
<!-- END GENERATED BLUEPRINT -->

### CognitiveSubstrate/Organism

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/ -->
| File | Owns |
|---|---|
| `BodyEvidence.swift` | Body evidence classes, secret-free identities and bounded freshness/uncertainty metrics |
| `CognitiveSomaticSignalAdapter.swift` | `CognitiveSomaticSignals` enum; `signal`, `safeSourceComponent` |
| `OrganismBehaviorPosture.swift` | `OrganismBehaviorPosture`: typed evidence decisions, optimism thresholds and operational directives; default posture renders nothing |
| `OrganismBodySchema.swift` | `ProviderPathEvidenceOutcome` enum |
| `OrganismCapabilitySelfModel.swift` | `OrganismCapabilitySelfModel` enum; `beliefs` |
| `OrganismCaringEvent.swift` | `OrganismCaringEvent`: encounter identity, dose eligibility and rolling encounter extension; one encounter receives one dose |
| `OrganismChemistry.swift` | `OrganismChemistry` enum; `applying`, `dosedByCaringEvent` |
| `OrganismDreamRepair.swift` | `OrganismDreamRepair` enum; `applying`, `applyingResidualPressure` |
| `OrganismField.swift` | `OrganismField` struct; `summary`, `edge` |
| `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `foldTurn` (the body's whole share of one lived moment, with its watermark) |
| `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value` |
| `OrganismModels.swift` | `SomaticSignalKind` enum |
| `OrganismPersistence.swift` | `OrganismPersistentState`: persisted body field, chemistry, predictions and caring encounter; restore decay, identity validation and pending plan rekeying by source name or unnamed due instant, recovering Desk names retained in sourceOrgan |
| `OrganismPrediction+Horizon.swift` | Horizon vocabulary, bounded register reads and refresh transitions; named plans keep name identity, unnamed atoms use whole-second due instants |
| `OrganismPrediction+Semantic.swift` | Conversational expectation metadata and scope; `OrganismPredictiveBody` minting, reaction resolution and deterministic IDs |
| `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |
| `OrganismPredictionModels.swift` | Shared prediction rows, ledger, body confidence and cumulative outcome evidence |
| `OrganismProspectiveAffect.swift` | `OrganismProspectiveAffect`: pure prediction/horizon modulation of projected chemistry, without changing stored chemical state |
| `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |
| `OrganismResolutionFelt.swift` | `OrganismResolutionFelt`: pure notable resolution events with aboutness and per-path rate bounds; kernel retains state ownership |
| `OrganismSignalBus.swift` | `SomaticSignalBus` actor; `observe`, `configure` |
| `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |
| `OrganismTypedBodyBeliefs.swift` | Seven typed domain readings: evidence-bounded categories, freshness and compatibility values |
| `SomaticSignalValence.swift` | `SomaticSignalKind` intrinsic valence: one per-kind table shared by signal adaptation and organism field defaults |
<!-- END GENERATED BLUEPRINT -->

### Connectors

Directory: `Modules/NativeAgentCore/Sources/Connectors/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Connectors/ -->
| File | Owns |
|---|---|
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |
| `ConnectorActions.swift` | `ConnectorActions` struct; `runConnectorAction` uses shared admission, input values and approval replay; native work journal/handoff reads, redaction before display bounds and original Git reads; work snapshots return directly without unused latest.json/codex_daily.jsonl copies; credential-bearing text never enters a part |
| `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and `ConnectorProofLedger`: credential-backed health from latest actual receipts, decayed by age without polling |
| `ConnectorOAuthRegistry.swift` | Canonical connector row edits, including revocation; extends PersistenceCore's checked registry owner with `mutateConnectorRegistryEntry`, `removeConnectorRegistryEntries` |
| `ConnectorRegistryActions.swift` | connector/workspace registry operations and ordered workspace readback verification; Slack disconnect records the person’s decision before credential removal; socket-mode metadata writes delegate to SlackCredentials |
| `ConnectorWizardActions.swift` | `ConnectorWizardSetupRoute`: the wizard's token route, read from the inline card registry; registry row read |
| `Connectors.swift` | Canonical workspace-array read and tilde-expanded string paths for search and journal roots; typed workspace search results and checked identity metadata; empty queries echo their original input |
| `LocalPIMConnectorActions+Authorization.swift` | calendar read/write authorization interpretation and EventKit permission prompts; wizard status |
| `LocalPIMConnectorActions+Calendar.swift` | Calendar CRUD, bounded event snapshots and calendar day/range interpretation on the existing LocalPIMStore |
| `LocalPIMConnectorActions+Reminders.swift` | Reminder CRUD, due-date splitting and paging on the existing LocalPIMStore |
| `LocalPIMConnectorActions.swift` | Shared EventKit authorization facts, scalar interpretation and argument refusals for Calendar and Reminders |
| `LocalPIMStore.swift` | concrete `LocalPIMStore` EventKit session; main-actor mutations, queue-confined reads |
| `NativeOAuthFlow+Connectors.swift` | `NativeOAuthFlow`: `saveInlineConnector`, a connector card's token save (Slack, Telegram) |
| `NativeOAuthFlow+Slack.swift` | `saveSlackToken` validates explicit setup tokens through `SlackWebAPI` and records the person's connected decision; canonical auth metadata and grant publication delegate to SlackCredentials without a legacy copy. Saved fields describe setup, while runtime health requires action proof; publication checks its captured revision under the commit locks, and disconnect advances the registry credential generation |
<!-- END GENERATED BLUEPRINT -->

### Context

Directory: `Modules/NativeAgentCore/Sources/Context/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Context/ -->
| File | Owns |
|---|---|
| `Context.swift` | `SwiftNativeContextClient`: feature-surface lookup only; no legacy receipt reader or retention. Existing `context/<runID>.json` files are left for the operator. |
| `ContextArena.swift` | `ContextArena`: bounded resident generations, immutable snapshot leases, serialized publication and pressure trimming |
| `ContextAtomMatching.swift` | `ContextMarkdownCompiler` atom matching: ordered exact identity reuse and heading-scoped fuzzy matching |
| `ContextCandidateScore.swift` | Context eligibility decisions and candidate scoring values with their existing codecs |
| `ContextConflictGraph.swift` | `ContextSelector` conflict connected components, resolution validation and receipt projection; selection retains atomic admission |
| `ContextCorrectionScope.swift` | `ContextCorrectionScope`: applicability gates for canonical corrections and endpoint-scoped graph relations; selection utility grants no authority |
| `ContextExpansion.swift` | `ContextExpander.expand`: expands selector-offered pointers without mutating context or deriving authority from their contents |
| `ContextFeedback.swift` | `ContextFeedbackReducer`: deterministic rebuildable utility and use-reachability projection from explicit-bucket feedback and canonical seeds |
| `ContextFlowModels.swift` | ContextFlow value vocabulary: source/atom/relationship identity, authority, privacy, injection policy and immutable generation records |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`: bounded Markdown atom compilation and exact unchanged-source reuse; `triggerTokens` owns ordered trigger extraction with source-specific tokenization/filter/bound parameters; persona GROWTH uses the PersonaEngine episodic-log filter before hashing and parsing |
| `ContextMarkdownGrammar.swift` | `ContextMarkdownCompiler` grammar: UTF-8 block ranges, Markdown boundaries and generated USER fact bullets |
| `ContextMemoryLead.swift` | `ContextMemoryLead`: memory age, provenance and stored-source extraction; packet lines retain the shared author suffix |
| `ContextPacket.swift` | Context packet, expandable pointers, safe representation leads and retained memory provenance |
| `ContextPreparation+Feedback.swift` | Ordered advisory feedback persistence and replay; cache matches generation, event ordinal and decay bucket; retained delivery evidence alone grants conversation-local rest |
| `ContextPreparation+SourceReconciliation.swift` | Source compilation and immutable generation publication through the actor's single admission gate; durable baselines, degradation, arena rehydration and bounded store maintenance |
| `ContextPreparation+TurnSelection.swift` | Generation-derived authorization and precoverage, exact turn leases and mandatory-budget retry; verification filters delivery while preserving selection receipts, budgets and feedback IDs |
| `ContextPreparation.swift` | One ContextPreparation actor and state owner; lifecycle, health, compile/publication admission and cancellation; stop invalidates candidates and drains entered publication |
| `ContextPreparedTurn+CameToMind.swift` | `cameToMind(by:embedding:excluding:limit:)`: a moment's words as one more reading of the turn's own need, so what they reads or what happens brings memories to mind by the rule their message does (two deviations, rest, their disclosure), minus what the turn already holds |
| `ContextProjectionSources.swift` | `ContextCompiledProjectionProvider`: incremental rebuildable source projections, generation-bound exclusions and delivery/publication hooks |
| `ContextRelevance.swift` | `ContextSelector` relevance mathematics: lexical/semantic scoring, memory-population standing, diversity and redundancy; `ContextLexicalTokenizer` shares recall normalization |
| `ContextSQLiteCodecs.swift` | `ContextSQLiteStore` persisted atom payloads, row decoding, JSON dates and vector bytes |
| `ContextSQLiteMaintenance.swift` | `ContextSQLiteStore` source degradation, ordered feedback persistence, health, pruning and vacuum on its single pool |
| `ContextSQLiteSchema.swift` | `ContextSQLiteStore` schema: unchanged migration identities and SQLite definitions |
| `ContextSQLiteStore.swift` | `ContextSQLiteStore`: derived immutable Context generations, feedback, health and pruning; canonical sources remain authoritative |
| `ContextSelection.swift` | `ContextSelector.select` owns eligibility, mandatory coverage, memory touch/rest admission, quotas, deterministic reranking and packet receipts; `commonEligibilityFailure` is shared with expansion |
| `ContextSelectionConfiguration.swift` | Context selector limits, ranking weights and named admission errors |
| `ContextSelectionReceipt.swift` | Selection conflicts, degraded sources, budget, index and receipt evidence with byte-compatible coding keys |
| `ContextSourceMonitoring.swift` | `ContextSourceRegistry`, monitor and coalescer: explicit source allowlists, owner inventories and bounded directory invalidations |
| `ContextTurnRuntime.swift` | `ContextPreparedTurn`, request and embedding ticket: generation lease, bounded query-vector handoff (the query, its other voice and a follow-up's own words) and turn feedback/delivery accounting |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Context diagnostics |
| `NeedSignal.swift` | Context need, admitted origin/authorization, cache identity and explicit conflict vocabulary |
| `RequiredDocumentMirror.swift` | `RequiredDocumentMirror` and `StablePromptKernel`: persona-slot/source naming, required document reads and deterministic logical byte accounting |
<!-- END GENERATED BLUEPRINT -->

### ContextFlow

Directory: `Modules/NativeAgentCore/Sources/ContextFlow/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ContextFlow/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ContextFlow diagnostics |
| `NativeContextFlowConfiguration.swift` | `NativeContextFlowConfiguration`, mode status, startup error and observatory health; onboarding-safe mode and RAM budget resolution |
| `NativeContextFlowRuntime+QueryEmbedding.swift` | `NativeContextFlowRuntime` query embeddings; primary-first readings, joined tickets, epoch-checked settlement and bounded cache; task ownership stays on the runtime actor |
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime` actor; ordered, joined lifecycle transitions; stop drains retained picker, observation and embedding bodies; picker publication checks, turn preparation and memory provenance |
| `NativeContextMemoryPressureObserver.swift` | `DispatchContextMemoryPressureObserver`: cancellable OS pressure event bridge; runtime and coordinator retain trim policy |
| `NativeContextMemoryProvenance.swift` | `NativeContextMemoryProvenance.attach`: advisory reverse lookup on the exact prepared-turn lease; misses never invent record identity |
| `NativeContextProjectionText.swift` | `NativeContextProjectionText` enum; `clean`, `bounded`; projection triggers delegate to ContextMarkdownCompiler |
| `NativeKnowledgeGraphContextProjection.swift` | `KnowledgeGraphContext`: rebuildable graph atoms, support and triggers with canonical-source verification |
| `NativeMemoryContextProjection.swift` | `MemoryContext`: canonical memory projection, including immutable untrusted-source entities and source hashes |
| `NativeResidentWorkContextProjection.swift` | `ResidentWorkContext` and `ResidentWorkDecisionNeed`: provenance-bearing Desk/Workshop context, without scheduling or transition authority |
| `NativeStudioContextProjection.swift` | `StudioContext`: rebuildable journal/canon pointer atoms and invalidation; judgments remain behind on-demand pointers |
| `PersonaContextFlowProvider.swift` | `PersonaContextFlowProvider` actor; persona source registrations and required-document mirrors share one compiler batch and surface provenance |
| `PersonaContextInvalidation.swift` | `DerivedPersonaPinInvalidationSink`, `ContextFlowInvalidationRelay` and `REMPinRebuildCoalescer`; persona invalidation reaches Context Flow and rebuilds REM pins even while it is off |
| `SensesContextProjection.swift` | `UnreadSenseNews`: four bounded unread `news` atoms from `SenseNewsBoard`, selected from the published generation, verified still unread before delivery (unread news does not expire), separately rendered and acknowledged only on provider output; seen exclusion also protects retained generations |
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
| `DeskArchiveQueries.swift` | Archival, current-life readings and hierarchy queries |
| `DeskBoardLayout.swift` | `DeskBoardLayout`: active/pursuit/watch partitioning and watch order; `DeskPage` attention, freshness and timestamp interpretation |
| `DeskCadence.swift` | Carried steps, cadence and notification policy values |
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation`; life-stamped resumable work, stopped/restored projection; receiptIsUnresolved and toJSON |
| `DeskDependencyTransitions.swift` | Dependencies, hierarchy settlement and locked revalidation |
| `DeskHolds.swift` | Durable Desk hold ownership under the existing feed lock |
| `DeskItem.swift` | Derived live Desk items and explicit progress; statusDescription reads existing status/waitingOn without rewriting persisted rows |
| `DeskJournal.swift` | Locked event feed append, integrity and compaction |
| `DeskLiveStateMemo.swift` | Replay memo keyed by the canonical feed stamp |
| `DeskModels.swift` | Shared Desk enum vocabulary and JSON scalar interpretation |
| `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |
| `DeskNotify.swift` | `DeskNotificationRead`, `DeskNotificationProposal`: frozen native policy inputs and typed proposals; native consent/ceilings and defer truth; Desk/config revision checks and baseline/window commit under native locks; a nag's baseline and ledger settle only after channel acceptance or durable hold. No part execution under a lock. Notification, nag, drift wording and deadline policy live in Resources/abilities/desk-notify.js; the person's unmute and scheduled loop share it |
| `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for HarnessQueue and strict interpretation of historical drift notes; the retired external-observation evaluator and writer are removed |
| `DeskOperations.swift` | `DeskOpBody` enum; `updateTitle` optionally replaces refs with the same replayable summary update |
| `DeskPalette.swift` | `DeskPaletteRow`, `DeskFuzzy`, `DeskPaletteQuery`, `DeskPaletteCommandApplication`: ranked matching and revision-bound command admission |
| `DeskParking.swift` | `DeskDeferPreset`; deferred-work interpretation |
| `DeskQuickAction.swift` | `DeskQuickAction`: Desk tool names and dispatch arguments |
| `DeskRef.swift` | Stable Desk references and their persisted tagged-union identity |
| `DeskRefActions.swift` | `DeskRefAction`, `DeskRefAffordance`: reference open destinations and copy text |
| `DeskSequencing.swift` | `DeskSequencing.compute`: derived blockedness, cycles and subtree plans from stored edges; unblocking never writes a separate operation |
| `DeskState.swift` | Append-only archive records and materialized Desk state formats |
| `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |
| `DeskStore.swift` | `SwiftNativeDeskStore` struct; process-wide `currentRevision` advances before and after each awaited canonical append under the ops lock; `continuation`, `setContinuation`, `heldBy` (nonacquiring hold read); keyed system findings persist findingKey through create, compaction and archive, preserve closure and person ownership under their filing lock; explicit reopening refreshes evidence in that transaction or files anew after archive, with opt-in ref replacement on the same `updateTitle` op; terminalParentsWithNonTerminalDescendants is the pure Doctor/repair selection, with mutation-time revalidation under the ops lock; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `DeskText.swift` | `DeskPage`: compact board and exact-record text, sequencing segments, duration and archive presentation |
| `DeskWorkTransitions.swift` | Durable work creation, reservations, receipts and transitions |
| `MyQueue.swift` | `MyQueue` enum; `entries`, `add`, `isReady`; `Entry.owedToPerson` derives reply obligation from recorded origin and canonical session kind, independent of readiness and taint |
| `OwnerAttentionPolicy.swift` | One owner-attention policy from approvals, Desk waits and inbox choices |
| `PartRunStore.swift` | HMAC-sealed checkpoints under skills/runs; stamps new saves with DataRootLife, reads cross-life journals stopped/restored; explicit Resume runs fresh without the old journal. Desk expiry/MyQueue closure, retention/discard and SwiftNativeManifestSigner signing remain here |
| `PromotionDossier.swift` | Desk notes and typed evidence dossiers for self-authored pursuits |
| `Pursuit.swift` | Durable work attempts and pursuit accounting values |
| `TaskLedger.swift` | `SwiftNativeTaskLedger` owns the orchestration event feed and compaction base; the CLI and wrapper use `PersistenceCore.defaultDataRoot()` unless `--data-root` is explicit |
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
The receive timer owns its sleep and a separate retained drain owns accepted
work through actual exit; teardown cannot reopen its exclusion or let it
rearm an old transport's housekeeping. Subscription registration is retained
and serialized, and metadata callbacks require their exact live query.
Phone-request teardown settles its waiter with an unknown-delivery error and
cancels the send; that send keeps its exclusion until its actual exit.
Presence remains an external protocol beat, not change observation: the
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
| `APNSNotificationDelivery.swift` | SwiftNativeAPNSSender notification/work-activity delivery, fan-out deadline and capped outcome receipts |
| `APNSNotificationReadiness.swift` | SwiftNativeAPNSSender canonical registration reads, target/configuration validation and checked readiness |
| `AdaptiveDrainPolicy.swift` | `AdaptiveDrainPolicy`: receive deadlines from outstanding work, peer activity and proven push; sender retains lost-push recovery |
| `BridgeEvalSeams.swift` | Bridge value policies: durable seen-ID bounds, incoming disposition, KVS keyspace/nudge admission and snapshot/inbox sweep plans |
| `CKLandmine.swift` | CloudKit entitlement probes and guarded account-status projection |
| `DeviceSync.swift` | `DeviceSync` and shared aliases: resident phone bridge, snapshot/inbox assembly and overview-driven needs-person notification binding |
| `DeviceSyncHost.swift` | Engine snapshot/action seam; transcript timestamps bound read-only other-room exchanges to shown history; message owners omit previews for transport budgets |
| `ICloudConnection.swift` | Account, connection, transport registration and receive cadence |
| `ICloudDeliveryNudgeQueue.swift` | `ICloudDeliveryNudgeQueue`: one bounded single-flight KVS wake worker; a nudge never proves transport delivery |
| `ICloudDriveOutbox.swift` | Coordinated Drive outbox scanning, consumption and observation |
| `ICloudIncomingTurnForwarder.swift` | Signed incoming phone turns route helpers to their own runner and resident conversations to chat; iCloudChatFileAccess; checked session commits, Privacy-redacted errors and retained conflated optional publication through `ICloudConflatedSender` |
| `ICloudIncomingTurnPort.swift` | Incoming phone turn engine port: resident chat, helper execution, presentation and control handoff |
| `ICloudIncomingVerification.swift` | Incoming message verification and receipt vocabulary |
| `ICloudReceiving.swift` | Observer-bound receiving and CloudKit drain settlement |
| `ICloudTextDeltaCoalescer.swift` | Owns the accumulating stream text; `push` appends deltas, `flush` emits full-text replacements |
| `LivingAttentionPolicy.swift` | `LivingAttentionPolicy.organismNeedsAttention`: shared body-attention projection for Mac and phone; Desk owns needs-person attention |
| `MacPhoneRequestChannel.swift` | `MacPhoneRequestChannel`: one bounded authenticated request waiter; timeout retires waiting while send ownership drains to actual exit |
| `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`: `chatHistoryPage`; history rows carry a session-index generation unchanged across the history read |
| `MacSyncActionRouter+Connectors.swift` | `MacSyncActionRouter`: `connectorAction` |
| `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |
| `MacSyncActionRouter+Providers.swift` | `MacSyncActionRouter`: `configureEncryptedProvider`, `startProviderSignIn` |
| `MacSyncActionRouter+Scheduler.swift` | `MacSyncActionRouter`: `schedulerAction` |
| `MacSyncActionRouter+Telegram.swift` | `MacSyncActionRouter`: `telegramAction` |
| `MacSyncActionRouter+Trust.swift` | `MacSyncActionRouter`: `applyTrustAction` |
| `MacSyncActionRouter+TrustCommand.swift` | `MobileTrustAction`: checked trust writes |
| `MacSyncActionRouter.swift` | `MacSyncActionRouter` struct; `surfaceSelection`; routing receipts use committed selection snapshots; approval, memory and inbox mutations return affected canonical records/removals for the shared phone projection; no complete inbox or memory lists in action replies; other readback revisions are captured on the Mac before the canonical read |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | MacSyncEngine: shared inner-action ledger decisions, freshness, response recovery, reservation and settlement; the ledger response wins, and strictly bound executed rows without one recover HMAC-verified matching response files through the same owner for both transports and stale pending files; transport acquisition, delivery and archival remain separate |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`: `start`, `stop`; the selected transport supplies roots and ingress to one snapshot lifecycle; saved connector setup changes and receipt-ledger health edges rebuild the heavy snapshots |
| `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |
| `MacSyncEngine+NeedsUserNotify.swift` | `NeedsUserEdgeNotifier` actor; `evaluate`, `stableDigest` |
| `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |
| `MacSyncEngine+Security.swift` | MacSyncEngine pairing rotation and signed responses; complete signed CloudKit action-record budgeting before terminal ledger settlement; oversized readbacks return an explicit processed-action error; BridgeMessage owns HMAC, constant-time comparison and inner-action verification; outer signatures remain case-sensitive |
| `MacSyncEngine+SnapshotFreshness.swift` | Cancelled snapshot reads, stale-group accounting and group build outcomes |
| `MacSyncEngine+Snapshots.swift` | Revisioned snapshots retain exact payload/wire digests; phone Inspector reads its host; chat snapshots carry HerScreen's read-only other-room exchanges as an additive field |
| `MacSyncEngine+Storage.swift` | `MacSyncEngine`: `recordProcessed`, `restoreState`, `cappedPreservingMarkers`; consolidated replay/digest restoration and device bookkeeping await the shared `DeviceSyncStorage` actor in `DeviceSync.swift` before admission/acknowledgement |
| `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |
| `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`: `startWorkActivityObservation`, `projectWorkshopWorkActivities`, `requestWorkActivityPublication` |
| `MacSyncEngine.swift` | Mac snapshot/inbox state, active chat tasks and stop bookkeeping; chat snapshots add read-only other-room exchanges beside canonical messages |
| `MacSyncInboxAction.swift` | Shared `InboxAction` alias and checked remote message/transaction filename identities |
| `MacSyncMobileNotificationRelay.swift` | Sole notifications/push_tokens.json mutation owner: alert registration/pruning, work-activity registration and locked delivery reservations/outcomes; APNs supplies only the send effect; no duplicate mobile_push/tokens.json writes |
| `MobileNotificationDeliveryReceipt.swift` | Bridge/APNs notification receipts distinguish acceptance, display uncertainty and named errors |
| `MobileSnapshotBuilder.swift` | Snapshot integrity vocabulary and bounded mobile projection construction |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DeviceSync diagnostics |
| `NativeAgentNotificationDefaults.swift` | `NativeAgentNotificationDefaults`: shared agent display name and explicit/default notification title resolution |
| `PairedPhoneStore.swift` | Paired-phone array mutations using PairedPhoneAuthority's one Phone schema; local backup/export/phone exclusions and Paired Phones privacy scope are declared here |
| `PairingSecretManager.swift` | `PairingSecret`: checked device-only HMAC secret ownership, explicit rotation and pairing material publication |
| `PhoneConnectionReader.swift` | `PhoneConnectionReader`: weak on-demand reader of the running bridge's one phone-connection assessment |
| `SwiftNativeAPNSSender.swift` | One APNs sender actor owns credential state, JWT reuse/expiry, rejection holds and signing |
| `WorkActivityPushRegistration.swift` | Work-activity push registration, start reservation state and pairing fingerprints with unchanged saved Codable keys |
| `iCloudBridge+ChatAdmission.swift` | Durable chat admission, reply binding and settlement in the bridge ledger |
| `iCloudBridge+DeliveryReceipts.swift` | `iCloudBridge`: `appendChatDeliveryReceipt`, `appendActionResponseDeliveryReceipt`, `appendInboundSuccessReceipt` |
| `iCloudBridge+Pairing.swift` | Pairing claims and the Mac reading of phone connection facts |
| `iCloudBridge+Publication.swift` | Provider catalog, snapshot status, presence and progress publication |
| `iCloudBridge+ReplyDelivery.swift` | Correlated reply recovery, delivery and terminal receipts |
| `iCloudBridge.swift` | Owns ChatRecord admission, reply binding, recovery, durable mutation and terminal retention interpretation for icloud/chat_transactions; rejected CloudKit envelopes have no local journal/quarantine copy. `setup`, `recordCloudKitPushEvidence` (data-root-scoped chat-subscription push proof persisted across launches; subscription failure or unannounced aged delivery revokes), `scheduleNextDeviceDrainFallback` (obligations or push unavailable/unproven; idle rests), `cloudKitActionResponseMessage` (sending and sizing), `failedReplyClaims` (startup snapshot or exact delivery event) |
<!-- END GENERATED BLUEPRINT -->

### DeviceSync/State

Directory: `Modules/NativeAgentCore/Sources/DeviceSync/State/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DeviceSync/State/ -->
| File | Owns |
|---|---|
| `ICloudSyncStatePaths.swift` | `ICloudSyncStatePaths` and bridge health reader: local sync bookkeeping paths and read-only live bridge health, without probing or sync authority |
<!-- END GENERATED BLUEPRINT -->

### Dispatcher

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Dispatcher/ -->
| File | Owns |
|---|---|
| `ChatSlashCommands.swift` | `ChatSlashCommandRegistry` and routing: shared command recognition and execution host contract; surface presentation remains local |
| `Dispatcher.swift` | `DispatchResult`, read-only `SwiftNativeDispatcher` with a fail-closed writable-handler boundary and direct trace receipts; dispatch status and read verification derive from `ChatToolOutcome` exact/display classes; partial reads retain visible output without a fabricated error or verification claim |
| `LocalToolImage.swift` | `LocalToolImage`: turn-local admitted image continuation and bounded thumbnails, including every chrome.look spelling; pixels never enter durable JSON/transcript receipts |
| `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `dispatchNativeAction` uses `LocalConnectorActions.nativeReadOnly` |
<!-- END GENERATED BLUEPRINT -->

### Dispatcher/Actions

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/Actions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Dispatcher/Actions/ -->
| File | Owns |
|---|---|
| `DirectoryInventory.swift` | File metadata and bounded directory inventory |
| `FileActionContext.swift` | File source, path authority and authenticated connector context |
| `FileMutation.swift` | Guarded write, transfer and Trash operations |
| `FileReading.swift` | Descriptor-bound file windows, matching and excerpts |
| `FileSystemActions.swift` | `FileSystemActions` file operations and shared path/value functions; workspace mutation resolution, allowed roots and sensitive/private-store fences; `SwiftNativeSecurityCenter.fencedAttachment`; descriptor-bound byte windows, line queries/excerpts, guarded writes, transfers, Trash, metadata and budgeted directory sizes; `FileReadSourceMaterial` descriptor-only source port |
| `FileSystemVerifiedPath.swift` | `VerifiedImageRead`: shared image delivery from verified file or owned Chrome capture bytes; source dimensions and bounded-thumbnail receipts remain intact |
| `LocalConnectorActions.swift` | Canonical file/system handlers and verification flags; `nativeReadOnly` selects the exact seven native/slash tools |
| `MachineFactsActions.swift` | `FileSystemActions.systemInfo`: machine and application facts, disk capacity, memory, processes, network, boot, presence and battery; existing bounded process reads |
| `PersonaSystemActions.swift` | Protected persona tool reads through PersonaEngine's document selection and the filesystem owner's sensitive-path/regular-descriptor checks; skill/workspace read adapters; `ClockReply` owns timezone selection and date projection with local/chat field adapters |
| `ProcessCapture.swift` | `runProcess` Foundation and descriptor-pinned launches share bounded capture and settlement; executable lookup, result flags, pipe capture and condition-based timeout ownership |
| `RepositoryReadActions.swift` | `FileSystemActions` repository reads: descriptor-pinned grep, parsed Git status, dated diff/log and dirty summary; Git executable, environment, config and sandbox policy shared with `FileReadSourceMaterial.shellReadLaunch` |
<!-- END GENERATED BLUEPRINT -->

### DoctorChecks

Directory: `Modules/NativeAgentCore/Sources/DoctorChecks/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DoctorChecks/ -->
| File | Owns |
|---|---|
| `ChatChecks.swift` | ChatSessionsCheck and ChatMessagesIntegrityCheck read session and transcript stores without mutation; ChatMessagesScanCache memoizes canonical-path fingerprints and scan counts |
| `DoctorChecks.swift` | SwiftNativeDoctorChecks inventory and execution; seventeen ordered checks, StorageCheck-first preparation, concurrent measurements, scoped repairs and shared heartbeat exclusions |
| `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |
| `DoctorReadings.swift` | Shared Doctor readings, ownership, recovery steps, executable repair and provider observation values; CheckResult preserves the report and experience projection shape; app defects never create coding requests |
| `DoctorRunsInspectorChecks.swift` | Inspector health verdict from the engine's persisted-trace observation state |
| `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |
| `DoctorStatusProjection+Config.swift` | `AutoDoctorConfig`; `DoctorReadout`: `readAutoDoctorConfig`, `boolValue`, `intValue` |
| `DoctorStatusProjection+Hardening.swift` | `DoctorReadout`: `getProductionHardening` |
| `DoctorStatusProjection.swift` | `DoctorReadout` enum; `healthReadings`, `persistDoctorSnapshot`, `recordReadings`, `repairProjection`; Experiences owns repair obligations and settlement, while Doctor owns the measured postcondition and executable repair call; historical calls are never reanimated; DoctorPlainCopy owns severity classification for Doctor/Support aggregation and adverse admission |
| `ICloudChecks.swift` | ICloudBridgeStateCheck measures the active iCloud transport and local sync bookkeeping; repairs only missing bridge directories and preserves signed transport and account verdicts |
| `IdentityAbilityChecks.swift` | PersonaEngineCheck compiles canonical identity documents and the saved onboarded profile without seeding identity; AbilityFilesCheck reports file and seed-install failures |
| `MemoryModelChecks.swift` | MemoryStoreCheck inspects canonical memory and graph counts; CoreMLEmbedderCheck measures installed assets and model loading, repairing only the compile cache |
| `ModelCompensationsCheck.swift` | Doctor-only, read-only counts of `shim.fired` by census ID since the current build launched; no compensation judgment or repair |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DoctorChecks diagnostics |
| `OAuthChecks.swift` | OAuthTokenExpiryCheck measures credentials through their owners; inspection never exchanges tokens and scoped repair refreshes only expired refreshable credentials |
| `ProductionHardeningSummary.swift` | `ProductionHardeningSummary` struct |
| `PromptPrefixHealthCheck.swift` | `PromptPrefixHealthCheck`: measured prefix/cache-shape health from real turn observations and provider token receipts |
| `ReleaseChecklist.swift` | `ReleaseChecklist` struct |
| `SessionIdentityCheck.swift` | `SessionIdentityCheck.run`: session mint-site counts and source/row disagreement diagnostics |
| `StorageChecks.swift` | StorageCheck prepares only STORAGE_SUBDIRS and leaves retired directories and existing contents untouched; RuntimeJSONStoresCheck inspects owner state without mutation; OpLogHealthCheck measures feed readability and compaction |
| `SubconsciousVitalsCheck.swift` | `SubconsciousVitalsCheck`: measured capsule/felt vocabulary and chemistry health from canonical local evidence |
| `SupportDiagnostics.swift` | support diagnostics read model |
| `TurnTraceWindowReader.swift` | Measurement-window policy and coverage through canonical TurnTrace framing |
<!-- END GENERATED BLUEPRINT -->

### DreamREMCycle

Directory: `Modules/NativeAgentCore/Sources/DreamREMCycle/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DreamREMCycle/ -->
| File | Owns |
|---|---|
| `DreamCycleContracts.swift` | `DreamTrigger` enum |
| `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`: `gatherRecentMessagesAcrossSessions`, `feltRankIndex`; timestamps read through ChatSessionRecollections |
| `DreamCycleRunner.swift` | `DreamCycleRunner` actor; `runNightlyDreamCycle`, `reconcileDreamMark` repairs the mark from saved section cutoffs under the run reservation; `integrateMood`, `retryMoodIntegration`, `affectJudgment(inDiaryMarkdown:)` |
| `DreamNight.swift` | `DreamNight` and `DreamDiaryWeeks`: shared diary section/title/prose summary parsing and week grouping across all dream readers |
| `DreamPayload.swift` | `DreamPayload` and `DreamClaim`: the dream's per-claim gentleness and owner-relevance judgments travel with its admitted quote/source provenance; older claims remain unknown for Reach |
| `DreamProvenance.swift` | `DreamEntryProvenance` and `DreamSourceRef`: per-claim dream support, source resolution and section-aware peer provenance |
| `DreamREMCycle+Consolidation.swift` | `REMConsolidator`: one explicitly routed GROWTH completion and proposal parsing with verbatim source-bound supporting passages |
| `DreamREMCycle+HeavyLogic.swift` | REM stateless helpers: persona reads and rendering, durable denial tombstones and old-diary archival; caller retains proposal persistence and approval gating |
| `DreamREMCycle.swift` | `FileBackedDreamDiary`: typed active/archive discovery, filename/day extraction, checked browsing and by-date reads |
| `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DreamREMCycle diagnostics |
| `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |
| `REMConsolidator.swift` | `REMConsolidator` actor; `runWeeklyREM` shares one checked diary window with distillation, filters a fresh tombstone batch and resolves committed causal refs for reflection; `rankedByRecurrence` |
| `REMGrowthEvictionHistory.swift` | `REMGrowthEvictionHistory`: durable original approved-growth eviction records, proposal references and pending reconciliation |
| `REMGrowthWriter.swift` | Exact standalone-paragraph ranges shared by approved append, pin survival and eviction; append preserves authored headings |
| `REMPinsReader.swift` | `REMPinsReader`: checked mtime-cached pin reads; only absence is empty, unavailable bytes fail the turn; `latest` |
| `REMProposalStore.swift` | `REMProposalStore`: canonical proposal JSONL, checked reads, legacy import, approval transitions and bounded compaction |
| `REMReport.swift` | `REMReport`, `REMRunReportPayload`; manual completion validates counters and refuses skipped passes as completion |
<!-- END GENERATED BLUEPRINT -->

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

`EngineLaunch` keeps recovery, launch admission, task lifetime, loop ordering and
quit settlement. `EngineChatSurfaces`, `EngineDreams` and `EngineScheduledWork`
compose chat transports, Dream/REM and scheduler/Workshop capabilities.

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
domain owners. A delayed senses registration cannot install residents after stop.
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
Launch recovers interrupted Mac and browser operations after restore and
before engine creation or ingress. Browser recovery failure uses the existing
startup failure presentation and prevents admission; resident approval
reconciliation no longer runs restart recovery against newly admitted work.
Desk's finished execution history includes the execution owner's `stopped`
status, including active records projected as stopped after a backup restore.
Desk presentation treats nonfinite or unrepresentable ages as unknown and
invalid or overflowing timer counts as unavailable. Step progress clamps
before adding its one-based offset; movement evidence binds each handle
before grouping rather than force-unwrapping a filtered optional.

`RuntimeReadProjection` owns the Mac-local `ActivityEvent` ledger value beside
its tail reader. It writes `executionId` and permanently reads historical `missionId`.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/EngineRuntime/ -->
| File | Owns |
|---|---|
| `AgentContactRow.swift` | Contact identity/health folding, per-door authority and shared status vocabulary; ContactListFacade retains one checked door read, with primary contacts derived from it. |
| `AgentVoice.swift` | Agent name grammar and lock-protected live voice shared across presentation surfaces |
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |
| `ChatModels.swift` | `ChatMessage`: `ChatMessageMetadata`, `CodingKeys`; decode-only inline cards travel with loaded message revisions and never re-encode onto transcript wire; Mac ImageIO generation fills Shared's optional attachment preview bytes with a 720px display decode; transport copies can omit previews before rejecting history; concrete Markdown export and clipboard formatting |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `ChatTranscriptCache.swift` | `ChatTranscriptCache`: file-identity disk revisions feed transcript messages, recollections, context statistics and search; bounded shell opening/last-turn scans share the cache owner |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `ConnectorRecord.swift` | `ConnectorRecord`, `ConnectorActionRecord` and descriptor readiness projection |
| `ConnectorStatusProjection+Actions.swift` | connector action registry, records and checked capability statuses |
| `ConnectorStatusProjection+LocalIntegrations.swift` | connector platform actions, EventKit status, local proof and phone readiness snapshots, action evidence; Mac assistant catalog reads invoke the editable `mac-watch-catalog` seed through L0 Parts.call with effects refused; integration recovery parts supply words only over native reasons, preserving operation status/identity/effects, including batch actions, with visible recovery unavailability |
| `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile rows and commands use their own checked refresh result from ConnectorReadiness; Mac and phone toggles share update and its checked verification; committed disconnect fences earlier reads through write before lane restart and checked verification. |
| `ConnectorStatusProjection.swift` | `ConnectorReadiness` observable engine owner: `LatestRead` publishes checked accounts, secret metadata and credential-free Slack policy; committed account updates publish through `write`, mutation verification uses its own refresh result; source invalidations; `connectorRowWithRuntimeOverlay`, `readConnectorRecords` (finishes pending Slack saves before seeding an absent registry with undecided choices; publication failures propagate), `updateConnector`, `restartSlackLane` (a Slack toggle or a phone Disconnect rebuilds the Socket Mode lane from what is saved); connector pages share decayed action/HTTP receipt evidence, including the Slack door's Web API calls |
| `ContactAddressBook.swift` | ContactListFacade owns checked address-book doors and their LatestRead publication and contact-change watch |
| `ContactConversationReads.swift` | AgentContactThreads and shared contact values read canonical contact conversations, helper results and isolated live flights for desktop and phone |
| `ContactThreadReadouts.swift` | ContactThreadReadouts and ContactFlightReadout own mounted contact/helper/crew observation and LatestRead publication; live-only ticks update isolated flight slots |
| `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceipts`; shared context trace/receipt facts and checked Composer receipt reader using the caller engine's root for trace and provider/window reads; sizes are nonnegative whole counts, checked totals and estimates stay unavailable when unrepresentable |
| `ConversationAttention.swift` | `MacChatUnreadSessions`: phone activity remains unread until its conversation opens; persisted unread IDs exclude the active conversation |
| `ConversationRoutes.swift` | Saved SidebarItem route vocabulary and aliases, shell tab homes, SkillsToolsSection and fixed conversation provenance labels |
| `ConversationRows.swift` | `ChatShellConversationRow`, `ChatShellEnvelope` and running-session routes project conversation identity and visible rows; `ChatShellOpeningLine` owns bounded preparation, cached revisions and `LatestRead` publication per standardized data root; classification and subtitles use that owner; human titles stay native and automated title prose is prepared by the batched presentation face; trouble derives from loaded messages |
| `ConversationSearch.swift` | `CommandPaletteMessageIndex` and saved bot/memory search inputs remain owned by `TranscriptsFacade`; `LatestRead` orders checked publication per root; `TranscriptSearch` projects the same provenance-selected visible words as conversation rendering |
| `DeskActivityPresentation.swift` | Desk lane availability, movement evidence, live activity expiry, program-family eligibility and execution progress |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `DeskItemPresentation.swift` | Desk tones, item freshness and shared relative-time wording with exact next-change boundaries |
| `DeskPagePresentation.swift` | Desk page snapshots, attention, project/deadline composition and wording from one frozen board read |
| `DoctorEmbeddingDownloadCheck.swift` | `DoctorEmbeddingDownloadCheck` enum; embedding download health `read`, `repair` |
| `DoctorProviderPathReading.swift` | Doctor captures checked routing before one catalog read; returns path diagnosis and the same provider rows for coverage, preserving pending-selection faults |
| `EngineApprovalNotifications.swift` | `ApprovalNotificationDelivery`: approval discovery, pending-state selection and notification delivery coordination |
| `EngineApprovals.swift` | `ApprovalsFacade`: one checked records/loading/error publication for health, sidebar, views, actions and phone overview; failed reads retain checked rows and mark them unavailable; shared inline settlement, single-flight resolution and outcome/preflight checks; shared summary/failure wording; Approval reads return their own result; LatestRead orders records/failure publication and committed decisions use write(). |
| `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands` struct; `ability_manage` verbs over `Parts`, the owner's card for a keep and decision receipts; `CapabilityCommandOutcome` invalidates UI projections |
| `EngineChatSurfaces.swift` | NativeAgentEngine chat-surface composition: Slack Socket Mode, Telegram polling, approvals, provider choices, speech transcription and permission cards |
| `EngineCognitionModels.swift` | `LivingStatusSnapshot` and `DreamReport` completion and status interpretation |
| `EngineCognitionView.swift` | `CognitionViewFacade`: checked diary/gate revision and file invalidation shared by Dreams, Settings and search; root-scoped model-call readout/refresh; `LatestRead` owns observatory, proposals, vitals, model-call and Living Status publication; watched paths and coalesced refresh coordination; `DreamDiary`: `FileBackedDreamDiary` rows |
| `EngineComposition.swift` | Concrete runtime and background-work composition through the existing root-bound engine ports |
| `EngineConnectors.swift` | ConnectorReadiness workspace/action reads publish through LatestRead; committed workspace additions publish their own checked result through write; native connector execution supplies its engine root and originating `ToolsFacade.withPartDoor` before calling the domain; no second connector facade or account snapshot. |
| `EngineContactCommands.swift` | Person-initiated sends, verified-session stop commands and held-message withdrawal through engine dispatch; Contact sends/stops and core bridge/A2A construction over the injected engine |
| `EngineDesk.swift` | DeskFacade retains one complete board/overview/page snapshot for Mac and DeviceSync, including prepared attention rows and deadlines; engine inbox/approvals/bots supply its lanes. LatestRead orders board, workflow, research and scheduler publication; committed research receipts use write, scheduler repairs fence older reads before checked feed readback. Job observation and refresh coalescing share the retained feed. DeskToolDispatchRouter retains the local-click approval filer while dispatching native mutations through the canonical part door without a model-routing prerequisite, including Make's Try again. |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeviceSync+Snapshots.swift` | Phone snapshot/action adapter; remote Mac control translates through engine Trust and the platform native route; engine owners: retained Desk board/overview and checked inbox/approval lanes, connectors through `engine.connectors`, persona through `engine.persona` (PersonaFacade), runs through `engine.runs`, skill inventory through engine.tools; shared transcript/card/navigation, other-room exchange and live layout projections; conversation rows carry engine classification and assistant rows carry persisted tool evidence; Trust serialization delegates to `engine.trust.snapshotData`; proposal first_seen/last_seen/staged_at project createdAt and resolved_at is unset; signed incoming-turn delivery and handoff ordering; approvals carry the selected Mac turn ID for transcript anchoring; native presentation and cross-area assembly through ports |
| `EngineDeviceSyncHelpers.swift` | Phone helper edit validation, revisions, provider pin/follow semantics and contact commands; `editBotDefinition` fresh merge/timing; `botsShelfRead` supplies one helper status projection to Mac and DeviceSync; action receipts use the committed definition independently of snapshot refresh, whose `helpers_snapshot_error` marks the phone's shared helpers snapshot stale without failing the committed action; successful refresh replaces it without status overrides |
| `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`: cognition health and repair; APNs diagnostics name the canonical push-token store, never retained mobile_push/tokens.json |
| `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`: one launch refresh after a persisted terminal turn trace; retains its task and disarms both observation and refresh on launch stop |
| `EngineDoctor+StatusChecks.swift` | `DoctorFacade`: checked Desk attention and Activity facts go through L0 Parts.call to Resources/abilities/diagnostic-narration.js outside view rendering; native measured status, approval/store failures, corruption detection, unknown-outcome reconciliation and parent repair remain here; an unavailable narrator is explicit without being mistaken for a canonical read failure |
| `EngineDoctor.swift` | DoctorFacade owns report evidence, tool health receipts, loop verdicts and DoctorPlainCopy summary/issue rows; rooted weekly digest/error, activity, hardening/exports, gauntlet, health card, liveness, watchdog and live report refresh publish through LatestRead; completed reports and committed exports use write. RuntimeHealth is liveness metadata; lifecycle facts remain manager-owned; run history belongs to engine.runs. |
| `EngineDoctorHealthReads.swift` | EngineDoctorRuntime assembles health cards through DoctorReadout, merges live report rows and reuses completed support reports within the existing TTL |
| `EngineDoctorMeasurements.swift` | EngineDoctorRuntime reads live provider, search, Telegram, memory, tool, autonomy, bridge, contact, loop and organ health; shared memory/search caches retain their measurement bounds |
| `EngineDoctorRepairs.swift` | EngineDoctorRuntime selects and executes owner repairs, persists compatible receipts and retains the search-backend absence marker |
| `EngineDoctorRuntime.swift` | EngineDoctorRuntime and EngineDoctorPlatformPort retain live check orchestration, frozen repair admission, cancellation, rechecks and repair-obligation publication |
| `EngineDreams.swift` | NativeAgentEngine dream and REM commands, pending proposal staging and notifications; only a committed dream wakes EnginePractice |
| `EngineInbox.swift` | InboxFacade publishes checked items, triggers and read errors through LatestRead; each caller receives its own rows; markRead and committed trigger changes use write; owner-scoped observe/observeTriggers, including canonical ability invalidations for authored trigger defaults, loading and availability; newest physical row per stable card id. |
| `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery starts independently at launch, its install observation once part wakes are registered; trusted bundled seeds installed before ingress; current seeds follow changed shipped bodies, while edited/non-seed content and other occupied slots are preserved, each failure retained by AbilityFilesCheck and reported through Doctor to the person while launch continues; an installed seed the readable bundle no longer ships, still its proof's candidate and never re-enabled, is switched off through its registry (restorable); root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, procedure-retention root admission; one retained quit settlement joins producers and tracked turns before the final snapshot and dependency retirement, shared by both quit bounds, background loop manifest; resident composition lives in EngineChatSurfaces, EngineDreams and EngineScheduledWork; native effects arrive through EngineBackgroundWorkHost; MCP servers a data root kept are raised to their once by name as theirs to grow (`raiseKeptMCPServers`), their file untouched and, since a launch line can carry a key, fenced from their file readers with its backup copies; `tellRetiredConnectors` removes retired service rows and tells their once which were set up; old credentials stay untouched and unread; the engine exposes the existing activity controller through its body host; termination stops EnginePractice and waits for its settlement |
| `EngineMacIntegration.swift` | `MacIntegrationFacade`: root-specific checked permissions, nonprompting OS grants and watch readiness publish through `LatestRead`; explicit Mail evidence shares the same owner and invalidation; Setup, Mac Integration, connector actions and quiet pages share these reads; permission-file and root-specific notifications invalidate the same owner; phone serialization uses its own returned checked permission result |
| `EngineMaintenanceParts.swift` | EngineBackgroundWorkPort enters ToolsFacade.withPartDoor for L0 Parts.call of maintenance-assistance and backup-cadence; preserves backup-cadence cancellation as CancellationError; returns typed card prose, optional deadlines and trigger choices without publication or backup execution authority |
| `EngineMemory.swift` | Memory v2 status and read availability publish through `refreshStatuses`; pending proposals publish checked rows and failure together through `proposals(status:)`, retaining checked rows on failure and leaving decision animation to the Mac; canonical recall keeps request identity separate from retained rows' successful query and never substitutes inventory matches; memory reads/writes and durable review-reminder crossing; one checked `graphSnapshot` shared by Knowledge Graph and Capabilities; `ProposalRecord` evidence; LatestRead orders pending proposals and memory status; committed proposal decisions use write() with the Mac's existing animation transaction. |
| `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`: native owner-response interpretation, approval reread and composer admission |
| `EnginePartWake.swift` | `EnginePartWake`: `start`, `deliver`, `run`, `readsOnly`, `reindex`; Autonomy-gated wake index, per-part single flight, including source-triggered sense interpretation (material/transport stay source-owned, bundled senses need no wake header); a `held`, `resumed` or source-subscription wake Autonomy refused waits (`holdBack`, preserving source slot/helper generation independently of the header index) and is delivered when a trust-policy change finds the switch on; unreadable authority clears the index with repair owed, and a `held` or `resumed` wake meanwhile waits for it to read again; tainted signals skip write-capable parts (`tainted_signal` trace, no card); gated resident tools/skills and resident senses; current Chat model and signal audit; file-change watches survive absence and suppress self-writes; stop joins runs and all current/replaced file and trust watchers; turn-end steer retained; `resumed` delivered once at launch; `person.away`/`person.here` signalled from `MacPersonInput.presenceChanged`, whose first deadline is armed from existing idle after this observer registers; header-declared runs are `HerOpened` work |
| `EnginePersona.swift` | PersonaFacade owns profile/documents and retained read availability for Mac, editors and DeviceSync over unchanged PersonaEngine content readers/writers. LatestRead orders reads/failures, committed profile/name/document saves use write; chat/settlement scaffolding keeps its existing effect without discarded diagnostic compilation. |
| `EnginePractice.swift` | `EnginePractice`: the night's practice pass after each dream, one at a time, Autonomy read again before every keep turn, replay and keep, Stop (termination) cancelling it while its ledger still settles: per agent (the resident, each helper) nominate from the retained traces (`TurnPractice`), start the tape for what is nominated, offer a sequence with two or more replayable recorded examples (arguments exact, results as far as kept) whose later arguments are not mostly judgment to that agent's own keep moment (their ephemeral turn on their resident session, a helper's own turn) under `Parts.compiling`, each keep turn bounded by `TurnTokenBudget` and `TurnDeadline` at `BotRunLimits` (a helper's by its own run budget), a version the store holds for the practice adopted by its `compiled` key, then verify the staged version by tape replay (`ability.validate`) and admit it (`ability.enable`: theirs under Full Mac for their own work, else the owner's card) through the gated app door; at most three offers per agent a night; a `practice.night` trace row |
| `EngineProviderHelpers.swift` | ProvidersFacade checked settings refresh, credential/OAuth verdicts, model grouping, eligibility, snapshot-owned model/account inheritance, auth normalization and quiet provider policy; routing-derived selections share SettingsSnapshot. LatestRead orders settings and failures; committed routing publishes through write and retires prior session reads before checked session refresh. |
| `EngineProviders+Adoption.swift` | Blank-surface adoption delegates to the routing transaction and publishes its committed snapshot through LatestRead.write; serialized chat-brain saves retain pending edits, while canonical selection derives from ProvidersFacade.settings. |
| `EngineProviders+Probe.swift` | `ProvidersFacade`: `testProvider`, `clearProvider` |
| `EngineProviders.swift` | ProvidersFacade.settings owns routing, connections, catalog and derived readiness for every Mac picker and phone publication; provider/account invalidations refresh this snapshot. LatestRead orders settings and per-session route/context reads, returning each caller its own result; committed routing publishes through write. ProviderRouting owns persistence, discovery and eligibility; editors hold pending choices only. Catalog rows come only from the live catalog owners; independent ChatGPT, OpenRouter and Moonshot refreshes run concurrently with their existing error/freshness results; the unwritten providers/models.json compatibility input is retired. |
| `EngineRouteError.swift` | Engine route failures and shared UserFacingError interpretation; POSIX error codes compare at NSError's full integer width |
| `EngineScheduledWork.swift` | NativeAgentEngine trigger scheduler and Workshop composition; SchedulerDueJobRunner native effects; scheduled reads enter withPartDoor and watchRefusal before dispatch |
| `EngineSenses.swift` | One engine Senses projection for registry records, actual source/helper watches, news and interactive views through `LatestRead`, committed switches through `write`; visible-window observation of canonical ability files and news/view invalidations, without idle sampling |
| `EngineSync.swift` | `SyncFacade` class; `observeStatus`, `setStatus`; pairing-key snapshot reads publish through `LatestRead`, and rotation advances the same boundary |
| `EngineTelegram+Commands.swift` | Telegram configuration and mobile commands; Telegram token admission, settings and delivery commands, typed diagnostic-clear receipt; diagnostic state edits delegate to TelegramPollLoop.mutateState |
| `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |
| `EngineTelegram.swift` | Telegram facade and tool status envelope; `TelegramFacade` class; `loadStatus`, `load`; status uses TelegramPollLoop's checked state read, reporting unavailable state in lastError; `refresh` alone publishes status through `LatestRead`, including diagnostic-clear readback; credential badges read TelegramPresentationSnapshot.tokenConfigured directly |
| `EngineTools.swift` | ToolsFacade owns authored tools, slash planning, full form descriptors and shared catalog status classification; `withPartDoor` gives native scheduled/UI owners and Tools Keep the ordinary gated chain and AppChatToolDispatcher host, with originating work identity, resident approval session and caller's file-access posture inherited by part thinking; native callers can supply their authenticated envelope and existing approval filer, preserving Telegram transport and Desk-click authority without another door; one checked skill inventory supplies metadata, source/revision and guidance detail from the same body read (phone metadata omits source). LatestRead orders slash, catalog, authored, skill and native-power reads; committed authored writes use write. Native actions derive from their registry; receipts and notification/browser status retain availability. |
| `EngineTrust.swift` | TrustFacade owns checked policy, effective feature verdicts and security status/invalidation; raw/typed policy and phone serialization publish through LatestRead, committed policy through write. Catalog/source/install/network publication, Privacy Map and inbox policy each share a LatestRead; catalog/inbox commits use write. Policy derives autonomy guardrails; connected-agent rows belong to engine.contacts. Rooted Mac audit decoding retains availability and canonical/legacy receipt fields. |
| `EngineTurnContinuation.swift` | `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; completion destination recovery uses the bound engine and attention router; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders; `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders |
| `EngineTurns.swift` | TurnsFacade owns turn lifecycle/Stop/queue/screen-preview presentation, one Capabilities trace feed without an extracted copy, and read-only Agent View pane text/subscriptions keyed by conversation and room; LatestRead orders trace publication and each pane independently. The preview binds L0's pure helper face to its native root without effects and preserves last-seen semantics |
| `EngineWorkshopObservatory.swift` | `WorkshopPursuitRow`, `DeskPursuitVetoRationale`; Workshop read projections |
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletRun` is the stored run schema, typed history reader and manual check runner; `GauntletCheck` |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `TurnsFacade.receiveScreenPreview` publishes the runtime's transient preview vocabulary |
| `MacChatTurnExecution.swift` | `NativeAgentEngine`: Mac turn streaming, checkpoint resume, clear/archive, retry and lifecycle activity use `TurnsFacade.runtime`; producer joins, transcript publication, settlement and queue release retain their order; `ChatTurnToolPlacement` places canonical tool rows before the live reply |
| `MacIntegrationDeliveryActions.swift` | Mac integration protocol execution, scheduler and Spotlight routing; due-reminders passes the requesting dispatcher's root to LocalPIMConnectorActions; Music calls the editable music part through L0, and Mail/Messages/Notes recovery words come from their parts while facts/evidence stay native; mobile notifications delegate to AppToolRuntime with the dispatcher surface; checked pairing and phone result routing; Mac notification receipts and MacControl adapter |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for EngineRuntime diagnostics |
| `MountedTranscriptRefresh.swift` | Mounted and detached chat refresh/observation through the engine shared transcript owner |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`: captures the person's location before shared chat queue admission; chat applies the saved choice |
| `NativeAgentEngine.swift` | Core live/isolated root selection, chat/tool and manifest composition retained independently by contact clients (no borrowed engine lifetime); resident service facades, shared persona/configuration/runs projections and `ConnectorReadiness`; Desk receives the engine's inbox, approvals and bots; owns root-scoped contact/crew and layout observation plus Activity invalidations and the bot scheduler shared by deadlines and read projections |
| `NativeAgentEnginePorts.swift` | Once-installed native host factories, body effects and shared EngineCognitionHost defaults; pure readout faces bind the selected Parts version through the no-effect authored host; read-part calls bind the existing ToolsFacade originating door and narrow the pinned candidate to native-permitted read actions/capabilities |
| `NativeAgentResidentRefresh.swift` | `NativeAgentEngine` onboarding/resident refresh: profile transitions defer mind/context reload until admitted turns drain |
| `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |
| `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |
| `PresentationFaces.swift` | Root-scoped PresentationFaces feeds L0's pure presentation-copy.js cache from frozen inputs outside rendering |
| `PresentationValues.swift` | Shared health and capability presentation values, shared formatter alias and display-string truncation |
| `ProviderChoices.swift` | Provider model catalogs, shared first-party descriptor conversion, Codex auth readout and quiet-composer conformances; reasoning values come from NativeAgentShared |
| `RuntimeReadProjection+Configuration.swift` | `RuntimeReadouts.Configuration`: publishes and returns its own saved SearXNG URL read; configuration reads use the engine projection and the provider owner's `LatestRead` for Codex authentication, while editors retain separate drafts |
| `RuntimeReadProjection+Feeds.swift` | Notification pending counts read only ApprovalInbox; the unwritten notification receipt input and inferred authorization are retired. Browser reads, checked skills with opt-in source/revision from the inventory body epoch, JSON decoding and JSONL tails; engine.runs retains rows and availability through LatestRead and returns its own read for DeviceSync, preserving rows on failure. Saved-things reads delegate to existing Desk, bot, memory and diary owners. |
| `RuntimeReadProjection+QuietPages.swift` | Quiet page/item formatting and navigation over engine projections: Desk uses the complete retained `DeskFacade.page` and its prepared attention rows, helpers use `botsShelfRead` including followingModel, chat cards and heading use the checked transcript projection; unsupported card states share one person-directed defect naming the card; page indexing takes the live layout; Mac access/grants render `MacIntegrationFacade`; connector items expose secret names without values; shared Trust, provider, inbox and settings read formatting |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadError`: unreadable feed detail shared by checked runtime readers |
| `RuntimeReadProjection.swift` | Autonomy delegates to TrustFacade's policy projection; unused personal-OS compiler read is deleted (Capabilities renders the published profile); `getSessionContext` requires the effective session provider |
| `RuntimeSummaryModels.swift` | `KernelGuardrail` struct |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SelfImprovement+TrainingReads.swift` | `HarnessBenchmarkRun`, `HarnessBenchmarkCheck` models and benchmark execution returning its result without a duplicate receipt store; unused `evals/runs.json` reads/schema and `harness/benchmark/runs.jsonl` writes/retention are retired; retained files stay on disk, outside backup, export and phone sync, and appear in PrivacyMap |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SurfaceRuntimeStatusModels.swift` | Approval-backed notification pending status and browser status models; no unwritten notification receipt or inferred authorization fields; browser status exposes capture paths, with no unused profile path |
| `TelegramEvidence.swift` | TelegramPresentationSnapshot, transport health, receipt/blocked/error Codable records and concrete tool health receipt |
| `ToolReceipts.swift` | ChatShellToolSummary frozen tool facts, status classification and exact persona-write receipts; TranscriptsFacade prepares shared fold headlines and up to four expanded details |
| `TranscriptReading.swift` | TranscriptsFacade canonical file/index reads, retention and one-revision card/attachment preparation |
| `TranscriptReadout.swift` | Transcript/card structures, page-bounded inline mounts and structural message grouping |
| `TranscriptSessionMutations.swift` | TranscriptsFacade session creation, rename/archive and canonical transcript clear with unchanged lock ordering |
| `TranscriptsFacade.swift` | Root-scoped observable transcript/session publication, navigation and streaming cache; LatestRead preserves each read and committed clears |
| `TurnCardReadout.swift` | `MacChatTurnCardModel`, `TurnCardReadout` and `MacChatTurnCardFormat`: display-only lifecycle, approval, visibility and whole-second timing projection; canonical turn state and approval records remain authoritative |
| `WorkOverviewRead+Today.swift` | `TodayReadout` freezes checked sources and provenance, feeds the pure `today-readout.js` faces through L0's version/epoch cache, binds source IDs to native dates and note links, and publishes through `LatestRead`; waiting counts share a pure face too. `TodayDreamDigest` reads the latest dream through `DreamNight`; native input supplies its title, mood and timestamp, never diary Markdown for JS to parse. Narration, grouping, due words and ordering live in the part. Unbound rows are omitted individually with native reasons; other activity, Ahead, earlier notes and note links remain. Native unavailable evidence, localization and live clock gutters remain. Mac and quiet reads consume the same prepared rows |
| `WorkOverviewRead.swift` | `WorkOverviewRead` enum; `project`, execution/Desk-item `row`, `text`, `requiresApproval`; overview and phone task rows share the execution approval predicate; ID-based details use the same status projection; complete owner-attention counts by reference kind before mobile list bounds |
| `WorkStatusPublication.swift` | Per-AppModel MainActor publication: one board read, coalesced requests, needs-owner push evaluation and change-suppressed widget status |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/ !Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift !Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: `mailListRecent`, `mailSearch`, `mailSend`, `mailDraft` |
| `MacAppleScriptBridge+MailAppleEvents.swift` | `MacAppleScriptBridge`: Apple Event scripts, bounded identity lookups and encoded Mail record framing |
| `MacAppleScriptBridge+MailIndex.swift` | `MacAppleScriptBridge`: read-only Envelope Index queries, account coverage, exact sender counts, mailbox pages and sender formatting |
| `MacAppleScriptBridge+MailMessageBytes.swift` | `MacAppleScriptBridge`: paired-identity .emlx reads, contained attachments and bounded MIME/HTML decoding |
| `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: bounded workspace-read orchestration and mailbox scope validation |
| `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: Messages list field projection and shared date/duration windows, `messagesSend`, `notesModify` (exact-note update or reversible deletion) |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`: delegates `runAppleScript` to MacControl, skill hand-back and integration envelopes; `deniedEnvelope`; Music recipe/parsers live in the editable `Resources/abilities/music-library.js` and `music.js` seeds, called through L0 `Parts.call` by MacIntegrationDeliveryActions; the playback receipt and effects survive failed readback as a separate `now_playing` fact, and exact title/artist selection uses Unicode full case folding |
| `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in AppleScriptExecution |
| `MacAssistantStatus.swift` | assistant status composition from evidence snapshots, client contract, result, lightweight serialization, Mail readiness projection and native watch access evidence; typed catalog data and UI words come from `Resources/abilities/mac-watch-catalog.js`, never creating jobs; missing/disabled/invalid catalog is unavailable, never an empty catalog |
| `MacContactsExecutor.swift` | concrete `CNContactStore` ownership, authorization, selection, mutation validation, name cache and projection |
| `MacLocationReader.swift` | One retained CoreLocation manager, cached authorization and bounded fresh-fix requests |
| `MacMessagesHistory.swift` | protected Messages-directory access probe, bounded SQLite reads, latest-unread thread filtering, date-bounded ordering and folded matching |
| `MacMessagesTypedString.swift` | bounded attributed-body archive decoding |
| `SystemPermissionPreflight.swift` | Observed OS grants, request admission and one capability vocabulary for permission cards |
<!-- END GENERATED BLUEPRINT -->

### MultimodalTTS

Directory: `Modules/NativeAgentCore/Sources/MultimodalTTS/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MultimodalTTS/MultimodalTTS+VoiceSelection.swift -->
| File | Owns |
|---|---|
| `MultimodalTTS+VoiceSelection.swift` | voice authority/routing, native/cloud playback, generations/cancellation; `VoicePreference`: `quiet`, `name`; auto-read decision |
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
| `MacAXActSource.swift` | AX action targets, outcomes, source contract and unavailable-platform construction; window presence distinguishes unreadable inventory from absence |
| `MacAXAttributeRead.swift` | `MacAXAttributeRead` enum; one checked raw attribute copy preserves AX failures for required native evidence, with nil-tolerant perception/action projections; package-native clients share raw/string, parent, label, action-name and frame reads; static-text selectors use their text when no caption names them, while field values stay separate; visible list/table/outline child ordering shared by reads and action paths, on-screen/total counts; `copyTextRange`, `copyRaw`, `copyWindowIdentity`, shared identity `copyLabel` retaining redaction captions, separate display names with help cleanup and explicit AX title-element captions |
| `MacAXEffectObservation.swift` | `MacAXEffectObserverSource`, registration and collector: payload-free AX notifications, bounded signal waits and idempotent removal on the shared AX execution lane |
| `MacAXElementSource.swift` | Read-only element source contracts and defaults |
| `MacAXObservation.swift` | Anchored accessibility reading, scoping and search |
| `MacAXValues.swift` | Accessibility identity, geometry, node and query values |
| `MacAccessibilityActuator.swift` | Selects and reports AX value/action or explicitly admitted synthetic click, preserving source rereads and result receipts |
| `MacAccessibilityReader.swift` | Shared AX walker and node/depth/time budgets; package-native window/subtree and direct-child reads use that walker with topology-only snapshots and optional caller-scoped descent, report incomplete reads with search purpose, visited count, unseen floor and reasons, and never collect credential values; passive native reads share its deadline and cancellation; native reply text requires readable static AXValues and checked topology subroles; `SystemMacAXElementSource` owns exact native window inventory and transient menu roots |
| `MacActClosedLoop+EffectDifferences.swift` | `MacActClosedLoop`: effect-difference records, redacted JSON, walk comparability, `diff` and target-owned press evidence; complete comparison sets retain receipt caps and context redaction |
| `MacActClosedLoop.swift` | `MacActClosedLoop.verify` owns the declared-effect verdict for semantic, menu and physical act receipts: exact complete AXValue, selection range, selected/state/focus, owned window/sheet creation, confirmed removal or process exit and AX surface transitions; pixels are witnesses only; readable mismatches are `acted_mismatch`, unavailable readback (including canonically masked text values) is `acted_unobserved`; an unchanged surface without press evidence is unobserved, never a mismatch (only a contradicted destination is) |
| `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |
| `MacActSerial.swift` | `MacActSerial` serializes named/exact acts and watch hands, releasing held input on driver transfer |
| `MacAppIndex.swift` | One in-process live Spotlight metadata query over local volumes; rows excluding bundles inside packages materialize only on gathering/update edges on its owning queue; cancellation removes async initial-gather waiters; startup failure retires query/tokens and completes gathering once; terminal `shutdown()` closes admission, stops query/tokens and finishes streams on that queue (engine caller integration remains required); sync/async reads and exact lookup share kept rows; newest-only edges emit when bundle id/version/path changes; actionable index failures propagate; `mac.apps` names its Spotlight source; Launch Services remains the launch fallback after an index miss |
| `MacAppMaps.swift` | `MacAppMapStore` owns per-app control maps and control-scoped press outcome evidence; reads and flush outcomes are checked, failed writes stay dirty, and malformed maps remain in place without overwrite |
| `MacAppNavigation.swift` | `MacApplications`, `AppControlRunResult` and `OpenTarget`: exact application resolution, launch, measured focus, quit and URL/file opening under the existing driver authority |
| `MacAppSourceEvents.swift` | `MacAppSourceEvents` class; event-backed running-app AX observation, coalescing, cancellation and notification-stall completion for cold reads; incomplete traversal retains prior subscriptions and only a complete read prunes missing descendants, application/window/focus subscriptions stand if any succeeds, and zero supported notifications is `source_unsupported` |
| `MacAppWindowText.swift` | `MacAppWindowText` enum; one positional-redacting on-device recognizer for current app-window capture and ephemeral whole-window shots before text-only retention |
| `MacAppleEvents.swift` | `AppleScriptExecution`: bundle-specific AppleScript/JXA targets and Automation status; URL-bound launch:false calls, native per-event read-only enforcement and Music playback settled once against the original track/process/command |
| `MacAttention.swift` | `MacAttentionSessionStore` owns driver authority, synchronous physical takeover and optional bounded view sessions; `MacDriverBinding` owns held-input release, foreground/background authority and cancellation-independent settlement under the original driver generation; session stop/expiry leaves passive observation active, explicit handback revokes control |
| `MacAttentionEvents.swift` | Passive attention activity and observation sources; AppKit monitors share person-input provenance and person-only-window exclusions, retain scene-change events and reduce keyboard events to pulses; pointer coalescing never delays synchronous takeover |
| `MacAttentionObservation.swift` | Bounded attention readout and observation continuity |
| `MacBackgroundSight.swift` | `MacBackgroundSight.resolve`: exact running and installed identities precede partial running-app matches without activation; missing, ambiguous, unavailable and self targets remain distinct |
| `MacChromiumAccessibility.swift` | Chromium accessibility flags and verified native readback |
| `MacClipboard.swift` | `MacClipboardRead` and pasteboard ports: permission-bound clipboard reads/writes, source redaction and bounded text/type projection |
| `MacControl+Client.swift` | `SwiftNativeMacControl` actor; `dispatch`, `dispatchApprovedInjection`; `MacObservationMode` carries passive read authority without motor binding, wake, capabilities or desktop effects |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl`: `handleAct`, `pointerRestoredJSON` |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: `waitForTextInput`, `handleHand`, `watchedWindowMiss` (a watch's events land on its window, read at each event), `handleNudge`; text input verifies focus, selection and value with cancellable 25ms polling bounded to 750ms; hand text mismatch excerpts are always redacted because its readback lacks canonical caption/group redaction context |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`: `handleMenu`, `handleMenuPress`, `handleClipboardRead`; surface menu commands await surface-transition notifications within the existing deadline before owned-window readback; Select All keeps its range readback |
| `MacControl+OperationSupport.swift` | `SwiftNativeMacControl`: `attachingOperation`, `replayResult`, `unknownResult` |
| `MacControl+Perception.swift` | `SwiftNativeMacControl`: `handleRead` reads live window text unless the caller names a file; semantic view masks pixels from the complete AX snapshot's secret frames before sharing |
| `MacControl+SystemActions.swift` | `SwiftNativeMacControl`: `handleFileRead`, `handleFileWrite`, `handleFileList`, `handleMedia` (Now Playing system keys and running-player observations) |
| `MacControl+TextEditing.swift` | `SwiftNativeMacControl.typeText`: replacement, append and continuation typing preserve the act's mutation ledger, focus gate, exact expected text and partial-input receipts |
| `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |
| `MacControlActionRoutes.swift` | Canonical MacControlResult dispatch receipts plus workbench availability and category policy |
| `MacControlAdmission.swift` | Canonical desktop policy and input admission; passive observation carries no motor authority |
| `MacControlContracts.swift` | `MacControlResult`, `MacControlClient`, `MacMotorCount` and action families: dispatch receipts, read/effect classification, shared policy categories and policy-provider contract |
| `MacControlOperationStore.swift` | `MacControlOperationStore`: canonical payload-free operation lifecycle, request digests, cancellation settlement and motor projection |
| `MacControlSettlement.swift` | Desktop operation settlement and byte-compatible refusal audit receipts |
| `MacCrossAppDrag.swift` | `MacCrossAppDrag`, `MacFourVerbs.performCrossAppDrag`: two-anchor drag resolution, destination raising and secure/obstructed path refusals with actual-effect evidence |
| `MacDocumentObservation.swift` | Document reading and screen text extraction within the existing observation |
| `MacDocumentRead.swift` | `MacDocumentRead`: bounded document extraction and scrolling accumulation; observed scrollbar restoration, admitted file access, deadlines and redacted read frames |
| `MacDocumentReadTakeover.swift` | `MacDocumentReadTakeover.mark`: physical-input takeover signal for bounded reads, preventing subsequent wheel emissions without changing permissions |
| `MacFileAccess.swift` | `FileBytes`: bounded regular-file reads/appends, atomic writes, directory listing, verified entry moves and trash |
| `MacFourVerbs+Act.swift` | `MacFourVerbs`: `act`, `addAttention`, `frontChangedWords`; named/exact act dispatch, repetition and semantic/physical effect receipts |
| `MacFourVerbs+AppMap.swift` | `MacFourVerbs` app-map integration: remember verified named controls; control-scoped pointer hypotheses retain contrary and uncertain outcomes, match fresh live evidence and never block background Accessibility |
| `MacFourVerbs+Batches.swift` | `MacFourVerbs`: `actSteps`, `SightCarry`, `ActFlow` and step digests; cancellation and confirmed effect mismatches stop further steps while preserving landed or uncertain receipts for resume |
| `MacFourVerbs+Foreground.swift` | `MacFourVerbs`: `FrontExpectation`, `actBroughtForward`, `settlementDispatch`, `missBeforeRaise`; named-app acts borrow and settle the exact foreground window under the driver generation |
| `MacFourVerbs+MenuCommands.swift` | `MacFourVerbs`: menu lookup, command receipts and popup selection; menu paths retain foreground targeting, ambiguity and declared-effect verification |
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `webURL`; landing targets the recipient returned by Launch Services |
| `MacFourVerbs+Observation.swift` | `MacFourVerbs`: `screen`, `observedReply`; self-window looks hand off to mounted `visible`, naming the person's app behind their (`appBehindMe`); observed and blind replies preserve failed effect verdicts and confirmed window/process removal across app changes |
| `MacFourVerbs+PerceptionSupport.swift` | `MacFourVerbs`: shared rendering/targeting `partition` and `supplementalDuplicateIndex` |
| `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: `performPhysical`, `performPointer`, `performAtPlace` |
| `MacFourVerbs+ScreenFusion.swift` | `MacSightCaptureBinding` and `MacFourVerbs.sight`: call-local compiler percept, complete AX read and pixel fusion bound to window identity and frame generation; preserve redaction and natural target addresses |
| `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: supplemental AX native-page merge, `zoom`, `parseVerb`, `isRightClick` |
| `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: `resolve`, `answers`, `bareNumberNote` |
| `MacFourVerbs+Wait.swift` | `MacFourVerbs`: `wait`; app-level signals prompt bounded screen re-reads; action verification uses its owning bounded polling waits without additional subscriptions |
| `MacFourVerbs+WorkspaceControl.swift` | `MacFourVerbs` workspace acts: fresh exact frame/app/window/handle checks; supplemental surfaces never raise background apps for physical input |
| `MacFourVerbs.swift` | `MacFourVerbs` struct |
| `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient` |
| `MacFusedObservation.swift` | Fused semantic and marked-image capture |
| `MacHandRepertoire.swift` | `MacHandRepertoire`: constructs bounded keyboard/pointer step sequences with one drag interpolation, held-key/button balance and residual-release accounting |
| `MacInjectionApproval.swift` | `MacInjectionCapability`, ledger, context, approval digest and secret vault: body-bound expiring single-use input authority and redacted approval evidence |
| `MacInputEvents.swift` | `MacEventSink`, `DriverCheckedMacEventSink` and `CGEventSink`: driver-checked input, native event preparation and HID/per-process emission |
| `MacKeyboard.swift` | `MacKeyModifiers`, `MacKeyChord`, `MacKeySyntax`, `MacKeyEvent` and `MacSecureEventInput`: keyboard grammar, layout resolution, literal text limits and secure-input evidence |
| `MacLookFrames.swift` | Retained frame values and task-scoped frame store |
| `MacLookPercept.swift` | Immutable semantic percept, handle and readout vocabulary |
| `MacMenuBar.swift` | `MacMenuBar`: bounded native menu reads, path resolution and safe semantic presentation |
| `MacNativeAction.swift` | Native act execution through the existing text-editing owner and act verification loop |
| `MacNotification.swift` | Notification posting through the app's injected banner exit with truthful unverified acceptance |
| `MacNotificationDelivery.swift` | `NotificationPostReceipt` and `NotificationPosting`: notification acceptance and authorization evidence, without claiming delivery or observation |
| `MacPerceptionCompiler.swift` | `MacPerceptionCompiler`, look frames and handles: graded perception from the existing AX snapshot, redacted readouts and fresh target resolution |
| `MacPersonInput.swift` | `MacPersonInput` owns exact person/synthetic input provenance and canonical presence; motor-fenced session activity permits capture resumption without Input Monitoring and never asserts presence; `NativeAgentMacEventIdentity`, `ScriptedInputSources` and `NativeAgentMotorEpoch` identify their input and motor output |
| `MacPointer.swift` | `MacMouseEvent`, `MacScrollEvent` and `AgentPointerHold`: pointer/scroll event values and bounded ownership restoring the person's cursor after agent input |
| `MacPointerObservation.swift` | `MacPointerPosition` and `MacRegionAim`: actual cursor observation and clear-region aiming; unavailable position never becomes an invented origin |
| `MacProcessExecution.swift` | `ProcessExecution`, `ProcessRunResult` and `ProcessRunCancellation`: shared process launch, bounded capture, pipe-setup error translation, cancellation settlement, timeout escalation and identity-bound process-tree reaping; SSH and local callers use the same runner |
| `MacProtectedPaths.swift` | `MacControlSensitivePathFence`: protected data paths and the shared OS/store mutation floor, including protected parents; reads and copy sources keep their scope |
| `MacSavePanelPlacement.swift` | Save-panel placement through the existing act verification loop |
| `MacScreenPageCompiler.swift` | `MacScreenPageCompiler` enum; complete nested AX reading order, structural/activation alias folding, adjacent checkbox captions in structured and aggregate documents, document title ownership, sentence-first links including aggregate document text, AX landmark and card sections, live-region text with duplicate container folding, display cleanup after full-context redaction, composite rows with status details and exact related-action bindings |
| `MacScreenReadiness.swift` | `MacSessionState`, its sources, `MacWakeGuard`, `MacScreenLock.wakeIfCovered` and `SwiftNativeMacControl.handleWake`: checked console/display readiness, bounded inert wake, focused-password evidence ordered through LatestRead and fused-view wake receipts |
| `MacScreenRender.swift` | `MacScreenText` and `MacScreenRender`: shared semantic/pixel screen formatting that preserves compiler redaction verdicts |
| `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`; `MacScreenViewTextRedaction` owns field/prose secret-label vocabulary with distinct matching rules and shared AX/OCR caption geometry with caller-unit proximity; session-scoped `MacImageFrames` holds delivered pixel geometry under the semantic observation's reference (desktop images mint their own) |
| `MacScreenViewBuilder.swift` | View and mark construction from captured geometry and accessibility |
| `MacScreenViewCapture.swift` | Window/display capture selection, `SystemMacVisualObstructionProbe` (other apps' windows over a frame, for sight and a watch's hands) and `SystemMacScreenCaptureSource`; exactly-once callback cancellation invalidates results and resumes immediately, with no cancellation-ignoring join on an unabortable ScreenCaptureKit callback |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG` masks secret frames before encoding; `encodePNG` |
| `MacScreenViewResultRedaction.swift` | Persisted result previews omit image payloads |
| `MacScreenViewTextRedaction.swift` | One secret-decision owner for text, pixels and enclosing captions |
| `MacScreenWatch+Capture.swift` | `MacScreenWatch`: exact-window frame capture, complete secret inspection and masking before publication; newest pending capture is inspected at its 500ms deadline, without another capture; inspection failure ends the active watch |
| `MacScreenWatch+FrameQueries.swift` | `MacScreenWatch.read`: generation-bound pixel colour, mean, change and redacted text queries; admitted reads publish only while open under the same secret verdict |
| `MacScreenWatch+Hands.swift` | `MacScreenWatch.hand`: frame-pixel input through four verbs on the watch binding, with current authority, exact front window, secret drag bounds and person takeover |
| `MacScreenWatch.swift` | One exact-window ScreenCaptureKit stream per part run, generation-bound frame queries and physical hands in same-owner extensions; person-only windows refused; each delivered frame awaits its complete secret-field inspection and masking; the newest pending capture survives inspection and its 500 ms interval and is inspected without another capture; incomplete inspection ends with an owned failure. Inspection work is retained; success and failure commit only while active, so expiry cancellation cannot cut admitted settlement short or create repair debt. Authority is checked at next/read/hand; window identity at each event. Terminal errors retain their cause; outside an enclosing act Experiences owns repair until an inspected frame from the same window/region arrives or it is let go. Duration stops capture and closes admission immediately; an admitted frame read or hand has up to 10s (the maximum hand duration) to settle before the retained frame and held input retire. Non-cooperative work retains its local frame until actual exit and cannot publish after retirement. Stop, window loss/resize, revocation, part change and takeover retire immediately. |
| `MacSemanticAct.swift` | MacFourVerbs actOnce remains one semantic effect transaction with its existing observation identity |
| `MacSemanticExecution.swift` | MacFourVerbs supplemental semantic/native-hand execution and input grammar under the same driver and act lifetime |
| `MacSemanticObservation.swift` | Semantic look capture and exact-node search |
| `MacTransientMenus.swift` | `MacTransientMenus`: bounded near-focus native menu evidence and capture geometry, without a second window address space |
| `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |
| `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactedText`; fixed OCR caption/proximity rules with caller-owned text limits; one positional caption/overlap redaction boundary for both OCR readers |
| `MacWaitSignals.swift` | `MacWaitSignals` and activation observation ports: cancellable event-driven waits that consume existing app/AX signals |
| `MacWindowActivation.swift` | `SystemMacAXActSource`: driver-checked window raising and measured app activation with Automation diagnostics; app-only activation preserves the self-AX fence |
| `MacWorkContinuation.swift` | One request's bounded native takeover continuation |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MacControl diagnostics |
| `SystemMacAXActSource.swift` | Native AX execution lane, CF-equal source-owned handles, resolution and driver-checked mutations; admission failures retain their own identity |
| `SystemMacAXElementSource.swift` | Native read-only AX source with instance-locked references |
| `TrustedRemoteEffectNodes.swift` | Reads operator-provisioned trusted node JSON and returns SSH execution receipts to the caller |
| `VisionColorRegionLayer.swift` | `VisionColorRegionResult`, `VisionPixelGrid`, `VisionColorRegionLayer` |
| `VisionFourVerbAdapter.swift` | `VisionPercept.fourVerbSupplement`: additive screen contents, controls, values and physical targets with provenance and abstention |
| `VisionHandles.swift` | `VisionHandles` |
| `VisionImageGeometry.swift` | `VisionImageDecoder`, `VisionImageCrop`, `VisionImageCropper`: owned image decoding and geometry-preserving crops |
| `VisionPercept.swift` | `VisionAffordanceRow`, `VisionReadoutRow`, `VisionRecognizedText`, `VisionPercept` |
| `VisionPerceptionCompiler.swift` | `VisionPerceptionError`, `VisionRowDraft`, `VisionPerceptionCompiler` |
| `VisionPerceptionTypes.swift` | `VisionConfidence`, `VisionStateGuess`, `VisionEvidenceSource`, `VisionCandidate` |
| `VisionRoleGuess.swift` | `VisionRoleGuess` |
| `VisionSaliencyLayer.swift` | `VisionSaliencyLayer`, `VisionKitSalienceProvider` |
| `VisionTextBandLayer.swift` | `VisionTextBand`, `VisionTextBandLayer` |
| `VisionTextLayer.swift` | `VisionTextLayerResult`, `VisionTextLayer`, `VisionKitTextRecognizer` |
| `VisionVisualObjects.swift` | `VisionLiveRegionIdentity`, `VisionLiveOccludedRegion`; `VisionPercept`: physical admission, indicator values, shape aliases and spatial relations |
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
| `AdaptiveMemoryFacts.swift` | Fact-lane memory interpretation and supersession |
| `AdaptiveMemoryPromoter+Migrations.swift` | `AdaptiveMemoryPromoter`: import-only held-turn format, once-only trusted pending-fact acceptance and moment-to-care migrations with unchanged durable markers |
| `AdaptiveMemoryPromoter+Recovery.swift` | `AdaptiveMemoryPromoter`: owed-turn recovery on the live observation tail; recorded-provenance replay, fair retries and bounded wake/idle/night batches with cancellation-safe judgment settlement |
| `AdaptiveMemoryValues.swift` | Adaptive candidates, extraction evidence, observation and shared hygiene vocabulary |
| `AfterTurnMemorySurprise.swift` | `AfterTurnMemorySurprise`: the agent's own learned prediction that a turn's interpretation would be a COMPLETE no-op: language-independent, fully covered warm-vector precedents from its labelled record, keyed by agent, memory model and detector version, with the cost law's standing |
| `AfterTurnSurpriseLedger.swift` | `AfterTurnSurpriseLedger`: the agent's own labelled record of complete-channel interpretation outcomes (append-only, keyed by agent, memory model and detector version): frozen precedent predictions, deferred turns labelled when their batch judges them, measured provider and delay costs, and the Wilson-bound cost law that grants deferral |
| `EmbeddingModelDownload.swift` | `EmbeddingModelDownload` actor; `ranges`, `assemble`; operation-scoped status observation and retained, cancellation-aware extraction through actual subprocess exit; shared status text and progress projection |
| `KnowledgeGraph+CanonicalRebuild.swift` | `SwiftNativeKnowledgeGraphIndexer`: `rebuildMemoryDerivedGraphFromCanonicalStore`, `reconcileMemoryIndexFingerprints` |
| `KnowledgeGraph+ContextRelations.swift` | Bounded typed entity relations with disclosure and provenance evidence |
| `KnowledgeGraph+GC.swift` | Explicit/approved orphan collection retaining source provenance and the primary-user role hub |
| `KnowledgeGraph+GrowthDistillation.swift` | Independent REM/GROWTH provenance through the canonical graph store |
| `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact`; ID-only canonical indexing and generation/mode-fenced projection reconciliation |
| `KnowledgeGraph+PoolCache.swift` | Direct canonical MemoryStorage resolution with missing-file refusal, per-path single-flight and failed-resolution eviction; no launch owner-registration port |
| `KnowledgeGraph+PrimaryUserIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: shared `profileNames`, `resolvePrimaryUserName`, `consolidatePrimaryUserEntities`, `removeUnreferencedPrimaryUserRole` |
| `KnowledgeGraph+RelatedEntities.swift` | Bounded one-hop entity reads for already-disclosed memory IDs |
| `KnowledgeGraph+SQLite.swift` | Checked prepared-pool boundary and shared entity/edge serialization; legacy import rechecks eligibility and records durable completion in its row-write transaction; batched entity reads retain per-entity relationship limits and failures in one transaction |
| `KnowledgeGraph+StudioRelationAudit.swift` | Checked Studio relation audit and reconciliation evidence |
| `KnowledgeGraph+StudioRelations.swift` | Studio journal relation publication with its own provenance |
| `KnowledgeGraph.swift` | Graph normalization, checked legacy JSON admission and entity search |
| `KnowledgeGraphMaintenanceActions.swift` | `KnowledgeGraphMaintenanceActions`: canonical orphan-sweep preview/apply; apply requires exactly the reviewed candidate set |
| `KnowledgeGraphProjectionModels.swift` | `AgentGraphNode` struct |
| `KnowledgeGraphReadProjection.swift` | Checked complete graph projection, including typed canvas entities/edges and derived entity neighborhoods from the same snapshot; `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData` |
| `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: one checked backend admission for bounded single and batched SQLite reads, optional entity enrichment and immutable legacy snapshots |
| `KnowledgeGraphTypedRead.swift` | Typed checked projections on `SwiftNativeKnowledgeGraphReader` |
| `LegacyCorrectionScopeMigration.swift` | Reviewed scope application and its consumed completion marker; no dated write-only audit copies; `runIfNeeded`, `migrationsDir` |
| `MemoryCandidateQuality.swift` | `MemoryCandidateQuality`: shared durable-candidate hygiene and explicit incomplete-fragment rejection reasons |
| `MemoryDataProvenance.swift` | `MemoryDataProvenance`: stamp, retain and display memory sources across writes, readbacks and prompt projections |
| `MemoryEmbeddingEpoch.swift` | `MemoryEmbeddingEpoch`, `MemoryEmbeddingBatch`; engine-stopped epoch reconciliation on the canonical memory owner, including same-epoch vector-pending tombstones before active memory admission; admission retained through actual flight exit |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring`: shared relevance candidate-window bound, timestamp delegation, decay, literal kind extraction and record correction classification; mutation exceptions require explicit correction kind |
| `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: pure shared record privacy/persona/surface disclosure, independent of Trust tool admission |
| `MemoryRepairOneShot.swift` | `archiveInventoryRows` and approved canonical truncated-row execution with safety snapshots; legacy notes staging, scanning, purge, stamps and outcome files are retired without touching existing files |
| `MemorySenseProvenance.swift` | `MemorySenseProvenance`: shared warning presentation and durable sense-version metadata; `MemoryStorage.markVersionWrong` |
| `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery (the journal's owed turns) wire models |
| `MemoryStatusProjection.swift` | MemoryV2 and embedding runtime status projections and recent misses; embedding settings act through MemoryFacade's canonical owner; `MemoryV2NativeStackSnapshot` reads native stack health |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+Comparison.swift` | `MemoryStorage`: comparison-key modes, scope/epoch checks and quantity/polarity matching; callers own candidate execution |
| `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: `embeddingCorpusSnapshot`, `embeddingEpochState`; derived action vectors in `memory.sqlite`, keyed by embedding epoch and exact-text SHA-256, outside the canonical corpus |
| `MemoryStorage+Integrity.swift` | `MemoryStorage`: `requireSemanticIntegrity`, `spotlightSnapshot` returns eligible exported items and their fingerprint; `createConsistentBackup` |
| `MemoryStorage+Migrations.swift` | `MemoryStorage.migrator`; registered GRDB schema migrations |
| `MemoryStorage+Projections.swift` | `MemoryStorage`: ordered USER.md, Spotlight and graph projection tails, attachment, canonical readback and shutdown settlement without cancelling canonical writes; startup eviction publication and `userPromptCore` |
| `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |
| `MemoryStorage+Recall.swift` | `MemoryStorage`: `invalidateRecallCache`, shared `rankedRecall` scoring and bounded `recall` deduplication, canonical recall-generation cache |
| `MemoryStorage+Tombstones.swift` | `MemoryStorage`: `upsertTombstone`; same-epoch owed tombstone vectors land on exact hash/content; semantic consumers require complete forgotten-claim vectors; near-verbatim gate and `nearestTombstones` for the memory manager |
| `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |
| `MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter` actor and live interpretation; meaning before apply, trusted fact acceptance by operation identity, learned complete-no-op deferral and labels under the judging model |
| `MemoryV2+DueDateStamp.swift` | `MemoryDueDateStamp`: writer-named plan instants, shared horizon clock-relative labels and a date reader that excludes retired prose-extractor stamps |
| `MemoryV2+Embedding.swift` | Embedding provider contracts and `CoreMLEmbeddingProvider`: real-model loading, artifact epochs, bounded compiled-model storage, fail-closed availability, one batch prediction per embed call |
| `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`; canonical runtime embedding backend with performance residency and the query form (bge queries carry its retrieval instruction, stored text never); durable action-index updates at warm-up and inventory changes, with serialized missing-text fills and background epoch rebuilds; engine termination closes admission, removes passive observations and cancels/drains both convergence flights through actual exit |
| `MemoryV2+FoundationModels.swift` | `OnDeviceClassification`: shared category prompt and exact reply parser for on-device and remote kind labels |
| `MemoryV2+KindBackfill.swift` | `MemoryKindBackfill`: approval-staged legacy row classifications and checked apply through canonical storage |
| `MemoryV2+KindStamp.swift` | `MemoryKindStamp`: conservative write-time memory kind and source metadata defaults; the one kind vocabulary (`writerKinds`, `personKinds`) the writer, the explicit save and the person picture share |
| `MemoryV2+LaneRetention.swift` | `MemoryStorage` indexed lane ID reads for inventory retirement without tombstoning user memory |
| `MemoryV2+MemoryManager.swift` | `MemoryManagerLane`: semantic after-turn memory decisions (one turn, or a bounded batch of owed turns via `MemoryBatchInput`) with writer-named plan dates, grounded correction validation and reconciliation against existing rows |
| `MemoryV2+Moments.swift` | `MemoryMoments`: the retired moment lane's row vocabulary, turn and source provenance metadata and recall origin |
| `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; `isEnabled`, `knowledgeGraphEnabled` |
| `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |
| `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`: `recordRecallHits`, counted/capped candidate-paged `recall`, `readMemoryRecord`; invocation-local ranked voices reused for disclosure refill |
| `MemoryV2+RecallQueryExpansion.swift` | `MemoryRecallQueryExpansion`: persona/user name-aware first-person recall rewrites |
| `MemoryV2+SharedInstance.swift` | `SwiftNativeMemoryV2` directly owns canonical `MemoryStorage`; attachment readiness, engine-closed projection hooks and unavailable-storage admission; late canonical attachment never reopens stopped projections |
| `MemoryV2+Spotlight.swift` | Canonical generation-proven rebuild shared by launch and repair, serialized with incremental Spotlight projections before taking its snapshot; isolated roots never alter system Spotlight |
| `MemoryV2+Storage.swift` | `MemoryStorage` actor, shared database pool and canonical mutations; bounded admission and eviction, transactional duplicate/supersession writes, scalar `statusCounts` and checked `curationPage` |
| `MemoryV2+TextClip.swift` | `MemoryTextClip`: shared sentence/word-safe display clipping and bounded memory text presentation |
| `MemoryV2+UserMDGen.swift` | `UserMDGenerator`: coalesced regeneration of derived USER.md at the active canonical persona root; SQLite remains truth; admits `MemoryKindStamp.personKinds`, bounded at `UserMDAutogenMarkers.promptByteCap` |
| `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |
| `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `emitDiagnostic` |
| `MemoryV2Contracts.swift` | Recall candidate offsets and counted/capped continuations, proposal contracts; `MemoryPatchContract` preserves untrusted sources through rewrites and duplicate collapse |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MemoryV2 diagnostics |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractEntities`, `taggedNameIsCredible` |
| `WordPieceTokenizer.swift` | `WordPieceTokenizer`: bge BERT vocabulary tokenization, greedy subwords and encoded token IDs |
<!-- END GENERATED BLUEPRINT -->

### NativeAgentCore

Directory: `Modules/NativeAgentCore/Sources/NativeAgentCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentCore/ -->
| File | Owns |
|---|---|
| `AgentHostACP.swift` | `AgentHostACP`: documented stdio launch contracts, protocol pins, explicit ask permissions and verification/version blockers |
| `AgentHostCommandLines.swift` | `AgentHostCommandLines`: data-driven CLI launch/stream contracts, executable resolution and scrubbed environment; no host-specific adapter branches |
| `BridgeCore.swift` | Shared HTTP framing, bearer comparison, loopback/authentication admission and response transport |
| `BridgeRoutingPrefix.swift` | `BridgeRoutingPrefix`: bounded stored-prefix parsing/stripping; caller retains provenance admission |
| `CapabilityLifecycle.swift` | `CapabilityLifecycle`: common ability store paths, lifecycle actions, version rules and current peer/owner keep authority |
| `CausalTransitionEvidence.swift` | `CausalTransitionEvidence`: immutable pre-transition assignment and evidence-class values; observational metadata grants no authority |
| `ChatSessionIDPath.swift` | `NativeAgentChatSessionID`: safe filename/path components preserving legacy colon IDs while refusing traversal and separators |
| `ContextSecretContentPolicy.swift` | Shared derived-context secret policy; linear nested percent decoding and ordered URL extraction with authoritative whole-text and query-assignment redaction before and after news composition; Context compiler, native news and JavaScript helper use this same owner |
| `DerivedStateInvalidation.swift` | `DerivedStateInvalidationCenter`: post-write canonical-source invalidations through StoreReloadDebouncer.Timer and coalesced sink delivery; derived owners must reread truth |
| `LLMClient.swift` | `LLMClient` named completion and structured streaming; request context, prompt layout, offered schemas and message/stream contracts |
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `LifecyclePrimitives.swift` | `ScopedWaiter`, `OnceByKey` and `BoundedWait`: lifecycle-safe waiter release, keyed single execution and bounded waits |
| `MemoryDisplayText.swift` | `MemoryDisplayText`: canonical memory text, shared author suffix and USER.md coverage/join keys, preserving date-critical kinds |
| `MotorActionReadModel.swift` | `MotorActionReadModel`: shared payload-free phase, deadline and verification language; canonical domain reducers retain authority |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | process-cached current identity, injectable `from`, `writeLaunchStamp` |
| `NativeLoopbackListenerParameters.swift` | Loopback listener construction, generation and rebind lifecycle; one retained, cancellable two-second port diagnostic, with admission held through process exit and stale generations excluded from publication |
| `NativeTimestampFormat.swift` | Core alias to Shared's locked wire timestamp owner |
| `OrganPulse.swift` | `OrganPulse`: shared proof-of-pass values and installed recording hook; BackgroundLoops owns durable pulse records |
| `PersonOnlyWindows.swift` | `PersonOnlyWindows`: registered person-only window exclusion, input/pointer coordination and step-aside hooks without app dependencies |
| `ProcessTreeReaper.swift` | `ProcessTreeReaper`: process-start-identity snapshots and leaf-first subprocess termination; reused PIDs never receive stale signals |
| `ProviderCallEvidence.swift` | Payload-free provider lifecycle events and observation, learned first-output deadlines and request input-byte evidence |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `RecallLexicalNormalization.swift` | `characterEditDistance`: pure Character comparison; `RecallLexicalNormalization`: shared retrieval-only inflections and question-word vocabulary; canonical text and authority remain verbatim |
| `SSEEventStream.swift` | Shared SSE framing and `ProviderStreamContext`; transport opening and activity for every event/comment; optional round-scoped diagnostic event capture before provider decoding |
| `Settle.swift` | `settle`: the Stop law's one primitive; settlement runs outside the caller's cancellation, exactly once (docs/STOP.md) |
| `TimeoutRace.swift` | `raceAgainstTimeout` through `ContinuationOnce`: first-wins operation/deadline coordination with explicit parent-cancellation outcome |
| `ToolFailureAndEffects.swift` | Owner-supplied tool failure, recovery and effect evidence; declared tool class, reach, capabilities and argument-dependent effect vocabulary |
| `TurnDeadline.swift` | `TurnDeadline`: active-work deadlines pause for a person and renew on progress; wall-clock ceilings never pause or renew; `secondsLeft` reads the tightest ceiling; `TurnBodyLifetime` admits one body inside its deadline scope, cancels and joins its actual result through settlement |
| `TurnPresentation.swift` | `TurnPresentationReducer`: sanitized bounded turn lifecycle/activity projection; no tool arguments, payloads or hidden reasoning |
| `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |
| `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`: one USER.md section marker vocabulary and shared prompt/pinned-section handling; `promptByteCap`, the person picture's bound (one floor turn's recall memory) |
| `UserMessageIntentSignals.swift` | `UserMessageIntentSignals`: pure lexical context/tool allocation signals and control-handoff recognition; never effect authority |
| `VectorMath.swift` | `VectorMath.cosine`: shared finite-checked Double cosine core for recall, cognition and context; `standout`: linear leave-one-out deviation scores; `chanceBar`: the one bar every similarity decision clears (chance among n, plus 1 for attention, 2 for an action) |
| `WorkshopWireVocabulary.swift` | Workshop wire vocabularies: canonical surface/event/approval/inbox/environment spelling and centralized legacy translation |
<!-- END GENERATED BLUEPRINT -->

### Onboarding

Directory: `Modules/NativeAgentCore/Sources/Onboarding/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Onboarding/ -->
| File | Owns |
|---|---|
| `Onboarding.swift` | Onboarding client roots, start verdict and ability catalog |
| `OnboardingCompletion.swift` | Durable completion intent and recovery; persona and profile bytes verify before the sentinel |
| `OnboardingIdentity.swift` | Checked identity and shared manifest/byte writer; profile and USER publication use their domain owners |
| `OnboardingProfileRepair.swift` | Missing-only profile repair under completion and profile locks; completed persona bytes stay intact |
| `OnboardingReset.swift` | Durable reset intent, exact-byte backups and recovery; backups precede completion evidence removal |
| `OnboardingTourReplay.swift` | MainActor tour replay request and once-only claim |
| `OnboardingValues.swift` | Onboarding payload, result and recovery verdict vocabulary |
| `PersonaTemplates.swift` | `PersonaTemplates` enum; `generate` |
| `StarterPersona.swift` | Starter persona publication through canonical document owners |
<!-- END GENERATED BLUEPRINT -->

### AuthoredCapabilities

Directory: `Modules/NativeAgentCore/Sources/AuthoredCapabilities/`

Depends on NativeAgentCore support, PersistenceCore durable I/O and Experiences for source-fault repair obligations from live part runs carrying input; file-backed sense completions record outcomes without this obligation; owns the authored part contract without importing feature executors.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AuthoredCapabilities/ -->
| File | Owns |
|---|---|
| `AbilityAccounting.swift` | Locked execution settlement and learned-use accounting |
| `AbilityAdoption.swift` | Verified legacy preparation, publication and archival |
| `AbilityCatalog.swift` | Checked inventory and redacted catalog projections |
| `AbilityFile.swift` | Canonical authored file, header, slot and reach representation |
| `AbilityStorage.swift` | Checked canonical file and accounting encoding |
| `AbilityStore.swift` | one byte-exact latest accounting snapshot reuses pure evidence redaction across catalog reads; The bundled seed catalog owns shipped-id and native- reservations for new parts in Parts.save and for installation; all-kind registry rows carry kind and version, including recordless turns, and senses expose record-owned version/reach/mode without ability wake/residency; one throwing partHeader normalizer/catalog for tools, skills, senses and reserved turns: reach/wake/face/resident/learned/choices, the `signalled` notification sources post and each part's `wakes`, legacy permissions projection and one 512 KB source limit; invocation-scoped file reach binds declared read/write approval to the part's own data root; current/prev/next lifecycle, shared ID normalization and all-slot name/identity occupancy for create-only saves, atomic current-only seed installation under the store lock with any existing id/slot skipped, notebook schema and read/write/delete under the same lock (16 KiB/value, 64 KiB/notebook), independent versioned outcomes/read counts in state.json with exact-file read recovery and the captured restore digest retained in the remedy instruction, including native/bundled reads without executable files, without source rewrites, bounded recent exact-input/reached-call outcomes with call labels redacted before persistence, retained accounting redacted on projection, input previews and version run totals and recent per-use model rounds (`recordRounds`) projected as learned.use from ordinary gated execution (no rehearsal/preview/replay competence credit), scoped rehearsal evidence distinguished from bundled admission and from a tape replay of recorded practice (`replayed`, kind `tape_replay` with its coverage) and projected separately for current and proposed versions, operation-scoped repair owed through Experiences with source-filled native authoring calls for their abilities/senses, source reads and a person-directed defect for reserved turns, and no automatic swap-back; damaged-source recovery preserves fileRepairInstruction; unique ids, owner-off/peer-authoring guards, change invalidation and read/files/states perform verified on-disk migration of the three old stores into one retained .old-layout archive; `restoredLegacyCarry` prepares older-backup parts plus readable current uncarried kinds/accounting before installation, returning omissions for the sealed restore receipt; `installRestoredLegacy` installs that selection, or the backup alone when carry is lost, and archives the legacy sources without rereading current accounting; Exact reach-capability action definitions exclude Photos from file reach; the bundled seed catalog owns shipped-id and native- reservations for new parts in Parts.save and for installation |
| `PartCall.swift` | Re-exports the shared Mac/iPhone part result and face wire types; strict face shape and identifier validation excludes native availability, failure and owed fields from editable content |
| `PartFaces.swift` | `PartFaces`: native source-change projection owner; frozen packets and source epochs, version/epoch cache, canonical ability-change invalidation, per-part LatestRead publication; cancelled reads publish and cache nothing, preserving the last snapshot and allowing another ask at the same version/epoch; observable and Codable typed rows for Mac/phone consumers; `PartFaceSnapshot` keeps native unavailable/failed/owed beside authored content; synchronous stop retires publication/observation and cancels refreshes before returning their settlement drain (close awaits it); source callers retain and cancel their own reads; no view executes JS, no domain truth store |
| `SkillRunContext.swift` | Singular authored-run TaskLocals, part identity, file-write notifications, a wake's model admitted at its first thought, and hand-back refusal contract |
<!-- END GENERATED BLUEPRINT -->

### PersistenceCore

Directory: `Modules/NativeAgentCore/Sources/PersistenceCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersistenceCore/ -->
| File | Owns |
|---|---|
| `CapabilityLifecycle+FileAdmission.swift` | CapabilityLifecycle file-write admission, peer-content protection and owner-off reconciliation |
| `CheckedFixedSizeSecretFile.swift` | `CheckedFixedSizeSecretFile`: exact regular 0600 secret bytes, missing-only creation and byte-preserving invalid-state failure; caller owns authority lifecycle |
| `ConnectorActionReceipt.swift` | Shared connector action/Slack HTTP receipt schema, path and capped append owner; producer timestamps and outputs retained; local/off-disk backup, credential-free phone health projection, no production export; PrivacyMap/connectors |
| `ConnectorInputValue.swift` | Connector input scalars and secret-free TransportAllowlist: canonical Slack auth.json policy only, strict alias unions within that object and Telegram integer IDs shared by ingress and SecurityCenter; unreadable or malformed saved policy throws |
| `ConnectorOAuthRegistry.swift` | Sole checked connector registry reader/schema and durable publication owner (`writeRegistry`), including bootstrap and Slack recovery; canonical IDs and `connectionDecision`. A connection decision is recorded only by the person's own connect or disconnect; seeds, first reads and migrations are undecided, and missing decision fields read as undecided without inferring from enabled/authState. `permitsCredentialMigration` reads only that decision: connected or undecided may migrate; a recorded person-disconnect never does. Malformed authority throws |
| `DataRootLife.swift` | `DataRootLife`; one root life-id, created once when absent as their first life (`first`) and replaced by the restore intent's UUID; `life(of:)` reads a missing stamp as the first life, so an upgrade never reads as a restore; resumable owners stamp at beginning and admit only that life, projecting work from another life stopped with reason restored; CodexCompletionReadout owns lifecycle disk projection and incremental transcript origins |
| `DeviceSecretKeychain.swift` | Verified device-only Keychain secret bytes and a service's account list; callers own locked reference commits and migration |
| `DiskStorageOwner.swift` | `DiskStorageOwner`: owner retention plans and execution, contained identity-checked moves to Trash and logical-byte outcomes; no history deletion |
| `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy`; shared trace envelope/retention and native-power browser/action receipt retention; local backup/export/raw phone exclusions, selected telemetry projection and Traces privacy scope; appendPathOwnedJSONL is the existing mutation owner |
| `FileChangeEvents.swift` | `FileChangeEvents`: bounded cancellable async vnode event bridge with one initial edge only after successful arming |
| `FileChangeWatcher.swift` | `FileChangeWatcher`: independent subscription identity and cancellation; registry `Entry` owns one path's shared vnode, ancestor observation and replacement rearming with serialized teardown |
| `FileLockSidecarLifecycle.swift` | `FileLockSidecarLifecycle`: bounded locked reaping of old regular orphan sidecars; live/fresh/link sidecars stay untouched |
| `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |
| `InstallPaths.swift` | Install-owned paths, public release preparation and login-item location admission |
| `JSONLRetention.swift` | SwiftNativePersistenceCore owns the activity event envelope, path and append; producers preserve redacted values, IDs and timestamps; JSONLCapCheckCounter owns cap-check cadence |
| `JSONRow.swift` | `JSONRow` checked stored-object reads; required/optional typed fields and named malformed-row errors |
| `JSONSchema.swift` | `JSONValue.SchemaProblem`, `validate`, `schemaProblem`: whole-tree schema preflight and value validation, ignoring unknown keywords with caller-owned error formatting; `ToolSchema` shared nullable/object/string/boolean/integer/enum/parameter constructors |
| `JSONValue+Accessors.swift` | JSONValue primitive accessors with explicit numeric coercion/finite policy; JSONKey and unknown-field Codable container operations |
| `JSONValue.swift` | `JSONValue` ADT and wire codec; nonfinite-token parsing, Python-compatible ordered/sorted serialization, Codable conversion; `decodeCompletion`, `fromEncodable`, `mapStrings`, `decodedExactly` (strict stored-document shape), `digest`, `differences` |
| `Keyring.swift` | `Keyring` enum: the one keyring's storage — a secret by their name in one Keychain service with the hosts and programs the person granted it for, its renewal and when it was granted; `kept`, every entry by name; `{{secret:<name>}}` names; a program grant is the executable's path and code identity; no network |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for PersistenceCore diagnostics |
| `NativeActionRouteSupport.swift` | `NativeActionWire` enum; `jsonValueBody`, `notImplemented` |
| `NativeAgentWorkspaceRoot.swift` | Canonical workspace root, byte-preserving file spelling, target/entry canonicalization and byte-exact component-relative paths; callers select bases and retain admission authority |
| `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |
| `OncePerPeriodReservation.swift` | `OncePerPeriodReservation`: locked durable periodic admission and stamp-specific restoration of a failed reservation |
| `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock` and persistence lock support: current-task lock ownership, bounded acquisition and sidecar identity checks |
| `PersistenceCore.swift` | JSON/JSONL atomic and durable persistence, strict UTF-8 physical-line reads with integrity reporting and directory sync; bounded atomic `PhonePlaceHistory` written only by the Mac bridge |
| `PersistenceDataRoot.swift` | Swift initializes the stable process data root once; explicit resolver arguments bypass it; literalFileURL preserves configuration path spelling; `DataRootLife.life(of:)` interprets JSON stamps, with a missing or non-string stamp naming the first life |
| `RegistryTimestampSortKey.swift` | `RegistryTimestampSortKey` enum; `sortKey` |
| `Repair.swift` | Shared repair, reconciliation, terminal and person-decision shapes; ToolFailureError.call builds native calls, while fileRepairInstruction owns byte-preserving person recovery prose for damaged files, without executable coding requests |
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
| `Experience.swift` | `ExperienceStore`, the append-only owner per data root over `experiences/experiences.sqlite`; `begin`, `append`, `experience`, `open`, indexed open/recent `projection` and commit-fed `changes`. Shared `Experience`/`ObligationPhase` live in NativeAgentShared. Recording stays off reply paths; projection drains queued writes and reports persistence gaps; a write the law refuses is logged and never poisons reads. Turn owners record answer lifetimes and recover saved-answer settlements; conversation and shelf owners publish peer obligations and completed run identities |
| `Flow.swift` | `Flow`: scope-ordered open, stopped, finished and dropped helpers over ExperienceStore; failure state shares the durable owner's root-plus-scope record identity; unfinished runs owe finish, with position-prefixed landed digests and references to their owners' raw records |
| `Owed.swift` | `Owed`: what they owes or is owed under the id its owner hands their (a reply's delivery id, a card's `interaction:<id>`), born owing one key and moved only by that owner at its persistence boundary, so desk.wait and repair.let_go read one experience |
| `RepairOwed.swift` | `RepairOwed`: experience-backed repair claims and settlement; `isOwed` omits effect-free agent probes and explicit pre-effect refusals without rewriting history; retries, restarts and unrelated successes cannot settle another operation's debt |
<!-- END GENERATED BLUEPRINT -->

### PersonaEngine

Built-in skill guidance inventory and display models live with the persona;
they read persona/skills/bodies and do not execute guidance.

Directory: `Modules/NativeAgentCore/Sources/PersonaEngine/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersonaEngine/ -->
| File | Owns |
|---|---|
| `InstalledSkillInventory.swift` | Built-in guidance inventory, matching and body reads shared by Parts, Mac and phone as SkillRecord, carrying source text and revision without reconstruction |
| `NativeAgentPublicSafety.swift` | `NativeAgentPublicSafety`: checked onboarding completion/legacy anchors and neutral organism admission before resident cognition wakes |
| `PersonaCompiler+Normalization.swift` | `PersonaCompiler`: `normalize` |
| `PersonaEngine+Compiler.swift` | `PersonaCompiler`: `compile`, `fingerprint`, `renderPrompt`; batched context surfaces share canonical persona documents and identity, with separate surface overrides; USER core projection |
| `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`: shared document-kind normalization and selection, locked persona mutations and private backups; ordinary persona mutations; skill-specific aliases are retired |
| `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: profile schema preparation, including onboarding, and sole profile commit owner; fixed document specs and guarded writes; append reads current content under the write lock with the editor's cap and backup policy |
| `PersonaEngine.swift` | `SwiftNativePersonaEngine`: shared persona-document reads and GROWTH episodic-log filtering; `PersonaSelection`: installation-wide selection for every door |
| `Skills.swift` | `SkillRecord`: built-in guidance carried directly through discovery, reads, Mac and phone |
<!-- END GENERATED BLUEPRINT -->

### Privacy

Directory: `Modules/NativeAgentCore/Sources/Privacy/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Privacy/ -->
| File | Owns |
|---|---|
| `NativeAgentSecretRedactor.swift` | Canonical credential text redaction and shared secret detection: exact script-input names, broader audit/card names, audit token/JWT scanning and recursive script-input paths |
| `NativeAppSecretRedactor.swift` | NativeAppSecretRedactor: redactText and string-only redactValue; redactArguments withholds secret-named fields; redactedRemoteErrorDetail owns phone error path projection |
| `PrivacyMap.swift` | Privacy inventory counts hidden retained files, including notebooks and live Procedures; helpers, triggers, Doctor, weekly improvement, REM, appraisals, preferences and secondary bridge state; declares context, dreams, traces, Desk, Workshop, Studio, Make, agents (including peers) and full agent-conversations state, Slack, onboarding controls, embedding settings/install state, notifications, saved desktops, screen state, the whole ui directory, attention and notification deduplication ledgers, welcome markers, trust/catalog, legacy approval evidence, security audit, browser runs/captures, Chrome tab mappings, browser discovery and its retired token copy, paired phones, legacy pairing bytes and their live coordination lock, phone snapshot/response/transaction cache, received phone JPEGs, Mac-control state/audits and Mac integration permission authority, swarms, builder/restart/Codex/image evidence, child credentials, live provider status/vitals and owner-resolved workspace/bridge locations once each; owns productionExportRelativePaths consumed by archive creation; export claims derive from intersecting selected paths and name partial scope; chat Markdown export and activity support bundles are named separately; storage owners state backup/export/phone decisions; Telegram state.json support, ignored legacy push tokens, chat completion-delivery state, launch retirement markers and diagnostic outputs have explicit coverage decisions |
<!-- END GENERATED BLUEPRINT -->

### Procedures

Directory: `Modules/NativeAgentCore/Sources/Procedures/`

Retention reads the complete bounded invocation ledger through the invocation
owner's validated reader. Any unreadable, oversized or invalid reference record
aborts deletion and logs the ledger failure; damaged evidence stays untouched.
The tail-only reader that skipped unreadable references is removed.
Invocations hold a file lock keyed by artifact and canonical invocation ID
across work and receipt publication. Different inputs of the same artifact
execute independently; only retries of the same invocation serialize. Ledger
and automatic-pointer locks cover only admission and publication. While holding
the ledger lock, retention tries the artifact lock and each invocation sidecar
once, skipping any busy artifact without blocking settlement. The ledger lock
excludes new admission during this check. Receipt publication retires the held
invocation sidecar; retention retires idle sidecars left by interrupted callers.
Every dispatched attempt settles one receipt before releasing that lock,
including executor throws, invalid verification and Stop. Without usable domain
verification the receipt records unverified effects and a payload-free interruption
reason, then the original error is rethrown. A retry reads that terminal account
and returns it only if its domain outcome was verified. An unverified attempt
reenters the canonical executor with the same invocation identity, so Workshop
reuses the existing execution and reconstructs verification from its record and
timeline before a new receipt is appended. Earlier interruption rows remain
unchanged. Domain readback remains the executor's responsibility; the generic
store cannot infer success from a thrown observation.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Procedures/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Procedures diagnostics |
| `ProcedureArtifactContracts.swift` | Procedure artifact errors, canonical execution and invocation receipt contracts, and payload-free status snapshots |
| `ProcedureArtifactStore.swift` | ProcedureArtifactStore immutable artifact installation, discovery, revalidation and status; explicit backup/export/sync decisions and privacy-map coverage |
| `ProcedureArtifactValidity.swift` | ProcedureArtifactStore artifact, compiler identity and invocation receipt validity; shared token and timestamp predicates |
| `ProcedureCandidateAdmission.swift` | Procedure candidate evidence binding, review contracts and strict manual/canary admission |
| `ProcedureCompilation.swift` | Declarative procedure artifacts, shared domain contracts and immutable transition-table compilation |
| `ProcedureExactActivation.swift` | Exact activation manifests and active pointers; artifact revalidation and pointer publication share retention's invocation-ledger lock, acquired before the pointer lock |
| `ProcedureInvocation.swift` | ProcedureArtifactStore manual/exact invocation admission, execution/ledger/pointer locks, canonical execution, idempotent receipts and settlement |
| `ProcedureReplay.swift` | replay status/count and manual dry-run eligibility; canonical executor retains dispatch |
| `ProcedureRetention.swift` | ProcedureArtifactStore root-scoped retention flight, reference-locked artifact sweeping and orphan lock reclamation |
| `ProcedureTrajectory.swift` | Payload-free procedure trajectories, extraction, validation and rejection evidence |
<!-- END GENERATED BLUEPRINT -->

### ProviderRouting

Directory: `Modules/NativeAgentCore/Sources/ProviderRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ProviderRouting/ -->
| File | Owns |
|---|---|
| `AsyncSerialQueue.swift` | FIFO completion and caller cancellation for shared single-use OAuth token refreshes |
| `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |
| `ChatCompletionsStreamDecoder.swift` | `ChatCompletionsStreamDecoder`: shared buffered terminal decoding/receipts and SSE content/reasoning/tool fragments, usage and root errors; terminal/tool alignment validation preserves provider failures |
| `ChatGPTAccountModelRefresh.swift` | `ChatGPTAccountModelRefresh`: account-scoped UI/sign-in model discovery and checked cache publication outside provider dispatch |
| `ChatGPTCredentials.swift` | ChatGPTTransport credential discovery, exact account binding and serialized single-use token refresh |
| `ChatGPTResponsesBody.swift` | ChatGPTTransport Responses wire body, structured input roles and native tool encoding |
| `ChatGPTTransport.swift` | ChatGPT OAuth request/stream/error execution with conversation or stable Workshop cache routing |
| `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog` enum; `load`, `matchingModels`; one decoded catalog for account matching and separate Codex/OAuth projections, invalidated by file attributes with auth identity checked on selection; a cache read fault owes repair under `codex.model_catalog:<file path>` with the file as owner; a later successful read settles it |
| `CodexOAuthAccessContext.swift` | Checked Codex OAuth access identity and stable re-sign-in-required exhaustion marker |
| `FirstPartyModelCatalog.swift` | `FirstPartyModelCatalog`: shared first-party model capabilities, route controls and image/speech choices for inspection, pickers and request serialization |
| `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`; successful/failed call receipts with full/delta context byte sizes, keyframe status, purpose, timing, provider identity and redacted underlying failure detail; memory, digest and probe telemetry retain their own surfaces when routing inherits Chat; a bound `spent` tally adds each row's usage (their turn's own rounds) |
| `LLMClient+AnthropicAdapter.swift` | `AnthropicTransport`: shared buffered Messages response operation, credential discovery, prompt blocks and thinking/tool wire controls |
| `LLMClient+AnthropicNativeTools.swift` | `AnthropicTransport`: buffered JSON and SSE both open through `ProviderWire`; native-tool stream decoding commits explicit object input at content-block close; empty-input candidates and later blocks wait in wire order for the terminal verdict; interruptions discard unconfirmed empty candidates and release explicit calls, retaining thinking replay; shared Anthropic event type, wire errors, usage and stop-reason accumulation |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthTransport`: `requestMaxTokens`, `installedClaudeCodeVersion`; indexed content-block validation shared by OAuth text and Anthropic native-tool streams, keeping text/thinking/signature/tool deltas on their own blocks |
| `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthTransport`: `ephemeralCacheControl`, `currentTurnUserIndex`, shared encoded conversation cache boundaries |
| `LLMClient+CodexAdapter.swift` | `CodexProcess`: streaming and buffered Codex runners; pins the shared credential resolver's path for account controls, child-home binding and preparation; never lets the CLI select another credential; NativeAgentCore's ProcessPipeDrain owns shared nonblocking pipe capture without an executor dependency |
| `LLMClient+MoonshotAdapter.swift` | `MoonshotTransport`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |
| `LLMClient+OpenAIAdapter.swift` | `OpenAITransport`: API-key Responses/Chat Completions selection, message/tool encoding and bounded completion/stream transport |
| `LLMClient+OpenAIOAuthCredentials.swift` | `ChatGPTTransport.preferredAuthPath`: the single ChatGPT/Codex credential-path resolver for readiness, all adapters, maintenance, child execution and explicit CLI inspection; app-owned writes and root-consented CLI adoption share this owner; child homes derive from an already-selected credential; hasAccessToken checks presence only, not execution readiness |
| `LLMClient+OpenAIResponsesDecoding.swift` | `ChatGPTTransport`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |
| `LLMClient+OpenRouterAdapter.swift` | `OpenRouterTransport`: namespaced model routing, reasoning controls and authenticated OpenRouter completion/stream transport |
| `LLMClient+Real.swift` | `makeResidentProviderLLMClient` owns the nine-transport assembly for resident, planner and swarm calls; `SwiftNativeLLMClient` shared routing and non-streaming execution envelope, stream guard admission before adapter creation, and failed-call telemetry before error normalization |
| `LLMClient+XAIOAuthDirectAdapter.swift` | `XAIOAuthTransport`: app-owned OAuth token lifecycle and Grok completion/stream transport with shared refresh serialization |
| `LLMProviderStatusFeed.swift` | live provider status feed; byte-checked receipt decode reuse, verdict age checked at use |
| `LLMRequestShape.swift` | Request cache markers, conversation-prefix snapshots and task-local secondary-call isolation; `ToolContractWeight` measures schema material without retaining content |
| `LLMUsage.swift` | Provider usage parsing, counter semantics, streaming accumulation and saturating logical input totals |
| `ModelCatalogTTLCache.swift` | shared live fetch and TTL/backoff state machine; a path-bound LatestRead orders publication and coalesces equal-credential fetches; unchanged credentials and checked persistence own cache/backoff commits; `ModelCatalogDecodeCache` memoizes decoded rows and authority stamps by canonical file path and mtime |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ProviderRouting diagnostics |
| `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model parsing/capabilities and checked offline cache, using shared TTL state machinery |
| `NativeOAuthCallbackPolicy.swift` | Shared callback validation with exactly one state and caller-specific messages; handleCallbackURL, validateCallback, parseCallback |
| `NativeOAuthCallbackRegistry.swift` | `PendingCallbacks` class; `register`, `forget` |
| `NativeOAuthFlow+Configs.swift` | ProviderOAuthConfig owns provider client identities and token endpoints; buildAuthURL, exchangeCode |
| `NativeOAuthFlow+Helpers.swift` | PKCE and OAuthGrantOperations.post, the redirect-refusing transport for all token grants; adapters retain sessions, encoding, 20/30-second request bounds and error classification; owned sessions and device polls have elapsed resource bounds. Device authorization polls at the server interval through expiry, denial or cancel |
| `NativeOAuthFlow+Keyring.swift` | `Keyring`: `granted`, `grant`, `forget`, `values` — grant, removal and renewal of one secret on its one queue of the refresh queue registry; a renewal commits only onto the entry it read, and a successful grant or removal voids sign-ins begun before it; `NativeOAuthFlow`: `grantSecret` — the person's grant of a keyring secret, pasted or by a sign-in run from parameters they supplied (PKCE, loopback redirect, token redeemed and kept, never shown) |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackPageMessage` |
| `NativeOAuthFlow+TokenStatus.swift` | Token clearing and badge projections of each adapter's credential verdict and effective expiry; Sendable sign-in/session-offer values travel in the checked provider snapshot; no independent readiness or credential-selection rules |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | `NativeOAuthFlow` enum; `validateSignInDestination`, `startOAuthFlow`, Anthropic setup-token normalization/admission/write |
| `NativeOAuthLoopbackCallbackServer.swift` | shared ChatGPT/xAI loopback callback socket lifecycle; one admitted wait (concurrent waits reject before installing cancellation or timeout), bounded blocking clients on Dispatch, protocol-specific response shape, state validation and exactly-once completion; browser opening stays in the owning session |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort` protocol; `runAuthSession`, `isCanceledLogin`; shared `makeLoopbackSession` returns the concrete callback server; `openBrowser`, `runLoopbackAuthSession` defaults |
| `OAuthCredentialDecoding.swift` | Shared JWT payload and OAuth expiry decoding; `OAuthRefreshBinding`: account identity and refresh continuity |
| `OAuthCredentialHealth.swift` | Secret-free maintenance projection of adapter-owned expiry, refresh binding and readiness verdicts |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` (per credential path or key) |
| `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: transport-specific catalog capability admission and reasoning/service-tier wire serialization |
| `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed model availability, capability parsing and checked catalog cache through shared TTL machinery |
| `ProviderAPIKeyStore.swift` | Provider reference/string validation; byte insertion, readback and deletion delegate to DeviceSecretKeychain |
| `ProviderConfiguration.swift` | Byte-checked provider configuration decode under the writer's lock with fresh credential/readiness facts |
| `ProviderConnectionProbe.swift` | provider connection probes |
| `ProviderErrorBodyDrain.swift` | `ProviderErrorBodyDrain`: bounded exact-request diagnostic reads with idle deadlines; adapters retain HTTP verdicts and cancellation stays cancellation |
| `ProviderFailure.swift` | Typed provider failure classification and `Diagnostic` wrapper preserving redacted wire evidence and the owner's `ToolFailureError` repair through normalization; `repair` decides once whether a failed call owes repair (sign-in, account, model choice) or is a correction that owes nothing |
| `ProviderOAuthAdmission.swift` | Observed OAuth credential admission and expiry interpretation |
| `ProviderReadiness.swift` | Provider inventory and credential readiness |
| `ProviderReasoningSelection.swift` | Normalizes reasoning selection; NativeAgentShared owns supported-choice filtering |
| `ProviderRecoveryPolicy.swift` | Shared failure classification and helper-start backoff; surfaces never replay a provider call (delivery redials live in ProviderStreamGuard's `ProviderWire`) |
| `ProviderRouteDerivation.swift` | Route and catalog derivation from one checked provider snapshot; unknown context windows remain unknown |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting` actor; `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `adoptConnectedProvider`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting`; effort-only group rows inherit Chat's current model/account without seeding other controls; provider interpretation, byte-checked picker/configuration decode reuse with fresh credential/readiness checks; checked picker revisions come from both files under the transaction lock and travel with phone snapshots/readbacks, recoverable group writes/adoption and byte-preserving explicit routing reconstruction |
| `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot` carries its checked source revision and owns modelOverrideSurfaces independently of effort/Fast for settings and UI inheritance reads; `TurnRouteAdmission` and checked snapshot admission bind one execution tuple with explicit inheritance; `SwiftNativeProviderRouting` surface lookup conveniences |
| `ProviderRoutingValues.swift` | Provider and surface scalar interpretation with stable saved JSON vocabulary |
| `ProviderSelection.swift` | Provider picker transactions through the existing tuple lock |
| `ProviderSignInHandoff.swift` | provider sign-in handoff state |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderStreamGuard.swift` | Configured idle/wall cuts on wire activity for every provider stream; the request registers its progress wake before reading and waits only for progress or its next deadline; terminal state closes activity admission before canceling forwarding/deadline tasks, retaining their handles through actual exit without joining the producer; typed no-reply failure and uncapped model URLSession; the learned first-output deadline bounds only a wire with nothing on it; `ProviderWire` opens every provider HTTP stream and owns delivery: until any of the answer arrives, a lost wire, an answerless idle or first-output cut, or a provider's busy reply (overloaded, 5xx, a rate limit with no wait or a wait up to 30 s) dials again, up to 10 dials with 0.5-8 s jittered backoff inside the call's wall, each redial first waiting for the Mac's network path (Stop and the wall end the wait); refusals, sign-in, context and long quota waits never redial, CLI wires never do, and the final failure says how many tries it took; wall-off streams forward without a deadline worker |
| `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared tool/image transport capabilities independent of model-name inference |
| `ProviderTurnChoice+ModelSelection.swift` | provider turn model selection |
| `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |
| `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive lifecycle-derived latency/error bands, first-output evidence and persisted bounded health state |
| `RequestPrefixReceipt.swift` | `RequestPrefixReceipt`: hashes exact encoded request byte slices without reserializing tools or exposing request text |
| `RunawayOutputDetector.swift` | `RunawayOutputDetector`: streamed tool/prose boundaries, complete-call retention and read/action classification through parser/registry owners |
| `SwiftCodexDeviceLoginManager.swift` | `CodexExecutable`: inherited-first PATH and explicit-override executable selection shared by readiness and process execution |
| `XAIOAuthCredentialStore.swift` | Locked xAI token migration, immutable Keychain references, refresh reads and sign-out cleanup |
<!-- END GENERATED BLUEPRINT -->

### Research

Directory: `Modules/NativeAgentCore/Sources/Research/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Research/ -->
| File | Owns |
|---|---|
| `BoundedResearchDownload.swift` | `BoundedResearchDownload`: cancellable URLSession delegate download with retained-byte limits enforced before appending |
| `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |
| `Research+Autodetect.swift` | `SwiftNativeResearchClient`: `autodetectSearXNG`, `checkSearXNG`, `normalizedSearXNGBaseURL`, `saveSearXNGBaseURL` |
| `Research+Helpers.swift` | `SwiftNativeResearchClient`: `trimTrailingSlash`, `makeURL`, `isoTimestamp` |
| `Research+Lab.swift` | `SwiftNativeResearchClient`: `researchLabRuns`, `runResearchLab`; SearXNG evidence explicitly distinguishes unavailable from empty, an injected L0 part call selects sources and composes the brief, native validation binds selected sources to that search, and settlement commits locked capped history plus activity/trace receipts with native status/error truth; source selection, brief wording and `buildResearchBrief` moved to `Resources/abilities/research-lab.js` |
| `Research+SearchFetch.swift` | SwiftNativeResearchClient: checkedSearxngBaseURL owns search configuration; search/fetch preserve transport causes; fetchURL retains explained source receipts with reader locators and block-shaped HTML; ResearchFetchRecord.readJSON selects find passages or returns the whole retained extraction through output paging |
| `Research+WebSearch.swift` | `WebSearchRoutes`: SearXNG results or its plain failure; without SearXNG, `browser_search` (Chrome or their own browser); actual-route receipts and untrusted web-content labels |
| `Research.swift` | `SwiftNativeResearchClient` and research values: SearXNG discovery/search, fetched-source receipts, classified DNS/refused-connection/timeout causes and persisted lab run contracts |
| `ResearchHTMLExtraction.swift` | `ResearchHTMLExtraction`: fetched HTML block, list and table text with inline resolved links; HN story rows and comment paragraphs; chrome exclusion and cancellable parsing without a DOM node cutoff |
| `ResearchTextDecoding.swift` | `ResearchTextDecoding`: response charset parsing outside quoted parameters and strict handling of incomplete terminal UTF-8 |
| `ResearchTransports.swift` | `URLSessionResearchHTTPClient.getBounded`; Docker discovery/start retains daemon readiness polling at 3-second intervals within its 90-second window, with no confirmed push replacement; subprocesses delegate to `MacControl.ProcessExecution` with full output capture |
<!-- END GENERATED BLUEPRINT -->

### SchedulerExecution

Directory: `Modules/NativeAgentCore/Sources/SchedulerExecution/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SchedulerExecution/ -->
| File | Owns |
|---|---|
| `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |
| `SchedulerDueJobRunner+CycleHelpers.swift` | `SchedulerDueJobRunner`: `pruneRetiredRows`, `nextEpoch`, `containsLastRunToday`; dream/REM diary and inbox helpers |
| `SchedulerDueJobRunner+DreamCommands.swift` | canonical recurring-dream command selection and job receipts |
| `SchedulerDueJobRunner+Execution.swift` | `SchedulerDueJobRunner`: `execute` (a `part` job fires its part's `schedule:` signal), `watch` (a `connector_action` read posts the rows new since its last read as one news per job), `channelIsSwitchedOn`, `disabledDreamResult` |
| `SchedulerDueJobRunner+Persistence.swift` | `SchedulerDueJobRunner`: execution-result adaptation to canonical scheduler settlement; `appendActivity` |
| `SchedulerDueJobRunner+ProactiveScan.swift` | `SchedulerDueJobRunner`: `surfaceProactiveScan` |
| `SchedulerDueJobRunner+Selection.swift` | `SchedulerDueJobRunner`: `nextMeaningfulDeadline`, `claimDueJob`, `dueJobs`, `ensureDefaultCycleJobs`; default cycle jobs and one `part` job per part and `schedule:` wake; saved built-in reader watches moved to their door reads |
| `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`: `jobTimeoutSeconds`, `executeWithTimeout`; retains the actual body task and its returned result through stopped settlement |
| `SchedulerDueJobRunner.swift` | `SchedulerDueJobRunner` actor; `runDueJobs`; reads canonical job rows through `SchedulerJobs`; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `sendTelegramMessage`, `read` (a scheduled read through the app door) |
<!-- END GENERATED BLUEPRINT -->

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/ !Modules/NativeAgentCore/Sources/Senses/Owned*.swift !Modules/NativeAgentCore/Sources/Senses/SensesContract.swift !Modules/NativeAgentCore/Sources/Senses/SensesHub.swift !Modules/NativeAgentCore/Sources/Senses/SenseNewsBoard.swift !Modules/NativeAgentCore/Sources/Senses/Helper*.swift !Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift !Modules/NativeAgentCore/Sources/Senses/SenseScreenThings.swift !Modules/NativeAgentCore/Sources/Senses/SenseTurnReads.swift -->
| File | Owns |
|---|---|
| `BuiltInSenses.swift` | Bundle-owned native adapters and JavaScript defaults; file overrides win and accounting lives in AbilityStore state; bundled records have built-in origin and no creation/enable placeholders |
| `ExistingCornersSourceProvider.swift` | `ExistingCornersSourceProvider`: contract ports for today's raw material, native pages and source-owned live-watch inventory; packageManifest owns package membership, symlink/type rejection and the 8,000 total-member bound, including watched directories, for watching and archive delivery; `SenseNativePages` owns readable Chrome places, bounded conversation/tab-scoped private continuation bindings, structural things/verbs and existing raw UTF-8 windows |
| `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |
| `FileSenseRegistry+Storage.swift` | Registry validation, candidate/version-folder source resolution, bounded code manifests and path/symlink fences. Persisted sense timestamps validate within the supported Date range; built-in and shared records may omit an unknown creation date. |
| `FileSenseRegistry.swift` | Sense adapter directly projects current/previous AbilityStore slots and publishes selected records without a serialized version catalog; successful reads delegate versioned evidence to AbilityStore; bundle defaults, corner lookup, keep/restore through the shared publication authority gate with bundled materialization deferred to the admitted save, previous-version swap, final override drop and separate owner-off preservation; retained-version reads add readable corner names; store-locked, root-scoped helper selection identities exclude read bookkeeping and distinguish each selected lifetime without changing saved records |
| `SenseHelperMaterial.swift` | Bounded file and package material conversion for the existing sense helper |
| `SenseHelperProcess.swift` | Request and observation supervision over OwnedProgramProcess; pending work joins settlement before release |
<!-- END GENERATED BLUEPRINT -->

### SlackBot

Directory: `Modules/NativeAgentCore/Sources/SlackBot/`

`SlackSocketModeLoop.swift` owns connection lifetime, ingress and shared state.
Its `+History`, `+Answers`, `+Media` and `+Evidence` extensions organize the
existing methods over that same state.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SlackBot/ -->
| File | Owns |
|---|---|
| `SlackCredentials.swift` | Slack tokens/grants in Keychain; canonical connectors/slack/auth.json validation, save/recovery, toggle and revoke; metadata import and token migration share registry → canonical locks and PersistenceCore's connectionDecision field. Connected or undecided may migrate; only a recorded person-disconnect retires oauth_tokens/slack.json without importing metadata or tokens, until explicit reconnect. Seeds, first reads and migrations are undecided; enabled/authState never record a choice. Eligible absent canonical auth imports checked legacy metadata with verified publication before source removal; runtime policy reads canonical metadata only. File tokens migrate through verified Keychain writes, canonical fields winning over legacy input; a committed grant stays authoritative. Retained connectors/slack/oauth_app.json has no reader; coverage decisions live here |
| `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; socket/history/recovery admission, retains accepted handler tasks until actual exit with one active handler per event in the process (across loop replacements), and terminal delivery truth; `path`, `recoverySummary`, `failedReplyClaims`, `confirmReplyPart` retain confirmed text/image progress across holds; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | Socket configuration and throwing ingress/toggle readers consume TransportAllowlist's checked Slack metadata and strict string-only union; UI callers retain unavailable authority as a failure |
| `SlackSocketModeLoop+Answers.swift` | `SlackSocketModeLoop`: journal-owned inbound handling, durable answer recovery and delivery, accepted-reply reconciliation and deferred settings settlement |
| `SlackSocketModeLoop+Evidence.swift` | `SlackSocketModeLoop`: bounded receipts and errors, envelope evidence, diagnostic state patches, timestamps and secret redaction |
| `SlackSocketModeLoop+History.swift` | `SlackSocketModeLoop`: conversation discovery, bounded history paging and socket-health polling deadlines; reconnect gap fill and the missed-event backstop retain their intervals |
| `SlackSocketModeLoop+Media.swift` | `SlackSocketModeLoop`: inbound file parsing, bounded image hydration, attachment notices and uploadable image selection |
| `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: one closure classifier for receive return, disconnect and transport error; fatal disconnects outrank planned recycling |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop` state, `tick`, `tickOutcome`, socket lifetime and ingress; session cancellation closes pending receives and drains passive work while journal-owned accepted handlers continue |
| `SlackSocketModeSupport.swift` | `SlackConversationRef` struct; `SlackHandlingCompletion` keeps deferred settings operations within the accepted handler's lifetime, after reply settlement |
| `SlackTurnContracts.swift` | `SlackInboundFile` struct |
| `SlackTurnIngress.swift` | `SlackSocketModeLoop.ifConfigured`: configured Slack ingress, engine-profiled chat and settled-turn signal wiring without forged signature authority |
| `SlackWebAPI.swift` | Shared HTTP response normalization for replies, history's injected session and explicit setup tokens; replies retain grant checks and record proofs through ConnectorActionReceipt, history/setup retain strict rejection; uploads and `requireConfiguredToken` |
<!-- END GENERATED BLUEPRINT -->

### StandingBots

Directory: `Modules/NativeAgentCore/Sources/StandingBots/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/StandingBots/ -->
| File | Owns |
|---|---|
| `BotDefinitionStore.swift` | Definition persistence and exact helper session ownership; editor model/budget/schedule/event admission; launch leaves saved definitions and model choices untouched, with no migration marker |
| `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |
| `BotEventTriggers.swift` | `BotEventRouter` and `BotEventStore`: Slack event matching/admission and durable wake records from already received events |
| `BotHeadline.swift` | `BotHeadline` enum; `make`, `clipped` preserve whole-word reply headlines |
| `BotLegacyHistory.swift` | `ShelfStore`: `legacyHistory` |
| `BotRunQueue.swift` | `BotRunQueue` struct; `enqueue`, `presence` |
| `BotRunner.swift` | `BotRunner` actor; `run`, `ask` |
| `BotRunnerDeadline.swift` | One helper seconds deadline is reported when crossed and never cancels its work; scheduled runs and direct conversations share it |
| `BotRunnerScheduler.swift` | `BotRunnerScheduler` actor; `effectiveSchedule` shares reconciled timing and admission with live deadlines |
| `BotTurnRunner.swift` | `BotTurnRunner` owns helper-only model/tool rounds over the shared prefix layout supplied by its adapter; injected wire codecs, gated dispatch and row writer reuse their existing owners; Stop saves partial output through settle |
| `BotsShelfRead.swift` | Shelf and Desk consume `BotRunnerScheduler.BotSchedule`; one running/queued/model-choice/pause/run-status classification for Mac, quiet reads and iPhone; approval and run-feed read models |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for StandingBots diagnostics |
| `ShelfApprovalReconciliation.swift` | `ShelfStore` approval reconciliation: all shelf readers project canonical approval resolution without making shelf copies authoritative |
| `ShelfStore.swift` | `ShelfStore` struct; `append`, `settleApproval`; query-bound cursor and plain offset paging with whole-word headlines |
| `StandingBotSchedule.swift` | `StandingBotSchedule` enum; `parse`, `words` |
| `StandingBotsDisk.swift` | `StandingBotsDisk` struct; `validatePath`, `locked` |
| `StandingBotsModels.swift` | Helper definitions own name, optional personality, job, output and provider/budget settings; cadence, run and shelf values |
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
| `MakeStudio.swift` | Root-scoped artifact metadata, native decoding, durable version allocation and previews; generated-image registration is editable `Resources/abilities/make-generated.js`, composing native raw generation results with `make.add` (prompt/model metadata retained); native generation receipt paths are scoped to that call, and the registration primitive admits those verified app outputs while arbitrary files retain the workspace fence; `MakeStudio.Shelf` owns watcher/coalescing lifetime and publishes its read results through `LatestRead`; each preview file/revision owns L0 `PartFaces` for editable `Resources/abilities/make-title.js` (HTML title → prompt → filename); native unavailable/failed status accompanies the face, views only read their preview's snapshots; shutdown drains projections and cancellation never rearms a retired shelf |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Studio diagnostics |
| `StudioCanon.swift` | Append-only membership, evidence-bound proposal references and unchanged native identity/fingerprints (fixed 90-day silence ledger units); editable `Resources/abilities/studio-canon.js` owns proposal selection/reasons and the next silence deadline; native counts/entry ids cannot be supplied by the part, native capacity and agent-only decision/append authority remain |
| `StudioConsult.swift` | Studio errors and immutable consult envelopes |
| `StudioJournalEntry.swift` | Encounter, journal and amendment vocabulary; corrections project without rewriting journal bytes |
| `StudioRecall.swift` | Read-only recall and encounter-intake values |
| `StudioStore.swift` | Append-only journal and corrections, consult and honest-encounter truth; timestamps use NativeTimestampFormat directly; `encounterIntakePage` exposes bounded neutral consult/corrected-history facts with a shared content digest, refuses unreadable/incomplete history and changed pages; `namedEncounterIntake` validates editable `Resources/abilities/studio-intake.js` selection against native encounter truth, retaining no Swift ordering or invitation prose |
| `StudioWorkingShelf.swift` | `StudioWorkingShelf` struct; `decodeSlots`, `selections` |
<!-- END GENERATED BLUEPRINT -->

### SwarmRuns

Directory: `Modules/NativeAgentCore/Sources/SwarmRuns/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SwarmRuns/ -->
| File | Owns |
|---|---|
| `RunLedger.swift` | `RunLedger`: cross-surface completed-run summary |
| `SwarmExecutor.swift` | `SwiftNativeAgentSwarmExecutor`: admission, worker execution, provider/model/tool access, concurrency, deadlines, cancellation, character-safe retention and partial outcomes; progress, terminal receipts and removal delegate to the shared runs owner. The originating app door calls `Resources/abilities/crew-instructions.js` through L0 `Parts.call` for briefs, synthesis messages and digest policy; preparation failure is explicit and settlement uses the prepared digest without starting JS after Stop |
| `SwarmReceipts.swift` | Swarm result values and JSON receipts, persistence errors, wire timestamps, worker plan/progress JSON and `SwarmLiveBoard`; live progress delegates storage and recovery to `SwiftNativeSwarmRunsReader` |
| `SwarmRequests.swift` | `AgentSwarmError`, `AgentSwarmPolicy`, `AgentSwarmWorkerSpec`, `AgentSwarmRunRequest`: policy bounds, request aliases, Work model/account binding, worker access and effort validation, and dry-run plans |
| `SwarmRunsReader.swift` | `SwiftNativeSwarmRunsReader`: owns live-board and receipt storage and worker report IDs; one read-only recovery projection for crews, report inspection and the live board; inspection gives pending live workers their deterministic IDs and marks absent output unavailable, preserving strict terminal-report validation; durable receipts win, interrupted completion time stays unknown, and `SwarmCrew.liveness(of:)` classifies every crew view without promoting unknown to running or replaying work; its writer records recoveryObservedAt once when committing projected recovery before the next board write and removes it only after receipt durability |
<!-- END GENERATED BLUEPRINT -->

### SystemOps

Directory: `Modules/NativeAgentCore/Sources/SystemOps/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SystemOps/ -->
| File | Owns |
|---|---|
| `SoftwareUpdateState.swift` | `SoftwareUpdateState` |
| `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |
| `SystemOps+Production.swift` | `ProductionExport`: checked typed export registry reads, stable newest-first ordering and archive verification; no external status runtime |
<!-- END GENERATED BLUEPRINT -->

### TelegramBot

Directory: `Modules/NativeAgentCore/Sources/TelegramBot/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TelegramBot/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TelegramBot diagnostics |
| `TelegramApprovalHandling.swift` | `TelegramApprovalHandling`: addressed-bot-aware approval parsing, callback contracts and canonical approval resolution/delivery lifecycle |
| `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver` actor; `onDelta`, `finalize` |
| `TelegramBot+APIHelpers.swift` | `_tgBuildBotURL`: canonical path-segment and query encoding for Telegram Bot API URLs |
| `TelegramBot+Client.swift` | `SwiftNativeTelegramBot` client wiring and dependency/result contracts; status/test send, locked log clearing and long-poll accounting |
| `TelegramBot+Config.swift` | Saved shape validation, exact positive `voice_max_bytes` and TransportAllowlist's normalized integer IDs. Model/effort fields are legacy routing metadata; voice model metadata does not select recognition. Loads can remove retired credentials and migrate plaintext to Keychain. Conditional saves resolve kept tokens under the config lock and advance revisions, including disconnect |
| `TelegramBot+Models.swift` | Telegram wire models: typed API failures/results, sender/update/message/reply context and callback number decoding |
| `TelegramBot+Settings.swift` | Mobile operation prerequisites delegate saved field validation to `TelegramConfig.validateSavedConfiguration` |
| `TelegramChatHandling.swift` | Telegram chat contracts: progress/compaction sinks and attempt context carrying decoded sender identity separately from chat identity |
| `TelegramCommandMenu.swift` | `TelegramCommandMenuStatus` and `TelegramCommandMenuSync`: command-menu synchronization status contract |
| `TelegramCommandPolicy.swift` | telegram-commands.js projects menu/help over native command identities through L0 PartFaces and prepares memory reply words before the native write; reserved Stop/approval controls, canonical memory provenance, storage and awaited reply settlement remain native; menu synchronization keys on the selected part version |
| `TelegramCommands.swift` | Telegram command identities, aliases, menu visibility, slash parsing and bot dispatch for the destination's conversation |
| `TelegramMediaAttachment.swift` | `TelegramMediaDownloader`: two-stage file metadata/download admission with declared-size and actual-byte bounds |
| `TelegramModelSelection.swift` | Account-scoped provider/model selection, capability lookup, menu values and bot-facing model access |
| `TelegramModelSelectionHandling.swift` | `TelegramModelSelectionCallback`: provider/model selection callback encoding, key validation and action parsing |
| `TelegramOffsetCursor.swift` | `TelegramOffsetCursor`: monotonic durable getUpdates cursor; only missing state bootstraps and corrupt state cannot replay commands |
| `TelegramPartPolicy.swift` | Telegram's originating-door typed part calls use the canonical turn envelope, not a separate origin identity; telegram-model-picker.js interprets requests and draws menus; native code supplies checked choices, authenticates callback identities, validates returned buttons and retains canonical routing writes |
| `TelegramPollBackoff.swift` | `TelegramExponentialBackoff` and `TelegramErrorLog`: poll/menu failure cadence and locked bounded error-log rotation |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`; approval commands/callbacks carry decisions; shared approval transactions own reporting turns; the transport recovers only already-produced legacy answers |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`: `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand`; admitted commands/callbacks bind their Telegram surface, verified chat/sender and work identity in TurnEnvelope; Telegram has no command-signature scheme |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `chatAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+QueuedTurnControls.swift` | `TelegramPollLoop`: `handleQueuedTurnControlCallback` |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: sole checked state.json reader and mutation owner (`readState`, `mutateState`) for polling, migration and status consumers; only missing state is empty, and unreadable/non-object state fails with a dedicated telegram/state.json error and is never overwritten; migration locks only existing legacy storage; `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |
| `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody` |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramPollLoop.swift` | `TelegramPollLoop`: authenticated update intake; tracked media preparation retains unstarted updates on shutdown and settles explicit Stop; saved reply recovery and checkpoint settlement |
| `TelegramProgressFace.swift` | Per-card source epoch and L0 PartFaces cache over sanitized canonical phase and timing; native availability/failure and output redaction; Telegram progress/status voice comes from telegram-progress.js, entered through the originating app door |
| `TelegramQueuedTurnControls.swift` | `TelegramQueuedTurnControlCallback`: queue control markup and callback decoding retaining forum-topic identity |
| `TelegramRestart.swift` | Owner-authorized Telegram restart through the injected app operation with termination deferred until the reply attempt |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramSessionStore.swift` | `TelegramSessionStore`: locked session mint/adoption and delivery mapping with exact resolution traces; the shared anchor selects the owner's ordinary conversation; owner resume/list admission requires a live direct row before binding |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger` actor; one owner per canonical ledger path across poll-loop replacements serializes `upsert` and `remove`; `TelegramTurnCardRestartRepairer` owns one repair task and shutdown |
| `TelegramTurnControls.swift` | `TelegramTurnControlCallback`: active-turn control markup and callback decoding retaining forum-topic identity |
| `TelegramTurnCoordinator.swift` | `TelegramTurns`: active/queued turn ownership, durable update recovery exclusion and control claims; Stop presentation keeps tasks owned and joinable through operation/receipt/ingress/card settlement until completion releases the slot |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias; canonical lifecycle adapter and native redaction; authored progress wording lives in telegram-progress.js |
| `TelegramTurnProgressCardDriver.swift` | `TelegramTurnProgressCardDriver`: one acknowledged lifecycle message per accepted turn; terminal waiters resolve only after identity persistence; terminal repair belongs to the delivery ledger |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox` struct; `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`; maintained claim index emits delivery invalidations and can be reconstructed from checked claims without changing phases; recovery exceptions retain a terminal quarantined claim and reason, excluded from automatic replay; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `TelegramVoiceTranscription.swift` | Telegram voice transcription owns and joins conversion, recognition and system-temp cleanup on Stop/deadline; temporary audio stays outside the data root, backup/export/phone sync and the PrivacyMap telegram tree |
<!-- END GENERATED BLUEPRINT -->

### ToolRegistry

Directory: `Modules/NativeAgentCore/Sources/ToolRegistry/`

| File | Owns |
|---|---|

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ToolRegistry/ -->
| `ChatToolCatalog.swift` | `ChatToolCatalogSnapshot`, schema and dispatch-plan values: typed tool inventory and runtime safety categories, with presentation-only taxonomy |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ToolRegistry diagnostics |
| `ToolDescriptor.swift` | `ToolDescriptor`, `ToolExecutor`, `AppActionBinding`: composed action calls, effect declarations (class, reach, capabilities; each form supplies the common case) and executable ownership registration |
| `ToolNameAliases.swift` | `ToolNameAliases`: one spelling/argument translation owner across Trust, dispatch, receipts and visible app-call projection |
| `ToolRegistry.swift` | `ToolRecord` and AbilityStore's checked part-record projection: missing required fields are omitted; invalid authored fields fail listing and dispatch discovery; `keepReview` and `reviewedKeepDigest` bind waiting or selected code to the review captured under the ability-store lock |
<!-- END GENERATED BLUEPRINT -->

### Transcripts

Directory: `Modules/NativeAgentCore/Sources/Transcripts/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Transcripts/ -->
| File | Owns |
|---|---|
| `ChatCancelFlag.swift` | `ChatCancelFlag`: run-identity Stop markers and in-flight registration; later acceptance never erases a prior turn's Stop |
| `ChatExportService.swift` | Shared chat export errors and completion value; concrete Markdown export lives beside EngineRuntime's ChatMessage |
| `ChatSessionIndexFile.swift` | Canonical durable index writer, creator-declared conversation kinds and exact-owner corrections, checked index schema and message-index, projection-generation, transcript-rewrite and retention-removal transactions; count/acknowledgment reads under index → transcript locks, retention on every message within the index transaction; `recordContinuityParticipant`, `recordConversationChange`; backup/export/sync/privacy decisions live here |
| `ChatSessionRecollections.swift` | Recollection row/coverage parsing, exchange pairing by conversation/run with runless adjacency, incremental scans and timestamps |
| `ChatSessionRetention+ArchiveHistory.swift` | Checked archive-index decoding, ordered transcript discovery and byte-preserving restoration; callers retain sessions-index then transcript lock order |
| `ChatSessionRetention+PinnedChats.swift` | Pinned-chat preferences and retention mirror; mirror writes precede defaults publication, and unreadable protection halts retention |
| `ChatSessionRetention+StateExpiry.swift` | Bounded orphan session-state expiry under the caller's locked index snapshot; one archive-tier change/interval admission mark, with canonical history never expired |
| `ChatSessionRetention.swift` | Archive eligibility and protected conversations; manual/retention archive settlement and durable append before hot-row removal; index to transcript to archive lock order, exact acknowledged-version guard and retained chat storage |
| `ChatSessionScratch.swift` | `ChatSessionScratch` owns the session scratch JSON path, locked mutation and reads for Mac, Telegram and tools; off-disk backup only, no local backup/export/phone sync, inventoried under chat |
| `ConversationAnchor.swift` | `ConversationAnchor`: shared current-person conversation publication, protected sessions and adoption decisions across surfaces; only a session whose row records it as their direct conversation may anchor (`mayAnchor`), whatever door publishes |
| `InlineInteractionCompactionRetention.swift` | `InlineInteractionCompactionRetention`: preserves live/suspended card handles during destructive transcript compaction |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Transcripts diagnostics |
| `SessionConversation.swift` | `SessionConversation`: row-backed conversation kind for a session or id; creator source keys apply current declarations to historical transport rows on read; one index read can serve a whole batch, and one-id reads reuse each index parsed once per file stamp |
| `TranscriptRowStamp.swift` | One saved-row speaker/steering/contact projection for metadata and persisted preview stamps; imported or generic-agent rows attest no speaker |
| `TranscriptRows.swift` | `ContactThread` uses PersistenceCore's canonical JSONL serialization and owns durable append and exact-byte row edits/replacement for chat, compaction and archive restoration; writes share the owner lock and compound caller lock boundaries; session-index mutate provides checked read/edit/commit. `read` shares tail/incremental byte reads; `Line` retains each row's stamp, words, speaker and answers-id; `project` is the shared presentation; displayed contact speech alone calls `consume`; `DelegatedReplyEnvelope` shares reply/header syntax for search and presentation under caller-owned provenance admission |
<!-- END GENERATED BLUEPRINT -->

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TriggerScheduler/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TriggerScheduler diagnostics |
| `MorningBriefAssembly.swift` | SwiftNativeTriggerScheduler authored morning-brief card assembly, part invocation and inactive schedule defaults |
| `MorningBriefPart.swift` | Originating-door invocation and typed inactive-default/publication proposal wire; no briefing policy or model prompt |
| `MorningBriefSources.swift` | Frozen checked Desk, Workshop, inbox, session and bounded parsed/redacted worklog observations; only consumed fields enter the part, with native row validity and unavailable/empty distinctions; native local-day and date-label facts |
| `ScheduledJob.swift` | `ScheduledJob`: strict scheduler row decoding and projected civil next-run decoration while preserving claimed/retry instants |
| `SchedulerJobNormalizer.swift` | SchedulerJobNormalizer canonical job input normalization, delivery channels, saved scalar coercion and timing decoration |
| `SchedulerJobOccurrences.swift` | SwiftNativeTriggerScheduler life-stamped job occurrence claims, settlement, pruning and default-cycle row updates |
| `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: shared civil schedule math and next occurrences; timezone changes cannot mint another civil occurrence |
| `SchedulerJobs.swift` | SwiftNativeTriggerScheduler canonical bounded job storage, mutation, activity receipts and read-only app-door watch admission |
| `SchedulerRecurrence.swift` | SchedulerJobNormalizer recurrence arithmetic, civil-minute matching and timestamp parsing |
| `TriggerInboxPublication.swift` | SwiftNativeTriggerScheduler inbox preparation, locked durable acceptance, notification delivery and activity receipts |
| `TriggerNotificationInbox.swift` | `TriggerNotificationInbox`: proactive identity matcher, checked locked mirror, `archiveSupersededMorningBriefs` |
| `TriggerOccurrences.swift` | SwiftNativeTriggerScheduler daily eligibility, durable life-stamped trigger claims, repair, deadlines and checked occurrence/config reads |
| `TriggerScheduler.swift` | SwiftNativeTriggerScheduler actor, trigger configuration and consent, legacy-file import and Workshop submission |
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
| `CapabilityCatalog.swift` | Capability sources, trust roots, historical pack installation receipts and removal; catalog registry aggregation and mutation share `CapabilityCatalogStoreReader`'s checked object-array schema; workflow mutations delegate to SavedWorkflows. Installed items and receipts are authoritative, with no saved pack copy or `packPath`. Retained `catalog/packs` files are untouched orphans, excluded from local backup, export and phone sync; PrivacyMap lists their catalog folder. |
| `CapabilityPackParts.swift` | Removal of historical capability-pack parts through AbilityStore; only a matching install receipt owns their removal |
| `CapabilityRecords+Dynamic.swift` | Read-only capability projections; workflow and catalog registries use their owners' checked schemas, never default over damaged saved state |
| `CapabilityTrust.swift` | `SwiftNativeCapabilityTrust`: checked capability trust/catalog values, scoring, evaluation and display projections |
| `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor` and `connectorActionDescriptors`: static connector action/schema inventory; live authentication decoration belongs elsewhere |
| `ConversationSurfaceProfile.swift` | `ConversationSurfaceProfile`: canonical origin normalization and remote/mobile classification; domain trust evidence stays with authority owners |
| `FeatureSurfaceRecords.swift` | `FeatureSurfaceRecord` and `featureSurfaceRecords`: feature surface manifest and the app actions that reach each surface |
| `MacControlGate.swift` | `MacControlGate`: effective Mac policy admission, private-path rules and admitted Full Mac handling through checked Trust |
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Peer-origin approval floors read only the declared call class; memory notes retain origin attribution without the former human-turn read-latch exception; ability changes/growth capture use CapabilityLifecycle's common write guard |
| `SavedTrustPolicyAuthority.swift` | `SavedTrustPolicyAuthority`: point-of-use saved policy reads through canonical shape/type validators; invalid authority never reads as configured |
| `SavedWorkflows.swift` | `SavedWorkflows`: one checked registry schema and stable timestamp sorting for read-only list/projection and historical pack removal; list and Capabilities share exact legacy-seed normalization without changing customized rows or saved bytes; `WorkflowStep`, `WorkflowRecord`; no default seeding or read-side writes; backup/export inclusion, no raw phone sync and workflows privacy coverage are declared here |
| `SecurityCenter+FullMacPolicy.swift` | `SwiftNativeSecurityCenter`: `fullMacActive`, `fullMacYoloAuthority`, checked local `localFullMacYoloAdmitted`, `drivenAgentLaunchPermission` |
| `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: audit `redactValue`, using Privacy's canonical detection predicates |
| `SecurityCenter+JSONUtilities.swift` | Trust JSON primitives and workspace roots; resolved containment uses NativeAgentWorkspaceRoot's byte-exact component law; transport policy decoding belongs to TransportAllowlist in PersistenceCore |
| `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |
| `SecurityCenter+PathPolicy.swift` | Capability effects and Mac Control file admission use NativeAgentWorkspaceRoot's byte-exact path law; supported file mutations share execution's resolver and relative base; unknown relative capability paths count as outside; `capabilityWritesOutsideAppData`, `pathIsInsideRoots`, `pathLikeStrings` |
| `SecurityCenter+ReceiptJSON.swift` | `SecurityToolEnvelope`: `toJSONValue` |
| `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary`, `isoTimestamp` |
| `SecurityCenter+ToolProfiles.swift` | AuthoredToolEffects.shellReadOnlyWords certifies literal shell reads for gates, receipts and fixed-argv read confinement; canonicalToolRisk and declared effect projection; app-call read treatment delegates to PermissionLaw.toolClass, with argument policy and display severity |
| `SecurityCenter.swift` | Security decisions including permission-reset approval, audit JSONL, preserved pretrim archive and completion marker; local backup/export/phone exclusions and Security Audit privacy scope declared at the owner; status accepts the facade's checked policy generation without rereading it |
| `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner` actor; 32-byte regular 0600 signing authority with explicit backup/export/sync/privacy decisions; `canonicalBytes`, read-only `existingSigningKey` for proof checks |
| `TrustAccessModeCapabilityCatalog+Read.swift` | Trust projections; effective Full Mac uses MacControlGate's admitted-call projection and PermissionLaw's Full Mac posture: no category approval prompts; saved restricted-mode approval metadata remains unchanged |
| `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog` enum; `normalizedMode`, `macControlPolicy` and Mac integration preset recognition |
| `TrustCenter+Autonomy.swift` | `PermissionLaw` enum: `posture`, `answer` (the one effective level), `judge`, `toolClass` (the one class resolution per call, read by authorization and scheduling), `doorClass` (a door action as it runs, folded ones as their tool; what a scheduled read is held to), `reachesUser`, `reach(ofPermissions:)` (a part's declared permissions → theirs or their); `SwiftNativeTrustCenter.autonomyLevel` delegates to `PermissionLaw.answer` |
| `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter.authorizeChromeControlEffect`: checked authority distinguishes disabled from unavailable without a Boolean wrapper |
| `TrustCenter+Defaults.swift` | Canonical Trust/Mac schema, using immutable MacControlPolicyWireSnapshot scalar defaults shared with typed and phone reads |
| `TrustCenter+PolicyLoading.swift` | Canonical checked policy bytes, decode/shape validation and normalization, also used by SavedTrustPolicyAuthority's exact-byte validation cache; absent files and validated empty objects receive fresh-install additions |
| `TrustCenter+PolicyModels.swift` | `TrustCenterDefaultWorkspaceRoots`, `TrustCenterError` |
| `TrustCenter.swift` | Checked policy object and preserved damaged-policy bytes, with backup/export/live-policy phone/Trust privacy decisions; `getTrust`, `applyPolicyPatchChecked` |
| `TrustPolicy.swift` | Typed UI subset, not full authority: security/provider/personality/iOS-remote blocks remain in the raw checked policy sent to the phone |
| `TrustPolicyActions.swift` | `TrustPolicyActions` struct; `developerModePatchBody`, `saveMemoryPolicy`, `saveAgentAccessMode`; `saveMacControlPolicy` patches edited fields and checks their baseline inside the policy lock |
| `TrustPolicyToolWriter.swift` | `TrustPolicyToolWriter` enum; `applyTrustPolicyPatch` |
<!-- END GENERATED BLUEPRINT -->

### TrustPersistence

Directory: `Modules/NativeAgentCore/Sources/TrustPersistence/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TrustPersistence/ -->
| File | Owns |
|---|---|
| `ProductionExport+Archive.swift` | Production archives consume PrivacyMap.productionExportRelativePaths; production, support and local backup input scopes are complete allowlists with unselected scopes excluded; the backup owner's recursive copier snapshots nested memory SQLite and omits lock/journal sidecars; canonical memory backup and persona root, credential exclusions with actual skipped paths; support bundles keep their separate selection and registry rows; staging is removed on return or failure and archives use the backup owner's streaming digest |
| `TrustBackupCapture.swift` | TrustBackupPersistence capture and export copying; ordered scopes, writer locks, credential exclusions and read-only SQLite copies |
| `TrustBackupCatalog.swift` | TrustBackupPersistence catalog publication and retention; writable index.json, read-only legacy registry.json, verified restore points, pins and staged dependencies |
| `TrustBackupFoundation.swift` | `JSONDecoder`: extension |
| `TrustBackupModels.swift` | Backup records and restore results; requiresRestart distinguishes staged scopes/time from completed installation; notCarried records unreadable pieces, causes and losses |
| `TrustBackupOffDisk.swift` | TrustBackupPersistence off-disk copies; credential exclusions, SQLite journal conversion, landed integrity verification and automatic retention |
| `TrustBackupRestore.swift` | TrustBackupPersistence forward restore installation; durable intent and receipt, cataloged pre-restore backup, continuity fences and transcript version advancement |
| `TrustBackupSnapshot.swift` | TrustBackupPersistence sealed snapshot evidence; bounded integrity manifests, link containment, authority validation and legacy sealing |
<!-- END GENERATED BLUEPRINT -->

### TurnTrace

Directory: `Modules/NativeAgentCore/Sources/TurnTrace/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TurnTrace/ -->
| File | Owns |
|---|---|
| `AbandonedTurnReconciler.swift` | `TurnCheckpoint` retains its originating DataRootLife; reads project stopped/restored across lives, ordinary reconciliation settles through the Stop terminal record before retirement; independent checkpoint discovery, strict day validation, sweep-local terminal index and guarded retirement |
| `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook` enum; `arm`, `disarm`; retains sweep/resume jobs through exit and removes its observer at engine termination; excludes active turns and claims checkpoint resumes; terminal settlement awaits the installed anchor-intent adapter |
| `SessionIdentity.swift` | Session identity ledger, mint-site traces and source-flapping diagnostics |
| `TurnFirstRenderRegistry.swift` | Bounded single-claim first-render correlation and publication |
| `TurnInspectorFeed.swift` | Engine-owned persisted today/yesterday evidence, exact file observation, `LatestRead` publication with checked read failures, grouped Mac cards, bounded phone summaries and immutable selected-date replay reads |
| `TurnInspectorPresentation.swift` | Inspector statuses, titles, rows, cards and redacted details, including memory-promotion prediction, deferral and unlabelled evidence |
| `TurnPractice.swift` | `TurnPractice`: each agent's practice as the night reads it (AGENT_IS_THE_APP "Practice compiles"): its turns' top-level `app` calls from `tool.dispatch` end rows (a nested call is its part's), recurring successful sequences of two or more operations nominated against what the parts' own frequencies give by chance (exact Poisson tail at `VectorMath.chanceBar`'s attention tail among the sequences tested; closed sequences only), the per-agent ledger and its recording set, bounded redacted tape rows for nominated operations only that keep what is exact (arguments and outer operational options when unchanged, the result path by path, left-out paths named and absent from the replayed reply, never reconstructed; a replay verifies the calls alone), each row carrying its call-end sequence (`nextSequence`, taken on the dispatch path) and appended at once, the trim ordering by it, occurrences joined to the tape by receipt id with honest coverage, and the value-flow map (a constant, an earlier result's or arguments' path, or judgment) the compile filter and their packet read; `turn_traces/practice/` |
| `TurnSummaryRecord.swift` | `TurnSummaryComputer`, `TurnSummarySource`: Mac-owned Inspector privacy projection and byte budgets |
| `TurnTraceBus.swift` | In-process multicast and bounded ingress/disk queues with sole retained workers; durable terminal delivery before checkpoint retirement |
| `TurnTraceContext.swift` | Request-scoped turn identity, origin, reply route and stable reply-row correlation |
| `TurnTraceEvent.swift` | Canonical event schema, terminal kind/status vocabulary, envelope and payload bounds; model-call receipts retain the shared ledger byte budget |
| `TurnTraceGrouping.swift` | Stable arrival-index grouping and exact nonnegative measurements with damage evidence shared by Inspector and phone summaries |
| `TurnTracePersistLane.swift` | One diagnostic writer for daily turn traces and standalone receipts; owns the filename/day calendar, guarded appends and durable terminal notifications |
| `TurnTraceRecentReader.swift` | Checked recent/day-file reads, historical receipt reconciliation and usage queries; preserves unmatched history, outcomes and read coverage |
| `TurnTraceReplayReader.swift` | Persisted trace framing, physical row sizes, stat-stamped replay caching and Doctor scans; terminal matching remains independent of recovery coverage |
| `TurnTraceRetention.swift` | `TurnTraceRetention.enforce`: date-based expiry of trace artifacts and their lock sidecars with retention receipts |
| `TurnTraceW2.swift` | `TurnTraceRedactor` and `InspectorThinkingLane`: shared trace redaction and per-surface summarized-thinking visibility gate |
<!-- END GENERATED BLUEPRINT -->

### WorkshopExecution

Directory: `Modules/NativeAgentCore/Sources/WorkshopExecution/`

Execution records use only `execution.json`; directories without it are excluded
from the shared queue enumeration, while damaged canonical records block admission.
Launch and reads never rename or repair saved Workshop files. Retired `mission.json`,
its lock/conflict files, `workshop/legacy_executions.json` and `workshop/migrations/`
evidence remain untouched for User to decide. Per-step receipts remain overview artifacts;
steps_completed is durable truth, with the receipts directory derived on read without saved-pointer rewrites.

Failed or invalid plans refuse submission instead of substituting synthesis steps; provider failures retain their original repair evidence. The runner preserves explicit per-step working-folder arguments, supplying omitted arguments from the plan's required `working_directory`. The planner interprets the first path named in the objective (a file, including a creation target, uses its parent; a directory stays as named even if absent), else the canonical workspace; filesystem existence does not decide a path's intended role. Executor handoff preserves the full result projection; textual verification matches only result strings or `text`, `content`, or `stdout`, including nested `output`, excluding receipt metadata. Only model context is bounded, preserving head and tail with an explicit elision count.

The tool-step contract separates required effects from read evidence. Planning
preserves the objective's conditional reads as `optional: true`; omitted on an
older plan means required. The actual call's class comes from Trust's existing
effect declaration, including resolved door actions and arguments, never a
tool-name list or a planner's claim. Only declared reads may be optional.
Effects fail on failed or partial outcomes. Reads with retained results continue,
recording `partial` when coverage is incomplete; a required read with no result
fails, while an optional one records `skipped`. Each read receipt retains its raw
reply and `read_coverage` (`complete`, `partial`, `absent`, or `unavailable`), which
later synthesis also sees. A null reply or failed read without declared partial
coverage supplies no result; successful empty files and collections are valid
answers. Workshop uses the owner's outcome/coverage, without guessing payload
meaning from field names. Cancellation stays
cancellation. Confirmed absence may begin fresh work where the objective permits;
an unavailable or incompletely read existing source is never permission to
replace it as empty. Existing saved plans and data are not rewritten.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/WorkshopExecution/ -->
| File | Owns |
|---|---|
| `BackgroundWorkLease.swift` | `BackgroundWorkLease` actor; persisted shared window claims and release of the holder’s newest unused claim |
| `ExecutionRecordDecoding.swift` | SwiftNativeWorkshopRunner execution-record decoding, faithful validation and persisted plan parsing |
| `ExecutionRecordFile.swift` | Canonical execution record/timeline I/O; a missing stamp means the first DataRootLife; active records from another life read stopped with terminal_reason restored before every claim/recovery/update; no filesystem migration on read |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for WorkshopExecution diagnostics |
| `StepCancellationObservation.swift` | WorkshopExecutorLoop step cancellation and deadline observation; returned effects settle before continuation |
| `WorkshopArtifactWriter.swift` | `WorkshopArtifactWriter` descriptor-anchored handle-scoped artifact filesystem, safe components and bounded UTF-8 reads |
| `WorkshopCompiledLocalFileCopyProcedure.swift` | `WorkshopCompiledProcedurePlanError` enum |
| `WorkshopCompiledProcedureRuntime.swift` | `WorkshopCompiledLocalFileCopyInvocation`: reviewed exact artifact invocation through Workshop queue; existing Trust/file dispatch retain authority |
| `WorkshopExecution+Admission.swift` | `WorkshopExecutorLoop` queue admission, drain, slot claims and restart/approval-timeout recovery; originating DataRootLife governs restored records and explicit fresh starts |
| `WorkshopExecution+Approvals.swift` | `WorkshopExecutorLoop` resolved-step approval evidence, resumption, rejection, annotation and blocked-step claim clearing through ExecutionRecordFile |
| `WorkshopExecution+CausalTransitionEvidence.swift` | `SwiftNativeWorkshopRunner` causal/motor projections: payload-free canonical plan interpretation, provider accounting and evidence classes without fabricated execution |
| `WorkshopExecution+Content.swift` | `WorkshopExecutorLoop` synthesis content validation, prior-step prompts, single-pass argument references and full/bounded output handoff |
| `WorkshopExecution+DeskTasks.swift` | `WorkshopDirectedTaskSubmitter` and Desk receipt bridge: Desk-first task identity with canonical Workshop execution and terminal evidence |
| `WorkshopExecution+Executor.swift` | `WorkshopExecutorLoop` actor, configuration, canonical Desk cancellation, outcome settlement and execution record/timeline/receipt I/O through ExecutionRecordFile |
| `WorkshopExecution+OutcomeScoreboard.swift` | Native canonical receipt/record decoding, verification classification, timestamp interpretation and complete `weeklyOutcomeInput` evidence; missing stores are available empty, unreadable/incomplete sources throw. Editable `Resources/abilities/weekly-outcomes.js` owns local ISO-week grouping, statistics, trend thresholds and digest text; EngineLaunch invokes it through `ToolsFacade.withPartDoor` for maintenance, without activating schedules or a Swift policy substitute |
| `WorkshopExecution+OutcomeVerification.swift` | `WorkshopExecutorLoop`: `unmetSuccessCriterion`, `verifyCompletedOutcome` |
| `WorkshopExecution+PlannerLLM.swift` | `SwiftNativeWorkshopPlannerLLM`: checked executions routing admission, live catalog binding and provider planner calls |
| `WorkshopExecution+Runner.swift` | SwiftNativeWorkshopRunner canonical execution.json ownership, safe execution IDs, queue admission, planning, cancellation and timeline receipts |
| `WorkshopExecution+Steps.swift` | WorkshopExecutorLoop step progression, approval gating, dispatch and declared-read coverage |
| `WorkshopExecution+Types.swift` | Workshop execution value contracts: specs/steps with optional-read intent, verification/records, enqueue outcomes, argument validation and planner interface |
| `WorkshopExecutorContracts.swift` | Workshop step approval/dispatch contracts and outcomes with independent read coverage |
| `WorkshopProcedureExactActivation.swift` | `WorkshopProcedureExactActivationQualifier` and coordinator: event-driven qualification from immutable terminal evidence and exact procedure ledger identity |
| `WorkshopPump+Selection.swift` | `WorkshopCandidate`, `PursuitChoiceScore` and `WorkshopPump` due-item selection, choice rationale, cadence deadlines and Desk-day windows |
| `WorkshopPump.swift` | `WorkshopPump` tick and live/recovered receipt settlement through Desk’s ops lock; status changes require the latest reservation on a nonterminal item and receipt-only recovery requires its unchanged commit revision |
| `WorkshopReceiptLog.swift` | `WorkshopReceiptLog` actor; session/directed_task receipt variants, one locked idempotent directed batch append, reservation recovery index and bounded raw read of workshop/receipts.jsonl |
| `WorkshopReservationDurability.swift` | `WorkshopReservationDurability` canonical reservation and receipt file/directory fsync boundary |
| `WorkshopSession.swift` | `WorkshopSession` struct; `run`, `trimSummary` |
| `WorkshopSessionContracts.swift` | `WorkshopSessionStatus` enum |
| `WorkshopSessionEffects.swift` | `WorkshopSessionEffects` protocol; `makeToolDispatcher`, `productionTurnExecutor` |
| `WorkshopSessionResultStore.swift` | `WorkshopSessionResultStore` struct; `path`, `save` |
| `WorkshopToolProfile.swift` | `WorkshopToolProfile` struct; `permits` |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

Checked Mac integration permission storage and mail read locations.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `MacIntegrationGates.swift` | `MacIntegrationGates`: `byTool` (the switch each dispatcher tool is gated on), `refusal` (the off switch's refusal, asked before any card by the chat gate and the Workshop executor) |
| `MacIntegrationPermissionStore.swift` | Saved integration consent under one checked, flocked authority; explicit operator off wins over Full Mac |
| `MacIntegrationPermissions.swift` | Integration identity, consent values and mutation provenance; persisted integration IDs are stable |
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
| `InboxItemRecord.swift` | Tolerant raw-row construction, declared source meaning and action/proactive interpretation on shared inbox values; latest stable-card identity and OwnerAttentionPolicy projection |
| `LiveNotificationInbox.swift` | Single physical-line reader and writer for inbox cards; actor mutations and caller-owned row edits share retention and archive-before-rewrite under the inbox flock |
| `NotificationInbox.swift` | `NotificationInboxClock` |
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
| `PartHost.swift` | rehearsal shares one lazy helper across fixtures and decision replays; `Parts.rehearse`, `ToolHost`: a part's declared actions, files by reach and primitives through the broker; nested part calls are programs, retaining preview and their typed result while child effects stay suppressed; projection execution refuses host effects, model tool thinking retains this same restricted host and passes its native effect envelope through unchanged; `Parts.rehearse`, `ToolHost`: a part's declared actions and the exact shared capability action map and primitives through the broker |
| `Parts+Compile.swift` | `Parts.Compiling`: the night's keep moment for one nominated practice, bound around that agent's own turn; every save in that turn is this practice's (one ability and its revisions, its code making the practice's calls; any other save there is refused), staged only (never kept in the act, Full Mac included), its fixtures are the recorded tape's calls with the input they gives each example, its manifest carries `compiled` and its origin the examples' steer; `prepareKeep` keeps a compiled version only once its tape replayed |
| `Parts+Creation.swift` | Parts saving and rehearsal with staged-write settlement, inherited input contracts and ratcheting provenance; save receipts retain validate/proof/write milliseconds |
| `Parts+Execution.swift` | Parts pinned typed calls and pure faces, held runs and settlement; exact admission and dependency checks on every run |
| `Parts+HTTPWire.swift` | HTTP request and bounded response wire conversion for the existing resource broker |
| `Parts+Keeping.swift` | Parts keep eligibility and lifecycle mutations; one prepareKeep decision, sealed admission, owner-off authority, enable/disable/drop/rollback and locked registry mutation |
| `Parts+Migration.swift` | Parts bundled seed admission and retained tool/skill conversion; IDs, code, versions, digests and provenance remain intact |
| `Parts+Reading.swift` | Parts identity and row lookup, selected-version reads and bounded all-kind lists; built-in guidance and nearest-three unknown-id receipts |
| `Parts.swift` | Parts and PartError; one ability owner, shared store access and JSON values |
| `SecretRedactor.swift` | Exact-secret insertion and whole/stream redaction formats shared by one admitted execution |
| `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`: declared model/network/program/secret reach, one raw receive for fetch and held connections, programs over stdio, keyring secrets inserted at the edge and reply redaction (stream-piece boundaries may expose up to three leading secret bytes before the remainder is redacted), admitted-model thoughts (optional app tools and an existing routing surface, canonical tool-turn owner, same restricted host and caller limits) and fetch, the run's one screen watch and its hands; DNS handles remain owned until actual synchronous exit after cancellation/close, late results open nothing, and fetch timeout reports an unknown outcome; one arrival buffer per held thing that program and network reads take (one text-or-base64 shape), each arrival on which posts a resident ability's `held` signal; no file executor |
<!-- END GENERATED BLUEPRINT -->

### Chrome Relay Core

Directory: `Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/ -->
| File | Owns |
|---|---|
| `ChromeHostIdentity.swift` | `ChromeHostIdentity`: native messaging browser/relay process identity, listener token location and filesystem identity, allowed-origin checks and private refusal evidence |
| `ChromeSocketIdentity.swift` | `ChromeSocketIdentity`: kernel audit-token peer validation against the running caller's designated signer; unsigned identity is refused |
| `NativeMessagingFraming.swift` | `NativeMessagingFramer`: bounded little-endian JSON framing shared by Chrome pipes and private relay socket, with exact fragmented reads |
<!-- END GENERATED BLUEPRINT -->

### Task Ledger CLI

Directory: `Modules/NativeAgentCore/Sources/TaskLedgerCLI/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TaskLedgerCLI/ -->
| File | Owns |
|---|---|
| `main.swift` | `TaskLedgerCLI`: explicit ledger append/claim/list commands, option parsing and shared or explicitly overridden data-root resolution |
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
| `ApprovalRequest.swift` | ApprovalRequest: shared consent outcomes, execution evidence and exact chat provenance; approval authority remains Mac-owned |
| `BridgeMessage.swift` | `BridgeMessage`: shared signed device envelope, canonical HMAC body, exact reply correlation and inner approval signature validation |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver` enum; `typeAndMime`, `fileByteLimit`, `submittingSpeech` keeps composer wording on its utterances |
| `ChatPacedReveal.swift` | `ChatStreamPacer` and shared streaming views: paragraph-aware paced reveal, edge fade and settle crossfade for Mac/iPhone |
| `ChatRichContentParser.swift` | `ChatRichContentParser`: shared fence, list and sanitized inline grammar; `ChatContentCache`: bounded content-keyed FIFO storage |
| `CloudKitDeviceTransport+Messages.swift` | Signed message delivery, serialized drains and delivery cursor admission |
| `CloudKitDeviceTransport+PairingStatus.swift` | Pairing, presence and serialized status publication |
| `CloudKitDeviceTransport+Pull.swift` | Cursor-paginated record pulls and retained traversal checkpoints |
| `CloudKitDeviceTransport+Retention.swift` | Bounded record retention and per-record-family sweep cursors |
| `CloudKitDeviceTransport+Subscriptions.swift` | Silent notification subscriptions and registration reconciliation |
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport` class; `observeAccountFailures`, `observeIncoming` (returns subscription readiness), `isChatNotification`, `shouldPersistPullCursor`, `resignalMessage` (original signed envelope; existing query clock renewed) |
| `ColorHex.swift` | `NativeAgentSpacing`, `NativeAgentRadius`, `HazeColor`, `HazeMood` and `Color.init(hex:)`: shared geometry and appearance values |
| `CompactDurationFormatter.swift` | `CompactDurationFormatter.string`: shared rounded compact duration wording with finite/range admission |
| `ContinuationOnce.swift` | `ContinuationOnce`: one retained first outcome for single-consumer waits; winning resolution runs cancellation before any continuation resumes; CloudKit races preserve typed failures and caller-owned task policies |
| `ConversationModels.swift` | Shared conversations and `ChatThreadKind` declarations, navigation, tool evidence, transcripts, attachments and oriented thumbnail decoding; engine-resolved display titles default to title; Mac-owned navigation retains pin/anchor order, thread kind and exact helper owner |
| `DetachedCloudKitTimeoutRace.swift` | Detached CloudKit race and diagnostic `withCKTimeout` optional-result policy |
| `DeviceApprovalSignature.swift` | `DeviceApprovalSignature`: Ed25519 device identity and canonical approval-body verification; outer HMAC remains required |
| `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |
| `DeviceEventIdentity.swift` | Stable cross-device notification/collapse identity and shared authenticated notification category construction |
| `DeviceSyncTransport.swift` | Shared device-sync role/message codecs, account/recovery outcomes and transport resolution |
| `HazeView.swift` | `HazeView`: shared radial haze rig, overlap cap, weight and tempo; native geometry, lifecycle and phone tab clock |
| `ICloudBridgeConstants.swift` | `NativeAgentICloudBridgeConstants`: shared KVS/Drive wire namespace, mobile source keys and configured background task identifiers |
| `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.normalized`: canonical signed phone file-access modes; malformed metadata never becomes permissive |
| `InboxAction.swift` | Shared signed iPhone-to-Mac inbox envelope; Codable wire schema for both transports and platforms |
| `InboxDigestGroupProjection.swift` | `InboxDigestGroups`: read-only platform inbox adapter preferring structured groups over legacy prose |
| `InboxWireModels.swift` | Shared inbox rows and `InboxActionVocabulary`: action normalization and native operation set, with broader signed-wire recognition; `view` remains phone-local |
| `InlineInteraction.swift` | `InlineInteraction`: durable card kind/state/scope, continuation and outcome contract shared by dispatch, transcript and renderers |
| `InlineInteractionDescriptor.swift` | Registry-supplied control/location bindings and shared `InlineCardField` connector vocabulary for Mac and phone |
| `InspectorModels.swift` | Shared content-free Inspector turn summaries and mobile tool catalog rows with compatible summary decoding |
| `JSONByteScanner.swift` | Lexical JSON string, value, object-member and array-element byte spans; callers own validation and duplicate-key policy |
| `KnowledgeGraphEdgeWireSnapshot.swift` | `KnowledgeGraphEdgeWireSnapshot`: shared immutable edge decoding; platform wrappers retain UI identity and extra fields |
| `LatestRead.swift` | `LatestRead`: one owner's published snapshot; reads return their own result and publication moves forward only; `refreshDraft` applies only the newest-started form refresh; cancellation never publishes or advances the boundary; reads inherit their owner's actor isolation and synchronous writes publish on that owner |
| `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: shared Codable/Hashable policy snapshot, decoding/defaults; TrustCenter retains policy authority |
| `MemoryModels.swift` | Shared memory rows and proposals with compatible field decoding and persisted proposal key spellings |
| `MobileAppSettings.swift` | `MobileAppSetting`: phone projection of Mac settings registry controls and single-value update spellings |
| `MobileConnectorSnapshot.swift` | MobileConnectorSnapshot: credential-free connector state and available phone controls |
| `MobileDeskSnapshot.swift` | `DeskKind`, `DeskStatus`, `WorkOverview` and mobile Desk values: bounded canonical-identity reading copies, owner counts and execution movement; no second decision owner |
| `MobileHelpers.swift` | Helper row/edit revisions, shared agent summaries and read-only other-room exchange rows/chronological placement for Mac and phone |
| `MobileSchedulerSnapshot.swift` | `MobileSchedulerSnapshot` struct |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup` enum; `groups`; declares live phone snapshot inputs only: unread promotion_candidates.json is retired; training_proposals.json retains its active phone readers |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | Shared `TrustWorkshopPolicy` value and closed `MobileTrustAction` requests; TrustCenter retains policy authority |
| `MobileWorkActivity.swift` | `Experience` and `ObligationPhase` value contracts shared by owners and phone renderers; `MobileWorkActivity` and its revisioned experience snapshot |
| `ModuleLogging.swift` | `ModuleLog`: shared public diagnostic formatting and credential scrubbing; `nativeLog` retains the Shared category |
| `NativeTimestampFormat.swift` | Locked wire timestamp formats and Foundation parsers; explicit precision, UTC suffixes and calendar-day zones |
| `OrganismLivingStatus.swift` | `OrganismLivingStatusFile`: rebuildable shared body/status transport values with explicit unavailable boundaries; cognition remains Mac-owned |
| `PartFace.swift` | Shared Codable/Sendable PartCallResult and PartCallError, typed PartFace sections/rows, and PartFaceSnapshot with native ready/unavailable/failed/error/owed fields for Mac and iPhone |
| `PersonaModels.swift` | Shared personality traits, saved profile and identity-neutral display names; PersonaEngine owns canonical storage |
| `PhoneConnection.swift` | `NAPhoneConnection`: one shared assessment of pairing, transport and accepted exchange, naming the first unmet fact and its repair owner |
| `PhoneMacControlAction.swift` | Executable phone Mac-control methods and native paths shared by mobile senders and Mac dispatch; preserves the volume wire envelope |
| `PhonePlaceEvent.swift` | `PhonePlaceEvent`: authenticated cross-device place observations |
| `PhoneRequest.swift` | `PhoneRequest` and `PhoneRequestResult`: typed signed request/result bodies over the existing device chat lane |
| `ProviderAuthStatus.swift` | `ProviderAuthStatus`: credential-proof presentation, compatibility decoder and bounded metadata projection; providers retain dispatch eligibility authority |
| `ProviderCatalogStatus.swift` | `NAProviderCatalogStatusCodec`: credential-free provider/model/surface metadata over existing device status transport |
| `ProviderCatalogWireModels.swift` | Shared provider connections with compatible decoding, model capabilities, typed check results, reasoning-choice values/table/filter and surface-group vocabulary; callers own their default reasoning policies |
| `RunKindVocabulary.swift` | Shared safe display names and recognized symbols for extensible run-kind wire values; unknown symbols stay platform-owned |
| `RunRecord.swift` | RunRecord: shared Codable run-history fields |
| `RuntimeHealth.swift` | RuntimeHealth: shared runtime liveness metadata; lifecycle facts remain with their owners |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope`: shared seal/open wire contract for authenticated secret actions |
| `SpeechUtterance.swift` | `SpeechUtterance`: original audio/recognition evidence, submitted wording and compact uncertainty projection without rewriting hypotheses |
| `StoreReloadDebouncer.swift` | `StoreReloadDebouncer`: visibility-gated trailing-edge reloads with one in flight; exclusion lasts until actual reload exit; `Timer` owns cancellable delays for reloads, source invalidations, context and cognition |
| `SurfaceLayout.swift` | `SurfaceLayout` struct: the layout document's shape, vocabulary and seed; `addMissing`, `shown`, `arranged` for the Mac and the phone; `QuietToolPage` owns the shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases, the door's page resolution (`step`, `place`: alias, `page/item` split, home rooms) and derives accepted part face pages from those definitions |
| `SystemToast.swift` | `SystemToast` and `SystemToastCenter`: shared replace-by-ID notice values, severity defaults, queue and owned dismissal timers; each platform owns its queue instance |
| `ToolActivityPresentation.swift` | `ToolActivityPresentation`: shared card/progress/approval copy from bounded call names; tool IDs and execution arguments stay unchanged |
| `TurnSecretRedactor.swift` | `TurnSecretRedactor`: credential-name/token recognition and shared presentation/trace scrubbing; callers own size bounds |
| `UserDisplayFormatters.swift` | Shared timestamp parsing/cache, lexical home-relative path display and compact duration presentation through `CompactDurationFormatter` |
| `VolumeIO.swift` | The one owner of blocking file work that can touch a File Provider or network volume (iCloud Drive): one serial queue off the cooperative pool, awaited by its callers |
| `WorkshopTaskRecord.swift` | WorkshopTaskRecord: shared task wire row with compatible field decoding; the Mac supplies approval authority |
<!-- END GENERATED BLUEPRINT -->

## Parts

Directory: `Resources/abilities/`

Every bundled JavaScript part owns its row. Existing Swift owners retain
native effects, consent and settlement.

<!-- BEGIN GENERATED BLUEPRINT: Resources/abilities/ -->
| File | Owns |
|---|---|
| `backup-cadence.js` | tool `backup-cadence`: Choose off-disk backup freshness and identity-change cadence from native timestamps. |
| `crew-instructions.js` | tool `crew-instructions`: Prepare crew briefs, synthesis messages and digest bounds from native admitted worker facts. |
| `desk-notify.js` | tool `desk-notify`: My Desk interruption policy: changed work, earned nudges, quiet-window drift and exact deadlines. |
| `desktop-courier.js` | tool `desktop-courier`: Prepare the desktop courier's reply address and constrained tool-turn procedure. |
| `diagnostic-narration.js` | tool `diagnostic-narration`: Narrate checked Desk and Activity facts. |
| `due-reminders.js` | tool `due-reminders`: Read reminders in two named parts: today (local day, earliest first) and overdue (before today, oldest first). |
| `growth-week.js` | tool `growth-week`: My seven-day growth readout, from frozen native REM timeline evidence. |
| `mac-watch-catalog.js` | tool `mac-watch-catalog`: Return inactive Mail, Calendar and Reminders watch recipes. |
| `mail-recovery.js` | tool `mail-recovery`: Recovery wording for structured mail failure reasons. |
| `maintenance-assistance.js` | tool `maintenance-assistance`: Group and explain checked Doctor asks, saved storage plans and Speech Recognition permission facts. |
| `make-generated.js` | tool `make-generated`: Compose raw generated images with make.add, preserving their prompt, model and requested ref, and report each registration failure. |
| `make-title.js` | tool `make-title`: The title of a Make preview, from its decoded HTML title, prompt or filename. |
| `messages-recovery.js` | tool `messages-recovery`: Recovery wording for structured messages failure reasons. |
| `music-library.js` | tool `music-library`: Read Music playback state and observed timing; page typed playlists and sorted, filtered library/search results with totals, without opening Music. |
| `music.js` | tool `music`: Play, pause, stop or skip Music; bound play with seconds through the native player call, resolve an exact library track, and read playback through music-library. |
| `native-morning-brief.js` | ability `native-morning-brief`: Compose the morning brief and its inbox card from checked native source packets. |
| `notes-recovery.js` | tool `notes-recovery`: Recovery wording for structured notes failure reasons. |
| `notice.js` | tool `notice`: Notice a scriptable app arriving; offer once per bundle and version. |
| `presentation-copy.js` | tool `presentation-copy`: My page subtitles, activity phrases and automated conversation titles, over sanitized native presentation facts. |
| `research-lab.js` | tool `research-lab`: Select sources and compose a Research Lab brief from the native SearXNG evidence packet. |
| `studio-canon.js` | tool `studio-canon`: Propose canon tending from neutral recurrence, production-pull and membership facts, with reasons and the next silence deadline. |
| `studio-intake.js` | tool `studio-intake`: Order unanswered artifact consults from complete corrected history, and phrase invitations to work already in reach. |
| `telegram-commands.js` | ability `telegram-commands`: My Telegram command menu, help, and memory-command reply words. |
| `telegram-model-picker.js` | ability `telegram-model-picker`: Interpret Telegram model requests and draw checked model menus. |
| `telegram-progress.js` | ability `telegram-progress`: My Telegram progress and status voice over sanitized native lifecycle facts. |
| `today-readout.js` | tool `today-readout`: Compose my Today rows from frozen, provenance-checked sources. |
| `turn-continuation.js` | ability `turn-continuation`: Compose a Desk continuation cue with native checkpoint evidence slots. |
| `turn.js` | turn `turn`: The stem hands step one event at a time (message, model, result, observation, resumed) and runs the effects it returns (model.call, app, reply.stream, reply.end, after). |
| `weather.js` | tool `weather`: Read current weather and daily temperature high/low, rain chance, wind, sunrise and sunset from Open-Meteo. |
| `weekly-outcomes.js` | tool `weekly-outcomes`: Compose the weekly Workshop outcome digest from complete native-normalized samples. |
| `workspace-readout.js` | tool `workspace-readout`: Compose Today, Music and helper workspace faces from native read facts, selecting only bound item and action keys. |
<!-- END GENERATED BLUEPRINT -->

## iOS Companion Map

### Companion

Directory: `iOS/NativeAgentMobile/Sources/`

<!-- BEGIN GENERATED BLUEPRINT: iOS/NativeAgentMobile/Sources/ -->
| File | Owns |
|---|---|
| `AdvancedPresentation.swift` | `View`: `mobileReadingScreen` |
| `AdvancedStore.swift` | Shared health and runs refresh loading/errors |
| `AdvancedView.swift` | More navigation reads the pairing-owned surface layout and composes Status and Runs |
| `AliveCards.swift` | Card surfaces, sections, rows and row press presentation |
| `AliveConnection.swift` | Shared Mac connection wording, pairing guidance and snapshot freshness |
| `AliveControls.swift` | Status lights, actions, search, glass controls and haze swatches |
| `AlivePage.swift` | Native list page, headers, list environment and scroll-edge fades |
| `AlivePalette.swift` | Phone haze colours, contrast tokens and page metrics |
| `AliveRoom.swift` | Phone room and chat-driven mood presenting the shared `HazeView` |
| `AliveWords.swift` | Count, identifier and timestamp wording for phone screens |
| `ApprovalPayloadView.swift` | Readable approval payload fields and exact Mac-sent details |
| `ApprovalsStore.swift` | Signed approval decisions, refresh state and pending-arrival notifications |
| `ApprovalsView.swift` | Approval list, cards and history read the shared sync projection, including Mac-resolved decision and time |
| `ChatBubbleViews.swift` | Reply and attachment rendering, inline approvals and tool activity |
| `ChatModels.swift` | Chat values, runtime controls and Mac transcript projection onto ChatMessage |
| `ChatPresentation.swift` | Chat controls and picker presentation; model controls read the shared `iCloudSyncEngine.surfaceModels` projection |
| `ChatView+Choices.swift` | Mac-owned model configuration and chat option controls on ChatView |
| `ChatView+Composer.swift` | Session-bound drafts, dictation controls and attachment preparation on ChatView |
| `ChatView+ConversationEvents.swift` | Mounted reply observers, foreground refresh and session-bound dictation callbacks on ChatView |
| `ChatView+Notices.swift` | One condition-bound banner lane for chat, sync and voice notices |
| `ChatView+Thread.swift` | Transcript rendering, scrolling and SwiftUI hooks on ChatView |
| `ChatView.swift` | Conversation state, session navigation and anchor reconciliation; composes thread, composer, choices and notices |
| `DeskItemDetail.swift` | Desk item detail, retained note submission and new-item form |
| `DeskStatus.swift` | Desk and task status marks, status words and kind words |
| `DeskView.swift` | Shared Desk board rows and reading copies; selected handles resolve current fields or an unavailable state |
| `InboxDetailSheet.swift` | ID-resolved inbox detail and related digest navigation |
| `InboxModels.swift` | Phone rendering and bounded notification planning over shared inbox values; status and source meaning are supplied by the Mac |
| `InboxStore.swift` | Inbox refresh/actions, known arrivals and local notification policy |
| `InboxView.swift` | Inbox list, card rows and reading navigation use the shared sync projection |
| `KnowledgeGraphView.swift` | Graph presentation and ID-resolved entity details/neighbors from the shared typed graph; local search/loading state |
| `MacActionReceipts.swift` | Mac Tools receipt ledger, approval reconciliation and receipt rows |
| `MacBridgeClient.swift` | Signed iCloud chat transport, pairing and connection observation |
| `MacToolsPresentation.swift` | Policy hints for shared executable phone actions, volume target wording, notification feedback and Spotlight results |
| `MacToolsView.swift` | Mac controls use PhoneMacControlAction and the shared Trust snapshot; receipts live in MacActionReceipts |
| `MemoryListView.swift` | Local memory search, result rows and deletion confirmation |
| `MemoryStore.swift` | Memory refresh, deletion and proposal decision state |
| `MemoryView.swift` | Memory page and proposal rows read the shared sync projection; composes mutation and local search owners |
| `MobileAgentsView.swift` | Agent list and ID-resolved conversation from the sync owner's shared readbacks; local message drafts and submission state |
| `MobileAppIntents.swift` | `MobileAskIntent`: `perform` |
| `MobileConnectorRow.swift` | Connector destination, health presentation and rows share the sync projection; connector receipts update it |
| `MobileHelpersView.swift` | Helper list and ID-resolved details from the sync owner; local editable drafts and submission state |
| `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |
| `MobileInteractionCard.swift` | Inline interaction fields, setup routing and signed answers |
| `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
| `MobileSchedulerView.swift` | `MobileSchedulerView` struct |
| `MobileSearchIndex.swift` | Actor-owned local row search shared by memory, tools and knowledge graph |
| `MobileTrustEditor.swift` | Trust destination and editor share the sync projection; displays the engine-resolved preset and effective permission level |
| `NativeAgentDesign.swift` | `View`: `appShimmer` |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PersonalityDetailView.swift` | Personality destination, snapshot freshness and trait presentation read the shared sync projection through SettingsStore |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities`; Live Activities and the thinking light share Mac-projected activity state and Experience correlation evidence; no local turn-status persistence or bridge-event reducer |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `RunsLogView.swift` | Run history, rows and complete run detail |
| `SettingsViewFull.swift` | Device settings, shared SettingsStore refresh/loading and snapshot availability presentation |
| `SkillLifecycleView.swift` | Shared typed skill catalog renderer, local filters and ID-resolved details; SkillsToolsView owns catalog refresh/loading |
| `SkillsToolsView.swift` | Combined catalog refresh/loading/error owner; tool renderer reads shared sync catalog and retains local search state |
| `StatusDetailView.swift` | Phone, Mac and organism status readback |
| `TelegramView.swift` | `TelegramView` struct; reads the shared revision-ordered Telegram projection |
| `TurnInspectorView.swift` | Turn summary presentation reads the shared sync projection directly |
| `WorkshopView.swift` | Shared task rows, engine-projected actionable approval state and ID-resolved details; local submission/loading state |
| `iCloudBridge+CloudKit.swift` | CloudKit setup, pairing acquisition, presence and coalesced drains on iCloudBridge |
| `iCloudBridge+Drive.swift` | Drive acquisition, outbox scanning, consumed-reply archive retention and deadline-bound staged publication on iCloudBridge |
| `iCloudBridge.swift` | Authenticated admission and delivery ownership; `recordMacConfirmation`, `clearMacConfirmationForConnectionRepair`; pairing-scoped record-identity nudges until authenticated Mac acceptance or the existing chat/action/place owner retires delivery; place acceptance is checkpointed by `PhonePlaces` before nudges stop; restored owners loaded before pruning |
| `iCloudSyncEngine+Actions.swift` | Signed action submission, send serialization and connection-repair admission; response verification, correlation, settlement and bounded arrival waiting |
| `iCloudSyncEngine+Commands.swift` | Subject commands and receipt adoption through the signed action transaction |
| `iCloudSyncEngine+SnapshotReading.swift` | Snapshot replica freshness, bounded coordinated byte reads, tolerant decoding and read-health reporting on iCloudSyncEngine |
| `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot` owns both file and action receipt adoption, retaining newer Mac helper revisions; `refreshHelpersSnapshot`, `applySchedulerSnapshot`, `refreshSchedulerSnapshot`, `applyProviderState`; Mac revisions order approvals, inbox and memory snapshots against per-record readbacks/removals until acknowledged; provider snapshots and action receipts use the checked routing revision in the same shared surface-model projection; one typed skill/tool/graph decode owner through full, catalog and graph refreshes; Advanced group delivery refreshes that graph projection for its open list/detail; connector and Telegram receipts share snapshot ordering |
| `iCloudSyncEngine+Transactions.swift` | Pending signed envelopes, pairing reconciliation, response mailbox recovery and deadline-bound transaction persistence with striped locking and exact-byte readback |
| `iCloudSyncEngine+Transcripts.swift` | PublishedTranscript projection, generation-ordered reconciliation and history adoption; retained local rows, compatible fuller text and non-image attachment bytes share one owner |
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
    {"id": "retired-ios-provider-routing", "files": ["iOS/NativeAgentMobile/Sources/ProviderSettingsView.swift"], "forbiddenPatterns": ["daemon /v1|daemon/native_agentd\\.py"], "caseInsensitive": true, "message": "iOS provider comments must point to Swift provider handlers"},
    {"id": "retired-ios-http-runtime", "files": ["iOS/NativeAgentMobile/Sources/MacBridgeClient.swift"], "forbiddenPatterns": ["daemon HTTP server|Mac daemon returned HTTP"], "caseInsensitive": true, "message": "iOS bridge facade must not describe a live daemon HTTP runtime"},
    {"id": "retired-skill-manifest-runtime", "files": ["docs/skill_manifest_spec.md"], "forbiddenPatterns": ["(?i)\\bdaemon\\b|native_agentd\\.py|daemon's venv Python|Daemon-Side"], "caseInsensitive": true, "message": "skill manifest spec must describe the Swift runtime rather than daemon-owned skills"},
    {"id": "retired-release-migration-instructions", "files": ["docs/release-migration.md"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765|native_agentd\\.py|Verify daemon started|Bundled Python hash verification"], "caseInsensitive": true, "message": "release migration docs must not prescribe retired daemon/Python runtime checks"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/slack.json", "docs/example_manifests/gmail.json", "docs/example_manifests/google_calendar.json", "docs/example_manifests/notion.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "retired-core-machinery", "roots": ["Modules/NativeAgentCore/Sources"], "forbidden": ["OperationalTransitionShadow", "personal_trace_shadow", "WorkshopTerminalOutcomeInterpreter"]},
    {"id": "retired-adaptive-effort", "files": ["Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestration+ToolLoop.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Factories.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift", "Modules/NativeAgentCore/Sources/AppToolRuntime/AppChatToolDispatcher.swift", "Sources/NativeAgentApp/AppModel.swift", "Modules/NativeAgentCore/Sources/EngineRuntime/EngineTurns.swift", "Sources/NativeAgentApp/ChatView+SlashCommands.swift", "Sources/NativeAgentApp/AppApprovalTransactionEffects.swift", "Modules/NativeAgentCore/Sources/ApprovalTransactions/ApprovalTransactionCoordinator.swift"], "forbiddenPatterns": ["adaptiveReasoningEffort"], "caseInsensitive": true},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift"], "required": ["checkedRouteAdmission"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/TurnContextPreparation.swift"], "required": ["provider.admissionReused"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/WorkshopExecution/WorkshopExecution+PlannerLLM.swift"], "required": ["checkedRoutingSnapshot"], "forbidden": ["computeModelPreferences"]},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/CognitiveSubstrate/CognitiveSubstrate+Maintenance.swift"], "required": ["persistMaintenanceTransition"], "forbidden": ["try await persistSnapshot(", "try await persistThoughtSeedFamily(", "try await recordReceiptChecked("]},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/TurnTrace/TurnTraceBus.swift"], "required": ["_FIFO<TurnTraceEvent>", "persistLane", "capacity: 4096"], "forbidden": []},
    {"id": "core-does-not-import-app", "roots": ["Modules/NativeAgentCore/Sources"], "forbiddenImports": ["NativeAgentApp"]},
    {
      "id": "app-is-a-platform-door",
      "roots": ["Sources/NativeAgentApp"],
      "requiredAnyImports": ["SwiftUI", "AppKit"],
      "allowlist": {
        "Sources/NativeAgentApp/InboxCardActions.swift": "Area 4 — approval transaction app effects and presentation assembly",
        "Sources/NativeAgentApp/ActivityWatchController.swift": "App presentation/platform integration — area number unmapped",
        "Sources/NativeAgentApp/AppApprovalTransactionEffects.swift": "Trust and shared model projections — area number unmapped",
        "Sources/NativeAgentApp/AppConnectorPlatform.swift": "Area 1 composition handoff — live connector/integration bindings; policy and execution in core",
        "Sources/NativeAgentApp/AppQuietLowerOnly.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietSettingsHost.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietToolHost+Mind.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppQuietToolHost.swift": "Chat and surface integration — area number unmapped",
        "Sources/NativeAgentApp/AppToolPlatform.swift": "Area 1 composition handoff — live executor/browser/Doctor bindings",
        "Sources/NativeAgentApp/MemoryAppIntents.swift": "MemoryV2 — area number unmapped",
        "Sources/NativeAgentApp/Models/ImprovementNextGenModels.swift": "Trust and shared model projections — area number unmapped",
        "Sources/NativeAgentApp/NativeAgentIntents.swift": "App presentation/platform integration — area number unmapped",
        "Sources/NativeAgentApp/SensesAssembly.swift": "Area 1 composition handoff — live sense runner/provenance bindings",
        "Sources/NativeAgentApp/AppModel+ChatActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+ChatSessions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+GraphCapabilityActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+HealthEmbeddings.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+MemoryActions.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+Refresh.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own",
        "Sources/NativeAgentApp/AppModel+RoutingWorkflowMCP.swift": "AppModel extension — the app's own observable model, calling the engine; no view or platform API of its own"
      },
      "message": "Engine logic belongs in NativeAgentCore; the app retains views and platform adapters."
    }
  ]
}
```
