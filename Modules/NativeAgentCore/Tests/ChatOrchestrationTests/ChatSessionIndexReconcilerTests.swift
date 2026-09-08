import Darwin
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
        #expect(
            second.transcriptsExamined == 0,
            "a transcript with a canonical index row must not be parsed again at launch"
        )
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

    @Test(.timeLimit(.minutes(1)))
    func heldOrphanLockDoesNotBlockUnrelatedIndexPersistence() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let persistence = SwiftNativePersistenceCore()
        for sessionID in ["a-held", "b-recoverable"] {
            try await persistence.appendJSONLDurable(.object([
                "id": .string("message-\(sessionID)"),
                "sessionId": .string(sessionID),
                "role": .string("user"),
                "content": .string("Recover \(sessionID)"),
                "createdAt": .string("2026-09-07T12:00:00Z"),
            ]), to: dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl"))
        }
        let lockPath = dataRoot.appendingPathComponent("chat/messages/a-held.jsonl.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY, 0o600)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(fd, LOCK_UN) }

        let reconciler = ChatSessionIndexReconciler(dataRoot: dataRoot)
        let report = try await withThrowingTaskGroup(
            of: ChatSessionIndexReconciliationReport?.self
        ) { group in
            group.addTask { try await reconciler.reconcile() }
            group.addTask {
                try await persistence.withFileLock(sessionsPath) {
                    var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
                    rows.append(["id": .string("unrelated"), "title": .string("Live chat")])
                    try await persistence.writeDataAtomicDurable(
                        ChatSessionIndexFile.serializedData(for: rows), to: sessionsPath
                    )
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw NSError(domain: "ReconciliationTestTimeout", code: 1)
            }
            defer { group.cancelAll() }
            var report: ChatSessionIndexReconciliationReport?
            for _ in 0..<2 {
                if let completion = try await group.next(), let result = completion { report = result }
            }
            return try #require(report)
        }
        #expect(report.sessionsRecovered == 1)
        #expect(report.skippedForBounds == 1)
        #expect(report.corruptTranscripts == 0)
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        #expect(rows.contains { $0["id"] == .string("unrelated") })
        #expect(rows.contains { $0["id"] == .string("b-recoverable") })
        #expect(!rows.contains { $0["id"] == .string("a-held") })

        _ = flock(fd, LOCK_UN)
        let retry = try await reconciler.reconcile()
        #expect(retry.sessionsRecovered == 1)
        #expect(retry.skippedForBounds == 0)
    }

    @Test func boundedScanExcludesKnownHistoricalTranscripts() async throws {
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
        #expect(report.transcriptsExamined == 1)
        #expect(report.skippedForBounds == 0)
        #expect(report.sessionsRecovered == 1)
        let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        #expect(rows.contains { $0["id"] == .string("zz-orphan") })
    }
}
