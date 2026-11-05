import SwiftUI
import MemoryV2
import PersistenceCore
#if canImport(CloudKit)
import CloudKit
import DeviceSync
// Blueprint: | `KnowledgeGraphStatusHeader.swift` | `KGNativeStackHeader`: renders the engine memory diagnostics and graph counts |

// Only the canonical checked graph read establishes entity/edge counts; other memory counts and file timestamps are not graph evidence.
struct KGNativeStackHeader: View {
    let memory: MemoryFacade
    let totalEntities: Int?
    let totalEdges: Int?
    var body: some View {
        HStack(spacing: 12) {
            Text(totalEntities.map { "\($0) entities" } ?? "Entities unavailable").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(NativeAgentShell.secondary)
            Text(totalEdges.map { "\($0) relationships" } ?? "Relationships unavailable").font(.caption.weight(.semibold))
            Text("·").foregroundStyle(NativeAgentShell.secondary)
            Text("Last checked \(Self.relative(memory.diagnosticsCheckedAt))").font(.caption).foregroundStyle(NativeAgentShell.secondary)
            Spacer()
            Group {
                Label(totalEntities.map { "\($0) SQLite" } ?? "SQLite count unavailable", systemImage: "cylinder.split.1x2")
                Label(memory.diagnostics.runtimeEmbedderDimensions.map { "\($0)d vectors" } ?? "Vector dimensions unavailable", systemImage: "cpu")
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
