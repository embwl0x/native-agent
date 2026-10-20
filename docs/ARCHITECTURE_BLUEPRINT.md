# NativeAgent Architecture Blueprint

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

Source-owner map for the running app. Start with [NORTHSTAR](NORTHSTAR.md)
for intent and the [documentation guide](README.md) for task-specific reading.
The tables name current declarations and selected entry points, not exhaustive
APIs. Implementation details belong beside their source owners.

## First Principle

One brain, many doors. `NativeAgent.app` hosts the runtime in-process.
`EngineRuntime/NativeAgentEngine` composes chat clients, tool dispatch and the
resident services from a data root and platform ports. `NativeAgentEnginePorts+App`
binds those ports to the Mac app and constructs the live engine.
`ChatTurnRuntime` owns turn execution; the app and remote surfaces reach that
engine through their adapters.

## Runtime Shape

| Location | Responsibility |
|---|---|
| `Sources/NativeAgentApp/` | SwiftUI app, Mac platform adapters and live engine assembly |
| `Sources/NativeAgentSenseHost/` | Shared isolated JavaScriptCore executor for senses, tools, skills and ad hoc scripts; app supplies source/material and owns supervision |
| `Modules/NativeAgentCore/Sources/` | Engine, turn execution, domain stores, tools and policy |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/ProcessPipeDrain.swift` | One nonblocking subprocess pipe reader shared by provider transport and Mac execution; MacControl translates setup failures at its execution boundary |
| `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | Shared completion route and requester identity; lifecycle decision projection for recovery, journal retention and reporting; exact answer admission makes let_go terminal for lifecycle and direct route-journal sends |
| `Modules/NativeAgentShared/Sources/NativeAgentShared/` | Shared Mac/iPhone declarations |
| `iOS/NativeAgentMobile/Sources/` | iPhone UI and sync adapters |

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

| File | Responsibility |
|---|---|
| `Sources/NativeAgentSenseHost/main.swift` | JSON-line entry loop and bundled SDK loading for the shared JavaScript executor |
| `Sources/NativeAgentSenseHost/PlugIO.swift` | Bounded JSON-line transport and active-reply stall window |
| `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift` | Persistent sense/resident-part contexts with fresh frozen input per call, synchronous API, shared Swift fragment-redaction binding, page/news checks, JSC execution watchdog |
| `Modules/NativeAgentCore/Sources/Senses/SenseHostLocator.swift` | Installed helper address |
| `Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift` | Deny-default Seatbelt reach, immutable private stores and exact-IP network fence |

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
adapters. `ChatSessionWork` and `Transcripts` contain session/history storage;
`ContextFlow`, `MemoryV2`, `PersonaEngine` and `Cognition` supply their respective
context and state. Their file maps below identify the owning declarations.

## Tool Dispatcher Map

`app` is the single always-on model tool. `app {}` opens home, where Agent left
off. `page`, `item`, `find` and `action` reach the app's pages, saved places,
settings and actions. `AppToolExecutor+AppDoor` owns that interface;
`AppActionRegistry` defines `AppAction` and `AppActions`, including admitted parts' unclaimed `face.action` ids.
At executor assembly it supplies `ToolRegistry.AppActionBinding`: executor, fixed input,
renames, descriptor, saved Trust keys, lifecycle and argument-dependent read conditions.
TrustCenter, the door and receipts consume that binding; native descriptors also own
inventory membership, categories and authored-name reservations. Declared lifecycle writes refuse peer steering before
dispatch; legacy routes resolve from each action's declared tool and fixed input.
`AbilityStore` owns `data/abilities/`: current, previous and proposed files plus
run accounting in `state.json`. All kinds re-read keep authority under its
publication lock before any publication write, including bundled displacement
and sense restoration, through the engine-bound checked Trust reader; owner-off
authority remains separate. Every run records ok/error/refused/cut/network;
a failed live part operation owes repair through Experiences even after a clean run.
The retained source supplies its authoring call; successful operation or keeping
its repair settles it, while reads and restarts do not.
There is no automatic swap-back or notification-only healing. Explicit rollback
keeps its existing authority checks. Sense lifecycle saves retain store-owned
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
Unregistered non-folded actions require approval. Folded actions keep approval on
their underlying call. Domain capabilities and saved legacy Trust keys remain
TrustCenter policy.
`AgentWorkspace` supplies home's navigation and retained places.
Home labels its snapshot time and each section's source coverage; the turn glance
and inner capsule label their snapshot time and omitted live-state coverage.

`AppScriptRunner` adapts the app door to the shared `OwnedProgramRunner`.
`AppActions` owns dependency contract projection and frozen legacy pin identities;
argument/result schemas and revision are pinned independently of discovery prose.
Admitted authored tools are scriptable actions, including routine dependencies;
their calls retain ordinary skill checks and capture validation substitutes fixtures.
Their pinned action contract supplies the routine's read-before-act knowledge;
execution does not require a diagnostics-page version. Skill run accepts input
and its legacy args spelling; capture input errors report an argument remedy.
Script and authored-tool app calls re-enter the turn's ordinary dispatch chain;
tool reach (`reach` or `permissions`) constrains `host.network`, `host.apps.call`,
`host.model.call` and `host.fetch`. `host.files/calendar/reminders/contacts` are prelude aliases
for existing folded door actions with their named arguments and results; their reach expands
to pinned door dependencies (file reads for read reach, mutations for write reach).
File paths, session restrictions, protected stores and the Full Mac write boundary
belong to those ordinary file actions; no file executor or classifier lives in the primitive broker.
Model thoughts use the admitted turn or wake run's exact client and routing tuple, without persona or
turn output budgets; `ability:<id>:<purpose>[:<signal>]` goes through ordinary model-call telemetry, never effect admission.
Tools and skills expose `host.state.get/set` through the same serialized notebook owner as senses,
keyed by part id, with scratch state during proof/preview and separate lifecycle accounting.
ToolExecution depends on ProviderRouting for that telemetry's independent request shape.
Fetch credentials stay in Swift: the dispatcher reuses connector credential readers,
TrustCenter's connector API host registry (AgentMail's configured host), and an ephemeral
session with no cookie/credential storage. Keyless HTTP uses the broker's existing
NWConnection pinned to its checked address, TLS server name and platform HTTP message
parsing; it never resolves again in URLSession. Both return redirects without following them.
Fetch uses its own policy name `fetch.<connector>` or `fetch.keyless`: GET carries
`connector_read:<id>`, everything else `connector_write:<id>`; keyless carries `network_public`.
Explicit capability overrides use the existing toolAutonomy store alongside tool names.
Every effect re-enters the ordinary gate chain; no Swift tool's admission is mirrored.
EventKit remains in LocalPIMConnectorActions/LocalPIMStore and Contacts in MacContactsExecutor.
Sandboxed authored execution has no blanket Full Mac requirement; each primitive uses its effect's ordinary gate.
Human card waits pause the execution clocks; ordinary host work stays under the watchdog.
Every kind renews its progress window on a host reply; real provider bytes and network
replies renew the same window during host work. Stalled receives still expire.
Its envelope uses the dispatcher's authorable-name predicate, registered with the app policies, so an ability file cannot reclassify a Swift built-in.
The part header owns structured reach; tool records consume its projected permissions rather than treating reach itself as a list.
Primitive approval replay retains the originating broker through the existing host-call
subscription, rechecks the selected version and executes only the approved call.
The broker owns only model.call, fetch, raw network primitives and the run's screen watch (its frames are reads inside the admitted watch: no admission and no ledger row each; the watch leaves one receipt); ToolHost retains
declared app targets and the shared SystemAppleScriptAdapter call.
Primitive results and a tool's `returned` value are opaque data; outcome and effect classification reads only the receipt envelope. MacControl's `SystemAppleScriptAdapter` is the single in-process OSA
execution owner for authored app calls and the built-in `MacAppleScriptBridge`:
one serial `NativeAgent.AppleScript` queue that holds every OSA wait off the
cooperative pool, URL-bound process resolution, Automation preflight, native
send/active callbacks, each event's own declared reply timeout, an explicit
cancellation flag and error mapping live there;
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

Native executors in `ChatToolRuntime` and `AppToolRuntime` sit behind the app
interface. Their implementation names are not additional model tools.
`ToolNameAliases` maps folded names to actions and produces translated `app`
calls for refusals. `ChatOrchestration+ToolDispatch` rejects folded calls that
the provider request did not offer. Discovery is through `app`, without a
separate tool-loading workflow.

`tool.propose` files an authored tool; `tool.approve` activates it, after which
it is callable as `authored.<id>`. MCP actions use `mcp.<server>.<tool>`.
`AppActionRegistry`, `ToolNameAliases` and `MCPToolBridge` own those mappings.
`Research+CodexSearch` owns `web.search`: general queries use the bundled
Codex executable and the root's app-owned access-only ChatGPT child home;
category queries use SearXNG. Time ranges travel with the selected route.
Codex web tools are exposed directly, without a code-mode host. Codex failures
use the existing SearXNG route and retain their reason; completed empty searches
stay on their route. General-search discovery does
not depend on the optional category backend. Doctor probes the same executable
and credential home. `script/fetch_codex.sh` pins and verifies the executable
before Xcode embeds it; development and release signing seal it.

## Policy Chokepoints

`TrustCenter` and `SecurityCenter` retain effect-time authority. Full Mac uses
the operator's selected autonomy; macOS privacy-permission resets still require
explicit approval. `PeerTurnEffectPolicy` files the one card of a peer-steered turn: a turn an
untrusted agent started with its message; its first effect of any kind cards once, quoting the ask,
and the answer elevates the run (`PeerDataTaint.elevate`) so nothing more in it asks. Reading an
agent's words steers nothing (`markConsumed` latches nothing). `ApprovalTransactions` owns the
corresponding approval execution paths. Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns; ordinary Trust and domain checks still apply.

## State Ownership

`PersistenceCore` supplies shared JSON/JSONL I/O, durable writers, file locks,
change observation and data-root resolution. Domain stores remain with their
owners: authored part headers, lifecycle and run context in `AuthoredCapabilities`,
memory in `MemoryV2`, persona compilation in `PersonaEngine`, chat state
in `ChatSessionWork`/`Transcripts`, work in `Desk`, approvals in
`ApprovalInbox`, and the record of what happened in `Experiences`. The tables point to those implementations rather than
restating their storage formats.

## Background Loops

`BackgroundLoops/BackgroundLoopsManager` owns registration, execution and
status. Core `EngineLaunch` constructs the concrete loop registrations and
dependencies through installed native host effects. Each failure outcome refreshes one keyed Desk
finding; receipts and execution backoff remain with the scheduler.

## Source Map Convention

Each directory label is relative to the repository root; table filenames are
relative to that directory. Rows retain backticked Swift filenames for
`script/check_architecture_blueprint.swift`, which checks file existence and
coverage of its enforced file families. Declaration names are source locators;
consult the named owner for behavior and limits.

## App Source Map

### App

Directory: `Sources/NativeAgentApp/`

Hardened-runtime Mac builds require
`com.apple.security.personal-information.calendars=true`; without it, TCC
rejects Calendar permission prompts. All four Mac entitlement templates retain
this grant, and `script/verify_release_artifact.sh` checks the signed entitlement.

