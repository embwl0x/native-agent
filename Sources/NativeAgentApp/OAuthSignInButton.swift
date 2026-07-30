// Swift-native cutover (2026-06-02): OAuth flow is driven entirely in-process by
// `NativeOAuthFlow` — provider-native OAuth for Anthropic/Grok via the
// registered `nativeagent://oauth/...` callback, and (since 2026-07-05) the
// codex-free native loopback flow on :1455 for ChatGPT (see
// NativeOAuthFlow+Loopback; the codex device flow survives only as the
// alternative path). PKCE-exchanges the returned code via URLSession and
// persists tokens to the same on-disk shape the read-side OAuth-direct
// adapters already consume. No daemon, no HTTP plumbing through /v1/providers/*.

import SwiftUI
import AuthenticationServices

/// Drop into Settings, onboarding, or anywhere else.
/// Examples:
///   OAuthSignInButton(provider: .chatgpt)
///   OAuthSignInButton(provider: .claude)
struct OAuthSignInButton: View {
    let provider: OAuthProvider
    /// Kept for source-compat with call sites that still pass the daemon
    /// URL — IGNORED now that the flow is fully in-process.
    var nativeBaseURL: String = ""
    var onSuccess: (() -> Void)? = nil

    // S.5: access AppModel so we can propagate revoke state to provider list
    @Environment(AppModel.self) private var appModel

