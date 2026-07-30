# NativeAgent Architecture Blueprint

Last updated: 2026-07-12

This is the fast architecture map for Codex, Agent, Claude/Claude, and any other LLM working on NativeAgent. Read this before making structural changes.

## First Principle

NativeAgent is a Swift-native Mac + iPhone agent runtime. `NativeAgent.app` owns the live runtime in-process.

Shipped subsystems are unconditionally Swift-native. The migration-era
`SubsystemFlag` / `RuntimeSnapshot` / `MutableRuntime` control plane and its
app-lifecycle attachment have been retired. Product trust, onboarding, and
preference gates remain owned by their actual subsystems; no gate chooses
between runtimes, and unsupported edges fail closed in Swift.

There is no live external interpreter backend and no launchd-owned agent runtime. Do not add external runtime code, fallback loops, launchd install paths, or duplicated state roots. If a missing behavior exists, implement it in Swift or fail closed with an honest Swift error.

Historical daemon/Python-era words may still appear in old audit notes, compatibility tests, migration comments, or cleanup checks. Treat those as legacy compatibility vocabulary only. They are not the current architecture.

## Read Order

1. `docs/ARCHITECTURE_BLUEPRINT.md` for the system map and ownership rules.
2. `docs/PROJECT_DIRECTION.md` for durable product and safety guardrails.
3. `docs/HANDOFF_CURRENT.md` for the current known-good baseline and recent changes.
4. `PROJECT_STATUS.md` for capability status and open gaps.

If docs and code disagree, trust code/git, then update the stale doc.

## Runtime Shape

- Mac app: `Sources/NativeAgentApp/`
- Swift runtime modules: `Modules/NativeAgentCore/`
- Shared Mac/iOS models: `Modules/NativeAgentShared/`
- iOS companion: `iOS/NativeAgentMobile/`
- Runtime state: `data/` and `.runtime/` are local/generated and gitignored.
- Work product has one resolver and one trust boundary:
  `NativeAgentWorkspaceRoot` uses `<verified-source>/workspace` for development
  and `<dataRoot>/workspace` for app-only/public installs. Mac chat, detached
  chat, Telegram, Slack, iOS-forwarded turns, bridge helpers, builder tools,
  TrustCenter, connector workspace actions, and compiled Workshop procedures
  consume that same root. Relative file-tool paths resolve there. It is
  local/generated and gitignored.
- Persona source: `persona/`

The installed app is built by `script/install_app.sh` and normally lives in the current user's `~/Applications/NativeAgent.app`.

## High-Level Flow

```text
Mac / iOS / Telegram / Slack / local bridge
    -> App-side surface handler
    -> ChatOrchestration session + history + continuity
    -> TurnPlan intent/policy/resident-readiness snapshot
    -> compact persona / memory / runtime context
    -> optional gated CognitiveSubstrate capsule
    -> ProviderRouting model adapter
    -> tool loop through SwiftToolDispatcher / AppChatToolDispatcher
    -> MemoryV2, tools, connectors, browser, scheduler, Mac integration
    -> receipts, chat transcript, activity, iCloud/APNS notifications
```

Normal chat should stay fast. Use lazy manifests, small continuity cards, bounded recall, and tool loading. Do not inject broad memory, tool, skill, or connector inventories into every turn.

### Swarm workers

`agent_swarm` is temporary fan-out inside the same runtime, not another mind.
Provider Routing's checked `swarms` surface tuple owns its default provider,
model, and reasoning effort. Explicit model choices can specialize workers;
TrustCenter does not own a competing model default.

Workers are prompt-only/read-only unless the parent selects `access: inherit`.
Inherited workers reuse `runEphemeralToolTurn` and the existing tool dispatcher,
workspace resolver, SecurityCenter/TrustCenter, autonomy, receipts, and
verification. The originating surface and verified session remain the
authorization identity even though LLM calls use the Swarms provider. Nested
delegation and NativeAgent install/restart are withheld from worker catalogs
and dispatch. SwarmRuns owns fan-out and receipts only; it does not become a
memory, permission, provider, or tool owner.

## Shared Causal Language At Protocol Edges

NativeAgent uses one bounded read vocabulary for action phase and verification
across protocol shapes. This lets Agent interpret an action consistently
whether it began through a native tool, MCP, connector, messaging surface, or a
future webhook adapter. It does not merge the domains that own the truth.

```text
protocol response or native tool envelope
    -> transport classification + opaque owner action identity
    -> canonical domain read (Workshop / Browser / Mac Control / send / ...)
    -> MotorActionReadModel phase + separate verification state
    -> replay-guarded receipt and resident consequence
```

The ownership contract is strict:

- `ToolCausalBoundary` is a closed, value-only mapping for supported tool
  aliases. It does not dispatch, persist, approve, verify, or infer an unknown
  domain.
- `MCPInvocationOutcome` says only whether a response arrived or the remote
  protocol reported an error. Neither an MCP response nor HTTP `200` certifies
  an external effect.
- Each canonical domain owner retains its exact lifecycle, effect-time
  validation, verification, recovery, and receipt authority. Shared motor
  phases are a projection over those owners, never a replacement reducer.
- A canonical owner projection may return through the replay guard into
  resident state with its verification state still explicit. Duplicate, stale,
  dry-run, transport-only, and unowned evidence cannot masquerade as a new
  consequence.
- New MCPs, webhooks, and connectors should translate at this edge and bind to
  the domain that can verify reality. Do not create a universal webhook bus,
  integration store, scheduler, approval owner, or settlement service.

This is how protocol independence supports one persistent Agent: the wire
format can change without making her reconstruct a new meaning for proposed,
running, externally waiting, verified, succeeded, or failed work. TrustCenter,
approvals, provenance, canonical stores, and domain verification remain the
authorities.

## App Source Map

`Sources/NativeAgentApp/NativeAgentApp.swift` is the SwiftUI app/scene shell. Its executable entry point claims the single app process and completes public-release data-root quarantine before SwiftUI constructs `NativeAgentApp`, `AppModel`, or any process-wide persistence owner; moving a root after a SQLite owner opens it is forbidden because it splits canonical and derived writes across inodes. `UpdateController.swift` is the single Sparkle scheduler/controller shared by the application menu and both Settings presentations; it starts only when the signed bundle carries a non-placeholder feed, a valid EdDSA public key, and the release pipeline's Boolean proof that the feed was published. `ContentView.swift` owns canonical sidebar selection and typed child routing. `SkillsToolsView.swift` is the single Skills & Tools sidebar destination: it owns only the persisted Skills/Tools page selection, while `SkillLifecycleView` and `ToolsView` retain their separate content and refresh behavior. Direct Skills and Tools routes select the exact child page without recreating a second sidebar destination. `NativeAgentLaunchPreflight.swift` owns the pre-AppKit guard that suppresses accidental Codex-shell execution of the repo dist GUI bundle while preserving canonical installed launches. AppDelegate and app lifecycle behavior belong in focused siblings:

| File | Owns |
|---|---|
| `AppDelegate+Launch.swift` | Launch/bootstrap wiring, URL handling, activation setup, GitHub Keychain credential reconciliation, append-only reconciliation of legacy contradictory Desk hierarchies, and one-shot recovery of durable Codex completion jobs after the bridge listener is ready |
| `AppDelegate+BackgroundTasks.swift` | Background-loop start/stop wiring |
| `AppDelegate+ProcessLifecycle.swift` | Termination/sleep/wake lifecycle hooks |
| `AppDelegate+ICloudRuntimeForwarding.swift` | iCloud/runtime event forwarding through the resident iOS-profile chat client; reuse is profile-exact and cannot borrow Mac/Slack/Telegram policy identity |
| `NativeAgentWindowChrome.swift` | Main-window chrome and placement helpers |
| `NativeAgentEmbeddingWarmup.swift` | Startup embedding warmup |
| `ViewFileRefreshTask.swift` | View-lifetime adapter from canonical file/store invalidations to one trailing-edge SwiftUI refresh; owns no state or signal source and cancels with view visibility |
| `NativeCognitionRuntime.swift` | App-owned CognitiveSubstrate assembly gate, lifecycle restore/persist, atomic Subconscious-master configuration with actual substrate/Organism readback, same-process onboarding-transition refresh, event-coalesced dirty microcycle ownership, one generation-checked exact cognition-maintenance deadline, immediate Dream/REM replay with durable pending-reconciliation retry, reflection surface seed, organism body-state sampling, transactional reflex review + audit receipts, and observatory read model. CognitiveSubstrate projects only real discrete maintenance boundaries (emotional consolidation, thought-seed physical expiry, and proposed-view retirement); elapsed analytic reads create no checkpoint wake, unchanged projections do not churn the task, and the daily registered loop is only crash/integrity recovery. Residual organism repair persists and publishes its own transition without poking cognition. CognitiveSubstrate, OrganismKernel, and the bounded Desk pursuit replay publish immutable attention into one lock-backed handoff after owner transitions; an ordinary turn reads it without entering those actors, touching disk, scheduling work, or calling a model. Resident event admission updates bounded in-memory state and schedules one coalesced microcycle; it does not synchronously commit each physiological family. At microcycle start the runtime captures the scheduled count, turn class, generation, and execution identity, then clears pending state so a reentrant event owns a distinct later generation. One fixed-time field snapshot supplies both workspace and canonical SQLite persistence for nodes, affect, thought seeds, pruning, and the receipt. The ordinary provider seam also takes one fixed-time `CognitiveTurnProjection`: one body sample and canonical affect epoch feed one OrganismKernel refresh/frozen read, and that exact organism projection feeds the frozen capsule. Structured and Anthropic text-compatible turns consume the same capsule/posture pair and only mark it surfaced after appending it to provider context. This value owns no state or authority. Exact-root Desk invalidations still trigger detached canonical pursuit replay and clear stale intent immediately. The live OrganismKernel supplies current delivery prediction evidence after continuity restore; body projection does not decode the kernel's persistence file behind its owner. It publishes payload-free, buffering-newest owner invalidations after visible cognitive transitions so mounted views and the existing Mac→iPhone snapshot writer can reread state without polling. The live default-root runtime also feeds an optional payload-free installed-physiology recorder from existing events/deadlines; recording is asynchronous/coalesced with a bounded termination durability barrier, never another scheduler. Admission provenance assigns live/system/debug/verification class before asynchronous work; topic words in an ordinary user message cannot reclassify it. Alternate/test runtimes inject exact data roots and cognitive/organism configuration instead of mutating process defaults. |
| `NativeContextFlowRuntime.swift` | App-owned ContextFlow composition, start/stop/reload, the single persisted Active/Observe Only/Off production mode, resident MemoryV2 and Desk/Workshop projections, attention handoff, and public pre-onboarding force-off. It does not own canonical memory/persona state or tool authority. |
| `NativeAgentBuildIdentity.swift` | Fail-closed running-bundle identity from stamped version, full source object ID, and dirty-source truth. A revision is exact only when the bundle is clean and carries a full Git object ID. |
| `AgentDisplayName.swift` | Mac adapter over the shared pure identity formatter. Visible UI reads the configured PersonaEngine profile name through `AppModel.agentDisplayName`; generic onboarding labels and missing profile state fall back to `NativeAgent` instead of becoming a fixed persona. |
| `ClaudeBridge.swift` | Authenticated localhost `/claude/*` and `/codex/*` state/message/tool/events/debug routes, descriptor-published preferred-port fallback, external-MCP deny, bounded activity, bridge attachment metadata, and honest completion status projection for text, attachment-only, failed-pre-dispatch, in-progress, and outcome-unknown results |
| `CodexCompletionLifecycle.swift` | Durable digest-bound claim/cache/delivery lifecycle for Codex completion returns: at-most-once Agent-turn admission, response synchronization before external send, per-artifact settlement, stable retry only for idempotent transports, and fail-closed ambiguity/corruption handling |
| `AgentBridgeCompletionRouter.swift` | Routes a cached Codex completion to the persisted origin, requires Slack/Telegram semantic acceptance, and refuses to replay accepted or ambiguity-settled non-idempotent artifacts |
| `NativeLoopbackListenerParameters.swift` | Shared listener-level loopback binding and preferred/consecutive/system-assigned fallback plan for the Mac Control and Codex/Claude bridges; each bridge publishes its selected port, while accept-time peer checks and bearer auth remain separate defense-in-depth gates |
| `AppChatToolDispatcher.swift` | App-native notification/browser tools plus lazy `reflex_review`, which routes approve/hold/reject into `NativeCognitionRuntime` rather than writing organism state directly. One `ToolCausalBoundary.MotorReference` observer replaces per-domain Workshop/Mac/external-send callbacks; the factory still rereads the exact canonical owner before resident consequence admission, while Browser keeps its existing runner-owned readback. Shared chat composition disables only the inner duplicate autonomy decision because `ChatOrchestrationClient` has already authenticated the exact origin and owns the single approval/autonomy membrane; direct/raw app-tool clients retain the inner gate, and all SecurityCenter hard checks still run. |

