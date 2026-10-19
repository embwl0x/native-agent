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

actor PersonaContextFlowProvider: ContextRequiredDocumentMirrorProviding {
    private struct Build: Sendable {
        let mirrors: [RequiredDocumentMirror]
        let registrations: [ContextSourceRegistration]
        let allowedRoots: [URL]
    }

    private static let owner = ContextPersonaSourceNaming.owner
    private static let surfaces: [ContextSurface] = [
        .chat, .telegram, .ios, .slack, .workshop, .bridge, .bot,
    ]

    private let compiler: PersonaCompiler
    private var cachedBuild: Build?

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        let standardizedRoot = dataRoot.standardizedFileURL
        let persona = standardizedRoot
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: standardizedRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: standardizedRoot)
        self.compiler = PersonaCompiler(engine: persona)
    }

    func refreshContextSources(in registry: ContextSourceRegistry) async throws {
        let build = try await makeBuild()
        for root in build.allowedRoots {
            try await registry.addAllowedRoot(root)
        }
        let owners = Set(build.registrations.map(\.descriptor.owner)).union([
            Self.owner,
            "nativeagent.markdown.skill-bodies",
        ])
        for owner in owners.sorted() {
            try await registry.replaceOwned(owner: owner, with: build.registrations)
        }
        cachedBuild = build
    }

    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] {
        if let cachedBuild { return cachedBuild.mirrors }
        let build = try await makeBuild()
        cachedBuild = build
        return build.mirrors
    }

    private func makeBuild() async throws -> Build {
        let requestedOverride = PersonaSelection.current()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedOverride = requestedOverride?.isEmpty == false ? requestedOverride : nil
        let snapshots = try await compiler.contextSourceSnapshots(
            surfaces: Self.surfaces.map(\.rawValue),
            personaOverrides: selectedOverride.map { ["chat": $0] } ?? [:]
        )

        var registrations: [ContextSourceID: ContextSourceRegistration] = [:]
        var allowedRoots = Set<URL>()
        for snapshot in snapshots {
            allowedRoots.insert(snapshot.personaRoot)
            for document in snapshot.documents {
                let locator = Self.locator(
                    personaID: snapshot.packet.personaId,
                    document: document
                )
                let sourceID = ContextStableID.source(owner: Self.owner, locator: locator)
                let surface = document.surfaceOverride
                    ? ContextSurface(rawValue: String(document.id.dropFirst("surface:".count)))
                    : nil
                let descriptor = ContextSourceDescriptor(
                    id: sourceID,
                    owner: Self.owner,
                    kind: .persona,
                    canonicalLocator: locator,
                    authority: Self.authority(for: document.id),
                    privacy: .localPrivate,
                    permittedSurfaces: surface.map { [$0] } ?? Set(Self.surfaces),
                    injectionPolicy: Self.injectionPolicy(for: document.id)
                )
                let registration = ContextSourceRegistration(
                    descriptor: descriptor,
                    fileURL: document.fileURL,
                    allowedRoot: snapshot.personaRoot,
                    requiredPersonaDocument: Self.requiredKind(for: document.id),
                    personaID: ContextPersonaID(rawValue: snapshot.packet.personaId)
                )
                registrations[sourceID] = registration
            }
        }

        let grouped = Dictionary(grouping: snapshots, by: { $0.packet.personaId })
        let mirrors = try grouped.keys.sorted().map { personaID in
            try Self.makeMirror(
                personaID: personaID,
                snapshots: grouped[personaID] ?? [],
                requestedPersonaOverride: selectedOverride
            )
        }
        return Build(
            mirrors: mirrors,
            registrations: registrations.values.sorted { $0.descriptor.id < $1.descriptor.id },
            allowedRoots: allowedRoots.sorted { $0.path < $1.path }
        )
    }

    static func makeMirror(
        personaID: String,
        snapshots: [PersonaContextSourceSnapshot],
        requestedPersonaOverride: String? = nil
    ) throws -> RequiredDocumentMirror {
        guard let canonical = snapshots.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard !snapshots.contains(where: { snapshot in
            snapshot.documents.contains { ContextSecretContentPolicy.containsSecretLikeContent($0.content) }
                || snapshot.packet.activeDocs.values.contains {
                    ContextSecretContentPolicy.containsSecretLikeContent($0)
                }
        }) else {
            throw ContextMarkdownCompilerError.secretLikeContent
        }
        let canonicalDocuments = canonical.documents
            .filter { !$0.surfaceOverride }
            .sorted { $0.canonicalOrder < $1.canonicalOrder }
        let documents = try canonicalDocuments.map { source in
            // PROVENANCE, derived from the SAME descriptor inputs `makeBuild`
            // registers this document's context source with — the locator and
            // the permitted-surface set. Carrying it on the mirror is what lets
            // the stable-prefix renderer prove a surface permission instead of
            // re-deriving one from a locator string. A canonical (non-override)
            // document permits every surface; a surface override is not a
            // required document and never reaches this map.
            let locator = Self.locator(personaID: personaID, document: source)
            return try RequiredDocument(
                id: RequiredDocumentID(rawValue: "\(source.id).md"),
                canonicalOrder: source.canonicalOrder,
                sourceHash: ContextStableID.digest(parts: [source.content]),
                text: source.content,
                tokenCount: estimatedTokenCount(source.content),
                sourceID: ContextStableID.source(owner: Self.owner, locator: locator),
                permittedSurfaces: Set(Self.surfaces)
            )
        }
        let fingerprint = ContextStableID.digest(parts: documents.flatMap {
            [$0.id.rawValue, $0.sourceHash]
        })
        let contextPersonaID = ContextPersonaID(rawValue: personaID)
        let kernels = try snapshots.sorted { $0.packet.surface < $1.packet.surface }.map { snapshot in
            let activeKernelDocuments = snapshot.documents.filter {
                !$0.surfaceOverride && ($0.id == "SOUL" || $0.id == "VOICE")
            }.sorted { $0.canonicalOrder < $1.canonicalOrder }
            let includedIDs = activeKernelDocuments.map { RequiredDocumentID(rawValue: "\($0.id).md") }
            let renderedPrompt = PersonaCompiler.renderPrompt(
                documents: snapshot.packet.activeDocs.filter {
                    $0.key == "SOUL" || $0.key == "VOICE"
                },
                surface: snapshot.packet.surface
            )
            let surfaceGuidance = PersonaCompiler.renderPrompt(
                documents: snapshot.packet.activeDocs.filter { $0.key == "surface:\(snapshot.packet.surface)" },
                surface: snapshot.packet.surface
            )
            guard !ContextSecretContentPolicy.containsSecretLikeContent(renderedPrompt),
                  !ContextSecretContentPolicy.containsSecretLikeContent(surfaceGuidance) else {
                throw ContextMarkdownCompilerError.secretLikeContent
            }
            let key = try StablePromptKernelKey(
                personaID: contextPersonaID,
                surfaceVariant: ContextSurfaceVariant(rawValue: snapshot.packet.surface),
                sourceFingerprint: fingerprint
            )
            return try StablePromptKernel(
                key: key,
                renderedPrompt: renderedPrompt,
                includedDocumentIDs: includedIDs,
                tokenCount: estimatedTokenCount(renderedPrompt + surfaceGuidance),
                requestedPersonaOverride: snapshot.packet.surface == ContextSurface.chat.rawValue
                    ? requestedPersonaOverride : nil,
                surfaceGuidance: surfaceGuidance
            )
        }
        return try RequiredDocumentMirror(
            personaID: contextPersonaID,
            sourceFingerprint: fingerprint,
            documents: documents,
            kernels: kernels
        )
    }

    private static func locator(
        personaID: String,
        document: PersonaContextDocumentSource
    ) -> String {
        let component = document.surfaceOverride
            ? "surfaces/\(document.id.dropFirst("surface:".count)).md"
            : "\(document.id).md"
        return "persona/\(personaID)/\(component)"
    }

    private static func authority(for documentID: String) -> ContextAuthority {
        switch documentID {
        case "SOUL", "VOICE": .identity
        case "USER": .explicitCorrection
        case "MEMORY": .approved
        default: .canonical
        }
    }

    static func injectionPolicy(for documentID: String) -> ContextInjectionPolicy {
        switch documentID {
        case "SOUL", "VOICE": .always
        case let value where value.hasPrefix("surface:"): .always
        default: .adaptive
        }
    }

    private static func requiredKind(for documentID: String) -> RequiredPersonaDocumentKind? {
        guard !documentID.hasPrefix("surface:") else { return nil }
        return RequiredPersonaDocumentKind(rawValue: "\(documentID).md")
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 3) / 4)
    }
}

