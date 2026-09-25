import SwiftUI

// ui-simplify 2026-09-02 (Lane A): the rail.
//
// Seventeen destinations became five places. Refinement pass, same day: the
// glyphs went. Four words at one left edge carry the column; a 2pt bar marks
// the place. A pill turned the rail into a segmented control, and the SF
// Symbols were the borrowed part (Agent's read, User's "looks like a template").
// Every route is untouched — only the furniture changed.

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
                    // The hover fade belongs to the word and nothing else. It
                    // used to sit on the whole Button, one modifier outside the
                    // overlay that hosts the selection bar — and an
                    // `.animation(_:value:)` is a scope, not an addition: for
                    // everything under it the transaction's animation becomes
                    // this one when `value` changed and NOTHING when it did
                    // not. On a click `hovering` does not change, so the rail's
                    // `.snappy` selection transaction was replaced with nil
                    // before it reached the bar, the matchedGeometryEffect
                    // source was removed and re-inserted un-animated, and the
                    // bar cut from one row to the next instead of travelling.
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

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(HazeColor(stored: hazeRaw).edgeLight, lineWidth: 1.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Two quiet groups on a floating glass plate, with Settings at the foot.
struct ShellSidebarRail: View {
    @Binding var selection: SidebarItem
    /// Every item except the last renders at the top; the last (Settings) is
    /// pushed to the bottom so the setup door is never mistaken for a place to
    /// work.
    var items: [SidebarItem] = SidebarItem.shellPrimaryItems
    /// The places that have something waiting on him. A dot, never a count —
    /// the caller does the counting and this rail only says whether.
    var needsYou: Set<SidebarItem> = []
    @AppStorage(BotsShelfPreference.key) private var botsPreviewEnabled = true
    /// Explicit override is used by the headless renderer, never persisted.
    var botsPreviewOverride: Bool? = nil

    /// The one id the travelling selection bar is known by.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Regular, like the composer: never mix clear and regular on one screen
    /// (WWDC25 219). One token if the pixels say otherwise.
    static let plateGlass: Glass = .regular

    var body: some View {
        VStack(spacing: 4) {
            ForEach(BotsShelfRailProposal.everyday(Array(items.dropLast()))) { item in proposalItem(item) }
            if botsPreviewOverride ?? botsPreviewEnabled { proposalItem(.bots) }
            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(height: 1)
                .padding(.horizontal, NativeAgentShellLayout.railWordInset)
                .padding(.vertical, 6)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
            ForEach(BotsShelfRailProposal.configuration(Array(items.dropLast()))) { item in
                proposalItem(item)
            }
            Spacer(minLength: 8)
            if let last = items.last {
                ShellRailItem(
                    item: last,
                    isSelected: selection.normalized == last.normalized,
                    needsYou: needsYou.contains(last.normalized),
                    onSelect: { selection = last },
                    barNamespace: selectionBar
                )
            }
        }
        // The bar's travel is one transaction over the whole rail, so both the
        // leaving and the arriving row read the same animation.
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: selection
        )
        // The shell baseline: "Chat", "Conversations" and the room header
        // share one first-text baseline at window y 72 (the 28pt title strip
        // plus 44 — the 24pt unit's nearest whole beat). At 13pt medium
        // centred in a 44pt row the word's baseline sits 27.3 below the top
        // of the stack, so 14 lands it on 72 — now 10 of that outside the
        // plate and 4 inside it. Settings keeps its 14 from the bottom the
        // same way.
        .padding(.top, 14 - NativeAgentShellLayout.railPlateInset)
        .padding(.bottom, 14 - NativeAgentShellLayout.railPlateInset)
        .frame(width: NativeAgentShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        // User, 2026-09-23 ("alive glass"): the rail alone floats — a rounded
        // plate of glass inset from the window's top (below the traffic
        // lights), bottom and leading edges. This changes the 2026-09-03 "one
        // sheet, not three plates" rule for the rail only: the list column and
        // every page stay transparent over the window's one sheet
        // (ShellFrame). Agent, same day: the plate must read as that same
        // sheet, just shaped — no seam, no brightness jump — so it wears
        // `.clear` glass (the edge and the lensing, none of `.regular`'s frost
        // over a room that is already coated) and no drawn border; the
        // trailing hairline is gone because the plate's edge is the boundary.
        // Reduce transparency: `.identity`, the flat rail over the opaque room.
        // While she thinks before replying, a shimmer drifts through it
        // (ThinkingGlow, a leaf).
        .background {
            ThinkingGlow(kind: .shimmer, cornerRadius: NativeAgentShellLayout.railPlateRadius)
        }
        .glassEffect(
            reduceTransparency ? .identity : Self.plateGlass,
            in: RoundedRectangle(cornerRadius: NativeAgentShellLayout.railPlateRadius, style: .continuous)
        )
        .padding([.top, .bottom, .leading], NativeAgentShellLayout.railPlateInset)
        .padding(.trailing, 6)
        // Agent, 2026-09-02: the 1px light hairline that used to sit on the
        // rail's top edge is gone. With the title bar transparent the rail now
        // reaches the window's own edge, so that line drew itself across the
        // traffic-light row — a strip, which is the thing the shell does not
        // paint on glass.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }

    private func proposalItem(_ item: SidebarItem) -> some View {
        ShellRailItem(item: item, isSelected: selection.normalized == item.normalized,
                      needsYou: needsYou.contains(item.normalized), onSelect: { selection = item },
                      barNamespace: selectionBar)
    }
}
