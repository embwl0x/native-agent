import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import Testing
import VisionPerception
@testable import ChatOrchestration

private struct _FourVerbViewHost: MacFourVerbsHost {
    let output: JSONValue
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        #expect(action == "view")
        #expect(body["semantic_raw_frame"] == .bool(true))
        #expect(body["semantic_focus_visual_surface"] == .bool(true))
        return MacControlResult(
            ok: true, action: action, output: output,
            error: nil, durationMs: 0, viaSwift: true
        )
    }
}

private func _viewMark(
    _ number: Int,
    role: String,
    label: String?,
    x: Double
) -> JSONValue {
    var object: [String: JSONValue] = [
        "mark": .int(Int64(number)),
        "path": .array([.int(Int64(number))]),
        "role": .string(role),
        "enabled": .bool(true),
        "frame": .object([
            "x": .double(x), "y": .double(100), "w": .double(80), "h": .double(28),
        ]),
    ]
    if let label { object["label"] = .string(label) }
    else { object["label_source"] = .string("none") }
    return .object(object)
}

@Test func fusedViewCarriesOnlyFiniteObservedPointerPositions() async throws {
    for point: JSONValue in [.object(["x": .double(-200), "y": .double(300)]),
                             .object(["x": .string("200"), "y": .double(300)]), .null] {
        let host = _FourVerbViewHost(output: .object([
            "accessibility_trusted": .bool(true), "pointer": point,
            "origin": .object(["x": .int(-500), "y": .int(0)]),
            "logical_size": .object(["w": .int(800), "h": .int(600)]),
        ]))
        let supplement = try #require(await SwiftToolDispatcherFourVerbPerceptionSource(host: host).observe())
        if point == .object(["x": .double(-200), "y": .double(300)]) {
            #expect(supplement.pointer == MacPointerPosition(x: -200, y: 300))
        } else { #expect(supplement.pointer == nil) }
    }
}

@Test func transientMenusBecomeFreshNamedTargetsWithoutWindowHandles() async throws {
    let rect: JSONValue = .object(["x": .int(100), "y": .int(120), "w": .int(200), "h": .int(24)])
    let host = _FourVerbViewHost(output: .object([
        "accessibility_trusted": .bool(true),
        "transient_menus": .array([.object([
            "truncated": .bool(true),
            "items": .array([
                .object(["role": .string("AXMenuItem"), "label": .string("Inspect"),
                         "enabled": .bool(true), "frame": rect]),
                .object(["role": .string("AXMenuItem"), "label": .string("Disabled"),
                         "enabled": .bool(false), "frame": rect]),
            ]),
        ])]),
    ]))
    let supplement = try #require(await SwiftToolDispatcherFourVerbPerceptionSource(host: host).observe())
    #expect(supplement.controls.map(\.label.display) == ["Inspect", "Disabled"])
    #expect(supplement.targets.map(\.enabled) == [true, false])
    #expect(supplement.targets.allSatisfy { $0.kind == "menu item" && $0.provenance == .ax })
    #expect(supplement.targets.allSatisfy { $0.viewId == nil && $0.mark == nil && $0.sourceAXPath == nil })
    #expect(supplement.values.contains { $0.text.display?.contains("truncated") == true })
}

@Test
func higherLayerForegroundWindowObstructsTheVisualWorldButSystemChromeDoesNot() throws {
    let world = MacAXFrame(x: 0, y: 0, w: 1_000, h: 800)
    let windows = [
        MacVisualWindowRecord(
            ownerPID: 900,
            ownerName: "Control Center",
            layer: 25,
            frame: MacAXFrame(x: 0, y: 0, w: 1_000, h: 24),
            alpha: 1
        ),
        MacVisualWindowRecord(
            ownerPID: 901,
            ownerName: "UserNotificationCenter",
            layer: 8,
            frame: MacAXFrame(x: 250, y: 150, w: 500, h: 400),
            alpha: 1
        ),
        MacVisualWindowRecord(
            ownerPID: 100,
            ownerName: "Google Chrome",
            layer: 0,
            frame: world,
            alpha: 1
        ),
    ]
    let obstruction = try #require(SystemMacVisualObstructionProbe.obstructions(
        in: windows, over: world, targetPID: 100
    ).first)
    #expect(obstruction.ownerName == "UserNotificationCenter")
    #expect(abs(obstruction.coverage - 0.25) < 0.001)
    #expect(SystemMacVisualObstructionProbe.obstructions(
        in: [windows[0], windows[2]], over: world, targetPID: 100
    ).isEmpty)
}

