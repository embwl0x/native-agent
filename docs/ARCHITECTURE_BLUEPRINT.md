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
`ChatTurnRuntime` owns turn execution; the app and remote surfaces reach that
engine through their adapters.

## Runtime Shape

| Location | Responsibility |
|---|---|
| `Sources/NativeAgentApp/` | SwiftUI app, Mac platform adapters and live engine assembly |
| `Modules/NativeAgentCore/Sources/` | Engine, turn execution, domain stores, tools and policy |
| `Modules/NativeAgentShared/Sources/NativeAgentShared/` | Shared Mac/iPhone declarations |
| `iOS/NativeAgentMobile/Sources/` | iPhone UI and sync adapters |

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
`AppActionRegistry` defines `AppAction` and the `AppActions` registry.
At executor assembly it supplies `AppActionPolicy` flags to TrustCenter;
the peer floor, SecurityCenter and receipt redaction read that projection.
Unregistered non-folded actions require approval. Folded actions keep approval on
their underlying call. Domain capabilities and saved legacy Trust keys remain
TrustCenter policy.
`AgentWorkspace` supplies home's navigation and retained places.

`app {script}` runs JavaScriptCore through `AppScriptRunner`. Its generated
`app.*` calls re-enter the app dispatch path; scripts have no direct filesystem,
network or process API. Script limits and refusal handling live in that owner.

Native executors in `ChatToolRuntime` and `AppToolRuntime` sit behind the app
interface. Their implementation names are not additional model tools.
`ToolNameAliases` maps folded names to actions and produces translated `app`
calls for refusals. `ChatOrchestration+ToolDispatch` rejects folded calls that
the provider request did not offer. Discovery is through `app`, without a
separate tool-loading workflow.

`tool.propose` files an authored tool; `tool.approve` activates it, after which
it is callable as `authored.<id>`. MCP actions use `mcp.<server>.<tool>`.
`AppActionRegistry`, `ToolNameAliases` and `MCPToolBridge` own those mappings.
`Research+CodexSearch` owns `web.search`: general queries try Codex first;
code-shaped queries try SearXNG first. Unfiltered searches try the other route
when the first fails or returns no results, identifying the route and fallback.
Non-general categories and time ranges use only SearXNG because Codex cannot
apply those filters.

## Policy Chokepoints

`TrustCenter` and `SecurityCenter` retain effect-time authority. Full Mac uses
the operator's selected autonomy; macOS privacy-permission resets still require
explicit approval. `PeerTurnEffectPolicy` retains owner approval for
peer-steered deletes/irreversible acts, sends in the owner's name, persona
writes and the protected app approval actions. `ApprovalTransactions` owns the
corresponding approval execution paths. Authenticated turns from agents enabled
in Trust → Connected agents carry User's authority and skip extra peer approvals;
ordinary Trust and domain checks still apply.

## State Ownership

`PersistenceCore` supplies shared JSON/JSONL I/O, durable writers, file locks,
change observation and data-root resolution. Domain stores remain with their
owners: memory in `MemoryV2`, persona compilation in `PersonaEngine`, chat state
in `ChatSessionWork`/`Transcripts`, work in `Desk`, and approvals in
`ApprovalInbox`. The tables point to those implementations rather than
restating their storage formats.

## Background Loops

`BackgroundLoops/BackgroundLoopsManager` owns registration, execution and
status. The app's `BackgroundLoopsAssembly` files construct the concrete loop
registrations and dependencies.

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
| `AgentDisplayName.swift` | `canonicalAgentDisplayName` |
| `AppAttentionDelivery.swift` | `AttentionRouter`: extension |
| `AppDelegate+BackgroundTasks.swift` | `AppDelegate`: `registerBackgroundTaskHandlers` |
| `AppDelegate+ICloudRuntimeForwarding.swift` | `AppDelegate`: `forwardToSwiftRuntime` |
| `AppDelegate+Launch.swift` | `AppDelegate`: `applicationDidFinishLaunching`, `applicationShouldTerminateAfterLastWindowClosed`, `application` |
| `AppDelegate+ProcessLifecycle.swift` | `AppDelegate`: `claimSingleAppInstance`, `presentSingleInstanceWedgedAlert`, `presentPublicReleaseDataRootError` |
| `AppDeviceSyncHost+Connectors.swift` | `AppDeviceSyncHost`: `mobileConnectors`, `setConnectorEnabled`, `disconnectConnector` |
| `AppDeviceSyncHost+Helpers.swift` | `AppDeviceSyncHost`: `helpersSnapshot`, `helperAction`, `agentThreadAction` |
| `AppDeviceSyncHost+Providers.swift` | `AppDeviceSyncHost`: `startProviderSignIn`, `providerSignInStates` |
| `AppDeviceSyncHost+Telegram.swift` | `AppDeviceSyncHost`: `telegramSnapshot`, `changeTelegram` |
| `AppDeviceSyncHost+Trust.swift` | `AppDeviceSyncHost`: `applyMobileTrustAction` |
| `AppDeviceSyncHost.swift` | `AppDeviceSyncHost` struct; `retryRequestedResults`, `getWorkshopExecutions` |
| `AppGitHubOAuthCredentials.swift` | `AppGitHubOAuthCredentials` struct; `saveToken`, `saveOAuthToken` |
| `AppGrokBotConnectionPort.swift` | `AppGrokBotConnectionPort` struct; `ensureRunning`, `send` |
| `AppMacSyncRemoteMacControlPort.swift` | `AppMacSyncRemoteMacControlPort` struct; `loadTrustPolicy`, `run` |
| `AppModel+BaseURLSettings.swift` | `AppModel`: `saveSearXNGBaseURL`, `applyRefreshedSearXNGBaseURL` |
| `AppModel+ChatActions.swift` | `AppModel`: `compactActiveChat`, `clearActiveChatMessages`, `regenerateAssistantMessage` |
| `AppModel+ChatSessions.swift` | `AppModel`: `loadChatState`, `refreshForSidebarItem`, `recordPanelRefresh` |
| `AppModel+ChatState.swift` | `AppModel`: `receiveMacScreenPreview`, `loadDetachedSessionMessages` |
| `AppModel+FirstRunWelcome.swift` | `AppModel`: `firstRunMessages`, `markFirstRunWelcomePending`, `maybeSendFirstRunGreeting` |
| `AppModel+GraphCapabilityActions.swift` | `AppModel`: `searchGraph`, `refreshGraph`, `runResearchLab` |
| `AppModel+HealthEmbeddings.swift` | `AppModel`: `fetchEmbeddingsStatus`, `toggleEmbeddingsBackend`, `setEmbeddingsMemoryMode` |
| `AppModel+MacChatSessionPort.swift` | `AppModel`: `noteChatSessionUserChoice`, `hasCachedChatTranscript`, `containsChatSession` |
| `AppModel+MacChatTurnPort.swift` | `AppModel`: `captureMacWorkContinuation`, `chatHasConversationRows`, `cancelICloudChatTurnForControlHandoff` |
| `AppModel+MemoryActions.swift` | `AppModel`: `pinMemory`, `deleteMemory`, `consolidateMemory` |
| `AppModel+PersonalitySelfImprovement.swift` | `AppModel`: `savePersonality`, `savePersonalityChecked`, `savePersonalityName` |
| `AppModel+ProviderReadiness.swift` | `AppModel`: `missingProviderChatGuidance`, `hasAnyUsableProvider` |
| `AppModel+ProvidersAuth.swift` | `AppModel`: `refreshToolsFromToolbar`, `refreshModelCatalog` |
| `AppModel+Refresh.swift` | `AppModel`: `setIfChanged`, `refreshAll` |
| `AppModel+RoutingWorkflowMCP.swift` | `AppModel`: `search`, `routeIntent` |
| `AppModel+SkillsIntegrations.swift` | `AppModel`: `deleteSkill`, `loadSkillManifests`, `installReviewedSkill` |
| `AppModel+ViewClientOps.swift` | `AppModel`: `resolveApproval`, `getConfig`, `postRaw` |
| `AppModel+WidgetStatus.swift` | `AppModel`: `publishWorkStatus` |
| `AppModel+WorkshopPolicy.swift` | `AppModel`: `refreshSchedulerJobs`, `setSchedulerJobEnabled`, `createDreamJob` |
| `AppQuietSettingsHost.swift` | `AppQuietSettingsHost` class; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `AppQuietToolHost+Mind.swift` | `AppQuietToolHost`: `runMind`, `manageSkill` |
| `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |
| `AppQuietToolPresentation.swift` | `page`, `contextReceiptRead`, `agentViewRead` |
| `AppRelauncher.swift` | `AppRelauncher`: `spawnDetached` |
| `AppSchedulerExecutionPlatform.swift` | `AppSchedulerExecutionPlatform` struct; `postNotification`, `sendTelegramMessage` |
| `AppToolHealthHost.swift` | `AppToolHealthHost` enum; `doctorStatus`, `telegramStatus` |
| `AppToolPlatform.swift` | `AppToolExecutor`: `defaultBrowserActionRunner`, `decideBlockedWorkshopStep`, `macPersonAway` |
| `AppWorkshopPumpPlatform.swift` | `AppWorkshopPumpPlatform` struct; `isUnderResourcePressure`, `artifactIsReadable` |
| `AppWorkshopSessionEffects.swift` | `AppWorkshopSessionEffects` struct; `makeToolDispatcher`, `productionTurnExecutor` |
| `BackgroundLoopsAssembly+Autonomy.swift` | `BackgroundLoopsAssembly`: `trustPolicyPath`, `makeAutonomyPromotionLoop` |
| `BackgroundLoopsAssembly+ChatSurfaces.swift` | `BackgroundLoopsAssembly`: `makeSlackSocketModeLoopIfConfigured`, `makeTelegramPollLoopIfConfigured`, `fileSystemPermissionNotice` |
| `BackgroundLoopsAssembly+Cognition.swift` | `BackgroundLoopsAssembly`: `makeCognitionMaintenanceLoop`, `makeCognitionReplayLoop`, `makeCognitionReflectionLoop` |
| `BackgroundLoopsAssembly+Continuation.swift` | `BackgroundLoopsAssembly`: `makeDeskContinuationScheduler`, `resumeDeskContinuation` |
| `BackgroundLoopsAssembly+Delegation.swift` | `BackgroundLoopsAssembly`: `makeDelegationOutcomeLoop` |
| `BackgroundLoopsAssembly+DeskNotify.swift` | `BackgroundLoopsAssembly`: `makeDeskNotifyLoop` |
| `BackgroundLoopsAssembly+DreamsMemory.swift` | `BackgroundLoopsAssembly`: `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager`, `makeMemoryConsolidationLoop` |
| `BackgroundLoopsAssembly+GitHubTracking.swift` | `BackgroundLoopsAssembly`: `githubTrackingWatchedPaths`, `makeGitHubTrackingLoop` |
| `BackgroundLoopsAssembly+Heartbeat.swift` | `BackgroundLoopsAssembly`: `makeHeartbeatLoop`, `makeSelfHealingHook`, `repairHeartbeatInboxItem` |
| `BackgroundLoopsAssembly+Maintenance.swift` | `BackgroundLoopsAssembly`: `makeAutoDoctorLoop`, `makeTurnTraceRetentionLoop`, `makeOffDiskBackupLoop` |
| `BackgroundLoopsAssembly+TriggerScheduler.swift` | `BackgroundLoopsAssembly`: `makeTriggerSchedulerLoop`, `makeMorningBriefSynthesizer` |
| `BackgroundLoopsAssembly+UnconfiguredLane.swift` | `BackgroundLoopsAssembly`: `unconfiguredLanePlaceholder` |
| `BackgroundLoopsAssembly+Workshop.swift` | `BackgroundLoopsAssembly`: `makeWorkshopPump`, `unattendedWorkAllowed`, `isFullMacPolicy` |
| `BackgroundLoopsAssembly+WorkshopExecution.swift` | `BackgroundLoopsAssembly`: `makeWorkshopExecutor`, `isWideOpenTrust`, `workshopExecutorGate` |
| `BotsEditorSheet.swift` | `BotsEditorSheet` struct |
| `BotsShelfPresentation.swift` | `BotsShelfRailProposal` enum; `destinations`, `everyday` |
| `BotsShelfView.swift` | `BotsShelfView` struct |
| `BrowserWindow.swift` | `NavResult` struct |
| `CapabilitiesView.swift` | `CapabilitiesView` struct |
| `CapabilityProductionHardeningPanel.swift` | `CapabilityProductionHardeningPanel` struct |
| `ChatComposerChrome.swift` | `ComposerTabKeyHandler` struct; `makeNSView`, `updateNSView` |
| `ChatContentCache.swift` | `ChatContentCache` class; `lookup`, `insertIfAbsent` |
| `ChatInlineApprovalCard.swift` | `InlineApprovalPresentation` enum; `state` |
| `ChatMessageListView.swift` | `ChatMessageListView` struct |
| `ChatShellPresentation.swift` | `ChatShellConversationRow`: `isWorking`, `preview`, `isBridgeRouted` |
| `ChatShellViews.swift` | `ShellRoomHeader` struct |
| `ChatSlashCommandMenu.swift` | `SlashCommandMenu` struct |
| `ChatSlashCommandRegistry.swift` | `ChatSlashCommandRegistry` enum; `descriptor`, `helpText` |
| `ChatToolPillView.swift` | `ToolPillPresentation` enum; `outcome`, `title` |
| `ChatView+Attachments.swift` | `ChatView`: `endDictation`, `toggleVoice`, `captureScreen` |
| `ChatView+DetachedSessionMenu.swift` | `ChatView`: `detachedSessionMenu` |
| `ChatView+PinnedSessions.swift` | `ChatView`: `humanPinnedSessionIds`, `savePinnedSessionIds`, `prunePinnedSessions` |
| `ChatView+SessionActions.swift` | `ChatView`: `showToast`, `rename`, `renameActiveChatTitle` |
| `ChatView+ShellColumn.swift` | `ChatView`: `shellSessionHasUnsentWork`, `shellSessionIsPinned`, `shellSessionRow` |
| `ChatView+SlashCommands.swift` | `ChatView`: `send`, `handleSlashCommand`, `dispatchSlashCommandTool` |
| `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` enum; `setUp`, `isComplete` |
| `ComposerContextReceipt.swift` | `ComposerContextReceipt` struct |
| `ConnectorsView.swift` | `ConnectorsView` struct |
| `ClaudeBridge+AgentLive.swift` | `ClaudeBridge`: `installAgentLivePublisher`, `agentLivePayload`, `handleAgentLive` |
| `ClaudeBridge+StandingViews.swift` | `ClaudeBridge`: `standingViewBodyPreview`, `standingViewJSON`, `standingViewListJSON` |
| `ClaudeBridge+StateProjection.swift` | `ClaudeBridge`: `handleState`, `readActivePersona`, `readBridgeActiveSession` |
| `ClaudeBridge.swift` | `ClaudeBridge` class; `eventStreamFrame`, `eventRouteSnapshot` |
| `DeskItemInspector.swift` | `DeskItemInspector` struct |
| `DeskLanePresentation.swift` | `DeskHerHourPresentation` enum; `state`, `symbol` |
| `DeskLiveReloader.swift` | `DeskLiveReloader` class; `trace`, `resolveGlanceVisibility` |
| `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |
| `EventKitPIMStore.swift` | `EventKitPIMStore` class; `authorizationState`, `requestCalendarAccess` |
| `GitHubPlatformPorts.swift` | `GitHubApprovalEdgeNotifier`: extension |
| `ICloudInboxDidProcessRoute.swift` | `ICloudInboxDidProcessRoute` enum; `resolve` |
| `InteractionCardDelivery.swift` | `InteractionCardDelivery` enum; `pointer`, `observe` |
| `KGGraphCanvas.swift` | `KGGraphCanvas` struct |
| `KnowledgeGraphEnableActionPresentation.swift` | `KnowledgeGraphEnableActionPresentation` enum; `buttonControl`, `failure` |
| `KnowledgeGraphRows.swift` | `KGEntityRow` struct |
| `KnowledgeGraphStatusHeader.swift` | `KGNativeStackStatus` struct; `load` |
| `KnowledgeGraphView+Maintenance.swift` | `KnowledgeGraphView`: `loadKnowledgeGraphPolicy`, `reloadKnowledgeGraphPolicyAndGraph`, `loadGraph` |
| `LivingStatusPanel.swift` | `LivingStatusPanel` struct |
| `MacAgentACPProcess.swift` | `MacAgentACPProcess` struct; `spawn`, `finish` |
| `MacAppleScriptBridge+Mail.swift` | `MacAppleScriptBridge`: `mailListRecent`, `mailSearch`, `mailSend` |
| `MacAppleScriptBridge+MailWorkspace.swift` | `MacAppleScriptBridge`: `mailWorkspaceRead`, `mailReadScope`, `mailIndexDatabase` |
| `MacAppleScriptBridge+MessagesNotes.swift` | `MacAppleScriptBridge`: `messagesRecentThreads`, `parseMessagesMetadata`, `messagesSend` |
| `MacAppleScriptBridge+Music.swift` | `MacAppleScriptBridge`: `musicSearchLibrary`, `musicListLibrary`, `musicListPlaylists` |
| `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge`: `runAppleScript`, `isMusicNoCurrentTrackError`, `deniedEnvelope` |
| `MacChatTranscriptSearch.swift` | `MacChatTranscriptSearch` enum |
| `MacControlBridge.swift` | `MacControlBridge` class; `startGateAllows`, `start` |
| `MacControlBridgeProcesses.swift` | `MacControlBridgeProcesses` class; `requestCancellation`, `consumeCancellation` |
| `MacPIMConnectorActions.swift` | `MacPIMConnectorActions` enum; `calendarListUpcoming`, `calendarCalendars` |
| `MacPinnedChatSessionStore.swift` | `MacPinnedChatSessionStore` enum; `normalized`, `decode` |
| `MemoriesPageView.swift` | `MemoriesPageView` struct |
| `MemoryAppIntents.swift` | `QueryMemoryIntent` struct; `perform` |
| `MemoryRepairPresentation.swift` | `AppMemoryRepairPresentation` struct; `ensureInboxCard` |
| `NativeAgentApp.swift` | SwiftUI app and scene declarations; app lifecycle wiring |
| `NativeAgentDesign.swift` | `View`: `settingsCardSurface`, `capsuleTag`, `appShimmer` |
| `NativeAgentDesignTokens.swift` | `Color`: `NativeAgentFont`, `NativeAgentSpacing`, `NativeAgentRadius` |
| `NativeAgentEmbeddingWarmup.swift` | `maybeWarmEmbeddingsForFastMode`, `reconcileMemoryEmbeddingEpochAtLaunch`, `writeReceipt` |
| `NativeAgentEnginePorts+App.swift` | Mac platform-port bindings and construction of `NativeAgentEngine.live` |
| `NativeAgentIntents.swift` | `NativeAgentChatIntent`: `perform`, `reply` |
| `NativeAgentNotificationActions.swift` | `NativeAgentNotificationActions` enum; `register`, `category` |
| `NativeAgentWidgetSnapshot.swift` | `NativeAgentWidgetSnapshot` struct; `status`, `fileURL` |
| `NativeAgentWindowChrome.swift` | `AppRelauncher` enum; `relaunchHelperScript`, `relaunchHelperArguments` |
| `NativeClient+ApprovalExecutors.swift` | `NativeClient`: `memoryHygieneReceipt`, `applyResolvedStudioCanonProposal` |
| `NativeClient+ApprovalTransactionEffects.swift` | `NativeClientApprovalTransactionEffects` struct; `runMemoryHygiene`, `disableSkill` |
| `NativeClient+BrowserRoutes.swift` | `NativeClient`: `runBrowser`, `decodeBrowserRouteRun`, `executeApprovedBrowserRun` |
| `NativeClient+ChatCompaction.swift` | `NativeClient`: `compactSession` |
| `NativeClient+ChatRuntime.swift` | `NativeClient`: `chat`, `chatStream` |
| `NativeClient+ConnectorActions.swift` | `NativeClient`: `runConnectorAction`, `fullMacYoloAdmitted`, `fullMacYoloAuthorityAdmitted` |
| `NativeClient+ConnectorAuthActions.swift` | `NativeClient`: `revokeConnector` |
| `NativeClient+CutoverSeams.swift` | `NativeClient`: `postContextFeedback`, `captureScreenForChat`, `macControlNotify` |
| `NativeClient+DoctorCognition.swift` | `NativeClient`: `doctorCognitionChecks`, `doctorCognitionRepair` |
| `NativeClient+DreamActions.swift` | `NativeClient`: `runDream`, `runRem`, `patchDreamCycleEnabled` |
| `NativeClient+ExportWorkshopInbox.swift` | `NativeClient`: `createProductionExport`, `createSupportBundle`, `createWorkshopTask` |
| `NativeClient+ExternalSendApproval.swift` | `NativeClient`: `applyResolvedExternalSend`, `externalSendReceiptsPath`, `externalSendReceiptIndexPath` |
| `NativeClient+ImprovementOps.swift` | `NativeClient`: `startImprovement`, `createRecurringImprovement`, `runHarnessBenchmark` |
| `NativeClient+Improvements.swift` | `NativeClient`: `runImprovementGauntlet`, `installDemoCapabilityPack`, `installCapabilityPack` |
| `NativeClient+JSONPathSupport.swift` | `NativeClient`: `foundationDictionary` |
| `NativeClient+KnowledgeGraphView.swift` | `NativeClient`: `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData`, `getKnowledgeGraphViewRead` |
| `NativeClient+LocalAPI.swift` | `NativeClient`: `readLocalJSON`, `readJSONObject`, `readAutoDoctorConfig` |
| `NativeClient+MCP.swift` | `NativeClient`: `evaluateMCPUIAdmission`, `callMCPTool`, `warmMCPServer` |
| `NativeClient+MemoryApprovalExecutors.swift` | `NativeClient`: `applyResolvedMemoryRepair`, `reconcileUnappliedMemoryRepairs`, `applyResolvedKindBackfill` |
| `NativeClient+MemoryMutations.swift` | `NativeClient`: `consolidateMemory`, `addMemory`, `postNote` |
| `NativeClient+MemoryPolicyActions.swift` | `NativeClient`: `triggerMemoryConsolidation`, `saveMemoryPolicy`, `patchMemoryPolicy` |
| `NativeClient+NativeActions.swift` | `NativeClient`: `runNativeAction`, `swiftNativeActionRecords`, `nativeActionReceiptsPath` |
| `NativeClient+NextGenActions.swift` | `NativeClient`: `runNextGenAction`, `resolveNextGenAction`, `isNextGenActionBacked` |
| `NativeClient+NextGenStatus.swift` | `NativeClient`: `getNextGenSummary`, `getNextGenPhases`, `getNextGenReceipts` |
| `NativeClient+Notifications.swift` | `Notification`: extension |
| `NativeClient+OnboardingActions.swift` | `NativeClient`: `startOnboarding`, `resumePendingOnboarding`, `completeOnboarding` |
| `NativeClient+ProviderTelegramSessions.swift` | `NativeClient`: `getCompiledPersonality` |
| `NativeClient+ProviderWorkflowGraph.swift` | `NativeClient`: `configureModel`, `configureSurfaceSelection`, `setSurfaceModel` |
| `NativeClient+Providers.swift` | `NativeClient`: `configureProvider`, `testProvider`, `setActiveProvider` |
| `NativeClient+RegistryMutations.swift` | `NativeClient`: `updateSkill`, `deleteSkill`, `archiveSkill` |
| `NativeClient+ResearchOps.swift` | `NativeClient`: `normalizedSearXNGBaseURL`, `searxngBaseURLValidationMessage`, `configureSearXNG` |
| `NativeClient+RuntimeReadAPIs.swift` | `NativeClient`: `makeAppMacAssistantStatusClient`, `getMacAssistantStatus`, `getWorkflows` |
| `NativeClient+SchedulerJobActions.swift` | `NativeClient`: `createJob`, `setSchedulerJobEnabled`, `cancelSchedulerJob` |
| `NativeClient+SelfEvolutionApproval.swift` | `NativeClient`: `selfEvolutionDeps`, `evolutionRepoRoot`, `applyFullMacAdmittedSelfEvolution` |
| `NativeClient+SkillActions.swift` | `NativeClient`: `readSkillRegistry`, `readSkillManifest`, `readSkillReadme` |
| `NativeClient+SwiftRuntime.swift` | `NativeClient`: `_swiftDispatch`, `swiftListMCPConsents`, `_mapMCPConsent` |
| `NativeClient+SystemOpsActions.swift` | `NativeClient`: `runDoctor`, `liveDoctorCoverageChecks`, `safeDoctorDetail` |
| `NativeClient+TelegramOps.swift` | `NativeClient`: `configureTelegram`, `testTelegram`, `clearTelegramLogs` |
| `NativeClient+ToolDispatch.swift` | `NativeClient`: `dispatchToolData`, `_dispatchMissingNativeHandler`, `fileSafeTimestamp` |
| `NativeClient+TrainingActions.swift` | `NativeClient`: `getTrainingRuns`, `getTrainingProposals`, `approveTrainingProposal` |
| `NativeClient+TrustBackupOps.swift` | `NativeClient`: `saveTrustPolicy`, `postTrustWrite`, `applyTrustPolicyPatch` |
| `NativeClient+TrustPolicyActions.swift` | `NativeClient`: `developerModePatchBody`, `saveDeveloperMode`, `saveMultimodalPolicy` |
| `NativeClient+TrustPreset.swift` | `NativeClient`: `saveTrustPreset` |
| `NativeClient+WorkMemory.swift` | `NativeClient`: `getRuns`, `getRunsStrict`, `getPersonality` |
| `NativeClientStatusPlatform.swift` | `NativeClientStatusPlatform` struct; `calendarEventKitReadState` |
| `NativeLoopbackListenerParameters.swift` | `NativeLoopbackListenerParameters` enum; `tcp`, `makeListener` |
| `NativeOAuthLoopbackCallbackServer.swift` | `NativeOAuthLoopbackCallbackServer` class; `wait`, `cancel` |
| `NativeOAuthPlatform+Loopback.swift` | `NativeOAuthPlatform`: `runLoopbackAuthSession` |
| `NativeOAuthPlatform+SessionRunner.swift` | `NativeOAuthPlatform`: `runAuthSession` |
| `NativeOAuthPlatform.swift` | `NativeOAuthPlatform` enum; `makeLoopbackSession`, `openBrowser` |
| `NativeOAuthSessionSupport.swift` | `OAuthSessionBox` class; `set`, `session` |
| `OnboardingWizard.swift` | `OnboardingWizard` struct |
| `PersonalityView.swift` | `PersonalityView` struct |
| `ProviderSettingsComponents.swift` | `ProviderRowView` struct |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `QuietChatSessionVerbs.swift` | `QuietChatSessionVerbs` enum; `run`, `fence` |
| `QuietComposerVerbs.swift` | `QuietComposerVerbs` enum; `state`, `fence` |
| `SimpleShellView.swift` | `SimpleShellView` struct |
| `TriggerNotifierBinding.swift` | `TriggerNotifierBinding` enum; `mirrorNonNotifiedFire`, `makeNotifyingTriggerScheduler` |
| `TrustCenterView.swift` | `TrustCenterView` struct |
| `ViewFileRefreshTask.swift` | `ViewFileRefreshTask` enum; `run` |
| `WorkshopObservatoryPanel.swift` | `WorkshopObservatoryPanel` struct |

