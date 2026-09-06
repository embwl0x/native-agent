import SwiftUI

// User, 2026-09-04: the Advanced pages come out from behind Settings and onto
// the rail, and the ones that belong together become tabs on one page. The
// tab row is the rail's own idiom turned sideways: the rail's 14pt medium
// words, the selected one in the text colour with the rail's 2pt bar that
// travels, the rest secondary with a hover fade on the word. No segmented
// control, no second accent.

/// One tab: a stable key (persisted per page) and the word a person reads.
struct ShellTab<Key: Hashable>: Identifiable {
    let key: Key
    let title: String
    var id: Key { key }
}

struct ShellTabs<Key: Hashable>: View {
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key

    @Namespace private var bar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs) { tab in
                ShellTabWord(
                    id: "shell.tab.\(tab.key)",
                    title: tab.title,
                    isSelected: tab.key == selection,
                    onSelect: { selection = tab.key },
                    barNamespace: bar
                )
            }
            Spacer(minLength: 0)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25),
            value: selection
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct ShellTabWord: View {
    let id: String
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    var barNamespace: Namespace.ID

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            Text(title)
                .font(ShellType.rail)
                .foregroundStyle(isSelected ? NativeAgentShell.text
                    : (hovering ? NativeAgentShell.text.opacity(0.75) : NativeAgentShell.secondary))
                // The fade belongs to the word; the selection transaction
                // must reach the bar untouched (see ShellRailItem).
                .animation(
                    NativeAgentMotion.respecting(.easeOut(duration: 0.15), reduceMotion: reduceMotion),
                    value: hovering
                )
                .lineLimit(1)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(NativeAgentShell.text)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "shell.tabs.bar", in: barNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A rail page with tabs: the page frame's title, the tab row under it, then
/// the selected tab's content. Content is keyed by the selection so a tab
/// switch is a clean swap, never a half-updated page.
struct ShellTabbedPage<Key: Hashable, Content: View>: View {
    let title: String
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key
    @ViewBuilder let content: (Key) -> Content

    var body: some View {
        ShellPageFrame(title: title, showsBack: false) {
            VStack(alignment: .leading, spacing: 0) {
                ShellTabs(tabs: tabs, selection: $selection)
                    .padding(.bottom, 18)
                content(selection)
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// A rail page without tabs: the frame and its title, nothing else added.
struct ShellRailPage<Content: View>: View {
    let title: String
    var wide: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        ShellPageFrame(title: title, showsBack: false, wide: wide) { content }
    }
}