@Test
func smallAndSameAppOverlaysAreSpatialObstructionsWithoutDisablingClearTargets() throws {
    let world = MacAXFrame(x: 0, y: 0, w: 2_330, h: 1_359)
    let popup = MacAXFrame(x: 900, y: 200, w: 260, h: 250)
    let floating = MacAXFrame(x: 1_400, y: 500, w: 120, h: 100)
    let windows = [
        MacVisualWindowRecord(ownerPID: 901, ownerName: "System dialog", layer: 8, frame: popup, alpha: 1),
        MacVisualWindowRecord(ownerPID: 100, ownerName: "Target app", layer: 0, frame: floating, alpha: 1),
        MacVisualWindowRecord(ownerPID: 100, ownerName: "Target app", layer: 0, frame: world, alpha: 1),
        MacVisualWindowRecord(ownerPID: 902, ownerName: "Behind", layer: 0, frame: world, alpha: 1),
    ]
    let obstructions = SystemMacVisualObstructionProbe.obstructions(in: windows, over: world, targetPID: 100)
    #expect(obstructions.count == 2)
    #expect(obstructions.allSatisfy { $0.coverage < 0.03 })
    #expect(obstructions.contains { $0.covers(MacAXFrame(x: 920, y: 220, w: 30, h: 30)) })
    #expect(obstructions.contains { $0.covers(MacAXFrame(x: 1_410, y: 510, w: 20, h: 20)) })
    #expect(!obstructions.contains { $0.covers(MacAXFrame(x: 100, y: 700, w: 40, h: 40)) })
    // A projected point moving under the popup must be withheld too.
    #expect(!obstructions[0].covers(MacAXFrame(x: 850, y: 220, w: 40, h: 40)))
    #expect(obstructions[0].covers(MacAXFrame(x: 880, y: 220, w: 40, h: 40)))
}

@Test
func fusedViewMakesInferredRowsAndUnnamedControlsAddressableWithoutLeakingViewIds() async {
    let marks: [JSONValue] = [
        _viewMark(1, role: "AXRow", label: "Screenshots", x: 10),
        _viewMark(2, role: "AXTextArea", label: nil, x: 100),
        _viewMark(3, role: "AXButton", label: "Back", x: 200),
        _viewMark(4, role: "AXButton", label: "Forward", x: 300),
        _viewMark(5, role: "AXButton", label: "Share", x: 400),
        _viewMark(6, role: "AXButton", label: "View", x: 500),
        _viewMark(7, role: "AXButton", label: "More", x: 600),
    ]
    let host = _FourVerbViewHost(output: .object([
        "view": .string("private-view-token"),
        "accessibility_trusted": .bool(true),
        "marks": .array(marks),
    ]))
    let supplement = await SwiftToolDispatcherFourVerbPerceptionSource(host: host).observe()

    #expect(supplement?.targets.contains(where: { $0.label?.display == "Screenshots" }) == true)
    #expect(supplement?.targets.contains(where: { $0.kind == "text area" && $0.label?.display == nil && $0.sourceAXPath == [2] }) == true)
    #expect(supplement?.controls.contains(where: { $0.kind == "text area" && $0.label.display == nil && $0.sourceAXPath == [2] }) == true)
    #expect(supplement?.targets.allSatisfy { $0.viewId == "private-view-token" } == true)
}

