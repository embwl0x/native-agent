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

@Test func foregroundExclusionRemovesTextAndObjectsButKeepsUncoveredScene() throws {
    let scene = Scene.mainScene()
    let covered = try #require(scene.targets.first).rect
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image,
        using: VisionKitTextRecognizer(),
        excludedRegions: [covered]
    )
    #expect(!percept.rows.isEmpty)
    #expect(percept.rows.allSatisfy { $0.rect.intersection(covered).area == 0 })
    #expect(percept.readouts.allSatisfy { $0.rect.intersection(covered).area == 0 })
    for text in percept.recognizedText {
        let rect = try #require(text.rect)
        #expect(rect.intersection(covered).area == 0)
    }
    for target in scene.targets.dropFirst() where target.rect.intersection(covered).area == 0 {
        #expect(scene.hit(target, in: percept.rows) != nil, "uncovered target lost: \(target.name)")
    }
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
    #expect(supplement.contents.first(where: { $0.kind == .canvas })?.canvas?.hasPerceptualEvidence == true)
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

@Test func centeredSaliencyHaloCorroboratesPreciseObjectWithoutDuplicatingIt() throws {
    let precise = VisionCandidate(
        rect: VisionRect(x: 470, y: 470, w: 40, h: 40),
        sources: [.colorRegion],
        boundsConfidence: 0.85,
        fillLuminance: 0.7
    )
    // IoU is only 0.16: the old IoU-only fold emitted this soft halo as a
    // second object even though it is centred on and tightly contains the
    // precise candidate.
    let folded = VisionSaliencyLayer.fold(
        salient: [(VisionRect(x: 440, y: 440, w: 100, h: 100), 0.8)],
        into: [precise],
        imageSize: VisionSize(width: 1000, height: 1000)
    )

    #expect(folded.count == 1)
    #expect(folded[0].rect == precise.rect)
    #expect(folded[0].sources.contains(.saliency))
    #expect(folded[0].salience == 0.8)
}

@Test func broadSaliencyPanelDoesNotAbsorbContainedControl() throws {
    let control = VisionCandidate(
        rect: VisionRect(x: 470, y: 470, w: 40, h: 40),
        sources: [.colorRegion],
        boundsConfidence: 0.85
    )
    let folded = VisionSaliencyLayer.fold(
        salient: [(VisionRect(x: 250, y: 250, w: 500, h: 500), 0.8)],
        into: [control],
        imageSize: VisionSize(width: 1000, height: 1000)
    )

    #expect(folded.count == 2)
    #expect(folded.contains { $0.sources == [.saliency] })
}

@Test func salientUnknownObjectsBecomeNumberedPhysicalRegionsWithoutInventedSemantics() throws {
    let scene = Scene.mainScene()
    let provider = VisionStaticSalienceProvider(regions: [
        (VisionRect(x: 780, y: 460, w: 60, h: 60), 0.7),
    ])
    let percept = try VisionPerceptionCompiler(salience: provider).compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    let physicalRow = try #require(percept.rows.first { $0.evidence == [.saliency] })
    let supplement = percept.fourVerbSupplement(
        origin: (100, 200),
        logicalSize: (900, 600),
        viewId: "live-view",
        liveRegionIdentities: [
            physicalRow.rect: VisionLiveRegionIdentity(
                id: 1, motion: "moving right", projectedX: 12, projectedY: -4
            ),
        ]
    )

    let region = try #require(supplement.targets.first {
        $0.label?.display == "visual region 1"
    })
    #expect(region.kind == "visual region")
    #expect(region.physicalOnly)
    #expect(!region.motionUncertain, "a measured moving trajectory needs no acquisition frames")
    let firstEstimate = percept.fourVerbSupplement(
        origin: (100, 200), logicalSize: (900, 600), viewId: "live-view",
        liveRegionIdentities: [physicalRow.rect: VisionLiveRegionIdentity(
            id: 1, motion: "moving right", projectedX: 12, projectedY: -4,
            needsMotionConfirmation: true)]
    )
    #expect(firstEstimate.targets.first { $0.label?.display == "visual region 1" }?.motionUncertain == true,
        "readable motion prose must not end acquisition before motor evidence is corroborated")
    #expect(!region.regionOnly)
    #expect(region.viewId == "live-view")
    #expect(region.aliases.contains("moving object"))
    let scaleX = 900 / percept.frameSize.width
    let scaleY = 600 / percept.frameSize.height
    #expect(region.frame.x == 100 + physicalRow.rect.x * scaleX + 12)
    #expect(region.frame.y == 200 + physicalRow.rect.y * scaleY - 4)
    #expect(region.observedFrame.x == 100 + physicalRow.rect.x * scaleX)
    #expect(region.observedFrame.y == 200 + physicalRow.rect.y * scaleY)
    let canvas = try #require(supplement.targets.first { $0.regionOnly && $0.kind == "canvas" })
    #expect(canvas.aliases == ["canvas", "viewport", "world"])
    #expect(supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "visual region 1"
            && $0.detail.first?.display == "compact physical object"
            && $0.abstain == nil && $0.physicalOnly
    })
    let ordinary = MacScreenRender.render(MacScreenRender.Screen(appName: "Scene", contents: supplement.contents))
    #expect(ordinary.contains("moving right"), "ordinary screen must retain motion without requiring canvas zoom")
    #expect(ordinary.contains("size "))
}

