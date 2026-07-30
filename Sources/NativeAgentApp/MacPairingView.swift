// PATCH-2026-05-08: icloud-pairing-ui — Mac-side QR + copyable-key pairing screen
import CoreImage
import SwiftUI

struct MacPairingView: View {
    @State private var secretBase64: String = ""
    @State private var qrImage: NSImage? = nil
    @State private var copied = false
    // S.3: confirmation before regenerate
    @State private var showRegenConfirm = false
    // S.4: reveal/hide key
    @State private var keyRevealed = false
    // S.7: stored Task so we can cancel the 30-s auto-hide timer
    @State private var revealTimer: Task<Void, Never>? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GradientText(
                    text: "Pair iOS Device",
                    colors: [.blue, .cyan, .teal],
                    font: .title2.bold()
                )

                // S.2: screenshot/sharing warning
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                    Text("This QR code and key are SECRETS. Don't screenshot, share, or photograph them — anyone with this key can sign messages to your Mac.")
                        .font(.caption).foregroundStyle(.orange)
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                Text("Scan this QR code from the NativeAgent iOS app to enable secure iCloud sync. Without pairing, iOS messages are rejected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let qr = qrImage {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 240, height: 240)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Or paste this key into iOS manually:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        // S.4: hide behind Reveal button; auto-hide after 30s
                        if keyRevealed {
                            Text(secretBase64)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(repeating: "•", count: 40))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        Button(keyRevealed ? "Hide" : "Reveal") {
                            if keyRevealed {
                                // Hide immediately, cancel any pending timer
                                revealTimer?.cancel()
                                revealTimer = nil
                                keyRevealed = false
                            } else {
                                keyRevealed = true
                                revealTimer?.cancel()
                                revealTimer = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(30))
                                    if !Task.isCancelled { keyRevealed = false }
                                    revealTimer = nil
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        Button(copied ? "Copied!" : "Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(secretBase64, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                // S.3: confirmation dialog before regenerate
                Button(role: .destructive) { showRegenConfirm = true } label: {
                    Label("Regenerate Pairing Key", systemImage: "arrow.clockwise")
                }
                .help("Invalidates the existing pairing — you'll need to re-pair every iOS device.")
                .confirmationDialog(
                    "Regenerate Pairing Key?",
                    isPresented: $showRegenConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Regenerate", role: .destructive) { regenerateSecret() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This invalidates the current pairing — all paired iOS devices will need to re-pair with the new QR code.")
                }

                Spacer()
            }
            .padding(20)
        }
        .task {
            // mainactor_icloud: currentSecretBase64() does blocking disk I/O —
            // read it off the MainActor (awaited to preserve ordering), then
            // hop back to mutate @State.
            let secret = await Task.detached(priority: .utility) {
                PairingSecretManager.currentSecretBase64()
            }.value
            secretBase64 = secret
            qrImage = renderQR(payload: pairingPayloadJSON(secret: secret))
        }
        .onDisappear {
            // S.7: cancel the auto-hide timer so it doesn't fire on a stale view
            revealTimer?.cancel()
            revealTimer = nil
        }
    }

    // MARK: - Helpers

    private func pairingPayloadJSON(secret: String) -> String {
        let body: [String: Any] = ["type": "icloud_pairing", "secret": secret, "version": "1"]
        // .sortedKeys so Mac and iOS produce byte-identical JSON for any future HMAC over this payload
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func renderQR(payload: String) -> NSImage? {
        guard let data = payload.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private func regenerateSecret() {
        // mainactor_icloud: delete + regenerate + KVS publish are blocking
        // file/iCloud I/O — run them off the MainActor (awaited to preserve
        // ordering), then hop back to mutate @State.
        Task {
            let newSecret = await Task.detached(priority: .utility) { () async -> String in
                PairingSecretManager.deleteSecret()
                let secret = PairingSecretManager.currentSecretBase64()
                await PairingSecretManager.publishMaterialToKVS()
                return secret
            }.value
            // Public Developer ID builds use CloudKit without KVS. Republish
            // through the bridge's selected transport so a rotated canonical
            // key reaches every supported distribution lane.
            _ = await iCloudBridge.shared.publishCurrentPairingSecret()
            // Clear MacSyncEngine's cached secret AFTER the new bytes are on disk +
            // published — NOT before. Invalidating first opened a window where a
            // concurrent inbound iCloud validation could re-read and re-cache the
            // OLD secret mid-regeneration; doing it here guarantees the next read
            // picks up the new secret. (Cheap in-memory mutation on the MainActor.)
            MacSyncEngine.shared.invalidatePairingSecret()
            secretBase64 = newSecret
            qrImage = renderQR(payload: pairingPayloadJSON(secret: newSecret))
        }
    }
}