    @State private var status: SignInStatus = .idle
    @State private var lastError: String? = nil
    @State private var authStatusText: String? = nil
    @State private var flowTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    flowTask = Task { await runFlow() }
                } label: {
                    HStack(spacing: 8) {
                        if case .running = status {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: provider.iconSystemName)
                        }
                        Text(buttonLabel)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.tintColor)
                .disabled(status == .running)

                if status == .complete {
                    Button("Sign out") {
                        Task { await signOut() }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            if let detail = authStatusText {
                Label(detail, systemImage: status == .complete ? "checkmark.seal.fill" : "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let err = lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .task {
            await refreshStatus()
        }
        .onDisappear {
            // B.9: cancel in-flight polling when the view disappears
            flowTask?.cancel()
            flowTask = nil
        }
    }

    private var buttonLabel: String {
        switch status {
        case .running:  return "Signing in…"
        case .complete: return "Re-authenticate \(provider.displayShort)"
        case .idle:     return "Sign in with \(provider.displayShort)"
        }
    }

    // MARK: - Flow

    @MainActor
    private func runFlow() async {
        // ChatGPT now uses the DIRECT in-process browser OAuth (NativeOAuthFlow,
        // like Anthropic/Grok) — no codex CLI (2026-07-04, User). The old
        // codex device-login path (runCodexDeviceLoginFlow, still below) is
        // retained but no longer the default; the direct flow opens
        // auth.openai.com in a browser and returns the token.
        status = .running
        lastError = nil
        print("[oauth-signin] starting native flow for \(provider.id)")

        let result = await NativeOAuthFlow.startOAuthFlow(providerId: provider.id)
        if Task.isCancelled {
            status = .idle
            return
        }
        if result.ok {
            status = .complete
            // F.evalfix2/R2: render the same countdown the next refreshStatus
            // cycle would compute, off the just-written auth.json — not a
            // placeholder. If signInStatusDetail can't read expiry (long-lived
            // setup_token), fall through to "Signed in".
            authStatusText = NativeOAuthFlow.signInStatusDetail(providerId: provider.id)
                ?? "Signed in"
            await appModel.loadProvidersForChat()
            // Fill any blank/stale surfaces with the provider just connected, so
            // the user isn't left hand-switching surfaces off the codex default.
            // Only touches unconfigured/unavailable surfaces — never clobbers a
            // surface already on another connected provider.
            await appModel.adoptProviderForBlankSurfaces(provider.id)
            onSuccess?()
        } else {
            status = .idle
            lastError = result.error ?? "OAuth failed (no details)"
        }
    }

    @MainActor
    private func runCodexDeviceLoginFlow() async {
        status = .running
        lastError = nil
        authStatusText = "Opening Codex browser login..."
        print("[oauth-signin] starting Codex device flow for \(provider.id)")

        do {
            let login = try await appModel.client.openCodexLoginInBrowser()
            appModel.codexDeviceLogin = login
            authStatusText = codexDeviceLoginStatusText(login)
        } catch {
            status = .idle
            lastError = "Codex login failed: \(error.localizedDescription)"
            return
        }

        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            if Task.isCancelled {
                status = .idle
                return
            }

            do {
                let login = try await appModel.client.getCodexDeviceLoginStatus()
                appModel.codexDeviceLogin = login
                authStatusText = codexDeviceLoginStatusText(login)
                if login.running != true {
                    let auth = try? await appModel.client.getCodexAuthStatus()
                    appModel.codexAuthStatus = auth
                    await appModel.loadProvidersForChat()
                    if auth?.appOwnedLoggedIn == true {
                        status = .complete
                        authStatusText = "Signed in through Codex"
                        onSuccess?()
                    } else {
                        status = .idle
                        lastError = login.detail ?? "Codex login did not finish."
                    }
                    return
                }
            } catch {
                lastError = "Codex login status failed: \(error.localizedDescription)"
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        status = .idle
        lastError = "Codex login timed out. Start ChatGPT sign-in again to get a fresh code."
    }

    private func codexDeviceLoginStatusText(_ login: CodexDeviceLogin) -> String {
        if let code = login.code, !code.isEmpty {
            if let minutes = login.expiresInMinutes {
                return "Enter code \(code) in the browser (\(minutes)m)"
            }
            return "Enter code \(code) in the browser"
        }
        return login.detail ?? "Waiting for Codex login code..."
    }

    @MainActor
    private func signOut() async {
        _ = NativeOAuthFlow.clearTokens(providerId: provider.id)
        await refreshStatus()
        if provider.id == "openai_oauth_direct",
           NativeOAuthFlow.isSignedIn(providerId: provider.id) {
            lastError = "Shared Codex auth is still signed in. Sign out from Codex to remove it."
        }
        // S.5: propagate revoke to the provider list so ProviderSettingsView
        // and the chat brain bar reflect the new auth state immediately.
        await appModel.loadProvidersForChat()
    }

    @MainActor
    private func refreshStatus() async {
        if NativeOAuthFlow.isSignedIn(providerId: provider.id) {
            status = .complete
            // Show "Signed in (expires in Xh Ym)" countdown when expires_at
            // is persisted. Falls back to "Signed in" for long-lived
            // setup_tokens that don't carry expiry.
            authStatusText = NativeOAuthFlow.signInStatusDetail(providerId: provider.id)
                ?? "Signed in"
        } else {
            status = .idle
            authStatusText = nil
        }
    }

    private enum SignInStatus: Equatable {
        case idle, running, complete
    }
}

// MARK: - Provider catalog

/// Identity + branding for each OAuth provider exposed in NativeAgent.
struct OAuthProvider {
    let id: String                  // matches the daemon's provider_id
    let displayShort: String        // "ChatGPT", "Claude" — used in button label
    let iconSystemName: String
    let tintColor: Color

    static let chatgpt = OAuthProvider(
        id: "openai_oauth_direct",
        displayShort: "ChatGPT",
        iconSystemName: "person.crop.circle.badge.checkmark",
        tintColor: .green
    )

    static let anthropic = OAuthProvider(
        id: "anthropic_oauth_direct",
        displayShort: "Anthropic",
        iconSystemName: "brain.head.profile",
        tintColor: .orange
    )

    static let xai = OAuthProvider(
        id: "xai_oauth_direct",
        displayShort: "xAI Grok",
        iconSystemName: "sparkles",
        tintColor: .cyan
    )

    /// Back-compat alias — earlier code referred to this provider as `.claude`.
    static let claude = anthropic
}

// MARK: - Presentation context (AppKit hook)

final class OAuthSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthSignInPresenter()

    // PATCH-2026-05-07: oauth-session-retain Hold a strong ref to the
    // ASWebAuthenticationSession while it's presenting. Without this, ARC
    // releases the session when the local variable goes out of scope and
    // the sheet may dismiss / never finish.
    private var activeSessions: [ASWebAuthenticationSession] = []
    private var fallbackAnchorWindow: NSWindow?
    private let lock = NSLock()

    func retain(_ session: ASWebAuthenticationSession) {
        lock.lock(); activeSessions.append(session); lock.unlock()
        // B.9: timer is now a fallback only — the completion callback releases
        // the session immediately via release(_:) on normal completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self, weak session] in
            guard let self = self, let session = session else { return }
            self.lock.lock()
            self.activeSessions.removeAll { $0 === session }
            self.lock.unlock()
        }
    }

    // B.9: immediate release from the session's own completion callback
    func release(_ session: ASWebAuthenticationSession) {
        lock.lock()
        activeSessions.removeAll { $0 === session }
        lock.unlock()
    }

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
