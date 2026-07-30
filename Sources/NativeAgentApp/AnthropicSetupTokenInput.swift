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
    var nativeBaseURL: String = NativeBaseURLDefaults.read()
    var onSuccess: (() -> Void)? = nil

    @State private var token: String = ""
    @State private var status: SubmitStatus = .idle
    @State private var lastError: String? = nil
    @State private var lastSuccess: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Or paste an Anthropic setup-token:")
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
                .disabled(status == .submitting || trimmedToken.count < 80)
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

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    @MainActor
    private func submit() async {
        let t = trimmedToken
        guard !t.isEmpty else { return }
        status = .submitting
        lastError = nil
        lastSuccess = nil

        // DAEMON KILLED 2026-06-02. Write the setup_token directly to
        // <dataRoot>/providers/anthropic_oauth_direct.json with the shape
        // AnthropicOAuthDirectAdapter expects:
        //   {"access_token": "...", "auth_mode": "setup_token", "saved_at": "..."}
        do {
            let dataRoot = PersistenceCore.defaultDataRoot()
            let providersDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
            let path = providersDir.appendingPathComponent("anthropic_oauth_direct.json")
            try FileManager.default.createDirectory(at: providersDir, withIntermediateDirectories: true)
            let now = ISO8601DateFormatter().string(from: Date())
            let payload: [String: Any] = [
                "access_token": t,
                "auth_mode": "setup_token",
                "saved_at": now,
            ]
            try writeJSONObject(payload, to: path)
            status = .idle
            token = ""
            lastSuccess = "Anthropic setup-token saved to \(path.path)"
            onSuccess?()
        } catch {
            status = .idle
            lastError = "Failed to save setup-token: \(error.localizedDescription)"
        }
    }

    private enum SubmitStatus: Equatable {
        case idle, submitting
    }
}
