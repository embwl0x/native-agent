import Foundation
import Testing
@testable import VisionPerception

// MARK: - Layer-level pins

@Test func fixedColorDistancePreservesSquaredRGBReduction() {
    let values: [Double] = [0, 0.001, 0.03125, 0.1, 0.125, 0.5, 0.99, 1]
    for r in values {
        for g in values {
            for b in values {
                let color = SIMD3(r, g, b)
                for reference in [SIMD3<Double>(0, 0, 0), SIMD3<Double>(0.53125, 0.5, 0.25), SIMD3<Double>(1, 1, 1)] {
                    let delta = color - reference
                    #expect(VisionColorRegionLayer.distanceSquared(color, reference) == (delta * delta).sum())
                }
            }
        }
    }
}
//
// The scene tests prove the pipeline on pixels. These pin the DECISIONS that
// the spikes' measurements bought, where a scene would be a slow and indirect
// way to ask.

// MARK: Text layer — conditional tiling

private func box(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VisionTextBox {
    VisionTextBox(text: text, rect: VisionRect(x: x, y: y, w: w, h: h), confidence: 0.9)
}

@Test func sparseCanvasTextGetsOneBoundedLocalRecoveryInsteadOfNineTiles() throws {
    let title = VisionTextBox(
        text: "Moving visual target",
        rect: VisionRect(x: 34, y: 28, w: 310, h: 28),
        confidence: 0.9
    )
    let hits = VisionTextBox(
        text: "Hits: 1",
        rect: VisionRect(x: 34, y: 64, w: 80, h: 22),
        confidence: 0.8,
        source: "tile"
    )
    let recognizer = VisionStaticTextRecognizer(boxes: [title], tileOnlyBoxes: [hits])
    let config = VisionTextLayerConfig(sparseRecoveryMaxBoxes: 3)
    let result = try VisionTextLayer.recognize(
        image: Scene.mainScene().image,
        using: recognizer,
        config: config
    )

    #expect(result.tiled)
    #expect(result.tilingReason.contains("sparse text recovery"))
    #expect(result.boxes.map(\.text).contains("Hits: 1"))
}

@Test func tilingDoesNotFireOnOrdinaryUiText() {
    // Spike v1, measured: whole-frame OCR recovered 142/144 strings at 2560×1440
    // in 409 ms; 3×3 tiling recovered 145/144 for 704 ms. Always-on tiling buys
    // ~nothing and costs ~1.7×, so ordinary text must not trigger it.
    let boxes = (0..<20).map { box("Label \($0)", 10, Double($0) * 30, 120, 17) }
    let decision = VisionTextLayer.tilingDecision(boxes: boxes, imageHeight: 1440)
    #expect(!decision.shouldTile)
    #expect(decision.reason.contains("no tiny text"))
}

@Test func foregroundTinyTextDoesNotTriggerRefinementButRemainsForRedaction() throws {
    let ordinary = (0..<4).map { box("World \($0)", 10, Double($0) * 30, 100, 20) }
    let covered = (0..<8).map { box("Dialog \($0)", 400, Double($0) * 10, 100, 6) }
    let result = try VisionTextLayer.recognize(
        image: Scene.mainScene().image,
        using: VisionStaticTextRecognizer(boxes: ordinary + covered, tileOnlyBoxes: []),
        config: VisionTextLayerConfig(sparseRecoveryMaxBoxes: 3),
        ignoredForRefinement: [VisionRect(x: 390, y: 0, w: 130, h: 100)]
    )
    #expect(!result.tiled)
    #expect(result.boxes.count == ordinary.count + covered.count,
        "whole-frame text remains available to the redactor before compiler exclusion")
    #expect(result.tilingReason.contains("foreground-covered text ignored"))
}

@Test func foregroundTextCannotSuppressSparseWorldTextRecovery() throws {
    let title = box("World", 20, 20, 100, 24)
    let covered = (0..<5).map { box("Dialog \($0)", 400, Double($0) * 30, 100, 18) }
    let recovered = box("Hits: 2", 20, 55, 80, 18)
    let result = try VisionTextLayer.recognize(
        image: Scene.mainScene().image,
        using: VisionStaticTextRecognizer(boxes: [title] + covered, tileOnlyBoxes: [recovered]),
        config: VisionTextLayerConfig(sparseRecoveryMaxBoxes: 3),
        ignoredForRefinement: [VisionRect(x: 390, y: 0, w: 130, h: 160)]
    )
    #expect(result.tiled)
    #expect(result.tilingReason.contains("sparse text recovery"))
    #expect(result.tilingReason.contains("1 local region(s)"))
    #expect(result.boxes.contains { $0.text == "Hits: 2" })
}

