import Testing
import Foundation
@testable import PersistenceCore

// MARK: - U5 W-G (2026-06-11): enforceJSONLLineCap

@Suite("enforceJSONLLineCap")
struct JSONLLineCapTests {
    private func tmpFile() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jsonlcap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }

    @Test func underCap_isNoOp() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let lines = (0..<10).map { #"{"i":\#($0)}"# }.joined(separator: "\n") + "\n"
        try lines.write(to: path, atomically: true, encoding: .utf8)
        let dropped = try enforceJSONLLineCap(at: path, maxLines: 100)
        #expect(dropped == 0)
        #expect(try String(contentsOf: path, encoding: .utf8) == lines, "under-cap file must be untouched")
    }

    @Test func overCap_keepsNewestLines_reportsDropCount() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let all = (0..<25).map { #"{"i":\#($0)}"# }
        try (all.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let dropped = try enforceJSONLLineCap(at: path, maxLines: 10)
        #expect(dropped == 15, "drop count must be reported, not silent")
        let kept = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(kept.count == 10)
        #expect(kept.first == #"{"i":15}"#, "oldest survivors must be the newest 10")
        #expect(kept.last == #"{"i":24}"#)
        // The fixed-path tmp sibling must not linger.
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathExtension("captmp").path))
    }

    @Test func missingFile_isNoOp() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let dropped = try enforceJSONLLineCap(at: path, maxLines: 10)
        #expect(dropped == 0)
    }

    // MARK: - H3/M6 (2026-07-09): stat-first early-outs

    /// The byte-size early-out (`size < maxLines` ⇒ at most `maxLines` lines) is
    /// a LOWER BOUND, not a heuristic. Prove it does not skip a real trim on the
    /// densest possible input: one-byte lines (bare newlines).
    @Test func sizeEarlyOut_stillTrims_whenLinesAreOneByteEach() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        // 40 empty lines = 40 bytes; maxLines 10 ⇒ size(40) >= 10, no early-out.
        try String(repeating: "\n", count: 40).write(to: path, atomically: true, encoding: .utf8)
        let dropped = try enforceJSONLLineCap(at: path, maxLines: 10)
        #expect(dropped == 30)
    }

    /// A file whose byte size is below `maxLines` cannot hold more than
    /// `maxLines` lines, so the cap must early-out without reading it.
    @Test func sizeEarlyOut_isNoOp_whenFileSmallerThanCap() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let lines = (0..<5).map { #"{"i":\#($0)}"# }.joined(separator: "\n") + "\n"
        try lines.write(to: path, atomically: true, encoding: .utf8)
        let dropped = try enforceJSONLLineCap(at: path, maxLines: 10_000)
        #expect(dropped == 0)
        #expect(try String(contentsOf: path, encoding: .utf8) == lines)
    }

    /// `trimWhenBytesExceed` is the amortization that keeps the turn-trace append
    /// off a full-file read on every row: under the trigger the line count is
    /// never taken, even when the file is over its line cap.
    @Test func byteTrigger_skipsTrim_belowThreshold_andTrimsAbove() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let all = (0..<25).map { #"{"i":\#($0)}"# }
        let contents = all.joined(separator: "\n") + "\n"
        try contents.write(to: path, atomically: true, encoding: .utf8)

        // Over the LINE cap, but under the byte trigger: deliberately untouched.
        let skipped = try enforceJSONLLineCap(at: path, maxLines: 10, trimWhenBytesExceed: 1_000_000)
        #expect(skipped == 0)
        #expect(try String(contentsOf: path, encoding: .utf8) == contents)

        // Once the file crosses the trigger, the line cap is enforced as usual.
        let trimmed = try enforceJSONLLineCap(at: path, maxLines: 10, trimWhenBytesExceed: 8)
        #expect(trimmed == 15)
        let kept = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(kept.count == 10)
        #expect(kept.last == #"{"i":24}"#)
    }

    @Test func hardByteCapKeepsNewestWholeRowsWithHysteresis() throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let rows = (0..<20).map {
            #"{"i":\#($0),"payload":"\#(String(repeating: "x", count: 40))"}"#
        }
        try (rows.joined(separator: "\n") + "\n")
            .write(to: path, atomically: true, encoding: .utf8)

        let dropped = try enforceJSONLByteCap(
            at: path,
            maxBytes: 500,
            trimToBytes: 320
        )
        #expect(dropped > 0)
        let data = try Data(contentsOf: path)
        #expect(data.count <= 320)
        let kept = try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONValue.parse(Data($0.utf8)) }
        #expect(!kept.isEmpty)
        guard case .object(let newest)? = kept.last else {
            Issue.record("newest row missing")
            return
        }
        #expect(newest["i"] == .int(19))
        #expect(!FileManager.default.fileExists(
            atPath: path.appendingPathExtension("bytecaptmp").path
        ))
    }

    @Test func securityAuditTriggerKeepsAppendWorkBoundedBeforeRotation() {
        #expect(JSONLLineCaps.securityAudit > 0)
        #expect(JSONLLineCaps.securityAuditTrimTriggerBytes > JSONLLineCaps.securityAudit)
        #expect(JSONLLineCaps.securityAuditTrimTriggerBytes == 32 * 1024 * 1024)
    }

    @Test func concurrentCappedAppendsSerializeThroughRotation() async throws {
        let path = tmpFile()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let persistence = SwiftNativePersistenceCore()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<20 {
                group.addTask {
                    try await appendJSONLCapped(
                        .object(["id": .int(Int64(id))]),
                        to: path,
                        using: persistence,
                        maxLines: 10,
                        logLabel: "JSONLLineCapTests.concurrent",
                        trimWhenBytesExceed: 1
                    )
                }
            }
            try await group.waitForAll()
        }

        let lines = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 10)
        var ids = Set<Int64>()
        for line in lines {
            let value = try JSONValue.parse(Data(line.utf8))
            guard case .object(let object) = value,
                  case .int(let id) = object["id"] else {
                Issue.record("rotated row was not a complete id object")
                continue
            }
            ids.insert(id)
        }
        #expect(ids.count == 10, "concurrent append+rotation must retain ten distinct complete rows")
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathExtension("captmp").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((perms & 0o777) == 0o600)
    }

    /// These two historically bypassed the shared activity owner and performed
    /// a full-file line count after every append. Keep the ownership boundary
    /// explicit so a future parity edit cannot silently restore O(file) work.
    @Test func connectorAndResearchActivityWriters_useSharedAmortizedOwner() throws {
        let moduleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/Connectors/Connectors.swift",
            "Sources/Research/Research+ActivityTrace.swift",
        ]
        for relativePath in relativePaths {
            let source = try String(
                contentsOf: moduleRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(source.contains("appendJSONLCapped("), "\(relativePath) must use the shared owner")
            #expect(
                !source.contains("enforceJSONLLineCap("),
                "\(relativePath) must not perform an exact full-feed scan per append"
            )
        }
    }
}