@Test func unlabeledUnaddressableFragmentsCollapseIntoOneHonestSummary() throws {
    func fragment(_ handle: String, x: Double, reason: String) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle,
            handleAmbiguity: nil,
            roleGuess: "AXStaticText",
            roleRationale: "text-shaped pixels",
            label: nil,
            rect: VisionRect(x: x, y: 20, w: 30, h: 12),
            confidence: VisionConfidence(bounds: 0.4, role: 0.2, state: 0, text: 0.3, target: 0.25),
            state: VisionStateGuess(),
            evidence: [.textBand],
            ambiguous: reason,
            destructiveRisk: false,
            salience: 0
        )
    }
    let rows = [
        fragment("a", x: 20, reason: "overlapping candidate — action points coincide"),
        fragment("b", x: 80, reason: "target confidence below physical-action floor"),
    ]
    let shared = MacLookPercept(
        app: nil, windowTitle: nil, focus: nil, modal: nil, landmarks: [],
        affordances: [], unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: 0, labeledCount: 0, truncated: false,
        truncationReasons: [], skippedAtLeast: 0
    )
    let percept = VisionPercept(
        percept: shared,
        rows: rows,
        readouts: [],
        abstain: VisionAbstainReport(considered: 2, abstained: 2, reasons: [:]),
        frameSize: VisionSize(width: 400, height: 300),
        textTiled: false,
        textTilingReason: "not needed",
        recognizedStrings: 0,
        recognizedText: [],
        notes: []
    )

    let supplement = percept.fourVerbSupplement(
        origin: (0, 0), logicalSize: (400, 300), viewId: "summary-view"
    )
    let visibleRows = supplement.contents.flatMap(\.rows)
    #expect(visibleRows.count == 1)
    #expect(visibleRows[0].label?.display == "2 uncertain visual fragments")
    #expect(visibleRows[0].abstain?.contains("1 overlapping") == true)
    #expect(visibleRows[0].abstain?.contains("1 low target confidence") == true)
    #expect(supplement.targets.allSatisfy { $0.label?.display != "a" && $0.label?.display != "b" })
}

