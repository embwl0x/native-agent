import Foundation
import Combine
import NativeAgentShared
#if canImport(UIKit)
import UIKit
#endif
// Blueprint: | `MacBridgeClient.swift` | Signed iCloud chat transport, pairing and connection observation |

@MainActor
enum MacBridgeReconnectPolicy {
    static func delayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        attempt < 60 ? 500_000_000 : 5_000_000_000
    }
}

/// Refresh only while an age can change the connection or its displayed recency.
enum MacConnectionRefreshPolicy {
    /// Cadence while a presence, startup or transport boundary is imminent.
    static let activeInterval: TimeInterval = 5
    /// Foreground presence rereads are at most once a minute.
    static let presenceRefreshInterval: TimeInterval = 60

    /// Seconds until the next recompute, or nil when nothing time-dependent
    /// remains — the availability publisher and any Mac confirmation re-arm it.
    static func refreshInterval(
        now: Date,
        lastSeenAt: Date?,
        connectingStartedAt: Date?,
        bridgeUnavailableSince: Date?,
        isPaired: Bool,
        recentLastSeenInterval: TimeInterval,
        initialConnectingInterval: TimeInterval,
        macUnreachableThreshold: TimeInterval
    ) -> TimeInterval? {
        if let connectingStartedAt,
           now.timeIntervalSince(connectingStartedAt) <= initialConnectingInterval {
            return activeInterval
        }
        // Paired + unavailable is still counting up to the transport diagnosis.
        if isPaired, let bridgeUnavailableSince,
           now.timeIntervalSince(bridgeUnavailableSince) < macUnreachableThreshold {
            return activeInterval
        }
        if let lastSeenAt {
            // After the presence window, refresh at minute or hour granularity.
            let age = now.timeIntervalSince(lastSeenAt)
            if age <= recentLastSeenInterval { return max(activeInterval, recentLastSeenInterval - age) }
            return age < 3600 ? presenceRefreshInterval : 3600
        }
        // Never seen, not connecting, already past the unreachable threshold:
        // the projection is settled until an event changes an input.
        return nil
    }
}

