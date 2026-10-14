import Foundation
import OSLog
import ApprovalTransactions
import BackgroundLoops
import BackgroundWork
import Browser
import ChatOrchestration
import ChatSessionWork
import Cognition
import Connectors
import ContextFlow
import Desk
import GitHubConnector
import MemoryV2
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import PersonaEngine
import SlackConnector
import Transcripts
import TurnTrace
import WorkshopExecution
import Agents
import AppToolRuntime
import ApprovalInbox
import AttentionRouting
import CognitiveSubstrate
import DeviceSync
import DoctorChecks
import DreamREMCycle
import MacControl
import ProviderRouting
import SchedulerExecution
import SelfImprovement
import SlackBot
import StandingBots
import TelegramBot
import TriggerScheduler
import TrustCenter
import TrustPersistence
import AgentWorkspace
import Darwin
import KnowledgeGraph
import MCPDispatcher
import NativeAgentShared

/// Native effects used by Core's background composition. Scheduling, admission
/// and reconciliation remain with the existing engine and background owners.
public protocol EngineBackgroundWorkHost: Sendable {
    var approvals: ApprovalTransactionCoordinator { get }
    var attention: AttentionRouter { get }
    var backupHost: TrustBackupHost { get }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult
    func notifyIfAttentionWorthy(dataRoot: URL, itemId: String, title: String, summary: String, source: String, severity: String) async
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult]
    func wakeDoctorForPendingTransitions(dataRoot: URL) async
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue], externalSendIdempotencyKey: String) async throws -> (id: String, status: String)
    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending
    var speechPermission: SpeechPermissionSnapshot { get }
    var voiceName: String { get }
    var agentSubject: String { get }
    func githubRuntime(dataRoot: URL, shared: Bool) -> GitHubCommandRuntime
    func evaluateGitHubApprovals(dataRoot: URL) async
    var triggerNotifier: TriggerNotifier { get }
    func mirrorTriggerFire(_ result: TriggerFireResult) async -> Bool
}

private struct EngineDerivedStateInvalidationSink: DerivedStateInvalidationSink {
    let dataRoot: URL
    let writeMemorySnapshot: @Sendable () async -> Void

    func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        let memoryPath = dataRoot.appendingPathComponent("memory/memory.sqlite").standardizedFileURL.path
        if changes.contains(where: {
            $0.namespace == "memory-v2" && $0.canonicalLocator == memoryPath
        }) {
            await writeMemorySnapshot()
        }
        await DerivedPersonaPinInvalidationSink(dataRoot: dataRoot).sourceDidChange(changes)
    }
}

extension NativeAgentEngine {
    public static func prepareProcessFileLimit() {
        var files = rlimit()
        if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < 10_240 {
            files.rlim_cur = min(files.rlim_max, 10_240)
            _ = setrlimit(RLIMIT_NOFILE, &files)
        }
    }

