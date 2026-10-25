import Foundation
import DoctorChecks
import MemoryV2
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DoctorEmbeddingDownloadCheck.swift` | `DoctorEmbeddingDownloadCheck` enum; embedding download health `read`, `repair` |

@MainActor
public enum DoctorEmbeddingDownloadCheck {
    public static let id = "live.embedding_download"
    public static let title = "Memory model download"

    public static func read(dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> CheckResult {
        guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "unmeasured",
                               detail: "The embedding runtime is unavailable, so the need for a model download cannot be checked.",
                               human_action: "Restart NativeAgent, then run Doctor again to check the memory model download.")
        }
        guard runtime.requestedBackend != ManagedEmbeddingProvider.mockBackend else {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "not needed",
                               detail: "A separate memory model download is not required by the current embedding mode.")
        }
        guard let url = Bundle.main.url(forResource: "embedding-download", withExtension: "json") else {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "not needed",
                               detail: "No separate download is configured; the bundled model is checked by Core ML Embedder.")
        }
        guard let length = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              length <= 8_192,
              let data = try? Data(contentsOf: url),
              let descriptor = try? EmbeddingModelDownload.Descriptor.parse(data) else {
            return CheckResult(source: "NativeAgent.app/Contents/Resources/embedding-download.json", id: id, title: title, status: "fail",
                               detail: "The bundled memory model download descriptor is unreadable or invalid.",
                               harm: "The required memory model cannot be downloaded.",
                               human_action: "Tell the person: this copy of NativeAgent has an unreadable or invalid embedding-download.json; preserve the reported descriptor error.", owner: .builder)
        }
        guard descriptor.distribution == "separate-download" else {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "not needed",
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
                    return CheckResult(source: "extras/coreml and memory/memory.sqlite: embedding epoch", id: id, title: title, status: "unmeasured",
                                       detail: "The installed memory model's embedding epoch is unavailable.")
                }
                if state.activeEpoch != epoch.rawValue {
                    return CheckResult(source: "extras/coreml and memory/memory.sqlite: embedding epoch", id: id, title: title, status: "warn",
                                       detail: "The installed memory model and memory search have different embedding epochs.",
                                       harm: "She cannot reliably find memories using the installed model.",
                                       human_action: "Press Repair in Diagnostics → Health checks to retry memory search reconciliation.", repair_available: true)
                }
            } catch {
                return CheckResult(source: "extras/coreml and memory/memory.sqlite: embedding epoch", id: id, title: title, status: "unmeasured",
                                   detail: "The installed memory model's memory search epoch could not be checked: \(error.localizedDescription)")
            }
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "ok",
                               detail: "An installed model is present and memory search uses its embedding epoch; Core ML Embedder checks loadability.")
        }
        let download = await EmbeddingModelDownloadController.shared.doctorSnapshot()
        let phase = download.phase
        if download.running {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "ok",
                               detail: "The memory model transfer is running: \(phase).")
        }
        let work = dataRoot.appendingPathComponent("extras/.coreml-download/\(descriptor.sha256)")
        if FileManager.default.fileExists(atPath: work.appendingPathComponent("invalid-parts").path) {
            return CheckResult(source: "extras/.coreml-download/\(descriptor.sha256)",
                               id: id, title: title, status: "fail",
                               detail: "The saved memory model parts failed the release digest check and were preserved.",
                               harm: "The required memory model cannot be installed from these saved parts.",
                               human_action: ToolFailureError.fileRepairInstruction(work,
                                   shape:
                                   "These downloaded memory model parts failed the release digest and the download refuses them while they sit here. "
                                   + "Move this whole directory intact to a sibling recovery name, never deleting a part, so app embeddings.resume downloads the release model again."))
        }
        let userPaused = await EmbeddingModelDownloadController.shared.doctorUserPaused()
        if phase == "Download paused" || userPaused {
            return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "off",
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
            return CheckResult(source: "extras/.coreml-download/\(descriptor.sha256)",
                               nextCall: ToolFailureError.call("app", ["action": .string("embeddings.resume"), "args": .object([:])]),
                               id: id, title: title, status: "fail",
                               detail: "A saved memory model part has an invalid byte length; the download owner must reacquire it before installation.",
                               harm: "The required memory model cannot be installed from these saved parts.")
        }
        if bytes > 0, bytes < descriptor.byteLength {
            return CheckResult(source: "extras/.coreml-download/\(descriptor.sha256)", id: id, title: title, status: "warn",
                               detail: "A resumable memory model transfer has \(bytes) of \(descriptor.byteLength) bytes saved; the owner will verify the final digest before installation.",
                               harm: "Memory search cannot use the required model until its transfer finishes.",
                               human_action: "Press Repair in Diagnostics → Health checks to resume the saved transfer.", repair_available: true)
        }
        if bytes == descriptor.byteLength {
            return CheckResult(source: "extras/.coreml-download/\(descriptor.sha256)",
                               nextCall: ToolFailureError.call("app", ["action": .string("embeddings.resume"), "args": .object([:])]),
                               id: id, title: title, status: "warn",
                               detail: "The memory model archive is fully downloaded but has not been installed; current phase: \(phase).",
                               harm: "Memory search cannot use the required model until it is installed.",
                               human_action: "Open Diagnostics and choose Check / resume on the Memory model download row to verify and install it.")
        }
        return CheckResult(source: "extras/coreml and extras/.coreml-download", id: id, title: title, status: "warn",
                           detail: "The required separate memory model has not been downloaded; current phase: \(phase).",
                           human_action: "Open Diagnostics and choose Check / resume on the Memory model download row.")
    }

    public static func repair(dataRoot: URL = PersistenceCore.defaultDataRoot(), scope: DoctorRepairScope) async -> DoctorExecutableRepair? {
        let before = await read(dataRoot: dataRoot)
        if before.status == "warn", before.detail == "The installed memory model and memory search have different embedding epochs." {
            guard case .button = scope else { return nil }
            return DoctorExecutableRepair(checkID: id) {
                let current = await read(dataRoot: dataRoot)
                guard current.status == "warn", current.detail == before.detail else {
                    return .unverified("Repair skipped: the memory search epoch changed.")
                }
                return await SwiftNativeMemoryV2.shared.reconcileEmbeddingEpochAtLaunch()
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