public struct NativeContextFlowConfiguration: Sendable, Equatable {
    public static let modeEnvironmentKey = "NATIVE_AGENT_CONTEXT_FLOW_MODE"
    public static let modeDefaultsKey = "contextFlowMode"
    static let budgetDefaultsKey = "contextFlowRAMMiB"

    let mode: ContextFlowMode
    let budget: ContextArenaBudget

    public static func initializeMissingInnerLifeMode(defaults: UserDefaults) {
        guard defaults.object(forKey: modeDefaultsKey) == nil else { return }
        defaults.set(ContextFlowMode.active.rawValue, forKey: modeDefaultsKey)
    }

    static func resolve(dataRoot: URL) -> Self {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let isPublicSafe = NativeAgentPublicSafety.isPublicSafeMode(environment: environment)
        let preOnboarding = isPublicSafe
            && !NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        let explicitMode = environment[modeEnvironmentKey]
            .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
            ?? defaults.string(forKey: modeDefaultsKey)
                .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
        let mode: ContextFlowMode = preOnboarding ? .off : (explicitMode ?? .active)
        let budget = ContextArenaBudget(
            rawValue: defaults.integer(forKey: budgetDefaultsKey)
        ) ?? .default
        return Self(mode: mode, budget: budget)
    }
}

public struct NativeContextFlowModeStatus: Sendable, Equatable {
    public let effectiveMode: ContextFlowMode
}

