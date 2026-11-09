import Foundation
import Combine
import SwiftUI
import NativeAgentShared
// Blueprint: | `KnowledgeGraphView.swift` | Shared graph collection and selected item demands; the native canvas is a page leaf |

struct KnowledgeGraphView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedId: String?
    @State private var review = false
    @State private var selectedKinds: Set<String> = []
    @State private var timeWindow = KGTimeWindow.all
    @State private var filterClock = Date()
    @AppStorage("knowledgeGraphViewMode") private var mode = KGViewMode.list.rawValue
    private var session: FacePageSession { appModel.pageSessions.page("knowledge") }
    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page("knowledge")).value(as: PartFaceSnapshot.self) }
    private var graph: KnowledgeGraphFace? { appModel.face.slot(.knowledgeGraph).value(as: KnowledgeGraphFace.self) }
    private var entities: [FaceGraphEntity] { graph?.entities ?? [] }
    private var edges: [FaceGraphEdge] { graph?.edges ?? [] }
    private var visibleIDs: Set<String> { Set(visible.map(\.id)) }
    private var selectionRows: [PartFace.Row] {
        visible.map { .init(id: $0.id, title: $0.name, open: "page:knowledge/entity:" + $0.id) }
    }
    private var visible: [FaceGraphEntity] {
        let cutoff = timeWindow.cutoff(at: filterClock)
        return entities.filter { entity in
            (selectedKinds.isEmpty || selectedKinds.contains(entity.kind)) &&
                (timeWindow == .all || cutoff.map { boundary in entity.lastSeen.map { $0 >= boundary } == true } == true) &&
                session.matchesFilter(.init(id: entity.id, title: entity.name, detail: entity.kind.capitalized))
        }
    }
    private var filterExpiry: Date? {
        guard let days = timeWindow.days else { return nil }
        return entities.compactMap(\.lastSeen).compactMap { Calendar.current.date(byAdding: .day, value: days, to: $0) }
            .filter { $0 > filterClock }.min()
    }

    var body: some View {
        Group {
            if let snapshot, let face = presentation(snapshot) {
                FaceSelectionView(face: face, session: session, selection: $selectedId, door: door, page: "knowledge", leaf: leaf,
                    selectionRows: selectionRows, rowFilter: { visibleIDs.contains($0.id) }) { item, _ in
                    AnyView(FaceItemView(item: "entity:" + item, revision: face.sections.first(where: { $0.id == "entities" })?.revision,
                        door: appModel.pageDoor(page: "knowledge/entity:" + item, open: open),
                        reader: appModel.pageDoor(page: "knowledge", open: open),
                        session: appModel.pageSessions.page("knowledge/entity:" + item)))
                }
            } else if let snapshot { FaceView(snapshot: snapshot, title: "Knowledge Graph", door: door, session: session) }
            else { Text("Waiting on the knowledge graph…").foregroundStyle(.secondary) }
        }
        .faceObservation(.key(.page("knowledge")))
        .faceObservation(.key(.knowledgeGraph))
        .sheet(isPresented: $review) {
            PageSheetHost(title: "Graph upkeep", onDone: { review = false }) {
                FaceItemView(item: "upkeep", door: appModel.pageDoor(page: "knowledge/upkeep", open: open),
                    reader: appModel.pageDoor(page: "knowledge", open: open), session: appModel.pageSessions.page("knowledge/upkeep"))
                    .padding(16)
            }
        }
        .onChange(of: timeWindow) { _, _ in filterClock = Date() }
        .onChange(of: entities) { _, _ in filterClock = Date() }
        .onReceive(Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
        ])) { _ in filterClock = Date() }
        .task(id: filterExpiry) {
            guard let deadline = filterExpiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            filterClock = Date()
        }
        .navigationTitle("Knowledge Graph")
    }

    private func presentation(_ snapshot: PartFaceSnapshot) -> PartFace? {
        guard var face = snapshot.drawnFace else { return nil }
        guard KGViewMode(rawValue: mode) != nil else {
            return PartFace(title: face.title, sections: [filters, .init(id: "drawing-unavailable", style: .note,
                rows: [.init(id: "drawing-unavailable", title: "The saved drawing choice is unavailable. Choose List or Graph.", tone: .failed)])])
        }
        face.sections = face.sections.map { section in
            guard section.id == "entities" else { return section }
            var drawn = section
            if mode == KGViewMode.graph.rawValue {
                drawn.block = .init(kind: "leaf", key: "graph-canvas", leaf: "graph", ref: "knowledge",
                                    alt: "Knowledge Graph canvas with \(visible.count) entities")
            }
            return drawn
        }
        face.sections = [filters] + face.sections + (snapshot.levers ?? [])
        if timeWindow != .all, entities.contains(where: { $0.lastSeen == nil }) {
            face.sections.insert(.init(id: "recency", style: .note, rows: [.init(id: "unknown", title:
                "Entities without a last-seen timestamp are outside this time filter. Choose All time to include them.", tone: .quiet)]), at: 1)
        }
        if timeWindow != .all, timeWindow.cutoff(at: filterClock) == nil {
            face.sections.insert(.init(id: "calendar-unavailable", style: .note, rows: [.init(id: "calendar-unavailable",
                title: "The calendar could not determine this time window.", tone: .failed)]), at: 1)
        }
        return face
    }

    private var filters: PartFace.Section {
        let kinds = KnowledgeGraphFilterCatalog.selectableKinds.map { kind in
            PartFace.Row(id: "kind:" + kind, title: kind.capitalized, control: .toggle(selectedKinds.contains(kind),
                call: .init("graph.filter.kind", ["kind": .string(kind)])))
        }
        return .init(id: "filters", title: "View", style: .list, rows: [
            .init(id: "drawing", title: "Drawing", control: .choice(KGViewMode.allCases.map { .init(id: $0.rawValue, label: $0.rawValue) },
                selected: mode, call: .init("graph.drawing"))),
            .init(id: "time", title: "Time", control: .choice(KGTimeWindow.allCases.map { .init(id: $0.rawValue, label: $0.rawValue) },
                selected: timeWindow.rawValue, call: .init("graph.filter.time"))),
            .init(id: "kinds", title: selectedKinds.isEmpty ? "All kinds" : "Selected kinds", rows: kinds)
        ])
    }

    private var door: ClosureFaceDoor {
        let base = appModel.pageDoor(page: "knowledge", open: open)
        return ClosureFaceDoor(open: open, read: { try await base.read($0) }, pageRead: { try await base.readFace($0) },
            releaseFace: { await base.releaseFace($0) }, scope: { base.scoped(to: $0) }, perform: { submission in
            switch submission.expectedCall.action {
            case "graph.drawing":
                guard let value = submission.value, KGViewMode(rawValue: value) != nil else { return invalidFilter() }
                if mode != value { mode = value }
            case "graph.filter.time":
                guard let value = submission.value, let window = KGTimeWindow(rawValue: value) else { return invalidFilter() }
                timeWindow = window
            case "graph.filter.kind":
                guard case .string(let kind)? = submission.expectedCall.args["kind"],
                      KnowledgeGraphFilterCatalog.selectableKinds.contains(kind), let value = submission.value,
                      value == "on" || value == "off" else { return invalidFilter() }
                if value == "on" { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
            default: return await base.act(submission)
            }
            return FaceActOutcome(effects: .none, accepted: true)
        })
    }

    private func invalidFilter() -> FaceActOutcome {
        .interrupted(WireFailure(code: "graph_filter_invalid", message: "The selected graph filter is unavailable.", cause: nil, effects: .none))
    }

    private func leaf(_ block: PartFace.Block) -> AnyView {
        guard block.leaf == "graph", block.ref == "knowledge" else { return AnyView(Text(block.alt ?? PartFace.Block.updateNote)) }
        return AnyView(KGGraphCanvas(entities: visible, edges: edges, selectedId: $selectedId).frame(minHeight: 360))
    }

    private func open(_ link: String) {
        guard case .page("knowledge", let item?)? = FaceLink(link) else { return }
        if item == "upkeep" { review = true }
        else if item.hasPrefix("entity:") { selectedId = String(item.dropFirst("entity:".count)) }
    }
}