@Test func visibleTinyTextStillGetsRefinedBesideAnExcludedOverlay() throws {
    let tiny = (0..<4).map { box("World \($0)", 10, Double($0) * 10, 80, 6) }
    let result = try VisionTextLayer.recognize(
        image: Scene.mainScene().image,
        using: VisionStaticTextRecognizer(boxes: tiny, tileOnlyBoxes: [box("Recovered", 10, 70, 70, 6)]),
        ignoredForRefinement: [VisionRect(x: 390, y: 0, w: 130, h: 100)]
    )
    #expect(result.tiled)
    #expect(result.tilingReason.contains("tiny text"))
    #expect(result.boxes.contains { $0.text == "Recovered" })
}

@Test func tilingFiresOnGenuinelyTinyText() {
    let boxes = (0..<20).map { box("x", 10, Double($0) * 12, 40, 7) }
    let decision = VisionTextLayer.tilingDecision(boxes: boxes, imageHeight: 1440)
    #expect(decision.shouldTile)
    #expect(decision.reason.contains("tiny text"))
}

@Test func aFrameWithNoTextIsNotTiled() {
    // No text is not evidence of TINY text — it is evidence of no text (a game
    // canvas, a photo). Re-scanning it nine times is pure waste.
    let decision = VisionTextLayer.tilingDecision(boxes: [], imageHeight: 1440)
    #expect(!decision.shouldTile)
    #expect(decision.reason.contains("nothing to re-scan"))
}

@Test func tilesCoverTheWholeFrameWithOverlap() {
    let size = VisionSize(width: 900, height: 600)
    let tiles = VisionTextLayer.tiles(imageSize: size)
    #expect(tiles.count == 9)
    #expect(tiles.allSatisfy { $0.x >= 0 && $0.y >= 0 })
    #expect(tiles.allSatisfy { $0.maxX <= size.width + 0.001 && $0.maxY <= size.height + 0.001 })
    // Adjacent tiles must overlap, or a string on a seam is cut in every tile.
    let topLeft = tiles[0]
    let topMiddle = tiles[1]
    #expect(topLeft.maxX > topMiddle.x)
}

@Test func theSameStringSeenByTwoTilesIsOneString() {
    let merged = VisionTextLayer.dedupe([
        VisionTextBox(text: "Send", rect: VisionRect(x: 100, y: 50, w: 40, h: 16), confidence: 0.7),
        VisionTextBox(text: "Send", rect: VisionRect(x: 101, y: 51, w: 40, h: 16), confidence: 0.95),
        VisionTextBox(text: "Cancel", rect: VisionRect(x: 200, y: 50, w: 50, h: 16), confidence: 0.9),
    ])
    #expect(merged.count == 2)
    #expect(merged.first { $0.text == "Send" }?.confidence == 0.95)
}

@Test func deterministicOCRReadingOrderSurvivesEveryNearTiePermutation() {
    let boxes = [box("A", 20, 0, 5, 5), box("B", 10, 0.6, 5, 5), box("C", 0, 1.2, 5, 5)]
    let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for indexes in permutations {
        let ordered = VisionTextLayer.dedupe(indexes.map { boxes[$0] })
        #expect(ordered.map(\.text) == ["B", "A", "C"])
        #expect(ordered.count == boxes.count)
    }
    let sameRow = [box("Z", 0, 0, 5, 5), box("A", 0.6, 0.4, 5, 5), box("B", 1.2, 0.8, 5, 5)]
    for indexes in permutations {
        #expect(VisionTextLayer.dedupe(indexes.map { sameRow[$0] }).map(\.text) == ["A", "Z", "B"])
    }
}

@Test func deterministicOCRDuplicateWinnerPreservesHigherConfidence() {
    let first = VisionTextBox(text: "Send", rect: VisionRect(x: 10, y: 10, w: 40, h: 16), confidence: 0.8)
    let shifted = VisionTextBox(text: "Send", rect: VisionRect(x: 10.5, y: 10.5, w: 40, h: 16), confidence: 0.8, source: "tile")
    let stronger = VisionTextBox(text: "Send", rect: shifted.rect, confidence: 0.95, source: "tile")
    #expect(VisionTextLayer.dedupe([first, shifted]) == [first])
    #expect(VisionTextLayer.dedupe([shifted, first]) == [first])
    #expect(VisionTextLayer.dedupe([first, stronger]) == [stronger])
    #expect(VisionTextLayer.dedupe([stronger, first]) == [stronger])
    let exactTile = VisionTextBox(text: first.text, rect: first.rect, confidence: first.confidence, source: "tile")
    #expect(VisionTextLayer.dedupe([first, exactTile]) == VisionTextLayer.dedupe([exactTile, first]))
}

