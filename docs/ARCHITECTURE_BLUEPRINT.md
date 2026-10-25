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
| `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | Shared completion route/requester identity and lifecycle projection; `isValidIOSDeviceRouteKey`; recovery, reporting and delivery admission share DataRootLife's stopped/restored result for unfinished prior-life sends; let_go remains terminal |
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
| `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift` | Persistent sense/resident-part contexts with fresh frozen input per call, synchronous run/face entries, fresh projection helpers, shared Swift fragment-redaction binding and SenseWire validation, JSC execution watchdog with ProgramProgressWindow arithmetic |
| `Sources/NativeAgentSenseHost/PlugIO.swift` | Bounded JSON-line transport and active-reply stall window |
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
`AbilityStore` owns `data/abilities/`: current, previous and proposed files,
run accounting in `abilities/state.json`, and JSON notebooks in `senses/<id>/state.json`.
Its bundled seed catalog owns the shipped ids reserved by `Parts.save`, together
with `native-`; future shipped parts use `native-`.
Each decoded source file carries its body digest; body edits refresh it.
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

`AppScriptRunner` adapts the app door to the shared `OwnedProgramRunner`.
`AppActions` owns dependency contract projection and frozen legacy pin identities;
argument/result schemas and revision are pinned independently of discovery prose.
Admitted authored tools are scriptable actions, including routine dependencies;
their calls retain ordinary skill checks and capture validation substitutes fixtures.
Their pinned action contract supplies the routine's read-before-act knowledge;
execution does not require a diagnostics-page version. Skill run accepts input
and its legacy args spelling; capture input errors report an argument remedy.
Script and authored-tool app calls re-enter the turn's ordinary dispatch chain;
tool reach (`reach` or `permissions`) constrains `host.network`, `host.program`, `host.apps.call`,
`host.model.call` and `host.fetch`; `secret:<name>` lets a call carry that keyring secret. `host.files/calendar/reminders/contacts` are prelude aliases
for existing folded door actions with their named arguments and results; their reach expands
to pinned door dependencies (file reads for read reach, mutations for write reach).
File paths, session restrictions, protected stores and the Full Mac write boundary
belong to those ordinary file actions; no file executor or classifier lives in the primitive broker.
Model thoughts inherit the admitted turn or wake run's client and routing tuple when no surface is selected;
an explicit surface admits its saved route with the parent's per-turn model choice set aside. Thoughts run without persona and with the caller's remaining
turn output budgets; `ability:<id>:<purpose>[:<signal>]` goes through ordinary model-call telemetry, never effect admission.
Thought output carries nested tool effects through success, failure, cancellation and JSON validation into the primitive receipt;
unestablished effects are unknown and a thought offering tools is not read-only for replay. Nested effects retain their own admission.
Tools, skills and senses share AbilityStore's notebook read/write/delete owner and lock,
keyed by part id, with scratch state during proof/preview and separate lifecycle accounting; a final drop deletes the part, accounting and notebook.
ToolExecution depends on ProviderRouting for that telemetry's independent request shape.
Fetch is the broker's: it uses its existing NWConnection pinned to its checked address,
TLS server name and platform HTTP message parsing, never resolves again in URLSession, and
returns redirects without following them. A fetch naming a connector refuses, pointing to
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
Tools, skills and turns renew progress on non-state host replies; state traffic
does not renew it. Senses renew on validated progress, accepted source reads,
published pages and news; host-reply waits are excluded from elapsed work.
The progress clock pauses during host work and renews on a non-state reply; provider
and network activity run under their own stream and dispatch deadlines, not this clock.
Stalled receives still expire.
Its envelope uses the dispatcher's authorable-name predicate, registered with the app policies, so an ability file cannot reclassify a Swift built-in.
The part header owns structured reach; tool records consume its projected permissions rather than treating reach itself as a list.
Primitive approval replay retains the originating broker through the existing host-call
subscription, rechecks the selected version and executes only the approved call.
The broker owns only model.call, fetch, raw network primitives and the run's screen watch (its frames are reads inside the admitted watch: no admission and no ledger row each; the watch leaves one receipt); ToolHost retains
declared app targets and the shared SystemAppleScriptAdapter call.
Primitive results and a tool's `returned` value are opaque data; outcome and effect classification reads only the receipt envelope. Authored business failure is reported by throwing a JavaScript error; `OwnedProgramRunner` owns that terminal verdict. MacControl's `SystemAppleScriptAdapter` is the single in-process OSA
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

Native executors in `ChatToolRuntime` and `AppToolRuntime` sit behind the app
interface. Their implementation names are not additional model tools.
`ToolNameAliases` maps folded names to actions and produces translated `app`
calls for refusals. `ChatOrchestration+ToolDispatch` rejects folded calls that
the provider request did not offer. Discovery is through `app`, without a
separate tool-loading workflow.

`ability.save` saves a part (`Parts`); once kept, by their under Full Mac or by the
owner's card, it is callable as `authored.<id>`.
Every executable keep/enable carries the exact digest shown when its row or
card was staged, including self-improvement approvals and their replay. The
ability-store read captures code, declarations and digest together; callers
without that review offer a read rather than executable approval. A nil
version restores only Markdown guidance, never executable code.
Executable approval cards are the owner's on the Mac or paired phone;
Telegram only points to that full review, and the agent's inbox door cannot
approve them even under Full Mac.
`AppActionRegistry` and `ToolNameAliases` own those mappings.
`Research+WebSearch` owns `web.search` (the built-in `web_search`): SearXNG answers,
every engine it has, with its results or its failure said plainly; no fallback hides
a broken SearXNG. A Mac without SearXNG searches through a browser: the result hands
their `browser_search` (Chrome through the extension when it is connected, else their own
browser), which they runs and reads. Doctor probes SearXNG only.

## Policy Chokepoints

`TrustCenter` and `SecurityCenter` retain effect-time authority. Full Mac uses
the operator's selected autonomy; macOS privacy-permission resets still require
explicit approval. `PeerTurnEffectPolicy` files the one card of a peer-steered turn: a turn an
untrusted agent started with its message; its first effect of any kind cards once, quoting the ask,
and an approved answer to that card (a verified approved replay) ends the peer floor for the run, a decline leaves it;
ordinary gates (destructive, privacy resets, domain) remain. Reading an
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

File observation reports failed initial/re-arming through `FileChangeWatcher`'s
status and failure callback. `FileChangeEvents.waitUntilArmed()` returns that
status; a failed observation finishes its stream without claiming an initial
edge. Returning from watcher construction alone does not prove usable sources.
Status reads wait for in-progress arming to finish; a successful vnode replacement
does not terminate subscriptions during the source-table gap. The subscription
and registry locks remain free for cancellation and failure delivery during that wait.
Reload debounce and derived-invalidation delivery retain entered work separately
from their timers. Cancellation/replacement requests cancellation and keeps
single-flight ownership through actual exit; only current pending edges admit
follow-up work. Response deadlines remain bounded without joining late work,
whose execution owner must retain exclusion/resources through actual exit.

## Background Loops

`BackgroundLoops/BackgroundLoopsManager` owns registration, execution and
status. Core `EngineLaunch` constructs the concrete loop registrations and
dependencies through installed native host effects. Each failure outcome is a Doctor reading whose
repair, when owed, is projected from Experiences (no parallel Desk finding); receipts and
execution backoff remain with the scheduler.

## Source Map Convention

Each directory label is relative to the repository root; table filenames are
relative to that directory. Each file owns one `// Blueprint: <table row>` line
directly after imports (at the top without imports). Edit that line, then run
`swift script/generate_architecture_blueprint.swift`; only marked table regions
are rewritten. Non-Swift files use their comment syntax; files without comments
stay hand-kept outside generated regions. `script/check_architecture_blueprint.swift`
requires a source-owned header in every non-test Swift file under `Modules/`
and `Sources/` (excluding `.build`) and every `Resources/abilities/*.js` part,
then checks generated equality, exact row placement and file existence. This
complete coverage replaces the former selected-prefix family allowlist and
duplicate basename-only table scan; the generator owns header/row validation.
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
| `AdvancedPageComponents.swift` | `AdvancedEyebrow` struct |
| `AgentContactsSection.swift` | `AgentContactsSection`: contact rows/actions from discovery state; offscreen capture reads never initiate discovery |
| `AgentScreenView.swift` | `AgentScreenView`: read-only agent home/room projection; preview never marks seen, writes or dispatches tools |
| `AlivePageKit.swift` | Alive page components: shared glass metrics/palette, headers, cards, pills, progress and flow layout for Today/Desk |
| `AnthropicSetupTokenInput.swift` | `AnthropicSetupTokenInput`: setup-token paste, submission and visible status through existing provider setup |
| `AppApprovalTransactionEffects.swift` | `AppApprovalTransactionEffects` struct and `ApprovalTransactionCoordinator.app`: app-bound approval factory and live executor/platform bindings; `AppApprovalTransactionEffects` struct; `ApprovalTransactionCoordinator.app` |
| `AppConnectorPlatform.swift` | live voice, notification, Mac control and device-sync bindings over core connector/integration policy and status owners; remaining composition belongs to Area 1; notification, EventKit and connector platform bindings over core policy/status owners |
| `AppDelegate+BackgroundTasks.swift` | `AppDelegate`: `registerBackgroundTaskHandlers` |
| `AppDelegate+Launch.swift` | `AppDelegate`: `applicationDidFinishLaunching`, `applicationShouldTerminateAfterLastWindowClosed`, `application` |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: `claimSingleAppInstance`, `presentSingleInstanceWedgedAlert`, `presentPublicReleaseDataRootError` |
| `AppModel+ChatActions.swift` | `AppModel`: `compactActiveChat`, `clearActiveChatMessages`, `regenerateAssistantMessage`, `startActiveChatTurn`, `startChatTurnForSession`; turn options from `ChatTurnRuntime/MacChatTurnCommands.swift` |
| `AppModel+ChatSessions.swift` | `AppModel`: chat load/selection/index refresh and `recordPanelRefresh`; sidebar refresh uses engine persona/configuration/runs/provider and connector owners; `composerDraft(for:)` owns one draft per session for main/detached composers and commands, exact accepted-edit clearing and empty-only prefills; quiet chat commands delegate to shared transcript/session transactions |
| `AppModel+ChatState.swift` | `AppModel`: `loadDetachedSessionMessages`, `pinChatSessionForDetachedWindow`, `pruneSessionChatState`, `pruneStaleSessionChatState` |
| `AppModel+GraphCapabilityActions.swift` | `AppModel`: `searchGraph`, `refreshGraph`, `runResearchLab`; Lab's frozen evidence calls the editable `research-lab` part through `Parts.call` and the canonical admission-only gate; native Research commits the accepted proposal |
| `AppModel+HealthEmbeddings.swift` | `AppModel`: `loadHealthCard`, `setHealthCardIfMeaningfullyChanged`; the Doctor owner's `LatestRead` orders health-card publication |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `resumeMacChatTurn` reconnects checkpoint progress to the existing stream adapter and lifecycle; `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory`, `consolidateMemory`, `applyMemoryConsolidationResult`, `runMemoryHygiene` |
| `AppModel+PersonalitySelfImprovement.swift` | Mac personality editor outcomes delegate profile/document publication and writes to `engine.persona`; support diagnostics and proposal actions |
| `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll`; Telegram form reads share `refreshTelegramSettingsDraft` with the direct refresh |
| `AppModel+RoutingWorkflowMCP.swift` | `ResearchSearchFailure`; `AppModel`: research `search`, `resolveApproval`, `resolveApprovalOnce`, `isResolvingApproval` |
| `AppModel+SkillsIntegrations.swift` | `AppModel`: built-in skill guidance and part Keep/off-switch; workspace creation, SearXNG autodetection and projection readback, Telegram settings/log actions and Doctor commands; `refreshTelegramSettingsDraft` captures and merges untouched form fields through one newest-started `LatestRead.refreshDraft` owner; connector updates verify through `engine.connectors.update` |
| `AppModel.swift` | `AppModel`: app composition, UI/editor state and engine access; provider, persona, configuration and run state derive from engine owners; connector rows derive from `engine.connectors.accounts`; inbox actions receive `engine.inbox`; shared chat draft/session and surface command coordination |
| `AppQuietLowerOnly.swift` | `AppQuietSettingsHost` and `AppQuietToolHost`: app connector/permission command bindings with Full Mac ownership limits and visible decisions |
| `AppQuietSettingsHost.swift` | `AppQuietSettingsHost` class; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: `runMind`, `managePart` |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppShellMenuPresentation.swift` | `NavigateMenuPresentation` and `MenuBarStatusPresentation`: menu order/shortcuts projected from the rail and one canonical status line |
| `AppToolPlatform.swift` | AppToolExecutor platform bindings: browser, notification, workshop decisions and away sensing; chat.post receives the engine's existing background speech client |
| `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |
| `ApprovalsView.swift` | `ApprovalsView`: checked approval decisions/history, payload preview and known risk-badge/toast presentation |
| `BotsEditorSheet.swift` | facade provider accounts and checked settings, shelf next-run projection, engine-owned fresh definition merge |
| `BotsShelfView.swift` | shared helper status and transcript messages/streaming tail; no private transcript rows or JSONL observation |
| `BrowserWindow.swift` | `NavResult` struct; `BrowserActionRoutes.app` over the visible window's route effects; actor-owned `BrowserCallbackWait` settles callbacks or cancellation once; physical exclusion remains until late WebKit callbacks exit |
| `CapabilitiesView.swift` | `CapabilitiesView` struct; shared engine NextGen snapshot and eligible actions; `AppModel.routeIntent`; `NextGenReceipt.humanized` |
| `CapabilityProductionHardeningPanel.swift` | `CapabilityProductionHardeningPanel` struct |
| `ChatClipboardAndAttachmentSupport.swift` | `ChatComposerSupport` and `ChatClipboard`: shared drop/paste/picker intake, destination capture and off-main image conversion |
| `ChatCodeBlockView.swift` | `ChatCodeBlockView`: selectable fenced code, language label and idempotent copy; no renderer state or clock |
| `ChatComposerChrome.swift` | `ComposerTabKeyHandler` struct; `makeNSView`, `updateNSView` |
| `ChatComposerDraft.swift` | `ChatComposerDraft`: the shared session text, edit timestamp and manual-edit revision for dictation; AppModel owns its lifetime and composers bind to the same object |
| `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |
| `ChatComposerSettings.swift` | Composer shell state/readers/layout and settings cards: shared main/detached composer presentation and quiet command port bindings |
| `ChatContextFillBar.swift` | `ContextFillPresentation` and context strip/ring: measured usage, model window and compaction controls; missing figures stay visibly unavailable |
| `ChatFocusedCommands.swift` | `ChatFocusedCommands`: active-window chat action closures and page visibility, keeping shortcuts out of hidden controls |
| `ChatInboxStrip.swift` | `InboxStripContainer`: compact unread-note/approval/card projection; reading does not resolve and settled origins archive their pointer |
| `ChatInlineApprovalCard.swift` | mounted approval card, transient interaction state and facade-owned decisions |
| `ChatMarkdownTable.swift` | `ChatMarkdownTableParser` and view: pure prose segmentation, alignment/cell parsing and rendered transcript tables |
| `ChatMessageListView.swift` | Windowed transcript interleaves HerScreen other-room exchanges from the contact projection; rows open the sidebar's contact thread; attachments use transcript-owned previews |
| `ChatPlatformAdapters.swift` | Chat platform adapters: attachment drops, editor-scoped paste interception and scroll event bridges with mounted-page visibility |
| `ChatQueuedTurnsView.swift` | `ChatQueuedTurnsView`: bounded session-scoped send-next chips, overflow and steer/send-now controls |
| `ChatShellPresentation.swift` | `ChatShellTrustPhrase`, `ChatShellStatus`, `ChatShellCopy`; trust/status projections and composer/greeting copy |
| `ChatShellViews.swift` | `ShellRoomHeader` struct |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatStreamingTail.swift` | `StreamingTailBubble` and observer: row-local live text updates without republishing the whole transcript |
| `ChatToolPillView.swift` | `ToolPillPresentation` struct; retained metadata projection, `outcome`, `title` |
| `ChatTurnFailure.swift` | `FailedTurnRetryConfirmation` and continuation binding: shared confirmation after effects/unknown outcomes and session-local continue action |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+DetachedSessionMenu.swift` | `ChatView`: `detachedSessionMenu` |
| `ChatView+PinnedSessions.swift` | `ChatView`: `humanPinnedSessionIds`, `savePinnedSessionIds`, `prunePinnedSessions` |
| `ChatView+SessionActions.swift` | `ChatView`: `showToast`, `rename`, `renameActiveChatTitle` |
| `ChatView+ShellColumn.swift` | `ChatView`: `shellSessionHasUnsentWork`, `shellSessionIsPinned`, `shellSessionRow` |
| `ChatView+SlashCommands.swift` | `ChatView`: `send`, `handleSlashCommand`, `dispatchSlashCommandTool` |
| `ChatView.swift` | `ChatView` struct; `ChatTurnNoticePresentation` |
| `ChatViewStateCoordinators.swift` | Chat view coordinators: viewport/follow state and occurrence-preserving composer toast queue independent of transcript layout |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` alias to `ChromeControl.ChromeExtensionFolder`; app-bound `setUp`, `setupMessage` |
| `CognitionObservatoryView+Affect.swift` | Observatory affect presentation: snapshot axes and warmth context distinguish disabled/unavailable evidence from real zero |
| `CognitionObservatoryView+Capsule.swift` | Observatory capsule/reflection panels and felt-mode gloss: read-only projection with no capsule text or behavior mutation |
| `CognitionObservatoryView+LoopHarness.swift` | Observatory loop/workspace/association panels: same-snapshot endpoint resolution and honest unavailable receipt/graph presentation |
| `CognitionObservatoryView+Metrics.swift` | `CognitionTensionsPresentation`: same-snapshot capacity/counter models for Observatory metrics and pruning panels |
| `CognitionObservatoryView+Organism.swift` | Observatory organism panel: read-only kernel rows distinguish off, empty, stale and malformed readings |
| `CognitionObservatoryView+Proposals.swift` | Observatory growth-week and developmental timeline: readout/receipt presentation from current cognition state |
| `CognitionObservatoryView+Shared.swift` | Observatory shared rows/count badges: explicit zero stays visible; unavailable or malformed counts never become fabricated badges |
| `CognitionObservatoryView.swift` | `CognitionObservatoryView`: research panel assembly, live dependency reads, override controls and persistence/feedback presentation |
| `CognitionProposalsView.swift` | `CognitionProposalsView`: read-only schema lineage from canonical Dream/REM approvals |
| `CommandPalette.swift` | `CommandPaletteView`: keyboard navigation/search across pages, sessions and saved items; coordinator owns navigation and canonical owners supply actions |
| `ComposerContextReceipt.swift` | `ComposerContextReceiptBody`, `ComposerContextReceiptCard` views; `LatestRead` on the shell (or standalone card) orders receipt publication |
| `ConnectorWizardView.swift` | `ConnectorWizardView` and state: existing connector setup routes, cancellable sign-in/save steps and truthful external-browser handoff outcomes |
| `ConnectorsView.swift` | `ConnectorsView` struct: engine connector projection for the secrets the keyring keeps (name, where each may go, account, when granted; Remove after a confirmation) and the built-in accounts |
| `ContentView.swift` | `ContentView`: Simple/Advanced/Agent shell assembly, navigation destinations, first-run presentation and iCloud action refresh routing |
| `ContextFlowObservatoryPanel.swift` | `ContextFlowObservatoryPanel`: health rows preserve off, unreadable and failed states instead of a reassuring zero table |
| `DeskDebugPanels.swift` | `DeskDebugPanels`: diagnostic disclosures over the engine's retained Desk revision |
| `DeskItemInspector.swift` | `DeskItemInspector` struct |
| `DeskNagsPanel.swift` | `DeskNagsPanel`: current nag configuration reads and explicit owner controls through Desk quick actions |
| `DeskPageView.swift` | `DeskPageView`: canonical work overview, bounded folds/detail actions and separate store/execution/schedule failure presentation |
| `DetachedChatPanel.swift` | `DetachedChatWindowController`: session-window creation, persisted pins/frames, focus, appearance and lifecycle teardown |
| `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session-bound transcript/composer, search, speech and attachment intake through shared chat owners |
| `DiagnosticsView.swift` | `DiagnosticsView` and refresh coalescer: one sequential shared snapshot across status/runs segments, with legacy tab routing |
| `DisclosureRowToggle.swift` | `DisclosureRowToggle`: whole-label disclosure hit target sharing the DisclosureGroup's existing binding |
| `DoctorView.swift` | `DoctorView`: measured report rows/footer, run/repair/support actions and explicit action failure presentation |
| `DreamsView.swift` | `DreamsView`: shared diary reads, selection, dream/REM controls and unavailable/error presentation |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `GrokSecureSetupCard.swift` | `GrokSecureSetupCard`: masked credential submission through secure setup, without exposing secret values in the view |
| `HealthPill.swift` | `HealthPill`: compact health status color/label presentation |
| `InboxCardActions.swift` | `AppInboxCardActionEffects`: mounted navigation and injected engine inbox; callers use the core inbox transaction directly |
| `InboxSettingsView.swift` | `InboxSettingsView`: master/trigger controls, independent writer outcomes and history navigation over canonical inbox policy |
| `InboxView.swift` | `InboxView`: canonical inbox lanes, digest groups, details and single-flight row actions; unknown sources stay visible |
| `InlineCard.swift` | Inline card view family: shared visual grammar and action closures for needs, approvals and receipts; no store or work lifecycle ownership |
| `InlineInteractionChatBinding.swift` | `InlineInteractionChatBinding`: card action/control presentation, existing setup sheets and verify-on-return settlement |
| `InlinePreviewCards.swift` | `ApprovalDecisionAction.resolve`: one inline approval resolve/toast/refresh sequence shared by deciding surfaces |
| `InspectorView.swift` | `InspectorView` and `TurnInspectorStore`: per-window live/replay selection over engine traces with separate requested/displayed date provenance |
| `InteractionCardDelivery.swift` | `InteractionCardDelivery`: `answer`, `act`; shared card transactions with native navigation; `AppInlineInteractionPlatformPort`, `AppInlineInteractionControlPort`, `InteractionInboxCard` |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphRows.swift` | Entity rows and detail render `MemoryFacade.graphSnapshot`, without separate neighborhood reads |
| `KnowledgeGraphStatusHeader.swift` | `KGNativeStackHeader`: renders the engine memory diagnostics and graph counts |
| `KnowledgeGraphView.swift` | `KnowledgeGraphView`: mounted graph, filters, policy and maintenance presentation; `loadKnowledgeGraphPolicy`, `reloadKnowledgeGraphPolicyAndGraph`, `loadGraph` |
| `LivingStatusPanel.swift` | `LivingStatusPanel` struct |
| `MacAssistantWatchSetupView.swift` | `MacAssistantWatchSetupView`: assistant watch/access controls, readiness reads and actionable Mail/permission checks |
| `MacChatOtherSessionsBanner.swift` | `MacChatOtherSessionsBanner`: affordance projection and navigation to work running in other sessions |
| `MacChatRunningSessionMenu.swift` | `MacChatRunningSessionMenu`: shared go-to menu for sessions with background turns |
| `MacChatTranscriptSearch.swift` | `MacChatTranscriptSearch` alias to `ChatSessionWork.TranscriptSearch`; `MacChatTranscriptSearchCursor`, `MacChatTranscriptSearchController`, `MacChatTranscriptSearchBar`; source preparation and search results publish through `LatestRead`, with input revisions retained only for coalescing; `TranscriptSearch.scrollTargetID` |
| `MacChatTurnCard.swift` | `MacChatTurnCard`: one display over canonical lifecycle state, shared by main/detached windows without card-local clocks or state machines |
| `MacControlPermissionsView.swift` | `MacControlPermissionsView`: checked policy/category controls, audit/workbench UI and explicit save/permission feedback |
| `MacIntegrationView.swift` | `MacIntegrationView`: checked integration read/write controls, actual permission probes and truthful System Settings handoff outcomes |
| `MacPairingView.swift` | `MacPairingView`: shared pairing assessment, key presentation/rotation and reveal lifecycle; offscreen reads never generate keys |
| `MacWorkOverviewDetail.swift` | `MacWorkOverviewDetail`: canonical work detail and decision actions, never the clipped overview copy |
| `MemoriesPageView.swift` | `MemoriesPageView` struct |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform`; pending proposals use the engine's review-eligible reader |
| `MemoryView.swift` | Memory page upkeep/status components: canonical consolidate/hygiene/Spotlight actions, full text and explicit storage/embedder availability |
| `MenuBarController.swift` | `GlobalHotkeyManager`: Carbon summon registration and tap/hold push-to-talk state with cancellable voice lifecycle |
| `MoodTint.swift` | Mood tint presentation: sampled canonical mood, damping/caps and accessibility-aware glass modifiers without independent feeling state |
| `NativeAgentApp.swift` | SwiftUI app and scene declarations; coordinator-gated async restore/recovery before model and ingress, off-main engine/layout preparation; `NativeAgentEngine.installRuntimeObservationsAtLaunch` through `EngineLaunch` to `BackgroundWork.BodyReport` Swift crash/exit logging |
| `NativeAgentAppCoordinator.swift` | `NativeAgentAppCoordinator`: process bootstrap and queued scene navigation; delivery receipts prove scene acceptance, not finished rendering or work |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`, `appShimmer` |
| `NativeAgentDesignTokens.swift` | `Color`: `NativeAgentFont`, `NativeAgentSpacing`, `NativeAgentRadius` |
| `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |
| `NativeAgentIntents.swift` | `NativeAgentChatIntent`: `perform`, `reply` |
| `NativeAgentMotion.swift` | `NativeAgentMotion`: shared timing/arrival transitions with Reduce Motion-aware layout and retained opacity crossfades |
| `NativeAgentNotificationActions.swift` | Native response mapping, notification categories and mounted window/conversation dispatch; effects stay in EngineNotificationActions |
| `NativeAgentWindowChrome.swift` | `MainWindowContent`, `MenuBarOpenButton`; main-window content and menu-bar opening |
| `NativeDisclosureTriangle.swift` | `NativeDisclosureTriangle`: AppKit disclosure button bridge sharing the row's expansion binding |
| `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession` |
| `NativeOAuthPlatform.swift` | `NativeOAuthPlatform`: `NativeOAuthPlatformPort` conformance and `isCanceledLogin` adapter |
| `NativeSearchField.swift` | `NativeSearchField`: NSSearchField bridge with native clear/escape/return behavior and explicit focus tokens |
| `OAuthSignInButton.swift` | `OAuthSignInButton` and presenter: in-process sign-in/sign-out, CLI session consent and current credential-state presentation |
| `ObservatoryNoticeRow.swift` | `ObservatoryNoticeRow`: one compact tinted notice presentation shared by Observatory panels |
| `OnboardingTourOverlay.swift` | Tour progress uses stable stop identity and reconciles rail changes from the engine layout passed by ContentView; only in-overlay progress is local |
| `OnboardingWizard.swift` | `OnboardingWizard` struct; provider rows, connection and Chat readiness derive from ProvidersFacade settings; only setup progress and drafts are local |
| `PersonaWriteReceiptRow.swift` | `PersonaWriteReceiptRow`: settled persona-write receipt projection using the existing inline receipt grammar |
| `PersonalityView.swift` | `PersonalityView` struct; document editing makes no claim that memory review writes the optional MEMORY.md input |
| `PollScheduler.swift` | `PollScheduler`: focus/stream-aware scheduling only for heterogeneous visible samples lacking a complete push owner |
| `ProviderSettingsComponents.swift` | `ProviderRowView` struct; ProviderConfigSheet receives its live connection by ID from ProvidersFacade; credential/model drafts and operation progress stay local |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `QuietSelfAdminRender.swift` | Quiet page assembly and app read/action host; Tools ability rows use Parts.list, including turn and senses; mounted presentation supplies the visible mode and Agent room for self-window reads, independently of Advanced sidebar `current` and its screenshot restriction; Today waiting uses `WorkOverviewRead`, helpers use the engine bot shelf, chat cards use the transcript owner's checked projection; page indexing/rendering receives live layout; context receipts read the engine data root |
| `ResearchView.swift` | `ResearchView`: search/configuration actions and eligibility/status presentation over root-scoped Research owners |
| `RunsView.swift` | `RunsView`: shared ledger list/details and explicit unknown/failure badge vocabulary from canonical run rows |
| `SchedulerView.swift` | `SchedulerView`: scheduled job controls and explicit accepted/refused toggle receipts |
| `SecurityCenterPanel.swift` | `NativeSecurityCenterPanel`: checked posture, kill-switch, flags and receipt presentation; local pending state lasts only through saved-policy reread |
| `SelfImprovementView.swift` | `SelfImprovementView`: weekly improvement switch, corrected-lesson growth reads and explicit manual-run feedback |
| `SensesAssembly.swift` | `SensesAssembly`: launch-only shared hub installation and gated raw-read bindings; quiet reads borrow no turn authority |
| `SensesView.swift` | `SensesView`; engine Senses projection, lifecycle controls and native share picker |
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
| `SimpleSetupPanel.swift` | `InlineCardSetupPresentation`: existing setup controls in a floating Simple panel or Advanced sheet/page |
| `SimpleShellView.swift` | Simple and Advanced shells render the engine's shared contact, helper and typed crew projection; only selection and formatting remain local |
| `SimpleThreadViews.swift` | Simple contact/helper/crew threads: canonical conversation/run projections and composers bound to the selected contact or helper |
| `SimpleViewMode.swift` | `ViewModeSwitch`: Simple/Advanced/Agent selection and shared top chrome placement |
| `SkillLifecycleView.swift` | `SkillLifecycleView`: persona-guidance list/search/source reads and explicit build-draft handoff through existing chat owners |
| `SkillsToolsView.swift` | `SkillsToolsView`: visible selection between reusable guidance and executable tools; each child retains refresh ownership |
| `SlimSettingsView.swift` | Operational settings presentation: canonical control homes, status wording and updater availability shared by settings page rows |
| `StatusView.swift` | `StatusView`: living system status and latest chronological activity projection with raw malformed-time evidence retained |
| `SystemPermissionPreflight.swift` | `SystemPermissionPreflight`: person-initiated macOS permission prompts before System Settings handoff, including Bluetooth prompt lifecycle |
| `SystemToastBar.swift` | `SystemToastCenter` and notice lane: replace-by-ID notices, owned auto-dismiss tasks and room-scoped positioning |
| `TelegramView.swift` | `TelegramView`: credential-free settings/status projections and save/test/log controls; outbound success never proves inbound poller health |
| `ThinkingGlow.swift` | `ThinkingGlow`: leaf-layer working shimmer and composer rim driven by turn state, fading when reply text begins |
| `ThinkingSlider.swift` | `ThinkingPane` and slider: model-supported effort presentation, bounded selection gestures and shared composer pane styling |
| `TodayView.swift` | Visible Today lanes and activity from `engine.today`; waiting shares WorkOverview with quiet Today; engine layout renders current blocks; note actions use `engine.inbox`; local row/sheet interaction state |
| `ToolInputForm.swift` | `ToolInputForm`: schema-driven argument draft, field validation and explicit submit for tools requiring structured input |
| `ToolsView.swift` | `ToolsView`: runtime/authored tool catalog, search/details, approval/lifecycle controls and operation status receipts |
| `TranscriptLayoutProbe.swift` | `TranscriptLayoutProbe`: opt-in per-row layout measurement and bounded diagnostic ledger, without changing transcript content |
| `TrustCenterView.swift` | `TrustCenterView`; confirmation states a normal backup is kept before scope replacement, failure replaces nothing, and previous-life work stays stopped until fresh Resume |
| `TrustGuardrailSummary.swift` | `TrustGuardrailSummary`: derived plain-language effective file/autonomy/backup/Mac/send reach, never another saved policy |
| `TrustPermissionsViews.swift` | Trust permission views: checked Chrome/multimodal/training/Workshop/memory policy controls through existing Trust owners |
| `UpdateController.swift` | `UpdateController`: configured Sparkle lifecycle, version probes and explicit unavailable/update presentation |
| `VoiceInputController.swift` | `VoiceInputCapture.forChat`: binds agent-name recognition context, person-visible macOS speech authorization and shared user-facing failures |
| `WindowHaze.swift` | Window haze components: shared glass backdrop, palette/saturation and appearance-aware window surface rendering |
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
| `TrainingImprovementModels.swift` | `HarnessBenchmarkRun.run(dataRoot:)`: app binding of authored-tool count, embedding availability and Doctor statuses to the shared benchmark owner |
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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/Owned*.swift Modules/NativeAgentCore/Sources/Senses/SensesContract.swift Modules/NativeAgentCore/Sources/Senses/Helper*.swift Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift Modules/NativeAgentCore/Sources/Senses/SenseScreenThings.swift -->
| File | Owns |
|---|---|
| `HelperSenseRunner.swift` | Isolated plug supervision with validated progress-based stall detection excluding app-served reply waits, read-to-watch idle holds, subscription-owned lifetime and restarts; source callbacks keep newest material and signal EnginePartWake for unattended interpretation, fenced by helper generation; canonical sense disable/replacement retires only that selected lifetime's passive helpers (including unattended on-call wakes) and pending admissions; late retirement and failure reporting cannot affect a replacement, and availability reports rejected by the registry post no news, while sense-identified accepted human on-call work settles with its requesting owner; notebook access delegates to AbilityStore; versioned use and visible live failure news, sealed view events, detached site following and app change deduplication/news; app reads use assembly's Trust-admitted read closure |
| `OwnedProgram.swift` | Program contract separating source digest from caller/candidate version, run/face entries over the same source, and ProgramProgressWindow: shared ContinuousClock renewal, host-wait exclusion and deadlines, with independent supervisor/JSC enforcement |
| `OwnedProgramRunner.swift` | Invocation-bound selection/dependency proof shared until canonical catalog revision changes; shared program execution, resident helper leases invalidated by canonical ability changes/removal, and what a resident ability holds (`holding`, one broker per resident life) kept in the same slot, selected under the store lock, surviving a failed run's dropped helper; retirement closes admission and retains teardown through completion before replacement publication, and terminal quit (`endResidents`) removes the catalog observer and drains teardown; helper-owned one-second process-tree RSS sampling remains because no equivalent threshold event is confirmed; fresh per-call authority/journal and resume freshness; host calls carry the part and its input in SkillRunContext; `host.state.get/set` for tools and skills reaches AbilityStore's notebook by part id (scratch for preview/validation); skill resume replays saved state results then persists new state operations normally, without renewing stalled execution; authored tools receive frozen home/workspace paths and their requesting data root; rooted file calls resolve app_data/workspace before the door, retaining path-array listing compatibility through ordinary paging; `ReadContent` collects owner-declared envelope projections and content dependencies, sharing normalization with replay argument comparisons without changing replies; a ledger row for a batch call carries its receipts' effects |
| `OwnedProgramStore.swift` | Retained ability file URLs, candidate identity, sealed rehearsal and publication through AbilityStore headers; rehearsal scopes supplied inputs and reached calls, never behavioral proof from intercepted replies; trusted bundled-seed proofs seal exact bytes without validation receipts or staging; kept proofs seal their Full Mac keeps without rehearsal; source-bound sense reads bind captured-material proof; OwnedProgramFixtures reads live and intercepts tool/routine effects and decisions |
| `SenseDoor.swift` | Registry-first reads, bundled-kind ownership, exact served provenance and file-material envelopes; the admitted request owns/cancels its shared raw flight, and cancelled reads cannot cache late material; captured views retain the turn's growth refusal, discarding refused file bytes while preserving screen/site read and action snapshots; distinct private web/visible browser/group-owned Chrome provenance, same-corner act verification without re-entry, wrong-version reporting, captured native/JS site action material, Chrome envelope continuations and native screen continuation snapshots |
| `SenseScreenThings.swift` | Exact screen thing selections, captured related-action bindings on composite rows, and in-turn mac.act verb requests |
| `SensesContract.swift` | sense records/contracts and SenseWire page/news/view validators and notebook byte bounds shared at both process boundaries, SensesHub registry projection and exact view-event admission, native catalog, memory provenance and durable unread news |
<!-- END GENERATED BLUEPRINT -->

### ActivityWatch

Directory: `Modules/NativeAgentCore/Sources/ActivityWatch/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ActivityWatch/ -->
| File | Owns |
|---|---|
| `ActivityPolicy.swift` | `ActivityPolicy` and `ActivityPolicyStore`: checked capture consent, exclusions, title permissions and policy persistence |
| `ActivityQuery.swift` | `ActivityQueryService.run`: gated activity reads, current-policy re-filtering, bounded rows and honest truncation |
| `ActivityRetention.swift` | `ActivityRetentionRunner`: durable last-run stamp, prune deadlines and policy-selected retention |
| `ActivityRollups.swift` | `ActivityRollups`: timezone-relative buckets, top apps and exemplars; span overlap is clipped to the requested range |
| `ActivitySpan.swift` | `ActivitySpan` and `ActivityCloseReason`: persisted activity intervals, redacted titles and close vocabulary |
| `ActivitySpanEngine.swift` | `ActivitySpanEngine.process`: capture state transitions, policy gates, source title redaction and store commands |
| `ActivitySpanStore.swift` | `ActivitySpanStore`; asynchronous per-root store acquisition shared by capture, retention and queries |
| `ActivityTitleRedaction.swift` | `ActivityTitleRedaction.redact`: the source boundary that removes secrets before titles enter spans or disk |
| `ActivityWatchController.swift` | `ActivityWatchController`, `ActivityCaptureIssue`; capture lifecycle, serialized off-main policy reads/writes and capture-ordered exclusion purges, exact policy-file invalidation and one retention schedule using the runner's completed-run stamp and effective clamped capture policy; issues join their Experience receipts, with injected platform error and notification presentation; Mac permissions, quiet controls and the menu indicator reach this same lifecycle/policy owner through engine.activityWatch |
| `ActivityWatchPaths.swift` | `ActivityWatchPaths`: one directory and file vocabulary for private ambient history, separate from activity event feeds |
| `ActivityWatcher.swift` | `ActivityWatcher`; capture-thread sources and ordered store pump; presence reads `MacPersonInput.presence`, capture idle-close remains separate and idle-resume reads `MacPersonInput.sessionIdleAfterAgentMotor` in every permission state without asserting presence; unexpected run-loop return degrades and retires capture; only the drained pump releases installation and pending restart ownership |
| `HumanPresenceStamp.swift` | `HumanPresenceStamp` enum; durable present/away crossings at `ActivityWatchPaths.presenceTransitionURL`, shared with the scheduler through `transitionURL` |
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
| `AgentACPApproval.swift` | `AgentACPApproval` enum; `connect`, `request` |
| `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` enum; helper discovery and shared execution; wake-runner process identity; OMP reply-job recovery |
| `AgentContactHealth.swift` | Shared reply-path health from the newest receipt's `no_reply_expired`, delivery failures and round trips; an app, program or recipe change since the proof is unverified, named ("Unverified since Muse updated to 7.0", "…since Hermes updated to 0.22.0", "…since the recipe changed"), with no repair; the next send or `agent.verify` re-proves. `repair` is the one repair: the contact's own send run dry (`AgentRecipeStore.dryRun`), for a send that sent nothing (`heal`: one retry of the same operation, or a harness item), and `agent.verify`, never the background check, which reads the last send's repair (an A2A contact's runs its dry run, `AgentPeerDiscovery.a2aCheck`); a desktop chat whose log changed shape after Return is filed, never retried, and a send that lands closes the contact's bridge items. Detached refreshes share one projection. Durable verification claims bound background checks to once per episode and once per contact per hour, without resend or a new poller. |
| `AgentConversationExchange.swift` | `AgentConversationExchange`: `started`, `absorb`, `validate`; partial text is retained separately from a finished reply; each exchange retains its receipt's shelf result UUID across subsequent sends |
| `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |
| `AgentConversationLive.swift` | `AgentConversationLive` struct; `projection`; the live hub flushes pending text when the resident owner stops, and already accepted sends publish later text immediately until they settle; flush identities reject superseded coalescing tasks |
| `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |
| `AgentConversationRunning.swift` | `AgentConversationRunning` class; `begin`, `end`; retains sends by row and operation through their matching exit, including Stop waiters when a follow-up begins; retains queued senders and background conclusions through actual exit; a response timeout does not release an accepted send's owner; withdrawing queued work wakes its sender to exit; Stop joins local send settlement before retiring and joining exchange-owned desktop readers; the continuation lifecycle closes reader admission and drains settlement before closing live publication |
| `AgentConversationSession.swift` | `AgentConversationSession` enum; `approvalRow`, `replayApproval`; `viaAbility` and `answer` (`agent.reply`): a contact reached through one of their abilities; queued follow-ups register for approval resolutions and execution settlements before reading, including replay failures recorded only in the approval store; conversation receipt writes also wake them, and they hold unsent at the one-day boundary without approval sampling; `clear_queue` withdraws queued and reserved messages immediately after cancellation admission, before cancelling or joining local work; sends and Stop requests settle through `settle`, with no persisted stopping state or second desktop terminal writer |
| `AgentConversationStore.swift` | `records` reconciles/saves denied approvals and publishes experience/live projections; `outcome_unknown` attention receipts use the session's `unsettledAttention` owner: unresolved sends stay waiting with the answer owed, terminal unknowns fail without claiming non-delivery; `records` and `recordsUnlocked` project stored reply deadlines through `AgentConversationView`; reporting expiry releases the conversation without settling its retained desktop observer, which writes its one terminal receipt, partial text and local release together at settlement; other reply expiry is terminal with no reply, while transport still accepts late answers; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `AgentConversationView.swift` | `AgentConversationView` enum; `read`, `codingReply`, `expiringReply`; `dotReply` projects Dot's existing half-hour wait from its stored send time for UI and contact reads. `claudeWorklogTail` is the shared bounded continuity/worklog reader; `claudeWorklog` exposes recent recorded work for contact reads and the read-only app action. |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter` enum; `checkEntry`, `writeEnvironment`, `ensureEnvironment`; absent/exact entries, same-peer reconciliation and stale-install helper replacement; foreign-entry refusal; `checking` validates without writing; removal names missing ownership receipts and preserves unproven bytes |
| `AgentHostConnection.swift` | `AgentHostConnection` enum; `builderWorkspaceRoot`, `isNamedConnect`; Connect resolves host or exact peer identity (a peer only in its own workspace; another folder is that folder's own contact), re-mints a missing key on the same contact, retires proof and rewrites only its connector entry under the settings lock; elevation remains store-owned; disconnect revokes before settings cleanup and keeps failed cleanup owed to the person through RepairOwed and fileRepairInstruction; missing helpers and secure-random failures name the defect and person; `verifySetup` stays read-only |
| `AgentHostDirectory.swift` | `AgentHostDirectory` enum; `bridgeDiscoveryDirectory`, `peerDescriptorDirectory`; `installation.evidence` is discovery/Connect/verify's one installation check; install markers must resolve to executable files or app bundles with executable programs, never profiles; recipe `executables`, `discoveryWords`, `searchPaths` and `messagingPermissionsPath` replace inferred program names, fixed discovery words, ambient path additions and a hardcoded host permission file |
| `AgentLaneHandles.swift` | `AgentLaneHandles.migrate`: once-per-launch migration of historically read lanes into explicit contact handles; grants remain door-owned |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery` enum; `authenticatedInterface`, `a2aCheck` (an A2A call's card held to its recipe; its dry run), `listTasks`, `probe` (discovery by protocol, never by name: an A2A card on any listening loopback port, a program carrying ACP's methods or advertising an ACP entry, a settings file holding an mcpServers table, all read from verified regular files; the recipe book read after, a find none knows carrying its `draft` recipe under an id of its protocol and path; on Agents and an explicit discover only, launch and installs keep the last finds); launch directly discovers/connects settings hosts from recipes without awaiting Spotlight; the index watcher adds later arrivals after any in-flight scan; recipe-location watchers reconcile once after arming within the same lifecycle; no elevation, and a found program runs (bounded --help and initialize) only on an explicit discover, under `Launch`, the send's own rule for running another agent's program (`agentProgramLaunch`: Full Mac as is, else the builder sandbox, denied or locked down not at all); persistent declines/disconnects win, running hosts get one restart note; host and pass-wide setup failures name files/fields and remedies per candidate and wake key, keep dismissible offers, and clear on automatic/manual recovery; `app.installed` for each whole bundle at a bundle id and version new since the first, silent installed-apps.json baseline |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy`: shared A2A origin normalization, `peerFailure`, `peerAuthorizeInterface`; discovery retains its separate card-to-contact check |
| `AgentPeerStore.swift` | Canonical contact decoding, identity projections and proof; authenticated inbound proof connects hosts without a command line too. `isReady` checks route/key proof, unavailable mark and ACP startability, while `AgentContactHealth` owns version/digest freshness. `list` prepares/chmods its directory before reading; summaries retain every contact with reachability and owner trust separately |
| `AgentPeerTransport.swift` | `AgentPeerCredentials`: credential uniqueness and availability; bearer comparison delegates to `BridgeCore` |
| `AgentRecipeStore.swift` | `AgentRecipeStore` enum: one recipe per agent host under agents/recipes/, seeded from the host tables and bundled `Resources/grok-routine.json` through the existing authored-field-preserving merge, read by `AgentHostDirectory.rows`, and one per A2A contact under its id (`AgentHostRow.A2A`, `recipe(for:)` seeds a missing one on the spot); `grokRoutine(dataRoot:)` rereads the editable Grok navigation file at each setup under the store/file locks; `load`, `recipe`, `launch` (Trust's reader), `read`/`write` (the door's, one shape check, under the file lock; write can create a new host.id without overwriting existing bytes), `learn` (a dry run's findings, source "learned"), `dryRun` |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport` enum; `listen`, `reconnect`, `stop`, `readiness`; retained socket observation and helper pipes close on the delegation runner's shutdown; generation guards reject old callbacks, accepted room deliveries retain their handles until exit |
| `GrokBotRoute.swift` | `GrokBotRoute` enum; `withHistory`, `takenByWaiter`; cancellation ends the waiter handoff without resampling |
| `HelperContact.swift` | Turn-local resident contact door for this install's helper; argument routing grants no authority and the actual send remains below the existing tool gates |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentConversations diagnostics |
| `PeerTrust.swift` | `PeerTrust`: installed trust reader and exact contact/principal resolution; authority follows attested doors and person grants |
| `PersonInitiatedSend.swift` | `PersonInitiatedSend` class; `matches`, `claim` |
<!-- END GENERATED BLUEPRINT -->