Bridge message responses carry generated attachment metadata (`id`, type, MIME, name, byte size, and local generated-image path) but never inline base64 bytes. `/codex/message` uses the shared chat factory; `/codex/tool` uses read-only file access with no approval filer. Both deny and scrub external `mcp__*` tools.

`Sources/NativeAgentApp/AppModel.swift` is the observable state/bootstrap shell. It should stay mostly stored state, computed counts, bootstrap, and shared helpers.

Feature actions live in focused extensions:

| File | Owns |
|---|---|
| `AppModel+ChatState.swift` | Per-session message/receipt state, detached-window helpers, busy/streaming indicators, and send-next queue projections |
| `AppModel+FirstRunWelcome.swift` | First-run welcome/autostart state and onboarding affordances |
| `AppModel+ChatSessions.swift` | Session loading, selection, naming, sidebar refresh |
| `AppModel+ChatActions.swift` | Transactional send/regenerate/stop/archive/chat memory/scratch actions plus the bounded per-session send-next queue, ordered drain gate, and steer cancellation boundary. Regenerate carries the exact assistant row identity into canonical message persistence; it never appends then performs a best-effort cleanup. |
| `AppModel+Refresh.swift` | `refreshAll` and dashboard snapshot fan-in |
| `AppModel+HealthEmbeddings.swift` | Health card, what's-running, embeddings controls |
| `AppModel+ProvidersAuth.swift` | Provider/model catalog, chat brain defaults, Codex login |
| `AppModel+ProviderReadiness.swift` | Provider readiness refresh and chat-brain availability summaries |
| `AppModel+RoutingWorkflowMCP.swift` | Research search, route planning, workflows, approvals, MCP details/calls |
| `AppModel+GraphCapabilityActions.swift` | KG actions, capability catalog/trust, native actions, browser, improvements |
| `AppModel+WorkshopPolicy.swift` | Dreams job shortcut, Workshop tasks, Trust Center policy, backups |
| `AppModel+MemoryActions.swift` | Memory search, pin/delete/consolidate/hygiene |
| `AppModel+SkillsIntegrations.swift` | Skills, tools, evals, workspaces, connectors, Telegram, Doctor |
| `AppModel+PersonalitySelfImprovement.swift` | Personality docs, self-improvement, memory proposals, training, dreams, promotion |
| `AppModel+ViewClientOps.swift` | Thin NativeClient passthroughs for views (R22): status/config reads, inbox, model catalog, raw POST |

`Modules/NativeAgentCore/Sources/ProviderRouting/FirstPartyModelCatalog.swift` owns the verified public OpenAI, Anthropic, xAI, and conservative Moonshot model/capability tables plus provider-specific request controls. `MoonshotModelCatalog.swift` overlays an authenticated `/v1/models` response on that offline Kimi baseline; its rebuildable cache is never a provider registry row. `LLMClient+MoonshotAdapter.swift` keeps Moonshot identity, credentials, and endpoint separate from generic OpenAI transport, preserves Kimi reasoning content through structured tool loops, and prevents hidden reasoning deltas from becoming assistant text. `LLMClient+AnthropicOAuthDirectAdapter.swift` owns Anthropic OAuth cache-marker placement: the text-compatible append-only lane retains the previous and current request boundaries within the four-breakpoint limit so cache reuse survives a new conversation turn; structured native-tool traffic retains its separate last-tool/current-message budget. Cache metadata must not alter model-visible prompt content, ordering, effort, or tool authority, and transport support must be established by live provider usage rather than inferred from API-key documentation. `CodexSelectableModelCatalog.swift` overlays the signed ChatGPT/Codex account entitlement cache on an account-verified fallback for both direct ChatGPT OAuth and Codex CLI; its account-only capability contract must never replace the separate OpenAI API-key contract. `OpenAIExecutionControls.swift` preserves account Max/Ultra as selectable Codex presets but maps either to the deepest direct ChatGPT OAuth wire effort, `xhigh`; Codex CLI retains the literal preset so it can apply its client-side behavior. `ProviderSettingsView.swift` owns provider/model/Think/Fast selection for every canonical model surface, while `ChatBrainControlBar.swift` owns the same provider-scoped controls for the active Mac chat. A successful Providers save must update the shared `AppModel` picker cache immediately so an open chat cannot send a stale provider/model/Think/Fast selection. API keys remain Mac-local and never travel through signed iCloud actions. Global compatibility caches cannot override canonical first-party capability rows. Accepted Slack and Telegram turns consume one checked `ProviderRoutingSnapshot`; their app wiring must not independently reread preference and active-provider files or reimplement effort/model compatibility.

`Sources/NativeAgentApp/NativeClient.swift` is the thin client/facade. Endpoint groups belong in `NativeClient+*.swift` files, not back in the facade.

Large NativeClient endpoint families are split by product surface:

| File | Owns |
|---|---|
| `NativeClient+ApprovalExecutors.swift` | Generic/misc approval resolution and reconciliation helpers |
| `NativeClient+BrowserRoutes.swift` | Visible Browser status/routes and the app-owned WebKit effect adapter. Canonical running/terminal/deadline/cancel/recovery state and derived receipts belong to the Core Browser operation store. |
| `BrowserWindow.swift` | MainActor-owned visible WKWebView and its optional authenticated loopback IPC adapter; the IPC listener shares the preferred/consecutive/system-assigned fallback contract and publishes `browser_ipc.json`, while browser effects and verification remain in the existing Browser domain path. |
| `NativeClient+ChatRuntime.swift` | Chat send/stream facades and chat runtime adapters |
| `NativeClient+ConnectorActions.swift` | Connector action dispatch, status, and receipt helpers |
| `NativeClient+ConnectorAuthActions.swift` | Connector revoke/connect registry mutations |
| `NativeClient+CutoverSeams.swift` | Swift runtime seam helpers and adapter shims |
| `NativeClient+DreamActions.swift` | Manual dream/REM actions and dream diary reads |
| `NativeClient+ExportWorkshopInbox.swift` | Workshop execution/inbox export helpers |
| `NativeClient+ExternalSendApproval.swift` | Replayable Slack/AgentMail external-send approval execution and durable receipt handling |
| `NativeClient+ImprovementOps.swift` | Improvement operation actions and receipts |
| `NativeClient+Improvements.swift` | Improvement dashboard, detail, and status helpers |
| `NativeClient+JSONPathSupport.swift` | Small shared JSON/path helpers |
| `NativeClient+KnowledgeGraphView.swift` | Checked canonical KnowledgeGraph projection for Mac panels and iCloud/iOS snapshots; SQLite is authoritative once present |
| `NativeClient+LocalAPI.swift` | In-process local API route adapters |
| `NativeClient+MCP.swift` | MCP server/status/call helpers |
| `NativeClient+MemoryApprovalExecutors.swift` | Memory repair/kind-backfill approval execution and reconciliation |
| `NativeClient+MemoryMutations.swift` | Memory pin/delete/consolidate/hygiene mutation routes |
| `NativeClient+MemoryPolicyActions.swift` | Memory proposals, consolidation, memory-policy patches |
| `NativeClient+WorkMemory.swift` | Work-memory and Workshop execution/status bridge helpers |
| `NativeClient+NativeActions.swift` | Native action catalog, status, and dispatch helpers |
| `NativeClient+NextGenActions.swift` | Next-gen feature action routes |
| `NativeClient+NextGenStatus.swift` | Next-gen status/readiness summaries |
| `NativeClient+Notifications.swift` | Notification, inbox, and APNS status/action helpers |
| `NativeClient+OnboardingActions.swift` | Onboarding start/complete/reset |
| `NativeClient+ProcedureExactActivation.swift` | Idempotent executor and crash reconciliation for the local-only, evidence-bound exact Workshop procedure activation approval; it revalidates canonical evidence before installing the active pointer |
| `NativeClient+ProviderTelegramSessions.swift` | Provider/Telegram session linkage helpers plus explicit-root model catalog reads |
| `NativeClient+ProviderWorkflowGraph.swift` | Provider workflow/graph helpers plus explicit-root surface/provider preference writes |
| `NativeClient+Providers.swift` | Provider/model catalog, OAuth readiness, model preferences, and exact injected auth/cache roots for alternate-runtime construction |
| `NativeClient+RegistryMutations.swift` | Registry-backed runtime mutation helpers |
| `NativeClient+ResearchOps.swift` | SearXNG config/autodetect and research search |
| `NativeClient+RuntimeReadAPIs.swift` | Read-only runtime/dashboard/status endpoints |
| `NativeClient+SchedulerJobActions.swift` | Scheduler job creation |
| `NativeClient+SelfEvolutionApproval.swift` | Self-evolution approval apply/reconcile/verify handling |
| `NativeClient+SkillActions.swift` | Skill registry, manifest/readme reads, enable/disable |
| `NativeClient+SwiftRuntime.swift` | Swift runtime status and health helpers |
| `NativeClient+SystemOpsActions.swift` | Doctor, rebuild, git push, git/process helper, stash recovery |
| `NativeClient+TelegramOps.swift` | Telegram config, test send, and log clearing |
| `NativeClient+ToolDispatch.swift` | Chat tool dispatch wrappers and bridge client helpers |
| `NativeClient+TrainingActions.swift` | Training runs, drills, proposals, promotion staging |
| `NativeClient+TrustBackupOps.swift` | Trust-policy backup/restore helpers |
| `NativeClient+TrustPolicyActions.swift` | Trust, multimodal, Mac-control, Full Mac duration policy writes |

