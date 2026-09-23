import Foundation
import Testing
@testable import PersistenceCore

/// Mature retained files, rather than empty-file appends, reproduce the disk
/// amplification that made a few hundred new rows rewrite gigabytes.
@Suite
struct DiagnosticJSONLRetentionTests {
    private func feed(_ relativePath: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-retention-\(UUID().uuidString)")
        let path = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return (root, path)
    }

    private func event(_ id: Int, padding: Int = 0) -> JSONValue {
        .object(["id": .int(Int64(id)), "payload": .string(String(repeating: "x", count: padding))])
    }

    private func seed(_ count: Int, padding: Int, at path: URL) throws {
        let rows = try (0..<count).map { try event($0, padding: padding).serialize(pretty: false) }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: path)
    }

    private func fileIdentity(_ path: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func size(_ path: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return try #require(attributes[.size] as? NSNumber).intValue
    }

    @Test func matureTraceAboveSoftTriggerDoesNotRewriteForEveryAppend() async throws {
        let (root, path) = try feed("traces/events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(JSONLLineCaps.traceEvents, padding: 1_200, at: path)
        let persistence = SwiftNativePersistenceCore()
        var identity = try fileIdentity(path)
        var rewrittenBytes = 0
        var rotations = 0
        for id in 0..<1_200 {
            try await appendPathOwnedJSONL(
                event(10_000 + id, padding: 1_200), to: path,
                using: persistence, logLabel: "DiagnosticRetention.trace"
            )
            let nextIdentity = try fileIdentity(path)
            let bytes = try size(path)
            #expect(bytes <= JSONLLineCaps.traceMaximumBytes)
            if identity != nextIdentity {
                rotations += 1
                rewrittenBytes += bytes
                identity = nextIdentity
            }
            if id == 0 {
                // The retained window itself still exceeds the soft trigger.
                // A threshold-only guard would resume rewriting next append.
                #expect(bytes > JSONLLineCaps.traceTrimTriggerBytes)
            }
        }
        #expect(rotations == 2)
        #expect(rewrittenBytes < 12 * 1024 * 1024)
        let rows = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        #expect(rows.count >= JSONLLineCaps.traceTrimTargetLines)
        #expect(rows.count < JSONLLineCaps.traceEvents + JSONLLineCaps.capCheckStride)
        guard case .object(let last) = try JSONValue.parse(Data(try #require(rows.last).utf8)) else {
            Issue.record("latest trace row is not complete JSON")
            return
        }
        #expect(last["id"] == .int(11_199))
    }

    @Test(arguments: ["traces/events.jsonl"])
    func longRowsRotateBelowHardCeilingWithoutRewritingTheNextAppend(_ relativePath: String) async throws {
        let (root, path) = try feed(relativePath)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = try #require(jsonlPathOwnedCapPolicy(for: path))
        let maximum = try #require(policy.maxBytes)
        let target = try #require(policy.trimToBytes)
        try seed(20, padding: 512 * 1024, at: path)
        try await appendPathOwnedJSONL(
            event(21), to: path, using: SwiftNativePersistenceCore(),
            logLabel: "DiagnosticRetention.longRows"
        )
        #expect(try size(path) <= target)
        let identity = try fileIdentity(path)
        for id in 22..<54 {
            try await appendPathOwnedJSONL(
                event(id), to: path, using: SwiftNativePersistenceCore(),
                logLabel: "DiagnosticRetention.longRows"
            )
        }
        #expect(try fileIdentity(path) == identity)
        #expect(try size(path) <= maximum)
        let rows = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        for row in rows { _ = try JSONValue.parse(Data(row.utf8)) }
    }

    @Test func oversizedNewDiagnosticRowIsRejectedWithoutWriting() async throws {
        let (root, path) = try feed("traces/events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(1, padding: 0, at: path)
        let original = try Data(contentsOf: path)
        await #expect(throws: JSONLPathOwnedAppendError.self) {
            try await appendPathOwnedJSONL(
                self.event(2, padding: JSONLLineCaps.traceMaximumBytes), to: path,
                using: SwiftNativePersistenceCore(), logLabel: "DiagnosticRetention.oversized"
            )
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func legacyOversizedDiagnosticRowDoesNotDefeatHardLimit() async throws {
        let (root, path) = try feed("traces/events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(1, padding: JSONLLineCaps.traceMaximumBytes + 1, at: path)
        try await appendPathOwnedJSONL(
            event(2), to: path, using: SwiftNativePersistenceCore(),
            logLabel: "DiagnosticRetention.legacy"
        )
        let rows = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 1)
        #expect(try size(path) <= JSONLLineCaps.traceMaximumBytes)
        #expect(try JSONValue.parse(Data(try #require(rows.last).utf8)) == event(2))
    }

    @Test func malformedEvidenceAtCeilingIsPreservedAndFurtherGrowthRefused() async throws {
        let (root, path) = try feed("traces/events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(repeating: 0xFF, count: JSONLLineCaps.traceMaximumBytes)
        try original.write(to: path)
        await #expect(throws: JSONLPathOwnedAppendError.self) {
            try await appendPathOwnedJSONL(
                self.event(2), to: path, using: SwiftNativePersistenceCore(),
                logLabel: "DiagnosticRetention.malformed"
            )
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func activityLowWaterRotationStillPreservesRareKinds() throws {
        let (root, path) = try feed("activity/events.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        let rare = #"{"kind":"approval","id":0}"#
        let common = #"{"kind":"chat"}"#
        let rows = [rare] + Array(repeating: common, count: 20)
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: path)
        #expect(try enforceActivityEventsLineCap(
            at: path, maxLines: 20, minimumRowsPerKind: 2, trimToLines: 16
        ) == 5)
        let retained = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        #expect(retained.count == 16)
        #expect(retained.first == Substring(rare))
    }

    @Test func byteLowWaterKeepsANewestWholeRowThatStillFitsTheHardLimit() throws {
        let (root, path) = try feed("misc/rows.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        let newest = try event(2, padding: 60).serialize(pretty: false) + "\n"
        let original = try event(1, padding: 60).serialize(pretty: false) + "\n" + newest
        try Data(original.utf8).write(to: path)
        #expect(newest.utf8.count > 60 && newest.utf8.count < 100)
        #expect(try enforceJSONLByteCap(
            at: path, maxBytes: 100, trimToBytes: 60, preserveOversizedNewestRow: false
        ) == 1)
        #expect(try String(contentsOf: path, encoding: .utf8) == newest)
    }

    @Test func defaultByteRetentionStillPreservesOversizedEvidence() throws {
        let (root, path) = try feed("security/audit.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try event(1, padding: 200).serialize(pretty: false) + "\n"
        try Data(original.utf8).write(to: path)
        #expect(try enforceJSONLByteCap(at: path, maxBytes: 100, trimToBytes: 60) == 0)
        #expect(try String(contentsOf: path, encoding: .utf8) == original)
    }
}
