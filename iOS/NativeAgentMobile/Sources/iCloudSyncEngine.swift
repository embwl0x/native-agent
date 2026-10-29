// Phone snapshot projection and signed action submission to MacSyncEngine.

import CryptoKit
import AppIntents
import Foundation
import SwiftUI
import Observation
import NativeAgentShared

// MARK: - Inbox action envelope (iOS → Mac)

typealias InboxAction = NativeAgentShared.InboxAction

extension InboxAction {
    static func make(action: String, payload: [String: String]) -> InboxAction {
        InboxAction(
            msgId: UUID().uuidString,
            clientId: "ios",
            action: action,
            payload: payload,
            createdAt: NativeTimestampFormat.plainZulu(Date()),
            protocolVersion: 2,
            transactionId: UUID().uuidString,
            signature: nil
        )
    }
}

/// The Mac's capture revision travels with the bytes it describes. Phone
/// request/arrival order is never the age of that snapshot.
struct MacSnapshotRead<Value: Decodable & Sendable>: Decodable, Sendable {
    let revision: Double
    let value: Value
}

// MARK: - iCloudSyncEngine

/// The last agent name this phone heard, kept only for the pairing that
/// delivered it. The key is a fingerprint of the pairing secret (a different
/// Mac or Apple Account pairs with a different secret), never the secret.
/// Unpaired, or paired to someone else, the name is dropped, not shown.
enum AgentNameCache {
    private static let nameKey = SharedChatInbox.identityNameKey
    private static let pairingKey = SharedChatInbox.identityPairingKey

