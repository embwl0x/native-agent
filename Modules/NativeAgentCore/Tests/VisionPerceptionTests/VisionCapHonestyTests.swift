import CoreGraphics
import Foundation
import Testing
@testable import VisionPerception

// gpt-5.5 vision-v0 review (2026-08-22): three ways a CAP could quietly lie.
// 1. BLOCKING — the abstain report was computed AFTER `maxAffordances`
//    truncation while `considered` counted the PRE-cap set, so dense frames
//    understated the refusal rate exactly when the cap bit.
// 2. SHOULD-FIX — `readoutsOmitted` was hardcoded 0, so a capped readout list
//    looked complete.
// 3. SHOULD-FIX — tile OCR failures were swallowed by `try?`, making tiny-text
//    recovery silently non-deterministic.

@Test func theAbstainRateIsHonestWhenTheAffordanceCapBites() throws {
    let scene = Scene.mainScene()
    let tight = VisionPerceptionConfig(maxAffordances: 3)
    let percept = try VisionPerceptionCompiler(config: tight).compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    // The rate's denominator is the EMITTED set…
    #expect(percept.rows.count <= 3)
    #expect(percept.abstain.considered == percept.rows.count)
    // …and the rows the cap dropped are SURFACED, not silently missing.
    #expect(percept.abstain.droppedBeyondCap > 0,
            "mainScene has more than 3 candidates; the drop must be visible")
    #expect(percept.notes.contains { $0.contains("cap were dropped") })
    // The metric a reader sees carries the same honesty.
    guard case .object(let json) = percept.abstain.toJSON() else {
        Issue.record("abstain JSON not an object"); return
    }
    #expect(json["dropped_beyond_cap"] != nil)
    #expect(json["dropped_beyond_cap"] != .int(0))
}

/// Deterministic readouts: a flat background (no color candidates, no bands)
/// and a stub recognizer emitting three small captions plus two PROMINENT
/// standalone values. The two big ones are readouts by the prominence rule.
private struct _ReadoutStubRecognizer: VisionTextRecognizing {
    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        guard region == nil else { return [] }
        return [
            VisionTextBox(text: "small a", rect: VisionRect(x: 20, y: 20, w: 60, h: 8), confidence: 0.9),
            VisionTextBox(text: "small b", rect: VisionRect(x: 20, y: 60, w: 60, h: 8), confidence: 0.9),
            VisionTextBox(text: "small c", rect: VisionRect(x: 20, y: 100, w: 60, h: 8), confidence: 0.9),
            VisionTextBox(text: "42.7", rect: VisionRect(x: 200, y: 40, w: 90, h: 20), confidence: 0.95),
            VisionTextBox(text: "OK 99%", rect: VisionRect(x: 200, y: 120, w: 90, h: 20), confidence: 0.95),
        ]
    }
}

@Test func aCappedReadoutListSaysHowManyItDropped() throws {
    let context = Scene.context(width: 400, height: 200)
    guard let image = context.makeImage() else { Issue.record("no image"); return }

    let full = try VisionPerceptionCompiler().compile(
        image: image, using: _ReadoutStubRecognizer()
    )
    #expect(full.readouts.count == 2, "two prominent standalone values: \(full.readouts.count)")
    #expect(full.percept.readoutsOmitted == 0)

    let tight = VisionPerceptionConfig(maxReadouts: 1)
    let capped = try VisionPerceptionCompiler(config: tight).compile(
        image: image, using: _ReadoutStubRecognizer()
    )
    #expect(capped.readouts.count == 1)
    #expect(capped.percept.readoutsOmitted == 1,
            "a capped readout list must not look complete")
}

/// A recognizer whose whole-frame pass reports TINY text (forcing the tiling
/// decision) and whose every tile pass THROWS.
private struct _TinyThenThrowingRecognizer: VisionTextRecognizing {
    struct Boom: Error {}
    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        guard region == nil else { throw Boom() }
        // Median height far below the tiny-text threshold ⇒ shouldTile.
        return (0..<4).map { i in
            VisionTextBox(
                text: "tiny\(i)",
                rect: VisionRect(x: Double(i) * 40 + 8, y: 30, w: 30, h: 5),
                confidence: 0.9
            )
        }
    }
}

@Test func aFailedTilePassIsCountedAndSurfacedNeverSwallowed() throws {
    let scene = Scene.mainScene()
    let result = try VisionTextLayer.recognize(
        image: scene.image,
        using: _TinyThenThrowingRecognizer(),
        config: .default
    )
    #expect(result.tiled, "the tiny-text whole pass must trigger tiling")
    #expect(result.tileFailures > 0, "every tile threw; the count must say so")

    // And the compiler turns that count into a note a reader actually sees.
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: _TinyThenThrowingRecognizer()
    )
    #expect(percept.notes.contains { $0.contains("tile pass(es) failed") },
            "a silent tile failure is the non-determinism the review flagged: \(percept.notes)")
}
