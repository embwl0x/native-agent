// PATCH-2026-05-07: ios-parity iCloudSyncEngine — snapshot reader + inbox writer for iOS
// Architecture:
//   READ:  iCloud Drive `snapshots/*.json` — Mac's SnapshotWriter keeps these fresh.
//          KVS key `snapshot_updated` pings iOS when a snapshot changes.
//   WRITE: iOS drops an action envelope into `inbox/<msg_id>.json`.
//          Mac's MacSyncEngine picks it up, dispatches into the Swift runtime, writes response to
//          `responses/<msg_id>.json`. iOS polls KVS key `inbox_response_<msg_id>` for the reply.

import CryptoKit
import AppIntents
import Foundation
import SwiftUI
import NativeAgentShared

// MARK: - Inbox action envelope (iOS → Mac)

struct InboxAction: Codable {
    var msgId: String
    var clientId: String           // "ios"
    var action: String             // "submitWorkshopTask", step decisions, approval and memory actions
    var payload: [String: String]  // action-specific key/value pairs
    var createdAt: String
    var protocolVersion: Int?
    var transactionId: String?
    /// HMAC-SHA256 (lowercase hex) over canonical JSON body (keys sorted, "signature" key excluded).
    /// Populated by iCloudSyncEngine.sendAction before writing to iCloud Drive.
    var signature: String?
    var devicePublicKey: String? = nil
    var deviceSignature: String? = nil

    static func make(action: String, payload: [String: String]) -> InboxAction {
        InboxAction(
            msgId: UUID().uuidString,
            clientId: "ios",
            action: action,
            payload: payload,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: 2,
            transactionId: UUID().uuidString,
            signature: nil
        )
    }
}

struct SurfaceModelPref: Equatable, Sendable, Codable {
    var model: String
    var reasoningEffort: String?
    var serviceTier: String?
    var providerId: String? = nil
}

// MARK: - iCloudSyncEngine

/// The last agent name this phone heard, kept only for the pairing that
/// delivered it. The key is a fingerprint of the pairing secret (a different
/// Mac or Apple Account pairs with a different secret), never the secret.
/// Unpaired, or paired to someone else, the name is dropped, not shown.
enum AgentNameCache {
    private static let nameKey = "nativeagent.lastAgentName"
    private static let pairingKey = "nativeagent.lastAgentName.pairing"

    static func fingerprint(_ secret: Data?) -> String? {
        guard let secret, !secret.isEmpty else { return nil }
        return SHA256.hash(data: secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func remember(_ name: String, pairing secret: Data?, defaults: UserDefaults = .standard) {
        guard let fingerprint = fingerprint(secret) else { return }
        defaults.set(name, forKey: nameKey)
        defaults.set(fingerprint, forKey: pairingKey)
        CommunicationNotification.remember(name: name, pairing: fingerprint)
    }

    /// The remembered name when it belongs to this pairing. A different
    /// pairing clears it. No secret in hand (unpaired, or the Keychain still
    /// locked at launch) shows nothing and keeps it; `forget` runs when the
    /// pairing is known to be gone.
    static func name(pairing secret: Data?, defaults: UserDefaults = .standard) -> String? {
        guard let name = defaults.string(forKey: nameKey), let fingerprint = fingerprint(secret) else { return nil }
        guard defaults.string(forKey: pairingKey) == fingerprint else {
            forget(defaults: defaults)
            return nil
        }
        CommunicationNotification.remember(name: name, pairing: fingerprint)
        return name
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: nameKey)
        defaults.removeObject(forKey: pairingKey)
        CommunicationNotification.forget()
    }
}

@MainActor
final class iCloudSyncEngine: ObservableObject {
    static let shared = iCloudSyncEngine()

    // MARK: - Published snapshots

