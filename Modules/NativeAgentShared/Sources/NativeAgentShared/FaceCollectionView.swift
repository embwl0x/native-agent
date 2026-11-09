import Foundation
import Observation
import SwiftUI
import Accessibility
// Blueprint: | `FaceCollectionView.swift` | Session-held collection continuations, nested item reads and adaptive selection |

@MainActor @Observable public final class FaceCollectionReads {
    struct Collection {
        var source: PartFace.Section
        var section: PartFace.Section
        var request: FaceReadRequest?
        var failure: String?
        var cancelled = false
        var task: Task<Void, Never>?
        var rowScopes: [String: String] = [:]
        var leases: [(request: FaceReadRequest, door: any FaceDoor)] = []
    }
    struct Item {
        let identity: FaceReadRequest
        let request: FaceReadRequest
        let door: any FaceDoor
        var face: PartFace?
        var failure: String?
        var cancelled = false
        var task: Task<Void, Never>?
    }
    private(set) var collections: [String: Collection] = [:]
    private(set) var items: [String: Item] = [:]
    private var holders: [UUID: Set<String>] = [:]
    public init() {}

    func section(_ source: PartFace.Section) -> PartFace.Section {
        guard let held = collections[source.id], held.source == source else { return source }
        return held.section
    }

    func scope(section: String, row: String) -> String? { collections[section]?.rowScopes[row] }

    /// A page holds demands; recycled rows only draw their already-held results.
    func hold(_ sources: [PartFace.Section], items demands: [FaceReadRequest], by viewer: UUID, door: any FaceDoor,
              anchor: String? = nil, itemDoor: ((FaceReadRequest) -> any FaceDoor)? = nil) {
        holders[viewer] = Set(demands.map(\.key) + sources.map(\.id))
        for source in sources {
            if let held = collections[source.id], held.source == source { continue }
            guard var held = collections[source.id] else {
                collections[source.id] = Collection(source: source, section: source)
                continue
            }
            if let revision = source.revision, held.section.revision == revision {
                // A new publication of the same collection cannot erase pages already read or their scopes.
                let firstIDs = Set(source.rows.map(\.id))
                var section = source
                section.rows += held.section.rows.filter { !firstIDs.contains($0.id) }
                section.more = held.section.more
                section.footer = held.section.footer
                held.source = source
                held.section = section
                collections[source.id] = held
            } else if held.leases.isEmpty || source.more == nil {
                release(held)
                collections[source.id] = Collection(source: source, section: source)
            } else {
                // Keep the old reading on screen until its replacement has restored the held span at the visible row.
                held.task?.cancel()
                held.source = source
                collections[source.id] = held
                load(source, cursor: source.more?.next, anchor: anchor, door: door,
                     minimumRows: held.section.rows.count, starting: source)
            }
        }
        for identity in demands {
            if items[identity.key]?.identity == identity { continue }
            if let previous = items.removeValue(forKey: identity.key) { release(previous) }
            let reader = itemDoor?(identity) ?? door
            let request = FaceReadRequest(id: UUID(), key: identity.key, expectedCall: identity.expectedCall, revision: identity.revision,
                                          cursor: identity.cursor, anchor: identity.anchor, query: identity.query)
            items[request.key] = Item(identity: identity, request: request, door: reader)
            let task = Task {
                do {
                    let face = try await reader.readFace(request)
                    try Task.checkCancellation()
                    guard items[request.key]?.request == request else { return }
                    items[request.key]?.face = face
                } catch {
                    guard items[request.key]?.request == request else { return }
                    if error is CancellationError || Task.isCancelled { items[request.key]?.cancelled = true }
                    else { items[request.key]?.failure = error.localizedDescription }
                }
                if items[request.key]?.request == request { items[request.key]?.task = nil }
            }
            items[request.key]?.task = task
        }
        releaseUnheld()
    }

    func release(_ viewer: UUID) { holders.removeValue(forKey: viewer); releaseUnheld() }

    private func releaseUnheld() {
        let held = holders.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for key in Array(items.keys) where !held.contains(key) {
            if let item = items.removeValue(forKey: key) { release(item) }
        }
        for key in Array(collections.keys) where !held.contains(key) {
            if let collection = collections.removeValue(forKey: key) { release(collection) }
        }
    }

    private func release(_ collection: Collection) {
        collection.task?.cancel()
        Task {
            await collection.task?.value
            for lease in collection.leases { await lease.door.releaseFace(lease.request) }
        }
    }

    private func release(_ item: Item) {
        item.task?.cancel()
        Task {
            await item.task?.value
            await item.door.releaseFace(item.request)
        }
    }

    func more(_ source: PartFace.Section, anchor: String?, door: any FaceDoor) {
        let current = section(source)
        guard let more = current.more, collections[source.id]?.task == nil else { return }
        if collections[source.id] == nil { collections[source.id] = Collection(source: source, section: source) }
        load(source, cursor: more.next, anchor: anchor, door: door)
    }

