import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import MacControl
@testable import VisionPerception

// MARK: - The scene tests
//
// Real CGImages through the real pipeline (real Vision OCR included). These
// pin the RECALL the spikes measured and the trust contract Agent specified.
//
// Spike (a) v1's number was 8/11 targets: all filled borderless buttons, all
// fields, 3/6 rows — the misses being white-on-background rows, which is what
// the y-band clusterer was designed for. This scene carries the same target
// classes and the bar here is ALL of them.

private func compileMainScene(redraw: Bool = false) throws -> (Scene.Rendered, VisionPercept) {
    let scene = Scene.mainScene(redraw: redraw)
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image,
        using: VisionKitTextRecognizer(),
        appName: "AX-blind window",
        windowTitle: "Account Settings"
    )
    return (scene, percept)
}

@Test func recallsEveryButtonFieldAndRow() throws {
    let (scene, percept) = try compileMainScene()
    var missed: [String] = []
    var misroled: [String] = []
    for target in scene.targets {
        guard let row = scene.hit(target, in: percept.rows) else {
            missed.append(target.name)
            continue
        }
        if row.roleGuess != target.expectedRole {
            misroled.append("\(target.name): \(row.roleGuess) ≠ \(target.expectedRole)")
        }
    }
    #expect(missed.isEmpty, "missed targets: \(missed)")
    #expect(misroled.isEmpty, "wrong roles: \(misroled)")
    // 3 buttons + 2 fields + 5 text-only rows. The rows are the half the
    // colour heuristic correctly cannot see.
    #expect(scene.targets.count == 10)
}

@Test func textOnlyRowsComeFromTheYBandClusterer() throws {
    let (scene, percept) = try compileMainScene()
    let rows = percept.rows.filter { $0.roleGuess == VisionRoleGuess.row }
    #expect(rows.count == 5)
    // Every one of them must be evidenced by the TEXT BAND layer: these rows
    // have no fill contrast at all, so a colour-region-only pipeline would
    // report nothing here — which is precisely the spike's known miss.
    #expect(rows.allSatisfy { $0.evidence.contains(.textBand) })
    _ = scene
}

@Test func everyRowCarriesProvenanceAndAllFiveConfidences() throws {
    let (_, percept) = try compileMainScene()
    #expect(!percept.rows.isEmpty)
    guard case .object(let payload) = percept.toJSON(),
          case .array(let affordances)? = payload["affordances"] else {
        Issue.record("percept JSON has no affordances array")
        return
    }
    #expect(affordances.count == percept.rows.count)
    for entry in affordances {
        guard case .object(let row) = entry else {
            Issue.record("affordance row is not an object")
            continue
        }
        #expect(row["provenance"] == .string("vision"))
        #expect(row["label_source"] == .string("vision"))
        guard case .object(let confidence)? = row["confidence"] else {
            Issue.record("row \(row["handle"] ?? .null) has no confidence object")
            continue
        }
        // FIVE attributes, all present, every time. `target` is the amendment
        // that came out of the verbatim audit and is the one an actuator gates
        // on, so its absence is a contract break, not a missing nicety.
        for attribute in ["bounds", "role", "state", "text", "target"] {
            #expect(confidence[attribute] != nil, "confidence.\(attribute) missing")
        }
    }
}

@Test func noRowClaimsFabricatedCertainty() throws {
    let (_, percept) = try compileMainScene()
    for row in percept.rows {
        #expect(row.confidence.role < 1.0, "\(row.roleGuess) claimed role certainty")
        #expect(row.confidence.target < 1.0, "\(row.roleGuess) claimed target certainty")
        if row.roleGuess == VisionRoleGuess.unknown {
            // An unknown role is AXUnknown + a low confidence, never a guessed
            // AXButton at 1.0.
            #expect(row.confidence.role <= 0.25)
        }
    }
}

@Test func disabledIsGuessedExplicitlyAndNeverAsABareBoolean() throws {
    let (scene, percept) = try compileMainScene()
    let archive = try #require(
        scene.hit(scene.targets.first { $0.name == "Archive" }!, in: percept.rows)
    )
    let save = try #require(
        scene.hit(scene.targets.first { $0.name == "Save" }!, in: percept.rows)
    )
    // The load-bearing guess: a greyed control must be NAMED as one, with a
    // confidence, rather than clicked hopefully.
    let disabled = try #require(archive.state.disabled)
    #expect(disabled.value == true)
    #expect(disabled.confidence > 0 && disabled.confidence < 1)
    #expect(disabled.evidence.contains("spread"))
    #expect(save.state.disabled?.value == false)

    // …and in the payload it is an OBJECT with its own confidence, never a
    // bare boolean that reads as fact.
    guard case .object(let json) = archive.toJSON(),
          case .object(let state)? = json["state"],
          case .object(let flag)? = state["disabled"] else {
        Issue.record("disabled did not serialize as an object")
        return
    }
    #expect(flag["value"] == .bool(true))
    #expect(flag["confidence"] != nil)
    #expect(flag["evidence"] != nil)
}

@Test func destructiveActionsAreTagged() throws {
    let (scene, percept) = try compileMainScene()
    let delete = try #require(
        scene.hit(scene.targets.first { $0.name == "Delete Account" }!, in: percept.rows)
    )
    #expect(delete.destructiveRisk)
    let save = try #require(
        scene.hit(scene.targets.first { $0.name == "Save" }!, in: percept.rows)
    )
    #expect(!save.destructiveRisk)
}

