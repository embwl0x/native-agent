import Foundation

// Blueprint: | `MobileDeskSnapshot.swift` | `DeskKind`, `DeskStatus`, `WorkOverview`: bounded Desk copies; no decision authority |

public enum DeskKind: String, Sendable, CaseIterable, Equatable {
    case watch, plan, project, gh, standing
}

public enum DeskStatus: String, Sendable, CaseIterable, Equatable {
    case watch, flag, now, next, todo, done, blocked, canceled

    /// done / canceled are terminal — an item is archivable only once terminal, and a parent refuses archive while any child is non-terminal.
    public var isTerminal: Bool { self == .done || self == .canceled }
}

public extension DeskStatus {
    var displayLabel: String {
        switch self {
        case .now: "now"
        case .next: "next"
        case .blocked: "blocked"
        case .flag: "needs attention"
        case .done: "done"
        case .todo: "to do"
        case .watch: "watching"
        case .canceled: "cancelled"
        }
    }
}

/// A reading copy, never a second work or decision owner. References use the canonical identity rather than a title, alias, path, or chat draft.
public struct WorkOverviewReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case desk, approval, execution, inbox
    }
    public var kind: Kind
    public var id: String
    public init(kind: Kind, id: String) { self.kind = kind; self.id = id }
}

public struct WorkOverviewRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(reference.kind.rawValue):\(reference.id)" }
    public var reference: WorkOverviewReference
    public var title: String
    public var summary: String
    public var detail: String
    public var state: String
    public var updatedAt: String
    public var location: String?
    public var movementAt: String?

    public init(reference: WorkOverviewReference, title: String, summary: String,
                detail: String, state: String, updatedAt: String, location: String? = nil,
                movementAt: String? = nil) {
        self.reference = reference
        self.title = title
        self.summary = summary
        self.detail = detail
        self.state = state
        self.updatedAt = updatedAt
        self.location = location
        self.movementAt = movementAt
    }

    public func stateLabel(at now: Date) -> String {
        if state == "running" {
            return DeskActivityState.execution(.init(deskHandle: nil, status: state,
                updatedAt: updatedAt, lastMovementAt: movementAt), now: now).label
        }
        return state
    }
}

public struct WorkOverview: Codable, Equatable, Sendable {
    public var experienceRevision: Int? = 1
    public var experiences: [Experience]? = nil
    /// Full owner counts, before the phone's bounded list is cut.
    public var needsYouCounts: [WorkOverviewReference.Kind: Int]? = nil
    /// When the mobile overview last changed; installed phones use this to refuse older deliveries.
    public var capturedAt: String
    public var now: [WorkOverviewRow]
    public var needsYou: [WorkOverviewRow]
    public var recentlyDone: [WorkOverviewRow]
    public var unavailable: [String]
    public var omittedNow: Int
    public var omittedNeedsYou: Int
    public var omittedRecentlyDone: Int

    public init(capturedAt: String, now: [WorkOverviewRow], needsYou: [WorkOverviewRow],
                recentlyDone: [WorkOverviewRow], unavailable: [String],
                omittedNow: Int = 0, omittedNeedsYou: Int = 0, omittedRecentlyDone: Int = 0) {
        self.capturedAt = capturedAt
        self.now = now
        self.needsYou = needsYou
        self.recentlyDone = recentlyDone
        self.unavailable = unavailable
        self.omittedNow = omittedNow
        self.omittedNeedsYou = omittedNeedsYou
        self.omittedRecentlyDone = omittedRecentlyDone
    }

    private enum CodingKeys: String, CodingKey {
        case experienceRevision, experiences, needsYouCounts, capturedAt, now, needsYou, recentlyDone, unavailable
        case omittedNow, omittedNeedsYou, omittedRecentlyDone
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(experienceRevision, forKey: .experienceRevision)
        try container.encodeIfPresent(experiences, forKey: .experiences)
        try container.encode(capturedAt, forKey: .capturedAt)
        if let needsYouCounts {
            // Enum-keyed dictionaries encode as alternating key/value arrays. Sort at this producer;
            // JSON sortedKeys cannot order arrays. Keep the wire shape the phone already decodes.
            var counts = container.nestedUnkeyedContainer(forKey: .needsYouCounts)
            for (kind, count) in needsYouCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                try counts.encode(kind)
                try counts.encode(count)
            }
        }
        try container.encode(now, forKey: .now)
        try container.encode(needsYou, forKey: .needsYou)
        try container.encode(recentlyDone, forKey: .recentlyDone)
        try container.encode(unavailable, forKey: .unavailable)
        try container.encode(omittedNow, forKey: .omittedNow)
        try container.encode(omittedNeedsYou, forKey: .omittedNeedsYou)
        try container.encode(omittedRecentlyDone, forKey: .omittedRecentlyDone)
    }

    public var needsYouCount: Int { needsYou.count + omittedNeedsYou }

    public var headline: String {
        guard unavailable.isEmpty else { return "Part of the overview is unavailable." }
        let waiting = needsYouCount
        return waiting == 0 ? "Nothing needs you on this overview."
            : "\(waiting) \(waiting == 1 ? "thing needs" : "things need") you."
    }

    public var needsYouOverflow: String? {
        omittedNeedsYou > 0 ? "And \(omittedNeedsYou) more waiting in Approvals, Inbox, and Desk." : nil
    }
}

/// Execution-owned movement, independent of edits to a Desk row.
public struct DeskExecutionEvidence: Codable, Equatable, Sendable {
    public var deskHandle: String?
    public var status: String
    public var updatedAt: String?
    public var lastMovementAt: String?

    public init(deskHandle: String?, status: String, updatedAt: String?, lastMovementAt: String? = nil) {
        self.deskHandle = deskHandle
        self.status = status
        self.updatedAt = updatedAt
        self.lastMovementAt = lastMovementAt
    }
}