/// A configured runtime that could not start. Carried to the turn that needs
/// it, so the reply names the cause instead of going out without context.
public struct NativeContextFlowStartupError: Error, LocalizedError {
    public let detail: String
    public var errorDescription: String? { "Context Flow could not start: \(detail)" }
}

/// The live runtime's health read has a distinct configured-off result: no
/// coordinator is expected in that case, unlike an unavailable read.
public enum ContextFlowObservatoryHealthState: Sendable, Equatable {
    case unavailable
    case off
    case health(ContextFlowCoordinatorHealth)
}

public actor NativeContextFlowRuntime: ContextTurnPreparing {
    private let dataRoot: URL
    private var coordinator: ContextFlowCoordinator?
    private var memoryRuntime: SwiftNativeMemoryV2?
    private let memoryPressureObserver: DispatchContextMemoryPressureObserver?
    /// One kqueue-backed invalidation reader over the canonical Desk feed and
    /// Workshop execution records. It carries no payload and owns no work state;
    /// every edge makes the existing ContextFlow coordinator reread the stores.
    private var residentWorkObservationTask: Task<Void, Never>?
    private var terminalResidentWorkRecordPaths: Set<String> = []
    /// The startup in flight. Waiters await this task, so a turn or a quit
    /// lends its priority to the launch's utility-priority startup instead of
    /// parking behind it on a busy Mac (a continuation lends nothing).
    private var startup: Task<Void, Never>?
    private var personaPickerReconcile: Task<Void, Never>?
    private var semanticQueryCache: [String: ContextQueryEmbeddingValue] = [:]
    private var semanticQueryCacheOrder: [String] = []
    static let maximumConcurrentSemanticQueries = 8
    private var semanticQueryTickets: [String: ContextQueryEmbeddingTicket] = [:]
    private var semanticQueryTasks: [String: Task<Void, Never>] = [:]
    private var semanticQueryEpoch: UInt64 = 0
    private var startupFailedClosed = false
    /// Why the configured runtime has no coordinator. The next turn retries
    /// startup and, if it fails again, stops with this instead of replying
    /// without context.
    private var startupFailure: String?
    /// Packet provenance: accepted with each published memory generation,
    /// read at prepare time to resolve selected memory atoms → record IDs.
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
        if let startup { return await startup.value }
        guard coordinator == nil else { return }
        // Cleared by the task itself, so a stop-then-start after it finishes
        // never mistakes the finished one for a startup in flight.
        let startup = Task {
            await performStartup()
            self.startup = nil
        }
        self.startup = startup
        await startup.value
    }

    private func performStartup() async {
        startupFailedClosed = false
        startupFailure = nil
        let configuration = resolvedConfiguration()
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
            let coordinator = ContextFlowCoordinator(
                mode: configuration.mode,
                store: store,
                arena: arena,
                registry: registry,
                compiler: NativeContextMarkdownCompiler(memory: memory),
                mirrorProvider: provider,
                compiledProjectionProviders: [NativeMemoryContextProjection(
                    memory: memory,
                    provenanceIndex: memoryProvenanceIndex,
                    dataRoot: dataRoot
                ),
                NativeResidentWorkContextProjection(dataRoot: dataRoot),
                NativeKnowledgeGraphContextProjection(dataRoot: dataRoot),
                NativeStudioContextProjection(dataRoot: dataRoot),
                SensesContextProjection()]
            )
            memoryRuntime = memory
            self.coordinator = coordinator
            await startResidentWorkObservationIfNeeded()
            if usesLiveAppBody {
                // 2026-09-06: the installed sink is the pin sink, put in place
                // at app launch and independent of this runtime. Context Flow
                // subscribes to it here instead of owning it, so a GROWTH.md
                // write retires its pins with Context Flow off too.
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
                // Only Context Flow's subscription goes; the pin sink stays
                // installed, so pins still rebuild after a failed startup.
                await ContextFlowInvalidationRelay.shared.set(nil)
            }
            coordinator = nil
            memoryRuntime = nil
            startupFailedClosed = true
            startupFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await memoryPressureObserver?.stop()
            residentWorkObservationTask?.cancel()
            residentWorkObservationTask = nil
            nativeLog("[context-flow] start failed closed: %@", String(describing: error))
        }
    }

    public func stop() async {
        await startup?.value
        semanticQueryEpoch &+= 1
        semanticQueryTasks.values.forEach { $0.cancel() }
        semanticQueryTasks.removeAll()
        semanticQueryTickets.removeAll()
        semanticQueryCache.removeAll()
        semanticQueryCacheOrder.removeAll()
        await memoryPressureObserver?.stop()
        residentWorkObservationTask?.cancel()
        residentWorkObservationTask = nil
        if usesLiveAppBody {
            await ContextFlowInvalidationRelay.shared.set(nil)
        }
        await coordinator?.stop()
        coordinator = nil
        memoryRuntime = nil
    }

    public func reloadConfiguration() async {
        await stop()
        await start()
    }

    /// Persist and hot-apply the single production Context Flow mode. Public
    /// pre-onboarding safety is still resolved inside `start()` and can force
    /// the effective mode off regardless of the requested preference.
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

    /// Eagerly rebuild after the Mac picker changes. `prepareContextTurn` also
    /// requests it, without waiting: a turn whose kernel predates the selection
    /// gets the persona receipt, never the prior persona.
    public func personaPickerDidChange() async {
        await reconcilePersonaPickerIfNeeded()
    }

    private func requestPersonaPickerReconcile() {
        guard personaPickerReconcile == nil else { return }
        personaPickerReconcile = Task {
            await reconcilePersonaPickerIfNeeded()
            personaPickerReconcile = nil
        }
    }

    private func normalizedPersonaOverride() -> String? {
        let value = PersonaSelection.current()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func reconcilePersonaPickerIfNeeded() async {
        guard let coordinator else { return }
        // Only the immutable published kernel can acknowledge a selection.
        // Sampling preferences before/after an awaited build loses changes
        // (including ABA); a cached provider build may not have published yet.
        let lease = try? await coordinator.acquireSnapshot()
        let chatKernels = lease?.snapshot.requiredDocumentMirrors.compactMap {
            $0.kernel(for: ContextSurfaceVariant(rawValue: ContextSurface.chat.rawValue))
        } ?? []
        let selectionPublished = chatKernels.count == 1
            && chatKernels[0].requestedPersonaOverride == normalizedPersonaOverride()
        lease?.release()
        // Missing publication is not an acknowledged default/nil selection.
        guard !selectionPublished else { return }
        _ = await coordinator.reconcileSourceChanges([DerivedSourceChange(
            namespace: "persona-picker",
            stableID: "chat",
            operation: .reconcile,
            reason: "chat_persona_picker_changed"
        )])
        // Failure retains the old kernel receipt, so the next ordinary turn
        // or picker edge retries without a separate acknowledgment to undo.
    }

    /// A read never waits on a start: during startup there is no started
    /// coordinator to report, so it answers not-started (the bridge's state
    /// read waited here ~95 s after a launch on a loaded Mac).
    public func health() async -> ContextFlowCoordinatorHealth? {
        guard startup == nil else { return nil }
        return await coordinator?.health()
    }

    /// Observatory reads must distinguish an intentionally disabled runtime
    /// from one whose health cannot be obtained. Both have no coordinator, but
    /// only the former is a healthy configuration state.
    public func observatoryHealthState() async -> ContextFlowObservatoryHealthState {
        await startup?.value
        if let coordinator {
            return .health(await coordinator.health())
        }
        if startupFailedClosed { return .unavailable }
        return resolvedConfiguration().mode == .off ? .off : .unavailable
    }

    /// During startup, the configured mode it is bringing up; never a wait.
    public func contextFlowMode() async -> ContextFlowMode {
        if startup == nil, let coordinator { return await coordinator.mode }
        return resolvedConfiguration().mode
    }

    private func resolvedConfiguration() -> NativeContextFlowConfiguration {
        NativeContextFlowConfiguration.resolve(dataRoot: dataRoot)
    }

    public func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket? {
        let epoch = semanticQueryEpoch
        guard let coordinator, await coordinator.mode == .active,
              let memory = memoryRuntime else { return nil }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 8 * 1_024 else { return nil }
        guard let runtime = await memory.embeddingRuntimeSnapshot(),
              runtime.effectiveBackend != ManagedEmbeddingProvider.failClosedBackend,
              runtime.coreMLLoaded
                || runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend else {
            return ContextQueryEmbeddingTicket(unavailable: "the memory-search model is not loaded")
        }
        // Backend inspection suspends. A stop/reload during that await must
        // not admit a task against the retired runtime after its drain.
        guard epoch == semanticQueryEpoch, self.coordinator != nil,
              !Task.isCancelled else { return nil }
        let normalized = query.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        // User, 2026-09-06: the same question in the other voice ("me" → the
        // agent's name, "you" → the user's). The legacy recall lane has always
        // asked both and kept the better score per row; the packet lane
        // embedded the raw question only, so an atom written in the third
        // person never surfaced for a question asked in the first. Both
        // voices go through ONE embed call, so the second vector costs no
        // extra round trip and lands in the same space. Part of the cache key
        // as well: a changed agent/user name changes the rewrite.
        let alternateQuery = MemoryRecallQueryExpansion.rewrite(
            query,
            names: MemoryRecallQueryExpansion.names(
                storeDirectory: dataRoot.appendingPathComponent("memory", isDirectory: true)
            )
        )
        // The runtime snapshot already carries the exact usable vector-space
        // identity. A second MemoryV2 getter would make ManagedEmbeddingProvider
        // reread the same backend/mode JSON files on every active turn.
        guard let embeddingEpoch = runtime.embeddingEpoch else {
            return ContextQueryEmbeddingTicket(unavailable: "the memory-search model named no vector space")
        }
        let key = ContextStableID.digest(parts: [
            "semantic-query-v2",
            embeddingEpoch,
            normalized,
            alternateQuery ?? "",
        ])
        if let cached = semanticQueryCache[key] {
            touchSemanticQueryCacheKey(key)
            let ticket = ContextQueryEmbeddingTicket()
            ticket.publish(
                cached.values,
                alternate: cached.alternateValues,
                modelFingerprint: cached.modelFingerprint,
                modelID: cached.modelID
            )
            return ticket
        }
        if let pending = semanticQueryTickets[key] { return pending }

        // Semantic query vectors are optional. Keep a wedged provider or burst
        // of turns from building an unbounded task/ticket backlog; overflow
        // follows the existing lexical-only path without delaying the turn.
        guard semanticQueryTickets.count < Self.maximumConcurrentSemanticQueries else {
            return ContextQueryEmbeddingTicket(unavailable: "\(Self.maximumConcurrentSemanticQueries) query embeddings are already in flight")
        }
        let ticket = ContextQueryEmbeddingTicket()
        semanticQueryTickets[key] = ticket
        let modelID = runtime.modelId
        semanticQueryTasks[key] = Task(priority: .utility) { [weak self, memory] in
            let value: Result<ContextQueryEmbeddingValue, Error>
            do {
                let texts = alternateQuery.map { [query, $0] } ?? [query]
                let batch = try await memory.embedForDerivedContextWithEpoch(texts)
                guard let first = batch.vectors.first else { throw MemoryV2Error.underlying("embedder returned no vectors") }
                value = .success(ContextQueryEmbeddingValue(
                    values: first,
                    alternateValues: batch.vectors.count > 1 ? batch.vectors[1] : nil,
                    modelFingerprint: batch.epoch.rawValue,
                    modelID: modelID
                ))
            } catch {
                value = .failure(error)
            }
            await self?.completeSemanticQuery(
                key: key, epoch: epoch, expectedEmbeddingEpoch: embeddingEpoch, value: value
            )
        }
        return ticket
    }

    private func completeSemanticQuery(
        key: String,
        epoch: UInt64,
        expectedEmbeddingEpoch: String,
        value result: Result<ContextQueryEmbeddingValue, Error>
    ) {
        guard epoch == semanticQueryEpoch else { return }
        semanticQueryTasks[key] = nil
        let ticket = semanticQueryTickets.removeValue(forKey: key)
        let value: ContextQueryEmbeddingValue
        switch result {
        case .failure(let error):
            ticket?.fail("query embedding failed: \(error.localizedDescription)")
            return
        case .success(let embedded):
            value = embedded
        }
        guard !value.values.isEmpty, value.values.allSatisfy(\.isFinite) else {
            ticket?.fail("the memory-search model returned an unusable query vector")
            return
        }
        guard value.modelFingerprint == expectedEmbeddingEpoch else {
            ticket?.fail("the memory-search model changed while the query embedded")
            return
        }
        // The embedder can change while prediction is suspended. Never bind
        // a vector from the new space to the old snapshot's cache key: after
        // a switch back, that poisoned hit would keep disabling semantic
        // relevance for this query. Removing the in-flight ticket above
        // permits a fresh exact-epoch retry.
        semanticQueryCache[key] = value
        touchSemanticQueryCacheKey(key)
        while semanticQueryCacheOrder.count > 32 {
            let evicted = semanticQueryCacheOrder.removeFirst()
            semanticQueryCache[evicted] = nil
        }
        // User, 2026-09-06: the FIRST request for a query is the one holding
        // this ticket, and publishing only the primary vector dropped the
        // other voice for it — every later turn hit the cache path above,
        // which does carry both, so automatic recall asked in both voices
        // everywhere except the turn that computed them.
        ticket?.publish(
            value.values,
            alternate: value.alternateValues,
            modelFingerprint: value.modelFingerprint,
            modelID: value.modelID
        )
    }

    private func touchSemanticQueryCacheKey(_ key: String) {
        semanticQueryCacheOrder.removeAll { $0 == key }
        semanticQueryCacheOrder.append(key)
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
        // Packet provenance: resolve this turn's selected memory/correction
        // atoms back to record identity (the digest is one-way; only this
        // layer holds the reverse index). Attached to the SAME instance —
        // never re-wrap a prepared turn, its deinit releases the generation
        // lease. Empty resolution attaches nothing and stays byte-identical.
        let resolution = NativeContextMemoryProvenance.attach(
            to: prepared,
            index: memoryProvenanceIndex
        )
        if resolution.unresolvedMemoryAtomCount > 0 {
            // Invariant breach: the packet carries memory atoms the owner
            // index cannot name. Every miss (total or partial) means those
            // records' use_count/activation loop silently starves. Preserve a
            // payload-free diagnostic for observability and log the counts.
            nativeLog(
                "[context-flow] memory provenance MISS: resolved %d of %d packet memory atoms, index size %d",
                resolution.resolvedMemoryAtomCount,
                resolution.requestedMemoryAtomCount,
                memoryProvenanceIndex.count
            )
            // The system log is not a turn-observable evidence boundary. This
            // additive, payload-free receipt joins the exact chat turn when
            // one is bound, so a ranked provenance lead can name the turn that
            // would otherwise silently starve its memory activation feedback.
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
        guard let coordinator else { return }
        _ = try? await coordinator.applyMemoryPressure(pressure)
    }

    /// This decision runs on the memory-pressure queue, never on the runtime
    /// actor. Keep it value-only so the queue boundary is both auditable and
    /// executable without synthesizing a system memory-pressure event.
    nonisolated static func memoryPressureLevel(
        hasCritical: Bool,
        hasWarning: Bool
    ) -> ContextArenaPressure {
        if hasCritical { return .critical }
        if hasWarning { return .warning }
        return .normal
    }

    /// Register before the first projection replay so a canonical write cannot
    /// land in a read/subscription gap. Each observed edge re-arms the complete
    /// path set before reconciliation; a Desk close that follows a Workshop
    /// terminal write is therefore buffered instead of being lost.
    private func startResidentWorkObservationIfNeeded() async {
        guard residentWorkObservationTask == nil else { return }
        let observation = makeResidentWorkObservation()
        await observation.waitUntilArmed()
        guard coordinator != nil, !Task.isCancelled else { observation.cancel(); return }
        residentWorkObservationTask = Task { [weak self] in
            guard let self else { observation.cancel(); return }
            await self.observeResidentWorkChanges(observation)
        }
    }

    private func observeResidentWorkChanges(_ initial: FileChangeEvents) async {
        var observation = initial
        defer { observation.cancel() }
        while !Task.isCancelled {
            let changed = await waitForResidentWorkChange(observation)
            observation.cancel()
            guard changed, !Task.isCancelled else { return }

            // Re-arm first. The projection read below can suspend on Desk or
            // Workshop I/O while the canonical owner commits a related edge.
            observation = makeResidentWorkObservation()
            await observation.waitUntilArmed()
            guard !Task.isCancelled, let coordinator else { return }
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
        // FileChangeWatcher falls back to the nearest existing parent for a
        // missing target. Watching the exact feed/root avoids duplicate wakes
        // from their parent directories while still detecting first creation.
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
                    // RESOLVED AT ARM TIME (P2-1): watch the record name this
                    // directory actually has right now — `execution.json`, or a
                    // legacy `mission.json` the rename pass hasn't reached.
                    // Watching both names would double the kqueue fd count
                    // across EVERY execution directory to cover a rename that
                    // cannot happen while this runtime is armed: the migrator
                    // renames only in applicationDidFinishLaunching, before
                    // this runtime starts. For a directory with neither file,
                    // resolve() yields the canonical name and
                    // FileChangeWatcher falls back to the directory itself, so
                    // first creation still wakes us.
                    let record = ExecutionRecordFile.resolve(in: directory)
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

    /// Canonical Workshop executors commit verification and terminal status in
    /// the same locked write. Once that record is terminal, keeping an EVTONLY
    /// descriptor open forever only watches immutable history. Missing,
    /// malformed, and active records remain observed fail-safe; the execution
    /// root watcher discovers newly-created directories.
    nonisolated static func shouldObserveResidentWorkExecutionRecord(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else {
            return true
        }
        return !WorkshopOutcomeScoreboard.terminalStatuses.contains(status.lowercased())
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

/// 2026-09-06 — REM PIN RETRACTION LATENCY.
///
/// `rem_pins.json` reconciles every approved lesson against the live persona
/// document, so removing or rewording a lesson in GROWTH.md is supposed to
/// retire its pin. But the index was only rebuilt on approve/deny and on a REM
/// tick, so a retracted lesson kept riding into every chat turn until the next
/// weekly cycle. Saving GROWTH.md already publishes a persona invalidation;
/// this sink is what turns that into a rebuild.
///
/// A FAN-OUT rather than a second center: `DerivedStateInvalidationCenter`
/// holds one sink, and this is it — installed once at app launch and never
/// removed. Context Flow's coordinator is forwarded first, exactly as before,
/// but it is now a SUBSCRIBER (through `ContextFlowInvalidationRelay`) rather
/// than the owner of the installation.
///
/// 2026-09-06: this sink used to be installed only when Context Flow built a
/// coordinator, so with Context Flow off — or after a failed startup — a
/// GROWTH.md edit left retracted pins riding into every turn until the next
/// weekly REM cycle, which is the very latency the sink exists to remove.
public struct DerivedPersonaPinInvalidationSink: DerivedStateInvalidationSink {
    let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        if let primary = await ContextFlowInvalidationRelay.shared.current() {
            await primary.sourceDidChange(changes)
        }
        // Only the document REM can pin into. `stableID` is a filename from
        // the persona doc writers and a bare doc id from the scaffolder;
        // `supportsProposalTarget` normalises both.
        guard changes.contains(where: {
            $0.namespace == "persona"
                && REMProposalStore.supportsProposalTarget($0.stableID)
        }) else { return }
        await REMPinRebuildCoalescer.shared.requestRebuild(dataRoot: dataRoot)
    }
}

/// The Context Flow coordinator's subscription to the invalidation center,
/// held apart from the installation itself (2026-09-06). `current()` hands the
/// sink back rather than forwarding through this actor, so a slow coordinator
/// delivery never serialises behind the relay's isolation.
actor ContextFlowInvalidationRelay {
    static let shared = ContextFlowInvalidationRelay()

    private var coordinator: (any DerivedStateInvalidationSink)?

    func set(_ sink: (any DerivedStateInvalidationSink)?) {
        coordinator = sink
    }

    func current() -> (any DerivedStateInvalidationSink)? {
        coordinator
    }
}

/// Collapses a burst of GROWTH.md writes into one rebuild, and a write that
/// arrives DURING a rebuild into exactly one more afterwards. No timer: the
/// invalidation center already coalesces its deliveries, and a rebuild that is
/// already running is the debounce window.
actor REMPinRebuildCoalescer {
    static let shared = REMPinRebuildCoalescer()

    private var rebuilding = false
    private var changedAgain = false

    func requestRebuild(dataRoot: URL) async {
        guard !rebuilding else {
            changedAgain = true
            return
        }
        rebuilding = true
        defer { rebuilding = false }
        repeat {
            changedAgain = false
            await Task.detached(priority: .utility) { [dataRoot] in
                do {
                    try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
                } catch {
                    nativeLog("[rem-pins] rebuild after a persona write failed: %@",
                          String(describing: error))
                }
            }.value
        } while changedAgain
    }
}