    @Published var workshopTasks: [WorkshopTaskRecord] = []
    @Published var deskItems: [MobileDeskItem] = []
    @Published var workOverview: WorkOverview?
    @Published var schedulerSnapshot: MobileSchedulerSnapshot?
    var schedulerJobReceiptTimes: [String: Double] = [:]
    @Published var schedulerError: String?
    /// What the Mac's Desk bounds dropped, as the Mac reported it. nil means no
    /// report was delivered (an older Mac), never "nothing was dropped".
    @Published var deskBounds: MobileDeskProjectionReport?
    /// Complete reading copies of the priority Desk items, carried
    /// automatically beside the compact board so the text that matters can be
    /// read away from the Mac. Keyed by Desk handle.
    @Published var deskReadingCopies: [String: MobileDeskItemReadingCopy] = [:]
    @Published var skills: [SkillRecord] = []
    @Published var memories: [MemoryRecord] = []
    @Published var memoryProposals: [MemoryProposalRecord] = []
    @Published var trainingProposals: [TrainingProposalSummary] = []
    @Published var promotionCandidates: [PromotionCandidateSummary] = []
    /// Set only after both self-improvement projections arrive together. Empty
    /// arrays before this point mean “not published yet”, not a measured clear
    /// queue on the iPhone.
    @Published var selfImprovementSnapshotPublishedAt: Date?
    @Published var trustPolicy: TrustPolicy?
    // R25 (2026-07-02): personality.json now carries the real native
    // NativeClient.getPersonality() profile (shared PersonalityProfile type,
    // typed encode) — the daemon-era raw-bytes note and the `{}` stub are gone.
    @Published private(set) var personality: PersonalityProfile?
    private var personalityPairing: String?
    private var snapshotPairing: String?

    /// Drive snapshots and local CloudKit bytes belong to one pairing. Never
    /// adopt legacy, unscoped files when pairing changes or after relaunch.
    static func cachedSnapshotDirectory(in directory: URL, pairing secret: Data?) -> URL {
        directory.appendingPathComponent("pairings", isDirectory: true)
            .appendingPathComponent(AgentNameCache.fingerprint(secret) ?? "unpaired", isDirectory: true)
    }

    func applyPersonality(_ profile: PersonalityProfile, pairing secret: Data?) {
        guard let fingerprint = AgentNameCache.fingerprint(secret),
              secret == pairingStore?.iCloudPairingSecret else { return }
        let previousName = personality?.name
        personalityPairing = fingerprint
        personality = profile
        let name = NativeAgentIdentity.displayName(profile.name, fallback: "")
        if !name.isEmpty { AgentNameCache.remember(name, pairing: secret) }
        if previousName != profile.name { NativeAgentMobileShortcuts.updateAppShortcutParameters() }
    }