    private func load(_ source: PartFace.Section, cursor: String?, anchor: String?, door: any FaceDoor,
                      minimumRows: Int? = nil, starting: PartFace.Section? = nil) {
        let previous = collections[source.id]
        let current = starting ?? section(source)
        let request = FaceReadRequest(id: UUID(), key: source.id, expectedCall: source.more?.read ?? current.more?.read,
                                      revision: cursor == nil ? nil : current.revision ?? current.more?.revision,
                                      cursor: cursor, anchor: anchor)
        if cursor != nil, request.revision == nil {
            collections[source.id]?.failure = "The collection owner supplied no revision for its continuation."
            return
        }
        collections[source.id]?.request = request
        collections[source.id]?.failure = nil
        collections[source.id]?.cancelled = false
        collections[source.id]?.leases.append((request, door))
        let task = Task {
            do {
                var face: PartFace
                var completed = request
                var replacing = starting != nil
                do { face = try await door.readFace(request) }
                catch let error as PartCallError where error.code == "collection_changed" && request.cursor != nil {
                    try Task.checkCancellation()
                    replacing = true
                    completed = .init(id: UUID(), key: source.id, expectedCall: request.expectedCall,
                                      anchor: request.anchor, query: request.query)
                    collections[source.id]?.leases.append((completed, door))
                    face = try await door.readFace(completed)
                }
                var accumulated = starting
                var scopes: [String: String] = [:]
                let restoring = minimumRows ?? (completed.cursor == nil && request.cursor != nil ? current.rows.count : 0)
                while true {
                    try Task.checkCancellation()
                    guard collections[source.id]?.request == request else { return }
                    guard var next = face.sections.first(where: { $0.id == source.id }) else {
                        throw PartCallError(code: "collection_unconfirmed", message: "The collection owner did not return section " + source.id + ".")
                    }
                    for row in next.rows {
                        for descendant in row.descendants { scopes[descendant.id] = completed.scope }
                    }
                    if let previous = accumulated ?? (completed.cursor != nil ? current : nil) {
                        guard next.revision != nil, next.revision == previous.revision else {
                            throw PartCallError(code: "collection_changed", message: "The collection changed while restoring this reading.")
                        }
                        let ids = Set(previous.rows.map(\.id))
                        next.rows = previous.rows + next.rows.filter { !ids.contains($0.id) }
                        if accumulated != nil, next.more != nil, next.rows.count == previous.rows.count {
                            throw PartCallError(code: "collection_unconfirmed", message: "The continuation supplied no new rows.")
                        }
                        if accumulated == nil { scopes = collections[source.id]?.rowScopes.merging(scopes) { _, new in new } ?? scopes }
                    }
                    accumulated = next
                    // The held row count bounds the restored span; an anchor outside it is still owed until read or confirmed absent at the end.
                    let needsAnchor = starting != nil && anchor.map { id in !next.rows.contains { $0.id == id } } == true
                    guard next.rows.count < restoring || needsAnchor, let more = next.more else {
                        collections[source.id]?.rowScopes = scopes
                        collections[source.id]?.section = next
                        if replacing, let previous {
                            let retired = Set(previous.leases.map { $0.request.id })
                            collections[source.id]?.leases.removeAll { retired.contains($0.request.id) }
                            release(previous)
                        }
                        break
                    }
                    guard let revision = next.revision ?? more.revision, more.next != completed.cursor else {
                        throw PartCallError(code: "collection_unconfirmed", message: "The collection owner did not advance its continuation.")
                    }
                    completed = .init(id: UUID(), key: source.id, expectedCall: more.read, revision: revision,
                                      cursor: more.next, anchor: anchor)
                    collections[source.id]?.leases.append((completed, door))
                    face = try await door.readFace(completed)
                }
            } catch {
                guard collections[source.id]?.request == request else { return }
                if error is CancellationError || Task.isCancelled { collections[source.id]?.cancelled = true }
                else { collections[source.id]?.failure = error.localizedDescription }
            }
            if collections[source.id]?.request == request { collections[source.id]?.task = nil }
        }
        collections[source.id]?.task = task
    }

    func cancel(_ key: String) {
        items[key]?.cancelled = true
        items[key]?.task?.cancel()
        collections[key]?.cancelled = true
        collections[key]?.task?.cancel()
    }
}

/// The selected item is held above its drawing, through its own page door.
public struct FaceItemView: View {
    private let item: String
    private let readCall: PartFace.Call?
    private let revision: String?
    private let reader: any FaceDoor
    private let session: FacePageSession
    private let leaf: ((PartFace.Block) -> AnyView)?
    @State private var viewer = UUID()
    @Environment(\.faceHoldsDocuments) private var holdsDemands
    public init(item: String, readCall: PartFace.Call? = nil, revision: String? = nil, door: any FaceDoor,
                reader: (any FaceDoor)? = nil, session: FacePageSession, leaf: ((PartFace.Block) -> AnyView)? = nil) {
        self.item = item; self.readCall = readCall; self.revision = revision; self.reader = reader ?? door
        self.session = session; self.leaf = leaf
    }
    private var request: FaceReadRequest { .init(id: viewer, key: item, expectedCall: readCall, revision: revision) }
    public var body: some View {
        Group {
            if let held = session.collections.items[item] {
                if let face = held.face { FaceView(face: face, door: held.door.scoped(to: held.request.scope), session: session, leaf: leaf) }
                else if let failure = held.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                else if held.cancelled { Text("Stopped waiting for this item.").foregroundStyle(.secondary) }
                else { HStack { Text("Waiting on " + reader.waitingOn + "…"); Button("Cancel") { session.collections.cancel(item) } } }
            } else { Text("Waiting on " + reader.waitingOn + "…").foregroundStyle(.secondary) }
        }
        .onAppear { hold() }
        .onChange(of: request) { _, _ in hold() }
        .onChange(of: holdsDemands) { _, _ in hold() }
        .onDisappear { session.collections.release(viewer) }
    }
    private func hold() { session.collections.hold([], items: holdsDemands ? [request] : [], by: viewer, door: reader) }
}

