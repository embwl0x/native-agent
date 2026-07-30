import Foundation
import Testing
@testable import PersonaEngine

private func makeContextSnapshotFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaContextSourceSnapshotTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeContextSnapshotFixture(_ content: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(content.utf8).write(to: url)
}

private func writeContextSnapshotCanonicalDocs(
    to root: URL,
    includeMemory: Bool
) throws {
    let docs = [
        ("SOUL", "canonical soul\n"),
        ("VOICE", "canonical voice\n"),
        ("USER", "canonical user\n"),
        ("GROWTH", "canonical growth\n"),
        ("AGENTS", "canonical agents\n"),
    ]
    for (id, content) in docs {
        try writeContextSnapshotFixture(content, to: root.appendingPathComponent("\(id).md"))
    }
    if includeMemory {
        try writeContextSnapshotFixture(
            "canonical memory\n",
            to: root.appendingPathComponent("MEMORY.md")
        )
    }
}

private func makeContextSnapshotCompiler(root: URL) -> PersonaCompiler {
    let dataRoot = root.deletingLastPathComponent()
        .appendingPathComponent("PersonaContextSourceSnapshotData-\(UUID().uuidString)")
    return PersonaCompiler(
        engine: SwiftNativePersonaEngine(root: root, dataRoot: dataRoot)
    )
}

private func prompt(from documents: [PersonaContextDocumentSource], surface: String) -> String {
    documents.map { document in
        if document.surfaceOverride {
            return "Surface guidance for \(surface):\n\(document.content)"
        }
        return "# \(document.id)\n\(document.content)"
    }.joined(separator: "\n\n")
}

@Test
func contextSourceSnapshot_preserves_canonical_order_and_compile_parity() async throws {
    let root = try makeContextSnapshotFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeContextSnapshotCanonicalDocs(to: root, includeMemory: true)

    let compiler = makeContextSnapshotCompiler(root: root)
    let compiled = try await compiler.compile(surface: "chat")
    let snapshot = try await compiler.contextSourceSnapshot(surface: "chat")

    #expect(snapshot.personaRoot == root)
    #expect(snapshot.activePersonaDirectory == nil)
    #expect(snapshot.packet == compiled)
    #expect(snapshot.documents.map(\.id) == [
        "SOUL", "VOICE", "USER", "GROWTH", "MEMORY", "AGENTS",
    ])
    #expect(snapshot.documents.map(\.canonicalOrder) == [0, 1, 2, 3, 4, 5])
    #expect(snapshot.documents.map(\.content) == snapshot.documents.map { compiled.activeDocs[$0.id]! })
    #expect(snapshot.documents.map(\.fileURL) == snapshot.documents.map {
        root.appendingPathComponent("\($0.id).md")
    })
    #expect(snapshot.documents.filter(\.optional).map(\.id) == ["MEMORY"])
    #expect(snapshot.documents.allSatisfy { !$0.surfaceOverride })
    #expect(prompt(from: snapshot.documents, surface: "chat") == compiled.compiledSystemPrompt)
}

@Test
func contextSourceSnapshot_omits_missing_optional_memory_without_reordering_agents() async throws {
    let root = try makeContextSnapshotFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeContextSnapshotCanonicalDocs(to: root, includeMemory: false)

    let snapshot = try await makeContextSnapshotCompiler(root: root)
        .contextSourceSnapshot(surface: "chat")

    #expect(snapshot.documents.map(\.id) == ["SOUL", "VOICE", "USER", "GROWTH", "AGENTS"])
    #expect(snapshot.documents.map(\.canonicalOrder) == [0, 1, 2, 3, 5])
    #expect(!snapshot.documents.contains { $0.id == "MEMORY" })
    #expect(snapshot.documents.last?.id == "AGENTS")
}

@Test
func contextSourceSnapshot_tracks_active_and_per_turn_persona_overrides() async throws {
    let root = try makeContextSnapshotFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeContextSnapshotCanonicalDocs(to: root, includeMemory: true)

    let active = root.appendingPathComponent("ActivePersona", isDirectory: true)
    let perTurn = root.appendingPathComponent("PerTurnPersona", isDirectory: true)
    try writeContextSnapshotFixture("active soul\n", to: active.appendingPathComponent("SOUL.md"))
    try writeContextSnapshotFixture("per-turn voice\n", to: perTurn.appendingPathComponent("VOICE.md"))
    try writeContextSnapshotFixture(
        #"{"persona":"ActivePersona"}"#,
        to: root.appendingPathComponent("active.json")
    )

    let compiler = makeContextSnapshotCompiler(root: root)
    let activeSnapshot = try await compiler.contextSourceSnapshot(surface: "chat")
    let overrideSnapshot = try await compiler.contextSourceSnapshot(
        surface: "chat",
        personaOverride: "PerTurnPersona"
    )

    #expect(activeSnapshot.packet.personaId == "ActivePersona")
    #expect(activeSnapshot.activePersonaDirectory == active)
    #expect(activeSnapshot.documents.first { $0.id == "SOUL" }?.content == "active soul\n")
    #expect(activeSnapshot.documents.first { $0.id == "SOUL" }?.fileURL == active.appendingPathComponent("SOUL.md"))
    #expect(activeSnapshot.documents.first { $0.id == "VOICE" }?.fileURL == root.appendingPathComponent("VOICE.md"))

    #expect(overrideSnapshot.packet.personaId == "PerTurnPersona")
    #expect(overrideSnapshot.activePersonaDirectory == perTurn)
    #expect(overrideSnapshot.documents.first { $0.id == "VOICE" }?.content == "per-turn voice\n")
    #expect(overrideSnapshot.documents.first { $0.id == "VOICE" }?.fileURL == perTurn.appendingPathComponent("VOICE.md"))
    #expect(overrideSnapshot.documents.first { $0.id == "SOUL" }?.fileURL == root.appendingPathComponent("SOUL.md"))
    #expect(activeSnapshot.watchedDirectories.contains(active))
    #expect(overrideSnapshot.watchedDirectories.contains(perTurn))
}

@Test
func contextSourceSnapshot_includes_surface_override_after_agents_with_compile_parity() async throws {
    let root = try makeContextSnapshotFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeContextSnapshotCanonicalDocs(to: root, includeMemory: true)
    let surfaceURL = root
        .appendingPathComponent("surfaces", isDirectory: true)
        .appendingPathComponent("dream.md")
    try writeContextSnapshotFixture("dream guidance\n", to: surfaceURL)

    let compiler = makeContextSnapshotCompiler(root: root)
    let compiled = try await compiler.compile(surface: "dream")
    let snapshot = try await compiler.contextSourceSnapshot(surface: "dream")
    let surfaceDocument = try #require(snapshot.documents.last)

    #expect(snapshot.packet == compiled)
    #expect(surfaceDocument.id == "surface:dream")
    #expect(surfaceDocument.fileURL == surfaceURL)
    #expect(surfaceDocument.content == compiled.activeDocs["surface:dream"])
    #expect(surfaceDocument.canonicalOrder == 6)
    #expect(surfaceDocument.optional)
    #expect(surfaceDocument.surfaceOverride)
    #expect(snapshot.documents.dropLast().last?.id == "AGENTS")
    #expect(prompt(from: snapshot.documents, surface: "dream") == compiled.compiledSystemPrompt)
}