### AgentLinkTransport

Directory: `Modules/NativeAgentCore/Sources/AgentLinkTransport/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AgentLinkTransport/ -->
| File | Owns |
|---|---|
| `AgentA2AGRPC.swift` | `AgentA2AGRPC` enum; `send`; each streaming request retains its live-update forwarder and closes/cancels it on exit or cancellation |
| `AgentA2APushReceiver.swift` | `AgentA2APushReceiver` actor; `receive`, `consume`; authenticated task pushes invalidate the continuation through its canonical record writer; an owned invalidator registers before reads, replays pending hints, and retires on resident stop. Continuation startup makes saved waiting A2A task reads due after registering the invalidator, reconciling deadlines whose process-local push proof was lost at restart. The bounded mailbox retains current-process proof of delivery for each peer/task after consumption: proven push suspends sampling only after a validated task read; unavailable, invalid or thrown reads retain their short deadlines, while absent proof or an ended stream without push keeps fallback reads; GetTask stays authoritative and the one-day boundary remains |
| `AgentA2AStream.swift` | `AgentA2AStream` enum; `events`, `normalize`; shared stream accumulator |
| `AgentA2AWire+Mapping.swift` | `AgentA2AWire`: `canonicalPart`, `wirePart`, `canonicalState` |
| `AgentA2AWire+Operations.swift` | `AgentA2AWire`: `operationRequest`, `operationResult`, `normalizeTaskList` |
| `AgentA2AWire.swift` | `AgentA2AWire` enum; `selectInterface`, `messageRequest` |
| `AgentACPClient.swift` | `AgentACPClient` actor; `startupTimeoutReceipt`, `turn` (recipe-driven; no message is a dry run), `learned`; `Mismatch`: nothing sent |
| `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |
| `AgentACPProcess.swift` | `AgentACPProcess` approved spawn, process-group termination and reap |
| `AgentPeerHTTP.swift` | `AgentPeerHTTP` enum; `send`, `get`; each exchange retains its live-update forwarder and closes/cancels it on settlement, cancellation or deinit |
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
| `AgentContactState.swift` | Folds validated contact projections from `AgentPeerStore` into presentation identities; labels only ACP/MCP schemes as such. `AgentLocalHealth` owns 600-second freshness and 300-second refresh spacing; exact pull-reply read receipts. |
| `AgentConversationProjection.swift` | `AgentConversationRecord`: reply expectation is explicit or defaults true except short acknowledgements; `nextReadAt` schedules eligible automatic reads/delivery, not reply lifetime. Associated-door history projects through Transcripts' `ContactThread.project`; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `AgentWorkspace.swift` | `AgentWorkspace` enum; `dispatch`; `AgentWorkspaceNavigation.Session` retains the conversation's last undo receipt alongside its navigation, scoped by data root and session, never in a second ledger |
| `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback` enum; `dispatchEffect`, `followUp` |
| `AgentWorkspaceActivity.swift` | Native Calendar/Reminders and shelf adapters; Today supplies checked reads and bound item/action keys to `workspace-readout.js`; helper selection/copy is owned by that part, not a Swift bot projection |
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
| `AgentWorkspacePorts.swift` | `AgentWorkspacePorts` enum; the parts ranking the app door registers, read by the turn glance; workspace row decisions and pure helper faces enter L0 through the caller's native tool port |
| `AgentWorkspaceProjection.swift` | `AgentWorkspaceProjection`: async `project` sends Music and helpers through the owned workspace part while native readers retain the other areas; record titles stay native; `AgentWorkspace` binds receipt read refs through the existing workspace name book |
| `AgentWorkspaceReadiness.swift` | `AgentWorkspaceReadiness` enum; `withSnapshot`, `filter` |
| `AgentWorkspaceSavedReply.swift` | `AgentWorkspaceSavedReply` struct; `title`, `evidence` |
| `AgentWorkspaceWork.swift` | `AgentWorkspaceWork` enum; `desk`, `continuation` |
| `AgentWorkspaceWorkOverview.swift` | `AgentWorkspaceNavigation`: `workReceiptKey`, `placeAction`, `focusWork` |
| `DelegationStatusProjection.swift` | `DelegationDeliveryCache` class; `read`; consumes lifecycle decisions with their known principal and source; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `HarnessQueue.swift` | `HarnessQueue` enum, `HarnessFinding` struct; `file`, `resolve`, `fold`: keyed findings refresh in place, preserving closure and person ownership; wake carry opportunities share the existing ledger and its retained material fingerprint, reoffering only changed work; settled experience conditions name their release |
| `HerQueue.swift` | `MyQueueTurnProjectionProviding` protocol over cognition's Desk-revision-checked candidates and explicit refresh-pending-after-write state; `MyQueueReady` reads named experience conditions by primary key for unattended and recorded-session eligibility; `HerScreen`: `queueContext`, async `queueRows` shows those obligations, `resume` |
| `HerScreen.swift` | `HerScreen` enum; `withNames`, `resolve`, compact Senses home projection and readable full senses item from registry/news, sharing the live built-ability line with turn context; shared home/room crew rows and worker details preserve canonical SwarmCrew liveness |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom`; crews reuse HerScreen's crew rows and canonical SwarmCrew liveness, counting unknown separately from running |
| `HerScreenRooms+Build.swift` | `HerScreen`: `buildRoom`, `buildTarget`, `buildRecordRoom` |
| `HerScreenRooms+Comms.swift` | `HerScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `HerScreenRooms+Core.swift` | `HerScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `HerScreenRooms+Elsewhere.swift` | HerScreen door lines own completed other-room exchanges for the person's Mac/phone timeline and bounded words in home-turn context; peer turns never carry the person's words |
| `HerScreenRooms+Life.swift` | Native Music target bindings, status/unavailable evidence and rendering; playback narration, track/playlist curation and action labels are removed to `workspace-readout.js`; `lifeRoom` presents a failed nested Music readback with its full cause while retaining the original control receipt on its separate DONE line; `lifePulse`, `opening`; `HerItemPages` caches text without read-side peer lists |
| `HerScreenRooms+Web.swift` | `HerScreen`: `tabName`, `tabTitle`, `webTabCell` |
| `HerScreenRooms.swift` | `HerScreen`: `room`, `names`, `screen`; helper-room facts bind the shared cached `workspace-readout.js` face to native helper identities, targets, freshness and status; `HerOpened`: regular-app launches attributed only when known person-input idle exceeds both the oldest active work's age and 10 seconds; `recordedLaunches` is pruned at work end and intersected with running apps by the MAC room; work end requests a reminder, never quits apps; launch observation retires at the last work end or engine shutdown and rejects retired callbacks |
| `HerWorld.swift` | `HerWorld` struct; retained owner picture including contact histories and delegations; `HerMemo` refreshes on file and owner lifecycle invalidations, publishes completion, and tracks pending revisions without page-time source scans; observations share the 30-minute/128-key working window even without a value, and engine shutdown closes admission and cancels passive resources; child watches rebind on membership changes; room acknowledgements preserve stale parts; crew notices preserve canonical SwarmCrew liveness; name books retain their names lock |
| `HumanConversationIndex.swift` | `HumanConversationIndex` enum; `string`, `object` |
| `MacScreenPreviewBus.swift` | `MacScreenPreviewBus` enum; preview resizes the source-masked observation |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AgentWorkspace diagnostics |
| `ResidentWake.swift` | `ResidentWake`; arrival queue/claims stamp their beginning DataRootLife; pending work from another life (no stamp is the first life) reads stopped/restored and cannot wake, hand back or accept; retained original arrival content/evidence remains visible |
| `SurfaceLayoutStore.swift` | Root-scoped layout store and `SurfaceLayoutLive`; the engine's one observed layout feeds Mac, DeviceSync, quiet Today, page index and live tour stops. `read`/`write` validate one shape/version and preserve replaced bytes; chat fold writes route through `setSurfaceExpanded`. Snapshot reads publish through `LatestRead`; PrivacyMap inventories the whole ui directory, including the previous revision. |
| `ToolSignature.swift` | `ToolSignature` enum; `call`, `doorArgs` |
| `WorkContextQuery.swift` | `WorkContextQuery` struct; `matchedTerms`, `score` |
| `WorkspaceReadout.swift` | Frozen workspace facts and exact native item/action bindings; typed `workspace-readout.js` decisions select existing keys and labels, never manufacture targets, permissions or source status; selected helper details retain native identity and content |
<!-- END GENERATED BLUEPRINT -->

### Agents

Directory: `Modules/NativeAgentCore/Sources/Agents/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Agents/ -->
| File | Owns |
|---|---|
| `AgentBridgeCompletionRouter.swift` | Completion-route adapters and destination validation; saved let-go delivery stops at admission before asking-chat rows or dispatch; cancellation exits retry backoff and fences the next send; `AgentBridgeCompletionRouter`: `validatedRoute`, `deliverAnswer` |
| `AgentBridgeSurface.swift` | Peer framing, bound turns and conversation identity, including the in-process helper sender; header names the person's live exchange view and chat.post through the existing proactive speech owner; surface names confer no authority |
| `AgentContactRoutes.swift` | Authenticated contact ingress, MCP/A2A requests, retained reply pagination (failed prose followed by its terminal cause), event waits and transport-confirmed fetch acknowledgements; A2A HTTP waits retain their worker and cancel on connection failure or stop, preserving the reply path on receive half-close without canceling the accepted canonical turn |
| `AgentContacts.swift` | Root-retained contact clients, tasks, reply handovers and desktop routes; helpers of this install reach the resident through the same contact runtime with their own sender and thread |
| `AgentConversationContinuation.swift` | `AgentConversationContinuation`: durable reply reads, queued follow-ups and completion delivery through the existing delegation lifecycle |
| `AgentPeerReplayClaimStore.swift` | `AgentPeerReplayClaimStore`: principal/protocol/message digest claims and retained receipts; conflicting bytes refuse and prior-life unfinished claims do not resume |
| `BridgeLane.swift` | `BridgeLane`: bridge surface spelling and agent-authorship classification, without assigning identity or effect authority |
| `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation`; saved arrivals wait on `TurnAdmission` capacity signals; cached failed-admission peer IDs gate link recovery before peer/file reads; room cleanup keeps the first revised message per ID; successful recovery owns network/provider subscriptions until retirement, which releases recovery admission on failure, cancellation and stop; the delegation runner stops subscriptions with discovery and Dot socket observation; old lifecycle callbacks cannot retry admissions |
| `ClaudeBridgeMessageRuntime+AgentLive.swift` | `ClaudeBridgeMessageRuntime`: `agentLiveJobActive`, `handleAgentLive` |
| `ClaudeBridgeMessageRuntime.swift` | Bridge message admission/delivery and the retained chat client; event publication is a weak callback to the HTTP runtime |
| `ClaudeBridgeRuntime.swift` | Authenticated HTTP/contact routes and generation-ordered contact lifecycle; stop closes admission before passive cleanup, preserving accepted turns/tools; the 64-request ceiling inherited from connection admission now holds workers/actual tool dispatches until exit, beyond response deadlines; the shared human-pausable tool ceiling returns unknown on timeout without prematurely settling the tool receipt; one recovery per listener generation owns concurrent Codex/OMP children through exit, including SystemProcessAdapter-owned helper reaping; live payload publication, retained clients and event transport |
| `ClaudeBridgeStateProjection.swift` | `ClaudeBridgeStateProjection` enum; `procedureStatusJSON`, `microcycleTelemetryJSON` |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` struct; claims require the pinned response run; digest-bound answer and exact return intent; remote settlement delegates to the route journal; launch/event reconciliation isolates corrupt jobs and sends settlement candidates to codex_thread_wakeup.js, the sole reply-deliveries.jsonl writer; its existing ledger.lock protects compare-and-append and producer rotation; closed peer reply findings settle covered records as let_go; delivery admission, artifact reservation and dispatch transition reject let-go records before transport; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `DesktopAgentConversationRoute.swift` | The originating app door calls `Resources/abilities/desktop-courier.js` through L0 `Parts.call` for reply-address wording and the courier's constrained tool-turn procedure. Native code serializes exact recipient/message data and retains the tool-turn owner, exact-recipient/send-evidence fence, screen/input ownership, uncertain outcomes and settlement. Grok's direct native send/reply watch remains separate; part failure stops before courier typing, with no compiled procedure fallback |
| `DesktopChatRoute.swift` | Recipe-bound conversation selection, send confirmation and learned reads; MacControl owns bounded window/subtree reads, attributes, activation, AX mutations and input construction/emission; control searches exclude the message log, and incomplete reads remain read failures through waits and delivery receipts; shared desktop observation preserves reply quiet, title and setup deadlines, including a final condition read; answered receipts name the read method and wake; uncertain delivery without automatic resend; sends and late readers preserve produced text and release their resources through `settle` |
| `GrokBotConnection.swift` | Grok connection coordination and secure Bot selection/credential transactions; unfinished contacts resume from the durable pre-submission boundary without resending an uncertain request; setup blockers retain their own remedy |
| `GrokBotConnectionPort.swift` | `GrokBotConnectionPort` protocol; throwing `ensureRunning`, `send`, a bootstrap pre-submission callback and native import returning that operation's value-free field exposure receipt |
| `GrokDesktopReply.swift` | MacControl owns bounded native window/subtree reads and reply-text traversal; incomplete reads propagate to send and reply receipts; submission-owned shared desktop observation transfers once to its reply reader; a last non-answering reply must match across two idle AX reads at least 300ms apart, with one quiet-boundary read independent of notifications; the three-minute reporting deadline releases foreground ownership without claiming completion; no-notification interval observation ends at that deadline while supported events retain late-answer reach; reader settlement through `settle` saves the answer or partial with its actual read method/wake and releases observation and foreground once |
| `GrokInboundReply.swift` | Root-retained handover tasks deduplicate by message until actual exit; canonical `TurnAdmission.admittedRun` registers accepted runs for Stop/quit before session admission; `settle` writes their terminal handover result and releases ownership; the continuation lifecycle closes admission, cancels and joins them before closing live publication |
| `GrokRoutineAccessibility.swift` | A client of MacControl hands: shared bounded window/subtree reads find the Routines anchor outside the transcript, then search only its section; budget exhaustion reports search purpose and extent, never recipe drift; shared attribute/label/frame reads, transient menu roots, actuator mutations and event-sink input replace private AX primitives. Native-only routine credential transfer for the contact's selected Bot: editable recipe steps select the exact title with its Pause switch inside the Routines content list, `AXShowMenu` on its title group then Webhook; no chat-link or row-press path; masked fields use only their own Copy control with bounded native clipboard release through `settle`; field counts/readability and missing controls/menu items are reported without values, with their recipe file as the UI-drift lever; setup/send and foreground restoration use `SystemMacAXActSource.activate` under the original driver generation; panel cleanup and foreground release run through `settle` with an independent cancellation lifetime, still revoked by physical takeover; front waits use workspace events only; shared `DesktopRouteObservation` registers before the condition read and surfaces failed registration/renewal only after that read, uses 250ms `external_protocol_poll` wakes only for `source_unsupported` within each step's own deadline, and records the actual read method and wake; reverse navigation settlement dismisses only steps this import opened, stops on a failed child dismissal, and appends cleanup failure after the original blocker |
| `HumanConversationReplyService.swift` | `HumanConversationReplyService.reply`: explicit assistant replies through transcript and delivery owners; claim before mutation and no automatic replay |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Agents diagnostics |
| `NativeAgentA2AGRPCListener.swift` | gRPC loopback listener generation and endpoint publication; stop closes publication and retains the serving worker through graceful drain, excluding restart until actual exit |
| `NativeAgentA2AGRPCService.swift` | gRPC authentication, protocol/error projection and acknowledged stream delivery |
| `NativeAgentA2AWire+Parts.swift` | A2A content validation; file byte ceiling comes from Shared's `ChatAttachmentTypeResolver` |
| `NativeAgentA2AWire+Push.swift` | `AgentContactCallback` and `AgentContactPushConfig`: durable callback obligations, Keychain destination references and bounded push delivery |
| `NativeAgentA2AWire+REST.swift` | `AgentContactA2AEndpoint.handleREST`: authenticated REST binding over the shared A2A parser, task owner and projections |
| `NativeAgentA2AWire+Runtime.swift` | Contact task admission, runtime dispatch and reply/event framing; the same contact runtime revalidates a local helper against this install's definition, without granting peer elevation |
| `NativeAgentA2AWire+Tasks.swift` | Canonical contact task projection and record-owned accepted workers; failed settlement preserves streamed prose and offsets; transmitted reply acknowledgements route outbound evidence through AgentPeerStore.recordProof for MCP-host reply health; synchronous bridge admission closure precedes generation-ordered passive cleanup; approval/receipt observations, reply waiters/streams and push tails retire on stop, with canceled handles retained through exit; activation restores persisted owed callbacks, including terminal tasks outside live records; coalesced approval-refresh requests retain a pending pass so worker settlement and observation rearming cannot lose their wake; accepted workers and durable recovery finish independently of the listener, and explicit task cancellation remains separate; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `NativeAgentA2AWire.swift` | A2A bindings use contact task workers and a dedicated gRPC listener; turns execute through shared chat |
| `NativeAgentMCPWire.swift` | MCP negotiation, parsing, caller-supplied request identity and reply projection |
<!-- END GENERATED BLUEPRINT -->

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AppToolRuntime/ -->
| File | Owns |
|---|---|
| `AppActionRegistry.swift` | App action definitions and registry (`AppAction`, `AppActions`); dependency contracts omit the retired scriptability field; authored action lookup; one schema-aware semantic/lexical ranking for declared page items, built-ins, admitted tools, enabled skills and current senses, with shared retrieval stop words, a semantic relevance floor and model-epoch action vectors; explicitly requested retired tools are labeled read-only records; file Trash, recurring tasks and named contacts route to their owners; their own parts ranked and rendered from one inventory for the turn glance (`parts`), acknowledging only shown fresh parts; a receipt's `effect` names a run of their part as `part`; chat.post exposes the existing proactive speech seam |
| `AppChatToolDispatcher.swift` | Composed tool dispatch, Security Center admission and settled-result observers; `withAuthoredProgramHost` is the one host binding for turns and native scheduled/UI owners, retaining their originating gated reentry |
| `AppScriptRunner.swift` | Shared-runner app host adapter, the signing key's file revision for invocation bindings, dependency shapes and ordinary turn-chain re-entry; NativeAgentSecretRedactor owns recursive credential recognition for ordinary typing and flow steps, alongside declared credential args; digest-only saved pins retain their historical encoding, while full saved contracts ignore retired scriptability metadata; an older door id or an older spelling of a part's action in a part's code resolves through `partAlias`, as a turn's call does; declarations grant no action authority |
| `AppToolExecutor+AppDoor.swift` | The `app` schema and home/page/item/find/action/actions/script dispatch; self-window `visible` resolves through the mounted presentation before ordinary page lookup; compact expandable action catalogs, read-only conversion census and preserved domain execution receipts; owns version recovery, including sense.versions; generic failures and wrong or absent version scopes use action discovery, never registry scopes as page ids; `undo` re-enters the receipted layout, recipe or setting action's gates and restores through that owner; page action lists and guides use the same originating data root as their rows, including all face-page parts on Tools |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpAllowed`, `runChromeHistory`; history reads a private SQLite copy of Chrome's Default profile under Full Mac/file-read authority, with bounded rows and query deadline; `RetainedBrowserRead` keeps the visible read's full capture and receipt beside its rejected view; scroll readback carries the tab-bound viewport observation, with no timed delta retries |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`: `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall` |
| `AppToolExecutor+Health.swift` | `AppToolExecutor`: `doctorStatus`, `boundedDoctorDetail`, `doctorStatusEnvelope` |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+Make.swift` | `AppToolExecutor` Make actions: studio ref reads/writes, intake reads and reply image attachment behind the workspace fence |
| `AppToolExecutor+MyQueue.swift` | `AppToolExecutor`: `runMyQueue`, `runHouseFile`; filing receipts report the stored owner and explicitly say when a requested reassignment was not made |
| `AppToolExecutor+PagePresentation.swift` | screenshot results and quiet page/read rendering |
| `AppToolExecutor+PartRun.swift` | `AppToolExecutor`: a part's own run (`doorPart`: Desk holds, the gated `authored.<id>`, `afterPartRun`: MY QUEUE upgrade line, runner-owned effect reconciliation and action-owned version recovery, with fresh-run calls only for no effects, a strict stop kept to resume), `doorPartPreview` retains nested value-call version pins, `doorPartResume`, `partAlias` (the older skill.*/tool.* doors and older spellings of a part's action, until the release after the one that ships one-part), `doorWouldCard`; stopped checkpoints delegate to Desk’s `PartRunStore` |
| `AppToolExecutor+Photos.swift` | `AppToolExecutor`: `runPhotosRead`; read-only PhotoKit counts and recent asset metadata, with action-time macOS authorization |
| `AppToolExecutor+QuietMind.swift` | quiet mind commands and decision receipts |
| `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`: `performMacSelfAppRoute` propagates self-window look outcomes; only independently verified navigation retains its success with a supplementary observation; `quietPosture`, `freshQuietPosture` |
| `AppToolExecutor+SenseMake.swift` | `AppToolExecutor` sense authoring: captured admitted material, preview/keep lifecycle and owner-off authority without re-reading the source |
| `AppToolExecutor+Senses.swift` | Sense corner reads, served verb discovery and gated in-turn acts |
| `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`: immutable non-door schemas and independently lazy door schema via `appToolSchemas`, preserving the registry initialization boundary |
| `AppToolExecutor+UpkeepTarget.swift` | backup restore target validation |
| `AppToolExecutor.swift` | `AppToolExecutor` class; shared immutable descriptors; `execute`; chat.post routes to the conversation anchor through Reach's existing speech claim/quota; `macPersonAway` callback; home arrivals from app.installed runs retain bundle/version identity alongside the line without a new action argument; mobileNotify owns app/bridge notification defaults, verified session binding and previews, while AttentionRouter delivers |
| `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |
| `AppToolPorts.swift` | `BrowserToolPlatformPort` struct; `QuietToolPresentationPort` supplies mounted visible-page input separately from the Advanced sidebar page |
| `ChromePageText.swift` | `ChromePageText` enum; one `Projection` shares rendered text and addressable rows with the mirror and envelope; ordered inline prose with link proofs, section-named continuation headers, `project`, `rows`, page and folded-control `next`; `contentVersion` shared by the envelope and Chrome news without rendering |
| `ExistingCornersReaders.swift` | `ExistingCornersSourceProvider`: gated raw readers for screen, files, documents, connectors, private web, visible browser and Chrome; event-backed Chrome material for ordinary reads/following; `NativeChromeNews` observes from tab navigation, owns one tab-bound native reader subscription into `SenseNewsBoard`, retires it when its canonical sense is disabled/replaced, observes catalog changes only while subscriptions start/live, and sends capture failures to Chrome status without consuming its successful baseline |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for AppToolRuntime diagnostics |
| `NativeActionRoutes.swift` | `NativeActionRoutes` enum; `runNativeAction`, `swiftNativeActionRecords`; native receipts use Browser's shared path and appendPathOwnedJSONL retention |
| `NativeAgentNotificationPostResult.swift` | Re-exports `AttentionRouting` notification result contracts |
| `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |
| `NativeSkillRegistryActions.swift` | owner-facing enable/disable through `Parts` and capability-pack script-host binding; `enableSkill`, `disableSkill` |
| `PartThoughtTools.swift` | Restricted app-tool dispatcher for a part's thought, through its exact ToolHost and originating gate chain, with no independent effect authority; aggregates canonical nested receipt effects, including unknown in-flight effects, through thought failure/cancellation |
| `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`, `HazeColor`, `MomentsLaneSetting`; shared appearance, view and moments preferences |
| `QuietChatSessionCommands.swift` | `QuietChatSessionCommands`: effect-free session fences, session operations and queued-turn receipts through canonical turn owners |
| `QuietComposerCommands.swift` | `QuietComposerCommands`: draft/model/effort/persona/speech commands through composer ports; preview and execution share admission fences |
| `QuietInboxCommands.swift` | `QuietInboxHost`: inbox fences and commands |
| `QuietSelfAdminSettings+LowerOnly.swift` | lower-only settings rows and cognition/provider controls; Mac permission reductions enforce their subset under the authority file lock |
| `QuietSelfAdminSettings+Mobile.swift` | mobile settings projection and writes |
| `QuietSelfAdminSettings.swift` | `QuietSettingsHostProvider` typealias; static-first settings lookup and read-scoped bot projections, with fresh mutation readers; thinking writes only effort, preserving model/account inheritance |
| `QuietSettingsHost.swift` | `QuietSettingsHost` protocol; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `QuietTrustPolicyPreset+Action.swift` | trust preset action receipts |
| `QuietTrustPolicyPreset.swift` | `TrustPolicyPreset` enum; `save`, effective-policy preset matching |
| `ToolInteractionResolving+Transactions.swift` | interaction lookup and transaction resolution |
<!-- END GENERATED BLUEPRINT -->

