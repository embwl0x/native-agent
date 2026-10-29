import SwiftUI
import Foundation
import NativeAgentShared
import ProviderRouting
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import AppKit
import AppToolRuntime
// Blueprint: | `ProviderAccounts.swift` | Provider account rows, sign-in presentation and catalog refresh; ProviderSettingsView keeps page state |

// Onboarding and Providers share this account row.
struct ProviderRowView: View {
    let provider: ProviderInfo
    let onConfigure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: providerIcon(provider.provider_id))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.tertiary)
                .frame(width: 24)
            Text(provider.display_name)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let status = ProviderStatusWord.word(for: provider.auth_status.state) {
                ProviderStatusWord(text: status.text, kind: status.kind)
            }
            Button("Set up") {
                onConfigure()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(ShellType.labelMedium)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerIcon(_ id: String) -> String {
        switch id {
        case "codex":             return "sparkles"
        case "anthropic", "anthropic_mcp", "anthropic_oauth_direct": return "brain"
        case "xai", "xai_oauth_direct": return "sparkles"
        case "openrouter":        return "shuffle"
        case "moonshot":          return "moon.stars.fill"
        case "kimi-code":         return "curlybraces"
        case "openai":            return "cpu"
        default:                  return "server.rack"
        }
    }
}

/// Refresh distinguishes an unreadable authority from a successfully empty catalog.
enum ProviderSettingsRefreshPresentation: Equatable {
    case empty
    case unavailable(String)
    case available

    static func resolve(providerCount: Int, loadError: String?) -> Self {
        guard providerCount == 0 else { return .available }
        guard let loadError,
              !loadError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .unavailable(loadError)
    }
}

/// Show the account's own evidence; an unconfigured account offers Set up.
enum ProviderAccountStateLinePresentation {
    static func line(_ status: ProviderAuthStatus) -> String? {
        status.eligible || status.state == "rejected" ? status.detail : nil
    }
}

