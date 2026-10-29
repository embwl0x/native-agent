import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import TrustCenter
import CryptoKit
import GRDB
import PersonaEngine
// Blueprint: | `ContextPreparation.swift` | One ContextPreparation actor and state owner; lifecycle, health, compile/publication admission and cancellation; stop invalidates candidates and drains entered publication |

public enum ContextFlowMode: String, Codable, CaseIterable, Sendable {
    case off
    case active
}

public protocol ContextRequiredDocumentMirrorProviding: Sendable {
    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror]
    func refreshContextSources(in registry: ContextSourceRegistry) async throws
}

public protocol ContextMarkdownCompiling: Sendable {
    func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource?,
        updatedAt: Date
    ) async throws -> ContextCompiledSource
}

extension ContextMarkdownCompiler: ContextMarkdownCompiling {}

public struct ContextFlowCoordinatorHealth: Sendable, Equatable {
    public let mode: ContextFlowMode
    public let started: Bool
    public let activeStoreGenerationID: Int64?
    public let activeArenaGenerationID: Int64?
    public let registeredSourceCount: Int
    public let degradedSourceCount: Int
    public let arenaMetrics: ContextArenaMetrics
    /// Bounded rebuildable feedback retained across a coordinator restart.
    /// This health gauge never grants authority.
    public let feedbackEventCount: Int
    /// Identity of the newest retained advisory event, for restart/cap
    /// observability without exposing event payloads through every turn.
    public let newestFeedbackEventID: String?
    public let lastReconciledAt: Date?
    public let lastError: String?

    public init(
        mode: ContextFlowMode,
        started: Bool,
        activeStoreGenerationID: Int64?,
        activeArenaGenerationID: Int64?,
        registeredSourceCount: Int,
        degradedSourceCount: Int,
        arenaMetrics: ContextArenaMetrics,
        feedbackEventCount: Int = 0,
        newestFeedbackEventID: String? = nil,
        lastReconciledAt: Date?,
        lastError: String?
    ) {
        self.mode = mode
        self.started = started
        self.activeStoreGenerationID = activeStoreGenerationID
        self.activeArenaGenerationID = activeArenaGenerationID
        self.registeredSourceCount = registeredSourceCount
        self.degradedSourceCount = degradedSourceCount
        self.arenaMetrics = arenaMetrics
        self.feedbackEventCount = feedbackEventCount
        self.newestFeedbackEventID = newestFeedbackEventID
        self.lastReconciledAt = lastReconciledAt
        self.lastError = lastError
    }
}

public enum ContextFlowCoordinatorError: Error, Equatable, Sendable {
    case activeGenerationUnavailable
    case arenaPublicationFailed(String)
    case duplicateProjectedSource(ContextSourceID)
}

