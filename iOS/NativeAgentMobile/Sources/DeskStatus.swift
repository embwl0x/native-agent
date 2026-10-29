import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskStatus.swift` | Desk and task status marks, status words and kind words |

// MARK: - Desk words and marks (shared with Desk tasks)

/// A status as a small mark: a breathing dot for what I'm doing now, a check
/// for done, a filled dot for next, a ring for the rest. The word beside it
/// carries the meaning; the mark is never coloured.
struct DeskStatusMark: View {
    let status: String
    var movementAt: String? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let movement = movementAt.flatMap(UserDisplayFormatters.parseISOTimestamp)
        let expiry = movement?.addingTimeInterval(DeskActivityState.movementWindow)
        return TimelineView(.explicit(expiry.map { [$0] } ?? [])) { context in
            switch status.lowercased() {
            case "now", "running", "active":
                let active = scenePhase == .active && movement.map { $0 <= context.date } == true
                    && expiry.map { context.date < $0 } == true
                PulsingDot(color: AlivePalette.text, size: 7, isActive: active)
            case "done", "completed", "succeeded":
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AlivePalette.secondary)
            case "next":
                Circle().fill(AlivePalette.secondary).frame(width: 7, height: 7)
            default:
                Circle().strokeBorder(AlivePalette.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Plain words for Desk and task statuses.
enum DeskStatusWords {
    static func word(for status: String) -> String {
        switch status.lowercased() {
        case "now": return "Doing now"
        case "next": return "Up next"
        case "todo": return "To do"
        case "watch": return "Watching"
        case "flag": return "Flagged"
        case "blocked": return "Stuck"
        case "done", "completed", "succeeded": return "Done"
        case "canceled", "cancelled": return "Canceled"
        case "active", "running": return "Working"
        case "queued": return "Waiting its turn"
        case "paused": return "Paused"
        case "failed", "error", "timeout": return "Didn't finish"
        default:
            if status.lowercased().contains("approval") { return "Needs your yes" }
            return AliveWords.humanized(status.lowercased())
        }
    }
}

enum DeskKindWords {
    static func word(for kind: String) -> String {
        switch kind.lowercased() {
        case "gh": return "GitHub"
        case "standing": return "Standing"
        case "watch": return "Watch"
        default: return AliveWords.humanized(kind.lowercased())
        }
    }
}
