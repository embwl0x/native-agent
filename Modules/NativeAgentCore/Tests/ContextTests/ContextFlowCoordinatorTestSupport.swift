import Foundation
import NativeAgentCore
import Testing
@testable import Context

/// Collects the coordinator's error-level diagnostics so tests can prove the
/// dead-lane alarm fires (and, just as importantly, that it stays quiet on the
/// healthy paths).
final class CoordinatorDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    var memoryVocabularyDrift: [String] {
        all.filter { $0.contains("memory-scope vocabulary drift") }
    }
}

struct CoordinatorEmbeddingProvider: ContextMarkdownEmbeddingProvider {
    let modelFingerprint = "coordinator-test"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.enumerated().map { index, _ in [Float(index + 1), 0.5] }
    }
}

actor CoordinatorControllableCompiler: ContextMarkdownCompiling {
    private let base = ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider())
    private var blockedText: String?
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func blockNextCompilation(containing text: String) {
        blockedText = text
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedCompilation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
        isBlocked = false
    }

    func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource?,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        if let blockedText,
           String(data: sourceData, encoding: .utf8)?.contains(blockedText) == true {
            self.blockedText = nil
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            isBlocked = false
        }
        return try await base.compile(
            sourceData: sourceData,
            descriptor: descriptor,
            previous: previous,
            updatedAt: updatedAt
        )
    }
}

actor CoordinatorCancellationCompiler: ContextMarkdownCompiling {
    private let base = ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider())
    private var blockedText: String?
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func cancelNextCompilation(containing text: String) {
        blockedText = text
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func compile(
        sourceData: Data,
        descriptor: ContextSourceDescriptor,
        previous: ContextCompiledSource?,
        updatedAt: Date
    ) async throws -> ContextCompiledSource {
        if let blockedText,
           String(data: sourceData, encoding: .utf8)?.contains(blockedText) == true {
            self.blockedText = nil
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
            try await Task.sleep(for: .seconds(60))
        }
        return try await base.compile(
            sourceData: sourceData,
            descriptor: descriptor,
            previous: previous,
            updatedAt: updatedAt
        )
    }
}

struct CoordinatorMirrorProvider: ContextRequiredDocumentMirrorProviding {
    let mirror: RequiredDocumentMirror
    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] { [mirror] }
}

actor CoordinatorRefreshingMirrorProvider:
    ContextRequiredDocumentMirrorProviding,
    ContextSourceRegistrationRefreshing
{
    let mirrors: [RequiredDocumentMirror]
    private var registrations: [ContextSourceRegistration] = []
    private var refreshes = 0
    private var ownedRegistrationOwners: Set<String> = []
    private var cancelRefresh = false

    init(mirrors: [RequiredDocumentMirror]) {
        self.mirrors = mirrors
    }

    func replaceRegistrations(_ registrations: [ContextSourceRegistration]) {
        self.registrations = registrations
        ownedRegistrationOwners.formUnion(registrations.map(\.descriptor.owner))
    }

    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] { mirrors }

    func refreshCount() -> Int { refreshes }

    func setRefreshCancellation(_ cancelled: Bool) { cancelRefresh = cancelled }

    func refreshContextSources(in registry: ContextSourceRegistry) async throws {
        refreshes += 1
        if cancelRefresh { throw CancellationError() }
        let registrations = self.registrations
        for root in Set(registrations.map(\.allowedRoot)) {
            try await registry.addAllowedRoot(root)
        }
        for owner in ownedRegistrationOwners.sorted() {
            try await registry.replaceOwned(owner: owner, with: registrations)
        }
    }
}

private struct CoordinatorProjectionProvider: ContextCompiledProjectionProvider {
    let sources: [ContextCompiledSource]

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        ContextCompiledProjectionResult(changedSources: sources.filter {
            previousSources[$0.descriptor.id] != $0
        })
    }
}

private enum CoordinatorInjectedProjectionError: Error {
    case injected
}

