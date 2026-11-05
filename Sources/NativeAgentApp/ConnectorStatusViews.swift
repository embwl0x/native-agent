import SwiftUI
// Blueprint: | `ConnectorStatusViews.swift` | Status pill and note still shared by the iPhone pairing and agent-contact instruments |

/// Keep the status word readable without tint: calm and trouble fail 4.5:1 on the card fill.
struct ConnectorsStatusPill: View {
    let text: String
    let tone: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(ShellType.rowDetail.weight(.medium))
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(reduceTransparency ? TodayPalette.cardFill : NativeAgentShell.softFill))
        .overlay(Capsule().strokeBorder(AlivePalette.rim, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct ConnectorsNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
