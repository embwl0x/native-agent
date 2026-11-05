import EngineRuntime
import MemoryV2
import Foundation
import SwiftUI
import Combine
import NativeAgentShared

// Blueprint: | `KnowledgeGraphView.swift` | KnowledgeGraphView: shared graph snapshot, policy, maintenance and filters |

struct KnowledgeGraphView: View {
    @Environment(AppModel.self) var appModel
    var entities: [KnowledgeGraphEntity] { memory.graphEntities }
    var edges: [KnowledgeGraphEdge] { memory.graphEdges }
    var totalEntities: Int { memory.graphTotalEntities }
    var totalEdges: Int? { memory.graphTotalEdges }
    var loading: Bool { memory.graphLoading }
    @State var errorMsg: String? = nil
    // Keep error origin with the message: only graph-load failures make retained rows stale.
    @State var errorOrigin: KnowledgeGraphPresentation.ErrorOrigin? = nil
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
    @State var selectedId: String? = nil

    /// Derive selection from current visibility so detail cannot leak a filtered-out node before onChange reconciles state.
    var selectedEntity: KnowledgeGraphEntity? {
        guard let id = KnowledgeGraphPresentation.reconciledSelection(
            selectedId,
            visibleIDs: displayedEntityIDs
        ) else { return nil }
        return displayEntities.first(where: { $0.id == id })
    }

    var displayedEntityIDs: Set<String> {
        Set(displayEntities.map(\.id))
    }

    var displayedEntitySignature: String {
        displayEntities.map(\.id).sorted().joined(separator: "|")
    }

    @AppStorage("knowledgeGraphViewMode") private var persistedViewMode = KGViewMode.list.rawValue
    @State var selectedKinds: Set<String> = []  // empty = all
    @State var timeWindow: KGTimeWindow = .all

    @State var gcRunning = false
    @State var gcStatus: String? = nil
    @State var gcCandidates: [KnowledgeGraphGCCandidate] = []
    @State var gcPreviewCandidateIDs: Set<String> = []
    @State var showGCConfirm = false

    var memory: MemoryFacade { appModel.engine.memory }

    let kindCatalog = KnowledgeGraphFilterCatalog.selectableKinds

    /// An unread policy is not an off graph; enabling requires a successful authority read.
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

    var recencyNotice: String? {
        _ = displayEntities
        let count = filterProjection.unavailableRecencyCount
        guard count > 0 else { return nil }
        return "Recency unavailable for \(count) entities (last-seen timestamp missing or invalid)." +
            (timeWindow == .all ? "" : " These entities are excluded from this time filter; choose All time to see them.")
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

            AliveGroupCard {
                KGNativeStackHeader(
                    memory: memory,
                    totalEntities: memory.graphSnapshot?.canvasEntities.count,
                    totalEdges: totalEdges
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
                    .help("Choose whether to browse the graph as a list or a graph.")
                }

                HStack(spacing: 8) {
                    NativeSearchField(text: $searchText, prompt: "Search entities…",
                                      identifier: "knowledgeGraph.search",
                                      accessibilityLabel: "Search entities")
                        .frame(maxWidth: 260)
                    Spacer()

                }
            }

            if let recencyNotice {
                Text(recencyNotice)
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
                isEnabled: knowledgeGraphEnabled,
                viewMode: viewMode,
                policyReadError: policyReadError
            ) {
            case .loading:
                AdvancedWaitingLine("Reading the knowledge graph…")
            case let .unavailable(err):
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
            case .graph:
                // Cap only the quadratic canvas layout, never the list.
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
        // Watch sorted visible ids to clear filtered-out details without comparing whole entity arrays.
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
        // Fill available height so rows cannot collapse against the footer.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectRelatedEntity(_ id: String) {
        // Recheck filters on activation so a vanished destination cannot clear the current detail.
        guard let destination = KnowledgeGraphPresentation.reconciledSelection(
            id, visibleIDs: displayedEntityIDs
        ) else { return }
        selectedId = destination
    }

}

extension KnowledgeGraphView {
    func loadGraph() async {
        guard !Task.isCancelled else { return }
        errorMsg = nil
        errorOrigin = nil
        await memory.loadGraph()
        guard !Task.isCancelled, memory.graphLoadError == nil else { return }
        await memory.refreshDiagnostics()
    }
}