extension ProviderSettingsView {
    @ViewBuilder
    private func accountRow(_ provider: ProviderInfo) -> some View {
        if !provider.auth_status.eligible {
            Button {
                configureSheet = provider.provider_id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.display_name)
                            .font(ShellType.rowTitle)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = ProviderAccountStateLinePresentation.line(provider.auth_status) {
                            Text(line)
                                .font(ShellType.rowDetail).foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(provider.auth_modes.contains("api_key") ? "API key" : "Sign in")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                    Image(systemName: "chevron.right")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set up \(provider.display_name), \(provider.auth_modes.contains("api_key") ? "API key" : "account sign-in")")
        } else {
            // One row: the name, its status under it, Manage on the right.
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.display_name)
                        .font(ShellType.rowTitle)
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ProviderAccountStateLinePresentation.line(provider.auth_status) ?? "")
                        .font(ShellType.rowDetail).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(provider.auth_modes.map { mode in
                        switch mode {
                        case "api_key": "API key"
                        case "oauth": "Account sign-in"
                        default: mode.replacingOccurrences(of: "_", with: " ")
                        }
                    }.joined(separator: " · "))
                        .font(ShellType.rowDetail).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Manage") {
                    configureSheet = provider.provider_id
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Manage \(provider.display_name)")
            }
        }
    }

    /// Account setup, sign-ins and refresh.
    @ViewBuilder
    var providerListColumn: some View {
        ScrollView {
            // Account/configuration cards can extend well below the viewport.
            // Keep their model state in this page, but measure visible content.
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Choose an account and a chat model. Model changes save immediately.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AdvancedSection(title: "Accounts & API keys", card: .bare) {
                    VStack(alignment: .leading, spacing: 8) {
                        if isLoading && providers.isEmpty {
                            ProviderCard {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Reading the accounts…")
                                        .font(ShellType.label)
                                        .foregroundStyle(secondaryInk)
                                }
                            }
                        } else if case let .unavailable(detail) = ProviderSettingsRefreshPresentation.resolve(
                            providerCount: providers.count,
                            loadError: providerLoadError
                        ) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProviderCardTitle(
                                        title: "The accounts could not be read",
                                        line: detail
                                    )
                                }
                            }
                        } else if providers.isEmpty {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "No accounts yet",
                                    line: "Expand Sign in below, or press Refresh to read accounts on this Mac."
                                )
                            }
                        } else {
                            // One group card, a row per account, hairlines between.
                            AliveGroupCard {
                                ForEach(providers.sorted { ($0.auth_status.eligible ? 0 : 1, $0.display_name) < ($1.auth_status.eligible ? 0 : 1, $1.display_name) }) { provider in
                                    accountRow(provider)
                                }
                            }
                        }

                        Button(isLoading ? "Refreshing…" : "Refresh") {
                            Task { await loadProviders(refreshCatalog: true) }
                        }
                        .buttonStyle(.bordered)
                        .font(ShellType.labelMedium)
                        .disabled(isLoading)
                        if !providers.isEmpty, let providerLoadError {
                            Text(providerLoadError)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup("Sign in, reconnect or add an account") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "ChatGPT",
                                    line: "Sign in with your ChatGPT Plus or Pro account in the browser."
                                )
                                OAuthSignInButton(provider: .chatgpt)
                            }
                        }

                        // Direct Anthropic OAuth shares the CLI's public client ID for token compatibility.
                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "Anthropic",
                                    line: "Two ways in. A setup token is the route Anthropic recommends for outside apps; make one at console.anthropic.com, under Settings then OAuth."
                                )
                                OAuthSignInButton(provider: .anthropic)
                                AnthropicSetupTokenInput()
                            }
                        }

                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "xAI",
                                    line: "Sign in with xAI to use Grok models. This is separate from the X connector; the token stays in this app's own store."
                                )
                                OAuthSignInButton(provider: .xai)
                            }
                        }
                    }
                }

                // Telegram settings own the config; this section links there.
                AdvancedSection(title: "Telegram", card: .bare) {
                    ProviderCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ProviderCardTitle(
                                title: "Telegram lives on its own page",
                                line: "The bot token, who may write in, and the model it answers with are all on the Telegram page."
                            )
                            Button("Open Telegram") {
                                let receipt = ApplicationLifetime.shared.request(.sidebar(.telegram))
                                switch receipt {
                                case .deliveredToMountedScene:
                                    status = ("Telegram settings request delivered to the main window.", .info)
                                case .queuedForMainScene:
                                    status = ("Telegram settings will open when the main window is ready.", .info)
                                }
                            }
                            .buttonStyle(.bordered)
                            .font(ShellType.labelMedium)
                        }
                    }
                }

                let text = status.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !text.isEmpty {
                    Text(text.count > 220 ? String(text.prefix(220)) + "…" : text)
                        .font(ShellType.caption)
                        .foregroundStyle(statusColor(status.kind))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        // Selectable text must not also carry a custom accessibility label; SwiftUI AX loops.
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .navigationTitle("Providers")
    }

    func loadProviders(refreshCatalog: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await appModel.engine.providers.refreshSettings(
            refreshCatalog: refreshCatalog, cause: UserFacingError.cause
        ) {
        case let .loaded(snapshot):
            var kind: SystemToast.Kind = .info
            if let catalogError = snapshot.catalogError {
                refreshCatalogNote = "couldn't load models: \(catalogError)"
                kind = .error
            } else if refreshCatalog {
                switch snapshot.catalog?.catalogFreshness
                    .flatMap(ModelCatalogFreshness.init(rawValue:)) {
                case .staleAfterFailedRefresh, .unavailable:
                    kind = .warn
                    refreshCatalogNote = snapshot.catalog?.catalogNote ?? "couldn't load models"
                case .cached:
                    refreshCatalogNote = "model catalog unchanged, showing the cached list"
                case .liveIncomplete:
                    kind = .warn
                    refreshCatalogNote = "model catalog refreshed; the provider's list may be partial"
                case .live, .none:
                    refreshCatalogNote = nil
                }
            } else {
                refreshCatalogNote = nil
            }
            let loadedText = rowSet.unsupportedStoredKeys.isEmpty
                ? "Providers loaded at \(shortTime())"
                : "Provider settings need repair before every saved activity can be configured."
            if !rowSet.unsupportedStoredKeys.isEmpty, kind != .error { kind = .warn }
            status = (refreshCatalogNote.map { "\(loadedText) — \($0)" } ?? loadedText, kind)
        case let .failed(detail):
            status = ("Couldn't read the accounts. \(detail)", .error)
        }
    }

    private func statusColor(_ tone: SystemToast.Kind) -> Color {
        switch tone {
        case .info: return NativeAgentShell.secondary
        case .success: return NativeAgentShell.calm
        // Warnings and failures share the attention colour; their words distinguish them.
        case .warn, .error: return NativeAgentShell.trouble
        }
    }

    private func shortTime() -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f.string(from: Date())
    }
}
