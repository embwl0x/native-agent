import SwiftUI
import NativeAgentShared
import Foundation
import ProviderRouting
import PersistenceCore
// Blueprint: | `ProviderConfigSheet.swift` | ProviderConfigSheet holds connection credentials, protected drafts, model defaults and explicit verification |

// Save remains unverified until the user explicitly runs a successful Test Connection.
enum ProviderCredentialVerification: Equatable {
    /// Nothing written or tested in this sheet session.
    case idle
    /// Credential removed or confirmed unavailable.
    case disconnected
    /// Credential written to disk, never checked against the service.
    case savedUnverified
    /// A saved credential without a live probe (`tested:false`) is unverified, not failed.
    case savedNoProbe
    /// Test Connection came back OK.
    case verified
    /// Test Connection ran and did not come back OK.
    case verificationFailed

    /// Save only ever means "written to disk".
    static func afterSave() -> ProviderCredentialVerification { .savedUnverified }

    /// Only a live probe can verify a key or report a probe failure.
    static func afterTest(_ result: NativeAgentShared.ProviderTestResult, credentialReady: Bool) -> ProviderCredentialVerification {
        if result.tested {
            return result.status == "ok" ? .verified : .verificationFailed
        }
        // Before probing, an error means missing credentials; no probe is otherwise unverified.
        if result.status == "error" { return .verificationFailed }
        return credentialReady ? .savedNoProbe : .disconnected
    }

    /// Clearing credentials drops any earlier claim.
    static func afterClear() -> ProviderCredentialVerification { .disconnected }

    /// Provider notes may add detail, never verification.
    func statusText(providerNote: String? = nil) -> String {
        let base: String
        switch self {
        case .idle:
            base = ""
        case .disconnected:
            base = "Not connected."
        case .savedUnverified:
            base = "Saved to this Mac. Not checked yet — press Test Connection to confirm it works."
        case .savedNoProbe:
            base = "Saved to this Mac. This sign-in method has no connection test — it is checked on your first real request."
        case .verified:
            base = "Saved and tested. This provider is working."
        case .verificationFailed:
            base = "The test failed. Check the credentials, then test again."
        }
        guard let note = providerNote, !note.isEmpty else { return base }
        return base.isEmpty ? note : "\(base) \(note)"
    }

    /// Override file-presence readiness until the key is tested.
    var badge: (text: String, status: String)? {
        switch self {
        case .idle: return nil
        case .disconnected: return ("Disconnected", "warn")
        case .savedUnverified: return ("saved · not tested", "warn")
        case .savedNoProbe: return ("saved · no test available", "ok")
        case .verified: return ("tested · working", "ok")
        case .verificationFailed: return ("test failed", "error")
        }
    }
}

/// Save provider defaults only while advertised; absent or stale choices stay visible for replacement.
enum ProviderConfigModelPickerPresentation: Equatable {
    case noCatalog
    case selected
    case staleSelection(String)

    static func resolve(selectedModel: String, advertisedModelIDs: [String]) -> Self {
        guard !advertisedModelIDs.isEmpty else { return .noCatalog }
        return advertisedModelIDs.contains(selectedModel)
            ? .selected
            : .staleSelection(selectedModel)
    }

    var needsReplacement: Bool {
        if case .staleSelection = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .noCatalog:
            return "Model catalog unavailable. Any saved default remains unchanged until models can be loaded."
        case .selected:
            return nil
        case let .staleSelection(model):
            return "Saved default \(model) is not in this provider's current model catalog. Choose a replacement before saving."
        }
    }
}