/// Resident event-driven compiler and RAM publication coordinator.
public actor ContextPreparation: DerivedStateInvalidationSink {
    public let mode: ContextFlowMode
    public let store: ContextSQLiteStore
    public let arena: ContextArena
    public let registry: ContextSourceRegistry

    let compiler: any ContextMarkdownCompiling
    let selector: ContextSelector
    let mirrorProvider: any ContextRequiredDocumentMirrorProviding
    let compiledProjectionProviders: [any ContextCompiledProjectionProvider]
    var monitor: ContextSourceMonitor?
    private var coalescer: ContextSourceEventCoalescer?
    var started = false
    var lastReconciledAt: Date?
    var lastError: String?
    // Prune after successful commits, bounded by the maintenance interval.
    var lastPruneAt: Date?
    let pruneInterval: TimeInterval = 6 * 3_600
    /// Vacuum reclaims freed pages at most daily, only after pruning deletes rows.
    var lastVacuumAt: Date?
    let vacuumInterval: TimeInterval = 24 * 3_600
    var activeStoredGeneration: ContextStoredGeneration?
    var activeCompiledSources: [ContextSourceID: ContextCompiledSource] = [:]
    let feedbackReducer = ContextFeedbackReducer()
    var feedbackEvents: [ContextFeedbackEvent] = []
    var feedbackOrdinal: UInt64 = 0
    /// The last feedback that applied; a failed update never replaces it.
    var publishedFeedback: ContextFeedbackSnapshot?
    var cachedFeedback: (
        generationID: Int64, feedbackOrdinal: UInt64, timeBucket: Int64,
        snapshot: ContextFeedbackSnapshot
    )?
    // Newer batches include every unacknowledged request. Compilation may
    // overlap, but only the freshest batch can enter the publication gate.
    var nextReconciliationRequestID: UInt64 = 0
    var pendingRegistrations: [ContextSourceID: PendingRegistration] = [:]
    var pendingProjectionReconciliationRequestIDs: [String: UInt64] = [:]
    var pendingReconciliationReason = "source_change"
    private var publicationInProgress = false
    private var publicationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Stop drains an entered publisher even if its own caller is cancelled.
    /// Admission waiters, in contrast, leave on cancellation or stop.
    private var publicationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    var reconciliationClosed = false
    var lifecycleID: UInt64 = 0
    /// One compile at a time. A request arriving during one waits, and only
    /// the newest waiter compiles: an older one's commit would be refused.
    var compileInProgress = false
    var compileWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Housekeeping rebuilds a turn requested or launch started; no turn awaits it.
    private var backgroundReconciliation: Task<Void, Never>?
    var degradedSourceIDs: Set<ContextSourceID> = []
    /// Cache only immutable generation derivations; keep feedback and live effects outside.
    var generationDerivedCache: [GenerationDerivedCacheKey: GenerationDerivedTurnState] = [:]
    /// Error-level diagnostic sink for context health and vocabulary drift.
    let diagnostics: @Sendable (String) -> Void

    public init(
        mode: ContextFlowMode = .active,
        store: ContextSQLiteStore,
        arena: ContextArena,
        registry: ContextSourceRegistry,
        compiler: any ContextMarkdownCompiling,
        mirrorProvider: any ContextRequiredDocumentMirrorProviding,
        compiledProjectionProviders: [any ContextCompiledProjectionProvider] = [],
        selector: ContextSelector = ContextSelector(),
        diagnostics: @escaping @Sendable (String) -> Void = { nativeLog("%@", $0) }
    ) {
        self.diagnostics = diagnostics
        self.mode = mode
        self.store = store
        self.arena = arena
        self.registry = registry
        self.compiler = compiler
        self.mirrorProvider = mirrorProvider
        self.compiledProjectionProviders = compiledProjectionProviders
        self.selector = selector
    }

    public func start() async {
        guard !started else { return }
        started = true
        reconciliationClosed = false
        lifecycleID &+= 1
        let lifecycleID = self.lifecycleID
        guard mode != .off else { return }

        let coalescer = ContextSourceEventCoalescer { [weak self] directories in
            guard await self?.isCurrent(lifecycleID) == true else { return }
            await self?.reconcile(dirtyDirectories: directories)
        }
        self.coalescer = coalescer
        let monitor = ContextSourceMonitor { [weak self] directory in
            await self?.observe(directory, lifecycleID: lifecycleID)
        }
        self.monitor = monitor

        // Turns read the published generation and never wait for launch housekeeping.
        do {
            if let published = try await store.loadActiveGeneration() {
                guard isCurrent(lifecycleID) else { return }
                guard await beginPublication(for: nextReconciliationRequestID) else { return }
                defer { finishPublication() }
                try await activate(published)
            }
        } catch {
            guard isCurrent(lifecycleID) else { return }
            lastError = "the published context generation could not be reopened: \(error)"
        }
        guard isCurrent(lifecycleID) else { return }
        reconcileInBackground(reason: "launch")
        await restoreFeedbackEvents()
    }

    func reconcileInBackground(reason: String) {
        guard !reconciliationClosed, backgroundReconciliation == nil else { return }
        let lifecycleID = self.lifecycleID
        backgroundReconciliation = Task {
            await reconcileAll(reason: reason)
            guard isCurrent(lifecycleID) else { return }
            await refreshWatchedDirectories()
            if isCurrent(lifecycleID) { backgroundReconciliation = nil }
        }
    }

    public func stop() async {
        // Close admission and invalidate compiled candidates before suspending.
        // A publisher already inside the gate may finish, but replacement must
        // not start until its durable and resident publications have drained.
        reconciliationClosed = true
        lifecycleID &+= 1
        nextReconciliationRequestID &+= 1
        started = false
        resumeCompileWaiters()
        resumePublicationWaiters()
        let background = backgroundReconciliation
        background?.cancel()
        // Passive watches close before joining any entered reconciliation.
        await monitor?.stop()
        await coalescer?.cancel()
        await background?.value
        backgroundReconciliation = nil
        if publicationInProgress {
            await withCheckedContinuation { publicationDrainWaiters.append($0) }
        }
        coalescer = nil
        monitor = nil
        pendingRegistrations.removeAll()
        pendingProjectionReconciliationRequestIDs.removeAll()
        activeStoredGeneration = nil
        activeCompiledSources.removeAll()
        cachedFeedback = nil
        invalidateGenerationDerivedCache()
    }

    public func reconcileAfterWake() async {
        guard !reconciliationClosed, mode != .off else { return }
        let lifecycleID = self.lifecycleID
        _ = try? arena.applyMemoryPressure(.normal)
        await reconcileAll(reason: "wake")
        guard isCurrent(lifecycleID) else { return }
        await refreshWatchedDirectories()
    }

    public func applyMemoryPressure(_ pressure: ContextArenaPressure) async throws -> ContextArenaTrimReceipt {
        let receipt = try arena.applyMemoryPressure(pressure)
        if pressure == .normal {
            await reconcileAll(reason: "pressure_normal")
        }
        return receipt
    }

    public func acquireSnapshot() throws -> ContextGenerationLease {
        try arena.acquireSnapshot()
    }

    public func health() async -> ContextFlowCoordinatorHealth {
        // An unread store is not a store with no degraded sources: the zero
        // travels with the failed measurement as the health error.
        var storeHealth: ContextStoreHealthSnapshot?
        var measurementError: String?
        do { storeHealth = try await store.healthSnapshot() } catch {
            measurementError = "context store health could not be read: \(error)"
        }
        let metrics = arena.metrics()
        return ContextFlowCoordinatorHealth(
            mode: mode,
            started: started,
            activeStoreGenerationID: storeHealth?.activeGenerationID,
            activeArenaGenerationID: metrics.currentGenerationID,
            registeredSourceCount: await registry.allRegistrations().count,
            degradedSourceCount: storeHealth?.degradedSources ?? 0,
            arenaMetrics: metrics,
            feedbackEventCount: feedbackEvents.count,
            newestFeedbackEventID: feedbackEvents.last?.id,
            lastReconciledAt: lastReconciledAt,
            lastError: measurementError ?? lastError
        )
    }

    func isCurrent(_ lifecycleID: UInt64) -> Bool {
        self.lifecycleID == lifecycleID && !reconciliationClosed && !Task.isCancelled
    }

    private func observe(_ directory: URL, lifecycleID: UInt64) async {
        guard isCurrent(lifecycleID) else { return }
        await coalescer?.enqueue(directory)
    }

    func finishCompile() {
        compileInProgress = false
        resumeCompileWaiters()
    }

    func cancelCompileWaiter(_ id: UUID) {
        compileWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeCompileWaiters() {
        let waiters = Array(compileWaiters.values)
        compileWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func beginPublication(for requestID: UInt64) async -> Bool {
        while publicationInProgress, !reconciliationClosed, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(); return }
                    publicationWaiters[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelPublicationWaiter(id) }
            }
        }
        guard !reconciliationClosed, requestID == nextReconciliationRequestID, !Task.isCancelled else { return false }
        publicationInProgress = true
        return true
    }

    func finishPublication() {
        publicationInProgress = false
        resumePublicationWaiters()
        let drains = publicationDrainWaiters
        publicationDrainWaiters.removeAll(keepingCapacity: true)
        for drain in drains { drain.resume() }
    }

    private func cancelPublicationWaiter(_ id: UUID) {
        publicationWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumePublicationWaiters() {
        let waiters = Array(publicationWaiters.values)
        publicationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

}
