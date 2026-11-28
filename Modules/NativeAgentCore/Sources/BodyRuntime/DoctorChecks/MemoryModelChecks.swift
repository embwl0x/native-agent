import Foundation
import NativeAgentCore
import PersistenceCore
import MindCore
// Blueprint: | `MemoryModelChecks.swift` | Canonical memory/graph counts; activation verdict and installed prediction; epoch repair |

/// Inspect canonical SQLite graph counts without automatically repairing data.
public struct MemoryStoreCheck: DoctorCheck {
    public let id: String = "memory_store"
    public let title: String = "MemoryV2 and Knowledge Graph Store"
    private let root: URL

    public init(root: URL = defaultDataRoot()) {
        self.root = root
    }

    public func run() async -> CheckResult {
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        let sqlite = memoryDir.appendingPathComponent("memory.sqlite")
        do {
            try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        } catch {
            return CheckResult(source: "memory/memory.sqlite",
                id: id,
                title: title,
                status: "fail",
                detail: "Could not prepare memory directory: \(error.localizedDescription)",
                harm: "The agent's memories cannot be saved.",
                human_action: StorageCheck.accessStep(memoryDir.path),
                ask: .permission
            )
        }

        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: sqlite.path) {
            warnings.append("memory.sqlite missing")
        } else {
            do {
                guard let size = try FileManager.default.attributesOfItem(atPath: sqlite.path)[.size] as? NSNumber else {
                    throw CocoaError(.fileReadUnknown)
                }
                if size.int64Value <= 0 { warnings.append("memory.sqlite is empty") }
            } catch {
                return CheckResult(source: sqlite.path, id: id, title: title, status: "fail",
                    detail: "The size of \(sqlite.path) could not be read.",
                    human_action: StorageCheck.accessStep(sqlite.path), ask: .permission)
            }
        }

        // Only a present, nonempty database can provide measured graph counts.
        var kgSummary: String?
        if warnings.isEmpty {
            let reader = makeKnowledgeGraphReader(
                graphPath: memoryDir.appendingPathComponent("memory.sqlite")
            )
            do {
                let envelope = try await reader.allEntitiesChecked(page: 0)
                guard case .object(let obj) = envelope,
                      case .int(let entities)? = obj["total_entities"],
                      case .int(let relationships)? = obj["total_edges"] else {
                    throw DoctorChecksError.underlying("knowledge graph envelope malformed")
                }
                kgSummary = "knowledge graph: \(entities) entities, \(relationships) relationships"
            } catch {
                return CheckResult(source: "memory/memory.sqlite",
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Knowledge graph tables in memory.sqlite could not be read: \(error.localizedDescription)",
                    harm: "The agent cannot recall connections between its saved memories."
                )
            }
        }

        if !warnings.isEmpty {
            return CheckResult(source: "memory/memory.sqlite",
                id: id,
                title: title,
                status: "fail",
                detail: "Memory store warning(s): \(warnings.joined(separator: ", ")).",
                human_action: """
                    Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore \
                    backup.
                    """,
                ask: .permission
            )
        }
        return CheckResult(source: "memory/memory.sqlite",
            id: id,
            title: title,
            status: "ok",
            detail: "memory.sqlite is present and readable (\(kgSummary ?? "knowledge graph readable"))."
        )
    }
}

/// Include activation refusal in health; reconverge a refused epoch through the canonical runtime after clearing its compile cache.
public struct CoreMLEmbedderCheck: RepairingDoctorCheck {
    public let id: String = "coreml_embedder"

    /// Account only exact required package assets; unknown files, caches and download staging remain dynamic storage.
    public static func installedModelStorageFiles(dataRoot: URL) throws -> Set<String> {
        let directory = dataRoot.appendingPathComponent("extras/coreml", isDirectory: true)
        let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot)
        guard installed.modelURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              installed.modelURL.pathExtension == "mlpackage" else { return [] }
        let manifest = installed.modelURL.appendingPathComponent("Manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        guard let entries = object?["itemInfoEntries"] as? [String: [String: Any]],
              let root = object?["rootModelIdentifier"] as? String,
              entries[root]?["path"] as? String == "com.apple.CoreML/model.mlmodel",
              entries.values.contains(where: { $0["path"] as? String == "com.apple.CoreML/weights" }) else { return [] }
        let files = [manifest, installed.vocabURL, directory.appendingPathComponent("embedding.json"),
                     installed.modelURL.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"),
                     installed.modelURL.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")]
        let base = directory.standardizedFileURL.path
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
                  file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  NativeAgentWorkspaceRoot.relativePath(file.standardizedFileURL.path, under: base)?.isEmpty == false else { return [] }
        }
        return Set(files.map { $0.standardizedFileURL.path })
    }

