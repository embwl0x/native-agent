import ProviderRouting

// Blueprint: | `AnthropicSetupTokenInput.swift` | `AnthropicSetupTokenInput`: setup-token paste, submission and visible status through existing provider setup |
// PATCH-2026-05-07: anthropic-setup-token Paste-token UI for the Anthropic
// OAuth direct provider.
//
// Anthropic's blessed path for third-party harnesses: user generates a
// long-lived OAuth access token at console.anthropic.com → Settings → OAuth
// (the "Get Setup Token" button — gives back a `sk-ant-oat01-…` string),
// pastes it into NativeAgent. No browser flow, no callback listener, no
// port collisions with codex CLI / Claude Code CLI.
//
// Server-side it's used the same way as a browser-flow OAuth token:
// Authorization: Bearer + Claude Code identity headers + system prompt.

import SwiftUI
import PersistenceCore

struct AnthropicSetupTokenInput: View {
    var onSuccess: (() -> Void)? = nil

    @State private var token: String = ""
    @State private var status: SubmitStatus = .idle
    @State private var lastError: String? = nil
    @State private var lastSuccess: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Or run `claude setup-token` in Terminal and paste the key here:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = URL(string: "https://console.anthropic.com/settings/oauth") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Get one at console.anthropic.com", systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
            }
            HStack(spacing: 8) {
                SecureField("sk-ant-oat01-…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(status == .submitting)
                Button {
                    Task { await submit() }
                } label: {
                    if status == .submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(status == .submitting
                          || token.filter { !$0.isWhitespace }.count < 80)
            }

            if let s = lastSuccess {
                Label(s, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let err = lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    @MainActor
    private func submit() async {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastError = nil
        lastSuccess = nil
        status = .submitting
        let error = NativeOAuthFlow.saveAnthropicSetupToken(token)
        status = .idle
        if let error {
            lastError = error
        } else {
            token = ""
            lastSuccess = "Setup token saved."
            onSuccess?()
        }
    }

    private enum SubmitStatus: Equatable {
        case idle, submitting
    }
}
