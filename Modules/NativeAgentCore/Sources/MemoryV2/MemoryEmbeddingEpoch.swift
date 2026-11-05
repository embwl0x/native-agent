import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `MemoryEmbeddingEpoch.swift` | vector-space identity, item outcomes and owned convergence |

/// Immutable identity of one vector space. Dimensions alone are deliberately insufficient: backend, model/tokenizer artifacts, preprocessing, pooling,
/// normalization, and sequence length all participate in compatibility.
public struct MemoryEmbeddingEpoch: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    public static let activationProbeText = "NativeAgent embedding epoch activation"
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

    /// Length-prefix directory digest fields with big-endian 64-bit lengths to keep framing unambiguous.
    private static func byteLength(_ count: Int) -> Data {
        var big = UInt64(count).bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func sha256(directory url: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files = try FileManager.default.subpathsOfDirectory(atPath: url.path)
            .map { url.appendingPathComponent($0) }
            .filter { try $0.resourceValues(forKeys: Set(keys)).isRegularFile == true }
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

/// A prediction can be unusable for one text without losing its siblings. Transport, model and output-contract failures still throw for the call.
public enum MemoryEmbeddingItem: Sendable, Equatable {
    case vector([Float])
    case unembeddable(reason: String)
}

public struct MemoryEmbeddingItemBatch: Sendable {
    public let epoch: MemoryEmbeddingEpoch
    public let items: [MemoryEmbeddingItem]

    public init(epoch: MemoryEmbeddingEpoch, items: [MemoryEmbeddingItem]) {
        self.epoch = epoch
        self.items = items
    }

    /// Callers requiring every vector get an explicit indexed error, never a shortened batch or a manufactured vector.
    func requireVectors() throws -> [[Float]] {
        try items.enumerated().map { index, item in
            switch item {
            case .vector(let vector): return vector
            case .unembeddable(let reason):
                throw MemoryStorageError.searchFailure("Text at batch index \(index) is unembeddable: \(reason)",
                    code: "memory_text_unembeddable", instruction: "Inspect the named text and model output; no replacement vector was used.")
            }
        }
    }
}

extension SwiftNativeMemoryV2 {
    @discardableResult
    public func reconcileEmbeddingEpochAtLaunch() async -> Bool {
        await requestEmbeddingEpochReconcile()?.value ?? false
    }

    /// One housekeeping flight converges the corpus for launch, model install and recall (which never waits); a request mid-pass earns one more pass.
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

    /// Rows written while the model was cold get their vectors here, each through the checks a warm write passes (`landOwedVector`).
    private func fillOwedMemoryVectors() async throws {
        guard let embedder, let disk = storage else { throw MemoryV2Error.storageUnavailable }
        try checkEmbeddingConvergence()
        while true {
            let owed = try await disk.memoriesOwingVectors(limit: 32, epoch: embedder.embeddingEpoch)
            try checkEmbeddingConvergence()
            guard !owed.isEmpty else { return }
            let batch = try await embedder.embedItemsWithEpoch(owed.map(\.content))
            try checkEmbeddingConvergence()
            guard batch.items.count == owed.count else {
                throw MemoryV2Error.underlying("embedder returned \(batch.items.count)/\(owed.count) owed outcomes")
            }
            var moved = 0
            for (row, item) in zip(owed, batch.items) {
                switch item {
                case .unembeddable(let reason):
                    if try await disk.recordUnembeddable(MemoryEmbeddingCorpusRow(kind: .memory, id: row.id, content: row.content), epoch: batch.epoch,
                        reason: reason) {
                        nativeLog("[memory-epoch] unembeddable memory %@: %@", row.id, reason)
                        moved += 1
                    }
                    try checkEmbeddingConvergence()
                case .vector(let vector):
                    try VectorMath.requireUsable(vector, dimensions: embedder.dimensions)
                    let outcome = try await disk.landOwedVector(id: row.id, content: row.content, vector: vector, epoch: batch.epoch)
                    try checkEmbeddingConvergence()
                    if case .archived(let reason) = outcome { nativeLog("[memory-epoch] archived %@: %@", row.id, reason) }
                    if case .superseded = outcome { continue }
                    moved += 1
                }
            }
            // Newer writes own unchanged rows and request their own fills.
            guard moved > 0 else { return }
        }
    }

    /// Forget can win before an active row's vector lands. Tombstones are canonical claims too, filled in the same epoch without reindexing.
    private func fillOwedTombstoneVectors() async throws {
        guard let embedder, let disk = storage else { throw MemoryV2Error.storageUnavailable }
        while true {
            try checkEmbeddingConvergence()
            let owed = try await disk.tombstonesOwingVectors(limit: 32, epoch: embedder.embeddingEpoch)
            try checkEmbeddingConvergence()
            guard !owed.isEmpty else { return }
            let batch = try await embedder.embedItemsWithEpoch(owed.map(\.content))
            try checkEmbeddingConvergence()
            guard batch.items.count == owed.count else {
                throw MemoryV2Error.underlying("embedder did not return every owed tombstone outcome")
            }
            var moved = 0
            for (row, item) in zip(owed, batch.items) {
                switch item {
                case .unembeddable(let reason):
                    if try await disk.recordUnembeddable(MemoryEmbeddingCorpusRow(kind: .tombstone, id: row.hash, content: row.content), epoch: batch.epoch,
                        reason: reason) {
                        nativeLog("[memory-epoch] unembeddable tombstone %@: %@", row.hash, reason)
                        moved += 1
                    }
                    try checkEmbeddingConvergence()
                case .vector(let vector):
                    try VectorMath.requireUsable(vector, dimensions: embedder.dimensions)
                    if try await disk.landOwedTombstoneVector(hash: row.hash, content: row.content, vector: vector, epoch: batch.epoch) { moved += 1 }
                    try checkEmbeddingConvergence()
                }
            }
            guard moved > 0 else { return }
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
            if state.activeEpoch != providerEpoch.rawValue || state.dimensions != embedder?.dimensions
                || state.activationFailure?.epoch == providerEpoch.rawValue,
               let report = try await reconcileMemoryEmbeddingEpoch() {
                try checkEmbeddingConvergence()
                nativeLog("[memory-epoch] activated %@ across %d canonical rows; %d unembeddable", report.epoch, report.total, report.unembeddable)
            }
            try await fillOwedTombstoneVectors()
            try await fillOwedMemoryVectors()
            try checkEmbeddingConvergence()
            return true
        } catch is CancellationError {
            return false
        } catch {
            nativeLog("[memory-epoch] convergence failed: %@", String(describing: error))
            return false
        }
    }
}
