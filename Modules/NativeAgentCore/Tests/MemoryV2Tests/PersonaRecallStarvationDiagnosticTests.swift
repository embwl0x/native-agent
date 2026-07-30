import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// Vocabulary-mismatch alarm for the recall half of the persona split
// (2026-07-24). MemoryV2's `persona` argument is an exact-equality filter over
// RECORD persona ids — agent names, the only vocabulary in the live store
// ("Agent", "NativeAgent"). Callers upstream hold persona SLOT ids ("canonical"
// or a custom persona subdirectory name), a different vocabulary entirely.
//
// PRODUCT POLICY (User approved, same day): a slot id is PRESENTATION-ONLY, so
// memoryRecallPersonaFilter now resolves EVERY slot — resident and custom — to
// nil. On the healthy path this alarm therefore cannot fire, and the "stays
// quiet" tests below are the ones that pin the shipped behavior.
//
// The alarm is kept because the mismatch class is real and only moved: it now
// catches any FUTURE caller that reaches MemoryV2 with an id from the wrong
// vocabulary (a new lane that skips memoryRecallPersonaFilter, or a slot id
// smuggled in through a tool argument). A lane that can never match a row must
// never fail in silence again.

private final class DiagnosticLog: @unchecked Sendable {
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

    var starvation: [String] {
        all.filter { $0.contains("persona recall starvation") }
    }
}

private func makeMemory() -> (SwiftNativeMemoryV2, InMemoryMemoryStorage, MockEmbeddingProvider) {
    let embedder = MockEmbeddingProvider(dimensions: 384)
    let storage = InMemoryMemoryStorage()
    return (SwiftNativeMemoryV2(embedder: embedder, storage: storage), storage, embedder)
}

/// Seed a record under a LIVE record-persona vocabulary value (an agent name).
private func seedAgentNameScopedRecord(
    _ storage: InMemoryMemoryStorage,
    _ embedder: MockEmbeddingProvider,
    text: String,
    personaId: String,
    id: String? = nil,
    extras: JSONValue? = nil
) async throws {
    let vector = try await embedder.embed([text])[0]
    _ = try await storage.insert(
        record: MemoryRecord(
            id: id ?? "seeded-\(personaId.lowercased())",
            text: text,
            personaId: personaId,
            lifecycle: MemoryLifecycle.confirmed,
            createdAt: "2026-07-14T00:00:00Z",
            updatedAt: "2026-07-14T00:00:00Z",
            status: "active",
            extras: extras
        ),
        embedding: vector
    )
}

/// Not the shipped chat path any more (memoryRecallPersonaFilter sends a slot
/// id in as nil). This is the guard for a caller that BYPASSES that mapping and
/// hands MemoryV2 an id from the slot vocabulary: it still recalls nothing, and
/// it still has to say so.
@Test("a wrong-vocabulary persona id recalls nothing from an agent-name store — loudly")
func personaSlotIdRecallStarvationIsLogged() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent"
    )

    // "Agent" is a persona SLOT id — the shape ChatOrchestration hands down for
    // any custom persona. No record persona id can ever equal it.
    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "CustomPersona",
        surface: "chat"
    ))

    #expect(result.total == 0)
    #expect(log.starvation.count == 1)
    let line = try #require(log.starvation.first)
    #expect(line.contains("ERROR"))
    #expect(line.contains("\"CustomPersona\""))
    #expect(line.contains("chat"))
}

@Test("the resident's unfiltered recall lane never trips the alarm")
func unfilteredRecallStaysQuiet() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent"
    )

    // persona: nil is exactly what memoryRecallPersonaFilter yields for the
    // resident slot — the healthy path.
    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: nil,
        surface: "chat"
    ))

    #expect(result.total == 1)
    #expect(log.starvation.isEmpty)
}

@Test("a matching persona filter that finds hits stays quiet")
func matchingPersonaFilterStaysQuiet() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent"
    )

    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "ResidentAgent",
        surface: "chat"
    ))

    #expect(result.total == 1)
    #expect(log.starvation.isEmpty)
}

@Test("surface disclosure — not the persona filter — emptying the recall stays quiet")
func surfaceDisclosureEmptiedRecallStaysQuiet() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    // The row IS in this persona's lane — the persona filter matches it fine.
    // Only surface disclosure (permittedSurfaces excludes "slack") drops it.
    // The old probe saw "non-empty store + zero hits" and blamed the persona
    // filter for a decision it never made.
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent",
        extras: .object(["permittedSurfaces": .array([.string("chat")])])
    )

    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "ResidentAgent",
        surface: "slack"
    ))

    #expect(result.total == 0)
    #expect(result.disclosureFilteredCount == 1)
    #expect(log.starvation.isEmpty)
}

@Test("a store holding nothing disclosable on this surface stays quiet")
func nothingDisclosableAnywhereStaysQuiet() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    // Every row in the store is chat-only. A slack recall under a slot id gets
    // zero — but the persona filter cost the caller nothing, because surface
    // disclosure would have withheld these rows anyway.
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent",
        extras: .object(["permittedSurfaces": .array([.string("chat")])])
    )

    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "CustomPersona",
        surface: "slack"
    ))

    #expect(result.total == 0)
    #expect(log.starvation.isEmpty)
}

@Test("a tool loop repeating one starving recall gets ONE line, not one per call")
func repeatedStarvingRecallIsReportedOnce() async throws {
    let (memory, storage, embedder) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }
    try await seedAgentNameScopedRecord(
        storage, embedder,
        text: "User drinks jasmine tea after lunch.",
        personaId: "ResidentAgent"
    )

    // The live shape: an agent retries the same recall inside one tool loop.
    // Varying the query text proves the bound is on the (persona, surface)
    // FAILURE — not on the literal query string.
    for text in ["jasmine tea", "jasmine tea please", "tea after lunch", "jasmine tea"] {
        let result = try await memory.recall(MemoryV2RecallRequest(
            text: text,
            topK: 5,
            persona: "CustomPersona",
            surface: "chat"
        ))
        #expect(result.total == 0)
    }

    #expect(log.starvation.count == 1)

    // A DIFFERENT starving lane is still its own signal — the memo bounds
    // repetition, it does not go deaf.
    _ = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "CustomPersona",
        surface: "telegram"
    ))
    #expect(log.starvation.count == 2)
}

@Test("an empty store is not a starving lane — no alarm, no cry-wolf")
func emptyStoreStaysQuiet() async throws {
    let (memory, _, _) = makeMemory()
    let log = DiagnosticLog()
    await memory.setDiagnosticSink { log.record($0) }

    let result = try await memory.recall(MemoryV2RecallRequest(
        text: "jasmine tea",
        topK: 5,
        persona: "CustomPersona",
        surface: "chat"
    ))

    #expect(result.total == 0)
    #expect(log.starvation.isEmpty)
}
