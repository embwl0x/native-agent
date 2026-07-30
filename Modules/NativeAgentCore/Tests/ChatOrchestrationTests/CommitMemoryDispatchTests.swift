import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

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

    // SecurityCenter risk profiling for commit_memory is asserted in
    // TrustCenterTests/CommitMemorySecurityTests.swift (the profile() helper is
    // a private extension; the public evaluateTool envelope is the test seam).
}