### ApprovalInbox

Directory: `Modules/NativeAgentCore/Sources/ApprovalInbox/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalInbox/ -->
| File | Owns |
|---|---|
| `ApprovalInbox+ChatReceipt.swift` | Approval receipt rows and healing order; transcript bytes are written through ContactThread |
| `ApprovalInbox+EffectSpend.swift` | `SwiftNativeApprovalInbox` effect spends: durable consumption immediately before execution; a spend is not an outcome or permission to replay |
| `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `loadSpends` |
| `ApprovalInbox+ProcedureExactActivation.swift` | `SwiftNativeApprovalInbox` exact procedure activation cards and decisions, bound to the saved proposal and preview |
| `ApprovalInbox+ProcedureReview.swift` | `SwiftNativeApprovalInbox.approvedProcedureReviewerDecision`: production reviewer decisions bound to candidate evidence digests |
| `ApprovalInbox+RestoreFences.swift` | `SwiftNativeApprovalInbox.mergeRestoreFences`: pre-owner restore merge of monotonic spends, resolutions and continuation facts, with unreadable-piece receipts |
| `ApprovalInbox+SkillScriptInstall.swift` | `SwiftNativeApprovalInbox.askUserToInstallScript`: exact-digest executable review cards and install bindings; every deciding surface must show saved review |
| `ApprovalInbox.swift` | `SwiftNativeApprovalInbox`; canonical checked authority storage and decision/grant facts; recordsUnlocked/list share the originating DataRootLife projection for execution and chat continuation. Old approved but unexecuted work reads stopped/restored without changing the grant or settled outcomes; resolution stamps new work; raw offline validation remains side effect free |
| `ApprovalLifecycle.swift` | `ApprovalLifecycleBus`: post-commit approval transition fan-out and host reply context; the inbox remains decision authority |
| `ApprovalReplayAuthorizer.swift` | `ApprovalInboxApprovedReplayVerifier`: verifies replay authority against canonical inbox state and effect identity before approved dispatch |
| `ApprovalWords.swift` | `ApprovalWords.title`: shared plain-language approval names for Today and agent home |
<!-- END GENERATED BLUEPRINT -->

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ApprovalTransactions/ -->
| File | Owns |
|---|---|
| `ApprovalChatCards+Interactions.swift` | `ApprovalChatCards`: mirrors inline interactions into the person's conversation and Telegram while answers retain the origin card's identity and settlement |
| `ApprovalChatCards.swift` | Approval-card projection and notifications; transcript appends delegate to the chat owner, projection generations to ChatSessionIndexFile |
| `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects` port; `ApprovalTransactionCoordinator.decideBlockedWorkshopStep`; workshop-step decision/approval transaction |
| `ApprovalTransactionCoordinator.swift` | `ApprovalTransactionCoordinator` struct; delegates execution-record claim changes to Workshop's executor and terminal browser reads to the browser owner; reconciliation cursor coverage is declared here; `jsonString`, `memoryHygieneReceipt`; Desk resolution observation runs in BackgroundLoops' resident body; admitted Desk decision writes finish through `settle` |
| `DeskClickApprovalFiler.swift` | Package-scoped local-click approval filing under `ApprovalTransactions` |
| `InboxCardActions.swift` | `InboxCardActions`: engagement-before-effect ordering, primary action projection and spoken/draft delivery through one inbox claim |
| `InlineInteractionDelivery.swift` | Inbox pointers and inline-card delivery; BackgroundLoops owns observation and cancellation; `settle` releases its notification token and joins the retained recovery scan |
| `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort` protocol; platform probes/acquisition and activation/System Settings quit events for non-polling card settlement; GrantWatch consumes them in BackgroundLoops' resident body, coalescing taps and retiring each card's refresher |
| `InlineInteractionResolver+ChatLifecycle.swift` | `InlineInteractionResolver` chat lifecycle: repeated-ask projection, controls, permission return checks and verified card settlement |
| `InlineInteractionResolver+MissingProvider.swift` | `InlineInteractionResolver.raiseMissingChatProvider`: setup card before provider dispatch; only text-only questions can resume |
| `InlineInteractionResolver.swift` | Control/continuation resolution uses the chat owner's transcript CAS and stopped projection; same-life stranded claims alone may reclaim/replay. The person's Resume replaces stopped continuations with fresh work without captured blocked calls. Existing setup admission, Stop settlement and slot ownership remain canonical |
| `MacChatTurnApproval.swift` | canonical turn approval projection, card visibility and inline authority state |
| `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedKindBackfill`, `reconcileUnappliedMemoryRepairs` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ApprovalTransactions diagnostics |
| `ProcedureExactActivationApproval.swift` | `ApprovalTransactionCoordinator`: `applyResolvedProcedureExactActivation` |
| `REMLessonOrigin.swift` | `REMLessonOrigin`: approved lesson provenance and origin moments, retaining what changed and the exchange that taught it |
| `TelegramApprovalCoordinator.swift` | `TelegramApprovalFiler` actor; Stop closes prompt admission and drains accepted units through `settle`; approval and inline sends own their response and receipt, independently of transcript mirrors and cancelled callers; recovery covers pending prompts and delivered inline cards missing settlement receipts, honoring resident-wake quiet holds for new inline prompts; per-card edits retain their receipts; resolution waits subscribe before reading and release/join resolution events, file observation and the 15-second missed-event backstop through `settle`; expiry guidance names from PersonaEngine |
<!-- END GENERATED BLUEPRINT -->

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AttentionRouting/ -->
| File | Owns |
|---|---|
| `AttentionDeliveryPorts.swift` | `AttentionDeliveryPorts` struct |
| `AttentionRouter+MacNotifications.swift` | Native UserNotifications transport, message-route binding and notification admission/receipts; fire-and-forget posts retain their handles through the OS outcome, and shutdown closes admission without joining or cancelling accepted banners |
| `AttentionRouter+RequestedResults.swift` | `AttentionRouter`: `retryRequestedResults`, `deliverRequestedResult` |
| `AttentionRouter.swift` | `AttentionRouter` actor; `delivery`, `allowed`, `releaseHeld` retain notification destinations and routing metadata through quiet hours; all sends, including pinned commands, stay retained until settlement; terminal shutdown closes new admission and accepted sends finish without an unbounded join |
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
| `BackgroundLoops.swift` | `SwiftNativeLoopScheduler`, loop registrations and accounting: in-process scheduling, event deadlines, durable outcomes and worker lifecycle |
| `BackgroundLoopsManager.swift` | Core background-loop registration, execution and status; retains the engine's single resident observation body, cancels its effect on stop and joins its settlement before returning or replacement |
| `ErrorFeeds.swift` | `ErrorFeeds`: shared live error-feed inventory and bounded recent-burst scans for heartbeat and weekly improvement |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundLoops diagnostics |
| `PhysiologySelfWriteRegistry.swift` | `PhysiologySelfWriteRegistry`: writer-generation suppression of watcher echoes, without time-window suppression of external writes |
<!-- END GENERATED BLUEPRINT -->

### BackgroundWork

