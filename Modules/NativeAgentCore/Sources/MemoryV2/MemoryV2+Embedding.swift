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

// Blueprint: | `MemoryV2+Embedding.swift` | Embedding provider contracts and `CoreMLEmbeddingProvider`: real-model loading, artifact epochs, bounded compiled-model storage, fail-closed availability, one batch prediction per embed call |

// MARK: - Embedding framework + on-disk store + Swift recaller
//
// Production model packaging happens outside runtime. bge-large-en-v1.5 and
// its WordPiece vocabulary ship in Resources/embedding; a data-root copy may
// supply the same model. Missing or broken assets fail closed by path.
// Production callers go through SwiftNativeMemoryV2.recall(). When the real
// model is unavailable, only an explicit mock opt-in permits synthetic vectors.

// MARK: - EmbeddingProvider protocol

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var modelId: String { get }
    var embeddingEpoch: MemoryEmbeddingEpoch { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
    /// Search queries, in the same space as the stored text they are scored
    /// against. Never for text that is stored.
    func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
}

public extension EmbeddingProvider {
    /// A symmetric model embeds a query like any other text.
    func embedQueriesWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        try await embedWithEpoch(texts)
    }

    var embeddingEpoch: MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(
            backend: modelId,
            modelID: modelId,
            modelArtifactDigest: "provider-defined-identity-unavailable",
            tokenizerArtifactDigest: "provider-defined-identity-unavailable",
            preprocessing: "provider-defined",
            pooling: "provider-defined",
            normalization: "provider-defined",
            dimensions: dimensions,
            maximumSequenceLength: nil
        )
    }

    func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch {
        MemoryEmbeddingBatch(epoch: embeddingEpoch, vectors: try await embed(texts))
    }
}

