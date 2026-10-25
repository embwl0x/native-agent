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
import DreamREMCycle
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
// Blueprint: | `EngineLaunch.swift` | `NativeAgentEngine`: canonical memory attachment and launch recovery; discovery starts independently at launch, its install observation once part wakes are registered; trusted bundled seeds installed before ingress; current seeds follow changed shipped bodies, while edited/non-seed content and other occupied slots are preserved, each failure retained by AbilityFilesCheck and reported through Doctor to the person while launch continues; an installed seed the readable bundle no longer ships, still its proof's candidate and never re-enabled, is switched off through its registry (restorable); root-bound derived-state invalidation; NativeAgentEngine launch/recovery ordering, procedure-retention root admission and terminal drain, background loop manifest and surface/workshop/scheduler composition; native effects arrive through EngineBackgroundWorkHost; MCP servers a data root kept are raised to their once by name as theirs to grow (`raiseKeptMCPServers`), their file untouched and, since a launch line can carry a key, fenced from their file readers with its backup copies; `tellRetiredConnectors` removes retired service rows and tells their once which were set up; old credentials stay untouched and unread; the engine exposes the existing activity controller through its body host |

/// Native effects used by Core's background composition. Scheduling, admission
/// and reconciliation remain with the existing engine and background owners.
public protocol EngineBackgroundWorkHost: Sendable {
    @MainActor var activityWatch: ActivityWatchController { get }
    var approvals: ApprovalTransactionCoordinator { get }
    var attention: AttentionRouter { get }
    var backupHost: TrustBackupHost { get }
    func postMacNotification(title: String, body: String, userInfo: [String: String], soundName: String?) async -> NativeAgentNotificationPostResult
    func notifyIfAttentionWorthy(dataRoot: URL, itemId: String, title: String, summary: String, source: String, severity: String) async
    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> DoctorReport
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue]) async throws -> (id: String, status: String)
    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending
    var speechPermission: SpeechPermissionSnapshot { get }
    /// Asks macOS once when the grant was never decided (the system's own prompt); otherwise the live status.
    func requestSpeechPermissionIfNotDetermined() async -> SpeechPermissionSnapshot
    var voiceName: String { get }
    var agentSubject: String { get }
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
        BackgroundLoopsManager.shared.receiveOrganPulses()
        // The person-input tap starts now or not at all this launch. Without
        // it she raises the grant herself (User's law): once a launch, until
        // granted, a card waits in the person's conversation (on a first
        // launch, the first one there is). Nothing of hers waits on it; the
        // card opens the pane and, once the switch is on, says one relaunch
        // is needed.
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
            let restored = try await Task.detached(priority: .userInitiated) {
                try await TrustBackupPersistence.resumeStagedBackupRestoreAtLaunch(dataRoot: dataRoot, host: backupHost)
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
        // No state owner or ingress exists until restore and recovery succeed.
        await Task.detached(priority: .utility) {
            if let resources {
                await installBundledParts(dataRoot: dataRoot, resources: resources)
            }
            do { try NativeAgentBuildIdentity.current.writeLaunchStamp(root: dataRoot) }
            catch { ModuleLog.app("[launch] Could not record app start time: %@", error.localizedDescription) }
            do {
                _ = try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot)
                ModuleLog.app("[workspace] canonical work root ready")
            } catch { ModuleLog.app("[workspace] canonical work root unavailable: %@", error.localizedDescription) }
            ChatUpdateNote.recordLaunchAtStartup(dataRoot: dataRoot, currentVersion: currentVersion, resources: resources)
        }.value
        _ = await Task.detached(priority: .userInitiated) { NativeAgentEngine.live }.value
        return true
    }

    private static func installBundledParts(dataRoot: URL, resources: URL) async {
        let abilities = AbilityStore(dataRoot: dataRoot)
        var failures: [String] = []
        do {
            let bundled = AbilityStore(dataRoot: resources)
            let seeds = try AbilityStore.seedCatalog(resources: resources)
            // Retirement is read off the whole bundle: one unreadable seed and nothing fades this launch.
            let shipped = seeds.map { try? AbilityStore.decode($0).id }
            if !shipped.contains(nil) {
                do { try fadeRetiredSeeds(abilities, shipped: Set(shipped.compactMap { $0 }), dataRoot: dataRoot) }
                catch { failures.append("retired seeds: \(error.localizedDescription)") }
            }
            // Her tools and skills take the one form of a part first (idempotent),
            // with the owner's trust in agents bound, as their admissions read it.
            PeerTrust.install(dataRoot: dataRoot)
            do { try await Parts(root: dataRoot).migrate() } catch { failures.append("parts: \(error.localizedDescription)") }
            let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot) { _, _ in nil }
            await OwnedProgramInvocation.$host.withValue(host) {
                for url in seeds.sorted(by: { $0.path < $1.path }) {
                    do {
                        let seed = try AbilityStore.decode(url)
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
                await DoctorStatusProjection.recordReadings([await AbilityFilesCheck(root: dataRoot).run()], dataRoot: dataRoot)
            }
        }
    }

    /// A seed the app no longer ships fades: an installed copy still exactly
    /// the seed is switched off through its registry, the way quarantine does,
    /// restorable and never deleted. One she changed (its bytes no longer the
    /// candidate its seed proof names) or turned back on (`enabledAt`) is hers and stays.
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

    /// NativeAgent runs no MCP servers of its own (10-21): what she reaches,
    /// she grows. Servers a data root kept from before are hers to grow; she
    /// hears of them once, and their file stays as it was.
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

    /// A service's ability is hers to grow (10-21): NativeAgent no longer runs
    /// Notion, Gmail, Google Calendar, X, AgentMail, TradingView or GitHub.
    /// Their old credentials (files and Keychain items) stay as they were and
    /// are no longer read; she hears once which were set up, and asks for a key
    /// on a card when she grows one. GitHub folded later the same day, so it
    /// has its own marker: a root that already heard the first note hears it once.
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
        reindexMemory: @escaping @Sendable () async -> Void,
        registerBackgroundTasks: @MainActor () -> Void,
        waitForSenses: @escaping @Sendable () async throws -> Void,
        resumeMacTurn: @escaping @Sendable (TurnCheckpoint, TurnContinuationRuntime) async throws -> Void,
        momentsEnabled: @escaping @Sendable () -> Bool,
        approvals: ApprovalTransactionCoordinator
    ) {
        guard !launchStopped, !residentsStarted, !Task.isCancelled else { return }
        residentsStarted = true
        retainLaunchWork {
            await NativeAgentEngine.live.chrome.observeBrowserLaunches()
            guard !Task.isCancelled else { return }
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        }
        retainLaunchWork {
            if await reconcileMemoryAtLaunch(dataRoot: dataRoot, storageUnavailable: storageUnavailable), !Task.isCancelled {
                await reindexMemory()
            }
        }
        registerBackgroundTasks()
        WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())
        // Each bring-up remains independent so one blocked store cannot hold
        // the other resident owners or the native launch callback.
        retainLaunchWork {
            let descriptor = embeddingDescriptorURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? EmbeddingModelDownload.Descriptor.parse($0) }
            if descriptor?.distribution != "separate-download" {
                await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
            }
        }
        retainLaunchWork { await NativeAgentEngine.liveCognition.bootstrap() }
        // Callbacks a peer is owed from before the relaunch go out now, not when the task is next read.
        retainLaunchWork { await NativeAgentEngine.live.agents.tasks.redeliverOwedCallbacks() }
        retainLaunchWork {
            await reconcileTranscriptsAtLaunch(dataRoot: dataRoot)
            guard !Task.isCancelled else { return }
            // Behind her: the first launch with the index builds it; later
            // launches absorb only what changed while she was away.
            _ = ChatHistoryIndex.shared(dataRoot: dataRoot).absorbAll()
        }
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
                makeLLMClient: { makeSharedLLMClient() }, momentsEnabled: momentsEnabled)
        }
        retainLaunchWork {
            await reconcileApprovalsAtLaunch(dataRoot: dataRoot,
                makeLLMClient: { makeSharedLLMClient() }, approvals: approvals,
                stagePendingREMProposals: { await stagePendingREMProposalsAtLaunch() })
        }
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

    @MainActor
    public static func drainResidentWorkForTermination(
        shutdownSenses: @escaping @Sendable () async -> Void,
        makeActivityWatchDrain: @MainActor () -> Task<Void, Never>
    ) {
        stopLaunchWork()
        NativeAgentEngine.live.trace.stop()
        let otherDoorDrain = OtherDoorTurns.shared.stop()
        AbandonedTurnReconciliationHook.disarm()
        HerMemo.shared.shutdown()
        HerOpened.shared.shutdown()
        let makeDrain = NativeAgentEngine.live.make.shutdown()
        NativeAgentNotifications.shutdown()
        let group = DispatchGroup()
        let stemStopped = Task.detached { await EnginePartWake.shared.stop() }
        let attention = NativeAgentEngine.live.ports.backgroundWork.attention
        group.enter()
        Task.detached { await makeDrain.value; group.leave() }
        group.enter()
        Task.detached { await attention.shutdown(); group.leave() }
        group.enter()
        Task.detached { await otherDoorDrain.value; group.leave() }
        group.enter()
        Task.detached { await ChatSessionAgingConsolidation.stop(); group.leave() }
        group.enter()
        Task.detached { await TurnVolatileArchiveRegistry.shared.stopOrphanRetention(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await NativeAgentEngine.live.chrome.stop(); group.leave() }
        group.enter()
        Task.detached { await ProcedureArtifactStore.stopRetention(dataRoot: NativeAgentEngine.live.dataRoot); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await NativeAgentEngine.liveCognition.flushForTermination(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await BackgroundLoopsManager.shared.shutdown(); group.leave() }
        group.enter()
        Task.detached { await SwiftNativeMemoryV2.shared.shutdownEmbeddingConvergence(); group.leave() }
        group.enter()
        Task.detached { await AdaptiveMemoryPromoter.shared.shutdown(); group.leave() }
        group.enter()
        Task.detached { await SwiftNativeMemoryV2.shared.shutdownProjections(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await shutdownSenses(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await OwnedProgramRunner.endResidents(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await SwiftToolDispatcher.closeACPConnections(); group.leave() }
        group.enter()
        Task.detached { await stemStopped.value; await NativeAgentEngine.live.contextFlow.stop(); group.leave() }
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
        guard !launchStopped, !Task.isCancelled else { return }
        NativeAgentEngine.liveDeviceSync.bridge.setup()
        NativeAgentEngine.liveDeviceSync.bridge.observeIncomingMessages(onMessage: forward)
        // The bridge publishes the pairing key once it knows this Mac holds
        // the phone; a launch never writes it over another Mac's.
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
        // 2026-09-11: a pending statement retired by its own correction must
        // not leave a tombstone that blocks the correction (Astra comb 1).
        // Idempotent, no-op once clean.
        await SwiftNativeMemoryV2.shared.repairSupersededTombstones()
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

    public static func reconcileApprovalsAtLaunch(
        dataRoot: URL,
        makeLLMClient: @escaping @Sendable () -> any LLMClient,
        approvals: ApprovalTransactionCoordinator,
        stagePendingREMProposals: @Sendable () async -> Int
    ) async {
        // Settle resolved executions before staging backfills and swaps.
        let records = await ApprovalTransactionCoordinator.resolvedApprovalsForReconciliation(dataRoot: dataRoot)
        guard !Task.isCancelled else { return }
        let repairs = await MemoryApprovalTransactions.reconcileUnappliedMemoryRepairs(dataRoot: dataRoot, records: records)
        guard !Task.isCancelled else { return }
        OrganPulse.record("launch.memory_repairs", found: repairs, note: "\(repairs) re-run")
        await MemoryRepairOneShot.archiveInventoryRows(dataRoot: dataRoot)
        guard !Task.isCancelled else { return }
        await LegacyCorrectionScopeMigration.runIfNeeded(dataRoot: dataRoot)
        guard !Task.isCancelled else { return }
        // Backfills and swaps use the same approved-execution recovery path.
        let backfills = await MemoryApprovalTransactions.reconcileUnappliedKindBackfills(dataRoot: dataRoot, records: records)
        guard !Task.isCancelled else { return }
        OrganPulse.record("launch.kind_backfills", found: backfills, note: "\(backfills) re-run")
        await MemoryApprovalTransactions.stageKindBackfillIfNeeded(
            dataRoot: dataRoot,
            makeLLMClient: makeLLMClient
        )
        guard !Task.isCancelled else { return }
        var settled = 0, failures: [String] = []
        for swap in await MemoryConsolidationGate.reconcile(dataRoot: dataRoot) {
            guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        let approvals = await approvals.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, records: records)
        OrganPulse.record("launch.approval_executions", found: approvals, note: "\(approvals) re-run")
        guard !Task.isCancelled else { return }
        // Revalidate legacy evidence before staging the same local-only review
        // as terminal-event reconciliation; unverified procedures stay off.
        let procedureDataRoot = dataRoot
        let keptOff = await WorkshopProcedureLegacyRevalidation.runIfNeeded(dataRoot: procedureDataRoot)
        guard !Task.isCancelled else { return }
        OrganPulse.record("launch.procedure_revalidation", found: keptOff.count, note: "\(keptOff.count) kept off")
        for line in keptOff {
            guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        let activationCards = await WorkshopProcedureExactActivationCoordinator
            .reconcileLocalFileCopyIfQualified()
        guard !Task.isCancelled else { return }
        OrganPulse.record("launch.procedure_activation", found: activationCards, note: "\(activationCards) review staged")
        // Catch up existing unstaged REM rows without generating another batch.
        let remStaged = await stagePendingREMProposals()
        OrganPulse.record("launch.rem_staging", found: remStaged, note: "\(remStaged) staged")
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
        // Reply journal owners start before the checkpoint sweep hands
        // resumed answers to them. The one start path: failure notices
        // wired, and the startup Doctor pass that gives a relaunch its report.
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

    public static func startBackgroundLoops(loops: [LoopRegistration]) async {
        let manager = BackgroundLoopsManager.shared
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
            async let desk: Void = ApprovalTransactionCoordinator.settleDeskWaitsOnEveryResolve(dataRoot: dataRoot)
            async let grants: Void = InlineInteractionResolver.GrantWatch.shared.observe()
            async let interactions: Void = InlineInteractionDelivery.observe(dataRoot: dataRoot)
            _ = await (desk, grants, interactions)
        }), !Task.isCancelled else { return }
        // Refresh the heartbeat receipt after restart without blocking startup.
        await retainLaunchWork { await manager.runTickOnce(loopId: "heartbeat") }
        guard !Task.isCancelled else { return }
        guard NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) else { return }
        let config = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        if (config.enabled ?? true) && (config.runOnStartup ?? true) {
            await retainLaunchWork { await manager.runTickOnce(loopId: "doctor_auto_run") }
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
    /// credential/routing resolution. PersonaBackedBackgroundLLMClient supplies
    /// persona, user-memory core and organism posture when persona context is absent.
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
    /// TriggerScheduler job at 03:30 Mac-local. A periodic REM wrapper is
    /// absent for the same reason: `nativeagent-weekly-rem` at 04:30
    /// Mac-local on Sundays owns weekly REM.
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
        do {
            return try SlackSocketModeLoop.ifConfigured(
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
        } catch {
            return .unreadable(loopId: "slack_socket_mode",
                               error: "could not read the Slack tokens: \(error.localizedDescription)")
        }
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
        // Keep the exact Telegram profile and approval filer resident for the
        // loop lifetime. Routing/policy remain per-turn snapshots; only the
        // stateless orchestration graph and schema caches are reused.
        let client = NativeAgentEngine.live.chatClient(
            profile: .telegram,
            approvalFiler: approvalFiler
        )
        let telegramFace: PartFaces.Call = { id, input, version in
            do {
                return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("telegram:projection:" + id)) {
                    await Parts(root: dataRoot).face(id: id, input: input, version: version)
                }
            } catch {
                return .failure(.init(code: "unavailable", message: error.localizedDescription))
            }
        }
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
            },
            partCall: { id, input in
                guard let envelope = ChatToolSessionContext.envelope, envelope.surface == "telegram", envelope.workIdentity != nil else {
                    return .failure(.init(code: "unavailable", message: "The Telegram command has no authenticated originating update."))
                }
                do {
                    return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: envelope) {
                        await Parts(root: dataRoot).call(id: id, input: input, as: JSONValue.self)
                    }
                } catch {
                    return .failure(.init(code: "unavailable", message: error.localizedDescription))
                }
            },
            partFace: telegramFace
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
            partFace: telegramFace,
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
        // A grant macOS has never been asked for is asked for now, by her (the
        // one card she raises herself, 0.6.7): the system's own prompt, and the
        // voice note transcribes on the grant. Only a refusal needs the pane.
        if capability == "speechRecognition",
           await NativeAgentEngine.live.ports.backgroundWork.requestSpeechPermissionIfNotDetermined().isGranted {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
            return
        }
        await ChatSurfaceBackgroundWork.fileSystemPermissionNotice(
            capability: capability, dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission },
            assistanceCard: { try await EngineBackgroundWorkPort().assistanceCard(dataRoot: dataRoot, input: $0) },
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

    func stopAgentConversations() async {
        await NativeAgentEngine.live.agents.continuation.stop()
    }

    func nextConversationDeadline(after now: Date) -> Date? {
        NativeAgentEngine.live.agents.continuation.nextDeadline(after: now)
    }
}


// MARK: - Desk notify loop (desk-side push, NO cognition)
//
// A throttled, desk-local loop that lets the Desk tap User on the shoulder: it
// reads desk state, asks her desk-notify part which items changed
// since their last ping (cooldown-gated), fires a Mac banner + paired-device
// push for each, then stamps lastNotifiedAt so a single change can't fan out
// into duplicate pings (Agent's idempotency requirement).
//
// This NEVER touches the CognitiveSubstrate — it's a SEPARATE loop from the
// cognition manifest in assembleAllLoops. The desk reaches out to User; it does
// not live in her head (User's hard line, 2026-06-29). The part proposes;
// publication, quiet hours, delivery and stamps remain with native owners.

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
            propose: { input in
                try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("background:desk_notify")) {
                    switch await Parts(root: dataRoot).call(id: "desk-notify", input: input, as: DeskNotificationProposal.self) {
                    case .success(let proposal): return proposal
                    case .failure(let error): throw error
                    }
                }
            },
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
            dreamCareNightProvider: DreamBackgroundWork.makeDreamCareNightProvider(cognitionRuntime: cognition),
            dreamReceiptSink: DreamBackgroundWork.makeDreamReceiptSink(cognitionRuntime: cognitionRuntime(for: root)),
            // …and the dream's mood flows back out into her slow disposition
            // layer, for the same reason (U2a, 2026-07-09).
            dreamMoodSink: DreamBackgroundWork.makeDreamMoodSink(cognitionRuntime: cognitionRuntime(for: root)),
            lifecycleObserver: cognition
        )
        return try await DreamBackgroundWork.runDream(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition,
            force: force, trigger: trigger, notifications: EngineREMProposalNotifications()
        )
    }

    /// Weekly REM consolidation. It stages approvals like the background
    /// loop, so a manual run's proposals reach the inbox. `force` defaults to
    /// the manual behaviour (the weekly marker is distinct from the
    /// one-dream-per-night diary contract); the persisted Sunday job passes
    /// false so a "Run REM now" earlier the same week and the 04:30 job never
    /// distil the same dreams twice.
    public static func runRem(dataRoot root: URL, force: Bool = true, repair: Bool = false) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = makeDreamREMCycle(
            root: root,
            gate: try await CognitionViewFacade(dataRoot: root).dreamGateChecked(),
            remStageApproval: DreamBackgroundWork.makeREMProposalStager(dataRoot: root, notifications: EngineREMProposalNotifications()),
            lifecycleObserver: cognition
        )
        if repair {
            let archived = try await impl.repairREM()
            return ["ok": true, "archivedEntries": archived, "proposalsGenerated": 0, "repaired": true]
        }
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
        MaintenanceBackgroundWork(port: EngineBackgroundWorkPort()).makeWeeklySelfImprovementLoop(
            dataRoot: dataRoot, llm: llm, workshopOutcomes: {
                let engine = NativeAgentEngine.forRoot(dataRoot)
                return try await engine.tools.withPartDoor(envelope: .native("maintenance:self_improvement_sweep:weekly-outcomes")) {
                    let input = try await SwiftNativeWorkshopRunner(root: dataRoot).weeklyOutcomeInput()
                    let result = await Parts(root: dataRoot).call(id: "weekly-outcomes", input: input, as: String.self)
                    try Task.checkCancellation()
                    switch result {
                    case .success(let text): return text
                    case .failure(let error): throw error
                    }
                }
            })
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
    func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner] {
        [TrustBackupPersistence.diskStorageOwner(dataRoot: dataRoot), ChatSessionRetention.diskStorageOwner,
         ContextSQLiteStore.diskStorageOwner]
    }

    func runAutoDoctor(checks: any DoctorChecksProtocol, dataRoot: URL) async throws -> [CheckResult] {
        // An automatic run (launch, first turn, the weekly sweep) takes the
        // same lifecycle as Run: admitted only when no run is in flight, and
        // its report is the one the Doctor page and the pill read, so a
        // relaunch is never left at "no report" while one ran.
        let doctor = NativeAgentEngine.live.doctor
        let owned = doctor.dataRoot == dataRoot
        if owned, !(await doctor.admitRun()) { return [] }
        do {
            let report = try await NativeAgentEngine.live.ports.backgroundWork.runAutoDoctor(checks: checks, dataRoot: dataRoot)
            if owned {
                let rows = await DoctorStatusProjection.repairProjection(report.checks, dataRoot: dataRoot)
                await doctor.finishRun(DoctorReport(status: DoctorStatusProjection.doctorRollup(rows.map(\.status)),
                                                    repaired: report.repaired, checks: rows))
            }
            return report.checks
        } catch {
            if owned { await doctor.finishRun(nil) }
            throw error
        }
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
    public static func makeNativeTriggerScheduler(dataRoot: URL) -> SwiftNativeTriggerScheduler {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized
            == PersistenceCore.defaultDataRoot().standardizedFileURL
        let workshopRunner: SwiftNativeWorkshopRunner? = isLiveRoot
            ? makeWorkshopRunner(lifecycleObserver: NativeAgentEngine.liveCognition)
            : nil
        let notifier: TriggerNotifier? = isLiveRoot
            ? NativeAgentEngine.live.ports.backgroundWork.triggerNotifier
            : nil
        return SwiftNativeTriggerScheduler(
            root: standardized,
            workshopRunner: workshopRunner,
            notifier: notifier,
            worklogPath: isLiveRoot
                ? nil
                : standardized.appendingPathComponent("no-such-worklog.jsonl"),
            morningBriefPart: { input in
                if !isLiveRoot, input.objectValue?["operation"] == .string("brief") {
                    throw TriggerSchedulerError.persistenceFailure("A secondary root cannot spend the live morning-brief model route.")
                }
                let engine = NativeAgentEngine.forRoot(standardized)
                return try await engine.tools.withPartDoor(envelope: .native("trigger:morning_brief"), fileAccess: "read_only") {
                    switch await Parts(root: standardized).call(id: "native-morning-brief", input: input, as: JSONValue.self) {
                    case .success(let value): return value
                    case .failure(let error): throw error
                    }
                }
            }
        )
    }

    public static func makeTriggerSchedulerLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        let standardized = dataRoot.standardizedFileURL
        let isLiveRoot = standardized == PersistenceCore.defaultDataRoot().standardizedFileURL
        let native = makeNativeTriggerScheduler(dataRoot: standardized)
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
            let work = TriggerSchedulerBackgroundWork.makeJobWork(
                runDueJobs: { await dueJobRunner.runDueJobs(maxJobs: $0) },
                activityFailure: { await dueJobRunner.activityFeedError },
                nextDeadline: { await dueJobRunner.nextMeaningfulDeadline(after: $0) },
                bots: NativeAgentEngine.live.bots,
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
                    DeskContinuationScheduler.ownerReceiptChanged,
                    SwiftNativeTriggerScheduler.dueWorkRemaining,
                    // A part's `schedule:` wakes are its own jobs, kept with its header.
                    AbilityStore.didChange,
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

    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue]) async throws -> (id: String, status: String) {
        try await NativeAgentEngine.live.ports.backgroundWork.runConnectorAction(id: id, dryRun: dryRun, input: input)
    }

    var connectorActionIDs: Set<String> { Set(connectorActionDescriptors().map(\.id)) }

    func runDream(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runDream(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runRem(force: Bool) async throws -> sending [String: Any] {
        try await NativeAgentEngine.runRem(dataRoot: PersistenceCore.defaultDataRoot(), force: force)
    }

    func runHarnessBenchmark() async throws -> (id: String, status: String?) {
        let root = PersistenceCore.defaultDataRoot()
        let run = await HarnessBenchmarkRun.run(
            authoredToolCount: { try await ToolsFacade(dataRoot: root).listAuthored().count },
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