### Models

Directory: `Sources/NativeAgentApp/Models/`

| File | Owns |
|---|---|
| `ConfigProviderDoctorModels.swift` | `TrustTrainingPolicy`: `AppConfig`, `AutoDoctorConfig`, `TelegramTestResponse` |
| `ImprovementNextGenModels.swift` | `NextGenReceipt`: `ImprovementGauntletRun`, `GauntletCheck`, `ProductionHardeningSummary` |
| `TolerantDisplayStringDecoding.swift` | `decodeTolerantDisplayString` |

## Core Runtime Map

### ActivityWatch

Directory: `Modules/NativeAgentCore/Sources/ActivityWatch/`

| File | Owns |
|---|---|
| `HumanPresenceStamp.swift` | `HumanPresenceStamp` struct; `url`, `transitionURL` |

### AgentConversations

Directory: `Modules/NativeAgentCore/Sources/AgentConversations/`

ACP agents run as the user and can act directly. Their requested permission
modes are vendor restrictions, not NativeAgent enforcement guarantees;
NativeAgent approval cards cover only requests the agent submits.
`AgentHostConnection.swift` discloses this boundary when connecting an agent.

| File | Owns |
|---|---|
| `AgentACPApproval.swift` | `AgentACPApproval` enum; `renewExecutable`, `request` |
| `AgentBridgeRuntime.swift` | `AgentBridgeRuntime` enum; `codexHelperURL`, `claudeHelperURL` |
| `AgentConversationExchange.swift` | `AgentConversationExchange`: `started`, `absorb`, `validate` |
| `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |
| `AgentConversationLive.swift` | `AgentConversationLive` struct; `projection` |
| `AgentConversationRouting.swift` | `AgentConversationRouting` enum; `route`, `wrap` |
| `AgentConversationRunning.swift` | `AgentConversationRunning` class; `begin`, `end` |
| `AgentConversationSession.swift` | `AgentConversationSession` enum; `approvalRow`, `replayApproval` |
| `AgentConversationStore.swift` | `AgentConversationStore` struct; `records`, `recordsUnlocked` |
| `AgentContactHealth.swift` | Bounded local CLI authentication/version and installed-app probes. Five-minute sampling through the existing delegation continuation; list/home reads and new failures share the same single-flight cache. No agent turns. |
| `AgentConversationView.swift` | `AgentConversationView` enum; `read`, `codingReply` |
| `AgentHostConfigWriter+Goose.swift` | `AgentHostConfigWriter`: `writeGooseEntry`, `removeGooseEntry` |
| `AgentHostConfigWriter.swift` | `AgentHostConfigWriter` enum; `writeEnvironment`, `ensureEnvironment` |
| `AgentHostConnection.swift` | `AgentHostConnection` enum; `builderWorkspaceRoot`, `isNamedConnect` |
| `AgentHostDirectory.swift` | `AgentHostDirectory` enum; `bridgeDiscoveryDirectory`, `peerDescriptorDirectory` |
| `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |
| `AgentMailActions.swift` | `AgentMailActions` enum; `listRecent`, `readMessage` |
| `AgentPeerDiscovery.swift` | `AgentPeerDiscovery` enum; `authenticatedInterface`, `localCandidates` |
| `AgentPeerPolicy.swift` | `AgentPeerPolicy` enum; `peerFailure`, `peerAuthorizeInterface` |
| `AgentPeerStore.swift` | `AgentPeerStore` struct; `list`, `namesMentioned` |
| `AgentPeerTransport.swift` | `AgentPeerCredentials` enum; `resolve`, `isAvailable` |
| `ChatGPTDotIPCTransport.swift` | `ChatGPTDotIPCTransport` enum; `recentSendFile`, `nextPull` |
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
| `AgentACPClient.swift` | `AgentACPClient` actor; `startupTimeoutReceipt`, `turn` |
| `AgentACPExecutable.swift` | `AgentACPExecutable` struct; `capture`, `verify` |
| `AgentACPProcess.swift` | `AgentACPProcess` enum; `installHost`, `spawn` |
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
| `AgentConversationProjection.swift` | `AgentConversationRecord` struct |
| `AgentWorkspace.swift` | `AgentWorkspace` enum; `dispatch` |
| `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback` enum; `dispatchEffect`, `followUp` |
| `AgentWorkspaceActivity.swift` | `AgentWorkspaceActivity` enum; `project`, `today` |
| `AgentWorkspaceApps.swift` | `AgentWorkspaceApps` enum; `quickAction`, `project` |
| `AgentWorkspaceArrivals.swift` | `AgentWorkspaceArrivals` enum; `pending`, `hash` |
| `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: `observationStamps`, `observe`, `bindCurrent` |
| `AgentWorkspaceChanges.swift` | `AgentWorkspaceChanges` enum; `evaluate`, `evaluateHumanListing` |
| `AgentWorkspaceConversation.swift` | `AgentWorkspaceConversation` enum; `project` |
| `AgentWorkspaceConversations.swift` | `AgentWorkspaceConversations` enum; `project` |
| `AgentWorkspaceDesktopNavigation.swift` | `AgentWorkspaceNavigation`: `restoredSession`, `canEvict`, `draftAttemptIsDurable` |
| `AgentWorkspaceDesktopStore.swift` | `AgentWorkspaceDesktopStore` struct; `load`, `save` |
| `AgentWorkspaceEnvironment.swift` | `AgentWorkspaceEnvironment` enum; `isStatusReader`, `title` |
| `AgentWorkspaceFileRevision.swift` | `AgentWorkspaceFileRevision` struct; `prepare` |
| `AgentWorkspaceFind.swift` | `AgentWorkspaceFind` enum; `project` |
| `AgentWorkspaceForm.swift` | `AgentWorkspaceForm` struct; `readingHelperSettings`, `withSchemaIssue` |
| `AgentWorkspaceHumanProjection.swift` | `AgentWorkspaceHumanProjection` enum; `read`, `project` |
| `AgentWorkspaceKnowledge.swift` | `AgentWorkspaceKnowledge` enum; `project`, `memoryTitle` |
| `AgentWorkspaceMail.swift` | `AgentWorkspaceMail` enum; `project` |
| `AgentWorkspaceMessages.swift` | `AgentWorkspaceMessages` enum; `project` |
| `AgentWorkspaceOverview.swift` | `AgentWorkspaceNavigation`: `windowTitle`, `windowAction`, `window` |
| `AgentWorkspacePorts.swift` | `AgentWorkspacePorts` enum |
| `AgentContactState.swift` | Presentation-only Claude/Codex identity aliases, local health observations and exact pull-reply read receipts. Original routes, credentials and transcripts remain separate. |
| `AgentWorkspaceProjection.swift` | `AgentWorkspaceProjection`: `project` |
| `AgentWorkspaceReadiness.swift` | `AgentWorkspaceReadiness` enum; `withSnapshot`, `filter` |
| `AgentWorkspaceSavedReply.swift` | `AgentWorkspaceSavedReply` struct; `title`, `evidence` |
| `AgentWorkspaceWork.swift` | `AgentWorkspaceWork` enum; `desk`, `continuation` |
| `AgentWorkspaceWorkOverview.swift` | `AgentWorkspaceNavigation`: `workReceiptKey`, `placeAction`, `focusWork` |
| `DelegationStatusProjection.swift` | `DelegationDeliveryCache` class; `read` |
| `HerQueue.swift` | `MyQueueReady` enum; `ready`; `HerScreen`: `queueRows`, `resume` |
| `HerScreen.swift` | `HerScreen` enum; `withNames`, `resolve` |
| `HerScreenPreview.swift` | `AgentWorkspaceScreenPreview` enum; `glance`, `render` |
| `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom` |
| `HerScreenRooms+Build.swift` | `HerScreen`: `buildRoom`, `buildTarget`, `buildRecordRoom` |
| `HerScreenRooms+Comms.swift` | `HerScreen`: `sendTrouble`, `roomCounts`, `notConnected` |
| `HerScreenRooms+Core.swift` | `HerScreen`: `familyRoom`, `coreAction`, `coreProjection` |
| `HerScreenRooms+Elsewhere.swift` | `HerScreen`: `doorLines`, `elsewhereRoom`, `elsewhere` |
| `HerScreenRooms+Life.swift` | `HerScreen`: `lifeRoom`, `lifePulse`, `opening` |
| `HerScreenRooms+Web.swift` | `HerScreen`: `tabName`, `tabTitle`, `webTabCell` |
| `HerScreenRooms.swift` | `HerScreen`: `room`, `names`, `screen` |
| `HerWorld.swift` | `HerWorld` struct |
| `HumanConversationIndex.swift` | `HumanConversationIndex` enum; `string`, `object` |
| `MacScreenPreviewBus.swift` | `MacScreenPreviewBus` enum |
| `ResidentWake.swift` | `ResidentWake` class; `request`, `claim`, `take` |
| `StandingBotSchedule.swift` | `StandingBotSchedule` enum; `parse`, `words` |
| `ToolSignature.swift` | `ToolSignature` enum; `call`, `doorArgs` |
| `WorkContextQuery.swift` | `WorkContextQuery` struct; `matchedTerms`, `score` |

### Agents

Directory: `Modules/NativeAgentCore/Sources/Agents/`

| File | Owns |
|---|---|
| `AgentBridgeCompletionRouter.swift` | `AgentBridgeCompletionRouter` enum; `isValidIOSDeviceRouteKey`, `deliverAnswer` |
| `ChatGPTDotConversation.swift` | `ChatGPTDotConversation` actor; `refresh`, `conversation` |
| `CodexCompletionLifecycle.swift` | `CodexCompletionLifecycle` struct; `claim`, `markNotStarted` |
| `ClaudeBridgeDenyDispatcher.swift` | `ClaudeBridgeDenyDispatcher` class; `builtInAgentLaneUsable`, `preApprovalRefusal` |
| `ClaudeBridgeMessageRuntime+AgentLive.swift` | `ClaudeBridgeMessageRuntime`: `agentLiveJobActive`, `handleAgentLive` |
| `ClaudeBridgeMessageRuntime.swift` | `ClaudeBridgeMessageRuntime` class; `handleMessage`, `validGenericAgentMessage` |
| `ClaudeBridgeStateProjection.swift` | `ClaudeBridgeStateProjection` enum; `procedureStatusJSON`, `microcycleTelemetryJSON` |
| `GrokBotConnection.swift` | `GrokBotConnection` enum; `perform`, `result` |
| `GrokBotConnectionPort.swift` | `GrokBotConnectionPort` protocol; `ensureRunning`, `send` |

### AppToolRuntime

Directory: `Modules/NativeAgentCore/Sources/AppToolRuntime/`

| File | Owns |
|---|---|
| `AppActionRegistry.swift` | App action definitions and registry (`AppAction`, `AppActions`); MCP and authored action lookup |
| `AppChatToolDispatcher.swift` | Composed tool dispatch, Security Center admission and settled-result observers |
| `AppScriptRunner.swift` | JavaScriptCore scripts, generated app API, bounded execution and gated call handling |
| `AppToolExecutor+AppDoor.swift` | The `app` schema and home/page/item/find/action/script dispatch |
| `AppToolExecutor+Browser.swift` | `AppToolExecutor`: `runBrowserTool`, `freshChromePage`, `chromeFollowUpAllowed` |
| `AppToolExecutor+ChromeFields.swift` | `AppToolExecutor`: `resolveChromeTarget`, `chromeFields`, `runChromeFieldsCall` |
| `AppToolExecutor+Health.swift` | `AppToolExecutor`: `doctorStatus`, `boundedDoctorDetail`, `doctorStatusEnvelope` |
| `AppToolExecutor+MyQueue.swift` | `AppToolExecutor`: `runMyQueue` |
| `AppToolExecutor+SkillRun.swift` | `AppToolExecutor`: `doorSkill` (skill.run, skill.resume), `doorWouldCard`; `SkillRunStore` |
| `AppToolExecutor+InteractionAct.swift` | `AppToolExecutor`: `cardRefusal`, `runCardAction`, `applyMacControlCategoryGrant` |
| `AppToolExecutor+QuietSelfAdmin.swift` | `AppToolExecutor`: `performMacSelfAppRoute`, `quietPosture`, `freshQuietPosture` |
| `AppToolExecutor+ToolSchemas.swift` | `AppToolExecutor`: `appToolSchemas` |
| `AppToolExecutor.swift` | `AppToolExecutor` class; `defaultReflexReviewerIdentity`, `execute` |
| `AppToolNotificationInput.swift` | `NativeAgentNotificationDefaults`: `parseInput` |
| `AppToolPorts.swift` | `BrowserToolPlatformPort` struct |
| `ChromePageText.swift` | `ChromePageText` enum; `render`, `rows` |
| `NativeActionRoutes.swift` | `NativeActionRoutes` enum; `runNativeAction`, `swiftNativeActionRecords` |
| `NativeAgentNotificationPostResult.swift` | `NativeAgentNotificationPostResult` struct; `deliveryFields` |
| `NativeDispatchFailure.swift` | `NativeDispatchFailure` enum; `missingHandler` |
| `NativeRegistryEvaluation.swift` | `NativeRegistryEvaluation` enum; `appendBoundedRun` |
| `NativeSkillRegistryActions.swift` | `NativeSkillRegistryActions` enum; `updateSkill`, `deleteSkill` |
| `QuietAdminPreferences.swift` | `VoicePreference` enum; `quiet`, `name` |
| `QuietSelfAdminSettings.swift` | `QuietSettingsHostProvider` typealias |
| `QuietSettingsHost.swift` | `QuietSettingsHost` protocol; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |
| `QuietTrustPolicyPreset.swift` | `TrustPolicyPreset` enum |
| `SerialDetachedRelay.swift` | `SerialDetachedRelay` class; `enqueue`, `drain` |

### ApprovalInbox

Directory: `Modules/NativeAgentCore/Sources/ApprovalInbox/`

| File | Owns |
|---|---|
| `ApprovalExecutionAnnotation.swift` | `ApprovalExecutionAnnotation` enum; `annotateApprovalExecution` |
| `ApprovalInbox+InjectionSpend.swift` | `SwiftNativeApprovalInbox`: `consumeInjectionApproval`, `injectionApprovalSpend`, `loadSpends` |

### ApprovalTransactions

Directory: `Modules/NativeAgentCore/Sources/ApprovalTransactions/`

| File | Owns |
|---|---|
| `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects` protocol; `runMemoryHygiene`, `disableSkill` |
| `ApprovalTransactionCoordinator.swift` | `ApprovalTransactionCoordinator` struct; `jsonString`, `memoryHygieneReceipt` |
| `ExternalSendApprovalTransactions.swift` | `ExternalSendApprovalTransactions` enum; `applyResolvedExternalSend`, `externalSendReceiptsPath` |
| `InlineInteractionPlatformPort.swift` | `InlineInteractionPlatformPort` protocol; `probeAppleEventApp`, `mailListRecent` |
| `InlineInteractionResolver.swift` | `InlineInteractionResolver` enum; `takeContinuationHandBack`, `interactions` |
| `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedMemoryRepair`, `reconcileUnappliedMemoryRepairs` |
| `ProcedureExactActivationApproval.swift` | `ApprovalTransactionCoordinator`: `applyResolvedProcedureExactActivation` |
| `SelfEvolutionApprovalReconciliation.swift` | `ApprovalTransactionCoordinator`: `reconcileUnappliedSelfEvolution` |
| `TelegramApprovalCoordinator.swift` | `TelegramApprovalFiler` actor; `fileApprovalRequest`, `awaitResolution` |

### AttentionRouting

Directory: `Modules/NativeAgentCore/Sources/AttentionRouting/`

| File | Owns |
|---|---|
| `AttentionDeliveryPorts.swift` | `AttentionDeliveryPorts` struct |
| `AttentionRouter+RequestedResults.swift` | `AttentionRouter`: `retryRequestedResults`, `deliverRequestedResult` |
| `AttentionRouter.swift` | `AttentionRouter` actor; `delivery`, `allowed` |
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
| `AutonomyBackgroundWork.swift` | `AutonomyBackgroundWork` enum; `trustPolicyPath`, `makeAutonomyPromotionLoop` |
| `BackgroundWorkClients.swift` | `PersonaBackedBackgroundLLMClient` struct; `complete`, `completeMessages` |
| `BackgroundWorkPorts.swift` | `BackgroundWorkEventPort` protocol; `storeAndFileEvents` |
| `ChatSurfaceBackgroundWork.swift` | `ChatSurfaceBackgroundWork` enum; `makeTelegramChatHandler`, `fileSystemPermissionNotice` |
| `DelegationBackgroundWork.swift` | `DelegationBackgroundWork` struct; `makeDelegationOutcomeLoop`, `delegationJobSnapshot` |
| `DeskContinuationScheduler.swift` | `DeskContinuationScheduler` actor; `nextDeadline`, `runDue` |
| `DeskNotifyRunner.swift` | `DeskNotifyRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
| `DreamBackgroundWork.swift` | `DreamBackgroundWork` enum; `stagePendingREMProposalsAtLaunch`, `makeREMProposalStager` |
| `GitHubTrackingBackgroundWork.swift` | `GitHubTrackingBackgroundWork` enum; `githubTrackingWatchedPaths`, `makeGitHubTrackingLoop` |
| `HeartbeatBackgroundWork.swift` | `HeartbeatBackgroundWork` struct; `makeHeartbeatLoop`, `makeSelfHealingHook` |
| `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |
| `InboxRewriteGuard.swift` | `InboxRewriteGuard` enum; `readLines`, `writeLines` |
| `MaintenanceBackgroundWork.swift` | `MaintenanceBackgroundWork` struct; `makeAutoDoctorLoop`, `makeTurnTraceRetentionLoop` |
| `MemoryConsolidationHygieneRunner.swift` | `MemoryConsolidationHygieneRunner` struct; `tick`, `tickOutcome` |
| `TelegramBackgroundBridges.swift` | `TelegramAccountModelCatalogPort` struct |
| `TriggerSchedulerBackgroundWork.swift` | `TriggerSchedulerBackgroundWork` enum; `makeJobWork`, `makeMorningBriefSynthesizer` |
| `UnconfiguredBackgroundLane.swift` | `UnconfiguredBackgroundLane` enum; `unconfiguredLanePlaceholder` |
| `WorkshopBackgroundWork.swift` | `WorkshopBackgroundWork` enum; `makeWorkshopExecutor`, `unattendedWorkAllowed` |
| `WorkshopExecutorDrainRunner.swift` | `WorkshopExecutorDrainRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |
| `WorkshopPumpLoopRunner.swift` | `WorkshopPumpLoopRunner` struct; `physiologyEvents`, `nextMeaningfulDeadline` |

