import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2

// MARK: - commit_memory dispatcher-surface tests
//
// commit_memory is Agent's memory WRITE path, restored after the Python→Swift
// chat cutover dropped it (~2026-05-17). These tests pin the DISPATCHER-LAYER
// wiring: catalog advertisement + schema, lazy-load/always-on membership,
// empty-text rejection (which fires BEFORE the .shared store, so it's
// hermetic), and the SecurityCenter risk profile.
//
// The store round-trip + kind threading + dedup-for-free are asserted
// hermetically in MemoryV2Tests/CommitMemoryStoreTests.swift (the impl routes
// to the process-wide SwiftNativeMemoryV2.shared, which cannot be redirected
// to a tmp root from inside one test without racing the global `let`).

@Suite("CommitMemoryDispatch")
struct CommitMemoryDispatchTests {

    private func hermeticDispatcher() -> SwiftToolDispatcher {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommitMemoryDispatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SwiftToolDispatcher(dataRoot: root)
    }

    // MARK: Catalog

    @Test func catalogAdvertisesCommitMemoryInAlwaysOnBlock() async throws {
        let dispatcher = hermeticDispatcher()
        // includeFullMacFileTools=false → only the ALWAYS-ON block. commit_memory
        // must appear here (daemon always_on + AUTO), NOT gated behind Full Mac.
        let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: false)
        let commit = try #require(schemas.first { $0.name == "commit_memory" })
        #expect(commit.description.contains("Durably record"))

        // Schema declares `text` required and the four optional params.
        let parsed = try JSONValue.parse(commit.parametersJSON)
        guard case .object(let obj) = parsed,
              case .object(let props)? = obj["properties"],
              case .array(let required)? = obj["required"] else {
            Issue.record("commit_memory schema is not a well-formed object")
            return
        }
        #expect(required == [.string("text")])
        #expect(props["text"] != nil)
        #expect(props["kind"] != nil)
        #expect(props["tags"] != nil)
        #expect(props["confidence"] != nil)
        #expect(props["importance"] != nil)
        // R13: correction lineage params — the LLM must be able to name the
        // memory a new fact corrects (store round-trip pinned in
        // MemoryV2Tests/CorrectionLineageTests).
        #expect(props["corrects"] != nil)
        #expect(props["correction_reason"] != nil)
        #expect(props["context_topics"] != nil)
        // confidence/importance carry the JSON Schema number type.
        if case .object(let conf)? = props["confidence"] {
            #expect(conf["type"] == .string("number"))
        } else {
            Issue.record("confidence is not an object schema")
        }
    }

    @Test func commitMemoryIsAlwaysOnAndBuiltIn() {
        // Hot core: dispatchable without a tool_load dance (symmetric with
        // recall_memory) AND advertised in listAvailableTools via builtInToolNames.
        #expect(SwiftToolDispatcher.alwaysOnCoreNames.contains("commit_memory"))
        #expect(SwiftToolDispatcher.builtInToolNames.contains("commit_memory"))
    }

    // MARK: Empty-text rejection (hermetic — throws before the store)

    @Test func emptyTextRejectedBeforeStore() async throws {
        let dispatcher = hermeticDispatcher()
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_commit_memory(input: ["text": .string("   ")])
        }
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_commit_memory(input: ["text": .string("")])
        }
    }

    @Test func missingTextRejected() async throws {
        let dispatcher = hermeticDispatcher()
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_commit_memory(input: ["kind": .string("note")])
        }
    }

    @Test func malformedTopicScopeIsRejectedBeforeMemoryWrite() async throws {
        let dispatcher = hermeticDispatcher()
        for value in [JSONValue.array([]), .array([.int(1)]), .array([.string(" ")]), .string("project")] {
            await #expect(throws: (any Error).self) {
                _ = try await dispatcher.impl_commit_memory(input: [
                    "text": .string("The greenhouse schedule is dusk."), "kind": .string("correction"),
                    "context_topics": value,
                ])
            }
        }
    }

    @Test(arguments: [false, true])
    func duplicateCorrectionKeepsExistingFactAndReportsNoSelfCorrection(normalizedVariant: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("commit-self-correction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: MemoryStorageBridge(storage: storage))
        let dispatcher = SwiftToolDispatcher(dataRoot: root, memoryV2: memory, allowProcessGlobalTools: false)
        let text = "The orchard gate opens at dusk."
        let original = try await memory.store(content: text, source: "chat.commit_memory")
        let before = try #require(try await storage.memory(id: original.id))
        let result = try await dispatcher.impl_commit_memory(input: [
            "text": .string(normalizedVariant ? "THE ORCHARD GATE OPENS AT DUSK!" : text),
            "corrects": .string(original.id),
            "kind": .string("correction"),
        ])
        guard case .object(let payload) = result,
              case .object(let correction)? = payload["correction"] else {
            Issue.record("missing correction receipt")
            return
        }
        #expect(payload["status"] == .string("ok"))
        #expect(payload["id"] == .string(original.id))
        #expect(correction["applied"] == .bool(false))
        #expect(correction["note"] == .string("The saved text resolved to the same existing memory. No self-correction was applied; this call did not retire that record."))
        let after = try #require(try await storage.memory(id: original.id))
        #expect(after.content == before.content)
        #expect(after.lifecycle == before.lifecycle)
        #expect(after.status == "active")
        if case .object(let metadata)? = after.metadata {
            #expect(metadata["corrected_by"] == nil)
            #expect(metadata["correction_history"] == nil)
        }
        let hits = try await storage.recallByKeyword(queryText: "orchard gate", topK: 5)
        #expect(hits.map(\.memory.id) == [original.id])
    }

    // SecurityCenter risk profiling for commit_memory is asserted in
    // TrustCenterTests/CommitMemorySecurityTests.swift (the profile() helper is
    // a private extension; the public evaluateTool envelope is the test seam).
}
