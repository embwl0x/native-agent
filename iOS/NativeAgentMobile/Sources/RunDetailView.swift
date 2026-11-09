import SwiftUI
import NativeAgentShared
// Blueprint: | `RunDetailView.swift` | Saved run detail uses the signed document door and shared TextKit renderer |

struct RunDetailView: View {
    let run: RunRecord
    var body: some View { MobileDocumentPage(identity: run, subject: .run(run.id), title: "Run detail") }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(DeskStatusWords.word(for: status))
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NativeAgentMobileTheme.Colors.quietFill)
            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            .clipShape(Capsule())
    }
}
