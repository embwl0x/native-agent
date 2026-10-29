import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
// Blueprint: | `MemoryModelChecks.swift` | MemoryStoreCheck inspects canonical memory and graph counts; CoreMLEmbedderCheck measures installed assets and model loading, repairing only the compile cache |

/// Prepare the memory directory, then inspect SQLite kg_entities/kg_relationships through the runtime reader; offer no
/// automatic data repair.
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
                harm: "Her memories cannot be saved.",
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
                graphPath: memoryDir.appendingPathComponent("knowledge_graph.json")
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
                    harm: "She cannot recall connections between her saved memories.",
                    human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore backup.",
                    ask: .permission
                )
            }
        }

        if !warnings.isEmpty {
            return CheckResult(source: "memory/memory.sqlite",
                id: id,
                title: title,
                status: "fail",
                detail: "Memory store warning(s): \(warnings.joined(separator: ", ")).",
                human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/memory.sqlite, then choose Restore → Restore backup.",
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

/// Load the runtime's embedding model and vocabulary through its compile cache; repair clears that cache and probes again.
public struct CoreMLEmbedderCheck: RepairingDoctorCheck {
    public let id: String = "coreml_embedder"

    /// Exact required assets of the installed source package. Unknown files, caches and download staging remain dynamic
    /// storage. Model load/integrity checks still belong to this check's ordinary run path.
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
        // Missing and unusable assets fail through the same named resolver.
        let installed: CoreMLEmbeddingProvider.InstalledExtrasModel
        do {
            installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: root)
        } catch {
            let unusable: (manifest: URL, reason: String)? = if case .installedModelUnusable(let path, let reason) = error as? EmbeddingError {
                (URL(fileURLWithPath: path), reason)
            } else { nil }
            let dataFile = unusable.flatMap { NativeAgentWorkspaceRoot.relativePath($0.manifest.path, under: root.path)?.isEmpty == false ? $0 : nil }
            // The manifest's own words name a damaged manifest; anything else is a missing or invalid model asset, which only
            // the installation directory set aside fixes.
            let manifestDamaged = dataFile.map { $0.reason.hasPrefix("embedding.json") || $0.reason.hasPrefix("model and vocab") } ?? false
            return CheckResult(source: unusable.map { manifestDamaged ? $0.manifest.path : $0.manifest.deletingLastPathComponent().path } ?? "extras/coreml/embedding.json",
                id: id, title: title, status: "fail",
                detail: "\(CoreMLEmbeddingProvider.bundledModelID) is unavailable (\(error.localizedDescription)); semantic recall is off until it is fixed.",
                harm: "She cannot search her memories by meaning.",
                human_action: dataFile.map { file in manifestDamaged
                    ? ToolFailureError.fileRepairInstruction(file.manifest,
                        shape: "This JSON manifest holds model and vocab file names beside it, model_id bge-large-en-v1.5 and dimensions 1024. Do not substitute another model or invent missing assets.")
                    : ToolFailureError.fileRepairInstruction(file.manifest.deletingLastPathComponent(),
                        shape: "This installed memory model directory is unusable (\(file.reason)). If embedding.json names a model the person installed themselves, leave it and report that. "
                            + "Otherwise move the whole directory intact to a sibling recovery name, never deleting a file, so app embeddings.resume installs the release model again.") },
                owner: unusable != nil && dataFile == nil ? .builder : nil
            )
        }
        if repair {
            #if canImport(CoreML) && !os(Linux)
            CoreMLEmbeddingProvider.wipeCompileCache(packageURL: installed.modelURL)
            #endif
            let after = await probe(installed: installed)
            return CheckResult(source: after.source, nextCall: after.nextCall,
                id: id, title: title, status: after.status, detail: after.detail,
                harm: after.harm,
                repair: "Wiped the CoreML compile cache and re-probed the model load.",
                repairApplied: true,
                repair_available: true
            )
        }
        return await probe(installed: installed)
    }

    private func probe(installed: CoreMLEmbeddingProvider.InstalledExtrasModel) async -> CheckResult {
        do {
            let provider = try CoreMLEmbeddingProvider(
                modelURL: installed.modelURL, vocabURL: installed.vocabURL,
                dimensions: installed.dimensions, modelId: installed.modelID)
            return CheckResult(source: installed.modelURL.path,
                id: id, title: title, status: "ok",
                detail: "\(provider.modelId), \(provider.dimensions)-d, loads: model compiles/loads from cache and the WordPiece vocab parses."
            )
        } catch {
            return CheckResult(source: "Core ML model \(CoreMLEmbeddingProvider.bundledModelID) and its compiled cache",
                id: id, title: title, status: "fail",
                detail: "\(CoreMLEmbeddingProvider.bundledModelID) failed to load (\(String(describing: error))); semantic recall is unavailable.",
                harm: "She cannot reliably search her memories by meaning.",
                repair: "Press Repair in Diagnostics → Health checks to clear the Core ML compile cache and retry loading the model.",
                repair_available: true
            )
        }
    }
}
