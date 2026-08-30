import Foundation
import CryptoKit
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Native recall exact-ID paging")
struct RecallMemoryPagingTests {
    private func fixture() async throws -> (SwiftToolDispatcher, InMemoryMemoryStorage, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-pages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = InMemoryMemoryStorage()
        let embedder = MockEmbeddingProvider(dimensions: 8)
        let text = String(repeating: "The orchard café 🌱 watering plan is weekly. ", count: 90) + "End."
        let vector = try #require(try await embedder.embed(["orchard watering"]).first)
        _ = try await storage.insert(record: MemoryRecord(
            id: "long-fact", text: text, memoryKind: "note", personaId: "Agent",
            createdAt: "2026-08-01T00:00:00Z", observedAt: "2026-07-01T12:00:00Z"
        ), embedding: vector)
        return (SwiftToolDispatcher(
            dataRoot: root, memoryV2: SwiftNativeMemoryV2(embedder: embedder, storage: storage),
            allowProcessGlobalTools: false
        ), storage, text, root)
    }

    @Test(arguments: ["recall_memory", "recall_search"])
    func searchHitRecoveryActionReadsAllCharactersInBoundedPages(tool: String) async throws {
        let (dispatcher, _, text, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = try await dispatcher.dispatch(tool: tool, input: ["query": .string("orchard watering"), "k": .int(1)], surface: "chat")
        guard case .object(let searchObject) = search,
              case .array(let hits)? = searchObject["hits"],
              case .object(let hit)? = hits.first,
              case .object(let action)? = hit["read_more"] else {
            Issue.record("excerpt lacks callable recovery action")
            return
        }
        #expect(action["memory_id"] == .string("long-fact"))
        #expect(action["tool"] == .string("recall_memory"))
        #expect(hit["content_truncated"] == .bool(true))
        var offset: Int64 = 0
        var recovered = ""
        var expectedHash: JSONValue = .null
        for _ in 0..<10 {
            let result = try await dispatcher.dispatch(tool: tool, input: [
                "memory_id": .string("long-fact"), "offset": .int(offset), "max_characters": .int(Int64.max),
                "expected_content_sha256": expectedHash,
            ], surface: "chat")
            guard case .object(let page) = result, case .string(let content)? = page["content"] else {
                Issue.record("missing record page")
                return
            }
            #expect(page["status"] == .string("ok"))
            #expect(page["offset"] == .int(offset))
            #expect(page["full_content_chars"] == .int(Int64(text.count)))
            #expect(content.count <= memoryRecallContentCap)
            #expect(!content.contains("\u{FFFD}"))
            #expect(page["temporal"] == .object(["observed_at": .string("2026-07-01T12:00:00Z")]))
            let canonicalHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(page["content_sha256"] == .string(canonicalHash))
            expectedHash = .string(canonicalHash)
            #expect(page["consistency_note"] == nil)
            recovered += content
            if page["next_offset"] == .null { break }
            guard case .int(let next)? = page["next_offset"] else {
                Issue.record("invalid next_offset")
                return
            }
            #expect(next == offset + Int64(content.count))
            guard case .object(let continuation)? = page["read_more"] else {
                Issue.record("missing version-bound continuation"); return
            }
            #expect(continuation["expected_content_sha256"] == expectedHash)
            #expect(continuation["offset"] == .int(next))
            offset = next
        }
        #expect(recovered == text)
    }

    @Test func notFoundAndDeniedAreIdenticalAndHugeOffsetIsSafe() async throws {
        let (dispatcher, _, text, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("long-fact")], surface: "slack")
        let missing = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("missing")], surface: "slack")
        #expect(denied == missing)
        #expect(missing == .object(["status": .string("not_found")]))
        let end = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("long-fact"), "offset": .int(Int64.max)], surface: "chat")
        guard case .object(let page) = end else { Issue.record("missing end page"); return }
        #expect(page["content"] == .string(""))
        #expect(page["offset"] == .int(Int64(text.count)))
        #expect(page["next_offset"] == .null)
    }

    @Test func invalidOrMixedPagingArgumentsAreRejectedWithoutNumericTraps() async throws {
        let (dispatcher, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs: [[String: JSONValue]] = [
            ["memory_id": .string("long-fact"), "query": .string("orchard")],
            ["memory_id": .string("long-fact"), "k": .int(1)],
            ["query": .string("orchard"), "offset": .int(1)],
            ["memory_id": .string("long-fact"), "offset": .int(-1)],
            ["memory_id": .string("long-fact"), "max_characters": .int(0)],
            ["memory_id": .string("long-fact"), "offset": .double(1e100)],
            ["memory_id": .string("long-fact"), "offset": .double(0.5)],
            ["memory_id": .string("long-fact"), "max_characters": .double(.infinity)],
            ["memory_id": .string("long-fact"), "offset": .string("1")],
            ["query": .string("orchard"), "expected_content_sha256": .string(String(repeating: "a", count: 64))],
            ["memory_id": .string("long-fact"), "expected_content_sha256": .string("not-a-hash")],
            ["memory_id": .string("long-fact"), "expected_content_sha256": .string(String(repeating: "z", count: 64))],
        ]
        for input in inputs {
            await #expect(throws: (any Error).self) {
                _ = try await dispatcher.impl_recall_memory(input: input, surface: "chat")
            }
        }
    }

    @Test func strictBindingNullAndEmptyPlaceholdersDoNotMixModes() async throws {
        let (dispatcher, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = try await dispatcher.dispatch(tool: "recall_memory", input: [
            "query": .string("orchard watering"), "memory_id": .null,
            "offset": .null, "max_characters": .string(""), "k": .null,
        ], surface: "chat")
        guard case .object(let searchObject) = search else { Issue.record("missing search"); return }
        #expect(searchObject["hits"] != nil)
        let page = try await dispatcher.dispatch(tool: "recall_memory", input: [
            "memory_id": .string("long-fact"), "query": .string(" "), "k": .null,
            "offset": .null, "max_characters": .null,
        ], surface: "chat")
        guard case .object(let pageObject) = page else { Issue.record("missing page"); return }
        #expect(pageObject["id"] == .string("long-fact"))
        #expect(pageObject["offset"] == .int(0))
        #expect(pageObject["next_offset"] == .int(Int64(memoryRecallContentCap)))
    }

    @Test(arguments: ["recall_memory", "recall_search"])
    func requiredWireFieldsCanUseSchemaAdmittedNullsInBothModes(tool: String) async throws {
        let (dispatcher, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = try #require(dispatcher.builtInToolSchemas(includeFullMacFileTools: false).first { $0.name == tool })
        guard case .object(let object) = try JSONValue.parse(schema.parametersJSON),
              case .object(let properties)? = object["properties"] else {
            Issue.record("missing schema properties"); return
        }
        let inputs: [[String: JSONValue]] = [
            ["query": .string("orchard watering"), "k": .int(1), "memory_id": .null,
             "offset": .null, "max_characters": .null, "expected_content_sha256": .null],
            ["query": .null, "k": .null, "memory_id": .string("long-fact"),
             "offset": .int(0), "max_characters": .int(2000), "expected_content_sha256": .null],
        ]
        for input in inputs {
            #expect(Set(input.keys) == Set(properties.keys))
            for (key, value) in input where value == .null {
                guard case .object(let field)? = properties[key],
                      case .array(let types)? = field["type"] else {
                    Issue.record("unused field cannot represent null: \(key)"); return
                }
                #expect(types.contains(.string("null")))
            }
            let result = try await dispatcher.dispatch(tool: tool, input: input, surface: "chat")
            guard case .object(let output) = result else { Issue.record("missing result"); return }
            if input["memory_id"] == .null {
                #expect(output["hits"] != nil)
            } else {
                #expect(output["id"] == .string("long-fact"))
                #expect(output["next_offset"] == .int(2000))
            }
        }
    }

    @Test func bothExistingToolSchemasAdvertiseSearchAndExactPageModes() async throws {
        let (dispatcher, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: false)
        for name in ["recall_memory", "recall_search"] {
            let schema = try #require(schemas.first { $0.name == name })
            guard case .object(let object) = try JSONValue.parse(schema.parametersJSON),
                  case .object(let properties)? = object["properties"] else {
                Issue.record("missing schema properties"); return
            }
            for key in ["query", "k", "memory_id", "offset", "max_characters", "expected_content_sha256"] {
                guard case .object(let field)? = properties[key] else {
                    Issue.record("missing field \(key)"); return
                }
                let valueType = ["query", "memory_id", "expected_content_sha256"].contains(key) ? "string" : "integer"
                #expect(field["type"] == .array([.string(valueType), .string("null")]))
            }
            #expect(object["required"] == .array([]))
        }
    }

    @Test func sameLengthEditRejectsBoundContinuationWithoutReturningMixedText() async throws {
        let (dispatcher, storage, original, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("long-fact")], surface: "chat")
        guard case .object(let page) = first, case .object(let continuation)? = page["read_more"] else {
            Issue.record("missing continuation"); return
        }
        let changed = original.replacingOccurrences(of: "weekly", with: "yearly")
        #expect(changed.count == original.count)
        _ = try await storage.updateMemory(id: "long-fact", patch: .object(["content": .string(changed)]), newEmbedding: nil)
        let result = try await dispatcher.dispatch(tool: "recall_memory", input: continuation, surface: "chat")
        guard case .object(let conflict) = result else { Issue.record("missing change response"); return }
        #expect(conflict["status"] == .string("record_changed"))
        #expect(conflict["restart_at"] == .int(0))
        #expect(conflict["content"] == nil)
        #expect(conflict["next_offset"] == nil)
        #expect(conflict["content_sha256"] != page["content_sha256"])
        let restarted = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("long-fact")], surface: "chat")
        guard case .object(let restart) = restarted else { Issue.record("missing restarted page"); return }
        #expect(restart["status"] == .string("ok"))
        #expect(restart["content_sha256"] == conflict["content_sha256"])

        var legacy = continuation
        legacy.removeValue(forKey: "expected_content_sha256")
        let unchecked = try await dispatcher.dispatch(tool: "recall_memory", input: legacy, surface: "chat")
        guard case .object(let uncheckedPage) = unchecked else { Issue.record("missing legacy page"); return }
        #expect(uncheckedPage["status"] == .string("ok"))
        #expect(uncheckedPage["consistency_note"] != nil)
    }

    @Test func accessOrRetirementChangeIsCheckedBeforeVersionInformation() async throws {
        let (dispatcher, storage, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await dispatcher.dispatch(tool: "recall_memory", input: ["memory_id": .string("long-fact")], surface: "chat")
        guard case .object(let page) = first, case .object(var continuation)? = page["read_more"] else {
            Issue.record("missing continuation"); return
        }
        // Deliberately mismatched version must not reveal the current hash to
        // a surface which cannot read the canonical record.
        continuation["expected_content_sha256"] = .string(String(repeating: "0", count: 64))
        let denied = try await dispatcher.dispatch(tool: "recall_memory", input: continuation, surface: "slack")
        #expect(denied == .object(["status": .string("not_found")]))
        _ = try await storage.updateMemory(id: "long-fact", patch: .object(["status": .string("deleted")]), newEmbedding: nil)
        let retired = try await dispatcher.dispatch(tool: "recall_memory", input: continuation, surface: "chat")
        #expect(retired == denied)
    }

    @Test func boundUnicodePagesPreserveExtendedGraphemes() async throws {
        let (dispatcher, storage, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "The orchard marker sequence is " + String(repeating: "👩🏽‍🌾e\u{301}🇲🇽", count: 900) + "."
        _ = try await storage.updateMemory(id: "long-fact", patch: .object(["content": .string(text)]), newEmbedding: nil)
        var input: [String: JSONValue] = ["memory_id": .string("long-fact")]
        var joined = ""
        var priorHash: JSONValue?
        for _ in 0..<3 {
            let result = try await dispatcher.dispatch(tool: "recall_search", input: input, surface: "chat")
            guard case .object(let page) = result, case .string(let content)? = page["content"] else {
                Issue.record("missing Unicode page"); return
            }
            #expect(content.count <= 2000)
            #expect(page["status"] == .string("ok"))
            if let priorHash { #expect(page["content_sha256"] == priorHash) }
            priorHash = page["content_sha256"]
            joined += content
            if page["next_offset"] == .null { break }
            guard case .object(let continuation)? = page["read_more"] else {
                Issue.record("missing Unicode continuation"); return
            }
            input = continuation
        }
        #expect(joined == text)
        #expect(Data(joined.utf8) == Data(text.utf8))
    }
}
