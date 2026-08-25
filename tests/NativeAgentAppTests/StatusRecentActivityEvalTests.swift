import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.settings · Status recent activity", .serialized)
struct StatusRecentActivityEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-recent-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeEvents(_ count: Int, to root: URL) throws {
        let path = root.appendingPathComponent("activity/events.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rows = try (0..<count).map { index -> String in
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "event-\(index)",
                "kind": "eval",
                "title": "Activity \(index)",
                "status": "ok",
                "createdAt": String(format: "2026-08-24T12:%02d:00Z", index),
            ])
            return String(decoding: data, as: UTF8.self)
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: path)
    }

    @Test("the recent-activity projection shows the newest isolated-ledger events first")
    func recentActivityUsesTheInjectedCanonicalLedger() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEvents(12, to: root)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let events = try await client.getActivity()
        #expect(events.map(\.id) == (0..<12).map { "event-\($0)" })
        #expect(StatusActivityPresentation.recentEvents(from: events).map(\.id) == [
            "event-11", "event-10", "event-9", "event-8", "event-7", "event-6", "event-5", "event-4",
        ])

        let refresh = AppModel.nextRefreshStatus(
            previous: nil, failedEndpoints: [], at: Date()
        )
        #expect(StatusActivityPresentation.state(events: events, refresh: refresh) == .current(events))
        #expect(StatusActivityPresentation.state(events: [], refresh: refresh) == .empty)
    }

    @Test("unreadable activity authority remains unavailable or stale instead of empty")
    func malformedLedgerPreservesHonestAdverseStates() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity/events.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{ not activity json\n".utf8)
        try malformed.write(to: path)

        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        await #expect(throws: (any Error).self) {
            _ = try await client.getActivity()
        }
        #expect(try Data(contentsOf: path) == malformed)

        let retained = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: [
            "id": "retained", "kind": "eval", "title": "Last known activity",
            "status": "ok", "createdAt": "2026-08-24T12:00:00Z",
        ]))
        let failedRefresh = AppModel.nextRefreshStatus(
            previous: nil, failedEndpoints: ["activity"], at: Date()
        )
        #expect(StatusActivityPresentation.state(
            events: [retained],
            refresh: failedRefresh
        ) == .stale([retained]))
        #expect(StatusActivityPresentation.state(
            events: [],
            refresh: failedRefresh
        ) == .unavailable)

        let malformedTimestamp = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: [
            "id": "bad-timestamp", "kind": "eval", "title": "Timestamp evidence",
            "status": "ok", "createdAt": "not-a-timestamp",
        ]))
        #expect(StatusActivityPresentation.timestamp(for: malformedTimestamp) == "not-a-timestamp")
    }
}
