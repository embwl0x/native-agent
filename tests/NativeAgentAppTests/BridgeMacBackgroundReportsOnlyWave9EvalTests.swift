import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("app bridges reports-only wave 9", .serialized)
struct BridgeMacBackgroundReportsOnlyWave9EvalTests {
    // app.bridges / icloud.ensureChatSessionIndex
    @Test("an iCloud session index survives restart without duplicating or rewriting its canonical row")
    @MainActor
    func iCloudSessionIndexIsCreatedOnceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentWave9-session-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "ios-wave9-session"

        try await AppDelegate.ensureChatSessionIndex(sessionID: id, dataRoot: root)
        let path = root.appendingPathComponent("chat/sessions.json")
        let firstBytes = try Data(contentsOf: path)
        let first = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
        #expect(first.count == 1)
        let row = try #require(first.first)
        let rowID: JSONValue? = row["id"]
        let source: JSONValue? = row["source"]
        let sourceKey: JSONValue? = row["sourceKey"]
        let messageCount: JSONValue? = row["messageCount"]
        #expect(rowID == JSONValue.string(id))
        #expect(source == JSONValue.string("ios"))
        #expect(sourceKey == JSONValue.string(NativeAgentICloudBridgeConstants.mobileSourceKey))
        #expect(messageCount == JSONValue.int(0))

        try await AppDelegate.ensureChatSessionIndex(sessionID: id, dataRoot: root)
        #expect(try Data(contentsOf: path) == firstBytes)
    }
}
