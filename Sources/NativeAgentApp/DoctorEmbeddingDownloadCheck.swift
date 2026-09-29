import Foundation
import DoctorChecks
import MemoryV2
import PersistenceCore

@MainActor
enum DoctorEmbeddingDownloadCheck {
    static let id = "live.embedding_download"
    static let title = "Memory model download"

    static func read(dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> CheckResult {
        guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else {
            return CheckResult(id: id, title: title, status: "warn",
                               detail: "The embedding runtime is unavailable, so the need for a model download cannot be checked.",
                               human_action: "Restart NativeAgent, then run Doctor again to check the memory model download.")
        }
        guard runtime.requestedBackend != ManagedEmbeddingProvider.mockBackend else {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "A separate memory model download is not required by the current embedding mode.")
        }
        guard let url = Bundle.main.url(forResource: "embedding-download", withExtension: "json") else {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "No separate download is configured; the bundled model is checked by Core ML Embedder.")
        }
        guard let length = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              length <= 8_192,
              let data = try? Data(contentsOf: url),
              let descriptor = try? EmbeddingModelDownload.Descriptor.parse(data) else {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "The bundled memory model download descriptor is unreadable or invalid.",
                               human_action: "Reinstall NativeAgent to restore embedding-download.json in the app bundle.")
        }
        guard descriptor.distribution == "separate-download" else {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "The model is bundled; no separate transfer is required.")
        }
        let target = dataRoot.appendingPathComponent("extras/coreml")
        // Installed means the current release: the owner stamps release.sha256 on install.
        let installedRelease = (try? String(contentsOf: target.appendingPathComponent("release.sha256"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.fileExists(atPath: target.path), installedRelease == descriptor.sha256 {
            do {
                let state = try await SwiftNativeMemoryV2.shared.memoryEmbeddingEpochState()
                guard let epoch = await SwiftNativeMemoryV2.shared.embeddingEpoch() else {
                    return CheckResult(id: id, title: title, status: "warn",
                                       detail: "The installed memory model's embedding epoch is unavailable.",
                                       human_action: "Restart NativeAgent, then run Doctor again to check memory search.")
                }
                if state.activeEpoch != epoch.rawValue {
                    return CheckResult(id: id, title: title, status: "warn",
                                       detail: "The installed memory model and memory search have different embedding epochs.",
                                       human_action: "Open Diagnostics → Doctor and press Repair to retry memory search reconciliation.")
                }
            } catch {
                return CheckResult(id: id, title: title, status: "warn",
                                   detail: "The installed memory model's memory search epoch could not be checked: \(error.localizedDescription)",
                                   human_action: "Restart NativeAgent, then run Doctor again to check memory search.")
            }
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "An installed model is present and memory search uses its embedding epoch; Core ML Embedder checks loadability.")
        }
        let download = await EmbeddingModelDownloadController.shared.doctorSnapshot()
        let phase = download.phase
        if download.running {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "The memory model transfer is running: \(phase).")
        }
        let work = dataRoot.appendingPathComponent("extras/.coreml-download/\(descriptor.sha256)")
        if FileManager.default.fileExists(atPath: work.appendingPathComponent("invalid-parts").path) {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "The saved memory model parts failed the release digest check and were preserved.",
                               human_action: "Open Diagnostics and report the digest mismatch to support; keep data/extras/.coreml-download unchanged.")
        }
        let userPaused = await EmbeddingModelDownloadController.shared.doctorUserPaused()
        if phase == "Download paused" || userPaused {
            return CheckResult(id: id, title: title, status: "ok",
                               detail: "The memory model transfer was paused by the user.")
        }
        let ranges = EmbeddingModelDownload.ranges(size: descriptor.byteLength)
        var bytes: Int64 = 0
        var invalid = false
        for (index, range) in ranges.enumerated() {
            let part = work.appendingPathComponent("part-\(index)")
            guard FileManager.default.fileExists(atPath: part.path) else { continue }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value,
                  size > 0, size <= range.count else { invalid = true; break }
            bytes += size
        }
        if invalid {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "A saved memory model part has an invalid byte length; the transfer cannot be resumed safely.",
                               human_action: "Open Diagnostics and report the memory model download failure to support; keep data/extras/.coreml-download unchanged.")
        }
        if bytes > 0, bytes < descriptor.byteLength {
            return CheckResult(id: id, title: title, status: "warn",
                               detail: "A resumable memory model transfer has \(bytes) of \(descriptor.byteLength) bytes saved; the owner will verify the final digest before installation.",
                               human_action: "Open Diagnostics → Doctor and press Repair to resume the saved transfer.")
        }
        if bytes == descriptor.byteLength {
            return CheckResult(id: id, title: title, status: "warn",
                               detail: "The memory model archive is fully downloaded but has not been installed. \(phase).",
                               human_action: "Open Diagnostics and choose Check / resume on the Memory model download row to verify and install it.")
        }
        return CheckResult(id: id, title: title, status: "warn",
                           detail: "The required separate memory model has not been downloaded. \(phase).",
                           human_action: "Open Diagnostics and choose Check / resume on the Memory model download row.")
    }

    static func repair(dataRoot: URL = PersistenceCore.defaultDataRoot(), scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
        let before = await read(dataRoot: dataRoot)
        if before.status == "warn", before.detail == "The installed memory model and memory search have different embedding epochs." {
            guard case .button = scope else { return nil }
            return DoctorExecutableRepair(checkID: id) {
                let current = await read(dataRoot: dataRoot)
                guard current.status == "warn", current.detail == before.detail else {
                    return .unverified("Repair skipped: the memory search epoch changed.")
                }
                return await reconcileMemoryEmbeddingEpochAtLaunch()
                    ? .completed("Completed: memory search now uses the installed model's embedding epoch.")
                    : .unverified("Memory search reconciliation did not complete; the prior corpus was retained.")
            }
        }
        guard before.status == "warn", before.detail.hasPrefix("A resumable memory model transfer") else { return nil }
        return DoctorExecutableRepair(checkID: id) {
            let current = await read(dataRoot: dataRoot)
            guard current.status == "warn", current.detail.hasPrefix("A resumable memory model transfer") else {
                return .unverified("Repair skipped: the transfer state changed.")
            }
            let reconcile: Bool
            if case .button = scope { reconcile = true } else { reconcile = false }
            let completed = await EmbeddingModelDownloadController.shared.resumeForDoctor(reconcile: reconcile)
            return completed
                ? .completed(reconcile
                    ? "Completed: resumed the verified-range transfer and reconciled memory search."
                    : "Completed: resumed the verified-range transfer and installed the memory model.")
                : .unverified("Resume did not complete; the download owner retained its saved parts and reported the current phase.")
        }
    }
}