### Browser

Directory: `Modules/NativeAgentCore/Sources/Browser/`

| File | Owns |
|---|---|
| `BrowserActionRoutes+NativeActions.swift` | `BrowserActionRoutes`: `runBrowserNativeAction`, `stringInput` |
| `BrowserActionRoutes.swift` | `BrowserActionRoutes` struct; `observeBrowserMotorAction`, `runBrowser` |
| `BrowserLink.swift` | `BrowserLink` struct |
| `BrowserRouteEffects.swift` | `BrowserRouteEffects` protocol; `beginNavigation`, `cancelNavigation` |
| `BrowserRouteModels.swift` | `BrowserRun` struct |

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
| `CarriedAnchorRecollection.swift` | `CarriedAnchorRecollection` enum; `isEnabled`, `seeded` |
| `ChatCompactionBackupRetention.swift` | `ChatCompactionBackupRetention` enum; `enforce` |
| `ChatCompactionDistiller.swift` | `ChatCompactionDistiller` struct; `maxSummaryChars`, `thirdPersonSubjectCount` |
| `ChatSecretRedactor.swift` | `ChatSecretRedactor` typealias |
| `ChatSessionAgingConsolidation.swift` | `ChatSessionAgingConsolidation` struct; `scheduleTranscriptAgingIfNeeded`, `runTranscriptAging` |
| `ChatSessionAutocompactor.swift` | `ChatSessionAutocompactor` struct; `compactIfNeeded`, `pruneCompactBackups` |
| `ChatSessionDirective.swift` | `ChatSessionDirective` enum; `safeComponent`, `recordURL` |
| `ChatSessionIndexReconciler.swift` | `ChatSessionIndexReconciler` actor; `reconcile` |
| `ChatSessionLockSidecarCleanup.swift` | `reapOrphanedChatSessionLockSidecars` |
| `ChatToolOutcome.swift` | `ChatToolOutcome` enum; `errorMessage`, `exactResultClass` |
| `ChatTranscriptEvidenceRendering.swift` | `ChatTranscriptEvidenceRendering` enum; `recordedPendingToolStatus`, `recordedToolStatus` |
| `ChatTranscriptToolMessageKind.swift` | `ChatTranscriptToolMessageKind` enum; `pendingApprovalID`, `pendingApprovalReason` |
| `ContextBudgetPolicy.swift` | `ContextBudgetPolicy` enum; `compactionHistoryCharacters`, `floors` |
| `HistoryWindowCursor.swift` | `HistoryWindowCursor` struct |
| `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore` struct; `record`, `recordConversationContinuation` |
| `OutcomeTissueV2.swift` | `OutcomeEvidenceState` enum |
| `OutcomeTraceIdentity.swift` | `OutcomeTraceIdentity` enum; `normalized` |
| `SessionDigestProvider.swift` | `SessionDigestProvider` struct; `pointerSentence`, `digest` |
| `SessionHistoryMessageProjection.swift` | `SessionHistoryMessageProjection` enum; `admission`, `project` |
| `SessionHistoryPromptRenderer.swift` | `SessionHistoryPromptRenderer` enum; `renderDetailed`, `recallQuery` |
| `SessionHistoryReader.swift` | `SessionHistoryReader` actor; `messages`, `messagesWithStats` |
| `TurnVolatileArchive.swift` | `TurnVolatileArchive` actor; `load`, `record` |

