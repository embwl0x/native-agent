import SwiftUI
import NativeAgentShared
import ProviderRouting
import EngineRuntime
import Foundation
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import AppKit
import AppToolRuntime
// Blueprint: | `ClaudeConnectionPanels.swift` | Direct Anthropic OAuth sign-in and setup-token connection panel |

enum AnthropicOAuthDirectPanelPresentation {
    static let title = "Connect via Anthropic OAuth"
    static let detail = "Full capability API access (streaming, vision, tools) using your own OAuth credentials."
}

struct AnthropicOAuthDirectPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AnthropicOAuthDirectPanelPresentation.title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            ProviderNote(text: AnthropicOAuthDirectPanelPresentation.detail)
            // Read sign-in from its canonical store so provider-list staleness cannot hide current state.
            OAuthSignInButton(provider: .anthropic)
            AnthropicSetupTokenInput()
        }
    }
}
