import Foundation

// MARK: - REMPin (chat-turn injection shape)

/// One latest-approved REM proposal, surfaced into every chat turn's system
/// prompt as "Recent REM-approved persona drift". Public so the chat
/// orchestrator can decode the pins.json index.
public struct REMPin: Sendable, Codable, Equatable {
    public var id: String
    public var text: String
    public var createdAt: String

    public init(id: String, text: String, createdAt: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - REMPinsReader

/// Mtime-cached reader for the rem_pins.json index emitted by REMConsolidator.
/// Lives in DreamREMCycle so ChatOrchestration can depend on it without
/// pulling the whole consolidation pipeline.
public enum REMPinsReader {
    /// Read the per-target pins index. Empty file / missing file / parse
    /// failure all return an empty dict — the chat turn must NOT inject
    /// anything in those cases.
    public static func read(dataRoot: URL) -> [String: [REMPin]] {
        let url = dataRoot.appendingPathComponent("rem_pins.json")
        return REMPinsDecodedCache.shared.read(url: url)
    }

    /// Flatten the per-target pins into the chat-turn injection lines.
    /// Returns at most `latestN` pins overall (default 3), newest first by
    /// createdAt. Empty input → empty array → no injection.
    public static func latest(_ index: [String: [REMPin]], latestN: Int = 3) -> [REMPin] {
        let all = index.values.flatMap { $0 }
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(latestN))
    }

    struct CacheStats: Sendable, Equatable {
        let decodeAttempts: Int
        let hits: Int
    }

    /// Deterministic operation-count seam for the turn-speed regression.
    static func _testCacheStats(dataRoot: URL) -> CacheStats {
        REMPinsDecodedCache.shared.stats(
            url: dataRoot.appendingPathComponent("rem_pins.json")
        )
    }

    static func _resetCacheForTesting(dataRoot: URL) {
        REMPinsDecodedCache.shared.reset(
            url: dataRoot.appendingPathComponent("rem_pins.json")
        )
    }
}

/// Process-local decoded cache keyed by canonical path and file mtime.
///
/// Every read still stats the exact file, so removal and atomic replacement are
/// visible on the next turn. Missing, unreadable, empty, or corrupt bytes cache
/// only an empty result for that observed mtime; a later mtime always retries
/// the decode. This preserves the reader's fail-closed behavior without paying
/// JSON decode cost on every unchanged chat turn.
private final class REMPinsDecodedCache: @unchecked Sendable {
    static let shared = REMPinsDecodedCache()

    private struct Entry {
        let modifiedAt: Date
        let index: [String: [REMPin]]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var decodeAttempts: [String: Int] = [:]
    private var hits: [String: Int] = [:]

    func read(url: URL) -> [String: [REMPin]] {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }

        // Retry once if a writer replaces the file between the first stat and
        // the read. Never associate bytes with a stale mtime key.
        for _ in 0..<2 {
            guard let modifiedAt = modificationDate(url) else {
                entries.removeValue(forKey: key)
                return [:]
            }
            if let entry = entries[key], entry.modifiedAt == modifiedAt {
                hits[key, default: 0] += 1
                return entry.index
            }

            decodeAttempts[key, default: 0] += 1
            let decoded: [String: [REMPin]]
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let value = try? JSONDecoder().decode([String: [REMPin]].self, from: data) {
                decoded = value
            } else {
                decoded = [:]
            }
            guard modificationDate(url) == modifiedAt else { continue }

            if entries[key] == nil, entries.count >= 64 {
                entries.remove(at: entries.startIndex)
            }
            entries[key] = Entry(modifiedAt: modifiedAt, index: decoded)
            return decoded
        }

        // A continuously changing file is not a safe source for prompt data.
        entries.removeValue(forKey: key)
        return [:]
    }

    func stats(url: URL) -> REMPinsReader.CacheStats {
        let key = url.standardizedFileURL.path
        lock.lock()
        let value = REMPinsReader.CacheStats(
            decodeAttempts: decodeAttempts[key, default: 0],
            hits: hits[key, default: 0]
        )
        lock.unlock()
        return value
    }

    func reset(url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        entries.removeValue(forKey: key)
        decodeAttempts.removeValue(forKey: key)
        hits.removeValue(forKey: key)
        lock.unlock()
    }

    private func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
        return attributes?[.modificationDate] as? Date
    }
}