### ChatToolParsing

Directory: `Modules/NativeAgentCore/Sources/ChatToolParsing/`

| File | Owns |
|---|---|
| `ToolCallParser.swift` | `ToolCallParser` enum; `parse`, `throughLastToolMarker` |

### ChatToolRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatToolRuntime/`

| File | Owns |
|---|---|
| `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding` enum; `pending`, `glance` |
| `AppRestartCoordinator.swift` | `AppRestartCoordinator` actor; `configure`, `relauncherArgv` |
| `BotChatContract.swift` | `BotChatContract` struct; `checked` |
| `BotRunConversation.swift` | `BotRunConversation` enum; `enqueueRequestedCheck`, `dispatch` |
| `BuilderWorktreeAllocator.swift` | `BuilderWorktreeAllocator` actor; `resolve`, `bind` |
| `BuiltInToolSchemaFactory+AgentCommunication.swift` | `BuiltInToolSchemaFactory`: `agentCommunicationSchemas` |
| `BuiltInToolSchemaFactory+CoreSchemas.swift` | `BuiltInToolSchemaFactory`: `coreSchemas` |
| `BuiltInToolSchemaFactory+Descriptions.swift` | `BuiltInToolSchemaFactory`: extension |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |
| `BuiltInToolSchemaFactory+StandingBots.swift` | `BuiltInToolSchemaFactory`: `standingBotSchemas` |
| `BuiltInToolSchemaFactory.swift` | `BuiltInToolSchemaFactory` struct; `requestedSchema`, `obj` |
| `CanonicalToolNameDispatcher.swift` | `CanonicalToolNameDispatcher` class; `canonical`, `dispatch` |
| `ChatFullMacYoloAdmission.swift` | `ChatFullMacYoloAdmission` enum; `admitted` |
| `ChatToolDispatchTrace.swift` | `ChatToolOutcome`: `normalizedFailure`, `failure`, `outputLooksSuccessful` |
| `ChatToolJSONRedaction.swift` | `ChatToolJSONRedaction` enum; `injectionRedactedArgJSON`, `injectionRedactedResultJSON` |
| `ChatToolRuntimeImports.swift` | Re-exports `ChatTurnContracts`, `AgentConversations`, `AgentWorkspace`, `ChatSessionWork`, `ChatToolParsing` |
| `ChatToolSessionInjection.swift` | `ChatToolSessionInjection` enum; `apply` |
| `CodexImageGenerationControls.swift` | `CodexImageGenerationRequest`: `normalizedForBuiltIn`, `normalized` |
| `CodexImageGenerationHelp.swift` | `CodexImageGenerationHelp` enum |
| `CompactActionReceipt.swift` | `CompactActionReceipt` struct; `toJSONValue`, `toolDispatch` |
| `ExternalSendApprovalLifecycle.swift` | `ExternalSendApprovalLifecycle` enum; `executeAdmittedYoloToolResult`, `stage` |
| `FluidContextToolScope.swift` | `FluidContextToolScope` enum |
| `GitHubCommandCheckoutResolver.swift` | `GitHubCommandCheckoutResolver` enum; `resolve` |
| `InlineInteractionModelOverride.swift` | `InlineInteractionModelOverride` enum; `binding` |
| `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |
| `InlineInteractionRegistry.swift` | `InlineInteractionRegistry` enum; `connectorSetup`, `canonicalConnectorID` |
| `MCPToolCatalogWarmer.swift` | `MCPToolCatalogWarmer` actor; `kickDetached`, `kickIfDue` |
| `MemoryRecallPersonaFilter.swift` | `memoryRecallPersonaFilter` |
| `PeerDataTaintDispatcher.swift` | `PeerDataTaintDispatcher` class; `dispatch`, `peerLine` |
| `ProviderToolResultRecovery.swift` | `SwiftToolDispatcher`: `impl_tool_result_page` |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: `drivenAgentLaunch`, `drivenAgentContact`, `stampDelegationProducer` |
| `SwiftToolDispatcher+AgentCommunication.swift` | `SwiftToolDispatcher`: `closeACPConnections`, `builtInAgentLaneUsable`, `impl_agentCommunication` |
| `SwiftToolDispatcher+ArtifactContext.swift` | `SwiftToolDispatcher`: `impl_artifact_find` |
| `SwiftToolDispatcher+BuilderTools.swift` | `SwiftToolDispatcher`: `builderSourceRepoRoot`, `builderWorkspaceRoot`, `builderAllowedRoots` |
| `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage`, `dotAwaitsReply` |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | `SwiftToolDispatcher`: `impl_search_chat_history`, `impl_read_chat_message` |
| `SwiftToolDispatcher+CloudConnectorTools.swift` | `SwiftToolDispatcher`: `impl_gmail_status`, `impl_gmail_search`, `impl_gmail_read` |
| `SwiftToolDispatcher+CodexBridgeTools.swift` | `SwiftToolDispatcher`: `codexBrainControls`, `agentBridgeReplyOrigin`, `runCodexMessage` |
| `SwiftToolDispatcher+ContextTraceTools.swift` | `SwiftToolDispatcher`: `impl_context_lookup`, `impl_scratchpad_read`, `impl_recent_trace_summary` |
| `SwiftToolDispatcher+ClaudeBridgeTools.swift` | `SwiftToolDispatcher`: `runClaudeMessage`, `claudeReceiptStatus`, `markWakeStartedNothing` |
| `SwiftToolDispatcher+DelegationTools.swift` | `SwiftToolDispatcher`: `impl_delegation_status`, `delegationStatusLimit`, `delegationStatusOffset` |
| `SwiftToolDispatcher+DeskTools.swift` | `SwiftToolDispatcher`: `deskAlias`, `impl_desk_read`, `impl_desk_add_item` |
| `SwiftToolDispatcher+DesktopPixels.swift` | `SwiftToolDispatcher`: `desktopPixelsRequested`, `desktopPixels` |
| `SwiftToolDispatcher+Dispatch.swift` | `SwiftToolDispatcher`: `withWebScheme`, `dispatch`, `preApprovalRefusal` |
| `SwiftToolDispatcher+DreamDiaryTools.swift` | `SwiftToolDispatcher`: `impl_dream_diary_read`, `dreamDiaryEntryJSON`, `dreamDiaryStorageFields` |
| `SwiftToolDispatcher+ExternalConnectors.swift` | `SwiftToolDispatcher`: `xConnectorWithOAuthFallback` |
| `SwiftToolDispatcher+FourVerbPerception.swift` | `MacVisualWindowRecord` struct |
| `SwiftToolDispatcher+HumanConversations.swift` | `HumanConversationSnapshot` struct |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | `SwiftToolDispatcher`: `impl_image_generate`, `showGeneratedImages`, `imageGenerationReferences` |
| `SwiftToolDispatcher+InlineInteraction.swift` | `SwiftToolDispatcher`: `impl_request_interaction` |
| `SwiftToolDispatcher+InnerStateTools.swift` | `SwiftToolDispatcher`: `impl_inner_state`, `innerStateRawWindowHours`, `innerStateWindowHours` |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`: `impl_search_kg`, `kgSeenDate` |
| `SwiftToolDispatcher+MCP.swift` | `SwiftToolDispatcher`: `parseMCPToolName`, `forwardedMCPArguments`, `impl_mcp_tool` |
| `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |
| `SwiftToolDispatcher+MacIntegration.swift` | `SwiftToolDispatcher`: `dispatchMacIntegrationTool` |
| `SwiftToolDispatcher+Markets.swift` | `SwiftToolDispatcher`: `impl_market_status`, `impl_market_watchlists`, `impl_tradingview_watchlist` |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |
| `SwiftToolDispatcher+MemoryTools.swift` | `SwiftToolDispatcher`: `cappedRecallK`, `recallHitsJSON`, `provenanceMetadata` |
| `SwiftToolDispatcher+MomentTools.swift` | `SwiftToolDispatcher`: `impl_memory_moments_pending`, `impl_memory_moment_review` |
| `SwiftToolDispatcher+OMPBridgeTools.swift` | `SwiftToolDispatcher`: `runOMPMessage`, `ompSessionSaved` |
| `SwiftToolDispatcher+PersonaTools.swift` | `SwiftToolDispatcher`: `impl_get_persona_doc`, `impl_persona_read`, `impl_persona_write` |
| `SwiftToolDispatcher+RemoteNodes.swift` | `SwiftToolDispatcher`: `impl_remote_node_list`, `impl_remote_node_execute` |
| `SwiftToolDispatcher+Sandbox.swift` | `SwiftToolDispatcher`: `resolveSandboxed`, `stringArray`, `normalizeFullMacPathArgument` |
| `SwiftToolDispatcher+SchemaBuilders.swift` | `SwiftToolDispatcher`: `modelVisibleMCPTools`, `modelVisibleMCPToolNames`, `modelVisibleToolNames` |
| `SwiftToolDispatcher+SkillTools.swift` | `SwiftToolDispatcher`: `impl_list_skills`, `impl_read_skill`, `impl_save_skill` |
| `SwiftToolDispatcher+StandingBots.swift` | `SwiftToolDispatcher`: `standingBotApprovalReason`, `standingBotsArgumentRefusal`, `impl_standingBots` |
| `SwiftToolDispatcher+StandingViewTools.swift` | `SwiftToolDispatcher`: `impl_hold_view`, `impl_release_view` |
| `SwiftToolDispatcher+StudioCanonTools.swift` | `SwiftToolDispatcher`: `impl_studio_canon`, `impl_studio_canon_resolve` |
| `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`: `impl_studio_shelf`, `studioImageInvitation`, `impl_studio_consult` |
| `SwiftToolDispatcher+SubprocessSupport.swift` | `SwiftToolDispatcher`: `armSubprocessTimeout`, `interruptThenTerminate`, `reapLaunchedTree` |
| `SwiftToolDispatcher+SwarmTools.swift` | `SwiftToolDispatcher`: `impl_agent_swarm` |
| `SwiftToolDispatcher+ToolCatalog.swift` | Internal executor inventory, model visibility and the single `app` always-on floor |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: `optionalNumber`, `jsonString`, `jsonInt` |
| `SwiftToolDispatcher+ToolImpls.swift` | `SwiftToolDispatcher`: `requireNonSensitiveReadPath`, `impl_read_file`, `fileReadPresentation` |
| `SwiftToolDispatcher+ToolManifest.swift` | `SwiftToolDispatcher`: `toolManifest` |
| `SwiftToolDispatcher+WorkContext.swift` | `SwiftToolDispatcher`: `impl_work_context`, `workContextDeskItem`, `boundedWorkContextValue` |
| `SwiftToolDispatcher+WorkshopTools.swift` | `SwiftToolDispatcher`: `impl_workshop_submit`, `impl_workshop_status`, `impl_task_ledger_post` |
| `SwiftToolDispatcher+WorkspaceDesk.swift` | `SwiftToolDispatcher`: `workspaceDesk` |
| `SwiftToolDispatcher.swift` | Native dispatcher construction and built-in, registry and MCP schemas |
| `ToolCausalBoundary.swift` | `ToolCausalBoundary` enum; `hasCanonicalMotorOwner`, `motorReference` |
| `ToolResultSections.swift` | `ToolResultSections` enum; `pages` |
| `WorkshopSynthesizeToolDispatcher.swift` | `WorkshopSynthesizeReadOnlyToolDispatcher` struct; `dispatch`, `listAvailableTools` |

### ChatTurnContracts

Directory: `Modules/NativeAgentCore/Sources/ChatTurnContracts/`

| File | Owns |
|---|---|
| `ChatApprovalContracts.swift` | `AutonomyDecision` enum |
| `ChatPersistenceContext.swift` | `ChatPersistenceContext` enum |
| `ChatToolBridges.swift` | `PureToolArgumentValidating` protocol; `argumentRefusal` |
| `ChatToolSessionContext.swift` | `ChatToolSessionContext` enum; `rendersInlineCards`, `withReplyRoute` |
| `ChatTurnExecution.swift` | `ChatTurnExecution` class; `bindHistoryRunID`, `keepCapabilityNote` |
| `PeerDataTaint.swift` | `PeerDataTaint` class; `withScope`, `markConsumed` |
| `SwarmChatClientFactory.swift` | `SwarmChatClientFactory` protocol; `makeClient` |
| `ToolDispatchRecord.swift` | `ToolDispatchRecord` struct |
| `ToolNoticeBus.swift` | `ToolNoticeBus` enum |
| `ToolTurnContracts.swift` | `ToolDispatchClient`: `dispatch`, `listAvailableTools`, `listAvailableToolSchemas` |
| `TurnToolSchemaCatalogSeed.swift` | `TurnToolSchemaCatalogSeed` struct |

### ChatTurnRuntime

Directory: `Modules/NativeAgentCore/Sources/ChatTurnRuntime/`

| File | Owns |
|---|---|
| `AgentConversationsExports.swift` | Re-exports `AgentConversations` |
| `AgentWorkspaceExports.swift` | Re-exports `AgentWorkspace` |
| `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop` |
| `ChatOrchestration+SessionHistory.swift` | `SwiftNativeTurnEngine`: `buildTurnContextWithHistory`, `fireAssemblyStageEvent`, `injectingSessionDigest` |
| `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody`, `joinedProse` |
| `ChatOrchestration+ToolDispatch.swift` | Shared per-iteration tool dispatch and refusal of unoffered folded calls |
| `ChatOrchestration+ToolLoop.swift` | `TurnContext`: `withToolSchemas` |
| `ChatOrchestration+TurnEngine.swift` | `SwiftNativeTurnEngine`: turn context preparation and provider execution |
| `ChatOrchestrationClient+Attachments.swift` | `SwiftNativeChatOrchestrationClient`: `imageBlocksFromAttachments`, `multimodalPolicyAllows`, `turnAttachmentInput` |
| `ChatOrchestrationClient+Client.swift` | `SwiftNativeChatOrchestrationClient` actor; `drainDeferredMemoryPromotion`, `chat` |
| `ChatOrchestrationClient+DispatchWrappers.swift` | `FileAccessGatedDispatcher` class; `preApprovalRefusal`, `approvalCardReason` |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn` |
| `ChatOrchestrationClient+Factories.swift` | `complete`, `makeChatOrchestrationClient`, `makeGatedToolDispatchClient` |
| `ChatOrchestrationClient+HumanConversationReply.swift` | `SwiftNativeChatOrchestrationClient`: `appendHumanConversationReply` |
| `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`: `reportTranscriptWriteFailure`, `persistPartialIfNeeded`, `appendToolMessage` |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | `SwiftNativeChatOrchestrationClient`: `personaFingerprint`, `contextFingerprint`, `iso8601` |
| `ChatOrchestrationClient+StreamFacade.swift` | `SwiftNativeChatOrchestrationClient`: `chatStream`, `chatStreamExecution` |
| `ChatOrchestrationClient+StructuredChat.swift` | `SwiftNativeChatOrchestrationClient`: `emitMetacognitiveTerminalTrace`, `emitTurnFailedTrace`, `emitTurnCancelledTrace` |
| `ChatOrchestrationClient+ToolDispatching.swift` | `SwiftNativeChatOrchestrationClient`: `makeTracedGatedDispatcher` |
| `ChatOrchestrationClient+ToolReceipts.swift` | `SwiftNativeChatOrchestrationClient`: `persistToolReceipt` |
| `ChatOrchestrationClient+Types.swift` | `ChatOrchestrationClient` protocol; `drainDeferredMemoryPromotion`, `enqueueUserMessage` |
| `ChatSessionWork.swift` | Re-exports `ChatSessionWork` |
| `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |
| `ChatToolRuntime.swift` | Re-exports `ChatToolRuntime`, `ChatTurnContracts` |
| `ChatTurnExecution.swift` | `SwiftNativeChatOrchestrationClient`: `chat` |
| `ChatWrittenFileArtifacts.swift` | `ChatWrittenFileArtifacts`: whole-file receipt selection and canonical recovery references |
| `ConversationPrefixSeeding.swift` | `ConversationPrefixSeeding` enum; `isOpenAIResponsesLane`, `delivery` |
| `FirstRunWelcomeTransaction.swift` | `FirstRunWelcomeTransaction` class; `hasConversationRows`, `isPersistedFailureRow` |
| `HerScreenPreview.swift` | `HerScreenPreview` enum; `glance`, `render` |
| `InjectionApprovalVerifier.swift` | `ApprovalInboxInjectionApprovalVerifier` struct; `verifyInjectionApproval` |
| `MacChatRetrySnapshot.swift` | `MacChatRetrySnapshot` struct; `capture`, `stillMatchesLocal` |
| `MacChatSessionTransactions.swift` | `MacChatSessionTransactions` class; `existingMainSession`, `create` |
| `MacChatStreamAccumulator.swift` | `ChatStreamAccumulator` actor; `consume` |
| `MacChatStreamAdapter.swift` | `MacChatStreamAdapter` enum; `stream`, `bridgeChatStreamEvents` |
| `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |
| `MacChatTurnAdmission.swift` | `MacChatTurnPresentationPort`: `rejectMacChatTurn`, `startChatTurn`, `stopChatStream` |
| `MacChatTurnLifecycle.swift` | `MacChatTurnTerminalEvidence` enum |
| `MacChatTurnLifecycleIntake.swift` | `MacChatTurnPresentationPort`: `beginChatTurnLifecycle`, `applyChatTurnLifecycleInput`, `receiveChatTurnActivity` |
| `MacChatTurnPresentationPort.swift` | `MacChatTurnPresentationPort` protocol; `chatHasConversationRows`, `captureMacWorkContinuation` |
| `MacChatTurnRetry.swift` | `MacChatTurnPresentationPort`: `admitMacChatRetry`, `runAdmittedMacChatRetry`, `settleMacChatRetry` |
| `MacChatTurnRuntime.swift` | `MacChatTurnRuntime` class; `runAdmittedTurn`, `lifecycle` |
| `MacChatTurnStreamConsumer.swift` | `MacChatTurnPresentationPort`: `consumeMacChatStream` |
| `MacChatTurnStreamSettlement.swift` | `MacChatTurnPresentationPort`: `completeMacChatStream`, `joinFailedMacChatStream`, `settleMacChatStream` |
| `MindMemoryManager.swift` | `MindMemoryManager` struct; `interpret` |
| `OutcomeTissueV2.swift` | `ResponseOutcomeObservationV2`: `make` |
| `ParallelToolDispatch.swift` | `ParallelToolDispatch` enum; `isSerialFallbackForced`, `isParallelSafe` |
| `StandingBotContinuity.swift` | `StandingBotContinuity` enum; `session`, `reply` |
| `SwarmChatClientFactory.swift` | `NativeSwarmChatClientFactory` struct; `makeClient` |
| `SwiftToolDispatcherConstruction.swift` | `SwiftToolDispatcher`: extension |
| `TextMarkerCodec.swift` | `TextMarkerCodec` struct; `calls`, `throughLastMarker` |
| `ToolLoopSupport.swift` | `TurnEngineResult`: `ToolLoopTraceObservation`, `ToolLoopExhausted`, `ToolLoopExhaustion` |
| `TurnEngineContracts.swift` | `MemoryRecalling`: `recall`, `recordServedContextHits` |
| `TurnSettle.swift` | `TurnSettle` enum; `requestedResultIntent`, `isWaitingOnCard` |

