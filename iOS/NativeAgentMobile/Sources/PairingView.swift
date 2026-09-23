// Phase 14e-iCloud HMAC self-heal: iCloud-only pairing flow.
// The legacy LAN/HTTP transport (QR scan + bearer token) was retired in the
// iOS iCloud-only sweep (see MacBridgeClient.swift). This view now offers only:
//   1) Automatic iCloud KVS bootstrap (no user input — happens on init).
//   2) Check for Mac: re-read the Mac's published pairing key.
import SwiftUI
import NativeAgentShared

enum IOSPairingPresentation {
    private static var appName: String {
        NativeAgentIdentity.displayName(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    }
    private static var macPairingRoute: String { "\(appName) Settings on your Mac → Pair iPhone / iPad" }
    static let title = "Pair with the Mac app to get started."
    /// The operating requirement, stated at pairing: this phone is a window
    /// onto the Mac, so the Mac has to be up for anything to happen.
    static var macDependence: String {
        "The agent runs on your Mac. Keep it awake with \(appName) running for replies and actions from your phone."
    }
    static var iCloudReadyDetail: String { "1. Open \(appName) on your Mac.\n2. Use the same Apple Account on both devices.\n3. Wait for the pairing key, then tap Connect." }
    static let iCloudUnavailableDetail = "1. Open iPhone Settings -> Apple Account.\n2. Sign in with the same account as your Mac and turn on iCloud Drive.\n3. Return here to pair."
    static var manualSectionTitle: String { "Pairing key from \(appName)" }
    static var manualSectionDetail: String { "Open \(macPairingRoute), then tap Check for Mac. Keep the Mac app open and both devices connected to the internet." }
    static var missingKeyMessage: String { "The Mac’s pairing details haven’t arrived. Open \(macPairingRoute), check that both devices are online, then tap Check for Mac again." }
    static var notSignedSyncMessage: String { "iCloud sync is waiting for pairing. Open \(macPairingRoute), then open Pair with Mac on this phone and tap Check for Mac." }
    static var signatureRetryMessage: String { "The Mac could not verify this phone’s pairing key. Open \(macPairingRoute), then open Pair with Mac on this phone and tap Check for Mac." }
}

struct PairingView: View {
    var onSkip: (() -> Void)? = nil
    var onPaired: (() -> Void)? = nil

    @EnvironmentObject private var pairingStore: PairingStore
    @ObservedObject private var bridge = iCloudBridge.shared
    @State private var errorMessage: String?
    @State private var iCloudSecretError: String?
    @State private var isCheckingForMac = false
    @State private var phoneCode = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    if !phoneCode.isEmpty {
                        Text("This phone’s code").font(.headline)
                        Text(phoneCode).font(.caption.monospaced()).textSelection(.enabled)
                        Text("On your Mac, open Settings → Pair iPhone / iPad. Match this code and choose Pair, then tap Connect again.")
                            .font(.subheadline)
                    }
                    Spacer(minLength: 24)

                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)

                    VStack(spacing: 8) {
                        Text("NativeAgent Mobile").font(.title2.weight(.semibold))
                        Text(IOSPairingPresentation.title)
                            .font(.body)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                            .multilineTextAlignment(.center)
                        Text(IOSPairingPresentation.macDependence)
                            .font(.subheadline)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("pairing.mac-dependence")
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
                                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                            Text("iCloud detected")
                                .font(.headline)
                            Text(IOSPairingPresentation.iCloudReadyDetail)
                                .font(.subheadline)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                            .tint(pairingStore.isICloudSigned ? NativeAgentPalette.agentAccent : .gray)
                            .controlSize(.large)
                            .padding(.horizontal, 32)
                            .disabled(!pairingStore.isICloudSigned)
                        }
                    } else {
                        Text(IOSPairingPresentation.iCloudUnavailableDetail)
                            .font(.callout)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32)
                    }

                    iCloudSyncPairingSection

                    Spacer(minLength: 24)
                }
            }
            .mobileReadingScreen()
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let skip = onSkip {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Skip") { skip() }
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
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
                    .font(.headline)
                    .padding(.horizontal, 32)

                Text(IOSPairingPresentation.manualSectionDetail)
                    .font(.callout)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .padding(.horizontal, 32)
            }

            MobileReadingSurface {
                MobileAdaptiveRow(spacing: 8) {
                    Image(systemName: pairingStore.isICloudSigned ? "checkmark.circle" : "icloud.slash")
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    Text(isCheckingForMac ? "Checking for Mac…" : pairingStore.isICloudSigned ? "Mac pairing details available" : !bridge.available ? "iCloud is unavailable. Check your Apple Account and internet connection." : "Waiting for the Mac’s pairing details")
                        .font(.body)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            }
            .padding(.horizontal, 32)

            Button("Check for Mac") {
                Task {
                    isCheckingForMac = true
                    iCloudSecretError = nil
                    await pairingStore.refreshFromKVS()
                    await bridge.drainDeviceTransport()
                    isCheckingForMac = false
                    if !pairingStore.isICloudSigned {
                        iCloudSecretError = bridge.available
                            ? IOSPairingPresentation.missingKeyMessage
                            : IOSPairingPresentation.iCloudUnavailableDetail
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 32)
            .disabled(isCheckingForMac)

            if let err = iCloudSecretError {
                Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal, 32)
            }
        }
    }

    private func connectViaICloud() {
        guard pairingStore.isICloudSigned else {
            errorMessage = IOSPairingPresentation.missingKeyMessage
            return
        }
        pairingStore.applyICloudPairing()
        Task {
            do {
                let key = try PhoneSigningIdentity.key()
                phoneCode = DeviceApprovalSignature.deviceID(publicKey: key.publicKey.rawRepresentation)
                iCloudSyncEngine.shared.pairingStore = pairingStore
                let id = try await iCloudSyncEngine.shared.sendAction(.make(action: "pairDevice", payload: [:]), intentionalNewRequest: true)
                let response = try iCloudSyncEngine.shared.requireSuccessfulActionResponse(
                    await iCloudSyncEngine.shared.pollWithTimeout(msgId: id, timeout: 30, interval: 0.5, expectedAction: "pairDevice")
                )
                guard response["ok"] == "true" else {
                    errorMessage = response["message"] ?? "Choose Pair on your Mac, then connect again."
                    return
                }
                onPaired?()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