    public static func installRuntimeObservationsAtLaunch(dataRoot: URL) {
        let crashLog = BodyReport.crashBreadcrumbs(dataRoot)
        do {
            try FileManager.default.createDirectory(at: crashLog.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            BodyReport.installCrashBreadcrumbs(path: crashLog.path)
        } catch {
            ModuleLog.app("[crash-breadcrumbs] unavailable: %@", error.localizedDescription)
        }
        BackgroundLoopsManager.shared.receiveOrganPulses()
        KnowledgeGraphPoolCache.installOwner(SwiftNativeMemoryV2.knowledgeGraphPool(at:))
    }

    public static func validateProvidersAtLaunch() {
        signal(SIGPIPE, SIG_IGN)
        if let mismatch = ProviderSurfaceGroups.membershipMismatch() {
            FileHandle.standardError.write(Data(
                "[providers] surface groups and MODEL_SURFACES disagree — \(mismatch)\n".utf8))
            assertionFailure("Providers group membership: \(mismatch)")
        }
    }

    @MainActor
    public static func prepareStateAtLaunch(
        dataRoot: URL, currentVersion: String, resources: URL?, backupHost: TrustBackupHost,
        publicReleaseUnavailable: @MainActor @Sendable (String) -> Void,
        backupRestoreUnavailable: @MainActor @Sendable (String) -> Void,
        confirmMissingRoots: @MainActor @Sendable ([String]) -> Bool,
        macRecoveryUnavailable: @MainActor @Sendable () -> Void
    ) async -> Bool {
        if case .failed(let error) = await Task.detached(priority: .userInitiated, operation: {
            InstallPaths.preparePublicReleaseDataRootIfNeeded()
        }).value {
            publicReleaseUnavailable(error)
            return false
        }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try TrustBackupPersistence.resumeStagedBackupRestoreAtLaunch(dataRoot: dataRoot, host: backupHost)
            }.value
        } catch {
            backupRestoreUnavailable(error.localizedDescription)
            return false
        }
        if !InstallPaths.isPublicReleaseBundle {
            let missing = await Task.detached { PersistenceCore.missingLaunchRoots(dataRoot: dataRoot) }.value
            if !missing.isEmpty, !confirmMissingRoots(missing) { return false }
        }
        do {
            let recovered = try await MacControlOperationStore(dataRoot: dataRoot).recoverInterruptedOperations()
            ModuleLog.app("[mac-control] startup recovered interrupted operations: %d", recovered)
        } catch {
            ModuleLog.app("[mac-control] refusing startup after operation recovery failure: %@", error.localizedDescription)
            macRecoveryUnavailable()
            return false
        }
        // No state owner or ingress exists until restore and recovery succeed.
        await Task.detached(priority: .utility) {
            do { try NativeAgentBuildIdentity.current.writeLaunchStamp(root: dataRoot) }
            catch { ModuleLog.app("[launch] Could not record app start time: %@", error.localizedDescription) }
            do {
                _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
                ModuleLog.app("[workspace] canonical work root ready")
            } catch { ModuleLog.app("[workspace] canonical work root unavailable: %@", error.localizedDescription) }
            ChatUpdateNote.recordLaunchAtStartup(dataRoot: dataRoot, currentVersion: currentVersion, resources: resources)
        }.value
        _ = await Task.detached(priority: .userInitiated) { NativeAgentEngine.live }.value
        await SurfaceLayoutLive.shared.attach(dataRoot: dataRoot)
        return true
    }

    public static func installBotProviderCheck() async {
        do { try BotDefinitionStore(dataRoot: PersistenceCore.defaultDataRoot()).migrateLegacyDefinitions() }
        catch {
            FileHandle.standardError.write(Data("[bots] migration unavailable: \(error)\n".utf8))
            return
        }
        await BotRunGate.installLiveCheck { bot, dataRoot in
            do { _ = try await BotChatContract.choice(for: bot, dataRoot: dataRoot); return nil }
            catch { return String(describing: error) }
        }
    }

    public static func installActionLabelsAtLaunch() {
        let labels = AppActions.all.flatMap { action in
            [(action.id, action.label)] + (action.isFold && action.label != action.tool ? [(action.tool, action.label)] : [])
        }
        ToolActivityPresentation.installActionLabels(
            Dictionary(labels, uniquingKeysWith: { first, _ in first }))
    }

    public static func startContextFlowAtLaunch(dataRoot: URL) {
        Task.detached(priority: .utility) {
            await installDerivedStateInvalidationAtLaunch(dataRoot: dataRoot) {
                await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots(includeMemories: true)
            }
            await NativeAgentEngine.live.contextFlow.start()
        }
    }

    public static func reconcileSpeechPermissionAtLaunch(dataRoot: URL) {
        Task.detached(priority: .utility) {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
        }
    }

    @MainActor
    public static func startResidentWorkAtLaunch(
        dataRoot: URL, embeddingDescriptorURL: URL?,
        storageUnavailable: @escaping @MainActor @Sendable () -> Void,
        reindexMemory: @escaping @Sendable () async -> Void,
        registerBackgroundTasks: @MainActor () -> Void,
        waitForSenses: @escaping @Sendable () async throws -> Void,
        resumeMacTurn: @escaping @Sendable (TurnCheckpoint, TurnContinuationRuntime) async throws -> Void,
        repairPresentation: any MemoryRepairPresentationPort,
        momentsEnabled: @escaping @Sendable () -> Bool,
        approvals: ApprovalTransactionCoordinator
    ) {
        Task.detached(priority: .utility) {
            await NativeAgentEngine.live.chrome.observeBrowserLaunches()
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        }
        Task.detached(priority: .utility) {
            if await reconcileMemoryAtLaunch(dataRoot: dataRoot, storageUnavailable: storageUnavailable) {
                await reindexMemory()
            }
        }
        registerBackgroundTasks()
        WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())
        // Each bring-up remains independent so one blocked store cannot hold
        // the other resident owners or the native launch callback.
        Task.detached(priority: .utility) {
            let descriptor = embeddingDescriptorURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? EmbeddingModelDownload.Descriptor.parse($0) }
            if descriptor?.distribution != "separate-download" {
                await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
            }
        }
        BackgroundConsolidationGate.shared.install { reason in
            switch await NativeAgentEngine.liveCognition.backgroundCognitionGate(reason: reason) {
            case .allowed: return .allowed
            case .skipped(let why): return .deferred(why)
            }
        }
        Task.detached(priority: .utility) { await NativeAgentEngine.liveCognition.bootstrap() }
        Task.detached(priority: .utility) { await reconcileTranscriptsAtLaunch(dataRoot: dataRoot) }
        Task.detached(priority: .utility) {
            await startBackgroundWorkAtLaunch(
                dataRoot: dataRoot,
                github: NativeAgentEngine.live.ports.backgroundWork.githubRuntime(dataRoot: dataRoot, shared: true),
                makeLoops: {
                    _ = NativeAgentEngine.live
                    do { try await waitForSenses() }
                    catch { ModuleLog.app("[senses] Launch registration unavailable: %@", error.localizedDescription) }
                    let loops = assembleAllLoops()
                    await installBotProviderCheck()
                    return loops
                },
                resume: { checkpoint in
                    try await makeTurnContinuationRuntime(dataRoot: dataRoot)
                        .resumeAtLaunch(checkpoint, resumeMacTurn: resumeMacTurn)
                })
        }
        DoctorFacade.armFirstTurnRefresh {
            await makeAutoDoctorLoop(freshMeasurement: true).tickOutcome()
        }
        Task.detached(priority: .utility) { await reconcileDeskAtLaunch(dataRoot: dataRoot) }
        Task.detached(priority: .utility) {
            await configureMemoryPromotionAtLaunch(dataRoot: dataRoot,
                makeLLMClient: { makeSharedLLMClient() }, momentsEnabled: momentsEnabled)
        }
        Task.detached(priority: .utility) {
            await reconcileApprovalsAtLaunch(dataRoot: dataRoot, presentation: repairPresentation,
                makeLLMClient: { makeSharedLLMClient() }, approvals: approvals,
                stagePendingREMProposals: { await stagePendingREMProposalsAtLaunch() })
        }
    }

    public static func waitForInFlightTurnsBeforeQuit(
        _ runs: Set<String>, isRestarting: @escaping @Sendable () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while !NativeAgentEngine.live.turns.inFlightRunIDs().isDisjoint(with: runs),
              ContinuousClock.now < deadline, !isRestarting() {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let left = NativeAgentEngine.live.turns.inFlightRunIDs().intersection(runs).count
        ModuleLog.app("[quit] %@", left == 0 ? "turns finished — quitting" : "\(left) turn(s) still running at the bound — quitting anyway")
    }

    @MainActor
    public static func drainResidentWorkForTermination(
        shutdownSenses: @escaping @Sendable () async -> Void,
        makeActivityWatchDrain: @MainActor () -> Task<Void, Never>
    ) {
        let group = DispatchGroup()
        group.enter()
        Task.detached { await NativeAgentEngine.live.chrome.stop(); group.leave() }
        group.enter()
        Task.detached { await NativeAgentEngine.liveCognition.flushForTermination(); group.leave() }
        group.enter()
        Task.detached { await TurnPlanTraceWriter.shared.drain(); group.leave() }
        group.enter()
        Task.detached { await BackgroundLoopsManager.shared.shutdown(); group.leave() }
        group.enter()
        Task.detached { await shutdownSenses(); group.leave() }
        group.enter()
        Task.detached { await SwiftNativeMCPDispatcher.stopAllSharedPools(); group.leave() }
        group.enter()
        Task.detached { await SwiftToolDispatcher.closeACPConnections(); group.leave() }
        group.enter()
        Task.detached { await NativeAgentEngine.live.contextFlow.stop(); group.leave() }
        group.enter()
        // Create the native drain before the main actor enters the bounded wait.
        let activityWatchDrain = makeActivityWatchDrain()
        Task.detached { await activityWatchDrain.value; group.leave() }
        _ = group.wait(timeout: .now() + 3.0)
    }

    public static func prepareContextForSleep() {
        Task.detached(priority: .utility) { await NativeAgentEngine.live.contextFlow.prepareForSleep() }
    }

    public static func reconcileContextAfterWake() {
        Task.detached(priority: .utility) {
            await NativeAgentEngine.live.contextFlow.reconcileAfterWake()
            await NativeAgentEngine.liveCognition.reanchorDeadlinesAfterWake()
        }
    }

    @MainActor
    public static func startDeviceSyncAtLaunch(
        forward: @escaping (BridgeMessage) async -> Bool,
        registerLoginItem: @MainActor () -> Void
    ) {
        Task { @MainActor in
            NativeAgentEngine.liveDeviceSync.bridge.setup()
            NativeAgentEngine.liveDeviceSync.bridge.observeIncomingMessages(onMessage: forward)
        }
        Task.detached(priority: .userInitiated) { await PairingSecretManager.publishMaterialToKVS() }
        if NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: PersistenceCore.defaultDataRoot()) {
            registerLoginItem()
        }
    }


    public static func reconcileMemoryAtLaunch(
        dataRoot: URL,
        storageUnavailable: @MainActor @Sendable () -> Void
    ) async -> Bool {
        let logger = Logger(subsystem: "com.nativeagent.app", category: "memory-migration")
        let canonicalStorage: MemoryStorage
        do {
            canonicalStorage = try await SwiftNativeMemoryV2.resolvedStorage(
                dataRoot: dataRoot
            )
        } catch {
            logger.error("MemoryV2 canonical storage unavailable; migration and projections refused: \(String(describing: error), privacy: .public)")
            await storageUnavailable()
            return false
        }
        let report = await MemoryV2Migrator(
            dataRoot: dataRoot,
            storage: canonicalStorage
        ).migrate()
        if report.skippedAlreadyMigrated {
            logger.info("MemoryV2 migration: already complete; skipped")
        } else {
            logger.info(
                "MemoryV2 migration: memories=\(report.memoriesImported, privacy: .public) proposals=\(report.proposalsImported, privacy: .public) tombstones=\(report.tombstonesImported, privacy: .public) errors=\(report.errors.count, privacy: .public)"
            )
            for err in report.errors.prefix(5) {
                logger.error("MemoryV2 migration error: \(err, privacy: .public)")
            }
        }
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "migration",
            operation: .reconcile,
            reason: "memory_migration_finished"
        ))
        await DerivedStateInvalidationCenter.shared.flush()
        guard report.requiredFailures == 0 else {
            logger.error("MemoryV2 derived projection reconciliation refused because migration is incomplete")
            return false
        }

        // A full graph rebuild is only required when this launch actually
        // crossed the canonical migration boundary. On healthy launches,
        // the shared MemoryV2 startup hook performs a bounded additive
        // backfill instead of deleting and recreating every graph row.
        // 2026-09-11: a pending statement retired by its own correction must
        // not leave a tombstone that blocks the correction (Astra comb 1).
        // Idempotent, no-op once clean.
        await SwiftNativeMemoryV2.shared.repairSupersededTombstones()
        if !report.skippedAlreadyMigrated {
            do {
                _ = try await SwiftNativeMemoryV2.shared.reconcileKnowledgeGraphProjection()
            } catch {
                logger.error("MemoryV2 Knowledge Graph reconciliation failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let generator = await SwiftNativeMemoryV2.shared.bindUserMDGenerator(
            dataRoot: dataRoot,
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        ) {
            do {
                _ = try await generator.regenerate()
            } catch UserMDGeneratorError.onboardingIncomplete {
                // Expected on a blank install; onboarding owns first write.
            } catch {
                logger.error("MemoryV2 USER.md reconciliation failed: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    public static func reconcileTranscriptsAtLaunch(dataRoot: URL) async {
        let logger = Logger(subsystem: "com.nativeagent.app", category: "chat-reconciliation")
        do {
            let report = try await ChatSessionIndexReconciler(
                dataRoot: dataRoot
            ).reconcile()
            OrganPulse.record("launch.chat_index", found: report.sessionsRecovered + report.staleRowsRepaired + report.corruptTranscripts,
                              note: "recovered \(report.sessionsRecovered), repaired \(report.staleRowsRepaired), corrupt \(report.corruptTranscripts) of \(report.transcriptsExamined)")
            if report.sessionsRecovered > 0 || report.corruptTranscripts > 0
                || report.staleRowsRepaired > 0 {
                logger.info(
                    "Chat reconciliation: recovered=\(report.sessionsRecovered, privacy: .public) repaired=\(report.staleRowsRepaired, privacy: .public) corrupt=\(report.corruptTranscripts, privacy: .public) examined=\(report.transcriptsExamined, privacy: .public)"
                )
            }
        } catch {
            logger.error("Chat reconciliation refused: \(String(describing: error), privacy: .public)")
        }
    }

    public static func reconcileDeskAtLaunch(dataRoot: URL) async {
        // Reconcile historical Desk feeds written before parent/child
        // terminal-state invariants existed. The store repairs by appending
        // ordinary set_status ops under its canonical flock; it never
        // rewrites the event log or hot-edits desk_state.json.
        do {
            let ops = try await SwiftNativeDeskStore(
                dataRoot: dataRoot
            ).reconcileTerminalParentsWithNonTerminalDescendants()
            OrganPulse.record("launch.desk_hierarchy", found: ops.count, note: "\(ops.count) statuses set")
        } catch {
            FileHandle.standardError.write(
                Data("Desk hierarchy reconciliation failed: \(error)\n".utf8)
            )
        }
    }

    public static func reconcileApprovalsAtLaunch(
        dataRoot: URL,
        presentation: any MemoryRepairPresentationPort,
        makeLLMClient: @escaping @Sendable () -> any LLMClient,
        approvals: ApprovalTransactionCoordinator,
        stagePendingREMProposals: @Sendable () async -> Int
    ) async {
        // Reconcile before staging: a crash after approval but before execution
        // leaves a staging stamp that would otherwise prevent repair forever.
        let repairs = await MemoryApprovalTransactions.reconcileUnappliedMemoryRepairs(dataRoot: dataRoot)
        OrganPulse.record("launch.memory_repairs", found: repairs, note: "\(repairs) re-run")
        await MemoryRepairOneShot.stageIfNeeded(
            dataRoot: dataRoot,
            presentation: presentation)
        await LegacyCorrectionScopeMigration.runIfNeeded(dataRoot: dataRoot)
        // Backfills and swaps use the same approved-execution recovery path.
        let backfills = await MemoryApprovalTransactions.reconcileUnappliedKindBackfills(dataRoot: dataRoot)
        OrganPulse.record("launch.kind_backfills", found: backfills, note: "\(backfills) re-run")
        await MemoryApprovalTransactions.stageKindBackfillIfNeeded(
            dataRoot: dataRoot,
            makeLLMClient: makeLLMClient
        )
        var settled = 0, failures: [String] = []
        for swap in await MemoryConsolidationGate.reconcile(dataRoot: dataRoot) {
            switch swap {
            case .applied, .alreadyApplied, .staleRefused, .cleanedUpDenied: settled += 1
            case .pendingApproval: break
            case .failed(let runId, let reason), .projectionFailed(let runId, let reason): failures.append("\(runId): \(reason)")
            }
        }
        if failures.isEmpty {
            OrganPulse.record("launch.consolidation_swaps", found: settled, note: "\(settled) settled")
        } else {
            OrganPulse.record("launch.consolidation_swaps", .skipped,
                              note: "\(settled) settled, \(failures.count) failed: " + failures.joined(separator: "; "))
        }
        // Close stranded browser effects before approval reconciliation so
        // repairing an annotation cannot reopen an outcome-unknown navigation.
        do {
            let stranded = try await SwiftNativeBrowserClient.defaultClient()
                .executeBrowserOperation(.recoverStrandedRunning).recoveredCount
            OrganPulse.record("launch.browser_stranded", found: stranded, note: "\(stranded) closed as outcome unknown")
        } catch {
            nativeLog("[browser] restart recovery failed: %@", String(describing: error))
        }
        let approvals = await approvals.reconcileUnappliedApprovalExecutions()
        OrganPulse.record("launch.approval_executions", found: approvals, note: "\(approvals) re-run")
        Task { await ApprovalTransactionCoordinator.settleDeskWaitsOnEveryResolve(dataRoot: dataRoot) }
        // Revalidate legacy evidence before staging the same local-only review
        // as terminal-event reconciliation; unverified procedures stay off.
        let procedureDataRoot = dataRoot
        let keptOff = await WorkshopProcedureLegacyRevalidation.runIfNeeded(dataRoot: procedureDataRoot)
        OrganPulse.record("launch.procedure_revalidation", found: keptOff.count, note: "\(keptOff.count) kept off")
        for line in keptOff {
            let cardID = "procedure-legacy-revalidation-\(CausalTransitionEvidence.opaqueIdentity(line).prefix(16))"
            _ = try? await LiveNotificationInbox(
                path: LiveNotificationInbox.livePath(dataRoot: procedureDataRoot)
            ).appendUnique(.object([
                "id": .string(cardID),
                "created_at": .string(NativeTimestampFormat.fractionalZulu(Date())),
                "source": .string("workshop"),
                "severity": .string("info"),
                "title": .string("A saved procedure stays off"),
                "summary": .string(line),
                "actions": .array([.object(["id": .string("dismiss"), "label": .string("Dismiss"),
                                            "description": .string("Dismiss this card")])]),
                "status": .string("unread"),
            ]), id: cardID)
        }
        let activationCards = await WorkshopProcedureExactActivationCoordinator
            .reconcileLocalFileCopyIfQualified()
        OrganPulse.record("launch.procedure_activation", found: activationCards, note: "\(activationCards) review staged")
        // Catch up existing unstaged REM rows without generating another batch.
        let remStaged = await stagePendingREMProposals()
        OrganPulse.record("launch.rem_staging", found: remStaged, note: "\(remStaged) staged")
    }

    public static func reconcileConnectorCredentialsAtLaunch(
        dataRoot: URL, github: @escaping @Sendable () -> GitHubCommandRuntime
    ) async {
        // Before Slack's ingress starts: its tokens move from files to Keychain.
        do { try SlackCredentials.migrate(dataRoot: dataRoot) }
        catch { nativeLog("[slack-credential] Keychain migration failed: %@", error.localizedDescription) }
        do { try await ConnectorOAuthRegistry.migrateXCredentials(dataRoot: dataRoot) }
        catch { nativeLog("[x-credential] Keychain migration repair state unavailable: %@", error.localizedDescription) }
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.nativeagent.app", category: "github-credential")
            let github = github()
            await github.replayResidentStateAtLaunch()
            do {
                let configured = try await GitHubCredentialStore.shared.reconcileAtLaunch(
                    dataRoot: dataRoot
                )
                if configured {
                    logger.info("GitHub credential Keychain reconciliation complete")
                    await github.recoverAtLaunch()
                }
            } catch {
                logger.error(
                    "GitHub credential Keychain reconciliation failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    public static func prepareExecutionStorageAtLaunch(dataRoot: URL) async throws {
        // 2026-09-18: a first-format migration can visit every execution.
        // Let AppKit finish launching while it runs; runtime ingress and
        // schedulers below still start only after the migration succeeds.
        let report = try await WorkshopStorageMigrator.prepareForReading(dataRoot: dataRoot)
        if report.didMigrate {
            // P2-7: the legacy missions/ absorption is deleted; the only
            // passes that can report didMigrate now are the execution.json
            // record rename and receipts_dir pointer repair.
            nativeLog(
                "[workshop-migration] normalized execution records: changed=%d conflicts=%d receipt=%@",
                report.moved.count,
                report.conflictsPreservedInArchive.count,
                report.receiptRelativePath ?? "none"
            )
        }
    }

    public static func installDerivedStateInvalidationAtLaunch(
        dataRoot: URL, writeMemorySnapshot: @escaping @Sendable () async -> Void
    ) async {
        await DerivedStateInvalidationCenter.shared.install(
            EngineDerivedStateInvalidationSink(dataRoot: dataRoot, writeMemorySnapshot: writeMemorySnapshot))
    }

    public static func startBackgroundWorkAtLaunch(
        dataRoot: URL,
        github: GitHubCommandRuntime,
        makeLoops: @Sendable () async -> [LoopRegistration],
        resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void
    ) async {
        // Prime GitHub before refresh can publish, then start reply journal
        // owners before the checkpoint sweep hands resumed answers to them.
        await github.replayResidentStateAtLaunch()
        let loops = await makeLoops()
        await BackgroundLoopsManager.shared.start(loops: loops)
        await AbandonedTurnReconciliationHook.arm(completedTurnNotification: .chatTurnCompleted,
            inFlight: { Set(ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).map(\.turnId)) },
            resume: resume)
    }

    public static func configureMemoryPromotionAtLaunch(
        dataRoot: URL,
        makeLLMClient: @escaping @Sendable () -> any LLMClient,
        momentsEnabled: @escaping @Sendable () -> Bool
    ) async {
        await AdaptiveMemoryPromoter.shared.configure(
            memory: SwiftNativeMemoryV2.shared,
            memoryManager: MindMemoryManager(makeLLMClient: makeLLMClient),
            momentsEnabled: momentsEnabled,
            adaptivePromotionEnabled: { MemoryPolicyGate.adaptivePromotionEnabled() },
            personName: { NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) }
        )
    }

    public static func startBackgroundLoops() async {
        guard !(await BackgroundLoopsManager.shared.isRunning()) else { return }
        await startBackgroundLoops(loops: assembleAllLoops())
    }

    public static func startBackgroundLoops(loops: [LoopRegistration]) async {
        let manager = BackgroundLoopsManager.shared
        let dataRoot = PersistenceCore.defaultDataRoot()
        await manager.setFailureOutcome { loopId, error in
            await MaintenanceBackgroundWork.fileLoopFailureNotice(
                dataRoot: dataRoot, loopId: loopId, error: error)
        }
        await manager.setFailureRecoveryPush { loopId, healthyAt in
            await MaintenanceBackgroundWork.resolveLoopFailureNotice(
                dataRoot: dataRoot, loopId: loopId, healthyAt: healthyAt)
        }
        guard await manager.start(loops: loops) else { return }
        Task { await live.ports.backgroundWork.wakeDoctorForPendingTransitions(dataRoot: dataRoot) }
        // Refresh the heartbeat receipt after restart without blocking startup.
        Task { await manager.runTickOnce(loopId: "heartbeat") }
        guard NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) else { return }
        let config = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        if (config.enabled ?? true) && (config.runOnStartup ?? true) {
            Task { await manager.runTickOnce(loopId: "doctor_auto_run") }
        }
    }

    @discardableResult
    public static func runBackgroundLoopOnce(loopId: String) async -> LoopTickOutcome {
        let manager = BackgroundLoopsManager.shared
        if !(await manager.isRunning(loopId: loopId)) {
            await startBackgroundLoops(loops: assembleAllLoops())
        }
        return await manager.runTickOnce(loopId: loopId)
    }

    @discardableResult
    public static func restartBackgroundLoop(id: String, manager: BackgroundLoopsManager = .shared) async -> LoopRestartOutcome {
        await MaintenanceBackgroundWork.restartLoop(id: id, manager: manager, replacementLoop: { id in
            switch id {
            case "telegram_poll":
                return makeTelegramPollLoopIfConfigured().map(LoopRegistration.enabled)
                    ?? .disabled(loopId: "telegram_poll", reason: telegramUnconfiguredReason)
            case "slack_socket_mode": return makeSlackSocketModeLane()
            case "doctor_auto_run": return .enabled(makeAutoDoctorLoop())
            default: return nil
            }
        })
    }
}

extension NativeAgentEngine {

    /// Shared LLM client used by background REM/self-improvement/reflection
    /// lanes. SwiftNativeLLMClient routes by model-id prefix to the three
    /// real backend adapters (Anthropic / OpenAI / Codex CLI). Default
    /// model resolution falls back to the router's "chat" surface preference.
    /// Resolve the one cognition owner for a loop body. Alternate roots must
    /// never observe or mutate the process-global personal runtime.
    public static func cognitionRuntime(
        for dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> NativeCognitionRuntime {
        let standardized = dataRoot.standardizedFileURL
        return standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? NativeAgentEngine.liveCognition
            : NativeCognitionRuntime(dataRoot: standardized, host: NativeAgentEngine.live.ports.cognitionHost,
                                     contextFlow: NativeContextFlowRuntime(dataRoot: standardized))
    }

    /// Body work shares the resident turn provider assembly and its exact
    /// credential/routing resolution, without adding a persona prompt.
    /// Background calls carry the same idle and wall as resident turns, so one
    /// stalled call cannot hold the memory promotion chain forever.
    public static func makeSharedLLMClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> any LLMClient {
        let runtime = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        guard dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return PersonaBackedBackgroundLLMClient(
                inner: AlternateRootUnavailableBackgroundLLMClient(),
                dataRoot: dataRoot,
                cognitionRuntime: runtime
            )
        }
        let inner = makeResidentProviderLLMClient(dataRoot: dataRoot, lifecycleObserver: runtime)
        return PersonaBackedBackgroundLLMClient(
            inner: inner,
            dataRoot: dataRoot,
            cognitionRuntime: runtime
        )
    }
    /// Full loop manifest for BackgroundLoopsManager: doctor,
    /// memory, self-improvement, Workshop execution executor, heartbeat, and hooks.
    /// A periodic dream wrapper is intentionally absent from this manifest:
    /// unattended dreams have exactly one owner, the `nativeagent-nightly-dream`
    /// TriggerScheduler job at 03:30 America/Chicago. A periodic REM wrapper is
    /// absent for the same reason: `nativeagent-weekly-rem` at 04:30
    /// America/Chicago on Sundays owns weekly REM.
    public static func assembleAllLoops(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [LoopRegistration] {
        let cognition = cognitionRuntime(for: dataRoot)
        let llm = makeSharedLLMClient(dataRoot: dataRoot, cognitionRuntime: cognition)
        let runners: [any LoopRunner] = [
            makeAutoDoctorLoop(dataRoot: dataRoot),
            makeTurnTraceRetentionLoop(dataRoot: dataRoot),
            makeOffDiskBackupLoop(dataRoot: dataRoot),
            // Tightness round 2 item 6: daily disk-hygiene watchdog — detects
            // oversized files / an over-budget data/ tree and files ONE inbox
            // card. Detect-never-delete.
            makeDataRootDiskHygieneLoop(dataRoot: dataRoot),
            MemoryConsolidationHygieneRunner(dataRoot: dataRoot),
            makeWeeklySelfImprovementLoop(dataRoot: dataRoot, llm: llm),
            // No `rem_cycle` entry: the `nativeagent-weekly-rem` TriggerScheduler
            // job is the sole owner of weekly REM (see the manifest note above).
            // User-authored scheduler jobs and time/idle triggers use exact
            // persisted deadlines plus config/activity invalidations. Core owns
            // the only lifecycle; the six-hour cadence is missed-event repair.
            makeTriggerSchedulerLoop(dataRoot: dataRoot),
            makeWorkshopExecutorLoopRunner(dataRoot: dataRoot, cognitionRuntime: cognition),
            // Wave B (desk-workshop Phase 1): the Workshop pump. Zero-LLM heart —
            // a quiet day makes no provider call; organism-gated (runs only in a
            // `normal` posture), reserves a Desk slot BEFORE any session, and
            // runs one bounded work session behind the WorkshopToolProfile
            // membrane. Distinct from the execution executor above (Phase 2 re-homes
            // that engine); this is the new self-pursuit work lane.
            makeWorkshopPumpLoop(dataRoot: dataRoot, cognitionRuntime: cognition),
            CognitiveMaintenanceLoop(interval: 24 * 60 * 60, runtime: cognition),
            CognitiveReplayLoop(interval: 24 * 60 * 60, runtime: cognition),
            CognitiveReflectionLoop(interval: 24 * 60 * 60, llm: llm, runtime: cognition),
            // Cue authoring stays available as an explicit/manual seam, but is
            // absent from production scheduling until it has a live consumer.
            // This avoids both unattended model spend and a dead 10-minute wake.
            // U2b wave 3 lane A: interval health heartbeat.
            makeHeartbeatLoop(dataRoot: dataRoot),
            // U4 Wave C: autonomy-promotion PROPOSAL loop (cards only; applies
            // human-approved promotions via a re-verifying reconcile).
            AutonomyBackgroundWork.makeAutonomyPromotionLoop(dataRoot: dataRoot, events: EngineBackgroundWorkPort()),
            // Desk notify (2026-06-29): desk-side push when a direct/urgent
            // tracked item changes. A SEPARATE loop from the cognition manifest
            // above — it reads desk state and pings User, never touching the
            // CognitiveSubstrate. Self-gating (no-op unless an item is marked).
            makeDeskNotifyLoop(dataRoot: dataRoot),
            // W2b (upgrade campaign Track A): delegation terminal-transition
            // cards. Reads the two wake-job stores through the same projector
            // `delegation_status` uses and files ONE card per newly-terminal
            // job, keyed off a durable cursor so a job cards exactly once.
            makeDelegationOutcomeLoop(dataRoot: dataRoot),
            // Configured GitHub projects flow into durable Desk refs/items.
            // The runner is due-driven and change-idempotent; no config or no
            // material remote change means no state write and no notification.
            makeGitHubTrackingLoop(dataRoot: dataRoot),
        ]
        var loops = runners.map(LoopRegistration.enabled)
        loops.append(
            makeTelegramPollLoopIfConfigured(dataRoot: dataRoot)
                .map(LoopRegistration.enabled)
                ?? .disabled(
                    loopId: "telegram_poll",
                    reason: telegramUnconfiguredReason
                )
        )
        loops.append(makeSlackSocketModeLane(dataRoot: dataRoot))
        return loops
    }
}



// MARK: - Chat Surface Loops

extension NativeAgentEngine {
    public static let telegramUnconfiguredReason =
        "telegram not configured (no enabled bot token in telegram/config.json)"

    /// The configured Socket Mode worker, or a visible disabled lane.
    public static func makeSlackSocketModeLane(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> LoopRegistration {
        SlackSocketModeLoop.ifConfigured(
            dataRoot: dataRoot,
            chatClient: { NativeAgentEngine.live.chatClient(profile: .slack) },
            // 2026-09-22: fire-and-forget — the reply must not wait on a busy
            // main thread just to tell the Mac UI to reload.
            turnCompleted: { sessionID in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                }
            },
            botEventIntake: { channelId, text, userId in
                await BotEventIntake.slackMessage(channelId: channelId, text: text,
                                                 userId: userId, dataRoot: dataRoot,
                                                 isAutonomyEnabled: {
                    await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
                })
            }
        ).map(LoopRegistration.enabled) ?? .disabled(
            loopId: "slack_socket_mode",
            reason: SlackSocketModeLoop.offReason(dataRoot: dataRoot)
        )
    }

    // Swift Telegram long-poll loop wiring. Only enabled when
    // a real token + enabled=true sit on disk; assembly keeps the disabled
    // lane visible when no worker can be constructed.
    public static func makeTelegramPollLoopIfConfigured(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> TelegramPollLoop? {
        guard let cfg = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              cfg.enabled, !cfg.botToken.isEmpty
        else { return nil }
        // Build the Swift-native chat-orchestration client lazily so we don't
        // pay the LLM-client construction cost when no Telegram traffic flows.
        // The profiled app client factory is idempotent — each call builds a
        // fresh client over the same on-disk data root.
        // Brain state has one owner: providers/surfaces.json. Resolve it at
        // handler time so /model, /think, /fast, Mac settings, and iPhone
        // controls all affect the very next turn without restarting this loop.
        let providerDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let providerRouting = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: providerDir.appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: providerDir.appendingPathComponent("active.json")
        )
        let telegramSessions = TelegramSessionStore(dataRoot: dataRoot)
        let approvalFiler = TelegramApprovalFiler(
            dataRoot: dataRoot,
            token: cfg.botToken,
            promptSender: { token, chatId, approval, toolName, payload in
                try await TelegramApprovalFiler.sendTelegramApprovalPrompt(
                    token: token, chatId: chatId, approval: approval,
                    toolName: toolName, payload: payload,
                    send: TelegramPollLoop.defaultSendMessageWithReplyMarkup
                )
            },
            approvalResolver: { id, decision, provenance in
                _ = try await NativeAgentEngine.live.ports.backgroundWork.approvals.resolveApproval(
                    id: id, decision: decision.rawValue, provenance: provenance
                )
            }
        )
        TelegramApprovalFilerRef.shared.configure(approvalFiler)
        Task { await ApprovalChatCards.promptPending(dataRoot: dataRoot, telegram: approvalFiler) }
        // Keep the exact Telegram profile and approval filer resident for the
        // loop lifetime. Routing/policy remain per-turn snapshots; only the
        // stateless orchestration graph and schema caches are reused.
        let client = NativeAgentEngine.live.chatClient(
            profile: .telegram,
            approvalFiler: approvalFiler
        )
        let telegramBot = SwiftNativeTelegramBot(
            dataRoot: dataRoot,
            completenessDeps: TelegramBotCompletenessDeps(
                routing: TelegramProviderRoutingBridge(
                    routing: providerRouting,
                    dataRoot: dataRoot,
                    accountCatalog: TelegramAccountModelCatalogPort(
                        isAccountBackedProvider: { CodexSelectableModelCatalog.isAccountBackedProvider($0) },
                        chatGPTOAuthCacheCandidate: { CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: $0) },
                        load: { provider, cacheURL, useDefaultCacheWhenNil in
                            CodexSelectableModelCatalog.load(
                                providerID: provider,
                                cacheURL: cacheURL,
                                useDefaultCacheWhenNil: useDefaultCacheWhenNil
                            ).map { model in
                                TelegramModelChoice(
                                    id: model.id,
                                    name: model.displayName,
                                    isCurrent: false,
                                    supportedReasoningEfforts: model.supportedReasoningEfforts,
                                    supportsFast: model.supportsFast
                                )
                            }
                        }
                    )
                ),
                memory: TelegramMemoryWriterBridge(dataRoot: dataRoot),
                restart: TelegramRestartBridge(dataRoot: dataRoot, deferredRestart: { reason in
                    await AppRestartCoordinator.shared.requestRestartDeferringTerminate(
                        reason: reason,
                        source: "telegram:/restart"
                    )
                })
            ),
            compactionHandler: { sessionId in
                let model = await providerRouting.modelStringForSurface("compaction") ?? ""
                let outcome = try await client.compactSession(
                    sessionId: sessionId,
                    model: model,
                    surface: "telegram",
                    force: true
                )
                if outcome.compacted {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionId)
                    }
                }
                return outcome
            }
        )
        let handler = ChatSurfaceBackgroundWork.makeTelegramChatHandler(
            dataRoot: dataRoot,
            telegramSessions: telegramSessions,
            client: client,
            turnCompleted: { sessionID in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                }
            }
        )
        return TelegramPollLoop(
            interval: 0.25,
            token: cfg.botToken,
            revokeDriverControl: { await MacAttentionSessionStore.shared.revokeDriverControl() },
            allowedChatIds: cfg.allowedChatIds,
            allowedUserIds: cfg.allowedUserIds,
            requireMention: cfg.requireMention,
            bot: telegramBot,
            dataRoot: dataRoot,
            offsetURL: dataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json"),
            syncCommandMenu: TelegramPollLoop.defaultSyncCommandMenu,
            approvalHandler: approvalFiler,
            attachmentChatHandler: handler,
            // Memory promotion already runs under the turn engine's ownership.
            // Telegram completion must not wait for this optional background work.
            voiceTranscriber: makeTelegramVoiceTranscriber(cfg: cfg, dataRoot: dataRoot),
            onCapabilityDenied: { capability in
                await fileSystemPermissionNotice(capability: capability, dataRoot: dataRoot)
            },
            voiceMaxBytes: cfg.voiceMaxBytes
        )
    }

    public static func fileSystemPermissionNotice(capability: String, dataRoot: URL) async {
        await ChatSurfaceBackgroundWork.fileSystemPermissionNotice(
            capability: capability, dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission },
            notify: { root, id, title, summary, source, severity in
                await NativeAgentEngine.live.ports.backgroundWork.notifyIfAttentionWorthy(
                    dataRoot: root, itemId: id, title: title, summary: summary,
                    source: source, severity: severity)
            })
    }

    public static func retireSystemPermissionCardIfGranted(dataRoot: URL) async {
        await ChatSurfaceBackgroundWork.retireSystemPermissionCardIfGranted(
            dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission })
    }

    /// The Telegram surface's one transcriber factory. Keeping this at the
    /// assembly boundary means the config chooses a backend once, while each
    /// inbound voice note still executes through the shared poll-loop error and
    /// permission-card path.
    public static func makeTelegramVoiceTranscriber(
        cfg: TelegramBot.TelegramConfig,
        dataRoot: URL
    ) -> SwiftAppleSpeechTranscriber? {
        guard cfg.voiceTranscriptionEnabled else { return nil }
        return SwiftAppleSpeechTranscriber(contextualStrings: { [NativeAgentEngine.live.ports.backgroundWork.voiceName] })
    }

}



