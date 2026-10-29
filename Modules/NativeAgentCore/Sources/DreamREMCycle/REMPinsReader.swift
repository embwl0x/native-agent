import Foundation
// Blueprint: | `REMPinsReader.swift` | `REMPinsReader`: checked mtime-cached pin reads; only absence is empty, unavailable bytes fail the turn; `latest` |

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
/// Lives in DreamREMCycle so ChatTurnRuntime can depend on it without
/// pulling the whole consolidation pipeline.
public enum REMPinsReader {
    public enum ReadError: Error, LocalizedError {
        case unavailable(URL, Error)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let url, let error):
                return "REM pins unavailable at \(url.path): \(error.localizedDescription). Preserve the file and repair its owning index before retrying."
            }
        }
    }

    /// Only a missing file is an empty index. Existing unreadable or invalid
    /// bytes are unavailable; no stale pins replace the owning file.
    public static func read(dataRoot: URL) throws -> [String: [REMPin]] {
        let url = dataRoot.appendingPathComponent("rem_pins.json")
        return try REMPinsDecodedCache.shared.read(url: url)
    }

    /// Flatten the per-target pins into the chat-turn injection lines.
    /// Returns at most `latestN` pins overall (default 3), newest first by
    /// createdAt. Empty input → empty array → no injection.
    public static func latest(_ index: [String: [REMPin]], latestN: Int = 3) -> [REMPin] {
        // Sort target keys so timestamp ties keep a stable cached prefix across launches.
        let all = index.keys.sorted().flatMap { index[$0] ?? [] }
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(latestN))
    }
}

/// Process-local decoded cache keyed by canonical path and file mtime.
///
/// Every read still stats the exact file, so removal and atomic replacement are
/// visible on the next turn. Failures invalidate the cache and propagate;
/// only a successful decode is cached.
private final class REMPinsDecodedCache: @unchecked Sendable {
    static let shared = REMPinsDecodedCache()

    private struct Entry {
        let modifiedAt: Date
        let index: [String: [REMPin]]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func read(url: URL) throws -> [String: [REMPin]] {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }

        do {
            // Retry once if a writer replaces the file between stat and read.
            for _ in 0..<2 {
                let modifiedAt = try modificationDate(url)
                if let entry = entries[key], entry.modifiedAt == modifiedAt {
                    return entry.index
                }

                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode([String: [REMPin]].self, from: data)
                guard try modificationDate(url) == modifiedAt else { continue }

                if entries[key] == nil, entries.count >= 64 {
                    entries.remove(at: entries.startIndex)
                }
                entries[key] = Entry(modifiedAt: modifiedAt, index: decoded)
                return decoded
            }
            throw CocoaError(.fileReadUnknown)
        } catch {
            entries.removeValue(forKey: key)
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError {
                return [:]
            }
            throw REMPinsReader.ReadError.unavailable(url, error)
        }
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
