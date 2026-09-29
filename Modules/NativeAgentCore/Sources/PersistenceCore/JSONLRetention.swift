import FeedPolicy
import Foundation
import Darwin
import NativeAgentCore

// MARK: - JSONL line cap (U5 W-G, 2026-06-11)

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

    /// Test seam: forget the per-path history so a fresh temp path starts at 1.
    func _testReset() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll()
    }
}

/// Trim a JSONL file to its newest `maxLines` lines. Returns the number of
/// lines dropped (0 when under the cap or the file is missing). The CALLER
/// must hold the file's flock — this helper is the trim step of an
/// append-then-cap sequence and does no locking of its own (mirrors the
/// notification-inbox 1000-line recipe). Never silent: callers log the
/// returned drop count.
///
/// H3/M6 (2026-07-09): the size check happens FIRST. This helper used to read
/// the entire file into memory on every append just to discover it was under the
/// cap — quadratic on an append-only feed, and it did that read while holding the
/// feed's flock on the chat turn path (a 20k-line trace file meant ~18MB read per
/// appended row). Two cheap `stat`-based early-outs now short-circuit it:
///   - `trimWhenBytesExceed`: an optional soft trigger. Below it the cap is not
///     evaluated at all. It is NOT a byte cap: retained rows can remain above
///     the trigger. Shared appends amortize calls separately. Callers that
///     need the exact newest-`maxLines` invariant after EVERY append omit it.
///   - an exact lower bound: a file of `n` bytes holds at most `n` lines (every
///     line but the last carries a newline), so `size < maxLines` cannot be over
///     the cap. Sound for every caller, no semantic change.
@discardableResult
public func enforceJSONLLineCap(
    at path: URL,
    maxLines: Int,
    trimWhenBytesExceed: Int? = nil,
    trimToLines: Int? = nil
) throws -> Int {
    guard maxLines > 0, FileManager.default.fileExists(atPath: path.path) else { return 0 }
    // An unstattable-but-present file falls through to the full read rather than
    // silently skipping the cap.
    if let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue {
        if size == 0 { return 0 }
        if let trigger = trimWhenBytesExceed, size < trigger { return 0 }
        if size < maxLines { return 0 }
    }
    let data = try Data(contentsOf: path)
    guard let s = String(data: data, encoding: .utf8) else {
        // U5 fix-round (2026-06-11, gpt-5.5 NIT): never silent — a non-UTF8
        // feed means the cap cannot run, which the state-lifecycle rule says
        // must be visible, not a quiet `return 0`.
        NSLog("enforceJSONLLineCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.count > maxLines else { return 0 }
    let retainedLines = min(maxLines, max(1, trimToLines ?? maxLines))
    let dropped = lines.count - retainedLines
    let trimmed = lines.suffix(retainedLines).joined(separator: "\n") + "\n"
    // Durable rewrite: the append that preceded this trim was fsync'd, so the
    // trim must not be the weak link — a bare .atomic write + replaceItemAt
    // can commit the rename before the data blocks on power loss, leaving the
    // feed truncated with the old contents already unlinked.
    try SwiftNativePersistenceCore.atomicWrite(Data(trimmed.utf8), to: path)
    return dropped
}

/// Grouped JSONL line retention. Keeps the total budget unchanged while
/// reserving the newest `minimumRowsPerKind` rows for every decodable `kind`.
/// Remaining slots are the newest rows globally. Output stays in original
/// chronological order, malformed rows still survive when they are recent,
/// and no other JSONL feed inherits this policy.
@discardableResult
func enforceJSONLKindLineCap(
    at path: URL,
    maxLines: Int,
    minimumRowsPerKind: Int,
    trimWhenBytesExceed: Int? = nil,
    trimToLines: Int? = nil
) throws -> Int {
    guard maxLines > 0,
          minimumRowsPerKind > 0,
          FileManager.default.fileExists(atPath: path.path) else { return 0 }
    if let size = ((try? FileManager.default.attributesOfItem(
        atPath: path.path
    ))?[.size] as? NSNumber)?.intValue {
        if size == 0 { return 0 }
        if let trigger = trimWhenBytesExceed, size < trigger { return 0 }
        if size < maxLines { return 0 }
    }
    let data = try Data(contentsOf: path)
    guard let text = String(data: data, encoding: .utf8) else {
        NSLog("enforceJSONLKindLineCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.count > maxLines else { return 0 }
    let retainedLines = min(maxLines, max(1, trimToLines ?? maxLines))

    var reserved = Set<Int>()
    var retainedPerKind: [String: Int] = [:]
    for index in lines.indices.reversed() {
        guard let row = try? JSONValue.parse(Data(lines[index].utf8)),
              case .object(let object) = row,
              case .string(let rawKind)? = object["kind"] else { continue }
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, retainedPerKind[kind, default: 0] < minimumRowsPerKind else {
            continue
        }
        reserved.insert(index)
        retainedPerKind[kind, default: 0] += 1
    }

    var kept = Set(lines.indices.suffix(retainedLines))
    kept.formUnion(reserved)
    while kept.count > retainedLines {
        if let oldestUnreserved = kept.sorted().first(where: { !reserved.contains($0) }) {
            kept.remove(oldestUnreserved)
        } else if let oldest = kept.min() {
            // More distinct kinds than the entire line budget: remain bounded
            // and prefer the newest reserved evidence deterministically.
            kept.remove(oldest)
        } else {
            break
        }
    }
    let ordered = kept.sorted().map { lines[$0] }
    let dropped = lines.count - ordered.count
    guard dropped > 0 else { return 0 }
    try SwiftNativePersistenceCore.atomicWrite(
        Data((ordered.joined(separator: "\n") + "\n").utf8),
        to: path
    )
    return dropped
}

/// Trim a JSONL file to the newest whole rows that fit within `trimToBytes`
/// once it crosses `maxBytes`. The caller must hold the file's flock. The
/// lower target provides hysteresis so a busy feed does not reread/rewrite the
/// entire file on every append after reaching its ceiling.
/// A newest whole row larger than the low-water target may survive by itself;
/// diagnostic mode still requires it to fit the hard maximum. Default mode
/// preserves even an oversized newest evidence row for its owning caller.
@discardableResult
public func enforceJSONLByteCap(
    at path: URL,
    maxBytes: Int,
    trimToBytes: Int,
    preserveOversizedNewestRow: Bool = true
) throws -> Int {
    guard maxBytes > 0,
          trimToBytes > 0,
          trimToBytes <= maxBytes,
          FileManager.default.fileExists(atPath: path.path) else {
        return 0
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
    guard size.map({ $0 > maxBytes }) != false else { return 0 }
    let data = try Data(contentsOf: path)
    guard data.count > maxBytes else { return 0 }
    guard let text = String(data: data, encoding: .utf8) else {
        if !preserveOversizedNewestRow {
            throw JSONLPathOwnedAppendError.unreadableDiagnosticFeed(path.standardizedFileURL.path)
        }
        NSLog("enforceJSONLByteCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    var keptReversed: [Substring] = []
    var keptBytes = 0
    for line in lines.reversed() {
        let lineBytes = line.utf8.count + 1
        // Only opted-in disposable diagnostics may discard a legacy row that
        // alone exceeds the hard ceiling. Evidence-owning callers keep the
        // historical default. New oversized diagnostic rows are refused before
        // append by appendJSONLCapped, so this is recovery for inherited data.
        if !preserveOversizedNewestRow, lineBytes > maxBytes { continue }
        if !keptReversed.isEmpty, keptBytes + lineBytes > trimToBytes {
            break
        }
        // A single row should already be bounded by its owner. Preserve the
        // newest row even if a corrupt/legacy row exceeds the target so the
        // cap never replaces the feed with an empty file.
        keptReversed.append(line)
        keptBytes += lineBytes
        if keptBytes >= trimToBytes { break }
    }
    let kept = keptReversed.reversed()
    let dropped = max(0, lines.count - kept.count)
    guard dropped > 0 else { return 0 }
    let trimmed = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    // Same durable rewrite as enforceJSONLLineCap — see the note there.
    try SwiftNativePersistenceCore.atomicWrite(Data(trimmed.utf8), to: path)
    return dropped
}

/// U5 fix-round (2026-06-11, gpt-5.5 review): THE shared capped-append for
/// JSONL activity-style feeds. Appends `event` to `path`, then trims the file
/// to its newest `maxLines` lines, logging what the rotation dropped. Every
/// live `activity/events.jsonl` writer routes through here so no append path
/// can grow the feed unbounded again (PersonaEngine doc-save emit, Skills,
/// Executions, SchedulerDueJobRunner).
///
/// Locking: when `takeLock` is true (default) the append+cap runs under
/// `withFileLock(path)` — for EVERY conformer, not just the SwiftNative impl —
/// so the cap's read-trim-replace cannot race a concurrent capped writer. Callers
/// that already hold the events-feed flock pass `takeLock: false` to avoid
/// double-acquiring it.
public func appendJSONLCapped(
    _ event: JSONValue,
    to path: URL,
    using persistence: any PersistenceCoreProtocol,
    maxLines: Int = JSONLLineCaps.activityEvents,
    logLabel: String,
    takeLock: Bool = true,
    trimWhenBytesExceed: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    capCheckStride: Int = JSONLLineCaps.capCheckStride,
    // When the feed is a RECORD rather than telemetry, the append has to be on
    // the platter before this call returns. `appendBytes` refuses a raw durable
    // append to a path-owned feed, so the durable route has to run here, inside
    // the permit — a caller cannot get both guarantees any other way.
    durable: Bool = false,
    beforePotentialLineCap: (@Sendable () async throws -> Void)? = nil
) async throws {
    // F2 (2026-08-28): when the FILE owns its retention, the table wins over
    // whatever budget this call site remembered to pass. A mismatch is logged
    // rather than silently accepted so a stale local constant is visible.
    let policy = jsonlPathOwnedCapPolicy(for: path)
    if let policy, policy.maxLines != maxLines {
        NSLog("%@: %@ has a path-owned cap of %d line(s) — ignoring the call site's %d",
              logLabel, path.lastPathComponent, policy.maxLines, maxLines)
    }
    let effectiveMaxLines = policy?.maxLines ?? maxLines
    let effectiveTrimTrigger = policy?.trimWhenBytesExceed ?? trimWhenBytesExceed
    let effectiveMaxBytes = policy?.maxBytes ?? maxBytes
    let effectiveTrimToBytes = policy?.trimToBytes ?? trimToBytes ?? effectiveMaxBytes
    let diagnosticByteBound = policy?.maxBytes != nil
    let diagnosticAppendBytes: Int?
    // Reject rather than truncate a new diagnostic record that cannot fit in
    // its file's hard budget. Audit/authoritative callers do not inherit this.
    if diagnosticByteBound, let effectiveMaxBytes {
        let count = try event.serialize(pretty: false).utf8.count + 1
        guard count <= effectiveMaxBytes else {
            throw JSONLPathOwnedAppendError.recordExceedsByteLimit(
                path.standardizedFileURL.path, count, effectiveMaxBytes
            )
        }
        diagnosticAppendBytes = count
    } else {
        diagnosticAppendBytes = nil
    }
    let work: @Sendable () async throws -> Void = {
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
            }
        }
        // Decide once, before the append, whether this call can enter the
        // full-read line-cap path. Owners that must preserve pre-trim evidence
        // use the hook to archive at exactly the same amortized checkpoints;
        // they must not independently reread a multi-megabyte feed on every
        // append merely in case this is the one that trims.
        let fullCheckWillBeDue = JSONLCapCheckCounter.shared.isFullCheckDueOnNextAppend(
            path: path, stride: capCheckStride
        )
        // A soft trigger is not a ceiling: once a retained file remained above
        // it, the old code rewrote that file for EVERY new row. Trigger-backed
        // feeds now count only at bounded stride checkpoints, even when mature.
        // Explicit hard byte ceilings are checked on every append separately.
        let shouldCheckLines = fullCheckWillBeDue || effectiveTrimTrigger == nil
        if let beforePotentialLineCap {
            let reachesByteCeiling: Bool
            if let effectiveMaxBytes {
                let currentBytes = ((try? FileManager.default.attributesOfItem(
                    atPath: path.path
                ))?[.size] as? NSNumber)?.intValue
                let appendedBytes = (try? event.serialize(pretty: false).utf8.count + 1)
                reachesByteCeiling = currentBytes == nil
                    || appendedBytes == nil
                    || currentBytes! + appendedBytes! > effectiveMaxBytes
            } else {
                reachesByteCeiling = false
            }
            if shouldCheckLines || reachesByteCeiling {
                try await beforePotentialLineCap()
            }
        }
        try await JSONLPathOwnedAppendPermit.$isInsideCappedAppend.withValue(true) {
            if durable {
                try await persistence.appendJSONLDurable(event, to: path)
            } else {
                try await persistence.appendJSONL(event, to: path)
            }
        }
        // Spend the checkpoint only after a successful append. The caller's
        // file lock keeps the earlier evidence-hook preview and this decision
        // together. Full checkpoints always evaluate rows, regardless of size.
        _ = JSONLCapCheckCounter.shared.isFullCheckDue(
            path: path, stride: capCheckStride
        )
        let dropped: Int
        if !shouldCheckLines {
            dropped = 0
        } else if let minimumRowsPerKind = policy?.minimumRowsPerKind {
            dropped = try enforceJSONLKindLineCap(
                at: path,
                maxLines: effectiveMaxLines,
                minimumRowsPerKind: minimumRowsPerKind,
                trimWhenBytesExceed: nil,
                trimToLines: policy?.trimToLines
            )
        } else {
            dropped = try enforceJSONLLineCap(
                at: path,
                maxLines: effectiveMaxLines,
                trimWhenBytesExceed: nil,
                trimToLines: policy?.trimToLines
            )
        }
        if dropped > 0 {
            NSLog("%@: %@ cap dropped %d oldest line(s)",
                  logLabel, path.lastPathComponent, dropped)
        }
        if let effectiveMaxBytes, let effectiveTrimToBytes {
            let byteDropped = try enforceJSONLByteCap(
                at: path,
                maxBytes: effectiveMaxBytes,
                trimToBytes: effectiveTrimToBytes,
                preserveOversizedNewestRow: !diagnosticByteBound
            )
            if byteDropped > 0 {
                NSLog("%@: %@ byte cap dropped %d oldest line(s)",
                      logLabel, path.lastPathComponent, byteDropped)
            }
        }
    }
    if takeLock {
        // L7 (2026-08-01 audit): this used to downcast to
        // `SwiftNativePersistenceCore` and, on failure, append UNROTATED with no
        // log — a silent fallback that quietly disabled every line/byte cap for
        // any other conformer, letting the feed grow without bound while the
        // call still reported success. The downcast was also gratuitous:
        // `withFileLock` is a PersistenceCoreProtocol EXTENSION
        // (PersistenceCore+FileLock.swift:4), so every conformer already has it,
        // and it locks a local `<path>.lock` sidecar with flock independent of
        // the append backend. The `takeLock: false` branch below has always run
        // the cap for arbitrary conformers, so refusing to run it here was
        // internally inconsistent too. Now uniform: lock, append, cap — and a
        // lock-acquire failure THROWS rather than degrading in silence.
        try await persistence.withFileLock(path, work)
    } else {
        // Caller already holds the events-feed flock.
        try await work()
    }
}

public enum JSONLPathOwnedAppendError: Error, Equatable {
    case unregisteredPath(String)
    case recordExceedsByteLimit(String, Int, Int)
    case unreadableDiagnosticFeed(String)
    /// A raw (uncapped) append reached a file whose retention is path-owned.
    /// F2 (2026-08-28): the registry used to be opt-in at the CALL SITE, so the
    /// invariant "this feed is capped" held only as long as every writer
    /// remembered to use `appendPathOwnedJSONL`. It is now enforced at the one
    /// byte-writer every append funnels through, so forgetting fails loudly at
    /// the first write instead of silently growing the feed forever.
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
/// Callers that already hold the feed lock pass `takeLock:false`.
public func appendPathOwnedJSONL(
    _ event: JSONValue,
    to path: URL,
    using persistence: any PersistenceCoreProtocol,
    logLabel: String,
    takeLock: Bool = true,
    durable: Bool = false,
    // Passthrough to `appendJSONLCapped`'s pre-trim hook, for the owners whose
    // feed must not lose a row to a trim. It throws to STOP the append.
    beforePotentialLineCap: (@Sendable () async throws -> Void)? = nil
) async throws {
    guard let policy = jsonlPathOwnedCapPolicy(for: path) else {
        throw JSONLPathOwnedAppendError.unregisteredPath(path.standardizedFileURL.path)
    }
    try await appendJSONLCapped(
        event,
        to: path,
        using: persistence,
        maxLines: policy.maxLines,
        logLabel: logLabel,
        takeLock: takeLock,
        trimWhenBytesExceed: policy.trimWhenBytesExceed,
        durable: durable,
        beforePotentialLineCap: beforePotentialLineCap
    )
}
