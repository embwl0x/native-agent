
import Foundation
import OSLog
import CryptoKit
import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `iCloudBridge.swift` | Authenticated delivery; bounded unknown-send observation, pre-dispatch receipt listeners and checked retention |

typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder

struct ICloudUnverifiedRecord: Codable, Identifiable {
    let id: String
    let kind: String
    let sender: String
    let timestamp: Date
    let reason: String
    let pairingVersion: Int64
    let keyDigest: String
}

struct ICloudBridgeRejectedMessage: Sendable {
    let messageID: String
    let correlationID: String?
    let reason: String

    /// Signed unread expiry proves nothing ran; only the user may authorize a fresh send.
    var isExpiredRequest: Bool { reason == "request_expired" }

    var userMessage: String {
        if isExpiredRequest {
            return "Your Mac received this after its request window expired. It wasn't started."
        }
        if reason == "clock_ahead" {
            return "Mac reply rejected: its timestamp is in the future. Check both devices' clocks and try again."
        }
        if reason == "stale timestamp" {
            return "Mac reply rejected: stale timestamp. Check both devices' clocks and try again."
        }
        return "Mac reply rejected: \(reason). Re-pair this iPhone with the current Mac app."
    }
}

@MainActor
final class iCloudBridge: ObservableObject {
    static let shared = iCloudBridge()

    @Published var available: Bool = false
    @Published private(set) var lastMacConfirmationAt: Date?

    func recordMacConfirmation(at timestamp: Date) {
        guard timestamp > (lastMacConfirmationAt ?? .distantPast) else { return }
        lastMacConfirmationAt = timestamp
    }

    /// Bind observed Mac pairing material to the phone key used to read it; installing a different key invalidates that evidence.
    struct MacPairingKeyReading: Equatable {
        let recordKey: Data
        let phoneKey: Data
    }
    @Published var macPairingKey: MacPairingKeyReading?

    func clearMacConfirmationForConnectionRepair() {
        lastMacConfirmationAt = nil
    }
    @Published var lastSyncAt: Date? {
        didSet {
            PhoneRequests.shared.syncDidSucceed()
            Task { await PhonePlaces.shared.publish() }
            PhoneSenses.shared.publish()
        }
    }
    @Published var syncStatus: String = "iCloud not checked" {
        didSet {
            if accountFailure != nil, syncStatus != DeviceSyncAccountFailure.phoneMessage {
                syncStatus = DeviceSyncAccountFailure.phoneMessage
            }
        }
    }
    @Published var accountFailure: DeviceSyncAccountFailure?
    private(set) var accountFailureGeneration: UInt64 = 0

    func recordAccountFailure(_ failure: DeviceSyncAccountFailure) {
        accountFailureGeneration &+= 1
        accountFailure = failure
        syncStatus = DeviceSyncAccountFailure.phoneMessage
    }

    let kvs = NSUbiquitousKeyValueStore.default
    private var activeSendCount = 0
    var driveURL: URL?
    var metadataQuery: NSMetadataQuery?
    // CloudKit requires checked selection and entitlement; nil means unavailable.
    var deviceTransport: CloudKitDeviceTransport?
    var usesCloudKitDeviceTransport: Bool { deviceTransport != nil }
    var onTransportSucceeded: (() -> Void)?
    var deviceDrainInFlight = false
    var deviceDrainQueued = false
    var foregroundReceiveTask: Task<Void, Never>?
    var foregroundPresenceTask: Task<Void, Never>?
    // Delivery keeps record IDs only; existing chat/action owners decide whether requests remain live.
    private var deliveryNudges: [String: String] = [:]
    private var deliveryNudgeKey: String?
    private var deliveryNudgeTask: Task<Void, Never>?
    /// Notify only at verified receipt admission; disappearing nudges/exchanges do not prove receipt.
    private var deliveryReceiptObservers: [UUID: (String, () -> Void)] = [:]

    func deliveryPairingMatches(_ secret: Data) -> Bool {
        deliveryNudgeKey == "mobile.icloud.unaccepted.\(keyDigest(secret))"
    }

    func deliveryPairingDidChange() {
        // Unknown authority cannot retire delivery, even when setup/foreground callers missed the material change.
        guard let material = pairingStore?.material, material != .unavailable else { return }
        let secret = material.secret
        let key = secret.map { "mobile.icloud.unaccepted.\(keyDigest($0))" }
        if deliveryNudgeKey != key {
            // A new key may now verify or accept what the old one could not.
            if deliveryNudgeKey != nil, key != nil { Task { await self.retryHeldMacRecords(force: true) } }
            if let deliveryNudgeKey { userDefaults.removeObject(forKey: deliveryNudgeKey) }
            deliveryNudgeTask?.cancel()
            deliveryNudgeTask = nil
            deliveryNudgeKey = key
            deliveryNudges = key.flatMap { userDefaults.dictionary(forKey: $0) as? [String: String] } ?? [:]
        }
        resumeDeliveryNudges()
    }

