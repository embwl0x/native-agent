import Foundation
import ChatOrchestration
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Desk actions traverse the same lazy-tool authority as chat.  Supplying the
/// session loadout here ensures this feed eval reaches the nag-config writer
/// rather than stopping at the dispatcher’s missing-session denial.
private struct NagConfigAuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

/// Executable fence for `feeds / feeds.desk.nag_config`.
@Suite("Desk nag config feed")
struct DeskNagConfigFeedEvalTests {
    @Test("a Desk nag toggle rewrites only the owned config schema")
    func deskNagToggleWritesKnownSchema() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskNagConfigFeedEval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DeskNagConfigStore(dataRoot: root)
        try await store.save(DeskNagConfig())
        let path = store.configPath
        let before = try Data(contentsOf: path)

        // Ensure the filesystem can represent a distinct modification instant;
        // the action below is the exact route used by the Desk toggle.
        try await Task.sleep(nanoseconds: 10_000_000)
        let sessionID = "desk-nag-config-feed-\(UUID().uuidString)"
        try await ActiveToolsStore(dataRoot: root).addLoaded(
            sessionId: sessionID,
            names: ["desk_nag_control"]
        )
        let outcome = await DeskActionRunner.perform(
            .nagGlobal(on: true),
            via: NagConfigAuthorizedDeskRouter(
                router: DeskToolDispatchRouter(dataRoot: root),
                sessionID: sessionID
            )
        )

        #expect(outcome.ok, "the UI action must not claim a config change unless the locked writer accepted it")
        let raw = try JSONValue.parse(Data(contentsOf: path))
        #expect(DeskNagConfigSchema.unexpectedKeys(in: raw).isEmpty)
        #expect(
            DeskNagConfigSchema.unexpectedKeys(in: .object([
                "enabled": .bool(true),
                "writerDrift": .string("not owned"),
            ])) == ["root.writerDrift"]
        )
        #expect(try Data(contentsOf: path) != before)

        let reloaded = await DeskNagConfigStore(dataRoot: root).load()
        #expect(reloaded.enabled)
    }
}
