
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
    let pageSessions = FacePageSessions()

    // MARK: - Published snapshots

    var workOverview: WorkOverview?
    var agentThreads: [String: MobileAgentThread] = [:]
    var skills: [SkillManifestEntry] = []
    var tools: [MobileToolCatalogRecord] = []
    var knowledgeGraph: KGEntityResponse?
    var memoryProposals: [MemoryProposalRecord] = []
    var snapshotReadRevisions: [String: Double] = [:]
    var recordReadbackRevisions: [String: [String: Double]] = [:]
    var trustPolicy: TrustPolicy?
    private(set) var personality: PersonalityProfile?
    var voicePreference: MobileVoicePreference?
    private var personalityPairing: String?
    private var snapshotPairing: String?

    /// Bind CloudKit cache bytes to one pairing; never adopt unscoped files across pairing changes or relaunch.
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
        if snapshotDir != nil {
            snapshotDir = cloudKitSnapshotCacheDirectory(pairing: secret)
        }
        workOverview = nil
        faces = [:]
        agentThreads = [:]
        PhoneTurnActivity.shared.workCorrelations = [:]
        skills = []
        tools = []
        knowledgeGraph = nil
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
        cloudKitCatchUpFailure = nil
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
    /// Retain the completed read's cause until catch-up succeeds or the connection is reset.
    var cloudKitCatchUpFailure: DeviceSyncError?
    private var snapshotSyncError: String?
    var syncError: String? {
        get {
            let catchUpError = cloudKitCatchUpFailure.map { "Mac updates could not be read: \($0.localizedDescription)" }
            let errors = [snapshotSyncError, catchUpError].compactMap { $0 }
            return errors.isEmpty ? nil : errors.joined(separator: "\n")
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

    var snapshotDir: URL?
    var responsesDir: URL?
    var transactionDir: URL?
    var isSetUp = false
    var refreshInFlight = false
    var refreshQueued = false
    /// Invalidates reads/cache writes across teardown or transport root changes.
    var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored let snapshotRead = LatestRead()
    @ObservationIgnored let organismRead = LatestRead()
    @ObservationIgnored let telegramRead = LatestRead()
    @ObservationIgnored let trustRead = LatestRead()
    var snapshotHealth: [String: SnapshotReadHealth] = [:]
    @ObservationIgnored let memoryRead = LatestRead()
    @ObservationIgnored let inboxRead = LatestRead()
    @ObservationIgnored let deskRead = LatestRead()
    @ObservationIgnored let approvalsRead = LatestRead()
    @ObservationIgnored let transcriptsRead = LatestRead()
    @ObservationIgnored let sessionListRead = LatestRead()
    var pairingStore: PairingStore? {
        didSet { invalidateSnapshots(pairing: pairingStore?.iCloudPairingSecret) }
    }

    // Serialize transaction admission on MainActor; independent actions including Stop may overlap, while repair waits for active sends.
    var sendingTransactions: Set<String> = []

    // Ledger persistence is part of send acceptance; bound synchronous coordinated-I/O waits before releasing send ownership.

    init(personality: PersonalityProfile? = nil) { self.personality = personality }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notSetup
    case notSigned
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
        case .notSetup:         return "iCloud sync not initialized. Reconnect to CloudKit."
        case .notSigned:        return IOSPairingPresentation.notSignedSyncMessage
        case .responseUnconfirmed(let msg): return msg
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