### ChromeControl

Directory: `Modules/NativeAgentCore/Sources/ChromeControl/`

| File | Owns |
|---|---|
| `ChromeControlRuntime.swift` | `ChromeControlRuntime` actor; `connectionStates`, `setupConnectionStatus` |

### Cognition

Directory: `Modules/NativeAgentCore/Sources/Cognition/`

| File | Owns |
|---|---|
| `CognitiveBackgroundLoops.swift` | `CognitiveMaintenanceLoop` struct; `tick`, `tickOutcome` |
| `NativeCognitionRuntime+Replay.swift` | `NativeCognitionRuntime`: `makeReplayIntegrationInput` |
| `NativeCognitionRuntime+StudioWander.swift` | `NativeCognitionRuntime`: `considerStudioWander`, `studioWanderIsInstalled`, `studioWanderInstallationNow` |
| `NativeCognitionRuntime.swift` | `NativeCognitionRuntime` actor; `markSessionDebug`, `rememberNonLiveTurnKind` |
| `NativeCognitionRuntimeModels.swift` | `NativeCognitionPreferenceDefaults` struct |
| `SignedPeerEvidence.swift` | `SignedPeerEvidence` struct |

### CognitiveSubstrate

Directory: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`

| File | Owns |
|---|---|
| `CognitiveMetadataSignals.swift` | `CognitiveMetadataSignals` enum; `stringSignals` |
| `CognitiveSQLiteStore+Reads.swift` | `CognitiveSQLiteStore`: `loadNodes`, `loadRestoreBundle`, `loadArtifacts` |
| `CognitiveSQLiteStore.swift` | `CognitiveSQLiteStore` actor; `backupForDoctor`, `saveNodes` |
| `CognitiveSubstrate+Affect.swift` | `CognitiveSubstrate`: `canonicalAffectProjection`, `decayAffectInMemory`, `applyAffectFromEvent` |
| `CognitiveSubstrate+Capsule.swift` | `CognitiveSubstrate`: `compileCapsule`, `compileFrozenCapsule`, `compileFrozenCapsulePresentation` |
| `CognitiveSubstrate+CapsuleCadence.swift` | `CognitiveSubstrate`: `selectInnerLine`, `innerTakeawayCadenceKey`, `threadKindPhrase` |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | `CognitiveSubstrate`: `feltTintNodes`, `feltDominantNode`, `feltObjectLabel` |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | `CognitiveSubstrate`: `soundEchoRegisterScore`, `soundEchoLandingFactor`, `capsuleCadenceShouldSpeak` |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | `CognitiveSubstrate`: `relationalWarmthBoost`, `isUserAuthored`, `conversationalAppraisal` |
| `CognitiveSubstrate+Ingest.swift` | `CognitiveSubstrate`: `ingest`, `ingestResident`, `reconsolidatePendingCompletion` |
| `CognitiveSubstrate+Persistence.swift` | `CognitiveSubstrate`: `persistSnapshot`, `recordReceipt`, `recordReceiptChecked` |
| `CognitiveSubstrate+Reflection.swift` | `CognitiveSubstrate`: `planReflectionChecked`, `reflectionSourceExcerpts`, `planReflection` |
| `CognitiveSubstrate+Replay.swift` | `CognitiveSubstrate`: `integrateReplay`, `integrateReplayChecked`, `recordEpisode` |
| `CognitiveSubstrate+Research.swift` | `CognitiveSubstrate`: `setAblation`, `facultyMeasurementSnapshot`, `runResearchExperiment` |
| `CognitiveSubstrate+Restore.swift` | `CognitiveSubstrate`: `backupPersistentStateForDoctor`, `restorePersistentState`, `stringArrayValue` |
| `CognitiveSubstrate+Serialization.swift` | `CognitiveSubstrate`: `cleanedSessionId` |
| `CognitiveSubstrate+StandingViews.swift` | `CognitiveSubstrate`: `standingViewTermsMatch`, `createStandingView`, `normalizedStandingViewBody` |
| `CognitiveSubstrate+StudioEvents.swift` | `CognitiveSubstrate`: `studioJournalFelt`, `studioJournalEvent`, `ingestStudioJournalEntry` |
| `CognitiveSubstrate+ThoughtSeeds.swift` | `CognitiveSubstrate`: `boundedThoughtSeedSources`, `addThoughtSeed`, `decayThoughtSeedsInMemory` |
| `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate`: `metadataString`, `isConversationalPresenceStatement`, `isOperationalSubconsciousNoise` |
| `CognitiveSubstrate+Workspace.swift` | `CognitiveSubstrate`: `workspaceSnapshot`, `frozenRead`, `frozenRevisionToken` |
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
| `OrganismLivingDynamics.swift` | `OrganismAnalyticDecay` struct; `value`, `crossingDate` |
| `OrganismModels.swift` | `SomaticSignalKind` enum |
| `OrganismPrediction+Horizon.swift` | `OrganismPredictiveBody`: `applyingHorizonRefresh` |
| `OrganismPrediction.swift` | `OrganismPredictiveBody` enum; `predictionID`, `applying` |
| `OrganismPredictionModels.swift` | `OrganismPredictionKind` enum |
| `OrganismResidualRepair.swift` | `OrganismResidualRepair` enum; `combinedPressure`, `opportunity` |
| `OrganismSignalBus.swift` | `OrganismKernel`: `observe` |
| `OrganismToken.swift` | `OrganismToken` enum; `canonicalToken` |

### Connectors

Directory: `Modules/NativeAgentCore/Sources/Connectors/`

| File | Owns |
|---|---|
| `ConnectorActionPlatform.swift` | `ConnectorActionPlatform` protocol; `attentionRouter`, `macAction` |
| `ConnectorActionReceipt.swift` | `ConnectorActionReceipt` struct |
| `ConnectorActions.swift` | `ConnectorActions` struct; `runConnectorAction`, `fullMacYoloAdmitted` |
| `ConnectorOAuthConfig.swift` | `ConnectorOAuthConfig` struct |
| `ConnectorOAuthRegistry.swift` | `ConnectorOAuthRegistry` enum; `mutateConnectorRegistryEntry`, `checkedConnectorRows` |
| `ConnectorRegistryActions.swift` | `ConnectorRegistryActions` enum; `updateConnector`, `addWorkspace` |
| `ConnectorWizardActions.swift` | `ConnectorWizardActions` enum; `getConnectorRegistrationStatus`, `registerConnectorApp` |
| `Connectors+Auth.swift` | `ConnectorAuthClient` protocol; `revokeConnector`, `connectConnector` |
| `GitHubOAuthCredentialPort.swift` | `GitHubOAuthCredentialPort` protocol; `saveToken`, `saveOAuthToken` |
| `LocalPIMConnectorActions.swift` | `LocalPIMConnectorActions` enum; `calendarListUpcoming`, `calendarCalendars` |
| `LocalPIMStore.swift` | `LocalPIMEntity` enum |
| `NativeOAuthFlow+ConnectorCredentials.swift` | `NativeOAuthFlow`: `connectorOAuthAppCredentials`, `saveConnectorOAuthApp`, `saveNotionToken` |
| `NativeOAuthFlow+Connectors.swift` | `NativeOAuthFlow`: `startConnectorOAuthFlow`, `connectorTokenPath` |
| `NativeOAuthFlow+GitHub.swift` | `NativeOAuthFlow`: `saveGitHubToken`, `completeGitHubDeviceFlow`, `loadGitHubToken` |
| `NativeOAuthFlow+Slack.swift` | `NativeOAuthFlow`: `saveSlackToken` |

### Context

Directory: `Modules/NativeAgentCore/Sources/Context/`

| File | Owns |
|---|---|
| `ContextSelection.swift` | `ContextSelector` struct; `select` |
| `ContextSelectionContracts.swift` | `ContextOriginClass` enum |
| `ContextMarkdownCompiler.swift` | `ContextMarkdownCompiler`: bounded Markdown atom compilation; persona GROWTH uses the PersonaEngine episodic-log filter before hashing and parsing |

### ContextFlow

Directory: `Modules/NativeAgentCore/Sources/ContextFlow/`

| File | Owns |
|---|---|
| `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime` actor; `start`, `stop` |
| `NativeContextProjectionText.swift` | `NativeContextProjectionText` enum; `clean`, `bounded` |

### Desk

Directory: `Modules/NativeAgentCore/Sources/Desk/`

| File | Owns |
|---|---|
| `DeskClock.swift` | `DeskClock` enum; `nowISO`, `commitStamp` |
| `DeskContinuation.swift` | `DeskContinuation` struct; `receiptIsUnresolved`, `toJSON` |
| `DeskModels.swift` | `DeskStatus`: `DeskKind`, `CadenceMode`, `NotifyLevel` |
| `DeskOperations.swift` | `DeskOpBody` enum |
| `DeskStore+Reduction.swift` | `SwiftNativeDeskStore`: `compact`, `aliasSeq`, `orderByAlias` |
| `DeskStore.swift` | `SwiftNativeDeskStore` struct; `continuation`, `setContinuation` |
| `DeskStoreRecords.swift` | `DeskError` enum |
| `MyQueue.swift` | `MyQueue` enum; `entries`, `add`, `isReady` |

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

| File | Owns |
|---|---|
| `CKLandmine.swift` | `CloudKitHealth` actor; `likelyHealthy` |
| `DeviceSyncHost.swift` | `DeviceSyncHost` protocol; `helpersSnapshot`, `helperAction` |
| `ICloudIncomingTurnForwarder.swift` | `ICloudIncomingTurnForwarder` struct; `redactedRemoteErrorDetail`, `iCloudChatFileAccess` |
| `ICloudIncomingTurnPort.swift` | `ICloudIncomingTurnPort` protocol; `residentChatClient`, `publishReply` |
| `ICloudTextDeltaCoalescer.swift` | `ICloudTextDeltaCoalescer` struct; `push`, `flush` |
| `MacSyncActionRouter+Connectors.swift` | `MacSyncActionRouter`: `connectorAction` |
| `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |
| `MacSyncActionRouter+Providers.swift` | `MacSyncActionRouter`: `configureEncryptedProvider`, `startProviderSignIn` |
| `MacSyncActionRouter+Scheduler.swift` | `MacSyncActionRouter`: `schedulerAction` |
| `MacSyncActionRouter+Telegram.swift` | `MacSyncActionRouter`: `telegramAction` |
| `MacSyncActionRouter+Trust.swift` | `MacSyncActionRouter`: `applyTrustAction` |
| `MacSyncActionRouter.swift` | `MacSyncActionRouter` struct; `macIntegrationPermissionRequest`, `surfaceSelection` |
| `MacSyncEngine+Helpers.swift` | `MacSyncEngine`: `startHelpersSnapshotObservation`, `helpersSnapshotData` |
| `MacSyncEngine+Inbox.swift` | `MacSyncEngine`: `authenticateInboxFile`, `startInboxQuery`, `quarantineUnauthenticatedInboxFile` |
| `MacSyncEngine+Lifecycle.swift` | `MacSyncEngine`: `startCloudKitSnapshotProjection`, `start`, `stop` |
| `MacSyncEngine+NeedsUserNotify.swift` | `NeedsUserEdgeNotifier` actor; `evaluate`, `stableDigest` |
| `MacSyncEngine+Notifications.swift` | `MacSyncEngine`: `sendNotificationToPairedDevices` |
| `MacSyncEngine+Scheduler.swift` | `MacSyncEngine`: `schedulerSnapshotData`, `startSchedulerSnapshotObservation` |
| `MacSyncEngine+Security.swift` | `MacSyncEngine`: `beginPairingSecretRotation`, `finishPairingSecretRotation`, `signedResponse` |
| `MacSyncEngine+Snapshots.swift` | `MacSyncEngine`: `writeSnapshots`, `encodeSnapshot`, `publishChangedSnapshots` |
| `MacSyncEngine+Storage.swift` | `MacSyncEngine`: `recordProcessed`, `loadProcessedIds`, `cappedPreservingMarkers` |
| `MacSyncEngine+Telegram.swift` | `MacSyncEngine`: `telegramSnapshotData` |
| `MacSyncEngine+WorkActivity.swift` | `MacSyncEngine`: `startWorkActivityObservation`, `projectWorkshopWorkActivities`, `requestWorkActivityPublication` |
| `MacSyncInboxAction.swift` | `InboxAction` struct |
| `MacSyncMobileNotificationRelay.swift` | `MacSyncMobileNotificationRelay` struct; `storePushToken`, `storeWorkActivityRegistration` |
| `MacSyncRemoteMacControl.swift` | `MacSyncRemoteMacControl` struct; `dispatch` |
| `MacSyncRemoteMacControlPort.swift` | `MacSyncRemoteMacControlPort` protocol; `loadTrustPolicy`, `run` |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `open` |
| `iCloudBridge+DeliveryReceipts.swift` | `iCloudBridge`: `appendChatDeliveryReceipt`, `appendActionResponseDeliveryReceipt`, `appendInboundSuccessReceipt` |
| `iCloudBridge.swift` | `iCloudBridge` class; `setup`, `startDeviceDrainFallback` |

