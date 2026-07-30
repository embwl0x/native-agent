import CryptoKit
import Foundation

// MARK: - GitHub Command
//
// GitHubCommandStore is the operational owner for tracked GitHub work. Its
// append-only feed is canonical; github_command_state.json is only a derived
// projection. Connector and app layers may supply evidence and perform side
// effects, but they cannot choose or mutate an item's state directly.

public enum GitHubCommandItemKind: String, Codable, Sendable, CaseIterable {
    case pullRequest = "pull_request"
    case issue
}

public enum GitHubCommandActionSignal: String, Codable, Sendable, CaseIterable, Hashable {
    case reviewComment = "review_comment"
    case changesRequested = "changes_requested"
    case ciFailure = "ci_failure"
    case conflict
}

public enum GitHubCommandWaitingKind: String, Codable, Sendable, CaseIterable {
    case review
    case ci
    case maintainer
    case readyToMerge = "ready_to_merge"
}

public enum GitHubCommandAttentionReason: String, Codable, Sendable, CaseIterable {
    case dispatchFailed = "dispatch_failed"
    case codexFailed = "codex_failed"
    case verificationFailed = "verification_failed"
    case verificationReadFailed = "verification_read_failed"
    // A dispatched codex turn that records no callback within the overdue
    // window (a lost/stalled callback). Explicit rawValue keeps the persisted
    // ops feed Codable-stable if the case list is ever reordered.
    case callbackOverdue = "callback_overdue"
    // Retained for decoding snapshots written by the short-lived busy-requeue
    // implementation. Empty terminal turns are outcome-unknown and are no
    // longer routed here or replayed automatically.
    case codexBusy = "codex_busy"
    case stale
    case contradictoryState = "contradictory_state"
}

public enum GitHubCommandStateName: String, Codable, Sendable, CaseIterable {
    case detected
    case needsCodex = "needs_codex"
    case codexWorking = "codex_working"
    case verifying
    case needsUser = "needs_user"
    case waitingUpstream = "waiting_upstream"
    case attention
    case resolved
}

public enum GitHubCommandItemState: Codable, Sendable, Equatable {
    case detected
    case needsCodex
    case codexWorking
    case verifying
    case needsUser
    case waitingUpstream(GitHubCommandWaitingKind)
    case attention(GitHubCommandAttentionReason)
    case resolved

    public var name: GitHubCommandStateName {
        switch self {
        case .detected: return .detected
        case .needsCodex: return .needsCodex
        case .codexWorking: return .codexWorking
        case .verifying: return .verifying
        case .needsUser: return .needsUser
        case .waitingUpstream: return .waitingUpstream
        case .attention: return .attention
        case .resolved: return .resolved
        }
    }

    public var isTerminal: Bool { self == .resolved }

    /// States from which a dispatch RESULT may still transition the item.
    /// Anything else (settled via a late callback, terminal, already working
    /// under another key) treats an arriving dispatch result as stale.
    public var isDispatchPending: Bool {
        switch self {
        case .detected, .needsCodex, .attention(.dispatchFailed), .attention(.verificationFailed):
            return true
        default:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey { case name, kind, reason }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(GitHubCommandStateName.self, forKey: .name) {
        case .detected: self = .detected
        case .needsCodex: self = .needsCodex
        case .codexWorking: self = .codexWorking
        case .verifying: self = .verifying
        case .needsUser: self = .needsUser
        case .waitingUpstream:
            self = .waitingUpstream(try box.decode(GitHubCommandWaitingKind.self, forKey: .kind))
        case .attention:
            self = .attention(try box.decode(GitHubCommandAttentionReason.self, forKey: .reason))
        case .resolved: self = .resolved
        }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(name, forKey: .name)
        if case .waitingUpstream(let kind) = self { try box.encode(kind, forKey: .kind) }
        if case .attention(let reason) = self { try box.encode(reason, forKey: .reason) }
    }
}

public struct GitHubCommandBlocker: Codable, Sendable, Equatable {
    public let detail: String
    public let owner: String

