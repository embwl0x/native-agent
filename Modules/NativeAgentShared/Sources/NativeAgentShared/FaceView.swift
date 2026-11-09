import SwiftUI
import Accessibility
import Foundation
// Blueprint: | `FaceView.swift` | Shared page renderer, adaptive sections and keyboard row navigation |

/// Draws a shared face and native levers; its door owns navigation and action execution.
public struct FaceView: View {
    public let face: PartFace
    public let levers: [PartFace.Section]
    public let words: String?
    public let keyed: [PartFace.Section]
    private let adapter: any FaceDoor
    private let leaf: ((PartFace.Block) -> AnyView)?
    private let rowFilter: ((PartFace.Row) -> Bool)?
    @State private var localSession: FacePageSession
    private let retainedSession: FacePageSession?
    private var session: FacePageSession { retainedSession ?? localSession }
    @State private var viewer = UUID()
    /// Rows, controls and action buttons share the page's focus reconciliation and scroll owner.
    @FocusState private var focus: FaceFocus?
    @Environment(\.faceInList) private var inList
    @Environment(\.faceHoldsDocuments) private var holdsDocuments

    public init(face: PartFace, levers: [PartFace.Section] = [], words: String? = nil, keyed: [PartFace.Section] = [],
                open: @escaping (String) -> Void, act: @escaping (String, String, String?) async -> Void) {
        self.init(face: face, levers: levers, words: words, keyed: keyed,
                  door: ClosureFaceDoor(open: open, act: act), session: FacePageSession(), retaining: false)
    }

    public init(snapshot: PartFaceSnapshot, title: String, header: Bool = true, open: @escaping (String) -> Void,
                act: @escaping (String, String, String?) async -> Void) {
        self.init(snapshot: snapshot, title: title, header: header,
                  door: ClosureFaceDoor(open: open, act: act), session: FacePageSession(), retaining: false)
    }

    public init(face: PartFace, levers: [PartFace.Section] = [], words: String? = nil, keyed: [PartFace.Section] = [],
                door: any FaceDoor, session: FacePageSession, retaining: Bool = true,
                leaf: ((PartFace.Block) -> AnyView)? = nil, rowFilter: ((PartFace.Row) -> Bool)? = nil) {
        self.face = face
        self.levers = levers
        self.words = words
        self.keyed = keyed
        adapter = door
        self.leaf = leaf
        self.rowFilter = rowFilter
        retainedSession = retaining ? session : nil
        _localSession = State(initialValue: session)
    }

    public init(snapshot: PartFaceSnapshot, title: String, header: Bool = true, door: any FaceDoor, session: FacePageSession,
                retaining: Bool = true) {
        let drawn = snapshot.drawnFace
        let face = drawn ?? PartFace(sections: [])
        self.init(face: header ? face : PartFace(sections: face.sections, detail: face.detail), levers: snapshot.levers ?? [],
                  words: drawn == nil ? snapshot.error?.message ?? title + " is " + snapshot.status.rawValue + "." : nil,
                  keyed: drawn == nil ? snapshot.keyLevers ?? [] : [], door: door, session: session, retaining: retaining)
    }

    #if os(iOS)
    public static let door = "phone"
    #else
    public static let door = "mac"
    #endif

    private func shown(_ sections: [PartFace.Section], scope: String) -> [PartFace.Section] {
        sections.map { section in
            var drawn = session.collections.section(section).drawn(on: Self.door)
            drawn.id = scope + ":" + section.id
            return drawn
        }.filter { $0.block != nil || !$0.rows.isEmpty || $0.more != nil || $0.footer?.isEmpty == false }
    }

    private var sections: [PartFace.Section] {
        shown(levers, scope: "levers") + shown(keyed, scope: "keyed") + shown(face.sections, scope: "face")
    }

    private var collectionSources: [PartFace.Section] {
        (levers + keyed + face.sections).filter { $0.more != nil }
    }

    private var itemDemands: [FaceReadRequest] {
        sections.flatMap { section in
            session.visibleRows(section).compactMap { entry in
                let row = entry.row
                guard row.expands == true, session.expanded.contains(.init(section: section.id, row: row.id)) else { return nil }
                return FaceReadRequest(id: viewer, key: row.id, expectedCall: row.read, revision: section.revision)
            }
        }
    }

    private func itemDoor(_ request: FaceReadRequest) -> any FaceDoor {
        for section in sections where section.allRows.contains(where: { $0.id == request.key }) {
            let raw = section.id.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
            if let scope = session.collections.scope(section: raw, row: request.key) { return adapter.scoped(to: scope) }
        }
        return adapter
    }

    private var controls: [FaceItemID] {
        sections.filter { $0.block == nil }.flatMap { section in
            session.visibleRows(section).map(\.row).filter { $0.control != nil }.map { FaceItemID(section: section.id, row: $0.id) }
        }
    }

    private var documents: [PartFace.Block] {
        sections.filter { $0.folded != true || session.unfolded.contains($0.id) }.compactMap(\.block)
            .filter { $0.kind == "document" && $0.text == nil }
            .map { PartFace.Block(key: $0.key, read: $0.read, revision: $0.revision) }
    }

    private var visibleRows: [FaceItemID] {
        sections.flatMap { section in
            if section.block != nil { return [FaceItemID]() }
            if section.folded == true && !session.unfolded.contains(section.id) { return [FaceItemID]() }
            return session.visibleRows(filtered(section)).map { FaceItemID(section: section.id, row: $0.row.id) }
        }
    }