### Dispatcher

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/`

| File | Owns |
|---|---|
| `NativeActionDispatch.swift` | `NativeActionDispatch` enum; `swiftNativeDispatcherActions`, `dispatchNativeAction` |

### Dispatcher/Actions

Directory: `Modules/NativeAgentCore/Sources/Dispatcher/Actions/`

| File | Owns |
|---|---|
| `FileSystemActions.swift` | `FileSystemActions` enum; `resolvePath`, `allowedRoots` |

### DoctorChecks

Directory: `Modules/NativeAgentCore/Sources/DoctorChecks/`

| File | Owns |
|---|---|
| `AutoDoctorConfig.swift` | `AutoDoctorConfig` struct |
| `DoctorActionRuntime.swift` | `DoctorActionRuntime` struct; `safeDetail`, `mergeReport` |
| `DoctorChecks.swift` | `SwiftNativeDoctorChecks` actor; `freshMeasurementChecks`, `runAll` |
| `DoctorHealthCard.swift` | `HealthCardSubsystem` struct |
| `DoctorSafeRepairPolicy.swift` | `DoctorSafeRepairPolicy` enum; `checkIDs`, `appliedRepairCount` |
| `DoctorStatusProjection+Config.swift` | `DoctorStatusProjection`: `readAutoDoctorConfig`, `boolValue`, `intValue` |
| `DoctorStatusProjection+Hardening.swift` | `DoctorStatusProjection`: `getProductionHardening` |
| `DoctorStatusProjection.swift` | `DoctorStatusProjection` enum; `makeHealthCard`, `persistDoctorSnapshot` |
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
| `REMConsolidator.swift` | `REMConsolidator` actor; `runWeeklyREM`, `rankedByRecurrence` |
| `REMPinsReader.swift` | `REMPinsReader` enum; `read`, `latest` |
| `REMReport.swift` | `REMReport` struct |

### EngineRuntime

Directory: `Modules/NativeAgentCore/Sources/EngineRuntime/`

| File | Owns |
|---|---|
| `BrowserLink.swift` | `BrowserLink` typealias |
| `CapabilityTraceFeed.swift` | `CapabilityTraceFeed` enum; `path`, `read` |
| `ChatModels.swift` | `ChatMessage`: `NativeAppChatMessage`, `ChatMessageMetadata`, `CodingKeys` |
| `ChatStreamingTailBox.swift` | `ChatStreamingTailBox` class |
| `CodexSelectableModelCatalog.swift` | `CodexSelectableModelCatalog` typealias |
| `CognitionObservatoryRefreshCoordinator.swift` | `CognitionObservatoryRefreshCoordinator` class; `begin`, `settle` |
| `ConnectorRecord.swift` | `ConnectorRecord` struct |
| `ConnectorStatusProjection.swift` | `ConnectorStatusProjection` enum; `connectorRowWithRuntimeOverlay`, `markCredentialProof` |
| `DefaultReasoningEffortOptions.swift` | `defaultReasoningEffortOptions` |
| `DeskBoardRead.swift` | `DeskBoardRead` struct |
| `EngineApprovals.swift` | `ApprovalRecord`: `ApprovalsFacade` |
| `EngineCognitionModels.swift` | `CognitionProposalsFeed` enum |
| `EngineCognitionView.swift` | `DreamEntry`: `CognitionViewFacade`, `DreamDiary` |
| `EngineDesk.swift` | `DeskFacade` class; `loadBoard`, `taskRows` |
| `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |
| `EngineDeskReadModels.swift` | `DeskLaneState` enum; `boundedReason`, `failed` |
| `EngineDeskRecordProbe.swift` | `DeskFacade`: `probeExecutionRecords` |
| `EngineDoctor.swift` | `WatchdogStatus`: `DoctorFacade`, `DoctorReport` |
| `EngineInbox.swift` | `InboxItemRecord`: `InboxFacade` |
| `EngineMCPActions.swift` | `MCPUIActionAuthority`: `runtime` |
| `EngineMemory.swift` | `ProposalRecord`: `MemoryFacade` |
| `EnginePresentationModels.swift` | `TelegramPresentationSnapshot`: `TelegramVoiceTranscriptionStatus`, `TelegramReceipt`, `CodingKeys` |
| `EngineProviderHelpers.swift` | `ProvidersFacade`: `readJSONObject`, `readModelRoutingConfig`, `stringValue` |
| `EngineProviders.swift` | `ProvidersFacade`: `connections`, `modelCatalog`, `list`; presentation over ProviderRouting's checked snapshot |
| `EngineRouteError.swift` | `DaemonError` enum |
| `EngineSync.swift` | `SyncFacade` class; `observeStatus`, `setStatus` |
| `EngineTelegram.swift` | `TelegramFacade` class; `configuration`, `load` |
| `EngineTelegramRouting.swift` | `TelegramBrainResolution` struct |
| `EngineTools.swift` | `ToolsFacade` class; `listMCPSessions`, `loadManifest` |
| `EngineTranscripts.swift` | `TranscriptsFacade`: `messages`, `setMessages`, `streamingTailBox` |
| `EngineTrust.swift` | `TrustFacade` class; `loadCapabilities`, `load` |
| `EngineTurns.swift` | `TurnsFacade` class; `lifecycle`, `screenPreview` |
| `EngineWorkshopObservatory.swift` | `WorkshopScoreView` struct |
| `LatestAsyncRequestGate.swift` | `LatestAsyncRequestGate` struct; `begin`, `accepts` |
| `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |
| `MacChatScreenPreview.swift` | `MacChatScreenPreview` struct; `merged` |
| `NativeAgentAppChatSurfaceProfile.swift` | `NativeAgentAppChatSurfaceProfile` enum |
| `NativeAgentChatApprovalFiler.swift` | `NativeAgentChatApprovalFiler` actor; `fileApprovalRequest`, `peerRequesterName` |
| `NativeAgentEngine.swift` | Core composition root; chat clients, tool dispatch chains and resident service facades |
| `NativeAgentEnginePorts.swift` | Platform ports consumed by the core composition root |
| `NextGenStatusModels.swift` | `NextGenSummary` struct |
| `NextGenStatusProjection.swift` | `NextGenStatusProjection` struct; `getNextGenSummary`, `getNextGenPhases` |
| `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |
| `PersonalityGrowthSummary.swift` | `PersonalityGrowthSummary` struct |
| `RuntimeReadProjection+Feeds.swift` | `RuntimeReadProjection`: `getNotificationStatus`, `getBrowserStatus`, `decodeJSONValue` |
| `RuntimeReadProjection+Improvement.swift` | `RuntimeReadProjection`: `swiftImprovementGauntlet` |
| `RuntimeReadProjection+Personality.swift` | `RuntimeReadProjection`: `swiftPersonalityGrowth` |
| `RuntimeReadProjection+Traces.swift` | `RuntimeReadProjection`: `getTraces` |
| `RuntimeReadProjection.swift` | `RuntimeReadProjection` enum; `getSessionContext` |
| `RuntimeSummaryModels.swift` | `KernelGuardrail` struct |
| `RuntimeTrace.swift` | `RuntimeTrace` struct |
| `SessionContextStatus.swift` | `SessionContextStatus` struct |
| `SurfaceRuntimeStatusModels.swift` | `NotificationRuntimeStatus` struct |
| `TolerantDisplayStringDecoding.swift` | `decodeTolerantDisplayString` |
| `WorkOverviewRead.swift` | `WorkOverviewRead` enum; `project`, `text` |

### GitHubConnector

Directory: `Modules/NativeAgentCore/Sources/GitHubConnector/`

| File | Owns |
|---|---|
| `GitHubApprovalNotify.swift` | `GitHubApprovalEdgeNotifier` actor; `evaluateSnapshot` |
| `GitHubCommandLiveStateMemo.swift` | `GitHubCommandLiveStateMemo` actor; `value`, `prime` |
| `GitHubCommandModels.swift` | `GitHubCommandItemKind` enum |
| `GitHubCommandRuntime.swift` | `GitHubCommandRuntime` actor; `replayResidentStateAtLaunch`, `recoverAtLaunch` |
| `GitHubCommandStore.swift` | `GitHubCommandStore` struct; `liveState`, `memoKey` |
| `GitHubProjectTracking.swift` | `GitHubConnectorActions`: `search`, `listPullRequests`, `getIssue` |
| `GitHubTrackingModels.swift` | `TrackedRepository` struct; `fromJSON` |

### KnowledgeGraph

Directory: `Modules/NativeAgentCore/Sources/KnowledgeGraph/`

| File | Owns |
|---|---|
| `KnowledgeGraph+CanonicalRebuild.swift` | `SwiftNativeKnowledgeGraphIndexer`: `rebuildMemoryDerivedGraphFromCanonicalStore`, `backfillMissingMemoryIndexRows` |
| `KnowledgeGraph+MemoryIndexing.swift` | `KnowledgeGraphMemoryFact` struct |
| `KnowledgeGraph+PrimaryUserIndexing.swift` | `SwiftNativeKnowledgeGraphIndexer`: `resolvePrimaryUserName`, `consolidatePrimaryUserEntities`, `removeUnreferencedPrimaryUserRole` |
| `KnowledgeGraphProjectionModels.swift` | `AgentGraphNode` struct |
| `KnowledgeGraphReadProjection.swift` | `KnowledgeGraphReadProjection` enum; `canonicalAgentGraphProjection`, `canonicalKnowledgeGraphSnapshotData` |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | `SwiftNativeKnowledgeGraphIndexer`: `extractEntities`, `taggedNameIsCredible` |

### MCPDispatcher

Directory: `Modules/NativeAgentCore/Sources/MCPDispatcher/`

| File | Owns |
|---|---|
| `MCPActionModels.swift` | `MCPConsentRecord` struct |
| `MCPResultEvidence.swift` | `MCPResultEvidence` enum; `project`, `activityReceipt` |
| `MCPUIActions+Registry.swift` | `MCPUIActions`: `mapConsent`, `grantConsent`, `revokeConsent` |
| `MCPUIActions.swift` | `MCPUIActions` enum; `evaluateMCPUIAdmission`, `callMCPTool` |

### MacControl

Directory: `Modules/NativeAgentCore/Sources/MacControl/`

