import Foundation
import PersistenceCore
import CryptoKit
import NativeAgentCore
import Darwin
import AuthoredCapabilities
import os
import NativeAgentShared
import Experiences
import Observation
// Blueprint: | `TurnTraceReplayReader.swift` | Persisted trace framing, physical row sizes, stat-stamped replay caching and Doctor scans; terminal matching remains independent of recovery coverage |

public struct TurnTraceReplayReader {
    static let replayCache = TurnTraceReplayCache()

    /// Live and replay share `TurnTracePersistLane.fileURL(for:root:)`'s day-path resolver.
    public static func fileURL(for date: Date, root: URL) -> URL {
        TurnTracePersistLane.fileURL(for: date, root: root)
    }
    public typealias ReadResult = (events: [TurnTraceEvent], report: JSONLReadReport)

    /// Missing files are empty; read failures throw and damaged framing stays in the report.
    public static func read(_ url: URL) async throws -> ReadResult {
        let key = url.resolvingSymlinksInPath().path
        let before = SnapshotTailOpLog.fileStamp(url)
        if let cached = replayCache.lookup(key: key, stamp: before) { return cached }
        let result: ReadResult = before == .absent ? ([], .clean) : try parse(Data(contentsOf: url))
        if let before, before == SnapshotTailOpLog.fileStamp(url) {
            replayCache.store(key: key, stamp: before, result: result)
        }
        return result
    }

    static func parse(_ data: Data) -> ReadResult {
        let read = SwiftNativePersistenceCore.decodeJSONL(data) {
            TurnTraceEvent(persistedJSONRow: $0, physicalByteCount: $1)
        }
        return (read.rows, read.report)
    }

    /// Positive terminal evidence among decoded rows. Recovery callers must
    /// separately validate coverage before concluding a damaged feed is settled.
    static func containsTerminal(forTurn turnId: String, in events: [TurnTraceEvent], status: String? = nil) -> Bool {
        events.contains { event in
            guard event.turnId == turnId, TurnTraceEvent.isTerminalKind(event.kind) else { return false }
            guard let status else { return true }
            guard case .object(let payload) = event.payload else { return false }
            return payload["status"] == .string(status)
        }
    }

    static func tail(_ url: URL, limit: Int, maxBytes: Int) async throws
        -> (events: [TurnTraceEvent], report: JSONLReadReport, bytesRead: Int, truncated: Bool) {
        guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(url, limit: limit, maxBytes: maxBytes)
        else { return ([], .clean, 0, false) }
        let lines = read.lines.dropFirst(read.leadingFragment ? 1 : 0)
        let events = lines.compactMap { line -> TurnTraceEvent? in
            guard String(data: line, encoding: .utf8) != nil, let row = try? JSONValue.parse(line) else { return nil }
            return TurnTraceEvent(persistedJSONRow: row, physicalByteCount: line.count + 1)
        }
        return (events, JSONLReadReport(malformedLineCount: lines.count - events.count, physicalLineCount: lines.count),
                read.bytesRead, read.truncatedToByteWindow)
    }
}

/// Stat-stamped process-wide replay cache; files over 2 MiB are not retained.
final class TurnTraceReplayCache: @unchecked Sendable {
    typealias Result = TurnTraceReplayReader.ReadResult

    static let maximumCacheableBytes: Int64 = 2 * 1_024 * 1_024
    static let maximumEntries = 3

    private struct Entry {
        let stamp: SnapshotTailOpLog.FileStamp
        let result: Result
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func lookup(key: String, stamp: SnapshotTailOpLog.FileStamp?) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let stamp, let entry = entries[key], entry.stamp == stamp else { return nil }
        return entry.result
    }

    func store(key: String, stamp: SnapshotTailOpLog.FileStamp, result: Result) {
        lock.lock()
        defer { lock.unlock() }
        if case .present(_, _, let byteCount, _, _, _, _) = stamp,
           byteCount > Self.maximumCacheableBytes { return }
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maximumEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
        entries[key] = Entry(stamp: stamp, result: result)
    }

}

extension TurnTraceReplayReader {
    /// Validate the retained physical window before applying the Doctor's kind/time policy.
    public static func scan(
        _ path: URL, budget: Int, floor: Date, kinds: Set<String>, handle: (TurnTraceEvent) -> Void
    ) async -> (truncated: Bool, malformedLines: Int, matchedRows: Int)? {
        guard let read = try? await tail(path, limit: Int.max, maxBytes: budget) else { return nil }
        var matchedRows = 0
        for event in read.events where kinds.contains(event.kind) && event.ts >= floor {
            matchedRows += 1
            handle(event)
        }
        return (read.truncated, read.report.malformedLineCount, matchedRows)
    }
}
