import Synchronization
import SenseCore
import MacNerves
import Foundation
import MindCore
import OSLog
import DeskCore
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Darwin
import NativeAgentShared
// Blueprint: | `EngineLaunch.swift` | Ordered bring-up, sealed program seeds, launch identities, ingress and retained settlement |

/// Native ports supply effects; existing engine and background owners retain scheduling, admission and reconciliation.
public protocol EngineBackgroundWorkHost: Sendable {
    @MainActor var activityWatch: ActivityWatchController { get }
    var approvals: ApprovalExecution { get }
    var attention: AttentionRouter { get }
    func runAutoDoctor(checks: SwiftNativeDoctorChecks, dataRoot: URL) async throws -> DoctorReport
    func makeCompletionSender(dataRoot: URL, silentTelegram: Bool, requestedResultDeliveryID: String?, authorizeTelegramReply: @escaping @Sendable (
        TelegramConfig, Int) -> Bool) -> any AgentBridgeCompletionSending
    var speechPermission: SpeechPermissionSnapshot { get }
    /// Request undecided macOS grants only once; otherwise read live status.
    func requestSpeechPermissionIfNotDetermined() async -> SpeechPermissionSnapshot
    var voiceName: String { get }
    var agentSubject: String { get }
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
        let contactsPath = dataRoot.appendingPathComponent("agents/peers.json").standardizedFileURL.path
        if changes.contains(where: {
            $0.namespace == "agent-trust" && $0.operation == .reconcile && $0.canonicalLocator == contactsPath
        }) {
            // Contact writes already announce this edge; an observed credential-only mismatch reaches both memory projections here too.
            NotificationCenter.default.post(AgentPeerStore.TrustDidChange(fileURL: nil))
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

    @MainActor
    static func retainLaunchWork(_ operation: @escaping @Sendable () async -> Void) {
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
        if residentsStarted { live.bodyField?.closeFrontEvents() }
        for task in launchTasks.values { task.cancel() }
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
        // Beats are recorded from the first one; the mind's nerve feels them only while a mind runs (`MindLifetime`).
        BackgroundLoopLifetimes.shared.receiveOrganPulses()
        // Input Monitoring is asked once, on the first-run permission card's walk with every other grant; Trust and the Desk's night row say
        // when it is still off. No second card is raised here.
    }

    public static func validateProvidersAtLaunch() {
        signal(SIGPIPE, SIG_IGN)
    }

    @MainActor
    public static func prepareStateAtLaunch(
        dataRoot: URL, currentVersion: String, resources: URL?,
        publicReleaseUnavailable: @MainActor @Sendable (String) async -> Void,
        backupRestoreUnavailable: @MainActor @Sendable (String) async -> Void,
        confirmMissingRoots: @MainActor @Sendable ([String]) async -> Bool
    ) async -> Bool {
        if case .failed(let error) = await Task.detached(priority: .userInitiated, operation: {
            InstallPaths.preparePublicReleaseDataRootIfNeeded()
        }).value {
            await publicReleaseUnavailable(error)
            return false
        }
        do {
            let restored = try await Task.detached(priority: .userInitiated) {
                try await TrustBackupPersistence.resumeStagedBackupRestoreAtLaunch(dataRoot: dataRoot)
            }.value
            for note in restored?.notCarried ?? [] { ModuleLog.app("[backup-restore] %@", note) }
        } catch {
            await backupRestoreUnavailable(error.localizedDescription)
            return false
        }
        if !InstallPaths.isPublicReleaseBundle {
            let missing = await Task.detached { PersistenceCore.missingLaunchRoots(dataRoot: dataRoot) }.value
            if !missing.isEmpty, !(await confirmMissingRoots(missing)) { return false }
        }
        // This root's life begins at launch, not at whichever owner first reads it: a phone message older than its birth is another life's.
        do { _ = try DataRootLife.current(in: dataRoot) } catch { ModuleLog.app("[life] %@", error.localizedDescription) }
        do {
            try await Task.detached {
                let directory = dataRoot.appendingPathComponent("skills/runs", isDirectory: true)
                let paths: [URL]
                do { paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
                catch CocoaError.fileReadNoSuchFile { return }
                for path in paths where path.lastPathComponent.range(of: "^run-[0-9a-f]{8}\\.claimed$", options: .regularExpression) != nil {
                    try FileManager.default.moveItem(at: path, to: path.deletingPathExtension().appendingPathExtension("json"))
                }
            }.value
        } catch {
            ModuleLog.app("[runs] Saved-run recovery unavailable: %@", error.localizedDescription)
        }
        do {
            let recovered = try await MacControlOperationStore(dataRoot: dataRoot).recoverInterruptedOperations()
            ModuleLog.app("[mac-control] startup recovered interrupted operations: %d", recovered)
        } catch {
            ModuleLog.app("[mac-control] Mac actions unavailable after recovery failure; app will start: %@", error.localizedDescription)
        }
        // Recover before ingress; each failure refuses only its owner’s effects so unrelated surfaces can start.
        var strandedBrowserOperations: Int?
        do {
            strandedBrowserOperations = try await SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
                .executeBrowserOperation(.recoverStrandedRunning).recoveredCount
        } catch {
            ModuleLog.app("[browser] Browser actions unavailable after recovery failure; app will start: %@", error.localizedDescription)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) { await installBundledParts(dataRoot: dataRoot, resources: resources) }
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

    private static func installBundledParts(dataRoot: URL, resources: URL?) async {
        let abilities = AbilityStore(dataRoot: dataRoot)
        var failures: [String] = []
        var moved: [(id: String, from: String, to: String)] = []
        var currentSeeds = 0, preparedAdmissions = 0
        do {
            guard let resources else {
                throw ToolFailureError("The app's resource directory is unavailable; bundled programs could not be installed.", effects: .none)
            }
            let bundled = AbilityStore(dataRoot: resources)
            let seeds = try AbilityStore.seedCatalog(resources: resources).sorted { $0.path < $1.path }.map { url in (url, Result { try AbilityStore.decode(
                url) }) }
            // Require a readable whole bundle before disabling untouched seeds.
            do {
                let shipped = try seeds.map { try $0.1.get().id }
                try fadeRetiredSeeds(abilities, shipped: Set(shipped))
            } catch { failures.append("retired seeds: \(error.localizedDescription)") }
            // Launch owns no enclosing turn or operation; admission and installation share this explicit operation.
            let invocation = ChatToolInvocation()
            let execution = AppActionExecution(invocation: invocation, deadlines: invocation.deadlines,
                turnWork: .init(toolInvocation: invocation))
            let host = AppToolExecutor.authoredProgramHost(dataRoot: dataRoot, jobStore: AgentJobStore(dataRoot: dataRoot), turn: nil, execution: execution) { _, _, _, _ in nil }
            let parts = Parts(root: dataRoot), programs = OwnedProgramStore(root: abilities.root)
            let admission = Parts.Invocation(host: host, execution: .init(turn: nil, surface: "launch", deadlines: execution.deadlines))
            for (url, decoded) in seeds {
                do {
                    let seed = try decoded.get()
                    guard try bundled.path(id: seed.id, pathExtension: seed.pathExtension) == url else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var bundle = seed.bodyDigest
                    defer { recordSeed(seed, bundle: bundle, source: url, abilities: abilities) }
                    let current = try abilities.read(id: seed.id, slot: .current)
                    if current == nil, try abilities.contains(id: seed.id) { continue }
                    let candidate: OwnedProgramStore.Candidate
                    if seed.kind == .part {
                        candidate = try await parts.seedCandidate(seed, invocation: admission)
                    } else {
                        let analysis = try await OwnedProgramRunner(dataRoot: dataRoot).analyze(seed.body)
                        candidate = try OwnedProgramStore.turnCandidate(seed, analysis: analysis)
                    }
                    bundle = candidate.digest
                    let unsealed = ["proof", "record", "candidate"]
                    let shippedUnsealed = current.map { !AbilityStore.isSeed($0) && $0.body == seed.body
                        && $0.metadata.filter { !unsealed.contains($0.key) } == seed.metadata.filter { !unsealed.contains($0.key) } } ?? false
                    if let current, !AbilityStore.isSeed(current), !shippedUnsealed,
                       try seed.kind != .part || !programs.samePart(current, as: candidate) {
                        try tellShippedBeside(current, shipped: seed, digest: candidate.digest, source: url, dataRoot: dataRoot)
                        continue
                    }
                    let kept: AbilityStore.File
                    if seed.kind == .part {
                        guard let admitted = try await parts.bundledSeed(seed, candidate: candidate, invocation: admission) else {
                            currentSeeds += 1
                            continue
                        }
                        kept = admitted
                    } else {
                        guard case .int(let version)? = seed.metadata["version"] else { throw CocoaError(.fileReadCorruptFile) }
                        if try programs.isCurrentSeed(candidate, version: version) {
                            currentSeeds += 1
                            continue
                        }
                        kept = try programs.bundledSeed(candidate, version: version,
                            key: await SwiftNativeManifestSigner(dataRoot: dataRoot).loadOrCreateSigningKey())
                    }
                    preparedAdmissions += 1
                    var followed: String?
                    let displaced = try abilities.installSeed(kept, turn: nil) { current in
                        if AbilityStore.isSeed(current) {
                            guard let digest = current.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"]?.stringValue else {
                                throw ToolFailureError("""
                                    Installed seed \(current.id) has no sealed candidate identity. Preserve its bytes and repair its authored source before \
                                    upgrading.
                                    """, effects: .none,
                                    code: "seed_identity_missing",
                                        instruction: "Read this ability and repair its missing sealed candidate through its authoring owner.",
                                        recovery: .inspect)
                            }
                            guard let key = try SwiftNativeManifestSigner(dataRoot: dataRoot).existingSigningKey() else {
                                throw ManifestSigningError.keyUnavailable("Installed seed authority is missing")
                            }
                            _ = try programs.proof(current, key: key)
                            followed = digest
                        }
                        if followed != nil, seed.kind == .turn, current.bodyDigest == kept.bodyDigest, current.part == kept.part,
                           current.metadata["version"] == kept.metadata["version"] { return true }
                        return try shippedUnsealed || seed.kind == .part && programs.samePart(current, as: candidate)
                    }
                    if displaced != nil, let followed { moved.append((seed.id, followed, candidate.digest)) }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        tellFollowedChanged(moved, dataRoot: dataRoot)
        AbilityFilesCheck.recordSeedInstallation(failures: failures, current: currentSeeds,
            prepared: preparedAdmissions, root: dataRoot)
        // Doctor's reading publishes on its own; launch never waits for it.
        if !failures.isEmpty {
            await retainLaunchWork {
                await DoctorReadout.recordReadings([await AbilityFilesCheck(root: dataRoot).run()], dataRoot: dataRoot)
            }
        }
    }

    private static func tellFollowedChanged(_ moved: [(id: String, from: String, to: String)], dataRoot: URL) {
        guard !moved.isEmpty else { return }
        let lines = moved.map { "\($0.id) \($0.from.prefix(12)) → \($0.to.prefix(12))" }.joined(separator: "; ")
        Attention.post(Happening(.body, subject: "parts", door: "stem", who: "self",
            words: "Parts I follow changed with the app: \(lines). Each earlier version stays as <id>.prev.",
            once: "shipped:" + moved.map { $0.id + ":" + $0.to }.joined(separator: ",")), dataRoot: dataRoot)
    }

    private static func tellShippedBeside(_ own: AbilityStore.File, shipped: AbilityStore.File, digest: String, source: URL, dataRoot: URL) throws {
        guard let description = shipped.record["description"]?.stringValue, !description.isEmpty else {
            throw ToolFailureError("Bundled program \(shipped.id) needs a description of what it changes in its record.", effects: .none)
        }
        let id = own.id
        Attention.post(Happening(.body, subject: "part:" + id, door: "stem", who: "self",
            words: """
                The shipped \(id) is at version \(digest.prefix(12)); yours is your own and stays as it is. \
                \(description) ability.read {id:"\(id)"} shows yours; read the shipped source beside it, \
                merge from it or leave it.
                """,
            once: "shipped:" + id + ":" + digest, shows: "Shipped source: " + source.path), dataRoot: dataRoot)
    }

    private static func recordSeed(_ seed: AbilityStore.File, bundle: String, source: URL, abilities: AbilityStore) {
        do {
            guard let installed = try abilities.read(id: seed.id, slot: .current) else {
                ModuleLog.app("[seeds] resource=%@ installed=missing bundle=%@; selection unavailable", source.lastPathComponent, bundle)
                return
            }
            let sealed = installed.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"]?.stringValue
            let state = AbilityStore.isSeed(installed) ? "follows" : installed.bodyDigest == seed.bodyDigest ? "hers" : "beside"
            ModuleLog.app("[seeds] resource=%@ installed=%@ bundle=%@ %@", source.lastPathComponent, AbilityStore.isSeed(installed) ? sealed ?? "unidentified" : installed.bodyDigest, bundle, state)
        } catch {
            ModuleLog.app("[seeds] resource=%@ installed=unavailable bundle=%@; %@", source.lastPathComponent, bundle, error.localizedDescription)
        }
    }

    // Disable only untouched unbundled seeds; edited or re-enabled parts belong to the agent.
    // A seed whose sealed version cannot be loaded stays as it is and is named; the others still fade.
    private static func fadeRetiredSeeds(_ abilities: AbilityStore, shipped: Set<String>) throws {
        try AbilityStore.withLock {
            let programs = OwnedProgramStore(root: abilities.root)
            var unloadable: [String] = []
            let retired = Set(try abilities.files(kind: .part, includeProposals: false).filter { file in
                guard AbilityStore.isSeed(file), !shipped.contains(file.id), case .object(let proof)? = file.metadata["proof"],
                      case .string(let digest)? = proof["candidate"] else { return false }
                do { _ = try programs.load(id: file.id, digest: digest) }
                catch {
                    unloadable.append("\(file.id): \(error.localizedDescription)")
                    return false
                }
                return true
            }.map(\.id))
            if !retired.isEmpty, case .array(var rows) = try abilities.registry(kind: .part) {
                var faded = false
                for index in rows.indices {
                    guard case .object(var row) = rows[index], case .string(let id)? = row["id"], retired.contains(id),
                          row["status"] != .string("disabled"), row["enabledAt"] == nil else { continue }
                    row["status"] = .string("disabled")
                    row["disabledReason"] = .string("No longer shipped with the app; restore it to use it again.")
                    rows[index] = .object(row); faded = true
                }
                if faded { try abilities.saveRegistry(.array(rows), kind: .part, turn: nil) }
            }
            if !unloadable.isEmpty {
                throw PersistenceCoreError.ioFailure("Not faded, their sealed version unloadable: " + unloadable.joined(separator: "; "))
            }
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

    @MainActor
    public static func reconcileSpeechPermissionAtLaunch(dataRoot: URL) {
        retainLaunchWork {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
        }
    }

    @MainActor
    public static func startResidentWorkAtLaunch(
        dataRoot: URL, embeddingDescriptorURL: URL?,
        storageUnavailable: @escaping @MainActor @Sendable () -> Void,
        resumeMacTurn: @escaping @Sendable (TurnCheckpoint, TurnContinuationRuntime) async throws -> Void,
        approvals: ApprovalExecution
    ) {
        guard !launchStopped, !residentsStarted, !Task.isCancelled,
              SwiftNativeMemoryV2.usesDefaultDataRoot(dataRoot) else { return }
        residentsStarted = true
        // Her body observes every door's turn even when no conversation window is mounted.
        OtherDoorTurns.shared.start(NativeAgentEngine.live.faceActs.chat)
        let engine = NativeAgentEngine.live
        retainLaunchWork { await engine.bodyField?.start(engine.dataRoot, chrome: engine.chrome) }
        retainLaunchWork { await NativeAgentEngine.live.connectors.observe() }
        retainLaunchWork { await NativeAgentEngine.live.observeDiagnosticsLivingStatus() }
        retainLaunchWork {
            await NativeAgentEngine.live.chrome.observeBrowserLaunches()
            guard !Task.isCancelled else { return }
            await NativeAgentEngine.live.chrome.reconcilePolicy(context: MacOperationContext(dataRoot: dataRoot))
        }
        retainLaunchWork { _ = await reconcileMemoryAtLaunch(dataRoot: dataRoot, storageUnavailable: storageUnavailable) }
        retainLaunchWork { await SwiftNativeMemoryIndexer.reconcileAtLaunch(dataRoot: dataRoot) }
        // Bring up owners independently so one blocked store cannot hold siblings or the native launch callback.
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
        // Deliver callbacks owed before relaunch without waiting for a task read.
        retainLaunchWork { await NativeAgentEngine.live.agents.tasks.redeliverOwedCallbacks() }
        // A job a relaunch left working resumes through its door or ends stopped, so none waits on a flight that is gone. Its doors are open first.
        retainLaunchWork {
            let jobs = engine.agentJobs
            await AgentJobs.resume(service: jobs, register: AppToolExecutor.jobRegistrar(dataRoot: jobs.dataRoot))
        }
        retainLaunchWork { await reconcileTranscriptsAtLaunch(dataRoot: dataRoot) }
        retainLaunchWork { _ = await ChatHistoryIndex.shared(dataRoot: dataRoot).absorbAll() }
        // Read the user’s login PATH at launch so later callers do not wait.
        retainLaunchWork { _ = AgentHostCommandLines.loginEnvironment }
        retainLaunchWork {
            guard !Task.isCancelled else { return }
            _ = await AgentDiscoverySession.shared.candidates(refresh: true, probe: false, dataRoot: dataRoot)
        }
        retainLaunchWork {
            guard !Task.isCancelled else { return }
            await startBackgroundWorkAtLaunch(
                engine: engine,
                makeLoops: {
                    _ = NativeAgentEngine.live
                    guard !Task.isCancelled else { return nil }
                    // The delegation runner owns contact observation lifecycle.
                    let loops = assembleAllLoops()
                    guard !Task.isCancelled else { return nil }
                    await retainLaunchWork { await NativeAgentEngine.live.mind?.bodyIsUp() }
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
                makeLLMClient: { makeSharedLLMClient(dataRoot: dataRoot) })
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
            } catch is CancellationError {
                // Quit cancelled a lock wait: a stop, not a broken approval store.
                return
            } catch {
                await RepairOwed.owe(dataRoot, id: "approval.reconcile", kind: .run,
                    operation: "approval.reconcile", owner: "Approval reconciliation",
                    words: error.localizedDescription,
                    lever: "Repair the approval store or reconciliation cursor, then restart to reconcile the retained decisions.").value
            }
            await retainLaunchWork {
                await MemoryApprovalTransactions.stageKindBackfillIfNeeded(dataRoot: dataRoot,
                    makeLLMClient: { makeSharedLLMClient(dataRoot: dataRoot) })
            }
            await retainLaunchWork {
                let remStaged = await stagePendingREMProposalsAtLaunch()
                OrganPulse.record("launch.rem_staging", found: remStaged, note: "\(remStaged) staged")
            }
        }
    }

    @MainActor
    public static func startDeviceSyncAtLaunch(
        forward: @escaping (BridgeMessage, ICloudPhoneRoute) async -> Bool,
        registerLoginItem: @MainActor () -> Void
    ) {
        guard !launchStopped, !Task.isCancelled else { return }
        NativeAgentEngine.liveDeviceSync.bridge.setup()
        NativeAgentEngine.liveDeviceSync.bridge.observeIncomingMessages(onMessage: forward)
        // Publish the pairing key only after establishing this Mac’s phone ownership; never overwrite another Mac’s key.
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
        // Superseded statements’ tombstones must not block their corrections.
        await SwiftNativeMemoryV2.shared.repairSupersededTombstones()
        // Admit trusted backlog under current keep rules.
        if let generator = await SwiftNativeMemoryV2.shared.bindUserMDGenerator(
            dataRoot: dataRoot,
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        ) {
            do {
                _ = try await generator.regenerate()
            } catch UserMDGeneratorError.onboardingIncomplete {
                // Onboarding owns the first write on blank installs.
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
                              note: """
                                  recovered \(report.sessionsRecovered), repaired \(report.staleRowsRepaired), corrupt \(report.corruptTranscripts) of \
                                  \(report.transcriptsExamined)
                                  """)
            if report.sessionsRecovered > 0 || report.corruptTranscripts > 0
                || report.staleRowsRepaired > 0 {
                logger.info(
                    """
                        Chat reconciliation: recovered=\(report.sessionsRecovered, privacy: .public) repaired=\(report.staleRowsRepaired, privacy: .public) \
                        corrupt=\(report.corruptTranscripts, privacy: .public) examined=\(report.transcriptsExamined, privacy: .public)
                        """
                )
            }
        } catch {
            logger.error("Chat reconciliation refused: \(String(describing: error), privacy: .public)")
        }
    }

    public static func reconcileConnectorCredentialsAtLaunch(dataRoot: URL) async {
        // Recover credential saves and check metadata before admitting ingress.
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
        engine: NativeAgentEngine,
        makeLoops: @Sendable () async -> [LoopRegistration]?,
        resume: @escaping @Sendable (TurnCheckpoint) async throws -> Void
    ) async {
        guard !Task.isCancelled else { return }
        // Start reply journals before resumed answers reach them; wire failure notices and launch Doctor reporting through that same start path.
        guard let loops = await makeLoops(), !Task.isCancelled else { return }
        await startBackgroundLoops(loops: loops)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard !launchStopped, !Task.isCancelled else { return }
            engine.abandonedTurns.arm(resume: resume)
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
            personName: { try NativeCognitionRuntime.resolveUserName(dataRoot: dataRoot) },
            reconcilePromiseCard: { entry, store in _ = try await AgentScreen.reconcileFiledCard(entry, store: store) }
        )
    }

    public static func startBackgroundLoops(loops: [LoopRegistration]) async {
        let manager = BackgroundLoopLifetimes.shared
        let dataRoot = PersistenceCore.defaultDataRoot()
        // Before setup finishes there is no agent: the scheduler does not start a pass that needs one.
        manager.admitAgentPasses { NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) }
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
            async let grants: Void = NativeAgentEngine.live.interactions.observeGrants()
            async let interactions: Void = InlineInteractionDelivery.observe(interactions: NativeAgentEngine.live.interactions)
            _ = await (desk, grants, interactions)
        }), !Task.isCancelled else { return }
        let config = DoctorReadout.readAutoDoctorConfig(dataRoot: dataRoot)
        if (config.enabled ?? true) && (config.runOnStartup ?? true) {
            await retainLaunchWork { await manager.runTickOnce(loopId: "doctor_auto_run") }
        }
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

    public struct QuitRestartWake: NotificationCenter.MainActorMessage {
        public typealias Subject = NativeAgentEngine
        public init() {}
    }

    public static func waitForInFlightTurnsBeforeQuit(
        _ runs: Set<String>, isRestarting: @escaping @Sendable () -> Bool
    ) async {
        // Arm before reading so racing completion or restart stays buffered.
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [],
            notifications: [ChatCancelFlag.InFlightDidChange.name, QuitRestartWake.name])
        var iterator = events.makeAsyncIterator()
        while !Task.isCancelled,
              !NativeAgentEngine.live.turns.inFlightRunIDs().isDisjoint(with: runs), !isRestarting() {
            guard await iterator.next() != nil else { return }
        }
        let left = NativeAgentEngine.live.turns.inFlightRunIDs().intersection(runs).count
        ModuleLog.app("[quit] %@", left == 0 ? "turns finished" : "\(left) turn(s) remain before settlement")
    }

    // Close, join and save share one retained settlement.
    @MainActor private static var quitSettlement: Task<NativeCognitionSleepOutcome?, Never>?

    /// Quit callers join the same retained operation.
    @MainActor
    public static func beginQuitSleep(after producers: Task<Void, Never>,
                                      retireBrowser: @escaping @MainActor @Sendable () -> Void) -> Task<NativeCognitionSleepOutcome?, Never> {
        if let quitSettlement { return quitSettlement }
        let task = Task.detached { () -> NativeCognitionSleepOutcome? in
            await producers.value
            ModuleLog.app("[quit] drained producers")
            // Arm before the registry read so admitted producers’ final completions cannot race it.
            let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [],
                notifications: [ChatCancelFlag.InFlightDidChange.name])
            // Join every admitted turn before the final snapshot.
            var iterator = events.makeAsyncIterator()
            while !NativeAgentEngine.live.turns.inFlightRunIDs().isEmpty {
                guard await iterator.next() != nil else {
                    ModuleLog.app("[quit] admitted-turn observation ended before completion")
                    return nil
                }
            }
            ModuleLog.app("[quit] drained admitted turns")
            await quitDrained("tool dispatch settlement") { await SwiftNativeTurnEngine.joinDispatchSettlements() }
            await quitDrained("Mac rooms") { await NativeAgentEngine.live.bodyField?.closeRooms() }
            await quitDrained("memory promoter") { await AdaptiveMemoryPromoter.shared.sleep() }
            await quitDrained("contact reply writes") { await AgentConversationStore.joinPendingReplyWrites() }
            await quitDrained("attention posts") { await Attention.joinPendingPosts() }
            await quitDrained("session usage receipts") { await LLMCallTraceRecorder.joinPendingUsageReceipts() }
            await quitDrained("dream theme extractions") { await NativeCognitionRuntime.joinPendingDreamThemeExtractions() }
            await TurnTraceBus.shared.drainForProcessExit()
            let slept = await NativeAgentEngine.live.mind?.end() ?? .noMind
            ModuleLog.app("[quit] drained mind")
            await quitDrained("chat history index") { await ChatHistoryIndex.joinPendingAbsorptions() }
            await quitDrained("browser") { await retireBrowser() }
            return slept
        }
        quitSettlement = task
        return task
    }

    public static func sleepMind(after settlement: Task<NativeCognitionSleepOutcome?, Never>) async -> String {
        await settlement.value?.summary ?? "did not settle: admitted-turn observation unavailable"
    }

    /// Close producer admission when quit hold begins; keep dependencies alive until admitted runs settle.
    @MainActor
    public static func beginQuitProducerSettlement(appLaunch: Task<Void, Never>?, appObservers: [Task<Void, Never>] = []) -> Task<Void, Never> {
        stopLaunchWork()
        let launch = Array(launchTasks.values)
        let dataRoot = NativeAgentEngine.live.dataRoot
        let otherDoors = OtherDoorTurns.shared.stop()
        let make = NativeAgentEngine.live.make.shutdown()
        let bots = NativeAgentEngine.live.bots
        let helpers = Task.detached { await bots.shutdown() }
        let activity = NativeAgentEngine.live.activityWatch.makeTerminationDrain()
        let attention = NativeAgentEngine.live.ports.backgroundWork.attention
        let notifications = Task.detached { await attention.shutdown() }
        let cognition = NativeAgentEngine.live.mind?.beginClosingAdmission()
        NativeAgentEngine.live.abandonedTurns.disarm()
        AgentMemo.shared.shutdown()
        AgentOpened.shared.shutdown()
        NativeAgentNotifications.shutdown()
        return Task.detached {
            await quitDrained("clock deliveries") { await OneClock.at(dataRoot).finishScheduledDeliveries() }
            async let body: Void = quitDrained("body field") { await NativeAgentEngine.live.bodyField?.stop() }
            async let wakes: Void = quitDrained("part wake") { await EnginePartWake.shared.stop() }
            async let loops: Void = quitDrained("background loops") { await BackgroundLoopLifetimes.shared.shutdown() }
            async let helperRuns: Void = quitDrained("helper scheduler") { await helpers.value }
            async let attentionRouter: Void = quitDrained("attention router") { await notifications.value }
            async let cognitionAdmission: Void = quitDrained("cognition admission") { await cognition?.value }
            await quitDrained("launch work (\(launch.count))") { for task in launch { await task.value } }
            await quitDrained("app launch") { await appLaunch?.value }
            await quitDrained("app observers (\(appObservers.count))") { for observer in appObservers { await observer.value } }
            await quitDrained("other doors' turns") { await otherDoors.value }
            await quitDrained("make") { await make.value }
            await quitDrained("activity watch") { await activity.value }
            _ = await (body, wakes, loops, helperRuns, attentionRouter, cognitionAdmission)
        }
    }

    /// Each piece quit waits on names itself when it is seen done, so a quit that never answers names the piece still running.
    static func quitDrained(_ name: String, _ piece: () async -> Void) async {
        await piece()
        ModuleLog.app("[quit] drained %@", name)
    }

    /// The held quit retires resident dependencies after the sleep settled and before it answers the termination, so no clock bounds it:
    /// each step ends when its own work is seen done (cancelled tasks joined, writes returned) or its processes are seen exited.
    public static func retireResidentWork(after settlement: Task<NativeCognitionSleepOutcome?, Never>,
                                          shutdownSenses: @escaping @Sendable () async -> Void) async {
        // An unavailable barrier keeps dependencies until exit rather than retiring them under live turns.
        guard await settlement.value != nil else {
            ModuleLog.app("[quit] dependencies retained: admitted-turn observation unavailable")
            return
        }
        async let chrome: Void = NativeAgentEngine.live.chrome.stop()
        async let chromeNews: Void = NativeChromeNews.shared.shutdown()
        async let senses: Void = shutdownSenses()
        async let programs: Void = OwnedProgramRunner.endResidents()
        async let acp: Void = SwiftToolDispatcher.closeACPConnections()
        async let context: Void = NativeAgentEngine.live.contextFlow.stop()
        async let embeddings: Void = SwiftNativeMemoryV2.shared.shutdownEmbeddingConvergence()
        async let promoter: Void = AdaptiveMemoryPromoter.shared.shutdown()
        async let projections: Void = SwiftNativeMemoryV2.shared.shutdownProjections()
        async let trace: Void = NativeAgentEngine.live.trace.stop()
        _ = await (chrome, chromeNews, senses, programs, acp, context, embeddings, promoter, projections, trace)
        await quitDrained("post-retirement attention posts") { await Attention.joinPendingPosts() }
        // Retire inventory only after every producer, turn, sense and program has settled.
        await MacAppIndex.shared.shutdown()
    }

    @MainActor
    public static func prepareContextForSleep() {
        retainLaunchWork { await NativeAgentEngine.live.contextFlow.prepareForSleep() }
    }

    @MainActor
    public static func reconcileContextAfterWake() {
        retainLaunchWork {
            await NativeAgentEngine.live.contextFlow.reconcileAfterWake()
            await NativeAgentEngine.liveCognition?.reanchorDeadlinesAfterWake()
        }
    }
}

public final class WakeResetThrottle: Sendable {
    private let lastFire = Mutex(Date.distantPast)

    public init() {}

    public func shouldFire(now: Date = Date(), minimumInterval: TimeInterval = 30) -> Bool {
        lastFire.withLock { lastFire in
            // Treat backward clock correction as a new epoch so an unreachable future stamp cannot throttle recovery forever.
            if now < lastFire {
                lastFire = now
                return true
            }
            guard now.timeIntervalSince(lastFire) >= minimumInterval else { return false }
            lastFire = now
            return true
        }
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
