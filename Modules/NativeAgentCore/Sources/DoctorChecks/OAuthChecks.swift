import Foundation
import ProviderRouting
import PersistenceCore
// Blueprint: | `OAuthChecks.swift` | OAuthTokenExpiryCheck measures credentials through their owners; inspection never exchanges tokens and scoped repair refreshes only expired refreshable credentials |

/// Expiry repair delegates to the credential's runtime owner. Inspection never exchanges tokens; safe repair refreshes only
/// expired, refreshable credentials.
public struct OAuthTokenExpiryCheck: RepairingDoctorCheck {
    public let id = "oauth_token_expiry"
    public let title = "OAuth Token Expiry"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    private struct Credential {
        let owner: String
        let name: String
        let path: URL

        func signIn(_ root: URL) -> String {
            if let control = NativeOAuthFlow.signInControl(providerID: owner, dataRoot: root) { return "Open " + control + "." }
            return "Open Connectors → \(name) → Connect (or Reconnect)."
        }
    }

    private func credentials() -> [Credential] {
        let entries = [
            ("xai_oauth_direct", "xAI"), ("anthropic_oauth_direct", "Anthropic"),
            ("openai_oauth_direct", "ChatGPT"),
        ].map { owner, name in
            Credential(owner: owner, name: name,
                       path: ProviderOAuthCredentialMaintenance.credentialPath(provider: owner, root: root))
        }
        return entries.filter { credential in
            let fm = FileManager.default
            guard fm.fileExists(atPath: credential.path.path) else { return false }
            if credential.owner.hasSuffix("_oauth_direct"),
               let data = try? Data(contentsOf: credential.path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // A provider settings file with no credential is not a failed sign-in.
                return object["access_token"] != nil || object["refresh_token"] != nil || object["tokens"] != nil
            }
            return true
        }
    }

    public func run(repair: Bool) async -> CheckResult {
        let credentialList = credentials()
        let now = Date()
        var findings: [String] = []
        var asks: [String] = []
        var repaired: [String] = []
        var noExpiry: [String] = []
        var refreshable = false
        var unreadable = false
        var checked = 0
        for credential in credentialList {
            do {
                var state = try ProviderOAuthCredentialMaintenance.status(provider: credential.owner, root: root)
                checked += 1
                guard state.configured else {
                    findings.append("\(credential.name) has no usable saved credential")
                    asks.append(credential.signIn(root))
                    continue
                }
                if state.expiresAt == nil && !state.requiresRefresh {
                    noExpiry.append(credential.name)
                    continue
                }
                if !state.requiresRefresh, let expiry = state.expiresAt, expiry > now {
                    if !state.canRefresh && expiry.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
                        findings.append("\(credential.name) access expires within 7 days and no refresh credential is available")
                        asks.append(credential.signIn(root))
                    }
                    continue
                }
                let reason = state.requiresRefresh ? "authorization needs renewal" : "access expired"
                guard state.canRefresh else {
                    findings.append("\(credential.name) \(reason) and no refresh credential is available")
                    asks.append(credential.signIn(root))
                    continue
                }
                // Refreshable is normal (it renews on next use): not a finding, or she reads it as signed out and asks User to
                // sign in again.
                guard repair else {
                    refreshable = true
                    continue
                }
                do {
                    try Task.checkCancellation()
                    try await ProviderOAuthCredentialMaintenance.refresh(provider: credential.owner, root: root)
                    state = try ProviderOAuthCredentialMaintenance.status(provider: credential.owner, root: root)
                    if state.configured && !state.requiresRefresh && (state.expiresAt.map { $0 > Date() } ?? true) {
                        repaired.append(credential.name)
                        if state.expiresAt == nil { noExpiry.append(credential.name) }
                    } else {
                        findings.append("\(credential.name) still has no current access credential after refresh")
                        if !state.configured || !state.canRefresh { asks.append(credential.signIn(root)) }
                        else { refreshable = true }
                    }
                } catch {
                    if ProviderOAuthCredentialMaintenance.requiresSignIn(error) {
                        findings.append("\(credential.name) rejected the saved refresh authorization")
                        asks.append(credential.signIn(root))
                    } else {
                        // Provider bodies and credential material never enter Doctor reports.
                        findings.append("\(credential.name) refresh could not complete")
                        refreshable = true
                    }
                }
            } catch {
                unreadable = true
                findings.append("\(credential.name) credential state could not be read from \(credential.path.path)")
                asks.append(credential.signIn(root))
            }
        }
        var parts = ["\(checked) credential(s) inspected through their owners"]
        if !noExpiry.isEmpty {
            parts.append("no scheduled expiry: \(noExpiry.joined(separator: ", "))")
        }
        if !repaired.isEmpty { parts.append("refreshed: \(repaired.joined(separator: ", "))") }
        parts += findings
        let actions = asks.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }
        return CheckResult(source: credentialList.map { $0.path.path }.joined(separator: ", "), id: id, title: title,
                           status: unreadable ? "fail" : findings.isEmpty ? "ok" : "warn",
                           detail: parts.joined(separator: "; ") + ".",
                           harm: asks.isEmpty ? nil : "She cannot keep using the affected services without renewed access.",
                           repair: refreshable ? DoctorSafeRepairPolicy.oauthRefreshInstruction : nil,
                           receipt: repaired.isEmpty ? nil : "Repaired: refreshed \(repaired.joined(separator: ", ")).",
                           repairApplied: !repaired.isEmpty,
                           human_action: asks.isEmpty ? nil : actions.joined(separator: "; ") + ".",
                           repair_available: refreshable,
                           ask: asks.isEmpty ? nil : .signIn)
    }
}
