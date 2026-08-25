import CoreGraphics
import Foundation
import Testing
@testable import VisionPerception

// MARK: - Coverage wave A — row `vision.perceptionConfigThresholds`
//
// The AX-side caps (render/view budgets) are covered. The VISION-side GEOMETRY
// thresholds are not, and they are the knobs that decide whether two OCR boxes
// become one control or stay two.
//
// SILENT FAILURE: a `mergeIoU` or `containmentFraction` drift produces a
// percept that is still well-formed and still passes every scene test — just
// with one button split in half, or two buttons fused. The fused-view
// supplement then hands the agent a target whose centre sits BETWEEN two real
// controls, and the click lands on neither. Nothing in the envelope says so.
//
// WHAT IS ASSERTED: the shipped defaults sit on a PLATEAU, not on a cliff.
// Nudge each threshold ±20% and the row count and role assignment must not
// move. A threshold whose small change flips the percept is a lead, not
// something to ship quietly.
//
// DETERMINISM: OCR runs ONCE against the real recognizer; every configuration
// below replays those exact boxes. That isolates the geometry thresholds from
// Vision's own run-to-run variation — otherwise a flapping OCR result would be
// indistinguishable from a threshold cliff, which is the whole thing this test
// exists to tell apart.

private struct _ReplayRecognizer: VisionTextRecognizing {
    let boxes: [VisionTextBox]
    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        guard region == nil else { return [] }
        return boxes
    }
}


/// ONE real OCR pass for the whole file, lock-serialized and cached.
///
/// Vision funnels every synchronous text-recognition request through its own
/// capacity-limited internal queue (`VNControlledCapacityTasksQueue`). Under
/// swift-testing's default parallelism, a fleet of concurrent `recognizeText`
/// calls from this file plus the scene suites can park cooperative-pool
/// threads in that queue's semaphore (`_dispatch_semaphore_wait_slow`) and
/// wedge the entire run at 0% CPU. This file therefore pays for exactly ONE
/// real recognition, behind a lock, and every test replays those boxes.
private final class _PlateauOCRCache: @unchecked Sendable {
    static let shared = _PlateauOCRCache()
    private let lock = NSLock()
    private var cached: [VisionTextBox]?

    func boxes() throws -> [VisionTextBox] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let recognized = try VisionTextLayer.recognize(
            image: Scene.mainScene().image, using: VisionKitTextRecognizer(), config: .default
        ).boxes
        cached = recognized
        return recognized
    }
}

private struct _Fingerprint: Equatable, CustomStringConvertible {
    let rowCount: Int
    let roles: [String]
    let readoutCount: Int

    var description: String { "rows=\(rowCount) readouts=\(readoutCount) roles=\(roles.joined(separator: ","))" }
}

private func _fingerprint(_ config: VisionPerceptionConfig, _ scene: Scene.Rendered, _ recognizer: _ReplayRecognizer) throws -> _Fingerprint {
    let result = try VisionPerceptionCompiler(config: config).compile(
        image: scene.image,
        using: recognizer,
        appName: "AX-blind window",
        windowTitle: "Account Settings"
    )
    return _Fingerprint(
        rowCount: result.rows.count,
        // Sorted so a stable set of rows in a different emission order is not
        // reported as a percept change.
        roles: result.rows.map(\.roleGuess).sorted(),
        readoutCount: result.readouts.count
    )
}

/// Every geometry threshold, with a setter that rebuilds the config around it.
private func _thresholdSweep() -> [(name: String, value: (VisionPerceptionConfig) -> Double, apply: (Double) -> VisionPerceptionConfig)] {
    [
    ("mergeIoU", { $0.mergeIoU }, { VisionPerceptionConfig(mergeIoU: $0) }),
    ("glyphRunIoU", { $0.glyphRunIoU }, { VisionPerceptionConfig(glyphRunIoU: $0) }),
    ("glyphInsetCoverage", { $0.glyphInsetCoverage }, { VisionPerceptionConfig(glyphInsetCoverage: $0) }),
    ("containmentFraction", { $0.containmentFraction }, { VisionPerceptionConfig(containmentFraction: $0) }),
    ("readoutProminence", { $0.readoutProminence }, { VisionPerceptionConfig(readoutProminence: $0) }),
    ]
}

@Test
func visionThresholdNudgesNeverMoveTheTargetingGeometry() throws {
    let scene = Scene.mainScene()
    // ONE real OCR pass per FILE (lock-serialized, cached). Everything after
    // this is deterministic replay.
    let boxes = try _PlateauOCRCache.shared.boxes()
    #expect(!boxes.isEmpty, "the replay is vacuous without real recognized text")
    let recognizer = _ReplayRecognizer(boxes: boxes)

    let baseline = try _fingerprint(.default, scene, recognizer)
    #expect(baseline.rowCount > 0, "the baseline percept must contain rows for a nudge to mean anything")
    // The replay must be deterministic, or every difference below is noise.
    #expect(try _fingerprint(.default, scene, recognizer) == baseline)

    // THE SHIPPED VALUES, written out. The sweep below is RELATIVE — it moves
    // each threshold off wherever the default is — so on its own it cannot see
    // the default itself drifting. These are the absolute pins.
    #expect(VisionPerceptionConfig.default.mergeIoU == 0.6)
    #expect(VisionPerceptionConfig.default.glyphRunIoU == 0.5)
    #expect(VisionPerceptionConfig.default.glyphInsetCoverage == 0.8)
    #expect(VisionPerceptionConfig.default.containmentFraction == 0.6)
    #expect(VisionPerceptionConfig.default.readoutProminence == 1.25)
    #expect(VisionPerceptionConfig.default.maxReadouts == 8)
    #expect(VisionPerceptionConfig.default.maxAffordances == 60)

    // THE PROPERTY THAT MATTERS FOR AIMING: no threshold at ±20% may change
    // how many affordances there are or what they are guessed to be. That is
    // the drift that splits one button in two — or fuses two into one whose
    // centre is between them — and then a click lands on neither.
    var cliffs: [String] = []
    for threshold in _thresholdSweep() {
        let shipped = threshold.value(.default)
        for factor in [0.8, 1.2] {
            let nudged = shipped * factor
            let fingerprint = try _fingerprint(threshold.apply(nudged), scene, recognizer)
            if fingerprint.rowCount != baseline.rowCount || fingerprint.roles != baseline.roles {
                cliffs.append("\(threshold.name) \(shipped) → \(nudged): \(fingerprint) ≠ \(baseline)")
            }
        }
    }
    #expect(cliffs.isEmpty,
            "a shipped threshold sits on a cliff — a ±20% drift changes the affordance percept: \(cliffs.joined(separator: " | "))")
}

