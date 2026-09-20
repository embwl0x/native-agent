import AuthenticationServices
import Foundation

final class OAuthSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: ASWebAuthenticationSession?

    func set(_ session: ASWebAuthenticationSession) {
        lock.lock()
        value = session
        lock.unlock()
    }

    func session() -> ASWebAuthenticationSession? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class OAuthContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<URL, Error>?
    private var continuation: CheckedContinuation<URL, Error>?

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning url: URL) {
        finish(.success(url))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
