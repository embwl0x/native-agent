// PATCH-2026-05-07: kg-1 KnowledgeGraphView — Memory > Graph sub-section.
// Shows entity list + edges. Simple adjacency list layout (no external libs).
import SwiftUI
import MemoryV2
import KnowledgeGraph
import PersistenceCore
#if canImport(CloudKit)
import CloudKit
import DeviceSync

// The header receives entity/edge counts from the canonical checked graph read.
// It must never substitute MemoryV2 row count or legacy JSON mtime for graph
// truth once memory.sqlite is authoritative.
public struct KGNativeStackStatus: Equatable, Sendable {
    public var sqliteEntities: Int
    public var embeddingDim: Int
    public var cloudKitState: String
    public var lastChecked: Date?
    public static let empty = KGNativeStackStatus(
        sqliteEntities: 0, embeddingDim: 0,
        cloudKitState: "unknown", lastChecked: nil
    )

    public static func load(entityCount: Int) async -> KGNativeStackStatus {
        var status = KGNativeStackStatus.empty
        status.lastChecked = Date()
        let snapshot = await MemoryV2NativeStackSnapshot.load()
        status.sqliteEntities = entityCount
        status.embeddingDim = snapshot.runtimeEmbedderDimensions ?? 0
        status.cloudKitState = snapshot.cloudKitAccountStatus
        return status
    }

}

struct KGNativeStackHeader: View {
    let status: KGNativeStackStatus
    let totalEntities: Int
    let totalEdges: Int
    var body: some View {
        // A row inside the alive group card: no material strip of its own,
        // and shell inks (the system tertiary fails on the haze).
        HStack(spacing: 12) {
            Text("\(totalEntities) entities").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(NativeAgentShell.secondary)
            Text("\(totalEdges) relationships").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(NativeAgentShell.secondary)
            Text("Last checked \(Self.relative(status.lastChecked))").font(.caption).foregroundStyle(NativeAgentShell.secondary)
            Spacer()
            Group {
                Label("\(status.sqliteEntities) SQLite", systemImage: "cylinder.split.1x2")
                Label("\(status.embeddingDim)d vectors", systemImage: "cpu")
                Label(status.cloudKitState, systemImage: "icloud")
            }
            .font(.caption2)
            .foregroundStyle(NativeAgentShell.secondary)
        }
        .foregroundStyle(NativeAgentShell.text)
    }
    private static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#endif
