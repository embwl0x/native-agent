import BackgroundLoops
import Foundation

/// The closed action vocabulary emitted on heartbeat-authored inbox cards.
/// These ids cross the persisted inbox boundary, so an unknown value must be
/// rejected before a card reaches the UI with a button no executor understands.
enum HeartbeatCardAction: String, CaseIterable, Sendable {
    case repair
    case openApprovals = "open_approvals"
    case archive
    case dismiss

    static let ids = Set(allCases.map(\.rawValue))

    private var isTerminal: Bool {
        self == .archive || self == .dismiss
    }

    var noticeAction: HeartbeatNoticeAction {
        switch self {
        case .repair:
            HeartbeatNoticeAction(
                id: rawValue,
                label: "Repair",
                description: "Close resolved Doctor self-heal proposals"
            )
        case .openApprovals:
            HeartbeatNoticeAction(
                id: rawValue,
                label: "Open Approvals",
                description: "Review approvals blocking Desk tasks"
            )
        case .archive:
            HeartbeatNoticeAction(id: rawValue, label: "Archive", description: "Archive this card")
        case .dismiss:
            HeartbeatNoticeAction(id: rawValue, label: "Dismiss", description: "Dismiss this card")
        }
    }

    /// Canonicalizes the condition-specific controls and always supplies the
    /// two terminal inbox controls. An unregistered authored id is a producer
    /// defect, not a reason to publish an unresolvable card.
    static func cardActions(
        authored: [HeartbeatNoticeAction]
    ) throws -> [HeartbeatNoticeAction] {
        let requested = Set(authored.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) })
        let unknown = requested.subtracting(ids)
        guard unknown.isEmpty else {
            throw HeartbeatCardActionError.unknownActionIDs(unknown.sorted())
        }
        return allCases
            .filter { !$0.isTerminal && requested.contains($0.rawValue) }
            .map(\.noticeAction)
            + [HeartbeatCardAction.archive.noticeAction, HeartbeatCardAction.dismiss.noticeAction]
    }
}

enum HeartbeatCardActionError: LocalizedError, Equatable {
    case unknownActionIDs([String])

    var errorDescription: String? {
        switch self {
        case .unknownActionIDs(let ids):
            "Heartbeat attempted to publish unsupported inbox action(s): \(ids.joined(separator: ", "))"
        }
    }
}
