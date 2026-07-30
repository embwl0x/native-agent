import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreML) && !os(Linux)
import CoreML
#endif

// MARK: - Phase B: Embedding framework + on-disk store + Swift recaller
//
// CARVED OUT OF THIS COMMIT (still Phase B / future):
//   * Production model packaging must happen outside runtime. NativeAgent does
//     not shell out to a conversion script while running.
//   * BERT-style WordPiece subword tokenization: lands with the packaged
//     .mlpackage. The CoreMLEmbeddingProvider here intentionally throws if
//     anyone tries to embed without a real model, rather than silently producing
//     wrong vectors with a stand-in tokenizer.
//   * The Core Spotlight index search backend: Phase C will replace
//     JSONLEmbeddingStore.search()'s O(N) linear cosine scan.
//   * CloudKit sync on top of the same EmbeddingStore interface: Phase D.
//
// Production callers go through SwiftNativeMemoryV2.recall(). When the real
// .mlpackage is absent the wiring uses the fail-closed/mock test path; once the
// packaged CoreML model is present the same Swift recaller provides dense recall.

// MARK: - EmbeddingProvider protocol

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var modelId: String { get }
    var embeddingEpoch: MemoryEmbeddingEpoch { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    func embedWithEpoch(_ texts: [String]) async throws -> MemoryEmbeddingBatch
}

public extension EmbeddingProvider {
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
//
// Deterministic synthetic embeddings: same input text always produces the same
// 384-d vector, and different inputs produce different vectors with very high
// probability (FNV-1a hash seeds a LCG that fills the vector, then L2-normalize).
//
// Useful for tests and for any forward-compat path that wants the embedding
// framework to be exercisable before the real Core ML model is packaged.
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

    private static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
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
//
// Throws on every `embed()` call with a canonical NativeAgentMemoryV2 / -100
// error. Replaces the prior "silently fall back to MockEmbeddingProvider"
// pattern in production wiring: random vectors looked successful while
// making memory recall return noise, which the user only noticed via degraded
// quality, not visible failure. Now the failure is loud and the caller's
// own error path (refuse to write the migration sentinel; surface to UI;
// retry on next launch) takes over. The dimensions / modelId fields stay
// populated so callers that inspect provider metadata before calling
// embed() (e.g. status panels) don't crash; only embed() throws.
public struct FailClosedEmbeddingProvider: EmbeddingProvider {
    public let dimensions: Int
    public let modelId: String = "fail-closed"

    public init(dimensions: Int = 384) {
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
        throw NSError(
            domain: "NativeAgentMemoryV2",
            code: -100,
            userInfo: [NSLocalizedDescriptionKey:
                "CoreML embedding model unavailable. Reinstall the app to "
                + "restore the bundled MiniLM, or set "
                + "NATIVE_AGENT_EMBEDDING_MOCK=1 to opt into deterministic "
                + "test vectors."]
        )
    }
}

// MARK: - CoreMLEmbeddingProvider
//
// Loads a .mlpackage from a known on-disk URL. This is the WIRING SPOT for the
// future MiniLM → Core ML drop:
//   1. Run script/convert_minilm_to_coreml.py (to be shipped) to produce
//      MiniLM_L6_v2.mlpackage.
//   2. Bundle the .mlpackage with the app (or stash it in Application Support).
//   3. Construct CoreMLEmbeddingProvider(modelURL: <bundle URL>).
//
// Today the init() throws cleanly if the URL is malformed, has the wrong
// extension, or doesn't exist, and embed() throws .modelNotLoaded if anyone
// reaches it. This is intentional: we'd rather fail loudly than emit silently-
// wrong vectors from a placeholder tokenizer.
//
// Full validity (whether the .mlpackage actually loads under MLModel) is
// DEFERRED until the real MiniLM .mlpackage drops — attempting MLModel.load
// today would be a no-op without a real artifact, so we only validate shape:
// file URL, known extension, exists on disk.
public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public static let allowedModelExtensions: Set<String> = ["mlpackage", "mlmodelc", "mlmodel"]
    private static let bundledEpochLock = NSLock()
    nonisolated(unsafe) private static var cachedDefaultBundledEpoch: MemoryEmbeddingEpoch?

