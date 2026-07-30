import Foundation

final class PendingCallbacks: @unchecked Sendable {
    static let shared = PendingCallbacks()

    private let lock = NSLock()
    private var resolvers: [String: (URL) -> Void] = [:]

    func register(state: String, resolver: @escaping (URL) -> Void) {
        lock.lock()
        resolvers[state] = resolver
        lock.unlock()
    }

    func forget(state: String) {
        lock.lock()
        resolvers.removeValue(forKey: state)
        lock.unlock()
    }

    @discardableResult
    func resolve(state: String, with url: URL) -> Bool {
        lock.lock()
        let cb = resolvers.removeValue(forKey: state)
        lock.unlock()
        guard let cb else { return false }
        cb(url)
        return true
    }
}
