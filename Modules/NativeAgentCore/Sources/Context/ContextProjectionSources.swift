import Foundation

/// Incremental output from a rebuildable non-file Context source projection.
/// Providers compare their current source of truth with `previousSources` and
/// return only changed sources plus sources that must leave the next generation.
public struct ContextCompiledProjectionResult: Sendable, Equatable {
    public let changedSources: [ContextCompiledSource]
    public let removedSourceIDs: Set<ContextSourceID>

    public init(
        changedSources: [ContextCompiledSource],
        removedSourceIDs: Set<ContextSourceID> = []
    ) {
        self.changedSources = changedSources
        self.removedSourceIDs = removedSourceIDs
    }

    public var isEmpty: Bool {
        changedSources.isEmpty && removedSourceIDs.isEmpty
    }

    public func generationDraft(
        reason: String,
        createdAt: Date = Date()
    ) -> ContextGenerationDraft {
        ContextGenerationDraft(
            reason: reason,
            changedSources: changedSources,
            removedSourceIDs: removedSourceIDs,
            createdAt: createdAt
        )
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

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult
}

public extension ContextCompiledProjectionProvider {
    var projectionIdentifier: String { String(reflecting: Self.self) }
    var invalidationNamespaces: Set<String> { [] }
}

public typealias ContextCompiledProjectionProviding = ContextCompiledProjectionProvider