    static func fingerprint(_ secret: Data?) -> String? {
        guard let secret, !secret.isEmpty else { return nil }
        return SHA256.hash(data: secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func remember(_ name: String, pairing secret: Data?, defaults: UserDefaults? = SharedChatInbox.identityDefaults) {
        guard let fingerprint = fingerprint(secret), let defaults else { return }
        defaults.set(name, forKey: nameKey)
        defaults.set(fingerprint, forKey: pairingKey)
        CommunicationNotification.remember(name: name, pairing: fingerprint)
    }

    /// The remembered name when it belongs to this pairing. A different
    /// pairing clears it. No secret in hand (unpaired, or the Keychain still
    /// locked at launch) shows nothing and keeps it; `forget` runs when the
    /// pairing is known to be gone.
    static func name(pairing secret: Data?, defaults: UserDefaults? = SharedChatInbox.identityDefaults) -> String? {
        guard let defaults, let name = defaults.string(forKey: nameKey), let fingerprint = fingerprint(secret) else { return nil }
        guard defaults.string(forKey: pairingKey) == fingerprint else {
            forget(defaults: defaults)
            return nil
        }
        CommunicationNotification.remember(name: name, pairing: fingerprint)
        return name
    }

    static func forget(defaults: UserDefaults? = SharedChatInbox.identityDefaults) {
        defaults?.removeObject(forKey: nameKey)
        defaults?.removeObject(forKey: pairingKey)
        CommunicationNotification.forget()
    }
}

@MainActor
@Observable
final class iCloudSyncEngine {
    static let shared = iCloudSyncEngine()

    // MARK: - Published snapshots

    var workshopTasks: [WorkshopTaskRecord] = []
    var deskItems: [MobileDeskItem] = []
    var workOverview: WorkOverview?
    var schedulerSnapshot: MobileSchedulerSnapshot?
    var schedulerJobReceiptTimes: [String: Double] = [:]
    var schedulerError: String?
    var appSettingRows: [MobileAppSetting] = []
    var appSettingsLoading = false
    var appSettingsSaving: Set<String> = []
    var appSettingsFailure: String?
    var helperDetails: [UUID: MobileHelperEdit] = [:]
    var agentThreads: [String: MobileAgentThread] = [:]
    /// What the Mac's Desk bounds dropped, as the Mac reported it. nil means no
    /// report was delivered (an older Mac), never "nothing was dropped".
    var deskBounds: MobileDeskProjectionReport?
    /// Complete reading copies of the priority Desk items, carried
    /// automatically beside the compact board so the text that matters can be
    /// read away from the Mac. Keyed by Desk handle.
    var deskReadingCopies: [String: MobileDeskItemReadingCopy] = [:]
    var skills: [SkillManifestEntry] = []
    var tools: [MobileToolCatalogRecord] = []
    var knowledgeGraph: KGEntityResponse?
    var memories: [MemoryRecord] = []
    var memoryProposals: [MemoryProposalRecord] = []
    var snapshotReadRevisions: [String: Double] = [:]
    var recordReadbackRevisions: [String: [String: Double]] = [:]
    var trustPolicy: TrustPolicy?
    // Mac personality.json decodes as the shared PersonalityProfile.
    private(set) var personality: PersonalityProfile?
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
        if fingerprint == nil { AgentNameCache.forget() }
        else { _ = AgentNameCache.name(pairing: secret) }
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
        appSettingsRead.write { appSettingRows = [] }
        appSettingsFailure = nil
        helperDetails = [:]
        agentThreads = [:]
        PhoneTurnActivity.shared.workCorrelations = [:]
        deskBounds = nil
        deskReadingCopies = [:]
        skills = []
        tools = []
        knowledgeGraph = nil
        memories = []
        memoryProposals = []
        snapshotReadRevisions = [:]
        snapshotHealth = [:]
        recordReadbackRevisions = [:]
        trustPolicy = nil
        personalityPairing = nil
        personality = nil
        sessions = []
        helpersSnapshot = nil
        surfaceLayout = nil
        sessionNavigation = nil
        chatTranscripts = [:]
        health = nil
        organismLivingStatus = nil
        runs = []
        connectors = []
        telegram = nil
        providers = []
        providerSignIns = [:]
        surfaceModels = [:]
        surfaceModelRevisions = [:]
        approvals = []
        inboxItems = []
        turnSummaries = nil
        lastSyncAt = nil
        groupTransportDeliveryAt = Self.loadGroupDeliveryClocks(pairing: fingerprint)
        staleSnapshotGroups = [:]
        syncError = nil
        inboxSnapshotLoaded = false
        approvalsSnapshotLoaded = false
        memoryProposalsSnapshotLoaded = false
        NativeAgentMobileShortcuts.updateAppShortcutParameters()
    }
    var sessions: [ChatSession] = []
    var helpersSnapshot: MobileHelpersSnapshot?
    /// The Mac's layout (ui/layout.json, in the core snapshot); More draws its sections from it.
    var surfaceLayout: SurfaceLayout?
    var sessionNavigation: ChatSessionNavigation?
    var pinnedChatSessions: [ChatSession] { sessionNavigation?.rows.filter(\.isPinned).map(\.session) ?? [] }
    var chatAnchor: ConversationAnchorPin? { sessionNavigation?.anchor }
    var chatTranscripts: [String: PublishedTranscript] = [:]
    var health: RuntimeHealth?
    var organismLivingStatus: OrganismLivingStatusFile?
    // Mac heavy snapshots publish the newest 50 runs in runs.json.
    var runs: [RunRecord] = []
    var connectors: [MobileConnectorSnapshot] = []
    var telegram: MobileTelegramSnapshot?
    // MacSyncEngine publishes providers.json.
    var providers: [ProviderInfo] = []
    var providerSignIns: [String: [String: String]] = [:]
    var surfaceModels: [String: NAProviderSurfaceSelection] = [:]
    var surfaceModelRevisions: [String: Double] = [:]
    var approvals: [ApprovalRequest] = []
    var inboxItems: [InboxItemRecord] = []
    // Read-only per-turn summaries from the Mac snapshot lane.
    var turnSummaries: TurnSummaryFile?
    var lastSyncAt: Date?
    var foregroundSnapshotGroup: NAMobileSnapshotGroup = .chat
    /// Persisted delivery times by NAMobileSnapshotGroup.rawValue; each screen reads its own group.
    /// lastSyncAt measures local cache reads, not transport delivery.
    var groupTransportDeliveryAt: [String: Date] = [:]

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
    /// Group → reason the Mac could not rebuild it; these rows remain stale regardless of sync time.
    var staleSnapshotGroups: [String: String] = [:]
    var syncError: String?
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
    var inboxDir: URL?
    var responsesDir: URL?
    var transactionDir: URL?
    var isSetUp = false
    var refreshInFlight = false
    var refreshQueued = false
    var fullRefreshQueued = false
    var transportDeliveryQueued = false
    /// Invalidates reads/cache writes across teardown or transport root changes.
    var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored let snapshotRead = LatestRead()
    var snapshotHealth: [String: SnapshotReadHealth] = [:]
    @ObservationIgnored let workshopRead = LatestRead()
    @ObservationIgnored let memoryRead = LatestRead()
    @ObservationIgnored let inboxRead = LatestRead()
    @ObservationIgnored let deskRead = LatestRead()
    @ObservationIgnored let approvalsRead = LatestRead()
    @ObservationIgnored let transcriptsRead = LatestRead()
    @ObservationIgnored let sessionListRead = LatestRead()
    @ObservationIgnored let appSettingsRead = LatestRead()
    /// Injected by the app after PairingStore is created. Used to sign outgoing inbox messages.
    var pairingStore: PairingStore? {
        didSet { invalidateSnapshots(pairing: pairingStore?.iCloudPairingSecret) }
    }

    // The main actor serializes admission by transaction. Independent actions
    // (especially Stop) can submit together; repair waits for all active sends.
    var sendingTransactions: Set<String> = []

    // Transaction persistence is part of sendAction's acceptance boundary.
    // Coordinated iCloud I/O is synchronous and can stall, so every ledger
    // transition races a finite deadline before send ownership is released.
    var transactionWriteTimeoutSeconds: TimeInterval = 5

    init(personality: PersonalityProfile? = nil) { self.personality = personality }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notSetup
    case notSigned
    case timeout(String)
    case responseUnconfirmed(String)
    case persistence(String)
    /// Submission conflicts with an active transaction or connection repair.
    case busy(String)
    /// The signed request reached the Mac but its effect is still held by the
    /// canonical approval owner. This is neither success nor a retryable
    /// transport failure.
    case approvalRequired(String, approvalID: String? = nil)
    case unsupported(String)
    case macRejected(String)
    /// The action never reached the Mac: a definite failure, unlike the
    /// unconfirmed outcome `.responseUnconfirmed` stands for.
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSetup:         return "iCloud sync not initialized. Enable iCloud Drive and reconnect."
        case .notSigned:        return IOSPairingPresentation.notSignedSyncMessage
        case .timeout(let msg), .responseUnconfirmed(let msg): return msg
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
