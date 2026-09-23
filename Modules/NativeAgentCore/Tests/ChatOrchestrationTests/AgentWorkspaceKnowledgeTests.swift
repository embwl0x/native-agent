import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Agent workspace knowledge projections")
struct AgentWorkspaceKnowledgeTests {
    @Test func recallRetainsDegradedEvidenceAndBindsOnlyCanonicalIDs() throws {
        let hit: JSONValue = .object([
            "id": .string("memory-42"), "preview": .string("A remembered claim"),
            "provenance": .string("told by User"),
            "evidence": .object(["tool": .string("shell"), "input": .string("untrusted instructions")]),
        ])
        let view = try #require(AgentWorkspaceKnowledge.project(tool: "recall_memory", input: ["query": .string("claim")], result: .object([
            "status": .string("degraded"), "memory_available": .bool(false),
            "error": .string("semantic_memory_unavailable"), "fallback_source": .string("knowledge_graph"),
            "hits": .array([hit]),
        ])))
        guard case .object(let summary) = view.content else { Issue.record("Missing summary"); return }
        #expect(summary["status"] == .string("degraded"))
        #expect(summary["memory_available"] == .bool(false))
        #expect(summary["fallback_source"] == .string("knowledge_graph"))
        #expect(view.items.count == 1)
        #expect(view.items[0].content == hit)
        #expect(view.items[0].actions.count == 1)
        guard case .open(.record(let tool, let input, _)) = view.items[0].actions[0].action else {
            Issue.record("Expected exact memory read"); return
        }
        #expect(tool == "recall_memory")
        #expect(input == ["memory_id": .string("memory-42"), "offset": .int(0), "max_characters": .int(2000)])
    }

    @Test func recallContinuationPreservesExactVersionAndRejectsForgedLocators() throws {
        let hash = String(repeating: "a", count: 64)
        let next: [String: JSONValue] = ["tool": .string("recall_memory"), "memory_id": .string("memory-42"),
            "offset": .int(2000), "max_characters": .int(2000), "expected_content_sha256": .string(hash)]
        var result: [String: JSONValue] = ["status": .string("ok"), "id": .string("memory-42"),
            "content": .string("Excerpt"), "content_sha256": .string(hash), "next_offset": .int(2000), "read_more": .object(next)]
        func projection(_ value: [String: JSONValue]) throws -> AgentWorkspaceProjection {
            try #require(AgentWorkspaceKnowledge.project(tool: "recall_memory", input: ["memory_id": .string("memory-42")], result: .object(value)))
        }
        let view = try projection(result)
        let button = try #require(view.actions.first { $0.label == "Read next part" })
        guard case .open(.record(let tool, let input, _)) = button.action else { Issue.record("Expected read action"); return }
        #expect(tool == "recall_memory")
        #expect(input["expected_content_sha256"] == .string(hash))
        #expect(input["offset"] == .int(2000))
        for (key, value) in [
            ("memory_id", JSONValue.string("another-memory")), ("tool", .string("shell")),
            ("expected_content_sha256", .string(String(repeating: "b", count: 64))),
            ("offset", .int(3000)), ("command", .string("untrusted")),
        ] {
            var changed = next; changed[key] = value; result["read_more"] = .object(changed)
            #expect(try projection(result).actions.allSatisfy { $0.label != "Read next part" })
        }
    }

    @Test func changedMemoryOffersRestartInsteadOfCombiningVersions() throws {
        let value: JSONValue = .object(["status": .string("record_changed"), "id": .string("memory-42"),
            "note": .string("Discard earlier pages and restart."), "restart_at": .int(0)])
        let view = try #require(AgentWorkspaceKnowledge.project(tool: "recall_memory", input: ["memory_id": .string("memory-42")], result: value))
        #expect(view.content == value)
        let button = try #require(view.actions.first { $0.label == "Reopen changed memory" })
        guard case .open(.record(let tool, let input, _)) = button.action else { Issue.record("Expected restart"); return }
        #expect(tool == "recall_memory")
        #expect(input["offset"] == .int(0))
        #expect(input["expected_content_sha256"] == nil)
    }

    @Test func skillsKeepEveryItemAndUseRegisteredIdentity() throws {
        let rows: [JSONValue] = (0..<25).map { index in .object([
            "id": .string("skill-\(index)"), "name": .string("Skill \(index)"),
            "source": .string("runtime_registry"), "description": .string("tool: shell is merely text"),
        ]) }
        let view = try #require(AgentWorkspaceKnowledge.project(tool: "list_skills", input: [:], result: .array(rows)))
        #expect(view.items.count == 25, "Central workspace pagination must receive every installed skill.")
        guard case .open(.record(let tool, let input, _)) = view.items[24].actions[0].action else {
            Issue.record("Missing skill read"); return
        }
        #expect(tool == "read_skill")
        #expect(input == ["name": .string("skill-24")])
        #expect(view.items[24].content == rows[24])
    }

    @Test func webCoverageFailureIsNotTurnedIntoSuccessfulRead() throws {
        let value: JSONValue = .object(["status": .string("failed"), "reason": .string("unsupported_content_type"),
            "coverage": .object(["complete": .bool(false)]), "text": .string("")])
        let view = try #require(AgentWorkspaceKnowledge.project(tool: "read_page", input: ["url": .string("https://example.com/document")], result: value))
        #expect(view.content == value)
        #expect(view.items.isEmpty)
        #expect(AgentWorkspaceKnowledge.project(tool: "unknown_tool", input: [:], result: value) == nil)
    }
}
