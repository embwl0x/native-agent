import Foundation

/// Retains one refresh queue per standardized credential path for the process lifetime.
/// Each provider adapter owns a separate static registry, even for identical paths.
final class OAuthRefreshQueueRegistry: @unchecked Sendable {
    // All dictionary access is protected by this synchronous lock.
    private var sharedRefreshActors: [String: AsyncSerialQueue] = [:]
    private let sharedRefreshActorsLock = NSLock()

    func queue(for path: URL) -> AsyncSerialQueue {
        sharedRefreshActorsLock.lock()
        defer { sharedRefreshActorsLock.unlock() }
        let key = path.standardizedFileURL.path
        if let existing = sharedRefreshActors[key] { return existing }
        let q = AsyncSerialQueue()
        sharedRefreshActors[key] = q
        return q
    }
}
