import Foundation
import CommonCrypto
import PersistenceCore

// Heavy logic for the REM consolidation pipeline:
//   - topic clustering of dream entries
//   - .rem_tombstones exclusion of denied proposals
//   - GROWTH.md size-cap eviction (caller distills evicted slice into KG)
//   - 14-day archival of old dream_diary entries
//
// Mirrors the retired daemon behaviors (_REM_MAX_PROPOSALS gate, .rem_tombstones
// denylist, GROWTH cap eviction-to-KG, 14-day archive). Persistence + approval
// gating remain with the caller — these are stateless helpers / file actors.

// MARK: - Topic clustering

public struct DreamEntryCluster: Sendable {
    public let topicKey: String
    public let entries: [DreamEntry]
    public let dateRange: (earliest: String, latest: String)

    public init(topicKey: String, entries: [DreamEntry], dateRange: (earliest: String, latest: String)) {
        self.topicKey = topicKey
        self.entries = entries
        self.dateRange = dateRange
    }
}

private func wordSet(_ s: String, prefix: Int = 100) -> Set<String> {
    let head = String(s.prefix(prefix)).lowercased()
    let parts = head.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    return Set(parts.map(String.init).filter { !$0.isEmpty })
}

private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
    if a.isEmpty && b.isEmpty { return 1.0 }
    let inter = a.intersection(b).count
    let uni = a.union(b).count
    if uni == 0 { return 0 }
    return Double(inter) / Double(uni)
}

private func topicLabel(_ s: String) -> String {
    let head = String(s.prefix(100)).lowercased()
    let parts = head.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "is", "it", "for", "on"]
    let sig = parts.filter { !stop.contains($0) && $0.count > 1 }
    return sig.prefix(4).joined(separator: "-")
}

/// Group dream entries by similar leading-text topic via Jaccard ≥ 0.5 on the
/// first 100 chars' word-set. Greedy single-pass assignment; entries that don't
/// reach the threshold against any existing cluster become their own singleton.
public func clusterDreamEntries(_ entries: [DreamEntry]) -> [DreamEntryCluster] {
    var clusters: [(key: String, sets: [Set<String>], entries: [DreamEntry])] = []
    for entry in entries {
        let text = entry.content ?? ""
        let ws = wordSet(text)
        var placed = false
        for i in 0..<clusters.count {
            // Compare to first member's word set (representative).
            if let rep = clusters[i].sets.first, jaccard(ws, rep) >= 0.5 {
                clusters[i].sets.append(ws)
                clusters[i].entries.append(entry)
                placed = true
                break
            }
        }
        if !placed {
            clusters.append((key: topicLabel(text), sets: [ws], entries: [entry]))
        }
    }
    return clusters.map { c in
        let dates = c.entries.map { $0.date }.sorted()
        return DreamEntryCluster(
            topicKey: c.key,
            entries: c.entries,
            dateRange: (earliest: dates.first ?? "", latest: dates.last ?? "")
        )
    }
}

// MARK: - REMTombstoneStore

/// Byte-compatible port of daemon `_tombstone_fp(text)` (the retired daemon
/// L76-81 — `" ".join(text.lower().split())` then sha256 hex first-16).
/// Python's `str.split()` with no args splits on runs of ANY whitespace and
/// discards empties; the Swift equivalent is `split(whereSeparator: { $0.isWhitespace })`
/// (which also drops zero-length runs by default). Anything that diverges from
/// this exact pipeline silently desyncs Swift and daemon dedup.
public func _tombstone_fp(_ text: String) -> String {
    let pieces = text.lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    let normalized = pieces.joined(separator: " ")
    let digest = sha256Hex(normalized)
    return String(digest.prefix(16))
}