    private func filtered(_ section: PartFace.Section) -> PartFace.Section {
        var result = section
        if let rowFilter, section.id == "face:" + (face.detail?.of ?? "") { result.rows = result.rows.filter(rowFilter) }
        if face.detail == nil || section.id == "face:" + (face.detail?.of ?? "") {
            result.rows = result.rows.filter(session.matchesFilter)
        }
        return result
    }

    public var body: some View {
        #if os(macOS)
        ScrollViewReader { reader in
            pageContent.onChange(of: focus) { _, next in
                if let item = next?.item { reader.scrollTo(item) }
            }
        }
        #else
        if inList, face.sections.contains(where: { $0.filter != nil }) {
            pageContent.searchable(text: Binding(get: { session.filter }, set: { session.filter = $0 }))
        }
        else { pageContent }
        #endif
    }

    private var pageContent: some View {
        Group {
            if inList { contents }
            else { VStack(alignment: .leading, spacing: NativeAgentSpacing.section) { contents } }
        }
        .onChange(of: visibleRows) { old, new in reconcile(old: old, new: new) }
        .onAppear {
            session.attach(viewer)
            session.documents.hold(holdsDocuments ? documents : [], by: viewer, door: adapter)
            holdDemands()
        }
        .onChange(of: collectionSources) { _, _ in
            holdDemands()
        }
        .onChange(of: itemDemands) { _, _ in
            holdDemands()
        }
        .onChange(of: holdsDocuments) { _, _ in holdDemands() }
        .onChange(of: holdsDocuments ? documents : []) { _, demands in
            session.documents.hold(demands, by: viewer, door: adapter)
        }
        .onDisappear {
            session.documents.release(viewer)
            session.collections.release(viewer)
            session.detach(viewer)
        }
        .onChange(of: controls) { _, new in
            if case .control(let item)? = focus, !new.contains(item), visibleRows.contains(item) { focus = .row(item) }
        }
        .onChange(of: focus) { _, next in if let item = next?.item { session.selection = item } }
        #if os(macOS)
        .background {
            Button("") { session.showsFilter = true; focus = .filter }
                .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
        }
        #endif
    }

    private func holdDemands() {
        session.collections.hold(holdsDocuments ? collectionSources : [], items: holdsDocuments ? itemDemands : [],
                                 by: viewer, door: adapter, anchor: session.scrollAnchor?.row, itemDoor: itemDoor)
    }

    @ViewBuilder private var contents: some View {
        if face.title?.isEmpty == false || face.line?.isEmpty == false {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                if let title = face.title, !title.isEmpty { Text(title).font(.largeTitle.weight(.semibold)) }
                if let line = face.line, !line.isEmpty { Text(line).font(.title3).foregroundStyle(.secondary) }
            }
        }
        if session.showsFilter || face.sections.contains(where: { $0.filter != nil }) {
            TextField(face.sections.compactMap(\.filter).first ?? "Filter", text: Binding(get: { session.filter }, set: { session.filter = $0 }))
                .textFieldStyle(.roundedBorder).focused($focus, equals: .filter)
                .accessibilityLabel(Text("Filter"))
                .onKeyPress(.escape) { session.showsFilter = false; session.filter = ""; return .handled }
        }
        sectionViews(shown(levers, scope: "levers"))
        if let words, !words.isEmpty { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
        sectionViews(shown(keyed, scope: "keyed"))
        sectionViews(shown(face.sections, scope: "face"))
    }

    private func sectionViews(_ sections: [PartFace.Section]) -> some View {
        ForEach(sections) { section in
            FaceSectionView(section: filtered(section), door: adapter, session: session, focus: $focus, move: move, leaf: leaf,
                            collection: collectionSources.first { section.id == "face:" + $0.id
                                || section.id == "keyed:" + $0.id || section.id == "levers:" + $0.id })
        }
    }

    private func move(_ item: FaceItemID, _ direction: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex(of: item)
        let next = index.map { min(max($0 + direction, 0), rows.count - 1) } ?? 0
        if let item = rows.dropFirst(next).first { focus = .row(item) }
    }

    private func reconcile(old: [FaceItemID], new: [FaceItemID]) {
        guard let selected = session.selection, !new.contains(selected) else { return }
        let index = old.firstIndex(of: selected) ?? 0
        let next = old.dropFirst(index + 1).first { new.contains($0) } ?? new.first
        session.selection = next
        if focus?.item == selected { focus = next.map(FaceFocus.row) }
        if let next, let title = sections.first(where: { $0.id == next.section })?.rows.first(where: { $0.id == next.row })?.title {
            AccessibilityNotification.Announcement(title).post()
        }
    }
}

enum FaceTone {
    static func color(_ tone: PartFace.Tone?) -> Color {
        switch tone ?? .plain {
        case .plain, .quiet: .secondary
        case .attention: .orange
        case .failed: .red
        case .done: .green
        case .live: .accentColor
        }
    }
}

enum FaceTime {
    static func short(_ iso: String) -> String? {
        guard let date = UserDisplayFormatters.parseISOTimestamp(iso) else { return nil }
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Pills wrap without exceeding their proposed width.
struct FaceFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: width)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }

    private static func size(of view: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
