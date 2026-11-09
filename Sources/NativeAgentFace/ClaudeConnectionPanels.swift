import SwiftUI
import NativeAgentShared
import Foundation
import AppKit
// Blueprint: | `ClaudeConnectionPanels.swift` | Direct Anthropic OAuth sign-in and setup-token connection panel |

enum AnthropicOAuthDirectPanelPresentation {
    static let title = "Connect via Anthropic OAuth"
    static let detail = "Full capability API access (streaming, vision, tools) using your own OAuth credentials."
}

struct AnthropicOAuthDirectPanel: View {
    var showConnectionTest = false
    @Environment(AppModel.self) private var appModel
    @State private var isTesting = false
    @State private var testStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AnthropicOAuthDirectPanelPresentation.title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            ProviderNote(text: AnthropicOAuthDirectPanelPresentation.detail)
            // Read sign-in from its canonical store so provider-list staleness cannot hide current state.
            OAuthSignInButton(provider: .anthropic)
            AnthropicSetupTokenInput()
            if showConnectionTest {
                Button(isTesting ? "Testing Claude…" : "Test Claude connection") {
                    Task { await testConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting)
                if let testStatus { ProviderNote(text: testStatus) }
            }
        }
    }

    private func testConnection() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let probe = try await appModel.testProviderConnection(.init(
                id: "anthropic_oauth_direct", authMode: "oauth", secret: nil, displayedRevision: nil))
            testStatus = probe.result.error ?? probe.result.detail ?? probe.result.status
        } catch { testStatus = error.localizedDescription }
    }
}
