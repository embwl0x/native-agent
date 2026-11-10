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
    @Environment(\.faceInList) private var inList
    @Environment(\.faceStyle) private var style

    private var unfolded: Bool { section.folded != true || session.unfolded.contains(section.id) }

    var body: some View {
        if inList {
            Section {
                if section.folded == true { foldHeader }
                if unfolded { sectionContent; continuation }
            } header: {
                if section.folded != true { heading }
            } footer: {
                if unfolded { footer }
            }
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

    @ViewBuilder private var heading: some View {
        if let title = section.title, !title.isEmpty {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        if let footer = section.footer, !footer.isEmpty { Text(footer).font(.footnote).foregroundStyle(.secondary) }
    }

    private var foldHeader: some View {
        Button {
            withAnimation(.snappy) {
                if session.unfolded.contains(section.id) { session.unfolded.remove(section.id) }
                else { session.unfolded.insert(section.id) }
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
        if let block = section.block { blockView(block) }
        else { rows }
    }

    private var rows: some View {
        ForEach(flatRows, id: \.row.id) { entry in
            rowView(entry.row).padding(.leading, CGFloat(entry.depth) * 16)
            if entry.row.rows != nil || entry.row.expands == true {
                Button(session.expanded.contains(item(entry.row)) ? "Collapse " + entry.row.title : "Expand " + entry.row.title) {
                    let id = item(entry.row)
                    if session.expanded.contains(id) { session.expanded.remove(id) }
                    else { session.expanded.insert(id) }
                }.buttonStyle(.plain).font(style.detail)
                    .accessibilityValue(session.expanded.contains(item(entry.row)) ? "Expanded" : "Collapsed")
            }
            if entry.row.expands == true, session.expanded.contains(item(entry.row)) { demanded(entry.row) }
        }
    }

    private func item(_ row: PartFace.Row) -> FaceItemID { .init(section: section.id, row: row.id) }

    private var flatRows: [(row: PartFace.Row, depth: Int)] {
        session.visibleRows(section)
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
            } else if let failure = reading.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            else if reading.cancelled { Text("Stopped waiting for " + row.title + ".").foregroundStyle(.secondary) }
            else { HStack { Text("Waiting on " + row.title + "…"); Button("Cancel") { session.collections.cancel(row.id) } } }
        } else { Text("Waiting on " + row.title + "…").foregroundStyle(.secondary) }
    }

    @ViewBuilder private var continuation: some View {
        if let collection {
            let held = session.collections.collections[collection.id]
            if let total = section.more?.total { Text("Showing \(section.rows.count) of \(total)").font(style.detail).foregroundStyle(.secondary) }
            if let failure = held?.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if held?.cancelled == true { Text("Stopped waiting for this collection.").foregroundStyle(.secondary) }
            if held?.task != nil {
                HStack { Text("Waiting on more rows…"); Button("Cancel") { session.collections.cancel(collection.id) } }
            } else if section.more != nil {
                Button("Read more") { session.collections.more(collection, anchor: session.scrollAnchor?.row, door: door) }
            }
        }
    }

    private func rowView(_ row: PartFace.Row) -> some View {
        FaceRowView(row: row, item: FaceItemID(section: section.id, row: row.id), door: rowDoor(row),
                    session: session, focus: focus, move: move, sectionStyle: section.style ?? .list,
                    waiting: (section.style == .waiting && section.rows.first?.id == row.id) || row.running == true,
                    connectsTimeline: section.style == .timeline && section.rows.last?.id != row.id)
            .listRowInsets(style.insets)
            .id(FaceItemID(section: section.id, row: row.id))
    }

    private func rowDoor(_ row: PartFace.Row) -> any FaceDoor {
        if let collection, let scope = session.collections.scope(section: collection.id, row: row.id) { return door.scoped(to: scope) }
        return door
    }
}
