import Foundation
// Blueprint: | `CountsFace.swift` | `CountsFace`, `CountReading`, `InboxCountsFace`: finished attention, availability and status values for the Mac face |

/// A retained count carries its source's availability; an unread source has no count.
public struct CountReading: FaceValue {
    public var value: Int?
    public var issue: String?
    public var isAvailable: Bool { value != nil && issue == nil }

    public init(value: Int? = nil, issue: String? = nil) {
        self.value = value
        self.issue = issue
    }
}

public struct InboxCountsFace: FaceValue {
    public var rows: [InboxItemRecord]
    public var noteIDs: [String]
    public var unread: CountReading
    public var isReading: Bool

    public init(rows: [InboxItemRecord] = [], noteIDs: [String] = [], unread: CountReading = .init(), isReading: Bool = false) {
        self.rows = rows
        self.noteIDs = noteIDs
        self.unread = unread
        self.isReading = isReading
    }
}

/// Feed data is presentation, never approval, delivery or freshness authority.
public struct CountsFace: FaceValue {
    public var inbox = InboxCountsFace()
    public var approvals = ApprovalsFace()
    public var memoryProposals = CountReading()
    public var helpers = CountReading()
    public var runningHelpers = CountReading()
    public var deskWaiting = CountReading()
    public var unreadSessionIDs: Set<String>?
    public var panels = PanelFreshnessFace()
    public var statuses = CountStatusValues()

    public init() {}
}
