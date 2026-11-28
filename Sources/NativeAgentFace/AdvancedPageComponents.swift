import Foundation
import SwiftUI
// Blueprint: | `AdvancedPageComponents.swift` | Inline page-read status and checked display words for item status |

/// Keep cached content mounted while the page read reports its status.
struct PageReadStatus: View {
    var text: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
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

enum AdvancedStatusWords {
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
