import Foundation
import Synchronization
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import NativeAgentCore
import PersistenceCore
#if canImport(CoreML) && !os(Linux)
import CoreML
#endif

// Blueprint: | `MemoryV2+Embedding.swift` | `CoreMLEmbeddingProvider`: checked real-model loading and batch outcomes |

// MARK: - Embedding framework + on-disk store + Swift recaller
// Production uses packaged bge and WordPiece artifacts from Resources or the data root; missing or broken assets fail by path. Synthetic vectors require
// explicit mock selection.

// MARK: - EmbeddingProvider protocol

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var modelId: String { get }
    var embeddingEpoch: MemoryEmbeddingEpoch { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
    func embedItemsWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingItemBatch
    /// Search queries, in the same space as the stored text they are scored against. Never for text that is stored.
    func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
}

public extension EmbeddingProvider {
    func embedItemsWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingItemBatch {
        let batch = try await embedWithEpoch(texts)
        return MemoryEmbeddingItemBatch(epoch: batch.epoch, items: batch.vectors.map { .vector($0) })
    }

    func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts)
    }

    func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        MemoryEmbeddingBatch(epoch: embeddingEpoch, vectors: try await embed(texts))
    }
}

// MARK: - MockEmbeddingProvider
// Seed deterministic synthetic vectors explicitly and normalize them for cosine scoring.
public struct MockEmbeddingProvider: EmbeddingProvider {
    public let dimensions: Int
    public let modelId: String = "mock"

    public init(dimensions: Int = 384) {
        self.dimensions = dimensions
    }

    public var embeddingEpoch: MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(
            backend: "deterministic-mock",
            modelID: modelId,
            modelArtifactDigest: "fnv1a64-xorshift64star-v1",
            tokenizerArtifactDigest: "none",
            preprocessing: "exact-utf8",
            pooling: "synthetic-vector-fill",
            normalization: "l2",
            dimensions: dimensions,
            maximumSequenceLength: nil
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { Self.vector(for: $0, dim: dimensions) }
    }

    private static func vector(for text: String, dim: Int) -> [Float] {
        var state = fnv1a64(text)
        if state == 0 { state = 0x9E3779B97F4A7C15 }
        var out = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let mixed = state &* 0x2545F4914F6CDD1D
            let unit = (Double(mixed >> 11) / Double(1 << 53)) * 2.0 - 1.0
            out[i] = Float(unit)
        }
        // L2 normalize so cosine similarity == dot product.
        var sumsq: Float = 0
        for v in out { sumsq += v * v }
        let norm = sumsq > 0 ? sqrtf(sumsq) : 1
        for i in 0..<dim { out[i] /= norm }
        return out
    }
}

// MARK: - FailClosedEmbeddingProvider
// Metadata remains readable; every embed call reports the unavailable search model.
public struct FailClosedEmbeddingProvider: EmbeddingProvider {
    public let dimensions: Int
    public let modelId: String = "fail-closed"

    public init(dimensions: Int = CoreMLEmbeddingProvider.bundledDimensions) {
        self.dimensions = dimensions
    }


    public var embeddingEpoch: MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(
            backend: "fail-closed",
            modelID: modelId,
            modelArtifactDigest: "unavailable",
            tokenizerArtifactDigest: "unavailable",
            preprocessing: "unavailable",
            pooling: "unavailable",
            normalization: "unavailable",
            dimensions: dimensions,
            maximumSequenceLength: nil
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw MemoryStorageError.searchFailure("The memory search model is unavailable.",
            code: "memory_search_model_unavailable",
            instruction: "Tell the person: NativeAgent's bge-large-en-v1.5 search model is unavailable; read Doctor for the model file and failure.")
    }
}

