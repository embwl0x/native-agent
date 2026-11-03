import AuthoredCapabilities
import Experiences
import ActivityWatch
import Foundation
import Context
import OSLog
import ApprovalTransactions
import BackgroundLoops
import BackgroundWork
import Browser
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolParsing
import ChatToolRuntime
import ChatSessionWork
import Cognition
import Connectors
import ContextFlow
import Desk
import MemoryV2
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Procedures
import PersonaEngine
import Transcripts
import TurnTrace
import WorkshopExecution
import AgentConversations
import Agents
import AppToolRuntime
import ApprovalInbox
import AttentionRouting
import CognitiveSubstrate
import DeviceSync
import DoctorChecks
import MacControl
import ProviderRouting
import SchedulerExecution
import SlackBot
import StandingBots
import TelegramBot
import TriggerScheduler
import TrustCenter
import TrustPersistence
import AgentWorkspace
import Privacy
import Darwin
import NativeAgentShared
import Senses
import ToolExecution
import Studio
// Blueprint: | `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery starts independently at launch, its install observation once part wakes are registered; trusted bundled seeds installed before ingress; the seed owner compares complete authored/sealed contracts, while edited/non-seed content and other occupied slots are preserved, each failure retained by AbilityFilesCheck and reported through Doctor to the person while launch continues; an installed seed the readable bundle no longer ships, still its proof's candidate and never re-enabled, is switched off through its registry (restorable); root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, procedure-retention root admission; enabled scheduled work migrates once into intentions before resident loops start, with migration failure reported through Doctor and loops held; loop launch and continuation observers are independent of senses registration; sense reads and file subscriptions await readiness at their own owners; one retained quit settlement joins producers and tracked turns before the final snapshot and dependency retirement, shared by both quit bounds, background loop manifest; resident composition lives in EngineChatSurfaces, EngineDreams and EngineScheduledWork; native effects arrive through EngineBackgroundWorkHost; retired credential-bearing MCP files remain untouched and privacy-fenced with their backup copies; completed retired-connector notices have been removed; retained old credentials stay untouched and unread; the engine exposes the existing activity controller through its body host; launch starts the front-app perception after installing the crossing; termination closes and joins its delayed/admitted work |

/// Native effects used by Core's background composition. Scheduling, admission and reconciliation remain with the existing engine and background owners.
public protocol EngineBackgroundWorkHost: Sendable {
    @MainActor var activityWatch: ActivityWatchController { get }
    var approvals: ApprovalExecution { get }
    var attention: AttentionRouter { get }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult
    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> DoctorReport
    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending
    var speechPermission: SpeechPermissionSnapshot { get }
    /// Asks macOS once when the grant was never decided (the system's own prompt); otherwise the live status.
    func requestSpeechPermissionIfNotDetermined() async -> SpeechPermissionSnapshot
    var voiceName: String { get }
    var agentSubject: String { get }
    var triggerNotifier: TriggerNotifier { get }
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
    @MainActor public var activityWatch: ActivityWatchController { ports.backgroundWork.activityWatch }
    // Launch work belongs to this process lifecycle, not to the resident scheduler.
    @MainActor private static var launchTasks: [UUID: Task<Void, Never>] = [:]
    @MainActor private static var launchStopped = false
    @MainActor private static var residentsStarted = false
    @MainActor private static var runtimeObservationsInstalled = false
    @MainActor private static var firstAnchorTask: Task<Void, Never>?
    @MainActor private static var firstAnchorObserver: NSObjectProtocol?
    @MainActor private static var frontSenseDrain: Task<Void, Never>?

    @MainActor
    private static func retainLaunchWork(_ operation: @escaping @Sendable () async -> Void) {
        guard !launchStopped, !Task.isCancelled else { return }
        let id = UUID()
        launchTasks[id] = Task.detached(priority: .utility) {
            if !Task.isCancelled { await operation() }
            await retireLaunchWork(id)
        }
    }

    @MainActor private static func retireLaunchWork(_ id: UUID) { launchTasks.removeValue(forKey: id) }