    public init(detail: String, owner: String) {
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Authoritative GraphQL state for one pull-request review thread. The
/// unresolved generation is durable observation-layer identity: resolving a
/// thread preserves it, while a later unresolved transition increments it so
/// the same REST comment can become a genuinely new actionable event.
public struct GitHubCommandReviewThreadEvidence: Codable, Sendable, Equatable {
    public let threadId: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let rootCommentId: Int64?
    public let reviewId: Int64?
    public let unresolvedGeneration: Int

    public init(
        threadId: String,
        isResolved: Bool,
        isOutdated: Bool,
        rootCommentId: Int64? = nil,
        reviewId: Int64? = nil,
        unresolvedGeneration: Int = 0
    ) {
        self.threadId = threadId
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.rootCommentId = rootCommentId
        self.reviewId = reviewId
        self.unresolvedGeneration = unresolvedGeneration
    }

    public var isActionable: Bool { !isResolved && !isOutdated }

    /// Merges two evidence sets into the freshest truth per thread. Lifecycle
    /// order is active g1 < resolved g1 < active g2 < …, so the entry that is
    /// further along wins regardless of which surface recorded it. Used to keep
    /// stored evidence monotonic: a raced refresh carrying stale thread state
    /// must never regress what a callback verification already recorded.
    public static func mergingFreshest(
        _ lhs: [GitHubCommandReviewThreadEvidence]?,
        _ rhs: [GitHubCommandReviewThreadEvidence]?
    ) -> [GitHubCommandReviewThreadEvidence]? {
        if lhs == nil && rhs == nil { return nil }
        var byThread: [String: GitHubCommandReviewThreadEvidence] = [:]
        for thread in (lhs ?? []) + (rhs ?? []) {
            guard let existing = byThread[thread.threadId] else {
                byThread[thread.threadId] = thread
                continue
            }
            let existingOrder = (existing.unresolvedGeneration, existing.isActionable ? 0 : 1)
            let candidateOrder = (thread.unresolvedGeneration, thread.isActionable ? 0 : 1)
            if candidateOrder > existingOrder { byThread[thread.threadId] = thread }
        }
        return Array(byThread.values).sorted { $0.threadId < $1.threadId }
    }
}

/// Bounded, dispatch-ready evidence captured during the canonical GitHub read.
/// GitHub Command hands this resident evidence to temporary Codex cognition so
/// the worker does not have to reconstruct the actionable event from a bare PR
/// number. It is descriptive only; TrustCenter and live GitHub verification
/// retain all write and settlement authority.
public struct GitHubCommandActionEvidence: Codable, Sendable, Equatable {
    public let signal: GitHubCommandActionSignal
    public let identifier: String
    public let summary: String
    public let url: String?
    public let path: String?
    public let line: Int?
    public let author: String?

    public init(
        signal: GitHubCommandActionSignal,
        identifier: String,
        summary: String,
        url: String? = nil,
        path: String? = nil,
        line: Int? = nil,
        author: String? = nil
    ) {
        self.signal = signal
        self.identifier = identifier
        self.summary = summary
        self.url = url
        self.path = path
        self.line = line
        self.author = author
    }
}

public struct GitHubCommandObservation: Codable, Sendable, Equatable {
    public let repository: String
    public let number: Int
    public let kind: GitHubCommandItemKind
    public let title: String
    public let isOpen: Bool
    public let isMerged: Bool
    public let observedVersion: String
    public let actionableEventVersion: String?
    public let signals: Set<GitHubCommandActionSignal>
    public let headSHA: String?
    public let humanDecision: GitHubCommandBlocker?
    public let waitingKind: GitHubCommandWaitingKind
    public let isStale: Bool
    public let finalReceipt: String?
    public let reviewThreads: [GitHubCommandReviewThreadEvidence]?
    public let actionableEvidence: [GitHubCommandActionEvidence]?

    public init(
        repository: String,
        number: Int,
        kind: GitHubCommandItemKind,
        title: String,
        isOpen: Bool,
        isMerged: Bool = false,
        observedVersion: String,
        actionableEventVersion: String? = nil,
        signals: Set<GitHubCommandActionSignal> = [],
        headSHA: String? = nil,
        humanDecision: GitHubCommandBlocker? = nil,
        waitingKind: GitHubCommandWaitingKind = .maintainer,
        isStale: Bool = false,
        finalReceipt: String? = nil,
        reviewThreads: [GitHubCommandReviewThreadEvidence]? = nil,
        actionableEvidence: [GitHubCommandActionEvidence]? = nil
    ) {
        self.repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        self.number = number
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isOpen = isOpen
        self.isMerged = isMerged
        self.observedVersion = observedVersion
        self.actionableEventVersion = actionableEventVersion
        self.signals = signals
        self.headSHA = headSHA
        self.humanDecision = humanDecision
        self.waitingKind = waitingKind
        self.isStale = isStale
        self.finalReceipt = finalReceipt
        self.reviewThreads = reviewThreads
        self.actionableEvidence = actionableEvidence
    }

    public var itemId: String { Self.itemId(repository: repository, number: number) }

    public var actionableEventKey: String? {
        guard !signals.isEmpty, let version = actionableEventVersion, !version.isEmpty else { return nil }
        return "\(itemId)+\(version)"
    }

    public static func itemId(repository: String, number: Int) -> String {
        "\(repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())#\(number)"
    }

    /// Copy with thread evidence merged against what the store already holds,
    /// so a re-observation carrying stale thread state cannot regress evidence
    /// a fresher read (e.g. callback verification) recorded. Signals and event
    /// version stay as observed — a raced refresh loses at most one cycle,
    /// because the next reconciliation seeds from the preserved evidence and
    /// mints the correct generation.
    public func preservingFreshestReviewThreads(
        from prior: GitHubCommandObservation?
    ) -> GitHubCommandObservation {
        let merged = GitHubCommandReviewThreadEvidence.mergingFreshest(
            prior?.reviewThreads, reviewThreads
        )
        guard merged != reviewThreads else { return self }
        return GitHubCommandObservation(
            repository: repository, number: number, kind: kind, title: title,
            isOpen: isOpen, isMerged: isMerged, observedVersion: observedVersion,
            actionableEventVersion: actionableEventVersion, signals: signals,
            headSHA: headSHA, humanDecision: humanDecision, waitingKind: waitingKind,
            isStale: isStale, finalReceipt: finalReceipt, reviewThreads: merged,
            actionableEvidence: actionableEvidence
        )
    }
}

public struct GitHubCommandDispatchIntent: Codable, Sendable, Equatable {
    public let itemId: String
    public let eventKey: String
    public let dispatchId: String
    public let headSHA: String?
    public let attempt: Int
    public let preparedAt: String
}

public struct GitHubCommandDispatchReceipt: Codable, Sendable, Equatable {
    public let eventKey: String
    public let dispatchId: String
    public let messageId: String
    public let queuedAt: String
    public let transport: String
    public let recovered: Bool

    public init(
        eventKey: String,
        dispatchId: String,
        messageId: String,
        queuedAt: String,
        transport: String = "codex_message",
        recovered: Bool = false
    ) {
        self.eventKey = eventKey
        self.dispatchId = dispatchId
        self.messageId = messageId
        self.queuedAt = queuedAt
        self.transport = transport
        self.recovered = recovered
    }
}

public struct GitHubCommandWorkLogEntry: Codable, Sendable, Equatable {
    public let at: String
    public let kind: String
    public let summary: String
    public let messageId: String?
}

public struct GitHubCommandNotificationReceipt: Codable, Sendable, Equatable {
    public let dedupKey: String
    public let deliveredAt: String
    public let status: String
    public let detail: String
}

public enum GitHubCommandNotificationKind: String, Codable, Sendable {
    case success
    case blocker
}

public struct GitHubCommandNotificationIntent: Codable, Sendable, Equatable {
    public let dedupKey: String
    public let itemId: String
    public let kind: GitHubCommandNotificationKind
    public let title: String
    public let body: String
}

public struct GitHubCommandItem: Codable, Sendable, Equatable {
    public let itemId: String
    public var repository: String
    public var number: Int
    public var kind: GitHubCommandItemKind
    public var title: String
    public var state: GitHubCommandItemState
    public var observation: GitHubCommandObservation?
    public var dispatchIntent: GitHubCommandDispatchIntent?
    public var dispatchReceipt: GitHubCommandDispatchReceipt?
    public var workLog: [GitHubCommandWorkLogEntry]
    public var blocker: GitHubCommandBlocker?
    public var finalReceipt: String?
    public var lastCallbackStatus: String?
    // The eventKey that last settled through verification into waiting_upstream.
    // An identical re-observation of an already-settled event must not bounce
    // back into attention; only a NEW actionable event may re-route.
    public var lastSettledEventKey: String?
    public var notificationClaims: [String]
    public var notificationReceipts: [GitHubCommandNotificationReceipt]
    // Consecutive live-read failures during verification. Derived state only
    // (never serialized to ops); optional so any cached snapshot decodes.
    public var verificationReadFailures: Int?
    /// Timestamp of the last semantic motor transition. Generic observation,
    /// notification, and stale-result bookkeeping must not advance it.
    public var motorUpdatedAt: String? = nil
    public var createdAt: String
    public var updatedAt: String
}

public struct GitHubCommandState: Codable, Sendable, Equatable {
    public var items: [GitHubCommandItem]
    public var dispatchedEventKeys: [String]
    public var updatedAt: String?

    public init(items: [GitHubCommandItem] = [], dispatchedEventKeys: [String] = [], updatedAt: String? = nil) {
        self.items = items
        self.dispatchedEventKeys = dispatchedEventKeys
        self.updatedAt = updatedAt
    }

    public func item(_ itemId: String) -> GitHubCommandItem? {
        items.first { $0.itemId == itemId.lowercased() }
    }

    public var nonTerminalItems: [GitHubCommandItem] { items.filter { !$0.state.isTerminal } }

    public func count(in state: GitHubCommandStateName) -> Int {
        items.lazy.filter { $0.state.name == state }.count
    }

    /// An enum state makes double-membership impossible. This explicit audit
    /// keeps the no-item-vanishes contract executable for tests and callers.
    public var allItemsAreInExactlyOneState: Bool {
        let partitionCount = GitHubCommandStateName.allCases.reduce(0) { $0 + count(in: $1) }
        return partitionCount == items.count && Set(items.map(\.itemId)).count == items.count
    }
}

public enum GitHubCommandStoreError: Error, LocalizedError, Equatable {
    case invalidObservation(String)
    case unknownItem(String)
    case invalidTransition(String)
    case malformedOperation
    case invariantViolation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidObservation(let detail): return "Invalid GitHub Command observation: \(detail)"
        case .unknownItem(let id): return "Unknown GitHub Command item \(id)."
        case .invalidTransition(let detail): return "Invalid GitHub Command transition: \(detail)"
        case .malformedOperation: return "GitHub Command operation feed contains an unreadable row."
        case .invariantViolation(let detail): return "GitHub Command invariant failed: \(detail)"
        }
    }
}

private struct GitHubCommandCallback: Codable, Sendable, Equatable {
    let messageIds: [String]
    let codexStatus: String
    let summary: String
    let threadId: String?
    let turnId: String?
}

private enum GitHubCommandOpBody: Codable, Sendable, Equatable {
    case detected(repository: String, number: Int, kind: GitHubCommandItemKind, title: String)
    case observed(GitHubCommandObservation)
    case dispatchPrepared(GitHubCommandDispatchIntent)
    case dispatchSucceeded(itemId: String, receipt: GitHubCommandDispatchReceipt)
    case dispatchFailed(itemId: String, eventKey: String, detail: String)
    case callbackReceived(itemId: String, callback: GitHubCommandCallback)
    case verificationReadFailed(itemId: String, detail: String)
    case notificationClaimed(itemId: String, intent: GitHubCommandNotificationIntent)
    case notificationRecorded(itemId: String, receipt: GitHubCommandNotificationReceipt)
}

private extension GitHubCommandOpBody {
    var causalKind: String {
        switch self {
        case .detected: return "detected"
        case .observed: return "observed"
        case .dispatchPrepared: return "dispatch_prepared"
        case .dispatchSucceeded: return "dispatch_succeeded"
        case .dispatchFailed: return "dispatch_failed"
        case .callbackReceived: return "callback_received"
        case .verificationReadFailed: return "verification_read_failed"
        case .notificationClaimed: return "notification_claimed"
        case .notificationRecorded: return "notification_recorded"
        }
    }

    var affectedItemId: String {
        switch self {
        case .detected(let repository, let number, _, _):
            return GitHubCommandObservation.itemId(repository: repository, number: number)
        case .observed(let observation): return observation.itemId
        case .dispatchPrepared(let intent): return intent.itemId
        case .dispatchSucceeded(let itemId, _), .dispatchFailed(let itemId, _, _),
             .callbackReceived(let itemId, _), .verificationReadFailed(let itemId, _),
             .notificationClaimed(let itemId, _), .notificationRecorded(let itemId, _):
            return itemId
        }
    }

    var expectedNextEvidence: String? {
        switch self {
        case .dispatchPrepared: return "dispatch_result"
        case .dispatchSucceeded: return "codex_callback"
        case .callbackReceived: return "github_verification"
        case .notificationClaimed: return "delivery_receipt"
        default: return nil
        }
    }

    var procedureActionKind: String? {
        switch self {
        case .dispatchPrepared: return "dispatch_prepare"
        case .dispatchSucceeded: return "codex_bridge_dispatch"
        case .notificationClaimed: return "notification_claim"
        default: return nil
        }
    }

    var procedureEvidenceKind: String? {
        switch self {
        case .detected: return "item_detection"
        case .observed: return "github_live_observation"
        case .dispatchPrepared: return "dispatch_intent"
        case .dispatchSucceeded: return "dispatch_receipt"
        case .dispatchFailed: return "dispatch_failure"
        case .callbackReceived: return "correlated_callback"
        case .verificationReadFailed: return "github_read_failure"
        case .notificationClaimed: return "notification_claim"
        case .notificationRecorded: return "delivery_receipt"
        }
    }

    var procedureCheckpointClass: String? {
        switch self {
        case .dispatchPrepared: return "canonical_dispatch_precondition"
        case .callbackReceived: return "canonical_callback_correlation"
        case .observed: return "github_reducer_verification"
        case .notificationClaimed: return "canonical_notification_claim"
        default: return nil
        }
    }

    var procedureRetryClass: String? {
        switch self {
        case .dispatchPrepared(let intent) where intent.attempt > 1: return "bounded_dispatch_retry"
        case .dispatchFailed: return "retryable_dispatch_failure"
        case .verificationReadFailed: return "bounded_read_retry"
        default: return nil
        }
    }

    var procedureRetryCount: Int? {
        switch self {
        case .dispatchPrepared(let intent): return max(0, intent.attempt - 1)
        default: return nil
        }
    }

    var procedureExternalEffectClass: String {
        switch self {
        case .dispatchSucceeded, .notificationRecorded: return "external_send"
        case .dispatchPrepared, .dispatchFailed, .notificationClaimed: return "local_control"
        case .detected, .observed, .callbackReceived, .verificationReadFailed: return "external_read"
        }
    }