    public let dimensions: Int
    public let modelId: String
    public let embeddingEpoch: MemoryEmbeddingEpoch
    private let modelURL: URL
    private let modelLoaded: Bool
    private let tokenizer: WordPieceTokenizer?
    private let maxSeqLength: Int
    #if canImport(CoreML) && !os(Linux)
    private let mlModel: MLModel?
    #endif

    /// A5.4 escape hatch: which `MLModelConfiguration` (if any) the model load
    /// should use. `nil` means "hand `MLModel(contentsOf:)` no configuration at
    /// all" — byte-for-byte the pre-A5.4 load, so nothing changes when
    /// low-memory mode is off. Low-memory mode pins `.cpuOnly`, keeping MiniLM
    /// off the GPU/ANE residency pools; 8 GB Macs previously had no way to cap
    /// that footprint. Pure function so the selection itself is pinned by tests.
    #if canImport(CoreML) && !os(Linux)
    public static func modelConfiguration(lowMemory: Bool) -> MLModelConfiguration? {
        guard lowMemory else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return configuration
    }

    private static func loadModel(at url: URL, configuration: MLModelConfiguration?) throws -> MLModel {
        guard let configuration else { return try MLModel(contentsOf: url) }
        return try MLModel(contentsOf: url, configuration: configuration)
    }
    #endif

    /// - Parameter lowMemory: when true the CoreML model is loaded with
    ///   `computeUnits = .cpuOnly`. Read at model-LOAD time only — see
    ///   `ManagedEmbeddingProvider.setMemoryMode`, which drops a resident model
    ///   when the selection flips so the next embed reloads under the new units.
    public init(
        modelURL: URL,
        vocabURL: URL? = nil,
        dimensions: Int = 384,
        modelId: String = "all-MiniLM-L6-v2",
        maxSeqLength: Int = 128,
        lowMemory: Bool = false
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
        self.embeddingEpoch = try Self.epoch(
            modelURL: modelURL,
            vocabURL: vocabURL,
            dimensions: dimensions,
            modelID: modelId,
            maximumSequenceLength: maxSeqLength
        )

        #if canImport(CoreML) && !os(Linux)
        // F2: .mlpackage cannot be loaded by MLModel(contentsOf:) directly —
        // it must be compiled to .mlmodelc first. The CoreMLEmbedderTests
        // parity harness already calls MLModel.compileModel(at:) for the same
        // reason. Mirror that here: compile .mlpackage on first init, cache
        // the compiled artifact in tmp so subsequent boots skip the compile,
        // and load the .mlmodelc result. .mlmodelc inputs skip compile.
        //
        // SELF-HEALING (2026-07-12, User's broken-panel incident): an install
        // restarting the app can race two processes through this cache — the
        // dying one mid-compile, the new one trusting a half-written slot by
        // mtime. A cache-load failure therefore wipes the slot and recompiles
        // ONCE from the pristine bundled .mlpackage before giving up, and the
        // real underlying error is preserved instead of swallowed.
        var loadedModel: MLModel?
        var loadFailure: Error?
        // A5.4: nil configuration == the untouched CoreML default path.
        let configuration = Self.modelConfiguration(lowMemory: lowMemory)
        do {
            let urlToLoad: URL
            if ext == "mlpackage" {
                urlToLoad = try Self.compileAndCache(packageURL: modelURL)
            } else {
                urlToLoad = modelURL
            }
            loadedModel = try Self.loadModel(at: urlToLoad, configuration: configuration)
        } catch {
            loadFailure = error
            if ext == "mlpackage" {
                Self.wipeCompileCache(packageURL: modelURL)
                do {
                    let recompiled = try Self.compileAndCache(packageURL: modelURL)
                    loadedModel = try Self.loadModel(at: recompiled, configuration: configuration)
                    loadFailure = nil
                } catch {
                    loadFailure = error
                }
            }
        }
        self.mlModel = loadedModel
        if let vurl = vocabURL, FileManager.default.fileExists(atPath: vurl.path) {
            self.tokenizer = try? WordPieceTokenizer(vocabURL: vurl)
        } else {
            self.tokenizer = nil
        }
        self.modelLoaded = (loadedModel != nil && self.tokenizer != nil)
        #else
        let loadFailure: Error? = nil
        self.tokenizer = nil
        self.modelLoaded = false
        #endif
        if !modelLoaded {
            // Init succeeded as a shape check (file exists, valid extension)
            // but inference will throw. Under the current fail-closed
            // contract this surfaces as a runtime embed() failure unless the
            // caller has explicitly opted into mock vectors via config or
            // NATIVE_AGENT_EMBEDDING_MOCK=1.
            let underlying = loadFailure.map { " Underlying: \(String(describing: $0))" } ?? ""
            let missing = (mlModel == nil ? "MLModel" : "WordPiece vocab")
            throw EmbeddingError.modelNotLoaded(
                reason: "CoreMLEmbeddingProvider could not load \(missing) at \(modelURL.path).\(underlying)"
            )
        }
    }