// MARK: - CoreMLEmbeddingProvider
// Require the model and vocabulary; shared inference failures throw while unusable corpus predictions retain item-scoped outcomes.
public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let allowedModelExtensions: Set<String> = ["mlpackage", "mlmodelc", "mlmodel"]
    // Share the artifact digest independently of each provider's epoch parameters.
    private static let cachedExtrasEpoch = Mutex<(fingerprint: String, digest: String, epoch: MemoryEmbeddingEpoch?)?>(nil)

    /// Cheap change detector for an installed extras model: every file under the package plus the manifest and vocab, as relative path, size and modification
    /// time.
    private static func extrasFingerprint(_ installed: InstalledExtrasModel) throws -> String {
        let fm = FileManager.default
        func stamp(_ url: URL, relativeTo base: URL) throws -> String {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
                throw EmbeddingError.invalidModelURL(reason: "Artifact size or modification time unavailable: \(url.path)")
            }
            let rel = NativeAgentWorkspaceRoot.relativePath(url.path, under: base.path).map { $0.isEmpty || base.path == "/" ? $0 : "/" + $0 } ?? url.path
            return "\(rel)|\(size)|\(mtime)"
        }
        var lines: [String] = [try stamp(installed.vocabURL, relativeTo: installed.modelURL.deletingLastPathComponent()),
                               try stamp(installed.modelURL.deletingLastPathComponent().appendingPathComponent("embedding.json"),
                                     relativeTo: installed.modelURL.deletingLastPathComponent())]
        let attrs = try fm.attributesOfItem(atPath: installed.modelURL.path)
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            for path in try fm.subpathsOfDirectory(atPath: installed.modelURL.path) {
                lines.append(try stamp(installed.modelURL.appendingPathComponent(path), relativeTo: installed.modelURL))
            }
        } else {
            lines.append(try stamp(installed.modelURL, relativeTo: installed.modelURL))
        }
        return installed.modelURL.path + "\n" + lines.sorted().joined(separator: "\n")
    }

    public let dimensions: Int
    public let modelId: String
    public let embeddingEpoch: MemoryEmbeddingEpoch
    private let modelURL: URL
    private let tokenizer: WordPieceTokenizer
    private let maxSeqLength: Int
    public static let bundledModelID = "bge-large-en-v1.5"
    public static let bundledDimensions = 1024
    #if canImport(CoreML) && !os(Linux)
    private let mlModel: MLModel
    #endif

    /// Use CPU and Neural Engine so embedding never consumes GPU capacity.
    #if canImport(CoreML) && !os(Linux)
    public static func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    #endif

    public init(
        modelURL: URL,
        vocabURL: URL? = nil,
        dimensions: Int = CoreMLEmbeddingProvider.bundledDimensions,
        modelId: String = CoreMLEmbeddingProvider.bundledModelID,
        maxSeqLength: Int = 128
    ) throws {
        self.modelURL = modelURL
        self.dimensions = dimensions
        self.modelId = modelId
        self.maxSeqLength = maxSeqLength
        guard modelURL.isFileURL else {
            throw EmbeddingError.invalidModelURL(reason: "modelURL must be a file URL, got \(modelURL.absoluteString)")
        }
        let ext = modelURL.pathExtension.lowercased()
        guard Self.allowedModelExtensions.contains(ext) else {
            throw EmbeddingError.invalidModelURL(reason: "unsupported model extension \".\(ext)\" — expected one of \(Self.allowedModelExtensions.sorted())")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EmbeddingError.modelNotFound(path: modelURL.path)
        }
        let modelArtifactDigest: String
        let fingerprint = try vocabURL.map { try Self.extrasFingerprint(InstalledExtrasModel(
            modelURL: modelURL, vocabURL: $0, modelID: modelId, dimensions: dimensions)) }
        let cachedDigest = Self.cachedExtrasEpoch.withLock { $0.flatMap { $0.fingerprint == fingerprint ? $0.digest : nil } }
        if let cachedDigest {
            modelArtifactDigest = cachedDigest
        } else {
            modelArtifactDigest = try Self.modelArtifactDigest(modelURL: modelURL)
            if let fingerprint {
                Self.cachedExtrasEpoch.withLock { $0 = (fingerprint, modelArtifactDigest, nil) }
            }
        }
        self.embeddingEpoch = try Self.epoch(
            modelURL: modelURL,
            vocabURL: vocabURL,
            dimensions: dimensions,
            modelID: modelId,
            maximumSequenceLength: maxSeqLength,
            modelArtifactDigest: modelArtifactDigest
        )

        #if canImport(CoreML) && !os(Linux)
        // The cache owner loads the compiled artifact before serving it. A failed load reports that artifact; only explicit repair removes it.
        let configuration = Self.modelConfiguration()
        do {
            if ext == "mlpackage" {
                self.mlModel = try Self.loadCompiledModel(
                    packageURL: modelURL,
                    artifactDigest: modelArtifactDigest,
                    configuration: configuration
                )
            } else {
                self.mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            }
        } catch {
            throw EmbeddingError.modelNotLoaded(reason: "\(modelURL.path): \(error)")
        }
        guard let vocabURL else {
            throw EmbeddingError.modelNotLoaded(reason: "WordPiece vocabulary was not configured for \(modelURL.path).")
        }
        do { self.tokenizer = try WordPieceTokenizer(vocabURL: vocabURL) }
        catch {
            throw EmbeddingError.modelNotLoaded(reason: "WordPiece vocabulary \(vocabURL.path): \(error)")
        }
        #else
        throw EmbeddingError.modelNotLoaded(reason: "Core ML is unavailable on this platform.")
        #endif
    }

    private static func epoch(
        modelURL: URL,
        vocabURL: URL?,
        dimensions: Int,
        modelID: String,
        maximumSequenceLength: Int,
        modelArtifactDigest: String
    ) throws -> MemoryEmbeddingEpoch {
        let tokenizerDigest: String
        if let vocabURL {
            tokenizerDigest = try MemoryEmbeddingEpoch.sha256(file: vocabURL)
        } else {
            tokenizerDigest = "missing"
        }
        return MemoryEmbeddingEpoch(
            backend: "coreml",
            modelID: modelID,
            modelArtifactDigest: modelArtifactDigest,
            tokenizerArtifactDigest: tokenizerDigest,
            preprocessing: "wordpiece-v3;lowercase=true;unicode=nfc;accents=nfd-strip-mn;whitespace=space;controls=strip;punctuation=split;cjk=split",
            pooling: "attention-mask-mean-or-model-pooled",
            normalization: "l2",
            dimensions: dimensions,
            maximumSequenceLength: maximumSequenceLength
        )
    }

    private static func modelArtifactDigest(modelURL: URL) throws -> String {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory)
        return try isDirectory.boolValue
            ? MemoryEmbeddingEpoch.sha256(directory: modelURL)
            : MemoryEmbeddingEpoch.sha256(file: modelURL)
    }

    #if canImport(CoreML) && !os(Linux)
    /// Explicit repair removes only the selected artifact's current OS cache.
    public static func wipeCompileCache(packageURL: URL) throws {
        let root = try compileCacheRoot()
        let cached = try compileCacheDirectory(packageURL: packageURL,
            artifactDigest: modelArtifactDigest(modelURL: packageURL))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try withCompileCacheLock(cacheRoot: root) {
            if FileManager.default.fileExists(atPath: cached.path) {
                try FileManager.default.removeItem(at: cached)
            }
        }
    }
    #endif

    #if canImport(CoreML) && !os(Linux)
    /// Load exactly once at its durable path under the cache's cross-process lock. A failed artifact remains named for explicit repair, never served.
    static func loadCompiledModel(
        packageURL: URL,
        artifactDigest: String,
        configuration: MLModelConfiguration,
        cacheRoot overrideRoot: URL? = nil,
        osKey overrideOSKey: String? = nil
    ) throws -> MLModel {
        let fm = FileManager.default
        let root = try overrideRoot ?? compileCacheRoot()
        let cacheDir = try compileCacheDirectory(
            packageURL: packageURL,
            artifactDigest: artifactDigest,
            cacheRoot: overrideRoot,
            osKey: overrideOSKey
        ).deletingLastPathComponent()
        let cached = try compileCacheDirectory(
            packageURL: packageURL,
            artifactDigest: artifactDigest,
            cacheRoot: overrideRoot,
            osKey: overrideOSKey
        )

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try withCompileCacheLock(cacheRoot: root) {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: cached.path) {
                do { return try MLModel(contentsOf: cached, configuration: configuration) }
                catch {
                    throw EmbeddingError.modelNotLoaded(
                        reason: "Compiled artifact \(cached.path) failed to load: \(error). Repair this artifact through Doctor.")
                }
            }

            let compiled = try MLModel.compileModel(at: packageURL)
            let staging = cacheDir.appendingPathComponent(
                ".\(UUID().uuidString).mlmodelc",
                isDirectory: true
            )
            defer { try? fm.removeItem(at: staging) }
            try fm.moveItem(at: compiled, to: staging)
            try fm.moveItem(at: staging, to: cached)
            let model: MLModel
            do { model = try MLModel(contentsOf: cached, configuration: configuration) }
            catch {
                throw EmbeddingError.modelNotLoaded(reason: "Compiled artifact \(cached.path) failed to load: \(error). Repair this artifact through Doctor.")
            }
            retainCurrentAndNewest(in: cacheDir, keeping: cached, maximumEntries: 2) { $0.pathExtension == "mlmodelc" }
            retainCurrentAndNewest(in: cacheDir.deletingLastPathComponent(), keeping: cacheDir, maximumEntries: 1) {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            return model
        }
    }

    static func compileCacheDirectory(
        packageURL: URL,
        artifactDigest: String,
        cacheRoot overrideRoot: URL? = nil,
        osKey overrideOSKey: String? = nil
    ) throws -> URL {
        let base = packageURL.deletingPathExtension().lastPathComponent
        let osKey = sanitizedCacheComponent(overrideOSKey ?? operatingSystemCacheKey())
        let digest = sanitizedCacheComponent(artifactDigest)
        return try (overrideRoot ?? compileCacheRoot())
            .appendingPathComponent(base, isDirectory: true)
            .appendingPathComponent(osKey, isDirectory: true)
            .appendingPathComponent("\(digest).mlmodelc", isDirectory: true)
    }

    static func compileCacheRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base
            .appendingPathComponent(InstallPaths.current.name("NativeAgent"), isDirectory: true)
            .appendingPathComponent("coreml-compiled-v2", isDirectory: true)
    }

    static func operatingSystemCacheKey(processInfo: ProcessInfo = .processInfo) -> String {
        let version = processInfo.operatingSystemVersion
        let build = systemBuildVersion() ?? "unknown-build"
        return "macos-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)-\(build)"
    }

    private static func systemBuildVersion() -> String? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary["ProductBuildVersion"] as? String
    }

    private static func sanitizedCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(scalars)
    }

    /// Keep the current path first, then the newest candidates; two artifacts protect another process's pending load.
    static func retainCurrentAndNewest(
        in directory: URL,
        keeping current: URL,
        maximumEntries: Int,
        fileManager fm: FileManager = .default,
        matching predicate: (URL) -> Bool
    ) {
        guard maximumEntries > 0,
              let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return }
        let candidates = entries.filter(predicate)
            .sorted {
                if $0.standardizedFileURL == current.standardizedFileURL { return true }
                if $1.standardizedFileURL == current.standardizedFileURL { return false }
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for stale in candidates.dropFirst(maximumEntries) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func withCompileCacheLock<T>(cacheRoot: URL, body: () throws -> T) throws -> T {
        let lockPath = cacheRoot.appendingPathComponent(".compile.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    #endif

    public static func bundled(extrasRoot: URL? = nil) throws -> CoreMLEmbeddingProvider {
        let installed = try installedExtrasModel(root: extrasRoot)
        return try CoreMLEmbeddingProvider(
            modelURL: installed.modelURL,
            vocabURL: installed.vocabURL,
            dimensions: installed.dimensions,
            modelId: installed.modelID
        )
    }

    /// Read bge model and vocabulary from their colocated embedding.json; artifact identity enters the epoch so convergence replaces incompatible corpus
    /// vectors.
    public struct InstalledExtrasModel: Sendable, Equatable {
        public let modelURL: URL
        public let vocabURL: URL
        public let modelID: String
        public let dimensions: Int
    }

    /// A present but unusable manifest throws immediately. With neither copy, fail by name and path, exactly as for a broken install.
    public static func installedExtrasModel(root: URL?) throws -> InstalledExtrasModel {
        _ = try EmbeddingModelDownload.configuredDescriptor()
        if let root,
           let installed = try extrasModel(inDirectory: root
               .appendingPathComponent("extras", isDirectory: true)
               .appendingPathComponent("coreml", isDirectory: true)) {
            return installed
        }
        if let resources = Bundle.main.resourceURL,
           let shipped = try extrasModel(inDirectory: resources.appendingPathComponent("embedding", isDirectory: true)) {
            return shipped
        }
        let shippedManifest = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("embedding/embedding.json")
        let dataLocation = root.map { " Also checked \($0.appendingPathComponent("extras/coreml/embedding.json").path)." } ?? ""
        throw EmbeddingError.installedModelUnusable(
            manifest: shippedManifest.path,
            reason: "\(bundledModelID) is missing: embedding.json, embedding.mlpackage and vocab.txt are required.\(dataLocation)"
        )
    }

    /// Only an absent manifest returns nil; unusable configured artifacts throw with their cause.
    static func extrasModel(inDirectory dir: URL) throws -> InstalledExtrasModel? {
        let manifest = dir.appendingPathComponent("embedding.json")
        func unusable(_ reason: String) -> EmbeddingError {
            .installedModelUnusable(manifest: manifest.path, reason: reason)
        }
        // Use lstat so dangling symlinks and unreadable folders cannot masquerade as absent installs.
        var info = stat()
        if lstat(manifest.path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw unusable("embedding.json cannot be checked: \(String(cString: strerror(errno)))")
        }
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw unusable("embedding.json is not readable JSON") }
        guard let model = object["model"] as? String, !model.isEmpty,
              let vocab = object["vocab"] as? String, !vocab.isEmpty,
              let modelID = object["model_id"] as? String, !modelID.isEmpty,
              let dimensions = object["dimensions"] as? Int, dimensions > 0
        else { throw unusable("embedding.json needs model, vocab, model_id and dimensions") }
        guard modelID == bundledModelID, dimensions == bundledDimensions
        else { throw unusable("embedding.json must select \(bundledModelID), \(bundledDimensions) dimensions; found \(modelID), \(dimensions) dimensions") }
        guard !model.contains("/"), !vocab.contains("/")
        else { throw unusable("model and vocab must be file names beside embedding.json") }
        let modelURL = dir.appendingPathComponent(model)
        let vocabURL = dir.appendingPathComponent(vocab)
        guard allowedModelExtensions.contains(modelURL.pathExtension.lowercased())
        else { throw unusable("\(model) is not a Core ML model package") }
        guard FileManager.default.fileExists(atPath: modelURL.path)
        else { throw unusable("\(model) is missing") }
        guard FileManager.default.fileExists(atPath: vocabURL.path)
        else { throw unusable("\(vocab) is missing") }
        // Both files must resolve inside the extras directory, symlinks included.
        let base = dir.resolvingSymlinksInPath().path
        guard [modelURL, vocabURL].allSatisfy({ NativeAgentWorkspaceRoot.relativePath($0.resolvingSymlinksInPath().path, under: base)?.isEmpty == false })
        else { throw unusable("\(model) or \(vocab) resolves outside \(dir.path)") }
        return InstalledExtrasModel(modelURL: modelURL, vocabURL: vocabURL, modelID: modelID, dimensions: dimensions)
    }

    public static func bundledEmbeddingEpoch(extrasRoot: URL? = nil) throws -> MemoryEmbeddingEpoch {
        let installed = try installedExtrasModel(root: extrasRoot)
        // Invalidate on recursive file stamps, including manifest and vocabulary changes.
        let fingerprint = try extrasFingerprint(installed)
        let cached = cachedExtrasEpoch.withLock { $0.flatMap { $0.fingerprint == fingerprint ? $0 : nil } }
        if let epoch = cached?.epoch { return epoch }
        let digest = try cached?.digest ?? modelArtifactDigest(modelURL: installed.modelURL)
        let resolvedEpoch = try epoch(
            modelURL: installed.modelURL,
            vocabURL: installed.vocabURL,
            dimensions: installed.dimensions,
            modelID: installed.modelID,
            maximumSequenceLength: 128,
            modelArtifactDigest: digest
        )
        cachedExtrasEpoch.withLock { $0 = (fingerprint, digest, resolvedEpoch) }
        return resolvedEpoch
    }

    /// Probe resources without compiling or loading CoreML so opening Settings cannot allocate the model.
    public static func bundledResourcesAvailable(extrasRoot: URL? = nil) -> Bool {
        do {
            _ = try installedExtrasModel(root: extrasRoot)
            return true
        } catch {
            return false
        }
    }

    /// The shadow check must not infer absence from a clipped sentence. This reads the already-loaded tokenizer's exact window, without inference.
    func coversCompleteTexts(_ texts: [String]) -> Bool {
        texts.allSatisfy { tokenizer.encode($0, maxLength: maxSeqLength).isComplete }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embedItemsWithEpoch(texts).requireVectors()
    }

    public func embedItemsWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingItemBatch {
        let items = try await embed(texts.map { tokenizer.encode($0, maxLength: maxSeqLength) })
        return MemoryEmbeddingItemBatch(epoch: embeddingEpoch, items: items)
    }

    func embedCompleteTexts(_ texts: [String]) async throws -> [[Float]]? {
        let encoded = texts.map { tokenizer.encode($0, maxLength: maxSeqLength) }
        guard encoded.allSatisfy({ $0.isComplete }) else { return nil }
        let items = try await embed(encoded)
        return try MemoryEmbeddingItemBatch(epoch: embeddingEpoch, items: items).requireVectors()
    }

    private func embed(_ encoded: [(inputIds: [Int], attentionMask: [Int], isComplete: Bool)]) async throws -> [MemoryEmbeddingItem] {
        #if canImport(CoreML) && !os(Linux)
        var inputs: [MLFeatureProvider] = []
        var masks: [[Int]] = []
        inputs.reserveCapacity(encoded.count)
        for (ids, mask, _) in encoded {
            let inputArr = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLength)], dataType: .int32)
            let maskArr = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLength)], dataType: .int32)
            for i in 0..<maxSeqLength {
                inputArr[i] = NSNumber(value: i < ids.count ? Int32(ids[i]) : 0)
                maskArr[i] = NSNumber(value: i < mask.count ? Int32(mask[i]) : 0)
            }
            do {
                inputs.append(try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: inputArr),
                    "attention_mask": MLFeatureValue(multiArray: maskArr),
                ]))
            } catch {
                throw EmbeddingError.modelNotLoaded(reason: "could not build input feature provider: \(error)")
            }
            masks.append(mask)
        }
        guard !inputs.isEmpty else { return [] }
        let outputs: MLBatchProvider
        do {
            outputs = try await mlModel.predictions(
                from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions()
            )
        } catch {
            throw EmbeddingError.modelNotLoaded(reason: "CoreML prediction failed: \(error)")
        }
        guard outputs.count == inputs.count else {
            throw EmbeddingError.modelNotLoaded(reason: "CoreML returned \(outputs.count) predictions for \(inputs.count) inputs")
        }
        var results: [MemoryEmbeddingItem] = []
        results.reserveCapacity(encoded.count)
        for index in 0..<outputs.count {
            let out = outputs.features(at: index)
            let mask = masks[index]
            var pooled: MemoryEmbeddingItem? = nil
            for name in out.featureNames {
                guard let val = out.featureValue(for: name), let arr = val.multiArrayValue else { continue }
                pooled = Self.meanPoolAndNormalize(arr, mask: mask, dim: dimensions)
                if pooled != nil { break }
            }
            guard let vec = pooled else {
                throw EmbeddingError.modelNotLoaded(reason: """
                    no usable multiarray output in CoreML prediction (missing output or unexpected shape vs dim=\(dimensions))
                    """)
            }
            results.append(vec)
        }
        return results
        #else
        _ = encoded
        throw EmbeddingError.modelNotLoaded(reason: "CoreML unavailable on this platform")
        #endif
    }

    #if canImport(CoreML) && !os(Linux)
    private static func meanPoolAndNormalize(_ arr: MLMultiArray, mask: [Int], dim: Int) -> MemoryEmbeddingItem? {
        let shape = arr.shape.map { $0.intValue }
        if shape == [1, dim] || shape == [dim] {
            var out = [Float](repeating: 0, count: dim)
            for i in 0..<dim { out[i] = arr[i].floatValue }
            return normalizedItem(out)
        }
        // Attention masking prevents padded tokens from affecting the pooled vector.
        if shape.count == 3, shape[0] == 1, shape[2] == dim {
            let seq = shape[1]
            var sum = [Float](repeating: 0, count: dim)
            var denom: Float = 0
            for t in 0..<seq {
                let active: Float = (t < mask.count && mask[t] != 0) ? 1.0 : 0.0
                if active == 0 { continue }
                denom += 1
                for d in 0..<dim {
                    let idx = t * dim + d
                    sum[d] += arr[idx].floatValue
                }
            }
            if denom > 0 { for d in 0..<dim { sum[d] /= denom } }
            return normalizedItem(sum)
        }
        // Reject unexpected output shapes rather than constructing an unusable vector.
        return nil
    }

    private static func l2norm(_ v: [Float]) throws -> [Float] {
        try VectorMath.requireUsable(v)
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        let normalized = v.map { Float(Double($0) / norm) }
        try VectorMath.requireUsable(normalized, dimensions: v.count)
        return normalized
    }

    /// Only normalization of this prediction is item-scoped. Missing output, wrong output shape and failed batch inference remain shared failures.
    private static func normalizedItem(_ vector: [Float]) -> MemoryEmbeddingItem {
        do { return .vector(try l2norm(vector)) }
        catch { return .unembeddable(reason: error.localizedDescription) }
    }
    #endif
}

