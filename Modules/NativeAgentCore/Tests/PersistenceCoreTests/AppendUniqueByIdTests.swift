import Testing
import Foundation
@testable import PersistenceCore

// MARK: - appendUniqueById (tightness sweep C10 / 2026-07-17)
//
// The idempotent-inbox-card append extracted from the two byte-identical
// MemoryV2 stagers: append only if no recent row shares the id.

@Suite("appendUniqueById")
struct AppendUniqueByIdTests {
    private func tmpFile() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uniqueid-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inbox.jsonl")
    }

    private func card(_ id: String) -> JSONValue { .object(["id": .string(id), "body": .string("x")]) }

    private func ids(_ path: URL) throws -> [String] {
        try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { raw in
                guard let parsed = try? JSONValue.parse(Data(String(raw).utf8)),
                      case .object(let obj) = parsed, case .string(let id)? = obj["id"] else { return nil }
                return id
            }
    }

    @Test func appendsWhenAbsent_andDedupesRepeat() async throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let p = SwiftNativePersistenceCore()

        try await appendUniqueById(card("A"), to: path, using: p)
        try await appendUniqueById(card("B"), to: path, using: p)
        try await appendUniqueById(card("A"), to: path, using: p)   // duplicate — no-op
        #expect(try ids(path) == ["A", "B"])
    }

    @Test func recordWithoutId_alwaysAppends() async throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let p = SwiftNativePersistenceCore()

        let noId: JSONValue = .object(["body": .string("x")])
        try await appendUniqueById(noId, to: path, using: p)
        try await appendUniqueById(noId, to: path, using: p)   // nothing to dedup on
        let lines = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }

    @Test func dedupWithinScanWindow() async throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let p = SwiftNativePersistenceCore()

        // With a tiny scan window, the target must still dedup against a row that
        // is within the last `scanLimit` rows.
        try await appendUniqueById(card("keep"), to: path, using: p, scanLimit: 4)
        for i in 0..<2 { try await appendUniqueById(card("n-\(i)"), to: path, using: p, scanLimit: 4) }
        try await appendUniqueById(card("keep"), to: path, using: p, scanLimit: 4)   // within window → no-op
        #expect(try ids(path) == ["keep", "n-0", "n-1"])
    }
}
