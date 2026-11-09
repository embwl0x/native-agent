import Foundation
// Blueprint: | `TodayView.swift` | Activity section names for body navigation requests |

enum ActivitySection: String, Sendable, Identifiable {
    case approvals
    case inbox
    case memoryProposals
    case cognitionProposals

    var id: String { rawValue }

    var sheetTitle: String {
        switch self {
        case .approvals, .inbox: "Inbox"
        case .memoryProposals: "Memories to look at"
        case .cognitionProposals: "REM Replay Lineage"
        }
    }
}

// MARK: - Today face and Activity destinations
