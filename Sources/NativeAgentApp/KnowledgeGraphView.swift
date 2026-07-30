import SwiftUI
import KnowledgeGraph

// ---------------------------------------------------------------------------
// MARK: - Main view
// ---------------------------------------------------------------------------

// 2026-06-06: KG-graph-toggle — explicit user-controlled List vs Graph mode
// (the existing auto-switch at 200 entities is now a safety net inside Graph
// mode only). Filter row adds kind-multi-select and a time-window picker; both
// apply to BOTH views via `displayEntities`.
enum KGViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case graph = "Graph"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .graph: return "circle.hexagonpath"
        }
    }
}

enum KGTimeWindow: String, CaseIterable, Identifiable {
    case all = "All time"
    case day = "Last day"
    case week = "Last week"
    case month = "Last month"
    var id: String { rawValue }
    /// Cutoff date — anything with `last_seen` (or `first_seen` fallback) at or
    /// after the cutoff is included. `nil` means no filter.
    var cutoff: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all: return nil
        case .day: return cal.date(byAdding: .day, value: -1, to: now)
        case .week: return cal.date(byAdding: .day, value: -7, to: now)
        case .month: return cal.date(byAdding: .day, value: -30, to: now)
        }
    }
}

struct KnowledgeGraphView: View {
    // PATCH-2026-05-07: kg-1 Memory > Graph tab — entity list + detail card
    @Environment(AppModel.self) var appModel
    @State var entities: [KGEntity] = []
    @State var edges: [KGEdge] = []
    @State var totalEntities: Int = 0
    @State var totalEdges: Int? = nil
    @State var loading = false
    @State var errorMsg: String? = nil
    // U5 W-C fix-round: true when the LAST loadGraph() attempt threw. Drives
    // the stale-data marker — a GC-sweep failure also sets errorMsg, but the
    // graph on screen isn't stale in that case, so the marker must not lie.
    @State var lastLoadFailed = false
    @State var searchText = ""
    @State var filterType: String = "all"
    @State var isEnablingGraph = false
    @State var nativeStack: KGNativeStackStatus = .empty
    // Single source of truth for selection. Both the list and the graph canvas
    // write here; `selectedEntity` (below) is derived. Avoids the two-state
    // drift the previous attempt had where graph clicks and list selections
    // could disagree.
    @State var selectedId: String? = nil

    /// Computed view of the selection — `nil` when nothing is selected OR the
    /// selected id was filtered out (the `.onChange` on `displayEntities` keeps
    /// `selectedId` in sync, but compute against `entities` here so a transient
    /// out-of-window id still resolves to its entity for that one render).
    var selectedEntity: KGEntity? {
        guard let id = selectedId else { return nil }
        return entities.first(where: { $0.id == id })
    }
    // 2026-06-06: view-mode + filter state. Defaults to `.list` so existing
    // users see no surprise on upgrade.
    @State var viewMode: KGViewMode = .list
    @State var selectedKinds: Set<String> = []  // empty = all
    @State var timeWindow: KGTimeWindow = .all

    // U5 W-C (2026-06-11): explicit GC trigger state. The sweep is NEVER
    // automatic — the button runs a dry-run preview, the confirmation dialog
    // is the approval, and only then does apply run (the user's click is the
    // `approvedOverThreshold` consent).
    @State var gcRunning = false
    @State var gcStatus: String? = nil
    @State var gcCandidates: [KnowledgeGraphGCCandidate] = []
    @State var showGCConfirm = false

    // Source from AppModel's canonical client; the handle is passed into
    // KGEntityDetailView so all reads use the same in-process owner.
    var api: NativeClient { appModel.client }

    let entityTypes = ["all", "person", "project", "concept", "place", "event", "tool"]
    // Multi-select catalog — same list, minus "all" (selection-empty IS all).
    let kindCatalog = ["person", "project", "concept", "place", "event", "tool"]

    var knowledgeGraphEnabled: Bool {
        appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled ?? false
    }

