import SwiftUI
import PersistenceCore

// MARK: - DeskCommandPalette — ⌘K, scoped to the desk
//
// Sweep R4 W5. Deliberately NOT the app-wide palette (CommandPalette.swift):
// that one jumps between tabs and chat sessions, this one only ever addresses
// desk items, so its whole result pool is desk rows and its grammar is the
// desk's three verbs. Two palettes with different pools beats one palette whose
// results User has to disambiguate.
//
// Lightweight by contract: a sheet, a TextField, a filtered list. No third-party
// deps, no new mutation path — Enter hands a verb + a handle back to DeskView,
// which fires the same `DeskQuickAction` the buttons fire.

struct DeskCommandPaletteView: View {
    /// Every selectable desk row, in board order.
    let rows: [DeskPaletteRow]
    /// The row that is already selected, if any. An empty query after a verb
    /// ("close" ⏎) applies to THIS — never to an arbitrary first match.
    let selectedHandle: String?
    let onSelect: (String) -> Void
    let onCommand: (DeskPaletteQuery.Verb, String) -> Void

    @Binding var isPresented: Bool

    @State private var text: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var fieldFocused: Bool

    private var parsed: DeskPaletteQuery { DeskPaletteQuery.parse(text) }

    private var matches: [DeskPaletteRow] {
        DeskFuzzy.filter(rows, query: parsed.query)
    }

    /// The row Enter would act on. With a verb and an empty query that is the
    /// current selection; otherwise the highlighted match.
    private var target: DeskPaletteRow? {
        if parsed.verb != nil, parsed.query.isEmpty {
            return rows.first { $0.handle == selectedHandle }
        }
        let list = matches
        guard !list.isEmpty else { return nil }
        return list[min(max(highlighted, 0), list.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if let verb = parsed.verb {
                verbBanner(verb)
                Divider()
            }
            resultList
            Divider()
            footer
        }
        .frame(width: 560, height: 420)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find an item — or type close / defer / note", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in highlighted = 0 }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(matches.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.naFeel)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial)
    }

    /// Says out loud what Enter is about to DO. A palette that mutates on Enter
    /// without naming the mutation is how a stray keystroke closes an item.
    private func verbBanner(_ verb: DeskPaletteQuery.Verb) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: verb))
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(bannerText(verb))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func bannerText(_ verb: DeskPaletteQuery.Verb) -> String {
        guard let target else {
            return parsed.query.isEmpty
                ? "\(verb.actionLabel) — nothing selected yet; type part of an item's title."
                : "\(verb.actionLabel) — no item matches \u{201C}\(parsed.query)\u{201D}."
        }
        switch verb {
        case .close: return "Enter closes \u{201C}\(target.title)\u{201D}."
        case .deferItem: return "Enter selects \u{201C}\(target.title)\u{201D} and opens the park menu."
        case .note: return "Enter selects \u{201C}\(target.title)\u{201D} and opens the note field."
        }
    }

    private func icon(for verb: DeskPaletteQuery.Verb) -> String {
        switch verb {
        case .close: return "checkmark.circle"
        case .deferItem: return "pause.circle"
        case .note: return "text.bubble"
        }
    }

    @ViewBuilder
    private var resultList: some View {
        let list = matches
        if list.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(rows.isEmpty ? "Nothing on the board to act on." : "No match.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(Array(list.enumerated()), id: \.element.id) { index, row in
                    paletteRow(row, isHighlighted: index == min(highlighted, list.count - 1))
                        .id(row.handle)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            highlighted = index
                            commit()
                        }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, new in
                    guard new >= 0, new < list.count else { return }
                    proxy.scrollTo(list[new].handle, anchor: .center)
                }
            }
        }
    }

    private func paletteRow(_ row: DeskPaletteRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(row.alias)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body).lineLimit(1)
                Text("\(row.status) · \(row.project)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if row.handle == selectedHandle {
                Text("selected").capsuleTag(.accentColor)
            }
        }
        .padding(.vertical, 3)
        .naInteractive(radius: 8)
        .listRowBackground(
            isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("↑↓ move · ⏎ apply · esc close")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func commit() {
        guard let target else { return }
        isPresented = false
        if let verb = parsed.verb {
            onCommand(verb, target.handle)
        } else {
            onSelect(target.handle)
        }
    }
}
