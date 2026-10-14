import PersistenceCore
import MemoryV2
import Foundation
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
    var entities: [KnowledgeGraphEntity] { memory.graphEntities }
    var edges: [KnowledgeGraphEdge] { memory.graphEdges }
    var totalEntities: Int { memory.graphTotalEntities }
    var totalEdges: Int? { memory.graphTotalEdges }
    var loading: Bool { memory.graphLoading }
    /// This page's own action error (enable, maintenance). The graph read's
    /// error is the shared graph's, so every mounted page shows it.
    @State var errorMsg: String? = nil
    // Keep the origin alongside the visible error. A maintenance failure can
    // arrive after an older graph-load failure; only the latter makes retained
    // rows stale.
    @State var errorOrigin: KnowledgeGraphPresentation.ErrorOrigin? = nil
    /// Both errors when both stand; a failed shared read marks rows stale.
    var shownError: String? {
        let errors = [memory.graphLoadError, errorMsg].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
    var shownErrorOrigin: KnowledgeGraphPresentation.ErrorOrigin? {
        memory.graphLoadError != nil ? .graphLoad : errorOrigin
    }
    @State var policyReadError: String? = nil
    @State private var filterProjection = KnowledgeGraphPresentation.FilterProjection()
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
    var selectedEntity: KnowledgeGraphEntity? {
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

    // The graph and every entity read come from one facade, passed into
    // KGEntityDetailView so all reads use the same root.
    var memory: MemoryFacade { appModel.engine.memory }

    let entityTypes = KnowledgeGraphFilterCatalog.entityTypes
    // Multi-select catalog — same list, minus "all" (selection-empty IS all).
    let kindCatalog = KnowledgeGraphFilterCatalog.selectableKinds

    /// `nil` is an unread policy, not an off graph. The empty state must never
    /// offer an enable action based on a missing authority read.
    var knowledgeGraphEnabled: Bool? {
        appModel.engine.trust.policy?.memoryPolicy?.knowledge_graph_enabled
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
    static func parseKGDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let date = UserDisplayFormatters.parseFoundationISOTimestamp(s) { return date }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: String(s.prefix(10)))
    }

    var displayEntities: [KnowledgeGraphEntity] {
        filterProjection.entities(entities, type: filterType, kinds: selectedKinds,
                                  window: timeWindow, query: searchText)
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
            // The counts strip is this card's first row.
            AliveGroupCard {
                KGNativeStackHeader(
                    status: nativeStack,
                    totalEntities: totalEntities,
                    totalEdges: totalEdges ?? 0
                )
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
                    .hazeTinted(.segments)
                    .fixedSize()
                    .accessibilityLabel("Knowledge Graph view mode")
                    .accessibilityValue(viewMode.rawValue)
                    .help(viewModeNotice ?? "Choose whether to browse the graph as a list or a graph.")
                }

                // Search + (legacy single-type) filter bar
                HStack(spacing: 8) {
                    NativeSearchField(text: $searchText, prompt: "Search entities…",
                                      identifier: "knowledgeGraph.search",
                                      accessibilityLabel: "Search entities")
                        .frame(maxWidth: 260)
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
                error: shownError,
                entityCount: entities.count,
                errorOrigin: shownErrorOrigin
            ) {
                AliveGroupCard {
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
                error: shownError,
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
                                    entity: entity, memory: memory,
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
        .liveTask {
            guard await loadKnowledgeGraphPolicy() else { return }
            guard !Task.isCancelled else { return }
            await loadGraph()
        }
        // Selection sync: when the active filter set drops the currently
        // selected id from `displayEntities`, clear it so the detail pane
        // doesn't keep showing a node the user can no longer see. Watch the
        // sorted id-list signature rather than the array itself — cheaper and
        // matches what the canvas keys layout on.
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
                    entity: entity, memory: memory,
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

/// Presentation state for the Knowledge Graph opt-out action. A policy
/// write is not a graph read: success means the canonical Memory Policy
/// committed, even if the follow-up graph load later has no rows or fails.
enum KnowledgeGraphEnableActionPresentation: Equatable {
    case idle
    case enabling
    case enabled
    case disabling
    case disabled
    case failed(String)

    struct ButtonControl: Equatable {
        let title: String
        let systemImage: String
        let isDisabled: Bool
    }

    static func buttonControl(isEnabling: Bool, isEnabled: Bool = false) -> ButtonControl {
        ButtonControl(
            title: isEnabling
                ? (isEnabled ? "Disabling..." : "Enabling...")
                : (isEnabled ? "Disable Knowledge Graph" : "Enable Knowledge Graph"),
            systemImage: isEnabling ? "hourglass" : (isEnabled ? "pause.circle" : "checkmark.circle"),
            isDisabled: isEnabling
        )
    }

    static func failure(statusText: String, enabling: Bool = false) -> Self {
        let detail = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = enabling ? "enabled" : "disabled"
        return .failed(
            detail.isEmpty
                ? "Knowledge Graph could not be \(action) because the memory settings could not be saved."
                : "Knowledge Graph could not be \(action). \(detail)"
        )
    }

    var completionMessage: String? {
        if case .disabled = self {
            return "Knowledge Graph disabled. New conversations will no longer contribute entity links."
        }
        if case .enabled = self {
            return "Knowledge Graph enabled. New conversations can now contribute entity links."
        }
        return nil
    }

    var failureMessage: String? {
        if case let .failed(detail) = self {
            return detail
        }
        return nil
    }
}

/// The policy operation is separate from graph loading: its durable success
/// condition is the checked Memory Policy write. Keeping the action here lets
/// the mounted page and non-UI callers share one outcome contract.
enum KnowledgeGraphEnableAction {
    @MainActor
    static func perform(using appModel: AppModel, enabled: Bool = true) async -> KnowledgeGraphEnableActionPresentation {
        guard await appModel.patchMemoryPolicy(knowledgeGraphEnabled: enabled),
              appModel.engine.trust.policy?.memoryPolicy?.knowledge_graph_enabled == enabled else {
            return .failure(statusText: appModel.statusText, enabling: enabled)
        }
        return enabled ? .enabled : .disabled
    }
}

/// Presentation-ready result of the explicit orphan-sweep preview. Keeping
/// the operation's error translation at the action boundary lets every UI
/// surface show the same concrete failure without depending on detached
/// SwiftUI `@State` storage.
enum KnowledgeGraphMaintenancePresentation {
    /// The complete visible state of the explicit sweep action. The view
    /// copies this state into SwiftUI storage; tests can observe the same
    /// result without constructing a detached view whose `@State` is inert.
    struct State: Equatable {
        let status: String?
        let candidates: [KnowledgeGraphGCCandidate]
        let candidateIDs: Set<String>
        let presentsConfirmation: Bool
        let errorMessage: String?
        let requiresGraphReload: Bool
    }

    enum PreviewOutcome: Equatable {
        case noCandidates
        case candidates([KnowledgeGraphGCCandidate])
        case failed(String)
    }

    enum ApplyOutcome: Equatable {
        case applied(KnowledgeGraphGCReport)
        case previewDiverged([KnowledgeGraphGCCandidate])
        case failed(String)
    }

    static func preview(
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> PreviewOutcome {
        do {
            let report = try await actions.previewOrphanSweep()
            return report.candidates.isEmpty
                ? .noCandidates
                : .candidates(report.candidates)
        } catch {
            return .failed(UserFacingError.message(error, action: "sweep orphaned entities"))
        }
    }

    static func previewState(
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> State {
        switch await preview(actions: actions) {
        case .noCandidates:
            return State(
                status: "No orphaned entities.", candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: nil, requiresGraphReload: false
            )
        case let .candidates(candidates):
            return State(
                status: nil, candidates: candidates, candidateIDs: Set(candidates.map(\.id)),
                presentsConfirmation: true, errorMessage: nil, requiresGraphReload: false
            )
        case let .failed(message):
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: message, requiresGraphReload: false
            )
        }
    }

    static func apply(
        expectedCandidateIDs: Set<String>,
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> ApplyOutcome {
        do {
            switch try await actions.applyOrphanSweep(expectedCandidateIDs: expectedCandidateIDs) {
            case let .applied(report):
                return .applied(report)
            case let .previewDiverged(currentCandidates):
                return .previewDiverged(currentCandidates)
            }
        } catch {
            return .failed(UserFacingError.message(error, action: "sweep orphaned entities"))
        }
    }

    static func applyState(
        expectedCandidateIDs: Set<String>,
        actions: KnowledgeGraphMaintenanceActions = .init()
    ) async -> State {
        switch await apply(expectedCandidateIDs: expectedCandidateIDs, actions: actions) {
        case let .applied(report):
            return State(
                status: "Removed \(report.entitiesDeleted) entities · \(report.edgesDeleted) edges.",
                candidates: [], candidateIDs: [], presentsConfirmation: false,
                errorMessage: nil, requiresGraphReload: true
            )
        case let .previewDiverged(candidates):
            return State(
                status: nil, candidates: candidates, candidateIDs: Set(candidates.map(\.id)),
                presentsConfirmation: true,
                errorMessage: "Orphan set changed before deletion. Review the updated candidates and confirm again.",
                requiresGraphReload: false
            )
        case let .failed(message):
            return State(
                status: nil, candidates: [], candidateIDs: [],
                presentsConfirmation: false, errorMessage: message, requiresGraphReload: false
            )
        }
    }
}

extension KnowledgeGraphView {
    /// Policy authority is read separately from graph contents so unreadable
    /// bytes cannot leave the mounted page indefinitely saying "Checking".
    /// The enable action remains unavailable until this checked read succeeds.
    func loadKnowledgeGraphPolicy() async -> Bool {
        if appModel.engine.trust.policy != nil {
            policyReadError = nil
            return true
        }
        do {
            appModel.engine.trust.policy = try await appModel.engine.trust.load()
            policyReadError = nil
            return true
        } catch {
            policyReadError = UserFacingError.message(error, action: "read the trust policy")
            return false
        }
    }

    func reloadKnowledgeGraphPolicyAndGraph() async {
        guard await loadKnowledgeGraphPolicy() else { return }
        await loadGraph()
    }

    func loadGraph() async {
        guard !Task.isCancelled else { return }
        // ui-honesty 2026-06-10: clear the previous error at the start of
        // every load — a stale failure message used to persist over a
        // subsequent successful refresh.
        errorMsg = nil
        errorOrigin = nil
        // U5 W-C fix-round: a failed read keeps whatever loaded previously
        // (the banner marks it stale) — but the error is rendered FIRST,
        // never under a fabricated healthy empty state. The read's own error
        // lives on the shared graph (`shownError`).
        await memory.loadGraph()
        guard !Task.isCancelled, memory.graphLoadError == nil else { return }
        let status = await KGNativeStackStatus.load(entityCount: totalEntities)
        guard !Task.isCancelled else { return }
        nativeStack = status
    }

    func enableKnowledgeGraph(enabled: Bool = true) async {
        guard !isEnablingGraph else { return }
        isEnablingGraph = true
        defer { isEnablingGraph = false }
        enableActionPresentation = enabled ? .enabling : .disabling
        errorMsg = nil
        errorOrigin = nil
        let outcome = await KnowledgeGraphEnableAction.perform(using: appModel, enabled: enabled)
        enableActionPresentation = outcome
        guard outcome == .enabled || outcome == .disabled else { return }
        await loadGraph()
    }

    // U5 W-C: GC sweep — dry-run preview, then user-confirmed apply.

    func previewGCSweep(actions: KnowledgeGraphMaintenanceActions = .init()) async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        applyGCSweepPresentation(
            await KnowledgeGraphMaintenancePresentation.previewState(actions: actions)
        )
    }

    func applyGCSweep(actions: KnowledgeGraphMaintenanceActions = .init()) async {
        guard !gcRunning else { return }
        gcRunning = true
        defer { gcRunning = false }
        let presentation = await KnowledgeGraphMaintenancePresentation.applyState(
            expectedCandidateIDs: gcPreviewCandidateIDs,
            actions: actions
        )
        applyGCSweepPresentation(presentation)
        if presentation.requiresGraphReload {
            await loadGraph()
        }
    }

    private func applyGCSweepPresentation(
        _ presentation: KnowledgeGraphMaintenancePresentation.State
    ) {
        gcStatus = presentation.status
        gcCandidates = presentation.candidates
        gcPreviewCandidateIDs = presentation.candidateIDs
        showGCConfirm = presentation.presentsConfirmation
        errorMsg = presentation.errorMessage
        errorOrigin = presentation.errorMessage == nil ? nil : .maintenance
    }
}

enum KnowledgeGraphFilterCatalog {
    static let entityTypes = [
        "all", "person", "organization", "project", "concept", "place", "event", "tool", "fact",
    ]
    static let selectableKinds = Array(entityTypes.dropFirst())
}

/// The single type picker and the multi-kind menu intersect. An empty
/// intersection is a filter contradiction, not evidence that the graph has no
/// data, and must be presented before the generic filtered-empty state.
enum KnowledgeGraphFilterConflict: Equatable {
    case none
    case incompatible(type: String, kinds: [String])

    static func resolve(filterType: String, selectedKinds: Set<String>) -> Self {
        guard filterType != "all", !selectedKinds.isEmpty,
              !selectedKinds.contains(filterType) else { return .none }
        return .incompatible(type: filterType, kinds: selectedKinds.sorted())
    }

    var message: String? {
        switch self {
        case .none:
            return nil
        case let .incompatible(type, kinds):
            let selected = kinds.map(\.capitalized).joined(separator: ", ")
            return "Type \(type.capitalized) conflicts with kind filter \(selected)."
        }
    }
}

/// Keeps the segmented picker and the graph renderer on one explicit routing
/// contract. A selected Graph segment is a request, rather than a claim that
/// a graph has actually been rendered.
enum KGViewModePickerPreference {
    static let key = "knowledgeGraphViewMode"

    static func resolve(persistedValue: String?) -> KGViewMode {
        guard let persistedValue,
              let mode = KGViewMode(rawValue: persistedValue) else {
            return .list
        }
        return mode
    }

    static func persistedValue(for mode: KGViewMode) -> String {
        mode.rawValue
    }


}

/// The picker has a tiny value-state owner so both the persisted preference
/// and the renderer route through one canonical mode. Keeping this outside
/// the SwiftUI view makes an unmounted view incapable of fabricating picker
/// state in an eval.
struct KGViewModePickerState: Equatable {
    let selectedMode: KGViewMode

    init(persistedValue: String?) {
        selectedMode = KGViewModePickerPreference.resolve(persistedValue: persistedValue)
    }

    var persistedValue: String {
        KGViewModePickerPreference.persistedValue(for: selectedMode)
    }
}

enum KGViewModePickerPresentation {
    /// Mirror the actual canvas owner. The picker is a helpful early route;
    /// `KGGraphCanvasLayout` still enforces this cap for every direct caller.
    static let maximumGraphEntities = KGGraphCanvasLayout.maximumRenderableEntities

    enum Route: Equatable {
        case list
        case graph
        case graphSafetyFallback(entityCount: Int)
    }

    static func route(requested: KGViewMode, displayedEntityCount: Int) -> Route {
        guard requested == .graph else { return .list }
        guard displayedEntityCount <= maximumGraphEntities else {
            return .graphSafetyFallback(entityCount: displayedEntityCount)
        }
        return .graph
    }

    static func pickerNotice(requested: KGViewMode, displayedEntityCount: Int) -> String? {
        guard case let .graphSafetyFallback(entityCount) = route(
            requested: requested,
            displayedEntityCount: displayedEntityCount
        ) else { return nil }
        return "Graph view is unavailable for \(entityCount) shown entities; the list is displayed instead. Narrow the filters to use the graph."
    }
}

@MainActor
enum KnowledgeGraphPresentation {
    /// Selection and drawing reuse the same filter result until an input or
    /// the next timestamp boundary changes. Dates are parsed once per source.
    final class FilterProjection {
        private var source: [KnowledgeGraphEntity] = []
        private var dates: [Date?] = []
        private var type = ""
        private var kinds: Set<String> = []
        private var window: KGTimeWindow = .all
        private var query = ""
        private var rows: [KnowledgeGraphEntity] = []
        private var validUntil = Date.distantPast
        private var evaluatedAt = Date.distantPast
        private var calendar = Calendar.current

        func entities(_ entities: [KnowledgeGraphEntity], type: String, kinds: Set<String>,
                      window: KGTimeWindow, query: String) -> [KnowledgeGraphEntity] {
            let now = Date()
            let currentCalendar = Calendar.current
            let changed = source != entities
            if !changed, self.type == type, self.kinds == kinds,
               self.window == window, self.query == query, calendar == currentCalendar,
               now >= evaluatedAt, now < validUntil { return rows }
            if changed {
                source = entities
                dates = entities.map {
                    KnowledgeGraphView.parseKGDate($0.lastSeen) ?? KnowledgeGraphView.parseKGDate($0.firstSeen)
                }
            }
            self.type = type
            self.kinds = kinds
            self.window = window
            self.query = query
            calendar = currentCalendar
            evaluatedAt = now
            let cutoff = window.cutoff
            rows = zip(entities, dates).compactMap { entity, date in
                guard (type == "all" || entity.type == type),
                      (kinds.isEmpty || kinds.contains(entity.type)),
                      cutoff == nil || date.map({ $0 >= cutoff! }) == true,
                      query.isEmpty || entity.name.localizedCaseInsensitiveContains(query)
                        || (entity.summary ?? "").localizedCaseInsensitiveContains(query) else { return nil }
                return entity
            }
            let days = window == .day ? 1 : window == .week ? 7 : 30
            validUntil = cutoff == nil ? .distantFuture : dates.compactMap { date in
                date.flatMap { currentCalendar.date(byAdding: .day, value: days, to: $0) }
            }.filter { $0 > now }.min() ?? .distantFuture
            return rows
        }
    }

    enum Content: Equatable { case loading, unavailable(String), policyUnavailable, policyUnreadable(String), disabled, empty, filteredEmpty, list, graph, graphSafetyNet(count: Int) }
    enum ErrorPlacement: Equatable { case none, emptyState(String), retainedDataBanner(message: String, isStale: Bool) }
    /// Error provenance is retained with the message so the mounted banner
    /// never labels a maintenance-action error as stale graph data.  A boolean
    /// from an earlier load attempt is insufficient: a later GC failure can
    /// replace the visible message while retained graph rows are still current.
    enum ErrorOrigin: Equatable { case graphLoad, policyAction, maintenance }
    static func content(
        isLoading: Bool,
        error: String?,
        entityCount: Int,
        displayedEntityCount: Int,
        renderableGraphEntityCount: Int? = nil,
        isEnabled: Bool?,
        viewMode: KGViewMode,
        policyReadError: String? = nil
    ) -> Content {
        if let error, entityCount == 0 { return .unavailable(error) }
        // Retained rows are still useful while a refresh is in flight. Do not
        // replace them with an unlabelled spinner; the error presentation
        // above the graph carries the failure/provenance instead.
        if isLoading && entityCount == 0 { return .loading }
        if isEnabled == nil,
           let policyReadError,
           !policyReadError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .policyUnreadable(policyReadError)
        }
        if isEnabled == nil { return .policyUnavailable }
        if entityCount == 0 { return isEnabled == true ? .empty : .disabled }
        if displayedEntityCount == 0 { return .filteredEmpty }
        switch KGViewModePickerPresentation.route(
            requested: viewMode,
            displayedEntityCount: renderableGraphEntityCount ?? displayedEntityCount
        ) {
        case .list:
            return .list
        case .graph:
            return .graph
        case let .graphSafetyFallback(entityCount):
            return .graphSafetyNet(count: entityCount)
        }
    }

    static func errorPlacement(
        isLoading _: Bool,
        error: String?,
        entityCount: Int,
        errorOrigin: ErrorOrigin?
    ) -> ErrorPlacement {
        // A maintenance action can fail while another graph operation is
        // loading. The error is still evidence and must remain visible; the
        // content classifier decides whether an empty graph shows a full
        // unavailable state or retained rows stay on screen.
        guard let error else { return .none }
        return entityCount == 0
            ? .emptyState(error)
            : .retainedDataBanner(message: error, isStale: errorOrigin == .graphLoad)
    }

    /// A filter change may remove the selected node from the rendered graph.
    /// Keep the transition explicit so a second layout/update cannot be
    /// mistaken for another user-visible clear.
    enum SelectionReconciliation: Equatable {
        case alreadyEmpty
        case retained(String)
        case cleared(String)

        var selectedID: String? {
            switch self {
            case .alreadyEmpty, .cleared:
                return nil
            case let .retained(id):
                return id
            }
        }
    }

    static func reconcileSelection(
        _ selectedID: String?,
        visibleIDs: Set<String>
    ) -> SelectionReconciliation {
        guard let selectedID else { return .alreadyEmpty }
        return visibleIDs.contains(selectedID) ? .retained(selectedID) : .cleared(selectedID)
    }

    static func reconciledSelection(_ selectedID: String?, visibleIDs: Set<String>) -> String? {
        reconcileSelection(selectedID, visibleIDs: visibleIDs).selectedID
    }

}
