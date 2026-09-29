import Foundation

public final class PendingCallbacks: @unchecked Sendable {
    public static let shared = PendingCallbacks()

    private let lock = NSLock()
    private var resolvers: [String: (URL) -> Void] = [:]

    public func register(state: String, resolver: @escaping (URL) -> Void) {
        lock.lock()
        resolvers[state] = resolver
        lock.unlock()
    }

    public func forget(state: String) {
        lock.lock()
        resolvers.removeValue(forKey: state)
        lock.unlock()
    }

    @discardableResult
    public func resolve(state: String, with url: URL) -> Bool {
        lock.lock()
        let cb = resolvers.removeValue(forKey: state)
        lock.unlock()
        guard let cb else { return false }
        cb(url)
        return true
    }
}
