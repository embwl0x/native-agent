import SwiftUI
import MemoryV2
import PersistenceCore

/// One app-owned task survives navigation; both status surfaces observe Core's push stream.
@MainActor @Observable
final class EmbeddingModelDownloadController {
    static let shared = EmbeddingModelDownloadController()
    var status = EmbeddingModelDownload.Status()
    var activating = false
    private var lastDoctorInstallCompleted = false
    private var installCommitted = false
    private let downloader = EmbeddingModelDownload(dataRoot: PersistenceCore.defaultDataRoot())
    private var task: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    func start(createOnly: Bool = true, reconcile: Bool = false) {
        guard task == nil, pauseTask == nil else { return }
        lastDoctorInstallCompleted = false
        installCommitted = false
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
                if createOnly, await downloader.isUserPaused() { return }
                if !createOnly { try await downloader.resumeByUser() }
                if try await downloader.install(createOnly: createOnly) {
                    installCommitted = true
                    activating = true
                    // Once the verified directory has committed, a late Pause must
                    // not cancel corpus convergence and strand two vector spaces.
                    let converged = reconcile ? await Task.detached(priority: .utility) {
                        _ = await SwiftNativeMemoryV2.shared.releaseEmbeddingMemory(reason: "verified model installed")
                        return await reconcileMemoryEmbeddingEpochAtLaunch()
                    }.value : true
                    activating = false
                    lastDoctorInstallCompleted = converged
                }
            } catch { /* Core publishes the failure and retains resumable parts. */ }
        }
    }

    func cancel() {
        guard let active = task, pauseTask == nil else { return }
        active.cancel()
        pauseTask = Task {
            await active.value
            if !installCommitted { try? await downloader.pauseByUser() }
            pauseTask = nil
        }
    }

    func doctorSnapshot() async -> EmbeddingModelDownload.Status {
        await downloader.currentStatus()
    }

    func doctorUserPaused() async -> Bool { await downloader.isUserPaused() }

    /// Doctor joins the same owner task used by the two visible rows.
    func resumeForDoctor(reconcile: Bool) async -> Bool {
        guard task == nil else { return false }
        start(reconcile: reconcile)
        await task?.value
        return lastDoctorInstallCompleted
    }
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
                Button("Check / resume") { controller.start(createOnly: false, reconcile: true) }
                    .disabled(controller.activating)
            }
        }
        .padding(8)
        }
    }
}
