import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

@Suite struct ToolCatalogCategoryTests {
    @Test(arguments: ["search", "compact", "full"])
    func filesCategoryConstrainsSearchAndBrowse(mode: String) async throws {
        let search = mode == "search"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        var input: [String: JSONValue] = ["category": .string(" files "), "session_id": .string("scope-test")]
        if search { input["query"] = .string("find a file by filename in a folder and read a bounded section") }
        if mode == "full" { input["detail"] = .string("full") }
        guard case .object(let result) = try await dispatcher.impl_tool_catalog(input: input) else { Issue.record("Missing catalog"); return }
        #expect(result["status"] == .string("ok"))
        #expect(result["category"] == .string("files"))
        let group = try #require(ToolPreloadHeuristics.loadGroup(forCategory: "files"))
        let key = search ? "matches" : "available_tools"
        guard case .array(let rows)? = result[key] else { Issue.record("Missing scope rows"); return }
        let names: [String] = rows.compactMap { value in
            if case .string(let name) = value { return name }
            if case .object(let row) = value, case .string(let name)? = row["name"] { return name }
            return nil
        }
        #expect(!names.isEmpty)
        #expect(Set(names).isSubset(of: group.tools))
        #expect(!names.contains("github_search"))
        if mode == "full", case .array(let schemas)? = result["tools"] {
            #expect(!schemas.isEmpty)
            for schema in schemas {
                guard case .object(let row) = schema, case .string(let name)? = row["name"] else { Issue.record("Invalid schema row"); continue }
                #expect(group.tools.contains(name))
            }
        }
        let state = await dispatcher.activeToolsStore.load(sessionId: "scope-test")
        #expect(state.activeTools.isEmpty, "Discovery must not load anything")
    }

    @Test(arguments: [JSONValue.null, JSONValue.string("  ")])
    func nullAndBlankRemainUnscoped(category: JSONValue) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        guard case .object(let scoped) = try await dispatcher.impl_tool_catalog(input: ["category": category]),
              case .object(let original) = try await dispatcher.impl_tool_catalog(input: [:]) else { Issue.record("Missing catalog"); return }
        #expect(scoped["available_tools"] == original["available_tools"])
        #expect(scoped["category"] == nil)
    }

    @Test(arguments: [JSONValue.int(4), JSONValue.bool(true), JSONValue.array([]), JSONValue.string("imaginary-category")])
    func invalidScopeFailsClearly(category: JSONValue) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        guard case .object(let result) = try await dispatcher.impl_tool_catalog(input: ["category": category]) else { Issue.record("Missing failure"); return }
        #expect(result["status"] == .string("failed"))
        #expect(result["available_tools"] == nil)
        if case .string = category {
            #expect(result["reason"] == .string("unknown_category"))
            #expect(result["known_categories"] != nil)
        } else { #expect(result["reason"] == .string("invalid_category")) }
    }
}
