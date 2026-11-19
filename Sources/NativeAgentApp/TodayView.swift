import Foundation
// Blueprint: | `TodayView.swift` | Activity section names for body navigation requests |

enum ActivitySection: String, Sendable, Identifiable {
    case approvals
    case inbox
    case memoryProposals
    case cognitionProposals

    var id: String { rawValue }

}

// MARK: - Today face and Activity destinations
