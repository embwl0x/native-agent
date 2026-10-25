import Foundation
import NativeAgentCore
// Blueprint: | `ContextFlowCoordinator.swift` | Immutable arena publication and trim rehydration; verification filters delivered items/pointers but retains selection-time receipt/budget and feedback IDs; compile/publication admission waits leave on cancellation or stop; stop invalidates candidates and separately drains entered publication before returning; feedback replay reused only for matching generation, events and decay bucket; SQLite retains derived generations and ranking events, while turn traces own displayed receipts |

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
public actor ContextFlowCoordinator: DerivedStateInvalidationSink {
    public let mode: ContextFlowMode
    public let store: ContextSQLiteStore
    public let arena: ContextArena
    public let registry: ContextSourceRegistry

    private struct PendingRegistration: Sendable {
        let registration: ContextSourceRegistration
        let requestID: UInt64
    }

    private struct ReconciliationBatch: Sendable {
        let requestID: UInt64
        let registrations: [ContextSourceRegistration]
        let reason: String
        let compiledProjectionIdentifiers: Set<String>
    }

    private struct ReconciliationCandidate: Sendable {
        let batch: ReconciliationBatch
        let baselineGenerationID: Int64?
        let changedSources: [ContextCompiledSource]
        let removedSourceIDs: Set<ContextSourceID>
        let successfulSources: [ContextSourceID: ContextCompiledSource]
        let compileFailures: [ContextSourceID: String]
        let projectionResults: [String: ContextCompiledProjectionResult]
    }

    private let compiler: any ContextMarkdownCompiling
    private let selector: ContextSelector
    private let mirrorProvider: any ContextRequiredDocumentMirrorProviding
    private let compiledProjectionProviders: [any ContextCompiledProjectionProvider]
    private var monitor: ContextSourceMonitor?
    private var coalescer: ContextSourceEventCoalescer?
    private var started = false
    /// Embedding models already reported as having no semantic floor.
    private var floorlessEmbeddingModels: Set<String> = []
    private var lastReconciledAt: Date?
    private var lastError: String?
    // 2026-07-21 audit: context.sqlite grew unbounded because store.prune()
    // had zero production callers. Prune opportunistically after successful
    // commits, interval-gated so hot reconcile streaks don't pay for it.
    private var lastPruneAt: Date?
    private let pruneInterval: TimeInterval = 6 * 3_600
    /// A5.5(b): VACUUM cadence. prune() bounds the row count every 6h; VACUUM
    /// reclaims the freed pages back to the filesystem. It rewrites the whole
    /// file, so it runs far less often — once per day, and only when a prune
    /// actually deleted something.
    private var lastVacuumAt: Date?
    private let vacuumInterval: TimeInterval = 24 * 3_600
    private var activeStoredGeneration: ContextStoredGeneration?
    private var activeCompiledSources: [ContextSourceID: ContextCompiledSource] = [:]
    private let feedbackReducer = ContextFeedbackReducer()
    private var feedbackEvents: [ContextFeedbackEvent] = []
    private var feedbackOrdinal: UInt64 = 0
    /// The last feedback that applied; a failed update never replaces it.
    private var publishedFeedback: ContextFeedbackSnapshot?
    private var cachedFeedback: (
        generationID: Int64, feedbackOrdinal: UInt64, timeBucket: Int64,
        snapshot: ContextFeedbackSnapshot
    )?
    /// Bounded USER.md precoverage outcome reporting — one line per distinct
    /// state (success, non-application, failure) instead of one per turn.
    private var precoverageReporter = PrecoverageOutcomeReporter()
    // Newer batches include every unacknowledged request. Compilation may
    // overlap, but only the freshest batch can enter the publication gate.
    private var nextReconciliationRequestID: UInt64 = 0
    private var pendingRegistrations: [ContextSourceID: PendingRegistration] = [:]
    private var pendingProjectionReconciliationRequestIDs: [String: UInt64] = [:]
    private var pendingReconciliationReason = "source_change"
    private var publicationInProgress = false
    private var publicationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Stop drains an entered publisher even if its own caller is cancelled.
    /// Admission waiters, in contrast, leave on cancellation or stop.
    private var publicationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var reconciliationClosed = false
    private var lifecycleID: UInt64 = 0
    /// One compile at a time. A request arriving during one waits, and only
    /// the newest waiter compiles: an older one's commit would be refused.
    private var compileInProgress = false
    private var compileWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Housekeeping rebuilds a turn requested or launch started; no turn awaits it.
    private var backgroundReconciliation: Task<Void, Never>?
    private var degradedSourceIDs: Set<ContextSourceID> = []
    /// Per-generation derivations whose inputs are immutable for a complete
    /// mirror/kernel/surface/privacy behavior key. This keeps repeated turns
    /// from walking every source and atom merely to rebuild the same authority
    /// sets. Turn-local feedback and all live-only side effects stay outside.
    private var generationDerivedCache: [GenerationDerivedCacheKey: GenerationDerivedTurnState] = [:]
    /// Error-level diagnostic sink. Injected so tests can prove the dead-lane
    /// alarm actually fires; production keeps nativeLog (Console.app / the app's
    /// log stream), matching the provenance-MISS line added in 218fb021.
    private let diagnostics: @Sendable (String) -> Void

    struct GenerationDerivedCacheKey: Hashable, Sendable {
        let generationID: Int64
        let generationSourceFingerprint: String
        let surface: String
        let personaID: String
        let mirrorSourceFingerprint: String
        let kernelPersonaID: String
        let kernelSurface: String
        let kernelSourceFingerprint: String
        let stableIncludedDocumentIDs: [String]
        let allowedPrivacy: [String]
        /// Part of the key because it changes the DERIVED value: it decides
        /// whether every persona source is precovered or only the kernel's.
        let stableSegmentCarriesRequiredDocuments: Bool
        let userMemoryCore: [String]?
        let memoryRecallDisabled: Bool
        let excludedSourceOwners: Set<String>

        init(
            generationID: Int64,
            generationSourceFingerprint: String,
            surface: String,
            personaID: String,
            mirrorSourceFingerprint: String,
            kernelPersonaID: String,
            kernelSurface: String,
            kernelSourceFingerprint: String,
            stableIncludedDocumentIDs: [String],
            allowedPrivacy: [String],
            stableSegmentCarriesRequiredDocuments: Bool = false,
            userMemoryCore: [String]? = nil,
            memoryRecallDisabled: Bool = false,
            excludedSourceOwners: Set<String> = []
        ) {
            self.generationID = generationID
            self.generationSourceFingerprint = generationSourceFingerprint
            self.surface = surface
            self.personaID = personaID
            self.mirrorSourceFingerprint = mirrorSourceFingerprint
            self.kernelPersonaID = kernelPersonaID
            self.kernelSurface = kernelSurface
            self.kernelSourceFingerprint = kernelSourceFingerprint
            self.stableIncludedDocumentIDs = stableIncludedDocumentIDs
            self.allowedPrivacy = allowedPrivacy
            self.stableSegmentCarriesRequiredDocuments = stableSegmentCarriesRequiredDocuments
            self.userMemoryCore = userMemoryCore
            self.memoryRecallDisabled = memoryRecallDisabled
            self.excludedSourceOwners = excludedSourceOwners
        }

        init(
            generation: ContextStoredGeneration,
            request: ContextTurnRequest,
            mirror: RequiredDocumentMirror,
            kernel: StablePromptKernel,
            excludedSourceOwners: Set<String>
        ) {
            self.init(
                generationID: generation.generation.id,
                generationSourceFingerprint: generation.generation.sourceFingerprint,
                surface: request.surface.rawValue,
                personaID: mirror.personaID.rawValue,
                mirrorSourceFingerprint: mirror.sourceFingerprint,
                kernelPersonaID: kernel.key.personaID.rawValue,
                kernelSurface: kernel.key.surfaceVariant.rawValue,
                kernelSourceFingerprint: kernel.key.sourceFingerprint,
                stableIncludedDocumentIDs: kernel.includedDocumentIDs.map(\.rawValue),
                allowedPrivacy: request.allowedPrivacy.map(\.rawValue).sorted(),
                stableSegmentCarriesRequiredDocuments:
                    request.stableSegmentCarriesRequiredDocuments,
                userMemoryCore: request.userMemoryCore,
                memoryRecallDisabled: !request.memoryRecallEnabled,
                excludedSourceOwners: excludedSourceOwners
            )
        }
    }

    private struct GenerationDerivedTurnState: Sendable {
        let allowedSourceIDs: Set<ContextSourceID>
        let precoveredSourceIDs: Set<ContextSourceID>
        let userPrecoverage: GeneratedUserPrecoverageOutcome
        let protectedCorrectionAtomIDs: Set<ContextAtomID>
        let memoryPersonaPrefix: String
        let slotScopedMemorySourceCount: Int
    }

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
        let monitor = ContextSourceMonitor { [weak self] event in
            await self?.observe(event, lifecycleID: lifecycleID)
        }
        self.monitor = monitor

        // Turns read the generation published before this launch while the
        // launch rebuild runs as housekeeping. A store that never published
        // one has nothing to read yet: its turns get the unavailable-generation
        // receipt until the first build publishes; none waits for it.
        do {
            if let published = try await store.loadActiveGeneration() {
                guard isCurrent(lifecycleID) else { return }
                guard await beginPublication(for: nextReconciliationRequestID) else { return }
                defer { finishPublication() }
                try await activate(published, projectionResults: [:])
            }
        } catch {
            guard isCurrent(lifecycleID) else { return }
            lastError = "the published context generation could not be reopened: \(error)"
        }
        guard isCurrent(lifecycleID) else { return }
        reconcileInBackground(reason: "launch")
        await restoreFeedbackEvents()
    }

    private func reconcileInBackground(reason: String) {
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

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        _ = await reconcileSourceChanges(changes)
    }

    /// Request-scoped completion for callers that fence a foreground choice
    /// on publication. Health is not a completion receipt: cancellation keeps
    /// health unchanged, and another request may publish while this one fails.
    public func reconcileSourceChanges(_ changes: [DerivedSourceChange]) async -> Bool {
        guard !reconciliationClosed, mode != .off, !changes.isEmpty, !Task.isCancelled else { return false }
        let lifecycleID = self.lifecycleID
        let semanticChanges = changes.filter(\.semantic)
        let invalidatedProjectionIDs = Set(compiledProjectionProviders.compactMap { provider in
            semanticChanges.contains(where: provider.isInvalidated)
                ? provider.projectionIdentifier
                : nil
        })
        let projectionNamespaces = Set(compiledProjectionProviders.flatMap(\.invalidationNamespaces))
        let registrationChanges = semanticChanges.filter {
            !projectionNamespaces.contains($0.namespace)
        }
        // An unrelated candidate database must not refresh discovery, acquire
        // a publication request ID, or supersede pending live-owner demand.
        guard !registrationChanges.isEmpty || !invalidatedProjectionIDs.isEmpty else { return true }

        // Projection-owned invalidations do not reread every other compiled
        // source. A Workshop status edge must not rescan/embed MemoryV2, and a
        // memory write must not replay Desk. Both remain background rebuilds.
        if registrationChanges.isEmpty, !invalidatedProjectionIDs.isEmpty {
            return await reconcile(
                registrations: [],
                reason: "compiled_projection_invalidation",
                compiledProjectionIdentifiers: invalidatedProjectionIDs
            )
        }
        guard await refreshDiscoveredSources() else { return false }
        let all = await registry.allRegistrations()
        guard isCurrent(lifecycleID) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.descriptor.id.rawValue, $0) })
        var selected: [ContextSourceRegistration] = []
        var requiresFullReconciliation = false
        for change in registrationChanges {
            if change.operation == .reconcile {
                requiresFullReconciliation = true
                continue
            }
            if let registration = byID[change.stableID] {
                selected.append(registration)
            } else if let locator = change.canonicalLocator {
                let standardized = URL(fileURLWithPath: locator).standardizedFileURL
                selected.append(contentsOf: all.filter { $0.fileURL.standardizedFileURL == standardized })
            } else {
                requiresFullReconciliation = true
            }
        }
        let completed: Bool
        if requiresFullReconciliation {
            // Discovery already refreshed this request's complete registry.
            // Reusing that snapshot avoids a second persona/catalog read pass
            // while still rebuilding every compiled projection on a full edge.
            completed = await reconcile(
                registrations: all,
                reason: "direct_invalidation",
                compiledProjectionIdentifiers: Set(
                    compiledProjectionProviders.map(\.projectionIdentifier)
                )
            )
        } else {
            completed = await reconcile(
                registrations: Self.unique(selected),
                reason: "direct_invalidation",
                compiledProjectionIdentifiers: invalidatedProjectionIDs
            )
        }
        guard isCurrent(lifecycleID) else { return false }
        await refreshWatchedDirectories()
        return completed && !Task.isCancelled
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

    private func generationDerivedTurnState(
        generation: ContextStoredGeneration,
        request: ContextTurnRequest,
        mirror: RequiredDocumentMirror,
        kernel: StablePromptKernel
    ) -> GenerationDerivedTurnState {
        let excludedSourceOwners = Set(compiledProjectionProviders.flatMap(\.excludedSourceOwners))
        let key = GenerationDerivedCacheKey(
            generation: generation,
            request: request,
            mirror: mirror,
            kernel: kernel,
            excludedSourceOwners: excludedSourceOwners
        )
        if let cached = generationDerivedCache[key] {
            return cached
        }

        let personaPrefix = ContextPersonaSourceNaming.locatorPrefix(for: mirror.personaID)
        let normalizedPersonaID = mirror.personaID.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let memoryPersonaPrefix = "memory-v2/personas/\(ContextStableID.digest(parts: [normalizedPersonaID]))/"
        var selectedSources: [ContextStoredSource] = []
        selectedSources.reserveCapacity(generation.sources.count)
        var slotScopedMemorySourceCount = 0
        for source in generation.sources {
            if excludedSourceOwners.contains(source.descriptor.owner) { continue }
            if !request.memoryRecallEnabled, source.descriptor.owner == "nativeagent.memory-v2" { continue }
            if source.descriptor.owner == "nativeagent.memory-v2",
               source.descriptor.canonicalLocator.hasPrefix(memoryPersonaPrefix) {
                slotScopedMemorySourceCount += 1
            }
            if source.descriptor.permittedSurfaces.contains(request.surface),
               request.allowedPrivacy.contains(source.descriptor.privacy),
               source.descriptor.owner != ContextPersonaSourceNaming.owner
                    || source.descriptor.canonicalLocator.hasPrefix(personaPrefix) {
                // Appending in generation order preserves the exact input order
                // used by the precoverage derivation before this cache existed.
                selectedSources.append(source)
            }
        }

        let allowedSourceIDs = Set(selectedSources.map(\.descriptor.id))
        let precoveredDocumentNames = Set(kernel.includedDocumentIDs.map {
            String($0.rawValue.dropLast(3))
        })
        let surfaceSuffix = "/surfaces/\(request.surface.rawValue).md"
        // When the caller's STABLE segment carries the persona's required
        // documents verbatim, EVERY persona-owned source it is allowed to carry
        // is already in the cached prefix — not just the kernel's own
        // SOUL/VOICE. Precovering them is how the packet stops mirroring 22 KB
        // of identity into the volatile block on every turn. `false` (the
        // default) keeps the kernel-only precoverage that shipped before this
        // flag.
        //
        // SURFACE PERMISSION IS THE GATE, IN BOTH DIRECTIONS. A source that
        // does not permit THIS turn's surface is not in the stable prefix, so
        // precovering it would delete it from the turn outright — the packet
        // must keep answering for it under its own surface rules (where
        // `ContextSelection.eligibilityReason` denies it as `.surfaceDenied`
        // anyway). `selectedSources` is already surface-filtered above; the
        // guard is restated here because "the caller happened to filter it for
        // me" is not a permission check, and `stablePrefixRequiredDocuments`
        // applies this identical predicate on the rendering side.
        var precoveredSourceIDs = Set(selectedSources.lazy.filter { source in
            guard source.descriptor.owner == ContextPersonaSourceNaming.owner,
                  source.descriptor.permittedSurfaces.contains(request.surface)
            else { return false }
            if request.stableSegmentCarriesRequiredDocuments { return true }
            let locator = source.descriptor.canonicalLocator
            if locator.hasSuffix(surfaceSuffix) { return true }
            let documentName = locator.split(separator: "/").last.map(String.init)?
                .replacingOccurrences(of: ".md", with: "")
            return documentName.map(precoveredDocumentNames.contains) ?? false
        }.map(\.descriptor.id))
        let userPrecoverage = Self.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: kernel,
            selectedSources: selectedSources,
            generation: generation
        )
        precoveredSourceIDs.formUnion(userPrecoverage.precoveredSourceIDs)
        // Suppress only facts in the USER block actually carried this turn
        // (its preamble in the stable segment, its pinned facts in the dynamic tail).
        // Persona USER atoms remain precovered: omitted facts must come from
        // their canonical memory sources, never from the generated document.
        if let user = mirror.documents.first(where: { $0.id.rawValue == "USER.md" }),
           let userSourceID = user.sourceID, precoveredSourceIDs.contains(userSourceID) {
            let carried = UserMDAutogenMarkers.promptText(user.text, pinnedCore: request.userMemoryCore)
            let facts = Self.generatedUserFacts(in: carried) ?? Set(carried.split(separator: "\n").compactMap { line in
                line.hasPrefix("- ") ? MemoryDisplayText.projectionJoinKey(String(line.dropFirst(2))) : nil
            })
            let factsByCore = Dictionary(grouping: facts, by: \.core)
            let memorySourceIDs = Set(selectedSources.lazy.filter {
                $0.descriptor.owner == "nativeagent.memory-v2"
            }.map(\.descriptor.id))
            for atom in generation.atoms where atom.validToGeneration == nil
                && memorySourceIDs.contains(atom.draft.sourceID) {
                let body = MemoryDisplayText.projectionJoinKey(atom.draft.body)
                if factsByCore[body.core]?.contains(where: { $0.isCovered(by: body) }) == true {
                    precoveredSourceIDs.insert(atom.draft.sourceID)
                }
            }
        }

        let protectedCorrectionAtomIDs = Set(generation.atoms.lazy.filter { atom in
            atom.validToGeneration == nil
                && atom.draft.kind == .correction
                && atom.draft.authority == .explicitCorrection
                // 2026-09-23: topic-less corrections rode every turn uncapped.
                && ContextCorrectionScope.hasTopics(atom.draft)
                && allowedSourceIDs.contains(atom.draft.sourceID)
                && request.allowedPrivacy.contains(atom.draft.privacy)
                && atom.draft.permittedSurfaces.contains(request.surface)
        }.map(\.draft.id))
        let derived = GenerationDerivedTurnState(
            allowedSourceIDs: allowedSourceIDs,
            precoveredSourceIDs: precoveredSourceIDs,
            userPrecoverage: userPrecoverage,
            protectedCorrectionAtomIDs: protectedCorrectionAtomIDs,
            memoryPersonaPrefix: memoryPersonaPrefix,
            slotScopedMemorySourceCount: slotScopedMemorySourceCount
        )
        generationDerivedCache[key] = derived
        return derived
    }

    private func invalidateGenerationDerivedCache() {
        guard !generationDerivedCache.isEmpty else { return }
        generationDerivedCache.removeAll(keepingCapacity: true)
    }

    private func activateStoredGeneration(_ stored: ContextStoredGeneration) {
        if activeStoredGeneration?.generation.id != stored.generation.id {
            activeCompiledSources = Self.previousCompiledSources(stored)
        }
        if let activeStoredGeneration,
           activeStoredGeneration.generation.id != stored.generation.id
                || activeStoredGeneration.generation.sourceFingerprint
                    != stored.generation.sourceFingerprint {
            invalidateGenerationDerivedCache()
        }
        activeStoredGeneration = stored
    }

    public func prepareTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        guard started, mode != .off else {
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        // The turn reads the published generation; it never joins a compile.
        guard let generation = activeStoredGeneration else {
            reconcileInBackground(reason: "turn_generation_recovery")
            throw ContextTurnPreparationError.generationUnavailable
        }
        let lease = try arena.acquireSnapshot()
        do {
            let surfaceVariant = ContextSurfaceVariant(rawValue: request.surface.rawValue)
            let mirrorCandidates = lease.snapshot.requiredDocumentMirrors.filter {
                $0.kernel(for: surfaceVariant) != nil
            }
            let mirror = request.personaIDHint.flatMap { hint in
                mirrorCandidates.first { $0.personaID.rawValue == hint }
            } ?? (mirrorCandidates.count == 1 ? mirrorCandidates[0] : nil)
            guard let mirror, let kernel = mirror.kernel(for: surfaceVariant) else {
                throw ContextTurnPreparationError.kernelUnavailable(
                    surface: request.surface,
                    personaIDHint: request.personaIDHint
                )
            }

            // MEMORY IS SHARED ACROSS PERSONA SLOTS — there is deliberately no
            // persona clause in the selection filter below.
            //
            // PRODUCT POLICY (User approved, 2026-07-24): a persona slot id is
            // PRESENTATION-ONLY. `mirror.personaID` is a persona SLOT id
            // ("canonical" or a custom persona subdirectory name), while every
            // projected memory scope is a digest of a MemoryV2 RECORD persona
            // id (an agent name). The live store's whole `personaId`
            // vocabulary is configured agent names and
            // "NativeAgent" (85 active), VERIFIED 2026-07-24. No production
            // writer stamps a SLOT id into a record.
            //
            // So the previous "custom personas only see their own scope" gate
            // was never isolation: it was an id-vocabulary mismatch wearing
            // isolation's clothes. A custom persona's own scope is UNMINTABLE,
            // so the gate protected an empty set forever while costing the
            // whole memory lane (zero atoms for any custom persona; the
            // resident lost every source too until the .resident bypass landed
            // earlier today).
            //
            // NativeAgent is deliberately ONE agent that may spawn subagents
            // but is NOT a multi-agent system. Persona docs change how she
            // SOUNDS, not who she IS; memory is the continuity. Sharding memory
            // per persona mask would be a quiet step toward a fleet and
            // contradicts the northstar's "one mind, no theater".
            //
            // If genuine compartmentalization is ever wanted (a demo persona
            // that must not see personal memories), its home is the per-record
            // DISCLOSURE layer — MemoryRecordDisclosurePolicy.classify /
            // .permits(surface:personaID:), already surface- and persona-aware
            // — NOT a storage-level persona filter here. Do not reintroduce a
            // slot-id scope gate in this filter.
            let generationDerived = generationDerivedTurnState(
                generation: generation,
                request: request,
                mirror: mirror,
                kernel: kernel
            )
            // Vocabulary-drift alarm (2026-07-24), replacing the memory-scope
            // starvation alarm this batch shipped a few hours earlier. Under
            // the shared-store policy no persona slot can starve, so that alarm
            // could only ever fire on healthy behavior — and an alarm that
            // cries wolf gets ignored.
            //
            // What IS still a real, and now the ONLY, mismatch worth shouting
            // about: a live memory source scoped by digest(SLOT id). That can
            // only mean a writer began minting per-SLOT memory scopes — the two
            // id vocabularies have merged, and the presentation-only decision
            // above has to be re-reviewed before that shard goes live. Silent
            // on every shape production emits today; one error line per
            // side-effecting turn, never per atom.
            //
            // Known benign trip: a persona subdirectory named exactly like an
            // agent (a configured-name slot) makes the two digests
            // collide. That overlap is itself worth a look, so it is not
            // special-cased away.
            if generationDerived.slotScopedMemorySourceCount > 0 {
                diagnostics(
                    "[context-flow] ERROR memory-scope vocabulary drift: "
                    + "\(generationDerived.slotScopedMemorySourceCount) live memory source(s) are scoped by "
                    + "persona SLOT id \"\(mirror.personaID.rawValue)\" (prefix "
                    + "\(generationDerived.memoryPersonaPrefix)). MemoryV2 record persona ids are AGENT NAMES; "
                    + "a slot-id-scoped record means the two vocabularies merged. Memory is "
                    + "deliberately shared across persona slots — re-review that decision "
                    + "before shipping a per-slot memory shard."
                )
            }
            // SCOPE, stated once so it stops being re-discovered: precoverage
            // decides whether the USER.md CONTEXT SOURCE's atoms enter this
            // packet. It does not edit the persona-document lane.
            //
            // It is nonetheless GATED on that lane, because suppression here is
            // only de-duplication when the stable prompt actually carries
            // USER.md. `kernel` is that lane's authority, so it is passed in
            // rather than assumed. Corrected 2026-07-24: the previous note here
            // asserted the persona lane "renders USER.md into the system prompt"
            // unconditionally. It does not — in `ContextFlowMode.active` the
            // kernel is SOUL+VOICE only, and that false premise is what made
            // suppression a fact-loss path.
            //
            // `persona.docChars` counts the mirror's documents, NOT the bytes
            // sent; `system.stableChars` is what ships. A successful precoverage
            // leaves both unchanged by design — that is not evidence it failed.
            if let line = precoverageReporter.message(for: generationDerived.userPrecoverage) {
                diagnostics(line)
            }
            if request.queryEmbedding != nil, let model = request.queryEmbeddingModelID,
               selector.configuration.memorySemanticFloors[model] == nil,
               floorlessEmbeddingModels.insert(model).inserted {
                diagnostics("[context] no memory semantic floor for embedding model \(model); memories ride only by explicit match, working set or pins")
            }
            let feedback = feedbackSnapshot(for: generation)
            let feedbackByAtom = Dictionary(uniqueKeysWithValues: feedback.states.map {
                ($0.atomID, $0)
            })
            var activation = request.cognitiveActivation
            for state in feedback.states where state.temporaryActivation > 0 {
                activation[state.atomID] = max(
                    activation[state.atomID] ?? 0,
                    state.temporaryActivation
                )
            }
            let makeNeed: (Int) -> NeedSignal = { characterBudget in
                NeedSignal(
                    message: request.userMessage,
                    surface: request.surface,
                    origin: request.origin,
                    authorization: ContextSelectionAuthorization(
                        allowedOrigins: [request.origin],
                        allowedPrivacy: request.allowedPrivacy,
                        allowedSourceIDs: generationDerived.allowedSourceIDs,
                        permissionLabels: request.permissionLabels
                    ),
                    sessionID: request.sessionID,
                    recentTurns: request.recentTurns,
                    activeTask: request.activeTask,
                    unresolvedQuestion: request.unresolvedQuestion,
                    goal: request.goal,
                    predictedToolGroups: request.predictedToolGroups,
                    contextualTerms: request.contextualTerms,
                    cognitiveActivation: activation,
                    feedbackUtilityOverrides: feedbackByAtom.mapValues(\.utility),
                    feedbackDecayOverrides: feedbackByAtom.mapValues(\.decay),
                    workingAtomIDs: request.workingAtomIDs,
                    precoveredSourceIDs: generationDerived.precoveredSourceIDs,
                    mandatoryAtomIDs: Set(generation.atoms.lazy.filter {
                        generationDerived.protectedCorrectionAtomIDs.contains($0.draft.id)
                            && ContextCorrectionScope.applies(
                                $0.draft, message: request.userMessage, recentTurns: request.recentTurns
                            )
                    }.map(\.draft.id)),
                    // `deletedAtomIDs` is the selector's existing exclusion;
                    // here it carries her rejections (Phase 5 B0).
                    deletedAtomIDs: request.suppressedAtomIDs,
                    queryEmbedding: request.queryEmbedding,
                    alternateQueryEmbedding: request.alternateQueryEmbedding,
                    queryEmbeddingModelFingerprint: request.queryEmbeddingModelFingerprint,
                    queryEmbeddingModelID: request.queryEmbeddingModelID,
                    availableGenerationID: generation.generation.id,
                    characterBudget: characterBudget,
                    packetAtomExpandThresholdChars: request.packetAtomExpandThresholdChars,
                    memoryAtomRowLimit: request.memoryAtomRowLimit,
                    cacheState: .hit
                )
            }
            var need = makeNeed(request.characterBudget)
            var budgetExpansion: ContextFlowBudgetExpansion?
            var packet: ContextPacket
            do {
                packet = try selector.select(
                    need,
                    from: generation,
                    pinnedTo: lease.snapshot,
                    measureLatency: true
                )
            } catch ContextSelectionError.mandatoryBudgetExceeded(let required, _)
                where request.maximumCharacterBudget > request.characterBudget
            {
                let expandedBudget = min(
                    request.maximumCharacterBudget,
                    max(
                        request.characterBudget,
                        required + request.postMandatoryCharacterReserve
                    )
                )
                guard expandedBudget >= required else {
                    throw ContextSelectionError.mandatoryBudgetExceeded(
                        required: required,
                        limit: request.maximumCharacterBudget
                    )
                }
                need = makeNeed(expandedBudget)
                budgetExpansion = ContextFlowBudgetExpansion(
                    requestedCharacterBudget: request.characterBudget,
                    effectiveCharacterBudget: expandedBudget,
                    maximumCharacterBudget: request.maximumCharacterBudget,
                    mandatoryCharacterBudget: required,
                    grantedPostMandatoryReserve: max(0, expandedBudget - required)
                )
                packet = try selector.select(
                    need,
                    from: generation,
                    pinnedTo: lease.snapshot,
                    measureLatency: true
                )
            }
            let verifier = Self.verifier(compiledProjectionProviders, generation: generation, surface: request.surface)
            packet = await Self.verified(packet, by: verifier, in: generation)
            let recordsFeedback = !Self.isTestSession(request.sessionID)
            if recordsFeedback {
                await recordFeedback(
                    signal: .selection,
                    atomIDs: packet.selectedItems.map(\.pointer.atomID),
                    evidenceIDs: [packet.receipt.id],
                    generationID: generation.generation.id
                )
            }
            let feedbackHandler: (@Sendable (
                ContextFeedbackSignal,
                [ContextAtomID],
                [String]
            ) async -> Void)?
            if recordsFeedback {
                feedbackHandler = { [weak self] signal, atomIDs, evidenceIDs in
                    await self?.recordFeedback(
                        signal: signal,
                        atomIDs: atomIDs,
                        evidenceIDs: evidenceIDs,
                        generationID: generation.generation.id
                    )
                }
            } else {
                feedbackHandler = nil
            }
            let providers = compiledProjectionProviders
            let deliveryHandler: @Sendable ([ContextPacketItem]) async -> Void = { items in
                for provider in providers { await provider.didDeliver(items) }
            }
            return ContextPreparedTurn(
                mode: mode,
                kernel: kernel,
                mirror: mirror,
                packet: packet,
                lease: lease,
                generation: generation,
                need: need,
                budgetExpansion: budgetExpansion,
                deliveryHandler: deliveryHandler,
                feedbackHandler: feedbackHandler,
                verifier: verifier
            )
        } catch {
            lease.release()
            throw error
        }
    }

    /// Every projection checks exactly the atoms chosen against its owner.
    private static func verifier(
        _ providers: [any ContextCompiledProjectionProvider], generation: ContextStoredGeneration, surface: ContextSurface
    ) -> @Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion {
        { chosen in
            var exclusion = ContextTurnExclusion()
            for provider in providers {
                let check = await provider.verify(chosen, in: generation, surface: surface)
                exclusion.atomIDs.formUnion(check.atomIDs)
                exclusion.unverified += check.unverified
            }
            return exclusion
        }
    }

    /// Excludes rejected items/pointers and adds verification notices. Selection
    /// receipt and budget stay unchanged; outcome feedback retains the original IDs.
    private static func verified(
        _ packet: ContextPacket, by verifier: @Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion,
        in generation: ContextStoredGeneration
    ) async -> ContextPacket {
        let chosenIDs = Set(packet.selectedItems.map(\.pointer.atomID) + packet.expandablePointers.map(\.atomID))
        let check = await verifier(generation.atoms.filter { chosenIDs.contains($0.draft.id) })
        guard !check.atomIDs.isEmpty || !check.unverified.isEmpty else { return packet }
        return ContextPacket(
            generationID: packet.generationID, sourceFingerprint: packet.sourceFingerprint,
            selectedItems: packet.selectedItems.filter { !check.atomIDs.contains($0.pointer.atomID) },
            expandablePointers: packet.expandablePointers.filter { !check.atomIDs.contains($0.atomID) },
            conflictSets: packet.conflictSets, degradedSources: packet.degradedSources + check.unverified,
            budget: packet.budget, receipt: packet.receipt)
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

    private func feedbackSnapshot(
        for generation: ContextStoredGeneration
    ) -> ContextFeedbackSnapshot {
        let bucket = Self.feedbackTimeBucket()
        if let cachedFeedback, cachedFeedback.generationID == generation.generation.id,
           cachedFeedback.feedbackOrdinal == feedbackOrdinal,
           cachedFeedback.timeBucket == bucket {
            return cachedFeedback.snapshot
        }
        // One seed per atom id: the reducer rejects a duplicate seed, and a
        // generation carrying the same atom twice must not be able to throw
        // on the rebuild — let alone on the fallback rebuild below.
        var seenSeedIDs: Set<ContextAtomID> = []
        let seeds = generation.atoms.compactMap { atom -> ContextFeedbackSeed? in
            guard seenSeedIDs.insert(atom.draft.id).inserted else { return nil }
            return ContextFeedbackSeed(
                atomID: atom.draft.id,
                baseUtility: atom.draft.recentUsefulness,
                baseActivation: atom.draft.activation,
                baseDecay: atom.draft.decayState
            )
        }
        let validIDs = Set(seeds.map(\.atomID))
        let applicable = feedbackEvents.compactMap { event -> ContextFeedbackEvent? in
            let retained = event.atomIDs.filter(validIDs.contains)
            guard !retained.isEmpty else { return nil }
            return ContextFeedbackEvent(
                id: event.id,
                atomIDs: retained,
                signal: event.signal,
                timeBucket: event.timeBucket,
                evidenceIDs: event.evidenceIDs
            )
        }
        do {
            let snapshot = try feedbackReducer.rebuild(seeds: seeds, events: applicable, through: bucket)
            cachedFeedback = (generation.generation.id, feedbackOrdinal, bucket, snapshot)
            publishedFeedback = snapshot
            return snapshot
        } catch {
            // The published feedback stands and the failed update is the
            // receipt; nothing is rebuilt without the retained events, and
            // nothing is cached, so the next turn tries the update again.
            lastError = "a context feedback update could not be applied; the last published feedback stands: \(error)"
            diagnostics("[context-flow] \(lastError ?? "")")
            return publishedFeedback ?? ContextFeedbackSnapshot(states: [])
        }
    }

    private func recordFeedback(
        signal: ContextFeedbackSignal,
        atomIDs: [ContextAtomID],
        evidenceIDs: [String],
        generationID: Int64
    ) async {
        let ids = Array(Set(atomIDs)).sorted()
        guard !ids.isEmpty else { return }
        feedbackOrdinal &+= 1
        let bucket = Self.feedbackTimeBucket()
        let event = ContextFeedbackEvent(
            id: ContextStableID.digest(parts: [
                "context-feedback-v1",
                String(generationID),
                String(feedbackOrdinal),
                Self.feedbackSignalName(signal),
            ] + ids.map(\.rawValue) + evidenceIDs.sorted()),
            atomIDs: ids,
            signal: signal,
            timeBucket: bucket,
            evidenceIDs: evidenceIDs
        )
        do {
            try await store.recordFeedbackEvent(event)
            feedbackEvents.append(event)
            cachedFeedback = nil
            if feedbackEvents.count > 4_096 {
                feedbackEvents.removeFirst(feedbackEvents.count - 4_096)
            }
        } catch {
            // Context feedback is advisory, but a failed write must not look
            // like a healthy restart that merely learned nothing.
            lastError = "context feedback persistence failed: \(error)"
            diagnostics("[context-flow] \(lastError ?? "context feedback persistence failed")")
            return
        }
    }

    private func restoreFeedbackEvents() async {
        let lifecycleID = self.lifecycleID
        cachedFeedback = nil
        do {
            let restored = try await store.recentFeedbackEvents(limit: 4_096)
            guard isCurrent(lifecycleID) else { return }
            // Event IDs are ordinal-scoped. Retaining the current high-water
            // mark prevents a relaunch from overwriting a retained event.
            let ordinal = try await store.feedbackEventOrdinalHighWaterMark()
            guard isCurrent(lifecycleID) else { return }
            feedbackEvents = restored
            feedbackOrdinal = ordinal
            cachedFeedback = nil
        } catch {
            guard isCurrent(lifecycleID) else { return }
            lastError = "context feedback restore failed: \(error)"
            diagnostics("[context-flow] \(lastError ?? "context feedback restore failed")")
        }
    }

    /// Test traffic must not train her ranker (User, 2026-09-26). Benchmarks,
    /// walks and drives reach her over the bridge in sessions whose ids name
    /// them (bench-…, walk26-…, cuwalk-…, a2awalk-…, desk-walk…,
    /// claude-drive-…, telegram-drive-…, rut-test); her own Mac and Telegram
    /// threads are UUIDs, which can never contain these words. 09-24: fifteen
    /// bench-* context_expand calls raised one memory's score in real turns.
    private static func isTestSession(_ sessionID: String?) -> Bool {
        guard let id = sessionID?.lowercased() else { return false }
        return ["bench", "walk", "drive", "test"].contains { id.contains($0) }
    }

    private static func feedbackTimeBucket(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 / 300)
    }

    /// What a USER.md precoverage attempt did.
    ///
    /// All THREE states are reportable, because on 2026-07-24 the interesting
    /// live case turned out to be the SUCCESS one: precoverage was firing and
    /// suppressing correctly, and said nothing — so from outside the app it was
    /// indistinguishable from `.notApplicable` and from never having run.
    /// Diagnosing it needed a SQLite read of the live generation. A state that
    /// can only be established by reading the user's database is not observable.
    ///
    /// `.uncoveredFact` is the failure the caller must SEE: precoverage is
    /// all-or-nothing, so one uncovered line disables suppression for the whole
    /// document.
    enum GeneratedUserPrecoverageOutcome: Equatable, Sendable {
        /// Every generated fact is carried by an eligible memory atom.
        case precovered(Precovered)
        /// Ordinary non-application — no generated USER.md, a manual preamble,
        /// malformed markers, or no healthy USER/memory sources selected. The
        /// reason is carried so "not applicable because X" is distinguishable
        /// from "attempted and failed because Y".
        case notApplicable(NotApplicableReason)
        /// A generated fact has no matching memory atom.
        case uncoveredFact(fact: String, reason: UncoveredReason)

        /// What a successful precoverage actually bought, so the receipt can
        /// say "suppressed N atoms / M chars" instead of nothing at all.
        struct Precovered: Equatable, Sendable {
            let sourceIDs: Set<ContextSourceID>
            let factCount: Int
            let suppressedAtomCount: Int
            let suppressedChars: Int
        }

        var precoveredSourceIDs: Set<ContextSourceID> {
            if case .precovered(let summary) = self { return summary.sourceIDs }
            return []
        }
    }

    /// Why precoverage did not apply. Every one of these is ordinary — but
    /// "ordinary" and "silent" are not the same thing, and conflating them is
    /// what made this function undiagnosable from its own logs.
    enum NotApplicableReason: String, Equatable, Sendable {
        /// The persona mirror carries no USER.md document at all.
        case noUserDocument = "no-user-document"
        /// USER.md exists but is not a pure generated projection: a manual
        /// preamble, missing/malformed autogen markers, prose outside the
        /// markers, or a body line that is not a `- ` bullet.
        case notGeneratedProjection = "not-generated-projection"
        /// Well-formed markers, zero facts between them — nothing to cover.
        case noGeneratedFacts = "no-generated-facts"
        /// No healthy, live `nativeagent.persona` USER.md source in the
        /// selected set for this surface/privacy.
        case noHealthyUserSource = "no-healthy-user-source"
        /// No healthy, live `nativeagent.memory-v2` source selected, so there
        /// is nothing that could carry a fact.
        case noHealthyMemorySource = "no-healthy-memory-source"
        /// This surface's stable prompt kernel does not include USER.md, so the
        /// context packet is USER.md's ONLY carrier and suppressing it would
        /// drop facts rather than de-duplicate them. See the comment on
        /// `generatedUserProjectionOutcome` for why this is the decisive check.
        case userDocumentNotInStablePrompt = "user-document-not-in-stable-prompt"
    }

    enum UncoveredReason: String, Equatable, Sendable {
        /// An atom carrying this text exists, but the two sides still
        /// canonicalize it differently. Post-`MemoryDisplayText.projectionJoinKey`
        /// this should be unreachable — if it fires, a renderer drifted again.
        case rendererDivergence = "renderer-divergence"
        /// No atom carries this text at all: the projection rejected the row
        /// (lifecycle, durability, secret shape, disclosure, size), the row is
        /// out of the selected persona scope, or USER.md is stale.
        case admissionAsymmetry = "admission-asymmetry"
    }

    /// USER.md's generated fact body is a human-readable projection of
    /// MemoryV2. Suppress that whole adaptive source only when every generated
    /// bullet is represented by an eligible, healthy MemoryV2 atom.
    /// A manual preamble, malformed markers, or one missing fact fails back to
    /// today's USER selection behavior.
    ///
    /// Both sides of the join go through `MemoryDisplayText.projectionJoinKey`
    /// — the SAME helper — because they arrive in different shapes: a USER.md
    /// line has already been through the display renderer, an atom body has
    /// not. Comparing the two raw strings meant any row with a leading
    /// timestamp broke precoverage for the entire document.
    ///
    /// CARRIER SAFETY (2026-07-24). `precoveredSourceIDs` has exactly one
    /// meaning at its consumer: "already present in the stable prompt, so do
    /// not spend dynamic budget re-sending it" (see the comment above
    /// `scorable` in `ContextSelection.select`). A precovered source is hard
    /// dropped from the ranked candidates AND loses `.always` mandatory status
    /// — it cannot enter the packet by any route.
    ///
    /// That premise is what this function must establish before suppressing.
    /// Fact-level parity with memory atoms is NOT sufficient, because those
    /// atoms are ordinary `adaptive` candidates competing for the character
    /// budget: nothing guarantees the selector actually picks them. If USER.md
    /// is also absent from the stable prompt, a "covered" fact can end up in
    /// no lane at all.
    ///
    /// That was live. In `ContextFlowMode.active` the kernel renders SOUL and
    /// VOICE only (`NativeContextFlowRuntime.makeMirror`), so USER.md was never
    /// in the stable prompt — while 1053 sampled turns showed `stableChars`
    /// pinned at ~10.5k, below USER.md's own 15,006 bytes, and 757 of them
    /// (72%) selected ZERO memory atoms. Suppression on those turns removed
    /// User's user facts outright.
    ///
    /// So the kernel is consulted directly: suppress only when USER.md is
    /// genuinely in the stable prompt for THIS surface. This is a property of
    /// the mirror/kernel build, not of per-turn state, so it cannot make the
    /// stable prefix vary from turn to turn.
    static func generatedUserProjectionOutcome(
        mirror: RequiredDocumentMirror,
        kernel: StablePromptKernel,
        selectedSources: [ContextStoredSource],
        generation: ContextStoredGeneration
    ) -> GeneratedUserPrecoverageOutcome {
        guard let user = mirror.documents.first(where: { $0.id.rawValue == "USER.md" }) else {
            return .notApplicable(.noUserDocument)
        }
        // Decisive, and checked before anything else: if the stable prompt for
        // this surface does not carry USER.md, the packet is its only carrier
        // and no amount of fact parity makes suppression safe.
        guard kernel.includedDocumentIDs.contains(where: { $0.rawValue == "USER.md" }) else {
            return .notApplicable(.userDocumentNotInStablePrompt)
        }
        guard let facts = generatedUserFacts(in: user.text) else {
            return .notApplicable(.notGeneratedProjection)
        }
        guard !facts.isEmpty else { return .notApplicable(.noGeneratedFacts) }

        let userSources = selectedSources.filter {
            $0.descriptor.owner == "nativeagent.persona"
                && $0.descriptor.canonicalLocator.hasSuffix("/USER.md")
        }
        guard !userSources.isEmpty, userSources.allSatisfy({
            $0.health == .healthy && $0.validToGeneration == nil
        }) else { return .notApplicable(.noHealthyUserSource) }
        let memorySources = selectedSources.filter {
            $0.descriptor.owner == "nativeagent.memory-v2"
                && $0.health == .healthy
                && $0.validToGeneration == nil
        }
        guard !memorySources.isEmpty else { return .notApplicable(.noHealthyMemorySource) }
        let memorySourceIDs = Set(memorySources.map(\.descriptor.id))
        let memoryBodies = Set(generation.atoms.lazy.filter {
            $0.validToGeneration == nil && memorySourceIDs.contains($0.draft.sourceID)
        }.map { MemoryDisplayText.projectionJoinKey($0.draft.body) })

        // Sorted so "the first uncovered fact" is deterministic across runs —
        // `facts` is a Set, and a diagnostic that names a different line every
        // turn is noise, not a signal.
        //
        // `facts` may stay a Set because the join key keeps date-critical rows
        // apart (their stamp is part of the key): two facts collapse into one
        // entry only when they are byte-identical after whitespace collapse,
        // and one atom genuinely does cover two identical lines. Coverage is a
        // "does an atom carry this text" question, not a counting question.
        for fact in facts.sorted(by: { $0.description < $1.description })
        where !memoryBodies.contains(where: { fact.isCovered(by: $0) }) {
            // A body that carries the same CORE but fails the join is not a
            // renderer drift — it is a different record (different stamp) or a
            // sibling that was not admitted. Only a genuine text-shape mismatch
            // counts as divergence.
            let reason: UncoveredReason = memoryBodies.contains(where: {
                $0.core.hasSuffix(fact.core) || fact.core.hasSuffix($0.core)
            }) && !memoryBodies.contains(where: { $0.core == fact.core })
                ? .rendererDivergence
                : .admissionAsymmetry
            return .uncoveredFact(fact: fact.description, reason: reason)
        }

        let userSourceIDs = Set(userSources.map(\.descriptor.id))
        let suppressed = generation.atoms.lazy.filter {
            $0.validToGeneration == nil && userSourceIDs.contains($0.draft.sourceID)
        }
        return .precovered(GeneratedUserPrecoverageOutcome.Precovered(
            sourceIDs: userSourceIDs,
            factCount: facts.count,
            suppressedAtomCount: suppressed.count,
            suppressedChars: suppressed.reduce(0) { $0 + $1.draft.body.count }
        ))
    }

    /// Bounded reporter for precoverage OUTCOMES — success, non-application,
    /// and failure alike: ONE line per distinct state, never one per turn.
    ///
    /// Precoverage runs on every prepared turn, so per-turn reporting would
    /// print forever; total silence, the state before this, made a working
    /// suppression indistinguishable from a broken one (2026-07-24: diagnosing
    /// "is precoverage even firing?" required reading the live SQLite store,
    /// because neither success nor `.notApplicable` left a trace).
    ///
    /// Bounded by a small memo SET, not a single slot: `selectedSources` is
    /// surface-scoped, so chat and telegram turns can legitimately reach
    /// different outcomes, and a one-slot memo would then alternate and log on
    /// every turn.
    ///
    /// Past the cap the reporter MUTES itself permanently, with one line saying
    /// so. Evicting or clearing the memo instead would let a churning state
    /// re-report forever — bounded memory, unbounded output, which is the
    /// per-turn printer this design exists to avoid. A mute that announces
    /// itself is honest; silent truncation is the failure class this whole
    /// batch has been removing.
    struct PrecoverageOutcomeReporter {
        static let signatureCap = 8
        private var loggedSignatures: Set<String> = []
        private var muted = false

        /// The line to emit, or nil when this exact state was already reported
        /// (or the reporter has muted itself after `signatureCap` states).
        mutating func message(for outcome: GeneratedUserPrecoverageOutcome) -> String? {
            guard !muted else { return nil }
            let (signature, line) = Self.render(outcome)
            guard !loggedSignatures.contains(signature) else { return nil }
            guard loggedSignatures.count < Self.signatureCap else {
                muted = true
                return "[context-flow] USER.md precoverage reporting muted after "
                    + "\(Self.signatureCap) distinct outcome states this process; the state "
                    + "is churning faster than a per-state receipt can describe. Restart to "
                    + "re-arm. Suppression behavior itself is unaffected."
            }
            loggedSignatures.insert(signature)
            return line
        }

        private static func render(
            _ outcome: GeneratedUserPrecoverageOutcome
        ) -> (signature: String, line: String) {
            switch outcome {
            case .precovered(let summary):
                let signature = "precovered|\(summary.factCount)|\(summary.suppressedAtomCount)"
                    + "|\(summary.suppressedChars)"
                return (
                    signature,
                    "[context-flow] USER.md precoverage active: all \(summary.factCount) "
                        + "generated fact(s) are carried by memory atoms, so "
                        + "\(summary.suppressedAtomCount) USER.md context atom(s) "
                        + "(\(summary.suppressedChars) chars) are held out of the context "
                        + "packet. This suppresses the USER.md CONTEXT SOURCE only, and only "
                        + "because this surface's stable prompt kernel independently carries "
                        + "USER.md — so the facts still reach the model."
                )
            case .notApplicable(.userDocumentNotInStablePrompt):
                return (
                    "not-applicable|\(NotApplicableReason.userDocumentNotInStablePrompt.rawValue)",
                    "[context-flow] USER.md precoverage not applicable "
                        + "(\(NotApplicableReason.userDocumentNotInStablePrompt.rawValue)): this "
                        + "surface's stable prompt kernel does not include USER.md, so the "
                        + "context packet is its only carrier. Suppressing it would drop user "
                        + "facts rather than de-duplicate them. USER.md context atoms are "
                        + "selected normally."
                )
            case .notApplicable(let reason):
                return (
                    "not-applicable|\(reason.rawValue)",
                    "[context-flow] USER.md precoverage not applicable "
                        + "(\(reason.rawValue)): no suppression attempted this turn. "
                        + "USER.md context atoms, if any, are selected normally."
                )
            case .uncoveredFact(let fact, let reason):
                let clipped = fact.count > 120 ? String(fact.prefix(120)) + "…" : fact
                return (
                    "uncovered|\(reason.rawValue)|\(clipped)",
                    "[context-flow] WARN USER.md precoverage disabled "
                        + "(\(reason.rawValue)): generated fact \"\(clipped)\" has no matching "
                        + "memory atom. USER.md is injected in full alongside the memory atoms "
                        + "until this fact is covered or dropped from generation."
                )
            }
        }
    }

    private static func generatedUserFacts(in text: String) -> Set<MemoryDisplayText.Key>? {
        let preambleStart = UserMDAutogenMarkers.preambleStart
        let preambleEnd = UserMDAutogenMarkers.preambleEnd
        let bodyStart = UserMDAutogenMarkers.bodyStart
        let bodyEnd = UserMDAutogenMarkers.bodyEnd
        guard !text.contains(preambleStart),
              !text.contains(preambleEnd),
              let start = text.range(of: bodyStart),
              let end = text.range(of: bodyEnd, range: start.upperBound..<text.endIndex),
              text[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var facts = Set<MemoryDisplayText.Key>()
        for rawLine in text[start.upperBound..<end.lowerBound].split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.hasPrefix("- ") else { return nil }
            // Same helper the atom side uses — see
            // `generatedUserProjectionOutcome`. Never normalize here on its own.
            let fact = MemoryDisplayText.projectionJoinKey(String(line.dropFirst(2)))
            guard !fact.isEmpty else { return nil }
            facts.insert(fact)
        }
        return facts
    }

    private static func feedbackSignalName(_ signal: ContextFeedbackSignal) -> String {
        switch signal {
        case .selection: "selection"
        case .expansion: "expansion"
        case .correction(.confirms): "correction.confirms"
        case .correction(.contradicts): "correction.contradicts"
        case .retry: "retry"
        case .outcome(.completed): "outcome.completed"
        case .outcome(.confirmed): "outcome.confirmed"
        case .outcome(.contradicted): "outcome.contradicted"
        case .outcome(.abandoned): "outcome.abandoned"
        }
    }

    // MARK: - Event handling

    private func isCurrent(_ lifecycleID: UInt64) -> Bool {
        self.lifecycleID == lifecycleID && !reconciliationClosed && !Task.isCancelled
    }

    private func observe(_ event: ContextDirectoryEvent, lifecycleID: UInt64) async {
        guard isCurrent(lifecycleID) else { return }
        await coalescer?.enqueue(event.directory)
    }

    private func reconcile(dirtyDirectories: Set<URL>) async {
        let lifecycleID = self.lifecycleID
        guard await refreshDiscoveredSources() else {
            await refreshWatchedDirectories()
            return
        }
        guard isCurrent(lifecycleID) else { return }
        var affected: [ContextSourceRegistration] = []
        for directory in dirtyDirectories.sorted(by: { $0.path < $1.path }) {
            if let rows = try? await registry.registrations(affectedBy: directory) {
                guard isCurrent(lifecycleID) else { return }
                affected.append(contentsOf: rows)
            }
        }
        guard isCurrent(lifecycleID) else { return }
        await reconcile(
            registrations: Self.unique(affected),
            reason: "directory_event",
            compiledProjectionIdentifiers: []
        )
        guard isCurrent(lifecycleID) else { return }
        await refreshWatchedDirectories()
    }

    @discardableResult
    private func reconcileAll(reason: String) async -> Bool {
        let lifecycleID = self.lifecycleID
        guard await refreshDiscoveredSources(), !Task.isCancelled else { return false }
        let registrations = await registry.allRegistrations()
        guard isCurrent(lifecycleID) else { return false }
        return await reconcile(
            registrations: registrations,
            reason: reason,
            compiledProjectionIdentifiers: Set(
                compiledProjectionProviders.map(\.projectionIdentifier)
            )
        )
    }

    @discardableResult
    private func reconcile(
        registrations: [ContextSourceRegistration],
        reason: String,
        compiledProjectionIdentifiers: Set<String>
    ) async -> Bool {
        guard !reconciliationClosed, mode != .off, !Task.isCancelled else { return false }
        nextReconciliationRequestID &+= 1
        let requestID = nextReconciliationRequestID
        for registration in registrations {
            pendingRegistrations[registration.descriptor.id] = PendingRegistration(
                registration: registration,
                requestID: requestID
            )
        }
        for identifier in compiledProjectionIdentifiers {
            pendingProjectionReconciliationRequestIDs[identifier] = requestID
        }
        pendingReconciliationReason = reason
        return await reconcilePending(requestID: requestID)
    }

    private func reconcilePending(requestID: UInt64) async -> Bool {
        // Launch used to compile twice at once (start, and the memory
        // migration's invalidation). Pending demand accumulates, so the newest
        // request's one compile answers every request that waited for it.
        while compileInProgress, !reconciliationClosed, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(); return }
                    compileWaiters[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelCompileWaiter(id) }
            }
        }
        guard !reconciliationClosed, requestID == nextReconciliationRequestID, !Task.isCancelled else { return false }
        // A push's compiler may already have answered this flight's demand.
        if pendingRegistrations.isEmpty, pendingProjectionReconciliationRequestIDs.isEmpty {
            return activeStoredGeneration != nil
        }
        let batch = ReconciliationBatch(
            requestID: requestID,
            registrations: pendingRegistrations.values
                .map(\.registration)
                .sorted { $0.descriptor.id < $1.descriptor.id },
            reason: pendingReconciliationReason,
            compiledProjectionIdentifiers: Set(
                pendingProjectionReconciliationRequestIDs.keys
            )
        )

        var compileFailures: [ContextSourceID: String] = [:]
        compileInProgress = true
        let candidate: ReconciliationCandidate
        do {
            candidate = try await makeCandidate(for: batch, compileFailures: &compileFailures, stopWhenSuperseded: true)
            finishCompile()
        } catch is CancellationError {
            finishCompile()
            // Cancellation leaves demand pending for the next owner edge.
            return false
        } catch {
            finishCompile()
            await commitFailure(error, compileFailures: compileFailures, for: batch)
            return false
        }
        return await commit(candidate)
    }

    private func finishCompile() {
        compileInProgress = false
        resumeCompileWaiters()
    }

    private func cancelCompileWaiter(_ id: UUID) {
        compileWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeCompileWaiters() {
        let waiters = Array(compileWaiters.values)
        compileWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// `stopWhenSuperseded`: a newer request has taken over this batch's
    /// demand and its commit would be refused, so stop between sources.
    private func checkCandidateAdmission(_ requestID: UInt64, enabled: Bool) throws {
        if enabled, reconciliationClosed || Task.isCancelled || requestID != nextReconciliationRequestID {
            throw CancellationError()
        }
    }

    private func makeCandidate(
        for batch: ReconciliationBatch,
        compileFailures: inout [ContextSourceID: String],
        stopWhenSuperseded: Bool = false
    ) async throws -> ReconciliationCandidate {
        try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
        // A failed arena publication can leave SQLite ahead of the resident body.
        let durableGeneration = try await store.activeGeneration()
        try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
        let active: ContextStoredGeneration?
        let previousBySource: [ContextSourceID: ContextCompiledSource]
        if let retained = activeStoredGeneration, retained.generation.id == durableGeneration?.id {
            active = retained
            previousBySource = activeCompiledSources
        } else {
            if let durableGeneration {
                active = try await store.loadGeneration(id: durableGeneration.id)
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
            } else {
                active = nil
            }
            previousBySource = Self.previousCompiledSources(active)
        }
        let authoritativeSources = await registry.authoritativeSourceIDsByOwner()
        try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
        var changedSources: [ContextCompiledSource] = []
        // Discovery can remove a registration before this loop sees it.
        // Retire only sources whose owner explicitly supplied a complete
        // inventory, including empty inventories after restart.
        var removedSourceIDs = Set(previousBySource.compactMap { sourceID, source in
            guard let currentIDs = authoritativeSources[source.descriptor.owner],
                  !currentIDs.contains(sourceID) else { return nil as ContextSourceID? }
            return sourceID
        })
        var successfulSources: [ContextSourceID: ContextCompiledSource] = [:]
        var projectionResults: [String: ContextCompiledProjectionResult] = [:]

        for registration in batch.registrations {
            try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
            let sourceID = registration.descriptor.id
            if let currentIDs = authoritativeSources[registration.descriptor.owner],
               !currentIDs.contains(sourceID) {
                // A retry may still carry this now-retired registration.
                continue
            }
            guard FileManager.default.fileExists(atPath: registration.fileURL.path) else {
                if previousBySource[sourceID] != nil {
                    removedSourceIDs.insert(sourceID)
                }
                continue
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: registration.fileURL.path)
                let updatedAt = (attributes[.modificationDate] as? Date) ?? Date()
                let data = try Data(contentsOf: registration.fileURL, options: [.mappedIfSafe])
                guard data.count <= registration.maximumUTF8Bytes else {
                    throw ContextMarkdownCompilerError.sourceTooLarge(
                        actualBytes: data.count,
                        maximumBytes: registration.maximumUTF8Bytes
                    )
                }
                let compiled = try await compiler.compile(
                    sourceData: data,
                    descriptor: registration.descriptor,
                    previous: previousBySource[sourceID],
                    updatedAt: updatedAt
                )
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
                successfulSources[sourceID] = compiled
                // 2026-09-22: an embedding-provider change leaves bytes
                // (and so sourceHash) unchanged; without this the
                // re-embedded atoms were dropped and old vectors stuck.
                let embeddingChanged = Set(compiled.atoms.map { $0.embedding?.modelFingerprint })
                    != Set((previousBySource[sourceID]?.atoms ?? []).map { $0.embedding?.modelFingerprint })
                if compiled.sourceHash != previousBySource[sourceID]?.sourceHash
                    || compiled.descriptor != previousBySource[sourceID]?.descriptor
                    || embeddingChanged {
                    changedSources.append(compiled)
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                compileFailures[sourceID] = String(reflecting: type(of: error))
            }
        }

        // SQLite may have advanced before a mirror/arena failure retained the
        // live generation. Rebuild projection metadata against that durable
        // baseline before a selective retry can accept it.
        let projectionIdentifiers = active?.generation.id != activeStoredGeneration?.generation.id
            ? Set(compiledProjectionProviders.map(\.projectionIdentifier))
            : batch.compiledProjectionIdentifiers
        if !projectionIdentifiers.isEmpty {
            for provider in compiledProjectionProviders where
                projectionIdentifiers.contains(provider.projectionIdentifier) {
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
                let result = try await provider.compiledProjection(previousSources: previousBySource)
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
                projectionResults[provider.projectionIdentifier] = result
                for source in result.changedSources {
                    if changedSources.contains(where: { $0.descriptor.id == source.descriptor.id }) {
                        throw ContextFlowCoordinatorError.duplicateProjectedSource(source.descriptor.id)
                    }
                    changedSources.append(source)
                }
                removedSourceIDs.formUnion(result.removedSourceIDs)
            }
        }

        return ReconciliationCandidate(
            batch: batch,
            baselineGenerationID: active?.generation.id,
            changedSources: changedSources,
            removedSourceIDs: removedSourceIDs,
            successfulSources: successfulSources,
            compileFailures: compileFailures,
            projectionResults: projectionResults
        )
    }

    private func commit(_ candidate: ReconciliationCandidate) async -> Bool {
        guard await beginPublication(for: candidate.batch.requestID) else { return false }
        defer { finishPublication() }

        do {
            var candidate = candidate
            // Compilation suspends outside the publication gate. An earlier
            // publisher may have replaced its baseline while this diff waited.
            if try await store.activeGeneration()?.id != candidate.baselineGenerationID {
                var compileFailures: [ContextSourceID: String] = [:]
                candidate = try await makeCandidate(for: candidate.batch, compileFailures: &compileFailures)
            }
            let persistedDegradedCount = try? await store.healthSnapshot().degradedSources
            let hasUnknownPersistedDegradation = (persistedDegradedCount ?? 0) > degradedSourceIDs.count
            for (sourceID, error) in candidate.compileFailures.sorted(by: { $0.key < $1.key }) {
                await markSourceDegraded(sourceID, error: error)
            }

            var changedBySource = Dictionary(candidate.changedSources.map {
                ($0.descriptor.id, $0)
            }, uniquingKeysWith: { first, _ in first })
            let recoveredSourceIDs = degradedSourceIDs
                .intersection(candidate.successfulSources.keys)
                .subtracting(candidate.compileFailures.keys)
            let healthRecoverySourceIDs = hasUnknownPersistedDegradation
                ? recoveredSourceIDs.union(candidate.successfulSources.keys)
                : recoveredSourceIDs
            for sourceID in healthRecoverySourceIDs {
                if let source = candidate.successfulSources[sourceID] {
                    changedBySource[sourceID] = source
                }
            }

            if !changedBySource.isEmpty || !candidate.removedSourceIDs.isEmpty {
                _ = try await store.publish(ContextGenerationDraft(
                    reason: candidate.batch.reason,
                    changedSources: changedBySource.values.sorted {
                        $0.descriptor.id < $1.descriptor.id
                    },
                    removedSourceIDs: candidate.removedSourceIDs
                ))
                degradedSourceIDs.subtract(healthRecoverySourceIDs)
                degradedSourceIDs.subtract(candidate.removedSourceIDs)
            } else if try await store.activeGeneration() == nil {
                await pruneStoreIfDue()
                lastReconciledAt = Date()
                acknowledge(candidate.batch)
                return false
            }

            let stored: ContextStoredGeneration
            if let retained = activeStoredGeneration,
               persistedDegradedCount == retained.sources.filter({ $0.health == .degraded }).count,
               try await store.activeGeneration()?.id == retained.generation.id {
                stored = retained
            } else {
                guard let loaded = try await store.loadActiveGeneration() else {
                    throw ContextFlowCoordinatorError.activeGenerationUnavailable
                }
                stored = loaded
            }
            try await activate(stored, projectionResults: candidate.projectionResults)
            lastReconciledAt = Date()
            acknowledge(candidate.batch)
            await pruneStoreIfDue()
            return !Task.isCancelled
        } catch is CancellationError {
            // A cancelled caller must not mint an orange health incident or a
            // persistent degradation. Pending demand remains retryable.
            return false
        } catch {
            recordReconciliationFailure(error)
            return false
        }
    }

    /// Make `stored` the generation turns read: its mirrors, arena snapshot
    /// and projection identities publish together or not at all.
    private func activate(
        _ stored: ContextStoredGeneration,
        projectionResults: [String: ContextCompiledProjectionResult]
    ) async throws {
        let mirrors = try await mirrorProvider.requiredDocumentMirrors()
        let currentSnapshot = arena.currentSnapshot()
        let snapshot: ContextGenerationSnapshot
        if let currentSnapshot,
           currentSnapshot.generationID == stored.generation.id,
           currentSnapshot.sourceFingerprint == stored.generation.sourceFingerprint,
           currentSnapshot.requiredDocumentMirrors == mirrors.sorted(by: { $0.personaID < $1.personaID }),
           currentSnapshot.hotEntries.count + currentSnapshot.warmEntries.count == stored.atoms.count {
            snapshot = currentSnapshot
        } else {
            snapshot = try Self.makeArenaSnapshot(stored: stored, mirrors: mirrors)
        }
        let outcome: ContextArenaPublicationOutcome?
        if currentSnapshot == snapshot {
            outcome = nil
        } else if currentSnapshot?.generationID == stored.generation.id {
            outcome = arena.rehydrate(snapshot)
        } else {
            outcome = arena.publish(snapshot)
        }
        switch outcome {
        case nil, .published, .rehydrated:
            lastError = nil
            activateStoredGeneration(stored)
            let pinnedGenerationIDs = Set(arena.metrics().pinnedGenerations.keys)
            for provider in compiledProjectionProviders {
                provider.didPublish(
                    projectionResults[provider.projectionIdentifier],
                    generation: stored,
                    retaining: pinnedGenerationIDs
                )
            }
        case .retainedLastGood(let failure, _):
            throw ContextFlowCoordinatorError.arenaPublicationFailed(String(describing: failure))
        }
    }

    /// Bound retained generations and versions after successful commits.
    /// Maintenance failures never block a commit; they stay in health until
    /// the next due commit retries them.
    private func pruneStoreIfDue(now: Date = Date()) async {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < pruneInterval { return }
        do {
            let result = try await store.prune()
            lastPruneAt = now
            // A5.5(b): reclaim freed pages once per day, only when this or a
            // recent prune actually deleted rows (an empty prune freed nothing,
            // so a VACUUM would rewrite the file for no gain). VACUUM failure is
            // maintenance-only, never a reconcile blocker.
            let vacuumDue = lastVacuumAt.map { now.timeIntervalSince($0) >= vacuumInterval } ?? true
            if vacuumDue && result.totalDeleted > 0 {
                do {
                    try await store.vacuum()
                    lastVacuumAt = now
                } catch {
                    lastError = "context store vacuum failed; retried in the next due window: \(error)"
                    diagnostics("[context-flow] \(lastError ?? "")")
                }
            }
        } catch {
            lastError = "context store prune failed; retried at the next due commit: \(error)"
            diagnostics("[context-flow] \(lastError ?? "")")
        }
    }

    private func commitFailure(
        _ error: any Error,
        compileFailures: [ContextSourceID: String],
        for batch: ReconciliationBatch
    ) async {
        guard await beginPublication(for: batch.requestID) else { return }
        defer { finishPublication() }
        for (sourceID, compileError) in compileFailures.sorted(by: { $0.key < $1.key }) {
            await markSourceDegraded(sourceID, error: compileError)
        }
        recordReconciliationFailure(error)
    }

    private func markSourceDegraded(_ sourceID: ContextSourceID, error: String) async {
        try? await store.markSourceDegraded(sourceID, error: error)
        degradedSourceIDs.insert(sourceID)
        guard let stored = activeStoredGeneration else { return }
        invalidateGenerationDerivedCache()
        activeStoredGeneration = ContextStoredGeneration(
            generation: stored.generation,
            sources: stored.sources.map { source in
                guard source.descriptor.id == sourceID else { return source }
                return ContextStoredSource(
                    descriptor: source.descriptor,
                    sourceHash: source.sourceHash,
                    health: .degraded,
                    lastError: error,
                    validFromGeneration: source.validFromGeneration,
                    validToGeneration: source.validToGeneration
                )
            },
            atoms: stored.atoms,
            relationships: stored.relationships
        )
    }

    private func beginPublication(for requestID: UInt64) async -> Bool {
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

    private func finishPublication() {
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

    private func acknowledge(_ batch: ReconciliationBatch) {
        for (sourceID, pending) in pendingRegistrations where pending.requestID <= batch.requestID {
            pendingRegistrations[sourceID] = nil
        }
        for (identifier, requestID) in pendingProjectionReconciliationRequestIDs
            where requestID <= batch.requestID {
            pendingProjectionReconciliationRequestIDs[identifier] = nil
        }
    }

    private func recordReconciliationFailure(_ error: any Error) {
        lastError = String(describing: error)
        // Leave failed demand pending. A later external reconciliation will
        // coalesce and retry it without scheduling an immediate retry loop.
    }

    private func refreshWatchedDirectories() async {
        let lifecycleID = self.lifecycleID
        guard mode != .off, isCurrent(lifecycleID) else { return }
        let directories = await registry.watchedDirectories()
        guard isCurrent(lifecycleID) else { return }
        await monitor?.setDirectories(directories)
    }

    /// Refresh failure must stop this reconciliation request. Continuing with
    /// the prior registry can publish a healthy-looking old persona generation
    /// for a new picker value and cause the app-side ordering fence to consider
    /// that value reconciled. The last good generation remains active instead.
    private func refreshDiscoveredSources() async -> Bool {
        let lifecycleID = self.lifecycleID
        guard isCurrent(lifecycleID) else { return false }
        do {
            try await mirrorProvider.refreshContextSources(in: registry)
            return isCurrent(lifecycleID)
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(lifecycleID) else { return false }
            lastError = String(describing: error)
            return false
        }
    }

    // MARK: - Projection

    private static func previousCompiledSources(
        _ stored: ContextStoredGeneration?
    ) -> [ContextSourceID: ContextCompiledSource] {
        guard let stored else { return [:] }
        let atomsBySource = Dictionary(grouping: stored.atoms.map(\.draft), by: \.sourceID)
        let sourcesByAtom = Dictionary(grouping: stored.atoms, by: \.draft.id)
            .mapValues { Set($0.map(\.draft.sourceID)) }
        var relationshipsBySource: [ContextSourceID: [ContextRelationshipDraft]] = [:]
        for relationship in stored.relationships {
            for sourceID in sourcesByAtom[relationship.draft.sourceAtomID] ?? [] {
                relationshipsBySource[sourceID, default: []].append(relationship.draft)
            }
        }
        var result: [ContextSourceID: ContextCompiledSource] = [:]
        for source in stored.sources {
            let sourceAtoms = atomsBySource[source.descriptor.id] ?? []
            result[source.descriptor.id] = ContextCompiledSource(
                descriptor: source.descriptor,
                sourceHash: source.sourceHash,
                atoms: sourceAtoms,
                relationships: relationshipsBySource[source.descriptor.id] ?? []
            )
        }
        return result
    }

    private static func makeArenaSnapshot(
        stored: ContextStoredGeneration,
        mirrors: [RequiredDocumentMirror]
    ) throws -> ContextGenerationSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hot: [ContextArenaEntry] = []
        var warm: [ContextArenaEntry] = []
        var selectionIndex: [ContextAtomID: ContextSelectionIndexEntry] = [:]
        for storedAtom in stored.atoms {
            let atom = storedAtom.draft
            selectionIndex[atom.id] = ContextSelectionIndexEntry(atom: atom)
            let tier: ContextArenaTier = atom.injectionPolicy == .always
                || [.identity, .relationship, .correction, .runtimeTruth].contains(atom.kind)
                ? .hot
                : .warm
            let metadata = try encoder.encode(atom)
            let entry = try ContextArenaEntry(
                key: ContextArenaEntryKey(
                    namespace: atom.kind.rawValue,
                    id: atom.id.rawValue,
                    sourceFingerprint: atom.sourceHash,
                    generationID: stored.generation.id
                ),
                tier: tier,
                text: atom.body,
                summary: atom.deterministicSummary,
                metadata: metadata,
                vector: atom.embedding?.values ?? [],
                retentionPriority: atom.authority.rank
            )
            if tier == .hot { hot.append(entry) } else { warm.append(entry) }
        }
        return try ContextGenerationSnapshot(
            generationID: stored.generation.id,
            sourceFingerprint: stored.generation.sourceFingerprint,
            requiredDocumentMirrors: mirrors,
            hotEntries: hot,
            warmEntries: warm,
            selectionIndex: selectionIndex
        )
    }

    private static func unique(_ registrations: [ContextSourceRegistration]) -> [ContextSourceRegistration] {
        var seen = Set<ContextSourceID>()
        return registrations
            .sorted { $0.descriptor.id < $1.descriptor.id }
            .filter { seen.insert($0.descriptor.id).inserted }
    }
}
