import Foundation
import NativeAgentCore

// Blueprint: | `ContextProjectionSources.swift` | `ContextCompiledProjectionProvider`: derived sources, exclusions and checked publication |

/// Drop unverifiable atoms with degraded-source receipts.
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

/// Providers discover and validate derived inputs without mutating canonical sources or publishing Context generations.
public protocol ContextCompiledProjectionProvider: Sendable {
    /// Process-local identity coalesces derived work only; canonical authority stays with source stores.
    var projectionIdentifier: String { get }

    /// Each provider explicitly declares which canonical invalidations require rebuilding.
    var invalidationNamespaces: Set<String> { get }

    /// Exact canonical file whose changes this projection consumes. A staged candidate under another root is not a mutation of the live source. Nil explicitly
    /// declares a namespace-wide, non-file source.
    var invalidationSourceURL: URL? { get }

    /// Point-of-use policy exclusions, including sources in retained generations.
    var excludedSourceOwners: Set<String> { get }

    /// Check chosen atoms at selection and expansion against their canonical owner; name unverifiable content rather than trusting a retained generation.
    func verify(_ chosen: [ContextStoredAtom], in generation: ContextStoredGeneration,
                surface: ContextSurface) async -> ContextTurnExclusion
    func didDeliver(_ items: [ContextPacketItem]) async

    func isInvalidated(by change: DerivedSourceChange) -> Bool

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult

    /// Accept the generation synchronously only after arena publication.
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