`NativeClient+ApprovalExecutors.swift` owns generic/misc approval resolution only. Memory repair/kind-backfill approval handling lives in `NativeClient+MemoryApprovalExecutors.swift`; self-evolution approval apply/reconcile/verify handling lives in `NativeClient+SelfEvolutionApproval.swift`.

`BackgroundLoopsAssembly.swift` is the composition manifest. Loop families live in `BackgroundLoopsAssembly+*.swift`; do not hide new long-running loops elsewhere.

`NativeAgentCore.BackgroundLoopsManager` is the sole owner of loop lifecycle, execution, single-flight state, counters, and status. The app-side facade assembles dependencies and delegates to Core; it must not keep a second scheduler or status ledger. Periodic ticks and OS run-now requests pass through the same per-loop single-flight gate. Targeted Telegram or Slack reload replaces only that surface's registration and preserves sibling tasks and counters.

| File | Owns |
|---|---|
| `BackgroundLoopsAssembly+Autonomy.swift` | Autonomy/proactive/self-improvement loop wiring |
| `BackgroundLoopsAssembly+ChatSurfaces.swift` | Telegram, Slack, and iCloud/iOS chat-surface loop wiring; each long-lived surface registration reuses one client with that exact surface profile rather than reconstructing the full chat factory per turn |
| `BackgroundLoopsAssembly+DeskNotify.swift` | Desk-side push loop when a tracked item changes (idempotent, no cognition) |
| `BackgroundLoopsAssembly+GitHubTracking.swift` | Due-driven persisted-scope GitHub refresh; contribution mode circulates only authenticated authored PRs plus their linked issues into deduplicated Desk refs/items, archives prior snapshot-owned rows that leave scope, and preserves closed PR snapshot history |
| `BackgroundLoopsAssembly+DreamsMemory.swift` | Dream, REM, memory hygiene, and consolidation loop wiring |
| `BackgroundLoopsAssembly+Heartbeat.swift` | Heartbeat, watchdog, app-health, and self-healing loop wiring |
| `BackgroundLoopsAssembly+Maintenance.swift` | Snapshot, inbox cleanup, receipt, and maintenance loop wiring |
| `BackgroundLoopsAssembly+TriggerScheduler.swift` | TriggerScheduler due-deadline owner: canonical trigger file invalidations and exact next-fire deadlines wake one bounded due-job pass; no periodic trigger sweep |
| `BackgroundLoopsAssembly+WorkshopExecution.swift` | Workshop multi-step execution, approval staging, and due-trigger runner wiring |
| `BackgroundLoopsAssembly+Cognition.swift` | Manual/diagnostic microcycle factory plus production maintenance, daily replay integrity fallback, and budgeted reflection loop wiring; the 30-second microcycle is not in the production manifest because runtime events coalesce dirty settlement directly, and canonical Dream/REM commits wake replay directly |
| `BackgroundLoopsAssembly+Workshop.swift` | Organism-gated Desk Workshop pump, durable lease/reservation, and bounded restricted-session wiring |

`SchedulerDueJobRunner.swift` is the due-job actor shell and `runDueJobs` entry. Scheduler behavior is split by responsibility:

| File | Owns |
|---|---|
| `SchedulerDueJobRunner+Selection.swift` | Due-row selection, default job repair, dream receipt backfill |
| `SchedulerDueJobRunner+Execution.swift` | `notify`, `connector_action`, `dream`, and `rem` execution |
| `SchedulerDueJobRunner+Persistence.swift` | Job row updates, activity receipts, notification inbox writes |
| `SchedulerDueJobRunner+CycleHelpers.swift` | Dream/REM scheduling and inbox-message helpers |
| `SchedulerDueJobRunner+ProactiveScan.swift` | Scheduled proactive-scan inbox surfacing adapter |
| `SchedulerDueJobRunner+Timeout.swift` | Per-job timeout table + race primitive; a hung job fails loud and the runner continues |
| `NativeAppSecretRedactor.swift` | App-only Telegram-token and local-home privacy extensions layered after the canonical `PersistenceCore.NativeAgentSecretRedactor` credential contract |

Dream-cycle constants/policy live in `NativeAgentDreamCycleSupport.swift`; scheduled proactive-scan evaluation lives in `NativeAgentScheduledProactiveScan.swift`.

`NativeOAuthFlow.swift` is the provider OAuth entry and provider-id normalization shell. OAuth behavior is split by responsibility:

| File | Owns |
|---|---|
| `NativeOAuthFlow+XAI.swift` | xAI OAuth discovery, loopback browser flow, token exchange/persistence |
| `NativeOAuthFlow+Slack.swift` | Slack pasted-token save, `auth.test`, Socket Mode token persistence |
| `NativeOAuthFlow+GitHub.swift` | GitHub PAT Keychain save/load through `GitHubCredentialStore`, `/user` validation, connector registry connection marking |
| `NativeOAuthFlow+Connectors.swift` | X/Gmail/Calendar PKCE loopback flow and owner-only token persistence |
| `NativeOAuthFlow+ConnectorCredentials.swift` | Operator-owned OAuth app credentials and validated Notion integration-token persistence |
| `NativeOAuthFlow+SessionRunner.swift` | `ASWebAuthenticationSession`, callback fallback, callback parsing |
| `NativeOAuthFlow+TokenStatus.swift` | Sign-out, expiry/status checks, provider token paths |
| `NativeOAuthFlow+Configs.swift` | Provider and connector OAuth catalogs |
| `NativeOAuthFlow+Helpers.swift` | PKCE, JSON file IO, JWT expiry parsing, redaction helpers |
| `NativeOAuthFlow+Loopback.swift` | Local OAuth callback listener helpers for direct browser flows |

OAuth callback state lives in `NativeOAuthCallbackRegistry.swift`, generic
session support lives in `NativeOAuthSessionSupport.swift`, and xAI plus cloud
connectors reuse `NativeOAuthLoopbackCallbackServer.swift`.

`MacSyncEngine.swift` is the iCloud bridge state shell. Keep mutable bridge state there; put behavior in the focused extensions:

| File | Owns |
|---|---|
| `MacSyncEngine+Lifecycle.swift` | attach/start/stop, setup directories, slow missed-event integrity fallback, and one payload-free subscription that republishes bounded cognition/Organism transition snapshots to iPhone without polling |
| `MacSyncEngine+Storage.swift` | processed-id/digest persistence, transactions, coordinated iCloud file helpers, pruning/KVS sweep |
| `MacSyncEngine+Security.swift` | pairing secret cache, HMAC signing/validation, rejection responses |
| `MacSyncEngine+Snapshots.swift` | snapshot fan-in/write, pinned chats/transcripts, native snapshot byte helpers, and the iOS living-status projection. Its `needsUser` bit is derived only from exact nonterminal Desk rows explicitly waiting on the owner; organism trouble, reflex review, and generic blocked work remain separate `needsAttention` state. If canonical Desk cannot be read, the composite living-status snapshot is retained rather than overwritten with invented calm/action truth. |
| `MacSyncEngine+Inbox.swift` | KVS/query callbacks, inbox file claiming/validation/dispatch/archival |
| `MacSyncEngine+Notifications.swift` | paired-device notification relay facade |
| `MacSyncEngine+NeedsUserNotify.swift` | one-shot needs-user APNS edge detection with stable SHA-256 identity; durable dedup advances only after successful delivery and retries failures across ticks/restarts. Its caller admits only explicit owner-waiting Desk rows; approval lanes notify independently, while generic blocks and body caution cannot generate needs-user APNS. The persisted private filename remains stable for installed-state continuity; notification wording resolves the configured profile name. |
| `MacPinnedChatSessionStore.swift` | single Mac mutation/codec seam for the ordered pinned-session IDs; publishes the reactive `@AppStorage` value and the matching retention-protection mirror together so Mac UI, retention, and iOS snapshots cannot define pins independently |
| `MacSyncActionRouter.swift` | iOS remote action policy/dispatch |
| `MacSyncRemoteMacControl.swift` | iOS-triggered Mac-control transport/policy |
| `MacSyncMobileNotificationRelay.swift` | push-token persistence plus APNS/iCloud notification fanout |
| `MacSyncInboxAction.swift` | iOS-compatible inbox wire struct |
| `SignedPeerEvidence.swift` | latest authenticated iOS contact receipt derived only after signed chat/action HMAC and freshness validation; body reachability must not derive from configuration-file timestamps |

`PairingSecretManager` plus signed iCloud/MacSync HMAC validation is the only
mobile pairing owner. The retired unsigned `mobile/pairing.json` token surface
does not exist and must not be recreated or used as organism/body evidence.
On an unpaired iOS launch, `PairingView` must bind its authoritative
`PairingStore` to both `iCloudSyncEngine` and `iCloudBridge` before the bridge
starts draining CloudKit. This preserves automatic same-account pairing even
when the Mac record is already waiting; manual secret entry remains a recovery
path, not the normal setup flow.

`MacAppleScriptBridge.swift` is the AppleScript bridge namespace only.

`NativeAgentShared/DeviceEventIdentity.swift` owns payload-free notification event identity across Mac APNS/iCloud fanout and iOS snapshot-local presentation. APNS collapse IDs, bridge metadata, Inbox/Approval/Workshop local notifications, and delivery receipts carry the same bounded digest when they represent the same semantic event; the iOS presentation gate checks pending/delivered requests before adding another local alert.

