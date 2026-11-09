import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskStatus.swift` | Desk and task status words |

// MARK: - Desk words

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