@Test func physicalRegionConfidenceMeasuresPointingWithoutInventingRoleCertainty() throws {
    let row = VisionAffordanceRow(
        handle: "bright-object",
        handleAmbiguity: nil,
        roleGuess: "AXCheckBox",
        roleRationale: "small square filled region",
        label: nil,
        rect: VisionRect(x: 100, y: 80, w: 60, h: 60),
        confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(),
        evidence: [.colorRegion],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0,
        visualContrast: 0.8,
        visualColor: "yellow",
        visualShape: "round"
    )
    let halo = VisionAffordanceRow(
        handle: "soft-halo",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "attention blob only",
        label: nil,
        rect: VisionRect(x: 80, y: 60, w: 100, h: 100),
        confidence: VisionConfidence(bounds: 0.35, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(),
        evidence: [.saliency],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0.8,
        visualContrast: nil,
        visualColor: nil
    )
    let broadAttentionField = VisionAffordanceRow(
        handle: "broad-field",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "attention blob only",
        label: nil,
        rect: VisionRect(x: 190, y: 120, w: 200, h: 150),
        confidence: VisionConfidence(bounds: 0.35, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(),
        evidence: [.saliency],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0.8
    )
    let linearIndicator = VisionAffordanceRow(
        handle: "green-strip",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "strongly bounded color strip",
        label: nil,
        rect: VisionRect(x: 20, y: 20, w: 100, h: 6),
        confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(),
        evidence: [.colorRegion],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0,
        visualContrast: 0.8,
        visualColor: "green"
    )
    let linearIndicatorRemainder = VisionAffordanceRow(
        handle: "blue-strip",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "strongly bounded color strip",
        label: nil,
        rect: VisionRect(x: 120, y: 20, w: 40, h: 6),
        confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(),
        evidence: [.colorRegion],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0,
        visualContrast: 0.4,
        visualColor: "blue"
    )
    let strayMarker = VisionAffordanceRow(
        handle: "stray-marker",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "OCR marker without a grounded role",
        label: VisionRedactedText(raw: "• •", json: .string("• •"), secret: false, reason: nil),
        rect: VisionRect(x: 175, y: 4, w: 10, h: 10),
        confidence: VisionConfidence(bounds: 0.4, role: 0.1, state: 0, text: 0.8, target: 0.2),
        state: VisionStateGuess(),
        evidence: [.textBand],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0.1
    )
    let shared = MacLookPercept(
        app: nil, windowTitle: nil, focus: nil, modal: nil, landmarks: [],
        affordances: [], unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: 0, labeledCount: 0, truncated: false,
        truncationReasons: [], skippedAtLeast: 0
    )
    let percept = VisionPercept(
        percept: shared,
        rows: [halo, broadAttentionField, linearIndicator, linearIndicatorRemainder, strayMarker, row],
        readouts: [VisionReadoutRow(
            handle: "bullet-readout",
            text: VisionRedactedText(raw: "•", json: .string("•"), secret: false, reason: nil),
            rect: VisionRect(x: 180, y: 4, w: 8, h: 8),
            confidence: VisionConfidence(bounds: 0.9, role: 0, state: 0, text: 1, target: 0)
        )],
        abstain: VisionAbstainReport(considered: 5, abstained: 5, reasons: [:]),
        frameSize: VisionSize(width: 400, height: 300),
        textTiled: false,
        textTilingReason: "not needed",
        recognizedStrings: 2,
        recognizedText: [
            VisionRecognizedText(
                text: VisionRedactedText(raw: "Energy: 71%", json: .string("Energy: 71%"), secret: false, reason: nil),
                confidence: 1,
                rect: VisionRect(x: 20, y: 4, w: 90, h: 14)
            ),
            VisionRecognizedText(
                text: VisionRedactedText(raw: "•", json: .string("•"), secret: false, reason: nil),
                confidence: 1,
                rect: VisionRect(x: 180, y: 4, w: 8, h: 8)
            ),
        ],
        notes: []
    )

    let supplement = percept.fourVerbSupplement(
        origin: (0, 0), logicalSize: (400, 300), viewId: "point-view"
    )
    let rendered = try #require(supplement.contents.flatMap(\.rows).first)
    let target = try #require(supplement.targets.first { $0.physicalOnly })

    #expect(rendered.detail.first?.display == "round physical object")
    #expect(rendered.detail.contains { $0.display?.contains("yellow") == true })
    #expect(rendered.detail.contains {
        $0.display?.contains("at 33%,37%, size 15%x20%") == true
    })
    #expect(rendered.abstain == nil)
    #expect(rendered.physicalOnly)
    #expect(rendered.provenance == .vision(0.8))
    #expect(target.provenance == .vision(0.8))
    #expect(target.motionUncertain, "a new physical point has no motion evidence yet")
    #expect(supplement.targets.filter(\.physicalOnly).count == 1)
    #expect(!supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "visual region 2"
    })
    #expect(supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "2 uncertain visual fragments"
            && $0.abstain?.contains("low bounds confidence") == true
    })
    #expect(supplement.values.contains {
        $0.text.display == "Energy: 71% — horizontal segmented indicator (green 71%, blue 29%) at 23%,8%, length 35%"
    })
    #expect(!supplement.values.contains { $0.text.display == "Energy: 71%" })
    #expect(!supplement.values.contains { $0.text.display == "•" })
    #expect(!supplement.contents.flatMap(\.rows).contains { $0.label?.display == "• •" })
}