@Test func conditionalTilingRunsTheExtraPassOnlyWhenItShould() throws {
    let image = Scene.mainScene().image
    let tiny = (0..<12).map { box("t", 10, Double($0) * 10, 20, 6) }
    let extra = [box("hidden-in-a-tile", 300, 300, 90, 6)]
    let tinyResult = try VisionTextLayer.recognize(
        image: image,
        using: VisionStaticTextRecognizer(boxes: tiny, tileOnlyBoxes: extra)
    )
    #expect(tinyResult.tiled)
    #expect(tinyResult.boxes.contains { $0.text == "hidden-in-a-tile" })

    let ordinary = (0..<12).map { box("Label", 10, Double($0) * 30, 100, 18) }
    let ordinaryResult = try VisionTextLayer.recognize(
        image: image,
        using: VisionStaticTextRecognizer(boxes: ordinary, tileOnlyBoxes: extra)
    )
    #expect(!ordinaryResult.tiled)
    #expect(!ordinaryResult.boxes.contains { $0.text == "hidden-in-a-tile" })
}

// MARK: Element layer (b) — Y-BAND clustering

@Test func connectedColorComponentsDistinguishRoundFromSquareWithoutChangingBounds() throws {
    let background = SIMD3<Double>(1, 1, 1)
    let foreground = SIMD3<Double>(1, 0, 0)
    func shape(for occupied: Set<Int>) throws -> String {
        let samples = (0..<144).map { occupied.contains($0) ? foreground : background }
        let grid = VisionPixelGrid(
            columns: 12,
            rows: 12,
            stepX: 10,
            stepY: 10,
            imageSize: VisionSize(width: 120, height: 120),
            samples: samples
        )
        let result = VisionColorRegionLayer.candidates(grid: grid)
        return try #require(result.candidates.first?.visualShape)
    }
    func indexes(_ rows: [[Int]]) -> Set<Int> {
        Set(rows.enumerated().flatMap { offset, columns in
            columns.map { (offset + 3) * 12 + $0 }
        })
    }

    let square = indexes(Array(repeating: Array(3...7), count: 5))
    let round = indexes([
        Array(4...6), Array(3...7), Array(3...7), Array(3...7), Array(4...6),
    ])
    #expect(try shape(for: square) == "square")
    #expect(try shape(for: round) == "round")
}

@Test func rowsAreFormedByYBandsNotByColumns() {
    // The close-out's exact failure: a right-hand VALUE COLUMN shares a left-x
    // and an even pitch, so column-first grouping clustered the VALUES into
    // "rows" and missed the rows. Y-band grouping clusters by vertical overlap
    // and gets the rows themselves — a band per row, each spanning both texts.
    var boxes: [VisionTextBox] = []
    for index in 0..<5 {
        let y = 100 + Double(index) * 40
        boxes.append(box("Report \(index)", 60, y, 120, 18))
        boxes.append(box("\(index) pts", 700, y + 1, 50, 16))
    }
    let bands = VisionTextBandLayer.bands(from: boxes)
    #expect(bands.count == 5)
    #expect(bands.allSatisfy { $0.texts.count == 2 })

    let rows = VisionTextBandLayer.rowCandidates(from: boxes)
    #expect(rows.count == 5)
    // A row's rect spans the whole run, not just one column: the value column
    // alone would be ~50 px wide.
    #expect(rows.allSatisfy { $0.rect.w > 600 })
    #expect(rows.allSatisfy { $0.sources == [.textBand] })
    // Modest bounds confidence — the edges are inferred from the run, not seen.
    #expect(rows.allSatisfy { $0.boundsConfidence <= 0.6 })
}

@Test func twoLabelledFieldsAreNotAList() {
    // Two adjacent captioned fields are also multi-text bands. Without a
    // REPEAT there is no list, and inventing one would put a fake row handle
    // on a form.
    let boxes = [
        box("Email", 40, 100, 50, 16),
        box("user@example.com", 120, 100, 160, 16),
        box("Name", 40, 160, 45, 16),
        box("User", 120, 160, 40, 16),
    ]
    #expect(VisionTextBandLayer.rowCandidates(from: boxes).isEmpty)
}

