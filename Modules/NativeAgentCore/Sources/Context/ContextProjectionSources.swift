import Foundation
import NativeAgentCore

/// Incremental output from a rebuildable non-file Context source projection.
/// Providers compare their current source of truth with `previousSources` and
/// return only changed sources plus sources that must leave the next generation.
/// The chosen atoms a provider drops, and the degraded-source receipts for
/// what it could not verify (dropped too).
public struct ContextTurnExclusion: Sendable {
    public var atomIDs: Set<ContextAtomID>
    public var unverified: [ContextDegradedSourceNotice]

    public init(atomIDs: Set<ContextAtomID> = [], unverified: [ContextDegradedSourceNotice] = []) {
        self.atomIDs = atomIDs
        self.unverified = unverified
    }
}

public struct ContextCompiledProjectionResult: Sendable, Equatable {
    public let changedSources: [ContextCompiledSource]
    public let removedSourceIDs: Set<ContextSourceID>
    /// Derived record identities, accepted only with this projection's generation.
    public let atomRecordIDs: [ContextAtomID: String]

    public init(
        changedSources: [ContextCompiledSource],
        removedSourceIDs: Set<ContextSourceID> = [],
        atomRecordIDs: [ContextAtomID: String] = [:]
    ) {
        self.changedSources = changedSources
        self.removedSourceIDs = removedSourceIDs
        self.atomRecordIDs = atomRecordIDs
    }

    public var isEmpty: Bool {
        changedSources.isEmpty && removedSourceIDs.isEmpty
    }
}

/// A rebuildable projection whose output is already compiled for ContextStore.
/// The provider owns source discovery and validation but does not publish or
/// mutate either its source of truth or the Context generation store.
public protocol ContextCompiledProjectionProvider: Sendable {
    /// Stable process-local identity used to coalesce and selectively rebuild
    /// this projection. It names derived work only; canonical authority remains
    /// with the provider's source stores.
    var projectionIdentifier: String { get }

    /// Canonical invalidation namespaces that require this projection to be
    /// rebuilt. Empty keeps legacy/test providers launch-only.
    var invalidationNamespaces: Set<String> { get }

    /// Exact canonical file whose changes this projection consumes. A staged
    /// candidate under another root is not a mutation of the live source.
    /// Nil preserves namespace-only consumers and unlocated legacy events.
    var invalidationSourceURL: URL? { get }

    /// Point-of-use policy exclusions, including sources in retained generations.
    var excludedSourceOwners: Set<String> { get }

    /// Checked when the turn's atoms are chosen, and again at expansion: the
    /// provider drops any chosen atom its owner no longer stands behind
    /// (aged out, retired, changed, or not disclosed on this surface), naming
    /// what it could not verify. Rebuilds only refresh what is published.
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion
    func didDeliver(_ items: [ContextPacketItem]) async

    func isInvalidated(by change: DerivedSourceChange) -> Bool

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult

    /// Synchronous acceptance after arena publication. Nil carries unchanged
    /// projection state forward; pinned generations must retain their identities.
    func didPublish(
        _ result: ContextCompiledProjectionResult?,
        generation: ContextStoredGeneration,
        retaining generationIDs: Set<Int64>
    )
}

public extension ContextCompiledProjectionProvider {
    var projectionIdentifier: String { String(reflecting: Self.self) }
    var invalidationNamespaces: Set<String> { [] }
    var invalidationSourceURL: URL? { nil }
    var excludedSourceOwners: Set<String> { [] }
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion { ContextTurnExclusion() }
    func didDeliver(_ items: [ContextPacketItem]) async {}

    func didPublish(
        _ result: ContextCompiledProjectionResult?,
        generation: ContextStoredGeneration,
        retaining generationIDs: Set<Int64>
    ) {}

    func isInvalidated(by change: DerivedSourceChange) -> Bool {
        guard change.semantic, invalidationNamespaces.contains(change.namespace) else { return false }
        guard let invalidationSourceURL, let locator = change.canonicalLocator else { return true }
        return invalidationSourceURL.standardizedFileURL
            == URL(fileURLWithPath: locator).standardizedFileURL
    }
}
