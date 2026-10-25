// PATCH-2026-05-07: icloud-bridge Mac side — iCloud KVS+Drive hybrid bridge
// Architecture: A+B hybrid
//   - iCloud KVS (NSUbiquitousKeyValueStore): short control messages, status pings, "new-message" triggers
//   - iCloud Drive (NSMetadataQuery): chat history, attachments, full message payloads
// No Apple Developer cert required. Works on free Apple ID.
// Container: configured by NativeAgentICloudBridgeConstants.
// CloudKit is the selected public transport; KVS/Drive remains an explicit
// diagnostic and compatibility fallback.

import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `iCloudBridge.swift` | Owns ChatRecord admission, reply binding, recovery, durable mutation and terminal retention interpretation for icloud/chat_transactions; rejected CloudKit envelopes have no local journal/quarantine copy. `setup`, `recordCloudKitPushEvidence` (data-root-scoped chat-subscription push proof persisted across launches; subscription failure or unannounced aged delivery revokes), `scheduleNextDeviceDrainFallback` (obligations or push unavailable/unproven; idle rests), `cloudKitActionResponseMessage` (sending and sizing), `failedReplyClaims` (startup snapshot or exact delivery event) |

// MARK: - iCloudBridge (Mac)
// BridgeMessage, BridgeError, and all HMAC helpers are now in NativeAgentShared.
private typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
private typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder

/// One serial authentication owner per bridge. No suspension inside a check;
/// cancellation checks can still run while delivery awaits a chat's reply.
private actor ICloudIncomingVerifier {
    func classify(_ message: BridgeMessage) throws -> (ICloudIncomingMessageDisposition, Data) {
        let key = try PairingSecretManager.loadOrGenerateSecret()
        return (ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()), key)
    }

    func admitsControl(_ message: BridgeMessage) -> Bool {
        guard let key = try? PairingSecretManager.loadOrGenerateSecret() else { return false }
        if message.metadata?["kind"] != "icloud_action",
           UserMessageIntentSignals.isControlHandoff(message.text),
           let session = message.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           NativeAgentChatSessionID.normalizedPathComponent(session) != nil,
           case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()) {
            return true
        }
        return iCloudBridge.isAuthenticatedControlAction(message, secret: key)
    }
}

/// A chat receipt describes the furthest boundary this Mac actually observed.
/// Neither state implies that iOS fetched, displayed, or acknowledged the
/// message; that would require a separate signed return receipt from iOS.
enum ChatDeliveryReceiptStatus: String, Sendable {
    case failedBeforeDispatch = "failed_before_dispatch"
    /// The Drive file exists locally and still depends on iCloud replication.
    case queuedForICloudSync = "queued_for_icloud_sync"
    /// CloudKit accepted the outbound record, but iOS has not acknowledged it.
    case acceptedByTransport = "accepted_by_transport"
    /// The Mac verified and delivered the inbound peer message to the runtime.
    case deliveredToMac = "delivered_to_mac"
    /// The peer later confirmed delivery of a Mac-originated notification.
    case confirmedByPeer = "confirmed_by_peer"

    var deliveryConfirmed: Bool {
        switch self {
        case .failedBeforeDispatch, .queuedForICloudSync, .acceptedByTransport:
            return false
        case .deliveredToMac, .confirmedByPeer:
            return true
        }
    }
}

@MainActor
public final class iCloudBridge: ObservableObject {
    private enum ChatAdmission: Sendable {
        case reserved(url: URL, contents: Data)
        case completed, interrupted, unreadable, collision, stale, unavailable
    }

    /// The chat ledger's one schema includes admission, reply binding and recovery.
    /// Optional admission fields are absent on Mac-originated reply obligations.
    private struct ChatRecord: Codable, Sendable {
        var id: String?
        var direction: String
        var action: String
        var state: String
        var createdAt: String?
        var updatedAt: String?
        var attempts: Int?
        var lastError: String?
        var response: [String: String]?
        var msgId: String
        var actionDigest: String?
        var assistantSessionId: String?
        var resendRunId: String?
        var resendSessionId: String?
        var targetSourceKey: String?
        var hasAdmission: Bool { id != nil && createdAt != nil && updatedAt != nil && attempts != nil }
    }

    nonisolated private static func chatURL(_ messageID: String, dataRoot: URL) -> URL {
        let id = MacSyncSnapshotIntegrity.digest(Data(messageID.utf8))
        return dataRoot.appendingPathComponent("icloud/chat_transactions/\(id).json")
    }

