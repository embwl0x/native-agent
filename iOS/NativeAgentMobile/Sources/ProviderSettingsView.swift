// PATCH-2026-07-15: iOS ProviderSettingsView — signed remote control for the
// Mac-owned provider configuration. API keys are never stored or edited here;
// atomic surface selections and connection tests cross the authenticated action
// channel and are accepted only after the Mac returns a matching verified tuple.
import SwiftUI

/// Keeps the refresh button honest once its spinner stops: a failed provider
/// snapshot refresh remains visible instead of looking like an empty success.
enum ProviderRefreshPresentation {
    static func statusText(for outcome: ProviderControlsRefreshOutcome) -> String {
        outcome.feedbackMessage ?? ""
    }
}

/// iOS cannot import the Mac-only provider-routing module, so it retains a
/// presentation mirror for the canonical routing surfaces. Unknown or malformed
/// wire keys must read as a repair condition, never as a plausible prettified
/// storage key such as `Cognition_reflection`.
enum MobileProviderSurfaceLabelPresentation: Equatable {
    case named(String)
    case unrecognized(String)
    case malformed

    private static let namedLabels: [String: String] = [
        "chat": "Chat",
        "ios": "iPhone",
        "telegram": "Telegram",
        "slack": "Slack",
        "desk": "Desk",
        "workshop": "Desk tasks",
        "missions": "Desk tasks",
        "autonomy": "Autonomy",
        "swarms": "Swarms",
        "dream": "Dream",
        "rem": "REM",
        "training": "Training",
        "memory": "Memory",
        "heartbeat": "Heartbeat",
        "diagnostics": "Diagnostics",
        "cognition_reflection": "Cognition Reflection",
        "studio_wander": "Studio Wandering",
        "compaction": "Compaction",
        "self_improvement": "Self-Improvement",
    ]

    static func presentation(for rawSurface: String) -> Self {
        let trimmed = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == rawSurface, rawSurface == rawSurface.lowercased() else {
            return .malformed
        }
        guard let label = namedLabels[rawSurface] else { return .unrecognized(rawSurface) }
        return .named(label)
    }

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

