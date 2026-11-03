import Foundation

// Blueprint: | `VectorMath.swift` | `requireUsable`: shared finite/nonzero/dimension vector gate; `cosine`: shared finite-checked Double cosine core; `standout`: linear leave-one-out deviation scores used by recall and care settlement at the memory bar; `chanceBar`: unsolicited attention/action bar (chance among n, plus 1 or 2) |

/// Shared vector math for the recall / consolidation / context surfaces.
///
/// Before this existed, three separate `cosine` implementations had drifted:
/// MemoryV2 embedding recall used a `Float` version with no NaN guard,
/// MemoryV2 consolidation used a `Double` exact-count version, and Context
/// selection used a `Double` finite-checked version that also clamped to
/// `[0, 1]`. `cosine` here is the single guarded core: `Double` math,
/// equal-length required (mismatched dimensionality is a model/version skew,
/// not a valid comparison), finiteness-guarded (any non-finite component
/// collapses the whole comparison to `0`), and it returns the RAW cosine in
/// `[-1, 1]`. Each call site keeps its own post-clamp semantics locally
/// (Context still clamps to `[0, 1]`; consolidation compares the raw value
/// against a threshold).
public enum VectorMath {
    public struct UnusableVector: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// Admission, activation and inference share this gate. A missing expected
    /// width permits checking stored bytes, never inventing a model's width.
    public static func requireUsable(_ vector: [Float], dimensions: Int? = nil) throws {
        if let dimensions, dimensions <= 0 || vector.count != dimensions {
            throw UnusableVector(reason: "Embedding has \(vector.count) dimensions; expected \(dimensions).")
        }
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
            throw UnusableVector(reason: "Embedding must be nonempty, finite and nonzero.")
        }
    }

    /// Raw cosine similarity of two equal-length embeddings, guarded for empty
    /// input, length mismatch, and non-finite components. Returns a value in
    /// `[-1, 1]` (unclamped) or `0` when the comparison is undefined.
    public static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            let left = Double(a[index])
            let right = Double(b[index])
            guard left.isFinite, right.isFinite else { return 0 }
            dot += left * right
            normA += left * left
            normB += right * right
        }
        guard normA > 0, normB > 0 else { return 0 }
        let value = dot / (normA.squareRoot() * normB.squareRoot())
        return value.isFinite ? value : 0
    }

    /// Each value's deviations above the others' population mean, in linear time.
    /// Nil below that mean or with fewer than two others; infinite for zero variance.
    public static func standout(_ values: [Double]) -> [Double?] {
        guard values.count >= 3 else { return values.map { _ in nil } }
        let count = Double(values.count), mean = values.reduce(0, +) / count
        let squared = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return values.map { value in
            let delta = value - mean
            let otherMean = mean - delta / (count - 1)
            guard value > otherMean else { return nil }
            let variance = max(0, squared - delta * delta * count / (count - 1)) / (count - 1)
            return variance > 0 ? (value - otherMean) / variance.squareRoot() : .infinity
        }
    }

    /// What a similarity decision does, which sets how far past chance its
    /// winner must stand.
    public enum Decision: Sendable {
        /// Something comes to her attention: a care touched, a memory recalled
        /// into the turn, a moment she is reminded of. One deviation past chance.
        case attention
        /// Something is done for her without asking. Two deviations past
        /// chance. AfterTurnSurpriseLedger uses this margin when a labelled
        /// precedent nominates whether the after-turn fold has anything new.
        case action

        public var margin: Double {
            switch self {
            case .attention: return 1
            case .action: return 2
            }
        }
    }

    /// The chance bar for unsolicited attention and action: the best of `candidates`
    /// stands out by about √(2 ln n) deviations by chance alone (the expected
    /// maximum of n draws), so a candidate counts only when its `standout`
    /// reaches that plus the decision's margin. Derived from chance, not
    /// fitted, and it rises as the candidates grow: 3.5 for attention among 23
    /// cares, 4.0 among 80 memories; 4.0 to 4.6 for an action among 7 to 32.
    /// Addressed recall and care birth/night use the memory standout bar in
    /// ContextSelectionConfiguration instead; ambient touches retain this bar.
    public static func chanceBar(_ decision: Decision, among candidates: Int) -> Double {
        decision.margin + (2 * log(Double(max(1, candidates)))).squareRoot()
    }
}
