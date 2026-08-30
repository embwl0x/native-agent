import Foundation
import PersistenceCore
import Testing
@testable import SlackConnector

@Suite
struct SlackDurableReplyTransportTests {
    @Test func messageMetadataPreservesTheDurableMarker() throws {
        let metadata: JSONValue = .object([
            "event_type": .string("nativeagent_reply"),
            "event_payload": .object([
                "event_id": .string("T1:C1:1.000"),
                "fingerprint": .string("abc123"),
            ]),
        ])
        let converted = try SlackConnectorActions.messageMetadata(input: ["metadata": metadata])
        let object = try #require(converted)
        #expect(object["event_type"] as? String == "nativeagent_reply")
        let payload = try #require(object["event_payload"] as? [String: String])
        #expect(payload["event_id"] == "T1:C1:1.000")
        #expect(payload["fingerprint"] == "abc123")
        #expect(try SlackConnectorActions.messageMetadata(input: [:]) == nil)
    }

    @Test func socketCredentialSnapshotWinsAndEmptySnapshotFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SlackSnapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokens = root.appendingPathComponent("oauth_tokens", isDirectory: true)
        try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)
        try Data("{\"access_token\":\"other-workspace\"}".utf8).write(to: tokens.appendingPathComponent("slack.json"))
        #expect(try SlackConnectorActions.resolvedToken(override: "socket-snapshot", dataRoot: root) == "socket-snapshot")
        #expect(try SlackConnectorActions.resolvedToken(override: nil, dataRoot: root) == "other-workspace")
        #expect(throws: (any Error).self) {
            try SlackConnectorActions.resolvedToken(override: "  ", dataRoot: root)
        }
    }
}