    @MainActor
    public static func stopLaunchWork() {
        launchStopped = true // Close admission synchronously, before any drain suspends.
        frontSenseDrain = EngineFrontSense.shared.stop()
        for task in launchTasks.values { task.cancel() }
        firstAnchorTask?.cancel()
        if let firstAnchorObserver { NotificationCenter.default.removeObserver(firstAnchorObserver) }
        firstAnchorObserver = nil
        DoctorFacade.disarmFirstTurnRefresh()
    }

    public static func prepareProcessFileLimit() {
        var files = rlimit()
        if getrlimit(RLIMIT_NOFILE, &files) == 0, files.rlim_cur < 10_240 {
            files.rlim_cur = min(files.rlim_max, 10_240)
            _ = setrlimit(RLIMIT_NOFILE, &files)
        }
    }

    @MainActor
    public static func installRuntimeObservationsAtLaunch(dataRoot: URL) {
        guard !launchStopped, !runtimeObservationsInstalled else { return }
        runtimeObservationsInstalled = true
        let crashLog = BodyReport.crashBreadcrumbs(dataRoot)
        do {
            try FileManager.default.createDirectory(at: crashLog.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            BodyReport.installCrashBreadcrumbs(path: crashLog.path)
        } catch {
            ModuleLog.app("[crash-breadcrumbs] unavailable: %@", error.localizedDescription)
        }
        BackgroundLoopLifetimes.shared.receiveOrganPulses()
        // Attempt person-input observation once per launch; until granted, one retained card asks for access and relaunch.
        if !MacPersonInput.listening,
           let card = InlineInteractionRegistry.permission(["privacy:inputMonitoring"],
               why: "I need Input Monitoring to tell your own typing and pointing from mine, so I know when you're here before I bring an app forward.") {
            let published = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            firstAnchorObserver = NotificationCenter.default.addObserver(
                forName: ConversationAnchor.didPublish, object: nil, queue: nil
            ) { _ in published.continuation.yield(()) }
            firstAnchorTask = Task {
                defer {
                    if let firstAnchorObserver { NotificationCenter.default.removeObserver(firstAnchorObserver) }
                    firstAnchorObserver = nil
                    firstAnchorTask = nil
                    published.continuation.finish()
                }
                var session = ConversationAnchor.currentSessionId(dataRoot: dataRoot)
                if session == nil {
                    for await _ in published.stream {
                        guard !Task.isCancelled else { return }
                        session = ConversationAnchor.currentSessionId(dataRoot: dataRoot)
                        if session != nil { break }
                    }
                }
                guard let session, !Task.isCancelled, !launchStopped else { return }
                await InlineInteractionResolver.raise(card, sessionID: session, resumable: false,
                    origin: .native("launch:input-monitoring"), dataRoot: dataRoot)
            }
        }
    }

    public static func validateProvidersAtLaunch() {
        signal(SIGPIPE, SIG_IGN)
    }

    @MainActor
    public static func prepareStateAtLaunch(
        dataRoot: URL, currentVersion: String, resources: URL?,
        publicReleaseUnavailable: @MainActor @Sendable (String) -> Void,
        backupRestoreUnavailable: @MainActor @Sendable (String) -> Void,
        confirmMissingRoots: @MainActor @Sendable ([String]) -> Bool
    ) async -> Bool {
        if case .failed(let error) = await Task.detached(priority: .userInitiated, operation: {
            InstallPaths.preparePublicReleaseDataRootIfNeeded()
        }).value {
            publicReleaseUnavailable(error)
            return false
        }
        do {
            let restored = try await Task.detached(priority: .userInitiated) {
                try await TrustBackupPersistence.resumeStagedBackupRestoreAtLaunch(dataRoot: dataRoot)
            }.value
            for note in restored?.notCarried ?? [] { ModuleLog.app("[backup-restore] %@", note) }
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
            ModuleLog.app("[mac-control] Mac actions unavailable after recovery failure; app will start: %@", error.localizedDescription)
        }
        // Recovery precedes ingress. Each owner retains its failure and refuses
        // only its own new effects; chat and unrelated surfaces can start.
        var strandedBrowserOperations: Int?
        do {
            strandedBrowserOperations = try await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
                .executeBrowserOperation(.recoverStrandedRunning).recoveredCount
        } catch {
            ModuleLog.app("[browser] Browser actions unavailable after recovery failure; app will start: %@", error.localizedDescription)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) { if let resources { await installBundledParts(dataRoot: dataRoot, resources: resources) } }
            group.addTask(priority: .utility) {
                do { try NativeAgentBuildIdentity.current.writeLaunchStamp(root: dataRoot) }
                catch { ModuleLog.app("[launch] Could not record app start time: %@", error.localizedDescription) }
                do {
                    _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
                    ModuleLog.app("[workspace] canonical work root ready")
                } catch { ModuleLog.app("[workspace] canonical work root unavailable: %@", error.localizedDescription) }
                ChatUpdateNote.recordLaunchAtStartup(dataRoot: dataRoot, currentVersion: currentVersion, resources: resources)
            }
        }
        _ = await Task.detached(priority: .userInitiated) { NativeAgentEngine.live }.value
        if let strandedBrowserOperations {
            OrganPulse.record("launch.browser_stranded", found: strandedBrowserOperations,
                note: "\(strandedBrowserOperations) closed as outcome unknown before ingress")
        }
        return true
    }

