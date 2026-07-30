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
    private var didResume = false
    private let continuation: CheckedContinuation<URL, Error>

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(returning url: URL) {
        guard claim() else { return }
        continuation.resume(returning: url)
    }

    func resume(throwing error: Error) {
        guard claim() else { return }
        continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}