    private static func epoch(
        modelURL: URL,
        vocabURL: URL?,
        dimensions: Int,
        modelID: String,
        maximumSequenceLength: Int
    ) throws -> MemoryEmbeddingEpoch {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory)
        let modelDigest = try isDirectory.boolValue
            ? MemoryEmbeddingEpoch.sha256(directory: modelURL)
            : MemoryEmbeddingEpoch.sha256(file: modelURL)
        let tokenizerDigest: String
        if let vocabURL {
            tokenizerDigest = try MemoryEmbeddingEpoch.sha256(file: vocabURL)
        } else {
            tokenizerDigest = "missing"
        }
        return MemoryEmbeddingEpoch(
            backend: "coreml",
            modelID: modelID,
            modelArtifactDigest: modelDigest,
            tokenizerArtifactDigest: tokenizerDigest,
            preprocessing: "wordpiece-v1;lowercase=true;unicode=nfc;controls=strip;punctuation=split",
            pooling: "attention-mask-mean-or-model-pooled",
            normalization: "l2",
            dimensions: dimensions,
            maximumSequenceLength: maximumSequenceLength
        )
    }

    #if canImport(CoreML) && !os(Linux)
    /// Remove the cached compiled artifact so the next compileAndCache starts
    /// from the pristine bundled .mlpackage. Used by the self-healing retry
    /// above and by the Doctor repair action.
    public static func wipeCompileCache(packageURL: URL) {
        let base = packageURL.deletingPathExtension().lastPathComponent
        let cached = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NativeAgent", isDirectory: true)
            .appendingPathComponent("coreml", isDirectory: true)
            .appendingPathComponent("\(base).mlmodelc", isDirectory: true)
        try? FileManager.default.removeItem(at: cached)
    }
    #endif

    #if canImport(CoreML) && !os(Linux)
    /// F2: compile an .mlpackage to .mlmodelc, caching the compiled artifact in
    /// `<NSTemporaryDirectory>/NativeAgent/coreml/<basename>.mlmodelc`. If a
    /// cached copy already exists and is fresher than the .mlpackage manifest,
    /// returns it directly. Throws on compile failure; under the fail-closed
    /// contract that surfaces as a runtime embed() error unless the caller
    /// explicitly opted into mock vectors. Synchronous compile is acceptable
    /// here: the init path is rare (once per process) and not on @MainActor.
    fileprivate static func compileAndCache(packageURL: URL) throws -> URL {
        let fm = FileManager.default
        let base = packageURL.deletingPathExtension().lastPathComponent
        let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NativeAgent", isDirectory: true)
            .appendingPathComponent("coreml", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(base).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: cached.path) {
            // Validate freshness: if the .mlpackage's manifest mtime is newer
            // than the cached .mlmodelc, recompile.
            let manifest = packageURL.appendingPathComponent("Manifest.json")
            let manifestMtime = (try? fm.attributesOfItem(atPath: manifest.path)[.modificationDate]) as? Date
            let cacheMtime = (try? fm.attributesOfItem(atPath: cached.path)[.modificationDate]) as? Date
            if let mm = manifestMtime, let cm = cacheMtime, mm <= cm {
                return cached
            }
            if manifestMtime == nil || cacheMtime == nil {
                // Can't compare — trust the cache.
                return cached
            }
            // Stale — wipe and recompile.
            try? fm.removeItem(at: cached)
        }
        let compiled = try MLModel.compileModel(at: packageURL)
        // Move compiled artifact into our cache slot so the next boot skips
        // the compile entirely. moveItem fails if dest exists — we already
        // removed it above on the stale path.
        if fm.fileExists(atPath: cached.path) {
            try? fm.removeItem(at: cached)
        }
        do {
            try fm.moveItem(at: compiled, to: cached)
            return cached
        } catch {
            // Move failed (e.g. cross-volume) — fall back to using the
            // OS-tmp compile location directly. The MLModel load below will
            // still succeed.
            return compiled
        }
    }
    #endif

    /// Bundle-resolved factory. Looks up `minilm.mlpackage` and
    /// `minilm_vocab.txt` inside the given bundle (defaults to
    /// `Bundle.module`, which is the MemoryV2 target's resource bundle).
    public static func bundled(
        _ bundle: Bundle? = nil,
        lowMemory: Bool = false
    ) throws -> CoreMLEmbeddingProvider {
        let resolved = bundle ?? installedAppFallbackBundle() ?? Bundle.module
        guard let url = resolved.url(forResource: "minilm", withExtension: "mlpackage") else {
            throw EmbeddingError.modelNotFound(path: "Bundle.module/minilm.mlpackage")
        }
        let vocab = resolved.url(forResource: "minilm_vocab", withExtension: "txt")
        return try CoreMLEmbeddingProvider(modelURL: url, vocabURL: vocab, lowMemory: lowMemory)
    }

    public static func bundledEmbeddingEpoch(_ bundle: Bundle? = nil) throws -> MemoryEmbeddingEpoch {
        if bundle == nil {
            bundledEpochLock.lock()
            let cached = cachedDefaultBundledEpoch
            bundledEpochLock.unlock()
            if let cached { return cached }
        }
        let resolved = bundle ?? installedAppFallbackBundle() ?? Bundle.module
        guard let url = resolved.url(forResource: "minilm", withExtension: "mlpackage") else {
            throw EmbeddingError.modelNotFound(path: "Bundle.module/minilm.mlpackage")
        }
        let resolvedEpoch = try epoch(
            modelURL: url,
            vocabURL: resolved.url(forResource: "minilm_vocab", withExtension: "txt"),
            dimensions: 384,
            modelID: "all-MiniLM-L6-v2",
            maximumSequenceLength: 128
        )
        if bundle == nil {
            bundledEpochLock.lock()
            if let cached = cachedDefaultBundledEpoch {
                bundledEpochLock.unlock()
                return cached
            }
            cachedDefaultBundledEpoch = resolvedEpoch
            bundledEpochLock.unlock()
        }
        return resolvedEpoch
    }

    /// Wipe the compile cache for the BUNDLED model (Doctor repair action).
    /// Resolves the same bundle bundled() would, so callers outside this
    /// module never need the private bundle-fallback plumbing.
    public static func wipeBundledCompileCache(_ bundle: Bundle? = nil) {
        #if canImport(CoreML) && !os(Linux)
        let resolved = bundle ?? installedAppFallbackBundle() ?? Bundle.module
        if let pkg = resolved.url(forResource: "minilm", withExtension: "mlpackage") {
            wipeCompileCache(packageURL: pkg)
        }
        #endif
    }

    /// Cheap bundle-resource probe used by Settings/status. This intentionally
    /// does not compile or load the CoreML model, so merely opening Settings
    /// cannot pull the model into memory.
    public static func bundledResourcesAvailable(_ bundle: Bundle? = nil) -> Bool {
        let resolved = bundle ?? installedAppFallbackBundle() ?? Bundle.module
        return resolved.url(forResource: "minilm", withExtension: "mlpackage") != nil
            && resolved.url(forResource: "minilm_vocab", withExtension: "txt") != nil
    }

    /// 2026-06-07 task #88: installed-app shape fallback.
    ///
    /// SPM synthesizes `Bundle.module` to look for `<Pkg>_<Tgt>.bundle` at
    /// `Bundle.main.bundleURL` (next to Contents/) — that's the .build/
    /// layout. For a codesigned macOS .app, putting `.bundle` directories
    /// at the .app top level breaks the strict codesign bundle-layout
    /// check, so the only safe staging location is `Contents/Resources/`.
    /// This fallback returns a Bundle pointed at
    /// `Contents/Resources/NativeAgentCore_MemoryV2.bundle` when that
    /// directory exists; nil otherwise (dev builds fall through to
    /// Bundle.module's hardcoded .build/ path).
    private static func installedAppFallbackBundle() -> Bundle? {
        let mainResources = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let stagedPath = mainResources
            .appendingPathComponent("NativeAgentCore_MemoryV2.bundle", isDirectory: true)
            .path
        guard FileManager.default.fileExists(atPath: stagedPath) else { return nil }
        return Bundle(path: stagedPath)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        if !modelLoaded {
            // Reason copy reflects the fail-closed contract — the caller
            // surfaces this error; mock is opt-in only (config backend=mock
            // OR NATIVE_AGENT_EMBEDDING_MOCK=1).
            throw EmbeddingError.modelNotLoaded(
                reason: "CoreMLEmbeddingProvider not loaded; embed() fails closed unless config or NATIVE_AGENT_EMBEDDING_MOCK opts into mock vectors."
            )
        }
        #if canImport(CoreML) && !os(Linux)
        guard let model = mlModel, let tok = tokenizer else {
            throw EmbeddingError.modelNotLoaded(reason: "model or tokenizer missing")
        }
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let (ids, mask) = tok.encode(text, maxLength: maxSeqLength)
            let inputArr = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLength)], dataType: .int32)
            let maskArr = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLength)], dataType: .int32)
            for i in 0..<maxSeqLength {
                inputArr[i] = NSNumber(value: i < ids.count ? Int32(ids[i]) : 0)
                maskArr[i] = NSNumber(value: i < mask.count ? Int32(mask[i]) : 0)
            }
            // Try standard MiniLM CoreML input names. If the model rejects
            // them we surface modelNotLoaded — under the fail-closed contract
            // that propagates up to the caller as an embed() error unless the
            // user explicitly opted into mock vectors.
            let provider: MLFeatureProvider
            do {
                provider = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: inputArr),
                    "attention_mask": MLFeatureValue(multiArray: maskArr),
                ])
            } catch {
                throw EmbeddingError.modelNotLoaded(reason: "could not build input feature provider: \(error)")
            }
            let out: MLFeatureProvider
            do {
                out = try await model.prediction(from: provider)
            } catch {
                throw EmbeddingError.modelNotLoaded(reason: "CoreML prediction failed: \(error)")
            }
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
        _ = texts
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
        // Unexpected shape (model/config dimension skew): fail closed. The
        // old fallback flat-took the first `dim` floats — a valid-looking
        // garbage vector that poisons recall silently, exactly what this
        // file's fail-closed doctrine forbids (audit 2026-06-09).
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
    case dimensionMismatch(expected: Int, got: Int)
    case invalidModelURL(reason: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let p): return "embedding model not found at \(p)"
        case .modelNotLoaded(let r): return "embedding model not loaded: \(r)"
        case .dimensionMismatch(let e, let g): return "embedding dimension mismatch: expected \(e), got \(g)"
        case .invalidModelURL(let r): return "invalid embedding model URL: \(r)"
        }
    }
}

