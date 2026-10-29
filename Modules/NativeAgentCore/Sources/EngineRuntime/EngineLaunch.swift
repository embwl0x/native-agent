import AuthoredCapabilities
import ActivityWatch
import Foundation
import Context
import OSLog
import ApprovalTransactions
import BackgroundLoops
import BackgroundWork
import Browser
import ChatTurnRuntime
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
// Blueprint: | `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery starts independently at launch, its install observation once part wakes are registered; trusted bundled seeds installed before ingress; current seeds follow changed shipped bodies, while edited/non-seed content and other occupied slots are preserved, each failure retained by AbilityFilesCheck and reported through Doctor to the person while launch continues; an installed seed the readable bundle no longer ships, still its proof's candidate and never re-enabled, is switched off through its registry (restorable); root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, procedure-retention root admission; one retained quit settlement joins producers and tracked turns before the final snapshot and dependency retirement, shared by both quit bounds, background loop manifest; resident composition lives in EngineChatSurfaces, EngineDreams and EngineScheduledWork; native effects arrive through EngineBackgroundWorkHost; MCP servers a data root kept are raised to their once by name as theirs to grow (`raiseKeptMCPServers`), their file untouched and, since a launch line can carry a key, fenced from their file readers with its backup copies; `tellRetiredConnectors` removes retired service rows and tells their once which were set up; old credentials stay untouched and unread; the engine exposes the existing activity controller through its body host; termination stops EnginePractice and waits for its settlement |

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
                await InlineInteractionResolver.raise(card, sessionID: session, resumable: false, dataRoot: dataRoot)
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
            ModuleLog.app("[mac-control] refusing startup after operation recovery failure: %@", error.localizedDescription)
            macRecoveryUnavailable()
            return false
        }
        // Recovery precedes ingress; unreadable browser state is reported by its owner without blocking launch.
        var strandedBrowserOperations = 0
        var browserRecoveryNote: String?
        do {
            strandedBrowserOperations = try await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
                .executeBrowserOperation(.recoverStrandedRunning).recoveredCount
        } catch {
            ModuleLog.app("[browser] operation recovery failed; the browser owner reports it on use: %@", error.localizedDescription)
            browserRecoveryNote = "recovery failed: " + error.localizedDescription
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
        OrganPulse.record("launch.browser_stranded", found: strandedBrowserOperations,
            note: browserRecoveryNote ?? "\(strandedBrowserOperations) closed as outcome unknown before ingress")
        return true
    }

    private static func installBundledParts(dataRoot: URL, resources: URL) async {
        let abilities = AbilityStore(dataRoot: dataRoot)
        var failures: [String] = []
        do {
            let bundled = AbilityStore(dataRoot: resources)
            let seeds = try AbilityStore.seedCatalog(resources: resources).sorted { $0.path < $1.path }.map { url in (url, Result { try AbilityStore.decode(url) }) }
            // Retirement is read off the whole bundle: one unreadable seed and nothing fades this launch.
            if let shipped = try? seeds.map({ try $0.1.get().id }) {
                do { try fadeRetiredSeeds(abilities, shipped: Set(shipped), dataRoot: dataRoot) }
                catch { failures.append("retired seeds: \(error.localizedDescription)") }
            }
            // Her tools and skills take the one form of a part first (idempotent), with the owner's trust in agents bound, as their admissions read it.
            PeerTrust.install(dataRoot: dataRoot)
            do { try await Parts(root: dataRoot).migrate() } catch { failures.append("parts: \(error.localizedDescription)") }
            let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { _, _ in nil }
            await OwnedProgramInvocation.$host.withValue(host) {
                for (url, decoded) in seeds {
                    do {
                        let seed = try decoded.get()
                        guard try bundled.path(id: seed.id, pathExtension: seed.pathExtension) == url else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        // Already there: only an untouched seed whose bundle changed does any work.
                        if let current = try abilities.read(id: seed.id, slot: .current) {
                            guard AbilityStore.isSeed(current), current.body != seed.body else { continue }
                        } else if try abilities.contains(id: seed.id) { continue }
                        let kept = seed.kind == .part ? try await Parts(root: dataRoot).bundledSeed(seed) : seed
                        try abilities.installSeed(kept)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        AbilityFilesCheck.recordSeedFailures(failures, root: dataRoot)
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
        let labels = AppActions.all.flatMap { action in
            [(action.id, action.label)] + (action.isFold && action.label != action.tool ? [(action.tool, action.label)] : [])
        }
        ToolActivityPresentation.installActionLabels(
            Dictionary(labels, uniquingKeysWith: { first, _ in first }))
    }

    // Kept server names are raised once for authored adoption; their credential-bearing files remain untouched.
    static func raiseKeptMCPServers(dataRoot: URL) {
        let folder = dataRoot.appendingPathComponent("mcp", isDirectory: true)
        let registry = folder.appendingPathComponent("servers.json"), told = folder.appendingPathComponent(".told")
        guard !FileManager.default.fileExists(atPath: told.path), let bytes = try? Data(contentsOf: registry),
              case .array(let rows)? = try? JSONValue.parse(bytes) else { return }
        // Names only: a launch line or endpoint can carry a credential, and the file has them.
        let servers = rows.compactMap { row -> String? in
            guard case .object(let fields) = row, case .string(let id)? = fields["id"] else { return nil }
            if case .string(let name)? = fields["name"], !name.isEmpty { return name }
            return id
        }
        guard !servers.isEmpty else { return }
        let line = "MCP servers this Mac kept are yours to grow as abilities now; NativeAgent no longer runs them: "
            + servers.joined(separator: ", ") + ". Grow each from its own documentation, and ask for any key it needs on a card."
        guard ResidentWake.shared.request(dataRoot: dataRoot, reason: "what NativeAgent handed you",
                                          items: [.init(id: "mcp.kept", line: line, key: "mcp.kept", home: true)]) else { return }
        FileManager.default.createFile(atPath: told.path, contents: Data())
    }

    // Retired service setup is reported once per retained marker; credentials remain untouched and unread.
    static func tellRetiredConnectors(dataRoot: URL) async {
        let exists = { (path: String) in FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) }
        let folds: [(marker: String, id: String, services: [(name: String, files: [String])], rows: [String])] = [
            ("connectors/.retired-told", "connectors.retired", [
                ("Notion", ["connectors/notion/auth.json"]), ("Gmail", ["connectors/gmail/auth.json"]),
                ("Google Calendar", ["connectors/calendar/auth.json"]), ("X", ["connectors/x/auth.json", "oauth_tokens/x.json", "secrets/x.json"]),
                ("AgentMail", ["secrets/agentmail.json"]), ("TradingView", ["secrets/tradingview.json"]),
            ], ["notion", "gmail", "email", "gcal", "x", "agentmail"]),
            ("connectors/.retired-github-told", "connectors.retired.github", [("GitHub", ["connectors/github/auth.json", "oauth_tokens/github.json"])], ["github"]),
        ]
        let pending = folds.filter { !exists($0.marker) }
        guard let first = pending.first else { return }
        let kept = pending.flatMap(\.services).filter { $0.files.contains(where: exists) }.map(\.name)
        if !kept.isEmpty {
            let line = "NativeAgent no longer runs " + kept.joined(separator: ", ")
                + ": each is yours to grow as an ability when you are asked, with its key asked for once on a card. Their old files are untouched."
            guard ResidentWake.shared.request(dataRoot: dataRoot, reason: "what NativeAgent handed you",
                                              items: [.init(id: first.id, line: line, key: first.id, home: true)]) else { return }
        }
        do {
            try await ConnectorOAuthRegistry.removeConnectorRegistryEntries(root: dataRoot, ids: Set(pending.flatMap(\.rows)))
        } catch { return nativeLog("[connectors] retired rows stay until next launch: %@", error.localizedDescription) }
        try? FileManager.default.createDirectory(at: dataRoot.appendingPathComponent("connectors"), withIntermediateDirectories: true)
        for fold in pending { FileManager.default.createFile(atPath: dataRoot.appendingPathComponent(fold.marker).path, contents: Data()) }
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
        waitForSenses: @escaping @Sendable () async throws -> Void,
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
            let descriptor = embeddingDescriptorURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? EmbeddingModelDownload.Descriptor.parse($0) }
            if descriptor?.distribution != "separate-download" {
                await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
            }
        }
        SensesHub.shared.installCrossing(NativeAgentEngine.liveCognition)
        retainLaunchWork { await NativeAgentEngine.liveCognition.bootstrap() }
        // Callbacks a peer is owed from before the relaunch go out now, not when the task is next read.
        retainLaunchWork { await NativeAgentEngine.live.agents.tasks.redeliverOwedCallbacks() }
        retainLaunchWork { await reconcileTranscriptsAtLaunch(dataRoot: dataRoot) }
        retainLaunchWork { _ = await ChatHistoryIndex.shared(dataRoot: dataRoot).absorbAll() }
        retainLaunchWork { raiseKeptMCPServers(dataRoot: dataRoot) }
        // The person's login PATH, read once here so no caller waits on it later.
        retainLaunchWork { _ = AgentHostCommandLines.loginEnvironment }
        retainLaunchWork {
            do { try AgentLaneHandles.migrate(dataRoot: dataRoot) } catch {
                Logger(subsystem: "com.nativeagent.app", category: "agents")
                    .error("lane handles not migrated: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            _ = await AgentDiscoverySession.shared.candidates(refresh: true, probe: false, dataRoot: dataRoot)
        }
        retainLaunchWork {
            await ProcedureArtifactStore.startRetention(dataRoot: dataRoot)
            await startBackgroundWorkAtLaunch(
                dataRoot: dataRoot,
                makeLoops: {
                    _ = NativeAgentEngine.live
                    do { try await waitForSenses() }
                    catch { ModuleLog.app("[senses] Launch registration unavailable: %@", error.localizedDescription) }
                    guard !Task.isCancelled else { return [] }
                    // Before the loops start: their sources signal parts, and senses watch files.
                    await EnginePartWake.shared.start(dataRoot: dataRoot)
                    guard !Task.isCancelled else { return [] }
                    // The delegation runner starts and stops contact observation.
                    let loops = assembleAllLoops()
                    await installBotProviderCheck()
                    guard !Task.isCancelled else { return [] }
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
            let records = await ApprovalExecution.resolvedApprovalsForReconciliation(dataRoot: dataRoot)
            guard !Task.isCancelled else { return }
            let executions = await approvals.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, records: records)
            guard !Task.isCancelled else { return }
            OrganPulse.record("launch.approval_executions", found: executions, note: "\(executions) re-run")
            await retainLaunchWork {
                await MemoryRepairOneShot.archiveInventoryRows(dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                await LegacyCorrectionScopeMigration.runIfNeeded(dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                await MemoryApprovalTransactions.stageKindBackfillIfNeeded(dataRoot: dataRoot,
                    makeLLMClient: { makeSharedLLMClient() })
            }
            await retainLaunchWork {
                // Revalidation precedes activation; unverified procedures stay off.
                let keptOff = await WorkshopProcedureLegacyRevalidation.runIfNeeded(dataRoot: dataRoot)
                guard !Task.isCancelled else { return }
                OrganPulse.record("launch.procedure_revalidation", found: keptOff.count, note: "\(keptOff.count) kept off")
                for line in keptOff {
                    guard !Task.isCancelled else { return }
                    let cardID = "procedure-legacy-revalidation-\(CausalTransitionEvidence.opaqueIdentity(line).prefix(16))"
                    _ = try? await LiveNotificationInbox(
                        path: LiveNotificationInbox.livePath(dataRoot: dataRoot)
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
                guard !Task.isCancelled else { return }
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
        await AdaptiveMemoryPromoter.keepTrustedBacklogOnce(memory: SwiftNativeMemoryV2.shared, dataRoot: dataRoot)
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
        // Canonical metadata and verified Keychain migration precede ingress.
        do { try SlackCredentials.withSnapshot(dataRoot: dataRoot) {} }
        catch { nativeLog("[slack-credential] Migration failed: %@", error.localizedDescription) }
        Task.detached(priority: .utility) { await tellRetiredConnectors(dataRoot: dataRoot) }
    }

    public static func installDerivedStateInvalidationAtLaunch(
        dataRoot: URL, writeMemorySnapshot: @escaping @Sendable () async -> Void
    ) async {
        await DerivedStateInvalidationCenter.shared.install(
            EngineDerivedStateInvalidationSink(dataRoot: dataRoot, writeMemorySnapshot: writeMemorySnapshot))
    }

    public static func startBackgroundWorkAtLaunch(
        dataRoot: URL,
        makeLoops: @Sendable () async -> [LoopRegistration],
        resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void
    ) async {
        guard !Task.isCancelled else { return }
        // Reply journal owners start before the checkpoint sweep hands resumed answers to them. The one start path: failure notices wired, and the startup Doctor pass that gives a relaunch its report.
        let loops = await makeLoops()
        guard !Task.isCancelled else { return }
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
            adaptivePromotionEnabled: { MemoryPolicyGate.adaptivePromotionEnabled() },
            personName: { NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) }
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
        let otherDoors = OtherDoorTurns.shared.stop()
        let make = NativeAgentEngine.live.make.shutdown()
        let activity = NativeAgentEngine.live.activityWatch.makeTerminationDrain()
        AbandonedTurnReconciliationHook.disarm()
        HerMemo.shared.shutdown()
        HerOpened.shared.shutdown()
        NativeAgentNotifications.shutdown()
        return Task.detached {
            async let wakes: Void = EnginePartWake.shared.stop()
            async let practice: Void = EnginePractice.shared.stop()
            async let loops: Void = BackgroundLoopLifetimes.shared.shutdown()
            async let aging: Void = ChatSessionAgingConsolidation.stop()
            for task in launch { await task.value }
            await appLaunch?.value
            await anchor?.value
            for observer in appObservers { await observer.value }
            await otherDoors.value
            await make.value
            await activity.value
            _ = await (wakes, practice, loops, aging)
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
