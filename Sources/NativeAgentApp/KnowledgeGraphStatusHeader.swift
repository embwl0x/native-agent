// PATCH-2026-05-07: kg-1 KnowledgeGraphView — Memory > Graph sub-section.
// Shows entity list + edges. Simple adjacency list layout (no external libs).
import SwiftUI
import KnowledgeGraph
import PersistenceCore
#if canImport(CloudKit)
import CloudKit

// The header receives entity/edge counts from the canonical checked graph read.
// It must never substitute MemoryV2 row count or legacy JSON mtime for graph
// truth once memory.sqlite is authoritative.
public struct KGNativeStackStatus: Equatable, Sendable {
    public var sqliteEntities: Int
    public var embeddingDim: Int
    public var spotlightIndexed: Int
    public var cloudKitState: String
    public var lastUpdated: Date?
    public static let empty = KGNativeStackStatus(
        sqliteEntities: 0, embeddingDim: 0, spotlightIndexed: 0,
        cloudKitState: "unknown", lastUpdated: nil
    )

    /// Read-only probe of the apple-native stack. Mirrors the
    /// `MemoryV2NativeStackSnapshot.load()` pattern in ContentView (same data
    /// root, same SQLite store, same Spotlight sentinel) but scoped to the KG
    /// view's compact header.
    @MainActor
    public static func load(graphCounts: (entities: Int, edges: Int)) async -> KGNativeStackStatus {
        let dataRoot = PersistenceCore.defaultDataRoot()
        var status = KGNativeStackStatus.empty
        status.embeddingDim = 384

        status.sqliteEntities = graphCounts.entities
        let spotMarker = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".spotlight_reindexed", isDirectory: false)
        if FileManager.default.fileExists(atPath: spotMarker.path) {
            status.spotlightIndexed = status.sqliteEntities
        }
        // CloudKit account probe — disabled by default because CKContainer
        // traps synchronously when the provisioning profile lacks the CloudKit
        // service grant.
        if nativeAgentCloudKitAccountProbeEnabled() {
            status.cloudKitState = await withCKTimeout("KGNativeStackStatus.cloudKitAccount") {
                let s = try await CKContainer.default().accountStatus()
                switch s {
                case .available: return "available"
                case .noAccount: return "noAccount"
                case .restricted: return "restricted"
                case .temporarilyUnavailable: return "temporarilyUnavailable"
                case .couldNotDetermine: return "unknown"
                @unknown default: return "unknown"
                }
            } ?? "timeout"
        } else {
            status.cloudKitState = nativeAgentCloudKitDisabledStatus
        }
        let sqlitePath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sqlitePath.path),
           let mtime = attrs[.modificationDate] as? Date {
            status.lastUpdated = mtime
        }
        return status
    }
}

struct KGNativeStackHeader: View {
    let status: KGNativeStackStatus
    let totalEntities: Int
    let totalEdges: Int
    var body: some View {
        HStack(spacing: 12) {
            Text("\(totalEntities) entities").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(.tertiary)
            Text("\(totalEdges) relationships").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(.tertiary)
            Text("last-updated \(Self.relative(status.lastUpdated))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Label("\(status.sqliteEntities) SQLite", systemImage: "cylinder.split.1x2").font(.caption2)
            Label("\(status.embeddingDim)d MiniLM", systemImage: "cpu").font(.caption2)
            Label(status.cloudKitState, systemImage: "icloud").font(.caption2)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    private static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#endif