@Test
func liveSceneProjectsBoundedMotionThroughPerceptionDelay() async throws {
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let row = VisionAffordanceRow(
        handle: "moving-target",
        handleAmbiguity: nil,
        roleGuess: "AXUnknown",
        roleRationale: "attention blob only",
        label: nil,
        rect: VisionRect(x: 100, y: 100, w: 40, h: 40),
        confidence: VisionConfidence(bounds: 0.8, role: 0.2, state: 0, text: 0, target: 0.45),
        state: VisionStateGuess(),
        evidence: [.colorRegion, .saliency],
        ambiguous: nil,
        destructiveRisk: false,
        salience: 0.8,
        visualContrast: 0.8
    )
    func captured(_ epoch: Double) -> Date {
        SwiftToolDispatcherFourVerbPerceptionSource.captureDate(from: [
            "captured_at": .string("1970-01-01T00:16:40Z"),
            "captured_at_epoch_seconds": .double(epoch),
        ], fallback: Date(timeIntervalSince1970: 9_999))
    }
    let firstCapture = captured(1_000.125)
    _ = await scene.identify(
        rows: [row], frameSize: VisionSize(width: 1000, height: 1000),
        origin: (0, 0), logicalSize: (1000, 1000), sceneKey: "moving",
        capturedAt: firstCapture, now: firstCapture.addingTimeInterval(0.1)
    )
    let movedRect = VisionRect(x: 120, y: 100, w: 40, h: 40)
    let moved = VisionAffordanceRow(
        handle: row.handle,
        handleAmbiguity: nil,
        roleGuess: row.roleGuess,
        roleRationale: row.roleRationale,
        label: nil,
        rect: movedRect,
        confidence: row.confidence,
        state: row.state,
        evidence: row.evidence,
        ambiguous: nil,
        destructiveRisk: false,
        salience: row.salience,
        visualContrast: row.visualContrast
    )
    let secondCapture = captured(1_000.325)
    let snapshot = await scene.identify(
        rows: [moved], frameSize: VisionSize(width: 1000, height: 1000),
        origin: (0, 0), logicalSize: (1000, 1000), sceneKey: "moving",
        capturedAt: secondCapture, now: secondCapture.addingTimeInterval(0.1)
    )
    let identity = try #require(snapshot.identities[movedRect])

    #expect(identity.id == 1)
    #expect(identity.motion == "moving right")
    #expect(abs(identity.projectedX - 15) < 0.001)
    #expect(abs(identity.projectedY) < 0.001)

    // The jump is inside the old broad 220-point motion ceiling but outside
    // this object's normal spatial reach, so identity is appearance-only.
    let jumpedRect = VisionRect(x: 230, y: 100, w: 40, h: 40)
    let jumped = VisionAffordanceRow(
        handle: row.handle,
        handleAmbiguity: nil,
        roleGuess: row.roleGuess,
        roleRationale: row.roleRationale,
        label: nil,
        rect: jumpedRect,
        confidence: row.confidence,
        state: row.state,
        evidence: row.evidence,
        ambiguous: nil,
        destructiveRisk: false,
        salience: row.salience,
        visualContrast: row.visualContrast
    )
    let thirdCapture = captured(1_000.525)
    let afterJump = await scene.identify(
        rows: [jumped], frameSize: VisionSize(width: 1000, height: 1000),
        origin: (0, 0), logicalSize: (1000, 1000), sceneKey: "moving",
        capturedAt: thirdCapture, now: thirdCapture.addingTimeInterval(0.1)
    )
    let jumpedIdentity = try #require(afterJump.identities[jumpedRect])
    #expect(jumpedIdentity.id == identity.id)
    #expect(jumpedIdentity.motion == "repositioned")
    #expect(jumpedIdentity.projectedX == 0)
    #expect(jumpedIdentity.projectedY == 0)
}

