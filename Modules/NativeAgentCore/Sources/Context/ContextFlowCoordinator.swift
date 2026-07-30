import Foundation
import NativeAgentCore

public enum ContextFlowMode: String, Codable, CaseIterable, Sendable {
    case off
    case shadow
    case active
}

public protocol ContextRequiredDocumentMirrorProviding: Sendable {
    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror]
}

public protocol ContextSourceRegistrationRefreshing: Sendable {
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

public struct EmptyContextRequiredDocumentMirrorProvider: ContextRequiredDocumentMirrorProviding {
    public init() {}
    public func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] { [] }
}

public struct ContextFlowCoordinatorHealth: Sendable, Equatable {
    public let mode: ContextFlowMode
    public let started: Bool
    public let activeStoreGenerationID: Int64?
    public let activeArenaGenerationID: Int64?
    public let registeredSourceCount: Int
    public let degradedSourceCount: Int
    public let arenaMetrics: ContextArenaMetrics
    public let pendingPrewarmHints: Int
    public let prewarmUsefulnessReceipts: Int
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
        pendingPrewarmHints: Int,
        prewarmUsefulnessReceipts: Int,
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
        self.pendingPrewarmHints = pendingPrewarmHints
        self.prewarmUsefulnessReceipts = prewarmUsefulnessReceipts
        self.lastReconciledAt = lastReconciledAt
        self.lastError = lastError
    }
}

public enum ContextFlowCoordinatorError: Error, Equatable, Sendable {
    case activeGenerationUnavailable
    case arenaPublicationFailed(String)
    case duplicateProjectedSource(ContextSourceID)
}

