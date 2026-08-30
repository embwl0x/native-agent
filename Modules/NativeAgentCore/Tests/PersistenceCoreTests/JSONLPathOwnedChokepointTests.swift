import Testing
import Foundation
@testable import PersistenceCore

// MARK: - F2 (2026-08-28): cap-by-path chokepoint
//
// The path-owned cap registry existed before this suite, but it was opt-in AT
// THE CALL SITE: a writer that reached for `appendJSONL` directly grew a
// co-written feed forever and nothing said so. These tests pin the invariant in
// both directions — the registry is authoritative for a registered path, and a
// raw append to one is impossible through the public persistence API.

@Suite("JSONL path-owned cap chokepoint")
struct JSONLPathOwnedChokepointTests {
    private func makeRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pathowned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tracesPath(_ root: URL) -> URL {
        root.appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private func harnessRunsPath(_ root: URL) -> URL {
        root.appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("benchmark", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
    }

    private func lineCount(_ path: URL) throws -> Int {
        let text = try String(contentsOf: path, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func row(_ i: Int) -> JSONValue {
        .object(["i": .int(Int64(i)), "kind": .string("test.row")])
    }

    // MARK: registry contents

    @Test func registryCoversTheCoWrittenFeeds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(jsonlPathOwnedCapPolicy(for: tracesPath(root))?.maxLines
                == JSONLLineCaps.traceEvents)
        #expect(jsonlPathOwnedCapPolicy(for: root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl"))?.maxLines
                == JSONLLineCaps.activityEvents)
        #expect(jsonlPathOwnedCapPolicy(for: harnessRunsPath(root))?.maxLines
                == JSONLLineCaps.harnessBenchmarkRuns)
        // A same-named file in an unrelated directory is NOT swept up.
        #expect(jsonlPathOwnedCapPolicy(
            for: root.appendingPathComponent("events.jsonl")) == nil)
    }

    // MARK: the cap actually runs

    @Test func registeredPathIsTrimmedToItsOwnedCap() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = harnessRunsPath(root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Seed one line OVER the owned cap without going through the append
        // path, then let a single capped append trip the trim.
        let seeded = (0..<(JSONLLineCaps.harnessBenchmarkRuns + 1))
            .map { #"{"i":\#($0)}"# }
            .joined(separator: "\n") + "\n"
        try Data(seeded.utf8).write(to: path)

        try await appendPathOwnedJSONL(
            row(9_999), to: path,
            using: SwiftNativePersistenceCore(),
            logLabel: "test.harness"
        )

        #expect(try lineCount(path) == JSONLLineCaps.harnessBenchmarkRuns)
        // The newest row survived the trim; the oldest did not.
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.hasSuffix("\"i\":9999,\"kind\":\"test.row\"}\n")
                || text.contains("9999"))
        #expect(!text.contains(#"{"i":0}"#))
    }

    /// The table outranks whatever budget a call site remembered. A writer that
    /// reaches `appendJSONLCapped` directly with a stale local constant gets the
    /// FILE's policy, not its own.
    @Test func callSiteCapCannotUndercutThePathOwnedPolicy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The harness feed, not traces: its policy carries no byte trigger, so
        // a trim WOULD fire here if the call site's budget were honored. (On a
        // trigger-gated feed this assertion would pass vacuously.)
        let path = harnessRunsPath(root)

        for i in 0..<5 {
            try await appendJSONLCapped(
                row(i), to: path,
                using: SwiftNativePersistenceCore(),
                maxLines: 1,                    // bogus local budget
                logLabel: "test.traces"
            )
        }

        // With `maxLines: 1` honored this file would hold one line.
        #expect(try lineCount(path) == 5)
    }

    // MARK: bypass is impossible

    @Test func rawAppendToARegisteredPathThrows() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftNativePersistenceCore()

        for path in [tracesPath(root),
                     harnessRunsPath(root),
                     root.appendingPathComponent("activity", isDirectory: true)
                         .appendingPathComponent("events.jsonl")] {
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendJSONL(self.row(1), to: path)
            }
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendJSONL([self.row(1)], to: path)
            }
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendJSONLDurable(self.row(1), to: path)
            }
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendJSONLDurable([self.row(1)], to: path)
            }
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendAuditLine(self.row(1), to: path)
            }
            await #expect(throws: JSONLPathOwnedAppendError.self) {
                try await core.appendAuditLineRaw(#"{"i":1}"#, to: path)
            }
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    @Test func unregisteredPathsKeepTheRawAppendPath() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("receipts.jsonl")

        try await SwiftNativePersistenceCore().appendJSONL(row(1), to: path)
        #expect(try lineCount(path) == 1)
    }

    /// The permit is scoped to the capped append and must not leak to a later
    /// raw write on the same task.
    @Test func permitDoesNotOutliveTheCappedAppend() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = tracesPath(root)
        let core = SwiftNativePersistenceCore()

        try await appendPathOwnedJSONL(
            row(1), to: path, using: core, logLabel: "test.traces"
        )
        #expect(try lineCount(path) == 1)

        await #expect(throws: JSONLPathOwnedAppendError.self) {
            try await core.appendJSONL(self.row(2), to: path)
        }
        #expect(try lineCount(path) == 1)
    }
}
