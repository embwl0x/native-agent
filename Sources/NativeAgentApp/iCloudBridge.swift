// PATCH-2026-05-07: icloud-bridge Mac side — iCloud KVS+Drive hybrid bridge
// Architecture: A+B hybrid
//   - iCloud KVS (NSUbiquitousKeyValueStore): short control messages, status pings, "new-message" triggers
//   - iCloud Drive (NSMetadataQuery): chat history, attachments, full message payloads
// No Apple Developer cert required. Works on free Apple ID.
// Container: configured by NativeAgentICloudBridgeConstants.
// CloudKit (Option C) is the v2 upgrade path — see docs/mobile_companion.md

import Foundation
import SwiftUI
import NativeAgentShared
import PersistenceCore

// MARK: - iCloudBridge (Mac)
// BridgeMessage, BridgeError, and all HMAC helpers are now in NativeAgentShared.
private typealias KVSKey = NativeAgentICloudBridgeConstants.KVSKey
private typealias DriveFolder = NativeAgentICloudBridgeConstants.DriveFolder

@MainActor
final class iCloudBridge: ObservableObject {
    static let shared = iCloudBridge()

    // MARK: Published state

    @Published var available: Bool = false
    @Published var lastSyncAt: Date?
    @Published var syncStatus: String = "iCloud not checked"

    // MARK: Private

    private var driveURL: URL?
    private var metadataQuery: NSMetadataQuery?
    private var messageHandlers: [(BridgeMessage) async -> Bool] = []
    // CK-3b: the device-sync transport SEAM. Non-nil ⇒ CloudKit is the active
    // transport (resolver selected `.cloudkit` AND the entitlement is present —
    // makeCloudKitTransport enforces the crash-guard). nil ⇒ the legacy
    // KVS/ubiquity path below runs unchanged. The resolver defaults `.kvs`, so
    // this stays nil until CK-4 bakes the flag → zero runtime change here.
    private var deviceTransport: DeviceSyncTransport?
    var usesCloudKitDeviceTransport: Bool { deviceTransport != nil }
    private(set) var cloudKitVisualNotificationPeerReady: Bool = false
    // CK-3c: single-flight guard for the transport drain (timer + observe +
    // on-demand triggers coalesce; per-message delivery is already atomic in the
    // transport) + the flag-gated poll task (Mac has no APNs push handler, so it
    // polls the transport while CloudKit is active).
    private var deviceDrainInFlight = false
    private var deviceDrainQueued = false
    private var deviceDrainTimerTask: Task<Void, Never>?
    /// Last successfully published deterministic provider projection. Repeated
    /// UI refreshes often discover identical state; skip those CloudKit writes.
    private var lastPublishedProviderCatalogStatus: String?
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
    private var setupTask: Task<Void, Never>?
    // Monotonic token: bumped on every setup()/tearDown() so a stale off-main
    // container resolve that completes late can't re-register observers / start
    // the query for a superseded setup (it checks generation before applying).
    private var setupGeneration: Int = 0
    private var outboxScanTask: Task<Void, Never>?
    private var outboxScanInFlight = false
    private var outboxScanQueued = false
    // N10 fix: idempotency guard — track whether setup() has already run so
    // repeat calls don't stack additional KVS observers (each call added a
    // new addObserver which fired the handler multiple times per external change).
    private var isSetUp: Bool = false

    // Drive folder layout
    // <container>/Documents/outbox/mac/   — Mac writes here
    // <container>/Documents/outbox/ios/   — iOS writes here
    // <container>/Documents/processing/   — Mac claimed but has not acked yet
    // <container>/Documents/processed/    — read messages moved here (archive)

    // MARK: - Init

