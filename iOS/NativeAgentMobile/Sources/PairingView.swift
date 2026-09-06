// Phase 14e-iCloud HMAC self-heal: iCloud-only pairing flow.
// The legacy LAN/HTTP transport (QR scan + bearer token) was retired in the
// iOS iCloud-only sweep (see MacBridgeClient.swift). This view now offers only:
//   1) Automatic iCloud KVS bootstrap (no user input — happens on init).
//   2) Manual base64 HMAC paste as a fallback when KVS sync is delayed.
import SwiftUI

enum IOSPairingPresentation {
    static let title = "Pair with the Mac app to get started."
    static let iCloudReadyDetail = "NativeAgent connects to your Mac via iCloud. The Mac publishes a pairing key automatically. If this iPhone does not pick it up after a few seconds, open Mac Settings -> Pair iPhone / iPad, copy the key, and paste it below."
    static let iCloudUnavailableDetail = "Sign into iCloud in Settings -> Apple Account to enable pairing."
    static let manualSectionTitle = "Pairing key from Mac Settings"
    static let manualSectionDetail = "NativeAgent for iPhone does not scan a QR code yet. To continue, copy the pairing key from the Mac app (Settings -> Pair iPhone / iPad) and paste it here."
    static let manualFieldHint = "Paste the pairing key (base64, about 44 characters):"
    static let manualLengthDetail = "Paste the base64 key from the Mac app, not a hex string. The key is usually about 44 characters."
    static let missingKeyMessage = "Waiting on the pairing key from your Mac. Open Mac Settings -> Pair iPhone / iPad, then copy and paste the current key if it has not arrived through iCloud yet."
    static let notSignedSyncMessage = "iCloud sync paused — pairing key not configured. Open Mac Settings -> Pair iPhone / iPad, then copy and paste the current key."
    static let signatureRetryMessage = "Signature validation failed. Open Mac Settings -> Pair iPhone / iPad, then copy and paste the current key again."
}

enum ManualPairingKeyPaste {
    enum Verdict: Equatable {
        case verified
        case looksLikeHex
        case invalidFormat
        case awaitingMacVerification
        case doesNotMatchMac
    }

    static func verdict(base64: String, publishedMacSecret: Data?) -> Verdict {
        if base64.count == 64,
           base64.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil {
            return .looksLikeHex
        }
        guard let candidate = Data(base64Encoded: base64), candidate.count == 32 else {
            return .invalidFormat
        }
        guard let publishedMacSecret else { return .awaitingMacVerification }
        return candidate == publishedMacSecret ? .verified : .doesNotMatchMac
    }
}

struct PairingView: View {
    var onSkip: (() -> Void)? = nil
    var onPaired: (() -> Void)? = nil

    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var bridge = iCloudBridge.shared
    @State private var errorMessage: String?
    @State private var iCloudSecretError: String?
    @State private var iCloudSecretSuccess: String?
    @State private var pastedSecretKey: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 24)

                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(NativeAgentPalette.agentGradient)

                    VStack(spacing: 8) {
                        GradientText(text: "NativeAgent Mobile", font: AppFont.display)
                        Text(IOSPairingPresentation.title)
                            .font(AppFont.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if bridge.available {
                        VStack(spacing: 16) {
                            Image(systemName: "icloud.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.blue)
                            Text("iCloud detected")
                                .font(.headline)
                            Text(IOSPairingPresentation.iCloudReadyDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)

                            Button {
                                connectViaICloud()
                            } label: {
                                Label(
                                    pairingStore.isICloudSigned
                                        ? "Connect via iCloud"
                                        : "Waiting for pairing key…",
                                    systemImage: "checkmark.icloud"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(pairingStore.isICloudSigned ? NativeAgentPalette.agentAccent : .gray)
                            .controlSize(.large)
                            .padding(.horizontal, 32)
                            .disabled(!pairingStore.isICloudSigned)
                        }
                    } else {
                        Text(IOSPairingPresentation.iCloudUnavailableDetail)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    iCloudSyncPairingSection

                    Spacer(minLength: 24)
                }
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let skip = onSkip {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Skip") { skip() }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { bridge.setup() }
        }
    }

    @ViewBuilder
    private var iCloudSyncPairingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().padding(.horizontal, 48)

            VStack(alignment: .leading, spacing: 8) {
                Label(IOSPairingPresentation.manualSectionTitle, systemImage: "lock.icloud")
                    .font(AppFont.section)
                    .padding(.horizontal, 32)

                Text(IOSPairingPresentation.manualSectionDetail)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            GlassCard(
                tint: pairingStore.isICloudSigned ? .green : .orange,
                cornerRadius: 14
            ) {
                HStack(spacing: 8) {
                    PulsingDot(color: pairingStore.isICloudSigned ? .green : .orange)
                    Text(pairingStore.isICloudSigned ? "Pairing key configured" : "No pairing key — iCloud actions will fail")
                        .font(AppFont.body)
                        .foregroundStyle(pairingStore.isICloudSigned ? .green : .orange)
                }
            }
            .padding(.horizontal, 32)

            if let err = iCloudSecretError {
                Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal, 32)
            }
            if let ok = iCloudSecretSuccess {
                Text(ok).foregroundStyle(.green).font(.caption).padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(IOSPairingPresentation.manualFieldHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                TextField("Paste base64 key here…", text: $pastedSecretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal, 32)

                Text(IOSPairingPresentation.manualLengthDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Button("Save Pairing Key") {
                    // 2026-09-06: ask the device transport for the Mac's
                    // published material first. On a Mac with no KVS
                    // entitlement that record is the only thing this key can be
                    // verified against.
                    Task {
                        await pairingStore.refreshPublishedPairingSecretForVerification()
                        saveICloudSecretFromPaste()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.horizontal, 32)
                .disabled(pastedSecretKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func connectViaICloud() {
        guard pairingStore.isICloudSigned else {
            errorMessage = IOSPairingPresentation.missingKeyMessage
            return
        }
        pairingStore.applyICloudPairing()
        onPaired?()
    }

    private func saveICloudSecretFromPaste() {
        iCloudSecretError = nil
        iCloudSecretSuccess = nil
        let trimmed = pastedSecretKey.trimmingCharacters(in: .whitespaces)
        switch ManualPairingKeyPaste.verdict(
            base64: trimmed,
            publishedMacSecret: pairingStore.publishedICloudPairingSecretForVerification()
        ) {
        case .looksLikeHex:
            iCloudSecretError = "That looks like hex — use the base64 key from the Mac app."
        case .invalidFormat:
            iCloudSecretError = "Invalid key: must be 44-char base64 encoding of 32 bytes."
        case .awaitingMacVerification:
            iCloudSecretError = "The key is well formed, but the Mac pairing record has not arrived to verify it yet. Keep this screen open and try again."
        case .doesNotMatchMac:
            iCloudSecretError = "That key does not match the current Mac pairing key. Copy a new key from the Mac app and try again."
        case .verified:
            guard pairingStore.applyICloudSecret(base64: trimmed) else {
                iCloudSecretError = "The verified key could not be stored securely. Try again after unlocking this iPhone."
                return
            }
            iCloudSecretSuccess = "Pairing key verified with the Mac and saved. iCloud actions will now be signed."
            pastedSecretKey = ""
            if pairingStore.isICloudPaired {
                onPaired?()
            }
        }
    }
}
