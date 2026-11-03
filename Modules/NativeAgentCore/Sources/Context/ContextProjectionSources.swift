import Foundation
import NativeAgentCore

// Blueprint: | `ContextProjectionSources.swift` | `ContextCompiledProjectionProvider`: incremental rebuildable source projections, generation-bound exclusions and delivery/publication hooks; compiled projections carry unavailable-source reasons and opt-in checked unchanged sources for health recovery |

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

/// Hash changes and retirements from one owner's current source inventory.
public struct ContextCompiledProjectionResult: Sendable, Equatable {
    public let changedSources: [ContextCompiledSource]
    public let removedSourceIDs: Set<ContextSourceID>
    /// Checked reads, including unchanged sources, and failures beside retained inputs.
    public let verifiedSources: [ContextCompiledSource]
    public let sourceFailures: [ContextSourceID: String]
    public init(
        changedSources: [ContextCompiledSource],
        removedSourceIDs: Set<ContextSourceID> = [],
        sourceFailures: [ContextSourceID: String] = [:],
        verifiedSources: [ContextCompiledSource] = []
    ) {
        self.changedSources = changedSources
        self.removedSourceIDs = removedSourceIDs
        self.verifiedSources = verifiedSources.filter { sourceFailures[$0.descriptor.id] == nil }
        self.sourceFailures = sourceFailures
    }

    public init(owner: String, currentSources: [ContextCompiledSource],
                previousSources: [ContextSourceID: ContextCompiledSource],
                sourceFailures: [ContextSourceID: String] = [:],
                verifiedSources: [ContextCompiledSource] = []) {
        self.verifiedSources = verifiedSources.filter { sourceFailures[$0.descriptor.id] == nil }
        self.sourceFailures = sourceFailures
        changedSources = currentSources.filter {
            previousSources[$0.descriptor.id]?.sourceHash != $0.sourceHash
        }
        let currentIDs = Set(currentSources.map(\.descriptor.id))
        removedSourceIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == owner }
            .map(\.descriptor.id)).subtracting(currentIDs).subtracting(sourceFailures.keys)
    }

    public var isEmpty: Bool {
        changedSources.isEmpty && removedSourceIDs.isEmpty && sourceFailures.isEmpty
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
    /// rebuilt. Each provider declares its current contract explicitly.
    var invalidationNamespaces: Set<String> { get }

    /// Exact canonical file whose changes this projection consumes. A staged
    /// candidate under another root is not a mutation of the live source.
    /// Nil explicitly declares a namespace-wide, non-file source.
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

    /// Synchronous acceptance of the published generation after arena publication.
    func didPublish(generation: ContextStoredGeneration)
}

public extension ContextCompiledProjectionProvider {
    var projectionIdentifier: String { String(reflecting: Self.self) }
    var excludedSourceOwners: Set<String> { [] }
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion { ContextTurnExclusion() }
    func didDeliver(_ items: [ContextPacketItem]) async {}

    func didPublish(generation: ContextStoredGeneration) {}

    func isInvalidated(by change: DerivedSourceChange) -> Bool {
        guard change.semantic, invalidationNamespaces.contains(change.namespace) else { return false }
        guard let invalidationSourceURL, let locator = change.canonicalLocator else { return true }
        return invalidationSourceURL.standardizedFileURL
            == URL(fileURLWithPath: locator).standardizedFileURL
    }
}