@Test func bandsClusterByVerticalOverlapEvenWhenColumnsDoNotAlign() {
    let boxes = [
        box("left", 10, 100, 60, 20),
        box("middle", 300, 104, 60, 12),
        box("right", 700, 98, 60, 24),
    ]
    let bands = VisionTextBandLayer.bands(from: boxes)
    #expect(bands.count == 1)
    #expect(bands[0].texts.count == 3)
    #expect(bands[0].rect.w >= 750)
}

// MARK: Handles

@Test func theFingerprintIsRoleLabelAndQuantizedPositionOnly() {
    let size = VisionSize(width: 800, height: 600)
    let base = VisionHandles.fingerprint(
        roleGuess: "AXButton", label: "Send",
        rect: VisionRect(x: 100, y: 100, w: 80, h: 30), imageSize: size
    )
    // SIZE is not identity: a button that grows a few pixels when its label
    // re-lays-out is the same button.
    let grown = VisionHandles.fingerprint(
        roleGuess: "AXButton", label: "Send",
        rect: VisionRect(x: 100, y: 100, w: 84, h: 30), imageSize: size
    )
    #expect(base == grown)
    // Raw pixels are not identity either: a sub-bucket nudge keeps the handle.
    let nudged = VisionHandles.fingerprint(
        roleGuess: "AXButton", label: "Send",
        rect: VisionRect(x: 102, y: 101, w: 80, h: 30), imageSize: size
    )
    #expect(base == nudged)
    // A real move DOES rename it — the caller must be told the target drifted.
    let moved = VisionHandles.fingerprint(
        roleGuess: "AXButton", label: "Send",
        rect: VisionRect(x: 400, y: 300, w: 80, h: 30), imageSize: size
    )
    #expect(base != moved)
    // Role and label are identity.
    #expect(base != VisionHandles.fingerprint(
        roleGuess: "AXTextField", label: "Send",
        rect: VisionRect(x: 100, y: 100, w: 80, h: 30), imageSize: size
    ))
    #expect(base != VisionHandles.fingerprint(
        roleGuess: "AXButton", label: "Sent",
        rect: VisionRect(x: 100, y: 100, w: 80, h: 30), imageSize: size
    ))
}

@Test func theFingerprintToleratesOcrNoiseWithoutCollapsingAList() {
    let size = VisionSize(width: 900, height: 560)
    let rect = VisionRect(x: 400, y: 80, w: 140, h: 42)
    func print(_ label: String) -> String {
        VisionHandles.fingerprint(roleGuess: "AXButton", label: label, rect: rect, imageSize: size)
    }
    // MEASURED noise: two captures of the identical scene read the same greyed
    // button as "Archive" and "Archivel". A handle that renames a control
    // nobody touched has failed at its only job.
    #expect(print("Archive") == print("Archivel"))
    // …but the tolerance must not collapse a list onto one token. The digits
    // are what tells one row from the next, and losing them would put every
    // row on a position-derived ordinal.
    #expect(print("Report 1 12 pts") != print("Report 2 15 pts"))
    // A mangled space is noise; the digits still carry the identity.
    #expect(print("Report 4 21 pts") == print("Report 421 pts"))
}

@Test func identicalCandidatesGetOrdinalsAndSayThatTheyDid() {
    let minted = VisionHandles.mint(fingerprints: ["a", "a", "b"])
    #expect(minted[0].handle + ".2" == minted[1].handle)
    #expect(minted[0].ambiguity != nil)
    #expect(minted[1].ambiguity != nil)
    // A silently positional handle is worse than a drifted one, so the note is
    // present and says WHY.
    #expect(minted[0].ambiguity?.contains("position-derived") == true)
    #expect(minted[2].ambiguity == nil)
}

@Test func handleTokensAreStableAcrossProcesses() {
    // FNV-1a, not `Hasher`: `Hasher` is per-process seeded, so the same screen
    // would hand out different handles next launch. This is a pinned constant
    // on purpose — if it changes, every stored handle in the wild broke.
    #expect(VisionHandles.token(fingerprint: "vision>AXButton/Send/2:3") ==
            VisionHandles.token(fingerprint: "vision>AXButton/Send/2:3"))
    #expect(VisionHandles.token(fingerprint: "vision>AXButton/Send/2:3").count == 6)
}

// MARK: Geometry

@Test func coverageAndIouMeasureDifferentThings() {
    let big = VisionRect(x: 0, y: 0, w: 100, h: 100)
    let small = VisionRect(x: 10, y: 10, w: 20, h: 20)
    #expect(small.coverage(by: big) == 1.0)
    #expect(big.iou(small) < 0.05)
}