    private static func installBundledParts(dataRoot: URL, resources: URL) async {
        let abilities = AbilityStore(dataRoot: dataRoot)
        var failures: [String] = []
        var currentSeeds = 0, preparedAdmissions = 0
        do {
            let bundled = AbilityStore(dataRoot: resources)
            let seeds = try AbilityStore.seedCatalog(resources: resources).sorted { $0.path < $1.path }.map { url in (url, Result { try AbilityStore.decode(url) }) }
            // Retirement is read off the whole bundle: one unreadable seed and nothing fades this launch.
            if let shipped = try? seeds.map({ try $0.1.get().id }) {
                do { try fadeRetiredSeeds(abilities, shipped: Set(shipped), dataRoot: dataRoot) }
                catch { failures.append("retired seeds: \(error.localizedDescription)") }
            }
            // Bind the owner's peer trust before admitting the bundled seeds.
            PeerTrust.install(dataRoot: dataRoot)
            let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { _, _ in nil }
            await OwnedProgramInvocation.$host.withValue(host) {
                for (url, decoded) in seeds {
                    do {
                        let seed = try decoded.get()
                        guard try bundled.path(id: seed.id, pathExtension: seed.pathExtension) == url else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        // Her own version stays hers. The seed owner compares the full
                        // unsigned contract before admission and rechecks at installation.
                        if let current = try abilities.read(id: seed.id, slot: .current) {
                            guard AbilityStore.isSeed(current) else { continue }
                        } else if try abilities.contains(id: seed.id) { continue }
                        let kept: AbilityStore.File
                        if seed.kind == .part {
                            guard let admitted = try await Parts(root: dataRoot).bundledSeed(seed) else {
                                currentSeeds += 1
                                continue
                            }
                            preparedAdmissions += 1
                            kept = admitted
                        } else { kept = seed }
                        try abilities.installSeed(kept) { current in
                            guard let digest = current.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"]?.stringValue else {
                                throw ToolFailureError("Installed seed \(current.id) has no sealed candidate identity. Preserve its bytes and repair its authored source before upgrading.", effects: .none,
                                    code: "seed_identity_missing", instruction: "Read this ability and repair its missing sealed candidate through its authoring owner.", recovery: .inspect)
                            }
                            guard let key = try SwiftNativeManifestSigner(dataRoot: dataRoot).existingSigningKey() else {
                                throw ManifestSigningError.keyUnavailable("Installed seed authority is missing")
                            }
                            let programs = OwnedProgramStore(root: abilities.root)
                            _ = try programs.proof(try programs.load(id: current.id, digest: digest), key: key)
                        }
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        AbilityFilesCheck.recordSeedInstallation(failures: failures, current: currentSeeds,
            prepared: preparedAdmissions, root: dataRoot)
        // Doctor's reading publishes on its own; launch never waits for it.
        if !failures.isEmpty {
            Task.detached(priority: .utility) {
                await DoctorReadout.recordReadings([await AbilityFilesCheck(root: dataRoot).run()], dataRoot: dataRoot)
            }
        }
    }

    // Only untouched retired seeds are disabled; edited or re-enabled parts remain hers.
    private static func fadeRetiredSeeds(_ abilities: AbilityStore, shipped: Set<String>, dataRoot: URL) throws {
        try AbilityStore.withLock {
            let programs = OwnedProgramStore(root: abilities.root)
            let retired = Set(try abilities.files(kind: .part, includeProposals: false).filter { file in
                guard AbilityStore.isSeed(file), !shipped.contains(file.id), case .object(let proof)? = file.metadata["proof"],
                      case .string(let digest)? = proof["candidate"] else { return false }
                return (try? programs.load(id: file.id, digest: digest)) != nil
            }.map(\.id))
            guard !retired.isEmpty, case .array(var rows) = try abilities.registry(kind: .part) else { return }
            var faded = false
            for index in rows.indices {
                guard case .object(var row) = rows[index], case .string(let id)? = row["id"], retired.contains(id),
                      row["status"] != .string("disabled"), row["enabledAt"] == nil else { continue }
                row["status"] = .string("disabled")
                row["disabledReason"] = .string("No longer shipped with the app; restore it to use it again.")
                rows[index] = .object(row); faded = true
            }
            if faded { try abilities.saveRegistry(.array(rows), kind: .part) }
        }
    }

    public static func installBotProviderCheck() async {
        await BotRunGate.installLiveCheck { bot, dataRoot in
            do { _ = try await BotChatContract.choice(for: bot, dataRoot: dataRoot); return nil }
            catch { return String(describing: error) }
        }
    }

    public static func installActionLabelsAtLaunch() {
        let actions: [AppAction]
        do { actions = try AppActions.seedActions }
        catch {
            let root = PersistenceCore.defaultDataRoot()
            RepairOwed.owe(root, id: "action-labels:" + UUID().uuidString.lowercased(), kind: .run,
                operation: "actions.labels", owner: "Action declarations",
                words: "Action labels were not installed: \(error.localizedDescription). Repair the declaration and relaunch.")
            return
        }
        let labels = actions.flatMap { action in
            [(action.id, action.label)] + (action.isFold && action.label != action.tool ? [(action.tool, action.label)] : [])
        }
        ToolActivityPresentation.installActionLabels(
            Dictionary(labels, uniquingKeysWith: { first, _ in first }))
    }

    @MainActor
    public static func startContextFlowAtLaunch(dataRoot: URL) {
        retainLaunchWork {
            await installDerivedStateInvalidationAtLaunch(dataRoot: dataRoot) {
                await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots(includeMemories: true)
            }
            guard !Task.isCancelled else { return }
            await NativeAgentEngine.live.contextFlow.start()
            if Task.isCancelled { await NativeAgentEngine.live.contextFlow.stop() }
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
        registerBackgroundTasks: @MainActor () -> Void,
        resumeMacTurn: @escaping @Sendable (TurnCheckpoint, TurnContinuationRuntime) async throws -> Void,
        approvals: ApprovalExecution
    ) {
        guard !launchStopped, !residentsStarted, !Task.isCancelled else { return }
        residentsStarted = true
        retainLaunchWork {
            await NativeAgentEngine.live.chrome.observeBrowserLaunches()
            guard !Task.isCancelled else { return }
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        }
        retainLaunchWork { _ = await reconcileMemoryAtLaunch(dataRoot: dataRoot, storageUnavailable: storageUnavailable) }
        retainLaunchWork { await SwiftNativeMemoryIndexer.reconcileAtLaunch(dataRoot: dataRoot) }
        registerBackgroundTasks()
        WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())
        // Each bring-up remains independent so one blocked store cannot hold the other resident owners or the native launch callback.
        retainLaunchWork {
            do {
                _ = try EmbeddingModelDownload.configuredDescriptor(at: embeddingDescriptorURL)
                await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
            } catch {
                let detail = "Memory model bring-up unavailable: \(error.localizedDescription)"
                ModuleLog.app("[embedding-download] %@", detail)
                await DoctorReadout.recordReadings([CheckResult(source: "embedding-download.json",
                    id: "launch.embeddings", title: "Memory model bring-up", status: "fail", detail: detail)], dataRoot: dataRoot)
            }
        }
        SensesHub.shared.installCrossing(NativeAgentEngine.liveCognition)
        EngineFrontSense.shared.start(dataRoot: dataRoot)
        retainLaunchWork { await NativeAgentEngine.liveCognition.bootstrap() }
        // Callbacks a peer is owed from before the relaunch go out now, not when the task is next read.
        retainLaunchWork { await NativeAgentEngine.live.agents.tasks.redeliverOwedCallbacks() }
        retainLaunchWork { await reconcileTranscriptsAtLaunch(dataRoot: dataRoot) }
        retainLaunchWork { _ = await ChatHistoryIndex.shared(dataRoot: dataRoot).absorbAll() }
        // The person's login PATH, read once here so no caller waits on it later.
        retainLaunchWork { _ = AgentHostCommandLines.loginEnvironment }
        retainLaunchWork {
            guard !Task.isCancelled else { return }
            _ = await AgentDiscoverySession.shared.candidates(refresh: true, probe: false, dataRoot: dataRoot)
        }
        retainLaunchWork {
            do {
                try await migrateScheduledIntentionsAtLaunch(dataRoot: dataRoot)
            } catch is CancellationError {
                return
            } catch {
                let detail = "Scheduled work could not become intentions; resident loops did not start: " + error.localizedDescription
                ModuleLog.app("[intentions] %@", detail)
                await DoctorReadout.recordReadings([CheckResult(source: "Launch intention migration",
                    id: "launch.intentions", title: "Scheduled intentions", status: "fail", detail: detail)], dataRoot: dataRoot)
                return
            }
            guard !Task.isCancelled else { return }
            await ProcedureArtifactStore.startRetention(dataRoot: dataRoot)
            await startBackgroundWorkAtLaunch(
                dataRoot: dataRoot,
                makeLoops: {
                    _ = NativeAgentEngine.live
                    guard !Task.isCancelled else { return nil }
                    // Register signals before loop sources fire. Individual sense reads
                    // and file subscriptions own readiness; neither holds loop launch.
                    await EnginePartWake.shared.start(dataRoot: dataRoot)
                    guard !Task.isCancelled else { return nil }
                    // The delegation runner starts and stops contact observation.
                    let loops = assembleAllLoops()
                    await installBotProviderCheck()
                    guard !Task.isCancelled else { return nil }
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
        retainLaunchWork {
            await configureMemoryPromotionAtLaunch(dataRoot: dataRoot,
                makeLLMClient: { makeSharedLLMClient() })
        }
        retainLaunchWork {
            do {
                let records = try await ApprovalExecution.resolvedApprovalsForReconciliation(dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                let executions = try await approvals.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, records: records)
                guard !Task.isCancelled else { return }
                await RepairOwed.settle(dataRoot, operation: "approval.reconcile",
                    evidence: .init(source: "workflows/approvals/requests.json", id: "checked reconciliation scan")).value
                OrganPulse.record("launch.approval_executions", found: executions, note: "\(executions) re-run")
            } catch {
                await RepairOwed.owe(dataRoot, id: "approval.reconcile", kind: .run,
                    operation: "approval.reconcile", owner: "Approval reconciliation",
                    words: error.localizedDescription,
                    lever: "Repair the approval store or reconciliation cursor, then restart to reconcile the retained decisions.").value
            }
            await retainLaunchWork {
                await MemoryApprovalTransactions.stageKindBackfillIfNeeded(dataRoot: dataRoot,
                    makeLLMClient: { makeSharedLLMClient() })
            }
            await retainLaunchWork {
                let activationCards = await WorkshopProcedureActivation.reconcileLocalFileCopyIfQualified()
                guard !Task.isCancelled else { return }
                OrganPulse.record("launch.procedure_activation", found: activationCards, note: "\(activationCards) review staged")
            }
            await retainLaunchWork {
                let remStaged = await stagePendingREMProposalsAtLaunch()
                OrganPulse.record("launch.rem_staging", found: remStaged, note: "\(remStaged) staged")
            }
        }
    }

    @MainActor
    public static func startDeviceSyncAtLaunch(
        forward: @escaping (BridgeMessage) async -> Bool,
        registerLoginItem: @MainActor () -> Void
    ) {
        guard !launchStopped, !Task.isCancelled else { return }
        NativeAgentEngine.liveDeviceSync.bridge.setup()
        NativeAgentEngine.liveDeviceSync.bridge.observeIncomingMessages(onMessage: forward)
        // The bridge publishes the pairing key once it knows this Mac holds the phone; a launch never writes it over another Mac's.
        if NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: PersistenceCore.defaultDataRoot()) {
            registerLoginItem()
        }
    }

    public static func reconcileMemoryAtLaunch(
        dataRoot: URL,
        storageUnavailable: @MainActor @Sendable () -> Void
    ) async -> Bool {
        let logger = Logger(subsystem: "com.nativeagent.app", category: "memory-launch")
        do {
            _ = try await SwiftNativeMemoryV2.resolvedStorage(
                dataRoot: dataRoot
            )
        } catch {
            logger.error("MemoryV2 canonical storage unavailable; projections refused: \(String(describing: error), privacy: .public)")
            await storageUnavailable()
            return false
        }
        // Idempotently remove superseded statements' tombstones so their corrections remain admissible.
        await SwiftNativeMemoryV2.shared.repairSupersededTombstones()
        // Admit the trusted backlog once under the current keep rules.
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

    public static func reconcileConnectorCredentialsAtLaunch(dataRoot: URL) async {
        // Current credential save recovery and checked metadata precede ingress.
        do { try SlackCredentials.withSnapshot(dataRoot: dataRoot) {} }
        catch { nativeLog("[slack-credential] Saved credential state unavailable: %@", error.localizedDescription) }
    }

    public static func installDerivedStateInvalidationAtLaunch(
        dataRoot: URL, writeMemorySnapshot: @escaping @Sendable () async -> Void
    ) async {
        await DerivedStateInvalidationCenter.shared.install(
            EngineDerivedStateInvalidationSink(dataRoot: dataRoot, writeMemorySnapshot: writeMemorySnapshot))
    }

    public static func startBackgroundWorkAtLaunch(
        dataRoot: URL,
        makeLoops: @Sendable () async -> [LoopRegistration]?,
        resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void
    ) async {
        guard !Task.isCancelled else { return }
        // Reply journal owners start before the checkpoint sweep hands resumed answers to them. The one start path: failure notices wired, and the startup Doctor pass that gives a relaunch its report.
        guard let loops = await makeLoops(), !Task.isCancelled else { return }
        await startBackgroundLoops(loops: loops)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard !launchStopped, !Task.isCancelled else { return }
            AbandonedTurnReconciliationHook.arm(completedTurnNotification: .chatTurnCompleted,
                inFlight: { Set(ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).map(\.turnId)) },
                resume: resume)
        }
    }

    public static func configureMemoryPromotionAtLaunch(
        dataRoot: URL,
        makeLLMClient: @escaping @Sendable () -> any LLMClient
    ) async {
        await AdaptiveMemoryPromoter.shared.configure(
            memory: SwiftNativeMemoryV2.shared,
            memoryManager: MindMemoryJudgment(makeLLMClient: makeLLMClient),
            adaptivePromotionEnabled: { try MemoryPolicyGate.adaptivePromotionEnabled() },
            personName: { try NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) }
        )
    }

    public static func startBackgroundLoops(loops: [LoopRegistration]) async {
        let manager = BackgroundLoopLifetimes.shared
        let dataRoot = PersistenceCore.defaultDataRoot()
        await manager.setFailureOutcome { loopId, error in
            await MaintenanceBackgroundWork.fileLoopFailureNotice(
                dataRoot: dataRoot, loopId: loopId, error: error)
        }
        await manager.setFailureRecoveryPush { loopId, _ in
            guard let healthyAt = await manager.status().first(where: { $0.name == loopId })?.lastSuccessfulWorkAt else { return false }
            return await MaintenanceBackgroundWork.resolveLoopFailureNotice(
                dataRoot: dataRoot, loopId: loopId, healthyAt: healthyAt)
        }
        guard !Task.isCancelled, await manager.start(loops: loops, residentObservation: {
            async let desk: Void = ApprovalExecution.settleDeskWaitsOnEveryResolve(dataRoot: dataRoot)
            async let grants: Void = InlineInteractionResolver.GrantWatch.shared.observe()
            async let interactions: Void = InlineInteractionDelivery.observe(dataRoot: dataRoot)
            _ = await (desk, grants, interactions)
        }), !Task.isCancelled else { return }
        // Refresh the heartbeat receipt after restart without blocking startup.
        await retainLaunchWork { await manager.runTickOnce(loopId: "heartbeat") }
        guard !Task.isCancelled else { return }
        guard NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) else { return }
        let config = DoctorReadout.readAutoDoctorConfig(dataRoot: dataRoot)
        if (config.enabled ?? true) && (config.runOnStartup ?? true) {
            await retainLaunchWork { await manager.runTickOnce(loopId: "doctor_auto_run") }
        }
    }

    @discardableResult
    public static func runBackgroundLoopOnce(loopId: String) async -> LoopTickOutcome {
        let manager = BackgroundLoopLifetimes.shared
        if !(await manager.isRunning(loopId: loopId)) {
            await startBackgroundLoops(loops: assembleAllLoops())
        }
        return await manager.runTickOnce(loopId: loopId)
    }

    @discardableResult
    public static func restartBackgroundLoop(id: String, manager: BackgroundLoopLifetimes = .shared) async -> LoopRestartOutcome {
        await MaintenanceBackgroundWork.restartLoop(id: id, manager: manager, replacementLoop: { id in
            switch id {
            case "telegram_poll":
                return makeTelegramPollLane()
            case "slack_socket_mode": return makeSlackSocketModeLane()
            case "doctor_auto_run": return .enabled(makeAutoDoctorLoop())
            default: return nil
            }
        })
    }

    public static let quitRestartWake = Notification.Name("NativeAgent.quitRestartWake")

    public static func waitForInFlightTurnsBeforeQuit(
        _ runs: Set<String>, isRestarting: @escaping @Sendable () -> Bool
    ) async {
        // Arm before reading: completion or restart racing the first read stays buffered.
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [],
            notifications: [ChatCancelFlag.inFlightDidChange, quitRestartWake])
        _ = await raceAgainstTimeout(seconds: 20) {
            var iterator = events.makeAsyncIterator()
            while !Task.isCancelled,
                  !NativeAgentEngine.live.turns.inFlightRunIDs().isDisjoint(with: runs), !isRestarting() {
                guard await iterator.next() != nil else { return }
            }
        }
        let left = NativeAgentEngine.live.turns.inFlightRunIDs().intersection(runs).count
        ModuleLog.app("[quit] %@", left == 0 ? "turns finished — quitting" : "\(left) turn(s) still running at the bound — quitting anyway")
    }

    // Close interpretation admission, join work and save through one retained settlement; a timed-out caller leaves settlement running.
    @MainActor private static var quitSettlement: Task<NativeCognitionSleepOutcome?, Never>?

    /// Retained independently of either quit bound. The terminal drain joins this same operation; timeout cancels only its caller-facing wait.
    @MainActor
    public static func beginQuitSleep(after producers: Task<Void, Never>, runs: Set<String>,
                                      retireBrowser: @escaping @MainActor @Sendable () -> Void) -> Task<NativeCognitionSleepOutcome?, Never> {
        if let quitSettlement { return quitSettlement }
        let task = Task.detached { () -> NativeCognitionSleepOutcome? in
            await producers.value
            // Producers can have started their own admitted turns before Stop. Arm before the registry read so their final completion cannot race it.
            let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [],
                notifications: [ChatCancelFlag.inFlightDidChange])
            // Every turn in flight, read again at each step: a message admitted after Stop (a queued Telegram turn) is hers too, and the final snapshot waits for it. The sleep bound still caps the wait.
            var iterator = events.makeAsyncIterator()
            while !NativeAgentEngine.live.turns.inFlightRunIDs().isEmpty {
                guard await iterator.next() != nil else {
                    ModuleLog.app("[quit] admitted-turn observation ended before completion")
                    return nil
                }
            }
            await AdaptiveMemoryPromoter.shared.sleep()
            let slept = await NativeAgentEngine.liveCognition.sleep()
            await retireBrowser()
            return slept
        }
        quitSettlement = task
        return task
    }

