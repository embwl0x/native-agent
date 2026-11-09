import SwiftUI
import NativeAgentShared
// Blueprint: | `EmbeddingModelDownloadRow.swift` | `EmbeddingModelDownloadRow` struct |

struct EmbeddingModelDownloadRow: View {
    @Environment(AppModel.self) private var appModel

    private var download: EmbeddingDownloadFace? {
        appModel.face.slot(.counts).select("download", as: CountsFace.self) { $0?.statuses.download }
    }

    var body: some View {
        if let download, download.status.available {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text(download.activating ? "Updating memory search…" : download.status.phase)
                    .font(.caption)
                if download.status.running, download.status.total > 0 {
                    ProgressView(value: Double(download.status.completed), total: Double(download.status.total))
                    Text("""
                        \(ByteCountFormatter.string(fromByteCount: download.status.completed, countStyle: .file)) of \
                        \(ByteCountFormatter.string(fromByteCount: download.status.total, countStyle: .file))
                        """)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if download.status.running {
                Button("Pause") { command(.pause) }
            } else {
                Button("Check / resume") { command(.resume) }
                    .disabled(download.activating)
            }
        }
        .padding(8)
        }
    }

    private func command(_ command: DownloadCommand) {
        Task {
            do { try await appModel.client.act(.setEmbeddingDownload(command)).checkedAcknowledgement() }
            catch { appModel.systemToasts.push(error: error.localizedDescription) }
        }
    }
}
