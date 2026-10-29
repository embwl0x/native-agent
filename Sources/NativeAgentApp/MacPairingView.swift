// Mac-side automatic iCloud pairing with manual key transfer as a fallback.
import SwiftUI
import DeviceSync
import NativeAgentShared

// Blueprint: | `MacPairingView.swift` | `MacPairingView`: shared pairing assessment, key presentation/rotation and reveal lifecycle; offscreen reads never generate keys |

struct MacPairingView: View {
    @Environment(AppModel.self) private var appModel
    private var sync: SyncFacade { appModel.engine.sync }
    // A quiet offscreen read of Connectors must not MAKE the pairing key it
    // is reading: `currentSecretBase64()` generates a missing secret on disk.
    // Offscreen we peek instead, and an absent key reads as absent.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    private var secretBase64: String { sync.secretBase64 }
    @State private var manualPairingExpanded = false
    @State private var copied = false
    private var pairingError: String? { sync.pairingError }
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

                // The operating requirement, said before he leaves the house:
                // the phone is a window onto this Mac, not a second brain.
                Text("I run on your Mac. Keep it awake with NativeAgent running for replies and actions from your phone.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.mac-dependence")

                // The connection is three facts, never one: pairing, iCloud and
                // the last accepted exchange, each with who can fix it and how.
                VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                    AliveEyebrow("Connection")
                    AliveGroupCard {
                        if let connection = sync.connection {
                            ForEach(connection.facts, id: \.label) { item in
                                PairingFactRow(label: item.label, fact: item.fact)
                            }
                            Text("Latest: \(sync.status)")
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else {
                            Text(sync.status)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let pairingError {
                    PairingNoticeCard(text: pairingError, systemImage: "exclamationmark.shield.fill")
                }

                // One phone follows one Mac. Another Mac on this Apple Account
                // has it; moving it here is the person's act, not a launch's.
                if sync.phonePairedElsewhere {
                    VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                        AliveEyebrow("Your iPhone")
                        AliveGroupCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Your iPhone is paired with another Mac (or an earlier install of NativeAgent) on this Apple Account. Moving it here disconnects it from that one.")
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Use my iPhone with this Mac") {
                                    Task { await sync.usePhoneHere() }
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("pairing.use-phone-here")
                            }
                        }
                    }
                }

                // One group card, a row per phone with its status pill.
                VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                    AliveEyebrow("Paired devices")
                    Text("Match the phone’s code before choosing Pair. Removing a phone stops it from deciding approvals.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AliveGroupCard {
                        if sync.phones.filter({ $0.status != .removed }).isEmpty {
                            Text("No phones paired yet. Open the companion app to request pairing.")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                        ForEach(sync.phones.filter { $0.status != .removed }) { phone in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phone.status == .paired ? "iPhone or iPad" : "Phone waiting to pair")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(NativeAgentShell.text)
                                    Text(phone.id)
                                        .font(PairingType.code)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                // A pending phone is waiting on you: the teal's one job.
                                ConnectorsStatusPill(
                                    text: phone.status == .paired ? "Paired" : "Waiting",
                                    tone: phone.status == .paired ? NativeAgentShell.calm : NativeAgentShell.needsYou)
                                if phone.status == .pending {
                                    Button("Pair") { Task { await sync.setStatus(.paired, id: phone.id) } }
                                }
                                Button("Remove", role: .destructive) { Task { await sync.setStatus(.removed, id: phone.id) } }
                            }
                        }
                    }
                    if let message = sync.message {
                        Text(message).foregroundStyle(NativeAgentShell.trouble)
                    }
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
                        AliveEyebrow("The pairing key")
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
                                            .foregroundStyle(NativeAgentShell.secondary)
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
                                                do { try await Task.sleep(for: .seconds(30)) }
                                                catch { return }
                                                // A cancelled older timer must not clear
                                                // the handle of a newly revealed key.
                                                keyRevealed = false
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
                        .padding(16).settingsCardSurface()
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
                    AliveEyebrow("Start over")
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
            sync.observeStatus()
            await sync.loadSecret(quiet: quietOffscreenRead)
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
        Task { await sync.regenerateSecret() }
    }

}

// MARK: - Page kit
//
// Pairing notices and code values use the shared page kit.

/// 13 monospaced, for a value that is a code. `ShellType` has no monospaced
/// face, so this derives one from the token size rather than a literal.
private enum PairingType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
}

/// One fact of the connection: what is true, its state, and the way on when
/// someone has to act.
private struct PairingFactRow: View {
    let label: String
    let fact: NAPhoneConnection.Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                Text(fact.line)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let lever = fact.lever, fact.state != .holds {
                    Text(lever)
                        .font(ShellType.caption)
                        .foregroundStyle(fact.state == .broken ? NativeAgentShell.trouble : NativeAgentShell.needsYou)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ConnectorsStatusPill(
                text: fact.state == .holds ? "OK" : fact.state == .waiting ? "Waiting" : "Needs fixing",
                tone: fact.state == .holds ? NativeAgentShell.calm
                    : fact.state == .waiting ? NativeAgentShell.needsYou : NativeAgentShell.trouble)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Something the person has to know before they carry on: a card in the
/// trouble colour, never a painted strip.
private struct PairingNoticeCard: View {
    let text: String
    let systemImage: String

    var body: some View {
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
        .padding(16).settingsCardSurface()
    }
}