/// SHA256 → lowercase hex string. CryptoKit unavailable to keep the
/// PersistenceCore-only dep graph clean; CommonCrypto is in the SDK and
/// produces the same byte-compat digest Python's hashlib does.
private func sha256Hex(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    bytes.withUnsafeBufferPointer { buf in
        _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

/// Daemon tombstone value shape — mirrors the retired daemon
/// (`tombstones[fp] = {rejected_at, target_doc, reason, preview}`). The dict
/// keys are snake_case to match daemon's JSON-on-disk format byte-for-byte.
public struct REMTombstoneRecord: Codable, Sendable, Equatable {
    public let rejected_at: String
    public let target_doc: String
    public let reason: String
    public let preview: String

    public init(rejected_at: String, target_doc: String, reason: String, preview: String) {
        self.rejected_at = rejected_at
        self.target_doc = target_doc
        self.reason = reason
        self.preview = preview
    }
}

/// A nonempty tombstone file is durable rejection state. Do not reinterpret an
/// unreadable or malformed file as an empty denylist: callers must abort so a
/// rejected proposal cannot return and a subsequent write cannot erase it.
public enum REMTombstoneStoreError: Error, LocalizedError, Equatable, Sendable {
    case unreadable(path: String)
    case malformed(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "REM tombstones at \(path) could not be read; preserving the file and aborting the pass"
        case .malformed(let path):
            return "REM tombstones at \(path) are malformed; preserving the file and aborting the pass"
        }
    }
}

public actor REMTombstoneStore {
    private let path: URL
    private let fm = FileManager.default
    private let lockCore = SwiftNativePersistenceCore()

    /// BUG-A FIX: daemon writes tombstones as a SINGLE JSON dict
    /// (`{fp: {...}}`) at `<data_root>/harness/.rem_tombstones.json`
    ///. Swift previously wrote JSONL (one
    /// record per line) at the same path — the path was right but the
    /// FORMAT was wrong, so each side's writes were meaningless to the
    /// other. Rewrite to read/write the daemon dict format keyed by the
    /// SHA256-first-16 fingerprint of `_tombstone_fp(proposed_text)`.
    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        let dir = dataRoot.appendingPathComponent("harness", isDirectory: true)
        self.path = dir.appendingPathComponent(".rem_tombstones.json")
    }

    /// Test seam — accept an explicit path so test suites that need to
    /// validate the harness/.rem_tombstones.json location can also pin a
    /// tmpdir without re-deriving the path from a dataRoot URL.
    public init(path: URL) {
        self.path = path
    }

    /// Test introspection — return the file URL this store writes to.
    /// Used by `remTombstoneStore_uses_harness_path_not_dream_diary` to
    /// assert the path lives under `harness/.rem_tombstones.json`.
    public func tombstonesPath() -> URL { path }

    private func ensureDir() throws {
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Daemon-shape loader: file content is a JSON dict keyed by fingerprint.
    /// Backward-compat: if the file looks like JSONL (older Swift writes from
    /// before this fix), parse complete legacy records and upgrade on the NEXT
    /// mutation. Missing or empty state means no tombstones. A nonempty state
    /// that cannot be decoded in either supported format fails closed.
    public func loadAll() throws -> [String: REMTombstoneRecord] {
        guard fm.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileNoSuchFile.rawValue {
                return [:]
            }
            throw REMTombstoneStoreError.unreadable(path: path.path)
        }
        guard !data.isEmpty else { return [:] }
        // Try daemon dict shape first.
        if let dict = try? JSONDecoder().decode([String: REMTombstoneRecord].self, from: data) {
            return dict
        }
        // Legacy JSONL fall-through. Parse each line, synthesize a fingerprint
        // from the legacy `normText` (which was already lowered + whitespace-
        // collapsed — same as `_tombstone_fp` minus the hash), then rebuild a
        // daemon record so the next write upgrades the file on disk.
        struct LegacyEntry: Decodable {
            let targetDoc: String
            let normText: String
            let reason: String
            let recordedAt: String
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw REMTombstoneStoreError.malformed(path: path.path)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw REMTombstoneStoreError.malformed(path: path.path)
        }
        var migrated: [String: REMTombstoneRecord] = [:]
        for line in lines {
            guard let legacy = try? JSONDecoder().decode(LegacyEntry.self, from: Data(line.utf8)) else {
                throw REMTombstoneStoreError.malformed(path: path.path)
            }
            // Compute fingerprint from the already-normalized legacy normText.
            // Re-normalizing is a no-op (lower + collapse is idempotent), so this
            // matches `_tombstone_fp` exactly even though we don't have the raw
            // pre-normalization text.
            let normText = legacy.normText
            let fp = _tombstone_fp(normText)
            migrated[fp] = REMTombstoneRecord(
                rejected_at: legacy.recordedAt,
                target_doc: legacy.targetDoc,
                reason: legacy.reason,
                preview: String(normText.prefix(200))
            )
        }
        return migrated
    }

    private func saveAll(_ dict: [String: REMTombstoneRecord]) throws {
        try ensureDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(dict)
        // Atomic write via tmp + rename — matches daemon's `write_text` which
        // CPython implements atomically on POSIX. `.atomic` write option on
        // Data does the equivalent dance.
        try data.write(to: path, options: .atomic)
    }

    public func record(_ proposal: REMProposal, reason: String) async throws {
        let proposedText = proposal.proposalText
        let fp = _tombstone_fp(proposedText)
        let isoNow = ISO8601DateFormatter().string(from: Date())
        let record = REMTombstoneRecord(
            rejected_at: isoNow,
            target_doc: proposal.targetDoc,
            reason: reason,
            preview: String(proposedText.prefix(200))
        )
        // BUG-A FIX: wrap the read-modify-write under withFileLock so
        // concurrent daemon writes can't lose updates. flock convention:
        // `<path>.lock` sibling file, matches the retired daemon.
        try await lockCore.withFileLock(path) {
            var dict = try await self.loadAllInsideLock()
            dict[fp] = record
            try await self.saveAllInsideLock(dict)
        }
    }

    /// Worker that runs inside the actor while file lock is held by the
    /// withFileLock closure. Needed because withFileLock's body is non-actor
    /// (@Sendable closure) — we hop back into the actor via `await self.x()`.
    private func loadAllInsideLock() async throws -> [String: REMTombstoneRecord] {
        return try loadAll()
    }

    private func saveAllInsideLock(_ dict: [String: REMTombstoneRecord]) async throws {
        try saveAll(dict)
    }

    public func isTombstoned(_ proposal: REMProposal) async throws -> Bool {
        let fp = _tombstone_fp(proposal.proposalText)
        let dict = try loadAll()
        return dict[fp] != nil
    }
}

