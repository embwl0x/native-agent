import Foundation

/// Bounded, rebuildable projection of the Mac-owned Desk for companion devices.
/// Stable handles are used for every mutation; aliases are display-only.
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

    public init(
        handle: String, alias: String, parent: String?, kind: String, status: String,
        project: String, title: String, summary: String?, openedAt: String,
        updatedAt: String, closedAt: String?, pinned: Bool, blockedReason: String?,
        waitingOn: String?, blockedOn: [String], deferUntil: String?, origin: String,
        requiresOwnerInput: Bool, recentNotes: [MobileDeskNote]
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
    }
}


/// The published bounds of the Desk projection, shared so a companion device
/// can show where the boundary is instead of presenting a clipped projection as
/// the whole store. Silent truncation was the defect, not the bounds.
/// What the Mac LEFT OUT of the Desk projection, published explicitly.
/// 2026-09-12: the phone used to infer truncation from "I received at least 300
/// rows", which missed every drop made to satisfy the encoded-size bound (a
/// projection cut to 180 fat rows showed no boundary at all) and said nothing
/// when the rows it did receive were all in non-history sections.
public struct MobileDeskProjectionReport: Codable, Equatable, Sendable {
    /// Desk items the Mac holds, before any bound was applied.
    public var totalRows: Int
    /// Items actually published in desk.json.
    public var includedRows: Int
    /// Items the bounds dropped. Authoritative — never recomputed by a reader.
    public var omittedCount: Int
    /// True when anything was dropped, by either the row cap or the size cap.
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
    /// Every clipped string ends with this, so no reader mistakes a cut
    /// sentence ("three watchdog kills on healthy sessi") for the whole text.
    public static let truncationMark = "…"

    public static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + truncationMark
    }

    public static func isClipped(_ text: String) -> Bool {
        text.hasSuffix(truncationMark)
    }
}