    func invalidateSnapshots(pairing secret: Data?) {
        let fingerprint = AgentNameCache.fingerprint(secret)
        guard snapshotPairing != fingerprint else { return }
        snapshotPairing = fingerprint
        lifecycleGeneration &+= 1
        refreshInFlight = false
        refreshQueued = false
        fullRefreshQueued = false
        transportDeliveryQueued = false
        if prefersCloudKitSnapshotCache {
            snapshotDir = cloudKitSnapshotCacheDirectory(pairing: secret)
        } else if let driveSnapshotRoot {
            snapshotDir = fingerprint == nil ? nil : Self.cachedSnapshotDirectory(in: driveSnapshotRoot, pairing: secret)
        }
        workshopTasks = []
        deskItems = []
        workOverview = nil
        schedulerSnapshot = nil
        schedulerJobReceiptTimes = [:]
        schedulerError = nil
        deskBounds = nil
        deskReadingCopies = [:]
        skills = []
        memories = []
        memoryProposals = []
        trainingProposals = []
        promotionCandidates = []
        selfImprovementSnapshotPublishedAt = nil
        trustPolicy = nil
        personalityPairing = nil
        personality = nil
        sessions = []
        helpersSnapshot = nil
        pinnedChatSessions = []
        chatAnchor = nil
        chatTranscripts = [:]
        health = nil
        organismLivingStatus = nil
        runs = []
        connectors = []
        providers = []
        providerSignIns = [:]
        surfaceModels = [:]
        pendingPhoneSurfaceModels = [:]
        approvals = []
        inboxItems = []
        turnSummaries = nil
        lastSyncAt = nil
        groupTransportDeliveryAt = Self.loadGroupDeliveryClocks(pairing: fingerprint)
        staleSnapshotGroups = [:]
        syncError = nil
        lastActionSendFailure = nil
        inboxSnapshotLoaded = false
        approvalsSnapshotLoaded = false
        memoryProposalsSnapshotLoaded = false
        NativeAgentMobileShortcuts.updateAppShortcutParameters()
    }
    @Published var sessions: [ChatSession] = []
    @Published var helpersSnapshot: MobileHelpersSnapshot?
    @Published var pinnedChatSessions: [ChatSession] = []
    /// The Mac window's current chat, published beside `sessions.json`.
    /// Main follows it; explicitly opened history keeps its own destination.
    @Published var chatAnchor: ConversationAnchorPin?
    /// 2026-09-06: one published transcript for a session — the rows the Mac
    /// published and the version it published them at, in ONE value. Two
    /// properties would not do: only the rows map is observed, so a republished
    /// empty transcript that differs solely by version would never be
    /// delivered, and an empty transcript is exactly the one that needs its
    /// version looked at.
    struct PublishedTranscript: Equatable {
        var records: [ChatMessageRecord]
        /// The Mac session's transcript version — a counter bumped on every
        /// clear and every transcript write. nil on pre-2026-09-06 Mac builds;
        /// an empty transcript with no version never clears anything.
        var generation: Int?
    }
    @Published var chatTranscripts: [String: PublishedTranscript] = [:]
    @Published var health: RuntimeHealth?
    @Published var organismLivingStatus: OrganismLivingStatusFile?
    // R25: worker/codex runs from runs.json (newest 50, written by the Mac's
    // heavy snapshot pass) — AdvancedView's runs list finally has a source.
    @Published var runs: [RunRecord] = []
    @Published var connectors: [ConnectorRecord] = []
    // PATCH-2026-05-07: leftover-1 providers snapshot — loaded from providers.json written by MacSyncEngine
    @Published var providers: [ProviderInfo] = []
    @Published var providerSignIns: [String: [String: String]] = [:]
    @Published var surfaceModels: [String: SurfaceModelPref] = [:]
    var pendingPhoneSurfaceModels: [UUID: (surface: String, preference: SurfaceModelPref)] = [:]
    @Published var approvals: [ApprovalRequest] = []
    @Published var inboxItems: [InboxItemRecord] = []
    // Turn Inspector W4: read-only per-turn summaries from the Mac snapshot lane.
    @Published var turnSummaries: TurnSummaryFile?
    @Published var lastSyncAt: Date?
    /// When each snapshot GROUP last actually arrived — keyed by
    /// `NAMobileSnapshotGroup.rawValue`. `lastSyncAt` is renewed by every local
    /// cache read (a Desk read renews it without reading Memory), so it is the
    /// age of a local read and NOT the age of delivered rows; and one global
    /// delivery clock was no better, because a Desk delivery made Approvals look
    /// fresh. Every "Fresh" surface reads ITS OWN group through
    /// `transportDeliveryAt(screenGroup:)`. Persisted: a delivery that landed
    /// before this launch still landed.
    @Published var groupTransportDeliveryAt: [String: Date] = [:]

    private static let groupDeliveryDefaultsKey = "na.sync.groupTransportDeliveryAt.v1"
    private static let groupDeliveryPairingDefaultsKey = "na.sync.groupTransportDeliveryAt.pairing"
    private static let legacyDeliveryDefaultsKey = "na.sync.lastTransportDeliveryAt"

