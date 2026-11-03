// Phone chat transport over checked CloudKit, configured by NativeAgentICloudBridgeConstants.

import Foundation
import CryptoKit
import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `iCloudBridge.swift` | Authenticated admission and delivery ownership; unknown sends observe exact server records and verified correlation receipts for 60 seconds before reporting unconfirmed; scoped receipt listeners precede dispatch; pairing-scoped record nudges survive unavailable authority; checkpointed place/sense acceptance |

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

    /// The Mac refused this request before the agent ever saw it, purely
    /// because it sat unread past its window. Nothing ran, so sending it again
    /// cannot duplicate anything — but only the person may do that.
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

    /// The key the account's Mac pairing record held when last read, with the
    /// phone key it was read against. A reading counts only for that phone
    /// key: whatever installs a new one (a push, KVS, a paste, a repair)
    /// voids it until the next read.
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
    // Delivery ownership contains record identities, never a second copy of
    // the request. Existing chat/action wait owners decide whether it is live.
    private var deliveryNudges: [String: String] = [:]
    private var deliveryNudgeKey: String?
    private var deliveryNudgeTask: Task<Void, Never>?
    /// Scoped subscribers to the verified receipt boundary, never inferred
    /// from disappearance of a nudge or a pending exchange.
    private var deliveryReceiptObservers: [UUID: (String, () -> Void)] = [:]

    func deliveryPairingMatches(_ secret: Data) -> Bool {
        deliveryNudgeKey == "mobile.icloud.unaccepted.\(keyDigest(secret))"
    }

    func deliveryPairingDidChange() {
        // Unknown authority cannot retire delivery work, including through
        // setup/foreground callers that did not observe the material change.
        guard let material = pairingStore?.material, material != .unavailable else { return }
        let secret = material.secret
        let key = secret.map { "mobile.icloud.unaccepted.\(keyDigest($0))" }
        if deliveryNudgeKey != key {
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
            // The handle owns the sleeping deadline, never the delivery it wakes.
            self.deliveryNudgeTask = nil
            // If authority is still unreadable, retain the nudges. A checked
            // same-key publication resumes them without a stale task handle.
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

    /// Observe only; never resubmit a write while its outcome is unknown.
    /// Read failures and empty results keep waiting until the bounded deadline.
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
        deliveryNudges = deliveryNudges.filter { $0.value != correlation }
        persistDeliveryNudges()
    }

    func isAwaitingMacAcceptance(_ correlation: String) -> Bool {
        deliveryNudges.values.contains(correlation)
    }
    /// Deduplication receipts persist in the supplied defaults store.
    private let userDefaults: UserDefaults
    @Published private(set) var unverifiedRecords: [ICloudUnverifiedRecord] = []
    @Published private(set) var unverifiedRecordsError: String?
    private let unverifiedRecordsKey = "mobile.icloud.unverifiedRecords.v1"

    private func keyDigest(_ secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Records deferred by THIS bridge instance. Kept in memory on purpose: a
    /// recreated bridge (relaunch) re-verifies every unclaimed record, and a
    /// pairing change re-verifies within a run. The persisted list below is
    /// only what Diagnostics shows.
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
            unverifiedRecordsError = "Verification history could not be saved: \(error.localizedDescription). Repair iPhone local storage; existing saved bytes are retained."
        }
    }
    /// Resolves the account's Drive mount off-main.
    private let ubiquityContainerURL: @Sendable (String?) -> URL?
    private var messageHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    private var rejectionHandlers: [UUID: (ICloudBridgeRejectedMessage) -> Void] = [:]
    // Unsigned signature_invalid_resync hints request pairing refresh.
    private var resyncHintHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    // Reply and progress deduplication evict oldest arrivals; reply IDs persist in that order.
    private(set) var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    private var seenKVSProgressMessageIDs: Set<String> = []
    private var seenKVSProgressMessageIDsOrdered: [String] = []
    var isCheckingMacOutbox = false
    var macOutboxScanQueued = false
    var setupTask: Task<Void, Never>?
    /// Drains wait for incoming registration before reading the inbox.
    var deviceIncomingSetupTask: Task<Void, Never>?
    private(set) var setupGeneration = 0
    private let processedMacReplyIDsKey = "NativeAgentMobile.iCloud.processedMacReplyIDs.v1"
    private let maxProcessedMacReplyIDs = 500
    private let maxSeenKVSProgressMessageIDs = 200

    // PairingStore supplies the secret for outgoing signatures and incoming verification.
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
        catch { unverifiedRecordsError = "Verification history could not be read: \(error.localizedDescription). Repair iPhone local storage; existing saved bytes are retained and will not be replaced." }
        if let saved = userDefaults.array(forKey: processedMacReplyIDsKey) as? [String] {
            for id in saved where seenMessageIDs.insert(id).inserted {
                seenMessageIDsOrdered.append(id)
            }
        }
    }

    private func recordSeenMacReplyID(_ id: String) {
        guard !seenMessageIDs.contains(id) else { return }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        while seenMessageIDsOrdered.count > maxProcessedMacReplyIDs {
            let oldest = seenMessageIDsOrdered.removeFirst()
            seenMessageIDs.remove(oldest)
        }
    }

    // Setup registers observers and metadata queries once per lifecycle.
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

        // CloudKit owns messages and snapshots; KVS still carries progress/resync nudges.
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

        // CloudKit preserves the signed envelope inline, or in an encrypted
        // CKAsset for audio and envelopes above the inline budget.
        if let ck = deviceTransport {
            resumeDeliveryNudges()
            let recordName = msg.metadata?[NAChatMessageCodec.recordIDMetadataKey] ?? msg.id
            deliveryNudges[recordName] = msg.metadata?["actionId"] ?? msg.id
            persistDeliveryNudges()
            // Subscribe before dispatch: a Mac receipt can beat the save's
            // return (or its timeout). This subscriber owns no delivery state.
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

    /// Carries signed InboxAction envelopes to MacSyncEngine over the chat transport.
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
        // Progress and notices arrive through KVS on either transport.
        Task {
            await dispatchLatestKVSChatProgress(key: KVSKey.chatProgressLatest)
            await dispatchLatestKVSChatProgress(key: KVSKey.chatNoticeLatest)
        }
        // Drain the active transport for messages held until this consumer registered.
        if let ck = deviceTransport {
            Task { await ck.drainIncoming() }
        }
        return id
    }

    @discardableResult
    func observeRejectedMessages(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID {
        let id = UUID()
        rejectionHandlers[id] = onReject
        // Drain rejections held until this consumer registered.
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
        // Drain resync hints held until this consumer registered.
        if let ck = deviceTransport { Task { await ck.drainIncoming() } }
        return id
    }

    func removeResyncObserver(_ id: UUID?) {
        guard let id else { return }
        resyncHintHandlers.removeValue(forKey: id)
    }

    /// Catch up through the active transport while a reply is outstanding or the user refreshes.
    @discardableResult
    func pollIncomingNow() async -> Bool {
        guard NADeviceSyncRecoveryBudget.hasTime else { return false }
        if deviceTransport != nil {
            return await drainDeviceTransport()
        }
        syncStatus = "CloudKit unavailable. Check pairing and install the current signed iPhone app."
        return false
    }

    /// Validates and routes both transports. Record consumption and Drive file
    /// archival are separate receipts; unclaimed Drive files stay in the outbox.
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, archiveDriveFile: (() async -> Void)? = nil) async -> Bool {
        let generation = setupGeneration
        guard pairingStore?.isRepairingConnection != true else { return false }
        let mobileSourceKey: String
        do { mobileSourceKey = try NativeAgentICloudBridgeConstants.mobileSourceKey }
        catch { syncStatus = error.localizedDescription; return false }
        let kind = msg.metadata?["kind"]
        if seenMessageIDs.contains(msg.id) { return true }
        if let secret = pairingStore?.iCloudPairingSecret,
           isVerificationDeferred(msg.id, secret: secret, version: pairingStore?.knownSecretVersion ?? 0),
           abs(Date().timeIntervalSince(msg.timestamp)) <= 24 * 60 * 60 {
            return false
        }

        // A foreign record cannot hold CloudKit's cursor; a shared Drive file
        // remains available to its intended recipient.
        if let tsk = msg.metadata?["targetSourceKey"], !tsk.isEmpty,
           tsk != ChatRuntimeControls.deviceSourceKey,
           tsk.trimmingCharacters(in: .whitespacesAndNewlines) != mobileSourceKey {
            guard archiveDriveFile == nil else { return false }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            return true
        }

        // Resync is the one unsigned wire exception. Its exact bounded shape
        // is checked before it may refresh pairing material; a lookalike with
        // an action/session/attachment is terminally consumed but never
        // dispatched or allowed to mutate local state.
        if msg.metadata?["kind"] == "signature_invalid_resync" {
            if let field = msg.unsignedResyncHintFailure {
                // A lookalike is dropped, not deferred: it is never a reply, so it
                // must not raise the unverified-reply banner or hold the cursor.
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

        // Signed records remain eligible until their exact consumer is ready.
        // Do this after foreign-target and resync handling: neither is a local
        // chat/notification delivery, and both must not wedge the cursor.
        guard kind == "notification" || kind == "icloud_action_response" || kind == PhoneRequest.messageKind
                || !messageHandlers.isEmpty
                || !rejectionHandlers.isEmpty else { return false }
        guard let secret = pairingStore?.iCloudPairingSecret else { return false }  // can't verify → retry

        // A changed key may authenticate this exact reply. A failed check is
        // not a request rejection and must not acknowledge the record away.
        let verified = await Self.verifyReply(msg, secret: secret)
        guard generation == setupGeneration, pairingStore?.isRepairingConnection != true else { return false }
        if !verified {
            // Archive stale unverifiable records, including action responses
            // signed before a pairing-secret change. Clear their diagnostic
            // state and consume without dispatch or rejection so they cannot
            // settle a transaction or re-raise the banner on the next launch.
            if abs(Date().timeIntervalSince(msg.timestamp)) > 24 * 60 * 60 {
                NSLog("[iCloudBridge] archiving >24h-old unverifiable Mac message %@ without dispatch", msg.id)
                unverifiedRecords.removeAll { $0.id == msg.id }
                persistUnverifiedRecords()
                recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
                await archiveDriveFile?()
                guard generation == setupGeneration else { return false }
                return true
            }
            // Defer only once a consumer has been told: an unclaimed record with no
            // rejection observer yet stays eligible so the next drain reports it.
            if !rejectionHandlers.isEmpty {
                retainUnverified(msg, secret: pairingStore?.iCloudPairingSecret ?? secret,
                    version: pairingStore?.knownSecretVersion ?? 0,
                    reason: msg.sender != "mac" ? "sender_invalid" : msg.signature == nil ? "signature_missing" : "signature_mismatch")
            }
            // Name the record so the next unverifiable reply is diagnosable from the console.
            NSLog("[iCloudBridge] signature_invalid id=%@ kind=%@ sender=%@ signed=%d session=%@",
                  msg.id, msg.metadata?["kind"] ?? "-", msg.sender, msg.signature == nil ? 0 : 1, msg.sessionID ?? "-")
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id, correlationID: nil, reason: "signature_invalid")
            syncStatus = rejection.userMessage
            for handler in rejectionHandlers.values { handler(rejection) }
            return false
        }
        if unverifiedRecords.contains(where: { $0.id == msg.id }) {
            unverifiedRecords.removeAll { $0.id == msg.id }
            persistUnverifiedRecords()
        }

        // A signed acknowledgement settles what this phone still owes, however late it lands.
        guard await acceptDelivery(msg), generation == setupGeneration else { return false }

        // Chat waits for its consumer; notifications go directly to scheduling.
        recordMacConfirmation(at: msg.timestamp)
        let status: String?
        if kind == PhoneRequest.messageKind {
            // verifyReply may have refreshed pairing while suspended. Bind
            // durable acceptance to the key that authenticates the message now.
            guard let requestSecret = pairingStore?.iCloudPairingSecret,
                  msg.verifySignature(secret: requestSecret),
                  await PhoneRequests.shared.accept(msg, secret: requestSecret) else { return false }
            status = nil
        } else if kind == "icloud_action_response" {
            guard let actionID = msg.correlationID,
                  await iCloudSyncEngine.shared.persistCloudKitActionResponse(
                    msg.text,
                    actionID: actionID
                  ) else {
                return false
            }
            status = "Received action response from Mac"
        } else if kind == "notification" {
            guard await NativeAgentBridgeNotificationScheduler.schedule(msg) else { return false }
            status = "Received notification from Mac"
        } else {
            guard !messageHandlers.isEmpty else { return false }
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

    private func persistSeenMacReplyIDs() {
        let capped = Array(seenMessageIDsOrdered.suffix(maxProcessedMacReplyIDs))
        userDefaults.set(capped, forKey: processedMacReplyIDsKey)
    }

}