@MainActor
final class MacBridgeClient: ObservableObject {
    private let bridge: iCloudBridge
    @Published private(set) var connection = NAPhoneConnection(
        pairing: .init(.waiting, AliveConnection.unpaired),
        transport: .init(.waiting, "Not connected yet; pairing starts it"),
        exchange: .init(.waiting, "Not heard from your Mac yet")
    )
    @Published var lastSeenAt: Date? {
        didSet { refreshConnection() }
    }

    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var bridgeAvailabilityCancellable: AnyCancellable?
    private var macKeyCancellable: AnyCancellable?
    private var pairingCancellable: AnyCancellable?
    /// The key the account's Mac pairing record held when last read.
    @Published private(set) var macPairingKey: iCloudBridge.MacPairingKeyReading?
    private var networkPathCancellable: AnyCancellable?
    private var statusRefreshTask: Task<Void, Never>?
    private let pathObserver: NetworkPathObserver = .shared
    /// Resume queued sends on network restoration; replay a missed event when the callback is set.
    var onNetworkPathRestored: (() -> Void)? {
        didSet {
            guard missedPathRestore, let onNetworkPathRestored else { return }
            missedPathRestore = false
            onNetworkPathRestored()
        }
    }
    private var missedPathRestore = false
    /// When the presence beat was last re-read, only while the app is open.
    private var presenceRereadAt: Date?
    /// nil until NWPathMonitor reports; nil never paints an outage. Republished
    /// here so views observing the client see the transition.
    @Published private(set) var deviceIsOffline: Bool?
    /// Banner copy for the offline case, or nil when there is nothing to say.
    var offlineBannerMessage: String? {
        NetworkPathObserver.offlineBannerMessage(isOffline: deviceIsOffline)
    }
    var connectingStartedAt: Date?
    private var bridgeUnavailableSince: Date?
    /// Pairing distinguishes an unreachable Mac after 30 seconds of bridge unavailability.
    weak var pairingStore: PairingStore? {
        didSet {
            pairingCancellable = pairingStore?.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.refreshConnection() }
            }
            refreshConnection()
        }
    }

    /// NAMacPresence defines the phone's window for the Mac's two-minute idle heartbeat.
    private static let recentLastSeenInterval = NAMacPresence.phoneWindow
    private static let initialConnectingInterval: TimeInterval = 30
    private static let macUnreachableThreshold: TimeInterval = 30

    init(bridge: iCloudBridge = .shared) {
        self.bridge = bridge
        bridgeAvailabilityCancellable = bridge.$available.combineLatest(bridge.$accountFailure, bridge.$lastMacConfirmationAt)
            .sink { [weak self] _, _, _ in
                Task { @MainActor in
                    if let timestamp = self?.bridge.lastMacConfirmationAt {
                        self?.recordMacConfirmation(at: timestamp)
                    }
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
                    // An already-online cold launch also resumes retained sends.
                    if wasOffline != false, offline == false {
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
        if let reading = macPairingKey, reading.phoneKey == pairingStore.iCloudPairingSecret,
           reading.recordKey != reading.phoneKey {
            return .init(.broken, "My key isn\u{2019}t your Mac\u{2019}s anymore", owner: .personOnPhone,
                         lever: "Your Mac holds a newer pairing key, or another Mac took the pairing. Tap Pair with Mac to take your Mac\u{2019}s current key.")
        }
        guard pairingStore.isICloudPaired else {
            return .init(.waiting, "Waiting for you to pair on your Mac", owner: .personOnMac,
                         lever: "On your Mac, open Connectors \u{203A} iPhone, match the code and choose Pair.")
        }
        return .init(.holds, "Paired with your Mac")
    }

    /// Each fact comes directly from this phone's pairing, transport and Mac evidence.
    private func assessedConnection(now: Date) -> NAPhoneConnection {
        var transport = NAPhoneConnection.Fact(.holds, "iCloud is carrying our messages")
        var exchange = NAPhoneConnection.Fact(.waiting, "Not heard from your Mac yet")
        let connecting = connectingStartedAt.map { now.timeIntervalSince($0) <= Self.initialConnectingInterval } ?? false
        if deviceIsOffline == true {
            transport = .init(.broken, "You\u{2019}re offline. I\u{2019}ll send when you\u{2019}re back", owner: .network,
                         lever: "Reconnect this iPhone to Wi-Fi or cellular data.")
        } else if bridge.accountFailure != nil {
            transport = .init(.broken, DeviceSyncAccountFailure.phoneMessage, owner: .iCloudAccount,
                         lever: "Open Settings \u{203A} Apple Account on this iPhone and finish signing in to iCloud.")
        } else if bridge.available, let lastSeenAt, now.timeIntervalSince(lastSeenAt) <= Self.recentLastSeenInterval {
            exchange = .init(.holds, "Heard from your Mac \(lastSeenAt.formatted(date: .omitted, time: .shortened))")
        } else if connecting {
            transport = .init(.waiting, "Finding your Mac\u{2026}")
        } else if bridge.available || (pairingStore?.isPaired == true
                    && bridgeUnavailableSince.map { now.timeIntervalSince($0) >= Self.macUnreachableThreshold } == true) {
            let heard = lastSeenAt.map { " Last heard \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            exchange = .init(.waiting, AliveConnection.unreachable, owner: .personOnMac,
                         lever: "Open NativeAgent on your Mac and keep it awake." + heard)
            if !bridge.available {
                transport = .init(.waiting, "iCloud isn\u{2019}t connecting", owner: .network,
                                 lever: "Check this iPhone\u{2019}s connection; I keep trying.")
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
        connectingStartedAt = Date()
        bridge.setup()
        refreshConnection()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, generation == self.reconnectGeneration {
                self.bridge.setup()
                self.refreshConnection()
                if self.bridge.available { break }
                attempts += 1
                try? await Task.sleep(
                    nanoseconds: MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: attempts)
                )
            }
            guard generation == self.reconnectGeneration else { return }
            self.reconnectTask = nil
        }
    }

    func disconnect() {
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        connectingStartedAt = nil
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
            transactions: mailboxes.transactions, responses: mailboxes.responses, inbox: mailboxes.inbox
        )
        try bridge.requireIdleSendForConnectionRepair()
        try sync.requireIdleActionForConnectionRepair()
        try pairingStore.clearPairingForConnectionRepair()
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        statusRefreshTask?.cancel()
        connectingStartedAt = nil
        bridgeUnavailableSince = nil
        lastSeenAt = nil
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
        /// A caller-supplied correlation ID lets Stop name the run before send returns.
        messageID: String = UUID().uuidString,
        preparedMessage: BridgeMessage? = nil,
        expectedPairing: String? = nil,
        onPrepared: ((BridgeMessage) async throws -> Void)? = nil
    ) async throws -> String {
        let metadata = Self.chatSendMetadata(
            controls: controls,
            suppressRemoteUserAppend: suppressRemoteUserAppend,
            replacementAssistantMessageID: replacementAssistantMessageID
        )
        let references = try await Task.detached(priority: .utility) {
            try attachments.map { attachment in
                var reference = attachment
                if reference.type == "audio", reference.utterance != nil {
                    _ = try MobileLocalStorage.retainRecording(reference)
                    reference.utterance?.audioReference = "iphone-recording:\(reference.id)"
                    reference.base64 = ""
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
    ) -> [String: String] {
        var metadata = controls.metadata(transport: "icloud")
        if suppressRemoteUserAppend, let replacementAssistantMessageID {
            metadata["suppressUserAppend"] = "true"
            metadata["replacementAssistantMessageId"] = replacementAssistantMessageID.uuidString
        }
        return metadata
    }

    /// `runIDs` name the in-flight turns this Stop is for. The Mac cancels
    /// only a run it was given, so a send issued straight after Stop is never
    /// cancelled in place of the turn the user stopped.
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
            let generation = self?.reconnectGeneration
            Task { @MainActor in
                guard self?.reconnectGeneration == generation else { return }
                self?.recordMacConfirmation(at: msg.timestamp)
            }
            onMessage(msg)
        }
    }

    @discardableResult
    func observeICloudReplyRejections(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID? {
        // A record that failed verification is not the Mac speaking: it never
        // refreshes presence.
        bridge.observeRejectedMessages(onReject: onReject)
    }

    /// Observe unsigned signature_invalid_resync hints for chat send recovery.
    @discardableResult
    func observeICloudResyncHints(onHint: @escaping (BridgeMessage) -> Void) -> UUID? {
        // Unsigned, so it is no evidence the Mac is up.
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

    /// Only Mac-originated activity or a confirmed Mac action may refresh the
    /// status chip. Queuing an iPhone message proves iCloud accepted it, not
    /// that the Mac is awake to process it.
    func recordMacConfirmation(at timestamp: Date = Date()) {
        guard timestamp > (lastSeenAt ?? .distantPast) else { return }
        connectingStartedAt = nil
        lastSeenAt = timestamp
    }

    func refreshConnection(now: Date = Date()) {
        if bridge.available {
            bridgeUnavailableSince = nil
        } else if bridgeUnavailableSince == nil {
            bridgeUnavailableSince = now
        }
        var next = assessedConnection(now: now)
        // An old sighting waits for a foreground presence read before losing contact.
        if next.transport.state == .holds, next.exchange.state == .waiting, lastSeenAt != nil,
           UIApplication.shared.applicationState == .active,
           now.timeIntervalSince(presenceRereadAt ?? .distantPast) >= MacConnectionRefreshPolicy.presenceRefreshInterval {
            presenceRereadAt = now
            Task { @MainActor [weak self] in
                await self?.bridge.readMacPresence()
                self?.refreshConnection()
            }
            if connection.exchange.state == .holds { next.exchange = connection.exchange }
        }
        if connection != next {
            connection = next
        }
        rescheduleStatusRefresh(now: now)
    }

    /// Arm one recompute at the cadence the current ages justify.
    private func rescheduleStatusRefresh(now: Date) {
        statusRefreshTask?.cancel()
        guard let interval = MacConnectionRefreshPolicy.refreshInterval(
            now: now,
            lastSeenAt: lastSeenAt,
            connectingStartedAt: connectingStartedAt,
            bridgeUnavailableSince: bridgeUnavailableSince,
            isPaired: pairingStore?.isPaired == true,
            recentLastSeenInterval: Self.recentLastSeenInterval,
            initialConnectingInterval: Self.initialConnectingInterval,
            macUnreachableThreshold: Self.macUnreachableThreshold
        ) else {
            statusRefreshTask = nil
            return
        }
        statusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshConnection()
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
        // A refresh is also the missed-reply recovery path. Existing in-memory
        // rows do not prove that the latest Mac snapshot has been adopted.
        // The snapshot reader retains last-good rows if the read is unavailable.
        await engine.refreshChatTranscriptsSnapshot()
        return engine.transcriptRead(for: sid)
    }
}