// MARK: - EmbeddingStore protocol

public protocol EmbeddingStore: Sendable {
    func upsert(id: String, embedding: [Float], text: String) async throws
    func get(id: String) async throws -> (embedding: [Float], text: String)?
    func delete(id: String) async throws
    func search(query: [Float], topK: Int) async throws -> [(id: String, score: Float, text: String)]
}

// MARK: - JSONLEmbeddingStore (on-disk linear-scan backend)
//
// One JSONL line per record: {"id": ..., "text": ..., "embedding": [Float...]}.
// upsert dedupes by id via an in-memory map and rewrites the file on overwrite.
// search() computes cosine similarity against every record; suitable for the
// ~10k-record scale Phase B needs. Phase C will replace search() with a Core
// Spotlight query backend; the protocol is the seam.
public actor JSONLEmbeddingStore: EmbeddingStore {
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var text: String
        public var embedding: [Float]
    }

    private let path: URL
    private var records: [String: Record] = [:]
    private var loaded = false
    /// U5 W-G corrupt-preserve fix (2026-06-11): raw lines that failed to
    /// decode on load. Previously these were silently skipped on load AND
    /// then permanently destroyed by the next `flush()` full-file rewrite.
    /// Now they're carried verbatim and re-written at the end of the file
    /// so a decode bug or torn write never silently deletes data.
    private var preservedUndecodableLines: [Data] = []
    private let persistence: SwiftNativePersistenceCore

    public init(path: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.path = path
        self.persistence = persistence
    }

    // MARK: per-path coordination
    //
    // Two-layer locking (lock-unification fix, 2026-05-31):
    //
    //   Layer 1 (in-process, PathLockRegistry): serializes two
    //     JSONLEmbeddingStore actors in THIS process that point at the
    //     same file. Without it each would load a stale in-memory snapshot,
    //     mutate it, and last-writer-wins truncate the other on flush.
    //
    //   Layer 2 (cross-process, SwiftNativePersistenceCore.withFileLock):
    //     serializes against other Swift processes that write
    //     <dataRoot>/memory_embeddings.jsonl. Without it a write that lands
    //     between our read and our atomic replace would be silently truncated.
    //     Same `<path>.lock` sibling convention the
    //     JSONLMemoryConsolidationRecaller (now thinly wrapping this
    //     store) use.
    //
    // Order matters: in-process FIRST, flock SECOND. Reversing would risk
    // an unbounded queue of process-local tasks all racing for one flock,
    // and flock(2) on macOS is per open-file-description (NOT reentrant
    // across fds in the same process) — so nesting two withFileLock calls
    // on the same path would deadlock. The recaller therefore CALLS this
    // store's public methods rather than holding its own flock.
    //
    // Implementation of Layer 1: an actor-based async semaphore keyed by
    // standardized path string. NSLock is unsuitable because NSLock.lock()
    // is unavailable from async contexts under Swift 6 concurrency.
    fileprivate actor PathLockRegistry {
        static let shared = PathLockRegistry()
        private var held: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(_ key: String) async {
            if !held.contains(key) {
                held.insert(key)
                return
            }
            await withCheckedContinuation { cont in
                waiters[key, default: []].append(cont)
            }
            // On resume, ownership is handed off directly — `held` already
            // contains `key`, the releaser did not clear it.
        }

        func release(_ key: String) {
            if var queue = waiters[key], !queue.isEmpty {
                let next = queue.removeFirst()
                if queue.isEmpty {
                    waiters.removeValue(forKey: key)
                } else {
                    waiters[key] = queue
                }
                next.resume()
            } else {
                held.remove(key)
            }
        }
    }

    private func withPathLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let key = path.standardizedFileURL.path
        await PathLockRegistry.shared.acquire(key)
        do {
            // In-process lock held; now take the cross-process flock around
            // the actual I/O so the daemon (or any peer Swift process) using
            // the same `<path>.lock` convention serializes with us.
            let r = try await persistence.withFileLock(path) {
                try await body()
            }
            await PathLockRegistry.shared.release(key)
            return r
        } catch {
            await PathLockRegistry.shared.release(key)
            throw error
        }
    }

    private func loadIfNeeded() throws {
        if loaded { return }
        loaded = true
        records.removeAll()
        preservedUndecodableLines.removeAll()
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        for line in lines {
            guard !line.isEmpty else { continue }
            if let rec = try? decoder.decode(Record.self, from: Data(line)) {
                records[rec.id] = rec
            } else {
                // U5 W-G corrupt-preserve: keep the undecodable bytes so the
                // next flush() rewrite doesn't destroy them. Loud, not silent.
                preservedUndecodableLines.append(Data(line))
            }
        }
        if !preservedUndecodableLines.isEmpty {
            NSLog("JSONLEmbeddingStore: preserved %d undecodable line(s) in %@ (will be re-written verbatim on flush)",
                  preservedUndecodableLines.count, path.lastPathComponent)
        }
    }

    private func flush() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var buf = Data()
        for rec in records.values {
            let line = try encoder.encode(rec)
            buf.append(line)
            buf.append(0x0A)
        }
        // U5 W-G corrupt-preserve: carry lines we couldn't decode at load
        // time through the rewrite instead of dropping them.
        for line in preservedUndecodableLines {
            buf.append(line)
            buf.append(0x0A)
        }
        try buf.write(to: path, options: .atomic)
    }

    public func upsert(id: String, embedding: [Float], text: String) async throws {
        try await withPathLock {
            try await self._upsertLocked(id: id, embedding: embedding, text: text)
        }
    }

    public func get(id: String) async throws -> (embedding: [Float], text: String)? {
        try await withPathLock {
            try await self._getLocked(id: id)
        }
    }

    public func delete(id: String) async throws {
        try await withPathLock {
            try await self._deleteLocked(id: id)
        }
    }

    public func search(query: [Float], topK: Int) async throws -> [(id: String, score: Float, text: String)] {
        try await withPathLock {
            try await self._searchLocked(query: query, topK: topK)
        }
    }

    /// Read-only snapshot of every record currently on disk, force-reloading
    /// from the file under the same two-layer lock used by writers.
    /// Added (2026-05-31) for JSONLMemoryConsolidationRecaller so the
    /// MemoryConsolidationLoop can enumerate records WITHOUT doing raw file
    /// I/O outside the store — that was the duplicate-impl drift this
    /// unification fixes. Exposes the immutable `Record` struct rather
    /// than tuples so the recaller's ConsolidationCandidate mapping stays
    /// strongly typed.
    public func allRecords() async throws -> [Record] {
        try await withPathLock {
            try await self._allRecordsLocked()
        }
    }

    // MARK: actor-isolated work bodies
    //
    // The withPathLock body must be @Sendable (it crosses into
    // persistence.withFileLock's detached open/flock task), so it can't
    // capture actor-isolated state directly. These _xxxLocked helpers ARE
    // actor-isolated and called via `await self?._xxxLocked(...)`; the
    // outer @Sendable closure only retains a weak self and re-enters the
    // actor for the actual work.

    private func _upsertLocked(id: String, embedding: [Float], text: String) throws {
        // Force a re-read so we observe writes from any peer instance (or
        // peer process) on the same path before mutating + flushing.
        loaded = false
        try loadIfNeeded()
        records[id] = Record(id: id, text: text, embedding: embedding)
        try flush()
    }

    private func _getLocked(id: String) throws -> (embedding: [Float], text: String)? {
        loaded = false
        try loadIfNeeded()
        guard let r = records[id] else { return nil }
        return (r.embedding, r.text)
    }

    private func _deleteLocked(id: String) throws {
        loaded = false
        try loadIfNeeded()
        guard records.removeValue(forKey: id) != nil else { return }
        try flush()
    }

    private func _searchLocked(query: [Float], topK: Int) throws -> [(id: String, score: Float, text: String)] {
        loaded = false
        try loadIfNeeded()
        guard topK > 0, !query.isEmpty else { return [] }
        var scored: [(id: String, score: Float, text: String)] = []
        scored.reserveCapacity(records.count)
        for rec in records.values {
            // Surface dimension mismatches loudly instead of silently
            // truncating to the shorter prefix — a 3-d stored vector vs
            // a 5-d query is a model/version skew, not a valid comparison.
            if rec.embedding.count != query.count {
                throw EmbeddingError.dimensionMismatch(expected: rec.embedding.count, got: query.count)
            }
            let s = Self.cosine(query, rec.embedding)
            scored.append((rec.id, s, rec.text))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK))
    }

    private func _allRecordsLocked() throws -> [Record] {
        loaded = false
        try loadIfNeeded()
        // Map.values is unordered; sort by id for deterministic output so
        // the consolidation loop's union-find walk is reproducible.
        return records.values.sorted { $0.id < $1.id }
    }

    // Single source of truth: VectorMath.cosine (Double, finiteness-guarded,
    // equal-length required). This surface historically returned a NaN-unguarded
    // Float over min(count) — same-model embeddings are always equal length, so
    // the guard only hardens the pathological cases. Score stays Float.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        Float(VectorMath.cosine(a, b))
    }
}

