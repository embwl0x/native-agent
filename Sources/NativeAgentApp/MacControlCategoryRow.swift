import MacIntegration
import NativeAgentCore
import AppToolRuntime
import ChatToolParsing
import PersistenceCore
import AppKit
import MacControl
import NativeAgentShared
import SwiftUI
import TrustCenter
// Blueprint: | `MacControlCategoryRow.swift` | Mac control capability switches and explicit unavailable-category presentation |
internal struct MacControlCategoryRow: View {
    let label: String
    let detail: String
    let safeDefault: Bool
    let masterEnabled: Bool
    @Binding var isOn: Bool
    var body: some View {
        let notes = [
            masterEnabled ? nil : "Turning this on also turns on Mac control.",
            safeDefault ? "Safe by default." : nil,
        ].compactMap { $0 }
        FeatureSwitchRow(
            title: label,
            detail: detail,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            isOn: $isOn
        )
    }
}
/// A capability the Swift Mac Control runtime deliberately does not offer yet.
/// It is a status row rather than a disabled Toggle: a toggle suggests a user
/// can make the action available, while these actions would only return 501.
/// A state, not trouble: the word is quiet.
internal struct MacControlUnavailableCategoryRow: View {
    let label: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                Text(detail)
                    .font(ShellType.rowDetail)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text("Not available")
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