@Test func perceptualColorNamesStayCompactAndSemanticFree() {
    #expect(VisionColorSample(red: 1, green: 0.08, blue: 0.05).name == "red")
    #expect(VisionColorSample(red: 1, green: 0.85, blue: 0.08).name == "yellow")
    #expect(VisionColorSample(red: 0.05, green: 0.8, blue: 0.15).name == "green")
    #expect(VisionColorSample(red: 0.05, green: 0.2, blue: 0.95).name == "blue")
    #expect(VisionColorSample(red: 0.16, green: 0.21, blue: 0.26).name == "dark blue")
    #expect(VisionColorSample(red: 0.9, green: 0.08, blue: 0.75).name == "magenta")
    #expect(VisionColorSample(red: 0.05, green: 0.06, blue: 0.07).name == "black")
    #expect(VisionColorSample(red: 0.95, green: 0.94, blue: 0.93).name == "white")
}

@Test func substantialLowContrastRegionRemainsPhysicallyAddressable() {
    let obstacle = VisionAffordanceRow(
        handle: "muted-obstacle",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "no matching shape",
        label: nil,
        rect: VisionRect(x: 100, y: 100, w: 84, h: 150),
        confidence: VisionConfidence(bounds: 0.86, role: 0.15, state: 0, text: 0, target: 0.2),
        state: VisionStateGuess(),
        evidence: [.colorRegion],
        ambiguous: "unlabeled region with no role guess — not separately addressable",
        destructiveRisk: false,
        salience: 0,
        visualContrast: 0.13,
        visualColor: "dark gray"
    )
    let tinyMutedFragment = VisionAffordanceRow(
        handle: "muted-fragment",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "no matching shape",
        label: nil,
        rect: VisionRect(x: 10, y: 10, w: 8, h: 8),
        confidence: VisionConfidence(bounds: 0.86, role: 0.15, state: 0, text: 0, target: 0.2),
        state: VisionStateGuess(),
        evidence: [.colorRegion],
        ambiguous: "unlabeled region with no role guess — not separately addressable",
        destructiveRisk: false,
        salience: 0,
        visualContrast: 0.13,
        visualColor: "dark gray"
    )
    let frame = VisionSize(width: 1_000, height: 1_000)
    #expect(VisionPercept.isPhysicalRegionCandidate(obstacle, frameSize: frame))
    #expect(!VisionPercept.isPhysicalRegionCandidate(tinyMutedFragment, frameSize: frame))

    let shared = MacLookPercept(
        app: nil, windowTitle: nil, focus: nil, modal: nil, landmarks: [],
        affordances: [], unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: 0, labeledCount: 0, truncated: false,
        truncationReasons: [], skippedAtLeast: 0
    )
    let percept = VisionPercept(
        percept: shared,
        rows: [obstacle],
        readouts: [],
        abstain: VisionAbstainReport(considered: 1, abstained: 1, reasons: [:]),
        frameSize: frame,
        textTiled: false,
        textTilingReason: "not needed",
        recognizedStrings: 0,
        recognizedText: [],
        notes: []
    )
    let supplement = percept.fourVerbSupplement(
        origin: (0, 0), logicalSize: (1_000, 1_000), viewId: "muted-world"
    )
    #expect(supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "visual region 1" && $0.provenance == .vision(0.13)
            && !$0.physicalOnly && $0.abstain == "physical point confidence too low; observe again"
    })
    #expect(!supplement.targets.contains { $0.physicalOnly })
}

@Test func overlappingSameColorDetectorViewsBecomeOnePhysicalObject() {
    func yellow(_ handle: String, rect: VisionRect, bounds: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle,
            handleAmbiguity: nil,
            roleGuess: "AXUnknown",
            roleRationale: "no matching shape",
            label: nil,
            rect: rect,
            confidence: VisionConfidence(bounds: bounds, role: 0.15, state: 0, text: 0, target: 0.2),
            state: VisionStateGuess(),
            evidence: [.colorRegion],
            ambiguous: "unlabeled region with no role guess — not separately addressable",
            destructiveRisk: false,
            salience: 0.4,
            visualContrast: 0.8,
            visualColor: "yellow"
        )
    }
    let weaker = yellow(
        "yellow-soft", rect: VisionRect(x: 100, y: 100, w: 44, h: 44), bounds: 0.84
    )
    let stronger = yellow(
        "yellow-core", rect: VisionRect(x: 102, y: 101, w: 40, h: 40), bounds: 0.94
    )
    let separate = yellow(
        "yellow-other", rect: VisionRect(x: 180, y: 100, w: 40, h: 40), bounds: 0.94
    )
    let redundant = VisionPercept.redundantSameColorRegionIndexes(
        in: [weaker, stronger, separate],
        frameSize: VisionSize(width: 400, height: 300)
    )
    #expect(redundant == [0])
}