    static func label(for surface: String, surfaceModels: [String: SurfaceModelPref]) -> String {
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

/// A response may arrive after the user has picked another tuple, so only the
/// request that still owns a surface may restore its former selection.
enum ProviderSelectionRollbackPresentation {
    struct Selection: Equatable {
        let providerID: String
        let modelID: String
    }

    static func rollback(
        currentGeneration: UInt64,
        requestGeneration: UInt64,
        previous: Selection
    ) -> Selection? {
        currentGeneration == requestGeneration ? previous : nil
    }

    static func acceptReceipt(
        _ receipt: MobileSurfaceSelectionReceipt,
        currentGeneration: UInt64,
        requestGeneration: UInt64
    ) -> Selection? {
        guard currentGeneration == requestGeneration else { return nil }
        return Selection(providerID: receipt.providerID, modelID: receipt.model)
    }
}


// MARK: - Main View

struct ProviderSettingsView: View {
    @StateObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore

    // Presentation mirror of ProviderSurfaceGroups. Submit one representative
    // surface; the Mac applies the choice to every member of its group.
    private var renderedSurfaces: [String] {
        ["chat", "desk", "memory"]
    }

    private func groupCaption(_ surface: String) -> String {
        switch surface {
        case "chat": "Chat, iPhone, Telegram and Slack"
        case "desk": "Desk, Task execution, Independent tasks, Coordinated tasks, Skill practice, Background check-ins and Diagnostics"
        case "memory": "Memory, Dreams, REM, Reflection, Conversation summaries, Learning and Creative exploration"
        default: ""
        }
    }

    // Active provider per surface (local UI state; saves on change)
    @State private var activeSurface: [String: String] = [:]
    @State private var requestedModel: [String: String] = [:]
    @State private var pendingSurfaceReceipts: [String: MobileSurfaceSelectionReceipt] = [:]
    @State private var selectionGeneration: [String: UInt64] = [:]
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
        providers.filter { $0.auth_status.state == "ready" }
    }

    private var defaultProviderID: String {
        selectableProviders.first?.provider_id ?? ""
    }

    private func selectableModels(for providerID: String) -> [ProviderModelInfo] {
        providers.first(where: { $0.provider_id == providerID })?.models ?? []
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
            seedActiveSurface()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-designDetail") { configSheet = providers.first }
            #endif
            if sync.surfaceModels.isEmpty || sync.providers.isEmpty {
                Task {
                    _ = await iCloudBridge.shared.drainDeviceTransport()
                    await sync.refreshProviderControlsSnapshot()
                    seedActiveSurface()
                }
            }
        }
        .onChange(of: sync.providers) { _, _ in
            seedActiveSurface()
        }
        .onChange(of: sync.surfaceModels) { _, _ in
            seedActiveSurface()
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
        let providerID = activeSurface[surface] ?? defaultProviderID
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
        guard let model = selectableModels(for: providerID).first(where: { $0.id == id }) else { return id }
        return ProviderWords.modelName(model)
    }

    // MARK: - Helpers

    private func refreshProviders() async {
        isRefreshing = true
        _ = await iCloudBridge.shared.drainDeviceTransport()
        let outcome = await iCloudSyncEngine.shared.refreshProviderControlsSnapshot()
        seedActiveSurface()
        statusText = ProviderRefreshPresentation.statusText(for: outcome)
        isRefreshing = false
    }

    private func seedActiveSurface() {
        let synced = sync.trustPolicy?.providerPolicy?.activePerSurface ?? [:]
        let readyProviderIds = Set(selectableProviders.map(\.provider_id))
        for surface in renderedSurfaces {
            if let receipt = pendingSurfaceReceipts[surface] {
                guard receipt.isAcknowledged(by: sync.surfaceModels[surface]) else { continue }
                pendingSurfaceReceipts.removeValue(forKey: surface)
            }
            if let providerId = sync.surfaceModels[surface]?.providerId,
               readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
                requestedModel[surface] = sync.surfaceModels[surface]?.model
            } else if let providerId = synced[surface], readyProviderIds.contains(providerId) {
                activeSurface[surface] = providerId
                requestedModel[surface] = nil
            } else {
                activeSurface[surface] = defaultProviderID
                requestedModel[surface] = nil
            }
        }
    }

    private func currentSelection(for surface: String) -> ProviderSelectionRollbackPresentation.Selection {
        let providerID = activeSurface[surface] ?? defaultProviderID
        let modelID = requestedModel[surface]
            ?? sync.surfaceModels[surface]?.model
            ?? ""
        return .init(providerID: providerID, modelID: modelID)
    }

    private func submitSelection(
        surface: String,
        selection: ProviderSelectionRollbackPresentation.Selection
    ) {
        let previous = currentSelection(for: surface)
        let requestGeneration = (selectionGeneration[surface] ?? 0) &+ 1
        selectionGeneration[surface] = requestGeneration
        pendingSurfaceReceipts.removeValue(forKey: surface)
        sendSelection(
            surface: surface,
            selection: selection,
            previous: previous,
            requestGeneration: requestGeneration
        )
    }