extension NativeAgentEngine {
    public static func makeTurnContinuationRuntime(dataRoot: URL) -> TurnContinuationRuntime {
        TurnContinuationRuntime(dataRoot: dataRoot, engine: .forRoot(dataRoot),
            telegramApprovalFiler: { TelegramApprovalFilerRef.shared.current() },
            makeSender: { silent, notificationID, authorize in
                NativeAgentEngine.live.ports.backgroundWork.makeCompletionSender(dataRoot: dataRoot, silentTelegram: silent,
                    requestedResultDeliveryID: notificationID, authorizeTelegramReply: authorize)
            })
    }

}


extension NativeAgentEngine {
    public static func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        DelegationBackgroundWork(port: EngineBackgroundWorkPort()).makeDelegationOutcomeLoop(dataRoot: dataRoot, configRoot: configRoot)
    }
}

extension EngineBackgroundWorkPort: DelegationBackgroundWorkPort {
    func letGoReplies(deliveryIDs: Set<String>, outcome: String, dataRoot: URL, configRoot: URL) async throws {
        try await CodexCompletionLifecycle.letGoReplies(deliveryIDs: deliveryIDs, outcome: outcome,
            dataRoot: dataRoot, configRoot: configRoot)
    }

    func reconcileReplyDeliveries(dataRoot: URL) async throws {
        try await NativeAgentEngine.live.agents.continuation.reconcileReplies()
        try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: dataRoot).reconcileReplyMirror()
        if let telegram = await BackgroundLoops.BackgroundLoopsManager.shared.loopRunner(loopId: "telegram_poll") as? TelegramPollLoop {
            try await telegram.reconcileSavedReplies()
        }
        if let slack = await BackgroundLoops.BackgroundLoopsManager.shared.loopRunner(loopId: "slack_socket_mode") as? SlackSocketModeLoop {
            try await slack.reconcileSavedReplies()
        }
    }
    func retryRequestedResults(dataRoot: URL) async throws {
        try await NativeAgentEngine.live.ports.backgroundWork.attention.retryRequestedResults(dataRoot: dataRoot)
    }

    var agentSubject: String { NativeAgentEngine.live.ports.backgroundWork.agentSubject }

    func observeMotorActionState(_ model: MotorActionReadModel) async {
        await NativeAgentEngine.liveCognition.observeMotorActionState(model)
    }

    func reconcileAgentConversations() async throws {
        try await NativeAgentEngine.live.agents.continuation.tick()
    }

    func nextConversationDeadline(after now: Date) -> Date? {
        NativeAgentEngine.live.agents.continuation.nextDeadline(after: now)
    }
}