    private init() {}

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
        let capped = Array(seenMessageIDsOrdered.suffix(Self.seenMessageIDsCap))
        UserDefaults.standard.set(capped, forKey: Self.ckProcessedIDsDefaultsKey)
    }

    private func loadCKSeenIDs() {
        guard let ckIDs = UserDefaults.standard.array(forKey: Self.ckProcessedIDsDefaultsKey) as? [String] else { return }
        for id in ckIDs where seenMessageIDs.insert(id).inserted {
            seenMessageIDsOrdered.append(id)
        }
        trimSeenMessageIDsIfNeeded()
    }

    // MARK: - Ubiquity container resolution (single source)

    /// Canonical resolver for the iCloud ubiquity container's `Documents` URL,
    /// via `FileManager.url(forUbiquityContainerIdentifier:)`. Returns nil when
    /// iCloud is signed out / the container isn't mounted.
    ///
    /// C10 (tightness-sweep 2026-07-17): this is the SINGLE owner of the
    /// container lookup. SwiftNativeAPNS previously hand-built the equivalent
    /// path from `NSHomeDirectory()/Library/Mobile Documents/<folder>` — a
    /// second, silently-drifting way to find the same directory. That path now
    /// lives here as `hardcodedDocumentsURL()` and is used only as a fallback.
    ///
    /// WARNING: `url(forUbiquityContainerIdentifier:)` is SYNCHRONOUS and can
    /// block for many seconds on first launch while the container mounts — only
    /// call it off the main actor (as `setup()` and the APNS token-load path
    /// both do). It is `nonisolated` precisely so background callers can reach
    /// it without hopping to the main actor.
    nonisolated static func ubiquityDocumentsURL() -> URL? {
        let containerID = NativeAgentICloudBridgeConstants.containerID
        return FileManager.default
            .url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// The legacy hand-built `~/Library/Mobile Documents/<folder>/Documents`
    /// URL. Deterministic (no container-mount wait), so it's the safe fallback
    /// when the API resolver returns nil.
    nonisolated static func hardcodedDocumentsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent(NativeAgentICloudBridgeConstants.mobileDocumentsFolderName, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    // MARK: - Setup

    func setup() {
        // N10 fix: guard against repeat setup() calls stacking KVS observers.
        guard !isSetUp else { return }
        isSetUp = true
        syncStatus = "iCloud connecting…"
        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration

        // CloudKit-only starts do not pass through the Drive bootstrap below,
        // so restore their persisted replay filter before the first drain.
        loadCKSeenIDs()

        // CloudKit is independent of the ubiquity/Drive mount. Public
        // Developer ID builds may have the CloudKit service without
        // CloudDocuments, so establish the entitlement-checked transport
        // before resolving the legacy Documents container.
        configureDeviceTransportIfAvailable()

        // 2026-05-28 fix: FileManager.default.url(forUbiquityContainerIdentifier:)
        // is SYNCHRONOUS and can block for many seconds (sometimes 30s+) on first
        // launch while the iCloud container mounts. Running it on the @MainActor
        // froze the UI thread long enough that runningboardd / the watchdog killed
        // the app. The iOS companion hit this exact bug; this ports that fix.
        //
        // Move the container resolve off the main actor; hop back to update
        // @Published state, register observers, and start the metadata query.
        let containerID = NativeAgentICloudBridgeConstants.containerID
        setupTask = Task.detached(priority: .utility) {
            // This is the call that was blocking — runs on a background thread now.
            let containerURL = FileManager.default.url(
                forUbiquityContainerIdentifier: containerID
            )
            await iCloudBridge.shared.applyContainerResult(containerURL, generation: generation)
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
            if DeviceSyncTransportResolver.bridgeCanStart(
                cloudKitTransportActive: deviceTransport != nil,
                ubiquityContainerAvailable: false
            ) {
                // Transport selection is now final: there is no Drive root to
                // replace this cache. Starting projection here avoids building
                // the same heavy snapshots once for the temporary CloudKit
                // cache and again moments later when Drive resolves.
                MacSyncEngine.shared.startCloudKitSnapshotProjection()
                available = true
                syncStatus = "CloudKit ready — iCloud Drive unavailable"
                return
            }
            // Reset isSetUp so the caller can retry later once iCloud signs in.
            isSetUp = false
            available = false
            syncStatus = "iCloud container unavailable — sign into iCloud in System Settings"
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

        available = true
        syncStatus = "iCloud ready"

        // PATCH-2026-05-07: ios-parity start snapshot writer + inbox watcher
        MacSyncEngine.shared.start(docsURL: docsURL)

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

        // Start NSMetadataQuery watching iOS outbox folder
        startMetadataQuery(docsURL: docsURL)
    }

    /// Starts the checked CloudKit transport without depending on iCloud Drive.
    /// The factory remains the sole entitlement/crash guard. Legacy KVS/Drive
    /// setup proceeds independently and is still used when this returns nil.
    private func configureDeviceTransportIfAvailable() {
        guard deviceTransport == nil else { return }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        guard let transport = DeviceSyncTransportResolver.makeCloudKitTransport(
            role: .mac,
            containerIdentifier: containerID
        ) else {
            return
        }
        deviceTransport = transport
        available = true
        syncStatus = "CloudKit connecting…"
        NSLog("[iCloudBridge] device transport: CloudKit ACTIVE (role=mac)")

        Task {
            await transport.observeIncoming { [weak self] msg in
                await self?.handleIncomingFromTransport(msg) ?? false
            }
        }
        Task {
            await transport.observeStatus(
                key: NAVisualNotificationCapability.statusKey
            ) { [weak self] value in
                await MainActor.run {
                    self?.cloudKitVisualNotificationPeerReady =
                        NAVisualNotificationCapability.isReady(value)
                }
            }
        }
        Task {
            _ = await PairingSecretManager.publishMaterial(to: transport)
            _ = await self.publishProviderCatalogStatus()
        }

        // Mac has no APNs push handler, so poll while CloudKit is active.
        // This is transport-only and does not depend on a Drive mount.
        deviceDrainTimerTask?.cancel()
        deviceDrainTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await self?.drainDeviceTransport()
            }
        }
    }

    /// Republishes the current canonical secret after an explicit rotation.
    /// MacPairingView calls this in addition to the preserved KVS publication;
    /// the bridge exposes no secret bytes and owns no alternate pairing state.
    @discardableResult
    func publishCurrentPairingSecret() async -> Bool {
        guard let deviceTransport else { return false }
        return await PairingSecretManager.publishMaterial(to: deviceTransport)
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

    func sendChatMessage(
        text: String,
        sessionID: String? = nil,
        correlationID: String? = nil,
        metadata: [String: String]? = nil,
        attachments: [MultimodalAttachment] = [],
        messageID: String = UUID().uuidString
    ) async throws -> BridgeMessage {
        let unsigned = BridgeMessage.make(
            id: messageID,
            sender: "mac",
            text: text,
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: metadata,
            attachments: attachments.isEmpty ? nil : attachments
        )
        // Phase 14e-iCloud: sign with the pairing secret. PairingSecretManager
        // is the Mac-side single source of truth (used by MacSyncEngine for
        // the action channel) — same secret signs both channels so iOS can
        // verify with one key.  loadOrGenerateSecret() always returns Data.
        let secret = PairingSecretManager.loadOrGenerateSecret()
        let msg = (try? unsigned.signed(with: secret)) ?? unsigned

        // CK-3b: CloudKit transport path. The signed BridgeMessage rides verbatim
        // in the record's payloadJSON (lossless — signature preserved), so iOS
        // verifies with the same secret exactly as on the Drive path. The shared
        // codec rejects an oversized encoded record before CloudKit sees it,
        // producing a clear user-facing error instead of an opaque server failure.
        if let ck = deviceTransport {
            try await ck.send(msg)
            await recordChatDeliveryReceipt(msg, transport: "cloudkit")
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
            lastSyncAt = Date()
            syncStatus = "Sent via CloudKit"
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
            .appendingPathComponent(DriveFolder.outboxMac)
            .appendingPathComponent("\(msg.id).json")
        try await Task.detached(priority: .utility) { [data, outboxURL] in
            try data.write(to: outboxURL, options: .atomic)
        }.value
        await recordChatDeliveryReceipt(msg, transport: "icloud_drive")

        // KVS trigger: notify iOS side that a new file is waiting in Drive
        let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
        _ = await withCKTimeout("iCloudBridge.sendChatMessage.kvsTrigger") {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
            return kvs.synchronize()
        }
        scheduleDeliveryNudges(for: msg.id)

        lastSyncAt = Date()
        syncStatus = "Sent — waiting for iCloud sync"
        return msg
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
        let data = try JSONEncoder().encode(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeError.containerUnavailable
        }
        let unsigned = BridgeMessage.make(
            sender: "mac",
            text: text,
            correlationID: correlationID,
            metadata: ["kind": "icloud_action_response"]
        )
        let secret = PairingSecretManager.loadOrGenerateSecret()
        try await deviceTransport.send(unsigned.signed(with: secret))
        lastSyncAt = Date()
        syncStatus = "Sent action response via CloudKit"
    }

    private func recordChatDeliveryReceipt(_ message: BridgeMessage, transport: String) async {
        let secret = PairingSecretManager.loadOrGenerateSecret()
        let row: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "messageId": .string(message.id),
            "correlationId": message.correlationID.map { .string($0) } ?? .null,
            "sessionId": message.sessionID.map { .string($0) } ?? .null,
            "sender": .string(message.sender),
            "direction": .string("mac_to_ios"),
            "transport": .string(transport),
            "status": .string("sent"),
            "signatureVerified": .bool(message.verifySignature(secret: secret)),
            "kind": message.metadata?["kind"].map { .string($0) } ?? .string("reply"),
            "targetSourceKey": message.metadata?["targetSourceKey"].map { .string($0) } ?? .null,
            "textPreview": .string(String(message.text.prefix(240))),
            "attachmentCount": .int(Int64(message.attachments?.count ?? 0)),
        ])
        let path = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent("chat_delivery_receipts.jsonl")
        try? await appendJSONLCapped(
            row,
            to: path,
            using: SwiftNativePersistenceCore(),
            maxLines: 500,
            logLabel: "iCloudBridge.chatDelivery"
        )
    }

    /// Phase 14e-iCloud HMAC self-heal: write an UNSIGNED BridgeMessage to the
    /// Mac→iOS outbox with metadata.kind == "signature_invalid_resync". iOS
    /// special-cases this kind BEFORE its signature check so the hint actually
    /// lands even though Mac and iOS disagree on the current HMAC. Carries the
    /// rejected msg id + the Mac's current secret-publishedAt timestamp +
    /// pairing_secret_version so iOS knows what version it must catch up to.
    func sendUnsignedResyncHint(
        correlationID: String?,
        targetSourceKey: String
    ) async throws {
        guard let docsURL = driveURL else {
            throw BridgeError.containerUnavailable
        }
        let publishedAt = await withCKTimeout("iCloudBridge.resyncHint.readPublishedAt") {
            NSUbiquitousKeyValueStore.default.string(forKey: "NativeAgent.pairing.publishedAt") ?? ""
        } ?? ""
        let secretVersion = PairingSecretManager.currentSecretVersion()
        let metadata: [String: String] = [
            "kind": "signature_invalid_resync",
            "rejectedMessageId": correlationID ?? "",
            "publishedAt": publishedAt,
            "pairing_secret_version": String(secretVersion),
            "targetSourceKey": targetSourceKey,
        ]
        let msg = BridgeMessage.make(
            sender: "mac",
            text: "signature_invalid_resync",
            sessionID: nil,
            correlationID: correlationID,
            metadata: metadata
        )
        // INTENTIONALLY UNSIGNED — iOS dispatches on metadata.kind first.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let outboxURL = docsURL
            .appendingPathComponent(DriveFolder.outboxMac)
            .appendingPathComponent("\(msg.id).json")
        try await Task.detached(priority: .utility) { [data, outboxURL] in
            try data.write(to: outboxURL, options: .atomic)
        }.value
        let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(msg.id)"
        _ = await withCKTimeout("iCloudBridge.resyncHint.kvsTrigger") {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
            return kvs.synchronize()
        }
    }

    private func scheduleDeliveryNudges(for messageID: String) {
        for delayNs in [1_000_000_000, 3_000_000_000] as [UInt64] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delayNs)
                guard self.available else { return }
                let triggerValue = "\(ISO8601DateFormatter().string(from: Date())):\(messageID)"
                _ = await withCKTimeout("iCloudBridge.deliveryNudge.kvsTrigger", seconds: 3) {
                    let kvs = NSUbiquitousKeyValueStore.default
                    kvs.set(triggerValue, forKey: KVSKey.newMessageInDrive)
                    return kvs.synchronize()
                }
            }
        }
    }

    // MARK: - Status pings (KVS only — fast)

    func sendShortStatus(key: String, value: String) {
        // CK-3b: route status through the CloudKit transport when active.
        if let ck = deviceTransport {
            Task { try? await ck.setStatus(key: key, value: value) }
            return
        }
        Task.detached(priority: .utility) {
            _ = await withCKTimeout("iCloudBridge.sendShortStatus.\(key)", seconds: 3) {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(value, forKey: key)
                return kvs.synchronize()
            }
        }
    }

    /// Publish the Mac-owned provider/model catalog to the paired phone without
    /// copying credentials or requiring the legacy iCloud Drive snapshot lane.
    /// The status record is a bounded LWW projection; the Mac remains the only
    /// provider configuration owner.
    @discardableResult
    func publishProviderCatalogStatus(providers suppliedProviders: [ProviderInfo]? = nil) async -> Bool {
        guard let deviceTransport else { return false }
        do {
            let api = NativeClient(baseURL: "")
            let providers: [ProviderInfo]
            if let suppliedProviders {
                providers = suppliedProviders
            } else {
                providers = try await api.listProviders()
            }
            let preferences = try await api.getModelPreferences()
            let activeProviders = try await NativeClient.readActiveProvidersFromDisk()

            let providerRows = providers.map { provider in
                NAProviderCatalogProvider(
                    providerID: provider.provider_id,
                    displayName: provider.display_name,
                    authState: provider.auth_status.state,
                    authModes: provider.auth_modes,
                    models: provider.models.map { model in
                        NAProviderCatalogModel(
                            id: model.id,
                            name: model.name,
                            contextLength: model.context_length,
                            supportsStreaming: model.supports_streaming,
                            supportsVision: model.supports_vision,
                            supportsTools: model.supports_tools,
                            supportsJSONMode: model.supports_json_mode,
                            defaultReasoningEffort: model.default_reasoning_effort,
                            supportedReasoningEfforts: model.supported_reasoning_efforts,
                            supportsFast: model.supports_fast
                        )
                    }
                )
            }
            var surfaces: [String: NAProviderSurfaceSelection] = [:]
            for preference in preferences.preferences where !preference.surface.isEmpty && !preference.model.isEmpty {
                surfaces[preference.surface] = NAProviderSurfaceSelection(
                    providerID: activeProviders[preference.surface],
                    model: preference.model,
                    reasoningEffort: preference.reasoningEffort.isEmpty ? nil : preference.reasoningEffort,
                    serviceTier: preference.serviceTier
                )
            }
            let catalog = NAProviderCatalogStatus(
                providers: providerRows,
                surfaces: surfaces
            )
            let value = try NAProviderCatalogStatusCodec.encode(catalog)
            if value == lastPublishedProviderCatalogStatus {
                return true
            }
            try await deviceTransport.setStatus(
                key: NAProviderCatalogStatusCodec.statusKey,
                value: value
            )
            lastPublishedProviderCatalogStatus = value
            return true
        } catch {
            NSLog("[iCloudBridge] provider catalog publication failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Publish selected rebuildable iOS read projections through the existing
    /// bounded CloudKit status seam. The snapshot writer remains the only
    /// projection compiler; this adapter only transports its exact file bytes.
    @discardableResult
    func publishMobileSnapshotStatus(
        groups: Set<NAMobileSnapshotGroup>,
        snapshotDirectory: URL
    ) async -> Bool {
        guard let deviceTransport, !groups.isEmpty else { return false }
        var allSucceeded = true
        for group in NAMobileSnapshotGroup.allCases where groups.contains(group) {
            do {
                var files: [String: Data] = [:]
                for filename in group.filenames {
                    let url = snapshotDirectory.appendingPathComponent(filename)
                    if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                        files[filename] = data
                    }
                }
                guard !files.isEmpty else { continue }
                let value = try NAMobileSnapshotStatusCodec.encode(
                    group: group,
                    files: files
                )
                if lastPublishedMobileSnapshotStatus[group] == value {
                    continue
                }
                try await deviceTransport.setStatus(
                    key: group.statusKey,
                    value: value
                )
                lastPublishedMobileSnapshotStatus[group] = value
            } catch {
                allSucceeded = false
                NSLog(
                    "[iCloudBridge] mobile snapshot %@ publication failed: %@",
                    group.rawValue,
                    error.localizedDescription
                )
            }
        }
        return allSucceeded
    }

    @discardableResult
    func sendKVSChatProgress(
        text: String,
        sessionID: String,
        correlationID: String,
        metadata: [String: String]
    ) async -> Bool {
        var compactMetadata = metadata.mapValues { String($0.prefix(240)) }
        compactMetadata["ephemeral"] = "true"
        compactMetadata["transport"] = compactMetadata["transport"] ?? "icloud"
        compactMetadata["source"] = compactMetadata["source"] ?? "mac"

        let unsigned = BridgeMessage.make(
            sender: "mac",
            text: String(text.prefix(240)),
            sessionID: sessionID,
            correlationID: correlationID,
            metadata: compactMetadata
        )
        let secret = PairingSecretManager.loadOrGenerateSecret()
        let msg: BridgeMessage
        do {
            msg = try unsigned.signed(with: secret)
        } catch {
            NSLog("[iCloudBridge] failed to sign KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(msg)
        } catch {
            NSLog("[iCloudBridge] failed to encode KVS progress msg=%@: %@", correlationID, "\(error)")
            return false
        }

        let delivered = await withCKTimeout("iCloudBridge.sendKVSChatProgress", seconds: 3) {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.set(data, forKey: KVSKey.chatProgressLatest)
            return kvs.synchronize()
        } ?? false

        if delivered {
            lastSyncAt = Date()
            syncStatus = "Progress sent via iCloud KVS"
        } else {
            NSLog("[iCloudBridge] KVS progress sync did not complete msg=%@", correlationID)
        }
        return delivered
    }

    func observeStatusKey(_ key: String, onChange: @escaping (String) -> Void) {
        // Handled in kvsDidChange; register per-key handlers via a dict in a full impl.
        // For v1, callers can observe `available` and `syncStatus` @Published props.
        _ = key; _ = onChange  // placeholder — extend in v2
    }

    // MARK: - Observe incoming messages from iOS (Drive)

    func observeIncomingMessages(onMessage: @escaping (BridgeMessage) async -> Bool) {
        // N-dedup fix: replace rather than append. A teardown→setup retry (or any
        // second call) previously stacked handlers, so each iOS message was
        // forwarded to the daemon once PER accumulated handler → duplicate turns.
        // There is exactly one logical forwarder, so idempotent single-slot
        // registration is correct.
        messageHandlers = [onMessage]
        // CK-3b: with CloudKit active, the forwarder is already registered (at
        // transport birth in applyContainerResult); just re-drain to pull
        // anything that arrived before this handler existed. Live push→drain
        // wakeups are CK-3c. The legacy Drive scan runs otherwise.
        if let ck = deviceTransport {
            Task { await ck.drainIncoming() }
            return
        }
        checkIosOutbox()
    }

    /// CK-3b: validate + forward a message pulled from the CloudKit transport,
    /// mirroring `scanIosOutboxFiles`' checks. Returns true when the message is
    /// HANDLED (delivered OR permanently rejected) so the transport advances its
    /// cursor; false only when transiently undeliverable (runtime unavailable) so
    /// the transport re-delivers next drain (the halt-on-undelivered contract).
    @MainActor
    private func handleIncomingFromTransport(_ msg: BridgeMessage) async -> Bool {
        // Already handled (persistent seen-set; the transport also dedups by id).
        if seenMessageIDs.contains(msg.id) { return true }
        let secret = PairingSecretManager.loadOrGenerateSecret()
        // HMAC — a CK record is no more trusted than a Drive file. Verify or drop.
        // (Full resync self-heal parity — republish secret + resync hint — is a
        // follow-up; it needs pairing-over-CK wired first. Drop+log is secure.)
        if msg.signature == nil || !msg.verifySignature(secret: secret) {
            NSLog("[iCloudBridge] dropping iOS→Mac CK msg %@: bad signature", msg.id)
            recordSeenMessageID(msg.id)
            return true  // consume — permanently bad, do not retry
        }
        let messageAge = Date().timeIntervalSince(msg.timestamp)
        if messageAge > 24 * 60 * 60 || messageAge < -15 * 60 {
            NSLog("[iCloudBridge] dropping iOS→Mac CK msg %@: stale timestamp", msg.id)
            recordSeenMessageID(msg.id)
            return true  // consume
        }
        if msg.metadata?["kind"] == "icloud_action" {
            let handled = await MacSyncEngine.shared.processCloudKitActionMessage(msg)
            if handled {
                recordSeenMessageID(msg.id)
                persistCKSeenIDs()
                lastSyncAt = Date()
                syncStatus = "Processed iPhone action (CloudKit)"
            }
            return handled
        }
        do {
            try await SignedPeerEvidenceStore.record(
                eventID: msg.id,
                channel: .chat,
                peerCreatedAt: msg.timestamp,
                dataRoot: NativeAgentPaths.dataRoot
            )
        } catch {
            NSLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                  msg.id, error.localizedDescription)
        }
        var delivered = false
        for handler in messageHandlers {
            if await handler(msg) { delivered = true }
        }
        if delivered {
            recordSeenMessageID(msg.id)
            // CK-3c: persist the CK-consumed id so a restart within the cursor's
            // 30s clock-skew re-pull window doesn't re-deliver it (gpt-5.5 CK-3c
            // review P1). Synchronous UserDefaults (ordered on the main actor,
            // atomic) — NOT a detached file write, which could reorder two rapid
            // saves or not flush before exit. Mirrors the iOS bridge's approach;
            // merged back into the seen-set on setup. Only the DELIVERED branch
            // needs it (a re-dropped bad-sig/stale is harmless).
            persistCKSeenIDs()
            lastSyncAt = Date()
            syncStatus = "Received message from iOS (CloudKit)"
            return true
        }
        syncStatus = "iPhone message waiting — Mac runtime unavailable"
        return false  // transient — retry next drain
    }

    /// CK-3c: drain the CloudKit transport (incoming + pairing + status) if it is
    /// active; no-op when nil (flag-off). Single-flight — overlapping triggers
    /// (poll timer, initial observe, future push) coalesce into at most one queued
    /// re-run, so they don't fire redundant CloudKit round-trips. Per-message
    /// delivery is already atomic in the transport (claimIfUnseen), so this is an
    /// efficiency guard, not a correctness one. Returns true if any incoming
    /// message was dispatched.
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

    // MARK: - Poll / flush iOS outbox (called by metadata query or on-demand)

    func checkIosOutbox() {
        guard let docsURL = driveURL else { return }
        guard !messageHandlers.isEmpty else {
            syncStatus = "iPhone message waiting — starting Mac receiver"
            return
        }
        if outboxScanInFlight {
            outboxScanQueued = true
            return
        }
        outboxScanInFlight = true
        let seenSnapshot = seenMessageIDs
        let inFlightSnapshot = inFlightIncomingMessageIDs
        let secret = PairingSecretManager.loadOrGenerateSecret()
        outboxScanTask = Task.detached(priority: .utility) { [docsURL, seenSnapshot, inFlightSnapshot, secret] in
            let scan = Self.scanIosOutboxFiles(
                docsURL: docsURL,
                seenMessageIDs: seenSnapshot,
                inFlightMessageIDs: inFlightSnapshot,
                secret: secret
            )
            await MainActor.run {
                self.outboxScanInFlight = false
                defer {
                    if self.outboxScanQueued {
                        self.outboxScanQueued = false
                        self.checkIosOutbox()
                    }
                }
                guard !Task.isCancelled else { return }
                for rejection in scan.rejections {
                    Task { @MainActor in
                        _ = try? await self.sendChatMessage(
                            text: rejection.text,
                            sessionID: rejection.sessionID,
                            correlationID: rejection.correlationID,
                            metadata: [
                                "kind": "rejection",
                                "reason": rejection.reason,
                                "targetSourceKey": rejection.targetSourceKey,
                            ]
                        )
                        // Phase 14e-iCloud HMAC self-heal: when the rejection
                        // was a signature mismatch, force-publish the current
                        // secret (bumps pairing_secret_version) and queue an
                        // UNSIGNED signature_invalid_resync hint to iOS so it
                        // can refresh its cached secret and retry. The hint is
                        // unsigned by design — signing it with the Mac secret
                        // would just hit the same mismatch on iOS.
                        if rejection.reason == "signature_invalid" {
                            await PairingSecretManager.publishMaterialToKVS(forceBumpVersion: true)
                            try? await self.sendUnsignedResyncHint(
                                correlationID: rejection.correlationID,
                                targetSourceKey: rejection.targetSourceKey
                            )
                        }
                    }
                }
                for id in scan.seenIDs {
                    self.recordSeenMessageID(id)
                }
                if !scan.seenIDs.isEmpty {
                    let idsSnapshot = self.seenMessageIDsOrdered
                    Task.detached(priority: .utility) { [idsSnapshot, docsURL] in
                        Self.saveProcessedMessageIDs(idsSnapshot, docsURL: docsURL)
                    }
                }
                guard !scan.messages.isEmpty else { return }
                self.lastSyncAt = Date()
                self.syncStatus = "Received message from iOS"
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
                let backlog = scan.messages
                Task { @MainActor in
                    for pending in backlog {
                        guard !self.inFlightIncomingMessageIDs.contains(pending.message.id) else { continue }
                        self.inFlightIncomingMessageIDs.insert(pending.message.id)
                        defer {
                            self.inFlightIncomingMessageIDs.remove(pending.message.id)
                        }
                        do {
                            try await SignedPeerEvidenceStore.record(
                                eventID: pending.message.id,
                                channel: .chat,
                                peerCreatedAt: pending.message.timestamp,
                                dataRoot: NativeAgentPaths.dataRoot
                            )
                        } catch {
                            NSLog("[iCloudBridge] could not persist signed peer evidence for %@: %@",
                                  pending.message.id, error.localizedDescription)
                        }
                        var delivered = false
                        for handler in self.messageHandlers {
                            if await handler(pending.message) {
                                delivered = true
                            }
                        }
                        if delivered {
                            await self.markIosMessageProcessed(pending, docsURL: docsURL)
                        } else {
                            self.syncStatus = "iPhone message waiting — Mac runtime unavailable"
                        }
                    }
                }
            }
        }
    }

    private struct OutboxRejection {
        var text: String
        var sessionID: String?
        var correlationID: String
        var reason: String
        var targetSourceKey: String
    }

    private struct PendingOutboxMessage: Sendable {
        var message: BridgeMessage
        var fileURL: URL
    }

    nonisolated private static func processedMessageIDsURL(docsURL: URL) -> URL {
        docsURL
            .appendingPathComponent(DriveFolder.processed)
            .appendingPathComponent("ios_chat_processed_ids.json")
    }

    // fix-2026-06-10 sync-audit #2: load/save the ORDERED id array (oldest →
    // newest) so eviction is insertion-ordered, not the old lexicographic
    // .sorted().suffix() which evicted age-randomly.
    nonisolated private static func loadProcessedMessageIDs(docsURL: URL) -> [String] {
        let url = processedMessageIDsURL(docsURL: docsURL)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    nonisolated private static func saveProcessedMessageIDs(_ ids: [String], docsURL: URL) {
        let url = processedMessageIDsURL(docsURL: docsURL)
        let capped = Array(ids.suffix(seenMessageIDsCap))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func markIosMessageProcessed(_ pending: PendingOutboxMessage, docsURL: URL) async {
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        recordSeenMessageID(pending.message.id)
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
        syncStatus = "iPhone message delivered"
    }

    nonisolated private static func scanIosOutboxFiles(
        docsURL: URL,
        seenMessageIDs: Set<String>,
        inFlightMessageIDs: Set<String>,
        secret: Data
    ) -> (messages: [PendingOutboxMessage], rejections: [OutboxRejection], seenIDs: [String]) {
        let iosOutbox = docsURL.appendingPathComponent(DriveFolder.outboxIos)
        let processingDir = docsURL.appendingPathComponent(DriveFolder.processing)
        let processedDir = docsURL.appendingPathComponent(DriveFolder.processed)
        let fm = FileManager.default
        var messages: [PendingOutboxMessage] = []
        var rejections: [OutboxRejection] = []
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

            // Require HMAC on chat as well as action sync. Without this, a file
            // dropped into iCloud Drive could bypass the signed action channel
            // and still reach the Mac chat runtime.
            if msg.signature == nil || !msg.verifySignature(secret: secret) {
                // Phase 14e-iCloud HMAC self-heal: warn (not silent), surface
                // back to iOS as a signature_invalid_resync hint so iOS can
                // refresh its cached secret from KVS and retry. The handler
                // also re-publishes the secret with a bumped pairing_secret_version
                // so iOS observes the change and re-reads.
                print("[iCloudBridge] dropping iOS→Mac msg \(msg.id): bad signature; resync sent")
                let targetSourceKey = msg.metadata?["sourceKey"] ?? ""
                rejections.append(OutboxRejection(
                    text: "iPhone message rejected: missing or bad signature. Re-pair this iPhone with the current Mac app.",
                    sessionID: msg.sessionID,
                    correlationID: msg.id,
                    reason: "signature_invalid",
                    targetSourceKey: targetSourceKey
                ))
                seenIDs.append(msg.id)
                let dest = processedDir.appendingPathComponent(currentURL.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }
            let messageAge = Date().timeIntervalSince(msg.timestamp)
            if messageAge > 24 * 60 * 60 || messageAge < -15 * 60 {
                NSLog("[iCloudBridge] dropping iOS→Mac message %@: stale timestamp", msg.id)
                let targetSourceKey = msg.metadata?["sourceKey"] ?? ""
                rejections.append(OutboxRejection(
                    text: "iPhone message rejected: stale timestamp. Check both devices' clocks and try again.",
                    sessionID: msg.sessionID,
                    correlationID: msg.id,
                    reason: "stale_timestamp",
                    targetSourceKey: targetSourceKey
                ))
                seenIDs.append(msg.id)
                let dest = processedDir.appendingPathComponent(currentURL.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.moveItem(at: currentURL, to: dest)
                continue
            }

            messages.append(PendingOutboxMessage(message: msg, fileURL: currentURL))
        }
        return (messages, rejections, seenIDs)
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
        Task { @MainActor in
            self.metadataQuery?.disableUpdates()
            self.checkIosOutbox()
            self.metadataQuery?.enableUpdates()
        }
    }

    // MARK: - KVS change handler

    @objc private nonisolated func kvsDidChange(_ note: Notification) {
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        Task { @MainActor in
            if let changed = changedKeys, changed.contains(KVSKey.newMessageInDrive) {
                self.syncStatus = "KVS trigger received — checking Drive…"
                self.checkIosOutbox()
            }
        }
    }

    // MARK: - Cleanup

    func tearDown() {
        // Cancel + invalidate any in-flight container resolve so a late
        // applyContainerResult can't re-register observers after teardown.
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        messageHandlers = []
        deviceTransport = nil  // CK-3b: drop the transport; setup() re-resolves it
        cloudKitVisualNotificationPeerReady = false
        lastPublishedProviderCatalogStatus = nil
        lastPublishedMobileSnapshotStatus = [:]
        deviceDrainTimerTask?.cancel()  // CK-3c: stop the poll
        deviceDrainTimerTask = nil
        deviceDrainInFlight = false
        deviceDrainQueued = false
        // N8 fix (R16): reset isSetUp so a subsequent setup() call can succeed.
        // Without this, tearDown() left isSetUp=true and setup() returned early
        // at the guard-!isSetUp check, leaving the bridge permanently stopped.
        isSetUp = false
        // PATCH-2026-05-07: ios-parity stop sync engine
        Task { @MainActor in MacSyncEngine.shared.stop() }
    }
}

// BridgeError is now in NativeAgentShared.