// MARK: - MockEmbeddingProvider
// Explicit synthetic provider: FNV-1a seeds xorshift64*, then L2 normalization.
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
            // xorshift64* — deterministic, decent distribution for tests.
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
//
// Require a loaded Core ML model and WordPiece vocabulary; inference failures and unusable output throw.
public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let allowedModelExtensions: Set<String> = ["mlpackage", "mlmodelc", "mlmodel"]
    // Share the artifact digest independently of each provider's epoch parameters.
    private static let cachedExtrasEpoch = Mutex<(fingerprint: String, digest: String, epoch: MemoryEmbeddingEpoch?)?>(nil)

    /// Cheap change detector for an installed extras model: every file under
    /// the package plus the manifest and vocab, as relative path, size and
    /// modification time.
    private static func extrasFingerprint(_ installed: InstalledExtrasModel) -> String {
        let fm = FileManager.default
        func stamp(_ url: URL, relativeTo base: URL) -> String {
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let rel = NativeAgentWorkspaceRoot.relativePath(url.path, under: base.path).map { $0.isEmpty || base.path == "/" ? $0 : "/" + $0 } ?? url.path
            return "\(rel)|\(size)|\(mtime)"
        }
        var lines: [String] = [stamp(installed.vocabURL, relativeTo: installed.modelURL.deletingLastPathComponent()),
                               stamp(installed.modelURL.deletingLastPathComponent().appendingPathComponent("embedding.json"),
                                     relativeTo: installed.modelURL.deletingLastPathComponent())]
        if let e = fm.enumerator(at: installed.modelURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let file as URL in e { lines.append(stamp(file, relativeTo: installed.modelURL)) }
        } else {
            lines.append(stamp(installed.modelURL, relativeTo: installed.modelURL))
        }
        return installed.modelURL.path + "\n" + lines.sorted().joined(separator: "\n")
    }

    public let dimensions: Int
    public let modelId: String
    public let embeddingEpoch: MemoryEmbeddingEpoch
    private let modelURL: URL
    private let tokenizer: WordPieceTokenizer
    private let maxSeqLength: Int
    /// The one production embedding model, shipped in Resources/embedding.
    public static let bundledModelID = "bge-large-en-v1.5"
    public static let bundledDimensions = 1024
    #if canImport(CoreML) && !os(Linux)
    private let mlModel: MLModel
    #endif

    /// The embedding model always uses CPU + Neural Engine, never the GPU.
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
        let fingerprint = vocabURL.map { Self.extrasFingerprint(InstalledExtrasModel(
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
        // Compile .mlpackage inputs into the durable cache before loading.
        // A package load failure wipes that cache and recompiles once; retain the final cause.
        var loadedModel: MLModel?
        var loadFailure: Error?
        let configuration = Self.modelConfiguration()
        do {
            let urlToLoad: URL
            if ext == "mlpackage" {
                urlToLoad = try Self.compileAndCache(
                    packageURL: modelURL,
                    artifactDigest: modelArtifactDigest
                )
            } else {
                urlToLoad = modelURL
            }
            loadedModel = try MLModel(contentsOf: urlToLoad, configuration: configuration)
        } catch {
            loadFailure = error
            if ext == "mlpackage" {
                Self.wipeCompileCache(packageURL: modelURL)
                do {
                    let recompiled = try Self.compileAndCache(
                        packageURL: modelURL,
                        artifactDigest: modelArtifactDigest
                    )
                    loadedModel = try MLModel(contentsOf: recompiled, configuration: configuration)
                    loadFailure = nil
                } catch {
                    loadFailure = error
                }
            }
        }
        var loadedTokenizer: WordPieceTokenizer?
        if let vurl = vocabURL, FileManager.default.fileExists(atPath: vurl.path) {
            do {
                loadedTokenizer = try WordPieceTokenizer(vocabURL: vurl)
            } catch {
                loadFailure = error
            }
        }
        guard let loadedModel, let loadedTokenizer else {
            let underlying = loadFailure.map { " Underlying: \(String(describing: $0))" } ?? ""
            let missing = (loadedModel == nil ? "MLModel" : "WordPiece vocab")
            throw EmbeddingError.modelNotLoaded(
                reason: "CoreMLEmbeddingProvider could not load \(missing) at \(modelURL.path).\(underlying)"
            )
        }
        self.mlModel = loadedModel
        self.tokenizer = loadedTokenizer
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
    /// Remove the package's compiled cache under its cross-process lock.
    public static func wipeCompileCache(packageURL: URL) {
        let base = packageURL.deletingPathExtension().lastPathComponent
        let root = compileCacheRoot()
        let modelRoot = root
            .appendingPathComponent(base, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? withCompileCacheLock(cacheRoot: root) {
            try? FileManager.default.removeItem(at: modelRoot)
        }
    }
    #endif

    #if canImport(CoreML) && !os(Linux)
    /// Publish a durable digest/OS-keyed .mlmodelc atomically under a cross-process lock.
    static func compileAndCache(
        packageURL: URL,
        artifactDigest: String,
        cacheRoot overrideRoot: URL? = nil,
        osKey overrideOSKey: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let root = overrideRoot ?? compileCacheRoot()
        let cacheDir = compileCacheDirectory(
            packageURL: packageURL,
            artifactDigest: artifactDigest,
            cacheRoot: overrideRoot,
            osKey: overrideOSKey
        ).deletingLastPathComponent()
        let cached = compileCacheDirectory(
            packageURL: packageURL,
            artifactDigest: artifactDigest,
            cacheRoot: overrideRoot,
            osKey: overrideOSKey
        )

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try withCompileCacheLock(cacheRoot: root) {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: cached.path) {
                retainCurrentAndNewest(in: cacheDir, keeping: cached, maximumEntries: 2) { $0.pathExtension == "mlmodelc" }
                retainCurrentAndNewest(in: cacheDir.deletingLastPathComponent(), keeping: cacheDir, maximumEntries: 1) {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                return cached
            }

            let compiled = try MLModel.compileModel(at: packageURL)
            let staging = cacheDir.appendingPathComponent(
                ".\(UUID().uuidString).mlmodelc",
                isDirectory: true
            )
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.moveItem(at: compiled, to: staging)
            } catch {
                try fm.copyItem(at: compiled, to: staging)
                try? fm.removeItem(at: compiled)
            }
            if fm.fileExists(atPath: cached.path) {
                try? fm.removeItem(at: cached)
            }
            try fm.moveItem(at: staging, to: cached)
            retainCurrentAndNewest(in: cacheDir, keeping: cached, maximumEntries: 2) { $0.pathExtension == "mlmodelc" }
            retainCurrentAndNewest(in: cacheDir.deletingLastPathComponent(), keeping: cacheDir, maximumEntries: 1) {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            return cached
        }
    }

    static func compileCacheDirectory(
        packageURL: URL,
        artifactDigest: String,
        cacheRoot overrideRoot: URL? = nil,
        osKey overrideOSKey: String? = nil
    ) -> URL {
        let base = packageURL.deletingPathExtension().lastPathComponent
        let osKey = sanitizedCacheComponent(overrideOSKey ?? operatingSystemCacheKey())
        let digest = sanitizedCacheComponent(artifactDigest)
        return (overrideRoot ?? compileCacheRoot())
            .appendingPathComponent(base, isDirectory: true)
            .appendingPathComponent(osKey, isDirectory: true)
            .appendingPathComponent("\(digest).mlmodelc", isDirectory: true)
    }

    static func compileCacheRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
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

    /// Resolve bge from the data root or Resources/embedding, then load it.
    public static func bundled(extrasRoot: URL? = nil) throws -> CoreMLEmbeddingProvider {
        let installed = try installedExtrasModel(root: extrasRoot)
        return try CoreMLEmbeddingProvider(
            modelURL: installed.modelURL,
            vocabURL: installed.vocabURL,
            dimensions: installed.dimensions,
            modelId: installed.modelID
        )
    }

    /// bge installed under `<dataRoot>/extras/coreml/` or Resources/embedding,
    /// described by `embedding.json` beside it:
    ///
    ///     {"model": "embedding.mlpackage", "vocab": "vocab.txt",
    ///      "model_id": "bge-large-en-v1.5", "dimensions": 1024}
    ///
    /// Its artifacts participate in the embedding epoch; launch convergence
    /// re-embeds a corpus still in an older vector space.
    public struct InstalledExtrasModel: Sendable, Equatable {
        public let modelURL: URL
        public let vocabURL: URL
        public let modelID: String
        public let dimensions: Int
    }

    /// A present but unusable manifest throws immediately. With neither copy,
    /// fail by name and path, exactly as for a broken install.
    public static func installedExtrasModel(root: URL?) throws -> InstalledExtrasModel {
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

    /// nil when `dir` has no `embedding.json`; throws when it has one that
    /// cannot be used, naming why.
    static func extrasModel(inDirectory dir: URL) throws -> InstalledExtrasModel? {
        let manifest = dir.appendingPathComponent("embedding.json")
        func unusable(_ reason: String) -> EmbeddingError {
            .installedModelUnusable(manifest: manifest.path, reason: reason)
        }
        // Only a manifest that is genuinely absent means "nothing installed".
        // lstat, not fileExists: a dangling symlink or an unreadable folder is
        // a broken install, not an absent one.
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
        let fingerprint = extrasFingerprint(installed)
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

    /// Cheap bundle-resource probe used by Settings/status. This intentionally
    /// does not compile or load the CoreML model, so merely opening Settings
    /// cannot pull the model into memory.
    public static func bundledResourcesAvailable(extrasRoot: URL? = nil) -> Bool {
        do {
            _ = try installedExtrasModel(root: extrasRoot)
            return true
        } catch {
            return false
        }
    }

    /// The shadow check must not infer absence from a clipped sentence. This
    /// reads the already-loaded tokenizer's exact window, without inference.
    func coversCompleteTexts(_ texts: [String]) -> Bool {
        texts.allSatisfy { tokenizer.encode($0, maxLength: maxSeqLength).isComplete }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embed(texts.map { tokenizer.encode($0, maxLength: maxSeqLength) })
    }

    func embedCompleteTexts(_ texts: [String]) async throws -> [[Float]]? {
        let encoded = texts.map { tokenizer.encode($0, maxLength: maxSeqLength) }
        guard encoded.allSatisfy({ $0.isComplete }) else { return nil }
        return try await embed(encoded)
    }

    private func embed(_ encoded: [(inputIds: [Int], attentionMask: [Int], isComplete: Bool)]) async throws -> [[Float]] {
        #if canImport(CoreML) && !os(Linux)
        // Predict every text in one call as a single batch.
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
        var results: [[Float]] = []
        results.reserveCapacity(encoded.count)
        for index in 0..<outputs.count {
            let out = outputs.features(at: index)
            let mask = masks[index]
            // Take the first multiarray output and mean-pool over the token
            // dimension when shape is [1, seq, dim]; if it's already [1, dim]
            // (pooled output), use it as-is.
            var pooled: [Float]? = nil
            for name in out.featureNames {
                guard let val = out.featureValue(for: name), let arr = val.multiArrayValue else { continue }
                pooled = Self.meanPoolAndNormalize(arr, mask: mask, dim: dimensions)
                if pooled != nil { break }
            }
            guard let vec = pooled else {
                throw EmbeddingError.modelNotLoaded(reason: "no usable multiarray output in CoreML prediction (missing output or unexpected shape vs dim=\(dimensions))")
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
    private static func meanPoolAndNormalize(_ arr: MLMultiArray, mask: [Int], dim: Int) -> [Float]? {
        let shape = arr.shape.map { $0.intValue }
        // Case 1: [1, dim] or [dim] — already pooled.
        if shape == [1, dim] || shape == [dim] {
            var out = [Float](repeating: 0, count: dim)
            for i in 0..<dim { out[i] = arr[i].floatValue }
            return l2norm(out)
        }
        // Case 2: [1, seq, dim] — mean-pool over seq using attention mask.
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
            return l2norm(sum)
        }
        // Reject unexpected output shapes rather than constructing an unusable vector.
        return nil
    }

    private static func l2norm(_ v: [Float]) -> [Float] {
        var sumsq: Float = 0
        for x in v { sumsq += x * x }
        let n = sumsq > 0 ? sqrtf(sumsq) : 1
        return v.map { $0 / n }
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
