import Foundation
// Blueprint: | `NativeCollectionPages.swift` | Shared graph collection and item projections from canonical device or body readings |

public enum GraphCollectionFace {
    public static func list(entities: [FaceGraphEntity], total: Int?, cursor: Int = 0, revision: String,
                            page: String = "knowledge", pageSize: Int = 256, itemPrefix: String = "") throws -> PartFace {
        guard cursor >= 0, cursor <= entities.count, pageSize > 0, pageSize <= 256 else {
            throw PartCallError(code: "invalid_cursor", message: "The graph cursor or page size is outside this collection.")
        }
        let start = cursor
        let rows = entities.dropFirst(start).prefix(pageSize).map { entity in
            PartFace.Row(id: entity.id, title: entity.name, detail: entity.kind.capitalized, open: "page:" + page + "/" + itemPrefix + entity.id)
        }
        let next = start + rows.count
        let more: PartFace.More? = next < entities.count
            ? .init(next: String(next), total: total, revision: revision) : nil
        return PartFace(title: "Knowledge Graph", sections: [
            .init(id: "entities", title: "Entities", style: .list,
                  footer: total.map { "Showing \(next) of \($0) entities" }, rows: rows, more: more, filter: "Search entities…", revision: revision)
        ], detail: .init(of: "entities"))
    }

    public static func detail(entity: FaceGraphEntity, entities: [FaceGraphEntity], edges: [FaceGraphEdge],
                              state: FaceReadState, page: String = "knowledge", relationshipCursor: Int = 0,
                              revision: String? = nil, itemPrefix: String = "") throws -> PartFace {
        guard relationshipCursor >= 0, relationshipCursor <= edges.count else {
            throw PartCallError(code: "invalid_cursor", message: "The relationship cursor is outside this entity's reading.")
        }
        var facts = [PartFace.Row(id: "kind", title: "Kind", value: entity.kind.capitalized)]
        if let weight = entity.weight { facts.append(.init(id: "weight", title: "Weight", value: String(weight))) }
        if let lastSeen = entity.lastSeen {
            facts.append(.init(id: "last-seen", title: "Last seen", at: NativeTimestampFormat.fractionalZulu(lastSeen)))
        }
        let relationships: [PartFace.Row]
        let start = relationshipCursor
        switch state {
        case .ready:
            relationships = edges.isEmpty ? [.init(id: "empty", title: "No relationships recorded.", tone: .quiet)]
                : edges.enumerated().dropFirst(start).prefix(256).map { index, edge in
                    let other = edge.from == entity.id ? edge.to : edge.from
                    let named = entities.first { $0.id == other }
                    let direction = edge.from == entity.id ? "→ " : "← "
                    return .init(id: "edge:\(index)", title: named?.name ?? "Entity \(other) (name unavailable)",
                                 detail: direction + edge.kind.replacingOccurrences(of: "_", with: " "),
                                 value: edge.weight.map { String($0) }, open: named.map { "page:" + page + "/" + itemPrefix + $0.id })
                }
        case .waiting(let owner): relationships = [.init(id: "waiting", title: "Waiting on " + owner + "…", tone: .quiet)]
        case .unavailable(let failure):
            relationships = [.init(id: "unavailable", title: failure.message, detail: failure.cause, tone: .failed)]
        }
        let next = state == .ready && !edges.isEmpty ? start + relationships.count : start
        var sections = [PartFace.Section(id: "entity", style: .values, rows: facts)]
        if let summary = entity.detail {
            sections.append(.init(id: "summary", rows: [], block: .init(key: "summary:" + entity.id,
                text: summary.utf8.count <= PartFace.Block.inlineByteLimit ? summary : nil, copy: true)))
        }
        sections.append(.init(id: "relationships:" + entity.id, title: "Relationships", style: .list, rows: relationships,
            more: state == .ready && next < edges.count ? .init(next: String(next), total: edges.count, revision: revision) : nil,
            revision: revision))
        return PartFace(title: entity.name, sections: sections)
    }
}