`NativeAgentShared/CloudKitDeviceTransport.swift` owns the exact private-database
query-subscription contract. Subscriptions are user-level CloudKit objects, not
role-level device objects, so Mac and iPhone converge on one ID per record
type: `NAChatMessage.incoming`, `NANotification.visible`,
`NAPairingDevice.changes`, and `NAStatus.changes`. Registration must fetch
before create and may treat a
failed create as an idempotent race only when an authoritative refetch proves
the exact row exists. A production/schema rejection is never equivalent to
“already subscribed.” Legacy role-suffixed IDs are accepted only as exact push
compatibility values and are not authored by current builds.

Silent `content-available` pushes remain the event-driven sync trigger for
ordinary `NAChatMessage` records, but Apple may coalesce them and they are not
delivery proof for a user alert. Explicit notifications are therefore written
as `NANotification` records and match only `NANotification.visible`, whose
localization-backed title and body are presented by iOS without granting the
app background execution. The ordinary `NAChatMessage.incoming` subscription
stays broad and schema-independent for legacy and mixed-version chat wakeups,
but the two subscriptions cannot overlap because their record types differ.
iOS registers the visual subscription before silent chat sync and retires the
old overlapping `NAChatMessage.notifications.visible` subscription on upgrade.
This is the credential-free public notification path for users signed into the
same iCloud account; direct APNS is an optional private/self-hosted parallel
route, not a public-service dependency.
The record retains the signed `BridgeMessage` as authority; the visible
projection carries only title, screen, and canonical event identity. After the
visual subscription is authoritatively registered, the later record drain
absorbs the signed outcome without scheduling a second local notification.
CloudKit permits no more than three `desiredKeys`; the visual contract uses
exactly screen, event identity, and kind while title/body travel through
localization arguments. iOS publishes an exact versioned capability status
only after registration succeeds and retries it on foreground activation.
Mac eligibility receipts consume that paired-phone status rather than
reconstructing readiness from Mac-side CloudKit configuration.

| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | Apple Mail read/send/search AppleScript actions |
| `MacAppleScriptBridge+MessagesNotes.swift` | Messages and Notes AppleScript actions |
| `MacAppleScriptBridge+Music.swift` | Apple Music now-playing/search/library/player AppleScript actions |
| `MacAppleScriptBridge+Runtime.swift` | Shared executor, envelopes, escaping, input coercion, and record parsers |

`NativeAgentPaths.swift` owns data/persona root resolution and public first-run blank-slate quarantine. `NativeAgentPublicSafety.swift` owns pure public-safe launch predicates used by runtime defaults.

`ChatView.swift` remains the main chat composition view. `ChatQueuedTurnsView.swift` is the shared main/detached Mac projection of the per-session send-next queue. Enter remains an acceptance action while a turn is active: the message is held in a bounded 20-item in-memory FIFO and does not become transcript/provider context until its execution starts. Natural completion drains the next turn, ordinary Stop pauses the queue, and Steer promotes a selected turn before ordered cancellation and restart. The drain-start gate is part of the transaction boundary so a new Enter cannot overtake a queued turn while that turn is being started. Scroll-follow behavior and toast queue/dedupe state live in `ChatViewStateCoordinators.swift`; Markdown transcript export lives in `ChatExportService.swift`; clipboard and attachment type utilities live in `ChatClipboardAndAttachmentSupport.swift`.

Chat submission crosses `AppModel.startActiveChatTurn` as an acceptance boundary: the composer clears only after the selected session accepted the turn, and startup/session failures leave the draft and attachments intact. Uncached session selection is likewise transactional in `AppModel+ChatSessions.swift`; only the newest successful load may replace the active transcript. Main and detached chat both render messages through `ChatMessageListView`, so message, tool, approval, retry, timestamp, copy, and read-aloud behavior has one presentation owner.

Chat surface helpers belong in focused `ChatView+*.swift` extensions:

| File | Owns |
|---|---|
| `ChatView+PinnedSessions.swift` | Pinned-session row/loading actions |
| `ChatView+SlashCommands.swift` | Slash-command detection and handling |
| `ChatView+Attachments.swift` | Attachment picking, paste/drop, and preview actions |
| `ChatView+SessionActions.swift` | Session-level UI commands and transcript actions |
| `LivingStatusPanel.swift` | Chat-sidebar Today readout for aggregate organism posture, body state, Desk/approval/dream summary, and user-action status. `needs User` is reserved for canonical pending approvals or nonterminal Desk rows whose exact waiting party is `owner`, `user`, or `human`; failed verification, generic blocks, provider/tool caution, phone/resource trouble, and reflex review remain visible as `no action needed` attention. The panel refreshes from the existing Desk/approval/file and cognition invalidations. |
| `DeskLiveReloader.swift` | Event-driven Workshop invalidation merge: process-local store tokens plus kqueue file watching, trailing-edge coalescing, visibility gating, and reload timing receipts |

`CognitionObservatoryView.swift` owns the Advanced sidebar view for default-off CognitiveSubstrate controls, Organism Kernel visibility/toggle, metrics, capsule preview, reflection receipts, and identity proposal approval/rejection.

`KnowledgeGraphView.swift` is the KnowledgeGraph screen composition surface. Keep graph view state/filtering there and put supporting owners in the focused files:

| File | Owns |
|---|---|
| `KnowledgeGraphStatusHeader.swift` | Native KG stack status probe and header |
| `KnowledgeGraphModels.swift` | KG UI response/entity/edge/search models |
| `KnowledgeGraphView+Maintenance.swift` | Load/enable/GC/forget actions |
| `KnowledgeGraphRows.swift` | Entity/detail/edge rows |
| `KGGraphCanvas.swift` | Graph canvas rendering |

## iOS Companion Map

`iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift` owns iCloud sync state only. `iCloudSyncEngine+Setup.swift` owns setup and the rebuildable CloudKit snapshot/action cache, `iCloudSyncEngine+Snapshots.swift` owns snapshot refresh/loaders, and `iCloudSyncEngine+Actions.swift` owns signed inbox actions, response polling, and Mac-control/provider mutation helpers. `MacSyncEngine` remains the sole snapshot compiler and action dispatcher. Public Developer ID builds carry its exact established snapshot files in five bounded, compressed, digest-checked `NAStatus` groups because they cannot use the Mac-App-Store-only CloudDocuments/KVS lane; iOS atomically adopts those bytes into a local cache without creating another model or authority owner. Legacy builds may retain coordinated Drive files. Signed public action envelopes and responses reuse `BridgeMessage` CloudKit transport, but still pass the inner action HMAC/freshness, exact idempotency, TrustCenter/router, transaction receipt, and signed-response boundaries. A response is durably cached before CloudKit acknowledgement so retry resends evidence rather than repeating an effect. Partial multi-file refreshes preserve last-proven values and cannot advance full-sync freshness. Mac and iPhone use the same `NativeAgentIdentity` pure formatter over their already-authoritative profile projection; the helper owns no identity storage or sync and supplies only bounded configured-name display plus a neutral fallback.

`iOS/NativeAgentMobile/Sources/ChatStore.swift` owns observable chat state and cached-session helpers only. Behavior lives in `ChatStore+Sending.swift`, `ChatStore+Sessions.swift`, `ChatStore+SnapshotMerge.swift`, `ChatStore+ICloudReplies.swift`, `ChatStore+Typewriter.swift`, and `ChatStore+Refresh.swift`. iOS mirrors the Mac send-next contract with a bounded, visible, session-owned in-memory FIFO: natural completion drains it; Stop pauses it; Steer retires the old reply correlations, awaits signed Mac cancellation, and only then runs the promoted turn so late cancellation/final replies cannot stop or overwrite the replacement. While a reply is outstanding and on explicit refresh/foreground events, iOS drains the active transport; it never checks the retired Drive outbox when CloudKit is selected and adds no idle polling. The chat strip contains one current phone-main slot plus the exact ordered `pinned_chat_sessions.json` projection; `source == ios` is session provenance, not a second pin owner. Closing a pinned phone tab sends the signed `unpinChatSession` action, mutates the Mac-owned pin list, and republishes the snapshot without deleting or archiving the conversation.

## Core Runtime Map

`Modules/NativeAgentCore` owns the Swift runtime modules:

| Module | Owns |
|---|---|
| `ChatOrchestration` | Turn engine, session history, turn planning, context assembly, tool loop, dispatch wrappers, same-turn lazy schema refresh, provider-facing tool-result ceilings with turn-scoped recovery paging, dispatch watchdogs, and exact no-progress recovery. One checked admission freezes provider/model/effort/tier for the accepted turn; central streaming/non-streaming paths and actual completion/transcript accounting reuse that tuple rather than mixing routing generations. Canonical user persistence, cognition ingestion, and the compaction check finish before ordinary preparation fans out; deterministic turn planning and one frozen cognition/organism projection may then overlap unchanged Fluid Context/history assembly and active-tool/schema reads. The joined projection remains turn-scoped and commits only after entering provider input; this overlap introduces no cache or authority owner. Dynamic Context remains 6,000 characters in the common case; the shared turn engine permits one coordinator-owned retry only for authoritative mandatory overflow, bounded at 24,000 with ranked-context reserve, so accumulated explicit corrections do not force the much larger legacy reconstruction path and strict callers still fail closed. The same admission compiles route-owned closed tool-group readiness with lexical hints and the exact surface policy before the first provider call; it changes request-scoped schemas only, never durable tool activation or authority. |
| `Context` | Rebuildable immutable context generations, required-document mirrors, bounded RAM arena, generation-checked cancellation-safe event coalescing, owner-selective projection invalidation, eligibility/ranking, feedback/prewarm, and generation-pinned expansion. Cancellation is control flow rather than source degradation. MemoryV2 and Desk/Workshop projections remain derived reads; canonical stores and TrustCenter retain authority. |
| `PersistenceCore` | Canonical append-only local stores plus the single exact eight-pattern digest-bearing secret-redaction contract for durable receipts/activity and the shared non-digest chat/Turn Inspector preview contract, bounded store invalidation tokens, vnode file watching, a bounded `FileChangeEvents` async bridge with one registration-race read, visibility-aware reload debouncing for live projections, and bounded asynchronous TurnTrace emission/persistence pumps. Shared JSONL caps support stat-first soft byte triggers: authority owners may keep every append synchronous and durable while amortizing locked exact-line rotation instead of rereading a growing ledger on every write. Its installed-physiology store is observational evidence only: bounded daily JSONL/rotation and pure reporting, with no prompt/action/permission authority or scheduler. In measurement epoch `resident-live-latency-v3`, event rows require live/system/debug/verification class and separate total, substrate, somatic, and residual-scheduling admission latency. Live+system form the production resident population; live alone forms the ordinary population; diagnostics remain auditable but excluded. Resident and ordinary admission/microcycle populations each require twenty samples and fail at 25 ms or above; ordinary chat latency independently requires twenty live samples. The multi-day gate also rejects retention saturation, quiet CPU at or above 0.5%, and process wake rate at or above 18,000/hour. A fresh compatible `runtime_started` row opens the epoch, retaining older evidence without mixing it into current latency/restart claims. Recorder durability timeout becomes an explicit blocker rather than an unbounded shutdown wait. |
| `Onboarding` | First-run identity/persona creation and reset. Completion is a resumable exact manifest transaction with persona/profile targets first and sentinel last. Public runtime safety treats a pending profile-before-sentinel manifest as incomplete; the narrow legacy compatibility read requires a valid local profile plus every required persona document. Reset has its own exact phased manifest: byte-preserving backups are written and reverified before source removal, completion markers clear only after cleanup, and reset intent clears last. Start/complete/resume reconcile an interrupted reset before exposing or creating onboarding state. |
| `CognitiveSubstrate` | Experimental/default-off active cognitive state infrastructure: bounded events, continuity field, SQLite snapshot/restore, workspace, capsule preview, affect, thought seeds, replay references, reflection receipts, and observatory read model (commitment/prediction task-tracking removed 2026-07-01 — the subconscious is feelings/views/continuity, not a task tracker). Affect and thought-seed reads settle analytically at the requested instant. `CognitiveFrozenRead` captures configuration, workspace, affect, mood, thought seeds, standing-view text, and Sound echo as one immutable evaluation epoch; ordinary chat compiles from that epoch at the same fixed time as its organism projection. Continuity owns rebuildable derived token and defensive-turn-kind indexes, so activation/workspace reads do not repeatedly reclassify every node from prose. Thought-seed score/decay/cap changes replace the exact persisted family and apply protected-family retention in one SQLite transaction. Resident sensory ingestion mutates bounded owner state but defers durability to the coalesced microcycle; that microcycle and larger maintenance use the existing canonical transaction for nodes, seed replacement, affect/ambient settlement, receipts, and pruning. Full maintenance additionally owns emotional consolidation, stale standing views, and lineage; all live mutators serialize at that transition boundary. |
| `ProviderRouting` | OpenAI/Anthropic/Codex/xAI/Moonshot/OpenRouter model routing and streaming adapters. Moonshot owns authenticated live Kimi discovery, K3 Max reasoning, hidden-reasoning preservation through tool loops, streaming, tools, and vision without borrowing another provider's identity or credentials. Surface preferences and active providers publish through one pending-marker recovery transaction; `ProviderRoutingSnapshot` is the checked reconciled read consumed once at every central provider dispatch boundary. GPT-5.6 Sol remains the canonical account default and exact persisted GPT-5.5 routes normalize forward at the execution boundary. |
| `MemoryV2` | SQLite memory store, shared candidate-quality gate, narrow structured-fact auto-save, review proposals, BM25/dense recall with ordinary-fact room ahead of excess skill discovery hints, KG indexing, USER.md projection, and Fluid Context projection source. A purely generated USER body is suppressed from dynamic Context only with exact healthy MemoryV2 parity; manual or malformed content fails back to normal selection. `MemoryStorage` owns the hard 2,000-row canonical bound: direct inserts, proposal acceptance, approved consolidation swaps, and legacy store-open repair prune inside the SQLite write boundary, then retract evicted rows from derived projections and write bounded retention receipts. Approved consolidation is terminal only after retryable canonical rebuild of USER.md, Spotlight, MemoryV2-owned KG claims, and Fluid Context invalidation. |
| `KnowledgeGraph` | SQLite graph/query owner plus exact MemoryV2-derived rebuild: corrected canonical facts and index-version changes retract prior indexer-owned entities, relations, provenance, and index rows while unrelated manual/legacy graph content is preserved. One stable primary-person role reads canonical onboarding `userName` once per index/rebuild/GC operation, exposes generic role labels as aliases, and narrowly consolidates exact legacy role duplicates without inferring identity from prose. Derived counts reset before replay. The deterministic extractor treats inline list markers as sentence boundaries, rejects grammatical negation and acronym-inflected verb fragments, and classifies Apple as an organization without a model call or frequency gate; source-backed facts and meaningful proper/domain concepts remain searchable. A present SQLite graph is the sole read/mutation owner and authoritative even when empty; unreadable SQLite fails closed. Mac panels, chat/MCP tools, and Mac-produced iOS snapshots use checked queries or a bounded complete projection. Legacy JSON is read/mutated only when SQLite is genuinely missing, with one-time import owned by the SQLite loader. |
| `TrustCenter` | Trust policy, SecurityCenter, capability source/root catalogs, strict local signing-key validation, tool risk/autonomy profiles, and canonical normalized conversation-surface classification shared by policy/planning/approval paths. Only missing saved authority may bootstrap defaults; existing corrupt authority remains byte-preserved, unavailable, and fail-closed. SecurityCenter evaluates every tool call and synchronously appends its redacted receipt; its 20,000-row audit cap uses PersistenceCore's 32 MiB stat-first trigger and locked newest-row trim so accumulated history does not impose an O(file) scan on every dispatch. |
| `MacControl` | Full Mac gate, app/file/system control policy helpers, and parent-owned cancellable shell/Spotlight subprocess groups with bounded termination escalation |
| `MCPDispatcher` | MCP registry, live stdio/http calls, strict consent authority, subprocess pool, and value-only `MCPInvocationOutcome` normalization. Only a missing consent ledger is empty; existing unreadable, malformed, duplicate, or oversized authority fails closed before list/grant/revoke and is never rewritten as empty. Raw and one adapter-wrapped protocol errors share one transport interpretation without claiming external effect settlement. |
| `WorkflowOrchestration` | Workflow definitions, runs, approvals, client/engine, committed cancel/rollback watching, and stored per-attempt step deadlines integrated with retry receipts |
| `WorkshopExecution` | Workshop-owned multi-step execution engine for user-directed tasks: planner, checkpoints, executor, Desk lifecycle bridge, storage migration, and unified outcome scoreboard. `WorkshopCompiledLocalFileCopyProcedure.swift` is a value-only deterministic planner target for one locally reviewed read/write shape. Manual invocation is admitted inside `ProcedureArtifactStore.invokeManual`; `WorkshopCompiledProcedureInvocationExecutor` then accepts only the exact planned artifact/contract with zero provider accounting, canonical timeline replay, checked TrustCenter policy, and domain-owned motor verification. Workshop remains the executor, Desk the task owner, ApprovalInbox the review authority, and the procedure store the artifact/receipt owner. Stable caller keys bind idempotency to artifact, paths, and exact bounded source bytes. Resident-runner races are observed through vnode-backed `FileChangeEvents`, not polling. After at least twelve distinct canonical verified zero-provider invocations, an immutable local-only ApprovalInbox decision may install one exact implementation-bound active pointer. `workshop_submit(operation: copy_workspace_file)` consults that pointer only for the unambiguous typed operation; ambiguity, absent/stale/corrupt activation, or pre-admission mismatch falls back to ordinary Workshop, while an admitted invocation never duplicates the effect. The pointer lock spans canonical consequence, and deleting only that pointer restores ordinary routing. This is not a prose router, permission grant, scheduler, generated executable, or general learned selector, and it adds no work to ordinary chat unless Workshop is explicitly invoked. A completed child closes its Desk commitment only with domain-owned `satisfied` verification; unverified completion remains blocked awaiting canonical verification without recruiting a model. |
| `TriggerScheduler` | Canonical trigger/job state plus source invalidations and exact next-meaningful-deadline projection. App background assembly delegates one Core-owned due-work registration; it does not run a detached minute loop. |
| `ApprovalInbox` | Canonical approval safety state. Missing storage is an empty inbox; existing unreadable, malformed, non-array, or malformed-row storage fails closed for list/create/resolve/archive and is never overwritten as empty. |
| `TelegramBot` | Telegram update models, polling, command/client helpers |
| `SystemOps` | Doctor/readiness/system repair/rebuild/git recovery helpers |
| `DreamREMCycle` | Nightly Dream and REM consolidation runners. One Dream invocation gathers all eligible recent conversations under global byte/message/time bounds and performs one bounded consolidation; no per-session provider-call knob remains. |
| `CommandPalette` | Compact command/search/coordination manifest |
| `GitHubConnector` | Keychain-backed GitHub PAT lifecycle with exact-path plaintext migration, typed REST client, authoritative rate-limit-aware GraphQL review-thread observation, compact provider read projections (`GitHubToolProjection`), confirm-gated mutation executor, contribution-scoped project tracking, snapshot cache, Desk reconciliation, and sampled digest |

## Workshop Work Ownership

Workshop is the single work surface. Desk owns canonical work identity and lifecycle; Agent's pursuits and user-directed tasks both appear there. User-directed tasks retain the bounded `WorkshopExecution` multi-step planner/executor rather than being reduced to a one-shot pump job. Terminal execution state is synchronized back to the same Desk item and writes the same Workshop receipt ledger. ContextFlow projects a bounded, secret-checked read of Desk identity/status plus the latest linked child, verification, decision need, and expected evidence. It owns no transitions and rebuilds from exact file events or restart. Completed-but-unverified execution cannot close the Desk commitment.

Active execution state lives under `data/workshop/`: per-task records in `executions/`, trigger configuration/state in `triggers.json` and `trigger_state.json`, legacy flat summaries in `legacy_executions.json`, and unified receipts in `receipts.jsonl`. `WorkshopStorageMigrator` runs synchronously before background loops on launch, moves any remaining `data/missions` state, normalizes migrated absolute receipt pointers, preserves conflicts in a timestamped `data/archive/missions-pre-workshop-*` directory, and writes a migration receipt under `data/workshop/migrations/`. A migration failure aborts startup rather than silently splitting work across two roots. Doctor storage preparation and Trust backups likewise own `workshop`; neither may recreate or back up a live `missions` root.

The old `mission_submit`/`mission_status` chat tools and Missions UI are retired. `workshop_submit` and `workshop_status` are the supported tool surface. A few serialized tokens remain intentionally stable so existing local state survives the cutover: provider/context surface `missions`, trust-policy key `missionPolicy`, approval action `mission.step` with `mission_id`, execution filename `mission.json`, historical activity kinds such as `mission_complete`, and the saved sidebar alias `.missions`. Treat these as compatibility wire IDs, not current product or Swift type names.

The `CognitiveSubstrate` actor implementation is split by cognitive band (move-only R8b decomposition; all files are `extension CognitiveSubstrate` in the same target):