    /// ISO-8601 string parser used by `first_seen` / `last_seen`. The KG writer
    /// emits canonical RFC-3339 / ISO-8601 strings; older fixtures may emit a
    /// date-only `YYYY-MM-DD`. Both must parse so the time-window filter
    /// doesn't silently drop entities with the older shape.
    ///
    /// Formatters are instantiated locally (not `static let`) because
    /// ISO8601DateFormatter is not `Sendable` and Swift 6 strict-concurrency
    /// rejects shared mutable static state. The cost of allocating two
    /// formatters per parse is negligible compared to the filter sweep itself.
    static func parseKGDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFull.date(from: s) { return d }
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        if let d = isoNoFrac.date(from: s) { return d }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let d = dateOnly.date(from: String(s.prefix(10))) { return d }
        return nil
    }

    var displayEntities: [KGEntity] {
        var list = entities
        // Single-select dropdown ("all" + 6 kinds) takes precedence when not
        // "all"; the multi-select set narrows further. Both empty = no filter.
        if filterType != "all" { list = list.filter { $0.type == filterType } }
        if !selectedKinds.isEmpty {
            list = list.filter { selectedKinds.contains($0.type) }
        }
        if let cutoff = timeWindow.cutoff {
            list = list.filter { entity in
                let stamp = Self.parseKGDate(entity.last_seen)
                    ?? Self.parseKGDate(entity.first_seen)
                guard let stamp else { return false }
                return stamp >= cutoff
            }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.summary ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            KGNativeStackHeader(
                status: nativeStack,
                totalEntities: totalEntities,
                totalEdges: totalEdges ?? 0
            )
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.top, NativeAgentSpacing.md)

            // 2026-06-06: filter row — kind multi-select + time-window picker.
            // Sits above the search bar and view-mode toggle; applies to both.
            HStack(spacing: NativeAgentSpacing.sm) {
                Menu {
                    Button(selectedKinds.isEmpty ? "✓ All kinds" : "All kinds") {
                        selectedKinds.removeAll()
                    }
                    Divider()
                    ForEach(kindCatalog, id: \.self) { kind in
                        Button(action: {
                            if selectedKinds.contains(kind) {
                                selectedKinds.remove(kind)
                            } else {
                                selectedKinds.insert(kind)
                            }
                        }) {
                            Label(
                                "\(selectedKinds.contains(kind) ? "✓ " : "")\(kind.capitalized)",
                                systemImage: KGEntityRow.typeIcon(kind)
                            )
                        }
                    }
                } label: {
                    HStack(spacing: NativeAgentSpacing.xs) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(selectedKinds.isEmpty
                             ? "All kinds"
                             : selectedKinds.count == 1
                                ? selectedKinds.first!.capitalized
                                : "\(selectedKinds.count) kinds")
                            .font(NativeAgentFont.label)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Picker("Time", selection: $timeWindow) {
                    ForEach(KGTimeWindow.allCases) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Picker("View", selection: $viewMode) {
                    ForEach(KGViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, NativeAgentSpacing.md)
            .padding(.vertical, NativeAgentSpacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.top, NativeAgentSpacing.md)

            // Search + (legacy single-type) filter bar
            HStack(spacing: NativeAgentSpacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search entities…", text: $searchText)
                    .textFieldStyle(.plain)
                Spacer()
                Picker("Type", selection: $filterType) {
                    ForEach(entityTypes, id: \.self) { t in
                        Text(t.capitalized).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding(NativeAgentSpacing.md)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.top, NativeAgentSpacing.xs)

            // U5 W-C fix-round (gpt-5.5 NEEDS_FIX): when an error lands AFTER
            // a successful load, the error banner renders ABOVE the retained
            // graph — never below it, never silently. The stale-data marker
            // appears only for LOAD failures (the data on screen predates the
            // failure); a GC-sweep failure shows the error without the marker
            // because the rendered graph is still current.
            if let err = errorMsg, !loading, !entities.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(err)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.red)
                        if lastLoadFailed {
                            Text("Showing previously loaded data — it may be stale.")
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await loadGraph() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                .padding(NativeAgentSpacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
                .padding(.horizontal, NativeAgentSpacing.lg)
                .padding(.top, NativeAgentSpacing.xs)
            }

            if loading {
                ProgressView("Loading graph…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMsg, entities.isEmpty {
                // U5 W-C fix-round (gpt-5.5 NEEDS_FIX): error state WINS.
                // Pre-fix, a corrupt store on first load still rendered the
                // healthy "No entities yet" empty state with the real error
                // buried at the bottom — a fabricated-healthy lie. With
                // nothing loaded to show, the error is the whole story.
                NativeEmptyState(
                    title: "Couldn't load the knowledge graph",
                    detail: err,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await loadGraph() } }
                )
            } else if entities.isEmpty {
                NativeEmptyState(
                    title: knowledgeGraphEnabled ? "No entities yet" : "Knowledge Graph is off",
                    detail: knowledgeGraphEnabled
                        ? "Future conversations will populate entity links here. Use refresh after the next chat turn."
                        : "Turn on Knowledge Graph in Memory Policy to start tracking entities from conversations.",
                    systemImage: "circle.hexagongrid",
                    actionTitle: knowledgeGraphEnabled ? "Refresh Graph" : (isEnablingGraph ? "Enabling..." : "Enable Knowledge Graph"),
                    actionImage: knowledgeGraphEnabled ? "arrow.clockwise" : "checkmark.circle",
                    action: {
                        Task {
                            if knowledgeGraphEnabled {
                                await loadGraph()
                            } else {
                                await enableKnowledgeGraph()
                            }
                        }
                    }
                )
            } else if displayEntities.isEmpty {
                // Entities exist but the active filter set excludes all of
                // them. Distinct empty state with a clear-all-filters action
                // so the canvas/list never silently goes blank.
                VStack(spacing: NativeAgentSpacing.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No entities match these filters.")
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                    Button("Clear filters") {
                        selectedKinds.removeAll()
                        timeWindow = .all
                        filterType = "all"
                        searchText = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 2026-06-06: viewMode is now user-controlled. The >200 safety
                // net only fires inside `.graph` (F3: the hand-rolled
                // force-directed layout is O(n²) per iteration and gets
                // visually meaningless past a couple hundred nodes). In
                // `.list` mode we always show the list regardless of count.
                switch viewMode {
                case .list:
                    splitListAndDetail
                case .graph:
                    if displayEntities.count > 200 {
                        VStack(spacing: NativeAgentSpacing.sm) {
                            HStack {
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                                Text("Graph too large (\(displayEntities.count) entities) — showing list. Tighten the filters above to render as a graph.")
                                    .font(NativeAgentFont.label).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, NativeAgentSpacing.lg)
                            splitListAndDetail
                        }
                    } else {
                        HSplitView {
                            KGGraphCanvas(
                                entities: displayEntities,
                                edges: edges,
                                selectedId: $selectedId
                            )
                            .frame(minWidth: 300)

                            if let entity = selectedEntity {
                                KGEntityDetailView(entity: entity, api: api)
                                    .frame(minWidth: 300)
                            } else {
                                NativeEmptyState(title: "Tap a node", detail: "", systemImage: "hand.tap")
                                    .frame(minWidth: 300)
                            }
                        }
                    }
                }
            }
            // (U5 W-C fix-round: the old bottom-of-stack error Text is gone —
            // errors now render as the dedicated empty-store error state or
            // the banner ABOVE the graph, both added above.)

            // Footer: total count + explicit GC trigger
            if !entities.isEmpty {
                HStack {
                    Text("\(totalEntities) entities\(totalEdges.map { " · \($0) edges" } ?? "")")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let gcStatus {
                        Text(gcStatus)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await previewGCSweep() }
                    } label: {
                        Label(gcRunning ? "Sweeping…" : "Sweep orphans…",
                              systemImage: "trash.slash")
                    }
                    .controlSize(.small)
                    .disabled(gcRunning)
                    .help("Find entities whose source memories were deleted. Shows a preview first — nothing is removed without your confirmation.")
                }
                .padding(.horizontal, NativeAgentSpacing.lg)
                .padding(.vertical, NativeAgentSpacing.xs)
                .background(.ultraThinMaterial)
            }
        }
        .confirmationDialog(
            "Remove \(gcCandidates.count) orphaned entit\(gcCandidates.count == 1 ? "y" : "ies")?",
            isPresented: $showGCConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(gcCandidates.count) entities", role: .destructive) {
                Task { await applyGCSweep() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let preview = gcCandidates.prefix(8).map { $0.name }.joined(separator: ", ")
            Text("Their source memories no longer exist. \(preview)\(gcCandidates.count > 8 ? ", …" : "")")
        }
        .task {
            if appModel.trustPolicy == nil {
                await appModel.refreshForSidebarItem(.knowledge)
            }
            await loadGraph()
            nativeStack = await KGNativeStackStatus.load(graphCounts: (totalEntities, totalEdges ?? 0))
        }
        // Selection sync: when the active filter set drops the currently
        // selected id from `displayEntities`, clear it so the detail pane
        // doesn't keep showing a node the user can no longer see. Watch the
        // sorted id-list signature rather than the array itself (KGEntity is
        // not Equatable) — cheaper and matches what the canvas keys layout on.
        .onChange(of: displayEntities.map(\.id).sorted().joined(separator: "|")) { _, _ in
            if let id = selectedId, !displayEntities.contains(where: { $0.id == id }) {
                selectedId = nil
            }
        }
        // ui-taste-sweep 2026-06-07: every other primary tab sets its own
        // navigationTitle. Without one, the toolbar fell back to the app
        // name ("NativeAgent"), which looked broken next to Chat / Activity
        // / Memories etc. all naming themselves.
        .navigationTitle("Knowledge Graph")
    }

    var splitListAndDetail: some View {
        HSplitView {
            List(displayEntities, selection: $selectedId) { entity in
                KGEntityRow(entity: entity).tag(entity.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 260)

            if let entity = selectedEntity {
                KGEntityDetailView(entity: entity, api: api)
                    .frame(minWidth: 300)
            } else {
                NativeEmptyState(title: "Select an entity", detail: "", systemImage: "hand.tap")
                    .frame(minWidth: 300)
            }
        }
    }

}