// MARK: - Desk notify loop (desk-side push, NO cognition)
//
// A throttled, desk-local loop that lets the Desk tap User on the shoulder: it
// reads desk state, asks DeskNotifyEvaluator which direct/urgent items changed
// since their last ping (cooldown-gated), fires a Mac banner + paired-device
// push for each, then stamps lastNotifiedAt so a single change can't fan out
// into duplicate pings (Agent's idempotency requirement).
//
// This NEVER touches the CognitiveSubstrate — it's a SEPARATE loop from the
// cognition manifest in assembleAllLoops. The desk reaches out to User; it does
// not live in her head (User's hard line, 2026-06-29). Self-gating: with no
// item marked direct/urgent, every tick is a cheap state-read that returns nil.

extension NativeAgentEngine {
    public static func makeDeskNotifyLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 24 * 60 * 60,
        postMacNotification: @escaping @Sendable (String, String, [String: String], String?) async -> Bool = { title, body, userInfo, sound in
            await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(title: title, body: body, userInfo: userInfo, soundName: sound).posted
        }
    ) -> some LoopRunner {
        DeskNotifyRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot,
            attention: NativeAgentEngine.live.ports.backgroundWork.attention,
            postMacNotification: postMacNotification,
            postNagNotification: { title, body, handle in
                await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(
                    title: title, body: body,
                    userInfo: handle.map { [NativeAgentNotificationRoute.deskHandleKey: $0] } ?? [:],
                    soundName: nil
                ).posted
            }
        )
    }
}


