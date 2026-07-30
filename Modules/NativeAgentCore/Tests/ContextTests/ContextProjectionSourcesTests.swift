import Context
import Foundation
import Testing

private struct ProjectionProviderFixture: ContextCompiledProjectionProvider {
    let result: ContextCompiledProjectionResult

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        result
    }
}

@Suite("Context compiled projection sources")
struct ContextProjectionSourcesTests {
    @Test("result preserves changed sources and removals in a generation draft")
    func generationDraft() async throws {
        let sourceID = ContextStableID.source(owner: "test", locator: "record")
        let source = ContextCompiledSource(
            descriptor: ContextSourceDescriptor(
                id: sourceID,
                owner: "test",
                kind: .memory,
                canonicalLocator: "record",
                authority: .inferred,
                privacy: .localPrivate,
                permittedSurfaces: [.chat],
                injectionPolicy: .adaptive
            ),
            sourceHash: "hash",
            atoms: []
        )
        let removedID = ContextStableID.source(owner: "test", locator: "removed")
        let result = ContextCompiledProjectionResult(
            changedSources: [source],
            removedSourceIDs: [removedID]
        )
        let provider: any ContextCompiledProjectionProviding = ProjectionProviderFixture(
            result: result
        )

        let projected = try await provider.compiledProjection(previousSources: [:])
        let createdAt = Date(timeIntervalSince1970: 123)
        let draft = projected.generationDraft(reason: "memory rebuild", createdAt: createdAt)

        #expect(!projected.isEmpty)
        #expect(draft.reason == "memory rebuild")
        #expect(draft.changedSources == [source])
        #expect(draft.removedSourceIDs == [removedID])
        #expect(draft.createdAt == createdAt)
    }

    @Test("empty result is explicitly detectable")
    func emptyResult() {
        let result = ContextCompiledProjectionResult(changedSources: [])
        #expect(result.isEmpty)
    }
}
