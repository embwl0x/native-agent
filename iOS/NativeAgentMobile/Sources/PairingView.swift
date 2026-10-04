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
    /// The operating requirement, stated at pairing, in the agent's own voice:
    /// this phone is a window onto the Mac, so the Mac has to be up.
    static var macDependence: String {
        "I run on your Mac. Keep it awake with \(appName) open and I can answer you here."
    }
    static var iCloudReadySteps: [String] { ["Open \(appName) on your Mac.", "Use the same Apple Account on both.", "Wait for the pairing key, then tap Connect."] }
    static let iCloudUnavailableSteps = ["Open Settings → Apple Account.", "Sign in with your Mac’s account and turn on iCloud Drive.", "Come back here to pair."]
    static var iCloudReadyDetail: String { numbered(iCloudReadySteps) }
    static var iCloudUnavailableDetail: String { numbered(iCloudUnavailableSteps) }
    private static func numbered(_ steps: [String]) -> String {
        steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
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
    @State private var isConnecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var phoneCode = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        AlivePageHeader(title: "Welcome.")
                        Text(IOSPairingPresentation.macDependence)
                            .font(.body)
                            .lineSpacing(4)
                            .foregroundStyle(AlivePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pairing.mac-dependence")
                    }
                    .padding(.top, 24)

                    if !phoneCode.isEmpty {
                        AliveCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("This phone’s code").font(.headline).foregroundStyle(AlivePalette.text)
                                Text(phoneCode).font(.callout.monospaced()).textSelection(.enabled)
                                    .foregroundStyle(AlivePalette.text)
                                Text("On your Mac, open Settings → Pair iPhone / iPad, match this code and choose Pair. Then tap Connect again.")
                                    .font(.subheadline).foregroundStyle(AlivePalette.secondary)
                            }
                            .aliveRow()
                        }
                    }

                    stepsCard

                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    // One way forward: Connect once the Mac's key is here,
                    // otherwise look for it again.
                    let canConnect = bridge.available && pairingStore.isICloudSigned
                    Button {
                        if canConnect {
                            connectionTask = Task { await connectViaICloud() }
                        } else { checkForMac() }
                    } label: {
                        Text(isConnecting ? "Waiting for Mac confirmation…" : isCheckingForMac ? "Checking for Mac…" : canConnect ? "Connect" : "Check for Mac")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Capsule())
                            .aliveGlass(in: Capsule(), interactive: true,
                                        tint: HazeColor(stored: hazeColorRaw).control(dark: true, labelled: true))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting || isCheckingForMac)

                    VStack(alignment: .leading, spacing: 8) {
                        if let err = iCloudSecretError {
                            Text(err).foregroundStyle(.red).font(.footnote)
                        }
                        Text(IOSPairingPresentation.manualSectionDetail)
                            .font(.footnote)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .alivePageChrome(title: "Pair with Mac", root: false)
            .toolbar {
                if let skip = onSkip {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Skip") { skip() }
                            .foregroundStyle(AlivePalette.text)
                    }
                }
            }
            .onAppear { bridge.setup() }
            .onDisappear { connectionTask?.cancel() }
            .task(id: pairingStore.iCloudPairingSecret) {
                guard pairingStore.connectionRepairPending else { return }
                if pairingStore.isICloudSigned {
                    await connectViaICloud()
                } else {
                    await pairingStore.refreshFromKVS(allowDuringRepair: !bridge.usesCloudKitDeviceTransport)
                    await bridge.drainDeviceTransport()
                }
            }
        }
    }

    @AppStorage(HazeColor.key) private var hazeColorRaw = HazeColor.defaultValue.rawValue

    /// The steps as one card: three numbered steps, then whether the Mac's
    /// pairing key has arrived.
    private var stepsCard: some View {
        let steps = bridge.available ? IOSPairingPresentation.iCloudReadySteps : IOSPairingPresentation.iCloudUnavailableSteps
        return AliveCard {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { AliveDivider() }
                HStack(alignment: .center, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(AlivePalette.text)
                        .frame(width: 28, height: 28)
                        .background(AlivePalette.fill, in: Circle())
                        .overlay(Circle().strokeBorder(AlivePalette.highlight, lineWidth: 1))
                    Text(step)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .aliveRow()
            }
            AliveDivider()
            HStack(spacing: 10) {
                if isCheckingForMac {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: pairingStore.isICloudSigned ? "checkmark.circle.fill" : bridge.available ? "clock" : "icloud.slash")
                        .foregroundStyle(pairingStore.isICloudSigned
                                         ? AnyShapeStyle(HazeColor(stored: hazeColorRaw).swatch)
                                         : AnyShapeStyle(AlivePalette.secondary))
                        .frame(width: 28)
                }
                Text(isCheckingForMac ? "Checking for Mac…" : pairingStore.isICloudSigned ? "Pairing key is here" : !bridge.available ? "iCloud is unavailable on this phone." : "Waiting for the Mac’s pairing key")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
            }
            .aliveRow()
        }
    }

    private func checkForMac() {
        Task {
            isCheckingForMac = true
            iCloudSecretError = nil
            await pairingStore.refreshFromKVS(allowDuringRepair: !bridge.usesCloudKitDeviceTransport)
            await bridge.drainDeviceTransport()
            isCheckingForMac = false
            if !pairingStore.isICloudSigned {
                iCloudSecretError = bridge.available
                    ? IOSPairingPresentation.missingKeyMessage
                    : IOSPairingPresentation.iCloudUnavailableDetail
            }
        }
    }

    private func connectViaICloud() async {
        guard !isConnecting, !pairingStore.isRepairingConnection else { return }
        guard pairingStore.isICloudSigned else {
            errorMessage = IOSPairingPresentation.missingKeyMessage
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        errorMessage = nil
        let repairing = pairingStore.connectionRepairPending
        let deadline = Date().addingTimeInterval(60)
        do {
            let key = try PhoneSigningIdentity.key()
            phoneCode = DeviceApprovalSignature.deviceID(publicKey: key.publicKey.rawRepresentation)
            let sync = iCloudSyncEngine.shared
            sync.pairingStore = pairingStore
            if repairing, let secret = pairingStore.iCloudPairingSecret {
                try sync.requireIdleActionForConnectionRepair()
                pairingStore.isRepairingConnection = true
                defer { pairingStore.isRepairingConnection = false }
                let mailboxes = sync.connectionRepairMailboxes()
                try await iCloudSyncEngine.reconcileActionsForConnectionRepair(
                    transactions: mailboxes.transactions, responses: mailboxes.responses,
                    inbox: mailboxes.inbox, currentSecret: secret
                )
            }
            repeat {
                try Task.checkCancellation()
                let id = try await iCloudSyncEngine.shared.sendAction(.make(action: "pairDevice", payload: [:]), intentionalNewRequest: true)
                let result = await iCloudSyncEngine.shared.pollWithTimeout(
                    msgId: id, timeout: min(30, max(0, deadline.timeIntervalSinceNow)), interval: 0.5, expectedAction: "pairDevice"
                )
                try Task.checkCancellation()
                if repairing, result?["code"] == "device_not_verified", deadline.timeIntervalSinceNow > 10 {
                    try await Task.sleep(for: .seconds(10))
                    continue
                }
                let response = try iCloudSyncEngine.shared.requireSuccessfulActionResponse(result)
                guard response["ok"] == "true" else {
                    errorMessage = response["message"] ?? "Choose Pair on your Mac, then connect again."
                    return
                }
                pairingStore.finishConnectionRepair()
                pairingStore.applyICloudPairing()
                onPaired?()
                return
            } while Date() < deadline
            errorMessage = "Choose Pair on your Mac, then tap Connect again."
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}
