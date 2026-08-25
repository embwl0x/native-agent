import Foundation
import CoreGraphics
@testable import ChatOrchestration
import MacControl
import NativeAgentCore
import PersistenceCore
import Testing
import VisionPerception

private final class RenderCapTargetHost: MacFourVerbsHost, @unchecked Sendable {
    private let lock = NSLock()
    private var looks: [MacControlResult]
    private var calls: [(String, [String: JSONValue])] = []

    init(looks: [MacControlResult]) {
        self.looks = looks
    }

    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        lock.withLock {
            calls.append((action, body))
            if action == "look" {
                return looks.removeFirst()
            }
            return MacControlResult(
                ok: true,
                action: action,
                output: .object(["status": .string("acted"), "effect": .object([:])]),
                error: nil,
                durationMs: 1,
                viaSwift: true
            )
        }
    }

    func firstActBody() -> [String: JSONValue]? {
        lock.withLock { calls.first(where: { $0.0 == "act" })?.1 }
    }

    func actions() -> [String] {
        lock.withLock { calls.map(\.0) }
    }
}

private struct RenderCapSupplement: MacFourVerbsSupplementalPerceptionSource {
    let value: MacFourVerbsSupplement
    func observe() async -> MacFourVerbsSupplement? { value }
}

private actor RenderCapSequenceSupplement: MacFourVerbsSupplementalPerceptionSource {
    private var values: [[String]]
    private let target: MacFourVerbsSupplementalTarget

    init(values: [[String]], target: MacFourVerbsSupplementalTarget) {
        self.values = values
        self.target = target
    }

    func observe() async -> MacFourVerbsSupplement? {
        let current = values.count > 1 ? values.removeFirst() : (values.first ?? [])
        return MacFourVerbsSupplement(
            appName: "Fixture App",
            bundleIdentifier: "test.fixture.app",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: [target],
            diagnostics: ["vision_value_text": .array(current.map(JSONValue.string))]
        )
    }
}

private func renderCapLook(
    window: String,
    affordances: [[String: JSONValue]],
    landmarks: [[String: JSONValue]] = []
) -> MacControlResult {
    MacControlResult(
        ok: true,
        action: "look",
        output: .object([
            "frame_id": .string("fixture-frame"),
            "app": .object([
                "name": .string("Fixture App"),
                "bundle_id": .string("test.fixture.app"),
                "pid": .int(42),
            ]),
            "window": .string(window),
            "affordances": .array(affordances.map(JSONValue.object)),
            "landmarks": .array(landmarks.map(JSONValue.object)),
            "focus": .object([:]),
        ]),
        error: nil,
        durationMs: 1,
        viaSwift: true
    )
}

private func renderCapAffordance(
    handle: String,
    role: String,
    label: String,
    path: Int
) -> [String: JSONValue] {
    [
        "handle": .string(handle),
        "role": .string(role),
        "label": .string(label),
        "path": .array([.int(Int64(path))]),
        "enabled": .bool(true),
    ]
}

@Test("render caps never make a visible control or row unaddressable")
func renderCapsDoNotCapNaturalTargets() async throws {
    let controls = [
        renderCapAffordance(handle: "first", role: "AXButton", label: "Back", path: 0),
        renderCapAffordance(handle: "second", role: "AXButton", label: "Share", path: 1),
        renderCapAffordance(handle: "new-note", role: "AXButton", label: "New Note", path: 2),
    ]
    let controlHost = RenderCapTargetHost(looks: [
        renderCapLook(window: "Notes", affordances: controls),
        renderCapLook(window: "New note", affordances: controls),
    ])
    let controlReply = await MacFourVerbs(
        host: controlHost,
        options: MacScreenRender.Options(maxControls: 2)
    ).act(verb: "click", target: "New Note")
    #expect(controlReply.ok, "\(controlReply.text)")
    #expect(controlHost.firstActBody()?["handle"] == .string("new-note"))

    let rows = [
        renderCapAffordance(handle: "row-1", role: "AXRow", label: "First", path: 0),
        renderCapAffordance(handle: "row-2", role: "AXRow", label: "Second", path: 1),
        renderCapAffordance(handle: "row-3", role: "AXRow", label: "Third", path: 2),
    ]
    let rowHost = RenderCapTargetHost(looks: [
        renderCapLook(window: "List", affordances: rows),
        renderCapLook(window: "Third opened", affordances: rows),
    ])
    let rowReply = await MacFourVerbs(
        host: rowHost,
        options: MacScreenRender.Options(maxRows: 2)
    ).act(verb: "open", target: "row 3")
    #expect(rowReply.ok, "\(rowReply.text)")
    #expect(rowHost.firstActBody()?["handle"] == .string("row-3"))
}