    private func sendSelection(
        surface: String,
        selection: ProviderSelectionRollbackPresentation.Selection,
        previous: ProviderSelectionRollbackPresentation.Selection,
        requestGeneration: UInt64
    ) {
        Task {
            do {
                guard !selection.modelID.isEmpty else {
                    throw NSError(
                        domain: "ProviderSettingsView",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "That provider has no selectable model."]
                    )
                }
                let preference = sync.surfaceModels[surface]
                let receipt = try await iCloudSyncEngine.shared.configureSurfaceSelection(
                    surface: surface,
                    providerId: selection.providerID,
                    model: selection.modelID,
                    reasoningEffort: preference?.reasoningEffort ?? "high",
                    serviceTier: preference?.serviceTier ?? "default"
                )
                guard let committed = ProviderSelectionRollbackPresentation.acceptReceipt(
                    receipt, currentGeneration: selectionGeneration[surface] ?? 0,
                    requestGeneration: requestGeneration
                ) else { return }
                activeSurface[surface] = committed.providerID
                requestedModel[surface] = committed.modelID
                pendingSurfaceReceipts[surface] = receipt
                // The signed reply is already authoritative. Do not await a
                // second refresh whose stale snapshot could race a newer pick.
                seedActiveSurface()
                statusText = "\(surfaceLabel(surface)) now uses \(receipt.model)."
            } catch {
                guard let restored = ProviderSelectionRollbackPresentation.rollback(
                    currentGeneration: selectionGeneration[surface] ?? 0,
                    requestGeneration: requestGeneration,
                    previous: previous
                ) else { return }
                activeSurface[surface] = restored.providerID
                requestedModel[surface] = restored.modelID
                statusText = "Error: \(error.localizedDescription)"
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't update \(surfaceLabel(surface)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func selectedModelLabel(for surface: String) -> String {
        if let requested = requestedModel[surface], !requested.isEmpty { return requested }
        return MobileProviderSurfaceModelMenuPresentation.label(
            for: surface,
            surfaceModels: sync.surfaceModels
        )
    }

    private func surfaceLabel(_ surface: String) -> String {
        switch surface {
        case "chat": "Chat"
        case "desk": "Work"
        case "memory": "Memory and mind"
        default: MobileProviderSurfaceLabelPresentation.presentation(for: surface).text
        }
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
                                            user_info: ["plan": "Team"], last_checked_at: nil),
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
        case "needs_key": return "Needs a key"
        case "needs_oauth": return "Needs sign-in"
        case "error": return "Error"
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

    static func capabilities(_ model: ProviderCapabilityPresentation.Model) -> String {
        var words: [String] = []
        if model.supportsStreaming { words.append("streams") }
        if model.supportsVision { words.append("sees images") }
        if model.supportsTools { words.append("uses tools") }
        if model.supportsJSONMode { words.append("JSON mode") }
        guard let first = words.first else { return "No extra capabilities published" }
        words[0] = first.prefix(1).uppercased() + first.dropFirst()
        return words.joined(separator: " · ")
    }
}

enum ProviderCapabilityPresentation {
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let supportsStreaming: Bool
        let supportsVision: Bool
        let supportsTools: Bool
        let supportsJSONMode: Bool
    }

    static func models(from source: [ProviderModelInfo]) -> [Model] {
        source.enumerated().map { index, model in
            let displayName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Model(
                id: "\(index):\(model.id)",
                name: displayName.isEmpty ? model.id : displayName,
                supportsStreaming: model.supports_streaming,
                supportsVision: model.supports_vision,
                supportsTools: model.supports_tools,
                supportsJSONMode: model.supports_json_mode
            )
        }
    }
}


// MARK: - Detail / action sheet

struct ProviderDetailSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    @ObservedObject private var sync = iCloudSyncEngine.shared
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
                let capabilityModels = ProviderCapabilityPresentation.models(from: provider.models)
                AliveSection("Models") {
                    if capabilityModels.isEmpty {
                        AliveRow("Not published yet",
                                detail: "The Mac hasn’t published this provider’s models and what they can do.")
                    }
                    ForEach(Array(capabilityModels.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { AliveDivider() }
                        AliveRow(model.name, detail: ProviderWords.capabilities(model))
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
        let submittedKey = kind == "save" ? apiKey : nil
        Task {
            do {
                switch kind {
                case "oauth":
                    signInRequestID = try await sync.startProviderSignIn(providerId: provider.provider_id)
                    isWorking = false
                    applySignInState()
                case "save":
                    feedbackText = try await sync.configureProvider(
                        providerId: provider.provider_id, apiKey: submittedKey,
                        authMode: "api_key"
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
