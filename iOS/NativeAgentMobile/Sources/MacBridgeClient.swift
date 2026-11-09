import Foundation
import Combine
import NativeAgentShared
#if canImport(UIKit)
import UIKit
#endif
// Blueprint: | `MacBridgeClient.swift` | Signed iCloud chat transport, pairing and connection observation |

@MainActor
final class MacBridgeClient: ObservableObject {
    private let bridge: iCloudBridge
    @Published private(set) var connection = NAPhoneConnection(
        pairing: .init(.waiting, AliveConnection.unpaired),
        transport: .init(.waiting, "Not connected yet; pairing starts it"),
        exchange: .init(.waiting, "Not heard from your Mac yet")
    )
    var lastSeenAt: Date? { bridge.lastMacConfirmationAt }
    private var presenceExpiryTask: Task<Void, Never>?

    private var connectionGeneration = 0
    private var bridgeAvailabilityCancellable: AnyCancellable?
    private var macKeyCancellable: AnyCancellable?
    private var pairingCancellable: AnyCancellable?
    @Published private(set) var macPairingKey: iCloudBridge.MacPairingKeyReading?
    private var networkPathCancellable: AnyCancellable?
    private let pathObserver: NetworkPathObserver = .shared
    /// Replay a missed network-restoration event when the queue callback attaches.
    var onNetworkPathRestored: (() -> Void)? {
        didSet {
            guard missedPathRestore, let onNetworkPathRestored else { return }
            missedPathRestore = false
            onNetworkPathRestored()
        }
    }
    private var missedPathRestore = false
    /// Nil means NWPathMonitor has not reported, so it cannot establish an outage; republish changes for client-observing views.
    @Published private(set) var deviceIsOffline: Bool?
    var offlineBannerMessage: String? {
        NetworkPathObserver.offlineBannerMessage(isOffline: deviceIsOffline)
    }
    var isConnecting = false
    weak var pairingStore: PairingStore? {
        didSet {
            pairingCancellable = pairingStore?.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.refreshConnection() }
            }
            refreshConnection()
        }
    }

    init(bridge: iCloudBridge = .shared) {
        self.bridge = bridge
        bridgeAvailabilityCancellable = bridge.$available.combineLatest(bridge.$accountFailure, bridge.$lastMacConfirmationAt)
            .sink { [weak self] _, _, _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    if self?.bridge.lastMacConfirmationAt != nil { self?.isConnecting = false }
                    self?.refreshConnection()
                }
            }
        macKeyCancellable = bridge.$macPairingKey
            .sink { [weak self] key in
                Task { @MainActor in
                    self?.macPairingKey = key
                    self?.refreshConnection()
                }
            }
        networkPathCancellable = pathObserver.$isOffline
            .sink { [weak self] offline in
                Task { @MainActor in
                    guard let self else { return }
                    let wasOffline = self.deviceIsOffline
                    self.deviceIsOffline = offline
                    self.refreshConnection()
                    // Cold launch must resume retained sends even when the network was already online.
                    if wasOffline != false, offline == false {
                        self.bridge.setup()
                        self.bridge.startForegroundReceiving()
                        Task { await self.bridge.catchUpCloudKit() }
                        if let handler = self.onNetworkPathRestored { handler() }
                        else { self.missedPathRestore = true }
                    }
                }
            }
        pathObserver.start()
        refreshConnection()
    }

    private var pairingFact: NAPhoneConnection.Fact {
        guard let pairingStore, pairingStore.isICloudSigned else {
            return .init(.waiting, AliveConnection.unpaired, owner: .personOnPhone,
                         lever: "Tap Pair with Mac, with NativeAgent open on your Mac.")
        }
        if pairingStore.isRepairingConnection {
            return .init(.waiting, "Repairing the connection\u{2026}")
        }
        guard let reading = macPairingKey, reading.phoneKey == pairingStore.iCloudPairingSecret else {
            return .init(.waiting, "Waiting to read your Mac's pairing key", owner: .network,
                         lever: "Refresh the connection to read your Mac's current key.")
        }
        if let recordKey = reading.recordKey, recordKey != reading.phoneKey {
            return .init(.broken, "My key isn\u{2019}t your Mac\u{2019}s anymore", owner: .personOnPhone,
                         lever: "Your Mac holds a newer pairing key, or another Mac took the pairing. Tap Pair with Mac to take your Mac\u{2019}s current key.")
        }
        if let failure = reading.failure {
            return .init(.waiting, failure, owner: .network,
                         lever: "Refresh the connection when iCloud is available to read your Mac's current key.")
        }
        guard pairingStore.isICloudPaired else {
            return .init(.waiting, "Waiting for you to pair on your Mac", owner: .personOnMac,
                         lever: "On your Mac, open Connectors \u{203A} iPhone, match the code and choose Pair.")
        }
        return .init(.holds, "Paired with your Mac")
    }

    /// Derive connection facts only from this phone's pairing, transport and Mac evidence.
    private func assessedConnection() -> NAPhoneConnection {
        var transport = NAPhoneConnection.Fact(.holds, "iCloud is carrying our messages")
        var exchange = NAPhoneConnection.Fact(.waiting, "Not heard from your Mac yet")
        if deviceIsOffline == true {
            transport = .init(.broken, "You\u{2019}re offline. I\u{2019}ll send when you\u{2019}re back", owner: .network,
                         lever: "Reconnect this iPhone to Wi-Fi or cellular data.")
        } else if bridge.accountFailure != nil {
            transport = .init(.broken, DeviceSyncAccountFailure.phoneMessage, owner: .iCloudAccount,
                         lever: "Open Settings \u{203A} Apple Account on this iPhone and finish signing in to iCloud.")
        } else if bridge.available, let lastSeenAt,
                  case .current = StatusConnectionPresentation.syncState(lastSyncedAt: lastSeenAt, staleAfter: NAMacPresence.phoneWindow) {
            exchange = .init(.holds, "Heard from your Mac \(lastSeenAt.formatted(date: .omitted, time: .shortened))")
        } else if isConnecting {
            transport = .init(.waiting, "Finding your Mac\u{2026}")
        } else if bridge.available || pairingStore?.isPaired == true {
            let heard = lastSeenAt.map { " Last heard \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            exchange = .init(.waiting, "Waiting to hear from your Mac", owner: .personOnMac,
                         lever: "Open NativeAgent on your Mac and keep it awake." + heard)
            if !bridge.available {
                transport = .init(.waiting, "iCloud isn\u{2019}t connecting", owner: .network,
                                 lever: "Check this iPhone\u{2019}s connection, then refresh.")
            }
        } else if pairingStore?.isICloudSigned == true {
            transport = .init(.broken, AliveConnection.noICloud, owner: .iCloudAccount,
                             lever: "Sign in to iCloud in Settings on this iPhone, with the same Apple Account as your Mac.")
        } else {
            transport = .init(.waiting, "Not connected yet; pairing starts it")
        }
        return NAPhoneConnection(pairing: pairingFact, transport: transport, exchange: exchange)
    }

    func configureICloud() {
        isConnecting = true
        bridge.setup()
        refreshConnection()
    }

    func disconnect() {
        connectionGeneration += 1
        isConnecting = false
        bridge.tearDown()
        refreshConnection()
    }

    func repairConnection() async throws {
        guard let pairingStore else { throw SyncError.notSetup }
        guard !pairingStore.isRepairingConnection else {
            throw SyncError.busy("Connection repair is in progress.")
        }
        let sync = iCloudSyncEngine.shared
        try bridge.requireIdleSendForConnectionRepair()
        try sync.requireIdleActionForConnectionRepair()
        pairingStore.isRepairingConnection = true
        defer { pairingStore.isRepairingConnection = false }
        let mailboxes = sync.connectionRepairMailboxes()
        try await iCloudSyncEngine.reconcileActionsForConnectionRepair(
            transactions: mailboxes.transactions, responses: mailboxes.responses
        )
        try bridge.requireIdleSendForConnectionRepair()
        try sync.requireIdleActionForConnectionRepair()
        try pairingStore.clearPairingForConnectionRepair()
        connectionGeneration += 1
        isConnecting = false
        bridge.clearMacConfirmationForConnectionRepair()
        bridge.tearDown(preservingConsumers: true)
        sync.clearConnectionDeliveryHistory()
        refreshConnection()
        bridge.setup()
        refreshConnection()
    }

    // MARK: - Chat

    func sendMessage(
        _ text: String,
        sessionID: String?,
        controls: ChatRuntimeControls = .defaults,
        attachments: [MultimodalAttachment] = [],
        suppressRemoteUserAppend: Bool = false,
        replacementAssistantMessageID: UUID? = nil,
        /// Accept a caller-minted correlation so Stop can name the run before transport returns.
        messageID: String = UUID().uuidString,
        preparedMessage: BridgeMessage? = nil,
        expectedPairing: String? = nil,
        onPrepared: ((BridgeMessage) async throws -> Void)? = nil
    ) async throws -> String {
        let metadata = try Self.chatSendMetadata(
            controls: controls,
            suppressRemoteUserAppend: suppressRemoteUserAppend,
            replacementAssistantMessageID: replacementAssistantMessageID
        )
        let references = try await Task.detached(priority: .utility) {
            try attachments.map { attachment in
                var reference = attachment
                if reference.type == "audio", reference.utterance != nil {
                    guard reference.byteSize > 0, reference.byteSize <= ChatAttachmentTypeResolver.fileByteLimit,
                          let bytes = Data(base64Encoded: reference.base64), bytes.count == reference.byteSize else {
                        throw NSError(domain: "VoiceNote", code: 3, userInfo: [NSLocalizedDescriptionKey:
                            "The voice recording is missing or exceeds the 10 MB limit. Record a shorter note."])
                    }
                    _ = try MobileLocalStorage.retainRecording(reference)
                    reference.utterance?.audioReference = nil
                    reference.path = nil
                }
                return reference
            }
        }.value
        let msg = try await bridge.sendChatMessage(
            id: messageID,
            text: text,
            sessionID: sessionID,
            metadata: metadata,
            attachments: references,
            preparedMessage: preparedMessage,
            expectedPairing: expectedPairing,
            onPrepared: onPrepared
        )
        return msg.id
    }

    static func chatSendMetadata(
        controls: ChatRuntimeControls,
        suppressRemoteUserAppend: Bool,
        replacementAssistantMessageID: UUID?
    ) throws -> [String: String] {
        var metadata = try controls.metadata(transport: "icloud")
        if suppressRemoteUserAppend, let replacementAssistantMessageID {
            metadata["suppressUserAppend"] = "true"
            metadata["replacementAssistantMessageId"] = replacementAssistantMessageID.uuidString
        }
        return metadata
    }

    /// Stop names exact runs so a subsequent send cannot be cancelled in place of the work the user stopped.
    func steerChat(sessionID: String, runID: String, text: String) async throws -> Bool {
        try await iCloudSyncEngine.shared.steerChat(sessionId: sessionID, runId: runID, text: text)
    }

    func cancelChat(sessionID: String?, runIDs: [String] = []) async throws {
        let hasExplicitSession = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        _ = try await iCloudSyncEngine.shared.cancelChat(
            sessionId: sessionID,
            source: "ios_icloud",
            sourceKey: hasExplicitSession ? nil : NativeAgentICloudBridgeConstants.mobileSourceKey,
            runIDs: runIDs
        )
    }

    @discardableResult
    func observeICloudReplies(onMessage: @escaping (BridgeMessage) -> Void) -> UUID? {
        return bridge.observeIncomingMessages { [weak self] msg in
            let generation = self?.connectionGeneration
            Task { @MainActor in
                guard self?.connectionGeneration == generation else { return }
                self?.recordMacConfirmation(at: msg.timestamp)
            }
            onMessage(msg)
        }
    }

    @discardableResult
    func observeICloudReplyRejections(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID? {
        // Unverified records cannot refresh Mac presence.
        bridge.observeRejectedMessages(onReject: onReject)
    }

    @discardableResult
    func observeICloudResyncHints(onHint: @escaping (BridgeMessage) -> Void) -> UUID? {
        // Unsigned hints cannot prove Mac presence.
        bridge.observeResyncHints(onResync: onHint)
    }

    func removeICloudResyncHintObserver(_ id: UUID?) {
        bridge.removeResyncObserver(id)
    }

    func removeICloudReplyObserver(_ id: UUID?) {
        bridge.removeIncomingObserver(id)
    }

    func removeICloudReplyRejectionObserver(_ id: UUID?) {
        bridge.removeRejectedObserver(id)
    }

    @discardableResult
    func pollICloudRepliesNow() async -> Bool {
        let delivered = await bridge.pollIncomingNow()
        refreshConnection()
        return delivered
    }

    /// Only Mac activity or confirmed Mac actions refresh status; an accepted phone upload proves iCloud receipt only.
    func recordMacConfirmation(at timestamp: Date) {
        bridge.recordMacConfirmation(at: timestamp)
        isConnecting = false
        refreshConnection()
    }

    func refreshConnection() {
        presenceExpiryTask?.cancel()
        presenceExpiryTask = nil
        let next = assessedConnection()
        if connection != next { connection = next }
        guard let lastSeenAt else { return }
        let now = Date()
        let date = lastSeenAt.timeIntervalSince(now) > 60
            ? lastSeenAt.addingTimeInterval(-60) : lastSeenAt.addingTimeInterval(NAMacPresence.phoneWindow)
        let delay = date.timeIntervalSince(now)
        guard delay > 0 else { return }
        // Contact expiry changes only the displayed evidence; it never settles a message or declares the Mac stopped.
        presenceExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.refreshConnection()
        }
    }

    // MARK: - Chat history refresh (iCloud snapshot read)

    /// Preserve the distinction between an unpublished session and an explicitly empty transcript.
    func readChatTranscript(sessionID: String?) async -> MacTranscriptRead {
        let engine = iCloudSyncEngine.shared
        let sid: String
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sid = sessionID
        } else {
            return .unavailable
        }
        // Refresh may recover a missed reply; cached rows cannot prove newest-snapshot adoption, and unavailable reads must retain admitted rows.
        await engine.refreshChatTranscriptsSnapshot()
        return engine.transcriptRead(for: sid)
    }
}