@Test("a fused AX label enriches an already-framed semantic target")
func fusedLabelAndSemanticHandleStayOneAddressableTarget() async throws {
    let frame = MacAXFrame(x: 100, y: 50, w: 40, h: 30)
    let unlabeled: [String: JSONValue] = [
        "handle": .string("semantic-new-note"),
        "role": .string("AXButton"),
        "path": .array([.int(0)]),
        "enabled": .bool(true),
        "frame": .object([
            "x": .double(frame.x), "y": .double(frame.y),
            "w": .double(frame.w), "h": .double(frame.h),
        ]),
    ]
    let host = RenderCapTargetHost(looks: [
        renderCapLook(window: "Notes", affordances: [unlabeled]),
        renderCapLook(window: "New note", affordances: [unlabeled]),
    ])
    let label = MacScreenText("New Note", redacted: .string("New Note"))
    let supplement = RenderCapSupplement(value: MacFourVerbsSupplement(
        appName: "Fixture App",
        bundleIdentifier: "test.fixture.app",
        controls: [MacScreenRender.Control(label: label, kind: "button", provenance: .ax)],
        targets: [MacFourVerbsSupplementalTarget(
            label: label,
            kind: "button",
            frame: frame,
            provenance: .ax,
            viewId: "view-1",
            mark: 7
        )]
    ))

    let reply = await MacFourVerbs(host: host, supplementalSource: supplement)
        .act(verb: "click", target: "New Note")

    #expect(reply.ok, "\(reply.text)")
    #expect(host.firstActBody()?["handle"] == .string("semantic-new-note"))
}

@Test("a containing toolbar region never swallows its named button")
func nestedControlAndLandmarkRemainDistinctTargets() async throws {
    let toolbar: [String: JSONValue] = [
        "kind": .string("toolbar"),
        "role": .string("AXToolbar"),
        "label": .string("toolbar 1"),
        "path": .array([.int(0)]),
        "frame": .object([
            "x": .double(0), "y": .double(0),
            "w": .double(800), "h": .double(60),
        ]),
    ]
    let host = RenderCapTargetHost(looks: [
        renderCapLook(window: "Notes", affordances: [], landmarks: [toolbar]),
        renderCapLook(window: "New note", affordances: [], landmarks: [toolbar]),
    ])
    let label = MacScreenText("New Note", redacted: .string("New Note"))
    let supplement = RenderCapSupplement(value: MacFourVerbsSupplement(
        appName: "Fixture App",
        bundleIdentifier: "test.fixture.app",
        controls: [MacScreenRender.Control(label: label, kind: "button", provenance: .ax)],
        targets: [MacFourVerbsSupplementalTarget(
            label: label,
            kind: "button",
            frame: MacAXFrame(x: 700, y: 10, w: 40, h: 30),
            provenance: .ax,
            viewId: "view-1",
            mark: 9
        )]
    ))

    let reply = await MacFourVerbs(host: host, supplementalSource: supplement)
        .act(verb: "click", target: "New Note")

    #expect(reply.ok, "\(reply.text)")
    #expect(host.firstActBody() == nil, "the supplemental button should use the physical hand, not the toolbar handle")
}

private struct EmptyVisionTextRecognizer: VisionTextRecognizing {
    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] { [] }
}

private func blankVisionImage(width: Int = 200, height: Int = 120) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

@Test("salient unlabeled pixels join the fused screen as physical regions")
func salientPixelsBecomePhysicalFourVerbRegions() throws {
    let image = try blankVisionImage()
    let salience = VisionStaticSalienceProvider(regions: [
        (VisionRect(x: 120, y: 35, w: 35, h: 35), 0.8),
        (VisionRect(x: 10, y: 5, w: 30, h: 30), 0.9),
    ])
    let percept = try VisionPerceptionCompiler(salience: salience).compile(
        image: image,
        using: EmptyVisionTextRecognizer()
    )
    let supplement = percept.fourVerbSupplement(
        origin: (20, 30),
        logicalSize: (200, 120),
        viewId: "live-view",
        globalRegionOfInterest: MacAXFrame(x: 110, y: 50, w: 100, h: 85)
    )

    let region = try #require(supplement.targets.first {
        $0.label?.display == "visual region 1"
    })
    #expect(region.kind == "visual region")
    #expect(region.physicalOnly)
    #expect(region.viewId == "live-view")
    #expect(supplement.targets.filter(\.physicalOnly).count == 1,
            "browser-chrome candidates outside the dominant canvas must not become targets")
    #expect(supplement.contents.flatMap(\.rows).contains {
        $0.label?.display == "visual region 1"
    })
}

