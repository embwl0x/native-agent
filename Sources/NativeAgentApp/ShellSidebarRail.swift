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
                        NativeAgentMotion.respecting(.easeOut(duration: 0.15), reduceMotion: reduceMotion),
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
        .onHover { hovering = $0 }
        .help(item.displayName)
        .accessibilityIdentifier("sidebar.item.\(item.rawValue)")
        .accessibilityLabel(needsYou ? "\(item.shellRailTitle), waiting for you" : item.shellRailTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The 84pt rail on glass: four places at the top, Settings at the foot.
struct ShellSidebarRail: View {
    @Binding var selection: SidebarItem
    /// Every item except the last renders at the top; the last (Settings) is
    /// pushed to the bottom so the setup door is never mistaken for a place to
    /// work.
    var items: [SidebarItem] = SidebarItem.shellPrimaryItems
    /// The places that have something waiting on him. A dot, never a count —
    /// the caller does the counting and this rail only says whether.
    var needsYou: Set<SidebarItem> = []

    /// The one id the travelling selection bar is known by.
    static let selectionBarID = "shell.rail.selection-bar"
    @Namespace private var selectionBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ForEach(items.dropLast()) { item in
                ShellRailItem(
                    item: item,
                    isSelected: selection.normalized == item.normalized,
                    needsYou: needsYou.contains(item.normalized),
                    onSelect: { selection = item },
                    barNamespace: selectionBar
                )
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
            reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25),
            value: selection
        )
        // The shell baseline: "Chat", "Conversations" and the room header
        // share one first-text baseline at window y 72 (the 28pt title strip
        // plus 44 — the 24pt unit's nearest whole beat). At 13pt medium
        // centred in a 44pt row the word's baseline sits 27.3 below the top
        // of the stack, so 14 lands it on 72.
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: NativeAgentShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        // User, 2026-09-03: the rail is navigation — the functional layer — so
        // it wears real Liquid Glass now. The NSVisualEffectView that used to
        // sit under it is gone: an AppKit effect view beneath a sidebar stops
        // the glass showing through, which is why the coat kept getting
        // heavier and the rail kept not looking like glass. What is left is a
        // hint of the rail's own tone, nothing like a coat, so the rail reads
        // more transparent than the room beside it. Reduce transparency takes
        // the fill opaque and the glass to .identity: that setting asks for
        // more opacity, never less.
        // User, 2026-09-03: "it should all look like one." The rail is the
        // same sheet as the room, same material, same coat, so the desktop
        // bleeds through it exactly as it does through the chat; its own
        // glass plate read flatter than the room beside it. The column keeps
        // a hairline on its trailing edge so you can still see where it ends.
        // The sheet is the window's (ShellFrame); the rail is transparent over
        // it and keeps only its hairline.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(NativeAgentShell.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        // Agent, 2026-09-02: the 1px light hairline that used to sit on the
        // rail's top edge is gone. With the title bar transparent the rail now
        // reaches the window's own edge, so that line drew itself across the
        // traffic-light row — a strip, which is the thing the shell does not
        // paint on glass.
        // Agent, 2026-09-02: and the trailing hairline down the rail/list edge
        // is gone too. A column boundary in this shell is a material change,
        // not a drawn rule — over a live desktop the line was the one place
        // the wallpaper's bleed crossed a seam and stopped dead. The rail's
        // coat (NativeAgentShell.rail) and the list's (.list) already differ;
        // if they ever read as one column the answer is to take the rail's
        // coat a step further off, never to put the line back.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }
}