@Test func capturedFrameTimingKeepsSubsecondSpacingAndParsesLegacyEvidence() {
    let fallback = Date(timeIntervalSince1970: 2_000)
    func parse(_ value: JSONValue?, _ text: String = "1970-01-01T00:16:40Z") -> Date {
        var output: [String: JSONValue] = ["captured_at": .string(text)]
        output["captured_at_epoch_seconds"] = value
        return SwiftToolDispatcherFourVerbPerceptionSource.captureDate(from: output, fallback: fallback)
    }
    let first = parse(.double(1_000.125))
    let second = parse(.double(1_000.245))
    #expect(abs(second.timeIntervalSince(first) - 0.12) < 0.000001)
    #expect(abs(parse(nil, "1970-01-01T00:16:40.375Z").timeIntervalSince1970 - 1_000.375) < 0.000001)
    #expect(parse(nil).timeIntervalSince1970 == 1_000)
    #expect(parse(.double(.infinity)).timeIntervalSince1970 == 1_000)
    #expect(parse(.string("invalid"), "invalid") == fallback)
}

@Test func corroboratedFastMotionCanCompensateLatencyBeyondTwoObjectWidths() async throws {
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let start = Date(timeIntervalSince1970: 5_000)
    func row(_ x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(handle: "fast", handleAmbiguity: nil, roleGuess: "AXUnknown",
            roleRationale: "bounded color", label: nil, rect: VisionRect(x: x, y: 200, w: 50, h: 50),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
            destructiveRisk: false, salience: 0, visualContrast: 0.8, visualColor: "yellow", visualShape: "round")
    }
    var snapshots: [VisionLiveSceneSnapshot] = []
    for (index, x) in [100.0, 350.0, 600.0].enumerated() {
        let date = start.addingTimeInterval(Double(index) * 0.25)
        snapshots.append(await scene.identify(rows: [row(x)], frameSize: VisionSize(width: 2000, height: 1000),
            origin: (0, 0), logicalSize: (2000, 1000), sceneKey: "fast", capturedAt: date,
            now: date.addingTimeInterval(0.15)))
    }
    let provisional = try #require(snapshots[1].identities[row(350).rect])
    #expect(provisional.projectedX == 0)
    let confirmed = try #require(snapshots[2].identities[row(600).rect])
    #expect(confirmed.motion?.hasPrefix("moving ") == true)
    #expect(abs(confirmed.projectedX - 200) < 0.001)
    #expect(confirmed.projectedX <= 250, "lead cannot exceed the corroborated frame travel")
}