extension NativeAgentEngine {
    public static let remStagingCatchUpLimit = DreamBackgroundWork.remStagingCatchUpLimit

    @discardableResult
    public static func stagePendingREMProposalsAtLaunch(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        limit: Int = remStagingCatchUpLimit,
        stager: REMApprovalStager? = nil
    ) async -> Int {
        await DreamBackgroundWork.stagePendingREMProposalsAtLaunch(
            dataRoot: dataRoot, limit: limit, stager: stager,
            notifications: EngineREMProposalNotifications()
        )
    }

}

// MARK: - Dream and REM runs

extension NativeAgentEngine {
    /// One dream pass, for the scheduled nightly and the manual run alike:
    /// the same MemoryV2 Self-half, felt tone, felt origins (the diary names
    /// the journal entry a feeling came from), receipts and mood sink as the
    /// background loop, so neither path silently dreams with an empty
    /// Self-half. A committed dream then reaches the organism.
    public static func runDream(
        dataRoot root: URL,
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = SwiftNativeDreamREMCycle(
            dataRoot: root,
            gate: await CognitionViewFacade(dataRoot: root).dreamGate(),
            dreamMemoryDeltaProvider: DreamBackgroundWork.makeDreamMemoryDeltaProvider(dataRoot: root),
            dreamFeltSummaryProvider: DreamBackgroundWork.makeDreamFeltSummaryProvider(cognitionRuntime: cognitionRuntime(for: root)),
            dreamFeltOriginProvider: DreamBackgroundWork.makeDreamFeltOriginProvider(cognitionRuntime: cognitionRuntime(for: root)),
            dreamReceiptSink: DreamBackgroundWork.makeDreamReceiptSink(cognitionRuntime: cognitionRuntime(for: root)),
            // …and the dream's mood flows back out into her slow disposition
            // layer, for the same reason (U2a, 2026-07-09).
            dreamMoodSink: DreamBackgroundWork.makeDreamMoodSink(cognitionRuntime: cognitionRuntime(for: root)),
            lifecycleObserver: cognition
        )
        return try await DreamBackgroundWork.runDream(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition,
            force: force, trigger: trigger
        )
    }

