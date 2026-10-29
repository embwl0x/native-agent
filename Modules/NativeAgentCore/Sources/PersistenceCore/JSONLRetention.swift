import Foundation
import Darwin
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `JSONLRetention.swift` | SwiftNativePersistenceCore owns the activity event envelope, path and append; producers preserve redacted values, IDs and timestamps; JSONLCapCheckCounter owns cap-check cadence |

// MARK: - JSONL retention

/// Per-path append counter driving `JSONLLineCaps.capCheckStride`. Process-local
/// and deliberately not persisted: a fresh process checks on its first append to
/// each path, which is exactly when an inherited over-cap file needs trimming.
final class JSONLCapCheckCounter: @unchecked Sendable {
    static let shared = JSONLCapCheckCounter()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// True when this append should evaluate the line cap in full (ignoring any
    /// byte trigger). Fires on the 1st, (stride+1)th, … append to `path`.
    /// Bound on distinct tracked paths. The production feed set is a couple of
    /// dozen fixed paths, but `appendJSONLCapped` also serves per-session and
    /// per-run files, so an unbounded map would creep in a long-lived process.
    /// Overflowing simply forgets the counts — the only cost is one extra full
    /// cap evaluation per path afterwards, which is the SAFE direction.
    private static let maximumTrackedPaths = 4096

    func isFullCheckDue(path: URL, stride: Int) -> Bool {
        guard stride > 1 else { return true }
        let key = path.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
            counts.removeAll(keepingCapacity: true)
        }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next % stride == 1
    }

    /// Read-only preview used by pre-trim evidence owners. The caller holds
    /// the path's file lock, so no same-path capped append can advance between
    /// this preview and the later consuming `isFullCheckDue` call. Keeping the
    /// preview non-mutating also means a failed append does not spend a stride.
    func isFullCheckDueOnNextAppend(path: URL, stride: Int) -> Bool {
        guard stride > 1 else { return true }
        let key = path.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
            return true
        }
        let next = (counts[key] ?? 0) + 1
        return next % stride == 1
    }
}

/// Select line retention, then byte retention, and durably publish once.
/// The caller holds the feed's lock. Checked append bytes may be carried in
/// to avoid rereading a diagnostic feed admitted before its append.
@discardableResult
public func enforceJSONLRetention(
    at path: URL,
    maxLines: Int? = nil,
    minimumRowsPerKind: Int? = nil,
    trimWhenBytesExceed: Int? = nil,
    trimToLines: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    preserveOversizedNewestRow: Bool = true,
    data checkedData: Data? = nil
) throws -> Int {
    let selection = try selectJSONLRetention(
        at: path, maxLines: maxLines, minimumRowsPerKind: minimumRowsPerKind,
        trimWhenBytesExceed: trimWhenBytesExceed, trimToLines: trimToLines,
        maxBytes: maxBytes, trimToBytes: trimToBytes,
        preserveOversizedNewestRow: preserveOversizedNewestRow, data: checkedData)
    if let retained = selection.retained {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(retained, to: path)
    }
    return selection.dropped?.count ?? 0
}

