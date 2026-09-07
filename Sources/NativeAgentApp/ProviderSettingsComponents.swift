import SwiftUI
import Foundation
import ProviderRouting
import PersistenceCore

// MARK: - Provider Row
// A provider row carries no surface of its own: the card it sits in is the
// surface.

// internal (was private) so the onboarding provider-connect step can reuse the
// SAME row + config sheet as the working Providers settings panel (User,
// 2026-07-04: "show all the options we have — go off the working app").
struct ProviderRowView: View {
    let provider: ProviderInfo
    let onConfigure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: providerIcon(provider.provider_id))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.tertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.display_name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Text(provider.auth_modes.joined(separator: " / "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ProviderStatusWord(
                text: statusLabel(provider.auth_status.state),
                kind: statusBadgeKind(provider.auth_status.state)
            )
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

    private func statusLabel(_ state: String) -> String {
        switch state {
        case "ready":       return "Ready"
        case "needs_key":   return "Needs a key"
        case "needs_oauth": return "Needs a sign-in"
        case "error":       return "Not working"
        default:            return "Not set up"
        }
    }

    private func statusBadgeKind(_ state: String) -> String {
        switch state {
        case "ready":  return "ok"
        case "error":  return "error"
        default:       return "warn"
        }
    }
}

// MARK: - Configure Sheet

// FIRSTRUN-2 (2026-08-01): Save writes a key to disk and used to report a flat
// "Saved." Readiness everywhere downstream is inferred from file presence
// (NativeClient+Providers.swift synthesizes `hasToken` from the file), so a
// typo'd or revoked key read as a working provider until the first chat failed.
//
// Writing a key is not proof the key works. Save now moves the sheet into
// `savedUnverified` and the copy says exactly that; only a passing Test
// Connection promotes it to `verified`. Validation is never auto-fired on save
// — the user presses Test Connection.
enum ProviderCredentialVerification: Equatable {
    /// Nothing written or tested in this sheet session.
    case idle
    /// Credential written to disk, never checked against the service.
    case savedUnverified
    /// Credential written, and this provider has no live probe to check it
    /// with (`tested:false` from testProvider — e.g. Anthropic has no free
    /// probe endpoint). NOT a failure: without this state a working key could
    /// never leave "test failed" (gpt-5.5 review BLOCKING).
    case savedNoProbe
    /// Test Connection came back OK.
    case verified
    /// Test Connection ran and did not come back OK.
    case verificationFailed

    /// Save only ever means "written to disk".
    static func afterSave() -> ProviderCredentialVerification { .savedUnverified }

    /// Test Connection is the only transition that can claim the key works —
    /// and only a probe that actually RAN can claim it failed.
    static func afterTest(_ result: ProviderTestResult) -> ProviderCredentialVerification {
        if result.tested {
            return result.status == "ok" ? .verified : .verificationFailed
        }
        // No live probe ran. "error" means the attempt itself found something
        // wrong before probing (no key on disk) — a real failure. Anything
        // else means the provider is untestable, which must not read as failed.
        return result.status == "error" ? .verificationFailed : .savedNoProbe
    }

    /// Clearing credentials drops any earlier claim.
    static func afterClear() -> ProviderCredentialVerification { .idle }

    /// Short plain-English line shown under the panels. `providerNote` is an
    /// optional provider-specific addendum; it must never claim the key works.
    func statusText(providerNote: String? = nil) -> String {
        let base: String
        switch self {
        case .idle:
            base = ""
        case .savedUnverified:
            base = "Saved to this Mac. Not checked yet — press Test Connection to confirm it works."
        case .savedNoProbe:
            base = "Saved to this Mac. This provider has no connection test — the key is checked on your first real request."
        case .verified:
            base = "Saved and tested. This provider is working."
        case .verificationFailed:
            base = "Saved, but the test failed. Check the key, then test again."
        }
        guard let note = providerNote, !note.isEmpty else { return base }
        return base.isEmpty ? note : "\(base) \(note)"
    }

    /// Header badge override, or `nil` to keep the provider's own auth status.
    /// A file-presence "ready" badge must not sit above an untested key.
    var badge: (text: String, status: String)? {
        switch self {
        case .idle: return nil
        case .savedUnverified: return ("saved · not tested", "warn")
        case .savedNoProbe: return ("saved · no test available", "ok")
        case .verified: return ("tested · working", "ok")
        case .verificationFailed: return ("test failed", "error")
        }
    }
}

/// A provider default is not a per-surface model pin. The sheet may write the
/// former only after the selected catalog item is still advertised; an absent
/// or stale default remains visible for replacement rather than being silently
/// coerced into an unrelated model.
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

/// The provider catalog is the auth-mode authority for the configuration
/// sheet. Normalize its wire values once so a stale persisted mode cannot
/// become an untagged Picker selection or be written back as an unsupported
/// route.
struct ProviderAuthModePickerState: Equatable {
    let supportedModes: [String]
    let selectedMode: String
    let repairedSavedMode: String?

    var canSave: Bool { supportedModes.contains(selectedMode) }
}

enum ProviderAuthModePickerPresentation {
    private static let knownModes: Set<String> = ["api_key", "oauth"]

    static func resolve(
        advertisedModes: [String],
        savedMode: String?,
        providerIsReady: Bool
    ) -> ProviderAuthModePickerState {
        var seen = Set<String>()
        let supportedModes = advertisedModes.compactMap { raw -> String? in
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownModes.contains(mode), seen.insert(mode).inserted else { return nil }
            return mode
        }
        let normalizedSavedMode = savedMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedSavedMode, supportedModes.contains(normalizedSavedMode) {
            return ProviderAuthModePickerState(
                supportedModes: supportedModes,
                selectedMode: normalizedSavedMode,
                repairedSavedMode: nil
            )
        }
        let fallback = providerIsReady && supportedModes.contains("oauth")
            ? "oauth"
            : (supportedModes.first ?? "")
        return ProviderAuthModePickerState(
            supportedModes: supportedModes,
            selectedMode: fallback,
            repairedSavedMode: normalizedSavedMode?.isEmpty == false ? normalizedSavedMode : nil
        )
    }
}

struct ProviderConfigSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var apiKey = ""
    @State private var authMode: String
    @State private var selectedModel = ""
    @State private var availableModels: [ProviderModelInfo]
    @State private var testResult: ProviderTestResult? = nil
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var credentialRevision = 0
    @State private var statusText = ""
    @State private var showRemoveCredentialsConfirm = false
    /// FIRSTRUN-2: tracks whether the credential in this sheet has actually
    /// been proven against the service, independent of the file-presence
    /// readiness the provider row reports.
    @State private var verification: ProviderCredentialVerification = .idle

    private var authModePickerState: ProviderAuthModePickerState {
        ProviderAuthModePickerPresentation.resolve(
            advertisedModes: provider.auth_modes,
            savedMode: provider.auth_mode,
            providerIsReady: provider.auth_status.state == "ready"
        )
    }

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider
        self.onDone = onDone
        let authModeState = ProviderAuthModePickerPresentation.resolve(
            advertisedModes: provider.auth_modes,
            savedMode: provider.auth_mode,
            providerIsReady: provider.auth_status.state == "ready"
        )
        _authMode = State(initialValue: authModeState.selectedMode)
        let savedModel = provider.default_model?.trimmingCharacters(in: .whitespacesAndNewlines)
        _selectedModel = State(initialValue: savedModel?.isEmpty == false ? savedModel! : (provider.models.first?.id ?? ""))
        _availableModels = State(initialValue: provider.models)
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
                    // FIRSTRUN-2: an unverified save must not inherit the
                    // file-presence "ready" badge.
                    if let badge = verification.badge {
                        ProviderStatusWord(text: badge.text, kind: badge.status)
                    } else {
                        ProviderStatusWord(
                            text: provider.auth_status.state == "ready" ? "Ready" : "Not set up",
                            kind: provider.auth_status.state == "ready" ? "ok" : "warn"
                        )
                    }
                }
                Spacer(minLength: 8)
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .font(ShellType.labelMedium)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if authModePickerState.supportedModes.isEmpty {
                        ProviderSection(label: "How to sign in") {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "No way in was offered",
                                    line: "This account did not name a sign-in method. Refresh the accounts, or repair its configuration, before saving."
                                )
                            }
                        }
                    } else if authModePickerState.supportedModes.count > 1 {
                        ProviderSection(label: "How to sign in") {
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
                        ProviderSection(label: "Key") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SecureField("Paste the key here", text: Binding(get: { apiKey }, set: {
                                        apiKey = $0
                                        invalidateTestFeedback()
                                    }))
                                        .textFieldStyle(.roundedBorder)
                                        .font(ProviderType.code)
                                    ProviderNote(text: "The key is kept on this Mac only, readable by you alone, and is never written to a log.")
                                }
                            }
                        }
                    }

                    if authMode == "oauth" {
                        ProviderSection(label: "Sign in") {
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
                                        OAuthSignInButton(provider: .xai) {
                                            Task { await appModel.loadProvidersForChat() }
                                        }
                                    }
                                    ProviderNote(text: provider.auth_status.detail)
                                }
                            }
                        }
                    }

                    if !availableModels.isEmpty {
                        ProviderSection(label: "Model it falls back to") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Model", selection: $selectedModel) {
                                        ForEach(availableModels) { model in
                                            Text(model.name).tag(model.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .font(ShellType.label)
                                    ProviderNote(text: "This is the model used by a surface that is assigned to this provider and has not pinned one of its own. Surface assignments and pins are set on the Providers page.")
                                    if let message = modelPickerPresentation.message {
                                        ProviderNote(text: message, color: NativeAgentShell.trouble)
                                    }
                                    if let model = availableModels.first(where: { $0.id == selectedModel }) {
                                        HStack(spacing: 12) {
                                            capabilityPill("Streaming", ok: model.supports_streaming)
                                            capabilityPill("Vision", ok: model.supports_vision)
                                            capabilityPill("Tools", ok: model.supports_tools)
                                            capabilityPill("JSON", ok: model.supports_json_mode)
                                        }
                                    }
                                }
                            }
                        }
                    } else if !selectedModel.isEmpty,
                              let message = modelPickerPresentation.message {
                        ProviderSection(label: "Model it falls back to") {
                            ProviderCard {
                                ProviderNote(text: message, color: NativeAgentShell.trouble)
                            }
                        }
                    }

                    if let result = testResult {
                        ProviderSection(label: "Connection test") {
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
        do {
            _ = try await appModel.configureProvider(
                provider.provider_id,
                apiKey: savedAuthMode == "api_key" ? savedInput : nil,
                authMode: savedAuthMode,
                defaultModel: selectedModel
            )
            // 2026-09-06: Test should use the persisted key; preserve edits made during Save.
            if savedAuthMode == "api_key", apiKey == savedInput {
                apiKey = ""
            }
            let refreshed = try await appModel.listProviders()
            if let current = refreshed.first(where: { $0.provider_id == provider.provider_id }) {
                availableModels = current.models
            }
            await appModel.loadProvidersForChat()
            // FIRSTRUN-2: the key is on disk, nothing more. Any earlier
            // "verified" claim is stale now that the credential changed.
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
            statusText = "Save failed: \(error.localizedDescription)"
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
        // User, 2026-09-06: test what the sheet is showing. A key typed here and
        // not saved yet is the credential the person is asking about; testing
        // the saved one instead let a bad draft read "Saved and tested" off the
        // old key, and made a valid pasted key report "no api key configured"
        // on a fresh install. A draft result never touches `verification` —
        // that state describes the SAVED credential, and nothing was saved.
        let draftKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let testsDraft = authMode == "api_key" && !draftKey.isEmpty
        do {
            let result = try await appModel.testProvider(
                provider.provider_id,
                apiKeyOverride: testsDraft ? draftKey : nil
            )
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
                // FIRSTRUN-2: Test Connection is the only thing that can clear
                // the saved-but-unverified state.
                verification = .afterTest(result)
                statusText = verification.statusText(
                    providerNote: "This tested the key saved on this Mac."
                )
            }
        } catch {
            guard credentialRevision == revision, apiKey == testedInput, authMode == testedAuthMode else { return }
            if !testsDraft {
                verification = .verificationFailed
            }
            statusText = "Test error: \(error.localizedDescription)"
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
        do {
            _ = try await appModel.clearProvider(provider.provider_id)
            // User, 2026-09-06: for an OAuth provider the credential does not
            // live in providers/<id>.json — ChatGPT's is in codex_home/auth.json
            // and the others in their adapters' own token files — so removing
            // the registry row left the account connected while the sheet said
            // it had been disconnected. Go through the same path the OAuth
            // "Sign out" button uses; it no-ops for non-OAuth providers.
            let clearedOAuth = NativeOAuthFlow.clearTokens(
                providerId: provider.provider_id,
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
            let oauthID = NativeOAuthFlow.normalizedOAuthProviderId(provider.provider_id)
            if ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(oauthID),
               !clearedOAuth {
                statusText = "Clear failed: the OAuth credential could not be removed."
                await appModel.loadProvidersForChat()
                return
            }
            apiKey = ""
            verification = .afterClear()
            testResult = nil
            // The shared ~/.codex/auth.json belongs to the Codex CLI and is
            // never deleted here, so say so rather than claiming a removal
            // that did not happen (same wording the Sign out button uses).
            // User, 2026-09-06: this asked `isSignedIn`, which reads the auth
            // path chat will USE — and the removal just flipped CLI adoption to
            // declined, so the normal case answered false and reported
            // "Credentials removed" with the shared file still on disk. The
            // disclosure now keys off the shared file itself.
            statusText = NativeOAuthFlow.sharedCodexCLISessionRemains(
                providerId: provider.provider_id
            )
                ? "Shared Codex auth is still signed in. Sign out from Codex to remove it."
                : "Credentials removed."
            // S.5: propagate cleared credentials to the provider list so the
            // parent ProviderSettingsView and the chat brain bar reflect the
            // new auth_status (needs_key / needs_oauth) immediately.
            await appModel.loadProvidersForChat()
        } catch {
            statusText = "Clear failed: \(error.localizedDescription)"
        }
    }

    private func authModeLabel(_ mode: String) -> String {
        switch mode {
        case "api_key": return "A key"
        case "oauth":   return "A sign-in"
        default:        return "Something else"
        }
    }

    /// What the model can do, said in words. Calm when it can, quiet when it
    /// cannot — no plate under either.
    @ViewBuilder
    private func capabilityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(ShellType.caption)
            .foregroundStyle(ok ? NativeAgentShell.calm : NativeAgentShell.tertiary)
    }
}

// MARK: - PATCH-2026-05-07: anthropic-mcp status panel

/// A local Claude CLI presence check is the only evidence this panel has for
/// its persistent-MCP connection claim. Do not manufacture readiness from a
/// provider-list payload that may have been collected before the CLI moved or
/// was removed.
enum AnthropicMCPCLIProbe {
    enum Availability: Equatable {
        case checking
        case available(path: String)
        case unavailable(reason: String)
    }

    static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Availability {
        guard let path = environment["PATH"], !path.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH is unavailable.")
        }
        let directories = path.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        guard !directories.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH has no absolute directories.")
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("claude")
                .path
            if isExecutable(candidate) {
                return .available(path: candidate)
            }
        }
        return .unavailable(reason: "Claude CLI was not found on PATH. Install or restore Claude Code, then test again.")
    }
}

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