@Test
func liveSceneUsesMeasuredTrajectoryToBridgeFastFrameGaps() async throws {
    func target(x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: "fast-target",
            handleAmbiguity: nil,
            roleGuess: "AXUnknown",
            roleRationale: "bounded colored object",
            label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
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
    }

    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 3_000)
    let initial = await scene.identify(
        rows: [target(x: 100)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (width: 1_000, height: 500), sceneKey: "fast",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let id = try #require(initial.identities[VisionRect(x: 100, y: 100, w: 40, h: 40)]?.id)

    let second = first.addingTimeInterval(0.2)
    _ = await scene.identify(
        rows: [target(x: 150)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (width: 1_000, height: 500), sceneKey: "fast",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )

    // The next 100-point step is outside the object's ordinary 60-point
    // association reach, but exactly continues its measured 250-point/s path.
    let third = second.addingTimeInterval(0.4)
    let continued = await scene.identify(
        rows: [target(x: 250)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (width: 1_000, height: 500), sceneKey: "fast",
        capturedAt: third, now: third.addingTimeInterval(0.1)
    )
    let identity = try #require(
        continued.identities[VisionRect(x: 250, y: 100, w: 40, h: 40)]
    )
    #expect(identity.id == id)
    #expect(identity.motion == "moving right quickly")
    #expect(abs(identity.projectedX - 37.5) < 0.001)

    let hiddenCapture = third.addingTimeInterval(0.2)
    let hidden = await scene.identify(
        rows: [], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (width: 1_000, height: 500), sceneKey: "fast",
        capturedAt: hiddenCapture, now: hiddenCapture.addingTimeInterval(0.1)
    )
    let occluded = try #require(hidden.temporarilyNotVisible.first { $0.id == id })
    #expect(occluded.shapeName == "round")
    #expect(occluded.lastCenterXPercent == 27)
    #expect(occluded.expectedCenterXPercent == 32)
    #expect(occluded.expectedCenterYPercent == 24)
}

@Test
func liveSceneDoesNotProjectThroughAMeasuredReversal() async throws {
    func target(x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: "reversing-target", handleAmbiguity: nil,
            roleGuess: "AXUnknown", roleRationale: "bounded colored object", label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
            destructiveRisk: false, salience: 0, visualContrast: 0.8,
            visualColor: "yellow", visualShape: "round"
        )
    }
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 4_000)
    _ = await scene.identify(
        rows: [target(x: 100)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "reversal",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let second = first.addingTimeInterval(0.2)
    _ = await scene.identify(
        rows: [target(x: 140)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "reversal",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )
    let third = second.addingTimeInterval(0.2)
    let reversedRect = VisionRect(x: 120, y: 100, w: 40, h: 40)
    let reversed = await scene.identify(
        rows: [target(x: 120)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "reversal",
        capturedAt: third, now: third.addingTimeInterval(0.1)
    )
    let identity = try #require(reversed.identities[reversedRect])

    #expect(identity.motion == "moving left")
    #expect(identity.projectedX == 0)
    #expect(identity.projectedY == 0)
}

@Test func liveSceneConfirmsFastAcquisitionWithoutPromotingUnverifiedJumps() async throws {
    func target(_ x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: "fast", handleAmbiguity: nil, roleGuess: "AXUnknown",
            roleRationale: "bounded color", label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
            destructiveRisk: false, salience: 0, visualContrast: 0.8,
            visualColor: "yellow", visualShape: "round"
        )
    }
    let cases: [(String, Double, Double, Bool, Bool)] = [
        ("continuous", 300, 0.4, false, true),
        ("reversed", 100, 0.4, false, false),
        ("another jump", 400, 0.4, false, false),
        ("stale", 300, 1.5, false, false),
        ("same-color ambiguity", 300, 0.4, true, false),
    ]
    for (name, finalX, finalTime, duplicate, shouldMove) in cases {
        let scene = SwiftToolDispatcherFourVerbLiveScene()
        func observe(_ x: Double, _ t: Double) async -> VisionLiveSceneSnapshot {
            let date = Date(timeIntervalSince1970: 5_000 + t)
            return await scene.identify(
                rows: [target(x)] + (duplicate ? [target(700)] : []),
                frameSize: VisionSize(width: 1_000, height: 500),
                origin: (0, 0), logicalSize: (1_000, 500), sceneKey: name,
                capturedAt: date, now: date.addingTimeInterval(0.1)
            )
        }
        _ = await observe(100, 0)
        let second = await observe(200, 0.2)
        let unconfirmed = try #require(second.identities[target(200).rect])
        #expect(unconfirmed.motion == "repositioned")
        #expect(unconfirmed.projectedX == 0 && unconfirmed.projectedY == 0)
        let third = await observe(finalX, finalTime)
        let final = try #require(third.identities[target(finalX).rect])
        if shouldMove {
            #expect(final.motion == "moving right quickly")
            #expect(abs(final.projectedX - 75) < 0.001)
        } else {
            #expect(final.projectedX == 0 && final.projectedY == 0, "unconfirmed \(name)")
        }
    }
}

@Test
func liveSceneKeepsMotionLanguageAcrossAnUndersampledFrame() async throws {
    func target(x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: "undersampled-target", handleAmbiguity: nil,
            roleGuess: "AXUnknown", roleRationale: "bounded colored object", label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
            destructiveRisk: false, salience: 0, visualContrast: 0.8,
            visualColor: "yellow", visualShape: "round"
        )
    }
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 5_000)
    _ = await scene.identify(
        rows: [target(x: 100)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "undersampled",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let second = first.addingTimeInterval(0.2)
    _ = await scene.identify(
        rows: [target(x: 120)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "undersampled",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )
    let third = second.addingTimeInterval(0.02)
    let currentRect = VisionRect(x: 121, y: 100, w: 40, h: 40)
    let current = await scene.identify(
        rows: [target(x: 121)], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "undersampled",
        capturedAt: third, now: third.addingTimeInterval(0.1)
    )
    let identity = try #require(current.identities[currentRect])

    #expect(identity.motion == "moving right")
    #expect(identity.projectedX == 0, "retained language must not become motor lead")
    #expect(identity.projectedY == 0)
}

@Test
func liveSceneClaimsStationaryOnlyAfterRepeatedStableObservations() async throws {
    let rect = VisionRect(x: 100, y: 100, w: 40, h: 40)
    let row = VisionAffordanceRow(
        handle: "stable-target", handleAmbiguity: nil,
        roleGuess: "AXUnknown", roleRationale: "bounded colored object", label: nil,
        rect: rect,
        confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
        state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
        destructiveRisk: false, salience: 0, visualContrast: 0.8,
        visualColor: "green", visualShape: "square"
    )
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 6_000)
    let initial = await scene.identify(
        rows: [row], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "stable",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    #expect(initial.identities[rect]?.motion == nil)
    let second = first.addingTimeInterval(0.2)
    let repeated = await scene.identify(
        rows: [row], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "stable",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )
    #expect(repeated.identities[rect]?.motion == nil)
    let third = second.addingTimeInterval(0.2)
    let established = await scene.identify(
        rows: [row], frameSize: VisionSize(width: 1_000, height: 500),
        origin: (0, 0), logicalSize: (1_000, 500), sceneKey: "stable",
        capturedAt: third, now: third.addingTimeInterval(0.1)
    )
    #expect(established.identities[rect]?.motion == "stationary")
}

@Test
func liveSceneRetainsDecayingTrajectoryThroughOneQuantizedFrame() async throws {
    func target(x: Double) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: "slow-target", handleAmbiguity: nil,
            roleGuess: "AXUnknown", roleRationale: "bounded colored object", label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(), evidence: [.colorRegion], ambiguous: nil,
            destructiveRisk: false, salience: 0, visualContrast: 0.8,
            visualColor: "yellow", visualShape: "round"
        )
    }
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 5_000)
    _ = await scene.identify(
        rows: [target(x: 100)], frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "quantized",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let second = first.addingTimeInterval(0.2)
    let moved = await scene.identify(
        rows: [target(x: 110)], frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "quantized",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )
    let id = try #require(moved.identities[VisionRect(x: 110, y: 100, w: 40, h: 40)]?.id)

    let quantized = second.addingTimeInterval(0.2)
    let held = await scene.identify(
        rows: [target(x: 110)], frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "quantized",
        capturedAt: quantized, now: quantized.addingTimeInterval(0.1)
    )
    let heldIdentity = try #require(held.identities[VisionRect(x: 110, y: 100, w: 40, h: 40)])
    #expect(heldIdentity.id == id)
    #expect(heldIdentity.projectedX == 0, "unobserved continuation must not move the motor point")

    let hiddenCapture = quantized.addingTimeInterval(0.2)
    let hidden = await scene.identify(
        rows: [], frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "quantized",
        capturedAt: hiddenCapture, now: hiddenCapture.addingTimeInterval(0.1)
    )
    let occluded = try #require(hidden.temporarilyNotVisible.first { $0.id == id })
    #expect(occluded.lastCenterXPercent == 26)
    #expect(occluded.expectedCenterXPercent == 28)
}

@Test
func liveSceneKeepsDifferentlyColoredObjectsDistinctWhenTheyCross() async throws {
    func object(_ handle: String, x: Double, color: String) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle,
            handleAmbiguity: nil,
            roleGuess: "AXUnknown",
            roleRationale: "bounded colored object",
            label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(),
            evidence: [.colorRegion],
            ambiguous: nil,
            destructiveRisk: false,
            salience: 0,
            visualContrast: 0.8,
            visualColor: color
        )
    }
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 2_000)
    let initial = await scene.identify(
        rows: [object("red-a", x: 100, color: "red"), object("blue-a", x: 300, color: "blue")],
        frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "crossing",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let redID = try #require(initial.identities[VisionRect(x: 100, y: 100, w: 40, h: 40)]?.id)
    let blueID = try #require(initial.identities[VisionRect(x: 300, y: 100, w: 40, h: 40)]?.id)
    let second = first.addingTimeInterval(0.2)
    let crossed = await scene.identify(
        rows: [object("blue-b", x: 100, color: "blue"), object("red-b", x: 300, color: "red")],
        frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "crossing",
        capturedAt: second, now: second.addingTimeInterval(0.1)
    )

    #expect(crossed.identities[VisionRect(x: 100, y: 100, w: 40, h: 40)]?.id == blueID)
    #expect(crossed.identities[VisionRect(x: 300, y: 100, w: 40, h: 40)]?.id == redID)

    let third = second.addingTimeInterval(0.2)
    let redHidden = await scene.identify(
        rows: [object("blue-c", x: 110, color: "blue")],
        frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (500, 300), sceneKey: "crossing",
        capturedAt: third, now: third.addingTimeInterval(0.1)
    )
    #expect(redHidden.temporarilyNotVisible.contains {
        $0.id == redID && $0.colorName == "red" && $0.missedFrames == 1
    })
    #expect(!redHidden.identities.values.contains { $0.id == redID })
}

