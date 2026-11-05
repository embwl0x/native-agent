import SwiftUI
import DeviceSync
import NativeAgentShared

// Blueprint: | `MacPairingView.swift` | `MacPairingView`: checked iCloud pairing; explicit rotation; quiet reads generate no keys |

struct MacPairingView: View {
    @Environment(AppModel.self) private var appModel
    private var sync: SyncFacade { appModel.engine.sync }
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    private var pairingError: String? { sync.pairingError }
    @State private var showRegenConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("""
                    Open the Mac app and the companion app on your iPhone or iPad, using the same Apple Account on both devices. The pairing key arrives \
                    automatically through iCloud. Once it arrives, tap Connect on your phone or tablet.
                    """)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("I run on your Mac. Keep it awake with NativeAgent running for replies and actions from your phone.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing.mac-dependence")

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

                // One phone follows one Mac; moving it between Macs requires the person's action, never launch.
                if sync.phonePairedElsewhere {
                    VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                        AliveEyebrow("Your iPhone")
                        AliveGroupCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("""
                                    Your iPhone is paired with another Mac (or an earlier install of NativeAgent) on this Apple Account. Moving it here \
                                    disconnects it from that one.
                                    """)
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

                VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                    AliveEyebrow("Paired devices")
                    Text("Match the phone’s code before choosing Pair. Removing a phone stops it from deciding approvals.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AliveGroupCard {
                        if sync.phones.filter({ $0.status != .removed }).isEmpty {
                            Text(noPhoneLine)
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
                                ConnectorsStatusPill(
                                    text: phone.status == .paired ? "Can approve" : "Waiting",
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

                VStack(alignment: .leading, spacing: 12) {
                    AliveEyebrow("Pairing delivery")
                    Text("""
                        Use the same Apple Account on both devices and keep both apps online. The Connection facts above show what iCloud needs. After \
                        fixing it, check delivery here, then tap Check for Mac on your phone.
                        """)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(sync.isCheckingPairing ? "Checking iCloud delivery…" : "Check iCloud delivery") {
                        Task { await sync.checkPairingDelivery() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sync.isCheckingPairing)
                    .accessibilityIdentifier("pairing.check-delivery")
                }

                VStack(alignment: .leading, spacing: 12) {
                    AliveEyebrow("Start over")
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
                        Text("""
                            The old key stops working immediately. Keep both apps open while iCloud delivers the new key to each paired iPhone and iPad. If \
                            delivery needs attention, follow the Connection facts and choose Check iCloud delivery.
                            """)
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
    }

    // MARK: - Helpers

    /// A phone that chats over the shared key is connected before it can approve, so an empty list never reads as "no phone".
    private var noPhoneLine: String {
        sync.standing?.connected == true
            ? """
                Your iPhone is connected over iCloud, but it hasn’t asked to pair. Open the companion app and tap Connect; it appears here for you to \
                choose Pair.
                """
            : "No phone can approve yet. Open the companion app and tap Connect to request pairing."
    }

    private func regenerateSecret() {
        Task { await sync.regenerateSecret() }
    }

}

// MARK: - Page kit

/// Derive monospaced code size from ShellType because that token has no monospaced face.
private enum PairingType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
}

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
