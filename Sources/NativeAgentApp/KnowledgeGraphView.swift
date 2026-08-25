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
    // Keep the origin alongside the visible error. A maintenance failure can
    // arrive after an older graph-load failure; only the latter makes retained
    // rows stale.
    @State var errorOrigin: KnowledgeGraphPresentation.ErrorOrigin? = nil
    @State var policyReadError: String? = nil
    @State var searchText = ""
    @State var filterType: String = "all"
    @State var isEnablingGraph = false
    @State var enableActionPresentation: KnowledgeGraphEnableActionPresentation = .idle
    @State var nativeStack: KGNativeStackStatus = .empty
    // Single source of truth for selection. Both the list and the graph canvas
    // write here; `selectedEntity` (below) is derived. Avoids the two-state
    // drift the previous attempt had where graph clicks and list selections
    // could disagree.
    @State var selectedId: String? = nil

    /// Computed view of the selection — `nil` when nothing is selected OR the
    /// selected id is no longer visible under the active filters.  The
    /// on-change handler also clears stale state, while this read prevents a
    /// one-render detail-pane leak before SwiftUI delivers that handler.
    var selectedEntity: KGEntity? {
        guard let id = KnowledgeGraphPresentation.reconciledSelection(
            selectedId,
            visibleIDs: displayedEntityIDs
        ) else { return nil }
        return displayEntities.first(where: { $0.id == id })
    }

    /// These projections are the exact visibility contract used by both the
    /// detail pane's immediate read and the persisted selection reconciliation.
    /// Keeping them shared prevents the one-render stale-detail window from
    /// reappearing when the filters change.
    var displayedEntityIDs: Set<String> {
        Set(displayEntities.map(\.id))
    }

    var displayedEntitySignature: String {
        displayEntities.map(\.id).sorted().joined(separator: "|")
    }

    /// The canvas removes blank and duplicate identifiers before it enters its
    /// quadratic layout. Route the safety fallback using that same canonical
    /// participant count, so malformed duplicate rows cannot unnecessarily
    /// block a safe graph and every actual canvas participant is still capped.
    var renderableGraphEntityCount: Int {
        KGGraphCanvasLayout.canonicalEntities(displayEntities).count
    }

    var selectionReconciliation: KnowledgeGraphPresentation.SelectionReconciliation {
        KnowledgeGraphPresentation.reconcileSelection(
            selectedId,
            visibleIDs: displayedEntityIDs
        )
    }
    // 2026-06-06: view-mode + filter state. Defaults to `.list` so existing
    // users see no surprise on upgrade.
    @AppStorage(KGViewModePickerPreference.key) private var persistedViewMode = KGViewMode.list.rawValue
    @State var selectedKinds: Set<String> = []  // empty = all
    @State var timeWindow: KGTimeWindow = .all

    // U5 W-C (2026-06-11): explicit GC trigger state. The sweep is NEVER
    // automatic — the button runs a dry-run preview, the confirmation dialog
    // is the approval, and only then does apply run (the user's click is the
    // `approvedOverThreshold` consent).
    @State var gcRunning = false
    @State var gcStatus: String? = nil
    @State var gcCandidates: [KnowledgeGraphGCCandidate] = []
    @State var gcPreviewCandidateIDs: Set<String> = []
    @State var showGCConfirm = false

    // Source from AppModel's canonical client; the handle is passed into
    // KGEntityDetailView so all reads use the same in-process owner.
    var api: NativeClient { appModel.client }

    let entityTypes = KnowledgeGraphFilterCatalog.entityTypes
    // Multi-select catalog — same list, minus "all" (selection-empty IS all).
    let kindCatalog = KnowledgeGraphFilterCatalog.selectableKinds

    /// `nil` is an unread policy, not an off graph. The empty state must never
    /// offer an enable action based on a missing authority read.
    var knowledgeGraphEnabled: Bool? {
        appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled
    }

    var enableButtonControl: KnowledgeGraphEnableActionPresentation.ButtonControl {
        KnowledgeGraphEnableActionPresentation.buttonControl(isEnabling: isEnablingGraph)
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
        KnowledgeGraphPresentation.filteredEntities(
            entities,
            filterType: filterType,
            selectedKinds: selectedKinds,
            cutoff: timeWindow.cutoff,
            query: searchText
        )
    }

    var viewMode: KGViewMode {
        KGViewModePickerState(persistedValue: persistedViewMode).selectedMode
    }

    var viewModeSelection: Binding<KGViewMode> {
        Binding(
            get: { viewMode },
            set: { persistedViewMode = KGViewModePickerState(persistedValue: $0.rawValue).persistedValue }
        )
    }

    var viewModeNotice: String? {
        KGViewModePickerPresentation.pickerNotice(
            requested: viewMode,
            displayedEntityCount: renderableGraphEntityCount
        )
    }

    var filterConflict: KnowledgeGraphFilterConflict {
        KnowledgeGraphFilterConflict.resolve(
            filterType: filterType,
            selectedKinds: selectedKinds
        )
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

                Picker("View", selection: viewModeSelection) {
                    ForEach(KGViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Knowledge Graph view mode")
                .accessibilityValue(viewMode.rawValue)
                .help(viewModeNotice ?? "Choose whether to browse the graph as a list or a graph.")
            }
            .padding(.horizontal, NativeAgentSpacing.md)
            .padding(.vertical, NativeAgentSpacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.top, NativeAgentSpacing.md)

            if let viewModeNotice {
                Label(viewModeNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NativeAgentSpacing.lg)
                    .padding(.top, NativeAgentSpacing.xs)
            }

            if knowledgeGraphEnabled == true,
               let completion = enableActionPresentation.completionMessage {
                Label(completion, systemImage: "checkmark.circle")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NativeAgentSpacing.lg)
                    .padding(.top, NativeAgentSpacing.xs)
            }

            if let failure = enableActionPresentation.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NativeAgentSpacing.lg)
                    .padding(.top, NativeAgentSpacing.xs)
            }

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

            if let conflict = filterConflict.message {
                HStack(spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(conflict)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear kind filter") {
                        selectedKinds.removeAll()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, NativeAgentSpacing.lg)
                .padding(.vertical, NativeAgentSpacing.xs)
                .accessibilityElement(children: .combine)
            }

            // U5 W-C fix-round (gpt-5.5 NEEDS_FIX): when an error lands AFTER
            // a successful load, the error banner renders ABOVE the retained
            // graph — never below it, never silently. The stale-data marker
            // appears only for LOAD failures (the data on screen predates the
            // failure); a GC-sweep failure shows the error without the marker
            // because the rendered graph is still current.
            if case let .retainedDataBanner(err, isStale) = KnowledgeGraphPresentation.errorPlacement(
                isLoading: loading,
                error: errorMsg,
                entityCount: entities.count,
                errorOrigin: errorOrigin
            ) {
                HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(err)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.red)
                        if isStale {
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

            switch KnowledgeGraphPresentation.content(
                isLoading: loading,
                error: errorMsg,
                entityCount: entities.count,
                displayedEntityCount: displayEntities.count,
                renderableGraphEntityCount: renderableGraphEntityCount,
                isEnabled: knowledgeGraphEnabled,
                viewMode: viewMode,
                policyReadError: policyReadError
            ) {
            case .loading:
                ProgressView("Loading graph…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(err):
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
            case .policyUnavailable:
                NativeEmptyState(
                    title: "Checking Knowledge Graph permission",
                    detail: "The Memory Policy has not loaded yet, so this page will not guess that the graph is off.",
                    systemImage: "clock",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await reloadKnowledgeGraphPolicyAndGraph() } }
                )
            case .policyUnreadable(let detail):
                NativeEmptyState(
                    title: "Knowledge Graph permission unavailable",
                    detail: detail,
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await reloadKnowledgeGraphPolicyAndGraph() } }
                )
            case .disabled:
                NativeEmptyState(
                    title: "Knowledge Graph is off",
                    detail: "Turn on Knowledge Graph in Memory Policy to start tracking entities from conversations.",
                    systemImage: "circle.hexagongrid",
                    actionTitle: enableButtonControl.title,
                    actionImage: enableButtonControl.systemImage,
                    actionIsDisabled: enableButtonControl.isDisabled,
                    action: {
                        Task {
                            await enableKnowledgeGraph()
                        }
                    }
                )
            case .empty:
                NativeEmptyState(
                    title: "No entities yet",
                    detail: "Future conversations will populate entity links here. Use refresh after the next chat turn.",
                    systemImage: "circle.hexagongrid",
                    actionTitle: "Refresh Graph",
                    actionImage: "arrow.clockwise",
                    action: { Task { await loadGraph() } }
                )
            case .filteredEmpty:
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
            case .list:
                splitListAndDetail
            case let .graphSafetyNet(count):
                VStack(spacing: NativeAgentSpacing.sm) {
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Graph too large (\(count) entities) — showing list. Tighten the filters above to render as a graph.")
                            .font(NativeAgentFont.label).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, NativeAgentSpacing.lg)
                    splitListAndDetail
                }
            case .graph:
                // 2026-06-06: viewMode is now user-controlled. The >200 safety
                // net only fires inside `.graph` (F3: the hand-rolled
                // force-directed layout is O(n²) per iteration and gets
                // visually meaningless past a couple hundred nodes). In
                // `.list` mode we always show the list regardless of count.
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
            guard await loadKnowledgeGraphPolicy() else { return }
            await loadGraph()
            nativeStack = await KGNativeStackStatus.load(graphCounts: (totalEntities, totalEdges ?? 0))
        }
        // Selection sync: when the active filter set drops the currently
        // selected id from `displayEntities`, clear it so the detail pane
        // doesn't keep showing a node the user can no longer see. Watch the
        // sorted id-list signature rather than the array itself (KGEntity is
        // not Equatable) — cheaper and matches what the canvas keys layout on.
        .onChange(of: displayedEntitySignature) { _, _ in
            selectedId = selectionReconciliation.selectedID
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