    private static func loadGroupDeliveryClocks(pairing: String?) -> [String: Date] {
        guard let pairing,
              UserDefaults.standard.string(forKey: groupDeliveryPairingDefaultsKey) == pairing,
              let stored = UserDefaults.standard.dictionary(forKey: groupDeliveryDefaultsKey) as? [String: Date]
        else { return [:] }
        return stored
    }

    /// The newest delivery across all groups — for connection-wide surfaces
    /// only (Settings, Advanced), never for a screen that renders one group.
    var lastTransportDeliveryAt: Date? { groupTransportDeliveryAt.values.max() }

    func clearConnectionDeliveryHistory() {
        groupTransportDeliveryAt = [:]
        UserDefaults.standard.removeObject(forKey: Self.groupDeliveryDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.groupDeliveryPairingDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDeliveryDefaultsKey)
        lastActionSendFailure = nil
    }

    /// Record a real delivery of these groups. Call ONLY from the transport's
    /// own arrival paths, and only for the groups whose read actually landed.
    func noteTransportDelivery(at date: Date = Date(), groups: Set<NAMobileSnapshotGroup>) {
        guard let pairing = AgentNameCache.fingerprint(pairingStore?.iCloudPairingSecret) else { return }
        for group in groups { groupTransportDeliveryAt[group.rawValue] = date }
        UserDefaults.standard.set(groupTransportDeliveryAt, forKey: Self.groupDeliveryDefaultsKey)
        UserDefaults.standard.set(pairing, forKey: Self.groupDeliveryPairingDefaultsKey)
    }

    /// The delivery age a screen may claim. `screenGroup` is the snapshot group
    /// name a screen renders — the same vocabulary as `staleSnapshotGroups`
    /// ("approvals", "inbox", "memory_proposals", "desk", "runs"…). A name that
    /// maps to more than one delivery group takes the OLDEST of them: a screen
    /// is only as fresh as its stalest input. nil — or a name this build cannot
    /// map — falls back to the newest delivery across groups.
    func transportDeliveryAt(screenGroup: String?) -> Date? {
        let groups = Self.deliveryGroups(forScreenGroup: screenGroup)
        guard !groups.isEmpty else { return lastTransportDeliveryAt }
        var oldest: Date?
        for group in groups {
            guard let at = groupTransportDeliveryAt[group.rawValue] else { return nil }
            oldest = min(oldest ?? at, at)
        }
        return oldest
    }

    /// Screen group name → the transport groups that carry it. The Mac's
    /// per-group names are its snapshot filenames without the extension.
    static func deliveryGroups(forScreenGroup name: String?) -> Set<NAMobileSnapshotGroup> {
        guard let name, !name.isEmpty else { return [] }
        return NAMobileSnapshotGroup.groups(containingAny: ["\(name).json"])
    }
    /// Snapshot groups the Mac could not rebuild on its last pass, group name →
    /// reason (sweep 2026-09-01 item 2). A screen whose group is named here is
    /// rendering rows the Mac already knows are old, however fresh the sync
    /// timestamp looks.
    @Published var staleSnapshotGroups: [String: String] = [:]
    @Published var syncError: String?
    /// Set by `sendActionWithSignatureRetry` on every nil return: the send
    /// error when the action never left the phone, nil when it was sent but
    /// unanswered. Read synchronously by `requireSuccessfulActionResponse`.
    var lastActionSendFailure: String?
    var inboxSnapshotLoaded = false
    /// Per-queue arrival, for the same reason the inbox flag exists: a
    /// provider-catalog update alone sets `lastSyncAt`, so a shared timestamp
    /// is not evidence that these queues were ever read. An empty array before
    /// its own flag is set means "not arrived", never "clear".
    var approvalsSnapshotLoaded = false
    var memoryProposalsSnapshotLoaded = false

    /// The configured name from the Mac; else the last one this phone heard;
    /// the product name only before any name has ever been known.
    var agentDisplayName: String {
        let secret = pairingStore?.iCloudPairingSecret
        let lastKnown = AgentNameCache.name(pairing: secret)
        let currentName = personalityPairing == AgentNameCache.fingerprint(secret) ? personality?.name : nil
        return NativeAgentIdentity.displayName(currentName, fallback: NativeAgentIdentity.displayName(lastKnown))
    }

