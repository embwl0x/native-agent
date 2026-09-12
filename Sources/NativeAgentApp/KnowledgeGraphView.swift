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
        KnowledgeGraphEnableActionPresentation.buttonControl(
            isEnabling: isEnablingGraph, isEnabled: knowledgeGraphEnabled == true
        )
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
        VStack(alignment: .leading, spacing: 12) {
            KGNativeStackHeader(
                status: nativeStack,
                totalEntities: totalEntities,
                totalEdges: totalEdges ?? 0
            )

            if knowledgeGraphEnabled == true {
                Button {
                    Task { await enableKnowledgeGraph(enabled: false) }
                } label: {
                    Label(enableButtonControl.title, systemImage: enableButtonControl.systemImage)
                }
                .disabled(enableButtonControl.isDisabled)
            }

            // 2026-06-06: filter row — kind multi-select + time-window picker.
            // Sits above the search bar and view-mode toggle; applies to both.
            AdvancedCard {
                HStack(spacing: 8) {
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
                        Text(selectedKinds.isEmpty
                             ? "All kinds"
                             : selectedKinds.count == 1
                                ? selectedKinds.first!.capitalized
                                : "\(selectedKinds.count) kinds")
                            .font(ShellType.label)
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
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Knowledge Graph view mode")
                    .accessibilityValue(viewMode.rawValue)
                    .help(viewModeNotice ?? "Choose whether to browse the graph as a list or a graph.")
                }

                // Search + (legacy single-type) filter bar
                HStack(spacing: 8) {
                    TextField("Search entities…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(ShellType.label)
                    Spacer()
                    Picker("Type", selection: $filterType) {
                        ForEach(entityTypes, id: \.self) { t in
                            Text(t.capitalized).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if let viewModeNotice {
                Text(viewModeNotice)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if knowledgeGraphEnabled != nil,
               let completion = enableActionPresentation.completionMessage {
                Text(completion)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let failure = enableActionPresentation.failureMessage {
                Text(failure)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let conflict = filterConflict.message {
                HStack(spacing: 8) {
                    Text(conflict)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                    Spacer()
                    Button("Clear kind filter") {
                        selectedKinds.removeAll()
                    }
                    .controlSize(.small)
                }
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
                AdvancedCard(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(err)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                                .fixedSize(horizontal: false, vertical: true)
                            if isStale {
                                Text("Showing previously loaded data — it may be stale.")
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await loadGraph() }
                        }
                        .controlSize(.small)
                    }
                }
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
                AdvancedWaitingLine("Reading the knowledge graph…")
            case let .unavailable(err):
                // U5 W-C fix-round (gpt-5.5 NEEDS_FIX): error state WINS.
                // Pre-fix, a corrupt store on first load still rendered the
                // healthy "No entities yet" empty state with the real error
                // buried at the bottom — a fabricated-healthy lie. With
                // nothing loaded to show, the error is the whole story.
                AdvancedEmptyState(
                    title: "Couldn't load the knowledge graph",
                    detail: err,
                    actionTitle: "Retry",
                    action: { Task { await loadGraph() } }
                )
            case .policyUnavailable:
                AdvancedEmptyState(
                    title: "Checking Knowledge Graph permission",
                    detail: "The Memory Policy has not loaded yet, so this page will not guess that the graph is off.",
                    actionTitle: "Retry",
                    action: { Task { await reloadKnowledgeGraphPolicyAndGraph() } }
                )
            case .policyUnreadable(let detail):
                AdvancedEmptyState(
                    title: "Knowledge Graph permission unavailable",
                    detail: detail,
                    actionTitle: "Retry",
                    action: { Task { await reloadKnowledgeGraphPolicyAndGraph() } }
                )
            case .disabled:
                AdvancedEmptyState(
                    title: "Knowledge Graph is off",
                    detail: "Turn on Knowledge Graph in Memory Policy to start tracking entities from conversations.",
                    actionTitle: enableButtonControl.title,
                    actionIsDisabled: enableButtonControl.isDisabled,
                    action: {
                        Task {
                            await enableKnowledgeGraph()
                        }
                    }
                )
            case .empty:
                AdvancedEmptyState(
                    title: "No entities yet",
                    detail: "Future conversations will populate entity links here. Refresh after the next chat turn.",
                    actionTitle: "Refresh the graph",
                    action: { Task { await loadGraph() } }
                )
            case .filteredEmpty:
                // Entities exist but the active filter set excludes all of
                // them. Distinct empty state with a clear-all-filters action
                // so the canvas/list never silently goes blank.
                AdvancedEmptyState(
                    title: "No entities match these filters",
                    detail: "Clearing the kind, time and search filters brings the whole graph back.",
                    actionTitle: "Clear filters",
                    action: {
                        selectedKinds.removeAll()
                        timeWindow = .all
                        filterType = "all"
                        searchText = ""
                    }
                )
            case .list:
                splitListAndDetail
            case let .graphSafetyNet(count):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Graph too large (\(count) entities) — showing the list. Tighten the filters above to render as a graph.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .frame(minWidth: 300, maxHeight: .infinity)

                            if let entity = selectedEntity {
                                KGEntityDetailView(
                                    entity: entity, api: api,
                                    selectableEntityIDs: displayedEntityIDs,
                                    onSelectEntity: selectRelatedEntity
                                )
                                    .frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                            } else {
                                AdvancedEmptyState(
                                    title: "No node picked",
                                    detail: "Click a node on the canvas to read what the agent knows about it."
                                )
                                .padding(.horizontal, 16)
                                .frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                            }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // (U5 W-C fix-round: the old bottom-of-stack error Text is gone —
            // errors now render as the dedicated empty-store error state or
            // the banner ABOVE the graph, both added above.)

            // Footer: total count + explicit GC trigger
            if !entities.isEmpty {
                HStack(spacing: 8) {
                    Text("\(totalEntities) entities\(totalEdges.map { " · \($0) edges" } ?? "")")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                    Spacer()
                    if let gcStatus {
                        Text(gcStatus)
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    Button(gcRunning ? "Sweeping…" : "Sweep orphans…") {
                        Task { await previewGCSweep() }
                    }
                    .controlSize(.small)
                    .disabled(gcRunning)
                    .help("Find entities whose source memories were deleted. Shows a preview first — nothing is removed without your confirmation.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 200, idealWidth: 260, maxHeight: .infinity)

            if let entity = selectedEntity {
                KGEntityDetailView(
                    entity: entity, api: api,
                    selectableEntityIDs: displayedEntityIDs,
                    onSelectEntity: selectRelatedEntity
                )
                    .frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
            } else {
                AdvancedEmptyState(
                    title: "No entity picked",
                    detail: "Pick a row on the left to read what the agent knows about it."
                )
                .padding(.horizontal, 16)
                .frame(minWidth: 300, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Without a vertical claim the split sizes to its minimum and the
        // stack centres the leftover: a blank middle with the rows squeezed
        // against the footer (Agent's acceptance walk, 2026-09-12).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectRelatedEntity(_ id: String) {
        // Recheck the current filters at activation, not just when the row
        // rendered. A vanished destination must not clear the current detail.
        guard let destination = KnowledgeGraphPresentation.reconciledSelection(
            id, visibleIDs: displayedEntityIDs
        ) else { return }
        selectedId = destination
    }

}
