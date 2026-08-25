import Foundation
import Testing
@testable import NativeAgentCore

// Ledger row: core.vectorMath.cosine
//
// Silent-failure class: SILENT ZERO / WRONG VALUE. `VectorMath.cosine` is the
// single source of truth for embedding similarity across recall ranking,
// consolidation, and context selection. Every failure mode it guards collapses
// to `0` — which is indistinguishable from "these really are unrelated". So the
// undefined cases are pinned to 0 AND the defined cases are pinned to a
// non-zero value: a regression that returns 0 for everything (recall silently
// degrades to lexical-only, no error anywhere) fails the second half.
//
// The RAW range is pinned too: the doc comment promises `[-1, 1]` unclamped and
// each call site owns its own post-clamp. A re-introduced `max(0, …)` here would
// silently flip every "opposed" comparison into "unrelated" at every call site.

private func unitish(_ seed: UInt64, count: Int = 384) -> [Float] {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var out: [Float] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let bits = Double((state >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(1 << 53)
        out.append(Float(bits * 2 - 1))
    }
    return out
}

@Test("self-similarity is 1 within tolerance")
func cosineSelfSimilarityIsOne() {
    let vector = unitish(7)
    #expect(abs(VectorMath.cosine(vector, vector) - 1.0) < 1e-6)
    #expect(abs(VectorMath.cosine([3, 4], [3, 4]) - 1.0) < 1e-12)
}

@Test("orthogonal vectors score exactly 0 and opposed vectors score -1 (raw, unclamped)")
func cosineOrthogonalAndOpposed() {
    #expect(abs(VectorMath.cosine([1, 0], [0, 1])) < 1e-12)
    // The RAW value is required here. A clamp to [0, 1] inside VectorMath would
    // return 0 and this expectation fails.
    #expect(abs(VectorMath.cosine([1, 2, 3], [-1, -2, -3]) + 1.0) < 1e-12)
    #expect(VectorMath.cosine([1, 2, 3], [-3, 0, 0]) < 0)
}

@Test("a realistic 384-dim pair produces a live, non-degenerate score")
func cosineProducesNonZeroScoreForRealisticEmbeddings() {
    let a = unitish(11)
    let b = unitish(29)
    let related = zip(a, b).map { $0 * 0.85 + $1 * 0.15 }

    let unrelated = VectorMath.cosine(a, b)
    let near = VectorMath.cosine(a, related)

    // Teeth against "everything returns 0": both comparisons must be live
    // numbers, and the deliberately-blended vector must rank above the
    // independent one.
    #expect(unrelated != 0)
    #expect(near != 0)
    #expect(near > unrelated)
    #expect(near > 0.9 && near <= 1.0)
    #expect(abs(unrelated) < 0.5)
}

@Test("undefined comparisons collapse to 0 instead of a plausible-looking score")
func cosineUndefinedComparisonsReturnZero() {
    let vector = unitish(3, count: 8)
    // nil on either side
    #expect(VectorMath.cosine(nil, vector) == 0)
    #expect(VectorMath.cosine(vector, nil) == 0)
    #expect(VectorMath.cosine(nil, nil) == 0)
    // empty
    #expect(VectorMath.cosine([], []) == 0)
    #expect(VectorMath.cosine([], vector) == 0)
    // dimension skew — a model/version mismatch is not a valid comparison
    #expect(VectorMath.cosine(unitish(3, count: 384), unitish(3, count: 768)) == 0)
    #expect(VectorMath.cosine([1, 2, 3], [1, 2]) == 0)
    // zero norm on either side
    #expect(VectorMath.cosine([0, 0, 0], [1, 2, 3]) == 0)
    #expect(VectorMath.cosine([1, 2, 3], [0, 0, 0]) == 0)
}

@Test("a non-finite component collapses the whole comparison, it does not poison it")
func cosineNonFiniteComponentsReturnZero() {
    let base: [Float] = [1, 2, 3, 4]
    #expect(VectorMath.cosine([1, .nan, 3, 4], base) == 0)
    #expect(VectorMath.cosine(base, [1, 2, .infinity, 4]) == 0)
    #expect(VectorMath.cosine(base, [1, 2, 3, -.infinity]) == 0)
    #expect(VectorMath.cosine([.nan, .nan, .nan, .nan], base) == 0)
    // And the guard never leaks a NaN out to a caller that would then compare
    // it against a threshold (NaN comparisons are always false → silent drop).
    for value in [VectorMath.cosine([1, .nan], [1, 1]), VectorMath.cosine(base, base)] {
        #expect(value.isFinite)
    }
}

@Test("cosine is symmetric and scale-invariant")
func cosineSymmetricAndScaleInvariant() {
    let a = unitish(101, count: 64)
    let b = unitish(202, count: 64)
    #expect(abs(VectorMath.cosine(a, b) - VectorMath.cosine(b, a)) < 1e-12)
    let scaled = b.map { $0 * 17 }
    #expect(abs(VectorMath.cosine(a, b) - VectorMath.cosine(a, scaled)) < 1e-6)
}