public enum DeskActivityState: String, Sendable {
    case working, queued, watching, deferred, blocked, stale, unknown, finished

    public static let movementWindow: TimeInterval = 5 * 60

    public static func movementDate(_ raw: String?) -> Date? {
        raw.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst)
    }

    public static func execution(_ evidence: DeskExecutionEvidence?, now: Date) -> Self {
        guard let evidence else { return .unknown }
        if evidence.status == "queued" { return .queued }
        if evidence.status == "blocked_on_approval" { return .blocked }
        guard evidence.status == "running",
              let movement = movementDate(evidence.lastMovementAt), movement <= now else { return .unknown }
        return now.timeIntervalSince(movement) < movementWindow ? .working : .stale
    }

    public static func item(
        status: String, kind: String, deferred: Bool, updatedAt: String,
        evidence: DeskExecutionEvidence?, now: Date
    ) -> Self {
        if ["done", "canceled"].contains(status) { return .finished }
        let execution = execution(evidence, now: now)
        if execution != .unknown { return execution }
        if deferred { return .deferred }
        if status == "blocked" { return .blocked }
        if status == "watch" || kind == "watch" { return .watching }
        if ["todo", "next"].contains(status) { return .queued }
        if status == "now", let updated = movementDate(updatedAt),
           now.timeIntervalSince(updated) >= movementWindow { return .stale }
        return .unknown
    }

    public var label: String {
        switch self {
        case .working: "Working"
        case .queued: "Queued"
        case .watching: "Watching"
        case .deferred: "Deferred"
        case .blocked: "Blocked"
        case .stale: "Stale — activity unconfirmed"
        case .unknown: "Activity unknown"
        case .finished: "Finished"
        }
    }
}

/// Bounded, rebuildable projection of the Mac-owned Desk for companion devices. Stable handles are used for every mutation; aliases are display-only.
public struct MobileDeskNote: Codable, Equatable, Sendable {
    public var timestamp: String
    public var text: String

    public init(timestamp: String, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public struct MobileDeskItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { handle }
    public var handle: String
    public var alias: String
    public var parent: String?
    public var kind: String
    public var status: String
    public var project: String
    public var title: String
    public var summary: String?
    public var openedAt: String
    public var updatedAt: String
    public var closedAt: String?
    public var pinned: Bool
    public var blockedReason: String?
    public var waitingOn: String?
    public var blockedOn: [String]
    public var deferUntil: String?
    public var origin: String
    public var requiresOwnerInput: Bool
    public var recentNotes: [MobileDeskNote]
    public var executionEvidence: DeskExecutionEvidence?

    public init(
        handle: String, alias: String, parent: String?, kind: String, status: String,
        project: String, title: String, summary: String?, openedAt: String,
        updatedAt: String, closedAt: String?, pinned: Bool, blockedReason: String?,
        waitingOn: String?, blockedOn: [String], deferUntil: String?, origin: String,
        requiresOwnerInput: Bool, recentNotes: [MobileDeskNote],
        executionEvidence: DeskExecutionEvidence? = nil
    ) {
        self.handle = handle
        self.alias = alias
        self.parent = parent
        self.kind = kind
        self.status = status
        self.project = project
        self.title = title
        self.summary = summary
        self.openedAt = openedAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.pinned = pinned
        self.blockedReason = blockedReason
        self.waitingOn = waitingOn
        self.blockedOn = blockedOn
        self.deferUntil = deferUntil
        self.origin = origin
        self.requiresOwnerInput = requiresOwnerInput
        self.recentNotes = recentNotes
        self.executionEvidence = executionEvidence
    }

    public func activity(at now: Date) -> DeskActivityState {
        DeskActivityState.item(
            status: status, kind: kind, deferred: deferUntil != nil,
            updatedAt: updatedAt, evidence: executionEvidence, now: now)
    }
}


/// Bounded reading copies carry the source `capturedAt` so the phone shows their age rather than implying live state.
public struct MobileDeskItemReadingCopy: Codable, Equatable, Identifiable, Sendable {
    public var id: String { handle }
    public var handle: String
    public var capturedAt: String
    public var summary: String?
    public var blockedReason: String?
    public var notes: [MobileDeskNote]

    public init(
        handle: String,
        capturedAt: String,
        summary: String?,
        blockedReason: String?,
        notes: [MobileDeskNote]
    ) {
        self.handle = handle
        self.capturedAt = capturedAt
        self.summary = summary
        self.blockedReason = blockedReason
        self.notes = notes
    }
}

/// Published Desk omissions are authoritative for both row and size bounds; readers never infer them.
public struct MobileDeskProjectionReport: Codable, Equatable, Sendable {
    /// Desk items the Mac holds, before any bound was applied.
    public var totalRows: Int
    public var includedRows: Int
    /// Items the bounds dropped. Authoritative — never recomputed by a reader.
    public var omittedCount: Int
    public var truncated: Bool

    public init(totalRows: Int, includedRows: Int) {
        self.totalRows = totalRows
        self.includedRows = includedRows
        let omitted = max(0, totalRows - includedRows)
        self.omittedCount = omitted
        self.truncated = omitted > 0
    }
}

public enum MobileDeskProjectionBounds {
    public static let maximumRows = 300
    public static let maximumSummaryCharacters = 2_000
    public static let maximumNoteCharacters = 2_000
    /// Mark every clipped string so readers cannot mistake an incomplete sentence for the whole text.
    public static let truncationMark = "…"

    public static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + truncationMark
    }

    public static func isClipped(_ text: String) -> Bool {
        text.hasSuffix(truncationMark)
    }
}
