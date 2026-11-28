import Accelerate
import Foundation

// Blueprint: | `VectorMath.swift` | `requireUsable`, `cosine`, `standout`, `chanceBar`: vector gates and attention thresholds |

/// Use one finite-checked Double cosine core so dimension skew never becomes a valid comparison. Return raw [-1, 1]; callers own any narrower clamp.
public enum VectorMath {
    public struct UnusableVector: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// Admission, activation and inference share this gate. A missing expected width permits checking stored bytes, never inventing a model's width.
    public static func requireUsable(_ vector: [Float], dimensions: Int? = nil) throws {
        if let dimensions, dimensions <= 0 || vector.count != dimensions {
            throw UnusableVector(reason: "Embedding has \(vector.count) dimensions; expected \(dimensions).")
        }
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
            throw UnusableVector(reason: "Embedding must be nonempty, finite and nonzero.")
        }
    }

    /// Raw cosine similarity of two equal-length embeddings, guarded for empty input, length mismatch, and non-finite components. Returns a value in `[-1, 1]`
    /// (unclamped) or `0` when the comparison is undefined.
    public static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return 0 }
        let left = vDSP.floatToDouble(a)
        let right = vDSP.floatToDouble(b)
        let normA = vDSP.sumOfSquares(left)
        let normB = vDSP.sumOfSquares(right)
        guard normA > 0, normB > 0 else { return 0 }
        let value = vDSP.dot(left, right) / (normA.squareRoot() * normB.squareRoot())
        return value.isFinite ? value : 0
    }

    /// Each value's deviations above the others' population mean, in linear time. Nil below that mean or with fewer than two others; infinite for zero
    /// variance.
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

    public static func chanceBar(among candidates: Int) -> Double {
        1 + (2 * log(Double(max(1, candidates)))).squareRoot()
    }
}