// MARK: - Errors

public enum EmbeddingError: Error, LocalizedError {
    case modelNotFound(path: String)
    case modelNotLoaded(reason: String)
    case invalidModelURL(reason: String)
    case installedModelUnusable(manifest: String, reason: String)

    public var failure: ToolFailureError {
        switch self {
        case .modelNotFound(let p):
            return MemoryStorageError.searchFailure("Memory search model not found at \(p)", code: "memory_search_model_missing",
                instruction: "Restore the missing model at the reported path; read Doctor to verify it.")
        case .modelNotLoaded(let r):
            return MemoryStorageError.searchFailure("Memory search model not loaded: \(r)", code: "memory_search_model_load_failed",
                instruction: "Read Doctor and repair the reported model load error.")
        case .invalidModelURL(let r):
            return MemoryStorageError.searchFailure("Invalid memory search model path: \(r)", code: "memory_search_model_path_invalid",
                instruction: "Correct the reported model path; read Doctor to verify it.")
        case .installedModelUnusable(let m, let r):
            return MemoryStorageError.searchFailure("Installed memory search model did not load (\(m)): \(r)", code: "memory_search_model_unusable",
                instruction: "Repair the installed model named in the error; read Doctor to verify it.")
        }
    }

    public var errorDescription: String? { MemoryV2Error.describe(failure) }
}
