import Foundation
import CryptoKit
import NativeAgentCore

// Blueprint: | `AfterTurnMemorySurprise.swift` | `AfterTurnMemorySurprise`: the agent's own learned prediction that a turn's interpretation would be a COMPLETE no-op: language-independent, fully covered warm-vector precedents from its labelled record, keyed by agent, memory model and detector version, with the cost law's standing |

/// A prediction about ALL interpretation channels (memories, affect, caring,
/// cares), never permission to forget a turn: a deferred turn stays owed in
/// the lived-moment journal and is judged later (docs/COGNITION_WIRING.md,
/// "Deferral").
public struct AfterTurnMemorySurprise: Codable, Sendable, Equatable {
    /// Bumped whenever the detector's meaning changes: labels earned under an
    /// older detector never grant standing to this one.
    public static let detectorVersion = 3
    public enum Verdict: String, Codable, Sendable { case nothingNew, somethingNew, unsure }
    /// Whose record a prediction is scored against: the agent, the memory
    /// model that judges it (route key), the detector version.
    public struct Scope: Codable, Sendable, Equatable, Hashable {
        public let agent: String
        public let model: String
        public let detector: Int
    }
    public let verdict: Verdict
    public let reason: String
    public let epoch: String?
    public private(set) var scope: Scope?
    /// The frozen claim this prediction belongs to (precedent + its contrast
    /// population); standing is earned per claim.
    public let rule: String?
    public let at: Date?
    public private(set) var vectors: [[Float]]?
    /// True only when the cost law grants deferral (`AfterTurnSurpriseLedger.predict`).
    public let standing: Bool?
    public let lowerBound: Double?
    public let costBar: Double?
    public let tries: Int?
    public let hits: Int?

    static func unsure(_ reason: String) -> Self {
        Self(verdict: .unsure, reason: reason, epoch: nil, scope: nil, rule: nil,
             at: nil, vectors: nil, standing: false, lowerBound: nil, costBar: nil, tries: nil, hits: nil)
    }

    /// This prediction scored under the model that judged it (unchanged when
    /// unscoped or when no judging model is known).
    func judged(by model: String?) -> Self {
        guard let model, let scope, scope.model != model else { return self }
        var labelled = self
        labelled.scope = Scope(agent: scope.agent, model: model, detector: scope.detector)
        return labelled
    }

    func withoutVectors() -> Self {
        var bounded = self
        bounded.vectors = nil
        return bounded
    }

    static func fingerprint(_ values: [String]) -> String {
        let text = values.map { "\($0.utf8.count):" + $0 }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Full traversal, no language: split on Unicode scalar boundaries, then
    /// bisect until the resident embedder certifies every piece fits. The
    /// bounds cap optional CPU work, never natural language. Anything not
    /// fully covered is `unsure`, and an unsure turn is interpreted now.
    static func check(texts: [String], scope: Scope, memory: SwiftNativeMemoryV2,
                      dataRoot: URL, excluding turn: String) async -> Self {
        guard let epoch = await memory.warmEmbeddingEpoch() else { return .unsure("embedder_cold") }
        var pieces: [String] = []
        for text in texts where !text.isEmpty {
            let scalars = Array(text.unicodeScalars)
            guard scalars.count <= 65_536 else { return .unsure("coverage_exhausted") }
            for start in stride(from: 0, to: scalars.count, by: 512) {
                let end = min(start + 512, scalars.count)
                pieces.append(String(String.UnicodeScalarView(scalars[start..<end])))
            }
        }
        guard !pieces.isEmpty else { return .unsure("empty_input") }
        var vectors: [[Float]] = []
        var cursor = 0
        while cursor < pieces.count {
            guard pieces.count <= 128, !Task.isCancelled else { return .unsure("coverage_exhausted") }
            let piece = pieces[cursor]
            if await memory.coversCompleteTextsIfWarm([piece]) == true {
                cursor += 1
            } else {
                let scalars = Array(piece.unicodeScalars)
                guard scalars.count > 1, await memory.warmEmbeddingEpoch() == epoch else {
                    return .unsure("embedding_coverage_unavailable")
                }
                let middle = scalars.count / 2
                pieces.replaceSubrange(cursor...cursor, with: [
                    String(String.UnicodeScalarView(scalars[..<middle])),
                    String(String.UnicodeScalarView(scalars[middle...])),
                ])
            }
        }
        for start in stride(from: 0, to: pieces.count, by: 16) {
            guard !Task.isCancelled, await memory.warmEmbeddingEpoch() == epoch else {
                return .unsure("embedding_epoch_changed")
            }
            let inputs = Array(pieces[start..<min(start + 16, pieces.count)])
            guard let batch = await memory.embedIfWarm(inputs, requireFullText: true),
                  batch.count == inputs.count,
                  batch.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else {
                return .unsure("embedding_coverage_unavailable")
            }
            vectors.append(contentsOf: batch)
        }
        guard !Task.isCancelled, await memory.warmEmbeddingEpoch() == epoch,
              let dimension = vectors.first?.count,
              vectors.allSatisfy({ $0.count == dimension }) else { return .unsure("embedding_epoch_changed") }
        return await AfterTurnSurpriseLedger.shared.predict(dataRoot: dataRoot, scope: scope,
            epoch: epoch, vectors: vectors, excluding: turn)
    }
}

extension SwiftNativeMemoryV2 {
    func surpriseDataRoot() async -> URL? {
        if let canonicalDataRoot { return canonicalDataRoot }
        if let storage {
            let directory = storage.path.deletingLastPathComponent()
            guard directory.lastPathComponent == "memory" else { return nil }
            return directory.deletingLastPathComponent()
        }
        return nil
    }
}
