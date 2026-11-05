import Foundation
// Blueprint: | `REMPinsReader.swift` | `REMPinsReader`: checked mtime-cached pin reads; only absence is empty, unavailable bytes fail the turn; `latest` |

// MARK: - REMPin (chat-turn injection shape)

/// Share the public pin shape so chat can decode approved drift without owning consolidation.
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

/// Keep pin reading in DreamREMCycle so turn runtime need not import the consolidation pipeline.
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

    /// Only missing storage is empty; unreadable pins cannot reuse stale cached authority.
    public static func read(dataRoot: URL) throws -> [String: [REMPin]] {
        let url = dataRoot.appendingPathComponent("rem_pins.json")
        return try REMPinsDecodedCache.shared.read(url: url)
    }

    /// Bound newest-first pins across all targets so injection has one global limit.
    public static func latest(_ index: [String: [REMPin]], latestN: Int = 3) -> [REMPin] {
        // Sort target keys so timestamp ties preserve cached prefix bytes across launches.
        let all = index.keys.sorted().flatMap { index[$0] ?? [] }
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(latestN))
    }
}

/// Stat every read to observe removal and replacement; cache only successful decodes and invalidate on failure.
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
            // Retry once only when atomic replacement invalidates the stat/read identity.
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
