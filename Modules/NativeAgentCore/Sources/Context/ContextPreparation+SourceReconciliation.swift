import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import TrustCenter
import CryptoKit
import GRDB
import PersonaEngine
// Blueprint: | `ContextPreparation+SourceReconciliation.swift` | Source compilation and immutable generation publication through the actor's single admission gate; durable baselines, degradation, arena rehydration and bounded store maintenance |

extension ContextPreparation {
    struct PendingRegistration: Sendable {
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

    func reconcile(dirtyDirectories: Set<URL>) async {
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
    func reconcileAll(reason: String) async -> Bool {
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
        // The newest request compiles all accumulated pending demand.
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
                // Embedding-epoch changes require publication even when source bytes match.
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
                compileFailures[sourceID] = String(ContextSecretContentPolicy.redactedFragment(
                    String(describing: error)).prefix(2_048))
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
            compileFailures: compileFailures
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
            try await activate(stored)
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
    func activate(_ stored: ContextStoredGeneration) async throws {
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
            for provider in compiledProjectionProviders {
                provider.didPublish(generation: stored)
            }
        case .retainedLastGood(let failure, _):
            throw ContextFlowCoordinatorError.arenaPublicationFailed(String(describing: failure))
        }
    }

    /// Prune after successful commits; failures stay in health until the next due retry.
    private func pruneStoreIfDue(now: Date = Date()) async {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < pruneInterval { return }
        do {
            let result = try await store.prune()
            lastPruneAt = now
            // Vacuum only after rows are deleted; maintenance never blocks a commit.
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

    private func acknowledge(_ batch: ReconciliationBatch) {
        pendingRegistrations = pendingRegistrations.filter { $0.value.requestID > batch.requestID }
        pendingProjectionReconciliationRequestIDs = pendingProjectionReconciliationRequestIDs.filter { $0.value > batch.requestID }
    }

    private func recordReconciliationFailure(_ error: any Error) {
        lastError = String(describing: error)
        // Leave failed demand pending. A later external reconciliation will
        // coalesce and retry it without scheduling an immediate retry loop.
    }

    func refreshWatchedDirectories() async {
        let lifecycleID = self.lifecycleID
        guard mode != .off, isCurrent(lifecycleID) else { return }
        let directories = await registry.watchedDirectories()
        guard isCurrent(lifecycleID) else { return }
        await monitor?.setDirectories(directories)
    }

    /// Discovery failure retains the active generation and cannot acknowledge a picker change.
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
            let vectorBytes = (atom.embedding?.values.count ?? 0)
                .multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
            guard !vectorBytes.overflow else { throw ContextArenaEntryError.logicalByteOverflow }
            // Preserve admission accounting without retaining a second atom payload.
            let logicalBytes = try ContextLogicalByteAccounting.checkedSum([
                96, atom.kind.rawValue.utf8.count, atom.id.rawValue.utf8.count,
                atom.sourceHash.utf8.count, atom.body.utf8.count,
                atom.deterministicSummary?.utf8.count ?? 0,
                try encoder.encode(atom).count, vectorBytes.partialValue,
            ], overflowError: ContextArenaEntryError.logicalByteOverflow)
            let entry = try ContextArenaEntry(
                key: ContextArenaEntryKey(
                    namespace: atom.kind.rawValue,
                    id: atom.id.rawValue,
                    sourceFingerprint: atom.sourceHash,
                    generationID: stored.generation.id
                ),
                tier: tier,
                logicalByteCount: logicalBytes,
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
