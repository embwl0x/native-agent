import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import WorkshopExecution
import NativeAgentShared
// Blueprint: | `NativeContextFlowRuntime.swift` | `NativeContextFlowRuntime` actor; ordered, joined lifecycle transitions; stop drains retained picker, observation and embedding bodies; picker publication checks, turn preparation and memory provenance |

private struct NativeContextEmbeddingProvider: ContextMarkdownEmbeddingProvider {
    let memory: SwiftNativeMemoryV2
    let modelFingerprint: String

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let batch = try await memory.embedForDerivedContextWithEpoch(texts)
        guard batch.epoch.rawValue == modelFingerprint else {
            throw MemoryV2Error.underlying("Context embedding provider epoch changed during compilation")
        }
        return batch.vectors
    }
}

private struct NativeContextMarkdownCompiler: ContextMarkdownCompiling {
    let memory: SwiftNativeMemoryV2

    func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource?,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        guard let fingerprint = await memory.embeddingEpoch()?.rawValue else {
            throw MemoryV2Error.storageUnavailable
        }
        let provider = NativeContextEmbeddingProvider(memory: memory, modelFingerprint: fingerprint)
        return try await ContextMarkdownCompiler(embeddingProvider: provider).compile(
            sourceData: sourceData,
            descriptor: descriptor,
            previous: previous,
            updatedAt: updatedAt
        )
    }
}

