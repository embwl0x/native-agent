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
    @Published var skills: [SkillRecord] = []
    @Published var memories: [MemoryRecord] = []
    @Published var memoryProposals: [MemoryProposalRecord] = []
    @Published var trainingProposals: [TrainingProposalSummary] = []
    @Published var promotionCandidates: [PromotionCandidateSummary] = []
    @Published var trustPolicy: TrustPolicy?
    // R25 (2026-07-02): personality.json now carries the real native
    // NativeClient.getPersonality() profile (shared PersonalityProfile type,
    // typed encode) — the daemon-era raw-bytes note and the `{}` stub are gone.
    @Published var personality: PersonalityProfile?
    @Published var sessions: [ChatSession] = []
    @Published var pinnedChatSessions: [ChatSession] = []
    @Published var chatTranscripts: [String: [ChatMessageRecord]] = [:]
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
    @Published var syncError: String?
    var inboxSnapshotLoaded = false

    var agentDisplayName: String {
        NativeAgentIdentity.displayName(personality?.name)
    }

    // MARK: - Private

    let kvs = NSUbiquitousKeyValueStore.default
    var snapshotDir: URL?
    var prefersCloudKitSnapshotCache = false
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
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notSetup:         return "iCloud sync not initialized. Enable iCloud Drive and reconnect."
        case .notSigned:        return "iCloud sync paused — pairing key not configured. Scan the QR code from Mac Settings → Pair iPhone / iPad."
        case .timeout(let msg): return msg
        case .persistence(let msg): return msg
        case .busy(let msg):    return msg
        case .unsupported(let msg): return msg
        }
    }
}
