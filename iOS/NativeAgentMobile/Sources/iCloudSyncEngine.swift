
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

/// Snapshot age comes from the Mac's capture revision, never phone request/arrival order.
struct MacSnapshotRead<Value: Decodable & Sendable>: Decodable, Sendable {
    let revision: Double
    let value: Value
}

// MARK: - iCloudSyncEngine

/// Retain agent name only for its pairing fingerprint, never the secret; a changed pairing must not show another agent's name.
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

    /// Hide but retain name while key availability is unknown; forget only on checked pairing removal or change.
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
    /// Missing Desk omission metadata means no report arrived, never that nothing was omitted.
    var deskBounds: MobileDeskProjectionReport?
    var deskReadingCopies: [String: MobileDeskItemReadingCopy] = [:]
    var skills: [SkillManifestEntry] = []
    var tools: [MobileToolCatalogRecord] = []
    var knowledgeGraph: KGEntityResponse?
    var memories: [MemoryRecord] = []
    var memoryProposals: [MemoryProposalRecord] = []
    var snapshotReadRevisions: [String: Double] = [:]
    var recordReadbackRevisions: [String: [String: Double]] = [:]
    var trustPolicy: TrustPolicy?
    private(set) var personality: PersonalityProfile?
    var voicePreference: MobileVoicePreference?
    private var personalityPairing: String?
    private var snapshotPairing: String?

    /// Bind Drive and CloudKit cache bytes to one pairing; never adopt unscoped files across pairing changes or relaunch.
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
        if prefersCloudKitSnapshotCache {
            snapshotDir = cloudKitSnapshotCacheDirectory(pairing: secret)
        } else if let driveSnapshotRoot {
            snapshotDir = fingerprint == nil ? nil : Self.cachedSnapshotDirectory(in: driveSnapshotRoot, pairing: secret)
        }
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
        trustRead.write { trustPolicy = nil }
        personalityPairing = nil
        personality = nil
        voicePreference = nil
        sessions = []
        helpersSnapshot = nil
        surfaceLayout = nil
        sessionNavigation = nil
        chatTranscripts = [:]
        health = nil
        organismLivingStatus = nil
        runs = []
        runsSnapshotLoaded = false
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
        cloudKitCatchUpIncomplete = false
        cloudKitCatchUpFailures = 0
        syncError = nil
        inboxSnapshotLoaded = false
        approvalsSnapshotLoaded = false
        memoryProposalsSnapshotLoaded = false
        NativeAgentMobileShortcuts.updateAppShortcutParameters()
    }
    var sessions: [ChatSession] = []
    var helpersSnapshot: MobileHelpersSnapshot?
    var surfaceLayout: SurfaceLayoutAvailability?
    var sessionNavigation: ChatSessionNavigation?
    var pinnedChatSessions: [ChatSession] { sessionNavigation?.rows.filter(\.isPinned).map(\.session) ?? [] }
    var chatAnchor: ConversationAnchorPin? { sessionNavigation?.anchor }
    var chatTranscripts: [String: PublishedTranscript] = [:]
    var health: RuntimeHealth?
    var organismLivingStatus: OrganismLivingStatusFile?
    var runs: [RunRecord] = []
    var runsSnapshotLoaded = false
    var connectors: [MobileConnectorSnapshot] = []
    var telegram: MobileTelegramSnapshot?
    var providers: [ProviderInfo] = []
    var providerSignIns: [String: [String: String]] = [:]
    var surfaceModels: [String: NAProviderSurfaceSelection] = [:]
    var surfaceModelRevisions: [String: Double] = [:]
    var approvals: [ApprovalRequest] = []
    var inboxItems: [InboxItemRecord] = []
    /// Every page's face as the Mac last published it, by page id.
    var faces: [String: PartFaceSnapshot] = [:]
    var turnSummaries: TurnSummaryFile?
    var lastSyncAt: Date?
    var foregroundSnapshotGroup: NAMobileSnapshotGroup = .chat
    /// Track delivery by NAMobileSnapshotGroup.rawValue; lastSyncAt is only a local cache-read time.
    var groupTransportDeliveryAt: [String: Date] = [:]

    private static let groupDeliveryDefaultsKey = "na.sync.groupTransportDeliveryAt.v1"
    private static let groupDeliveryPairingDefaultsKey = "na.sync.groupTransportDeliveryAt.pairing"

    private static func loadGroupDeliveryClocks(pairing: String?) -> [String: Date] {
        guard let pairing,
              UserDefaults.standard.string(forKey: groupDeliveryPairingDefaultsKey) == pairing,
              let stored = UserDefaults.standard.dictionary(forKey: groupDeliveryDefaultsKey) as? [String: Date]
        else { return [:] }
        return stored
    }

    /// Use newest cross-group delivery only for connection-wide surfaces; individual screens need their own groups.
    var lastTransportDeliveryAt: Date? { groupTransportDeliveryAt.values.max() }

    func clearConnectionDeliveryHistory() {
        groupTransportDeliveryAt = [:]
        UserDefaults.standard.removeObject(forKey: Self.groupDeliveryDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.groupDeliveryPairingDefaultsKey)
    }

    /// Renew delivery clocks only from transport arrival and only for groups whose read succeeded.
    func noteTransportDelivery(at date: Date = Date(), groups: Set<NAMobileSnapshotGroup>) {
        guard let pairing = AgentNameCache.fingerprint(pairingStore?.iCloudPairingSecret) else { return }
        for group in groups { groupTransportDeliveryAt[group.rawValue] = date }
        UserDefaults.standard.set(groupTransportDeliveryAt, forKey: Self.groupDeliveryDefaultsKey)
        UserDefaults.standard.set(pairing, forKey: Self.groupDeliveryPairingDefaultsKey)
    }

    /// Use the oldest mapped input for screen freshness; unmapped/connection-wide callers use newest cross-group delivery.
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

    static func deliveryGroups(forScreenGroup name: String?) -> Set<NAMobileSnapshotGroup> {
        guard let name, !name.isEmpty else { return [] }
        return NAMobileSnapshotGroup.groups(containingAny: ["\(name).json"])
    }
    /// Group → reason the Mac could not rebuild it; these rows remain stale regardless of sync time.
    var staleSnapshotGroups: [String: String] = [:]
    /// Coalesced/partial catch-up remains owed until a complete remote pull and successful cache refresh.
    var cloudKitCatchUpIncomplete = false
    /// Warn only after catch-up reads fail twice running: one the next read heals is not the person's news,
    /// and a running read or one merged into the 0.75 s foreground receive remains owed.
    var cloudKitCatchUpFailures = 0
    var cloudKitCatchUpFailed: Bool { cloudKitCatchUpFailures >= 2 }
    private var snapshotSyncError: String?
    var syncError: String? {
        get {
            snapshotSyncError ?? (cloudKitCatchUpFailed
                ? "Mac updates are still catching up. Showing the last received data. Open Connection in Settings to check the Mac link."
                : nil)
        }
        set { snapshotSyncError = newValue }
    }
    var inboxSnapshotLoaded = false
    /// Track queue arrival independently: provider updates advance lastSyncAt without proving empty queues were ever read.
    var approvalsSnapshotLoaded = false
    var memoryProposalsSnapshotLoaded = false

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
    /// Invalidates reads/cache writes across teardown or transport root changes.
    var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored let snapshotRead = LatestRead()
    @ObservationIgnored let trustRead = LatestRead()
    var snapshotHealth: [String: SnapshotReadHealth] = [:]
    @ObservationIgnored let memoryRead = LatestRead()
    @ObservationIgnored let inboxRead = LatestRead()
    @ObservationIgnored let deskRead = LatestRead()
    @ObservationIgnored let approvalsRead = LatestRead()
    @ObservationIgnored let transcriptsRead = LatestRead()
    @ObservationIgnored let sessionListRead = LatestRead()
    @ObservationIgnored let appSettingsRead = LatestRead()
    var pairingStore: PairingStore? {
        didSet { invalidateSnapshots(pairing: pairingStore?.iCloudPairingSecret) }
    }

    // Serialize transaction admission on MainActor; independent actions including Stop may overlap, while repair waits for active sends.
    var sendingTransactions: Set<String> = []

    // Ledger persistence is part of send acceptance; bound synchronous coordinated-I/O waits before releasing send ownership.
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
    case busy(String)
    /// Pending canonical approval is neither success nor retryable transport failure.
    case approvalRequired(String, approvalID: String? = nil)
    case unsupported(String)
    case macRejected(String)
    /// Pre-dispatch refusal cannot settle an earlier retained request; responseUnconfirmed preserves its uncertainty.
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
