// PATCH-2026-05-07: icloud-bridge iOS side — iCloud KVS+Drive hybrid bridge
// Mirror of Sources/NativeAgentApp/iCloudBridge.swift (v1: extract to shared SPM module)
// Architecture: A+B hybrid
//   - iCloud KVS (NSUbiquitousKeyValueStore): short control messages, "new-message" triggers
//   - iCloud Drive (NSMetadataQuery): full chat message payloads
// No server, no tunnel, no Apple Developer cert required.
// Container: configured by NativeAgentICloudBridgeConstants.

import Foundation
import SwiftUI
import UIKit
import NativeAgentShared

// BridgeMessage, BridgeError, and all HMAC helpers are now in NativeAgentShared.
private typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
private typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder

struct ICloudBridgeRejectedMessage: Sendable {
    let messageID: String
    let correlationID: String?
    let reason: String

    var userMessage: String {
        if reason == "stale timestamp" {
            return "Mac reply rejected: stale timestamp. Check both devices' clocks and try again."
        }
        return "Mac reply rejected: \(reason). Re-pair this iPhone with the current Mac app."
    }
}

private enum ICloudBridgeIOError: LocalizedError, Sendable {
    case timeout(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timeout(let operation, let seconds):
            return "\(operation) timed out after \(Int(seconds))s. Check iCloud Drive connectivity and try again."
        }
    }
}

enum ICloudLegacyReplyArchive {
    static let folderName = "ios-consumed"
    static let maximumFileCount = 200
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func archive(
        _ fileURL: URL,
        processedRoot: URL,
        fileManager: FileManager = .default
    ) {
        let archiveDirectory = processedRoot.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let destination = archiveDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            // Seen-message persistence remains the delivery guard. Archive
            // maintenance must never prevent a verified reply from reaching Chat.
            NSLog("[iCloudBridge] could not archive consumed legacy reply %@: %@", fileURL.lastPathComponent, error.localizedDescription)
        }
    }

    @discardableResult
    static func prune(
        archiveDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: archiveDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let files = candidates.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }
        let cutoff = now.addingTimeInterval(-maximumAge)
        var survivors: [(url: URL, date: Date)] = []
        var removed = 0
        for file in files {
            if file.date < cutoff {
                if (try? fileManager.removeItem(at: file.url)) != nil { removed += 1 }
            } else {
                survivors.append(file)
            }
        }

        if survivors.count > maximumFileCount {
            let oldestFirst = survivors.sorted {
                if $0.date == $1.date { return $0.url.lastPathComponent < $1.url.lastPathComponent }
                return $0.date < $1.date
            }
            for file in oldestFirst.prefix(survivors.count - maximumFileCount) {
                if (try? fileManager.removeItem(at: file.url)) != nil { removed += 1 }
            }
        }
        return removed
    }
}

