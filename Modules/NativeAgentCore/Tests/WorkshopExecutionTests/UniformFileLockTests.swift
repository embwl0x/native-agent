import Testing
import Foundation
import PersistenceCore
@testable import WorkshopExecution

@Suite("uniform file locking — WorkshopExecution")
struct WorkshopExecutionUniformFileLockTests {
    /// The checkpoint store appends through `withLockedWrite`, which used to
    /// downcast and run BARE for a non-SwiftNative conformer — a JSONL row can
    /// span multiple write()s, so an unlocked append tears lines.
    @Test func appendCheckpoint_serializesForNonSwiftNativeConformer() async throws {
        let root = lockProbeTempRoot("workshop")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = LockProbePersistence()
        let store = SwiftNativeWorkshopCheckpointStore(dataRoot: root, persistence: probe)
        let path = store.checkpointsPath(executionId: "exec-1")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    let peer = SwiftNativeWorkshopCheckpointStore(dataRoot: root, persistence: probe)
                    try? await peer.appendCheckpoint(WorkshopCheckpoint(
                        id: "cp-\(i)",
                        executionId: "exec-1",
                        ts: "2026-08-01T00:00:0\(i)Z",
                        phase: "investigating",
                        summary: "checkpoint \(i)"
                    ))
                }
            }
        }

        #expect(
            probe.peakConcurrency(path) == 1,
            "checkpoints.jsonl appends must be mutually exclusive for every conformer"
        )
        let rows = try await store.readCheckpoints(executionId: "exec-1")
        #expect(rows.count == 6)
    }
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
