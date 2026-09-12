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
    static func line(state: String, detail: String) -> String {
        guard state.lowercased() == "ready" else { return "Not connected" }
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard detail.lowercased().contains("expired") else {
            return "Connected · account available"
        }
        return "Signed in · access expired, refresh unproven until the next chat"
    }
}