    /// Weekly REM consolidation. It stages approvals like the background
    /// loop, so a manual run's proposals reach the inbox. `force` defaults to
    /// the manual behaviour (the weekly marker is distinct from the
    /// one-dream-per-night diary contract); the persisted Sunday job passes
    /// false so a "Run REM now" earlier the same week and the 04:30 job never
    /// distil the same dreams twice.
    public static func runRem(dataRoot root: URL, force: Bool = true) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = makeDreamREMCycle(
            root: root,
            gate: try await CognitionViewFacade(dataRoot: root).dreamGateChecked(),
            remStageApproval: DreamBackgroundWork.makeREMProposalStager(dataRoot: root, notifications: EngineREMProposalNotifications()),
            lifecycleObserver: cognition
        )
        return try await DreamBackgroundWork.runREM(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition, force: force
        )
    }
}

private struct EngineREMProposalNotifications: REMProposalNotificationPort {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }
}


extension NativeAgentEngine {
    public static func makeGitHubTrackingLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some EventDeadlineLoopRunner {
        GitHubTrackingBackgroundWork.makeGitHubTrackingLoop(
            dataRoot: dataRoot, intervalSeconds: intervalSeconds,
            port: EngineGitHubTrackingWorkPort(dataRoot: dataRoot)
        )
    }
}

private struct EngineGitHubTrackingWorkPort: GitHubTrackingWorkPort {
    let runtime: GitHubCommandRuntime

    init(dataRoot: URL) {
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            self.runtime = NativeAgentEngine.live.ports.backgroundWork.githubRuntime(dataRoot: dataRoot, shared: true)
        } else {
            self.runtime = NativeAgentEngine.live.ports.backgroundWork.githubRuntime(dataRoot: dataRoot, shared: false)
        }
    }

    func processConnectorChangesIfChanged(refreshed: Bool) async {
        await runtime.processConnectorChangesIfChanged(refreshed: refreshed)
    }

    func evaluateApprovalSnapshot(dataRoot: URL) async {
        await NativeAgentEngine.live.ports.backgroundWork.evaluateGitHubApprovals(dataRoot: dataRoot)
    }

    func evaluateBotSnapshot(dataRoot: URL) async {
        await BotGitHubEventWatcher.shared.evaluateSnapshot(dataRoot: dataRoot)
    }
}