private struct AnthropicMCPStatusPanel: View {
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
            cliAvailability = AnthropicMCPCLIProbe.probe()
        }
    }

    private func runPersistentTest() async {
        isTesting = true
        testResult = ""
        cliAvailability = AnthropicMCPCLIProbe.probe()
        if case .unavailable(let reason) = cliAvailability {
            testResult = reason
            isTesting = false
            return
        }
        do {
            let result = try await appModel.testProvider(provider.provider_id)
            if result.tested {
                testResult = result.response ?? result.error ?? "ok"
            } else {
                testResult = result.detail ?? result.status
            }
        } catch {
            testResult = "Error: \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - PATCH-2026-05-07: anthropic-oauth-direct panel

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
            // Provider list rows are a snapshot. The canonical sign-in control
            // reads the same root it writes, so this panel cannot keep offering
            // Connect after the browser flow committed or claim authorization
            // from a stale provider-list response.
            OAuthSignInButton(provider: .anthropic)
        }
    }
}

// MARK: - Page kit
//
// The page's own small vocabulary: an eyebrow over a run, the card a group of
// controls sits in, the card's own headline, one quiet line, and the one word
// that says how an account stands.

/// 13 monospaced, for a value that is a code. `ShellType` carries no
/// monospaced face, so this derives one from the token size.
enum ProviderType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
}

struct ProviderSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
            content
        }
    }
}

struct ProviderCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .settingsCardSurface()
    }
}

struct ProviderCardTitle: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            Text(line)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// How an account stands, in one word, in one of the two colours the shell
/// palette carries for state. No plate: a coloured word on the card is enough.
struct ProviderStatusWord: View {
    let text: String
    /// "ok", "warn" or "error", as the presentation types already spell it.
    let kind: String

    var body: some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var color: Color {
        switch kind {
        case "ok": NativeAgentShell.calm
        // The shell palette has one attention colour; a warning and a failure
        // both wear it, and the word says which it is.
        case "warn", "error": NativeAgentShell.trouble
        default: NativeAgentShell.secondary
        }
    }
}
