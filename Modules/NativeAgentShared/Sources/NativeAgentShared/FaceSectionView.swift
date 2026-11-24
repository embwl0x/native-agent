import SwiftUI
// Blueprint: | `FaceSectionView.swift` | Shared face sections in native lists or door-supplied cards |

struct FaceSectionView: View {
    let section: PartFace.Section
    let door: any FaceDoor
    let session: FacePageSession
    let focus: FocusState<FaceFocus?>.Binding
    let move: (FaceItemID, Int) -> Void
    let leaf: ((PartFace.Block) -> AnyView)?
    var collection: PartFace.Section? = nil
    private var inList: Bool { listWidth != nil }
    @Environment(\.faceStyle) private var style
    @Environment(\.faceListWidth) private var listWidth
    @Environment(\.faceListColumnWidth) private var listColumnWidth

    private var unfolded: Bool { section.folded != true || session[open: .section(section.id)] }
    private var filledInList: Bool { section.filled == true }
    var body: some View {
        if inList {
            #if os(macOS)
            if listColumnWidth != nil {
                Section {
                    if section.folded == true { listRow(foldHeader, filled: filledInList) }
                    else { heading }
                    if unfolded { sectionContent; continuation; footer }
                }
                .listSectionSeparator(.hidden)
            } else {
                standardListSection
            }
            #else
            standardListSection
            #endif
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.eyebrowGap) {
                if section.folded == true { foldHeader.modifier(FaceCard()) } else { heading }
                if unfolded {
                    content
                    continuation
                    footer
                }
            }
        }
    }

    private var standardListSection: some View {
        Section {
            if section.folded == true { listRow(foldHeader, filled: filledInList) }
            if unfolded { sectionContent; continuation }
        } header: {
            if section.folded != true { heading }
        } footer: {
            if unfolded { footer }
        }
    }

    @ViewBuilder private var heading: some View {
        if let title = section.title, !title.isEmpty {
            let label = Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if inList { label.modifier(FaceListEdge()) } else { label }
        }
    }

    @ViewBuilder private var footer: some View {
        if let footer = section.footer, !footer.isEmpty {
            let label = Text(footer).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if inList { label.modifier(FaceListEdge()) } else { label }
        }
    }

    @ViewBuilder private func listRow<V: View>(_ content: V, filled: Bool = false, padded: Bool = true) -> some View {
        #if os(macOS)
        if let columnWidth = listColumnWidth {
            content
                .padding(padded ? style.insets : EdgeInsets())
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(filled ? style.actionSurface : Color.clear)
                .padding(.horizontal, NativeAgentSpacing.pageInset)
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            content
                .listRowInsets(padded ? style.insets : EdgeInsets())
                .listRowBackground(filled ? style.actionSurface : Color.clear)
        }
        #else
        if padded { content.listRowInsets(style.insets) } else { content }
        #endif
    }

    private var foldHeader: some View {
        Button {
            withAnimation(.snappy) {
                session[open: .section(section.id)].toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text(section.title ?? "").font(style.title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(unfolded ? 90 : 0))
            }
            .frame(minHeight: max(0, style.minimumHeight - style.insets.top - style.insets.bottom))
            .padding(inList ? EdgeInsets() : style.insets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(unfolded ? "Open" : "Folded")
    }

    @ViewBuilder private var content: some View {
        if let block = section.block {
            blockView(block).modifier(FaceCard())
        } else {
        switch section.style ?? .list {
        case .flow:
            FaceFlow(spacing: NativeAgentSpacing.sm) { rows }.scrollTargetLayout()
        case .note, .timeline:
            VStack(alignment: .leading, spacing: 0) { rows }.scrollTargetLayout()
        case .waiting:
            VStack(alignment: .leading, spacing: 0) { rows }.scrollTargetLayout().modifier(FaceCard())
        case .list, .values:
            VStack(alignment: .leading, spacing: 0) {
                rows
            }
            .scrollTargetLayout()
            .modifier(FaceCard())
        }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if let block = section.block { listRow(blockView(block), filled: filledInList, padded: false) }
        else { rows }
    }

    @ViewBuilder private var rows: some View {
        let expanded = session[open: .more(section.id)]
        let entries = flatRows
        ForEach(entries, id: \.id) { entry in
            let id = entry.id
            let discloses = entry.row.holdsBeneath || entry.row.expands == true
            let open = discloses && session[open: .row(id)]
            let leading = CGFloat(entry.depth) * 16
            let connectsTimeline = section.style == .timeline && entries.last?.id != id
            let line = rowView(entry.row, leading: leading, connectsTimeline: connectsTimeline).padding(.leading, leading)
            let probed = Group {
                if let listWidth { line.modifier(FaceListWidthProbe(list: listWidth)) }
                else { line }
            }
            if inList {
                listRow(probed, filled: filledInList).id(id)
            } else {
                probed.id(id)
            }
            if entry.row.expands == true, open {
                if inList { demanded(entry.row) }
                else { demanded(entry.row).layoutValue(key: FaceFlowLine.self, value: true) }
            }
        }
        let hidden = session.hiddenRows(section)
        if hidden > 0 {
            let line = foldLine("\(hidden) more", symbol: "chevron.down") { session[open: .more(section.id)] = true }
            if inList { listRow(line, filled: filledInList) } else { line }
        } else if expanded, section.rows.count > FacePageSession.foldAfter + 2 {
            let line = foldLine("Show fewer", symbol: "chevron.up") { session.collapseRows(section) }
            if inList { listRow(line, filled: filledInList) } else { line }
        }
    }

    private func foldLine(_ words: String, symbol: String, act: @escaping () -> Void) -> some View {
        let scope = (section.foldContext ?? section.title).flatMap { $0.isEmpty ? nil : $0 }
        return Button { withAnimation(.snappy) { act() } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption2.weight(.semibold))
                Text(words)
            }
            .font(style.detail).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: max(0, style.minimumHeight - style.insets.top - style.insets.bottom), alignment: .leading)
            .padding(inList ? EdgeInsets() : style.insets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(scope.map { words + ", " + $0 } ?? words))
    }

    private func item(_ row: PartFace.Row) -> FaceItemID { .init(section: section.id, row: row.id) }

    private var flatRows: [(id: FaceItemID, row: PartFace.Row, depth: Int)] {
        session.visibleRows(section).map { (id: item($0.row), row: $0.row, depth: $0.depth) }
    }

    @ViewBuilder private func blockView(_ block: PartFace.Block) -> some View {
        if block.kind == "form" {
            FaceFormBlock(block: block, section: section.id, session: session, door: door)
        } else if block.kind == "leaf" {
            if let leaf { leaf(block) }
            else { Text(block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary) }
        } else { FaceDocumentBlock(block: block, session: session, door: door) }
    }

    @ViewBuilder private func demanded(_ row: PartFace.Row) -> some View {
        if let reading = session.collections.items[row.id] {
            if let face = reading.face {
                AnyView(FaceView(face: face, door: reading.door.scoped(to: reading.request.scope),
                                 session: session.children.page(section.id + "/" + row.id), leaf: leaf))
            } else {
                let status = Group {
                    if let failure = reading.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                    else if reading.cancelled { Text("Stopped waiting for " + row.title + ".").foregroundStyle(.secondary) }
                    else { HStack { Text("Waiting on " + row.title + "…"); Button("Cancel") { session.collections.cancel(row.id) } } }
                }
                if inList { listRow(status, filled: filledInList) } else { status }
            }
        } else {
            let status = Text("Waiting on " + row.title + "…").foregroundStyle(.secondary)
            if inList { listRow(status, filled: filledInList) } else { status }
        }
    }

    @ViewBuilder private var continuation: some View {
        if let collection {
            let held = session.collections.collections[collection.id]
            if section.more != nil || held?.failure != nil || held?.cancelled == true || held?.task != nil {
                let content = VStack(alignment: .leading, spacing: 6) {
                    if let total = section.more?.total { Text("Showing \(section.rows.count) of \(total)").font(style.detail).foregroundStyle(.secondary) }
                    if let failure = held?.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                    if held?.cancelled == true { Text("Stopped waiting for this collection.").foregroundStyle(.secondary) }
                    if held?.task != nil {
                        HStack { Text("Waiting on more rows…"); Button("Cancel") { session.collections.cancel(collection.id) } }
                    } else if section.more != nil {
                        Button("Read more") { session.collections.more(collection, anchor: session.scrollAnchor?.row, door: door) }
                    }
                }
                if inList { listRow(content, filled: filledInList) } else { content }
            }
        }
    }

    private func rowView(_ row: PartFace.Row, leading: CGFloat, connectsTimeline: Bool) -> some View {
        FaceRowView(row: row, item: FaceItemID(section: section.id, row: row.id), door: rowDoor(row),
                    session: session, focus: focus, move: move, sectionStyle: section.style ?? .list,
                    waiting: (section.style == .waiting && section.rows.first?.id == row.id) || row.running == true,
                    connectsTimeline: connectsTimeline, columns: groupColumns, leading: leading)
    }

    /// The section's inline groups share columns, one per child word, in the order the rows give them (a word first met is placed after
    /// the word before it in its own row). Each column is the first child met with that word; a row without it ("Write" only) draws that
    /// child unseen to hold the column's width, so every "Write" stands under every other.
    private var groupColumns: [PartFace.Row] {
        var columns: [PartFace.Row] = []
        for group in section.rows.flatMap(\.lineRows).map(\.group) where !group.isEmpty {
            var place = 0
            for child in group {
                if let at = columns.firstIndex(where: { $0.title == child.title }) { place = at + 1 }
                else { columns.insert(child, at: place); place += 1 }
            }
        }
        return columns
    }

    private func rowDoor(_ row: PartFace.Row) -> any FaceDoor {
        if let collection, let scope = session.collections.scope(section: collection.id, row: row.id) { return door.scoped(to: scope) }
        return door
    }
}