    nonisolated private static func readChat(_ messageID: String, dataRoot: URL) throws -> ChatRecord {
        try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: chatURL(messageID, dataRoot: dataRoot)))
    }

    @discardableResult
    nonisolated private static func writeChat(_ record: ChatRecord, to path: URL) throws -> Data {
        let data = try JSONEncoder().encode(record)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
        return data
    }

    nonisolated static func isTerminalChatTransaction(_ data: Data) -> Bool {
        guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data),
              row.direction == "mac_to_ios" || row.hasAdmission else { return false }
        return ["completed", "sent_unconfirmed", "failed_before_answer", "unknown", "failed"].contains(row.state)
    }

    /// Both transports reserve the same canonical envelope before a turn starts.
    nonisolated private static func reserveChat(_ message: BridgeMessage, dataRoot: URL, canDispatch: Bool) async -> ChatAdmission {
        do {
            let digest = MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning())
            let id = MacSyncSnapshotIntegrity.digest(Data(message.id.utf8))
            let url = Self.chatURL(message.id, dataRoot: dataRoot)
            return try await SwiftNativePersistenceCore().withFileLock(url) {
                switch MacSyncEngine.coordinatedReadOutcome(at: url) {
                case .data(let data):
                    guard let row = try? JSONDecoder().decode(ChatRecord.self, from: data), row.hasAdmission else { return .unreadable }
                    guard row.id == id, row.msgId == message.id, row.actionDigest == digest,
                          row.direction == "ios_to_mac", row.action == "chat" else { return .collision }
                    return ["completed", "sent_unconfirmed", "failed_before_answer"].contains(row.state) ? .completed : .interrupted
                case .failed:
                    return .unreadable
                case .missing:
                    break
                }
                let age = Date().timeIntervalSince(message.timestamp)
                guard age <= 24 * 60 * 60, age >= -15 * 60 else { return .stale }
                guard canDispatch else { return .unavailable }
                let now = ISO8601DateFormatter().string(from: Date())
                let row = ChatRecord(id: id, direction: "ios_to_mac", action: "chat",
                                                 state: "running", createdAt: now, updatedAt: now,
                                                 attempts: 1, msgId: message.id, actionDigest: digest)
                let data = try Self.writeChat(row, to: url)
                guard case .data(let retained) = MacSyncEngine.coordinatedReadOutcome(at: url),
                      retained == data else { return .unavailable }
                return .reserved(url: url, contents: data)
            }
        } catch {
            nativeLog("[iCloudBridge] chat reservation unavailable: %@", error.localizedDescription)
            return .unavailable
        }
    }

    /// Only the caller that has not entered a handler may release its new row.
    /// Exact bytes keep an interrupted or subsequently advanced row intact.
    nonisolated private static func releaseUndispatchedChat(_ admission: ChatAdmission) async {
        await settle {
            if case .reserved(let url, let contents) = admission {
                do {
                    try await SwiftNativePersistenceCore().withFileLock(url) {
                        if try Data(contentsOf: url) == contents { try FileManager.default.removeItem(at: url) }
                    }
                } catch {
                    nativeLog("[iCloudBridge] undispatched chat reservation could not be released: %@", error.localizedDescription)
                }
            }
        }
    }

    nonisolated private static func finishChat(_ message: BridgeMessage, dataRoot: URL, completed: Bool) async -> Bool {
        return await settle {
            do {
                let url = Self.chatURL(message.id, dataRoot: dataRoot)
                return try await SwiftNativePersistenceCore().withFileLock(url) {
                    var row = try Self.readChat(message.id, dataRoot: dataRoot)
                    guard row.hasAdmission, row.msgId == message.id,
                          row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()) else { return false }
                    row.state = completed ? "completed" : "unknown"
                    row.updatedAt = ISO8601DateFormatter().string(from: Date())
                    try Self.writeChat(row, to: url)
                    return true
                }
            } catch {
                nativeLog("[iCloudBridge] chat outcome could not be saved: %@", error.localizedDescription)
                return false
            }
        }
    }

    nonisolated static func bindReplySession(_ message: BridgeMessage, sessionID: String, dataRoot: URL,
                                            resendRunID: String? = nil, resendSessionID: String? = nil) async throws {
        let path = chatURL(message.id, dataRoot: dataRoot)
        try await SwiftNativePersistenceCore().withFileLock(path) {
            var row = try readChat(message.id, dataRoot: dataRoot)
            guard row.msgId == message.id,
                  row.actionDigest == MacSyncSnapshotIntegrity.digest(try message.canonicalBodyForSigning()),
                  row.assistantSessionId == nil || row.assistantSessionId == sessionID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            row.assistantSessionId = sessionID
            if let resendRunID { row.resendRunId = resendRunID }
            if let resendSessionID { row.resendSessionId = resendSessionID }
            try writeChat(row, to: path)
        }
    }

    nonisolated private static func replyReservation(_ correlation: String, session: String, sourceKey: String,
                                             dataRoot: URL) throws -> ChatRecord {
        let path = chatURL(correlation, dataRoot: dataRoot)
        let row = try FileManager.default.fileExists(atPath: path.path)
            ? readChat(correlation, dataRoot: dataRoot)
            : ChatRecord(direction: "mac_to_ios", action: "chat", state: "owed",
                         msgId: correlation, assistantSessionId: session, targetSourceKey: sourceKey)
        guard row.msgId == correlation, ["ios_to_mac", "mac_to_ios"].contains(row.direction),
              row.action == "chat", row.assistantSessionId == nil || row.assistantSessionId == session else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return row
    }

    nonisolated private static func settleReply(_ correlation: String, session: String, sourceKey: String,
                                       state: String, dataRoot: URL) async throws {
        let result: Result<Void, Error> = await settle {
            do {
                let path = chatURL(correlation, dataRoot: dataRoot)
                try await SwiftNativePersistenceCore().withFileLock(path) {
                    var row = try replyReservation(correlation, session: session, sourceKey: sourceKey, dataRoot: dataRoot)
                    if row.state == state { return }
                    row.state = state
                    row.updatedAt = ISO8601DateFormatter().string(from: Date())
                    try writeChat(row, to: path)
                }
                return .success(())
            } catch { return .failure(error) }
        }
        try result.get()
    }

    private static let pushLog = Logger(subsystem: "NativeAgent.DeviceSync", category: "push")

    private enum DrainTrigger: String {
        case fallbackTimer, cloudKitPush, legacyKVS, coalesced, repair, wake, network
    }

    unowned let sync: DeviceSync
    // MARK: Published state

    @Published public internal(set) var available: Bool = false
    @Published public internal(set) var lastSyncAt: Date?
    @Published public internal(set) var syncStatus: String = "iCloud not checked" {
        didSet {
            if accountFailure != nil, syncStatus != DeviceSyncAccountFailure.macMessage {
                syncStatus = DeviceSyncAccountFailure.macMessage
            } else if accountFailure == nil, phonePairedElsewhere, syncStatus != Self.pairedElsewhereStatus {
                syncStatus = Self.pairedElsewhereStatus
            }
        }
    }
    @Published public private(set) var accountFailure: DeviceSyncAccountFailure? {
        didSet { refreshPhoneConnection() }
    }
    private var accountFailureGeneration: UInt64 = 0
    /// Another Mac on this Apple Account holds the phone's pairing; this Mac
    /// stays quiet toward the phone until the person moves it here.
    @Published public private(set) var phonePairedElsewhere = false {
        didSet { refreshPhoneConnection() }
    }
    /// Whether this Mac has read its claim on the account's pairing since
    /// setup. Until it has, it writes nothing the phone reads as the Mac's.
    private var phonePairingSettled = false {
        didSet { refreshPhoneConnection() }
    }
    /// The phone's connection as this Mac knows it: pairing, transport and the
    /// last accepted exchange, each with its owner. Connectors › iPhone and
    /// Doctor say where the connection stands through this one value.
    @Published public private(set) var phoneConnection = NAPhoneConnection(
        pairing: .init(.waiting, "Checking this Mac's pairing."),
        transport: .init(.waiting, "iCloud is not checked yet."),
        exchange: .init(.waiting, "No message from your iPhone yet."))
    /// Why this build has no CloudKit transport, when it was meant to.
    private var transportRefusal: NAPhoneConnection.Fact? { didSet { refreshPhoneConnection() } }
    private var pairingKeyUnreadable = false { didSet { refreshPhoneConnection() } }
    /// When the phone was last there, from a message this Mac accepted.
    private var lastPhoneContactAt: Date? { didSet { refreshPhoneConnection() } }
    /// When this Mac last turned away a phone message signed with another key.
    private var lastPhoneRejectedAt: Date? { didSet { refreshPhoneConnection() } }
    private var pairedPhonesSubscription: AnyCancellable?
    private var phonePairingRecheckDue = false
    /// This Mac speaks to the phone: it holds the account's pairing.
    private var speaksToPhone: Bool { deviceTransport != nil && phonePairingSettled && !phonePairedElsewhere }
    nonisolated static let pairedElsewhereStatus =
        "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account. Choose Use my iPhone with this Mac to move it here."
    /// This install changed its key and the account's pairing record has not
    /// taken it yet: owed, not lost. Per data root, like the key itself.
    private var pairingPublicationOwedKey: String {
        let root = SHA256.hash(data: Data(sync.dataRoot.standardizedFileURL.path.utf8))
        return "NativeAgent.pairing.cloudKitPublicationOwed.v1." + root.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Private

    private var driveURL: URL?
    private var metadataQuery: NSMetadataQuery?
    private var messageHandlers: [(BridgeMessage) async -> Bool] = []
    // Only the entitlement-checked resolver installs this CloudKit transport.
    private var deviceTransport: DeviceSyncTransport?
    private var doctorTransportHealth: ICloudBridgeHealthSnapshot.Health = .unmeasured {
        didSet { refreshPhoneConnection() }
    }
    private var doctorSendFailures: [String: ICloudBridgeHealthSnapshot.Health] = [:] {
        didSet { refreshPhoneConnection() }
    }
    private var doctorSendMeasured = false
    var onTransportSucceeded: (() -> Void)?
    public lazy var phoneRequests = MacPhoneRequestChannel(bridge: self)
    var usesCloudKitDeviceTransport: Bool {
        isSetUp && deviceTransport != nil
    }
    public private(set) var cloudKitVisualNotificationPeerReady: Bool = false
    // Push/receive deadlines coalesce; the transport owns message deduplication.
    private var deviceDrainInFlight = false
    private var deviceDrainTask: Task<Bool, Never>?
    private var deviceDrainGeneration: Int?
    private var activeCloudKitChats = 0
    private var deviceDrainQueued = false
    private var deviceDrainTimerTask: Task<Void, Never>?
    private var cloudKitPushProofAt: Date?
    private var cloudKitPushProven: Bool { cloudKitPushProofAt != nil }
    private var deviceDrainTriggeredByPush = false
    private var cloudKitPushUnavailable = false
    private var deviceDrainCadence: TimeInterval?
    private var deviceNetworkMonitor: NWPathMonitor?
    private var deviceNetworkSatisfied: Bool?
    // 2026-09-06: the retention sweep's own single-flight slot. It runs beside
    // the drain, never inside it, so a slow or timing-out sweep cannot delay
    // message delivery; a sweep still running when the next drain finishes is
    // simply not started again.
    private var deviceRetentionSweepInFlight = false
    private var deviceRetentionSweepTask: Task<Void, Never>?
    /// Owns the receive deadline while delivery needs one.
    var drainPolicy = AdaptiveDrainPolicy()
    private var lastDeviceDrainAt = Date.distantPast
    /// Last successfully published deterministic provider projection. Repeated
    /// UI refreshes often discover identical state; skip those CloudKit writes.
    private var lastPublishedProviderCatalogStatus: String?
    // One owner spans the read and send. Callers join it and queue a fresh read,
    // including a return to the cached selection while a different send awaits.
    private var providerCatalogPublicationTask: Task<Bool, Never>?
    private var providerCatalogPublicationQueued = false
    private var lastPublishedMobileSnapshotStatus: [NAMobileSnapshotGroup: String] = [:]
    // fix-2026-06-10 sync-audit #2 (fix-R9-9 pattern from MacSyncEngine):
    // maintain insertion order alongside the set so eviction drops OLDEST ids
    // first. The previous .sorted().suffix(cap) trimmed lexicographically —
    // age-random eviction that could forget a recent id and replay its message.
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    // N-mem fix: the on-disk processed-ids file is capped at `seenMessageIDsCap`
    // via .suffix() but the in-memory Set only ever .insert()d → unbounded
    // memory growth over a long-running session. Cap memory the same way so
    // memory and disk stay consistent (both insertion-ordered, oldest evicted).
    // nonisolated: an immutable Sendable constant read by the nonisolated static
    // saveProcessedMessageIDs off-main helper; no actor isolation needed.
    nonisolated private static let seenMessageIDsCap = 2000
    private var inFlightIncomingMessageIDs: Set<String> = []
    private var inFlightReplyIDs: Set<String> = []
    private var setupTask: Task<Void, Never>?
    // Monotonic token: bumped on every setup()/tearDown() so a stale off-main
    // container resolve that completes late can't re-register observers / start
    // the query for a superseded setup (it checks generation before applying).
    private var setupGeneration: Int = 0
    /// DeviceSyncTransport currently has last-registration-wins observation but
    /// no cancellation token. Keep the callback itself lifecycle-gated so a
    /// retained transport cannot route work after this bridge has torn down.
    private var incomingObserverGeneration: UInt64 = 0
    private var incomingObserverTask: Task<Void, Never>?
    private var incomingObserverTaskID = UUID()
    private var transportSetupTask: Task<Void, Never>?
    private var transportSetupTaskID = UUID()
    private(set) var incomingObserverInstalled = false
    private var outboxScanTask: Task<Void, Never>?
    private var outboxScanInFlight = false
    private var outboxScanQueued = false
    /// Each admitted Drive backlog owns its settlement; teardown closes its
    /// next dispatch without cancelling the human turn already underway.
    private var outboxBacklogTasks: [UUID: Task<Void, Never>] = [:]
    /// Makes a cancelled/retired detached scan unable to clear or replay work
    /// belonging to a newer bridge lifecycle.
    private var outboxScanGeneration: UInt64 = 0
    // N10 fix: idempotency guard — track whether setup() has already run so
    // repeat calls don't stack additional KVS observers (each call added a
    // new addObserver which fired the handler multiple times per external change).
    private var isSetUp: Bool = false
    private let incomingVerifier = ICloudIncomingVerifier()
    private var deliveryNudgeQueue: ICloudDeliveryNudgeQueue?

    // Drive folder layout
    // <container>/Documents/outbox/mac/   — Mac writes here
    // <container>/Documents/outbox/ios/   — iOS writes here
    // <container>/Documents/processing/   — Mac claimed but has not acked yet
    // <container>/Documents/processed/    — read messages moved here (archive)

    // MARK: - Init

    init(sync: DeviceSync) {
        self.sync = sync
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        Task {
            let failure = await sync.storage.perform {
                try? JSONDecoder().decode(DeviceSyncAccountFailure.self, from: Data(contentsOf: url))
            }
            guard accountFailureGeneration == 0, let failure else { return }
            accountFailure = failure
            syncStatus = DeviceSyncAccountFailure.macMessage
        }
        ICloudBridgeHealthReader.register(dataRoot: sync.dataRoot) { [weak self] in
            self?.doctorHealthSnapshot
        }
        PhoneConnectionReader.register(dataRoot: sync.dataRoot) { [weak self] in
            self?.phoneConnection
        }
    }

    private var doctorHealthSnapshot: ICloudBridgeHealthSnapshot? {
        guard isSetUp || setupTask != nil else { return nil }
        if usesCloudKitDeviceTransport {
            let health: ICloudBridgeHealthSnapshot.Health
            if let accountFailure {
                health = .accountFailure(code: accountFailure.code, detail: accountFailure.detail)
            } else {
                health = doctorTransportHealth
            }
            return .init(transport: .cloudKit, health: health,
                         sendMeasured: doctorSendMeasured, sendFailures: doctorSendFailures)
        }
        guard deviceTransport == nil else { return nil }
        return .init(
            transport: .iCloudDrive,
            health: doctorTransportHealth,
            documentsURL: driveURL
        )
    }

    private static func transportHealth(_ error: Error) -> ICloudBridgeHealthSnapshot.Health {
        switch error as? DeviceSyncError {
        case .unauthorized: return .signedOut
        case .notConfigured: return .notEntitled
        case .quotaExceeded: return .quotaExceeded
        case .account(let failure): return .accountFailure(code: failure.code, detail: failure.detail)
        case .pairedElsewhere: return .pairedElsewhere
        default: return .unavailable(error.localizedDescription)
        }
    }

    private func recordSendResult(operation: String, error: Error? = nil) async {
        // A Mac whose phone is paired elsewhere says so once, as its receive
        // health; each refused write is that same fact, not a send failure.
        if case .pairedElsewhere? = error as? DeviceSyncError { return }
        doctorSendMeasured = true
        doctorSendFailures[operation] = error.map(Self.transportHealth)
        if let error, case .account(let failure) = error as? DeviceSyncError {
            await recordAccountFailure(failure)
        }
        if error == nil { onTransportSucceeded?() }
    }

    // N-mem fix: insert a seen id and cap the in-memory set so it can't grow
    // without bound. fix-2026-06-10 sync-audit #2: insertion-ordered, evicting
    // oldest first (mirrors MacSyncEngine.recordProcessed / fix-R9-9).
    private func recordSeenMessageID(_ id: String) {
        guard !seenMessageIDs.contains(id) else { return }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        trimSeenMessageIDsIfNeeded()
    }

    private func trimSeenMessageIDsIfNeeded() {
        while seenMessageIDsOrdered.count > Self.seenMessageIDsCap {
            let oldest = seenMessageIDsOrdered.removeFirst()
            seenMessageIDs.remove(oldest)
        }
    }

    // CK-3c: CK-consumed ids persist to UserDefaults — synchronous, ordered on
    // the main actor, atomic — so a restart within the transport cursor's 30s
    // re-pull window doesn't re-deliver a CK message. Separate key from the Drive
    // path's file store; both feed the unified in-memory seen-set on setup.
    // Mirrors the iOS bridge (which already persists its seen-set to UserDefaults).
    private static let ckProcessedIDsDefaultsKey = "NativeAgent.iCloud.ckProcessedIDs.v1"

    private func persistCKSeenIDs() {
        ICloudSeenIDDefaultsStore.save(
            seenMessageIDsOrdered,
            defaults: .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
    }

    private func loadCKSeenIDs() {
        let ckIDs = ICloudSeenIDDefaultsStore.load(
            defaults: .standard,
            key: Self.ckProcessedIDsDefaultsKey,
            cap: Self.seenMessageIDsCap
        )
        for id in ckIDs where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        trimSeenMessageIDsIfNeeded()
    }

    // MARK: - Setup

    public func setup() {
        // N10 fix: guard against repeat setup() calls stacking KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        // A stored sentence from an earlier key change could never settle; the
        // owed publication (the pairing fact) says it now, and settles itself.
        UserDefaults.standard.removeObject(forKey: "NativeAgent.pairing.publicationWarning.v1")
        if pairedPhonesSubscription == nil {
            pairedPhonesSubscription = sync.pairedPhones.$phones.sink { [weak self] _ in
                Task { @MainActor in self?.refreshPhoneConnection() }
            }
        }
        lastPhoneContactAt = SignedPeerEvidenceStore.load(dataRoot: sync.dataRoot)?.contactAt
        doctorTransportHealth = .unmeasured
        doctorSendFailures.removeAll()
        doctorSendMeasured = false
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration

        // CloudKit-only starts do not pass through the Drive bootstrap below,
        // so restore their persisted replay filter before the first drain.
        loadCKSeenIDs()
        recordCloudKitPushEvidence()

        // CloudKit is independent of the ubiquity/Drive mount. Public
        // Developer ID builds may have the CloudKit service without
        // CloudDocuments, so establish the entitlement-checked transport
        // before resolving the legacy Documents container.
        configureDeviceTransportIfAvailable()

        // A successfully constructed CloudKit transport is the runtime
        // capability proof for the public lane. Keep KVS as a best-effort
        // control/progress nudge, but do not mount or scan the retired Drive
        // data plane. If CloudKit is unavailable (or the build selects KVS),
        // setup falls through to the complete legacy path unchanged.
        if deviceTransport != nil {
            setupTask = Task {
                let failure = await sync.engine.startCloudKitSnapshotProjection()
                guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }
                if let failure { syncStatus = failure }
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(kvsDidChange(_:)),
                    name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: nil
                )
                Task.detached(priority: .utility) {
                    _ = await withCKTimeout("iCloudBridge.setup.cloudKitKVSNudge") {
                        NSUbiquitousKeyValueStore.default.synchronize()
                    }
                }
            }
            return
        }

        // Without the CloudKit transport, KVS is the pairing channel itself.
        Task.detached(priority: .userInitiated) { await PairingSecretManager.publishMaterialToKVS() }

        // 2026-05-28 fix: FileManager.default.url(forUbiquityContainerIdentifier:)
        // is SYNCHRONOUS and can block for many seconds (sometimes 30s+) on first
        // launch while the iCloud container mounts. Running it on the @MainActor
        // froze the UI thread long enough that runningboardd / the watchdog killed
        // the app. The iOS companion hit this exact bug; this ports that fix.
        //
        // Move the container resolve off the main actor; hop back to update
        // @Published state, register observers, and start the metadata query.
        let containerID = NativeAgentICloudBridgeConstants.containerID
        let sync = self.sync
        setupTask = Task.detached(priority: .utility) {
            // This is the call that was blocking — runs on a background thread now.
            let containerURL = FileManager.default.url(
                forUbiquityContainerIdentifier: containerID
            )
            await sync.bridge.applyContainerResult(containerURL, generation: generation)
        }
    }

    /// Applies the result of the off-main-actor container lookup back on the
    /// main actor. Split out from setup() so the Task.detached closure does not
    /// capture `self` directly (Swift-6 strict concurrency clean).
    @MainActor
    private func applyContainerResult(_ containerURL: URL?, generation: Int) async {
        // Ignore a stale resolve from a superseded setup()/tearDown().
        guard generation == setupGeneration, isSetUp else { return }
        guard let containerURL else {
            // Reset isSetUp so the caller can retry later once iCloud signs in.
            isSetUp = false
            available = false
            syncStatus = "iCloud container unavailable — sign into iCloud in System Settings"
            doctorTransportHealth = .unavailable(syncStatus)
            OrganPulse.recordOff("snapshot_integrity", because: "iCloud Drive unavailable")
            return
        }

        let docsURL = containerURL.appendingPathComponent("Documents")
        driveURL = docsURL

        // Create directory structure if needed (off-main, awaited before proceeding)
        await Task.detached(priority: .utility) { [docsURL] in
            Self.createDriveDirectories(docsURL: docsURL)
        }.value
        // Re-assert staleness AFTER the await: the off-main directory create is a
        // suspension point, so tearDown() (or a newer setup()) may have run while
        // we were suspended. Without this re-check we'd re-enable observers, the
        // metadata query, and the sync engine for a superseded/torn-down setup,
        // and leave isSetUp=false so a later setup() stacks duplicate observers.
        guard generation == setupGeneration, isSetUp else { return }
        // 2026-05-29 fix: loadProcessedMessageIDs does try? Data(contentsOf:) on a
        // file inside the iCloud ubiquitous container, which can trigger an
        // on-demand download and block the main thread — the same watchdog-kill
        // mode the container resolve above was moved off-main to avoid. Read it
        // off-main, awaited, then hop back to mutate state.
        let loaded = await Task.detached(priority: .utility) { [docsURL] in
            Self.loadProcessedMessageIDs(docsURL: docsURL)
        }.value
        // Re-assert staleness AFTER the new await suspension point (reentrancy):
        // tearDown() or a newer setup() may have run while we were suspended.
        guard generation == setupGeneration, isSetUp else { return }
        // fix-2026-06-10 sync-audit #2: restore the ordered array (disk order =
        // insertion order) so eviction stays oldest-first across restarts.
        seenMessageIDs = []
        seenMessageIDsOrdered = []
        for id in loaded where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        // CK-3c: also restore CK-consumed ids (UserDefaults) into the unified
        // seen-set so a restart doesn't re-deliver a CloudKit message.
        loadCKSeenIDs()
        trimSeenMessageIDsIfNeeded()

        // PATCH-2026-05-07: ios-parity start snapshot writer + inbox watcher
        let failure = await sync.engine.start(docsURL: docsURL)
        guard generation == setupGeneration, isSetUp else { return }

        available = failure == nil
        syncStatus = failure ?? "iCloud readiness not checked"
        doctorTransportHealth = failure.map { .unavailable($0) } ?? .unmeasured

        // Start KVS change observation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        _ = await withCKTimeout("iCloudBridge.setup.kvsSynchronize") {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        // Teardown can retire this setup during the final KVS suspension too.
        guard generation == setupGeneration, isSetUp, !Task.isCancelled else { return }

        // Start NSMetadataQuery watching iOS outbox folder
        startMetadataQuery(docsURL: docsURL)
    }

    /// Publication reports acceptance of the requested groups, not readiness.
    func notePublication(_ failures: [NAMobileSnapshotGroup: DeviceSyncError]?) {
        guard accountFailure == nil, !phonePairedElsewhere else { return }
        guard let failures else { syncStatus = "CloudKit publication unconfirmed"; return }
        syncStatus = failures.min(by: { $0.key.rawValue < $1.key.rawValue }).map {
            "CloudKit did not accept the phone's \($0.key.rawValue) snapshot: \($0.value.localizedDescription)"
        } ?? "CloudKit accepted the requested snapshots"
    }

    /// Starts the checked CloudKit transport without depending on iCloud Drive.
    /// The factory remains the sole entitlement/crash guard. Legacy KVS/Drive
    /// setup is retained only when this returns nil.
    private func configureDeviceTransportIfAvailable() {
        guard deviceTransport == nil else { return }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        guard let transport = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac,
            containerIdentifier: containerID
        ) else {
            recordTransportOrgansOff("no CloudKit transport")
            transportRefusal = Self.cloudKitRefusal(containerID: containerID)
            return
        }
        transportRefusal = nil
        deviceTransport = transport
        OrganPulse.recordStarting("presence_beat", cadence: NAMacPresence.beat)
        (transport as? CloudKitDeviceTransport)?.useAssetSecret {
            guard let encoded = try? PairingSecretManager.existingSecretBase64() else { return nil }
            return Data(base64Encoded: encoded)
        }
        (transport as? CloudKitDeviceTransport)?.observeAccountFailures { [weak self] failure in
            await self?.recordAccountFailure(failure)
        }
        available = true
        syncStatus = "CloudKit connecting…"
        nativeLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=mac)")

        registerIncomingTransportObserver(transport)
        let generation = setupGeneration
        let previous = transportSetupTask
        previous?.cancel()
        let taskID = UUID()
        transportSetupTaskID = taskID
        transportSetupTask = Task {
            defer { if transportSetupTaskID == taskID { transportSetupTask = nil } }
            await previous?.value
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await transport.observeStatus(
                key: NAVisualNotificationCapability.statusKey,
                onChange: { [weak self] value in
                    await MainActor.run {
                        guard let self, self.isSetUp, generation == self.setupGeneration else { return }
                        self.cloudKitVisualNotificationPeerReady =
                            NAVisualNotificationCapability.isReady(value)
                    }
                }
            )
            guard !Task.isCancelled, isSetUp, generation == setupGeneration else { return }
            await claimPhonePairing()
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(deviceDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        let monitor = NWPathMonitor()
        deviceNetworkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.setupGeneration == generation else { return }
                let regained = self.deviceNetworkSatisfied == false && satisfied
                self.deviceNetworkSatisfied = satisfied
                if regained { _ = await self.drainDeviceTransport(trigger: .network) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "NativeAgent.DeviceSync.network"))
        scheduleNextDeviceDrainFallback()
        NSApplication.shared.registerForRemoteNotifications(matching: [])
    }

    @objc private func deviceDidWake() {
        Task { _ = await self.drainDeviceTransport(trigger: .wake) }
    }

    private var deviceReceiveCadence: TimeInterval? {
        drainPolicy.interval(now: Date(), polling: !cloudKitPushProven,
            active: activeCloudKitChats > 0 || phoneRequests.hasPendingRequest)
    }

    private var devicePollingNote: String {
        cloudKitPushProven ? "" : cloudKitPushUnavailable
            ? "polling: push unavailable" : "polling: push unproven"
    }

    /// A received push proves delivery across launches; an unannounced phone
    /// message older than two eight-second re-signals disproves it. This local
    /// scalar is separate from account failures, which a healthy pull clears.
    private func recordCloudKitPushEvidence(received: Bool? = nil) {
        let url = sync.dataRoot.appendingPathComponent("icloud/chat_push_proof.json")
        do {
            if let received {
                cloudKitPushProofAt = received ? Date() : nil
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(cloudKitPushProofAt).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                cloudKitPushProofAt = try JSONDecoder().decode(Date?.self, from: Data(contentsOf: url))
            }
        } catch {
            nativeLog("[iCloudBridge] push evidence unavailable: %@", error.localizedDescription)
        }
    }

    func scheduleNextDeviceDrainFallback() {
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = nil
        guard isSetUp, deviceTransport != nil else {
            deviceDrainTimerTask = nil
            recordTransportOrgansOff("iPhone transport gone")
            return
        }
        guard !phonePairedElsewhere else {
            deviceDrainTimerTask = nil
            return
        }
        let now = Date()
        guard let delay = drainPolicy.nextDrainDelay(now: now, lastDrainAt: lastDeviceDrainAt,
            polling: !cloudKitPushProven, active: activeCloudKitChats > 0 || phoneRequests.hasPendingRequest) else {
            deviceDrainCadence = nil
            OrganPulse.recordOff("icloud_drain", because: "resting — waiting for change")
            return
        }
        let cadence = deviceReceiveCadence
        if deviceDrainCadence != cadence {
            deviceDrainCadence = cadence
            OrganPulse.record("icloud_drain", .skipped,
                note: devicePollingNote.isEmpty ? "starting" : devicePollingNote, cadence: cadence)
        }
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        let generation = setupGeneration
        deviceDrainTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self, self.isSetUp,
                  generation == self.setupGeneration else { return }
            // The handle owns only the sleeping timer, never the drain it wakes.
            // Streaming output re-arms this timer while the drain awaits the
            // chat. Retaining this handle there cancelled the final reply's
            // owner as soon as its first delta was sent.
            self.deviceDrainTimerTask = nil
            guard self.deviceReceiveCadence != nil else {
                self.scheduleNextDeviceDrainFallback()
                return
            }
            await self.drainDeviceTransport(trigger: .fallbackTimer)
        }
    }

    /// The drain and the presence beat run only over the transport: without it
    /// they are off, not overdue.
    private func recordTransportOrgansOff(_ reason: String) {
        for organ in ["icloud_drain", "presence_beat"] { OrganPulse.recordOff(organ, because: reason) }
    }

    /// Registration alone does not prove the subscription can wake this process.
    public func cloudKitPushRegistrationSucceeded() {
        Self.pushLog.notice("APNs registration succeeded")
        guard deviceTransport != nil else { return }
        cloudKitPushUnavailable = false
        scheduleNextDeviceDrainFallback()
    }

    public func cloudKitPushRegistrationFailed(_ error: Error) {
        Self.pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        guard deviceTransport != nil else { return }
        nativeLog("[iCloudBridge] CloudKit push unavailable; retaining polling fallback: %@",
              error.localizedDescription)
        recordCloudKitPushUnavailable()
    }

    private func recordCloudKitPushUnavailable() {
        cloudKitPushUnavailable = true
        recordCloudKitPushEvidence(received: false)
        deviceDrainCadence = nil
        scheduleNextDeviceDrainFallback()
    }

    public func recognizesCloudKitRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let recognized = CloudKitDeviceTransport.isDeviceSyncNotification(userInfo)
        if CloudKitDeviceTransport.isPairingNotification(userInfo) { phonePairingRecheckDue = true }
        Self.pushLog.notice("Remote notification received deviceSync=\(recognized)")
        return recognized
    }

    public func handleCloudKitPushWake(_ userInfo: [AnyHashable: Any]) async {
        if phonePairingRecheckDue || !phonePairingSettled {
            phonePairingRecheckDue = false
            await claimPhonePairing()
        }
        guard !phonePairedElsewhere else { return }
        if CloudKitDeviceTransport.isChatNotification(userInfo) {
            recordCloudKitPushEvidence(received: true)
            cloudKitPushUnavailable = false
        }
        // A push is peer activity; follow-up traffic keeps the fast cadence.
        drainPolicy.notePeerActivity(at: Date())
        _ = await drainDeviceTransport(trigger: .cloudKitPush)
    }

    /// Publish the exact bytes returned by the atomic rotation transaction.
    /// This avoids a second disk read becoming a different authority decision.
    @discardableResult
    public func publishPairingSecret(_ secret: Data) async -> Bool {
        let generation = setupGeneration
        guard await publishPairing(secret), generation == setupGeneration else { return false }
        notePairingHeld()
        return true
    }

    /// A key change is owed to the account's pairing record from before the
    /// key changes until the record takes it, so no quit or claim in between
    /// reads this install's own old key as another Mac's. Only a key change
    /// owes: a move-here the person pressed that failed stays their error to
    /// retry, never a standing claim.
    public func owePairingPublication(_ owed: Bool) {
        if owed {
            UserDefaults.standard.set(true, forKey: pairingPublicationOwedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pairingPublicationOwedKey)
        }
        refreshPhoneConnection()
    }

    /// The account's pairing record takes this Mac's key: the person's act or
    /// this Mac's own key change. Landing settles anything owed.
    private func publishPairing(_ secret: Data) async -> Bool {
        guard let deviceTransport else { return false }
        let published = await PairingSecretManager.publishMaterial(secret, to: deviceTransport)
        await recordSendResult(operation: "pairing", error: published ? nil :
            DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
        if published { owePairingPublication(false) }
        return published
    }

    /// The phone follows one Mac: whichever key the account's Mac pairing
    /// record holds. Launch takes that record only when it is free or already
    /// this Mac's. Another Mac keeps the phone until the person moves it here
    /// (`usePhoneHere`), so launching a second Mac never takes the phone.
    private func claimPhonePairing() async {
        guard let transport = deviceTransport else { return }
        let generation = setupGeneration
        let accountGeneration = accountFailureGeneration
        let secret: Data
        do {
            secret = try PairingSecretManager.loadOrGenerateSecret()
        } catch {
            nativeLog("[PairingBootstrap] Pairing unavailable; refusing device claim: \(error.localizedDescription)")
            pairingKeyUnreadable = true
            await recordSendResult(operation: "pairing", error:
                DeviceSyncError.underlying(message: "Pairing publication failed; check the Mac pairing key and iCloud."))
            syncStatus = "iPhone pairing unavailable — check the Mac pairing key and iCloud"
            return
        }
        pairingKeyUnreadable = false
        let held: Bool?
        if UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            held = await publishPairing(secret) ? true : nil
        } else {
            held = await transport.claimPairing(secret: secret)
            if held == nil {
                await recordSendResult(operation: "pairing", error:
                    DeviceSyncError.transient(message: "The iPhone pairing record could not be read; retrying at the next sync."))
            } else {
                await recordSendResult(operation: "pairing")
            }
        }
        guard generation == setupGeneration, let held else { return }
        // The account answered; a stored account failure is no longer true.
        if accountFailure != nil, accountGeneration == accountFailureGeneration { await clearAccountFailure() }
        if held {
            notePairingHeld()
        } else {
            notePairedElsewhere()
        }
    }

    /// The person's act: move the phone to this Mac.
    @discardableResult
    public func usePhoneHere() async -> Bool {
        guard deviceTransport != nil,
              let secret = try? PairingSecretManager.loadOrGenerateSecret() else { return false }
        return await publishPairingSecret(secret)
    }

    /// This Mac holds the pairing. Coming out of silence (launch, or another
    /// Mac had the phone), everything it has for the phone goes out afresh:
    /// the other Mac may have written over all of it.
    private func notePairingHeld() {
        let wasSpeaking = speaksToPhone
        let wasElsewhere = phonePairedElsewhere
        phonePairingSettled = true
        phonePairedElsewhere = false
        guard !wasSpeaking else { return }
        lastPublishedProviderCatalogStatus = nil
        lastPublishedMobileSnapshotStatus.removeAll()
        if wasElsewhere {
            // The drain and the presence republish below record their own pulses.
            doctorTransportHealth = .unmeasured
        }
        Task.detached(priority: .utility) { await PairingSecretManager.publishMaterialToKVS() }
        Task {
            _ = await self.publishProviderCatalogStatus()
            await self.sync.engine.republishPhonePages()
            if wasElsewhere { _ = await self.drainDeviceTransport(trigger: .coalesced) }
        }
    }

    private func notePairedElsewhere() {
        phonePairingSettled = true
        phonePairedElsewhere = true
        syncStatus = Self.pairedElsewhereStatus
        doctorTransportHealth = .pairedElsewhere
        doctorSendFailures.removeAll()
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = nil
        recordTransportOrgansOff("the iPhone is paired with another Mac")
    }

    // MARK: - The phone connection

    func notePhoneContact(at peerTimestamp: Date) {
        let contact = min(peerTimestamp, Date())
        if contact > (lastPhoneContactAt ?? .distantPast) { lastPhoneContactAt = contact }
    }

    private func refreshPhoneConnection() {
        let next = NAPhoneConnection(pairing: phonePairingFact, transport: phoneTransportFact, exchange: phoneExchangeFact)
        if next != phoneConnection { phoneConnection = next }
    }

    private var phonePairingFact: NAPhoneConnection.Fact {
        if pairingKeyUnreadable {
            return .init(.broken, "This Mac's pairing key can't be read.", owner: .personOnMac,
                         lever: "Open Connectors → iPhone → Regenerate the pairing key, confirm Regenerate, then pair the iPhone again.")
        }
        if deviceTransport != nil, UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            return .init(.waiting, "This Mac's new pairing key is waiting for iCloud to take it.", owner: .network,
                         lever: "Keep this Mac online with NativeAgent open; it publishes the key on its own.")
        }
        if phonePairedElsewhere {
            return .init(.waiting, "Your iPhone is paired with another Mac (or an earlier install) on this Apple Account.",
                         owner: .personOnMac,
                         lever: "Choose Connectors → iPhone → Use my iPhone with this Mac to disconnect it from the other Mac and connect it here.")
        }
        let phones = sync.pairedPhones.phones.filter { $0.status != .removed }
        if phones.contains(where: { $0.status == .pending }) {
            return .init(.waiting, "An iPhone is waiting for you to pair it.", owner: .personOnMac,
                         lever: "Open Connectors → iPhone, match the code the iPhone shows, then choose Pair.")
        }
        guard phones.contains(where: { $0.status == .paired }) else {
            return .init(.waiting, "No iPhone is paired yet.", owner: .personOnPhone,
                         lever: "Open NativeAgent on your iPhone, signed in to this Apple Account, and tap Connect.")
        }
        if deviceTransport != nil, !phonePairingSettled {
            return .init(.waiting, "Paired; checking in iCloud that this Mac still holds the pairing.")
        }
        return .init(.holds, "Paired with your iPhone.")
    }

    private var phoneTransportFact: NAPhoneConnection.Fact {
        if accountFailure != nil {
            return .init(.broken, "iCloud sign-in needs attention on this Mac.", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and finish signing in to iCloud.")
        }
        if deviceTransport == nil, let transportRefusal { return transportRefusal }
        let carrier = deviceTransport != nil ? "CloudKit" : "iCloud Drive"
        switch doctorTransportHealth {
        case .available, .pairedElsewhere:
            guard doctorSendFailures.isEmpty else {
                return .init(.waiting, "\(carrier) is up; some deliveries to the iPhone are waiting to resend.", owner: .network,
                             lever: "Keep this Mac online with NativeAgent open; it resends on its own.")
            }
            return .init(.holds, "\(carrier) carries their messages.")
        case .unmeasured:
            return .init(.waiting, "\(carrier) is starting; not measured yet.")
        case .signedOut:
            return .init(.broken, "This Mac is not signed in to iCloud.", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and sign in.")
        case .notEntitled:
            return .init(.broken, "This build is not signed to use iCloud for the phone.", owner: .builder,
                         lever: "Install a signed NativeAgent build.")
        case .quotaExceeded:
            return .init(.broken, "iCloud storage is full.", owner: .iCloudAccount,
                         lever: "Free iCloud storage in System Settings → Apple Account → iCloud.")
        case .accountFailure(_, let detail):
            return .init(.broken, "iCloud turned this Mac away: \(detail)", owner: .iCloudAccount,
                         lever: "Open System Settings → Apple Account and check iCloud.")
        case .unavailable(let reason):
            return .init(.waiting, "\(carrier)'s last receive failed: \(reason)", owner: .network,
                         lever: "Check this Mac's internet connection; NativeAgent retries on its own.")
        }
    }

    private var phoneExchangeFact: NAPhoneConnection.Fact {
        if let rejected = lastPhoneRejectedAt, rejected > (lastPhoneContactAt ?? .distantPast) {
            return .init(.broken,
                         "Turned away the iPhone's last message (\(rejected.formatted(date: .abbreviated, time: .shortened))): it was signed with a key this Mac does not hold.",
                         owner: .personOnPhone,
                         lever: "On the iPhone, open Settings › Connection and choose Pair with Mac.")
        }
        guard let contact = lastPhoneContactAt else {
            return .init(.waiting, "No message from your iPhone yet.", owner: .personOnPhone,
                         lever: "Send a message from NativeAgent on your iPhone.")
        }
        return .init(.holds, "Last message from your iPhone: \(contact.formatted(date: .abbreviated, time: .shortened)).")
    }

    /// Why a build meant to use CloudKit got no transport for the phone.
    nonisolated static func cloudKitRefusal(containerID: String) -> NAPhoneConnection.Fact? {
        guard DeviceSyncTransportResolver.resolvedKind() == .cloudkit else { return nil }
        guard DeviceCloudKitPreflight.hasCloudKitEntitlement() else {
            return .init(.broken, "This build is not signed for CloudKit, so the iPhone cannot reach it.", owner: .builder,
                         lever: "Install a NativeAgent build signed with CloudKit.")
        }
        return .init(.broken,
                     "This build is configured for iCloud container \(containerID), but its signature grants another, so the iPhone cannot reach it.",
                     owner: .builder,
                     lever: "Install a NativeAgent build whose iCloud container matches its signature.")
    }

    // MARK: - Drive directory bootstrap

    nonisolated private static func createDriveDirectories(docsURL: URL) {
        let fm = FileManager.default
        for folder in [DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processing, DriveFolder.processed] {
            let url = docsURL.appendingPathComponent(folder)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Send chat message (Drive for payload + KVS trigger)

    nonisolated public static func failedReplyClaims(dataRoot: URL, changedPath: URL? = nil) throws -> [(path: URL, at: String)] {
        let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true)
        if let changedPath, changedPath.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL { return [] }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        if let changedPath, !FileManager.default.fileExists(atPath: changedPath.path) { return [] }
        let paths = try changedPath.map { [$0] } ?? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try paths.filter { $0.pathExtension == "json" }.compactMap { path in
            let record = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: path))
            guard record.state == "failed_before_answer" else { return nil }
            let id = record.msgId
            guard !id.isEmpty, let at = record.updatedAt, record.action == "chat",
                  path.deletingPathExtension().lastPathComponent == MacSyncSnapshotIntegrity.digest(Data(id.utf8)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (path: path, at: at)
        }
    }

    public func recoverReply(_ response: ChatResponse, route: AgentBridgeCompletionRoute, priorVerdict: String? = nil) async throws -> String {
        guard let answerSession = response.sessionId, let sourceKey = route.sourceKey,
              AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else {
            throw BridgeError.containerUnavailable
        }
        let session = route.sessionId ?? answerSession
        let correlation = route.correlationId ?? response.runId
        let transportID = "reply-" + MacSyncSnapshotIntegrity.digest(Data("\(answerSession)\n\(response.runId)".utf8))
        let root = sync.dataRoot
        if TurnQuietHoursWindow.holdsResidentWake(session: answerSession, dataRoot: root) { return "owed" }
        let reservation = try Self.replyReservation(correlation, session: session, sourceKey: sourceKey, dataRoot: root)
        let verdict = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root)
        if verdict == nil {
            var metadata = ["transport": "icloud", "source": "mac", "assistantRunId": response.runId, "replyTo": route.replyTo ?? "iphone",
                            "targetSourceKey": route.sourceKey ?? "", "canonicalAnswerRunId": response.runId,
                            "canonicalAnswerSessionId": answerSession]
            if response.terminalState == .failed {
                metadata["kind"] = "rejection"
                metadata["reason"] = "failed_before_answer"
                metadata["errorDetail"] = response.output
            }
            if let run = reservation.resendRunId { metadata["canonicalAnswerRunId"] = run }
            if let session = reservation.resendSessionId { metadata["canonicalAnswerSessionId"] = session }
            let attachments = try ICloudIncomingTurnForwarder.bridgeAttachments(from: response.attachments ?? [],
                text: response.output, sessionID: session, correlationID: correlation, metadata: metadata)
            if let priorVerdict {
                let secret = try PairingSecretManager.loadOrGenerateSecret()
                let message = try BridgeMessage.make(id: transportID, sender: "mac", text: response.output,
                    sessionID: session, correlationID: correlation, metadata: metadata, attachments: attachments).signed(with: secret)
                guard await Self.appendChatDeliveryReceipt(message, direction: "mac_to_ios", transport: "legacy_completion",
                    status: priorVerdict == "completed" ? .acceptedByTransport : .queuedForICloudSync,
                    secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
            } else {
                do {
                    _ = try await sendChatMessage(text: response.output, sessionID: session, correlationID: correlation,
                        metadata: metadata, attachments: attachments, messageID: transportID)
                } catch {
                    if error as? ChatOrchestrationError == .replyHeldForQuietHours { return "owed" }
                    guard try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root) != nil else { throw error }
                }
            }
        }
        guard let settled = try await Self.replyVerdict(correlationID: correlation, runID: response.runId, dataRoot: root) else {
            return "owed"
        }
        try await Self.settleReply(correlation, session: session, sourceKey: sourceKey, state: settled, dataRoot: root)
        // CloudKit took it; the phone has not said it holds it, so it stays owed there.
        try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root, sessionId: answerSession,
                                                                           runId: response.runId, verdict: "accepted_by_transport")
        return settled
    }

    nonisolated private static func replyReceipts(dataRoot: URL) async throws -> [[String: JSONValue]] {
        let path = chatDeliveryReceiptsURL(dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore().withFileLock(path) { try loadChatDeliveryReceiptRows(path: path) }
    }

    nonisolated static func replyVerdict(correlationID: String, runID: String, dataRoot: URL) async throws -> String? {
        let rows = try await replyReceipts(dataRoot: dataRoot)
        return replyVerdict(rows: rows, correlationID: correlationID, runID: runID)
    }

    nonisolated private static func replyVerdict(rows: [[String: JSONValue]], correlationID: String, runID: String) -> String? {
        let statuses = rows.compactMap { fields -> String? in
            guard fields["direction"] == .string("mac_to_ios"),
                  fields["correlationId"] == .string(correlationID),
                  [JSONValue.string("reply"), .string("codex_completion")].contains(fields["kind"] ?? .null)
                    || fields["kind"] == .string("rejection") && fields["canonicalAnswerRunId"] != nil,
                  (fields["assistantRunId"] ?? fields["correlationId"]) == .string(runID)
                    || fields["kind"] == .string("codex_completion") && fields["assistantRunId"] == .string(correlationID),
                  case .string(let status)? = fields["status"] else { return nil }
            return status
        }
        if statuses.contains("accepted_by_transport") || statuses.contains("confirmed_by_peer") { return "completed" }
        return statuses.contains("queued_for_icloud_sync") ? "sent_unconfirmed" : nil
    }

    private func resendSavedReply(_ message: BridgeMessage, dataRoot: URL) async -> Bool? {
        guard message.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" else { return nil }
        do {
            guard let session = message.sessionID, NativeAgentChatSessionID.normalizedPathComponent(session) == session else { return false }
            let source = message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"] ?? "app"
            let route = AgentBridgeCompletionRoute(surface: "ios", sessionId: session, sourceKey: source,
                replyTo: message.metadata?["clientSurface"], correlationId: message.id)
            if try await Self.replyVerdict(correlationID: message.id, runID: message.id, dataRoot: dataRoot) != nil {
                _ = try await recoverReply(ChatResponse(runId: message.id, model: "", output: "", sessionId: session), route: route)
                return true
            }
            let record = try Self.readChat(message.id, dataRoot: dataRoot)
            var originalRun: String?
            var originalSession = session
            if let saved = record.resendSessionId { originalSession = saved }
            if let saved = record.resendRunId { originalRun = saved }
            else {
                let receipts = try await Self.replyReceipts(dataRoot: dataRoot)
                for receipt in receipts.reversed() {
                    guard receipt["direction"] == .string("mac_to_ios"),
                          receipt["kind"] == .string("reply"), receipt["sessionId"] == .string(session),
                          receipt["targetSourceKey"] == .string(source),
                          case .string(let correlation)? = receipt["correlationId"],
                          case .string(let run) = receipt["assistantRunId"] ?? receipt["correlationId"] ?? .null,
                          Self.replyVerdict(rows: receipts, correlationID: correlation, runID: run) == "sent_unconfirmed" else { continue }
                    if case .string(let canonical)? = receipt["canonicalAnswerRunId"] { originalRun = canonical }
                    else { originalRun = run }
                    if case .string(let canonical)? = receipt["canonicalAnswerSessionId"] { originalSession = canonical }
                    break
                }
            }
            var response = ChatResponse(runId: message.id, model: "", output: "There's no saved answer waiting to be delivered.", sessionId: session)
            if let originalRun, !originalRun.isEmpty {
                guard let saved = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: originalSession, runId: originalRun) else { return false }
                response = saved
                response.runId = message.id
            }
            try await Self.bindReplySession(message, sessionID: session, dataRoot: dataRoot,
                resendRunID: originalRun ?? "", resendSessionID: originalSession)
            return try await recoverReply(response, route: route) != "owed"
        } catch { return false }
    }

    public func sendChatMessage(
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [NativeAgentShared.MultimodalAttachment] = [],
        messageID: String = UUID().uuidString,
        timestamp: Date? = nil
    ) async throws -> BridgeMessage {
        let root = sync.dataRoot
        let finalReply = correlationID != nil && (metadata?["kind"] == nil
            || ["reply", "codex_completion"].contains(metadata?["kind"] ?? "")
            || metadata?["kind"] == "rejection" && metadata?["canonicalAnswerRunId"] != nil)
        func requireDeliveryAdmission() throws {
            guard finalReply || metadata?["kind"] == "text_delta" else { return }
            guard try CodexCompletionLifecycleProjection.permitsDelivery(
                sessionId: metadata?["canonicalAnswerSessionId"] ?? sessionID,
                runId: metadata?["canonicalAnswerRunId"] ?? metadata?["assistantRunId"] ?? correlationID,
                configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: root), dataRoot: root) else {
                throw CocoaError(.userCancelled)
            }
        }
        try requireDeliveryAdmission()
        if (finalReply || metadata?["kind"] == "text_delta"),
           TurnQuietHoursWindow.holdsResidentWake(session: metadata?["canonicalAnswerSessionId"] ?? sessionID, dataRoot: root) {
            throw ChatOrchestrationError.replyHeldForQuietHours
        }
        let unsigned = BridgeMessage.make(
            id: messageID,
            sender: "mac",
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments,
            timestamp: timestamp ?? Date()
        )
        // Phase 14e-iCloud: sign with the pairing secret. PairingSecretManager
        // is the Mac-side single source of truth (used by MacSyncEngine for
        // the action channel) — same secret signs both channels so iOS can
        // verify with one key. Pairing state must be durable and checked before
        // any message is signed or published; an unavailable local secret may
        // never degrade into an unsigned transport message.
        let (secret, msg) = try await sync.storage.perform {
            let secret = try PairingSecretManager.loadOrGenerateSecret()
            return (secret, try unsigned.signed(with: secret))
        }
        let runID = metadata?["assistantRunId"] ?? correlationID ?? messageID
        if finalReply, !inFlightReplyIDs.insert(runID).inserted { throw BridgeError.containerUnavailable }
        defer { if finalReply { inFlightReplyIDs.remove(runID) } }
        if finalReply, let correlationID {
            if try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) != nil { return msg }
        }
        let operation: String
        if let correlationID {
            operation = "chat turn \(correlationID)" + (metadata?["kind"] == "text_delta" ? " delta" : "")
        } else {
            operation = "message \(msg.id)"
        }

        // CK-3b: CloudKit transport path. The signed BridgeMessage rides verbatim
        // in the record's payloadJSON (lossless — signature preserved), so iOS
        // verifies with the same secret exactly as on the Drive path. The shared
        // codec rejects an oversized encoded record before CloudKit sees it,
        // producing a clear user-facing error instead of an opaque server failure.
        if let ck = deviceTransport {
            do {
                try requireDeliveryAdmission()
                try await ck.send(msg) {
                    if finalReply {
                        guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "cloudkit",
                            status: .queuedForICloudSync, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
                    }
                }
                if metadata?["kind"] != "text_delta", let correlationID {
                    doctorSendFailures["chat turn \(correlationID) delta"] = nil
                }
                await recordSendResult(operation: operation)
            } catch {
                syncStatus = "CloudKit did not accept message: \(error.localizedDescription)"
                await recordSendResult(operation: operation, error: error)
                if finalReply, let correlationID,
                   try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) == "sent_unconfirmed" {
                    guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "cloudkit",
                        status: .queuedForICloudSync, secret: secret, dataRoot: root,
                        detail: error.localizedDescription) else { throw CocoaError(.fileWriteUnknown) }
                }
                throw error
            }
            await recordChatDeliveryReceipt(
                msg,
                transport: "cloudkit",
                status: .acceptedByTransport,
                secret: secret
            )
            if finalReply, let sessionID, let correlationID,
               try await Self.replyVerdict(correlationID: correlationID, runID: runID, dataRoot: root) == "completed" {
                try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: root, sessionId: sessionID,
                                                                                   runId: runID, verdict: "accepted_by_transport")
            }
            // CK-5: fire the lightweight KVS "new message" nudge so the peer drains
            // CloudKit IMMEDIATELY — an event-driven foreground trigger (fires on
            // send, not on a timer, so no idle churn / scroll bounce), and it works
            // in the foreground where iOS withholds the silent push. The public
            // build (no KVS) falls back to the CloudKit push. A no-op if KVS is
            // absent; wrapped in a timeout so a wedged KVS can't block the send.
            let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
            _ = await withCKTimeout("iCloudBridge.sendChatMessage.ckNudge", seconds: 3) {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                return kvs.synchronize()
            }
            noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
            lastSyncAt = Date()
            syncStatus = "CloudKit accepted message — waiting for iOS"
            return msg
        }

        // Explicit/fail-safe legacy KVS/ubiquity path.
        guard let docsURL = driveURL else {
            throw BridgeError.containerUnavailable
        }
        let outboxURL = docsURL
            .appendingPathComponent(DriveFolder.outboxMac)
            .appendingPathComponent("\(msg.id).json")
        let data = try await sync.storage.perform {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try encoder.encode(msg)
        }
        if finalReply {
            guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "icloud_drive",
                status: .queuedForICloudSync, secret: secret, dataRoot: root) else { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            try requireDeliveryAdmission()
            try await Task.detached(priority: .utility) { [data, outboxURL] in
                try data.write(to: outboxURL, options: .atomic)
            }.value
        } catch {
            syncStatus = "Could not queue iCloud message: \(error.localizedDescription)"
            if finalReply {
                let exists = await sync.storage.perform { FileManager.default.fileExists(atPath: outboxURL.path) }
                guard await Self.appendChatDeliveryReceipt(msg, direction: "mac_to_ios", transport: "icloud_drive",
                    status: exists ? .queuedForICloudSync : .failedBeforeDispatch,
                    secret: secret, dataRoot: root, detail: error.localizedDescription) else { throw CocoaError(.fileWriteUnknown) }
            }
            throw error
        }
        await recordChatDeliveryReceipt(
            msg,
            transport: "icloud_drive",
            status: .queuedForICloudSync,
            secret: secret
        )

        // KVS trigger: notify iOS side that a new file is waiting in Drive
        let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
        _ = await withCKTimeout("iCloudBridge.sendChatMessage.kvsTrigger") {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
            return kvs.synchronize()
        }
        await scheduleDeliveryNudges(for: msg.id)

        noteOutboundToPeer(correlationID: correlationID, metadata: metadata)
        lastSyncAt = Date()
        syncStatus = "Queued for iCloud sync — waiting for iOS"
        return msg
    }

    /// E3: a delivered outbound message settles the drain cadence. Only a
    /// terminal message retires the correlation — a text_delta or progress
    /// frame proves the turn is still running, so it refreshes peer activity
    /// instead of declaring the reply sent.
    private func noteOutboundToPeer(correlationID: String?, metadata: [String: String]?) {
        defer { scheduleNextDeviceDrainFallback() }
        let now = Date()
        guard let correlationID, !correlationID.isEmpty else {
            drainPolicy.notePeerActivity(at: now)
            return
        }
        switch metadata?["kind"] {
        case "text_delta", "progress":
            drainPolicy.notePeerActivity(at: now)
        default:
            drainPolicy.resolve(correlationID, at: now)
        }
    }

    func cloudKitActionResponseMessage(_ response: [String: String], correlationID: String) throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            sender: "mac",
            text: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
            correlationID: correlationID,
            metadata: ["kind": "icloud_action_response"]
        )
        let secret = try PairingSecretManager.loadOrGenerateSecret()
        return try unsigned.signed(with: secret)
    }

    /// Return the existing MacSyncEngine-signed action response over CloudKit.
    /// Trust/dispatch/receipt ownership stays in MacSyncEngine; BridgeMessage
    /// contributes transport HMAC, correlation, ordering, and retry semantics.
    func sendCloudKitActionResponse(
        _ response: [String: String],
        correlationID: String
    ) async throws {
        guard let deviceTransport else {
            throw BridgeError.containerUnavailable
        }
        do {
            let signed = try cloudKitActionResponseMessage(response, correlationID: correlationID)
            try await deviceTransport.send(signed)
            await recordSendResult(operation: "action response \(correlationID)")
            await Self.appendActionResponseDeliveryReceipt(
                response: response,
                correlationID: correlationID,
                transport: "cloudkit",
                status: .acceptedByTransport,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            drainPolicy.resolve(correlationID, at: Date())
            scheduleNextDeviceDrainFallback()
            lastSyncAt = Date()
            syncStatus = "Sent action response via CloudKit"
        } catch {
            // Do not leave a prior green send painted as current health. The
            // durable response remains available to MacSync for a restart-safe
            // resend, but the bridge state must say that this attempt failed.
            syncStatus = "CloudKit action response waiting to resend: \(error.localizedDescription)"
            await recordSendResult(operation: "action response \(correlationID)", error: error)
            throw error
        }
    }

    private func recordChatDeliveryReceipt(
        _ message: BridgeMessage,
        transport: String,
        status: ChatDeliveryReceiptStatus,
        secret: Data,
        direction: String = "mac_to_ios"
    ) async {
        await Self.appendChatDeliveryReceipt(
            message,
            direction: direction,
            transport: transport,
            status: status,
            secret: secret,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    private func scheduleDeliveryNudges(for messageID: String) async {
        let queue: ICloudDeliveryNudgeQueue
        if let deliveryNudgeQueue {
            queue = deliveryNudgeQueue
        } else {
            queue = ICloudDeliveryNudgeQueue(
                isAvailable: { [weak self] in
                    await self?.available ?? false
                },
                sendNudge: { messageID in
                    let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(messageID)"
                    return await withCKTimeout(
                        "iCloudBridge.deliveryNudge.kvsTrigger",
                        seconds: 3
                    ) {
                        let kvs = NSUbiquitousKeyValueStore.default
                        kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                        return kvs.synchronize()
                    } ?? false
                },
                observeOutcome: { [weak self] outcome in
                    await self?.recordDeliveryNudgeOutcome(outcome)
                }
            )
            deliveryNudgeQueue = queue
        }
        await queue.schedule(for: messageID)
    }

    private func recordDeliveryNudgeOutcome(_ outcome: ICloudDeliveryNudgeOutcome) {
        switch outcome.disposition {
        case .synchronized:
            break
        case .unavailable:
            syncStatus = "iCloud delivery nudge skipped: iCloud unavailable"
        case .synchronizeFailed:
            syncStatus = "iCloud delivery nudge failed: iOS will retry on its next sync"
        }
    }

    /// Publish the Mac-owned provider/model catalog to the paired phone without
    /// copying credentials or requiring the legacy iCloud Drive snapshot lane.
    /// The status record is a bounded LWW projection with one publication owner;
    /// the Mac remains the only provider configuration owner.
    @discardableResult
    public func publishProviderCatalogStatus() async -> Bool {
        guard speaksToPhone else { return false }
        providerCatalogPublicationQueued = true
        if let providerCatalogPublicationTask { return await providerCatalogPublicationTask.value }
        let publication = Task { await drainProviderCatalogPublication() }
        providerCatalogPublicationTask = publication
        return await publication.value
    }

    private func drainProviderCatalogPublication() async -> Bool {
        defer { providerCatalogPublicationTask = nil }
        var published = false
        repeat {
            providerCatalogPublicationQueued = false
            published = false
            guard let deviceTransport, speaksToPhone else { return false }
            let generation = setupGeneration
            do {
                let snapshot = try await sync.host.providerCatalogSnapshot()
                guard generation == setupGeneration, speaksToPhone else { continue }
                let catalog = NAProviderCatalogStatus(
                    providers: snapshot.providers,
                    surfaces: Self.providerSurfaceSelections(from: snapshot.routing),
                    routingRevision: snapshot.routing.revision
                )
                let value = try NAProviderCatalogStatusCodec.encode(catalog)
                if value != lastPublishedProviderCatalogStatus {
                    try await deviceTransport.setStatus(key: NAProviderCatalogStatusCodec.statusKey, value: value)
                    guard generation == setupGeneration, speaksToPhone else { continue }
                    lastPublishedProviderCatalogStatus = value
                    // Reread current configuration after every send. Only a
                    // stable projection, or an unqueued failure, ends this owner.
                    providerCatalogPublicationQueued = true
                    await recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey)
                }
                published = true
            } catch {
                guard generation == setupGeneration, speaksToPhone else { continue }
                lastPublishedProviderCatalogStatus = nil
                await recordSendResult(operation: NAProviderCatalogStatusCodec.statusKey, error: error)
                nativeLog("[iCloudBridge] provider catalog publication failed: \(error.localizedDescription)")
            }
        } while providerCatalogPublicationQueued
        return published
    }

    /// A credential-free projection of one frozen routing generation. Never
    /// reread a second picker file while constructing the phone's tuple.
    nonisolated static func providerSurfaceSelections(
        from snapshot: ProviderRoutingSnapshot
    ) -> [String: NAProviderSurfaceSelection] {
        snapshot.preferences.reduce(into: [:]) { surfaces, entry in
            let (surface, preference) = entry
            guard !surface.isEmpty, !preference.model.isEmpty else { return }
            surfaces[surface] = NAProviderSurfaceSelection(
                providerID: snapshot.activeProviders[surface],
                model: preference.model,
                reasoningEffort: preference.reasoningEffort.isEmpty ? nil : preference.reasoningEffort,
                serviceTier: preference.serviceTier
            )
        }
    }

    /// Publish selected rebuildable iOS read projections through the existing
    /// bounded CloudKit status seam. The snapshot writer remains the only
    /// projection compiler; this adapter only transports its exact file bytes.
    /// Returns each group that did not publish, with why; nil when there is no
    /// CloudKit transport or the pass was torn down.
    @discardableResult
    func publishMobileSnapshotStatus(
        groups: Set<NAMobileSnapshotGroup>,
        snapshotDirectory: URL,
        shouldPublish: @MainActor () -> Bool = { true }
    ) async -> [NAMobileSnapshotGroup: DeviceSyncError]? {
        guard let deviceTransport, speaksToPhone, !groups.isEmpty else { return nil }
        var failures: [NAMobileSnapshotGroup: DeviceSyncError] = [:]
        for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
            do {
                guard let value = try await MobileSnapshotBuilder.shared.status(
                    group: group, directory: snapshotDirectory
                ) else { throw DeviceSyncError.underlying(message: "Snapshot \(group.rawValue) is absent; it was not published.") }
                guard shouldPublish() else { return nil }
                if lastPublishedMobileSnapshotStatus[group] == value {
                    continue
                }
                try await deviceTransport.setStatus(
                    key: group.statusKey,
                    value: value
                )
                guard shouldPublish() else { return nil }
                lastPublishedMobileSnapshotStatus[group] = value
                await recordSendResult(operation: group.statusKey)
            } catch {
                guard shouldPublish() else { return nil }
                failures[group] = error as? DeviceSyncError ?? .underlying(message: error.localizedDescription)
                await recordSendResult(operation: group.statusKey, error: error)
                // Forget what was last published for this group: the retained
                // value is what suppresses the next attempt, and this group is
                // now known not to be on the phone as published.
                lastPublishedMobileSnapshotStatus[group] = nil
                nativeLog(
                    "[iCloudBridge] mobile snapshot %@ publication failed: %@",
                    group.rawValue,
                    error.localizedDescription
                )
            }
        }
        return failures
    }

    enum MacPresencePublication {
        case published, ineligible, failed
    }

    /// Eligibility is distinct from failure of an eligible publication attempt.
    func publishMacPresence() async -> MacPresencePublication {
        guard let deviceTransport, speaksToPhone else { return .ineligible }
        let generation = setupGeneration
        do {
            guard let encoded = try PairingSecretManager.existingSecretBase64(),
                  let secret = Data(base64Encoded: encoded) else { return .failed }
            try await deviceTransport.setPresence(pairingSecret: secret)
            guard isSetUp, generation == setupGeneration else { return .ineligible }
            await recordSendResult(operation: "presence")
            return .published
        } catch {
            guard isSetUp, generation == setupGeneration else { return .ineligible }
            await recordSendResult(operation: "presence", error: error)
            nativeLog("[iCloudBridge] presence beat failed: %@", error.localizedDescription)
            return .failed
        }
    }

    @discardableResult
    public func sendKVSChatProgress(
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String],
        key: String = NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest,
        mirrorKey: String? = nil
    ) async -> Bool {
        let msg: BridgeMessage
        let mirror: BridgeMessage?
        do {
            (msg, mirror) = try await sync.storage.perform {
                let secret = try PairingSecretManager.loadOrGenerateSecret()
                let msg = try Self.makeKVSChatProgressMessage(text: text, sessionID: sessionID,
                    correlationID: correlationID, metadata: metadata, secret: secret)
                var mirror: BridgeMessage?
                if let mirrorKey, mirrorKey != key {
                    // Old phones admit only progress; both copies retain the same id.
                    var mirrorMetadata = metadata
                    mirrorMetadata["kind"] = "progress"
                    mirror = try Self.makeKVSChatProgressMessage(id: msg.id, text: text, sessionID: sessionID,
                        correlationID: correlationID, metadata: mirrorMetadata, secret: secret)
                }
                return (msg, mirror)
            }
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] failed to sign KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let data: Data
        let mirrorData: Data?
        do {
            (data, mirrorData) = try await sync.storage.perform {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (try encoder.encode(msg), try mirror.map { try encoder.encode($0) })
            }
        } catch {
            nativeLog("[iCloudBridge] failed to encode KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let delivery: ICloudKVSProgressDeliveryResult = await withCKTimeout(
            "iCloudBridge.sendKVSChatProgress",
            seconds: 3
        ) { () -> ICloudKVSProgressDeliveryResult in
            let kvs = NSUbiquitousKeyValueStore.default
            var existingKeys = Set(kvs.dictionaryRepresentation.keys)
            let admission = ICloudKVSProgressWriteAdmission.assess(
                keys: existingKeys,
                progressKey: key
            )
            guard admission.isAllowed else { return .blocked(admission) }
            // 2026-09-06: the mirror carries the same message id, so a phone
            // that reads both keys drops the second copy, while a phone that
            // only knows the old key still receives the event.
            if let mirrorKey, let mirrorData, mirrorKey != key {
                // 2026-09-06: the mirror is admitted against the keyspace AS
                // IT WILL BE once the primary key is written. Assessing both
                // from one pre-write snapshot admitted two NEW keys at 959 and
                // pushed the store past its own 960 ceiling, after which every
                // later progress overwrite was rejected outright.
                existingKeys.insert(key)
                let mirrorAdmission = ICloudKVSProgressWriteAdmission.assess(
                    keys: existingKeys,
                    progressKey: mirrorKey
                )
                guard mirrorAdmission.isAllowed else { return .blocked(mirrorAdmission) }
                kvs.set(mirrorData, forKey: mirrorKey)
            }
            kvs.set(data, forKey: key)
            return kvs.synchronize() ? .synchronized : .synchronizeFailed
        } ?? .timedOut

        switch delivery {
        case .synchronized:
            lastSyncAt = Date()
            syncStatus = "Progress sent via iCloud KVS"
            return true
        case .blocked(let admission):
            let snapshot = admission.snapshot
            let detail = admission.failureDescription ?? "KVS keyspace unavailable"
            syncStatus = "iCloud KVS progress blocked: \(detail)"
            nativeLog(
                "[iCloudBridge] KVS progress blocked msg=%@ totalKeys=%d responseKeys=%d: %@",
                correlationID,
                snapshot.totalKeyCount,
                snapshot.inboxResponseKeyCount,
                detail
            )
        case .synchronizeFailed, .timedOut:
            syncStatus = delivery == .timedOut
                ? "iCloud KVS progress timed out"
                : "iCloud KVS progress sync failed"
            nativeLog("[iCloudBridge] KVS progress sync did not complete msg=%@", correlationID)
        }
        return false
    }

    nonisolated static func makeKVSChatProgressMessage(
        id: String = UUID().uuidString,
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String],
        secret: Data
    ) throws -> BridgeMessage {
        var compactMetadata = metadata.mapValues { String($0.prefix(240)) }
        compactMetadata["ephemeral"] = "true"
        compactMetadata["transport"] = compactMetadata["transport"] ?? "icloud"
        compactMetadata["source"] = compactMetadata["source"] ?? "mac"

        let unsigned = BridgeMessage.make(
            id: id,
            sender: "mac",
            text: String(text.prefix(240)),
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: compactMetadata
        )
        return try unsigned.signed(with: secret)
    }

    // MARK: - Observe incoming messages from iOS (Drive)

    public func observeIncomingMessages(onMessage: @escaping (BridgeMessage) async -> Bool) {
        // N-dedup fix: replace rather than append. A teardown→setup retry (or any
        // second call) previously stacked handlers, so each iOS message was
        // forwarded to the daemon once PER accumulated handler → duplicate turns.
        // There is exactly one logical forwarder, so idempotent single-slot
        // registration is correct.
        messageHandlers = [onMessage]
        // Keep the transport callback bound to this bridge as well as draining
        // records that arrived before the app-side forwarder. The production
        // setup path already installs this same callback, but registering here
        // is idempotent (the transport is last-registration-wins) and prevents
        // a late/recovered observer from becoming a green bridge with no route.
        if let ck = deviceTransport {
            registerIncomingTransportObserver(ck)
            return
        }
        checkIosOutbox()
    }

    private func acceptsIncomingObserver(generation: UInt64) -> Bool {
        isSetUp && generation == incomingObserverGeneration && deviceTransport != nil
    }

    private func registerIncomingTransportObserver(_ transport: DeviceSyncTransport) {
        incomingObserverGeneration &+= 1
        incomingObserverInstalled = false
        let observerGeneration = incomingObserverGeneration
        let previous = incomingObserverTask
        previous?.cancel()
        let taskID = UUID()
        incomingObserverTaskID = taskID
        (transport as? CloudKitDeviceTransport)?.setControlAdmission { [weak self] message in
            guard let self else { return false }
            return await self.admitsPhoneControl(message, generation: observerGeneration)
        }
        incomingObserverTask = Task { [weak self] in
            defer {
                if self?.incomingObserverTaskID == taskID { self?.incomingObserverTask = nil }
            }
            // Subscription registration is last-writer-wins. Retire the old
            // registration before installing its replacement, even across await.
            await previous?.value
            guard !Task.isCancelled, let self,
                  self.acceptsIncomingObserver(generation: observerGeneration) else { return }
            let subscriptionsReady = await transport.observeIncoming { [weak self] message in
                guard let self,
                      await self.acceptsIncomingObserver(generation: observerGeneration)
                else { return false }
                let handled = await self.handleIncomingFromTransport(message, observerGeneration: observerGeneration)
                guard handled, message.metadata?["kind"] == PhonePlaceEvent.messageKind
                    || message.metadata?["kind"] == PhoneRequestResult.messageKind else { return handled }
                guard message.sender == "ios", let encoded = try? PairingSecretManager.existingSecretBase64(),
                      let secret = Data(base64Encoded: encoded), message.verifySignature(secret: secret) else { return handled }
                // These deliveries have no answer of their own. Use the same
                // signed progress channel as chat acceptance, durably over CK.
                return (try? await self.sendChatMessage(text: "Mac received it", sessionID: message.sessionID,
                    correlationID: message.id, metadata: ["kind": "progress", "stage": "received"])) != nil
            }
            guard !Task.isCancelled, self.acceptsIncomingObserver(generation: observerGeneration)
            else { return }
            if !subscriptionsReady { self.recordCloudKitPushUnavailable() }
            self.incomingObserverInstalled = true
            if self.deviceDrainInFlight {
                self.deviceDrainQueued = true
            } else {
                _ = self.startDeviceDrain(transport, trigger: .coalesced)
            }
        }
    }

    private func admitsPhoneControl(_ message: BridgeMessage, generation: UInt64) async -> Bool {
        guard acceptsIncomingObserver(generation: generation) else { return false }
        let admitted = await incomingVerifier.admitsControl(message)
        return admitted && acceptsIncomingObserver(generation: generation)
    }

    nonisolated static func isAuthenticatedControlAction(_ message: BridgeMessage, secret: Data) -> Bool {
        guard case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: secret, now: Date()),
              message.metadata?["kind"] == "icloud_action",
              let data = message.text.data(using: .utf8),
              let action = try? JSONDecoder().decode(InboxAction.self, from: data),
              ["cancelChat", "steerChat"].contains(action.action),
              let ids = InboxActionFileBoundary.validatedIDs(for: action),
              ids.messageID == message.metadata?["actionId"],
              let signature = action.signature
        else { return false }
        return BridgeMessage.innerActionSignatureError(data: data, signature: signature, secret: { secret }) == nil
    }

    /// CK-3b: validate + forward a message pulled from the CloudKit transport,
    /// mirroring `scanIosOutboxFiles`' checks. Returns true when the message is
    /// HANDLED (delivered OR permanently rejected) so the transport advances its
    /// cursor; false only when transiently undeliverable (runtime unavailable) so
    /// the transport re-delivers next drain (the halt-on-undelivered contract).
    @MainActor
    func handleIncomingFromTransport(_ msg: BridgeMessage, observerGeneration: UInt64? = nil) async -> Bool {
        // A shared HMAC key proves pairing, not direction. Reject before the
        // ID cache or action dispatcher can claim an attacker-selected ID.
        guard msg.sender == "ios" else {
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = "Rejected iPhone message (CloudKit): sender_invalid"
            return true
        }
        // Already handled (persistent seen-set; the transport also dedups by id).
        if seenMessageIDs.contains(msg.id) { return true }
        let disposition: ICloudIncomingMessageDisposition
        let secret: Data
        do {
            (disposition, secret) = try await incomingVerifier.classify(msg)
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] deferring iOS→Mac CK msg %@: %@", msg.id, error.localizedDescription)
            return false
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        if disposition == .permanentlyRejected(reason: "signature_invalid") {
            // A phone that now signs with another Mac's key was moved there:
            // its messages are that Mac's, not an attack on this one.
            if !phonePairedElsewhere { await claimPhonePairing() }
            if phonePairedElsewhere { return true }
            // The phone's clock, like contact: an old-key message sent before
            // newer accepted ones is not the latest word.
            let rejectedAt = min(msg.timestamp, Date())
            if rejectedAt > (lastPhoneRejectedAt ?? .distantPast) { lastPhoneRejectedAt = rejectedAt }
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            syncStatus = "Rejected iPhone message (CloudKit): signature_invalid"
            return true
        }
        // Authentication suspended; a concurrent cancellation may have completed.
        if seenMessageIDs.contains(msg.id) { return true }
        if !deviceDrainTriggeredByPush, let proof = cloudKitPushProofAt,
           msg.timestamp > proof, Date().timeIntervalSince(msg.timestamp) > 16 {
            recordCloudKitPushEvidence(received: false)
            scheduleNextDeviceDrainFallback()
        }
        switch disposition {
        case .permanentlyRejected(let reason):
            if reason == "stale_timestamp" {
                if msg.metadata?["kind"] != PhonePlaceEvent.messageKind,
                   msg.metadata?["kind"] != PhoneRequestResult.messageKind {
                    // Chat and action ledgers may already own this expired request.
                    break
                }
                guard await sendIncomingRejection(msg, reason: Date() > msg.timestamp ? "request_expired" : "clock_ahead") else { return false }
            }
            nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, reason)
            // Do not reserve the rejected envelope's caller-selected ID:
            // a fresh authenticated envelope may reuse it.
            syncStatus = "Rejected iPhone message (CloudKit): \(reason)"
            return true  // permanently rejected: consume, never wedge transport
        case .deliver:
            break
        }
        // Every signed message is the phone's contact, its answers to our
        // requests included: a phone that just answered is not silent.
        drainPolicy.notePeerActivity(at: Date())
        scheduleNextDeviceDrainFallback()
        do {
            try await SignedPeerEvidenceStore.record(
                eventID: msg.id,
                channel: .chat,
                peerCreatedAt: msg.timestamp,
                dataRoot: PersistenceCore.defaultDataRoot()
            )
            if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
            notePhoneContact(at: msg.timestamp)
        } catch {
            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                  msg.id, error.localizedDescription)
        }
        if let observerGeneration, !acceptsIncomingObserver(generation: observerGeneration) { return false }
        if msg.metadata?["kind"] == PhonePlaceEvent.messageKind {
            guard let event = try? JSONDecoder().decode(PhonePlaceEvent.self, from: Data(msg.text.utf8)),
                  event.id == msg.id, event.isValid else {
                nativeLog("[iCloudBridge] dropping iOS→Mac CK msg %@: %@", msg.id, "invalid_place_event")
                return true
            }
            do {
                try PhonePlaceHistory.record(event, dataRoot: PersistenceCore.defaultDataRoot())
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                return true
            } catch {
                syncStatus = "iPhone place event could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        if msg.metadata?["kind"] == PhoneRequestResult.messageKind {
            phoneRequests.receive(msg)
            recordSeenMessageID(msg.id)
            persistCKSeenIDs()
            return true
        }
        if msg.metadata?["kind"] == "icloud_action" {
            let correlation = msg.metadata?["actionId"] ?? msg.id
            drainPolicy.noteOutstanding(correlation, at: Date())
            scheduleNextDeviceDrainFallback()
            defer {
                drainPolicy.resolve(correlation, at: Date())
                scheduleNextDeviceDrainFallback()
            }
            let handled = await sync.engine.processCloudKitActionMessage(msg)
            if handled {
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                lastSyncAt = Date()
                syncStatus = "Processed iPhone action (CloudKit)"
            }
            return handled
        }
        activeCloudKitChats += 1
        defer {
            activeCloudKitChats -= 1
            scheduleNextDeviceDrainFallback()
        }
        drainPolicy.notePeerActivity(at: Date())
        scheduleNextDeviceDrainFallback()
        let delivery = await deliverIncomingChat(msg)
        if delivery != .deferred {
            if delivery == .delivered {
                await Self.appendInboundSuccessReceipt(
                    msg,
                    transport: "cloudkit",
                    secret: secret,
                    dataRoot: PersistenceCore.defaultDataRoot()
                )
            }
            if delivery != .rejected { recordSeenMessageID(msg.id) }
            // CK-3c: persist the CK-consumed id so a restart within the cursor's
            // 30s clock-skew re-pull window doesn't re-deliver it (gpt-5.5 CK-3c
            // review P1). Synchronous UserDefaults (ordered on the main actor,
            // atomic) — NOT a detached file write, which could reorder two rapid
            // saves or not flush before exit. Mirrors the iOS bridge's approach;
            // merged back into the seen-set on setup. Only the DELIVERED branch
            // needs it (a re-dropped bad-sig/stale is harmless).
            if delivery != .rejected { persistCKSeenIDs() }
            lastSyncAt = Date()
            syncStatus = "Processed iPhone request (CloudKit)"
            return true
        }
        markMacRuntimeUnavailable()
        return false  // transient — retry next drain
    }

    private func sendIncomingRejection(_ message: BridgeMessage, reason: String) async -> Bool {
        let text: String
        switch reason {
        case "request_expired":
            text = "Your Mac received this after its request window expired. It wasn't started."
        case "clock_ahead":
            text = "iPhone message rejected: its timestamp is in the future. Check both devices' clocks and try again."
        case "message_id_collision":
            text = "This message ID already belongs to a different request. This request wasn't started."
        default:
            text = "Couldn't finish the reply."
        }
        do {
            let isOutcomeError = reason == "unknown_outcome" || reason == "message_id_collision"
            _ = try await sendChatMessage(text: text, sessionID: message.sessionID, correlationID: message.id,
                                          metadata: ["kind": isOutcomeError ? "error" : "rejection", "reason": reason,
                                                     "errorDetail": text,
                                                     "targetSourceKey": message.metadata?["routeKey"]
                                                        ?? message.metadata?["deviceSourceKey"]
                                                        ?? message.metadata?["sourceKey"] ?? ""])
            return true
        } catch {
            syncStatus = "iPhone response could not be sent — retaining request for retry"
            return false
        }
    }

    private enum IncomingChatDelivery { case delivered, handled, rejected, deferred }

    private func deliverIncomingChat(_ message: BridgeMessage) async -> IncomingChatDelivery {
        guard isSetUp, !inFlightIncomingMessageIDs.contains(message.id) else { return .deferred }
        let generation = setupGeneration
        inFlightIncomingMessageIDs.insert(message.id)
        defer {
            inFlightIncomingMessageIDs.remove(message.id)
            if generation == setupGeneration, isSetUp {
                drainPolicy.resolve(message.id, at: Date())
                scheduleNextDeviceDrainFallback()
            }
        }
        let dataRoot = PersistenceCore.defaultDataRoot()
        let reservation = await Self.reserveChat(message, dataRoot: dataRoot, canDispatch: !messageHandlers.isEmpty)
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        switch reservation {
        case .completed:
            return .handled
        case .collision:
            return await sendIncomingRejection(message, reason: "message_id_collision") ? .rejected : .deferred
        case .stale:
            return await sendIncomingRejection(message, reason: Date() > message.timestamp ? "request_expired" : "clock_ahead") ? .rejected : .deferred
        case .unavailable:
            syncStatus = "iPhone request record unavailable — retaining request for retry"
            return .deferred
        case .interrupted:
            if let resent = await resendSavedReply(message, dataRoot: dataRoot) { return resent ? .handled : .deferred }
            // The checkpoint owns unfinished work; the reservation owns its saved answer.
            do {
                let record = try Self.readChat(message.id, dataRoot: dataRoot)
                let session = record.assistantSessionId ?? message.sessionID
                guard let session else { return .deferred }
                let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: message.id)
                if response == nil, try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: message.id) {
                    return .deferred
                }
                guard try await recoverReply(response ?? ChatResponse(runId: message.id, model: "",
                    output: "Couldn't finish the reply.", sessionId: session, terminalState: .failed),
                    route: AgentBridgeCompletionRoute(surface: "ios", sessionId: session,
                        sourceKey: message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"],
                        replyTo: message.metadata?["clientSurface"], correlationId: message.id)) != "owed" else { return .deferred }
                if response == nil {
                    try await Self.settleReply(message.id, session: session, sourceKey: message.metadata?["routeKey"] ?? message.metadata?["deviceSourceKey"] ?? message.metadata?["sourceKey"] ?? "",
                        state: "failed_before_answer", dataRoot: dataRoot)
                    StoreChangeBus.shared.emit(StoreChange(store: .replyDelivery, path: Self.chatURL(message.id, dataRoot: dataRoot)))
                }
                return .handled
            } catch { return .deferred }
        case .unreadable:
            // Unknown authority stays byte-preserved and never authorizes dispatch.
            return await sendIncomingRejection(message, reason: "unknown_outcome") ? .handled : .deferred
        case .reserved:
            break
        }
        drainPolicy.noteOutstanding(message.id, at: Date())
        scheduleNextDeviceDrainFallback()
        if let resent = await resendSavedReply(message, dataRoot: dataRoot) { return resent ? .handled : .deferred }
        guard isSetUp, generation == setupGeneration else {
            await Self.releaseUndispatchedChat(reservation)
            return .deferred
        }
        var delivered = false
        for handler in messageHandlers {
            // No suspension separates the pre-dispatch check from the first
            // handler. After entry, retirement must keep its outcome record.
            guard isSetUp, generation == setupGeneration else { return .deferred }
            if await handler(message) { delivered = true }
        }
        if !delivered {
            guard await sendIncomingRejection(message, reason: "unknown_outcome") else { return .deferred }
        }
        guard await Self.finishChat(message, dataRoot: dataRoot, completed: delivered) else { return .deferred }
        return delivered ? .delivered : .handled
    }

    private func markMacRuntimeUnavailable() {
        syncStatus = "iPhone message waiting — Mac runtime unavailable"
    }

    /// CK-3c: drain the CloudKit transport (incoming + pairing + status) if it is
    /// active; no-op when nil (flag-off). Single-flight — overlapping triggers
    /// (poll timer, initial observe, future push) coalesce into at most one queued
    /// re-run, so they don't fire redundant CloudKit round-trips. Per-message
    /// delivery is already atomic in the transport (claimIfUnseen), so this is an
    /// efficiency guard, not a correctness one. Returns true if any incoming
    /// message was dispatched.
    @discardableResult
    public func repairReceive() async {
        _ = await drainDeviceTransport(trigger: .repair)
    }

    private func drainDeviceTransport(trigger: DrainTrigger) async -> Bool {
        guard isSetUp, let ck = deviceTransport else { return false }
        if deviceDrainInFlight {
            Self.pushLog.info("Drain coalesced trigger=\(trigger.rawValue, privacy: .public)")
            deviceDrainQueued = true
            guard deviceDrainGeneration == setupGeneration else { return false }
            lastDeviceDrainAt = Date()
            defer { scheduleNextDeviceDrainFallback() }
            let dispatched = await (ck as? CloudKitDeviceTransport)?.drainIncomingControls() ?? 0
            Self.pushLog.info("Cancellation drain trigger=\(trigger.rawValue, privacy: .public) dispatched=\(dispatched)")
            return dispatched > 0
        }
        return await startDeviceDrain(ck, trigger: trigger).value
    }

    /// The receive timer owns its sleep; this handle owns the drain and any
    /// accepted human turn it awaits. Teardown cannot release its exclusion.
    private func startDeviceDrain(_ ck: DeviceSyncTransport, trigger: DrainTrigger) -> Task<Bool, Never> {
        let generation = setupGeneration
        deviceDrainGeneration = generation
        lastDeviceDrainAt = Date()
        deviceDrainInFlight = true
        deviceDrainTriggeredByPush = trigger == .cloudKitPush
        let task = Task {
            defer {
                deviceDrainInFlight = false
                deviceDrainTriggeredByPush = false
                deviceDrainTask = nil
                deviceDrainGeneration = nil
                if isSetUp, deviceDrainQueued, let current = deviceTransport {
                    deviceDrainQueued = false
                    _ = startDeviceDrain(current, trigger: .coalesced)
                } else {
                    scheduleNextDeviceDrainFallback()
                }
                if isSetUp, generation == setupGeneration {
                    startDeviceRetentionSweepIfIdle(ck)
                }
            }
            return await runDeviceDrain(ck, trigger: trigger, generation: generation)
        }
        deviceDrainTask = task
        return task
    }

    private func runDeviceDrain(_ ck: DeviceSyncTransport, trigger: DrainTrigger, generation: Int) async -> Bool {
        guard isSetUp, generation == setupGeneration else { return false }
        Self.pushLog.info("Drain started trigger=\(trigger.rawValue, privacy: .public)")
        // Keep missed-push recovery alive even when the stream emits no deltas.
        scheduleNextDeviceDrainFallback()
        // An unsettled claim, or a key change iCloud has not taken yet, is
        // retried on the drain's own cadence until it lands.
        if !phonePairingSettled || UserDefaults.standard.bool(forKey: pairingPublicationOwedKey) {
            await claimPhonePairing()
        }
        guard isSetUp, generation == setupGeneration else { return false }
        let accountGeneration = accountFailureGeneration
        let doctorGeneration = setupGeneration
        let result = await ck.drainIncoming()
        guard isSetUp, generation == setupGeneration else { return false }
        // The claim may have found another Mac while this drain was reading.
        guard !phonePairedElsewhere else { return false }
        if doctorGeneration == setupGeneration {
            switch result {
            case .success(let count):
                doctorTransportHealth = .available
                onTransportSucceeded?()
                let note = ["\(count) drained", devicePollingNote].filter { !$0.isEmpty }.joined(separator: "; ")
                OrganPulse.record("icloud_drain", found: count, note: note, cadence: deviceReceiveCadence)
            case .skipped: OrganPulse.record("icloud_drain", .skipped, note: devicePollingNote, cadence: deviceReceiveCadence)
            // No pulse: a drain that keeps failing goes overdue.
            case .failure(let error, _): doctorTransportHealth = Self.transportHealth(error)
            }
        }
        Self.pushLog.info("Incoming drain completed trigger=\(trigger.rawValue, privacy: .public) dispatched=\(result.dispatchedCount)")
        if case .failure(.account(let failure), _) = result {
            await recordAccountFailure(failure)
        }
        guard isSetUp, generation == setupGeneration else { return false }
        await ck.drainPairing()
        guard isSetUp, generation == setupGeneration else { return false }
        await ck.drainStatus()
        guard isSetUp, generation == setupGeneration else { return false }
        if case .success = result, accountGeneration == accountFailureGeneration {
            await clearAccountFailure()
        }
        return result.dispatchedCount > 0
    }

    private func recordAccountFailure(_ failure: DeviceSyncAccountFailure) async {
        accountFailureGeneration &+= 1
        let changed = accountFailure != failure
        accountFailure = failure
        syncStatus = DeviceSyncAccountFailure.macMessage
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        await sync.storage.perform {
            guard changed || !FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(failure).write(to: url, options: .atomic)
            } catch { nativeLog("[iCloudBridge] could not persist account failure: %@", error.localizedDescription) }
        }
    }

    private func clearAccountFailure() async {
        accountFailureGeneration &+= 1
        let generation = accountFailureGeneration
        let url = ICloudSyncStatePaths.accountFailure(dataRoot: sync.dataRoot)
        let cleared = await sync.storage.perform {
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch {
                    nativeLog("[iCloudBridge] could not clear account failure: %@", error.localizedDescription)
                    return false
                }
            }
            return true
        }
        guard cleared, generation == accountFailureGeneration, accountFailure != nil else { return }
        accountFailure = nil
        syncStatus = "CloudKit account fault cleared"
    }

    /// 2026-09-06: the Mac is the retention owner for the shared CloudKit
    /// records — it is the always-on device, and the phone never deletes. The
    /// sweep used to run INSIDE the drain's single-flight window, where its
    /// CloudKit round-trips (a 10 s query plus a 15 s delete, per record type)
    /// held off the next drain by up to 50 s in the worst timeout sequence and
    /// delayed message delivery by that much. It is housekeeping: it gets its
    /// own single-flight slot at low priority, and no drain ever waits on it.
    /// The transport still self-throttles (hourly) and bounds each run.
    private func startDeviceRetentionSweepIfIdle(_ ck: DeviceSyncTransport) {
        guard isSetUp, !deviceRetentionSweepInFlight else { return }
        deviceRetentionSweepInFlight = true
        deviceRetentionSweepTask = Task(priority: .utility) { [weak self] in
            await ck.sweepExpiredRecords()
            self?.deviceRetentionSweepInFlight = false
            self?.deviceRetentionSweepTask = nil
        }
    }

    // MARK: - Poll / flush iOS outbox (called by metadata query or on-demand)

    func checkIosOutbox() {
        guard isSetUp, let docsURL = driveURL else { return }
        guard !messageHandlers.isEmpty else {
            syncStatus = "iPhone message waiting — starting Mac receiver"
            return
        }
        if outboxScanInFlight {
            outboxScanQueued = true
            return
        }
        let seenSnapshot = seenMessageIDs
        let inFlightSnapshot = inFlightIncomingMessageIDs
        let secret: Data
        do {
            secret = try PairingSecretManager.loadOrGenerateSecret()
        } catch {
            syncStatus = "iPhone pairing unavailable — repair the Mac pairing key"
            nativeLog("[iCloudBridge] pairing authority unavailable during Drive scan: %@", error.localizedDescription)
            return
        }
        outboxScanInFlight = true
        outboxScanGeneration &+= 1
        let scanGeneration = outboxScanGeneration
        let lifecycle = setupGeneration
        outboxScanTask = Task.detached(priority: .utility) { [docsURL, seenSnapshot, inFlightSnapshot, secret] in
            let scan = Self.scanIosOutboxFiles(
                docsURL: docsURL,
                seenMessageIDs: seenSnapshot,
                inFlightMessageIDs: inFlightSnapshot,
                secret: secret
            )
            await MainActor.run {
                self.outboxScanInFlight = false
                self.outboxScanTask = nil
                defer {
                    if self.outboxScanQueued, self.isSetUp {
                        self.outboxScanQueued = false
                        self.checkIosOutbox()
                    }
                }
                guard !Task.isCancelled, self.isSetUp, self.outboxScanGeneration == scanGeneration,
                      lifecycle == self.setupGeneration else { return }
                for id in scan.seenIDs {
                    self.recordSeenMessageID(id)
                }
                let idsSnapshot = self.seenMessageIDsOrdered
                if !scan.messages.isEmpty {
                    self.lastSyncAt = Date()
                    self.syncStatus = "Received message from iOS"
                }
                // fix-2026-06-10 sync-audit #3: process backlogged messages
                // SEQUENTIALLY in arrival order. The previous per-message
                // unstructured Task ran the whole backlog concurrently, and
                // forwardToSwiftRuntime's registerActiveChatTask cancels any
                // existing task per sessionID — so two same-session messages
                // queued offline cancelled each other mid-stream. The cancel
                // semantics (new LIVE message supersedes) are unchanged; the
                // backlog just no longer races itself.
                // Claim each id AS ITS TURN STARTS, not up front (gpt-5.5
                // review: an up-front claim strands every later message as
                // permanently in-flight if one handler hangs — defers never
                // run on a hang). With per-start claiming, a hung item leaves
                // the REST unclaimed for the next scan, and a later same-
                // session message unwedges the hang via the supersede-cancel.
                // Check-then-insert runs with no await in between (MainActor),
                // so duplicate ids within or across scans dispatch only once.
                // Explicit control messages must not wait behind a streaming turn.
                let handoffs = scan.messages.filter { UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let ordinary = scan.messages.filter { !UserMessageIntentSignals.isControlHandoff($0.message.text) }
                let backlog = handoffs + ordinary
                let backlogID = UUID()
                self.outboxBacklogTasks[backlogID] = Task { @MainActor in
                    defer { self.outboxBacklogTasks.removeValue(forKey: backlogID) }
                    if !scan.seenIDs.isEmpty {
                        await Task.detached(priority: .utility) {
                            Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
                        }.value
                    }
                    for pending in backlog {
                        guard self.isSetUp, lifecycle == self.setupGeneration else { return }
                        guard !self.seenMessageIDs.contains(pending.message.id),
                              !self.inFlightIncomingMessageIDs.contains(pending.message.id) else { continue }
                        do {
                            try await SignedPeerEvidenceStore.record(
                                eventID: pending.message.id,
                                channel: .chat,
                                peerCreatedAt: pending.message.timestamp,
                                dataRoot: PersistenceCore.defaultDataRoot()
                            )
                            if self.isSetUp, lifecycle == self.setupGeneration {
                                self.notePhoneContact(at: pending.message.timestamp)
                            }
                        } catch {
                            nativeLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                                  pending.message.id, error.localizedDescription)
                        }
                        guard self.isSetUp, lifecycle == self.setupGeneration else { return }
                        let delivery = await self.deliverIncomingChat(pending.message)
                        if delivery != .deferred {
                            if delivery == .delivered {
                                await Self.appendInboundSuccessReceipt(
                                    pending.message,
                                    transport: "icloud_drive",
                                    secret: secret,
                                    dataRoot: PersistenceCore.defaultDataRoot()
                                )
                            }
                            await self.markIosMessageProcessed(pending, docsURL: docsURL, recordIdentity: delivery != .rejected)
                        } else if self.isSetUp, lifecycle == self.setupGeneration {
                            self.markMacRuntimeUnavailable()
                        }
                    }
                }
            }
        }
    }

    struct PendingOutboxMessage: Sendable {
        var message: BridgeMessage
        var fileURL: URL
    }

    nonisolated static func processedMessageIDsURL(docsURL: URL) -> URL {
        docsURL
            .appendingPathComponent(DriveFolder.processed)
            .appendingPathComponent("ios_chat_processed_ids.json")
    }

    // fix-2026-06-10 sync-audit #2: load/save the ORDERED id array (oldest →
    // newest) so eviction is insertion-ordered, not the old lexicographic
    // .sorted().suffix() which evicted age-randomly.
    nonisolated static func loadProcessedMessageIDs(docsURL: URL) -> [String] {
        let url = processedMessageIDsURL(docsURL: docsURL)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    nonisolated static func saveProcessedMessageIDs(_ ids: [String], docsURL: URL) {
        let url = processedMessageIDsURL(docsURL: docsURL)
        let capped = Array(ids.suffix(seenMessageIDsCap))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func markIosMessageProcessed(_ pending: PendingOutboxMessage, docsURL: URL, recordIdentity: Bool) async {
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        if recordIdentity { recordSeenMessageID(pending.message.id) }
        let dest = processedDir.appendingPathComponent(pending.fileURL.lastPathComponent)
        let idsSnapshot = seenMessageIDsOrdered
        let sourceURL = pending.fileURL
        await Task.detached(priority: .utility) { [idsSnapshot, docsURL, dest, sourceURL] in
            Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.moveItem(at: sourceURL, to: dest)
        }.value
        lastSyncAt = Date()
        syncStatus = "iPhone request processed"
    }

    nonisolated static func scanIosOutboxFiles(
        docsURL: URL,
        seenMessageIDs: Set<String>,
        inFlightMessageIDs: Set<String>,
        secret: Data
    ) -> (messages: [PendingOutboxMessage], seenIDs: [String]) {
        let iosOutbox = docsURL.appendingPathComponent(DriveFolder.outboxIos)
        let processingDir = docsURL.appendingPathComponent(DriveFolder.processing)
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        let fm = FileManager.default
        var messages: [PendingOutboxMessage] = []
        var seenIDs: [String] = []

        try? fm.startDownloadingUbiquitousItem(at: iosOutbox)
        try? fm.createDirectory(at: processingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: processedDir, withIntermediateDirectories: true)

        let outboxFiles = (try? fm.contentsOfDirectory(
            at: iosOutbox, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        let processingFiles = (try? fm.contentsOfDirectory(
            at: processingDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let jsonFiles = (outboxFiles + processingFiles).filter { $0.pathExtension == "json" }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }

        for fileURL in jsonFiles {
            var currentURL = fileURL
            if fileURL.deletingLastPathComponent().lastPathComponent != "processing" {
                let claimed = processingDir.appendingPathComponent(fileURL.lastPathComponent)
                if fm.fileExists(atPath: claimed.path) {
                    try? fm.removeItem(at: claimed)
                }
                do {
                    try fm.moveItem(at: fileURL, to: claimed)
                    currentURL = claimed
                } catch {
                    continue
                }
            }
            guard let data = try? Data(contentsOf: currentURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let msg = try? decoder.decode(BridgeMessage.self, from: data) else {
                let dest = processedDir.appendingPathComponent("malformed_\(currentURL.lastPathComponent).done")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }
            // A metadata-query rescan can see the file while its first handler
            // is still awaiting the model. Leave it claimed in `processing` so
            // a transient handler failure remains retryable. Treating in-flight
            // as already-seen used to move it to duplicate_*.done and could drop
            // that retry permanently.
            if inFlightMessageIDs.contains(msg.id) {
                continue
            }
            if seenMessageIDs.contains(msg.id) || seenIDs.contains(msg.id) {
                let dest = processedDir.appendingPathComponent("duplicate_\(currentURL.lastPathComponent).done")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }

            // The shared pairing key authenticates both directions. A signed
            // Mac reply copied into this directory is not iPhone input.
            guard msg.sender == "ios" else {
                nativeLog("[iCloudBridge] dropping wrong-direction iOS outbox message %@", msg.id)
                let dest = processedDir.appendingPathComponent("rejected_sender_\(currentURL.lastPathComponent).done")
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }

            // Require HMAC on chat as well as action sync. Without this, a file
            // dropped into iCloud Drive could bypass the signed action channel
            // and still reach the Mac chat runtime.
            if msg.signature == nil || !msg.verifySignature(secret: secret) {
                // Unauthenticated identity never earns an accepted ID or a
                // signed response. Preserve the exact bytes under their digest.
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let dest = processedDir.appendingPathComponent("rejected_signature_\(digest).done")
                do {
                    try data.write(to: dest, options: .atomic)
                    try fm.removeItem(at: currentURL)
                } catch {
                    nativeLog("[iCloudBridge] signature quarantine unavailable: %@", error.localizedDescription)
                }
                continue
            }
            messages.append(PendingOutboxMessage(message: msg, fileURL: currentURL))
        }
        messages.sort {
            if $0.message.timestamp != $1.message.timestamp {
                return $0.message.timestamp < $1.message.timestamp
            }
            return $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent
        }
        return (messages, seenIDs)
    }

    // MARK: - NSMetadataQuery (watches iOS outbox for new iCloud files)

    private func startMetadataQuery(docsURL: URL) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            docsURL.appendingPathComponent(DriveFolder.outboxIos).path
        )
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery = q

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )
        q.start()
    }

    // 2026-05-09: NotificationCenter posts these on whatever queue the
    // poster used (NSMetadataQuery: private worker queue; KVS daemon:
    // com.apple.kvs.client.callback).  iCloudBridge is @MainActor, so
    // calling self.* from a non-main queue trips the Swift executor
    // assertion (SIGTRAP/EXC_BREAKPOINT).  Mark the @objc selectors
    // nonisolated and hop to MainActor inside.
    @objc private nonisolated func metadataQueryDidUpdate(_ note: Notification) {
        let queryID = note.object.map { ObjectIdentifier($0 as AnyObject) }
        Task { @MainActor in
            guard self.isSetUp, let query = self.metadataQuery,
                  ObjectIdentifier(query) == queryID else { return }
            query.disableUpdates()
            self.checkIosOutbox()
            query.enableUpdates()
        }
    }

    // MARK: - KVS change handler

    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            guard self.isSetUp else { return }
            let messageChanged = changedKeys == nil
                || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if messageChanged {
                if self.deviceTransport != nil {
                    _ = await self.drainDeviceTransport(trigger: .legacyKVS)
                } else {
                    self.syncStatus = "KVS trigger received — checking Drive…"
                    self.checkIosOutbox()
                }
            }
        }
    }

    // MARK: - Cleanup

    public func tearDown() {
        // Close request admission before settling waiters or draining sends.
        isSetUp = false
        phoneRequests.stop()
        // Cancel + invalidate any in-flight container resolve so a late
        // applyContainerResult can't re-register observers after teardown.
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        incomingObserverGeneration &+= 1
        incomingObserverInstalled = false
        incomingObserverTask?.cancel()
        transportSetupTask?.cancel()
        outboxScanGeneration &+= 1
        outboxScanTask?.cancel()
        // The scanner keeps its slot until physical file work returns. Backlog
        // owners finish their accepted turn, then the lifecycle fence retires them.
        outboxScanQueued = false
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        deviceNetworkMonitor?.cancel()
        deviceNetworkMonitor = nil
        deviceNetworkSatisfied = nil
        cloudKitPushProofAt = nil
        cloudKitPushUnavailable = false
        deviceDrainCadence = nil
        drainPolicy = AdaptiveDrainPolicy()
        messageHandlers = []
        deviceTransport = nil  // CK-3b: drop the transport; setup() re-resolves it
        phonePairingSettled = false
        phonePairedElsewhere = false
        phonePairingRecheckDue = false
        cloudKitVisualNotificationPeerReady = false
        lastPublishedProviderCatalogStatus = nil
        // Keep the owner until its awaited send returns; a new setup queues
        // behind it instead of overlapping the retired lifecycle's publication.
        providerCatalogPublicationQueued = false
        lastPublishedMobileSnapshotStatus = [:]
        deviceDrainTimerTask?.cancel()  // CK-3c: stop the poll
        deviceDrainTimerTask = nil
        // The drain and retention handles keep exclusion until actual exit.
        deviceDrainQueued = false
        deviceRetentionSweepTask?.cancel()  // 2026-09-06: stop the retention sweep
        if let deliveryNudgeQueue {
            Task { await deliveryNudgeQueue.cancelAll() }
            self.deliveryNudgeQueue = nil
        }
        // N8 fix (R16): reset isSetUp so a subsequent setup() call can succeed.
        // Without this, tearDown() left isSetUp=true and setup() returned early
        // at the guard-!isSetUp check, leaving the bridge permanently stopped.
        isSetUp = false
        // PATCH-2026-05-07: ios-parity stop sync engine
        sync.engine.stop()
    }
}

// BridgeError is now in NativeAgentShared.
