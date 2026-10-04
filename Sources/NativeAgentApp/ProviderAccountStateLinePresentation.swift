import Foundation

/// The one line under a configured provider's name.
///
/// `auth_status.state == "ready"` means "eligible to dispatch", which is NOT
/// the same claim as "connected". The oauth-direct readers deliberately return
/// ready for an access token that has already expired as long as a refresh
/// token is on file — the refresh itself is unproven until a chat uses it. That
/// detail is already in the row's own model, so the line states it instead of
/// replacing it with "Connected · account available".
enum ProviderAccountStateLinePresentation {
    static func line(state: String, detail: String, failedTest: String? = nil) -> String {
        guard state.lowercased() == "ready" else { return "Not connected" }
        if let failedTest { return failedTestLine(failedTest) }
        // An expired access token with a refresh token on file is normal: it
        // renews on the next chat. Saying "expired" here sent User to sign in
        // three times (10-03); a real refresh failure arrives as failedTest.
        return "Connected · account available"
    }

    /// A signed-in account whose last test failed (`LLMProviderStatusFeed.failedTest`):
    /// ready to dispatch is not working. Reconnecting is User's, in Manage.
    static func failedTestLine(_ failure: String) -> String {
        failure == "key rejected" ? "Key rejected — reconnect" : "Connected · last test failed: \(failure)"
    }

    /// The Providers page read's `state — detail`. Ready only means eligible
    /// to dispatch, so a rejected key or expired access leads with that.
    static func pageLine(state: String, detail: String, failedTest: String?) -> String {
        guard state.lowercased() == "ready" else { return "\(state) — \(detail)" }
        if let failedTest {
            return failedTest == "key rejected" ? "needs reconnect — Key rejected" : "last test failed — \(failedTest)"
        }
        return detail.lowercased().contains("expired")
            ? "ready — signed in; the access token renews itself on the next chat (nothing to do)" : "\(state) — \(detail)"
    }
}
