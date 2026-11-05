import NativeAgentShared
import AppToolRuntime
import SwiftUI

// Blueprint: | `ShellSidebarRail.swift` | `ShellSidebarRail`: canonical rail item presentation, selection and focus-ring rendering |

/// Retained rows must not hide the conversation list's unavailable cause.
struct ConversationReadNotice: View {
    let detail: String?
    var body: some View {
        if let detail {
            Label(detail, systemImage: "exclamationmark.triangle")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("conversations.read-unavailable")
        }
    }
}

struct ShellRailItem: View {
    var item: SidebarItem
    var isSelected: Bool
    /// Show only whether attention is needed; the page owns the details.
    var needsYou: Bool = false
    var attentionUnavailable = false
    var onSelect: () -> Void
    /// Share identity across rows so the selection bar can travel instead of blinking.
    var barNamespace: Namespace.ID

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Text(item.shellRailTitle)
                    .font(ShellType.rail)
                    .foregroundStyle(isSelected ? NativeAgentShell.text
                        : (hovering ? NativeAgentShell.text.opacity(0.75) : NativeAgentShell.secondary))
                    // Scope hover animation to the word so selection-bar travel keeps the rail's transaction.
                    .animation(
                        NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
                        value: hovering
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if needsYou {
                    Circle()
                        .fill(NativeAgentShell.needsYou)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                } else if attentionUnavailable {
                    Image(systemName: "questionmark.circle")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .help("Attention unavailable. Open Today to inspect the source read problem.")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .frame(height: NativeAgentShellLayout.railItemHeight)
            .overlay(alignment: .leading) {
                // Share bar identity to preserve selection continuity; Reduce Motion crossfades stationary bars.
                let bar = RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(NativeAgentShell.text)
                    .frame(width: 2, height: 20)
                    .padding(.leading, NativeAgentShellLayout.barInset)
                if reduceMotion {
                    bar.opacity(isSelected ? 1 : 0)
                        .animation(NativeAgentMotion.crossfade, value: isSelected)
                } else if isSelected {
                    bar.matchedGeometryEffect(
                        id: ShellSidebarRail.selectionBarID,
                        in: barNamespace
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellKeyboardTarget(.rail)
        // Return must activate a focused button just as Space does.
        .onKeyPress(.return) { onSelect(); return .handled }
        .onHover { hovering = $0 }
        .help(item.displayName)
        .accessibilityIdentifier("sidebar.item.\(item.rawValue)")
        .accessibilityLabel(attentionUnavailable
            ? "\(item.shellRailTitle), attention unavailable"
            : needsYou ? "\(item.shellRailTitle), waiting for you" : item.shellRailTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Match the rail's rounded plate instead of using the square system focus ring.
struct ShellRailFocusRing: View {
    @AppStorage(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var ringColor: Color {
        if contrast == .increased { return NativeAgentShell.text }
        let haze = HazeColor(stored: hazeRaw)
        return colorScheme == .dark ? haze.edgeLight : Color(nsColor: haze.control(dark: false, labelled: false))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(ringColor, lineWidth: colorScheme == .light || contrast == .increased ? 2 : 1.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ShellSidebarRail: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: SidebarItem
    /// The caller owns counts; the rail exposes only whether attention is needed.
    var needsYou: Set<SidebarItem>? = []
    var attentionItem: SidebarItem? = nil

    /// One identity preserves the bar's continuity between rows.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Anchor Settings at the foot so setup stays distinct from work destinations.
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        let rail = SidebarItem.rail(layout)
        VStack(spacing: 4) {
            ConversationReadNotice(detail: appModel.engine.transcripts.navigationReadIssue)
            ForEach(rail.dropLast(), id: \.self) { row(item: $0) }
            Spacer(minLength: 8)
            if let last = rail.last { row(item: last) }
        }
        // Animate the whole rail in one transaction so departing and arriving bars stay in sync.
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: selection
        )
        }
        // Align rail words to the header baseline and retain the same Settings inset.
        .padding(.top, 14 - NativeAgentShellLayout.railPlateInset)
        .padding(.bottom, 14 - NativeAgentShellLayout.railPlateInset)
        .frame(width: NativeAgentShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        // Only the rail floats on clear glass; reduced transparency leaves it flat over the opaque room.
        .background {
            ThinkingGlow(kind: .shimmer, cornerRadius: NativeAgentShellLayout.railPlateRadius)
        }
        .glassEffect(
            reduceTransparency ? .identity : HouseGlass.plate,
            in: RoundedRectangle(cornerRadius: NativeAgentShellLayout.railPlateRadius, style: .continuous)
        )
        .padding([.top, .bottom, .leading], NativeAgentShellLayout.railPlateInset)
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }

    @ViewBuilder
    private func row(item: SidebarItem?) -> some View {
        if let item {
            ShellRailItem(item: item, isSelected: selection.normalized == item.normalized,
                          needsYou: needsYou?.contains(item.normalized) == true,
                          attentionUnavailable: needsYou == nil && attentionItem?.normalized == item.normalized,
                          onSelect: { selection = item },
                          barNamespace: selectionBar)
        } else {
            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(height: 1)
                .padding(.horizontal, NativeAgentShellLayout.railWordInset)
                .padding(.vertical, 6)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
        }
    }
}
