import SwiftUI
import NativeAgentShared

enum IOSPairingPresentation {
    private static var appName: String {
        NativeAgentIdentity.displayName(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    }
    static var macPairingRoute: String { """
        \(appName) on your Mac → Connectors → iPhone (in Simple view, ask your agent to pair this phone and open the pairing \
        card)
        """ }
    static let title = "Pair with the Mac app to get started."
    /// Explain at pairing that the phone depends on the Mac being awake.
    static var macDependence: String {
        "I run on your Mac. Keep it awake with \(appName) open and I can answer you here."
    }
    static var iCloudReadySteps: [String] { ["Open \(appName) on your Mac.", "Use the same Apple Account on both.",
        "Wait for the pairing key, then tap Connect."] }
    static let iCloudUnavailableSteps = ["Open Settings → Apple Account.", "Sign in with your Mac’s account.",
        "Come back here to pair."]
    static var iCloudUnavailableDetail: String { numbered(iCloudUnavailableSteps) }
    private static func numbered(_ steps: [String]) -> String {
        steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
    static var manualSectionDetail: String { """
        Open \(macPairingRoute), then tap Check for Mac. Keep the Mac app open and both devices connected to the \
        internet.
        """ }
    static var missingKeyMessage: String { """
        The Mac’s pairing details haven’t arrived. Open \(macPairingRoute), check that both devices are online, then tap Check \
        for Mac again.
        """ }
    static var notSignedSyncMessage: String { """
        iCloud sync is waiting for pairing. Open \(macPairingRoute), then open Pair with Mac on this phone and tap Check for \
        Mac.
        """ }
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
    /// The connect this screen is waiting on; a cancelled one may still be unwinding and must not touch the screen.
    @State private var connectionID: UUID?
    /// The pairing key the waiting connect was sent under; nil until it is sent.
    @State private var connectingWith: Data?
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
                                Text("""
                                    Open \(IOSPairingPresentation.macPairingRoute), match this code and choose Pair. This phone goes on by \
                                    itself once the Mac accepts it.
                                    """)
                                    .font(.subheadline).foregroundStyle(AlivePalette.secondary)
                            }
                            .aliveRow()
                        }
                    }

                    stepsCard

                    if let failure = pairingStore.secretStorageError {
                        Text(failure).foregroundStyle(.red).font(.callout)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    let canConnect = bridge.available && pairingStore.isICloudSigned
                    Button {
                        if canConnect {
                            connectionTask = Task { await connectViaICloud() }
                        } else { checkForMac() }
                    } label: {
                        Text(isConnecting ? "Waiting for Mac confirmation…" : isCheckingForMac ? "Checking for Mac…"
                            : canConnect ? "Connect" : "Check for Mac")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Capsule())
                            .aliveGlass(in: Capsule(), interactive: true,
                                        tint: HazeColor(stored: hazeColorRaw).control(dark: true, labelled: true))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting || isCheckingForMac)

                    if isConnecting {
                        Button("Cancel waiting") {
                            connectionTask?.cancel()
                            connectionTask = nil
                            connectionID = nil
                            isConnecting = false
                        }
                        .frame(maxWidth: .infinity)
                    }

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
            .onChange(of: pairingStore.macAcceptances) { _, _ in
                // The Mac's acceptance, by its answer or its own confirmation, ends any wait here and closes the screen.
                connectionTask?.cancel()
                connectionTask = nil
                connectionID = nil
                isConnecting = false
                onPaired?()
            }
            .task(id: pairingStore.iCloudPairingSecret) {
                // A connect sent under a key the Mac has since replaced cannot be answered; it goes again under the new one.
                if isConnecting, let sentWith = connectingWith, sentWith != pairingStore.iCloudPairingSecret, pairingStore.isICloudSigned {
                    connectionTask?.cancel()
                    connectionID = nil
                    isConnecting = false
                    connectionTask = Task { await connectViaICloud() }
                    return
                }
                guard pairingStore.connectionRepairPending else { return }
                if pairingStore.isICloudSigned {
                    connectionTask = Task { await connectViaICloud() }
                    await connectionTask?.value
                } else {
                    await pairingStore.refreshFromCloudKit()
                }
            }
        }
    }

    @AppStorage(HazeColor.key) private var hazeColorRaw = HazeColor.defaultValue.rawValue

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
                    Image(systemName: keyIsCurrent ? "checkmark.circle.fill" : bridge.available ? "clock" : "icloud.slash")
                        .foregroundStyle(keyIsCurrent
                                         ? AnyShapeStyle(HazeColor(stored: hazeColorRaw).swatch)
                                         : AnyShapeStyle(AlivePalette.secondary))
                        .frame(width: 28)
                }
                Text(isCheckingForMac ? "Checking for Mac…" : keyIsCurrent ? "Pairing key is here"
                    : pairingStore.isICloudSigned ? bridge.macPairingKey?.failure ?? "Checking this key against your Mac’s current one"
                    : !bridge.available ? "iCloud is unavailable on this phone." : "Waiting for the Mac’s pairing key")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
            }
            .aliveRow()
        }
    }

    /// "Here" means the key the Mac publishes now, read from iCloud, not any key this phone kept.
    private var keyIsCurrent: Bool { bridge.macPairingKey?.isCurrent(pairingStore.iCloudPairingSecret) == true }

    private func checkForMac() {
        Task {
            isCheckingForMac = true
            iCloudSecretError = nil
            await pairingStore.refreshFromCloudKit()
            // The Mac's acceptance may already be waiting in iCloud; reading it here needs no push.
            if pairingStore.isICloudSigned { _ = await bridge.pollIncomingNow() }
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
        let id = UUID()
        connectionID = id
        connectingWith = nil
        isConnecting = true
        defer {
            if connectionID == id {
                connectionID = nil
                connectingWith = nil
                isConnecting = false
            }
        }
        errorMessage = nil
        // Every Connect reads the Mac's current pairing key first: one sent under a replaced key would be turned away.
        await pairingStore.refreshFromCloudKit()
        guard connectionID == id else { return }
        // An acceptance already in iCloud closes this screen without another round trip.
        if pairingStore.isICloudSigned { _ = await bridge.pollIncomingNow() }
        guard connectionID == id, !Task.isCancelled else { return }
        guard pairingStore.isICloudSigned else {
            errorMessage = IOSPairingPresentation.missingKeyMessage
            return
        }
        let repairing = pairingStore.connectionRepairPending
        do {
            let key = try await PhoneSigningIdentity.shared.key()
            phoneCode = DeviceApprovalSignature.deviceID(publicKey: key.publicKey.rawRepresentation)
            let sync = iCloudSyncEngine.shared
            sync.pairingStore = pairingStore
            if repairing, let secret = pairingStore.iCloudPairingSecret {
                pairingStore.isRepairingConnection = true
                defer { pairingStore.isRepairingConnection = false }
                let mailboxes = sync.connectionRepairMailboxes()
                try await iCloudSyncEngine.reconcileActionsForConnectionRepair(
                    transactions: mailboxes.transactions, responses: mailboxes.responses,
                    currentSecret: secret
                )
            }
            try Task.checkCancellation()
            connectingWith = pairingStore.iCloudPairingSecret
            let result = try await iCloudSyncEngine.shared.sendActionAndWait(
                .make(action: "pairDevice", payload: [:]), intentionalNewRequest: true)
            try Task.checkCancellation()
            let response = try iCloudSyncEngine.shared.requireSuccessfulActionResponse(result)
            guard response["ok"] == "true" else {
                errorMessage = response["message"] ?? "Choose Pair on your Mac, then connect again."
                return
            }
            pairingStore.finishConnectionRepair()
            pairingStore.applyICloudPairing(acceptance: response[NAPairingConfirmation.acceptanceField])
        } catch is CancellationError {
        } catch where connectionID == id { errorMessage = error.localizedDescription } catch {}
    }
}
