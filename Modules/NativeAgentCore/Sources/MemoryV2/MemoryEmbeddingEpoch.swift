import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `MemoryEmbeddingEpoch.swift` | `MemoryEmbeddingEpoch`, `MemoryEmbeddingBatch`; engine-stopped epoch reconciliation on the canonical memory owner, including same-epoch vector-pending tombstones before active memory admission; admission retained through actual flight exit |

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

    /// Big-endian 64-bit length prefix — the frame marker for the directory
    /// digest below.
    private static func byteLength(_ count: Int) -> Data {
        var big = UInt64(count).bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
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
            let path = Data(relative.utf8)
            let contents = try Data(contentsOf: file, options: [.mappedIfSafe])
            // Length-prefixed framing keeps distinct model directories distinct even when file contents contain NULs.
            hasher.update(data: byteLength(path.count))
            hasher.update(data: path)
            hasher.update(data: byteLength(contents.count))
            hasher.update(data: contents)
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

extension SwiftNativeMemoryV2 {
    @discardableResult
    public func reconcileEmbeddingEpochAtLaunch() async -> Bool {
        await requestEmbeddingEpochReconcile()?.value ?? false
    }

    /// One housekeeping flight converges the corpus for launch, model install
    /// and recall (which never waits); a request mid-pass earns one more pass.
    @discardableResult
    func requestEmbeddingEpochReconcile() -> Task<Bool, Never>? {
        guard !embeddingConvergenceStopped else { return nil }
        embeddingEpochDirty = true
        if let flight = embeddingEpochReconcile { return flight }
        let flight = Task(priority: .utility) { () -> Bool in
            defer { embeddingEpochReconcile = nil }
            var converged = false
            while !embeddingConvergenceStopped, !Task.isCancelled, embeddingEpochDirty {
                embeddingEpochDirty = false
                converged = await convergeEmbeddingEpoch()
            }
            return !embeddingConvergenceStopped && !Task.isCancelled && converged
        }
        embeddingEpochReconcile = flight
        return flight
    }

    /// Rows written while the model was cold get their vectors here, each
    /// through the checks a warm write passes (`landOwedVector`).
    private func fillOwedMemoryVectors() async throws {
        guard let embedder, let disk = storage else { throw MemoryV2Error.storageUnavailable }
        try checkEmbeddingConvergence()
        while true {
            let owed = try await disk.memoriesOwingVectors(limit: 32)
            try checkEmbeddingConvergence()
            guard !owed.isEmpty else { return }
            let batch = try await embedder.embedWithEpoch(owed.map(\.content))
            try checkEmbeddingConvergence()
            guard batch.vectors.count == owed.count else {
                throw MemoryV2Error.underlying("embedder returned \(batch.vectors.count)/\(owed.count) owed vectors")
            }
            var moved = 0
            for (row, vector) in zip(owed, batch.vectors) where !vector.isEmpty {
                let outcome = try await disk.landOwedVector(id: row.id, content: row.content, vector: vector, epoch: batch.epoch)
                try checkEmbeddingConvergence()
                if case .archived(let reason) = outcome { nativeLog("[memory-epoch] archived %@: %@", row.id, reason) }
                if case .superseded = outcome { continue }
                moved += 1
            }
            // Nothing moved: newer writes own these rows; their own request fills them.
            guard moved > 0 else { return }
        }
    }

    /// Forget can win before an active row's vector lands. Tombstones are
    /// canonical claims too, filled in the same epoch without reindexing.
    private func fillOwedTombstoneVectors() async throws {
        guard let embedder, let disk = storage else { throw MemoryV2Error.storageUnavailable }
        while true {
            try checkEmbeddingConvergence()
            let owed = try await disk.tombstonesOwingVectors(limit: 32)
            guard !owed.isEmpty else { return }
            let batch = try await embedder.embedWithEpoch(owed.map(\.content))
            try checkEmbeddingConvergence()
            guard batch.vectors.count == owed.count, batch.vectors.allSatisfy({ !$0.isEmpty }) else {
                throw MemoryV2Error.underlying("embedder did not return every owed tombstone vector")
            }
            for (row, vector) in zip(owed, batch.vectors) {
                _ = try await disk.landOwedTombstoneVector(hash: row.hash, content: row.content, vector: vector, epoch: batch.epoch)
                try checkEmbeddingConvergence()
            }
        }
    }

    private func convergeEmbeddingEpoch() async -> Bool {
        do {
            try checkEmbeddingConvergence()
            try await warmUpEmbedder()
            try checkEmbeddingConvergence()
            let state = try await memoryEmbeddingEpochState()
            try checkEmbeddingConvergence()
            guard let providerEpoch = embeddingEpoch() else {
                return false
            }
            if state.activeEpoch != providerEpoch.rawValue,
               let report = try await reconcileMemoryEmbeddingEpoch() {
                try checkEmbeddingConvergence()
                nativeLog("[memory-epoch] activated %@ across %d canonical rows", report.epoch, report.total)
            }
            try await fillOwedTombstoneVectors()
            try await fillOwedMemoryVectors()
            try checkEmbeddingConvergence()
            return true
        } catch is CancellationError {
            return false
        } catch {
            nativeLog("[memory-epoch] activation failed; prior corpus retained: %@", String(describing: error))
            return false
        }
    }
}
