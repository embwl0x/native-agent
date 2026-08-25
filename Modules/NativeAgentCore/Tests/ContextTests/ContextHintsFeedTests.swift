import Foundation
import Testing
@testable import Context

@Suite(.serialized)
struct ContextHintsFeedTests {
    @Test
    func validHintsAreFreshUntilTheirNewestUpdateExceedsTheNamedAge() throws {
        let root = try makeRoot("freshness")
        defer { try? FileManager.default.removeItem(at: root) }
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try writeHints([
            ["id": "hint-1", "mode": "expanded", "updatedAt": stamp(updatedAt)],
            ["id": "hint-2", "mode": "minimal", "updatedAt": stamp(updatedAt.addingTimeInterval(-60))],
        ], root: root)

        #expect(ContextHintsFeed.inspect(dataRoot: root, now: updatedAt.addingTimeInterval(60), maximumAge: 120)
            == .fresh(hintCount: 2, newestUpdatedAt: updatedAt))
        #expect(ContextHintsFeed.inspect(dataRoot: root, now: updatedAt.addingTimeInterval(121), maximumAge: 120)
            == .stale(hintCount: 2, newestUpdatedAt: updatedAt))
    }

    @Test
    func malformedRowsAreNamedInsteadOfBeingReadAsAHealthyEmptyFeed() throws {
        let root = try makeRoot("malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHints([
            ["id": "hint-1", "mode": "expanded", "updatedAt": "2026-01-01T00:00:00Z"],
            ["id": "hint-2", "mode": "minimal", "updatedAt": 1],
            ["id": "", "mode": "minimal", "updatedAt": "2026-01-01T00:00:00Z"],
        ], root: root)

        let health = ContextHintsFeed.inspect(dataRoot: root)
        #expect(health == .malformed(rowCount: 3, malformedRows: 2))
        #expect(health.warning?.contains("2 of 3 rows") == true)
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextHintsFeedTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeHints(_ rows: [[String: Any]], root: URL) throws {
        let directory = root.appendingPathComponent("context/hints", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("hints.json"))
    }

    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