    func resumeDeliveryNudges() {
        guard let secret = pairingStore?.iCloudPairingSecret else { return }
        if !deliveryPairingMatches(secret) {
            deliveryPairingDidChange()
            return
        }
        guard deviceTransport != nil, let key = deliveryNudgeKey else { return }
        guard deliveryNudgeTask == nil, !deliveryNudges.isEmpty else { return }
        let generation = setupGeneration
        deliveryNudgeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.setupGeneration == generation, self.deliveryNudgeKey == key else { return }
            // The handle owns its wake deadline, never the delivery being awakened.
            self.deliveryNudgeTask = nil
            // Retain nudges while authority is unreadable; checked same-key publication resumes them without stale task handles.
            guard self.pairingStore?.iCloudPairingSecret == secret,
                  let transport = self.deviceTransport else { return }
            let chat = ChatStore.shared
            await chat.restorationTask?.value
            await PhonePlaces.shared.restorationTask?.value
            await PhoneSenses.shared.restorationTask?.value
            guard self.setupGeneration == generation, self.deliveryNudgeKey == key,
                  self.pairingStore?.iCloudPairingSecret == secret else { return }
            self.deliveryNudges = self.deliveryNudges.filter { _, correlation in
                if let exchange = chat.pendingExchanges[correlation], !exchange.isExpired { return true }
                return PhonePlaces.shared.ownsDelivery(correlation)
                    || PhoneSenses.shared.ownsDelivery(correlation)
                    || !iCloudSyncEngine.shared.sendingTransactions.isEmpty || ActionResponseWaiters.shared.isWaiting(correlation)
            }
            self.persistDeliveryNudges()
            guard !self.deliveryNudges.isEmpty else { return }
            await self.dispatchLatestKVSChatProgress(key: KVSKey.chatProgressLatest)
            _ = await self.drainDeviceTransport()
            for (record, correlation) in self.deliveryNudges {
                guard self.setupGeneration == generation, self.deliveryNudgeKey == key,
                      self.pairingStore?.iCloudPairingSecret == secret else { return }
                guard self.deliveryNudges[record] == correlation else { continue }
                do {
                    try await transport.resignalMessage(named: record)
                    guard self.setupGeneration == generation, self.deliveryNudges[record] == correlation,
                          self.pairingStore?.iCloudPairingSecret == secret else { continue }
                    self.kvs.set(UUID().uuidString, forKey: KVSKey.newMessageInDrive)
                    await PairingStore.synchronizeKVSWithTimeout()
                } catch {
                    guard self.setupGeneration == generation, self.deliveryNudgeKey == key,
                          self.pairingStore?.iCloudPairingSecret == secret else { return }
                    self.syncStatus = "Waiting for Mac acceptance — delivery nudge failed: \(error.localizedDescription)"
                }
            }
            self.resumeDeliveryNudges()
        }
    }

    private func persistDeliveryNudges() {
        guard let deliveryNudgeKey else { return }
        userDefaults.set(deliveryNudges, forKey: deliveryNudgeKey)
        if deliveryNudges.isEmpty {
            deliveryNudgeTask?.cancel()
            deliveryNudgeTask = nil
        }
    }

    /// Called only after direction, target and HMAC verification.
    private func acceptDelivery(_ message: BridgeMessage) async -> Bool {
        guard let correlation = message.correlationID else { return true }
        let generation = setupGeneration
        let secret = pairingStore?.iCloudPairingSecret
        guard await PhonePlaces.shared.acceptDelivery(correlation), setupGeneration == generation,
              pairingStore?.iCloudPairingSecret == secret else { return false }
        guard await PhoneSenses.shared.acceptDelivery(correlation), setupGeneration == generation,
              pairingStore?.iCloudPairingSecret == secret else { return false }
        for (expected, receive) in Array(deliveryReceiptObservers.values) where expected == correlation {
            receive()
        }
        stopDeliveryNudges(for: correlation)
        return true
    }

    /// Unknown outcomes permit observation only; failed/empty reads wait to the bounded deadline without resubmission.
    func confirmMessageDelivery(
        _ message: BridgeMessage,
        until deadline: Date,
        hasMacEvidence: () -> Bool = { false }
    ) async -> Bool {
        guard let transport = deviceTransport else { return hasMacEvidence() }
        let generation = setupGeneration
        let secret = pairingStore?.iCloudPairingSecret
        let correlation = message.metadata?["actionId"] ?? message.id
        var received = false
        let observer = UUID()
        deliveryReceiptObservers[observer] = (correlation, { received = true })
        defer { deliveryReceiptObservers.removeValue(forKey: observer) }
        var delay: TimeInterval = 1
        while !Task.isCancelled, generation == setupGeneration,
              secret == pairingStore?.iCloudPairingSecret {
            if received || hasMacEvidence() { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let matches = await transport.messageRecordMatches(message, timeoutSeconds: min(5, remaining))
            guard !Task.isCancelled, generation == setupGeneration,
                  secret == pairingStore?.iCloudPairingSecret else { return false }
            if matches || received || hasMacEvidence() { return true }
            let pause = min(delay, max(0, deadline.timeIntervalSinceNow))
            do { try await Task.sleep(for: .seconds(pause)) } catch { return false }
            delay = min(8, delay * 2)
        }
        guard !Task.isCancelled, generation == setupGeneration,
              secret == pairingStore?.iCloudPairingSecret else { return false }
        return received || hasMacEvidence()
    }

    func stopDeliveryNudges(for correlation: String) {
        guard deliveryNudges.values.contains(correlation) else { return }
        deliveryNudges = deliveryNudges.filter { $0.value != correlation }
        persistDeliveryNudges()
    }

    func isAwaitingMacAcceptance(_ correlation: String) -> Bool {
        deliveryNudges.values.contains(correlation)
    }
    private let userDefaults: UserDefaults
    @Published private(set) var unverifiedRecords: [ICloudUnverifiedRecord] = []
    @Published private(set) var unverifiedRecordsError: String?
    private let unverifiedRecordsKey = "mobile.icloud.unverifiedRecords.v1"

    private func keyDigest(_ secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Keep deferred IDs instance-local so relaunch/pairing changes reverify unclaimed records; persisted IDs are diagnostic only.
    private var deferredThisRun: [String: Set<String>] = [:]

    func isVerificationDeferred(_ id: String, secret: Data, version: Int64) -> Bool {
        deferredThisRun["\(version)|\(keyDigest(secret))"]?.contains(id) == true
    }

    func retainUnverified(_ msg: BridgeMessage, secret: Data, version: Int64, reason: String) {
        deferredThisRun["\(version)|\(keyDigest(secret))", default: []].insert(msg.id)
        unverifiedRecords.removeAll { $0.id == msg.id }
        unverifiedRecords.append(.init(id: msg.id, kind: msg.metadata?["kind"] ?? "chat",
            sender: msg.sender, timestamp: msg.timestamp, reason: reason,
            pairingVersion: version, keyDigest: keyDigest(secret)))
        persistUnverifiedRecords()
        NSLog("[iCloudBridge] verification_deferred id=%@ kind=%@ sender=%@ timestamp=%@ pairing_version=%lld reason=%@",
              msg.id, msg.metadata?["kind"] ?? "chat", msg.sender,
              ISO8601DateFormatter().string(from: msg.timestamp), version, reason)
    }

    private func persistUnverifiedRecords() {
        guard unverifiedRecordsError == nil else { return }
        do {
            let data = try JSONEncoder().encode(unverifiedRecords)
            userDefaults.set(data, forKey: unverifiedRecordsKey)
        } catch {
            unverifiedRecordsError = """
                Verification history could not be saved: \(error.localizedDescription). Repair iPhone local storage; existing saved \
                bytes are retained.
                """
        }
    }
    /// Resolve Drive mount off-main so container lookup cannot block the UI.
    private let ubiquityContainerURL: @Sendable (String?) -> URL?
    private var messageHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    private var rejectionHandlers: [UUID: (ICloudBridgeRejectedMessage) -> Void] = [:]
    // Unsigned signature_invalid_resync hints authorize pairing refresh only.
    private var resyncHintHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    /// Every Mac record this phone has handled, by when it first arrived. CloudKit keeps a record for `retentionWindow`, and a drain can
    /// re-read anything that old, so the phone remembers each one exactly that long: a record handled once is never handled again.
    private var seenMacRecords: [String: Date] = [:]
    var seenMessageIDs: Set<String> { Set(seenMacRecords.keys) }
    /// A drain saves what it handled once, when it ends; nothing is written per record.
    private var seenMacRecordsDirty = false
    /// Records the phone has refused, by id: how often and since when, and whether it now holds them (cursor moved past).
    private(set) var failingMacRecords: [String: FailingMacRecord] = [:]
    /// Why the record being admitted was refused this time.
    private var refusal: String?
    private var retriedHeldThisLaunch = false
    private static let failingMacRecordsURL = URL.applicationSupportDirectory.appending(path: "failing-mac-records.json")
    static let stuckAfterAttempts = 3
    static let stuckAfter: TimeInterval = 120
    private static let deliveryLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeAgentMobile", category: "delivery")
    private var seenKVSProgressMessageIDs: Set<String> = []
    private var seenKVSProgressMessageIDsOrdered: [String] = []
    var isCheckingMacOutbox = false
    var macOutboxScanQueued = false
    var setupTask: Task<Void, Never>?
    /// Drains wait for incoming registration before reading the inbox.
    var deviceIncomingSetupTask: Task<Void, Never>?
    private(set) var setupGeneration = 0
    private static let seenMacRecordsURL = URL.applicationSupportDirectory.appending(path: "seen-mac-records.json")
    private let maxSeenKVSProgressMessageIDs = 200

    weak var pairingStore: PairingStore?

    init(
        deviceTransport: CloudKitDeviceTransport? = nil,
        pairingStore: PairingStore? = nil,
        userDefaults: UserDefaults = .standard,
        ubiquityContainerURL: @escaping @Sendable (String?) -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: $0)
        }
    ) {
        self.deviceTransport = deviceTransport
        self.pairingStore = pairingStore
        self.userDefaults = userDefaults
        self.ubiquityContainerURL = ubiquityContainerURL
        do { unverifiedRecords = try MobileLocalStorage.restore([ICloudUnverifiedRecord].self, key: unverifiedRecordsKey, defaults: userDefaults) ?? [] }
        catch { unverifiedRecordsError = """
            Verification history could not be read: \(error.localizedDescription). Repair iPhone local storage; existing saved bytes are retained and will \
            not be replaced.
            """ }
        if let data = try? Data(contentsOf: Self.seenMacRecordsURL),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            seenMacRecords = saved
        }
        if let data = try? Data(contentsOf: Self.failingMacRecordsURL),
           let saved = try? JSONDecoder().decode([String: FailingMacRecord].self, from: data) {
            failingMacRecords = saved
        }
    }

    private func recordSeenMacReplyID(_ id: String) {
        guard seenMacRecords[id] == nil else { return }
        seenMacRecords[id] = Date()
    }

    var isSetUp = false

    func setup() {
        guard !isSetUp else { return }
        isSetUp = true
        setupGeneration += 1
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()

        do { try configureDeviceTransportIfAvailable() }
        catch {
            available = false
            syncStatus = "CloudKit unavailable: \(error.localizedDescription)"
            return
        }

        // CloudKit owns messages/snapshots; KVS supplies only progress and resync nudges.
        if deviceTransport != nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(kvsDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kvs
            )
            Task { await PairingStore.synchronizeKVSWithTimeout() }
            available = true
            syncStatus = "CloudKit ready"
            return
        }

        available = false
        syncStatus = "CloudKit unavailable: no transport was constructed. Install the current signed iPhone app with its iCloud entitlement."
    }

    func requireIdleSendForConnectionRepair() throws {
        guard activeSendCount == 0 else {
            throw SyncError.busy("A message is still sending. Wait for it to finish, then repair the connection.")
        }
    }

    func sendChatMessage(
        id: String = UUID().uuidString,
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [MultimodalAttachment] = [],
        preparedMessage: BridgeMessage? = nil,
        expectedPairing: String? = nil,
        onPrepared: ((BridgeMessage) async throws -> Void)? = nil
    ) async throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            id: id,
            sender: "ios",
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments
        )
        guard let secret = pairingStore?.iCloudPairingSecret else {
            throw BridgeError.missingPairingSecret
        }
        if let expectedPairing, AgentNameCache.fingerprint(secret) != expectedPairing {
            throw SyncError.sendFailed("This saved message belongs to another pairing. Submit a new message to send it here.")
        }
        guard pairingStore?.isRepairingConnection != true else {
            throw SyncError.busy("Connection repair is in progress.")
        }
        activeSendCount += 1
        defer { activeSendCount -= 1 }
        let generation = setupGeneration
        let msg = try await Task.detached(priority: .userInitiated) {
        if let preparedMessage {
            if preparedMessage.verifySignature(secret: secret) {
                return preparedMessage
            }
            throw SyncError.sendFailed("The retained message does not verify for this pairing. Submit a new message to send it here.")
        } else {
            return try unsigned.signed(with: secret)
        }
        }.value
        guard generation == setupGeneration, secret == pairingStore?.iCloudPairingSecret else {
            throw BridgeError.missingPairingSecret
        }
        try await onPrepared?(msg)
        guard generation == setupGeneration, secret == pairingStore?.iCloudPairingSecret else {
            throw BridgeError.missingPairingSecret
        }

        // Keep signed envelopes intact inline or in encrypted CKAsset when audio/size exceeds the inline budget.
        if let ck = deviceTransport {
            resumeDeliveryNudges()
            let recordName = msg.metadata?[NAChatMessageCodec.recordIDMetadataKey] ?? msg.id
            deliveryNudges[recordName] = msg.metadata?["actionId"] ?? msg.id
            persistDeliveryNudges()
            // Subscribe before dispatch because a Mac receipt can beat save completion/timeout; this observer owns no delivery state.
            var received = false
            let observer = UUID()
            deliveryReceiptObservers[observer] = (msg.metadata?["actionId"] ?? msg.id, { received = true })
            defer { deliveryReceiptObservers.removeValue(forKey: observer) }
            do {
                do { try await ck.send(msg) }
                catch is DeviceSyncSendOutcomeUnknown {
                    syncStatus = "Still sending…"
                    let confirmed = await confirmMessageDelivery(msg, until: Date().addingTimeInterval(60),
                                                                 hasMacEvidence: { received })
                    guard confirmed else {
                        syncStatus = ChatWaitStatusPresentation.deliveryUnconfirmed
                        throw DeviceSyncSendOutcomeUnknown(message: ChatWaitStatusPresentation.deliveryUnconfirmed)
                    }
                }
            } catch {
                if !(error is DeviceSyncSendOutcomeUnknown) {
                    deliveryNudges.removeValue(forKey: recordName)
                    persistDeliveryNudges()
                }
                resumeDeliveryNudges()
                if case .account(let failure) = error as? DeviceSyncError {
                    recordAccountFailure(failure)
                }
                throw error
            }
            resumeDeliveryNudges()
            lastSyncAt = Date()
            syncStatus = "Sending via CloudKit"
            onTransportSucceeded?()
            return msg
        }

        throw BridgeError.containerUnavailable
    }

    func sendActionEnvelope(_ data: Data, actionID: String) async throws {
        guard deviceTransport != nil,
              let text = String(data: data, encoding: .utf8) else {
            throw BridgeError.containerUnavailable
        }
        _ = try await sendChatMessage(
            text: text,
            metadata: [
                "kind": "icloud_action",
                "actionId": actionID,
            ]
        )
    }

    var pairingSecretForPhoneRequests: Data? { pairingStore?.iCloudPairingSecret }

    @discardableResult
    func observeIncomingMessages(onMessage: @escaping (BridgeMessage) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = onMessage
        Task {
            await dispatchLatestKVSChatProgress(key: KVSKey.chatProgressLatest)
            await dispatchLatestKVSChatProgress(key: KVSKey.chatNoticeLatest)
        }
        // Consumer registration must drain messages retained while that consumer was absent.
        if let ck = deviceTransport {
            Task { await ck.drainIncoming() }
        }
        return id
    }

    @discardableResult
    func observeRejectedMessages(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID {
        let id = UUID()
        rejectionHandlers[id] = onReject
        // Deliver retained rejections when their consumer registers.
        if let ck = deviceTransport { Task { await ck.drainIncoming() } }
        return id
    }

    func removeIncomingObserver(_ id: UUID?) {
        guard let id else { return }
        messageHandlers.removeValue(forKey: id)
    }

    func removeRejectedObserver(_ id: UUID?) {
        guard let id else { return }
        rejectionHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func observeResyncHints(onResync: @escaping (BridgeMessage) -> Void) -> UUID {
        let id = UUID()
        resyncHintHandlers[id] = onResync
        // Deliver retained resync hints when their consumer registers.
        if let ck = deviceTransport { Task { await ck.drainIncoming() } }
        return id
    }

    func removeResyncObserver(_ id: UUID?) {
        guard let id else { return }
        resyncHintHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func pollIncomingNow(recovery: DeviceSyncRecovery = .init()) async -> Bool {
        guard recovery.hasTime else { return false }
        if deviceTransport != nil {
            return await drainDeviceTransport(recovery: recovery)
        }
        syncStatus = "CloudKit unavailable. Check pairing and install the current signed iPhone app."
        return false
    }

    /// One Mac record, as the drain hands it over. A record its owner takes is handled. A record refused now pins the drain's cursor so it is
    /// read again; one that keeps being refused (`stuckAfterAttempts` times over `stuckAfter`) is held instead: the cursor moves past it,
    /// the log and Diagnostics name it with its reason, and it is tried again only at launch or when the pairing key changes.
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, archiveDriveFile: (() async -> Void)? = nil) async -> Bool {
        let generation = setupGeneration
        refusal = nil
        if await admitIncoming(msg, archiveDriveFile: archiveDriveFile) {
            if failingMacRecords.removeValue(forKey: msg.id) != nil { saveFailingMacRecords() }
            return true
        }
        guard archiveDriveFile == nil, generation == setupGeneration else { return false }
        return holdIfStuck(msg, reason: refusal ?? "this phone did not take it")
    }

    /// Keep consumption and Drive archival as separate receipts; unclaimed files must remain in the outbox.
    @MainActor
    private func admitIncoming(_ msg: BridgeMessage, archiveDriveFile: (() async -> Void)? = nil) async -> Bool {
        let generation = setupGeneration
        guard pairingStore?.isRepairingConnection != true else { return refuse("a pairing repair is in progress") }
        let mobileSourceKey: String
        do { mobileSourceKey = try NativeAgentICloudBridgeConstants.mobileSourceKey }
        catch { syncStatus = error.localizedDescription; return refuse("this phone's source key is unavailable") }
        let kind = msg.metadata?["kind"]
        if seenMacRecords[msg.id] != nil { return true }
        // Live is now: streamed words are cumulative, so an old piece of a reply is history the transcript already holds. Handling it
        // would only cost the work and the redraws of a reply that has ended; its ending still passes, for the send it answered.
        if msg.metadata?["live"] == "true", kind == "text_delta",
           Date().timeIntervalSince(msg.timestamp) > ChatStore.liveIsNow {
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            return true
        }
        if let secret = pairingStore?.iCloudPairingSecret,
           isVerificationDeferred(msg.id, secret: secret, version: pairingStore?.knownSecretVersion ?? 0),
           abs(Date().timeIntervalSince(msg.timestamp)) <= 24 * 60 * 60 {
            return refuse("its signature waits for the current pairing key")
        }

        // Foreign records cannot stall CloudKit cursors; shared Drive files remain for their intended recipient.
        if let tsk = msg.metadata?["targetSourceKey"], !tsk.isEmpty,
           tsk != ChatRuntimeControls.deviceSourceKey,
           tsk.trimmingCharacters(in: .whitespacesAndNewlines) != mobileSourceKey {
            guard archiveDriveFile == nil else { return false }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            return true
        }

        // Accept only the exact bounded unsigned resync shape; action/session/attachment lookalikes must never dispatch or mutate state.
        if msg.metadata?["kind"] == "signature_invalid_resync" {
            if let field = msg.unsignedResyncHintFailure {
                // Consume resync lookalikes without deferral/banner because they are not replies and must not hold the cursor.
                NSLog("[iCloudBridge] malformed resync hint consumed id=%@ field=%@", msg.id, field)
                syncStatus = "Ignored a malformed iCloud pairing refresh hint"
                recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
                await archiveDriveFile?()
                guard generation == setupGeneration else { return false }
                return true
            }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            await archiveDriveFile?()
            guard generation == setupGeneration else { return false }
            syncStatus = "iCloud pairing refresh from Mac"
            if await pairingStore?.refreshFromCloudKit() == true {
                NSLog("[iCloudBridge] signature_invalid_resync applied — new HMAC installed")
                if archiveDriveFile != nil { macOutboxScanQueued = true }
                for handler in resyncHintHandlers.values { handler(msg) }
            }
            return true
        }

        // Handle foreign targets/resync before waiting for signed consumers so nonlocal records cannot wedge delivery.
        guard kind == "notification" || kind == "icloud_action_response" || kind == PhoneRequest.messageKind
                || !messageHandlers.isEmpty
                || !rejectionHandlers.isEmpty else { return refuse("nothing on this phone is listening for it yet") }
        guard let secret = pairingStore?.iCloudPairingSecret else { return refuse("this phone has no pairing key") }

        // A new key may verify the same reply; failure is not request rejection and cannot acknowledge the record away.
        let verified = await Self.verifyReply(msg, secret: secret)
        guard generation == setupGeneration, pairingStore?.isRepairingConnection != true else { return false }
        if !verified {
            // Consume stale unverifiable records without dispatch/rejection so they cannot settle work or raise recurring banners after key changes.
            if abs(Date().timeIntervalSince(msg.timestamp)) > 24 * 60 * 60 {
                NSLog("[iCloudBridge] archiving >24h-old unverifiable Mac message %@ without dispatch", msg.id)
                unverifiedRecords.removeAll { $0.id == msg.id }
                persistUnverifiedRecords()
                recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
                await archiveDriveFile?()
                guard generation == setupGeneration else { return false }
                return true
            }
            // Defer only after notifying a rejection consumer; without one, retain eligibility for the next drain.
            if !rejectionHandlers.isEmpty {
                retainUnverified(msg, secret: pairingStore?.iCloudPairingSecret ?? secret,
                    version: pairingStore?.knownSecretVersion ?? 0,
                    reason: msg.sender != "mac" ? "sender_invalid" : msg.signature == nil ? "signature_missing" : "signature_mismatch")
            }
            NSLog("[iCloudBridge] signature_invalid id=%@ kind=%@ sender=%@ signed=%d session=%@",
                  msg.id, msg.metadata?["kind"] ?? "-", msg.sender, msg.signature == nil ? 0 : 1, msg.sessionID ?? "-")
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id, correlationID: nil, reason: "signature_invalid")
            syncStatus = rejection.userMessage
            for handler in rejectionHandlers.values { handler(rejection) }
            return refuse("its signature does not match this phone's pairing")
        }
        if unverifiedRecords.contains(where: { $0.id == msg.id }) {
            unverifiedRecords.removeAll { $0.id == msg.id }
            persistUnverifiedRecords()
        }

        // A signed acknowledgement settles what this phone still owes, however late it lands.
        guard await acceptDelivery(msg) else { return refuse("its delivery receipt was not accepted") }
        guard generation == setupGeneration else { return false }

        recordMacConfirmation(at: msg.timestamp)
        let status: String?
        if kind == PhoneRequest.messageKind {
            // Verification may refresh pairing while suspended; bind durable acceptance to the key that now authenticates this message.
            guard let requestSecret = pairingStore?.iCloudPairingSecret,
                  msg.verifySignature(secret: requestSecret),
                  await PhoneRequests.shared.accept(msg, secret: requestSecret) else { return refuse("the phone request was not accepted") }
            status = nil
        } else if kind == "icloud_action_response" {
            guard let actionID = msg.correlationID,
                  await iCloudSyncEngine.shared.persistCloudKitActionResponse(
                    msg.text,
                    actionID: actionID
                  ) else {
                return refuse("its action response could not be saved")
            }
            status = "Received action response from Mac"
        } else if kind == "notification" {
            guard await NativeAgentBridgeNotificationScheduler.schedule(msg) else { return refuse("its notification could not be scheduled") }
            status = "Received notification from Mac"
        } else {
            guard !messageHandlers.isEmpty else { return refuse("the chat is not listening yet") }
            status = "Received from Mac"
        }
        guard generation == setupGeneration else { return false }
        recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
        await archiveDriveFile?()
        guard generation == setupGeneration else { return false }
        if let status { lastSyncAt = Date(); syncStatus = status }
        if kind != PhoneRequest.messageKind, kind != "icloud_action_response", kind != "notification" {
            if kind == "text_delta" || [nil, "reply", "final", "error", "cancelled"].contains(kind) {
                NSLog("[phone-pipe] received kind=%@ correlation=%@ seq=%@ writtenAt=%@ receivedAt=%@",
                    kind ?? "reply", msg.correlationID ?? "-", msg.metadata?["seq"] ?? "-",
                    NativeTimestampFormat.fractionalZulu(msg.timestamp), NativeTimestampFormat.fractionalZulu(Date()))
            }
            for handler in messageHandlers.values { handler(msg) }
        }
        return true
    }

    static func verifyReply(
        _ message: BridgeMessage,
        secret: Data
    ) async -> Bool {
        guard message.sender == "mac" else { return false }
        return await Task.detached(priority: .userInitiated, operation: { message.verifySignature(secret: secret) }).value
    }

    @objc nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            let progressChanged = changedKeys == nil || changedKeys?.contains(KVSKey.chatProgressLatest) == true
            // Notices have a separate latest-value key so progress cannot overwrite them.
            let noticeChanged = changedKeys == nil || changedKeys?.contains(KVSKey.chatNoticeLatest) == true
            let driveChanged = changedKeys == nil || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if progressChanged {
                await self.dispatchLatestKVSChatProgress(key: KVSKey.chatProgressLatest)
            }
            if noticeChanged {
                await self.dispatchLatestKVSChatProgress(key: KVSKey.chatNoticeLatest)
            }
            // Drain only on the once-per-message durable-send nudge, never on token progress.
            if driveChanged { await self.drainDeviceTransport() }
        }
    }

    private func dispatchLatestKVSChatProgress(key: String) async {
        guard let secret = pairingStore?.iCloudPairingSecret else { return }
        let generation = setupGeneration
        guard let data = kvs.data(forKey: key) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let msg: BridgeMessage
        do { msg = try decoder.decode(BridgeMessage.self, from: data) }
        catch {
            syncStatus = "Mac progress could not be read (\(key)): \(error.localizedDescription). Check Connection in Settings."
            return
        }
        guard msg.sender == "mac" else { return }
        guard msg.verifySignature(secret: secret) else {
            syncStatus = "Mac progress rejected — pairing out of sync"
            return
        }
        guard abs(Date().timeIntervalSince(msg.timestamp)) <= 24 * 60 * 60 else { return }
        guard let kind = msg.metadata?["kind"],
              kind == "progress" || kind == "tool_use" || kind == "tool_result"
                || kind == "notice" else {
            return
        }
        let mobileSourceKey: String
        do { mobileSourceKey = try NativeAgentICloudBridgeConstants.mobileSourceKey }
        catch { syncStatus = error.localizedDescription; return }
        if let targetSourceKey = msg.metadata?["targetSourceKey"],
           !targetSourceKey.isEmpty,
           targetSourceKey != ChatRuntimeControls.deviceSourceKey,
           targetSourceKey.trimmingCharacters(in: .whitespacesAndNewlines) != mobileSourceKey {
            return
        }

        guard await acceptDelivery(msg), generation == setupGeneration,
              pairingStore?.iCloudPairingSecret == secret else { return }
        guard !seenKVSProgressMessageIDs.contains(msg.id) else { return }
        guard !messageHandlers.isEmpty else { return }
        recordSeenKVSProgressMessageID(msg.id)
        lastSyncAt = Date()
        syncStatus = "Received Mac progress"
        for handler in messageHandlers.values {
            handler(msg)
        }
    }

    private func recordSeenKVSProgressMessageID(_ id: String) {
        guard !seenKVSProgressMessageIDs.contains(id) else { return }
        seenKVSProgressMessageIDs.insert(id)
        seenKVSProgressMessageIDsOrdered.append(id)
        while seenKVSProgressMessageIDsOrdered.count > maxSeenKVSProgressMessageIDs {
            let oldest = seenKVSProgressMessageIDsOrdered.removeFirst()
            seenKVSProgressMessageIDs.remove(oldest)
        }
    }

    func tearDown(preservingConsumers: Bool = false) {
        setupGeneration += 1
        stopForegroundReceiving()
        setupTask?.cancel()
        setupTask = nil
        deviceIncomingSetupTask?.cancel()
        deviceIncomingSetupTask = nil
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        if !preservingConsumers {
            messageHandlers = [:]
            rejectionHandlers = [:]
            resyncHintHandlers = [:]
        }
        deferredThisRun = [:]
        deviceTransport = nil
        deliveryNudgeTask?.cancel()
        deliveryNudgeTask = nil
        deliveryNudgeKey = nil
        deliveryNudges = [:]
        deviceDrainInFlight = false
        deviceDrainQueued = false
        saveSeenMacRecords()
        driveURL = nil
        available = false
        lastSyncAt = nil
        accountFailureGeneration &+= 1
        accountFailure = nil
        syncStatus = "iCloud disconnected"
        isCheckingMacOutbox = false
        macOutboxScanQueued = false
        isSetUp = false
        iCloudSyncEngine.shared.tearDown()
    }

    private func refuse(_ reason: String) -> Bool {
        refusal = reason
        return false
    }

    /// A refused record pins the cursor while its refusal may pass; once it has kept being refused it is held and the cursor moves on.
    private func holdIfStuck(_ msg: BridgeMessage, reason: String) -> Bool {
        let now = Date()
        var entry = failingMacRecords[msg.id] ?? FailingMacRecord(message: msg, reason: reason, firstRefusedAt: now, attempts: 0, held: false)
        entry.reason = reason
        entry.attempts += 1
        if !entry.held, entry.attempts >= Self.stuckAfterAttempts, now.timeIntervalSince(entry.firstRefusedAt) >= Self.stuckAfter {
            entry.held = true
            Self.deliveryLog.notice("""
                held Mac record \(msg.id, privacy: .public) kind \(msg.metadata?["kind"] ?? "chat", privacy: .public) from \(msg.timestamp, privacy: .public) \
                after \(entry.attempts, privacy: .public) refusals: \(reason, privacy: .public)
                """)
        }
        failingMacRecords[msg.id] = entry
        saveFailingMacRecords()
        return entry.held
    }

    /// Held records are tried once per launch and when the pairing key changes; one still refused a day after its first refusal is let go.
    func retryHeldMacRecords(force: Bool = false) async {
        guard force || !retriedHeldThisLaunch else { return }
        retriedHeldThisLaunch = true
        let generation = setupGeneration
        for (id, entry) in failingMacRecords where entry.held {
            guard generation == setupGeneration else { return }
            refusal = nil
            if await admitIncoming(entry.message) {
                failingMacRecords[id] = nil
            } else if Date().timeIntervalSince(entry.firstRefusedAt) > 24 * 60 * 60 {
                Self.deliveryLog.notice("let go of Mac record \(id, privacy: .public): \(entry.reason, privacy: .public)")
                recordSeenMacReplyID(id); persistSeenMacReplyIDs()
                failingMacRecords[id] = nil
            } else if let refusal {
                failingMacRecords[id]?.reason = refusal
            }
        }
        saveFailingMacRecords()
    }

    private func saveFailingMacRecords() {
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(failingMacRecords).write(to: Self.failingMacRecordsURL, options: .atomic)
        } catch {
            NSLog("[iCloudBridge] refused-record ledger could not be saved: %@", error.localizedDescription)
        }
    }

    /// During a drain this only marks the memory changed; the drain saves it once when it ends.
    private func persistSeenMacReplyIDs() {
        seenMacRecordsDirty = true
        if !deviceDrainInFlight { saveSeenMacRecords() }
    }

    /// Writes the memory, forgetting records CloudKit no longer keeps.
    func saveSeenMacRecords() {
        guard seenMacRecordsDirty else { return }
        seenMacRecordsDirty = false
        let cutoff = Date().addingTimeInterval(-CloudKitDeviceTransport.retentionWindow)
        seenMacRecords = seenMacRecords.filter { $0.value > cutoff }
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(seenMacRecords).write(to: Self.seenMacRecordsURL, options: .atomic)
        } catch {
            seenMacRecordsDirty = true
            NSLog("[iCloudBridge] handled-record memory could not be saved: %@", error.localizedDescription)
        }
    }

}

/// A Mac record this phone refused: the record itself, why, since when and how often, and whether it is held past the drain's cursor.
struct FailingMacRecord: Codable {
    var message: BridgeMessage
    var reason: String
    var firstRefusedAt: Date
    var attempts: Int
    var held: Bool
}
