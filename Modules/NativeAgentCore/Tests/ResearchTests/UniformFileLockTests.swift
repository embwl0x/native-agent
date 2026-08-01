import Testing
import Foundation
import PersistenceCore
@testable import Research

@Suite("uniform file locking — Research")
struct ResearchUniformFileLockTests {
    /// runResearchLab read-modify-writes research/lab/runs.json (read existing,
    /// insert newest-first, cap at 100). The lock used to be skipped entirely for
    /// any conformer that was not SwiftNativePersistenceCore.
    @Test func labRuns_serializeForNonSwiftNativeConformer() async throws {
        let root = lockProbeTempRoot("research")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = LockProbePersistence()
        let labRunsPath = root.appendingPathComponent("research/lab/runs.json")

        func makeClient() -> SwiftNativeResearchClient {
            SwiftNativeResearchClient(
                persistence: probe,
                http: UnreachableHTTPClient(),
                docker: NoDockerExecutor(),
                configPathOverride: root.appendingPathComponent("config/config.json"),
                receiptsDirOverride: root.appendingPathComponent("research"),
                labRunsPathOverride: labRunsPath,
                activityPathOverride: root.appendingPathComponent("activity/events.jsonl"),
                tracesPathOverride: root.appendingPathComponent("traces/events.jsonl")
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    _ = try? await makeClient().runResearchLab(
                        objective: "objective-\(i)", maxResults: 1
                    )
                }
            }
        }

        #expect(
            probe.peakConcurrency(labRunsPath) == 1,
            "lab runs.json read-modify-write must be mutually exclusive for every conformer"
        )
        let raw = await probe.readJSON(labRunsPath, defaultValue: .array([]))
        guard case .array(let rows) = raw else {
            Issue.record("lab runs.json was not an array")
            return
        }
        #expect(rows.count == 6, "an unlocked R-M-W loses concurrent lab runs")
    }
}

/// No network: research falls into its "SearXNG is not configured" branch and
/// still persists the run, which is the path under test.
private struct UnreachableHTTPClient: ResearchHTTPClient {
    func get(url: URL, timeout: TimeInterval) async throws -> (Int, Data, String?) {
        throw ResearchClientError.notConfigured
    }
}

private struct NoDockerExecutor: DockerPSExecutor {
    func runJSONLines() async -> String? { nil }
}

// MARK: - Uniform-locking probe (L7 sweep, 2026-08-01)
//
// `withFileLock` is a PersistenceCoreProtocol EXTENSION
// (PersistenceCore+FileLock.swift:4), so EVERY conformer has it. Call sites used
// to write `if let p = persistence as? SwiftNativePersistenceCore { p.withFileLock… }
// else { work() }` — which silently ran the read-modify-write with NO mutual
// exclusion for any other conformer. These tests pin the fix: a NON-SwiftNative
// conformer must now serialize.
//
// HOW THE PROBE WORKS: the shim widens every persistence call with a real
// suspension and records, PER PATH, the peak number of callers observed inside a
// persistence call on that path at once. When the module's whole R-M-W runs under
// `withFileLock(path)`, a second caller is parked in the flock spin and never
// inside a persistence call — peak is 1. Unlocked, the calls interleave, peak
// exceeds 1, and (for read-modify-write stores) updates are lost.
private final class LockProbePersistence: PersistenceCoreProtocol, @unchecked Sendable {
    private let mutex = NSLock()
    private var inFlight: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private let delay: UInt64

    init(delayNanos: UInt64 = 30_000_000) { self.delay = delayNanos }

    func peakConcurrency(_ path: URL) -> Int {
        mutex.lock(); defer { mutex.unlock() }
        return peak[path.path] ?? 0
    }

    private func begin(_ path: URL) {
        mutex.lock()
        let n = (inFlight[path.path] ?? 0) + 1
        inFlight[path.path] = n
        peak[path.path] = max(peak[path.path] ?? 0, n)
        mutex.unlock()
    }

    private func end(_ path: URL) {
        mutex.lock()
        inFlight[path.path] = (inFlight[path.path] ?? 1) - 1
        mutex.unlock()
    }

    private func stall() async {
        try? await Task.sleep(nanoseconds: delay)
    }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        begin(path); defer { end(path) }
        let data = try? Data(contentsOf: path)
        await stall()
        guard let data, let parsed = try? JSONValue.parse(data) else { return defaultValue }
        return parsed
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        begin(path); defer { end(path) }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(try value.serialize(pretty: false).utf8)
        await stall()
        try payload.write(to: path, options: .atomic)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        begin(path); defer { end(path) }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((try record.serialize(pretty: false) + "\n").utf8)
        await stall()
        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: path, options: .atomic)
        }
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        Array(try await readJSONL(path).suffix(limit))
    }

    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        begin(path); defer { end(path) }
        let text = try? String(contentsOf: path, encoding: .utf8)
        await stall()
        guard let text else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }
}

private func lockProbeTempRoot(_ tag: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("uniformlock-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
