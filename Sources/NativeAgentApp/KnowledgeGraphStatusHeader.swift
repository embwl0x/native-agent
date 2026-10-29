import SwiftUI
import MemoryV2
import PersistenceCore
#if canImport(CloudKit)
import CloudKit
import DeviceSync
// Blueprint: | `KnowledgeGraphStatusHeader.swift` | `KGNativeStackHeader`: renders the engine memory diagnostics and graph counts |

// The header receives entity/edge counts from the canonical checked graph read.
// It must never substitute MemoryV2 row count or legacy JSON mtime for graph
// truth once memory.sqlite is authoritative.
struct KGNativeStackHeader: View {
    let memory: MemoryFacade
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
            Text("Last checked \(Self.relative(memory.diagnosticsCheckedAt))").font(.caption).foregroundStyle(NativeAgentShell.secondary)
            Spacer()
            Group {
                Label("\(totalEntities) SQLite", systemImage: "cylinder.split.1x2")
                Label("\(memory.diagnostics.runtimeEmbedderDimensions ?? 0)d vectors", systemImage: "cpu")
                Label(memory.diagnostics.cloudKitAccountStatus, systemImage: "icloud")
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