struct ProviderConfigSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    @Environment(AppModel.self) private var appModel
    // Credentials deliberately die with the sheet; only nonsecret edits belong to the app.
    @State private var apiKey = ""
    private var authMode: String {
        get { appModel.editDraft("provider:\(provider.provider_id):authMode", seed: authModePickerState.selectedMode) }
        nonmutating set { appModel.setEditDraft(newValue, for: "provider:\(provider.provider_id):authMode") }
    }
    private var selectedModel: String {
        get { appModel.editDraft("provider:\(provider.provider_id):model", seed: savedModel) }
        nonmutating set { appModel.setEditDraft(newValue, for: "provider:\(provider.provider_id):model") }
    }
    private var availableModels: [NativeAgentShared.ProviderModelInfo] { provider.models }
    @State private var testResult: NativeAgentShared.ProviderTestResult? = nil
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var credentialRevision = 0
    @State private var statusText = ""
    @State private var showRemoveCredentialsConfirm = false
    @State private var showDiscardKeyConfirm = false
    /// Live verification is independent of file-presence readiness.
    @State private var verification: ProviderCredentialVerification = .idle

    private var authModePickerState: ProvidersFacade.AuthModePickerState {
        ProvidersFacade.authModePickerState(
            advertisedModes: provider.auth_modes,
            savedMode: provider.auth_mode,
            providerIsReady: provider.auth_status.eligible
        )
    }

    private var savedModel: String {
        let model = provider.default_model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? (provider.models.first?.id ?? "") : model
    }

    private func clearDraft() {
        appModel.clearEditDraft("provider:\(provider.provider_id):authMode")
        appModel.clearEditDraft("provider:\(provider.provider_id):model")
    }

    private var modelPickerPresentation: ProviderConfigModelPickerPresentation {
        ProviderConfigModelPickerPresentation.resolve(
            selectedModel: selectedModel,
            advertisedModelIDs: availableModels.map(\.id)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.display_name)
                        .font(ShellType.title)
                        .foregroundStyle(NativeAgentShell.text)
                    // An unverified save cannot claim readiness.
                    if let badge = verification.badge {
                        ProviderStatusWord(text: badge.text, kind: badge.status)
                    } else {
                        let word = ProviderStatusWord.word(for: provider.auth_status.state) ?? ("Not set up", "warn")
                        ProviderStatusWord(text: word.text, kind: word.kind)
                    }
                }
                Spacer(minLength: 8)
                Button("Done") {
                    if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onDone()
                    } else {
                        showDiscardKeyConfirm = true
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .hazeTinted(.button)
                    .controlSize(.regular)
                    .font(ShellType.labelMedium)
                    .disabled(isSaving || isTesting)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if authModePickerState.supportedModes.isEmpty {
                        AdvancedSection(title: "How to sign in", card: .bare) {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "No way in was offered",
                                    line: "This account did not name a sign-in method. Refresh the accounts, or repair its configuration, before saving."
                                )
                            }
                        }
                    } else if authModePickerState.supportedModes.count > 1 {
                        AdvancedSection(title: "How to sign in", card: .bare) {
                            ProviderCard {
                                Picker("Mode", selection: Binding(get: { authMode }, set: {
                                    authMode = $0
                                    invalidateTestFeedback()
                                })) {
                                    ForEach(authModePickerState.supportedModes, id: \.self) { mode in
                                        Text(authModeLabel(mode)).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .hazeTinted(.segments)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }

                    if let repaired = authModePickerState.repairedSavedMode,
                       !authModePickerState.supportedModes.isEmpty {
                        ProviderNote(
                            text: "The saved sign-in method is no longer offered, so \(authModeLabel(authMode)) is being used instead.",
                            color: NativeAgentShell.trouble
                        )
                        .accessibilityLabel("The saved sign-in method \(repaired) is no longer offered.")
                    }

                    // API Key input (shown when api_key mode or provider only supports api_key)
                    if authMode == "api_key" {
                        AdvancedSection(title: "Key", card: .bare) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SecureField("Paste the key here", text: Binding(get: { apiKey }, set: {
                                        apiKey = $0
                                        invalidateTestFeedback()
                                    }))
                                        .textFieldStyle(.roundedBorder)
                                        .font(ShellType.code)
                                    ProviderNote(text: "The key is kept on this Mac only, readable by you alone, and is never written to a log.")
                                }
                            }
                        }
                    }

                    if authMode == "oauth" {
                        AdvancedSection(title: "Sign in", card: .bare) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    if provider.provider_id == "anthropic" {
                                        Text("Use your Claude Pro or Max subscription through the Claude command-line tool instead of paying for credits.")
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let userInfo = provider.auth_status.user_info {
                                            ProviderNote(text: userInfo["version"] ?? "claude command-line tool")
                                        }
                                    } else if provider.provider_id == "anthropic_mcp" {
                                        AnthropicMCPStatusPanel(provider: provider, appModel: appModel)
                                    } else if provider.provider_id == "anthropic_oauth_direct" {
                                        AnthropicOAuthDirectPanel()
                                    } else if provider.provider_id == "xai_oauth_direct" {
                                        Text("Sign in to xAI for Grok models.")
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.text)
                                        OAuthSignInButton(provider: .xai)
                                    }
                                    ProviderNote(text: provider.auth_status.detail)
                                }
                            }
                        }
                    }

                    if !availableModels.isEmpty {
                        AdvancedSection(title: "Model it falls back to", card: .bare) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Model", selection: appModel.editBinding("provider:\(provider.provider_id):model", seed: savedModel)) {
                                        ForEach(availableModels) { model in
                                            Text(model.name).tag(model.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .font(ShellType.label)
                                    ProviderNote(text: "This model is used wherever this provider is selected, unless you choose a different model for that use. You can make those choices on the Providers page.")
                                    if let message = modelPickerPresentation.message {
                                        ProviderNote(text: message, color: NativeAgentShell.trouble)
                                    }
                                    if let model = availableModels.first(where: { $0.id == selectedModel }) {
                                        HStack(spacing: 12) {
                                            capabilityPill("Streaming", ok: model.supports_streaming)
                                            capabilityPill("Vision", ok: model.supports_vision)
                                            capabilityPill("Tools", ok: model.supports_tools)
                                            capabilityPill("Structured answers", ok: model.supports_json_mode)
                                        }
                                    }
                                }
                            }
                        }
                    } else if !selectedModel.isEmpty,
                              let message = modelPickerPresentation.message {
                        AdvancedSection(title: "Model it falls back to", card: .bare) {
                            ProviderCard {
                                ProviderNote(text: message, color: NativeAgentShell.trouble)
                            }
                        }
                    }

                    if let result = testResult {
                        AdvancedSection(title: "Connection test", card: .bare) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    if result.tested {
                                        if let response = result.response {
                                            Text(response)
                                                .font(ShellType.label)
                                                .foregroundStyle(NativeAgentShell.text)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let error = result.error {
                                            ProviderNote(text: error, color: NativeAgentShell.trouble)
                                        }
                                        if let model = result.model_used {
                                            ProviderNote(text: model)
                                        }
                                    } else {
                                        ProviderNote(text: result.detail ?? "The test did not run.")
                                    }
                                }
                            }
                        }
                    }

                    if !statusText.isEmpty {
                        ProviderNote(text: statusText)
                    }

                    HStack(spacing: 8) {
                        Button(isSaving ? "Saving…" : "Save") {
                            Task { await saveConfig() }
                        }
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                        .disabled(isSaving || modelPickerPresentation.needsReplacement || !authModePickerState.canSave)

                        Button(isTesting ? "Testing…" : "Test the connection") {
                            Task { await runTest() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting || isSaving)

                        Spacer(minLength: 8)

                        Button("Remove the key", role: .destructive) {
                            showRemoveCredentialsConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                    }
                    .font(ShellType.labelMedium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .interactiveDismissDisabled(isSaving || isTesting || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .confirmationDialog("Close without saving the key?", isPresented: $showDiscardKeyConfirm, titleVisibility: .visible) {
            Button("Discard key", role: .destructive) { onDone() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The key you pasted has not been saved. Choose Keep editing, then Save to use it.")
        }
        .confirmationDialog(
            "Remove the \(provider.display_name) key?",
            isPresented: $showRemoveCredentialsConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove the key", role: .destructive) {
                Task { await clearConfig() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects the account and removes its saved key from this Mac. Surfaces using it stop working until another account is chosen.")
        }
    }

    private func saveConfig() async {
        guard !isSaving else { return }
        guard authModePickerState.supportedModes.contains(authMode) else {
            statusText = "Save failed: choose a supported authentication method first."
            return
        }
        isSaving = true
        invalidateTestFeedback()
        let savedInput = apiKey
        let savedAuthMode = authMode
        let submittedModel = selectedModel
        do {
            try await appModel.engine.providers.saveConnection(
                provider.provider_id,
                apiKey: savedAuthMode == "api_key" ? savedInput : nil,
                authMode: savedAuthMode, defaultModel: submittedModel,
                didSave: {
                    if savedAuthMode == "api_key", apiKey == savedInput { apiKey = "" }
                },
                failure: { error, action in appModel.setFailureStatus(error, action: action) }
            )
            // A saved credential invalidates earlier verification.
            if authMode == savedAuthMode, selectedModel == submittedModel { clearDraft() }
            verification = .afterSave()
            testResult = nil
            statusText = verification.statusText(providerNote: {
                switch provider.provider_id {
                case "moonshot":
                    return "Moonshot model choices are ready."
                case "kimi-code":
                    return "Kimi Code model choices are ready; the server accepts the tiers your subscription allows."
                default:
                    return nil
                }
            }())
        } catch {
            statusText = UserFacingError.message(error, action: "save \(provider.display_name)")
        }
        isSaving = false
    }

    private func runTest() async {
        guard !isTesting, !isSaving else { return }
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        let revision = credentialRevision
        let testedInput = apiKey
        let testedAuthMode = authMode
        // Test the displayed draft; draft results never update the saved credential's verification.
        let draftKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let testsDraft = authMode == "api_key" && !draftKey.isEmpty
        do {
            let probe = try await appModel.engine.providers.testConfiguredProvider(
                provider, authMode: testedAuthMode, apiKey: testedInput
            )
            let result = probe.result
            let credentialReady = probe.credentialReady
            guard credentialRevision == revision, apiKey == testedInput, authMode == testedAuthMode else { return }
            testResult = result
            if testsDraft {
                if result.tested && result.status == "ok" {
                    statusText = "Tested the key typed here and it works. It is not saved yet — press Save to keep it."
                } else if result.tested {
                    statusText = "Tested the key typed here and it did not work. It is not saved."
                } else {
                    statusText = "This provider has no connection test, so the key typed here was not checked. Press Save to keep it."
                }
            } else {
                // Only Test Connection verifies saved credentials.
                verification = .afterTest(result, credentialReady: credentialReady)
                statusText = verification.statusText(
                    providerNote: result.tested ? "This tested the credential saved on this Mac." : result.detail
                )
            }
        } catch {
            guard credentialRevision == revision, apiKey == testedInput, authMode == testedAuthMode else { return }
            if !testsDraft {
                verification = .verificationFailed
            }
            statusText = UserFacingError.message(error, action: "test \(provider.display_name)")
        }
    }

    private func invalidateTestFeedback() {
        credentialRevision += 1
        testResult = nil
        statusText = ""
    }

    private func clearConfig() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        invalidateTestFeedback()
        let outcome = await appModel.disconnectProvider(provider.provider_id)
        if outcome.ok {
            apiKey = ""
            clearDraft()
            verification = .afterClear()
            testResult = nil
        }
        statusText = outcome.detail
    }

    private func authModeLabel(_ mode: String) -> String {
        switch mode {
        case "api_key": return "A key"
        case "oauth":   return "A sign-in"
        default:        return "Something else"
        }
    }

    /// Capabilities use calm or quiet text without a plate.
    @ViewBuilder
    private func capabilityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(ShellType.caption)
            .foregroundStyle(ok ? NativeAgentShell.calm : NativeAgentShell.tertiary)
    }
}
