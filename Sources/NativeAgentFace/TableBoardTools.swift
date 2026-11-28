import AppKit
import NativeAgentShared
import SwiftUI
// Blueprint: | `TableBoardTools.swift` | The standing table's named tools, element actions and live card picker |

private extension TableBoardTool {
    var help: String {
        switch self {
        case .select: "Move a card or drag empty space to pan."
        case .note: "Click the board to write a note."
        case .card: "Choose a Desk item or piece to add a live card."
        case .pen: "Drag to draw a line; click Pen again to finish drawing."
        case .connect: "Click a start card and then a destination card."
        }
    }
}

/// Named tools floating above the standing table.
struct TableBoardTools: View {
    @Binding var tool: TableBoardTool
    @Binding var picking: Bool
    let choices: [[String: PartFace.Value]]
    let percent: Int
    let choose: ([String: PartFace.Value]) -> Void
    let zoom: (CGFloat) -> Void
    let fit: () -> Void

    @MainActor static let windowMinimumSize: NSSize = {
        let toolbar = Self(tool: .constant(.select), picking: .constant(false), choices: [],
                           percent: Int(BoardCamera.maximumScale * 100), choose: { _ in }, zoom: { _ in }, fit: {})
        let host = NSHostingView(rootView: toolbar.fixedSize())
        let insets = FacePageView.standaloneInset + MakeBoardView.tableToolsInset
        return NSSize(width: ceil(host.fittingSize.width) + 2 * insets, height: 360)
    }()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { tools; Divider().frame(height: 16).padding(.horizontal, 4); camera }.fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) { tools }.fixedSize()
                HStack(spacing: 4) { camera }.fixedSize()
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary).font(ShellType.label).padding(8)
        .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: picking) { _, now in if !now && tool == .card { tool = .select } }
    }
    private var tools: some View {
        ForEach(TableBoardTool.allCases, id: \.self) { option in
            Button {
                tool = tool == option ? .select : option
                picking = tool == .card
            } label: {
                Label(option.rawValue, systemImage: option.symbol).fixedSize().padding(6)
                    .background(tool == option ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .help(option.help)
            .popover(isPresented: Binding(get: { picking && option == .card }, set: { picking = $0 }),
                     attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { TableCardPicker(choices: choices, choose: choose) }
        }
    }
    @ViewBuilder private var camera: some View {
        Button { zoom(0.8) } label: {
            Label("Zoom out", systemImage: "minus.magnifyingglass").fixedSize().padding(6).contentShape(Rectangle())
        }.help("Make the table smaller.")
        Text("\(percent)%").monospacedDigit().fixedSize().padding(.horizontal, 4)
        Button { zoom(1.25) } label: {
            Label("Zoom in", systemImage: "plus.magnifyingglass").fixedSize().padding(6).contentShape(Rectangle())
        }.help("Make the table larger.")
        Button(action: fit) {
            Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right").fixedSize().padding(6).contentShape(Rectangle())
        }.help("Centre the table and follow changes.")
    }
}

/// Actions attached to the chosen table element.
struct TableElementTools: View {
    let starting: Bool
    let connectable: Bool
    let colours: Bool
    let color: String?
    let recolor: (String) -> Void
    let cross: () -> Void
    let connect: () -> Void
    let remove: () -> Void
    var open: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if starting { Text("Start").font(.caption).foregroundStyle(.secondary) }
                Button(action: cross) { Label("Cross off", systemImage: "checkmark") }.help("Cross off the selected element.")
                Button(action: connect) { Label("Connect", systemImage: "arrow.up.right") }.disabled(!connectable)
                    .help("Start an arrow from the selected card.")
                Button(action: remove) { Label("Delete", systemImage: "trash") }.help("Delete the selected element and attached arrows.")
                if let open { Button(action: open) { Label("Open", systemImage: "arrow.up.forward.square") }.help("Open the piece in Make.") }
            }
            if colours {
                HStack(spacing: 10) {
                    ForEach(BoardPalette.names, id: \.self) { name in
                        Button { recolor(name) } label: {
                            Circle().fill(BoardPalette.fill(name)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke((color ?? "white") == name
                                    ? BoardPalette.words(name, table: true) : TodayPalette.cardStroke, lineWidth: 1))
                        }.accessibilityLabel(name.capitalized).help("Colour the selected card " + name + ".")
                    }
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary).font(ShellType.label).padding(10)
        .houseSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Searchable live references supplied by the Desk page.
struct TableCardPicker: View {
    let choices: [[String: PartFace.Value]]
    let choose: ([String: PartFace.Value]) -> Void
    @State private var search = ""
    private var matches: [[String: PartFace.Value]] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return choices.filter { choice in
            let text = [choice["label"]?.stringValue, choice["detail"]?.stringValue].compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search title or Desk number", text: $search).textFieldStyle(.roundedBorder)
            if matches.isEmpty { Text(choices.isEmpty ? "No cards available in this reading." : "No matching cards.").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(matches.indices, id: \.self) { index in
                        let choice = matches[index]
                        Button { choose(choice) } label: {
                            VStack(alignment: .leading) {
                                Text(choice["label"]?.stringValue ?? "").foregroundStyle(.primary)
                                Text(choice["detail"]?.stringValue ?? "").font(ShellType.label).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.font(ShellType.body).padding(14).frame(width: 320, height: 300)
    }
}