/// Selection is unfinished reading in the window, independent of a posted page's values.
public struct FaceSelectionView: View {
    private let face: PartFace
    private let page: String?
    private let session: FacePageSession
    @Binding private var selection: String?
    private let door: any FaceDoor
    private let leaf: ((PartFace.Block) -> AnyView)?
    private let detail: (String, PartFace.Row?) -> AnyView
    private let selectionRows: [PartFace.Row]?
    private let rowFilter: ((PartFace.Row) -> Bool)?
    @State private var retainedSelection: PartFace.Row?
    @State private var viewer = UUID()
    @Environment(\.faceHoldsDocuments) private var holdsDemands
    @State private var width: CGFloat = 0
    public init(face: PartFace, session: FacePageSession, selection: Binding<String?>, door: any FaceDoor, page: String? = nil,
                leaf: ((PartFace.Block) -> AnyView)? = nil, selectionRows: [PartFace.Row]? = nil,
                rowFilter: ((PartFace.Row) -> Bool)? = nil,
                detail: @escaping (String, PartFace.Row?) -> AnyView) {
        self.face = face; self.session = session; _selection = selection; self.door = door; self.leaf = leaf; self.detail = detail
        self.page = page
        self.selectionRows = selectionRows
        self.rowFilter = rowFilter
    }
    private var rows: [PartFace.Row] {
        guard let source = face.sections.first(where: { $0.id == face.detail?.of }) else { return [] }
        return session.collections.section(source).rows
    }
    private var selectedRow: PartFace.Row? {
        if let row = (selectionRows ?? rows).first(where: { $0.id == selection }) { return row }
        if selectionRows == nil, face.sections.first(where: { $0.id == face.detail?.of })?.more != nil,
           retainedSelection?.id == selection { return retainedSelection }
        return nil
    }
    private var selectingDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: { link in
            if case .page(let target, item: _?)? = FaceLink(link), page == nil || target == page,
               let row = (selectionRows ?? rows).first(where: { $0.open == link }) { selection = row.id }
            else { door.open(link) }
        }, read: { try await door.read($0) }, pageRead: { try await door.readFace($0) },
                        releaseFace: { await door.releaseFace($0) }, scope: { door.scoped(to: $0) }, perform: { await door.act($0) })
    }
    public var body: some View {
        Group {
            #if os(macOS)
            if width >= 900 {
                HSplitView {
                    list.frame(minWidth: 240, idealWidth: 320)
                    reading.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { pushed }
            #else
            pushed
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { session.attach(viewer); retainedSelection = selectedRow; hold() }
        .onDisappear { session.collections.release(viewer); session.detach(viewer) }
        .onChange(of: face.sections) { _, _ in hold() }
        .onChange(of: holdsDemands) { _, _ in hold() }
        .onChange(of: selection) { _, _ in retainedSelection = selectedRow }
        .onChange(of: (selectionRows ?? rows).map(\.id)) { old, new in
            guard let selection, old.contains(selection), !new.contains(selection) else { return }
            guard selectionRows != nil || face.sections.first(where: { $0.id == face.detail?.of })?.more == nil else { return }
            let index = old.firstIndex(of: selection) ?? 0
            self.selection = old.dropFirst(index + 1).first { new.contains($0) } ?? new.first
            AccessibilityNotification.Announcement(rows.first { $0.id == self.selection }?.title ?? "No items in this collection.").post()
        }
    }
    private func hold() {
        session.collections.hold(holdsDemands ? face.sections.filter { $0.more != nil } : [], items: [], by: viewer, door: door,
                                 anchor: session.scrollAnchor?.row)
    }
    private var list: some View {
        List {
            FaceView(face: face, door: selectingDoor, session: session, leaf: leaf, rowFilter: rowFilter).environment(\.faceInList, true)
        }
            .listStyle(.plain)
            .scrollPosition(id: Binding(get: { session.scrollAnchor }, set: { session.scrollAnchor = $0 }), anchor: .top)
    }
    @ViewBuilder private var reading: some View {
        if let selection { detail(selection, selectedRow).id(selection) }
        else { Text("Choose an item.").foregroundStyle(.secondary) }
    }
    private var pushed: some View {
        Group {
            if let selection {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Back") { self.selection = nil }
                    detail(selection, selectedRow).id(selection)
                }
            } else { list }
        }
    }
}
