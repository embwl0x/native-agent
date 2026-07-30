import Foundation

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
}
