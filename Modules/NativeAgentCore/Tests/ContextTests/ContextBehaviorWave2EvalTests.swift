import Foundation
import Testing
@testable import Context

@Suite("Context behavior wave 2")
struct ContextBehaviorWave2EvalTests {
    @Test("Directory delete, rename, and revoke events require a monitor rearm")
    func destructiveDirectoryEventsRequireRearm() {
        let directory = URL(fileURLWithPath: "/tmp/context-wave2")
        for flag in [
            DispatchSource.FileSystemEvent.delete.rawValue,
            DispatchSource.FileSystemEvent.rename.rawValue,
            DispatchSource.FileSystemEvent.revoke.rawValue,
        ] {
            #expect(ContextDirectoryEvent(directory: directory, rawFlags: flag).requiresRearm)
        }
        #expect(!ContextDirectoryEvent(
            directory: directory,
            rawFlags: DispatchSource.FileSystemEvent.write.rawValue
        ).requiresRearm)
    }

    @Test("Prune removes source tombstones only after their retained versions are gone")
    func pruneReclaimsFullyUnreferencedRemovedSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-wave2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContextSQLiteStore(dataRoot: root)
        let source = source(body: "old")
        _ = try await store.publish(ContextGenerationDraft(
            reason: "add", changedSources: [source], createdAt: Date(timeIntervalSince1970: 1)
        ))
        _ = try await store.publish(ContextGenerationDraft(
            reason: "remove", changedSources: [], removedSourceIDs: [source.descriptor.id],
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        #expect(try await store.healthSnapshot().removedSources == 1)

        _ = try await store.prune(retainingLatest: 1)
        #expect(try await store.healthSnapshot().removedSources == 0)
    }

    private func source(body: String) -> ContextCompiledSource {
        let sourceID = ContextStableID.source(owner: "wave2", locator: "fixture")
        let hash = ContextStableID.digest(parts: [body])
        let descriptor = ContextSourceDescriptor(
            id: sourceID, owner: "wave2", kind: .persona, canonicalLocator: "fixture",
            authority: .identity, privacy: .localPrivate, permittedSurfaces: [.chat], injectionPolicy: .always
        )
        let atom = ContextAtomDraft(
            id: ContextStableID.atom(sourceID: sourceID, kind: .identity, headingPath: ["fixture"], blockAnchor: "0"),
            sourceID: sourceID, kind: .identity, headingPath: ["fixture"],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count), sourceHash: hash,
            body: body, deterministicSummary: body, authority: .identity, confidence: 1,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 1)), privacy: .localPrivate,
            permittedSurfaces: [.chat], injectionPolicy: .always, contentRole: .identity,
            entities: [], triggers: [], embedding: ContextEmbedding(modelFingerprint: "wave2", values: [1])
        )
        return ContextCompiledSource(descriptor: descriptor, sourceHash: hash, atoms: [atom])
    }
}
