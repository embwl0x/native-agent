import Foundation
import MemoryV2
import NativeAgentShared
import SwiftUI
import AppKit
import EngineRuntime
import Combine
import Cognition
import NativeAgentCore
import PersistenceCore

// Blueprint: | `KnowledgeGraphPresentation.swift` | Graph modes, filters, cached date projection, selection and content/error presentation; retains the canvas size boundary |

// List and Graph share the same filtered entities; Graph enforces its size cap.
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

extension KnowledgeGraphView {
    /// Graph time filters accept ISO-8601 timestamps and date-only YYYY-MM-DD.
    static func parseKGDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(s) { return date }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: String(s.prefix(10)))
    }
}

enum KnowledgeGraphFilterCatalog {
    static let selectableKinds = [
        "person", "organization", "project", "concept", "place", "event", "tool", "fact",
    ]
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
    final class GraphFilter {
        private var source: [KnowledgeGraphEntity] = []
        private var dates: [Date?] = []
        private var kinds: Set<String> = []
        private var window: KGTimeWindow = .all
        private var query = ""
        private var rows: [KnowledgeGraphEntity] = []
        private var validUntil = Date.distantPast
        private var evaluatedAt = Date.distantPast
        private var calendar = Calendar.current

        var nextExpiry: Date? { validUntil == .distantFuture ? nil : validUntil }

        func invalidate() { validUntil = .distantPast }

        func entities(_ entities: [KnowledgeGraphEntity], kinds: Set<String>,
                      window: KGTimeWindow, query: String) -> [KnowledgeGraphEntity] {
            let now = Date()
            let currentCalendar = Calendar.current
            let changed = source != entities
            if !changed, self.kinds == kinds,
               self.window == window, self.query == query, calendar == currentCalendar,
               now >= evaluatedAt, now < validUntil { return rows }
            if changed {
                source = entities
                dates = entities.map {
                    KnowledgeGraphView.parseKGDate($0.lastSeen) ?? KnowledgeGraphView.parseKGDate($0.firstSeen)
                }
            }
            self.kinds = kinds
            self.window = window
            self.query = query
            calendar = currentCalendar
            evaluatedAt = now
            let cutoff = window.cutoff
            rows = zip(entities, dates).compactMap { entity, date in
                guard kinds.isEmpty || kinds.contains(entity.type),
                      cutoff.map({ boundary in date.map { $0 >= boundary } == true }) ?? true,
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
    enum ErrorOrigin: Equatable { case graphLoad, maintenance }
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

    /// A selection is valid only while its node is visible.
    static func reconciledSelection(_ selectedID: String?, visibleIDs: Set<String>) -> String? {
        guard let selectedID, visibleIDs.contains(selectedID) else { return nil }
        return selectedID
    }

}