@Test func theSameFrameCompilesToTheSamePercept() throws {
    let (_, first) = try compileMainScene()
    let (_, second) = try compileMainScene()
    #expect(first.rows.map(\.handle) == second.rows.map(\.handle))
    #expect(first.toJSON() == second.toJSON())
}

@Test func handlesSurviveAHarmlessRedraw() throws {
    let (_, before) = try compileMainScene()
    let (_, after) = try compileMainScene(redraw: true)
    // The redraw adds a caret, changes a decoration one shade, and nudges the
    // controls by a pixel. Nothing material moved, so nothing may be renamed.
    let stable = Set(before.rows.map(\.handle)).intersection(after.rows.map(\.handle))
    let labeled = before.rows.filter { $0.displayLabel?.isEmpty == false }
    let renamed = labeled.map(\.handle).filter { !stable.contains($0) }
    #expect(renamed.isEmpty, "labeled handles changed across a harmless redraw: \(renamed)")
}

@Test func emitsTheSharedMacLookPerceptShape() throws {
    let (_, percept) = try compileMainScene()
    let shared = percept.percept
    #expect(shared.affordances.count == percept.rows.count)
    #expect(shared.interactiveCount == percept.rows.count)
    #expect(shared.affordances.allSatisfy { $0.labelSource == "vision" })
    #expect(shared.affordances.allSatisfy { $0.frame != nil })
    // A believed-disabled control reads disabled on the shared bare bool too —
    // conservative, because that bool has no room for a confidence.
    let archive = try #require(shared.affordances.first { $0.label.hasPrefix("Archiv") })
    #expect(!archive.enabled)
    // The glance says which organ produced it. A caller must never have to
    // guess whether a sentence came from AX or from pixels.
    #expect(percept.glanceLine().hasPrefix("[vision] "))
    #expect(percept.glanceLine().contains("AX-blind window"))
}

@Test func prominentStandaloneValuesBecomeReadouts() throws {
    let (_, percept) = try compileMainScene()
    // The 24 pt title is the one text on this screen nobody claimed and that
    // stands out by size.
    #expect(percept.readouts.contains { $0.text.display == "Account Settings" })
    // A readout is not an act target and does not pretend to be one.
    #expect(percept.readouts.allSatisfy { $0.confidence.target <= 0.25 })
}

@Test func visionRowsBecomeConfidenceGatedFourVerbTargetsInGlobalCoordinates() throws {
    let (_, percept) = try compileMainScene()
    let supplement = percept.fourVerbSupplement(
        origin: (100, 200),
        logicalSize: (600, 400),
        viewId: "hidden-view"
    )

    #expect(supplement.contents.contains(where: { $0.kind == .canvas }))
    #expect(!supplement.targets.isEmpty)
    #expect(supplement.targets.count < percept.rows.count,
            "uncertain/destructive rows must remain visible but unaddressable")
    #expect(supplement.targets.allSatisfy { $0.frame.x >= 100 && $0.frame.y >= 200 })
    #expect(supplement.targets.allSatisfy { $0.viewId == "hidden-view" })
    #expect(supplement.controls.contains(where: { $0.abstain != nil }),
            "an abstain must be printed, never silently dropped")
}

@Test func saliencyRanksAndAddsWithoutInventingRoles() throws {
    let scene = Scene.mainScene()
    // Deterministic saliency: one blob over a known button (ranking) and one
    // over an iconic region neither colour nor text found (adding).
    let provider = VisionStaticSalienceProvider(regions: [
        (VisionRect(x: 40, y: 80, w: 130, h: 42), 0.9),
        (VisionRect(x: 780, y: 460, w: 60, h: 60), 0.7),
    ])
    let percept = try VisionPerceptionCompiler(salience: provider).compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    let save = try #require(percept.rows.first { $0.displayLabel == "Save" })
    #expect(save.evidence.contains(.saliency))
    #expect(save.salience > 0)
    let added = try #require(percept.rows.first { $0.evidence == [.saliency] })
    // Saliency knows nothing about what a region IS, and the row says so.
    #expect(added.roleGuess == VisionRoleGuess.unknown)
    #expect(added.confidence.role <= 0.25)
    #expect(added.confidence.bounds <= 0.4)
}

@Test func salientUnknownObjectsBecomeNumberedPhysicalRegionsWithoutInventedSemantics() throws {
    let scene = Scene.mainScene()
    let provider = VisionStaticSalienceProvider(regions: [
        (VisionRect(x: 780, y: 460, w: 60, h: 60), 0.7),
    ])
    let percept = try VisionPerceptionCompiler(salience: provider).compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    let supplement = percept.fourVerbSupplement(
        origin: (100, 200),
        logicalSize: (900, 600),
        viewId: "live-view"
    )

    let region = try #require(supplement.targets.first {
        $0.label?.display == "visual region 1"
    })
    #expect(region.kind == "visual region")
    #expect(region.physicalOnly)
    #expect(!region.regionOnly)
    #expect(region.viewId == "live-view")
    #expect(supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "visual region 1"
            && $0.abstain == "physical region; semantic role uncertain"
    })
}