@Test("a dominant AX image enables pixels even when browser chrome has many marks")
func dominantCanvasRunsPixelPerceptionInsideRichBrowserChrome() {
    #expect(SwiftToolDispatcherFourVerbPerceptionSource.shouldCompilePixelPerception(
        accessibilityTrusted: true,
        markCount: 45,
        dominantImageFraction: 0.05
    ))
    #expect(!SwiftToolDispatcherFourVerbPerceptionSource.shouldCompilePixelPerception(
        accessibilityTrusted: true,
        markCount: 45,
        dominantImageFraction: 0.02
    ))
}

@Test("the semantic screen crops pixels to the AX canvas and retains global hand geometry")
func semanticScreenCropsToCanvasBeforePerception() throws {
    let image = try blankVisionImage()
    let crop = VisionImageCropper.crop(
        image,
        to: MacAXFrame(x: 110, y: 50, w: 100, h: 85),
        origin: (20, 30),
        logicalSize: (200, 120)
    )

    #expect(crop.image.width == 100)
    #expect(crop.image.height == 85)
    #expect(crop.origin.x == 110)
    #expect(crop.origin.y == 50)
    #expect(crop.logicalSize.width == 100)
    #expect(crop.logicalSize.height == 85)
}

@Test("visual regions retain one identity and report motion across observations")
func liveSemanticScreenTracksVisualRegions() async throws {
    let image = try blankVisionImage()
    func percept(x: Double) throws -> VisionPercept {
        try VisionPerceptionCompiler(salience: VisionStaticSalienceProvider(regions: [
            (VisionRect(x: x, y: 35, w: 35, h: 35), 0.9),
        ])).compile(image: image, using: EmptyVisionTextRecognizer())
    }
    let first = try percept(x: 20)
    let second = try percept(x: 28)
    let relocated = try percept(x: 150)
    let firstRow = try #require(first.rows.first(where: VisionPercept.isPhysicalRegionCandidate))
    let secondRow = try #require(second.rows.first(where: VisionPercept.isPhysicalRegionCandidate))
    let relocatedRow = try #require(relocated.rows.first(where: VisionPercept.isPhysicalRegionCandidate))
    let scene = SwiftToolDispatcherFourVerbLiveScene()

    let firstIDs = await scene.identify(
        rows: first.rows,
        frameSize: first.frameSize,
        origin: (100, 200),
        logicalSize: (1_000, 600),
        sceneKey: "fixture"
    )
    let secondIDs = await scene.identify(
        rows: second.rows,
        frameSize: second.frameSize,
        origin: (100, 200),
        logicalSize: (1_000, 600),
        sceneKey: "fixture"
    )
    let relocatedIDs = await scene.identify(
        rows: relocated.rows,
        frameSize: relocated.frameSize,
        origin: (100, 200),
        logicalSize: (1_000, 600),
        sceneKey: "fixture"
    )

    let firstIdentity = try #require(firstIDs[firstRow.rect])
    let secondIdentity = try #require(secondIDs[secondRow.rect])
    let relocatedIdentity = try #require(relocatedIDs[relocatedRow.rect])
    #expect(secondIdentity.id == firstIdentity.id)
    #expect(secondIdentity.motion == "moving right")
    #expect(relocatedIdentity.id == firstIdentity.id,
            "the same distinctive object may relocate after a successful action")
    #expect(relocatedIdentity.motion == "moving right")
}

@Test("every redacted canvas string remains readable when one visual row claims the band")
func allClaimedCanvasTextStillAppearsInScreenValues() throws {
    let image = try blankVisionImage()
    let recognizer = VisionStaticTextRecognizer(boxes: [
        VisionTextBox(
            text: "Moving visual target",
            rect: VisionRect(x: 22, y: 2, w: 125, h: 18),
            confidence: 0.98
        ),
        VisionTextBox(
            text: "Hits: 0",
            rect: VisionRect(x: 22, y: 20, w: 55, h: 18),
            confidence: 0.95
        ),
        VisionTextBox(
            text: "Misses: 0",
            rect: VisionRect(x: 22, y: 38, w: 75, h: 18),
            confidence: 0.94
        ),
    ])
    let percept = try VisionPerceptionCompiler(salience: VisionStaticSalienceProvider(regions: [
        (VisionRect(x: 10, y: 10, w: 90, h: 40), 0.8),
    ])).compile(image: image, using: recognizer)
    let supplement = percept.fourVerbSupplement(
        origin: (0, 0),
        logicalSize: (200, 120)
    )

    let values = Set(supplement.values.compactMap { $0.text.display })
    #expect(values.isSuperset(of: ["Moving visual target", "Hits: 0", "Misses: 0"]))
}

