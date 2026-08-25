import Foundation

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

    static func load(from defaults: UserDefaults) -> KGViewMode {
        resolve(persistedValue: defaults.string(forKey: key))
    }

    static func save(_ mode: KGViewMode, in defaults: UserDefaults) {
        defaults.set(persistedValue(for: mode), forKey: key)
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

    func selecting(_ mode: KGViewMode) -> Self {
        Self(persistedValue: mode.rawValue)
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
    enum Content: Equatable { case loading, unavailable(String), policyUnavailable, policyUnreadable(String), disabled, empty, filteredEmpty, list, graph, graphSafetyNet(count: Int) }
    enum ErrorPlacement: Equatable { case none, emptyState(String), retainedDataBanner(message: String, isStale: Bool) }
    /// Error provenance is retained with the message so the mounted banner
    /// never labels a maintenance-action error as stale graph data.  A boolean
    /// from an earlier load attempt is insufficient: a later GC failure can
    /// replace the visible message while retained graph rows are still current.
    enum ErrorOrigin: Equatable { case graphLoad, policyAction, maintenance }
    enum Relationships: Equatable { case loading, failed(String), notLoaded, none, loaded(count: Int) }
    enum EntityDetailRelationships: Equatable {
        case loading
        case failed(String)
        case notLoaded
        case none
        case loaded(count: Int)
        case partial(visibleCount: Int, omittedUnrelatedCount: Int)
    }

    static func filteredEntities(_ entities: [KGEntity], filterType: String, selectedKinds: Set<String>, cutoff: Date?, query: String) -> [KGEntity] {
        entities.filter { entity in
            guard (filterType == "all" || entity.type == filterType),
                  (selectedKinds.isEmpty || selectedKinds.contains(entity.type)) else { return false }
            if let cutoff {
                guard let stamp = KnowledgeGraphView.parseKGDate(entity.last_seen)
                    ?? KnowledgeGraphView.parseKGDate(entity.first_seen), stamp >= cutoff else { return false }
            }
            return query.isEmpty || entity.name.localizedCaseInsensitiveContains(query)
                || (entity.summary ?? "").localizedCaseInsensitiveContains(query)
        }
    }

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

    static func relationships(isLoading: Bool, error: String?, edgeCount: Int?) -> Relationships {
        if isLoading { return .loading }
        if let error { return .failed(error) }
        guard let edgeCount else { return .notLoaded }
        return edgeCount == 0 ? .none : .loaded(count: edgeCount)
    }

    /// A detail response must only render edges connected to the entity whose
    /// pane is open. Corrupt or stale rows for another root are evidence of an
    /// incomplete response, never a relationship of the selected entity.
    static func visibleRelationshipEdges(
        rootID: String,
        response: KGNeighborsResponse?
    ) -> [KGEdge] {
        (response?.edges ?? []).filter { $0.from == rootID || $0.to == rootID }
    }

    static func entityDetailRelationships(
        isLoading: Bool,
        error: String?,
        rootID: String,
        response: KGNeighborsResponse?
    ) -> EntityDetailRelationships {
        if isLoading { return .loading }
        if let error {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "Relationship details could not be loaded." : detail)
        }
        guard let response else { return .notLoaded }
        let visible = visibleRelationshipEdges(rootID: rootID, response: response)
        let omitted = response.edges.count - visible.count
        if omitted > 0 {
            return .partial(visibleCount: visible.count, omittedUnrelatedCount: omitted)
        }
        return visible.isEmpty ? .none : .loaded(count: visible.count)
    }
}
