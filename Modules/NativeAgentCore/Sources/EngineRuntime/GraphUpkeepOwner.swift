import Foundation
import MemoryV2
import NativeAgentShared
import Privacy
// Blueprint: | `GraphUpkeepOwner.swift` | One owner holds reviewed orphan identities and consumes their Apply token exactly once |

public actor GraphUpkeepOwner {
    private let dataRoot: URL
    private var reviewed: (request: UUID, token: String, candidates: [KnowledgeGraphGCCandidate])?
    public init(dataRoot: URL) { self.dataRoot = dataRoot }

    private func preview(request: UUID) async throws -> (request: UUID, token: String, candidates: [KnowledgeGraphGCCandidate]) {
        let report = try await KnowledgeGraphMaintenanceActions(dataRoot: dataRoot).previewOrphanSweep()
        let token = UUID().uuidString
        reviewed = (request, token, report.candidates)
        return (request, token, report.candidates)
    }

    public func review(request: FaceReadRequest) async throws -> PartFace {
        let preview: (request: UUID, token: String, candidates: [KnowledgeGraphGCCandidate])
        let opening = request.key == "upkeep" && request.cursor == nil && request.revision == nil
        if let reviewed, !opening || reviewed.request == request.id { preview = reviewed }
        else { preview = try await self.preview(request: request.id) }
        let ids = preview.candidates.map(\.id)
        let cursor: Int
        if let raw = request.cursor {
            guard request.revision == preview.token, let offset = Int(raw), offset >= 0, offset <= ids.count else {
                throw PartCallError(code: "collection_changed", message: "This upkeep review changed. Open its current candidates again.")
            }
            cursor = offset
        } else if let anchor = request.anchor, let index = ids.firstIndex(of: anchor) { cursor = index }
        else { cursor = 0 }
        let rows = preview.candidates.dropFirst(cursor).prefix(256).map {
            PartFace.Row(id: $0.id, title: NativeAppSecretRedactor.redactText($0.name))
        }
        let next = cursor + rows.count
        let call = PartFace.Call("graph.apply", ["previewToken": .string(preview.token), "expectedIDs": .array(ids.map(PartFace.Value.string))])
        var sections = [PartFace.Section(id: "upkeep-candidates", title: "Reviewed orphaned entities", style: .list,
            footer: "Showing \(next) of \(ids.count) reviewed candidates", rows: rows,
            more: next < ids.count ? .init(next: String(next), total: ids.count, revision: preview.token,
                read: .init("graph.upkeep")) : nil, revision: preview.token)]
        sections.append(.init(id: "review", style: .list, rows: [
            .init(id: "apply", title: ids.isEmpty ? "No orphaned entities." : "Remove \(ids.count) reviewed entities",
                actions: ids.isEmpty ? nil : [.init(id: "apply", label: "Delete reviewed entities", role: .destructive, call: call)])
        ]))
        return PartFace(title: "Graph upkeep", line: "Nothing is removed until you apply this review.", sections: sections)
    }

    public func apply(expectedIDs: [String], token: String) async throws -> String {
        guard let reviewed, reviewed.token == token, Set(reviewed.candidates.map(\.id)) == Set(expectedIDs),
              reviewed.candidates.count == expectedIDs.count else {
            throw PartCallError(code: "graph_preview_unavailable", message: "Review the orphan candidates again before removing them.")
        }
        guard !reviewed.candidates.isEmpty else {
            throw PartCallError(code: "graph_review_empty", message: "This review contains no entities to remove.")
        }
        self.reviewed = nil
        switch try await KnowledgeGraphMaintenanceActions(dataRoot: dataRoot).applyOrphanSweep(
            expectedCandidateIDs: Set(reviewed.candidates.map(\.id))) {
        case .applied(let report): return "Removed \(report.entitiesDeleted) entities · \(report.edgesDeleted) edges."
        case .previewDiverged:
            throw PartCallError(code: "graph_preview_changed", message: "The orphan set changed. Review it again before confirming deletion.")
        }
    }
}