    /// Even an absent model is named, using the runtime's one model identity.
    public var title: String { "Core ML Embedder (\(CoreMLEmbeddingProvider.bundledModelID))" }

    private let root: URL

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run(repair: Bool) async -> CheckResult {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: root)
        guard let runtime = await memory.embeddingRuntimeSnapshot() else {
            return CheckResult(source: "memory embedding runtime", id: id, title: title, status: "warn",
                detail: "The canonical memory provider is not available to measure.")
        }
        if runtime.requestedBackend == ManagedEmbeddingProvider.mockBackend {
            return await probe(memory: memory, installed: nil)
        }
        // Missing and unusable assets fail through the same named resolver.
        let installed: CoreMLEmbeddingProvider.InstalledExtrasModel
        do {
            installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: root)
        } catch {
            let unusable: (manifest: URL, reason: String)? = if case .installedModelUnusable(let path, let reason) = error as? EmbeddingError {
                (URL(fileURLWithPath: path), reason)
            } else { nil }
            let dataFile = unusable.flatMap { NativeAgentWorkspaceRoot.relativePath($0.manifest.path, under: root.path)?.isEmpty == false ? $0 : nil }
            // Keep the manifest's own remedy for manifest damage; other asset failures require setting aside the installation.
            let manifestDamaged = dataFile.map { $0.reason.hasPrefix("embedding.json") || $0.reason.hasPrefix("model and vocab") } ?? false
            return CheckResult(
                source: unusable.map { manifestDamaged ? $0.manifest.path : $0.manifest.deletingLastPathComponent().path } ?? "extras/coreml/embedding.json",
                id: id, title: title, status: "fail",
                detail: "\(CoreMLEmbeddingProvider.bundledModelID) is unavailable (\(error.localizedDescription)); semantic recall is off until it is fixed.",
                harm: "The agent cannot search its memories by meaning.",
                human_action: dataFile.map { file in manifestDamaged
                    ? ToolFailureError.fileRepairInstruction(file.manifest,
                        shape: """
                            This JSON manifest holds model and vocab file names beside it, model_id bge-large-en-v1.5 and dimensions 1024. Do not \
                            substitute another model or invent missing assets.
                            """)
                    : ToolFailureError.fileRepairInstruction(file.manifest.deletingLastPathComponent(),
                        shape: """
                            This installed memory model directory is unusable (\(file.reason)). If embedding.json names a model the person installed \
                            themselves, leave it and report that.\u{20}
                            """
                            + """
                                Otherwise move the whole directory intact to a sibling recovery name, never deleting a file, so app embeddings.resume \
                                installs the release model again.
                                """) },
                owner: unusable != nil && dataFile == nil ? .builder : nil
            )
        }
        if repair {
            do { try CoreMLEmbeddingProvider.wipeCompileCache(packageURL: installed.modelURL) }
            catch {
                return CheckResult(source: installed.modelURL.path,
                    id: id, title: title, status: "fail",
                    detail: """
                        Memory model cache could not be cleared: \(error.localizedDescription). Repair the cache directory access before loading the \
                        model again.
                        """,
                    harm: "The agent cannot repair its memory search model's compiled cache.",
                    repairApplied: false, repair_available: true)
            }
            let after = await probe(memory: memory, installed: installed, reconcileRefusal: true)
            if after.status == "off" { return after }
            return CheckResult(source: after.source, nextCall: after.nextCall,
                id: id, title: title, status: after.status, detail: after.detail,
                harm: after.harm,
                repair: """
                    Removed this model artifact's compiled cache for the current OS and rechecked memory search health, resubmitting a matching \
                    activation refusal to the canonical memory owner. \(after.repair ?? "")
                    """,
                repairApplied: true,
                repair_available: true
            )
        }
        return await probe(memory: memory, installed: installed)
    }

    private func probe(memory: SwiftNativeMemoryV2, installed: CoreMLEmbeddingProvider.InstalledExtrasModel?,
                       reconcileRefusal: Bool = false) async -> CheckResult {
        do {
            let epoch = try installed.map { _ in try CoreMLEmbeddingProvider.bundledEmbeddingEpoch(extrasRoot: root) }
            var state: MemoryEmbeddingEpochState?
            if installed != nil { state = try await memory.memoryEmbeddingEpochState() }
            if let epoch, reconcileRefusal, state?.activationFailure?.epoch == epoch.rawValue {
                await memory.releaseEmbeddingMemory()
                _ = await memory.reconcileEmbeddingEpochAtLaunch()
                state = try await memory.memoryEmbeddingEpochState()
            }
            if let epoch, let failure = state?.activationFailure, failure.epoch == epoch.rawValue {
                return CheckResult(source: "memory/memory.sqlite",
                    id: id, title: title, status: "fail",
                    detail: "Memory search activation refused at \(failure.recordedAt) for \(failure.epoch): \(failure.reason)",
                    harm: "The agent cannot search its saved memories with the installed model.",
                    repair: """
                        Press Repair in Diagnostics → Health checks to clear the Core ML compile cache and rebuild through the memory owner. If \
                        activation is still refused, preserve the installed model and report the named model defect to the builder. A passing probe \
                        cannot clear this refusal; successful canonical activation is required.
                        """,
                    repair_available: true)
            }
            let batch = try await memory.embedForDerivedContextWithEpoch([MemoryEmbeddingEpoch.activationProbeText])
            guard batch.vectors.count == 1, let vector = batch.vectors.first else {
                throw DoctorChecksError.underlying("The model returned no activation probe vector.")
            }
            guard let runtime = await memory.embeddingRuntimeSnapshot(), runtime.embeddingEpoch == batch.epoch.rawValue else {
                return CheckResult(source: "memory embedding runtime", id: id, title: title, status: "warn",
                    detail: "The serving provider's epoch is unavailable or changed during the probe; memory search health remains unmeasured.")
            }
            try VectorMath.requireUsable(vector, dimensions: runtime.dimensions)
            if runtime.requestedBackend == ManagedEmbeddingProvider.mockBackend {
                return CheckResult(source: "config/embeddings.json", id: id, title: title, status: "off",
                    detail: """
                        Meaning-based memory is Off; the canonical memory owner's selected \(runtime.modelId), \(runtime.dimensions)-d provider \
                        produces a usable vector.
                        """,
                    repair_available: false)
            }
            guard let installed, batch.epoch == epoch, state?.activeEpoch == batch.epoch.rawValue,
                  state?.dimensions == runtime.dimensions, runtime.dimensions == installed.dimensions else {
                return CheckResult(source: "memory/memory.sqlite",
                    id: id, title: title, status: "warn",
                    detail: """
                        The canonical memory probe produces a usable vector, but the serving, installed and active model epochs or dimensions differ. \
                        Canonical activation is still unmeasured; inspect convergence before judging memory search healthy.
                        """)
            }
            return CheckResult(source: installed.modelURL.path,
                id: id, title: title, status: "ok",
                detail: """
                    \(installed.modelID), \(installed.dimensions)-d: memory search has activated this epoch; the canonical memory owner's \
                    activation probe produces a usable vector with the installed model's epoch.
                    """
            )
        } catch {
            if installed == nil {
                return CheckResult(source: "memory embedding runtime", id: id, title: title, status: "warn",
                    detail: "Meaning-based memory was Off, but its selected provider could not be measured (\(String(describing: error))).",
                    repair_available: false)
            }
            return CheckResult(source: "Core ML model \(CoreMLEmbeddingProvider.bundledModelID) and its compiled cache",
                id: id, title: title, status: "fail",
                detail: """
                    \(CoreMLEmbeddingProvider.bundledModelID) memory search health could not be established (\(String(describing: error))); \
                    model prediction and canonical activation must both be readable and usable.
                    """,
                harm: "The agent cannot reliably search its memories by meaning.",
                repair: """
                    Press Repair in Diagnostics → Health checks to clear the Core ML compile cache and retry the prediction. If it still fails, \
                    preserve the installed model and report the named model defect to the builder; do not activate an empty index.
                    """,
                repair_available: true
            )
        }
    }
}