@Test func stableVisualRegionsExposeABoundedRelativeSceneGraph() throws {
    func object(_ handle: String, color: String, x: Double, y: Double, shape: String? = nil) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle,
            handleAmbiguity: nil,
            roleGuess: "AXUnknown",
            roleRationale: "no matching shape",
            label: nil,
            rect: VisionRect(x: x, y: y, w: 20, h: 20),
            confidence: VisionConfidence(bounds: 0.9, role: 0.15, state: 0, text: 0, target: 0.2),
            state: VisionStateGuess(),
            evidence: [.colorRegion],
            ambiguous: "unlabeled region with no role guess — not separately addressable",
            destructiveRisk: false,
            salience: 0,
            visualContrast: 0.8,
            visualColor: color, visualShape: shape
        )
    }
    let rows = [
        object("yellow", color: "yellow", x: 10, y: 100, shape: "square"),
        object("blue", color: "blue", x: 100, y: 100, shape: "round"),
        object("green", color: "green", x: 100, y: 10),
    ]
    let shared = MacLookPercept(
        app: nil, windowTitle: nil, focus: nil, modal: nil, landmarks: [],
        affordances: [], unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: 0, labeledCount: 0, truncated: false,
        truncationReasons: [], skippedAtLeast: 0
    )
    let percept = VisionPercept(
        percept: shared,
        rows: rows,
        readouts: [],
        abstain: VisionAbstainReport(considered: 3, abstained: 3, reasons: [:]),
        frameSize: VisionSize(width: 200, height: 200),
        textTiled: false,
        textTilingReason: "not needed",
        recognizedStrings: 0,
        recognizedText: [],
        notes: []
    )
    let identities = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
        ($0.element.rect, VisionLiveRegionIdentity(
            id: $0.offset + 1,
            motion: $0.offset == 0 ? "moving right slowly"
                : $0.offset == 2 ? "stationary" : nil
        ))
    })
    let supplement = percept.fourVerbSupplement(
        origin: (0, 0),
        logicalSize: (200, 200),
        liveRegionIdentities: identities,
        liveOccludedRegions: [VisionLiveOccludedRegion(
            id: 9,
            colorName: "red",
            shapeName: "round",
            lastCenterXPercent: 70,
            lastCenterYPercent: 40,
            expectedCenterXPercent: 74,
            expectedCenterYPercent: 42,
            missedFrames: 1,
            confidence: 0.5
        )]
    )
    #expect(supplement.values.contains {
        $0.text.display == "square yellow visual region 1 is left of round blue visual region 2"
    })
    #expect(supplement.values.contains {
        $0.text.display == "round blue visual region 2 is below green visual region 3"
    })
    #expect(supplement.values.contains {
        $0.text.display == "round red visual region 9 temporarily not visible; last seen at 70%,40% (1 frame ago); expected near 74%,42% if motion continued"
    })
    let yellowTarget = supplement.targets.first { $0.label?.display == "visual region 1" }
    #expect(yellowTarget?.aliases.contains("yellow object on the left") == true)
    #expect(yellowTarget?.aliases.contains("yellow object at middle left") == true)
    #expect(yellowTarget?.aliases.contains("moving yellow object") == true)
    #expect(yellowTarget?.aliases.contains("yellow object moving right slowly") == true)
    #expect(yellowTarget?.aliases.contains("yellow object left of blue object") == true)
    #expect(yellowTarget?.aliases.contains("yellow square left of blue circle") == true)
    #expect(yellowTarget?.aliases.contains("square left of blue circle") == true)
    #expect(yellowTarget?.aliases.contains("yellow square right of blue circle") == false)
    #expect(yellowTarget?.aliases.contains("yellow circle left of blue square") == false)
    let greenTarget = supplement.targets.first { $0.label?.display == "visual region 3" }
    #expect(greenTarget?.aliases.contains("stationary green object") == true)
    #expect(supplement.diagnostics["vision_effect_value_text"] == .array([]))
    #expect(!supplement.targets.contains { $0.label?.display == "visual region 9" })
}

