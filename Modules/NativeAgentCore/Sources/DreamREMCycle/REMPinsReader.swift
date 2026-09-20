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
    /// failure all return an empty dict. I/O failures retain the last readable
    /// index for this session and retry on the next turn.
    public static func read(dataRoot: URL) -> [String: [REMPin]] {
        let url = dataRoot.appendingPathComponent("rem_pins.json")
        return REMPinsDecodedCache.shared.read(url: url)
    }

    /// Flatten the per-target pins into the chat-turn injection lines.
    /// Returns at most `latestN` pins overall (default 3), newest first by
    /// createdAt. Empty input → empty array → no injection.
    public static func latest(_ index: [String: [REMPin]], latestN: Int = 3) -> [REMPin] {
        // 2026-09-18: equal timestamps must not inherit randomized dictionary
        // order after a relaunch; these pins are part of the cached prefix.
        let all = index.keys.sorted().flatMap { index[$0] ?? [] }
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
/// visible on the next turn. I/O failures leave the last readable index intact
/// and are never cached as successful reads. Missing, empty, or corrupt bytes
/// return empty, preserving the existing decode behavior.
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
    private var loggedReadFailures: Set<String> = []

    func read(url: URL) -> [String: [REMPin]] {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }

        do {
            // Retry once if a writer replaces the file between stat and read.
            for _ in 0..<2 {
                let modifiedAt = try modificationDate(url)
                if let entry = entries[key], entry.modifiedAt == modifiedAt {
                    hits[key, default: 0] += 1
                    loggedReadFailures.remove(key)
                    return entry.index
                }

                decodeAttempts[key, default: 0] += 1
                let data = try Data(contentsOf: url)
                let decoded = (try? JSONDecoder().decode([String: [REMPin]].self, from: data)) ?? [:]
                guard try modificationDate(url) == modifiedAt else { continue }

                if entries[key] == nil, entries.count >= 64 {
                    entries.remove(at: entries.startIndex)
                }
                entries[key] = Entry(modifiedAt: modifiedAt, index: decoded)
                loggedReadFailures.remove(key)
                return decoded
            }
            throw CocoaError(.fileReadUnknown)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError {
                entries.removeValue(forKey: key)
                loggedReadFailures.remove(key)
                return [:]
            }
            if loggedReadFailures.insert(key).inserted {
                fputs("[REMPinsReader] Cannot read \(url.path); retaining last readable pins and retrying next turn: \(error)\n", stderr)
            }
            return entries[key]?.index ?? [:]
        }
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
        loggedReadFailures.remove(key)
        lock.unlock()
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }
}
