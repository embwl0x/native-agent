import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `KnowledgeGraphPresentation.swift` | Local graph view and recency choices; canvas edge drawing identity |

enum KGViewMode: String, CaseIterable, Identifiable {
    case list = "List", graph = "Graph"
    var id: String { rawValue }
}

enum KGTimeWindow: String, CaseIterable, Identifiable {
    case all = "All time", day = "Last day", week = "Last week", month = "Last month"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .all: nil
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }

    func cutoff(at date: Date) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: date)
    }
}

enum KnowledgeGraphFilterCatalog {
    static let selectableKinds = ["person", "organization", "project", "concept", "place", "event", "tool", "fact"]
}

extension FaceGraphEdge {
    var drawingID: String {
        [from, to, kind].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
