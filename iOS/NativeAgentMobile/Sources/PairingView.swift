// Phase 14e-iCloud HMAC self-heal: iCloud-only pairing flow.
// The legacy LAN/HTTP transport (QR scan + bearer token) was retired in the
// iOS iCloud-only sweep (see MacBridgeClient.swift). This view now offers only:
//   1) Automatic iCloud KVS bootstrap (no user input — happens on init).
//   2) Check for Mac publication, then offer verified manual correction.
import SwiftUI
import NativeAgentShared

enum IOSPairingPresentation {
    private static var appName: String {
        NativeAgentIdentity.displayName(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    }
    private static var macPairingRoute: String { "\(appName) Settings on your Mac → Pair iPhone or iPad" }
    static let title = "Pair with the Mac app to get started."
    static var iCloudReadyDetail: String { "1. Open \(appName) on your Mac.\n2. Use the same Apple Account on both devices.\n3. Wait for the pairing key, then tap Connect." }
    static let iCloudUnavailableDetail = "1. Open iPhone Settings -> Apple Account.\n2. Sign in with the same account as your Mac and turn on iCloud Drive.\n3. Return here to pair."
    static var manualSectionTitle: String { "Pairing key from \(appName)" }
    static var manualSectionDetail: String { "Open \(macPairingRoute), then tap Check for Mac. Keep the Mac app open and both devices connected to the internet." }
    static var manualCorrectionDetail: String { "If the saved key needs correcting, copy the pairing key from \(macPairingRoute) and paste it here." }
    static let manualFieldHint = "Pairing key"
    static let manualLengthDetail = "Copy the full pairing key from the Mac app."
    static var missingKeyMessage: String { "The Mac’s pairing details haven’t arrived. Open \(macPairingRoute), check that both devices are online, then tap Check for Mac again." }
    static var notSignedSyncMessage: String { "iCloud sync is waiting for pairing. Open \(macPairingRoute), then open Pair with Mac on this phone and tap Check for Mac." }
    static var signatureRetryMessage: String { "The Mac could not verify this phone’s pairing key. Open \(macPairingRoute), then open Pair with Mac on this phone and tap Check for Mac." }

    static func canCorrectManually(hasCheckedForMac: Bool, publishedMacSecret: Data?) -> Bool {
        hasCheckedForMac && publishedMacSecret?.count == 32
    }
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
    @State private var isCheckingForMac = false
    @State private var hasCheckedForMac = false

    private var canCorrectManually: Bool {
        IOSPairingPresentation.canCorrectManually(
            hasCheckedForMac: hasCheckedForMac,
            publishedMacSecret: pairingStore.publishedICloudPairingSecretForVerification()
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
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
                    Text(isCheckingForMac ? "Checking for Mac…" : canCorrectManually ? "Mac pairing details available" : !bridge.available ? "iCloud is unavailable. Check your Apple Account and internet connection." : "Waiting for the Mac’s pairing details")
                        .font(.body)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            }
            .padding(.horizontal, 32)

            Button("Check for Mac") {
                Task {
                    isCheckingForMac = true
                    iCloudSecretError = nil
                    iCloudSecretSuccess = nil
                    await pairingStore.refreshPublishedPairingSecretForVerification()
                    hasCheckedForMac = true
                    isCheckingForMac = false
                    if !canCorrectManually {
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
            if let ok = iCloudSecretSuccess {
                Text(ok).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary).font(.caption).padding(.horizontal, 32)
            }

            if canCorrectManually {
            DisclosureGroup("Correct pairing key manually") {
                Text(IOSPairingPresentation.manualCorrectionDetail)
                    .font(.callout)
                Text(IOSPairingPresentation.manualFieldHint)
                    .font(.caption)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .padding(.horizontal, 32)

                TextField("Paste pairing key", text: $pastedSecretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal, 32)

                DisclosureGroup("Pairing key help") {
                    Text(IOSPairingPresentation.manualLengthDetail)
                        .font(.callout)
                }
                .padding(.horizontal, 32)

                Button("Save Pairing Key") {
                    // 2026-09-06: ask the device transport for the Mac's
                    // published material first. On a Mac with no KVS
                    // entitlement that record is the only thing this key can be
                    // verified against.
                    Task {
                        isCheckingForMac = true
                        await pairingStore.refreshPublishedPairingSecretForVerification()
                        saveICloudSecretFromPaste()
                        isCheckingForMac = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.horizontal, 32)
                .disabled(isCheckingForMac || pastedSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 32)
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
        let trimmed = pastedSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ManualPairingKeyPaste.verdict(
            base64: trimmed,
            publishedMacSecret: pairingStore.publishedICloudPairingSecretForVerification()
        ) {
        case .looksLikeHex, .invalidFormat:
            iCloudSecretError = IOSPairingPresentation.manualLengthDetail
        case .awaitingMacVerification:
            iCloudSecretError = IOSPairingPresentation.missingKeyMessage
        case .doesNotMatchMac:
            iCloudSecretError = "That key does not match the current Mac pairing key. Copy a new key from the Mac app and try again."
        case .verified:
            guard pairingStore.applyICloudSecret(base64: trimmed) else {
                iCloudSecretError = "The verified key could not be stored securely. Try again after unlocking this iPhone."
                return
            }
            iCloudSecretSuccess = "Pairing key verified with the Mac and saved."
            pastedSecretKey = ""
            if pairingStore.isICloudPaired {
                onPaired?()
            }
        }
    }
}
