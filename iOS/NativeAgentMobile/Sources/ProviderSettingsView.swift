// Phone credential entry is encrypted for the Mac's Keychain and verification.
// Model selections are accepted only after a matching verified Mac tuple.
import SwiftUI
import NativeAgentShared
// Blueprint: | `ProviderSettingsView.swift` | `ProviderSettingsView` struct |

/// Unknown or malformed wire keys remain explicit repair conditions.
extension ProviderSurfaceLabel {
    var text: String {
        switch self {
        case .named(let label): label
        case .unrecognized(let surface): "Unrecognized surface (\(surface))"
        case .malformed: "Surface label unavailable"
        }
    }
}

/// Model pins are Mac-owned and arrive in `surfaceModels`. Keep their visible
/// state separate from an absent projection: a published pin must always be
/// shown verbatim, while a missing row says the phone is still waiting for the
/// Mac instead of looking like an intentional unset selection.
enum MobileProviderSurfaceModelMenuPresentation {
    static let unpublishedLabel = "Model not published"

    static func label(for surface: String, surfaceModels: [String: NAProviderSurfaceSelection]) -> String {
        guard let rawModel = surfaceModels[surface]?.model else {
            return unpublishedLabel
        }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return unpublishedLabel
        }
        return model
    }
}

/// A signed action reply proves a provider test passed only when the Mac uses
/// its explicit `ok` status. An absent or unfamiliar payload is an incomplete
/// test result, not evidence that the connection works.
enum ProviderConnectionTestPresentation {
    static func feedback(status: String, successPrefix: String = "Test complete.") -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: Mac did not return a test result."
        }
        guard trimmed.lowercased() == "ok" else {
            if ["error", "failed", "needs_credentials"].contains(trimmed.lowercased()) {
                return "Error: \(trimmed)"
            }
            return "Error: Mac returned an unrecognized test status: \(trimmed)"
        }
        return successPrefix
    }
}

// MARK: - Main View

struct ProviderSettingsView: View {
    private struct Selection {
        let providerID: String
        let modelID: String
    }
    private let sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore

    private var renderedSurfaces: [String] { ProviderSurfaceGroups.all.compactMap { $0.surfaces.first } }

    private func groupCaption(_ surface: String) -> String {
        ProviderSurfaceGroups.all.first { $0.surfaces.contains(surface) }?.caption ?? ""
    }

    @State private var configSheet: ProviderInfo? = nil
    @State private var statusText = ""
    @State private var isRefreshing = false

    /// The Mac's provider projection (a DEBUG design sample when there is none).
    private var providers: [ProviderInfo] {
        #if DEBUG
        if MobileDesignSamples.screen != nil, sync.providers.isEmpty { return ProviderDesignSample.providers }
        #endif
        return sync.providers
    }

    private var selectableProviders: [ProviderInfo] {
        providers.filter { $0.auth_status.eligible }
    }

