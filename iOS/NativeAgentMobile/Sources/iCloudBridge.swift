
import Foundation
import OSLog
import CryptoKit
import SwiftUI
import NativeAgentShared
import UIKit
import CloudKit
// Blueprint: | `iCloudBridge.swift` | Authenticated admission, consumer dispatch and durable receive settlement; unresolved delivery stays open |

typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey

struct ICloudUnverifiedRecord: Codable, Identifiable, Equatable, Sendable {
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
        let recordKey: Data?
        let phoneKey: Data
        let failure: String?
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
    @Published var syncStatus: String = "iCloud not checked"
    @Published var accountFailure: DeviceSyncAccountFailure?
    private(set) var accountFailureGeneration: UInt64 = 0

    func recordAccountFailure(_ failure: DeviceSyncAccountFailure) {
        accountFailureGeneration &+= 1
        accountFailure = failure
        syncStatus = DeviceSyncAccountFailure.phoneMessage
    }

    let kvs = NSUbiquitousKeyValueStore.default
    private var activeSendCount = 0
    // CloudKit requires checked selection and entitlement; nil means unavailable.
    var deviceTransport: CloudKitDeviceTransport?
    var usesCloudKitDeviceTransport: Bool { deviceTransport != nil }
    var onTransportSucceeded: (() -> Void)?
    var deviceDrainInFlight = false
    var deviceDrainQueued = false
    var foregroundReceiveTask: Task<Void, Never>?
    var foregroundPresenceTask: Task<Void, Never>?
    var foregroundCatchUpTask: Task<Void, Never>?
    private var unacceptedDeliveries: [String: String] = [:]
    private var deliveryPairingKey: String?
    private static let missingPairingRefusal = "this phone has no pairing key"
    private static let signatureRefusal = "its signature does not match this phone's pairing"
    private static let consumerRefusal = "nothing on this phone is listening for it yet"
    private static let chatConsumerRefusal = "the chat is not listening yet"

    func deliveryPairingMatches(_ secret: Data) -> Bool {
        deliveryPairingKey == "mobile.icloud.unaccepted.\(keyDigest(secret))"
    }

    func deliveryPairingDidChange() {
        guard let material = pairingStore?.material, material != .unavailable else { return }
        let key = material.secret.map { "mobile.icloud.unaccepted.\(keyDigest($0))" }
        guard deliveryPairingKey != key else { return }
        let stored: [String: String]
        if let key, let raw = userDefaults.object(forKey: key) {
            guard let records = raw as? [String: String] else {
                syncStatus = "Pending Mac deliveries could not be read. Repair this iPhone's saved connection state before sending again."
                return
            }
            stored = records
        } else { stored = [:] }
        deliveryPairingKey = key
        unacceptedDeliveries = stored
        if key != nil {
            Task { await self.reconsiderRefusedMacRecords(repairedReasons: [Self.missingPairingRefusal, Self.signatureRefusal]) }
        }
    }