    var procedureToolCallCount: Int? {
        switch self {
        case .dispatchSucceeded, .notificationRecorded: return 1
        default: return nil
        }
    }
}

private struct GitHubCommandOp: Codable, Sendable, Equatable {
    let id: String
    let at: String
    let body: GitHubCommandOpBody
}

/// The op-log's compaction snapshot (audit round 2, F1). `state` is the full
/// reduced state through `lastCompactedOpId` — items, blockers, notification
/// claims/receipts, AND `dispatchedEventKeys` (the at-most-once ledger; losing
/// it would re-dispatch settled work). Replay seeds from it and applies only
/// ops that follow `lastCompactedOpId`.
private struct GitHubCommandCompactionBase: Codable, Sendable {
    let state: GitHubCommandState
    let lastCompactedOpId: String
    let compactedAt: String
    let compactedOpCount: Int
    /// First op id of the tail the compaction kept in the rewritten log.
    /// This is the lock-free reader's consistency proof: an ops snapshot
    /// whose head matches belongs to THIS base's file generation; a snapshot
    /// containing `lastCompactedOpId` predates the truncate and prefix-drops;
    /// anything else is a torn read and retries. keep >= 1 guarantees it.
    let tailFirstOpId: String
}

public struct GitHubCommandStore: Sendable, MotorActionReadModelProviding {
    public let dataRoot: URL
    public let opsPath: URL
    public let statePath: URL
    /// Compaction snapshot the op-log replays FROM: the full reduced state
    /// (including the monotonic dispatched at-most-once ledger) as of
    /// `lastCompactedOpId`. Written atomically BEFORE the op-log truncate; a
    /// crash between the two is healed by the replay prefix-drop.
    public let basePath: URL
    /// Op-log lines that trigger a snapshot+truncate on the next write. The
    /// feed grew unbounded with O(total-ops) replay per write (audit round 2,
    /// F1: 15.9k ops in 6 days). Injectable for tests.
    let opsCompactionThreshold: Int
    private let persistence = SwiftNativePersistenceCore()
    private let changeBus: StoreChangeBus

    /// A codex_working item whose dispatch receipt is older than this window
    /// with no recorded callback is treated as a lost/stalled callback and
    /// ages into attention(.callbackOverdue). Durable bridge recovery still
    /// owns the original turn; timeout alone never authorizes a competing one.
    static let codexCallbackOverdueSeconds: TimeInterval = 6 * 60 * 60

    /// Bounded "still needs work → back to codex" loop (User, 2026-07-12): a
    /// verificationFailed item re-dispatches to codex until this many total
    /// attempts, then parks as a genuine blocker that claims APNS. The cap
    /// prevents a codex ping-pong loop on work he cannot actually clear.
    static let maxDispatchAttemptsPerEvent = 3

    /// Per-item work-log bound (2026-07-21 audit): a terminal item used to
    /// accumulate one stale_callback row per late/duplicate callback forever.
    /// Keep the newest entries only, drop-oldest.
    static let maxWorkLogEntries = 50

    /// Resolved items retire out of the reduced state this long after their
    /// last update (2026-07-21 audit, persistence slice): items and
    /// dispatchedEventKeys otherwise grew the reduced state — rewritten on
    /// every append and baked into ops_base — forever. Retirement is anchored
    /// to the feed's OWN newest stamp, never wall-clock, so the same feed
    /// always folds to the same state. Injectable for tests.
    let terminalItemRetentionSeconds: TimeInterval
    /// The dispatched at-most-once ledger keeps every key a live item still
    /// references (at-most-once + settle-bounce survive) plus this many of
    /// the most recently dispatched keys — the tail covers keys whose item
    /// cleared its reference when a superseding event arrived before the old
    /// event settled. Injectable for tests.
    let dispatchedEventKeysTailCap: Int

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        changeBus: StoreChangeBus = .shared,
        opsCompactionThreshold: Int = 2_048,
        terminalItemRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60,
        dispatchedEventKeysTailCap: Int = 512
    ) {
        self.dataRoot = dataRoot
        self.changeBus = changeBus
        self.opsCompactionThreshold = max(2, opsCompactionThreshold)
        self.terminalItemRetentionSeconds = terminalItemRetentionSeconds
        self.dispatchedEventKeysTailCap = max(0, dispatchedEventKeysTailCap)
        let directory = dataRoot.appendingPathComponent("workshop/github_command", isDirectory: true)
        self.opsPath = directory.appendingPathComponent("ops.jsonl")
        self.statePath = directory.appendingPathComponent("github_command_state.json")
        self.basePath = directory.appendingPathComponent("ops_base.json")
    }

    public func liveState() async throws -> GitHubCommandState {
        let feed = try await readFeedUnlocked()
        let state = try replay(base: feed.base, feed.ops)
        try Self.validate(state)
        return state
    }

    /// Shared motor-tissue projection. GitHub Command keeps sole ownership of
    /// its reducer and feed; this method only translates the current item.
    public func motorActionReadModel(actionId: String) async throws -> MotorActionReadModel? {
        guard let item = try await liveState().item(actionId) else { return nil }
        return Self.motorActionReadModel(item: item)
    }

    /// Pure projection for a reducer result the caller already owns. Runtime
    /// transition sinks use this overload so publishing a state change never
    /// rereads or replays the append-only feed a second time.
    public static func motorActionReadModel(item: GitHubCommandItem) -> MotorActionReadModel {
        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let expectedEvidence: String?
        switch item.state {
        case .detected:
            phase = .proposed
            verification = .notStarted
            expectedEvidence = "routing_decision"
        case .needsCodex:
            phase = .ready
            verification = .notStarted
            expectedEvidence = "dispatch_result"
        case .codexWorking:
            phase = .waitingExternal
            verification = .notStarted
            expectedEvidence = "codex_callback"
        case .verifying:
            phase = .verifying
            verification = .pending
            expectedEvidence = "github_verification"
        case .needsUser:
            phase = .awaitingHuman
            verification = .unknown
            expectedEvidence = "user_judgment"
        case .waitingUpstream:
            phase = .waitingExternal
            verification = .satisfied
            expectedEvidence = "upstream_change"
        case .attention(let reason):
            phase = .blocked
            switch reason {
            case .verificationFailed, .verificationReadFailed:
                verification = .failed
            default:
                verification = .notStarted
            }
            expectedEvidence = "recovery_evidence"
        case .resolved:
            if item.kind == .pullRequest, item.observation?.isMerged != true {
                // Closing a PR without merging is terminal, but it is not the
                // successful completion that positive resident physiology
                // represents. Keep the canonical item resolved while the
                // shared motor view truthfully reports cancellation.
                phase = .cancelled
                verification = .notRequired
                expectedEvidence = nil
            } else {
                phase = .succeeded
                verification = .satisfied
                expectedEvidence = nil
            }
        }
        return MotorActionReadModel(
            domain: "github_command",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(item.itemId),
            phase: phase,
            domainState: item.state.name.rawValue,
            verification: verification,
            expectedNextEvidence: expectedEvidence,
            updatedAt: item.motorUpdatedAt ?? item.createdAt
        )
    }

    public static func motorSemanticFingerprint(_ model: MotorActionReadModel) -> String {
        CausalTransitionEvidence.opaqueIdentity([
            model.actionIdentity,
            model.phase.rawValue,
            model.domainState,
            model.verification.rawValue,
            model.expectedNextEvidence ?? "none",
        ].joined(separator: "|"))
    }