actor CoordinatorControllableProjectionProvider: ContextCompiledProjectionProvider {
    nonisolated let projectionIdentifier: String
    nonisolated let invalidationNamespaces: Set<String>
    nonisolated let invalidationSourceURL: URL?
    private var shouldFailNext = false
    private var calls = 0

    init(
        identifier: String = "coordinator.controllable",
        namespaces: Set<String> = [],
        sourceURL: URL? = nil
    ) {
        projectionIdentifier = identifier
        invalidationNamespaces = namespaces
        invalidationSourceURL = sourceURL
    }

    func failNextProjection() {
        shouldFailNext = true
    }

    func invocationCount() -> Int {
        calls
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        _ = previousSources
        calls += 1
        if shouldFailNext {
            shouldFailNext = false
            throw CoordinatorInjectedProjectionError.injected
        }
        return ContextCompiledProjectionResult(changedSources: [])
    }
}

extension ContextFlowCoordinatorTests {
    struct Fixture {
        let root: URL
        let sourceFile: URL
        let sourceID: ContextSourceID
        let store: ContextSQLiteStore
        let arena: ContextArena
        let registry: ContextSourceRegistry
        let mirror: RequiredDocumentMirror
        let refreshingMirrorProvider: CoordinatorRefreshingMirrorProvider
        let coordinator: ContextFlowCoordinator
        let diagnostics: CoordinatorDiagnosticLog

        func cleanup() {
            Task { await coordinator.stop() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    func makeFixture(
        mode: ContextFlowMode,
        body: String,
        warmBody: String? = nil,
        projectedSources: [ContextCompiledSource] = [],
        compiler: (any ContextMarkdownCompiling)? = nil,
        projectionProviders: [any ContextCompiledProjectionProvider]? = nil,
        mirrorPersonaID: ContextPersonaID = ContextPersonaID(rawValue: "Agent"),
        additionalMirrorPersonaIDs: [ContextPersonaID] = [],
        mirrorSurfaceVariants: [ContextSurfaceVariant] = [ContextSurfaceVariant(rawValue: "chat")]
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextFlowCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        let sourceFile = persona.appendingPathComponent("SOUL.md")
        try body.write(to: sourceFile, atomically: true, encoding: .utf8)

        let sourceID = ContextStableID.source(owner: "persona", locator: "SOUL.md")
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: "persona",
            kind: .persona,
            canonicalLocator: sourceFile.path,
            authority: .identity,
            privacy: .localPrivate,
            permittedSurfaces: [.chat, .bridge],
            injectionPolicy: .always
        )
        let registry = try ContextSourceRegistry(allowedRoots: [persona])
        try await registry.register(ContextSourceRegistration(
            descriptor: descriptor,
            fileURL: sourceFile,
            allowedRoot: persona,
            requiredPersonaDocument: .soul,
            personaID: ContextPersonaID(rawValue: "Agent")
        ))
        if let warmBody {
            let warmFile = persona.appendingPathComponent("PROJECT.md")
            try warmBody.write(to: warmFile, atomically: true, encoding: .utf8)
            let warmDescriptor = ContextSourceDescriptor(
                id: ContextStableID.source(owner: "project", locator: "PROJECT.md"),
                owner: "project",
                kind: .project,
                canonicalLocator: warmFile.path,
                authority: .external,
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .bridge],
                injectionPolicy: .adaptive
            )
            try await registry.register(ContextSourceRegistration(
                descriptor: warmDescriptor,
                fileURL: warmFile,
                allowedRoot: persona
            ))
        }

        let requiredDocument = try RequiredDocument(
            kind: .soul,
            sourceHash: ContextStableID.digest(parts: [body]),
            text: body,
            tokenCount: 8
        )
        let mirrorFingerprint = "mirror-fingerprint"
        let mirrorPersonaIDs = [mirrorPersonaID] + additionalMirrorPersonaIDs
        let mirrors = try mirrorPersonaIDs.map { personaID in
            let kernels = try mirrorSurfaceVariants.map { surface in
                try StablePromptKernel(
                    key: StablePromptKernelKey(
                        personaID: personaID,
                        surfaceVariant: surface,
                        sourceFingerprint: mirrorFingerprint
                    ),
                    renderedPrompt: "# SOUL\n\(body)",
                    includedDocumentIDs: [requiredDocument.id],
                    tokenCount: 8
                )
            }
            return try RequiredDocumentMirror(
                personaID: personaID,
                sourceFingerprint: mirrorFingerprint,
                documents: [requiredDocument],
                kernels: kernels
            )
        }
        let mirror = mirrors[0]
        let arena = try ContextArena(budget: .mib32)
        let store = try ContextSQLiteStore(dataRoot: root)
        let sourceCompiler: any ContextMarkdownCompiling = compiler
            ?? ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider())
        let sourceProjectionProviders: [any ContextCompiledProjectionProvider] = projectionProviders
            ?? [CoordinatorProjectionProvider(sources: projectedSources)]
        let diagnostics = CoordinatorDiagnosticLog()
        let refreshingMirrorProvider = CoordinatorRefreshingMirrorProvider(mirrors: mirrors)
        let coordinator = ContextFlowCoordinator(
            mode: mode,
            store: store,
            arena: arena,
            registry: registry,
            compiler: sourceCompiler,
            mirrorProvider: refreshingMirrorProvider,
            compiledProjectionProviders: sourceProjectionProviders,
            diagnostics: { [diagnostics] message in diagnostics.record(message) }
        )
        return Fixture(
            root: root,
            sourceFile: sourceFile,
            sourceID: sourceID,
            store: store,
            arena: arena,
            registry: registry,
            mirror: mirror,
            refreshingMirrorProvider: refreshingMirrorProvider,
            coordinator: coordinator,
            diagnostics: diagnostics
        )
    }

