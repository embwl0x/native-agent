import SwiftUI
import MemoryV2
import PersistenceCore

/// One app-owned task survives navigation; both status surfaces observe Core's push stream.
@MainActor @Observable
final class EmbeddingModelDownloadController {
    static let shared = EmbeddingModelDownloadController()
    var status = EmbeddingModelDownload.Status()
    var activating = false
    private let downloader = EmbeddingModelDownload(dataRoot: PersistenceCore.defaultDataRoot())
    private var task: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        if observation == nil {
            observation = Task {
                for await value in await downloader.updates() { status = value }
            }
        }
        task = Task {
            defer { task = nil }
            guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot(),
                  runtime.requestedBackend != ManagedEmbeddingProvider.mockBackend else { return }
            do {
                if try await downloader.install() {
                    activating = true
                    // Once the verified directory has committed, a late Pause must
                    // not cancel corpus convergence and strand two vector spaces.
                    await Task.detached(priority: .utility) {
                        _ = await SwiftNativeMemoryV2.shared.releaseEmbeddingMemory(reason: "verified model installed")
                        await reconcileMemoryEmbeddingEpochAtLaunch()
                    }.value
                    activating = false
                }
            } catch { /* Core publishes the failure and retains resumable parts. */ }
        }
    }

    func cancel() { task?.cancel() }
}

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
                Button("Check / resume") { controller.start() }
                    .disabled(controller.activating)
            }
        }
        .padding(8)
        }
    }
}
