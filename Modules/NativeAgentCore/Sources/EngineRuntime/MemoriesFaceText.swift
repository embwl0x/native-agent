import Foundation
import MemoryV2
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MemoriesFaceText.swift` | Memory face wording, ordering and exact row-link destinations |

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

enum MemoriesFaceText {
    static func memoryRow(_ memory: MemoryV2.MemoryRecord, root: URL) -> PartFace.Row {
        let pinned = memory.pinned == true
        var meta: [String] = []
        if let warning = MemorySenseProvenance.warning(in: memory.extras) { meta.append(warning) }
        if pinned { meta.append("Pinned") }
        if MemoryLifecycle.normalized(memory.lifecycle) == MemoryLifecycle.graduated { meta.append("graduated → GROWTH") }
        if stamp(memory).flatMap(UserDisplayFormatters.parseISOTimestamp) == nil { meta.append("when, I'm not sure") }
        meta.append(MemoryDataProvenance.presentation(provenance(memory.sourceRunId), metadata: memory.extras, dataRoot: root))
        let excerpt = TodayWords.line(memory.text, limit: 96)
        return .init(id: "memory:" + memory.id, title: excerpt.isEmpty ? "An empty note" : excerpt,
                     detail: meta.joined(separator: " · "), at: stamp(memory), symbol: pinned ? "pin.fill" : nil,
                     open: MemoriesFaceTarget.memory(memory.id).link,
                     actions: [.init(id: pinned ? "unpin" : "pin", label: pinned ? "Unpin" : "Pin to the top"),
                               .init(id: "forget", label: "Forget this…", role: .destructive)])
    }

    static func ordered(_ memories: [MemoryV2.MemoryRecord]) -> [MemoryV2.MemoryRecord] {
        memories.map { memory in
            let updated = memory.updatedAt.flatMap { UserDisplayFormatters.parseISOTimestamp($0) }
            let created = UserDisplayFormatters.parseISOTimestamp(memory.createdAt)
            return (memory, updated ?? created ?? .distantPast)
        }.sorted { lhs, rhs in
            if (lhs.0.pinned == true) != (rhs.0.pinned == true) { return lhs.0.pinned == true }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.id < rhs.0.id
        }.map(\.0)
    }

    static func stamp(_ memory: MemoryV2.MemoryRecord) -> String? {
        if let updated = memory.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !updated.isEmpty { return updated }
        return memory.createdAt
    }

    static func proposalKind(_ proposal: ProposalRecord) -> String {
        proposal.metadata?.objectValue?["kind"]?.stringValue == "correction" ? "Correction" : "Fact"
    }

    static func issue(_ id: String, title: String, error: Error) -> PartFace.Section {
        .init(id: id + "-error", style: .list, rows: [
            .init(id: id + "-error", title: title, detail: error.localizedDescription, tone: .failed)
        ])
    }

    private static func provenance(_ source: String?) -> String {
        let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw == "manual" || raw == "user" { return "Shared by you" }
        if raw.hasPrefix("chat.commit_memory") || raw.hasPrefix("commit_memory") { return "I wrote it down myself" }
        if raw.hasPrefix(MemoryMoments.sourcePrefix) { return "I kept it from something that happened" }
        if raw.hasPrefix("adaptive-promoter") || raw.hasPrefix("semantic-adaptive-extractor") { return "I picked it up while we talked" }
        if raw.hasPrefix("consolidat") || raw.hasPrefix("hygiene") { return "I tidied it up from older notes" }
        return "I don't remember where this came from"
    }
}
