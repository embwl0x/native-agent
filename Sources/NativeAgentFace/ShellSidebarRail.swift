import NativeAgentShared
import SwiftUI

// Blueprint: | `ShellSidebarRail.swift` | Canonical rail rows, unavailable page owners, selection and focus rings |

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

extension ShellRailItem {
    init(item: SidebarItem, isSelected: Bool, needsYou: Bool, attentionUnavailable: Bool, onSelect: @escaping () -> Void,
         barNamespace: Namespace.ID) {
        self.init(title: item.shellRailTitle, help: item.displayName, identifier: "sidebar.item.\(item.rawValue)", isSelected: isSelected,
                  needsYou: needsYou, attentionUnavailable: attentionUnavailable, onSelect: onSelect, barNamespace: barNamespace)
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
    @Binding var selection: SidebarItem
    /// The page of the agent's own the window shows (the selection is `.ownPage`), and how a row selects one.
    var selectedPage: String?
    var selectPage: (String) -> Void

    /// One identity preserves the bar's continuity between rows.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Anchor Settings at the foot so setup stays distinct from work destinations.
        SurfaceLayoutContent(appModel.shellLayout) { layout in
        let rail = SidebarItem.railRows(layout)
        let pageIDs = Set(rail.compactMap { row -> String? in if case .page(let id) = row { id } else { nil } })
        let own = Dictionary(uniqueKeysWithValues: QuietPages.own(appModel, ids: pageIDs).map { ($0.id, $0.title) })
        let catalog = appModel.face.slot(PageFaceKey.catalog).value(as: PartFaceCatalog.self)
        VStack(spacing: 4) {
            SessionNavigationNotice()
            ForEach(rail.dropLast(), id: \.self) { row($0, own: own, catalog: catalog) }
            Spacer(minLength: 8)
            if let last = rail.last { row(last, own: own, catalog: catalog) }
        }
        // Animate the whole rail in one transaction so departing and arriving bars stay in sync.
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: selection
        )
        .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion), value: selectedPage)
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
    private func row(_ row: ShellRailRow, own: [String: String], catalog: PartFaceCatalog?) -> some View {
        switch row {
        case .item(let item):
            if item == .activity {
                ShellAttentionRailItem(isSelected: selection == item, barNamespace: selectionBar) { selection = item }
            } else {
                ShellRailItem(item: item, isSelected: selection == item, needsYou: false, attentionUnavailable: false,
                              onSelect: { selection = item }, barNamespace: selectionBar)
            }
        case .page(let page):
            let words: (title: String, help: String) = if let title = own[page] { (title, title) }
                else if let failure = catalog?.failure { ("\(page) · unavailable", failure.message) }
                else if catalog == nil { ("\(page) · waiting", "Waiting on the authored-page inventory.") }
                else { ("\(page) · unclaimed", "No active part claims this page. Open it to read its status.") }
            ShellRailItem(title: words.title, help: words.help, identifier: "sidebar.page.\(page)",
                          isSelected: selection == .ownPage && selectedPage == page,
                          onSelect: { selectPage(page) }, barNamespace: selectionBar)
        case .divider:
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

private struct ShellAttentionRailItem: View {
    @Environment(AppModel.self) private var appModel
    let isSelected: Bool
    let barNamespace: Namespace.ID
    let onSelect: () -> Void

    var body: some View {
        let waiting: Bool? = appModel.countPart("deskWaiting.presence") { face in
            guard let count = face?.deskWaiting, count.isAvailable, let value = count.value else { return nil }
            return value > 0
        }
        ShellRailItem(item: .activity, isSelected: isSelected, needsYou: waiting == true, attentionUnavailable: waiting == nil,
                      onSelect: onSelect, barNamespace: barNamespace)
    }
}