extension NativeAgentEngine {
    public static func makeHeartbeatLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> HeartbeatLoop {
        HeartbeatBackgroundWork(port: EngineBackgroundWorkPort()).makeHeartbeatLoop(dataRoot: dataRoot)
    }

    public static func repairHeartbeatInboxItem(
        id: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await HeartbeatBackgroundWork(port: EngineBackgroundWorkPort()).repairHeartbeatInboxItem(id: id, dataRoot: dataRoot)
    }


}


struct EngineBackgroundWorkPort: HeartbeatBackgroundWorkPort {

    func storeAndFileEvents(paths: [URL], loopId: String?) -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: paths, loopId: loopId)
    }

    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String,
        summary: String, source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title,
            summary: summary, source: source, severity: severity
        )
    }


}


extension NativeAgentEngine {
    public static func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeAutoDoctorLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds, freshMeasurement: freshMeasurement)
    }

    public static func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeTurnTraceRetentionLoop(dataRoot: dataRoot, intervalSeconds: intervalSeconds)
    }

    public static func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeOffDiskBackupLoop(dataRoot: dataRoot)
    }

    public static func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient
    ) -> WeeklySelfImprovementLoop {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeWeeklySelfImprovementLoop(dataRoot: dataRoot, llm: llm)
    }

    public static func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeDataRootDiskHygieneLoop(dataRoot: dataRoot)
    }

    public static func cleanUpDiskHygiene(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> String {
        try await MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).cleanUpDiskHygiene(dataRoot: dataRoot)
    }
}

extension EngineBackgroundWorkPort: MaintenanceBackgroundWorkPort {
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult] {
        try await NativeAgentEngine.live.ports.backgroundWork.runAutoDoctor(checks: checks, dataRoot: dataRoot)
    }

    func routeDoctorAsk(eventID: String, title: String, detail: String) async throws {
        try await NativeAgentEngine.live.ports.backgroundWork.attention.route(
            eventId: eventID, importance: .ownerWaiting, title: title, body: detail,
            userInfo: ["screen": "inbox", "source": "doctor_ask", "itemId": "doctor-ask", "dedupKey": eventID]
        )
    }

    var unavailableSkipPrefix: String { DoctorLoopHealth.unavailableSkipPrefix }

    func autoDoctorConfig(dataRoot: URL) -> (enabled: Bool?, intervalSeconds: Int?) {
        let config = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        return (config.enabled, config.intervalSeconds)
    }

    func offDiskBackupParent() -> URL { TrustBackupPersistence.offDiskBackupParent() }

    func offDiskAutomaticBackups(in parent: URL) throws -> [(url: URL, date: Date)] {
        try TrustBackupPersistence.offDiskAutomaticBackups(in: parent)
    }

    func createOffDiskBackup(reason: String, dataRoot: URL, parent: URL, now: Date) async throws -> URL {
        try await TrustBackupPersistence.createOffDiskBackup(
            reason: reason, dataRoot: dataRoot, parent: parent, now: now, host: NativeAgentEngine.live.ports.backgroundWork.backupHost
        )
    }
}


// Trigger and scheduler-job physiology.
//
// User schedules remain canonical in scheduler/jobs.json and the two trigger
// config stores. BackgroundLoopsManager owns their one lifecycle, single-flight
// execution, status, startup reconciliation, event coalescing, and deadline
// task. This wrapper owns no Task and no timer of its own.

extension NativeAgentEngine {
    public static func makeTriggerSchedulerLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let workshopRunner: SwiftNativeWorkshopRunner? = isLiveRoot
            ? makeWorkshopRunner(lifecycleObserver: NativeAgentEngine.liveCognition)
            : nil
        let notifier: TriggerNotifier? = isLiveRoot
            ? NativeAgentEngine.live.ports.backgroundWork.triggerNotifier
            : nil
        let native = SwiftNativeTriggerScheduler(
            root: standardized,
            workshopRunner: workshopRunner,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? nil
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            // L5 G3: the time trigger fires the blueprint turn. Live root only —
            // a secondary/test root must never borrow the provider, the tools,
            // or the cost. nil there means the deterministic counts brief,
            // exactly as before.
            morningBriefSynthesizer: isLiveRoot ? makeMorningBriefSynthesizer() : nil
        )
        let mirror: @Sendable (TriggerFireResult) async -> Bool
        if isLiveRoot {
            mirror = { result in
                await NativeAgentEngine.live.ports.backgroundWork.mirrorTriggerFire(result)
            }
        } else {
            mirror = { _ in true }
        }
        let dueJobRunner = SchedulerDueJobRunner(root: standardized)
        let runDueJobs: @Sendable () async -> [String]
        let shutdownJobs: @Sendable () async -> Void
        let schedulerActivityFailure: @Sendable () async -> String?
        let nextJobDeadline: @Sendable (Date) async -> Date?
        if isLiveRoot {
            // Scheduled bot runs are unattended provider spend and pass through the
            // same master Autonomy switch Workshop does (lane1 finding 1: the
            // replaced runner's checked unattended admission was never restored).
            // Manual requests queued by the user are admitted inside the scheduler
            // without this gate.
            let bots = BotRunnerScheduler(dataRoot: standardized,
                session: NativeAgentEngine.live.standingBotSession(),
                isAutonomyEnabled: { await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: standardized) })
            let work = TriggerSchedulerBackgroundWork.makeJobWork(
                runDueJobs: { await dueJobRunner.runDueJobs(maxJobs: $0) },
                activityFailure: { await dueJobRunner.activityFeedError },
                nextDeadline: { await dueJobRunner.nextMeaningfulDeadline(after: $0) },
                bots: bots,
                continuations: makeTurnContinuationRuntime(dataRoot: standardized).makeDeskContinuationScheduler()
            )
            runDueJobs = work.runDueJobs
            shutdownJobs = work.shutdown
            schedulerActivityFailure = work.activityFailure
            nextJobDeadline = work.nextDeadline
        } else {
            // Scheduler jobs can dispatch process-global notification,
            // connector, provider, and sync owners. Secondary/test roots may
            // inspect their own files but never borrow those live effects.
            runDueJobs = { [] }
            shutdownJobs = {}
            schedulerActivityFailure = { nil }
            nextJobDeadline = { _ in nil }
        }
        return TriggerSchedulerEventDeadlineRunner(
            dataRoot: standardized,
            events: { paths, loopId in
                EventDeadlinePhysiology.storeAndFileEvents(paths: paths, notifications: [
                    BotRunQueue.didChange,
                    // 2026-09-06: every deadline this runner reports is an ABSOLUTE
                    // instant derived from local time — a cron-shaped job's "09:00", an
                    // idle crossing. A clock correction or a time-zone move changes
                    // what those instants ARE, and no watched file records it, so the
                    // armed deadline went on pointing at the old wall time until the
                    // six-hour integrity tick recomputed it.
                    .NSSystemClockDidChange,
                    .NSSystemTimeZoneDidChange,
                ], loopId: loopId)
            },
            schedulerJobsPath: dueJobRunner.jobsPath,
            triggerScheduler: native,
            runDueJobs: runDueJobs,
            shutdownJobs: shutdownJobs,
            schedulerActivityFailure: schedulerActivityFailure,
            nextSchedulerJobDeadline: nextJobDeadline,
            mirrorFire: mirror
        )
    }

    public static func makeMorningBriefSynthesizer() -> MorningBriefSynthesizer {
        TriggerSchedulerBackgroundWork.makeMorningBriefSynthesizer(runTurn: { prompt in
            let client = NativeAgentEngine.live.chatClient(profile: .background)
            let response = try await LLMCallContext.$purpose.withValue("morning_brief") {
            try await client.runEphemeralToolTurn(
                message: prompt,
                fileAccess: "read_only",
                surface: WorkshopSurfaceVocabulary.canonical
            )
            }
            return response.output
        })
    }
}


// Wave B — production wiring for the Workshop pump loop.
//
// The pump itself does ZERO LLM work (WorkshopPump.tick): a quiet day makes no
// provider call. The one bounded session it may run goes through WorkshopSession
// behind the WorkshopToolProfile membrane. All the app-layer dependencies the
// Core pump receives from the app (organism posture, trust policy) are
// injected here, the same shape as makeMissionExecutorLoopRunner.

extension NativeAgentEngine {