private final class ICloudBridgeWriteContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func publishAndResume(
        _ continuation: CheckedContinuation<Void, Error>,
        publish: () throws -> Void
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        do {
            try publish()
            didResume = true
            lock.unlock()
            continuation.resume()
        } catch {
            didResume = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - iCloudBridge (iOS)

@MainActor
final class iCloudBridge: ObservableObject {
    static let shared = iCloudBridge()

    // MARK: Published state

    @Published var available: Bool = false
    @Published var lastSyncAt: Date?
    @Published var syncStatus: String = "iCloud not checked"

    // MARK: Private

    private let kvs = NSUbiquitousKeyValueStore.default
    private var driveURL: URL?
    private var metadataQuery: NSMetadataQuery?
    // CK-3b: the device-sync transport SEAM. Non-nil ⇒ CloudKit is the active
    // transport (resolver selected `.cloudkit` AND the entitlement is present —
    // makeCloudKitTransport enforces the crash-guard). nil ⇒ the legacy
    // KVS/ubiquity path runs unchanged. Resolver defaults `.kvs`, so this stays
    // nil until CK-4 bakes the flag → zero runtime change here.
    private var deviceTransport: DeviceSyncTransport?
    var usesCloudKitDeviceTransport: Bool { deviceTransport != nil }
    // CK-3c: single-flight guard for the transport drain (APNs push + observe
    // re-drains coalesce; per-message delivery is already atomic in the transport).
    private var deviceDrainInFlight = false
    private var deviceDrainQueued = false
    private var messageHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    private var rejectionHandlers: [UUID: (ICloudBridgeRejectedMessage) -> Void] = [:]
    // Phase 14e-iCloud HMAC self-heal: callbacks invoked when an unsigned
    // signature_invalid_resync hint arrives from Mac.
    private var resyncHintHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    // R2: Mac-originated notifications relayed via iCloud. The BridgeMessage's
    // metadata.kind == "notification" carries title/body (and optional
    // userInfo.* keys) so the iOS app can schedule a local UNNotification.
    private var notificationHandlers: [UUID: (BridgeMessage) -> Void] = [:]
    // fix-2026-06-10 sync-audit #2 (fix-R9-9 pattern from Mac's MacSyncEngine):
    // ordered array alongside the set so eviction drops OLDEST ids first. The
    // previous persist path did Array(set.suffix(500)) — an arbitrary subset —
    // which could forget a recent Mac reply id across relaunch and replay it.
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDsOrdered: [String] = []
    private var seenKVSProgressMessageIDs: Set<String> = []
    // 2026-07-21 audit fix: insertion-ordered array beside the set so eviction
    // drops OLDEST ids first — sorted().suffix(max) kept an arbitrary subset
    // (opaque message ids sort unrelated to arrival), so a recently-seen id
    // could be evicted and its progress message re-dispatched (duplicate tool
    // pill / revived typing hint). Mirrors recordSeenMacReplyID above.
    private var seenKVSProgressMessageIDsOrdered: [String] = []
    private var isCheckingMacOutbox = false
    private var macOutboxScanQueued = false
    private var setupTask: Task<Void, Never>?
    private var setupGeneration = 0
    private let processedMacReplyIDsKey = "NativeAgentMobile.iCloud.processedMacReplyIDs.v1"
    private let maxProcessedMacReplyIDs = 500
    private let maxSeenKVSProgressMessageIDs = 200

    // Phase 14e-iCloud: PairingStore is injected so sendChatMessage can sign
    // outgoing BridgeMessages and checkMacOutbox can verify incoming ones.
    // Set by NativeAgentMobileApp at startup.
    weak var pairingStore: PairingStore?

    // MARK: - Init

    private init() {
        if let saved = UserDefaults.standard.array(forKey: processedMacReplyIDsKey) as? [String] {
            // fix-2026-06-10 sync-audit #2: restore the ordered array (disk
            // order = insertion order) so eviction stays oldest-first.
            for id in saved where seenMessageIDs.insert(id).inserted {
                seenMessageIDsOrdered.append(id)
            }
        }
    }

    // fix-2026-06-10 sync-audit #2: insertion-ordered record + oldest-first
    // eviction, capping memory and disk identically.
    private func recordSeenMacReplyID(_ id: String) {
        guard !seenMessageIDs.contains(id) else { return }
        seenMessageIDs.insert(id)
        seenMessageIDsOrdered.append(id)
        while seenMessageIDsOrdered.count > maxProcessedMacReplyIDs {
            let oldest = seenMessageIDsOrdered.removeFirst()
            seenMessageIDs.remove(oldest)
        }
    }

    // MARK: - Setup

    // N12 fix (R17): guard against double-setup. Mac side fixed this in R15;
    // iOS side had the same issue — calling setup() twice (e.g. from onAppear
    // and from a TabView re-appearance) would re-register duplicate KVS observers
    // and duplicate metadata queries, causing double-processing of messages.
    private var isSetUp = false

    func setup() {
        guard !isSetUp else { return }
        isSetUp = true
        setupGeneration += 1
        let generation = setupGeneration
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()

        // CloudKit does not require an iCloud Drive/ubiquity Documents mount.
        // Establish the entitlement-checked public transport first; legacy
        // KVS/Drive setup continues independently when a container is present.
        configureDeviceTransportIfAvailable()

        // 2026-05-09 fix: FileManager.default.url(forUbiquityContainerIdentifier:)
        // is SYNCHRONOUS and can block for many seconds (sometimes 30s+) on
        // first launch while the iCloud container mounts.  Running it on the
        // @MainActor froze the UI thread long enough that runningboardd /
        // SpringBoard escalated to a userspace watchdog timeout (180s) — kernel
        // panic and full device freeze. Crash logs from a connected iPhone
        // confirmed: "panic: userspace watchdog timeout: no successful checkins
        // from SpringBoard in 180 seconds".
        //
        // Move the container resolve + directory bootstrap off the main actor;
        // hop back to update @Published state and start the metadata query.
        setupTask = Task.detached(priority: .userInitiated) {
            let containerID = NativeAgentICloudBridgeConstants.containerID
            // This call is what was blocking — runs on a background thread now.
            let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
            await iCloudBridge.shared.applyContainerResult(containerURL, generation: generation)
        }
    }

    /// Applies the result of the off-main-actor container lookup back on the
    /// main actor.  Split out from setup() so the Task.detached closure
    /// doesn't capture `self` directly (Swift-6 strict concurrency clean).
    @MainActor
    private func applyContainerResult(_ containerURL: URL?, generation: Int) {
        guard generation == setupGeneration, isSetUp else { return }
        guard let containerURL else {
            if DeviceSyncTransportResolver.bridgeCanStart(
                cloudKitTransportActive: deviceTransport != nil,
                ubiquityContainerAvailable: false
            ) {
                available = true
                syncStatus = "CloudKit ready — iCloud Drive unavailable"
                return
            }
            available = false
            syncStatus = "iCloud unavailable — sign into iCloud in Settings → Apple Account"
            isSetUp = false  // allow retry
            return
        }
        let docsURL = containerURL.appendingPathComponent("Documents")
        driveURL = docsURL
        createDriveDirectories(docsURL: docsURL)
        available = true
        syncStatus = "iCloud ready"

        // PATCH-2026-05-07: ios-parity wire snapshot engine to the same container
        iCloudSyncEngine.shared.setup(docsURL: docsURL)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        kvs.synchronize()

        startMetadataQuery(docsURL: docsURL)
    }

    /// Starts the public CloudKit transport before any iCloud Drive lookup.
    /// Incoming pairing material is handed to PairingStore, the existing
    /// transactional Keychain owner; the bridge never persists a second copy.
    private func configureDeviceTransportIfAvailable() {
        guard deviceTransport == nil else { return }
        guard let transport = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .ios,
            containerIdentifier: NativeAgentICloudBridgeConstants.containerID
        ) else {
            return
        }
        deviceTransport = transport
        available = true
        syncStatus = "CloudKit connecting…"
        NSLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=ios)")
        iCloudSyncEngine.shared.enableCloudKitSnapshotCache()

        // Silent CloudKit subscription pushes do not require alert permission,
        // but they do require APNS device registration. Register as soon as the
        // entitled transport exists instead of waiting until pairing has
        // already completed (which is too late for an iOS-starts-first flow).
        UIApplication.shared.registerForRemoteNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudKitAppDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        Task {
            await transport.observeIncoming { [weak self] msg in
                await self?.handleIncomingFromTransport(msg) ?? false
            }
            let ready = await transport.ensurePushSubscriptions()
            await self.publishVisualNotificationCapability(
                ready: ready && transport.presentsVisualNotifications,
                using: transport
            )
        }
        Task {
            await transport.observePairing { [weak self] secret in
                await self?.applyPairingMaterialFromTransport(secret) ?? false
            }
        }
        Task {
            await transport.observeStatus(
                key: NAProviderCatalogStatusCodec.statusKey
            ) { value in
                await MainActor.run {
                    _ = iCloudSyncEngine.shared.applyProviderCatalogStatus(value)
                }
            }
        }
        Task {
            for group in NAMobileSnapshotGroup.allCases {
                await transport.observeStatus(key: group.statusKey) { value in
                    await iCloudSyncEngine.shared.applyCloudKitSnapshotStatus(
                        value,
                        group: group
                    )
                }
            }
        }
    }

    /// Foreground catch-up for the unpaired state. A failed/missing Keychain
    /// commit leaves the transport pairing record unacknowledged, so this
    /// bounded activation event retries it without adding an idle poll. Once
    /// paired, foreground activation performs no pairing work.
    @objc private nonisolated func cloudKitAppDidBecomeActive(_ note: Notification) {
        Task { @MainActor in
            guard let transport = self.deviceTransport else { return }
            let ready = await transport.ensurePushSubscriptions()
            await self.publishVisualNotificationCapability(
                ready: ready && transport.presentsVisualNotifications,
                using: transport
            )
            if self.pairingStore?.isPaired != true {
                _ = await transport.drainPairing()
            }
        }
    }

    private func publishVisualNotificationCapability(
        ready: Bool,
        using transport: any DeviceSyncTransport
    ) async {
        do {
            try await transport.setStatus(
                key: NAVisualNotificationCapability.statusKey,
                value: NAVisualNotificationCapability.encoded(ready: ready)
            )
        } catch {
            NSLog("[iCloudBridge] visual notification capability publish failed: \(error)")
        }
    }

    private func applyPairingMaterialFromTransport(_ secret: Data) -> Bool {
        guard secret.count == 32 else {
            NSLog("[iCloudBridge] Rejected malformed CloudKit pairing material (%d bytes)", secret.count)
            return false
        }
        guard let pairingStore else {
            NSLog("[iCloudBridge] Holding CloudKit pairing material until PairingStore is attached")
            return false
        }
        return pairingStore.applyCloudKitPairingSecret(secret)
    }

    private func createDriveDirectories(docsURL: URL) {
        let fm = FileManager.default
        for folder in [DriveFolder.outboxMac, DriveFolder.outboxIos, DriveFolder.processed] {
            let url = docsURL.appendingPathComponent(folder)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Send chat message (Drive + KVS trigger)

    func sendChatMessage(
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [MultimodalAttachment] = []
    ) async throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
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
        let msg = try unsigned.signed(with: secret)

        // CK-3b: CloudKit transport path. The signed BridgeMessage rides verbatim
        // in the record's payloadJSON (lossless — signature preserved), so the Mac
        // side verifies with the same secret exactly as on the Drive path. Large
        // attachments still ride inline here; CKAsset migration is the deferred
        // follow-up (#7) — an oversized send surfaces loud, it doesn't corrupt the
        // legacy path.
        if let ck = deviceTransport {
            try await ck.send(msg)
            lastSyncAt = Date()
            syncStatus = "Sending via CloudKit"
            return msg
        }

        // Legacy KVS/ubiquity path (default until CK-4 bakes the flag).
        guard let docsURL = driveURL else {
            throw BridgeError.containerUnavailable
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)

        let outboxURL = docsURL
            .appendingPathComponent(DriveFolder.outboxIos)
            .appendingPathComponent("\(msg.id).json")
        try await Self.writeDataOffMain(data, to: outboxURL, timeoutSeconds: 8, operation: "iCloud chat send")

        // KVS trigger: notify Mac side
        kvs.set("\(ISO8601DateFormatter().string(from: Date())):\(msg.id)", forKey: KVSKey.newMessageInDrive)
        kvs.synchronize()

        lastSyncAt = Date()
        syncStatus = "Sending"
        return msg
    }

    /// Carry the existing signed InboxAction envelope over the same CloudKit
    /// message transport as chat. The action keeps its own HMAC and is still
    /// validated and dispatched by MacSyncEngine; this only replaces the
    /// unavailable public-build iCloud Drive mailbox.
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

    // MARK: - Observe incoming messages from Mac

    @discardableResult
    func observeIncomingMessages(onMessage: @escaping (BridgeMessage) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = onMessage
        // KVS progress channel stays on KVS for now (progress-over-CK is a
        // follow-up); only the message data-plane cuts over in CK-3b.
        dispatchLatestKVSChatProgress()
        // CK-3b: with CloudKit active, the forwarder is already registered (at
        // transport birth); re-drain to pull anything that arrived before this
        // handler existed. Legacy Drive scan runs otherwise.
        if let ck = deviceTransport {
            Task { await ck.drainIncoming() }
        } else {
            Task { await checkMacOutbox() }
        }
        return id
    }

    @discardableResult
    func observeRejectedMessages(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID {
        let id = UUID()
        rejectionHandlers[id] = onReject
        // CK-3b: a rejection may have been held pending this consumer; re-drain.
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
        // CK-3b: re-drain in case a hint was held pending this consumer.
        if let ck = deviceTransport { Task { await ck.drainIncoming() } }
        return id
    }

    func removeResyncObserver(_ id: UUID?) {
        guard let id else { return }
        resyncHintHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func observeNotifications(onNotification: @escaping (BridgeMessage) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = onNotification
        // CK-3b: re-drain via CloudKit when active; legacy Drive scan otherwise.
        if let ck = deviceTransport {
            Task { await ck.drainIncoming() }
        } else {
            Task { await checkMacOutbox() }
        }
        return id
    }

    func removeNotificationObserver(_ id: UUID?) {
        guard let id else { return }
        notificationHandlers.removeValue(forKey: id)
    }

    // MARK: - Poll / flush Mac outbox

    func checkMacOutbox() async {
        guard let docsURL = driveURL else { return }
        guard let secret = pairingStore?.iCloudPairingSecret else { return }
        guard !messageHandlers.isEmpty || !notificationHandlers.isEmpty else {
            syncStatus = "Mac reply waiting — open Chat to receive it"
            return
        }
        guard !isCheckingMacOutbox else {
            macOutboxScanQueued = true
            return
        }
        isCheckingMacOutbox = true
        let seenIDs = seenMessageIDs
        defer {
            isCheckingMacOutbox = false
            if macOutboxScanQueued {
                macOutboxScanQueued = false
                Task { @MainActor in await self.checkMacOutbox() }
            }
        }

        let result = await Self.scanMacOutbox(
            docsURL: docsURL,
            secret: secret,
            seenIDs: seenIDs,
            consumeChatMessages: !messageHandlers.isEmpty,
            consumeNotifications: !notificationHandlers.isEmpty
        )
        for id in result.seenIDs {
            recordSeenMacReplyID(id)
        }
        persistSeenMacReplyIDs()
        // Phase 14e-iCloud HMAC self-heal: dispatch resync hints BEFORE
        // rejections — the hint may install a new secret in time for the
        // chat replay path triggered by the rejection.
        for hint in result.resyncHints {
            syncStatus = "iCloud pairing refresh from Mac"
            if await pairingStore?.refreshFromKVS() == true {
                NSLog("[iCloudBridge] signature_invalid_resync applied — new HMAC installed")
            }
            for handler in resyncHintHandlers.values { handler(hint) }
        }
        for rejection in result.rejections {
            syncStatus = rejection.userMessage
            for handler in rejectionHandlers.values { handler(rejection) }
        }
        for msg in result.notifications {
            lastSyncAt = Date()
            syncStatus = "Received notification from Mac"
            for handler in notificationHandlers.values { handler(msg) }
        }
        for msg in result.messages {
            lastSyncAt = Date()
            syncStatus = "Received from Mac"
            for handler in messageHandlers.values { handler(msg) }
        }
    }

    /// Exact active-transport catch-up used only while a chat reply is
    /// outstanding or the user explicitly refreshes. CloudKit must drain its
    /// records; checking the retired Drive outbox cannot observe a public build.
    func pollIncomingNow() async {
        if deviceTransport != nil {
            _ = await drainDeviceTransport()
        } else {
            await checkMacOutbox()
        }
    }

    /// CK-3b: validate + route a message pulled from the CloudKit transport,
    /// mirroring `scanMacOutboxSynchronously`'s checks. Returns true when the
    /// message is HANDLED (delivered / rejected / archived) so the transport
    /// advances its cursor; false only when transiently undeliverable — no
    /// consumer registered yet, or the pairing secret isn't ready — so the
    /// transport re-delivers on the next drain (the halt-on-undelivered contract,
    /// which correctly holds a chat message until ChatView opens and re-drains).
    @MainActor
    private func handleIncomingFromTransport(_ msg: BridgeMessage) async -> Bool {
        let kind = msg.metadata?["kind"]
        // No consumer at all yet → hold for retry.
        guard kind == "icloud_action_response"
                || !messageHandlers.isEmpty
                || !notificationHandlers.isEmpty else { return false }
        if seenMessageIDs.contains(msg.id) { return true }
        guard let secret = pairingStore?.iCloudPairingSecret else { return false }  // can't verify → retry

        // targetSourceKey filter (mirrors the scan): not addressed here → consume.
        if let tsk = msg.metadata?["targetSourceKey"], !tsk.isEmpty,
           tsk != ChatRuntimeControls.deviceSourceKey,
           !NativeAgentICloudBridgeConstants.isMobileSourceKey(tsk) {
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            return true
        }

        // Resync hint arrives UNSIGNED by design — dispatch on kind BEFORE the
        // signature check (Mac/iOS have disagreeing secrets at this point).
        if msg.metadata?["kind"] == "signature_invalid_resync" {
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            syncStatus = "iCloud pairing refresh from Mac"
            if await pairingStore?.refreshFromKVS() == true {
                NSLog("[iCloudBridge] signature_invalid_resync applied — new HMAC installed")
            }
            for handler in resyncHintHandlers.values { handler(msg) }
            return true
        }

        // HMAC — verify or reject (a CK record is no more trusted than a file).
        if msg.signature == nil || !msg.verifySignature(secret: secret) {
            // Preserve the "re-pair" prompt: if no rejection consumer is
            // registered yet (ChatView closed), HOLD for retry rather than
            // consuming and losing the prompt (gpt-5.5 CK-3b review P1 #3).
            // Delivered when a consumer registers and re-drains.
            guard !rejectionHandlers.isEmpty else { return false }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id, correlationID: msg.correlationID, reason: "signature_invalid")
            syncStatus = rejection.userMessage
            for handler in rejectionHandlers.values { handler(rejection) }
            return true
        }

        // >24h old → archive silently (phone was likely offline; history syncs
        // via snapshots). Mirrors sync-audit #4 — no scary clock-skew banner.
        if abs(Date().timeIntervalSince(msg.timestamp)) > 24 * 60 * 60 {
            NSLog("[iCloudBridge] archiving >24h-old Mac CK message %@ without dispatch", msg.id)
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            return true
        }

        // Route notification vs chat; consume only if the matching consumer
        // exists (else hold for retry — delivered in order when it registers).
        if kind == "icloud_action_response" {
            guard let actionID = msg.correlationID,
                  await iCloudSyncEngine.shared.persistCloudKitActionResponse(
                    msg.text,
                    actionID: actionID
                  ) else {
                return false
            }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            lastSyncAt = Date()
            syncStatus = "Received action response from Mac (CloudKit)"
        } else if kind == "notification" {
            guard !notificationHandlers.isEmpty else { return false }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            lastSyncAt = Date()
            syncStatus = "Received notification from Mac (CloudKit)"
            if NativeAgentCloudKitNotificationRouting.shouldScheduleLocalCopy(
                transportPresentsVisualNotification: deviceTransport?.presentsVisualNotifications == true
            ) {
                for handler in notificationHandlers.values { handler(msg) }
            } else {
                NSLog("[iCloudBridge] consumed CloudKit notification %@ without local duplicate; Apple owns visual presentation", msg.id)
            }
        } else {
            guard !messageHandlers.isEmpty else { return false }
            recordSeenMacReplyID(msg.id); persistSeenMacReplyIDs()
            lastSyncAt = Date()
            syncStatus = "Received from Mac (CloudKit)"
            for handler in messageHandlers.values { handler(msg) }
        }
        return true
    }

    /// CK-3c: drain the CloudKit transport (incoming + pairing + status) if it is
    /// active; no-op when nil (flag-off). Called from the APNs silent-push
    /// handler. Single-flight — overlapping pushes/re-drains coalesce into at
    /// most one queued re-run (per-message delivery is already atomic in the
    /// transport). Returns true if any incoming message was dispatched.
    @discardableResult
    func drainDeviceTransport() async -> Bool {
        guard let ck = deviceTransport else { return false }
        if deviceDrainInFlight { deviceDrainQueued = true; return false }
        deviceDrainInFlight = true
        defer {
            deviceDrainInFlight = false
            if deviceDrainQueued {
                deviceDrainQueued = false
                Task { await self.drainDeviceTransport() }
            }
        }
        let dispatched = await ck.drainIncoming()
        await ck.drainPairing()
        await ck.drainStatus()
        return dispatched > 0
    }

    /// CK-3c: entry point for the APNs silent-push handler. Drains the transport
    /// ONLY when CloudKit is active (deviceTransport non-nil) AND the push is one
    /// of our device-sync subscriptions. Flag-off builds return immediately
    /// without parsing the push, so the legacy notification path is untouched.
    @discardableResult
    func drainIfDeviceSyncPush(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard deviceTransport != nil else { return false }
        #if canImport(CloudKit)
        guard CloudKitDeviceTransport.isDeviceSyncNotification(userInfo) else { return false }
        return await drainDeviceTransport()
        #else
        return false
        #endif
    }

    // MARK: - NSMetadataQuery (watches Mac outbox for new iCloud files)

    private func startMetadataQuery(docsURL: URL) {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            docsURL.appendingPathComponent(DriveFolder.outboxMac).path
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

    @objc private nonisolated func metadataQueryDidUpdate(_ note: Notification) {
        Task { @MainActor in
            self.metadataQuery?.disableUpdates()
            await self.checkMacOutbox()
            self.metadataQuery?.enableUpdates()
        }
    }

    // MARK: - KVS change handler

    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            let progressChanged = changedKeys == nil || changedKeys?.contains(KVSKey.chatProgressLatest) == true
            let driveChanged = changedKeys == nil || changedKeys?.contains(KVSKey.newMessageInDrive) == true
            if progressChanged {
                self.dispatchLatestKVSChatProgress()
            }
            // CK-5: drain ONLY on the once-per-message nudge (newMessageInDrive),
            // NEVER on progressChanged. The stream fires chatProgressLatest on every
            // token, so draining on it queued a drain storm that accumulated across
            // the conversation and stalled later messages. The Mac fires the drive
            // nudge exactly once, right after it saves the durable CloudKit message.
            if driveChanged {
                if self.deviceTransport != nil {
                    await self.drainDeviceTransport()
                } else {
                    self.syncStatus = "KVS ping — fetching from Mac..."
                    await self.checkMacOutbox()  // legacy path (flag-off)
                }
            }
        }
    }

    private func dispatchLatestKVSChatProgress() {
        guard !messageHandlers.isEmpty else { return }
        guard let secret = pairingStore?.iCloudPairingSecret else { return }
        guard let data = kvs.data(forKey: KVSKey.chatProgressLatest) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let msg = try? decoder.decode(BridgeMessage.self, from: data) else {
            return
        }
        guard !seenKVSProgressMessageIDs.contains(msg.id) else { return }
        guard msg.sender == "mac" else { return }
        guard msg.verifySignature(secret: secret) else {
            syncStatus = "Mac progress rejected — pairing out of sync"
            return
        }
        guard abs(Date().timeIntervalSince(msg.timestamp)) <= 24 * 60 * 60 else { return }
        guard let kind = msg.metadata?["kind"],
              kind == "progress" || kind == "tool_use" || kind == "tool_result" else {
            return
        }
        if let targetSourceKey = msg.metadata?["targetSourceKey"],
           !targetSourceKey.isEmpty,
           targetSourceKey != ChatRuntimeControls.deviceSourceKey,
           !NativeAgentICloudBridgeConstants.isMobileSourceKey(targetSourceKey) {
            return
        }

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

    // MARK: - iCloud sign-in check helper

    /// Returns the iCloud account token (opaque, non-PII) or nil if not signed in.
    var iCloudAccountToken: String? {
        FileManager.default.ubiquityIdentityToken.map { "\($0)" }
    }

    // MARK: - Cleanup

    func tearDown() {
        setupGeneration += 1
        setupTask?.cancel()
        setupTask = nil
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        messageHandlers = [:]
        rejectionHandlers = [:]
        resyncHintHandlers = [:]
        notificationHandlers = [:]
        deviceTransport = nil  // CK-3b: drop the transport; setup() re-resolves it
        deviceDrainInFlight = false  // CK-3c
        deviceDrainQueued = false
        driveURL = nil
        available = false
        syncStatus = "iCloud disconnected"
        isCheckingMacOutbox = false
        macOutboxScanQueued = false
        isSetUp = false
        iCloudSyncEngine.shared.tearDown()
    }

    private func persistSeenMacReplyIDs() {
        // fix-2026-06-10 sync-audit #2: persist the ORDERED array (oldest →
        // newest). The old Array(set.suffix(cap)) kept an arbitrary subset.
        let capped = Array(seenMessageIDsOrdered.suffix(maxProcessedMacReplyIDs))
        UserDefaults.standard.set(capped, forKey: processedMacReplyIDsKey)
    }

    private struct MacOutboxScanResult: Sendable {
        var messages: [BridgeMessage] = []
        var rejections: [ICloudBridgeRejectedMessage] = []
        var seenIDs: [String] = []
        // Phase 14e-iCloud HMAC self-heal: unsigned signature_invalid_resync
        // hints from Mac. Surfaced separately so the main-actor handler can
        // refresh the secret and retry the last unACK'd send.
        var resyncHints: [BridgeMessage] = []
        // R2: notification BridgeMessages relayed from Mac.
        var notifications: [BridgeMessage] = []
    }

    private nonisolated static func writeDataOffMain(
        _ data: Data,
        to url: URL,
        timeoutSeconds: TimeInterval,
        operation: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ICloudBridgeWriteContinuation()
            let writeTask = Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let parent = url.deletingLastPathComponent()
                let stagedURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: stagedURL) }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordError: NSError?
                var writeError: Error?
                coordinator.coordinate(writingItemAt: stagedURL, options: [.forReplacing], error: &coordError) { writeURL in
                    do {
                        try data.write(to: writeURL, options: .atomic)
                    } catch {
                        writeError = error
                    }
                }
                if let coordError {
                    gate.resume(continuation, with: .failure(coordError))
                } else if let writeError {
                    gate.resume(continuation, with: .failure(writeError))
                } else {
                    gate.publishAndResume(continuation) {
                        if fm.fileExists(atPath: url.path) {
                            try fm.removeItem(at: url)
                        }
                        try fm.moveItem(at: stagedURL, to: url)
                    }
                }
            }
            Task.detached {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                } catch {
                    return
                }
                writeTask.cancel()
                gate.resume(continuation, with: .failure(ICloudBridgeIOError.timeout(operation, timeoutSeconds)))
            }
        }
    }

    private nonisolated static func scanMacOutbox(
        docsURL: URL,
        secret: Data,
        seenIDs: Set<String>,
        consumeChatMessages: Bool,
        consumeNotifications: Bool
    ) async -> MacOutboxScanResult {
        let task = Task.detached(priority: .userInitiated) {
            scanMacOutboxSynchronously(
                docsURL: docsURL,
                secret: secret,
                seenIDs: seenIDs,
                consumeChatMessages: consumeChatMessages,
                consumeNotifications: consumeNotifications
            )
        }
        return await task.value
    }

    private nonisolated static func scanMacOutboxSynchronously(
        docsURL: URL,
        secret: Data,
        seenIDs: Set<String>,
        consumeChatMessages: Bool,
        consumeNotifications: Bool
    ) -> MacOutboxScanResult {
        var result = MacOutboxScanResult()
        let macOutbox = docsURL.appendingPathComponent(DriveFolder.outboxMac)
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        let fm = FileManager.default

        try? fm.startDownloadingUbiquitousItem(at: macOutbox)

        guard let files = try? fm.contentsOfDirectory(
            at: macOutbox,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return result }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in jsonFiles {
            // 2026-07-21 audit fix: a size>0 attribute is NOT proof of
            // download — iCloud syncs metadata (including logical size) before
            // content, so a dataless file read size>0, was treated as
            // downloaded, Data(contentsOf:) failed silently (try? → nil →
            // continue), and NO download was ever kicked. The file was
            // re-scanned forever; a notification stuck in a dataless file
            // never fired. Ask the downloading status instead.
            let downloadingStatus = try? fileURL.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ).ubiquitousItemDownloadingStatus
            guard downloadingStatus == .current else {
                try? fm.startDownloadingUbiquitousItem(at: fileURL)
                continue
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let msg = try? decoder.decode(BridgeMessage.self, from: data),
                  !seenIDs.contains(msg.id) else { continue }

            if let targetSourceKey = msg.metadata?["targetSourceKey"],
               !targetSourceKey.isEmpty,
               targetSourceKey != ChatRuntimeControls.deviceSourceKey,
               !NativeAgentICloudBridgeConstants.isMobileSourceKey(targetSourceKey) {
                continue
            }
            let isNotification = msg.metadata?["kind"] == "notification"
            if isNotification {
                guard consumeNotifications else { continue }
            } else {
                guard consumeChatMessages else { continue }
            }

            // Phase 14e-iCloud HMAC self-heal: resync hints from Mac arrive
            // UNSIGNED by design (Mac and iOS have disagreeing secrets at
            // this point - signing would just hit the same mismatch).
            // Dispatch on metadata.kind BEFORE the signature check.
            if msg.metadata?["kind"] == "signature_invalid_resync" {
                result.seenIDs.append(msg.id)
                result.resyncHints.append(msg)
                moveToProcessed(fileURL, processedDir: processedDir, fileManager: fm)
                continue
            }

            if msg.signature == nil || !msg.verifySignature(secret: secret) {
                result.seenIDs.append(msg.id)
                result.rejections.append(ICloudBridgeRejectedMessage(
                    messageID: msg.id,
                    correlationID: msg.correlationID,
                    reason: "signature_invalid"
                ))
                moveToProcessed(fileURL, processedDir: processedDir, fileManager: fm)
                continue
            }
            if abs(Date().timeIntervalSince(msg.timestamp)) > 24 * 60 * 60 {
                // fix-2026-06-10 sync-audit #4: an unconsumed >24h-old Mac
                // reply almost always means the phone was simply off/offline —
                // not clock skew. Dispatching a "stale timestamp" rejection put
                // a scary "check both devices' clocks" banner up and discarded
                // the reply text. Archive silently instead; the conversation
                // history arrives via the chat_transcripts.json snapshot anyway.
                NSLog("[iCloudBridge] archiving >24h-old Mac outbox message %@ without dispatch (phone likely offline; history syncs via snapshots)", msg.id)
                result.seenIDs.append(msg.id)
                moveToProcessed(fileURL, processedDir: processedDir, fileManager: fm)
                continue
            }
            // R2: route notification-kind messages to the notification
            // handler instead of the chat reply path.
            if msg.metadata?["kind"] == "notification" {
                result.seenIDs.append(msg.id)
                result.notifications.append(msg)
                moveToProcessed(fileURL, processedDir: processedDir, fileManager: fm)
                continue
            }
            result.seenIDs.append(msg.id)
            result.messages.append(msg)
            moveToProcessed(fileURL, processedDir: processedDir, fileManager: fm)
        }
        ICloudLegacyReplyArchive.prune(
            archiveDirectory: processedDir.appendingPathComponent(ICloudLegacyReplyArchive.folderName),
            fileManager: fm
        )
        return result
    }

    private nonisolated static func moveToProcessed(
        _ fileURL: URL,
        processedDir: URL,
        fileManager fm: FileManager
    ) {
        ICloudLegacyReplyArchive.archive(
            fileURL,
            processedRoot: processedDir,
            fileManager: fm
        )
    }
}

enum NativeAgentCloudKitNotificationRouting {
    static func shouldScheduleLocalCopy(
        transportPresentsVisualNotification: Bool
    ) -> Bool {
        !transportPresentsVisualNotification
    }
}

// BridgeError is now in NativeAgentShared.