Directory: `Modules/NativeAgentCore/Sources/BackgroundWork/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/BackgroundWork/ -->
| File | Owns |
|---|---|
| `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `completeMessages`; task-only context for `recall_judge`, `memory_interpret`, `memory_held`, and `kind_backfill`; other work honors caller-bound context assembly |
| `BackgroundWorkPorts.swift` | Background work ports; typed content-only `AssistanceCardContent`, `BackupTrigger` and maintenance part invocation seams; `storeAndFileEvents` |
| `BodyReport.swift` | Crash breadcrumb paths and fatal-signal/process-exit logging |
| `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork` enum; `makeTelegramChatHandler`; `fileSystemPermissionNotice` passes native Speech Recognition facts to maintenance-assistance, retaining permission checks, retirement, sticky-status publication and delivery |
| `DelegationBackgroundWork.swift` | `DelegationBackgroundWork` struct; `makeDelegationOutcomeLoop`, `delegationJobSnapshot`; one owed-answer notice per peer, retires the duplicate Codex backlog card; one failed-before-answer finding per peer or human route, dated counts and bounded newest-first file refs; per-peer findings persist and refresh every covered delivery ID as a trace ref; closed peer findings settle only those IDs before reply reconciliation; Telegram's index and exact iOS events retain settlement ownership |
| `DelegationOutcomeLoop.swift` | Delegation terminal snapshots, exact durable cursor, outcome/liveness classification and settlement runner |
| `DeskContinuationScheduler.swift` | `DeskContinuationScheduler` actor; `nextDeadline`, `runDue`; checkpointed runs retain their process-resume owner; `prompt` calls the editable `turn-continuation` seed through L0, then inserts native checkpoint evidence into typed cue slots without sending receipt/partial-reply text into JavaScript; claims, verification and CAS stay native; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `DeskNotifyRunner.swift` | `DeskNotifyRunner`: calls the desk-notify part through the scheduled owner's originating app door; revision-checked native commit before notification delivery, quiet hours, stamps and exact-deadline scheduling; already-committed held deliveries retain their native release path even when a new proposal fails |
| `DoctorLoopHealth.swift` | `DoctorLoopHealth`, `LoopHealthVerdict`; health, dormancy and schedule interpretation of supplied manager observations, plus bounded failure-receipt parsing |
| `DoctorLoopRecovery.swift` | `DoctorLoopRecovery` enum; `checks`, `repair` over core loop-manager state |
| `DreamBackgroundWork.swift` | `DreamBackgroundWork` enum; `runREM` routes typed decode failures and healthy settlement to the shared finding sink; `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager` |
| `HeartbeatBackgroundWork.swift` | `HeartbeatBackgroundWork` struct; `makeHeartbeatLoop` uses per-condition templates without a model call; `HeartbeatLoop` owns heartbeat work |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `MaintenanceBackgroundWork.swift` | `MaintenanceBackgroundWork` struct; Doctor and loop failures owe repair through DoctorStatusProjection; Doctor ask grouping and storage card narration live in Resources/abilities/maintenance-assistance.js; native ask eligibility, disk accounting, unavailable plan reads, saved executable cleanup scope, cleanup receipts and acknowledgment by finding identity stay here; no JS under the publication lock; Resources/abilities/backup-cadence.js selects off-disk freshness and identity-change timing, with native volume/metadata observations, root protection and backup execution; canceled deadline reads return without a backup outcome, canceled ticks skip; actual cadence failures name the part, cause and repair/restore lever in offdisk_backup's failed scheduler receipts and Doctor/maintenance health, never a not-due skip or substitute cadence; unavailable observations never become empty inputs; the weekly Workshop digest is supplied by EngineLaunch through the ordinary maintenance part door, with unavailable evidence failing the pass; weekly signals use chat, live error feeds and Doctor health, without the retired Python sink or skill registry; self-improvement captures the checked part row's full review and digest in enable cards, deduplicated by finding and exact version; retention, backup work and manual weekly-run token lifecycle; DoctorFacade owns observed digest reads |
| `MemoryConsolidationHygieneRunner.swift` | `MemoryConsolidationHygieneRunner` struct; `tickOutcome` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for BackgroundWork diagnostics |
| `TelegramBackgroundBridges.swift` | `TelegramAccountModelCatalogPort` struct |
| `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork` enum; `makeJobWork`; event/deadline runner for canonical scheduler jobs and inbox occurrences; briefing prompt and synthesis policy live in `native-morning-brief.js` |
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
| `Browser+OperationStore.swift` | SwiftNativeBrowserClient's checked run-array schema, lifecycle writes and terminal vocabulary shared by reconciliation; derived receipts and traces use appendPathOwnedJSONL; local backup/export/raw phone sync excluded, PrivacyMap lists Browser Runs |
| `Browser.swift` | Browser status delegates run decoding to the operation owner and retains its existing malformed-feed error; operation/capture paths and status projection; WebKit owns website data, with no advertised data-root profile |
| `BrowserActionRoutes+DOM.swift` | DOM scripts, mutation/readiness-driven reads with one 3750ms deadline and operation-owned cancellation, result decoding and browser errors |
| `BrowserActionRoutes+IPC.swift` | authenticated IPC route decisions over window effects |
| `BrowserActionRoutes+NativeActions.swift` | `BrowserActionRoutes`: `runBrowserNativeAction`, `stringInput` |
| `BrowserActionRoutes.swift` | `BrowserActionRoutes` struct; `observeBrowserMotorAction`, `runBrowser`, direct dry-run/cancel commands to the canonical operation store, task-local `retainRead` delivery of the exact visible read capture |
| `BrowserCaptureCache.swift` | `BrowserCaptureCache`: serialized bounded storage and grouped eviction of disposable perception artifacts; expired captures require new observation |
| `BrowserIPCServer.swift` | browser IPC routing and shared NativeLoopbackListener transport conformance; browser_ipc.json alone publishes endpoint/token discovery and Doctor readiness events, with backup/export/phone exclusions and privacy coverage; no duplicate token file writer; connection retirement cancels its routed task; deadlines report unknown effect outcome |
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
aging alone requests a fixed keep-tail. Provider distillation runs outside the transcript lock.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatSessionWork/ -->
| File | Owns |
|---|---|
| `CarriedAnchorRecollection.swift` | `CarriedAnchorRecollection` enum; `isEnabled`, `seeded` |
| `ChatCompactionBackupRetention.swift` | `ChatCompactionBackupRetention` enum; `enforce` |
| `ChatCompactionDistiller.swift` | `ChatCompactionDistiller` struct; `maxSummaryChars`, `thirdPersonSubjectCount`; transcript replacements and index commits use Transcripts' storage owners |
| `ChatSecretRedactor.swift` | `ChatSecretRedactor` typealias |
| `ChatSessionAgingConsolidation.swift` | `ChatSessionAgingConsolidation` struct; `scheduleTranscriptAgingIfNeeded`, `runTranscriptAging`; coordinator retains bodies and 300-second cancellation deadlines, releases claims only at body exit, closes admission at engine termination |
| `ChatSessionAutocompactor.swift` | `ChatSessionAutocompactor` struct; `compactIfNeeded`, `pruneCompactBackups`; ContactThread writes transcript and original-history bytes; `ChatSessionAutocompactionConfig` owns `effectiveWindowTokens` and the read-only `contextWindowReadout` used by page reads and runtime introspection. |
| `ChatSessionDirective.swift` | `ChatSessionDirective` enum; `safeComponent`, `recordURL`; seven-day delivery eligibility leaves expired/delivered records on disk |
| `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` selects repairs and commits through ChatSessionIndexFile |
| `ChatTranscriptEvidenceRendering.swift` | recorded tool outcomes and attachment evidence; voice history renders the retained utterance and original audio reference; re-exports ChatToolParsing's shared result classification |
| `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |
| `ContextBudgetPolicy.swift` | Shared model-input budgets for every door; `compactionHistoryCharacters`, `floors`; derived budget reuse by exact effective window after current model/catalog resolution |
| `HistoryWindowCursor.swift` | `HistoryWindowCursor`, `HistoryWindowCursorStore`; locked advancement persists only changed boundaries |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatSessionWork diagnostics |
| `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore` struct; `record`, `recordConversationContinuation`; the locked validation supplies physical rows and append bytes to shared retention |
| `OutcomeTissueV2.swift` | `OutcomeEvidenceState` enum |
| `OutcomeTraceIdentity.swift` | `OutcomeTraceIdentity` enum; `normalized` |
| `SessionDigestProvider.swift` | Participant-bound prior-conversation selection and frozen handoff; `pointerSentence`, `digest`; peer identity is independent of session-id shape |
| `SessionHistoryMessageProjection.swift` | `SessionHistoryMessageProjection` enum; `admission`, `project` |
| `SessionHistoryPromptRenderer.swift` | `SessionHistoryPromptRenderer` enum; `renderDetailed`, `recallQuery` |
| `SessionHistoryReader.swift` | `SessionHistoryReader` actor; `messages`, `messagesWithStats`; initialization leaves retired middle-index files untouched |
| `SessionMessageProvenance.swift` | `SessionMessageProvenance` |
| `TranscriptSearch.swift` | `TranscriptSearchDocument`, `TranscriptSearchResult`, `TranscriptSearchResponse`, `TranscriptSearch` |
| `TurnVolatileArchive.swift` | `TurnVolatileArchive` actor; `load`, `record`, `prune`; pruning removes only obsolete observed runs whose entries still match under the file lock; registry owns demand-triggered single-flight orphan expiry through exit and closes retention at engine termination |
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
| `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding` enum; `pending`, `glance`; workspace tool port derives bounded built/recent ability names from canonical tool, skill and sense availability |
| `AppRestartCoordinator.swift` | Shared detached native relauncher observes parent exit before opening; tool restart audit/cooldown/grace and 120-second exit deadline; operator menu/restore retains 30-second deadline; stalled quit aborts relaunch |
| `BotChatContract.swift` | Helper identity, personality, job/output instructions and checked provider choice; helpers follow Chat unless explicitly pinned |
| `BotRunConversation.swift` | `BotRunConversation` enum; `enqueueRequestedCheck`, `dispatch` |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator` actor; `resolve`, `bind`; allocation reserves config root/agent/conversation before suspension and waiters reread the winning assignment; checkout reservations exclude reuse/allocation/binding from retirement through Git awaits, with freshness reread while held; unreadable or invalid retained pointers refuse continuity with the exact field and fileRepairInstruction for the person, never a coding-agent repair call |
| `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas` |
| `BuiltInToolSchemaFactory+CoreSchemas.swift` | `BuiltInToolSchemaFactory`: `coreSchemas`, unchanged `context_expand` descriptor |
| `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |
| `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |
| `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory` struct; `requestedSchema`; common constructors come from `PersistenceCore.ToolSchema` |
| `CanonicalToolNameDispatcher.swift` | `CanonicalToolNameDispatcher` class; `canonical`, `dispatch` |
| `ChatFullMacYoloAdmission.swift` | `ChatFullMacYoloAdmission` enum; `admitted` |
| `ChatHistoryIndex.swift` | `ChatHistoryIndex` class; `shared`, `absorb`, `absorbAll`, `livedLines`; durable content-addressed index of transcript lines for history search (chat/index/history.sqlite) |
| `ChatToolDispatchTrace.swift` | `ChatToolOutcome`: `normalizedFailure`, `failure`, `outputLooksSuccessful`; a turn-bound receipt is also the evidence of its act experience |
| `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction` enum; `injectionRedactedArgJSON`, `injectionRedactedResultJSON` |
| `ChatToolRuntimeImports.swift` | Re-exports `ChatTurnContracts`, `AgentConversations`, `AgentWorkspace`, `ChatSessionWork`, `ChatToolParsing` |
| `ChatToolSessionInjection.swift` | `ChatToolSessionInjection`: verified-session → tool-loop-session selection and shared internal/tool-specific session injection |
| `CodexImageGenerationControls.swift` | `CodexImageGenerationRequest`: `normalizedForBuiltIn`, `normalized` |
| `CodexImageGenerationHelp.swift` | `CodexImageGenerationHelp` enum |
| `CompactActionReceipt.swift` | `CompactActionReceipt` struct; `toJSONValue`, `toolDispatch` |
| `FluidContextToolScope.swift` | `FluidContextToolScope` enum; expanded memory pages retain stored untrusted sources |
| `GitHubCommandCheckoutResolver.swift` | `GitHubCommandCheckoutResolver` enum; `resolve` |
| `HarnessDecidedRow.swift` | `HarnessDecidedRow`: rolling per-requester/tool decision visibility without push; info writes stay off the tool gate's path |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | `InlineInteractionRegistry` enum; `connectorSetup`, `canonicalConnectorID` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatToolRuntime diagnostics |
| `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher` class; `peerApproval` shares live trusted-turn and peer-floor decisions between preview and execution; a peer-steered lifecycle write asks its one command card at the gate like any effect, and the ability stores refuse it until that card is answered; memory notes retain origin attribution checks; read results keep source labels without collecting steering peers or quoted lines |
| `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`: `impl_tool_result_page`; retained-response search coverage and source-positioned matching records |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: `drivenAgentLaunch`, `drivenAgentContact`, `stampDelegationProducer` |
| `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `builtInAgentLaneUsable`, `impl_agentCommunication`; command settlement joins its output consumer before reading replies and releasing its directory/probe |
| `SwiftToolDispatcher+ArtifactContext.swift` | `SwiftToolDispatcher`: `impl_artifact_find` |
| `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots`; `builderLaunch`, the one way a command line starts (sandbox, starting folder, SwiftPM shim) for the shell tools and a part's program; builder and detached installer terminal audits run in SubprocessWork settlement |
| `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage` |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | `SwiftToolDispatcher`: `impl_search_chat_history`, `impl_read_chat_message` |
| `SwiftToolDispatcher+ClaudeBridgeTools.swift` | `SwiftToolDispatcher`: `runClaudeMessage`, `claudeReceiptStatus`, `markWakeStartedNothing` |
| `SwiftToolDispatcher+CodexBridgeTools.swift` | `SwiftToolDispatcher`: `codexBrainControls`, `agentBridgeReplyOrigin`, `runCodexMessage`; inbox admission delegates to `codex_wake_inbox_projection.js`, the sole inbox/history mutation owner, with the helper's directory lock; SubprocessWork settlement retains partial replies and writes the terminal audit and Runs projection |
| `SwiftToolDispatcher+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, bounded anchored `impl_recent_trace_summary` pages; receipts span conversations by default, rank non-read actions first and scan complete retained since windows; `trace.usage` and `trace.model_calls` share this route and `TurnTraceRecentReader` for recorded sums, purpose counts and retention coverage; explicit session filters and bound turn refs |
| `SwiftToolDispatcher+DelegationTools.swift` | `SwiftToolDispatcher`: `impl_delegation_status`, `delegationStatusLimit`, `delegationStatusOffset` |
| `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`: `deskAlias`, `impl_desk_read`, `impl_desk_add_item` |
| `SwiftToolDispatcher+DesktopPixels.swift` | `SwiftToolDispatcher`: `desktopPixelsRequested`, `desktopPixels`, `impl_mac_screenshot_save` saves system captures without model pixel delivery |
| `SwiftToolDispatcher+Dispatch.swift` | `SwiftToolDispatcher`: `withWebScheme`, `dispatch`, `preApprovalRefusal`; due-reminders passes the requesting dispatcher's data root through its Mac bridge; image generation binds its native receipt's exact output paths for Make registration, and keeps completed generation artifacts and metadata top-level beside `make_registration_failed` so every reply surface retains the artifacts; `mac_location` answers with the fix the kept CoreLocation owner holds, and its age, or requests its ordinary Location permission card |
| `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |
| `SwiftToolDispatcher+FourVerbPerception.swift` | `SwiftToolDispatcherFourVerbPerceptionSource` struct; whole native masked observation through recognition, region crop and JPEG fitting only at model delivery; window obstructions from MacControl's `SystemMacVisualObstructionProbe` |
| `SwiftToolDispatcher+HumanConversations.swift` | `HumanConversationSnapshot` struct |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`: `impl_image_generate`, `showGeneratedImages`, `imageGenerationReferences`; Codex settlement preserves captured output and produced images through Stop, then writes one terminal receipt |
| `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |
| `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`: `impl_search_kg`, `kgSeenDate` |
| `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |
| `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`: `dispatchMacIntegrationTool`, read-only MapKit directions, distance-fraction place lookup and radius-bounded nearby place search via `impl_maps_route` / `impl_maps_search`, sharing `place` / `describe` |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` retain provenance on readback (a read steers nothing); `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`: `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata` |
| `SwiftToolDispatcher+MomentTools.swift` | `SwiftToolDispatcher`: `impl_memory_moments_pending`, `impl_memory_moment_review` |
| `SwiftToolDispatcher+OMPBridgeTools.swift` | `SwiftToolDispatcher`: `runOMPMessage`, `ompSessionSaved` |
| `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`: `impl_get_persona_doc`, `impl_persona_read`, `impl_persona_write` |
| `SwiftToolDispatcher+Reach.swift` | `performReach`: `programReach`, a part program's shell access check and launch plan |
| `SwiftToolDispatcher+RemoteNodes.swift` | `SwiftToolDispatcher`: `impl_remote_node_list`, `impl_remote_node_execute` |
| `SwiftToolDispatcher+Sandbox.swift` | `SwiftToolDispatcher`: `resolveSandboxed`, `stringArray`, `normalizeFullMacPathArgument`, `openScreenWatch` (a part run's watch under the four verbs' access, card and sight); implicit point acts use MacImageFrames' newest session image, acquiring the first through the canonical mac.look pixels:true path before input; explicit unknown image references remain refused |
| `SwiftToolDispatcher+SchemaBuilders.swift` | `SwiftToolDispatcher`: `builtInToolSchemas` |
| `SwiftToolDispatcher+Senses.swift` | `SwiftToolDispatcher`: sense corner resolution and authorized raw material adapters |
| `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher`: `standingBotApprovalReason`, `standingBotsArgumentRefusal`, `impl_standingBots` |
| `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`: `impl_studio_canon`, `impl_studio_canon_resolve`; native evidence reads and transactional staging consume studio-canon proposals, retain pending/pass caps, fingerprint dedupe and agent-only decision authority; unavailable sources throw, never become an empty tending pass |
| `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`: `impl_studio_shelf`, `studioImageInvitation`, `impl_studio_consult`; journal refresh holds the existing journal flock from read through graph commit and audit |
| `SwiftToolDispatcher+SubprocessSupport.swift` | `SubprocessWork` owns launch admission, verified process tree, timeout and physical exit; Stop freezes and kills the effect tree immediately, then `settle` releases descendants and runs the adapter's one output/audit settlement; shared bounded invoke/image pipe capture with adapter-specific limits and decoding |
| `SwiftToolDispatcher+SwarmTools.swift` | `SwiftToolDispatcher`: `impl_agent_swarm` |
| `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: `optionalNumber`, `jsonString`, `jsonInt` |
| `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file` (window parsing, ceilings and omitted defaults belong to `FileSystemActions`), `fileReadPresentation`, shared `impl_file_metadata` for list/info, `impl_trusted_file_mutation` (workspace writes and Trash) |
| `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |
| `SwiftToolDispatcher+WorkContext.swift` | `SwiftToolDispatcher`: `impl_work_context`, `workContextDeskItem`, `boundedWorkContextValue` |
| `SwiftToolDispatcher+WorkshopTools.swift` | `SwiftToolDispatcher`: `impl_workshop_submit`, `impl_workshop_status`, `impl_task_ledger_post` |
| `SwiftToolDispatcher+WorkspaceDesk.swift` | `SwiftToolDispatcher`: `workspaceDesk` |
| `SwiftToolDispatcher.swift` | Native dispatcher construction and built-in and registry catalogs; authored projections share AbilityStore's checked ToolRecord projection and exact catalog revision; named schema construction consumes parsed registry rows and selects before encoding |
| `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |
| `ToolPreloadHeuristics.swift` | `ToolPreloadHeuristics`: shared dispatch-time Mac Integration permission table, without lexical turn-intent inference |
| `ToolResultSections.swift` | `ToolResultSections` enum; `pages`; complete line/value records, search records first and then shortest fields first (a result's verdict before its bulk), source-order query selection, raw references for oversized records |
<!-- END GENERATED BLUEPRINT -->

### ChatTurnContracts

Directory: `Modules/NativeAgentCore/Sources/ChatTurnContracts/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ChatTurnContracts/ -->
| File | Owns |
|---|---|
| `ChatApprovalContracts.swift` | `AutonomyDecision` enum |
| `ChatPersistenceContext.swift` | `ChatPersistenceContext` enum |
| `ChatToolBridges.swift` | `PureToolArgumentValidating` protocol; `argumentRefusal`; MacIntegrationToolBridge requires the requesting data root for due-reminders |
| `ChatToolSessionContext.swift` | `ChatToolSessionContext` enum; `rendersInlineCards`, `withReplyRoute`; `TurnEnvelope.workIdentity` carries attribution, `answerExperienceID` carries the owed answer through continuations; neither grants authority |
| `ChatTurnExecution.swift` | `ChatTurnExecution` class; `bindHistoryRunID`, `keepCapabilityNote` |
| `PeerDataTaint.swift` | `PeerDataTaint` class; `withScope`, `mark` (latches any sender the owner does not trust, recognized or not, but their own `self` and bots), `markConsumed` (latches nothing: a read steers nothing), `elevate` (the person answered the run's card); one restore initializer retains provenance and answers without a read-latch marker; ability write refusal reads current origin principal and live/carried peer steering |
| `SwarmChatClientFactory.swift` | `SwarmChatClientFactory` protocol; `makeClient` |
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
| `AgentConversationsExports.swift` | Re-exports `AgentConversations` |
| `AgentWorkspaceExports.swift` | Re-exports `AgentWorkspace` |
| `ApprovalActionText.swift` | `ApprovalActionText`: approval action/reason presentation; original arguments remain execution authority |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`: type/size admission, bounded off-main file reads and voice draft attachments |
| `ChatGeneratedImageArtifacts.swift` | `ChatGeneratedImageArtifacts`: reply attachment projection from actual generation receipts and explicit reply choices |
| `ChatLiveTap.swift` | `ChatLiveTap` enum; `observe` (every turn's deltas and saved answer, for the phone) |
| `ChatOrchestration+AutonomyGate.swift` | `AutonomyGate`: TrustCenter autonomy resolution and approval filing before concrete tool dispatch |
| `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop`; `TurnCheckpointScope`, serialized `TurnCheckpointWriter`; same-turn transcript/receipt recovery and finished-run cleanup |
| `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: `buildTurnContextWithHistory` (history and digest gathered for their turn part), `fireAssemblyStageEvent`, `injectingSessionDigest` |
| `ChatOrchestration+Streaming.swift` | `TurnStreamEvent`: reversible streaming display and transient tool notices; never durable reply or terminal evidence |
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: runs their turn part's effects, hands it each event with each result's declared effect, logs at every host-call boundary; the turn returns at `reply.end` and `after`, and effects after them run privately on the same turn id, never streamed, saved to the conversation or checkpointed), `joinedProse`; retains post-reply flights through settlement, surviving conversational Stop; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed |
| `ChatOrchestration+ToolDispatch.swift` | Shared per-iteration tool dispatch and refusal of unoffered folded calls |
| `ChatOrchestration+ToolLoop.swift` | `TurnContext`: `withToolSchemas`; `finishReplyTurn` settles reply.end, including incomplete work; ContextFlow's `.completed` records this loop exit; tool rounds distinguish Stop, control return and failed observation; failed handback waits end the turn without resuming, and the return nudge requires current driver permission |
| `ChatOrchestration+TurnEngine.swift` | `SwiftNativeTurnEngine`: gathers their turn part's reach (persona, pins, recall, packet, facts, established-person and runtime/view/contact availability facts) and provider execution; expression/setup instructions live in `Resources/abilities/turn.js`; `checkedRouteAdmission` owns unbound route resolution; bound turns reuse admission; retains promotion predecessors through settlement and clears only the current completed handle |
| `ChatOrchestrationClient+Attachments.swift` | image/document admission and voice evidence projection; audio remains an attachment, never a provider content block |
| `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `chat`, `chatExecution`; `StructuredChatExecution` carries the response and typed success/failure; `withCurrentChatModel` admits the current Chat pick at a wake's `model.call`, so a run that never thinks needs no model; `withModelContext` binds the same client/provider/model/effort/tier for turns and wakes |
| `ChatOrchestrationClient+DispatchWrappers.swift` | `FileAccessGatedDispatcher` class; `preApprovalRefusal`, `approvalCardReason`, `sharedFileAccess`; `sharedChatFileAccess`; carries the chain's file access to the organs and refuses only an unrecognized mode and a pathful read under `none` (no tool-name lists; admission is posture × declared class in TrustCenter); declared part app-data reach approves matching read/write paths; peer approval uses the declared class without an external-tool resolver; `AutonomyGatedDispatcher` audit rows that fail are owed repairs |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn`, `runPartToolTurn`; prepared part messages enter the same canonical loop and admitted routing with caller limits, restricted tools and taint, without persona/recall assembly, parent checkpoints or after-turn mind work; explicit part-thought surfaces admit their saved route without the parent's ProviderTurnChoice, omitted surfaces inherit; PartToolThinkingContext marks only that internal thought |
| `ChatOrchestrationClient+Factories.swift` | `complete`, `makeChatOrchestrationClient`, `makeGatedToolDispatchClient`, canonical `makeResidentProviderLLMClient` shared by turns and background body work; stall-only calls share a transport without a resource wall; `SwiftNativeMemoryV2RecallingAdapter`: disclosure-aware recall and served-hit credit |
| `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`: `appendHumanConversationReply` |
| `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`; attachment path/byte writer for transcripts and queues; shared tool/approval/card append, supersession, dedupe and card CAS/receipt schema. Inline continuations retain DataRootLife and read stopped/restored across lives; session index maintenance delegates to ChatSessionIndexFile |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `contextFingerprint`, `iso8601` |
| `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`: `chatStream`, `chatStreamExecution` |
| `ChatOrchestrationClient+StructuredChat.swift` | `SwiftNativeChatOrchestrationClient`: `executeStructuredChatStreaming` owns the accepted turn's effect and one joined `settle` with captured identity: save the complete reply or retained loop prose/artifacts once, settle heard/answer records and the terminal checkpoint, release cancel/steering registrations; thrown work fails or stops, never leaves a vanished waiter; turn-bound carried offers before provider input; `metacognitiveTerminalEvent`, `turnFailedEvent`, `turnCancelledEvent` |
| `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |
| `ChatOrchestrationClient+ToolReceipts.swift` | `SwiftNativeChatOrchestrationClient`: `persistToolReceipt` |
| `ChatOrchestrationClient+Types.swift` | `ChatOrchestrationClient` protocol; `enqueueUserMessage` |
| `ChatSessionWork.swift` | Re-exports `ChatSessionWork` |
| `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |
| `ChatToolRuntime.swift` | Re-exports `ChatToolRuntime`, `ChatTurnContracts` |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`: `chat` supplies explicit provider choice, aggregate token budget and mechanical-row provenance; ordinary turns settle without requiring a token budget |
| `ChatTurnFailure.swift` | `ChatTurnFailure`: failure metadata and retry-confirmation classification from the turn's own dispatch/effect evidence |
| `ChatTurnSteering.swift` | `ChatTurnSteering` actor; open turns and turn-activity clock; atomic resident claim/reservation under the common free-time law; person admission opens immediately |
| `ChatUpdateNote.swift` | Version note selection and launch transaction with supplied bundle resource/version inputs |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ContextStageTrace.swift` | `ContextStageTrace`, stage vocabularies and lifecycle telemetry: bounded context timing, counts and recall/admission trace recording |
| `ConversationPrefixSeeding.swift` | `ConversationPrefixSeeding` enum; `isOpenAIResponsesLane`, `delivery` |
| `DelegatedCampaignGuidance.swift` | `DelegatedCampaignGuidance`: provider-neutral campaign prompt contract; Trust, dispatch and domain verification retain authority |
| `DocumentExcerpt.swift` | `DocumentExcerpt.selected`: query-scored attachment line windows rendered in document order with explicit line ranges |
| `FirstConversationPersonaExemption.swift` | `FirstConversationPersonaExemption`: exact-session one-shot persona write token and pending voice step; atomic consumption prevents reuse |
| `FirstRunWelcomeTransaction.swift` | `FirstRunWelcomeTransaction` class; `hasConversationRows`, `isPersistedFailureRow` |
| `GlobalHotkeyVoiceTurn.swift` | `GlobalHotkeyVoiceTurn`: push-to-talk authorization, capture and final speech result through the shared Mac send boundary |
| `HerScreenPreview.swift` | shared screen/room text projection |
| `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |
| `InlineInteractionSignatureWitness.swift` | `InlineInteractionSignatureWitness`: cryptographic witness for signed card continuation; persisted transcript claims confer no signing authority |
| `IntraTurnContextCompaction.swift` | `IntraTurnContextCompaction`: context-window measurement, in-flight compaction and pressure receipts within turn deadlines |
| `MacChatRetrySnapshot.swift` | `MacChatRetrySnapshot` struct; `capture`, `stillMatchesLocal` |
| `MacChatSessionTransactions.swift` | selection intent/transactions, load-completion waiter and running-session navigation; `LatestRead` owns session-index publication, and committed create/rename changes use `write`; selection and durable rename intents retain their independent action identities |
| `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator` actor; `consume`; deltas arm one publication deadline, rearmed only for owed text; settlement/termination cancel and join publication |
| `MacChatStreamAdapter.swift` | `MacChatStreamAdapter` enum; `stream`, `bridgeChatStreamEvents` |
| `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |
| `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |
| `MacChatTurnCommands.swift` | `NativeChatTurnOptions` and `MacChatTurnRuntime`: shared Mac turn options, transcript commands and admission/Stop coordination |
| `MacChatTurnLifecycle.swift` | `MacChatTurnTerminalEvidence`; queue persistence stamps new requests and projects work from another life (no stamp is the first life) stopped through DataRootLife; restoreCarry/installRestoreCarry and their current-work overlay are deleted |
| `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`: `beginChatTurnLifecycle`, `applyChatTurnLifecycleInput`, `receiveChatTurnActivity`; `OtherDoorTurns` retains its trace subscription consumer, counts reply progress only from surface output evidence, stops at engine termination and unsubscribes on exit |
| `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |
| `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry`, `settleMacChatRetry` |
| `MacChatTurnRuntime.swift` | Canonical Mac admission/lifecycle and Send-next projection; queue writes use MacChatTurnLifecycleStore; cross-life requests stay stopped until the person's Resume or Send now creates fresh requests without old steering or continuations |
| `MacChatTurnStreamConsumer.swift` | `MacChatTurnPresentationPort`: `consumeMacChatStream` |
| `MacChatTurnStreamSettlement.swift` | Mac stream completion, joined persistence and lifecycle settlement; helper conversations enter their own runner with the existing Mac admission |
| `MindMemoryManager.swift` | `MindMemoryManager` struct; `interpret` (with the cares section when cares are shown), `appraiseCares`, `relevantRecallIDs`; incremental ranked evidence and catalog-budgeted relevance batches; `AfterTurnMemoryFailure` preserves output limits, request rejections and refusals with distinct recovery |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChatTurnRuntime diagnostics |
| `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`: native requested-result settlement classification of the user-authored message head |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` reads the declared class and the catalog bucket (reads of their own data and files run side by side; their devices, the app door and the unplaced run one at a time); keyword scheduling inference removed |
| `PersistedToolReceipt.swift` | `PersistedToolReceipt.project`: bounded, redacted historical tool facts and exact continuations; oversized locators are omitted rather than clipped |
| `ProactiveAssistantSpeech.swift` | `speakProactively` owns proactive transcript writes, claims, quota and destination reconciliation; Reach and chat.post share reachOut, inbox Act uses morningBrief |
| `ProviderRecoveryPolicy.swift` | `TurnEngineError` provider failure wrapping: preserves interrupted-stream causes and classifies nonempty partial output as work that ran partly |
| `ProviderToolNameMap.swift` | `ProviderToolNameMap`: stable provider-safe tool aliases with reverse mapping to canonical dispatch names |
| `StandingBotContinuity.swift` | Helper ingress routes to StandingBots' own turn runner; checked session creation and legacy shelf import retain the existing transcript format |
| `StandingBotModel.swift` | Helper adapter supplies the existing provider codec, checked tool chain and transcript writer to StandingBots' own model loop, without resident context or after-turn work; its own session compacts through the shared compactor at the shared threshold, and its thread with their is its memory of it |
| `SwarmChatClientFactory.swift` | `NativeSwarmChatClientFactory` struct; `makeClient` |
| `SwiftToolDispatcherConstruction.swift` | `SwiftToolDispatcher`: extension |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolCallCodec.swift` | `ToolCallCodec`: provider tool offerings, streamed prose release and native/text-marker call decoding; the turn loop owns dispatch and budgets |
| `ToolLoopSupport.swift` | `ToolLoopTraceObservation` retains prose and dispatch evidence across every loop throw and owns failed-attempt classification; legacy failed-slot counting stays separate; `ToolDispatchDeadline` |
| `TurnClockQuietHours.swift` | `TurnQuietHoursWindow`: local wall-clock quiet-hours membership, wraparound and exact end deadline shared by native reply admission |
| `TurnContextSnapshotTrace.swift` | `SwiftNativeTurnEngine.fireContextSnapshotEvent`: local bounded, redacted context snapshots and prompt/schema fingerprints tied to the current turn trace |
| `TurnEngineContracts.swift` | `TurnContext` value projections with module-scoped setters and immutable admitted routing; `TurnEngineResult` aliases TurnTraceEvent's terminal status vocabulary; `SharedAdaptiveMemoryPromoter`: full turn evidence and telemetry |
| `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |
| `TurnPart+ShippedBodies.swift` | `TurnPart.shipped`: generated prior shipped turn-body versions and digests from git history; the currently bundled body is not an upgrade candidate |
| `TurnPart.swift` | `TurnPart`: their turn as a part (`abilities/turn.js` `step(state, event)`) in one held helper per turn (a helper short of resources is an observation retried on the helper backoff until Stop; any other start failure ends the turn with its fix), version choice (prior shipped bodies come from generated `shipped`) and seed install (write failures name the person and storage repair), the effect queue, the turn's event log and reconstruction for resume and heal; `provider_failure` carries the repair's callable input, permits explicit `app` repair calls through the ordinary dispatcher or a re-issued `model.call`, and can end incomplete without healing an authored part; compare-and-swap heal in one store transaction |
| `TurnPlanning.swift` | `TurnPlanner`, `TurnPlan` and `TurnPlanTraceRecorder`: capability selection and turn-plan trace projection |
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
| `ChromeControlRuntime.swift` | `ChromeControlRuntime` actor; authenticated relay and extension attach readiness, manifest-backed extension versions and reconnect-confirmed self-reload; transport stop retires passive file/launch observations, reconciliation can rearm them, and terminal runtime stop closes admission and connection streams; post-arm file wakes and observation identities fence registration races; Chrome NativeAgent group membership is tab authority, user-touch ungroups a tab, each conversation remembers its last tab and rebuilds from the group; numeric tab addresses, per-tab reading views, snapshot/element/user-sequence safety and bounded mutation-backed page change streams; only explicit tab.close removes a tab; shutdown and reload leave all tabs open; connection transitions, relay diagnostics, extension errors and browser signature preflight remain |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` enum; `isComplete`; extension completeness, staged replacement and registered-host refresh; incomplete bundles and copy failures name the defect and person recovery step, never a coding request |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ChromeControl diagnostics |
<!-- END GENERATED BLUEPRINT -->

### Cognition

Directory: `Modules/NativeAgentCore/Sources/Cognition/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Cognition/ -->
| File | Owns |
|---|---|
| `AutonomousPursuitProposer.swift` | `AutonomousPursuitProposer`: at most one reflection pursuit from a live non-seed life-depth care with a stance; life approval, Desk cap and citation dedup guard admission |
| `CognitionHost.swift` | Native cognition reach, including the sender-owned phone notification target count and root-bound pure readout-face invocation; domain facts and canonical commits remain outside editable code |
| `CognitiveAttentionResidentProjection.swift` | `CognitiveAttentionResidentProjection`: lock-backed immutable cognition/organism handoff for turn reads without actor, disk or provider work |
| `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |
| `EventDeadlinePhysiology.swift` | `EventDeadlinePhysiology`: store/file invalidations and cancellable refresh adapters; canonical runners reread state and suppress only known self-write generations |
| `MindCaringAppraiser.swift` | `MindCaringAppraiser` and `CaringReceiptLog`: semantic caring appraisal receipts, amendments and dosing evidence |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Cognition diagnostics |
| `NativeCognitionRuntime+Continuity.swift` | `NativeCognitionRuntime` continuity reads: dream residue, local gap cues and builder activity; absent and unreadable sources remain distinct |
| `NativeCognitionRuntime+Deadlines.swift` | `CoalescingDeadline` and cognition deadline scheduling: one cancellable wake per owner, residual repair and maintenance outcome reporting |
| `NativeCognitionRuntime+Events.swift` | `NativeCognitiveEventFactory` and runtime event ingestion: payload-free motor/provider observations; domain owners retain outcome authority |
| `NativeCognitionRuntime+Expectations.swift` | `NativeCognitionRuntime` horizon expectations: composed dated evidence, refresh deadlines and toward/resolution readings |
| `NativeCognitionRuntime+MindLedger.swift` | `NativeCognitionRuntime` mind ledger: trace-backed why, association rejection and undertone undo through substrate owners |
| `NativeCognitionRuntime+Notify.swift` | `NativeCognitionRuntime.innerStateReading`: one reading across mind/body owners and pending stake-bearing expectations |
| `NativeCognitionRuntime+Organism.swift` | `NativeCognitionRuntime` organism integration: approval lifecycle expectations, somatic ingestion, felt resolutions and live body projections |
| `NativeCognitionRuntime+ProviderEvidence.swift` | `NativeCognitionRuntime` provider evidence: bounded lifecycle history restored from canonical traces and durable capability projection |
| `NativeCognitionRuntime+ProviderVitals.swift` | `NativeCognitionRuntime` provider interoception: passive vitals persistence, health-band transitions and graded somatic ingestion |
| `NativeCognitionRuntime+Pursuit.swift` | `NativeCognitionRuntime` pursuit projection: canonical Desk invalidations and bounded resident intent, without turn-time Desk I/O |
| `NativeCognitionRuntime+Reach.swift` | `ReachLedger` and runtime reach: one considerate initiative path, durable offer/answer accounting and exact delivery deadlines |
| `NativeCognitionRuntime+Reflection.swift` | `NativeCognitionRuntime` reflection: dream/REM-triggered single-flight reflection, budget admission, result settlement and pursuit proposals |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`: `makeReplayIntegrationInput` |
| `NativeCognitionRuntime+SourceWakes.swift` | Runtime-owned source observations for canon, horizon, Reach, cares and quiet-hour preferences; registration precedes reads, renewed directory children remain watched, canon arms journal membership before enumerating input children and compares input stamps to ignore audit output and unchanged directory events, stop cancels observations, and the existing residual deadline owns source cooldown/eligibility/expiry boundaries |
| `NativeCognitionRuntime+StudioCanon.swift` | Native source invalidations, background admission, throttle, audit receipts and exact deadline ownership; proposal and next-deadline choices come from read-constrained studio-canon calls; no new timer or schedule activation |
| `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`: `considerStudioWander`, `studioWanderIsInstalled`, `studioWanderInstallationNow`; unanswered consult ordering and all encounter invitation wording call editable studio-intake through the originating door, with native source-failure reporting and encounter validation |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime` actor; `rememberNonLiveTurnKind`; Desk candidates/approval context publish together with the read's Desk revision, checked at turn and wake admission; generation orders refreshes; observes Experiences for carried wait settlement, caching only its last read to ignore unchanged replay events; settled live turns trigger one held-memory drain at idle; `GrowthWeekProjection` binds frozen growth facts to L0's version/source cache through the native host |
| `NativeCognitionRuntimeModels.swift` | `CognitiveObservatoryDetail` and runtime read models; shared affect validity and organism sample freshness/validity |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |
| `StudioWanderLane.swift` | `StudioWanderLane` enum; installation, eligibility, carried-hour state and prompt for studio wandering |
<!-- END GENERATED BLUEPRINT -->

### CognitiveSubstrate

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/CognitiveSubstrate/ -->
| File | Owns |
|---|---|
| `CognitiveConfiguration.swift` | `CognitiveConfiguration`: cleaned cognition settings, reflection spend ceilings and personality experiment gates |
| `CognitiveEvent.swift` | `CognitiveEvent` and event/turn-kind vocabularies: typed cognition observations, mechanical-row classification and metadata signals |
| `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |
| `CognitiveModels.swift` | `CognitiveNode`, snapshots and `CognitiveFrozenRead`: source/subject identity, bounded emotional tags, association edges and persistence health values |
| `CognitivePhaseModels.swift` | Cognition phase contracts: prepared turn projections, presentation commits, attention, workspace, capsule and care values |
| `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadRestoreBundle`, `loadReceiptRecords` |
| `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore` actor; `backupForDoctor`, `saveNodes` |
| `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |
| `CognitiveSubstrate+AttentionSignals.swift` | `CognitiveSubstrate.attentionSignals`: pure bounded workspace/question/subject projection and resident handoff publication |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: `compileFrozenCapsulePresentation` owns chat and inspect-only reflection assembly |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: fingerprint cadence and the Since gap cue |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `capsuleCadenceShouldSpeak` |
| `CognitiveSubstrate+Cares.swift` | `CognitiveSubstrate` cares: four life seeds, embedder-chosen care lines for the after-turn call, its parsed judgment and provenance-gated apply; retains the completed migration marker without loading retired artifacts |
| `CognitiveSubstrate+CaresMind.swift` | `CognitiveSubstrate` cares on their mind: one pressure, the capsule's care cue and when it becomes their intention to bring a care up, and what Reach and their hour read from the same pressure |
| `CognitiveSubstrate+CaresNight.swift` | `CognitiveSubstrate` cares at night: the dream's material (moved today, still open), its settle and let-go lines, fade past the depth's horizon, deepen by distinct days moved, the cares ready for the life card and its approval, their story lines |
| `CognitiveSubstrate+CaringAppraisal.swift` | `CaringAppraisalRequest`, verdict and lane contracts: semantic caring judgments, distinctness and admission/refusal interfaces |
| `CognitiveSubstrate+CaringEvent.swift` | `CognitiveSubstrate` caring event admission: turn context, semantic verdict delivery and distinct encounter/refusal accounting |
| `CognitiveSubstrate+Continuity.swift` | `CognitiveSubstrate` continuity cues: dream-theme association and since-gap candidates compete for the existing felt slot |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: conversational appraisal and warmth, relational provenance, open completion and association signatures |
| `CognitiveSubstrate+FeltFingerprint.swift` | `CognitiveSubstrate` felt fingerprint: graded live feeling words, safe subject labels and capsule line composition |
| `CognitiveSubstrate+FeltOrigins.swift` | `CognitiveSubstrate.feltDayOrigins`: last-day felt-node provenance for dreams, using the same population as the felt-day summary |
| `CognitiveSubstrate+GrowthWeek.swift` | Frozen REM timeline and decoded disposition transitions; `growthWeek`/`growthWeekLines` share the owned `growth-week.js` face. Readout grouping, titles, reasons, alternatives, ordering, cap and undertone prose are removed from Swift; canonical timeline source titles stay in Replay for its other consumers. |
| `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidatePendingCompletion` |
| `CognitiveSubstrate+InnerState.swift` | `CognitiveSubstrate.innerStateReading`: record-backed mind/body introspection, selection reasons and felt/care/toward projections |
| `CognitiveSubstrate+MindLedger.swift` | `CognitiveSubstrate` mind ledger: bounded association suppressions and undo entries, persistence and restoration |
| `CognitiveSubstrate+Mood.swift` | `CognitiveSubstrate` mood: read-time emotional-tag integration, disposition, congruence, felt-day summaries and dream-residue claims |
| `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistSnapshot`, `recordReceipt` |
| `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: causal `planReflectionChecked`, frozen per-cause peer/node provenance, judged reflection integration and receipts |
| `CognitiveSubstrate+RemindedOf.swift` | `CognitiveSubstrate` unbidden moment association: cadence, selection revalidation and bounded served-moment affect accounting |
| `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplayChecked`; schema status and dated REM resolutions share the inbox's decision snapshot by proposal identity; adoption requires its application claim; unmatched retained history stays explicitly unavailable; retired view/opinion/interest events never enter timeline or growth-week readouts |
| `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: `setAblation`, `facultyMeasurementSnapshot`, `runResearchExperiment` |
| `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState`, `stringArrayValue` |
| `CognitiveSubstrate+SemanticAppraisal.swift` | `SemanticAppraisal`: meaning-weighted event appraisal against outcomes and embedding-touched cares |
| `CognitiveSubstrate+Serialization.swift` | `CognitiveSubstrate`: `cleanedSessionId` |
| `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |
| `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate`: `metadataString`, `isConversationalPresenceStatement`, `isOperationalSubconsciousNoise` |
| `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead` |
| `CognitiveSubstrate.swift` | `CognitiveSubstrate` actor; `waitForMaintenanceTransition`, `beginMaintenanceTransition` |
| `CognitiveSubstrateContracts.swift` | `CognitiveSubstrateDependencies` struct; injected frozen growth projection, explicit unavailable when unbound |
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
| `CognitiveSomaticSignalAdapter.swift` | `CognitiveSomaticSignalAdapter` enum; `signal`, `safeSourceComponent` |
| `OrganismBehaviorPosture.swift` | `OrganismBehaviorPosture`: evidence-backed operational directives and review signals; default posture renders nothing |
| `OrganismBodySchema.swift` | `ProviderPathEvidenceOutcome` enum |
| `OrganismCapabilitySelfModel.swift` | `OrganismCapabilitySelfModel` enum; `beliefs` |
| `OrganismCaringEvent.swift` | `OrganismCaringEvent`: encounter identity, dose eligibility and rolling encounter extension; one encounter receives one dose |
| `OrganismChemistry.swift` | `OrganismChemistry` enum; `applying`, `dosedByCaringEvent` |
| `OrganismDreamRepair.swift` | `OrganismDreamRepair` enum; `applying`, `applyingResidualPressure` |
| `OrganismField.swift` | `OrganismField` struct; `summary`, `edge` |
| `OrganismKernel.swift` | `OrganismKernel` actor; `configure`, `admitAfterTurnReaction` |
| `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value` |
| `OrganismModels.swift` | `SomaticSignalKind` enum |
| `OrganismPersistence.swift` | `OrganismPersistentState`: persisted body field, chemistry, predictions and caring encounter; restore decay and identity validation |
| `OrganismPrediction+Horizon.swift` | `OrganismPredictiveBody`: `applyingHorizonRefresh` |
| `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |
| `OrganismPredictionModels.swift` | `OrganismPredictionKind` enum |
| `OrganismProspectiveAffect.swift` | `OrganismProspectiveAffect`: pure prediction/horizon modulation of projected chemistry, without changing stored chemical state |
| `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |
| `OrganismResolutionFelt.swift` | `OrganismResolutionFelt`: pure notable resolution events with aboutness and per-path rate bounds; kernel retains state ownership |
| `OrganismSignalBus.swift` | `SomaticSignalBus` actor; `observe`, `configure` |
| `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |
| `OrganismTypedBodyBeliefs.swift` | Typed body belief projections: secret-free evidence references, locally received freshness and bounded capability/integrity/presence metrics |
| `SomaticSignalValence.swift` | `SomaticSignalKind` intrinsic valence: one per-kind table shared by signal adaptation and organism field defaults |
<!-- END GENERATED BLUEPRINT -->

### Connectors

Directory: `Modules/NativeAgentCore/Sources/Connectors/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Connectors/ -->
| File | Owns |
|---|---|
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |
| `ConnectorActions.swift` | `ConnectorActions` struct; `runConnectorAction`, `fullMacYoloAdmitted`; native work journal/handoff reads, redaction before display bounds and original Git reads; work snapshots return directly without unused latest.json/codex_daily.jsonl copies; credential-bearing text never enters a part |
| `ConnectorHealthDecay.swift` | `ConnectorHealthDecay` and `ConnectorProofLedger`: credential-backed health from latest actual receipts, decayed by age without polling |
| `ConnectorOAuthRegistry.swift` | Canonical connector row edits, including revocation; extends PersistenceCore's checked registry owner with `mutateConnectorRegistryEntry`, `removeConnectorRegistryEntries` |
| `ConnectorRegistryActions.swift` | connector/workspace registry operations and ordered workspace readback verification; Slack socket-mode metadata writes delegate to SlackCredentials |
| `ConnectorWizardActions.swift` | `ConnectorWizardSetupRoute`: the wizard's token route, read from the inline card registry; registry row read |
| `Connectors+Auth.swift` | `revokeConnector` records the person's disconnected decision in the canonical registry and delegates credential disable/removal to SlackCredentials |
| `Connectors.swift` | Canonical workspace-array read and tilde-expanded string paths for search and journal roots; empty search queries return nil for the action's empty envelope |
| `LocalPIMConnectorActions+Authorization.swift` | calendar read/write authorization interpretation and EventKit permission prompts; wizard status |
| `LocalPIMConnectorActions.swift` | `LocalPIMConnectorActions` enum; `calendarListUpcoming`, `calendarCalendars`, `remindersListWrite`; calendar reads retain physical enumeration through settlement and return the rows already produced; due-today/overdue composition requires its caller's data root, calls that root's editable `due-reminders` part through L0 and requests up to 200 rows from one native snapshot; general reminder query keeps permissions, queue-confined EventKit filtering/serialization and native access/time-zone facts |
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
| `ContextCorrectionScope.swift` | `ContextCorrectionScope`: applicability gates for canonical corrections and endpoint-scoped graph relations; selection utility grants no authority |
| `ContextExpansion.swift` | `ContextExpander.expand`: expands selector-offered pointers without mutating context or deriving authority from their contents |
| `ContextFeedback.swift` | `ContextFeedbackReducer`: deterministic rebuildable utility projection from explicit-bucket feedback and canonical seeds |
| `ContextFlowCoordinator.swift` | Immutable arena publication and trim rehydration; verification filters delivered items/pointers but retains selection-time receipt/budget and feedback IDs; compile/publication admission waits leave on cancellation or stop; stop invalidates candidates and separately drains entered publication before returning; feedback replay reused only for matching generation, events and decay bucket; SQLite retains derived generations and ranking events, while turn traces own displayed receipts |
| `ContextFlowModels.swift` | ContextFlow value vocabulary: source/atom/relationship identity, authority, privacy, injection policy and immutable generation records |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`: bounded Markdown atom compilation and exact unchanged-source reuse; `triggerTokens` owns ordered trigger extraction with source-specific tokenization/filter/bound parameters; persona GROWTH uses the PersonaEngine episodic-log filter before hashing and parsing |
| `ContextMemoryLead.swift` | `ContextMemoryLead`: memory age, provenance and stored untrusted-source extraction |
| `ContextProjectionSources.swift` | `ContextCompiledProjectionProvider`: incremental rebuildable source projections, generation-bound exclusions and delivery/publication hooks |
| `ContextSQLiteStore.swift` | `ContextSQLiteStore`: derived immutable Context generations, feedback, health and pruning; canonical sources remain authoritative |
| `ContextSelection.swift` | `ContextSelector` struct; `select`, `commonEligibilityFailure` shared with expansion; correction scope/conflict resolution remain selection policy |
| `ContextSelectionContracts.swift` | `ContextOriginClass` enum; `ContextPacketItem` owns expandable representation and safe leads, and retains memory untrusted sources through body/summary selection |
| `ContextSourceMonitoring.swift` | `ContextSourceRegistry`, monitor and coalescer: explicit source allowlists, owner inventories and bounded directory invalidations |
| `ContextTurnRuntime.swift` | `ContextPreparedTurn`, request and embedding ticket: generation lease, bounded query-vector handoff and turn feedback/delivery accounting |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Context diagnostics |
| `RequiredDocumentMirror.swift` | `RequiredDocumentMirror` and `StablePromptKernel`: persona-slot/source naming, required document reads and deterministic logical byte accounting |
<!-- END GENERATED BLUEPRINT -->

### ContextFlow

Directory: `Modules/NativeAgentCore/Sources/ContextFlow/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ContextFlow/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ContextFlow diagnostics |
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime` actor; joined, ordered start/stop/reload transitions reserve ownership before suspension; stop retains and drains picker/observation work, whose follow-ups check their lifecycle; retired embedding tickets fail immediately, and predictions retain their bounded slots until actual exit; persona registrations and mirrors share a compiler batch |
| `NativeContextMemoryPressureObserver.swift` | `DispatchContextMemoryPressureObserver`: cancellable OS pressure event bridge; runtime and coordinator retain trim policy |
| `NativeContextMemoryProvenance.swift` | `NativeContextMemoryProvenance.attach`: advisory reverse lookup on the exact prepared-turn lease; misses never invent record identity |
| `NativeContextProjectionText.swift` | `NativeContextProjectionText` enum; `clean`, `bounded`; projection triggers delegate to ContextMarkdownCompiler |
| `NativeKnowledgeGraphContextProjection.swift` | `NativeKnowledgeGraphContextProjection`: rebuildable graph atoms, support and triggers with canonical-source verification |
| `NativeMemoryContextProjection.swift` | `NativeMemoryContextProjection`: canonical memory projection, including immutable untrusted-source entities and source hashes |
| `NativeResidentWorkContextProjection.swift` | `NativeResidentWorkContextProjection` and `ResidentWorkDecisionNeed`: provenance-bearing Desk/Workshop context, without scheduling or transition authority |
| `NativeStudioContextProjection.swift` | `NativeStudioContextProjection`: rebuildable journal/canon pointer atoms and invalidation; judgments remain behind on-demand pointers |
| `SensesContextProjection.swift` | `SensesContextProjection`: four bounded unread `news` atoms from `SenseNewsBoard`, selected from the published generation, verified for expiry/seen state before delivery, separately rendered and acknowledged only on provider output; expiry/seen exclusion also protects retained generations |
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
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation`; life-stamped resumable work, stopped/restored projection; receiptIsUnresolved and toJSON |
| `DeskModels.swift` | `DeskStatus`: `DeskKind`, `CadenceMode`, `NotifyLevel` |
| `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |
| `DeskNotify.swift` | `DeskNotificationRead`, `DeskNotificationProposal`: frozen native policy inputs and typed proposals; native consent/ceilings and defer truth; Desk/config revision checks and baseline/ledger/window commit under native locks, with no part execution under a lock. Notification, nag, drift wording and deadline policy live in Resources/abilities/desk-notify.js; the person's unmute and scheduled loop share it |
| `DeskObservation.swift` | `DeskObservationEvaluator`: pure externally observed drift, auto-resolution and verdict fingerprints for tracked references |
| `DeskObservationApplier.swift` | `DeskObservationApplier`: applies observation verdicts to Desk; evidence receipts land before closing work |
| `DeskOperations.swift` | `DeskOpBody` enum; `updateTitle` optionally replaces refs with the same replayable summary update |
| `DeskParking.swift` | `DeskDeferPreset`; deferred-work interpretation |
| `DeskProjection.swift` | `DeskBoardLayout`, `DeskPaletteRow`, `DeskPaletteQuery`, `DeskFuzzy`, `DeskPaletteCommandApplication`, `DeskQuickAction`, `DeskRefAction`, `DeskRefAffordance`; attention, freshness and date interpretation |
| `DeskSequencing.swift` | `DeskSequencing.compute`: derived blockedness, cycles and subtree plans from stored edges; unblocking never writes a separate operation |
| `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |
| `DeskStore.swift` | `SwiftNativeDeskStore` struct; process-wide `currentRevision` advances before and after each awaited canonical append under the ops lock; `continuation`, `setContinuation`, `heldBy` (nonacquiring hold read); keyed system findings persist findingKey through create, compaction and archive, preserve closure and person ownership under their filing lock; explicit reopening refreshes evidence in that transaction or files anew after archive, with opt-in ref replacement on the same `updateTitle` op; terminalParentsWithNonTerminalDescendants is the pure Doctor/repair selection, with mutation-time revalidation under the ops lock; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `MyQueue.swift` | `MyQueue` enum; `entries`, `add`, `isReady`; `Entry.owedToPerson` derives reply obligation from recorded origin, independent of readiness and taint |
| `PartRunStore.swift` | HMAC-sealed checkpoints under skills/runs; stamps new saves with DataRootLife, reads cross-life journals stopped/restored; explicit Resume runs fresh without the old journal. Desk expiry/MyQueue closure, retention/discard and SwiftNativeManifestSigner signing remain here |
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
reads. Heavy snapshot reads start together; publication retains its ordering.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DeviceSync/ -->
| File | Owns |
|---|---|
| `AdaptiveDrainPolicy.swift` | `AdaptiveDrainPolicy`: receive deadlines from outstanding work, peer activity and proven push; sender retains lost-push recovery |
| `BridgeEvalSeams.swift` | Bridge value policies: durable seen-ID bounds, incoming disposition, KVS keyspace/nudge admission and snapshot/inbox sweep plans |
| `CKLandmine.swift` | CloudKit entitlement probes, guarded account-status projection and `withCKTimeout` |
| `DeviceSync.swift` | `DeviceSync` and shared aliases: resident phone bridge, snapshot/inbox assembly and overview-driven needs-person notification binding |
| `DeviceSyncHost.swift` | Engine snapshot/action seam; transcript timestamps bound read-only other-room exchanges to shown history; message owners omit previews for transport budgets |
| `ICloudDeliveryNudgeQueue.swift` | `ICloudDeliveryNudgeQueue`: one bounded single-flight KVS wake worker; a nudge never proves transport delivery |
| `ICloudIncomingTurnForwarder.swift` | Signed incoming phone turns route helpers to their own runner and resident conversations to chat; iCloudChatFileAccess; checked session commits and Privacy-redacted error publication |
| `ICloudIncomingTurnPort.swift` | Incoming phone turn port: resident chat, helper-owned reply and existing reply/progress publication |
| `ICloudTextDeltaCoalescer.swift` | `ICloudTextDeltaCoalescer` struct; `push`, `flush` |
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
| `MacSyncActionRouter.swift` | `MacSyncActionRouter` struct; `surfaceSelection`; approval, memory and inbox mutations return affected canonical records/removals for the shared phone projection; no complete inbox or memory lists in action replies; readback revisions are captured on the Mac before the canonical read |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | MacSyncEngine: shared inner-action ledger decisions, freshness, response recovery, reservation and settlement; the ledger response wins, and strictly bound executed rows without one recover HMAC-verified matching response files through the same owner for both transports and stale pending files; transport acquisition, delivery and archival remain separate |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`: `startCloudKitSnapshotProjection`, `start`, `stop`; saved connector setup changes and receipt-ledger health edges rebuild the heavy snapshots, so the phone follows health changes without rebuilding for repeated healthy receipts |
| `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |
| `MacSyncEngine+NeedsUserNotify.swift` | `NeedsUserEdgeNotifier` actor; `evaluate`, `stableDigest` |
| `MacSyncEngine+Notifications.swift` | `MacSyncEngine`: `sendNotificationToPairedDevices` |
| `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |
| `MacSyncEngine+Security.swift` | MacSyncEngine pairing rotation and signed responses; complete signed CloudKit action-record budgeting before terminal ledger settlement; oversized readbacks return an explicit processed-action error; BridgeMessage owns HMAC, constant-time comparison and inner-action verification; outer signatures remain case-sensitive |
| `MacSyncEngine+Snapshots.swift` | Revisioned snapshots retain exact payload/wire digests; phone Inspector reads its host; chat snapshots carry HerScreen's read-only other-room exchanges as an additive field |
| `MacSyncEngine+Storage.swift` | `MacSyncEngine`: `recordProcessed`, `restoreState`, `cappedPreservingMarkers`; consolidated replay/digest restoration and device bookkeeping await the shared `DeviceSyncStorage` actor in `DeviceSync.swift` before admission/acknowledgement |
| `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |
| `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`: `startWorkActivityObservation`, `projectWorkshopWorkActivities`, `requestWorkActivityPublication` |
| `MacSyncEngine.swift` | Mac snapshot/inbox state, active chat tasks and stop bookkeeping; chat snapshots add read-only other-room exchanges beside canonical messages |
| `MacSyncInboxAction.swift` | `InboxAction` struct |
| `MacSyncMobileNotificationRelay.swift` | Sole notifications/push_tokens.json mutation owner: alert registration/pruning, work-activity registration and locked delivery reservations/outcomes; APNs supplies only the send effect; no duplicate mobile_push/tokens.json writes |
| `MacSyncRemoteMacControl.swift` | `MacSyncRemoteMacControl` struct; `dispatch` |
| `MacSyncRemoteMacControlPort.swift` | `MacSyncRemoteMacControlPort` protocol; `loadTrustPolicy`, `run` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DeviceSync diagnostics |
| `NativeAgentNotificationDefaults.swift` | `NativeAgentNotificationDefaults`: shared agent display name and explicit/default notification title resolution |
| `PairedPhoneStore.swift` | Paired-phone array mutations using PairedPhoneAuthority's one Phone schema; local backup/export/phone exclusions and Paired Phones privacy scope are declared here |
| `PairingSecretManager.swift` | `PairingSecretManager`: checked device-only HMAC secret ownership, explicit rotation and pairing material publication |
| `PhoneConnectionReader.swift` | `PhoneConnectionReader`: weak on-demand reader of the running bridge's one phone-connection assessment |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `open` |
| `SwiftNativeAPNS.swift` | APNs delivery, readiness and body configuration use the sender's deliverable target count from notifications/push_tokens.json; work-activity mutations delegate to MacSyncMobileNotificationRelay; an empty canonical set stays empty; mobile_push/tokens.json is neither read, imported nor removed |
| `iCloudBridge+DeliveryReceipts.swift` | `iCloudBridge`: `appendChatDeliveryReceipt`, `appendActionResponseDeliveryReceipt`, `appendInboundSuccessReceipt` |
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
| `Dispatcher.swift` | `DispatchResult`, read-only `SwiftNativeDispatcher` with a fail-closed writable-handler boundary, `makeDispatcher`; `dispatchSlashCommand`; dispatch status and read verification derive from `ChatToolOutcome` exact/display classes; partial reads retain visible output without a fabricated error or verification claim |
| `LocalToolImage.swift` | `LocalToolImage`: turn-local admitted image continuation and bounded thumbnails; pixels never enter durable JSON/transcript receipts |
| `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `dispatchNativeAction` uses `LocalConnectorActions.nativeReadOnly` |
<!-- END GENERATED BLUEPRINT -->

### Dispatcher/Actions

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/Actions/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Dispatcher/Actions/ -->
| File | Owns |
|---|---|
| `FileSystemActions.swift` | `FileSystemActions` enum; `resolvePath` for reads/repository paths, mutations use NativeAgentWorkspaceRoot's shared execution/containment resolver; `allowedRoots`, part app-data reach and retained private/authority-store exclusions, `SwiftNativeSecurityCenter.fencedAttachment` (an attached file meets the same sensitive-store fence and refusal as files.read in every posture, then the workspace fence below Full Mac), shared mutation fences and reversible `trashFile`; version-checked line scanning owns file/log query selection, positions, full-source coverage and source continuation; `fileInfo` reads descriptor-bound metadata without following the final link; `listDir` owns budgeted allocated disk usage with named partial results; `gitLog`/`gitDiff` own dated repository reads; shared Git status parsing and process capture/settlement for Foundation and descriptor-pinned launches; `FileReadSourceMaterial` descriptor-only source port |
| `FileSystemVerifiedPath.swift` | `VerifiedImageRead`: image delivery from already verified descriptor bytes; source dimensions and bounded-thumbnail receipts remain intact |
| `LocalConnectorActions.swift` | Canonical file/system handlers and verification flags; `nativeReadOnly` selects the exact seven native/slash tools |
| `PersonaSystemActions.swift` | Protected persona tool reads through PersonaEngine's document selection and the filesystem owner's sensitive-path/regular-descriptor checks; skill/workspace read adapters; `ClockReply` owns timezone selection and date projection with local/chat field adapters |
<!-- END GENERATED BLUEPRINT -->

### DoctorChecks

Directory: `Modules/NativeAgentCore/Sources/DoctorChecks/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/DoctorChecks/ -->
| File | Owns |
|---|---|
| `DoctorActionRuntime.swift` | `DoctorActionRuntime` struct; `safeDetail`, `mergeReport` |
| `DoctorChecks.swift` | `SwiftNativeDoctorChecks` actor; `makeDoctorChecks`, `runAll`; runtime JSON and transcript inspection is read-only; persona health never seeds identity; canonical owners alone create or mutate these stores; StorageCheck does not create research/downloads, rich_ui, personal_os, llm, context/evals, context/hints, production/migrations, self_worktrees, native_power/browser/profile or native_power/notifications, and leaves existing contents untouched; onboarded persona health requires the saved profile and validates it through `PersonaCompiler.compileProfile`, reporting its failure; StorageCheck does not create capabilities, graphs, routing, connectors/workspaces, research/downloads, rich_ui, personal_os, llm, context/evals, context/hints, production/migrations, self_worktrees or native_power/browser/profile, and leaves existing contents untouched; CheckResult carries the owner, registered native repair or person recovery step and its experience projection; app defects never create coding requests |
| `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |
| `DoctorRunsInspectorChecks.swift` | Inspector health verdict from the engine's persisted-trace observation state |
| `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |
| `DoctorStatusProjection+Config.swift` | `AutoDoctorConfig`; `DoctorStatusProjection`: `readAutoDoctorConfig`, `boolValue`, `intValue` |
| `DoctorStatusProjection+Hardening.swift` | `DoctorStatusProjection`: `getProductionHardening` |
| `DoctorStatusProjection.swift` | `DoctorStatusProjection` enum; `makeHealthCard`, `persistDoctorSnapshot`, `recordReadings`, `repairProjection`; Experiences owns repair obligations and settlement, while Doctor owns the measured postcondition and executable repair call; historical calls are never reanimated; DoctorPlainCopy owns severity classification for Doctor/Support aggregation and adverse admission |
| `ModelCompensationsCheck.swift` | Doctor-only, read-only counts of `shim.fired` by census ID since the current build launched; no compensation judgment or repair |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DoctorChecks diagnostics |
| `ProductionHardeningSummary.swift` | `ProductionHardeningSummary` struct |
| `PromptPrefixHealthCheck.swift` | `PromptPrefixHealthCheck`: measured prefix/cache-shape health from real turn observations and provider token receipts |
| `ReleaseChecklist.swift` | `ReleaseChecklist` struct |
| `SessionIdentityCheck.swift` | `SessionIdentityCheck.run`: session mint-site counts and source/row disagreement diagnostics |
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
| `DreamCycleRunner+Messages.swift` | `DreamCycleRunner`: `gatherRecentMessagesAcrossSessions`, `feltRankIndex`, `parseDaemonISO` |
| `DreamCycleRunner.swift` | `DreamCycleRunner` actor; `runNightlyDreamCycle`, `reconcileDreamMark` repairs the mark from saved section cutoffs under the run reservation; `integrateMood`, `retryMoodIntegration`, `affectJudgment(inDiaryMarkdown:)` |
| `DreamNight.swift` | `DreamNight` and `DreamDiaryWeeks`: shared diary section/title parsing and week grouping across all dream readers |
| `DreamPayload.swift` | `DreamPayload` struct |
| `DreamProvenance.swift` | `DreamEntryProvenance` and `DreamSourceRef`: per-claim dream support, source resolution and section-aware peer provenance |
| `DreamREMCycle+Consolidation.swift` | `SwiftNativeREMConsolidator`: consolidation prompts and proposal parsing with verbatim source-bound supporting passages |
| `DreamREMCycle+HeavyLogic.swift` | REM stateless helpers: persona reads, durable denial tombstones and old-diary archival; caller retains proposal persistence and approval gating |
| `DreamREMCycle.swift` | `FileBackedDreamDiary`: typed active/archive discovery, filename/day extraction, checked browsing and by-date reads |
| `DreamRunReservation.swift` | `DreamRunReservation` struct; `acquire`, `release` |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for DreamREMCycle diagnostics |
| `REMConsolidator+GrowthEviction.swift` | `REMConsolidator`: `runGrowthEviction` |
| `REMConsolidator.swift` | `REMConsolidator` actor; `runWeeklyREM` shares one checked diary window with distillation, filters a fresh tombstone batch and resolves committed causal refs for reflection; `rankedByRecurrence` |
| `REMGrowthEvictionHistory.swift` | `REMGrowthEvictionHistory`: durable original approved-growth eviction records, proposal references and pending reconciliation |
| `REMGrowthWriter.swift` | `REMGrowthWriter.appendApprovedLesson`: exact approved paragraph append to a ready canonical persona root, preserving authored headings |
| `REMPinsReader.swift` | `REMPinsReader` enum; `read`, `latest` |
| `REMProposalStore.swift` | `REMProposalStore`: canonical proposal JSONL, checked reads, legacy import, approval transitions and bounded compaction |
| `REMReport.swift` | `REMReport`, `REMRunReportPayload`; manual completion validates counters and refuses skipped passes as completion |
<!-- END GENERATED BLUEPRINT -->

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/EngineRuntime/ -->
| File | Owns |
|---|---|
| `AgentContactRow.swift` | Contact identity/health folding, per-door authority and shared status vocabulary; ContactListFacade retains one checked door read, with primary contacts derived from it. |
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; asynchronous timeline over canonical turn evidence and standalone ledger rows |
| `ChatModels.swift` | `ChatMessage`: `NativeAppChatMessage`, `ChatMessageMetadata`, `CodingKeys`; decode-only inline cards travel with loaded message revisions and never re-encode onto transcript wire; transcript-owned attachment preview bytes/unavailable status carried to Mac and DeviceSync, bounded to the existing 720px display decode; transport copies can omit optional previews before rejecting history |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `ConnectorRecord.swift` | `ConnectorRecord`, `ConnectorActionRecord` and descriptor readiness projection |
| `ConnectorStatusProjection+Actions.swift` | connector action registry, records and checked capability statuses |
| `ConnectorStatusProjection+LocalIntegrations.swift` | connector platform actions, EventKit status, proof cache, local PIM and phone readiness, action evidence; Mac assistant catalog reads invoke the editable `mac-watch-catalog` seed through L0 Parts.call with effects refused; integration recovery parts supply words only over native reasons, preserving operation status/identity/effects, including batch actions, with visible recovery unavailability |
| `ConnectorStatusProjection+Mobile.swift` | Credential-free mobile rows and commands use their own checked refresh result from ConnectorStatusProjection; Mac and phone toggles share update and its checked verification; committed disconnect fences earlier reads through write before lane restart and checked verification. |
| `ConnectorStatusProjection.swift` | `ConnectorStatusProjection` observable engine owner: `LatestRead` publishes checked accounts, secret metadata and credential-free Slack policy; committed account updates publish through `write`, mutation verification uses its own refresh result; source invalidations; `connectorRowWithRuntimeOverlay`, `readConnectorRecords` (finishes pending Slack saves before seeding an absent registry with undecided choices; publication failures propagate), `updateConnector`, `restartSlackLane` (a Slack toggle or a phone Disconnect rebuilds the Socket Mode lane from what is saved); connector pages share decayed action/HTTP receipt evidence, including the Slack door's Web API calls |
| `ContextReceiptProjection.swift` | `ComposerContextReceiptRow`, `ComposerContextReceipt`, `ComposerContextReceiptState`, `ContextReceiptProjection`; shared context trace/receipt facts and checked Composer receipt reader using the caller engine's root for trace and provider/window reads |
| `DefaultReasoningEffortOptions.swift` | `defaultReasoningEffortOptions` |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `DoctorEmbeddingDownloadCheck.swift` | `DoctorEmbeddingDownloadCheck` enum; embedding download health `read`, `repair` |
| `DoctorProviderPathReading.swift` | `DoctorProviderPathReading` enum; checked active-provider route and injected platform probe |
| `EngineApprovalNotifications.swift` | `ApprovalNotificationDelivery`: approval discovery, pending-state selection and notification delivery coordination |
| `EngineApprovals.swift` | `ApprovalsFacade`: one checked records/loading/error publication for health, sidebar, views, actions and phone overview; failed reads retain checked rows and mark them unavailable; shared inline settlement, single-flight resolution and outcome/preflight checks; shared summary/failure wording; Approval reads return their own result; LatestRead orders records/failure publication and committed decisions use write(). |
| `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands` struct; `ability_manage` verbs over `Parts`, the owner's card for a keep and decision receipts; `CapabilityCommandOutcome` invalidates UI projections |
| `EngineCognitionModels.swift` | `LivingStatusSnapshot` and `DreamRunResult` completion and status interpretation |
| `EngineCognitionView.swift` | `CognitionViewFacade`: checked diary/gate revision and file invalidation shared by Dreams, Settings and search; root-scoped model-call readout/refresh; `LatestRead` owns observatory, proposals, vitals, model-call and Living Status publication; watched paths and coalesced refresh coordination; `DreamDiary`: `FileBackedDreamDiary` rows |
| `EngineConnectors.swift` | ConnectorStatusProjection workspace/action reads publish through LatestRead; committed workspace additions publish their own checked result through write; native connector execution supplies its engine root and originating `ToolsFacade.withPartDoor` before calling the domain; no second connector facade or account snapshot. |
| `EngineContactCommands.swift` | Person-initiated sends, verified-session stop commands and held-message withdrawal through engine dispatch; Contact sends/stops and core bridge/A2A construction over the injected engine |
| `EngineContactThreads.swift` | ContactListFacade owns checked doors through LatestRead; shared contact/helper/crew projections and HerScreen's other-room timeline refresh on the same contact signals |
| `EngineDesk.swift` | DeskFacade retains one complete board/overview/page snapshot for Mac and DeviceSync, including prepared attention rows and deadlines; engine inbox/approvals/bots supply its lanes. LatestRead orders board, workflow, research and scheduler publication; committed research receipts use write, scheduler repairs fence older reads before checked feed readback. Job observation and refresh coalescing share the retained feed. DeskToolDispatchRouter retains checked routing and the local-click approval filer while dispatching through the canonical part door, including Make's Try again. |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeskReadModels.swift` | Desk movement, live activity, program-family eligibility and execution slices; `DeskPageSnapshot`, `DeskPageContent`, `DeskAttentionStrip` and `DeskPageWords`; Desk movement/activity projections and WorkStatusPublication; each AppModel retains its own publication/coalescing lifetime and supplies only WidgetKit reload; Shared DeskPageContent facts, project/deadline projection and execution verification values |
| `EngineDeviceSync+Snapshots.swift` | Phone snapshot/action adapter over engine owners: retained Desk board/overview and checked inbox/approval lanes, connectors through `engine.connectors`, persona through `engine.persona` (PersonaFacade), runs through `engine.runs`, skill inventory through engine.tools; shared transcript/card/navigation, other-room exchange and live layout projections; conversation rows carry engine classification and assistant rows carry persisted tool evidence; Trust serialization delegates to `engine.trust.snapshotData`; proposal first_seen/last_seen/staged_at project createdAt and resolved_at is unset; signed incoming-turn delivery and handoff ordering; approvals carry the selected Mac turn ID for transcript anchoring; native presentation and cross-area assembly through ports |
| `EngineDeviceSyncHelpers.swift` | Phone helper edit validation, revisions, provider pin/follow semantics and contact commands; `editBotDefinition` fresh merge/timing; `botsShelfRead` supplies one helper status projection to Mac and DeviceSync; action receipts use the committed definition independently of snapshot refresh, whose `helpers_snapshot_error` marks the phone's shared helpers snapshot stale without failing the committed action; successful refresh replaces it without status overrides |
| `EngineDoctor+Cognition.swift` | `EngineDoctorRuntime`: cognition health and repair; APNs diagnostics name the canonical push-token store, never retained mobile_push/tokens.json |
| `EngineDoctor+FirstTurnRefresh.swift` | `DoctorFacade`: one launch refresh after a persisted terminal turn trace; retains its task and disarms both observation and refresh on launch stop |
| `EngineDoctor+StatusChecks.swift` | `DoctorFacade`: checked Desk attention and Activity facts go through L0 Parts.call to Resources/abilities/diagnostic-narration.js outside view rendering; native measured status, approval/store failures, corruption detection, unknown-outcome reconciliation and parent repair remain here; an unavailable narrator is explicit without being mistaken for a canonical read failure |
| `EngineDoctor.swift` | DoctorFacade owns report evidence, loop verdicts and DoctorPlainCopy summary/issue rows; rooted weekly digest/error, activity, hardening/exports, gauntlet, health card, liveness, watchdog and live report refresh publish through LatestRead; completed reports and committed exports use write. RuntimeHealth is liveness metadata; lifecycle facts remain manager-owned; run history belongs to engine.runs. |
| `EngineDoctorRuntime.swift` | EngineDoctorRuntime and EngineDoctorPlatformPort own live health interpretation, repair admission, Support Snapshot reuse and pending-transition wake; one manager/receipt read supplies both the loop check and DoctorFacade verdicts. |
| `EngineInbox.swift` | InboxFacade publishes checked items, triggers and read errors through LatestRead; each caller receives its own rows; markRead and committed trigger changes use write; owner-scoped observe/observeTriggers, including canonical ability invalidations for authored trigger defaults, loading and availability; InboxItemRecord action/proactive prominence and newest physical row per stable card id. |
| `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery starts independently at launch, its install observation once part wakes are registered; trusted bundled seeds installed before ingress; current seeds follow changed shipped bodies, while edited/non-seed content and other occupied slots are preserved, each failure retained by AbilityFilesCheck and reported through Doctor to the person while launch continues; an installed seed the readable bundle no longer ships, still its proof's candidate and never re-enabled, is switched off through its registry (restorable); root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, procedure-retention root admission and terminal drain, background loop manifest and surface/workshop/scheduler composition; native effects arrive through EngineBackgroundWorkHost; MCP servers a data root kept are raised to their once by name as theirs to grow (`raiseKeptMCPServers`), their file untouched and, since a launch line can carry a key, fenced from their file readers with its backup copies; `tellRetiredConnectors` removes retired service rows and tells their once which were set up; old credentials stay untouched and unread; the engine exposes the existing activity controller through its body host |
| `EngineMacIntegration.swift` | `MacIntegrationFacade`: root-specific checked permissions, nonprompting OS grants and watch readiness publish through `LatestRead`; explicit Mail evidence shares the same owner and invalidation; Setup, Mac Integration, connector actions and quiet pages share these reads; permission-file and root-specific notifications invalidate the same owner; phone serialization uses its own returned checked permission result |
| `EngineMaintenanceParts.swift` | EngineBackgroundWorkPort enters ToolsFacade.withPartDoor for L0 Parts.call of maintenance-assistance and backup-cadence; preserves backup-cadence cancellation as CancellationError; returns typed card prose, optional deadlines and trigger choices without publication or backup execution authority |
| `EngineMemory.swift` | Memory v2 status and read availability publish through `refreshStatuses`; pending proposals publish checked rows and failure together through `proposals(status:)`, retaining checked rows on failure and leaving decision animation to the Mac; memory reads/search/writes and durable review-reminder crossing; one checked `graphSnapshot` shared by Knowledge Graph and Capabilities; `ProposalRecord` evidence; LatestRead orders pending proposals and memory status; committed proposal decisions use write() with the Mac's existing animation transaction. |
| `EngineNotificationActions.swift` | `NativeAgentEngine.handleNotificationAction`: native owner-response interpretation, approval reread and composer admission |
| `EnginePartWake.swift` | `EnginePartWake`: `start`, `deliver`, `run`, `readsOnly`, `reindex`; Autonomy-gated wake index, per-part single flight, including source-triggered sense interpretation (material/transport stay source-owned, bundled senses need no wake header); a `held`, `resumed` or source-subscription wake Autonomy refused waits (`holdBack`, preserving source slot/helper generation independently of the header index) and is delivered when a trust-policy change finds the switch on; unreadable authority clears the index with repair owed, and a `held` or `resumed` wake meanwhile waits for it to read again; tainted signals skip write-capable parts (`tainted_signal` trace, no card); gated resident tools/skills and resident senses; current Chat model and signal audit; file-change watches survive absence and suppress self-writes; turn-end steer retained; `resumed` delivered once at launch; `person.away`/`person.here` signalled from `MacPersonInput.presenceChanged`, whose first deadline is armed from existing idle after this observer registers; header-declared runs are `HerOpened` work |
| `EnginePersona.swift` | PersonaFacade owns profile/documents and retained read availability for Mac, editors and DeviceSync over unchanged PersonaEngine content readers/writers. LatestRead orders reads/failures, committed profile/name/document saves use write; chat/settlement scaffolding keeps its existing effect without discarded diagnostic compilation. |
| `EnginePresentationModels.swift` | Root-scoped `PresentationFaces` feeds L0's pure `presentation-copy.js` cache outside rendering; page subtitles and tool phrases are removed from Swift, while sanitized tool facts, classification and identity grammar stay native. `TelegramPresentationSnapshot`, shared route vocabulary, `SidebarItem.shellFirstTab`, `SidebarItem.shellHome`, `UserDisplayFormatters`, temporal/receipt values and shared inline card presentation remain |
| `EngineProviderHelpers.swift` | ProvidersFacade checked settings refresh, credential/OAuth verdicts, model grouping, eligibility, snapshot-owned model/account inheritance, auth normalization and quiet provider policy; routing-derived selections share SettingsSnapshot. LatestRead orders settings and failures; committed routing publishes through write and retires prior session reads before checked session refresh. |
| `EngineProviders+Adoption.swift` | Blank-surface adoption delegates to the routing transaction and publishes its committed snapshot through LatestRead.write; serialized chat-brain saves retain pending edits, while canonical selection derives from ProvidersFacade.settings. |
| `EngineProviders+Probe.swift` | `ProvidersFacade`: `testProvider`, `clearProvider` |
| `EngineProviders.swift` | ProvidersFacade.settings owns routing, connections, catalog and derived readiness for every Mac picker and phone publication; provider/account invalidations refresh this snapshot. LatestRead orders settings and per-session route/context reads, returning each caller its own result; committed routing publishes through write. ProviderRouting owns persistence, discovery and eligibility; editors hold pending choices only. Catalog rows come only from the live catalog owners; the unwritten providers/models.json compatibility input is retired. |
| `EngineRouteError.swift` | Engine route failures and shared UserFacingError interpretation |
| `EngineSenses.swift` | One engine Senses projection for registry records, news and interactive views through `LatestRead`, committed switches through `write`; one window sampler while Senses or Work is visible |
| `EngineSync.swift` | `SyncFacade` class; `observeStatus`, `setStatus`; pairing-key snapshot reads publish through `LatestRead`, and rotation advances the same boundary |
| `EngineTelegram+Commands.swift` | Telegram configuration and mobile commands; Telegram token admission, settings and delivery commands, typed diagnostic-clear receipt; diagnostic state edits delegate to TelegramPollLoop.mutateState |
| `EngineTelegram+Reply.swift` | Telegram reply delivery and result models |
| `EngineTelegram.swift` | Telegram facade and tool status envelope; `TelegramFacade` class; `configuration`, `loadStatus`, `load`; status uses TelegramPollLoop's checked state read, reporting unavailable state in lastError; `refresh` alone publishes status through `LatestRead`, including diagnostic-clear readback; credential badges read TelegramPresentationSnapshot.tokenConfigured directly |
| `EngineTools.swift` | ToolsFacade owns authored tools, slash planning, full form descriptors and shared catalog status classification; `withPartDoor` gives native scheduled/UI owners and Tools Keep the ordinary gated chain and AppChatToolDispatcher host, with originating work identity, resident approval session and caller's file-access posture inherited by part thinking; native callers can supply their authenticated envelope and existing approval filer, preserving Telegram transport and Desk-click authority without another door; one checked skill inventory supplies metadata, source/revision and guidance detail from the same body read (phone metadata omits source). LatestRead orders slash, catalog, authored, skill and native-power reads; committed authored writes use write. Native actions derive from their registry; receipts and notification/browser status retain availability. |
| `EngineTranscripts.swift` | `TranscriptsFacade`: root-scoped index/transcript invalidations, `CommandPaletteMessageIndex` and checked saved bot/memory search inputs; per-session observable slots and `LatestRead` card/read-status publication returning each read's own result; message writes retain published card rows/models, committed transcript clears use `write`; messages, streaming tails and first-conversation identity; resolved display titles and shared navigation/pin/anchor mutations; `loadTranscript` projects cards, heading and attachment previews from one transcript/root while preserving live rows; `refreshCards` and helper `observeSessionMessages` use that owner; Mac, detached, Shotgun, quiet chat, inbox cards and DeviceSync share the projection; `ChatTranscriptCache` owns file-identity transcript/shell/context reads; session transactions, unread accounting, stream/resume/settlement, mutations and slash execution |
| `EngineTrust.swift` | TrustFacade owns checked policy, effective feature verdicts and security status/invalidation; raw/typed policy and phone serialization publish through LatestRead, committed policy through write. Catalog/source/install/network publication, Privacy Map and inbox policy each share a LatestRead; catalog/inbox commits use write. Policy derives autonomy guardrails; connected-agent rows belong to engine.contacts. Rooted Mac audit decoding retains availability and canonical/legacy receipt fields. |
| `EngineTurnContinuation.swift` | `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; completion destination recovery uses the bound engine and attention router; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders; `TurnContinuationRuntime` struct; process checkpoint resume, Desk verification/resumption and approval follow-up share turn admission and reply settlement; caller-result recovery registers with the retained task's worker and cancellation owner; composes existing TurnTrace state and helper ownership; retains anchor mirror intent and reconciles its lifecycle with injected platform senders |
| `EngineTurns.swift` | TurnsFacade owns turn lifecycle/Stop/queue/screen-preview presentation, one Capabilities trace feed without an extracted copy, and read-only Agent View pane text/subscriptions keyed by conversation and room; LatestRead orders trace publication and each pane independently. The preview binds L0's pure helper face to its native root without effects and preserves last-seen semantics |
| `EngineWorkshopObservatory.swift` | `WorkshopScoreView`, `DeskPursuitVetoRationale`; Workshop read projections |
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletStatus`: `ImprovementGauntletRun`, `GauntletCheck` |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `MacChatScreenPreview` struct; `merged`; `TurnsFacade.receiveScreenPreview` |
| `MacIntegrationDeliveryActions.swift` | Mac integration protocol execution, scheduler and Spotlight routing; due-reminders passes the requesting dispatcher's root to LocalPIMConnectorActions; Music calls the editable music part through L0, and Mail/Messages/Notes recovery words come from their parts while facts/evidence stay native; mobile notifications delegate to AppToolRuntime with the dispatcher surface; checked pairing and phone result routing; Mac notification receipts and MacControl adapter |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for EngineRuntime diagnostics |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |
| `NativeAgentEngine+IntentChat.swift` | `NativeAgentEngine.replyToIntent`: captures the person's location before shared chat queue admission; chat applies the saved choice |
| `NativeAgentEngine.swift` | Core live/isolated root selection, chat/tool and manifest composition; resident service facades, shared persona/configuration/runs projections and `ConnectorStatusProjection`; Desk receives the engine's inbox, approvals and bots; owns root-scoped contact/crew and layout observation plus Activity invalidations and the bot scheduler shared by deadlines and read projections |
| `NativeAgentEnginePorts.swift` | Once-installed native host factories, body effects and shared EngineCognitionHost defaults; pure readout faces bind the selected Parts version through the no-effect authored host; read-part calls bind the existing ToolsFacade originating door and narrow the pinned candidate to native-permitted read actions/capabilities |
| `NativeAgentResidentRefresh.swift` | `NativeAgentEngine` onboarding/resident refresh: profile transitions defer mind/context reload until admitted turns drain |
| `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |
| `NextGenActionExecution.swift` | capability action probes and execution receipts; release.gate is retired because release/checklist.json has no producer and an absent checklist cannot establish a gate |
| `NextGenStatusModels.swift` | `NextGenSummary`, `NextGenReceipt` structs |
| `NextGenStatusProjection.swift` | Engine-owned observable NextGen snapshot: phases, summary, receipts, read failure and executor-backed eligible actions shared by Capabilities and Chat; receipts read only the executor-owned nextgen/actions/receipts.jsonl, with the unwritten runtime/nextgen_receipts.jsonl input retired; no UI receipt accumulation or secondary merging; LatestRead orders whole-snapshot/failure publication while returning each read's own snapshot. |
| `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |
| `PersonalityGrowthSummary.swift` | `PersonalityGrowthSummary` struct |
| `RuntimeReadProjection+Configuration.swift` | `RuntimeReadProjection.Configuration`: publishes and returns its own saved SearXNG URL read; configuration reads use the engine projection and the provider owner's `LatestRead` for Codex authentication, while editors retain separate drafts |
| `RuntimeReadProjection+Feeds.swift` | Notification pending counts read only ApprovalInbox; the unwritten notification receipt input and inferred authorization are retired. Browser reads, checked skills with opt-in source/revision from the inventory body epoch, JSON decoding and JSONL tails; engine.runs retains rows and availability through LatestRead and returns its own read for DeviceSync, preserving rows on failure. Saved-things reads delegate to existing Desk, bot, memory and diary owners. |
| `RuntimeReadProjection+Improvement.swift` | `RuntimeReadProjection`: `swiftImprovementGauntlet` |
| `RuntimeReadProjection+Personality.swift` | RuntimeReadProjection.swiftPersonalityGrowth; saved profile/document reads, failures and committed writes belong to PersonaFacade. |
| `RuntimeReadProjection+QuietPages.swift` | Quiet page/item formatting and navigation over engine projections: Desk uses the complete retained `DeskFacade.page` and its prepared attention rows, helpers use `botsShelfRead` including followingModel, chat cards and heading use the checked transcript projection; unsupported card states share one person-directed defect naming the card; page indexing takes the live layout; Mac access/grants render `MacIntegrationFacade`; connector items expose secret names without values; shared Trust, provider, inbox and settings read formatting |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadProjection`: `getTraces`; `RuntimeReadError` enum |
| `RuntimeReadProjection.swift` | Autonomy delegates to TrustFacade's policy projection; unused personal-OS compiler read is deleted (Capabilities renders the published profile); `getSessionContext` requires the effective session provider |
| `RuntimeSummaryModels.swift` | `KernelGuardrail` struct |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SelfImprovement+Gauntlet.swift` | RuntimeReadProjection owns stateless gauntlet artifact reads and promotion-class projection directly, without a temporary actor |
| `SelfImprovement+TrainingReads.swift` | `HarnessBenchmarkRun`, `HarnessBenchmarkCheck` models and benchmark execution returning its result without a duplicate receipt store; unused `evals/runs.json` reads/schema and `harness/benchmark/runs.jsonl` writes/retention are retired; retained files stay on disk, outside backup, export and phone sync, and appear in PrivacyMap |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SurfaceRuntimeStatusModels.swift` | Approval-backed notification pending status and browser status models; no unwritten notification receipt or inferred authorization fields; browser status exposes capture paths, with no unused profile path |
| `TolerantDisplayStringDecoding.swift` | `JSONValue.nextGenDisplayString` |
| `TranscriptReadProjection.swift` | transcript/read caches; `ChatShellConversationRow`: `isWorking`, `preview`, `isBridgeRouted`; conversation and running-session routes, turn card/trouble projection and native title-source classification. Stored human titles stay native; automated title prose is removed to the batched `presentation-copy.js` face before TranscriptsFacade publishes. No render-triggered naming or view-owned anchor reader |
| `WorkOverviewRead+Today.swift` | `TodayProjection` freezes checked sources and provenance, feeds the pure `today-readout.js` faces through L0's version/epoch cache, binds source IDs to native dates and note links, and publishes through `LatestRead`; waiting counts share a pure face too. `TodayDreamDigest` reads the latest dream through `DreamNight`; native input supplies its title, mood and timestamp, never diary Markdown for JS to parse. Narration, grouping, due words and ordering live in the part. Unbound rows are omitted individually with native reasons; other activity, Ahead, earlier notes and note links remain. Native unavailable evidence, localization and live clock gutters remain. Mac and quiet reads consume the same prepared rows |
| `WorkOverviewRead.swift` | `WorkOverviewRead` enum; `project`, execution/Desk-item `row`, `text`, `requiresApproval`; overview and phone task rows share the execution approval predicate; ID-based details use the same status projection; complete owner-attention counts by reference kind before mobile list bounds |
<!-- END GENERATED BLUEPRINT -->

### MacIntegration

Directory: `Modules/NativeAgentCore/Sources/MacIntegration/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacIntegration/ !Modules/NativeAgentCore/Sources/MacIntegration/MacIntegration*.swift !Modules/NativeAgentCore/Sources/MacIntegration/MailReadLocator.swift -->
| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: `mailListRecent`, `mailSearch`, `mailSend`, `mailDraft` |
| `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: `mailWorkspaceRead`, `mailReadScope`, `mailIndexDatabase`, `mailSenders` (exact grouped sender counts), `mailFileRead`, `mailAttachment` (paired-identity .emlx bodies, MIME/table decoding and local attachments) |
| `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: `messagesRecentThreads`, `messagesSend`, `notesModify` (exact-note update or reversible deletion) |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`: delegates `runAppleScript` to MacControl, skill hand-back and integration envelopes; `deniedEnvelope`; Music recipe/parsers live in the editable `Resources/abilities/music-library.js` and `music.js` seeds, called through L0 `Parts.call` by MacIntegrationDeliveryActions; the playback receipt and effects survive failed readback as a separate `now_playing` fact, and exact title/artist selection uses Unicode full case folding |
| `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in SystemAppleScriptAdapter |
| `MacAssistantStatus.swift` | assistant status client, result, lightweight serialization of an existing full result, Mail readiness projection and native watch access evidence; typed catalog data and UI words come from `Resources/abilities/mac-watch-catalog.js`, never creating jobs; missing/disabled/invalid catalog is unavailable, never an empty catalog |
| `MacContactsExecutor.swift` | concrete `CNContactStore` ownership, authorization, selection, mutation validation, name cache and projection |
| `MacMessagesHistory.swift` | protected Messages-directory access probe, bounded SQLite reads and folded matching |
| `MacMessagesTypedString.swift` | bounded attributed-body archive decoding |
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

Directory: `Modules/NativeAgentCore/Sources/MacControl/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/MacControl/ -->
| File | Owns |
|---|---|
| `MacAXAttributeRead.swift` | `MacAXAttributeRead` enum; one checked raw attribute copy preserves AX failures for required native evidence, with nil-tolerant perception/action projections; package-native clients share raw/string, parent, label, action-name and frame reads; static-text selectors use their text when no caption names them, while field values stay separate; visible list/table/outline child ordering shared by reads and action paths, on-screen/total counts; `copyTextRange`, `copyRaw`, `copyWindowIdentity`, shared identity `copyLabel` retaining redaction captions, separate display names with help cleanup and explicit AX title-element captions |
| `MacAccessibilityActuator.swift` | `MacAccessibilityActuator` enum; `act`; exact-element native actions and attributes share driver checks and mutation recording with resolved actions; native admission failures remain separate from actual AX return codes; `CGEventSink` owns native key/click preparation and HID emission; `SystemMacAXActSource.activate` and `raise` share measured app activation, driver checks and Automation diagnostics; app-only activation reads no AX windows and preserves the self-AX fence; `MacAXActSource.windowPresence` checks the owning process's AXWindows plus focused/main windows, distinguishing unreadable inventory from confirmed absence |
| `MacAccessibilityReader.swift` | Shared AX walker and node/depth/time budgets; package-native window/subtree and direct-child reads use that walker with topology-only snapshots and optional caller-scoped descent, report incomplete reads with search purpose, visited count, unseen floor and reasons, and never collect credential values; passive native reads share its deadline and cancellation; native reply text requires readable static AXValues and checked topology subroles; `SystemMacAXElementSource` owns exact native window inventory and transient menu roots |
| `MacActClosedLoop.swift` | `MacActClosedLoop.verify` owns the declared-effect verdict for semantic, menu and physical act receipts: exact complete AXValue, selection range, selected/state/focus, owned window/sheet creation, confirmed removal or process exit and AX surface transitions; pixels are witnesses only; readable mismatches are `acted_mismatch`, unavailable readback (including canonically masked text values) is `acted_unobserved` |
| `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |
| `MacAppIndex.swift` | One in-process live Spotlight metadata query over local volumes; rows excluding bundles inside packages materialize only on gathering/update edges on its owning queue; cancellation removes async initial-gather waiters; startup failure retires query/tokens and completes gathering once; terminal `shutdown()` closes admission, stops query/tokens and finishes streams on that queue (engine caller integration remains required); sync/async reads and exact lookup share kept rows; newest-only edges emit when bundle id/version/path changes; actionable index failures propagate; `mac.apps` names its Spotlight source; Launch Services remains the launch fallback after an index miss |
| `MacAppMaps.swift` | `MacAppMapStore` owns per-app control maps and learned choices; malformed maps remain in place without overwrite; no quarantine/reset copy |
| `MacAppSourceEvents.swift` | `MacAppSourceEvents` class; event-backed running-app AX observation, coalescing, cancellation and notification-stall completion for cold reads; incomplete traversal retains prior subscriptions and only a complete read prunes missing descendants, application/window/focus subscriptions stand if any succeeds, and zero supported notifications is `source_unsupported` |
| `MacAppWindowText.swift` | `MacAppWindowText` enum; one positional-redacting on-device recognizer for current app-window capture and ephemeral whole-window shots before text-only retention |
| `MacAttention.swift` | `MacPersonInput` owns exact person input and canonical presence; its motor-fenced session-activity read lets capture resume without Input Monitoring and never publishes presence; motor provenance, attention monitoring and attention sessions; `MacPersonInput` owns person/synthetic input provenance and the presence fact; attention uses that provenance for synchronous takeover, retaining scene events and person-only-window exclusions; `MacDriverBinding.settlementBinding` gives `settle` an independent cancellation lifetime under the original authority and driver generation; `stopAttentionSession` ends only the optional session, `revokeDriverControl` hands back control |
| `MacBackgroundSight.swift` | `MacBackgroundSight.resolve`: pure running-app matching without activation; missing, ambiguous and self targets remain distinct |
| `MacClipboard.swift` | `MacClipboardRead` and pasteboard ports: permission-bound clipboard reads/writes, source redaction and bounded text/type projection |
| `MacControl+Adapters.swift` | System adapters, bundle-specific AppleScript/JXA Automation targets and permission status; authored app calls support `launch:false` with URL-bound running-process resolution and explicit `not_running`/no effects, and `read_only:true` enforced by the native per-event send callback; execution-boundary translation of shared process-pipe setup errors |
| `MacControl+Client.swift` | `SwiftNativeMacControl` actor; `dispatch`, `dispatchApprovedInjection`; `MacObservationMode` carries passive read authority without motor binding, wake, capabilities or desktop effects |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl`: `handleAct`, `pointerRestoredJSON` |
| `MacControl+DictionaryHelpers.swift` | `Dictionary.stringValue`: MacControl's shared typed string lookup for JSON argument dictionaries |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: `waitForTextInput`, `handleHand`, `watchedWindowMiss` (a watch's events land on its window, read at each event), `handleNudge`; text input verifies focus, selection and value with cancellable 25ms polling bounded to 750ms; hand text mismatch excerpts are always redacted because its readback lacks canonical caption/group redaction context |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`: `handleMenu`, `handleMenuPress`, `handleClipboardRead`; surface menu commands await surface-transition notifications within the existing deadline before owned-window readback; Select All keeps its range readback |
| `MacControl+OperationSupport.swift` | `SwiftNativeMacControl`: `attachingOperation`, `replayResult`, `unknownResult` |
| `MacControl+Perception.swift` | `SwiftNativeMacControl`: `handleRead`, `documentPath`; semantic view masks pixels from the complete AX snapshot's secret frames before sharing |
| `MacControl+SystemActions.swift` | `SwiftNativeMacControl`: `handleFileRead`, `handleFileWrite`, `handleFileList`, `handleMedia` (Now Playing system keys and running-player observations) |
| `MacControl+Types.swift` | `MacControlSensitivePathFence` owns the mutation floor both raw file routes use: OS paths and dedicated Mac-control state/audit, their screen, activity capture and experience stores, including protected parents; reads and copy sources keep their scope |
| `MacControlActionRoutes+PlatformPolicy.swift` | checked Trust policy provider and bounded process-result interpretation |
| `MacControlActionRoutes.swift` | Mac control dispatch receipts plus workbench availability and category policy |
| `MacControlOperationStore.swift` | `MacControlOperationStore`: canonical payload-free operation lifecycle, request digests, cancellation settlement and motor projection |
| `MacCrossAppDrag.swift` | `MacCrossAppDrag`: two-anchor drag resolution, destination raising and secure/obstructed path refusals with actual-effect evidence |
| `MacDocumentRead.swift` | `MacDocumentRead`: bounded document extraction and scrolling accumulation; admitted file access, deadlines and redacted read frames |
| `MacDocumentReadTakeover.swift` | `MacDocumentReadTakeover.mark`: physical-input takeover signal for bounded reads, preventing subsequent wheel emissions without changing permissions |
| `MacFourVerbs+Act.swift` | `MacFourVerbs`: `act`, `addAttention`, `frontChangedWords`; batch cancellation and confirmed declared-effect mismatches stop further steps while preserving emitted input and each returned receipt's landed or uncertain outcome for resume |
| `MacFourVerbs+AppMap.swift` | `MacFourVerbs` app-map integration: learn only verified named-control acts; remembered routes must match fresh live element evidence |
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `webURL`; landing targets the recipient returned by Launch Services |
| `MacFourVerbs+Observation.swift` | `MacFourVerbs`: `screen`, `observedReply`, `sight`; self-window looks hand off to the mounted `visible` presentation without claiming a completed read; call-local complete AX read shared with pixel capture under window identity and frame-generation validation; observed and blind replies preserve failed declared-effect verdicts and confirmed window/process removal even when the next screen belongs to another app |
| `MacFourVerbs+PerceptReconstruction.swift` | `MacFourVerbs`: `percept`, `partition`, `supplementalDuplicateIndex` |
| `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: `performPhysical` |
| `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: supplemental AX native-page merge, `zoom`, `parseVerb`, `isRightClick` |
| `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: `resolve`, `answers`, `bareNumberNote` |
| `MacFourVerbs+Wait.swift` | `MacFourVerbs`: `wait`; app-level signals prompt bounded screen re-reads; action verification uses its owning bounded polling waits without additional subscriptions |
| `MacFourVerbs+WorkspaceControl.swift` | `MacFourVerbs` workspace acts: fresh exact frame/app/window/handle checks; supplemental surfaces never raise background apps for physical input |
| `MacFourVerbs.swift` | `MacFourVerbs` struct |
| `MacFourVerbsContracts.swift` | `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement`, `MacFourVerbsSupplementalPerceptionSource`; four verbs dispatch through `MacControlClient` |
| `MacHandRepertoire.swift` | `MacHandRepertoire`: pure bounded keyboard/pointer plans with held-key/button balance and residual-release accounting |
| `MacMenuBar.swift` | `MacMenuBar`: bounded native menu reads, path resolution and safe semantic presentation |
| `MacPerceptionCompiler.swift` | `MacPerceptionCompiler`, look frames and handles: graded perception from the existing AX snapshot, redacted readouts and fresh target resolution |
| `MacPointerObservation.swift` | `MacPointerPosition` and `MacRegionAim`: actual cursor observation and clear-region aiming; unavailable position never becomes an invented origin |
| `MacScreenPageCompiler.swift` | `MacScreenPageCompiler` enum; complete nested AX reading order, structural/activation alias folding, adjacent checkbox captions in structured and aggregate documents, document title ownership, sentence-first links including aggregate document text, AX landmark and card sections, live-region text with duplicate container folding, display cleanup after full-context redaction, composite rows with status details and exact related-action bindings |
| `MacScreenRender.swift` | `MacScreenText` and `MacScreenRender`: shared semantic/pixel screen formatting that preserves compiler redaction verdicts |
| `MacScreenView.swift` | `MacScreenShot`, `MacScreenViewGeometry`; `MacScreenViewTextRedaction` owns field/prose secret-label vocabulary with distinct matching rules and shared AX/OCR caption geometry with caller-unit proximity; session-scoped `MacImageFrames` holds delivered pixel geometry under the semantic observation's reference (desktop images mint their own) |
| `MacScreenViewCapture.swift` | Window/display capture selection, `SystemMacVisualObstructionProbe` (other apps' windows over a frame, for sight and a watch's hands) and `SystemMacScreenCaptureSource`; exactly-once callback cancellation invalidates results and resumes immediately, with no cancellation-ignoring join on an unabortable ScreenCaptureKit callback |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG` masks secret frames before encoding; `encodePNG` |
| `MacScreenWatch.swift` | One exact-window ScreenCaptureKit stream per part run, generation-bound frame queries and physical hands; person-only windows refused, secret fields inspected every 500 ms and painted out, incomplete inspection ends with an owned failure. Inspection work is retained; success and failure commit only while active, so expiry cancellation cannot cut admitted settlement short or create repair debt. Authority is checked at next/read/hand; window identity at each event. Terminal errors retain their cause; outside an enclosing act Experiences owns repair until an inspected frame from the same window/region arrives or it is let go. Duration stops capture and closes admission immediately; an admitted frame read or hand has up to 10s (the maximum hand duration) to settle before the retained frame and held input retire. Non-cooperative work retains its local frame until actual exit and cannot publish after retirement. Stop, window loss/resize, revocation, part change and takeover retire immediately. |
| `MacTransientMenus.swift` | `MacTransientMenus`: bounded near-focus native menu evidence and capture geometry, without a second window address space |
| `MacVisionTextGeometry.swift` | `VisionRect`, `VisionSize`, `VisionTextBox`; shared image-pixel OCR geometry |
| `MacVisionTextRedaction.swift` | `VisionTextRedaction`, `VisionRedactionConfig`, `VisionRedactedText`; pixel-unit adapter to shared AX caption geometry; one positional caption/overlap redaction boundary for both OCR readers |
| `MacWaitSignals.swift` | `MacWaitSignals` and activation observation ports: cancellable event-driven waits that consume existing app/AX signals |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MacControl diagnostics |
| `TrustedRemoteEffectNodes.swift` | Reads operator-provisioned trusted node JSON and returns SSH execution receipts to the caller; unused provisioning APIs and unread receipt-file writes are retired |
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
| `AfterTurnNoveltyGate.swift` | `AfterTurnNoveltyGate.skipReason`: on-device acknowledgement/repetition admission for after-turn memory interpretation |
| `EmbeddingModelDownload.swift` | `EmbeddingModelDownload` actor; `ranges`, `assemble`; operation-scoped status observation and retained, cancellation-aware extraction through actual subprocess exit; shared status text and progress projection |
| `EmbeddingStatusReadiness.swift` | `EmbeddingStatusReadiness` struct |
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
| `KnowledgeGraphReadProjection.swift` | Checked complete graph projection, including typed canvas entities/edges and derived entity neighborhoods from the same snapshot; `canonicalAgentGraphProjection`, `agentGraph`, `canonicalKnowledgeGraphSnapshotData` |
| `KnowledgeGraphReader.swift` | `SwiftNativeKnowledgeGraphReader`: one checked backend admission for bounded single and batched SQLite reads, optional entity enrichment and immutable legacy snapshots |
| `KnowledgeGraphSearchProjection.swift` | Typed graph search projections |
| `KnowledgeGraphTypedRead.swift` | Typed checked projections on `SwiftNativeKnowledgeGraphReader` |
| `LegacyCorrectionScopeMigration.swift` | Reviewed scope application and its consumed completion marker; no dated write-only audit copies; `runIfNeeded`, `migrationsDir` |
| `MemoryConsolidationGate+Database.swift` | `MemoryConsolidationGate`: `transactionalTableSwap`, `backupLiveStore`, `sweepBackups`; snapshots included in local backup/export, excluded from off-disk backup and phone sync |
| `MemoryConsolidationGate+Receipts.swift` | `MemoryConsolidationGate`: `writeManifest`, `readManifest`, `readReceipt`; cards append through `LiveNotificationInbox` |
| `MemoryConsolidationGateContracts.swift` | `MemoryConsolidationDiff` struct |
| `MemoryConsolidationHygiene.swift` | `MemoryConsolidationHygiene`: sole typed hygiene receipt reader/writer, including approved-swap reconciliation; `runOnce`, `lastRunPath` |
| `MemoryDataProvenance.swift` | `MemoryDataProvenance`: stamp, retain and consume untrusted memory sources across writes and readbacks |
| `MemoryEmbeddingEpoch.swift` | `MemoryEmbeddingEpoch`, `MemoryEmbeddingBatch`; engine-stopped launch epoch reconciliation on the canonical memory owner; admission retained through actual flight exit |
| `MemoryHygieneReport.swift` | `MemoryHygieneReport` struct |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring`: timestamp delegation, decay, literal kind extraction and record correction classification; mutation exceptions require explicit correction kind |
| `MemoryRecordDisclosure.swift` | `MemoryRecordDisclosurePolicy`: pure shared record privacy/persona/surface disclosure, independent of Trust tool admission |
| `MemoryRepairOneShot.swift` | `archiveInventoryRows` and approved canonical truncated-row execution with safety snapshots; legacy notes staging, scanning, purge, stamps and outcome files are retired without touching existing files |
| `MemorySenseProvenance.swift` | `MemorySenseProvenance`; `MemoryStorage.markVersionWrong`: durable sense-version warning metadata |
| `MemoryStatusModels.swift` | MemoryV2 counts, embedding and after-turn recovery wire models |
| `MemoryStatusProjection+WireModels.swift` | memory status wire models |
| `MemoryStatusProjection.swift` | MemoryV2 and embedding runtime status projections and recent misses; hygiene reads use MemoryConsolidationHygiene's schema; embedding settings act through MemoryFacade's canonical owner; `MemoryV2NativeStackSnapshot` reads native stack health |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+Comparison.swift` | `MemoryStorage`: comparison-key modes, duplicate modes, scope/epoch checks and quantity/polarity matching; callers own candidate execution |
| `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: `embeddingCorpusSnapshot`, `embeddingEpochState`; derived action vectors in `memory.sqlite`, keyed by embedding epoch and exact-text SHA-256, outside the canonical corpus |
| `MemoryStorage+Integrity.swift` | `MemoryStorage`: `requireSemanticIntegrity`, `spotlightGenerationFingerprint` hashes only eligible exported payload; `createConsistentBackup` |
| `MemoryStorage+Migrations.swift` | `MemoryStorage.migrator`; registered GRDB schema migrations |
| `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |
| `MemoryStorage+Recall.swift` | `MemoryStorage`: `invalidateRecallCache`, shared `rankedRecall` scoring and bounded `recall` deduplication, canonical recall-generation cache |
| `MemoryStorage+Tombstones.swift` | `MemoryStorage`: `upsertTombstone` |
| `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |
| `MemoryV2+AdaptivePromoter.swift` | `AdaptiveMemoryPromoter`: after-turn fact interpretation and held moment lanes, bounded staging and memory-manager outcomes |
| `MemoryV2+ConsolidationGate.swift` | `MemoryConsolidationGate`; gateLockTarget/withGateLock; reconciliation repairs known terminal receipts and respects the approval owner's terminal execution outcome before any candidate application |
| `MemoryV2+ConsolidationStorageSupport.swift` | `MemoryConsolidationGate`: `consolidationDir`, `candidatesDir`, `candidateRoot` |
| `MemoryV2+Consolidator.swift` | `MemoryConsolidator`: gated pending-proposal consolidation, duplicate/supersession handling and active-memory archival |
| `MemoryV2+DueDateStamp.swift` | `MemoryDueDateStamp`: conservative spoken-plan date/time resolution and metadata stamping for forward expectations |
| `MemoryV2+Embedding.swift` | Embedding provider contracts and `CoreMLEmbeddingProvider`: real-model loading, artifact epochs, bounded compiled-model storage and fail-closed availability |
| `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot`; canonical runtime embedding backend with performance residency and the query form (bge queries carry its retrieval instruction, stored text never); durable action-index updates at warm-up and inventory changes, with serialized missing-text fills and background epoch rebuilds; engine termination closes admission, removes passive observations and cancels/drains both convergence flights through actual exit |
| `MemoryV2+FoundationModels.swift` | `AppleFoundationModelsAdapter.classify`: on-device kind labels for existing memory rows; no fact extraction |
| `MemoryV2+KindBackfill.swift` | `MemoryKindBackfill`: approval-staged legacy row classifications and checked apply through canonical storage |
| `MemoryV2+KindStamp.swift` | `MemoryKindStamp`: conservative write-time memory kind and source metadata defaults |
| `MemoryV2+LaneRetention.swift` | `MemoryLaneHandle` and lane retention: bounded lane-owned row reads and archival without tombstoning user memory |
| `MemoryV2+MemoryManager.swift` | `MemoryManagerLane`: semantic after-turn memory decisions, grounded correction validation and reconciliation against existing rows |
| `MemoryV2+Moments.swift` | `MemoryMoments`: grounded exchange/quote candidates, provenance metadata, content validation and rumination projections |
| `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; `isEnabled`, `knowledgeGraphEnabled` |
| `MemoryV2+ProbeRunner.swift` | `MemoryProbeRunner`: existing known-answer recall scoring/comparison through canonical storage and embedding epochs |
| `MemoryV2+ProbeSet.swift` | `MemoryProbeSet`: known-answer probe values, bundled/override loading and strict parsing for consolidation admission |
| `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |
| `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`: `recordRecallHits`, `recall`, `readMemoryRecord`; invocation-local ranked voices reused for disclosure refill |
| `MemoryV2+RecallQueryExpansion.swift` | `MemoryRecallQueryExpansion`: persona/user name-aware first-person recall rewrites |
| `MemoryV2+SharedInstance.swift` | Concrete `MemoryStorageBridge` translates canonical records; attachment readiness, engine-closed projection hooks and unavailable-storage admission; late canonical attachment never reopens stopped projections |
| `MemoryV2+Spotlight.swift` | Canonical generation-proven rebuild shared by launch and repair, serialized with incremental Spotlight projections before taking its snapshot; isolated roots never alter system Spotlight |
| `MemoryV2+Storage.swift` | `MemoryStorage` actor; ordered USER.md, Spotlight and graph tails retained through actual exit; close/drain projections without cancelling canonical writes, retire replaced USER.md generators; scalar `statusCounts`, checked `curationPage` |
| `MemoryV2+SupersessionLint.swift` | `MemorySupersessionLint` and `MemoryFragmentUsageProtection`: disclosure-scoped retirement matching and protection for used memory fragments |
| `MemoryV2+TextClip.swift` | `MemoryTextClip`: shared sentence/word-safe display clipping and bounded memory text presentation |
| `MemoryV2+UserMDGen.swift` | `UserMDGenerator`: coalesced regeneration of derived USER.md at the active canonical persona root; SQLite remains truth |
| `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |
| `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `emitDiagnostic` |
| `MemoryV2Contracts.swift` | Current recall/proposal contracts; `MemoryPatchContract` preserves untrusted sources through rewrites and duplicate collapse |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for MemoryV2 diagnostics |
| `ReviewedMomentAcceptance.swift` | `ReviewedMomentAcceptance`: prepared moment wording and embedding admitted together by canonical transaction |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractEntities`, `taggedNameIsCredible` |
| `WordPieceTokenizer.swift` | `WordPieceTokenizer`: BERT/MiniLM vocabulary tokenization, greedy subwords and encoded token IDs |
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
| `DataRootLife.swift` | `DataRootLife`; one root life-id, created once when absent as their first life (`first`) and replaced by the restore intent's UUID; `life(of:)` reads a missing stamp as the first life, so an upgrade never reads as a restore; resumable owners stamp at beginning and admit only that life, projecting work from another life stopped with reason restored |
| `DerivedStateInvalidation.swift` | `DerivedStateInvalidationCenter`: post-write canonical-source invalidations and coalesced sink delivery; derived owners must reread truth |
| `LLMClient.swift` | `LLMClient` and shared message/tool/stream contracts: task-local call context, lifecycle evidence, deadlines and failure/effect vocabulary |
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `LatestRead.swift` | `LatestRead`: one owner's published snapshot; a read returns what it read, and publication moves forward only (a read or write that started later is never replaced by one that started earlier); `refreshDraft` instead applies only the newest-started form refresh, with field-edit protection owned by its caller; cancelled reads apply nothing and do not advance the published boundary; construction is nonisolated for facade assembly, while read/refreshDraft/write remain MainActor-isolated |
| `LifecyclePrimitives.swift` | `ScopedWaiter`, `OnceByKey` and `BoundedWait`: lifecycle-safe waiter release, keyed single execution and bounded waits |
| `MemoryCandidateQuality.swift` | `MemoryCandidateQuality`: shared durable-candidate hygiene and explicit incomplete-fragment rejection reasons |
| `MemoryDisplayText.swift` | `MemoryDisplayText`: canonical memory text rendering and USER.md coverage/join keys, preserving date-critical kinds |
| `ModuleLogging.swift` | `ModuleLog`: shared formatted, credential-redacted public diagnostics with each module's existing category |
| `MotorActionReadModel.swift` | `MotorActionReadModel`: shared payload-free phase, deadline and verification language; canonical domain reducers retain authority |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | process-cached current identity, injectable `from`, `writeLaunchStamp` |
| `NativeLoopbackListenerParameters.swift` | Loopback listener construction, generation and rebind lifecycle; one retained, cancellable two-second port diagnostic, with admission held through process exit and stale generations excluded from publication |
| `NativeTimestampFormat.swift` | `NativeTimestampFormat` enum; `flooredOptionalMicrosecondUTCOffset`; `calendarDay` in the Mac's autoupdating current time zone |
| `OrganPulse.swift` | `OrganPulse`: shared proof-of-pass values and installed recording hook; BackgroundLoops owns durable pulse records |
| `PersonOnlyWindows.swift` | `PersonOnlyWindows`: registered person-only window exclusion, input/pointer coordination and step-aside hooks without app dependencies |
| `ProcessTreeReaper.swift` | `ProcessTreeReaper`: process-start-identity snapshots and leaf-first subprocess termination; reused PIDs never receive stale signals |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `RecallLexicalNormalization.swift` | `RecallLexicalNormalization`: shared retrieval-only inflections and question-word vocabulary; canonical text and authority remain verbatim |
| `SSEEventStream.swift` | Shared SSE framing and `ProviderStreamContext`; transport opening and activity for every event/comment; optional round-scoped diagnostic event capture before provider decoding |
| `Settle.swift` | `settle`: the Stop law's one primitive; settlement runs outside the caller's cancellation, exactly once (docs/STOP.md) |
| `TimeoutRace.swift` | `TimeoutRaceLatch` and `raceAgainstTimeout`: first-wins operation/deadline coordination with explicit parent-cancellation outcome |
| `TurnDeadline.swift` | `TurnDeadline` class; shared active-work deadline pauses while awaiting a person |
| `TurnPresentation.swift` | `TurnPresentationReducer`: sanitized bounded turn lifecycle/activity projection; no tool arguments, payloads or hidden reasoning |
| `TurnSecretRedactor.swift` | `TurnSecretRedactor`: credential-name/token recognition and shared presentation/trace scrubbing; callers own size bounds |
| `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |
| `UserMDAutogenMarkers.swift` | `UserMDAutogenMarkers`: one USER.md section marker vocabulary and shared prompt/pinned-section handling |
| `UserMessageIntentSignals.swift` | `UserMessageIntentSignals`: pure lexical context/tool allocation signals and control-handoff recognition; never effect authority |
| `VectorMath.swift` | `VectorMath.cosine`: shared finite-checked Double cosine core for recall, consolidation and context |
| `WorkshopWireVocabulary.swift` | Workshop wire vocabularies: canonical surface/event/approval/inbox/environment spelling and centralized legacy translation |
<!-- END GENERATED BLUEPRINT -->

### Onboarding

Directory: `Modules/NativeAgentCore/Sources/Onboarding/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Onboarding/ -->
| File | Owns |
|---|---|
| `Onboarding.swift` | Typed onboarding client; durable completion/reset transactions, profile repair and recovery verdicts; profile preparation/commits use PersonaEngine, USER commits use UserMDGenerator; starter notes append through the persona document owner's lock |
| `PersonaTemplates.swift` | `PersonaTemplates` enum; `generate` |
<!-- END GENERATED BLUEPRINT -->

### AuthoredCapabilities

Directory: `Modules/NativeAgentCore/Sources/AuthoredCapabilities/`

Depends on NativeAgentCore support, PersistenceCore durable I/O and Experiences for source-fault repair obligations from live part runs carrying input; file-backed sense completions record outcomes without this obligation; owns the authored part contract without importing feature executors.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/AuthoredCapabilities/ -->
| File | Owns |
|---|---|
| `AbilityStore.swift` | The bundled seed catalog owns shipped-id and native- reservations for new parts in Parts.save and for installation; all-kind registry rows carry kind and version, including recordless turns, and senses expose record-owned version/reach/mode without ability wake/residency; one throwing partHeader normalizer/catalog for tools, skills, senses and reserved turns: reach/wake/face/resident/learned/choices, the `signalled` notification sources post and each part's `wakes`, legacy permissions projection and one 512 KB source limit; invocation-scoped file reach binds declared read/write approval to the part's own data root; current/prev/next lifecycle, shared ID normalization and all-slot name/identity occupancy for create-only saves and pack preflight, permitting same-install same-id replacements, atomic current-only seed installation under the store lock with any existing id/slot skipped, notebook schema and read/write/delete under the same lock (16 KiB/value, 64 KiB/notebook), independent versioned outcomes/read counts in state.json with exact-file read recovery and the captured restore digest retained in the remedy instruction, including native/bundled reads without executable files, without source rewrites, bounded recent exact-input/reached-call outcomes with redacted input previews and version run totals projected as learned.use from ordinary gated execution (no rehearsal/preview/replay competence credit), scoped rehearsal evidence distinguished from bundled admission and projected separately for current and proposed versions, operation-scoped repair owed through Experiences with source-filled native authoring calls for their abilities/senses, source reads and a person-directed defect for reserved turns, and no automatic swap-back; damaged-source recovery preserves fileRepairInstruction; unique ids, owner-off/peer-authoring guards, change invalidation and read/files/states perform verified on-disk migration of the three old stores into one retained .old-layout archive; `restoredLegacyCarry` prepares older-backup parts plus readable current uncarried kinds/accounting before installation, returning omissions for the sealed restore receipt; `installRestoredLegacy` installs that selection, or the backup alone when carry is lost, and archives the legacy sources without rereading current accounting |
| `PartCall.swift` | Re-exports the shared Mac/iPhone part result and face wire types; strict face shape and identifier validation excludes native availability, failure and owed fields from editable content |
| `PartFaces.swift` | `PartFaces`: native source-change projection owner; frozen packets and source epochs, version/epoch cache, canonical ability-change invalidation, per-part LatestRead publication; cancelled reads publish and cache nothing, preserving the last snapshot and allowing another ask at the same version/epoch; observable and Codable typed rows for Mac/phone consumers; `PartFaceSnapshot` keeps native unavailable/failed/owed beside authored content; synchronous stop retires publication/observation and cancels refreshes before returning their settlement drain (close awaits it); source callers retain and cancel their own reads; no view executes JS, no domain truth store |
| `SkillRunContext.swift` | Singular authored-run TaskLocals, part identity, file-write notifications, a wake's model admitted at its first thought, and hand-back refusal contract |
<!-- END GENERATED BLUEPRINT -->

### PersistenceCore

Directory: `Modules/NativeAgentCore/Sources/PersistenceCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersistenceCore/ -->
| File | Owns |
|---|---|
| `CheckedFixedSizeSecretFile.swift` | `CheckedFixedSizeSecretFile`: exact regular 0600 secret bytes, missing-only creation and byte-preserving invalid-state failure; caller owns authority lifecycle |
| `ConnectorActionReceipt.swift` | Shared connector action/Slack HTTP receipt schema, path and capped append owner; producer timestamps and outputs retained; local/off-disk backup, credential-free phone health projection, no production export; PrivacyMap/connectors |
| `ConnectorInputValue.swift` | Connector input scalars and secret-free TransportAllowlist: canonical Slack auth.json policy only, strict alias unions within that object and Telegram integer IDs shared by ingress and SecurityCenter; unreadable or malformed saved policy throws |
| `ConnectorOAuthRegistry.swift` | Sole checked connector registry reader/schema and durable publication owner (`writeRegistry`), including bootstrap and Slack recovery; canonical IDs and `connectionDecision`. A connection decision is recorded only by the person's own connect or disconnect; seeds, first reads and migrations are undecided, and missing decision fields read as undecided without inferring from enabled/authState. `permitsCredentialMigration` reads only that decision: connected or undecided may migrate; a recorded person-disconnect never does. Malformed authority throws |
| `DeviceSecretKeychain.swift` | Verified device-only Keychain secret bytes and a service's account list; callers own locked reference commits and migration |
| `DiskStorageOwner.swift` | `DiskStorageOwner`: owner retention plans and execution, contained identity-checked moves to Trash and logical-byte outcomes; no history deletion |
| `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy`; shared trace envelope/retention and native-power browser/action receipt retention; local backup/export/raw phone exclusions, selected telemetry projection and Traces privacy scope; appendPathOwnedJSONL is the existing mutation owner |
| `FileChangeEvents.swift` | `FileChangeEvents`: bounded cancellable async vnode event bridge with one initial edge only after successful arming |
| `FileChangeWatcher.swift` | `FileChangeWatcher`: pooled file/directory vnode subscriptions, ancestor watches and replacement rearming with serialized teardown |
| `FileLockSidecarLifecycle.swift` | `FileLockSidecarLifecycle`: bounded locked reaping of old regular orphan sidecars; live/fresh/link sidecars stay untouched |
| `HomePath.swift` | `HomePath.expand`: expands only the current user's home shorthand, leaving named-user paths unchanged |
| `InstallPaths.swift` | Install-owned paths, public release preparation and login-item location admission |
| `JSONLRetention.swift` | SwiftNativePersistenceCore owns the activity event envelope, path and append; producers preserve redacted values, IDs and timestamps; JSONLCapCheckCounter owns cap-check cadence |
| `JSONValue.swift` | `JSONValue` enum; `ToolSchema` shared object/string/boolean/integer/enum/parameter constructors; shared schema checker for app arguments, Workshop and owned-code model replies (whole-tree preflight of enforced keywords, unknown keywords ignored, caller-owned error formatting); `fromEncodable`, `mapStrings`, `decodedExactly` (a store's one shape check, naming the field), `digest`, `differences`; `JSONRow` checked row reads for typed owner records |
| `Keyring.swift` | `Keyring` enum: the one keyring's storage — a secret by their name in one Keychain service with the hosts and programs the person granted it for, its renewal and when it was granted; `kept`, every entry by name; `{{secret:<name>}}` names; a program grant is the executable's path and code identity; no network |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for PersistenceCore diagnostics |
| `NativeActionRouteSupport.swift` | `NativeActionRouteSupport` enum; `jsonValueBody`, `notImplemented` |
| `NativeAgentWorkspaceRoot.swift` | Canonical workspace root; `resolveFileMutationPath` is the shared byte-preserving path resolver for file mutation execution and containment, including the workspace base for relative names |
| `NativePrivateFile.swift` | `NativePrivateFile.write`: atomic private-file replacement with 0600 at creation, without a chmod exposure window |
| `OncePerPeriodReservation.swift` | `OncePerPeriodReservation`: locked durable periodic admission and stamp-specific restoration of a failed reservation |
| `PersistenceCore+FileLock.swift` | `FileLockScope`, `CredentialFileLock` and persistence lock support: current-task lock ownership, bounded acquisition and sidecar identity checks |
| `PersistenceCore.swift` | Shared JSONValue primitive accessors with explicit numeric coercion/finite policy; JSON/JSONL atomic/durable persistence, strict UTF-8 physical-line tails with rejected-row accounting and directory sync; CapabilityLifecycle guards ability changes and reconciles owner-off attribution; VerifiedPath owns descriptor-relative IO and transfers |
| `PersistenceDataRoot.swift` | `ResolvedDataRootCache` class; `resolve` |
| `RegistryTimestampSortKey.swift` | `RegistryTimestampSortKey` enum; `sortKey` |
| `Repair.swift` | Shared repair, reconciliation, terminal and person-decision shapes; ToolFailureError.call builds native calls, while fileRepairInstruction owns byte-preserving person recovery prose for damaged files, without executable coding requests |
| `SnapshotTailOpLog.swift` | `SnapshotTailOpLog`: shared base-plus-tail replay, feed integrity and bounded compaction bookkeeping |
| `StoreChangeBus.swift` | `StoreChangeBus`: process-local multicast store invalidations; files remain authoritative |
| `StoreReloadDebouncer.swift` | `StoreReloadDebouncer`: visibility-gated trailing-edge reloads with one in flight; exclusion lasts until actual reload exit |
| `VolumeIO.swift` | The one owner of blocking file work that can touch a File Provider or network volume (iCloud Drive): one serial queue off the cooperative pool, awaited by its callers |
<!-- END GENERATED BLUEPRINT -->

### Experiences

Directory: `Modules/NativeAgentCore/Sources/Experiences/`

Depends only on GRDB, so every owner of a happening can write it ([EXPERIENCE](EXPERIENCE.md)).

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Experiences/ -->
| File | Owns |
|---|---|
| `Experience.swift` | `ExperienceStore`, the append-only owner per data root over `experiences/experiences.sqlite`; `begin`, `append`, `experience`, `open`, indexed open/recent `projection` and commit-fed `changes`. Shared `Experience`/`ObligationPhase` live in NativeAgentShared. Recording stays off reply paths; projection drains queued writes and reports persistence gaps; a write the law refuses is logged and never poisons reads. Turn owners record answer lifetimes and recover saved-answer settlements; conversation and shelf owners publish peer obligations and completed run identities |
| `Flow.swift` | `Flow`: scope-ordered open, stopped, finished and dropped helpers over ExperienceStore; unfinished runs owe finish, with position-prefixed landed digests and references to their owners' raw records |
| `Owed.swift` | `Owed`: what they owes or is owed under the id its owner hands their (a reply's delivery id, a card's `interaction:<id>`), born owing one key and moved only by that owner at its persistence boundary, so desk.wait and repair.let_go read one experience |
| `RepairOwed.swift` | `RepairOwed`: experience-backed repair claims and settlement; retries, restarts and unrelated successes cannot settle another operation's debt |
<!-- END GENERATED BLUEPRINT -->

### PersonaEngine

Built-in skill guidance inventory and display models live with the persona;
they read persona/skills/bodies and do not execute guidance.

Directory: `Modules/NativeAgentCore/Sources/PersonaEngine/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PersonaEngine/ -->
| File | Owns |
|---|---|
| `InstalledSkillInventory.swift` | Built-in guidance inventory, matching and body reads shared by Parts, Mac and phone; each checked entry carries its readme into source/revision and UI detail without a second body read |
| `NativeAgentPublicSafety.swift` | `NativeAgentPublicSafety`: checked onboarding completion/legacy anchors and neutral organism admission before resident cognition wakes |
| `PersonaCompiler+Normalization.swift` | `PersonaCompiler`: `normalize` |
| `PersonaEngine+Compiler.swift` | `PersonaCompiler`: `compile`, `fingerprint`, `renderPrompt`; batched context surfaces share canonical persona documents and identity, with separate surface overrides; USER core projection |
| `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`: shared document-kind normalization and selection, locked persona mutations and private backups; ordinary persona mutations; skill-specific aliases are retired |
| `PersonaEngine+Writes.swift` | `SwiftNativePersonaEngine`: profile schema preparation, including onboarding, and sole profile commit owner; fixed document specs and guarded writes; append reads current content under the write lock with the editor's cap and backup policy |
| `PersonaEngine.swift` | `SwiftNativePersonaEngine`: shared persona-document reads and GROWTH episodic-log filtering; `PersonaSelection`: installation-wide selection for every door |
| `Skills.swift` | `SkillRecord`, `SkillRegistryEntry`: built-in guidance rows as the Skills page and phone snapshot carry them |
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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Procedures/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Procedures diagnostics |
| `ProcedureArtifactStore.swift` | `ProcedureArtifactStore` actor; artifact installation and invocation admission/receipts; explicit backup/export/sync decisions and privacy-map coverage; all store instances share one coalesced retention flight per canonical root, opened and terminally closed/drained by engine lifecycle, with cancellation checked before deletion; the invocation-ledger file lock excludes reference publication from retention eligibility/deletion across store instances; automatic admission takes it before the active-pointer lock |
| `ProcedureCompilation.swift` | `ProcedureTerminalClass` enum |
| `ProcedureExactActivation.swift` | Exact activation manifests and active pointers; artifact revalidation and pointer publication share retention's invocation-ledger lock, acquired before the pointer lock |
| `ProcedureExactActivationExecutor.swift` | `ProcedureExactActivationExecutor` enum; `activate` |
| `ProcedureReplay.swift` | replay status/count and manual dry-run eligibility; canonical executor retains dispatch |
<!-- END GENERATED BLUEPRINT -->

### ProviderRouting

Directory: `Modules/NativeAgentCore/Sources/ProviderRouting/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ProviderRouting/ -->
| File | Owns |
|---|---|
| `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |
| `ChatCompletionsStreamDecoder.swift` | `ChatCompletionsStreamDecoder`: shared SSE content/reasoning/tool fragments, usage and root errors; terminal/tool alignment validation preserves provider failures |
| `ChatGPTAccountModelRefresh.swift` | `ChatGPTAccountModelRefresh`: account-scoped UI/sign-in model discovery and checked cache publication outside provider dispatch |
| `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog` enum; `load`, `signedCacheLists`; one decoded catalog for account matching and separate Codex/OAuth projections, invalidated by file attributes with auth identity checked on selection; a cache read fault owes repair under `codex.model_catalog:<file path>` with the file as owner; a later successful read settles it |
| `FirstPartyModelCatalog.swift` | `FirstPartyModelCatalog`: shared first-party model capabilities, route controls and image/speech choices for inspection, pickers and request serialization |
| `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`; successful/failed call receipts with purpose, timing, provider identity and redacted underlying failure detail; memory, digest and probe telemetry retain their own surfaces when routing inherits Chat |
| `LLMClient+AnthropicAdapter.swift` | `AnthropicAdapter`: Messages completion/stream transport, credential discovery, prompt blocks and thinking/tool wire controls |
| `LLMClient+AnthropicNativeTools.swift` | `AnthropicAdapter`: buffered JSON and SSE both open through `ProviderWire`; native-tool stream decoding commits explicit object input at content-block close; empty-input candidates and later blocks wait in wire order for the terminal verdict; interruptions discard unconfirmed empty candidates and release explicit calls, retaining thinking replay; shared Anthropic event type, wire errors, usage and stop-reason accumulation |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthDirectAdapter`: `requestMaxTokens`, `clearAtBeta`, `installedClaudeCodeVersion`; indexed content-block validation shared by OAuth text and Anthropic native-tool streams, keeping text/thinking/signature/tool deltas on their own blocks |
| `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthDirectAdapter`: `ephemeralCacheControl`, `currentTurnUserIndex`, `currentBoundaryIndex` |
| `LLMClient+CodexAdapter.swift` | `CodexAdapter`: streaming and buffered Codex runners; pins the shared credential resolver's path for account controls, child-home binding and preparation; never lets the CLI select another credential; NativeAgentCore's ProcessPipeDrain owns shared nonblocking pipe capture without an executor dependency |
| `LLMClient+MoonshotAdapter.swift` | `MoonshotAdapter`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |
| `LLMClient+OpenAIAdapter.swift` | `OpenAIAdapter`: API-key Responses/Chat Completions selection, message/tool encoding and bounded completion/stream transport |
| `LLMClient+OpenAIOAuthCredentials.swift` | `OpenAIOAuthDirectAdapter.preferredAuthPath`: the single ChatGPT/Codex credential-path resolver for readiness, all adapters, maintenance, child execution and explicit CLI inspection; app-owned writes and root-consented CLI adoption share this owner; child homes derive from an already-selected credential; hasAccessToken checks presence only, not execution readiness |
| `LLMClient+OpenAIOAuthDirectAdapter.swift` | `CodexOAuthAccessContext` struct |
| `LLMClient+OpenAIResponsesDecoding.swift` | `OpenAIOAuthDirectAdapter`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |
| `LLMClient+OpenRouterAdapter.swift` | `OpenRouterAdapter`: namespaced model routing, reasoning controls and authenticated OpenRouter completion/stream transport |
| `LLMClient+Real.swift` | `SwiftNativeLLMClient` shared routing and non-streaming execution envelope, stream guard admission before adapter creation, and failed-call telemetry before error normalization |
| `LLMClient+XAIOAuthDirectAdapter.swift` | `XAIOAuthDirectAdapter`: app-owned OAuth token lifecycle and Grok completion/stream transport with shared refresh serialization |
| `LLMProviderStatusFeed.swift` | live provider status feed; byte-checked receipt decode reuse, verdict age checked at use |
| `ModelCatalogTTLCache.swift` | shared live fetch and TTL/backoff state machine; only the current per-path refresh with unchanged credentials commits cache/backoff; `ModelCatalogDecodeCache` memoizes each provider's decoded rows and authority stamps by canonical file path and mtime |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for ProviderRouting diagnostics |
| `MoonshotModelCatalog.swift` | `MoonshotModelCatalog`: authenticated model parsing/capabilities and checked offline cache, using shared TTL state machinery |
| `NativeOAuthCallbackPolicy.swift` | Shared callback validation with exactly one state and caller-specific messages; handleCallbackURL, validateCallback, parseCallback |
| `NativeOAuthCallbackRegistry.swift` | `PendingCallbacks` class; `register`, `forget` |
| `NativeOAuthFlow+Configs.swift` | ProviderOAuthConfig owns provider client identities and token endpoints; buildAuthURL, exchangeCode |
| `NativeOAuthFlow+Helpers.swift` | PKCE and NativeOAuthSupport.post, the redirect-refusing transport for all token grants; adapters retain sessions, encoding, 20/30-second request bounds and error classification; owned sessions and device polls have elapsed resource bounds. Device authorization polls at the server interval through expiry, denial or cancel |
| `NativeOAuthFlow+Keyring.swift` | `Keyring`: `granted`, `grant`, `forget`, `values` — grant, removal and renewal of one secret on its one queue of the refresh queue registry; a renewal commits only onto the entry it read, and a successful grant or removal voids sign-ins begun before it; `NativeOAuthFlow`: `grantSecret` — the person's grant of a keyring secret, pasted or by a sign-in run from parameters they supplied (PKCE, loopback redirect, token redeemed and kept, never shown) |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackTarget`, `callbackHasResult` |
| `NativeOAuthFlow+TokenStatus.swift` | Token clearing and badge projections of each adapter's credential verdict and effective expiry; Sendable sign-in/session-offer values travel in the checked provider snapshot; no independent readiness or credential-selection rules |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | `NativeOAuthFlow` enum; `validateSignInDestination`, `startOAuthFlow`, Anthropic setup-token normalization/admission/write |
| `NativeOAuthLoopbackCallbackServer.swift` | shared ChatGPT/xAI loopback callback socket lifecycle; one admitted wait (concurrent waits reject before installing cancellation or timeout), bounded blocking clients on Dispatch, protocol-specific response shape, state validation and exactly-once completion; browser opening stays in the owning session |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort` protocol; `runAuthSession`, `isCanceledLogin`; shared `makeLoopbackSession`, `openBrowser`, `runLoopbackAuthSession` defaults; `OAuthLoopbackSession` protocol |
| `OAuthContinuationGate.swift` | `OAuthContinuationGate` class; `install`, `resume` |
| `OAuthCredentialDecoding.swift` | Shared JWT payload and OAuth expiry decoding; `OAuthRefreshBinding`: account identity and refresh continuity |
| `OAuthCredentialHealth.swift` | Secret-free maintenance projection of adapter-owned expiry, refresh binding and readiness verdicts |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` (per credential path or key) |
| `OpenAIExecutionControls.swift` | `OpenAIExecutionControls`: transport-specific catalog capability admission and reasoning/service-tier wire serialization |
| `OpenRouterModelCatalog.swift` | `OpenRouterModelCatalog`: live-backed model availability, capability parsing and checked catalog cache through shared TTL machinery |
| `ProviderAPIKeyStore.swift` | Provider reference/string validation; byte insertion, readback and deletion delegate to DeviceSecretKeychain |
| `ProviderConnectionProbe.swift` | provider connection probes |
| `ProviderErrorBodyDrain.swift` | `ProviderErrorBodyDrain`: bounded exact-request diagnostic reads with idle deadlines; adapters retain HTTP verdicts and cancellation stays cancellation |
| `ProviderFailure.swift` | Typed provider failure classification and `Diagnostic` wrapper preserving redacted wire evidence and the owner's `ToolFailureError` repair through normalization; `repair` decides once whether a failed call owes repair (sign-in, account, model choice) or is a correction that owes nothing |
| `ProviderReasoningSelection.swift` | provider reasoning selection |
| `ProviderRecoveryPolicy.swift` | Shared failure classification and helper-start backoff; surfaces never replay a provider call (delivery redials live in ProviderStreamGuard's `ProviderWire`) |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting` actor; `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`, `adoptConnectedProvider`, `catalogContextLength`, `routingRepairInput`, `reconstructRouting`; effort-only group rows inherit Chat's current model/account without seeding other controls; provider interpretation, byte-checked picker/configuration decode reuse with fresh credential/readiness checks; checked picker revisions come from both files under the transaction lock and travel with phone snapshots/readbacks, recoverable group writes/adoption and byte-preserving explicit routing reconstruction |
| `ProviderRoutingContracts.swift` | `ProviderRoutingSnapshot` carries its checked source revision and owns modelOverrideSurfaces independently of effort/Fast for settings and UI inheritance reads; `ProviderRoutingProtocol`: `listProviders`, `getProvider`, `configureProvider` |
| `ProviderSignInHandoff.swift` | provider sign-in handoff state |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderStreamGuard.swift` | Configured idle/wall cuts on wire activity for every provider stream; the request registers its progress wake before reading and waits only for progress or its next deadline; terminal state closes activity admission before canceling forwarding/deadline tasks, retaining their handles through actual exit without joining the producer; typed no-reply failure and uncapped model URLSession; the learned first-output deadline bounds only a wire with nothing on it; `ProviderWire` opens every provider HTTP stream and owns delivery: until any of the answer arrives, a lost wire, a sent request with no response head in 20 s (plus upload time), an answerless idle or first-output cut, or a provider's busy reply (overloaded, 5xx, a rate limit naming a wait up to 30 s) dials again, up to 10 dials with 0.5-8 s jittered backoff inside the call's wall, each redial first waiting for the Mac's network path (Stop and the wall end the wait); refusals, sign-in, context and long quota waits never redial, CLI wires never do, and the final failure says how many tries it took; wall-off streams forward without a deadline worker |
| `ProviderToolCapability.swift` | `ProviderToolCapability`: adapter-declared tool/image transport capabilities independent of model-name inference |
| `ProviderTurnChoice+ModelSelection.swift` | provider turn model selection |
| `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |
| `ProviderVitalsSensor.swift` | `ProviderVitalsSensor`: passive lifecycle-derived latency/error bands, first-output evidence and persisted bounded health state |
| `RequestPrefixReceipt.swift` | `RequestPrefixReceipt`: hashes exact encoded request byte slices without reserializing tools or exposing request text |
| `RunawayOutputDetector.swift` | `RunawayOutputDetector`: streamed tool/prose boundaries, complete-call retention and read/action classification through parser/registry owners |
| `SwiftCodexDeviceLoginManager.swift` | `SwiftCodexDeviceLoginManager` enum; CLI executable readiness |
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
| `Research+SearchFetch.swift` | SwiftNativeResearchClient: checkedSearxngBaseURL is the search configuration reader used by search, Settings, connector status and Doctor; localServerIsDown, search returns results without a duplicate receipt file; fetchURL retains source receipts with explicit reader locators |
| `Research+WebSearch.swift` | `WebSearchRoutes`: SearXNG results or its plain failure; without SearXNG, `browser_search` (Chrome or their own browser); actual-route receipts and untrusted web-content labels |
| `Research.swift` | `SwiftNativeResearchClient` and research values: SearXNG discovery/search, fetched-source receipts and persisted lab run contracts |
| `ResearchTextDecoding.swift` | `ResearchTextDecoding`: response charset parsing outside quoted parameters and strict handling of incomplete terminal UTF-8 |
| `ResearchTransports.swift` | `URLSessionResearchHTTPClient.getBounded`; Docker discovery/start retains daemon readiness polling at 3-second intervals within its 90-second window, with no confirmed push replacement; subprocesses delegate to `MacControl.SystemProcessAdapter` with full output capture |
<!-- END GENERATED BLUEPRINT -->

### SchedulerExecution

Directory: `Modules/NativeAgentCore/Sources/SchedulerExecution/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SchedulerExecution/ -->
| File | Owns |
|---|---|
| `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |
| `SchedulerDueJobRunner+CycleHelpers.swift` | `SchedulerDueJobRunner`: `pruneRetiredRows`, `nextEpoch`, `containsLastRunToday`; dream/REM diary and inbox helpers |
| `SchedulerDueJobRunner+DreamCommands.swift` | canonical recurring-dream command selection and job receipts |
| `SchedulerDueJobRunner+Execution.swift` | `SchedulerDueJobRunner`: `execute` (a `part` job fires its part's `schedule:` signal), `channelIsSwitchedOn`, `disabledDreamResult` |
| `SchedulerDueJobRunner+Persistence.swift` | `SchedulerDueJobRunner`: execution-result adaptation to canonical scheduler settlement; `appendActivity` |
| `SchedulerDueJobRunner+ProactiveScan.swift` | `SchedulerDueJobRunner`: `surfaceProactiveScan` |
| `SchedulerDueJobRunner+Selection.swift` | `SchedulerDueJobRunner`: `nextMeaningfulDeadline`, `claimDueJob`, `dueJobs`, `ensureDefaultCycleJobs`; default cycle jobs and one `part` job per part and `schedule:` wake |
| `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`: `jobTimeoutSeconds`, `executeWithTimeout` |
| `SchedulerDueJobRunner.swift` | `SchedulerDueJobRunner` actor; `runDueJobs`; reads canonical job rows through `SchedulerJobs`; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `sendTelegramMessage` |
<!-- END GENERATED BLUEPRINT -->

### Senses

Directory: `Modules/NativeAgentCore/Sources/Senses/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/Senses/ !Modules/NativeAgentCore/Sources/Senses/Owned*.swift !Modules/NativeAgentCore/Sources/Senses/SensesContract.swift !Modules/NativeAgentCore/Sources/Senses/Helper*.swift !Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift !Modules/NativeAgentCore/Sources/Senses/SenseScreenThings.swift !Modules/NativeAgentCore/Sources/Senses/SenseTurnReads.swift -->
| File | Owns |
|---|---|
| `BuiltInSenses.swift` | Bundle-owned native adapters and JavaScript defaults; file overrides win and accounting lives in AbilityStore state |
| `ExistingCornersSourceProvider.swift` | `ExistingCornersSourceProvider`: contract ports for today's raw material and native pages; packageManifest owns package membership, symlink/type rejection and the 8,000 total-member bound, including watched directories, for watching and archive delivery; `SenseNativePages` owns readable Chrome places, bounded conversation/tab-scoped private continuation bindings, structural things/verbs and existing raw UTF-8 windows |
| `FileSenseRegistry+Sharing.swift` | Approval-gated portable code/record export |
| `FileSenseRegistry+Storage.swift` | Registry validation, candidate/version-folder source resolution, bounded code manifests and path/symlink fences |
| `FileSenseRegistry.swift` | Sense adapter to AbilityStore files and state; successful reads delegate versioned evidence to AbilityStore; bundle defaults, corner lookup, keep/restore through the shared publication authority gate with bundled materialization deferred to the admitted save, previous-version swap, final override drop and separate owner-off preservation; store-locked, root-scoped helper selection identities exclude read bookkeeping and distinguish each selected lifetime without changing saved records |
<!-- END GENERATED BLUEPRINT -->

### SlackBot

Directory: `Modules/NativeAgentCore/Sources/SlackBot/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SlackBot/ -->
| File | Owns |
|---|---|
| `SlackCredentials.swift` | Slack tokens/grants in Keychain; canonical connectors/slack/auth.json validation, save/recovery, toggle and revoke; metadata import and token migration share registry → canonical locks and PersistenceCore's connectionDecision field. Connected or undecided may migrate; only a recorded person-disconnect retires oauth_tokens/slack.json without importing metadata or tokens, until explicit reconnect. Seeds, first reads and migrations are undecided; enabled/authState never record a choice. Eligible absent canonical auth imports checked legacy metadata with verified publication before source removal; runtime policy reads canonical metadata only. File tokens migrate through verified Keychain writes, canonical fields winning over legacy input; a committed grant stays authoritative. Retained connectors/slack/oauth_app.json has no reader; coverage decisions live here |
| `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; socket/history/recovery admission, retains accepted handler tasks until actual exit with one active handler per event in the process (across loop replacements), and terminal delivery truth; `path`, `recoverySummary`, `failedReplyClaims`, `confirmReplyPart` retain confirmed text/image progress across holds; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | Socket configuration and throwing ingress/toggle readers consume TransportAllowlist's checked Slack metadata and strict string-only union; UI callers retain unavailable authority as a failure |
| `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: `classifySessionClosure`, `disconnectDisposition`, `classifyReceiveLoopReturn` |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop` struct; `tick`, `tickOutcome`; session cancellation closes pending socket receives before draining passive work, while accepted human handlers continue under the journal. Reconnect gap fill, unhealthy-socket history polling and the healthy-socket missed-event backstop retain their existing intervals; history waits use the next poll deadline rather than sampling local state |
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
| `BotDefinitionStore.swift` | Definition persistence and editor model/budget/schedule/event admission; launch leaves saved definitions and model choices untouched, with no migration marker |
| `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |
| `BotEventTriggers.swift` | `BotEventRouter` and `BotEventStore`: Slack event matching/admission and durable wake records from already received events |
| `BotHeadline.swift` | `BotHeadline` enum; `make` |
| `BotLegacyHistory.swift` | `ShelfStore`: `legacyHistory` |
| `BotRunQueue.swift` | `BotRunQueue` struct; `enqueue`, `presence` |
| `BotRunner.swift` | `BotRunner` actor; `run`, `ask` |
| `BotRunnerDeadline.swift` | One helper seconds deadline is reported when crossed and never cancels its work; scheduled runs and direct conversations share it |
| `BotRunnerScheduler.swift` | `BotRunnerScheduler` actor; `effectiveSchedule` shares reconciled timing and admission with live deadlines; `savedDates` is editor-only reservation state |
| `BotTurnRunner.swift` | `BotTurnRunner` owns helper-only model/tool rounds over the helper transcript; injected wire codecs, gated dispatch and row writer reuse their existing owners; Stop saves partial output through settle |
| `BotsShelfRead.swift` | Shelf and Desk consume `BotRunnerScheduler.Projection`; one running/queued/model-choice/pause/run-status classification for Mac, quiet reads and iPhone; approval and run-feed read models |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for StandingBots diagnostics |
| `ShelfApprovalReconciliation.swift` | `ShelfStore` approval reconciliation: all shelf readers project canonical approval resolution without making shelf copies authoritative |
| `ShelfStore.swift` | `ShelfStore` struct; `append`, `settleApproval` |
| `StandingBotSchedule.swift` | `StandingBotSchedule` enum; `parse`, `words` |
| `StandingBotsDisk.swift` | `StandingBotsDisk` struct; `validatePath`, `locked` |
| `StandingBotsModels.swift` | Helper definitions own name, optional personality, job, output and provider/budget settings; cadence, run and shelf values |
<!-- END GENERATED BLUEPRINT -->

### Studio

Directory: `Modules/NativeAgentCore/Sources/Studio/`

Studio and its consumers use NativeTimestampFormat directly for pure timestamp
formatting/parsing; Studio has no clock-only dependency on Desk. Desk retains
its separate monotonic clock behavior.

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
| `StudioStore.swift` | Append-only journal and corrections, consult and honest-encounter truth; timestamps use NativeTimestampFormat directly; `encounterIntakePage` exposes bounded neutral consult/corrected-history facts with a shared content digest, refuses unreadable/incomplete history and changed pages; `namedEncounterIntake` validates editable `Resources/abilities/studio-intake.js` selection against native encounter truth, retaining no Swift ordering or invitation prose |
| `StudioWorkingShelf.swift` | `StudioWorkingShelf` struct; `decodeSlots`, `selections` |
<!-- END GENERATED BLUEPRINT -->

### SwarmRuns

Directory: `Modules/NativeAgentCore/Sources/SwarmRuns/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SwarmRuns/ -->
| File | Owns |
|---|---|
| `RunLedger.swift` | `RunLedger`: cross-surface completed-run summary |
| `SwarmExecutor.swift` | `SwiftNativeAgentSwarmExecutor`, `SwarmLiveBoard`: admission and worker execution; progress, terminal receipts and removal delegate to the shared runs owner; the originating app door calls `Resources/abilities/crew-instructions.js` through L0 `Parts.call` for worker briefs, synthesis messages and digest policy. Provider/model/tool access, concurrency, cancellation, character-safe retention, partial outcomes and receipts stay native; preparation failure is explicit and never runs old Swift policy, and settlement uses the prepared digest without starting JS after Stop |
| `SwarmRunsReader.swift` | `SwiftNativeSwarmRunsReader`: owns live-board and receipt storage and worker report IDs; one read-only recovery projection for crews, report inspection and the live board; inspection gives pending live workers their deterministic IDs and marks absent output unavailable, preserving strict terminal-report validation; durable receipts win, interrupted completion time stays unknown, and `SwarmCrew.liveness(of:)` classifies every crew view without promoting unknown to running or replaying work; its writer records recoveryObservedAt once when committing projected recovery before the next board write and removes it only after receipt durability |
<!-- END GENERATED BLUEPRINT -->

### SystemOps

Directory: `Modules/NativeAgentCore/Sources/SystemOps/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/SystemOps/ -->
| File | Owns |
|---|---|
| `SoftwareUpdateState.swift` | `SoftwareUpdateState` |
| `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |
| `SystemOps+CapabilityScoring.swift` | Capability scoring: shared keyword tokenization, context capability score components and bounded catalog selection |
| `SystemOps+Production.swift` | `SwiftNativeProductionExportsClient`: lossless production export registry reads and verification; no external status runtime |
| `SystemOps+RouterPlan.swift` | `SwiftNativeRouterPlanClient`: context capability route selection and policy projection for proposed next actions |
| `SystemOps+Types.swift` | `RoutePlanResult`, `IntentRoutePlan` and `SystemOpsError`: router plan/capability values and explicit SystemOps failures |
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
| `TelegramBot+Client.swift` | `SwiftNativeTelegramBot` client: status/test send, locked log clearing, long-poll accounting and shared slash dispatch |
| `TelegramBot+Completeness.swift` | `TelegramCommandRegistry` and completeness dependencies: slash parsing, provider/memory/restart ports and compatible model selection |
| `TelegramBot+Config.swift` | Saved shape validation, exact positive `voice_max_bytes` and TransportAllowlist's normalized integer IDs. Model/effort fields are legacy routing metadata; voice model metadata does not select recognition. Loads can remove retired credentials and migrate plaintext to Keychain. Conditional saves resolve kept tokens under the config lock and advance revisions, including disconnect |
| `TelegramBot+Models.swift` | Telegram wire models: typed API failures/results, sender/update/message/reply context and callback number decoding |
| `TelegramBot+Settings.swift` | Mobile operation prerequisites delegate saved field validation to `TelegramConfig.validateSavedConfiguration` |
| `TelegramChatHandling.swift` | Telegram chat contracts: progress/compaction sinks and attempt context carrying decoded sender identity separately from chat identity |
| `TelegramCommandMenu.swift` | `TelegramCommandMenuStatus` and `TelegramCommandMenuSync`: command-menu synchronization status contract |
| `TelegramCommandPolicy.swift` | telegram-commands.js projects menu/help over native command identities through L0 PartFaces and prepares memory reply words before the native write; reserved Stop/approval controls, canonical memory provenance, storage and awaited reply settlement remain native; menu synchronization keys on the selected part version |
| `TelegramMediaAttachment.swift` | `TelegramMediaDownloader`: two-stage file metadata/download admission with declared-size and actual-byte bounds |
| `TelegramModelSelectionHandling.swift` | `TelegramModelSelectionCallback`: provider/model selection callback encoding, key validation and action parsing |
| `TelegramOffsetCursor.swift` | `TelegramOffsetCursor`: monotonic durable getUpdates cursor; only missing state bootstraps and corrupt state cannot replay commands |
| `TelegramPartPolicy.swift` | Telegram's originating-door typed part calls use the canonical turn envelope, not a separate origin identity; telegram-model-picker.js interprets requests and draws menus; native code supplies checked choices, authenticates callback identities, validates returned buttons and retains canonical routing writes |
| `TelegramPollBackoff.swift` | `TelegramExponentialBackoff` and `TelegramErrorLog`: poll/menu failure cadence and locked bounded error-log rotation |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`; approval commands/callbacks use ApprovalInbox's life-bound continuation; the unstamped legacy continuation importer and its duplicate record are deleted |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`: `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand`; admitted commands/callbacks bind their Telegram surface, verified chat/sender and work identity in TurnEnvelope; Telegram has no command-signature scheme |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `chatAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+QueuedTurnControls.swift` | `TelegramPollLoop`: `handleQueuedTurnControlCallback` |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: sole checked state.json reader and mutation owner (`readState`, `mutateState`) for polling, migration and status consumers; only missing state is empty, and unreadable/non-object state fails with a dedicated telegram/state.json error and is never overwritten; migration locks only existing legacy storage; `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint`, `discoverSenders`; bounded setup pages persist in the canonical inbox before the bot cursor advances |
| `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody` |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramPollLoop.swift` | `TelegramPollLoop`: authenticated update intake, long-poll/chat turn lifecycle, saved reply recovery and checkpoint settlement |
| `TelegramProgressFace.swift` | Per-card source epoch and L0 PartFaces cache over sanitized canonical phase and timing; native availability/failure and output redaction; Telegram progress/status voice comes from telegram-progress.js, entered through the originating app door |
| `TelegramQueuedTurnControls.swift` | `TelegramQueuedTurnControlCallback`: queue control markup and callback decoding retaining forum-topic identity |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramSessionStore.swift` | `TelegramSessionStore`: locked session mint/adoption and delivery mapping; the shared anchor selects the owner's ordinary conversation |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger` actor; one owner per canonical ledger path across poll-loop replacements serializes `upsert` and `remove`; `TelegramTurnCardRestartRepairer` owns one repair task and shutdown |
| `TelegramTurnControls.swift` | `TelegramTurnControlCallback`: active-turn control markup and callback decoding retaining forum-topic identity |
| `TelegramTurnCoordinator.swift` | `TelegramTurnCoordinator`: active/queued turn ownership, durable update recovery exclusion, control claims and Stop/idle settlement |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias; canonical lifecycle adapter and native redaction; authored progress wording lives in telegram-progress.js |
| `TelegramTurnProgressCardDriver.swift` | `TelegramTurnProgressCardDriver`: one acknowledged lifecycle message per accepted turn; terminal repair belongs to the delivery ledger |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox` struct; `snapshots`, `ensurePending`, `failedReplyClaims`, `repair`; maintained claim index emits delivery invalidations and can be reconstructed from checked claims without changing phases; recovery exceptions retain a terminal quarantined claim and reason, excluded from automatic replay; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `TelegramVoiceTranscription.swift` | Telegram voice transcription and system-temp audio preparation/cleanup outside the data root; temporary audio is excluded from backup/export/phone sync and the PrivacyMap telegram tree |
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
| `ChatExportService.swift` | Snapshot-based Markdown rendering and atomic export write outside the main actor; completion follows the file write |
| `ChatSessionIndexFile.swift` | Canonical durable index writer and checked index schema and message-index, projection-generation, transcript-rewrite and retention-removal transactions; count/acknowledgment reads under index → transcript locks, retention on every message within the index transaction; `recordContinuityParticipant`, `recordConversationChange`; backup/export/sync/privacy decisions live here |
| `ChatSessionRecollections.swift` | Recollection row/coverage parsing, incremental scans and lock-protected timestamp formatters |
| `ChatSessionRetention.swift` | Canonical archive-index schema, manual archive transaction and durable append, shared by discovery/restoration; retention row removal delegates to ChatSessionIndexFile; locked pruning/enforcement snapshot, nonblocking transcript admission and exact acknowledged-version guard; retains all chat storage including the history index during disk cleanup |
| `ChatSessionScratch.swift` | `ChatSessionScratch` owns the session scratch JSON path, locked mutation and reads for Mac, Telegram and tools; off-disk backup only, no local backup/export/phone sync, inventoried under chat |
| `ConversationAnchor.swift` | `ConversationAnchor`: shared current-person conversation publication, protected sessions and adoption decisions across surfaces |
| `InlineInteractionCompactionRetention.swift` | `InlineInteractionCompactionRetention`: preserves live/suspended card handles during destructive transcript compaction |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for Transcripts diagnostics |
| `TranscriptRows.swift` | `ContactThread` owns transcript JSONL serialization, durable append and exact-byte replacement for chat, compaction and archive restoration; writes share the owner lock and compound caller lock boundaries; session-index mutate provides checked read/edit/commit. `read` shares tail/incremental byte reads; `Line` retains each row's stamp, words, speaker and answers-id; `project` is the shared presentation; displayed contact speech alone calls `consume` |
<!-- END GENERATED BLUEPRINT -->

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TriggerScheduler/ -->
| File | Owns |
|---|---|
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for TriggerScheduler diagnostics |
| `MorningBriefPart.swift` | Originating-door invocation and typed inactive-default/publication proposal wire; no briefing policy or model prompt |
| `MorningBriefSources.swift` | Frozen checked Desk, Workshop, inbox, session and bounded parsed/redacted worklog observations; only consumed fields enter the part, with native row validity and unavailable/empty distinctions; native local-day and date-label facts |
| `ScheduledJob.swift` | `ScheduledJob`: strict scheduler row decoding and projected civil next-run decoration while preserving claimed/retry instants |
| `SchedulerJobRuntime.swift` | `SchedulerJobRuntime`: shared civil schedule math and next occurrences; timezone changes cannot mint another civil occurrence |
| `SchedulerJobs.swift` | Canonical bounded jobs, life-stamped occurrence claims and settlement; other-life (no stamp = first life) claims read stopped/restored, stay disabled until explicit Resume starts fresh; claimDueJobs, settleOccurrence, pruneJobs and upsertDefaultCycleJob |
| `TriggerNotificationInbox.swift` | `TriggerNotificationInbox`: proactive identity matcher, checked locked mirror, `archiveSupersededMorningBriefs` |
| `TriggerScheduler.swift` | `SwiftNativeTriggerScheduler` actor; daily trigger admission uses one parser and the shared job normalizer's civil-minute math; retains catch-up and claims; morning brief content, card and defaults come from `Resources/abilities/native-morning-brief.js` through the engine's read-only originating part door; one config loader requests seed rows only for missing files, with native supported inbox kinds keeping saved controls and Workshop triggers independent of the brief part; native consent forces proposed default schedules off and preserves saved rows, occurrence identity and publication/delivery settlement; legacy inbox trigger inputs copy only to absent canonical files under the destination lock, leaving legacy files and their folder untouched; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
<!-- END GENERATED BLUEPRINT -->

### TrustCenter

Directory: `Modules/NativeAgentCore/Sources/TrustCenter/`

The workflow capability reader delegates checked schema and saved-row sorting
to `WorkflowOrchestration`, which also owns pack admission,
installation and removal; the capability reader does not write back.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TrustCenter/ -->
| File | Owns |
|---|---|
| `CapabilityCatalog.swift` | Capability sources, trust roots and pack installation receipts; catalog registry aggregation and mutation share `CapabilityCatalogStoreReader`'s checked object-array schema; workflow mutations delegate to WorkflowOrchestration. Installed items and receipts are authoritative, with no saved pack copy or `packPath`. Retained `catalog/packs` files are untouched orphans, excluded from local backup, export and phone sync; PrivacyMap lists their catalog folder. |
| `CapabilityPackParts.swift` | Capability-pack part admission, installation/removal and the save inversion bound by EngineRuntime; drafts retain pack origin and ToolExecution owns Parts.save |
| `CapabilityRecords+Dynamic.swift` | Read-only capability projections; workflow and catalog registries use their owners' checked schemas, never default over damaged saved state |
| `CapabilityTrust.swift` | `SwiftNativeCapabilityTrust`: checked capability trust/catalog values, scoring, evaluation and display projections |
| `ConnectorActionsRegistry.swift` | `ConnectorActionDescriptor` and `connectorActionDescriptors`: static connector action/schema inventory; live authentication decoration belongs elsewhere |
| `ConversationSurfaceProfile.swift` | `ConversationSurfaceProfile`: canonical origin normalization and remote/mobile classification; domain trust evidence stays with authority owners |
| `FeatureSurfaceRecords.swift` | `FeatureSurfaceRecord` and `featureSurfaceRecords`: feature surface manifest and the app actions that reach each surface |
| `MacControlGate.swift` | `MacControlGate`: effective Mac policy admission, private-path rules and admitted Full Mac handling through checked Trust |
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Peer-origin approval floors read only the declared call class; memory notes retain origin attribution without the former human-turn read-latch exception; ability changes/growth capture use CapabilityLifecycle's common write guard |
| `SavedTrustPolicyAuthority.swift` | `SavedTrustPolicyAuthority`: point-of-use saved policy reads through canonical shape/type validators; invalid authority never reads as configured |
| `SecurityCenter+FullMacPolicy.swift` | `SwiftNativeSecurityCenter`: `fullMacActive`, `fullMacYoloAuthority`, checked local `localFullMacYoloAdmitted`, `drivenAgentLaunchPermission` |
| `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: audit `redactValue`, using Privacy's canonical detection predicates |
| `SecurityCenter+JSONUtilities.swift` | Trust JSON primitives and workspace roots; byte-exact containment of resolved paths; transport policy decoding belongs to TransportAllowlist in PersistenceCore |
| `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |
| `SecurityCenter+PathPolicy.swift` | SecurityCenter owns byte-exact, component-wise containment of resolved absolute I/O paths for capability effects and Mac Control file admission; supported file mutations use NativeAgentWorkspaceRoot's execution resolver and relative base; unknown relative capability paths count as outside; `capabilityWritesOutsideAppData`, `pathIsInsideRoots`, `pathLikeStrings` |
| `SecurityCenter+ReceiptJSON.swift` | `SecurityToolEnvelope`: `toJSONValue` |
| `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `receiptSummary`, `isoTimestamp` |
| `SecurityCenter+ToolProfiles.swift` | canonicalToolRisk and declared effect projection; app-call read treatment delegates to PermissionLaw.toolClass, with argument policy and display severity |
| `SecurityCenter.swift` | Security decisions including permission-reset approval, audit JSONL, preserved pretrim archive and completion marker; local backup/export/phone exclusions and Security Audit privacy scope declared at the owner; status accepts the facade's checked policy generation without rereading it |
| `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner` actor; 32-byte regular 0600 signing authority with explicit backup/export/sync/privacy decisions; `canonicalBytes`, `compactCanonicalJSON`, read-only `existingSigningKey` for proof checks |
| `TrustAccessModeCapabilityCatalog+Read.swift` | Trust projections; effective Full Mac uses MacControlGate's admitted-call projection and PermissionLaw's Full Mac posture: no category approval prompts; saved restricted-mode approval metadata remains unchanged |
| `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog` enum; `normalizedMode`, `macControlPolicy` and Mac integration preset recognition |
| `TrustCenter+Autonomy.swift` | `PermissionLaw` enum: `posture`, `answer` (the one effective level), `judge`, `toolClass` (the one class resolution per call, read by authorization and scheduling), `reachesUser`, `reach(ofPermissions:)` (a part's declared permissions → theirs or their); `SwiftNativeTrustCenter.autonomyLevel` delegates to `PermissionLaw.answer` |
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
| `ProductionExport+Archive.swift` | Production archives consume PrivacyMap.productionExportRelativePaths; production, support and local backup input scopes are complete allowlists with unselected scopes excluded; the backup owner's recursive copier snapshots nested memory SQLite and omits lock/journal sidecars; canonical memory backup and persona root, credential exclusions with actual skipped paths; support bundles keep their separate selection and registry rows |
| `TrustBackupFoundation.swift` | `JSONDecoder`: extension |
| `TrustBackupHost.swift` | `TrustBackupHost`; running-bundle version factory |
| `TrustBackupModels.swift` | Backup records and restore results; requiresRestart distinguishes staged scopes/time from completed installation; notCarried records unreadable pieces, causes and losses |
| `TrustBackupPersistence.swift` | `TrustBackupPersistence`; before replacement the normal writer keeps a cataloged backup, reason before restore of the target name; backup failure replaces nothing. The retained backup supplies domain-owned readable continuity facts; the intent UUID becomes the new DataRootLife. Interrupted installation moves forward; backups/restore-receipt.json retains omissions. Temporary carry snapshot writer and per-kind checkpoint settlement are deleted. Snapshot integrity, lock-sidecar exclusion, JSONL writer locks, legacy ability preparation, transcript stamping and retention remain with their owners |
<!-- END GENERATED BLUEPRINT -->

### TurnTrace

Directory: `Modules/NativeAgentCore/Sources/TurnTrace/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/TurnTrace/ -->
| File | Owns |
|---|---|
| `AbandonedTurnReconciler.swift` | `TurnCheckpoint` retains its originating DataRootLife; reads project stopped/restored across lives, ordinary reconciliation settles through the Stop terminal record before retirement; independent checkpoint discovery, strict day validation, sweep-local terminal index and guarded retirement |
| `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook` enum; `arm`, `disarm`; retains sweep/resume jobs through exit and removes its observer at engine termination; excludes active turns and claims checkpoint resumes; terminal settlement awaits the installed anchor-intent adapter |
| `SessionIdentity.swift` | `ChatThreadKind` and session identity ledger: creation-time conversation kind, mint-site traces and source-flapping diagnostics |
| `TurnInspectorFeed.swift` | Engine-owned persisted today/yesterday evidence, exact file observation, `LatestRead` publication with checked read failures, grouped Mac cards, bounded phone summaries and immutable selected-date replay reads |
| `TurnSummaryRecord.swift` | `TurnSummaryRecord`, `TurnSummaryFile`, `TurnSummaryComputer`, `TurnSummarySource` |
| `TurnTrace.swift` | `TurnTraceEvent.isTerminalKind` and `TerminalState` own terminal kind/status vocabulary for chat and restore settlement; durable terminal delivery (its notification carries the trace day file, session, surface and the part whose run started the turn) before checkpoint retirement; bounded ingress/disk queues retain their sole workers through settlement, checked JSONL framing before kind/turn filtering including one exact day-file read per receipt lookup without a retention scan, and first-render correlation/publication; turn-bound calls, dispatches and plans persist only here, with standalone and unmatched historical ledger rows through `traceEvidence`, preserving historical outcomes when canonical status is absent; model-call rows retain the former ledger byte budget to preserve cache-prefix evidence |
| `TurnTraceReadProjection.swift` | `TurnTraceRow`, `TurnTraceGrouping`, `TurnTraceReplayReader`, `TurnInspectorGrouping`; PersistenceCore framing and TurnTraceEvent decoding shared by replay, recent, Doctor, recovery and guarded append reads; reports read coverage before window/kind policies; decoded terminal matching is independent of strict recovery coverage validation |
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

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/WorkshopExecution/ -->
| File | Owns |
|---|---|
| `ExecutionRecordFile.swift` | Canonical execution record/timeline I/O; active records from another DataRootLife or unstamped records read stopped with terminal_reason restored before every claim/recovery/update; no filesystem migration on read |
| `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for WorkshopExecution diagnostics |
| `WorkshopCanonicalProcedureExecutor.swift` | `WorkshopCompiledProcedureInvocationExecutor`: provider-free invocation with canonical queue admission inside the procedure ledger boundary |
| `WorkshopCompiledLocalFileCopyProcedure.swift` | `WorkshopCompiledProcedurePlanError` enum |
| `WorkshopCompiledProcedureRuntime.swift` | `WorkshopCompiledLocalFileCopyInvocation`: reviewed exact artifact invocation through Workshop queue; existing Trust/file dispatch retain authority |
| `WorkshopExecution+CausalTransitionEvidence.swift` | `SwiftNativeWorkshopRunner` causal/motor projections: payload-free canonical plan interpretation, provider accounting and evidence classes without fabricated execution |
| `WorkshopExecution+DeskTasks.swift` | `WorkshopDirectedTaskSubmitter` and Desk receipt bridge: Desk-first task identity with canonical Workshop execution and terminal evidence |
| `WorkshopExecution+Executor.swift` | `WorkshopExecutorLoop` dispatches execution-record transitions and blocked-step approval-claim clears with its own root through ExecutionRecordFile; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |
| `WorkshopExecution+OutcomeScoreboard.swift` | Native canonical receipt/record decoding, verification classification, timestamp interpretation and complete `weeklyOutcomeInput` evidence; missing stores are available empty, unreadable/incomplete sources throw. Editable `Resources/abilities/weekly-outcomes.js` owns local ISO-week grouping, statistics, trend thresholds and digest text; EngineLaunch invokes it through `ToolsFacade.withPartDoor` for maintenance, without activating schedules or a Swift policy substitute |
| `WorkshopExecution+OutcomeVerification.swift` | `WorkshopExecutorLoop`: `unmetSuccessCriterion`, `verifyCompletedOutcome` |
| `WorkshopExecution+PlannerLLM.swift` | `SwiftNativeWorkshopPlannerLLM`: checked executions routing admission, live catalog binding and provider planner calls |
| `WorkshopExecution+Runner.swift` | `SwiftNativeWorkshopRunner`: canonical execution.json ownership, safe execution IDs, queue admission, planning/cancel transitions and timeline receipts |
| `WorkshopExecution+Types.swift` | Workshop execution value contracts: specs/steps, verification/records, enqueue outcomes, argument validation and planner interface |
| `WorkshopExecutorContracts.swift` | `WorkshopStepApprovalRequest` struct |
| `WorkshopProcedureExactActivation.swift` | `WorkshopProcedureExactActivationQualifier` and coordinator: event-driven qualification from immutable terminal evidence and exact procedure ledger identity |
| `WorkshopPump.swift` | `WorkshopPump` struct; `tick`, `hasLiveAttempt`; live and recovered receipts settle through Desk's ops lock, changing status only for the latest reservation on a nonterminal item; receipt-only recovery requires its unchanged commit revision; WorkshopReceiptLog owns the receipts feed’s session/directed_task variants, both append routes, handoff marker writes and bounded raw read |
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
| `MacIntegrationPermissions.swift` | integration authority store plus one system-permission map for card admission, panes and checking; durable permission writes emit the existing root-scoped permission-change signal; kept Mac CoreLocation reader with a locked authorization cache and Location Services acquisition; Messages directory access probe, bundle-specific Automation verification, Trust-only categories left to Trust, and notification authorization |
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
| `InboxItemRecord.swift` | `InboxSourceReadState`, `InboxItemRecord`, `InboxRelatedGroup`; latest stable-card identity and OwnerAttentionPolicy projection |
| `LiveNotificationInbox.swift` | Single physical-line reader and writer for inbox cards; actor mutations and caller-owned row edits share retention and archive-before-rewrite under the inbox flock |
| `NotificationInbox.swift` | `NotificationInboxClock` |
<!-- END GENERATED BLUEPRINT -->

### GrokLink

Directory: `Modules/NativeAgentCore/Sources/GrokLink/`

Grok connection credentials and reply input.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/GrokLink/ -->
| File | Owns |
|---|---|
| `GrokLinkCredential.swift` | `GrokLinkCredential`, `GrokReplyInput` |
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

### WorkflowOrchestration

Directory: `Modules/NativeAgentCore/Sources/WorkflowOrchestration/`

The core boundary is retained: EngineRuntime's public `DeskFacade.workflows`
projection exposes `WorkflowRecord`. Moving those records into App would require
EngineRuntime → App → EngineRuntime, so the TOP 10 contraction is cycle-skipped.

Workflow registry and records. Dormant compiled defaults and their seeding/merge
policy are retired; listing an absent registry returns empty without writing it.
The shared read projection alone normalizes the exact original `memory-capture`
seed to a template stating execution is unavailable; saved bytes are never rewritten.
Existing saved rows, including customized templates, and history are preserved. The workflow client
owns pack installation/removal and checked reads; Doctor does not create/reset
the registry or the retired run_state directory. Heartbeat reads retained run_state
as historical residue; existing history stays untouched.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/WorkflowOrchestration/ -->
| File | Owns |
|---|---|
| `WorkflowOrchestration.swift` | Saved workflow records: one checked registry schema and stable timestamp sorting for read-only list/projection and pack admission/install/removal; list and Capabilities share exact legacy-seed normalization without changing customized rows or saved bytes; `WorkflowStep`, `WorkflowRecord`; no default seeding or read-side writes; backup/export inclusion, no raw phone sync and workflows privacy coverage are declared here |
<!-- END GENERATED BLUEPRINT -->

### ToolExecution

Directory: `Modules/NativeAgentCore/Sources/ToolExecution/`

Tool execution, sandbox primitive broker and promotion boundary.

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/ToolExecution/ -->
| File | Owns |
|---|---|
| `PartHost.swift` | `Parts.rehearse`, `ToolHost`: a part's declared actions, files by reach and primitives through the broker; nested part calls are programs, retaining preview and their typed result while child effects stay suppressed; projection execution refuses host effects, model tool thinking retains this same restricted host and passes its native effect envelope through unchanged |
| `Parts.swift` | `Parts`, `PartError`: the one form of a part (docs/AGENT_IS_THE_APP.md): one save (a revision inherits what it does not restate; `edits` revise its code), one read-only keep eligibility projection shared by Tools and enable (`prepareKeep`, current row against the reviewed full digest and sealed proof; nil version restores only disabled Markdown guidance without a candidate or code fingerprint, decided and written under the ability-store lock; `keepRefusal`: theirs under Full Mac for their own work, else the owner's card), one signed admission re-verified each run, one run with bounded version-pinned typed `call` (optional native preview retains the runner/host preview posture; optional native `CallReach` narrows the pinned candidate's actions/primitive capabilities before suspension) and pure `face` entries and broker settlement, one all-kind list shared with the Tools page, one read (kind/version and selected declarations and latest code labeled by source.version, built-in guidance through InstalledSkillInventory), one lifecycle (enable, restore, disable, rollback, drop, validate); launch migration of tool and skill records; bundled seeds kept with exact sealed admission |
| `ToolExecution+RunSandbox.swift` | `ToolPrimitiveBroker`: declared model/network/program/secret reach, raw network, programs over stdio, keyring secrets inserted at the edge and reply redaction (stream-piece boundaries may expose up to three leading secret bytes before the remainder is redacted), admitted-model thoughts (optional app tools and an existing routing surface, canonical tool-turn owner, same restricted host and caller limits) and fetch, the run's one screen watch and its hands; DNS handles remain owned until actual synchronous exit after cancellation/close, late results open nothing, and fetch timeout reports an unknown outcome; one arrival buffer per held thing that program and network reads take (one text-or-base64 shape), each arrival on which posts a resident ability's `held` signal; no file executor |
<!-- END GENERATED BLUEPRINT -->

### Chrome Relay Core

Directory: `Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/NativeAgentChromeRelayCore/ -->
| File | Owns |
|---|---|
| `ChromeHostIdentity.swift` | `ChromeHostIdentity`: native messaging browser/relay process identity, allowed-origin checks and private refusal evidence |
| `ChromeSocketIdentity.swift` | `ChromeSocketIdentity`: kernel audit-token peer validation against the running caller's designated signer; unsigned identity is refused |
| `NativeMessagingFraming.swift` | `NativeMessagingFramer`: bounded little-endian JSON framing shared by Chrome pipes and private relay socket, with exact fragmented reads |
<!-- END GENERATED BLUEPRINT -->

### Permissions Snapshot

Directory: `Modules/NativeAgentCore/Sources/PermissionsSnapshot/`

<!-- BEGIN GENERATED BLUEPRINT: Modules/NativeAgentCore/Sources/PermissionsSnapshot/ -->
| File | Owns |
|---|---|
| `main.swift` | PermissionsSnapshot executable: deterministic permission-law row projection through the real gated dispatcher with recording ports; not app runtime |
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
| `BridgeMessage.swift` | `BridgeMessage`: shared signed device envelope, canonical HMAC body, exact reply correlation and inner approval signature validation |
| `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver` enum; `typeAndMime`, `fileByteLimit`, `submittingSpeech` keeps composer wording on its utterances |
| `ChatPacedReveal.swift` | `ChatStreamPacer` and shared streaming views: paragraph-aware paced reveal, edge fade and settle crossfade for Mac/iPhone |
| `ChatRichContentParser.swift` | `ChatRichContentParser` enum; `blocks`, `listRows`; shared fence, list marker and continuation grammar |
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport` class; `observeAccountFailures`, `observeIncoming` (returns subscription readiness), `isChatNotification`, `shouldPersistPullCursor`, `resignalMessage` (original signed envelope; existing query clock renewed) |
| `CloudKitTimeoutResultLatch.swift` | `CloudKitTimeoutResultLatch` actor; `wait`, `finish`, `race`; shared timeout race for detached diagnostics and budget-inheriting transport tasks |
| `ColorHex.swift` | `Color.init(hex:)`: shared six/eight-digit String color decoding for Mac and iPhone |
| `CompactDurationFormatter.swift` | `CompactDurationFormatter.string`: shared rounded compact duration wording with finite/range admission |
| `DetachedCloudKitTimeoutRace.swift` | `DetachedCloudKitTimeoutOutcome` enum |
| `DeviceApprovalSignature.swift` | `DeviceApprovalSignature`: Ed25519 device identity and canonical approval-body verification; outer HMAC remains required |
| `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |
| `DeviceEventIdentity.swift` | `NativeAgentDeviceEventIdentity`: payload-free stable cross-device notification/collapse identity independent of changing prose |
| `DeviceSyncTransport.swift` | `DeviceSyncTransport`: shared transport seam, role/message codecs, account/recovery outcomes and transport resolution |
| `ICloudBridgeConstants.swift` | `NativeAgentICloudBridgeConstants`: shared KVS/Drive wire namespace, mobile source keys and configured background task identifiers |
| `ICloudChatFileAccessPolicy.swift` | `ICloudChatFileAccessPolicy.normalized`: canonical signed phone file-access modes; malformed metadata never becomes permissive |
| `InboxDigestGroupProjection.swift` | `InboxDigestGroupProjection`: read-only platform inbox adapter preferring structured groups over legacy prose |
| `InboxWireModels.swift` | Shared inbox rows and `InboxActionVocabulary`: signed Mac route normalization and supported controls; `view` remains phone-local |
| `InlineInteraction.swift` | `InlineInteraction`: durable card kind/state/scope, continuation and outcome contract shared by dispatch, transcript and renderers |
| `InlineInteractionDescriptor.swift` | `InlineInteractionDescriptor`: registry-supplied existing control/location bindings; renderers switch on interaction kind, not connector name |
| `KnowledgeGraphEdgeWireSnapshot.swift` | `KnowledgeGraphEdgeWireSnapshot`: shared immutable edge decoding; platform wrappers retain UI identity and extra fields |
| `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: shared policy snapshot decoding/defaults; TrustCenter retains policy authority |
| `MobileAppSettings.swift` | `MobileAppSetting`: phone projection of Mac settings registry controls and single-value update spellings |
| `MobileDeskSnapshot.swift` | `WorkOverview` and mobile Desk values: bounded canonical-identity reading copies, owner counts and execution movement; no second decision owner |
| `MobileHelpers.swift` | Helper row/edit revisions, shared agent summaries and read-only other-room exchange rows/chronological placement for Mac and phone |
| `MobileSchedulerSnapshot.swift` | `MobileSchedulerSnapshot` struct |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup` enum; `groups`; declares live phone snapshot inputs only: unread promotion_candidates.json is retired; training_proposals.json retains its active phone readers |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | `MobileTrustAction` enum |
| `MobileWorkActivity.swift` | `Experience` and `ObligationPhase` value contracts shared by owners and phone renderers; `MobileWorkActivity` and its revisioned experience snapshot |
| `ModuleLogging.swift` | `nativeLog`: shared module diagnostics with local credential scrubbing before public logging, without importing Core |
| `OrganismLivingStatus.swift` | `OrganismLivingStatusFile`: rebuildable shared body/status transport values with explicit unavailable boundaries; cognition remains Mac-owned |
| `PartFace.swift` | Shared Codable/Sendable PartCallResult and PartCallError, typed PartFace sections/rows, and PartFaceSnapshot with native ready/unavailable/failed/error/owed fields for Mac and iPhone |
| `PhoneConnection.swift` | `NAPhoneConnection`: one shared assessment of pairing, transport and accepted exchange, naming the first unmet fact and its repair owner |
| `PhonePlaceEvent.swift` | `PhonePlaceEvent` and `PhonePlaceHistory`: authenticated place observations and bounded atomic history written only by the Mac bridge |
| `PhoneRequest.swift` | `PhoneRequest` and `PhoneRequestResult`: typed signed request/result bodies over the existing device chat lane |
| `ProviderAuthStatus.swift` | `ProviderAuthStatus`: shared credential-proof presentation and separately published dispatch eligibility |
| `ProviderAuthStatusWireSnapshot.swift` | `ProviderAuthStatusWireSnapshot`: shared compatibility decoding and bounded metadata projection; providers retain credential/routing authority |
| `ProviderCatalogStatus.swift` | `NAProviderCatalogStatusCodec`: credential-free provider/model/surface metadata over existing device status transport |
| `ProviderCatalogWireModels.swift` | `ProviderModelInfo` and `ProviderTestResult`: shared model capabilities and typed check results, including cause and exact-key fingerprint |
| `RunKindVocabulary.swift` | `RunKindVocabulary.displayName`: shared safe display names for extensible run-kind wire values |
| `SharedModels.swift` | `ChatSession.displayTitle` is engine-resolved presentation; canonical index decoding initializes it from `title` when absent; `ChatSessionNavigation` carries ordered rows with actual pin/anchor flags and the shared `ConversationAnchorPin`; one `pinned_chat_sessions.json` object replaces separate platform merges and `chat_anchor.json` |
| `SpeechUtterance.swift` | `SpeechUtterance`: original audio/recognition evidence, submitted wording and compact uncertainty projection without rewriting hypotheses |
| `SurfaceLayout.swift` | `SurfaceLayout` struct: the layout document's shape, vocabulary and seed; `addMissing`, `shown`, `arranged` for the Mac and the phone; `QuietToolPage` owns the shared page definitions including inbox/unindexed reads; `AppDoorNames` shares page/item aliases and derives accepted part face pages from those definitions |
| `ToolActivityPresentation.swift` | `ToolActivityPresentation`: shared card/progress/approval copy from bounded call names; tool IDs and execution arguments stay unchanged |
| `UserDisplayFormatters.swift` | `UserDisplayFormatters` timestamp parsing, cache and presentation shared by Mac and iPhone; compact duration presentation delegates to `CompactDurationFormatter` |
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
| `due-reminders.js` | tool `due-reminders`: Read reminders due today and overdue in the Mac's local day. |
| `growth-week.js` | tool `growth-week`: My seven-day growth readout, from frozen native REM timeline evidence. |
| `mac-watch-catalog.js` | tool `mac-watch-catalog`: Return inactive Mail, Calendar and Reminders watch recipes. |
| `mail-recovery.js` | tool `mail-recovery`: Recovery wording for structured mail failure reasons. |
| `maintenance-assistance.js` | tool `maintenance-assistance`: Group and explain checked Doctor asks, saved storage plans and Speech Recognition permission facts. |
| `make-generated.js` | tool `make-generated`: Compose raw generated images with make.add, preserving their prompt, model and requested ref, and report each registration failure. |
| `make-title.js` | tool `make-title`: The title of a Make preview, from its decoded HTML title, prompt or filename. |
| `messages-recovery.js` | tool `messages-recovery`: Recovery wording for structured messages failure reasons. |
| `music-library.js` | tool `music-library`: Read Music library search, playlist/library pages and current playback without opening Music. |
| `music.js` | tool `music`: Control Music playback, resolve an exact library track, and verify playback through the read-only music-library part. |
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
| `AdvancedView.swift` | More reads the pairing-owned surface layout directly; shared health and runs retain local loading/error state only |
| `ApprovalsView.swift` | Approval presentation and submission state; rows read the shared sync projection, including Mac-resolved decision and time |
| `ChatBubbleViews.swift` | `BubbleView` struct |
| `ChatPresentation.swift` | Chat controls and picker presentation; model controls read the shared `iCloudSyncEngine.surfaceModels` projection |
| `ChatView.swift` | Main reads the conversation anchor; Mac-projected other-room events interleave by time and open the Agents thread; history selection and drafts remain local |
| `DeskView.swift` | Shared Desk rows and reading copies; selected handles resolve current fields or an unavailable state |
| `InboxModels.swift` | `InboxItemRecord` transport shape and presentation; status is supplied by the Mac |
| `InboxView.swift` | Inbox presentation, notifications and submission state; rows and ID-selected details read the shared sync projection |
| `KnowledgeGraphView.swift` | Graph presentation and ID-resolved entity details/neighbors from the shared typed graph; local search/loading state |
| `MacToolsPresentation.swift` | `MacSystemQuickAction` enum |
| `MacToolsView.swift` | `MacToolsView` struct; remote controls read the shared Trust snapshot |
| `MemoryView.swift` | Memory presentation and submission state; memories and proposals read the shared sync projection without local suppression |
| `MobileAgentsView.swift` | Agent list and ID-resolved conversation from the sync owner's shared readbacks; local message drafts and submission state |
| `MobileAppIntents.swift` | `MobileAskIntent`: `perform` |
| `MobileConnectorRow.swift` | `MobileConnectorRow` struct; connector receipts update the sync projection |
| `MobileHelpersView.swift` | Helper list and ID-resolved details from the sync owner; local editable drafts and submission state |
| `MobileIntentRuntime.swift` | `MobileIntentRuntime` enum; `prepare`, `agent` |
| `MobileNotificationActions.swift` | `MobileNotificationActions` enum; `handle` |
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `shouldSync` |
| `MobileSchedulerView.swift` | `MobileSchedulerView` struct |
| `MobileTrustEditor.swift` | `MobileTrustEditor` struct; displays the engine-resolved preset and effective permission level |
| `NativeAgentDesign.swift` | `View`: `appShimmer` |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities`; Live Activities and the thinking light share Mac-projected activity state and Experience correlation evidence; no local turn-status persistence or bridge-event reducer |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `seal` |
| `SkillLifecycleView.swift` | Shared typed skill catalog, local filters/loading state, ID-resolved details with unavailable state |
| `SkillsToolsView.swift` | Shared tool catalog presentation and local page/search/loading state |
| `TelegramView.swift` | `TelegramView` struct; reads the shared revision-ordered Telegram projection |
| `TurnInspectorView.swift` | Turn summary presentation reads the shared sync projection directly |
| `WorkshopView.swift` | Shared task rows, engine-projected actionable approval state and ID-resolved details; local submission/loading state |
| `iCloudBridge.swift` | `iCloudBridge` class; `recordMacConfirmation`, `clearMacConfirmationForConnectionRepair`; pairing-scoped record-identity nudges until authenticated Mac acceptance or the existing chat/action/place owner retires delivery; place acceptance is checkpointed by `PhonePlaces` before nudges stop; restored owners loaded before pruning |
| `iCloudSyncEngine+Actions.swift` | `iCloudSyncEngine`: `requireIdleActionForConnectionRepair`, `reconcileActionsForConnectionRepair`, `persistCloudKitActionResponse`; accepted surface-model receipts update every engine-declared group member in shared `surfaceModels`, ordered by the routing owner's committed revision, without acknowledgment fences; settings/helper/thread readbacks live here rather than in screens; settings reads cannot overtake mutations, helper receipts use `applyHelpersSnapshot` with Mac revision ordering and detail invalidation and agent summaries retain one shape |
| `iCloudSyncEngine+Snapshots.swift` | `iCloudSyncEngine`: `applyHelpersSnapshot` owns both file and action receipt adoption, retaining newer Mac helper revisions; `refreshHelpersSnapshot`, `applySchedulerSnapshot`, `refreshSchedulerSnapshot`, `applyProviderState`; Mac revisions order approvals, inbox and memory snapshots against per-record readbacks/removals until acknowledged; provider snapshots and action receipts use the checked routing revision in the same shared surface-model projection; one typed skill/tool/graph decode owner through full, catalog and graph refreshes; Advanced group delivery refreshes that graph projection for its open list/detail; matched fuller transcript text survives compatible truncation across history membership and generation changes; connector and Telegram receipts share snapshot ordering |
<!-- END GENERATED BLUEPRINT -->

### Diagnostics

Directory: `iOS/NativeAgentMobile/Sources/Diagnostics/`

<!-- BEGIN GENERATED BLUEPRINT: iOS/NativeAgentMobile/Sources/Diagnostics/ -->
| File | Owns |
|---|---|
| `CKLandmine.swift` | `withCKTimeout` |
<!-- END GENERATED BLUEPRINT -->

## Executable Architecture Policy

`script/check_architecture_blueprint.swift` reads the following JSON block. Change
ownership rules here in the same commit as the source change. The checker invokes
the generator for complete headers, exact file/row placement and generated equality,
then validates policy markers/imports as text without compiler type-checking. `blueprintRoots`
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
        "Sources/NativeAgentApp/MemoryAppIntents.swift": "MemoryV2 — area number unmapped",
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
