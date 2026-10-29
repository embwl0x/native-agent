import NativeAgentShared
import AppToolRuntime
import SwiftUI

// Blueprint: | `ShellSidebarRail.swift` | `ShellSidebarRail`: canonical rail item presentation, selection and focus-ring rendering |

/// One word in the rail, with the bar when it is the place you are.
struct ShellRailItem: View {
    var item: SidebarItem
    var isSelected: Bool
    /// Something is waiting on him in this place. One 6pt dot after the word —
    /// no number, no pill. The rail says THAT there is something; the page
    /// says what it is.
    var needsYou: Bool = false
    var onSelect: () -> Void
    /// Shared with every other row so the selection bar can travel between
    /// them instead of blinking off one row and on at the next.
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
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, NativeAgentShellLayout.railWordInset)
            .frame(height: NativeAgentShellLayout.railItemHeight)
            .overlay(alignment: .leading) {
                // The bar: 2pt wide, 20pt tall, 4pt in from the edge. Only the
                // selected row renders it, so matchedGeometryEffect carries it
                // from the old place to the new one — an identity marker has to
                // travel or the causal link is lost. Under Reduce Motion every
                // row keeps its own bar and they cross-fade: travel is exactly
                // what that setting asks us to drop.
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
        // Space presses a focused Button; Return does the same here.
        .onKeyPress(.return) { onSelect(); return .handled }
        .onHover { hovering = $0 }
        .help(item.displayName)
        .accessibilityIdentifier("sidebar.item.\(item.rawValue)")
        .accessibilityLabel(needsYou ? "\(item.shellRailTitle), waiting for you" : item.shellRailTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Keyboard focus on a rail word: a rounded ring in the haze's edge light,
/// inset like the plate's own corners, instead of the square system ring.
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

/// Quiet groups on a floating glass plate, as the layout orders them, with
/// the last (Settings, as seeded) at the foot.
struct ShellSidebarRail: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: SidebarItem
    /// The places that have something waiting on him. A dot, never a count —
    /// the caller does the counting and this rail only says whether.
    var needsYou: Set<SidebarItem> = []

    /// The one id the travelling selection bar is known by.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Every row but the last renders at the top; the last is pushed to the
        // bottom, so the setup door is never mistaken for a place to work.
        let rail = SidebarItem.rail(appModel.engine.layout.layout)
        VStack(spacing: 4) {
            ForEach(rail.dropLast(), id: \.self) { row(item: $0) }
            Spacer(minLength: 8)
            if let last = rail.last { row(item: last) }
        }
        // The bar's travel is one transaction over the whole rail, so both the
        // leaving and the arriving row read the same animation.
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: selection
        )
        // Rail words share the shell header's baseline at window y 72; Settings keeps the same bottom inset.
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
                          needsYou: needsYou.contains(item.normalized), onSelect: { selection = item },
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
