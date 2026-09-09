// Mac-side automatic iCloud pairing with manual key transfer as a fallback.
import SwiftUI

enum PairingPublicationPresentation {
    static func error(kvsPublished: Bool, cloudKitPublished: Bool) -> String? {
        switch (kvsPublished, cloudKitPublished) {
        case (true, true):
            return nil
        case (false, true):
            return "The new key is saved and CloudKit updated, but KVS did not accept it. iPhones using KVS bootstrap may not receive the new pairing key until KVS recovers."
        case (true, false):
            return "The new key is saved and KVS updated, but CloudKit did not accept it. Paired iPhones may reject signed messages until CloudKit recovers."
        case (false, false):
            return "The new key is saved, but neither KVS nor CloudKit accepted it yet."
        }
    }
}

/// The pairing key is already rotated when either publication route fails, so
/// this warning must survive the settings view's local state. Otherwise a user
/// can navigate away and lose the only indication that every paired phone may
/// still hold the old key.
enum PairingPublicationHealth {
    static let warningDefaultsKey = "NativeAgent.pairing.publicationWarning.v1"

    @discardableResult
    static func record(
        kvsPublished: Bool,
        cloudKitPublished: Bool,
        defaults: UserDefaults = .standard
    ) -> String? {
        let warning = PairingPublicationPresentation.error(
            kvsPublished: kvsPublished,
            cloudKitPublished: cloudKitPublished
        )
        if let warning {
            defaults.set(warning, forKey: warningDefaultsKey)
        } else {
            defaults.removeObject(forKey: warningDefaultsKey)
        }
        return warning
    }

    static func currentWarning(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: warningDefaultsKey)
    }
}

struct MacPairingView: View {
    @ObservedObject private var bridge = iCloudBridge.shared
    @State private var secretBase64: String = ""
    @State private var manualPairingExpanded = false
    @State private var copied = false
    @State private var pairingError: String?
    @AppStorage(PairingPublicationHealth.warningDefaultsKey) private var pairingPublicationWarning = ""
    // S.3: confirmation before regenerate
    @State private var showRegenConfirm = false
    // S.4: reveal/hide key
    @State private var keyRevealed = false
    // S.7: stored Task so we can cancel the 30-s auto-hide timer
    @State private var revealTimer: Task<Void, Never>? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Open the Mac app and the companion app on your iPhone or iPad, using the same Apple Account on both devices. The pairing key arrives automatically through iCloud. Once it arrives, tap Connect on your phone or tablet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PairingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        PairingSectionLabel(text: "iCloud status")
                        Text(bridge.syncStatus)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let pairingError {
                    PairingNoticeCard(text: pairingError, systemImage: "exclamationmark.shield.fill")
                }

