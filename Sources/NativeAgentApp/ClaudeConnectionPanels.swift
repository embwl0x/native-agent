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
// Blueprint: | `ClaudeConnectionPanels.swift` | Claude connection panels show CLI availability, persistent process evidence and direct OAuth sign-in |

struct AnthropicMCPStatusPresentation: Equatable {
    enum ProcessStatus: Equatable {
        case alive
        case notRunning
        case unavailable

        var label: String {
            switch self {
            case .alive: "Process alive"
            case .notRunning: "Not running"
            case .unavailable: "Process status unavailable"
            }
        }

        var badgeStatus: String {
            switch self {
            case .alive: "ok"
            case .notRunning, .unavailable: "warn"
            }
        }
    }

    let headline: String?
    let cliBadge: String
    let cliBadgeStatus: String
    let detail: String?
    let version: String?
    let mode: String?
    let processStatus: ProcessStatus?

    static func make(
        availability: AnthropicMCPCLIProbe.Availability,
        userInfo: [String: String]?
    ) -> Self {
        switch availability {
        case .checking:
            return Self(
                headline: nil,
                cliBadge: "Checking Claude CLI…",
                cliBadgeStatus: "warn",
                detail: nil,
                version: nil,
                mode: nil,
                processStatus: nil
            )
        case .unavailable(let reason):
            return Self(
                headline: nil,
                cliBadge: "Claude CLI unavailable",
                cliBadgeStatus: "error",
                detail: reason,
                version: nil,
                mode: nil,
                processStatus: nil
            )
        case .available:
            let mode = userInfo?["mode"]
            let processStatus: ProcessStatus
            switch userInfo?["mcp_process_alive"]?.lowercased() {
            case "true": processStatus = .alive
            case "false": processStatus = .notRunning
            default: processStatus = .unavailable
            }
            return Self(
                headline: processStatus == .alive
                    ? "Persistent connection via Claude CLI"
                    : nil,
                cliBadge: "Claude CLI available",
                cliBadgeStatus: "ok",
                detail: processStatus == .alive
                    ? nil
                    : "Claude CLI is available, but no persistent MCP process is confirmed.",
                version: userInfo?["version"],
                mode: mode == "mcp_server" ? "MCP server" : "per-call stream",
                processStatus: processStatus
            )
        }
    }
}

struct AnthropicMCPStatusPanel: View {
    let provider: ProviderInfo
    let appModel: AppModel

    @State private var testResult: String = ""
    @State private var isTesting = false
    @State private var cliAvailability: AnthropicMCPCLIProbe.Availability = .checking

    var body: some View {
        let presentation = AnthropicMCPStatusPresentation.make(
            availability: cliAvailability,
            userInfo: provider.auth_status.user_info
        )
        VStack(alignment: .leading, spacing: 8) {
            if let headline = presentation.headline {
                Text(headline)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
            }
            HStack(spacing: 12) {
                ProviderStatusWord(text: presentation.cliBadge, kind: presentation.cliBadgeStatus)
                if let version = presentation.version {
                    Text(version)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                if let mode = presentation.mode {
                    Text(mode)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                if let processStatus = presentation.processStatus {
                    ProviderStatusWord(text: processStatus.label, kind: processStatus.badgeStatus)
                }
            }
            if let detail = presentation.detail {
                ProviderNote(text: detail)
            }
            Button(isTesting ? "Testing…" : "Test the connection") {
                Task { await runPersistentTest() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(ShellType.labelMedium)
            .disabled(isTesting)
            if !testResult.isEmpty {
                ProviderNote(text: testResult)
            }
        }
        .task(id: provider.auth_status.last_checked_at) {
            let availability = await Task.detached(priority: .userInitiated) { AnthropicMCPCLIProbe.probe() }.value
            guard !Task.isCancelled else { return }
            cliAvailability = availability
        }
    }

    private func runPersistentTest() async {
        isTesting = true
        testResult = ""
        cliAvailability = await Task.detached(priority: .userInitiated) { AnthropicMCPCLIProbe.probe() }.value
        if case .unavailable(let reason) = cliAvailability {
            testResult = reason
            isTesting = false
            return
        }
        do {
            let result = try await appModel.engine.providers.testProvider(provider.provider_id)
            if result.tested {
                testResult = result.response ?? result.error ?? "ok"
            } else {
                testResult = result.detail ?? result.status
            }
        } catch {
            testResult = UserFacingError.message(error, action: "test \(provider.display_name)")
        }
        isTesting = false
    }
}

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
            // Sign-in reads its canonical store, independent of the provider-list snapshot.
            OAuthSignInButton(provider: .anthropic)
            AnthropicSetupTokenInput()
        }
    }
}
