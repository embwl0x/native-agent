import SwiftUI
import MemoryV2

struct EmbeddingModelDownloadRow: View {
    @State private var controller = EmbeddingModelDownloadController.shared

    var body: some View {
        if controller.status.available {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.activating ? "Updating memory search…" : controller.status.phase)
                    .font(.caption)
                if controller.status.running, controller.status.total > 0 {
                    ProgressView(value: Double(controller.status.completed), total: Double(controller.status.total))
                    Text("\(ByteCountFormatter.string(fromByteCount: controller.status.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: controller.status.total, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.status.running {
                Button("Pause") { controller.cancel() }
            } else {
                Button("Check / resume") { controller.start(createOnly: false, reconcile: true) }
                    .disabled(controller.activating)
            }
        }
        .padding(8)
        }
    }
}
