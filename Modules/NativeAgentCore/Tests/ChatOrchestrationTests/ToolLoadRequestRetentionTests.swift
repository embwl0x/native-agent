import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

@Suite("Tool load request retention")
struct ToolLoadRequestRetentionTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-load-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = value else {
            throw NSError(domain: "ToolLoadRequestRetentionTests", code: 1)
        }
        return object
    }

    private func seedOldLoadout(root: URL, session: String, names: Set<String>, oldest: String) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldStamp = formatter.string(from: Date().addingTimeInterval(-7200))
        let newerStamp = formatter.string(from: Date().addingTimeInterval(-3600))
        let state: JSONValue = .object([
            "sessionId": .string(session),
            "activeTools": .array(names.sorted().map(JSONValue.string)),
            "loadedAt": .object(Dictionary(uniqueKeysWithValues: names.map {
                ($0, JSONValue.string($0 == oldest ? oldStamp : newerStamp))
            })),
            "updatedAt": .string(newerStamp),
        ])
        let path = root.appendingPathComponent("chat/active_tools/\(session).json")
        try await SwiftNativePersistenceCore().writeJSON(state, to: path)
        return oldStamp
    }

    @Test func mixedRequestProtectsAlreadyActiveToolAtCap() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = UUID().uuidString
        let old = "market_status"
        let new = "workshop_status"
        let available = Set(try await dispatcher.listAvailableTools())
            .subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
            .subtracting(SwiftToolDispatcher.legacyMacModelToolNames)
        #expect(available.isSuperset(of: [old, new]))
        let filler = Set(available.subtracting([old, new]).sorted().prefix(ActiveToolsStore.maxPersistedTools - 1))
        let initial = filler.union([old])
        #expect(initial.count == ActiveToolsStore.maxPersistedTools)
        let oldStamp = try await seedOldLoadout(root: root, session: session, names: initial, oldest: old)

        let result = try object(try await dispatcher.dispatch(tool: "tool_load", input: [
            "session_id": .string(session), "names": .array([.string(old), .string(new)]),
        ], surface: "chat"))
        #expect(result["loaded_now"] == .array([.string(new)]))
        #expect(result["already_active"] == .array([.string(old)]))
        #expect(result["loaded"] == .array([.string(old), .string(new)]))
        guard case .array(let schemas)? = result["schemas_added"] else {
            Issue.record("missing schema delta"); return
        }
        #expect(try schemas.map { try object($0)["name"] } == [.string(new)])
        let state = await dispatcher.activeToolsStore.load(sessionId: session)
        #expect(state.activeTools.count == ActiveToolsStore.maxPersistedTools)
        #expect(state.activeTools.isSuperset(of: [old, new]))
        #expect(state.loadedAt[old] != oldStamp)
        #expect(initial.subtracting(state.activeTools).count == 1)
        // Exercise the actual lazy gate, not just the success-shaped receipt.
        let dispatched = try object(try await dispatcher.dispatch(tool: old, input: [
            "session_id": .string(session),
        ], surface: "chat"))
        #expect(dispatched["reason"] != .string("not_loaded"))
        #expect(dispatched["runtime"] == .string("swift-native"))
    }

    @Test func explicitReloadRefreshesTTLWithoutNewSchemaDelta() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = UUID().uuidString
        let name = "market_status"
        let oldStamp = try await seedOldLoadout(root: root, session: session, names: [name], oldest: name)
        let result = try object(try await dispatcher.dispatch(tool: "tool_load", input: [
            "session_id": .string(session), "names": .array([.string(name)]),
        ], surface: "chat"))
        #expect(result["loaded_now"] == .array([]))
        #expect(result["schemas_added"] == .array([]))
        let state = await dispatcher.activeToolsStore.load(sessionId: session)
        #expect(state.activeTools == [name])
        #expect(state.loadedAt[name] != oldStamp)
    }

    @Test func explicitOversizedMixedRequestRemainsWhole() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = UUID().uuidString
        let requested = Set(Set(try await dispatcher.listAvailableTools())
            .subtracting(SwiftToolDispatcher.alwaysOnCoreNames)
            .subtracting(SwiftToolDispatcher.legacyMacModelToolNames)
            .sorted().prefix(ActiveToolsStore.maxPersistedTools + 6))
        #expect(requested.count == ActiveToolsStore.maxPersistedTools + 6)
        let previous = Set(requested.sorted().prefix(ActiveToolsStore.maxPersistedTools))
        _ = try await dispatcher.activeToolsStore.addLoaded(sessionId: session, names: previous)
        let result = try object(try await dispatcher.dispatch(tool: "tool_load", input: [
            "session_id": .string(session), "names": .array(requested.sorted().map(JSONValue.string)),
        ], surface: "chat"))
        #expect(result["loaded_now"] == .array(requested.subtracting(previous).sorted().map(JSONValue.string)))
        #expect(result["session_active_count"] == .int(Int64(requested.count)))
        #expect(await dispatcher.activeToolsStore.load(sessionId: session).activeTools == requested)
    }
}