/// Resident event-driven compiler and RAM publication coordinator. FC0-FC3
/// callers run this in shadow mode; active prompt selection is a later gate.
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
        let changedSources: [ContextCompiledSource]
        let removedSourceIDs: Set<ContextSourceID>
        let successfulSources: [ContextSourceID: ContextCompiledSource]
        let compileFailures: [ContextSourceID: String]
    }

    private let compiler: any ContextMarkdownCompiling
    private let selector: ContextSelector
    private let mirrorProvider: any ContextRequiredDocumentMirrorProviding
    private let compiledProjectionProviders: [any ContextCompiledProjectionProvider]
    private var monitor: ContextSourceMonitor?
    private var coalescer: ContextSourceEventCoalescer?
    private var started = false
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
    private let feedbackReducer = ContextFeedbackReducer()
    private var feedbackEvents: [ContextFeedbackEvent] = []
    private var feedbackOrdinal: UInt64 = 0
    /// Bounded USER.md precoverage outcome reporting — one line per distinct
    /// state (success, non-application, failure) instead of one per turn.
    private var precoverageReporter = PrecoverageOutcomeReporter()
    private let prewarmPlanner = ContextPrewarmPlanner()
    private var prewarmPlans: [ContextPrewarmScope: ContextPrewarmPlan] = [:]
    private var prewarmRevision: Int64 = 0
    // Newer batches include every unacknowledged request. Compilation may
    // overlap, but only the freshest batch can enter the publication gate.
    private var nextReconciliationRequestID: UInt64 = 0
    private var pendingRegistrations: [ContextSourceID: PendingRegistration] = [:]
    private var pendingProjectionReconciliationRequestIDs: [String: UInt64] = [:]
    private var pendingReconciliationReason = "source_change"
    private var publicationInProgress = false
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var degradedSourceIDs: Set<ContextSourceID> = []
    /// Error-level diagnostic sink. Injected so tests can prove the dead-lane
    /// alarm actually fires; production keeps NSLog (Console.app / the app's
    /// log stream), matching the provenance-MISS line added in 218fb021.
    private let diagnostics: @Sendable (String) -> Void

    public init(
        mode: ContextFlowMode = .shadow,
        store: ContextSQLiteStore,
        arena: ContextArena,
        registry: ContextSourceRegistry,
        compiler: any ContextMarkdownCompiling,
        mirrorProvider: any ContextRequiredDocumentMirrorProviding = EmptyContextRequiredDocumentMirrorProvider(),
        compiledProjectionProviders: [any ContextCompiledProjectionProvider] = [],
        selector: ContextSelector = ContextSelector(),
        diagnostics: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }
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
        guard mode != .off else { return }

        let coalescer = ContextSourceEventCoalescer { [weak self] directories in
            await self?.reconcile(dirtyDirectories: directories)
        }
        self.coalescer = coalescer
        let monitor = ContextSourceMonitor { [weak self] event in
            await self?.observe(event)
        }
        self.monitor = monitor

        await reconcileAll(reason: "launch")
        await refreshWatchedDirectories()
    }

    public func stop() async {
        await coalescer?.cancel()
        await monitor?.stop()
        coalescer = nil
        monitor = nil
        started = false
        activeStoredGeneration = nil
    }

    public func reconcileAfterWake() async {
        guard mode != .off else { return }
        _ = try? arena.applyMemoryPressure(.normal)
        await reconcileAll(reason: "wake")
        await refreshWatchedDirectories()
    }

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        guard mode != .off, !changes.isEmpty else { return }
        let semanticChanges = changes.filter(\.semantic)
        let changedNamespaces = Set(semanticChanges.map(\.namespace))
        let invalidatedProjectionIDs = Set(compiledProjectionProviders.compactMap { provider in
            provider.invalidationNamespaces.isDisjoint(with: changedNamespaces)
                ? nil
                : provider.projectionIdentifier
        })
        let projectionNamespaces = Set(compiledProjectionProviders.flatMap(\.invalidationNamespaces))
        let registrationChanges = semanticChanges.filter {
            !projectionNamespaces.contains($0.namespace)
        }

        // Projection-owned invalidations do not reread every other compiled
        // source. A Workshop status edge must not rescan/embed MemoryV2, and a
        // memory write must not replay Desk. Both remain background rebuilds.
        if registrationChanges.isEmpty, !invalidatedProjectionIDs.isEmpty {
            await reconcile(
                registrations: [],
                reason: "compiled_projection_invalidation",
                compiledProjectionIdentifiers: invalidatedProjectionIDs
            )
            return
        }
        await refreshDiscoveredSources()
        let all = await registry.allRegistrations()
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
        if requiresFullReconciliation {
            await reconcileAll(reason: "direct_invalidation")
        } else {
            await reconcile(
                registrations: Self.unique(selected),
                reason: "direct_invalidation",
                compiledProjectionIdentifiers: invalidatedProjectionIDs
            )
        }
        await refreshWatchedDirectories()
    }

    public func applyMemoryPressure(_ pressure: ContextArenaPressure) async throws -> ContextArenaTrimReceipt {
        let receipt = try arena.applyMemoryPressure(pressure)
        _ = await prewarmPlanner.setResourcePressure(pressure)
        try? await store.recordReceipt(ContextStoreReceipt(
            kind: .pressure,
            generationID: arena.currentSnapshot()?.generationID,
            summary: "context arena memory pressure",
            details: [
                "pressure": pressure.rawValue,
                "before_bytes": String(receipt.beforeLogicalBytes),
                "after_bytes": String(receipt.afterLogicalBytes),
                "evicted": String(receipt.evictedWarmEntryKeys.count),
            ]
        ))
        if pressure == .normal {
            await reconcileAll(reason: "pressure_normal")
        }
        return receipt
    }

    public func acquireSnapshot() throws -> ContextGenerationLease {
        try arena.acquireSnapshot()
    }

    private enum TurnPreparationPolicy {
        case live
        case frozen

        var recordsSideEffects: Bool {
            switch self {
            case .live: true
            case .frozen: false
            }
        }
    }

    public func prepareTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        try await prepareTurn(request, policy: .live)
    }

    /// Pin and select from the already-published generation without recovery,
    /// feedback mutation, prewarm continuity, or store receipts. The returned
    /// lease remains valid until the prepared turn is released.
    public func prepareFrozenTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        try await prepareTurn(request, policy: .frozen)
    }

    /// Pure revision read for before/after epoch coherence checks.
    public func frozenRevision() -> ContextFrozenRevision? {
        guard let generation = activeStoredGeneration,
              let arenaGenerationID = arena.currentSnapshot()?.generationID
        else { return nil }
        return ContextFrozenRevision(
            generationID: generation.generation.id,
            sourceFingerprint: generation.generation.sourceFingerprint,
            arenaGenerationID: arenaGenerationID
        )
    }

    private func prepareTurn(
        _ request: ContextTurnRequest,
        policy: TurnPreparationPolicy
    ) async throws -> ContextPreparedTurn {
        guard started, mode != .off else {
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        if activeStoredGeneration == nil, policy.recordsSideEffects {
            await reconcileAll(reason: "turn_generation_recovery")
        }
        guard let generation = activeStoredGeneration else {
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

            let personaPrefix = "persona/\(mirror.personaID.rawValue)/"
            let normalizedPersonaID = mirror.personaID.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let memoryPersonaPrefix = "memory-v2/personas/\(ContextStableID.digest(parts: [normalizedPersonaID]))/"
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
            let selectedSources = generation.sources.filter { source in
                source.descriptor.permittedSurfaces.contains(request.surface)
                    && request.allowedPrivacy.contains(source.descriptor.privacy)
                    && (source.descriptor.owner != "nativeagent.persona"
                        || source.descriptor.canonicalLocator.hasPrefix(personaPrefix))
            }
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
            if policy.recordsSideEffects {
                let slotScopedMemorySources = generation.sources.filter {
                    $0.descriptor.owner == "nativeagent.memory-v2"
                        && $0.descriptor.canonicalLocator.hasPrefix(memoryPersonaPrefix)
                }
                if !slotScopedMemorySources.isEmpty {
                    diagnostics(
                        "[context-flow] ERROR memory-scope vocabulary drift: "
                        + "\(slotScopedMemorySources.count) live memory source(s) are scoped by "
                        + "persona SLOT id \"\(mirror.personaID.rawValue)\" (prefix "
                        + "\(memoryPersonaPrefix)). MemoryV2 record persona ids are AGENT NAMES; "
                        + "a slot-id-scoped record means the two vocabularies merged. Memory is "
                        + "deliberately shared across persona slots — re-review that decision "
                        + "before shipping a per-slot memory shard."
                    )
                }
            }
            let allowedSourceIDs = Set(selectedSources.map(\.descriptor.id))
            let precoveredDocumentNames = Set(kernel.includedDocumentIDs.map {
                String($0.rawValue.dropLast(3))
            })
            let surfaceSuffix = "/surfaces/\(request.surface.rawValue).md"
            var precoveredSourceIDs = Set(selectedSources.lazy.filter { source in
                guard source.descriptor.owner == "nativeagent.persona" else { return false }
                let locator = source.descriptor.canonicalLocator
                if locator.hasSuffix(surfaceSuffix) { return true }
                let documentName = locator.split(separator: "/").last.map(String.init)?
                    .replacingOccurrences(of: ".md", with: "")
                return documentName.map(precoveredDocumentNames.contains) ?? false
            }.map(\.descriptor.id))
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
            let userPrecoverage = Self.generatedUserProjectionOutcome(
                mirror: mirror,
                kernel: kernel,
                selectedSources: selectedSources,
                generation: generation
            )
            precoveredSourceIDs.formUnion(userPrecoverage.precoveredSourceIDs)
            if policy.recordsSideEffects,
               let line = precoverageReporter.message(for: userPrecoverage) {
                diagnostics(line)
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
            let protectedCorrectionAtomIDs = Set(generation.atoms.lazy.filter { atom in
                atom.validToGeneration == nil
                    && atom.draft.kind == .correction
                    && atom.draft.authority == .explicitCorrection
                    && allowedSourceIDs.contains(atom.draft.sourceID)
                    && request.allowedPrivacy.contains(atom.draft.privacy)
                    && atom.draft.permittedSurfaces.contains(request.surface)
            }.map(\.draft.id))
            let makeNeed: (Int) -> NeedSignal = { characterBudget in
                NeedSignal(
                    message: request.userMessage,
                    surface: request.surface,
                    origin: request.origin,
                    authorization: ContextSelectionAuthorization(
                        allowedOrigins: [request.origin],
                        allowedPrivacy: request.allowedPrivacy,
                        allowedSourceIDs: allowedSourceIDs,
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
                    precoveredSourceIDs: precoveredSourceIDs,
                    mandatoryAtomIDs: protectedCorrectionAtomIDs,
                    queryEmbedding: request.queryEmbedding,
                    queryEmbeddingModelFingerprint: request.queryEmbeddingModelFingerprint,
                    availableGenerationID: generation.generation.id,
                    characterBudget: characterBudget,
                    cacheState: .hit
                )
            }
            var need = makeNeed(request.characterBudget)
            let packet: ContextPacket
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
                packet = try selector.select(
                    need,
                    from: generation,
                    pinnedTo: lease.snapshot,
                    measureLatency: true
                )
            }
            if policy.recordsSideEffects {
                recordFeedback(
                    signal: .selection,
                    atomIDs: packet.receipt.selectedAtomIDs,
                    evidenceIDs: [packet.receipt.id],
                    generationID: generation.generation.id
                )
                Task { [weak self] in
                    await self?.observePrewarmContinuity(
                        request: request,
                        packet: packet,
                        generation: generation,
                        snapshot: lease.snapshot
                    )
                }
                let store = self.store
                Task.detached(priority: .background) {
                    try? await store.recordReceipt(ContextStoreReceipt(
                        kind: .selection,
                        generationID: packet.generationID,
                        summary: "context selection",
                        details: [
                            "receipt_id": packet.receipt.id,
                            "surface": request.surface.rawValue,
                            "selected": String(packet.selectedItems.count),
                            "pointers": String(packet.expandablePointers.count),
                            "mandatory_coverage": String(packet.receipt.mandatoryCoverage),
                            "characters": String(packet.characterCount),
                            "selection_microseconds": String(
                                packet.receipt.measuredSelectionMicroseconds ?? 0
                            ),
                        ]
                    ))
                }
            }
            let feedbackHandler: (@Sendable (
                ContextFeedbackSignal,
                [ContextAtomID],
                [String]
            ) async -> Void)?
            if policy.recordsSideEffects {
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
            return ContextPreparedTurn(
                mode: mode,
                kernel: kernel,
                mirror: mirror,
                packet: packet,
                lease: lease,
                generation: generation,
                need: need,
                feedbackHandler: feedbackHandler
            )
        } catch {
            lease.release()
            throw error
        }
    }

    public func health() async -> ContextFlowCoordinatorHealth {
        let storeHealth = try? await store.healthSnapshot()
        let metrics = arena.metrics()
        return ContextFlowCoordinatorHealth(
            mode: mode,
            started: started,
            activeStoreGenerationID: storeHealth?.activeGenerationID,
            activeArenaGenerationID: metrics.currentGenerationID,
            registeredSourceCount: await registry.allRegistrations().count,
            degradedSourceCount: storeHealth?.degradedSources ?? 0,
            arenaMetrics: metrics,
            pendingPrewarmHints: await prewarmPlanner.pendingHintCount(),
            prewarmUsefulnessReceipts: await prewarmPlanner.recentUsefulnessReceipts().count,
            lastReconciledAt: lastReconciledAt,
            lastError: lastError
        )
    }

    @discardableResult
    public func submitPrewarm(_ event: ContextPrewarmEvent) async -> ContextPrewarmPlanningReceipt {
        let submission = await prewarmPlanner.submit(event)
        let planning = await prewarmPlanner.processNext()
        if let plan = planning.plan {
            for scope in Set(plan.items.map(\.cause)) {
                prewarmPlans[scope] = plan
            }
        }
        let receipt = ContextStoreReceipt(
            kind: .prewarm,
            generationID: planning.plan?.items.first?.candidate.generationID,
            summary: "context prewarm planning",
            details: [
                "submission": String(describing: submission.outcome),
                "outcome": String(describing: planning.outcome),
                "considered": String(planning.consideredAtomCount),
                "dropped": String(planning.droppedAtomCount),
                "planned": String(planning.plan?.items.count ?? 0),
            ]
        )
        let store = self.store
        Task.detached(priority: .background) {
            try? await store.recordReceipt(receipt)
        }
        return planning
    }

    @discardableResult
    public func submitPrewarm(
        kind: ContextPrewarmHintKind,
        id: String,
        terms: [String],
        revision: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async -> ContextPrewarmPlanningReceipt {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let generation = activeStoredGeneration, !normalizedID.isEmpty else {
            return ContextPrewarmPlanningReceipt(
                outcome: .empty,
                plan: nil,
                consideredAtomCount: 0,
                droppedAtomCount: 0,
                elapsedNanoseconds: 0,
                remainingQueueCount: await prewarmPlanner.pendingHintCount()
            )
        }
        let tokens = Self.prewarmTokens(terms.joined(separator: " "))
        let ranked = generation.atoms.compactMap { atom -> (ContextStoredAtom, Int)? in
            guard atom.validToGeneration == nil,
                  atom.draft.injectionPolicy != .neverInject else {
                return nil
            }
            let searchable = (
                atom.draft.headingPath.joined(separator: " ") + " "
                + atom.draft.triggers.joined(separator: " ") + " "
                + atom.draft.body
            ).lowercased()
            let overlap = tokens.reduce(into: 0) { count, token in
                if searchable.contains(token) { count += 1 }
            }
            guard overlap > 0 || tokens.isEmpty else { return nil }
            return (atom, overlap)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.draft.authority.rank != $1.0.draft.authority.rank {
                return $0.0.draft.authority.rank > $1.0.draft.authority.rank
            }
            return $0.0.draft.id < $1.0.draft.id
        }.prefix(32)
        let candidates = ranked.map { atom, overlap in
            ContextPrewarmCandidate(
                atomID: atom.draft.id,
                generationID: generation.generation.id,
                sourceFingerprint: generation.generation.sourceFingerprint,
                estimatedByteCount: atom.draft.body.utf8.count
                    + ((atom.draft.embedding?.values.count ?? 0) * MemoryLayout<Float>.stride),
                likelihood: min(1, 0.25 + (Double(overlap) * 0.15))
            )
        }
        let eventID = ContextStableID.digest(parts: [
            "context-owner-prewarm-v1",
            kind.rawValue,
            normalizedID,
            String(revision),
        ] + candidates.map { $0.atomID.rawValue })
        let event: ContextPrewarmEvent
        switch kind {
        case .session:
            event = .session(ContextSessionPrewarmHint(
                sessionID: normalizedID,
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .desk:
            event = .desk(ContextDeskPrewarmHint(
                deskID: normalizedID,
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .workshopExecution:
            event = .workshopExecution(ContextWorkshopPrewarmHint(
                executionID: normalizedID,
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .file:
            event = .file(ContextFilePrewarmHint(
                sourceID: ContextSourceID(rawValue: normalizedID),
                contentFingerprint: ContextStableID.digest(parts: terms),
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .toolResult:
            event = .toolResult(ContextToolResultPrewarmHint(
                toolCallID: normalizedID,
                resultFingerprint: ContextStableID.digest(parts: terms),
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .cognitive:
            event = .cognitive(ContextCognitivePrewarmHint(
                workspaceID: normalizedID,
                activationID: eventID,
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        case .organism:
            event = .organism(ContextOrganismPrewarmHint(
                predictionID: normalizedID,
                eventID: eventID,
                revision: revision,
                candidates: candidates
            ))
        }
        return await submitPrewarm(event)
    }

    private func observePrewarmContinuity(
        request: ContextTurnRequest,
        packet: ContextPacket,
        generation: ContextStoredGeneration,
        snapshot: ContextGenerationSnapshot
    ) async {
        let selectedIDs = Set(packet.receipt.selectedAtomIDs)
        let globalKinds: Set<ContextPrewarmHintKind> = [.desk, .file, .toolResult, .organism]
        let globalScopes = prewarmPlans.keys.filter { globalKinds.contains($0.kind) }
        let relevantScopes = Array(Set(prewarmScopes(for: request) + globalScopes)).sorted()
        for scope in relevantScopes {
            guard let plan = prewarmPlans.removeValue(forKey: scope) else { continue }
            let validation = await prewarmPlanner.validate(plan)
            let warmed = Set(validation.validItems.compactMap { item -> ContextAtomID? in
                let atomID = item.candidate.atomID
                return snapshot.hotEntries.contains { $0.key.id == atomID.rawValue }
                    || snapshot.warmEntries.contains { $0.key.id == atomID.rawValue }
                    ? atomID
                    : nil
            })
            let usefulness = await prewarmPlanner.recordUsefulness(
                for: plan,
                warmedAtomIDs: warmed,
                independentlySelectedAtomIDs: selectedIDs
            )
            let receipt = ContextStoreReceipt(
                kind: .prewarm,
                generationID: generation.generation.id,
                summary: "context prewarm usefulness",
                details: [
                    "scope": "\(scope.kind.rawValue):\(scope.id)",
                    "requested": String(usefulness.requestedAtomIDs.count),
                    "warmed": String(usefulness.warmedAtomIDs.count),
                    "useful": String(usefulness.usefulAtomIDs.count),
                    "usefulness": String(usefulness.usefulness),
                    "authority_granted": String(usefulness.authorityGranted),
                ]
            )
            let store = self.store
            Task.detached(priority: .background) {
                try? await store.recordReceipt(receipt)
            }
        }

        let atomByID = Dictionary(uniqueKeysWithValues: generation.atoms.map {
            ($0.draft.id, $0.draft)
        })
        let candidateIDs = Array(Set(
            packet.receipt.selectedAtomIDs + packet.receipt.pointerAtomIDs
        )).sorted()
        let candidates = candidateIDs.compactMap { atomID -> ContextPrewarmCandidate? in
            guard let atom = atomByID[atomID] else { return nil }
            return ContextPrewarmCandidate(
                atomID: atomID,
                generationID: generation.generation.id,
                sourceFingerprint: generation.generation.sourceFingerprint,
                estimatedByteCount: atom.body.utf8.count
                    + ((atom.embedding?.values.count ?? 0) * MemoryLayout<Float>.stride),
                likelihood: selectedIDs.contains(atomID) ? 1 : 0.5
            )
        }
        guard !candidates.isEmpty else { return }
        for scope in relevantScopes {
            prewarmRevision &+= 1
            let eventID = ContextStableID.digest(parts: [
                "context-prewarm-v1",
                scope.kind.rawValue,
                scope.id,
                packet.receipt.id,
                String(prewarmRevision),
            ])
            let event: ContextPrewarmEvent
            switch scope.kind {
            case .session:
                event = .session(ContextSessionPrewarmHint(
                    sessionID: scope.id,
                    eventID: eventID,
                    revision: prewarmRevision,
                    candidates: candidates
                ))
            case .workshopExecution:
                event = .workshopExecution(ContextWorkshopPrewarmHint(
                    executionID: scope.id,
                    eventID: eventID,
                    revision: prewarmRevision,
                    candidates: candidates
                ))
            case .cognitive:
                event = .cognitive(ContextCognitivePrewarmHint(
                    workspaceID: scope.id,
                    activationID: eventID,
                    eventID: eventID,
                    revision: prewarmRevision,
                    candidates: candidates
                ))
            default:
                continue
            }
            _ = await submitPrewarm(event)
        }
    }

    private func prewarmScopes(for request: ContextTurnRequest) -> [ContextPrewarmScope] {
        var scopes: [ContextPrewarmScope] = []
        if let sessionID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            scopes.append(ContextPrewarmScope(kind: .session, id: sessionID))
        }
        if request.surface == .workshop {
            let executionID = request.activeTask?.trimmingCharacters(in: .whitespacesAndNewlines)
            scopes.append(ContextPrewarmScope(
                kind: .workshopExecution,
                id: executionID?.isEmpty == false ? executionID! : "missions"
            ))
        }
        if !request.cognitiveActivation.isEmpty {
            scopes.append(ContextPrewarmScope(kind: .cognitive, id: "active-workspace"))
        }
        return Array(Set(scopes)).sorted()
    }

    private func feedbackSnapshot(
        for generation: ContextStoredGeneration
    ) -> ContextFeedbackSnapshot {
        let seeds = generation.atoms.map { atom in
            ContextFeedbackSeed(
                atomID: atom.draft.id,
                authority: atom.draft.authority,
                privacy: atom.draft.privacy,
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
        return (try? feedbackReducer.rebuild(
            seeds: seeds,
            events: applicable,
            through: Self.feedbackTimeBucket()
        )) ?? (try! feedbackReducer.rebuild(seeds: seeds, events: []))
    }

    private func recordFeedback(
        signal: ContextFeedbackSignal,
        atomIDs: [ContextAtomID],
        evidenceIDs: [String],
        generationID: Int64
    ) {
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
        feedbackEvents.append(event)
        if feedbackEvents.count > 4_096 {
            feedbackEvents.removeFirst(feedbackEvents.count - 4_096)
        }
        let receipt = ContextStoreReceipt(
            kind: .feedback,
            generationID: generationID,
            summary: "context feedback",
            details: [
                "event_id": event.id,
                "signal": Self.feedbackSignalName(signal),
                "atoms": String(ids.count),
                "time_bucket": String(bucket),
            ]
        )
        let store = self.store
        Task.detached(priority: .background) {
            try? await store.recordReceipt(receipt)
        }
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
    static func generatedUserProjectionPrecoverage(
        mirror: RequiredDocumentMirror,
        kernel: StablePromptKernel,
        selectedSources: [ContextStoredSource],
        generation: ContextStoredGeneration
    ) -> Set<ContextSourceID> {
        generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: kernel,
            selectedSources: selectedSources,
            generation: generation
        ).precoveredSourceIDs
    }

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

    private static func prewarmTokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap {
            let token = String($0)
            return token.count >= 2 ? token : nil
        })
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

    private func observe(_ event: ContextDirectoryEvent) async {
        await coalescer?.enqueue(event.directory)
        if event.requiresRearm {
            // Reconciliation runs before the watch set is rebuilt. Parent
            // watches remain alive and catch replacement of the child path.
            await monitor?.setDirectories([])
        }
    }

    private func reconcile(dirtyDirectories: Set<URL>) async {
        await refreshDiscoveredSources()
        guard !Task.isCancelled else { return }
        var affected: [ContextSourceRegistration] = []
        for directory in dirtyDirectories.sorted(by: { $0.path < $1.path }) {
            if let rows = try? await registry.registrations(affectedBy: directory) {
                affected.append(contentsOf: rows)
            }
        }
        await reconcile(
            registrations: Self.unique(affected),
            reason: "directory_event",
            compiledProjectionIdentifiers: []
        )
        await refreshWatchedDirectories()
    }

    private func reconcileAll(reason: String) async {
        await refreshDiscoveredSources()
        guard !Task.isCancelled else { return }
        await reconcile(
            registrations: await registry.allRegistrations(),
            reason: reason,
            compiledProjectionIdentifiers: Set(
                compiledProjectionProviders.map(\.projectionIdentifier)
            )
        )
    }

    private func reconcile(
        registrations: [ContextSourceRegistration],
        reason: String,
        compiledProjectionIdentifiers: Set<String>
    ) async {
        guard mode != .off, !Task.isCancelled else { return }
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
        do {
            let active = try await store.loadActiveGeneration()
            let previousBySource = Self.previousCompiledSources(active)
            var changedSources: [ContextCompiledSource] = []
            var removedSourceIDs = Set<ContextSourceID>()
            var successfulSources: [ContextSourceID: ContextCompiledSource] = [:]

            for registration in batch.registrations {
                let sourceID = registration.descriptor.id
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
                    successfulSources[sourceID] = compiled
                    if compiled.sourceHash != previousBySource[sourceID]?.sourceHash
                        || compiled.descriptor != previousBySource[sourceID]?.descriptor {
                        changedSources.append(compiled)
                    }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    compileFailures[sourceID] = String(reflecting: type(of: error))
                }
            }

            if !batch.compiledProjectionIdentifiers.isEmpty {
                for provider in compiledProjectionProviders where
                    batch.compiledProjectionIdentifiers.contains(provider.projectionIdentifier) {
                    let result = try await provider.compiledProjection(previousSources: previousBySource)
                    for source in result.changedSources {
                        if changedSources.contains(where: { $0.descriptor.id == source.descriptor.id }) {
                            throw ContextFlowCoordinatorError.duplicateProjectedSource(source.descriptor.id)
                        }
                        changedSources.append(source)
                    }
                    removedSourceIDs.formUnion(result.removedSourceIDs)
                }
            }

            await commit(ReconciliationCandidate(
                batch: batch,
                changedSources: changedSources,
                removedSourceIDs: removedSourceIDs,
                successfulSources: successfulSources,
                compileFailures: compileFailures
            ))
        } catch is CancellationError {
            // Cancellation is control flow, not source degradation. Demand
            // stays pending and the next owner edge will retry it.
            return
        } catch {
            await commitFailure(error, compileFailures: compileFailures, for: batch)
        }
    }

    private func commit(_ candidate: ReconciliationCandidate) async {
        guard await beginPublication(for: candidate.batch.requestID) else { return }
        defer { finishPublication() }

        do {
            let persistedDegradedCount = (try? await store.healthSnapshot().degradedSources) ?? 0
            let hasUnknownPersistedDegradation = persistedDegradedCount > degradedSourceIDs.count
            for (sourceID, error) in candidate.compileFailures.sorted(by: { $0.key < $1.key }) {
                try? await store.markSourceDegraded(sourceID, error: error)
                degradedSourceIDs.insert(sourceID)
            }

            var changedBySource = Dictionary(uniqueKeysWithValues: candidate.changedSources.map {
                ($0.descriptor.id, $0)
            })
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
                return
            }

            guard let stored = try await store.loadActiveGeneration() else {
                throw ContextFlowCoordinatorError.activeGenerationUnavailable
            }
            let mirrors = try await mirrorProvider.requiredDocumentMirrors()
            let snapshot = try Self.makeArenaSnapshot(stored: stored, mirrors: mirrors)
            let currentSnapshot = arena.currentSnapshot()
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
                activeStoredGeneration = stored
            case .retainedLastGood(let failure, _):
                throw ContextFlowCoordinatorError.arenaPublicationFailed(String(describing: failure))
            }
            lastReconciledAt = Date()
            acknowledge(candidate.batch)
            await pruneStoreIfDue()
        } catch is CancellationError {
            // A cancelled caller must not mint an orange health incident or a
            // durable degradation receipt. Pending demand remains retryable.
            return
        } catch {
            recordReconciliationFailure(error)
        }
    }

    /// 2026-07-21 audit fix: bound context.sqlite. store.prune() existed but
    /// had zero production callers — generations, atom/source versions,
    /// embeddings, FTS rows, and per-turn receipts accumulated forever. Runs
    /// after successful commits at most once per pruneInterval; failures are
    /// deliberately non-fatal (the next successful commit retries).
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
                    // VACUUM is best-effort disk reclamation; a failure just
                    // defers to the next due window.
                }
            }
        } catch {
            // Pruning is maintenance, never a reconcile blocker.
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
            try? await store.markSourceDegraded(sourceID, error: compileError)
            degradedSourceIDs.insert(sourceID)
        }
        recordReconciliationFailure(error)
    }

    private func beginPublication(for requestID: UInt64) async -> Bool {
        while publicationInProgress {
            await withCheckedContinuation { continuation in
                publicationWaiters.append(continuation)
            }
        }
        guard requestID == nextReconciliationRequestID else { return false }
        publicationInProgress = true
        return true
    }

    private func finishPublication() {
        publicationInProgress = false
        let waiters = publicationWaiters
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
        let store = self.store
        let generationID = arena.currentSnapshot()?.generationID
        let errorType = String(reflecting: type(of: error))
        Task.detached(priority: .background) {
            try? await store.recordReceipt(ContextStoreReceipt(
                kind: .degraded,
                generationID: generationID,
                summary: "context reconciliation failed",
                details: ["error_type": errorType]
            ))
        }
    }

    private func refreshWatchedDirectories() async {
        guard mode != .off else { return }
        await monitor?.setDirectories(await registry.watchedDirectories())
    }

    private func refreshDiscoveredSources() async {
        guard let refresher = mirrorProvider as? any ContextSourceRegistrationRefreshing else {
            return
        }
        do {
            try await refresher.refreshContextSources(in: registry)
        } catch is CancellationError {
            return
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Projection

    private static func previousCompiledSources(
        _ stored: ContextStoredGeneration?
    ) -> [ContextSourceID: ContextCompiledSource] {
        guard let stored else { return [:] }
        let atomsBySource = Dictionary(grouping: stored.atoms.map(\.draft), by: \.sourceID)
        let relationships = stored.relationships.map(\.draft)
        var result: [ContextSourceID: ContextCompiledSource] = [:]
        for source in stored.sources {
            let sourceAtoms = atomsBySource[source.descriptor.id] ?? []
            let atomIDs = Set(sourceAtoms.map(\.id))
            result[source.descriptor.id] = ContextCompiledSource(
                descriptor: source.descriptor,
                sourceHash: source.sourceHash,
                atoms: sourceAtoms,
                relationships: relationships.filter { atomIDs.contains($0.sourceAtomID) }
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
                retentionPriority: atom.authority.rank,
                lastAccessOrdinal: 0
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
