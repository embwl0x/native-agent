import CryptoKit
import Foundation

public enum GitHubCommandItemKind: String, Codable, Sendable, CaseIterable {
    case pullRequest = "pull_request"
    case issue
}

public enum GitHubCommandActionSignal: String, Codable, Sendable, CaseIterable, Hashable {
    case reviewComment = "review_comment"
    case issueComment = "issue_comment"
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

/// Bounded descriptive evidence captured during the canonical GitHub read for
/// Desk inspection and watcher notifications. It grants no action authority.
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
    case actionable
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
    // Failure detail from the codex completion callback (task #45): the
    // provider/runtime error text and the three-state resend-safety signal
    // (true = no work observed before the failure, false = partial work may
    // exist, nil = unknown). Inline defaults keep the memberwise init and any
    // cached snapshot decode-compatible.
    public var lastCallbackErrorMessage: String? = nil
    public var lastCallbackNoWorkObserved: Bool? = nil
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
    /// ops_base.json EXISTS but its bytes could not be read (fd exhaustion, an
    /// iCloud dataless placeholder, a transient IO error). Deliberately NOT an
    /// `invariantViolation`: that one is permanent corruption and wedges every
    /// reader and writer, this one is transient and the caller may retry.
    case baseUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidObservation(let detail): return "Invalid GitHub Command observation: \(detail)"
        case .unknownItem(let id): return "Unknown GitHub Command item \(id)."
        case .invalidTransition(let detail): return "Invalid GitHub Command transition: \(detail)"
        case .malformedOperation: return "GitHub Command operation feed contains an unreadable row."
        case .invariantViolation(let detail): return "GitHub Command invariant failed: \(detail)"
        case .baseUnreadable(let path): return "GitHub Command compaction base at \(path) exists but its bytes could not be read (transient IO); retry rather than treating the feed as corrupt."
        }
    }
}