// MARK: - SwiftNativeMemoryRecaller
//
// Composes an EmbeddingProvider + EmbeddingStore into a recall surface that
// mirrors the daemon's `/v1/memory/recall` return shape (MemoryRecallHit).
//
// The production SQLite-backed MemoryV2 path now does hybrid dense+BM25
// retrieval. This older JSONL recaller remains the bare embedding-only surface
// for fixture/framework tests and callers that explicitly wire an EmbeddingStore.
public actor SwiftNativeMemoryRecaller {
    private let embedder: any EmbeddingProvider
    private let store: any EmbeddingStore

    public init(embedder: any EmbeddingProvider, store: any EmbeddingStore) {
        self.embedder = embedder
        self.store = store
    }

    public func index(id: String, text: String) async throws {
        let vecs = try await embedder.embed([text])
        guard let v = vecs.first else {
            throw EmbeddingError.modelNotLoaded(reason: "embedder returned no vectors")
        }
        try await store.upsert(id: id, embedding: v, text: text)
    }

    public func remove(id: String) async throws {
        try await store.delete(id: id)
    }

    public func recall(_ query: String, k: Int = 10) async throws -> [MemoryRecallHit] {
        let vecs = try await embedder.embed([query])
        guard let q = vecs.first else { return [] }
        let results = try await store.search(query: q, topK: k)
        return results.map { row in
            let displayText = MemoryTextClip.memoryDisplayText(row.text)
            // U3 wave-1 item 1: sentence-clipped preview (no mid-word chop)
            // + full text on `content`. Output shaping only — row selection
            // and scores are unchanged.
            return MemoryRecallHit(
                score: Double(row.score),
                sessionId: nil,
                role: nil,
                ts: nil,
                preview: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallPreviewCap),
                content: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap),
                source: "swift-native",
                rankingSignals: nil,
                extras: .object(["id": .string(row.id)])
            )
        }
    }
}
