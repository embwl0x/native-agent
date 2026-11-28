import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import DeskCore
import CryptoKit
import GRDB
// Blueprint: | `ContextPreparation+SourceReconciliation.swift` | source compilation, checked faults and gated generation publication |

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
        let touchedMemoryIDs: [String: Set<String>]
    }

    private struct ReconciliationCandidate: Sendable {
        let batch: ReconciliationBatch
        let baselineGenerationID: Int64?
        let changedSources: [ContextCompiledSource]
        let removedSourceIDs: Set<ContextSourceID>
        let successfulSources: [ContextSourceID: ContextCompiledSource]
        let compileFailures: [ContextSourceID: String]
        let checkedSourceIDs: [String: Set<ContextSourceID>]
        let projectionReadResults: [String: [ContextSourceID: String]]
    }

    public func sourceDidChange(_ changes: [DerivedSourceChange]) async {
        _ = await reconcileSourceChanges(changes)
    }

    /// Request-scoped completion for callers that fence a foreground choice on publication. Health is not a completion receipt: cancellation keeps health
    /// unchanged, and another request may publish while this one fails.
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
        // An unrelated candidate database must not refresh discovery, acquire a publication request ID, or supersede pending live-owner demand.
        guard !registrationChanges.isEmpty || !invalidatedProjectionIDs.isEmpty else { return true }

        // Projection-owned invalidations do not reread every other compiled source. A Desk edge must not rescan/embed MemoryV2, and a memory write
        // must not replay Desk. Both remain background rebuilds.
        if registrationChanges.isEmpty, !invalidatedProjectionIDs.isEmpty {
            return await reconcile(
                registrations: [],
                reason: "compiled_projection_invalidation",
                compiledProjectionIdentifiers: invalidatedProjectionIDs, changes: semanticChanges
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
            // Discovery already refreshed this request's complete registry. Reusing that snapshot avoids a second persona/catalog read pass while still
            // rebuilding every compiled projection on a full edge.
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
                compiledProjectionIdentifiers: invalidatedProjectionIDs, changes: semanticChanges
            )
        }
        guard isCurrent(lifecycleID) else { return false }
        await refreshWatchedDirectories()
        return completed && !Task.isCancelled
    }

    private func activateStoredGeneration(_ stored: ContextStoredGeneration) {
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
            do {
                let rows = try await registry.registrations(affectedBy: directory)
                guard isCurrent(lifecycleID) else { return }
                affected.append(contentsOf: rows)
            } catch {
                recordReconciliationFailure(error)
                return
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
        compiledProjectionIdentifiers: Set<String>, changes: [DerivedSourceChange] = []
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
        for provider in compiledProjectionProviders where compiledProjectionIdentifiers.contains(provider.projectionIdentifier) {
            let identifier = provider.projectionIdentifier
            let invalidations = changes.filter(provider.isInvalidated)
            if !invalidations.isEmpty, invalidations.allSatisfy({ $0.touchedMemoryIDs != nil }),
               pendingProjectionReconciliationRequestIDs[identifier] == nil || pendingMemoryIDs[identifier] != nil {
                pendingMemoryIDs[identifier, default: []].formUnion(invalidations.flatMap { $0.touchedMemoryIDs ?? [] })
            } else {
                pendingMemoryIDs.removeValue(forKey: identifier)
            }
            pendingProjectionReconciliationRequestIDs[identifier] = requestID
        }
        pendingReconciliationReason = reason
        return await reconcilePending(requestID: requestID)
    }

    private func reconcilePending(requestID: UInt64) async -> Bool {
        // The newest request compiles all accumulated pending demand.
        while compileInProgress, !reconciliationClosed, !Task.isCancelled {
            let done = compileDone
            await done.park()
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
            ),
            touchedMemoryIDs: pendingMemoryIDs
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

    /// `stopWhenSuperseded`: a newer request has taken over this batch's demand and its commit would be refused, so stop between sources.
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
        if let retained = activeStoredGeneration, retained.generation.id == durableGeneration?.id {
            active = retained
        } else {
            if let durableGeneration {
                active = try await store.loadGeneration(id: durableGeneration.id)
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
            } else {
                active = nil
            }
        }
        let previousBySource = active?.compiledSources ?? ContextCompiledSources()
        let authoritativeSources = await registry.authoritativeSourceIDsByOwner()
        try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
        var changedSources: [ContextSourceID: ContextCompiledSource] = [:]
        // Discovery can remove a registration before this loop sees it. Retire only sources whose owner explicitly supplied a complete inventory, including
        // empty inventories after restart.
        var removedSourceIDs = Set<ContextSourceID>()
        for (owner, currentIDs) in authoritativeSources {
            removedSourceIDs.formUnion(previousBySource.ids(owner: owner).filter { !currentIDs.contains($0) })
        }
        var successfulSources: [ContextSourceID: ContextCompiledSource] = [:]

        // Registered persona files feed the required-document mirror, never derived atoms.

        // SQLite may have advanced before a mirror/arena failure retained the live generation. Rebuild projection metadata against that durable baseline before
        // a selective retry can accept it.
        let projectionIdentifiers = active?.generation.id != activeStoredGeneration?.generation.id
            ? Set(compiledProjectionProviders.map(\.projectionIdentifier))
            : batch.compiledProjectionIdentifiers
        var checkedSourceIDs: [String: Set<ContextSourceID>] = [:]
        var projectionReadResults: [String: [ContextSourceID: String]] = [:]
        if !projectionIdentifiers.isEmpty {
            for provider in compiledProjectionProviders where
                projectionIdentifiers.contains(provider.projectionIdentifier) {
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
                let touched = active != nil && active?.generation.id == activeStoredGeneration?.generation.id
                    ? batch.touchedMemoryIDs[provider.projectionIdentifier] : nil
                let result = try await provider.compiledProjection(previousSources: previousBySource, touchedMemoryIDs: touched)
                checkedSourceIDs[provider.projectionIdentifier] = result.checkedSourceIDs
                try checkCandidateAdmission(batch.requestID, enabled: stopWhenSuperseded)
                for source in result.verifiedSources { successfulSources[source.descriptor.id] = source }
                var failures: [ContextSourceID: String] = [:]
                for (id, reason) in result.sourceFailures {
                    let safeReason = String(ContextSecretContentPolicy.redactedFragment(reason).prefix(2_048))
                    failures[id] = safeReason
                    // Failure evidence exists even before the first stored row.
                    compileFailures[id] = safeReason
                }
                projectionReadResults[provider.projectionIdentifier] = failures
                for source in result.changedSources {
                    if changedSources.updateValue(source, forKey: source.descriptor.id) != nil {
                        throw ContextFlowCoordinatorError.duplicateProjectedSource(source.descriptor.id)
                    }
                }
                removedSourceIDs.formUnion(result.removedSourceIDs)
            }
        }

        return ReconciliationCandidate(
            batch: batch,
            baselineGenerationID: active?.generation.id,
            changedSources: Array(changedSources.values),
            removedSourceIDs: removedSourceIDs,
            successfulSources: successfulSources,
            compileFailures: compileFailures,
            checkedSourceIDs: checkedSourceIDs, projectionReadResults: projectionReadResults
        )
    }

    private func commit(_ candidate: ReconciliationCandidate) async -> Bool {
        guard await beginPublication(for: candidate.batch.requestID) else { return false }
        defer { finishPublication() }

        do {
            var candidate = candidate
            // Compilation suspends outside the publication gate. An earlier publisher may have replaced its baseline while this diff waited.
            if try await store.activeGeneration()?.id != candidate.baselineGenerationID {
                var compileFailures: [ContextSourceID: String] = [:]
                candidate = try await makeCandidate(for: candidate.batch, compileFailures: &compileFailures)
            }
            var admittedReadFailures = sourceReadFailures
            for (id, failures) in candidate.projectionReadResults {
                var remaining = admittedReadFailures[.projection(id)] ?? [:]
                if let checked = candidate.checkedSourceIDs[id] {
                    for source in checked { remaining.removeValue(forKey: source) }
                    remaining.merge(failures) { _, new in new }
                } else {
                    remaining = failures
                }
                admittedReadFailures[.projection(id)] = remaining.isEmpty ? nil : remaining
            }
            let degradedSourceIDs = try await store.degradedSourceIDs()
            let sameDegradedCount = degradedSourceIDs.count == activeStoredGeneration?.degradedCount
            for (sourceID, error) in candidate.compileFailures.sorted(by: { $0.key < $1.key }) {
                try await markSourceDegraded(sourceID, error: error)
            }
            var changedBySource = Dictionary(candidate.changedSources.map {
                ($0.descriptor.id, $0)
            }, uniquingKeysWith: { first, _ in first })
            let recoveredSourceIDs = degradedSourceIDs
                .intersection(candidate.successfulSources.keys)
                .subtracting(candidate.compileFailures.keys)
            for sourceID in recoveredSourceIDs {
                if let source = candidate.successfulSources[sourceID] {
                    changedBySource[sourceID] = source
                }
            }

            let sourcesChanged = !changedBySource.isEmpty || !candidate.removedSourceIDs.isEmpty || candidate.baselineGenerationID == nil
            let checkedTopology = ["nativeagent.memory-v2", "nativeagent.knowledge-graph", "nativeagent.studio"].contains {
                candidate.projectionReadResults[$0] != nil
            }
            var checkedGraph: Result<ContextAssociationGraph, any Error>?
            if checkedTopology, !sourcesChanged, let retained = activeStoredGeneration, retained.generation.id == candidate.baselineGenerationID {
                checkedGraph = try await readAssociationGraph(in: retained)
            }
            let topologyChanged = checkedGraph != nil && (try? checkedGraph?.get().edges) != (try? associationGraph?.get().edges)
            var publication: ContextGenerationRecord?
            if sourcesChanged || topologyChanged {
                publication = try await store.publish(ContextGenerationDraft(
                    reason: candidate.batch.reason,
                    changedSources: changedBySource.values.sorted {
                        $0.descriptor.id < $1.descriptor.id
                    },
                    removedSourceIDs: candidate.removedSourceIDs
                ), associationTopologyChanged: topologyChanged)
            }

            let stored: ContextStoredGeneration
            var patch: GenerationPatch?
            let durable = try await store.activeGeneration()
            if var retained = activeStoredGeneration, sameDegradedCount,
               let durable, let publication, publication.id == durable.id,
               publication.parentID == retained.generation.id {
                let replaced = candidate.removedSourceIDs.union(changedBySource.keys)
                let rows = try await store.publishedRows(generation: durable.id, sourceIDs: Array(changedBySource.keys))
                let removed = retained.apply(durable, sources: rows.sources, atoms: rows.atoms, replaced: replaced)
                patch = GenerationPatch(replaced: replaced, removed: removed, changed: rows.atoms)
                stored = retained
            } else if let retained = activeStoredGeneration, sameDegradedCount, durable?.id == retained.generation.id {
                patch = GenerationPatch(replaced: [], removed: [], changed: [])
                stored = retained
            } else {
                guard let loaded = try await store.loadActiveGeneration() else {
                    throw ContextFlowCoordinatorError.activeGenerationUnavailable
                }
                stored = loaded
            }
            try await activate(stored, requestID: candidate.batch.requestID, readFailures: admittedReadFailures, patch: patch,
                               refreshGraph: checkedTopology, checkedGraph: checkedGraph)
            lastReconciledAt = Date()
            acknowledge(candidate.batch)
            await pruneStoreIfDue()
            return !Task.isCancelled
        } catch is CancellationError {
            // A cancelled caller must not mint an orange health incident or a persistent degradation. Pending demand remains retryable.
            return false
        } catch {
            recordReconciliationFailure(error)
            return false
        }
    }

    struct GenerationPatch {
        let replaced: Set<ContextSourceID>
        let removed: Set<ContextAtomID>
        let changed: [ContextStoredAtom]
    }

    private func readAssociationGraph(in generation: ContextStoredGeneration) async throws -> Result<ContextAssociationGraph, any Error>? {
        guard let provider = compiledProjectionProviders.compactMap({ $0 as? any ContextAssociationProjecting }).first else { return nil }
        do { return .success(try await provider.associationGraph(in: generation)) }
        catch is CancellationError { throw CancellationError() }
        catch { return .failure(error) }
    }

    /// Make `stored` the generation turns read: its mirrors, arena snapshot and projection identities publish together or not at all.
    func activate(_ stored: ContextStoredGeneration, requestID: UInt64,
                  readFailures: [SourceReadOwner: [ContextSourceID: String]]? = nil, patch: GenerationPatch? = nil,
                  refreshGraph: Bool = true, checkedGraph: Result<ContextAssociationGraph, any Error>? = nil) async throws {
        var graph = checkedGraph ?? associationGraph
        if checkedGraph == nil, graph == nil || refreshGraph || patch == nil { graph = try await readAssociationGraph(in: stored) }
        let mirrors = try await mirrorProvider.requiredDocumentMirrors()
        guard !reconciliationClosed, requestID == nextReconciliationRequestID, !Task.isCancelled else { throw CancellationError() }
        let currentSnapshot = arena.currentSnapshot()
        let snapshot: ContextGenerationSnapshot
        if let currentSnapshot,
           currentSnapshot.generationID == stored.generation.id,
           currentSnapshot.sourceFingerprint == stored.generation.sourceFingerprint,
           currentSnapshot.requiredDocumentMirrors == mirrors.sorted(by: { $0.personaID < $1.personaID }),
           currentSnapshot.selectionIndex.count == stored.generation.atomCount {
            snapshot = currentSnapshot
        } else if let currentSnapshot, let patch,
                  currentSnapshot.generationID == stored.generation.parentID || currentSnapshot.generationID == stored.generation.id {
            snapshot = try currentSnapshot.patching(generation: stored.generation, mirrors: mirrors,
                removedAtomIDs: patch.removed, changedAtoms: patch.changed)
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
            let previous = activeStoredGeneration
            associationGraph = graph
            activateStoredGeneration(stored)
            if let readFailures { sourceReadFailures = readFailures }
            for provider in compiledProjectionProviders {
                provider.didPublish(generation: stored, replacedSourceIDs: patch?.replaced, previous: previous)
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
            do { try await markSourceDegraded(sourceID, error: compileError) }
            catch { recordReconciliationFailure(error); return }
        }
        recordReconciliationFailure(error)
    }

    private func markSourceDegraded(_ sourceID: ContextSourceID, error: String) async throws {
        try await store.markSourceDegraded(sourceID, error: error)
        arena.healthEvents.signal()
        invalidateGenerationDerivedCache()
        activeStoredGeneration?.markDegraded(sourceID, error: error)
    }

    private func acknowledge(_ batch: ReconciliationBatch) {
        pendingRegistrations = pendingRegistrations.filter { $0.value.requestID > batch.requestID }
        pendingProjectionReconciliationRequestIDs = pendingProjectionReconciliationRequestIDs.filter { $0.value > batch.requestID }
        pendingMemoryIDs = pendingMemoryIDs.filter { pendingProjectionReconciliationRequestIDs[$0.key] != nil }
    }

    private func recordReconciliationFailure(_ error: any Error) {
        lastError = String(describing: error)
        // Failed discovery/health demand supersedes any older publisher too. Reuse the admission owner's existing request identity; no second clock.
        nextReconciliationRequestID &+= 1
        // Leave failed demand pending. A later external reconciliation will coalesce and retry it without scheduling an immediate retry loop.
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
            recordReconciliationFailure(error)
            return false
        }
    }

    private static func makeArenaSnapshot(
        stored: ContextStoredGeneration,
        mirrors: [RequiredDocumentMirror]
    ) throws -> ContextGenerationSnapshot {
        var selectionIndex: [ContextAtomID: ContextSelectionIndexEntry] = [:]
        for atom in stored.atoms {
            selectionIndex[atom.draft.id] = ContextSelectionIndexEntry(atom: atom.draft)
        }
        return try ContextGenerationSnapshot(
            generationID: stored.generation.id,
            sourceFingerprint: stored.generation.sourceFingerprint,
            requiredDocumentMirrors: mirrors,
            selectionIndex: selectionIndex,
            vectorAtoms: stored.atoms
        )
    }

    private static func unique(_ registrations: [ContextSourceRegistration]) -> [ContextSourceRegistration] {
        var seen = Set<ContextSourceID>()
        return registrations
            .sorted { $0.descriptor.id < $1.descriptor.id }
            .filter { seen.insert($0.descriptor.id).inserted }
    }
}
