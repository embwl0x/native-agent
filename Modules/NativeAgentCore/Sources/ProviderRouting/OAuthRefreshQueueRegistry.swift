import Foundation
// Blueprint: | `OAuthRefreshQueueRegistry.swift` | `OAuthRefreshQueueRegistry` class; `queue` (per credential path or key) |

/// Retains one refresh queue per credential (a standardized path, or a key) for the process lifetime.
/// Each provider adapter owns a separate static registry, even for identical paths.
final class OAuthRefreshQueueRegistry: @unchecked Sendable {
    // All dictionary access is protected by this synchronous lock.
    private var sharedRefreshActors: [String: AsyncSerialQueue] = [:]
    private let sharedRefreshActorsLock = NSLock()

    func queue(for path: URL) -> AsyncSerialQueue { queue(forKey: path.standardizedFileURL.path) }

    /// One queue per credential however it is named (a keyring secret's name).
    func queue(forKey key: String) -> AsyncSerialQueue {
        sharedRefreshActorsLock.lock()
        defer { sharedRefreshActorsLock.unlock() }
        if let existing = sharedRefreshActors[key] { return existing }
        let q = AsyncSerialQueue()
        sharedRefreshActors[key] = q
        return q
    }
}
