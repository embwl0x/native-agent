import Foundation
import AppKit
import NativeAgentShared

// Blueprint: | `OAuthSignInButton.swift` | `OAuthSignInButton`: sign-in, CLI consent and persisted credential presentation |

import SwiftUI
struct OAuthSignInButton: View {
    let provider: OAuthProvider
    @Environment(AppModel.self) private var appModel

    private var authStatus: ProviderSignInStatus? {
        appModel.face.slot(.settings).select("providers.oauth.\(provider.id)", as: SettingsFace.self) {
            $0?.providers.snapshot?.oauthStatuses[provider.id]
        }
    }
    private var status: OAuthSignInPresentation.State {
        flowTask != nil ? .running : (authStatus?.isSignedIn == true ? .complete : .idle)
    }
    @State private var lastError: String? = nil
    private var authStatusText: String? { authStatus?.detail }
    @State private var flowTask: Task<Void, Never>? = nil
    @State private var credentialOperationRunning = false
    private var cliSessionOffer: CodexCLISessionOffer? {
        provider.id == "openai_oauth_direct"
            ? appModel.face.slot(.settings).select("providers.cliOffer", as: SettingsFace.self) { $0?.providers.snapshot?.codexCLISessionOffer }
            : nil
    }
    @State private var showingCLIConsentRepairConfirmation = false
    @State private var cliConsentRepairMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    guard flowTask == nil, !credentialOperationRunning else { return }
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
                // Per-provider fills would compete with the page's single accent.
                .buttonStyle(.bordered)
                .disabled(buttonControl.isDisabled || flowTask != nil || credentialOperationRunning)

                if buttonControl.showsCancel {
                    Button("Cancel", role: .cancel) {
                        flowTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }

                if status == .complete {
                    Button("Sign out") {
                        startCredentialAct(.signOutProvider(id: provider.id))
                    }
                    .buttonStyle(.bordered)
                    .disabled(flowTask != nil || credentialOperationRunning)
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
                                startCredentialAct(.decideCodexCLIConsent(allow: true))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            if !alreadyDeclined {
                                Button("Ignore") {
                                    startCredentialAct(.decideCodexCLIConsent(allow: false))
                                }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                                .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .disabled(status == .running || credentialOperationRunning)
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
                    .disabled(status == .running || credentialOperationRunning)
                }
            }
            if credentialOperationRunning { ProgressView("Updating sign-in…").controlSize(.small) }
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
                startCredentialAct(.repairCodexCLIConsent) {
                    cliConsentRepairMessage = "Saved consent was backed up and reset. Choose Use it or Ignore again."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                NativeAgent will preserve the unreadable bytes in a backup, then reset only this consent decision. It will not change \
                or delete your Codex CLI sign-in.
                """)
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
        lastError = nil
        do {
            _ = try await appModel.committedFaceAct(.beginOAuth(provider: provider.id))
        } catch {
            // The person pressing Cancel ends this task; the link then reports its own "stopped waiting" failure, which is not news to them.
            lastError = Task.isCancelled || error is CancellationError ? "Sign-in cancelled." : error.localizedDescription
        }
    }

    @MainActor
    private func startCredentialAct(_ act: FaceAct, onSuccess: (@MainActor () -> Void)? = nil) {
        guard !credentialOperationRunning, flowTask == nil else { return }
        credentialOperationRunning = true
        Task {
            defer { credentialOperationRunning = false }
            lastError = nil
            do {
                _ = try await appModel.committedFaceAct(act)
                onSuccess?()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

}

// MARK: - Provider catalog

/// Bordered controls keep provider branding from introducing competing accents.
struct OAuthProvider {
    let id: String
    let displayShort: String
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

/// Read persisted root-scoped credentials so mounted controls cannot claim optimistic success.
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