public actor NativeContextFlowRuntime: ContextTurnPreparing {
    let dataRoot: URL
    var coordinator: ContextPreparation?
    var memoryRuntime: SwiftNativeMemoryV2?
    private let memoryPressureObserver: DispatchContextMemoryPressureObserver?
    /// Payload-free Desk/Workshop invalidations make the coordinator reread canonical stores.
    private var residentWorkObservationTask: Task<Void, Never>?
    private var terminalResidentWorkRecordPaths: Set<String> = []
    enum LifecycleOperation { case start, stop, reload }
    /// Reserve before suspension: identical transitions join, others follow;
    /// reload owns teardown/replacement, and awaiting lends the caller's priority.
    var lifecycle: (
        id: UUID, operation: LifecycleOperation,
        configuration: NativeContextFlowConfiguration?, task: Task<Void, Never>
    )?
    private var personaPickerReconcile: (id: UUID, task: Task<Void, Never>)?
    private var personaPickerRequestRevision: UInt64 = 0
    var semanticQueryCache: [String: ContextQueryEmbeddingValue] = [:]
    var semanticQueryCacheOrder: [String] = []
    static let maximumConcurrentSemanticQueries = 8
    static let retiredSemanticQueryCause = "memory search stopped before the query embedded"
    var semanticQueryTickets: [String: ContextQueryEmbeddingTicket] = [:]
    /// Stop settles tickets immediately; retired predictions retain their slots until exit.
    var semanticQueryTasks: [UUID: Task<Void, Never>] = [:]
    var semanticQueryEpoch: UInt64 = 0
    private var startupFailedClosed = false
    /// The next turn retries startup and reports this cause if it still cannot start.
    private var startupFailure: String?
    /// Published-generation provenance resolves selected memory atoms to record IDs.
    private let memoryProvenanceIndex: MemoryAtomRecordIndex

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.memoryPressureObserver = dataRoot.standardizedFileURL
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? DispatchContextMemoryPressureObserver()
            : nil
        self.memoryProvenanceIndex = MemoryAtomRecordIndex()
    }

    private var usesLiveAppBody: Bool {
        dataRoot == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    public func start() async {
        await transition(.start)
    }

    private func transition(_ operation: LifecycleOperation) async {
        let configuration = operation == .reload ? resolvedConfiguration() : nil
        if let lifecycle, lifecycle.operation == operation, lifecycle.configuration == configuration {
            return await lifecycle.task.value
        }
        if lifecycle == nil, operation == .start, coordinator != nil { return }
        let predecessor = lifecycle?.task
        let id = UUID()
        let task = Task {
            await predecessor?.value
            if operation != .start { await performStop() }
            if operation != .stop, coordinator == nil {
                await performStartup(configuration: configuration ?? resolvedConfiguration())
            }
            // A queued successor owns the slot as soon as it is reserved.
            if lifecycle?.id == id { lifecycle = nil }
        }
        lifecycle = (id, operation, configuration, task)
        await task.value
    }

    private func performStartup(configuration: NativeContextFlowConfiguration) async {
        startupFailedClosed = false
        startupFailure = nil
        guard configuration.mode != .off else {
            nativeLog("[context-flow] disabled until onboarding or explicit enablement")
            return
        }

        do {
            let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            guard await memory.embeddingEpoch() != nil else {
                throw MemoryV2Error.storageUnavailable
            }
            let store = try ContextSQLiteStore(dataRoot: dataRoot)
            let arena = try ContextArena(budget: configuration.budget)
            let registry = try ContextSourceRegistry()
            let provider = PersonaContextFlowProvider(dataRoot: dataRoot)
            let coordinator = ContextPreparation(
                mode: configuration.mode,
                store: store,
                arena: arena,
                registry: registry,
                compiler: NativeContextMarkdownCompiler(memory: memory),
                mirrorProvider: provider,
                compiledProjectionProviders: [MemoryContext(
                    memory: memory,
                    provenanceIndex: memoryProvenanceIndex,
                    dataRoot: dataRoot
                ),
                ResidentWorkContext(dataRoot: dataRoot),
                KnowledgeGraphContext(dataRoot: dataRoot),
                StudioContext(dataRoot: dataRoot),
                UnreadSenseNews()]
            )
            memoryRuntime = memory
            self.coordinator = coordinator
            await startResidentWorkObservationIfNeeded()
            if usesLiveAppBody {
                // Context Flow subscribes without owning the app-lifetime pin sink.
                await ContextFlowInvalidationRelay.shared.set(coordinator)
            }
            installMemoryPressureSource()
            await coordinator.start()
            let health = await coordinator.health()
            nativeLog(
                "[context-flow] started mode=%@ generation=%lld sources=%d arena_bytes=%d",
                configuration.mode.rawValue,
                health.activeArenaGenerationID ?? 0,
                health.registeredSourceCount,
                health.arenaMetrics.currentLogicalBytes
            )
        } catch {
            if usesLiveAppBody {
                // Keep the app-lifetime pin sink installed after a failed startup.
                await ContextFlowInvalidationRelay.shared.set(nil)
            }
            coordinator = nil
            memoryRuntime = nil
            startupFailedClosed = true
            startupFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await memoryPressureObserver?.stop()
            residentWorkObservationTask?.cancel()
            await residentWorkObservationTask?.value
            residentWorkObservationTask = nil
            nativeLog("[context-flow] start failed closed: %@", String(describing: error))
        }
    }

    public func stop() async {
        await transition(.stop)
    }

    private func performStop() async {
        semanticQueryEpoch &+= 1
        let picker = personaPickerReconcile?.task
        picker?.cancel()
        let observation = residentWorkObservationTask
        observation?.cancel()
        let queries = Array(semanticQueryTasks.values)
        queries.forEach { $0.cancel() }
        semanticQueryTickets.values.forEach { $0.fail(Self.retiredSemanticQueryCause) }
        semanticQueryTickets.removeAll()
        semanticQueryCache.removeAll()
        semanticQueryCacheOrder.removeAll()
        // Close coordinator admission while a compilation-blocked pressure source drains.
        async let pressureStop: Void? = memoryPressureObserver?.stop()
        if usesLiveAppBody {
            await ContextFlowInvalidationRelay.shared.set(nil)
        }
        await coordinator?.stop()
        _ = await pressureStop
        await picker?.value
        await observation?.value
        // Ticket failure ends its wait; retain the body's slot and memory owner until exit.
        for query in queries { await query.value }
        personaPickerReconcile = nil
        residentWorkObservationTask = nil
        coordinator = nil
        memoryRuntime = nil
    }

    public func reloadConfiguration() async {
        await transition(.reload)
    }

    /// Persist and hot-apply the mode; start still forces off before public onboarding.
    @discardableResult
    public func setMode(_ mode: ContextFlowMode) async -> NativeContextFlowModeStatus {
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: NativeContextFlowConfiguration.modeDefaultsKey
        )
        await reloadConfiguration()
        return await modeStatus()
    }

    public func modeStatus() async -> NativeContextFlowModeStatus {
        return NativeContextFlowModeStatus(effectiveMode: await contextFlowMode())
    }

    public func prepareForSleep() async {
        guard let coordinator else { return }
        _ = try? await coordinator.applyMemoryPressure(.warning)
    }

    public func reconcileAfterWake() async {
        if coordinator == nil {
            await start()
        }
        await coordinator?.reconcileAfterWake()
    }

    /// Rebuild on picker changes; turn preparation requests without waiting and rejects stale kernels.
    public func personaPickerDidChange() async {
        await requestPersonaPickerReconcile()?.value
    }

    @discardableResult
    private func requestPersonaPickerReconcile() -> Task<Void, Never>? {
        guard lifecycle == nil, coordinator != nil else { return nil }
        personaPickerRequestRevision &+= 1
        if let personaPickerReconcile { return personaPickerReconcile.task }
        let id = UUID()
        let epoch = semanticQueryEpoch
        let task = Task {
            var revision: UInt64
            repeat {
                revision = personaPickerRequestRevision
                await reconcilePersonaPickerIfNeeded(epoch: epoch)
                // Only a new picker/turn request repeats the pass; build failure never does.
            } while epoch == semanticQueryEpoch && !Task.isCancelled
                && revision != personaPickerRequestRevision
            if personaPickerReconcile?.id == id { personaPickerReconcile = nil }
        }
        personaPickerReconcile = (id, task)
        return task
    }

    private func normalizedPersonaOverride() -> String? {
        let value = PersonaSelection.current()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func reconcilePersonaPickerIfNeeded(epoch: UInt64) async {
        guard epoch == semanticQueryEpoch, !Task.isCancelled, let coordinator else { return }
        // Only the published kernel acknowledges selection; sampled preferences can lose ABA changes.
        let lease = try? await coordinator.acquireSnapshot()
        let chatKernels = lease?.snapshot.requiredDocumentMirrors.compactMap {
            $0.kernel(for: ContextSurfaceVariant(rawValue: ContextSurface.chat.rawValue))
        } ?? []
        let selectionPublished = chatKernels.count == 1
            && chatKernels[0].requestedPersonaOverride == normalizedPersonaOverride()
        lease?.release()
        guard epoch == semanticQueryEpoch, self.coordinator === coordinator,
              !Task.isCancelled else { return }
        // Missing publication is not an acknowledged default/nil selection.
        guard !selectionPublished else { return }
        _ = await coordinator.reconcileSourceChanges([DerivedSourceChange(
            namespace: "persona-picker",
            stableID: "chat",
            operation: .reconcile,
            reason: "chat_persona_picker_changed"
        )])
        // Failure keeps the old receipt; the next turn or picker edge retries.
    }

    /// Health reads never wait for startup; an in-flight transition answers not-started.
    public func health() async -> ContextFlowCoordinatorHealth? {
        guard lifecycle == nil else { return nil }
        return await coordinator?.health()
    }

    /// An intentionally disabled runtime is healthy; an unavailable health read is not.
    public func observatoryHealthState() async -> ContextFlowObservatoryHealthState {
        await lifecycle?.task.value
        if let coordinator {
            return .health(await coordinator.health())
        }
        if startupFailedClosed { return .unavailable }
        return resolvedConfiguration().mode == .off ? .off : .unavailable
    }

    /// During a lifecycle transition, report the configured mode without waiting.
    public func contextFlowMode() async -> ContextFlowMode {
        if lifecycle == nil, let coordinator { return await coordinator.mode }
        return resolvedConfiguration().mode
    }

    func resolvedConfiguration() -> NativeContextFlowConfiguration {
        NativeContextFlowConfiguration.resolve(dataRoot: dataRoot)
    }

    public func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        await start()
        // The person's selection is applied by the build; the turn never
        // waits on it, and an unpublished selection is the persona receipt below.
        requestPersonaPickerReconcile()
        guard let coordinator else {
            if let startupFailure { throw NativeContextFlowStartupError(detail: startupFailure) }
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        let prepared = try await coordinator.prepareTurn(request)
        guard request.surface != .chat
            || prepared.kernel.requestedPersonaOverride == normalizedPersonaOverride() else {
            throw ContextTurnPreparationError.personaSelectionUnavailable
        }
        attachMemoryProvenance(to: prepared, surface: request.surface.rawValue)
        return prepared
    }

    private func attachMemoryProvenance(
        to prepared: ContextPreparedTurn,
        surface: String
    ) {
        // Resolve provenance from this exact instance's leased generation.
        let resolution = NativeContextMemoryProvenance.attach(to: prepared)
        if resolution.unresolvedMemoryAtomCount > 0 {
            // Missing locator identity leaves use unattributed; log counts without payloads.
            nativeLog(
                "[context-flow] memory provenance MISS: resolved %d of %d packet memory atoms, index size %d",
                resolution.resolvedMemoryAtomCount,
                resolution.requestedMemoryAtomCount,
                memoryProvenanceIndex.count
            )
            // Bind the payload-free miss receipt to the exact turn for memory activation diagnostics.
            TurnTraceBus.fireFromContext(
                kind: "context.memory_provenance_miss",
                surface: surface,
                payload: .object([
                    "schema": .string("context.memory_provenance_miss.v1"),
                    "requestedMemoryAtomCount": .int(Int64(resolution.requestedMemoryAtomCount)),
                    "resolvedMemoryAtomCount": .int(Int64(resolution.resolvedMemoryAtomCount)),
                    "unresolvedMemoryAtomCount": .int(Int64(resolution.unresolvedMemoryAtomCount)),
                    "provenanceIndexCount": .int(Int64(memoryProvenanceIndex.count)),
                ])
            )
        }
    }

    private func installMemoryPressureSource() {
        memoryPressureObserver?.start { [weak self] pressure in
            await self?.applyObservedMemoryPressure(pressure)
        }
    }

    private func applyObservedMemoryPressure(_ pressure: ContextArenaPressure) async {
        guard lifecycle == nil, let coordinator else { return }
        _ = try? await coordinator.applyMemoryPressure(pressure)
    }

    /// Value-only classification runs on the memory-pressure queue, outside actor isolation.
    nonisolated static func memoryPressureLevel(
        hasCritical: Bool,
        hasWarning: Bool
    ) -> ContextArenaPressure {
        if hasCritical { return .critical }
        if hasWarning { return .warning }
        return .normal
    }

    /// Arm before projection replay; re-arm every edge before reconciliation to preserve writes.
    private func startResidentWorkObservationIfNeeded() async {
        guard residentWorkObservationTask == nil else { return }
        let epoch = semanticQueryEpoch
        let observation = makeResidentWorkObservation()
        await observation.waitUntilArmed()
        guard epoch == semanticQueryEpoch, coordinator != nil,
              !Task.isCancelled else { observation.cancel(); return }
        residentWorkObservationTask = Task { [weak self] in
            guard let self else { observation.cancel(); return }
            await self.observeResidentWorkChanges(observation, epoch: epoch)
        }
    }

    private func observeResidentWorkChanges(_ initial: FileChangeEvents, epoch: UInt64) async {
        var observation = initial
        defer { observation.cancel() }
        while !Task.isCancelled {
            let changed = await waitForResidentWorkChange(observation)
            observation.cancel()
            guard changed, epoch == semanticQueryEpoch, !Task.isCancelled else { return }

            // Re-arm before projection I/O suspends so related canonical writes stay buffered.
            observation = makeResidentWorkObservation()
            await observation.waitUntilArmed()
            guard epoch == semanticQueryEpoch, !Task.isCancelled, let coordinator else { return }
            await coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "resident-work",
                stableID: "canonical",
                operation: .reconcile,
                reason: "resident_work_file_changed"
            ))
        }
    }

    private func waitForResidentWorkChange(_ observation: FileChangeEvents) async -> Bool {
        await withTaskCancellationHandler {
            for await _ in observation.stream {
                return !Task.isCancelled
            }
            return false
        } onCancel: {
            observation.cancel()
        }
    }

    private func residentWorkObservationPaths() -> [URL] {
        let deskOps = dataRoot
            .appendingPathComponent("desk", isDirectory: true)
            .appendingPathComponent("desk_ops.jsonl")
        let executionRoot = dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent(
            "executions",
            isDirectory: true
        )
        // Exact paths avoid duplicate wakes; missing targets watch their nearest existing parent.
        var paths = [deskOps, executionRoot]
        var discoveredRecordPaths: Set<String> = []
        if let directories = try? FileManager.default.contentsOfDirectory(
            at: executionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in directories {
                let isDirectory = (try? directory.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) ?? false
                if isDirectory {
                    // Watch the canonical record, or its directory until first creation.
                    let record = ExecutionRecordFile.canonicalPath(in: directory)
                    discoveredRecordPaths.insert(record.path)
                    if terminalResidentWorkRecordPaths.contains(record.path) {
                        continue
                    }
                    if Self.shouldObserveResidentWorkExecutionRecord(at: record) {
                        paths.append(record)
                    } else {
                        terminalResidentWorkRecordPaths.insert(record.path)
                    }
                }
            }
        }
        terminalResidentWorkRecordPaths.formIntersection(discoveredRecordPaths)
        return paths
    }

    /// Terminal records are immutable after the locked status/verification write.
    /// Keep missing, malformed and active records observed; the root discovers new directories.
    nonisolated static func shouldObserveResidentWorkExecutionRecord(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else {
            return true
        }
        return !WorkshopExecutionRecord.isTerminal(status)
    }

    private func makeResidentWorkObservation() -> FileChangeEvents {
        FileChangeEvents(paths: residentWorkObservationPaths(), emitInitial: false)
    }
}

extension NativeContextFlowRuntime {
    /// Resolve the projection's actual atom, including correction records.
    public nonisolated func memoryRecordAtomID(forRecordID recordID: String) -> ContextAtomID? {
        memoryProvenanceIndex.atomID(forRecordID: recordID)
    }
}
