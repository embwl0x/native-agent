import Foundation
import Testing
@testable import PersistenceCore

@Suite("Chat session index integrity")
struct ChatSessionIndexFileTests {
    @Test func missingIndexIsTheOnlyStateTreatedAsNew() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat/sessions.json")

        #expect(try ChatSessionIndexFile.loadObjectRowsForMutation(at: path).isEmpty)
    }

    @Test func invalidExistingIndexesAreRejectedWithoutChangingTheirBytes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat/sessions.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payloads = [
            Data(),
            Data("  \n\t".utf8),
            Data("{not-json".utf8),
            Data(#"{"id":"object-not-array"}"#.utf8),
            Data(#"[{"id":"valid"},42]"#.utf8),
        ]

        for payload in payloads {
            try payload.write(to: path, options: .atomic)
            let before = try Data(contentsOf: path)
            #expect(throws: ChatSessionIndexFileError.self) {
                _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: path)
            }
            #expect(try Data(contentsOf: path) == before)
        }
    }

    @Test func retentionRejectsMixedRowsWithoutArchivingOrRewriting() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat/sessions.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(#"[{"id":"valid","updatedAt":"2020-01-01T00:00:00Z","messageCount":0},false]"#.utf8)
        try payload.write(to: path)

        #expect(throws: ChatSessionIndexFileError.self) {
            _ = try ChatSessionRetention.enforce(
                dataRoot: root,
                policy: ChatSessionRetentionPolicy(
                    maxActiveSessions: 1,
                    staleEmptySessionAgeSeconds: 1,
                    includeMacPinnedSessions: false
                )
            )
        }

        #expect(try Data(contentsOf: path) == payload)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("chat/archive").path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-session-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
