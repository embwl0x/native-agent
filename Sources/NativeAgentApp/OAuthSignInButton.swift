import ProviderRouting

// Blueprint: | `OAuthSignInButton.swift` | `OAuthSignInButton` and presenter: in-process sign-in/sign-out, CLI session consent and current credential-state presentation |
// NativeOAuthFlow owns browser authorization and persisted credentials.

import SwiftUI
import AuthenticationServices
import PersistenceCore

/// Drop into Settings, onboarding, or anywhere else.
/// Examples:
///   OAuthSignInButton(provider: .chatgpt)
///   OAuthSignInButton(provider: .anthropic)
struct OAuthSignInButton: View {
    let provider: OAuthProvider
    @Environment(AppModel.self) private var appModel

    private var authStatus: NativeOAuthFlow.SignInStatus? {
        appModel.engine.providers.settings?.oauthStatuses[provider.id]
    }
    private var status: OAuthSignInPresentation.State {
        flowTask != nil ? .running : (authStatus?.isSignedIn == true ? .complete : .idle)
    }
    @State private var lastError: String? = nil
    private var authStatusText: String? { authStatus?.detail }
    @State private var flowTask: Task<Void, Never>? = nil
    private var cliSessionOffer: NativeOAuthFlow.CodexCLISessionOffer? {
        provider.id == "openai_oauth_direct" ? appModel.engine.providers.settings?.codexCLISessionOffer : nil
    }
    @State private var showingCLIConsentRepairConfirmation = false
    @State private var cliConsentRepairMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    guard flowTask == nil else { return }
                    flowTask = Task { await runFlow() }
                } label: {
                    HStack(spacing: 8) {
                        if case .running = status {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: provider.iconSystemName)
                        }
                        Text(buttonControl.title)
                            .font(ShellType.label)
                    }
                }
                // House rule 1 — one accent, one job. A brand fill per provider
                // is a second, third and fourth accent on one page, so the
                // sign-in control is a plain bordered button like every other.
                .buttonStyle(.bordered)
                .disabled(buttonControl.isDisabled || flowTask != nil)

                if buttonControl.showsCancel {
                    Button("Cancel", role: .cancel) {
                        flowTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }

                if status == .complete {
                    Button("Sign out") {
                        Task { await signOut() }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            if let detail = buttonControl.guidance ?? authStatusText {
                Label(detail, systemImage: status == .complete ? "checkmark.seal.fill" : "key.fill")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let err = lastError ?? authStatus?.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
            if status != .complete, provider.id == "openai_oauth_direct",
               let offer = cliSessionOffer {
                switch offer {
                case .available(let email, let alreadyDeclined):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            email.map { "Found an existing Codex CLI sign-in on this Mac (\($0))." }
                                ?? "Found an existing Codex CLI sign-in on this Mac (~/.codex).",
                            systemImage: "terminal"
                        )
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        HStack(spacing: 8) {
                            Button("Use it") {
                                Task { await acceptCLISessionOffer() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            if !alreadyDeclined {
                                Button("Ignore") {
                                    NativeOAuthFlow.recordCodexCLISessionDecision(
                                        allow: false, source: "providers_offer",
                                        dataRoot: appModel.engine.dataRoot)
                                    Task { await refreshStatus() }
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .disabled(status == .running)
                case .unavailable(let reason):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Codex CLI sign-in adoption is unavailable.", systemImage: "exclamationmark.triangle.fill")
                            .font(ShellType.captionSemibold)
                            .foregroundStyle(NativeAgentShell.trouble)
                        Text(reason)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                        Button("Repair saved consent…") {
                            showingCLIConsentRepairConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                    .disabled(status == .running)
                }
            }
            if let cliConsentRepairMessage {
                Label(cliConsentRepairMessage, systemImage: "checkmark.circle")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .onDisappear {
            flowTask?.cancel()
        }
        .confirmationDialog(
            "Repair saved Codex CLI consent?",
            isPresented: $showingCLIConsentRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Back Up and Reset") {
                Task { await repairCLISessionConsent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NativeAgent will preserve the unreadable bytes in a backup, then reset only this consent decision. It will not change or delete your Codex CLI sign-in.")
        }
    }

    private var buttonControl: OAuthSignInPresentation.ButtonControl {
        OAuthSignInPresentation.buttonControl(
            providerDisplayShort: provider.displayShort,
            state: status
        )
    }

    // MARK: - Flow

    @MainActor
    private func runFlow() async {
        // Keep the task owned until cancellation has torn down the old flow.
        defer { flowTask = nil }
        // ChatGPT uses the direct in-process browser OAuth, like Anthropic/Grok.
        lastError = nil
        print("[oauth-signin] starting native flow for \(provider.id)")

        _ = await appModel.engine.providers.connectOAuthProvider(
            platform: NativeOAuthPlatform.self, providerID: provider.id,
            present: { result in
                NSApp.activate(ignoringOtherApps: true)
                if !result.ok {
                    lastError = result.error ?? "OAuth failed (no details)"
                }
            },
            failure: { error, action in appModel.setFailureStatus(error, action: action) }
        )
    }

    @MainActor
    private func signOut() async {
        let cleared = NativeOAuthFlow.clearTokens(providerId: provider.id, dataRoot: appModel.engine.dataRoot)
        await refreshStatus()
        if !cleared {
            lastError = "Sign-out did not finish — a credential file could not be removed. Check permissions on the data folder and try again."
        } else if provider.id == "openai_oauth_direct",
           authStatus?.isSignedIn == true {
            lastError = "Shared Codex auth is still signed in. Sign out from Codex to remove it."
        }
    }

    @MainActor
    private func refreshStatus() async {
        lastError = nil
        await appModel.loadProvidersForChat()
    }

    /// User accepted the "use your existing Codex CLI sign-in" offer: record
    /// consent, then re-resolve — the shared session becomes a candidate and
    /// the badge labels it as an adopted CLI session.
    @MainActor
    private func acceptCLISessionOffer() async {
        lastError = nil
        guard await appModel.engine.providers.acceptCodexCLISession(
            failure: { error, action in appModel.setFailureStatus(error, action: action) }
        ) else {
            lastError = "Could not save the choice — check disk permissions."
            return
        }
    }

    @MainActor
    private func repairCLISessionConsent() async {
        do {
            let backup = try NativeOAuthFlow.repairCodexCLISessionConsent(
                dataRoot: appModel.engine.dataRoot)
            cliConsentRepairMessage = "Unreadable consent was backed up as \(backup.lastPathComponent). Choose Use it or Ignore again."
            lastError = nil
            await refreshStatus()
        } catch {
            lastError = UserFacingError.message(error, action: "repair the consent file")
        }
    }

}

// MARK: - Provider catalog

/// Identity for each OAuth provider exposed in NativeAgent. No brand colour:
/// the sign-in control is bordered, so a per-provider tint has nowhere to go.
struct OAuthProvider {
    let id: String                  // provider_id
    let displayShort: String        // "ChatGPT", "Claude" — used in button label
    let iconSystemName: String

    static let chatgpt = OAuthProvider(
        id: "openai_oauth_direct",
        displayShort: "ChatGPT",
        iconSystemName: "person.crop.circle.badge.checkmark"
    )

    static let anthropic = OAuthProvider(
        id: "anthropic_oauth_direct",
        displayShort: "Claude",
        iconSystemName: "brain.head.profile"
    )

    static let xai = OAuthProvider(
        id: "xai_oauth_direct",
        displayShort: "xAI Grok",
        iconSystemName: "sparkles"
    )

}

// MARK: - Presentation context (AppKit hook)

@MainActor
final class OAuthSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthSignInPresenter()

    private var fallbackAnchorWindow: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return window
        }
        if let fallbackAnchorWindow {
            return fallbackAnchorWindow
        }
        let fallback = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        fallbackAnchorWindow = fallback
        return fallback
    }
}

/// The persisted-credential outcome shown by every OAuth sign-in control.
/// It is intentionally derived from the same root-aware read as the runtime,
/// rather than from a mounted SwiftUI control or an optimistic write result.
enum OAuthSignInPresentation {
    enum State: Equatable {
        case idle
        case running
        case complete
    }

    struct ButtonControl: Equatable {
        let title: String
        let isDisabled: Bool
        var showsCancel: Bool = false
        var guidance: String? = nil
    }

    static func buttonControl(providerDisplayShort: String, state: State) -> ButtonControl {
        switch state {
        case .running:
            return ButtonControl(
                title: "Signing in…", isDisabled: true,
                showsCancel: true, guidance: "Finish signing in in your browser"
            )
        case .complete:
            return ButtonControl(
                title: "Re-authenticate \(providerDisplayShort)",
                isDisabled: false
            )
        case .idle:
            return ButtonControl(title: "Sign in with \(providerDisplayShort)", isDisabled: false)
        }
    }
}