    private func persistUnacceptedDeliveries() {
        guard let deliveryPairingKey else { return }
        if userDefaults.dictionary(forKey: deliveryPairingKey) as? [String: String] != unacceptedDeliveries {
            userDefaults.set(unacceptedDeliveries, forKey: deliveryPairingKey)
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
        retireDelivery(for: correlation)
        return true
    }

    func retireDelivery(for correlation: String) {
        guard unacceptedDeliveries.values.contains(correlation) else { return }
        unacceptedDeliveries = unacceptedDeliveries.filter { $0.value != correlation }
        persistUnacceptedDeliveries()
    }

    func isAwaitingMacAcceptance(_ correlation: String) -> Bool {
        unacceptedDeliveries.values.contains(correlation)
    }
    private let userDefaults: UserDefaults
    private let unverifiedStorage: MobileLocalStorage
    @Published private(set) var unverifiedRecords: [ICloudUnverifiedRecord] = []
    @Published private(set) var unverifiedRecordsError: String?
    private let unverifiedRecordsKey = "mobile.icloud.unverifiedRecords.v1"

    private func keyDigest(_ secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    func retainUnverified(_ msg: BridgeMessage, secret: Data, version: Int64, reason: String) async {
        let prior = unverifiedRecords
        unverifiedRecords.removeAll { $0.id == msg.id }
        unverifiedRecords.append(.init(id: msg.id, kind: msg.metadata?["kind"] ?? "chat",
            sender: msg.sender, timestamp: msg.timestamp, reason: reason,
            pairingVersion: version, keyDigest: keyDigest(secret)))
        if unverifiedRecords != prior { await persistUnverifiedRecords() }
        NSLog("[iCloudBridge] verification_deferred id=%@ kind=%@ sender=%@ timestamp=%@ pairing_version=%lld reason=%@",
              msg.id, msg.metadata?["kind"] ?? "chat", msg.sender,
              ISO8601DateFormatter().string(from: msg.timestamp), version, reason)
    }

    private func persistUnverifiedRecords() async {
        guard unverifiedRecordsError == nil else { return }
        let records = unverifiedRecords
        do {
            unverifiedStorage.save(key: unverifiedRecordsKey, value: { records }, onError: { _ in /* flush reports the completed outcome below. */ })
            try await unverifiedStorage.flush()
        } catch {
            unverifiedRecordsError = """
                Verification history could not be saved: \(error.localizedDescription). Repair iPhone local storage; existing saved \
                bytes are retained.
                """
        }
    }
    private var messageHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    private var rejectionHandlers: [UUID: (ICloudBridgeRejectedMessage) -> Void] = [:]
    // Unsigned signature_invalid_resync hints authorize pairing refresh only.
    private var resyncHintHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    /// Durable handled records are retained for the transport's retention window.
    private var seenMacRecords: [String: Date] = [:]
    /// A drain saves what it handled once, when it ends; nothing is written per record.
    private var seenMacRecordsDirty = false
    /// Unresolved admission failures retain their exact message and cause.
    private(set) var failingMacRecords: [String: FailingMacRecord] = [:]
    /// Why the record being admitted was refused this time.
    private var refusal: String?
    private nonisolated static let failingMacRecordsURL = URL.applicationSupportDirectory.appending(path: "failing-mac-records.json")
    private var receiveLedgersLoaded = false
    private var receiveLedgerRestoration: Task<Bool, Never>?
    private let receiveLedgerRead = LatestRead()
    private var seenKVSProgressMessageIDs: Set<String> = []
    private var seenKVSProgressMessageIDsOrdered: [String] = []
    /// Drains wait for incoming registration before reading the inbox.
    var deviceIncomingSetupTask: Task<Void, Never>?
    private(set) var setupGeneration = 0
    private nonisolated static let seenMacRecordsURL = URL.applicationSupportDirectory.appending(path: "seen-mac-records.json")
    private let maxSeenKVSProgressMessageIDs = 200

    weak var pairingStore: PairingStore?

    init(
        deviceTransport: CloudKitDeviceTransport? = nil,
        pairingStore: PairingStore? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.deviceTransport = deviceTransport
        self.pairingStore = pairingStore
        self.userDefaults = userDefaults
        self.unverifiedStorage = MobileLocalStorage(defaults: userDefaults)
        Task { await restoreReceiveLedgers() }
    }

    /// No record can be admitted until both replay memories have been read. Only a missing file is first use.
    func restoreReceiveLedgers() async -> Bool {
        if receiveLedgersLoaded { return true }
        if let receiveLedgerRestoration { return await receiveLedgerRestoration.value }
        let task = Task {
            do {
                unverifiedRecords = try await unverifiedStorage.read([ICloudUnverifiedRecord].self, key: unverifiedRecordsKey) ?? []
            } catch { unverifiedRecordsError = "Verification history could not be read: \(error.localizedDescription). Its saved bytes will not be replaced." }
            let result = await receiveLedgerRead.read({
                await VolumeIO.result {
                    (try Self.readReceiveLedger([String: Date].self, at: Self.seenMacRecordsURL),
                     try Self.readReceiveLedger([String: FailingMacRecord].self, at: Self.failingMacRecordsURL))
                }
            }, publish: { result in
                switch result {
                case .success(let (seen, failing)):
                    seenMacRecords = seen
                    failingMacRecords = failing
                    receiveLedgersLoaded = true
                case .failure(let error):
                    syncStatus = "Mac receive history could not be read: \(error.localizedDescription). "
                        + "Repair iPhone local storage; saved records remain untouched."
                }
            })
            if case .success = result { return true }
            return false
        }
        receiveLedgerRestoration = task
        let restored = await task.value
        receiveLedgerRestoration = nil
        return restored
    }

    private nonisolated static func readReceiveLedger<Value: Decodable & Sendable>(_ type: [String: Value].Type, at url: URL) throws -> [String: Value] {
        let data: Data
        do { data = try VolumeIO.contents(of: url) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
        return try JSONDecoder().decode(type, from: data)
    }

    private func recordSeenMacRecord(_ id: String) async -> Bool {
        guard seenMacRecords[id] == nil else { return await persistSeenMacRecords() }
        let receivedAt = Date()
        seenMacRecords[id] = receivedAt
        guard await persistSeenMacRecords() else {
            // A failed receipt must not suppress the next delivery of this record.
            if seenMacRecords[id] == receivedAt {
                seenMacRecords.removeValue(forKey: id)
                seenMacRecordsDirty = true
            }
            return false
        }
        return true
    }

    var isSetUp = false

    func setup() {
        guard !isSetUp else { return }
        isSetUp = true
        setupGeneration += 1
        syncStatus = "iCloud connecting…"
        NotificationCenter.default.removeObserver(self, name: .CKAccountChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cloudKitAccountDidChange(_:)), name: .CKAccountChanged, object: nil)

        do { try configureDeviceTransportIfAvailable() }
        catch {
            isSetUp = false
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
            Task {
                do { try await PairingStore.synchronizeKVS() }
                catch { syncStatus = error.localizedDescription }
            }
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
            deliveryPairingDidChange()
            guard deliveryPairingMatches(secret) else {
                throw SyncError.persistence("Pending Mac deliveries could not be restored for this pairing.")
            }
            let recordName = msg.metadata?[NAChatMessageCodec.recordIDMetadataKey] ?? msg.id
            unacceptedDeliveries[recordName] = msg.metadata?["actionId"] ?? msg.id
            persistUnacceptedDeliveries()
            do {
                try await ck.send(msg)
            } catch {
                if !(error is DeviceSyncSendOutcomeUnknown) {
                    unacceptedDeliveries.removeValue(forKey: recordName)
                    persistUnacceptedDeliveries()
                }
                if case .account(let failure) = error as? DeviceSyncError { recordAccountFailure(failure) }
                throw error
            }
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
            Task {
                await reconsiderRefusedMacRecords(repairedReasons: [Self.consumerRefusal, Self.chatConsumerRefusal])
                await ck.drainIncoming()
            }
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
        guard recovery.isActive else { return false }
        if deviceTransport != nil {
            return await drainDeviceTransport(recovery: recovery)
        }
        syncStatus = "CloudKit unavailable. Check pairing and install the current signed iPhone app."
        return false
    }

    /// Only verified consumer acceptance and its durable receipt advance the transport cursor.
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage) async -> Bool {
        let generation = setupGeneration
        guard await restoreReceiveLedgers(), generation == setupGeneration else { return false }
        refusal = nil
        if await admitIncoming(msg) {
            if failingMacRecords.removeValue(forKey: msg.id) != nil { return await saveReceiveLedgers() }
            return true
        }
        guard generation == setupGeneration else { return false }
        await retainRefusedMacRecord(msg, reason: refusal ?? "this phone did not take it")
        return false
    }

    /// Verification and consumer acceptance precede the durable handled-record receipt.
    @MainActor
    private func admitIncoming(_ msg: BridgeMessage) async -> Bool {
        let generation = setupGeneration
        guard pairingStore?.isRepairingConnection != true else { return refuse("a pairing repair is in progress") }
        let mobileSourceKey: String
        do { mobileSourceKey = try NativeAgentICloudBridgeConstants.mobileSourceKey }
        catch { syncStatus = error.localizedDescription; return refuse("this phone's source key is unavailable") }
        let kind = msg.metadata?["kind"]
        if seenMacRecords[msg.id] != nil { return await persistSeenMacRecords() }
        // Foreign records cannot stall CloudKit cursors.
        if let tsk = msg.metadata?["targetSourceKey"], !tsk.isEmpty,
           tsk != ChatRuntimeControls.deviceSourceKey,
           tsk.trimmingCharacters(in: .whitespacesAndNewlines) != mobileSourceKey {
            guard await recordSeenMacRecord(msg.id) else { return refuse("its handled-record memory could not be saved") }
            return true
        }

        // Accept only the exact bounded unsigned resync shape; action/session/attachment lookalikes must never dispatch or mutate state.
        if msg.metadata?["kind"] == "signature_invalid_resync" {
            if let field = msg.unsignedResyncHintFailure {
                // Consume resync lookalikes without deferral/banner because they are not replies and must not hold the cursor.
                NSLog("[iCloudBridge] malformed resync hint consumed id=%@ field=%@", msg.id, field)
                syncStatus = "Ignored a malformed iCloud pairing refresh hint"
                guard await recordSeenMacRecord(msg.id) else { return refuse("its handled-record memory could not be saved") }
                guard generation == setupGeneration else { return false }
                return true
            }
            guard await recordSeenMacRecord(msg.id) else { return refuse("its handled-record memory could not be saved") }
            guard generation == setupGeneration else { return false }
            syncStatus = "iCloud pairing refresh from Mac"
            if await pairingStore?.refreshFromCloudKit() == true {
                NSLog("[iCloudBridge] signature_invalid_resync applied — new HMAC installed")
                for handler in resyncHintHandlers.values { handler(msg) }
            }
            return true
        }

        // Handle foreign targets/resync before waiting for signed consumers so nonlocal records cannot wedge delivery.
        guard kind == "notification" || kind == "icloud_action_response" || kind == PhoneRequest.messageKind
                || !messageHandlers.isEmpty
                || !rejectionHandlers.isEmpty else { return refuse(Self.consumerRefusal) }
        guard let secret = pairingStore?.iCloudPairingSecret else { return refuse(Self.missingPairingRefusal) }

        // A new key may verify the same reply; failure is not request rejection and cannot acknowledge the record away.
        let verified = await Self.verifyReply(msg, secret: secret)
        guard generation == setupGeneration, pairingStore?.iCloudPairingSecret == secret,
              pairingStore?.isRepairingConnection != true else { return false }
        if !verified {
            // Defer only after notifying a rejection consumer; without one, retain eligibility for the next drain.
            if !rejectionHandlers.isEmpty {
                await retainUnverified(msg, secret: secret,
                    version: pairingStore?.knownSecretVersion ?? 0,
                    reason: msg.sender != "mac" ? "sender_invalid" : msg.signature == nil ? "signature_missing" : "signature_mismatch")
            }
            NSLog("[iCloudBridge] signature_invalid id=%@ kind=%@ sender=%@ signed=%d session=%@",
                  msg.id, msg.metadata?["kind"] ?? "-", msg.sender, msg.signature == nil ? 0 : 1, msg.sessionID ?? "-")
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id, correlationID: nil, reason: "signature_invalid")
            syncStatus = rejection.userMessage
            for handler in rejectionHandlers.values { handler(rejection) }
            return refuse(Self.signatureRefusal)
        }
        if unverifiedRecords.contains(where: { $0.id == msg.id }) {
            unverifiedRecords.removeAll { $0.id == msg.id }
            await persistUnverifiedRecords()
        }
        guard generation == setupGeneration, pairingStore?.isRepairingConnection != true else { return false }

        // A signed acknowledgement settles what this phone still owes, however late it lands.
        guard await acceptDelivery(msg) else { return refuse("its delivery receipt was not accepted") }
        guard generation == setupGeneration else { return false }

        recordMacConfirmation(at: msg.timestamp)
        guard await dispatchIncoming(msg, generation: generation) else { return false }
        guard await recordSeenMacRecord(msg.id) else { return refuse("its handled-record memory could not be saved") }
        return generation == setupGeneration
    }

    private func dispatchIncoming(_ msg: BridgeMessage, generation: Int) async -> Bool {
        let kind = msg.metadata?["kind"]
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
            guard !messageHandlers.isEmpty else { return refuse(Self.chatConsumerRefusal) }
            status = "Received from Mac"
        }
        guard generation == setupGeneration else { return false }
        if kind != PhoneRequest.messageKind, kind != "icloud_action_response", kind != "notification" {
            if kind == "text_delta" || [nil, "reply", "final", "error", "cancelled"].contains(kind) {
                NSLog("[phone-pipe] received kind=%@ correlation=%@ seq=%@ writtenAt=%@ receivedAt=%@",
                    kind ?? "reply", msg.correlationID ?? "-", msg.metadata?["seq"] ?? "-",
                    NativeTimestampFormat.fractionalZulu(msg.timestamp), NativeTimestampFormat.fractionalZulu(Date()))
            }
            for handler in Array(messageHandlers.values) { handler(msg) }
        }
        if let status { lastSyncAt = Date(); syncStatus = status }
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
            let deliveryChanged = changedKeys == nil || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if progressChanged {
                await self.dispatchLatestKVSChatProgress(key: KVSKey.chatProgressLatest)
            }
            if noticeChanged {
                await self.dispatchLatestKVSChatProgress(key: KVSKey.chatNoticeLatest)
            }
            // CloudKit durable-send nudge.
            if deliveryChanged { await self.drainDeviceTransport() }
        }
    }

    private func dispatchLatestKVSChatProgress(key: String) async {
        guard let secret = pairingStore?.iCloudPairingSecret else { return }
        let generation = setupGeneration
        guard let data = kvs.data(forKey: key) else { return }

        let msg: BridgeMessage
        do {
            msg = try await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(BridgeMessage.self, from: data)
            }.value
        }
        catch {
            syncStatus = "Mac progress could not be read (\(key)): \(error.localizedDescription). Check Connection in Settings."
            return
        }
        guard msg.sender == "mac" else { return }
        guard msg.verifySignature(secret: secret) else {
            syncStatus = "Mac progress rejected — pairing out of sync"
            return
        }
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
        deviceIncomingSetupTask?.cancel()
        deviceIncomingSetupTask = nil
        NotificationCenter.default.removeObserver(self)
        if !preservingConsumers {
            messageHandlers = [:]
            rejectionHandlers = [:]
            resyncHintHandlers = [:]
        }
        deviceTransport = nil
        deliveryPairingKey = nil
        unacceptedDeliveries = [:]
        deviceDrainInFlight = false
        deviceDrainQueued = false
        Task { _ = await saveSeenMacRecords() }
        available = false
        lastSyncAt = nil
        accountFailureGeneration &+= 1
        accountFailure = nil
        syncStatus = "iCloud disconnected"
        isSetUp = false
        iCloudSyncEngine.shared.tearDown()
    }

    private func refuse(_ reason: String) -> Bool {
        refusal = reason
        return false
    }

    private func retainRefusedMacRecord(_ message: BridgeMessage, reason: String) async {
        let firstRefusedAt = failingMacRecords[message.id]?.firstRefusedAt ?? Date()
        failingMacRecords[message.id] = FailingMacRecord(message: message, reason: reason, firstRefusedAt: firstRefusedAt)
        _ = await saveReceiveLedgers()
    }

    /// A repaired owner re-evaluates only the records that waited for it.
    private func reconsiderRefusedMacRecords(repairedReasons: Set<String>) async {
        guard await restoreReceiveLedgers() else { return }
        let generation = setupGeneration
        let repaired = failingMacRecords.filter { repairedReasons.contains($0.value.reason) }.map(\.key)
        for id in repaired {
            guard generation == setupGeneration else { return }
            await reconsiderRefusedMacRecord(id)
        }
    }

    func reconsiderRefusedMacRecord(_ id: String) async {
        guard await restoreReceiveLedgers(), let entry = failingMacRecords[id] else { return }
        let generation = setupGeneration
        refusal = nil
        let admitted = await admitIncoming(entry.message)
        guard generation == setupGeneration else { return }
        if admitted { failingMacRecords.removeValue(forKey: id) }
        else if let refusal { failingMacRecords[id]?.reason = refusal }
        _ = await saveReceiveLedgers()
    }

    /// Transport acceptance waits for the durable receipt, including during a drain. Failure leaves its claim and cursor retryable.
    private func persistSeenMacRecords() async -> Bool {
        seenMacRecordsDirty = true
        return await saveSeenMacRecords()
    }

    /// Writes the memory, forgetting records CloudKit no longer keeps.
    func saveSeenMacRecords() async -> Bool {
        guard seenMacRecordsDirty else { return true }
        return await saveReceiveLedgers()
    }

    private func saveReceiveLedgers() async -> Bool {
        guard receiveLedgersLoaded else { return false }
        let cutoff = Date().addingTimeInterval(-CloudKitDeviceTransport.retentionWindow)
        seenMacRecords = seenMacRecords.filter { $0.value > cutoff }
        let seen = seenMacRecords
        let failing = failingMacRecords
        do {
            try await VolumeIO.run {
                try Self.writeReceiveLedger(seen, to: Self.seenMacRecordsURL)
                try Self.writeReceiveLedger(failing, to: Self.failingMacRecordsURL)
            }
            if seenMacRecords == seen { seenMacRecordsDirty = false }
            return true
        } catch {
            seenMacRecordsDirty = true
            syncStatus = "Mac receive history could not be saved: \(error.localizedDescription). Its settlement remains owed."
            return false
        }
    }

    private nonisolated static func writeReceiveLedger<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        do { if try VolumeIO.contents(of: url) == data { return } }
        catch CocoaError.fileReadNoSuchFile { /* First committed receive history. */ }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// An unresolved Mac record and its admission failure.
struct FailingMacRecord: Codable, Sendable {
    var message: BridgeMessage
    var reason: String
    var firstRefusedAt: Date
}
