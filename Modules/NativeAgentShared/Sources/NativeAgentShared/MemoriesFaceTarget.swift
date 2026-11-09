import Foundation
// Blueprint: | `MemoriesFaceTarget.swift` | `MemoriesFaceTarget`: the exact places a Memories row leads (graph, upkeep, a memory, a rejected proposal) |

/// A face carries references only; each destination re-reads its canonical record.
public enum MemoriesFaceTarget: Equatable, Sendable {
    case graph, upkeep
    case memory(String), rejected(String)

    public init?(row: String) {
        if row == "graph" { self = .graph }
        else if row == "upkeep" { self = .upkeep }
        else if row.hasPrefix("memory:"), row.count > "memory:".count { self = .memory(String(row.dropFirst("memory:".count))) }
        else if row.hasPrefix("rejected:"), row.count > "rejected:".count { self = .rejected(String(row.dropFirst("rejected:".count))) }
        else { return nil }
    }

    public var row: String {
        switch self {
        case .graph: "graph"
        case .upkeep: "upkeep"
        case .memory(let id): "memory:" + id
        case .rejected(let id): "rejected:" + id
        }
    }

    public var link: String { "page:memories/" + row }
}