| File | Owns |
|---|---|
| `CognitiveSubstrate.swift` | Actor declaration, stored state, init/configure/ingest/snapshot/restore/persist, shared helpers, and the in-root replay/research band (episodes, schema/identity proposals, developmental timeline, experiments, observatory) |
| `CognitiveSubstrate+Capsule.swift` | Inner-state capsule compilation: capsule lines, felt-emotion and inner-voice cues, capsule fit/scoring, and immutable compilation from a `CognitiveFrozenRead` epoch |
| `CognitiveSubstrate+Reflection.swift` | Reflection request planning with one bounded actor-owned in-flight daily-budget reservation, durable receipts, proposal parsing, and cost/yield scoring |
| `CognitiveSubstrate+Affect.swift` | Affect state update/materialization plus pure analytic projection at an arbitrary read instant, ambient presence, and affect restore/reconcile |
| `CognitiveSubstrate+Workspace.swift` | Workspace microcycle/maintenance, node eligibility, scoring/sort, verification-node eviction, and one-epoch frozen read capture |
| `CognitiveSubstrate+ThoughtSeeds.swift` | Thought-seed add/materialization plus pure analytic priority/expiry projection, suggestions, prioritization, and cap enforcement |
| `CognitiveSubstrate+Serialization.swift` | `toJSON()` encoders for receipt/model types plus session-id helpers |

The Organism Kernel lives under `CognitiveSubstrate/Organism/` and stays default-off until explicitly enabled:

| File | Owns |
|---|---|
| `OrganismModels.swift` | Somatic signal, chemical state, body schema, projection, snapshot, and configuration models |
| `OrganismBodySchema.swift` | Pure body-read merge into BodySchema from bounded app-body reader inputs |
| `OrganismChemistry.swift` | Pure, bounded chemical/body-schema update rules and neutral projection body-line logic |
| `OrganismDreamRepair.swift` | Pure dream/REM field-repair operation planner, bounded repair receipts, contradiction evidence, and summary models. It does not manufacture standing-view proposals; concrete reviewable views remain solely owned by `CognitiveSubstrate+StandingViews.swift` through reflection and explicit resolution |
| `OrganismField.swift` | Pure in-memory organism node/edge plastic field, decay, repair softening, and bounded summaries |
| `OrganismKernel.swift` | Opt-in in-memory organism actor with signal ingest, projection, snapshot, and transient clear; ordinary chat can apply one body sample plus the substrate's same-time canonical affect and return its frozen projection/posture in one actor admission |
| `OrganismPrediction.swift` | Pure in-memory prediction ledger, exact correlation for tool/provider/phone/approval/workflow expectations, prediction-error chemistry nudges, and body-path confidence summaries. Shared provider calls emit payload-free lifecycle IDs; phone notification predictions use canonical device-event IDs and settle only from signed iOS process/scheduler receipts or exact local send failure—never generic health/reachability |
| `OrganismReflex.swift` | Pure in-memory reflex observation and review-candidate compiler with trust classes, approve/hold/permanent-reject transitions, and bounded reviewer receipts |
| `CognitiveSomaticSignalAdapter.swift` | Bounded CognitiveEvent-to-SomaticSignal mapping, redaction, debug/verification filtering |
| `OrganismSignalBus.swift` | SomaticSignalObserving protocol and feature-gated signal forwarding bus |

Trust and security implementation files are split by policy boundary:

| File | Owns |
|---|---|
| `TrustCenter.swift` | Actor state/init, public policy APIs, small decode/merge helpers |
| `TrustCenter+AppAdapter.swift` | App-facing JSON adapter for the Swift-native trust policy |
| `TrustCenter+PolicyModels.swift` | Trust policy wire/status models |
| `TrustCenter+Defaults.swift` | Default policy and fallback chains |
| `TrustCenter+PolicyLoading.swift` | Checked policy load/normalize/merge behavior; missing may bootstrap, while existing corrupt state is unavailable and projects a fail-closed compatibility policy only where a nonthrowing read is unavoidable |
| `TrustCenter+Autonomy.swift` | Tool autonomy lookup, glob matching, timestamp forwarding |
| `SwiftNativeManifestSigner.swift` | Manifest signing, HMAC, canonical JSON, timestamp signing |
| `SecurityCenter.swift` | Origin assessment, allowlists, public evaluation flow |
| `SecurityCenter+Models.swift` | SecurityCenter wire/status models |
| `SecurityCenter+ReceiptJSON.swift` | Receipt JSON serialization |
| `SecurityCenter+ToolProfiles.swift` | Tool risk/profile tables |
| `SecurityCenter+FullMacPolicy.swift` | Full Mac policy checks |
| `SecurityCenter+JSONUtilities.swift` | Shared JSON coercion helpers |
| `SecurityCenter+PathPolicy.swift` | File/path allow/deny policy |
| `SecurityCenter+InputScanning.swift` | Risk input scanning |
| `SecurityCenter+RegistryReceipts.swift` | Registry receipt helpers |

Telegram chat handler/progress contracts live in `TelegramChatHandling.swift`; growing-draft edits live in `TelegramDraftStreamer.swift`; command-menu sync contracts live in `TelegramCommandMenu.swift`; progress-message dedupe state lives in `TelegramProgressMessageState.swift`; `TelegramPollLoop.swift` owns the polling tick/state shell.

Telegram poll-loop behavior belongs in focused extensions:

| File | Owns |
|---|---|
| `TelegramPollLoop+StateReceipts.swift` | State paths, offsets, seen/blocked/error/receipt persistence, command menu sync |
| `TelegramPollLoop+ChatProgress.swift` | Typing heartbeat, progress notices, retry/provider usage notices |
| `TelegramPollLoop+Voice.swift` | Voice transcription notices and attachment parsing |
| `TelegramPollLoop+Media.swift` | Photo/image ingestion and dropped-attachment notices |
| `TelegramPollLoop+Approvals.swift` | Approval slash-command and inline-callback routing |
| `TelegramPollLoop+Commands.swift` | Slash-command dispatch, model callbacks, retry/session command handling |
| `TelegramPollLoop+Transport.swift` | Send/edit/chat-action/default-command transport and chunking |

Telegram command/media helpers are split by their own boundaries: `TelegramBot+Completeness.swift` owns completeness slash commands and dependency registration only; `TelegramMediaAttachment.swift` owns media attachment/download types; `TelegramVoiceTranscription.swift` owns Apple Speech/OpenAI Whisper transcription; `TelegramProgressNoticeChannel.swift` owns cross-surface progress notice plumbing.

`SwiftNativeChatOrchestrationClient` is split by execution concern:

| File | Owns |
|---|---|
| `ChatOrchestrationClient+Bridges.swift` | Bridge-specific chat entry points and surface adapters |
| `ChatOrchestrationClient+Client.swift` | Actor state/init and public chat facades |
| `ChatOrchestrationClient+DispatchWrappers.swift` | Dispatcher wrapper construction and tool-gate adapters |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | Stateless tool-capable turns for non-chat surfaces such as Workshop synthesis |
| `ChatOrchestrationClient+Factories.swift` | Client factories and dependency construction |
| `ChatOrchestrationClient+MessagePersistence.swift` | Chat JSONL/session persistence; validates the shared session index before transcript mutation. A successful canonical regenerate swaps exactly one assistant row under the transcript lock; a missing, duplicate, or non-assistant target fails before any replacement row is written. |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | Compact runtime helper functions |
| `ChatOrchestrationClient+StreamFacade.swift` | `chatStream` facade; signed remote regenerate binds its validated replacement identity inside the stream producer Task so task-local lifetime and transcript replacement remain request-scoped |
| `ChatOrchestrationClient+StructuredChat.swift` | Structured non-streaming/streaming execution |
| `ChatOrchestrationClient+TextCompatibility.swift` | Anthropic text-stream compatibility |
| `ChatOrchestrationClient+ToolDispatching.swift` | Traced/gated dispatcher choke point |
| `ChatOrchestrationClient+Types.swift` | Public response/support types and the current client-owned chat error contract; the retired protocol compatibility shell no longer ships |

`TurnPlanning.swift` owns the cheap per-turn plan used by structured chat before the first model call: router intent/context mode, policy snapshot, meaningful capability ids, resident tool readiness, preload prediction, compact context hinting, metadata-only aggregate `turn.plan` rows, and the smaller `turn.plan.v1` Turn Inspector event. Neither persists raw user text. `SystemOps` may attach only known closed tool groups to its existing route result; `ToolPreloadHeuristics` merges those route facts with lexical evidence, caps the request-scoped preload, and the normal schema/policy filter remains authoritative. The same group definitions now own compact catalog advertisement, category aliases, preload members, and explicit-load compatibility members; the two former `tool_load` switches no longer duplicate that contract. A generic word such as “find” does not imply web research. Production chat no longer computes or records the retired fixed-score metacognitive shadow; the architecture guard rejects reintroduction in structured chat, text-compatible chat, or the turn-plan recorder. The small metacognitive trace vocabulary remains in `ChatOrchestration` because structured turn identity and the OutcomeV2 historical reader consume it, but no production path invokes the shadow evaluator, adds its result to a prompt, or grants it authority. Frozen-mind, provider-transplant, calibration, adaptive-causal, and whole-system evaluation instruments live in the separate `NativeAgentEvaluation` target, which only ChatDrive and tests depend on; the Mac app does not link it. `NativeAgentCore/UserMessageIntentSignals.swift` is the shared pure guard used by SystemOps routing, the Dispatcher compatibility route, and tool preload: explicit tool prohibition is not creation intent, slash-joined prose is not a local path, and communication risk uses exact tokens rather than substrings such as `post` inside `posture`. Explicit tool creation, real path shapes, file nouns/extensions, and actual communication/calendar mutations retain their prior routes and authority gates. `NativeAgentEvaluation/ProviderTransplantEvaluation.swift` is an explicit CLI-only evaluator over frozen nonpersonal fixtures; it constructs no persona, memory, cognition, tool, or action owner and measures strict continuity-contract expression rather than identity. SwiftPM tests are automatically redirected to a process-specific trace root, including factories that explicitly pass the production default. Automatic preload predictions flow through request-scoped `LLMCallContext.turnActiveTools`; only explicit non-redundant `tool_load` writes grow `ActiveToolsStore`. `tool_catalog` returns a compact group/count/readiness view by default; `detail=full` is the schema-heavy diagnostic view. Compatibility aliases remain discovery/load and dispatch compatible without occupying the permanent hot set. `ChatOrchestration+ToolLoop.swift` appends newly authorized schemas after an explicit load before the next provider iteration and preserves existing provider aliases. It bounds provider-facing results to 12,000 UTF-8 bytes for GitHub/blocking delegation or 32,000 for other tools; `ProviderToolResultRecovery.swift` retains an oversized redacted result in owner-only temporary storage and exposes pages of at most 8,000 UTF-8 bytes through the read-only `tool_result_page` tool only to the same session and turn. Full dispatch records keep their existing diagnostic ownership. Every dispatch has a finite recovery backstop (15 minutes for ordinary interactive work, explicit tool timeouts plus cleanup margin, and 65 minutes for unattended work), and an exact same-call/same-result streak warns at eight rounds and stops at sixteen; any changed input or result resets the streak. These controls change transport and recovery behavior, never TrustCenter authorization or tool availability.