| File | Owns |
|---|---|
| `AdvancedPageComponents.swift` | `AdvancedEyebrow` struct |
| `AppApprovalTransactionEffects.swift` | `AppApprovalTransactionEffects` struct and `ApprovalTransactionCoordinator.app`: app-bound approval factory and live executor/platform bindings; external-send production composition lives in EngineRuntime; `AppApprovalTransactionEffects` struct; `ApprovalTransactionCoordinator.app`, external-send production bindings |
| `AppConnectorPlatform.swift` | live voice, notification, Mac control and device-sync bindings over core connector/integration policy and status owners; remaining composition belongs to Area 1; notification, EventKit and connector platform bindings over core policy/status owners |
| `AppDelegate+BackgroundTasks.swift` | `AppDelegate`: `registerBackgroundTaskHandlers` |
| `AppDelegate+Launch.swift` | `AppDelegate`: `applicationDidFinishLaunching`, `applicationShouldTerminateAfterLastWindowClosed`, `application` |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: `claimSingleAppInstance`, `presentSingleInstanceWedgedAlert`, `presentPublicReleaseDataRootError` |
| `AppModel+ChatActions.swift` | `AppModel`: `compactActiveChat`, `clearActiveChatMessages`, `regenerateAssistantMessage`; `NativeChatTurnOptions` struct |
| `AppModel+ChatSessions.swift` | `AppModel`: `loadChatState`, `refreshForSidebarItem`, `recordPanelRefresh` |
| `AppModel+ChatState.swift` | `AppModel`: `receiveMacScreenPreview`, `loadDetachedSessionMessages` |
| `AppModel+GraphCapabilityActions.swift` | `AppModel`: `searchGraph`, `refreshGraph`, `runResearchLab` |
| `AppModel+HealthEmbeddings.swift` | `AppModel`: `embeddingsStatus`, `toggleEmbeddingsBackend`, `setEmbeddingsMemoryMode` |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` reconnects checkpoint progress to the existing stream adapter and lifecycle; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory`, `consolidateMemory`, `runMemoryConsolidation`, `memoryHygieneReport` |
| `AppModel+PersonalitySelfImprovement.swift` | `AppModel`: `savePersonality`, `savePersonalityChecked`, `savePersonalityName` |
| `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll` |
| `AppModel+RoutingWorkflowMCP.swift` | `AppModel`: `search`, `routeIntent` |
| `AppModel+SkillsIntegrations.swift` | `AppModel`: `deleteSkill`, `loadSkillManifests`, `installReviewedSkill`; exact candidate code/fixture review |
| `AppQuietSettingsHost.swift` | `AppQuietSettingsHost` class; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: `runMind`, `manageSkill` |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppToolPlatform.swift` | live executor/browser/Doctor bindings over core policy; workshop decisions and away sensing live in core; `AppToolExecutor`: `defaultBrowserActionRunner`, `decideBlockedWorkshopStep`, `macPersonAway` |
| `BotsEditorSheet.swift` | `BotsEditorSheet` struct |
| `BotsShelfView.swift` | `BotsShelfView` struct |
| `BrowserWindow.swift` | `NavResult` struct; `BrowserActionRoutes.app` over the visible window's route effects |
| `CapabilitiesView.swift` | `CapabilitiesView` struct |
| `SensesView.swift` | `SensesSurfaceState`, `SensesView`; contract-only read projection and per-sense lifecycle switch |
| `WorkPaneSenseView.swift` | `WorkPaneSenseView`; separate offline script-enabled WebKit host, one version-bound sense event channel |
| `CapabilityProductionHardeningPanel.swift` | `CapabilityProductionHardeningPanel` struct |
| `ChatComposerChrome.swift` | `ComposerTabKeyHandler` struct; `makeNSView`, `updateNSView` |
| `ChatInlineApprovalCard.swift` | mounted approval card, local state and approval copy |
| `ChatMessageListView.swift` | `ChatMessageListView` struct |
| `ChatShellPresentation.swift` | `ChatShellConversationRow`: `isWorking`, `preview`, `isBridgeRouted` |
| `ChatShellViews.swift` | `ShellRoomHeader` struct |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatToolPillView.swift` | `ToolPillPresentation` struct; retained metadata projection, `outcome`, `title` |
| `ChatView.swift` | `ChatView` struct; `ChatTurnNoticePresentation` |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+DetachedSessionMenu.swift` | `ChatView`: `detachedSessionMenu` |
| `ChatView+PinnedSessions.swift` | `ChatView`: `humanPinnedSessionIds`, `savePinnedSessionIds`, `prunePinnedSessions` |
| `ChatView+SessionActions.swift` | `ChatView`: `showToast`, `rename`, `renameActiveChatTitle` |
| `ChatView+ShellColumn.swift` | `ChatView`: `shellSessionHasUnsentWork`, `shellSessionIsPinned`, `shellSessionRow` |
| `ChatView+SlashCommands.swift` | `ChatView`: `send`, `handleSlashCommand`, `dispatchSlashCommandTool` |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` enum; `setUp`, `isComplete` |
| `ComposerContextReceipt.swift` | `ComposerContextReceipt` struct |
| `ConnectorsView.swift` | `ConnectorsView` struct |
| `DeskItemInspector.swift` | `DeskItemInspector` struct |
| `DeskLiveReloader.swift` | `DeskLiveReloader` class; `trace`, `resolveGlanceVisibility` |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `GitHubPlatformPorts.swift` | `GitHubApprovalEdgeNotifier`: extension |
| `InboxCardActions.swift` | `AppInboxCardActionEffects`: mounted navigation and live composition bindings; callers use the core inbox transaction directly |
| `InteractionCardDelivery.swift` | `InteractionCardDelivery` enum; `pointer`, `observe` |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphRows.swift` | `KGEntityRow` struct |
| `KnowledgeGraphStatusHeader.swift` | `KGNativeStackStatus` struct; `load` |
| `KnowledgeGraphView.swift` | `KnowledgeGraphView`: mounted graph, filters, policy and maintenance presentation; `loadKnowledgeGraphPolicy`, `reloadKnowledgeGraphPolicyAndGraph`, `loadGraph` |
| `LivingStatusPanel.swift` | `LivingStatusPanel` struct |
| `MacChatTranscriptSearch.swift` | `MacChatTranscriptSearch` enum |
| `MemoriesPageView.swift` | `MemoriesPageView` struct |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform` |
| `MemoryRepairPresentation.swift` | `AppMemoryRepairPresentation` struct; `ensureInboxCard` |
| `NativeAgentApp.swift` | SwiftUI app and scene declarations; coordinator-gated async restore/recovery before model and ingress, off-main engine/layout preparation; startup pre-opens `logs/crash-breadcrumbs.log` for the tiny C `CrashBreadcrumbs` fatal-signal handler (best-effort unwinding, default re-raise) |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`, `appShimmer` |
| `NativeAgentDesignTokens.swift` | `Color`: `NativeAgentFont`, `NativeAgentSpacing`, `NativeAgentRadius` |
| `NativeAgentIntents.swift` | `NativeAgentChatIntent`: `perform`, `reply` |
| `NativeAgentNotificationActions.swift` | Native response mapping, notification categories and mounted window/conversation dispatch; effects stay in EngineNotificationActions |
| `NativeAgentWindowChrome.swift` | `AppRelauncher` enum; `relaunchHelperScript`, `relaunchHelperArguments` |
| `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession` |
| `NativeOAuthPlatform.swift` | `NativeOAuthPlatform` enum; `makeLoopbackSession`, `openBrowser` |
| `OnboardingWizard.swift` | `OnboardingWizard` struct |
| `PersonalityView.swift` | `PersonalityView` struct |
| `ProviderSettingsComponents.swift` | `ProviderRowView` struct |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `SimpleShellView.swift` | `SimpleShellView` struct |
| `TrustCenterView.swift` | `TrustCenterView` struct |
| `WorkshopObservatoryPanel.swift` | `WorkshopObservatoryPanel` struct |

### Models

Directory: `Sources/NativeAgentApp/Models/`

| File | Owns |
|---|---|
| `ImprovementNextGenModels.swift` | Core model aliases for `ImprovementGauntletRun`, `GauntletCheck`, `ProductionHardeningSummary` and `NextGenReceipt`; app extensions `ImprovementGauntletRun.run` and `NextGenReceipt.humanized` |

## Core Runtime Map

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

| File | Owns |
|---|---|
| `OwnedProgramStore.swift` | Candidate identity, sealed rehearsal and publication through AbilityStore headers; rehearsal scopes supplied inputs and reached calls, never behavioral proof from intercepted replies; trusted bundled-seed proofs seal exact bytes without validation receipts or staging; source-bound sense reads bind captured-material proof; OwnedProgramFixtures reads live and intercepts tool/routine effects and decisions |
| `OwnedProgramRunner.swift` | Invocation-bound selection/dependency proof shared until canonical catalog revision changes; shared program execution, resident helper leases invalidated by canonical ability changes/removal, fresh per-call authority/journal and resume freshness; host calls carry the part and its input in SkillRunContext; `host.state.get/set` for tools and skills reaches `PartNotebooks` by part id (scratch for preview/validation); skill resume replays saved state results then persists new state operations normally, without renewing stalled execution; authored tools receive frozen home/workspace paths and their requesting data root; rooted file calls resolve app_data/workspace before the door, retaining path-array listing compatibility through ordinary paging; `ReadContent` collects owner-declared envelope projections and content dependencies, sharing normalization with replay argument comparisons without changing replies |
| `SensesContract.swift` | sense records/contracts, SensesHub registry projection and exact view-event admission, native catalog, memory provenance and durable unread news |
| `HelperSenseRunner.swift` | Isolated plug supervision with validated progress-based stall detection excluding app-served reply waits, read-to-watch idle holds, subscription-owned lifetime, passive watch/source callbacks and restarts; `PartNotebooks` is the shared durable state owner for every part id (16 KiB/value, 64 KiB/notebook), separate from lifecycle accounting; versioned use and visible live failure news, sealed view events, detached site following and app change deduplication/news; app reads use assembly's Trust-admitted read closure |
| `SenseDoor.swift` | Registry-first reads, bundled-kind ownership, exact served provenance and file-material envelopes; captured views retain the turn's growth refusal, discarding refused file bytes while preserving screen/site read and action snapshots; distinct private web/visible browser/group-owned Chrome provenance, same-corner act verification without re-entry, wrong-version reporting, captured native/JS site action material, Chrome envelope continuations and native screen continuation snapshots |
| `SenseScreenThings.swift` | Exact screen thing selections, captured related-action bindings on composite rows, and in-turn mac.act verb requests |

### ActivityWatch

Directory: `Modules/NativeAgentCore/Sources/ActivityWatch/`

| File | Owns |
|---|---|
| `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`; capture lifecycle, serialized off-main policy reads/writes, exact policy-file invalidation and one retention schedule using the runner's completed-run stamp and effective clamped capture policy; issue state with injected platform error and notification presentation |
| `ActivitySpanStore.swift` | `ActivitySpanStore`; asynchronous per-root store acquisition shared by capture, retention and queries |
| `HumanPresenceStamp.swift` | `HumanPresenceStamp` enum; durable present/away crossings at `ActivityWatchPaths.presenceTransitionURL`, shared with the scheduler through `transitionURL` |

### AgentConversations

Directory: `Modules/NativeAgentCore/Sources/AgentConversations/`

ACP agents run as the user and can act directly. Their requested permission
modes are vendor restrictions, not NativeAgent enforcement guarantees;
NativeAgent approval cards cover only requests the agent submits.
`AgentHostConnection.swift` discloses this boundary when connecting an agent.

| File | Owns |
|---|---|
| `AgentACPApproval.swift` | `AgentACPApproval` enum; `connect`, `request` |
| `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` enum; helper discovery and shared execution; wake-runner process identity; OMP reply-job recovery |
| `AgentConversationExchange.swift` | `AgentConversationExchange`: `started`, `absorb`, `validate` |
| `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |
| `AgentConversationLive.swift` | `AgentConversationLive` struct; `projection` |
| `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |
| `AgentConversationRunning.swift` | `AgentConversationRunning` class; `begin`, `end` |
| `AgentConversationSession.swift` | `AgentConversationSession` enum; `approvalRow`, `replayApproval` |
| `AgentConversationStore.swift` | `AgentConversationStore` struct; `records`, `recordsUnlocked` project stored reply deadlines through `AgentConversationView`; expiry is terminal with no reply, while the transport still accepts late answers. |
| `AgentContactHealth.swift` | Shared reply-path health from the newest receipt's `no_reply_expired`, delivery failures and round trips; an app, program or recipe change since the proof is unverified, named ("Unverified since Muse updated to 7.0", "…since Hermes updated to 0.22.0", "…since the recipe changed"), with no repair; the next send or `agent.verify` re-proves. `repair` is the one repair: the contact's own send run dry (`AgentRecipeStore.dryRun`), for a send that sent nothing (`heal`: one retry of the same operation, or a harness item), and `agent.verify`, never the background check, which reads the last send's repair (an A2A contact's runs its dry run, `AgentPeerDiscovery.a2aCheck`); a desktop chat whose log changed shape after Return is filed, never retried, and a send that lands closes the contact's bridge items. Detached refreshes share one projection. Durable verification claims bound background checks to once per episode and once per contact per hour, without resend or a new poller. |
| `AgentConversationView.swift` | `AgentConversationView` enum; `read`, `codingReply`, `expiringReply`; `dotReply` projects Dot's existing half-hour wait from its stored send time for UI and contact reads. `claudeWorklogTail` is the shared bounded continuity/worklog reader; `claudeWorklog` exposes recent recorded work for contact reads and the read-only app action. |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter` enum; `writeEnvironment`, `ensureEnvironment`; settings splice accepts an absent or exact entry, or a same-contact credential repair differing only in its secret; all other collisions fail before mutation; `checking` requires the saved entry without writing; removal names missing ownership receipts and preserves unproven bytes |
| `AgentHostConnection.swift` | `AgentHostConnection` enum; `builderWorkspaceRoot`, `isNamedConnect`; Connect resolves host or exact peer identity (a peer only in its own workspace; another folder is that folder's own contact), re-mints a missing key on the same contact, retires proof and rewrites only its connector entry under the settings lock; elevation remains store-owned; disconnect revokes before settings cleanup and keeps failed cleanup owed through RepairOwed; `verifySetup` stays read-only |
| `AgentHostDirectory.swift` | `AgentHostDirectory` enum; `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`; `installation.evidence` is discovery/Connect/verify's one installation check; install markers must resolve to executable files or app bundles with executable programs, never profiles; recipe `executables`, `discoveryWords`, `searchPaths` and `messagingPermissionsPath` replace inferred program names, fixed discovery words, ambient path additions and a hardcoded host permission file |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentMailActions.swift` | `AgentMailActions` enum; `listRecent`, `readMessage` |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery` enum; `authenticatedInterface`, `a2aCheck` (an A2A call's card held to its recipe; its dry run), `listTasks`, `probe` (discovery by protocol, never by name: an A2A card on any listening loopback port, a program carrying ACP's methods or advertising an ACP entry, a settings file holding an mcpServers table, all read from verified regular files; the recipe book read after, a find none knows carrying its `draft` recipe under an id of its protocol and path; on Agents and an explicit discover only, launch and installs keep the last finds); launch directly discovers/connects settings hosts from recipes without awaiting Spotlight; the index watcher adds later arrivals after any in-flight scan; no elevation, and a found program runs (bounded --help and initialize) only on an explicit discover, under `Launch`, the send's own rule for running another agent's program (`agentProgramLaunch`: Full Mac as is, else the builder sandbox, denied or locked down not at all); persistent declines/disconnects win, running hosts get one restart note; host and pass-wide setup failures name files/fields and remedies per candidate and wake key, keep dismissible offers, and clear on automatic/manual recovery; `app.installed` for each whole bundle at a bundle id and version new since the first, silent installed-apps.json baseline |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy` enum; `peerFailure`, `peerAuthorizeInterface` |
| `AgentPeerStore.swift` | Canonical contacts and proof: app bundle/version and recipe version/digest at round trip; `list`, `contactSummaries` includes every saved contact with reachability and owner trust separately |
| `AgentPeerTransport.swift` | `AgentPeerCredentials` enum; `resolve`, `isAvailable` |
| `AgentRecipeStore.swift` | `AgentRecipeStore` enum: one recipe per agent host under agents/recipes/, seeded from the host tables, read by `AgentHostDirectory.rows`, and one per A2A contact under its id (`AgentHostRow.A2A`, `recipe(for:)` seeds a missing one on the spot); `load`, `recipe`, `launch` (Trust's reader), `read`/`write` (the door's, one shape check, under the file lock; write can create a new host.id without overwriting existing bytes), `learn` (a dry run's findings, source "learned"), `dryRun` |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport` enum; `listen`, `reconnect`, `readiness` |
| `ExternalSendPreparedInput.swift` | `ExternalSendPreparedInput` struct |
| `GrokBotRoute.swift` | `GrokBotRoute` enum; `withHistory`, `takenByWaiter` |
| `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |

### AgentLinkTransport

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/`

| File | Owns |
|---|---|
| `AgentA2AGRPC.swift` | `AgentA2AGRPC` enum; `send` |
| `AgentA2APushReceiver.swift` | `AgentA2APushReceiver` actor; `receive`, `consume` |
| `AgentA2AStream.swift` | `AgentA2AStream` enum; `events`, `normalize`; shared stream accumulator |
| `AgentA2AWire+Mapping.swift` | `AgentA2AWire`: `canonicalPart`, `wirePart`, `canonicalState` |
| `AgentA2AWire+Operations.swift` | `AgentA2AWire`: `operationRequest`, `operationResult`, `normalizeTaskList` |
| `AgentA2AWire.swift` | `AgentA2AWire` enum; `selectInterface`, `messageRequest` |
| `AgentACPClient.swift` | `AgentACPClient` actor; `startupTimeoutReceipt`, `turn` (recipe-driven; no message is a dry run), `learned`; `Mismatch`: nothing sent |
| `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |
| `AgentACPProcess.swift` | `AgentACPProcess` approved spawn, process-group termination and reap |
| `AgentPeerHTTP.swift` | `AgentPeerHTTP` enum; `send`, `get` |

### AgentLinkTransport/Generated

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/Generated/`

| File | Owns |
|---|---|
| `a2a.grpc.swift` | `GRPCCore`: `Lf_A2a_V1_A2AService`, `Method`, `SendMessage` |
| `a2a.pb.swift` | `Lf_A2a_V1_TaskState`: `_2`, `Version`, `RawValue` |

### AgentWorkspace

Directory: `Modules/NativeAgentCore/Sources/AgentWorkspace/`

Home navigation behind `app`; this module is not a separate model tool.

| File | Owns |
|---|---|
| `AgentConversationProjection.swift` | `AgentConversationRecord` struct; `ContactThread.lines` reads full history through the shared transcript resolver and propagates unavailable history |
| `AgentWorkspace.swift` | `AgentWorkspace` enum; `dispatch`; `AgentWorkspaceNavigation.Session` retains the conversation's last undo receipt alongside its navigation, scoped by data root and session, never in a second ledger |
| `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback` enum; `dispatchEffect`, `followUp` |
| `AgentWorkspaceActivity.swift` | `AgentWorkspaceActivity` enum; `project`, `today` |
| `AgentWorkspaceApps.swift` | `AgentWorkspaceApps` enum; `quickAction`, `project` |
| `AgentWorkspaceArrivals.swift` | `AgentWorkspaceArrivals` enum; `pending`, `hash` |
| `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: `observationStamps`, `observe`, `bindCurrent` |
| `AgentWorkspaceChanges.swift` | `AgentWorkspaceChanges` enum; `evaluate`, `evaluateHumanListing`, conversation change observations through the bound owner port |
| `AgentWorkspaceConversation.swift` | `AgentWorkspaceConversation` enum; `project` |
| `AgentWorkspaceConversations.swift` | `AgentWorkspaceConversations` enum; `project` |
| `AgentWorkspaceDesktopNavigation.swift` | `AgentWorkspaceNavigation`: `restoredSession`, `canEvict`, `draftAttemptIsDurable` |
| `AgentWorkspaceDesktopStore.swift` | `AgentWorkspaceDesktopStore` struct; `load`, `save` |
| `AgentWorkspaceEnvironment.swift` | `AgentWorkspaceEnvironment` enum; `isStatusReader`, `title` |
| `AgentWorkspaceFileRevision.swift` | `AgentWorkspaceFileRevision` struct; `prepare` |
| `AgentWorkspaceFind.swift` | Exact owned contact/helper, Desk, session, approval and message IDs enter their canonical readers before topic search; `project` |
| `AgentWorkspaceForm.swift` | `AgentWorkspaceForm` struct; `readingHelperSettings`, `withSchemaIssue` |
| `AgentWorkspaceHumanProjection.swift` | `AgentWorkspaceHumanProjection` enum; `read`, `project` |
| `AgentWorkspaceKnowledge.swift` | `AgentWorkspaceKnowledge` enum; `project`, `memoryTitle` |
| `AgentWorkspaceMail.swift` | `AgentWorkspaceMail` enum; `project` |
| `AgentWorkspaceMessages.swift` | `AgentWorkspaceMessages` enum; `project` |
| `AgentWorkspaceOverview.swift` | `AgentWorkspaceNavigation`: `windowTitle`, `windowAction`, `window` |
| `AgentWorkspacePorts.swift` | `AgentWorkspacePorts` enum |
| `AgentContactState.swift` | Presentation-only Claude/Codex identity aliases, local health observations and exact pull-reply read receipts. Original routes, credentials and transcripts remain separate. |
| `AgentWorkspaceProjection.swift` | `AgentWorkspaceProjection`: `project`; `AgentWorkspace` binds receipt read refs through the existing workspace name book |
| `AgentWorkspaceReadiness.swift` | `AgentWorkspaceReadiness` enum; `withSnapshot`, `filter`; tool-port service blockers shared with action discovery |
| `AgentWorkspaceSavedReply.swift` | `AgentWorkspaceSavedReply` struct; `title`, `evidence` |
| `AgentWorkspaceWork.swift` | `AgentWorkspaceWork` enum; `desk`, `continuation` |
| `AgentWorkspaceWorkOverview.swift` | `AgentWorkspaceNavigation`: `workReceiptKey`, `placeAction`, `focusWork` |
| `DelegationStatusProjection.swift` | `DelegationDeliveryCache` class; `read`; consumes lifecycle decisions with their known principal and source |
| `HerQueue.swift` | `MyQueueTurnProjectionProviding` protocol over cognition's Desk-revision-checked candidates and explicit refresh-pending-after-write state; `MyQueueReady` reads named experience conditions by primary key for unattended and recorded-session eligibility; `HerScreen`: `queueContext`, async `queueRows` shows those obligations, `resume` |
| `HerScreen.swift` | `HerScreen` enum; `withNames`, `resolve`, compact Senses home projection and readable full senses item from registry/news, sharing the live built-ability line with turn context |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom`; crews share the SwarmRuns projection with the Mac view |
| `HerScreenRooms+Build.swift` | `HerScreen`: `buildRoom`, `buildTarget`, `buildRecordRoom` |
| `HerScreenRooms+Comms.swift` | `HerScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `HerScreenRooms+Core.swift` | `HerScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `HerScreenRooms+Elsewhere.swift` | `HerScreen`: `doorLines`, `elsewhereRoom`, `elsewhere` |
| `HerScreenRooms+Life.swift` | `HerScreen`: `lifeRoom`, `lifePulse`, `opening` |
| `HerScreenRooms+Web.swift` | `HerScreen`: `tabName`, `tabTitle`, `webTabCell` |
| `HerScreenRooms.swift` | `HerScreen`: `room`, `names`, `screen` |
| `HarnessQueue.swift` | `HarnessQueue` enum, `HarnessFinding` struct; `file`, `resolve`, `fold`: keyed findings refresh in place, preserving closure and person ownership; wake carry opportunities share the existing ledger and its retained material fingerprint, reoffering only changed work; settled experience conditions name their release |
| `HerWorld.swift` | `HerWorld` struct; retained owner picture including contact histories and delegations; `HerMemo` refreshes on file and owner lifecycle invalidations, publishes completion, and tracks pending revisions without page-time source scans; child watches rebind on membership changes; room acknowledgements preserve stale parts; crews use canonical SwarmRuns; name books retain their names lock |
| `HumanConversationIndex.swift` | `HumanConversationIndex` enum; `string`, `object` |
| `MacScreenPreviewBus.swift` | `MacScreenPreviewBus` enum; preview resizes the source-masked observation |
| `ResidentWake.swift` | `ResidentWake` class; `request`, `claim`, `take`; `checkedRead` exposes pending/recent arrivals read-only through the existing Arrivals room; exact free-time deadlines, turn-terminal waits and conversation-event route waits share its ledger |
| `SurfaceLayoutStore.swift` | `SurfaceLayoutStore` enum: ui/layout.json under the host's data root (cached per root), seeded from `SurfaceLayout.vocabulary`; `layout` (what the window, their home and the page index draw, re-read when the file changes), `read`/`write` (the door's `layout.read`/`layout.write`: one shape check, version `layoutVersion@digest`, the replaced file kept for undo, a file that does not read never written over), `setExpanded` (the person's fold); `SurfaceLayoutLive` (the window's observed copy, `attach`ed to the app's root) |
| `ToolSignature.swift` | `ToolSignature` enum; `call`, `doorArgs` |
| `WorkContextQuery.swift` | `WorkContextQuery` struct; `matchedTerms`, `score` |

### Agents

Directory: `Modules/NativeAgentCore/Sources/Agents/`

| File | Owns |
|---|---|
| `AgentContactRoutes.swift` | Authenticated contact ingress, MCP/A2A requests, retained reply pagination, event waits and transport-confirmed fetch acknowledgements |
| `ClaudeBridgeRuntime.swift` | Authenticated HTTP/contact routes, state deadlines, human-pausable shared tool deadline, live payload publication, retained clients, reply recovery and event transport |
| `ClaudeBridgeRuntime+StandingViews.swift` | Standing-view request codec and HTTP routes through Cognition review authority |
| `DesktopChatRoute.swift` | Recipe-bound conversation selection, send confirmation, learned reads and uncertain delivery without automatic resend |
| `NativeAgentMCPWire.swift` | MCP negotiation, parsing, caller-supplied request identity and reply projection |
| `NativeAgentA2AGRPCListener.swift` | gRPC loopback listener generation, endpoint publication and lifecycle |
| `NativeAgentA2AGRPCService.swift` | gRPC authentication, protocol/error projection and acknowledged stream delivery |
| `AgentBridgeCompletionRouter.swift` | Completion-route adapters and destination validation; saved let-go delivery stops at admission before asking-chat rows or dispatch; `AgentBridgeCompletionRouter`: `isValidIOSDeviceRouteKey`, `deliverAnswer` |
| `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation`; saved arrivals wait on `TurnAdmission` capacity signals; cached failed-admission peer IDs gate link recovery before peer/file reads; room cleanup keeps the first revised message per ID |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` struct; claims require the pinned response run; digest-bound answer and exact return intent; remote settlement delegates to the route journal; launch/event reconciliation isolates corrupt jobs and appends JS reply-job settlements under the ledger.lock flock shared with JS append and rotation; closed peer reply findings settle covered records as let_go; delivery admission, artifact reservation and dispatch transition reject let-go records before transport |
| `ClaudeBridgeMessageRuntime+AgentLive.swift` | `ClaudeBridgeMessageRuntime`: `agentLiveJobActive`, `handleAgentLive` |
| `ClaudeBridgeMessageRuntime.swift` | Bridge message admission/delivery and the retained chat client; event publication is a weak callback to the HTTP runtime |
| `ClaudeBridgeStateProjection.swift` | `ClaudeBridgeStateProjection` enum; `procedureStatusJSON`, `microcycleTelemetryJSON` |
| `GrokBotConnection.swift` | Grok connection coordination and secure Bot selection/credential transactions |
| `GrokBotConnectionPort.swift` | `GrokBotConnectionPort` protocol; `ensureRunning`, `send` |

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

| File | Owns |
|---|---|
| `AppActionRegistry.swift` | App action definitions and registry (`AppAction`, `AppActions`); MCP and authored action lookup; one schema-aware semantic/lexical ranking for declared page items, built-ins, admitted tools, enabled skills and current senses, with shared retrieval stop words, a semantic relevance floor and model-epoch action vectors; explicitly requested retired tools are labeled read-only records; file Trash, recurring tasks and named contacts route to their owners |
| `AppChatToolDispatcher.swift` | Composed tool dispatch, Security Center admission and settled-result observers |
| `AppScriptRunner.swift` | Shared-runner app host adapter, dependency-scoped file revisions (including transitive MCP dependencies) for invocation bindings, dependency shapes and ordinary turn-chain re-entry; declarations grant no action authority |
| `AppToolExecutor+AppDoor.swift` | The `app` schema and home/page/item/find/action/actions/script dispatch, compact expandable action catalogs, read-only conversion census and preserved domain execution receipts; `undo` re-enters the receipted layout, recipe or setting action's gates and restores through that owner |
| `AppToolExecutor+Senses.swift` | Sense corner reads, served verb discovery and gated in-turn acts |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpAllowed`, `runChromeHistory`; history reads a private SQLite copy of Chrome's Default profile under Full Mac/file-read authority, with bounded rows and query deadline; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`: `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall` |
| `AppToolExecutor+Health.swift` | `AppToolExecutor`: `doctorStatus`, `boundedDoctorDetail`, `doctorStatusEnvelope` |
| `AppToolExecutor+MyQueue.swift` | `AppToolExecutor`: `runMyQueue`, `runHouseFile`; filing receipts report the stored owner and explicitly say when a requested reassignment was not made |
| `AppToolExecutor+Photos.swift` | `AppToolExecutor`: `runPhotosRead`; read-only PhotoKit counts and recent asset metadata, with action-time macOS authorization |
| `AppToolExecutor+SkillRun.swift` | `AppToolExecutor`: `doorSkill` (skill.validate, skill.run, skill.resume), routine dependency/input/version checks for shared validation, `doorWouldCard`; `SkillRunStore` |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`: `performMacSelfAppRoute`, `quietPosture`, `freshQuietPosture` |
| `AppToolExecutor+PagePresentation.swift` | screenshot results and quiet page/read rendering |
| `AppToolExecutor+QuietMind.swift` | quiet mind commands and decision receipts |
| `AppToolExecutor+UpkeepTarget.swift` | backup restore target validation |
| `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`: immutable non-door schemas and independently lazy door schema via `appToolSchemas`, preserving the registry initialization boundary |
| `AppToolExecutor.swift` | `AppToolExecutor` class; shared immutable descriptors; `execute`; home arrivals from app.installed runs retain bundle/version identity alongside the line without a new action argument |
| `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |
| `AppToolPorts.swift` | `BrowserToolPlatformPort` struct |
| `ChromePageText.swift` | `ChromePageText` enum; one `Projection` shares rendered text and addressable rows with the mirror and envelope; ordered inline prose with link proofs, section-named continuation headers, `project`, `rows`, page and folded-control `next`; `contentVersion` shared by the envelope and Chrome news without rendering |
| `ExistingCornersReaders.swift` | `ExistingCornersSourceProvider`: gated raw readers for screen, files, documents, connectors, private web, visible browser and Chrome; event-backed Chrome material for ordinary reads/following; `NativeChromeNews` observes from tab navigation, owns one tab-bound native reader subscription into `SenseNewsBoard`, and sends capture failures to Chrome status without consuming its successful baseline |
| `NativeActionRoutes.swift` | `NativeActionRoutes` enum; `runNativeAction`, `swiftNativeActionRecords` |
| `NativeAgentNotificationPostResult.swift` | Re-exports `AttentionRouting` notification result contracts |
| `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |
| `NativeSkillRegistryActions.swift` | native skill lifecycle actions and signed capability-pack script-host binding; `NativeSkillRegistryActions` enum; `deleteSkill`, `enableSkill`, `disableSkill` |
| `QuietAdminPreferences.swift` | `VoicePreference` enum; `quiet`, `name`; Shared UI preference keys including MomentsLaneSetting; appearance/view preferences; voice preferences belong to MultimodalTTS |
| `QuietInboxCommands.swift` | `QuietInboxHost`: inbox fences and commands |
| `QuietSelfAdminSettings.swift` | `QuietSettingsHostProvider` typealias; static-first settings lookup and read-scoped bot projections, with fresh mutation readers |
| `QuietSelfAdminSettings+LowerOnly.swift` | lower-only settings rows and cognition/provider controls |
| `QuietSelfAdminSettings+Mobile.swift` | mobile settings projection and writes |
| `QuietSettingsHost.swift` | `QuietSettingsHost` protocol; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `QuietTrustPolicyPreset.swift` | `TrustPolicyPreset` enum; `save`, effective-policy preset matching |
| `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |
| `ToolInteractionResolving+Transactions.swift` | interaction lookup and transaction resolution |

### ApprovalInbox

Directory: `Modules/NativeAgentCore/Sources/ApprovalInbox/`

| File | Owns |
|---|---|
| `ApprovalInbox.swift` | checked durable approval authority; `ApprovalRecord.decisionExperience` projects the decision obligation, dated outcome, shared face and receipt-backed application claim; REM resolves newest cards in one checked snapshot by proposal identity; mutation boundaries enqueue advisory experience writes using the committed record, never from reads |
| `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `loadSpends` |

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

| File | Owns |
|---|---|
| `DeskClickApprovalFiler.swift` | Package-scoped local-click approval filing under `ApprovalTransactions` |
| `ApprovalTransactionCoordinator+Effects.swift` | effect port and workshop-step decision/approval transaction |
| `ApprovalTransactionCoordinator.swift` | `ApprovalTransactionCoordinator` struct; `jsonString`, `memoryHygieneReceipt` |
| `ExternalSendApprovalTransactions.swift` | `ExternalSendApprovalTransactions` enum; `applyResolvedExternalSend`, `externalSendReceiptsPath` |
| `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort` protocol; platform probes/acquisition and activation/System Settings quit events for non-polling card settlement |
| `InlineInteractionResolver.swift` | `InlineInteractionResolver` enum; `takeContinuationHandBack`, `interactions`; authored setup cards file and return under the shared `blocksTurn` rule, while blocking cards wait |
| `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |
| `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedKindBackfill`, `reconcileUnappliedMemoryRepairs` |
| `ProcedureExactActivationApproval.swift` | `ApprovalTransactionCoordinator`: `applyResolvedProcedureExactActivation` |
| `TelegramApprovalCoordinator.swift` | `TelegramApprovalFiler` actor; `fileApprovalRequest`, `awaitResolution`; expiry guidance names from PersonaEngine |

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

| File | Owns |
|---|---|
| `NativeAgentNotificationActions.swift` | `NativeAgentNotificationActions` |
| `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult`: confirmed native delivery fields |
| `InboxPushNotifier.swift` | `AttentionRouter.notifyIfAttentionWorthy`: severity and live-root notification routing |
| `AttentionRouter+MacNotifications.swift` | Native UserNotifications transport, message-route binding and notification admission/receipts |
| `AttentionDeliveryPorts.swift` | `AttentionDeliveryPorts` struct |
| `AttentionRouter+RequestedResults.swift` | `AttentionRouter`: `retryRequestedResults`, `deliverRequestedResult` |
| `AttentionRouter.swift` | `AttentionRouter` actor; `delivery`, `allowed`, `releaseHeld` retain notification destinations and routing metadata through quiet hours |
| `NativeAgentScheduledProactiveScan.swift` | `NativeAgentScheduledProactiveScan` enum; `inboxActions`, `evaluate` |
| `NotificationChannelPreference.swift` | `NotificationChannelPreference` enum; `push`, `telegram` |
| `TriggerNotificationDelivery.swift` | `TriggerNotificationDelivery` enum; `importance`, `notify` |

### BackgroundLoops

Directory: `Modules/NativeAgentCore/Sources/BackgroundLoops/`

| File | Owns |
|---|---|
| `BackgroundLoopsManager.swift` | Core background-loop registration, execution and status |

### BackgroundWork

Directory: `Modules/NativeAgentCore/Sources/BackgroundWork/`

| File | Owns |
|---|---|
| `DelegationOutcomeLoop.swift` | Delegation terminal snapshots, exact durable cursor, outcome/liveness classification and settlement runner |
| `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `completeMessages` |
| `BackgroundWorkPorts.swift` | `BackgroundWorkEventPort` protocol; `storeAndFileEvents` |
| `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork` enum; `makeTelegramChatHandler`, `fileSystemPermissionNotice` |
| `DelegationBackgroundWork.swift` | `DelegationBackgroundWork` struct; `makeDelegationOutcomeLoop`, `delegationJobSnapshot`; one owed-answer notice per peer, retires the duplicate Codex backlog card; one failed-before-answer finding per peer or human route, dated counts and bounded newest-first file refs; per-peer findings persist and refresh every covered delivery ID as a trace ref; closed peer findings settle only those IDs before reply reconciliation; Telegram's index and exact iOS events retain settlement ownership |
| `BodyReport.swift` | Crash breadcrumb paths and fatal-signal/process-exit logging |
| `DeskContinuationScheduler.swift` | `DeskContinuationScheduler` actor; `nextDeadline`, `runDue`; checkpointed runs retain their process-resume owner |
| `DeskNotifyRunner.swift` | `DeskNotifyRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
| `DreamBackgroundWork.swift` | `DreamBackgroundWork` enum; `runREM` routes typed decode failures and healthy settlement to the shared finding sink; `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager` |
| `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; direct `LoopStatus` health, dormancy and schedule interpretation |
| `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |
| `GitHubTrackingBackgroundWork.swift` | `GitHubTrackingBackgroundWork` enum; `githubTrackingWatchedPaths`, `makeGitHubTrackingLoop` |
| `HeartbeatBackgroundWork.swift` | `HeartbeatBackgroundWork` struct; `makeHeartbeatLoop` uses per-condition templates without a model call; `HeartbeatLoop` owns heartbeat work |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `InboxRewriteGuard.swift` | `InboxRewriteGuard` enum; `readLines`, `writeLines` |
| `MaintenanceBackgroundWork.swift` | `MaintenanceBackgroundWork` struct; Doctor and loop failures owe repair through DoctorStatusProjection; disk hygiene accounts per owner, saves executable cleanup plans, retains cleanup receipts and acknowledgment by finding identity; weekly self-improvement, retention and backup work, manual weekly-run token lifecycle and digest reads |
| `MemoryConsolidationHygieneRunner.swift` | `MemoryConsolidationHygieneRunner` struct; `tick`, `tickOutcome` |
| `TelegramBackgroundBridges.swift` | `TelegramAccountModelCatalogPort` struct |
| `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork` enum; `makeJobWork`, `makeMorningBriefSynthesizer` |
| `WorkshopBackgroundWork.swift` | `WorkshopBackgroundWork` enum; `makeWorkshopExecutor`, `unattendedWorkAllowed`, Full Mac unattended override |
| `WorkshopExecutorDrainRunner.swift` | `WorkshopExecutorDrainRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
| `WorkshopPumpLoopRunner.swift` | `WorkshopPumpLoopRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |

### Browser

Directory: `Modules/NativeAgentCore/Sources/Browser/`

| File | Owns |
|---|---|
| `Browser+ActiveRuns.swift` | process-local run cancellation registry and attachment latch |
| `BrowserActionRoutes+DOM.swift` | DOM scripts, bounded reads, result decoding and browser errors |
| `BrowserActionRoutes+IPC.swift` | authenticated IPC route decisions over window effects |
| `BrowserIPCServer.swift` | browser IPC routing and shared NativeLoopbackListener transport conformance |
| `BrowserActionRoutes+NativeActions.swift` | `BrowserActionRoutes`: `runBrowserNativeAction`, `stringInput` |
| `BrowserActionRoutes.swift` | `BrowserActionRoutes` struct; `observeBrowserMotorAction`, `runBrowser`, direct dry-run/cancel commands to the canonical operation store, task-local `retainRead` delivery of the exact visible read capture |
| `BrowserLink.swift` | `BrowserLink` struct |
| `BrowserRouteEffects.swift` | visible browser port; shared begin/finish/cancel lifecycle over BrowserActiveRunRegistry |
| `BrowserRouteModels.swift` | `BrowserRun`, `NativeActionReceipt`; failed navigation receipts expose the retained openError as detail |

### ChatOrchestration

Directory: `Modules/NativeAgentCore/Sources/ChatOrchestration/`

| File | Owns |
|---|---|
| `ChatOrchestration.swift` | Re-exports `ChatTurnRuntime`, `ChatTurnContracts`, `ChatToolRuntime`, `ChatSessionWork`, `AgentWorkspace`, `AgentConversations`, `ChatToolParsing`, `AgentLinkTransport` |

### ChatSessionWork

Directory: `Modules/NativeAgentCore/Sources/ChatSessionWork/`

Manual compaction on Mac, iOS and Telegram uses `ChatOrchestrationClient.compactSession`:
the same mechanical summary, transcript-generation bump and background distillation.
Foreground chat and aging share `ChatSessionAutocompactor` and `ChatCompactionDistiller`;
aging alone requests a fixed keep-tail. Provider distillation runs outside the transcript lock.

| File | Owns |
|---|---|
| `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearchResult`, `TranscriptSearchResponse`, `TranscriptSearch` |
| `SessionMessageProvenance.swift` | `SessionMessageProvenance` |
| `CarriedAnchorRecollection.swift` | `CarriedAnchorRecollection` enum; `isEnabled`, `seeded` |
| `ChatCompactionBackupRetention.swift` | `ChatCompactionBackupRetention` enum; `enforce` |
| `ChatCompactionDistiller.swift` | `ChatCompactionDistiller` struct; `maxSummaryChars`, `thirdPersonSubjectCount` |
| `ChatSecretRedactor.swift` | `ChatSecretRedactor` typealias |
| `ChatSessionAgingConsolidation.swift` | `ChatSessionAgingConsolidation` struct; `scheduleTranscriptAgingIfNeeded`, `runTranscriptAging` |
| `ChatSessionAutocompactor.swift` | `ChatSessionAutocompactor` struct; `compactIfNeeded`, `pruneCompactBackups`; `ChatSessionAutocompactionConfig` owns `effectiveWindowTokens` and the read-only `contextWindowReadout` used by page reads and runtime introspection. |
| `ChatSessionDirective.swift` | `ChatSessionDirective` enum; `safeComponent`, `recordURL` |
| `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` |
| `ChatTranscriptEvidenceRendering.swift` | recorded tool outcomes and attachment evidence; voice history renders the retained utterance and original audio reference; re-exports ChatToolParsing's shared result classification |
| `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |
| `ContextBudgetPolicy.swift` | Shared model-input budgets for every door; `compactionHistoryCharacters`, `floors` |
| `HistoryWindowCursor.swift` | `HistoryWindowCursor`, `HistoryWindowCursorStore`; locked advancement persists only changed boundaries |
| `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore` struct; `record`, `recordConversationContinuation`; the locked validation supplies physical rows and append bytes to shared retention |
| `OutcomeTissueV2.swift` | `OutcomeEvidenceState` enum |
| `OutcomeTraceIdentity.swift` | `OutcomeTraceIdentity` enum; `normalized` |
| `SessionDigestProvider.swift` | Participant-bound prior-conversation selection and frozen handoff; `pointerSentence`, `digest`; peer identity is independent of session-id shape |
| `SessionHistoryMessageProjection.swift` | `SessionHistoryMessageProjection` enum; `admission`, `project` |
| `SessionHistoryPromptRenderer.swift` | `SessionHistoryPromptRenderer` enum; `renderDetailed`, `recallQuery` |
| `SessionHistoryReader.swift` | `SessionHistoryReader` actor; `messages`, `messagesWithStats` |
| `TurnVolatileArchive.swift` | `TurnVolatileArchive` actor; `load`, `record` |

### ChatToolParsing

Directory: `Modules/NativeAgentCore/Sources/ChatToolParsing/`

| File | Owns |
|---|---|
| `ChatToolOutcome.swift` | exact/display result classes, explanation and common waiting/failure predicates shared by approval faces, transcript projection and live receipts; below ApprovalInbox so readers share classification without importing session persistence |
| `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |

### ChatToolRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatToolRuntime/`

| File | Owns |
|---|---|
| `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding` enum; `pending`, `glance`; workspace tool port derives bounded built/recent ability names from canonical tool, skill and sense availability |
| `AppRestartCoordinator.swift` | Shared detached relauncher spawning; tool restart audit/cooldown/grace, bounded operator menu/restore exit wait and termination injection |
| `BotChatContract.swift` | `BotChatContract` struct; `checked`, `choice`; helpers follow Providers for Chat unless explicitly pinned, including legacy definitions without a pin field |
| `BotRunConversation.swift` | `BotRunConversation` enum; `enqueueRequestedCheck`, `dispatch` |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator` actor; `resolve`, `bind`; unreadable or invalid retained pointers refuse continuity with the exact field and a bounded repair call |
| `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas` |
| `BuiltInToolSchemaFactory+CoreSchemas.swift` | `BuiltInToolSchemaFactory`: `coreSchemas`, unchanged `context_expand` descriptor |
| `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |
| `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |
| `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory` struct; `requestedSchema`, `obj` |
| `CanonicalToolNameDispatcher.swift` | `CanonicalToolNameDispatcher` class; `canonical`, `dispatch` |
| `ChatHistoryIndex.swift` | `ChatHistoryIndex` class; `shared`, `absorb`, `absorbAll`; durable content-addressed index of transcript lines for history search (chat/index/history.sqlite) |
| `ChatFullMacYoloAdmission.swift` | `ChatFullMacYoloAdmission` enum; `admitted` |
| `ChatToolDispatchTrace.swift` | `ChatToolOutcome`: `normalizedFailure`, `failure`, `outputLooksSuccessful`; app-call traces retain structural `callShapes` (ordered action ids and argument keys/types, including a model's action batch), before lossy preview truncation; a turn-bound receipt is also the evidence of its act experience |
| `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction` enum; `injectionRedactedArgJSON`, `injectionRedactedResultJSON` |
| `ChatToolRuntimeImports.swift` | Re-exports `ChatTurnContracts`, `AgentConversations`, `AgentWorkspace`, `ChatSessionWork`, `ChatToolParsing` |
| `ChatToolSessionInjection.swift` | `ChatToolSessionInjection` enum; `apply` |
| `CodexImageGenerationControls.swift` | `CodexImageGenerationRequest`: `normalizedForBuiltIn`, `normalized` |
| `CodexImageGenerationHelp.swift` | `CodexImageGenerationHelp` enum |
| `CompactActionReceipt.swift` | `CompactActionReceipt` struct; `toJSONValue`, `toolDispatch` |
| `ExternalSendApprovalLifecycle.swift` | `ExternalSendApprovalLifecycle` enum; `executeAdmittedYoloToolResult`, `stage` |
| `FluidContextToolScope.swift` | `FluidContextToolScope` enum; expanded memory pages retain stored untrusted sources |
| `GitHubCommandCheckoutResolver.swift` | `GitHubCommandCheckoutResolver` enum; `resolve` |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | `InlineInteractionRegistry` enum; `connectorSetup`, `canonicalConnectorID` |
| `MCPToolCatalogWarmer.swift` | `MCPToolCatalogWarmer` actor; `kickDetached`, `kickIfDue`; bounded sweeps use `TurnDeadline`, marks retain per-server discovery selection |
| `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher` class; `peerApproval` shares live trusted-turn and peer-floor decisions between preview and execution; declared lifecycle writes apply CapabilityLifecycle's turn refusal before dispatch; memory notes retain attribution checks; `peerLine` preserves peer read provenance |
| `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`: `impl_tool_result_page`; retained-response search coverage and source-positioned matching records |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: `drivenAgentLaunch`, `drivenAgentContact`, `stampDelegationProducer` |
| `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `builtInAgentLaneUsable`, `impl_agentCommunication` |
| `SwiftToolDispatcher+ArtifactContext.swift` | `SwiftToolDispatcher`: `impl_artifact_find` |
| `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots` |
| `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage` |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | `SwiftToolDispatcher`: `impl_search_chat_history`, `impl_read_chat_message` |
| `SwiftToolDispatcher+CloudConnectorTools.swift` | Cloud reads and shared token reader; authenticated fetch with registry-fenced hosts; `OwnedFetchRedirects` refuses redirect dispatch |
| `SwiftToolDispatcher+CodexBridgeTools.swift` | `SwiftToolDispatcher`: `codexBrainControls`, `agentBridgeReplyOrigin`, `runCodexMessage` |
| `SwiftToolDispatcher+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, bounded anchored `impl_recent_trace_summary` pages; receipts span conversations by default, rank non-read actions first and scan complete retained since windows; `view:shapes` requires the signal's exact trace day file and turn id, exposes only top-level app calls in dispatch order, keys/types without values, excluding skill runs, and flags envelope truncation as incomplete; `trace.usage` and `trace.model_calls` share this route and `TurnTraceRecentReader` for recorded sums, purpose counts and retention coverage; explicit session filters and bound turn refs |
| `SwiftToolDispatcher+ClaudeBridgeTools.swift` | `SwiftToolDispatcher`: `runClaudeMessage`, `claudeReceiptStatus`, `markWakeStartedNothing` |
| `SwiftToolDispatcher+DelegationTools.swift` | `SwiftToolDispatcher`: `impl_delegation_status`, `delegationStatusLimit`, `delegationStatusOffset` |
| `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`: `deskAlias`, `impl_desk_read`, `impl_desk_add_item` |
| `SwiftToolDispatcher+DesktopPixels.swift` | `SwiftToolDispatcher`: `desktopPixelsRequested`, `desktopPixels`, `impl_mac_screenshot_save` saves system captures without model pixel delivery |
| `SwiftToolDispatcher+Dispatch.swift` | `SwiftToolDispatcher`: `withWebScheme`, `dispatch`, `preApprovalRefusal`; `mac_location` answers with the fix the kept CoreLocation owner holds, and its age, or requests its ordinary Location permission card |
| `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |
| `SwiftToolDispatcher+FourVerbPerception.swift` | `SwiftToolDispatcherFourVerbPerceptionSource` struct; whole native masked observation through recognition, region crop and JPEG fitting only at model delivery; window obstructions from MacControl's `SystemMacVisualObstructionProbe` |
| `SwiftToolDispatcher+HumanConversations.swift` | `HumanConversationSnapshot` struct |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`: `impl_image_generate`, `showGeneratedImages`, `imageGenerationReferences` |
| `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |
| `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`: `impl_search_kg`, `kgSeenDate` |
| `SwiftToolDispatcher+MCP.swift` | `SwiftToolDispatcher`: `parseMCPToolName`, `forwardedMCPArguments`, `impl_mcp_tool` |
| `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |
| `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`: `dispatchMacIntegrationTool`, read-only MapKit directions, distance-fraction place lookup and radius-bounded nearby place search via `impl_maps_route` / `impl_maps_search`, sharing `place` / `describe` |
| `SwiftToolDispatcher+Markets.swift` | `SwiftToolDispatcher`: `impl_market_status`, `impl_market_watchlists`, `impl_tradingview_watchlist`, `impl_market_quote`; quote-provider recovery retains answering provider and failures |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` retain taint on readback; `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`: `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata` |
| `SwiftToolDispatcher+MomentTools.swift` | `SwiftToolDispatcher`: `impl_memory_moments_pending`, `impl_memory_moment_review` |
| `SwiftToolDispatcher+OMPBridgeTools.swift` | `SwiftToolDispatcher`: `runOMPMessage`, `ompSessionSaved` |
| `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`: `impl_get_persona_doc`, `impl_persona_read`, `impl_persona_write` |
| `SwiftToolDispatcher+RemoteNodes.swift` | `SwiftToolDispatcher`: `impl_remote_node_list`, `impl_remote_node_execute` |
| `SwiftToolDispatcher+Sandbox.swift` | `SwiftToolDispatcher`: `resolveSandboxed`, `stringArray`, `normalizeFullMacPathArgument`, `openScreenWatch` (a part run's watch under the four verbs' access, card and sight) |
| `SwiftToolDispatcher+Senses.swift` | `SwiftToolDispatcher`: sense corner resolution and authorized raw material adapters |
| `SwiftToolDispatcher+SchemaBuilders.swift` | `SwiftToolDispatcher`: `modelVisibleMCPTools`, `mountedMCPToolSchemas`, `mcpToolSchemas` |
| `SwiftToolDispatcher+SkillTools.swift` | `SwiftToolDispatcher`: `impl_list_skills`, `impl_read_skill`, `impl_save_skill` |
| `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher`: `standingBotApprovalReason`, `standingBotsArgumentRefusal`, `impl_standingBots` |
| `SwiftToolDispatcher+StandingViewTools.swift` | `SwiftToolDispatcher`: `impl_hold_view`, `impl_release_view` |
| `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`: `impl_studio_canon`, `impl_studio_canon_resolve` |
| `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`: `impl_studio_shelf`, `studioImageInvitation`, `impl_studio_consult` |
| `SwiftToolDispatcher+SubprocessSupport.swift` | `SwiftToolDispatcher`: `armSubprocessTimeout`, `interruptThenTerminate`, `reapLaunchedTree`, shared bounded invoke/image pipe capture with adapter-specific limits and decoding |
| `SwiftToolDispatcher+SwarmTools.swift` | `SwiftToolDispatcher`: `impl_agent_swarm` |
| `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: `optionalNumber`, `jsonString`, `jsonInt` |
| `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file`, `fileReadPresentation`, shared `impl_file_metadata` for list/info, `impl_trusted_file_mutation` (workspace writes and Trash) |
| `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |
| `SwiftToolDispatcher+WorkContext.swift` | `SwiftToolDispatcher`: `impl_work_context`, `workContextDeskItem`, `boundedWorkContextValue` |
| `SwiftToolDispatcher+WorkshopTools.swift` | `SwiftToolDispatcher`: `impl_workshop_submit`, `impl_workshop_status`, `impl_task_ledger_post` |
| `SwiftToolDispatcher+WorkspaceDesk.swift` | `SwiftToolDispatcher`: `workspaceDesk` |
| `SwiftToolDispatcher.swift` | Native dispatcher construction and built-in, registry and MCP catalogs; authored projections share AbilityStore's exact catalog revision; named schema construction consumes parsed registry rows and selects before encoding |
| `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |
| `ToolResultSections.swift` | `ToolResultSections` enum; `pages`; complete line/value records, source-order query selection, raw references for oversized records |

### ChatTurnContracts

Directory: `Modules/NativeAgentCore/Sources/ChatTurnContracts/`

| File | Owns |
|---|---|
| `ChatApprovalContracts.swift` | `AutonomyDecision` enum |
| `ChatPersistenceContext.swift` | `ChatPersistenceContext` enum |
| `ChatToolBridges.swift` | `PureToolArgumentValidating` protocol; `argumentRefusal` |
| `ChatToolSessionContext.swift` | `ChatToolSessionContext` enum; `rendersInlineCards`, `withReplyRoute`; `TurnEnvelope.workIdentity` carries attribution, `answerExperienceID` carries the owed answer through continuations; neither grants authority |
| `ChatTurnExecution.swift` | `ChatTurnExecution` class; `bindHistoryRunID`, `keepCapabilityNote` |
| `PeerDataTaint.swift` | `PeerDataTaint` class; `withScope`, `markConsumed` (latches nothing: a read steers nothing), `elevate` (the person answered the run's card); ability write refusal reads current origin principal and live/carried peer steering |
| `SwarmChatClientFactory.swift` | `SwarmChatClientFactory` protocol; `makeClient` |
| `ToolDispatchRecord.swift` | `ToolDispatchRecord` struct; retains the call resolved before execution for outcome attribution and argument evidence |
| `ToolNoticeBus.swift` | `ToolNoticeBus` enum |
| `ToolTurnContracts.swift` | `ToolDispatchClient`: `dispatch`, `listAvailableTools`, `listAvailableToolSchemas` |

### ChatTurnRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatTurnRuntime/`

| File | Owns |
|---|---|
| `ChatUpdateNote.swift` | Version note selection and launch transaction with supplied bundle resource/version inputs |
| `AgentConversationsExports.swift` | Re-exports `AgentConversations` |
| `AgentWorkspaceExports.swift` | Re-exports `AgentWorkspace` |
| `ChatLiveTap.swift` | `ChatLiveTap` enum; `observe` (every turn's deltas and saved answer, for the phone) |
| `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop`; `TurnCheckpointScope`, serialized `TurnCheckpointWriter`; same-turn transcript/receipt recovery and finished-run cleanup |
| `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: `buildTurnContextWithHistory` (history and digest gathered for them turn part), `fireAssemblyStageEvent`, `injectingSessionDigest` |
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: runs their turn part's effects, hands it each event, logs at every host-call boundary), `joinedProse`; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed |
| `ChatOrchestration+ToolDispatch.swift` | Shared per-iteration tool dispatch and refusal of unoffered folded calls |
| `ChatOrchestration+ToolLoop.swift` | `TurnContext`: `withToolSchemas` |
| `ChatOrchestration+TurnEngine.swift` | `SwiftNativeTurnEngine`: gathers their turn part's reach (persona, pins, recall, packet, facts) and provider execution |
| `ChatOrchestrationClient+Attachments.swift` | image/document admission and voice evidence projection; audio remains an attachment, never a provider content block |
| `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `drainDeferredMemoryPromotion`, `chat`; `withCurrentChatModel` admits the current Chat pick once for a wake; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |
| `ChatOrchestrationClient+DispatchWrappers.swift` | `FileAccessGatedDispatcher` class; `preApprovalRefusal`, `approvalCardReason`, `sharedFileAccess`; `sharedChatFileAccess`; carries the chain's file access to the organs and refuses only an unrecognized mode and a pathful read under `none` (no tool-name lists; admission is posture × declared class in TrustCenter); declared part app-data reach approves matching read/write paths; `AutonomyGatedDispatcher` audit rows that fail are owed repairs |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn` |
| `ChatOrchestrationClient+Factories.swift` | `complete`, `makeChatOrchestrationClient`, `makeGatedToolDispatchClient`, canonical `makeResidentProviderLLMClient` shared by turns and background body work; stall-only calls share a transport without a resource wall; `SwiftNativeMemoryV2RecallingAdapter`: disclosure-aware recall and served-hit credit |
| `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`: `appendHumanConversationReply` |
| `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`: `reportTranscriptWriteFailure`, `persistPartialIfNeeded`, `appendToolMessage`, `correctSpeechTranscript` retains corrected faces with original recognition evidence |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `contextFingerprint`, `iso8601` |
| `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`: `chatStream`, `chatStreamExecution` |
| `ChatOrchestrationClient+StructuredChat.swift` | `SwiftNativeChatOrchestrationClient`: turn-bound carried offers before provider input; the turn's heard and answer experiences (the answer settles what the heard owed); `metacognitiveTerminalEvent`, `turnFailedEvent`, `turnCancelledEvent` |
| `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |
| `ChatOrchestrationClient+ToolReceipts.swift` | `SwiftNativeChatOrchestrationClient`: `persistToolReceipt` |
| `ChatOrchestrationClient+Types.swift` | `ChatOrchestrationClient` protocol; `drainDeferredMemoryPromotion`, `enqueueUserMessage` |
| `ChatSessionWork.swift` | Re-exports `ChatSessionWork` |
| `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |
| `ChatToolRuntime.swift` | Re-exports `ChatToolRuntime`, `ChatTurnContracts` |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`: `chat` |
| `ChatTurnSteering.swift` | `ChatTurnSteering` actor; open turns and turn-activity clock; atomic resident claim/reservation under the common free-time law; person admission opens immediately |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ConversationPrefixSeeding.swift` | `ConversationPrefixSeeding` enum; `isOpenAIResponsesLane`, `delivery` |
| `FirstRunWelcomeTransaction.swift` | `FirstRunWelcomeTransaction` class; `hasConversationRows`, `isPersistedFailureRow` |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |
| `MacChatRetrySnapshot.swift` | `MacChatRetrySnapshot` struct; `capture`, `stillMatchesLocal` |
| `MacChatSessionTransactions.swift` | selection intent/transactions, load-completion waiter and running-session navigation |
| `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator` actor; `consume`; changed-text publication retires while idle and restarts on deltas |
| `MacChatStreamAdapter.swift` | `MacChatStreamAdapter` enum; `stream`, `bridgeChatStreamEvents` |
| `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |
| `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |
| `MacChatTurnLifecycle.swift` | `MacChatTurnTerminalEvidence` enum |
| `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`: `beginChatTurnLifecycle`, `applyChatTurnLifecycleInput`, `receiveChatTurnActivity` |
| `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |
| `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry`, `settleMacChatRetry` |
| `MacChatTurnRuntime.swift` | Canonical Mac admission and lifecycle/Send-next projection; async queue transitions persist through `MacChatTurnLifecycleStore` |
| `VoiceInputCapture.swift` | consent-driven native microphone lifecycle; shared SpeechUtterance recognition and original audio travel through existing chat attachments |
| `MacChatTurnStreamConsumer.swift` | `MacChatTurnPresentationPort`: `consumeMacChatStream` |
| `MacChatTurnStreamSettlement.swift` | `MacChatTurnPresentationPort`: `completeMacChatStream`, `joinFailedMacChatStream`, `settleMacChatStream` |
| `MindMemoryManager.swift` | `MindMemoryManager` struct; `interpret`, `relevantRecallIDs`; incremental ranked evidence and catalog-budgeted relevance batches |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` |
| `StandingBotContinuity.swift` | `StandingBotContinuity` enum; `session`, `reply` |
| `SwarmChatClientFactory.swift` | `NativeSwarmChatClientFactory` struct; `makeClient` |
| `SwiftToolDispatcherConstruction.swift` | `SwiftToolDispatcher`: extension |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolLoopSupport.swift` | `ToolLoopTraceObservation`, `ToolDispatchDeadline`, `ToolLoopNoProgressGuard` |
| `TurnEngineContracts.swift` | `TurnContext` value projections with module-scoped setters and immutable admitted routing; `TurnEngineResult`; `SharedAdaptiveMemoryPromoter`: full turn evidence and telemetry |
| `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |
| `TurnPart.swift` | `TurnPart`: their turn as a part (`abilities/turn.js` `step(state, event)`) in one held helper per turn (a helper short of resources is an observation retried on the helper backoff until Stop; any other start failure ends the turn with its fix), version choice and seed install, the effect queue, the turn's event log and reconstruction for resume and heal; `provider_failure` carries the repair's callable input, permits explicit `app` repair calls through the ordinary dispatcher or a re-issued `model.call`, and can end incomplete without healing an authored part; compare-and-swap heal in one store transaction |
| `TurnSettle.swift` | `TurnSettle` enum; `requestedResultIntent`, `waitingOnCard` |
| `TurnRequest.swift` | `TurnRequest`: shared turn binding; `TurnAdmission`: per-session serialization, bounded admission queues and release/cancellation capacity signals for durable arrivals |

### ChromeControl

Directory: `Modules/NativeAgentCore/Sources/ChromeControl/`

| File | Owns |
|---|---|
| `ChromeExtensionFolder.swift` | extension completeness, staged replacement and registered-host refresh |
| `ChromeControlRuntime.swift` | `ChromeControlRuntime` actor; authenticated relay and extension attach readiness, manifest-backed extension versions and reconnect-confirmed self-reload; Chrome NativeAgent group membership is tab authority, user-touch ungroups a tab, each conversation remembers its last tab and rebuilds from the group; numeric tab addresses, per-tab reading views, snapshot/element/user-sequence safety and bounded mutation-backed page change streams; only explicit tab.close removes a tab; shutdown and reload leave all tabs open; connection transitions, relay diagnostics, extension errors and browser signature preflight remain |

### Cognition

Directory: `Modules/NativeAgentCore/Sources/Cognition/`

| File | Owns |
|---|---|
| `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`: `makeReplayIntegrationInput` |
| `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`: `considerStudioWander`, `studioWanderIsInstalled`, `studioWanderInstallationNow` |
| `StudioWanderLane.swift` | `StudioWanderLane` enum; installation, eligibility, carried-hour state and prompt for studio wandering |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime` actor; `rememberNonLiveTurnKind`; Desk candidates/approval context publish together with the read's Desk revision, checked at turn and wake admission; generation orders refreshes; observes Experiences for carried wait settlement, caching only its last read to ignore unchanged replay events; settled live turns trigger one held-memory drain at idle |
| `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail` and runtime read models; shared affect validity and organism sample freshness/validity |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |

### CognitiveSubstrate

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`

| File | Owns |
|---|---|
| `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |
| `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadRestoreBundle`, `loadReceiptRecords` |
| `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore` actor; `backupForDoctor`, `saveNodes` |
| `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: `compileCapsule`, `compileFrozenCapsulePresentation` |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: `selectInnerLine`, `innerTakeawayCadenceKey`, `threadKindPhrase` |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `capsuleCadenceShouldSpeak` |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: `relationalWarmthBoost`, `isUserAuthored`, `conversationalAppraisal` |
| `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidatePendingCompletion` |
| `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistSnapshot`, `recordReceipt` |
| `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: causal `planReflectionChecked`, frozen per-cause peer/node provenance, judged reflection integration and receipts |
| `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`; schema status and dated REM resolutions share the inbox's decision snapshot by proposal identity; adoption requires its application claim; unmatched retained history stays explicitly unavailable, without persisting another status or resolution |
| `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: `setAblation`, `facultyMeasurementSnapshot`, `runResearchExperiment` |
| `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState`, `stringArrayValue` |
| `CognitiveSubstrate+Serialization.swift` | `CognitiveSubstrate`: `cleanedSessionId` |
| `CognitiveSubstrate+StandingViews.swift` | `CognitiveSubstrate`: `standingViewTermsMatch`, `createStandingView`, `normalizedStandingViewBody` |
| `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |
| `CognitiveSubstrate+ThoughtSeeds.swift` | `CognitiveSubstrate`: `boundedThoughtSeedSources`, `addThoughtSeed`, `decayThoughtSeedsInMemory` |
| `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate`: `metadataString`, `isConversationalPresenceStatement`, `isOperationalSubconsciousNoise` |
| `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead` |
| `CognitiveSubstrate.swift` | `CognitiveSubstrate` actor; `waitForMaintenanceTransition`, `beginMaintenanceTransition` |
| `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies` struct |

### CognitiveSubstrate/Organism

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`

| File | Owns |
|---|---|
| `CognitiveSomaticSignalAdapter.swift` | `CognitiveSomaticSignalAdapter` enum; `signal`, `safeSourceComponent` |
| `OrganismBodySchema.swift` | `ProviderPathEvidenceOutcome` enum |
| `OrganismCapabilitySelfModel.swift` | `OrganismCapabilitySelfModel` enum; `beliefs` |
| `OrganismChemistry.swift` | `OrganismChemistry` enum; `applying`, `dosedByCaringEvent` |
| `OrganismDreamRepair.swift` | `OrganismDreamRepair` enum; `applying`, `applyingResidualPressure` |
| `OrganismField.swift` | `OrganismField` struct; `summary`, `edge` |
| `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `admitAfterTurnReaction` |
| `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value` |
| `OrganismModels.swift` | `SomaticSignalKind` enum |
| `OrganismPrediction+Horizon.swift` | `OrganismPredictiveBody`: `applyingHorizonRefresh` |
| `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |
| `OrganismPredictionModels.swift` | `OrganismPredictionKind` enum |
| `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |
| `OrganismSignalBus.swift` | `SomaticSignalBus` actor; `observe`, `configure` |
| `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |

### Connectors

Directory: `Modules/NativeAgentCore/Sources/Connectors/`

| File | Owns |
|---|---|
| `LocalPIMConnectorActions+Authorization.swift` | calendar read/write authorization interpretation and EventKit permission prompts; wizard status |
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |
| `ConnectorActionReceipt.swift` | `ConnectorActionReceipt` struct |
| `ConnectorActions.swift` | `ConnectorActions` struct; `runConnectorAction`, `fullMacYoloAdmitted` |
| `ConnectorOAuthConfig.swift` | `ConnectorOAuthConfig` struct |
| `ConnectorOAuthRegistry.swift` | `ConnectorOAuthRegistry` enum; `mutateConnectorRegistryEntry`, `checkedConnectorRows` |
| `ConnectorRegistryActions.swift` | connector/workspace registry operations and ordered workspace readback verification |
| `ConnectorWizardActions.swift` | connector setup registration and verified skill OAuth route mapping |
| `Connectors+Auth.swift` | `SwiftNativeConnectorAuthClient`: `revokeConnector` |
| `GitHubOAuthCredentialPort.swift` | GitHub OAuth credential contract; canonical credential-store conformance |
| `LocalPIMConnectorActions.swift` | `LocalPIMConnectorActions` enum; `calendarListUpcoming`, `calendarCalendars`, `remindersListWrite` |
| `LocalPIMStore.swift` | concrete `LocalPIMStore` EventKit session; main-actor mutations, queue-confined reads |
| `NativeOAuthFlow+ConnectorCredentials.swift` | `NativeOAuthFlow`: `connectorOAuthAppCredentials`, `saveConnectorOAuthApp`, `saveNotionToken` |
| `NativeOAuthFlow+Connectors.swift` | connector OAuth flows and client credential validation |
| `NativeOAuthFlow+GitHub.swift` | `NativeOAuthFlow`: `saveGitHubToken`, `completeGitHubDeviceFlow` |
| `NativeOAuthFlow+Slack.swift` | `NativeOAuthFlow`: `saveSlackToken` |

### Context

Directory: `Modules/NativeAgentCore/Sources/Context/`

| File | Owns |
|---|---|
| `ContextSelection.swift` | `ContextSelector` struct; `select` |
| `ContextSelectionContracts.swift` | `ContextOriginClass` enum; `ContextPacketItem` retains memory untrusted sources through body/summary selection |
| `ContextMemoryLead.swift` | `ContextMemoryLead`: memory age, provenance and stored untrusted-source extraction |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`: bounded Markdown atom compilation and exact unchanged-source reuse; persona GROWTH uses the PersonaEngine episodic-log filter before hashing and parsing |
| `ContextFlowCoordinator.swift` | Immutable arena publication and trim rehydration; feedback replay reused only for matching generation, events and decay bucket; SQLite retains derived generations and ranking events, while turn traces own displayed receipts |

### ContextFlow

Directory: `Modules/NativeAgentCore/Sources/ContextFlow/`

| File | Owns |
|---|---|
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime` actor; `start`, `stop`; persona registrations and mirrors share a compiler batch |
| `NativeMemoryContextProjection.swift` | `NativeMemoryContextProjection`: canonical memory projection, including immutable untrusted-source entities and source hashes |
| `NativeContextProjectionText.swift` | `NativeContextProjectionText` enum; `clean`, `bounded` |
| `SensesContextProjection.swift` | `SensesContextProjection`: four bounded unread `news` atoms from `SenseNewsBoard`, reconciled before turn selection, separately rendered and acknowledged only on provider output; expiry/seen exclusion also protects retained generations |

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

| File | Owns |
|---|---|
| `SenseTurnReads.swift` | `SenseTurnReads`: bounded turn-local served-version evidence |

### Desk

Directory: `Modules/NativeAgentCore/Sources/Desk/`

| File | Owns |
|---|---|
| `DeskParking.swift` | `DeskDeferPreset`; deferred-work interpretation |
| `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |
| `DeskProjection.swift` | `DeskBoardLayout`, `DeskPaletteRow`, `DeskPaletteQuery`, `DeskFuzzy`, `DeskPaletteCommandApplication`, `DeskQuickAction`, `DeskRefAction`, `DeskRefAffordance`; attention, freshness and date interpretation |
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation` struct; `receiptIsUnresolved`, `toJSON` |
| `DeskModels.swift` | `DeskStatus`: `DeskKind`, `CadenceMode`, `NotifyLevel` |
| `DeskOperations.swift` | `DeskOpBody` enum; `updateTitle` optionally replaces refs with the same replayable summary update |
| `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |
| `DeskStore.swift` | `SwiftNativeDeskStore` struct; process-wide `currentRevision` advances before and after each awaited canonical append under the ops lock; `continuation`, `setContinuation`, `heldBy` (nonacquiring hold read); keyed system findings persist findingKey through create, compaction and archive, preserve closure and person ownership under their filing lock; explicit reopening refreshes evidence in that transaction or files anew after archive, with opt-in ref replacement on the same `updateTitle` op |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `MyQueue.swift` | `MyQueue` enum; `entries`, `add`, `isReady`; `Entry.owedToPerson` derives reply obligation from recorded origin, independent of readiness and taint |

### DeviceSync

Directory: `Modules/NativeAgentCore/Sources/DeviceSync/`

CloudKit chat and notification delivery records become eligible for deletion
after 14 days (`CloudKitDeviceTransport.retentionWindow`). Phone catch-up uses
snapshots bounded to **16 sessions**, the last **80 messages** per session and
the first **6,000 characters** of each message (plus a truncation marker),
subject to a **2 MiB** transcript group budget and transport limits, enforced
by `MacSyncEngine+Snapshots.swift`. Older missed content may remain unavailable
on the phone; Mac transcripts are unaffected.

Both inbound chat transports reserve the authenticated envelope in local
`icloud/chat_transactions` before starting a turn. Interrupted reservations
produce a correlated unknown-outcome reply without redispatch. The existing
archive owner retains terminal chat and action rows for 30 days on both
transports and bounds local rejected envelopes to seven days / 50 MiB.
The snapshot integrity pass also retries persisted skipped groups without
requiring a retained digest. Live Activity start reservations retain their
expiry and are retired after a day only when no eligible start or token remains.
Permanent APNs activity-token rejections remove the token without releasing the
start reservation. Mac Integration permissions ride in the core CloudKit snapshot
as a canonical read projection. Generated phone replies carry JPEG previews
sharing the chat record budget; full image artifacts remain on the Mac.

Mac receive deadlines exist only for live reply/request obligations, active
phone turns, the 120-second peer-activity window, or push that is unavailable
or not yet proven by a received CloudKit push in this process. Otherwise the
drain has no timer and its OrganPulse is off/resting. Launch, CloudKit push,
KVS message nudge, wake and network regain drain incoming work. Phone delivery
owns a pairing-scoped durable map of unaccepted record identities and renews
those original records on an eight-second deadline while iOS grants execution.
Verified correlated Mac progress/replies/action responses retire that ownership;
messages with no answer use the same signed progress path for acceptance.
The query projection clock can advance on renewal; the signed timestamp cannot.
Older phones do not renew: a lost push waits for the next real receive change,
with their existing waiting/no-update UI and signed expiry refusal preserved.

`MobileSnapshotBuilder` owns snapshot encoding and post-history session-index
reads. Heavy snapshot reads start together; publication retains its ordering.

| File | Owns |
|---|---|
| `CKLandmine.swift` | CloudKit entitlement probes, guarded account-status projection and `withCKTimeout` |
| `DeviceSyncHost.swift` | `DeviceSyncHost` protocol; `helpersSnapshot`, `helperAction` |
| `ICloudIncomingTurnForwarder.swift` | `ICloudIncomingTurnForwarder` struct; `redactedRemoteErrorDetail`, `iCloudChatFileAccess` |
| `ICloudIncomingTurnPort.swift` | `ICloudIncomingTurnPort` protocol; `residentChatClient`, `publishReply` |
| `ICloudTextDeltaCoalescer.swift` | `ICloudTextDeltaCoalescer` struct; `push`, `flush` |
| `MacSyncActionRouter+ChatHistory.swift` | `MacSyncActionRouter`: `chatHistoryPage` |
| `MacSyncActionRouter+Connectors.swift` | `MacSyncActionRouter`: `connectorAction` |
| `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |
| `MacSyncActionRouter+Providers.swift` | `MacSyncActionRouter`: `configureEncryptedProvider`, `startProviderSignIn` |
| `MacSyncActionRouter+Scheduler.swift` | `MacSyncActionRouter`: `schedulerAction` |
| `MacSyncActionRouter+Telegram.swift` | `MacSyncActionRouter`: `telegramAction` |
| `MacSyncActionRouter+Trust.swift` | `MacSyncActionRouter`: `applyTrustAction` |
| `MacSyncActionRouter+TrustCommand.swift` | `MobileTrustAction`: checked trust writes |
| `MacSyncActionRouter.swift` | `MacSyncActionRouter` struct; `surfaceSelection` |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | `MacSyncEngine`: `authenticateInboxFile`, `startInboxQuery`, `quarantineUnauthenticatedInboxFile` |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`: `startCloudKitSnapshotProjection`, `start`, `stop` |
| `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |
| `MacSyncEngine+NeedsUserNotify.swift` | `NeedsUserEdgeNotifier` actor; `evaluate`, `stableDigest` |
| `MacSyncEngine+Notifications.swift` | `MacSyncEngine`: `sendNotificationToPairedDevices` |
| `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |
| `MacSyncEngine+Security.swift` | `MacSyncEngine`: `beginPairingSecretRotation`, `finishPairingSecretRotation`, `actionResponse`, `signedResponse` |
| `MacSyncEngine+Snapshots.swift` | `MacSyncEngine`: `writeSnapshots`, `encodeSnapshot`, `publishChangedSnapshots`; phone turn summaries read directly from `TurnTrace` |
| `MacSyncEngine+Storage.swift` | `MacSyncEngine`: `recordProcessed`, `restoreState`, `cappedPreservingMarkers`; consolidated replay/digest restoration and device bookkeeping await the shared `DeviceSyncStorage` actor in `DeviceSync.swift` before admission/acknowledgement |
| `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |
| `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`: `startWorkActivityObservation`, `projectWorkshopWorkActivities`, `requestWorkActivityPublication` |
| `MacSyncInboxAction.swift` | `InboxAction` struct |
| `MacSyncMobileNotificationRelay.swift` | `MacSyncMobileNotificationRelay` struct; `storePushToken`, `storeWorkActivityRegistration` |
| `MacSyncRemoteMacControl.swift` | `MacSyncRemoteMacControl` struct; `dispatch` |
| `MacSyncRemoteMacControlPort.swift` | `MacSyncRemoteMacControlPort` protocol; `loadTrustPolicy`, `run` |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `open` |
| `iCloudBridge+DeliveryReceipts.swift` | `iCloudBridge`: `appendChatDeliveryReceipt`, `appendActionResponseDeliveryReceipt`, `appendInboundSuccessReceipt` |
| `iCloudBridge.swift` | `iCloudBridge` class; `setup`, `recordCloudKitPushEvidence` (data-root-scoped chat-subscription push proof; subscription failure or unannounced aged delivery revokes), `scheduleNextDeviceDrainFallback` (obligations or push unavailable/unproven; idle rests), `cloudKitActionResponseMessage` (sending and sizing), `failedReplyClaims` (startup snapshot or exact delivery event) |

### Dispatcher

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/`

| File | Owns |
|---|---|
| `Dispatcher.swift` | `DispatchResult`, read-only `SwiftNativeDispatcher` with a fail-closed writable-handler boundary, `makeDispatcher`; `dispatchSlashCommand` |
| `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `dispatchNativeAction` uses `LocalConnectorActions.nativeReadOnly` |

### Dispatcher/Actions

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/Actions/`

| File | Owns |
|---|---|
| `FileSystemActions.swift` | `FileSystemActions` enum; `resolvePath`, `allowedRoots`, part app-data reach and retained private/authority-store exclusions, shared mutation fences and reversible `trashFile`; version-checked line scanning owns file/log query selection, positions, full-source coverage and source continuation; `fileInfo` reads descriptor-bound metadata without following the final link; `listDir` owns budgeted allocated disk usage with named partial results; `gitLog`/`gitDiff` own dated repository reads; shared Git status parsing and process capture/settlement for Foundation and descriptor-pinned launches; `FileReadSourceMaterial` descriptor-only source port |
| `LocalConnectorActions.swift` | Canonical file/system handlers and verification flags; `nativeReadOnly` selects the exact seven native/slash tools |

### DoctorChecks

Directory: `Modules/NativeAgentCore/Sources/DoctorChecks/`

| File | Owns |
|---|---|
| `TurnTraceWindowReader.swift` | Measurement-window policy and coverage through canonical TurnTrace framing |
| `DoctorRunsInspectorChecks.swift` | Inspector health verdict from primitive subscription state; repair eligibility |
| `SupportDiagnostics.swift` | support diagnostics read model |
| `DoctorActionRuntime.swift` | `DoctorActionRuntime` struct; `safeDetail`, `mergeReport` |
| `DoctorChecks.swift` | `SwiftNativeDoctorChecks` actor; `makeDoctorChecks`, `runAll`; CheckResult carries the owner, bound repair call or personal control and its experience projection |
| `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |
| `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |
| `DoctorStatusProjection+Config.swift` | `AutoDoctorConfig`; `DoctorStatusProjection`: `readAutoDoctorConfig`, `boolValue`, `intValue` |
| `DoctorStatusProjection+Hardening.swift` | `DoctorStatusProjection`: `getProductionHardening` |
| `DoctorStatusProjection.swift` | `DoctorStatusProjection` enum; `makeHealthCard`, `persistDoctorSnapshot`, `recordReadings`, `repairProjection`; Experiences owns repair obligations and settlement, while Doctor owns the measured postcondition |
| `ProductionHardeningSummary.swift` | `ProductionHardeningSummary` struct |
| `ReleaseChecklist.swift` | `ReleaseChecklist` struct |

### DreamREMCycle

Directory: `Modules/NativeAgentCore/Sources/DreamREMCycle/`

| File | Owns |
|---|---|
| `DreamCycleContracts.swift` | `DreamTrigger` enum |
| `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`: `gatherRecentMessagesAcrossSessions`, `feltRankIndex`, `parseDaemonISO` |
| `DreamCycleRunner.swift` | `DreamCycleRunner` actor; `runNightlyDreamCycle`, `moodLine` |
| `DreamPayload.swift` | `DreamPayload` struct |
| `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |
| `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |
| `REMConsolidator.swift` | `REMConsolidator` actor; `runWeeklyREM` shares one checked diary window with distillation, filters a fresh tombstone batch and resolves committed causal refs for reflection; `rankedByRecurrence` |
| `REMPinsReader.swift` | `REMPinsReader` enum; `read`, `latest` |
| `REMReport.swift` | `REMReport`, `REMRunReportPayload`; manual completion counter validation |

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

| File | Owns |
|---|---|
| `WorkOverviewRead+Today.swift` | `TodayRow`, `TodayWords`, `TodayDreamDigest`, `TodaySnapshot`, `TodayCollaboration`, `TodayEarlierNote`, `WorkOverviewRead` |
| `EngineApprovalNotifications.swift` | `ApprovalNotificationDelivery`: approval discovery, pending-state selection and notification delivery coordination |
| `TranscriptReadProjection.swift` | transcript/read caches, conversation and running-session routes, turn card/trouble projection, opening line and naming |
| `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`: native owner-response interpretation, approval reread and composer admission |
| `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery's install observation starts independently at launch; trusted bundled seeds installed as current before ingress, any existing slot preserved, each failure retained by AbilityFilesCheck and routed through Doctor to the builder while launch continues; root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, background loop manifest and surface/workshop/scheduler composition; native effects arrive through EngineBackgroundWorkHost |
| `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceiptProjection`; Shared context trace/receipt facts and checked Composer receipt reader |
| `AgentContactRow.swift` | Contact row policy and detached dispatcher/credential/thread assembly; contact restrictions, canonical identity and health folding for the composed contact facade; candidate setup failures survive identity folding and take precedence over health; contact-read failures reach the view's loadError |
| `EngineContactThreads.swift` | Contact snapshots, conversation/flight reads and cache validation |
| `EngineContactCommands.swift` | Person-initiated sends, verified-session stop commands and held-message withdrawal through engine dispatch; Contact sends/stops and core bridge/A2A construction over injected engine and GitHub owners |
| `EngineDeviceSyncHelpers.swift` | Phone helper edit validation, revisions, provider pin/follow semantics and contact commands; Phone helper/contact actions and Bots shelf policy/provider/run join |
| `ConnectorStatusProjection+LocalIntegrations.swift` | connector platform actions, EventKit status, proof cache, local PIM and phone readiness; connector proof cache, local PIM and phone push readiness, action evidence |
| `ConnectorStatusProjection+Actions.swift` | connector action registry, records and checked capability statuses |
| `ConnectorStatusProjection+Mobile.swift` | mobile connector projection and commands |
| `MacIntegrationDeliveryActions.swift` | Mac integration protocol execution, scheduler and Spotlight routing, Mac/phone envelopes and phone result routing with checked pairing before transport; Mac/phone notification tool receipts and the native MacControl notification adapter |
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |
| `ChatModels.swift` | `ChatMessage`: `NativeAppChatMessage`, `ChatMessageMetadata`, `CodingKeys` |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `ConnectorRecord.swift` | `ConnectorRecord`, `ConnectorActionRecord` and descriptor readiness projection |
| `ConnectorStatusProjection.swift` | `ConnectorStatusProjection` enum; `connectorRowWithRuntimeOverlay`, `readConnectorRecords`, `updateConnector`; connector pages share decayed action/HTTP receipt evidence, including Slack's Web API reads |
| `DefaultReasoningEffortOptions.swift` | `defaultReasoningEffortOptions` |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `DoctorEmbeddingDownloadCheck.swift` | `DoctorFacade`: embedding download health reading |
| `DoctorProviderPathReading.swift` | `DoctorProviderPathReading` enum; checked active-provider route and injected platform probe |
| `EngineApprovals.swift` | `ApprovalsFacade`: approval state, single-flight resolution and outcome/preflight checks; production Slack/AgentMail external-send bindings; `ApprovalRecord`: `ApprovalsFacade` |
| `EngineCognitionModels.swift` | `CognitionProposalsFeed` enum; `CognitionProposalsFeed`; `DreamRunResult` completion and status interpretation |
| `EngineCognitionView.swift` | `CognitionViewFacade`: refresh state and `LatestAsyncRequestGate`; `DreamDiary`: diary entry reads go directly through `FileBackedDreamDiary`; CognitionViewFacade snapshot admission, Living Status watched paths and coalesced refresh coordination; `CognitionViewFacade`: composite observatory reads, refresh state and `LatestAsyncRequestGate`; `DreamDiary`: diary entry reads go directly through `FileBackedDreamDiary` |
| `EngineDesk.swift` | `DeskFacade`: `loadBoard`, `loadOverview`, `taskRows`, scheduler mutation/default repair/publication; parallel independent reads and shared checked overview/phone authority lanes; `DeskToolInvoking`, `DeskToolDispatchRouter`, `DeskActionOutcome`, `DeskActionResultReader`; gated command routing and resident-hour reads; DeskFacade, DeskToolDispatchRouter.perform, native execution admission, page reads and Workshop veto mutation; `DeskFacade`: `loadBoard`, `loadOverview`, `taskRows`; parallel independent reads and shared checked overview/phone authority lanes; `DeskToolInvoking`, `DeskToolDispatchRouter`, `DeskActionOutcome`, `DeskActionResultReader`; gated command routing and resident-hour reads |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeskReadModels.swift` | Desk movement, live activity, program-family eligibility and execution slices; `DeskPageSnapshot`, `DeskPageContent`, `DeskAttentionStrip`, `DeskGitHubBucket`, `DeskGitHubWaitingRollup` and `DeskPageWords`; Desk movement/activity projections and WorkStatusPublication; each AppModel retains its own publication/coalescing lifetime and supplies only WidgetKit reload; Shared DeskPageContent facts, project/deadline projection and execution verification values |
| `EngineDoctor.swift` | Doctor observable state, run outcome and tool status envelope; `WatchdogStatus`: `DoctorFacade`, `DoctorReport` |
| `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`: cognition health and repair |
| `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`: one launch refresh after a persisted terminal turn trace |
| `EngineDoctor+StatusChecks.swift` | `DoctorFacade`: Desk attention and activity status checks |
| `EngineDoctorRuntime.swift` | `EngineDoctorRuntime`, `EngineDoctorPlatformPort`; live health interpretation, repair admission and pending-transition wake ownership; `EngineDoctorRuntime`, `EngineDoctorPlatformPort`; live health interpretation, repair admission, Support Snapshot result reuse and pending-transition wake ownership |
| `EngineInbox.swift` | Inbox facade, card action/proactive projections and OwnerAttentionPolicy prominence; newest physical row per stable card id; `InboxItemRecord`: `InboxFacade`; proactive `triggers`, `setTrigger`, `configureTrigger` |
| `EngineMCPActions.swift` | `MCPUIActionAuthority`: `runtime` |
| `EngineMemory.swift` | `ProposalRecord`: `MemoryFacade`; `graphView`, `searchGraph`, `KnowledgeGraphViewRead`; `MemoryFacade`: proposal read status, durable review-reminder crossing, `graphView`, `searchGraph`; `ProposalRecord`, `KnowledgeGraphViewRead` |
| `EnginePartWake.swift` | `EnginePartWake`: one signal-to-part index checked on delivery and rebuilt on part changes, cleared on unreadable authority with source-preserving repair owed; delivers `AbilityStore.signalled` and a turn's terminal row (`turn.ended`) to each part whose header `wake` lists it, one run at a time per part, while the owner's Autonomy switch allows: tools and skills through the door on a wake run's own gate chain (their resident session, current Trust, signal origin, stranger taint, the part bound so its cards wait), senses through their resident owner; every run binds the turn client's current admitted Chat model and the wake signal for model-call audit; `file.changed:` through the senses' watch, waiting through the file's absence, with the part's own writes (stamped as it left them) suppressed; installs the turn-end steer over the turn's own taint |
| `EnginePresentationModels.swift` | `TelegramPresentationSnapshot`: `TelegramVoiceTranscriptionStatus`, `TelegramReceipt`, `CodingKeys`; Shared route vocabulary, SidebarItem, PageTab, UserDisplayFormatters and temporal/receipt presentation values; transport snapshots; shared inline card vocabulary/projection and setup fields; identity grammar, tool summaries and message provenance |
| `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |
| `EngineProviderHelpers.swift` | `ProvidersFacade`: checked settings refresh, credential verdicts, provider/model/inheritance/readback selection, auth normalization and CLI credential transactions; `ProvidersFacade`: `readModelRoutingConfig`, `stringValue`; ProvidersFacade routing reads, model grouping/cache/effort eligibility and quiet provider policy |
| `EngineProviders.swift` | `ProvidersFacade`: `connections`, `modelCatalog`, `list`, `configureProvider`, `saveSurfaceSelection`; presentation and writes over ProviderRouting |
| `EngineDeviceSync+Snapshots.swift` | Phone snapshot/action adapter, memory-proposal Codable projection, signed incoming-turn delivery and handoff ordering; native presentation and cross-area assembly arrive through ports |
| `EngineProviders+Adoption.swift` | blank-surface provider adoption, connect/consent sequencing and serialized chat-brain save generation/rollback |
| `EngineProviders+Probe.swift` | `ProvidersFacade`: `testProvider`, `clearProvider` |
| `EngineRouteError.swift` | Engine route failures and shared UserFacingError interpretation |
| `EngineSync.swift` | `SyncFacade` class; `observeStatus`, `setStatus` |
| `EngineTelegram.swift` | Telegram facade and tool status envelope; `TelegramFacade` class; `configuration`, `loadStatus`, `load` |
| `EngineTelegram+Commands.swift` | Telegram configuration and mobile commands; Telegram token admission, settings and delivery commands, typed diagnostic-clear receipt |
| `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |
| `EngineTools.swift` | ToolsFacade: tools/MCP state, slash manifest projection and planning, post-write verification |
| `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands` struct; skill/tool commands, approval filing and decision receipts; `CapabilityCommandOutcome` invalidates UI projections |
| `EngineTurnContinuation.swift` | `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; completion destination recovery uses the bound engine and attention router; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders; `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders |
| `EngineTranscripts.swift` | `TranscriptsFacade`: per-session observable structure slots, `messages`, `setMessages`, `streamingTailBox`, presentation index warming, first-conversation receipt/person lookup; `ChatTranscriptCache`: off-main shell reads and shared file-identity cache for transcript projections and raw context statistics; TranscriptsFacade per-session structural slots; ChatTranscriptCache and CommandPaletteMessageIndex saved transcript reads; observable transcript slots/cache, session transactions/unread accounting, stream/resume/settlement, mutation, session naming and slash execution |
| `EngineTrust.swift` | Checked `TrustFacade`; `loadCapabilities`, `load`, backup read publication; capability `catalog`, `catalogSources`, `packInstalls`, `saveCatalogSource`; inbox enabled policy read/patch; `TrustFacade` class; `loadCapabilities`, `load`; capability `catalog`, `catalogSources`, `packInstalls`, `saveCatalogSource` |
| `EngineTurns.swift` | `TurnsFacade` class; `lifecycle`, `screenPreview`; TurnsFacade lifecycle/screen preview/busy predicate; compaction, slash dispatch and workshop session composition |
| `EngineWorkshopObservatory.swift` | `WorkshopScoreView`, `DeskPursuitVetoRationale`; Workshop read projections |
| `LatestAsyncRequestGate.swift` | `LatestAsyncRequestGate` struct; `begin`, `accepts` |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `MacChatScreenPreview` struct; `merged` |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |
| `NativeAgentEngine.swift` | Core live/isolated root selection, chat/tool composition and resident service facades |
| `NativeAgentEnginePorts.swift` | Once-installed native host factories, body effects and shared EngineCognitionHost defaults |
| `NextGenStatusModels.swift` | `NextGenSummary` struct |
| `NextGenStatusProjection.swift` | NextGen snapshot, phase projection and receipt merge |
| `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |
| `PersonalityGrowthSummary.swift` | `PersonalityGrowthSummary` struct |
| `RuntimeReadProjection+Feeds.swift` | `RuntimeReadProjection`: `getNotificationStatus`, `getBrowserStatus`, `skills`, `runs`, `tailJSONL` |
| `RuntimeReadProjection+Improvement.swift` | `RuntimeReadProjection`: `swiftImprovementGauntlet` |
| `RuntimeReadProjection+Personality.swift` | `RuntimeReadProjection`: `swiftPersonalityGrowth` |
| `RuntimeReadProjection+QuietPages.swift` | quiet page and item read projections |
| `NextGenActionExecution.swift` | capability action probes and execution receipts |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadProjection`: `getTraces`; `RuntimeReadError` enum |
| `RuntimeReadProjection.swift` | `RuntimeReadProjection` enum; `getSessionContext` |
| `RuntimeSummaryModels.swift` | `KernelGuardrail` struct |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SurfaceRuntimeStatusModels.swift` | `NotificationRuntimeStatus` struct |
| `TolerantDisplayStringDecoding.swift` | `JSONValue.nextGenDisplayString` |
| `WorkOverviewRead.swift` | `WorkOverviewRead` enum; `project`, `text`; complete owner-attention counts by reference kind before mobile list bounds |

### GitHubConnector

Directory: `Modules/NativeAgentCore/Sources/GitHubConnector/`

Direct GitHub HTTP reads append transport verdicts to the shared connector-action
proof ledger. `FeedPolicy` supplies that ledger's existing retention budget;
connector surfaces continue to read `ConnectorStatusProjection`.

| File | Owns |
|---|---|
| `GitHubApprovalNotify.swift` | `GitHubApprovalEdgeNotifier` actor; `evaluateSnapshot` |
| `GitHubCommandLiveStateMemo.swift` | `GitHubCommandLiveStateMemo` actor; `value`, `prime` |
| `GitHubCommandModels.swift` | `GitHubCommandItemKind` enum |
| `GitHubCommandRuntime.swift` | `GitHubCommandRuntime` actor; `replayResidentStateAtLaunch`, `recoverAtLaunch` |
| `GitHubCommandStore.swift` | `GitHubCommandStore` struct; `liveState`, `memoKey` |
| `GitHubProjectTracking.swift` | `GitHubConnectorActions`: `search`, `listPullRequests`, `getIssue` |
| `GitHubRepositoryReading.swift` | `GitHubConnectorActions`: bounded repository, notification, commit, workflow-run and failed-job reads |
| `GitHubToolProjection.swift` | `GitHubToolProjection`: compact provider-facing GitHub read models |
| `GitHubTrackingModels.swift` | `TrackedRepository` struct; `fromJSON` |

### KnowledgeGraph

Directory: `Modules/NativeAgentCore/Sources/KnowledgeGraph/`

| File | Owns |
|---|---|
| `KnowledgeGraph+CanonicalRebuild.swift` | `SwiftNativeKnowledgeGraphIndexer`: `rebuildMemoryDerivedGraphFromCanonicalStore`, `reconcileMemoryIndexFingerprints` |
| `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact`; ID-only canonical indexing and generation/mode-fenced projection reconciliation |
| `KnowledgeGraph+PrimaryUserIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: shared `profileNames`, `resolvePrimaryUserName`, `consolidatePrimaryUserEntities`, `removeUnreferencedPrimaryUserRole` |
| `KnowledgeGraph+SQLite.swift` | Checked prepared-pool boundary and shared entity/edge serialization for canonical graph reads and legacy import; batched entity reads retain per-entity relationship limits and failures in one transaction |
| `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: one checked backend admission for bounded single and batched SQLite reads, optional entity enrichment and immutable legacy snapshots |
| `KnowledgeGraphTypedRead.swift` | Typed checked projections on `SwiftNativeKnowledgeGraphReader` |
| `KnowledgeGraphProjectionModels.swift` | `AgentGraphNode` struct |
| `KnowledgeGraphReadProjection.swift` | `KnowledgeGraphReadProjection` enum; `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData` |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractEntities`, `taggedNameIsCredible` |

### MCPDispatcher

Directory: `Modules/NativeAgentCore/Sources/MCPDispatcher/`

| File | Owns |
|---|---|
| `MCPActionModels.swift` | `MCPConsentRecord`, `MCPResource` structs |
| `MCPDispatcher.swift` | `SwiftNativeMCPDispatcher` actor; checked registry and byte-preserving `repairRegistry`, checked consent storage, selected-server identity validation and shared `ToolAdmission` decisions for chat and UI; each surface retains refusal/card presentation |
| `MCPSubprocess+LiveCache.swift` | Shared tools/resources discovery and generation-fenced live cache; tools alone publish the persisted catalog |
| `MCPSubprocess+Pool.swift` | Generation/identity-fenced subprocess ownership, crash backoff and one idle-deadline arming path |
| `MCPSubprocess+Process.swift` | Stdio framing, native writes and remove-once RPC waiters owning their cancellable deadlines |
| `MCPResultEvidence.swift` | MCP result evidence and Activity receipt reads |
| `MCPUIActions+Registry.swift` | `MCPUIActions`: consent and inventory reads; one warm/restart/refresh command result keeps completion separate from inventory failures and reaches both the tool adapter and Hub without inferring status from UI text |
| `MCPUIActions.swift` | MCP configuration actions, input schema validation and argument conversion |

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: `mailListRecent`, `mailSearch`, `mailSend`, `mailDraft` |
| `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: `mailWorkspaceRead`, `mailReadScope`, `mailIndexDatabase`, `mailSenders` (exact grouped sender counts), `mailFileRead`, `mailAttachment` (paired-identity .emlx bodies, MIME/table decoding and local attachments) |
| `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: `messagesRecentThreads`, `messagesSend`, `notesModify` (exact-note update or reversible deletion) |
| `MacAppleScriptBridge+Music.swift` | `MacAppleScriptBridge`: `musicSearchLibrary`, `musicListLibrary`, `musicListPlaylists` |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`: delegates `runAppleScript` to MacControl, skill hand-back and integration envelopes; `isMusicNoCurrentTrackError`, `deniedEnvelope` |
| `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in SystemAppleScriptAdapter |
| `MacContactsExecutor.swift` | concrete `CNContactStore` ownership, authorization, selection, mutation validation, name cache and projection |
| `MacMessagesHistory.swift` | protected Messages-directory access probe, bounded SQLite reads and folded matching |
| `MacMessagesTypedString.swift` | bounded attributed-body archive decoding |

### MultimodalTTS

Directory: `Modules/NativeAgentCore/Sources/MultimodalTTS/`

| File | Owns |
|---|---|
| `MultimodalTTS+VoiceSelection.swift` | voice authority/routing, native/cloud playback, generations/cancellation, voice preference and auto-read decision |

### MacControl

Directory: `Modules/NativeAgentCore/Sources/MacControl/`

| File | Owns |
|---|---|
| `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |
| `MacControl+Adapters.swift` | System adapters, bundle-specific AppleScript/JXA Automation targets and permission status; execution-boundary translation of shared process-pipe setup errors |
| `MacAppIndex.swift` | One in-process live Spotlight metadata query over local volumes; rows excluding bundles inside packages materialize only on gathering/update edges on its owning queue; sync/async reads and exact lookup share kept rows; newest-only edges emit when bundle id/version/path changes; actionable index failures propagate; `mac.apps` names its Spotlight source; Launch Services remains the launch fallback after an index miss |
| `MacAXAttributeRead.swift` | `MacAXAttributeRead` enum; visible list/table/outline child ordering shared by reads and action paths, on-screen/total counts; `copyTextRange`, `copyRaw`, `copyWindowIdentity`, shared identity `copyLabel` retaining redaction captions, separate display names with help cleanup and explicit AX title-element captions |
| `MacScreenPageCompiler.swift` | `MacScreenPageCompiler` enum; complete nested AX reading order, structural/activation alias folding, adjacent checkbox captions in structured and aggregate documents, document title ownership, sentence-first links including aggregate document text, AX landmark and card sections, live-region text with duplicate container folding, display cleanup after full-context redaction, composite rows with status details and exact related-action bindings |
| `MacAppSourceEvents.swift` | `MacAppSourceEvents` class; event-backed running-app AX observation, coalescing, cancellation and notification-stall completion for cold reads |
| `MacAppWindowText.swift` | `MacAppWindowText` enum; one positional-redacting on-device recognizer for current app-window capture and ephemeral whole-window shots before text-only retention |
| `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |
| `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactionConfig`, `VisionRedactedText`; one positional caption/overlap redaction boundary for both OCR readers |
| `MacAccessibilityActuator.swift` | `MacAccessibilityActuator` enum; `act` |
| `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |
| `MacControl+Client.swift` | `SwiftNativeMacControl` actor; `dispatch`, `dispatchApprovedInjection`; `MacObservationMode` carries passive read authority without motor binding, wake, capabilities or desktop effects |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl`: `handleAct`, `pointerRestoredJSON` |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: `waitForTextInput`, `handleHand`, `watchedWindowMiss` (a watch's events land on its window, read at each event), `handleNudge` |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`: `handleMenu`, `handleMenuPress`, `handleClipboardRead` |
| `MacControl+OperationSupport.swift` | `SwiftNativeMacControl`: `attachingOperation`, `replayResult`, `unknownResult` |
| `MacControl+Perception.swift` | `SwiftNativeMacControl`: `handleRead`, `documentPath`; semantic view masks pixels from the complete AX snapshot's secret frames before sharing |
| `MacControl+SystemActions.swift` | `SwiftNativeMacControl`: `handleFileRead`, `handleFileWrite`, `handleFileList`, `handleMedia` (Now Playing system keys and running-player observations) |
| `MacControlActionRoutes.swift` | Mac control dispatch receipts plus workbench availability and category policy |
| `MacFourVerbs+Act.swift` | `MacFourVerbs`: `act`, `addAttention`, `frontChangedWords` |
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `webURL`; landing targets the recipient returned by Launch Services |
| `MacFourVerbs+Observation.swift` | `MacFourVerbs`: `screen`, `observedReply`, `sight`; call-local complete AX read shared with pixel capture under window identity and frame-generation validation |
| `MacFourVerbs+PerceptReconstruction.swift` | `MacFourVerbs`: `percept`, `partition`, `supplementalDuplicateIndex` |
| `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: `performPhysical` |
| `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: supplemental AX native-page merge, `zoom`, `parseVerb`, `isRightClick` |
| `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: `resolve`, `answers`, `bareNumberNote` |
| `MacFourVerbs+Wait.swift` | `MacFourVerbs`: `wait` |
| `MacFourVerbs.swift` | `MacFourVerbs` struct |
| `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient` |
| `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`; session-scoped `MacImageFrames` holds delivered pixel geometry under the semantic observation's reference (desktop images mint their own) |
| `MacScreenViewCapture.swift` | Window/display capture selection, `SystemMacVisualObstructionProbe` (other apps' windows over a frame, for sight and a watch's hands) and `SystemMacScreenCaptureSource`; exactly-once callback cancellation invalidates results and resumes immediately, with no cancellation-ignoring join on an unabortable ScreenCaptureKit callback |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG` masks secret frames before encoding; `encodePNG` |
| `MacScreenWatch.swift` | One exact-window ScreenCaptureKit stream per part run, generation-bound frame queries and physical hands; person-only windows refused, secret fields inspected every 500 ms and painted out, incomplete inspection ends with an owned failure. Authority is checked at next/read/hand; window identity at each event. Terminal errors retain their cause; outside an enclosing act Experiences owns repair until an inspected frame from the same window/region arrives or it is let go. Budget, Stop, window loss/resize, revocation, part change and takeover release held input and drop frames. |

### MemoryV2

Directory: `Modules/NativeAgentCore/Sources/MemoryV2/`

| File | Owns |
|---|---|
| `EmbeddingModelDownload.swift` | `EmbeddingModelDownload` actor; `ranges`, `assemble`; shared status text and progress projection |
| `EmbeddingStatusReadiness.swift` | `EmbeddingStatusReadiness` struct |
| `LegacyCorrectionScopeMigration.swift` | `LegacyCorrectionScopeMigration` enum; `runIfNeeded`, `migrationsDir` |
| `MemoryConsolidationGate+Database.swift` | `MemoryConsolidationGate`: `transactionalTableSwap`, `backupLiveStore`, `sweepBackups` |
| `MemoryConsolidationGate+Receipts.swift` | `MemoryConsolidationGate`: `writeManifest`, `readManifest`, `readReceipt` |
| `MemoryConsolidationGateContracts.swift` | `MemoryConsolidationDiff` struct |
| `MemoryConsolidationHygiene.swift` | `MemoryConsolidationHygiene` enum; `runOnce`, `lastRunPath`, consolidation and hygiene report projection |
| `MemoryEmbeddingEpoch.swift` | `MemoryEmbeddingEpoch`, `MemoryEmbeddingBatch`; launch epoch reconciliation on the canonical memory owner |
| `MemoryHygieneReport.swift` | `MemoryHygieneReport` struct |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring` enum; `parseTimestamp`, `decayFactor` |
| `MemoryRepairOneShot.swift` | `MemoryRepairOneShot` enum; `stageIfNeeded`, `stageLegacyNoteDupPurge` |
| `MemoryStatusModels.swift` | `MemoryVectorStatus` struct |
| `MemoryStatusProjection.swift` | `MemoryStatusProjection` enum; vector, MemoryV2 and embedding runtime status/action envelopes and recent misses; `MemoryV2NativeStackSnapshot` reads native stack health |
| `MemoryStatusProjection+WireModels.swift` | memory status wire models |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: `embeddingCorpusSnapshot`, `embeddingEpochState`; derived action vectors in `memory.sqlite`, keyed by embedding epoch and exact-text SHA-256, outside the canonical corpus |
| `MemoryStorage+Integrity.swift` | `MemoryStorage`: `requireSemanticIntegrity`, `spotlightGenerationFingerprint` hashes only eligible exported payload; `createConsistentBackup` |
| `MemoryStorage+Migrations.swift` | `MemoryStorage`: `adoptLedgerlessGraphStoreIfNeeded` |
| `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |
| `MemoryStorage+Recall.swift` | `MemoryStorage`: `invalidateRecallCache`, shared `rankedRecall` scoring and bounded `recall` deduplication, canonical recall-generation cache |
| `MemoryStorage+Tombstones.swift` | `MemoryStorage`: `addTombstone`, `removeTombstone`, `upsertTombstone` |
| `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |
| `MemoryV2+ConsolidationGate.swift` | `MemoryConsolidationGate` enum; `gateLockTarget`, `withGateLock` |
| `MemoryV2+ConsolidationStorageSupport.swift` | `MemoryConsolidationGate`: `consolidationDir`, `candidatesDir`, `candidateRoot` |
| `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`; canonical runtime embedding backend with performance residency; durable action-index updates at warm-up and inventory changes, with serialized missing-text fills and background epoch rebuilds |
| `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; `isEnabled`, `knowledgeGraphEnabled` |
| `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |
| `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`: `recordRecallHits`, `recall`, `readMemoryRecord`; invocation-local ranked voices reused for disclosure refill |
| `MemoryV2+SharedInstance.swift` | Concrete `MemoryStorageBridge` translates canonical records; attachment readiness, projection hooks and unavailable-storage admission |
| `MemoryV2+Spotlight.swift` | Canonical generation-proven rebuild shared by launch and repair; isolated roots never alter system Spotlight |
| `MemoryV2+Storage.swift` | `MemoryStorage` actor; ordered graph hooks, projection attachment, scalar `statusCounts`, checked `curationPage` |
| `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |
| `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `emitDiagnostic` |
| `MemoryV2Contracts.swift` | Current recall/proposal contracts; `MemoryPatchContract` preserves untrusted sources through rewrites and duplicate collapse |
| `MemorySenseProvenance.swift` | `MemorySenseProvenance`; `MemoryStorage.markVersionWrong`: durable sense-version warning metadata |
| `MemoryDataProvenance.swift` | `MemoryDataProvenance`: stamp, retain and consume untrusted memory sources across writes and readbacks |

### NativeAgentCore

Directory: `Modules/NativeAgentCore/Sources/NativeAgentCore/`

| File | Owns |
|---|---|
| `BridgeCore.swift` | Shared HTTP framing, loopback/authentication admission and response transport |
| `NativeLoopbackListenerParameters.swift` | Loopback listener construction, generation and rebind lifecycle |
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `ModuleLogging.swift` | `ModuleLog`: shared formatted, credential-redacted public diagnostics with each module's existing category |
| `ContextSecretContentPolicy.swift` | Shared derived-context secret policy; linear nested percent decoding and ordered URL extraction with authoritative whole-text and query-assignment redaction before and after news composition; Context compiler, native news and JavaScript helper use this same owner |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | process-cached current identity, injectable `from`, `writeLaunchStamp` |
| `NativeTimestampFormat.swift` | `NativeTimestampFormat` enum; `flooredOptionalMicrosecondUTCOffset`, `utcDay` |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `SSEEventStream.swift` | Shared SSE framing and `ProviderStreamContext`; transport opening and activity for every event/comment; optional round-scoped diagnostic event capture before provider decoding |
| `TurnDeadline.swift` | `TurnDeadline` class; shared active-work deadline pauses while awaiting a person |
| `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |

### Onboarding

Directory: `Modules/NativeAgentCore/Sources/Onboarding/`

| File | Owns |
|---|---|
| `Onboarding.swift` | Typed onboarding client; durable completion and reset transactions, profile repair, recovery/reset verdicts and once-only tour replay; Typed onboarding client; durable completion and reset transactions, starter-notes sequencing, profile repair |
| `PersonaTemplates.swift` | `PersonaTemplates` enum; `nowISO`, `generate` |

### AuthoredCapabilities

Directory: `Modules/NativeAgentCore/Sources/AuthoredCapabilities/`

Depends on NativeAgentCore support, PersistenceCore durable I/O and Experiences for repair obligations from live part runs; owns the authored part contract without importing feature executors.

| File | Owns |
|---|---|
| `AbilityStore.swift` | One part header/catalog for tools, skills, senses and reserved turns: reach/wake/face/resident/learned/choices, the `signalled` notification sources post and each part's `wakes`, legacy permissions projection and one 512 KB source limit; invocation-scoped file reach binds declared read/write approval to the part's own data root; current/prev/next lifecycle, all-slot name/identity occupancy for create-only saves, atomic current-only seed installation under the store lock with any existing id/slot skipped, independent versioned outcomes in state.json without source rewrites, bounded recent exact-input/reached-call outcomes with redacted input previews and version run totals projected as learned.use from ordinary gated execution (no rehearsal/preview/replay competence credit), scoped rehearsal evidence distinguished from bundled admission and projected separately for current and proposed versions, operation-scoped repair owed through Experiences with source-filled authoring calls and no automatic swap-back, unique ids, owner-off/peer-authoring guards, change invalidation and verified forward migration of the three old stores into one retained .old-layout archive |
| `SkillRunContext.swift` | Singular authored-run TaskLocals, part identity, file-write notifications and hand-back refusal contract |

### PersistenceCore

Directory: `Modules/NativeAgentCore/Sources/PersistenceCore/`

| File | Owns |
|---|---|
| `InstallPaths.swift` | Install-owned paths, public release preparation and login-item location admission |
| `ConnectorInputValue.swift` | `ConnectorInputValue` enum; `bool` |
| `ConnectorCredentialFile.swift` | Google, Notion and X credentials: checked metadata, path-bound device Keychain references, verified legacy migration; revocation keeps the reference until Keychain deletion succeeds |
| `DeviceSecretKeychain.swift` | Verified device-only Keychain secret bytes; callers own locked reference commits and migration |
| `DiskStorageOwner.swift` | `DiskStorageOwner`: owner retention plans and execution, contained identity-checked moves to Trash and logical-byte outcomes; no history deletion |
| `JSONLRetention.swift` | `JSONLCapCheckCounter` class; `isFullCheckDue`, `isFullCheckDueOnNextAppend` |
| `JSONValue.swift` | `JSONValue` enum; shared schema checker for app arguments, Workshop and owned-code model replies (whole-tree preflight of enforced keywords, unknown keywords ignored, caller-owned error formatting); `fromEncodable`, `mapStrings`, `decodedExactly` (a store's one shape check, naming the field), `digest`, `differences`; `JSONRow` checked row reads for typed owner records |
| `NativeActionRouteSupport.swift` | `NativeActionRouteSupport` enum; `jsonValueBody`, `notImplemented` |
| `PersistenceCore.swift` | Shared JSON/JSONL atomic/durable persistence, strict UTF-8 physical-line tails with rejected-row accounting and directory sync; CapabilityLifecycle guards ability changes and reconciles owner-off attribution; VerifiedPath owns descriptor-relative IO and transfers |
| `PersistenceDataRoot.swift` | `ResolvedDataRootCache` class; `resolve` |
| `RegistryTimestampSortKey.swift` | `RegistryTimestampSortKey` enum; `sortKey` |
| `VolumeIO.swift` | The one owner of blocking file work that can touch a File Provider or network volume (iCloud Drive): one serial queue off the cooperative pool, awaited by its callers |

### Experiences

Directory: `Modules/NativeAgentCore/Sources/Experiences/`

Depends only on GRDB, so every owner of a happening can write it ([EXPERIENCE](EXPERIENCE.md)).

| File | Owns |
|---|---|
| `Experience.swift` | `ExperienceStore`, the append-only owner per data root over `experiences/experiences.sqlite`; `begin`, `append`, `experience`, `open`, indexed open/recent `projection` and commit-fed `changes`. Shared `Experience`/`ObligationPhase` live in NativeAgentShared. Recording stays off reply paths; projection drains queued writes and reports gaps. Turn owners record answer lifetimes and recover saved-answer settlements; conversation and shelf owners publish peer obligations and completed run identities |
| `Flow.swift` | `Flow`: scope-ordered open, stopped, finished and dropped helpers over ExperienceStore; unfinished runs owe finish, with position-prefixed landed digests and references to their owners' raw records |
| `Owed.swift` | `Owed`: what they owes or is owed under the id its owner hands their (a reply's delivery id, a card's `interaction:<id>`), born owing one key and moved only by that owner at its persistence boundary, so desk.wait and repair.let_go read one experience |

### PersonaEngine

Directory: `Modules/NativeAgentCore/Sources/PersonaEngine/`

| File | Owns |
|---|---|
| `PersonaCompiler+Normalization.swift` | `PersonaCompiler`: `normalize` |
| `PersonaEngine+Compiler.swift` | `PersonaCompiler`: `compile`, `fingerprint`, `renderPrompt`; batched context surfaces share canonical persona documents and identity, with separate surface overrides; USER core projection |
| `PersonaEngine.swift` | `SwiftNativePersonaEngine`: shared persona-document reads and GROWTH episodic-log filtering; `PersonaSelection`: installation-wide selection for every door |
| `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`: locked persona mutations and private backups; ordinary persona mutations; skill-specific aliases are retired |
| `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: shared typed profile fields for persistence and onboarding normalization, fixed document specs and guarded writes |

### Privacy

Directory: `Modules/NativeAgentCore/Sources/Privacy/`

| File | Owns |
|---|---|
| `NativeAppSecretRedactor.swift` | `NativeAppSecretRedactor` enum; `redactText`, `redactValue` |
| `PrivacyMap.swift` | privacy state read model |

### Procedures

Directory: `Modules/NativeAgentCore/Sources/Procedures/`

| File | Owns |
|---|---|
| `ProcedureCompilation.swift` | `ProcedureTerminalClass` enum |
| `ProcedureExactActivationExecutor.swift` | `ProcedureExactActivationExecutor` enum; `activate` |
| `ProcedureReplay.swift` | replay status/count and manual dry-run eligibility; canonical executor retains dispatch |

### ProviderRouting

Directory: `Modules/NativeAgentCore/Sources/ProviderRouting/`

| File | Owns |
|---|---|
| `NativeOAuthLoopbackCallbackServer.swift` | shared ChatGPT/xAI loopback callback socket lifecycle, original protocol-specific admission/response shape, state validation and exactly-once completion |
| `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |
| `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog` enum; `load`, `signedCacheLists`; one decoded catalog for account matching and separate Codex/OAuth projections, invalidated by file attributes with auth identity checked on selection |
| `LLMClient+CodexAdapter.swift` | `CodexAdapter`: streaming and buffered Codex runners; NativeAgentCore's ProcessPipeDrain owns shared nonblocking pipe capture without an executor dependency |
| `GoogleOAuthCredentials.swift` | `GoogleOAuthCredentials` enum; `credentialStatus`, `accountSubject` |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthDirectAdapter`: `requestMaxTokens`, `clearAtBeta`, `installedClaudeCodeVersion`; indexed content-block validation shared by OAuth text and Anthropic native-tool streams, keeping text/thinking/signature/tool deltas on their own blocks |
| `LLMClient+AnthropicNativeTools.swift` | `AnthropicAdapter`: native-tool stream decoding commits explicit object input at content-block close; empty-input candidates and later blocks wait in wire order for the terminal verdict; interruptions discard unconfirmed empty candidates and release explicit calls, retaining thinking replay; shared Anthropic event type, wire errors, usage and stop-reason accumulation |
| `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthDirectAdapter`: `ephemeralCacheControl`, `currentTurnUserIndex`, `currentBoundaryIndex` |
| `LLMClient+OpenAIOAuthCredentials.swift` | `OpenAIOAuthDirectAdapter`: `authPathCandidates`, `boundRootReadAuthPath`, `preferredAuthPath` |
| `LLMClient+OpenAIOAuthDirectAdapter.swift` | `CodexOAuthAccessContext` struct |
| `LLMClient+OpenAIResponsesDecoding.swift` | `OpenAIOAuthDirectAdapter`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |
| `LLMClient+Real.swift` | `SwiftNativeLLMClient` shared routing and non-streaming execution envelope, stream guard admission before adapter creation, and failed-call telemetry before error normalization |
| `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`; successful/failed call receipts with purpose, timing, provider identity and redacted underlying failure detail; memory, digest and probe telemetry retain their own surfaces when routing inherits Chat |
| `NativeOAuthCallbackPolicy.swift` | `NativeOAuthFlow`: `handleCallbackURL`, `validateCallback`, `parseCallback` |
| `NativeOAuthCallbackRegistry.swift` | `PendingCallbacks` class; `register`, `forget` |
| `NativeOAuthFlow+Configs.swift` | `ProviderOAuthConfig` struct; `buildAuthURL`, `exchangeCode` |
| `NativeOAuthFlow+Helpers.swift` | `PKCE` struct; `generate` |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackTarget`, `callbackHasResult` |
| `NativeOAuthFlow+TokenStatus.swift` | `NativeOAuthFlow`: `clearTokens`, `expiresAt`, credential health/status and shared connection verdict |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | `NativeOAuthFlow` enum; `validateSignInDestination`, `startOAuthFlow`, Anthropic setup-token normalization/admission/write |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort` protocol; `runLoopbackAuthSession`, `isCanceledLogin` |
| `OAuthContinuationGate.swift` | `OAuthContinuationGate` class; `install`, `resume` |
| `OAuthCredentialDecoding.swift` | Shared JWT payload and OAuth expiry decoding; `OAuthRefreshBinding`: account identity and refresh continuity |
| `OAuthCredentialDestinations.swift` | `OAuthCredentialDestinations` enum; `xAIProvider`, `xConnector` |
| `OAuthCredentialHealth.swift` | `OAuthCredentialHealth` struct |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` |
| `ModelCatalogTTLCache.swift` | shared live fetch and TTL/backoff state machine; `ModelCatalogDecodeCache` memoizes each provider's decoded rows and authority stamps by canonical file path and mtime |
| `ProviderAPIKeyStore.swift` | `ProviderAPIKeyStore` enum; `insert`, `read` |
| `XAIOAuthCredentialStore.swift` | Locked xAI token migration, immutable Keychain references, refresh reads and sign-out cleanup |
| `ProviderFailure.swift` | Typed provider failure classification and `Diagnostic` wrapper preserving redacted wire evidence and the owner's `ToolFailureError` repair through normalization; `repair` decides once whether a failed call owes repair (sign-in, account, model choice) or is a correction that owes nothing |
| `ProviderRecoveryPolicy.swift` | Shared failure classification and helper-start backoff; provider calls do not repeat through a retry ladder |
| `ProviderStreamGuard.swift` | Configured idle/wall cuts on wire activity for every provider stream, typed no-reply failure, cancellation-owned stream forwarding and uncapped model URLSession; the learned first-output deadline bounds only a wire with nothing on it; wall-off streams forward without a watchdog |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting` actor; `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting`; provider interpretation, recoverable group writes and byte-preserving explicit routing reconstruction |
| `ProviderRoutingContracts.swift` | `ProviderRoutingProtocol`: `listProviders`, `getProvider`, `configureProvider` |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |
| `LLMProviderStatusFeed.swift` | live provider status feed |
| `ProviderConnectionProbe.swift` | provider connection probes |
| `ProviderReasoningSelection.swift` | provider reasoning selection |
| `ProviderSignInHandoff.swift` | provider sign-in handoff state |
| `ProviderTurnChoice+ModelSelection.swift` | provider turn model selection |
| `SwiftCodexDeviceLoginManager.swift` | `SwiftCodexDeviceLoginManager` enum; CLI executable readiness |

### Research

Directory: `Modules/NativeAgentCore/Sources/Research/`

| File | Owns |
|---|---|
| `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |
| `Research+Autodetect.swift` | `SwiftNativeResearchClient`: `autodetectSearXNG`, `checkSearXNG`, `normalizedSearXNGBaseURL`, `saveSearXNGBaseURL` |
| `Research+CodexSearch.swift` | `WebSearchRoutes`: general → Codex with direct web tools, categories/Codex failures → SearXNG; actual-route receipts, Codex failure reasons, untrusted web-content labels and explicit failures |
| `Research+Helpers.swift` | `SwiftNativeResearchClient`: `trimTrailingSlash`, `makeURL`, `isoTimestamp` |
| `Research+Lab.swift` | `SwiftNativeResearchClient`: `researchLabRuns`, `runResearchLab`, `buildResearchBrief` |
| `Research+SearchFetch.swift` | `SwiftNativeResearchClient`: `localServerIsDown`, `search`, `fetchURL` |
| `ResearchTransports.swift` | `URLSessionResearchHTTPClient.getBounded`; Docker discovery/start; subprocesses delegate to `MacControl.SystemProcessAdapter` with full output capture |

### SchedulerExecution

Directory: `Modules/NativeAgentCore/Sources/SchedulerExecution/`

| File | Owns |
|---|---|
| `SchedulerDueJobRunner+DreamCommands.swift` | canonical recurring-dream command selection and job receipts |
| `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |
| `SchedulerDueJobRunner+CycleHelpers.swift` | `SchedulerDueJobRunner`: `upsertDefaultCycleJob`, `pruneRetiredRows`, `nextEpoch` |
| `SchedulerDueJobRunner+Execution.swift` | `SchedulerDueJobRunner`: `execute` (a `part` job fires its part's `schedule:` signal), `channelIsSwitchedOn`, `disabledDreamResult` |
| `SchedulerDueJobRunner+Persistence.swift` | `SchedulerDueJobRunner`: execution-result adaptation to canonical scheduler settlement; `appendActivity` |
| `SchedulerDueJobRunner+ProactiveScan.swift` | `SchedulerDueJobRunner`: `surfaceProactiveScan` |
| `SchedulerDueJobRunner+Selection.swift` | `SchedulerDueJobRunner`: `nextMeaningfulDeadline`, `claimDueJobs`, `dueJobs`; default cycle jobs and one `part` job per part and `schedule:` wake |
| `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`: `jobTimeoutSeconds`, `executeWithTimeout` |
| `SchedulerDueJobRunner.swift` | `SchedulerDueJobRunner` actor; `runDueJobs`; reads canonical job rows through `SchedulerJobs` |
| `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `sendTelegramMessage` |

### SelfImprovement

Directory: `Modules/NativeAgentCore/Sources/SelfImprovement/`

| File | Owns |
|---|---|
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletStatus`: `ImprovementGauntletRun`, `GauntletCheck` |
| `SelfImprovement+TrainingReads.swift` | `SwiftNativeSelfImprovement`: `evals`, `listEvalsLocal`; `EvalRun`, `EvalCheck`, `HarnessBenchmarkRun`, `HarnessBenchmarkCheck` models and benchmark execution |

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

| File | Owns |
|---|---|
| `FileSenseRegistry.swift` | Sense adapter to AbilityStore files and state; bundle defaults, corner lookup, keep/restore through the shared publication authority gate with bundled materialization deferred to the admitted save, previous-version swap, final override drop and separate owner-off preservation |
| `FileSenseRegistry+Storage.swift` | Registry validation, candidate/version-folder source resolution, bounded code manifests and path/symlink fences |
| `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |
| `ExistingCornersSourceProvider.swift` | `ExistingCornersSourceProvider`: contract ports for today's raw material and native pages; `SenseNativePages` owns readable Chrome places, bounded conversation/tab-scoped private continuation bindings, structural things/verbs and existing raw UTF-8 windows |
| `BuiltInSenses.swift` | Bundle-owned native adapters and JavaScript defaults; file overrides win and accounting lives in AbilityStore state |

### Skills

Directory: `Modules/NativeAgentCore/Sources/Skills/`

| File | Owns |
|---|---|
| `InstalledSkillInventory.swift` | Shared skill file scan and bundled guidance; same-id overrides suppress bundle selections; review/install eligibility, canonical digest/source and checked runnable admission, source metadata and installed-skill projections |
| `Skills.swift` | Skill records/client over AbilityStore; create_only refuses occupied names/identities under the staging lock before any candidate is replaced; exact candidate admission and reads/runs, final drop, previous-version swap, Full Mac maintenance of agent-owned built-in overrides with separate owner-off protection and run accounting |
| `SkillsJSON.swift` | Checked skill record decoding and JSON convenience; no registry, shared version ownership or manifest storage |

### SlackBot

Directory: `Modules/NativeAgentCore/Sources/SlackBot/`

| File | Owns |
|---|---|
| `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; socket/history/recovery admission, active-handler exclusion and terminal delivery truth; `path`, `recoverySummary`, `failedReplyClaims`, `confirmReplyPart` retain confirmed text/image progress across holds |
| `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | Slack socket configuration and ID parsing |
| `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: `classifySessionClosure`, `disconnectDisposition`, `classifyReceiveLoopReturn` |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop` struct; `tick`, `tickOutcome` |
| `SlackSocketModeSupport.swift` | `SlackConversationRef` struct |
| `SlackTurnContracts.swift` | `SlackInboundFile` struct |

### StandingBots

Directory: `Modules/NativeAgentCore/Sources/StandingBots/`

| File | Owns |
|---|---|
| `BotsShelfRead.swift` | Shelf, helper schedule and approval read models; run-feed projection |
| `StandingBotSchedule.swift` | `StandingBotSchedule` enum; `parse`, `words` |
| `BotDefinitionStore.swift` | Definition persistence and editor model/budget/schedule/event admission |
| `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |
| `BotHeadline.swift` | `BotHeadline` enum; `make` |
| `BotLegacyHistory.swift` | `ShelfStore`: `legacyHistory` |
| `BotRunQueue.swift` | `BotRunQueue` struct; `enqueue`, `presence` |
| `BotRunner.swift` | `BotRunner` actor; `run`, `ask` |
| `BotRunnerDeadline.swift` | `BotRunnerDeadline` enum; `settled` |
| `BotRunnerScheduler.swift` | `BotRunnerScheduler` actor; `scheduledDates`, `missedRuns` |
| `ShelfStore.swift` | `ShelfStore` struct; `append`, `settleApproval` |
| `StandingBotsDisk.swift` | `StandingBotsDisk` struct; `validatePath`, `locked` |
| `StandingBotsModels.swift` | `BotDefinition`: `BotSource`, `BotRunLimits`, `BotCadence` |

### Studio

Directory: `Modules/NativeAgentCore/Sources/Studio/`

| File | Owns |
|---|---|
| `StudioWorkingShelf.swift` | `StudioWorkingShelf` struct; `decodeSlots`, `selections` |

### SwarmRuns

Directory: `Modules/NativeAgentCore/Sources/SwarmRuns/`

| File | Owns |
|---|---|
| `SwarmRunsReader.swift` | `SwiftNativeSwarmRunsReader`: shared crew projection, checked receipt persistence and exact interrupted recovery without replay |
| `SwarmExecutor.swift` | `SwiftNativeAgentSwarmExecutor`, `SwarmLiveBoard`: admission, worker execution and durable progress |
| `RunLedger.swift` | `RunLedger`: cross-surface completed-run summary |

### SystemOps

Directory: `Modules/NativeAgentCore/Sources/SystemOps/`

| File | Owns |
|---|---|
| `SoftwareUpdateState.swift` | `SoftwareUpdateState` |
| `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |

### TelegramBot

Directory: `Modules/NativeAgentCore/Sources/TelegramBot/`

| File | Owns |
|---|---|
| `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver` actor; `onDelta`, `finalize` |
| `TelegramBot+Config.swift` | `TelegramConfigurationSummary` struct |
| `TelegramBot+Settings.swift` | Telegram settings and saved routing |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`: `handleApprovalSlashCommand`, `handleApprovalCallback`, `importLegacyApprovalContinuations` |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`: `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand` |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `chatAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+QueuedTurnControls.swift` | `TelegramPollLoop`: `handleQueuedTurnControlCallback` |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |
| `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody` |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger` actor; `upsert`, `remove`; `TelegramTurnCardRestartRepairer` owns one repair task and shutdown |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox` struct; `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`; maintained claim index emits delivery invalidations and can be reconstructed from checked claims without changing phases; recovery exceptions retain a terminal quarantined claim and reason, excluded from automatic replay |

### ToolRegistry

Directory: `Modules/NativeAgentCore/Sources/ToolRegistry/`

| File | Owns |
|---|---|
| `ToolRegistryActions.swift` | Checked tool mutations, restore, drop and shared version/validation reads; run evidence and repair obligations belong to AbilityStore |
| `ToolApprovalEligibility.swift` | `ToolApprovalEligibility` enum; shared authored-tool activation refusal |
| `ToolDescriptor.swift` | `ToolDescriptor`, `ToolExecutor`, `AppActionBinding`: composed action calls, policies and executable ownership registration |

### Transcripts

Directory: `Modules/NativeAgentCore/Sources/Transcripts/`

| File | Owns |
|---|---|
| `ChatSessionIndexFile.swift` | `ChatSessionIndexFile` enum; `recordContinuityParticipant`, `recordConversationChange` |
| `ChatSessionRecollections.swift` | Recollection row/coverage parsing, incremental scans and lock-protected timestamp formatters |
| `ChatSessionRetention.swift` | Checked archive-index reader shared by discovery/restoration; locked pruning/enforcement snapshot, nonblocking transcript admission and exact acknowledged-version guard; retains all chat storage including the history index during disk cleanup |
| `ChatExportService.swift` | Snapshot-based Markdown rendering and atomic export write outside the main actor; completion follows the file write |

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

| File | Owns |
|---|---|
| `SchedulerJobs.swift` | Canonical bounded job storage, occurrence claims, unknown-outcome recovery and settlement; `claimDueJobs`, `settleOccurrence`, `pruneJobs` |
| `TriggerNotificationInbox.swift` | `TriggerNotificationInbox`: proactive identity matcher, checked locked mirror, `archiveSupersededMorningBriefs` |
| `TriggerScheduler.swift` | `SwiftNativeTriggerScheduler` actor; `listInboxTriggers`, `listWorkshopTriggers` |

### TrustCenter

Directory: `Modules/NativeAgentCore/Sources/TrustCenter/`

The workflow capability reader delegates defaults, unchanged-seed migration and
registry merging to `WorkflowOrchestration`; this reader does not write back.

| File | Owns |
|---|---|
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Peer-origin approval floors and provenance requirements for attributed memory notes; ability changes/growth capture use CapabilityLifecycle's common write guard |
| `SecurityCenter+FullMacPolicy.swift` | `SwiftNativeSecurityCenter`: `fullMacActive`, `fullMacYoloAuthority`, `drivenAgentLaunchPermission` |
| `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: `promptInjectionKeys`, `secretKeys`, `redactValue` |
| `SecurityCenter+JSONUtilities.swift` | `SwiftNativeSecurityCenter`: `maxDecision`, `object`, `string` |
| `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |
| `SecurityCenter+PathPolicy.swift` | `SwiftNativeSecurityCenter`: `capabilityWritesOutsideAppData`, `pathLikeStrings` |
| `SecurityCenter+ReceiptJSON.swift` | `SecurityToolEnvelope`: `toJSONValue` |
| `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary`, `isoTimestamp` |
| `SecurityCenter+ToolProfiles.swift` | `SwiftNativeSecurityCenter`: `canonicalToolRisk`, `profile`; authority consumes the registered action binding |
| `SecurityCenter.swift` | `SwiftNativeSecurityCenter`: security decisions, including permission-reset approval |
| `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner` actor; `canonicalBytes`, `compactCanonicalJSON` |
| `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog` enum; `normalizedMode`, `macControlPolicy` and Mac integration preset recognition |
| `TrustAccessModeCapabilityCatalog+Read.swift` | trust capability catalog reads, effective file/Mac authority and approval/risk groups |
| `TrustCenter+AppAdapter.swift` | `SwiftNativeTrustCenter`: `loadTrustPolicyJSON` |
| `TrustCenter+Autonomy.swift` | `PermissionLaw` enum: `posture`, `answer` (the one effective level), `judge`, `toolClass`, `reachesUser`; `SwiftNativeTrustCenter`: `autonomyLevel`, `autonomyForTool`, `autonomyForExactToolName`, `explicitAutonomyOverride` |
| `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter.authorizeChromeControlEffect`: checked authority distinguishes disabled from unavailable without a Boolean wrapper |
| `TrustCenter+Defaults.swift` | `SwiftNativeTrustCenter`: `defaultTrustPolicy` |
| `TrustCenter+PolicyLoading.swift` | `SwiftNativeTrustCenter`: `loadRawPolicyChecked`, `validateAuthorityPolicyShape`, `validateKnownAuthorityPolicyTypes` |
| `TrustCenter+PolicyModels.swift` | `TrustCenterDefaultWorkspaceRoots`, `TrustCenterError` |
| `TrustCenter.swift` | `SwiftNativeTrustCenter` actor; `getTrust`, `applyPolicyPatchChecked` |
| `TrustPolicy.swift` | `TrustPolicy`, `TrustTrainingPolicy` structs |
| `TrustPolicyActions.swift` | `TrustPolicyActions` struct; `developerModePatchBody`, `saveMemoryPolicy`, `saveAgentAccessMode` |
| `TrustPolicyToolWriter.swift` | `TrustPolicyToolWriter` enum; `applyTrustPolicyPatch` |

### TrustPersistence

Directory: `Modules/NativeAgentCore/Sources/TrustPersistence/`

| File | Owns |
|---|---|
| `ProductionExport+Archive.swift` | production archives, support bundles and registry rows |
| `TrustBackupFoundation.swift` | `JSONDecoder`: extension |
| `TrustBackupHost.swift` | `TrustBackupHost`; running-bundle version factory |
| `TrustBackupModels.swift` | `BackupRecord` struct |
| `TrustBackupPersistence.swift` | `TrustBackupPersistence` enum; snapshots never seal lock sidecars; existing missing lock entries are tolerated, present listed locks and all data retain integrity checks; disk reclamation keeps two verified restore points, catalog pins and staged-restore dependencies; only saved older candidates reach Trash, before catalog retirement under existing locks |

### TurnTrace

Directory: `Modules/NativeAgentCore/Sources/TurnTrace/`

| File | Owns |
|---|---|
| `TurnTraceReadProjection.swift` | TurnTraceRow, grouping/replay readers and shared TurnInspectorProjection/trace evidence |
| `TurnSummaryRecord.swift` | `TurnSummaryRecord`, `TurnSummaryFile`, `TurnSummaryComputer`, `TurnSummarySource` |
| `TurnInspectorFeed.swift` | `TurnInspectorLiveDropState`, `TurnInspectorFeed` |
| `AbandonedTurnReconciler.swift` | `TurnCheckpoint` durable run state; `AbandonedTurnReconciler` checkpoint discovery, sweep-local day terminal index and guarded legacy terminals |
| `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook` enum; `arm`; excludes active turns and claims checkpoint resumes; terminal settlement awaits the installed anchor-intent adapter |
| `TurnTrace.swift` | durable terminal delivery (its notification carries the trace day file, session, surface and the part whose run started the turn) before checkpoint retirement; bounded ingress/disk workers, checked JSONL framing before kind/turn filtering including one exact day-file read per shapes page without a retention scan, and first-render correlation/publication; turn-bound calls, dispatches and plans persist only here, with standalone and unmatched historical ledger rows through `traceEvidence`, preserving historical outcomes when canonical status is absent; model-call rows retain the former ledger byte budget to preserve cache-prefix evidence |

### WorkshopExecution

Directory: `Modules/NativeAgentCore/Sources/WorkshopExecution/`

Failed or invalid plans refuse submission instead of substituting synthesis steps; provider failures retain their original repair evidence.

| File | Owns |
|---|---|
| `WorkshopCompiledLocalFileCopyProcedure.swift` | `WorkshopCompiledProcedurePlanError` enum |
| `WorkshopExecution+OutcomeVerification.swift` | `WorkshopExecutorLoop`: `unmetSuccessCriterion`, `verifyCompletedOutcome` |
| `WorkshopExecutorContracts.swift` | `WorkshopStepApprovalRequest` struct |
| `WorkshopPump.swift` | `WorkshopPump` struct; `tick`, `hasLiveAttempt` |
| `WorkshopSession.swift` | `WorkshopSession` struct; `run`, `trimSummary` |
| `WorkshopSessionContracts.swift` | `WorkshopSessionStatus` enum |
| `WorkshopSessionEffects.swift` | `WorkshopSessionEffects` protocol; `makeToolDispatcher`, `productionTurnExecutor` |
| `WorkshopSessionResultStore.swift` | `WorkshopSessionResultStore` struct; `path`, `save` |
| `WorkshopToolProfile.swift` | `WorkshopToolProfile` struct; `permits` |

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

Checked Mac integration permission storage and mail read locations.

| File | Owns |
|---|---|
| `MacIntegrationGates.swift` | `MacIntegrationGates`: `byTool` (the switch each dispatcher tool is gated on), `refusal` (the off switch's refusal, asked before any card by the chat gate and the Workshop executor) |
| `MacIntegrationPermissions.swift` | integration authority store plus one system-permission map for card admission, panes and checking; one-shot Mac CoreLocation reader and Location Services acquisition; Messages directory access probe, bundle-specific Automation verification, Trust-only categories left to Trust, and notification authorization |
| `MailReadLocator.swift` | `MailReadLocator` |

### NotificationInbox

Directory: `Modules/NativeAgentCore/Sources/NotificationInbox/`

Notification records, checked live inbox storage and status reads. Depends on
Desk for the one OwnerAttentionPolicy; inbox prominence and overview counts
share it rather than implementing their own definitions of an obligation.

| File | Owns |
|---|---|
| `InboxItemRecord.swift` | `InboxSourceReadState`, `InboxItemRecord`, `InboxRelatedGroup`; latest stable-card identity and OwnerAttentionPolicy projection |
| `LiveNotificationInbox.swift` | `LiveNotificationInbox` |
| `NotificationInbox.swift` | `NotificationInboxClock` |

### GrokLink

Directory: `Modules/NativeAgentCore/Sources/GrokLink/`

Grok connection credentials and reply input.

| File | Owns |
|---|---|
| `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |

### MacAssistantStatus

Directory: `Modules/NativeAgentCore/Sources/MacAssistantStatus/`

Mac assistant readiness and platform capability status projections.

| File | Owns |
|---|---|
| `MacAssistantStatus.swift` | assistant status client, result, Mail readiness projection and watch evidence |

### MultimodalTTS

Directory: `Modules/NativeAgentCore/Sources/MultimodalTTS/`

Speech synthesis contracts and provider implementation.

| File | Owns |
|---|---|
| `MultimodalTTS.swift` | `MultimodalTTSError`, `SwiftOpenAITTSClient` |

### FeedPolicy

Directory: `Modules/NativeAgentCore/Sources/FeedPolicy/`

Path-owned bounded JSONL feed retention policy.

| File | Owns |
|---|---|
| `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy` |

### ScreenVision

Directory: `Modules/NativeAgentCore/Sources/ScreenVision/`

Screen capture, screen-understanding operations and permission observation.

| File | Owns |
|---|---|
| `ScreenVision.swift` | Screen vision owner; NativeScreenCapture encoding and capture error mapping |

### VisionPerception

Directory: `Modules/NativeAgentCore/Sources/VisionPerception/`

Image perception, OCR, geometry, redaction aliases and stable visual handles.

| File | Owns |
|---|---|
| `VisionColorRegionLayer.swift` | `VisionColorRegionResult`, `VisionPixelGrid`, `VisionColorRegionLayer` |
| `VisionFourVerbAdapter.swift` | `VisionImageDecoder`, `VisionImageCrop`, `VisionImageCropper`, `VisionLiveRegionIdentity`, `VisionLiveOccludedRegion`, `VisionPercept` |
| `VisionHandles.swift` | `VisionHandles` |
| `VisionPercept.swift` | `VisionAffordanceRow`, `VisionReadoutRow`, `VisionRecognizedText`, `VisionPercept` |
| `VisionPerceptionCompiler.swift` | `VisionPerceptionError`, `VisionRowDraft`, `VisionPerceptionCompiler` |
| `VisionPerceptionTypes.swift` | `VisionConfidence`, `VisionStateGuess`, `VisionEvidenceSource`, `VisionCandidate` |
| `VisionRoleGuess.swift` | `VisionRoleGuess` |
| `VisionSaliencyLayer.swift` | `VisionSaliencyLayer`, `VisionKitSalienceProvider` |
| `VisionTextBandLayer.swift` | `VisionTextBand`, `VisionTextBandLayer` |
| `VisionTextLayer.swift` | `VisionTextLayerResult`, `VisionTextLayer`, `VisionKitTextRecognizer` |
| `VisionTextRedaction.swift` | `VisionRedactedText`, `VisionRedactionConfig`, `VisionTextRedaction` |

### SlackConnector

Directory: `Modules/NativeAgentCore/Sources/SlackConnector/`

Slack credential persistence and connector actions.

| File | Owns |
|---|---|
| `SlackConnectorActions.swift` | `SlackConnectorActions`, `SlackConnectorCredentialsMissing` |
| `SlackCredentials.swift` | `SlackCredentials` |

### XConnector

Directory: `Modules/NativeAgentCore/Sources/XConnector/`

X connector actions.

| File | Owns |
|---|---|
| `XConnectorActions.swift` | `XConnectorActions` |

### WorkflowOrchestration

Directory: `Modules/NativeAgentCore/Sources/WorkflowOrchestration/`

Workflow registry, records, default migration and merge policy.

| File | Owns |
|---|---|
| `WorkflowOrchestration.swift` | `WorkflowStep`, `WorkflowRecord`, `SwiftNativeWorkflowOrchestrationClient`, `WorkflowOrchestrationClock`, `WorkflowDefaults`, `WorkflowMerge` |

### ToolExecution

Directory: `Modules/NativeAgentCore/Sources/ToolExecution/`

Tool execution, sandbox primitive broker and promotion boundary.

| File | Owns |
|---|---|
| `ToolExecution+Promote.swift` | `SwiftNativeToolExecution`, `ToolHost` |
| `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`: declared model/network/connector reach, raw network, admitted-model thoughts and fetch forwarding, the run's one screen watch and its hands; no file executor |
| `ToolExecution.swift` | `ToolExecutionError`, `ProposalRecord`, `ProposalValidationResult`, concrete `SwiftNativeToolExecution` proposal validation, promotion, execution and rollback; trusted bundle tool bytes prepared with exact sealed admission for direct current installation, without invoking the tool |

## Shared Source Map

### NativeAgentShared

Directory: `Modules/NativeAgentShared/Sources/NativeAgentShared/`

| File | Owns |
|---|---|
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver` enum; `typeAndMime`, `fileByteLimit`, `submittingSpeech` keeps composer wording on its utterances |
| `ChatRichContentParser.swift` | `ChatRichContentParser` enum; `blocks`, `listRows`; shared fence, list marker and continuation grammar |
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport` class; `observeAccountFailures`, `observeIncoming` (returns subscription readiness), `isChatNotification`, `shouldPersistPullCursor`, `resignalMessage` (original signed envelope; existing query clock renewed) |
| `CloudKitTimeoutResultLatch.swift` | `CloudKitTimeoutResultLatch` actor; `wait`, `finish`, `race`; shared timeout race for detached diagnostics and budget-inheriting transport tasks |
| `DetachedCloudKitTimeoutRace.swift` | `DetachedCloudKitTimeoutOutcome` enum |
| `MobileHelpers.swift` | `MobileHelpersSnapshot` struct |
| `MobileSchedulerSnapshot.swift` | `MobileSchedulerSnapshot` struct |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup` enum; `groups` |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | `MobileTrustAction` enum |
| `SurfaceLayout.swift` | `SurfaceLayout` struct: the layout document's shape, vocabulary and seed; `addMissing`, `shown`, `arranged` for the Mac and the phone; `QuietToolPage` owns the shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases and derives accepted part face pages from those definitions |
| `MobileWorkActivity.swift` | `Experience` and `ObligationPhase` value contracts shared by owners and phone renderers; `MobileWorkActivity` and its revisioned experience snapshot |

## iOS Companion Map

### Companion

Directory: `iOS/NativeAgentMobile/Sources/`

| File | Owns |
|---|---|
| `AdvancedPresentation.swift` | `View`: `mobileReadingScreen` |
| `AdvancedView.swift` | `AdvancedView` struct |
| `ChatBubbleViews.swift` | `BubbleView` struct |
| `ChatPresentation.swift` | `ChatSessionTabPresentation` enum; `isSelectionDisabled` |
| `ChatView.swift` | `ChatView` struct |
| `InboxModels.swift` | `InboxItemRecord`: `replacingStatus` |
| `InboxView.swift` | `InboxView` struct |
| `MacToolsPresentation.swift` | `MacSystemQuickAction` enum |
| `MacToolsView.swift` | `MacToolsView` struct |
| `MemoryView.swift` | `MemoryView` struct |
| `MobileAgentsView.swift` | `MobileAgentsView` struct |
| `MobileAppIntents.swift` | `MobileAskIntent`: `perform` |
| `MobileConnectorRow.swift` | `MobileConnectorRow` struct |
| `MobileHelpersView.swift` | `MobileHelpersView` struct |
| `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |
| `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
| `MobileSchedulerView.swift` | `MobileSchedulerView` struct |
| `MobileTrustEditor.swift` | `MobileTrustEditor` struct |
| `NativeAgentDesign.swift` | `View`: `appShimmer` |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities` |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `seal` |
| `TelegramView.swift` | `TelegramView` struct |
| `iCloudBridge.swift` | `iCloudBridge` class; `recordMacConfirmation`, `clearMacConfirmationForConnectionRepair`; pairing-scoped record-identity nudges until authenticated Mac acceptance or the existing chat/action/place owner retires delivery; place acceptance is checkpointed by `PhonePlaces` before nudges stop; restored owners loaded before pruning |
| `iCloudSyncEngine+Actions.swift` | `iCloudSyncEngine`: `requireIdleActionForConnectionRepair`, `reconcileActionsForConnectionRepair`, `persistCloudKitActionResponse` |
| `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `refreshHelpersSnapshot`, `applySchedulerSnapshot`, `refreshSchedulerSnapshot`, `applyProviderState` |

### Diagnostics

Directory: `iOS/NativeAgentMobile/Sources/Diagnostics/`

| File | Owns |
|---|---|
| `CKLandmine.swift` | `withCKTimeout` |

## Executable Architecture Policy

`script/check_architecture_blueprint.swift` reads the following JSON block. Change
ownership rules here in the same commit as the source change; the script contains
only parsing, file enumeration and validation mechanics. Paths are repository-relative.
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
  "families": [
    {"label": "AppDelegate", "directories": ["Sources/NativeAgentApp"], "prefix": "AppDelegate+"},
    {"label": "AppModel", "directories": ["Sources/NativeAgentApp"], "prefix": "AppModel+"},
    {"label": "EngineRuntime", "directories": ["Modules/NativeAgentCore/Sources/EngineRuntime"], "prefix": "Engine"},
    {"label": "ApprovalTransactionCoordinator", "directories": ["Modules/NativeAgentCore/Sources/ApprovalTransactions"], "prefix": "ApprovalTransactionCoordinator"},
    {"label": "SchedulerDueJobRunner", "directories": ["Modules/NativeAgentCore/Sources/SchedulerExecution"], "prefix": "SchedulerDueJobRunner+"},
    {"label": "NativeOAuthFlow", "directories": ["Modules/NativeAgentCore/Sources/ProviderRouting", "Modules/NativeAgentCore/Sources/Connectors"], "prefix": "NativeOAuthFlow+"},
    {"label": "NativeOAuthPlatform", "directories": ["Sources/NativeAgentApp"], "prefix": "NativeOAuthPlatform+"},
    {"label": "MacSyncEngine", "directories": ["Modules/NativeAgentCore/Sources/DeviceSync"], "prefix": "MacSyncEngine+"},
    {"label": "MacAppleScriptBridge", "directories": ["Modules/NativeAgentCore/Sources/MacIntegration"], "prefix": "MacAppleScriptBridge+"},
    {"label": "ChatView", "directories": ["Sources/NativeAgentApp"], "prefix": "ChatView+"},
    {"label": "KnowledgeGraphView", "directories": ["Sources/NativeAgentApp"], "prefix": "KnowledgeGraphView+"},
    {"label": "TrustCenter", "directories": ["Modules/NativeAgentCore/Sources/TrustCenter"], "prefix": "TrustCenter+"},
    {"label": "SecurityCenter", "directories": ["Modules/NativeAgentCore/Sources/TrustCenter"], "prefix": "SecurityCenter+"},
    {"label": "TelegramPollLoop", "directories": ["Modules/NativeAgentCore/Sources/TelegramBot"], "prefix": "TelegramPollLoop+"},
    {"label": "ChatOrchestrationClient", "directories": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime"], "prefix": "ChatOrchestrationClient+"},
    {"label": "Research", "directories": ["Modules/NativeAgentCore/Sources/Research"], "prefix": "Research+"},
    {"label": "SwiftToolDispatcher", "directories": ["Modules/NativeAgentCore/Sources/ChatToolRuntime"], "prefix": "SwiftToolDispatcher+"},
    {"label": "BuiltInToolSchemaFactory", "directories": ["Modules/NativeAgentCore/Sources/ChatToolRuntime"], "prefix": "BuiltInToolSchemaFactory+"}
  ],
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
    {"id": "retired-ios-action-routing", "files": ["iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift"], "forbiddenPatterns": ["dispatches to daemon|daemon endpoint"], "caseInsensitive": true, "message": "iOS sync comments must route to MacSyncEngine and Swift runtime"},
    {"id": "retired-ios-action-routing", "files": ["iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift"], "forbiddenPatterns": ["dispatches to daemon|daemon endpoint"], "caseInsensitive": true, "message": "iOS action comments must route to MacSyncEngine and Swift runtime"},
    {"id": "retired-ios-action-routing", "files": ["iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Setup.swift"], "forbiddenPatterns": ["dispatches to daemon|daemon endpoint"], "caseInsensitive": true, "message": "iOS setup comments must route to MacSyncEngine and Swift runtime"},
    {"id": "retired-ios-action-routing", "files": ["iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Snapshots.swift"], "forbiddenPatterns": ["dispatches to daemon|daemon endpoint"], "caseInsensitive": true, "message": "iOS snapshot comments must route to MacSyncEngine and Swift runtime"},
    {"id": "retired-ios-pairing-comment", "files": ["iOS/NativeAgentMobile/Sources/PairingStore.swift"], "forbiddenPatterns": ["<lan-ip>:8765|LAN daemon"], "caseInsensitive": true, "message": "iOS pairing comments must not document retired LAN pairing as current setup"},
    {"id": "retired-ios-kg-comment", "files": ["iOS/NativeAgentMobile/Sources/KnowledgeGraphView.swift"], "forbiddenPatterns": ["Mac daemon|old daemon /v1"], "caseInsensitive": true, "message": "iOS knowledge graph comments must describe iCloud snapshots and retired envelopes accurately"},
    {"id": "retired-ios-onboarding-comment", "files": ["iOS/NativeAgentMobile/Sources/NativeAgentMobileApp.swift"], "forbiddenPatterns": ["/v1/onboarding/start|now-dead daemon|post-wave-20 daemon"], "caseInsensitive": true, "message": "iOS onboarding comments must not point to retired onboarding HTTP routes"},
    {"id": "retired-ios-provider-routing", "files": ["iOS/NativeAgentMobile/Sources/ProviderSettingsView.swift"], "forbiddenPatterns": ["daemon /v1|daemon/native_agentd\\.py"], "caseInsensitive": true, "message": "iOS provider comments must point to Swift provider handlers"},
    {"id": "retired-ios-http-runtime", "files": ["iOS/NativeAgentMobile/Sources/MacBridgeClient.swift"], "forbiddenPatterns": ["daemon HTTP server|Mac daemon returned HTTP"], "caseInsensitive": true, "message": "iOS bridge facade must not describe a live daemon HTTP runtime"},
    {"id": "retired-skill-manifest-runtime", "files": ["docs/skill_manifest_spec.md"], "forbiddenPatterns": ["(?i)\\bdaemon\\b|native_agentd\\.py|daemon's venv Python|Daemon-Side"], "caseInsensitive": true, "message": "skill manifest spec must describe the Swift runtime rather than daemon-owned skills"},
    {"id": "retired-release-migration-instructions", "files": ["docs/release-migration.md"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765|native_agentd\\.py|Verify daemon started|Bundled Python hash verification"], "caseInsensitive": true, "message": "release migration docs must not prescribe retired daemon/Python runtime checks"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/slack.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/gmail.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/google_calendar.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "retired-example-oauth-callback", "files": ["docs/example_manifests/notion.json"], "forbiddenPatterns": ["127\\.0\\.0\\.1:8765"], "caseInsensitive": true, "message": "example OAuth manifests must use current nativeagent:// callback URIs"},
    {"id": "cognitive-traceability", "files": ["docs/COGNITIVE_SUBSTRATE_TRACEABILITY.md"], "required": ["CCS-P0-D1", "CCS-P0-D2", "CCS-P0-D3", "CCS-P0-D4", "CCS-P0-D5", "CCS-P0-D6", "CCS-P0-A1", "CCS-P0-A2", "CCS-P0-A3", "CCS-P0-A4", "CCS-P1-D1", "CCS-P1-D2", "CCS-P1-D3", "CCS-P1-D4", "CCS-P1-D5", "CCS-P1-D6", "CCS-P1-D7", "CCS-P1-D8", "CCS-P1-D9", "CCS-P1-D10", "CCS-P1-D11", "CCS-P1-D12", "CCS-P1-D13", "CCS-P1-D14", "CCS-P1-D15", "CCS-P1-A1", "CCS-P1-A2", "CCS-P1-A3", "CCS-P1-A4", "CCS-P1-A5", "CCS-P2-D1", "CCS-P2-D2", "CCS-P2-D3", "CCS-P2-D4", "CCS-P2-D5", "CCS-P2-D6", "CCS-P2-A1", "CCS-P2-A2", "CCS-P2-A3", "CCS-P2-A4", "CCS-P2-A5", "CCS-P3-D1", "CCS-P3-D2", "CCS-P3-D3", "CCS-P3-D4", "CCS-P3-D5", "CCS-P3-D6", "CCS-P3-A1", "CCS-P3-A2", "CCS-P3-A3", "CCS-P3-A4", "CCS-P3-A5", "CCS-P4-D1", "CCS-P4-D2", "CCS-P4-D3", "CCS-P4-D4", "CCS-P4-D5", "CCS-P4-D6", "CCS-P4-A1", "CCS-P4-A2", "CCS-P4-A3", "CCS-P4-A4", "CCS-P4-A5", "CCS-P4-A6", "CCS-P5-D1", "CCS-P5-D2", "CCS-P5-D3", "CCS-P5-D4", "CCS-P5-D5", "CCS-P5-D6", "CCS-P5-A1", "CCS-P5-A2", "CCS-P5-A3", "CCS-P5-A4", "CCS-P6-D1", "CCS-P6-D2", "CCS-P6-D3", "CCS-P6-D4", "CCS-P6-D5", "CCS-P6-A1", "CCS-P6-A2", "CCS-P6-A3", "CCS-P6-A4", "CCS-P6-A5", "CCS-P7-D1", "CCS-P7-D2", "CCS-P7-D3", "CCS-P7-D4", "CCS-P7-D5", "CCS-P7-D6", "CCS-P7-A1", "CCS-P7-A2", "CCS-P7-A3", "CCS-P7-A4", "CCS-P7-A5", "CCS-P8-D1", "CCS-P8-D2", "CCS-P8-D3", "CCS-P8-D4", "CCS-P8-D5", "CCS-P8-D6", "CCS-P8-A1", "CCS-P8-A2", "CCS-P8-A3", "CCS-P8-A4", "CCS-P9-D1", "CCS-P9-D2", "CCS-P9-D3", "CCS-P9-D4", "CCS-P9-D5", "CCS-P9-D6", "CCS-P9-D7", "CCS-P9-A1", "CCS-P9-A2", "CCS-P9-A3", "CCS-P9-A4", "CCS-P9-A5", "CCS-P10-D1", "CCS-P10-D2", "CCS-P10-D3", "CCS-P10-D4", "CCS-P10-D5", "CCS-P10-D6", "CCS-P10-A1", "CCS-P10-A2", "CCS-P10-A3", "CCS-X1", "CCS-X2", "CCS-X3", "CCS-X4", "CCS-X5", "CCS-X6", "CCS-X7", "CCS-X8", "CCS-X9", "Status Rules", "Next Execution Order"]},
    {"id": "retired-core-machinery", "roots": ["Modules/NativeAgentCore/Sources"], "forbidden": ["OperationalTransitionShadow", "personal_trace_shadow", "WorkshopTerminalOutcomeInterpreter"]},
    {"id": "retired-adaptive-effort", "files": ["Modules/NativeAgentCore/Sources/ApprovalInbox/ApprovalInbox.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestration+ToolLoop.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Factories.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift", "Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift", "Modules/NativeAgentCore/Sources/AppToolRuntime/AppChatToolDispatcher.swift", "Sources/NativeAgentApp/AppModel.swift", "Modules/NativeAgentCore/Sources/EngineRuntime/EngineTurns.swift", "Sources/NativeAgentApp/ChatView+SlashCommands.swift", "Sources/NativeAgentApp/AppApprovalTransactionEffects.swift", "Modules/NativeAgentCore/Sources/ApprovalTransactions/ApprovalTransactionCoordinator.swift"], "forbiddenPatterns": ["adaptiveReasoningEffort"], "caseInsensitive": true},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+Client.swift"], "required": ["checkedRouteAdmission"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+StreamFacade.swift"], "required": ["checkedRouteAdmission"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestration+TurnEngine.swift"], "required": ["provider.admissionReused"], "forbidden": []},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/WorkshopExecution/WorkshopExecution+PlannerLLM.swift"], "required": ["checkedRoutingSnapshot"], "forbidden": ["computeModelPreferences"]},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/CognitiveSubstrate/CognitiveSubstrate+Workspace.swift"], "required": ["persistMaintenanceTransition"], "forbidden": ["try await persistSnapshot(", "try await persistThoughtSeedFamily(", "try await recordReceiptChecked("]},
    {"id": "resident-mind-convergence", "files": ["Modules/NativeAgentCore/Sources/TurnTrace/TurnTrace.swift"], "required": ["_PersistPump", "capacity: 4096"], "forbidden": []},
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
        "Sources/NativeAgentApp/GitHubPlatformPorts.swift": "Area 1 composition handoff — live GitHub notification and cognition bindings",
        "Sources/NativeAgentApp/MemoryAppIntents.swift": "MemoryV2 / KnowledgeGraph — area number unmapped",
        "Sources/NativeAgentApp/MemoryRepairPresentation.swift": "MemoryV2 / KnowledgeGraph — area number unmapped",
        "Sources/NativeAgentApp/Models/ImprovementNextGenModels.swift": "Trust and shared model projections — area number unmapped",
        "Sources/NativeAgentApp/Models/TrainingImprovementModels.swift": "Trust and shared model projections — area number unmapped",
        "Sources/NativeAgentApp/NativeAgentIntents.swift": "App presentation/platform integration — area number unmapped",
        "Sources/NativeAgentApp/SensesAssembly.swift": "Area 1 composition handoff — live sense runner/provenance bindings"
      },
      "message": "Engine logic belongs in NativeAgentCore; the app retains views and platform adapters."
    }
  ]
}
```