    var body: some View {
        AlivePage(title: "Providers", line: "The models I think with.") {
            if !pairingStore.isPaired { AliveUnpairedReason() }
            providersSection
            modelsSection
            if !statusText.isEmpty {
                AliveFootnote(statusText)
            }
        }
        .macSyncErrorBanner()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refreshProviders() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundStyle(AlivePalette.text)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh providers")
            }
        }
        .sheet(item: $configSheet) { provider in
            ProviderDetailSheet(provider: provider, onDone: {
                configSheet = nil
            })
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-designDetail") { configSheet = providers.first }
            #endif
            if sync.surfaceModels.isEmpty || sync.providers.isEmpty {
                Task {
                    _ = await iCloudBridge.shared.drainDeviceTransport()
                    await sync.refreshProviderControlsSnapshot()
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var providersSection: some View {
        if providers.isEmpty && !isRefreshing {
            AliveCalmState(
                title: "No providers yet",
                line: "Keep NativeAgent open on the Mac. Its providers appear here once iCloud catches up."
            )
        } else {
            AliveSection("Connected", trailing: {
                if isRefreshing { ProgressView().controlSize(.small) }
            }) {
                if providers.isEmpty {
                    AliveRow("Refreshing…")
                }
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { AliveDivider() }
                    Button {
                        configSheet = provider
                    } label: {
                        AliveRow(provider.display_name, detail: ProviderWords.statusLine(for: provider)) {
                            AliveChevron()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modelsSection: some View {
        AliveSection("Models", footer: "Each choice applies to every activity listed in its group. Work and Memory and mind follow Chat until configured.") {
            if selectableProviders.isEmpty {
                Text("Connect a provider on the Mac to choose models here.")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .aliveRow()
            } else {
                ForEach(Array(renderedSurfaces.enumerated()), id: \.element) { index, surface in
                    if index > 0 { AliveDivider() }
                    surfaceRow(surface)
                    AliveNote(groupCaption(surface))
                }
            }
        }
    }

    /// One routing group and its exact provider/model pair.
    private func surfaceRow(_ surface: String) -> some View {
        let providerID = sync.surfaceModels[surface]?.providerID ?? ""
        let providerName = selectableProviders.first(where: { $0.provider_id == providerID })?.display_name
        return Menu {
            ForEach(selectableProviders) { provider in
                Section(provider.display_name) {
                    ForEach(provider.models) { model in
                        Button {
                            submitSelection(
                                surface: surface,
                                selection: .init(providerID: provider.provider_id, modelID: model.id)
                            )
                        } label: {
                            if provider.provider_id == providerID && model.id == selectedModelLabel(for: surface) {
                                Label(ProviderWords.modelName(model), systemImage: "checkmark")
                            } else {
                                Text(ProviderWords.modelName(model))
                            }
                        }
                    }
                }
            }
        } label: {
            // The short model name leads; the provider is in the menu's sections.
            AliveRow(surfaceLabel(surface), detail: modelLabel(for: surface, providerID: providerID), detailLines: 1) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
            }
        }
        .buttonStyle(.plain)
        .aliveUnavailable(!pairingStore.isPaired)
        .accessibilityValue(providerName.map { "\(modelLabel(for: surface, providerID: providerID)), \($0)" } ?? "")
        .accessibilityHint("Choose the model for \(surfaceLabel(surface)).")
    }

    /// The published model, by its display name when the provider lists it.
    private func modelLabel(for surface: String, providerID: String) -> String {
        let id = selectedModelLabel(for: surface)
        guard let model = providers.first(where: { $0.provider_id == providerID })?.models.first(where: { $0.id == id }) else { return id }
        return ProviderWords.modelName(model)
    }

    // MARK: - Helpers

    private func refreshProviders() async {
        isRefreshing = true
        _ = await iCloudBridge.shared.drainDeviceTransport()
        let outcome = await iCloudSyncEngine.shared.refreshProviderControlsSnapshot()
        statusText = outcome.feedbackMessage ?? ""
        isRefreshing = false
    }

    private func submitSelection(surface: String, selection: Selection) {
        let preference = sync.surfaceModels[surface]
        Task {
            do {
                guard !selection.modelID.isEmpty else {
                    throw NSError(
                        domain: "ProviderSettingsView", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "That provider has no selectable model."]
                    )
                }
                try await sync.configureSurfaceSelection(
                    surface: surface,
                    providerId: selection.providerID,
                    model: selection.modelID,
                    reasoningEffort: preference?.reasoningEffort ?? "high",
                    serviceTier: preference?.serviceTier ?? "default"
                )
                statusText = "\(surfaceLabel(surface)) now uses \(selectedModelLabel(for: surface))."
            } catch {
                statusText = "Error: \(error.localizedDescription)"
                SystemToastCenter.shared.push(
                    error: "Couldn't update \(surfaceLabel(surface)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func selectedModelLabel(for surface: String) -> String {
        return MobileProviderSurfaceModelMenuPresentation.label(
            for: surface,
            surfaceModels: sync.surfaceModels
        )
    }

    private func surfaceLabel(_ surface: String) -> String {
        ProviderSurfaceGroups.all.first { $0.surfaces.contains(surface) }?.title
            ?? ProviderSurfaceLabel.presentation(for: surface).text
    }
}

#if DEBUG
/// Screenshot fixture for `-designScreen providers`: two ready providers with
/// models, so the activity rows have something to show.
private enum ProviderDesignSample {
    static let providers: [ProviderInfo] = [
        sample("design-writing", "Research and long-form writing", models: [
            ("writer-large", "Writer Large", true), ("writer-fast", "Writer Fast", false),
        ]),
        sample("design-local", "On-device models", models: [("local-small", "Local Small", false)]),
    ]

    private static func sample(_ id: String, _ name: String, models: [(String, String, Bool)]) -> ProviderInfo {
        ProviderInfo(
            provider_id: id, display_name: name, auth_modes: ["api_key"],
            auth_status: ProviderAuthStatus(provider_id: id, state: "ready", detail: "Connected and answering.",
                                            user_info: ["plan": "Team"], last_checked_at: nil, eligible: true),
            models: models.map {
                ProviderModelInfo(id: $0.0, name: $0.1, context_length: 200_000, supports_streaming: true,
                                  supports_vision: $0.2, supports_tools: true, supports_json_mode: $0.2)
            }
        )
    }
}
#endif

/// Provider ids, states and auth modes as words.
enum ProviderWords {
    static func state(_ raw: String) -> String {
        switch raw {
        case "ready": return "Ready"
        case "saved": return "Saved, not yet checked"
        case "failed": return "Could not check"
        case "rejected": return "Key rejected"
        case "needs_key": return "Needs a key"
        case "needs_oauth": return "Needs sign-in"
        default: return AliveWords.humanized(raw)
        }
    }

    static func authMode(_ raw: String) -> String {
        switch raw {
        case "api_key": return "API key"
        case "oauth": return "account sign-in"
        default: return AliveWords.humanized(raw).lowercased()
        }
    }

    static func statusLine(for provider: ProviderInfo) -> String {
        let modes = provider.auth_modes.map(authMode).joined(separator: " or ")
        return [state(provider.auth_status.state), modes].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func modelName(_ model: ProviderModelInfo) -> String {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.id : name
    }

    static func capabilities(_ model: ProviderModelInfo) -> String {
        var words: [String] = []
        if model.supports_streaming { words.append("streams") }
        if model.supports_vision { words.append("sees images") }
        if model.supports_tools { words.append("uses tools") }
        if model.supports_json_mode { words.append("JSON mode") }
        guard let first = words.first else { return "No extra capabilities published" }
        words[0] = first.prefix(1).uppercased() + first.dropFirst()
        return words.joined(separator: " · ")
    }
}

// MARK: - Detail / action sheet

struct ProviderDetailSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    private let sync = iCloudSyncEngine.shared
    @State private var apiKey = ""
    @State private var signInRequestID: String?
    @State private var isWorking = false
    @State private var workLabel = ""
    @State private var feedbackText = ""

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider
        self.onDone = onDone
    }

    var body: some View {
        let provider = sync.providers.first(where: { $0.provider_id == self.provider.provider_id }) ?? self.provider
        NavigationStack {
            AlivePage(title: provider.display_name,
                     line: ProviderWords.state(provider.auth_status.state)) {
                // ── Status ────────────────────────────────────────────────
                let userInfo = Array((provider.auth_status.user_info ?? [:]).sorted { $0.key < $1.key }.prefix(3))
                if !provider.auth_status.detail.isEmpty || !userInfo.isEmpty {
                    AliveSection("Status") {
                        if !provider.auth_status.detail.isEmpty {
                            AliveRow(provider.auth_status.detail)
                        }
                        ForEach(Array(userInfo.enumerated()), id: \.element.key) { index, kv in
                            if index > 0 || !provider.auth_status.detail.isEmpty { AliveDivider() }
                            AliveRow(AliveWords.humanized(kv.key)) {
                                Text(kv.value)
                                    .font(.body)
                                    .foregroundStyle(AlivePalette.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                // ── Models and what each can do ───────────────────────────
                AliveSection("Models") {
                    if provider.models.isEmpty {
                        AliveRow("Not published yet",
                                detail: "The Mac hasn’t published this provider’s models and what they can do.")
                    }
                    ForEach(Array(provider.models.enumerated()), id: \.offset) { index, model in
                        if index > 0 { AliveDivider() }
                        AliveRow(ProviderWords.modelName(model), detail: ProviderWords.capabilities(model))
                    }
                }

                // ── Credentials are owned and checked by the Mac ───────────
                if provider.auth_modes.contains("api_key") || provider.auth_modes.contains("oauth") {
                    AliveSection("Sign-in") {
                        if provider.auth_modes.contains("api_key") {
                            SecureField("API key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isWorking)
                            Button(isWorking && workLabel == "save" ? "Saving and checking…" : "Save and verify key") {
                                sendAction("save")
                            }
                            .disabled(isWorking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            AliveFootnote("Encrypted for your paired Mac and saved in its Keychain. The Mac checks the connection.")
                        }
                        if provider.auth_modes.contains("oauth") {
                            if provider.auth_modes.contains("api_key") { AliveDivider() }
                            if ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(provider.provider_id) {
                                Button("Sign in on Mac") { sendAction("oauth") }
                                    .disabled(isWorking)
                                AliveFootnote("Finish sign-in in the browser on your Mac. Its result will appear here.")
                            } else {
                                AliveRow("Account sign-in", detail: "This provider’s sign-in must be managed on the Mac.")
                            }
                        }
                    }
                }

                // ── The one action ────────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        sendAction("test")
                    } label: {
                        Text(isWorking && workLabel == "test" ? "Testing…" : "Test connection")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .alivePrimaryButton()
                    .controlSize(.large)
                    .disabled(isWorking)

                    if feedbackText.isEmpty {
                        AliveFootnote("The test runs on the Mac. The result shows here when it finishes.")
                    } else {
                        Text(feedbackText)
                            .font(.footnote)
                            .foregroundStyle(feedbackText.hasPrefix("Error")
                                             ? NativeAgentMobileTheme.Colors.trouble : AlivePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDone() }
                        .foregroundStyle(AlivePalette.text)
                }
            }
            .onDisappear { apiKey = "" }
            .onChange(of: sync.providerSignIns) { _, _ in applySignInState() }
            .onAppear { applySignInState() }
        }
    }

    // MARK: - Actions

    private func sendAction(_ kind: String) {
        isWorking = true
        workLabel = kind
        feedbackText = kind == "oauth" ? "Waiting for sign-in on your Mac…" : ""
        let submittedKey = kind == "save" ? apiKey : ""
        Task {
            do {
                switch kind {
                case "oauth":
                    signInRequestID = try await sync.startProviderSignIn(providerId: provider.provider_id)
                    isWorking = false
                    applySignInState()
                case "save":
                    feedbackText = try await sync.configureProvider(
                        providerId: provider.provider_id, apiKey: submittedKey
                    )
                    if apiKey == submittedKey { apiKey = "" }
                    isWorking = false
                    _ = await sync.refreshProviderControlsSnapshot()
                case "test":
                    let status = try await iCloudSyncEngine.shared.testProvider(providerId: provider.provider_id)
                    finish(status: status, successPrefix: "Test complete.")

                default:
                    isWorking = false
                }
            } catch {
                feedbackText = "Error: \(error.localizedDescription)"
                isWorking = false
            }
        }
    }

    private func applySignInState() {
        if signInRequestID == nil, !isWorking {
            signInRequestID = sync.providerSignIns[provider.provider_id]?["request_id"]
        }
        guard let requestID = signInRequestID,
              let state = sync.providerSignIns[provider.provider_id],
              state["request_id"] == requestID else { return }
        switch state["state"] {
        case "pending":
            workLabel = "oauth"
            feedbackText = "Waiting for sign-in on your Mac…"
        case "signed_in":
            isWorking = false
            feedbackText = "Sign-in completed on Mac."
        case "failed":
            isWorking = false
            feedbackText = "Error: Sign-in did not complete on the Mac. It may have been canceled; try again there."
        default: break
        }
    }

    private func finish(status: String, successPrefix: String) {
        isWorking = false
        feedbackText = ProviderConnectionTestPresentation.feedback(
            status: status,
            successPrefix: successPrefix
        )
    }
}
