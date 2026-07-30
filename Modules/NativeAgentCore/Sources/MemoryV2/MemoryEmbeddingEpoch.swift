import CryptoKit
import Foundation

/// Immutable identity of one vector space. Dimensions alone are deliberately
/// insufficient: backend, model/tokenizer artifacts, preprocessing, pooling,
/// normalization, and sequence length all participate in compatibility.
public struct MemoryEmbeddingEpoch: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(
        backend: String,
        modelID: String,
        modelArtifactDigest: String,
        tokenizerArtifactDigest: String,
        preprocessing: String,
        pooling: String,
        normalization: String,
        dimensions: Int,
        maximumSequenceLength: Int?
    ) {
        let canonical = [
            "schema=nativeagent.memory-embedding-epoch.v1",
            "backend=\(backend)",
            "model_id=\(modelID)",
            "model_artifact_sha256=\(modelArtifactDigest)",
            "tokenizer_artifact_sha256=\(tokenizerArtifactDigest)",
            "preprocessing=\(preprocessing)",
            "pooling=\(pooling)",
            "normalization=\(normalization)",
            "dimensions=\(dimensions)",
            "maximum_sequence_length=\(maximumSequenceLength.map(String.init) ?? "none")",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.rawValue = "memory-embedding-v1:\(digest)"
    }

    static func sha256(file url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256(directory url: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file, options: [.mappedIfSafe]))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct MemoryEmbeddingBatch: Sendable, Equatable {
    public let epoch: MemoryEmbeddingEpoch
    public let vectors: [[Float]]

    public init(epoch: MemoryEmbeddingEpoch, vectors: [[Float]]) {
        self.epoch = epoch
        self.vectors = vectors
    }
}