    func compiledSource(
        id: String,
        owner: String,
        locator: String,
        kind: ContextAtomKind,
        body: String,
        authority: ContextAuthority,
        policy: ContextInjectionPolicy,
        permittedSurfaces: Set<ContextSurface> = [.chat, .bridge]
    ) -> ContextCompiledSource {
        let sourceID = ContextStableID.source(owner: owner, locator: locator)
        let sourceHash = ContextStableID.digest(parts: [body])
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: owner,
            kind: kind == .correction ? .memory : .persona,
            canonicalLocator: locator,
            authority: authority,
            privacy: .localPrivate,
            permittedSurfaces: permittedSurfaces,
            injectionPolicy: policy
        )
        let atom = ContextAtomDraft(
            id: ContextStableID.atom(
                sourceID: sourceID,
                kind: kind,
                headingPath: [id],
                blockAnchor: id
            ),
            sourceID: sourceID,
            kind: kind,
            headingPath: [id],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            authority: authority,
            confidence: 1,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 1_000)),
            privacy: .localPrivate,
            permittedSurfaces: permittedSurfaces,
            injectionPolicy: policy,
            contentRole: kind == .correction ? .memory : .fact
        )
        return ContextCompiledSource(
            descriptor: descriptor,
            sourceHash: sourceHash,
            atoms: [atom]
        )
    }

    func storedGeneration(
        _ compiledSources: [ContextCompiledSource]
    ) -> ContextStoredGeneration {
        let generationID: Int64 = 1
        return ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: generationID,
                parentID: nil,
                createdAt: Date(timeIntervalSince1970: 1_000),
                reason: "projection coverage test",
                sourceFingerprint: "projection-coverage",
                atomCount: compiledSources.flatMap(\.atoms).count,
                sourceCount: compiledSources.count
            ),
            sources: compiledSources.map {
                ContextStoredSource(
                    descriptor: $0.descriptor,
                    sourceHash: $0.sourceHash,
                    health: .healthy,
                    lastError: nil,
                    validFromGeneration: generationID,
                    validToGeneration: nil
                )
            },
            atoms: compiledSources.flatMap(\.atoms).map {
                ContextStoredAtom(
                    versionKey: "\($0.id.rawValue):\(generationID)",
                    draft: $0,
                    validFromGeneration: generationID,
                    validToGeneration: nil
                )
            },
            relationships: []
        )
    }

    /// `kernelCarriesUser` selects which of the two real mirror shapes to build.
    ///
    /// `true` is the full/shadow-mode kernel: the stable prompt renders USER.md,
    /// so the packet copy is a genuine duplicate and precoverage may suppress
    /// it. The coverage/join tests use this shape because their subject is the
    /// fact join, not the carrier gate.
    ///
    /// `false` is the live `ContextFlowMode.active` kernel — SOUL only, exactly
    /// what `NativeContextFlowRuntime.makeMirror` emits — where the packet is
    /// USER.md's only carrier and suppression would drop facts.
    func projectionMirror(
        userText: String,
        kernelCarriesUser: Bool = true
    ) throws -> RequiredDocumentMirror {
        let soul = try RequiredDocument(
            kind: .soul,
            sourceHash: "soul-hash",
            text: "Agent is one mind.",
            tokenCount: 5
        )
        let user = try RequiredDocument(
            kind: .user,
            sourceHash: ContextStableID.digest(parts: [userText]),
            text: userText,
            tokenCount: max(1, userText.utf8.count / 4)
        )
        let fingerprint = "projection-mirror"
        // The rendered prompt tracks includedDocumentIDs: a kernel that claims
        // to carry USER.md must actually contain its bytes, or the fixture
        // would assert on a shape the runtime never produces.
        let kernel = try StablePromptKernel(
            key: StablePromptKernelKey(
                personaID: ContextPersonaID(rawValue: "Agent"),
                surfaceVariant: ContextSurfaceVariant(rawValue: "chat"),
                sourceFingerprint: fingerprint
            ),
            renderedPrompt: kernelCarriesUser
                ? "# SOUL\nAgent is one mind.\n\n# USER\n\(userText)"
                : "# SOUL\nAgent is one mind.",
            includedDocumentIDs: kernelCarriesUser ? [soul.id, user.id] : [soul.id],
            tokenCount: 7
        )
        return try RequiredDocumentMirror(
            personaID: ContextPersonaID(rawValue: "Agent"),
            sourceFingerprint: fingerprint,
            documents: [soul, user],
            kernels: [kernel]
        )
    }

    /// The chat kernel of a fixture mirror — the stable-prompt authority that
    /// precoverage is gated on.
    func chatKernel(
        of mirror: RequiredDocumentMirror
    ) throws -> StablePromptKernel {
        try #require(mirror.kernel(for: ContextSurfaceVariant(rawValue: "chat")))
    }

    /// A persona mirror that carries no USER.md document — the shape behind
    /// `.notApplicable(.noUserDocument)`.
    func projectionMirrorWithoutUserDocument() throws -> RequiredDocumentMirror {
        let soul = try RequiredDocument(
            kind: .soul,
            sourceHash: "soul-hash",
            text: "Agent is one mind.",
            tokenCount: 5
        )
        let fingerprint = "projection-mirror-no-user"
        let kernel = try StablePromptKernel(
            key: StablePromptKernelKey(
                personaID: ContextPersonaID(rawValue: "Agent"),
                surfaceVariant: ContextSurfaceVariant(rawValue: "chat"),
                sourceFingerprint: fingerprint
            ),
            renderedPrompt: "# SOUL\nAgent is one mind.",
            includedDocumentIDs: [soul.id],
            tokenCount: 7
        )
        return try RequiredDocumentMirror(
            personaID: ContextPersonaID(rawValue: "Agent"),
            sourceFingerprint: fingerprint,
            documents: [soul],
            kernels: [kernel]
        )
    }

    func expectNoGenerationMinted(
        after generationID: Int64,
        in store: ContextSQLiteStore
    ) async throws {
        let activeGeneration = try #require(await store.activeGeneration())
        #expect(activeGeneration.id == generationID)
        do {
            _ = try await store.loadGeneration(id: generationID + 1)
            Issue.record("recovery unexpectedly minted SQLite generation \(generationID + 1)")
        } catch let error as ContextFlowStoreError {
            #expect(error == .generationNotFound(generationID + 1))
        }
    }
}
