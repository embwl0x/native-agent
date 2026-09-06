import Foundation
import NativeAgentCore
import Testing
@testable import Context

/// Collects the coordinator's error-level diagnostics so tests can prove the
/// dead-lane alarm fires (and, just as importantly, that it stays quiet on the
/// healthy paths).
private final class CoordinatorDiagnosticLog: @unchecked Sendable {
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

private struct CoordinatorEmbeddingProvider: ContextMarkdownEmbeddingProvider {
    let modelFingerprint = "coordinator-test"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.enumerated().map { index, _ in [Float(index + 1), 0.5] }
    }
}

private actor CoordinatorControllableCompiler: ContextMarkdownCompiling {
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

private actor CoordinatorCancellationCompiler: ContextMarkdownCompiling {
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

private struct CoordinatorMirrorProvider: ContextRequiredDocumentMirrorProviding {
    let mirror: RequiredDocumentMirror
    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] { [mirror] }
}

private actor CoordinatorRefreshingMirrorProvider:
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

private actor CoordinatorControllableProjectionProvider: ContextCompiledProjectionProvider {
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

@Suite(.serialized)
struct ContextFlowCoordinatorTests {
    // EVAL FENCE: core.context
    // Ledger row: context.coordinator.refreshDiscoveredSources
    @Test
    func startRefreshesDiscoveredRegistrationsBeforePublishingTheGeneration() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        let personaRoot = fixture.root.appendingPathComponent("persona", isDirectory: true)
        let owner = "fixture.discovered"
        let staleFile = personaRoot.appendingPathComponent("STALE.md")
        let currentFile = personaRoot.appendingPathComponent("CURRENT.md")
        try "# Discovered\nRetired registration.".write(
            to: staleFile,
            atomically: true,
            encoding: .utf8
        )
        try "# Discovered\nRefreshed registration reaches the generation.".write(
            to: currentFile,
            atomically: true,
            encoding: .utf8
        )

        func registration(file: URL, locator: String) -> ContextSourceRegistration {
            let descriptor = ContextSourceDescriptor(
                id: ContextStableID.source(owner: owner, locator: locator),
                owner: owner,
                kind: .project,
                canonicalLocator: file.path,
                authority: .external,
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .bridge],
                injectionPolicy: .adaptive
            )
            return ContextSourceRegistration(
                descriptor: descriptor,
                fileURL: file,
                allowedRoot: personaRoot
            )
        }

        let stale = registration(file: staleFile, locator: "discovered/STALE.md")
        let current = registration(file: currentFile, locator: "discovered/CURRENT.md")
        try await fixture.registry.register(stale)
        await fixture.refreshingMirrorProvider.replaceRegistrations([current])

        #expect(await fixture.registry.registration(for: stale.descriptor.id) != nil)
        #expect(await fixture.registry.registration(for: current.descriptor.id) == nil)

        await fixture.coordinator.start()

        #expect(await fixture.registry.registration(for: stale.descriptor.id) == nil)
        #expect(await fixture.registry.registration(for: current.descriptor.id) == current)
        let health = await fixture.coordinator.health()
        #expect(health.registeredSourceCount == 2)
        #expect(health.lastError == nil)

        let lease = try await fixture.coordinator.acquireSnapshot()
        defer { lease.release() }
        let entries = lease.snapshot.hotEntries + lease.snapshot.warmEntries
        #expect(entries.contains { $0.text.contains("Refreshed registration reaches") })
        #expect(entries.allSatisfy { !$0.text.contains("Retired registration") })
    }

    @Test
    func projectionInvalidationRebuildsOnlyTheOwningDerivedView() async throws {
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory",
            namespaces: ["memory-v2"]
        )
        let residentWork = CoordinatorControllableProjectionProvider(
            identifier: "resident-work",
            namespaces: ["resident-work"]
        )
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nOne mind.",
            projectionProviders: [memory, residentWork]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        #expect(await memory.invocationCount() == 1)
        #expect(await residentWork.invocationCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "resident-work",
            stableID: "canonical",
            operation: .reconcile,
            reason: "Workshop terminal edge"
        ))
        #expect(await memory.invocationCount() == 1)
        #expect(await residentWork.invocationCount() == 2)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "canonical",
            operation: .reconcile,
            reason: "memory write"
        ))
        #expect(await memory.invocationCount() == 2)
        #expect(await residentWork.invocationCount() == 2)
    }

    @Test
    func memoryInvalidationIgnoresCandidateRootWithoutRefreshingLiveSources() async throws {
        let livePath = URL(fileURLWithPath: "/fixture/live/memory/memory.sqlite")
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory", namespaces: ["memory-v2"], sourceURL: livePath
        )
        let fixture = try await makeFixture(
            mode: .shadow, body: "# Core\nOne continuous mind.", projectionProviders: [memory]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let initialHealth = await fixture.coordinator.health()
        #expect(await memory.invocationCount() == 1)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        let center = DerivedStateInvalidationCenter(coalescingNanoseconds: 60_000_000_000)
        await center.install(fixture.coordinator)
        let candidate = DerivedSourceChange(
            namespace: "memory-v2", stableID: "backed-up-row", operation: .removed,
            canonicalLocator: "/fixture/live/memory/consolidation/candidates/run/memory/memory.sqlite",
            reason: "candidate-only consolidation"
        )
        await center.publish(candidate)
        await center.flush()
        #expect(await memory.invocationCount() == 1)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)
        #expect(await fixture.coordinator.health().lastReconciledAt == initialHealth.lastReconciledAt)

        // A later candidate event with the same row ID cannot swallow the
        // live event in the coalescer. The actual live owner still runs once.
        await center.publish(DerivedSourceChange(
            namespace: "memory-v2", stableID: "backed-up-row", operation: .changed,
            canonicalLocator: "/fixture/live/memory/../memory/memory.sqlite", reason: "live write"
        ))
        await center.publish(candidate)
        await center.flush()
        #expect(await memory.invocationCount() == 2)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "memory-v2", stableID: "legacy", operation: .reconcile,
            reason: "legacy unlocated write"
        ))
        #expect(await memory.invocationCount() == 3)
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona-picker", stableID: "chat", operation: .reconcile,
            reason: "ordinary full refresh"
        ))
        #expect(await memory.invocationCount() == 4)
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 2)
        await center.install(nil)
    }

    @Test
    func fullDirectInvalidationRefreshesSourcesOnceAndRebuildsEveryProjection() async throws {
        let memory = CoordinatorControllableProjectionProvider(
            identifier: "memory",
            namespaces: ["memory-v2"]
        )
        let residentWork = CoordinatorControllableProjectionProvider(
            identifier: "resident-work",
            namespaces: ["resident-work"]
        )
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nOne mind.",
            projectionProviders: [memory, residentWork]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 1)

        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona-picker",
            stableID: "chat",
            operation: .reconcile,
            reason: "picker changed"
        ))
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 2)
        #expect(await memory.invocationCount() == 2)
        #expect(await residentWork.invocationCount() == 2)

        // An unlocatable source change also requests the complete registry.
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: "not-registered",
            operation: .changed,
            reason: "unlocatable change"
        ))
        #expect(await fixture.refreshingMirrorProvider.refreshCount() == 3)
        #expect(await memory.invocationCount() == 3)
        #expect(await residentWork.invocationCount() == 3)
        #expect(await fixture.coordinator.health().lastError == nil)
    }

    @Test
    func retiredDiscoveredSourcesLeaveTheGenerationWithoutRemovingOtherOwners() async throws {
        let projected = compiledSource(
            id: "projected", owner: "fixture.projected", locator: "projected/item",
            kind: .memory, body: "Projected memory remains.",
            authority: .external, policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .shadow, body: "# Core\nStable identity.", projectedSources: [projected]
        )
        defer { fixture.cleanup() }
        let root = fixture.sourceFile.deletingLastPathComponent()
        let file = root.appendingPathComponent("RETIRED.md")
        try "# Retired\nThis source is no longer admitted.".write(
            to: file, atomically: true, encoding: .utf8
        )
        let owner = "fixture.discovered"
        let sourceID = ContextStableID.source(owner: owner, locator: "retired")
        let registration = ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: sourceID, owner: owner, kind: .project, canonicalLocator: file.path,
                authority: .external, privacy: .localPrivate,
                permittedSurfaces: [.chat], injectionPolicy: .adaptive
            ),
            fileURL: file, allowedRoot: root
        )
        await fixture.refreshingMirrorProvider.replaceRegistrations([registration])
        await fixture.coordinator.start()
        let oldLease = try await fixture.coordinator.acquireSnapshot()
        defer { oldLease.release() }
        #expect(try await fixture.store.loadActiveGeneration()?.sources.contains {
            $0.descriptor.id == sourceID
        } == true)

        await fixture.refreshingMirrorProvider.replaceRegistrations([])
        await fixture.coordinator.reconcileAfterWake()

        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(!active.sources.contains { $0.descriptor.id == sourceID })
        #expect(active.sources.contains { $0.descriptor.id == fixture.sourceID })
        #expect(active.sources.contains { $0.descriptor.id == projected.descriptor.id })
        // Retirement affects derived availability, not canonical file bytes or
        // an already-frozen generation lease.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect((oldLease.snapshot.hotEntries + oldLease.snapshot.warmEntries).contains {
            $0.text.contains("no longer admitted")
        })
        #expect(await fixture.coordinator.health().lastError == nil)
    }

    @Test
    func emptyAuthoritativeInventoryRetiresPersistedSourcesAfterRestart() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nRetired persona source.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        await fixture.coordinator.stop()
        #expect(try await fixture.store.loadActiveGeneration()?.sources.count == 1)

        let registry = try ContextSourceRegistry()
        try await registry.replaceOwned(owner: "persona", with: [])
        let restarted = ContextFlowCoordinator(
            mode: .shadow, store: fixture.store, arena: try ContextArena(budget: .mib32),
            registry: registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror)
        )
        await restarted.start()
        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(active.sources.isEmpty)
        #expect(active.atoms.isEmpty)
        #expect(await restarted.health().lastError == nil)
        await restarted.stop()
    }

    @Test
    func cancelledDiscoveryDoesNotReportCompletionAndRemainsRetryable() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nInitial source.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let initialGeneration = await fixture.coordinator.health().activeArenaGenerationID
        try "# Core\nRepaired source.".write(
            to: fixture.sourceFile, atomically: true, encoding: .utf8
        )
        let changes = [DerivedSourceChange(
            namespace: "persona-picker", stableID: "chat", operation: .reconcile,
            reason: "picker changed"
        )]
        // A collaborator can throw CancellationError even when this parent
        // task has not been canceled. Health must stay honest, but cannot be
        // used as evidence that this request completed.
        await fixture.refreshingMirrorProvider.setRefreshCancellation(true)
        #expect(!Task.isCancelled)
        #expect(await fixture.coordinator.reconcileSourceChanges(changes) == false)
        #expect(await fixture.coordinator.health().lastError == nil)
        #expect(await fixture.coordinator.health().activeArenaGenerationID == initialGeneration)

        await fixture.refreshingMirrorProvider.setRefreshCancellation(false)
        #expect(await fixture.coordinator.reconcileSourceChanges(changes) == true)
        #expect(await fixture.coordinator.health().activeArenaGenerationID != initialGeneration)
        let active = try #require(try await fixture.store.loadActiveGeneration())
        #expect(active.atoms.contains { $0.draft.body.contains("Repaired source") })
    }

    @Test
    func startCompilesRegisteredSourcePublishesMirrorAndArena() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nAgent is one mind.")
        defer { fixture.cleanup() }

        await fixture.coordinator.start()
        let health = await fixture.coordinator.health()
        let lease = try await fixture.coordinator.acquireSnapshot()
        defer { lease.release() }

        #expect(health.started)
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.registeredSourceCount == 1)
        #expect(health.lastError == nil)
        #expect(lease.snapshot.requiredDocumentMirrors.count == 1)
        #expect(lease.snapshot.hotEntries.contains(where: { $0.text.contains("Agent is one mind") }))
    }

    @Test
    func directChangePublishesNextGenerationWhileOldLeaseRemainsStable() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nOriginal identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let oldLease = try await fixture.coordinator.acquireSnapshot()

        try "# Core\nUpdated identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "test edit"
        ))

        let current = try await fixture.coordinator.acquireSnapshot()
        defer {
            oldLease.release()
            current.release()
        }
        #expect(oldLease.snapshot.generationID == 1)
        #expect(oldLease.snapshot.hotEntries.contains(where: { $0.text.contains("Original") }))
        #expect(current.snapshot.generationID == 2)
        #expect(current.snapshot.hotEntries.contains(where: { $0.text.contains("Updated") }))
        #expect(fixture.arena.metrics().pinnedGenerations == [1: 1, 2: 1])
    }

    @Test
    func cancelledReconciliationIsControlFlowAndLaterOwnerEdgeRetries() async throws {
        let compiler = CoordinatorCancellationCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nInitial identity.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        await compiler.cancelNextCompilation(containing: "Cancelled revision")
        try "# Core\nCancelled revision.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let cancelled = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "cancelled owner edge"
            ))
        }
        await compiler.waitUntilBlocked()
        cancelled.cancel()
        await cancelled.value

        let afterCancellation = await fixture.coordinator.health()
        let cancellationReceipts = try await fixture.store.recentReceipts(limit: 100)
        #expect(afterCancellation.lastError == nil)
        #expect(afterCancellation.degradedSourceCount == 0)
        #expect(!cancellationReceipts.contains {
            $0.kind == .degraded && $0.summary == "context reconciliation failed"
        })

        try "# Core\nRecovered revision.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "later owner edge"
        ))

        let recovered = await fixture.coordinator.health()
        let generation = try #require(await fixture.store.loadActiveGeneration())
        #expect(recovered.lastError == nil)
        #expect(recovered.degradedSourceCount == 0)
        #expect(generation.generation.id == 2)
        #expect(generation.atoms.contains { $0.draft.body.contains("Recovered revision") })
    }

    @Test
    func failedCompileRetainsLastGoodGenerationAndReportsDegradedSource() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nSafe identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        try "# Core\napi_key = sk-this-must-not-enter-context".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "secret-like edit"
        ))

        let health = await fixture.coordinator.health()
        let snapshot = try await fixture.coordinator.acquireSnapshot()
        defer { snapshot.release() }
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.degradedSourceCount == 1)
        #expect(snapshot.snapshot.hotEntries.contains(where: { $0.text.contains("Safe identity") }))
        #expect(snapshot.snapshot.hotEntries.allSatisfy { !$0.text.contains("sk-this") })
    }

    @Test
    func olderSuspendedReconciliationCannotReplaceNewerPublishedContent() async throws {
        let compiler = CoordinatorControllableCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nInitial identity.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()

        await compiler.blockNextCompilation(containing: "Blocked A")
        try "# Core\nBlocked A identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let older = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "blocked A"
            ))
        }
        await compiler.waitUntilBlocked()

        try "# Core\nPublished B identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "publish B"
        ))

        let publishedB = try await fixture.coordinator.acquireSnapshot()
        #expect(publishedB.snapshot.generationID == 2)
        #expect(publishedB.snapshot.hotEntries.contains { $0.text.contains("Published B") })
        publishedB.release()

        await compiler.releaseBlockedCompilation()
        await older.value

        let final = try await fixture.coordinator.acquireSnapshot()
        defer { final.release() }
        let stored = try #require(await fixture.store.loadActiveGeneration())
        #expect(final.snapshot.generationID == 2)
        #expect(final.snapshot.hotEntries.contains { $0.text.contains("Published B") })
        #expect(final.snapshot.hotEntries.allSatisfy { !$0.text.contains("Blocked A") })
        #expect(stored.generation.id == 2)
        #expect(stored.atoms.contains { $0.draft.body.contains("Published B") })
        #expect(stored.atoms.allSatisfy { !$0.draft.body.contains("Blocked A") })
    }

    @Test
    func concurrentDistinctSourceRequestsCoalesceWithoutLoss() async throws {
        let compiler = CoordinatorControllableCompiler()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nSource A initial.",
            compiler: compiler
        )
        defer { fixture.cleanup() }
        let sourceBFile = fixture.sourceFile.deletingLastPathComponent()
            .appendingPathComponent("PROJECT.md")
        try "# Project\nSource B initial.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        let sourceBID = ContextStableID.source(owner: "project", locator: "PROJECT.md")
        try await fixture.registry.register(ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: sourceBID,
                owner: "project",
                kind: .project,
                canonicalLocator: sourceBFile.path,
                authority: .external,
                privacy: .localPrivate,
                permittedSurfaces: [.chat, .bridge],
                injectionPolicy: .adaptive
            ),
            fileURL: sourceBFile,
            allowedRoot: sourceBFile.deletingLastPathComponent()
        ))
        await fixture.coordinator.reconcileAfterWake()

        await compiler.blockNextCompilation(containing: "Source A revised")
        try "# Core\nSource A revised.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let sourceARequest = Task {
            await fixture.coordinator.sourceDidChange(DerivedSourceChange(
                namespace: "persona",
                stableID: fixture.sourceID.rawValue,
                operation: .changed,
                canonicalLocator: fixture.sourceFile.path,
                reason: "source A"
            ))
        }
        await compiler.waitUntilBlocked()

        try "# Project\nSource B revised.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.reconcileAfterWake()
        await compiler.releaseBlockedCompilation()
        await sourceARequest.value

        let stored = try #require(await fixture.store.loadActiveGeneration())
        let bodies = stored.atoms.map(\.draft.body)
        #expect(stored.generation.id == 2)
        #expect(bodies.contains { $0.contains("Source A revised") })
        #expect(bodies.contains { $0.contains("Source B revised") })
        let snapshot = try await fixture.coordinator.acquireSnapshot()
        defer { snapshot.release() }
        #expect(snapshot.snapshot.generationID == 2)
    }

    @Test
    func identicalContentRecoveryClearsDegradedSourceHealth() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nSafe identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()

        try "# Core\napi_key = sk-this-must-not-enter-context".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "degrade source"
        ))
        #expect(await fixture.coordinator.health().degradedSourceCount == 1)

        try "# Core\nSafe identity.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let recoveredArena = try ContextArena(budget: .mib32)
        let recoveredCoordinator = ContextFlowCoordinator(
            mode: .shadow,
            store: fixture.store,
            arena: recoveredArena,
            registry: fixture.registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror)
        )
        await recoveredCoordinator.reconcileAfterWake()

        let health = await recoveredCoordinator.health()
        let stored = try #require(await fixture.store.loadActiveGeneration())
        #expect(health.degradedSourceCount == 0)
        #expect(health.activeStoreGenerationID == 2)
        #expect(health.activeArenaGenerationID == 2)
        #expect(stored.atoms.contains { $0.draft.body.contains("Safe identity") })
    }

    @Test
    func failedBatchRemainsPendingUntilLaterUnrelatedReconciliation() async throws {
        let projectionProvider = CoordinatorControllableProjectionProvider()
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nSource A initial.",
            warmBody: "# Project\nSource B initial.",
            projectionProviders: [projectionProvider]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.reconcileAfterWake()
        #expect(await projectionProvider.invocationCount() == 1)

        await projectionProvider.failNextProjection()
        try "# Core\nSource A pending after failure.".write(
            to: fixture.sourceFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.reconcileAfterWake()

        for _ in 0..<10 { await Task.yield() }
        let failedHealth = await fixture.coordinator.health()
        #expect(await projectionProvider.invocationCount() == 2)
        #expect(failedHealth.activeStoreGenerationID == 1)
        #expect(failedHealth.activeArenaGenerationID == 1)
        #expect(failedHealth.lastError != nil)

        let sourceBFile = fixture.sourceFile.deletingLastPathComponent()
            .appendingPathComponent("PROJECT.md")
        let sourceBID = ContextStableID.source(owner: "project", locator: "PROJECT.md")
        try "# Project\nSource B unrelated update.".write(
            to: sourceBFile,
            atomically: true,
            encoding: .utf8
        )
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "project",
            stableID: sourceBID.rawValue,
            operation: .changed,
            canonicalLocator: sourceBFile.path,
            reason: "unrelated source B"
        ))

        let stored = try #require(await fixture.store.loadActiveGeneration())
        let health = await fixture.coordinator.health()
        let bodies = stored.atoms.map(\.draft.body)
        #expect(await projectionProvider.invocationCount() == 3)
        #expect(stored.generation.id == 2)
        #expect(bodies.contains { $0.contains("Source A pending after failure") })
        #expect(bodies.contains { $0.contains("Source B unrelated update") })
        #expect(health.activeStoreGenerationID == 2)
        #expect(health.activeArenaGenerationID == 2)
        #expect(health.lastError == nil)
    }

    @Test
    func unchangedReconciliationDoesNotMintGenerationOrDegradeArena() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        await fixture.coordinator.reconcileAfterWake()

        let health = await fixture.coordinator.health()
        #expect(health.activeStoreGenerationID == 1)
        #expect(health.activeArenaGenerationID == 1)
        #expect(health.lastError == nil)
    }

    @Test
    func descriptorOnlyPolicyChangePublishesNextGeneration() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let adaptiveDescriptor = ContextSourceDescriptor(
            id: fixture.sourceID,
            owner: "persona",
            kind: .persona,
            canonicalLocator: fixture.sourceFile.path,
            authority: .identity,
            privacy: .localPrivate,
            permittedSurfaces: [.chat, .bridge],
            injectionPolicy: .adaptive
        )
        try await fixture.registry.replace(ContextSourceRegistration(
            descriptor: adaptiveDescriptor,
            fileURL: fixture.sourceFile,
            allowedRoot: fixture.sourceFile.deletingLastPathComponent(),
            requiredPersonaDocument: .soul,
            personaID: ContextPersonaID(rawValue: "Agent")
        ))
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "test policy change"
        ))

        let generation = try #require(await fixture.store.loadActiveGeneration())
        let source = try #require(generation.sources.first {
            $0.descriptor.id == fixture.sourceID
        })
        let atom = try #require(generation.atoms.first {
            $0.draft.sourceID == fixture.sourceID
        })
        #expect(generation.generation.id == 2)
        #expect(source.descriptor.injectionPolicy == .adaptive)
        #expect(atom.draft.injectionPolicy == .adaptive)
    }

    @Test
    func generationDerivedSetsReuseOneComputationAndIsolatePrivacyKeys() async throws {
        let correction = compiledSource(
            id: "cached-correction",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/cached-correction",
            kind: .correction,
            body: "A cached eligibility walk must retain this explicit correction.",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [correction]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let correctionID = try #require(correction.atoms.first?.id)
        let privateRequest = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Retain the correction.",
            personaIDHint: "Agent",
            allowedPrivacy: [.localPrivate]
        )

        let first = try await fixture.coordinator.prepareFrozenTurn(privateRequest)
        #expect(first.need.mandatoryAtomIDs == [correctionID])
        let afterFirst = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterFirst.computationCount == 1)
        #expect(afterFirst.hitCount == 0)
        #expect(afterFirst.entryCount == 1)

        let second = try await fixture.coordinator.prepareFrozenTurn(privateRequest)
        #expect(second.packet.receipt.selectedAtomIDs == first.packet.receipt.selectedAtomIDs)
        let afterHit = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterHit.computationCount == 1)
        #expect(afterHit.hitCount == 1)
        #expect(afterHit.entryCount == 1)

        let publicRequest = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Retain only public context.",
            personaIDHint: "Agent",
            allowedPrivacy: [.publicSafe]
        )
        let publicOnly = try await fixture.coordinator.prepareFrozenTurn(publicRequest)
        #expect(!publicOnly.need.authorization.allowedSourceIDs.contains(correction.descriptor.id))
        #expect(!publicOnly.need.mandatoryAtomIDs.contains(correctionID))
        _ = try await fixture.coordinator.prepareFrozenTurn(publicRequest)
        let isolated = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(isolated.computationCount == 2)
        #expect(isolated.hitCount == 2)
        #expect(isolated.entryCount == 2)
        print(
            "[turn-speed-a4] four preparations performed "
                + "\(isolated.computationCount) generation-derived computations "
                + "and \(isolated.hitCount) cache hits"
        )

        await fixture.coordinator.stop()
        let stopped = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(stopped.entryCount == 0)
        #expect(stopped.invalidationCount == 1)
    }

    @Test
    func generationDerivedSetsIsolateSurfaceEligibilityAndPrecoverage() async throws {
        let chatSource = compiledSource(
            id: "surface-chat",
            owner: "nativeagent.persona",
            locator: "persona/Agent/surfaces/chat.md",
            kind: .identity,
            body: "Chat-only guidance must be precovered only on chat.",
            authority: .identity,
            policy: .always,
            permittedSurfaces: [.chat]
        )
        let bridgeSource = compiledSource(
            id: "surface-bridge",
            owner: "nativeagent.persona",
            locator: "persona/Agent/surfaces/bridge.md",
            kind: .identity,
            body: "Bridge-only guidance must be precovered only on bridge.",
            authority: .identity,
            policy: .always,
            permittedSurfaces: [.bridge]
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [chatSource, bridgeSource],
            mirrorSurfaceVariants: [
                ContextSurfaceVariant(rawValue: "chat"),
                ContextSurfaceVariant(rawValue: "bridge"),
            ]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(_ surface: ContextSurface) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: surface,
                origin: .localAuthenticated,
                userMessage: "Select this surface's guidance.",
                personaIDHint: "Agent",
                allowedPrivacy: [.localPrivate]
            )
        }

        let chat = try await fixture.coordinator.prepareFrozenTurn(request(.chat))
        #expect(chat.need.authorization.allowedSourceIDs.contains(chatSource.descriptor.id))
        #expect(!chat.need.authorization.allowedSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(chat.need.precoveredSourceIDs.contains(chatSource.descriptor.id))
        #expect(!chat.need.precoveredSourceIDs.contains(bridgeSource.descriptor.id))

        let bridge = try await fixture.coordinator.prepareFrozenTurn(request(.bridge))
        #expect(bridge.need.authorization.allowedSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(!bridge.need.authorization.allowedSourceIDs.contains(chatSource.descriptor.id))
        #expect(bridge.need.precoveredSourceIDs.contains(bridgeSource.descriptor.id))
        #expect(!bridge.need.precoveredSourceIDs.contains(chatSource.descriptor.id))

        _ = try await fixture.coordinator.prepareFrozenTurn(request(.chat))
        _ = try await fixture.coordinator.prepareFrozenTurn(request(.bridge))
        let metrics = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(metrics.computationCount == 2)
        #expect(metrics.hitCount == 2)
        #expect(metrics.entryCount == 2)
    }

    @Test
    func generationDerivedSetsIsolatePersonaSourcesAndScopeDigests() async throws {
        let agentSource = compiledSource(
            id: "persona-agent",
            owner: "nativeagent.persona",
            locator: "persona/Agent/GROWTH.md",
            kind: .relationship,
            body: "Agent-specific growth context.",
            authority: .identity,
            policy: .adaptive
        )
        let secondarySource = compiledSource(
            id: "persona-secondary",
            owner: "nativeagent.persona",
            locator: "persona/Secondary/GROWTH.md",
            kind: .relationship,
            body: "Secondary-specific growth context.",
            authority: .identity,
            policy: .adaptive
        )
        let agentScopeDigest = ContextStableID.digest(parts: ["agent"])
        let agentScopedMemory = compiledSource(
            id: "memory-agent-scope",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScopeDigest)/record",
            kind: .memory,
            body: "A digest-scoped fixture that must trip only for Agent.",
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentSource, secondarySource, agentScopedMemory],
            additionalMirrorPersonaIDs: [ContextPersonaID(rawValue: "Secondary")]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(_ persona: String) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "Select this persona's source set.",
                personaIDHint: persona,
                allowedPrivacy: [.localPrivate]
            )
        }

        let secondary = try await fixture.coordinator.prepareTurn(request("Secondary"))
        #expect(secondary.need.authorization.allowedSourceIDs.contains(secondarySource.descriptor.id))
        #expect(!secondary.need.authorization.allowedSourceIDs.contains(agentSource.descriptor.id))
        #expect(fixture.diagnostics.memoryVocabularyDrift.isEmpty)

        let agent = try await fixture.coordinator.prepareTurn(request("Agent"))
        #expect(agent.need.authorization.allowedSourceIDs.contains(agentSource.descriptor.id))
        #expect(!agent.need.authorization.allowedSourceIDs.contains(secondarySource.descriptor.id))
        let drift = fixture.diagnostics.memoryVocabularyDrift
        #expect(drift.count == 1)
        let driftLine = try #require(drift.first)
        #expect(driftLine.contains(agentScopeDigest))

        _ = try await fixture.coordinator.prepareFrozenTurn(request("Secondary"))
        _ = try await fixture.coordinator.prepareFrozenTurn(request("Agent"))
        let metrics = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(metrics.computationCount == 2)
        #expect(metrics.hitCount == 2)
        #expect(metrics.entryCount == 2)
    }

    @Test
    func generationDerivedCacheKeySeparatesEveryBehaviorDimension() {
        typealias Key = ContextFlowCoordinator.GenerationDerivedCacheKey
        func key(
            generationID: Int64 = 7,
            generationFingerprint: String = "generation-a",
            surface: String = "chat",
            personaID: String = "Agent",
            mirrorFingerprint: String = "mirror-a",
            kernelPersonaID: String = "Agent",
            kernelSurface: String = "chat",
            kernelFingerprint: String = "kernel-a",
            includedDocuments: [String] = ["SOUL.md", "VOICE.md"],
            privacy: [String] = ["local_private"]
        ) -> Key {
            Key(
                generationID: generationID,
                generationSourceFingerprint: generationFingerprint,
                surface: surface,
                personaID: personaID,
                mirrorSourceFingerprint: mirrorFingerprint,
                kernelPersonaID: kernelPersonaID,
                kernelSurface: kernelSurface,
                kernelSourceFingerprint: kernelFingerprint,
                stableIncludedDocumentIDs: includedDocuments,
                allowedPrivacy: privacy
            )
        }
        let baseline = key()
        let variants = [
            key(generationID: 8),
            key(generationFingerprint: "generation-b"),
            key(surface: "bridge"),
            key(personaID: "Secondary"),
            key(mirrorFingerprint: "mirror-b"),
            key(kernelPersonaID: "Secondary"),
            key(kernelSurface: "bridge"),
            key(kernelFingerprint: "kernel-b"),
            key(includedDocuments: ["SOUL.md"]),
            key(privacy: ["public_safe"]),
        ]

        #expect(Set([baseline] + variants).count == variants.count + 1)
    }

    @Test
    func generationChangeClearsDerivedSetsBeforeTheNextTurn() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let request = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Read the current generation.",
            personaIDHint: "Agent",
            allowedPrivacy: [.localPrivate]
        )

        let first = try await fixture.coordinator.prepareFrozenTurn(request)
        #expect(first.generation.generation.id == 1)
        #expect(first.need.authorization.allowedSourceIDs.contains(fixture.sourceID))
        let primed = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(primed.computationCount == 1)
        #expect(primed.entryCount == 1)

        let bridgeOnlyDescriptor = ContextSourceDescriptor(
            id: fixture.sourceID,
            owner: "persona",
            kind: .persona,
            canonicalLocator: fixture.sourceFile.path,
            authority: .identity,
            privacy: .localPrivate,
            permittedSurfaces: [.bridge],
            injectionPolicy: .always
        )
        try await fixture.registry.replace(ContextSourceRegistration(
            descriptor: bridgeOnlyDescriptor,
            fileURL: fixture.sourceFile,
            allowedRoot: fixture.sourceFile.deletingLastPathComponent(),
            requiredPersonaDocument: .soul,
            personaID: ContextPersonaID(rawValue: "Agent")
        ))
        await fixture.coordinator.sourceDidChange(DerivedSourceChange(
            namespace: "persona",
            stableID: fixture.sourceID.rawValue,
            operation: .changed,
            canonicalLocator: fixture.sourceFile.path,
            reason: "cache invalidation negative control"
        ))

        let afterPublication = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(afterPublication.invalidationCount == 1)
        #expect(afterPublication.entryCount == 0)
        let second = try await fixture.coordinator.prepareFrozenTurn(request)
        #expect(second.generation.generation.id == 2)
        #expect(!second.need.authorization.allowedSourceIDs.contains(fixture.sourceID))
        let recomputed = await fixture.coordinator.generationDerivedCacheMetrics()
        #expect(recomputed.computationCount == 2)
        #expect(recomputed.hitCount == 0)
        #expect(recomputed.invalidationCount == 1)
        #expect(recomputed.entryCount == 1)
    }

    @Test
    func largeAdaptiveRelationshipDoesNotDisplaceProtectedCorrection() async throws {
        let relationship = compiledSource(
            id: "relationship",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: String(repeating: "relationship context ", count: 400),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let correction = compiledSource(
            id: "correction",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/correction",
            kind: .correction,
            body: "User's explicit correction remains protected.",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [relationship, correction]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue our unrelated task.",
            personaIDHint: "Agent",
            characterBudget: 6_000
        ))

        let correctionID = try #require(correction.atoms.first?.id)
        let relationshipID = try #require(relationship.atoms.first?.id)
        #expect(prepared.packet.receipt.mandatoryAtomIDs.contains(correctionID))
        #expect(prepared.packet.receipt.coveredMandatoryAtomIDs.contains(correctionID))
        #expect(!prepared.packet.receipt.mandatoryAtomIDs.contains(relationshipID))
        #expect(prepared.packet.receipt.mandatoryCoverage == 1)
        #expect(prepared.packet.receipt.budget.usedCharacters <= 6_000)
    }

    @Test
    func accumulatedCorrectionsUseBoundedRetryAndPreserveRankedContext() async throws {
        let corrections = (0..<4).map { index in
            compiledSource(
                id: "correction-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/correction-\(index)",
                kind: .correction,
                body: String(repeating: "explicit correction \(index) remains authoritative. ", count: 55),
                authority: .explicitCorrection,
                policy: .adaptive
            )
        }
        let memory = compiledSource(
            id: "relevant-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/relevant-memory",
            kind: .memory,
            body: String(
                repeating: "The cobalt garden project uses a bounded resident context path. ",
                count: 20
            ),
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: corrections + [memory]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue the cobalt garden project using resident context.",
            personaIDHint: "Agent",
            characterBudget: 6_000,
            maximumCharacterBudget: 24_000,
            postMandatoryCharacterReserve: 4_000
        ))

        let correctionIDs = try corrections.map {
            try #require($0.atoms.first?.id)
        }
        let memoryID = try #require(memory.atoms.first?.id)
        let expansion = try #require(prepared.budgetExpansion)
        #expect(prepared.need.characterBudget > 6_000)
        #expect(prepared.need.characterBudget <= 24_000)
        #expect(expansion.requestedCharacterBudget == 6_000)
        #expect(expansion.effectiveCharacterBudget == prepared.need.characterBudget)
        #expect(expansion.maximumCharacterBudget == 24_000)
        #expect(expansion.mandatoryCharacterBudget == prepared.packet.receipt.budget.mandatoryCharacters)
        #expect(expansion.grantedPostMandatoryReserve == max(0, expansion.effectiveCharacterBudget - expansion.mandatoryCharacterBudget))
        #expect(prepared.packet.receipt.budget.characterLimit == prepared.need.characterBudget)
        #expect(prepared.packet.receipt.budget.usedCharacters <= prepared.need.characterBudget)
        #expect(Set(prepared.packet.receipt.mandatoryAtomIDs).isSuperset(of: correctionIDs))
        #expect(Set(prepared.packet.receipt.coveredMandatoryAtomIDs).isSuperset(of: correctionIDs))
        #expect(prepared.packet.receipt.selectedAtomIDs.contains(memoryID))
        #expect(prepared.packet.receipt.mandatoryCoverage == 1)
    }

    @Test
    func accumulatedCorrectionsStillFailClosedAtConfiguredCeiling() async throws {
        let corrections = (0..<4).map { index in
            compiledSource(
                id: "oversized-correction-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/oversized-correction-\(index)",
                kind: .correction,
                body: String(repeating: "authoritative correction \(index). ", count: 90),
                authority: .explicitCorrection,
                policy: .adaptive
            )
        }
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: corrections
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        do {
            _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "hello",
                personaIDHint: "Agent",
                characterBudget: 6_000,
                maximumCharacterBudget: 8_000,
                postMandatoryCharacterReserve: 4_000
            ))
            Issue.record("Expected the configured maximum budget to fail closed")
        } catch ContextSelectionError.mandatoryBudgetExceeded(let required, let limit) {
            #expect(required > limit)
            #expect(limit == 8_000)
        }
    }

    /// PRODUCT POLICY (User approved, 2026-07-24): a persona slot id is
    /// PRESENTATION-ONLY — a custom persona reads the SHARED memory store,
    /// exactly as the resident does. This test asserted the OPPOSITE earlier
    /// today; the old "isolation" was an id-vocabulary mismatch protecting an
    /// unmintable, permanently empty scope.
    ///
    /// The mismatched-vocabulary discipline is KEPT: the mirror carries a
    /// persona SLOT id ("CustomPersona" — a persona subdirectory name) while every
    /// projected memory scope is a digest of a RECORD persona id (agent names,
    /// the only vocabulary in the live store: "Agent", "NativeAgent"). Never
    /// the same literal on both sides — a same-string test can't see the live
    /// shape.
    @Test
    func customPersonaSlotAdmitsSharedAgentNameScopedMemory() async throws {
        // Keep the semantic roles distinct after the public exporter rewrites
        // the private resident name to the generic "agent" vocabulary.
        let residentNameScope = ContextStableID.digest(parts: ["agent"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let residentNameMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(residentNameScope)/records/one",
            kind: .memory,
            body: "Record persona id \"Agent\" — an agent name, not a slot id.",
            authority: .canonical,
            policy: .adaptive
        )
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/two",
            kind: .memory,
            body: "Record persona id \"NativeAgent\" — the other live agent name.",
            authority: .canonical,
            policy: .adaptive
        )
        let sharedMemory = compiledSource(
            id: "shared-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/shared/records/three",
            kind: .memory,
            body: "Unscoped shared memory.",
            authority: .canonical,
            policy: .adaptive
        )
        // NEGATIVE CONTROL: the selection filter is still doing real work — a
        // persona DOC belonging to another slot stays out. Without this, a
        // blanket admit-everything regression would green this test.
        let otherPersonaDoc = compiledSource(
            id: "other-persona-doc",
            owner: "nativeagent.persona",
            locator: "persona/Marcus/SOUL.md",
            kind: .fact,
            body: "Another persona slot's identity document.",
            authority: .identity,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [residentNameMemory, agentMemory, sharedMemory, otherPersonaDoc],
            mirrorPersonaID: ContextPersonaID(rawValue: "CustomPersona")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "CustomPersona"
        ))
        let allowed = prepared.need.authorization.allowedSourceIDs

        // Slot "CustomPersona" reads the shared store: BOTH agent-name scopes land.
        #expect(allowed.contains(residentNameMemory.descriptor.id))
        #expect(allowed.contains(agentMemory.descriptor.id))
        #expect(allowed.contains(sharedMemory.descriptor.id))
        #expect(!allowed.contains(otherPersonaDoc.descriptor.id))
        // Shared reads are the healthy path — the drift alarm must stay quiet.
        #expect(fixture.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// The surviving guard after the shared-store decision (2026-07-24). Memory
    /// is shared across persona slots, so no slot can starve and a starvation
    /// alarm would only ever fire on healthy behavior. The mismatch that is
    /// still REAL — and now the only one — is a live memory source scoped by
    /// digest(SLOT id): that means a writer began minting per-SLOT memory
    /// scopes, i.e. the two id vocabularies merged and the presentation-only
    /// decision has to be re-reviewed before a per-slot shard ships.
    ///
    /// This is the counterpart of the production-side guard in
    /// NativeMemoryContextProjectionTests.personaScopeUsesRecordPersonaVocabularyOnly.
    @Test
    func slotIDScopedMemorySourceTripsTheVocabularyDriftAlarm() async throws {
        let slotScope = ContextStableID.digest(parts: ["secondary"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        // Production never emits this shape — the fixture hand-mints it.
        let slotScopedMemory = compiledSource(
            id: "slot-scoped-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(slotScope)/records/one",
            kind: .memory,
            body: "Production-impossible slot-id-scoped memory.",
            authority: .canonical,
            policy: .adaptive
        )
        let liveShapedMemory = compiledSource(
            id: "live-shaped-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/two",
            kind: .memory,
            body: "The shape production actually writes.",
            authority: .canonical,
            policy: .adaptive
        )

        // (a) Slot-id-scoped record present: still ADMITTED (memory is shared —
        //     the alarm never withholds context), but the turn says so loudly.
        let drifted = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [slotScopedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { drifted.cleanup() }
        await drifted.coordinator.start()
        let admitted = try await drifted.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(admitted.need.authorization.allowedSourceIDs.contains(slotScopedMemory.descriptor.id))
        #expect(drifted.diagnostics.memoryVocabularyDrift.count == 1)

        // (b) The live shape — agent-name scopes, mismatched against the slot
        //     id on purpose. Admitted AND silent: this is correct behavior.
        let live = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [liveShapedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { live.cleanup() }
        await live.coordinator.start()
        let healthy = try await live.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(healthy.need.authorization.allowedSourceIDs.contains(liveShapedMemory.descriptor.id))
        #expect(live.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// Drift must be LOUD but BOUNDED: one error line per side-effecting turn
    /// naming the slot id, the computed prefix, and how many sources drifted —
    /// never one line per source or per atom.
    @Test
    func vocabularyDriftLogsOncePerTurnNamingSlotAndPrefix() async throws {
        let slotScope = ContextStableID.digest(parts: ["secondary"])
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let sources = [
            compiledSource(
                id: "slot-scoped-one",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(slotScope)/records/one",
                kind: .memory,
                body: "Slot-scoped memory one.",
                authority: .canonical,
                policy: .adaptive
            ),
            compiledSource(
                id: "slot-scoped-two",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(slotScope)/records/two",
                kind: .memory,
                body: "Slot-scoped memory two.",
                authority: .canonical,
                policy: .adaptive
            ),
            // Mismatched-vocabulary companion: an agent-name scope alongside
            // the drifted ones must not be counted as drift.
            compiledSource(
                id: "agent-memory",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/personas/\(agentScope)/records/three",
                kind: .memory,
                body: "NativeAgent-scoped memory.",
                authority: .canonical,
                policy: .adaptive
            ),
        ]
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: sources,
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))

        let logged = fixture.diagnostics.memoryVocabularyDrift
        #expect(logged.count == 1)
        let line = try #require(logged.first)
        #expect(line.contains("ERROR"))
        #expect(line.contains("\"Secondary\""))
        #expect(line.contains("memory-v2/personas/\(slotScope)/"))
        // 2 of the 3 memory sources drifted — the agent-name one is not drift.
        #expect(line.contains("2 live memory source(s)"))

        // Bounded: a second turn logs once more, never once per source/atom.
        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory again",
            personaIDHint: "Secondary"
        ))
        #expect(fixture.diagnostics.memoryVocabularyDrift.count == 2)
    }

    /// Negative controls: the alarm must not cry wolf on the healthy paths.
    @Test
    func memoryScopeDriftAlarmStaysQuietForResidentAndForSharedScopes() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .memory,
            body: "NativeAgent-scoped memory.",
            authority: .canonical,
            policy: .adaptive
        )
        let sharedMemory = compiledSource(
            id: "shared-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/shared/records/two",
            kind: .memory,
            body: "Shared memory.",
            authority: .canonical,
            policy: .adaptive
        )

        // Resident owns the whole store — never starved.
        let resident = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory],
            mirrorPersonaID: .resident
        )
        defer { resident.cleanup() }
        await resident.coordinator.start()
        _ = try await resident.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: ContextPersonaID.resident.rawValue
        ))
        #expect(resident.diagnostics.memoryVocabularyDrift.isEmpty)

        // A custom persona reading the shared store is the healthy path too.
        let custom = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory, sharedMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { custom.cleanup() }
        await custom.coordinator.start()
        _ = try await custom.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: "Secondary"
        ))
        #expect(custom.diagnostics.memoryVocabularyDrift.isEmpty)
    }

    /// Regression (2026-07-24): memory persona scopes are digests of MemoryV2
    /// record persona ids (agent names, e.g. "NativeAgent"), while the mirror
    /// carries the persona SLOT id ("canonical"). The live app pairs these two
    /// vocabularies, so a prefix built from the slot id can never match — and
    /// every memory source was silently excluded from live turns (memoryRecords
    /// stuck at 0, use_count/activation loop starved). The resident default
    /// persona must admit every memory scope. (Custom slots now do too — see
    /// customPersonaSlotAdmitsSharedAgentNameScopedMemory; a slot id is
    /// presentation-only.) This test intentionally uses MISMATCHED vocabularies
    /// on the two sides — same-string tests could never catch the live shape.
    @Test
    func residentPersonaAdmitsAgentNameScopedMemorySources() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let customScope = ContextStableID.digest(parts: ["secondary"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .memory,
            body: "Default-agent memory record.",
            authority: .canonical,
            policy: .adaptive
        )
        let customMemory = compiledSource(
            id: "custom-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(customScope)/records/two",
            kind: .memory,
            body: "Custom-persona memory record.",
            authority: .canonical,
            policy: .adaptive
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory, customMemory],
            mirrorPersonaID: .resident
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "memory",
            personaIDHint: ContextPersonaID.resident.rawValue
        ))
        let allowed = prepared.need.authorization.allowedSourceIDs

        // The resident owns the whole memory store — both scopes are hers.
        #expect(allowed.contains(agentMemory.descriptor.id))
        #expect(allowed.contains(customMemory.descriptor.id))
    }

    /// Admission is not delivery. This is the end of the pipe: a custom persona
    /// slot must get the shared store's memory as a real ATOM in the prepared
    /// packet, not merely an authorized source id. (Flipped 2026-07-24 from
    /// `customPersonaStillCannotSeeAgentNameScopedMemorySources`, which pinned
    /// the id-vocabulary mismatch as if it were intended isolation.)
    @Test
    func customPersonaSlotGetsSharedMemoryAtomsInThePreparedPacket() async throws {
        let agentScope = ContextStableID.digest(parts: ["nativeagent"])
        let agentMemory = compiledSource(
            id: "agent-memory",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/personas/\(agentScope)/records/one",
            kind: .correction,
            body: "User drinks jasmine tea after lunch, reliably.",
            authority: .explicitCorrection,
            policy: .always
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [agentMemory],
            mirrorPersonaID: ContextPersonaID(rawValue: "Secondary")
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "what does User drink after lunch?",
            personaIDHint: "Secondary"
        ))

        #expect(prepared.need.authorization.allowedSourceIDs.contains(agentMemory.descriptor.id))
        let memoryAtomID = try #require(agentMemory.atoms.first?.id, "fixture must mint an atom")
        #expect(prepared.packet.receipt.selectedAtomIDs.contains(memoryAtomID))
        #expect(prepared.packet.selectedItems.contains { $0.text.contains("jasmine tea") })
    }

    @Test
    func generatedUSERProjectionIsPrecoveredOnlyWithExactHealthyMemoryParity() throws {
        let firstFact = "User chooses jasmine tea after lunch."
        let secondFact = "Quiet morning work should never make noise."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(firstFact)
        - \(secondFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: "\(firstFact)\n\(secondFact)",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let firstMemory = compiledSource(
            id: "memory-first",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/first",
            kind: .memory,
            body: firstFact,
            authority: .canonical,
            policy: .adaptive
        )
        let secondMemory = compiledSource(
            id: "memory-second",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/second",
            kind: .memory,
            body: secondFact,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, firstMemory, secondMemory])
        let mirror = try projectionMirror(userText: generatedUSER)
        let precovered = ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(precovered == [userSourceID])

        let authorization = ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: [.localPrivate],
            allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
        )
        let baselineNeed = NeedSignal(
            message: "jasmine tea and quiet morning work",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: authorization,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let candidateNeed = NeedSignal(
            message: baselineNeed.message,
            surface: baselineNeed.surface,
            origin: baselineNeed.origin,
            authorization: authorization,
            precoveredSourceIDs: precovered,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let baseline = try ContextSelector().select(baselineNeed, from: generation)
        let candidate = try ContextSelector().select(candidateNeed, from: generation)

        #expect(baseline.selectedItems.contains { $0.pointer.sourceID == userSourceID })
        #expect(candidate.selectedItems.allSatisfy { $0.pointer.sourceID != userSourceID })
        #expect(candidate.characterCount < baseline.characterCount)
        #expect(candidate.selectedItems.map(\.text).contains(firstFact))
        #expect(candidate.selectedItems.map(\.text).contains(secondFact))
        print(
            "[memory-quality-metric] duplicate-projection baseline="
                + "\(baseline.characterCount)chars candidate=\(candidate.characterCount)chars"
        )

        // The SAME generation under the live `ContextFlowMode.active` kernel
        // (SOUL only) must NOT suppress: there the packet is USER.md's only
        // carrier. Facts and atoms are held fixed and only the kernel varies,
        // so the kernel is provably what drives the outcome.
        let activeModeMirror = try projectionMirror(
            userText: generatedUSER,
            kernelCarriesUser: false
        )
        let activeModePrecovered = ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: activeModeMirror,
            kernel: try chatKernel(of: activeModeMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(activeModePrecovered.isEmpty)
        let activeModeNeed = NeedSignal(
            message: baselineNeed.message,
            surface: baselineNeed.surface,
            origin: baselineNeed.origin,
            authorization: authorization,
            precoveredSourceIDs: activeModePrecovered,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let activeModePacket = try ContextSelector().select(activeModeNeed, from: generation)
        // The harm this gate prevents: under the active-mode kernel USER.md's
        // atom must stay in the packet, because nothing else is carrying it.
        #expect(activeModePacket.selectedItems.contains { $0.pointer.sourceID == userSourceID })

        let incomplete = storedGeneration([user, firstMemory])
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: incomplete.sources,
            generation: incomplete
        ).isEmpty)
        let manualMirror = try projectionMirror(userText: """
        <!-- USER_PREAMBLE_START -->
        A manual instruction that must remain visible.
        <!-- USER_PREAMBLE_END -->

        \(generatedUSER)
        """)
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: manualMirror,
            kernel: try chatKernel(of: manualMirror),
            selectedSources: generation.sources,
            generation: generation
        ).isEmpty)
    }

    /// The join compares a USER.md line (already through the display renderer)
    /// against a memory atom body (raw stored text). For any row whose stored
    /// text carries a leading timestamp those two strings DIFFER, and the
    /// all-or-nothing join then killed precoverage for the entire document.
    ///
    /// Every pair below is deliberately two DIFFERENT literals — a test that
    /// binds one literal to both sides can never observe this break, which is
    /// exactly how the bug shipped.
    @Test
    func precoverageJoinsTimestampedRecordBodiesAgainstStrippedUSERLines() throws {
        // (fact as USER.md renders it, body as the projection stores it)
        let pairs: [(fact: String, body: String)] = [
            (
                "User keeps the espresso machine on the left counter.",
                "[2026-07-24T09:15:00Z] User keeps the espresso machine on the left counter."
            ),
            (
                "Quiet morning work should never make noise.",
                "2026-07-19 · Quiet morning work should never make noise."
            ),
            (
                "User reviews the release checklist before every ship.",
                "createdAt: 2026-07-20 User reviews the release checklist before every ship."
            ),
            // Date-critical rows are the ONE shape where the two sides are
            // legitimately the same literal: the kind-aware display renderer
            // strips nothing from them, and the atom body is the same stored
            // text, so both sides carry the stamp verbatim. The join must not
            // "fix" that by reducing them — that reduction merged distinct
            // dated records. Distinguishability has its own test with teeth:
            // `dateCriticalFactsDifferingOnlyByDateAreNotCoveredByOneAtom`.
            (
                "2026-08-01 09:00 Dentist appointment downtown.",
                "2026-08-01 09:00 Dentist appointment downtown."
            ),
        ]
        // Guard the guard: three of four pairs must genuinely differ, or the
        // test has quietly degenerated into the single-literal blind spot.
        #expect(pairs.filter { $0.fact != $0.body }.count == 3)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        \(pairs.map { "- \($0.fact)" }.joined(separator: "\n"))

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: pairs.map(\.fact).joined(separator: "\n"),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memories = pairs.enumerated().map { index, pair in
            compiledSource(
                id: "memory-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(index)",
                kind: .memory,
                body: pair.body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let generation = storedGeneration([user] + memories)
        let mirror = try projectionMirror(userText: generatedUSER)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(outcome.precoveredSourceIDs == [userSourceID])

        // The atom bodies themselves are untouched — the shared helper is a
        // comparison key, not a rewrite of what the model reads.
        let storedBodies = Set(generation.atoms.map(\.draft.body))
        #expect(pairs.allSatisfy { storedBodies.contains($0.body) })
    }

    /// A join key that converges the two renderers by DESTROYING leading date
    /// stamps also merges two records that differ only by their date. Both
    /// USER.md lines then reduce to one entry, one admitted atom "covers" the
    /// pair, precoverage suppresses USER.md — and the fact whose atom was NOT
    /// admitted is silently deleted from the turn. Silent context loss.
    ///
    /// Live shape, deliberately mismatched on both axes at once: an ordinary
    /// row whose atom body still carries a storage timestamp the USER.md line
    /// dropped (the convergence the key exists for) sits alongside two
    /// date-critical rows that differ ONLY in their stamp (the distinction the
    /// key must preserve). Passing both at once is the whole requirement.
    @Test
    func dateCriticalFactsDifferingOnlyByDateAreNotCoveredByOneAtom() throws {
        let augustFact = "2026-08-01 09:00 Dentist appointment downtown."
        let septemberFact = "2026-09-01 09:00 Dentist appointment downtown."
        let ordinaryFact = "User keeps the espresso machine on the left counter."
        let ordinaryBody = "[2026-07-24T09:15:00Z] User keeps the espresso machine on the left counter."
        #expect(augustFact != septemberFact)
        #expect(ordinaryFact != ordinaryBody)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(ordinaryFact)
        - \(augustFact)
        - \(septemberFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: [ordinaryFact, augustFact, septemberFact].joined(separator: "\n"),
            authority: .explicitCorrection,
            policy: .adaptive
        )
        func memoryAtom(_ id: String, _ body: String) -> ContextCompiledSource {
            compiledSource(
                id: "memory-\(id)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(id)",
                kind: .memory,
                body: body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let ordinaryMemory = memoryAtom("ordinary", ordinaryBody)
        let augustMemory = memoryAtom("august", augustFact)
        let septemberMemory = memoryAtom("september", septemberFact)
        let mirror = try projectionMirror(userText: generatedUSER)

        // Only the AUGUST atom is admitted. The September fact lives nowhere
        // else in the turn, so USER.md must stay injected and say why.
        let partial = storedGeneration([user, ordinaryMemory, augustMemory])
        let partialOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: partial.sources,
            generation: partial
        )
        #expect(partialOutcome == .uncoveredFact(
            fact: septemberFact,
            reason: .admissionAsymmetry
        ))
        #expect(ContextFlowCoordinator.generatedUserProjectionPrecoverage(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: partial.sources,
            generation: partial
        ).isEmpty)

        // Mirror image: admitting only SEPTEMBER must strand August, not
        // silently pass because "some dentist atom exists".
        let mirrored = storedGeneration([user, ordinaryMemory, septemberMemory])
        #expect(ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: mirrored.sources,
            generation: mirrored
        ) == .uncoveredFact(fact: augustFact, reason: .admissionAsymmetry))

        // And the key still CONVERGES: with every atom admitted — including the
        // ordinary row whose body carries a stamp its USER.md line dropped —
        // the whole document precovers.
        let complete = storedGeneration([user, ordinaryMemory, augustMemory, septemberMemory])
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: complete.sources,
            generation: complete
        ).precoveredSourceIDs == [userSourceID])
    }

    /// USER.md can carry a fact whose record the memory projection refused
    /// (lifecycle `corrected`, non-durable text, secret shape, size). No atom
    /// carries it, so suppressing USER.md would DELETE that fact from the turn.
    /// The honest behavior is to keep USER.md injected — and to say so, loudly
    /// and once, naming the fact and the reason class.
    @Test
    func projectionRejectedFactKeepsUSERInjectedAndIsNamedInOneDiagnostic() throws {
        let coveredFact = "User reviews the release checklist before every ship."
        // A live shape: the superseded half of a corrected pair. Its record is
        // lifecycle=corrected, so the projection compiles no atom for it.
        let rejectedFact = "User keeps nocturnal hours — 3 AM check-ins observed."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(coveredFact)
        - \(rejectedFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: "\(coveredFact)\n\(rejectedFact)",
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let coveredMemory = compiledSource(
            id: "memory-covered",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/covered",
            kind: .memory,
            body: "[2026-07-20] \(coveredFact)",
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, coveredMemory])
        let mirror = try projectionMirror(userText: generatedUSER)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: mirror,
            kernel: try chatKernel(of: mirror),
            selectedSources: generation.sources,
            generation: generation
        )

        // Fail SAFE: nothing suppressed, so the uncovered fact still reaches
        // the turn through USER.md.
        #expect(outcome.precoveredSourceIDs.isEmpty)
        #expect(outcome == .uncoveredFact(
            fact: rejectedFact,
            reason: .admissionAsymmetry
        ))

        // ...and it is reported: once, naming the fact and the reason class.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let firstMessage = reporter.message(for: outcome)
        let first = try #require(firstMessage)
        #expect(first.contains(rejectedFact))
        #expect(first.contains("admission-asymmetry"))
        let repeatMessage = reporter.message(for: outcome)
        #expect(repeatMessage == nil)

        // A DIFFERENT uncovered fact is a different state and reports again —
        // the dedupe is per-state, not a global mute.
        let otherOutcome = ContextFlowCoordinator.GeneratedUserPrecoverageOutcome.uncoveredFact(
            fact: coveredFact,
            reason: .admissionAsymmetry
        )
        let otherRaw = reporter.message(for: otherOutcome)
        let otherMessage = try #require(otherRaw)
        #expect(otherMessage.contains(coveredFact))
    }

    @Test
    func precoverageDiagnosticSeparatesRendererDivergenceFromAdmissionAsymmetry() throws {
        let fact = "User reviews the release checklist before every ship."
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        // An atom whose text CONTAINS the fact but does not canonicalize to it
        // — the residual-normalization shape. If a renderer ever drifts again
        // this is the class the log must name, distinct from "no atom at all".
        let nearMiss = compiledSource(
            id: "memory-near",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/near",
            kind: .memory,
            body: "note — \(fact)",
            authority: .canonical,
            policy: .adaptive
        )
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/Agent/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let generation = storedGeneration([user, nearMiss])
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: try projectionMirror(userText: generatedUSER),
            kernel: try chatKernel(of: try projectionMirror(userText: generatedUSER)),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(outcome == .uncoveredFact(fact: fact, reason: .rendererDivergence))

        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let message = reporter.message(for: outcome)
        let line = try #require(message)
        #expect(line.contains("renderer-divergence"))
    }

    /// The state this batch's investigation actually landed in (2026-07-24):
    /// on User's LIVE data precoverage SUCCEEDS — 43/43 generated facts carried
    /// by memory atoms — and said nothing at all. Working suppression and
    /// never-ran were the same observation from outside the app; establishing
    /// which one it was took a read of the live SQLite generation.
    ///
    /// Success must therefore be a receipt, and it must name what it bought.
    /// The USER.md line and its atom body are deliberately DIFFERENT literals
    /// (the live shape: stored text keeps a stamp the rendered line dropped),
    /// so a renderer regression cannot pass this by tautology.
    @Test
    func precoverageSuccessReportsWhatItSuppressedOncePerState() throws {
        let firstFact = "User reviews the release checklist before every ship."
        let firstBody = "[2026-07-20T11:02:00Z] User reviews the release checklist before every ship."
        let secondFact = "User's quiet hours end around 03:00."
        let secondBody = "2026-07-18 User's quiet hours end around 03:00."
        #expect(firstFact != firstBody)
        #expect(secondFact != secondBody)

        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(firstFact)
        - \(secondFact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let userBody = "\(firstFact)\n\(secondFact)"
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: userBody,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memories = [firstBody, secondBody].enumerated().map { index, body in
            compiledSource(
                id: "memory-\(index)",
                owner: "nativeagent.memory-v2",
                locator: "memory-v2/records/\(index)",
                kind: .memory,
                body: body,
                authority: .canonical,
                policy: .adaptive
            )
        }
        let generation = storedGeneration([user] + memories)
        let outcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: try projectionMirror(userText: generatedUSER),
            kernel: try chatKernel(of: try projectionMirror(userText: generatedUSER)),
            selectedSources: generation.sources,
            generation: generation
        )
        let summary = try #require({ () -> ContextFlowCoordinator
            .GeneratedUserPrecoverageOutcome.Precovered? in
            guard case .precovered(let summary) = outcome else { return nil }
            return summary
        }())
        #expect(summary.factCount == 2)
        #expect(summary.suppressedAtomCount == 1)
        #expect(summary.suppressedChars == userBody.count)

        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let successMessage = reporter.message(for: outcome)
        // A successful precoverage must leave a receipt; silence is the defect.
        let line = try #require(successMessage)
        // All three summary fields must survive into the line — a receipt
        // missing one of them is a receipt that cannot be reconciled against
        // the packet.
        #expect(line.contains("all 2 generated fact(s)"))
        #expect(line.contains("1 USER.md context atom(s)"))
        #expect(line.contains("\(userBody.count) chars"))
        // The line must state the CONDITION that makes suppression safe — that
        // the stable prompt kernel independently carries USER.md. The previous
        // wording instead asserted the persona lane "injects USER.md
        // separately" unconditionally, which is false in active mode and is
        // precisely the claim that licensed a fact-loss path.
        #expect(line.lowercased().contains("stable prompt kernel"))
        #expect(!line.contains("deliberately untouched by precoverage"))
        // Bounded: the same state does not reprint every turn.
        let repeatMessage = reporter.message(for: outcome)
        #expect(repeatMessage == nil)
    }

    /// `.notApplicable` used to be one opaque case reached by four different
    /// guards, and it emitted nothing — so "precoverage declined" and
    /// "precoverage is broken" produced identical logs. Each guard now names
    /// itself, and each distinct reason reports once.
    @Test
    func precoverageNotApplicableNamesTheGuardThatDeclined() throws {
        let fact = "User reviews the release checklist before every ship."
        let body = "[2026-07-20T11:02:00Z] User reviews the release checklist before every ship."
        #expect(fact != body)
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memory = compiledSource(
            id: "memory-0",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/0",
            kind: .memory,
            body: body,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, memory])

        func outcome(
            mirrorText: String? = generatedUSER,
            sources: [ContextStoredSource]? = nil
        ) throws -> ContextFlowCoordinator.GeneratedUserPrecoverageOutcome {
            let mirror = try mirrorText.map { try projectionMirror(userText: $0) }
                ?? projectionMirrorWithoutUserDocument()
            return ContextFlowCoordinator.generatedUserProjectionOutcome(
                mirror: mirror,
                kernel: try chatKernel(of: mirror),
                selectedSources: sources ?? generation.sources,
                generation: generation
            )
        }

        // The mirror carries no USER.md at all.
        #expect(try outcome(mirrorText: nil) == .notApplicable(.noUserDocument))

        // A manual preamble — User's hand-written instruction must never be
        // suppressed by a projection argument.
        #expect(try outcome(mirrorText: """
        <!-- USER_PREAMBLE_START -->
        Never schedule anything before 09:00.
        <!-- USER_PREAMBLE_END -->

        \(generatedUSER)
        """) == .notApplicable(.notGeneratedProjection))

        // Well-formed markers, no bullets between them.
        #expect(try outcome(mirrorText: """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        <!-- USER_MD_AUTOGEN_END -->
        """) == .notApplicable(.noGeneratedFacts))

        // USER.md source present but degraded — precoverage must decline, and
        // say that it declined for THIS reason rather than a coverage one.
        let degradedUser = generation.sources.map { source in
            source.descriptor.canonicalLocator.hasSuffix("/USER.md")
                ? ContextStoredSource(
                    descriptor: source.descriptor,
                    sourceHash: source.sourceHash,
                    health: .degraded,
                    lastError: "read failed",
                    validFromGeneration: source.validFromGeneration,
                    validToGeneration: source.validToGeneration
                )
                : source
        }
        #expect(try outcome(sources: degradedUser) == .notApplicable(.noHealthyUserSource))

        // No memory sources selected at all — nothing could carry a fact.
        #expect(try outcome(sources: generation.sources.filter {
            $0.descriptor.owner != "nativeagent.memory-v2"
        }) == .notApplicable(.noHealthyMemorySource))

        // Each distinct reason reports once, and the reason class is IN the
        // line — a bare "not applicable" would be the silence this replaced.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let userMessage = reporter.message(for: .notApplicable(.noUserDocument))
        let userLine = try #require(userMessage)
        #expect(userLine.contains("no-user-document"))
        let repeatMessage = reporter.message(for: .notApplicable(.noUserDocument))
        #expect(repeatMessage == nil)
        let memoryMessage = reporter.message(for: .notApplicable(.noHealthyMemorySource))
        let memoryLine = try #require(memoryMessage)
        #expect(memoryLine.contains("no-healthy-memory-source"))
    }

    /// The live `ContextFlowMode.active` kernel renders SOUL and VOICE only, so
    /// USER.md is NOT in the stable prompt and the context packet is its only
    /// carrier. Suppressing it there deletes user facts outright.
    ///
    /// Measured on 1053 live context-flow turns (2026-07-24): `stableChars`
    /// held at ~10,564 — below USER.md's own 15,006 bytes, so it was provably
    /// never in the stable segment — while 757 turns (72%) selected ZERO memory
    /// atoms. Precoverage fired on the strength of fact parity alone, and
    /// `precoveredSourceIDs` hard-drops a source from the ranked candidates
    /// (`ContextSelection.select`), so those facts reached no lane at all.
    ///
    /// Every value below is a DISTINCT literal: the fact text differs from the
    /// stored body (leading stamp), and the two kernels differ in which
    /// documents they carry. Nothing is compared against itself.
    @Test
    func precoverageDeclinesWhenStablePromptDoesNotCarryUserDocument() throws {
        let fact = "User's quiet hours end around 03:00 — a 3 AM message means he woke up."
        let body = "[2026-07-24T03:04:00Z] User's quiet hours end around 03:00 "
            + "— a 3 AM message means he woke up."
        // Mismatched by construction: if these were one literal the join could
        // not distinguish a working renderer from a broken one.
        #expect(fact != body)
        let generatedUSER = """
        <!-- USER_MD_AUTOGEN_START -->
        # User Facts (auto-generated from memory SQLite)

        - \(fact)

        <!-- USER_MD_AUTOGEN_END -->
        """
        let user = compiledSource(
            id: "user-generated",
            owner: "nativeagent.persona",
            locator: "persona/canonical/USER.md",
            kind: .relationship,
            body: fact,
            authority: .explicitCorrection,
            policy: .adaptive
        )
        let memory = compiledSource(
            id: "memory-0",
            owner: "nativeagent.memory-v2",
            locator: "memory-v2/records/0",
            kind: .memory,
            body: body,
            authority: .canonical,
            policy: .adaptive
        )
        let generation = storedGeneration([user, memory])

        // Coverage parity HOLDS on both sides — the memory atom really does
        // carry the fact. Only the kernel differs, so any behavior difference
        // is attributable to the carrier gate and nothing else.
        let fullMirror = try projectionMirror(userText: generatedUSER, kernelCarriesUser: true)
        let activeMirror = try projectionMirror(userText: generatedUSER, kernelCarriesUser: false)
        #expect(try chatKernel(of: fullMirror).renderedPrompt.contains(fact))
        #expect(!(try chatKernel(of: activeMirror).renderedPrompt.contains(fact)))

        // Stable prompt carries USER.md → suppression is genuine de-duplication.
        let fullOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: fullMirror,
            kernel: try chatKernel(of: fullMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        let summary = try #require({ () -> ContextFlowCoordinator
            .GeneratedUserPrecoverageOutcome.Precovered? in
            guard case .precovered(let summary) = fullOutcome else { return nil }
            return summary
        }())
        #expect(summary.factCount == 1)
        #expect(summary.suppressedAtomCount == 1)

        // Stable prompt does NOT carry USER.md → must decline, naming the gate.
        let activeOutcome = ContextFlowCoordinator.generatedUserProjectionOutcome(
            mirror: activeMirror,
            kernel: try chatKernel(of: activeMirror),
            selectedSources: generation.sources,
            generation: generation
        )
        #expect(activeOutcome == .notApplicable(.userDocumentNotInStablePrompt))
        #expect(activeOutcome.precoveredSourceIDs.isEmpty)

        // End-to-end: the fact must survive into the packet on the active-mode
        // shape. This is the assertion that would have caught the live loss.
        let authorization = ContextSelectionAuthorization(
            allowedOrigins: [.localAuthenticated],
            allowedPrivacy: [.localPrivate],
            allowedSourceIDs: Set(generation.sources.map(\.descriptor.id))
        )
        let need = NeedSignal(
            message: "when does User's quiet time end",
            surface: .chat,
            origin: .localAuthenticated,
            authorization: authorization,
            precoveredSourceIDs: activeOutcome.precoveredSourceIDs,
            availableGenerationID: generation.generation.id,
            characterBudget: 1_000,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let packet = try ContextSelector().select(need, from: generation)
        let userSourceID = try #require(user.atoms.first?.sourceID)
        #expect(packet.selectedItems.contains { $0.pointer.sourceID == userSourceID })

        // The receipt must name the gate, so this state is diagnosable from
        // logs alone rather than by reading the user's SQLite store.
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let gateMessage = reporter.message(for: activeOutcome)
        let line = try #require(gateMessage)
        #expect(line.contains("user-document-not-in-stable-prompt"))
        #expect(line.contains("only carrier"))
        let repeatGateMessage = reporter.message(for: activeOutcome)
        #expect(repeatGateMessage == nil)
    }

    /// "Bounded" has to survive CHURN, not just repetition. A memo that evicts
    /// or clears on overflow bounds memory while leaving emission unbounded —
    /// a rotating state would then print on every turn forever, which is the
    /// per-turn printer the memo exists to prevent. Past the cap the reporter
    /// mutes itself, and says once that it did.
    @Test
    func precoverageReporterMutesItselfAloudInsteadOfPrintingForever() throws {
        var reporter = ContextFlowCoordinator.PrecoverageOutcomeReporter()
        let cap = ContextFlowCoordinator.PrecoverageOutcomeReporter.signatureCap
        let states = (0..<(cap + 4)).map { index in
            ContextFlowCoordinator.GeneratedUserPrecoverageOutcome.uncoveredFact(
                fact: "Churning fact number \(index).",
                reason: .admissionAsymmetry
            )
        }
        var lines: [String] = []
        // Two full passes: the second would double the output if the memo
        // cleared instead of muting.
        for _ in 0..<2 {
            for state in states {
                if let line = reporter.message(for: state) { lines.append(line) }
            }
        }
        #expect(lines.count == cap + 1)
        let mutedLine = try #require(lines.last)
        #expect(mutedLine.contains("muted"))
        // Even a brand-new state stays quiet once muted.
        let afterMute = reporter.message(for: .notApplicable(.noUserDocument))
        #expect(afterMute == nil)
    }

    @Test
    func normalPressureRehydratesWarmEntriesFromSameDurableGeneration() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nStable identity.",
            warmBody: "# Project\nKeep the recovery plan warm."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let initial = try await fixture.coordinator.acquireSnapshot()
        let generationID = initial.snapshot.generationID
        let warmEntryKeys = initial.snapshot.warmEntries.map(\.key)
        _ = try #require(warmEntryKeys.first)
        initial.release()

        let trim = try await fixture.coordinator.applyMemoryPressure(.critical)
        #expect(trim.evictedWarmEntryKeys == warmEntryKeys)
        #expect(fixture.arena.currentSnapshot()?.warmEntries.isEmpty == true)

        _ = try await fixture.coordinator.applyMemoryPressure(.normal)

        let recovered = try await fixture.coordinator.acquireSnapshot()
        defer { recovered.release() }
        #expect(recovered.snapshot.generationID == generationID)
        #expect(recovered.snapshot.warmEntries.map(\.key) == warmEntryKeys)
        #expect(fixture.arena.metrics().pressure == .normal)
        try await expectNoGenerationMinted(after: generationID, in: fixture.store)
    }

    @Test
    func wakeRehydratesWarmEntriesFromSameDurableGeneration() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Core\nStable identity.",
            warmBody: "# Project\nRestore this working set after wake."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let initial = try await fixture.coordinator.acquireSnapshot()
        let generationID = initial.snapshot.generationID
        let warmEntryKeys = initial.snapshot.warmEntries.map(\.key)
        _ = try #require(warmEntryKeys.first)
        initial.release()

        _ = try await fixture.coordinator.applyMemoryPressure(.critical)
        #expect(fixture.arena.currentSnapshot()?.warmEntries.isEmpty == true)

        await fixture.coordinator.reconcileAfterWake()

        let recovered = try await fixture.coordinator.acquireSnapshot()
        defer { recovered.release() }
        #expect(recovered.snapshot.generationID == generationID)
        #expect(recovered.snapshot.warmEntries.map(\.key) == warmEntryKeys)
        #expect(fixture.arena.metrics().pressure == .normal)
        try await expectNoGenerationMinted(after: generationID, in: fixture.store)
    }

    @Test
    func offModeDoesNotCompileOrStartWatchers() async throws {
        let fixture = try await makeFixture(mode: .off, body: "# Core\nIdentity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let health = await fixture.coordinator.health()
        #expect(health.mode == .off)
        #expect(health.started)
        #expect(health.activeStoreGenerationID == nil)
        #expect(health.activeArenaGenerationID == nil)
    }

    @Test
    func liveTurnSelectionAndOutcomeProduceBoundedFeedbackReceipts() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Who are you?",
            personaIDHint: "Agent"
        ))
        #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        await prepared.recordOutcome(.completed)

        var feedback: [ContextStoreReceipt] = []
        for _ in 0..<100 {
            feedback = try await fixture.store.recentReceipts(limit: 20)
                .filter { $0.kind == .feedback }
            if feedback.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(feedback.contains { $0.details["signal"] == "selection" })
        #expect(feedback.contains { $0.details["signal"] == "outcome.completed" })
    }

    // EVAL FENCE: core.context / context.selection.liveLatency
    @Test
    func liveSelectionReceiptCarriesMonotonicLatencyProvenanceAndRejectsAdverseRows() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What should I remember about this session?",
            personaIDHint: "Agent"
        ))
        let packetReceipt = prepared.packet.receipt
        // This proves provenance, not machine speed: zero microseconds is a
        // valid clock resolution, and no wall-clock envelope is asserted here.
        #expect(packetReceipt.selectionLatencyProvenance == .monotonicClock)
        #expect(packetReceipt.measuredSelectionMicroseconds != nil)

        // The receipt crosses process/storage boundaries as Codable data. A
        // current producer must retain the measured provenance, while a
        // pre-provenance wire payload must still decode honestly as unknown.
        let encodedReceipt = try JSONEncoder().encode(packetReceipt)
        let receiptWire = try #require(
            try JSONSerialization.jsonObject(with: encodedReceipt) as? [String: Any]
        )
        #expect(
            receiptWire["selectionLatencyProvenance"] as? String
                == ContextSelectionLatencyProvenance.monotonicClock.rawValue
        )
        let roundTrippedReceipt = try JSONDecoder().decode(
            ContextSelectionReceipt.self,
            from: encodedReceipt
        )
        #expect(roundTrippedReceipt.selectionLatencyProvenance == .monotonicClock)
        #expect(roundTrippedReceipt.measuredSelectionMicroseconds == packetReceipt.measuredSelectionMicroseconds)

        var legacyReceiptWire = receiptWire
        legacyReceiptWire.removeValue(forKey: "selectionLatencyProvenance")
        let legacyReceiptData = try JSONSerialization.data(withJSONObject: legacyReceiptWire)
        let legacyReceipt = try JSONDecoder().decode(ContextSelectionReceipt.self, from: legacyReceiptData)
        #expect(legacyReceipt.selectionLatencyProvenance == nil)
        #expect(legacyReceipt.measuredSelectionMicroseconds == packetReceipt.measuredSelectionMicroseconds)

        var durableReceipt: ContextStoreReceipt?
        for _ in 0..<100 {
            durableReceipt = try await fixture.store.recentReceipts(limit: 50).first(where: {
                $0.kind == .selection && $0.details["receipt_id"] == packetReceipt.id
            })
            if durableReceipt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stored = try #require(durableReceipt)
        let observed = ContextSelectionLatencyObservation(receipt: stored)
        #expect(observed.status == .measured)
        #expect(observed.provenance == .monotonicClock)
        #expect(observed.surface == .chat)
        #expect(observed.microseconds == packetReceipt.measuredSelectionMicroseconds)
        #expect(stored.details["selection_microseconds"] == packetReceipt.measuredSelectionMicroseconds.map { String($0) })

        let missing = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture missing latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "absent",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.unavailable.rawValue,
            ]
        ))
        #expect(missing.status == .missing)
        #expect(missing.microseconds == nil)

        let malformed = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture malformed latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "-9",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.monotonicClock.rawValue,
            ]
        ))
        #expect(malformed.status == .invalid)
        #expect(malformed.microseconds == nil)

        let replaySupplied = ContextSelectionLatencyObservation(receipt: ContextStoreReceipt(
            kind: .selection,
            summary: "fixture replay latency",
            details: [
                "surface": ContextSurface.chat.rawValue,
                "selection_microseconds": "12",
                "selection_latency_provenance": ContextSelectionLatencyProvenance.callerSupplied.rawValue,
            ]
        ))
        #expect(replaySupplied.status == .invalid)
        #expect(replaySupplied.microseconds == nil)
    }

    @Test
    func frozenTurnPinsGenerationWithoutFeedbackPrewarmOrReceiptMutation() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let revisionBefore = try #require(await fixture.coordinator.frozenRevision())
        let receiptsBefore = try await fixture.store.recentReceipts(limit: 100)
        let prepared = try await fixture.coordinator.prepareFrozenTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Evaluate the frozen identity.",
            personaIDHint: "Agent",
            sessionID: "frozen-session"
        ))
        let selected = try #require(prepared.packet.receipt.selectedAtomIDs.first)
        await prepared.recordExpansion(atomID: selected, receiptID: "must-not-persist")
        await prepared.recordRetry()
        await prepared.recordOutcome(.completed)
        for _ in 0..<10 { await Task.yield() }

        let revisionAfter = try #require(await fixture.coordinator.frozenRevision())
        let receiptsAfter = try await fixture.store.recentReceipts(limit: 100)
        #expect(revisionAfter == revisionBefore)
        #expect(prepared.generation.generation.id == revisionBefore.generationID)
        #expect(prepared.lease.snapshot.generationID == revisionBefore.arenaGenerationID)
        #expect(receiptsAfter == receiptsBefore)
    }

    @Test
    func repeatedSessionTurnsValidatePrewarmUsefulnessWithoutChangingSelection() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Core\nStable identity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()
        let request = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "Continue our identity discussion.",
            personaIDHint: "Agent",
            sessionID: "session-1"
        )

        let first = try await fixture.coordinator.prepareTurn(request)
        let firstSelection = first.packet.receipt.selectedAtomIDs
        for _ in 0..<100 {
            let receipts = try await fixture.store.recentReceipts(limit: 20)
            if receipts.contains(where: {
                $0.kind == .prewarm && $0.summary == "context prewarm planning"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let second = try await fixture.coordinator.prepareTurn(request)
        #expect(second.packet.receipt.selectedAtomIDs == firstSelection)
        var health = await fixture.coordinator.health()
        for _ in 0..<100 {
            if health.prewarmUsefulnessReceipts > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
            health = await fixture.coordinator.health()
        }
        #expect(health.prewarmUsefulnessReceipts == 1)
        var receipts: [ContextStoreReceipt] = []
        for _ in 0..<100 {
            receipts = try await fixture.store.recentReceipts(limit: 50)
            if receipts.contains(where: {
                $0.kind == .prewarm && $0.summary == "context prewarm usefulness"
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let usefulness = try #require(receipts.first {
            $0.kind == .prewarm && $0.summary == "context prewarm usefulness"
        })
        #expect(usefulness.details["authority_granted"] == "false")
    }

    // MARK: - Coverage-ledger fence core.context: wiring the store tests can't see
    //
    // The three tests below share a shape: the UNIT underneath is already well
    // covered (store.prune, the prewarm planner, ContextArena leases), and the
    // thing that has no coverage is whether the coordinator actually CALLS it.
    // Unwire any of them and every existing green check stays green.

    /// 2026-07-21 audit fix, re-armed. `store.prune()` shipped with ZERO
    /// production callers and context.sqlite grew without bound; the fix was to
    /// call it opportunistically after a successful commit. The store-level
    /// prune/vacuum tests (ContextFlowStoreTests) prove prune WORKS — none of
    /// them proves the coordinator invokes it, so deleting the call site
    /// reintroduces the original bug with a fully green suite and no symptom
    /// except a disk number nobody reads.
    ///
    /// Envelope, not exact values: history published before the retention
    /// window must be unreachable after a commit, and the active generation
    /// must still load. Nothing here pins the retention constant itself — that
    /// belongs to the store.
    @Test
    func aSuccessfulReconcileCommitPrunesTheStoreSoHistoryStaysBounded() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Identity\nAgent is one mind.")
        defer { fixture.cleanup() }

        // A history deeper than the default retention window (8), published
        // straight into the store so the coordinator's own commit is the only
        // thing that can bound it.
        for edit in 1...12 {
            _ = try await fixture.store.publish(ContextGenerationDraft(
                reason: "seeded edit \(edit)",
                changedSources: [compiledSource(
                    id: "seed",
                    owner: "seed",
                    locator: "SEED.md",
                    kind: .fact,
                    body: "Seeded body \(edit).",
                    authority: .external,
                    policy: .adaptive
                )],
                createdAt: Date(timeIntervalSince1970: Double(edit))
            ))
        }
        // Precondition: the oldest generation is present BEFORE the commit, so a
        // pass below is about pruning and not about it never having existed.
        #expect(try await fixture.store.loadGeneration(id: 1).generation.id == 1)

        // One successful reconcile+commit. This is the only action under test.
        await fixture.coordinator.start()

        let health = await fixture.coordinator.health()
        let activeID = try #require(health.activeStoreGenerationID)
        #expect(activeID > 12, "the launch reconcile did not commit a new generation")
        // The active generation survives the prune — bounding history must
        // never cost the generation the app is serving.
        #expect(try await fixture.store.loadGeneration(id: activeID).generation.id == activeID)

        do {
            _ = try await fixture.store.loadGeneration(id: 1)
            Issue.record("""
            generation 1 survived a successful commit — pruneStoreIfDue is no longer wired, \
            and context.sqlite grows without bound again
            """)
        } catch let error as ContextFlowStoreError {
            #expect(error == .generationNotFound(1))
        }
    }

    /// The app-facing prewarm overload — the one chat, cognition and the
    /// organism call. It owns token matching and its own fail-closed guard that
    /// returns an EMPTY receipt, and the app throws the receipt away
    /// (`NativeContextFlowRuntime.prewarm` is `async -> Void`). So if the
    /// tokenizer breaks or the guard trips, every prewarm silently plans
    /// nothing and nobody ever sees the `.empty`. The event-shaped overload and
    /// the planner are covered elsewhere; this overload's own logic was not.
    @Test
    func appFacingPrewarmPlansMatchingAtomsAndFailsClosedVisibly() async throws {
        let fixture = try await makeFixture(
            mode: .shadow,
            body: "# Identity\nAgent coordinates the cobalt garden rollout."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        // A term that genuinely appears in the published atom body.
        let planned = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "session-a",
            terms: ["cobalt"]
        )
        #expect(planned.outcome == .planned)
        let plan = try #require(planned.plan, "a matching term planned nothing — the token match is dead")
        #expect(!plan.items.isEmpty)
        #expect(plan.items.allSatisfy { $0.cause.kind == .session && $0.cause.id == "session-a" })
        // Prewarm is advisory only; it must never be able to alter selection or
        // grant authority, whatever it planned.
        #expect(!plan.canAlterSelection)
        #expect(!plan.canGrantAuthority)

        // The fail-closed guard: an empty/whitespace id can never plan.
        let blankID = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "   ",
            terms: ["cobalt"]
        )
        #expect(blankID.outcome == .empty)
        #expect(blankID.plan == nil)

        // A term matching nothing plans nothing — and says so, rather than
        // planning the whole generation.
        let unmatched = await fixture.coordinator.submitPrewarm(
            kind: .session,
            id: "session-b",
            terms: ["zzzznotawordinanyatom"]
        )
        #expect(unmatched.plan?.items.isEmpty ?? true)

        // And every submission that reaches the planner is DURABLE: the receipt
        // lands in the store even though the app-side caller discards the
        // return value (`NativeContextFlowRuntime.prewarm` is `async -> Void`),
        // and a zero-result planning is recorded as such rather than skipped.
        // The write is a detached background task, so poll under a deadline.
        //
        // NOTE, deliberately not asserted: the EARLY guard above (blank id / no
        // active generation) returns its `.empty` receipt before any store
        // write, so that failure mode is durable nowhere. Closing it needs a
        // production change (record a receipt on the guard path), which is out
        // of fence for this wave — it is reported as a needed seam instead of
        // being asserted here, so this test cannot pass by describing a bug.
        var planningReceipts: [ContextStoreReceipt] = []
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            planningReceipts = try await fixture.store.recentReceipts(limit: 50).filter {
                $0.kind == .prewarm && $0.summary == "context prewarm planning"
            }
            if planningReceipts.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            planningReceipts.count >= 2,
            "only \(planningReceipts.count) planning receipts landed — planner outcomes are no longer durable"
        )
        let recordedOutcomes = Set(planningReceipts.compactMap { $0.details["outcome"] })
        #expect(
            recordedOutcomes.contains("planned"),
            "no receipt recorded a planned outcome: \(recordedOutcomes.sorted())"
        )
        #expect(
            recordedOutcomes.contains("empty"),
            "a zero-result planning left no receipt — a prewarm lane that plans nothing is invisible: \(recordedOutcomes.sorted())"
        )
    }

    /// Lease RAII. `ContextPreparedTurn`'s ONLY release is its `deinit`, and
    /// `acquireSnapshot()` hands a raw lease to any caller with no wrapper at
    /// all. A lease that outlives its turn pins its generation in the arena
    /// forever — memory-pressure trims explicitly protect active leases, so
    /// those bytes can never be reclaimed and the only symptom is arena bytes
    /// that never come down. ContextArenaTests proves `release()` works when
    /// CALLED; nothing proved either vended object releases on scope exit.
    @Test
    func vendedLeasesReleaseWhenTheirScopeExitsSoNoGenerationStaysPinned() async throws {
        let fixture = try await makeFixture(mode: .shadow, body: "# Identity\nAgent is one mind.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let baseline = fixture.arena.metrics().activeLeaseCount

        // (a) the wrapped path: prepareTurn -> ContextPreparedTurn.deinit
        func prepareAndDrop() async throws -> Int64 {
            let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "What is the state of things?",
                personaIDHint: "Agent",
                characterBudget: 6_000
            ))
            let generationID = prepared.packet.generationID
            let during = withExtendedLifetime(prepared) { fixture.arena.metrics() }
            #expect(during.activeLeaseCount == baseline + 1)
            #expect(during.pinnedGenerations[generationID] != nil)
            return generationID
        }
        let preparedGeneration = try await prepareAndDrop()
        let afterPreparedTurn = fixture.arena.metrics()
        #expect(
            afterPreparedTurn.activeLeaseCount == baseline,
            "a prepared turn that went out of scope left its lease active — its generation is pinned forever"
        )
        #expect(afterPreparedTurn.pinnedGenerations[preparedGeneration] == nil)

        // (b) the UNWRAPPED path: acquireSnapshot vends a bare lease.
        func acquireAndDrop() async throws -> Int64 {
            let lease = try await fixture.coordinator.acquireSnapshot()
            let generationID = lease.snapshot.generationID
            let during = withExtendedLifetime(lease) { fixture.arena.metrics() }
            #expect(during.activeLeaseCount == baseline + 1)
            return generationID
        }
        let snapshotGeneration = try await acquireAndDrop()
        let afterSnapshot = fixture.arena.metrics()
        #expect(
            afterSnapshot.activeLeaseCount == baseline,
            "acquireSnapshot's raw lease did not release on deinit — a caller that forgets release() pins the arena"
        )
        #expect(afterSnapshot.pinnedGenerations[snapshotGeneration] == nil)
    }

    // REPORTS-ONLY -> executable boundary checks (Wave 1):
    //   core.context / context.coordinator.prepareTurn
    //   core.context / context.coordinator.prewarmPlans.residency
    // These use the real coordinator, SQLite store, arena, and prepared-turn
    // callback rather than source inspection; both the refusing and accepting
    // sides matter because a permissive fallback would look healthy in a trace.
    @Test
    func reportOnlyPrepareTurnRefusesBeforeStartAndWithoutASurfaceKernelThenServesThePublishedGeneration() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Identity\nCobalt garden continuity.")
        defer { fixture.cleanup() }
        let request = ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "report-only-session"
        )

        await #expect(throws: ContextTurnPreparationError.self) {
            _ = try await fixture.coordinator.prepareTurn(request)
        }

        await fixture.coordinator.start()
        let unsupportedSurface = ContextTurnRequest(
            surface: .bridge, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "report-only-session"
        )
        await #expect(throws: ContextTurnPreparationError.self) {
            _ = try await fixture.coordinator.prepareTurn(unsupportedSurface)
        }

        let prepared = try await fixture.coordinator.prepareTurn(request)
        let activeGenerationID = await fixture.coordinator.health().activeStoreGenerationID
        #expect(prepared.packet.generationID == activeGenerationID)
        #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        #expect(prepared.kernel.key.personaID.rawValue == "Agent")
    }

    @Test
    func reportOnlySessionPrewarmIsConsumedOnlyByItsMatchingTurn() async throws {
        let fixture = try await makeFixture(mode: .active, body: "# Identity\nCobalt garden continuity.")
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let planning = await fixture.coordinator.submitPrewarm(
            kind: .session, id: "session-a", terms: ["cobalt"], revision: 7
        )
        #expect(planning.outcome == .planned)
        #expect(!(planning.plan?.items.isEmpty ?? true))
        #expect(await fixture.coordinator.health().trackedPrewarmPlanCount == 1)

        // The same session receives a newer hint before it turns. It replaces
        // its retained plan instead of growing one dictionary entry per hint.
        let replacement = await fixture.coordinator.submitPrewarm(
            kind: .session, id: "session-a", terms: ["cobalt"], revision: 8
        )
        #expect(replacement.outcome == .planned)
        #expect(await fixture.coordinator.health().trackedPrewarmPlanCount == 1)

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "session-b"
        ))
        let unrelatedDeadline = ContinuousClock.now + .seconds(3)
        var unrelatedHealth = await fixture.coordinator.health()
        while unrelatedHealth.trackedPrewarmPlanCount != 2,
              ContinuousClock.now < unrelatedDeadline {
            try await Task.sleep(for: .milliseconds(10))
            unrelatedHealth = await fixture.coordinator.health()
        }
        #expect(
            unrelatedHealth.prewarmUsefulnessReceipts == 0,
            "a session-a warm plan was consumed by unrelated session-b"
        )
        #expect(
            unrelatedHealth.trackedPrewarmPlanCount == 2,
            "the unrelated next-turn plan must coexist with the retained session-a plan"
        )

        _ = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat, origin: .localAuthenticated, userMessage: "cobalt garden",
            personaIDHint: "Agent", sessionID: "session-a"
        ))
        let deadline = ContinuousClock.now + .seconds(3)
        var health = await fixture.coordinator.health()
        while (health.prewarmUsefulnessReceipts == 0 || health.trackedPrewarmPlanCount != 1),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            health = await fixture.coordinator.health()
        }
        #expect(health.prewarmUsefulnessReceipts == 1)
        #expect(
            health.trackedPrewarmPlanCount == 1,
            "matching session-a did not remove its resident plan; only session-b should remain"
        )
    }

    @Test
    func feedbackLearningSurvivesCoordinatorRestartAndKeepsAdvancing() async throws {
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Identity\nCobalt garden continuity."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        let first = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What is the cobalt garden state?",
            personaIDHint: "Agent"
        ))
        let selectedID = try #require(first.packet.receipt.selectedAtomIDs.first)
        #expect((first.need.feedbackUtilityOverrides[selectedID] ?? 0) == 0)
        #expect(await fixture.coordinator.health().feedbackEventCount == 1)

        // A new coordinator models the process restart that previously reset
        // FC7 to an empty in-memory array. It uses the same derived store but
        // rehydrates no user facts or authority from Context.
        let databaseURL = await fixture.store.databaseURL
        await fixture.coordinator.stop()
        let reopenedStore = try ContextSQLiteStore(databaseURL: databaseURL)
        let restarted = ContextFlowCoordinator(
            mode: .active,
            store: reopenedStore,
            arena: try ContextArena(budget: .mib32),
            registry: fixture.registry,
            compiler: ContextMarkdownCompiler(embeddingProvider: CoordinatorEmbeddingProvider()),
            mirrorProvider: CoordinatorMirrorProvider(mirror: fixture.mirror),
            diagnostics: { [log = fixture.diagnostics] message in log.record(message) }
        )
        await restarted.start()
        defer { Task { await restarted.stop() } }

        #expect(await restarted.health().feedbackEventCount == 1)
        let resumed = try await restarted.prepareTurn(ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What is the cobalt garden state?",
            personaIDHint: "Agent"
        ))
        #expect(
            (resumed.need.feedbackUtilityOverrides[selectedID] ?? 0) > 0,
            "a restart erased the prior selection's derived utility"
        )
        #expect(await restarted.health().feedbackEventCount == 2)
    }

    @Test
    func coordinatorFeedbackCapEvictsOldestAndReportsTheNewestRetainedEvent() async throws {
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Identity\nCobalt garden continuity."
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func driveSelection(_ index: Int) async throws {
            let prepared = try await fixture.coordinator.prepareTurn(ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "cobalt garden continuity \(index)",
                personaIDHint: "Agent",
                sessionID: "feedback-cap-\(index)"
            ))
            #expect(!prepared.packet.receipt.selectedAtomIDs.isEmpty)
        }

        try await driveSelection(0)
        let firstHealth = await fixture.coordinator.health()
        let evictedID = try #require(firstHealth.newestFeedbackEventID)

        for index in 1 ... 4_096 {
            try await driveSelection(index)
        }

        let beforeFinal = await fixture.coordinator.health()
        let beforeFinalID = try #require(beforeFinal.newestFeedbackEventID)
        try await driveSelection(4_097)
        let health = await fixture.coordinator.health()
        let newestID = try #require(health.newestFeedbackEventID)
        #expect(health.feedbackEventCount == 4_096)
        #expect(newestID != beforeFinalID)

        let retained = try await fixture.store.recentFeedbackEvents()
        #expect(retained.count == 4_096)
        #expect(retained.contains(where: { $0.id == evictedID }) == false)
        #expect(retained.last?.id == newestID)
    }

    private struct Fixture {
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

    /// NORTHSTAR clause 6. Measured 2026-09-01: `persona.docChars` = 22,278
    /// while `system.stableChars` = 4,601 — in `.active` mode the kernel is
    /// SOUL/VOICE only, so every other required persona document was precovered
    /// by NOTHING and rode the per-turn packet, uncached, on every single turn.
    ///
    /// `stableSegmentCarriesRequiredDocuments` is the caller's promise that its
    /// STABLE segment now carries those bytes verbatim. On that promise the
    /// coordinator precovers EVERY persona-owned source, and the packet stops
    /// mirroring identity into the volatile block. Default `false` reproduces
    /// today's kernel-only precoverage exactly — the assertion pair below is
    /// what proves the flag, and only the flag, moved the document.
    @Test
    func stableSegmentFlagKeepsRequiredPersonaDocumentsOutOfThePacket() async throws {
        let growth = compiledSource(
            id: "growth",
            owner: "nativeagent.persona",
            locator: "persona/Agent/GROWTH.md",
            kind: .identity,
            body: "Approved drift is curated, never inferred; growth is User-gated.",
            authority: .identity,
            policy: .always
        )
        let fixture = try await makeFixture(
            mode: .active,
            body: "# Core\nStable identity.",
            projectedSources: [growth]
        )
        defer { fixture.cleanup() }
        await fixture.coordinator.start()

        func request(stableCarriesDocuments: Bool) -> ContextTurnRequest {
            ContextTurnRequest(
                surface: .chat,
                origin: .localAuthenticated,
                userMessage: "How does approved drift work?",
                personaIDHint: "Agent",
                allowedPrivacy: [.localPrivate],
                stableSegmentCarriesRequiredDocuments: stableCarriesDocuments
            )
        }

        let growthSourceID = growth.descriptor.id

        // Today's behavior, untouched: the kernel carries SOUL only, so GROWTH
        // is not precovered and the packet is its carrier.
        let unflagged = try await fixture.coordinator
            .prepareFrozenTurn(request(stableCarriesDocuments: false))
        #expect(!unflagged.need.precoveredSourceIDs.contains(growthSourceID))
        #expect(unflagged.packet.selectedItems.contains {
            $0.pointer.sourceID == growthSourceID
        })

        // With the promise: precovered, and absent from the packet entirely —
        // not in the selected items, and not smuggled back as a pointer.
        let flagged = try await fixture.coordinator
            .prepareFrozenTurn(request(stableCarriesDocuments: true))
        #expect(flagged.need.precoveredSourceIDs.contains(growthSourceID))
        #expect(!flagged.packet.selectedItems.contains {
            $0.pointer.sourceID == growthSourceID
        })
        #expect(!flagged.packet.expandablePointers.contains {
            $0.sourceID == growthSourceID
        })
    }

    private func makeFixture(
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

    private func compiledSource(
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

    private func storedGeneration(
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
    private func projectionMirror(
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
    private func chatKernel(
        of mirror: RequiredDocumentMirror
    ) throws -> StablePromptKernel {
        try #require(mirror.kernel(for: ContextSurfaceVariant(rawValue: "chat")))
    }

    /// A persona mirror that carries no USER.md document — the shape behind
    /// `.notApplicable(.noUserDocument)`.
    private func projectionMirrorWithoutUserDocument() throws -> RequiredDocumentMirror {
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

    private func expectNoGenerationMinted(
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