                if !pairingPublicationWarning.isEmpty {
                    PairingNoticeCard(
                        text: "Pairing delivery needs attention: \(pairingPublicationWarning)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                DisclosureGroup("Pairing hasn't connected?", isExpanded: $manualPairingExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Check that both devices use the same Apple Account. If the key has not arrived, copy it here and paste it into Pair with Mac in the companion app, then tap Connect.")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PairingNoticeCard(
                            text: "The pairing key is a secret. Do not screenshot it, share it, or photograph it — anyone holding it can sign messages to this Mac.",
                            systemImage: "lock.shield.fill"
                        )
                        PairingSectionLabel(text: "The pairing key")
                        PairingCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    // S.4: hide behind Reveal button; auto-hide after 30s
                                    if keyRevealed {
                                        Text(secretBase64)
                                            .font(PairingType.code)
                                            .foregroundStyle(NativeAgentShell.text)
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else {
                                        Text(String(repeating: "•", count: 40))
                                            .font(PairingType.code)
                                            .foregroundStyle(NativeAgentShell.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
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
                                    .disabled(secretBase64.isEmpty)
                                    Button(copied ? "Copied" : "Copy") {
                                        let pb = NSPasteboard.general
                                        pb.clearContents()
                                        pb.setString(secretBase64, forType: .string)
                                        copied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(secretBase64.isEmpty)
                                }
                                .frame(height: 28)

                                if secretBase64.isEmpty {
                                    Text("The key appears here once this Mac can read it.")
                                        .font(ShellType.caption)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                } else {
                                    Text("Revealing the key hides it again after thirty seconds.")
                                        .font(ShellType.caption)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                .onChange(of: manualPairingExpanded) { _, expanded in
                    if !expanded {
                        revealTimer?.cancel()
                        revealTimer = nil
                        keyRevealed = false
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    PairingSectionLabel(text: "Start over")
                    // S.3: confirmation dialog before regenerate
                    Button(role: .destructive) { showRegenConfirm = true } label: {
                        Text("Regenerate the pairing key")
                            .font(ShellType.labelMedium)
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Regenerate the pairing key?",
                        isPresented: $showRegenConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Regenerate", role: .destructive) { regenerateSecret() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The old key stops working immediately. Keep both apps open while iCloud delivers the new key to each paired iPhone and iPad. If it does not arrive, expand the manual pairing section to copy and paste the new key.")
                    }
                    Text("The old key stops working the moment a new one is made.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .task {
            // mainactor_icloud: currentSecretBase64() does blocking disk I/O —
            // read it off the MainActor (awaited to preserve ordering), then
            // hop back to mutate @State.
            let result = await Task.detached(priority: .utility) { () -> (String?, String?) in
                do {
                    return (try PairingSecretManager.currentSecretBase64(), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            if let secret = result.0 {
                pairingError = nil
                secretBase64 = secret
            } else {
                pairingError = "Pairing is unavailable. \(result.1 ?? "The Mac pairing key could not be loaded.")"
                secretBase64 = ""
            }
        }
        .onDisappear {
            // S.7: cancel the auto-hide timer so it doesn't fire on a stale view
            revealTimer?.cancel()
            revealTimer = nil
            keyRevealed = false
        }
    }

    // MARK: - Helpers

    private func regenerateSecret() {
        Task {
            // Make signing/verification explicitly unavailable before the
            // canonical bytes move. No inbound action can be accepted with the
            // previous cached key once rotation has begun.
            MacSyncEngine.shared.beginPairingSecretRotation()
            let result = await Task.detached(priority: .utility) { () -> (Data?, String?) in
                do {
                    return (try PairingSecretManager.rotateSecret(), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value

            guard let persistedSecret = result.0 else {
                MacSyncEngine.shared.finishPairingSecretRotation(with: nil)
                let detail = result.1 ?? "The existing key was preserved."
                pairingError = "Pairing key regeneration failed. \(detail)"
                return
            }

            // Re-open the HMAC boundary with the exact durably read-back bytes
            // BEFORE awaiting either network publication route.
            MacSyncEngine.shared.finishPairingSecretRotation(with: persistedSecret)
            async let kvsPublished = PairingSecretManager.publishMaterialToKVS(persistedSecret)
            async let cloudKitPublished = iCloudBridge.shared.publishPairingSecret(persistedSecret)
            let published = await (kvsPublished, cloudKitPublished)
            // Each publication route has a distinct consumer. Neither a KVS
            // success nor a CloudKit success may hide the other route's failure:
            // doing so leaves some paired iPhones stale while this screen
            // reports healthy delivery.
            pairingError = nil
            pairingPublicationWarning = PairingPublicationHealth.record(
                kvsPublished: published.0,
                cloudKitPublished: published.1
            ) ?? ""
            let newSecretBase64 = persistedSecret.base64EncodedString()
            secretBase64 = newSecretBase64
        }
    }
}

// MARK: - Page kit
//
// The page's own small vocabulary: the eyebrow that heads a run, the card the
// controls sit in, and the one notice shape. Everything else on this page is
// plain text on the sheet ShellPageFrame already draws.

/// 13 monospaced, for a value that is a code. `ShellType` has no monospaced
/// face, so this derives one from the token size rather than a literal.
private enum PairingType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
}

private struct PairingSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ShellType.labelSemibold)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.secondary)
    }
}

private struct PairingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .settingsCardSurface()
    }
}

/// Something the person has to know before they carry on: a card in the
/// trouble colour, never a painted strip.
private struct PairingNoticeCard: View {
    let text: String
    let systemImage: String

    var body: some View {
        PairingCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
                Text(text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