Provider output ceilings must cover the provider's complete response, including
hidden/adaptive reasoning and tool arguments. `FirstPartyExecutionControls`
owns Anthropic's model/effort-aware ceiling and empty-output classification for
both API-key and OAuth adapters. A terminal provider stream with neither
answer text nor a tool call is never success; `streamTurn` is the
provider-neutral backstop for legacy/string streaming paths, while structured
native-tool adapters enforce the same invariant before completion. This
boundary is shared by chat surfaces and secondary factories without granting
tools or changing TrustCenter authority.

`Research.swift` is the public research model/protocol/client shell and factory. Research behavior is split by responsibility:

| File | Owns |
|---|---|
| `Research+ActivityTrace.swift` | Activity/trace emission and redaction |
| `Research+Autodetect.swift` | SearXNG discovery and config persistence |
| `Research+Helpers.swift` | Small URL/timestamp helpers |
| `Research+Lab.swift` | Lab-run catalog/execution and brief generation |
| `Research+SearchFetch.swift` | Search/fetch plus HTML/result parsing |
| `ResearchTransports.swift` | URLSession and docker-process transports |

## Tool Dispatcher Map

`SwiftToolDispatcher.swift` is now the state/init/schema-listing shell. Keep it small.

Tool families belong here:

| File | Owns |
|---|---|
| `SwiftToolDispatcher+ToolCatalog.swift` | Built-in tool name groups and always-on core |
| `SwiftToolDispatcher+Dispatch.swift` | Main dispatch switch and routing decisions |
| `SwiftToolDispatcher+SchemaBuilders.swift` | LLM tool schemas and the model-visible MCP boundary. NativeAgent's own MCP compatibility server remains available to raw MCP clients/UI but is not advertised back to the same runtime as duplicate model tools. |
| `SwiftToolDispatcher+ToolImpls.swift` | Basic file/list/write concrete tool implementations |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | Shared JSON/parsing helpers for tool implementations |
| `SwiftToolDispatcher+MemoryTools.swift` | Memory search/commit/proposal tools |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | KG query/status/fact tools |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | Chat/session search tools |
| `SwiftToolDispatcher+DeskTools.swift` | Desk explicit task-tracking tools |
| `SwiftToolDispatcher+WorkshopTools.swift` | Workshop submit/status tools |
| `SwiftToolDispatcher+PersonaTools.swift` | Persona/doc read tools |
| `SwiftToolDispatcher+ToolLoading.swift` | Tool catalog/load state actions; compact catalog is the default group/count/readiness read, `detail=full` exposes model-visible schema rows for diagnostics, and explicit loads remain the only durable active-tool mutation |
| `Dispatcher/Actions/FileSystemActions.swift` | Shared local path resolution for file/git/repo actions; expands `~` before absolute/relative normalization and canonical sandbox validation |
| `SwiftToolDispatcher+ContextTraceTools.swift` | Context/turn trace inspection tools; `recent_trace_summary` reads the current bounded `turn_traces` day ledger and can scope to the injected chat session |
| `SwiftToolDispatcher+SwarmTools.swift` | Swarm/run tools |
| `SwiftToolDispatcher+SkillTools.swift` | Compact installed-skill manifest, one-body lazy read, and canonical conversational save. Discovery delegates to `PersistenceCore/InstalledSkillInventory.swift`; saves delegate to the existing locked `Skills` owner, then reconcile the exact-root MemoryV2 recall pointer through the shared receipt-backed sync. The model never reconstructs registry/body formats, and skill guidance cannot change tool or trust authority. |
| `SwiftToolDispatcher+Sandbox.swift` | Full Mac access checks, sandbox helpers, local connector dispatch |
| `SwiftToolDispatcher+Markets.swift` | Market/TradingView read tools |
| `SwiftToolDispatcher+CloudConnectorTools.swift` | Bounded Gmail, Google Calendar, and Notion reads plus Google refresh-token persistence under the dispatcher's exact data root |
| `SwiftToolDispatcher+MCP.swift` | MCP bridge name parsing and live MCP calls |
| `SwiftToolDispatcher+ExternalConnectors.swift` | Connector-specific helper seams such as X fallback |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `time_now`, `claude_message`, `codex_message`, invoke helpers |
| `SwiftToolDispatcher+SubprocessSupport.swift` | Shared subprocess latches, timeout, bounded pipe buffers |
| `SwiftToolDispatcher+BuilderTools.swift` | shell/bash/git/apply_patch/tests/build/install tool execution; on a fresh Mac with no selected developer directory, the shared Process environment suppresses Apple's interactive Command Line Tools prompt so `/usr/bin` toolchain shims fail honestly instead of opening installer UI |
| `SwiftToolDispatcher+MacIntegration.swift` | Mail/Calendar/Contacts/Music/Scheduler bridge permission wrapper |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | Image generation tool dispatch, provider routing, and artifact receipts |

Do not add a new generic dispatcher if one of these families can own the work.

Mac-local Calendar and Reminders authorization remains owned by
`MacPIMConnectorActions.swift`; `MacIntegrationView.swift` is the explicit
foreground consent surface. Calendar reads require full access, while a pure
event-create path may request Apple's narrower write-only access. Tools can
report `needs_permission` but do not invent a second permission owner. Every
hardened-runtime Mac signing profile must include
`com.apple.security.personal-information.calendars`: macOS TCC otherwise
rejects the Calendar prompt before it writes any authorization row. The release
guard checks source profiles and `verify_release_artifact.sh` checks the
entitlement embedded in the signed app. Public CloudKit packaging additionally
uses `script/lib/provisioning_profile_contract.sh` at both pre-build and mounted
artifact boundaries: the embedded profile must bind the signature team, exact
team-prefixed bundle identifier, exact public container, CloudKit service,
production APNS/CloudKit environments, and an all-devices/no-device-list
Developer ID grant. Because codesign does not copy identity grants out of an
embedded profile, the release derives `com.apple.application-identifier` and
`com.apple.developer.team-identifier` from that validated profile into a
temporary team-specific signing plist; the tracked entitlement template stays
team-neutral. Mounted verification requires those signed values to match the
actual signature team and bundle ID. Codesign, Gatekeeper, and notarization
alone do not prove either the AMFI profile relationship or live CloudKit
initialization authority. TCC, Mac Integration gates,
TrustCenter, approvals, and effect-time validation retain their existing
authority.

## State Ownership

