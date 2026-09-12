// PATCH-2026-05-07: ios-parity iCloudSyncEngine — snapshot reader + inbox writer for iOS
// Architecture:
//   READ:  iCloud Drive `snapshots/*.json` — Mac's SnapshotWriter keeps these fresh.
//          KVS key `snapshot_updated` pings iOS when a snapshot changes.
//   WRITE: iOS drops an action envelope into `inbox/<msg_id>.json`.
//          Mac's MacSyncEngine picks it up, dispatches into the Swift runtime, writes response to
//          `responses/<msg_id>.json`. iOS polls KVS key `inbox_response_<msg_id>` for the reply.

import CryptoKit
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

@MainActor
final class iCloudSyncEngine: ObservableObject {
    static let shared = iCloudSyncEngine()

    // MARK: - Published snapshots

    @Published var workshopTasks: [WorkshopTaskRecord] = []
    @Published var deskItems: [MobileDeskItem] = []
    /// What the Mac's Desk bounds dropped, as the Mac reported it. nil means no
    /// report was delivered (an older Mac), never "nothing was dropped".
    @Published var deskBounds: MobileDeskProjectionReport?
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
    @Published var personality: PersonalityProfile?
    @Published var sessions: [ChatSession] = []
    @Published var pinnedChatSessions: [ChatSession] = []
    /// The conversation anchor the Mac published beside `sessions.json` — the
    /// session the human is currently active in on a direct remote surface.
    /// Read-only on the phone: it is merged into the tab strip and defaulted to,
    /// never written into anyone's pins and never synced back.
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
    @Published var surfaceModels: [String: SurfaceModelPref] = [:]
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
    @Published var groupTransportDeliveryAt: [String: Date] = iCloudSyncEngine.loadGroupDeliveryClocks()

    private static let groupDeliveryDefaultsKey = "na.sync.groupTransportDeliveryAt.v1"
    private static let legacyDeliveryDefaultsKey = "na.sync.lastTransportDeliveryAt"

    private static func loadGroupDeliveryClocks() -> [String: Date] {
        if let stored = UserDefaults.standard
            .dictionary(forKey: groupDeliveryDefaultsKey) as? [String: Date],
            !stored.isEmpty {
            return stored
        }
        // One-time migration: the single global clock this replaced was a real
        // delivery, so seed every group with it rather than showing every
        // screen as never-delivered after the upgrade.
        guard let legacy = UserDefaults.standard
            .object(forKey: legacyDeliveryDefaultsKey) as? Date else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: NAMobileSnapshotGroup.allCases.map { ($0.rawValue, legacy) }
        )
    }

    /// The newest delivery across all groups — for connection-wide surfaces
    /// only (Settings, Advanced), never for a screen that renders one group.
    var lastTransportDeliveryAt: Date? { groupTransportDeliveryAt.values.max() }

    /// Record a real delivery of these groups. Call ONLY from the transport's
    /// own arrival paths, and only for the groups whose read actually landed.
    func noteTransportDelivery(at date: Date = Date(), groups: Set<NAMobileSnapshotGroup>) {
        for group in groups { groupTransportDeliveryAt[group.rawValue] = date }
        UserDefaults.standard.set(groupTransportDeliveryAt, forKey: Self.groupDeliveryDefaultsKey)
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
    var inboxSnapshotLoaded = false
    /// Per-queue arrival, for the same reason the inbox flag exists: a
    /// provider-catalog update alone sets `lastSyncAt`, so a shared timestamp
    /// is not evidence that these queues were ever read. An empty array before
    /// its own flag is set means "not arrived", never "clear".
    var approvalsSnapshotLoaded = false
    var memoryProposalsSnapshotLoaded = false

    var agentDisplayName: String {
        NativeAgentIdentity.displayName(personality?.name)
    }

    // MARK: - Private

    let kvs = NSUbiquitousKeyValueStore.default
    var snapshotDir: URL?
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
    /// Invalidates reads/cache writes suspended across teardown or a transport
    /// root change. Generation guards on individual lanes handle ordering;
    /// this guard handles ownership replacement.
    var lifecycleGeneration: UInt64 = 0
    var snapshotRefreshGeneration: UInt64 = 0
    // 2026-07-04 (review): generation counter for the TARGETED inbox/activity
    // refreshes (foreground, remote-push, poll loops overlap) — a stale slower
    // read must never clobber a newer one. Shared between refreshInboxSnapshot
    // and refreshActivitySnapshot because both write inboxItems.
    var targetedRefreshGeneration: UInt64 = 0
    /// 2026-07-21 audit fix: per-lane stale-clobber guard for
    /// refreshChatTranscriptsSnapshot (concurrent overlapping reads could
    /// complete out of order, reverting chatTranscripts to an older read).
    var chatTranscriptsRefreshGeneration: UInt64 = 0
    /// 2026-09-06: the same stale-clobber guard for the chat SESSION LIST.
    /// `.onAppear` and the foreground scene-phase path both refresh it, and each
    /// read can block on iCloud download; two overlapping reads could complete
    /// newest-first and leave the phone showing an older sessions/pins/anchor
    /// set than it had already adopted.
    var chatSessionListRefreshGeneration: UInt64 = 0
    // R10-N8: processed IDs are session-only on iOS (in-memory set in caller logic) — Mac persists
    // processed_ids.json with corruption recovery; that is N/A here because iOS never persists this set.

    /// Injected by the app after PairingStore is created. Used to sign outgoing inbox messages.
    var pairingStore: PairingStore?

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
    case approvalRequired(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notSetup:         return "iCloud sync not initialized. Enable iCloud Drive and reconnect."
        case .notSigned:        return IOSPairingPresentation.notSignedSyncMessage
        case .timeout(let msg): return msg
        case .persistence(let msg): return msg
        case .busy(let msg):    return msg
        case .approvalRequired(let msg): return msg
        case .unsupported(let msg): return msg
        }
    }
}