| File | Owns |
|---|---|
| `MacAXAttributeRead.swift` | `MacAXAttributeRead` enum; `copyTextRange`, `copyRaw` |
| `MacAXWindowIdentityRead.swift` | `MacAXWindowIdentityRead` enum; `copy` |
| `MacAccessibilityActuator.swift` | `MacAccessibilityActuator` enum; `act` |
| `MacActReceiptRendering.swift` | `MacActReceiptRendering` enum; `actedReadout`, `actedElementJSON` |
| `MacControl+Client.swift` | `SwiftNativeMacControl` actor; `dispatch`, `dispatchApprovedInjection` |
| `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl`: `handleAct`, `pointerRestoredJSON` |
| `MacControl+DirectInput.swift` | `SwiftNativeMacControl`: `handleKeystroke`, `handleClick`, `handleScroll` |
| `MacControl+HandAndWake.swift` | `SwiftNativeMacControl`: `waitForTextInput`, `handleHand`, `handleNudge` |
| `MacControl+MenusAndClipboard.swift` | `SwiftNativeMacControl`: `handleMenu`, `handleMenuPress`, `handleClipboardRead` |
| `MacControl+OperationSupport.swift` | `SwiftNativeMacControl`: `attachingOperation`, `replayResult`, `unknownResult` |
| `MacControl+Perception.swift` | `SwiftNativeMacControl`: `handleRead`, `documentPath` |
| `MacControl+SystemActions.swift` | `SwiftNativeMacControl`: `handleFileRead`, `handleFileWrite`, `handleFileList` |
| `MacControlActionRoutes.swift` | `MacControlActionRoutes` enum; `auditPath`, `run` |
| `MacControlBridgeContracts.swift` | `MacControlBridgeInfoRouteResponse` struct; `responseObject` |
| `MacControlBridgeRuntime.swift` | `MacControlBridgeRuntime` class; `recoverInterruptedOperations`, `infoRouteResponse` |
| `MacFourVerbs+Act.swift` | `MacFourVerbs`: `act`, `addAttention`, `frontChangedWords` |
| `MacFourVerbs+Navigation.swift` | `MacFourVerbs`: `go`, `applicationURL`, `webURL` |
| `MacFourVerbs+Observation.swift` | `MacFourVerbs`: `screen`, `observedReply`, `sight` |
| `MacFourVerbs+PerceptReconstruction.swift` | `MacFourVerbs`: `percept`, `partition`, `supplementalDuplicateIndex` |
| `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: `performPhysical` |
| `MacFourVerbs+ScreenPresentation.swift` | `MacFourVerbs`: `zoom`, `parseVerb`, `isRightClick` |
| `MacFourVerbs+TargetResolution.swift` | `MacFourVerbs`: `resolve`, `answers`, `bareNumberNote` |
| `MacFourVerbs+Wait.swift` | `MacFourVerbs`: `wait` |
| `MacFourVerbs.swift` | `MacFourVerbs` struct |
| `MacFourVerbsContracts.swift` | `SwiftNativeMacControl`: `MacFourVerbsHost`, `MacFourVerbsSupplementalTarget`, `MacFourVerbsSupplement` |
| `MacScreenView.swift` | `MacScreenShot`: `cropped` |
| `MacScreenViewCapture.swift` | `MacScreenCaptureWindowSelection` enum; `selectedID` |
| `MacScreenViewRenderer.swift` | `CoreGraphicsMacScreenImageRenderer` struct; `renderPNG`, `encodePNG` |

### MemoryV2

Directory: `Modules/NativeAgentCore/Sources/MemoryV2/`

| File | Owns |
|---|---|
| `EmbeddingModelDownload.swift` | `EmbeddingModelDownload` actor; `ranges`, `assemble` |
| `EmbeddingStatusReadiness.swift` | `EmbeddingStatusReadiness` struct |
| `EmbeddingsMemoryReleaseVerification.swift` | `EmbeddingsMemoryReleaseVerification` enum; `verify` |
| `InMemoryMemoryStorage.swift` | `InMemoryMemoryStorage` actor; `lookupMemoryRecord`, `listMemory` |
| `LegacyCorrectionScopeMigration.swift` | `LegacyCorrectionScopeMigration` enum; `runIfNeeded`, `migrationsDir` |
| `MemoryConsolidationGate+Database.swift` | `MemoryConsolidationGate`: `transactionalTableSwap`, `backupLiveStore`, `sweepBackups` |
| `MemoryConsolidationGate+Receipts.swift` | `MemoryConsolidationGate`: `writeManifest`, `readManifest`, `readReceipt` |
| `MemoryConsolidationGateContracts.swift` | `MemoryConsolidationDiff` struct |
| `MemoryConsolidationHygiene.swift` | `MemoryConsolidationHygiene` enum; `runOnce`, `lastRunPath` |
| `MemoryHygieneReport.swift` | `MemoryHygieneReport` struct |
| `MemoryRecallScoring.swift` | `MemoryRecallScoring` enum; `parseTimestamp`, `decayFactor` |
| `MemoryRepairOneShot.swift` | `MemoryRepairOneShot` enum; `stageIfNeeded`, `stageTruncatedRowsRepair` |
| `MemoryStatusModels.swift` | `MemoryVectorStatus` struct |
| `MemoryStatusProjection.swift` | `MemoryStatusProjection` enum; `getMemoryVectorStatus`, `getMemoryV2Status` |
| `MemoryStorage+Codecs.swift` | `MemoryStorage`: `validateTemporalEvidence`, `contentHash`, `nowISO8601` |
| `MemoryStorage+EmbeddingEpoch.swift` | `MemoryStorage`: `embeddingCorpusSnapshot`, `frozenCopy`, `embeddingEpochState` |
| `MemoryStorage+Integrity.swift` | `MemoryStorage`: `requireSemanticIntegrity`, `projectionGenerationFingerprint`, `createConsistentBackup` |
| `MemoryStorage+Migrations.swift` | `MemoryStorage`: `adoptLedgerlessGraphStoreIfNeeded` |
| `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `insertProposal`, `stagePendingProposal` |
| `MemoryStorage+Recall.swift` | `MemoryStorage`: `invalidateRecallCache`, `recall`, `recallReportingKeywordFallback` |
| `MemoryStorage+Tombstones.swift` | `MemoryStorage`: `addTombstone`, `removeTombstone`, `upsertTombstone` |
| `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |
| `MemoryV2+ConsolidationGate.swift` | `MemoryConsolidationGate` enum; `gateLockTarget`, `withGateLock` |
| `MemoryV2+ConsolidationStorageSupport.swift` | `MemoryConsolidationGate`: `consolidationDir`, `candidatesDir`, `candidateRoot` |
| `MemoryV2+EmbeddingRuntime.swift` | `EmbeddingRuntimeSnapshot` struct |
| `MemoryV2+PolicyGate.swift` | `MemoryPolicyGate` enum; `isEnabled`, `knowledgeGraphEnabled` |
| `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |
| `MemoryV2+Recall.swift` | `SwiftNativeMemoryV2`: `recordRecallHits`, `recall`, `readMemoryRecord` |
| `MemoryV2+Storage.swift` | `MemoryStorage` actor; `attachUserMDGenerator`, `attachSpotlightHook` |
| `MemoryV2+Wiring.swift` | `SwiftNativeMemoryV2`: `duplicateProvenancePatch`, `store`, `isRejected` |
| `MemoryV2.swift` | `SwiftNativeMemoryV2` actor; `setDiagnosticSink`, `emitDiagnostic` |
| `MemoryV2Contracts.swift` | `MemoryStorageProtocol`: `listMemory`, `insert`, `updateMemory` |

### NativeAgentCore

Directory: `Modules/NativeAgentCore/Sources/NativeAgentCore/`

| File | Owns |
|---|---|
| `LLMCompatibilityPrompt.swift` | `llmCompatibilityPrompt` |
| `NativeActionRecord.swift` | `NativeActionRecord` struct |
| `NativeAgentBuildIdentity.swift` | `NativeAgentBuildIdentity` struct; `from`, `writeLaunchStamp` |
| `NativeTimestampFormat.swift` | `NativeTimestampFormat` enum; `flooredOptionalMicrosecondUTCOffset`, `utcDay` |
| `ProviderFamilyIdentity.swift` | `ProviderFamilyIdentity` enum; `normalize` |
| `TurnDeadline.swift` | `TurnDeadline` enum; `withDeadline` |
| `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |

### Onboarding

Directory: `Modules/NativeAgentCore/Sources/Onboarding/`

| File | Owns |
|---|---|
| `Onboarding.swift` | `JSONValue`: `fromObject` |
| `PersonaTemplates.swift` | `PersonaTemplates` enum; `nowISO`, `generate` |

### PersistenceCore

Directory: `Modules/NativeAgentCore/Sources/PersistenceCore/`

| File | Owns |
|---|---|
| `ConnectorInputValue.swift` | `ConnectorInputValue` enum; `bool` |
| `JSONLRetention.swift` | `JSONLCapCheckCounter` class; `isFullCheckDue`, `isFullCheckDueOnNextAppend` |
| `JSONValue.swift` | `JSONValue` enum; `fromEncodable`, `mapStrings` |
| `NativeActionRouteSupport.swift` | `NativeActionRouteSupport` enum; `jsonValueBody`, `notImplemented` |
| `PersistenceCore.swift` | Shared JSON/JSONL reads and writes, including atomic/durable persistence and transaction directory sync |
| `PersistenceDataRoot.swift` | `ResolvedDataRootCache` class; `resolve` |
| `RegistryTimestampSortKey.swift` | `RegistryTimestampSortKey` enum; `sortKey` |

### PersonaEngine

Directory: `Modules/NativeAgentCore/Sources/PersonaEngine/`

| File | Owns |
|---|---|
| `PersonaCompiler+Normalization.swift` | `PersonaCompiler`: `normalize` |
| `PersonaEngine+Compiler.swift` | `PersonaCompiler`: `compile`, `fingerprint`, `renderPrompt`; shared chat/background/reflection persona rendering, including USER core projection |
| `PersonaEngine.swift` | `SwiftNativePersonaEngine`: shared persona-document reads and GROWTH episodic-log filtering |
| `PersonaEngine+GrowthVoiceWrites.swift` | `SwiftNativePersonaEngine`: locked persona mutations and private backups; skill writes delegate to Skills draft/version lifecycle |

### Privacy

Directory: `Modules/NativeAgentCore/Sources/Privacy/`

| File | Owns |
|---|---|
| `NativeAppSecretRedactor.swift` | `NativeAppSecretRedactor` enum; `redactText`, `redactValue` |

### Procedures

Directory: `Modules/NativeAgentCore/Sources/Procedures/`

| File | Owns |
|---|---|
| `ProcedureCompilation.swift` | `ProcedureTerminalClass` enum |
| `ProcedureExactActivationExecutor.swift` | `ProcedureExactActivationExecutor` enum; `activate` |
| `ProcedureReplay.swift` | `ProcedureReplayMode` enum |

### ProviderRouting

Directory: `Modules/NativeAgentCore/Sources/ProviderRouting/`

| File | Owns |
|---|---|
| `ChatCompletionsMessageEncoding.swift` | `chatCompletionsMessages` |
| `CodexAccountModelCatalog.swift` | `CodexAccountModelCatalog` enum; `load`, `signedCacheLists` |
| `GoogleOAuthCredentials.swift` | `GoogleOAuthCredentials` enum; `credentialStatus`, `accountSubject` |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthDirectAdapter`: `requestMaxTokens`, `clearAtBeta`, `installedClaudeCodeVersion` |
| `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthDirectAdapter`: `ephemeralCacheControl`, `currentTurnUserIndex`, `currentBoundaryIndex` |
| `LLMClient+OpenAIOAuthCredentials.swift` | `OpenAIOAuthDirectAdapter`: `authPathCandidates`, `boundRootReadAuthPath`, `preferredAuthPath` |
| `LLMClient+OpenAIOAuthDirectAdapter.swift` | `CodexOAuthAccessContext` struct |
| `LLMClient+OpenAIResponsesDecoding.swift` | `OpenAIOAuthDirectAdapter`: `consumeResponsesStream`, `incompleteReasonText`, `incompleteNote` |
| `NativeOAuthCallbackPolicy.swift` | `NativeOAuthFlow`: `handleCallbackURL`, `validateCallback`, `parseCallback` |
| `NativeOAuthCallbackRegistry.swift` | `PendingCallbacks` class; `register`, `forget` |
| `NativeOAuthFlow+Configs.swift` | `ProviderOAuthConfig` struct; `buildAuthURL`, `exchangeCode` |
| `NativeOAuthFlow+Helpers.swift` | `PKCE` struct; `generate` |
| `NativeOAuthFlow+Loopback.swift` | `NativeOAuthFlow`: `startOpenAILoopbackFlow`, `callbackTarget`, `callbackHasResult` |
| `NativeOAuthFlow+TokenStatus.swift` | `NativeOAuthFlow`: `clearTokens`, `hasRefreshToken`, `expiresAt` |
| `NativeOAuthFlow+XAI.swift` | `NativeOAuthFlow`: `startXAIOAuthFlow` |
| `NativeOAuthFlow.swift` | `NativeOAuthFlow` enum; `validateSignInDestination`, `startOAuthFlow` |
| `NativeOAuthPlatformPort.swift` | `NativeOAuthPlatformPort` protocol; `runLoopbackAuthSession`, `isCanceledLogin` |
| `OAuthContinuationGate.swift` | `OAuthContinuationGate` class; `install`, `resume` |
| `OAuthCredentialDecoding.swift` | `OAuthRefreshBinding` enum; `string`, `identity` |
| `OAuthCredentialDestinations.swift` | `OAuthCredentialDestinations` enum; `xAIProvider`, `xConnector` |
| `OAuthCredentialHealth.swift` | `OAuthCredentialHealth` struct |
| `OAuthLoopbackCallbackPolicy.swift` | `OAuthLoopbackCallbackPolicy` enum; `callbackMatchesState`, `validCallbackURL` |
| `OAuthProductionSession.swift` | `OAuthProductionSession` enum; `make` |
| `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` |
| `ProviderAPIKeyStore.swift` | `ProviderAPIKeyStore` enum; `insert`, `read` |
| `ProviderRouting.swift` | `SwiftNativeProviderRouting` actor; `checkedProviderSnapshot`, `checkedRoutingSnapshot`, `saveGroupSelection`; provider interpretation and recoverable group writes |
| `ProviderRoutingContracts.swift` | `ProviderRoutingProtocol`: `listProviders`, `getProvider`, `configureProvider` |
| `ProviderStateValidation.swift` | `ProviderStateValidation` enum; `dataIfPresent`, `credential` |
| `ProviderTurnChoice.swift` | `ProviderTurnChoice` struct |
| `SwiftCodexDeviceLoginManager.swift` | `SwiftCodexDeviceLoginManager` enum; CLI executable readiness |

### Research

Directory: `Modules/NativeAgentCore/Sources/Research/`

| File | Owns |
|---|---|
| `Research+ActivityTrace.swift` | `SwiftNativeResearchClient`: `recordActivity`, `recordTrace`, `pythonCodepointPrefix` |
| `Research+Autodetect.swift` | `SwiftNativeResearchClient`: `autodetectSearXNG`, `checkSearXNG`, `dockerSearXNGCandidates` |
| `Research+CodexSearch.swift` | `WebSearchRoutes`: Codex/SearXNG selection, fallback and route receipts |
| `Research+Helpers.swift` | `SwiftNativeResearchClient`: `trimTrailingSlash`, `makeURL`, `isoTimestamp` |
| `Research+Lab.swift` | `SwiftNativeResearchClient`: `researchLabRuns`, `runResearchLab`, `buildResearchBrief` |
| `Research+SearchFetch.swift` | `SwiftNativeResearchClient`: `localServerIsDown`, `search`, `fetchURL` |
| `ResearchTransports.swift` | `URLSessionResearchHTTPClient` class; `getBounded`, `get` |

### SchedulerExecution

Directory: `Modules/NativeAgentCore/Sources/SchedulerExecution/`

| File | Owns |
|---|---|
| `NativeAgentDreamCycleSupport.swift` | `NativeAgentDreamCycleSchedule` enum; `runDateKey`, `dreamEntryDateKey` |
| `SchedulerDueJobRunner+CycleHelpers.swift` | `SchedulerDueJobRunner`: `upsertDefaultCycleJob`, `pruneCompletedOneShotRows`, `nextEpoch` |
| `SchedulerDueJobRunner+Execution.swift` | `SchedulerDueJobRunner`: `execute`, `channelIsSwitchedOn`, `disabledDreamResult` |
| `SchedulerDueJobRunner+Persistence.swift` | `SchedulerDueJobRunner`: `update`, `pruneCompletedOneShotJobs`, `appendActivity` |
| `SchedulerDueJobRunner+ProactiveScan.swift` | `SchedulerDueJobRunner`: `surfaceProactiveScan` |
| `SchedulerDueJobRunner+Selection.swift` | `SchedulerDueJobRunner`: `nextMeaningfulDeadline`, `selectDueJobs`, `claimDueJobs` |
| `SchedulerDueJobRunner+Timeout.swift` | `SchedulerDueJobRunner`: `jobTimeoutSeconds`, `executeWithTimeout` |
| `SchedulerDueJobRunner.swift` | `SchedulerDueJobRunner` actor; `readJobRowsChecked`, `runDueJobs` |
| `SchedulerExecutionPlatform.swift` | `SchedulerExecutionPlatform` protocol; `postNotification`, `sendTelegramMessage` |