/// One selection of original rows; nil dropped rows mean unreadable UTF-8.
private func selectJSONLRetention(
    at path: URL,
    maxLines: Int? = nil,
    minimumRowsPerKind: Int? = nil,
    trimWhenBytesExceed: Int? = nil,
    trimToLines: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    preserveOversizedNewestRow: Bool = true,
    data checkedData: Data? = nil
) throws -> (retained: Data?, dropped: [Substring]?) {
    guard (maxLines ?? 0) > 0 || (maxBytes ?? 0) > 0 else { return (nil, []) }
    guard checkedData != nil || FileManager.default.fileExists(atPath: path.path) else { return (nil, []) }
    let size = checkedData?.count ?? ((try? FileManager.default.attributesOfItem(
        atPath: path.path
    ))?[.size] as? NSNumber)?.intValue
    let checkLines = maxLines.map { limit in
        limit > 0 && size.map { $0 >= limit && $0 >= (trimWhenBytesExceed ?? 0) } != false
    } ?? false
    let byteTarget = trimToBytes ?? maxBytes ?? 0
    let checkBytes = maxBytes.map { limit in
        limit > 0 && byteTarget > 0 && byteTarget <= limit && size.map { $0 > limit } != false
    } ?? false
    guard checkLines || checkBytes else { return (nil, []) }
    let data = try checkedData ?? Data(contentsOf: path)
    guard let text = String(data: data, encoding: .utf8) else {
        if checkBytes, let maxBytes, data.count > maxBytes, !preserveOversizedNewestRow {
            throw JSONLPathOwnedAppendError.unreadableDiagnosticFeed(path.standardizedFileURL.path)
        }
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
            // Disposable diagnostics may drop inherited rows above the hard cap.
            if !preserveOversizedNewestRow, lineBytes > maxBytes { continue }
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

/// Owns activity/events.jsonl: the event envelope, path and capped append.
/// Producers supply their original redacted values, IDs and timestamps.
/// Local backup/export and phone sync exclude it; off-disk backup and support
/// bundles include it; PrivacyMap lists activity/. FeedPolicy.swift owns retention beside this enforcement.
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

/// Appends `event` to `path`, then trims the file
/// to its newest `maxLines` lines, logging what the rotation dropped. Every
/// live `activity/events.jsonl` writer routes through here to bound the feed.
///
/// Append and retention share `withFileLock(path)`, reusing a held same-path
/// lock. Only a compound transaction protected by a different path bypasses it.
public func appendJSONLCapped(
    _ event: JSONValue,
    to path: URL,
    maxLines: Int = JSONLLineCaps.activityEvents,
    logLabel: String,
    takeLock: Bool = true,
    trimWhenBytesExceed: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    capCheckStride: Int = JSONLLineCaps.capCheckStride,
    // Validated by the caller under the same file lock as this append.
    validatedExistingCounts: (lines: Int, bytes: Int)? = nil,
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
    let diagnosticByteBound = policy?.maxBytes != nil
    let payload = try SwiftNativePersistenceCore.serializeJSONL([event])
    let diagnosticAppendBytes: Int? = diagnosticByteBound ? payload.count : nil
    // Reject rather than truncate a new diagnostic record that cannot fit in
    // its file's hard budget. Audit/authoritative callers do not inherit this.
    if diagnosticByteBound, let effectiveMaxBytes {
        guard payload.count <= effectiveMaxBytes else {
            throw JSONLPathOwnedAppendError.recordExceedsByteLimit(
                path.standardizedFileURL.path, payload.count, effectiveMaxBytes
            )
        }
    }
    let work: @Sendable () async throws -> Void = {
        var checkedData: Data?
        var selection: (retained: Data?, dropped: [Substring]?)?
        // Do not keep growing an inherited malformed diagnostic feed merely
        // because retention cannot decode it. Preserve the evidence and refuse
        // this append before it crosses the ceiling; no quarantine copy can
        // itself become an unbounded second ledger.
        if let diagnosticAppendBytes, let effectiveMaxBytes,
           FileManager.default.fileExists(atPath: path.path) {
            let currentBytes = ((try? FileManager.default.attributesOfItem(
                atPath: path.path
            ))?[.size] as? NSNumber)?.intValue
            if currentBytes == nil || currentBytes! > effectiveMaxBytes - diagnosticAppendBytes {
                let data = try Data(contentsOf: path)
                guard String(data: data, encoding: .utf8) != nil else {
                    throw JSONLPathOwnedAppendError.unreadableDiagnosticFeed(path.standardizedFileURL.path)
                }
                checkedData = data
            }
        }
        // Archive selected original rows at the same checkpoints that enforce retention.
        let fullCheckWillBeDue = JSONLCapCheckCounter.shared.isFullCheckDueOnNextAppend(
            path: path, stride: capCheckStride
        )
        // Soft triggers count at bounded stride checkpoints; hard byte ceilings
        // are checked on every append.
        let shouldCheckLines = validatedExistingCounts.map { $0.lines + 1 > effectiveMaxLines }
            ?? (fullCheckWillBeDue || effectiveTrimTrigger == nil)
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
                var prospective = try checkedData ?? (FileManager.default.fileExists(atPath: path.path)
                    ? Data(contentsOf: path) : Data())
                if !prospective.isEmpty, prospective.last != 0x0A { prospective.append(0x0A) }
                prospective.append(payload)
                selection = try selectJSONLRetention(
                    at: path, maxLines: shouldCheckLines ? effectiveMaxLines : nil,
                    minimumRowsPerKind: policy?.minimumRowsPerKind, trimToLines: policy?.trimToLines,
                    maxBytes: effectiveMaxBytes, trimToBytes: effectiveTrimToBytes,
                    preserveOversizedNewestRow: !diagnosticByteBound, data: prospective)
                try await beforePotentialLineCap(selection!.dropped)
            }
        }
        try JSONLPathOwnedAppendPermit.$isInsideCappedAppend.withValue(true) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwiftNativePersistenceCore.appendOwnedBytes(payload, to: path, durable: durable)
            _ = chmod(path.path, 0o600)
        }
        if checkedData != nil {
            if !checkedData!.isEmpty, checkedData!.last != 0x0A { checkedData!.append(0x0A) }
            checkedData!.append(payload)
        }
        // Spend the checkpoint only after a successful append. The caller's
        // file lock keeps the earlier evidence-hook preview and this decision
        // together. Full checkpoints always evaluate rows, regardless of size.
        _ = JSONLCapCheckCounter.shared.isFullCheckDue(
            path: path, stride: capCheckStride
        )
        let checkBytes = validatedExistingCounts.map {
            $0.bytes + payload.count > (effectiveMaxBytes ?? Int.max)
        } ?? true
        let selected = try selection ?? selectJSONLRetention(
            at: path, maxLines: shouldCheckLines ? effectiveMaxLines : nil,
            minimumRowsPerKind: policy?.minimumRowsPerKind, trimToLines: policy?.trimToLines,
            maxBytes: checkBytes ? effectiveMaxBytes : nil,
            trimToBytes: effectiveTrimToBytes,
            preserveOversizedNewestRow: !diagnosticByteBound, data: checkedData)
        if let retained = selected.retained {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(retained, to: path)
        }
        let dropped = selected.dropped?.count ?? 0
        if dropped > 0 {
            nativeLog("%@: %@ cap dropped %d oldest line(s)",
                  logLabel, path.lastPathComponent, dropped)
        }
    }
    if takeLock {
        // Append and cap share the feed lock; acquisition failure throws.
        try await SwiftNativePersistenceCore.withFileLock(path, work)
    } else {
        // Caller holds the compound transaction's different-path lock.
        try await work()
    }
}

public enum JSONLPathOwnedAppendError: Error, Equatable {
    case unregisteredPath(String)
    case recordExceedsByteLimit(String, Int, Int)
    case unreadableDiagnosticFeed(String)
    /// The shared byte writer refuses uncapped appends to path-owned feeds.
    case rawAppendToPathOwnedFeed(String)
}

/// Permit for the sanctioned capped-append route. Set ONLY by
/// `appendJSONLCapped` around the inner raw append; read by
/// `SwiftNativePersistenceCore.appendBytes`. Task-local rather than a flag on
/// the type so it cannot leak across concurrent appends.
enum JSONLPathOwnedAppendPermit {
    @TaskLocal static var isInsideCappedAppend: Bool = false
}

/// Append through the path-owned cap registry. An unregistered path fails loud
/// so a typo or newly introduced writer cannot silently bypass retention.
/// Same-path lock reentry keeps an enclosing feed transaction intact.
public func appendPathOwnedJSONL(
    _ event: JSONValue,
    to path: URL,
    logLabel: String,
    durable: Bool = false,
    // Passthrough to `appendJSONLCapped`'s pre-trim hook, for the owners whose
    // feed must not lose a row to a trim. It throws to STOP the append.
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
