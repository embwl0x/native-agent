import Synchronization
import Foundation
import Darwin
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `JSONLRetention.swift` | Path-owned envelope, capped append and retention cadence. |

// MARK: - JSONL retention

/// Process-local counters check each path on its first append so inherited over-cap files are trimmed.
final class JSONLCapCheckCounter: Sendable {
    static let shared = JSONLCapCheckCounter()
    private let counts = Mutex<[String: Int]>([:])

    /// Bound tracked paths because per-session/run feeds are unbounded; forgetting counts only adds safe cap evaluations.
    private static let maximumTrackedPaths = 4096

    func recordAppend(path: URL) {
        let key = path.standardizedFileURL.path
        counts.withLock { counts in
            if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
                counts.removeAll(keepingCapacity: true)
            }
            counts[key, default: 0] += 1
        }
    }

    /// Preview without spending a stride; the caller's file lock prevents intervening appends before consumption.
    func isFullCheckDueOnNextAppend(path: URL) -> Bool {
        let key = path.standardizedFileURL.path
        return counts.withLock { counts in
            if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
                return true
            }
            let next = (counts[key] ?? 0) + 1
            return next % JSONLLineCaps.capCheckStride == 1
        }
    }
}

/// One selection of original rows; nil dropped rows mean unreadable UTF-8.
private func selectJSONLRetention(
    at path: URL,
    maxLines: Int? = nil,
    minimumRowsPerKind: Int? = nil,
    trimToLines: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    data checkedData: Data? = nil
) throws -> (retained: Data?, dropped: [Substring]?) {
    guard (maxLines ?? 0) > 0 || (maxBytes ?? 0) > 0 else { return (nil, []) }
    guard checkedData != nil || FileManager.default.fileExists(atPath: path.path) else { return (nil, []) }
    let size = checkedData?.count ?? ((try? FileManager.default.attributesOfItem(
        atPath: path.path
    ))?[.size] as? NSNumber)?.intValue
    let checkLines = maxLines.map { limit in
        limit > 0 && size.map { $0 >= limit } != false
    } ?? false
    let byteTarget = trimToBytes ?? maxBytes ?? 0
    let checkBytes = maxBytes.map { limit in
        limit > 0 && byteTarget > 0 && byteTarget <= limit && size.map { $0 > limit } != false
    } ?? false
    guard checkLines || checkBytes else { return (nil, []) }
    let data = try checkedData ?? Data(contentsOf: path)
    guard let text = String(data: data, encoding: .utf8) else {
        nativeLog("enforceJSONLRetention: %@ is not valid UTF-8 (%d bytes) — cap skipped",
                  path.path, data.count)
        return (nil, nil)
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    let original = lines
    let originalCount = lines.count
    var selected = Array(lines.indices)
    if checkLines, let maxLines, lines.count > maxLines {
        let retainedLines = min(maxLines, max(1, trimToLines ?? maxLines))
        var reserved = Set<Int>()
        if let minimumRowsPerKind, minimumRowsPerKind > 0 {
            var retainedPerKind: [String: Int] = [:]
            for index in lines.indices.reversed() {
                guard let row = try? JSONValue.parse(Data(lines[index].utf8)),
                      case .object(let object) = row,
                      case .string(let rawKind)? = object["kind"] else { continue }
                let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kind.isEmpty, retainedPerKind[kind, default: 0] < minimumRowsPerKind else { continue }
                reserved.insert(index)
                retainedPerKind[kind, default: 0] += 1
            }
        }
        var kept = Set(lines.indices.suffix(retainedLines))
        kept.formUnion(reserved)
        let oldestFirst = kept.sorted()
        let removalOrder = oldestFirst.filter { !reserved.contains($0) }
            + oldestFirst.filter { reserved.contains($0) }
        for index in removalOrder.prefix(max(0, kept.count - retainedLines)) { kept.remove(index) }
        selected = kept.sorted()
        lines = selected.map { original[$0] }
    }
    // A line trim normalizes the trailing separator before the byte selection.
    let selectedBytes = lines.count < originalCount
        ? lines.reduce(0) { $0 + $1.utf8.count + 1 } : data.count
    if checkBytes, let maxBytes, selectedBytes > maxBytes {
        var keptReversed: [Int] = []
        var keptBytes = 0
        for index in selected.reversed() {
            let line = original[index]
            let lineBytes = line.utf8.count + 1
            if !keptReversed.isEmpty, keptBytes + lineBytes > byteTarget { break }
            // Evidence retains its newest whole row even above the target.
            keptReversed.append(index)
            keptBytes += lineBytes
            if keptBytes >= byteTarget { break }
        }
        selected = Array(keptReversed.reversed())
        lines = selected.map { original[$0] }
    }
    let dropped = originalCount - lines.count
    guard dropped > 0 else { return (nil, []) }
    let retained = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    let kept = Set(selected)
    return (Data(retained.utf8), original.indices.filter { !kept.contains($0) }.map { original[$0] })
}

/// Producers retain original redacted evidence; FeedPolicy owns retention and this owner enforces it.
extension SwiftNativePersistenceCore {
    public static func activityEventsPath(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("activity/events.jsonl")
    }

    public static func activityEvent(
        id: String, kind: String, title: String, detail: String, status: String,
        executionId: String?, payload: JSONValue, createdAt: String
    ) -> JSONValue {
        .object([
            "id": .string(id), "kind": .string(kind), "title": .string(title),
            "detail": .string(detail), "status": .string(status),
            "executionId": executionId.map(JSONValue.string) ?? .null,
            "payload": payload, "createdAt": .string(createdAt),
        ])
    }

    public static func appendActivityEvent(
        _ event: JSONValue, to path: URL, logLabel: String
    ) async throws {
        try await appendJSONLCapped(event, to: path, logLabel: logLabel)
    }
}

@concurrent public func appendJSONLCapped(
    _ event: JSONValue,
    to path: URL,
    maxLines: Int = JSONLLineCaps.activityEvents,
    logLabel: String,
    trimWhenBytesExceed: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    // Confirm append durability before retention when this feed is a record of truth.
    durable: Bool = false,
    beforePotentialLineCap: (@Sendable ([Substring]?) async throws -> Void)? = nil
) async throws {
    // Path-owned retention overrides caller budgets; mismatches are logged.
    let policy = jsonlPathOwnedCapPolicy(for: path)
    if let policy, policy.maxLines != maxLines {
        nativeLog("%@: %@ has a path-owned cap of %d line(s) — ignoring the call site's %d",
              logLabel, path.lastPathComponent, policy.maxLines, maxLines)
    }
    let effectiveMaxLines = policy?.maxLines ?? maxLines
    let effectiveTrimTrigger = policy?.trimWhenBytesExceed ?? trimWhenBytesExceed
    let effectiveMaxBytes = policy?.maxBytes ?? maxBytes
    let effectiveTrimToBytes = policy?.trimToBytes ?? trimToBytes ?? effectiveMaxBytes
    let payload = try SwiftNativePersistenceCore.serializeJSONL([event])
    try await SwiftNativePersistenceCore.withFileLock(path) {
        var selection: (retained: Data?, dropped: [Substring]?)?
        // Archive selected original rows at the same checkpoints that enforce retention.
        let fullCheckWillBeDue = JSONLCapCheckCounter.shared.isFullCheckDueOnNextAppend(path: path)
        // Soft triggers count at bounded stride checkpoints; hard byte ceilings are checked on every append.
        let shouldCheckLines = fullCheckWillBeDue || effectiveTrimTrigger == nil
        if let beforePotentialLineCap {
            let reachesByteCeiling: Bool
            if let effectiveMaxBytes {
                let currentBytes = ((try? FileManager.default.attributesOfItem(
                    atPath: path.path
                ))?[.size] as? NSNumber)?.intValue
                reachesByteCeiling = currentBytes == nil
                    || currentBytes! + payload.count > effectiveMaxBytes
            } else {
                reachesByteCeiling = false
            }
            if shouldCheckLines || reachesByteCeiling {
                var prospective = try FileManager.default.fileExists(atPath: path.path)
                    ? Data(contentsOf: path) : Data()
                if !prospective.isEmpty, prospective.last != 0x0A { prospective.append(0x0A) }
                prospective.append(payload)
                selection = try selectJSONLRetention(
                    at: path, maxLines: shouldCheckLines ? effectiveMaxLines : nil,
                    minimumRowsPerKind: policy?.minimumRowsPerKind, trimToLines: policy?.trimToLines,
                    maxBytes: effectiveMaxBytes, trimToBytes: effectiveTrimToBytes, data: prospective)
                try await beforePotentialLineCap(selection!.dropped)
            }
        }
        try JSONLPathOwnedAppendPermit.$isInsideCappedAppend.withValue(true) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.appendOwnedBytes(payload, to: path, durable: durable)
            _ = chmod(path.path, 0o600)
        }
        // Spend checkpoints only after append succeeds under the preview's lock; full checkpoints ignore byte triggers.
        JSONLCapCheckCounter.shared.recordAppend(path: path)
        let selected = try selection ?? selectJSONLRetention(
            at: path, maxLines: shouldCheckLines ? effectiveMaxLines : nil,
            minimumRowsPerKind: policy?.minimumRowsPerKind, trimToLines: policy?.trimToLines,
            maxBytes: effectiveMaxBytes,
            trimToBytes: effectiveTrimToBytes)
        if let retained = selected.retained {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(retained, to: path)
        }
        let dropped = selected.dropped?.count ?? 0
        if dropped > 0 {
            nativeLog("%@: %@ cap dropped %d oldest line(s)",
                  logLabel, path.lastPathComponent, dropped)
        }
    }
}

