import EngineRuntime
import MemoryV2
import Foundation
import SwiftUI
import Combine
import NativeAgentShared

// Blueprint: | `KnowledgeGraphView.swift` | KnowledgeGraphView: mounted graph browsing and shared MemoryFacade refresh; policy, maintenance and filtering retain their owners |

struct KnowledgeGraphView: View {
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
    @State private var filterProjection = KnowledgeGraphPresentation.GraphFilter()
    @State private var filterClockTick = Date()
    @State var searchText = ""
    @State var isEnablingGraph = false
    @State var enableActionPresentation: KnowledgeGraphEnableActionPresentation = .idle
    // List and canvas share one selection; selectedEntity is derived.
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

    @AppStorage("knowledgeGraphViewMode") private var persistedViewMode = KGViewMode.list.rawValue
    @State var selectedKinds: Set<String> = []  // empty = all
    @State var timeWindow: KGTimeWindow = .all

    // The button previews; confirmation admits only that exact candidate set.
    @State var gcRunning = false
    @State var gcStatus: String? = nil
    @State var gcCandidates: [KnowledgeGraphGCCandidate] = []
    @State var gcPreviewCandidateIDs: Set<String> = []
    @State var showGCConfirm = false

    // The list, canvas and entity detail derive from one facade snapshot.
    var memory: MemoryFacade { appModel.engine.memory }

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

    var displayEntities: [KnowledgeGraphEntity] {
        _ = filterClockTick
        return filterProjection.entities(entities, kinds: selectedKinds,
                                         window: timeWindow, query: searchText)
    }

    private var filterExpiry: Date? {
        _ = displayEntities
        return filterProjection.nextExpiry
    }

    var viewMode: KGViewMode {
        KGViewMode(rawValue: persistedViewMode) ?? .list
    }

    var viewModeSelection: Binding<KGViewMode> {
        Binding(
            get: { viewMode },
            set: { persistedViewMode = $0.rawValue }
        )
    }

    var viewModeNotice: String? {
        KGViewModePickerPresentation.pickerNotice(
            requested: viewMode,
            displayedEntityCount: renderableGraphEntityCount
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

            // Kind and time-window filters apply to both view modes.
            AliveGroupCard {
                KGNativeStackHeader(
                    memory: memory,
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
                                    systemImage: knowledgeGraphTypeSymbols[kind] ?? "circle"
                                )
                            }
                        }
                    } label: {
                        Text(selectedKinds.isEmpty
                             ? "All kinds"
                             : selectedKinds.count == 1
                                ? selectedKinds.map { $0.capitalized }.joined()
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

                // Entity search; the kind menu owns type filtering.
                HStack(spacing: 8) {
                    NativeSearchField(text: $searchText, prompt: "Search entities…",
                                      identifier: "knowledgeGraph.search",
                                      accessibilityLabel: "Search entities")
                        .frame(maxWidth: 260)
                    Spacer()

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

            // Errors appear above retained data; only load failures mark the graph stale.
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
                // An unavailable store shows its error rather than a healthy empty state.
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
                // The 200-node limit applies only to the quadratic graph layout, never list mode.
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
        .liveTask(id: filterExpiry) {
            guard let deadline = filterExpiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            filterClockTick = Date()
        }
        .onReceive(Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged),
            NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
        ]).receive(on: RunLoop.main)) { _ in
            filterProjection.invalidate()
            filterClockTick = Date()
        }
        // Selection sync: when the active filter set drops the currently
        // selected id from `displayEntities`, clear it so the detail pane
        // doesn't keep showing a node the user can no longer see. Watch the
        // sorted id-list signature rather than the array itself — cheaper and
        // matches what the canvas keys layout on.
        .onChange(of: displayedEntitySignature) { _, _ in
            selectedId = KnowledgeGraphPresentation.reconciledSelection(selectedId, visibleIDs: displayedEntityIDs)
        }
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
        // The split fills available height to keep rows from collapsing against the footer.
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

extension KnowledgeGraphView {
    func loadGraph() async {
        guard !Task.isCancelled else { return }
        // Each load clears the previous error before refreshing.
        errorMsg = nil
        errorOrigin = nil
        // The shared graph retains data on failed reads and presents the error above it.
        await memory.loadGraph()
        guard !Task.isCancelled, memory.graphLoadError == nil else { return }
        await memory.refreshDiagnostics()
    }
}
