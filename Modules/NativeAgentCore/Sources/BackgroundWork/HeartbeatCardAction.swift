import BackgroundLoops
import Foundation
// Blueprint: | `HeartbeatCardAction.swift` | `HeartbeatCardAction` enum; `cardActions` |

/// Reject unknown persisted action ids before publishing a button that no executor understands.
public enum HeartbeatCardAction: String, CaseIterable, Sendable {
    case openApprovals = "open_approvals"
    case archive
    case dismiss

    public static let ids = Set(allCases.map(\.rawValue))

    private var isTerminal: Bool {
        self == .archive || self == .dismiss
    }

    public var noticeAction: HeartbeatNoticeAction {
        switch self {
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

    /// Terminal inbox controls always remain; an unregistered authored id is a producer defect.
    public static func cardActions(
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

public enum HeartbeatCardActionError: LocalizedError, Equatable {
    case unknownActionIDs([String])

    public var errorDescription: String? {
        switch self {
        case .unknownActionIDs(let ids):
            "Heartbeat attempted to publish unsupported inbox action(s): \(ids.joined(separator: ", "))"
        }
    }
}