    public static func sleepMind(after settlement: Task<NativeCognitionSleepOutcome?, Never>) async -> String {
        let outcome = await raceAgainstTimeout(seconds: sleepBound) { await settlement.value }
        switch outcome {
        case .value(let slept): return slept?.summary ?? "did not settle: admitted-turn observation unavailable"
        case .timedOut: return "did not settle within \(Int(sleepBound)) s"
        default: return "did not settle"
        }
    }

    // Quit waits at most sleepBound; the relauncher's exit deadline includes that bound.
    static let sleepBound: Double = 30

    /// Start closing producer admission at the beginning of the quit hold. Keep dependencies alive until these admitted runs have settled.
    @MainActor
    public static func beginQuitProducerSettlement(appLaunch: Task<Void, Never>?, appObservers: [Task<Void, Never>] = []) -> Task<Void, Never> {
        stopLaunchWork()
        let launch = Array(launchTasks.values)
        let anchor = firstAnchorTask
        let frontSense = frontSenseDrain
        let otherDoors = OtherDoorTurns.shared.stop()
        let make = NativeAgentEngine.live.make.shutdown()
        let activity = NativeAgentEngine.live.activityWatch.makeTerminationDrain()
        AbandonedTurnReconciliationHook.disarm()
        HerMemo.shared.shutdown()
        HerOpened.shared.shutdown()
        NativeAgentNotifications.shutdown()
        return Task.detached {
            async let wakes: Void = EnginePartWake.shared.stop()
            async let loops: Void = BackgroundLoopLifetimes.shared.shutdown()
            async let aging: Void = ChatSessionAgingConsolidation.stop()
            for task in launch { await task.value }
            await appLaunch?.value
            await anchor?.value
            await frontSense?.value
            for observer in appObservers { await observer.value }
            await otherDoors.value
            await make.value
            await activity.value
            _ = await (wakes, loops, aging)
        }
    }