### SelfImprovement

Directory: `Modules/NativeAgentCore/Sources/SelfImprovement/`

| File | Owns |
|---|---|
| `ImprovementGauntletReadModels.swift` | `ImprovementGauntletStatus`: `ImprovementGauntletRun`, `GauntletCheck` |
| `SelfEvolutionApprovalExecutor.swift` | `SelfEvolutionApprovalExecutor` enum; `evolutionRepoRoot`, `applyResolvedSelfEvolution` |
| `SelfEvolutionPlatformPort.swift` | `SelfEvolutionPlatformPort` protocol; `currentBundleSha`, `fireRebuild` |
| `SelfImprovement+TrainingPromotion.swift` | `SwiftNativeSelfImprovement`: `rejectTrainingProposalLocal`, `approveTrainingProposalLocal`, `approvePromotionStageLocal` |
| `SelfImprovement+TrainingReads.swift` | `SwiftNativeSelfImprovement`: `savedTrustAuthority`, `trustLeafBool`, `trainingAllowed` |

### Skills

Directory: `Modules/NativeAgentCore/Sources/Skills/`

| File | Owns |
|---|---|
| `InstalledSkillInventory.swift` | `InstalledSkillInventory`: checked identity, body resolution and availability for UI, discovery and recall |
| `Skills.swift` | `SkillsClient`, `SwiftNativeSkillsClient`: registry/manifest lifecycle, agent skill management and capability-pack skill mutations |
| `SkillsJSON.swift` | `JSONValue`: `SkillsRegistry`, `SkillManifestRegistry`, `SkillMutation` |

### SlackBot

Directory: `Modules/NativeAgentCore/Sources/SlackBot/`

| File | Owns |
|---|---|
| `SlackInboundDeliveryJournal.swift` | `SlackInboundDeliveryJournal` actor; `path`, `recoverySummary` |
| `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |
| `SlackSessionStore.swift` | `SlackSessionStore` struct; `activeSessionId`, `ensureSessionRow` |
| `SlackSocketModeConfig.swift` | `SlackSocketModeConfig` struct; `loadIngressPolicy`, `load` |
| `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: `classifySessionClosure`, `disconnectDisposition`, `classifyReceiveLoopReturn` |
| `SlackSocketModeLoop.swift` | `SlackSocketModeLoop` struct; `tick`, `tickOutcome` |
| `SlackSocketModeSupport.swift` | `SlackConversationRef` struct |
| `SlackTurnContracts.swift` | `SlackInboundFile` struct |

### StandingBots

Directory: `Modules/NativeAgentCore/Sources/StandingBots/`

| File | Owns |
|---|---|
| `BotDefinitionStore.swift` | `BotDefinitionStore` struct; `create`, `check` |
| `BotEventIntake.swift` | `BotEventIntake` enum; `router`, `slackMessage` |
| `BotHeadline.swift` | `BotHeadline` enum; `make` |
| `BotLegacyHistory.swift` | `ShelfStore`: `legacyHistory` |
| `BotRunQueue.swift` | `BotRunQueue` struct; `enqueue`, `enqueueRequest` |
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

### SystemOps

Directory: `Modules/NativeAgentCore/Sources/SystemOps/`

| File | Owns |
|---|---|
| `SystemGitActions.swift` | `SystemGitActions` enum; `processDetail` |

### TelegramBot

Directory: `Modules/NativeAgentCore/Sources/TelegramBot/`

| File | Owns |
|---|---|
| `TelegramAssistantDeliveryDriver.swift` | `TelegramAssistantDeliveryDriver` actor; `onDelta`, `finalize` |
| `TelegramBot+Config.swift` | `TelegramConfigurationSummary` struct |
| `TelegramPollLoop+Approvals.swift` | `TelegramPollLoop`: `handleApprovalSlashCommand`, `handleApprovalCallback`, `importLegacyApprovalContinuations` |
| `TelegramPollLoop+ChatProgress.swift` | `TelegramPollLoop`: `makeTurnProgressCard`, `makeAssistantDelivery`, `makeProgressSink` |
| `TelegramPollLoop+Commands.swift` | `TelegramPollLoop`: `handleControlHandoff`, `clearQueueAcknowledgement`, `handleSlashCommand` |
| `TelegramPollLoop+Media.swift` | `TelegramPollLoop`: `photoAttachment`, `caption`, `unsupportedAttachmentKind` |
| `TelegramPollLoop+QueuedTurnControls.swift` | `TelegramPollLoop`: `handleQueuedTurnControlCallback` |
| `TelegramPollLoop+StateReceipts.swift` | `TelegramPollLoop`: `inferDataRoot`, `writeStatePatch`, `botTokenFingerprint` |
| `TelegramPollLoop+Transport.swift` | `TelegramPollLoop`: `answerRecordedCallback`, `_tgDestinationFields`, `_tgDestinationBody` |
| `TelegramPollLoop+TurnControls.swift` | `TelegramPollLoop`: `handleTurnControlCallback`, `refreshLiveTurnCard`, `requestLiveTurnStop` |
| `TelegramPollLoop+Voice.swift` | `TelegramPollLoop`: `recordVoiceTranscription`, `voiceTranscriptionNotice`, `voiceAttachment` |
| `TelegramRichMessage.swift` | `TelegramInputRichBlock` enum |
| `TelegramTurnCardLedger.swift` | `TelegramTurnCardLedger` actor; `upsert`, `remove` |
| `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias |
| `TelegramUpdateInbox.swift` | `TelegramUpdateInbox` struct; `snapshots`, `ensurePending` |

### ToolRegistry

Directory: `Modules/NativeAgentCore/Sources/ToolRegistry/`

| File | Owns |
|---|---|
| `ToolRegistryActions.swift` | `ToolRegistryActions` enum; `updateTool`, `upsertProposal` |

### Transcripts

Directory: `Modules/NativeAgentCore/Sources/Transcripts/`

| File | Owns |
|---|---|
| `ChatSessionIndexFile.swift` | `ChatSessionIndexFile` enum; `recordContinuityParticipant`, `recordConversationChange` |

### TriggerScheduler

Directory: `Modules/NativeAgentCore/Sources/TriggerScheduler/`

| File | Owns |
|---|---|
| `ProactiveInboxStore.swift` | `ProactiveInboxStore` actor; `surface`, `activeDuplicateId` |
| `TriggerNotificationInbox.swift` | `TriggerNotificationInbox` enum; `mirrorCardIntoRealInbox`, `archiveSupersededMorningBriefs` |
| `TriggerScheduler.swift` | `SwiftNativeTriggerScheduler` actor; `listInboxTriggers`, `listWorkshopTriggers` |

### TrustCenter

Directory: `Modules/NativeAgentCore/Sources/TrustCenter/`

The workflow capability reader delegates defaults, unchanged-seed migration and
registry merging to `WorkflowOrchestration`; this reader does not write back.

| File | Owns |
|---|---|
| `MacInjectionRedaction.swift` | `MacInjectionArgRedaction` enum; `carriesSecretArgs`, `appDoorSecretKeys` |
| `PeerTurnEffectPolicy.swift` | Peer-origin approval floors and attributed memory-note policy |
| `SecurityCenter+FullMacPolicy.swift` | `SwiftNativeSecurityCenter`: `fullMacActive`, `fullMacYoloAuthority`, `drivenAgentLaunchPermission` |
| `SecurityCenter+InputScanning.swift` | `SwiftNativeSecurityCenter`: `promptInjectionKeys`, `secretKeys`, `redactValue` |
| `SecurityCenter+JSONUtilities.swift` | `SwiftNativeSecurityCenter`: `maxDecision`, `object`, `string` |
| `SecurityCenter+Models.swift` | `SecurityToolDecision` enum; `PairedPhoneAuthority` checked pairing reader |
| `SecurityCenter+PathPolicy.swift` | `SwiftNativeSecurityCenter`: `capabilityWritesOutsideAppData`, `pathLikeStrings` |
| `SecurityCenter+ReceiptJSON.swift` | `SecurityToolEnvelope`: `toJSONValue` |
| `SecurityCenter+RegistryReceipts.swift` | `SwiftNativeSecurityCenter`: `registryContainsSignedTool`, `receiptSummary`, `isoTimestamp` |
| `SecurityCenter+ToolProfiles.swift` | `AppActionPolicy` registry projection; `SwiftNativeSecurityCenter`: `canonicalToolRisk`, `appActionOldTool`, `profile` |
| `SecurityCenter.swift` | `SwiftNativeSecurityCenter`: security decisions, including permission-reset approval |
| `SwiftNativeManifestSigner.swift` | `SwiftNativeManifestSigner` actor; `canonicalBytes`, `compactCanonicalJSON` |
| `TrustAccessModeCapabilityCatalog.swift` | `TrustAccessModeCapabilityCatalog` enum; `normalizedMode`, `macControlPolicy` |
| `TrustCenter+AppAdapter.swift` | `SwiftNativeTrustCenter`: `loadTrustPolicyJSON` |
| `TrustCenter+Autonomy.swift` | `SwiftNativeTrustCenter`: `autonomyForTool`, `autonomyForExactToolName`, `explicitAutonomyOverride` |
| `TrustCenter+ChromeControl.swift` | `SwiftNativeTrustCenter`: `authorizeChromeControlEffect`, `chromeControlEnabledChecked` |
| `TrustCenter+Defaults.swift` | `SwiftNativeTrustCenter`: `defaultTrustPolicy` |
| `TrustCenter+PolicyLoading.swift` | `SwiftNativeTrustCenter`: `loadRawPolicyChecked`, `validateAuthorityPolicyShape`, `validateKnownAuthorityPolicyTypes` |
| `TrustCenter+PolicyModels.swift` | `AutonomyPolicy` struct |
| `TrustCenter.swift` | `SwiftNativeTrustCenter` actor; `getTrust`, `updateTrust` |
| `TrustPolicy.swift` | `TrustPolicy` struct |
| `TrustPolicyActions.swift` | `TrustPolicyActions` struct; `developerModePatchBody`, `saveDeveloperMode` |
| `TrustPolicyToolWriter.swift` | `TrustPolicyToolWriter` enum; `applyTrustPolicyPatch` |

### TrustPersistence

Directory: `Modules/NativeAgentCore/Sources/TrustPersistence/`

| File | Owns |
|---|---|
| `TrustBackupFoundation.swift` | `JSONDecoder`: extension |
| `TrustBackupHost.swift` | `TrustBackupHost` struct |
| `TrustBackupModels.swift` | `BackupRecord` struct |
| `TrustBackupPersistence.swift` | `TrustBackupPersistence` enum; `createBackup`, `offDiskAutomaticBackups` |

### TurnTrace

Directory: `Modules/NativeAgentCore/Sources/TurnTrace/`

| File | Owns |
|---|---|
| `AbandonedTurnReconciliationHook.swift` | `AbandonedTurnReconciliationHook` enum; `arm` |

### WorkshopExecution

Directory: `Modules/NativeAgentCore/Sources/WorkshopExecution/`

| File | Owns |
|---|---|
| `WorkshopCompiledLocalFileCopyProcedure.swift` | `WorkshopCompiledProcedurePlanError` enum |
| `WorkshopExecution+OutcomeVerification.swift` | `WorkshopExecutorLoop`: `unmetSuccessCriterion`, `verifyCompletedOutcome` |
| `WorkshopExecutorContracts.swift` | `WorkshopStepApprovalRequest` struct |
| `WorkshopPump.swift` | `WorkshopPump` struct; `tick`, `hasLiveAttempt` |
| `WorkshopPumpPlatform.swift` | `WorkshopPumpPlatform` protocol; `isUnderResourcePressure`, `artifactIsReadable` |
| `WorkshopSession.swift` | `WorkshopSession` struct; `run`, `trimSummary` |
| `WorkshopSessionContracts.swift` | `WorkshopSessionStatus` enum |
| `WorkshopSessionEffects.swift` | `WorkshopSessionEffects` protocol; `makeToolDispatcher`, `productionTurnExecutor` |
| `WorkshopSessionResultStore.swift` | `WorkshopSessionResultStore` struct; `path`, `save` |
| `WorkshopToolProfile.swift` | `WorkshopToolProfile` struct; `permits`, `isPermitted` |

## Shared Source Map

### NativeAgentShared

Directory: `Modules/NativeAgentShared/Sources/NativeAgentShared/`

| File | Owns |
|---|---|
| `CloudKitDeviceTransport.swift` | `CloudKitDeviceTransport` class; `observeAccountFailures`, `shouldPersistPullCursor` |
| `CloudKitTimeoutResultLatch.swift` | `CloudKitTimeoutResultLatch` actor; `wait`, `finish` |
| `DetachedCloudKitTimeoutRace.swift` | `DetachedCloudKitTimeoutOutcome` enum |
| `MobileHelpers.swift` | `MobileHelpersSnapshot` struct |
| `MobileSchedulerSnapshot.swift` | `MobileSchedulerSnapshot` struct |
| `MobileSnapshotStatus.swift` | `NAMobileSnapshotGroup` enum; `groups` |
| `MobileTelegramSnapshot.swift` | `MobileTelegramSnapshot` struct |
| `MobileTrustAction.swift` | `MobileTrustAction` enum |
| `MobileWorkActivity.swift` | `MobileWorkActivity` struct |

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
| `MobilePushNotifications.swift` | `NativeAgentPushTokenSyncCache` struct; `load`, `hasFreshSyncedRegistration` |
| `MobileSchedulerView.swift` | `MobileSchedulerView` struct |
| `MobileTrustEditor.swift` | `MobileTrustEditor` struct |
| `NativeAgentDesign.swift` | `View`: `appShimmer` |
| `NativeAgentMobileApp.swift` | `NativeAgentMobileApp` struct |
| `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |
| `PhoneTurnActivity+Work.swift` | `PhoneTurnActivity`: `setEnabled`, `receive`, `resumeWorkActivities` |
| `ProviderSettingsView.swift` | `ProviderSettingsView` struct |
| `SecretActionEnvelope.swift` | `SecretActionEnvelope` enum; `seal` |
| `TelegramView.swift` | `TelegramView` struct |
| `iCloudBridge.swift` | `iCloudBridge` class; `recordMacConfirmation`, `clearMacConfirmationForConnectionRepair` |
| `iCloudSyncEngine+Actions.swift` | `iCloudSyncEngine`: `requireIdleActionForConnectionRepair`, `reconcileActionsForConnectionRepair`, `persistCloudKitActionResponse` |
| `iCloudSyncEngine+Helpers.swift` | `iCloudSyncEngine`: `refreshHelpersSnapshot` |
| `iCloudSyncEngine+Scheduler.swift` | `iCloudSyncEngine`: `applySchedulerSnapshot`, `refreshSchedulerSnapshot` |

### Diagnostics

Directory: `iOS/NativeAgentMobile/Sources/Diagnostics/`

| File | Owns |
|---|---|
| `CKLandmine.swift` | `withCKTimeout` |