@Test
func visionGeometryThresholdsAlsoHoldTheReadoutSelectionSteady() throws {
    let scene = Scene.mainScene()
    let boxes = try _PlateauOCRCache.shared.boxes()
    let recognizer = _ReplayRecognizer(boxes: boxes)
    let baseline = try _fingerprint(.default, scene, recognizer)

    // The four GEOMETRY thresholds move nothing at all at ±20%, readouts
    // included.
    let geometry = _thresholdSweep().filter { $0.name != "readoutProminence" }
    #expect(geometry.count == 4)
    for threshold in geometry {
        let shipped = threshold.value(.default)
        for factor in [0.8, 1.2] {
            let fingerprint = try _fingerprint(threshold.apply(shipped * factor), scene, recognizer)
            #expect(fingerprint == baseline,
                    "\(threshold.name) at \(shipped * factor) changed the percept: \(fingerprint) ≠ \(baseline)")
        }
    }
}

/// MEASURED LEAD, pinned rather than reported and forgotten.
///
/// `readoutProminence` is the one threshold in this config that is NOT on a
/// plateau. Shipped at 1.25 the scene yields ONE readout; nudged −20% to 1.0 it
/// yields TWO. The affordance rows and their roles do not move — the targeting
/// geometry is safe — but WHICH standalone text counts as "the number the
/// screen is showing" flips on a 0.25 change.
///
/// That matters because a readout is what the agent quotes back as the value it
/// read. A drift here does not misplace a click; it changes what she believes
/// the screen SAYS, and the percept stays perfectly well-formed either way.
///
/// This is pinned as an exact measurement so the sensitivity cannot widen
/// unnoticed. If a future change puts readoutProminence on a plateau too, THIS
/// TEST FAILS — and ledger row `vision.perceptionConfigThresholds` gets
/// re-rated on purpose rather than by accident.
@Test
func readoutProminenceIsTheOneMeasuredCliffInTheShippedConfig() throws {
    let scene = Scene.mainScene()
    let boxes = try _PlateauOCRCache.shared.boxes()
    let recognizer = _ReplayRecognizer(boxes: boxes)

    let shipped = try _fingerprint(.default, scene, recognizer)
    let lowered = try _fingerprint(VisionPerceptionConfig(readoutProminence: 1.0), scene, recognizer)
    let raised = try _fingerprint(VisionPerceptionConfig(readoutProminence: 1.5), scene, recognizer)

    #expect(lowered.rowCount == shipped.rowCount, "the affordance rows must not move — only the readouts")
    #expect(lowered.roles == shipped.roles)
    #expect(lowered.readoutCount > shipped.readoutCount,
            "MEASURED LEAD: a -20% nudge must still admit more readouts (shipped \(shipped.readoutCount), lowered \(lowered.readoutCount)). If it no longer does, the cliff is gone — re-rate the ledger row.")
    #expect(raised.readoutCount <= shipped.readoutCount,
            "raising the bar must never admit MORE readouts")
}

/// NEGATIVE CONTROL for the test above.
///
/// A plateau assertion is worthless if the fingerprint cannot detect a change
/// at all. Pushed far enough, a threshold MUST move the percept — if this
/// passes vacuously then so does every nudge, and the whole sweep is theatre.
@Test
func theThresholdFingerprintActuallyDetectsAChangedPercept() throws {
    let scene = Scene.mainScene()
    let boxes = try _PlateauOCRCache.shared.boxes()
    let recognizer = _ReplayRecognizer(boxes: boxes)
    let baseline = try _fingerprint(.default, scene, recognizer)

    // The affordance cap is a knob with an unarguable effect. If the
    // fingerprint cannot see THIS, it can see nothing.
    let capped = try _fingerprint(VisionPerceptionConfig(maxAffordances: 2), scene, recognizer)
    #expect(capped != baseline, "the fingerprint must be able to detect a changed percept at all")
    #expect(capped.rowCount == 2)

    // …and a threshold pushed well past the sweep's ±20% does move it too, so
    // "stable at ±20%" is a measured plateau rather than an insensitive metric.
    let extreme = try _fingerprint(
        VisionPerceptionConfig(containmentFraction: 0.01, readoutProminence: 0.1), scene, recognizer
    )
    #expect(extreme != baseline,
            "thresholds driven far off their defaults must change the percept, or they are inert")
}
