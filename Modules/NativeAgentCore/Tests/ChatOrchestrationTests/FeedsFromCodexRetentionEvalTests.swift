import Foundation
import Testing
@testable import ChatOrchestration

@Suite("feeds.from_codex retention", .serialized)
struct FeedsFromCodexRetentionEvalTests {
    @Test("evicting an old Codex audit also evicts only its matching last-message sidecar")
    func auditRetentionKeepsActiveOrphanAndRemovesEvictedPairs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feeds-from-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let count = SwiftToolDispatcher.agentBridgeAuditRetention + 2
        for index in 0..<count {
            let runID = "run-\(index)"
            let audit = root.appendingPathComponent("\(runID).json")
            let message = root.appendingPathComponent("\(runID)-last-message.txt")
            try Data("{}".utf8).write(to: audit)
            try Data("last message".utf8).write(to: message)
            let date = Date(timeIntervalSince1970: TimeInterval(index + 1))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: audit.path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: message.path)
        }

        let activeSidecar = root.appendingPathComponent("active-last-message.txt")
        try Data("in-progress Codex output".utf8).write(to: activeSidecar)

        SwiftToolDispatcher.trimAgentBridgeAudits(in: root)

        let remainingAudits = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(remainingAudits.count == SwiftToolDispatcher.agentBridgeAuditRetention)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run-0.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run-0-last-message.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run-1-last-message.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("run-2-last-message.txt").path))
        #expect(FileManager.default.fileExists(atPath: activeSidecar.path), "an unmatched sidecar may belong to an active run")
    }
}