    @MainActor
    public static func drainResidentWorkForTermination(
        shutdownSenses: @escaping @Sendable () async -> Void,
        retireBrowser: @escaping @MainActor @Sendable () -> Void
    ) {
        let settlement = quitSettlement ?? beginQuitSleep(
            after: beginQuitProducerSettlement(appLaunch: nil),
            runs: NativeAgentEngine.live.turns.inFlightRunIDs(), retireBrowser: retireBrowser)
        let group = DispatchGroup()
        let attention = NativeAgentEngine.live.ports.backgroundWork.attention
        group.enter()
        Task.detached {
            // Only a completed sleep may retire its dependencies. An unavailable barrier stays explicitly unfinished until process exit.
            guard await settlement.value != nil else {
                ModuleLog.app("[quit] dependencies retained: admitted-turn observation unavailable")
                group.leave()
                return
            }
            async let chrome: Void = NativeAgentEngine.live.chrome.stop()
            async let senses: Void = shutdownSenses()
            async let programs: Void = OwnedProgramRunner.endResidents()
            async let acp: Void = SwiftToolDispatcher.closeACPConnections()
            async let context: Void = NativeAgentEngine.live.contextFlow.stop()
            async let artifacts: Void = ProcedureArtifactStore.stopRetention(dataRoot: NativeAgentEngine.live.dataRoot)
            async let embeddings: Void = SwiftNativeMemoryV2.shared.shutdownEmbeddingConvergence()
            async let promoter: Void = AdaptiveMemoryPromoter.shared.shutdown()
            async let projections: Void = SwiftNativeMemoryV2.shared.shutdownProjections()
            async let notifications: Void = attention.shutdown()
            _ = await (chrome, senses, programs, acp, context, artifacts, embeddings, promoter, projections, notifications)
            // Producers, admitted turns and resident senses/programs have all
            // settled; none can still need the app inventory or its stream.
            await MacAppIndex.shared.shutdown()
            group.leave()
        }
        NativeAgentEngine.live.trace.stop()
        if group.wait(timeout: .now() + 3.0) == .timedOut {
            ModuleLog.app("[quit] resident settlement unfinished at the 3 s termination bound")
        }
    }

    @MainActor
    public static func prepareContextForSleep() {
        retainLaunchWork { await NativeAgentEngine.live.contextFlow.prepareForSleep() }
    }

    @MainActor
    public static func reconcileContextAfterWake() {
        retainLaunchWork {
            await NativeAgentEngine.live.contextFlow.reconcileAfterWake()
            await NativeAgentEngine.liveCognition.reanchorDeadlinesAfterWake()
        }
    }
}

public final class WakeResetThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFire: Date = .distantPast

    public init() {}

    public func shouldFire(now: Date = Date(), minimumInterval: TimeInterval = 30) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Wall-clock corrections can move backwards. Treat that as a new epoch instead of permanently throttling sleep recovery until the clock catches up with a timestamp that no longer exists.
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