    /// Replays the canonical feed once and observes each reducer transition.
    /// The projection contains only enum state and SHA-256 identities: no repo
    /// name, title, comment/callback text, blocker detail, token, or local path.
    public func causalTransitionEvidence(limit: Int = 512) async throws -> [CausalTransitionEvidence] {
        let boundedLimit = max(0, min(limit, 2_048))
        guard boundedLimit > 0 else { return [] }
        let feed = try await readFeedUnlocked()
        let ops = feed.ops
        var evidence: [CausalTransitionEvidence] = []
        evidence.reserveCapacity(min(boundedLimit, ops.count))
        let captureStart = max(0, ops.count - boundedLimit)
        var operationIndex = 0
        var sequenceByItem: [String: Int] = [:]
        var parentOperationByItem: [String: String] = [:]
        _ = try replay(base: feed.base, ops) { op, before, after in
            let affectedItemID = op.body.affectedItemId
            let sequence = sequenceByItem[affectedItemID, default: 0]
            let opaqueOperationID = CausalTransitionEvidence.opaqueIdentity(op.id)
            let parentOperationID = parentOperationByItem[affectedItemID]
            defer {
                operationIndex += 1
                sequenceByItem[affectedItemID] = sequence + 1
                parentOperationByItem[affectedItemID] = opaqueOperationID
            }
            guard operationIndex >= captureStart else { return }
            let outcome: String
            if before == nil, after != nil {
                outcome = "item_created"
            } else if before?.state != after?.state {
                outcome = "state_changed"
            } else {
                outcome = "state_unchanged"
            }
            let item = after ?? before
            let itemKind = item?.kind.rawValue ?? "unknown"
            let opaqueItemIdentity = CausalTransitionEvidence.opaqueIdentity(affectedItemID)
            let entersResolved = before?.state != .resolved && after?.state == .resolved
            // Notification receipts appended after canonical resolution are a
            // separate delivery lifecycle, not extra steps after this reducer
            // trajectory's verified terminal.
            let lifecycleTrajectoryID = before?.state == .resolved && after?.state == .resolved
                ? nil : opaqueItemIdentity
            let phase: String? = after.map { item in
                switch item.state {
                case .detected: return MotorActionPhase.proposed.rawValue
                case .needsCodex: return MotorActionPhase.ready.rawValue
                case .codexWorking: return MotorActionPhase.waitingExternal.rawValue
                case .verifying: return MotorActionPhase.verifying.rawValue
                case .needsUser: return MotorActionPhase.awaitingHuman.rawValue
                case .waitingUpstream: return MotorActionPhase.waitingExternal.rawValue
                case .attention: return MotorActionPhase.blocked.rawValue
                case .resolved: return MotorActionPhase.succeeded.rawValue
                }
            }
            let verification: String? = after.map { item in
                switch item.state {
                case .verifying: return "pending"
                case .resolved, .waitingUpstream: return "verified"
                case .attention(.verificationFailed), .attention(.verificationReadFailed): return "failed"
                case .needsUser: return "unknown"
                default: return "not_started"
                }
            }
            let latencyMilliseconds: Int? = {
                let start: String?
                switch op.body {
                case .dispatchSucceeded(_, let receipt): start = receipt.queuedAt
                case .callbackReceived: start = before?.dispatchReceipt?.queuedAt
                default: start = nil
                }
                guard let start,
                      let startDate = DeskClock.parseISO(start),
                      let endDate = DeskClock.parseISO(op.at),
                      endDate >= startDate else { return nil }
                return Int(min(Double(Int.max), endDate.timeIntervalSince(startDate) * 1_000))
            }()
            evidence.append(CausalTransitionEvidence(
                domain: "github_command",
                operationId: opaqueOperationID,
                occurredAt: op.at,
                itemIdentity: opaqueItemIdentity,
                kind: op.body.causalKind,
                beforeState: before?.state.name.rawValue,
                afterState: after?.state.name.rawValue,
                expectedNextEvidence: op.body.expectedNextEvidence,
                outcome: outcome,
                trajectoryID: lifecycleTrajectoryID,
                parentOperationID: parentOperationID,
                sequenceNumber: sequence,
                motorPhase: phase,
                verificationClass: verification,
                authorityClass: "domain_reducer_only",
                deadlineClass: op.body.causalKind == "dispatch_succeeded"
                    ? "callback_overdue_6h" : nil,
                terminalClass: entersResolved ? "verified_success" : nil,
                completenessClass: entersResolved ? "complete" : "observed",
                taskFamily: "github_command.\(itemKind)",
                inputClass: itemKind,
                inputInstanceIdentity: opaqueItemIdentity,
                parameterSchemaClass: "github_command_item_v1",
                parameterSchemaIdentity: CausalTransitionEvidence.opaqueIdentity(
                    "github_command_item_v1|\(itemKind)"
                ),
                procedureShapeIdentity: CausalTransitionEvidence.opaqueIdentity(
                    "github_command_reducer_v1|\(itemKind)"
                ),
                actionKind: op.body.procedureActionKind,
                evidenceKind: op.body.procedureEvidenceKind,
                checkpointClass: op.body.procedureCheckpointClass,
                retryClass: op.body.procedureRetryClass,
                retryCount: op.body.procedureRetryCount,
                cancellationClass: nil,
                externalEffectClass: op.body.procedureExternalEffectClass,
                latencyMilliseconds: latencyMilliseconds,
                providerCallCount: nil,
                toolCallCount: op.body.procedureToolCallCount,
                providerCostMicros: nil,
                toolCostMicros: nil,
                removableOrchestrationProviderCallCount: nil
            ))
        }
        return evidence
    }

    @discardableResult
    public func detect(
        repository: String,
        number: Int,
        kind: GitHubCommandItemKind,
        title: String
    ) async throws -> GitHubCommandItem {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.split(separator: "/").count == 2, number > 0 else {
            throw GitHubCommandStoreError.invalidObservation("identity must be owner/repo plus a positive number")
        }
        let id = GitHubCommandObservation.itemId(repository: repository, number: number)
        return try await append(.detected(repository: repository, number: number, kind: kind, title: title), itemId: id)
    }

    @discardableResult
    public func observe(_ observation: GitHubCommandObservation) async throws -> GitHubCommandItem {
        try Self.validate(observation)
        return try await append(.observed(observation), itemId: observation.itemId)
    }

