import SwiftUI
import Foundation
import NativeAgentShared
import ProviderRouting
import PersistenceCore
// Blueprint: | `ProviderSettingsView.swift` | ProviderSettingsView owns account and activity draft state and composes their columns |

struct ProviderSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State var inlineReceipts: [String: SaveReceipt] = [:]

    init() {}

    // Opaque local surfaces keep secondary text legible over the shell wallpaper.
    var secondaryInk: Color { colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.28) }

    @Environment(AppModel.self) var appModel
    var providers: [ProviderInfo] { appModel.engine.providers.connections }
    @State var isLoading = false
    @State var refreshCatalogNote: String?
    /// Refresh errors remain separate from save/configure status.
    var providerLoadError: String? { appModel.engine.providers.settingsError }
    @State var configureSheet: String? = nil
    @State var status = (text: "", kind: SystemToast.Kind.info)

    // Only in-flight edits overlay the facade's committed routing.
    @State var pendingSelections: [String: ProviderTurnChoice] = [:]
    @State var groupSaveTokens: [String: UUID] = [:]
    @State var groupSaveTasks: [String: Task<Void, Never>] = [:]
    @State var savingGroups: Set<String> = []

    var body: some View {
        // Keep account setup and ordinary chat visible together; other model
        // choices are optional and start folded away.
        HStack(alignment: .top, spacing: 20) {
            providerListColumn
                .frame(maxWidth: 280)

            perSurfacePickerColumn
                // Reserve the complete control row, including card insets,
                // without taking the account column's share of the page.
                .frame(minWidth: 530)
        }
        .sheet(isPresented: Binding(get: { configureSheet != nil }, set: { if !$0 { configureSheet = nil } })) {
            if let provider = providers.first(where: { $0.provider_id == configureSheet }) {
            VStack(alignment: .leading, spacing: 12) {
                if provider.provider_id == "openai_oauth_direct" || provider.provider_id == "codex" {
                    // Account sign-in and reconnect actions remain directly visible.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider.auth_status.eligible ? "Reconnect ChatGPT account" : "Sign in with ChatGPT")
                            .font(ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        OAuthSignInButton(provider: .chatgpt)
                    }
                    .padding([.top, .horizontal], 20)
                }
            ProviderConfigSheet(provider: provider) {
                configureSheet = nil
            }
            }
            .environment(appModel)
            }
        }
        .quietReadTask { await loadProviders() }
    }
}