    /// Build the fully wired Workshop pump. Injected: the Desk store (Wave A),
    /// the shared background-work lease + compact receipt log (H4/M8), the
    /// bounded session runner, the organism posture read (H4), and the
    /// shared unattended-work gate.
    public static func makeWorkshopPump(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopPump {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        return WorkshopPump(
            dataRoot: dataRoot,
            store: store,
            lease: BackgroundWorkLease(dataRoot: dataRoot),
            receiptLog: WorkshopReceiptLog(dataRoot: dataRoot),
            sessionRunner: WorkshopSession(
                dataRoot: dataRoot, store: store,
                effects: EngineWorkshopSessionEffects()
            ),
            posture: { await cognition.organismBehaviorPosture() },
            isEnabled: { await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) }
        )
    }

    /// Event/deadline wrapper. Desk/trust/body mutations reconcile after one
    /// coalesced edge; the next persisted cadence or two-hour Workshop window
    /// owns one exact deadline. The daily interval is only missed-event
    /// integrity recovery. tickTimeoutOverride remains 1800s because a run may
    /// execute one multi-minute bounded LLM session.
    public static func makeWorkshopPumpLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        WorkshopPumpLoopRunner(dataRoot: dataRoot, pump: makeWorkshopPump(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        ))
    }
}



extension NativeAgentEngine {
    public static func makeWorkshopExecutor(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> WorkshopExecutorLoop {
        let usesLiveAppBody = dataRoot == PersistenceCore.defaultDataRoot()
        let cognition = cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        let gatedTools = makeGatedToolDispatchClient(
            tools: SwiftToolDispatcher(
                dataRoot: dataRoot,
                allowProcessGlobalTools: usesLiveAppBody,
                providerLifecycleObserver: cognition,
                macIntegrationBridge: usesLiveAppBody ? NativeAgentEngine.live.ports.macIntegration : nil,
                agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
            ),
            fileAccess: "auto",
            approvalFiler: nil,
            dataRoot: dataRoot
        )
        return WorkshopBackgroundWork.makeWorkshopExecutor(
            dataRoot: dataRoot, cognition: cognition,
            chatClient: { tools in
                let engine = usesLiveAppBody ? NativeAgentEngine.live : NativeAgentEngine.forRoot(dataRoot)
                return engine.chatClient(tools: tools)
            },
            gatedTools: gatedTools,
            approvedTools: { replay in
                makeGatedToolDispatchClient(
                    tools: SwiftToolDispatcher(
                        dataRoot: dataRoot, allowProcessGlobalTools: usesLiveAppBody,
                        providerLifecycleObserver: cognition,
                        macIntegrationBridge: usesLiveAppBody ? NativeAgentEngine.live.ports.macIntegration : nil,
                        agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)),
                    fileAccess: "auto", dataRoot: dataRoot, approvedReplay: replay)
            },
            notify: workshopInboxNotification
        )
    }

    public static let workshopInboxNotification: WorkshopInboxNotification = { root, id, title, summary, source, severity in
        await NativeAgentEngine.live.ports.backgroundWork.notifyIfAttentionWorthy(
            dataRoot: root, itemId: id, title: title, summary: summary, source: source, severity: severity
        )
    }

    /// Drain-loop wrapper for the scheduler (LoopRunner lives in
    /// BackgroundLoops; WorkshopExecutorLoop deliberately doesn't import it).
    ///
    /// gpt-5.5 executor-port blocker #1 (2026-06-10): the ASSEMBLED executor
    /// instance is also published to WorkshopExecutorRef.shared here, so
    /// approval continuations reach the SAME actor (same injected LLM/tool/
    /// stager closures, same actor serialization) the background drain loop
    /// runs — mirror of the AppRestartCoordinator.shared.configure app-boot
    /// wiring pattern. assembleAllLoops → BackgroundLoopsManager.start() calls
    /// this once at app launch; until then the ref is unconfigured.
    /// The Workshop runner the Desk's submit, step approvals and the agent's
    /// step decisions share: a fresh, side-effect-free actor per call (no
    /// cached state), whose planner sees the real tool catalog so a submitted
    /// execution can plan and run actual tools, not only chat.synthesize.
    /// Another root gets a planner routed and ledgered at that root.
    public static func makeWorkshopExecutionRunner(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> WorkshopExecution.SwiftNativeWorkshopRunner {
        let connectorActions = makeWorkshopPlannerConnectorActionsProvider(dataRoot: dataRoot)
        let cognition = cognitionRuntime(for: dataRoot)
        let isLiveRoot = dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
        return WorkshopExecution.SwiftNativeWorkshopRunner(
            root: dataRoot,
            planner: isLiveRoot
                ? SwiftNativeWorkshopPlannerLLM(connectorActionsProvider: connectorActions, lifecycleObserver: cognition)
                : SwiftNativeWorkshopPlannerLLM(dataRoot: dataRoot, connectorActionsProvider: connectorActions,
                                                lifecycleObserver: cognition))
    }

    public static func makeWorkshopExecutorLoopRunner(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> some LoopRunner {
        let executor = makeWorkshopExecutor(
            dataRoot: dataRoot,
            cognitionRuntime: cognitionRuntime
        )
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            WorkshopExecutorRef.shared.configure(executor)
        }
        return WorkshopExecutorDrainRunner(dataRoot: dataRoot, executor: executor)
    }
}



extension SchedulerDueJobRunner {
    public static let shared = SchedulerDueJobRunner()

    public init(root: URL = PersistenceCore.defaultDataRoot()) {
        self.init(root: root, platform: EngineSchedulerExecutionPlatform())
    }
}

struct EngineSchedulerExecutionPlatform: SchedulerExecutionPlatform {
    var attentionRouter: AttentionRouter { NativeAgentEngine.live.ports.backgroundWork.attention }

    func postNotification(title: String, body: String) async -> NativeAgentNotificationPostResult {
        await NativeAgentEngine.live.ports.backgroundWork.postMacNotification(title: title, body: body, userInfo: [:], soundName: nil)
    }

    func sendTelegramMessage(message: String) async throws {
        _ = try await makeTelegramBot().sendTestMessage(message: message, chatId: nil)
    }

    func notifyInboxIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }

    func runConnectorAction(
        id: String, dryRun: Bool, input: [String: JSONValue],
        externalSendIdempotencyKey: String
    ) async throws -> (id: String, status: String) {
        try await NativeAgentEngine.live.ports.backgroundWork.runConnectorAction(
            id: id, dryRun: dryRun, input: input,
            externalSendIdempotencyKey: externalSendIdempotencyKey)
    }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runDream(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runRem(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runHarnessBenchmark() async throws -> (id: String, status: String?) {
        let root = PersistenceCore.defaultDataRoot()
        let run = await HarnessBenchmarkRun.run(
            dataRoot: root,
            authoredToolCount: { try await ToolsFacade(dataRoot: root).listAuthored().count },
            mcpServerCount: { try await makeMCPDispatcher().listServers().count },
            embeddingRuntimeAvailable: { await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() != nil },
            doctorStatuses: { try? await makeDoctorChecks().runAll().map(\.status) }
        )
        return (run.id, run.status)
    }

    func createWorkshopTask(
        title: String, objective: String, projectSpaceId: String?
    ) async throws -> (id: String, status: String) {
        let execution = try await NativeAgentEngine.submitDeskTask(
            title: title, objective: objective, projectSpaceId: projectSpaceId
        ).execution
        return (execution.id, execution.status)
    }
}

public final class WakeResetThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFire: Date = .distantPast

    public init() {}

    public func shouldFire(now: Date = Date(), minimumInterval: TimeInterval = 30) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Wall-clock corrections can move backwards. Treat that as a new
        // epoch instead of permanently throttling sleep recovery until the
        // clock catches up with a timestamp that no longer exists.
        if now < lastFire {
            lastFire = now
            return true
        }
        guard now.timeIntervalSince(lastFire) >= minimumInterval else { return false }
        lastFire = now
        return true
    }

    @discardableResult
    public func handleWake(
        resetEffect: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { completion in
            URLSession.shared.reset(completionHandler: completion)
        },
        resetCompleted: @escaping @Sendable () -> Void = {
            ModuleLog.app("[wake] URLSession.shared reset after sleep")
        }
    ) -> Bool {
        guard shouldFire() else {
            ModuleLog.app("[wake] throttled — last fire was <30s ago, skipping URLSession reset")
            return false
        }
        resetEffect(resetCompleted)
        return true
    }
}
