import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

@Suite("Chat session index restart reconciliation")
struct ChatSessionIndexReconcilerTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-index-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("chat/messages", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("[]".utf8).write(to: root.appendingPathComponent("chat/sessions.json"))
        return root
    }

    @Test func recoversOrphanTranscriptExactlyOnce() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let sessionID = "telegram-recovered"
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.appendJSONLDurable(.object([
            "id": .string("m1"),
            "sessionId": .string(sessionID),
            "role": .string("user"),
            "content": .string("Please recover this session"),
            "createdAt": .string("2026-08-16T12:00:00Z"),
            "source": .string("telegram"),
        ]), to: transcript)

        let reconciler = ChatSessionIndexReconciler(dataRoot: dataRoot)
        let first = try await reconciler.reconcile()
        #expect(first.sessionsRecovered == 1)
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(
            at: dataRoot.appendingPathComponent("chat/sessions.json")
        )
        #expect(rows.count == 1)
        #expect(rows.first?["id"] == .string(sessionID))
        #expect(rows.first?["messageCount"] == .int(1))

        let second = try await reconciler.reconcile()
        #expect(second.sessionsRecovered == 0)
        #expect(try ChatSessionIndexFile.loadObjectRowsForMutation(
            at: dataRoot.appendingPathComponent("chat/sessions.json")
        ).count == 1)
    }

    @Test func malformedInteriorRowIsVisibleAndNeverRewritten() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let sessionID = "damaged-session"
        let transcript = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        let bytes = Data("""
        {"id":"m1","sessionId":"damaged-session","role":"user","content":"before","createdAt":"2026-08-16T12:00:00Z"}
        {bad json}
        {"id":"m2","sessionId":"damaged-session","role":"assistant","content":"after","createdAt":"2026-08-16T12:00:01Z"}
        """.utf8)
        try bytes.write(to: transcript)

        let history = try await SessionHistoryReader(dataRoot: dataRoot)
            .messagesWithStats(forSessionId: sessionID)
        #expect(history.messages.count == 2)
        #expect(history.stats.malformedRowCount == 1)

        let report = try await ChatSessionIndexReconciler(dataRoot: dataRoot).reconcile()
        #expect(report.sessionsRecovered == 0)
        #expect(report.corruptTranscripts == 1)
        #expect(try Data(contentsOf: transcript) == bytes)
        #expect(try ChatSessionIndexFile.loadObjectRowsForMutation(
            at: dataRoot.appendingPathComponent("chat/sessions.json")
        ).isEmpty)
    }

    @Test func boundedScanPrioritizesOrphansOverKnownHistoricalTranscripts() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let knownIDs = ["a-known", "b-known", "c-known"]
        let knownRows = knownIDs.map { ["id": JSONValue.string($0)] }
        try ChatSessionIndexFile.serializedData(for: knownRows).write(to: sessionsPath)

        let persistence = SwiftNativePersistenceCore()
        for sessionID in knownIDs + ["zz-orphan"] {
            try await persistence.appendJSONLDurable(.object([
                "id": .string("message-\(sessionID)"),
                "sessionId": .string(sessionID),
                "role": .string("user"),
                "content": .string("hello from \(sessionID)"),
                "createdAt": .string("2026-08-16T12:00:00Z"),
            ]), to: dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl"))
        }

        let report = try await ChatSessionIndexReconciler(dataRoot: dataRoot)
            .reconcile(maximumFiles: 2)
        #expect(report.transcriptsExamined == 2)
        #expect(report.skippedForBounds == 2)
        #expect(report.sessionsRecovered == 1)
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        #expect(rows.contains { $0["id"] == .string("zz-orphan") })
    }
}