@Test func overlappingVisualRegionsAreDescribedAsOverlapRatherThanDirection() {
    func object(_ handle: String, color: String, shape: String, rect: VisionRect) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle, handleAmbiguity: nil,
            roleGuess: "AXUnknown", roleRationale: "bounded colored object", label: nil,
            rect: rect,
            confidence: VisionConfidence(bounds: 0.9, role: 0.15, state: 0, text: 0, target: 0.2),
            state: VisionStateGuess(), evidence: [.colorRegion],
            ambiguous: "unlabeled region with no role guess — not separately addressable",
            destructiveRisk: false, salience: 0, visualContrast: 0.8,
            visualColor: color, visualShape: shape
        )
    }
    let rows = [
        object("target", color: "yellow", shape: "round", rect: VisionRect(x: 60, y: 60, w: 40, h: 40)),
        object("obstacle", color: "dark blue", shape: "square", rect: VisionRect(x: 80, y: 70, w: 50, h: 50)),
    ]
    let shared = MacLookPercept(
        app: nil, windowTitle: nil, focus: nil, modal: nil, landmarks: [],
        affordances: [], unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: 0, labeledCount: 0, truncated: false,
        truncationReasons: [], skippedAtLeast: 0
    )
    let percept = VisionPercept(
        percept: shared, rows: rows, readouts: [],
        abstain: VisionAbstainReport(considered: 2, abstained: 2, reasons: [:]),
        frameSize: VisionSize(width: 200, height: 200),
        textTiled: false, textTilingReason: "not needed", recognizedStrings: 0,
        recognizedText: [], notes: []
    )
    let identities = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
        ($0.element.rect, VisionLiveRegionIdentity(
            id: $0.offset + 1,
            motion: $0.offset == 0 ? "moving right slowly" : "stationary"
        ))
    })

    let supplement = percept.fourVerbSupplement(
        origin: (0, 0), logicalSize: (200, 200), liveRegionIdentities: identities
    )

    #expect(supplement.values.contains {
        $0.text.display == "round yellow visual region 1 overlaps square dark blue visual region 2"
    }, "\(supplement.values.compactMap(\.text.display))")
    #expect(!supplement.values.contains { $0.text.display?.contains("left of") == true })
    let target = supplement.targets.first { $0.label?.display == "visual region 1" }
    #expect(target?.aliases.contains("round yellow object") == true)
    #expect(target?.aliases.contains("yellow object") == true)
    #expect(target?.aliases.contains("moving round yellow object") == true)
    #expect(target?.aliases.contains("moving object") == true)
    #expect(target?.aliases.contains("moving round object") == true)
    #expect(target?.aliases.contains("yellow circle") == true)
    #expect(target?.aliases.contains("moving yellow circle") == true)
    #expect(target?.aliases.contains("stationary yellow circle") == false)
    #expect(target?.aliases.contains("yellow square") == false)
    #expect(target?.aliases.contains("yellow circle overlapping dark blue square") == true)
    #expect(target?.aliases.contains("yellow circle left of dark blue square") == false)
    let obstacle = supplement.targets.first { $0.label?.display == "visual region 2" }
    #expect(obstacle?.aliases.contains("stationary square dark blue object") == true)
    #expect(obstacle?.aliases.contains("stationary object") == true)
    #expect(obstacle?.aliases.contains("stationary square object") == true)
    #expect(obstacle?.aliases.contains("dark blue square") == true)
    #expect(obstacle?.aliases.contains("stationary dark blue square") == true)
    #expect(obstacle?.aliases.contains("stationary square") == true)
    #expect(obstacle?.aliases.contains("moving dark blue square") == false)
    #expect(obstacle?.aliases.contains("dark blue circle") == false)

    let unknownMotion = percept.fourVerbSupplement(origin: (0, 0), logicalSize: (200, 200))
    #expect(unknownMotion.targets.contains { $0.aliases.contains("dark blue square") })
    #expect(!unknownMotion.targets.contains { $0.aliases.contains("stationary dark blue square") })
}