    /// Record one refresh worth of observations as one canonical transaction:
    /// one feed read/replay, one append write, one state projection write, and
    /// one live invalidation. Sequential replay still preserves observation
    /// ordering and freshest-review-thread semantics within the batch.
    @discardableResult
    public func observe(_ observations: [GitHubCommandObservation]) async throws -> [GitHubCommandItem] {
        guard !observations.isEmpty else { return [] }
        try observations.forEach(Self.validate)
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedLocked()
            let newOps = observations.map {
                GitHubCommandOp(
                    id: UUID().uuidString.lowercased(),
                    at: DeskClock.nowISO(),
                    body: .observed($0)
                )
            }
            let state = try replay(base: feed.base, feed.ops + newOps)
            try Self.validate(state)
            try await persistence.appendJSONL(try newOps.map(Self.json), to: opsPath)
            changeBus.emit(StoreChange(store: .githubCommand, path: opsPath))
            try await persistence.writeJSON(try Self.json(state), to: statePath)
            try await compactIfNeededUnlocked(
                base: feed.base,
                rebasedOps: feed.ops + newOps,
                fileOpCount: feed.fileOpCount + newOps.count
            )
            return observations.compactMap { state.item($0.itemId) }
        }
    }

    /// Reserves one deterministic bridge id for an actionable event. Replaying
    /// an unfinished reservation returns the same id; retrying dispatch_failed
    /// increments the attempt but never changes the idempotency key.
    public func prepareDispatch(itemId: String) async throws -> GitHubCommandDispatchIntent? {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedLocked()
            let state = try replay(base: feed.base, feed.ops)
            guard let item = state.item(itemId) else { throw GitHubCommandStoreError.unknownItem(itemId) }
            // Never dispatch on an observation whose latest live re-read
            // FAILED (review: blip tolerance keeps the prior state dispatch-
            // eligible, but the evidence behind it is unverified). A clean
            // observe resets the counter and the next cycle dispatches.
            guard (item.verificationReadFailures ?? 0) == 0 else { return nil }
            let retryable: Bool
            let overdueRedispatch: Bool
            switch item.state {
            case .needsCodex: retryable = true; overdueRedispatch = false
            case .attention(.dispatchFailed): retryable = true; overdueRedispatch = false
            // "Codex said done but GitHub still shows the same actionable
            // event" goes BACK to codex a bounded number of times (User's spec:
            // still needs work → back to codex), then parks as a real blocker
            // that claims APNS. The cap prevents a codex ping-pong loop.
            case .attention(.verificationFailed):
                retryable = (item.dispatchIntent?.attempt ?? 1) < Self.maxDispatchAttemptsPerEvent
                overdueRedispatch = true
            default: retryable = false; overdueRedispatch = false
            }
            guard let eventKey = item.observation?.actionableEventKey else { return nil }
            // IDEMPOTENT RESUME (review round 4): an already-prepared intent
            // whose dispatchId has NOT been consumed by a recorded receipt is
            // returned AS-IS — crash recovery re-preparing the same dispatch
            // must not burn the retry cap, change the reserved key, or park
            // the item before its final attempt actually executed.
            // STATE ELIGIBILITY (round 5): resume only while the item is still
            // in a dispatch-pending shape. observe() can settle an item
            // (resolved / needsUser / waitingUpstream) WITHOUT clearing its
            // leftover intent, and a closed-PR or human-decision observation
            // can carry the same eventKey — a settled item must never get a
            // dispatch out of a stale reservation. isDispatchPending includes
            // verificationFailed regardless of cap, so an unconsumed FINAL
            // attempt still resumes after a crash.
            if let intent = item.dispatchIntent, intent.eventKey == eventKey,
               intent.dispatchId != item.dispatchReceipt?.dispatchId,
               item.state.isDispatchPending {
                return intent
            }
            guard retryable else { return nil }
            if !overdueRedispatch {
                guard !state.dispatchedEventKeys.contains(eventKey) else { return nil }
            }
            let attempt = (item.dispatchIntent?.eventKey == eventKey ? item.dispatchIntent?.attempt ?? 0 : 0) + 1
            let dispatchId: String
            if overdueRedispatch {
                dispatchId = Self.dispatchId(eventKey: eventKey, attempt: attempt)
            } else {
                dispatchId = Self.dispatchId(eventKey: eventKey)
            }
            let intent = GitHubCommandDispatchIntent(
                itemId: item.itemId,
                eventKey: eventKey,
                dispatchId: dispatchId,
                headSHA: item.observation?.headSHA,
                attempt: attempt,
                preparedAt: DeskClock.nowISO()
            )
            return try await appendUnlocked(.dispatchPrepared(intent), itemId: item.itemId, feed: feed)
                .dispatchIntent
        }
    }

    /// Receipt and codex_working are reduced from this single feed row. There
    /// is no API that can set codex_working independently.
    @discardableResult
    public func recordDispatchSuccess(
        itemId: String,
        receipt: GitHubCommandDispatchReceipt
    ) async throws -> GitHubCommandItem {
        try await append(.dispatchSucceeded(itemId: itemId.lowercased(), receipt: receipt), itemId: itemId)
    }

    @discardableResult
    public func recordDispatchFailure(itemId: String, eventKey: String, detail: String) async throws -> GitHubCommandItem {
        try await append(
            .dispatchFailed(itemId: itemId.lowercased(), eventKey: eventKey, detail: Self.bounded(detail, limit: 500)),
            itemId: itemId
        )
    }

    /// Correlates callback message ids to the store-owned dispatch receipt (or
    /// a crash-recovery intent with the same deterministic message id), logs the
    /// callback, and enters verifying. The caller must then re-read GitHub and
    /// feed the resulting observation back through observe(_:).
    @discardableResult
    public func recordCallback(
        messageIds: [String],
        codexStatus: String,
        summary: String,
        threadId: String? = nil,
        turnId: String? = nil
    ) async throws -> [GitHubCommandItem] {
        let ids = Set(messageIds.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return [] }
        return try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedLocked()
            var ops = feed.ops
            var state = try replay(base: feed.base, ops)
            let matches = state.items.filter { item in
                if let receipt = item.dispatchReceipt, ids.contains(receipt.messageId) { return true }
                if let intent = item.dispatchIntent, ids.contains(intent.dispatchId) { return true }
                return false
            }
            var updated: [GitHubCommandItem] = []
            var appendedCount = 0
            for item in matches {
                let callback = GitHubCommandCallback(
                    messageIds: messageIds,
                    codexStatus: codexStatus,
                    summary: Self.bounded(summary, limit: 4_000),
                    threadId: threadId,
                    turnId: turnId
                )
                let op = GitHubCommandOp(id: UUID().uuidString.lowercased(), at: DeskClock.nowISO(), body: .callbackReceived(itemId: item.itemId, callback: callback))
                try Self.validate(op.body, state: state)
                try await persistence.appendJSONL(try Self.json(op), to: opsPath)
                changeBus.emit(StoreChange(store: .githubCommand, path: opsPath))
                ops.append(op)
                appendedCount += 1
                state = try replay(base: feed.base, ops)
                guard let result = state.item(item.itemId) else { throw GitHubCommandStoreError.unknownItem(item.itemId) }
                updated.append(result)
            }
            try Self.validate(state)
            try await persistence.writeJSON(try Self.json(state), to: statePath)
            try await compactIfNeededUnlocked(
                base: feed.base,
                rebasedOps: ops,
                fileOpCount: feed.fileOpCount + appendedCount
            )
            return updated
        }
    }

    @discardableResult
    public func recordVerificationReadFailure(itemId: String, detail: String) async throws -> GitHubCommandItem {
        try await append(
            .verificationReadFailed(itemId: itemId.lowercased(), detail: Self.bounded(detail, limit: 500)),
            itemId: itemId
        )
    }

    /// Claims before delivery so a crash can lose a notification but can never
    /// duplicate it across restart. Claims exist only for terminal success or
    /// a specific blocker with an owner.
    public func claimNotification(itemId: String) async throws -> GitHubCommandNotificationIntent? {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedLocked()
            let state = try replay(base: feed.base, feed.ops)
            guard let item = state.item(itemId) else { throw GitHubCommandStoreError.unknownItem(itemId) }
            guard let intent = Self.notificationIntent(for: item), !item.notificationClaims.contains(intent.dedupKey) else {
                return nil
            }
            _ = try await appendUnlocked(.notificationClaimed(itemId: item.itemId, intent: intent), itemId: item.itemId, feed: feed)
            return intent
        }
    }

    /// Atomically claim every currently deliverable notification with one feed
    /// replay and one append transaction. The returned intents are already
    /// durable, so callers may deliver them without duplicate launch sends.
    public func claimPendingNotifications() async throws -> [GitHubCommandNotificationIntent] {
        try await persistence.withFileLock(opsPath) {
            let feed = try await readFeedLocked()
            let prior = try replay(base: feed.base, feed.ops)
            let intents = prior.items.compactMap { item -> GitHubCommandNotificationIntent? in
                guard let intent = Self.notificationIntent(for: item),
                      !item.notificationClaims.contains(intent.dedupKey) else { return nil }
                return intent
            }
            guard !intents.isEmpty else { return [] }
            let newOps = intents.map { intent in
                GitHubCommandOp(
                    id: UUID().uuidString.lowercased(),
                    at: DeskClock.nowISO(),
                    body: .notificationClaimed(itemId: intent.itemId, intent: intent)
                )
            }
            for op in newOps { try Self.validate(op.body, state: prior) }
            let state = try replay(base: feed.base, feed.ops + newOps)
            try Self.validate(state)
            try await persistence.appendJSONL(try newOps.map(Self.json), to: opsPath)
            changeBus.emit(StoreChange(store: .githubCommand, path: opsPath))
            try await persistence.writeJSON(try Self.json(state), to: statePath)
            try await compactIfNeededUnlocked(
                base: feed.base,
                rebasedOps: feed.ops + newOps,
                fileOpCount: feed.fileOpCount + newOps.count
            )
            return intents
        }
    }

    @discardableResult
    public func recordNotification(
        itemId: String,
        dedupKey: String,
        status: String,
        detail: String
    ) async throws -> GitHubCommandItem {
        let receipt = GitHubCommandNotificationReceipt(
            dedupKey: dedupKey,
            deliveredAt: DeskClock.nowISO(),
            status: status,
            detail: Self.bounded(detail, limit: 1_000)
        )
        return try await append(.notificationRecorded(itemId: itemId.lowercased(), receipt: receipt), itemId: itemId)
    }

    private func append(_ body: GitHubCommandOpBody, itemId: String) async throws -> GitHubCommandItem {
        try await persistence.withFileLock(opsPath) {
            try await appendUnlocked(
                body,
                itemId: itemId.lowercased(),
                feed: try await readFeedLocked()
            )
        }
    }

    private func appendUnlocked(
        _ body: GitHubCommandOpBody,
        itemId: String,
        feed: (base: GitHubCommandState?, ops: [GitHubCommandOp], fileOpCount: Int)
    ) async throws -> GitHubCommandItem {
        let prior = try replay(base: feed.base, feed.ops)
        try Self.validate(body, state: prior)
        let op = GitHubCommandOp(id: UUID().uuidString.lowercased(), at: DeskClock.nowISO(), body: body)
        try await persistence.appendJSONL(try Self.json(op), to: opsPath)
        changeBus.emit(StoreChange(store: .githubCommand, path: opsPath))
        let state = try replay(base: feed.base, feed.ops + [op])
        try Self.validate(state)
        try await persistence.writeJSON(try Self.json(state), to: statePath)
        try await compactIfNeededUnlocked(
            base: feed.base,
            rebasedOps: feed.ops + [op],
            fileOpCount: feed.fileOpCount + 1
        )
        guard let item = state.item(itemId) else { throw GitHubCommandStoreError.unknownItem(itemId) }
        return item
    }

    private func readOpsUnlocked() async throws -> [GitHubCommandOp] {
        let rows = try await persistence.readJSONL(opsPath)
        return try rows.map { row in
            guard let op: GitHubCommandOp = try? Self.decode(row) else {
                throw GitHubCommandStoreError.malformedOperation
            }
            return op
        }
    }

    /// Reads the replayable feed: compaction base (if any) + the ops that
    /// FOLLOW it. LOCK-FREE and consistent (review round 2, F1 finding 2 —
    /// without proof of pairing, a reader whose ops snapshot predates a
    /// compaction's append could replay the prefix twice on the new base;
    /// flocking every read cost ~66ms/call on the causal-evidence path, and
    /// speed must be free). Each attempt PROVES its (ops, base) pairing:
    ///   - no base file → no truncation has ever completed → ops is the
    ///     whole genesis log (the base is written before any truncate and
    ///     never deleted);
    ///   - base's lastCompactedOpId appears in ops → the snapshot predates
    ///     the truncate → drop the prefix through it (this also heals a
    ///     crash between base write and truncate);
    ///   - ops head == base's tailFirstOpId → the snapshot IS this base's
    ///     rewritten file (possibly with later appends) → replay on base;
    ///   - anything else is a torn read → retry; after 3 torn reads, one
    ///     pass under the flock is guaranteed consistent. Lock-free readers
    ///     ONLY — callers already holding the flock use readFeedLocked.
    private func readFeedUnlocked() async throws -> (base: GitHubCommandState?, ops: [GitHubCommandOp], fileOpCount: Int) {
        for _ in 0..<3 {
            if let feed = try await readFeedAttempt() { return feed }
        }
        return try await persistence.withFileLock(opsPath) {
            try await readFeedLocked()
        }
    }

    /// Single-attempt read for callers that ALREADY hold the ops flock.
    /// withFileLock is not reentrant (a fresh fd's flock spins EWOULDBLOCK
    /// against our own held lock), so a writer must never fall into
    /// readFeedUnlocked's flock fallback: under the flock no concurrent
    /// writer exists, so a failed (base, tail) pairing is genuine on-disk
    /// corruption and must throw loud — not wedge this writer, and every
    /// writer queued behind it, forever.
    private func readFeedLocked() async throws -> (base: GitHubCommandState?, ops: [GitHubCommandOp], fileOpCount: Int) {
        guard let feed = try await readFeedAttempt() else {
            throw GitHubCommandStoreError.invariantViolation(
                "ops feed unreadable as a consistent (base, tail) pair even under the ops flock"
            )
        }
        return feed
    }

    private func readFeedAttempt() async throws -> (base: GitHubCommandState?, ops: [GitHubCommandOp], fileOpCount: Int)? {
        var ops = try await readOpsUnlocked()
        let fileOpCount = ops.count
        guard FileManager.default.fileExists(atPath: basePath.path) else {
            return (nil, ops, fileOpCount)
        }
        // A base that EXISTS but will not decode must fail LOUD: after a
        // compaction has truncated the op-log, silently ignoring the base
        // would present a near-empty replay as valid state — data loss
        // dressed as health (review round 2, F1 finding 3). atomicWrite
        // (temp + rename) means readers never see a partial base.
        let raw = await persistence.readJSON(basePath, defaultValue: .null)
        guard raw != .null, let base: GitHubCommandCompactionBase = try? Self.decode(raw) else {
            throw GitHubCommandStoreError.invariantViolation(
                "ops_base.json exists but is unreadable — refusing to replay a truncated feed from empty"
            )
        }
        if let idx = ops.lastIndex(where: { $0.id == base.lastCompactedOpId }) {
            ops.removeFirst(idx + 1)
            return (base.state, ops, fileOpCount)
        }
        if ops.first?.id == base.tailFirstOpId {
            return (base.state, ops, fileOpCount)
        }
        return nil
    }

    /// Recent-evidence tail kept in the op-log across a compaction, so
    /// causalTransitionEvidence never blanks right after one (review round
    /// 2, F1 finding 4). Small thresholds (tests) scale the tail down.
    static let compactionKeepTailOps = 512

    /// Snapshot + keep-tail once the op-log crosses the threshold (audit
    /// round 2, F1). Callers hold the ops flock and pass the feed's base plus
    /// the full rebased op sequence (prior tail + just-appended). The new
    /// base replays through everything EXCEPT the kept tail and is written
    /// atomically BEFORE the log rewrite; the replay prefix-drop makes the
    /// in-between crash window safe (never lost, never double-applied).
    private func compactIfNeededUnlocked(
        base: GitHubCommandState?,
        rebasedOps: [GitHubCommandOp],
        fileOpCount: Int
    ) async throws {
        guard fileOpCount >= opsCompactionThreshold else { return }
        // keep >= 1: the rewritten log's head op is the lock-free reader's
        // consistency proof (tailFirstOpId), so the tail must never be empty.
        let keep = min(Self.compactionKeepTailOps, max(1, opsCompactionThreshold / 4))
        guard rebasedOps.count > keep, let lastPrefixOp = rebasedOps.dropLast(keep).last else { return }
        let prefix = Array(rebasedOps.dropLast(keep))
        let tail = Array(rebasedOps.suffix(keep))
        guard let tailFirst = tail.first else { return }
        let baseState = try replay(base: base, prefix)
        try Self.validate(baseState)
        let newBase = GitHubCommandCompactionBase(
            state: baseState,
            lastCompactedOpId: lastPrefixOp.id,
            compactedAt: DeskClock.nowISO(),
            compactedOpCount: fileOpCount,
            tailFirstOpId: tailFirst.id
        )
        // Snapshot-BEFORE-truncate via the shared engine. GitHubCommand keeps a
        // NON-empty tail (`tail`) — the rewritten log's head is the lock-free
        // reader's `tailFirstOpId` consistency proof, so it must never be empty.
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: try Self.json(newBase),
            tailRows: try tail.map(Self.json),
            basePath: basePath, opsPath: opsPath, persistence: persistence
        )
    }

    private func replay(
        base: GitHubCommandState?,
        _ ops: [GitHubCommandOp],
        observeTransition: ((GitHubCommandOp, GitHubCommandItem?, GitHubCommandItem?) -> Void)? = nil
    ) throws -> GitHubCommandState {
        var byId: [String: GitHubCommandItem] = [:]
        var dispatched = Set<String>()
        // First-seen order of the ledger keys, so the bounded "recent tail"
        // keeps the NEWEST keys (the set alone has no recency).
        var dispatchedOrder: [String] = []
        var updatedAt: String?
        if let base {
            byId = Dictionary(uniqueKeysWithValues: base.items.map { ($0.itemId, $0) })
            dispatched = Set(base.dispatchedEventKeys)
            dispatchedOrder = base.dispatchedEventKeys
            updatedAt = base.updatedAt
        }
        func recordDispatched(_ key: String) {
            if dispatched.insert(key).inserted { dispatchedOrder.append(key) }
        }
        for op in ops {
            updatedAt = op.at
            let affectedItemId = op.body.affectedItemId
            let before = byId[affectedItemId]
            switch op.body {
            case .detected(let repository, let number, let kind, let title):
                let id = GitHubCommandObservation.itemId(repository: repository, number: number)
                if var item = byId[id] {
                    item.repository = repository
                    item.kind = kind
                    item.title = title
                    item.updatedAt = op.at
                    byId[id] = item
                } else {
                    byId[id] = GitHubCommandItem(
                        itemId: id, repository: repository, number: number, kind: kind, title: title,
                        state: .detected, observation: nil, dispatchIntent: nil, dispatchReceipt: nil,
                        workLog: [], blocker: nil, finalReceipt: nil, lastCallbackStatus: nil,
                        lastSettledEventKey: nil,
                        notificationClaims: [], notificationReceipts: [], verificationReadFailures: nil, createdAt: op.at, updatedAt: op.at
                    )
                }

            case .observed(let observation):
                let id = observation.itemId
                var item = byId[id] ?? GitHubCommandItem(
                    itemId: id, repository: observation.repository, number: observation.number,
                    kind: observation.kind, title: observation.title, state: .detected,
                    observation: nil, dispatchIntent: nil, dispatchReceipt: nil, workLog: [],
                    blocker: nil, finalReceipt: nil, lastCallbackStatus: nil,
                    lastSettledEventKey: nil,
                    notificationClaims: [], notificationReceipts: [], verificationReadFailures: nil, createdAt: op.at, updatedAt: op.at
                )
                let priorObservation = item.observation
                var preserved = observation.preservingFreshestReviewThreads(from: priorObservation)
                // If preservation refused an evidence regression, the incoming
                // observation's actionability claims are stale too. When those
                // claims are purely thread-derived and the fresh evidence shows
                // no actionable thread, the poll is known-stale: keep the
                // preserved evidence, neutralize the stale claims, and leave
                // the item's state exactly where fresher truth put it.
                var staleNeutralized = false
                if preserved != observation,
                   observation.signals.isSubset(of: [.reviewComment, .changesRequested]),
                   preserved.reviewThreads?.contains(where: \.isActionable) == false {
                    staleNeutralized = true
                    preserved = GitHubCommandObservation(
                        repository: preserved.repository, number: preserved.number,
                        kind: preserved.kind, title: preserved.title,
                        isOpen: preserved.isOpen, isMerged: preserved.isMerged,
                        observedVersion: preserved.observedVersion,
                        actionableEventVersion: nil, signals: [],
                        headSHA: preserved.headSHA, humanDecision: preserved.humanDecision,
                        waitingKind: preserved.waitingKind, isStale: preserved.isStale,
                        finalReceipt: preserved.finalReceipt, reviewThreads: preserved.reviewThreads
                    )
                }
                item.repository = preserved.repository
                item.kind = preserved.kind
                item.title = preserved.title
                item.observation = preserved
                // Any successful observation ends a consecutive-read-failure run.
                item.verificationReadFailures = nil
                item.updatedAt = op.at
                if !staleNeutralized {
                    Self.route(&item, observation: preserved, priorObservation: priorObservation, dispatched: dispatched)
                }
                byId[id] = item

            case .dispatchPrepared(let intent):
                guard var item = byId[intent.itemId] else { continue }
                item.dispatchIntent = intent
                item.updatedAt = op.at
                byId[intent.itemId] = item

            case .dispatchSucceeded(let itemId, let receipt):
                // The at-most-once ledger stands even when the item itself is
                // gone (retired terminal) or has moved on to a new event.
                recordDispatched(receipt.eventKey)
                guard var item = byId[itemId] else { continue }
                // STALE-RESULT GUARD: a dispatch result may only transition an
                // item still in a dispatch-pending shape AND whose recorded
                // intent this receipt answers. If a late original callback
                // settled the item (resolved/verifying/waiting) — or a
                // concurrent observation routed a NEW actionable event and
                // cleared the old intent mid-send (2026-07-21 audit) — the
                // receipt is recorded but must not stomp the current state
                // back to codexWorking. The eventKey entered `dispatched`
                // above either way, so at-most-once survives.
                let answersIntent = item.dispatchIntent?.eventKey == receipt.eventKey
                    && item.dispatchIntent?.dispatchId == receipt.dispatchId
                if item.state.isDispatchPending && answersIntent {
                    item.dispatchReceipt = receipt
                    item.state = .codexWorking
                    item.blocker = nil
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "dispatch_receipt",
                        summary: "codex_message queued for \(item.repository) #\(item.number)",
                        messageId: receipt.messageId
                    ))
                } else {
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "stale_dispatch_receipt",
                        summary: "Dispatch receipt after state settled to \(item.state.name.rawValue); state unchanged",
                        messageId: receipt.messageId
                    ))
                }
                item.updatedAt = op.at
                byId[itemId] = item

            case .dispatchFailed(let itemId, let eventKey, let detail):
                guard var item = byId[itemId] else { continue }
                // Same stale-result guard: a failed retry send — or a failure
                // for an event a concurrent observation already superseded
                // (2026-07-21 audit) — must not drag the item into
                // attention(dispatchFailed).
                if item.state.isDispatchPending && item.dispatchIntent?.eventKey == eventKey {
                    item.state = .attention(.dispatchFailed)
                    item.blocker = GitHubCommandBlocker(
                        detail: "Codex bridge dispatch failed: \(detail)", owner: "NativeAgent Codex bridge"
                    )
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "dispatch_failed", summary: detail, messageId: nil
                    ))
                } else {
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "stale_dispatch_failure",
                        summary: "Dispatch failure after state settled to \(item.state.name.rawValue); state unchanged: \(detail)",
                        messageId: nil
                    ))
                }
                item.updatedAt = op.at
                byId[itemId] = item

            case .callbackReceived(let itemId, let callback):
                guard var item = byId[itemId] else { continue }
                // A late/duplicate callback correlating to an item that has
                // already reached a terminal state (e.g. a second completion
                // after resolved) is recorded as stale but must NOT revive the
                // item back into verifying.
                if item.state.isTerminal {
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "stale_callback",
                        summary: "Callback after terminal state ignored: \(callback.summary)",
                        messageId: callback.messageIds.first
                    ))
                    item.updatedAt = op.at
                    byId[itemId] = item
                    continue
                }
                if item.dispatchReceipt == nil, let intent = item.dispatchIntent {
                    let messageId = callback.messageIds.first(where: { $0 == intent.dispatchId }) ?? intent.dispatchId
                    let recovered = GitHubCommandDispatchReceipt(
                        eventKey: intent.eventKey, dispatchId: intent.dispatchId, messageId: messageId,
                        queuedAt: intent.preparedAt, transport: "codex_message_callback_recovery", recovered: true
                    )
                    item.dispatchReceipt = recovered
                    recordDispatched(intent.eventKey)
                }
                item.state = .verifying
                item.lastCallbackStatus = callback.codexStatus
                item.blocker = nil
                item.updatedAt = op.at
                Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                    at: op.at, kind: "codex_callback", summary: callback.summary,
                    messageId: callback.messageIds.first
                ))
                byId[itemId] = item

            case .verificationReadFailed(let itemId, let detail):
                guard var item = byId[itemId] else { continue }
                let failures = (item.verificationReadFailures ?? 0) + 1
                item.verificationReadFailures = failures
                // One failed read is a GitHub blip the next cycle retries —
                // logging it is enough. Only repeated consecutive failures earn
                // the attention bucket (User, 2026-07-12: a single 502 must not
                // land an alarm in his face).
                if failures >= 2 {
                    item.state = .attention(.verificationReadFailed)
                    item.blocker = GitHubCommandBlocker(
                        detail: "Live GitHub verification failed \(failures) times in a row: \(detail)",
                        owner: "GitHub connector"
                    )
                } else {
                    Self.appendWorkLog(&item, GitHubCommandWorkLogEntry(
                        at: op.at, kind: "verification_read_failed", summary: detail, messageId: nil
                    ))
                }
                item.updatedAt = op.at
                byId[itemId] = item

            case .notificationClaimed(let itemId, let intent):
                guard var item = byId[itemId] else { continue }
                if !item.notificationClaims.contains(intent.dedupKey) {
                    item.notificationClaims.append(intent.dedupKey)
                }
                item.updatedAt = op.at
                byId[itemId] = item

            case .notificationRecorded(let itemId, let receipt):
                guard var item = byId[itemId] else { continue }
                if !item.notificationReceipts.contains(where: { $0.dedupKey == receipt.dedupKey }) {
                    item.notificationReceipts.append(receipt)
                }
                item.updatedAt = op.at
                byId[itemId] = item
            }
            if var current = byId[affectedItemId] {
                let beforeFingerprint = before.map {
                    Self.motorSemanticFingerprint(Self.motorActionReadModel(item: $0))
                }
                let afterFingerprint = Self.motorSemanticFingerprint(
                    Self.motorActionReadModel(item: current)
                )
                if beforeFingerprint != afterFingerprint {
                    current.motorUpdatedAt = op.at
                } else {
                    current.motorUpdatedAt = before?.motorUpdatedAt ?? current.motorUpdatedAt
                }
                byId[affectedItemId] = current
            }
            observeTransition?(op, before, byId[affectedItemId])
        }
        // Terminal retirement + ledger bound (2026-07-21 audit, persistence
        // slice): resolved items and unreferenced dispatched keys otherwise
        // grew the reduced state — rewritten on every append and baked into
        // ops_base — forever. "Now" is the feed's OWN newest stamp (never
        // wall-clock), so the same feed always folds to the same state. The
        // ledger keeps every key a LIVE item still references (receipt /
        // intent / settle stamp — at-most-once and settle-bounce survive)
        // plus the most recent first-seen tail, which covers keys whose item
        // cleared its reference when a superseding event arrived before the
        // old event settled.
        if let feedNow = updatedAt.flatMap(DeskClock.parseISO) {
            let retiredIds = byId.values.compactMap { item -> String? in
                guard item.state.isTerminal,
                      let stamp = DeskClock.parseISO(item.updatedAt),
                      feedNow.timeIntervalSince(stamp) > terminalItemRetentionSeconds
                else { return nil }
                return item.itemId
            }
            for id in retiredIds { byId[id] = nil }
        }
        let referencedKeys = Set(byId.values.flatMap { item -> [String] in
            [item.dispatchReceipt?.eventKey, item.dispatchIntent?.eventKey, item.lastSettledEventKey]
                .compactMap { $0 }
        })
        let tailKeys = Set(dispatchedOrder.suffix(dispatchedEventKeysTailCap))
        dispatched.formIntersection(referencedKeys.union(tailKeys))
        return GitHubCommandState(
            items: byId.values.sorted { $0.itemId < $1.itemId },
            dispatchedEventKeys: dispatched.sorted(),
            updatedAt: updatedAt
        )
    }

    /// Per-item work-log append with the drop-oldest cap (2026-07-21 audit):
    /// a terminal item used to accumulate one stale_callback row per late or
    /// duplicate callback forever.
    private static func appendWorkLog(_ item: inout GitHubCommandItem, _ entry: GitHubCommandWorkLogEntry) {
        item.workLog.append(entry)
        if item.workLog.count > maxWorkLogEntries {
            item.workLog.removeFirst(item.workLog.count - maxWorkLogEntries)
        }
    }

    private static func route(
        _ item: inout GitHubCommandItem,
        observation: GitHubCommandObservation,
        priorObservation: GitHubCommandObservation?,
        dispatched: Set<String>
    ) {
        if !observation.isOpen {
            recordSettledEventKey(&item)
            item.state = .resolved
            item.blocker = nil
            item.finalReceipt = observation.finalReceipt ?? "\(item.repository) #\(item.number) \(observation.isMerged ? "merged" : "closed")."
            return
        }
        item.finalReceipt = nil
        if let decision = observation.humanDecision {
            // The event may have cleared in the same observation that carries
            // the decision — record settlement so the old key can never
            // bounce this item back into attention later (review round 2:
            // verifying → needsUser skipped the quiet-path stamp below).
            if observation.actionableEventKey == nil { recordSettledEventKey(&item) }
            item.state = .needsUser
            item.blocker = decision
            return
        }
        // A dispatched codex turn that never called back within the overdue
        // window is visibly stalled instead of sitting in codex_working
        // forever. The durable reply watcher still owns recovery; timeout is
        // not proof that a second turn would be safe.
        if case .codexWorking = item.state, Self.isCodexCallbackOverdue(item) {
            item.state = .attention(.callbackOverdue)
            item.blocker = GitHubCommandBlocker(
                detail: "Codex recorded no callback within the overdue window; the original turn may still need recovery or review.",
                owner: "NativeAgent Codex bridge"
            )
            return
        }
        if let eventKey = observation.actionableEventKey {
            if case .codexWorking = item.state, item.dispatchReceipt?.eventKey == eventKey { return }
            if case .verifying = item.state, item.dispatchReceipt?.eventKey == eventKey {
                let callbackSucceeded = ["completed", "ok", "success"].contains(item.lastCallbackStatus?.lowercased() ?? "")
                // The callback proves only that Codex returned. GitHub's
                // post-callback GraphQL observation owns settlement: active
                // review-thread identity + unresolved generation are already
                // encoded into eventKey, while resolved/outdated threads are
                // removed from actionable signals by the observation builder.
                // Therefore the same eventKey is direct evidence that the
                // desired external condition is still false. Never revive the
                // retired REST-era shortcut that let callback prose certify it.
                let reason: GitHubCommandAttentionReason = callbackSucceeded ? .verificationFailed : .codexFailed
                item.state = .attention(reason)
                item.blocker = GitHubCommandBlocker(
                    detail: callbackSucceeded
                        ? "Codex returned, but live GitHub still shows the same actionable event."
                        : item.lastCallbackStatus == "completed_without_reply"
                            ? "Codex ended without a final result; NativeAgent did not replay an outcome-unknown turn."
                            : "Codex did not complete the dispatched GitHub event.",
                    owner: callbackSucceeded ? "Codex" : "NativeAgent Codex bridge"
                )
                return
            }
            if dispatched.contains(eventKey) {
                // Polling must never redispatch the same actionable event.
                if case .attention = item.state { return }
                // An event that already settled through verification into
                // waiting_upstream must not bounce back to attention on an
                // identical re-observation. Only a NEW actionableEventVersion
                // (a different eventKey) may re-route.
                // 2026-07-21 audit fix: a RESOLVED (terminal) item must NOT
                // take this early return — a reopened PR re-observing its
                // previously settled eventKey would otherwise stay in
                // .resolved forever, hiding reopened actionable work. Terminal
                // items fall through to the attention route below.
                if item.lastSettledEventKey == eventKey {
                    if case .resolved = item.state {} else { return }
                }
                item.state = .attention(.verificationFailed)
                item.blocker = GitHubCommandBlocker(
                    detail: "A previously dispatched GitHub event is still actionable.", owner: "Codex"
                )
                return
            }
            item.state = .needsCodex
            item.blocker = nil
            if item.dispatchIntent?.eventKey != eventKey {
                item.dispatchIntent = nil
                item.dispatchReceipt = nil
                item.lastCallbackStatus = nil
            }
            return
        }
        // A red dispatch failure survives quiet polling — stale or unchanged
        // observations must not erase it (review: the stale branch below would
        // otherwise park it as waiting and silently stop retries). Only a real
        // dispatch outcome or a new actionable event moves it.
        if case .attention(.dispatchFailed) = item.state,
           observation.isStale || priorObservation?.observedVersion == observation.observedVersion { return }
        // Reaching here means the observation carries no actionable event:
        // a dispatched event has cleared on live GitHub. Record the settled
        // key so an identical re-observation (a marker resurrection that
        // re-produces an eventKey already in the monotonic dispatched set)
        // can never bounce the item back into attention — the guard above
        // was write-never before this stamp (audit round 2, G3).
        recordSettledEventKey(&item)
        if observation.isStale {
            // Quiet-but-stale tracked work WAITS — it does not demand a human.
            // Staleness stays visible as observation.isStale for display, but
            // routing it to attention piled 30 dormant upstream issues into
            // User's needs-attention bucket (User, 2026-07-12). The .stale
            // attention reason remains only for wire compat with old ops.
            item.state = .waitingUpstream(observation.waitingKind)
            item.blocker = nil
            return
        }
        item.state = .waitingUpstream(observation.waitingKind)
        item.blocker = nil
    }

    /// A quiet/terminal observation on an item that HOLDS a dispatch receipt
    /// records WHICH eventKey was verified-clear — regardless of the state
    /// the item happened to park in on the way (verifying, codexWorking,
    /// needsUser, attention: review round 2 found the verifying-only filter
    /// left needsUser/attention settles unstamped and bounceable). A receipt
    /// is the guard: needsCodex routing for a NEW key already cleared it,
    /// and receiptless states have nothing dispatched to settle.
    private static func recordSettledEventKey(_ item: inout GitHubCommandItem) {
        guard let settledKey = item.dispatchReceipt?.eventKey else { return }
        item.lastSettledEventKey = settledKey
    }

    private static func validate(_ observation: GitHubCommandObservation) throws {
        guard observation.repository.split(separator: "/").count == 2 else {
            throw GitHubCommandStoreError.invalidObservation("repository must be owner/name")
        }
        guard observation.number > 0 else {
            throw GitHubCommandStoreError.invalidObservation("number must be positive")
        }
        guard !observation.observedVersion.isEmpty else {
            throw GitHubCommandStoreError.invalidObservation("observedVersion is required")
        }
        if observation.signals.isEmpty != (observation.actionableEventVersion == nil) {
            throw GitHubCommandStoreError.invalidObservation("actionable signals and event version must appear together")
        }
        if let decision = observation.humanDecision,
           decision.detail.isEmpty || decision.owner.isEmpty {
            throw GitHubCommandStoreError.invalidObservation("human decisions require a specific blocker and owner")
        }
    }

    private static func validate(_ body: GitHubCommandOpBody, state: GitHubCommandState) throws {
        switch body {
        case .detected, .observed: return
        case .dispatchPrepared(let intent):
            guard let item = state.item(intent.itemId), item.observation?.actionableEventKey == intent.eventKey else {
                throw GitHubCommandStoreError.invalidTransition("dispatch intent does not match the current actionable event")
            }
            guard item.state == .needsCodex
                || item.state == .attention(.dispatchFailed)
                || item.state == .attention(.verificationFailed) else {
                throw GitHubCommandStoreError.invalidTransition("only needs_codex, dispatch_failed, or verification_failed may prepare dispatch")
            }
        case .dispatchSucceeded(let itemId, let receipt):
            // Tolerate a cleared intent (2026-07-21 audit): a concurrent
            // observe() that routed a NEW actionable event clears the old
            // dispatchIntent mid-send. Throwing here discarded a REAL codex
            // dispatch — the receipt never recorded, the eventKey never
            // entered the at-most-once ledger, and the runtime's whole
            // dispatch cycle aborted. Accept the receipt when it answers the
            // recorded intent (normal), when the item retired (ancient
            // result; the reducer files the ledger key only), or when the
            // receipt's event is no longer the item's current actionable
            // event (superseded; the reducer files it stale without stomping
            // state). Anything else is genuinely corrupt.
            guard let item = state.item(itemId) else { return }
            if let intent = item.dispatchIntent,
               intent.eventKey == receipt.eventKey, intent.dispatchId == receipt.dispatchId,
               receipt.messageId == intent.dispatchId { return }
            guard receipt.eventKey != item.observation?.actionableEventKey else {
                throw GitHubCommandStoreError.invalidTransition("dispatch receipt does not match its recorded intent")
            }
        case .dispatchFailed(let itemId, let eventKey, _):
            // Same cleared-intent tolerance as dispatchSucceeded above.
            guard let item = state.item(itemId) else { return }
            if item.dispatchIntent?.eventKey == eventKey { return }
            guard eventKey != item.observation?.actionableEventKey else {
                throw GitHubCommandStoreError.invalidTransition("dispatch failure does not match its recorded intent")
            }
        case .callbackReceived(let itemId, _):
            guard state.item(itemId)?.dispatchIntent != nil else {
                throw GitHubCommandStoreError.invalidTransition("callback has no correlated dispatch intent")
            }
        case .verificationReadFailed(let itemId, _):
            guard let item = state.item(itemId), !item.state.isTerminal else {
                throw GitHubCommandStoreError.invalidTransition("live-state read failure requires a non-terminal item")
            }
        case .notificationClaimed(let itemId, let intent):
            guard let item = state.item(itemId), notificationIntent(for: item) == intent else {
                throw GitHubCommandStoreError.invalidTransition("notification is outside the success/blocker boundary")
            }
        case .notificationRecorded(let itemId, let receipt):
            guard state.item(itemId)?.notificationClaims.contains(receipt.dedupKey) == true else {
                throw GitHubCommandStoreError.invalidTransition("notification receipt has no durable claim")
            }
        }
    }

    private static func validate(_ state: GitHubCommandState) throws {
        guard state.allItemsAreInExactlyOneState else {
            throw GitHubCommandStoreError.invariantViolation("an item vanished, duplicated, or occupied multiple states")
        }
        for item in state.items where item.state == .codexWorking {
            guard let receipt = item.dispatchReceipt,
                  state.dispatchedEventKeys.contains(receipt.eventKey) else {
                throw GitHubCommandStoreError.invariantViolation("codex_working requires an atomic dispatch receipt")
            }
        }
    }

    private static func notificationIntent(for item: GitHubCommandItem) -> GitHubCommandNotificationIntent? {
        let version = item.observation?.actionableEventVersion ?? item.observation?.observedVersion ?? item.updatedAt
        switch item.state {
        case .resolved:
            guard item.dispatchReceipt != nil, let receipt = item.finalReceipt, !receipt.isEmpty else { return nil }
            let key = "\(item.itemId)+\(version)+success"
            return GitHubCommandNotificationIntent(
                dedupKey: key, itemId: item.itemId, kind: .success,
                title: "GitHub resolved", body: Self.bounded(receipt, limit: 220)
            )
        case .needsUser:
            return blockerIntent(for: item, version: version)
        case .attention(let reason):
            // Only real, actionable blockers claim a notification. Transient
            // reasons (verificationReadFailed from a briefly-unreadable GitHub,
            // failures a retry may still clear) must NOT wake User's devices.
            // verificationFailed claims ONLY once its bounded back-to-codex
            // retries are exhausted — at that point it is genuinely stuck.
            switch reason {
            case .dispatchFailed, .callbackOverdue:
                return blockerIntent(for: item, version: version)
            case .verificationFailed:
                // Ping only when the FINAL attempt was reserved AND recorded —
                // a prepared-but-unexecuted cap attempt (crash window) must
                // resume and run before User hears about it (review round 4).
                guard let intent = item.dispatchIntent,
                      intent.attempt >= Self.maxDispatchAttemptsPerEvent,
                      item.dispatchReceipt?.dispatchId == intent.dispatchId else { return nil }
                return blockerIntent(for: item, version: version)
            case .codexFailed:
                // Outcome-unknown parks (empty terminal codex turn, failed
                // callback) never auto-replay, and nothing else will move
                // them — so User must hear about this one, exactly like
                // dispatchFailed/callbackOverdue. Dedup keeps it to one page
                // per parked state.
                return blockerIntent(for: item, version: version)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func blockerIntent(for item: GitHubCommandItem, version: String) -> GitHubCommandNotificationIntent? {
        guard let blocker = item.blocker, !blocker.detail.isEmpty, !blocker.owner.isEmpty else { return nil }
        let key = "\(item.itemId)+\(version)+blocker+\(item.state.name.rawValue)"
        return GitHubCommandNotificationIntent(
            dedupKey: key, itemId: item.itemId, kind: .blocker,
            title: "GitHub blocker",
            body: Self.bounded("\(item.repository) #\(item.number): \(blocker.detail) Owner: \(blocker.owner).", limit: 260)
        )
    }

    private static func dispatchId(eventKey: String) -> String {
        let digest = SHA256.hash(data: Data(eventKey.utf8))
        return "ghcmd_" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A distinct idempotency key for a verified-but-still-actionable retry.
    /// Salting by attempt guarantees a new inbox row instead of a dedup no-op.
    private static func dispatchId(eventKey: String, attempt: Int) -> String {
        dispatchId(eventKey: "\(eventKey)#retry\(attempt)")
    }

    /// A codex_working item is overdue when its dispatch receipt was queued
    /// longer ago than the store-owned window. codex_working already implies no
    /// callback (a callback moves the item to verifying), so no separate
    /// callback check is needed.
    private static func isCodexCallbackOverdue(_ item: GitHubCommandItem) -> Bool {
        guard let receipt = item.dispatchReceipt,
              let queuedAt = DeskClock.parseISO(receipt.queuedAt) else { return false }
        return Date().timeIntervalSince(queuedAt) > codexCallbackOverdueSeconds
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
    }

    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(value))
    }

    private static func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: value.serializedData(pretty: false))
    }
}
