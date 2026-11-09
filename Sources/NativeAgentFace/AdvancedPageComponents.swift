import Foundation
import SwiftUI
// Blueprint: | `AdvancedPageComponents.swift` | Inline page-read status and checked display words for item status |

/// Keep cached content mounted while the page read reports its status.
struct PageReadStatus: View {
    let isReading: Bool
    var text: String?

    var body: some View {
        HStack(spacing: 8) {
            if isReading { ProgressView().controlSize(.small) }
            if let text {
                Text(text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24, alignment: .leading)
    }
}

/// Reserve teal for waiting on a person; calm, trouble and quiet ink distinguish the other states.
enum AdvancedStatusWords {
    static func color(_ status: String?) -> Color {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "awaiting_approval", "needs_approval":
            return NativeAgentShell.needsYou
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready",
             "scheduled", "granted", "installed", "approved", "trusted", "healthy":
            return NativeAgentShell.calm
        case "fail", "failed", "error", "timeout", "quarantined", "evidence_failed",
             "denied", "revoked", "refused", "warn", "warning", "blocked",
             "needs_setup", "interrupted", "disabled", "rolled_back", "stale":
            return NativeAgentShell.trouble
        default:
            return NativeAgentShell.secondary
        }
    }

    /// Translate storage slugs into readable labels.
    static func label(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = known[trimmed.lowercased()] { return known }
        let spaced = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first, first.isLowercase else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    private static let known: [String: String] = [
        "ok": "OK",
        "warn": "Warning",
        "fail": "Failed",
        "info": "Working",
    ]
}