- Memory source of truth: MemoryV2 SQLite under `data/`, plus generated `persona/USER.md`.
- CognitiveSubstrate state is bounded and default-off. Optional persistence lives under `data/cognition/cognition.sqlite` for cognitive nodes/artifacts/receipts only; it must not duplicate MemoryV2 facts, write persona identity, or create a second memory source of truth. `NativeCognitionRuntime` is the only app-owned live assembly gate.
- User-facing memory prose must stay clean. Dates/timestamps belong in metadata unless the date is part of the fact.
- Persona source: `persona/SOUL.md`, `persona/VOICE.md`, `persona/GROWTH.md`, generated `persona/USER.md`, and `persona/skills/bodies/`.
- Chat history: chat JSONL/session stores under app data; session search and continuity recall are lazy. `PersistenceCore/ChatSessionIndexFile.swift` is the strict shared `chat/sessions.json` decoder for mutation boundaries: only a missing file is fresh state, while unreadable, empty, malformed, non-array, or mixed-row files fail closed before Mac, Telegram, Slack, iCloud, retention, message, or backup writers mutate data.
- Turn traces: `PersistenceCore/TurnTracePersistLane` owns `data/turn_traces/<day>.jsonl`; `TurnTraceRecentReader` is the bounded diagnostic reader. Payloads are bounded per leaf and at 12 KiB as a whole; an oversized payload becomes an explicit digest/preview summary that retains lifecycle identity. The daily ledger trims under the append flock from 12 MiB to the newest whole rows fitting 8 MiB, with no polling owner. XCTest/SwiftPM helper processes never write the live lane. The legacy aggregate `data/traces/events.jsonl` remains a separate action/compatibility ledger and is not authoritative for session turn inspection.
- Installed skills: `PersistenceCore/InstalledSkillInventory.swift` merges clean runtime registry entries with runtime bodies and the one resolved canonical persona skill shelf, retaining the stable registry id needed for body resolution. `list_skills`, `read_skill`, pointer sync, the Mac UI, and `capabilities.summary` resolve that same app-only/dev persona root instead of reconstructing it from the data-root parent. `save_skill` reuses `SwiftNativeSkillsClient.createSkill`, then immediately reconciles the dispatcher's exact-root MemoryV2 pointer and writes the shared sync receipt; Mac mutations and launch call the same reconciler. Missing optional shelves remain healthy diagnostics, while existing disabled/draft runtime rows suppress automatic recall. Bodies remain lazy, and no path teaches the model private storage formats or grants guidance any tool/trust authority.
- Desk: `PersistenceCore/DeskStore.swift` owns the append-only hierarchy. Self-authored pursuit origin is the identity-neutral `agent` role; legacy private-name rows decode compatibly but all new/re-encoded writes use `agent`. Terminal parents require terminal descendants, children cannot reopen beneath terminal ancestors, and launch reconciliation repairs older contradictions by appending ordinary `set_status` ops rather than rewriting the op log or `desk_state.json`. Desk and GitHub Command store appends emit process-local invalidation tokens; the Mac Workshop independently watches both canonical ops files through kqueue so out-of-process CLI writes also refresh without polling.
- GitHub Command: `PersistenceCore/GitHubCommandStore.swift` remains the sole append/reducer/state owner. The stored actionable event key binds the desired external condition to canonical GitHub evidence, including GraphQL review-thread identity and unresolved generation. Each dispatch carries that bounded exact evidence and may select only a local checkout whose Git remote matches the target repository; the temporary Codex thread therefore starts in the reviewed repository rather than reconstructing the event from a bare PR number or inheriting NativeAgent's checkout. Repository prose remains explicitly untrusted. Only the trusted `github-command` dispatcher surface plus that verified checkout may mint the internal repository-network capability. The wakeup turn remains `workspaceWrite`/`approvalPolicy=never`, enables public network access, and makes only the checkout and its resolved Git metadata writable; prompt text, topic labels, caller-supplied profile strings, and mixed batches fail closed to the ordinary wakeup policy. The app-server wakeup client still fail-closes dynamic client tools, approval requests, permissions, interactive input, and MCP elicitation because no user is present in that client loop; it returns the blocker to Codex instead of hanging or inventing consent. A Codex completion callback moves work to verification but cannot settle it; the post-callback GitHub reread must remove or replace the exact actionable event, while the same event remains `verification_failed`. An empty terminal turn or overdue callback is outcome-unknown and never authorizes an automatic competing turn. Its optional `causalTransitionEvidence` observes the existing single-pass replay and emits only bounded SHA-256 identities, state names, operation classes, and expected next-evidence classes. It is a read-only offline/shadow projection: no second ledger, write, dispatch, notification, prompt, or authority path.
- Cross-domain causal evidence: `PersistenceCore/CausalTransitionEvidence.swift` is a value-only read contract, not a store or bus. GitHub Command emits it from canonical reducer replay; `WorkshopExecution+CausalTransitionEvidence.swift` maps an already-read execution timeline without copying objectives, step output, receipts, or paths. Unknown domain events remain explicit `domain_specific` evidence. The retired observational transition model and its personal-trace authorization seam do not ship. `NativeAgentEvaluation/CausalOperationalSelfModel.swift` remains a deterministic generated/frozen evaluation instrument only; it has no prompt, provider, tool, memory, action, or installed-control seam and is not linked by the app.
- Shared motor semantics: `PersistenceCore/MotorActionReadModel.swift` provides one read-only phase/verification vocabulary while preserving each reducer's exact bounded `domainState`. GitHub Command, Workshop, Workflow Orchestration, and Browser conform without sharing an executor or authority owner. Browser's Core operation store owns canonical `runs.json`, request-digest idempotency, deadlines, terminal absorption, restart recovery, and retry-safe derived receipt/trace projection; WebKit remains only the app effect adapter. Active and dry-run rows expose opaque cancellation identity through the payload-free motor view, observed WKWebView navigation may satisfy success, legacy success remains unverified, and malformed tokens/timestamps fail loud. Workshop owns an optional durable verification object inside its canonical execution record: exact output criteria and bounded local `write_file` byte read-back may satisfy it, disagreement fails the execution, and unsupported external effects remain explicitly unverified. Verification adds no provider call, scheduler, action authority, or second store. Before a canonical motor projection may re-enter resident physiology, `CognitiveSQLiteStore` admits it through a bounded payload-free replay guard keyed by domain and opaque action identity; exact duplicates and stale/equal-time contradictions are rejected across relaunch, while a strictly newer owner timestamp may correct prior state. This guard has no motor authority and evicts beyond 4,096 distinct actions.
- Tool causal edge: `ChatOrchestration/ToolCausalBoundary.swift` is a pure closed mapping from supported tool aliases and bounded envelope identity keys to existing motor-owner domains. Chat trace classification, OutcomeV2 response anchors, and app consequence observation consume it instead of maintaining independent switches. It owns no dispatch, lifecycle, state, verification, safety, or physiology authority; dry runs never produce a motor reference, and each mapped owner remains the sole source of consequence truth.
- MCP response truth: `MCPDispatcher/MCPInvocationOutcome.swift` is a pure transport classifier for the raw MCP tool-result shape and one exact native/HTTP adapter wrapper. It aligns provider error bits, UI status, traces, and activity receipts, but it is not a settlement model. External MCP responses stay neutral to resident outcome learning until a canonical domain owner supplies verified consequence evidence.
- Adaptive learning gate: `NativeAgentEvaluation/AdaptiveCausalLearningGate.swift` is a pure offline readiness review, not a learner or store. It can reject an evaluation proposal that lacks longitudinal outcome coverage, schema/privacy versions, holdout, drift detection, rollback, or explicit personal-trace approval. NativeAgent currently has no production personal-trace learner, transition-shadow authority, or adaptive reasoning-effort controller.
- Chat UI state: `AppModel` owns per-session persisted messages, tasks, receipts, and committed drafts; `ChatView` and `DetachedChatPanelView` may hold view-local draft text but commit it at acceptance, session-switch, or close boundaries.
- Background-loop state: Core `BackgroundLoopsManager` owns registrations, tasks, single-flight gates, counters, and status. App assembly owns dependency construction only.
- iCloud bridge: signed Mac/iOS outbox/inbox/response files, plus snapshots for cockpit state.
- Notifications/activity/inbox: app-owned ledgers under `data/`; APNS sends through Swift app paths.
- Provider tokens/OAuth state: NativeAgent-owned provider stores under `data/providers/` and connector auth stores. The GitHub PAT is owned by `GitHubCredentialStore` in the macOS Keychain; `connectors/github/auth.json` and `oauth_tokens/github.json` contain non-secret metadata only after read-once migration.
- Data-root construction: defaults exist only at outer production factories.
  Once a provider, context, Browser, TriggerScheduler, Workflow, cognition, or
  Workshop body receives an injected root, that exact standardized root is
  transitive through child stores, telemetry/receipts, RunLedger, memory and
  research clients, OAuth/model caches, provider readiness, and Codex child
  `HOME`/`CODEX_HOME`/`NATIVE_AGENT_DATA_ROOT`. An alternate body must not
  inherit environment API keys, shared OAuth discovery, `~/.codex`, or
  process-global MemoryV2 state; it binds exact-root paths or fails closed.

Do not create parallel `data/persona/Agent`, `data/memory/USER.md`, installer seed copies, second memory stores, or side-channel prompt files.

## Policy Chokepoints

- Trust policy: `TrustCenter`
- Risk classification: `SecurityCenter`
- Full Mac gate: `MacControlGate`
- Chat/tool autonomy: `AutonomyGatedToolDispatcher` owns the single approval
  decision for shared chat composition after exact origin authentication;
  direct/raw app-tool clients retain `AppChatToolDispatcher`'s inner autonomy
  gate, and `SwiftToolDispatcher` retains its access checks. An authenticated
  remote conversation surface inherits Full Mac YOLO for ordinary tools, but a
  surface label alone never establishes trust and hard SecurityCenter exclusions
  such as self-modification, money, and external sends remain authoritative.
- Mac integration permissions: `MacIntegrationPermissionStore`. A missing
  store receives the documented bootstrap defaults; existing unreadable,
  malformed, or wrongly typed known authority is unavailable, byte-preserved,
  and deny-all until repaired. All mutations revalidate under the owner lock.
- Connector truth: connector status/proof gates must prove the account, not just token presence
- External sends and destructive/system-level changes stay deliberate approval boundaries

Do not bypass these from Mac UI, iOS, Telegram, Slack, local bridge, Workshop execution, scheduler jobs, or app-native actions.

## Chat Context Rules

- Stable cache layout is persona/pins plus the current lazy tool
  contract/catalog. Put that prefix before volatile recall, rendered history,
  clock, route, and organism context. Loading/unloading tools intentionally
  changes the stable prefix once; an ordinary user turn does not.
- Append-only message cache markers only reuse repeated calls inside one tool
  loop. Ordinary text-compatible turns construct independent message arrays,
  so cross-turn reuse must come from the stable system breakpoint.
- Dynamic tail may include current time/date, current surface/provider/model, short session continuity, and bounded recent context.
- Durable persona/memory should be lazily loaded and compact.
- Use MemoryV2 recall/KG/session search when needed, not always-loaded bulk.
- Middle-of-session continuity matters: use continuity cards and targeted session search rather than only the last one or two messages.
- Tool results pass through the fast tool gateway and should be compressed into bounded source/hash/preview envelopes when large.

## Background Loops

Background loops are app-owned Swift loops. They belong in `BackgroundLoopsAssembly+*.swift`, the scheduler, or explicit runner modules.

Current loop families include:

- chat surfaces: Telegram, Slack, iCloud/iOS chat
- dreams/memory: nightly dream, REM, hygiene/consolidation
- heartbeat/self-healing: app health and self-improvement checks
- maintenance: snapshots, inbox cleanup, receipts
- Workshop/autonomy: proactive scans and directed-work execution gates

`LoopRunner.tickOutcome()` is the scheduler's truth boundary. Simple loops may
use the default completed outcome, but any loop that catches operational failure
must return `.failed` rather than treating function return as success. The
production scheduler records bounded failure evidence at
`data/logs/background_loop_failures.jsonl`; disabled/not-due work returns a
typed skipped outcome. Token-spending idempotency reservations fail closed on
marker or flock errors.

One schedule should have one canonical owner. Dreams are one 03:30 America/Chicago nightly run for the previous Central calendar day.

The retired cue-authoring lane is absent from the loop manifest, runtime,
provider surfaces, persistence families, and package targets. Legacy cue
receipts and inert node metadata drain idempotently when the cognition store
opens. Do not recreate a model-spending lane unless a current consumer and
acceptance contract first prove it belongs in the resident agent's living path.

## Connector Rules

- A connector is not real because OAuth/token storage exists.
- Non-status actions require a live account/status proof where applicable.
- Gmail, Google Calendar, and Notion expose read-only, bounded lazy tools. Their
  setup state, token proof, and tool dispatch share the exact connector data
  root; nominal write descriptors remain unavailable until a verified effect
  adapter exists.
- Slack is a chat surface with its own provider picker and session behavior.
- Visible Browser is an app-native WKWebView tool surface, not an OAuth connector.
  Core `Browser/runs.json` owns its durable lifecycle through one operation
  reducer. The app asks Core to persist `running` before WebKit starts and keeps
  only a process-local run-ID registry to cancel the matching Task/navigation;
  canonical cancellation is terminal against late capture or completion writes,
  and launch fails stranded prior-process runs as outcome-unknown without
  reopening them. Its shared-motor adapter is read-only and payload-free; even a
  dry run remains nonterminal/cancellable because the canonical owner can still
  transition it to canceled.
- X social connector is separate from xAI OAuth model provider.

## Build And Test Baseline

Use the narrowest relevant check during iteration, then broaden before committing.

```bash
swift build --package-path Modules/NativeAgentShared
swift build --package-path Modules/NativeAgentCore
swift test --package-path Modules/NativeAgentCore --no-parallel
swift build
swift test --filter NativeAgentAppTests
./script/test.sh
./script/smoke_all.sh
./script/install_app.sh
```

For Mac runtime behavior changes, install with `./script/install_app.sh`. For iOS changes, build the iOS project with an installed simulator destination.

## Refactor Rules

- Prefer existing module/file-family ownership over new abstractions.
- Split by real ownership, not line count alone.
- Keep observable stored state centralized unless there is a clear feature-owned state object.
- Do not add duplicate roots, duplicate dispatchers, duplicate schedulers, or duplicate bridge paths.
- Keep public/default builds identity-neutral; local names come from runtime profile/persona/config.
- Update this blueprint when architecture ownership changes.