    // MARK: - Private

    let kvs = NSUbiquitousKeyValueStore.default
    var snapshotDir: URL?
    var driveSnapshotRoot: URL?
    var prefersCloudKitSnapshotCache = false
    /// Production uses Application Support. Tests can supply a disposable
    /// cache root while still exercising the exact decode → atomic write →
    /// refresh path used by the CloudKit status observer.
    var cloudKitSnapshotCacheRootOverride: URL?
    var inboxDir: URL?
    var responsesDir: URL?
    var transactionDir: URL?
    var isSetUp = false
    var refreshInFlight = false
    var refreshQueued = false
    var fullRefreshQueued = false
    var transportDeliveryQueued = false
    /// Invalidates reads/cache writes suspended across teardown or a transport
    /// root change. Generation guards on individual lanes handle ordering;
    /// this guard handles ownership replacement.
    var lifecycleGeneration: UInt64 = 0
    var snapshotRefreshGeneration: UInt64 = 0
    /// Shared by full and targeted Inbox/activity writers so older reads
    /// cannot clobber a lane superseded while they were suspended.
    var targetedRefreshGeneration: UInt64 = 0
    /// Shared by full and targeted writers of the board, bounds and reading copies.
    var deskRefreshGeneration: UInt64 = 0
    /// Shared by full, lightweight and targeted approval writers.
    var approvalsRefreshGeneration: UInt64 = 0
    /// Shared by full and targeted transcript writers.
    var chatTranscriptsRefreshGeneration: UInt64 = 0
    /// Shared by full, lightweight and targeted session/pin/anchor writers.
    var chatSessionListRefreshGeneration: UInt64 = 0
    // R10-N8: processed IDs are session-only on iOS (in-memory set in caller logic) — Mac persists
    // processed_ids.json with corruption recovery; that is N/A here because iOS never persists this set.

    /// Injected by the app after PairingStore is created. Used to sign outgoing inbox messages.
    var pairingStore: PairingStore? {
        didSet { invalidateSnapshots(pairing: pairingStore?.iCloudPairingSecret) }
    }

    // S.4: Prevent concurrent sendAction calls. If a second call arrives while
    // the first is still writing to iCloud Drive the caller gets SyncError.busy.
    var _sendInFlight: Bool = false
    let _sendLock = NSLock()

    // Transaction persistence is part of sendAction's acceptance boundary.
    // Coordinated iCloud I/O is synchronous and can stall, so every ledger
    // transition races a finite deadline before send ownership is released.
    var transactionWriteTimeoutSeconds: TimeInterval = 5
    var transactionWriteTestHook: (@Sendable (_ state: String) throws -> Void)?

    private init() {}
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notSetup
    case notSigned
    case timeout(String)
    case persistence(String)
    /// S.4: A second sendAction arrived while a prior one is still in-flight.
    case busy(String)
    /// The signed request reached the Mac but its effect is still held by the
    /// canonical approval owner. This is neither success nor a retryable
    /// transport failure.
    case approvalRequired(String, approvalID: String? = nil)
    case unsupported(String)
    case macRejected(String)
    /// The action never reached the Mac: a definite failure, unlike the
    /// unconfirmed outcome `.timeout` stands for.
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSetup:         return "iCloud sync not initialized. Enable iCloud Drive and reconnect."
        case .notSigned:        return IOSPairingPresentation.notSignedSyncMessage
        case .timeout(let msg): return msg
        case .persistence(let msg): return msg
        case .busy(let msg):    return msg
        case .approvalRequired(let msg, _): return msg
        case .unsupported(let msg): return msg
        case .macRejected(let msg): return msg
        case .sendFailed(let msg): return msg
        }
    }

    var approvalID: String? {
        if case .approvalRequired(_, let id) = self { return id }
        return nil
    }
}