@Test
func liveSceneKeepsDifferentlyShapedSameColorObjectsDistinctWhenTheyCross() async throws {
    func object(_ handle: String, x: Double, shape: String) -> VisionAffordanceRow {
        VisionAffordanceRow(
            handle: handle,
            handleAmbiguity: nil,
            roleGuess: "AXUnknown",
            roleRationale: "bounded colored object",
            label: nil,
            rect: VisionRect(x: x, y: 100, w: 40, h: 40),
            confidence: VisionConfidence(bounds: 0.9, role: 0.2, state: 0, text: 0, target: 0.25),
            state: VisionStateGuess(),
            evidence: [.colorRegion],
            ambiguous: nil,
            destructiveRisk: false,
            salience: 0,
            visualContrast: 0.8,
            visualColor: "red",
            visualShape: shape
        )
    }
    let scene = SwiftToolDispatcherFourVerbLiveScene()
    let first = Date(timeIntervalSince1970: 4_000)
    let initial = await scene.identify(
        rows: [object("round-a", x: 100, shape: "round"),
               object("square-a", x: 300, shape: "square")],
        frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (width: 500, height: 300), sceneKey: "shape-crossing",
        capturedAt: first, now: first.addingTimeInterval(0.1)
    )
    let roundID = try #require(
        initial.identities[VisionRect(x: 100, y: 100, w: 40, h: 40)]?.id
    )
    let squareID = try #require(
        initial.identities[VisionRect(x: 300, y: 100, w: 40, h: 40)]?.id
    )

    let crossed = await scene.identify(
        rows: [object("round-b", x: 300, shape: "round"),
               object("square-b", x: 100, shape: "square")],
        frameSize: VisionSize(width: 500, height: 300),
        origin: (0, 0), logicalSize: (width: 500, height: 300), sceneKey: "shape-crossing",
        capturedAt: first.addingTimeInterval(0.2), now: first.addingTimeInterval(0.3)
    )
    #expect(crossed.identities[VisionRect(x: 300, y: 100, w: 40, h: 40)]?.id == roundID)
    #expect(crossed.identities[VisionRect(x: 100, y: 100, w: 40, h: 40)]?.id == squareID)
}