@Test("numbered visual regions accept a literal click but refuse invented typing semantics")
func numberedVisualRegionStaysPhysicalOnly() async throws {
    let looks = (0..<3).map { index in
        renderCapLook(window: "Canvas \(index)", affordances: [])
    }
    let host = RenderCapTargetHost(looks: looks)
    let label = MacScreenText("visual region 1", redacted: .string("visual region 1"))
    let supplement = RenderCapSupplement(value: MacFourVerbsSupplement(
        appName: "Fixture App",
        bundleIdentifier: "test.fixture.app",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        targets: [MacFourVerbsSupplementalTarget(
            label: label,
            kind: "visual region",
            frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
            provenance: .vision(0.35),
            physicalOnly: true
        )]
    ))
    let verbs = MacFourVerbs(host: host, supplementalSource: supplement)

    let refused = await verbs.act(
        verb: "type", target: "visual region 1", text: "must not be typed"
    )
    #expect(!refused.ok)
    #expect(refused.detail["error"] == .string("visual_region_needs_physical_action"))
    #expect(!host.actions().contains("hand"))

    let clicked = await verbs.act(verb: "click", target: "visual region 1")
    #expect(clicked.ok, "\(clicked.text)")
    #expect(host.actions().contains("hand"))
    #expect(host.firstActBody() == nil, "an unlabeled pixel region must never enter semantic AX act")
    #expect(clicked.detail["verification"] == .string("unverified"),
            "generic animation/screen movement cannot verify a physical-region hit")
    #expect(clicked.detail["physical_route"] == .string("click"))
}

@Test("a changed visible canvas value verifies a physical-region click")
func canvasValueDeltaVerifiesPhysicalClick() async {
    let looks = (0..<2).map { index in
        renderCapLook(window: "Canvas \(index)", affordances: [])
    }
    let host = RenderCapTargetHost(looks: looks)
    let label = MacScreenText("visual region 1", redacted: .string("visual region 1"))
    let target = MacFourVerbsSupplementalTarget(
        label: label,
        kind: "visual region",
        frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
        provenance: .vision(0.45),
        physicalOnly: true
    )
    let supplement = RenderCapSequenceSupplement(
        values: [
            ["Moving visual target", "Hits: 0", "Misses: 0"],
            ["Moving visual target", "Hits: 1", "Misses: 0"],
        ],
        target: target
    )

    let clicked = await MacFourVerbs(host: host, supplementalSource: supplement)
        .act(verb: "click", target: "visual region 1")

    #expect(clicked.ok)
    #expect(clicked.detail["verification"] == .string("satisfied"))
    #expect(clicked.detail["verification_evidence"] == .string("fresh_visible_value_change"))
    #expect(clicked.detail["status"] == .string("acted"))
}

@Test("overlapping live visual regions remain resolvable by every printed identity")
func overlappingVisualRegionsDoNotLoseTheirActionNames() async {
    let looks = (0..<2).map { index in
        renderCapLook(
            window: "Canvas \(index)",
            affordances: [renderCapAffordance(
                handle: "ax-image",
                role: "AXImage",
                label: "Canvas",
                path: 0
            )]
        )
    }
    let host = RenderCapTargetHost(looks: looks)
    func label(_ number: Int) -> MacScreenText {
        let text = "visual region \(number)"
        return MacScreenText(text, redacted: .string(text))
    }
    let supplement = RenderCapSupplement(value: MacFourVerbsSupplement(
        appName: "Fixture App",
        bundleIdentifier: "test.fixture.app",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        contents: [MacScreenRender.Content(
            kind: .grid,
            rows: [1, 2].map { number in
                MacScreenRender.Row(
                    label: label(number),
                    detail: [MacScreenText("high contrast", redacted: .string("high contrast"))],
                    provenance: .vision(0.8),
                    abstain: "physical region; semantic role uncertain"
                )
            }
        )],
        targets: [
            MacFourVerbsSupplementalTarget(
                label: label(2),
                kind: "visual region",
                frame: MacAXFrame(x: 300, y: 200, w: 100, h: 100),
                provenance: .vision(0.8),
                physicalOnly: true
            ),
            MacFourVerbsSupplementalTarget(
                label: label(1),
                kind: "visual region",
                frame: MacAXFrame(x: 325, y: 225, w: 40, h: 40),
                provenance: .vision(0.8),
                physicalOnly: true
            ),
        ]
    ))
    let verbs = MacFourVerbs(host: host, supplementalSource: supplement)

    let clicked = await verbs.act(verb: "click", target: "visual region 1")

    #expect(clicked.ok, "\(clicked.text)")
    #expect(host.actions().contains("hand"))
    #expect(clicked.detail["matched"] == .string("\"visual region 1\""))
}
