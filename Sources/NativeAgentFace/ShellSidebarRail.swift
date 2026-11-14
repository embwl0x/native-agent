import NativeAgentShared
import SwiftUI

// Blueprint: | `ShellSidebarRail.swift` | The rail; place rows shared with Simple, the Desk row's waiting mark, selection bar and focus ring |

/// Retained rows must not hide the conversation list's unavailable cause.
struct SessionNavigationNotice: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        ConversationReadNotice(detail: appModel.face.slot(.sessionNavigation).select("navigationNotice", as: SessionNavigationFace.self) {
            (value: SessionNavigationFace?) -> String? in
            guard let status = value else { return "Waiting on the conversation list…" }
            if let issue = status.issue { return issue }
            return status.hasLoadedIndex ? nil : "Waiting on the conversation list…"
        })
    }
}

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
    var title: String
    var help: String
    var identifier: String
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
                Text(title)
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
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(attentionUnavailable
            ? "\(title), attention unavailable"
            : needsYou ? "\(title), waiting for you" : title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Match the rail's rounded plate instead of using the square system focus ring.
struct ShellRailFocusRing: View {
    @FacePreference(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var ringColor: Color {
        if contrast == .increased { return NativeAgentShell.text }
        let haze = HazeColor(stored: hazeRaw)
        return colorScheme == .dark ? haze.edgeLight : Color(nsColor: haze.control(dark: false, labelled: false))
    }

    var body: some View {
        FacePreferences(keys: [HazeColor.key]) { preferenceContent }
    }

    private var preferenceContent: some View {
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
    @Environment(\.layoutProfile) private var layoutProfile
    /// The surface the window shows: the one its selected page belongs to.
    var surface: ShellSurface
    /// Choosing a surface, with the pages the layout shows of it.
    var choose: (ShellSurface, [ShellRailRow]) -> Void

    /// One identity preserves the bar's continuity between rows.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Anchor Diagnostics at the foot so the advanced view stays apart from the places of work.
        SurfaceLayoutContent(appModel.shellLayout) { layout in
        let surfaces = ShellSurface.shown(layout, profile: layoutProfile)
        VStack(spacing: 4) {
            SessionNavigationNotice()
            ForEach(surfaces.filter { $0.surface != .diagnostics }) { row($0) }
            Spacer(minLength: 8)
            if let foot = surfaces.first(where: { $0.surface == .diagnostics }) { row(foot) }
        }
        // Animate the whole rail in one transaction so departing and arriving bars stay in sync.
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: surface
        )
        }
        // Align rail words to the header baseline and retain the same foot inset.
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

    private func row(_ shown: ShellSurfacePages) -> some View {
        ShellPlaceRow(place: shown, isSelected: shown.surface == surface, barNamespace: selectionBar) { choose(shown.surface, shown.pages) }
    }
}

/// One place's row, the same in Advanced's rail and Simple's sidebar: its word, the pages it holds as help, and on Desk whether something
/// waits on the person.
struct ShellPlaceRow: View {
    @Environment(AppModel.self) private var appModel
    let place: ShellSurfacePages
    let isSelected: Bool
    let barNamespace: Namespace.ID
    let onSelect: () -> Void

    var body: some View {
        let title = place.surface.title(appModel)
        // The row's help names the pages it holds, in the order its tabs show them.
        let words = ShellPageWords(appModel, pages: place.pages)
        let help = place.pages.map { words.title($0) }.joined(separator: ", ")
        let identifier = "sidebar.surface.\(place.surface.rawValue)"
        if place.surface == .desk {
            ShellAttentionRailItem(title: title, help: help, identifier: identifier, isSelected: isSelected,
                                   barNamespace: barNamespace, onSelect: onSelect)
        } else {
            ShellRailItem(title: title, help: help, identifier: identifier, isSelected: isSelected,
                          onSelect: onSelect, barNamespace: barNamespace)
        }
    }
}

/// The Desk row carries whether something waits on the person; reading it here keeps the count's changes from redrawing the rail.
private struct ShellAttentionRailItem: View {
    @Environment(AppModel.self) private var appModel
    let title: String
    let help: String
    let identifier: String
    let isSelected: Bool
    let barNamespace: Namespace.ID
    let onSelect: () -> Void

    var body: some View {
        let waiting = appModel.waitingOnPerson
        ShellRailItem(title: title, help: help, identifier: identifier, isSelected: isSelected, needsYou: waiting == true,
                      attentionUnavailable: waiting == nil, onSelect: onSelect, barNamespace: barNamespace)
    }
}
