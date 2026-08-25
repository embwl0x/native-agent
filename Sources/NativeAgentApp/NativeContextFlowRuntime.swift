import AppKit
import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import WorkshopExecution

struct SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults
}

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

actor PersonaContextFlowProvider:
    ContextRequiredDocumentMirrorProviding,
    ContextSourceRegistrationRefreshing
{
    private struct Build: Sendable {
        let mirrors: [RequiredDocumentMirror]
        let registrations: [ContextSourceRegistration]
        let allowedRoots: [URL]
    }

    private static let owner = "nativeagent.persona"
    private static let surfaces: [ContextSurface] = [
        .chat, .telegram, .ios, .slack, .workshop, .bridge,
    ]

    private let compiler: PersonaCompiler
    private let mode: ContextFlowMode
    private let personaOverride: @Sendable () -> String?
    private var cachedBuild: Build?

    init(
        compiler: PersonaCompiler? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        mode: ContextFlowMode = .shadow,
        personaOverride: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: "chatPersona").flatMap {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
    ) {
        let standardizedRoot = dataRoot.standardizedFileURL
        let persona = standardizedRoot
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: standardizedRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: standardizedRoot)
        self.compiler = compiler ?? PersonaCompiler(engine: persona)
        self.mode = mode
        self.personaOverride = personaOverride
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

    /// The chat persona picker is a process-local selection edge rather than a
    /// filesystem event. Drop the derived snapshot before ContextFlow asks us
    /// to refresh registrations and publish the replacement generation.
    func invalidateCachedBuild() {
        cachedBuild = nil
    }

    private func makeBuild() async throws -> Build {
        let selectedOverride = personaOverride()
        var snapshots: [PersonaContextSourceSnapshot] = []
        for surface in Self.surfaces {
            // The Mac chat picker is a per-turn override. Remote and autonomous
            // surfaces retain PersonaCompiler's active-persona resolution.
            let override = surface == .chat ? selectedOverride : nil
            snapshots.append(try await compiler.contextSourceSnapshot(
                surface: surface.rawValue,
                personaOverride: override
            ))
        }

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

        for root in allowedRoots.sorted(by: { $0.path < $1.path }) {
            guard let catalog = try? NativeMarkdownContextSourceCatalog(personaRoot: root) else {
                continue
            }
            for catalogRoot in catalog.allowedRoots { allowedRoots.insert(catalogRoot) }
            for registration in catalog.registrations {
                registrations[registration.descriptor.id] = registration
            }
        }

        let grouped = Dictionary(grouping: snapshots, by: { $0.packet.personaId })
        let mirrors = try grouped.keys.sorted().map { personaID in
            try Self.makeMirror(
                personaID: personaID,
                snapshots: grouped[personaID] ?? [],
                mode: mode
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
        mode: ContextFlowMode
    ) throws -> RequiredDocumentMirror {
        guard let canonical = snapshots.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let canonicalDocuments = canonical.documents
            .filter { !$0.surfaceOverride }
            .sorted { $0.canonicalOrder < $1.canonicalOrder }
        let documents = try canonicalDocuments.map { source in
            try RequiredDocument(
                id: RequiredDocumentID(rawValue: "\(source.id).md"),
                canonicalOrder: source.canonicalOrder,
                sourceHash: ContextStableID.digest(parts: [source.content]),
                text: source.content,
                tokenCount: estimatedTokenCount(source.content)
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
            let includedIDs = mode == .active
                ? activeKernelDocuments.map { RequiredDocumentID(rawValue: "\($0.id).md") }
                : documents.map(\.id)
            let renderedPrompt: String
            if mode == .active {
                var sections = activeKernelDocuments.map { "# \($0.id)\n\($0.content)" }
                if let surface = snapshot.documents.first(where: \.surfaceOverride) {
                    sections.append(
                        "Surface guidance for \(snapshot.packet.surface):\n\(surface.content)"
                    )
                }
                renderedPrompt = sections.isEmpty
                    ? snapshot.packet.compiledSystemPrompt
                    : sections.joined(separator: "\n\n")
            } else {
                renderedPrompt = snapshot.packet.compiledSystemPrompt
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
                tokenCount: estimatedTokenCount(renderedPrompt)
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

struct NativeContextFlowConfiguration: Sendable, Equatable {
    static let modeEnvironmentKey = "NATIVE_AGENT_CONTEXT_FLOW_MODE"
    static let modeDefaultsKey = "contextFlowMode"
    static let budgetDefaultsKey = "contextFlowRAMMiB"

    let mode: ContextFlowMode
    let budget: ContextArenaBudget

    static func resolve(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        publicSafeMode: Bool? = nil
    ) -> Self {
        let isPublicSafe = publicSafeMode ?? NativeAgentPublicSafety.isPublicSafeMode(
            environment: environment
        )
        let preOnboarding = isPublicSafe
            && !NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        let explicitMode = environment[modeEnvironmentKey]
            .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
            ?? defaults.string(forKey: modeDefaultsKey)
                .flatMap { ContextFlowMode(rawValue: $0.lowercased()) }
        let mode: ContextFlowMode = preOnboarding ? .off : (explicitMode ?? .shadow)
        let budget = ContextArenaBudget(
            rawValue: defaults.integer(forKey: budgetDefaultsKey)
        ) ?? .default
        return Self(mode: mode, budget: budget)
    }
}

struct NativeContextFlowModeStatus: Sendable, Equatable {
    let effectiveMode: ContextFlowMode
    let environmentManaged: Bool
    let setupForcedOff: Bool
}

struct NativeResidentWorkObservationStatus: Equatable, Sendable {
    let isWatching: Bool
    let watchedPaths: [String]
    let missingPaths: [String]
    let invalidationCount: Int
}

actor NativeContextFlowRuntime: ContextTurnPreparing {
    static let shared = NativeContextFlowRuntime()

    private let dataRoot: URL
    private let configurationOverride: NativeContextFlowConfiguration?
    private let memoryOverride: SwiftNativeMemoryV2?
    private let environmentOverride: [String: String]?
    private let defaultsOverride: SendableUserDefaults?
    private let publicSafeModeOverride: Bool?
    private let personaOverride: @Sendable () -> String?
    private var coordinator: ContextFlowCoordinator?
    private var personaProvider: PersonaContextFlowProvider?
    /// The picker value whose persona sources were last reconciled into the
    /// resident generation. This is an ordering fence, not a second persona
    /// owner: the closure still reads the canonical picker preference.
    private var reconciledPersonaOverride: String?
    private var memoryRuntime: SwiftNativeMemoryV2?
    private let memoryPressureObserver: (any NativeContextMemoryPressureObserving)?
    /// One kqueue-backed invalidation reader over the canonical Desk feed and
    /// Workshop execution records. It carries no payload and owns no work state;
    /// every edge makes the existing ContextFlow coordinator reread the stores.
    private var residentWorkObservationTask: Task<Void, Never>?
    private var residentWorkObservationPathsSnapshot: [URL] = []
    private var residentWorkInvalidationCount = 0
    private var starting = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    private var semanticQueryCache: [String: ContextQueryEmbeddingValue] = [:]
    private var semanticQueryCacheOrder: [String] = []
    private var semanticQueryWaiters: [String: [ContextQueryEmbeddingTicket]] = [:]
    private var semanticQueryTasks: [String: Task<Void, Never>] = [:]
    private var semanticQueryEpoch: UInt64 = 0
    private var startupFailedClosed = false
    /// Packet provenance: filled by the memory projection on every compile,
    /// read at prepare time to resolve selected memory atoms → record IDs.
    private let memoryProvenanceIndex: MemoryAtomRecordIndex
    private var lastMemoryProvenanceResolution: NativeContextMemoryProvenanceResolution?
    private var lastMemoryPressureReceipt: ContextArenaTrimReceipt?

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configurationOverride: NativeContextFlowConfiguration? = nil,
        memoryOverride: SwiftNativeMemoryV2? = nil,
        environmentOverride: [String: String]? = nil,
        defaultsOverride: SendableUserDefaults? = nil,
        publicSafeModeOverride: Bool? = nil,
        personaOverride: (@Sendable () -> String?)? = nil,
        memoryPressureObserver: (any NativeContextMemoryPressureObserving)? = nil,
        memoryProvenanceIndex: MemoryAtomRecordIndex? = nil
    ) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.configurationOverride = configurationOverride
        self.memoryOverride = memoryOverride
        self.environmentOverride = environmentOverride
        self.defaultsOverride = defaultsOverride
        self.publicSafeModeOverride = publicSafeModeOverride
        self.memoryPressureObserver = memoryPressureObserver
            ?? (dataRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL
                ? DispatchContextMemoryPressureObserver()
                : nil)
        self.memoryProvenanceIndex = memoryProvenanceIndex ?? MemoryAtomRecordIndex()
        let pickerDefaults = defaultsOverride ?? SendableUserDefaults(value: .standard)
        self.personaOverride = personaOverride ?? {
            let value = pickerDefaults.value.string(forKey: "chatPersona")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    private var usesLiveAppBody: Bool {
        dataRoot == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    func start() async {
        if starting {
            await waitForStartup()
            return
        }
        guard coordinator == nil else { return }
        starting = true
        startupFailedClosed = false
        lastMemoryPressureReceipt = nil
        let configuration = resolvedConfiguration()
        guard configuration.mode != .off else {
            NSLog("[context-flow] disabled until onboarding or explicit enablement")
            finishStartup()
            return
        }

        if let warning = ContextHintsFeed.inspect(dataRoot: dataRoot).warning {
            NSLog("[context-hints] %@", warning)
        }

        do {
            let memory: SwiftNativeMemoryV2
            if let memoryOverride {
                memory = memoryOverride
            } else {
                memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            }
            guard let embeddingEpoch = await memory.embeddingEpoch()?.rawValue else {
                throw MemoryV2Error.storageUnavailable
            }
            let embeddingProvider = NativeContextEmbeddingProvider(
                memory: memory,
                modelFingerprint: embeddingEpoch
            )
            let store = try ContextSQLiteStore(dataRoot: dataRoot)
            let arena = try ContextArena(budget: configuration.budget)
            let registry = try ContextSourceRegistry()
            let provider = PersonaContextFlowProvider(
                dataRoot: dataRoot,
                mode: configuration.mode,
                personaOverride: personaOverride
            )
            let coordinator = ContextFlowCoordinator(
                mode: configuration.mode,
                store: store,
                arena: arena,
                registry: registry,
                compiler: ContextMarkdownCompiler(embeddingProvider: embeddingProvider),
                mirrorProvider: provider,
                compiledProjectionProviders: [NativeMemoryContextProjection(
                    memory: memory,
                    provenanceIndex: memoryProvenanceIndex
                ), NativeResidentWorkContextProjection(dataRoot: dataRoot)]
            )
            memoryRuntime = memory
            personaProvider = provider
            self.coordinator = coordinator
            startResidentWorkObservationIfNeeded()
            if usesLiveAppBody {
                await DerivedStateInvalidationCenter.shared.install(coordinator)
            }
            installMemoryPressureSource()
            await coordinator.start()
            reconciledPersonaOverride = normalizedPersonaOverride()
            let health = await coordinator.health()
            NSLog(
                "[context-flow] started mode=%@ generation=%lld sources=%d arena_bytes=%d",
                configuration.mode.rawValue,
                health.activeArenaGenerationID ?? 0,
                health.registeredSourceCount,
                health.arenaMetrics.currentLogicalBytes
            )
        } catch {
            if usesLiveAppBody {
                await DerivedStateInvalidationCenter.shared.install(nil)
            }
            coordinator = nil
            personaProvider = nil
            reconciledPersonaOverride = nil
            memoryRuntime = nil
            startupFailedClosed = true
            await memoryPressureObserver?.stop()
            residentWorkObservationTask?.cancel()
            residentWorkObservationTask = nil
            NSLog("[context-flow] start failed closed: %@", String(describing: error))
        }
        finishStartup()
    }

    func stop() async {
        if starting { await waitForStartup() }
        semanticQueryEpoch &+= 1
        semanticQueryTasks.values.forEach { $0.cancel() }
        semanticQueryTasks.removeAll()
        semanticQueryWaiters.removeAll()
        semanticQueryCache.removeAll()
        semanticQueryCacheOrder.removeAll()
        await memoryPressureObserver?.stop()
        residentWorkObservationTask?.cancel()
        residentWorkObservationTask = nil
        if usesLiveAppBody {
            await DerivedStateInvalidationCenter.shared.install(nil)
        }
        await coordinator?.stop()
        coordinator = nil
        personaProvider = nil
        reconciledPersonaOverride = nil
        memoryRuntime = nil
    }

    func reloadConfiguration() async {
        await stop()
        await start()
    }

    /// Persist and hot-apply the single production Context Flow mode. Public
    /// pre-onboarding safety is still resolved inside `start()` and can force
    /// the effective mode off regardless of the requested preference.
    @discardableResult
    func setMode(_ mode: ContextFlowMode) async -> NativeContextFlowModeStatus {
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: NativeContextFlowConfiguration.modeDefaultsKey
        )
        await reloadConfiguration()
        return await modeStatus()
    }

    func modeStatus() async -> NativeContextFlowModeStatus {
        let environment = environmentOverride ?? ProcessInfo.processInfo.environment
        let environmentManaged = environment[NativeContextFlowConfiguration.modeEnvironmentKey]
            .flatMap { ContextFlowMode(rawValue: $0.lowercased()) } != nil
        let setupForcedOff = (publicSafeModeOverride
            ?? NativeAgentPublicSafety.isPublicSafeMode(environment: environment))
            && !NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot)
        return NativeContextFlowModeStatus(
            effectiveMode: await contextFlowMode(),
            environmentManaged: environmentManaged,
            setupForcedOff: setupForcedOff
        )
    }

    func prepareForSleep() async {
        guard let coordinator else { return }
        _ = try? await coordinator.applyMemoryPressure(.warning)
    }

    func reconcileAfterWake() async {
        if coordinator == nil {
            await start()
        }
        await coordinator?.reconcileAfterWake()
    }

    /// Eagerly rebuild after the Mac picker changes. `prepareContextTurn` also
    /// calls this fence, so an unstructured UI notification can never let the
    /// next real chat turn consume the prior persona generation.
    func personaPickerDidChange() async {
        await reconcilePersonaPickerIfNeeded()
    }

    private func normalizedPersonaOverride() -> String? {
        let value = personaOverride()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func reconcilePersonaPickerIfNeeded() async {
        let selectedPersona = normalizedPersonaOverride()
        guard selectedPersona != reconciledPersonaOverride,
              let coordinator,
              let personaProvider else { return }
        await personaProvider.invalidateCachedBuild()
        await coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona-picker",
            stableID: "chat",
            operation: .reconcile,
            reason: "chat_persona_picker_changed"
        ))
        reconciledPersonaOverride = selectedPersona
    }

    func health() async -> ContextFlowCoordinatorHealth? {
        if starting { await waitForStartup() }
        return await coordinator?.health()
    }

    /// Observatory reads must distinguish an intentionally disabled runtime
    /// from one whose health cannot be obtained. Both have no coordinator, but
    /// only the former is a healthy configuration state.
    func observatoryHealthState() async -> ContextFlowObservatoryHealthState {
        if starting { await waitForStartup() }
        if let coordinator {
            return .health(await coordinator.health())
        }
        if startupFailedClosed { return .unavailable }
        return resolvedConfiguration().mode == .off ? .off : .unavailable
    }

    func contextFlowMode() async -> ContextFlowMode {
        if starting { await waitForStartup() }
        if let coordinator { return await coordinator.mode }
        if startupFailedClosed { return .off }
        return resolvedConfiguration().mode
    }

    /// Lifecycle evidence for the OS pressure edge. This reports the actual
    /// bridge state rather than inferring installation from runtime mode.
    func memoryPressureSourceIsInstalled() -> Bool {
        memoryPressureObserver?.isRunning ?? false
    }

    /// The latest typed trim evidence remains available after shutdown so
    /// diagnostics can distinguish a registered source from a delivered edge.
    func memoryPressureReceipt() -> ContextArenaTrimReceipt? {
        lastMemoryPressureReceipt
    }

    /// The latest prepared turn's provenance resolution is intentionally
    /// payload-free. It makes a partial reverse-index miss visible to runtime
    /// diagnostics without putting record identities into Context receipts.
    func memoryProvenanceResolution() -> NativeContextMemoryProvenanceResolution? {
        lastMemoryProvenanceResolution
    }

    private func resolvedConfiguration() -> NativeContextFlowConfiguration {
        configurationOverride ?? NativeContextFlowConfiguration.resolve(
            dataRoot: dataRoot,
            environment: environmentOverride ?? ProcessInfo.processInfo.environment,
            defaults: defaultsOverride?.value ?? .standard,
            publicSafeMode: publicSafeModeOverride
        )
    }

    func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket? {
        guard let coordinator, await coordinator.mode == .active,
              let memory = memoryRuntime else { return nil }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 8 * 1_024 else { return nil }
        guard let runtime = await memory.embeddingRuntimeSnapshot(),
              runtime.effectiveBackend != ManagedEmbeddingProvider.failClosedBackend,
              runtime.coreMLLoaded
                || runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend else {
            return nil
        }
        let normalized = query.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        // The runtime snapshot already carries the exact usable vector-space
        // identity. A second MemoryV2 getter would make ManagedEmbeddingProvider
        // reread the same backend/mode JSON files on every active turn.
        guard let embeddingEpoch = runtime.embeddingEpoch else { return nil }
        let key = ContextStableID.digest(parts: [
            "semantic-query-v1",
            embeddingEpoch,
            normalized,
        ])
        let ticket = ContextQueryEmbeddingTicket()
        if let cached = semanticQueryCache[key] {
            touchSemanticQueryCacheKey(key)
            ticket.publish(cached.values, modelFingerprint: cached.modelFingerprint)
            return ticket
        }
        if semanticQueryWaiters[key] != nil {
            semanticQueryWaiters[key, default: []].append(ticket)
            return ticket
        }

        semanticQueryWaiters[key] = [ticket]
        let epoch = semanticQueryEpoch
        semanticQueryTasks[key] = Task(priority: .utility) { [weak self, memory] in
            let value: ContextQueryEmbeddingValue?
            do {
                let batch = try await memory.embedForDerivedContextWithEpoch([query])
                value = batch.vectors.first.map {
                    ContextQueryEmbeddingValue(
                        values: $0,
                        modelFingerprint: batch.epoch.rawValue
                    )
                }
            } catch {
                value = nil
            }
            await self?.completeSemanticQuery(key: key, epoch: epoch, value: value)
        }
        return ticket
    }

    private func completeSemanticQuery(
        key: String,
        epoch: UInt64,
        value: ContextQueryEmbeddingValue?
    ) {
        guard epoch == semanticQueryEpoch else { return }
        semanticQueryTasks[key] = nil
        let tickets = semanticQueryWaiters.removeValue(forKey: key) ?? []
        guard let value,
              !value.values.isEmpty,
              value.values.allSatisfy(\.isFinite),
              !value.modelFingerprint.isEmpty else { return }
        semanticQueryCache[key] = value
        touchSemanticQueryCacheKey(key)
        while semanticQueryCacheOrder.count > 32 {
            let evicted = semanticQueryCacheOrder.removeFirst()
            semanticQueryCache[evicted] = nil
        }
        for ticket in tickets {
            ticket.publish(value.values, modelFingerprint: value.modelFingerprint)
        }
    }

    private func touchSemanticQueryCacheKey(_ key: String) {
        semanticQueryCacheOrder.removeAll { $0 == key }
        semanticQueryCacheOrder.append(key)
    }

    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        await start()
        await reconcilePersonaPickerIfNeeded()
        guard let coordinator else {
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        let prepared = try await coordinator.prepareTurn(request)
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
        lastMemoryProvenanceResolution = resolution
        if resolution.unresolvedMemoryAtomCount > 0 {
            // Invariant breach: the packet carries memory atoms the owner
            // index cannot name. Every miss (total or partial) means those
            // records' use_count/activation loop silently starves. Preserve a
            // payload-free diagnostic for observability and log the counts.
            NSLog(
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

    func prepareFrozenContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn {
        await reconcilePersonaPickerIfNeeded()
        guard let coordinator else {
            throw ContextTurnPreparationError.coordinatorNotStarted
        }
        let prepared = try await coordinator.prepareFrozenTurn(request)
        attachMemoryProvenance(to: prepared, surface: request.surface.rawValue)
        return prepared
    }

    func frozenContextRevision() async -> ContextFrozenRevision? {
        guard let coordinator else { return nil }
        return await coordinator.frozenRevision()
    }

    func prewarm(kind: ContextPrewarmHintKind, id: String, terms: [String]) async {
        guard let coordinator else { return }
        _ = await coordinator.submitPrewarm(kind: kind, id: id, terms: terms)
    }

    private func installMemoryPressureSource() {
        memoryPressureObserver?.start { [weak self] pressure in
            await self?.applyObservedMemoryPressure(pressure)
        }
    }

    private func applyObservedMemoryPressure(_ pressure: ContextArenaPressure) async {
        guard let coordinator else { return }
        lastMemoryPressureReceipt = try? await coordinator.applyMemoryPressure(pressure)
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
    private func startResidentWorkObservationIfNeeded() {
        guard residentWorkObservationTask == nil else { return }
        residentWorkObservationTask = Task { [weak self] in
            await self?.observeResidentWorkChanges()
        }
    }

    private func observeResidentWorkChanges() async {
        refreshResidentWorkObservationSnapshot()
        var observation = FileChangeEvents(
            paths: residentWorkObservationPaths(),
            emitInitial: false
        )
        defer { observation.cancel() }
        while !Task.isCancelled {
            let changed = await waitForResidentWorkChange(observation)
            observation.cancel()
            guard changed, !Task.isCancelled else { return }

            // Re-arm first. The projection read below can suspend on Desk or
            // Workshop I/O while the canonical owner commits a related edge.
            observation = FileChangeEvents(
                paths: residentWorkObservationPaths(),
                emitInitial: false
            )
            refreshResidentWorkObservationSnapshot()
            guard let coordinator else { return }
            await coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "resident-work",
                stableID: "canonical",
                operation: .reconcile,
                reason: "resident_work_file_changed"
            ))
            residentWorkInvalidationCount += 1
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
                    paths.append(ExecutionRecordFile.resolve(in: directory))
                }
            }
        }
        return paths
    }

    func residentWorkObservationStatus() -> NativeResidentWorkObservationStatus {
        NativeResidentWorkObservationStatus(
            isWatching: residentWorkObservationTask != nil,
            watchedPaths: residentWorkObservationPathsSnapshot.map(\.path),
            missingPaths: residentWorkObservationPathsSnapshot
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
                .map(\.path),
            invalidationCount: residentWorkInvalidationCount
        )
    }

    private func refreshResidentWorkObservationSnapshot() {
        residentWorkObservationPathsSnapshot = residentWorkObservationPaths()
    }

    private func waitForStartup() async {
        guard starting else { return }
        await withCheckedContinuation { continuation in
            startupWaiters.append(continuation)
        }
    }

    private func finishStartup() {
        starting = false
        let waiters = startupWaiters
        startupWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }
}

extension NativeContextFlowRuntime {
    /// Mind-into-circulation (2026-07-10): app-side translation of a MEMORY
    /// RECORD id → the ContextAtomID the memory projection assigns that record.
    /// This lives app-side on purpose — the projection's owner string
    /// (`NativeMemoryContextProjection.owner`) must never be hardcoded in a core
    /// module. The derivation MIRRORS `NativeMemoryContextProjection.prepare`
    /// exactly (locatorDigest → locator → source → atom) so an activation weight
    /// keyed here lands on the same atom Fluid Context selects.
    ///
    /// Kind is fixed to `.memory`: the substrate hands us record ids without the
    /// correction flag, and correction atoms are already mandatory-included, so
    /// an activation miss on a correction record is benign (it's injected anyway).
    /// Reusable as a `@Sendable (String) -> ContextAtomID?` — no captured state.
    static func memoryRecordAtomID(forRecordID recordID: String) -> ContextAtomID? {
        // Mirror the projection's EXACT id pipeline (gpt-5.5 MED, 2026-07-10):
        // `normalizedID` precomposes Unicode before trimming — a decomposed
        // record id hashed raw would derive a locator the projection never
        // creates. Same validity gates (≤512 UTF-8 bytes, no control chars):
        // an id the projection would reject translates to nil, never to a
        // phantom atom id.
        let normalized = NativeMemoryContextProjection.normalizedRecordID(recordID)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 512,
              !NativeMemoryContextProjection.recordIDContainsDisallowedControl(normalized) else {
            return nil
        }
        let locatorDigest = ContextStableID.digest(parts: [normalized])
        let locator = "memory-v2/records/\(locatorDigest)"
        let sourceID = ContextStableID.source(
            owner: NativeMemoryContextProjection.owner,
            locator: locator
        )
        return ContextStableID.atom(
            sourceID: sourceID,
            kind: .memory,
            headingPath: [],
            blockAnchor: "memory-record"
        )
    }
}
