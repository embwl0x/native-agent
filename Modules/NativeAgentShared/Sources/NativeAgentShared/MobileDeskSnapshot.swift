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