// MARK: - GrowthDocManager

public actor GrowthDocManager {
    private let path: URL
    private let fm = FileManager.default

    public init(personaRoot: URL) {
        self.path = personaRoot.appendingPathComponent("GROWTH.md")
    }

    public func growthSize() async -> Int {
        guard fm.fileExists(atPath: path.path) else { return 0 }
        let attrs = (try? fm.attributesOfItem(atPath: path.path)) ?? [:]
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    private func readText() throws -> String {
        guard fm.fileExists(atPath: path.path) else { return "" }
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private struct EntryBlock {
        let date: String
        let text: String  // includes trailing newline if any
        let range: Range<String.Index>
    }

    /// Parse lines starting with `YYYY-MM-DD` as entry boundaries. Lines before
    /// the first date prefix belong to a synthetic "" header block we never evict.
    private func parseEntries(_ body: String) -> [EntryBlock] {
        let dateRegex = try! NSRegularExpression(
            pattern: "(^|\\n)(\\d{4}-\\d{2}-\\d{2})",
            options: []
        )
        let ns = body as NSString
        let matches = dateRegex.matches(in: body, options: [], range: NSRange(location: 0, length: ns.length))
        var blocks: [EntryBlock] = []
        for (i, m) in matches.enumerated() {
            let dateNS = m.range(at: 2)
            let date = ns.substring(with: dateNS)
            let blockStart = (m.range(at: 1).length > 0) ? m.range(at: 1).location + 1 : m.range.location
            let nextStart: Int
            if i + 1 < matches.count {
                let nm = matches[i + 1]
                nextStart = (nm.range(at: 1).length > 0) ? nm.range(at: 1).location + 1 : nm.range.location
            } else {
                nextStart = ns.length
            }
            let chunkRange = NSRange(location: blockStart, length: nextStart - blockStart)
            let chunk = ns.substring(with: chunkRange)
            guard let r = Range(chunkRange, in: body) else { continue }
            blocks.append(EntryBlock(date: date, text: chunk, range: r))
        }
        return blocks
    }

    public func evictionCandidates(maxBytes: Int) async throws -> String {
        let body = try readText()
        let size = body.utf8.count
        if size <= maxBytes { return "" }
        var blocks = parseEntries(body)
        blocks.sort { $0.date < $1.date }
        var evicted = ""
        var remaining = size
        for b in blocks {
            if remaining <= maxBytes { break }
            evicted += b.text
            remaining -= b.text.utf8.count
        }
        return evicted
    }

    public func appendEntry(_ text: String, date: String) async throws {
        let body = try readText()
        var out = body
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        out += "\(date) \(text)\n"
        try out.data(using: .utf8)!.write(to: path)
    }

    public func deleteSlice(_ slice: String) async throws {
        guard !slice.isEmpty else { return }
        let body = try readText()
        guard let r = body.range(of: slice) else { return }
        var out = body
        out.removeSubrange(r)
        try out.data(using: .utf8)!.write(to: path)
    }
}

// MARK: - DreamArchiver

public actor DreamArchiver {
    private let dataRoot: URL
    private let fm = FileManager.default

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    // Same stem pattern the readers use: legacy `YYYY-MM-DD.md` AND the
    // older session-suffixed `YYYY-MM-DD_<session>.md`. The old
    // `^(\d{4})-(\d{2})-(\d{2})$`
    // matched only the legacy form, so every Swift-written entry was skipped
    // and 14-day archival was a permanent no-op (dream_diary/ grew unbounded).
    private static let stemRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2})(?:_.+)?$")
    }()

    public func archiveOlderThan(daysOld: Int = 14, now: Date = Date()) async throws -> Int {
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard fm.fileExists(atPath: diary.path) else { return 0 }
        let cutoff = now.addingTimeInterval(TimeInterval(-daysOld * 86_400))
        let names = (try? fm.contentsOfDirectory(atPath: diary.path)) ?? []
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate]
        var moved = 0
        for name in names where name.hasSuffix(".md") {
            let stem = (name as NSString).deletingPathExtension
            let ns = stem as NSString
            let m = Self.stemRegex.firstMatch(in: stem, options: [], range: NSRange(location: 0, length: ns.length))
            guard let m else { continue }
            let dateStr = ns.substring(with: m.range(at: 1))
            guard let parsed = dateFmt.date(from: dateStr) else { continue }
            if parsed >= cutoff { continue }
            let year = String(dateStr.prefix(4))
            let archiveDir = diary.appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(year, isDirectory: true)
            if !fm.fileExists(atPath: archiveDir.path) {
                try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            }
            let src = diary.appendingPathComponent(name)
            let dst = archiveDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            try fm.moveItem(at: src, to: dst)
            moved += 1
        }
        return moved
    }
}
