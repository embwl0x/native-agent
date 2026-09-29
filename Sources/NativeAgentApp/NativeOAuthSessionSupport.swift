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
