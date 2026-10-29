import Foundation
import SwiftUI
import CloudKit
import NativeAgentShared
// Blueprint: | `MobileSearchIndex.swift` | Actor-owned local row search shared by memory, tools and knowledge graph |

struct MobileSearchInput<Row: Equatable & Sendable>: Equatable, Sendable {
    let rows: [Row]
    let query: String
}

actor MobileSearchIndex<Row: Equatable & Sendable> {
    private var source: [Row] = []
    private var searchable: [[String]] = []

    func search(_ input: MobileSearchInput<Row>, maximum: Int,
                fields: @Sendable (Row) -> [String],
                matches: @Sendable (String, String) -> Bool) -> [Row] {
        if source != input.rows {
            source = input.rows
            searchable = source.map(fields)
        }
        guard !input.query.isEmpty else { return Array(source.prefix(maximum)) }
        var result: [Row] = []
        for (row, text) in zip(source, searchable) {
            if Task.isCancelled { return [] }
            if text.contains(where: { matches($0, input.query) }) {
                result.append(row)
                if result.count == maximum { break }
            }
        }
        return result
    }
}