public enum JSONLPathOwnedAppendError: Error, Equatable {
    case unregisteredPath(String)
    /// Refuse uncapped writes so callers cannot bypass path-owned retention.
    case rawAppendToPathOwnedFeed(String)
}

/// Task-local permission confines raw appends to the capped owner without leaking authority across concurrent appends.
enum JSONLPathOwnedAppendPermit {
    @TaskLocal static var isInsideCappedAppend: Bool = false
}

/// Reject unregistered paths so typos and new writers cannot bypass retention; same-path reentry preserves transactions.
public func appendPathOwnedJSONL(
    _ event: JSONValue,
    to path: URL,
    logLabel: String,
    durable: Bool = false,
    // Owners may refuse the append when pre-trim evidence cannot be preserved.
    beforePotentialLineCap: (@Sendable ([Substring]?) async throws -> Void)? = nil
) async throws {
    guard let policy = jsonlPathOwnedCapPolicy(for: path) else {
        throw JSONLPathOwnedAppendError.unregisteredPath(path.standardizedFileURL.path)
    }
    try await appendJSONLCapped(
        event,
        to: path,
        maxLines: policy.maxLines,
        logLabel: logLabel,
        trimWhenBytesExceed: policy.trimWhenBytesExceed,
        durable: durable,
        beforePotentialLineCap: beforePotentialLineCap
    )
}
