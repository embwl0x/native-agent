// Phase 14e-iCloud HMAC self-heal: iCloud-only pairing flow.
// The legacy LAN/HTTP transport (QR scan + bearer token) was retired in the
// iOS iCloud-only sweep (see MacBridgeClient.swift). This view now offers only:
//   1) Automatic iCloud KVS bootstrap (no user input — happens on init).
//   2) Manual base64 HMAC paste as a fallback when KVS sync is delayed.
import SwiftUI

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
                        Text("Pair with the Mac app to get started.")
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
                            Text("NativeAgent connects to your Mac via iCloud. The Mac publishes a pairing key automatically — this device should pick it up within a few seconds.")
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
                        Text("Sign into iCloud in Settings → [Your Name] to enable pairing.")
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
                Label("Manual pairing key (fallback)", systemImage: "lock.icloud")
                    .font(AppFont.section)
                    .padding(.horizontal, 32)

                Text("Use this only if iCloud sync is delayed. Copy the pairing key from the Mac app (Settings → Pair iPhone) and paste it here.")
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
                Text("Paste the pairing key (base64, ~44 chars):")
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

                Text("Paste the base64 key from the Mac app (NOT hex). Length should be ~44 characters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Button("Save Pairing Key") {
                    saveICloudSecretFromPaste()
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
            errorMessage = "Waiting on the pairing key from your Mac. Make sure both devices are signed into the same iCloud account; the key arrives automatically via iCloud."
            return
        }
        pairingStore.applyICloudPairing()
        onPaired?()
    }

    private func saveICloudSecretFromPaste() {
        iCloudSecretError = nil
        iCloudSecretSuccess = nil
        let trimmed = pastedSecretKey.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 64,
           trimmed.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil {
            iCloudSecretError = "That looks like hex — use the base64 key from the Mac app."
            return
        }
        if pairingStore.applyICloudSecret(base64: trimmed) {
            iCloudSecretSuccess = "Pairing key saved. iCloud actions will now be signed."
            pastedSecretKey = ""
            if pairingStore.isICloudPaired {
                onPaired?()
            }
        } else {
            iCloudSecretError = "Invalid key: must be 44-char base64 encoding of 32 bytes."
        }
    }
}
